import CoreGraphics
import Foundation

// Whole-card expand/collapse. Pure (no AppKit, no window server), so every invariant is tested offscreen.

enum InteractionConfig {
    /// Expand/collapse duration when Reduce Motion is off. Reduce Motion -> 0: one final frame.
    static let duration: TimeInterval = 0.26
    /// Toggles closer together than this are ignored (one toggle per deliberate click).
    static let minToggleInterval: TimeInterval = 0.30
    /// The card layer uses a 16 pt *continuous* corner, which starts curving earlier than a circular arc of the same
    /// radius. A circular radius of 1.5x, inset 1 pt (the rim), lies entirely inside the painted shape
    /// (checked pixel-by-pixel offscreen by `interaction-check`).
    static let hitCornerRadius: CGFloat = CardMetrics.cornerRadius * 1.5
    static let hitInset: CGFloat = 1
    /// Idle fill of the hit window inside the hit shape: invisible to the eye, but non-zero alpha so it is hit.
    static let idleFillAlpha: CGFloat = 0.012
    /// Pressed feedback over the whole card: kept faint because the surface is large.
    static let pressedFillAlpha: CGFloat = 0.05
}

// MARK: Coordinate spaces

/// screen: AppKit global (y up); panel: the max panel's content view (y up); card: CardView, flipped (top-left
/// origin, y down); hit: the hit window's content view (y up); cg: Quartz global (top-left origin, y down).
enum CardCoordinates {
    static func screenToPanel(_ p: CGPoint, panel: CGRect) -> CGPoint { CGPoint(x: p.x - panel.minX, y: p.y - panel.minY) }
    static func panelToScreen(_ p: CGPoint, panel: CGRect) -> CGPoint { CGPoint(x: p.x + panel.minX, y: p.y + panel.minY) }
    /// The card is pinned to the panel's bottom edge, so panel y maps to card (flipped) y by the card height.
    static func panelToCard(_ p: CGPoint, cardHeight: CGFloat) -> CGPoint { CGPoint(x: p.x, y: cardHeight - p.y) }
    static func cardToPanel(_ p: CGPoint, cardHeight: CGFloat) -> CGPoint { CGPoint(x: p.x, y: cardHeight - p.y) }
    static func hitToScreen(_ p: CGPoint, hitFrame: CGRect) -> CGPoint { CGPoint(x: p.x + hitFrame.minX, y: p.y + hitFrame.minY) }
    static func screenToHit(_ p: CGPoint, hitFrame: CGRect) -> CGPoint { CGPoint(x: p.x - hitFrame.minX, y: p.y - hitFrame.minY) }
    static func screenToCG(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
    static func cgToScreen(_ r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

/// Rounded hit shape in a rect's own unflipped space: the rect inset by `hitInset`, corners of `hitCornerRadius`.
enum CardHitShape {
    static func contains(_ p: CGPoint, size: CGSize,
                         radius: CGFloat = InteractionConfig.hitCornerRadius, inset: CGFloat = InteractionConfig.hitInset) -> Bool {
        let r = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
        guard r.width > 0, r.height > 0, r.contains(p) else { return false }
        let k = min(radius, r.width / 2, r.height / 2)
        let cx = min(max(p.x, r.minX + k), r.maxX - k)
        let cy = min(max(p.y, r.minY + k), r.maxY - k)
        let dx = p.x - cx, dy = p.y - cy
        return dx * dx + dy * dy <= k * k
    }
}

// MARK: Geometry

/// The live card's placement for one screen. The panel frame is fixed (sized for `capacity` rows, as before); the
/// hit rect follows the painted card, never the max panel.
struct CardSurface: Equatable {
    let screen: CGRect
    let panel: CGRect
    let capacity: Int

    static func make(screen: CGRect) -> CardSurface? {
        guard let placed = CardPlacement.lockLayout(screen: screen) else { return nil }
        return CardSurface(screen: screen, panel: placed.frame, capacity: placed.rowCapacity)
    }

    /// Painted card in panel space for a (possibly mid-animation) height; bottom-pinned.
    func cardInPanel(height: CGFloat) -> CGRect {
        CGRect(x: 0, y: 0, width: panel.width, height: min(max(height, 0), panel.height))
    }

    func cardOnScreen(height: CGFloat) -> CGRect { cardInPanel(height: height).offsetBy(dx: panel.minX, dy: panel.minY) }

    /// Hit window frame (screen). While animating it is the smaller endpoint, which is painted at every frame because
    /// the card only grows or shrinks from a fixed bottom edge; otherwise the card as drawn.
    func hitFrame(currentHeight: CGFloat, animation: ExpandAnimation? = nil) -> CGRect {
        let h = animation.map { min($0.fromHeight, $0.toHeight) } ?? currentHeight
        return cardOnScreen(height: h)
    }

    /// Safety invariants for a hit rect. Empty = safe.
    func violations(hit: CGRect, paintedHeight: CGFloat) -> [String] {
        var out: [String] = []
        let band = CardPlacement.safeBand(in: screen)
        let painted = cardOnScreen(height: paintedHeight)
        if hit.isEmpty { out.append("empty hit rect") }
        if !painted.insetBy(dx: -0.5, dy: -0.5).contains(hit) { out.append("hit rect outside painted card") }
        if !panel.insetBy(dx: -0.5, dy: -0.5).contains(hit) { out.append("hit rect outside panel") }
        if hit.minY < band.minY + CardPlacement.gapAboveControls - 0.5 { out.append("hit rect near credential controls") }
        if hit.maxY > band.maxY + 0.5 { out.append("hit rect enters clock band") }
        if hit.height > panel.height + 0.5 { out.append("hit rect taller than panel") }
        return out
    }
}

// MARK: Card plan (what the view draws)

enum Disclosure: Equatable {
    case none
    /// Right-facing chevron: more rows can be shown.
    case collapsed
    /// Down-facing chevron: the card is expanded.
    case expanded
}

/// Content and height for one display state. Rows beyond `shownRows` are built (so they can be revealed during an
/// animation) but clipped. The footer line exists when there is "more" text or a disclosure glyph.
struct CardPlan: Equatable {
    let snapshot: CardSnapshot
    let shownRows: Int
    let disclosure: Disclosure

    var hasFooter: Bool { snapshot.overflow != nil || disclosure != .none }
    var height: CGFloat { CardMetrics.height(rows: shownRows, overflow: hasFooter) }

    static let empty = CardPlan(snapshot: CardSnapshot(rows: [], summary: "", overflow: nil, asOf: Date(timeIntervalSince1970: 0)),
                                shownRows: 0, disclosure: .none)

    /// `interactive`: the toggle is armed, so the disclosure glyph is drawn. Unarmed cards look exactly as before.
    static func make(_ live: LiveSnapshot?, display: CardDisplayState, interactive: Bool) -> CardPlan {
        guard let live, live.hasContent else { return .empty }
        let expanded = display.mode == .expanded
        let shown = min(live.itemCount, display.rowLimit)
        let text = live.cardSnapshot(rowLimit: display.rowLimit)
        let expandable = live.hasMoreRows && display.capacity > CardPresentation.rowLimit
        let disclosure: Disclosure = (interactive && expandable) ? (expanded ? .expanded : .collapsed) : .none
        // Build every row the expanded card could show, so expanding reveals them in place.
        let buildLimit = expandable ? display.capacity : display.rowLimit
        // Expanded with nothing hidden: the footer reads "Show fewer" beside the down chevron.
        let footer = text.overflow ?? (disclosure == .expanded ? live.text.showFewer : nil)
        let snapshot = CardSnapshot(rows: Array(live.rows.prefix(buildLimit)), projects: Array(live.projects.prefix(buildLimit)),
                                    summary: text.summary, overflow: footer, asOf: text.asOf, summaryVariants: text.summaryVariants,
                                    text: live.text)
        return CardPlan(snapshot: snapshot, shownRows: shown, disclosure: disclosure)
    }
}

// MARK: Animation

/// Pure function of time, so frames are deterministic and testable.
struct ExpandAnimation: Equatable {
    let fromRows: Int
    let toRows: Int
    let fromHeight: CGFloat
    let toHeight: CGFloat
    let duration: TimeInterval

    static func make(from: CardPlan, to: CardPlan, reduceMotion: Bool) -> ExpandAnimation {
        ExpandAnimation(fromRows: from.shownRows, toRows: to.shownRows, fromHeight: from.height, toHeight: to.height,
                        duration: reduceMotion ? 0 : InteractionConfig.duration)
    }

    static func still(_ plan: CardPlan) -> ExpandAnimation {
        ExpandAnimation(fromRows: plan.shownRows, toRows: plan.shownRows, fromHeight: plan.height, toHeight: plan.height, duration: 0)
    }

    var expands: Bool { toRows > fromRows }

    /// 0...1, cubic smoothstep. Duration 0 -> already at the end.
    func progress(at elapsed: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        let t = min(max(elapsed / duration, 0), 1)
        return t * t * (3 - 2 * t)
    }

    func isFinished(at elapsed: TimeInterval) -> Bool { duration <= 0 || elapsed >= duration }

    func cardHeight(at elapsed: TimeInterval) -> CGFloat {
        let p = CGFloat(progress(at: elapsed))
        return (fromHeight + (toHeight - fromHeight) * p).rounded()
    }

    /// Rows beyond the collapsed four fade with the reveal; the first four are always opaque.
    func rowAlpha(index: Int, at elapsed: TimeInterval) -> Double {
        guard index >= CardPresentation.rowLimit else { return 1 }
        let lo = min(fromRows, toRows), hi = max(fromRows, toRows)
        guard index < hi else { return 0 }
        if index < lo { return 1 }
        let p = progress(at: elapsed)
        return toRows >= fromRows ? p : 1 - p
    }
}

// MARK: Lock signal

/// Tri-state lock signal. Only `.locked` arms the toggle; `.inconclusive` always disarms.
enum LockSignal: Equatable {
    case locked, unlocked, inconclusive

    static func from(session: [String: Any]) -> LockSignal {
        guard !session.isEmpty else { return .inconclusive }
        guard (session["kCGSSessionOnConsoleKey"] as? NSNumber)?.boolValue == true else { return .inconclusive }
        guard let raw = session["CGSSessionScreenIsLocked"] else { return .unlocked }
        guard let number = raw as? NSNumber else { return .inconclusive }
        return number.boolValue ? .locked : .unlocked
    }
}

// MARK: Gate

/// Everything the gate needs, gathered fresh for every evaluation, press and release.
struct InteractionContext: Equatable {
    var enabled: Bool            // --expand-on-click
    var lock: LockSignal
    var presenterLocked: Bool    // PresenterStateMachine.locked; must agree with `lock`
    var cardShown: Bool
    var privateAttached: Bool
    var occlusionVisible: Bool
    var geometryOK: Bool
    var capacity: Int
    var rowCount: Int            // wire rows of the latest snapshot (<= 8); 0 when cleared
    var reduceMotion: Bool
}

/// One mouse event as the hit view saw it. `plain`: no Shift/Control/Option/Command/Fn held.
struct PointerSample: Equatable {
    enum Kind: Equatable { case leftDown, leftUp, other }
    var kind: Kind
    var plain: Bool
    /// Inside the rounded hit shape of the hit window as currently framed.
    var insideShape: Bool
}

enum InteractionAction: Equatable {
    case arm
    case disarm(String)
    /// Change the display mode with motion (or one frame under Reduce Motion). The runner builds both plans.
    case animate(toExpanded: Bool, reduceMotion: Bool)
    /// Stop any animation and draw the current display mode with no motion (after a disarm that is collapsed).
    case settle
    case pressed
    case ignored(String)
}

/// Display mode + pointer gate. Fails closed: anything other than a fully verified context disarms and collapses.
struct CardToggle {
    private(set) var display: CardDisplayState
    private(set) var armed = false
    private(set) var animating = false
    private(set) var finished = false
    /// Bumped whenever the active area or arm/lock state changes; a press only completes within one generation.
    private(set) var generation = 0
    private(set) var area: CGRect = .null
    private var pressGeneration: Int?
    private var lastToggle: TimeInterval = -.infinity

    init(capacity: Int) { display = CardDisplayState(capacity: capacity) }

    var pressInFlight: Bool { pressGeneration != nil }

    func allowed(_ c: InteractionContext) -> Bool {
        guard !finished, c.enabled, c.geometryOK, c.cardShown, c.occlusionVisible,
              c.capacity > CardPresentation.rowLimit, c.rowCount > CardPresentation.rowLimit else { return false }
        return c.lock == .locked && c.presenterLocked && c.privateAttached
    }

    /// After every presenter event, lock poll, content change, occlusion change and wake.
    mutating func evaluate(_ c: InteractionContext) -> [InteractionAction] {
        if allowed(c) {
            guard !armed else { return [] }
            armed = true
            bump()
            return [.arm]
        }
        return disarm(reason(c))
    }

    /// The hit rect the runner is about to apply. A change drops any press in flight.
    @discardableResult
    mutating func setArea(_ rect: CGRect) -> Bool {
        guard rect != area else { return false }
        area = rect
        bump()
        return true
    }

    /// New live content. Collapses (no animation) when it no longer has rows beyond four; stops a running animation.
    mutating func snapshot(_ live: LiveSnapshot?) -> [InteractionAction] {
        let wasExpanded = display.mode == .expanded
        if let live { display.snapshot(live) } else { display.cleared() }
        var actions: [InteractionAction] = []
        if animating || (wasExpanded && display.mode == .collapsed) {
            animating = false
            pressGeneration = nil
            actions.append(.settle)
        }
        return actions
    }

    mutating func lockChanged() -> [InteractionAction] {
        let wasExpanded = display.mode == .expanded || animating
        display.lockChanged()
        animating = false
        bump()
        return wasExpanded ? [.settle] : []
    }

    mutating func pointer(_ s: PointerSample, _ c: InteractionContext, now: TimeInterval) -> [InteractionAction] {
        switch s.kind {
        case .other:
            pressGeneration = nil
            return [.ignored("not a plain left button")]
        case .leftDown:
            pressGeneration = nil
            guard armed else { return [.ignored("not armed")] }
            guard allowed(c) else { return disarm("press with unverified context: " + reason(c)) }
            guard s.plain else { return [.ignored("modifier held")] }
            guard s.insideShape else { return [.ignored("outside card shape")] }
            guard !animating else { return [.ignored("animating")] }
            pressGeneration = generation
            return [.pressed]
        case .leftUp:
            let pressed = pressGeneration
            pressGeneration = nil
            guard let pressed else { return [.ignored("release without press")] }
            guard armed else { return [.ignored("not armed")] }
            guard pressed == generation else { return [.ignored("stale: area or lock state changed")] }
            guard allowed(c) else { return disarm("release with unverified context: " + reason(c)) }
            guard s.plain else { return [.ignored("modifier held")] }
            guard s.insideShape else { return [.ignored("released outside card shape")] }
            guard !animating else { return [.ignored("animating")] }
            guard now - lastToggle >= InteractionConfig.minToggleInterval else { return [.ignored("too soon")] }
            let toExpanded: Bool
            if display.mode == .collapsed {
                guard display.expand() else { return [.ignored("nothing to expand")] }
                toExpanded = true
            } else {
                display.collapse()
                toExpanded = false
            }
            lastToggle = now
            animating = !c.reduceMotion
            return [.animate(toExpanded: toExpanded, reduceMotion: c.reduceMotion)]
        }
    }

    mutating func animationFinished() { animating = false }

    /// Exit, failure, signal. Idempotent; never re-arms afterwards.
    mutating func shutdown(_ why: String) -> [InteractionAction] {
        let actions = disarm(why)
        finished = true
        return actions
    }

    private mutating func bump() {
        generation &+= 1
        pressGeneration = nil
    }

    private mutating func disarm(_ why: String) -> [InteractionAction] {
        var actions: [InteractionAction] = []
        if armed { actions.append(.disarm(why)) }
        if display.mode == .expanded || animating { actions.append(.settle) }
        if armed || pressGeneration != nil { bump() }
        armed = false
        animating = false
        display.collapse()
        return actions
    }

    private func reason(_ c: InteractionContext) -> String {
        if finished { return "finished" }
        if !c.enabled { return "disabled" }
        if !c.geometryOK { return "geometry" }
        if !c.cardShown { return "card hidden" }
        if !c.occlusionVisible { return "occluded" }
        if c.capacity <= CardPresentation.rowLimit { return "no room to expand" }
        if c.rowCount <= CardPresentation.rowLimit { return "nothing hidden" }
        if c.lock != .locked { return "lock signal \(c.lock)" }
        if !c.presenterLocked { return "presenter not locked" }
        return "private placement not attached"
    }
}

extension PrivatePlacement {
    /// Adds one more window (the hit panel) to the space this placement already owns, through the same validated
    /// SLSSpaceAddWindowsAndRemoveFromSpaces wrapper as the card. Fails closed (-1).
    func adoptAuxiliary(window: Int32, using ops: PrivateSpaceOperations) -> PrivatePlacementResult {
        guard space != 0, window > 0 else { return PrivatePlacementResult(failure: -1) }
        ops.addWindow(window, to: space)
        return PrivatePlacementResult(steps: [.init(step: .addWindows, result: .voidCompleted)])
    }
}
