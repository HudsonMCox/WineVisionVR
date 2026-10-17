#pragma once

#include <cstdint>
#include <limits>
#include <openxr/openxr.h>

// OpenXR handles are pointers on 64-bit and uint64_t on 32-bit. Never truncate
// an invalid 64-bit handle into a live 32-bit resource address.
template <typename Handle, typename Resource>
Handle WVRHandleFromPointer(Resource *resource) {
#if XR_PTR_SIZE == 8
  return reinterpret_cast<Handle>(resource);
#else
  return static_cast<Handle>(reinterpret_cast<uintptr_t>(resource));
#endif
}

template <typename Resource, typename Handle>
Resource *WVRPointerFromHandle(Handle handle) {
#if XR_PTR_SIZE == 8
  return reinterpret_cast<Resource *>(handle);
#else
  if (handle > std::numeric_limits<uintptr_t>::max()) return nullptr;
  return reinterpret_cast<Resource *>(static_cast<uintptr_t>(handle));
#endif
}
