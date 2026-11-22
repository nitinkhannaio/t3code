import AppKit

func log(_ message: String) {
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withTime, .withColonSeparatorInTime, .withFractionalSeconds])
    print("[\(stamp)] \(message)")
    fflush(stdout)
}

@MainActor
final class Runner {
    private let options: RunOptions
    private var machine = PresenterStateMachine()
    /// The latest decoded snapshot, in memory only. Never synthesized, never written anywhere.
    private var live: LiveSnapshot?
    /// Collapsed/expanded plus the whole-card pointer gate (Interaction.swift).
    private var toggle = CardToggle(capacity: CardPresentation.rowLimit)
    /// Nil while the primary screen is too small to keep the card clear of the clock and unlock controls.
    private var surface: CardSurface?
    /// Only when --expand-on-click: the one interactive window, sized to the painted card.
    private var hitPanel: CardHitPanel?
    /// The screen changed while the card was up; the new layout waits for the card to hide.
    private var layoutPending = false
    private var animation: ExpandAnimation?
    private var animationStart: TimeInterval = 0
    private var animationTimer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var reader: StdinReader?
    private let monitor = LockMonitor()
    private let backend: SkyLightBackend
    private var panel: CardPanel!
    /// Adaptive glass (`--appearance auto`): re-read only when the card rect, screen or wallpaper changes.
    private let wallpaper = WallpaperSampler()
    private var signalSources: [DispatchSourceSignal] = []

    init(options: RunOptions, backend: SkyLightBackend) {
        self.options = options
        self.backend = backend
    }

    func start() {
        guard let screen = NSScreen.screens.first else { return finish(code: 2, reason: "No screen.") }
        guard let placed = CardSurface.make(screen: screen.frame) else {
            return finish(code: 2, reason: "Screen \(screen.frame) is too small to keep the card clear of the clock and unlock controls.")
        }
        surface = placed
        toggle = CardToggle(capacity: placed.capacity)
        panel = CardPanel(frame: placed.panel, appearance: options.appearance ?? .dark)
        redraw()
        if options.expandOnClick {
            let hit = CardHitPanel(frame: placed.panel, appearance: panel.card.cardAppearance, cardLevel: panel.level)
            hit.hitView.onPointer = { [weak self] sample in MainActor.assumeIsolated { self?.pointer(sample) } }
            hit.onDroppedPointer = { [weak self] in
                MainActor.assumeIsolated { self?.pointer(PointerSample(kind: .other, plain: false, insideShape: false)) }
            }
            hitPanel = hit
        }
        log("live-lock screen=\(screen.frame) panel=\(placed.panel) rowCapacity=\(placed.capacity) expandOnClick=\(hitPanel != nil) glass=\(options.appearance?.rawValue ?? "auto")")

        installSignals()
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.screensChanged() }
        if options.appearance == nil {
            // Each space can have its own wallpaper.
            observe(NSWorkspace.shared.notificationCenter, NSWorkspace.activeSpaceDidChangeNotification) {
                $0.wallpaper.invalidate()
                $0.adaptGlass()
            }
        }
        if hitPanel != nil {
            observe(NotificationCenter.default, NSWindow.didChangeOcclusionStateNotification, object: panel) { $0.reevaluatePointer() }
        }
        monitor.onLockChange = { [weak self] locked in
            guard let self, locked != self.machine.locked else {
                self?.reevaluatePointer()
                return
            }
            log(locked ? "locked" : "unlocked")
            // Every lock/unlock starts collapsed.
            self.performInteraction(self.toggle.lockChanged())
            self.dispatch(.lockChanged(locked: locked))
        }
        monitor.onWake = { [weak self] in
            log("screens woke")
            self?.dispatch(.screensWoke)
        }
        dispatch(.started(locked: LockMonitor.isLocked()))
        guard !machine.finished else { return }
        monitor.start()
        let reader = StdinReader()
        self.reader = reader
        reader.start(
            onBatch: { [weak self] batch in MainActor.assumeIsolated { self?.apply(batch) } },
            onClose: { [weak self] reason in MainActor.assumeIsolated {
                log("input closed: \(reason)")
                self?.dispatch(.inputClosed)
            } }
        )
        log("armed: reading snapshots from stdin. Hidden until locked with a non-empty snapshot.")
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, object: AnyObject? = nil, _ body: @escaping (Runner) -> Void) {
        let token = center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { body(self) } }
        }
        observers.append((center, token))
    }

    /// Display configuration changed. Hidden: re-place now. Shown: disarm (geometry is stale) and re-place on hide;
    /// windows are never moved while locked (see CardHitPanel). A lid close or monitor plug usually leaves the main
    /// screen as it was, so once the displays settle, clicks come back if nothing about the card moved.
    private func screensChanged() {
        wallpaper.invalidate()
        if machine.shown {
            layoutPending = true
            log("screen parameters changed while shown: expand-on-click disarmed until the layout is unchanged or the card hides")
            reevaluatePointer()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.rearmIfLayoutUnchanged() }
        } else {
            relayout()
        }
    }

    /// Clears a pending layout only when the main screen gives the same placement and the window server shows both
    /// the card and its click window where that placement puts them. Never moves a window.
    private func rearmIfLayoutUnchanged() {
        guard layoutPending, machine.shown, !machine.finished, let surface, let screen = NSScreen.screens.first,
              CardSurface.make(screen: screen.frame) == surface else { return }
        let expected = CardCoordinates.screenToCG(surface.panel, primaryHeight: screen.frame.height)
        guard windowServerFrame(panel) == expected, hitPanel.map({ windowServerFrame($0) == expected }) ?? true else { return }
        layoutPending = false
        log("screens settled with the card where it was: expand-on-click allowed again")
        reevaluatePointer()
    }

    private func windowServerFrame(_ window: NSWindow) -> CGRect? {
        let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]])?.first
        guard let bounds = info?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds as CFDictionary)
    }

    private func relayout() {
        layoutPending = false
        guard let screen = NSScreen.screens.first, let placed = CardSurface.make(screen: screen.frame) else {
            surface = nil
            panel.alphaValue = 0
            log("screen too small to keep the card clear of the clock and unlock controls: card suppressed")
            return reevaluatePointer()
        }
        performInteraction(toggle.evaluate(context(cardShown: false)))
        surface = placed
        toggle = CardToggle(capacity: placed.capacity)
        if let live { performInteraction(toggle.snapshot(live)) }
        panel.setFrame(placed.panel, display: false)
        hitPanel?.setPanelFrame(placed.panel)
        panel.alphaValue = 1
        log("re-placed for screen=\(screen.frame) panel=\(placed.panel) rowCapacity=\(placed.capacity)")
        redraw()
    }

    private func currentPlan() -> CardPlan { CardPlan.make(live, display: toggle.display, interactive: toggle.armed) }

    /// Draws the current state with no motion.
    private func redraw() {
        stopAnimation()
        let plan = currentPlan()
        panel.update(plan)
        hitPanel?.hitView.expanded = toggle.display.mode == .expanded
        applyArea()
        adaptGlass()
    }

    /// Settled frames only (never per animation frame). A no-op unless the card rect, screen or wallpaper changed.
    private func adaptGlass() {
        guard options.appearance == nil, let screen = NSScreen.screens.first, panel.card.frame.height > 0,
              let choice = wallpaper.evaluate(card: panel.convertToScreen(panel.card.frame), screen: screen) else { return }
        guard choice.appearance != panel.card.cardAppearance else { return }
        panel.card.setAppearance(choice.appearance)
        hitPanel?.hitView.cardAppearance = choice.appearance
        log("glass: \(choice.appearance.rawValue) (wallpaper luminance \(choice.luminance.map { String(format: "%.2f", $0) } ?? "unavailable"))")
    }

    /// Latest-only: a batch carries the last valid update from one read; invalid lines are counted, not applied.
    private func apply(_ batch: StdinReader.Batch) {
        if batch.invalid > 0 {
            log("live: ignored \(batch.invalid) invalid line(s): \(batch.reasons.map { "\($0)" }.joined(separator: ", ")); kept previous snapshot")
        }
        guard let update = batch.latest else { return }
        switch update {
        case .clear:
            live = nil
            performInteraction(toggle.snapshot(nil))
            log("live: cleared")
        case .snapshot(let snapshot):
            live = snapshot
            performInteraction(toggle.snapshot(snapshot))
            // Counts and freshness only; titles and providers are never logged.
            log("live: snapshot mode=\(snapshot.mode.rawValue) items=\(snapshot.itemCount) \(CardPresentation.summary(snapshot.totals))\(snapshot.hasContent ? "" : " (empty)")")
        }
        if animation == nil { redraw() }
        dispatch(.liveContent(live?.hasContent ?? false))
    }

    private func installSignals() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.dispatch(.interrupted) } }
            source.resume()
            signalSources.append(source)
        }
    }

    private func dispatch(_ event: PresenterEvent) {
        let actions = machine.handle(event)
        // Pointer first on any way out: the hit panel is ordered out before the card hides and the space goes.
        if hitPanel != nil {
            if actions.contains(where: { if case .exit = $0 { return true }; return false }) {
                performInteraction(toggle.shutdown("exit"))
            } else if actions.contains(.hide) || actions.contains(.detachPrivate) || actions.contains(.teardownPrivate) {
                performInteraction(toggle.evaluate(context(cardShown: false)))
            }
        }
        for action in actions { perform(action) }
        if layoutPending, !machine.shown, !machine.finished { relayout() }
        reevaluatePointer()
    }

    private func perform(_ action: PresenterAction) {
        switch action {
        case .show:
            redraw()
            panel.orderFrontRegardless()
            log("shown")
            diagnose(after: 1.0)
        case .hide:
            panel.orderOut(nil)
            log("hidden")
        case .attachPrivate:
            privateCall("attach") { backend.attach(self.panel) }
            for delay in PresenterStateMachine.reassertDelays { schedulePrivateReassert(after: delay) }
        case .reassertPrivate:
            for delay in PresenterStateMachine.reassertDelays { schedulePrivateReassert(after: delay) }
        case .detachPrivate:
            report("detach", backend.detach())
        case .teardownPrivate:
            report("teardown", backend.teardown())
        case .exit(let code, let reason):
            finish(code: code, reason: reason)
        }
    }

    private func schedulePrivateReassert(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.machine.attached, self.machine.shown, self.machine.locked else { return }
            self.privateCall("reassert +\(delay)s") { self.backend.reassert(self.panel) }
            if let hit = self.hitPanel, self.toggle.armed, hit.isArmed {
                self.privateCall("hit reassert +\(delay)s") { self.backend.adoptAuxiliary(hit) }
            }
            self.reevaluatePointer()
        }
    }

    /// Stops only on a known failure (invalid window, no space, SLSSpaceCreate == 0); void calls just log completion.
    private func privateCall(_ name: String, _ call: () -> PrivatePlacementResult) {
        let result = call()
        report(name, result)
        if let code = result.failure { dispatch(.privateFailed(code: code)) }
        diagnose(after: 0.3)
    }

    private func report(_ name: String, _ result: PrivatePlacementResult) {
        if result.steps.isEmpty && result.failure == nil { log("\(name): no space; nothing to do") }
        for step in result.steps { log("\(name) \(step.description)") }
        if let code = result.failure { log("\(name) -> known failure \(code)") } else if !result.steps.isEmpty { log("\(name) -> done") }
    }

    /// Public, own-window-only visibility evidence that can be read after unlocking.
    private func diagnose(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(panel.windowNumber)) as? [[String: Any]])?.first
            let onscreen = (info?[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            log("diagnose: occlusionVisible=\(panel.occlusionState.contains(.visible)) cgOnscreen=\(onscreen) windowLayer=\(info?[kCGWindowLayer as String] ?? "?") frame=\(panel.frame)")
        }
    }

    private func finish(code: Int32, reason: String) {
        if hitPanel != nil { performInteraction(toggle.shutdown("finish")) }
        stopAnimation()
        log("exit \(code): \(reason)")
        monitor.stop()
        observers.forEach { $0.0.removeObserver($0.1) }
        hitPanel?.orderOut(nil)
        panel?.orderOut(nil)
        exit(code)
    }

    // MARK: Whole-card expand/collapse (--expand-on-click)

    /// `freshLock`: re-read the session (pointer presses); otherwise the monitor's last poll.
    private func context(cardShown: Bool? = nil, freshLock: Bool = false) -> InteractionContext {
        InteractionContext(
            enabled: hitPanel != nil,
            lock: freshLock ? LockSignal.from(session: LockMonitor.current()) : monitor.signal,
            presenterLocked: machine.locked,
            cardShown: cardShown ?? (machine.shown && panel.isVisible),
            privateAttached: machine.attached && backend.hasSpace,
            occlusionVisible: panel.occlusionState.contains(.visible),
            geometryOK: !layoutPending && surface != nil && areaSafe,
            capacity: toggle.display.capacity,
            rowCount: live?.itemCount ?? 0,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        )
    }

    private var areaSafe = true

    private func reevaluatePointer() {
        guard hitPanel != nil, panel != nil, !machine.finished else { return }
        performInteraction(toggle.evaluate(context()))
    }

    /// Frames the hit window to the painted card (smaller endpoint while animating) and records it with the gate,
    /// which drops any press in flight when the area changes. Unsafe geometry disarms.
    private func applyArea() {
        guard let hit = hitPanel, let surface else { return }
        let height = panel.card.frame.height
        let rect = surface.hitFrame(currentHeight: height, animation: animation)
        let problems = surface.violations(hit: rect, paintedHeight: animation.map { min($0.fromHeight, $0.toHeight) } ?? height)
        if !problems.isEmpty, !rect.isEmpty {
            if areaSafe { log("expand-on-click: unsafe hit rect (\(problems.joined(separator: ", "))); disarming") }
            areaSafe = false
        } else if !rect.isEmpty {
            areaSafe = true
        }
        if toggle.setArea(rect) { hit.place(rect) }
    }

    private func pointer(_ sample: PointerSample) {
        guard hitPanel != nil else { return }
        if sample.kind != .other { evidence(sample) }
        performInteraction(toggle.pointer(sample, context(freshLock: true), now: ProcessInfo.processInfo.systemUptime))
    }

    private func performInteraction(_ actions: [InteractionAction]) {
        for action in actions {
            switch action {
            case .arm:
                guard let hit = hitPanel else { continue }
                redraw()
                hit.arm()
                log("expand-on-click armed: interactive region = \(hit.activeFrame) (painted card only; hit window \(hit.frame), card panel stays click-through)")
                privateCall("hit adopt") { backend.adoptAuxiliary(hit) }
                diagnose(hit, "hit", after: 0.5)
            case .disarm(let reason):
                hitPanel?.disarm()
                log("expand-on-click disarmed: \(reason)")
                redraw()
            case .animate(let toExpanded, let reduceMotion):
                startAnimation(toExpanded: toExpanded, reduceMotion: reduceMotion)
            case .settle:
                redraw()
            case .pressed:
                break
            case .ignored(let reason):
                log("expand-on-click: ignored (\(reason))")
            }
        }
    }

    private func startAnimation(toExpanded: Bool, reduceMotion: Bool) {
        stopAnimation()
        var before = toggle.display
        if toExpanded { before.collapse() } else { _ = before.expand() }
        let from = CardPlan.make(live, display: before, interactive: true)
        let to = currentPlan()
        let a = ExpandAnimation.make(from: from, to: to, reduceMotion: reduceMotion)
        log("expand-on-click: animate rows \(a.fromRows) -> \(a.toRows) over \(a.duration)s\(a.duration == 0 ? " (Reduce Motion)" : "")")
        // Build the destination content (all rows + destination footer/chevron), then run the frames.
        panel.card.update(to)
        hitPanel?.hitView.expanded = toExpanded
        animation = a
        animationStart = ProcessInfo.processInfo.systemUptime
        applyArea()
        stepAnimation()
        guard animation != nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.stepAnimation() } }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    private func stepAnimation() {
        guard let a = animation else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - animationStart
        panel.setCardHeight(a.cardHeight(at: elapsed))
        panel.card.setRowAlphas { a.rowAlpha(index: $0, at: elapsed) }
        if a.isFinished(at: elapsed) {
            stopAnimation()
            toggle.animationFinished()
            redraw()
            log("expand-on-click: animation done, card height=\(panel.card.frame.height)")
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animation = nil
    }

    /// Delivery evidence only (never content): confirms nothing became key/active.
    private func evidence(_ s: PointerSample) {
        log("expand-on-click: \(s.kind == .leftDown ? "leftDown" : "leftUp") plain=\(s.plain) inside=\(s.insideShape) | appActive=\(NSApp.isActive) "
            + "keyWindow=\(NSApp.keyWindow == nil ? "none" : "PRESENT") mainWindow=\(NSApp.mainWindow == nil ? "none" : "PRESENT") "
            + "hitKey=\(hitPanel?.isKeyWindow ?? false) cardKey=\(panel.isKeyWindow)")
    }

    private func diagnose(_ window: NSWindow, _ name: String, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard window.isVisible else { return }
            let info = (CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(window.windowNumber)) as? [[String: Any]])?.first
            let onscreen = (info?[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            log("diagnose \(name): occlusionVisible=\(window.occlusionState.contains(.visible)) cgOnscreen=\(onscreen) layer=\(info?[kCGWindowLayer as String] ?? "?") frame=\(window.frame) ignoresMouse=\(window.ignoresMouseEvents) key=\(window.isKeyWindow)")
        }
    }
}

