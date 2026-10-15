/// A frame can contain both headset and capture drawables. Only the headset
/// owns guest target dimensions, tracking and consumption of a fresh frame.
enum WindowsVRDrawableRouter {
    static func renderFrame<Drawable>(
        _ drawables: [Drawable],
        isDisplay: (Drawable) -> Bool,
        prepareDisplay: (Drawable) -> Bool,
        render: (Drawable, Bool) -> Void,
        invalidateDisplay: () -> Void
    ) {
        guard let displayIndex = drawables.firstIndex(where: isDisplay) else {
            invalidateDisplay()
            for drawable in drawables { render(drawable, false) }
            return
        }
        let display = drawables[displayIndex]
        let ready = prepareDisplay(display)
        if !ready { invalidateDisplay() }
        // Produce the owned stereo snapshot before capture reads it, regardless
        // of the order in which CompositorServices returned its drawables.
        render(display, ready)
        for index in drawables.indices where index != displayIndex {
            render(drawables[index], false)
        }
    }
}
