import Foundation

/// Wire statuses in the fixed priority order the owning app sorts by (lower-case on the wire). Rows are drawn in
/// the order given; `priority` documents that order and is not used to re-sort.
enum SessionStatus: String, CaseIterable, Equatable {
    case approval, input, request, limited, failed, working, waiting, done

    var shortLabel: String {
        switch self {
        case .approval: "Approval"
        case .input: "Input"
        case .request: "Request"
        case .limited: "Limited"
        case .failed: "Failed"
        case .working: "Working"
        case .waiting: "Waiting"
        case .done: "Done"
        }
    }

    /// Spoken form; only Limited says what ran out.
    var accessibilityLabel: String { self == .limited ? "Usage limit reached" : shortLabel }

    /// Only these carry a `since` on the wire and show elapsed time after the label.
    var showsElapsed: Bool { self == .working || self == .waiting }

    /// 0 = most urgent. Same as the wire order above.
    var priority: Int { Self.allCases.firstIndex(of: self)! }

    var group: StatusGroup {
        switch self {
        case .approval, .input, .request, .limited, .failed: .attention
        case .working: .working
        case .waiting: .waiting
        case .done: .done
        }
    }

    var needsUser: Bool { group == .attention }
}

/// Count groups. Attention = approval/input/request/limited/failed; waiting and done are separate.
enum StatusGroup: CaseIterable, Equatable {
    case attention, working, waiting, done
}

struct StatusCounts: Equatable {
    var attention = 0, working = 0, waiting = 0, done = 0

    subscript(group: StatusGroup) -> Int {
        get {
            switch group {
            case .attention: attention
            case .working: working
            case .waiting: waiting
            case .done: done
            }
        }
        set {
            switch group {
            case .attention: attention = newValue
            case .working: working = newValue
            case .waiting: waiting = newValue
            case .done: done = newValue
            }
        }
    }

    var total: Int { attention + working + waiting + done }
}

/// T3 provider driver kinds (packages/contracts PROVIDER_DISPLAY_NAMES), each with bundled artwork in ProviderIconData.
enum ProviderDriver: String, CaseIterable, Equatable {
    case antigravity, codex, claudeAgent, cursor, grok, fx, kiro, muse, acpRegistry, pi, opencode

    var displayName: String {
        switch self {
        case .antigravity: "Antigravity"
        case .codex: "Codex"
        case .claudeAgent: "Claude"
        case .cursor: "Cursor"
        case .grok: "Grok"
        case .fx: "fx"
        case .kiro: "Kiro"
        case .muse: "Muse Code"
        case .acpRegistry: "ACP Registry"
        case .pi: "Pi"
        case .opencode: "OpenCode"
        }
    }
}

/// Provider mark: the provider's bundled T3 icon, or a neutral glyph for unknown or missing providers.
enum ProviderMark: Equatable {
    case brand(ProviderDriver)
    case neutral

    /// Provider identifiers as T3 names them; matched case-insensitively ("claude"/"claudeCode" kept as aliases of
    /// claudeAgent). Anything else is neutral (unbranded).
    static func forProvider(_ id: String?) -> ProviderMark {
        guard let key = id?.lowercased() else { return .neutral }
        if key == "claude" || key == "claudecode" { return .brand(.claudeAgent) }
        return ProviderDriver.allCases.first { $0.rawValue.lowercased() == key }.map(ProviderMark.brand) ?? .neutral
    }

    /// SF Symbol used only for the neutral mark.
    static let neutralSymbolName = "circle.dotted"

}

/// One rendered row. `title` is plain text (nil when withheld); the view never interprets it as markup.
struct CardRow: Equatable {
    let status: SessionStatus
    let title: String?
    let provider: ProviderMark
    /// Mac clock; only working/waiting rows carry it.
    var since: Date? = nil
    /// Validated PNG bytes (ProjectIcon.decode); nil falls back to the agent mark.
    var projectIcon: Data? = nil

    /// The title lane: the thread title, else the agent's name (drawn secondary); unknown agents read `text.agent`.
    func displayTitle(_ text: CardText = .english) -> String {
        if let title { return title }
        if case .brand(let driver) = provider { return driver.displayName }
        return text.agent
    }
    var titleIsFallback: Bool { title == nil }

    /// "Working 21m"; the bare label when there is no elapsed time to show.
    func statusText(now: Date, text: CardText = .english) -> String {
        guard status.showsElapsed, let since else { return text.status(status) }
        return text.status(status) + " " + text.duration.format(now.timeIntervalSince(since))
    }

    /// When `statusText` next changes, or nil when it never does.
    func nextStatusChange(after now: Date) -> Date? {
        guard status.showsElapsed, let since else { return nil }
        return since.addingTimeInterval(CardPresentation.nextElapsedBoundary(now.timeIntervalSince(since)))
    }
}

struct CardSnapshot: Equatable {
    var rows: [CardRow]
    /// Projects mode only; `rows` is then empty.
    var projects: [ProjectRow] = []
    let summary: String
    /// The footer line: "N more threads", "Show fewer", or nil.
    let overflow: String?
    let asOf: Date
    /// Tighter forms of `summary` (same words); empty means use `summary` as is.
    var summaryVariants: [String] = []
    var text: CardText = .english

    var itemCount: Int { rows.count + projects.count }
}

enum CardPresentation {
    /// Collapsed card: four rows.
    static let rowLimit = 4
    /// Expanded live card: up to eight rows, when the safe band has room (CardPlacement.lockLayout).
    static let expandedRowLimit = 8

    static func summary(_ totals: StatusCounts) -> String { summaryVariants(CardText.englishSummary(totals))[0] }

    /// Parts joined with " · ", then with thin and hair spaces around the dot, so every part stays visible in a
    /// narrow header. Longest first.
    static func summaryVariants(_ parts: [String]) -> [String] {
        guard parts.count > 1 else { return [parts.first ?? ""] }
        return [" · ", "\u{2009}·\u{2009}", "\u{200A}·\u{200A}"].map { parts.joined(separator: $0) }
    }

    /// Header freshness: the time alone, hours and minutes ("9:09 PM").
    static func timeText(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("jm")
        return formatter.string(from: date)
    }

    static func elapsedText(_ seconds: TimeInterval) -> String { CardText.Durations().format(seconds) }

    /// Elapsed seconds at which `elapsedText` next changes: the next second under a minute, else the next minute.
    static func nextElapsedBoundary(_ seconds: TimeInterval) -> TimeInterval {
        let s = max(0, seconds).rounded(.down)
        return s < 60 ? s + 1 : ((s / 60).rounded(.down) + 1) * 60
    }
}
