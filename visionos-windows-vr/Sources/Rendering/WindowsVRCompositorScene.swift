import ARKit
import CompositorServices
import Metal
import QuartzCore
import os
import SwiftUI
import simd

/// Add this scene to the app's SceneBuilder to provide a compositor-backed
/// immersive destination for GPU frames submitted through the native bridge.
@available(visionOS 1.0, *)
struct WindowsVRCompositorScene: Scene {
    static let identifier = "WindowsVRCompositor"
    private let model: LauncherModel

    init(model: LauncherModel) {
        self.model = model
    }

    var body: some Scene {
        // A VR game replaces the world, like an OpenXR runtime with opaque environment blending. The system's
        // default (mixed) style composites the layer over passthrough using alpha.
        ImmersiveSpace(id: Self.identifier) {
            CompositorLayer(configuration: WindowsVRCompositorConfiguration()) { layerRenderer in
                let transfer = WindowsVRLayerRendererTransfer(renderer: layerRenderer)
                let task = Task.detached(executorPreference: WindowsVRRenderTaskExecutor.shared) {
                    if #available(visionOS 27.0, *) {
                        let renderer = WindowsVRCompositorRenderer(layerRenderer: transfer.renderer)
                        await renderer.run()
                    }
                }
                WindowsVRCompositorTaskStore.shared.install(task)
            }
            .onDisappear {
                WindowsVRCompositorTaskStore.shared.stop()
                Task { await model.immersiveSpaceDidClose() }
            }
        }
        .immersionStyle(selection: .constant(.full), in: .full)
        .upperLimbVisibility(.hidden)
        .persistentSystemOverlays(.hidden)
    }
}

private final class WindowsVRCompositorTaskStore: @unchecked Sendable {
    static let shared = WindowsVRCompositorTaskStore()
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func install(_ newTask: Task<Void, Never>) {
        let previous = lock.withLock {
            let previous = task
            task = newTask
            return previous
        }
        previous?.cancel()
    }

    func stop() {
        let running = lock.withLock {
            let running = task
            task = nil
            return running
        }
        running?.cancel()
        wvr_compositor_pause_v1()
    }
}

private final class WindowsVRFrameTransferStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var didFail = false
    var failed: Bool { lock.withLock { didFail } }
    func markFailed() { lock.withLock { didFail = true } }
}

// CompositorLayer hands renderer ownership to this dedicated rendering task.
// The UI never accesses it after transfer; all renderer use stays on the
// serial executor rather than inheriting SwiftUI's main actor.
private struct WindowsVRLayerRendererTransfer: @unchecked Sendable {
    let renderer: LayerRenderer
}

/// Guest frames use a uniform eye raster today. Keep foveation disabled until
/// the guest render pass consumes Apple's rasterization-rate maps. Dedicated
/// textures are preferred; the target mapper also handles layered eye slices.
@available(visionOS 1.0, *)
private struct WindowsVRCompositorConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(
        capabilities: LayerRenderer.Capabilities,
        configuration: inout LayerRenderer.Configuration
    ) {
        let layouts = capabilities.supportedLayouts(options: [])
        if layouts.contains(.dedicated) {
            configuration.layout = .dedicated
        } else if layouts.contains(.layered) {
            configuration.layout = .layered
        }
        configuration.isFoveationEnabled = false
        // Render-quality overrides are only supported with foveation. Leave the
        // system's non-foveated quality untouched for uniform guest eye textures.
        // Match the guest runtime's advertised D3D11 sRGB swapchain format.
        // The compositor default may be RGBA16Float, which this first path
        // must not accidentally advertise as an unsupported 8-bit format.
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.depthFormat = .depth32Float
        // The compositor bridge clears render targets, copies exact-size game
        // frames, and spatially filters lower-resolution frames into them.
        configuration.colorUsage = [.renderTarget, .shaderRead]
    }
}

/// Compositor Services requires a dedicated render thread. This serial executor
/// keeps all access to LayerRenderer on one user-interactive queue.
private final class WindowsVRRenderTaskExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "org.avpplay.windows-vr.compositor", qos: .userInteractive)
    static let shared = WindowsVRRenderTaskExecutor()

    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        queue.async {
            unownedJob.runSynchronously(on: self.asUnownedTaskExecutor())
        }
    }

    nonisolated func asUnownedTaskExecutor() -> UnownedTaskExecutor {
        UnownedTaskExecutor(ordinary: self)
    }
}

@available(visionOS 1.0, *)
@available(visionOS 27.0, *)
private final class WindowsVRCompositorRenderer {
    private static let log = Logger(subsystem: "org.avpplay.windows-vr", category: "compositor")
    private let layerRenderer: LayerRenderer
    private let metalCommandQueue: MTLCommandQueue?
    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()
    private let controllerTracking = WindowsVRControllerProvider()
    private let compositorClock = LayerRenderer.Clock()
    private let spatialLibrary: MTLLibrary?
    private let spatialSampler: MTLSamplerState?
    private let presentationDepthState: MTLDepthStencilState?
    private var spatialPipelines: [UInt: any MTLRenderPipelineState] = [:]
    // Owned snapshots outlive a guest swapchain lease. They are updated and read
    // on the same Metal command queue, never by retaining a reusable guest image.
    private var lastEyeSnapshots: [any MTLTexture] = []
    private var snapshotGeneration: UInt64 = 0
    private var snapshotTracking: WVRFrameTrackingV1?
    private var loggedMissingAnchor = false
    private var lastDrawableLayout = ""
    private var lastFrameDiagnosticTime: TimeInterval = 0
    private var lastGPUStatisticsTime: TimeInterval = 0
    private var transferStatus: WindowsVRFrameTransferStatus?
    private var performanceStartedAt = CACurrentMediaTime()
    private var presentationCount: UInt64 = 0
    private var transferCount: UInt64 = 0
    private var lastTransferTime: TimeInterval?
    private var transferIntervals: [Double] = []
    private var transferBytes: UInt64 = 0
    private var encodeMilliseconds: Double = 0

    private static let spatialShaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct WVRSpatialVertexOut {
        float4 position [[position]];
        float2 uv;
    };
    vertex WVRSpatialVertexOut wvr_spatial_vertex(uint vertexID [[vertex_id]]) {
        const float2 positions[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        const float2 coordinates[3] = { float2(0.0, 1.0), float2(2.0, 1.0), float2(0.0, -1.0) };
        WVRSpatialVertexOut out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        out.uv = coordinates[vertexID];
        return out;
    }
    struct WVRSpatialSource {
        float2 origin;
        float2 extent;
        uint slice;
        uint padding;
        float presentationDepth;
        float reserved;
        float4x4 sourceFromDestinationClip;
    };
    struct WVRSpatialFragmentOut {
        float4 color [[color(0)]];
        float depth [[depth(any)]];
    };
    fragment WVRSpatialFragmentOut wvr_spatial_fragment(
        WVRSpatialVertexOut in [[stage_in]],
        texture2d<float> source [[texture(0)]],
        sampler linearClamp [[sampler(0)]],
        constant WVRSpatialSource& region [[buffer(0)]]) {
        float4 sourceClip = region.sourceFromDestinationClip * float4(2.0 * in.uv.x - 1.0, 1.0 - 2.0 * in.uv.y, region.presentationDepth, 1.0);
        float2 sourceUV = sourceClip.xy / sourceClip.w * float2(0.5, -0.5) + 0.5;
        if (sourceClip.w <= 0.0 || any(sourceUV < 0.0) || any(sourceUV > 1.0))
            return { float4(0.0, 0.0, 0.0, 1.0), region.presentationDepth };
        float2 pixel = clamp(region.origin + sourceUV * region.extent, region.origin + 0.5, region.origin + region.extent - 0.5);
        float2 uv = pixel / float2(source.get_width(), source.get_height());
        // OpenXR opaque blend (and any layer without source-alpha blending): the game's alpha is not coverage.
        // Unreal and others leave it near zero, which the visionOS compositor would show as passthrough.
        return { float4(source.sample(linearClamp, uv).rgb, 1.0), region.presentationDepth };
    }
    fragment WVRSpatialFragmentOut wvr_spatial_array_fragment(
        WVRSpatialVertexOut in [[stage_in]],
        texture2d_array<float> source [[texture(0)]],
        sampler linearClamp [[sampler(0)]],
        constant WVRSpatialSource& region [[buffer(0)]]) {
        float4 sourceClip = region.sourceFromDestinationClip * float4(2.0 * in.uv.x - 1.0, 1.0 - 2.0 * in.uv.y, region.presentationDepth, 1.0);
        float2 sourceUV = sourceClip.xy / sourceClip.w * float2(0.5, -0.5) + 0.5;
        if (sourceClip.w <= 0.0 || any(sourceUV < 0.0) || any(sourceUV > 1.0))
            return { float4(0.0, 0.0, 0.0, 1.0), region.presentationDepth };
        float2 pixel = clamp(region.origin + sourceUV * region.extent, region.origin + 0.5, region.origin + region.extent - 0.5);
        float2 uv = pixel / float2(source.get_width(), source.get_height());
        return { float4(source.sample(linearClamp, uv, region.slice).rgb, 1.0), region.presentationDepth };
    }
    """

    init(layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        self.metalCommandQueue = layerRenderer.device.makeCommandQueue()
        self.spatialLibrary = try? layerRenderer.device.makeLibrary(
            source: Self.spatialShaderSource,
            options: nil
        )
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        self.spatialSampler = layerRenderer.device.makeSamplerState(descriptor: samplerDescriptor)
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .always
        depthDescriptor.isDepthWriteEnabled = true
        self.presentationDepthState = layerRenderer.device.makeDepthStencilState(descriptor: depthDescriptor)
    }

    func run() async {
        LaunchLogFile.append("compositor", "Renderer initialized: uniform eye textures, system quality, foveation=false")
        wvr_compositor_pause_v1()
        let deviceObject = layerRenderer.device as AnyObject
        let bindStatus = wvr_compositor_bind_metal_device_v1(Unmanaged.passUnretained(deviceObject).toOpaque())
        guard bindStatus == 0 else {
            wvr_compositor_pause_v1()
            return
        }

        var trackingStarted = false
        defer {
            LaunchLogFile.append("lifecycle", "Render task ended; cancelled=\(Task.isCancelled)")
            arSession.stop()
            controllerTracking.reset()
            wvr_compositor_pause_v1()
        }

        while !Task.isCancelled {
            switch layerRenderer.state {
            case .paused:
                Self.log.notice("Layer renderer paused")
                LaunchLogFile.append("lifecycle", "Layer renderer paused")
                wvr_compositor_pause_v1()
                if trackingStarted {
                    arSession.stop()
                    controllerTracking.reset()
                    trackingStarted = false
                }
                layerRenderer.waitUntilRunning()
            case .running:
                if !trackingStarted {
                    Self.log.notice("Layer renderer running; starting tracking")
                    await startTracking()
                    trackingStarted = true
                }
                renderNextFrame()
            case .invalidated:
                Self.log.notice("Layer renderer invalidated")
                LaunchLogFile.append("lifecycle", "Layer renderer invalidated")
                return
            @unknown default:
                return
            }
        }
    }

    private func startTracking() async {
        let authorization = await arSession.requestAuthorization(for: [.worldSensing, .accessoryTracking])
        Self.log.notice("ARKit authorization: worldSensing=\(String(describing: authorization[.worldSensing])) accessoryTracking=\(String(describing: authorization[.accessoryTracking]))")
        let controllerProviders = await controllerTracking.configure(
            authorized: authorization[.accessoryTracking] == .allowed
        )
        var providers: [any DataProvider] = [worldTracking]
        providers.append(contentsOf: controllerProviders)
        do {
            try await arSession.run(providers)
        } catch {
            // A controller provider must never take head tracking down with it:
            // without a device anchor every drawable is dropped by the compositor.
            Self.log.error("ARKitSession.run with \(providers.count) providers failed: \(String(describing: error)); retrying with world tracking only")
            controllerTracking.reset()
            do {
                try await arSession.run([worldTracking])
            } catch {
                Self.log.error("ARKitSession.run (world tracking only) failed: \(String(describing: error))")
                publishUnavailablePose()
                return
            }
        }
        Self.log.notice("ARKit session running; worldTracking.state=\(String(describing: self.worldTracking.state))")
    }

    private func renderNextFrame() {
        guard let frame = layerRenderer.queryNextFrame(),
              let predictedTiming = frame.predictTiming()
        else {
            publishUnavailablePose()
            controllerTracking.publishUnavailableState()
            Thread.sleep(forTimeInterval: 0.001)
            return
        }

        frame.startUpdate()
        frame.endUpdate()
        compositorClock.wait(until: predictedTiming.optimalInputTime, tolerance: nil)
        frame.startSubmission()

        let drawables = frame.queryDrawables()
        guard !drawables.isEmpty else {
            // An empty query cancels the frame. The SDK explicitly forbids
            // further access, including endSubmission, even if the layer has
            // already returned to .running by the time we check its state.
            wvr_compositor_pause_v1()
            publishUnavailablePose()
            controllerTracking.publishUnavailableState()
            return
        }

        if LaunchDiagnostics.enabled {
            let layout = drawables.map { "target=\($0.target.rawValue) views=\($0.views.count)" }.joined(separator: "; ")
            if layout != lastDrawableLayout {
                lastDrawableLayout = layout
                LaunchLogFile.append("compositor", "Drawable routing: \(layout); built-in display owns guest targets")
            }
        }

        WindowsVRDrawableRouter.renderFrame(
            drawables,
            isDisplay: { $0.target == .builtIn },
            prepareDisplay: { drawable in
                guard publishTargets(for: drawable) else { return false }
                publishFrameTracking(for: drawable)
                return true
            },
            render: { drawable, consumeGuestFrame in
                // Capture can be monocular and has its own viewport/format. It
                // reuses the display snapshot and must not reset shared targets,
                // tracking, controller state, or acquire another guest lease.
                if !consumeGuestFrame, let display = drawables.first(where: { $0.target == .builtIn }) {
                    drawable.deviceAnchor = display.deviceAnchor
                }
                render(drawable, consumeGuestFrame: consumeGuestFrame)
            },
            invalidateDisplay: {
                wvr_compositor_pause_v1()
                publishUnavailablePose()
                controllerTracking.publishUnavailableState()
            }
        )
        endSubmissionIfValid(frame)
    }

    /// The compositor invalidates a frame when the layer leaves `.running`
    /// mid-frame (the immersive space is closing or pausing). Ending an invalid
    /// frame aborts the process with "cp_frame_end_submission() failed because
    /// the frame is not valid", so only end frames that are still valid.
    private func endSubmissionIfValid(_ frame: LayerRenderer.Frame) {
        guard layerRenderer.state == .running else {
            Self.log.notice("Dropping frame submission: layer renderer state is \(String(describing: self.layerRenderer.state))")
            return
        }
        frame.endSubmission()
    }

    private func target(for drawable: LayerRenderer.Drawable, viewIndex: Int) -> EyeTarget? {
        guard drawable.views.indices.contains(viewIndex) else { return nil }
        let map = drawable.views[viewIndex].textureMap
        guard drawable.colorTextures.indices.contains(map.textureIndex),
              drawable.depthTextures.indices.contains(map.textureIndex) else { return nil }
        let texture = drawable.colorTextures[map.textureIndex]
        let viewport = map.viewport
        let width = UInt32(max(0, Int(viewport.width.rounded(.down))))
        let height = UInt32(max(0, Int(viewport.height.rounded(.down))))
        guard width > 0, height > 0 else { return nil }
        return EyeTarget(
            texture: texture,
            depthTexture: drawable.depthTextures[map.textureIndex],
            slice: map.sliceIndex,
            originX: Int(viewport.originX.rounded(.down)),
            originY: Int(viewport.originY.rounded(.down)),
            width: width,
            height: height,
            pixelFormat: UInt32(texture.pixelFormat.rawValue)
        )
    }

    @discardableResult
    private func publishTargets(for drawable: LayerRenderer.Drawable) -> Bool {
        guard drawable.views.count == 2,
              let view0 = target(for: drawable, viewIndex: 0),
              let view1 = target(for: drawable, viewIndex: 1)
        else { return false }

        return wvr_compositor_publish_targets_v1(
            view0.width, view0.height, view0.pixelFormat,
            view1.width, view1.height, view1.pixelFormat
        ) == 0
    }

    private func publishFrameTracking(for drawable: LayerRenderer.Drawable) {
        guard drawable.views.count == 2 else {
            publishUnavailablePose()
            return
        }

        // Head prediction uses display time; controller prediction uses camera time.
        let targetTimestamp = timestampSeconds(drawable.frameTiming.presentationTime)
        controllerTracking.publishPredictedState(at: timestampSeconds(drawable.frameTiming.trackableAnchorTime))

        // World tracking has no anchor for the first frames after the immersive
        // space opens; without one there is no head pose to publish.
        guard let anchor = worldTracking.queryDeviceAnchor(atTimestamp: targetTimestamp) else {
            anchorMissing += 1
            if !loggedMissingAnchor {
                loggedMissingAnchor = true
                Self.log.error("No device anchor yet; worldTracking.state=\(String(describing: self.worldTracking.state))")
            }
            publishUnavailablePose()
            return
        }
        loggedMissingAnchor = false
        anchorFound += 1
        if anchor.isTracked { anchorTracked += 1 }
        lastHeadPosition = SIMD3<Float>(anchor.originFromAnchorTransform.columns.3.x, anchor.originFromAnchorTransform.columns.3.y, anchor.originFromAnchorTransform.columns.3.z)
        // Set the anchor even when it is not yet tracked: the compositor needs
        // it to reproject the frame to the display-time head pose.
        drawable.deviceAnchor = anchor
        let isTracked = anchor.isTracked
        let originFromDevice = isTracked ? anchor.originFromAnchorTransform : matrix_identity_float4x4

        var deviceFromEye: [Float] = []
        var projections: [Float] = []
        var frustumTangents: [Float] = []
        for viewIndex in 0..<2 {
            let view = drawable.views[viewIndex]
            let projection = drawable.computeProjection(convention: .rightUpBack, viewIndex: viewIndex)
            appendMatrix(view.transform, to: &deviceFromEye)
            appendMatrix(projection, to: &projections)

            // The runtime needs OpenVR's off-axis eye angles as well as the
            // projection matrix. `View.tangents` is deprecated since visionOS 2
            // and aborts the process ("BUG IN CLIENT") on current releases, so
            // recover the same four tangents from the projection instead.
            guard let fov = Self.frustumTangents(fromProjection: projection) else {
                publishUnavailablePose()
                return
            }
            frustumTangents.append(contentsOf: fov)
        }
        let depthRange = drawable.depthRange
        let headValues = matrixValues(originFromDevice)
        let depthValues = [depthRange.x, depthRange.y]
        let flags: UInt32 = isTracked ? 0b11 : 0

        headValues.withUnsafeBufferPointer { headBuffer in
            deviceFromEye.withUnsafeBufferPointer { eyeBuffer in
                projections.withUnsafeBufferPointer { projectionBuffer in
                    frustumTangents.withUnsafeBufferPointer { tangentBuffer in
                        depthValues.withUnsafeBufferPointer { depthBuffer in
                            _ = wvr_compositor_publish_frame_tracking_v1(
                                UInt64(max(0, targetTimestamp * 1.0e9)), flags,
                                headBuffer.baseAddress, eyeBuffer.baseAddress,
                                projectionBuffer.baseAddress, tangentBuffer.baseAddress,
                                depthBuffer.baseAddress
                            )
                        }
                    }
                }
            }
        }
    }

    /// Frustum tangents `[left, right, top, bottom]` (positive magnitudes, the
    /// order and sign `View.tangents` used) from a right-handed `.rightUpBack`
    /// perspective projection: with column-major `P`, `P[0][0] = 2 / (r + l)`,
    /// `P[2][0] = (r - l) / (r + l)` and likewise for y.
    private static func frustumTangents(fromProjection p: simd_float4x4) -> [Float]? {
        let sx = p.columns.0.x, sy = p.columns.1.y
        let ox = p.columns.2.x, oy = p.columns.2.y
        guard sx.isFinite, sy.isFinite, ox.isFinite, oy.isFinite, sx > 0, sy > 0 else { return nil }
        let tangents = [(1 - ox) / sx, (1 + ox) / sx, (1 + oy) / sy, (1 - oy) / sy]
        return tangents.allSatisfy { $0.isFinite && $0 > 0 } ? tangents : nil
    }

    private func publishUnavailablePose(timestamp: TimeInterval = CACurrentMediaTime()) {
        let identity = matrixValues(matrix_identity_float4x4)
        let eyes = identity + identity
        let projections = identity + identity
        let tangents = [Float](repeating: 0, count: 8)
        let depth = [Float](repeating: 0, count: 2)
        identity.withUnsafeBufferPointer { headBuffer in
            eyes.withUnsafeBufferPointer { eyeBuffer in
                projections.withUnsafeBufferPointer { projectionBuffer in
                    tangents.withUnsafeBufferPointer { tangentBuffer in
                        depth.withUnsafeBufferPointer { depthBuffer in
                            _ = wvr_compositor_publish_frame_tracking_v1(
                                UInt64(max(0, timestamp * 1.0e9)), 0,
                                headBuffer.baseAddress, eyeBuffer.baseAddress,
                                projectionBuffer.baseAddress, tangentBuffer.baseAddress,
                                depthBuffer.baseAddress
                            )
                        }
                    }
                }
            }
        }
    }

    private func render(_ drawable: LayerRenderer.Drawable, consumeGuestFrame: Bool) {
        let encodeStartedAt = CACurrentMediaTime()
        if transferStatus?.failed == true {
            lastEyeSnapshots.removeAll()
            snapshotGeneration = 0
            snapshotTracking = nil
            transferStatus = nil
        }
        guard let commandBuffer = metalCommandQueue?.makeCommandBuffer() else { return }
        commandBuffer.label = "wvr.presentation"

        var acquired = WVRAcquiredStereoFrameV2()
        acquired.structSize = UInt32(MemoryLayout<WVRAcquiredStereoFrameV2>.size)
        if LaunchDiagnostics.enabled {
            let now=CACurrentMediaTime()
            if now-lastGPUStatisticsTime>=5 {
                lastGPUStatisticsTime=now
                var text=[CChar](repeating:0,count:2048)
                if wvr_metal_copy_gpu_statistics(&text,UInt32(text.count)) != 0 {
                    LaunchLogFile.append("gpu-timing",String(cString:text))
                }
            }
        }
        let acquireStatus = consumeGuestFrame ? withUnsafeMutablePointer(to: &acquired) {
            wvr_compositor_acquire_latest_stereo_frame_v2($0)
        } : Int32(WVRCompositorStatusNoFrameAvailable.rawValue)
        let hasFrame = acquireStatus == 0 && acquired.lease != nil
        var renderTracking: WVRFrameTrackingV1? = nil
        if let lease = acquired.lease {
            var sample = WVRFrameTrackingV1()
            sample.structSize = UInt32(MemoryLayout<WVRFrameTrackingV1>.size)
            if wvr_compositor_copy_lease_tracking_v1(lease, &sample) == 0 { renderTracking = sample }
        }
        let diagnosticTime = ProcessInfo.processInfo.systemUptime
        var diagnoseThisFrame = false
        if diagnosticTime - lastFrameDiagnosticTime >= 5 {
            lastFrameDiagnosticTime = diagnosticTime
            diagnoseThisFrame = LaunchDiagnostics.enabled
            var stats = WVRCompositorStatsV1()
            stats.abiVersion = 1
            stats.structSize = UInt32(MemoryLayout<WVRCompositorStatsV1>.size)
            if wvr_compositor_copy_stats_v1(&stats) == 0 {
                let message = "Guest frames: submitted=\(stats.submittedFrames) acquired=\(stats.acquiredFrames) completed=\(stats.completedFrames) dropped=\(stats.droppedFrames) queued=\(stats.queuedFrames) available=\(hasFrame) acquireStatus=\(acquireStatus) | anchors: found=\(anchorFound) missing=\(anchorMissing) tracked=\(anchorTracked) head=\(lastHeadPosition) worldTracking=\(String(describing: worldTracking.state)) layer=\(String(describing: layerRenderer.state))"
                Self.log.notice("\(message, privacy: .public)")
                if LaunchDiagnostics.enabled { LaunchLogFile.append("compositor", message) }
            }
        }

        var leftTexture: (any MTLTexture)?
        var rightTexture: (any MTLTexture)?
        var readyEvent: (any MTLSharedEvent)?
        var leftSource: EyeSource?
        var rightSource: EyeSource?
        if hasFrame,
           let leftPointer = acquired.leftTexture,
           let rightPointer = acquired.rightTexture,
           let eventPointer = acquired.producerReadyEvent {
            leftTexture = Unmanaged<AnyObject>.fromOpaque(leftPointer).takeUnretainedValue() as? any MTLTexture
            rightTexture = Unmanaged<AnyObject>.fromOpaque(rightPointer).takeUnretainedValue() as? any MTLTexture
            readyEvent = Unmanaged<AnyObject>.fromOpaque(eventPointer).takeUnretainedValue() as? any MTLSharedEvent
            if let leftTexture, let rightTexture {
                leftSource = EyeSource(texture: leftTexture, slice: Int(acquired.leftSlice),
                                       x: Int(acquired.leftX), y: Int(acquired.leftY),
                                       width: Int(acquired.leftWidth), height: Int(acquired.leftHeight))
                rightSource = EyeSource(texture: rightTexture, slice: Int(acquired.rightSlice),
                                        x: Int(acquired.rightX), y: Int(acquired.rightY),
                                        width: Int(acquired.rightWidth), height: Int(acquired.rightHeight))
            }
        }

        var producerTargets = WVRRenderTargetInfoV1()
        producerTargets.structSize = UInt32(MemoryLayout<WVRRenderTargetInfoV1>.size)
        let targetStatus = wvr_compositor_copy_targets_v1(&producerTargets)
        let producerWidths = [producerTargets.width.0, producerTargets.width.1]
        let producerHeights = [producerTargets.height.0, producerTargets.height.1]
        let producerFormats = [producerTargets.pixelFormat.0, producerTargets.pixelFormat.1]
        let hasCurrentTargets = targetStatus == 0 && producerTargets.generation != 0 &&
            producerWidths.allSatisfy { $0 > 0 } && producerHeights.allSatisfy { $0 > 0 }

        let targets = (0..<drawable.views.count).compactMap { target(for: drawable, viewIndex: $0) }
        var sources = [leftSource, rightSource]
        let isNewGuestFrame = hasFrame
        if snapshotGeneration != producerTargets.generation || !hasCurrentTargets {
            lastEyeSnapshots.removeAll()
            snapshotGeneration = 0
            snapshotTracking = nil
        }
        if !hasFrame, lastEyeSnapshots.count == 2,
           snapshotGeneration == producerTargets.generation {
            renderTracking = snapshotTracking
            sources = lastEyeSnapshots.map {
                EyeSource(texture: $0, slice: 0, x: 0, y: 0, width: $0.width, height: $0.height)
            }
        }
        let matchesTarget = (hasFrame || lastEyeSnapshots.count == 2) && hasCurrentTargets && !drawable.views.isEmpty && drawable.views.count <= 2 &&
            targets.count == drawable.views.count && sources.count == 2 && sources.allSatisfy { $0 != nil } && (!hasFrame || readyEvent != nil) &&
            targets.indices.allSatisfy { index in
                guard let source = sources[index] else { return false }
                return source.width <= Int(producerWidths[index]) &&
                       source.height <= Int(producerHeights[index]) &&
                       source.width > 0 && source.height > 0 && source.slice >= 0 &&
                       source.slice < source.texture.arrayLength &&
                       source.x >= 0 && source.y >= 0 &&
                       source.x <= source.texture.width && source.y <= source.texture.height &&
                       source.width <= source.texture.width - source.x &&
                       source.height <= source.texture.height - source.y &&
                       (!consumeGuestFrame || producerFormats[index] == targets[index].pixelFormat) &&
                       UInt32(source.texture.pixelFormat.rawValue) == producerFormats[index] &&
                       source.texture.device === layerRenderer.device
            }

        if diagnoseThisFrame {
            let detail = sources.enumerated().map { index, source -> String in
                guard let source else { return "eye\(index)=nil" }
                let target = index < targets.count ? targets[index] : nil
                let depth = index < drawable.views.count ? presentationDepth(for: drawable, viewIndex: index) : nil
                return "eye\(index) src=\(source.width)x\(source.height)@\(source.x),\(source.y) fmt=\(source.texture.pixelFormat.rawValue) tex=\(source.texture.width)x\(source.texture.height) dst=\(target.map { "\($0.width)x\($0.height) fmt=\($0.pixelFormat)" } ?? "nil") sameDevice=\(source.texture.device === layerRenderer.device) presentationDepth=\(depth.map(String.init(describing:)) ?? "invalid") renderPose=\(renderTracking != nil)"
            }.joined(separator: " | ")
            LaunchLogFile.append("compositor", "render: matchesTarget=\(matchesTarget) hasFrame=\(hasFrame) hasTargets=\(hasCurrentTargets) views=\(drawable.views.count) targets=\(targets.count) event=\(readyEvent != nil) \(detail)")
        }

        // Copy on the same serial GPU queue before presenting, then return
        // guest images as soon as that copy finishes. Presentation only reads
        // owned snapshots, so producer reuse need not wait for encodePresent.
        var leaseCompletionBuffer: any MTLCommandBuffer = commandBuffer
        var transferred = false
        if hasFrame && matchesTarget, let leftSource, let rightSource,
           let readyEvent, let transfer = metalCommandQueue?.makeCommandBuffer() {
            transfer.label = "wvr.snapshot"
            transfer.encodeWaitForEvent(readyEvent, value: acquired.producerReadyValue)
            if cacheEyes([leftSource, rightSource], generation: producerTargets.generation,
                         tracking: renderTracking, on: transfer) {
                let status = WindowsVRFrameTransferStatus()
                transferStatus = status
                transfer.addCompletedHandler { completed in
                    if let error = completed.error {
                        status.markFailed()
                        LaunchLogFile.append("compositor", "Snapshot transfer failed: \(error)")
                    }
                }
                sources = lastEyeSnapshots.map {
                    EyeSource(texture: $0, slice: 0, x: 0, y: 0, width: $0.width, height: $0.height)
                }
                transferred = true
                leaseCompletionBuffer = transfer
                transferCount &+= 1
                if LaunchDiagnostics.enabled {
                    let now = CACurrentMediaTime()
                    if let previous = lastTransferTime, transferIntervals.count < 512 {
                        transferIntervals.append((now - previous) * 1000)
                    }
                    lastTransferTime = now
                }
                // Read + write bytes for two BGRA8 eye copies; no CPU readback.
                transferBytes &+= UInt64(leftSource.width * leftSource.height + rightSource.width * rightSource.height) * 8
            }
        }

        if matchesTarget {
            if !transferred, let readyEvent { commandBuffer.encodeWaitForEvent(readyEvent, value: acquired.producerReadyValue) }
            for index in 0..<2 {
                guard let source = sources[index] else { continue }
                let target = targets[index]
                // Opaque color and valid reverse-Z depth must be written together.
                // Without guest depth, present on a finite projection plane, as a
                // streaming VR client does. Zero-depth pixels represent no surface.
                // Clear in the drawing pass, keeping tiles resident instead of
                // storing and reloading color/depth in an empty pass first.
                // A shared attachment is cleared only by its first eye.
                let previousTargets = targets.prefix(index)
                let clearColor = !previousTargets.contains { $0.texture === target.texture && $0.slice == target.slice }
                let clearDepth = !previousTargets.contains { $0.depthTexture === target.depthTexture && $0.slice == target.slice }
                if let depth = presentationDepth(for: drawable, viewIndex: index),
                   encodeSpatialUpscale(source, to: target, depth: depth, reprojection: reprojection(for: drawable, viewIndex: index, renderTracking: renderTracking), clearColor: clearColor, clearDepth: clearDepth, on: commandBuffer) {
                    continue
                }
                clear(target, clearColor: clearColor, clearDepth: clearDepth, on: commandBuffer)
                Self.log.error("Unable to encode opaque color and valid presentation depth for eye \(index)")
            }
            if diagnoseThisFrame && LaunchDiagnostics.frameCaptureEnabled {
                if hasFrame, let source = sources[0] { encodeFrameProbe(source, label: "frame", on: commandBuffer) }
                // What the display layer holds after the copy, for a fresh guest frame ("drawable") and for a frame
                // redrawn from the cached snapshot ("snapshot"). Most presented frames are the latter, because the guest
                // submits at a lower rate than the display refreshes.
                let target = targets[0]
                encodeFrameProbe(EyeSource(texture: target.texture, slice: target.slice, x: target.originX, y: target.originY,
                                           width: Int(target.width), height: Int(target.height)),
                                 label: hasFrame ? "drawable" : "snapshot", on: commandBuffer)
            }
        } else {
            // No valid guest frame or matching owned snapshot: clear output.
            // Reused snapshots are real prior colors, not generated game frames.
            for target in targets {
                clear(target, on: commandBuffer)
            }
        }

        if isNewGuestFrame && matchesTarget && !transferred, let leftSource, let rightSource {
            _ = cacheEyes([leftSource, rightSource], generation: producerTargets.generation, tracking: renderTracking, on: commandBuffer)
        }
        drawable.encodePresent(commandBuffer: commandBuffer)
        // Keep producer images alive until their last GPU read: the owned
        // copy on the fast path, or presentation on the allocation-failure fallback.
        let leaseAddress = acquired.lease.map { UInt(bitPattern: $0) }
        commandBuffer.addCompletedHandler { completed in
            if let error = completed.error {
                Self.log.error("Presentation GPU command failed: \(String(describing: error), privacy: .public)")
                LaunchLogFile.append("compositor", "Presentation GPU command failed: \(error)")
            }
        }
        if let leaseAddress {
            leaseCompletionBuffer.addCompletedHandler { _ in
                wvr_compositor_release_acquired_frame_v1(UnsafeMutableRawPointer(bitPattern: leaseAddress))
            }
        }
        // Both buffers must be committed in order after installing callbacks.
        if transferred { leaseCompletionBuffer.commit() }
        commandBuffer.commit()
        if LaunchDiagnostics.enabled && consumeGuestFrame {
            presentationCount &+= 1
            encodeMilliseconds += (CACurrentMediaTime() - encodeStartedAt) * 1000
            let elapsed = CACurrentMediaTime() - performanceStartedAt
            if elapsed >= 5 {
                let intervals = transferIntervals.sorted()
                let median = intervals.isEmpty ? 0 : intervals[intervals.count / 2]
                let p95 = intervals.isEmpty ? 0 : intervals[(intervals.count - 1) * 95 / 100]
                LaunchLogFile.append("render-performance", String(format:
                    "displayFPS=%.1f transferFPS=%.1f snapshotReadWriteMiBps=%.1f meanCPUEncodeMs=%.3f newFrameMedianMs=%.3f newFrameP95Ms=%.3f",
                    Double(presentationCount) / elapsed, Double(transferCount) / elapsed,
                    Double(transferBytes) / elapsed / 1048576,
                    encodeMilliseconds / Double(max(1, presentationCount)), median, p95))
                performanceStartedAt = CACurrentMediaTime()
                presentationCount = 0
                transferCount = 0
                transferIntervals.removeAll(keepingCapacity: true)
                transferBytes = 0
                encodeMilliseconds = 0
            }
        }
    }


    private var probeCount = 0
    private var anchorFound = 0, anchorMissing = 0, anchorTracked = 0
    private var lastHeadPosition = SIMD3<Float>(0, 0, 0)

    /// Diagnostics only: copies the whole left-eye region the guest submitted into a shared buffer, reports how much
    /// of it is lit and how opaque, and saves it as a PNG (a handful of rotating files in Documents) so what the guest
    /// actually drew can be looked at without a headset.
    private func encodeFrameProbe(_ source: EyeSource, label: String, on commandBuffer: any MTLCommandBuffer) {
        let width = source.width, height = source.height, bytesPerRow = width * 4
        guard width > 0, height > 0,
              let buffer = layerRenderer.device.makeBuffer(length: bytesPerRow * height, options: .storageModeShared),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.copy(from: source.texture, sourceSlice: source.slice, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: source.x, y: source.y, z: 0), sourceSize: MTLSize(width: width, height: height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: bytesPerRow, destinationBytesPerImage: bytesPerRow * height)
        blit.endEncoding()
        probeCount += 1
        let index = probeCount
        commandBuffer.addCompletedHandler { _ in
            let bytes = buffer.contents().bindMemory(to: UInt8.self, capacity: bytesPerRow * height)
            var lit = 0, bright = 0, alphaSum = 0, maxRGB = 0
            var sums = [0, 0, 0]
            let stride = 7
            var sampled = 0
            var y = 0
            while y < height {
                var x = 0
                while x < width {
                    let o = y * bytesPerRow + x * 4
                    let b = Int(bytes[o]), g = Int(bytes[o + 1]), r = Int(bytes[o + 2]), a = Int(bytes[o + 3])
                    let m = max(r, max(g, b))
                    if m > 8 { lit += 1 }
                    if m > 64 { bright += 1 }
                    maxRGB = max(maxRGB, m); alphaSum += a
                    sums[0] += b; sums[1] += g; sums[2] += r
                    sampled += 1
                    x += stride
                }
                y += stride
            }
            let n = max(1, sampled)
            LaunchLogFile.append("compositor", "\(label) probe #\(index) (left eye \(width)x\(height)): litPixels(>8)=\(lit * 100 / n)% bright(>64)=\(bright * 100 / n)% maxRGB=\(maxRGB) meanBGR=\(sums.map { $0 / n }) meanAlpha=\(alphaSum / n)")
            if index % 3 == 1, let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
               let provider = CGDataProvider(data: Data(bytes: bytes, count: bytesPerRow * height) as CFData),
               let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                   space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                                   provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
               let destination = CGImageDestinationCreateWithURL(documents.appendingPathComponent("\(label)-probe-\((index / 3) % 4).png") as CFURL,
                                                                  "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(destination, image, nil)
                CGImageDestinationFinalize(destination)
            }
        }
    }

    private func cacheEyes(_ sources: [EyeSource], generation: UInt64,
                           tracking: WVRFrameTrackingV1?, on commandBuffer: any MTLCommandBuffer) -> Bool {
        var snapshots = lastEyeSnapshots
        let canReuse = snapshots.count == sources.count && sources.indices.allSatisfy {
            snapshots[$0].width == sources[$0].width && snapshots[$0].height == sources[$0].height &&
                snapshots[$0].pixelFormat == sources[$0].texture.pixelFormat
        }
        if !canReuse {
            snapshots.removeAll()
            for source in sources {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: source.texture.pixelFormat, width: source.width, height: source.height, mipmapped: false)
                descriptor.storageMode = .private
                descriptor.usage = [.shaderRead]
                guard let texture = layerRenderer.device.makeTexture(descriptor: descriptor) else {
                    lastEyeSnapshots.removeAll()
                    snapshotGeneration = 0
                    return false
                }
                snapshots.append(texture)
            }
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return false }
        for index in sources.indices {
            blit.copy(from: sources[index].texture, sourceSlice: sources[index].slice, sourceLevel: 0,
                      sourceOrigin: MTLOrigin(x: sources[index].x, y: sources[index].y, z: 0),
                      sourceSize: MTLSize(width: sources[index].width, height: sources[index].height, depth: 1),
                      to: snapshots[index], destinationSlice: 0, destinationLevel: 0,
                      destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        }
        blit.endEncoding()
        lastEyeSnapshots = snapshots
        snapshotGeneration = generation
        snapshotTracking = tracking
        return true
    }

    private func spatialPipeline(for format: MTLPixelFormat, depthFormat: MTLPixelFormat, sourceIsArray: Bool) -> (any MTLRenderPipelineState)? {
        let key = (format.rawValue << 16) | (depthFormat.rawValue << 1) | (sourceIsArray ? 1 : 0)
        if let cached = spatialPipelines[key] { return cached }
        guard let spatialLibrary,
              let vertex = spatialLibrary.makeFunction(name: "wvr_spatial_vertex"),
              let fragment = spatialLibrary.makeFunction(
                name: sourceIsArray ? "wvr_spatial_array_fragment" : "wvr_spatial_fragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = format
        descriptor.depthAttachmentPixelFormat = depthFormat
        guard let pipeline = try? layerRenderer.device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }
        spatialPipelines[key] = pipeline
        return pipeline
    }

    private func encodeSpatialUpscale(
        _ source: EyeSource,
        to target: EyeTarget,
        depth: Float,
        reprojection: simd_float4x4,
        clearColor: Bool,
        clearDepth: Bool,
        on commandBuffer: any MTLCommandBuffer
    ) -> Bool {
        let isArray = source.texture.textureType == .type2DArray
        guard source.width > 0, source.height > 0,
              let pipeline = spatialPipeline(for: target.texture.pixelFormat, depthFormat: target.depthTexture.pixelFormat, sourceIsArray: isArray),
              let spatialSampler,
              let presentationDepthState,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: {
                  let pass = MTLRenderPassDescriptor()
                  let attachment = pass.colorAttachments[0]
                  attachment?.texture = target.texture
                  attachment?.slice = target.slice
                  attachment?.level = 0
                  attachment?.loadAction = clearColor ? .clear : .load
                  attachment?.clearColor = MTLClearColorMake(0, 0, 0, 1)
                  attachment?.storeAction = .store
                  pass.depthAttachment.texture = target.depthTexture
                  pass.depthAttachment.slice = target.slice
                  pass.depthAttachment.loadAction = clearDepth ? .clear : .load
                  pass.depthAttachment.clearDepth = 0
                  pass.depthAttachment.storeAction = .store
                  return pass
              }())
        else { return false }

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(presentationDepthState)
        encoder.setViewport(MTLViewport(
            originX: Double(target.originX),
            originY: Double(target.originY),
            width: Double(target.width),
            height: Double(target.height),
            znear: 0.0,
            zfar: 1.0
        ))
        encoder.setFragmentTexture(source.texture, index: 0)
        encoder.setFragmentSamplerState(spatialSampler, index: 0)
        var region = WVRSpatialSourceUniform(
            origin: SIMD2<Float>(Float(source.x), Float(source.y)),
            extent: SIMD2<Float>(Float(source.width), Float(source.height)),
            slice: UInt32(source.slice), padding: 0, presentationDepth: depth, reserved: 0, sourceFromDestinationClip: reprojection)
        withUnsafeBytes(of: &region) { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        return true
    }

    private func clear(_ target: EyeTarget, clearColor: Bool = true, clearDepth: Bool = true, on commandBuffer: any MTLCommandBuffer) {
        let descriptor = MTLRenderPassDescriptor()
        let attachment = descriptor.colorAttachments[0]
        attachment?.texture = target.texture
        attachment?.slice = target.slice
        attachment?.level = 0
        attachment?.loadAction = clearColor ? .clear : .load
        attachment?.storeAction = .store
        attachment?.clearColor = MTLClearColorMake(0, 0, 0, 1)
        descriptor.depthAttachment.texture = target.depthTexture
        descriptor.depthAttachment.slice = target.slice
        descriptor.depthAttachment.loadAction = clearDepth ? .clear : .load
        descriptor.depthAttachment.storeAction = .store
        descriptor.depthAttachment.clearDepth = 0
        commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
    }

    private func timestampSeconds(_ instant: LayerRenderer.Clock.Instant) -> TimeInterval {
        let duration = LayerRenderer.Clock.Instant.epoch.duration(to: instant).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1.0e18
    }

    private func matrix<T>(from value: T) -> simd_float4x4 {
        let v = withUnsafeBytes(of: value) { Array($0.bindMemory(to: Float.self)) }
        return simd_float4x4(columns: (SIMD4(v[0], v[1], v[2], v[3]), SIMD4(v[4], v[5], v[6], v[7]),
                                      SIMD4(v[8], v[9], v[10], v[11]), SIMD4(v[12], v[13], v[14], v[15])))
    }

    private func reprojection(for drawable: LayerRenderer.Drawable, viewIndex: Int,
                              renderTracking: WVRFrameTrackingV1?) -> simd_float4x4 {
        guard let tracking = renderTracking, let currentAnchor = drawable.deviceAnchor else { return matrix_identity_float4x4 }
        let renderedEye = viewIndex == 0 ? matrix(from: tracking.deviceFromEye.0) : matrix(from: tracking.deviceFromEye.1)
        let renderedProjection = viewIndex == 0 ? matrix(from: tracking.projection.0) : matrix(from: tracking.projection.1)
        let originFromRenderedEye = matrix(from: tracking.originFromDevice) * renderedEye
        let originFromCurrentEye = currentAnchor.originFromAnchorTransform * drawable.views[viewIndex].transform
        var renderedEyeFromCurrentEye = originFromRenderedEye.inverse * originFromCurrentEye
        // Rotational timewarp is exact for color-only stereo. Translation is
        // supplied by fresh guest frames; synthesizing per-pixel parallax without
        // scene depth would distort nearby objects.
        renderedEyeFromCurrentEye.columns.3 = SIMD4<Float>(0, 0, 0, 1)
        let currentProjection = drawable.computeProjection(convention: .rightUpBack, viewIndex: viewIndex)
        return renderedProjection * renderedEyeFromCurrentEye * currentProjection.inverse
    }

    private func presentationDepth(for drawable: LayerRenderer.Drawable, viewIndex: Int) -> Float? {
        // Like ALVR's color-only video plane, keep synthetic depth far away.
        // A one-metre plane causes system positional reprojection to drag the
        // image like a nearby screen. Real scene translation comes from the
        // guest's fresh views until it supplies per-pixel composition depth.
        let range = drawable.depthRange
        let distance = max(range.y * 2, min(500, range.x * 0.5))
        guard range.y.isFinite, range.y > 0, range.x > distance else { return nil }
        let projection = drawable.computeProjection(convention: .rightUpBack, viewIndex: viewIndex)
        let clip = projection * SIMD4<Float>(0, 0, -distance, 1)
        let depth = clip.z / clip.w
        return depth.isFinite && depth > 0 && depth <= 1 ? depth : nil
    }

    private func appendMatrix(_ matrix: simd_float4x4, to values: inout [Float]) {
        values.append(contentsOf: matrixValues(matrix))
    }

    private func matrixValues(_ matrix: simd_float4x4) -> [Float] {
        [
            matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z, matrix.columns.0.w,
            matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z, matrix.columns.1.w,
            matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z, matrix.columns.2.w,
            matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z, matrix.columns.3.w
        ]
    }
}

@available(visionOS 1.0, *)
private struct EyeTarget {
    let texture: any MTLTexture
    let depthTexture: any MTLTexture
    let slice: Int
    let originX: Int
    let originY: Int
    let width: UInt32
    let height: UInt32
    let pixelFormat: UInt32
}

@available(visionOS 1.0, *)
private struct EyeSource {
    let texture: any MTLTexture
    let slice: Int
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

private struct WVRSpatialSourceUniform {
    var origin: SIMD2<Float>
    var extent: SIMD2<Float>
    var slice: UInt32
    var padding: UInt32
    var presentationDepth: Float
    var reserved: Float
    var sourceFromDestinationClip: simd_float4x4
}
