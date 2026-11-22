import CoreGraphics
import Foundation

// Feeds the real stdin reader and drives the runner's pure pieces (CardToggle, CardPlan, CardSurface) in a verified
// locked context on the 2240x1260 reference screen. Each batch releases the press left in flight by the previous one
// (it must be dropped when the area changed), clicks outside, with a modifier and plainly, then leaves a press in
// flight. Prints geometry and decisions only, never titles or providers.
let surface = CardSurface.make(screen: CGRect(x: 0, y: 0, width: 2240, height: 1260))!
var toggle = CardToggle(capacity: surface.capacity)
var live: LiveSnapshot?
var clock: TimeInterval = 0
var batchIndex = 0

func context() -> InteractionContext {
    InteractionContext(enabled: true, lock: .locked, presenterLocked: true, cardShown: live?.hasContent ?? false,
                       privateAttached: true, occlusionVisible: true, geometryOK: true, capacity: surface.capacity,
                       rowCount: live?.rows.count ?? 0, reduceMotion: false)
}
func plan() -> CardPlan { CardPlan.make(live, display: toggle.display, interactive: toggle.armed) }
func describe(_ a: [InteractionAction]) -> String { a.isEmpty ? "-" : a.map { "\($0)" }.joined(separator: ",") }
func refresh() -> [InteractionAction] {
    let actions = toggle.evaluate(context())
    toggle.setArea(surface.hitFrame(currentHeight: plan().height))
    return actions
}
func state() -> String {
    let p = plan(), hit = toggle.area
    let v = surface.violations(hit: hit, paintedHeight: p.height)
    return "armed=\(toggle.armed) mode=\(toggle.display.mode) shown=\(p.shownRows) built=\(p.snapshot.rows.count) disclosure=\(p.disclosure) "
        + "footer=\(p.hasFooter) more=\(p.snapshot.overflow ?? "-") height=\(Int(p.height)) hit=\(Int(hit.minX)),\(Int(hit.minY)) \(Int(hit.width))x\(Int(hit.height)) "
        + "safe=\(v.isEmpty ? "yes" : v.joined(separator: "|"))"
}
func click(_ sample: PointerSample, _ label: String) -> [InteractionAction] {
    clock += 0.5
    let pressed = toggle.pointer(PointerSample(kind: .leftDown, plain: sample.plain, insideShape: sample.insideShape), context(), now: clock)
    let released = toggle.pointer(PointerSample(kind: .leftUp, plain: sample.plain, insideShape: sample.insideShape), context(), now: clock + 0.05)
    print("  \(label): press=\(describe(pressed)) release=\(describe(released))")
    if released.contains(where: { if case .animate = $0 { return true }; return false }) { toggle.animationFinished() }
    toggle.setArea(surface.hitFrame(currentHeight: plan().height))
    return released
}

let reader = StdinReader()
reader.start(
    onBatch: { batch in
        batchIndex += 1
        clock += 10
        if batch.invalid > 0 { print("batch \(batchIndex): invalid=\(batch.invalid) reasons=\(batch.reasons) (kept previous; nothing re-evaluated)") }
        guard let update = batch.latest else { fflush(stdout); return }
        let applied: [InteractionAction]
        switch update {
        case .clear:
            live = nil
            applied = toggle.snapshot(nil)
        case .snapshot(let s):
            live = s
            applied = toggle.snapshot(s)
        }
        let gate = refresh()
        print("batch \(batchIndex): \(live == nil ? "clear" : "snapshot rows=\(live!.rows.count) \(CardPresentation.summary(live!.totals))") content=\(describe(applied)) gate=\(describe(gate))")
        print("  state: \(state())")
        var toggled = false
        if toggle.pressInFlight || batchIndex > 1 {
            let r = toggle.pointer(PointerSample(kind: .leftUp, plain: true, insideShape: true), context(), now: clock)
            print("  pending release from previous batch: \(describe(r))")
            if r.contains(where: { if case .animate = $0 { return true }; return false }) {
                toggled = true
                toggle.animationFinished()
                toggle.setArea(surface.hitFrame(currentHeight: plan().height))
                print("  state: \(state())")
            }
        }
        if !toggled {
            _ = click(PointerSample(kind: .leftDown, plain: true, insideShape: false), "outside shape")
            _ = click(PointerSample(kind: .leftDown, plain: false, insideShape: true), "with modifier")
            let r = click(PointerSample(kind: .leftDown, plain: true, insideShape: true), "plain centre")
            if !r.isEmpty { print("  state: \(state())") }
        }
        clock += 0.5
        let held = toggle.pointer(PointerSample(kind: .leftDown, plain: true, insideShape: true), context(), now: clock)
        print("  press left in flight: \(describe(held))")
        fflush(stdout)
    },
    onClose: { reason in
        print("closed: \(reason); armed=\(toggle.armed) -> runner would shut down (disarm before hide/teardown)")
        _ = toggle.shutdown("exit")
        print("after shutdown: armed=\(toggle.armed) reArm=\(describe(toggle.evaluate(context())))")
        fflush(stdout)
        exit(0)
    }
)
dispatchMain()
