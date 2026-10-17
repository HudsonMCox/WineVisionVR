#pragma once
#include "d3d12.h"
#include "WindowsVRD3D11ContextExt.h"

inline constexpr GUID kWVRD3D12CommandQueueExtIID = {0x08e6b53f, 0xede5, 0x4524, {0x90, 0xb8, 0x34, 0x45, 0xef, 0x05, 0x9b, 0x1e}};

// Optional project-owned DXMT queue interface. Never reinterpret guest COM
// pointers as Metal objects. The implementation resolves resources inside DXMT
// and uses the fixed-width WMT V2 submission and native consumer event.
struct WVRDXMTD3D12SubmitFrameV1 {
  ID3D12Resource *left;
  ID3D12Resource *right;
  uint64_t targetGeneration;
  uint64_t frameID;
  uint64_t timestampNanoseconds;
  uint32_t leftArraySlice, leftX, leftY, leftWidth, leftHeight;
  uint32_t rightArraySlice, rightX, rightY, rightWidth, rightHeight;
};

struct __declspec(uuid("08e6b53f-ede5-4524-90b8-3445ef059b1e")) IMTLD3D12CommandQueueExt : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE GetWindowsVRTargets(WVRDXMTTargetInfoV1 *targets) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetWindowsVRTracking(WVRDXMTTrackingV1 *tracking) = 0;
  virtual HRESULT STDMETHODCALLTYPE GetWindowsVRController(uint32_t role, WVRDXMTControllerV1 *controller) = 0;
  virtual HRESULT STDMETHODCALLTYPE SubmitWindowsVRHaptic(const WVRDXMTHapticV1 *haptic) = 0;
  // Images are released in D3D12_RESOURCE_STATE_COMMON on this DIRECT queue.
  // Accepted submissions are ordered after prior queue work. Reacquisition
  // enqueues a consumer-event wait before any subsequent writes on this queue.
  virtual HRESULT STDMETHODCALLTYPE SubmitWindowsVRFrame(const WVRDXMTD3D12SubmitFrameV1 *frame) = 0;
  virtual HRESULT STDMETHODCALLTYPE WaitWindowsVRImage(ID3D12Resource *resource) = 0;
};

// Optional, separately queried interface; IMTLD3D12CommandQueueExt's published vtable stays frozen.
inline constexpr GUID kWVRD3D12CommandQueueExt2IID = {0x463fa7ec, 0x5766, 0x4df6, {0xb3, 0x7e, 0xe9, 0x56, 0xd5, 0xe2, 0x05, 0x84}};

// V2 = V1 followed by the projection-jitter fields, with the same names and types as WVRDXMTSubmitFrameV2.
struct WVRDXMTD3D12SubmitFrameV2 {
  ID3D12Resource *left;
  ID3D12Resource *right;
  uint64_t targetGeneration;
  uint64_t frameID;
  uint64_t timestampNanoseconds;
  uint32_t leftArraySlice, leftX, leftY, leftWidth, leftHeight;
  uint32_t rightArraySlice, rightX, rightY, rightWidth, rightHeight;
  // Appended trailing fields (projection jitter), same meaning as WVRDXMTSubmitFrameV2.
  uint32_t jitterFlags;  // WVRDXMTJitterValid when the jitter fields are meaningful.
  float jitterPixelX;
  float jitterPixelY;
  float jitterNdcX;
  float jitterNdcY;
};

struct __declspec(uuid("463fa7ec-5766-4df6-b37e-e956d5e20584")) IMTLD3D12CommandQueueExt2 : public IUnknown {
  virtual HRESULT STDMETHODCALLTYPE SubmitWindowsVRFrameV2(const WVRDXMTD3D12SubmitFrameV2 *frame) = 0;
};

// MinGW's i386 ABI implements __uuidof through template specializations.
// Clang's uuid attribute alone is ignored on that target.
#ifdef __CRT_UUID_DECL
__CRT_UUID_DECL(IMTLD3D12CommandQueueExt2, 0x463fa7ec, 0x5766, 0x4df6, 0xb3, 0x7e, 0xe9, 0x56, 0xd5, 0xe2, 0x05, 0x84)
#endif
