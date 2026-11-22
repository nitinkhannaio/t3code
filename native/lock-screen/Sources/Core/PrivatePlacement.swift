import Foundation

/// The private SkyLight calls, one method per function; the app wraps libT3SkyLightBackend, tests use a mock.
/// Only `createSpace` returns a meaningful value (a space ID, 0 on failure); the others are void.
protocol PrivateSpaceOperations {
    func createSpace() -> UInt64
    func setAbsoluteLevel(space: UInt64, level: Int32)
    func showSpace(_ space: UInt64)
    func addWindow(_ window: Int32, to space: UInt64)
    func hideSpace(_ space: UInt64)
    /// false when SLSSpaceDestroy is not exported (it is optional); true once the void call returned.
    func destroySpace(_ space: UInt64) -> Bool
}

enum PrivateStep: String, Equatable {
    case createSpace = "SLSSpaceCreate"
    case setAbsoluteLevel = "SLSSpaceSetAbsoluteLevel"
    case showSpaces = "SLSShowSpaces"
    case addWindows = "SLSSpaceAddWindowsAndRemoveFromSpaces"
    case hideSpaces = "SLSHideSpaces"
    case destroySpace = "SLSSpaceDestroy"
}

enum PrivateStepResult: Equatable {
    /// A void call returned; there is no status to report.
    case voidCompleted
    case spaceID(UInt64)
    case unavailable
}

struct PrivateStepRecord: Equatable {
    let step: PrivateStep
    let result: PrivateStepResult

    var description: String {
        switch result {
        case .voidCompleted: return "\(step.rawValue) -> void call completed (no status returned)"
        case .spaceID(let id): return "\(step.rawValue) -> space \(id)"
        case .unavailable: return "\(step.rawValue) -> not exported; skipped"
        }
    }
}

struct PrivatePlacementResult: Equatable {
    var steps: [PrivateStepRecord] = []
    /// A known failure, which stops the run: -1 invalid window or no space to reassert, -2 SLSSpaceCreate returned 0.
    var failure: Int32?
}

/// Call order follows SkyLightWindow (create -> absolute level 400 -> show -> add window), plus re-assert, detach on
/// unlock and teardown on exit. Never aborts on a void call; aborts only on the known failures above.
struct PrivatePlacement {
    static let notificationCenterAtScreenLockLevel: Int32 = 400
    private(set) var space: UInt64 = 0

    mutating func attach(window: Int32, using ops: PrivateSpaceOperations) -> PrivatePlacementResult {
        guard window > 0 else { return PrivatePlacementResult(failure: -1) }
        var result = PrivatePlacementResult()
        if space == 0 {
            let created = ops.createSpace()
            result.steps.append(.init(step: .createSpace, result: .spaceID(created)))
            guard created != 0 else {
                result.failure = -2
                return result
            }
            space = created
            ops.setAbsoluteLevel(space: space, level: Self.notificationCenterAtScreenLockLevel)
            result.steps.append(.init(step: .setAbsoluteLevel, result: .voidCompleted))
        }
        let shown = reassert(window: window, using: ops)
        result.steps += shown.steps
        result.failure = shown.failure
        return result
    }

    func reassert(window: Int32, using ops: PrivateSpaceOperations) -> PrivatePlacementResult {
        guard space != 0, window > 0 else { return PrivatePlacementResult(failure: -1) }
        ops.showSpace(space)
        ops.addWindow(window, to: space)
        return PrivatePlacementResult(steps: [
            .init(step: .showSpaces, result: .voidCompleted),
            .init(step: .addWindows, result: .voidCompleted),
        ])
    }

    /// Hides the space on unlock; the caller orders the window out first. Nothing to do without a space.
    func detach(using ops: PrivateSpaceOperations) -> PrivatePlacementResult {
        guard space != 0 else { return PrivatePlacementResult() }
        ops.hideSpace(space)
        return PrivatePlacementResult(steps: [.init(step: .hideSpaces, result: .voidCompleted)])
    }

    /// Hides and destroys the space and forgets it. Cleanup never reports a failure.
    mutating func teardown(using ops: PrivateSpaceOperations) -> PrivatePlacementResult {
        guard space != 0 else { return PrivatePlacementResult() }
        ops.hideSpace(space)
        let destroyed = ops.destroySpace(space)
        space = 0
        return PrivatePlacementResult(steps: [
            .init(step: .hideSpaces, result: .voidCompleted),
            .init(step: .destroySpace, result: destroyed ? .voidCompleted : .unavailable),
        ])
    }
}
