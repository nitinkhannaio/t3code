import AppKit

/// Shared, deliberately inert lock-screen window configuration: never key, never moved, on every space.
private func configureInert(_ panel: NSPanel) {
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.isMovable = false
    panel.isMovableByWindowBackground = false
    panel.isExcludedFromWindowsMenu = true
    panel.animationBehavior = .none
    panel.becomesKeyOnlyIfNeeded = true
    panel.acceptsMouseMovedEvents = false
    panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    panel.level = .statusBar
    panel.canBecomeVisibleWithoutLogin = true
}

/// Read-only, click-through panel that can never become key or main. It never takes an event
/// (`ignoresMouseEvents` for its whole life), so its transparent max frame eats nothing.
final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    let card: CardView

    init(frame: CGRect, appearance: CardAppearance) {
        card = CardView(appearance: appearance)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureInert(self)
        ignoresMouseEvents = true
        // The panel keeps its tested max frame; only the glass card inside is fitted to the content.
        let container = NSView(frame: CGRect(origin: .zero, size: frame.size))
        container.addSubview(card)
        card.frame = container.bounds
        contentView = container
    }

    func update(_ plan: CardPlan) {
        card.update(plan)
        card.setRowAlphas { $0 < plan.shownRows ? 1 : 0 }
        setCardHeight(plan.height)
    }

    /// Bottom-pinned card at `height` (the panel frame itself never changes).
    func setCardHeight(_ height: CGFloat) {
        let bounds = contentView?.bounds ?? CGRect(origin: .zero, size: frame.size)
        card.frame = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: min(max(height, 0), bounds.height))
        card.layoutSubtreeIfNeeded()
    }
}

/// The only interactive surface, one level above the card. Never key or main, non-activating; drops every event
/// class except the left button; starts disarmed (ordered out, ignoresMouseEvents = true). Its frame is the card
/// panel's and is never resized while locked: on the lock screen the window server did not follow setFrame for it
/// (macOS 26.5, three displays). Only the painted card's rect is drawn and hit; the rest is alpha 0 and clicks pass.
final class CardHitPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    let hitView: CardHitView

    init(frame: CGRect, appearance: CardAppearance, cardLevel: NSWindow.Level) {
        hitView = CardHitView(frame: CGRect(origin: .zero, size: frame.size), appearance: appearance)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureInert(self)
        level = NSWindow.Level(rawValue: cardLevel.rawValue + 1)
        ignoresMouseEvents = true
        contentView = hitView
    }

    var isArmed: Bool { isVisible && !ignoresMouseEvents }

    /// The clickable screen rect: the painted card. Called only between frames the gate knows about.
    private(set) var activeFrame: CGRect = .zero

    func place(_ rect: CGRect) {
        guard activeFrame != rect else { return }
        activeFrame = rect
        hitView.activeRect = rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
        if isVisible { hitView.display() }
    }

    /// Follows the card panel to a new screen layout. Only while hidden, like the card panel itself.
    func setPanelFrame(_ panelFrame: CGRect) {
        setFrame(panelFrame, display: false)
        hitView.frame = CGRect(origin: .zero, size: panelFrame.size)
        let active = activeFrame
        activeFrame = .zero
        place(active)
    }

    func arm() {
        hitView.reset()
        ignoresMouseEvents = false
        orderFrontRegardless()
    }

    func disarm() {
        ignoresMouseEvents = true
        hitView.reset()
        orderOut(nil)
    }

    /// Every non-left-button input class is dropped before AppKit dispatches it.
    static let droppedTypes: Set<NSEvent.EventType> = [
        .keyDown, .keyUp, .flagsChanged, .scrollWheel, .rightMouseDown, .rightMouseUp, .rightMouseDragged,
        .otherMouseDown, .otherMouseUp, .otherMouseDragged, .mouseMoved, .mouseEntered, .mouseExited,
        .magnify, .swipe, .rotate, .beginGesture, .endGesture, .smartMagnify, .pressure, .tabletPoint, .tabletProximity,
    ]

    /// Modifiers that make a press "not plain". Caps Lock is a latched state, not a held key, so it is allowed.
    static let blockingModifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .function]

    var onDroppedPointer: (() -> Void)?

    override func sendEvent(_ event: NSEvent) {
        if Self.droppedTypes.contains(event.type) {
            if [.rightMouseDown, .otherMouseDown].contains(event.type) { onDroppedPointer?() }
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }
}

/// Plain drawn surface (no NSControl, never first responder). Non-zero alpha only inside the rounded hit shape so
/// there is something for the window server to hit; outside the shape hitTest returns nil.
final class CardHitView: NSView {
    static let collapsedAccessibilityLabel = "Show additional sessions"
    static let expandedAccessibilityLabel = "Hide additional sessions"

    private var palette: CardPalette
    var cardAppearance: CardAppearance {
        didSet {
            palette = .forAppearance(cardAppearance)
            needsDisplay = true
        }
    }
    private(set) var pressed = false { didSet { needsDisplay = true } }
    var expanded = false {
        didSet {
            applyAccessibilityLabel()
            setAccessibilityExpanded(expanded)
        }
    }
    /// VoiceOver names in the app's language, from the card's copy.
    var accessibilityLabels = (collapsed: CardHitView.collapsedAccessibilityLabel, expanded: CardHitView.expandedAccessibilityLabel) {
        didSet { applyAccessibilityLabel() }
    }

    private func applyAccessibilityLabel() {
        setAccessibilityLabel(expanded ? accessibilityLabels.expanded : accessibilityLabels.collapsed)
    }
    /// Raw pointer samples for the gate; the runner adds the fresh context. Phase name only for evidence logs.
    var onPointer: ((PointerSample) -> Void)?
    /// The painted card in this view's space; nothing outside it is drawn or hit.
    var activeRect: CGRect = .zero { didSet { needsDisplay = true } }

    init(frame: CGRect, appearance: CardAppearance) {
        palette = .forAppearance(appearance)
        cardAppearance = appearance
        super.init(frame: frame)
        self.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(Self.collapsedAccessibilityLabel)
        setAccessibilityExpanded(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }
    override var needsPanelToBecomeKey: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    /// The app is never active, so without this the first click would be swallowed.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func insideShape(_ pointInView: NSPoint) -> Bool {
        CardHitShape.contains(CGPoint(x: pointInView.x - activeRect.minX, y: pointInView.y - activeRect.minY), size: activeRect.size)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's space; this view is the content view, so that is the window's content space.
        insideShape(convert(point, from: superview)) ? self : nil
    }

    func reset() {
        tracking = false
        pressed = false
    }

    func hitPath() -> NSBezierPath {
        let r = activeRect.insetBy(dx: InteractionConfig.hitInset, dy: InteractionConfig.hitInset)
        let k = min(InteractionConfig.hitCornerRadius, r.width / 2, r.height / 2)
        return NSBezierPath(roundedRect: r, xRadius: k, yRadius: k)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard activeRect.width > 2 * InteractionConfig.hitInset, activeRect.height > 2 * InteractionConfig.hitInset else { return }
        palette.primary.withAlphaComponent(pressed ? InteractionConfig.pressedFillAlpha : InteractionConfig.idleFillAlpha).setFill()
        hitPath().fill()
    }

    static func isPlain(_ event: NSEvent) -> Bool {
        event.modifierFlags.intersection(CardHitPanel.blockingModifiers).isEmpty
    }

    private var tracking = false

    override func mouseDown(with event: NSEvent) {
        let inside = insideShape(convert(event.locationInWindow, from: nil))
        let sample = PointerSample(kind: .leftDown, plain: Self.isPlain(event), insideShape: inside)
        tracking = sample.plain && inside
        pressed = tracking
        onPointer?(sample)
    }

    override func mouseDragged(with event: NSEvent) {
        if tracking { pressed = insideShape(convert(event.locationInWindow, from: nil)) }
    }

    override func mouseUp(with event: NSEvent) {
        let inside = insideShape(convert(event.locationInWindow, from: nil))
        tracking = false
        pressed = false
        onPointer?(PointerSample(kind: .leftUp, plain: Self.isPlain(event), insideShape: inside))
    }

    override func rightMouseDown(with event: NSEvent) { onPointer?(PointerSample(kind: .other, plain: false, insideShape: false)) }
    override func otherMouseDown(with event: NSEvent) { onPointer?(PointerSample(kind: .other, plain: false, insideShape: false)) }
    override func scrollWheel(with event: NSEvent) {}
    override func keyDown(with event: NSEvent) {}
}
