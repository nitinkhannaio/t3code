import AppKit

func fail(_ message: String, code: Int32 = 64) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

let command: Command
do {
    command = try Arguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    fail("\(error)\n\n\(Arguments.usage)")
}

switch command {
case .help:
    print(Arguments.usage)

case .renderPNG(let out, let appearance, let sample, let expanded, let width, let interactive, let backdrop):
    MainActor.assumeIsolated {
        renderPNG(to: out, appearance: appearance, sample: sample, expanded: expanded, width: CGFloat(width), interactive: interactive, backdrop: backdrop)
    }

case .layoutCheck:
    exit(MainActor.assumeIsolated { layoutCheck() } ? 0 : 1)

case .interactionCheck:
    exit(MainActor.assumeIsolated { interactionCheck() })

case .run(let options):
    if let problem = LockMonitor.interactiveSessionProblem() { fail(problem, code: 2) }
    if isatty(STDIN_FILENO) != 0 {
        fail("live-lock is app-owned: its owning app writes snapshots to stdin over a pipe. stdin is a terminal; not arming.", code: 2)
    }
    let os = ProcessInfo.processInfo.operatingSystemVersion
    if !Arguments.isTestedOS(major: os.majorVersion, minor: os.minorVersion), !options.allowUntestedOS {
        fail("live-lock supports macOS 26.2 and 26.5; this is \(os.majorVersion).\(os.minorVersion). Pass --allow-untested-os to proceed.", code: 2)
    }
    let backend: SkyLightBackend
    do {
        backend = try SkyLightBackend.load()
    } catch {
        fail("\(error)", code: 3)
    }
    let probe = backend.probe()
    guard probe == 0 else { fail("SkyLight probe failed (\(probe)); not arming.", code: 3) }
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let runner = MainActor.assumeIsolated { Runner(options: options, backend: backend) }
    MainActor.assumeIsolated { runner.start() }
    app.run()
}
