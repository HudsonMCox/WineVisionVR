// Verify early guest reuse while an owned stereo image waits for presentation.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "WindowsVRCompositorBridge.h"
#include <cstdio>
#include <cstdlib>
#include <thread>
#include <chrono>
static id<MTLSharedEvent> displayGate;
static void require(bool value, const char *message) {
    if (!value) {
        displayGate.signaledValue = 1; // Never leave the GPU waiting after failure.
        std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1);
    }
    std::printf("PASS: %s\n", message);
}
static bool waitFor(id<MTLCommandBuffer> commands) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (commands.status != MTLCommandBufferStatusCompleted && commands.status != MTLCommandBufferStatusError) {
        if (std::chrono::steady_clock::now() > deadline) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    return commands.status == MTLCommandBufferStatusCompleted;
}
int main() { @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    require(device != nil, "real simulator Metal device");
    require(wvr_compositor_bind_metal_device_v1((__bridge void *)device) == 0, "bind device");
    require(wvr_compositor_publish_targets_v1(4,4,MTLPixelFormatRGBA8Unorm,4,4,MTLPixelFormatRGBA8Unorm) == 0, "publish targets");
    WVRRenderTargetInfoV1 targets = {}; targets.structSize = sizeof(targets);
    require(wvr_compositor_copy_targets_v1(&targets) == 0, "target generation");
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO];
    desc.textureType = MTLTextureType2DArray; desc.arrayLength = 2;
    desc.storageMode = MTLStorageModeShared; desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> guest = [device newTextureWithDescriptor:desc];
    id<MTLCommandQueue> producer = [device newCommandQueue], host = [device newCommandQueue];
    id<MTLSharedEvent> ready = [device newSharedEvent]; displayGate = [device newSharedEvent];
    require(guest && producer && host && ready && displayGate, "allocate queues and events");
    id<MTLCommandBuffer> initial = [producer commandBuffer];
    for (NSUInteger eye = 0; eye < 2; ++eye) {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
        pass.colorAttachments[0].texture = guest; pass.colorAttachments[0].slice = eye;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear; pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = eye ? MTLClearColorMake(0,1,0,1) : MTLClearColorMake(1,0,0,1);
        [[initial renderCommandEncoderWithDescriptor:pass] endEncoding];
    }
    [initial encodeSignalEvent:ready value:1]; [initial commit]; require(waitFor(initial), "produce stereo pixels");
    WVRSubmitStereoFrameV2 frame = {}; frame.abiVersion = WVR_COMPOSITOR_ABI_VERSION_V2; frame.structSize = sizeof(frame);
    frame.targetGeneration = targets.generation; frame.producerFrameID = 1;
    frame.leftTexture = frame.rightTexture = (__bridge void *)guest;
    frame.producerReadyEvent = (__bridge void *)ready; frame.producerReadyValue = 1;
    frame.leftSlice = 0; frame.rightSlice = 1; frame.leftX = frame.rightX = 2; frame.leftY = frame.rightY = 3;
    frame.leftWidth = frame.leftHeight = frame.rightWidth = frame.rightHeight = 4;
    uint64_t ticket = 0;
    require(wvr_compositor_submit_stereo_frame_v2(&frame,&ticket) == 0, "submit cropped array eyes");
    WVRAcquiredStereoFrameV2 acquired = {}; acquired.structSize = sizeof(acquired);
    require(wvr_compositor_acquire_latest_stereo_frame_v2(&acquired) == 0, "acquire producer lease");
    desc.textureType = MTLTextureType2D; desc.arrayLength = 1; desc.width = desc.height = 4; desc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> snapshots[2] = {[device newTextureWithDescriptor:desc], [device newTextureWithDescriptor:desc]};
    require(snapshots[0] && snapshots[1], "allocate owned stereo images");
    // Match production: allocate display first, commit transfer first.
    id<MTLCommandBuffer> display = [host commandBuffer]; display.label = @"wvr.presentation";
    id<MTLCommandBuffer> copy = [host commandBuffer]; copy.label = @"wvr.snapshot";
    [copy encodeWaitForEvent:ready value:1];
    id<MTLBlitCommandEncoder> blit = [copy blitCommandEncoder];
    for (NSUInteger eye = 0; eye < 2; ++eye)
        [blit copyFromTexture:guest sourceSlice:eye sourceLevel:0 sourceOrigin:MTLOriginMake(2,3,0) sourceSize:MTLSizeMake(4,4,1)
                   toTexture:snapshots[eye] destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding];
    void *lease = acquired.lease;
    [copy addCompletedHandler:^(id<MTLCommandBuffer> completed) { wvr_compositor_release_acquired_frame_v1(lease); }];
    [display encodeWaitForEvent:displayGate value:1];
    id<MTLBuffer> pixels[2] = {[device newBufferWithLength:1024 options:MTLResourceStorageModeShared], [device newBufferWithLength:1024 options:MTLResourceStorageModeShared]};
    blit = [display blitCommandEncoder];
    for (NSUInteger eye = 0; eye < 2; ++eye)
        [blit copyFromTexture:snapshots[eye] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(4,4,1)
                    toBuffer:pixels[eye] destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024];
    [blit endEncoding]; [copy commit]; [display commit];
    require(waitFor(copy), "owned copy finishes before display");
    void *opaqueConsumer = wvr_compositor_copy_consumer_event_v1();
    id<MTLSharedEvent> consumer = (__bridge id<MTLSharedEvent>)opaqueConsumer;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (consumer.signaledValue < ticket && std::chrono::steady_clock::now() < deadline)
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    require(consumer.signaledValue >= ticket && display.status != MTLCommandBufferStatusCompleted, "guest release fence advances while display is pending");
    id<MTLCommandBuffer> reuse = [producer commandBuffer];
    [reuse encodeWaitForEvent:consumer value:ticket];
    for (NSUInteger eye = 0; eye < 2; ++eye) {
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new];
        pass.colorAttachments[0].texture = guest; pass.colorAttachments[0].slice = eye;
        pass.colorAttachments[0].loadAction = MTLLoadActionClear; pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0,0,1,1);
        [[reuse renderCommandEncoderWithDescriptor:pass] endEncoding];
    }
    [reuse commit]; require(waitFor(reuse), "producer overwrites both eyes before presentation finishes");
    uint8_t reusedPixel[4] = {};
    [guest getBytes:reusedPixel bytesPerRow:4 bytesPerImage:4 fromRegion:MTLRegionMake2D(2,3,1,1) mipmapLevel:0 slice:0];
    require(reusedPixel[0] == 0 && reusedPixel[1] == 0 && reusedPixel[2] == 255, "guest image actually changed while display is pending");
    displayGate.signaledValue = 1; require(waitFor(display), "presentation completes from owned pixels");
    const uint8_t *left = (uint8_t *)pixels[0].contents, *right = (uint8_t *)pixels[1].contents;
    require(left[0] == 255 && left[1] == 0 && left[2] == 0 && right[0] == 0 && right[1] == 255 && right[2] == 0, "original eye colors survive producer reuse, array slices and crop");
    CFRelease(opaqueConsumer); wvr_compositor_pause_v1();
    puts("FRAME TRANSFER OWNERSHIP CHECKS PASSED");
} }
