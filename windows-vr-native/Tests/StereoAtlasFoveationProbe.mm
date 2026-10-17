#import "WindowsVRGuestFoveation.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <initializer_list>
#include <thread>
extern "C" {
void *dxmt_winemetal_unix_call_funcs[148] = {};
size_t wvr_dxmt_d3d12_unix_call_count_v1() { return 148; }
unsigned wvr_dxmt_d3d12_transport_abi_v1() { return 1; }
}
static int old(void *) { return 0; }
static id<MTLRasterizationRateMap> makeMap(id<MTLDevice> device,
                                           unsigned center) {
  float x[8], y[8];
  for (unsigned i = 0; i < 8; ++i) {
    x[i] = (i == center || i == center + 1) ? 1 : 0.25;
    y[i] = (i == 3 || i == 4) ? 1 : 0.25;
  }
  auto layer = [[MTLRasterizationRateLayerDescriptor alloc]
      initWithSampleCount:MTLSizeMake(8, 8, 1)
               horizontal:x
                 vertical:y];
  return [device
      newRasterizationRateMapWithDescriptor:
          [MTLRasterizationRateMapDescriptor
              rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(256, 256,
                                                                       1)
                                                     layer:layer]];
}
int main() {
  @autoreleasepool {
    auto device = MTLCreateSystemDefaultDevice();
    assert(device);
    dxmt_winemetal_unix_call_funcs[146] = (void *)old;
    assert(wvr_guest_foveation_install_v1());
    auto queue = [device newCommandQueue];
    auto progressEvent = [device newSharedEvent];
    WVRGuestFoveationPassV1 progress{};
    progress.abiVersion = WVR_GUEST_FOVEATION_ABI;
    progress.structSize = sizeof(progress);
    progress.operation = 5;
    progress.colorTexture = (uint64_t)(__bridge void *)progressEvent;
    auto endpoint = (int (*)(void *))dxmt_winemetal_unix_call_funcs[146];
    auto progressPointer = &progress;
    assert(endpoint(&progressPointer) == 0 && progress.status == 0 &&
           progress.encoder && progress.token);
    auto page = (const std::atomic<uint64_t> *)progress.encoder;
    assert(page->load(std::memory_order_acquire) == 0);
    auto signal = [queue commandBuffer];
    [signal encodeSignalEvent:progressEvent value:7];
    [signal commit];
    [signal waitUntilCompleted];
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (page->load(std::memory_order_acquire) < 7 &&
           std::chrono::steady_clock::now() < deadline)
      std::this_thread::sleep_for(std::chrono::milliseconds(1));
    assert(page->load(std::memory_order_acquire) == 7);
    progress.operation = 6;
    assert(endpoint(&progressPointer) == 0 && progress.status == 0);
    assert(endpoint(&progressPointer) == 0 && progress.status != 0);
    // Cancellation before a future signal must not leave a dangling guest page.
    progress.operation = 5;
    assert(endpoint(&progressPointer) == 0 && progress.status == 0);
    progress.operation = 6;
    assert(endpoint(&progressPointer) == 0 && progress.status == 0);
    signal = [queue commandBuffer];
    [signal encodeSignalEvent:progressEvent value:9];
    [signal commit];
    [signal waitUntilCompleted];

    auto descriptor = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:512
                                    height:256
                                 mipmapped:NO];
    descriptor.storageMode = MTLStorageModePrivate;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    auto color = [device newTextureWithDescriptor:descriptor];
    auto left = makeMap(device, 2), right = makeMap(device, 5);
    assert(color && left && right);
    NSError *error = nil;
    auto library =
        [device newLibraryWithSource:
                    @"#include <metal_stdlib>\nusing namespace metal;struct "
                    @"V{float4 p [[position]];float2 uv;};vertex V vs(uint i "
                    @"[[vertex_id]]){float2 "
                    @"p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return "
                    @"{float4(p[i],0,1),(p[i]+1)*0.5};}fragment float4 ps(V v "
                    @"[[stage_in]],constant float& eye [[buffer(0)]]){return "
                    @"float4(v.uv,eye,0.625);}"
                             options:nil
                               error:&error];
    assert(library);
    auto pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [library newFunctionWithName:@"vs"];
    pd.fragmentFunction = [library newFunctionWithName:@"ps"];
    pd.colorAttachments[0].pixelFormat = color.pixelFormat;
    auto pipeline = [device newRenderPipelineStateWithDescriptor:pd
                                                           error:&error];
    assert(pipeline);
    auto output = [device newBufferWithLength:512 * 256 * 4
                                      options:MTLResourceStorageModeShared];
    for (unsigned round = 0; round < 3; ++round) {
      auto command = [queue commandBuffer];
      WVRGuestFoveationPassV1 r{};
      r.abiVersion = WVR_GUEST_FOVEATION_ABI;
      r.structSize = sizeof(r);
      r.operation = 1;
      r.flags = 1;
      r.width = 512;
      r.height = 256;
      r.colorCount = 1;
      r.colorLoad = MTLLoadActionClear;
      r.commandBuffer = (uint64_t)(__bridge void *)command;
      r.colorTexture = (uint64_t)(__bridge void *)color;
      r.drawCalls = 2;
      wvr_guest_foveation_register_eye_v1(0, (__bridge void *)color, 0, 0, 0,
                                          256, 256);
      wvr_guest_foveation_publish_maps_v1((__bridge void *)left, 0,
                                          (__bridge void *)right, 0);
      if (!round) {
        assert(wvr_guest_foveation_process_v1(&r) != 0);
        wvr_guest_foveation_register_eye_v1(1, (__bridge void *)color, 0, 256,
                                            0, 256, 256);
      }
      wvr_guest_foveation_publish_maps_v1(
          (__bridge void *)(round % 2 ? right : left), 0,
          (__bridge void *)(round % 2 ? left : right), 0);
      assert(wvr_guest_foveation_process_v1(&r) == 0);
      r.operation = 4;
      assert(wvr_guest_foveation_process_v1(&r) == 0);
      auto encoder = (__bridge id<MTLRenderCommandEncoder>)(void *)r.encoder;
      [encoder setRenderPipelineState:pipeline];
      for (unsigned eye = 0; eye < 2; ++eye) {
        float e = eye;
        [encoder
            setViewport:(MTLViewport){double(eye * 256), 0, 256, 256, 0, 1}];
        [encoder setFragmentBytes:&e length:4 atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                    vertexStart:0
                    vertexCount:3];
      }
      [encoder endEncoding];
      r.operation = 2;
      assert(wvr_guest_foveation_process_v1(&r) == 0);
      [(__bridge id<MTLRenderCommandEncoder>)(void *)r.encoder endEncoding];
      auto blit = [command blitCommandEncoder];
      [blit copyFromTexture:color
                       sourceSlice:0
                       sourceLevel:0
                      sourceOrigin:MTLOriginMake(0, 0, 0)
                        sourceSize:MTLSizeMake(512, 256, 1)
                          toBuffer:output
                 destinationOffset:0
            destinationBytesPerRow:512 * 4
          destinationBytesPerImage:512 * 256 * 4];
      [blit endEncoding];
      [command commit];
      [command waitUntilCompleted];
      assert(!command.error);
      auto bytes = (const uint8_t *)output.contents;
      for (unsigned eye = 0; eye < 2; ++eye)
        for (unsigned y : {32u, 128u, 224u})
          for (unsigned x : {0u, 1u, 8u, 64u, 128u, 192u, 247u, 254u, 255u}) {
            auto pixel = bytes + 4 * (y * 512 + eye * 256 + x);
            if (std::abs(pixel[0] / 255.0 - (x + 0.5) / 256.0) >= 0.025)
              fprintf(stderr,
                      "atlas sample eye=%u x=%u y=%u rgba=%u,%u,%u,%u\n", eye,
                      x, y, pixel[0], pixel[1], pixel[2], pixel[3]);
            assert(std::abs(pixel[0] / 255.0 - (x + 0.5) / 256.0) < 0.025);
            assert(std::abs(pixel[1] / 255.0 - (1.0 - (y + 0.5) / 256.0)) <
                   0.025);
            assert(std::abs(pixel[2] / 255.0 - eye) < 0.025);
            assert(std::abs(pixel[3] / 255.0 - 0.625) < 0.01);
          }
    }
    // Verify offscreen stereo scene render targets (e.g. UE4 RGBA16Float SceneColor)
    // matching an active >= 512x512 VR swapchain atlas are auto-registered and foveated.
    auto swapAtlasDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                     width:1024
                                    height:512
                                 mipmapped:NO];
    swapAtlasDesc.storageMode = MTLStorageModePrivate;
    swapAtlasDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    auto swapAtlas = [device newTextureWithDescriptor:swapAtlasDesc];
    auto sceneColorDesc = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                     width:1024
                                    height:512
                                 mipmapped:NO];
    sceneColorDesc.storageMode = MTLStorageModePrivate;
    sceneColorDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    auto sceneColor = [device newTextureWithDescriptor:sceneColorDesc];
    assert(swapAtlas && sceneColor);
    wvr_guest_foveation_register_eye_v1(0, (__bridge void *)swapAtlas, 0, 0, 0,
                                        512, 512);
    wvr_guest_foveation_register_eye_v1(1, (__bridge void *)swapAtlas, 0, 512,
                                        0, 512, 512);
    wvr_guest_foveation_publish_maps_v1((__bridge void *)left, 0,
                                        (__bridge void *)right, 0);
    auto sceneCmd = [queue commandBuffer];
    WVRGuestFoveationPassV1 scenePass{};
    scenePass.abiVersion = WVR_GUEST_FOVEATION_ABI;
    scenePass.structSize = sizeof(scenePass);
    scenePass.operation = 1;
    scenePass.flags = 1;
    scenePass.width = 1024;
    scenePass.height = 512;
    scenePass.colorCount = 1;
    scenePass.colorLoad = MTLLoadActionClear;
    scenePass.commandBuffer = (uint64_t)(__bridge void *)sceneCmd;
    scenePass.colorTexture = (uint64_t)(__bridge void *)sceneColor;
    scenePass.drawCalls = 4;
    assert(wvr_guest_foveation_process_v1(&scenePass) == 0);
    scenePass.operation = 4;
    assert(wvr_guest_foveation_process_v1(&scenePass) == 0);
    [(__bridge id<MTLRenderCommandEncoder>)(void *)scenePass.encoder endEncoding];
    scenePass.operation = 2;
    assert(wvr_guest_foveation_process_v1(&scenePass) == 0);
    [(__bridge id<MTLRenderCommandEncoder>)(void *)scenePass.encoder endEncoding];
    [sceneCmd commit];
    [sceneCmd waitUntilCompleted];
    assert(!sceneCmd.error);

    char stats[512];
    assert(wvr_guest_foveation_copy_stats_v1(stats, sizeof(stats)));
    puts(stats);
    puts("PASS: paired stereo atlas, offscreen scene atlas auto-registration, asymmetric changing system maps, both eye "
         "viewports and colors/alpha; unpaired atlas rejected");
  }
}
