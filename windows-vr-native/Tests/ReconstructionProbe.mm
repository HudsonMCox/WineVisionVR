#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "WindowsVRCompositorBridge.h"
#include "WindowsVRGuestFoveation.h"
#include "WindowsVRReconstruction.h"
#include <cassert>
#include <cstdio>
#include <cstring>
#include <cmath>
extern "C" {
void *dxmt_winemetal_unix_call_funcs[148]={};
size_t wvr_dxmt_d3d12_unix_call_count_v1(){return 148;}
unsigned wvr_dxmt_d3d12_transport_abi_v1(){return 1;}
}
static int legacy(void*){return -1;}
static bool srgbMode=false,arrayMode=false;
static id<MTLTexture> make(id<MTLDevice>d,MTLPixelFormat format,unsigned w,unsigned h,bool shared,bool array=false){
 auto desc=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];if(array){desc.textureType=MTLTextureType2DArray;desc.arrayLength=2;}desc.storageMode=shared?MTLStorageModeShared:MTLStorageModePrivate;
 desc.usage=MTLTextureUsageShaderRead|MTLTextureUsageRenderTarget;return[d newTextureWithDescriptor:desc];
}
static void fill(id<MTLTexture>t,unsigned shift,unsigned slice=0){
 uint8_t pixels[32*16*4];for(unsigned y=0;y<16;++y)for(unsigned x=0;x<32;++x){auto at=(y*32+x)*4;pixels[at]=((x+shift)*7)%256;pixels[at+1]=(y*13)%256;pixels[at+2]=100;pixels[at+3]=255;}
 auto region=MTLRegionMake2D(arrayMode?2:0,arrayMode?3:0,32,16);
 if(arrayMode)[t replaceRegion:region mipmapLevel:0 slice:slice withBytes:pixels bytesPerRow:128 bytesPerImage:sizeof(pixels)];
 else [t replaceRegion:region mipmapLevel:0 withBytes:pixels bytesPerRow:128];
}
static float expected(unsigned value){float v=float(value)/255;return srgbMode?(v<=.04045f?v/12.92f:std::pow((v+.055f)/1.055f,2.4f)):v;}
static void verify(id<MTLCommandQueue>queue,void*context,unsigned kind,unsigned shift,bool holes){
 auto pointer=wvr_reconstruction_copy_output_v1(context,kind);assert(pointer);auto result=(__bridge id<MTLTexture>)pointer;
 auto cpu=make(queue.device,MTLPixelFormatRGBA16Float,32,16,true);
 auto b=[queue commandBuffer];auto blit=[b blitCommandEncoder];[blit copyFromTexture:result sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(32,16,1) toTexture:cpu destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];[blit endEncoding];[b commit];[b waitUntilCompleted];assert(b.status==MTLCommandBufferStatusCompleted);
 __fp16 pixels[32*16*4];[cpu getBytes:pixels bytesPerRow:32*8 fromRegion:MTLRegionMake2D(0,0,32,16) mipmapLevel:0];
 for(unsigned y=0;y<16;++y)for(unsigned x=0;x<32;++x){unsigned i=(y*32+x)*4;if(holes&&x==31){assert(pixels[i+3]==0);continue;}assert(pixels[i+3]==1);assert(std::fabs(float(pixels[i])-expected(((x+shift)*7)%256))<.001);assert(std::fabs(float(pixels[i+1])-expected((y*13)%256))<.001);}
 wvr_compositor_release_object_v1(pointer);
}
int main(int argc,char**argv){@autoreleasepool{
 if(argc>1){srgbMode=strcmp(argv[1],"srgb")==0||strcmp(argv[1],"array-srgb")==0;arrayMode=strcmp(argv[1],"array")==0||strcmp(argv[1],"array-srgb")==0;}
 auto device=MTLCreateSystemDefaultDevice();assert(device);auto queue=[device newCommandQueue];assert(queue);
 dxmt_winemetal_unix_call_funcs[146]=(void*)legacy;assert(wvr_guest_foveation_install_v1());
 assert(wvr_compositor_bind_metal_device_v1((__bridge void*)device)==0);assert(wvr_compositor_publish_targets_v1(32,16,srgbMode?71:70,32,16,srgbMode?71:70)==0);
 WVRRenderTargetInfoV1 targets{};targets.structSize=sizeof(targets);assert(wvr_compositor_copy_targets_v1(&targets)==0);
 const auto format=srgbMode?MTLPixelFormatRGBA8Unorm_sRGB:MTLPixelFormatRGBA8Unorm;
 auto left=make(device,format,arrayMode?36:32,arrayMode?22:16,true,arrayMode),right=arrayMode?left:make(device,format,32,16,true);
 fill(left,0);fill(right,0,arrayMode?1:0);auto depth=make(device,MTLPixelFormatDepth32Float,arrayMode?20:16,arrayMode?14:8,false,arrayMode);assert(depth);
 auto event=[device newSharedEvent];auto prepare=[queue commandBuffer];auto pass=[MTLRenderPassDescriptor new];pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=MTLLoadActionClear;pass.depthAttachment.storeAction=MTLStoreActionStore;pass.depthAttachment.clearDepth=.5;
 for(unsigned slice=0;slice<(arrayMode?2u:1u);++slice){pass.depthAttachment.slice=slice;auto encoder=[prepare renderCommandEncoderWithDescriptor:pass];[encoder endEncoding];}[prepare encodeSignalEvent:event value:1];[prepare commit];[prepare waitUntilCompleted];assert(prepare.status==MTLCommandBufferStatusCompleted);
 WVRReconstructionSubmitV1 frame{};frame.abiVersion=WVR_RECONSTRUCTION_ABI;frame.structSize=sizeof(frame);frame.producerEvent=(uint64_t)(__bridge void*)event;frame.producerValue=1;frame.frameID=1;frame.timestampNanoseconds=1000000000;frame.targetGeneration=targets.generation;
 for(unsigned eye=0;eye<2;++eye){auto&e=frame.eyes[eye];e.colorTexture=(uint64_t)(__bridge void*)(eye?right:left);e.depthTexture=(uint64_t)(__bridge void*)depth;e.colorSlice=e.depthSlice=arrayMode?eye:0;e.colorX=e.depthX=arrayMode?2:0;e.colorY=e.depthY=arrayMode?3:0;e.width=32;e.height=16;e.depthWidth=16;e.depthHeight=8;e.minDepth=0;e.maxDepth=1;for(unsigned i=0;i<4;++i)e.originFromEye[5*i]=e.projection[5*i]=1;e.projection[10]=-1;}
 auto context=wvr_reconstruction_create_v1((__bridge void*)device);assert(context);assert(wvr_reconstruction_set_interval_v1(context,1)==0);
 auto submit=[&]{frame.status=-1;void*pointer=&frame;assert(reinterpret_cast<int(*)(void*)>(dxmt_winemetal_unix_call_funcs[146])(&pointer)==0);assert(frame.status==0&&frame.compositorTicket&&frame.consumerEvent);wvr_compositor_release_object_v1((void*)frame.consumerEvent);};
 auto run=[&]{WVRAcquiredStereoFrameV2 acquired{};acquired.structSize=sizeof(acquired);assert(wvr_compositor_acquire_latest_stereo_frame_v2(&acquired)==0);assert(acquired.producerFrameID==frame.frameID);
 WVRReconstructionSubmitV1 geometry{};geometry.abiVersion=WVR_RECONSTRUCTION_ABI;geometry.structSize=sizeof(geometry);assert(wvr_compositor_copy_reconstruction_v1(acquired.lease,&geometry)==0);assert(geometry.frameID==frame.frameID&&geometry.targetGeneration==targets.generation&&geometry.eyes[0].depthWidth==16);
 auto b=[queue commandBuffer];assert(wvr_reconstruction_validate_v1(context,acquired.lease,(__bridge void*)b)==0);[b commit];[b waitUntilCompleted];assert(b.status==MTLCommandBufferStatusCompleted);wvr_compositor_release_acquired_frame_v1(acquired.lease);};
 submit();run();verify(queue,context,0,0,false);
 // Temporal reconstruction from an owned snapshot, after the game reuses the same color image.
 frame.frameID=2;frame.timestampNanoseconds+=11111111;frame.eyes[0].originFromEye[12]=frame.eyes[1].originFromEye[12]=2.f/32;
 fill(left,1);fill(right,1,arrayMode?1:0);submit();run();verify(queue,context,0,1,false);verify(queue,context,1,1,true);
 // Stereo disocclusion remains explicitly invalid, rather than copied or fabricated detail.
 frame.frameID=3;frame.timestampNanoseconds+=11111111;frame.eyes[0].originFromEye[12]=0;frame.eyes[1].originFromEye[12]=2.f/32;fill(left,0);fill(right,1,arrayMode?1:0);submit();run();verify(queue,context,0,1,true);
 auto invalid=frame;invalid.eyes[0].depthSlice=9;assert(wvr_compositor_submit_reconstruction_v1(&invalid)!=0);
 invalid=frame;invalid.eyes[0].depthTexture=(uint64_t)(__bridge void*)left;assert(wvr_compositor_submit_reconstruction_v1(&invalid)!=0);
 invalid=frame;invalid.eyes[0].projection[0]=NAN;assert(wvr_compositor_submit_reconstruction_v1(&invalid)!=0);
 invalid=frame;invalid.targetGeneration++;assert(wvr_compositor_submit_reconstruction_v1(&invalid)!=0);
 invalid=frame;invalid.eyes[0].depthWidth=UINT32_MAX;assert(wvr_compositor_submit_reconstruction_v1(&invalid)!=0);
 char stats[2048];assert(wvr_reconstruction_copy_stats_v1(context,stats,sizeof(stats)));puts(stats);assert(strstr(stats,"failed=0")&&strstr(stats,"stereoCoverage=0.9688")&&strstr(stats,"motionVectors=unavailable"));
 frame.frameID=4;frame.timestampNanoseconds+=200000000;submit();run();
 assert(!wvr_reconstruction_copy_output_v1(context,1));
 assert(wvr_reconstruction_copy_stats_v1(context,stats,sizeof(stats)));assert(strstr(stats,"resets=2")&&strstr(stats,"temporalCoverage=0.0000"));
 WVRSubmitStereoFrameV2 legacyFrame{};legacyFrame.abiVersion=WVR_COMPOSITOR_ABI_VERSION_V2;legacyFrame.structSize=sizeof(legacyFrame);legacyFrame.targetGeneration=targets.generation;
 legacyFrame.producerFrameID=5;legacyFrame.producerTimestampNanoseconds=frame.timestampNanoseconds+11111111;legacyFrame.leftTexture=(__bridge void*)left;legacyFrame.rightTexture=(__bridge void*)right;legacyFrame.producerReadyEvent=(__bridge void*)event;legacyFrame.producerReadyValue=1;legacyFrame.rightSlice=arrayMode?1:0;legacyFrame.leftX=legacyFrame.rightX=arrayMode?2:0;legacyFrame.leftY=legacyFrame.rightY=arrayMode?3:0;legacyFrame.leftWidth=legacyFrame.rightWidth=32;legacyFrame.leftHeight=legacyFrame.rightHeight=16;uint64_t ticket=0;
 assert(wvr_compositor_submit_stereo_frame_v2(&legacyFrame,&ticket)==0);WVRAcquiredStereoFrameV2 legacyAcquired{};legacyAcquired.structSize=sizeof(legacyAcquired);assert(wvr_compositor_acquire_latest_stereo_frame_v2(&legacyAcquired)==0);
 auto absent=[queue commandBuffer];assert(wvr_reconstruction_validate_v1(context,legacyAcquired.lease,(__bridge void*)absent)==1);assert(!wvr_reconstruction_copy_output_v1(context,0)&&!wvr_reconstruction_copy_output_v1(context,1));wvr_compositor_release_acquired_frame_v1(legacyAcquired.lease);
 assert(wvr_reconstruction_copy_stats_v1(context,stats,sizeof(stats)));assert(strstr(stats,"missingDepth=1"));
 wvr_reconstruction_destroy_v1(context);wvr_compositor_pause_v1();
 puts("PASS: real Metal stereo and temporal depth reconstruction, deterministic holes, independent depth resolution, owned history after image reuse, exact lease identity and malformed/stale rejection");
}}
