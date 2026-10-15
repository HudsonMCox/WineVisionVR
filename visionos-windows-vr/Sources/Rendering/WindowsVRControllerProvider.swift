import ARKit
import CoreHaptics
import GameController
import QuartzCore
import simd

/// visionOS accessory tracking and GameController input adapter for the native
/// OpenVR/OpenXR-facing ABI. This only reports sensors/actions; it does not
/// invent poses or mark absent controllers as tracked.
@available(visionOS 27.0, *)
final class WindowsVRControllerProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var accessoryProvider: AccessoryTrackingProvider?
    private var anchorsByRole: [UInt32: AccessoryAnchor] = [:]
    private var controllersByRole: [UInt32: any GCDevice] = [:]
    private var hapticEnginesByRole: [UInt32: CHHapticEngine] = [:]
    private var hapticPlayersByRole: [UInt32: any CHHapticPatternPlayer] = [:]
    private var anchorUpdatesTask: Task<Void, Never>?
    private var trackingGeneration: UInt64 = 0
    private var discoveryTask: Task<Void, Never>?
    private var lastDiagnosticByRole: [UInt32: TimeInterval] = [:]

    func configure(authorized: Bool) async -> [any DataProvider] {
        guard authorized, AccessoryTrackingProvider.isSupported else {
            reset()
            return []
        }

        let generation = lock.withLock {
            trackingGeneration &+= 1
            return trackingGeneration
        }

        let (accessories, devices) = await discoverAccessories()
        lock.withLock { controllersByRole = devices }
        let provider = AccessoryTrackingProvider(accessories: accessories)
        store(provider)
        anchorUpdatesTask = Task { [weak self, provider, generation] in
            for await update in provider.anchorUpdates {
                guard let self, self.isCurrentTrackingGeneration(generation) else { return }
                switch update.event {
                case .added, .updated:
                    guard let role = Self.role(for: update.anchor.accessory.inherentChirality) else { continue }
                    self.store(update.anchor, for: role, generation: generation)
                case .removed:
                    guard let role = Self.role(for: update.anchor.accessory.inherentChirality) else { continue }
                    self.removeAnchor(for: role, generation: generation)
                    self.publishUnavailable(role: role)
                @unknown default:
                    continue
                }
            }
        }
        discoveryTask = Task { [weak self, provider, generation] in
            var known = devices.mapValues { ObjectIdentifier($0 as AnyObject) }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isCurrentTrackingGeneration(generation) else { return }
                let current = Self.connectedDevices()
                let identifiers = Set(current.map { ObjectIdentifier($0 as AnyObject) })
                guard identifiers != Set(known.values) else { continue }
                let (accessories, devices) = await self.discoverAccessories()
                do {
                    try await provider.updateAccessories(accessories)
                    guard self.isCurrentTrackingGeneration(generation) else { return }
                    let retiredEngines = self.lock.withLock {
                        var engines: [CHHapticEngine] = []
                        for (role, oldDevice) in self.controllersByRole {
                            let changed = devices[role].map {
                                ObjectIdentifier($0 as AnyObject) != ObjectIdentifier(oldDevice as AnyObject)
                            } ?? true
                            if changed {
                                if let engine = self.hapticEnginesByRole.removeValue(forKey: role) { engines.append(engine) }
                                self.hapticPlayersByRole.removeValue(forKey: role)
                            }
                        }
                        self.controllersByRole = devices
                        self.anchorsByRole = self.anchorsByRole.filter { devices[$0.key] != nil }
                        return engines
                    }
                    retiredEngines.forEach { $0.stop() }
                    known = devices.mapValues { ObjectIdentifier($0 as AnyObject) }
                } catch {
                    LaunchLogFile.append("controllers", "Accessory update failed: \(error)")
                }
            }
        }
        return [provider]
    }

    /// Clears all cached device samples and stops controller haptics when the
    /// compositor is paused or invalidated. Fresh anchor updates repopulate the
    /// cache after tracking is restarted.
    func reset() {
        discoveryTask?.cancel()
        discoveryTask = nil
        let (updatesTask, engines) = lock.withLock {
            let task = anchorUpdatesTask
            anchorUpdatesTask = nil
            trackingGeneration &+= 1
            let engines = Array(hapticEnginesByRole.values)
            hapticEnginesByRole.removeAll()
            hapticPlayersByRole.removeAll()
            anchorsByRole.removeAll()
            controllersByRole.removeAll()
            accessoryProvider = nil
            return (task, engines)
        }
        updatesTask?.cancel()
        engines.forEach { $0.stop() }
        publishUnavailableState()
    }

    func publishUnavailableState() {
        publishUnavailable(role: 0)
        publishUnavailable(role: 1)
    }

    /// Called once for each compositor frame using its predicted ARKit time.
    /// Input snapshots are latest-state samples; the ABI does not queue stale
    /// controller input behind video frames.
    func publishPredictedState(at timestamp: TimeInterval) {
        for role: UInt32 in 0...1 {
            publishState(role: role, timestamp: timestamp)
            drainHaptic(role: role)
        }
    }

    private func publishState(role: UInt32, timestamp: TimeInterval) {
        let (provider, anchor, controller) = lock.withLock {
            (accessoryProvider, anchorsByRole[role], controllersByRole[role])
        }

        let predictedAnchor: AccessoryAnchor?
        if let provider, let anchor {
            predictedAnchor = provider.predictAnchor(for: anchor, at: timestamp)
        } else {
            predictedAnchor = nil
        }

        var buttons: UInt64 = 0
        var trigger: Float = 0
        var grip: Float = 0
        var stickX: Float = 0
        var stickY: Float = 0
        if let controller, let input = Self.input(for: controller) {
            // Poll a complete current state. An empty transition queue means no
            // changes; it does not mean held buttons have been released.
            let snapshot = input.capture()
            do {
                let inputButtons = snapshot.buttons
                let inputAxes = snapshot.axes
                let inputDpads = snapshot.dpads
                if pressed({ inputButtons[$0]?.pressedInput.isPressed == true }, ["Primary Button", "Button A", "Button X"]) { buttons |= 1 << 0 }
                if pressed({ inputButtons[$0]?.pressedInput.isPressed == true }, ["Secondary Button", "Button B", "Button Y"]) { buttons |= 1 << 1 }
                if pressed({ inputButtons[$0]?.pressedInput.isPressed == true }, [GCInputButtonMenu, GCInputButtonOptions, GCInputButtonShare]) { buttons |= 1 << 2 }
                if pressed({ inputButtons[$0]?.pressedInput.isPressed == true }, ["Thumbstick Button", "Left Thumbstick Button", "Right Thumbstick Button"]) { buttons |= 1 << 3 }
                if pressed({ inputButtons[$0]?.pressedInput.isPressed == true }, ["Trigger", "Left Trigger", "Right Trigger"]) { buttons |= 1 << 4 }
                if pressed({ inputButtons[$0]?.pressedInput.isPressed == true }, ["Grip Button", "Grip", "Tip", "Left Shoulder", "Right Shoulder"]) { buttons |= 1 << 5 }
                if pressed({ inputButtons[$0]?.touchedInput?.isTouched == true }, ["Trigger", "Left Trigger", "Right Trigger"]) { buttons |= 1 << 6 }
                if pressed({ inputButtons[$0]?.touchedInput?.isTouched == true }, ["Grip Button", "Grip", "Tip", "Left Shoulder", "Right Shoulder"]) { buttons |= 1 << 7 }

                trigger = scalar({ inputButtons[$0]?.pressedInput.value }, ["Trigger", "Left Trigger", "Right Trigger"])
                grip = scalar({ inputButtons[$0]?.pressedInput.value }, ["Grip Button", "Grip", "Tip", "Left Shoulder", "Right Shoulder"])
                if let stick = inputDpads["Thumbstick"] ?? inputDpads["Left Thumbstick"] ?? inputDpads["Right Thumbstick"] {
                    stickX = stick.xAxis.value
                    stickY = stick.yAxis.value
                } else {
                    stickX = scalar({ inputAxes[$0]?.absoluteInput?.value }, ["Thumbstick X Axis", "Left Thumbstick X Axis", "Right Thumbstick X Axis"])
                    stickY = scalar({ inputAxes[$0]?.absoluteInput?.value }, ["Thumbstick Y Axis", "Left Thumbstick Y Axis", "Right Thumbstick Y Axis"])
                }
            }
        }

        let tracked = predictedAnchor?.isTracked == true
        var matrix = tracked ? predictedAnchor!.originFromAnchorTransform : matrix_identity_float4x4
        let flags: UInt32 = (tracked ? 0b011 : 0) | (controller == nil ? 0 : 0b100)
        if LaunchDiagnostics.enabled && timestamp - (lastDiagnosticByRole[role] ?? 0) >= 5 {
            lastDiagnosticByRole[role] = timestamp
            LaunchLogFile.append("controllers", "role=\(role) connected=\(controller != nil) tracked=\(tracked) flags=\(flags) buttons=\(buttons) trigger=\(trigger) grip=\(grip) stick=\(stickX),\(stickY)")
        }
        withUnsafeBytes(of: &matrix) { bytes in
            let buffer = bytes.bindMemory(to: Float.self)
            _ = wvr_compositor_publish_controller_state_v1(
                role, flags, UInt64(max(0, timestamp * 1.0e9)), buffer.baseAddress,
                buttons, trigger, grip, stickX, stickY
            )
        }
    }

    private func drainHaptic(role: UInt32) {
        var request = WVRHapticRequestV1()
        request.structSize = UInt32(MemoryLayout<WVRHapticRequestV1>.size)
        guard wvr_compositor_take_haptic_v1(role, &request) == 0 else { return }

        // OpenXR replacement and stop requests apply to the vibration already
        // playing on this hand. Keep its handle so pulses cannot accumulate.
        let (controller, existingEngine, previousPlayer, generation) = lock.withLock {
            (controllersByRole[role], hapticEnginesByRole[role],
             hapticPlayersByRole.removeValue(forKey: role), trackingGeneration)
        }
        do { try previousPlayer?.stop(atTime: CHHapticTimeImmediate) }
        catch { LaunchLogFile.append("haptics", "Stop failed role=\(role): \(error)") }
        guard request.amplitude > 0, request.durationSeconds > 0,
              let controller, let haptics = Self.haptics(for: controller) else { return }

        let locality = role == 0 ? GCHapticsLocality.leftHandle : GCHapticsLocality.rightHandle
        guard let engine = existingEngine ?? haptics.createEngine(withLocality: locality)
                ?? haptics.createEngine(withLocality: GCHapticsLocality.all) else { return }
        if existingEngine == nil {
            // Core Haptics invalidates players on reset. Drop both handles and
            // create a fresh engine for the next game request after interruption.
            engine.resetHandler = { [weak self, weak engine] in
                guard let engine else { return }
                self?.invalidateHaptics(role: role, engine: engine)
            }
            engine.stoppedHandler = { [weak self, weak engine] _ in
                guard let engine else { return }
                self?.invalidateHaptics(role: role, engine: engine)
            }
        }
        do {
            try engine.start()
            let pattern = try CHHapticPattern(events: [
                CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: request.amplitude),
                    // Sharpness is perceptual, not a frequency in Hz. Use a
                    // neutral default for XR_FREQUENCY_UNSPECIFIED (zero).
                    CHHapticEventParameter(parameterID: .hapticSharpness,
                        value: request.frequencyHz == 0 ? 0.5 : min(1, request.frequencyHz / 1000))
                ], relativeTime: 0, duration: Double(request.durationSeconds))
            ], parameters: [])
            let player = try engine.makePlayer(with: pattern)
            let accepted = lock.withLock {
                guard trackingGeneration == generation,
                      let current = controllersByRole[role],
                      ObjectIdentifier(current as AnyObject) == ObjectIdentifier(controller as AnyObject) else { return false }
                hapticEnginesByRole[role] = engine
                hapticPlayersByRole[role] = player
                return true
            }
            guard accepted else { engine.stop(); return }
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            invalidateHaptics(role: role, engine: engine)
            engine.stop()
            LaunchLogFile.append("haptics", "Playback failed role=\(role): \(error)")
        }
    }

    private func invalidateHaptics(role: UInt32, engine: CHHapticEngine) {
        lock.withLock {
            guard hapticEnginesByRole[role] === engine else { return }
            hapticEnginesByRole.removeValue(forKey: role)
            hapticPlayersByRole.removeValue(forKey: role)
        }
    }

    private func publishUnavailable(role: UInt32) {
        var identity = matrix_identity_float4x4
        withUnsafeBytes(of: &identity) { bytes in
            let buffer = bytes.bindMemory(to: Float.self)
            _ = wvr_compositor_publish_controller_state_v1(role, 0, 0, buffer.baseAddress, 0, 0, 0, 0, 0)
        }
    }

    private static func connectedDevices() -> [any GCDevice] {
        var devices: [any GCDevice] = GCSpatialAccessory.spatialAccessories
        let identifiers = Set(devices.map { ObjectIdentifier($0 as AnyObject) })
        devices.append(contentsOf: GCController.controllers().filter {
            $0.productCategory == GCProductCategorySpatialController &&
                !identifiers.contains(ObjectIdentifier($0))
        })
        return devices
    }

    private func discoverAccessories() async -> ([Accessory], [UInt32: any GCDevice]) {
        var accessories: [Accessory] = []
        var devices: [UInt32: any GCDevice] = [:]
        for device in Self.connectedDevices() {
            do {
                let accessory = try await Accessory(device: device)
                guard let role = Self.role(for: accessory.inherentChirality), devices[role] == nil else { continue }
                devices[role] = device
                accessories.append(accessory)
                if let input = Self.input(for: device) {
                    let aliases = input.capture().buttons.map { $0.aliases.sorted().joined(separator: ",") }
                    LaunchLogFile.append("controllers", "role=\(role) button aliases=\(aliases)")
                }
                LaunchLogFile.append("controllers", "Discovered \(accessory.name) role=\(role) input=\(Self.input(for: device) != nil)")
            } catch {
                LaunchLogFile.append("controllers", "Accessory discovery failed: \(error)")
            }
        }
        return (accessories, devices)
    }

    private static func input(for device: any GCDevice) -> (any GCDevicePhysicalInput)? {
        if let accessory = device as? GCSpatialAccessory { return accessory.input }
        return (device as? GCController)?.input
    }

    private static func haptics(for device: any GCDevice) -> GCDeviceHaptics? {
        if let accessory = device as? GCSpatialAccessory { return accessory.haptics }
        return (device as? GCController)?.haptics
    }

    private func store(_ controller: any GCDevice, for role: UInt32) {
        lock.withLock { controllersByRole[role] = controller }
    }

    private func store(_ provider: AccessoryTrackingProvider) {
        lock.withLock { accessoryProvider = provider }
    }

    private func store(_ anchor: AccessoryAnchor, for role: UInt32, generation: UInt64) {
        lock.withLock {
            guard trackingGeneration == generation else { return }
            anchorsByRole[role] = anchor
        }
    }

    private func removeAnchor(for role: UInt32, generation: UInt64) {
        let engine: CHHapticEngine? = lock.withLock {
            guard trackingGeneration == generation else { return nil }
            anchorsByRole.removeValue(forKey: role)
            hapticPlayersByRole.removeValue(forKey: role)
            return hapticEnginesByRole.removeValue(forKey: role)
        }
        engine?.stop()
    }

    private func isCurrentTrackingGeneration(_ generation: UInt64) -> Bool {
        lock.withLock { trackingGeneration == generation }
    }

    private static func role(for chirality: Accessory.Chirality) -> UInt32? {
        switch chirality {
        case .left: 0
        case .right: 1
        default: nil
        }
    }

    private func pressed(_ read: (String) -> Bool, _ names: [String]) -> Bool {
        names.contains(where: read)
    }

    private func scalar(_ read: (String) -> Float?, _ names: [String]) -> Float {
        names.lazy.compactMap(read).first ?? 0
    }



    deinit {
        anchorUpdatesTask?.cancel()
        hapticEnginesByRole.values.forEach { $0.stop() }
    }
}
