import AppKit

/// Colours from the approved design: T3's sidebar status tokens on one thin glass layer (Paper "Iteration · glass +
/// project groups"). `tint` is the only tint; `highlight` is the 1 pt inner top edge.
struct CardPalette {
    let primary: NSColor
    let secondary: NSColor
    let tint: NSColor
    let rim: NSColor
    let highlight: NSColor
    private let statusColors: [SessionStatus: NSColor]

    /// Waiting is quiet: the secondary text colour.
    func color(for status: SessionStatus) -> NSColor { statusColors[status] ?? secondary }

    static func hex(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255, alpha: alpha)
    }

    static let dark = CardPalette(
        primary: hex(0xf5f5f7), secondary: hex(0xebebf5, 0x99 / 255), tint: hex(0x14141a, 0.38), rim: hex(0xffffff, 0.22),
        highlight: hex(0xffffff, 0.18),
        statusColors: [.approval: hex(0xfbbf24), .input: hex(0xa5b4fc), .request: hex(0xf0abfc), .limited: hex(0xfbbf24),
                       .failed: hex(0xf87171), .working: hex(0x60a5fa), .done: hex(0x34d399)]
    )
    static let light = CardPalette(
        primary: hex(0x1d1d1f), secondary: hex(0x3c3c43, 0.70), tint: hex(0xffffff, 0.42), rim: hex(0xffffff, 0.65),
        highlight: hex(0xffffff, 0.70),
        statusColors: [.approval: hex(0xb45309), .input: hex(0x4f46e5), .request: hex(0xc026d3), .limited: hex(0xb45309),
                       .failed: hex(0xb91c1c), .working: hex(0x1d4ed8), .done: hex(0x047857)]
    )

    static func forAppearance(_ appearance: CardAppearance) -> CardPalette { appearance == .dark ? dark : light }
}

/// The approved glass: the wallpaper blurred 40 pt and saturated 1.7x under the palette's single tint. The system
/// material paints its own grey fill and tone over the blur, which on the lock screen turns the card into a slate, so
/// only its backdrop layer is kept. Those layer names are private: if a macOS release renames them, nothing is
/// hidden and the card falls back to the stock material.
final class CardGlass: NSVisualEffectView {
    private static let systemTintLayers: Set<String> = ["fill", "tone", "Chameleon"]

    init() {
        super.init(frame: .zero)
        material = .fullScreenUI
        blendingMode = .behindWindow
        state = .active
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func setAppearance(_ appearance: CardAppearance) {
        self.appearance = NSAppearance(named: appearance == .dark ? .vibrantDark : .vibrantLight)
        stripSystemTint()
    }

    // AppKit rebuilds the material's layers on appearance and layout changes.
    override func layout() {
        super.layout()
        stripSystemTint()
    }

    override func updateLayer() {
        super.updateLayer()
        stripSystemTint()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stripSystemTint()
    }

    private func stripSystemTint() {
        guard let layer else { return }
        var pending = [layer]
        while let next = pending.popLast() {
            if let name = next.name, Self.systemTintLayers.contains(name) { next.isHidden = true }
            if next.name == "backdrop" {
                next.setValue(40, forKeyPath: "filters.gaussianBlur.inputRadius")
                next.setValue(1.7, forKeyPath: "filters.colorSaturate.inputAmount")
            }
            pending.append(contentsOf: next.sublayers ?? [])
        }
    }
}

private extension CardTypography.Weight {
    var font: NSFont.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }
}

/// Plain-text label: `stringValue` only, never attributed or markdown-interpreted.
private func label(_ style: CardTypography.Style, _ color: NSColor, monospacedDigits: Bool = false) -> NSTextField {
    let field = NSTextField(labelWithString: "")
    let size = CGFloat(style.size), weight = style.weight.font
    field.font = monospacedDigits ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
    field.textColor = color
    field.lineBreakMode = .byTruncatingTail
    field.maximumNumberOfLines = 1
    field.cell?.truncatesLastVisibleLine = true
    return field
}

/// Text fields draw with a 2pt inset on each side, so frames use the cell's full size.
private func fittedWidth(_ field: NSTextField) -> CGFloat { ceil(field.cell?.cellSize.width ?? field.intrinsicContentSize.width) }

/// A one-line field vertically centred on `midY` (flipped space), as CSS centres a line box.
private func place(_ field: NSTextField, x: CGFloat, midY: CGFloat, width: CGFloat) {
    let height = ceil(field.cell?.cellSize.height ?? 16)
    field.frame = CGRect(x: x, y: (midY - height / 2).rounded(), width: max(0, width), height: height)
}

/// Read-only card (never takes events: hitTest is nil and its panel ignores mouse events). Manual frame layout from
/// CardMetrics keeps it identical to the tested geometry. Rows sit in a clip between the header and a bottom-pinned
/// show-more row, so when the card grows upward the extra rows are revealed in place. The show-more row's chevron
/// points down while the card is expanded (an indicator only; the interactive surface is the separate hit panel).
final class CardView: NSView {
    private(set) var cardAppearance: CardAppearance
    private var palette: CardPalette
    private let material: CardGlass?
    private let tint = NSView()
    private let highlight = CAShapeLayer()
    private let summary: NSTextField
    private let time: NSTextField
    private let overflow: NSTextField
    private var rowViews: [CardRowView] = []
    private let rowsClip = FlippedClipView()
    let disclosureGlyph: GlyphView
    private let mark = MarkView()
    private(set) var disclosure: Disclosure = .none
    private var hasFooter = false
    private var summaryVariants: [String] = []
    private var timeVariants: [String] = []
    private var current: CardSnapshot?
    /// Offscreen renders pin the clock; live cards read it and redraw elapsed labels at their next boundary.
    private let fixedNow: Date?
    private var elapsedTimer: Timer?

    override var isFlipped: Bool { true }

    /// `useMaterial: false` is only for offscreen PNG renders, where behind-window blending has nothing to sample.
    /// `now`: a fixed clock for offscreen renders (no timers); nil reads the Mac clock.
    init(appearance: CardAppearance, useMaterial: Bool = true, now: Date? = nil) {
        cardAppearance = appearance
        palette = .forAppearance(appearance)
        fixedNow = now
        summary = label(CardTypography.summary, palette.primary)
        time = label(CardTypography.time, palette.secondary, monospacedDigits: true)
        time.alignment = .right
        overflow = label(CardTypography.overflow, palette.secondary)
        disclosureGlyph = GlyphView(.chevronRight, color: palette.secondary)
        material = useMaterial ? CardGlass() : nil
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = CardMetrics.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        tint.wantsLayer = true
        highlight.fillRule = .evenOdd
        rowsClip.wantsLayer = true
        rowsClip.layer?.masksToBounds = true
        disclosureGlyph.isHidden = true
        for view in [material, tint, mark, summary, time, rowsClip, overflow, disclosureGlyph].compactMap({ $0 }) { addSubview(view) }
        tint.layer?.addSublayer(highlight)
        applyPalette()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var now: Date { fixedNow ?? Date() }

    /// Dark or light glass. Recolours in place and rebuilds the rows, keeping their reveal opacity.
    func setAppearance(_ appearance: CardAppearance) {
        guard appearance != cardAppearance else { return }
        cardAppearance = appearance
        palette = .forAppearance(appearance)
        applyPalette()
        guard let current else { return }
        let alphas = rowViews.map(\.alphaValue)
        buildRows(current)
        for (row, alpha) in zip(rowViews, alphas) { row.alphaValue = alpha }
    }

    private func applyPalette() {
        appearance = NSAppearance(named: cardAppearance == .dark ? .darkAqua : .aqua)
        material?.setAppearance(cardAppearance)
        tint.layer?.backgroundColor = palette.tint.cgColor
        highlight.fillColor = palette.highlight.cgColor
        layer?.borderColor = palette.rim.cgColor
        summary.textColor = palette.primary
        mark.color = palette.primary
        time.textColor = palette.secondary
        overflow.textColor = palette.secondary
        disclosureGlyph.color = palette.secondary
    }

    /// Unified entry point: rows beyond `plan.shownRows` are built but clipped (revealed by an expand animation).
    func update(_ plan: CardPlan) {
        update(plan.snapshot, shownRows: plan.shownRows)
        disclosure = plan.disclosure
        hasFooter = plan.hasFooter
        disclosureGlyph.isHidden = !hasFooter
        disclosureGlyph.rotation = plan.disclosure == .expanded ? .down : .none
        needsLayout = true
    }

    func update(_ snapshot: CardSnapshot, shownRows: Int? = nil) {
        current = snapshot
        disclosure = .none
        hasFooter = snapshot.overflow != nil
        disclosureGlyph.isHidden = !hasFooter
        disclosureGlyph.rotation = .none
        summary.stringValue = snapshot.summary
        summaryVariants = snapshot.summaryVariants.isEmpty ? [snapshot.summary] : snapshot.summaryVariants
        let clock = CardPresentation.timeText(snapshot.asOf)
        timeVariants = [snapshot.text.updated(time: clock), clock]
        time.stringValue = timeVariants[0]
        overflow.stringValue = snapshot.overflow ?? ""
        overflow.isHidden = snapshot.overflow == nil
        buildRows(snapshot)
        let rows = rowViews.prefix(shownRows ?? rowViews.count).map(\.accessibilityText)
        setAccessibilityLabel(([snapshot.summary, timeVariants[0]] + rows + (snapshot.overflow.map { [$0] } ?? [])).joined(separator: ". "))
        needsLayout = true
    }

    private func buildRows(_ snapshot: CardSnapshot) {
        rowViews.forEach { $0.removeFromSuperview() }
        let at = now
        rowViews = snapshot.rows.map { RowView(row: $0, text: snapshot.text, palette: palette, appearance: cardAppearance, now: at) }
            + snapshot.projects.map { ProjectRowView(project: $0, text: snapshot.text, palette: palette) }
        rowViews.forEach(rowsClip.addSubview)
        scheduleElapsedRedraw(after: at)
        needsLayout = true
    }

    /// One-shot timer at the earliest label boundary ("Working 21m" -> "22m"); never a repeating timer. It stops
    /// while the card is not on screen; the next update (every show redraws) schedules it again.
    private func scheduleElapsedRedraw(after at: Date) {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
        guard fixedNow == nil, let next = rowViews.compactMap({ $0.nextStatusChange(after: at) }).min() else { return }
        let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                let current = Date()
                self.rowViews.forEach { $0.refreshStatus(now: current) }
                self.scheduleElapsedRedraw(after: current)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        elapsedTimer = timer
    }

    override func layout() {
        super.layout()
        material?.frame = bounds
        tint.frame = bounds
        // Inset 0 1px 0 highlight: the strip between the inner rounded edge and the same edge 1 pt lower.
        let inner = bounds.insetBy(dx: 1, dy: 1)
        let radius = CardMetrics.cornerRadius - 1
        let crescent = CGMutablePath()
        crescent.addRoundedRect(in: inner, cornerWidth: radius, cornerHeight: radius)
        crescent.addRoundedRect(in: inner.offsetBy(dx: 0, dy: tint.isFlipped ? 1 : -1), cornerWidth: radius, cornerHeight: radius)
        highlight.frame = tint.bounds
        highlight.path = crescent
        let innerShape = CAShapeLayer()
        innerShape.path = CGPath(roundedRect: inner, cornerWidth: radius, cornerHeight: radius, transform: nil)
        highlight.mask = innerShape
        let m = CardMetrics.self
        let contentX = m.padding + m.rowInset
        let headerMid = m.padding + m.headerHeight / 2
        func width(_ field: NSTextField, _ text: String) -> CGFloat {
            field.stringValue = text
            return fittedWidth(field)
        }
        // The mark takes the icon lane, so the summary starts where row titles do.
        mark.frame = CGRect(x: contentX, y: headerMid - m.iconSize / 2, width: m.iconSize, height: m.iconSize)
        let headerWidth = bounds.width - contentX - m.titleX
        let choice = HeaderFit.choose(timeWidths: timeVariants.map { width(time, $0) }, summaryWidths: summaryVariants.map { width(summary, $0) },
                                      contentWidth: headerWidth, gap: m.laneGap)
        summary.stringValue = summaryVariants.isEmpty ? "" : summaryVariants[choice.summary]
        time.isHidden = choice.time == nil
        var timeWidth: CGFloat = 0
        if let index = choice.time {
            time.stringValue = timeVariants[index]
            timeWidth = min(fittedWidth(time), headerWidth / 2)
        }
        let summaryWidth = headerWidth - timeWidth - (choice.time == nil ? 0 : m.laneGap)
        place(time, x: bounds.width - contentX - timeWidth, midY: headerMid, width: timeWidth)
        place(summary, x: m.titleX, midY: headerMid, width: summaryWidth)
        // Static states: footerTop == rowsTop + shown * rowHeight.
        let rowsTop = m.padding + m.headerHeight
        let footerTop = bounds.height - m.padding - (hasFooter ? m.overflowHeight : 0)
        rowsClip.frame = CGRect(x: m.padding, y: rowsTop, width: bounds.width - 2 * m.padding, height: max(0, footerTop - rowsTop))
        var y: CGFloat = 0
        for row in rowViews {
            row.frame = CGRect(x: 0, y: y, width: rowsClip.bounds.width, height: m.rowHeight)
            y += m.rowHeight
        }
        // Show-more row: same lanes as a session row (chevron in the icon lane, text in the title lane).
        let footerMid = footerTop + m.overflowHeight / 2
        disclosureGlyph.frame = CGRect(x: contentX, y: footerMid - m.iconSize / 2, width: m.iconSize, height: m.iconSize)
        place(overflow, x: m.titleX, midY: footerMid, width: bounds.width - contentX - m.titleX)
    }

    /// Per-row reveal opacity (rows 0-3 stay at 1).
    func setRowAlphas(_ alpha: (Int) -> Double) {
        for (index, row) in rowViews.enumerated() { row.alphaValue = CGFloat(alpha(index)) }
    }

    /// Whole rows that fit the current clip (offscreen checks).
    var visibleRowCapacity: Int { Int((rowsClip.frame.height / CardMetrics.rowHeight + 0.001).rounded(.down)) }
    var builtRowCount: Int { rowViews.count }
    var overflowFrame: CGRect { overflow.frame }

    /// Offscreen layout check only: names (never contents) of fixed-text fields that would be cut, lanes that drift,
    /// and status labels or counts that would not fit. Titles and project names truncate by design and are excluded.
    func clippedFields() -> [String] {
        layoutSubtreeIfNeeded()
        var clipped: [String] = []
        for (name, field) in [("summary", summary), ("time", time), ("overflow", overflow)] where !field.isHidden {
            if fittedWidth(field) > field.frame.width + 0.5 { clipped.append(name) }
        }
        let bottom = bounds.height - CardMetrics.padding + 0.5
        if !overflow.isHidden {
            if overflow.frame.maxY > bottom { clipped.append("overflow-height") }
            if overflow.frame.minX != CardMetrics.titleX { clipped.append("overflow-off-title-lane") }
        }
        if !disclosureGlyph.isHidden, disclosureGlyph.frame.maxY > bottom { clipped.append("chevron-height") }
        for (index, row) in rowViews.prefix(visibleRowCapacity).enumerated() {
            clipped += row.clippedParts().map { "row\(index).\($0)" }
            if row.frame.maxY > rowsClip.frame.height + 0.5 { clipped.append("row\(index).height") }
            if rowsClip.frame.minX + row.titleMinX != CardMetrics.titleX || row.iconMinX != disclosureGlyph.frame.minX - rowsClip.frame.minX {
                clipped.append("row\(index).lanes")
            }
        }
        return clipped
    }

    var timeShown: String { time.isHidden ? "-" : time.stringValue }
    var summaryShown: String { summary.stringValue }
    var overflowShown: String? { overflow.isHidden ? nil : overflow.stringValue }
    var statusTexts: [String] { rowViews.map(\.statusShown) }
}

private final class FlippedClipView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The T3 mark, filled and centred in its frame at the viewBox's aspect ratio.
final class MarkView: NSView {
    var color = NSColor.white { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let path = T3Mark.path else { return }
        let box = T3Mark.viewBox
        let k = bounds.width / box.width
        context.translateBy(x: 0, y: (bounds.height - box.height * k) / 2)
        context.scaleBy(x: k, y: k)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.fillPath()
    }
}

/// A Lucide glyph (Core's LucideGlyph) stroked in one colour: 2 units on the 24 grid, round caps and joins, so a
/// 12 pt status icon draws a 1 pt line, pixel-aligned at 2x. Not a control: hitTest is nil and it never takes focus.
final class GlyphView: NSView {
    enum Rotation { case none, down }
    private let glyph: LucideGlyph
    var color: NSColor { didSet { needsDisplay = true } }
    var rotation = Rotation.none { didSet { if rotation != oldValue { needsDisplay = true } } }

    init(_ glyph: LucideGlyph, color: NSColor) {
        self.glyph = glyph
        self.color = color
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let path = glyph.path else { return }
        let k = bounds.width / LucideGlyph.grid
        context.translateBy(x: bounds.midX, y: bounds.midY)
        if rotation == .down { context.rotate(by: .pi / 2) }
        context.scaleBy(x: k, y: k)
        context.translateBy(x: -LucideGlyph.grid / 2, y: -LucideGlyph.grid / 2)
        context.addPath(path)
        context.setLineWidth(LucideGlyph.strokeWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(color.cgColor)
        context.strokePath()
    }
}

/// What CardView needs from a thread row or a project row.
private protocol CardRowView: NSView {
    var titleMinX: CGFloat { get }
    var iconMinX: CGFloat { get }
    var statusShown: String { get }
    var accessibilityText: String { get }
    func refreshStatus(now: Date)
    func nextStatusChange(after now: Date) -> Date?
    func clippedParts() -> [String]
}

/// 16 pt icon lane: the project's PNG with a 4 pt corner, else nil.
private func projectIconView(_ png: Data?) -> NSImageView {
    let icon = NSImageView()
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.wantsLayer = true
    icon.layer?.cornerRadius = CardMetrics.iconCornerRadius
    icon.layer?.cornerCurve = .continuous
    icon.layer?.masksToBounds = true
    if let png, let rep = NSBitmapImageRep(data: png) {
        let image = NSImage(size: CGSize(width: CardMetrics.iconSize, height: CardMetrics.iconSize))
        image.addRepresentation(rep)
        icon.image = image
    }
    return icon
}

/// One sidebar row: icon lane (project icon, else the agent's mark), title lane, status lane (icon + label).
private final class RowView: NSView, CardRowView {
    let row: CardRow
    private let text: CardText
    private let icon: NSImageView
    private let title: NSTextField
    private let statusIcon: GlyphView
    private let status: NSTextField

    override var isFlipped: Bool { true }

    init(row: CardRow, text: CardText, palette: CardPalette, appearance: CardAppearance, now: Date) {
        self.row = row
        self.text = text
        title = row.titleIsFallback ? label(CardTypography.agentName, palette.secondary) : label(CardTypography.title, palette.primary)
        title.stringValue = row.displayTitle(text)
        let statusColor = palette.color(for: row.status)
        statusIcon = GlyphView(row.status.glyph, color: statusColor)
        status = label(CardTypography.status, statusColor, monospacedDigits: true)
        status.lineBreakMode = .byClipping
        status.stringValue = row.statusText(now: now, text: text)
        icon = projectIconView(row.projectIcon)
        super.init(frame: .zero)
        if icon.image == nil {
            icon.alphaValue = CardMetrics.agentMarkAlpha
            switch row.provider {
            case .brand(let driver):
                // T3's own provider artwork for this appearance, in its own colours (never tinted).
                icon.image = ProviderIconImages.image(for: driver, appearance: appearance)
            case .neutral:
                icon.image = NSImage(systemSymbolName: ProviderMark.neutralSymbolName, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
                icon.contentTintColor = palette.primary
                icon.layer?.cornerRadius = 0
            }
        }
        for view in [icon, title, statusIcon, status] { addSubview(view) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func refreshStatus(now: Date) {
        let label = row.statusText(now: now, text: text)
        guard label != status.stringValue else { return }
        status.stringValue = label
        needsLayout = true
    }

    func nextStatusChange(after now: Date) -> Date? { row.nextStatusChange(after: now) }

    var statusShown: String { status.stringValue }
    var titleMinX: CGFloat { title.frame.minX }
    var iconMinX: CGFloat { icon.frame.minX }
    var accessibilityText: String {
        "\(row.displayTitle(text)), \(row.status == .limited && text.statuses == CardText.englishStatuses ? row.status.accessibilityLabel : status.stringValue)"
    }

    override func layout() {
        super.layout()
        let m = CardMetrics.self
        let midY = bounds.height / 2
        icon.frame = CGRect(x: m.rowInset, y: midY - m.iconSize / 2, width: m.iconSize, height: m.iconSize)
        // Status lane is sized to its label and never truncates; the title takes what is left.
        let labelWidth = fittedWidth(status)
        let laneWidth = m.statusIconSize + m.statusIconGap + labelWidth
        let laneX = bounds.width - m.rowInset - laneWidth
        statusIcon.frame = CGRect(x: laneX, y: midY - m.statusIconSize / 2, width: m.statusIconSize, height: m.statusIconSize)
        place(status, x: laneX + m.statusIconSize + m.statusIconGap, midY: midY, width: labelWidth)
        let titleX = m.rowInset + m.iconSize + m.laneGap
        place(title, x: titleX, midY: midY, width: laneX - m.laneGap - titleX)
    }

    func clippedParts() -> [String] {
        layoutSubtreeIfNeeded()
        var parts: [String] = []
        if status.frame.maxX > bounds.width + 0.5 || fittedWidth(status) > status.frame.width + 0.5 { parts.append("status") }
        if title.frame.width < 40 { parts.append("title-too-narrow") }
        if title.frame.maxY > bounds.height || title.frame.minY < 0 { parts.append("title-height") }
        return parts
    }
}

/// One project (titles off): icon, name, then needs-you / working / done counts packed against the right edge.
private final class ProjectRowView: NSView, CardRowView {
    private let project: ProjectRow
    private let text: CardText
    private let icon: NSImageView
    private let name: NSTextField
    private let counts: [(glyph: GlyphView, label: NSTextField)]

    override var isFlipped: Bool { true }

    init(project: ProjectRow, text: CardText, palette: CardPalette) {
        self.project = project
        self.text = text
        icon = projectIconView(project.projectIcon)
        name = label(CardTypography.title, palette.primary)
        name.stringValue = project.name
        counts = project.counts.map { count in
            let color = palette.color(for: count.status)
            let number = label(CardTypography.status, color, monospacedDigits: true)
            number.lineBreakMode = .byClipping
            number.stringValue = String(count.count)
            return (GlyphView(count.status.glyph, color: color), number)
        }
        super.init(frame: .zero)
        if icon.image == nil {
            icon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
            icon.contentTintColor = palette.secondary
            icon.layer?.cornerRadius = 0
        }
        for view in [icon, name] + counts.flatMap({ [$0.glyph as NSView, $0.label] }) { addSubview(view) }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func refreshStatus(now: Date) {}
    func nextStatusChange(after now: Date) -> Date? { nil }

    var statusShown: String { counts.map(\.label.stringValue).joined(separator: " ") }
    var titleMinX: CGFloat { name.frame.minX }
    var iconMinX: CGFloat { icon.frame.minX }
    var accessibilityText: String {
        ([project.name] + project.counts.map { "\(text.status($0.status)) \($0.count)" }).joined(separator: ", ")
    }

    override func layout() {
        super.layout()
        let m = CardMetrics.self
        let midY = bounds.height / 2
        icon.frame = CGRect(x: m.rowInset, y: midY - m.iconSize / 2, width: m.iconSize, height: m.iconSize)
        var x = bounds.width - m.rowInset
        for count in counts.reversed() {
            let width = fittedWidth(count.label)
            x -= width
            place(count.label, x: x, midY: midY, width: width)
            x -= m.countIconGap + m.statusIconSize
            count.glyph.frame = CGRect(x: x, y: midY - m.statusIconSize / 2, width: m.statusIconSize, height: m.statusIconSize)
            x -= m.countGap
        }
        let countsMinX = counts.isEmpty ? bounds.width - m.rowInset : x + m.countGap
        let titleX = m.rowInset + m.iconSize + m.laneGap
        place(name, x: titleX, midY: midY, width: countsMinX - m.laneGap - titleX)
    }

    func clippedParts() -> [String] {
        layoutSubtreeIfNeeded()
        var parts: [String] = []
        if counts.contains(where: { fittedWidth($0.label) > $0.label.frame.width + 0.5 || $0.label.frame.maxX > bounds.width + 0.5 }) {
            parts.append("counts")
        }
        if name.frame.width < 40 { parts.append("title-too-narrow") }
        if name.frame.maxY > bounds.height || name.frame.minY < 0 { parts.append("title-height") }
        return parts
    }
}
