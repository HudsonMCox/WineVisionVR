#import "WindowsVRTextureSliceCache.h"
#import <Foundation/Foundation.h>
#include <cassert>
#include <chrono>
#include <cstdio>

static id<MTLTexture> arrayTexture(id<MTLDevice> device) {
  auto d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
  d.textureType = MTLTextureType2DArray; d.arrayLength = 2;
  d.storageMode = MTLStorageModeShared;
  d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget | MTLTextureUsagePixelFormatView;
  return [device newTextureWithDescriptor:d];
}
int main() {
  @autoreleasepool {
    auto device = MTLCreateSystemDefaultDevice(); assert(device);
    WVRTextureSliceCache cache;
    auto source = arrayTexture(device); assert(source);
    bool hit = true;
    auto left = cache.get(source,0,&hit); assert(left && !hit);
    auto right = cache.get(source,1,&hit); assert(right && !hit && right != left);
    assert(cache.get(source,0,&hit) == left && hit);
    assert(cache.get(source,1,&hit) == right && hit);
    assert(!cache.get(source,2,&hit) && !hit);
    assert(!cache.get(nil,0)); assert(!cache.get(left,0));
    for (unsigned slice=0;slice<2;++slice) {
      uint8_t pixels[256]; for(unsigned i=0;i<sizeof(pixels);++i)pixels[i]=uint8_t(i+slice*17);
      [source replaceRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0 slice:slice withBytes:pixels bytesPerRow:32 bytesPerImage:256];
      uint8_t actual[256]{}; auto view = slice ? right : left;
      [view getBytes:actual bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];
      assert(!memcmp(actual,pixels,sizeof(pixels)));
    }
    // A distinct parent view must not alias an existing cache key.
    auto parent = [source newTextureViewWithPixelFormat:source.pixelFormat textureType:MTLTextureType2DArray levels:NSMakeRange(0,1) slices:NSMakeRange(1,1)];
    auto nested = cache.get(parent,0,&hit); assert(nested && !hit && nested != left);
    uint8_t nestedPixels[256]{},rightPixels[256]{};
    [nested getBytes:nestedPixels bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];
    [right getBytes:rightPixels bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];
    assert(!memcmp(nestedPixels,rightPixels,sizeof(rightPixels)));
    // Neither source nor view can be kept alive by the cache itself.
    __weak id<MTLTexture> weakSource, weakView;
    @autoreleasepool {
      auto temporary = arrayTexture(device);
      auto view = cache.get(temporary,0);
      weakSource = temporary; weakView = view;
    }
    assert(!weakView && !weakSource);
    // Exercise eviction with externally owned views and ensure no wrong-parent hits.
    NSMutableArray<id<MTLTexture>> *owners = [NSMutableArray new];
    for(unsigned i=0;i<12;++i) {
      auto texture=arrayTexture(device); auto view=cache.get(texture,i%2,&hit);
      assert(view && !hit); [owners addObject:texture]; [owners addObject:view];
    }
    for(unsigned i=0;i<12;++i) {
      auto texture=owners[2*i]; auto view=cache.get(texture,i%2);
      assert(view.parentTexture == texture && view.parentRelativeSlice == i%2);
    }
    // Keep the view alive exactly as an in-flight render descriptor does.
    left = cache.get(source,0); const unsigned iterations=10000;
    auto begin=std::chrono::steady_clock::now();
    for(unsigned i=0;i<iterations;++i) { @autoreleasepool {
      auto view=[source newTextureViewWithPixelFormat:source.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(0,1) slices:NSMakeRange(0,1)];
      assert(view.width==8);
    }}
    auto baseline=std::chrono::duration<double,std::nano>(std::chrono::steady_clock::now()-begin).count()/iterations;
    begin=std::chrono::steady_clock::now();
    for(unsigned i=0;i<iterations;++i) { auto view=cache.get(source,0,&hit);assert(hit && view==left); }
    auto cached=std::chrono::duration<double,std::nano>(std::chrono::steady_clock::now()-begin).count()/iterations;
    printf("Metal slice views: new %.2f cached %.2f ns/call (%.2fx isolated)\n",baseline,cached,baseline/cached);
    puts("PASS: live-view reuse, exact slices/pixels, distinct parents, invalid inputs, eviction and non-owning lifetime");
  }
}
