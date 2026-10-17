#!/usr/bin/env python3
"""Exercise production snapshot negotiation/conversion without Wine."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2];s=(root/'windows-vr-openxr/src/WindowsVROpenXR.cpp').read_text()
def fn(name):
 a=s.index(name);b=s.index('{',a)+1;e=b;d=1
 while d:d+=(s[e]=='{')-(s[e]=='}');e+=1
 return s[a:e]
preamble=r'''
#include "WindowsVRFrameState.h"
#include <atomic>
#include <mutex>
#include <cassert>
#include <cstring>
constexpr unsigned kViewCount=2;
struct WVRDXMTTrackingV1 {uint32_t flags;uint64_t timestampNanoseconds;float originFromDevice[16],deviceFromEye[2][16],frustumTangents[2][4];};
struct WVRDXMTTargetInfoV1 {uint64_t generation;uint32_t width[2],height[2],pixelFormat[2];};
using WVRDXMTControllerV1=WVRControllerStateV1;
struct Instance {WVRDXMTTargetInfoV1 targets;};
struct Session {Instance*instance;std::once_flag frameBridgeOnce;using FrameBridgeFunction=int32_t(*)(void*);FrameBridgeFunction frameBridge=nullptr;std::atomic<bool>frameBridgeUnsupported{false};std::atomic<bool>frameBridgeAnnounced{false};};
void TraceLine(const char*){}
int calls=0,resolutions=0;bool supported=true;
int32_t bridge(void*data) {++calls;auto&r=*(WVRFrameStateRequestV1*)data;if(!supported)return -1;
 assert(r.abiVersion==WVR_FRAME_STATE_ABI&&r.structSize==sizeof(r)&&r.expectedTargetGeneration==42);
 assert(r.operation==(r.timeoutNanoseconds?2u:1u));r.status=0;r.tracking.flags=3;r.tracking.timestampNanoseconds=123456;
 for(unsigned i=0;i<16;++i)r.tracking.originFromDevice[i]=float(i);
 r.targets.generation=42;r.targets.width[0]=1888;r.targets.width[1]=1900;
 r.controllers[0].trigger=.75;r.controllers[0].buttons=16;r.controllers[1].grip=.5;return 0;
}
void* GetModuleHandleW(const wchar_t*){return (void*)1;}
void* GetProcAddress(void*,const char*){++resolutions;return (void*)bridge;}
'''
code=preamble+fn('bool GetSessionFrameState(')+fn('void CopyFrameTracking(')+fn('void CopyFrameTargets(')+fn('void CopyFrameController(')+r'''
int main(){Instance i{};i.targets.generation=42;Session s{};s.instance=&i;WVRFrameStateRequestV1 r;
 assert(GetSessionFrameState(&s,r));assert(GetSessionFrameState(&s,r,123456,100000000));assert(calls==2&&resolutions==1);
 WVRDXMTTrackingV1 t{};CopyFrameTracking(r.tracking,t);assert(t.flags==3&&t.timestampNanoseconds==123456&&t.originFromDevice[7]==7);
 WVRDXMTTargetInfoV1 targets{};CopyFrameTargets(r.targets,targets);assert(targets.generation==42&&targets.width[1]==1900);
 WVRDXMTControllerV1 c{};CopyFrameController(r.controllers[0],c);assert(c.trigger==.75&&c.buttons==16);CopyFrameController(r.controllers[1],c);assert(c.grip==.5);
 Session legacy{};legacy.instance=&i;supported=false;assert(!GetSessionFrameState(&legacy,r));auto before=calls;assert(!GetSessionFrameState(&legacy,r));assert(calls==before);
}
'''
with tempfile.TemporaryDirectory(prefix='wvr-frame-transport-') as name:
 w=Path(name);(w/'probe.cpp').write_text(code)
 subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20','-O2','-fsanitize=undefined,bounds','-I',str(root/'windows-vr-native/include'),str(w/'probe.cpp'),'-o',str(w/'probe')],check=True)
 subprocess.run([str(w/'probe')],check=True,timeout=30)
print('PASS: production frame-state transport negotiates once, sends timeout/generation, preserves tracking/controller values and stops probing legacy peers')
