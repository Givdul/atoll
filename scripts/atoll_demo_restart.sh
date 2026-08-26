#!/usr/bin/env bash
# Restarts Atoll with a full-task-state demo dataset (matches current TaskState cases).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED="$ROOT/build/atoll-derived"
PRODUCT="$DERIVED/Build/Products/Debug/Atoll.app"

echo "Building Atoll (derived data: ${DERIVED})…"
cd "$ROOT"
xcodebuild -scheme Atoll -configuration Debug -derivedDataPath "$DERIVED" build >/dev/null

killall Atoll 2>/dev/null || true
sleep 0.6
open "$PRODUCT" --args --demo-seed

echo "Launched $(basename "$PRODUCT") with --demo-seed."
