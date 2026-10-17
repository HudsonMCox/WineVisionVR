#import "../include/WindowsVRGuestFoveation.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
extern "C" {
void *dxmt_winemetal_unix_call_funcs[148] = {};
size_t wvr_dxmt_d3d12_unix_call_count_v1() { return 148; }
unsigned wvr_dxmt_d3d12_transport_abi_v1() { return 1; }
}
static int forwarded = 0;
static int original(void *) {
  ++forwarded;
  return 37;
}
static void require(bool v, const char *why) {
  if (!v) {
    fprintf(stderr, "FAIL: %s\n", why);
    exit(1);
  }
}
static WVRGuestFoveationPassV1 request(id<MTLCommandBuffer> cb,
                                       id<MTLTexture> color,
                                       id<MTLTexture> depth, unsigned slice) {
  WVRGuestFoveationPassV1 r{};
  r.abiVersion = WVR_GUEST_FOVEATION_ABI;
  r.structSize = sizeof(r);
  r.operation = 1;
  r.flags = WVR_GUEST_FOVEATION_SAFE_SHADER;
  r.drawCalls = 1;
  r.width = 256;
  r.height = 256;
  r.colorLoad = MTLLoadActionClear;
  r.depthLoad = MTLLoadActionClear;
  r.commandBuffer = (uint64_t)(__bridge void *)cb;
  r.colorTexture = (uint64_t)(__bridge void *)color;
  r.depthTexture = (uint64_t)(__bridge void *)depth;
  r.colorSlice = r.depthSlice = slice;
  r.clearDepth = 1;
  return r;
}
static id<MTLRasterizationRateMap> map(id<MTLDevice> d, bool shift) {
  float x[8], y[8];
  for (unsigned n = 0; n < 8; ++n) {
    x[n] = (n == (shift ? 5 : 2) || n == (shift ? 6 : 3)) ? 1 : 0.25;
    y[n] = (n == 3 || n == 4) ? 1 : 0.25;
  }
  auto l = [[MTLRasterizationRateLayerDescriptor alloc]
      initWithSampleCount:MTLSizeMake(8, 8, 1)
               horizontal:x
                 vertical:y];
  return
      [d newRasterizationRateMapWithDescriptor:
              [MTLRasterizationRateMapDescriptor
                  rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(
                                                                   shift ? 4096
                                                                         : 256,
                                                                   shift ? 4096
                                                                         : 256,
                                                                   1)
                                                         layer:l]];
}
int main(int argc, char **argv) {
  @autoreleasepool {
    const bool positionShader = argc == 2;
    const bool mrt = argc == 3;
    const bool stencil = mrt && !std::strcmp(argv[2], "stencil");
    const bool srgb = mrt && !std::strcmp(argv[2], "srgb");
    auto d = MTLCreateSystemDefaultDevice();
    require(d && [d supportsRasterizationRateMapWithLayerCount:1],
            "VRR device available");
    dxmt_winemetal_unix_call_funcs[146] = (void *)original;
    require(wvr_guest_foveation_install_v1() == 1,
            "transport install and all resolve shader pipelines compile");
    require(wvr_guest_foveation_install_v1() == 1, "idempotent installation");
    WVRGuestFoveationPassV1 old{};
    old.abiVersion = 1;
    auto ptr = &old;
    auto dispatch = (int (*)(void *))dxmt_winemetal_unix_call_funcs[146];
    require(dispatch(&ptr) == 37 && forwarded == 1,
            "existing ABI forwarded unchanged");
    WVRGuestFoveationPassV1 capabilities{};
    capabilities.abiVersion = WVR_GUEST_FOVEATION_ABI;
    capabilities.structSize = sizeof(capabilities);
    require(wvr_guest_foveation_process_v1(&capabilities) == 0 && capabilities.encoder,
            "capability handshake returns the borrowed identity buffer");
    auto identity = (__bridge id<MTLBuffer>)(void *)capabilities.encoder;
    require(identity.device == d && identity.length > 0,
            "identity buffer belongs to the compositor device");
    auto q = [d newCommandQueue];
    auto m = map(d, false);
    auto shifted = map(d, true);
    require(m && shifted, "synthetic maps");
    auto td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:(srgb ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm)
                                     width:256
                                    height:256
                                 mipmapped:NO];
    td.textureType = MTLTextureType2DArray;
    td.arrayLength = 2;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead |
               MTLTextureUsagePixelFormatView;
    auto color = [d newTextureWithDescriptor:td];
    td.pixelFormat = stencil ? MTLPixelFormatDepth32Float_Stencil8
                             : MTLPixelFormatDepth32Float;
    auto depth = [d newTextureWithDescriptor:td];
    require(color && depth, "stereo scene textures");
    td.pixelFormat = MTLPixelFormatRGBA16Float;
    auto extra = mrt ? [d newTextureWithDescriptor:td] : nil;
    auto cb = [q commandBuffer];
    auto r = request(cb, color, depth, 0);
    require(wvr_guest_foveation_process_v1(&r) != 0,
            "unregistered target falls back");
    wvr_guest_foveation_register_eye_v1(0, (__bridge void *)color, 0, 0, 0, 256,
                                        256);
    wvr_guest_foveation_register_eye_v1(1, (__bridge void *)color, 1, 0, 0, 256,
                                        256);
    require(wvr_guest_foveation_process_v1(&r) != 0, "missing maps fall back");
    wvr_guest_foveation_publish_maps_v1((__bridge void *)m, 0,
                                        (__bridge void *)shifted, 0);
    r.colorLoad = MTLLoadActionClear;
    r.flags = 0;
    require(wvr_guest_foveation_process_v1(&r) != 0,
            "unsafe shader falls back");
    r.flags = WVR_GUEST_FOVEATION_SAFE_SHADER;
    r.width = 128;
    require(wvr_guest_foveation_process_v1(&r) != 0,
            "mismatched logical extent falls back");
    r.width = 256;
    r.colorSlice = 2;
    require(wvr_guest_foveation_process_v1(&r) != 0,
            "invalid array slice falls back");
    r.colorSlice = 0;
    auto invalidABI = r;
    invalidABI.abiVersion++;
    require(wvr_guest_foveation_process_v1(&invalidABI) != 0,
            "unknown request ABI rejected");
    std::this_thread::sleep_for(std::chrono::milliseconds(30));
    r.flags = WVR_GUEST_FOVEATION_SAFE_SHADER;
    require(wvr_guest_foveation_process_v1(&r) != 0, "stale maps fall back");
    NSError *error = nil;
    auto library = [d
        newLibraryWithSource:
            @"#include <metal_stdlib>\nusing namespace metal; struct V{float4 "
            @"p [[position]];float2 uv;}; vertex V vs(uint i "
            @"[[vertex_id]]){float2 "
            @"p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};return "
            @"{float4(p[i],0.375,1),(p[i]+1)*0.5};} fragment float4 ps(V v "
            @"[[stage_in]],constant float &eye [[buffer(0)]]){return "
            @"float4(v.uv.x,v.uv.y,eye,0.625);}\nstruct O{float4 a "
            @"[[color(0)]];float4 b [[color(1)]];}; fragment O ps_mrt(V v "
            @"[[stage_in]],constant float &eye [[buffer(0)]]){return "
            @"{float4(v.uv,eye,0.625),float4(1-v.uv.x,v.uv.y,1-eye,0.375)};}"
                     options:nil
                       error:&error];
    require(library != nil, [[error description] UTF8String]);
    auto positionLibrary =
        positionShader ? [d newLibraryWithURL:[NSURL fileURLWithPath:@(argv[1])]
                                        error:&error]
                       : nil;
    require(!positionShader || positionLibrary != nil,
            [[error description] UTF8String]);
    auto pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [library newFunctionWithName:@"vs"];
    pd.fragmentFunction =
        positionShader ? [positionLibrary newFunctionWithName:@"position_color"]
                       : [library newFunctionWithName:mrt ? @"ps_mrt" : @"ps"];
    pd.colorAttachments[0].pixelFormat = color.pixelFormat;
    if (mrt)
      pd.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA16Float;
    pd.depthAttachmentPixelFormat = depth.pixelFormat;
    if (stencil)
      pd.stencilAttachmentPixelFormat = depth.pixelFormat;
    auto pso = [d newRenderPipelineStateWithDescriptor:pd error:&error];
    require(pso != nil, [[error description] UTF8String]);
    auto dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    dd.depthWriteEnabled = YES;
    if (stencil) {
      auto state = [MTLStencilDescriptor new];
      state.stencilCompareFunction = MTLCompareFunctionAlways;
      state.depthStencilPassOperation = MTLStencilOperationReplace;
      dd.frontFaceStencil = dd.backFaceStencil = state;
    }
    auto ds = [d newDepthStencilStateWithDescriptor:dd];
    auto pixels = [d newBufferWithLength:256 * 256 * 4 * 2
                                 options:MTLResourceStorageModeShared];
    auto depths = [d newBufferWithLength:256 * 256 * 4 * 2
                                 options:MTLResourceStorageModeShared];
    auto stencils = stencil
                        ? [d newBufferWithLength:256 * 256 * 2
                                         options:MTLResourceStorageModeShared]
                        : nil;
    auto fence = [d newFence];
    auto extras = mrt ? [d newBufferWithLength:256 * 256 * 8 * 2
                                       options:MTLResourceStorageModeShared]
                      : nil;
    auto decode=[&](uint8_t channel){const double value=channel/255.0;return !srgb?value:(value<=0.04045?value/12.92:std::pow((value+0.055)/1.055,2.4));};
    for (unsigned round = 0; round < 3; ++round) {
      cb = [q commandBuffer];
      for (unsigned eye = 0; eye < 2; ++eye) {
        // Republish after shader compilation and before each scene; real maps
        // arrive each compositor frame.
        wvr_guest_foveation_publish_maps_v1(
            (__bridge void *)(round % 2 ? shifted : m), 0,
            (__bridge void *)(round % 2 ? m : shifted), 0);
        r = request(cb, color, depth, eye);
        if (mrt) {
          r.colorCount = 2;
          r.additionalColors[0].texture = (uint64_t)(__bridge void *)extra;
          r.additionalColors[0].slice = eye;
          r.additionalColors[0].load =
              round == 2 ? MTLLoadActionLoad : MTLLoadActionClear;
        }
        if (round == 2) {
          r.colorLoad = MTLLoadActionLoad;
          r.depthLoad = MTLLoadActionLoad;
        }
        if (stencil) {
          r.stencilTexture = (uint64_t)(__bridge void *)depth;
          r.stencilSlice = eye;
          r.stencilLoad = round == 2 ? MTLLoadActionLoad : MTLLoadActionClear;
          r.depthStencilReadOnlyMask = round == 2 ? 2 : 0;
        }
        require(wvr_guest_foveation_process_v1(&r) == 0 && r.encoder,
                "compressed scene begins");
        r.operation = 4;
        require(wvr_guest_foveation_process_v1(&r) == 0 && r.encoder,
                "preloads finish after guest waits");
        auto enc = (__bridge id<MTLRenderCommandEncoder>)(void *)r.encoder;
        [enc setRenderPipelineState:pso];
        [enc setDepthStencilState:ds];
        [enc setViewport:(MTLViewport){0, 0, 256, 256, 0, 1}];
        if (stencil)
          [enc
              setStencilReferenceValue:round == 2 ? 0x55 : (eye ? 0x66 : 0x33)];
        if (round == 2)
          [enc setScissorRect:(MTLScissorRect){0, 0, 128, 256}];
        float value = (eye ? 0.8 : 0.2) + (round == 2 ? 0.1 : 0);
        [enc setFragmentBytes:&value length:sizeof(value) atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle
                vertexStart:0
                vertexCount:3];
        [enc endEncoding];
        auto invalid = r;
        invalid.operation = 2;
        invalid.token++;
        require(wvr_guest_foveation_process_v1(&invalid) != 0,
                "wrong token rejected without consuming pass");
        r.operation = 2;
        require(wvr_guest_foveation_process_v1(&r) == 0 && r.encoder,
                "uniform color and depth resolve begins");
        enc = (__bridge id<MTLRenderCommandEncoder>)(void *)r.encoder;
        [enc updateFence:fence afterStages:MTLRenderStageFragment];
        [enc endEncoding];
        auto blit = [cb blitCommandEncoder];
        [blit waitForFence:fence];
        [blit copyFromTexture:color
                         sourceSlice:eye
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(256, 256, 1)
                            toBuffer:pixels
                   destinationOffset:eye * 256 * 256 * 4
              destinationBytesPerRow:256 * 4
            destinationBytesPerImage:256 * 256 * 4];
        if (mrt)
          [blit copyFromTexture:extra
                           sourceSlice:eye
                           sourceLevel:0
                          sourceOrigin:MTLOriginMake(0, 0, 0)
                            sourceSize:MTLSizeMake(256, 256, 1)
                              toBuffer:extras
                     destinationOffset:eye * 256 * 256 * 8
                destinationBytesPerRow:256 * 8
              destinationBytesPerImage:256 * 256 * 8];
        [blit copyFromTexture:depth
                         sourceSlice:eye
                         sourceLevel:0
                        sourceOrigin:MTLOriginMake(0, 0, 0)
                          sourceSize:MTLSizeMake(256, 256, 1)
                            toBuffer:depths
                   destinationOffset:eye * 256 * 256 * 4
              destinationBytesPerRow:256 * 4
            destinationBytesPerImage:256 * 256 * 4
                             options:stencil
                                         ? MTLBlitOptionDepthFromDepthStencil
                                         : MTLBlitOptionNone];
        if (stencil)
          [blit copyFromTexture:depth
                           sourceSlice:eye
                           sourceLevel:0
                          sourceOrigin:MTLOriginMake(0, 0, 0)
                            sourceSize:MTLSizeMake(256, 256, 1)
                              toBuffer:stencils
                     destinationOffset:eye * 256 * 256
                destinationBytesPerRow:256
              destinationBytesPerImage:256 * 256
                               options:MTLBlitOptionStencilFromDepthStencil];
        [blit endEncoding];
      }
      [cb commit];
      [cb waitUntilCompleted];
      require(cb.status == MTLCommandBufferStatusCompleted,
              [[cb.error description] UTF8String]);
      for (unsigned eye = 0; eye < 2; ++eye)
        for (unsigned y = 8; y < 248; y += 8)
          for (unsigned x = 8; x < 248; x += 8) {
            auto pixel = (unsigned char *)pixels.contents +
                         (eye * 256 * 256 + y * 256 + x) * 4;
            require(std::abs(decode(pixel[0]) - (x + 0.5) / 256.) < 0.025,
                    "uniform horizontal coordinates restored");
            require(std::abs(decode(pixel[1]) -
                             (positionShader ? (y + 0.5) / 256.
                                             : (1 - (y + 0.5) / 256.))) < 0.025,
                    "uniform vertical coordinates restored");
            const double expectedBlue =
                positionShader
                    ? 0.375
                    : ((eye ? 0.8 : 0.2) + (round == 2 && x < 128 ? 0.1 : 0));
            // At the partial-draw boundary the reconstruction filter mixes the
            // adjacent old/new samples. Test its range separately from
            // interiors.
            const bool boundary = round == 2 && x == 128 && !positionShader;
            if (boundary)
              require(
                  decode(pixel[2]) >= expectedBlue - 0.01 &&
                      decode(pixel[2]) <= expectedBlue + 0.11,
                  "partial-draw boundary stays within old/new sample range");
            else
              require(std::abs(decode(pixel[2]) - expectedBlue) < 0.01,
                      "stereo slices preserved");
            require(std::abs(pixel[3] / 255. - 0.625) < 0.01,
                    "alpha preserved");
            if (mrt) {
              auto aux = (_Float16 *)extras.contents +
                         (eye * 256 * 256 + y * 256 + x) * 4;
              require(std::abs(float(aux[0]) - (1 - (x + 0.5) / 256.)) < 0.025,
                      "HDR MRT horizontal coordinates restored");
              if (boundary)
                require(float(aux[2]) >= 1 - expectedBlue - 0.11 &&
                            float(aux[2]) <= 1 - expectedBlue + 0.01,
                        "HDR boundary reconstruction range");
              else
                require(std::abs(float(aux[2]) -
                                 (1 - ((eye ? 0.8 : 0.2) +
                                       (round == 2 && x < 128 ? 0.1 : 0)))) <
                            0.01,
                        "HDR MRT survives partial LOAD and resolve chain");
              require(std::abs(float(aux[3]) - 0.375) < 0.001,
                      "HDR MRT alpha preserved");
            }
            if (stencil)
              require(((uint8_t *)
                           stencils.contents)[eye * 256 * 256 + y * 256 + x] ==
                          (eye ? 0x66 : 0x33),
                      "integer stencil preserved, including read-only partial "
                      "passes");
            require(
                std::abs(
                    ((float *)depths.contents)[eye * 256 * 256 + y * 256 + x] -
                    0.375) < 0.001,
                "depth restored before fence");
          }
    }
    if (positionShader) {
      cb = [q commandBuffer];
      auto pass = [MTLRenderPassDescriptor new];
      pass.colorAttachments[0].texture = color;
      pass.colorAttachments[0].slice = 0;
      pass.colorAttachments[0].loadAction = MTLLoadActionClear;
      pass.colorAttachments[0].storeAction = MTLStoreActionStore;
      pass.depthAttachment.texture = depth;
      pass.depthAttachment.slice = 0;
      pass.depthAttachment.loadAction = MTLLoadActionClear;
      pass.depthAttachment.storeAction = MTLStoreActionStore;
      auto encoder = [cb renderCommandEncoderWithDescriptor:pass];
      r = request(cb, color, depth, 0);
      r.operation = 3;
      r.encoder = (uint64_t)(__bridge void *)encoder;
      require(wvr_guest_foveation_process_v1(&r) == 0,
              "ordinary pass binds identity map");
      [encoder setRenderPipelineState:pso];
      [encoder setDepthStencilState:ds];
      [encoder setViewport:(MTLViewport){0, 0, 256, 256, 0, 1}];
      [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                  vertexStart:0
                  vertexCount:3];
      [encoder endEncoding];
      auto blit = [cb blitCommandEncoder];
      [blit copyFromTexture:color
                       sourceSlice:0
                       sourceLevel:0
                      sourceOrigin:MTLOriginMake(0, 0, 0)
                        sourceSize:MTLSizeMake(256, 256, 1)
                          toBuffer:pixels
                 destinationOffset:0
            destinationBytesPerRow:256 * 4
          destinationBytesPerImage:256 * 256 * 4];
      [blit endEncoding];
      [cb commit];
      [cb waitUntilCompleted];
      require(cb.status == MTLCommandBufferStatusCompleted,
              "identity-mapped AIR pass completes");
      for (unsigned y = 8; y < 248; y += 8)
        for (unsigned x = 8; x < 248; x += 8) {
          auto pixel = (uint8_t *)pixels.contents + (y * 256 + x) * 4;
          require(std::abs(decode(pixel[0]) - (x + 0.5) / 256.) < 0.005 &&
                      std::abs(decode(pixel[1]) - (y + 0.5) / 256.) < 0.005 &&
                      std::abs(decode(pixel[2]) - 0.375) < 0.005 &&
                      std::abs(pixel[3] / 255. - 0.625) < 0.005,
                  "uniform SV_Position xyzw preserved by identity map");
        }
    }
    require(color.width == 256 && color.height == 256,
            "guest resolution unchanged");
    wvr_guest_foveation_reset_v1();
    cb = [q commandBuffer];
    r = request(cb, color, nil, 0);
    require(wvr_guest_foveation_process_v1(&r) != 0,
            "session reset removes maps and targets");
    char stats[512];
    wvr_guest_foveation_copy_stats_v1(stats, sizeof(stats));
    puts(stats);
    puts("PASS: native transport forwarding, VRR shaders, changing maps, "
         "stereo array color/alpha/depth resolve, fence ordering, stale/unsafe "
         "fallback");
  }
}
