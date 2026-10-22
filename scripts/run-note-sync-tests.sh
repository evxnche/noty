#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
SOURCES=()
for f in "$ROOT"/Sources/*.swift; do
    [ "$(basename "$f")" = "Main.swift" ] && continue
    SOURCES+=("$f")
done
mkdir -p "$ROOT/build"
swiftc -Onone -parse-as-library -swift-version 5 -target arm64-apple-macosx15.0 -sdk "$SDK" \
    "${SOURCES[@]}" "$ROOT/Tests/NoteSyncTests.swift" -o "$ROOT/build/note-sync-tests"
"$ROOT/build/note-sync-tests"
