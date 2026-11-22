import Foundation

enum CardAppearance: String { case dark, light }

/// Offscreen render fixtures (made-up text). Threads: `mixed` (four statuses, nothing hidden), `all-states` (one row
/// per status), `six-rows` (expanded hides nothing), `overflow` (collapsed with a more-line), `titles-off` (agent
/// names), `long-text` (long title, project icons), `threads` (13 threads, 8 on the wire), `threads-six`.
/// Projects: `projects` (the approved project view). `german-*`: long localized copy.
enum RenderSample: String, Equatable, CaseIterable {
    case mixed, allStates = "all-states", sixRows = "six-rows", overflow, titlesOff = "titles-off", longText = "long-text"
    case threads, threadsSix = "threads-six", projects, germanThreads = "german-threads", germanProjects = "german-projects"
}

enum Command: Equatable {
    case run(RunOptions)
    /// `appearance` nil: chosen from `backdrop` like the live card chooses from the wallpaper.
    case renderPNG(out: String, appearance: CardAppearance?, sample: RenderSample, expanded: Bool = false, width: Double = 372,
                   interactive: Bool = false, backdrop: String? = nil)
    /// Offscreen AppKit layout check over every fixture, width and display mode. No window.
    case layoutCheck
    /// Offscreen AppKit check of the whole-card toggle (panels are never ordered in).
    case interactionCheck
    case help
}

struct RunOptions: Equatable {
    /// nil: adaptive, from the wallpaper behind the card.
    var appearance: CardAppearance? = nil
    var allowUntestedOS = false
    /// Click anywhere on the painted card to expand/collapse (opt-in; fails closed).
    var expandOnClick = false
}

struct ArgumentError: Error, Equatable, CustomStringConvertible {
    let description: String
}

enum Arguments {
    static let privateFlag = "--private-skylight"

    static let usage = """
    t3-glass-card — T3 Code's lock-screen status card (no network; never reads T3 files)

      t3-glass-card live-lock --private-skylight [--expand-on-click] [--allow-untested-os] [--appearance auto|dark|light]
      t3-glass-card render-png --out FILE [--appearance dark|light] [--sample \(RenderSample.allCases.map(\.rawValue).joined(separator: "|"))]
                               [--display collapsed|expanded] [--width 300-372] [--interactive]
                               [--backdrop IMAGE [--appearance auto]]   offscreen render, no window
      t3-glass-card layout-check       offscreen clipping check of every fixture (no window)
      t3-glass-card interaction-check  offscreen check of the whole-card toggle (no window is ever ordered in)

    live-lock reads newline-delimited JSON snapshots from stdin (a pipe from the owning app), keeps only the latest in
    memory, shows the card only while locked with a non-empty snapshot, hides on `null`, and exits when stdin closes.
    --expand-on-click  while verifiably locked, attached and visible, with more than four rows, a plain left
                       press+release on the painted card toggles collapsed/expanded.
    """

    static func parse(_ args: [String]) throws -> Command {
        guard let verb = args.first else { return .help }
        var rest = Array(args.dropFirst())

        func take(_ flag: String) throws -> String? {
            guard let index = rest.firstIndex(of: flag) else { return nil }
            guard index + 1 < rest.count else { throw ArgumentError(description: "\(flag) needs a value") }
            let value = rest[index + 1]
            rest.removeSubrange(index...(index + 1))
            return value
        }
        func flag(_ name: String) -> Bool {
            guard let index = rest.firstIndex(of: name) else { return false }
            rest.remove(at: index)
            return true
        }
        func appearance(default fallback: CardAppearance?) throws -> CardAppearance? {
            guard let raw = try take("--appearance") else { return fallback }
            if raw == "auto" { return nil }
            guard let value = CardAppearance(rawValue: raw) else { throw ArgumentError(description: "--appearance must be auto, dark or light") }
            return value
        }
        func finish<T>(_ value: T) throws -> T {
            guard rest.isEmpty else { throw ArgumentError(description: "Unknown arguments: \(rest.joined(separator: " "))") }
            return value
        }

        switch verb {
        case "help", "--help", "-h":
            return .help
        case "layout-check":
            return try finish(.layoutCheck)
        case "interaction-check":
            return try finish(.interactionCheck)
        case "render-png":
            guard let out = try take("--out") else { throw ArgumentError(description: "render-png needs --out FILE") }
            let look = try appearance(default: .dark)
            let backdrop = try take("--backdrop")
            if look == nil, backdrop == nil { throw ArgumentError(description: "--appearance auto needs --backdrop FILE") }
            var sample = RenderSample.mixed
            if let raw = try take("--sample") {
                guard let value = RenderSample(rawValue: raw) else {
                    throw ArgumentError(description: "--sample must be one of \(RenderSample.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                sample = value
            }
            var expanded = false
            if let raw = try take("--display") {
                guard ["collapsed", "expanded"].contains(raw) else { throw ArgumentError(description: "--display must be collapsed or expanded") }
                expanded = raw == "expanded"
            }
            var width = Double(CardMetrics.width)
            if let raw = try take("--width") {
                guard let value = Double(raw), Double(CardMetrics.minWidth)...Double(CardMetrics.width) ~= value else {
                    throw ArgumentError(description: "--width must be between \(Int(CardMetrics.minWidth)) and \(Int(CardMetrics.width))")
                }
                width = value
            }
            let interactive = flag("--interactive")
            return try finish(.renderPNG(out: out, appearance: look, sample: sample, expanded: expanded, width: width,
                                         interactive: interactive, backdrop: backdrop))
        case "live-lock":
            var options = RunOptions()
            options.appearance = try appearance(default: nil)
            guard flag(privateFlag) else {
                throw ArgumentError(description: "live-lock uses private SkyLight calls; pass \(privateFlag) to select it explicitly")
            }
            options.allowUntestedOS = flag("--allow-untested-os")
            options.expandOnClick = flag("--expand-on-click")
            return try finish(.run(options))
        default:
            throw ArgumentError(description: "Unknown command \(verb)")
        }
    }

    /// The private route was assessed against macOS 26.2 and 26.5.
    static func isTestedOS(major: Int, minor: Int) -> Bool {
        major == 26 && (minor == 2 || minor == 5)
    }
}
