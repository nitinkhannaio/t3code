import AppKit
import CoreImage

/// Offscreen layout check: no window, no app activation. Behind-window material can't be sampled offscreen, so the
/// card's tint is drawn over a stand-in gradient, or with `backdrop` over that image, blurred (40 px, saturation
/// 1.7) under the card to approximate the glass. `appearance` nil picks the variant from the backdrop exactly as the
/// live card picks it from the wallpaper.
@MainActor
func renderPNG(to path: String, appearance: CardAppearance?, sample: RenderSample, expanded: Bool = false, width: CGFloat = CardMetrics.width,
               interactive: Bool = false, backdrop: String? = nil) {
    let pad: CGFloat = 24
    let panelHeight = expanded ? CardMetrics.expandedMaxHeight : CardMetrics.maxHeight
    let size = CGSize(width: width + 2 * pad, height: panelHeight + 2 * pad)
    let canvas = NSView(frame: CGRect(origin: .zero, size: size))
    canvas.wantsLayer = true
    let image = backdrop.map(loadBackdrop)
    let look = appearance ?? .dark

    let snapshot = renderSnapshot(sample, expanded: expanded)
    // Same geometry as the panel: the card is fitted to its rows and pinned to the bottom of the max frame.
    let card: CardView
    if interactive {
        // Armed look: the plan the live runner draws (chevron, clip, footer), at the reference capacity of eight.
        let plan = renderPlan(sample, expanded: expanded, interactive: true)
        card = CardView(appearance: look, useMaterial: false, now: renderNow)
        card.update(plan)
        card.frame = CGRect(x: 0, y: 0, width: width, height: plan.height)
        card.setRowAlphas { $0 < plan.shownRows ? 1 : 0 }
    } else {
        card = placedCard(snapshot, appearance: look, panel: CGRect(x: 0, y: 0, width: width, height: panelHeight))
    }
    card.frame = card.frame.offsetBy(dx: pad, dy: pad)
    var luminance: Double?
    if let image {
        // The canvas stands in for the screen: the backdrop fills it, as the wallpaper fills the screen.
        func pixels(_ rect: CGRect) -> CGRect? {
            WallpaperTone.sample(card: rect, screen: canvas.bounds, image: CGSize(width: image.width, height: image.height), placement: .fill)?
                .imageRect.map { CGRect(x: $0.minX * CGFloat(image.width), y: $0.minY * CGFloat(image.height),
                                        width: $0.width * CGFloat(image.width), height: $0.height * CGFloat(image.height)) }
        }
        let fill = pixels(canvas.bounds)
        let under = pixels(card.frame)
        if let fill, let cropped = image.cropping(to: fill.integral) { canvas.layer?.contents = cropped }
        if let under {
            luminance = WallpaperSampler.luminance(of: image, in: under)
            let glass = NSImageView(frame: card.frame)
            glass.image = blurred(image, crop: under).map { NSImage(cgImage: $0, size: card.frame.size) }
            glass.imageScaling = .scaleAxesIndependently
            glass.wantsLayer = true
            glass.layer?.cornerRadius = CardMetrics.cornerRadius
            glass.layer?.cornerCurve = .continuous
            glass.layer?.masksToBounds = true
            canvas.addSubview(glass)
        }
        if appearance == nil { card.setAppearance(WallpaperTone.appearance(luminance: luminance)) }
    } else {
        let gradient = CAGradientLayer()
        gradient.frame = canvas.bounds
        gradient.colors = look == .dark
            ? [NSColor(srgbRed: 0.22, green: 0.24, blue: 0.43, alpha: 1).cgColor, NSColor(srgbRed: 0.45, green: 0.30, blue: 0.42, alpha: 1).cgColor]
            : [NSColor(srgbRed: 0.93, green: 0.86, blue: 0.78, alpha: 1).cgColor, NSColor(srgbRed: 0.70, green: 0.80, blue: 0.90, alpha: 1).cgColor]
        canvas.layer?.addSublayer(gradient)
    }
    card.layoutSubtreeIfNeeded()
    canvas.addSubview(card)
    canvas.layoutSubtreeIfNeeded()
    let clipped = card.clippedFields()

    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { fail("Could not allocate bitmap", code: 1) }
    rep.size = size
    canvas.cacheDisplay(in: canvas.bounds, to: rep)
    guard let data = rep.representation(using: .png, properties: [:]) else { fail("PNG encode failed", code: 1) }
    do {
        try data.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(Int(size.width))x\(Int(size.height)) pt @2x) sample=\(sample.rawValue) display=\(expanded ? "expanded" : "collapsed") interactive=\(interactive) glass=\(card.cardAppearance.rawValue)\(luminance.map { String(format: " luminance=%.2f", $0) } ?? "") disclosure=\(card.disclosure) rows=\(snapshot.itemCount) summary=\(card.summaryShown) time=\(card.timeShown) overflow=\(card.overflowShown ?? "-") status=\(card.statusTexts.joined(separator: "|")) clipped=\(clipped.isEmpty ? "none" : clipped.joined(separator: ","))")
    } catch {
        fail("\(error)", code: 1)
    }
}

private func loadBackdrop(_ path: String) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
              kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
              kCGImageSourceThumbnailMaxPixelSize: 1600,
          ] as CFDictionary) else { fail("Could not read backdrop \(path)", code: 1) }
    return image
}

/// CSS `blur(40px) saturate(170%)` of the region under the card, in the image's pixel scale.
private func blurred(_ image: CGImage, crop: CGRect) -> CGImage? {
    let ci = CIImage(cgImage: image)
    // CIImage is y-up; `crop` is y-down image pixels.
    let region = CGRect(x: crop.minX, y: CGFloat(image.height) - crop.maxY, width: crop.width, height: crop.height)
    let pixelsPerPoint = crop.width / CardMetrics.width
    let blur = ci.clampedToExtent().applyingGaussianBlur(sigma: 40 * pixelsPerPoint)
        .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.7])
    return CIContext().createCGImage(blur, from: region)
}

@MainActor
private func placedCard(_ snapshot: CardSnapshot, appearance: CardAppearance, panel: CGRect) -> CardView {
    let card = CardView(appearance: appearance, useMaterial: false, now: renderNow)
    card.frame = CardMetrics.cardFrame(inPanel: panel, rows: snapshot.itemCount, overflow: snapshot.overflow != nil)
    card.update(snapshot)
    card.layoutSubtreeIfNeeded()
    return card
}

/// Every fixture's asOf; renders pin the clock here, so "Working 21m" is deterministic.
let renderNow = Date(timeIntervalSince1970: 1_795_275_570)

private func renderSnapshot(_ sample: RenderSample, expanded: Bool) -> CardSnapshot {
    renderLive(sample).cardSnapshot(rowLimit: expanded ? CardPresentation.expandedRowLimit : CardPresentation.rowLimit)
}

func renderLive(_ sample: RenderSample) -> LiveSnapshot {
    let line: String
    switch sample {
    case .mixed:
        line = englishThreads((2, 1, 0, 1), [("input", "claudeAgent", "Pick a color token", nil), ("failed", "codex", "Run migration dry-run", nil),
                                             ("working", "cursor", "Refactor settings form", nil), ("done", "codex", "Write parser tests", nil)])
    case .allStates:
        line = englishThreads((5, 1, 1, 2), [
            ("approval", "codex", "Review migration plan", nil), ("input", "claudeAgent", "Pick a color token", nil),
            ("request", "antigravity", "Choose a test fixture", nil), ("limited", "cursor", "Summarize the design notes", nil),
            ("failed", "grok", "Run migration dry-run", nil), ("working", "opencode", "Refactor settings form", nil),
            ("waiting", nil, "Queued: lint the workspace", nil), ("done", "kiro", "Write parser tests", nil),
        ])
    case .sixRows:
        line = englishThreads((2, 2, 1, 1), [
            ("approval", "codex", "Review migration plan", nil), ("input", "claudeAgent", "Pick a color token", nil),
            ("working", "cursor", "Refactor settings form", nil), ("working", "grok", "Write parser tests", nil),
            ("waiting", "opencode", "Queued: lint the workspace", nil), ("done", "kiro", "Tidy build script", nil),
        ])
    case .overflow:
        line = englishThreads((2, 3, 0, 5), [("approval", "codex", nil, nil), ("input", "claudeAgent", nil, nil),
                                             ("working", "claudeAgent", nil, nil), ("done", "antigravity", nil, nil)])
    case .titlesOff:
        line = englishThreads((5, 1, 1, 1), titlesOffRows)
    case .longText:
        line = englishThreads((10, 8, 0, 24), [
            ("input", "codex", "Investigate why the release build drops source maps on Windows", iconRing),
            ("approval", "claudeAgent", "Review the parser change", iconBars),
            ("working", "codex", "Add regression coverage", iconRing),
            ("done", "cursor", "Tidy the settings copy", iconDiamond),
        ])
    case .threads: line = v2Threads(german: false)
    case .threadsSix: line = v2ThreadsSix
    case .projects: line = v2Projects(german: false)
    case .germanThreads: line = v2Threads(german: true)
    case .germanProjects: line = v2Projects(german: true)
    }
    return decodeSample(line)
}

/// One row per status, titles withheld: the agent's mark and name fill the icon and title lanes.
private let titlesOffRows: [(String, String?, String?, String?)] = [
    ("approval", "codex", nil, nil), ("input", "claudeAgent", nil, nil), ("request", "claudeAgent", nil, nil),
    ("limited", "codex", nil, nil), ("failed", "antigravity", nil, nil), ("working", "claudeAgent", nil, nil),
    ("waiting", "codex", nil, nil), ("done", "antigravity", nil, nil),
]

/// A threads-mode line with English copy. Working rows started 21 minutes and waiting rows 6 minutes before
/// `renderNow`; hidden counts are the totals minus the rows shown.
private func englishThreads(_ counts: (Int, Int, Int, Int), _ rows: [(String, String?, String?, String?)]) -> String {
    let totals = StatusCounts(attention: counts.0, working: counts.1, waiting: counts.2, done: counts.3)
    var hidden: [Int: Int] = [:]
    for k in CardPresentation.rowLimit...CardPresentation.expandedRowLimit where totals.total - min(k, rows.count) > 0 {
        hidden[k] = totals.total - min(k, rows.count)
    }
    let text = CardText.english(totals: totals, hidden: hidden.values)
    let body = rows.map { status, provider, title, icon in
        threadRow(status, provider, title, since: status == "working" ? "2026-11-21T15:18:30Z" : status == "waiting" ? "2026-11-21T15:33:30Z" : nil, icon: icon)
    }
    return json(["asOf": "2026-11-21T15:39:30Z", "mode": "threads",
                 "counts": ["attention": totals.attention, "working": totals.working, "waiting": totals.waiting, "done": totals.done],
                 "rows": body, "hidden": Dictionary(uniqueKeysWithValues: hidden.map { (String($0.key), $0.value) }),
                 "text": v2Text(summary: text.summary, more: text.more, german: false)])
}

/// Made-up 32x32 project icons (a ring, bars, a diamond), generated for these fixtures only.
private let iconRing = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAhUlEQVR42u2XwQ7AIAhD+a/93T5613lbopkGEWw1NvGm9F1AKlLoup838khL0eZNiFnmvxCzzTMIlPkHsSRATeEAWrkDWOUC0FPYAtEN4H1fPItZ3qkBRjrFBDDaXtoaB+AA8ALA25BiEMFHMcVnBP+OKRYSmpVsz60YHkwoohlFOEXF8wQQiSsWdpl/qAAAAABJRU5ErkJggg=="
private let iconBars = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAXklEQVR42mNgQAPvk3z/0xIz4AO0thyvI+hlOVZH0NtyFEcMlOVwR4w6YNQBhBT8//UVA1NT/agDhq4DSBUfdcCoA0YdMOqAoeuA0fbAqAOGdd9g8HTNBkXndKC65wAQhAV+z9pXkQAAAABJRU5ErkJggg=="
private let iconDiamond = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAkUlEQVR42u2X7QmAMAxEbycncAjXcD1HcowKgoIipW1yzSEN5Gd5D9rmA3jFNC+JmcgFG56V6AX/lOgNf0hEwW+JIWA5vO7bmSECF9wqAQ+4RQJe8FYJeMJbJOANr5UAA14jARa8VAJMeImEtkD4FUg8QolvKFGIJEqxRDOSaMcSA8mYCX+xG+isZhLLadR6fgDsmbxGDvn8pgAAAABJRU5ErkJggg=="

func renderPlan(_ sample: RenderSample, expanded: Bool, interactive: Bool, capacity: Int = CardPresentation.expandedRowLimit) -> CardPlan {
    var display = CardDisplayState(capacity: capacity)
    let live = renderLive(sample)
    display.snapshot(live)
    if expanded { display.expand() }
    return CardPlan.make(live, display: display, interactive: interactive)
}

/// Offscreen clipping check across fixtures x widths x appearances x display modes, plus worst-case summaries and
/// overflow lines. Prints field names and verdicts only. Returns false if any fixed-text field would be cut.
@MainActor
func layoutCheck() -> Bool {
    var ok = true
    let widths: [CGFloat] = [360, 372]
    for sample in RenderSample.allCases {
        for expanded in [false, true] {
            for width in widths {
                for appearance in [CardAppearance.dark, .light] {
                    let snapshot = renderSnapshot(sample, expanded: expanded)
                    let height = expanded ? CardMetrics.expandedMaxHeight : CardMetrics.maxHeight
                    let card = placedCard(snapshot, appearance: appearance, panel: CGRect(x: 0, y: 0, width: width, height: height))
                    let clipped = card.clippedFields()
                    let limit = expanded ? CardPresentation.expandedRowLimit : CardPresentation.rowLimit
                    let pass = clipped.isEmpty && snapshot.itemCount <= limit
                    ok = ok && pass
                    print("\(pass ? "PASS" : "FAIL") \(sample.rawValue) \(expanded ? "expanded" : "collapsed") w=\(Int(width)) \(appearance.rawValue) rows=\(snapshot.itemCount) overflow=\(card.overflowShown ?? "-") clipped=\(clipped.isEmpty ? "none" : clipped.joined(separator: ","))")
                }
            }
        }
    }
    // Armed (interactive) plans: chevron in the footer, the more-line must stop before it; every row shown fits.
    for sample in RenderSample.allCases {
        for expanded in [false, true] {
            for width in widths {
                for appearance in [CardAppearance.dark, .light] {
                    let plan = renderPlan(sample, expanded: expanded, interactive: true)
                    let card = CardView(appearance: appearance, useMaterial: false, now: renderNow)
                    card.update(plan)
                    card.frame = CGRect(x: 0, y: 0, width: width, height: plan.height)
                    card.layoutSubtreeIfNeeded()
                    let clipped = card.clippedFields()
                    let slotsOK = card.visibleRowCapacity == plan.shownRows
                    let pass = clipped.isEmpty && slotsOK
                    ok = ok && pass
                    print("\(pass ? "PASS" : "FAIL") interactive \(sample.rawValue) \(expanded ? "expanded" : "collapsed") w=\(Int(width)) \(appearance.rawValue) shown=\(plan.shownRows)/\(card.builtRowCount) disclosure=\(plan.disclosure) overflow=\(card.overflowShown ?? "-") clipped=\(clipped.isEmpty ? "none" : clipped.joined(separator: ","))")
                }
            }
        }
    }
    // Worst realistic header and more-line: every group present with two-digit counts, all eight states shown.
    let stress = [
        ("all groups 2-digit", StatusCounts(attention: 12, working: 34, waiting: 56, done: 78), 176),
        ("all groups 1-digit", StatusCounts(attention: 9, working: 9, waiting: 9, done: 9), 32),
    ]
    // Widest status lane the wire allows below a day ("Working 23h 59m") next to a long title.
    let rows = [CardRow(status: .working, title: String(repeating: "Fixture ", count: 12), provider: .neutral, since: renderNow.addingTimeInterval(-86_399)),
                CardRow(status: .approval, title: nil, provider: .neutral), CardRow(status: .limited, title: "Fixture", provider: .brand(.muse)),
                CardRow(status: .waiting, title: nil, provider: .brand(.acpRegistry), since: renderNow.addingTimeInterval(-3_599))]
    for (name, totals, hidden) in stress {
        for width in widths {
            let text = CardText.english(totals: totals, hidden: [hidden])
            let snapshot = CardSnapshot(rows: rows, summary: text.summaryVariants[0], overflow: text.more(hidden: hidden),
                                        asOf: renderNow, summaryVariants: text.summaryVariants, text: text)
            let card = placedCard(snapshot, appearance: .dark, panel: CGRect(x: 0, y: 0, width: width, height: CardMetrics.maxHeight))
            let clipped = card.clippedFields()
            ok = ok && clipped.isEmpty
            print("\(clipped.isEmpty ? "PASS" : "FAIL") stress \(name) w=\(Int(width)) summarySeparator=\(card.summaryShown.contains("\u{200A}") ? "hair" : card.summaryShown.contains("\u{2009}") ? "thin" : "normal") time=\(card.timeShown) status=\(card.statusTexts.joined(separator: "|")) overflow=\(card.overflowShown ?? "-") clipped=\(clipped.isEmpty ? "none" : clipped.joined(separator: ","))")
        }
    }
    print(ok ? "layout-check: all fixtures fit" : "layout-check: clipping found")
    return ok
}


private func decodeSample(_ line: String) -> LiveSnapshot {
    let result = LiveDecoder.decode(Data(line.utf8))
    guard case .success(.snapshot(let snapshot)) = result else { fail("render sample did not decode: \(result)", code: 1) }
    return snapshot
}



// MARK: wire v2 fixtures (made-up content, decoded by the real LiveDecoder)

private func json(_ object: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

private func v2Text(summary: [String], more: [Int: String], german: Bool) -> [String: Any] {
    let statuses = german
        ? ["approval": "Freigabe", "input": "Eingabe", "request": "Anfrage", "limited": "Limit erreicht", "failed": "Fehlgeschlagen",
           "working": "In Arbeit", "waiting": "Wartet", "done": "Erledigt"]
        : Dictionary(uniqueKeysWithValues: SessionStatus.allCases.map { ($0.rawValue, $0.shortLabel) })
    return [
        "summary": summary,
        "updated": german ? "Aktualisiert um {time}" : "Updated {time}",
        "more": Dictionary(uniqueKeysWithValues: more.map { (String($0.key), $0.value) }),
        "showFewer": german ? "Weniger anzeigen" : "Show fewer",
        "expandLabel": german ? "Weitere Sitzungen anzeigen" : "Show additional sessions",
        "collapseLabel": german ? "Weitere Sitzungen ausblenden" : "Hide additional sessions",
        "statuses": statuses,
        "duration": german ? ["seconds": "{count} Sek.", "minutes": "{count} Min.", "hours": "{hours} Std. {minutes} Min."]
                           : ["seconds": "{count}s", "minutes": "{count}m", "hours": "{hours}h {minutes}m"],
        "agent": "Agent",
    ]
}

private func threadRow(_ status: String, _ provider: String?, _ title: String?, since: String? = nil, icon: String? = nil) -> [String: Any] {
    ["status": status, "provider": provider ?? NSNull(), "title": title ?? NSNull(), "since": since ?? NSNull(), "projectIcon": icon ?? NSNull()]
}

/// 13 threads, 8 on the wire: "9 more threads" collapsed, "5 more threads" expanded to eight.
private func v2Threads(german: Bool) -> String {
    let hidden = [4: 9, 5: 8, 6: 7, 7: 6, 8: 5]
    let more = Dictionary(uniqueKeysWithValues: hidden.values.map { ($0, german ? "\($0) weitere Threads" : "\($0) more threads") })
    let titles = german
        ? ["Migrationsplan für die Abrechnungsdatenbank prüfen", "Farbtoken für die Seitenleiste auswählen", "Probelauf der Migration",
           "Einstellungsformular umbauen", "Parser-Tests schreiben", "Build-Skript aufräumen", "Arbeitsbereich linten", "Release-Notizen"]
        : ["Review migration plan", "Pick a color token", "Run migration dry-run", "Refactor settings form",
           "Write parser tests", "Tidy build script", "Queued: lint the workspace", "Draft release notes"]
    let rows = [
        threadRow("approval", "codex", titles[0], icon: monogram("T3")), threadRow("input", "claudeAgent", titles[1], icon: monogram("W")),
        threadRow("failed", "cursor", titles[2], icon: monogram("SE")),
        threadRow("working", "opencode", titles[3], since: german ? "2026-11-21T14:34:30Z" : "2026-11-21T15:18:30Z", icon: monogram("T3")),
        threadRow("working", "codex", titles[4], since: "2026-11-21T15:39:00Z", icon: monogram("HA")),
        threadRow("working", "grok", titles[5], since: "2026-11-21T15:18:30Z"),
        threadRow("waiting", nil, titles[6], since: "2026-11-21T15:33:30Z"), threadRow("done", "kiro", titles[7], icon: monogram("W")),
    ]
    let summary = german ? ["3 benötigen dich", "4 in Arbeit", "1 wartet", "5 erledigt"] : ["3 need you", "4 working", "1 waiting", "5 done"]
    return json(["asOf": "2026-11-21T15:39:30Z", "mode": "threads", "counts": ["attention": 3, "working": 4, "waiting": 1, "done": 5],
                 "rows": rows, "projects": [], "hidden": Dictionary(uniqueKeysWithValues: hidden.map { (String($0.key), $0.value) }),
                 "text": v2Text(summary: summary, more: more, german: german)])
}

/// Six threads: expanded to eight hides nothing, so the footer reads "Show fewer".
private let v2ThreadsSix: String = json([
    "asOf": "2026-11-21T15:39:30Z", "mode": "threads", "counts": ["attention": 2, "working": 2, "waiting": 1, "done": 1],
    "rows": [threadRow("approval", "codex", "Review migration plan", icon: monogram("T3")), threadRow("input", "claudeAgent", "Pick a color token"),
             threadRow("working", "cursor", "Refactor settings form", since: "2026-11-21T15:18:30Z"),
             threadRow("working", "grok", "Write parser tests", since: "2026-11-21T15:18:30Z"),
             threadRow("waiting", "opencode", "Queued: lint the workspace", since: "2026-11-21T15:33:30Z"), threadRow("done", "kiro", "Tidy build script")],
    "projects": [], "hidden": ["4": 2, "5": 1],
    "text": v2Text(summary: ["2 need you", "2 working", "1 waiting", "1 done"], more: [2: "2 more threads", 1: "1 more thread"], german: false),
])

private func projectRow(_ name: String, _ icon: String?, attention: Int = 0, _ status: String? = nil, working: Int = 0, done: Int = 0) -> [String: Any] {
    ["name": name, "projectIcon": icon ?? NSNull(), "attention": attention, "attentionStatus": status ?? NSNull(), "working": working, "done": done]
}

/// Paper "Iteration · glass + project groups": four projects shown, "1 more project".
private func v2Projects(german: Bool) -> String {
    let projects = german
        ? [projectRow("Interne Werkzeuge für die Datenmigration der Abrechnung", monogram("T3"), attention: 12, "approval", working: 34, done: 56),
           projectRow("Überwachte Läufe", monogram("SE"), attention: 1, "failed", working: 1),
           projectRow("website", monogram("W"), working: 1, done: 4), projectRow("Hermes Agent", monogram("HA"), done: 2),
           projectRow("Kein Projekt", nil, done: 1)]
        : [projectRow("T3 Code", monogram("T3"), attention: 1, "approval", working: 2, done: 3),
           projectRow("Supervised", monogram("SE"), attention: 1, "failed", working: 1),
           projectRow("website", monogram("W"), working: 1, done: 4), projectRow("Hermes Agent", monogram("HA"), done: 2),
           projectRow("Notes", nil, done: 1)]
    let summary = german ? ["13 benötigen dich", "36 in Arbeit", "63 erledigt"] : ["2 need you", "4 working", "10 done"]
    let counts = german ? ["attention": 13, "working": 36, "waiting": 0, "done": 63] : ["attention": 2, "working": 4, "waiting": 0, "done": 10]
    return json(["asOf": "2026-11-21T04:07:27Z", "mode": "projects", "counts": counts, "rows": [], "projects": projects, "hidden": ["4": 1],
                 "text": v2Text(summary: summary, more: [1: german ? "1 weiteres Projekt" : "1 more project"], german: german)])
}

/// Made-up 32x32 monogram icons standing in for the app's rendered project icons (Paper's T3, SE, W, HA).
private func monogram(_ letters: String) -> String {
    let (background, foreground): (NSColor, NSColor) = switch letters {
    case "T3": (CardPalette.hex(0x2563eb), .white)
    case "SE": (CardPalette.hex(0x4749ad), .white)
    case "W": (CardPalette.hex(0x0e8477), .white)
    default: (CardPalette.hex(0x793db2), .white)
    }
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: rep) else { fail("monogram", code: 1) }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    background.setFill()
    NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: 32, height: 32), xRadius: 8, yRadius: 8).fill()
    let font = NSFont.systemFont(ofSize: letters.count > 1 ? 14 : 18, weight: .bold)
    let text = NSAttributedString(string: letters, attributes: [.font: font, .foregroundColor: foreground])
    let size = text.size()
    text.draw(at: CGPoint(x: (32 - size.width) / 2, y: (32 - size.height) / 2))
    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else { fail("monogram", code: 1) }
    return ProjectIcon.prefix + png.base64EncodedString()
}
