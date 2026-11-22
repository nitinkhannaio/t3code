import Foundation

enum PresenterEvent: Equatable {
    case started(locked: Bool)
    case lockChanged(locked: Bool)
    case screensWoke
    case privateFailed(code: Int32)
    /// Whether the latest stdin snapshot has anything to show (null / empty -> false).
    case liveContent(Bool)
    /// stdin reached EOF or failed.
    case inputClosed
    case interrupted
}

enum PresenterAction: Equatable {
    case show
    case hide
    case attachPrivate
    case reassertPrivate
    case detachPrivate
    case teardownPrivate
    case exit(code: Int32, reason: String)
}

/// Pure decision logic. The AppKit runner performs the actions; nothing here touches the window server.
/// The card is shown only while locked with content, and every way out hides it before the space is torn down.
struct PresenterStateMachine {
    private(set) var locked = false
    private(set) var shown = false
    private(set) var attached = false
    private(set) var finished = false
    private(set) var hasContent = false

    /// Re-adoption delays after attach or wake; loginwindow rebuilds shown spaces after it reports a wake.
    static let reassertDelays: [TimeInterval] = [0.12, 0.5, 1.0, 2.0]

    mutating func handle(_ event: PresenterEvent) -> [PresenterAction] {
        guard !finished else { return [] }
        switch event {
        case .started(let isLocked):
            locked = isLocked
            if isLocked {
                return finish(code: 2, reason: "Start this while the Mac is unlocked, then lock it.")
            }
            return converge()

        case .lockChanged(let isLocked):
            guard isLocked != locked else { return [] }
            locked = isLocked
            return converge()

        case .liveContent(let present):
            guard present != hasContent else { return [] }
            hasContent = present
            return converge()

        case .screensWoke:
            return locked && attached && shown ? [.reassertPrivate] : []

        case .privateFailed(let code):
            return finish(code: 3, reason: "SkyLight call failed (CGError \(code)); hid the card and stopped.")

        case .inputClosed:
            return finish(code: 0, reason: "Input closed.")

        case .interrupted:
            return finish(code: 0, reason: "Interrupted.")
        }
    }

    /// Show precedes attach (the window must be ordered in); hide precedes detach (order out, then hide the space).
    private mutating func converge() -> [PresenterAction] {
        let want = locked && hasContent
        guard want != shown else { return [] }
        shown = want
        if want {
            attached = true
            return [.show, .attachPrivate]
        }
        let detach: [PresenterAction] = attached ? [.detachPrivate] : []
        attached = false
        return [.hide] + detach
    }

    private mutating func finish(code: Int32, reason: String) -> [PresenterAction] {
        finished = true
        var actions: [PresenterAction] = []
        if shown {
            shown = false
            actions.append(.hide)
        }
        attached = false
        actions.append(.teardownPrivate)
        actions.append(.exit(code: code, reason: reason))
        return actions
    }
}
