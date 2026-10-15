// Compile with the production router using swiftc -O; no game or headset is run.
@main
struct DrawableRoutingTests {
    struct Drawable { let name: String; let display: Bool; let usable: Bool }
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fatalError(message) }
    }
    static func main() {
        let display = Drawable(name: "headset", display: true, usable: true)
        let capture = Drawable(name: "monocular-capture", display: false, usable: false)
        let stereoCapture = Drawable(name: "stereo-capture", display: false, usable: true)
        for drawables in [[display], [display, capture], [capture, display], [stereoCapture, display, capture]] {
            var targets = false, tracking = false, invalidations = 0, consumed = 0
            var rendered: [String] = []
            WindowsVRDrawableRouter.renderFrame(drawables, isDisplay: { $0.display }, prepareDisplay: {
                check($0.display, "Capture must never publish/reset headset targets")
                targets = true; tracking = true; return $0.usable
            }, render: { drawable, consume in
                check(targets && tracking, "Capture must not erase headset readiness")
                if consume { consumed += 1; check(drawable.display, "Capture consumed a guest lease") }
                rendered.append(drawable.name)
            }, invalidateDisplay: { invalidations += 1; targets = false; tracking = false })
            check(invalidations == 0 && consumed == 1, "Stereo readiness must survive all auxiliary drawables")
            check(rendered.first == "headset", "Display must publish its snapshot before capture")
            check(rendered.count == drawables.count, "Every queried drawable must be presented")
        }
        for drawables in [[capture], [Drawable(name: "invalid-display", display: true, usable: false), capture], []] {
            var invalidations = 0, rendered = 0
            WindowsVRDrawableRouter.renderFrame(drawables, isDisplay: { $0.display }, prepareDisplay: { $0.usable }, render: { _, consume in
                check(!consume, "Missing/invalid display must not consume a guest frame")
                rendered += 1
            }, invalidateDisplay: { invalidations += 1 })
            check(invalidations == 1, "Missing/invalid display must invalidate readiness once")
            check(rendered == drawables.count, "Invalid frame must still present its queried drawables")
        }
        print("PASS: display/capture ordering, stable readiness, one guest lease, invalidation and balanced drawable presentation")
    }
}
