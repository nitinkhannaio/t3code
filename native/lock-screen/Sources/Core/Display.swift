import Foundation

/// Live card display mode: collapsed (four rows) or expanded (up to `capacity`, at most eight).
/// Pure and tested. Unified copy: only CardToggle (Interaction.swift) calls `expand()`, and only after a verified
/// plain left press+release on the painted card in live-lock with --expand-on-click. Otherwise it stays collapsed.
struct CardDisplayState: Equatable {
    enum Mode: Equatable { case collapsed, expanded }

    /// Rows the placed panel can hold (CardPlacement.lockLayout); 4...8.
    let capacity: Int
    private(set) var mode: Mode = .collapsed
    /// Whether the current snapshot has rows beyond the collapsed four.
    private(set) var hasMoreRows = false

    init(capacity: Int = CardPresentation.rowLimit) {
        self.capacity = min(max(capacity, CardPresentation.rowLimit), CardPresentation.expandedRowLimit)
    }

    /// Rows to draw for the current mode.
    var rowLimit: Int { mode == .expanded ? capacity : CardPresentation.rowLimit }
    var canExpand: Bool { mode == .collapsed && hasMoreRows && capacity > CardPresentation.rowLimit }

    /// Returns true when the mode changed.
    @discardableResult
    mutating func expand() -> Bool {
        guard canExpand else { return false }
        mode = .expanded
        return true
    }

    @discardableResult
    mutating func collapse() -> Bool {
        guard mode == .expanded else { return false }
        mode = .collapsed
        return true
    }

    /// Lock or unlock (either direction) always starts the next view collapsed.
    mutating func lockChanged() { mode = .collapsed }

    /// `null` / empty snapshot.
    mutating func cleared() {
        hasMoreRows = false
        mode = .collapsed
    }

    /// A new snapshot; collapses when it no longer has rows beyond the first four.
    mutating func snapshot(_ snapshot: LiveSnapshot) {
        hasMoreRows = snapshot.hasMoreRows
        if !snapshot.hasContent { cleared() } else if !hasMoreRows { mode = .collapsed }
    }
}
