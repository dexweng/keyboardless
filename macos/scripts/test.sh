#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p .local/swift-module-cache macos/build
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.local/swift-module-cache" macos/Sources/Core.swift macos/Sources/API.swift macos/Tests/Checks.swift -o macos/build/checks
PORT_FILE=$(mktemp)
node macos/Tests/mock-server.mjs > "$PORT_FILE" &
MOCK_PID=$!
trap 'kill "$MOCK_PID" 2>/dev/null || true; rm -f "$PORT_FILE"' EXIT
for i in $(seq 1 40); do [ -s "$PORT_FILE" ] && break; sleep 0.1; done
macos/build/checks "http://127.0.0.1:$(cat "$PORT_FILE")"
xcrun swiftc -swift-version 5 -module-cache-path "$PWD/.local/swift-module-cache" -framework AppKit -framework Carbon -framework ApplicationServices macos/Sources/Core.swift macos/Sources/Interface.swift macos/Sources/Shortcut.swift macos/Sources/Input.swift macos/Tests/ShortcutChecks.swift -o macos/build/shortcut-checks
macos/build/shortcut-checks
