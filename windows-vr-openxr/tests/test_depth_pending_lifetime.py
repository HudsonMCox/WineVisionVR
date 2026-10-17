#!/usr/bin/env python3
"""Execute actual pending submission and WMT RAII code to verify all four resource lifetimes."""
from pathlib import Path
import subprocess,tempfile,argparse
root=Path(__file__).resolve().parents[2]
parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--dxmt',type=Path,default=root/'.build-performance/dxmt');dxmt=parser.parse_args().dxmt
s=(dxmt/'src/dxmt/dxmt_context.hpp').read_text();metal=(dxmt/'src/winemetal/Metal.hpp').read_text()
def extract(s,signature):
 a=s.index(signature);b=s.index('{',a)+1;e=b;d=1
 while d:d+=(s[e]=='{')-(s[e]=='}');e+=1
 return s[a:e]
reference=extract(metal,'template <typename Class> class Reference')+';'
pending=extract(s,'struct PendingWindowsVRSubmission')+';'
a=s.index('void queueWindowsVRSubmission(');b=s.index(') {',a)+3;e=b;depth=1
while depth:depth+=(s[e]=='{')-(s[e]=='}');e+=1
method=s[a:e]
code=r'''
#include "WindowsVRWMTBridge.h"
#include "WindowsVRReconstruction.h"
#include <array>
#include <optional>
#include <memory>
#include <mutex>
#include <condition_variable>
#include <cassert>
#include <cstdio>
namespace WMT {
using obj_handle_t=uint64_t;constexpr uint64_t NULL_OBJECT_HANDLE=0;
std::array<int,16> refs{};int retainCalls=0;
struct Texture {uint64_t handle=0;explicit operator bool()const{return handle!=0;}void retain(){++retainCalls;if(handle)++refs[handle];}void release(){if(handle){assert(refs[handle]>0);--refs[handle];}}};
'''+reference+r'''
}
struct WindowsVRSubmissionResult {std::mutex mutex;std::condition_variable changed;int status=0;bool completed=false;};
struct Context {
'''+pending+r'''
std::optional<PendingWindowsVRSubmission>windows_vr_submission_;
'''+method+r'''
};
int main(){
 for(int i=1;i<=8;++i)WMT::refs[i]=1;
 {
 Context ctx;WMTWindowsVRRequestV2 layout{};WVRReconstructionSubmitV1 geometry{};geometry.abiVersion=WVR_RECONSTRUCTION_ABI;
 auto result=std::make_shared<WindowsVRSubmissionResult>();
 ctx.queueWindowsVRSubmission(WMT::Texture{1},WMT::Texture{2},layout,result,geometry,WMT::Texture{3},WMT::Texture{4});
 for(int i=1;i<=4;++i){assert(WMT::refs[i]==2);WMT::Texture{uint64_t(i)}.release();assert(WMT::refs[i]==1);}
 // A pending submission owns depth even after guest image waits release their resource-map entries.
 auto pending=std::move(*ctx.windows_vr_submission_);ctx.windows_vr_submission_.reset();for(int i=1;i<=4;++i)assert(WMT::refs[i]==1);
 assert(pending.depthLeft.handle==3&&pending.depthRight.handle==4);
 ctx.queueWindowsVRSubmission(WMT::Texture{5},WMT::Texture{6},layout,result,geometry,WMT::Texture{7},WMT::Texture{8});
 auto rejected=std::make_shared<WindowsVRSubmissionResult>();
 ctx.queueWindowsVRSubmission(WMT::Texture{1},WMT::Texture{2},layout,rejected,geometry,WMT::Texture{3},WMT::Texture{4});
 assert(rejected->completed&&rejected->status==WVRCompositorStatusIncompatibleTexture);
 for(int i=1;i<=4;++i)assert(WMT::refs[i]==1);for(int i=5;i<=8;++i)assert(WMT::refs[i]==2);
 ctx.windows_vr_submission_.reset();for(int i=5;i<=8;++i)assert(WMT::refs[i]==1);
 const int before=WMT::retainCalls;ctx.queueWindowsVRSubmission(WMT::Texture{5},WMT::Texture{6},layout,result);
 assert(WMT::retainCalls-before==2); // No null-depth retain calls cross the Wine/native boundary.
 assert(!ctx.windows_vr_submission_->depthLeft.handle&&!ctx.windows_vr_submission_->depthRight.handle);
 ctx.windows_vr_submission_.reset();
 }
 for(int i=1;i<=4;++i)assert(WMT::refs[i]==0);
 puts("PASS: actual pending transport and WMT RAII retain both color and depth through queue transfer, rejection and completion without leaked ownership");
}
'''
with tempfile.TemporaryDirectory(prefix='wvr-depth-lifetime-') as tmp:
 p=Path(tmp);(p/'probe.cpp').write_text(code)
 subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20','-O2','-fsanitize=undefined,bounds','-I',str(root/'windows-vr-openxr/include'),'-I',str(root/'windows-vr-native/include'),str(p/'probe.cpp'),'-o',str(p/'probe')],check=True)
 subprocess.run([str(p/'probe')],check=True)
