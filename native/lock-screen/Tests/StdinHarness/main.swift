import Foundation

// CLI-only harness: Core + Sources/App/StdinReader.swift, no AppKit, no window, no private code.
// Feeds the real reader from this process's stdin and prints what the runner would apply (latest-only),
// mirroring Runner.apply, then exits on EOF exactly as live-lock's .inputClosed path does.
var latest: LiveSnapshot?
let reader = StdinReader()
reader.start(
    onBatch: { batch in
        if batch.invalid > 0 { print("invalid=\(batch.invalid) reasons=\(batch.reasons)") }
        switch batch.latest {
        case .none: break
        case .clear?:
            latest = nil
            print("clear -> liveContent(false)")
        case .snapshot(let s)?:
            latest = s
            let card = s.cardSnapshot()
            print("snapshot rows=\(card.rows.count) summary=\(card.summary) overflow=\(card.overflow ?? "-") titles=\(card.rows.map(\.title)) providers=\(card.rows.map(\.provider)) -> liveContent(\(s.hasContent))")
        }
        fflush(stdout)
    },
    onClose: { reason in
        print("closed: \(reason) -> inputClosed; held=\(latest != nil)")
        fflush(stdout)
        exit(0)
    }
)
dispatchMain()
