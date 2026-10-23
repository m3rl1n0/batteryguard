#!/bin/sh
# Test dei casi limite di configurazione e battito del servizio. swiftc diretto per lo stesso motivo di build.sh.
set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/.build/tests"
mkdir -p "$OUT"

xcrun swiftc -target "$(uname -m)-apple-macos13" -module-name LimitConfigTests \
  "$ROOT/Sources/SMCKit/LimitConfig.swift" "$ROOT/Tests/LimitConfigTests/main.swift" \
  -o "$OUT/limit-config-tests"
"$OUT/limit-config-tests"

xcrun swiftc -target "$(uname -m)-apple-macos13" -module-name ServiceStatusTests \
  "$ROOT/Sources/SMCKit/ServiceStatus.swift" "$ROOT/Tests/ServiceStatusTests/main.swift" \
  -o "$OUT/service-status-tests"
"$OUT/service-status-tests"
