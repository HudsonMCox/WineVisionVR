#include "WindowsVRFrameState.h"
#include "WindowsVRReconstruction.h"
#include "WindowsVRTextureSliceCache.h"
#include "WindowsVRGuestFoveation.h"
#include "WindowsVRCompositorBridge.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <memory>
#include <mutex>
#include <unordered_map>

#if WVR_SOURCE_AIR_WRITER
#include "../shader-compiler/WindowsVRAIRWriter.h"
#endif

namespace {
using Dispatch = int (*)(void *);
Dispatch previousDispatch = nullptr;
std::atomic<bool> installed{false};
std::mutex stateMutex;
// GPU notifications publish monotonic event progress to a shared CPU page.
// Guest GetData polls this page rather than crossing Wine's Unix boundary.
static_assert(std::atomic<uint64_t>::is_always_lock_free &&
              sizeof(std::atomic<uint64_t>) == 8);
struct EventProgress {
  std::atomic<uint64_t> value{0};
  __strong id<MTLSharedEvent> event = nil;
  bool cancelled = false; // protected by progressMutex
};
std::mutex progressMutex;
std::unordered_map<uint64_t, std::shared_ptr<EventProgress>> progressPages;
std::atomic<uint64_t> nextProgressToken{1}, progressNotifications{0};
static void armProgress(std::shared_ptr<EventProgress> state) {
  id<MTLSharedEvent> event;
  uint64_t target;
  {
    std::lock_guard<std::mutex> lock(progressMutex);
    if (state->cancelled)
      return;
    event = state->event;
    target = state->value.load(std::memory_order_relaxed) + 1;
  }
  static MTLSharedEventListener *listener = [[MTLSharedEventListener alloc]
      initWithDispatchQueue:dispatch_queue_create(
                                "org.winevision.gpu-progress",
                                dispatch_queue_attr_make_with_qos_class(
                                    DISPATCH_QUEUE_SERIAL,
                                    QOS_CLASS_USER_INTERACTIVE, 0))];
  [event notifyListener:listener
                atValue:target
                  block:^(id<MTLSharedEvent> completed, uint64_t) {
                    {
                      std::lock_guard<std::mutex> lock(progressMutex);
                      if (state->cancelled)
                        return;
                      // Only a real Metal event value can publish completion.
                      // Command-buffer completion is not substituted for a
                      // mid-buffer query signal.
                      state->value.store(completed.signaledValue,
                                         std::memory_order_release);
                      ++progressNotifications;
                    }
                    armProgress(state);
                  }];
}
struct EyeMap {
  __strong id<MTLRasterizationRateMap> map = nil;
  uint32_t layer = 0;
  double published = 0;
};
std::array<EyeMap, 2> eyeMaps;
struct EyeTarget {
  __strong id<MTLTexture> root = nil;
  uint32_t role = 0, slice = 0, eyeWidth = 0, eyeHeight = 0;
  bool atlas = false;
  __strong id<MTLTexture> scratchColor[8] = {}, scratchDepth = nil;
  __strong id<MTLRasterizationRateMap> sourceMap = nil, adaptedMap = nil,
                                       rightSourceMap = nil;
  __strong id<MTLBuffer> parameters = nil;
  uint32_t mapLayer = 0, rightMapLayer = 0;
};
std::array<EyeTarget, 64> targets;
size_t nextTarget = 0;
std::atomic<uint64_t> sceneDraws{0}, logicalArea{0}, mappedArea{0},
    unmatchedTargets{0}, staleMaps{0}, atlasBegun{0}, bridgeCalls{0},
    capabilities{0}, uniformBindings{0};
std::atomic<uint64_t> sliceViewHits{0}, sliceViewCreates{0};
std::atomic<uint64_t> begun{0}, resolved{0}, rejected{0}, nextToken{1},
    mapAdaptations{0}, mapAdaptNanoseconds{0};
__strong id<MTLLibrary> resolveLibrary = nil;
__strong id<MTLBuffer> identityParameters = nil;
__strong id<MTLSamplerState> linearSampler = nil, pointSampler = nil;
__strong id<MTLDepthStencilState> resolveStates[2][4] = {};
__strong NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *pipelines;

id<MTLTexture> rootTexture(id<MTLTexture> texture,
                           NSUInteger *slice = nullptr) {
  while (texture.parentTexture) {
    if (slice)
      *slice += texture.parentRelativeSlice;
    if (texture.parentRelativeLevel)
      return nil;
    texture = texture.parentTexture;
  }
  return texture;
}
id<MTLTexture> singleSlice(id<MTLTexture> texture, uint32_t slice) {
  if (!texture)
    return nil;
  if (texture.textureType == MTLTextureType2D)
    return slice ? nil : texture;
  if (texture.textureType != MTLTextureType2DArray ||
      slice >= texture.arrayLength)
    return nil;
  thread_local WVRTextureSliceCache cache;
  bool hit = false;
  auto view = cache.get(texture, slice, &hit);
  if (view) (hit ? sliceViewHits : sliceViewCreates).fetch_add(1, std::memory_order_relaxed);
  return view;
}

// Adapt the system's separable rate functions in normalized screen space.
// Conservative neighboring maxima widen high-quality regions; no gaze point is
// reconstructed, persisted or exposed. The original system map stays immutable.
id<MTLRasterizationRateMap> adaptMap(id<MTLRasterizationRateMap> source,
                                     NSUInteger layer, NSUInteger width,
                                     NSUInteger height) {
  if (!source || layer >= source.layerCount || !width || !height)
    return nil;
  constexpr unsigned count = 32;
  float x[count], y[count], sx[count], sy[count];
  const auto screen = source.screenSize;
  if (!screen.width || !screen.height)
    return nil;
  const auto started = std::chrono::steady_clock::now();
  auto maximumRate = [&](bool horizontal, float begin, float end) {
    auto coordinate = [&](float at) {
      const auto p = [source
          mapScreenToPhysicalCoordinates:(MTLCoordinate2D){horizontal ? at : 0,
                                                           horizontal ? 0 : at}
                                forLayer:layer];
      return horizontal ? p.x : p.y;
    };
    float rate = 0.125f, previous = coordinate(begin);
    // A cell-average slope can hide a small full-rate region. Inspect
    // unit logical intervals, retaining the maximum rather than the mean.
    for (float at = begin; at < end;) {
      const float next = std::min(at + 1.0f, end), physical = coordinate(next);
      rate = std::max(rate, (physical - previous) / (next - at));
      previous = physical;
      at = next;
    }
    return std::clamp(rate, 0.125f, 1.0f);
  };
  for (unsigned i = 0; i < count; ++i) {
    sx[i] = maximumRate(true, float(i) * screen.width / count,
                        float(i + 1) * screen.width / count);
    sy[i] = maximumRate(false, float(i) * screen.height / count,
                        float(i + 1) * screen.height / count);
  }
  for (unsigned i = 0; i < count; ++i) {
    const unsigned lo = i ? i - 1 : 0, hi = std::min(i + 1, count - 1);
    x[i] = std::min(1.0f, std::ceil(std::max({sx[lo], sx[i], sx[hi]}) * 8) / 8);
    y[i] = std::min(1.0f, std::ceil(std::max({sy[lo], sy[i], sy[hi]}) * 8) / 8);
  }
  auto rates = [[MTLRasterizationRateLayerDescriptor alloc]
      initWithSampleCount:MTLSizeMake(count, count, 1)
               horizontal:x
                 vertical:y];
  auto descriptor = [MTLRasterizationRateMapDescriptor
      rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(width, height, 1)
                                             layer:rates];
  auto result =
      [source.device newRasterizationRateMapWithDescriptor:descriptor];
  mapAdaptations.fetch_add(1);
  mapAdaptNanoseconds.fetch_add(
      std::chrono::duration_cast<std::chrono::nanoseconds>(
          std::chrono::steady_clock::now() - started)
          .count());
  return result;
}

const char *shader = R"MSL(
#include <metal_stdlib>
using namespace metal;
struct V { float4 position [[position]]; };
vertex V wvr_fov_resolve_vertex(uint id [[vertex_id]]) {
    const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};
    return {float4(p[id],0,1)};
}
float2 sourceUV(float2 screen, constant rasterization_rate_map_data &data, uint2 size, uint4 physicalSize) {
    rasterization_rate_map_decoder decoder(data);
    float2 pixel = clamp(decoder.map_screen_to_physical_coordinates(screen,0),float2(0.5),float2(physicalSize.xy)-0.5);
    if (physicalSize.z) pixel.x = screen.x < physicalSize.z ? min(pixel.x, float(physicalSize.w)-0.5) : max(pixel.x,float(physicalSize.w)+0.5);
    return pixel/float2(size);
}
fragment float4 wvr_fov_resolve_color(V in [[stage_in]], texture2d<float> color [[texture(0)]],
    sampler linearClamp [[sampler(0)]], constant rasterization_rate_map_data &map [[buffer(0)]],constant uint4 &physicalSize [[buffer(1)]]) {
    return color.sample(linearClamp,sourceUV(in.position.xy,map,uint2(color.get_width(),color.get_height()),physicalSize));
}
struct O { float4 color [[color(0)]]; float depth [[depth(any)]]; };
fragment O wvr_fov_resolve_depth(V in [[stage_in]],texture2d<float> color [[texture(0)]],depth2d<float> depth [[texture(1)]],
    sampler linearClamp [[sampler(0)]],sampler pointClamp [[sampler(1)]],constant rasterization_rate_map_data &map [[buffer(0)]],constant uint4 &physicalSize [[buffer(1)]]) {
    float2 uv=sourceUV(in.position.xy,map,uint2(color.get_width(),color.get_height()),physicalSize);
    float2 depthUV=sourceUV(in.position.xy,map,uint2(depth.get_width(),depth.get_height()),physicalSize);
    return {color.sample(linearClamp,uv),depth.sample(pointClamp,depthUV)};
}
float2 uniformUV(float2 physical, constant rasterization_rate_map_data &data, uint2 size, uint4 bounds) {
    rasterization_rate_map_decoder decoder(data);
    float2 pixel = clamp(decoder.map_physical_to_screen_coordinates(physical,0),float2(0.5),float2(size)-0.5);
    if (bounds.z) pixel.x = physical.x < bounds.w ? min(pixel.x,float(bounds.z)-0.5) : max(pixel.x,float(bounds.z)+0.5);
    return pixel/float2(size);
}
fragment float4 wvr_fov_load_color(V in [[stage_in]], texture2d<float> color [[texture(0)]],
    sampler linearClamp [[sampler(0)]],constant rasterization_rate_map_data &map [[buffer(0)]],constant uint4 &bounds [[buffer(1)]]) {
    return color.sample(linearClamp,uniformUV(in.position.xy,map,uint2(color.get_width(),color.get_height()),bounds));
}
fragment O wvr_fov_load_depth(V in [[stage_in]],texture2d<float> color [[texture(0)]],depth2d<float> depth [[texture(1)]],
    sampler linearClamp [[sampler(0)]],sampler pointClamp [[sampler(1)]],constant rasterization_rate_map_data &map [[buffer(0)]],constant uint4 &bounds [[buffer(1)]]) {
    return {color.sample(linearClamp,uniformUV(in.position.xy,map,uint2(color.get_width(),color.get_height()),bounds)),
            depth.sample(pointClamp,uniformUV(in.position.xy,map,uint2(depth.get_width(),depth.get_height()),bounds))};
}
struct S { float4 color [[color(0)]]; float depth [[depth(any)]]; uint stencil [[stencil]]; };
fragment S wvr_fov_resolve_stencil(V in [[stage_in]],texture2d<float> color [[texture(0)]],depth2d<float> depth [[texture(1)]],texture2d<uint> stencil [[texture(2)]],sampler linearClamp [[sampler(0)]],sampler pointClamp [[sampler(1)]],constant rasterization_rate_map_data &map [[buffer(0)]],constant uint4 &physicalSize [[buffer(1)]]) {
    rasterization_rate_map_decoder decoder(map);
    uint2 pixel=uint2(sourceUV(in.position.xy,map,uint2(stencil.get_width(),stencil.get_height()),physicalSize)*float2(stencil.get_width(),stencil.get_height()));
    return {color.sample(linearClamp,sourceUV(in.position.xy,map,uint2(color.get_width(),color.get_height()),physicalSize)),depth.sample(pointClamp,sourceUV(in.position.xy,map,uint2(depth.get_width(),depth.get_height()),physicalSize)),stencil.read(pixel).r};
}
fragment S wvr_fov_load_stencil(V in [[stage_in]],texture2d<float> color [[texture(0)]],depth2d<float> depth [[texture(1)]],texture2d<uint> stencil [[texture(2)]],sampler linearClamp [[sampler(0)]],sampler pointClamp [[sampler(1)]],constant rasterization_rate_map_data &map [[buffer(0)]],constant uint4 &bounds [[buffer(1)]]) {
    rasterization_rate_map_decoder decoder(map);
    uint2 pixel=uint2(uniformUV(in.position.xy,map,uint2(stencil.get_width(),stencil.get_height()),bounds)*float2(stencil.get_width(),stencil.get_height()));
    return {color.sample(linearClamp,uniformUV(in.position.xy,map,uint2(color.get_width(),color.get_height()),bounds)),depth.sample(pointClamp,uniformUV(in.position.xy,map,uint2(depth.get_width(),depth.get_height()),bounds)),stencil.read(pixel).r};
}
)MSL";

// A side-by-side stereo atlas has one shared vertical rate function. Use the
// maximum required by either eye at every row, and keep each eye's horizontal
// rates independently. This is conservative for both system-supplied maps.
static id<MTLRasterizationRateMap> adaptStereoAtlas(const EyeMap &left,
                                                    const EyeMap &right,
                                                    NSUInteger width,
                                                    NSUInteger height) {
  auto l = adaptMap(left.map, left.layer, width, height);
  auto r = adaptMap(right.map, right.layer, width, height);
  if (!l || !r)
    return nil;
  float x[64], y[32];
  auto slope = [](id<MTLRasterizationRateMap> m, bool horizontal, unsigned cell,
                  NSUInteger extent) {
    float a = float(cell) * extent / 32, b = float(cell + 1) * extent / 32;
    auto p =
        [m mapScreenToPhysicalCoordinates:(MTLCoordinate2D){horizontal ? a : 0,
                                                            horizontal ? 0 : a}
                                 forLayer:0];
    auto q =
        [m mapScreenToPhysicalCoordinates:(MTLCoordinate2D){horizontal ? b : 0,
                                                            horizontal ? 0 : b}
                                 forLayer:0];
    return std::clamp(
        std::ceil(((horizontal ? q.x - p.x : q.y - p.y) / (b - a)) * 8) / 8,
        0.125f, 1.0f);
  };
  for (unsigned i = 0; i < 32; ++i) {
    x[i] = slope(l, true, i, width);
    x[i + 32] = slope(r, true, i, width);
    y[i] = std::max(slope(l, false, i, height), slope(r, false, i, height));
  }
  // Keep a full-rate filter guard at texture edges and the eye boundary.
  // This prevents reconstruction footprints from straddling independently
  // rasterized viewports or Metal's physical edge padding.
  x[0] = x[31] = x[32] = x[63] = 1.0f;
  y[0] = y[31] = 1.0f;
  auto layer = [[MTLRasterizationRateLayerDescriptor alloc]
      initWithSampleCount:MTLSizeMake(64, 32, 1)
               horizontal:x
                 vertical:y];
  auto descriptor = [MTLRasterizationRateMapDescriptor
      rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(width * 2,
                                                               height, 1)
                                             layer:layer];
  return [left.map.device newRasterizationRateMapWithDescriptor:descriptor];
}

struct Pass {
  __strong id<MTLCommandBuffer> commands;
  __strong id<MTLTexture> color[8] = {}, compressedColor[8] = {}, depth = nil,
                          compressedDepth = nil;
  __strong id<MTLTexture> stencilSource = nil, compressedStencil = nil;
  bool stencil = false, atlas = false;
  __strong id<MTLRenderCommandEncoder> encoder = nil;
  __strong id<MTLFence> chain = nil;
  __strong MTLRenderPassDescriptor *scene = nil;
  WVRGuestFoveationPassV1 request{};
  unsigned colorCount = 0;
  int firstPreload = -1;
  __strong id<MTLRasterizationRateMap> map;
  __strong id<MTLBuffer> parameters;
  __strong id<MTLRenderPipelineState> pipeline[8] = {}, loadPipeline[8] = {};
  uint64_t token = 0;
};
thread_local std::unique_ptr<Pass> activePass;

id<MTLRenderPipelineState> pipelineFor(id<MTLDevice> device,
                                       MTLPixelFormat color, bool depth,
                                       bool load = false,
                                       bool stencil = false) {
  // stateMutex protects the cache and shader/sampler publication.
  if (!resolveLibrary) {
    NSError *error = nil;
    resolveLibrary = [device newLibraryWithSource:@(shader)
                                          options:nil
                                            error:&error];
    if (!resolveLibrary) {
      NSLog(@"[guest-foveation] resolve shader failed: %@", error);
      return nil;
    }
    pipelines = [NSMutableDictionary new];
    MTLSamplerDescriptor *sampler = [MTLSamplerDescriptor new];
    sampler.sAddressMode = sampler.tAddressMode =
        MTLSamplerAddressModeClampToEdge;
    sampler.minFilter = sampler.magFilter = MTLSamplerMinMagFilterLinear;
    linearSampler = [device newSamplerStateWithDescriptor:sampler];
    sampler.minFilter = sampler.magFilter = MTLSamplerMinMagFilterNearest;
    pointSampler = [device newSamplerStateWithDescriptor:sampler];
    for (unsigned hasStencil = 0; hasStencil < 2; ++hasStencil)
      for (unsigned mask = 0; mask < 4; ++mask) {
        auto depth = [MTLDepthStencilDescriptor new];
        depth.depthCompareFunction = MTLCompareFunctionAlways;
        depth.depthWriteEnabled = !(mask & 1);
        if (hasStencil) {
          auto stencil = [MTLStencilDescriptor new];
          stencil.stencilCompareFunction = MTLCompareFunctionAlways;
          stencil.depthStencilPassOperation = MTLStencilOperationReplace;
          stencil.writeMask = (mask & 2) ? 0 : 0xff;
          depth.frontFaceStencil = depth.backFaceStencil = stencil;
        }
        resolveStates[hasStencil][mask] =
            [device newDepthStencilStateWithDescriptor:depth];
      }
  }
  NSNumber *key = @((uint64_t(color) << 3) | (uint64_t(stencil) << 2) |
                    (uint64_t(load) << 1) | depth);
  if (pipelines[key])
    return pipelines[key];
  auto descriptor = [MTLRenderPipelineDescriptor new];
  descriptor.vertexFunction =
      [resolveLibrary newFunctionWithName:@"wvr_fov_resolve_vertex"];
  descriptor.fragmentFunction = [resolveLibrary
      newFunctionWithName:stencil
                              ? (load ? @"wvr_fov_load_stencil"
                                      : @"wvr_fov_resolve_stencil")
                              : (load ? (depth ? @"wvr_fov_load_depth"
                                               : @"wvr_fov_load_color")
                                      : (depth ? @"wvr_fov_resolve_depth"
                                               : @"wvr_fov_resolve_color"))];
  descriptor.colorAttachments[0].pixelFormat = color;
  descriptor.depthAttachmentPixelFormat =
      depth ? (stencil ? MTLPixelFormatDepth32Float_Stencil8
                       : MTLPixelFormatDepth32Float)
            : MTLPixelFormatInvalid;
  descriptor.stencilAttachmentPixelFormat =
      stencil ? MTLPixelFormatDepth32Float_Stencil8 : MTLPixelFormatInvalid;
  NSError *error = nil;
  auto result = [device newRenderPipelineStateWithDescriptor:descriptor
                                                       error:&error];
  if (result)
    pipelines[key] = result;
  else
    NSLog(@"[guest-foveation] resolve pipeline failed: %@", error);
  return result;
}

int bridgeDispatch(void *opaque) {
  ++bridgeCalls;
  if (!opaque)
    return previousDispatch ? previousDispatch(opaque) : int(0xc0000141);
  auto request = *reinterpret_cast<WVRGuestFoveationPassV1 **>(opaque);
  if (request && request->abiVersion == WVR_FRAME_STATE_ABI) {
    auto frameState = reinterpret_cast<WVRFrameStateRequestV1 *>(request);
    frameState->status = wvr_compositor_frame_state_v1(frameState);
    return 0;
  }
  if (request && request->abiVersion == WVR_RECONSTRUCTION_ABI) {
    auto frame = reinterpret_cast<WVRReconstructionSubmitV1*>(request);
    frame->status = wvr_compositor_submit_reconstruction_v1(frame);
    return 0;
  }
  if (!request || request->abiVersion != WVR_GUEST_FOVEATION_ABI)
    return previousDispatch ? previousDispatch(opaque) : int(0xc0000141);
  wvr_guest_foveation_process_v1(request);
  return 0;
}
} // namespace

extern "C" int wvr_guest_foveation_install_v1(void) {
#if !WVR_SOURCE_AIR_WRITER && !WVR_GUEST_FOVEATION_TEST
  return 0; // Never enable guest coordinate changes without the matching
            // writer.
#endif
  if (installed.load())
    return 1;
  auto table = static_cast<void **>(
      dlsym(RTLD_DEFAULT, "dxmt_winemetal_unix_call_funcs"));
  auto count = reinterpret_cast<size_t (*)()>(
      dlsym(RTLD_DEFAULT, "wvr_dxmt_d3d12_unix_call_count_v1"));
  auto abi = reinterpret_cast<unsigned (*)()>(
      dlsym(RTLD_DEFAULT, "wvr_dxmt_d3d12_transport_abi_v1"));
  if (!table || !count || count() != 148 || !abi || abi() != 1 || !table[146])
    return 0;
  std::lock_guard<std::mutex> lock(stateMutex);
  if (installed.load())
    return 1;
  auto device = MTLCreateSystemDefaultDevice();
  if (!device || ![device supportsRasterizationRateMapWithLayerCount:1])
    return 0;
  for (auto format : {MTLPixelFormatBGRA8Unorm, MTLPixelFormatBGRA8Unorm_sRGB,
                      MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm_sRGB,
                      MTLPixelFormatRGBA16Float}) {
    if (!pipelineFor(device, format, false) ||
        !pipelineFor(device, format, true) ||
        !pipelineFor(device, format, false, true) ||
        !pipelineFor(device, format, true, true) ||
        !pipelineFor(device, format, true, false, true) ||
        !pipelineFor(device, format, true, true, true))
      return 0;
  }
  float fullRate = 1.0f;
  auto layer = [[MTLRasterizationRateLayerDescriptor alloc]
      initWithSampleCount:MTLSizeMake(1, 1, 1)
               horizontal:&fullRate
                 vertical:&fullRate];
  auto identity = [device
      newRasterizationRateMapWithDescriptor:
          [MTLRasterizationRateMapDescriptor
              rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(16384,
                                                                       16384, 1)
                                                     layer:layer]];
  if (!identity)
    return 0;
  identityParameters =
      [device newBufferWithLength:identity.parameterBufferSizeAndAlign.size
                          options:MTLResourceStorageModeShared];
  if (!identityParameters)
    return 0;
  [identity copyParameterDataToBuffer:identityParameters offset:0];
#if WVR_SOURCE_AIR_WRITER
  if (wvr_air_foveation_abi_v1() != 1)
    return 0;
#endif
  previousDispatch = reinterpret_cast<Dispatch>(table[146]);
  table[146] = reinterpret_cast<void *>(bridgeDispatch);
#if WVR_SOURCE_AIR_WRITER
  wvr_air_enable_foveation_v1();
#endif
  installed.store(true);
  return 1;
}
extern "C" void wvr_guest_foveation_reset_v1(void) {
  std::lock_guard<std::mutex> lock(stateMutex);
  eyeMaps = {};
  targets = {};
  nextTarget = 0;
}
extern "C" void wvr_guest_foveation_publish_maps_v1(void *left,
                                                    uint32_t leftLayer,
                                                    void *right,
                                                    uint32_t rightLayer) {
  std::lock_guard<std::mutex> lock(stateMutex);
  eyeMaps[0] = {(__bridge id<MTLRasterizationRateMap>)left, leftLayer,
                CACurrentMediaTime()};
  eyeMaps[1] = {(__bridge id<MTLRasterizationRateMap>)right, rightLayer,
                CACurrentMediaTime()};
}
extern "C" void wvr_guest_foveation_register_eye_v1(uint32_t role, void *opaque,
                                                    uint32_t slice, uint32_t x,
                                                    uint32_t y, uint32_t width,
                                                    uint32_t height) {
  if (role > 1 || !opaque || y)
    return;
  id<MTLTexture> texture = (__bridge id<MTLTexture>)opaque;
  NSUInteger absoluteSlice = slice;
  auto root = rootTexture(texture, &absoluteSlice);
  if (!root ||
      (root.textureType != MTLTextureType2D &&
       root.textureType != MTLTextureType2DArray) ||
      absoluteSlice >= root.arrayLength || !width || texture.height != height ||
      !((x == 0 && texture.width == width) ||
        (texture.width == uint64_t(width) * 2 && x == uint64_t(role) * width)))
    return;
  std::lock_guard<std::mutex> lock(stateMutex);
  for (auto &entry : targets)
    if (entry.root == root && entry.slice == absoluteSlice &&
        entry.role == role && entry.eyeWidth == width &&
        entry.eyeHeight == height) {
      entry.role = role;
      return;
    }
  targets[nextTarget] = {};
  targets[nextTarget].root = root;
  targets[nextTarget].role = role;
  targets[nextTarget].slice = uint32_t(absoluteSlice);
  targets[nextTarget].eyeWidth = width;
  targets[nextTarget].eyeHeight = height;
  targets[nextTarget].atlas = texture.width != width;
  nextTarget = (nextTarget + 1) % targets.size();
}
// The first preload encoder receives DXMT's original dependency waits. Later
// preload/resolve encoders are explicitly chained so an update on the final
// encoder covers every attachment, including untracked guest resources.
static id<MTLRenderCommandEncoder> preloadEncoder(Pass &pass, unsigned index) {
  auto d = [MTLRenderPassDescriptor new];
  d.rasterizationRateMap = pass.map;
  d.colorAttachments[0].texture = pass.compressedColor[index];
  d.colorAttachments[0].loadAction = MTLLoadActionDontCare;
  d.colorAttachments[0].storeAction = MTLStoreActionStore;
  if (int(index) == pass.firstPreload && pass.depth &&
      (pass.request.depthLoad == MTLLoadActionLoad ||
       (pass.stencil && pass.request.stencilLoad == MTLLoadActionLoad))) {
    d.depthAttachment.texture = pass.compressedDepth;
    d.depthAttachment.loadAction = MTLLoadActionDontCare;
    d.depthAttachment.storeAction = MTLStoreActionStore;
    if (pass.stencil) {
      d.stencilAttachment.texture = pass.compressedDepth;
      d.stencilAttachment.loadAction = MTLLoadActionDontCare;
      d.stencilAttachment.storeAction = MTLStoreActionStore;
    }
  }
  return [pass.commands renderCommandEncoderWithDescriptor:d];
}
static void encodeCopy(Pass &pass, id<MTLRenderCommandEncoder> encoder,
                       unsigned index, bool load, bool depth) {
  [encoder setRenderPipelineState:load ? pass.loadPipeline[index]
                                       : pass.pipeline[index]];
  if (depth)
    [encoder
        setDepthStencilState:
            resolveStates[pass.stencil ? 1 : 0]
                         [load ? 0
                               : (pass.request.depthStencilReadOnlyMask & 3)]];
  [encoder
      setFragmentTexture:load ? pass.color[index] : pass.compressedColor[index]
                 atIndex:0];
  if (depth)
    [encoder setFragmentTexture:load ? pass.depth : pass.compressedDepth
                        atIndex:1];
  if (depth && pass.stencil)
    [encoder
        setFragmentTexture:load ? pass.stencilSource : pass.compressedStencil
                   atIndex:2];
  [encoder setFragmentSamplerState:linearSampler atIndex:0];
  [encoder setFragmentSamplerState:pointSampler atIndex:1];
  [encoder setFragmentBuffer:pass.parameters offset:0 atIndex:0];
  const auto physical = [pass.map physicalSizeForLayer:0];
  const auto seam = [pass.map
      mapScreenToPhysicalCoordinates:(MTLCoordinate2D){
                                         float(pass.request.width / 2), 0}
                            forLayer:0];
  const auto logicalEnd =
      [pass.map mapScreenToPhysicalCoordinates:(MTLCoordinate2D){
                                                   float(pass.request.width),
                                                   float(pass.request.height)}
                                      forLayer:0];
  // physicalSizeForLayer includes tile padding that the scene never rasterizes.
  // Clamp reconstruction to pixel centers actually covered by the logical
  // image.
  uint32_t bounds[4] = {uint32_t(std::round(logicalEnd.x)),
                        uint32_t(std::round(logicalEnd.y)),
                        pass.atlas ? pass.request.width / 2 : 0,
                        pass.atlas ? uint32_t(std::round(seam.x)) : 0};
  [encoder setFragmentBytes:bounds length:sizeof(bounds) atIndex:1];
  [encoder setViewport:(MTLViewport){0, 0, double(pass.request.width),
                                     double(pass.request.height), 0, 1}];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}
extern "C" int wvr_guest_foveation_process_v1(WVRGuestFoveationPassV1 *r) {
  if (!r || r->abiVersion != WVR_GUEST_FOVEATION_ABI ||
      r->structSize != sizeof(*r))
    return -1;
  const auto suppliedEncoder = r->encoder;
  r->status = -1;
  r->encoder = 0;
  if (r->operation == 5) {
    if (!installed.load() || !r->colorTexture)
      return -1;
    auto state = std::make_shared<EventProgress>();
    state->event = (__bridge id<MTLSharedEvent>)(void *)r->colorTexture;
    state->value.store(state->event.signaledValue, std::memory_order_release);
    const uint64_t ticket = nextProgressToken.fetch_add(1);
    {
      std::lock_guard<std::mutex> lock(progressMutex);
      progressPages.emplace(ticket, state);
    }
    armProgress(state);
    r->encoder = (uint64_t)&state->value;
    r->token = ticket;
    r->status = 0;
    return 0;
  }
  if (r->operation == 6) {
    std::lock_guard<std::mutex> lock(progressMutex);
    const uint64_t ticket =
        r->token; // packed transport must not bind an aligned reference
    auto entry = progressPages.find(ticket);
    if (entry == progressPages.end())
      return -1;
    entry->second->cancelled = true;
    // Break the event -> notification block -> state -> event ownership cycle,
    // including cancellation before the next GPU signal ever occurs.
    entry->second->event = nil;
    progressPages.erase(entry);
    r->status = 0;
    return 0;
  }
  if (r->operation == 3) {
    if (!suppliedEncoder || !identityParameters)
      return -1;
    auto encoder =
        (__bridge id<MTLRenderCommandEncoder>)(void *)suppliedEncoder;
    [encoder setFragmentBuffer:identityParameters offset:0 atIndex:28];
    r->encoder = suppliedEncoder;
    ++uniformBindings;
    r->status = 0;
    return 0;
  }
  if (!r->operation) {
    ++capabilities;
    // Borrowed process-lifetime handle. The guest batches this binding with
    // its existing encoder setup instead of dispatching operation 3 per pass.
    r->encoder = (uint64_t)(__bridge void *)identityParameters;
    r->status = installed.load() && identityParameters ? 0 : -1;
    return r->status;
  }
  if (r->operation == 4) {
    if (!activePass || activePass->token != r->token)
      return -1;
    auto &pass = *activePass;
    if (pass.firstPreload >= 0) {
      bool first = true;
      for (unsigned index = 0; index < pass.colorCount; ++index) {
        if (!pass.color[index])
          continue;
        const auto load = index ? pass.request.additionalColors[index - 1].load
                                : pass.request.colorLoad;
        if (load != MTLLoadActionLoad && int(index) != pass.firstPreload)
          continue;
        auto encoder = first ? pass.encoder : preloadEncoder(pass, index);
        if (!encoder) {
          wvr_compositor_request_session_exit_v1();
          return -1;
        }
        if (!first)
          [encoder waitForFence:pass.chain
                   beforeStages:MTLRenderStageVertex | MTLRenderStageFragment];
        encodeCopy(pass, encoder, index, true,
                   int(index) == pass.firstPreload && pass.depth &&
                       (pass.request.depthLoad == MTLLoadActionLoad ||
                        (pass.stencil &&
                         pass.request.stencilLoad == MTLLoadActionLoad)));
        [encoder updateFence:pass.chain afterStages:MTLRenderStageFragment];
        [encoder endEncoding];
        first = false;
      }
      pass.encoder =
          [pass.commands renderCommandEncoderWithDescriptor:pass.scene];
      if (!pass.encoder) {
        wvr_compositor_request_session_exit_v1();
        return -1;
      }
      [pass.encoder waitForFence:pass.chain
                    beforeStages:MTLRenderStageVertex | MTLRenderStageFragment];
      pass.firstPreload = -1;
    }
    [pass.encoder setFragmentBuffer:pass.parameters offset:0 atIndex:28];
    r->encoder = (uint64_t)(__bridge void *)pass.encoder;
    r->status = 0;
    return 0;
  }
  if (r->operation == 2) {
    if (!activePass || activePass->token != r->token ||
        activePass->firstPreload >= 0)
      return -1;
    auto pass = std::move(activePass);
    int last = -1;
    for (unsigned i = 0; i < pass->colorCount; ++i)
      if (pass->color[i])
        last = int(i);
    bool first = true;
    for (unsigned index = 0; index < pass->colorCount; ++index) {
      if (!pass->color[index])
        continue;
      auto d = [MTLRenderPassDescriptor new];
      d.colorAttachments[0].texture = pass->color[index];
      d.colorAttachments[0].loadAction = MTLLoadActionDontCare;
      d.colorAttachments[0].storeAction = MTLStoreActionStore;
      bool includeDepth = first && pass->depth;
      if (includeDepth) {
        d.depthAttachment.texture = pass->depth;
        d.depthAttachment.loadAction =
            (pass->request.depthStencilReadOnlyMask & 1)
                ? MTLLoadActionLoad
                : MTLLoadActionDontCare;
        d.depthAttachment.storeAction = MTLStoreActionStore;
        if (pass->stencil) {
          d.stencilAttachment.texture = pass->depth;
          d.stencilAttachment.loadAction =
              (pass->request.depthStencilReadOnlyMask & 2)
                  ? MTLLoadActionLoad
                  : MTLLoadActionDontCare;
          d.stencilAttachment.storeAction = MTLStoreActionStore;
        }
      }
      auto encoder = [pass->commands renderCommandEncoderWithDescriptor:d];
      if (!encoder) {
        wvr_compositor_request_session_exit_v1();
        return -1;
      }
      if (!first)
        [encoder waitForFence:pass->chain
                 beforeStages:MTLRenderStageVertex | MTLRenderStageFragment];
      encodeCopy(*pass, encoder, index, false, includeDepth);
      first = false;
      if (int(index) != last) {
        [encoder updateFence:pass->chain afterStages:MTLRenderStageFragment];
        [encoder endEncoding];
      } else {
        r->encoder = (uint64_t)(__bridge void *)encoder;
      }
    }
    r->status = 0;
    ++resolved;
    return 0; // DXMT signals its fences on the final resolve, then ends it.
  }
  if (r->operation != 1 || activePass ||
      r->flags != WVR_GUEST_FOVEATION_SAFE_SHADER || !r->commandBuffer ||
      !r->colorTexture || r->colorCount > 8 ||
      r->depthStencilReadOnlyMask > 3) {
    ++rejected;
    return -1;
  }
  auto commands = (__bridge id<MTLCommandBuffer>)(void *)r->commandBuffer;
  auto pass = std::make_unique<Pass>();
  pass->commands = commands;
  pass->request = *r;
  pass->colorCount = r->colorCount ? r->colorCount : 1;
  auto firstRoot = (__bridge id<MTLTexture>)(void *)r->colorTexture;
  NSUInteger absoluteSlice = r->colorSlice;
  firstRoot = rootTexture(firstRoot, &absoluteSlice);
  for (unsigned i = 0; i < pass->colorCount; ++i) {
    auto handle = i ? r->additionalColors[i - 1].texture : r->colorTexture;
    if (!handle)
      continue;
    const auto slice = i ? r->additionalColors[i - 1].slice : r->colorSlice,
               load = i ? r->additionalColors[i - 1].load : r->colorLoad;
    auto color = singleSlice((__bridge id<MTLTexture>)(void *)handle, slice);
    pass->color[i] = color;
    if (!color || color.sampleCount != 1 || color.width != r->width ||
        color.height != r->height || color.device != commands.device ||
        load > MTLLoadActionClear) {
      ++rejected;
      return -1;
    }
    if (load == MTLLoadActionLoad && pass->firstPreload < 0)
      pass->firstPreload = int(i);
  }
  pass->depth = singleSlice((__bridge id<MTLTexture>)(void *)r->depthTexture,
                            r->depthSlice);
  auto depth = pass->depth;
  pass->stencil = r->stencilTexture != 0;
  if (pass->stencil) {
    auto stencil = singleSlice(
        (__bridge id<MTLTexture>)(void *)r->stencilTexture, r->stencilSlice);
    NSUInteger ds = r->depthSlice, ss = r->stencilSlice;
    auto dr =
             rootTexture((__bridge id<MTLTexture>)(void *)r->depthTexture, &ds),
         sr = rootTexture((__bridge id<MTLTexture>)(void *)r->stencilTexture,
                          &ss);
    if (!depth || !stencil ||
        depth.pixelFormat != MTLPixelFormatDepth32Float_Stencil8 || dr != sr ||
        ds != ss || r->stencilLoad > MTLLoadActionClear) {
      ++rejected;
      return -1;
    }
    pass->stencilSource =
        [depth newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8];
    if (!pass->stencilSource) {
      ++rejected;
      return -1;
    }
  }
  if ((r->depthTexture && !depth) ||
      (depth && (depth.device != commands.device || depth.width != r->width ||
                 depth.height != r->height || depth.sampleCount != 1 ||
                 depth.pixelFormat != (pass->stencil
                                           ? MTLPixelFormatDepth32Float_Stencil8
                                           : MTLPixelFormatDepth32Float) ||
                 r->depthLoad > MTLLoadActionClear))) {
    ++rejected;
    return -1;
  }
  if (depth &&
      (r->depthLoad == MTLLoadActionLoad ||
       (pass->stencil && r->stencilLoad == MTLLoadActionLoad)) &&
      pass->firstPreload < 0)
    pass->firstPreload = 0;
  std::lock_guard<std::mutex> lock(stateMutex);
  EyeTarget *entry = nullptr;
  for (auto &target : targets)
    if (target.root == firstRoot && target.slice == absoluteSlice) {
      entry = &target;
      break;
    }
  if (!entry) {
    uint32_t matchedEyeWidth = 0, matchedEyeHeight = 0;
    bool matchedAtlas = false;
    for (const auto &existing : targets) {
      if (!existing.root || existing.eyeWidth < 512 || existing.eyeHeight < 512)
        continue;
      if (existing.atlas && absoluteSlice == 0 &&
          r->width == 2 * existing.eyeWidth &&
          r->height == existing.eyeHeight) {
        matchedEyeWidth = existing.eyeWidth;
        matchedEyeHeight = existing.eyeHeight;
        matchedAtlas = true;
        break;
      }
      if (!existing.atlas && firstRoot.arrayLength >= 2 && absoluteSlice < 2 &&
          r->width == existing.eyeWidth && r->height == existing.eyeHeight) {
        matchedEyeWidth = existing.eyeWidth;
        matchedEyeHeight = existing.eyeHeight;
        matchedAtlas = false;
        break;
      }
    }
    if (matchedEyeWidth && matchedEyeHeight) {
      if (matchedAtlas) {
        for (uint32_t role : {0u, 1u}) {
          auto &slot = targets[nextTarget++ % targets.size()];
          slot = EyeTarget{};
          slot.root = firstRoot;
          slot.role = role;
          slot.slice = 0;
          slot.eyeWidth = matchedEyeWidth;
          slot.eyeHeight = matchedEyeHeight;
          slot.atlas = true;
          if (role == 0)
            entry = &slot;
        }
      } else {
        auto &slot = targets[nextTarget++ % targets.size()];
        slot = EyeTarget{};
        slot.root = firstRoot;
        slot.role = uint32_t(absoluteSlice);
        slot.slice = uint32_t(absoluteSlice);
        slot.eyeWidth = matchedEyeWidth;
        slot.eyeHeight = matchedEyeHeight;
        slot.atlas = false;
        entry = &slot;
      }
    }
  }
  if (!entry) {
    ++unmatchedTargets;
    ++rejected;
    return -1;
  }
  if (!eyeMaps[entry->role].map ||
      CACurrentMediaTime() - eyeMaps[entry->role].published > 0.025) {
    ++staleMaps;
    ++rejected;
    return -1;
  }
  const auto &eye = eyeMaps[entry->role];
  const auto &right = eyeMaps[1];
  if (entry->atlas) {
    bool paired = false;
    for (const auto &other : targets)
      paired |= other.root == firstRoot && other.slice == absoluteSlice &&
                other.atlas && other.role != entry->role &&
                other.eyeWidth == entry->eyeWidth &&
                other.eyeHeight == entry->eyeHeight;
    if (!paired || r->width != 2 * entry->eyeWidth ||
        r->height != entry->eyeHeight || !eyeMaps[0].map || !right.map ||
        CACurrentMediaTime() - eyeMaps[0].published > 0.025 ||
        CACurrentMediaTime() - right.published > 0.025) {
      ++rejected;
      return -1;
    }
  }
  const auto &left = entry->atlas ? eyeMaps[0] : eye;
  if (entry->sourceMap != left.map || entry->mapLayer != left.layer ||
      (entry->atlas && (entry->rightSourceMap != right.map ||
                        entry->rightMapLayer != right.layer)) ||
      entry->adaptedMap.screenSize.width != r->width ||
      entry->adaptedMap.screenSize.height != r->height) {
    entry->adaptedMap =
        entry->atlas
            ? adaptStereoAtlas(left, right, entry->eyeWidth, entry->eyeHeight)
            : adaptMap(left.map, left.layer, r->width, r->height);
    entry->sourceMap = left.map;
    entry->mapLayer = left.layer;
    entry->rightSourceMap = entry->atlas ? right.map : nil;
    entry->rightMapLayer = right.layer;
    entry->parameters =
        entry->adaptedMap
            ? [commands.device
                  newBufferWithLength:entry->adaptedMap
                                          .parameterBufferSizeAndAlign.size
                              options:MTLResourceStorageModeShared]
            : nil;
    if (entry->parameters)
      [entry->adaptedMap copyParameterDataToBuffer:entry->parameters offset:0];
  }
  pass->atlas = entry->atlas;
  pass->map = entry->adaptedMap;
  pass->parameters = entry->parameters;
  if (!pass->map || !pass->parameters) {
    ++rejected;
    return -1;
  }
  const auto size = [pass->map physicalSizeForLayer:0];
  if (!size.width || !size.height ||
      size.width * size.height >= uint64_t(r->width) * r->height) {
    ++rejected;
    return -1;
  }
  pass->scene = [MTLRenderPassDescriptor new];
  pass->scene.rasterizationRateMap = pass->map;
  unsigned firstColor = 0;
  while (firstColor < pass->colorCount && !pass->color[firstColor])
    ++firstColor;
  for (unsigned i = 0; i < pass->colorCount; ++i) {
    auto color = pass->color[i];
    if (!color)
      continue;
    pass->pipeline[i] = pipelineFor(commands.device, color.pixelFormat,
                                    depth && i == firstColor, false,
                                    pass->stencil && i == firstColor);
    const auto load = i ? r->additionalColors[i - 1].load : r->colorLoad;
    if (load == MTLLoadActionLoad || int(i) == pass->firstPreload)
      pass->loadPipeline[i] = pipelineFor(
          commands.device, color.pixelFormat,
          int(i) == pass->firstPreload && depth &&
              (r->depthLoad == MTLLoadActionLoad ||
               (pass->stencil && r->stencilLoad == MTLLoadActionLoad)),
          true,
          int(i) == pass->firstPreload && pass->stencil &&
              (r->depthLoad == MTLLoadActionLoad ||
               r->stencilLoad == MTLLoadActionLoad));
    if (!pass->pipeline[i] ||
        ((load == MTLLoadActionLoad || int(i) == pass->firstPreload) &&
         !pass->loadPipeline[i])) {
      ++rejected;
      return -1;
    }
    auto cached = entry->scratchColor[i];
    auto td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:color.pixelFormat
                                     width:std::max(size.width, cached.width)
                                    height:std::max(size.height, cached.height)
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
               MTLTextureUsagePixelFormatView;
    if (!cached || cached.width < size.width || cached.height < size.height ||
        cached.pixelFormat != color.pixelFormat)
      entry->scratchColor[i] = [commands.device newTextureWithDescriptor:td];
    pass->compressedColor[i] = entry->scratchColor[i];
    if (!pass->compressedColor[i])
      return -1;
    auto a = pass->scene.colorAttachments[i];
    a.texture = pass->compressedColor[i];
    a.loadAction = MTLLoadAction(load);
    a.storeAction = MTLStoreActionStore;
    // Packed transport doubles have only four-byte alignment. Copy into
    // aligned storage before array decay would erase that layout knowledge.
    double clear[4];
    std::memcpy(clear,
                i ? r->additionalColors[i - 1].clearColor : r->clearColor,
                sizeof(clear));
    a.clearColor = MTLClearColorMake(clear[0], clear[1], clear[2], clear[3]);
  }
  if (depth) {
    auto cached = entry->scratchDepth;
    auto td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:depth.pixelFormat
                                     width:std::max(size.width, cached.width)
                                    height:std::max(size.height, cached.height)
                                 mipmapped:NO];
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
               MTLTextureUsagePixelFormatView;
    if (!cached || cached.width < size.width || cached.height < size.height ||
        cached.pixelFormat != depth.pixelFormat)
      entry->scratchDepth = [commands.device newTextureWithDescriptor:td];
    pass->compressedDepth = entry->scratchDepth;
    if (!pass->compressedDepth)
      return -1;
    if (pass->stencil) {
      pass->compressedStencil = [pass->compressedDepth
          newTextureViewWithPixelFormat:MTLPixelFormatX32_Stencil8];
      if (!pass->compressedStencil)
        return -1;
      pass->scene.stencilAttachment.texture = pass->compressedDepth;
      pass->scene.stencilAttachment.loadAction = MTLLoadAction(r->stencilLoad);
      pass->scene.stencilAttachment.storeAction = MTLStoreActionStore;
      pass->scene.stencilAttachment.clearStencil = r->stencilClear;
    }
    pass->scene.depthAttachment.texture = pass->compressedDepth;
    pass->scene.depthAttachment.loadAction = MTLLoadAction(r->depthLoad);
    pass->scene.depthAttachment.storeAction = MTLStoreActionStore;
    pass->scene.depthAttachment.clearDepth = r->clearDepth;
  }
  if (pass->firstPreload >= 0 || pass->colorCount > 1) {
    pass->chain = [commands.device newFence];
    if (!pass->chain)
      return -1;
  }
  if (CACurrentMediaTime() - eye.published > 0.025) {
    ++rejected;
    return -1;
  }
  pass->encoder =
      pass->firstPreload >= 0
          ? preloadEncoder(*pass, unsigned(pass->firstPreload))
          : [commands renderCommandEncoderWithDescriptor:pass->scene];
  if (!pass->encoder)
    return -1;
  [pass->encoder setFragmentBuffer:pass->parameters offset:0 atIndex:28];
  pass->token = nextToken.fetch_add(1);
  r->token = pass->token;
  r->encoder = (uint64_t)(__bridge void *)pass->encoder;
  r->status = 0;
  activePass = std::move(pass);
  ++begun;
  if (entry->atlas)
    ++atlasBegun;
  sceneDraws.fetch_add(r->drawCalls);
  logicalArea.fetch_add(uint64_t(r->width) * r->height);
  mappedArea.fetch_add(uint64_t(size.width) * size.height);
  return 0;
}
extern "C" int wvr_guest_foveation_copy_stats_v1(char *buffer,
                                                 uint32_t capacity) {
  if (!buffer || !capacity)
    return 0;
  const auto adaptations = mapAdaptations.load();
  const auto area = logicalArea.load();
  std::snprintf(
      buffer, capacity,
      "guestFoveation begun=%llu resolved=%llu rejected=%llu draws=%llu "
      "unmatchedTargets=%llu staleMaps=%llu mapAreaRatio=%.3f "
      "systemMaps=per-eye maxAgeMs=25 adaptations=%llu meanAdaptCPUms=%.3f "
      "atlas=%llu bridgeCalls=%llu capabilities=%llu uniform=%llu "
      "eventNotifications=%llu sliceViewHits=%llu sliceViewCreates=%llu",
      (unsigned long long)begun.load(), (unsigned long long)resolved.load(),
      (unsigned long long)rejected.load(),
      (unsigned long long)sceneDraws.load(),
      (unsigned long long)unmatchedTargets.load(),
      (unsigned long long)staleMaps.load(),
      area ? double(mappedArea.load()) / double(area) : 1.0,
      (unsigned long long)adaptations,
      adaptations
          ? double(mapAdaptNanoseconds.load()) / double(adaptations) / 1e6
          : 0.0,
      (unsigned long long)atlasBegun.load(),
      (unsigned long long)bridgeCalls.load(),
      (unsigned long long)capabilities.load(),
      (unsigned long long)uniformBindings.load(),
      (unsigned long long)progressNotifications.load(),
      (unsigned long long)sliceViewHits.load(std::memory_order_relaxed),
      (unsigned long long)sliceViewCreates.load(std::memory_order_relaxed));
  return 1;
}
