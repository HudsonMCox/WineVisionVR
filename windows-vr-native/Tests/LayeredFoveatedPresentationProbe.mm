#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <simd/simd.h>
struct Region {
  simd_float2 origin, extent;
  uint32_t slice, layer;
  float depth, reserved;
  simd_float4x4 reprojection;
};
static void check(bool v, const char *s) {
  if (!v) {
    fprintf(stderr, "FAIL: %s\n", s);
    exit(1);
  }
}
int main(int argc, char **argv) {
  @autoreleasepool {
    check(argc == 2, "production shader path");
    auto d = MTLCreateSystemDefaultDevice();
    check([d supportsRasterizationRateMapWithLayerCount:2],
          "two-layer VRR support");
    NSError *error = nil;
    auto text = [NSString stringWithContentsOfFile:@(argv[1])
                                          encoding:NSUTF8StringEncoding
                                             error:&error];
    auto lib = [d newLibraryWithSource:text options:nil error:&error];
    check(lib != nil, [[error description] UTF8String]);
    float rates[4] = {0.5, 1, 1, 0.5};
    auto l = [[MTLRasterizationRateLayerDescriptor alloc]
        initWithSampleCount:MTLSizeMake(4, 4, 1)
                 horizontal:rates
                   vertical:rates];
    MTLRasterizationRateLayerDescriptor *layers[2] = {l, l};
    auto md = [MTLRasterizationRateMapDescriptor
        rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(64, 64, 1)
                                          layerCount:2
                                              layers:layers];
    auto map = [d newRasterizationRateMapWithDescriptor:md];
    check(map != nil, "layered map");
    auto physical = [map physicalSizeForLayer:0];
    auto td = [MTLTextureDescriptor
        texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                     width:physical.width
                                    height:physical.height
                                 mipmapped:NO];
    td.textureType = MTLTextureType2DArray;
    td.arrayLength = 2;
    td.storageMode = MTLStorageModePrivate;
    td.usage = MTLTextureUsageRenderTarget;
    auto color = [d newTextureWithDescriptor:td];
    td.pixelFormat = MTLPixelFormatDepth32Float;
    auto depth = [d newTextureWithDescriptor:td];
    auto pd = [MTLRenderPipelineDescriptor new];
    pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    pd.vertexFunction = [lib newFunctionWithName:@"wvr_spatial_vertex"];
    pd.fragmentFunction = [lib newFunctionWithName:@"wvr_spatial_fragment"];
    pd.colorAttachments[0].pixelFormat = color.pixelFormat;
    pd.depthAttachmentPixelFormat = depth.pixelFormat;
    auto pipeline = [d newRenderPipelineStateWithDescriptor:pd error:&error];
    check(pipeline != nil, [[error description] UTF8String]);
    auto sd = [MTLSamplerDescriptor new];
    sd.minFilter = sd.magFilter = MTLSamplerMinMagFilterLinear;
    sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
    auto sampler = [d newSamplerStateWithDescriptor:sd];
    auto dd = [MTLDepthStencilDescriptor new];
    dd.depthWriteEnabled = YES;
    dd.depthCompareFunction = MTLCompareFunctionAlways;
    auto ds = [d newDepthStencilStateWithDescriptor:dd];
    auto queue = [d newCommandQueue];
    auto cb = [queue commandBuffer];
    auto pass = [MTLRenderPassDescriptor new];
    pass.rasterizationRateMap = map;
    pass.renderTargetArrayLength = 2;
    pass.colorAttachments[0].texture = color;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.depthAttachment.texture = depth;
    pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore;
    auto enc = [cb renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:pipeline];
    [enc setDepthStencilState:ds];
    [enc setViewport:(MTLViewport){0, 0, 64, 64, 0, 1}];
    [enc setFragmentSamplerState:sampler atIndex:0];
    for (unsigned eye = 0; eye < 2; ++eye) {
      auto srcd = [MTLTextureDescriptor
          texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                       width:2
                                      height:2
                                   mipmapped:NO];
      srcd.storageMode = MTLStorageModeShared;
      srcd.usage = MTLTextureUsageShaderRead;
      auto src = [d newTextureWithDescriptor:srcd];
      uint8_t pixels[16];
      for (unsigned i = 0; i < 4; ++i) {
        pixels[i * 4] = eye ? 0 : 255;
        pixels[i * 4 + 1] = eye ? 255 : 0;
        pixels[i * 4 + 2] = 0;
        pixels[i * 4 + 3] = 0;
      }
      [src replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
             mipmapLevel:0
               withBytes:pixels
             bytesPerRow:8];
      Region r = {{0, 0},
                  {2, 2},
                  0,
                  eye,
                  eye ? 0.75f : 0.25f,
                  0,
                  matrix_identity_float4x4};
      [enc setVertexBytes:&r length:sizeof(r) atIndex:0];
      [enc setFragmentBytes:&r length:sizeof(r) atIndex:0];
      [enc setFragmentTexture:src atIndex:0];
      [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [enc endEncoding];
    NSUInteger row = ((physical.width * 4 + 255) / 256) * 256,
               bytes = row * physical.height;
    auto colors = [d newBufferWithLength:bytes * 2
                                 options:MTLResourceStorageModeShared];
    auto depths = [d newBufferWithLength:bytes * 2
                                 options:MTLResourceStorageModeShared];
    auto blit = [cb blitCommandEncoder];
    for (unsigned eye = 0; eye < 2; ++eye) {
      [blit copyFromTexture:color
                       sourceSlice:eye
                       sourceLevel:0
                      sourceOrigin:MTLOriginMake(0, 0, 0)
                        sourceSize:MTLSizeMake(physical.width, physical.height,
                                               1)
                          toBuffer:colors
                 destinationOffset:eye * bytes
            destinationBytesPerRow:row
          destinationBytesPerImage:bytes];
      [blit copyFromTexture:depth
                       sourceSlice:eye
                       sourceLevel:0
                      sourceOrigin:MTLOriginMake(0, 0, 0)
                        sourceSize:MTLSizeMake(physical.width, physical.height,
                                               1)
                          toBuffer:depths
                 destinationOffset:eye * bytes
            destinationBytesPerRow:row
          destinationBytesPerImage:bytes];
    }
    [blit endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    check(cb.status == MTLCommandBufferStatusCompleted,
          [[cb.error description] UTF8String]);
    for (unsigned eye = 0; eye < 2; ++eye) {
      auto p = (uint8_t *)colors.contents + eye * bytes +
               (physical.height / 2) * row + (physical.width / 2) * 4;
      check(p[eye ? 1 : 0] == 255 && p[eye ? 0 : 1] == 0 && p[3] == 255,
            "both eyes retained in one layered pass");
      auto z =
          *(float *)((uint8_t *)depths.contents + eye * bytes +
                     (physical.height / 2) * row + (physical.width / 2) * 4);
      check(std::abs(z - (eye ? 0.75f : 0.25f)) < 1e-6,
            "each eye has correct nonzero depth");
    }
    puts("PASS: production presentation shaders preserve both eyes and depth "
         "with a real two-layer rasterization rate map");
  }
}
