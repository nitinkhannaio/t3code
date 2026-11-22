import AppKit

/// Lock state from the public CGSession dictionary. Unlocked, it waits for the distributed lock notification (a
/// missed one leaves the card hidden: fail closed); locked, it also polls once a second to catch the unlock and to
/// re-verify the pointer gate.
final class LockMonitor {
    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    /// The signal from the last poll; `.locked` requires an on-console session (fast user switching reads inconclusive).
    private(set) var signal = LockSignal.inconclusive
    var onLockChange: ((Bool) -> Void)?
    var onWake: (() -> Void)?

    static func current() -> [String: Any] {
        (CGSessionCopyCurrentDictionary() as? [String: Any]) ?? [:]
    }

    static func isLocked() -> Bool { LockSignal.from(session: current()) == .locked }

    /// Logged-in, on-console GUI session, not root, not launched over SSH.
    static func interactiveSessionProblem() -> String? {
        let session = current()
        if session.isEmpty { return "No window server session (run this from Terminal in your logged-in desktop)." }
        if geteuid() == 0 { return "Refusing to run as root." }
        if (session[kCGSessionOnConsoleKey as String] as? NSNumber)?.boolValue != true { return "This session is not on the console." }
        if (session[kCGSessionLoginDoneKey as String] as? NSNumber)?.boolValue != true { return "Login has not completed." }
        let env = ProcessInfo.processInfo.environment
        if env["SSH_CONNECTION"] != nil || env["SSH_TTY"] != nil { return "Refusing to run over SSH; start it from a local Terminal." }
        return nil
    }

    func start() {
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            let token = distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.poll()
            }
            observers.append((distributed, token))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        let wake = workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.poll()
            self?.onWake?()
        }
        observers.append((workspace, wake))
        poll()
    }

    func poll() {
        signal = LockSignal.from(session: Self.current())
        let locked = signal == .locked
        if locked, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        } else if !locked {
            timer?.invalidate()
            timer = nil
        }
        onLockChange?(locked)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        observers.forEach { $0.0.removeObserver($0.1) }
        observers = []
    }
}

/// Runtime-loaded private backend. Nothing private is linked into the main binary.
/// Each libT3SkyLightBackend export wraps one SkyLight call; `PrivatePlacement` (Core) orders them and decides failure.
final class SkyLightBackend {
    private typealias Probe = @convention(c) () -> Int32
    private typealias Create = @convention(c) () -> UInt64
    private typealias SetLevel = @convention(c) (UInt64, Int32) -> Void
    private typealias SpaceCall = @convention(c) (UInt64) -> Void
    private typealias AddWindow = @convention(c) (UInt64, Int32) -> Void
    private typealias Destroy = @convention(c) (UInt64) -> Int32

    private struct Operations: PrivateSpaceOperations {
        let create: Create
        let setLevel: SetLevel
        let show: SpaceCall
        let add: AddWindow
        let hide: SpaceCall
        let destroy: Destroy

        func createSpace() -> UInt64 { create() }
        func setAbsoluteLevel(space: UInt64, level: Int32) { setLevel(space, level) }
        func showSpace(_ space: UInt64) { show(space) }
        func addWindow(_ window: Int32, to space: UInt64) { add(space, window) }
        func hideSpace(_ space: UInt64) { hide(space) }
        func destroySpace(_ space: UInt64) -> Bool { destroy(space) != 0 }
    }

    private let probeFn: Probe
    private let ops: Operations
    private var placement = PrivatePlacement()

    static var dylibURL: URL {
        Bundle.main.executableURL!.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("libT3SkyLightBackend.dylib")
    }

    static func load() throws -> SkyLightBackend {
        let path = dylibURL.path
        guard FileManager.default.fileExists(atPath: path) else { throw ArgumentError(description: "Backend not found at \(path)") }
        guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw ArgumentError(description: "dlopen failed: \(String(cString: dlerror()))")
        }
        func symbol<T>(_ name: String, _: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else { throw ArgumentError(description: "Backend is missing \(name)") }
            return unsafeBitCast(pointer, to: T.self)
        }
        return SkyLightBackend(
            probe: try symbol("t3skl_probe", Probe.self),
            ops: Operations(
                create: try symbol("t3skl_space_create", Create.self),
                setLevel: try symbol("t3skl_set_absolute_level", SetLevel.self),
                show: try symbol("t3skl_show_space", SpaceCall.self),
                add: try symbol("t3skl_add_window", AddWindow.self),
                hide: try symbol("t3skl_hide_space", SpaceCall.self),
                destroy: try symbol("t3skl_destroy_space", Destroy.self)
            )
        )
    }

    private init(probe: @escaping Probe, ops: Operations) {
        probeFn = probe
        self.ops = ops
    }

    func probe() -> Int32 { probeFn() }
    func attach(_ window: NSWindow) -> PrivatePlacementResult { placement.attach(window: Int32(window.windowNumber), using: ops) }
    func reassert(_ window: NSWindow) -> PrivatePlacementResult { placement.reassert(window: Int32(window.windowNumber), using: ops) }
    func detach() -> PrivatePlacementResult { placement.detach(using: ops) }
    func teardown() -> PrivatePlacementResult { placement.teardown(using: ops) }
    /// Adds the hit panel to the card's existing space.
    func adoptAuxiliary(_ window: NSWindow) -> PrivatePlacementResult { placement.adoptAuxiliary(window: Int32(window.windowNumber), using: ops) }
    var hasSpace: Bool { placement.space != 0 }
}
