#include "WindowsVRReconstruction.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#import <simd/simd.h>

namespace {
static NSString *const shader = @R"metal(
#include <metal_stdlib>
using namespace metal;
struct Params {
 float4x4 clipFromSource, viewFromSource;
 uint2 sourceSize,targetSize,sourceOrigin,depthOrigin,depthSize,targetOrigin;
 float2 depthRange; uint2 padding;
};
bool project(uint i, depth2d<float,access::read> depth, constant Params&p, thread uint&target,thread uint&key){
 if(i>=p.sourceSize.x*p.sourceSize.y)return false;
 uint2 s=uint2(i%p.sourceSize.x,i/p.sourceSize.x);
 float2 uv=(float2(s)+.5)/float2(p.sourceSize);
 uint2 ds=min(uint2(uv*float2(p.depthSize)),p.depthSize-1)+p.depthOrigin;
 float raw=depth.read(ds);
 if(!isfinite(raw)||raw<p.depthRange.x||raw>p.depthRange.y)return false;
 float d=(raw-p.depthRange.x)/(p.depthRange.y-p.depthRange.x);
 float4 c=float4(uv.x*2-1,1-uv.y*2,d,1);
 float4 clip=p.clipFromSource*c,view=p.viewFromSource*c;
 if(!all(isfinite(clip))||clip.w<=0)return false;
 float3 ndc=clip.xyz/clip.w;
 if(ndc.z<-.00001||ndc.z>1.00001)return false;
 float2 at=float2(ndc.x*.5+.5,.5-ndc.y*.5)*float2(p.targetSize);
 if(any(at<0)||any(at>=float2(p.targetSize)))return false;
 float distance=abs(view.w)<1e-10?INFINITY:-view.z/view.w;
 if(isnan(distance)||distance<=0)return false;
 uint2 pixel=uint2(at);target=pixel.y*p.targetSize.x+pixel.x;key=as_type<uint>(distance);return true;
}
kernel void clear_grid(device atomic_uint*z[[buffer(0)]],device atomic_uint*ids[[buffer(1)]],constant Params&p[[buffer(2)]],uint i[[thread_position_in_grid]]){
 if(i<p.targetSize.x*p.targetSize.y){atomic_store_explicit(z+i,0xffffffffu,memory_order_relaxed);atomic_store_explicit(ids+i,0xffffffffu,memory_order_relaxed);}
}
kernel void depth_grid(depth2d<float,access::read> depth[[texture(0)]],device atomic_uint*z[[buffer(0)]],constant Params&p[[buffer(2)]],uint i[[thread_position_in_grid]]){
 uint target,key;if(project(i,depth,p,target,key))atomic_fetch_min_explicit(z+target,key,memory_order_relaxed);
}
kernel void index_grid(depth2d<float,access::read> depth[[texture(0)]],device atomic_uint*z[[buffer(0)]],device atomic_uint*ids[[buffer(1)]],constant Params&p[[buffer(2)]],uint i[[thread_position_in_grid]]){
 uint target,key;if(project(i,depth,p,target,key)&&key==atomic_load_explicit(z+target,memory_order_relaxed))atomic_fetch_min_explicit(ids+target,i,memory_order_relaxed);
}
kernel void gather_color(texture2d<float,access::read> color[[texture(1)]],texture2d<float,access::write> output[[texture(2)]],device atomic_uint*ids[[buffer(1)]],constant Params&p[[buffer(2)]],uint2 at[[thread_position_in_grid]]){
 if(any(at>=p.targetSize))return;uint i=atomic_load_explicit(ids+at.y*p.targetSize.x+at.x,memory_order_relaxed);
 float4 c=0;if(i!=0xffffffffu){c=color.read(uint2(i%p.sourceSize.x,i/p.sourceSize.x)+p.sourceOrigin);c.a=1;}output.write(c,at);
}
kernel void measure(texture2d<float,access::read> output[[texture(2)]],texture2d<float,access::read> reference[[texture(3)]],device float4*metrics[[buffer(3)]],constant Params&p[[buffer(2)]],uint2 at[[thread_position_in_grid]],uint tid[[thread_index_in_threadgroup]],uint2 tile[[threadgroup_position_in_grid]]){
 threadgroup float errors[256];threadgroup uint valid[256],holes[256];
 bool inside=all(at<p.targetSize);float4 c=inside?output.read(at):float4(0);bool ok=inside&&c.a>.5;
 float3 delta=ok?c.rgb-reference.read(at+p.targetOrigin).rgb:float3(0);
 errors[tid]=dot(delta,delta)/3;valid[tid]=ok?1:0;holes[tid]=inside&&!ok?1:0;threadgroup_barrier(mem_flags::mem_threadgroup);
 for(uint stride=128;stride;stride>>=1){if(tid<stride){errors[tid]+=errors[tid+stride];valid[tid]+=valid[tid+stride];holes[tid]+=holes[tid+stride];}threadgroup_barrier(mem_flags::mem_threadgroup);}
 if(tid==0)metrics[tile.y*((p.targetSize.x+15)/16)+tile.x]=float4(errors[0],valid[0],holes[0],0);
}
)metal";
struct Params {
  simd_float4x4 clipFromSource, viewFromSource;
  simd_uint2 sourceSize, targetSize, sourceOrigin, depthOrigin, depthSize,
      targetOrigin;
  simd_float2 depthRange;
  simd_uint2 padding{};
};
static_assert(sizeof(Params) == 192);
struct Results {
  std::atomic<uint64_t> epoch{0};
  std::atomic<uint64_t> frames{0}, missing{0}, resets{0}, stereo{0},
      temporal{0}, completed{0}, failed{0};
  std::atomic<double> coverage[2]{}, mse[2]{};
};
struct History {
  __strong id<MTLTexture> color = nil, depth = nil;
  WVRReconstructionEyeV1 eye{};
  uint64_t frame = 0, time = 0, generation = 0;
};
struct Context {
  __strong id<MTLDevice> device = nil;
  __strong id<MTLCommandQueue> queue = nil;
  __strong id<MTLComputePipelineState> pipelines[5]{};
  __strong id<MTLTexture> outputs[2]{};
  std::shared_ptr<Results> results = std::make_shared<Results>();
  History history[2];
  unsigned next = 0, interval = 30;
  uint64_t sequence = 0;
  std::mutex mutex;
  bool valid = false;
  explicit Context(id<MTLDevice> d) : device(d) {
    NSError *error = nil;
    auto library = [d newLibraryWithSource:shader options:nil error:&error];
    const char *names[] = {"clear_grid", "depth_grid", "index_grid",
                           "gather_color", "measure"};
    if (!library) {
      NSLog(@"[reconstruction] shader library failed: %@", error);
      return;
    }
    for (unsigned i = 0; i < 5; ++i) {
      auto f = [library
          newFunctionWithName:[NSString stringWithUTF8String:names[i]]];
      pipelines[i] = [d newComputePipelineStateWithFunction:f error:&error];
      if (!pipelines[i]) {
        NSLog(@"[reconstruction] pipeline failed: %@", error);
        return;
      }
    }
    valid = true;
  }
};
id<MTLTexture> view(id<MTLTexture> t, uint32_t slice) {
  if (t.textureType == MTLTextureType2D)
    return slice ? nil : t;
  if (t.textureType != MTLTextureType2DArray || slice >= t.arrayLength)
    return nil;
  return [t newTextureViewWithPixelFormat:t.pixelFormat
                              textureType:MTLTextureType2D
                                   levels:NSMakeRange(0, 1)
                                   slices:NSMakeRange(slice, 1)];
}
simd_float4x4 matrix(const float *m) {
  simd_float4x4 result;
  std::memcpy(&result, m, sizeof(result));
  return result;
}
id<MTLTexture> texture(id<MTLDevice> d, MTLPixelFormat format, unsigned width,
                       unsigned height, MTLTextureUsage usage) {
  auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                 width:width
                                                                height:height
                                                             mipmapped:NO];
  desc.storageMode = MTLStorageModePrivate;
  desc.usage = usage;
  return [d newTextureWithDescriptor:desc];
}
bool encode(Context &ctx, id<MTLCommandBuffer> commands,
            const WVRReconstructionEyeV1 &source,
            const WVRReconstructionEyeV1 &target, unsigned kind) {
  const uint64_t count = uint64_t(target.width) * target.height;
  if (!count || count > 16777216 ||
      uint64_t(source.width) * source.height > 16777216)
    return false;
  auto color = view((__bridge id<MTLTexture>)(void *)source.colorTexture,
                    source.colorSlice);
  auto depth = view((__bridge id<MTLTexture>)(void *)source.depthTexture,
                    source.depthSlice);
  auto reference = view((__bridge id<MTLTexture>)(void *)target.colorTexture,
                        target.colorSlice);
  if (!color || !depth || !reference)
    return false;
  auto z = [ctx.device newBufferWithLength:count * 4
                                   options:MTLResourceStorageModePrivate];
  auto ids = [ctx.device newBufferWithLength:count * 4
                                     options:MTLResourceStorageModePrivate];
  auto output = texture(ctx.device, MTLPixelFormatRGBA16Float, target.width,
                        target.height,
                        MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite);
  const unsigned tilesX = (target.width + 15) / 16,
                 tilesY = (target.height + 15) / 16;
  auto metrics = [ctx.device
      newBufferWithLength:uint64_t(tilesX) * tilesY * sizeof(simd_float4)
                  options:MTLResourceStorageModeShared];
  if (!z || !ids || !output || !metrics)
    return false;
  Params p{};
  const auto sourceOrigin = matrix(source.originFromEye),
             targetView = simd_inverse(matrix(target.originFromEye));
  const auto inverseProjection = simd_inverse(matrix(source.projection));
  p.viewFromSource =
      simd_mul(simd_mul(targetView, sourceOrigin), inverseProjection);
  p.clipFromSource = simd_mul(matrix(target.projection), p.viewFromSource);
  p.sourceSize = {source.width, source.height};
  p.targetSize = {target.width, target.height};
  p.sourceOrigin = {source.colorX, source.colorY};
  p.depthOrigin = {source.depthX, source.depthY};
  p.depthSize = {source.depthWidth, source.depthHeight};
  p.targetOrigin = {target.colorX, target.colorY};
  p.depthRange = {source.minDepth, source.maxDepth};
  auto encoder = [commands computeCommandEncoder];
  if (!encoder)
    return false;
  [encoder setBuffer:z offset:0 atIndex:0];
  [encoder setBuffer:ids offset:0 atIndex:1];
  [encoder setBytes:&p length:sizeof(p) atIndex:2];
  [encoder setBuffer:metrics offset:0 atIndex:3];
  [encoder setTexture:depth atIndex:0];
  [encoder setTexture:color atIndex:1];
  [encoder setTexture:output atIndex:2];
  [encoder setTexture:reference atIndex:3];
  for (unsigned stage = 0; stage < 5; ++stage) {
    [encoder setComputePipelineState:ctx.pipelines[stage]];
    if (stage < 3) {
      uint64_t n = stage ? uint64_t(source.width) * source.height : count;
      [encoder dispatchThreads:MTLSizeMake(n, 1, 1)
          threadsPerThreadgroup:MTLSizeMake(256, 1, 1)];
    } else if (stage == 3)
      [encoder dispatchThreads:MTLSizeMake(target.width, target.height, 1)
          threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    else
      [encoder dispatchThreadgroups:MTLSizeMake(tilesX, tilesY, 1)
              threadsPerThreadgroup:MTLSizeMake(16, 16, 1)];
    [encoder memoryBarrierWithScope:MTLBarrierScopeBuffers |
                                    MTLBarrierScopeTextures];
  }
  [encoder endEncoding];
  ctx.outputs[kind] = output;
  auto results = ctx.results;
  const auto epoch = results->epoch.load();
  [commands addCompletedHandler:^(id<MTLCommandBuffer> b) {
    if (b.status != MTLCommandBufferStatusCompleted) {
      results->failed.fetch_add(1);
      return;
    }
    results->completed.fetch_add(1);
    if (results->epoch.load() != epoch)
      return;
    auto values = static_cast<const simd_float4 *>(metrics.contents);
    double error = 0, valid = 0, holes = 0;
    for (uint64_t i = 0; i < uint64_t(tilesX) * tilesY; ++i) {
      error += values[i].x;
      valid += values[i].y;
      holes += values[i].z;
    }
    results->coverage[kind].store(valid / (valid + holes));
    results->mse[kind].store(valid ? error / valid : 0);
  }];
  (kind ? ctx.results->temporal : ctx.results->stereo).fetch_add(1);
  return true;
}
bool snapshot(Context &ctx, id<MTLCommandBuffer> commands,
              const WVRReconstructionEyeV1 &source, History &slot) {
  auto color = view((__bridge id<MTLTexture>)(void *)source.colorTexture,
                    source.colorSlice);
  auto depth = view((__bridge id<MTLTexture>)(void *)source.depthTexture,
                    source.depthSlice);
  if (!color || !depth)
    return false;
  if (!slot.color || slot.color.width != source.width ||
      slot.color.height != source.height ||
      slot.color.pixelFormat != color.pixelFormat)
    slot.color = texture(ctx.device, color.pixelFormat, source.width,
                         source.height, MTLTextureUsageShaderRead);
  if (!slot.depth || slot.depth.width != source.depthWidth ||
      slot.depth.height != source.depthHeight)
    slot.depth = texture(ctx.device, depth.pixelFormat, source.depthWidth,
                         source.depthHeight, MTLTextureUsageShaderRead);
  if (!slot.color || !slot.depth)
    return false;
  auto blit = [commands blitCommandEncoder];
  if (!blit)
    return false;
  [blit copyFromTexture:color
            sourceSlice:0
            sourceLevel:0
           sourceOrigin:MTLOriginMake(source.colorX, source.colorY, 0)
             sourceSize:MTLSizeMake(source.width, source.height, 1)
              toTexture:slot.color
       destinationSlice:0
       destinationLevel:0
      destinationOrigin:MTLOriginMake(0, 0, 0)];
  [blit copyFromTexture:depth
            sourceSlice:0
            sourceLevel:0
           sourceOrigin:MTLOriginMake(source.depthX, source.depthY, 0)
             sourceSize:MTLSizeMake(source.depthWidth, source.depthHeight, 1)
              toTexture:slot.depth
       destinationSlice:0
       destinationLevel:0
      destinationOrigin:MTLOriginMake(0, 0, 0)];
  [blit endEncoding];
  slot.eye = source;
  slot.eye.colorTexture = (uint64_t)(__bridge void *)slot.color;
  slot.eye.depthTexture = (uint64_t)(__bridge void *)slot.depth;
  slot.eye.colorSlice = slot.eye.colorX = slot.eye.colorY =
      slot.eye.depthSlice = slot.eye.depthX = slot.eye.depthY = 0;
  return true;
}
} // namespace
extern "C" void *wvr_reconstruction_create_v1(void *device) {
  if (!device)
    return nullptr;
  auto ctx = std::make_unique<Context>((__bridge id<MTLDevice>)device);
  return ctx->valid ? ctx.release() : nullptr;
}
extern "C" void wvr_reconstruction_destroy_v1(void *context) {
  delete static_cast<Context *>(context);
}
extern "C" int32_t wvr_reconstruction_validate_v1(void *context, void *lease,
                                                  void *buffer) {
  if (!context || !lease || !buffer)
    return -1;
  auto &ctx = *static_cast<Context *>(context);
  auto commands = (__bridge id<MTLCommandBuffer>)buffer;
  WVRReconstructionSubmitV1 frame{};
  frame.abiVersion = WVR_RECONSTRUCTION_ABI;
  frame.structSize = sizeof(frame);
  if (wvr_compositor_copy_reconstruction_v1(lease, &frame) != 0) {
    std::lock_guard<std::mutex> lock(ctx.mutex);
    ctx.results->missing.fetch_add(1);
    ctx.results->epoch.fetch_add(1);
    if (ctx.history[0].color || ctx.history[1].color)
      ctx.results->resets.fetch_add(1);
    ctx.history[0] = History{};
    ctx.history[1] = History{};
    ctx.outputs[0] = ctx.outputs[1] = nil;
    ctx.next = 0;
    ctx.queue = nil;
    ctx.results->coverage[0].store(0);
    ctx.results->coverage[1].store(0);
    ctx.results->mse[0].store(0);
    ctx.results->mse[1].store(0);
    return 1;
  }
  std::lock_guard<std::mutex> lock(ctx.mutex);
  if (commands.device != ctx.device || !commands.retainedReferences)
    return -1;
  auto &previous = ctx.history[(ctx.next + 1) % 2];
  const bool reset = ctx.queue != commands.commandQueue ||
                     previous.generation != frame.targetGeneration ||
                     frame.frameID <= previous.frame ||
                     frame.timestampNanoseconds <= previous.time ||
                     frame.timestampNanoseconds - previous.time > 100000000;
  if (reset) {
    ctx.results->epoch.fetch_add(1);
    ctx.outputs[0] = ctx.outputs[1] = nil;
    ctx.results->coverage[1].store(0);
    ctx.results->mse[1].store(0);
    ctx.history[0] = History{};
    ctx.history[1] = History{};
    ctx.next = 0;
    ctx.results->resets.fetch_add(1);
  }
  ctx.queue = commands.commandQueue;
  [commands encodeWaitForEvent:(__bridge id<MTLSharedEvent>)(void *)
                                   frame.producerEvent
                         value:frame.producerValue];
  const bool measure = (ctx.sequence++ % ctx.interval) == 0;
  if (measure && !encode(ctx, commands, frame.eyes[0], frame.eyes[1], 0)) {
    ctx.results->failed.fetch_add(1);
    return -1;
  }
  if (measure && !reset && previous.color &&
      !encode(ctx, commands, previous.eye, frame.eyes[0], 1)) {
    ctx.results->failed.fetch_add(1);
    return -1;
  }
  auto &slot = ctx.history[ctx.next];
  if (!snapshot(ctx, commands, frame.eyes[0], slot)) {
    ctx.results->failed.fetch_add(1);
    return -1;
  }
  slot.frame = frame.frameID;
  slot.time = frame.timestampNanoseconds;
  slot.generation = frame.targetGeneration;
  ctx.next = (ctx.next + 1) % 2;
  ctx.results->frames.fetch_add(1);
  return 0;
}
extern "C" int32_t wvr_reconstruction_copy_stats_v1(void *context, char *buffer,
                                                    uint32_t capacity) {
  if (!context || !buffer || !capacity)
    return 0;
  auto &s = *static_cast<Context *>(context)->results;
  std::snprintf(
      buffer, capacity,
      "reconstruction mode=shadow frames=%llu missingDepth=%llu resets=%llu "
      "stereoJobs=%llu temporalJobs=%llu completed=%llu failed=%llu "
      "stereoCoverage=%.4f stereoMSE=%.6f temporalCoverage=%.4f "
      "temporalMSE=%.6f motionVectors=unavailable generatedDisplayFrames=0 "
      "transportRejected=%llu",
      (unsigned long long)s.frames.load(), (unsigned long long)s.missing.load(),
      (unsigned long long)s.resets.load(), (unsigned long long)s.stereo.load(),
      (unsigned long long)s.temporal.load(),
      (unsigned long long)s.completed.load(),
      (unsigned long long)s.failed.load(), s.coverage[0].load(),
      s.mse[0].load(), s.coverage[1].load(), s.mse[1].load(),
      (unsigned long long)wvr_reconstruction_transport_rejections_v1());
  return 1;
}

extern "C" void *wvr_reconstruction_copy_output_v1(void *context,
                                                   uint32_t kind) {
  if (!context || kind > 1)
    return nullptr;
  auto &ctx = *static_cast<Context *>(context);
  std::lock_guard<std::mutex> lock(ctx.mutex);
  return ctx.outputs[kind] ? (__bridge_retained void *)ctx.outputs[kind]
                           : nullptr;
}
extern "C" int32_t wvr_reconstruction_set_interval_v1(void *context,
                                                      uint32_t interval) {
  if (!context || !interval || interval > 120)
    return -1;
  auto &ctx = *static_cast<Context *>(context);
  std::lock_guard<std::mutex> lock(ctx.mutex);
  ctx.interval = interval;
  return 0;
}
