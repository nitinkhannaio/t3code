import CoreGraphics
import Foundation

// Minimal harness: compiled with Sources/Core only, so no AppKit, window server, or private code is touched.
var failures = 0
var passes = 0
func check(_ condition: Bool, _ message: @autoclosure () -> String, line: Int = #line) {
    if condition { passes += 1 } else { failures += 1; print("FAIL line \(line): \(message())") }
}
func eq<T: Equatable>(_ a: T, _ b: T, _ what: String, line: Int = #line) {
    check(a == b, "\(what): \(a) != \(b)", line: line)
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
// MARK: Presentation
do {
    eq(CardPresentation.summary(StatusCounts(attention: 1, working: 2)), "1 needs you · 2 working", "singular")
    eq(CardPresentation.summary(StatusCounts(working: 3)), "3 working", "nothing waiting")
    eq(CardPresentation.summary(StatusCounts(attention: 2)), "2 need you", "nothing working")
    eq(CardPresentation.summary(StatusCounts()), "Nothing running", "empty")

    eq(SessionStatus.allCases.map(\.rawValue), ["approval", "input", "request", "limited", "failed", "working", "waiting", "done"], "fixed wire order")
    eq(SessionStatus.allCases.map(\.shortLabel), ["Approval", "Input", "Request", "Limited", "Failed", "Working", "Waiting", "Done"], "simple labels")
    eq(SessionStatus.allCases.map(\.priority), Array(0..<8), "priority follows wire order")
    eq(SessionStatus.limited.accessibilityLabel, "Usage limit reached", "limit spoken in full")
    check(SessionStatus.allCases.filter { $0 != .limited }.allSatisfy { $0.accessibilityLabel == $0.shortLabel }, "other labels spoken as shown")
    eq(SessionStatus.allCases.filter(\.needsUser), [.approval, .input, .request, .limited, .failed], "attention group")
    eq(SessionStatus.allCases.filter(\.showsElapsed), [.working, .waiting], "only working and waiting show elapsed time")
    eq(SessionStatus.allCases.map(\.group), [.attention, .attention, .attention, .attention, .attention, .working, .waiting, .done], "groups")
    eq(CardPresentation.summary(StatusCounts(attention: 2, working: 1, waiting: 0, done: 1)), "2 need you · 1 working · 1 done", "positive totals only")
    eq(CardPresentation.summary(StatusCounts(attention: 0, working: 0, waiting: 2, done: 1)), "2 waiting · 1 done", "waiting and done")
    eq(CardPresentation.summary(StatusCounts(done: 1)), "1 done", "done only")
    let english = CardText.english(totals: StatusCounts(attention: 1, done: 4), hidden: [1, 9, 0])
    eq(english.more, [1: "1 more thread", 9: "9 more threads"], "fixture more-line: one total")
    eq(english.more(hidden: 9), "9 more threads", "more for a hidden count")
    eq(english.more(hidden: 0), nil, "nothing hidden: no more-line")
    eq(english.summary, ["1 needs you", "4 done"], "English summary parts")
    let tight = CardPresentation.summaryVariants(CardText.englishSummary(StatusCounts(attention: 12, working: 34, waiting: 56, done: 78)))
    eq(tight.count, 3, "summary has tighter fallbacks")
    check(tight.allSatisfy { $0.contains("78 done") && $0.contains("12 need you") }, "every fallback keeps every group, Done included")
    eq(tight[1], "12 need you\u{2009}·\u{2009}34 working\u{2009}·\u{2009}56 waiting\u{2009}·\u{2009}78 done", "thin-space tightening")
    eq(CardPresentation.summaryVariants(["1 done"]), ["1 done"], "single group has no variants")
    eq(CardPresentation.summaryVariants(["2 brauchen dich", "1 erledigt"])[0], "2 brauchen dich · 1 erledigt", "localized parts joined with \" · \"")
    eq(CardPresentation.summaryVariants(CardText.englishSummary(StatusCounts())), ["Nothing running"], "empty")
    eq(english.updated(time: "4:07 AM"), "Updated 4:07 AM", "updated template")
    eq(CardPresentation.timeText(t0, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!), "8:00\u{202F}AM", "header time: hours and minutes")
}

// MARK: Layout
do {
    eq(CardMetrics.height(rows: 4, overflow: true), 228, "max height (8 + 32 + 4 x 36 + 36 + 8): padding, header, rows, show-more row")
    eq(CardMetrics.height(rows: 3, overflow: false), 156, "short height (8 + 32 + 3 x 36 + 8)")
    eq(CardMetrics.height(rows: 1, overflow: false), 84, "one session hugs its row")
    eq(CardMetrics.titleX, 44, "title lane starts 18 + 16 + 10 from the card edge")
    eq(CardMetrics.padding + CardMetrics.rowInset, 18, "content sits 18 pt from the card edge")

    let screens: [(String, CGRect)] = [
        ("13in laptop", CGRect(x: 0, y: 0, width: 1470, height: 956)),
        ("14in laptop", CGRect(x: 0, y: 0, width: 1512, height: 982)),
        ("27in 5K", CGRect(x: 0, y: 0, width: 2560, height: 1440)),
        ("1280x800", CGRect(x: 0, y: 0, width: 1280, height: 800)),
        ("second display left/below", CGRect(x: -1920, y: -300, width: 1920, height: 1080)),
    ]
    for (name, screen) in screens {
        guard let frame = CardPlacement.lockFrame(screen: screen) else { check(false, "\(name) should fit"); continue }
        let band = CardPlacement.safeBand(in: screen)
        check(screen.contains(frame), "\(name): card on screen")
        check(frame.minY >= band.minY + CardPlacement.gapAboveControls - 0.5, "\(name): clear of unlock controls")
        check(frame.maxY <= band.maxY, "\(name): clear of clock")
        check(abs(frame.midX - screen.midX) <= 1, "\(name): centered")
        eq(frame.width, CardMetrics.width, "\(name): full width")
        eq(frame.height, CardMetrics.maxHeight, "\(name): card-sized, not full screen")
    }
    eq(CardPlacement.lockFrame(screen: CGRect(x: 0, y: 0, width: 1024, height: 480)), nil, "short screen refuses")
    eq(CardPlacement.lockFrame(screen: CGRect(x: 0, y: 0, width: 320, height: 900)), nil, "narrow screen refuses")
    let narrow = CardPlacement.lockFrame(screen: CGRect(x: 0, y: 0, width: 360, height: 900))
    eq(narrow?.width, 328, "narrow screen keeps 16pt gutters")
}

// MARK: Presenter state machine
do {
    var machine = PresenterStateMachine()
    eq(machine.handle(.started(locked: false)), [], "starts hidden")
    eq(machine.handle(.lockChanged(locked: true)), [], "locked but empty: stays hidden, nothing attached")
    check(!machine.shown && !machine.attached, "empty locked is hidden")
    eq(machine.handle(.screensWoke), [], "no reassert without a shown card")
    eq(machine.handle(.liveContent(true)), [.show, .attachPrivate], "content after lock: show, then attach")
    eq(machine.handle(.liveContent(true)), [], "repeat content only updates in place")
    eq(machine.handle(.lockChanged(locked: true)), [], "poll + notification are idempotent")
    eq(machine.handle(.screensWoke), [.reassertPrivate], "reassert on wake while shown")
    eq(machine.handle(.liveContent(false)), [.hide, .detachPrivate], "null clears while locked: hide, then detach")
    eq(machine.handle(.liveContent(true)), [.show, .attachPrivate], "new content re-shows")
    eq(machine.handle(.lockChanged(locked: false)), [.hide, .detachPrivate], "unlock hides")
    eq(machine.handle(.liveContent(true)), [], "content while unlocked stays hidden")
    check(!machine.shown, "never shown unlocked")
    eq(machine.handle(.lockChanged(locked: true)), [.show, .attachPrivate], "content before lock shows at lock")
    eq(machine.handle(.inputClosed), [.hide, .teardownPrivate, .exit(code: 0, reason: "Input closed.")], "EOF hides, tears down, exits")
    eq(machine.handle(.liveContent(true)), [], "nothing after exit")

    var interrupted = PresenterStateMachine()
    _ = interrupted.handle(.started(locked: false))
    _ = interrupted.handle(.liveContent(true))
    eq(interrupted.handle(.interrupted), [.teardownPrivate, .exit(code: 0, reason: "Interrupted.")], "interrupt while unlocked")

    var failed = PresenterStateMachine()
    _ = failed.handle(.started(locked: false))
    _ = failed.handle(.liveContent(true))
    _ = failed.handle(.lockChanged(locked: true))
    let failure = failed.handle(.privateFailed(code: 1000))
    eq(failure.first, .hide, "private failure hides first")
    check(failure.contains(.teardownPrivate), "private failure tears down")
    eq(failure.last, .exit(code: 3, reason: "SkyLight call failed (CGError 1000); hid the card and stopped."), "private failure exits")

    var startedLocked = PresenterStateMachine()
    eq(startedLocked.handle(.started(locked: true)), [.teardownPrivate, .exit(code: 2, reason: "Start this while the Mac is unlocked, then lock it.")], "refuse to start locked")
}

// MARK: Arguments
do {
    eq(try? Arguments.parse(["live-lock", "--private-skylight"]), .run(RunOptions()), "adaptive glass, no click by default")
    eq(try? Arguments.parse(["live-lock", "--private-skylight", "--expand-on-click", "--appearance", "light"]),
       .run(RunOptions(appearance: .light, expandOnClick: true)), "the product's flags; glass can be pinned")
    check((try? Arguments.parse(["live-lock"])) == nil, "private route needs the explicit flag")
    check((try? Arguments.parse(["live-lock", "--private-skylight", "--timeout", "60"])) == nil, "unknown flag")
    for removed in ["preview", "public-lock", "experimental-lock", "probe"] {
        check((try? Arguments.parse([removed])) == nil, "\(removed) is gone")
    }
    eq(try? Arguments.parse([]), .help, "no args is help")
    eq(try? Arguments.parse(["render-png", "--out", "x.png"]), .renderPNG(out: "x.png", appearance: .dark, sample: .mixed), "render")
    check((try? Arguments.parse(["render-png", "--out", "y.png", "--appearance", "auto"])) == nil, "auto render needs a backdrop")
    eq(try? Arguments.parse(["render-png", "--out", "y.png", "--appearance", "auto", "--backdrop", "w.heic"]),
       .renderPNG(out: "y.png", appearance: nil, sample: .mixed, backdrop: "w.heic"), "auto render from a backdrop")
    check(Arguments.isTestedOS(major: 26, minor: 2), "26.2 tested")
    check(Arguments.isTestedOS(major: 26, minor: 5), "26.5 tested")
    check(!Arguments.isTestedOS(major: 26, minor: 3), "26.3 untested")
    check(!Arguments.isTestedOS(major: 27, minor: 0), "27 untested")
}

// MARK: Private placement sequencing (recording mock; no SkyLight symbol is loaded or called)
final class RecordingSpaceOperations: PrivateSpaceOperations {
    var calls: [String] = []
    var nextSpace: UInt64 = 0x51
    var destroyExported = true
    func createSpace() -> UInt64 { calls.append("create"); return nextSpace }
    func setAbsoluteLevel(space: UInt64, level: Int32) { calls.append("level \(space) \(level)") }
    func showSpace(_ space: UInt64) { calls.append("show \(space)") }
    func addWindow(_ window: Int32, to space: UInt64) { calls.append("add \(window) \(space)") }
    func hideSpace(_ space: UInt64) { calls.append("hide \(space)") }
    func destroySpace(_ space: UInt64) -> Bool { calls.append("destroy \(space)"); return destroyExported }
}

do {
    let void = PrivateStepResult.voidCompleted
    let ops = RecordingSpaceOperations()
    var placement = PrivatePlacement()
    let attached = placement.attach(window: 42, using: ops)
    eq(ops.calls, ["create", "level 81 400", "show 81", "add 42 81"], "attach order and level 400")
    eq(attached.failure, nil, "void level/show/add completion never aborts")
    eq(attached.steps, [
        .init(step: .createSpace, result: .spaceID(81)),
        .init(step: .setAbsoluteLevel, result: void),
        .init(step: .showSpaces, result: void),
        .init(step: .addWindows, result: void),
    ], "attach logs each step separately")
    eq(PrivateStepRecord(step: .showSpaces, result: void).description, "SLSShowSpaces -> void call completed (no status returned)", "void step log line")
    eq(placement.space, 81, "space kept")

    ops.calls = []
    let again = placement.attach(window: 42, using: ops)
    eq(ops.calls, ["show 81", "add 42 81"], "re-lock reuses the space")
    eq(again.failure, nil, "re-attach succeeds")
    ops.calls = []
    eq(placement.reassert(window: 42, using: ops).failure, nil, "reassert succeeds")
    eq(ops.calls, ["show 81", "add 42 81"], "reassert is show + add")

    ops.calls = []
    let detached = placement.detach(using: ops)
    eq(ops.calls, ["hide 81"], "detach hides only")
    eq(detached, PrivatePlacementResult(steps: [.init(step: .hideSpaces, result: void)]), "detach completes without failure")

    ops.calls = []
    let torn = placement.teardown(using: ops)
    eq(ops.calls, ["hide 81", "destroy 81"], "teardown hides then destroys")
    eq(torn.failure, nil, "teardown never fails")
    eq(placement.space, 0, "teardown forgets the space")
    ops.calls = []
    eq(placement.teardown(using: ops), PrivatePlacementResult(), "second teardown is a no-op")
    eq(placement.detach(using: ops), PrivatePlacementResult(), "detach without a space is a no-op")
    eq(ops.calls, [], "no calls without a space")

    let missingDestroy = RecordingSpaceOperations()
    missingDestroy.destroyExported = false
    var optional = PrivatePlacement()
    _ = optional.attach(window: 7, using: missingDestroy)
    let skipped = optional.teardown(using: missingDestroy)
    eq(skipped.steps.last, .init(step: .destroySpace, result: .unavailable), "unexported destroy is reported, not fatal")
    eq(skipped.failure, nil, "unexported destroy is not a failure")

    let noSpace = RecordingSpaceOperations()
    noSpace.nextSpace = 0
    var refused = PrivatePlacement()
    let createFailed = refused.attach(window: 42, using: noSpace)
    eq(createFailed.failure, -2, "SLSSpaceCreate == 0 aborts")
    eq(noSpace.calls, ["create"], "nothing after a failed create")
    eq(refused.space, 0, "no space kept after a failed create")

    let untouched = RecordingSpaceOperations()
    var invalid = PrivatePlacement()
    eq(invalid.attach(window: 0, using: untouched).failure, -1, "invalid window aborts")
    eq(invalid.reassert(window: 42, using: untouched).failure, -1, "reassert without a space aborts")
    eq(untouched.calls, [], "aborts before any call")

    // Wire-up: a void completion keeps the card up; a known failure hides, tears down and exits 3.
    var ok = PresenterStateMachine()
    _ = ok.handle(.started(locked: false))
    _ = ok.handle(.liveContent(true))
    _ = ok.handle(.lockChanged(locked: true))
    if let code = attached.failure { _ = ok.handle(.privateFailed(code: code)) }
    check(ok.shown && ok.attached && !ok.finished, "void completion leaves the card shown and attached")
    var bad = PresenterStateMachine()
    _ = bad.handle(.started(locked: false))
    _ = bad.handle(.liveContent(true))
    _ = bad.handle(.lockChanged(locked: true))
    let stop = createFailed.failure.map { bad.handle(.privateFailed(code: $0)) } ?? []
    eq(stop, [.hide, .teardownPrivate, .exit(code: 3, reason: "SkyLight call failed (CGError -2); hid the card and stopped.")], "known failure stops")
}

// MARK: Lock geometry (credential and clock bands kept everywhere)
do {
    let imac = CGRect(x: 0, y: 0, width: 2240, height: 1260)
    let frame = CardPlacement.lockFrame(screen: imac)
    eq(frame?.minY, 300, "iMac 2240x1260 card bottom at y=300, clear of the profile photo")
    eq(CardPlacement.credentialBandHeight(screenHeight: 1260), 289.8, "credential band on the iMac")
    eq(CardPlacement.credentialBandHeight(screenHeight: 800), 220, "credential band floor on short screens")

    for height in stride(from: 600.0, through: 2200.0, by: 10.0) {
        for (width, originY) in [(1280.0, 0.0), (2560.0, -500.0)] {
            let screen = CGRect(x: 0, y: originY, width: width, height: height)
            guard let frame = CardPlacement.lockFrame(screen: screen) else {
                check(height < 700, "\(height): only very short screens refuse"); continue
            }
            let fromBottom = frame.minY - screen.minY
            check(fromBottom >= max(0.23 * height, 220) + 9.5, "\(height): clear of credential band (\(fromBottom))")
            check(frame.maxY <= screen.maxY - 0.30 * height + 0.5, "\(height): clear of clock band")
            check(screen.contains(frame), "\(height): on screen")
        }
    }
}

// MARK: Card fit inside the fixed panel, typography
do {
    let panel = CGRect(x: 0, y: 0, width: CardMetrics.width, height: CardMetrics.maxHeight)
    let two = CardMetrics.cardFrame(inPanel: panel, rows: 2, overflow: false)
    eq(two.minY, 0, "card pinned to the panel bottom (constant gap above credentials)")
    eq(two.height, CardMetrics.height(rows: 2, overflow: false), "card fitted to two rows")
    eq(CardMetrics.cardFrame(inPanel: panel, rows: 9, overflow: true).height, CardMetrics.maxHeight, "never taller than the panel")
    eq(CardMetrics.cardFrame(inPanel: panel, rows: 4, overflow: true), panel, "full card fills the panel")

    eq(CardTypography.title, .init(size: 14, weight: .medium, lineHeight: 20), "14/20 medium titles")
    eq(CardTypography.agentName, .init(size: 14, weight: .regular, lineHeight: 20), "14/20 regular agent name")
    eq(CardTypography.summary, .init(size: 12, weight: .medium, lineHeight: 16), "12pt medium summary")
    eq(CardTypography.time, .init(size: 12, weight: .regular, lineHeight: 16), "12pt regular time")
    eq(CardTypography.status, .init(size: 12, weight: .medium, lineHeight: 16), "12pt medium status")
    eq(CardTypography.overflow, .init(size: 14, weight: .regular, lineHeight: 20), "show-more text like an agent name")
}

// MARK: Live decoding
func data(_ text: String) -> Data { Data(text.utf8) }
let validLine = full(2, 3, 0, 0, rows: [
    #"{"status":"approval","provider":"codex","title":"Review plan","projectIcon":null}"#,
    #"{"status":"input","provider":"claudeAgent","title":null,"projectIcon":"data:image/png;base64,AAAA"}"#,
    #"{"status":"working","provider":"mystery","title":"<b>x</b>\n‮evil","projectIcon":null}"#,
    #"{"status":"working","provider":null,"title":"   ","projectIcon":null}"#,
], asOf: "\"2026-11-21T15:39:30.000Z\"")
func decodeError(_ text: String) -> LiveParseError? {
    if case .failure(let error) = LiveDecoder.decode(data(text)) { return error }
    return nil
}
func row(_ status: String, provider: String = "null", title: String = "\"t\"", icon: String = "null") -> String {
    #"{"status":"\#(status)","provider":\#(provider),"title":\#(title),"projectIcon":\#(icon)}"#
}
/// A threads line whose counts are spliced in raw, for the count-validation cases.
func message(attention: String = "1", working: String = "0", rows: [String]? = nil, asOf: String = "\"2026-11-21T15:39:30Z\"") -> String {
    full(min(max(Int(attention) ?? 0, 0), LiveLimits.maxCount), min(max(Int(working) ?? 0, 0), LiveLimits.maxCount), 0, 0, rows: rows ?? [row("approval")], asOf: asOf,
         counts: #""attention":\#(attention),"working":\#(working),"waiting":0,"done":0"#)
}
do {
    guard case .success(.snapshot(let live)) = LiveDecoder.decode(data(validLine)) else {
        check(false, "valid live line decodes"); throw CancellationError()
    }
    eq(live.asOf, Date(timeIntervalSince1970: 1_795_275_570), "asOf parsed (fractional ISO)")
    eq(live.rows.map(\.status), [.approval, .input, .working, .working], "selector order kept, not re-sorted")
    eq(live.rows.map(\.provider), [.brand(.codex), .brand(.claudeAgent), .neutral, .neutral], "bundled provider marks, neutral fallback")
    eq(live.rows.map(\.title), ["Review plan", nil, "<b>x</b> evil", nil], "plain-text titles, nil when hidden")
    eq(live.rows.map { $0.displayTitle(live.text) }, ["Review plan", "Claude", "<b>x</b> evil", "Agent"], "withheld title -> agent name, never \"Thread\"")
    eq(live.rows.map(\.titleIsFallback), [false, true, false, true], "fallback names are drawn secondary")
    check(live.rows.allSatisfy { $0.projectIcon == nil && $0.since == nil }, "no usable icon or since: agent mark, bare label")
    check(live.hasContent, "non-empty snapshot has content")
    let card = live.cardSnapshot()
    eq(card.summary, "2 need you · 3 working", "summary from the line's text")
    eq(card.overflow, "1 more thread", "more-line from the line's hidden counts")
    eq(card.rows.count, 4, "row cap")
    eq(card.asOf, live.asOf, "freshness is the selector's asOf")
} catch {}
do {
    eq(LiveDecoder.decode(data("null")), .success(.clear), "JSON null clears")
    eq(LiveDecoder.decode(data("  null \r")), .success(.clear), "null with whitespace / CR clears")
    if case .success(.snapshot(let s)) = LiveDecoder.decode(data(message())) { eq(s.asOf, Date(timeIntervalSince1970: 1_795_275_570), "asOf without fraction") }
    else { check(false, "whole-second asOf decodes") }

    if case .success(.snapshot(let empty)) = LiveDecoder.decode(data(message(attention: "0", rows: []))) {
        check(!empty.hasContent, "zero counts and no rows is empty")
    } else { check(false, "empty snapshot decodes") }
    if case .success(.snapshot(let summaryOnly)) = LiveDecoder.decode(data(message(attention: "2", rows: []))) {
        check(summaryOnly.hasContent, "counts without rows still have content")
    } else { check(false, "summary-only snapshot decodes") }

    eq(decodeError(""), .notJSON, "blank line invalid")
    eq(decodeError("hello"), .notJSON, "garbage invalid")
    eq(decodeError("[]"), .shape("message"), "array invalid")
    eq(decodeError("42"), .shape("message"), "number invalid")
    eq(decodeError(#"{"asOf":"x"}"#), .shape("mode"), "missing mode")
    eq(decodeError(message(asOf: "\"yesterday\"")), .timestamp, "bad timestamp")
    eq(decodeError(message(asOf: "17")), .shape("asOf"), "numeric asOf rejected")
    eq(decodeError(message(asOf: "\"" + String(repeating: "9", count: 80) + "\"")), .timestamp, "overlong timestamp")
    eq(live(message(attention: "-1", rows: []))?.totals.attention, 0, "negative count clamps")
    eq(live(message(attention: "10000", rows: []))?.totals.attention, LiveLimits.maxCount, "count ceiling clamps")
    eq(decodeError(message(attention: "1.5")), .shape("attention"), "fractional count")
    eq(decodeError(message(attention: "true")), .shape("attention"), "boolean count")
    eq(decodeError(message(attention: "\"1\"")), .shape("attention"), "string count")
    eq(decodeError(message(attention: "9", rows: (1...9).map { _ in row("input") })), .tooManyRows, "8-row wire cap enforced")
    // One malformed row is dropped; the rest of the card draws.
    for (bad, why) in [(row("pending"), "unknown status"), (row("DONE"), "statuses are lower-case"), (row("approval", title: "7"), "numeric title"),
                       (row("approval", provider: "[]"), "array provider"), ("5", "row must be an object"),
                       (row("approval", provider: "\"" + String(repeating: "p", count: 65) + "\""), "provider length"),
                       (row("approval", title: "\"" + String(repeating: "t", count: 2_001) + "\""), "title input length")] {
        eq(live(message(attention: "2", rows: [bad, row("input")]))?.rows.map(\.status), [.input], "\(why): row dropped")
    }
    eq(decodeError(message(rows: [row("approval", icon: "5")])), nil, "a non-string projectIcon is ignored, not a bad line")
    eq(decodeError(#"{"asOf":"2026-11-21T15:39:30Z","mode":"threads","counts":{"attention":1,"working":0,"waiting":0,"done":0},"rows":{},"text":{}}"#),
       .shape("rows"), "rows must be an array")
    let huge = "{\"pad\":\"" + String(repeating: "x", count: LiveLimits.maxLineBytes) + "\"}"
    eq(decodeError(huge), .tooLong, "oversized line rejected before parsing")
}

// MARK: Live text
do {
    eq(LiveText.title(nil), nil, "null title stays withheld")
    eq(LiveText.title(" \n\t "), nil, "blank title counts as withheld")
    eq(LiveText.title("a\u{0}b\u{7}c\u{2028}d"), "a b c d", "controls and separators become spaces")
    eq(LiveText.title("x\u{202E}y\u{200B}z\u{FEFF}"), "xyz", "bidi overrides and invisible format chars removed")
    eq(LiveText.title("  many   spaces  "), "many spaces", "whitespace collapsed")
    let long = LiveText.title(String(repeating: "é", count: 500))
    eq(long?.count, LiveLimits.maxTitleCharacters, "display title capped")
    check(long?.hasSuffix("…") == true, "capped title ends with ellipsis")
    eq(LiveText.title("**bold** [link](x) `code`"), "**bold** [link](x) `code`", "markup is shown literally, never interpreted")
}

// MARK: Live line framing (bounded)
do {
    var framer = LineFramer()
    eq(framer.feed(data("ab")), [], "partial line buffered")
    eq(framer.feed(data("c\nde")), [.line(data("abc"))], "line completed across chunks")
    eq(framer.feed(data("f\n\ng\n")), [.line(data("def")), .line(data("")), .line(data("g"))], "several lines per chunk")
    eq(framer.buffered, 0, "nothing left over")

    var big = LineFramer()
    let chunk = Data(repeating: UInt8(ascii: "x"), count: 4_096)
    var frames: [LineFrame] = []
    for _ in 0..<20 { frames += big.feed(chunk) }
    eq(frames, [.oversized], "oversized line reported once")
    check(big.buffered <= LiveLimits.maxLineBytes, "buffer stays bounded while discarding (\(big.buffered))")
    eq(big.feed(data("tail\nnull\n")), [.line(data("null"))], "framing resumes after the oversized line")
    eq(big.buffered, 0, "buffer cleared")

    var exact = LineFramer()
    let maxLine = Data(repeating: UInt8(ascii: "y"), count: LiveLimits.maxLineBytes)
    eq(exact.feed(maxLine + data("\n")), [.line(maxLine)], "a line of exactly the limit is accepted")
}

// MARK: Done / waiting groups, 8-row wire, hidden counts
/// A threads line with the app's English copy; hidden counts are the totals minus the rows shown.
func full(_ a: Int, _ w: Int, _ wt: Int, _ d: Int, rows: [String], asOf: String = "\"2026-11-21T15:39:30Z\"", counts: String? = nil) -> String {
    let totals = StatusCounts(attention: a, working: w, waiting: wt, done: d)
    var hidden: [String: Int] = [:]
    for k in 4...8 where totals.total - min(k, rows.count) > 0 { hidden[String(k)] = totals.total - min(k, rows.count) }
    let english = CardText.english(totals: totals, hidden: hidden.values)
    let text: [String: Any] = [
        "summary": english.summary, "updated": english.updated, "showFewer": english.showFewer, "agent": english.agent,
        "more": Dictionary(uniqueKeysWithValues: english.more.map { (String($0.key), $0.value) }),
        "statuses": Dictionary(uniqueKeysWithValues: english.statuses.map { ($0.key.rawValue, $0.value) }),
        "duration": ["seconds": english.duration.seconds, "minutes": english.duration.minutes, "hours": english.duration.hours],
    ]
    func json(_ o: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }
    let countsJSON = counts ?? #""attention":\#(a),"working":\#(w),"waiting":\#(wt),"done":\#(d)"#
    return #"{"asOf":\#(asOf),"mode":"threads","counts":{\#(countsJSON)},"rows":[\#(rows.joined(separator: ","))],"hidden":\#(json(hidden)),"text":\#(json(text))}"#
}
func live(_ text: String) -> LiveSnapshot? {
    if case .success(.snapshot(let s)) = LiveDecoder.decode(data(text)) { return s }
    return nil
}
do {
    let all = SessionStatus.allCases.map { row($0.rawValue) }
    guard let s = live(full(5, 1, 1, 1, rows: all)) else { check(false, "all eight statuses decode"); throw CancellationError() }
    eq(s.totals, StatusCounts(attention: 5, working: 1, waiting: 1, done: 1), "totals")
    eq(s.rows.map(\.status), SessionStatus.allCases, "rows kept in wire order")
    check(s.hasMoreRows, "more than four rows")
    let collapsed = s.cardSnapshot()
    eq(collapsed.rows.count, 4, "collapsed default")
    eq(collapsed.summary, "5 need you · 1 working · 1 waiting · 1 done", "summary from totals, not rows")
    eq(collapsed.overflow, "4 more threads", "collapsed omitted = totals - shown prefix")
    let expanded = s.cardSnapshot(rowLimit: 8)
    eq(expanded.rows.count, 8, "expanded shows all eight")
    eq(expanded.overflow, nil, "nothing omitted when every row is shown")
    eq(expanded.summary, collapsed.summary, "summary independent of display mode")
    eq(s.cardSnapshot(rowLimit: 6).overflow, "2 more threads", "partial capacity")
    eq(s.cardSnapshot(rowLimit: 99).rows.count, 8, "never more than eight")

    // Beyond the wire: totals larger than the rows still count as hidden.
    let beyond = live(full(12, 0, 0, 0, rows: (1...8).map { _ in row("input") }))
    eq(beyond?.cardSnapshot().overflow, "8 more threads", "collapsed: 4 wire rows + 4 beyond")
    eq(beyond?.cardSnapshot(rowLimit: 8).overflow, "4 more threads", "expanded: only the rows beyond the wire")
    check(live(full(0, 0, 0, 0, rows: []))?.hasContent == false, "all-zero new payload is empty")
    check(live(full(0, 0, 0, 2, rows: []))?.hasContent == true, "done counts alone are content")
} catch {}

// MARK: Display state (collapsed 4 / expanded <= 8); resets on lock, unlock, clear, and no more rows
do {
    let eight = live(full(8, 0, 0, 0, rows: (1...8).map { _ in row("input") }))!
    let four = live(full(4, 0, 0, 0, rows: (1...4).map { _ in row("input") }))!
    let empty = live(full(0, 0, 0, 0, rows: []))!

    var d = CardDisplayState(capacity: 8)
    eq(d.mode, .collapsed, "starts collapsed")
    check(!d.expand(), "nothing to expand before a snapshot")
    d.snapshot(eight)
    check(d.canExpand, "eight rows can expand")
    check(d.expand(), "expand")
    eq(d.rowLimit, 8, "expanded row limit")
    eq(eight.cardSnapshot(rowLimit: d.rowLimit).rows.count, 8, "expanded snapshot")
    check(!d.expand(), "expand is idempotent")
    d.snapshot(eight)
    eq(d.mode, .expanded, "same-size update keeps the expanded view")
    d.snapshot(four)
    eq(d.mode, .collapsed, "collapses when no more rows")
    d.snapshot(eight); d.expand(); d.lockChanged()
    eq(d.mode, .collapsed, "lock change resets")
    d.expand(); d.cleared()
    eq(d.mode, .collapsed, "clear resets")
    check(!d.canExpand, "clear forgets the extra rows")
    d.snapshot(eight); d.expand(); d.snapshot(empty)
    eq(d.mode, .collapsed, "empty snapshot resets")
    d.snapshot(eight); d.expand(); check(d.collapse(), "collapse"); eq(d.rowLimit, 4, "collapsed limit")

    var short = CardDisplayState(capacity: 6)
    short.snapshot(eight); short.expand()
    eq(short.rowLimit, 6, "expanded is bounded by the placed capacity")
    var none = CardDisplayState(capacity: 4)
    none.snapshot(eight)
    check(!none.expand(), "no expansion when only four rows fit")
    eq(CardDisplayState(capacity: 20).capacity, 8, "capacity clamped to eight")
    eq(CardDisplayState(capacity: 1).capacity, 4, "capacity floor four")
}

// MARK: Lock layout with up to eight rows: same bottom anchor, clock band kept
do {
    eq(CardMetrics.expandedMaxHeight, 372, "eight-row height (8 + 32 + 8 x 36 + 36 + 8)")
    let panel8 = CGRect(x: 0, y: 0, width: CardMetrics.width, height: CardMetrics.expandedMaxHeight)
    eq(CardMetrics.cardFrame(inPanel: panel8, rows: 8, overflow: true), panel8, "eight rows fill the tall panel")
    eq(CardMetrics.cardFrame(inPanel: panel8, rows: 4, overflow: false).minY, 0, "collapsed card stays pinned to the bottom")

    let imac = CGRect(x: 0, y: 0, width: 2240, height: 1260)
    let layout = CardPlacement.lockLayout(screen: imac)
    eq(layout?.rowCapacity, 8, "iMac holds eight rows")
    eq(layout?.frame.minY, CardPlacement.lockFrame(screen: imac)?.minY, "same bottom (y=300) as the collapsed frame")
    for height in stride(from: 600.0, through: 2200.0, by: 10.0) {
        for (width, originY) in [(1280.0, 0.0), (2560.0, -500.0), (360.0, 0.0)] {
            let screen = CGRect(x: 0, y: originY, width: width, height: height)
            guard let l = CardPlacement.lockLayout(screen: screen) else {
                check(CardPlacement.lockFrame(screen: screen) == nil, "\(height): layout refuses only where collapsed refuses"); continue
            }
            let fromBottom = l.frame.minY - screen.minY
            check(fromBottom >= max(0.23 * height, 220) + 9.5, "\(height): clear of credential band")
            check(l.frame.maxY <= screen.maxY - 0.30 * height + 0.5, "\(height): clear of clock band")
            check((4...8).contains(l.rowCapacity), "\(height): capacity 4...8")
            eq(l.frame.height, CardMetrics.height(rows: l.rowCapacity, overflow: true), "\(height): panel fits capacity")
            check(screen.contains(l.frame), "\(height): on screen")
        }
    }
    eq(CardPlacement.lockLayout(screen: CGRect(x: 0, y: 0, width: 1024, height: 800))?.rowCapacity, 6, "short screen: dynamic capacity")
    eq(CardPlacement.lockLayout(screen: CGRect(x: 0, y: 0, width: 1024, height: 700))?.rowCapacity, 4, "shorter screen: collapsed only")
    eq(CardPlacement.lockLayout(screen: CGRect(x: 0, y: 0, width: 1024, height: 480))?.rowCapacity, nil, "too short refuses")
}

// MARK: Provider icons (bundled T3 artwork)
do {
    // Every provider T3 can name must have a mark here; read the app's own list so a new provider fails loudly.
    let contracts = "../../packages/contracts/src/model.ts"
    if let source = try? String(contentsOfFile: contracts, encoding: .utf8),
       let start = source.range(of: "PROVIDER_DISPLAY_NAMES"), let end = source.range(of: "};", range: start.upperBound..<source.endIndex) {
        let names = source[start.upperBound..<end.lowerBound].split(separator: "\n").compactMap { line -> String? in
            guard let quote = line.range(of: "]: \"") else { return nil }
            return String(line[quote.upperBound...].prefix { $0 != "\"" })
        }
        check(!names.isEmpty, "read PROVIDER_DISPLAY_NAMES from \(contracts)")
        for name in names {
            check(ProviderDriver.allCases.contains { $0.displayName == name },
                  "T3 provider \"\(name)\" (\(contracts) PROVIDER_DISPLAY_NAMES) has no mark: add a ProviderDriver case and its PNGs to ProviderIconData.swift")
        }
    } else {
        check(false, "could not read PROVIDER_DISPLAY_NAMES from \(contracts) (run tests from native/lock-screen)")
    }
    let kinds = ProviderDriver.allCases.map(\.rawValue)
    eq(Set(ProviderIconData.pngBase64.keys), Set(kinds), "artwork table covers exactly the known drivers")
    for kind in kinds { eq(ProviderMark.forProvider(kind), .brand(ProviderDriver(rawValue: kind)!), "maps \(kind)") }
    eq(ProviderMark.forProvider("CODEX"), .brand(.codex), "case-insensitive")
    eq(ProviderMark.forProvider("claude"), .brand(.claudeAgent), "claude alias kept")
    eq(ProviderMark.forProvider("claudeCode"), .brand(.claudeAgent), "claudeCode alias kept")
    for unknown in [nil, "", "gemini", "openaiCompatible", "acp", " codex"] as [String?] {
        eq(ProviderMark.forProvider(unknown), .neutral, "unknown/missing stays unbranded: \(String(describing: unknown))")
    }

    // Each entry: valid 32x32 8-bit RGBA PNG with some non-transparent pixel data; distinct artwork per driver.
    func be32(_ d: Data, _ o: Int) -> Int { d[o..<o + 4].reduce(0) { $0 << 8 | Int($1) } }
    var total = 0
    for theme in ["dark", "light"] {
        var seen = Set<Data>()
        for kind in kinds {
            guard let pair = ProviderIconData.pngBase64[kind],
                  let png = Data(base64Encoded: theme == "dark" ? pair.dark : pair.light) else { check(false, "\(kind) \(theme) decodes"); continue }
            total += png.count
            check(png.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]), "\(kind) \(theme) PNG signature")
            check(png.count > 33 && String(decoding: png[12..<16], as: UTF8.self) == "IHDR", "\(kind) \(theme) IHDR")
            eq(be32(png, 16), 32, "\(kind) \(theme) width"); eq(be32(png, 20), 32, "\(kind) \(theme) height")
            eq(png[24], 8, "\(kind) \(theme) 8-bit"); eq(png[25], 6, "\(kind) \(theme) RGBA")
            check(seen.insert(png).inserted, "\(kind) \(theme) distinct from other providers")
        }
    }
    check(total < 24_000, "decoded artwork bounded (\(total) bytes)")

    for kind in kinds {
        guard case .success(.snapshot(let s)) = LiveDecoder.decode(data(message(rows: [row("approval", provider: "\"\(kind)\"")]))) else { check(false, "live \(kind) decodes"); continue }
        eq(s.rows.first?.provider, .brand(ProviderDriver(rawValue: kind)!), "live NDJSON provider \(kind) -> bundled icon")
    }
}

// MARK: Row wire fields: since and projectIcon (best effort, never a bad line)
do {
    let png1 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP4z8DwHwAFAAH/VscvDQAAAABJRU5ErkJggg=="
    let tooWide = "iVBORw0KGgoAAAANSUhEUgAAAQEAAAABCAYAAADemxtJAAAAFElEQVR42mP4z8DwfxSP4lE8cjEAPEsAHY84jCsAAAAASUVORK5CYII="
    let widest = "iVBORw0KGgoAAAANSUhEUgAAAQAAAAACCAYAAAC3zQLZAAAAHUlEQVR42mP4z8DwfxSP4lE8MjHDaCCM4lE8cjEA8078LoNbRxIAAAAASUVORK5CYII="
    let headerOnly = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ"
    func iconRow(_ icon: String) -> CardRow? {
        live(full(1, 0, 0, 0, rows: [#"{"status":"approval","provider":"codex","title":"t","projectIcon":\#(icon)}"#]))?.rows.first
    }
    /// png1 with a tEXt chunk grown to the longest data URI of at most `length` characters (base64 comes in 4s).
    func paddedURI(_ length: Int) -> String {
        func crc32(_ bytes: [UInt8]) -> UInt32 {
            var c: UInt32 = 0xFFFF_FFFF
            for b in bytes { c ^= UInt32(b); for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 } }
            return ~c
        }
        let base = [UInt8](Data(base64Encoded: png1)!)
        let textLength = (length - ProjectIcon.prefix.count) / 4 * 3 - base.count - 12
        let body = Array("tEXt".utf8) + Array("c".utf8) + [0] + [UInt8](repeating: 0x61, count: textLength - 2)
        func be(_ v: UInt32) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: v >> $0) } }
        let chunk = be(UInt32(textLength)) + body + be(crc32(body))
        return ProjectIcon.prefix + Data(Array(base[..<33]) + chunk + Array(base[33...])).base64EncodedString()
    }
    eq(paddedURI(LiveLimits.maxProjectIconCharacters).count, 6_142, "longest URI within the cap")
    eq(paddedURI(LiveLimits.maxProjectIconCharacters + 4).count, 6_146, "shortest URI past the cap")
    eq(iconRow("\"\(paddedURI(LiveLimits.maxProjectIconCharacters))\"")?.projectIcon != nil, true, "URI within the cap accepted")
    let valid = iconRow("\"data:image/png;base64,\(png1)\"")
    eq(valid?.projectIcon, Data(base64Encoded: png1), "valid PNG data URI -> PNG bytes")
    eq(iconRow("\"data:image/png;base64,\(widest)\"")?.projectIcon, Data(base64Encoded: widest), "256 px wide accepted")
    for (icon, why) in [
        ("null", "null"), ("5", "number"), ("{}", "object"), ("\"\"", "empty string"),
        ("\"data:image/jpeg;base64,\(png1)\"", "not PNG mime"), ("\"https://example.com/icon.png\"", "URL"),
        ("\"data:image/png;base64,@@@@\"", "not base64"), ("\"data:image/png;base64,AAAA\"", "not a PNG"),
        ("\"data:image/png;base64,\(headerOnly)\"", "header without image data"),
        ("\"data:image/png;base64,\(tooWide)\"", "257 px wide: refused before decoding"),
        ("\"\(paddedURI(LiveLimits.maxProjectIconCharacters + 4))\"", "one base64 quantum over 6144 characters"),
    ] {
        check(iconRow(icon) != nil, "\(why): line still decodes")
        eq(iconRow(icon)?.projectIcon, nil, "\(why): falls back to the agent mark")
    }
    let missing = live(full(0, 1, 0, 0, rows: [#"{"status":"working","provider":"codex","title":"t"}"#]))
    check(missing != nil && missing?.rows.first?.projectIcon == nil && missing?.rows.first?.since == nil, "rows without since/projectIcon decode")

    func sinceRow(_ status: String, _ since: String) -> CardRow? {
        let (a, w, wt, d) = status == "working" ? (0, 1, 0, 0) : status == "waiting" ? (0, 0, 1, 0) : status == "done" ? (0, 0, 0, 1) : (1, 0, 0, 0)
        return live(full(a, w, wt, d, rows: [#"{"status":"\#(status)","provider":"codex","title":"t","since":\#(since),"projectIcon":null}"#]))?.rows.first
    }
    let started = Date(timeIntervalSince1970: 1_795_274_310) // 21 minutes before the fixture asOf
    eq(sinceRow("working", "\"2026-11-21T15:18:30Z\"")?.since, started, "working since")
    eq(sinceRow("waiting", "\"2026-11-21T15:18:30.000Z\"")?.since, started, "waiting since (fractional)")
    for status in ["approval", "input", "failed", "done"] {
        check(sinceRow(status, "\"2026-11-21T15:18:30Z\"") != nil, "\(status) with since decodes")
        eq(sinceRow(status, "\"2026-11-21T15:18:30Z\"")?.since, nil, "\(status) ignores since")
    }
    for (since, why) in [("\"soon\"", "unparseable"), ("5", "number"), ("null", "null"), ("\"" + String(repeating: "9", count: 80) + "\"", "overlong")] {
        check(sinceRow("working", since) != nil, "\(why) since: line still decodes")
        eq(sinceRow("working", since)?.since, nil, "\(why) since -> no elapsed time")
    }
    // A full eight-row line with the largest icons still fits the 64 KiB line limit.
    eq(LiveLimits.maxLineBytes, 64 * 1024, "line limit")
    check(LiveLimits.maxRows * (LiveLimits.maxProjectIconCharacters + 1_024) < LiveLimits.maxLineBytes, "eight max icons with a KiB of other fields each fit a line")
}

// MARK: Status lane text and elapsed time (sidebar format, boundary redraws)
do {
    let cases: [(TimeInterval, String, TimeInterval)] = [
        (-30, "0s", 1), (0, "0s", 1), (0.9, "0s", 1), (1, "1s", 2), (59, "59s", 60), (59.99, "59s", 60),
        (60, "1m", 120), (119, "1m", 120), (21 * 60 + 5, "21m", 22 * 60), (3_599, "59m", 3_600),
        (3_600, "1h 0m", 3_660), (3_660, "1h 1m", 3_720), (2 * 3_600 + 5 * 60 + 59, "2h 5m", 2 * 3_600 + 6 * 60), (86_399, "23h 59m", 86_400),
        (90_000, "25h 0m", 90_060),
    ]
    for (elapsed, text, next) in cases {
        eq(CardPresentation.elapsedText(elapsed), text, "elapsed \(elapsed)")
        eq(CardPresentation.nextElapsedBoundary(elapsed), next, "next boundary after \(elapsed)")
        check(CardPresentation.elapsedText(next) != text, "label changes at its boundary (\(elapsed) -> \(next))")
        if next - 0.001 > max(elapsed, 0) { eq(CardPresentation.elapsedText(next - 0.001), text, "label holds until the boundary (\(elapsed))") }
    }
    let since = t0
    let working = CardRow(status: .working, title: "t", provider: .brand(.codex), since: since)
    eq(working.statusText(now: since.addingTimeInterval(21 * 60)), "Working 21m", "working label with elapsed time")
    eq(working.nextStatusChange(after: since.addingTimeInterval(21 * 60 + 10)), since.addingTimeInterval(22 * 60), "redraw at the next minute")
    eq(working.nextStatusChange(after: since.addingTimeInterval(5)), since.addingTimeInterval(6), "redraw at the next second under a minute")
    eq(CardRow(status: .waiting, title: nil, provider: .neutral, since: since).statusText(now: since.addingTimeInterval(360)), "Waiting 6m", "waiting label")
    eq(CardRow(status: .working, title: nil, provider: .neutral).statusText(now: since), "Working", "no since: bare label")
    eq(CardRow(status: .working, title: nil, provider: .neutral).nextStatusChange(after: since), nil, "no since: no redraws")
    eq(CardRow(status: .done, title: nil, provider: .neutral, since: since).statusText(now: since.addingTimeInterval(60)), "Done", "done never shows elapsed")
    eq(CardRow(status: .done, title: nil, provider: .neutral, since: since).nextStatusChange(after: since), nil, "done never redraws")
    eq(CardRow(status: .limited, title: nil, provider: .neutral).statusText(now: since), "Limited", "Limited, not Limit")
    eq(CardRow(status: .done, title: nil, provider: .brand(.claudeAgent)).displayTitle(), "Claude", "agent name")
    eq(CardRow(status: .done, title: nil, provider: .neutral).displayTitle(), "Agent", "unknown agent name")
    var german = CardText.english
    german.agent = "Agent:in"
    german.statuses[.working] = "In Arbeit"
    german.duration = CardText.Durations(seconds: "{count} Sek.", minutes: "{count} Min.", hours: "{hours} Std. {minutes} Min.")
    eq(CardRow(status: .done, title: nil, provider: .neutral).displayTitle(german), "Agent:in", "unknown agent name from text")
    eq(CardRow(status: .done, title: nil, provider: .brand(.codex)).displayTitle(german), "Codex", "provider names are not translated")
    eq(working.statusText(now: since.addingTimeInterval(65 * 60), text: german), "In Arbeit 1 Std. 5 Min.", "localized label and hours template")
    eq(working.statusText(now: since.addingTimeInterval(45), text: german), "In Arbeit 45 Sek.", "seconds template")
    eq(working.statusText(now: since.addingTimeInterval(21 * 60), text: german), "In Arbeit 21 Min.", "minutes template")
}

// MARK: Lucide glyphs (verbatim lucide-react 0.564.0 data, parsed to CGPath)
do {
    eq(SessionStatus.allCases.map(\.glyph), [.shieldQuestionMark, .messageCircleQuestionMark, .userRound, .circleAlert, .circleAlert,
                                             .circleDashed, .circleDotDashed, .circleCheck], "sidebar status icons")
    if let box = T3Mark.path?.boundingBoxOfPath {
        check(T3Mark.viewBox.contains(box), "T3 mark fits its viewBox (\(box))")
    } else {
        check(false, "T3 mark parses")
    }
    for glyph in LucideGlyph.allCases {
        guard let path = glyph.path else { check(false, "\(glyph) parses"); continue }
        let box = path.boundingBoxOfPath
        check(!box.isEmpty && box.minX >= 0.9 && box.minY >= 0.9 && box.maxX <= 23.1 && box.maxY <= 23.1, "\(glyph) inside the 24 grid with room for the stroke (\(box))")
    }
    // Arc direction: the top dash of CircleDashed bulges up to the circle (y = 2), not down toward the centre.
    let dash = SVGPath.parse("M10.1 2.182a10 10 0 0 1 3.8 0")?.boundingBoxOfPath
    check(dash.map { $0.minY < 2.01 && $0.maxY <= 2.19 } == true, "arc sweep follows SVG (\(String(describing: dash)))")
    // Large-arc flag: MessageCircle's body is most of a circle of radius 10 around (12, 12).
    let bubble = SVGPath.parse("M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719")?.boundingBoxOfPath
    check(bubble.map { abs($0.minY - 2) < 0.05 && abs($0.maxX - 22) < 0.05 } == true, "large arc spans the circle (\(String(describing: bubble)))")
    let chevron = SVGPath.parse("m9 18 6-6-6-6")?.boundingBoxOfPath
    eq(chevron, CGRect(x: 9, y: 6, width: 6, height: 12), "relative implicit lineto")
    eq(SVGPath.parse("M12 17h.01")?.boundingBoxOfPath.width.rounded(.up), 1, "dot: zero-ish horizontal line")
    check(SVGPath.parse("M1 1 Q2 2 3 3") == nil, "unsupported command refused")
    check(SVGPath.parse("1 1") == nil, "numbers before any command refused")
    check(SVGPath.parse("M0 0a1 2 0 0 1 2 0") == nil, "elliptical arcs refused")
}

// MARK: Wire v2 (mode, projects, hidden, localized text)
func v2Text(more: [Int: String] = [:], drop: String? = nil, override: [String: Any] = [:]) -> [String: Any] {
    var text: [String: Any] = [
        "summary": ["2 brauchen dich", "3 in Arbeit"], "updated": "Aktualisiert {time}",
        "more": Dictionary(uniqueKeysWithValues: more.map { (String($0.key), $0.value) }), "showFewer": "Weniger anzeigen",
        "statuses": Dictionary(uniqueKeysWithValues: SessionStatus.allCases.map { ($0.rawValue, "DE-" + $0.shortLabel) }),
        "duration": ["seconds": "{count} Sek.", "minutes": "{count} Min.", "hours": "{hours} Std. {minutes} Min."], "agent": "Agent:in",
    ]
    if let drop { text.removeValue(forKey: drop) }
    for (k, v) in override { text[k] = v }
    return text
}
func v2(_ mode: String = "threads", counts: [String: Any] = ["attention": 2, "working": 3, "waiting": 0, "done": 0], rows: [Any] = [],
        projects: [Any] = [], hidden: Any? = nil, text: Any? = v2Text()) -> String {
    var m: [String: Any] = ["asOf": "2026-11-22T04:07:27Z", "mode": mode, "counts": counts, "rows": rows, "projects": projects]
    if let hidden { m["hidden"] = hidden }
    if let text { m["text"] = text }
    return String(decoding: try! JSONSerialization.data(withJSONObject: m), as: UTF8.self)
}
func threadObject(_ status: String, title: String? = "t") -> [String: Any] { ["status": status, "provider": "codex", "title": title ?? NSNull()] }
func projectObject(_ name: String, attention: Any = 0, status: Any = NSNull(), working: Any = 0, done: Any = 0) -> [String: Any] {
    ["name": name, "projectIcon": NSNull(), "attention": attention, "attentionStatus": status, "working": working, "done": done]
}
do {
    // Valid threads line: localized copy reaches the card; hidden picks the more-line for the rows shown.
    let hidden: [String: Any] = ["4": 9, "5": 8, "6": 7, "7": 6, "8": 5]
    let more = [9: "9 weitere", 8: "8 weitere", 7: "7 weitere", 6: "6 weitere", 5: "5 weitere"]
    let rows = (0..<8).map { _ in threadObject("working") }
    guard let t = live(v2(rows: rows, hidden: hidden, text: v2Text(more: more))) else { check(false, "v2 threads decodes"); throw CancellationError() }
    eq(t.mode, .threads, "mode")
    eq(t.itemCount, 8, "eight rows")
    eq(t.hidden, [4: 9, 5: 8, 6: 7, 7: 6, 8: 5], "hidden per k")
    for k in 4...8 { eq(t.cardSnapshot(rowLimit: k).overflow, "\(9 - (k - 4)) weitere", "more-line for k=\(k)") }
    eq(t.cardSnapshot().summary, "2 brauchen dich · 3 in Arbeit", "summary parts joined with \" · \"")
    eq(t.cardSnapshot().text.updated(time: "04:07"), "Aktualisiert 04:07", "updated template")
    eq(t.rows[0].statusText(now: Date(), text: t.text), "DE-Working", "status label from text (no since)")
    eq(CardRow(status: .waiting, title: nil, provider: .neutral).displayTitle(t.text), "Agent:in", "agent fallback from text")

    // Nothing hidden: no more-line collapsed or expanded; the plan then shows "Show fewer" when expanded.
    let six = live(v2(rows: (0..<6).map { _ in threadObject("done") }, hidden: ["4": 2, "5": 1], text: v2Text(more: [2: "2 weitere", 1: "1 weitere"])))
    eq(six?.cardSnapshot(rowLimit: 8).overflow, nil, "expanded to eight hides nothing")
    eq(six?.cardSnapshot(rowLimit: 5).overflow, "1 weitere", "k=5")
    eq(six?.hiddenCount(showing: 2), 2, "k below four reads the collapsed count")

    // Missing or malformed text rejects the line rather than inventing English.
    eq(decodeError(v2(text: nil)), .text("text"), "missing text")
    eq(decodeError(v2(text: "Updated")), .text("text"), "text not an object")
    for field in ["summary", "updated", "more", "showFewer", "statuses", "duration", "agent"] {
        eq(decodeError(v2(text: v2Text(drop: field))), .text(field), "missing text.\(field)")
    }
    eq(decodeError(v2(text: v2Text(override: ["updated": 3]))), .text("updated"), "non-string template")
    eq(decodeError(v2(text: v2Text(override: ["showFewer": "  "]))), .text("showFewer"), "blank string")
    eq(decodeError(v2(text: v2Text(override: ["summary": ["ok", 2]]))), .text("summary"), "non-string summary part")
    var statuses = v2Text()["statuses"] as! [String: Any]
    statuses.removeValue(forKey: "limited")
    eq(decodeError(v2(text: v2Text(override: ["statuses": statuses]))), .text("statuses"), "every status label required")
    eq(decodeError(v2(text: v2Text(override: ["duration": ["seconds": "s", "minutes": "m"]]))), .text("duration"), "every duration template required")
    eq(decodeError(v2(hidden: ["4": 3], text: v2Text(more: [2: "2 weitere"]))), .text("more"), "a hidden count without its more string")
    eq(decodeError(v2("groups")), .shape("mode"), "unknown mode")
    eq(decodeError(v2(rows: (0..<9).map { _ in threadObject("done") })), .tooManyRows, "at most eight rows")

    // Counts: non-integers reject; absurd integers clamp.
    eq(decodeError(v2(counts: ["attention": true, "working": 0, "waiting": 0, "done": 0])), .shape("attention"), "boolean count")
    eq(decodeError(v2(counts: ["attention": 1.5, "working": 0, "waiting": 0, "done": 0])), .shape("attention"), "fractional count")
    eq(decodeError(v2(counts: ["attention": "2", "working": 0, "waiting": 0, "done": 0])), .shape("attention"), "string count")
    eq(decodeError(v2(counts: ["attention": 1, "working": 0, "done": 0])), .shape("waiting"), "v2 counts all required")
    eq(decodeError(v2(hidden: ["4": "x"])), .shape("hidden"), "non-integer hidden")
    let clamped = live(v2(counts: ["attention": 1e12, "working": -4, "waiting": 0, "done": 0], hidden: ["4": 1e9, "9": 3, "x": 1],
                          text: v2Text(more: [LiveLimits.maxCount: "viele"])))
    eq(clamped?.totals, StatusCounts(attention: LiveLimits.maxCount, working: 0), "huge and negative counts clamp")
    eq(clamped?.hidden, [4: LiveLimits.maxCount], "hidden clamps; keys outside 4...8 ignored")

    // Projects: drawn as given, counts left to right needs-you / working / done, zero counts omitted.
    let projects = [projectObject("T3 Code", attention: 1, status: "approval", working: 2, done: 3),
                    projectObject("Supervised", attention: 1, status: "failed", working: 1),
                    projectObject("website", working: 1, done: 4), projectObject("Hermes Agent", done: 2),
                    projectObject("Zeta\u{0007}\u{202E}", attention: 0, status: "input")]
    guard let p = live(v2("projects", counts: ["attention": 2, "working": 4, "waiting": 0, "done": 10], rows: [threadObject("approval", title: "secret")],
                          projects: projects, hidden: ["4": 1], text: v2Text(more: [1: "1 weiteres Projekt"]))) else {
        check(false, "v2 projects decodes"); throw CancellationError()
    }
    eq(p.mode, .projects, "projects mode")
    eq(p.rows, [], "thread rows are never kept in projects mode")
    eq(p.projects.map(\.name), ["T3 Code", "Supervised", "website", "Hermes Agent", "Zeta"], "order as given; control characters stripped")
    eq(p.projects[0].counts, [.init(status: .approval, count: 1), .init(status: .working, count: 2), .init(status: .done, count: 3)], "needs-you, working, done")
    eq(p.projects[1].counts.map(\.status), [.failed, .working], "most urgent status leads, done omitted")
    eq(p.projects[1].counts.first.map { $0.status.glyph }, .circleAlert, "failed draws the alert glyph")
    eq(p.projects[0].counts.first.map { $0.status.glyph }, .shieldQuestionMark, "approval draws the shield glyph")
    eq(p.projects[3].counts, [.init(status: .done, count: 2)], "done only")
    eq(p.projects[4].attentionStatus, nil, "attention 0: status ignored")
    eq(p.projects[4].counts, [], "all zero: no counts")
    let collapsed = p.cardSnapshot()
    eq(collapsed.projects.count, 4, "four projects collapsed")
    eq(collapsed.rows, [], "no thread rows")
    eq(collapsed.overflow, "1 weiteres Projekt", "projects more-line")
    eq(p.cardSnapshot(rowLimit: 8).projects.count, 5, "expanded shows all")
    check(p.hasMoreRows, "five projects can expand")
    // One bad project never freezes the card: it is dropped (or, for a blank name, drawn as "Untitled project").
    let tolerant = live(v2("projects", projects: [projectObject("keep"), projectObject("x", attention: 2),
                                                  projectObject("y", attention: 2, status: "working"), projectObject("z", working: 0.5),
                                                  "not an object", projectObject(" \n\u{200B} "), ["name": 7, "attention": 0, "working": 1, "done": 0]]))
    eq(tolerant?.projects.map(\.name), ["keep", LiveDecoder.untitledProject, LiveDecoder.untitledProject],
       "attention without a status, a non-attention status, a fractional count and a non-object are dropped; blank names fall back")
    let rowsKept = live(v2(rows: [threadObject("working"), threadObject("sleeping"), ["status": "done", "title": 5], "x", threadObject("done")]))
    eq(rowsKept?.rows.map(\.status), [.working, .done], "malformed thread rows are dropped, the rest draw")
    eq(live(v2("projects", projects: [projectObject(String(repeating: "n", count: 200))]))?.projects.first?.name.count, LiveLimits.maxProjectNameCharacters,
       "long names capped at 80 with an ellipsis")
    eq(decodeError(v2("projects", projects: [])), nil, "an empty project list is valid")
    // A line without mode or text is malformed; there is no other wire format.
    let noMode = #""asOf":"2026-11-22T04:07:27Z","counts":{"attention":1,"working":0,"waiting":0,"done":0},"rows":[\#(row("approval"))]"#
    eq(decodeError("{\(noMode)}"), .shape("mode"), "no mode")
    eq(decodeError(#"{\#(noMode),"text":{}}"#), .shape("mode"), "text without mode")
    eq(decodeError(v2(text: nil)), .text("text"), "v2 needs text")
    eq(live(v2(rows: [threadObject("done")], hidden: nil))?.hidden, [:], "absent hidden: nothing hidden")
    eq(live(v2(rows: [threadObject("done")], projects: ["junk", 3]))?.projects, [], "threads mode never reads the projects list")
    // text: 120 characters at most; templates without their placeholder use the English template for that key.
    eq(decodeError(v2(text: v2Text(override: ["showFewer": String(repeating: "x", count: 121)]))), .text("showFewer"), "121-character string")
    eq(decodeError(v2(text: v2Text(override: ["showFewer": String(repeating: "x", count: 120)]))), nil, "120 characters is fine")
    let noPlaceholders = live(v2(text: v2Text(override: ["updated": "Aktualisiert", "duration": ["seconds": "Sek.", "minutes": "{count} Min.", "hours": "{hours} Std."]])))
    eq(noPlaceholders?.text.updated, CardText.english.updated, "updated without {time}: English template")
    eq(noPlaceholders?.text.duration, CardText.Durations(seconds: "{count}s", minutes: "{count} Min.", hours: "{hours}h {minutes}m"),
       "each duration template falls back on its own")
    // more keys must be canonical positive integers.
    let canonical = live(v2(hidden: ["4": 5], text: v2Text(override: ["more": ["5": "5 weitere", "05": "x", "+5": "y", "0": "z", "-1": "w"]])))
    eq(canonical?.text.more, [5: "5 weitere"], "non-canonical more keys ignored")
    eq(decodeError(v2(hidden: ["4": 5], text: v2Text(override: ["more": ["05": "x"]]))), .text("more"), "a non-canonical key does not satisfy a hidden count")

    eq(decodeError(#"{"asOf":"2026-11-22T04:07:27Z","mode":"projects","counts":{"attention":0,"working":0,"waiting":0,"done":0},"text":{}}"#),
       .shape("projects"), "projects mode needs its list")
} catch {}

// MARK: Adaptive glass (wallpaper luminance)
do {
    func grey(_ v: UInt8) -> CardAppearance { WallpaperTone.appearance(luminance: WallpaperTone.averageLuminance(rgba: [UInt8](repeating: v, count: 64))) }
    eq(WallpaperTone.appearance(luminance: nil), .dark, "failure: dark")
    eq(WallpaperTone.appearance(luminance: .nan), .dark, "NaN: dark")
    eq(grey(255), .light, "white wallpaper: light")
    eq(grey(190), .light, "pale silver wallpaper: light")
    eq(grey(128), .dark, "mid-tone wallpaper: dark")
    eq(grey(30), .dark, "night wallpaper: dark")
    eq(WallpaperTone.relativeLuminance(red: 1, green: 1, blue: 1), 1, "white")
    eq(WallpaperTone.relativeLuminance(red: 0, green: 0, blue: 0), 0, "black")
    check(WallpaperTone.relativeLuminance(red: 0.5, green: 0.5, blue: 0.5) < 0.25, "mid grey is dark (sRGB is not linear)")
    eq(WallpaperTone.averageLuminance(rgba: []), nil, "no pixels")
    eq(WallpaperTone.averageLuminance(rgba: [255, 255, 255, 255, 0, 0, 0, 255]), 0.5, "mean of pixel luminances")

    // Placement: a 2:1 image on a 1000x1000 screen.
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    let wide = CGSize(width: 2000, height: 1000)
    eq(WallpaperTone.drawnRect(screen: screen.size, image: wide, placement: .fill), CGRect(x: -500, y: 0, width: 2000, height: 1000), "fill crops the sides")
    eq(WallpaperTone.drawnRect(screen: screen.size, image: wide, placement: .fit), CGRect(x: 0, y: 250, width: 1000, height: 500), "fit letterboxes")
    eq(WallpaperTone.drawnRect(screen: screen.size, image: wide, placement: .stretch), CGRect(x: 0, y: 0, width: 1000, height: 1000), "stretch")
    eq(WallpaperTone.drawnRect(screen: screen.size, image: CGSize(width: 200, height: 100), placement: .center), CGRect(x: 400, y: 450, width: 200, height: 100), "center: native size")
    eq(WallpaperTone.drawnRect(screen: screen.size, image: CGSize(width: 200, height: 100), placement: .shrinkToFit), CGRect(x: 400, y: 450, width: 200, height: 100), "shrink-to-fit: small stays native")
    eq(WallpaperTone.drawnRect(screen: screen.size, image: wide, placement: .shrinkToFit), CGRect(x: 0, y: 250, width: 1000, height: 500), "shrink-to-fit: large shrinks")

    let topLeft = CGRect(x: 0, y: 900, width: 100, height: 100)
    eq(WallpaperTone.sample(card: topLeft, screen: screen, image: wide, placement: .fill),
       .init(imageRect: CGRect(x: 0.25, y: 0, width: 0.05, height: 0.1), coverage: 1), "fill: screen top-left is the cropped image's top-left")
    eq(WallpaperTone.sample(card: topLeft, screen: screen, image: wide, placement: .fit), .init(imageRect: nil, coverage: 0), "fit: a card in the margin sees only the fill colour")
    eq(WallpaperTone.sample(card: CGRect(x: 0, y: 700, width: 100, height: 100), screen: screen, image: wide, placement: .fit)?.coverage, 0.5,
       "fit: half on the image, half on the margin")
    eq(WallpaperTone.sample(card: CGRect(x: 1000, y: 1000, width: 10, height: 10), screen: CGRect(x: 1000, y: 1000, width: 100, height: 100),
                            image: CGSize(width: 100, height: 100), placement: .fill)?.imageRect, CGRect(x: 0, y: 0.9, width: 0.1, height: 0.1), "secondary-screen origin")
    eq(WallpaperTone.sample(card: CGRect(x: 5000, y: 0, width: 10, height: 10), screen: screen, image: wide, placement: .fill), nil, "off screen: no sample")
    eq(WallpaperTone.sample(card: topLeft, screen: screen, image: .zero, placement: .fill), nil, "empty image")
    eq(WallpaperTone.blend(image: 0.9, fill: 0.1, coverage: 0.5), 0.5, "area-weighted blend")
    eq(WallpaperTone.blend(image: nil, fill: 0.8, coverage: 0), 0.8, "margin only: fill colour, image not needed")
    eq(WallpaperTone.blend(image: nil, fill: 0.8, coverage: 0.3), nil, "unreadable image part: no guess")
    eq(WallpaperTone.appearance(luminance: WallpaperTone.blend(image: 0.9, fill: 0, coverage: 0.2)), .dark, "a bright image mostly in a black margin stays dark")
}

// MARK: Header fit: counts first, then "Updated {time}", then the bare time, then no time
do {
    let summaries: [CGFloat] = [200, 190, 185]  // normal, thin, hair separators
    eq(HeaderFit.choose(timeWidths: [100, 50], summaryWidths: summaries, contentWidth: 336, gap: 10).time, 0, "room for everything: Updated {time}")
    let tightened = HeaderFit.choose(timeWidths: [100, 50], summaryWidths: summaries, contentWidth: 300, gap: 10)
    eq(tightened.time, 0, "full time kept while a tighter summary fits")
    eq(tightened.summary, 1, "summary tightens before the time shortens")
    let bare = HeaderFit.choose(timeWidths: [100, 50], summaryWidths: summaries, contentWidth: 246, gap: 10)
    eq(bare.time, 1, "bare time before dropping it")
    eq(bare.summary, 2, "every tightening is tried before the time is dropped")
    let dropped = HeaderFit.choose(timeWidths: [100, 50], summaryWidths: summaries, contentWidth: 220, gap: 10)
    eq(dropped.time, nil, "no time when even the tightest summary needs the room")
    eq(dropped.summary, 0, "with no time, the widest summary that fits")
    eq(HeaderFit.choose(timeWidths: [100, 50], summaryWidths: summaries, contentWidth: 150, gap: 10).summary, 2, "nothing fits: tightest form truncates")
    eq(HeaderFit.choose(timeWidths: [400], summaryWidths: [100], contentWidth: 336, gap: 10).time, 0, "time is capped at half the row")
}

print("\(passes) passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
