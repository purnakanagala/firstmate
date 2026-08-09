#!/usr/bin/env bash
# Provider-free runtime exercise for the TypeScript Pi rollover guard.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
node --no-warnings --experimental-strip-types "$ROOT/tests/fm-rollover-guard.runtime.mjs"
