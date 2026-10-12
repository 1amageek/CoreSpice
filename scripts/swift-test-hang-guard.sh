#!/bin/sh
# Repetition is optional; callers choose it only for a concrete liveness concern.
set -eu
repeats="$1"
seconds="$2"
shift 2
while [ "$repeats" -gt 0 ]; do
    "$(dirname "$0")/swift-test-timeout.sh" "$seconds" "$@"
    repeats=$((repeats - 1))
done
