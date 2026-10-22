#!/bin/bash
# Runs the pure-logic checks in Tests/ against the real Sources/ — everything
# except Main.swift, which owns @main, replaced by the test binary's own.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"

SOURCES=()
for f in "$ROOT"/Sources/*.swift; do
    [ "$(basename "$f")" = "Main.swift" ] && continue
    SOURCES+=("$f")
done

BIN="$ROOT/build/logic-tests"
mkdir -p "$ROOT/build"
swiftc -Onone -parse-as-library -swift-version 5 \
    -target arm64-apple-macosx15.0 \
    -sdk "$SDK" \
    "${SOURCES[@]}" "$ROOT/Tests/LogicTests.swift" \
    -o "$BIN"

"$BIN" "${1:-$ROOT/build/Noty.app}"
