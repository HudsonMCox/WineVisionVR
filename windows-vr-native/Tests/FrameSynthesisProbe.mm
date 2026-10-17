#include "WindowsVRFrameSynthesis.h"
#include "WindowsVRReconstruction.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <vector>
extern "C" {
void *dxmt_winemetal_unix_call_funcs[148] = {};
size_t wvr_dxmt_d3d12_unix_call_count_v1() { return 148; }
unsigned wvr_dxmt_d3d12_transport_abi_v1() { return 1; }
}
constexpr unsigned W = 128, H = 64;
static id<MTLTexture> make(id<MTLDevice> d, MTLPixelFormat f, unsigned w = W,
                           unsigned h = H) {
  auto p = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f
                                                              width:w
                                                             height:h
                                                          mipmapped:NO];
  p.storageMode = MTLStorageModeShared;
  p.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
  return [d newTextureWithDescriptor:p];
}
static unsigned color(int x, int y) {
  unsigned a = unsigned(x) * 73856093u ^ unsigned(y) * 19349663u;
  a ^= a >> 13;
  return 40 + a % 176;
}
static void fill(id<MTLTexture> t, int motion, int disparity,
                 bool flat = false) {
  uint8_t pixels[W * H * 4];
  for (unsigned y = 0; y < H; y++)
    for (unsigned x = 0; x < W; x++) {
      unsigned i = (y * W + x) * 4;
      auto v = flat ? 100 : color(int(x) - motion + disparity, y);
      pixels[i] = pixels[i + 1] = pixels[i + 2] = v;
      pixels[i + 3] = 255;
    }
  [t replaceRegion:MTLRegionMake2D(0, 0, W, H)
       mipmapLevel:0
         withBytes:pixels
       bytesPerRow:W * 4];
}
static std::vector<float> readDepth(id<MTLCommandQueue> q, void *pointer) {
  assert(pointer);
  auto t = (__bridge id<MTLTexture>)pointer;
  auto cpu = make(q.device, MTLPixelFormatRG32Float, t.width, t.height);
  auto b = [q commandBuffer];
  auto e = [b blitCommandEncoder];
  [e copyFromTexture:t
            sourceSlice:0
            sourceLevel:0
           sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(t.width, t.height, 1)
              toTexture:cpu
       destinationSlice:0
       destinationLevel:0
      destinationOrigin:MTLOriginMake(0, 0, 0)];
  [e endEncoding];
  [b commit];
  [b waitUntilCompleted];
  assert(b.status == MTLCommandBufferStatusCompleted);
  std::vector<float> data(t.width * t.height * 2);
  [cpu getBytes:data.data()
      bytesPerRow:t.width * 8
       fromRegion:MTLRegionMake2D(0, 0, t.width, t.height)
      mipmapLevel:0];
  wvr_compositor_release_object_v1(pointer);
  return data;
}
static std::vector<_Float16> readColor(id<MTLCommandQueue> q, void *pointer) {
  assert(pointer);
  auto t = (__bridge id<MTLTexture>)pointer;
  auto cpu = make(q.device, MTLPixelFormatRGBA16Float, t.width, t.height);
  auto b = [q commandBuffer];
  auto e = [b blitCommandEncoder];
  [e copyFromTexture:t
            sourceSlice:0
            sourceLevel:0
           sourceOrigin:MTLOriginMake(0, 0, 0)
             sourceSize:MTLSizeMake(t.width, t.height, 1)
              toTexture:cpu
       destinationSlice:0
       destinationLevel:0
      destinationOrigin:MTLOriginMake(0, 0, 0)];
  [e endEncoding];
  [b commit];
  [b waitUntilCompleted];
  assert(b.status == MTLCommandBufferStatusCompleted);
  std::vector<_Float16> data(t.width * t.height * 4);
  [cpu getBytes:data.data()
      bytesPerRow:t.width * 8
       fromRegion:MTLRegionMake2D(0, 0, t.width, t.height)
      mipmapLevel:0];
  wvr_compositor_release_object_v1(pointer);
  return data;
}
int main() {
  @autoreleasepool {
    auto device = MTLCreateSystemDefaultDevice();
    assert(device);
    auto queue = [device newCommandQueue];
    auto otherQueue = [device newCommandQueue];
    assert(wvr_compositor_bind_metal_device_v1((__bridge void *)device) == 0);
    assert(wvr_compositor_publish_targets_v1(W, H, 70, W, H, 70) == 0);
    WVRRenderTargetInfoV1 target{};
    target.structSize = sizeof(target);
    assert(wvr_compositor_copy_targets_v1(&target) == 0);
    auto left = make(device, MTLPixelFormatRGBA8Unorm),
         right = make(device, MTLPixelFormatRGBA8Unorm);
    fill(left, 0, 0);
    fill(right, 0, 2);
    auto event = [device newSharedEvent];
    event.signaledValue = 1;
    WVRFrameTrackingV1 tracking{};
    tracking.abiVersion = 1;
    tracking.structSize = sizeof(tracking);
    tracking.flags = WVRDevicePoseTracked;
    tracking.timestampNanoseconds = 1000000000;
    for (unsigned k = 0; k < 4; k++)
      tracking.originFromDevice[k * 5] = 1;
    for (unsigned eye = 0; eye < 2; eye++) {
      for (unsigned k = 0; k < 4; k++)
        tracking.deviceFromEye[eye][k * 5] = 1;
      tracking.deviceFromEye[eye][12] = eye * .064f;
      auto *p = tracking.projection[eye];
      p[0] = p[5] = 1;
      p[10] = -100.f / 99.9f;
      p[11] = -1;
      p[14] = -10.f / 99.9f;
    }
    WVRSubmitStereoFrameV2 submit{};
    submit.abiVersion = 2;
    submit.structSize = sizeof(submit);
    submit.producerFrameID = 1;
    submit.producerTimestampNanoseconds = 1000000000;
    submit.targetGeneration = target.generation;
    submit.leftTexture = (__bridge void *)left;
    submit.rightTexture = (__bridge void *)right;
    submit.producerReadyEvent = (__bridge void *)event;
    submit.producerReadyValue = 1;
    submit.leftWidth = submit.rightWidth = W;
    submit.leftHeight = submit.rightHeight = H;
    auto ctx = wvr_synthesis_create_v1((__bridge void *)device, 2);
    assert(ctx);
    assert(!wvr_synthesis_create_v1((__bridge void *)device, 3));
    auto ingest = [&](bool finish = true) {
      uint64_t ticket;
      assert(wvr_compositor_submit_stereo_frame_v2(&submit, &ticket) == 0);
      WVRAcquiredStereoFrameV2 frame{};
      frame.structSize = sizeof(frame);
      assert(wvr_compositor_acquire_latest_stereo_frame_v2(&frame) == 0);
      auto b = [queue commandBuffer];
      assert(wvr_synthesis_ingest_v1(ctx, &frame, &tracking, target.generation,
                                     (__bridge void *)b) == 0);
      assert(wvr_synthesis_encode_v1(ctx, submit.producerTimestampNanoseconds,
                                     W, H, W, H, 0, (__bridge void *)b) == 0);
      [b commit];
      if (finish) {
        [b waitUntilCompleted];
        assert(b.status == MTLCommandBufferStatusCompleted);
      }
      wvr_compositor_release_acquired_frame_v1(frame.lease);
    };
    ingest();
    auto depths = readDepth(queue, wvr_synthesis_copy_depth_v1(ctx, 0));
    unsigned confident = 0, accurate = 0;
    for (unsigned y = 5; y < H - 5; y++)
      for (unsigned x = 8; x < W - 8; x++) {
        unsigned i = (y * W + x) * 2;
        if (depths[i + 1] > .2) {
          confident++;
          if (std::fabs(depths[i] - 2.048) < .4)
            accurate++;
        }
      }
    printf("Stereo estimated plane: confident=%u accurate=%u\n", confident,
           accurate);
    assert(confident > W * H / 5 && accurate > confident * .9);
    auto original = readColor(queue, wvr_synthesis_copy_output_v1(ctx, 0));
    for (auto v : original)
      assert(std::isfinite(float(v)));
    // Same textured plane moves 3 pixels. A half-interval forecast must change
    // the image through object flow rather than pretending a head-pose warp is
    // FG.
    fill(left, 3, 0);
    fill(right, 3, 2);
    submit.producerFrameID++;
    submit.producerTimestampNanoseconds += 33333333;
    ingest();
    auto current = readColor(queue, wvr_synthesis_copy_output_v1(ctx, 0));
    auto generated = [queue commandBuffer];
    assert(wvr_synthesis_encode_v1(
               ctx, submit.producerTimestampNanoseconds + 16666666, W, H, W, H,
               1, (__bridge void *)generated) == 0);
    [generated commit];
    [generated waitUntilCompleted];
    assert(generated.status == MTLCommandBufferStatusCompleted);
    auto predicted = readColor(queue, wvr_synthesis_copy_output_v1(ctx, 0));
    unsigned moved = 0;
    for (unsigned i = 0; i < W * H; i++)
      if (std::fabs(float(current[i * 4]) - float(predicted[i * 4])) > .025)
        moved++;
    printf("Extrapolated changed pixels: %u\n", moved);
    assert(moved > W * H / 10);
    double correctDirection = 0, wrongDirection = 0;
    for (unsigned y = 3; y < H - 3; y++)
      for (unsigned x = 8; x < W - 8; x++) {
        unsigned i = (y * W + x) * 4;
        if (std::fabs(float(current[i]) - float(predicted[i])) <= .025)
          continue;
        float expected =
            (color(int(x) - 4, y) + color(int(x) - 5, y)) * .5f / 255;
        float opposite =
            (color(int(x) - 1, y) + color(int(x) - 2, y)) * .5f / 255;
        correctDirection += std::fabs(float(predicted[i]) - expected);
        wrongDirection += std::fabs(float(predicted[i]) - opposite);
      }
    printf("Motion direction error: forward=%.3f backward=%.3f\n",
           correctDirection, wrongDirection);
    assert(correctDirection < wrongDirection * .85);
    auto owned = wvr_synthesis_copy_source_v1(ctx, 0);
    assert(owned && owned != (__bridge void *)left);
    wvr_compositor_release_object_v1(owned);

    // Full output dimensions can exceed guest resolution. No render scale
    // changes.
    auto upscale = [queue commandBuffer];
    assert(wvr_synthesis_encode_v1(ctx, submit.producerTimestampNanoseconds,
                                   W * 2, H * 2, W * 2, H * 2, 0,
                                   (__bridge void *)upscale) == 0);
    [upscale commit];
    [upscale waitUntilCompleted];
    assert(upscale.status == MTLCommandBufferStatusCompleted);
    auto up = readColor(queue, wvr_synthesis_copy_output_v1(ctx, 0));
    assert(up.size() == W * H * 16);
    auto stale = [queue commandBuffer];
    assert(wvr_synthesis_encode_v1(
               ctx, submit.producerTimestampNanoseconds + 100000001, W, H, W, H,
               1, (__bridge void *)stale) == 1);
    assert(!wvr_synthesis_copy_output_v1(ctx, 0));
    auto wrong = [otherQueue commandBuffer];
    assert(wvr_synthesis_encode_v1(ctx, submit.producerTimestampNanoseconds, W,
                                   H, W, H, 1, (__bridge void *)wrong) == 1);
    // Uniform regions have no stereo evidence and must report invalid depth.
    fill(left, 0, 0, true);
    fill(right, 0, 0, true);
    submit.producerFrameID++;
    submit.producerTimestampNanoseconds += 200000000;
    ingest();
    auto flat = readDepth(queue, wvr_synthesis_copy_depth_v1(ctx, 0));
    for (unsigned i = 0; i < W * H; i++)
      assert(flat[i * 2 + 1] == 0);
    // Explicit scene depth wins even when the colour image is textureless.
    auto depthDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                     width:W
                                    height:H
                                 mipmapped:NO];
    depthDesc.storageMode = MTLStorageModePrivate;
    depthDesc.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    auto actualDepth = [device newTextureWithDescriptor:depthDesc];
    auto clear = [queue commandBuffer];
    auto pass = [MTLRenderPassDescriptor new];
    pass.depthAttachment.texture = actualDepth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    pass.depthAttachment.clearDepth = 100.f / 99.9f - (10.f / 99.9f) / 2.048f;
    auto render = [clear renderCommandEncoderWithDescriptor:pass];
    [render endEncoding];
    [clear commit];
    [clear waitUntilCompleted];
    assert(clear.status == MTLCommandBufferStatusCompleted);
    WVRReconstructionSubmitV1 exact{};
    exact.abiVersion = WVR_RECONSTRUCTION_ABI;
    exact.structSize = sizeof(exact);
    exact.producerEvent = (uint64_t)(__bridge void *)event;
    exact.producerValue = 1;
    exact.frameID = ++submit.producerFrameID;
    exact.timestampNanoseconds = submit.producerTimestampNanoseconds +=
        33333333;
    exact.targetGeneration = target.generation;
    for (unsigned eye = 0; eye < 2; eye++) {
      auto &g = exact.eyes[eye];
      g.colorTexture = (uint64_t)(__bridge void *)(eye ? right : left);
      g.depthTexture = (uint64_t)(__bridge void *)actualDepth;
      g.width = g.depthWidth = W;
      g.height = g.depthHeight = H;
      g.minDepth = 0;
      g.maxDepth = 1;
      memcpy(g.originFromEye, tracking.deviceFromEye[eye], 64);
      memcpy(g.projection, tracking.projection[eye], 64);
    }
    assert(wvr_compositor_submit_reconstruction_v1(&exact) == 0);
    wvr_compositor_release_object_v1((void *)exact.consumerEvent);
    WVRAcquiredStereoFrameV2 captured{};
    captured.structSize = sizeof(captured);
    assert(wvr_compositor_acquire_latest_stereo_frame_v2(&captured) == 0);
    auto exactCommands = [queue commandBuffer];
    assert(wvr_synthesis_ingest_v1(ctx, &captured, &tracking, target.generation,
                                   (__bridge void *)exactCommands) == 0);
    assert(wvr_synthesis_encode_v1(ctx, submit.producerTimestampNanoseconds, W,
                                   H, W, H, 0,
                                   (__bridge void *)exactCommands) == 0);
    [exactCommands commit];
    [exactCommands waitUntilCompleted];
    assert(exactCommands.status == MTLCommandBufferStatusCompleted);
    wvr_compositor_release_acquired_frame_v1(captured.lease);
    auto trueDepth = readDepth(queue, wvr_synthesis_copy_depth_v1(ctx, 0));
    for (unsigned i = 0; i < W * H; i++) {
      assert(std::fabs(trueDepth[i * 2] - 2.048f) < .001);
      assert(trueDepth[i * 2 + 1] == 1);
    }
    // Freeze the game view, then move the predicted headset sideways. The
    // new display pose must show depth-correct parallax, not a distant screen.
    fill(left, 0, 0);
    fill(right, 0, 2);
    exact.frameID = ++submit.producerFrameID;
    exact.timestampNanoseconds = submit.producerTimestampNanoseconds +=
        33333333;
    auto ingestExact = [&] {
      assert(wvr_compositor_submit_reconstruction_v1(&exact) == 0);
      wvr_compositor_release_object_v1((void *)exact.consumerEvent);
      WVRAcquiredStereoFrameV2 f{};
      f.structSize = sizeof(f);
      assert(wvr_compositor_acquire_latest_stereo_frame_v2(&f) == 0);
      auto b = [queue commandBuffer];
      assert(wvr_synthesis_ingest_v1(ctx, &f, &tracking, target.generation,
                                     (__bridge void *)b) == 0);
      assert(wvr_synthesis_encode_v1(ctx, submit.producerTimestampNanoseconds,
                                     W, H, W, H, 0, (__bridge void *)b) == 0);
      [b commit];
      [b waitUntilCompleted];
      assert(b.status == MTLCommandBufferStatusCompleted);
      wvr_compositor_release_acquired_frame_v1(f.lease);
    };
    ingestExact();
    WVRFrameSynthesisViewV1 display[2]{};
    for (unsigned eye = 0; eye < 2; eye++) {
      memcpy(display[eye].originFromEye, exact.eyes[eye].originFromEye, 64);
      display[eye].originFromEye[12] += .064;
      memcpy(display[eye].projection, exact.eyes[eye].projection, 64);
      display[eye].width = W;
      display[eye].height = H;
    }
    auto headWarp = [queue commandBuffer];
    assert(wvr_synthesis_encode_display_v1(
               ctx, submit.producerTimestampNanoseconds, display, 0,
               (__bridge void *)headWarp) == 0);
    [headWarp commit];
    [headWarp waitUntilCompleted];
    assert(headWarp.status == MTLCommandBufferStatusCompleted);
    auto parallax = readColor(queue, wvr_synthesis_copy_output_v1(ctx, 0));
    double correct = 0, opposite = 0;
    for (unsigned y = 4; y < H - 4; y++)
      for (unsigned x = 8; x < W - 8; x++) {
        float actual = parallax[(y * W + x) * 4];
        correct += std::fabs(actual - color(x + 2, y) / 255.f);
        opposite += std::fabs(actual - color(x - 2, y) / 255.f);
      }
    printf("Tracked head translation error: correct=%.3f opposite=%.3f\n",
           correct, opposite);
    assert(correct < opposite * .3);
    // Combined yaw and translation are checked against an analytic plane-ray
    // intersection, independently of the GPU's iterative depth-field solve.
    const float angle = .02f, cs = std::cos(angle), sn = std::sin(angle);
    for (unsigned eye = 0; eye < 2; eye++) {
      auto &m = display[eye].originFromEye;
      m[0] = cs;
      m[2] = -sn;
      m[8] = sn;
      m[10] = cs;
      m[12] = .064f + eye * .064f * cs;
      m[14] = -eye * .064f * sn;
    }
    auto rotation = [queue commandBuffer];
    assert(wvr_synthesis_encode_display_v1(
               ctx, submit.producerTimestampNanoseconds, display, 0,
               (__bridge void *)rotation) == 0);
    [rotation commit];
    [rotation waitUntilCompleted];
    assert(rotation.status == MTLCommandBufferStatusCompleted);
    auto rotated = readColor(queue, wvr_synthesis_copy_output_v1(ctx, 0));
    double rotationError = 0;
    for (unsigned y = 4; y < H - 4; y++)
      for (unsigned x = 8; x < W - 8; x++) {
        float rx = (x + .5f) * 2 / W - 1, ry = 1 - (y + .5f) * 2 / H;
        float dx = cs * rx - sn, dz = -sn * rx - cs, lambda = -2.048f / dz;
        float sx = (.5f + (dx * lambda + .064f) / 2.048f * .5f) * W - .5f,
              sy = (.5f - ry * lambda / 2.048f * .5f) * H - .5f;
        int x0 = std::floor(sx), y0 = std::floor(sy);
        float fx = sx - x0, fy = sy - y0;
        float expected =
            ((1 - fy) * ((1 - fx) * color(x0, y0) + fx * color(x0 + 1, y0)) +
             fy * ((1 - fx) * color(x0, y0 + 1) + fx * color(x0 + 1, y0 + 1))) /
            255;
        rotationError += std::fabs(float(rotated[(y * W + x) * 4]) - expected);
      }
    rotationError /= (H - 8) * (W - 16);
    printf("Combined head yaw/parallax mean error: %.6f\n", rotationError);
    assert(rotationError < .04);
    // Fresh game views already include the head movement. It must be removed
    // from object flow, so extrapolation must not move the static world again.
    fill(left, -2, 0);
    fill(right, -2, 2);
    tracking.originFromDevice[12] = .064;
    for (unsigned eye = 0; eye < 2; eye++)
      exact.eyes[eye].originFromEye[12] += .064;
    exact.frameID = ++submit.producerFrameID;
    exact.timestampNanoseconds = submit.producerTimestampNanoseconds +=
        33333333;
    ingestExact();
    auto cameraOnly = readColor(queue, wvr_synthesis_copy_output_v1(ctx, 0));
    auto residual = [queue commandBuffer];
    assert(wvr_synthesis_encode_v1(
               ctx, submit.producerTimestampNanoseconds + 16666666, W, H, W, H,
               1, (__bridge void *)residual) == 0);
    [residual commit];
    [residual waitUntilCompleted];
    assert(residual.status == MTLCommandBufferStatusCompleted);
    auto cameraForecast =
        readColor(queue, wvr_synthesis_copy_output_v1(ctx, 0));
    double falseObjectMotion = 0;
    for (unsigned y = 4; y < H - 4; y++)
      for (unsigned x = 8; x < W - 8; x++) {
        unsigned i = (y * W + x) * 4;
        falseObjectMotion +=
            std::fabs(float(cameraOnly[i]) - float(cameraForecast[i]));
      }
    falseObjectMotion /= (H - 8) * (W - 16);
    printf("Head-only false object motion mean error: %.6f\n",
           falseObjectMotion);
    assert(falseObjectMotion < .01);
    // Object motion under head roll must be expressed in CURRENT-eye axes.
    // An unrotated previous-frame vector would incorrectly lose its Y
    // component.
    const float roll = .4f, cr = std::cos(roll), sr = std::sin(roll);
    for (unsigned eye = 0; eye < 2; eye++) {
      std::vector<uint8_t> pixels(W * H * 4);
      for (unsigned y = 0; y < H; y++)
        for (unsigned x = 0; x < W; x++) {
          float u = (x + .5f) / W - .5f, v = (y + .5f) / H - .5f;
          float px = (.5f + cr * u + sr * v) * W - .5f - 1 + 2 * eye * cr;
          float py = (.5f - sr * u + cr * v) * H - .5f - eye * 2.f * H / W * sr;
          int ix = std::floor(px), iy = std::floor(py);
          float fx = px - ix, fy = py - iy;
          float value =
              (1 - fy) * ((1 - fx) * color(ix, iy) + fx * color(ix + 1, iy)) +
              fy * ((1 - fx) * color(ix, iy + 1) + fx * color(ix + 1, iy + 1));
          auto at = (y * W + x) * 4;
          pixels[at] = pixels[at + 1] = pixels[at + 2] =
              uint8_t(std::round(value));
          pixels[at + 3] = 255;
        }
      auto image = eye ? right : left;
      [image replaceRegion:MTLRegionMake2D(0, 0, W, H)
               mipmapLevel:0
                 withBytes:pixels.data()
               bytesPerRow:W * 4];
      auto &m = exact.eyes[eye].originFromEye;
      m[0] = cr;
      m[1] = sr;
      m[4] = -sr;
      m[5] = cr;
      m[12] = .064f + eye * .064f * cr;
      m[13] = eye * .064f * sr;
    }
    tracking.originFromDevice[0] = cr;
    tracking.originFromDevice[1] = sr;
    tracking.originFromDevice[4] = -sr;
    tracking.originFromDevice[5] = cr;
    exact.frameID = ++submit.producerFrameID;
    exact.timestampNanoseconds = submit.producerTimestampNanoseconds +=
        33333333;
    ingestExact();
    auto rolledFlow = readColor(queue, wvr_synthesis_copy_motion_v1(ctx, 0));
    double vx = 0, vy = 0;
    unsigned reliable = 0;
    for (unsigned y = 16; y < H - 16; y++)
      for (unsigned x = 32; x < W - 32; x++) {
        auto at = (y * W + x) * 4;
        if (float(rolledFlow[at + 2]) > .6) {
          vx += float(rolledFlow[at]) * W;
          vy += float(rolledFlow[at + 1]) * H;
          reliable++;
        }
      }
    assert(reliable > 100);
    vx /= reliable;
    vy /= reliable;
    printf("Head-roll object flow: reliable=%u mean=(%.3f,%.3f) "
           "expected=(%.3f,%.3f)\n",
           reliable, vx, vy, -3 * cr, -3 * sr * H / W);
    assert(std::fabs(vx + 3 * cr) < .6 && std::fabs(vy + 3 * sr * H / W) < .25);
    char stats[2048];
    assert(wvr_synthesis_copy_stats_v1(ctx, stats, sizeof(stats)));
    puts(stats);
    assert(strstr(stats, "gpuFailed=0") &&
           strstr(stats, "stereoEstimatedDepthFrames=3") &&
           strstr(stats, "gameDepthFrames=4"));
    // A changed eye subrectangle resets differently sized flow pyramids, even
    // when the compositor's target generation itself has not changed.
    submit.leftWidth = submit.rightWidth = W / 2;
    submit.producerFrameID++;
    submit.producerTimestampNanoseconds += 33333333;
    ingest();
    auto smaller = wvr_synthesis_copy_source_v1(ctx, 0);
    assert(smaller);
    auto smallerTexture = (__bridge id<MTLTexture>)smaller;
    assert(smallerTexture.width == W / 2);
    wvr_compositor_release_object_v1(smaller);
    submit.leftWidth = submit.rightWidth = W;
    // Spatial-only mode bypasses depth/flow while producing a complete image.
    auto spatialContext = wvr_synthesis_create_v1((__bridge void *)device, 1);
    assert(spatialContext);
    submit.producerFrameID++;
    submit.producerTimestampNanoseconds += 33333333;
    uint64_t spatialTicket = 0;
    assert(wvr_compositor_submit_stereo_frame_v2(&submit, &spatialTicket) == 0);
    WVRAcquiredStereoFrameV2 spatialFrame{};
    spatialFrame.structSize = sizeof(spatialFrame);
    assert(wvr_compositor_acquire_latest_stereo_frame_v2(&spatialFrame) == 0);
    auto spatialCommands = [queue commandBuffer];
    assert(wvr_synthesis_ingest_v1(spatialContext, &spatialFrame, &tracking,
                                   target.generation,
                                   (__bridge void *)spatialCommands) == 0);
    assert(wvr_synthesis_encode_v1(
               spatialContext, submit.producerTimestampNanoseconds, W * 2,
               H * 2, W * 2, H * 2, 1, (__bridge void *)spatialCommands) == 0);
    [spatialCommands commit];
    [spatialCommands waitUntilCompleted];
    assert(spatialCommands.status == MTLCommandBufferStatusCompleted);
    assert(!wvr_synthesis_copy_depth_v1(spatialContext, 0));
    auto spatialOutput =
        readColor(queue, wvr_synthesis_copy_output_v1(spatialContext, 0));
    for (auto v : spatialOutput)
      assert(std::isfinite(float(v)));
    wvr_compositor_release_acquired_frame_v1(spatialFrame.lease);
    wvr_synthesis_destroy_v1(spatialContext);
    // Return to the timestamp of the last frame ingested by the original
    // context.
    submit.producerTimestampNanoseconds -= 33333333;
    // Outstanding GPU handlers own only shared state; context destruction is
    // safe.
    auto pending = [queue commandBuffer];
    assert(wvr_synthesis_encode_v1(ctx, submit.producerTimestampNanoseconds, W,
                                   H, W, H, 0, (__bridge void *)pending) == 0);
    [pending commit];
    wvr_synthesis_destroy_v1(ctx);
    [pending waitUntilCompleted];
    assert(pending.status == MTLCommandBufferStatusCompleted);
    wvr_compositor_pause_v1();
    puts("PASS: production Metal stereo depth, confidence rejection, "
         "object-motion extrapolation, spatial reconstruction, stale/queue "
         "fallback and pending lifetime");
  }
}
