#!/usr/bin/env python3
"""Run the production EndFrame validation and routing without a Windows process."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2];source=(root/'windows-vr-openxr/src/WindowsVROpenXR.cpp').read_text()
def fn(signature):
 a=source.index(signature);b=source.index('{',a)+1;e=b;depth=1
 while depth:depth+=(source[e]=='{')-(source[e]=='}');e+=1
 return source[a:e]
preamble=r'''
#include <openxr/openxr.h>
#include "WindowsVRReconstruction.h"
#include <atomic>
#include <algorithm>
#include <mutex>
#include <condition_variable>
#include <vector>
#include <cstdio>
#include <cmath>
#include <cassert>
#include <cstring>
using HRESULT=int;
constexpr int S_FALSE=1,TraceEndFrame=0,DXGI_FORMAT_D32_FLOAT=40;
#define FAILED(x) ((x)<0)
struct WVRDXMTTrackingV1 {unsigned flags=1;};
struct WVRDXMTTargetInfoV1 {uint32_t width[2]{32,32},height[2]{16,16},pixelFormat[2]{70,70};uint64_t generation=42;};
struct WVRDXMTSubmitFrameV1 {void*left;void*right;uint64_t targetGeneration,frameID,timestampNanoseconds;};
struct WVRDXMTSubmitFrameV2 {void*left;void*right;uint64_t targetGeneration,frameID,timestampNanoseconds;uint32_t leftArraySlice,leftX,leftY,leftWidth,leftHeight,rightArraySlice,rightX,rightY,rightWidth,rightHeight;};
struct WVRDXMTDepthFrameV1 {WVRDXMTSubmitFrameV2 color;void*depth[2];WVRReconstructionEyeV1 geometry[2];};
struct WVRDXMTD3D12SubmitFrameV1 : WVRDXMTSubmitFrameV2 {};
struct Backend {int color=0,depth=0;WVRDXMTDepthFrameV1 last{};HRESULT SubmitWindowsVRFrame(const WVRDXMTSubmitFrameV1*){++color;return 0;}HRESULT SubmitWindowsVRFrame(const WVRDXMTD3D12SubmitFrameV1*){++color;return 0;}HRESULT SubmitWindowsVRFrameV2(const WVRDXMTSubmitFrameV2*){++color;return 0;}HRESULT SubmitWindowsVRDepthFrame(const WVRDXMTDepthFrameV1*f){++depth;last=*f;return 0;}};
struct Instance {bool depthEnabled=true;WVRDXMTTargetInfoV1 targets;};
struct Swapchain;
struct Session {Instance*instance;bool activeFrame=true,d3d12=false;uint64_t activeFrameIndex=0;std::atomic<XrSessionState>state{XR_SESSION_STATE_FOCUSED};std::mutex frameMutex;std::condition_variable frameCondition;std::vector<Swapchain*>swapchains;Backend*dxmt,*dxmtExt3,*dxmtExt4,*dxmtQueue12;};
struct Space {Session*session;};
struct Image {uint64_t releaseOrder=1;bool acquired=false;void*texture11=(void*)0x100;void*resource12=nullptr;};
struct Swapchain {Session*session;XrSwapchainCreateInfo info{XR_TYPE_SWAPCHAIN_CREATE_INFO};uint64_t targetGeneration=42;std::vector<Image>images{Image{}};};
Session*GetSession(XrSession h){return reinterpret_cast<Session*>(h);}Space*GetSpace(XrSpace h){return reinterpret_cast<Space*>(h);}Swapchain*GetSwapchain(XrSwapchain h){return reinterpret_cast<Swapchain*>(h);}
void TraceEntry(int){}void TraceLine(const char*){}void TraceResult(int,XrResult,uint64_t=0){}void TraceCompositorDrop(uint64_t){}
HRESULT GetSessionTargets(Session*s,WVRDXMTTargetInfoV1*t){*t=s->instance->targets;return 0;}
bool tracked=true;
HRESULT GetSessionTrackingAtTime(Session*,XrTime,WVRDXMTTrackingV1*){return tracked?0:-1;}
bool OriginFromSpace(Session*,Space*,const WVRDXMTTrackingV1&,XrPosef&p,uint32_t&flags){p={{0,0,0,1},{0,0,0}};flags=15;return true;}
XrPosef ComposePose(const XrPosef&a,const XrPosef&b){auto result=b;result.position.x+=a.position.x;return result;}
void MatrixFromPose(const XrPosef&p,float*m){std::fill_n(m,16,0.f);m[0]=m[5]=m[10]=m[15]=1;m[12]=p.position.x;m[13]=p.position.y;m[14]=p.position.z;}
'''
tests=r'''
int main(){
 Instance instance;Session session;session.instance=&instance;Backend backend;session.dxmt=session.dxmtExt3=session.dxmtExt4=session.dxmtQueue12=&backend;Space space{&session};
 Swapchain color,depth;color.session=depth.session=&session;color.info.width=32;color.info.height=16;color.info.arraySize=2;depth.info.width=16;depth.info.height=8;depth.info.arraySize=2;depth.info.format=DXGI_FORMAT_D32_FLOAT;depth.images[0].texture11=(void*)0x200;
 XrCompositionLayerDepthInfoKHR di[2]{{XR_TYPE_COMPOSITION_LAYER_DEPTH_INFO_KHR},{XR_TYPE_COMPOSITION_LAYER_DEPTH_INFO_KHR}};
 XrCompositionLayerProjectionView views[2]{{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW},{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}};
 for(unsigned eye=0;eye<2;++eye){views[eye].next=&di[eye];views[eye].pose={{0,0,0,1},{float(eye)*.06f,0,0}};views[eye].fov={-.7f,.7f,.7f,-.7f};views[eye].subImage={reinterpret_cast<XrSwapchain>(&color),{{0,0},{32,16}},eye};di[eye].subImage={reinterpret_cast<XrSwapchain>(&depth),{{0,0},{16,8}},eye};di[eye].minDepth=0;di[eye].maxDepth=1;di[eye].nearZ=.1f;di[eye].farZ=100;}
 XrCompositionLayerProjection layer{XR_TYPE_COMPOSITION_LAYER_PROJECTION};layer.space=reinterpret_cast<XrSpace>(&space);layer.viewCount=2;layer.views=views;
 const auto*base=reinterpret_cast<const XrCompositionLayerBaseHeader*>(&layer);XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO};end.displayTime=123456;end.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;end.layerCount=1;end.layers=&base;
 auto run=[&]{session.activeFrame=true;session.activeFrameIndex=77;return EndFrame(reinterpret_cast<XrSession>(&session),&end);};
 assert(run()==XR_SUCCESS&&backend.depth==1&&backend.color==0);assert(backend.last.depth[0]==depth.images[0].texture11&&backend.last.color.frameID==77&&backend.last.color.timestampNanoseconds==123456);assert(backend.last.geometry[1].colorSlice==1&&backend.last.geometry[1].depthSlice==1&&backend.last.geometry[0].depthWidth==16&&backend.last.geometry[0].width==32);assert(backend.last.geometry[1].originFromEye[12]==.06f);
 auto initial=backend.depth;di[0].minDepth=1;assert(run()==XR_ERROR_VALIDATION_FAILURE);assert(backend.depth==initial);di[0].minDepth=0;
 di[1].subImage.imageRect.extent.width=17;assert(run()==XR_ERROR_SWAPCHAIN_RECT_INVALID);di[1].subImage.imageRect.extent.width=16;
 depth.images[0].acquired=true;assert(run()==XR_ERROR_CALL_ORDER_INVALID);depth.images[0].acquired=false;
 depth.targetGeneration=43;assert(run()==XR_ERROR_HANDLE_INVALID);depth.targetGeneration=42;
 views[1].next=nullptr;assert(run()==XR_ERROR_LAYER_INVALID);views[1].next=&di[1];
 instance.depthEnabled=false;assert(run()==XR_ERROR_FEATURE_UNSUPPORTED);instance.depthEnabled=true;
 tracked=false;auto count=backend.color;assert(run()==XR_SUCCESS&&backend.color==count+1&&backend.depth==initial);tracked=true;
 views[0].next=views[1].next=nullptr;count=backend.color;assert(run()==XR_SUCCESS&&backend.color==count+1);
 views[0].next=&di[0];views[1].next=&di[1];di[0].nearZ=di[1].nearZ=INFINITY;di[0].farZ=di[1].farZ=.1f;assert(run()==XR_SUCCESS);assert(backend.last.geometry[0].projection[10]==0&&backend.last.geometry[0].projection[14]==.1f);
 // D3D12 accepts a valid optional composition-depth hint without claiming capture.
 session.d3d12=true;color.images[0].texture11=depth.images[0].texture11=nullptr;color.images[0].resource12=(void*)0x400;depth.images[0].resource12=(void*)0x500;count=backend.color;assert(run()==XR_SUCCESS&&backend.color==count+1);
 puts("PASS: production EndFrame depth routing, exact frame/eye identity, independent depth sizes, invalid chains/regions/images, legacy and tracking-loss fallback, reversed-infinite projection, D3D12 color preservation");
}
'''
with tempfile.TemporaryDirectory(prefix='wvr-depth-submit-') as tmp:
 p=Path(tmp);(p/'probe.cpp').write_text(preamble+fn('bool ReconstructionProjection(')+fn('XrResult XRAPI_CALL EndFrame(')+tests)
 subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20','-O2','-fsanitize=undefined,bounds','-I',str(root/'third-party/openxr/include'),'-I',str(root/'windows-vr-native/include'),str(p/'probe.cpp'),'-o',str(p/'probe')],check=True)
 subprocess.run([str(p/'probe')],check=True)
