import Foundation
import ImageIO

// stdin wire (v2): one JSON object per line, or `null` to clear. The contract lives with the desktop bridge
// (apps/desktop/src/lockScreen). Structural problems reject the line and keep the previous card; one malformed
// row or project is dropped; nothing here persists or reads T3 state.

enum LiveLimits {
    static let maxLineBytes = 64 * 1024
    static let maxRows = CardPresentation.expandedRowLimit
    static let maxCount = 9_999
    static let maxTitleCharacters = 120
    static let maxTitleInputCharacters = 2_000
    static let maxProviderCharacters = 64
    static let maxProjectNameCharacters = 80
    static let maxTextCharacters = 120
    static let maxSummaryParts = 8
    static let maxAsOfCharacters = 64
    /// Whole data URI, prefix included.
    static let maxProjectIconCharacters = 6_144
    /// A few KB of PNG can declare a huge canvas; anything larger than a favicon is refused before decoding.
    static let maxProjectIconPixels = 256
}

enum LiveParseError: Error, Equatable {
    case tooLong
    case notJSON
    /// Wrong JSON type or missing value for the named field.
    case shape(String)
    /// Value outside its bound for the named field.
    case range(String)
    case timestamp
    case tooManyRows
    /// `text` missing or malformed; names the field.
    case text(String)
}

struct LiveSnapshot: Equatable {
    let asOf: Date
    var mode: CardMode = .threads
    /// Header totals per group.
    let totals: StatusCounts
    /// Threads mode: all wire rows (<= 8), in the owner's order.
    var rows: [CardRow] = []
    /// Projects mode: all wire project rows (<= 8), in the owner's order.
    var projects: [ProjectRow] = []
    /// Items not shown when k (4...8) rows are shown.
    var hidden: [Int: Int] = [:]
    var text: CardText = .english

    var itemCount: Int { mode == .threads ? rows.count : projects.count }

    /// Empty snapshots (no rows, zero counts) keep the card hidden, like null.
    var hasContent: Bool { itemCount > 0 || totals.total > 0 }

    /// Rows beyond the collapsed four exist, so an expanded display has something to add.
    var hasMoreRows: Bool { itemCount > CardPresentation.rowLimit }

    func hiddenCount(showing rowLimit: Int) -> Int {
        hidden[min(max(rowLimit, CardPresentation.rowLimit), CardPresentation.expandedRowLimit)] ?? 0
    }

    /// Collapsed by default (four rows); pass a display state's `rowLimit` for the expanded card.
    func cardSnapshot(rowLimit: Int = CardPresentation.rowLimit) -> CardSnapshot {
        let limit = min(max(rowLimit, 0), CardPresentation.expandedRowLimit)
        let variants = text.summaryVariants
        return CardSnapshot(rows: Array(rows.prefix(limit)), projects: Array(projects.prefix(limit)), summary: variants[0],
                            overflow: text.more(hidden: hiddenCount(showing: limit)), asOf: asOf, summaryVariants: variants, text: text)
    }
}

enum LiveUpdate: Equatable {
    case snapshot(LiveSnapshot)
    case clear
}

enum LiveDecoder {
    static func decode(_ line: Data) -> Result<LiveUpdate, LiveParseError> {
        guard line.count <= LiveLimits.maxLineBytes else { return .failure(.tooLong) }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: line, options: [.fragmentsAllowed])
        } catch {
            return .failure(.notJSON)
        }
        if object is NSNull { return .success(.clear) }
        do {
            return .success(.snapshot(try snapshot(object)))
        } catch let error as LiveParseError {
            return .failure(error)
        } catch {
            return .failure(.notJSON)
        }
    }

    private static func snapshot(_ object: Any) throws -> LiveSnapshot {
        guard let message = object as? [String: Any] else { throw LiveParseError.shape("message") }
        let parsed = try parse(message)
        guard let asOfText = message["asOf"] as? String else { throw LiveParseError.shape("asOf") }
        guard asOfText.count <= LiveLimits.maxAsOfCharacters, let asOf = parseDate(asOfText) else {
            throw LiveParseError.timestamp
        }
        return LiveSnapshot(asOf: asOf, mode: parsed.mode, totals: parsed.totals, rows: parsed.rows, projects: parsed.projects,
                            hidden: parsed.hidden, text: parsed.text)
    }

    /// Safety net for a project whose name normalizes to nothing; the app sends a localized name.
    static let untitledProject = "Untitled project"

    private typealias Parsed = (mode: CardMode, totals: StatusCounts, rows: [CardRow], projects: [ProjectRow], hidden: [Int: Int], text: CardText)

    private static func parse(_ message: [String: Any]) throws -> Parsed {
        guard let raw = message["mode"] as? String, let mode = CardMode(rawValue: raw) else { throw LiveParseError.shape("mode") }
        guard let counts = message["counts"] as? [String: Any] else { throw LiveParseError.shape("counts") }
        let totals = StatusCounts(attention: try clamped(counts["attention"], "attention"), working: try clamped(counts["working"], "working"),
                                  waiting: try clamped(counts["waiting"], "waiting"), done: try clamped(counts["done"], "done"))
        // One malformed item is dropped; the rest of the card still draws. The inactive list is never read.
        let rows = mode == .threads ? try list(message, "rows").compactMap { try? row($0) } : []
        let projects = mode == .projects ? try list(message, "projects").compactMap { try? project($0) } : []
        var hidden: [Int: Int] = [:]
        if let rawHidden = message["hidden"], !(rawHidden is NSNull) {
            guard let object = rawHidden as? [String: Any] else { throw LiveParseError.shape("hidden") }
            for k in CardPresentation.rowLimit...CardPresentation.expandedRowLimit {
                guard let value = object[String(k)] else { continue }
                let n = try clamped(value, "hidden")
                if n > 0 { hidden[k] = n }
            }
        }
        return (mode, totals, rows, projects, hidden, try text(message["text"], hidden: hidden))
    }

    private static func list(_ message: [String: Any], _ key: String) throws -> [Any] {
        guard let items = message[key] as? [Any] else { throw LiveParseError.shape(key) }
        guard items.count <= LiveLimits.maxRows else { throw LiveParseError.tooManyRows }
        return items
    }

    /// A JSON integer (booleans and fractions are malformed), clamped to 0...maxCount.
    private static func clamped(_ value: Any?, _ key: String) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else {
            throw LiveParseError.shape(key)
        }
        let v = number.doubleValue
        guard v.isFinite, v.rounded() == v else { throw LiveParseError.shape(key) }
        return Int(min(max(v, 0), Double(LiveLimits.maxCount)))
    }

    private static func text(_ value: Any?, hidden: [Int: Int]) throws -> CardText {
        guard let object = value as? [String: Any] else { throw LiveParseError.text("text") }
        func string(_ raw: Any?, _ field: String) throws -> String {
            guard let s = raw as? String, s.count <= LiveLimits.maxTextCharacters,
                  let plain = LiveText.plain(s, limit: LiveLimits.maxTextCharacters) else { throw LiveParseError.text(field) }
            return plain
        }
        /// A template missing a placeholder falls back to the English template for that key.
        func template(_ raw: Any?, _ field: String, needs: [String], fallback: String) throws -> String {
            let value = try string(raw, field)
            return needs.allSatisfy(value.contains) ? value : fallback
        }
        func dictionary(_ field: String) throws -> [String: Any] {
            guard let d = object[field] as? [String: Any] else { throw LiveParseError.text(field) }
            return d
        }
        guard let rawSummary = object["summary"] as? [Any], rawSummary.count <= LiveLimits.maxSummaryParts else {
            throw LiveParseError.text("summary")
        }
        let summary = try rawSummary.map { try string($0, "summary") }
        var more: [Int: String] = [:]
        for (key, raw) in try dictionary("more") {
            guard let n = Int(key), n > 0, String(n) == key else { continue }
            more[n] = try string(raw, "more")
        }
        guard hidden.values.allSatisfy({ more[$0] != nil }) else { throw LiveParseError.text("more") }
        let rawStatuses = try dictionary("statuses")
        var statuses: [SessionStatus: String] = [:]
        for status in SessionStatus.allCases { statuses[status] = try string(rawStatuses[status.rawValue], "statuses") }
        let duration = try dictionary("duration")
        let english = CardText.english
        return CardText(summary: summary, updated: try template(object["updated"], "updated", needs: ["{time}"], fallback: english.updated),
                        more: more, showFewer: try string(object["showFewer"], "showFewer"), statuses: statuses,
                        duration: CardText.Durations(
                            seconds: try template(duration["seconds"], "duration", needs: ["{count}"], fallback: english.duration.seconds),
                            minutes: try template(duration["minutes"], "duration", needs: ["{count}"], fallback: english.duration.minutes),
                            hours: try template(duration["hours"], "duration", needs: ["{hours}", "{minutes}"], fallback: english.duration.hours)),
                        agent: try string(object["agent"], "agent"))
    }

    private static func project(_ object: Any) throws -> ProjectRow {
        guard let p = object as? [String: Any] else { throw LiveParseError.shape("project") }
        let rawName = (p["name"] as? String).flatMap { $0.count <= LiveLimits.maxTitleInputCharacters ? $0 : nil }
        let name = rawName.flatMap { LiveText.plain($0, limit: LiveLimits.maxProjectNameCharacters) } ?? untitledProject
        let attention = try clamped(p["attention"], "attention")
        var attentionStatus: SessionStatus?
        if attention > 0 {
            guard let raw = p["attentionStatus"] as? String, let status = SessionStatus(rawValue: raw), status.needsUser else {
                throw LiveParseError.shape("attentionStatus")
            }
            attentionStatus = status
        }
        return ProjectRow(name: name, projectIcon: ProjectIcon.decode(p["projectIcon"]), attention: attention,
                          attentionStatus: attentionStatus, working: try clamped(p["working"], "working"), done: try clamped(p["done"], "done"))
    }

    /// Absent or null -> nil; a string within `limit` -> the string; anything else is an error.
    private static func optionalString(_ object: [String: Any], _ key: String, limit: Int) throws -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw LiveParseError.shape(key) }
        guard text.count <= limit else { throw LiveParseError.range(key) }
        return text
    }

    private static func row(_ object: Any) throws -> CardRow {
        guard let row = object as? [String: Any] else { throw LiveParseError.shape("row") }
        guard let rawStatus = row["status"] as? String, let status = SessionStatus(rawValue: rawStatus) else {
            throw LiveParseError.shape("status")
        }
        let provider = try optionalString(row, "provider", limit: LiveLimits.maxProviderCharacters)
        let title = try optionalString(row, "title", limit: LiveLimits.maxTitleInputCharacters)
        let since = status.showsElapsed ? (row["since"] as? String).flatMap(lenientDate) : nil
        return CardRow(status: status, title: LiveText.title(title), provider: .forProvider(provider),
                       since: since, projectIcon: ProjectIcon.decode(row["projectIcon"]))
    }

    private static func lenientDate(_ text: String) -> Date? {
        text.count <= LiveLimits.maxAsOfCharacters ? parseDate(text) : nil
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

/// `projectIcon`: a small PNG data URI, or nil for anything else (the row then shows the agent mark).
enum ProjectIcon {
    static let prefix = "data:image/png;base64,"

    static func decode(_ value: Any?) -> Data? {
        guard let uri = value as? String, uri.count <= LiveLimits.maxProjectIconCharacters, uri.hasPrefix(prefix),
              let png = Data(base64Encoded: String(uri.dropFirst(prefix.count))), isSmallPNG(png),
              let source = CGImageSourceCreateWithData(png as CFData, nil),
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { return nil }
        return png
    }

    /// PNG signature and an IHDR within 1...maxProjectIconPixels on each side, checked before ImageIO sees it.
    private static func isSmallPNG(_ png: Data) -> Bool {
        let bytes = [UInt8](png.prefix(24))
        guard bytes.count == 24, bytes[0..<8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
              bytes[12..<16] == [0x49, 0x48, 0x44, 0x52] else { return false }
        func be32(_ o: Int) -> Int { bytes[o..<o + 4].reduce(0) { $0 << 8 | Int($1) } }
        let range = 1...LiveLimits.maxProjectIconPixels
        return range.contains(be32(16)) && range.contains(be32(20))
    }
}

enum LiveText {
    /// Plain, single-line display text. Control and separator characters become spaces; invisible format
    /// characters (bidi overrides, zero-width spaces, BOM) are dropped, keeping ZWJ/ZWNJ for emoji and scripts;
    /// whitespace is collapsed; the result is capped with an ellipsis. Never interpreted as markup.
    /// Nil (withheld or blank) lets the row show the agent's name instead.
    static func title(_ raw: String?) -> String? {
        raw.flatMap { plain($0, limit: LiveLimits.maxTitleCharacters) }
    }

    static func plain(_ raw: String, limit: Int) -> String? {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                scalars.append(" ")
            case .format:
                if scalar.value == 0x200C || scalar.value == 0x200D { scalars.append(scalar) }
            default:
                scalars.append(scalar)
            }
        }
        let collapsed = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)) + "…"
    }
}

enum LineFrame: Equatable {
    case line(Data)
    /// A line longer than maxLineBytes; its bytes were discarded up to the next newline.
    case oversized
}

/// Splits a byte stream on "\n" while holding at most maxLineBytes.
struct LineFramer {
    private var buffer = Data()
    private var discarding = false

    var buffered: Int { buffer.count }

    mutating func feed(_ data: Data) -> [LineFrame] {
        var frames: [LineFrame] = []
        var start = data.startIndex
        while start < data.endIndex {
            let newline = data[start...].firstIndex(of: 0x0A)
            let end = newline ?? data.endIndex
            let piece = data[start..<end]
            if discarding {
                if newline != nil { discarding = false }
            } else if buffer.count + piece.count > LiveLimits.maxLineBytes {
                frames.append(.oversized)
                buffer.removeAll()
                discarding = newline == nil
            } else {
                buffer.append(piece)
                if newline != nil {
                    frames.append(.line(Data(buffer)))
                    buffer.removeAll()
                }
            }
            start = newline.map { data.index(after: $0) } ?? data.endIndex
        }
        return frames
    }
}
