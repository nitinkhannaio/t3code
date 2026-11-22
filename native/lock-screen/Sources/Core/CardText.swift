import Foundation

/// threads: one row per thread (titles on). projects: one row per project with status counts (titles off).
enum CardMode: String, Equatable {
    case threads, projects
}

/// The card's copy, localized by the owning app (wire `text`). `english` supplies only per-key template fallbacks,
/// render fixtures and logs; the helper never invents copy for a line.
struct CardText: Equatable {
    struct Durations: Equatable {
        var seconds = "{count}s"
        var minutes = "{count}m"
        var hours = "{hours}h {minutes}m"

        /// "{count}s" under a minute, "{count}m" under an hour, else "{hours}h {minutes}m". A future `since` reads 0s.
        func format(_ elapsed: TimeInterval) -> String {
            let s = Int(max(0, elapsed).rounded(.down))
            if s < 60 { return seconds.replacingOccurrences(of: "{count}", with: "\(s)") }
            if s < 3_600 { return minutes.replacingOccurrences(of: "{count}", with: "\(s / 60)") }
            return hours.replacingOccurrences(of: "{hours}", with: "\(s / 3_600)")
                .replacingOccurrences(of: "{minutes}", with: "\(s % 3_600 / 60)")
        }
    }

    var summary: [String]
    /// Template with "{time}".
    var updated: String
    /// Overflow row text keyed by the number of items not shown.
    var more: [Int: String]
    var showFewer: String
    /// VoiceOver names for the click-to-expand card while collapsed and while expanded.
    var expandLabel: String
    var collapseLabel: String
    var statuses: [SessionStatus: String]
    var duration: Durations
    /// Title fallback for a thread whose provider is unknown.
    var agent: String

    func status(_ status: SessionStatus) -> String { statuses[status] ?? status.shortLabel }
    func updated(time: String) -> String { updated.replacingOccurrences(of: "{time}", with: time) }
    func more(hidden: Int) -> String? { hidden > 0 ? more[hidden] : nil }
    var summaryVariants: [String] { CardPresentation.summaryVariants(summary) }

    static let englishStatuses = Dictionary(uniqueKeysWithValues: SessionStatus.allCases.map { ($0, $0.shortLabel) })

    static let english = CardText(summary: [], updated: "Updated {time}", more: [:], showFewer: "Show fewer",
                                  expandLabel: "Show additional sessions", collapseLabel: "Hide additional sessions",
                                  statuses: englishStatuses, duration: Durations(), agent: "Agent")

    /// Fixture copy: English summary parts for `totals` and a "N more threads" line for each hidden count.
    static func english(totals: StatusCounts, hidden: some Sequence<Int>) -> CardText {
        var text = english
        text.summary = englishSummary(totals)
        for n in hidden where n > 0 { text.more[n] = n == 1 ? "1 more thread" : "\(n) more threads" }
        return text
    }

    /// Positive totals only, in group order: "2 need you · 1 working · 1 waiting · 1 done".
    static func englishSummary(_ totals: StatusCounts) -> [String] {
        var parts: [String] = []
        if totals.attention > 0 { parts.append(totals.attention == 1 ? "1 needs you" : "\(totals.attention) need you") }
        if totals.working > 0 { parts.append("\(totals.working) working") }
        if totals.waiting > 0 { parts.append("\(totals.waiting) waiting") }
        if totals.done > 0 { parts.append("\(totals.done) done") }
        return parts.isEmpty ? ["Nothing running"] : parts
    }
}

/// One project row (projects mode). Only the name, icon and counts ever reach the helper in this mode.
struct ProjectRow: Equatable {
    struct Count: Equatable {
        let status: SessionStatus
        let count: Int
    }

    let name: String
    var projectIcon: Data? = nil
    var attention = 0
    /// The most urgent attention status; nil iff attention is 0.
    var attentionStatus: SessionStatus? = nil
    var working = 0
    var done = 0

    /// Left to right: needs-you (most urgent status), working, done. Zero counts are omitted.
    var counts: [Count] {
        var out: [Count] = []
        if attention > 0, let attentionStatus { out.append(Count(status: attentionStatus, count: attention)) }
        if working > 0 { out.append(Count(status: .working, count: working)) }
        if done > 0 { out.append(Count(status: .done, count: done)) }
        return out
    }
}

/// Adaptive glass: light over a bright wallpaper, dark otherwise (and on any failure).
enum WallpaperTone {
    static let lightThreshold = 0.45

    /// WCAG relative luminance of an sRGB colour (components 0...1).
    static func relativeLuminance(red: Double, green: Double, blue: Double) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// Mean relative luminance of 8-bit RGBA pixels (premultiplied alpha is fine for an opaque wallpaper).
    static func averageLuminance(rgba: [UInt8]) -> Double? {
        let pixels = rgba.count / 4
        guard pixels > 0 else { return nil }
        var sum = 0.0
        for i in 0..<pixels {
            sum += relativeLuminance(red: Double(rgba[4 * i]) / 255, green: Double(rgba[4 * i + 1]) / 255, blue: Double(rgba[4 * i + 2]) / 255)
        }
        return sum / Double(pixels)
    }

    static func appearance(luminance: Double?) -> CardAppearance {
        guard let luminance, luminance.isFinite, luminance > lightThreshold else { return .dark }
        return .light
    }

    /// How macOS draws the desktop picture (NSWorkspace desktop image options).
    enum Placement: Equatable {
        /// Scaled to cover the screen, centred and cropped.
        case fill
        /// Scaled to fit inside the screen; the margins show the fill colour.
        case fit
        /// Each axis scaled to the screen.
        case stretch
        /// Native size, centred.
        case center
        /// Native size, shrunk to fit only when larger than the screen.
        case shrinkToFit
    }

    /// Where the image lands on the screen (screen-local points, y down). `image` is the image's size in points.
    static func drawnRect(screen: CGSize, image: CGSize, placement: Placement) -> CGRect {
        let fit = min(screen.width / image.width, screen.height / image.height)
        let scale: CGFloat = switch placement {
        case .fill: max(screen.width / image.width, screen.height / image.height)
        case .fit: fit
        case .stretch: 0
        case .center: 1
        case .shrinkToFit: min(1, fit)
        }
        guard placement != .stretch else { return CGRect(origin: .zero, size: screen) }
        let size = CGSize(width: image.width * scale, height: image.height * scale)
        return CGRect(x: (screen.width - size.width) / 2, y: (screen.height - size.height) / 2, width: size.width, height: size.height)
    }

    struct Sample: Equatable {
        /// The part of the image under the card, in unit coordinates (0...1, y down); nil when only margin is covered.
        let imageRect: CGRect?
        /// Share of the card's on-screen area that covers the image; the rest covers the fill colour.
        let coverage: Double
    }

    /// The card's rect (screen space, y up) against the drawn wallpaper. Nil when the card is off this screen.
    static func sample(card: CGRect, screen: CGRect, image: CGSize, placement: Placement) -> Sample? {
        guard screen.width > 0, screen.height > 0, image.width > 0, image.height > 0 else { return nil }
        let local = CGRect(x: card.minX - screen.minX, y: screen.maxY - card.maxY, width: card.width, height: card.height)
            .intersection(CGRect(origin: .zero, size: screen.size))
        guard !local.isNull, local.width > 0, local.height > 0 else { return nil }
        let drawn = drawnRect(screen: screen.size, image: image, placement: placement)
        let overlap = local.intersection(drawn)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return Sample(imageRect: nil, coverage: 0) }
        let unit = CGRect(x: (overlap.minX - drawn.minX) / drawn.width, y: (overlap.minY - drawn.minY) / drawn.height,
                          width: overlap.width / drawn.width, height: overlap.height / drawn.height)
        return Sample(imageRect: unit, coverage: Double(overlap.width * overlap.height / (local.width * local.height)))
    }

    /// Area-weighted luminance of image and fill colour. Nil when the image part is needed but unreadable.
    static func blend(image: Double?, fill: Double, coverage: Double) -> Double? {
        if coverage <= 0 { return fill }
        guard let image else { return nil }
        return coverage >= 1 ? image : image * coverage + fill * (1 - coverage)
    }
}
