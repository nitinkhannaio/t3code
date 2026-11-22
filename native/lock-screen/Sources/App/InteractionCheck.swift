import AppKit

/// Offscreen check of the whole-card toggle: builds the card and hit panels but never orders either in or activates
/// the app. Checks window flags, hit rect == painted card, hit pixels inside the painted shape, every animation
/// frame, AppKit vs Core coordinate conversions, and the credential/clock bands.
@MainActor
func interactionCheck() -> Int32 {
    var failures = 0, passes = 0
    func check(_ ok: Bool, _ what: @autoclosure () -> String) {
        if ok { passes += 1 } else { failures += 1; print("FAIL \(what())") }
    }
    _ = NSApplication.shared
    let reference = CGRect(x: 0, y: 0, width: 2240, height: 1260)
    guard let surface = CardSurface.make(screen: reference) else { print("FAIL no reference surface"); return 1 }
    check(surface.capacity == 8, "reference capacity 8 (\(surface.capacity))")

    // MARK: windows (constructed, never shown)
    let cardPanel = CardPanel(frame: surface.panel, appearance: .dark)
    let collapsed = renderPlan(.allStates, expanded: false, interactive: true)
    let expanded = renderPlan(.allStates, expanded: true, interactive: true)
    let six = renderPlan(.sixRows, expanded: true, interactive: true)
    cardPanel.update(collapsed)
    let hit = CardHitPanel(frame: surface.hitFrame(currentHeight: collapsed.height), appearance: .dark, cardLevel: cardPanel.level)
    for (name, panel) in [("card", cardPanel as NSPanel), ("hit", hit as NSPanel)] {
        check(!panel.canBecomeKey && !panel.canBecomeMain, "\(name) never key/main")
        check(panel.styleMask.contains(.nonactivatingPanel) && panel.styleMask.contains(.borderless), "\(name) borderless nonactivating")
        check(panel.canBecomeVisibleWithoutLogin, "\(name) visible without login (lock placement)")
        check(!panel.isVisible, "\(name) not ordered in")
        panel.makeKey()
        check(!panel.isKeyWindow, "\(name) makeKey refused")
    }
    check(cardPanel.ignoresMouseEvents, "card panel click-through for life")
    check(cardPanel.card.hitTest(NSPoint(x: 20, y: 20)) == nil, "card view never hit")
    check(hit.ignoresMouseEvents && !hit.isArmed, "hit panel starts disarmed")
    check(hit.level.rawValue == cardPanel.level.rawValue + 1, "hit panel one level above card")
    check(hit.frame == surface.cardOnScreen(height: collapsed.height), "hit frame == painted collapsed card \(hit.frame)")
    check(hit.frame.maxY < surface.panel.maxY - 1, "max panel's transparent top is not in the hit window")
    check(hit.frame.minX == surface.panel.minX && hit.frame.width == surface.panel.width && hit.frame.minY == surface.panel.minY, "hit shares the card's bottom/left/right edges")
    check(!hit.hitView.acceptsFirstResponder && !hit.hitView.needsPanelToBecomeKey && hit.hitView.acceptsFirstMouse(for: nil), "hit view focus rules")
    for type in [NSEvent.EventType.keyDown, .keyUp, .flagsChanged, .scrollWheel, .rightMouseDown, .rightMouseUp, .otherMouseDown, .mouseMoved, .magnify, .swipe] {
        check(CardHitPanel.droppedTypes.contains(type), "hit drops \(type.rawValue)")
    }
    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp, .leftMouseDragged] {
        check(!CardHitPanel.droppedTypes.contains(type), "hit keeps \(type.rawValue)")
    }
    check(CardHitPanel.blockingModifiers == [.shift, .control, .option, .command, .function], "plain = no shift/ctrl/opt/cmd/fn")
    check(hit.hitView.accessibilityRole() == .button && hit.hitView.accessibilityLabel() == CardHitView.collapsedAccessibilityLabel, "hit a11y collapsed")
    hit.hitView.expanded = true
    check(hit.hitView.accessibilityLabel() == CardHitView.expandedAccessibilityLabel && hit.hitView.isAccessibilityExpanded(), "hit a11y expanded")
    hit.hitView.expanded = false

    // MARK: plans drawn by the view
    check(collapsed.disclosure == .collapsed && collapsed.shownRows == 4 && cardPanel.card.builtRowCount == 8, "collapsed plan: 4 shown of 8 built, right chevron")
    check(cardPanel.card.visibleRowCapacity == 4, "collapsed clip shows 4 rows")
    check(collapsed.height == CardMetrics.maxHeight, "collapsed height (228 pt)")
    check(expanded.disclosure == .expanded && expanded.shownRows == 8 && expanded.height == CardMetrics.expandedMaxHeight, "expanded plan 8 rows, 372 pt")
    check(six.snapshot.overflow == "Show fewer" && six.hasFooter && six.disclosure == .expanded, "six rows expanded: nothing omitted, footer = chevron + Show fewer")
    let unarmed = renderPlan(.allStates, expanded: false, interactive: false)
    check(unarmed.disclosure == .none && unarmed.height == collapsed.height, "unarmed card: no chevron, same height")
    let few = renderPlan(.mixed, expanded: true, interactive: true)
    check(few.disclosure == .none && few.shownRows == 4 && few.height == CardMetrics.height(rows: 4, overflow: false), "<=4 rows: no chevron, old layout")

    // MARK: hit shape vs painted pixels (real CardView render, material off as in every offscreen render)
    for (name, plan) in [("collapsed", collapsed), ("expanded", expanded), ("six", six)] {
        for appearance in [CardAppearance.dark, .light] {
            let card = CardView(appearance: appearance, useMaterial: false)
            card.update(plan)
            card.frame = CGRect(x: 0, y: 0, width: surface.panel.width, height: plan.height)
            card.layoutSubtreeIfNeeded()
            guard let rep = card.bitmapImageRepForCachingDisplay(in: card.bounds) else { check(false, "bitmap"); continue }
            card.cacheDisplay(in: card.bounds, to: rep)
            let sx = CGFloat(rep.pixelsWide) / card.bounds.width, sy = CGFloat(rep.pixelsHigh) / card.bounds.height
            var accepted = 0, acceptedUnpainted = 0, painted = 0, paintedAccepted = 0
            for py in 0..<rep.pixelsHigh {
                for px in 0..<rep.pixelsWide {
                    let alpha = rep.colorAt(x: px, y: py)?.alphaComponent ?? 0
                    // Bitmap rows run top-down; hit space is unflipped (y up) with the same origin as the card's bottom-left.
                    let p = CGPoint(x: (CGFloat(px) + 0.5) / sx, y: card.bounds.height - (CGFloat(py) + 0.5) / sy)
                    let inside = CardHitShape.contains(p, size: card.bounds.size)
                    if inside { accepted += 1; if alpha < 0.2 { acceptedUnpainted += 1 } }
                    if alpha >= 0.2 { painted += 1; if inside { paintedAccepted += 1 } }
                }
            }
            let corner = rep.colorAt(x: 0, y: 0)?.alphaComponent ?? 1
            check(corner < 0.05, "\(name) \(appearance): render is corner-masked (alpha \(corner))")
            check(accepted > 0 && acceptedUnpainted == 0, "\(name) \(appearance): every accepted point is painted (\(acceptedUnpainted) unpainted)")
            let coverage = Double(paintedAccepted) / Double(max(painted, 1))
            check(coverage >= 0.97, "\(name) \(appearance): hit covers >=97% of painted card (\(coverage))")
        }
    }

    // MARK: hit view pixels + AppKit hit testing (window-server hit pixels only inside the shape)
    for plan in [collapsed, expanded] {
        hit.place(surface.hitFrame(currentHeight: plan.height))
        let v = hit.hitView
        check(v.frame.size == hit.frame.size, "hit view fills hit window")
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { check(false, "hit bitmap"); continue }
        v.cacheDisplay(in: v.bounds, to: rep)
        let sx = CGFloat(rep.pixelsWide) / v.bounds.width, sy = CGFloat(rep.pixelsHigh) / v.bounds.height
        var mismatches = 0, outsideLit = 0, testMismatch = 0
        for py in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for px in stride(from: 0, to: rep.pixelsWide, by: 2) {
                let p = CGPoint(x: (CGFloat(px) + 0.5) / sx, y: v.bounds.height - (CGFloat(py) + 0.5) / sy)
                let inside = CardHitShape.contains(p, size: v.bounds.size)
                let a = rep.colorAt(x: px, y: py)?.alphaComponent ?? 0
                let strictlyInside = CardHitShape.contains(p, size: v.bounds.size, radius: InteractionConfig.hitCornerRadius + 1, inset: InteractionConfig.hitInset + 1)
                if strictlyInside && a < 1.0 / 255 { mismatches += 1 }
                if !CardHitShape.contains(p, size: v.bounds.size, radius: InteractionConfig.hitCornerRadius - 1, inset: InteractionConfig.hitInset - 1) && a > 0 { outsideLit += 1 }
                if (v.hitTest(p) === v) != inside { testMismatch += 1 }
            }
        }
        check(mismatches == 0, "hit pixels alpha>0 inside shape (\(mismatches) misses) h=\(plan.height)")
        check(outsideLit == 0, "hit pixels alpha==0 outside shape (\(outsideLit)) h=\(plan.height)")
        check(testMismatch == 0, "hitView.hitTest == CardHitShape (\(testMismatch)) h=\(plan.height)")
        check(v.hitTest(NSPoint(x: 0.4, y: 0.4)) == nil && v.hitTest(NSPoint(x: v.bounds.maxX - 0.4, y: v.bounds.maxY - 0.4)) == nil, "rounded corners not hit")
        check(v.hitTest(NSPoint(x: -1, y: 20)) == nil && v.hitTest(NSPoint(x: v.bounds.midX, y: v.bounds.maxY + 1)) == nil, "outside the card not hit")
        // Coordinate conversions: AppKit vs Core.
        for p in [CGPoint(x: 5, y: 7), CGPoint(x: v.bounds.midX, y: v.bounds.midY), CGPoint(x: v.bounds.maxX - 3, y: v.bounds.maxY - 2)] {
            let appkit = hit.convertPoint(toScreen: v.convert(p, to: nil))
            check(appkit == CardCoordinates.hitToScreen(p, hitFrame: hit.frame), "hit->screen \(p)")
            check(CardCoordinates.screenToHit(appkit, hitFrame: hit.frame) == p, "screen->hit \(p)")
        }
    }
    // Card (flipped) -> screen, via AppKit, equals the Core chain card -> panel -> screen.
    cardPanel.update(expanded)
    for p in [CGPoint(x: 10, y: 10), CGPoint(x: 100, y: expanded.height - 5)] {
        let appkit = cardPanel.convertPoint(toScreen: cardPanel.card.convert(p, to: nil))
        let core = CardCoordinates.panelToScreen(CardCoordinates.cardToPanel(p, cardHeight: expanded.height), panel: surface.panel)
        check(appkit == core, "card(flipped)->screen \(p): \(appkit) vs \(core)")
    }
    let cg = CardCoordinates.screenToCG(hit.frame, primaryHeight: reference.height)
    check(CardCoordinates.cgToScreen(cg, primaryHeight: reference.height) == hit.frame && cg.minY == reference.height - hit.frame.maxY, "screen<->CG round trip")

    // MARK: animation frames: hit always inside the painted card, bands kept, bottom pinned
    for reduceMotion in [false, true] {
        for (from, to) in [(collapsed, expanded), (expanded, collapsed), (collapsed, six), (six, collapsed)] {
            let a = ExpandAnimation.make(from: from, to: to, reduceMotion: reduceMotion)
            cardPanel.card.update(to)
            var t: TimeInterval = 0, frames = 0
            repeat {
                cardPanel.setCardHeight(a.cardHeight(at: t))
                let painted = cardPanel.card.frame.height
                let rect = surface.hitFrame(currentHeight: painted, animation: a.isFinished(at: t) ? nil : a)
                let problems = surface.violations(hit: rect, paintedHeight: painted)
                check(problems.isEmpty, "frame t=\(t) \(from.shownRows)->\(to.shownRows): \(problems)")
                check(cardPanel.card.frame.minY == 0, "bottom pinned t=\(t)")
                // Rounded hit shape of the hit rect is inside the rounded shape of the painted card at this frame.
                let paintedSize = CGSize(width: surface.panel.width, height: painted)
                var escapes = 0
                for x in stride(from: 0, through: rect.width, by: 3) {
                    for y in stride(from: 0, through: rect.height, by: 3) {
                        let p = CGPoint(x: x, y: y)
                        if CardHitShape.contains(p, size: rect.size), !CardHitShape.contains(p, size: paintedSize) { escapes += 1 }
                    }
                }
                check(escapes == 0, "hit shape inside painted shape t=\(t) (\(escapes))")
                frames += 1
                t += 1.0 / 60
            } while !a.isFinished(at: t - 1.0 / 60)
            check(cardPanel.card.frame.height == to.height, "final height \(to.height) reduceMotion=\(reduceMotion)")
            if reduceMotion { check(frames == 1, "Reduce Motion: one frame (\(frames))") }
        }
    }

    // MARK: every reference screen: bands, capacity, no overlap near authentication controls
    for screen in [reference, CGRect(x: 0, y: 0, width: 1470, height: 956), CGRect(x: 0, y: 0, width: 1280, height: 800),
                   CGRect(x: 0, y: 0, width: 1280, height: 720), CGRect(x: 0, y: 0, width: 1920, height: 1080),
                   CGRect(x: 0, y: 0, width: 2560, height: 1440), CGRect(x: 0, y: 0, width: 1440, height: 900)] {
        guard let s = CardSurface.make(screen: screen) else { check(false, "surface for \(screen)"); continue }
        let band = CardPlacement.safeBand(in: screen)
        for exp in [false, true] {
            let plan = renderPlan(.allStates, expanded: exp, interactive: true, capacity: s.capacity)
            let rect = s.hitFrame(currentHeight: plan.height)
            check(s.violations(hit: rect, paintedHeight: plan.height).isEmpty, "\(screen.size) \(exp ? "expanded" : "collapsed") hit safe")
            check(rect.minY >= band.minY + CardPlacement.gapAboveControls - 0.5, "\(screen.size) hit >=10 pt above credential band")
            check(rect.maxY <= band.maxY, "\(screen.size) hit below clock band")
        }
    }
    check(CardSurface.make(screen: CGRect(x: 0, y: 0, width: 1024, height: 500)) == nil, "too-small screen: no surface (fail closed)")

    check(NSApp.keyWindow == nil && NSApp.mainWindow == nil, "no key/main window")
    check(!NSApp.isActive, "app never active")
    check(NSApp.windows.allSatisfy { !$0.isVisible }, "no window visible")
    print("interaction-check: \(passes) passed, \(failures) failed")
    return failures == 0 ? 0 : 1
}
