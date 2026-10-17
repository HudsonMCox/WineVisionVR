import SwiftUI
import UIKit
import Metal
import Observation
import WindowsVRCore

@MainActor
@Observable
final class WindowsDesktopControls {
    weak var surface: WindowsDesktopSurface?
    var inputMessage: String?
    func keyboard() { surface?.toggleKeyboard() }
    func key(_ vk: Int32) { surface?.pulseKey(vk) }
    func rightClick() { surface?.rightClick() }
    func scroll(_ delta: Int32) { surface?.scroll(delta) }
    func releaseInput() { surface?.releaseInput() }
}

struct WindowsDesktopView: View {
    @Bindable var model: LauncherModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var controls = WindowsDesktopControls()

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Label(model.manifest?.title ?? L("Windows desktop", "Windows-Desktop"), systemImage: "desktopcomputer")
                    .font(.headline)
                Spacer()
                Button(L("Keyboard", "Tastatur"), systemImage: "keyboard") { controls.keyboard() }
                    .disabled(!model.hasAcceptedLaunch)
                Menu(L("Controls", "Steuerung"), systemImage: "cursorarrow") {
                    Button("Escape") { controls.key(0x1B) }
                    Button("Tab") { controls.key(0x09) }
                    Button("Enter") { controls.key(0x0D) }
                    Button(L("Right click", "Rechtsklick")) { controls.rightClick() }
                    Button(L("Scroll up", "Nach oben scrollen")) { controls.scroll(120) }
                    Button(L("Scroll down", "Nach unten scrollen")) { controls.scroll(-120) }
                }.disabled(!model.hasAcceptedLaunch)
                if model.hasAcceptedLaunch {
                    Button(role: .destructive) { Task { await model.stop() } } label: {
                        Label(L("End session", "Sitzung beenden"), systemImage: "stop.fill")
                    }.disabled(model.isStopping || model.stopRequested)
                } else {
                    Button(L("Library", "Bibliothek")) { model.hideDesktopPresentation() }
                        .disabled(model.isLaunching)
                }
            }
            if model.stopRequested || model.requiresRestart {
                ForceQuitSessionButton()
            }
            WindowsDesktopSurfaceView(model: model, controls: controls)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
                .accessibilityLabel(L("Windows app screen", "Windows-App-Anzeige"))
            HStack {
                if model.isLaunching { ProgressView() }
                Text(model.launchError ?? model.sessionStatus)
                    .font(.footnote).foregroundStyle(model.launchError == nil ? Color.secondary : Color.red)
                Spacer()
            }
            if let message = controls.inputMessage {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 480)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { controls.releaseInput() }
        }
        .onDisappear { controls.releaseInput() }
    }
}

private struct WindowsDesktopSurfaceView: UIViewRepresentable {
    let model: LauncherModel
    let controls: WindowsDesktopControls

    func makeUIView(context: Context) -> WindowsDesktopSurface {
        let view = WindowsDesktopSurface(controls: controls)
        view.didAttach = { [weak model] in model?.desktopSurfaceDidAttach() }
        view.didDetach = { [weak model] in model?.desktopSurfaceDidDetach() }
        controls.surface = view
        return view
    }

    func updateUIView(_ view: WindowsDesktopSurface, context: Context) {
        // A normal Windows app can ask to save after Alt-F4; keep that dialog usable.
        view.inputEnabled = model.hasAcceptedLaunch && !model.isStopping
    }

    static func dismantleUIView(_ view: WindowsDesktopSurface, coordinator: ()) {
        view.releaseInput()
        view.didDetach?()
        _ = winios_compositor_set_hidden(1)
    }
}

/// Hosts DXMT and the existing GDI desktop compositor in the same window rect.
@MainActor
final class WindowsDesktopSurface: UIView, UIKeyInput {
    private let metalLayer = CAMetalLayer()
    private weak var controls: WindowsDesktopControls?
    private var keysHeld: Set<Int32> = []
    private var activeTouch: UITouch?
    private var releaseButton: UInt32 = 0
    private var pointer: (Int32, Int32) = (0, 0)
    private var attached = false
    var didAttach: (() -> Void)?
    var didDetach: (() -> Void)?
    var inputEnabled = false {
        didSet { if !inputEnabled { releaseInput() } }
    }

    init(controls: WindowsDesktopControls) {
        self.controls = controls
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = true
        layer.addSublayer(metalLayer)
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.drawableSize = CGSize(width: 1024, height: 768)
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hover(_:))))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unsupported") }
    override var canBecomeFirstResponder: Bool { true }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            releaseInput()
            attached = false
            didDetach?()
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let window, bounds.width > 0, bounds.height > 0 else { return }
        metalLayer.frame = bounds
        if !attached {
            guard let device = MTLCreateSystemDefaultDevice(),
                  wvr_compositor_bind_metal_device_v1(Unmanaged.passUnretained(device as AnyObject).toOpaque()) == 0 else {
                controls?.inputMessage = L("Metal could not prepare the desktop screen.", "Metal konnte die Desktop-Anzeige nicht vorbereiten.")
                return
            }
            metalLayer.device = device
            madeira_display_set_layer(metalLayer)
            attached = true
            _ = winios_compositor_set_hidden(0)
            didAttach?()
            LaunchLogFile.append("desktop", "Desktop surface attached; Metal device bound, no immersive space required")
        }
        let rect = convert(bounds, to: window)
        winios_set_desktop_rect(0, 0, 0, 0, 0)
        winios_set_compositor_frame(rect.minX, rect.minY, rect.width, rect.height)
    }

    func toggleKeyboard() {
        guard inputEnabled else { return }
        if isFirstResponder { resignFirstResponder() } else { becomeFirstResponder() }
    }

    private func map(_ point: CGPoint) -> (Int32, Int32)? {
        guard window != nil else { return nil }
        let position = convert(point, to: window)
        var x: Int32 = 0, y: Int32 = 0
        guard winios_desktop_point_from_window(position.x, position.y, &x, &y) != 0 else { return nil }
        pointer = (x, y)
        return pointer
    }

    @objc private func hover(_ recognizer: UIHoverGestureRecognizer) {
        guard inputEnabled, let (x, y) = map(recognizer.location(in: self)) else { return }
        winios_pointer(x, y, 0x8001, 0) // absolute move
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard inputEnabled, activeTouch == nil, let touch = touches.first,
              let (x, y) = map(touch.location(in: self)) else { return }
        activeTouch = touch
        let secondary = event?.buttonMask.contains(.secondary) == true
        releaseButton = secondary ? 0x0010 : 0x0004
        winios_pointer(x, y, 0x8001 | (secondary ? 0x0008 : 0x0002), 0)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard inputEnabled, let touch = activeTouch, touches.contains(touch),
              let (x, y) = map(touch.location(in: self)) else { return }
        winios_pointer(x, y, 0x8001, 0)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        _ = map(touch.location(in: self))
        releasePointer()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { releasePointer() }

    private func releasePointer() {
        if releaseButton != 0 { winios_pointer(pointer.0, pointer.1, 0x8000 | releaseButton, 0) }
        releaseButton = 0
        activeTouch = nil
    }

    func releaseInput() {
        releasePointer()
        for key in keysHeld { winios_post_key(key, 0) }
        keysHeld.removeAll()
        resignFirstResponder()
    }

    func pulseKey(_ vk: Int32) {
        guard inputEnabled, !keysHeld.contains(vk) else { return }
        winios_post_key(vk, 1)
        winios_post_key(vk, 0)
    }

    func rightClick() {
        guard inputEnabled, activeTouch == nil else { return }
        winios_pointer(pointer.0, pointer.1, 0x8008, 0)
        winios_pointer(pointer.0, pointer.1, 0x8010, 0)
    }

    func scroll(_ delta: Int32) {
        guard inputEnabled else { return }
        winios_pointer(pointer.0, pointer.1, 0x0800, UInt32(bitPattern: delta))
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard inputEnabled else { super.pressesBegan(presses, with: event); return }
        var other: Set<UIPress> = []
        for press in presses {
            if let key = press.key, let vk = WindowsDesktopKeyboard.virtualKey(hidUsage: key.keyCode.rawValue) {
                if keysHeld.insert(vk).inserted { winios_post_key(vk, 1) }
            } else { other.insert(press) }
        }
        // Handled hardware keys bypass UIKit's text insertion, avoiding duplicates.
        if !other.isEmpty { super.pressesBegan(other, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var other: Set<UIPress> = []
        for press in presses {
            if let key = press.key, let vk = WindowsDesktopKeyboard.virtualKey(hidUsage: key.keyCode.rawValue) {
                if keysHeld.remove(vk) != nil { winios_post_key(vk, 0) }
            } else { other.insert(press) }
        }
        if !other.isEmpty { super.pressesEnded(other, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }

    var hasText: Bool { true }
    func insertText(_ text: String) {
        guard inputEnabled, keysHeld.isEmpty else { return }
        let strokes = text.map { WindowsDesktopKeyboard.stroke(for: $0) }
        guard strokes.allSatisfy({ $0 != nil }) else {
            controls?.inputMessage = L("This keyboard currently supports basic Latin characters and US punctuation.", "Diese Tastatur unterstützt derzeit lateinische Grundzeichen und US-Satzzeichen.")
            return
        }
        controls?.inputMessage = nil
        for stroke in strokes.compactMap({ $0 }) {
            if stroke.shift { winios_post_key(0x10, 1) }
            pulseKey(stroke.key)
            if stroke.shift { winios_post_key(0x10, 0) }
        }
    }
    func deleteBackward() { pulseKey(0x08) }
    var keyboardType: UIKeyboardType = .asciiCapable
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
}
