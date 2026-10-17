#pragma once
#import <Metal/Metal.h>
#include <array>
#include <cstdint>

// Per-encode-thread, bounded and non-owning. A cached view can be reused while
// the render descriptor/command buffer owns it, but cannot pin a game resource
// after its last real owner releases it. Exact source identity prevents mixing
// relative slices of different parent views.
class WVRTextureSliceCache {
  struct Entry {
    __weak id<MTLTexture> source = nil;
    __weak id<MTLTexture> view = nil;
    uint32_t slice = 0;
    uintptr_t identity = 0; // comparison only; never dereferenced
  };
  std::array<Entry, 8> entries{};
  size_t next = 0, last = 0;
public:
  id<MTLTexture> get(id<MTLTexture> source, uint32_t slice, bool *hit = nullptr) {
    if (hit) *hit = false;
    if (!source || source.textureType != MTLTextureType2DArray || slice >= source.arrayLength) return nil;
    const auto identity = reinterpret_cast<uintptr_t>((__bridge void *)source);
    auto find = [&](size_t index) -> id<MTLTexture> {
      auto &entry = entries[index];
      // Reject unrelated slots before loading a weak Objective-C reference.
      // The weak source check is still mandatory if an address was reused.
      if (entry.slice != slice || entry.identity != identity || entry.source != source) return nil;
      return entry.view;
    };
    id<MTLTexture> view = find(last);
    if (!view) {
      for (size_t index = 0; index < entries.size(); ++index) {
        if (index == last) continue;
        view = find(index);
        if (view) { last = index; break; }
      }
    }
    if (view) { if (hit) *hit = true; return view; }
    view = [source newTextureViewWithPixelFormat:source.pixelFormat
                                   textureType:MTLTextureType2D
                                        levels:NSMakeRange(0, 1)
                                        slices:NSMakeRange(slice, 1)];
    if (view) {
      auto &entry = entries[next];
      entry.source = source; entry.view = view; entry.slice = slice; entry.identity = identity;
      last = next; next = (next + 1) % entries.size();
    }
    return view;
  }
};
