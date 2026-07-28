#!/bin/bash

set -euo pipefail

BINARY="${1:-.build/debug/Skerry}"
if [[ ! -x "$BINARY" ]]; then
  echo "Build Skerry first or pass its executable path." >&2
  exit 1
fi

TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT

enqueue_concurrently() {
  local i="$1"
  local last="$2"
  local pids=()
  while (( i <= last )); do
    (
      printf '{"session_id":"queue-%03d","cwd":"/tmp"}' "$i" |
        CFFIXED_USER_HOME="$TEST_HOME" "$BINARY" --lifecycle-event codex started
    ) &
    pids+=("$!")
    ((i += 1))
  done
  for pid in "${pids[@]}"; do
    wait "$pid"
  done
}

enqueue_concurrently 1 100

QUEUE="$TEST_HOME/.skerry/lifecycle-events"
if [[ "$(find "$QUEUE" -type f -name '*.json' | wc -l | tr -d ' ')" != "100" ]]; then
  echo "Concurrent enqueue did not preserve 100/100 events." >&2
  exit 1
fi
if [[ -e "$TEST_HOME/.skerry/.atoll-beta-migration-v1-complete" ]]; then
  echo "Lifecycle hooks unexpectedly ran beta migration." >&2
  exit 1
fi

for attempt in {1..10}; do
  find "$QUEUE" -type f -name '*.json' -delete
  enqueue_concurrently 1 300

  count="$(find "$QUEUE" -type f -name '*.json' | wc -l | tr -d ' ')"
  if [[ "$count" != "256" ]]; then
    echo "Concurrent queue cap retained $count events on attempt $attempt, expected 256." >&2
    exit 1
  fi
done

printf '{"session_id":"queue-301","cwd":"/tmp"}' |
  CFFIXED_USER_HOME="$TEST_HOME" "$BINARY" --lifecycle-event codex started
if [[ "$(find "$QUEUE" -type f -name '*.json' | wc -l | tr -d ' ')" != "256" ]] ||
  ! grep -Rq '"session_id":"queue-301"' "$QUEUE"; then
  echo "Queue cap did not persist the replacement before pruning." >&2
  exit 1
fi

echo "Lifecycle queue preserved 100/100 hooks and capped >256 concurrent hooks."
