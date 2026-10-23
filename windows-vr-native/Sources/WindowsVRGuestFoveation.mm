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
#include <cstdlib>
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
                      // In-process atomic notification (VeRantyx os_sync_wait_on_address pattern)
                      // Wakes any waiting threads immediately without wineserver roundtrip
#if defined(__cpp_lib_atomic_wait) && __cpp_lib_atomic_wait
                      state->value.notify_all();
#endif
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
// Foveal gaze estimate per eye, derived from the published system rate map.
// The map is retained here, so cache identity (pointer + layer) cannot be
// recycled by a later allocation.
struct GazeEstimate {
  __strong id<MTLRasterizationRateMap> map = nil;
  uint32_t layer = 0;
  bool computed = false, valid = false, logged = false;
  float centerU = 0.5f, centerV = 0.5f, radius = 0.25f;
  float loggedU = 0.5f, loggedV = 0.5f, loggedRadius = 0.25f;
  double lastLog = 0;
  double computedAt = 0;
};
std::array<GazeEstimate, 2> gazeEstimates;
// Returns the rate-weighted centroid (UV, y down) of screen cells whose local
// rate is >= 0.9 of the peak, plus the half-width of that region in UV. The
// local rate is the Jacobian determinant of the screen->physical mapping
// (physical pixels per screen pixel, squared), sampled on a 32x32 grid with
// finite differences.
bool computeGaze(id<MTLRasterizationRateMap> map, uint32_t layer, float &centerU,
                 float &centerV, float &radius) {
  if (!map || layer >= map.layerCount)
    return false;
  const MTLSize screen = map.screenSize;
  if (!screen.width || !screen.height ||
      ![map physicalSizeForLayer:layer].width)
    return false;
  constexpr int N = 32;
  const double W = screen.width, H = screen.height;
  const double hx = std::max(1.0, W / 64.0), hy = std::max(1.0, H / 64.0);
  auto phys = [&](double x, double y) {
    return [map mapScreenToPhysicalCoordinates:(MTLCoordinate2D){float(x), float(y)}
                                      forLayer:layer];
  };
  std::array<double, N * N> rate{};
  double peak = 0;
  for (int j = 0; j < N; ++j)
    for (int i = 0; i < N; ++i) {
      const double sx = (i + 0.5) * W / N, sy = (j + 0.5) * H / N;
      const double x0 = std::max(0.0, sx - hx), x1 = std::min(W, sx + hx);
      const double y0 = std::max(0.0, sy - hy), y1 = std::min(H, sy + hy);
      const auto a = phys(x0, sy), b = phys(x1, sy);
      const auto c = phys(sx, y0), d = phys(sx, y1);
      const double dxdx = (b.x - a.x) / (x1 - x0),
                   dydx = (b.y - a.y) / (x1 - x0);
      const double dxdy = (d.x - c.x) / (y1 - y0),
                   dydy = (d.y - c.y) / (y1 - y0);
      const double r = std::fabs(dxdx * dydy - dxdy * dydx);
      rate[j * N + i] = std::isfinite(r) ? r : 0;
      peak = std::max(peak, rate[j * N + i]);
    }
  if (!(peak > 0))
    return false;
  const double threshold = 0.9 * peak, cell = 1.0 / N;
  double sumW = 0, sumU = 0, sumV = 0;
  double minU = 1, maxU = 0, minV = 1, maxV = 0;
  for (int j = 0; j < N; ++j)
    for (int i = 0; i < N; ++i) {
      const double r = rate[j * N + i];
      if (r < threshold)
        continue;
      const double u = (i + 0.5) * cell, v = (j + 0.5) * cell;
      sumW += r;
      sumU += r * u;
      sumV += r * v;
      minU = std::min(minU, u);
      maxU = std::max(maxU, u);
      minV = std::min(minV, v);
      maxV = std::max(maxV, v);
    }
  if (!(sumW > 0))
    return false;
  centerU = float(sumU / sumW);
  centerV = float(sumV / sumW);
  radius = float(std::clamp(0.5 * (std::max(maxU - minU, maxV - minV) + cell),
                            cell, 0.5));
  return true;
}
struct EyeTarget {
  __strong id<MTLTexture> root = nil;
  uint32_t role = 0, slice = 0, eyeWidth = 0, eyeHeight = 0;
  bool atlas = false;
  // Size-derived targets are not registered eyes. singleEye targets follow the
  // eye of the most recent registered identity pass in the current frame.
  bool derived = false, singleEye = false;
  __strong id<MTLTexture> scratchColor[8] = {}, scratchDepth = nil;
  __strong id<MTLRasterizationRateMap> sourceMap = nil, adaptedMap = nil,
                                       rightSourceMap = nil;
  __strong id<MTLBuffer> parameters = nil;
  uint32_t mapLayer = 0, rightMapLayer = 0;
  bool yoroSkip = false;
  float yoroScale = 1.0f;
  float drsScale = 1.0f;
  // Cached with adaptedMap so resolves do not query the map per pass.
  uint32_t bounds[4] = {};
  MTLSize physicalSize = {};
  // Layered stereo pairs cache a two-layer scene map and each layer's
  // single-slice adaptation. Both are rebuilt when a source map or size changes.
  __strong id<MTLRasterizationRateMap> layeredMap = nil, layeredSource[2] = {};
  __strong id<MTLBuffer> layeredParameters = nil, layerParameters[2] = {};
  uint32_t layeredSourceLayer[2] = {}, layeredWidth = 0, layeredHeight = 0;
  bool layeredYoroSkip = false;
  float layeredYoroScale = 1.0f;
  float layeredDrsScale = 1.0f;
  uint32_t layerBounds[2][4] = {};
  MTLSize layerPhysical[2] = {};
};
std::array<EyeTarget, 64> targets;
size_t nextTarget = 0;
uint32_t lastIdentityRole = 0;
bool lastIdentityKnown = false;
std::atomic<uint64_t> sceneDraws{0}, logicalArea{0}, mappedArea{0},
    unmatchedTargets{0}, staleMaps{0}, atlasBegun{0}, bridgeCalls{0},
    capabilities{0}, uniformBindings{0};
std::atomic<uint64_t> sliceViewHits{0}, sliceViewCreates{0};
std::atomic<uint64_t> layeredBegun{0}, anySizeTargets{0},
    yoroSecondaryPasses{0};
std::atomic<bool> lastYoroSkipRequested{false};
std::atomic<float> drsScale{1.0f};
std::atomic<float> drsEmaMs{0.0f};
std::atomic<uint64_t> drsAdjustments{0};
std::mutex drsGovernorMutex;
double drsLastUpdateTime = 0.0;
double drsLastChangeTime = 0.0;
double drsLastLogTime = 0.0;
float drsCurrentEmaMs = 0.0f;
std::atomic<uint64_t> begun{0}, resolved{0}, rejected{0}, nextToken{1},
    mapAdaptations{0}, mapAdaptNanoseconds{0};
__strong id<MTLLibrary> resolveLibrary = nil;
__strong id<MTLBuffer> identityParameters = nil;
__strong id<MTLSamplerState> linearSampler = nil, pointSampler = nil;
__strong id<MTLDepthStencilState> resolveStates[2][4] = {};
__strong NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *pipelines;
// Small fixed cache in front of the dictionary, keyed by (format, flags).
struct PipelineSlot {
  MTLPixelFormat format = MTLPixelFormatInvalid;
  uint8_t flags = 0;
  __strong id<MTLRenderPipelineState> state = nil;
};
PipelineSlot pipelineSlots[32];

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

// Samples one layer's system rate functions and adapts them in normalized
// screen space. Conservative neighboring maxima widen high-quality regions;
// no gaze point is reconstructed, persisted or exposed.
struct YoroConfig {
  bool enabled = false;
  float scale = 0.5f;
};
static const YoroConfig &yoroConfig() {
  static const YoroConfig cfg = [] {
    YoroConfig c{};
    if (const char *env = std::getenv("WVR_YORO_SECONDARY_SKIP"))
      c.enabled = std::strcmp(env, "1") == 0;
    if (const char *scaleEnv = std::getenv("WVR_YORO_SECONDARY_SCALE")) {
      char *end = nullptr;
      const float parsed = std::strtof(scaleEnv, &end);
      if (end != scaleEnv && std::isfinite(parsed))
        c.scale = std::clamp(parsed, 0.25f, 1.0f);
    }
    NSLog(@"[guest-foveation] yoroSecondarySkip=%d scale=%.2f",
          c.enabled ? 1 : 0, c.scale);
    return c;
  }();
  return cfg;
}

struct DrsConfig {
  bool enabled = false;
  float targetHz = 45.0f;
  float targetMs = 1000.0f / 45.0f;
  float minScale = 0.5f;
};
static const DrsConfig &drsConfig() {
  static const DrsConfig cfg = [] {
    DrsConfig c{};
    if (const char *env = std::getenv("WVR_DRS_FOVEATION"))
      c.enabled = std::strcmp(env, "1") == 0;
    if (const char *hzEnv = std::getenv("WVR_DRS_TARGET_HZ")) {
      char *end = nullptr;
      const float parsed = std::strtof(hzEnv, &end);
      if (end != hzEnv && std::isfinite(parsed) && parsed > 0.0f) {
        c.targetHz = parsed;
        c.targetMs = 1000.0f / parsed;
      }
    }
    if (const char *minEnv = std::getenv("WVR_DRS_MIN_SCALE")) {
      char *end = nullptr;
      const float parsed = std::strtof(minEnv, &end);
      if (end != minEnv && std::isfinite(parsed))
        c.minScale = std::clamp(parsed, 0.125f, 1.0f);
    }
    if (c.enabled)
      NSLog(@"[guest-foveation] dynamic foveation governor enabled targetHz=%.1f targetMs=%.2f minScale=%.2f",
            c.targetHz, c.targetMs, c.minScale);
    return c;
  }();
  return cfg;
}

static void reduceSecondaryAxis(float *rates, float scale) {
  if (scale >= 0.999f)
    return;
  float peak = 0.0f;
  for (unsigned i = 1; i < 31; ++i)
    peak = std::max(peak, rates[i]);
  if (peak <= 0.0f)
    return;
  const float threshold = 0.9f * peak;
  for (unsigned i = 1; i < 31; ++i) {
    if (rates[i] >= threshold)
      continue;
    rates[i] = std::clamp(rates[i] * scale, 0.125f, 1.0f);
  }
}

static bool sampleAdaptedRates(id<MTLRasterizationRateMap> source,
                               NSUInteger layer, float (&x)[32],
                               float (&y)[32], bool reduce = false,
                               float scale = 1.0f) {
  constexpr unsigned count = 32;
  if (!source || layer >= source.layerCount)
    return false;
  float sx[count], sy[count];
  const auto screen = source.screenSize;
  if (!screen.width || !screen.height)
    return false;
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
  if (reduce) {
    reduceSecondaryAxis(x, scale);
    reduceSecondaryAxis(y, scale);
  }
  return true;
}

// The original system map stays immutable; the adapted map is a new object.
id<MTLRasterizationRateMap> adaptMap(id<MTLRasterizationRateMap> source,
                                     NSUInteger layer, NSUInteger width,
                                     NSUInteger height, bool reduce = false,
                                     float scale = 1.0f) {
  if (!source || layer >= source.layerCount || !width || !height)
    return nil;
  float x[32], y[32];
  const auto started = std::chrono::steady_clock::now();
  if (!sampleAdaptedRates(source, layer, x, y, reduce, scale))
    return nil;
  auto rates = [[MTLRasterizationRateLayerDescriptor alloc]
      initWithSampleCount:MTLSizeMake(32, 32, 1)
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
struct DO { float depth [[depth(any)]]; };
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
fragment DO wvr_fov_resolve_depth_only(V in [[stage_in]],depth2d<float> depth [[texture(1)]],
    sampler pointClamp [[sampler(1)]],constant rasterization_rate_map_data &map [[buffer(0)]],constant uint4 &physicalSize [[buffer(1)]]) {
    return {depth.sample(pointClamp,sourceUV(in.position.xy,map,uint2(depth.get_width(),depth.get_height()),physicalSize))};
}
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

// Pixel dimensions match an eye at 1x or a listed scale, within one pixel.
// Scaled targets are adapted to their own size by adaptMap.
static bool eyeSizeMatches(uint64_t width, uint64_t height, uint32_t eyeWidth,
                           uint32_t eyeHeight) {
  static constexpr double scales[] = {1.0, 0.5, 0.75, 1.25, 1.5, 2.0};
  for (double scale : scales) {
    if (std::fabs(double(width) - eyeWidth * scale) <= 1.0 &&
        std::fabs(double(height) - eyeHeight * scale) <= 1.0)
      return true;
  }
  return false;
}

// A side-by-side stereo atlas has one shared vertical rate function. Use the
// maximum required by either eye at every row, and keep each eye's horizontal
// rates independently. This is conservative for both system-supplied maps.
static id<MTLRasterizationRateMap> adaptStereoAtlas(const EyeMap &left,
                                                    const EyeMap &right,
                                                    NSUInteger width,
                                                    NSUInteger height,
                                                    float leftScale = 1.0f,
                                                    float rightScale = 1.0f) {
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
  if (leftScale < 0.999f) {
    reduceSecondaryAxis(x, leftScale);
    reduceSecondaryAxis(y, leftScale);
  }
  if (rightScale < 0.999f)
    reduceSecondaryAxis(x + 32, rightScale);
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

// Two-layer map for one stereo pair at one target size. Layer 0 and layer 1
// keep their own eye's adapted rates, matching the per-layer resolve maps that
// are built from the same eye maps.
static id<MTLRasterizationRateMap> adaptLayeredPair(const EyeMap &left,
                                                    const EyeMap &right,
                                                    NSUInteger width,
                                                    NSUInteger height,
                                                    float leftScale = 1.0f,
                                                    float rightScale = 1.0f) {
  if (!left.map || !right.map || left.map.device != right.map.device ||
      !width || !height)
    return nil;
  float lx[32], ly[32], rx[32], ry[32];
  if (!sampleAdaptedRates(left.map, left.layer, lx, ly, leftScale < 0.999f,
                          leftScale) ||
      !sampleAdaptedRates(right.map, right.layer, rx, ry, rightScale < 0.999f,
                          rightScale))
    return nil;
  const auto started = std::chrono::steady_clock::now();
  auto l = [[MTLRasterizationRateLayerDescriptor alloc]
      initWithSampleCount:MTLSizeMake(32, 32, 1)
               horizontal:lx
                 vertical:ly];
  auto r = [[MTLRasterizationRateLayerDescriptor alloc]
      initWithSampleCount:MTLSizeMake(32, 32, 1)
               horizontal:rx
                 vertical:ry];
  MTLRasterizationRateLayerDescriptor *layers[2] = {l, r};
  auto descriptor = [MTLRasterizationRateMapDescriptor
      rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(width, height, 1)
                                        layerCount:2
                                            layers:layers];
  auto result =
      [left.map.device newRasterizationRateMapWithDescriptor:descriptor];
  mapAdaptations.fetch_add(1);
  mapAdaptNanoseconds.fetch_add(
      std::chrono::duration_cast<std::chrono::nanoseconds>(
          std::chrono::steady_clock::now() - started)
          .count());
  return result;
}

// Rebuilds the cached layered scene map and the per-layer resolve adaptations
// whenever either eye map, its layer, or the target size changes.
static bool refreshLayered(EyeTarget &entry,
                           const std::array<EyeMap, 2> &eyes, uint32_t width,
                           uint32_t height, id<MTLDevice> device,
                           bool yoroSkip = false, float yoroScale = 1.0f,
                           float drsScale = 1.0f) {
  const float effectiveYoroScale = yoroSkip ? yoroScale : 1.0f;
  const float leftScale = drsScale;
  const float rightScale = drsScale * effectiveYoroScale;
  bool current = entry.layeredMap && entry.layeredWidth == width &&
                 entry.layeredHeight == height &&
                 entry.layeredYoroSkip == yoroSkip &&
                 entry.layeredYoroScale == effectiveYoroScale &&
                 std::fabs(entry.layeredDrsScale - drsScale) < 0.025f;
  for (unsigned l = 0; l < 2; ++l)
    current &= entry.layeredSource[l] == eyes[l].map &&
               entry.layeredSourceLayer[l] == eyes[l].layer;
  if (current)
    return true;
  auto map = adaptLayeredPair(eyes[0], eyes[1], width, height, leftScale,
                              rightScale);
  if (!map)
    return false;
  auto parameters =
      [device newBufferWithLength:map.parameterBufferSizeAndAlign.size
                          options:MTLResourceStorageModeShared];
  if (!parameters)
    return false;
  [map copyParameterDataToBuffer:parameters offset:0];
  for (unsigned l = 0; l < 2; ++l) {
    const float layerScale = (l == 0) ? leftScale : rightScale;
    auto single = adaptMap(eyes[l].map, eyes[l].layer, width, height,
                           layerScale < 0.999f, layerScale);
    if (!single)
      return false;
    auto buffer =
        [device newBufferWithLength:single.parameterBufferSizeAndAlign.size
                            options:MTLResourceStorageModeShared];
    if (!buffer)
      return false;
    [single copyParameterDataToBuffer:buffer offset:0];
    entry.layerParameters[l] = buffer;
    entry.layerPhysical[l] = [single physicalSizeForLayer:0];
    // Same logical-extent clamp as the single-slice path.
    const auto logicalEnd = [single
        mapScreenToPhysicalCoordinates:(MTLCoordinate2D){float(width),
                                                         float(height)}
                              forLayer:0];
    entry.layerBounds[l][0] = uint32_t(std::round(logicalEnd.x));
    entry.layerBounds[l][1] = uint32_t(std::round(logicalEnd.y));
    entry.layerBounds[l][2] = 0;
    entry.layerBounds[l][3] = 0;
  }
  entry.layeredMap = map;
  entry.layeredParameters = parameters;
  entry.layeredWidth = width;
  entry.layeredHeight = height;
  entry.layeredYoroSkip = yoroSkip;
  entry.layeredYoroScale = effectiveYoroScale;
  entry.layeredDrsScale = drsScale;
  for (unsigned l = 0; l < 2; ++l) {
    entry.layeredSource[l] = eyes[l].map;
    entry.layeredSourceLayer[l] = eyes[l].layer;
  }
  return true;
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
  __strong id<MTLRenderPipelineState> depthPipeline = nil;
  uint32_t bounds[4] = {};
  uint64_t token = 0;
  // Layered stereo passes: the two-slice destination, and each layer's
  // adaptation for the per-slice resolve.
  bool layered = false;
  __strong id<MTLTexture> layeredColor = nil, layeredDepth = nil;
  __strong id<MTLBuffer> layerParameters[2] = {};
  uint32_t layerBounds[2][4] = {};
};
thread_local std::unique_ptr<Pass> activePass;

id<MTLRenderPipelineState> pipelineFor(id<MTLDevice> device,
                                       MTLPixelFormat color, bool depth,
                                       bool load = false,
                                       bool stencil = false,
                                       bool depthOnly = false) {
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
  const uint8_t flags = uint8_t((unsigned(depthOnly) << 4) |
                                (unsigned(stencil) << 2) |
                                (unsigned(load) << 1) | unsigned(depth));
  for (auto &slot : pipelineSlots)
    if (slot.state && slot.format == color && slot.flags == flags)
      return slot.state;
  NSNumber *key = @((uint64_t(color) << 5) | flags);
  if (auto cached = pipelines[key]) {
    for (auto &slot : pipelineSlots)
      if (!slot.state) {
        slot = {color, flags, cached};
        break;
      }
    return cached;
  }
  auto descriptor = [MTLRenderPipelineDescriptor new];
  descriptor.vertexFunction =
      [resolveLibrary newFunctionWithName:@"wvr_fov_resolve_vertex"];
  descriptor.fragmentFunction = [resolveLibrary
      newFunctionWithName:depthOnly
                              ? @"wvr_fov_resolve_depth_only"
                              : (stencil
                                     ? (load ? @"wvr_fov_load_stencil"
                                             : @"wvr_fov_resolve_stencil")
                                     : (load ? (depth ? @"wvr_fov_load_depth"
                                                      : @"wvr_fov_load_color")
                                             : (depth
                                                    ? @"wvr_fov_resolve_depth"
                                                    : @"wvr_fov_resolve_color")))];
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
  if (result) {
    pipelines[key] = result;
    for (auto &slot : pipelineSlots)
      if (!slot.state) {
        slot = {color, flags, result};
        break;
      }
  } else {
    NSLog(@"[guest-foveation] resolve pipeline failed: %@", error);
  }
  return result;
}

// Encoders copy descriptor state when they are created, so one descriptor per
// thread serves the short-lived preload and resolve encoders. Every attachment
// and the rate map are reset so no state leaks between uses.
static MTLRenderPassDescriptor *scratchDescriptor() {
  static thread_local __strong MTLRenderPassDescriptor *descriptor = nil;
  if (!descriptor)
    descriptor = [MTLRenderPassDescriptor new];
  descriptor.rasterizationRateMap = nil;
  descriptor.colorAttachments[0].texture = nil;
  descriptor.depthAttachment.texture = nil;
  descriptor.stencilAttachment.texture = nil;
  return descriptor;
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
  if (!pipelineFor(device, MTLPixelFormatInvalid, true, false, false, true))
    return 0;
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
  gazeEstimates = {};
  lastYoroSkipRequested.store(false, std::memory_order_relaxed);
  targets = {};
  nextTarget = 0;
  lastIdentityKnown = false;
  {
    std::lock_guard<std::mutex> drsLock(drsGovernorMutex);
    drsCurrentEmaMs = 0.0f;
    drsLastUpdateTime = 0.0;
    drsLastChangeTime = 0.0;
  }
  drsScale.store(1.0f, std::memory_order_relaxed);
  drsEmaMs.store(0.0f, std::memory_order_relaxed);
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
  // Maps are published once per frame, so this bounds the identity used for
  // single eye-sized offscreen targets to the current frame.
  lastIdentityKnown = false;
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
  auto d = scratchDescriptor();
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
  // Bounds come from the per-map cache. They clamp reconstruction to pixel
  // centers covered by the logical image, excluding physical tile padding.
  [encoder setFragmentBytes:pass.bounds length:sizeof(pass.bounds) atIndex:1];
  [encoder setViewport:(MTLViewport){0, 0, double(pass.request.width),
                                     double(pass.request.height), 0, 1}];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}
static void encodeDepthCopy(Pass &pass, id<MTLRenderCommandEncoder> encoder) {
  [encoder setRenderPipelineState:pass.depthPipeline];
  [encoder setDepthStencilState:resolveStates[0][pass.request
                                                     .depthStencilReadOnlyMask &
                                                 3]];
  [encoder setFragmentTexture:pass.compressedDepth atIndex:1];
  [encoder setFragmentSamplerState:pointSampler atIndex:1];
  [encoder setFragmentBuffer:pass.parameters offset:0 atIndex:0];
  [encoder setFragmentBytes:pass.bounds length:sizeof(pass.bounds) atIndex:1];
  [encoder setViewport:(MTLViewport){0, 0, double(pass.request.width),
                                     double(pass.request.height), 0, 1}];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}
// One layer of the per-slice resolve. The compressed slice is sampled through
// that layer's own adapted map, and the copy lands in the matching slice.
static void encodeLayerCopy(Pass &pass, id<MTLRenderCommandEncoder> encoder,
                            unsigned layer) {
  [encoder setRenderPipelineState:pass.pipeline[0]];
  if (pass.depth) {
    [encoder setDepthStencilState:resolveStates[0][pass.request
                                                     .depthStencilReadOnlyMask &
                                                 3]];
    [encoder setFragmentTexture:singleSlice(pass.compressedDepth, layer)
                        atIndex:1];
  }
  [encoder setFragmentTexture:singleSlice(pass.compressedColor[0], layer)
                      atIndex:0];
  [encoder setFragmentSamplerState:linearSampler atIndex:0];
  [encoder setFragmentSamplerState:pointSampler atIndex:1];
  [encoder setFragmentBuffer:pass.layerParameters[layer] offset:0 atIndex:0];
  [encoder setFragmentBytes:pass.layerBounds[layer]
                     length:sizeof(pass.layerBounds[layer])
                    atIndex:1];
  [encoder setViewport:(MTLViewport){0, 0, double(pass.request.width),
                                     double(pass.request.height), 0, 1}];
  [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
}

// Legacy 492-byte requests are accepted. The layer count is read only from
// the 496-byte version.
extern "C" int wvr_guest_foveation_process_v1(WVRGuestFoveationPassV1 *r) {
  if (!r || r->abiVersion != WVR_GUEST_FOVEATION_ABI ||
      (r->structSize != WVR_GUEST_FOVEATION_PASS_V1_LEGACY_SIZE &&
       r->structSize != sizeof(*r)))
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
    if (!pass->colorCount) {
      // Depth-only: one resolve encoder, returned for DXMT to end.
      auto d = scratchDescriptor();
      d.depthAttachment.texture = pass->depth;
      d.depthAttachment.loadAction =
          (pass->request.depthStencilReadOnlyMask & 1) ? MTLLoadActionLoad
                                                       : MTLLoadActionDontCare;
      d.depthAttachment.storeAction = MTLStoreActionStore;
      auto encoder = [pass->commands renderCommandEncoderWithDescriptor:d];
      if (!encoder) {
        wvr_compositor_request_session_exit_v1();
        return -1;
      }
      encodeDepthCopy(*pass, encoder);
      r->encoder = (uint64_t)(__bridge void *)encoder;
      r->status = 0;
      ++resolved;
      return 0;
    }
    if (pass->layered) {
      // Each layer resolves its compressed slice through that layer's own
      // map into the matching destination slice. Layer 0 signals the chain
      // fence and layer 1 waits on it, as the MRT resolve does.
      id<MTLRenderCommandEncoder> encoder = nil;
      for (unsigned layer = 0; layer < 2; ++layer) {
        auto d = scratchDescriptor();
        d.colorAttachments[0].texture = singleSlice(pass->layeredColor, layer);
        d.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        d.colorAttachments[0].storeAction = MTLStoreActionStore;
        if (pass->depth) {
          d.depthAttachment.texture = singleSlice(pass->layeredDepth, layer);
          d.depthAttachment.loadAction =
              (pass->request.depthStencilReadOnlyMask & 1)
                  ? MTLLoadActionLoad
                  : MTLLoadActionDontCare;
          d.depthAttachment.storeAction = MTLStoreActionStore;
        }
        if (!d.colorAttachments[0].texture ||
            (pass->depth && !d.depthAttachment.texture)) {
          wvr_compositor_request_session_exit_v1();
          return -1;
        }
        encoder = [pass->commands renderCommandEncoderWithDescriptor:d];
        if (!encoder) {
          wvr_compositor_request_session_exit_v1();
          return -1;
        }
        if (layer)
          [encoder waitForFence:pass->chain
                   beforeStages:MTLRenderStageVertex | MTLRenderStageFragment];
        encodeLayerCopy(*pass, encoder, layer);
        if (!layer) {
          [encoder updateFence:pass->chain afterStages:MTLRenderStageFragment];
          [encoder endEncoding];
        }
      }
      r->encoder = (uint64_t)(__bridge void *)encoder;
      r->status = 0;
      ++resolved;
      return 0;
    }
    int last = -1;
    for (unsigned i = 0; i < pass->colorCount; ++i)
      if (pass->color[i])
        last = int(i);
    bool first = true;
    for (unsigned index = 0; index < pass->colorCount; ++index) {
      if (!pass->color[index])
        continue;
      auto d = scratchDescriptor();
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
  // Depth-only passes carry no colour (colorTexture and colorCount are zero).
  const bool hasColor = r->colorTexture != 0;
  // Version 496 carries arrayLength. Legacy requests are single-layer, so the
  // field is read only when the caller supplied it.
  const uint32_t arrayLength =
      r->structSize == sizeof(*r) ? r->arrayLength : 1u;
  const bool layered = arrayLength == 2;
  if (r->operation != 1 || activePass ||
      (r->flags & ~WVR_GUEST_FOVEATION_YORO_SECONDARY_SKIP) !=
          WVR_GUEST_FOVEATION_SAFE_SHADER ||
      !r->commandBuffer ||
      (!hasColor && (!r->depthTexture || r->colorCount)) || r->colorCount > 8 ||
      r->depthStencilReadOnlyMask > 3 || (arrayLength != 1 && !layered) ||
      (layered && !hasColor)) {
    ++rejected;
    return -1;
  }
  // Depth-only resolves do not preload depth or carry stencil.
  if (!hasColor && (r->stencilTexture || r->depthLoad == MTLLoadActionLoad)) {
    ++rejected;
    return -1;
  }
  auto commands = (__bridge id<MTLCommandBuffer>)(void *)r->commandBuffer;
  auto pass = std::make_unique<Pass>();
  pass->commands = commands;
  // Copy only the caller's bytes: a legacy request is shorter than the struct.
  std::memcpy(&pass->request, r, r->structSize);
  pass->colorCount = hasColor ? (r->colorCount ? r->colorCount : 1) : 0;
  pass->layered = layered;
  // Layered passes take one colour target at slice 0, with no preload and no
  // stencil. Anything else stays uniform.
  if (layered && (pass->colorCount != 1 || r->stencilTexture || r->colorSlice ||
                  r->colorLoad == MTLLoadActionLoad ||
                  r->depthLoad == MTLLoadActionLoad)) {
    ++rejected;
    return -1;
  }
  auto firstRoot = hasColor
      ? (__bridge id<MTLTexture>)(void *)r->colorTexture
      : (__bridge id<MTLTexture>)(void *)r->depthTexture;
  NSUInteger absoluteSlice = hasColor ? r->colorSlice : r->depthSlice;
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
  if (layered) {
    // The two-slice destination stays whole so each layer resolves into its
    // own slice.
    auto texture = (__bridge id<MTLTexture>)(void *)r->colorTexture;
    if (!firstRoot || texture.textureType != MTLTextureType2DArray ||
        texture.arrayLength != 2 || texture.device != commands.device ||
        absoluteSlice + 1 >= firstRoot.arrayLength) {
      ++rejected;
      return -1;
    }
    pass->layeredColor = texture;
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
  if (layered && depth) {
    auto layeredDepth = (__bridge id<MTLTexture>)(void *)r->depthTexture;
    if (r->depthSlice || layeredDepth.textureType != MTLTextureType2DArray ||
        layeredDepth.arrayLength != 2) {
      ++rejected;
      return -1;
    }
    pass->layeredDepth = layeredDepth;
  }
  if (depth &&
      (r->depthLoad == MTLLoadActionLoad ||
       (pass->stencil && r->stencilLoad == MTLLoadActionLoad)) &&
      pass->firstPreload < 0)
    pass->firstPreload = 0;
  std::lock_guard<std::mutex> lock(stateMutex);
  EyeTarget *entry = nullptr;
  MTLSize size{};
  const auto &yoro = yoroConfig();
  const bool yoroSkip =
      yoro.enabled || (r->flags & WVR_GUEST_FOVEATION_YORO_SECONDARY_SKIP) != 0;
  if (r->flags & WVR_GUEST_FOVEATION_YORO_SECONDARY_SKIP)
    lastYoroSkipRequested.store(true, std::memory_order_relaxed);
  const float yoroScale = yoro.scale;
  const auto &drs = drsConfig();
  const float currentDrsScale =
      drs.enabled ? drsScale.load(std::memory_order_relaxed) : 1.0f;
  const float quantizedDrsScale =
      std::clamp(std::round(currentDrsScale * 20.0f) / 20.0f,
                 drs.enabled ? drs.minScale : 0.125f, 1.0f);
  if (layered) {
    // The pair occupies slice s for role 0 and slice s+1 for role 1 of one root.
    for (auto &target : targets)
      if (target.root == firstRoot && target.slice == absoluteSlice &&
          target.role == 0 && !target.derived && !target.atlas &&
          target.eyeWidth >= 512 &&
          eyeSizeMatches(r->width, r->height, target.eyeWidth,
                         target.eyeHeight)) {
        entry = &target;
        break;
      }
    bool paired = false;
    if (entry)
      for (const auto &other : targets)
        paired |= other.root == firstRoot &&
                  other.slice == absoluteSlice + 1 && other.role == 1 &&
                  !other.derived && !other.atlas &&
                  other.eyeWidth == entry->eyeWidth &&
                  other.eyeHeight == entry->eyeHeight;
    if (!entry || !paired) {
      ++unmatchedTargets;
      ++rejected;
      return -1;
    }
    const auto now = CACurrentMediaTime();
    if (!eyeMaps[0].map || !eyeMaps[1].map ||
        now - eyeMaps[0].published > 0.025 ||
        now - eyeMaps[1].published > 0.025) {
      ++staleMaps;
      ++rejected;
      return -1;
    }
    if (!refreshLayered(*entry, eyeMaps, r->width, r->height,
                        commands.device, yoroSkip, yoroScale,
                        quantizedDrsScale)) {
      ++rejected;
      return -1;
    }
    pass->map = entry->layeredMap;
    pass->parameters = entry->layeredParameters;
    pass->layerParameters[0] = entry->layerParameters[0];
    pass->layerParameters[1] = entry->layerParameters[1];
    std::memcpy(pass->layerBounds, entry->layerBounds,
                sizeof(pass->layerBounds));
    size = MTLSizeMake(
        std::max(entry->layerPhysical[0].width, entry->layerPhysical[1].width),
        std::max(entry->layerPhysical[0].height,
                 entry->layerPhysical[1].height),
        1);
    if (!pass->map || !pass->parameters || !pass->layerParameters[0] ||
        !pass->layerParameters[1]) {
      ++rejected;
      return -1;
    }
    if (!size.width || !size.height ||
        size.width * size.height >= uint64_t(r->width) * r->height) {
      ++rejected;
      return -1;
    }
  } else {
    for (auto &target : targets)
      if (target.root == firstRoot && target.slice == absoluteSlice) {
        entry = &target;
        break;
      }
    if (entry && entry->singleEye) {
      // A single eye-sized offscreen target follows the latest eye identity.
      if (!lastIdentityKnown) {
        ++unmatchedTargets;
        ++rejected;
        return -1;
      }
      entry->role = lastIdentityRole;
    } else if (entry && !entry->derived && !entry->atlas) {
      lastIdentityRole = entry->role;
      lastIdentityKnown = true;
    }
    if (!entry) {
      uint32_t matchedEyeWidth = 0, matchedEyeHeight = 0;
      bool matchedAtlas = false, matchedSingle = false;
      for (const auto &existing : targets) {
        if (!existing.root || existing.derived || existing.eyeWidth < 512 ||
            existing.eyeHeight < 512)
          continue;
        if (existing.atlas) {
          if (absoluteSlice == 0 && r->width == 2 * existing.eyeWidth &&
              r->height == existing.eyeHeight) {
            matchedEyeWidth = existing.eyeWidth;
            matchedEyeHeight = existing.eyeHeight;
            matchedAtlas = true;
            break;
          }
          continue;
        }
        if (firstRoot.arrayLength >= 2 && absoluteSlice < 2 &&
            eyeSizeMatches(r->width, r->height, existing.eyeWidth,
                           existing.eyeHeight)) {
          matchedEyeWidth = existing.eyeWidth;
          matchedEyeHeight = existing.eyeHeight;
          matchedAtlas = false;
          break;
        }
        if (firstRoot.arrayLength == 1 && absoluteSlice == 0 &&
            lastIdentityKnown &&
            eyeSizeMatches(r->width, r->height, existing.eyeWidth,
                           existing.eyeHeight)) {
          matchedEyeWidth = existing.eyeWidth;
          matchedEyeHeight = existing.eyeHeight;
          matchedAtlas = false;
          matchedSingle = true;
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
            slot.derived = true;
            if (role == 0)
              entry = &slot;
          }
        } else {
          auto &slot = targets[nextTarget++ % targets.size()];
          slot = EyeTarget{};
          slot.root = firstRoot;
          slot.role = matchedSingle ? lastIdentityRole : uint32_t(absoluteSlice);
          slot.slice = uint32_t(absoluteSlice);
          slot.eyeWidth = matchedEyeWidth;
          slot.eyeHeight = matchedEyeHeight;
          slot.atlas = false;
          slot.derived = true;
          slot.singleEye = matchedSingle;
          entry = &slot;
        }
      }
      // Eye-like targets that match no eye size or scale reuse the reference
      // eye's rates at their own size. The reference is the most recent eye-0
      // map, or the last identity-matched eye when one is known. The adapted
      // map is cached on the target entry, so it is rebuilt only on resize.
      if (!entry && firstRoot.arrayLength == 1 && absoluteSlice == 0 &&
          (firstRoot.usage & MTLTextureUsageRenderTarget) != 0) {
        const uint32_t reference = lastIdentityKnown ? lastIdentityRole : 0;
        const EyeTarget *eyeRef = nullptr;
        for (const auto &existing : targets)
          if (existing.root && !existing.derived && !existing.atlas &&
              existing.role == reference && existing.eyeWidth >= 512 &&
              existing.eyeHeight >= 512) {
            eyeRef = &existing;
            break;
          }
        if (eyeRef) {
          const uint32_t refWidth = eyeRef->eyeWidth,
                         refHeight = eyeRef->eyeHeight;
          const double refAspect = double(refWidth) / refHeight;
          const double aspect = double(r->width) / r->height;
          const bool eyeLike =
              std::fabs(aspect / refAspect - 1.0) <= 0.02 &&
              r->width >= 0.25 * refWidth && r->width <= 2.0 * refWidth &&
              r->height >= 0.25 * refHeight && r->height <= 2.0 * refHeight;
          if (eyeLike) {
            auto &slot = targets[nextTarget++ % targets.size()];
            slot = EyeTarget{};
            slot.root = firstRoot;
            slot.role = reference;
            slot.slice = uint32_t(absoluteSlice);
            slot.eyeWidth = refWidth;
            slot.eyeHeight = refHeight;
            slot.derived = true;
            entry = &slot;
            ++anySizeTargets;
          }
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
    const bool targetYoroSkip = yoroSkip && (entry->atlas || entry->role == 1);
    const float targetYoroScale = targetYoroSkip ? yoroScale : 1.0f;
    const float singleScale = (entry->role == 1)
                                  ? (quantizedDrsScale * targetYoroScale)
                                  : quantizedDrsScale;
    if (entry->sourceMap != left.map || entry->mapLayer != left.layer ||
        (entry->atlas && (entry->rightSourceMap != right.map ||
                          entry->rightMapLayer != right.layer)) ||
        entry->yoroSkip != targetYoroSkip ||
        entry->yoroScale != targetYoroScale ||
        std::fabs(entry->drsScale - quantizedDrsScale) >= 0.025f ||
        entry->adaptedMap.screenSize.width != r->width ||
        entry->adaptedMap.screenSize.height != r->height) {
      entry->adaptedMap =
          entry->atlas
              ? adaptStereoAtlas(left, right, entry->eyeWidth, entry->eyeHeight,
                                 quantizedDrsScale,
                                 quantizedDrsScale * targetYoroScale)
              : adaptMap(left.map, left.layer, r->width, r->height,
                         singleScale < 0.999f, singleScale);
      entry->sourceMap = left.map;
      entry->mapLayer = left.layer;
      entry->rightSourceMap = entry->atlas ? right.map : nil;
      entry->rightMapLayer = right.layer;
      entry->yoroSkip = targetYoroSkip;
      entry->yoroScale = targetYoroScale;
      entry->drsScale = quantizedDrsScale;
      entry->parameters =
          entry->adaptedMap
              ? [commands.device
                    newBufferWithLength:entry->adaptedMap
                                            .parameterBufferSizeAndAlign.size
                                options:MTLResourceStorageModeShared]
              : nil;
      if (entry->parameters)
        [entry->adaptedMap copyParameterDataToBuffer:entry->parameters offset:0];
      entry->physicalSize = entry->adaptedMap
          ? [entry->adaptedMap physicalSizeForLayer:0]
          : MTLSize{};
      if (entry->adaptedMap) {
        // physicalSizeForLayer includes tile padding that the scene never
        // rasterizes. Clamp reconstruction to pixel centers actually covered by
        // the logical image.
        const auto seam = [entry->adaptedMap
            mapScreenToPhysicalCoordinates:(MTLCoordinate2D){
                                               float(r->width / 2), 0}
                                  forLayer:0];
        const auto logicalEnd = [entry->adaptedMap
            mapScreenToPhysicalCoordinates:(MTLCoordinate2D){float(r->width),
                                                             float(r->height)}
                                  forLayer:0];
        entry->bounds[0] = uint32_t(std::round(logicalEnd.x));
        entry->bounds[1] = uint32_t(std::round(logicalEnd.y));
        entry->bounds[2] = entry->atlas ? r->width / 2 : 0;
        entry->bounds[3] = entry->atlas ? uint32_t(std::round(seam.x)) : 0;
      }
    }
    pass->atlas = entry->atlas;
    pass->map = entry->adaptedMap;
    pass->parameters = entry->parameters;
    if (!pass->map || !pass->parameters) {
      ++rejected;
      return -1;
    }
    std::memcpy(pass->bounds, entry->bounds, sizeof(pass->bounds));
    size = entry->physicalSize;
    if (!size.width || !size.height ||
        size.width * size.height >= uint64_t(r->width) * r->height) {
      ++rejected;
      return -1;
    }
  }
  pass->scene = [MTLRenderPassDescriptor new];
  pass->scene.rasterizationRateMap = pass->map;
  if (layered)
    pass->scene.renderTargetArrayLength = 2;
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
    if (layered) {
      td.textureType = MTLTextureType2DArray;
      td.arrayLength = 2;
    }
    if (!cached || cached.width < size.width || cached.height < size.height ||
        cached.pixelFormat != color.pixelFormat ||
        cached.arrayLength != (layered ? 2u : 1u))
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
  if (!hasColor) {
    pass->depthPipeline = pipelineFor(commands.device, MTLPixelFormatInvalid,
                                      true, false, false, true);
    if (!pass->depthPipeline) {
      ++rejected;
      return -1;
    }
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
    if (layered) {
      td.textureType = MTLTextureType2DArray;
      td.arrayLength = 2;
    }
    if (!cached || cached.width < size.width || cached.height < size.height ||
        cached.pixelFormat != depth.pixelFormat ||
        cached.arrayLength != (layered ? 2u : 1u))
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
  // Layered resolves chain their two encoders with a fence, as MRT does.
  if (pass->firstPreload >= 0 || pass->colorCount > 1 || layered) {
    pass->chain = [commands.device newFence];
    if (!pass->chain)
      return -1;
  }
  if (CACurrentMediaTime() - eyeMaps[layered ? 0 : entry->role].published >
      0.025) {
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
  if (layered)
    ++layeredBegun;
  if (entry->atlas)
    ++atlasBegun;
  if (yoroSkip && (layered || entry->atlas || entry->role == 1))
    ++yoroSecondaryPasses;
  sceneDraws.fetch_add(r->drawCalls);
  logicalArea.fetch_add(uint64_t(r->width) * r->height);
  mappedArea.fetch_add(uint64_t(size.width) * size.height);
  return 0;
}
extern "C" int wvr_guest_foveation_copy_gaze_v1(uint32_t eye, float *outCenterUV,
                                                float *outRadiusUV) {
  if (!outCenterUV || !outRadiusUV)
    return 0;
  outCenterUV[0] = 0.5f;
  outCenterUV[1] = 0.5f;
  *outRadiusUV = 0.25f;
  if (eye > 1)
    return 0;
  std::lock_guard<std::mutex> lock(stateMutex);
  const auto &source = eyeMaps[eye];
  if (!source.map)
    return 0;
  auto &gaze = gazeEstimates[eye];
  // Recomputed when the published map object or its layer changes, and at
  // most every 33 ms otherwise: the system may refresh a reused map's rates
  // in place as gaze moves, which the identity check alone would not see.
  const double computeNow = CACurrentMediaTime();
  if (!gaze.computed || gaze.map != source.map || gaze.layer != source.layer ||
      computeNow - gaze.computedAt >= 0.033) {
    gaze.map = source.map;
    gaze.layer = source.layer;
    gaze.computed = true;
    gaze.computedAt = computeNow;
    gaze.valid = computeGaze(source.map, source.layer, gaze.centerU,
                             gaze.centerV, gaze.radius);
    if (!gaze.valid) {
      gaze.centerU = gaze.centerV = 0.5f;
      gaze.radius = 0.25f;
    }
  }
  const double now = CACurrentMediaTime();
  if (!gaze.valid) {
    if (now - gaze.lastLog >= 0.5) {
      NSLog(@"[guest-foveation] gaze unavailable eye=%u", eye);
      gaze.lastLog = now;
    }
    return 0;
  }
  outCenterUV[0] = gaze.centerU;
  outCenterUV[1] = gaze.centerV;
  *outRadiusUV = gaze.radius;
  const bool changed =
      !gaze.logged || std::fabs(gaze.centerU - gaze.loggedU) > 0.02f ||
      std::fabs(gaze.centerV - gaze.loggedV) > 0.02f ||
      std::fabs(gaze.radius - gaze.loggedRadius) > 0.02f;
  if (changed && (!gaze.logged || now - gaze.lastLog >= 0.5)) {
    NSLog(@"[guest-foveation] gaze eye=%u centerUV=(%.3f, %.3f) radiusUV=%.3f",
          eye, gaze.centerU, gaze.centerV, gaze.radius);
    gaze.logged = true;
    gaze.loggedU = gaze.centerU;
    gaze.loggedV = gaze.centerV;
    gaze.loggedRadius = gaze.radius;
    gaze.lastLog = now;
  }
  return 1;
}
extern "C" int wvr_guest_foveation_yoro_secondary_skip_v1(float *outScale) {
  const auto &cfg = yoroConfig();
  if (!cfg.enabled && !lastYoroSkipRequested.load(std::memory_order_relaxed))
    return 0;
  if (outScale)
    *outScale = cfg.scale;
  return 1;
}
extern "C" void
wvr_guest_foveation_report_frame_interval_v1(uint64_t producerFrameID,
                                             uint64_t intervalNanoseconds) {
  const auto &cfg = drsConfig();
  if (!cfg.enabled || intervalNanoseconds == 0)
    return;
  const float intervalMs = float(double(intervalNanoseconds) / 1e6);
  if (!std::isfinite(intervalMs) || intervalMs <= 0.0f)
    return;

  std::lock_guard<std::mutex> lock(drsGovernorMutex);
  if (drsCurrentEmaMs <= 0.0f) {
    drsCurrentEmaMs = intervalMs;
  } else {
    constexpr float alpha = 0.1f;
    drsCurrentEmaMs = alpha * intervalMs + (1.0f - alpha) * drsCurrentEmaMs;
  }
  drsEmaMs.store(drsCurrentEmaMs, std::memory_order_relaxed);

  const double now = CACurrentMediaTime();
  if (drsLastUpdateTime == 0.0) {
    drsLastUpdateTime = now;
    return;
  }
  if (now - drsLastUpdateTime < 0.250)
    return;

  const float current = drsScale.load(std::memory_order_relaxed);
  float updated = current;
  if (drsCurrentEmaMs > cfg.targetMs * 1.05f) {
    updated = std::max(cfg.minScale, current - 0.05f);
  } else if (drsCurrentEmaMs < cfg.targetMs * 1.02f &&
             now - drsLastChangeTime >= 1.0) {
    // A frame-capped game never runs faster than the target, so probe upwards
    // slowly while on target; a resulting miss lowers the scale again.
    updated = std::min(1.0f, current + 0.05f);
  }
  updated = std::clamp(std::round(updated * 20.0f) / 20.0f, cfg.minScale, 1.0f);
  drsLastUpdateTime = now;

  if (std::fabs(updated - current) >= 0.025f) {
    drsScale.store(updated, std::memory_order_relaxed);
    drsAdjustments.fetch_add(1, std::memory_order_relaxed);
    drsLastChangeTime = now;
    if (now - drsLastLogTime >= 1.0) {
      drsLastLogTime = now;
      NSLog(@"[guest-foveation] drsScale=%.2f emaMs=%.2f targetMs=%.2f",
            updated, drsCurrentEmaMs, cfg.targetMs);
    }
  }
}
extern "C" int wvr_guest_foveation_copy_stats_v1(char *buffer,
                                                 uint32_t capacity) {
  if (!buffer || !capacity)
    return 0;
  const auto adaptations = mapAdaptations.load();
  const auto area = logicalArea.load();
  const auto &yoro = yoroConfig();
  std::snprintf(
      buffer, capacity,
      "guestFoveation begun=%llu resolved=%llu rejected=%llu draws=%llu "
      "unmatchedTargets=%llu staleMaps=%llu mapAreaRatio=%.3f "
      "systemMaps=per-eye maxAgeMs=25 adaptations=%llu meanAdaptCPUms=%.3f "
      "atlas=%llu bridgeCalls=%llu capabilities=%llu uniform=%llu "
      "eventNotifications=%llu sliceViewHits=%llu sliceViewCreates=%llu "
      "layeredBegun=%llu anySizeTargets=%llu yoroSecondary=%llu "
      "yoroScale=%.2f drsScale=%.2f drsEmaMs=%.2f drsAdjustments=%llu",
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
      (unsigned long long)sliceViewCreates.load(std::memory_order_relaxed),
      (unsigned long long)layeredBegun.load(),
      (unsigned long long)anySizeTargets.load(),
      (unsigned long long)yoroSecondaryPasses.load(), double(yoro.scale),
      double(drsScale.load(std::memory_order_relaxed)),
      double(drsEmaMs.load(std::memory_order_relaxed)),
      (unsigned long long)drsAdjustments.load(std::memory_order_relaxed));
  return 1;
}
