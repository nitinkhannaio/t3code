import CoreGraphics
import Foundation

/// Lucide icons the card draws, as their SVG elements copied verbatim from lucide-react 0.564.0
/// (dist/esm/icons/*.js, ISC license; see NOTICE). Stroked at 2 units on the 24-unit grid with round caps and joins,
/// so they stay vector-crisp at any size. `path` is in grid units, y down (SVG space).
enum LucideGlyph: CaseIterable {
    case shieldQuestionMark, messageCircleQuestionMark, userRound, circleAlert, circleDashed, circleDotDashed, circleCheck
    case chevronRight

    enum Element: Equatable {
        case path(String)
        case circle(cx: CGFloat, cy: CGFloat, r: CGFloat)
        case line(x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat)
    }

    static let grid: CGFloat = 24
    static let strokeWidth: CGFloat = 2

    var elements: [Element] {
        switch self {
        case .shieldQuestionMark: [
            .path("M20 13c0 5-3.5 7.5-7.66 8.95a1 1 0 0 1-.67-.01C7.5 20.5 4 18 4 13V6a1 1 0 0 1 1-1c2 0 4.5-1.2 6.24-2.72a1.17 1.17 0 0 1 1.52 0C14.51 3.81 17 5 19 5a1 1 0 0 1 1 1z"),
            .path("M9.1 9a3 3 0 0 1 5.82 1c0 2-3 3-3 3"),
            .path("M12 17h.01"),
        ]
        case .messageCircleQuestionMark: [
            .path("M2.992 16.342a2 2 0 0 1 .094 1.167l-1.065 3.29a1 1 0 0 0 1.236 1.168l3.413-.998a2 2 0 0 1 1.099.092 10 10 0 1 0-4.777-4.719"),
            .path("M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"),
            .path("M12 17h.01"),
        ]
        case .userRound: [
            .circle(cx: 12, cy: 8, r: 5),
            .path("M20 21a8 8 0 0 0-16 0"),
        ]
        case .circleAlert: [
            .circle(cx: 12, cy: 12, r: 10),
            .line(x1: 12, y1: 8, x2: 12, y2: 12),
            .line(x1: 12, y1: 16, x2: 12.01, y2: 16),
        ]
        case .circleDashed: [
            .path("M10.1 2.182a10 10 0 0 1 3.8 0"),
            .path("M13.9 21.818a10 10 0 0 1-3.8 0"),
            .path("M17.609 3.721a10 10 0 0 1 2.69 2.7"),
            .path("M2.182 13.9a10 10 0 0 1 0-3.8"),
            .path("M20.279 17.609a10 10 0 0 1-2.7 2.69"),
            .path("M21.818 10.1a10 10 0 0 1 0 3.8"),
            .path("M3.721 6.391a10 10 0 0 1 2.7-2.69"),
            .path("M6.391 20.279a10 10 0 0 1-2.69-2.7"),
        ]
        case .circleDotDashed: [
            .path("M10.1 2.18a9.93 9.93 0 0 1 3.8 0"),
            .path("M17.6 3.71a9.95 9.95 0 0 1 2.69 2.7"),
            .path("M21.82 10.1a9.93 9.93 0 0 1 0 3.8"),
            .path("M20.29 17.6a9.95 9.95 0 0 1-2.7 2.69"),
            .path("M13.9 21.82a9.94 9.94 0 0 1-3.8 0"),
            .path("M6.4 20.29a9.95 9.95 0 0 1-2.69-2.7"),
            .path("M2.18 13.9a9.93 9.93 0 0 1 0-3.8"),
            .path("M3.71 6.4a9.95 9.95 0 0 1 2.7-2.69"),
            .circle(cx: 12, cy: 12, r: 1),
        ]
        case .circleCheck: [
            .circle(cx: 12, cy: 12, r: 10),
            .path("m9 12 2 2 4-4"),
        ]
        case .chevronRight: [
            .path("m9 18 6-6-6-6"),
        ]
        }
    }

    /// Nil only if an element's path data uses a command SVGPath does not handle (tests pin that every glyph parses).
    var path: CGPath? {
        let out = CGMutablePath()
        for element in elements {
            switch element {
            case .path(let d):
                guard let parsed = SVGPath.parse(d) else { return nil }
                out.addPath(parsed)
            case .circle(let cx, let cy, let r):
                out.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
            case .line(let x1, let y1, let x2, let y2):
                out.move(to: CGPoint(x: x1, y: y1))
                out.addLine(to: CGPoint(x: x2, y: y2))
            }
        }
        return out
    }
}

/// T3's mark as the iPhone Live Activity draws it (apps/mobile/assets/widget/T3Mark.svg), filled, in its viewBox.
enum T3Mark {
    static let viewBox = CGRect(x: 7, y: 29, width: 111, height: 74)
    static let path = SVGPath.parse(
        "M33.4509 93V47.56H15.5309V37H64.3309V47.56H46.4109V93H33.4509ZM86.7253 93.96C82.832 93.96 78.9653 93.4533 75.1253 92.44C71.2853 91.3733 68.032 89.88 65.3653 87.96L70.4053 78.04C72.5386 79.5867 75.0186 80.8133 77.8453 81.72C80.672 82.6267 83.5253 83.08 86.4053 83.08C89.6586 83.08 92.2186 82.44 94.0853 81.16C95.952 79.88 96.8853 78.12 96.8853 75.88C96.8853 73.7467 96.0586 72.0667 94.4053 70.84C92.752 69.6133 90.0853 69 86.4053 69H80.4853V60.44L96.0853 42.76L97.5253 47.4H68.1653V37H107.365V45.4L91.8453 63.08L85.2853 59.32H89.0453C95.9253 59.32 101.125 60.8667 104.645 63.96C108.165 67.0533 109.925 71.0267 109.925 75.88C109.925 79.0267 109.099 81.9867 107.445 84.76C105.792 87.48 103.259 89.6933 99.8453 91.4C96.432 93.1067 92.0586 93.96 86.7253 93.96Z"
    )
}

extension SessionStatus {
    /// The status icons T3's sidebar uses for each state.
    var glyph: LucideGlyph {
        switch self {
        case .approval: .shieldQuestionMark
        case .input: .messageCircleQuestionMark
        case .request: .userRound
        case .limited, .failed: .circleAlert
        case .working: .circleDashed
        case .waiting: .circleDotDashed
        case .done: .circleCheck
        }
    }
}

/// Minimal SVG path-data parser for the commands Lucide's glyphs use: M L H V C A Z, absolute and relative, with
/// implicit repeats. Arcs must be circular and unrotated (every Lucide arc is).
enum SVGPath {
    static func parse(_ d: String) -> CGPath? {
        var scanner = Tokens(Array(d.utf8))
        let path = CGMutablePath()
        var current = CGPoint.zero, start = CGPoint.zero
        var command: UInt8?
        while scanner.skipSeparators() {
            if let c = scanner.command() {
                command = c
            } else if command == nil {
                return nil
            }
            guard let c = command else { return nil }
            let relative = c >= UInt8(ascii: "a")
            func point() -> CGPoint? {
                guard let x = scanner.number(), let y = scanner.number() else { return nil }
                return relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
            }
            switch c | 0x20 {
            case UInt8(ascii: "m"):
                guard let p = point() else { return nil }
                path.move(to: p)
                current = p; start = p
                command = relative ? UInt8(ascii: "l") : UInt8(ascii: "L")
            case UInt8(ascii: "l"):
                guard let p = point() else { return nil }
                path.addLine(to: p)
                current = p
            case UInt8(ascii: "h"):
                guard let x = scanner.number() else { return nil }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
            case UInt8(ascii: "v"):
                guard let y = scanner.number() else { return nil }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
            case UInt8(ascii: "c"):
                guard let c1 = point(), let c2 = point(), let p = point() else { return nil }
                path.addCurve(to: p, control1: c1, control2: c2)
                current = p
            case UInt8(ascii: "a"):
                guard let rx = scanner.number(), let ry = scanner.number(), let rotation = scanner.number(),
                      let large = scanner.flag(), let sweep = scanner.flag(), let p = point(),
                      rx == ry, rotation == 0 else { return nil }
                addArc(to: path, from: current, to: p, radius: rx, large: large, sweep: sweep)
                current = p
            case UInt8(ascii: "z"):
                path.closeSubpath()
                current = start
                command = nil
            default:
                return nil
            }
        }
        return path
    }

    /// SVG endpoint arc (F.6.5) with rx == ry and no rotation, as a CG arc. Built in SVG space (y down), where a
    /// sweep flag of 1 means increasing angle, i.e. CG's `clockwise: false`.
    private static func addArc(to path: CGMutablePath, from p1: CGPoint, to p2: CGPoint, radius: CGFloat, large: Bool, sweep: Bool) {
        guard p1 != p2 else { return }
        guard radius > 0 else { return path.addLine(to: p2) }
        let hx = (p1.x - p2.x) / 2, hy = (p1.y - p2.y) / 2
        let d2 = hx * hx + hy * hy
        let r = max(radius, sqrt(d2))
        let coef = (large != sweep ? 1 : -1) * sqrt(max(0, (r * r - d2) / d2))
        let center = CGPoint(x: coef * hy + (p1.x + p2.x) / 2, y: -coef * hx + (p1.y + p2.y) / 2)
        let a1 = atan2(p1.y - center.y, p1.x - center.x), a2 = atan2(p2.y - center.y, p2.x - center.x)
        path.addArc(center: center, radius: r, startAngle: a1, endAngle: a2, clockwise: !sweep)
    }

    private struct Tokens {
        let bytes: [UInt8]
        var i = 0
        init(_ bytes: [UInt8]) { self.bytes = bytes }

        /// Skips spaces and commas; false at the end.
        mutating func skipSeparators() -> Bool {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x2C || bytes[i] == 0x0A || bytes[i] == 0x09 { i += 1 }
            return i < bytes.count
        }

        mutating func command() -> UInt8? {
            let b = bytes[i]
            guard (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A), b != UInt8(ascii: "e"), b != UInt8(ascii: "E") else { return nil }
            i += 1
            return b
        }

        /// Arc flags are a single 0/1 and may abut the next number.
        mutating func flag() -> Bool? {
            guard skipSeparators(), bytes[i] == 0x30 || bytes[i] == 0x31 else { return nil }
            defer { i += 1 }
            return bytes[i] == 0x31
        }

        mutating func number() -> CGFloat? {
            guard skipSeparators() else { return nil }
            let begin = i
            if bytes[i] == 0x2D || bytes[i] == 0x2B { i += 1 }
            var dot = false, digits = false
            while i < bytes.count {
                let b = bytes[i]
                if b >= 0x30 && b <= 0x39 { digits = true; i += 1 } else if b == 0x2E && !dot { dot = true; i += 1 } else { break }
            }
            if digits, i < bytes.count, bytes[i] == 0x65 || bytes[i] == 0x45 {
                i += 1
                if i < bytes.count, bytes[i] == 0x2D || bytes[i] == 0x2B { i += 1 }
                while i < bytes.count, bytes[i] >= 0x30 && bytes[i] <= 0x39 { i += 1 }
            }
            guard digits, let value = Double(String(decoding: bytes[begin..<i], as: UTF8.self)) else { i = begin; return nil }
            return CGFloat(value)
        }
    }
}
