# Quota-efficiency controls verification

**Audience:** maintainer verification.

**Verified:** 2026-08-05.

The current guarantee is behavioral rather than a claim that local polling consumes tokens.
The rollover regression uses fake tmux and Pi surfaces, never a provider call, and proves fresh generation publication, capsule acknowledgment enforcement, unchanged worktree bytes, idempotent retry, and refusal boundaries.
The watcher regression proves that an unchanged already-delivered quiet status absorbs later pane-hash churn only while the ordinary non-X ship agent is affirmatively alive, while changed status and unsafe liveness still surface.

Commands:

```sh
tests/fm-rollover.test.sh
tests/fm-watch-triage.test.sh
tests/fm-pi-primary-types.test.sh
bin/fm-doc-audience-check.sh
bin/fm-lint.sh
```

Expected output:

```text
# fm-rollover.test.sh: all assertions passed
# fm-watch-triage.test.sh: all assertions passed
ok - tracked Pi extensions pass strict no-emit typecheck against Pi <installed-version>
documentation audience check: ok
lint: ok
```

A missing local Pi package or TypeScript compiler may produce the test owner's explicit skip line for the typecheck; CI's installed toolchain remains authoritative.
The validation metric is fewer primary model turns per unchanged wait interval, lower first-turn and peak context after rollover, and zero superseded-instruction executions.
The home-local `.quiet-stale-suppressed-*` counters measure only avoided unchanged-wait model turns and never assign token cost to local polling.
