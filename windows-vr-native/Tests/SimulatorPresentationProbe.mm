#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <simd/simd.h>
#include <cmath>
#include <cstdio>

struct SourceRegion {
    simd_float2 origin, extent;
    uint32_t slice, padding;
    float depth, reserved;
    simd_float4x4 reprojection;
};
static_assert(sizeof(SourceRegion) == 96);

static void require(bool condition, const char *message) {
    if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
    printf("PASS: %s\n", message);
}

int main(int argc, char **argv) { @autoreleasepool {
    require(argc == 2 || argc == 3, "production shader source supplied");
    FILE *pixelsFile = argc == 3 ? fopen(argv[2], "wb") : nullptr;
    require(argc != 3 || pixelsFile != nullptr, "optional comparison output opens");
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    require(device != nil, "simulator Metal device available");
    NSError *error = nil;
    NSString *source = [NSString stringWithContentsOfFile:@(argv[1]) encoding:NSUTF8StringEncoding error:&error];
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    if (error) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
    require(library != nil, "production presentation shaders compile");
    id<MTLCommandQueue> queue = [device newCommandQueue];
    MTLSamplerDescriptor *samplerDesc = [MTLSamplerDescriptor new];
    samplerDesc.minFilter = samplerDesc.magFilter = MTLSamplerMinMagFilterLinear;
    samplerDesc.sAddressMode = samplerDesc.tAddressMode = MTLSamplerAddressModeClampToEdge;
    id<MTLSamplerState> sampler = [device newSamplerStateWithDescriptor:samplerDesc];
    MTLDepthStencilDescriptor *depthDesc = [MTLDepthStencilDescriptor new];
    depthDesc.depthCompareFunction = MTLCompareFunctionAlways;
    depthDesc.depthWriteEnabled = YES;
    id<MTLDepthStencilState> depthState = [device newDepthStencilStateWithDescriptor:depthDesc];

    for (bool array : { false, true }) {
        MTLTextureDescriptor *inputDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:8 height:8 mipmapped:NO];
        inputDesc.storageMode = MTLStorageModeShared;
        inputDesc.usage = MTLTextureUsageShaderRead;
        if (array) { inputDesc.textureType = MTLTextureType2DArray; inputDesc.arrayLength = 2; }
        id<MTLTexture> input = [device newTextureWithDescriptor:inputDesc];
        uint8_t pixels[8*8*4];
        for (unsigned i=0; i<64; ++i) { pixels[i*4]=32; pixels[i*4+1]=64; pixels[i*4+2]=128; pixels[i*4+3]=0; }
        [input replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 slice:array ? 1 : 0 withBytes:pixels bytesPerRow:32 bytesPerImage:256];
        MTLTextureDescriptor *outputDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB width:16 height:16 mipmapped:NO];
        outputDesc.storageMode = MTLStorageModePrivate;
        outputDesc.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> output = [device newTextureWithDescriptor:outputDesc];
        outputDesc.pixelFormat = MTLPixelFormatDepth32Float;
        id<MTLTexture> depth = [device newTextureWithDescriptor:outputDesc];
        MTLRenderPipelineDescriptor *pipelineDesc = [MTLRenderPipelineDescriptor new];
        pipelineDesc.vertexFunction = [library newFunctionWithName:@"wvr_spatial_vertex"];
        pipelineDesc.fragmentFunction = [library newFunctionWithName:array ? @"wvr_spatial_array_fragment" : @"wvr_spatial_fragment"];
        pipelineDesc.colorAttachments[0].pixelFormat = output.pixelFormat;
        pipelineDesc.depthAttachmentPixelFormat = depth.pixelFormat;
        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pipelineDesc error:&error];
        if (error) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
        require(pipeline != nil, array ? "array color/depth pipeline builds" : "2D color/depth pipeline builds");
        int unwarpedRed = 0;
        for (unsigned test=0; test<8; ++test) {
            // Reverse-Z depth of a 500m color plane with a 0.1m near plane.
            const float value = test==0 ? 0.0f : 0.0002f;
            const bool gradient = test>=2;
            if (gradient) {
                for (unsigned y=0; y<8; ++y) for (unsigned x=0; x<8; ++x) pixels[(y*8+x)*4+2]=32+x*16;
                [input replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 slice:array ? 1 : 0 withBytes:pixels bytesPerRow:32 bytesPerImage:256];
            }
            id<MTLCommandBuffer> commands = [queue commandBuffer];
            MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
            pass.colorAttachments[0].texture=output;
            pass.colorAttachments[0].loadAction=MTLLoadActionClear;
            pass.colorAttachments[0].storeAction=MTLStoreActionStore;
            pass.depthAttachment.texture=depth;
            pass.depthAttachment.loadAction=MTLLoadActionClear;
            pass.depthAttachment.storeAction=MTLStoreActionStore;
            pass.depthAttachment.clearDepth=0;
            id<MTLRenderCommandEncoder> draw = [commands renderCommandEncoderWithDescriptor:pass];
            [draw setRenderPipelineState:pipeline];
            [draw setDepthStencilState:depthState];
            [draw setViewport:(MTLViewport){4,4,8,8,0,1}];
            [draw setFragmentTexture:input atIndex:0];
            [draw setFragmentSamplerState:sampler atIndex:0];
            SourceRegion region = {{2,2},{4,4},array ? 1u : 0u,0,value,0,matrix_identity_float4x4};
            if (test==3) region.reprojection.columns[3].x=0.5f;
            if (test==4 || test==5) {
                region.reprojection.columns[0].w=0.25f;
                region.reprojection.columns[1].w=-0.15f;
            }
            if (test==5) {
                region.reprojection.columns[0].x=0.98f; region.reprojection.columns[0].y=0.2f;
                region.reprojection.columns[1].x=-0.2f; region.reprojection.columns[1].y=0.98f;
            }
            if (test==6) region.reprojection.columns[3].w=-1;
            if (test==7) region.reprojection.columns[3].x=3;
            [draw setVertexBytes:&region length:sizeof(region) atIndex:0];
            [draw setFragmentBytes:&region length:sizeof(region) atIndex:0];
            [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
            [draw endEncoding];
            id<MTLBuffer> colors=[device newBufferWithLength:16*256 options:MTLResourceStorageModeShared];
            id<MTLBuffer> depths=[device newBufferWithLength:16*256 options:MTLResourceStorageModeShared];
            id<MTLBlitCommandEncoder> blit=[commands blitCommandEncoder];
            [blit copyFromTexture:output sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(16,16,1) toBuffer:colors destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:16*256];
            [blit copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(16,16,1) toBuffer:depths destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:16*256];
            [blit endEncoding]; [commands commit]; [commands waitUntilCompleted];
            if (commands.error) fprintf(stderr, "%s\n", commands.error.localizedDescription.UTF8String);
            require(commands.status == MTLCommandBufferStatusCompleted, "GPU color/depth pass completes");
            uint8_t *color=(uint8_t *)colors.contents + 8*256+8*4;
            float z=*(float *)((uint8_t *)depths.contents+8*256+8*4);
            if (!gradient) require(std::abs(int(color[0])-32)<=1 && std::abs(int(color[1])-64)<=1 && std::abs(int(color[2])-128)<=1, "color survives crop and scaling");
            if (test==2) unwarpedRed=color[2];
            if (test==3) require(color[2]>unwarpedRed+10, "render-to-display transform changes sampled game view");
            if (test>=6) require(color[0]==0 && color[1]==0 && color[2]==0, "out-of-view reprojection is opaque black");
            if (pixelsFile) {
                for (unsigned y=0;y<16;++y) {
                    fwrite((uint8_t*)colors.contents+y*256,1,16*4,pixelsFile);
                    fwrite((uint8_t*)depths.contents+y*256,1,16*4,pixelsFile);
                }
            }
            require(color[3]==255, "zero-alpha guest becomes opaque output");
            require(std::abs(z-value)<1e-6, value == 0 ? "negative control: visible RGB can still have zero depth" : "game pixels have nonzero perspective depth");
            require(*(float *)depths.contents==0, "outside the viewport remains clear depth");
        }
    }
    if (pixelsFile) fclose(pixelsFile);
    puts("PRESENTATION PROBE PASSED");
} }
