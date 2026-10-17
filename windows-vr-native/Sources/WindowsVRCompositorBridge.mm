#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreFoundation/CoreFoundation.h>
#import <os/lock.h>

#include "WindowsVRCompositorBridge.h"
#include "WindowsVRFrameState.h"
#include "WindowsVRReconstruction.h"
#import <simd/simd.h>
#include <mutex>
#include <condition_variable>
#include <chrono>

#include <algorithm>
#include <array>
#include <cmath>
#include "WindowsVRCompletionWindow.h"
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <unistd.h>

@interface WVRReconstructionResources : NSObject
@property(nonatomic,strong) id<MTLTexture> leftDepth;
@property(nonatomic,strong) id<MTLTexture> rightDepth;
@property(nonatomic,assign) WVRReconstructionSubmitV1 metadata;
@end
@implementation WVRReconstructionResources
@end

// Projection-jitter metadata carried with a queued frame. ndc is per eye and is
// derived from the published producer targets when the frame is submitted.
struct WVRBridgeJitter {
    uint32_t flags;
    uint32_t renderFlags;
    float pixelX;
    float pixelY;
    float ndc[2][2];
};

namespace {

// Publishers never acquire this mutex while holding BridgeState::lock.
// The wait side holds it across snapshot+sleep, closing the lost-wakeup race.
std::mutex frameSignalMutex;
std::condition_variable frameSignal;
std::atomic<uint32_t> frameWaiters{0};
struct FrameStateChanged {
    ~FrameStateChanged() {
        if (!frameWaiters.load(std::memory_order_acquire)) return;
        { std::lock_guard<std::mutex> guard(frameSignalMutex); }
        frameSignal.notify_all();
    }
};

/// Which bridge calls the guest runtime actually makes, bounded so a render loop cannot flood the file:
/// the first few calls of each kind and then every power of two. Lines go to Documents/launcher-log.txt
/// beside the launcher's own milestones.
enum BridgeCall : int {
    CallBind, CallPublishTargets, CallCopyTargets, CallCopyReadiness, CallSubmitV1, CallSubmitV2,
    CallCopyTracking, CallCopyController, CallPublishTracking, CallSubmitV2Reject, CallCount
};
std::atomic<uint32_t> g_callCounts[CallCount];
const char *const kCallNames[CallCount] = {
    "bind-metal-device", "publish-targets", "copy-targets", "copy-readiness", "submit-stereo-v1",
    "submit-stereo-v2", "copy-frame-tracking", "copy-controller-state", "publish-frame-tracking", "submit-v2-reject"};

uint32_t shouldTraceBridgeCall(BridgeCall call) {
    static const bool enabled = getenv("WVR_TRACE_BRIDGE") != nullptr;
    if (!enabled) return false;
    const uint32_t count = g_callCounts[call].fetch_add(1, std::memory_order_relaxed) + 1;
    return (count <= 4 || (count & (count - 1)) == 0) ? count : 0;
}

void writeBridgeTrace(BridgeCall call, uint32_t count, const char *detail) {
    static NSString *path = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)
        firstObject] stringByAppendingPathComponent:@"launcher-log.txt"];
    if (!path) return;
    char line[640];
    struct timespec now{}; clock_gettime(CLOCK_REALTIME, &now);
    struct tm local{}; time_t seconds = now.tv_sec; localtime_r(&seconds, &local);
    const int length = std::snprintf(line, sizeof(line), "%02d:%02d:%02d.%03d [bridge] %s #%u %s\n",
        local.tm_hour, local.tm_min, local.tm_sec, static_cast<int>(now.tv_nsec / 1000000),
        kCallNames[call], count, detail ? detail : "");
    const int fd = open(path.fileSystemRepresentation, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd < 0) return;
    if (length > 0) (void)write(fd, line, static_cast<size_t>(length));
    close(fd);
}

void traceBridgeCall(BridgeCall call, const char *detail) {
    if (const auto count = shouldTraceBridgeCall(call)) writeBridgeTrace(call, count, detail);
}
template<typename... Args>
void traceBridgeCallf(BridgeCall call, const char *format, Args... args) {
    const auto count = shouldTraceBridgeCall(call);
    if (!count) return;
    char detail[480];
    std::snprintf(detail, sizeof(detail), format, args...);
    writeBridgeTrace(call, count, detail);
}

/// A producer event is usable when Metal reports it as belonging to the compositor's device, or does not report a
/// device at all. Shared events created by another component in this process (the guest graphics layer's queue
/// event) can answer nil; the frame's textures are already required to belong to this device, so a nil answer
/// carries no evidence of a foreign GPU.
bool eventUsable(id<MTLSharedEvent> event, id<MTLDevice> device) {
    if (!event) return false;
    id<MTLDevice> owner = event.device;
    return owner == nil || owner == device;
}

constexpr size_t kQueueCapacity = 3;
constexpr uint64_t kMaxOutstandingTickets = kQueueCapacity * 2;
static_assert(kMaxOutstandingTickets == kWVRCompletionWindowCapacity);

struct QueuedFrame {
    uint64_t ticket = 0;
    uint64_t producerFrameID = 0;
    uint64_t producerTimestampNanoseconds = 0;
    __strong id<MTLTexture> left = nil;
    __strong id<MTLTexture> right = nil;
    __strong id<MTLSharedEvent> readyEvent = nil;
    uint64_t readyValue = 0;
    WVRFrameTrackingV1 renderTracking{};
    __strong WVRReconstructionResources *reconstruction = nil;
    WVRBridgeJitter jitter{};
    uint32_t leftSlice = 0, leftX = 0, leftY = 0, leftWidth = 0, leftHeight = 0;
    uint32_t rightSlice = 0, rightX = 0, rightY = 0, rightWidth = 0, rightHeight = 0;
};

class BridgeState {
public:
    os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    __strong id<MTLDevice> device = nil;
    __strong id<MTLSharedEvent> consumerEvent = nil;
    std::array<QueuedFrame, kQueueCapacity> queue;
    size_t head = 0;
    size_t count = 0;
    uint64_t nextTicket = 1;
    uint64_t lastSignaledTicket = 0;
    uint64_t outstandingLeases = 0;
    uint64_t completedTicketMask = 0;
    WVRRenderTargetInfoV1 targets = {
        WVR_COMPOSITOR_ABI_VERSION,
        sizeof(WVRRenderTargetInfoV1),
        0,
        {0, 0}, {0, 0}, {0, 0}, {0, 0}
    };
    std::array<uint32_t, WVR_COMPOSITOR_VIEW_COUNT> drawableWidth{0, 0};
    std::array<uint32_t, WVR_COMPOSITOR_VIEW_COUNT> drawableHeight{0, 0};
    float renderScale = 1.0f;
    bool compositorPaused = true;
    WVRFrameTrackingV1 tracking = {
        WVR_COMPOSITOR_ABI_VERSION,
        sizeof(WVRFrameTrackingV1),
        0,
        0,
        0,
        {0}, {{0}, {0}}, {{0}, {0}}, {{0}, {0}}, {0, 0}
    };
    std::array<WVRFrameTrackingV1, 512> trackingHistory{};
    size_t trackingHistoryNext = 0;
    size_t trackingHistoryCount = 0;
    uint64_t lastDisplayPublishTimestamp = 0;
    uint64_t displayPeriodNanoseconds = 11111111;
    std::array<uint64_t, 8> displayPeriods{};
    size_t displayPeriodCount = 0, displayPeriodNext = 0;
    WVRCompositorStatsV1 stats = {
        WVR_COMPOSITOR_ABI_VERSION,
        sizeof(WVRCompositorStatsV1),
        0, 0, 0, 0, 0, 0
    };
    std::array<WVRControllerStateV1, 2> controllers{};
    std::array<WVRHapticRequestV1, 2> haptics{};
    std::array<bool, 2> hapticPending{false, false};
    uint64_t nextHapticSequence = 1;
    bool sessionExitRequested = false;
};

BridgeState &state() {
    static BridgeState bridge;
    return bridge;
}

// Select only GPU-ready frames. Waiting for an unfinished producer on the
// display queue would also stall all following cached-frame reprojections.
int newestReadyOffsetLocked(const BridgeState &bridge) {
    for (size_t offset = bridge.count; offset > 0; --offset) {
        const auto &slot = bridge.queue[(bridge.head + offset - 1) % kQueueCapacity];
        if (slot.readyEvent.signaledValue >= slot.readyValue) return static_cast<int>(offset - 1);
    }
    return -1;
}

WVRFrameTrackingV1 trackingForTimestampLocked(const BridgeState &bridge, uint64_t timestamp) {
    WVRFrameTrackingV1 result{};
    uint64_t closest = 2'000'001; // Allow timestamp rounding, never substitute the current pose.
    // Frames normally reference one of the most recent display predictions.
    // Traverse the ring in publication order instead of scanning its oldest
    // physical slot first; still examine all entries when no exact match exists.
    for (size_t offset = 1; offset <= bridge.trackingHistoryCount; ++offset) {
        const size_t index = (bridge.trackingHistoryNext + bridge.trackingHistory.size() - offset) % bridge.trackingHistory.size();
        const auto &sample = bridge.trackingHistory[index];
        if (!(sample.flags & WVRDevicePoseTracked) || !sample.timestampNanoseconds) continue;
        const auto delta = timestamp >= sample.timestampNanoseconds ? timestamp - sample.timestampNanoseconds : sample.timestampNanoseconds - timestamp;
        if (delta < closest) {
            closest = delta; result = sample;
            if (delta == 0) return result;
        }
    }
    return result;
}

void clearSlot(QueuedFrame &slot) {
    slot = QueuedFrame{};
}

void markTicketCompleteLocked(BridgeState &bridge, uint64_t ticket) {
    if (ticket <= bridge.lastSignaledTicket) return;
    const bool advanced = wvrCompleteTicket(ticket, bridge.lastSignaledTicket, bridge.completedTicketMask);
    if (advanced && bridge.consumerEvent) {
        bridge.consumerEvent.signaledValue = bridge.lastSignaledTicket;
    }
    ++bridge.stats.completedFrames;
}

void dropHeadLocked(BridgeState &bridge) {
    if (bridge.count == 0) return;
    QueuedFrame &slot = bridge.queue[bridge.head];
    markTicketCompleteLocked(bridge, slot.ticket);
    clearSlot(slot);
    bridge.head = (bridge.head + 1) % kQueueCapacity;
    --bridge.count;
    ++bridge.stats.droppedFrames;
    bridge.stats.queuedFrames = static_cast<uint32_t>(bridge.count);
}

uint32_t producerExtent(uint32_t drawableExtent, float scale) {
    if (drawableExtent == 0) return 0;
    const uint32_t scaled = std::max<uint32_t>(1, static_cast<uint32_t>(
        std::floor(static_cast<double>(drawableExtent) * static_cast<double>(scale))));
    // Unity pads eye buffers to tile boundaries. Advertise that allocation size
    // so its stereo texture fits the contract; presentation scales to the view.
    // Tiny probe/preview textures retain their exact extent.
    if (scaled < 64) return scaled;
    const uint64_t aligned = (static_cast<uint64_t>(scaled) + 63u) & ~uint64_t(63u);
    return static_cast<uint32_t>(std::min<uint64_t>(aligned, UINT32_MAX));
}

void invalidateTargetsLocked(BridgeState &bridge) {
    wvr_guest_foveation_reset_v1();
    const bool changed = bridge.drawableWidth[0] != 0 || bridge.drawableWidth[1] != 0 ||
                         bridge.targets.width[0] != 0 || bridge.targets.width[1] != 0;
    while (bridge.count > 0) dropHeadLocked(bridge);
    bridge.drawableWidth = {0, 0};
    bridge.drawableHeight = {0, 0};
    bridge.compositorPaused = true;
    for (size_t eye = 0; eye < WVR_COMPOSITOR_VIEW_COUNT; ++eye) {
        bridge.targets.width[eye] = 0;
        bridge.targets.height[eye] = 0;
        bridge.targets.pixelFormat[eye] = 0;
    }
    if (changed) ++bridge.targets.generation;
}

void updateTargetsLocked(BridgeState &bridge,
                         uint32_t leftWidth, uint32_t leftHeight, uint32_t leftPixelFormat,
                         uint32_t rightWidth, uint32_t rightHeight, uint32_t rightPixelFormat) {
    const uint32_t drawableWidth[2] = {leftWidth, rightWidth};
    const uint32_t drawableHeight[2] = {leftHeight, rightHeight};
    const uint32_t pixelFormat[2] = {leftPixelFormat, rightPixelFormat};
    uint32_t producerWidth[2]{};
    uint32_t producerHeight[2]{};
    for (size_t eye = 0; eye < WVR_COMPOSITOR_VIEW_COUNT; ++eye) {
        producerWidth[eye] = producerExtent(drawableWidth[eye], bridge.renderScale);
        producerHeight[eye] = producerExtent(drawableHeight[eye], bridge.renderScale);
    }

    bool changed = false;
    for (size_t eye = 0; eye < WVR_COMPOSITOR_VIEW_COUNT; ++eye) {
        changed |= bridge.drawableWidth[eye] != drawableWidth[eye] ||
                   bridge.drawableHeight[eye] != drawableHeight[eye] ||
                   bridge.targets.width[eye] != producerWidth[eye] ||
                   bridge.targets.height[eye] != producerHeight[eye] ||
                   bridge.targets.pixelFormat[eye] != pixelFormat[eye];
    }
    if (!changed) {
        bridge.compositorPaused = false;
        return;
    }

    while (bridge.count > 0) dropHeadLocked(bridge);
    for (size_t eye = 0; eye < WVR_COMPOSITOR_VIEW_COUNT; ++eye) {
        bridge.drawableWidth[eye] = drawableWidth[eye];
        bridge.drawableHeight[eye] = drawableHeight[eye];
        bridge.targets.width[eye] = producerWidth[eye];
        bridge.targets.height[eye] = producerHeight[eye];
        bridge.targets.pixelFormat[eye] = pixelFormat[eye];
    }
    bridge.compositorPaused = false;
    ++bridge.targets.generation;
}

void clearTrackingLocked(BridgeState &bridge) {
    bridge.trackingHistory = {};
    bridge.trackingHistoryNext = 0;
    bridge.trackingHistoryCount = 0;
    bridge.lastDisplayPublishTimestamp = 0;
    bridge.displayPeriodNanoseconds = 11111111;
    bridge.displayPeriods = {};
    bridge.displayPeriodCount = bridge.displayPeriodNext = 0;
    bridge.tracking.flags = 0;
    bridge.tracking.timestampNanoseconds = 0;
    std::fill_n(bridge.tracking.originFromDevice, 16, 0.0f);
    bridge.tracking.originFromDevice[0] = 1.0f;
    bridge.tracking.originFromDevice[5] = 1.0f;
    bridge.tracking.originFromDevice[10] = 1.0f;
    bridge.tracking.originFromDevice[15] = 1.0f;
    for (size_t eye = 0; eye < WVR_COMPOSITOR_VIEW_COUNT; ++eye) {
        std::fill_n(bridge.tracking.deviceFromEye[eye], 16, 0.0f);
        std::fill_n(bridge.tracking.projection[eye], 16, 0.0f);
        std::fill_n(bridge.tracking.frustumTangents[eye], 4, 0.0f);
    }
    std::fill_n(bridge.tracking.depthRange, 2, 0.0f);
    for (size_t role = 0; role < WVR_COMPOSITOR_VIEW_COUNT; ++role) {
        WVRControllerStateV1 &controller = bridge.controllers[role];
        controller = WVRControllerStateV1{};
        controller.abiVersion = WVR_COMPOSITOR_ABI_VERSION;
        controller.structSize = sizeof(WVRControllerStateV1);
        controller.role = static_cast<uint32_t>(role);
        controller.originFromController[0] = 1.0f;
        controller.originFromController[5] = 1.0f;
        controller.originFromController[10] = 1.0f;
        controller.originFromController[15] = 1.0f;
        bridge.haptics[role] = WVRHapticRequestV1{};
        bridge.hapticPending[role] = false;
    }
}

bool validTexture(id<MTLTexture> texture, id<MTLDevice> device,
                  uint32_t width, uint32_t height, uint32_t pixelFormat) {
    return texture != nil && texture.device == device &&
           texture.textureType == MTLTextureType2D && texture.sampleCount == 1 &&
           texture.width == width && texture.height == height &&
           static_cast<uint32_t>(texture.pixelFormat) == pixelFormat;
}

int32_t submitStereoFrame(const WVRSubmitStereoFrameV1 *frame,
                          uint64_t expectedGeneration,
                          bool checkGeneration,
                          uint64_t *outCompositorTicket) {
    if (!frame || !outCompositorTicket || frame->abiVersion != WVR_COMPOSITOR_ABI_VERSION ||
        frame->structSize < sizeof(WVRSubmitStereoFrameV1) || !frame->leftTexture ||
        !frame->rightTexture || !frame->producerReadyEvent) {
        return WVRCompositorStatusInvalidArgument;
    }

    id<MTLTexture> left = (__bridge id<MTLTexture>)frame->leftTexture;
    id<MTLTexture> right = (__bridge id<MTLTexture>)frame->rightTexture;
    id<MTLSharedEvent> readyEvent = (__bridge id<MTLSharedEvent>)frame->producerReadyEvent;

    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (!bridge.device || !bridge.consumerEvent) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusDeviceNotBound;
    }
    if ((checkGeneration && expectedGeneration != bridge.targets.generation) ||
        bridge.targets.width[0] == 0 || bridge.targets.height[0] == 0 ||
        bridge.targets.width[1] == 0 || bridge.targets.height[1] == 0) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusIncompatibleTexture;
    }
    if (!validTexture(left, bridge.device, bridge.targets.width[0], bridge.targets.height[0],
                      bridge.targets.pixelFormat[0]) ||
        !validTexture(right, bridge.device, bridge.targets.width[1], bridge.targets.height[1],
                      bridge.targets.pixelFormat[1]) || !eventUsable(readyEvent, bridge.device)) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusIncompatibleTexture;
    }
    if (bridge.nextTicket == 0) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusUnsupportedABI;
    }
    if (bridge.nextTicket - bridge.lastSignaledTicket - 1 >= kMaxOutstandingTickets) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusNoFrameAvailable;
    }

    if (bridge.count == kQueueCapacity) dropHeadLocked(bridge);
    const size_t tail = (bridge.head + bridge.count) % kQueueCapacity;
    QueuedFrame &slot = bridge.queue[tail];
    slot.ticket = bridge.nextTicket++;
    slot.producerFrameID = frame->producerFrameID;
    slot.producerTimestampNanoseconds = frame->producerTimestampNanoseconds;
    slot.renderTracking = trackingForTimestampLocked(bridge, frame->producerTimestampNanoseconds);
    slot.reconstruction = nil;
    slot.jitter = WVRBridgeJitter{};
    slot.left = left;
    slot.right = right;
    slot.readyEvent = readyEvent;
    slot.readyValue = frame->producerReadyValue;
    slot.leftWidth = static_cast<uint32_t>(left.width);
    slot.leftHeight = static_cast<uint32_t>(left.height);
    slot.rightWidth = static_cast<uint32_t>(right.width);
    slot.rightHeight = static_cast<uint32_t>(right.height);
    *outCompositorTicket = slot.ticket;
    ++bridge.count;
    ++bridge.stats.submittedFrames;
    bridge.stats.queuedFrames = static_cast<uint32_t>(bridge.count);
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

} // namespace

@interface WVRFrameLease : NSObject
@property(nonatomic,strong) WVRReconstructionResources *reconstruction;
@property(nonatomic) WVRBridgeJitter jitter;
@property(nonatomic) uint64_t ticket;
@property(nonatomic) uint64_t producerFrameID;
@property(nonatomic) uint64_t producerTimestampNanoseconds;
@property(nonatomic, strong) id<MTLTexture> left;
@property(nonatomic, strong) id<MTLTexture> right;
@property(nonatomic, strong) id<MTLSharedEvent> readyEvent;
@property(nonatomic) uint64_t readyValue;
@property(nonatomic) WVRFrameTrackingV1 renderTracking;
@property(nonatomic) uint32_t leftSlice, leftX, leftY, leftWidth, leftHeight;
@property(nonatomic) uint32_t rightSlice, rightX, rightY, rightWidth, rightHeight;
@end
@implementation WVRFrameLease
@end

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_bind_metal_device_v1(void *opaqueDevice) {
    FrameStateChanged notifyWaiters;
    traceBridgeCall(CallBind, opaqueDevice ? "device" : "null device");
    if (!opaqueDevice) return WVRCompositorStatusInvalidArgument;
    id<MTLDevice> device = (__bridge id<MTLDevice>)opaqueDevice;
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (bridge.device != device) {
        const bool targetsLive = bridge.drawableWidth[0] != 0 || bridge.drawableWidth[1] != 0;
        if (targetsLive || bridge.count != 0 || bridge.outstandingLeases != 0 ||
            bridge.completedTicketMask != 0) {
            os_unfair_lock_unlock(&bridge.lock);
            return WVRCompositorStatusIncompatibleTexture;
        }
        id<MTLSharedEvent> event = [device newSharedEvent];
        if (!event) {
            os_unfair_lock_unlock(&bridge.lock);
            return WVRCompositorStatusDeviceNotBound;
        }
        event.label = @"Windows VR compositor consumption";
        event.signaledValue = bridge.lastSignaledTicket;
        bridge.device = device;
        bridge.consumerEvent = event;
    }
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT void *wvr_compositor_copy_metal_device_v1(void) {
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    void *result = bridge.device ? (__bridge_retained void *)bridge.device : nullptr;
    os_unfair_lock_unlock(&bridge.lock);
    return result;
}

extern "C" WVR_COMPOSITOR_EXPORT void wvr_compositor_release_object_v1(void *object) {
    if (object) CFRelease((CFTypeRef)object);
}

extern "C" WVR_COMPOSITOR_EXPORT void *wvr_compositor_copy_consumer_event_v1(void) {
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    void *result = bridge.consumerEvent ? (__bridge_retained void *)bridge.consumerEvent : nullptr;
    os_unfair_lock_unlock(&bridge.lock);
    return result;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_set_render_scale_v1(float scale) {
    FrameStateChanged notifyWaiters;
    if (!std::isfinite(scale) || scale <= 0.0f || scale > 1.0f) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    bridge.renderScale = scale;
    if (bridge.drawableWidth[0] != 0 && bridge.drawableHeight[0] != 0 &&
        bridge.drawableWidth[1] != 0 && bridge.drawableHeight[1] != 0) {
        updateTargetsLocked(bridge,
                            bridge.drawableWidth[0], bridge.drawableHeight[0], bridge.targets.pixelFormat[0],
                            bridge.drawableWidth[1], bridge.drawableHeight[1], bridge.targets.pixelFormat[1]);
    }
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT void wvr_compositor_request_session_exit_v1(void) {
    FrameStateChanged notifyWaiters;
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    bridge.sessionExitRequested = true;
    os_unfair_lock_unlock(&bridge.lock);
}

extern "C" WVR_COMPOSITOR_EXPORT void wvr_compositor_reset_session_exit_v1(void) {
    FrameStateChanged notifyWaiters;
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    bridge.sessionExitRequested = false;
    os_unfair_lock_unlock(&bridge.lock);
}

extern "C" WVR_COMPOSITOR_EXPORT void wvr_compositor_pause_v1(void) {
    FrameStateChanged notifyWaiters;
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    invalidateTargetsLocked(bridge);
    clearTrackingLocked(bridge);
    os_unfair_lock_unlock(&bridge.lock);
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_publish_targets_v1(
    uint32_t leftWidth, uint32_t leftHeight, uint32_t leftPixelFormat,
    uint32_t rightWidth, uint32_t rightHeight, uint32_t rightPixelFormat) {
    FrameStateChanged notifyWaiters;
    {
        traceBridgeCallf(CallPublishTargets, "left=%ux%u fmt=%u right=%ux%u fmt=%u",
                      leftWidth, leftHeight, leftPixelFormat, rightWidth, rightHeight, rightPixelFormat);
    }
    const bool allZero = leftWidth == 0 && leftHeight == 0 && leftPixelFormat == 0 &&
                         rightWidth == 0 && rightHeight == 0 && rightPixelFormat == 0;
    if (allZero) {
        BridgeState &bridge = state();
        os_unfair_lock_lock(&bridge.lock);
        invalidateTargetsLocked(bridge);
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusOK;
    }
    if (leftWidth == 0 || leftHeight == 0 || rightWidth == 0 || rightHeight == 0) {
        return WVRCompositorStatusInvalidArgument;
    }

    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    updateTargetsLocked(bridge, leftWidth, leftHeight, leftPixelFormat,
                        rightWidth, rightHeight, rightPixelFormat);
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_copy_targets_v1(
    WVRRenderTargetInfoV1 *outInfo) {
    if (!outInfo || outInfo->structSize < sizeof(WVRRenderTargetInfoV1)) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    *outInfo = bridge.targets;
    os_unfair_lock_unlock(&bridge.lock);
    {
        traceBridgeCallf(CallCopyTargets, "left=%ux%u right=%ux%u", outInfo->width[0], outInfo->height[0],
                      outInfo->width[1], outInfo->height[1]);
    }
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_copy_readiness_v1(
    WVRCompositorReadinessV1 *outReadiness) {
    if (!outReadiness || outReadiness->structSize < sizeof(WVRCompositorReadinessV1)) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    outReadiness->abiVersion = WVR_COMPOSITOR_ABI_VERSION;
    outReadiness->structSize = sizeof(WVRCompositorReadinessV1);
    outReadiness->metalDeviceBound = bridge.device ? 1u : 0u;
    outReadiness->stereoTargetsPublished =
        bridge.targets.width[0] > 0 && bridge.targets.height[0] > 0 &&
        bridge.targets.width[1] > 0 && bridge.targets.height[1] > 0 ? 1u : 0u;
    outReadiness->trackedHeadPoseAvailable =
        (bridge.tracking.flags & WVRDevicePoseTracked) != 0 ? 1u : 0u;
    outReadiness->reserved = 0;
    outReadiness->trackingTimestampNanoseconds = bridge.tracking.timestampNanoseconds;
    os_unfair_lock_unlock(&bridge.lock);
    {
        traceBridgeCallf(CallCopyReadiness, "device=%u targets=%u headPose=%u", outReadiness->metalDeviceBound,
                      outReadiness->stereoTargetsPublished, outReadiness->trackedHeadPoseAvailable);
    }
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_submit_stereo_frame_v1(
    const WVRSubmitStereoFrameV1 *frame, uint64_t *outCompositorTicket) {
    const int32_t status = submitStereoFrame(frame, 0, false, outCompositorTicket);
    traceBridgeCallf(CallSubmitV1, "status=%d", status);
    return status;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_submit_stereo_frame_for_generation_v1(
    const WVRSubmitStereoFrameV1 *frame, uint64_t targetGeneration,
    uint64_t *outCompositorTicket) {
    return submitStereoFrame(frame, targetGeneration, true, outCompositorTicket);
}

static int32_t submitStereoFrameV2Impl(const WVRSubmitStereoFrameV2 *frame, uint64_t *outCompositorTicket, WVRReconstructionResources *reconstruction, const WVRBridgeJitter *jitter);

static int32_t submitStereoFrame(
    const WVRSubmitStereoFrameV2 *frame, uint64_t *outCompositorTicket, WVRReconstructionResources *reconstruction,
    const WVRBridgeJitter *jitter = nullptr) {
    const int32_t status = submitStereoFrameV2Impl(frame, outCompositorTicket,reconstruction,jitter);
    traceBridgeCallf(CallSubmitV2, "status=%d", status);
    return status;
}

static int32_t submitStereoFrameV2Impl(const WVRSubmitStereoFrameV2 *frame, uint64_t *outCompositorTicket, WVRReconstructionResources *reconstruction, const WVRBridgeJitter *jitter) {
    if (!frame || !outCompositorTicket || frame->abiVersion != WVR_COMPOSITOR_ABI_VERSION_V2 ||
        frame->structSize < sizeof(WVRSubmitStereoFrameV2) || !frame->leftTexture ||
        !frame->rightTexture || !frame->producerReadyEvent || frame->targetGeneration == 0) {
        return WVRCompositorStatusInvalidArgument;
    }
    id<MTLTexture> left = (__bridge id<MTLTexture>)frame->leftTexture;
    id<MTLTexture> right = (__bridge id<MTLTexture>)frame->rightTexture;
    id<MTLSharedEvent> readyEvent = (__bridge id<MTLSharedEvent>)frame->producerReadyEvent;
    auto validSource = [](id<MTLTexture> texture, id<MTLDevice> device, uint32_t slice,
                          uint32_t x, uint32_t y, uint32_t width, uint32_t height,
                          uint32_t pixelFormat) {
        const bool supportedType = texture.textureType == MTLTextureType2D ||
                                   texture.textureType == MTLTextureType2DArray;
        const uint32_t sliceCount = texture.textureType == MTLTextureType2D ? 1u :
                                    static_cast<uint32_t>(texture.arrayLength);
        return texture && texture.device == device && supportedType && texture.sampleCount == 1 &&
               slice < sliceCount && width > 0 && height > 0 &&
               x <= texture.width && y <= texture.height &&
               width <= texture.width - x && height <= texture.height - y &&
               static_cast<uint32_t>(texture.pixelFormat) == pixelFormat;
    };
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (!bridge.device || !bridge.consumerEvent) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusDeviceNotBound;
    }
    if (frame->targetGeneration != bridge.targets.generation ||
        bridge.targets.width[0] == 0 || bridge.targets.height[0] == 0 ||
        bridge.targets.width[1] == 0 || bridge.targets.height[1] == 0) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusIncompatibleTexture;
    }
    if (!validSource(left, bridge.device, frame->leftSlice, frame->leftX, frame->leftY,
                     frame->leftWidth, frame->leftHeight, bridge.targets.pixelFormat[0]) ||
        !validSource(right, bridge.device, frame->rightSlice, frame->rightX, frame->rightY,
                     frame->rightWidth, frame->rightHeight, bridge.targets.pixelFormat[1]) ||
        frame->leftWidth > bridge.targets.width[0] || frame->leftHeight > bridge.targets.height[0] ||
        frame->rightWidth > bridge.targets.width[1] || frame->rightHeight > bridge.targets.height[1] ||
        !eventUsable(readyEvent, bridge.device)) {
        {
            char d[480];
            std::snprintf(d, sizeof(d),
                "v2 rejected: eventDev=%p busDev=%p L type=%d fmt=%d %lux%lu arr=%lu smp=%lu rect=%u,%u %ux%u slice=%u dev=%d | R type=%d fmt=%d %lux%lu arr=%lu rect=%u,%u %ux%u slice=%u | target fmt=%u/%u %ux%u event=%d",
                (__bridge void *)readyEvent.device, (__bridge void *)bridge.device, (int)left.textureType, (int)left.pixelFormat, (unsigned long)left.width, (unsigned long)left.height,
                (unsigned long)left.arrayLength, (unsigned long)left.sampleCount, frame->leftX, frame->leftY,
                frame->leftWidth, frame->leftHeight, frame->leftSlice, left.device == bridge.device,
                (int)right.textureType, (int)right.pixelFormat, (unsigned long)right.width, (unsigned long)right.height,
                (unsigned long)right.arrayLength, frame->rightX, frame->rightY, frame->rightWidth, frame->rightHeight,
                frame->rightSlice, bridge.targets.pixelFormat[0], bridge.targets.pixelFormat[1],
                bridge.targets.width[0], bridge.targets.height[0], eventUsable(readyEvent, bridge.device));
            traceBridgeCall(CallSubmitV2Reject, d);
        }
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusIncompatibleTexture;
    }
    if (bridge.nextTicket == 0 ||
        bridge.nextTicket - bridge.lastSignaledTicket - 1 >= kMaxOutstandingTickets) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusNoFrameAvailable;
    }
    if (bridge.sessionExitRequested) { os_unfair_lock_unlock(&bridge.lock); return WVRCompositorStatusNoFrameAvailable; }
    wvr_guest_foveation_register_eye_v1(0, frame->leftTexture, frame->leftSlice, frame->leftX, frame->leftY, frame->leftWidth, frame->leftHeight);
    wvr_guest_foveation_register_eye_v1(1, frame->rightTexture, frame->rightSlice, frame->rightX, frame->rightY, frame->rightWidth, frame->rightHeight);
    if (bridge.count == kQueueCapacity) dropHeadLocked(bridge);
    const size_t tail = (bridge.head + bridge.count) % kQueueCapacity;
    QueuedFrame &slot = bridge.queue[tail];
    slot.ticket = bridge.nextTicket++;
    slot.producerFrameID = frame->producerFrameID;
    slot.producerTimestampNanoseconds = frame->producerTimestampNanoseconds;
    slot.renderTracking = trackingForTimestampLocked(bridge, frame->producerTimestampNanoseconds);
    slot.reconstruction = reconstruction;
    slot.jitter = jitter ? *jitter : WVRBridgeJitter{};
    if (slot.jitter.flags & WVR_SUBMIT_JITTER_VALID) {
        for (unsigned eye = 0; eye < 2; ++eye) {
            slot.jitter.ndc[eye][0] = 2.0f * slot.jitter.pixelX / static_cast<float>(bridge.targets.width[eye]);
            slot.jitter.ndc[eye][1] = 2.0f * slot.jitter.pixelY / static_cast<float>(bridge.targets.height[eye]);
        }
    } else {
        slot.jitter = WVRBridgeJitter{};
    }
    slot.left = left; slot.right = right; slot.readyEvent = readyEvent;
    slot.readyValue = frame->producerReadyValue;
    slot.leftSlice = frame->leftSlice; slot.leftX = frame->leftX; slot.leftY = frame->leftY;
    slot.leftWidth = frame->leftWidth; slot.leftHeight = frame->leftHeight;
    slot.rightSlice = frame->rightSlice; slot.rightX = frame->rightX; slot.rightY = frame->rightY;
    slot.rightWidth = frame->rightWidth; slot.rightHeight = frame->rightHeight;
    *outCompositorTicket = slot.ticket;
    ++bridge.count; ++bridge.stats.submittedFrames;
    bridge.stats.queuedFrames = static_cast<uint32_t>(bridge.count);
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_submit_stereo_frame_v2(
    const WVRSubmitStereoFrameV2 *frame, uint64_t *ticket) {
    return submitStereoFrame(frame,ticket,nil,nullptr);
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_submit_stereo_frame_v3(
    const WVRSubmitStereoFrameV3 *frame, uint64_t *ticket) {
    if (!frame || !ticket || frame->abiVersion != WVR_COMPOSITOR_ABI_VERSION_V3 ||
        frame->structSize < sizeof(WVRSubmitStereoFrameV3))
        return WVRCompositorStatusInvalidArgument;
    WVRSubmitStereoFrameV2 v2{};
    v2.abiVersion = WVR_COMPOSITOR_ABI_VERSION_V2;
    v2.structSize = sizeof(v2);
    v2.producerFrameID = frame->producerFrameID;
    v2.producerTimestampNanoseconds = frame->producerTimestampNanoseconds;
    v2.leftTexture = frame->leftTexture;
    v2.rightTexture = frame->rightTexture;
    v2.producerReadyEvent = frame->producerReadyEvent;
    v2.producerReadyValue = frame->producerReadyValue;
    v2.targetGeneration = frame->targetGeneration;
    v2.leftSlice = frame->leftSlice; v2.leftX = frame->leftX; v2.leftY = frame->leftY;
    v2.leftWidth = frame->leftWidth; v2.leftHeight = frame->leftHeight;
    v2.rightSlice = frame->rightSlice; v2.rightX = frame->rightX; v2.rightY = frame->rightY;
    v2.rightWidth = frame->rightWidth; v2.rightHeight = frame->rightHeight;
    WVRBridgeJitter jitter{};
    jitter.flags = frame->jitterFlags & WVR_SUBMIT_JITTER_VALID;
    jitter.renderFlags = frame->renderFlags;
    jitter.pixelX = frame->jitterPixelX;
    jitter.pixelY = frame->jitterPixelY;
    const int32_t status = submitStereoFrame(&v2, ticket, nil, &jitter);
    traceBridgeCallf(CallSubmitV2, "v3 status=%d jitter=%u", status, jitter.flags);
    return status;
}

static std::atomic<uint64_t> reconstructionRejections{0};
static int32_t submitReconstructionImpl(WVRReconstructionSubmitV1 *r) {
    if (!r || r->abiVersion!=WVR_RECONSTRUCTION_ABI || r->structSize!=sizeof(*r)) return WVRCompositorStatusUnsupportedABI;
    r->status=WVRCompositorStatusInvalidArgument; r->compositorTicket=0; r->consumerEvent=0;
    if (r->reserved || !r->frameID || !r->timestampNanoseconds) return r->status;
    auto resources=[WVRReconstructionResources new];
    for(unsigned eye=0;eye<2;++eye) {
        const auto &e=r->eyes[eye];
        auto color=(__bridge id<MTLTexture>)(void*)e.colorTexture;
        auto depth=(__bridge id<MTLTexture>)(void*)e.depthTexture;
        if (!color || !depth || color.device!=depth.device || depth.pixelFormat!=MTLPixelFormatDepth32Float ||
            (depth.textureType!=MTLTextureType2D && depth.textureType!=MTLTextureType2DArray) || depth.sampleCount!=1 ||
            e.depthSlice>=depth.arrayLength || !e.width || !e.height || !e.depthWidth || !e.depthHeight || e.depthX>depth.width || e.depthY>depth.height ||
            e.depthWidth>depth.width-e.depthX || e.depthHeight>depth.height-e.depthY ||
            !std::isfinite(e.minDepth) || !std::isfinite(e.maxDepth) || e.minDepth<0 || e.maxDepth>1 || e.minDepth>=e.maxDepth) return r->status;
        for(unsigned i=0;i<16;++i) if(!std::isfinite(e.originFromEye[i]) || !std::isfinite(e.projection[i]))return r->status;
        simd_float4x4 origin,projection;std::memcpy(&origin,e.originFromEye,sizeof(origin));std::memcpy(&projection,e.projection,sizeof(projection));
        if(!std::isfinite(simd_determinant(origin)) || !std::isfinite(simd_determinant(projection)) || simd_determinant(origin)==0 || simd_determinant(projection)==0)return r->status;
        if(eye==0)resources.leftDepth=depth;else resources.rightDepth=depth;
    }
    resources.metadata=*r;
    WVRSubmitStereoFrameV2 frame{};frame.abiVersion=WVR_COMPOSITOR_ABI_VERSION_V2;frame.structSize=sizeof(frame);
    frame.producerFrameID=r->frameID;frame.producerTimestampNanoseconds=r->timestampNanoseconds;frame.targetGeneration=r->targetGeneration;
    frame.leftTexture=(void*)r->eyes[0].colorTexture;frame.rightTexture=(void*)r->eyes[1].colorTexture;
    frame.producerReadyEvent=(void*)r->producerEvent;frame.producerReadyValue=r->producerValue;
    frame.leftSlice=r->eyes[0].colorSlice;frame.leftX=r->eyes[0].colorX;frame.leftY=r->eyes[0].colorY;frame.leftWidth=r->eyes[0].width;frame.leftHeight=r->eyes[0].height;
    frame.rightSlice=r->eyes[1].colorSlice;frame.rightX=r->eyes[1].colorX;frame.rightY=r->eyes[1].colorY;frame.rightWidth=r->eyes[1].width;frame.rightHeight=r->eyes[1].height;
    r->status=submitStereoFrame(&frame,&r->compositorTicket,resources,nullptr);
    if(r->status==0)r->consumerEvent=(uint64_t)wvr_compositor_copy_consumer_event_v1();
    return r->status;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_submit_reconstruction_v1(WVRReconstructionSubmitV1 *r) {
    const int32_t status=submitReconstructionImpl(r);
    if(status!=0)reconstructionRejections.fetch_add(1,std::memory_order_relaxed);
    return status;
}
extern "C" WVR_COMPOSITOR_EXPORT uint64_t wvr_reconstruction_transport_rejections_v1(void) {
    return reconstructionRejections.load(std::memory_order_relaxed);
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_acquire_latest_stereo_frame_v1(
    WVRAcquiredStereoFrameV1 *outFrame) {
    if (!outFrame || outFrame->structSize < sizeof(WVRAcquiredStereoFrameV1)) {
        return WVRCompositorStatusInvalidArgument;
    }

    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (bridge.count == 0) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusNoFrameAvailable;
    }

    const int readyOffset = newestReadyOffsetLocked(bridge);
    if (readyOffset < 0) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusNoFrameAvailable;
    }
    for (int skipped = 0; skipped < readyOffset; ++skipped) dropHeadLocked(bridge);
    QueuedFrame &slot = bridge.queue[bridge.head];
    if (slot.leftSlice != 0 || slot.rightSlice != 0 || slot.leftX != 0 || slot.leftY != 0 ||
        slot.rightX != 0 || slot.rightY != 0 || slot.left.textureType != MTLTextureType2D ||
        slot.right.textureType != MTLTextureType2D || slot.leftWidth != slot.left.width ||
        slot.leftHeight != slot.left.height || slot.rightWidth != slot.right.width || slot.rightHeight != slot.right.height) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusUnsupportedABI;
    }
    WVRFrameLease *lease = [WVRFrameLease new];
    lease.ticket = slot.ticket;
    lease.producerFrameID = slot.producerFrameID;
    lease.producerTimestampNanoseconds = slot.producerTimestampNanoseconds;
    lease.left = slot.left;
    lease.right = slot.right;
    lease.readyEvent = slot.readyEvent;
    lease.readyValue = slot.readyValue;
    lease.renderTracking = slot.renderTracking;
    lease.reconstruction = slot.reconstruction;
    lease.jitter = slot.jitter;
    lease.leftSlice = slot.leftSlice; lease.leftX = slot.leftX; lease.leftY = slot.leftY;
    lease.leftWidth = slot.leftWidth; lease.leftHeight = slot.leftHeight;
    lease.rightSlice = slot.rightSlice; lease.rightX = slot.rightX; lease.rightY = slot.rightY;
    lease.rightWidth = slot.rightWidth; lease.rightHeight = slot.rightHeight;

    outFrame->abiVersion = WVR_COMPOSITOR_ABI_VERSION;
    outFrame->structSize = sizeof(WVRAcquiredStereoFrameV1);
    outFrame->compositorTicket = lease.ticket;
    outFrame->producerFrameID = lease.producerFrameID;
    outFrame->producerTimestampNanoseconds = lease.producerTimestampNanoseconds;
    outFrame->lease = (__bridge_retained void *)lease;
    outFrame->leftTexture = (__bridge void *)lease.left;
    outFrame->rightTexture = (__bridge void *)lease.right;
    outFrame->producerReadyEvent = (__bridge void *)lease.readyEvent;
    outFrame->producerReadyValue = lease.readyValue;
    clearSlot(slot);
    bridge.head = (bridge.head + 1) % kQueueCapacity;
    --bridge.count;
    ++bridge.outstandingLeases;
    ++bridge.stats.acquiredFrames;
    bridge.stats.queuedFrames = static_cast<uint32_t>(bridge.count);
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_acquire_latest_stereo_frame_v2(
    WVRAcquiredStereoFrameV2 *outFrame) {
    if (!outFrame || outFrame->structSize < sizeof(WVRAcquiredStereoFrameV2))
        return WVRCompositorStatusInvalidArgument;
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (bridge.count == 0) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusNoFrameAvailable;
    }
    const int readyOffset = newestReadyOffsetLocked(bridge);
    if (readyOffset < 0) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusNoFrameAvailable;
    }
    for (int skipped = 0; skipped < readyOffset; ++skipped) dropHeadLocked(bridge);
    QueuedFrame &slot = bridge.queue[bridge.head];
    WVRFrameLease *lease = [WVRFrameLease new];
    lease.ticket = slot.ticket;
    lease.producerFrameID = slot.producerFrameID;
    lease.producerTimestampNanoseconds = slot.producerTimestampNanoseconds;
    lease.left = slot.left; lease.right = slot.right;
    lease.readyEvent = slot.readyEvent; lease.readyValue = slot.readyValue;
    lease.renderTracking = slot.renderTracking;
    lease.reconstruction = slot.reconstruction;
    lease.jitter = slot.jitter;
    lease.leftSlice = slot.leftSlice; lease.leftX = slot.leftX; lease.leftY = slot.leftY;
    lease.leftWidth = slot.leftWidth; lease.leftHeight = slot.leftHeight;
    lease.rightSlice = slot.rightSlice; lease.rightX = slot.rightX; lease.rightY = slot.rightY;
    lease.rightWidth = slot.rightWidth; lease.rightHeight = slot.rightHeight;
    outFrame->abiVersion = WVR_COMPOSITOR_ABI_VERSION_V2;
    outFrame->structSize = sizeof(WVRAcquiredStereoFrameV2);
    outFrame->compositorTicket = lease.ticket;
    outFrame->producerFrameID = lease.producerFrameID;
    outFrame->producerTimestampNanoseconds = lease.producerTimestampNanoseconds;
    outFrame->lease = (__bridge_retained void *)lease;
    outFrame->leftTexture = (__bridge void *)lease.left;
    outFrame->rightTexture = (__bridge void *)lease.right;
    outFrame->producerReadyEvent = (__bridge void *)lease.readyEvent;
    outFrame->producerReadyValue = lease.readyValue;
    outFrame->leftSlice = lease.leftSlice; outFrame->leftX = lease.leftX; outFrame->leftY = lease.leftY;
    outFrame->leftWidth = lease.leftWidth; outFrame->leftHeight = lease.leftHeight;
    outFrame->rightSlice = lease.rightSlice; outFrame->rightX = lease.rightX; outFrame->rightY = lease.rightY;
    outFrame->rightWidth = lease.rightWidth; outFrame->rightHeight = lease.rightHeight;
    outFrame->jitterFlags = lease.jitter.flags;
    outFrame->renderFlags = lease.jitter.renderFlags;
    for (unsigned eye = 0; eye < 2; ++eye) {
        outFrame->jitterNdc[eye][0] = lease.jitter.ndc[eye][0];
        outFrame->jitterNdc[eye][1] = lease.jitter.ndc[eye][1];
    }
    clearSlot(slot);
    bridge.head = (bridge.head + 1) % kQueueCapacity;
    --bridge.count; ++bridge.outstandingLeases; ++bridge.stats.acquiredFrames;
    bridge.stats.queuedFrames = static_cast<uint32_t>(bridge.count);
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_copy_lease_tracking_v1(
    void *opaqueLease, WVRFrameTrackingV1 *outTracking) {
    if (!opaqueLease || !outTracking || outTracking->structSize < sizeof(*outTracking))
        return WVRCompositorStatusInvalidArgument;
    WVRFrameLease *lease = (__bridge WVRFrameLease *)opaqueLease;
    *outTracking = lease.renderTracking;
    return (outTracking->flags & WVRDevicePoseTracked) ? WVRCompositorStatusOK : WVRCompositorStatusNoFrameAvailable;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_copy_reconstruction_v1(void *opaque, WVRReconstructionSubmitV1 *out) {
    if(!opaque || !out || out->abiVersion!=WVR_RECONSTRUCTION_ABI || out->structSize!=sizeof(*out))return WVRCompositorStatusInvalidArgument;
    auto lease=(__bridge WVRFrameLease*)opaque;
    if(!lease.reconstruction)return WVRCompositorStatusNoFrameAvailable;
    *out=lease.reconstruction.metadata;
    out->eyes[0].colorTexture=(uint64_t)(__bridge void*)lease.left;out->eyes[1].colorTexture=(uint64_t)(__bridge void*)lease.right;
    out->eyes[0].depthTexture=(uint64_t)(__bridge void*)lease.reconstruction.leftDepth;out->eyes[1].depthTexture=(uint64_t)(__bridge void*)lease.reconstruction.rightDepth;
    out->compositorTicket=lease.ticket;out->status=0;return 0;
}

extern "C" WVR_COMPOSITOR_EXPORT void wvr_compositor_release_acquired_frame_v1(void *opaqueLease) {
    if (!opaqueLease) return;
    WVRFrameLease *lease = (__bridge_transfer WVRFrameLease *)opaqueLease;
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    markTicketCompleteLocked(bridge, lease.ticket);
    if (bridge.outstandingLeases > 0) --bridge.outstandingLeases;
    os_unfair_lock_unlock(&bridge.lock);
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_publish_frame_tracking_v1(
    uint64_t timestampNanoseconds, uint32_t flags,
    const float *originFromDevice16, const float *deviceFromEye32,
    const float *projection32, const float *frustumTangents8, const float *depthRange2) {
    FrameStateChanged notifyWaiters;
    traceBridgeCall(CallPublishTracking, "");
    if (!originFromDevice16 || !deviceFromEye32 || !projection32 ||
        !frustumTangents8 || !depthRange2) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (bridge.compositorPaused) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusOK;
    }
    bridge.tracking.abiVersion = WVR_COMPOSITOR_ABI_VERSION;
    bridge.tracking.structSize = sizeof(WVRFrameTrackingV1);
    bridge.tracking.flags = flags;
    bridge.tracking.timestampNanoseconds = timestampNanoseconds;
    std::copy(originFromDevice16, originFromDevice16 + 16, bridge.tracking.originFromDevice);
    for (size_t eye = 0; eye < WVR_COMPOSITOR_VIEW_COUNT; ++eye) {
        std::copy(deviceFromEye32 + eye * 16, deviceFromEye32 + (eye + 1) * 16,
                  bridge.tracking.deviceFromEye[eye]);
        std::copy(projection32 + eye * 16, projection32 + (eye + 1) * 16,
                  bridge.tracking.projection[eye]);
        std::copy(frustumTangents8 + eye * 4, frustumTangents8 + (eye + 1) * 4,
                  bridge.tracking.frustumTangents[eye]);
    }
    std::copy(depthRange2, depthRange2 + 2, bridge.tracking.depthRange);
    if ((flags & WVRDevicePoseTracked) && timestampNanoseconds) {
        // SDK display timestamps advance independently of guest frame arrival.
        // Reject missed ticks and use a bounded median to resist scheduling jitter.
        if (timestampNanoseconds > bridge.lastDisplayPublishTimestamp && bridge.lastDisplayPublishTimestamp) {
            const uint64_t interval = timestampNanoseconds - bridge.lastDisplayPublishTimestamp;
            if (interval >= 7000000 && interval <= 14000000) {
                bridge.displayPeriods[bridge.displayPeriodNext] = interval;
                bridge.displayPeriodNext = (bridge.displayPeriodNext + 1) % bridge.displayPeriods.size();
                bridge.displayPeriodCount = std::min(bridge.displayPeriodCount + 1, bridge.displayPeriods.size());
                auto periods = bridge.displayPeriods;
                std::sort(periods.begin(), periods.begin() + bridge.displayPeriodCount);
                bridge.displayPeriodNanoseconds = periods[bridge.displayPeriodCount / 2];
            }
        }
        bridge.lastDisplayPublishTimestamp = timestampNanoseconds;
        bridge.trackingHistory[bridge.trackingHistoryNext] = bridge.tracking;
        bridge.trackingHistoryNext = (bridge.trackingHistoryNext + 1) % bridge.trackingHistory.size();
        bridge.trackingHistoryCount = std::min(bridge.trackingHistoryCount + 1, bridge.trackingHistory.size());
    }
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_frame_state_v1(WVRFrameStateRequestV1 *request) {
    if (!request || request->abiVersion != WVR_FRAME_STATE_ABI || request->structSize != sizeof(*request))
        return WVRCompositorStatusUnsupportedABI;
    request->status = WVRCompositorStatusInvalidArgument;
    if (request->operation != 1 && request->operation != 2) return request->status;
    BridgeState &bridge = state();
    auto snapshot = [&] {
        os_unfair_lock_lock(&bridge.lock);
        request->tracking = bridge.tracking;
        request->targets = bridge.targets;
        request->displayPeriodNanoseconds = bridge.displayPeriodNanoseconds;
        for (uint32_t role = 0; role < WVR_COMPOSITOR_VIEW_COUNT; ++role) request->controllers[role] = bridge.controllers[role];
        if (bridge.sessionExitRequested) request->tracking.flags |= WVRDevicePoseSessionExitRequested;
        const bool ready = bridge.compositorPaused || bridge.sessionExitRequested ||
            (request->expectedTargetGeneration && bridge.targets.generation != request->expectedTargetGeneration) ||
            ((request->tracking.flags & WVRDevicePoseTracked) && request->tracking.timestampNanoseconds > request->afterTimestampNanoseconds);
        os_unfair_lock_unlock(&bridge.lock);
        return ready;
    };
    if (request->operation == 1) { snapshot(); request->status = 0; return 0; }
    const uint64_t suppliedTimeout = request->timeoutNanoseconds;
    const uint64_t timeout = std::min<uint64_t>(suppliedTimeout, 100000000);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::nanoseconds(timeout);
    std::unique_lock<std::mutex> waitLock(frameSignalMutex);
    frameWaiters.fetch_add(1, std::memory_order_release);
    struct WaiterScope { ~WaiterScope() { frameWaiters.fetch_sub(1, std::memory_order_release); } } waiterScope;
    while (!snapshot()) {
        if (frameSignal.wait_until(waitLock, deadline) == std::cv_status::timeout) { snapshot(); break; }
    }
    // A timeout returns the actual latest state, never a synthetic display pose.
    request->status = 0;
    return 0;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_copy_frame_tracking_v1(
    WVRFrameTrackingV1 *outTracking) {
    if (!outTracking || outTracking->structSize < sizeof(WVRFrameTrackingV1)) {
        return WVRCompositorStatusInvalidArgument;
    }
    traceBridgeCall(CallCopyTracking, "");
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    *outTracking = bridge.tracking;
    if (bridge.sessionExitRequested) {
        outTracking->flags |= WVRDevicePoseSessionExitRequested;
    }
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_copy_controller_state_v1(
    uint32_t role, WVRControllerStateV1 *outState) {
    traceBridgeCall(CallCopyController, role == 0 ? "left" : "right");
    if (role >= WVR_COMPOSITOR_VIEW_COUNT || !outState ||
        outState->structSize < sizeof(WVRControllerStateV1)) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    *outState = bridge.controllers[role];
    outState->abiVersion = WVR_COMPOSITOR_ABI_VERSION;
    outState->structSize = sizeof(WVRControllerStateV1);
    outState->role = role;
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_publish_controller_state_v1(
    uint32_t role, uint32_t flags, uint64_t timestampNanoseconds,
    const float *originFromController16, uint64_t buttons,
    float trigger, float grip, float thumbstickX, float thumbstickY) {
    if (role > WVRControllerRoleRight || !originFromController16 ||
        !std::isfinite(trigger) || !std::isfinite(grip) ||
        !std::isfinite(thumbstickX) || !std::isfinite(thumbstickY)) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (bridge.compositorPaused) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusOK;
    }
    WVRControllerStateV1 &controller = bridge.controllers[role];
    controller.abiVersion = WVR_COMPOSITOR_ABI_VERSION;
    controller.structSize = sizeof(WVRControllerStateV1);
    controller.role = role;
    controller.flags = flags;
    controller.timestampNanoseconds = timestampNanoseconds;
    std::copy(originFromController16, originFromController16 + 16, controller.originFromController);
    controller.buttons = buttons;
    controller.trigger = std::clamp(trigger, 0.0f, 1.0f);
    controller.grip = std::clamp(grip, 0.0f, 1.0f);
    controller.thumbstickX = std::clamp(thumbstickX, -1.0f, 1.0f);
    controller.thumbstickY = std::clamp(thumbstickY, -1.0f, 1.0f);
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_submit_haptic_v1(
    uint32_t role, float amplitude, float frequencyHz, float durationSeconds,
    uint64_t *outSequence) {
    if (role > WVRControllerRoleRight || !outSequence ||
        !std::isfinite(amplitude) || !std::isfinite(frequencyHz) ||
        !std::isfinite(durationSeconds)) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (bridge.compositorPaused) {
        *outSequence = 0;
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusNoHapticAvailable;
    }
    WVRHapticRequestV1 &request = bridge.haptics[role];
    request.abiVersion = WVR_COMPOSITOR_ABI_VERSION;
    request.structSize = sizeof(WVRHapticRequestV1);
    request.role = role;
    request.reserved = 0;
    request.sequence = bridge.nextHapticSequence++;
    request.amplitude = std::clamp(amplitude, 0.0f, 1.0f);
    request.frequencyHz = std::clamp(frequencyHz, 0.0f, 1000.0f);
    // Preserve explicit stop requests and the OpenXR adapter's five-second bound.
    request.durationSeconds = amplitude <= 0 ? 0 : std::clamp(durationSeconds, 0.0f, 5.0f);
    request.reservedFloat = 0.0f;
    bridge.hapticPending[role] = true;
    *outSequence = request.sequence;
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_take_haptic_v1(
    uint32_t role, WVRHapticRequestV1 *outRequest) {
    if (role > WVRControllerRoleRight || !outRequest ||
        outRequest->structSize < sizeof(WVRHapticRequestV1)) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    if (!bridge.hapticPending[role]) {
        os_unfair_lock_unlock(&bridge.lock);
        return WVRCompositorStatusNoHapticAvailable;
    }
    *outRequest = bridge.haptics[role];
    bridge.hapticPending[role] = false;
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}

extern "C" WVR_COMPOSITOR_EXPORT int32_t wvr_compositor_copy_stats_v1(
    WVRCompositorStatsV1 *outStats) {
    if (!outStats || outStats->structSize < sizeof(WVRCompositorStatsV1)) {
        return WVRCompositorStatusInvalidArgument;
    }
    BridgeState &bridge = state();
    os_unfair_lock_lock(&bridge.lock);
    *outStats = bridge.stats;
    os_unfair_lock_unlock(&bridge.lock);
    return WVRCompositorStatusOK;
}
