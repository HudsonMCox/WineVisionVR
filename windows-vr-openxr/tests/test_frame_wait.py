#!/usr/bin/env python3
"""Run the production OpenXR frame-pacing function without launching a game."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2];s=(root/'windows-vr-openxr/src/WindowsVROpenXR.cpp').read_text()
a=s.index('XrResult XRAPI_CALL WaitFrame(');b=s.index('{',a)+1;end=b;depth=1
while depth:depth+=(s[end]=='{')-(s[end]=='}');end+=1
body=s[a:end]
fixture=r'''
#include <openxr/openxr.h>
#include "WindowsVRFrameState.h"
#include <atomic>
#include <algorithm>
#include <mutex>
#include <condition_variable>
#include <chrono>
#include <thread>
#include <vector>
#include <cassert>
#define FAILED(x) ((x)<0)
constexpr int TraceWaitFrame=0;constexpr XrDuration kMaximumWait=100000000;constexpr unsigned kViewCount=2;
using WVRDXMTTrackingV1=WVRFrameTrackingV1;using WVRDXMTTargetInfoV1=WVRRenderTargetInfoV1;
struct Instance {WVRDXMTTargetInfoV1 targets{};};
struct Swapchain {uint64_t targetGeneration;};
struct Session {Instance*instance;bool begun=true,exitRequested=false;XrSessionState state=XR_SESSION_STATE_FOCUSED;std::mutex frameMutex;std::condition_variable frameCondition;bool waitTokenPending=false;WVRDXMTTrackingV1 pendingTracking{};XrTime pendingDisplayTime=0;uint64_t pendingFrameIndex=0,frameIndex=0;XrTime predictedTime=100000000,lastWaitTrackingTime=100000000;std::vector<Swapchain*>swapchains;};
Session*GetSession(XrSession h){return (Session*)h;}
void TraceEntry(int){}void TraceResult(int,XrResult,uint64_t=0){}
void QueueSessionState(Session*s,XrSessionState state){s->state=state;}
XrTime MonotonicTimeNanoseconds(){return 1000;}
int scenario=0,polls=0;
int GetSessionTargets(Session*s,WVRDXMTTargetInfoV1*out){*out=s->instance->targets;return 0;}
int GetSessionTracking(Session*,WVRDXMTTrackingV1*out){++polls;out->flags=1;out->timestampNanoseconds=144444444;return 0;}
bool GetSessionFrameState(Session*s,WVRFrameStateRequestV1&r,uint64_t,uint64_t){
 if(scenario==5)return false;
 r.targets=s->instance->targets;r.tracking.flags=1;r.tracking.timestampNanoseconds=scenario==4?100000000:144444444;r.displayPeriodNanoseconds=scenario==6?10000000:11111111;
 if(scenario==1){r.targets.generation++;for(auto&w:r.targets.width)w=0;for(auto&h:r.targets.height)h=0;r.tracking.flags=0;}
 if(scenario==2){r.targets.generation++;r.targets.width[0]++;}
 if(scenario==3)r.tracking.flags|=WVRDevicePoseSessionExitRequested;
 return true;
}
bool ObserveSessionExitRequest(Session*s,WVRDXMTTrackingV1*t=nullptr,WVRDXMTTargetInfoV1*targets=nullptr,bool*valid=nullptr,const WVRFrameStateRequestV1*provided=nullptr){
 WVRFrameStateRequestV1 current{};current.targets=s->instance->targets;current.tracking.flags=1;current.tracking.timestampNanoseconds=100000000;
 if(provided)current=*provided;
 if(t)*t=current.tracking;if(targets)*targets=current.targets;if(valid)*valid=true;
 if(current.tracking.flags&WVRDevicePoseSessionExitRequested)s->exitRequested=true;
 return s->exitRequested;
}
'''+body+r'''
int main(){
 for(scenario=0;scenario<7;++scenario){
  polls=0;Instance i{};i.targets.generation=1;for(int e=0;e<2;++e){i.targets.width[e]=128;i.targets.height[e]=128;i.targets.pixelFormat[e]=80;}
  Session session{};session.instance=&i;XrFrameWaitInfo info{XR_TYPE_FRAME_WAIT_INFO};XrFrameState out{XR_TYPE_FRAME_STATE};
  auto result=WaitFrame((XrSession)&session,&info,&out);
  if(scenario==2){assert(result==XR_ERROR_SESSION_LOST&&session.exitRequested);continue;}
  if(scenario==3){assert(result==XR_ERROR_SESSION_NOT_RUNNING&&session.exitRequested);continue;}
  assert(result==XR_SUCCESS&&!session.exitRequested&&session.waitTokenPending);
  assert(out.shouldRender==((scenario==1||scenario==4)?XR_FALSE:XR_TRUE));
  if(scenario!=5)assert(polls==0);else assert(polls==1);
  assert(out.predictedDisplayPeriod==(scenario==6?10000000:11111111));
 }
}
'''
with tempfile.TemporaryDirectory(prefix='wvr-wait-frame-') as name:
 w=Path(name);(w/'probe.cpp').write_text(fixture)
 subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20','-O2','-fsanitize=undefined,bounds','-I',str(root/'third-party/openxr/include'),'-I',str(root/'windows-vr-native/include'),str(w/'probe.cpp'),'-o',str(w/'probe')],check=True)
 subprocess.run([str(w/'probe')],check=True,timeout=30)
print('PASS: production WaitFrame uses zero guest polls on native waits, preserves pause without session loss, handles resize/exit/timeout, and retains legacy polling')
