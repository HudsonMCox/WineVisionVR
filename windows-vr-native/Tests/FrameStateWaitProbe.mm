#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "WindowsVRFrameState.h"
#include "WindowsVRGuestFoveation.h"
#include <cassert>
#include <future>
#include <chrono>
#include <thread>
#include <cstdio>
extern "C" {
void *dxmt_winemetal_unix_call_funcs[148] = {};
size_t wvr_dxmt_d3d12_unix_call_count_v1() { return 148; }
unsigned wvr_dxmt_d3d12_transport_abi_v1() { return 1; }
}
static int legacy(void*) { return -1; }
using namespace std::chrono_literals;
static WVRFrameStateRequestV1 query(uint32_t op, uint64_t after=0, uint64_t timeout=100000000, uint64_t generation=0) {
 WVRFrameStateRequestV1 r{};r.abiVersion=WVR_FRAME_STATE_ABI;r.structSize=sizeof(r);r.operation=op;
 r.afterTimestampNanoseconds=after;r.timeoutNanoseconds=timeout;r.expectedTargetGeneration=generation;
 void *pointer = &r;
 auto dispatch = reinterpret_cast<int(*)(void*)>(dxmt_winemetal_unix_call_funcs[146]);
 assert(dispatch(&pointer)==0 && r.status==0);return r;
}
static void pose(uint64_t time) {
 float head[16]{},eyes[32]{},projection[32]{},fov[8]{},depth[2]{.1,100};
 for(int i=0;i<4;++i){head[i*5]=1;eyes[i*5]=eyes[16+i*5]=projection[i*5]=projection[16+i*5]=1;}
 assert(wvr_compositor_publish_frame_tracking_v1(time,WVRDevicePoseTracked,head,eyes,projection,fov,depth)==0);
}
int main(){@autoreleasepool{
 auto device=MTLCreateSystemDefaultDevice();assert(device);
 dxmt_winemetal_unix_call_funcs[146]=(void*)legacy;assert(wvr_guest_foveation_install_v1());
 assert(wvr_compositor_bind_metal_device_v1((__bridge void*)device)==0);
 auto targets=[](unsigned n){assert(wvr_compositor_publish_targets_v1(n,n,80,n,n,80)==0);};
 targets(128);pose(100);
 auto first=query(1);auto gen=first.targets.generation;
 assert(first.tracking.timestampNanoseconds==100&&first.targets.width[0]==128);
 assert(query(2,0).tracking.timestampNanoseconds==100);
 auto begin=std::chrono::steady_clock::now();auto stale=query(2,100,5000000,gen);
 auto elapsed=std::chrono::steady_clock::now()-begin;
 assert(elapsed>=4ms&&elapsed<500ms&&stale.tracking.timestampNanoseconds==100);
 auto pending=std::async(std::launch::async,[=]{return query(2,100,100000000,gen);});
 std::this_thread::sleep_for(3ms);pose(100);assert(pending.wait_for(3ms)==std::future_status::timeout);
 pose(101);assert(pending.wait_for(100ms)==std::future_status::ready);assert(pending.get().tracking.timestampNanoseconds==101);
 // Publication before, during and just after wait registration must never be lost.
 for(uint64_t i=102;i<202;++i){auto f=std::async(std::launch::async,[=]{return query(2,i-1,100000000,gen);});if(i%2)std::this_thread::yield();pose(i);assert(f.wait_for(100ms)==std::future_status::ready);assert(f.get().tracking.timestampNanoseconds==i);}
 auto resized=std::async(std::launch::async,[=]{return query(2,201,100000000,gen);});std::this_thread::sleep_for(2ms);targets(256);assert(resized.wait_for(100ms)==std::future_status::ready);assert(resized.get().targets.width[0]==256);
 gen=query(1).targets.generation;
 auto paused=std::async(std::launch::async,[=]{return query(2,201,100000000,gen);});std::this_thread::sleep_for(2ms);wvr_compositor_pause_v1();assert(paused.wait_for(100ms)==std::future_status::ready);assert(paused.get().targets.width[0]==0);
 targets(128);pose(202);gen=query(1).targets.generation;
 auto exiting=std::async(std::launch::async,[=]{return query(2,202,100000000,gen);});std::this_thread::sleep_for(2ms);wvr_compositor_request_session_exit_v1();assert(exiting.wait_for(100ms)==std::future_status::ready);assert(exiting.get().tracking.flags&WVRDevicePoseSessionExitRequested);
 wvr_compositor_reset_session_exit_v1();
 pose(1000000000);
 for(uint64_t tick=1;tick<=8;++tick)pose(1000000000+tick*10000000);
 assert(query(1).displayPeriodNanoseconds==10000000);
 pose(1110000000); // Three display ticks missed; keep the 100 Hz cadence.
 assert(query(1).displayPeriodNanoseconds==10000000);
 auto bad=query(1);bad.structSize--;assert(wvr_compositor_frame_state_v1(&bad)==WVRCompositorStatusUnsupportedABI);
 puts("PASS: coherent native frame state, bounded real-pose waits, duplicate suppression, 100 publication races, resize, pause, exit and ABI rejection");
}}
