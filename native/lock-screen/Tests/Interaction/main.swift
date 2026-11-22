import CoreGraphics
import Foundation

// Core-only (no AppKit, no window server, no private code): whole-card toggle, geometry, coordinate spaces,
// plans for resize/update/clear/overflow/trailing declutter, animation, and the fail-closed gate.
var failures = 0, passes = 0
func check(_ c: Bool, _ m: @autoclosure () -> String, line: Int = #line) {
    if c { passes += 1 } else { failures += 1; print("FAIL line \(line): \(m())") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ w: String, line: Int = #line) { check(a == b, "\(w): \(a) != \(b)", line: line) }

func rowJSON(_ status: String, _ provider: String = "codex") -> String {
    #"{"status":"\#(status)","provider":"\#(provider)","title":"t","projectIcon":null}"#
}
/// A threads line with English copy: counts are the rows plus `extra` threads beyond the wire, all hidden.
func line(_ statuses: [String], extraAttention: Int = 0, extraWorking: Int = 0, extraDone: Int = 0) -> String {
    var totals = StatusCounts(attention: extraAttention, working: extraWorking, done: extraDone)
    for s in statuses { totals[SessionStatus(rawValue: s)!.group] += 1 }
    var hidden: [String: Int] = [:]
    for k in 4...8 where totals.total - min(k, statuses.count) > 0 { hidden[String(k)] = totals.total - min(k, statuses.count) }
    let english = CardText.english(totals: totals, hidden: hidden.values)
    let text: [String: Any] = [
        "summary": english.summary, "updated": english.updated, "showFewer": english.showFewer, "agent": english.agent,
        "more": Dictionary(uniqueKeysWithValues: english.more.map { (String($0.key), $0.value) }),
        "statuses": Dictionary(uniqueKeysWithValues: english.statuses.map { ($0.key.rawValue, $0.value) }),
        "duration": ["seconds": english.duration.seconds, "minutes": english.duration.minutes, "hours": english.duration.hours],
    ]
    func json(_ o: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }
    let counts = ["attention": totals.attention, "working": totals.working, "waiting": totals.waiting, "done": totals.done]
    return #"{"asOf":"2026-11-21T15:39:30Z","mode":"threads","counts":\#(json(counts)),"rows":[\#(statuses.map { rowJSON($0) }.joined(separator: ","))],"hidden":\#(json(hidden)),"text":\#(json(text))}"#
}
func snap(_ text: String) -> LiveSnapshot {
    guard case .success(.snapshot(let s)) = LiveDecoder.decode(Data(text.utf8)) else { fatalError("fixture did not decode: \(text)") }
    return s
}
let eight = snap(line(["input", "approval", "request", "limited", "failed", "working", "waiting", "done"]))
let six = snap(line(["approval", "input", "working", "working", "waiting", "done"]))
let four = snap(line(["approval", "input", "working", "done"], extraWorking: 3))
let nine = snap(line(["input", "approval", "request", "limited", "failed", "working", "waiting", "done"], extraDone: 1))
let reference = CGRect(x: 0, y: 0, width: 2240, height: 1260)
let surface = CardSurface.make(screen: reference)!

// MARK: Coordinate spaces
do {
    let panel = CGRect(x: 934, y: 300, width: 372, height: 328)
    let p = CGPoint(x: 1000, y: 410)
    eq(CardCoordinates.panelToScreen(CardCoordinates.screenToPanel(p, panel: panel), panel: panel), p, "screen<->panel round trip")
    eq(CardCoordinates.screenToPanel(p, panel: panel), CGPoint(x: 66, y: 110), "screen->panel")
    eq(CardCoordinates.panelToCard(CGPoint(x: 66, y: 110), cardHeight: 200), CGPoint(x: 66, y: 90), "panel(y up)->card(flipped)")
    eq(CardCoordinates.cardToPanel(CGPoint(x: 66, y: 90), cardHeight: 200), CGPoint(x: 66, y: 110), "card->panel")
    eq(CardCoordinates.panelToCard(CGPoint(x: 0, y: 0), cardHeight: 200), CGPoint(x: 0, y: 200), "panel origin is card bottom-left")
    let hit = CGRect(x: 934, y: 300, width: 372, height: 200)
    eq(CardCoordinates.screenToHit(p, hitFrame: hit), CGPoint(x: 66, y: 110), "screen->hit")
    eq(CardCoordinates.hitToScreen(CGPoint(x: 66, y: 110), hitFrame: hit), p, "hit->screen")
    let cg = CardCoordinates.screenToCG(hit, primaryHeight: 1260)
    eq(cg, CGRect(x: 934, y: 760, width: 372, height: 200), "AppKit->CG flips about the primary height")
    eq(CardCoordinates.cgToScreen(cg, primaryHeight: 1260), hit, "CG->AppKit")
    // Bottom-pinned: a panel point maps to the same hit point when the hit window is the painted card.
    let inPanel = CardCoordinates.screenToPanel(p, panel: panel), inHit = CardCoordinates.screenToHit(p, hitFrame: hit)
    eq(inPanel, inHit, "panel and hit share the bottom-left origin")
}

// MARK: Hit shape
do {
    let size = CGSize(width: 372, height: 200)
    check(CardHitShape.contains(CGPoint(x: 186, y: 100), size: size), "centre")
    check(!CardHitShape.contains(CGPoint(x: 0.5, y: 0.5), size: size), "bottom-left corner excluded")
    check(!CardHitShape.contains(CGPoint(x: 371.5, y: 199.5), size: size), "top-right corner excluded")
    check(!CardHitShape.contains(CGPoint(x: 0.5, y: 100), size: size), "rim inset excluded")
    check(CardHitShape.contains(CGPoint(x: 1.5, y: 100), size: size), "just inside left edge")
    check(!CardHitShape.contains(CGPoint(x: -1, y: 100), size: size), "outside left")
    check(!CardHitShape.contains(CGPoint(x: 186, y: 201), size: size), "outside top")
    check(!CardHitShape.contains(CGPoint(x: 5, y: 5), size: size), "corner zone (5,5) excluded with r=24 (centre 25,25)")
    check(CardHitShape.contains(CGPoint(x: 10, y: 10), size: size), "(10,10) is 21.2 pt from the corner centre: inside")
    check(CardHitShape.contains(CGPoint(x: 20, y: 20), size: size), "corner zone (20,20) inside")
    check(!CardHitShape.contains(CGPoint(x: 10, y: 10), size: .zero), "empty size")
    // Shorter hit rect with the same bottom edge is a subset of the taller painted shape (animation invariant).
    var escapes = 0
    for h in stride(from: 200.0, through: 328.0, by: 8.0) {
        for x in stride(from: 0.0, through: 372.0, by: 2.0) {
            for y in stride(from: 0.0, through: 200.0, by: 2.0) {
                let p = CGPoint(x: x, y: y)
                if CardHitShape.contains(p, size: size), !CardHitShape.contains(p, size: CGSize(width: 372, height: h)) { escapes += 1 }
            }
        }
    }
    eq(escapes, 0, "shorter bottom-pinned hit shape inside every taller card shape")
}

// MARK: Geometry: bands, hit rect never the max frame
do {
    eq(surface.capacity, 8, "reference capacity")
    eq(surface.panel, CGRect(x: 934, y: 300, width: 372, height: 372), "panel holds eight rows plus the show-more row")
    let h = CardMetrics.maxHeight
    let hit = surface.hitFrame(currentHeight: h)
    eq(hit, CGRect(x: 934, y: 300, width: 372, height: 228), "collapsed hit = painted card")
    check(hit.maxY < surface.panel.maxY, "the panel's transparent top is outside the hit rect")
    check(surface.violations(hit: hit, paintedHeight: h).isEmpty, "collapsed hit safe")
    check(surface.violations(hit: surface.panel, paintedHeight: h).contains("hit rect outside painted card"), "max frame as hit rect is rejected")
    check(surface.violations(hit: hit.offsetBy(dx: 0, dy: -12), paintedHeight: h).contains("hit rect near credential controls"), "lowered hit near auth rejected")
    check(surface.violations(hit: CGRect(x: 934, y: 300, width: 372, height: 700), paintedHeight: 700).contains("hit rect enters clock band"), "tall hit enters clock")
    check(surface.violations(hit: .zero, paintedHeight: h).contains("empty hit rect"), "empty rejected")
    for (w, hgt, cap) in [(2240.0, 1260.0, 8), (1470.0, 956.0, 8), (1280.0, 800.0, 6), (1280.0, 720.0, 5), (1920.0, 1080.0, 8)] {
        let screen = CGRect(x: 0, y: 0, width: w, height: hgt)
        guard let s = CardSurface.make(screen: screen) else { check(false, "surface \(w)x\(hgt)"); continue }
        eq(s.capacity, cap, "capacity \(w)x\(hgt)")
        let band = CardPlacement.safeBand(in: screen)
        for rows in [4, s.capacity] {
            let r = s.hitFrame(currentHeight: CardMetrics.height(rows: rows, overflow: true))
            check(s.violations(hit: r, paintedHeight: r.height).isEmpty, "safe \(w)x\(hgt) rows \(rows)")
            check(r.minY >= band.minY + CardPlacement.gapAboveControls - 0.5, "no overlap with credential band \(w)x\(hgt)")
        }
    }
    check(CardSurface.make(screen: CGRect(x: 0, y: 0, width: 1024, height: 500)) == nil, "fail closed when even 4 rows do not fit")
}

// MARK: Plans: resize / update / clear / overflow / trailing declutter
do {
    var d = CardDisplayState(capacity: 8)
    d.snapshot(eight)
    let c = CardPlan.make(eight, display: d, interactive: true)
    eq(c.shownRows, 4, "collapsed shows 4")
    eq(c.snapshot.rows.count, 8, "collapsed builds all 8 for the reveal")
    eq(c.disclosure, .collapsed, "right chevron")
    eq(c.snapshot.overflow, "4 more threads", "collapsed more-line: one total (8 threads, 4 shown)")
    eq(c.height, 228, "collapsed 228 pt")
    let unarmed = CardPlan.make(eight, display: d, interactive: false)
    eq(unarmed.disclosure, .none, "no chevron unless armed")
    eq(unarmed.height, c.height, "arming never resizes the card")
    eq(unarmed.snapshot.overflow, c.snapshot.overflow, "arming keeps the more-line")
    d.expand()
    let e = CardPlan.make(eight, display: d, interactive: true)
    eq(e.shownRows, 8, "expanded shows 8")
    eq(e.snapshot.overflow, "Show fewer", "nothing omitted: chevron + Show fewer")
    check(e.hasFooter, "footer kept for the chevron and Show fewer")
    eq(CardPlan.make(eight, display: d, interactive: false).snapshot.overflow, nil, "unarmed cards never say Show fewer")
    eq(e.height, CardMetrics.height(rows: 8, overflow: true), "expanded height with chevron footer")
    // Expanded but more exist than eight (totals 9): the more-line stays with the chevron.
    var d9 = CardDisplayState(capacity: 8); d9.snapshot(nine); d9.expand()
    eq(CardPlan.make(nine, display: d9, interactive: true).snapshot.overflow, "1 more thread", "expanded keeps real omissions")
    // Update while expanded to six rows: resize down, still expanded.
    d.snapshot(six)
    eq(d.mode, .expanded, "still more than four: stays expanded")
    let e6 = CardPlan.make(six, display: d, interactive: true)
    eq(e6.shownRows, 6, "resize to 6 rows")
    eq(e6.height, CardMetrics.height(rows: 6, overflow: true), "6-row height")
    eq(e6.snapshot.rows.count, 6, "built rows follow content")
    // Update to four rows: collapses, chevron gone, old layout (declutter).
    d.snapshot(four)
    eq(d.mode, .collapsed, "no rows beyond four: collapsed")
    let p4 = CardPlan.make(four, display: d, interactive: true)
    eq(p4.disclosure, .none, "no chevron with <= 4 rows")
    eq(p4.snapshot.overflow, "3 more threads", "more-line from totals")
    eq(p4.height, CardMetrics.height(rows: 4, overflow: true), "old collapsed height")
    let exact4 = snap(line(["approval", "input", "working", "done"]))
    d.snapshot(exact4)
    let px = CardPlan.make(exact4, display: d, interactive: true)
    check(!px.hasFooter, "exact four rows: no footer at all")
    eq(px.height, CardMetrics.height(rows: 4, overflow: false), "exact four height (old)")
    // Clear.
    d.cleared()
    eq(CardPlan.make(nil, display: d, interactive: true), CardPlan.empty, "clear -> empty plan")
    let empty = snap(line([]))
    eq(CardPlan.make(empty, display: d, interactive: true), CardPlan.empty, "empty snapshot -> empty plan")
    // Capacity 6 (1280x800): expanded shows six of eight and keeps the more-line.
    var d6 = CardDisplayState(capacity: 6); d6.snapshot(eight); d6.expand()
    let cap6 = CardPlan.make(eight, display: d6, interactive: true)
    eq(cap6.shownRows, 6, "capacity 6 shows 6")
    eq(cap6.snapshot.rows.count, 6, "capacity 6 builds 6")
    eq(cap6.snapshot.overflow, "2 more threads", "capacity 6 more-line")
    // An unarmed plan draws exactly the plain snapshot (same rows, text and height).
    var dl = CardDisplayState(capacity: 8); dl.snapshot(four)
    let plain = four.cardSnapshot(rowLimit: dl.rowLimit)
    let plan = CardPlan.make(four, display: dl, interactive: false)
    eq(plan.snapshot.rows, plain.rows, "unarmed rows")
    eq(plan.snapshot.overflow, plain.overflow, "unarmed more-line")
    eq(plan.height, CardMetrics.height(rows: plain.rows.count, overflow: plain.overflow != nil), "unarmed height")
}

// MARK: Plans: v2 projects mode, localized footer
do {
    let statuses = SessionStatus.allCases.map { "\"\($0.rawValue)\":\"\($0.shortLabel)\"" }.joined(separator: ",")
    let projects = (1...5).map { #"{"name":"P\#($0)","projectIcon":null,"attention":0,"attentionStatus":null,"working":1,"done":0}"# }
    let text = #"{"summary":["5 in Arbeit"],"updated":"Aktualisiert {time}","more":{"1":"1 weiteres Projekt"},"showFewer":"Weniger anzeigen","statuses":{\#(statuses)},"duration":{"seconds":"{count}s","minutes":"{count}m","hours":"{hours}h {minutes}m"},"agent":"Agent"}"#
    let p = snap(#"{"asOf":"2026-11-22T04:07:27Z","mode":"projects","counts":{"attention":0,"working":5,"waiting":0,"done":0},"rows":[],"projects":[\#(projects.joined(separator: ","))],"hidden":{"4":1},"text":\#(text)}"#)
    var d = CardDisplayState(capacity: 8)
    d.snapshot(p)
    let c = CardPlan.make(p, display: d, interactive: true)
    eq(c.disclosure, .collapsed, "five projects: expandable")
    eq(c.shownRows, 4, "four projects collapsed")
    eq(c.snapshot.projects.count, 5, "all five built for the reveal")
    eq(c.snapshot.rows, [], "no thread rows in projects mode")
    eq(c.snapshot.overflow, "1 weiteres Projekt", "localized more-line")
    d.expand()
    let e = CardPlan.make(p, display: d, interactive: true)
    eq(e.shownRows, 5, "expanded shows five")
    eq(e.snapshot.overflow, "Weniger anzeigen", "localized Show fewer")
    eq(e.height, CardMetrics.height(rows: 5, overflow: true), "five rows + footer")
}

// MARK: Animation
do {
    var d = CardDisplayState(capacity: 8); d.snapshot(eight)
    let from = CardPlan.make(eight, display: d, interactive: true); d.expand()
    let to = CardPlan.make(eight, display: d, interactive: true)
    let a = ExpandAnimation.make(from: from, to: to, reduceMotion: false)
    eq(a.duration, 0.26, "duration")
    eq(a.cardHeight(at: 0), 228, "starts collapsed")
    eq(a.cardHeight(at: 0.26), 372, "ends expanded")
    check(a.cardHeight(at: 0.13) > 228 && a.cardHeight(at: 0.13) < 372, "mid")
    var prev: CGFloat = 0
    var monotonic = true
    for i in 0...16 { let h = a.cardHeight(at: Double(i) / 60); if h < prev { monotonic = false }; prev = h }
    check(monotonic, "monotonic expand")
    eq(a.rowAlpha(index: 3, at: 0), 1, "first four opaque")
    eq(a.rowAlpha(index: 5, at: 0), 0, "row 6 hidden at start")
    eq(a.rowAlpha(index: 5, at: 0.26), 1, "row 6 shown at end")
    let back = ExpandAnimation.make(from: to, to: from, reduceMotion: false)
    eq(back.rowAlpha(index: 7, at: 0.26), 0, "collapse hides row 8")
    eq(surface.hitFrame(currentHeight: a.cardHeight(at: 0.13), animation: a).height, 228, "hit uses smaller endpoint while animating (expand)")
    eq(surface.hitFrame(currentHeight: back.cardHeight(at: 0.13), animation: back).height, 228, "hit uses smaller endpoint while animating (collapse)")
    let rm = ExpandAnimation.make(from: from, to: to, reduceMotion: true)
    eq(rm.duration, 0, "Reduce Motion: no duration")
    check(rm.isFinished(at: 0) && rm.cardHeight(at: 0) == 372, "Reduce Motion: final frame at once")
}

// MARK: LockSignal (fast user switching reads off console: inconclusive, never locked)
do {
    eq(LockSignal.from(session: [:]), .inconclusive, "empty")
    eq(LockSignal.from(session: ["kCGSSessionOnConsoleKey": NSNumber(value: false)]), .inconclusive, "off console")
    eq(LockSignal.from(session: ["kCGSSessionOnConsoleKey": NSNumber(value: true)]), .unlocked, "no lock key = unlocked")
    eq(LockSignal.from(session: ["kCGSSessionOnConsoleKey": NSNumber(value: true), "CGSSessionScreenIsLocked": NSNumber(value: true)]), .locked, "locked")
    eq(LockSignal.from(session: ["kCGSSessionOnConsoleKey": NSNumber(value: true), "CGSSessionScreenIsLocked": "yes"]), .inconclusive, "malformed")
}

// MARK: Gate
let ok = InteractionContext(enabled: true, lock: .locked, presenterLocked: true, cardShown: true, privateAttached: true,
                            occlusionVisible: true, geometryOK: true, capacity: 8, rowCount: 8, reduceMotion: false)
let down = PointerSample(kind: .leftDown, plain: true, insideShape: true)
let up = PointerSample(kind: .leftUp, plain: true, insideShape: true)
func armed(_ live: LiveSnapshot = eight) -> CardToggle {
    var t = CardToggle(capacity: 8)
    _ = t.snapshot(live)
    _ = t.setArea(surface.hitFrame(currentHeight: 228))
    eq(t.evaluate(ok), [.arm], "arms with a fully verified context")
    return t
}
do {
    var t = CardToggle(capacity: 8)
    _ = t.snapshot(eight)
    check(t.allowed(ok), "allowed")
    // Every single condition disarms.
    let breaks: [(String, (inout InteractionContext) -> Void)] = [
        ("disabled", { $0.enabled = false }), ("unlocked", { $0.lock = .unlocked }), ("inconclusive", { $0.lock = .inconclusive }),
        ("presenter unlocked", { $0.presenterLocked = false }), ("hidden", { $0.cardShown = false }),
        ("detached", { $0.privateAttached = false }), ("occluded", { $0.occlusionVisible = false }),
        ("geometry", { $0.geometryOK = false }), ("capacity 4", { $0.capacity = 4 }), ("four rows", { $0.rowCount = 4 }),
        ("cleared", { $0.rowCount = 0 }),
    ]
    for (name, mutate) in breaks {
        var c = ok; mutate(&c)
        check(!t.allowed(c), "\(name) not allowed")
        var a = armed()
        let out = a.evaluate(c)
        check(out.first.map { if case .disarm = $0 { true } else { false } } ?? false, "\(name): disarm action \(out)")
        check(!a.armed, "\(name): disarmed")
        eq(a.evaluate(c), [], "\(name): idempotent")
    }
    var a = armed()
    eq(a.evaluate(ok), [], "re-evaluate keeps arm (no churn)")
}
do {
    // Plain press+release inside toggles; animation blocks clicks until finished.
    var t = armed()
    eq(t.pointer(down, ok, now: 10), [.pressed], "press")
    eq(t.pointer(up, ok, now: 10.1), [.animate(toExpanded: true, reduceMotion: false)], "release expands")
    eq(t.display.mode, .expanded, "expanded")
    check(t.animating, "animating")
    eq(t.pointer(down, ok, now: 10.2), [.ignored("animating")], "press during animation ignored")
    t.animationFinished()
    eq(t.pointer(down, ok, now: 10.3), [.pressed], "press after animation")
    eq(t.pointer(up, ok, now: 10.35), [.ignored("too soon")], "toggle interval")
    eq(t.display.mode, .expanded, "too-soon release does not toggle")
    _ = t.pointer(down, ok, now: 10.6)
    eq(t.pointer(up, ok, now: 10.7), [.animate(toExpanded: false, reduceMotion: false)], "release collapses")
    eq(t.display.mode, .collapsed, "collapsed")
}
do {
    var t = armed()
    eq(t.pointer(PointerSample(kind: .leftDown, plain: false, insideShape: true), ok, now: 1), [.ignored("modifier held")], "modified press")
    eq(t.pointer(up, ok, now: 1.1), [.ignored("release without press")], "release after modified press")
    _ = t.pointer(down, ok, now: 2)
    eq(t.pointer(PointerSample(kind: .leftUp, plain: false, insideShape: true), ok, now: 2.1), [.ignored("modifier held")], "modified release")
    eq(t.pointer(PointerSample(kind: .leftDown, plain: true, insideShape: false), ok, now: 3), [.ignored("outside card shape")], "press outside shape")
    _ = t.pointer(down, ok, now: 4)
    eq(t.pointer(PointerSample(kind: .leftUp, plain: true, insideShape: false), ok, now: 4.1), [.ignored("released outside card shape")], "drag out cancels")
    _ = t.pointer(down, ok, now: 5)
    eq(t.pointer(PointerSample(kind: .other, plain: false, insideShape: false), ok, now: 5.05), [.ignored("not a plain left button")], "right/other button")
    eq(t.pointer(up, ok, now: 5.1), [.ignored("release without press")], "other button cancels the press")
    eq(t.display.mode, .collapsed, "nothing toggled")
}
do {
    // Stale: area change between press and release drops the click.
    var t = armed()
    _ = t.pointer(down, ok, now: 1)
    check(t.setArea(surface.hitFrame(currentHeight: 232)), "area changed")
    eq(t.pointer(up, ok, now: 1.1), [.ignored("release without press")], "press dropped by area change")
    // Same area re-applied does not drop.
    _ = t.pointer(down, ok, now: 2)
    check(!t.setArea(surface.hitFrame(currentHeight: 232)), "same area")
    eq(t.pointer(up, ok, now: 2.1), [.animate(toExpanded: true, reduceMotion: false)], "same area keeps the press")
    // Lock change between press and release drops it.
    var l = armed()
    _ = l.pointer(down, ok, now: 1)
    _ = l.lockChanged()
    eq(l.pointer(up, ok, now: 1.1), [.ignored("release without press")], "lock change drops the press")
    // Context goes bad between press and release: disarm, never toggle.
    var u = armed()
    _ = u.pointer(down, ok, now: 1)
    var unlocked = ok; unlocked.lock = .unlocked
    let r = u.pointer(up, unlocked, now: 1.1)
    check(r.first.map { if case .disarm = $0 { true } else { false } } ?? false, "unlocked at release disarms \(r)")
    eq(u.display.mode, .collapsed, "no toggle after unlock")
    // Unverified press disarms.
    var v = armed()
    var occluded = ok; occluded.occlusionVisible = false
    let pr = v.pointer(down, occluded, now: 1)
    check(pr.first.map { if case .disarm = $0 { true } else { false } } ?? false, "occluded press disarms \(pr)")
    // Not armed: nothing.
    var n = CardToggle(capacity: 8)
    _ = n.snapshot(eight)
    eq(n.pointer(down, ok, now: 1), [.ignored("not armed")], "unarmed press")
}
do {
    // Reduce Motion: toggle without animating state.
    var t = armed()
    var rm = ok; rm.reduceMotion = true
    _ = t.pointer(down, rm, now: 1)
    eq(t.pointer(up, rm, now: 1.1), [.animate(toExpanded: true, reduceMotion: true)], "reduce motion toggle")
    check(!t.animating, "no animating state under Reduce Motion")
    _ = t.pointer(down, rm, now: 1.5)
    eq(t.pointer(up, rm, now: 1.6), [.animate(toExpanded: false, reduceMotion: true)], "immediate re-toggle allowed after interval")
}
do {
    // Content updates while expanded.
    var t = armed()
    _ = t.pointer(down, ok, now: 1); _ = t.pointer(up, ok, now: 1.1); t.animationFinished()
    eq(t.snapshot(six), [], "six rows: stays expanded, no settle needed")
    eq(t.display.mode, .expanded, "expanded after resize")
    eq(t.snapshot(four), [.settle], "four rows: collapse at once")
    eq(t.display.mode, .collapsed, "collapsed")
    var c4 = ok; c4.rowCount = 4
    let d = t.evaluate(c4)
    eq(d, [.disarm("nothing hidden")], "then disarms: nothing to expand")
    // Snapshot during an animation stops it.
    var s = armed()
    _ = s.pointer(down, ok, now: 1); _ = s.pointer(up, ok, now: 1.1)
    eq(s.snapshot(eight), [.settle], "update mid-animation settles")
    check(!s.animating, "animation stopped")
    // Clear while expanded.
    var c = armed()
    _ = c.pointer(down, ok, now: 1); _ = c.pointer(up, ok, now: 1.1); c.animationFinished()
    eq(c.snapshot(nil), [.settle], "clear collapses")
    var cleared = ok; cleared.rowCount = 0; cleared.cardShown = false
    check(c.evaluate(cleared).contains(.disarm("card hidden")), "clear then hidden disarms")
    // Disarm while expanded collapses.
    var x = armed()
    _ = x.pointer(down, ok, now: 1); _ = x.pointer(up, ok, now: 1.1); x.animationFinished()
    var hidden = ok; hidden.cardShown = false
    eq(x.evaluate(hidden), [.disarm("card hidden"), .settle], "disarm collapses at once")
    eq(x.display.mode, .collapsed, "collapsed on disarm")
    // Lock change while expanded collapses.
    var y = armed()
    _ = y.pointer(down, ok, now: 1); _ = y.pointer(up, ok, now: 1.1); y.animationFinished()
    eq(y.lockChanged(), [.settle], "lock change collapses")
}
do {
    // Shutdown never re-arms.
    var t = armed()
    eq(t.shutdown("exit"), [.disarm("exit")], "shutdown disarms")
    eq(t.evaluate(ok), [], "finished: no re-arm")
    check(!t.allowed(ok), "finished never allowed")
    eq(t.shutdown("exit"), [], "idempotent")
}

// MARK: adoptAuxiliary (recording mock; nothing private is loaded)
final class Recorder: PrivateSpaceOperations {
    var calls: [String] = []
    func createSpace() -> UInt64 { calls.append("create"); return 7 }
    func setAbsoluteLevel(space: UInt64, level: Int32) { calls.append("level \(level)") }
    func showSpace(_ space: UInt64) { calls.append("show") }
    func addWindow(_ window: Int32, to space: UInt64) { calls.append("add \(window)") }
    func hideSpace(_ space: UInt64) { calls.append("hide") }
    func destroySpace(_ space: UInt64) -> Bool { calls.append("destroy"); return true }
}
do {
    let ops = Recorder()
    var p = PrivatePlacement()
    eq(p.adoptAuxiliary(window: 5, using: ops).failure, -1, "no space: fail closed")
    _ = p.attach(window: 4, using: ops)
    eq(p.adoptAuxiliary(window: 5, using: ops).failure, nil, "adopt into existing space")
    eq(ops.calls, ["create", "level 400", "show", "add 4", "add 5"], "same wrapper, same space; no new private call")
    eq(p.adoptAuxiliary(window: 0, using: ops).failure, -1, "invalid window")
}

print("interaction tests: \(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
