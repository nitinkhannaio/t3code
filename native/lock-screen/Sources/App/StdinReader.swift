import Foundation

/// Reads stdin on a dedicated thread with bounded memory: one 4 KiB read buffer, the framer's <= 64 KiB line
/// buffer, and at most one decoded batch in flight (the thread waits until the main thread has applied it).
final class StdinReader: @unchecked Sendable {
    struct Batch {
        var latest: LiveUpdate?
        var invalid = 0
        /// First few reasons, for the log; never the line content.
        var reasons: [LiveParseError] = []
    }

    /// After stdin closes, the main thread gets this long to hide the card and tear down the space; then the process
    /// exits anyway, and the window server drops its windows and spaces with the connection.
    static let closeGrace: TimeInterval = 2

    func start(onBatch: @escaping @Sendable (Batch) -> Void, onClose: @escaping @Sendable (String) -> Void) {
        func close(_ reason: String) {
            DispatchQueue.main.async { onClose(reason) }
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.closeGrace) {
                FileHandle.standardError.write(Data("stdin closed \(Int(Self.closeGrace))s ago and the main thread did not exit; exiting\n".utf8))
                _exit(0)
            }
        }
        let thread = Thread {
            var framer = LineFramer()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            let applied = DispatchSemaphore(value: 0)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if count == 0 { return close("EOF") }
                if count < 0 {
                    if errno == EINTR { continue }
                    let code = errno
                    return close("read error \(code)")
                }
                var batch = Batch()
                for frame in framer.feed(Data(buffer[0..<count])) {
                    let result: Result<LiveUpdate, LiveParseError>
                    switch frame {
                    case .line(let line): result = LiveDecoder.decode(line)
                    case .oversized: result = .failure(.tooLong)
                    }
                    switch result {
                    case .success(let update): batch.latest = update
                    case .failure(let error):
                        batch.invalid += 1
                        if batch.reasons.count < 3 { batch.reasons.append(error) }
                    }
                }
                guard batch.latest != nil || batch.invalid > 0 else { continue }
                let ready = batch
                DispatchQueue.main.async {
                    onBatch(ready)
                    applied.signal()
                }
                applied.wait()
            }
        }
        thread.name = "t3-glass-card.stdin"
        thread.start()
    }
}
