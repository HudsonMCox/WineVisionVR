#!/usr/bin/env python3
"""Exercise the production pose-history search, including ring wrap and stale poses."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root/'windows-vr-native/Sources/WindowsVRCompositorBridge.mm').read_text()
method = source[source.index('WVRFrameTrackingV1 trackingForTimestampLocked('):source.index('\nvoid clearSlot(', source.index('WVRFrameTrackingV1 trackingForTimestampLocked('))]
fixture = r'''
#include <array>
#include <cstdint>
#include <cassert>
#include <cstdio>
#include <random>
constexpr uint32_t WVRDevicePoseTracked=1;
struct WVRFrameTrackingV1 {uint32_t flags=0;uint64_t timestampNanoseconds=0;};
struct CountedHistory {
 std::array<WVRFrameTrackingV1,512> entries{};
 mutable size_t reads=0;
 constexpr size_t size()const{return 512;}
 const auto& operator[](size_t i)const{++reads;return entries[i];}
 auto& operator[](size_t i){return entries[i];}
};
struct BridgeState {CountedHistory trackingHistory;size_t trackingHistoryCount=0,trackingHistoryNext=0;};
'''+method+r'''
int main(){
 BridgeState b;std::mt19937 random(19);
 assert(trackingForTimestampLocked(b,100).timestampNanoseconds==0);
 for(size_t publish=0;publish<3000;++publish){
  const uint64_t timestamp=10000000+publish*11111111;
  b.trackingHistory[b.trackingHistoryNext]={publish%17?1u:0u,timestamp};
  b.trackingHistoryNext=(b.trackingHistoryNext+1)%512;
  if(b.trackingHistoryCount<512)++b.trackingHistoryCount;
  for(int probe=0;probe<10;++probe){
   uint64_t requested=timestamp-(random()%520)*11111111ull;
   if(probe==0)requested=timestamp;
   if(probe==1)requested=timestamp+2000000;
   if(probe==2)requested=timestamp+2000001;
   uint64_t closest=2000001,expected=0;
   for(size_t i=0;i<b.trackingHistoryCount;++i){
    auto s=b.trackingHistory.entries[i];if(!(s.flags&1)||!s.timestampNanoseconds)continue;
    uint64_t d=requested>=s.timestampNanoseconds?requested-s.timestampNanoseconds:s.timestampNanoseconds-requested;
    if(d<closest){closest=d;expected=s.timestampNanoseconds;}
   }
   b.trackingHistory.reads=0;
   auto got=trackingForTimestampLocked(b,requested);
   assert(got.timestampNanoseconds==expected);
   if(probe==0&&publish%17)assert(b.trackingHistory.reads==1);
  }
 }
 puts("PASS: 30000 pose searches match reference across ring wraps, stale/untracked rejection and 2ms boundary; newest exact pose uses one read");
}
'''
with tempfile.TemporaryDirectory(prefix='wvr-tracking-') as temp:
 p=Path(temp);(p/'test.cpp').write_text(fixture)
 subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20','-O2','-fsanitize=undefined',str(p/'test.cpp'),'-o',str(p/'test')],check=True)
 subprocess.run([str(p/'test')],check=True)
