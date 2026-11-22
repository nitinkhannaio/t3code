import CoreGraphics

/// Card metrics from the approved design (Paper "Lock screen · all states"): T3's one-line sidebar row.
enum CardMetrics {
    static let width: CGFloat = 372
    static let minWidth: CGFloat = 300
    static let padding: CGFloat = 8
    static let headerHeight: CGFloat = 32
    static let rowHeight: CGFloat = 36
    /// Header and row content inset inside the padding, so content sits 18 pt from the card edge.
    static let rowInset: CGFloat = 10
    /// Between the icon, title and status lanes.
    static let laneGap: CGFloat = 10
    static let iconSize: CGFloat = 16
    static let iconCornerRadius: CGFloat = 4
    /// Agent marks are drawn quieter than project icons.
    static let agentMarkAlpha: CGFloat = 0.7
    static let statusIconSize: CGFloat = 12
    static let statusIconGap: CGFloat = 4
    /// Project rows: status icon to number, and between counts.
    static let countIconGap: CGFloat = 3
    static let countGap: CGFloat = 10
    /// The show-more row uses the same geometry as a session row.
    static let overflowHeight: CGFloat = rowHeight
    static let cornerRadius: CGFloat = 16

    /// Left edge of the title lane (and the show-more text), from the card edge.
    static var titleX: CGFloat { padding + rowInset + iconSize + laneGap }

    static func height(rows: Int, overflow: Bool) -> CGFloat {
        padding + headerHeight + CGFloat(rows) * rowHeight + (overflow ? overflowHeight : 0) + padding
    }

    /// The panel is sized once to the largest card so it never resizes while placed.
    static var maxHeight: CGFloat { height(rows: CardPresentation.rowLimit, overflow: true) }
    /// Tallest expanded live card (eight rows plus the show-more row).
    static var expandedMaxHeight: CGFloat { height(rows: CardPresentation.expandedRowLimit, overflow: true) }

    /// The visible glass inside the fixed panel: fitted to the rows actually shown and pinned to the panel's bottom
    /// edge (AppKit, unflipped), so it grows upward from a constant gap above the credential controls.
    static func cardFrame(inPanel bounds: CGRect, rows: Int, overflow: Bool) -> CGRect {
        let fitted = min(bounds.height, height(rows: min(max(rows, 0), CardPresentation.expandedRowLimit), overflow: overflow))
        return CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: fitted)
    }
}

/// Type scale. Kept in Core (no AppKit) so tests pin it; the view maps these to NSFont.Weight.
enum CardTypography {
    enum Weight: Equatable { case regular, medium, semibold }
    struct Style: Equatable {
        let size: Double
        let weight: Weight
        let lineHeight: Double
    }

    static let summary = Style(size: 12, weight: .medium, lineHeight: 16)
    static let time = Style(size: 12, weight: .regular, lineHeight: 16)          // secondary, tabular digits
    static let title = Style(size: 14, weight: .medium, lineHeight: 20)
    static let agentName = Style(size: 14, weight: .regular, lineHeight: 20)     // secondary, title withheld
    static let status = Style(size: 12, weight: .medium, lineHeight: 16)         // status colour, tabular digits
    static let overflow = Style(size: 14, weight: .regular, lineHeight: 20)      // secondary
}

enum CardPlacement {
    /// Clock and date live in the top band; avatar, name, password field and Touch ID prompt in the bottom band.
    static let topExclusion: CGFloat = 0.30
    /// Bottom credential band (avatar, name, password field): 23% of the screen height, never less than 220 pt.
    static let bottomExclusion: CGFloat = 0.23
    static let minimumCredentialBand: CGFloat = 220
    static let sideMargin: CGFloat = 16
    static let gapAboveControls: CGFloat = 10

    static func credentialBandHeight(screenHeight: CGFloat) -> CGFloat {
        max(screenHeight * bottomExclusion, minimumCredentialBand)
    }

    static func safeBand(in screen: CGRect) -> CGRect {
        let minY = screen.minY + credentialBandHeight(screenHeight: screen.height)
        let maxY = screen.maxY - screen.height * topExclusion
        return CGRect(x: screen.minX, y: minY, width: screen.width, height: max(0, maxY - minY))
    }

    /// AppKit coordinates (origin bottom-left). Nil when the card cannot fit outside the system UI bands.
    static func lockFrame(screen: CGRect, height: CGFloat = CardMetrics.maxHeight) -> CGRect? {
        let width = min(CardMetrics.width, screen.width - 2 * sideMargin)
        guard width >= CardMetrics.minWidth else { return nil }
        let band = safeBand(in: screen)
        let y = band.minY + gapAboveControls
        guard y + height <= band.maxY else { return nil }
        return CGRect(x: (screen.midX - width / 2).rounded(), y: y.rounded(), width: width, height: height)
    }

    /// Live lock layout: the same bottom anchor as `lockFrame`, with the panel grown upward to hold as many rows
    /// (4...8) as fit below the clock band. Nil when even the collapsed card does not fit.
    static func lockLayout(screen: CGRect) -> (frame: CGRect, rowCapacity: Int)? {
        for rows in stride(from: CardPresentation.expandedRowLimit, through: CardPresentation.rowLimit, by: -1) {
            if let frame = lockFrame(screen: screen, height: CardMetrics.height(rows: rows, overflow: true)) {
                return (frame, rows)
            }
        }
        return nil
    }
}

/// Header fit: the counts win. Each time form ("Updated 4:07 AM", then "4:07 AM") is tried with every summary
/// tightening before falling back to the next; with no time left, the summary takes the whole row (its last form
/// truncates if nothing fits). Time is capped at half the row.
enum HeaderFit {
    static func choose(timeWidths: [CGFloat], summaryWidths: [CGFloat], contentWidth: CGFloat, gap: CGFloat) -> (time: Int?, summary: Int) {
        for (index, width) in timeWidths.enumerated() {
            let room = contentWidth - min(width, contentWidth / 2) - gap
            if let fit = summaryWidths.firstIndex(where: { $0 <= room }) { return (index, fit) }
        }
        return (nil, summaryWidths.firstIndex(where: { $0 <= contentWidth }) ?? max(summaryWidths.count - 1, 0))
    }
}
