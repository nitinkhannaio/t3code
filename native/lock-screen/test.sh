#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

output="build/test"
node ../../apps/desktop/scripts/build-lock-screen-activity.mjs --output-dir "$output"
flags=(-O -swift-version 5 -target "$(uname -m)-apple-macosx26.0")

for suite in Core Interaction; do
  test_source="Tests/$suite/main.swift"
  [[ "$suite" != Core ]] || test_source="Tests/main.swift"
  xcrun swiftc "${flags[@]}" -module-name "T3LockScreen${suite}Tests" \
    Sources/Core/*.swift "$test_source" -o "$output/$suite"
  "$output/$suite"
done

xcrun swiftc "${flags[@]}" -module-name T3GlassInteractionHarness Sources/Core/*.swift \
  Sources/App/StdinReader.swift Tests/InteractionHarness/main.swift -o "$output/interaction-harness"
# One fixture record per 4 KiB read, so each update reaches the harness in its own batch.
awk '{ printf "%-4095s\n", $0 }' Tests/InteractionHarness/fixture.ndjson > "$output/interaction-input.ndjson"
"$output/interaction-harness" < "$output/interaction-input.ndjson" | \
  diff - Tests/InteractionHarness/expected.txt

"$output/t3-glass-card" layout-check
"$output/t3-glass-card" interaction-check
