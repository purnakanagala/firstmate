#!/usr/bin/env bash
# Real-herdr lifecycle tests for bin/templates/fm-launcher.command (the
# generalized macOS one-command Herdr+Pi launcher). Talks to a REAL herdr
# server, but ALWAYS on a private, named, throwaway session provisioned
# through bin/fm-herdr-lab.sh's guarded non-default lab contract - never the
# captain's live default session (see tests/fm-herdr-lab.test.sh and
# tests/fm-backend-herdr-smoke.test.sh for the same safety pattern). Skips
# cleanly when herdr or jq are not installed. Never invokes a real model: a
# tiny fake `pi` executable stands in, renamed to argv0 "pi" via `exec -a`
# (so Herdr's own native agent detection registers it exactly as it would
# a real Pi process), and a fake `quota-axi` stands in for every quota
# scenario.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TEMPLATE="$ROOT/bin/templates/fm-launcher.command"
assert_present "$TEMPLATE" "bin/templates/fm-launcher.command is missing"

command -v herdr >/dev/null 2>&1 || { echo "skip: herdr not found"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-lab.sh"

SESSION="fm-lab-launcher-$$"
LAB_SCRATCH=
cleanup_all() {
  [ -n "$LAB_SCRATCH" ] && rm -rf "$LAB_SCRATCH"
  herdr_safe_stop_and_delete "$SESSION"
  fm_test_cleanup
}
trap cleanup_all EXIT

fm_herdr_lab_provision "$SESSION" || fail "could not provision the isolated Herdr lab session"

LAB_SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-launcher-lifecycle.XXXXXX")

# --- fake pi: never invokes a real model -------------------------------------
#
# --version and --offline --list-models answer instantly. Any other
# invocation (a real "start/resume the primary" call) renames its own process
# image to argv0 "pi" via `exec -a` against the real bash binary directly (no
# further shebang indirection - re-invoking a shebang script does not stick,
# verified in the private predecessor artifact's own testing) and idles
# forever, so Herdr's native process-info/agent detection registers a live
# "pi" agent exactly like a real Pi launch would, with zero model calls.
FAKE_PI="$LAB_SCRATCH/pi"
cat > "$FAKE_PI" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "fake-pi 9.9.9"; exit 0 ;;
esac
if [ "${1:-}" = "--offline" ] && [ "${2:-}" = "--list-models" ]; then
  IFS='/' read -r prov mid <<< "${3:-}"
  echo "$prov $mid 1K context 1K max-out thinking=yes images=no"
  exit 0
fi
exec -a pi /bin/bash --norc --noprofile -c 'while true; do sleep 3600; done'
EOF
chmod +x "$FAKE_PI"

# --- fake quota-axi variants --------------------------------------------------
QUOTA_OK="$LAB_SCRATCH/quota-ok"
cat > "$QUOTA_OK" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[{"source":"oauth","state":{"status":"fresh"},"quotaSemantics":{"status":"known"},"windows":[{"id":"weekly","kind":"weekly","percentRemaining":80}]}]}
JSON
EOF
chmod +x "$QUOTA_OK"

QUOTA_LOW="$LAB_SCRATCH/quota-low"
cat > "$QUOTA_LOW" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[{"source":"oauth","state":{"status":"fresh"},"quotaSemantics":{"status":"known"},"windows":[{"id":"weekly","kind":"weekly","percentRemaining":3}]}]}
JSON
EOF
chmod +x "$QUOTA_LOW"

QUOTA_MISSING_PERCENT="$LAB_SCRATCH/quota-missing-percent"
cat > "$QUOTA_MISSING_PERCENT" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"providers":[{"source":"oauth","state":{"status":"fresh"},"quotaSemantics":{"status":"known"},"windows":[{"id":"weekly","kind":"weekly"}]}]}
JSON
EOF
chmod +x "$QUOTA_MISSING_PERCENT"

QUOTA_FAIL="$LAB_SCRATCH/quota-fail"
cat > "$QUOTA_FAIL" <<'EOF'
#!/usr/bin/env bash
echo "simulated quota-axi failure" >&2
exit 1
EOF
chmod +x "$QUOTA_FAIL"

QUOTA_POISON_MARKER="$LAB_SCRATCH/quota-poison-invoked"
QUOTA_POISON="$LAB_SCRATCH/quota-poison"
cat > "$QUOTA_POISON" <<EOF
#!/usr/bin/env bash
: > "$QUOTA_POISON_MARKER"
echo "quota-poison: must never be called" >&2
exit 99
EOF
chmod +x "$QUOTA_POISON"

# new_home <label> <workspace-label>: build a fresh fake Firstmate home with a
# matching generated launcher config (mirrors what fm-install-launcher.sh
# would produce), and echo its resolved real path. Every home gets its own
# workspace label so scenarios never collide inside the shared lab session.
new_home() {
  local label=$1 wslabel=$2 home
  home="$LAB_SCRATCH/home-$label"
  mkdir -p "$home/bin" "$home/state"
  cp "$ROOT/bin/herdr-min-protocol" "$home/bin/herdr-min-protocol"
  : > "$home/AGENTS.md"
  home=$(cd "$home" && pwd -P)
  cat > "$home/fm-launcher.conf" <<EOF
home=$home
model=openai-codex/gpt-5.6-sol
thinking=low
pi_bin=$FAKE_PI
quota_provider=codex
quota_reserve_percent=25
workspace_label=$wslabel
tab_label=fm-primary
EOF
  printf '%s\n' "$home"
}

# run_launcher <home> <quota-bin> <args...>
run_launcher() {
  local home=$1 quotabin=$2
  shift 2
  FM_LAUNCHER_CONF_OVERRIDE="$home/fm-launcher.conf" \
    FM_LAUNCHER_SESSION_OVERRIDE="$SESSION" \
    FM_LAUNCHER_QUOTA_BIN_OVERRIDE="$quotabin" \
    "$TEMPLATE" "$@"
}

# run_launcher_real <home> <quota-bin>: the default (argument-less, mutating)
# mode ends by running the real "herdr session attach". This test suite runs
# inside its own nested Herdr pane, where the real herdr client refuses to
# attach ("nested herdr is disabled by default") - an environment property of
# this sandbox, not a launcher defect. Every mutating step before that final
# attach (classify, quota gate, workspace/tab/pane create-or-recover, journal
# write) still ran for real; only that last interactive attach is tolerated as
# expected noise here, identified by its own exact printed reason.
run_launcher_real() {
  local home=$1 quotabin=$2 out rc
  out=$(run_launcher "$home" "$quotabin" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q "could not attach the Herdr client"; then
    fail "real launch failed for an unexpected reason: $out"
  fi
  printf '%s' "$out"
}

pane_shell_pid() {  # <pane-id>
  HERDR_SESSION="$SESSION" herdr pane process-info --pane "$1" --session "$SESSION" 2>/dev/null \
    | jq -r '.result.process_info.shell_pid // empty'
}

# pane_pi_pid <pane-id>: the pid of the fake pi's own renamed process (argv0
# "pi"), never just foreground_processes[0] - the fake pi's `while true; do
# sleep 3600; done` loop also reports its transient "sleep" child as a
# foreground process, and killing that alone would not touch the agent.
pane_pi_pid() {
  HERDR_SESSION="$SESSION" herdr pane process-info --pane "$1" --session "$SESSION" 2>/dev/null \
    | jq -r '[.result.process_info.foreground_processes[]? | select(.argv0=="pi" or .name=="pi")][0].pid // empty'
}

agent_count_at_cwd() {  # <cwd>
  HERDR_SESSION="$SESSION" herdr agent list --session "$SESSION" 2>/dev/null \
    | jq --arg cwd "$1" '[.result.agents[]? | select(.cwd == $cwd)] | length'
}

# =============================================================================
# Scenario 1: absent -> create, standalone home resolution (never derived from
# the invoking cwd or the template's own directory), quota enforced.
# =============================================================================

HOME1=$(new_home s1 launcher-s1)
cd /tmp || fail "could not cd away from the checkout before invoking the launcher"
run_launcher_real "$HOME1" "$QUOTA_OK" >/dev/null
sleep 1
JOURNAL1="$HOME1/state/.fm-launcher-primary-identity"
[ -f "$JOURNAL1" ] || fail "expected an identity journal after creating a fresh primary"
assert_grep "home=$HOME1" "$JOURNAL1" "journal must record the exact configured home, not a cwd-derived one"
CHECK1=$(run_launcher "$HOME1" "$QUOTA_OK" --check) || fail "check after create failed: $CHECK1"
assert_contains "$CHECK1" "alive" "primary should be alive immediately after a real create"
pass "launcher: absent state creates a fresh primary with home resolved from config, independent of cwd"

# =============================================================================
# Scenario 2: exact identity vs a duplicate agent at the same cwd. A second,
# unrelated live "pi" agent sharing FM_HOME must never be misread as our
# primary or as a duplicate/ambiguous collision.
# =============================================================================

HOME1_CWD="$HOME1"
WSLIST=$(HERDR_SESSION="$SESSION" herdr workspace list --session "$SESSION")
WSID1=$(printf '%s' "$WSLIST" | jq -r --arg l "launcher-s1" '.result.workspaces[]? | select(.label==$l) | .workspace_id')
[ -n "$WSID1" ] || fail "could not find the launcher's own workspace by label"
BEFORE_COUNT=$(agent_count_at_cwd "$HOME1_CWD")
FOREIGN_TAB=$(HERDR_SESSION="$SESSION" herdr tab create --workspace "$WSID1" --cwd "$HOME1_CWD" --label other-crew --no-focus --session "$SESSION")
FOREIGN_PANE=$(printf '%s' "$FOREIGN_TAB" | jq -r '.result.root_pane.pane_id')
HERDR_SESSION="$SESSION" herdr pane run "$FOREIGN_PANE" "'$FAKE_PI' --model foo --thinking low" --session "$SESSION" >/dev/null
sleep 1
AFTER_COUNT=$(agent_count_at_cwd "$HOME1_CWD")
[ "$AFTER_COUNT" -eq "$((BEFORE_COUNT + 1))" ] || fail "expected exactly one extra unrelated agent at the shared cwd (before=$BEFORE_COUNT after=$AFTER_COUNT)"

CHECK2=$(run_launcher "$HOME1" "$QUOTA_OK" --check) || fail "check with a duplicate-cwd foreign agent present should still report alive: $CHECK2"
assert_contains "$CHECK2" "alive" "a foreign pi agent at the same cwd must never trigger a false ambiguous/duplicate classification"
FINAL_COUNT=$(agent_count_at_cwd "$HOME1_CWD")
[ "$FINAL_COUNT" -eq "$AFTER_COUNT" ] || fail "the check must not have created or removed any agent (before=$AFTER_COUNT after=$FINAL_COUNT)"
pass "launcher: exact journaled identity is immune to an unrelated live agent at the same cwd"

cp "$JOURNAL1" "$JOURNAL1.saved"
awk -F= '$1=="model" { print "model=openai-codex/different-model"; next } { print }' \
  "$JOURNAL1.saved" > "$JOURNAL1"
CHECK2_PIN=$(run_launcher "$HOME1" "$QUOTA_OK" --check 2>&1)
RC2_PIN=$?
[ "$RC2_PIN" -ne 0 ] || fail "a journal written for a different model pin must refuse attachment"
assert_contains "$CHECK2_PIN" "ambiguous" "model-pin drift must classify as ambiguous"
mv "$JOURNAL1.saved" "$JOURNAL1"
pass "launcher: journal identity binds the configured model and reasoning pin"

# =============================================================================
# Scenario 3: a proven live primary is only focused/attached, never restarted,
# so attaching it must succeed even when the quota probe is broken/failing.
# (`--check`/`--dry-run` are diagnostic and always report current quota as
# information regardless of state - it is specifically the real mutating
# dispatch that must skip the quota gate for an already-alive primary, since
# only that path can actually start or resume a model.)
# =============================================================================

RUN3=$(run_launcher_real "$HOME1" "$QUOTA_FAIL")
if printf '%s' "$RUN3" | grep -q "quota-axi installed"; then
  fail "attaching an alive primary must never call the quota probe at all: $RUN3"
fi
pass "launcher: an already-live primary remains attachable when the quota probe fails"

# =============================================================================
# Scenario 4: absent-state and dead-primary-recovery both enforce the quota
# gate; a live primary's own state never bypasses it for those paths.
# =============================================================================

HOME4=$(new_home s4-absent launcher-s4-absent)
CHECK4=$(run_launcher "$HOME4" "$QUOTA_LOW" --check 2>&1)
RC4=$?
[ "$RC4" -ne 0 ] || fail "absent-state check must refuse below the configured quota reserve"
assert_contains "$CHECK4" "reserve" "refusal must name the reserve-floor requirement"
[ ! -f "$HOME4/state/.fm-launcher-primary-identity" ] || fail "a quota-refused absent check must never create a primary"
pass "launcher: absent-state start refuses below the configured quota reserve, creates nothing"

HOME4A=$(new_home s4-missing-percent launcher-s4-missing-percent)
CHECK4A=$(run_launcher "$HOME4A" "$QUOTA_MISSING_PERCENT" --check 2>&1)
RC4A=$?
[ "$RC4A" -ne 0 ] || fail "quota windows without percentRemaining must fail closed"
assert_contains "$CHECK4A" "percentRemaining" "missing quota percentages must produce an explicit refusal"
pass "launcher: missing quota percentages fail closed"

# Dead-primary recovery: create a real primary, kill only its foreground "pi"
# process (leaving a plain idle shell in the same pane - a provable husk),
# then confirm --check with a failing quota also refuses recovery.
HOME4B=$(new_home s4-dead launcher-s4-dead)
run_launcher_real "$HOME4B" "$QUOTA_OK" >/dev/null
sleep 1
J4B="$HOME4B/state/.fm-launcher-primary-identity"
PANE4B=$(awk -F= '$1=="pane_id"{print $2}' "$J4B")
[ -n "$PANE4B" ] || fail "could not read the journaled pane id for the dead-recovery scenario"
PI_PID=$(pane_pi_pid "$PANE4B")
[ -n "$PI_PID" ] || fail "could not read the fake pi's own renamed process pid"
kill "$PI_PID" 2>/dev/null
for _i in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(pane_pi_pid "$PANE4B")" != "$PI_PID" ] && break
  sleep 0.3
done
CHECK4B=$(run_launcher "$HOME4B" "$QUOTA_LOW" --check 2>&1)
RC4B=$?
[ "$RC4B" -ne 0 ] || fail "dead-primary check must refuse recovery below the configured quota reserve: $CHECK4B"
assert_contains "$CHECK4B" "reserve" "refusal should be quota-related for the proven husk"
pass "launcher: dead-primary recovery also enforces the configured quota reserve"

# Now prove recovery itself works with healthy quota: the SAME pane is reused
# (never closed/replaced), a fresh live "pi" agent reappears there.
run_launcher_real "$HOME4B" "$QUOTA_OK" >/dev/null
sleep 1
CHECK4C=$(run_launcher "$HOME4B" "$QUOTA_OK" --check) || fail "post-recovery check failed: $CHECK4C"
assert_contains "$CHECK4C" "alive" "expected the recovered husk to report alive"
J4B_AFTER=$(awk -F= '$1=="pane_id"{print $2}' "$J4B")
[ "$J4B_AFTER" = "$PANE4B" ] || fail "recovery must reuse the exact same pane, never a new one (was $PANE4B, now $J4B_AFTER)"
pass "launcher: a proven idle husk is recovered in the exact existing pane, never closed or replaced"

# =============================================================================
# Scenario 5: guarded --adopt-current. Only succeeds from inside the exact
# live pane it adopts, and never touches quota - proven by making it succeed
# against the poisoned quota-axi.
# =============================================================================

HOME5=$(new_home s5 launcher-s5)
WS5OUT=$(HERDR_SESSION="$SESSION" herdr workspace create --cwd "$HOME5" --label launcher-s5 --no-focus --session "$SESSION")
WS5=$(printf '%s' "$WS5OUT" | jq -r '.result.workspace.workspace_id')
TAB5OUT=$(HERDR_SESSION="$SESSION" herdr tab create --workspace "$WS5" --cwd "$HOME5" --label fm-primary --no-focus --session "$SESSION")
TAB5=$(printf '%s' "$TAB5OUT" | jq -r '.result.tab.tab_id')
PANE5=$(printf '%s' "$TAB5OUT" | jq -r '.result.root_pane.pane_id')
HERDR_SESSION="$SESSION" herdr pane run "$PANE5" "'$FAKE_PI' --model foo --thinking low" --session "$SESSION" >/dev/null
sleep 1

ADOPT_OK=$(HERDR_WORKSPACE_ID="$WS5" HERDR_TAB_ID="$TAB5" HERDR_PANE_ID="$PANE5" \
  run_launcher "$HOME5" "$QUOTA_POISON" --adopt-current 2>&1)
RC_ADOPT=$?
[ "$RC_ADOPT" -eq 0 ] || fail "adopt-current should succeed from inside the exact live pane: $ADOPT_OK"
[ ! -f "$QUOTA_POISON_MARKER" ] || fail "adopt-current must never call quota-axi, but the poisoned stub was invoked"
J5="$HOME5/state/.fm-launcher-primary-identity"
[ -f "$J5" ] || fail "adopt-current did not write an identity journal"
assert_grep "pane_id=$PANE5" "$J5" "adopted journal must record the exact live pane id"
pass "launcher: --adopt-current records an already-live identity without ever touching quota"

ADOPT_AGAIN=$(HERDR_WORKSPACE_ID="$WS5" HERDR_TAB_ID="$TAB5" HERDR_PANE_ID="$PANE5" \
  run_launcher "$HOME5" "$QUOTA_POISON" --adopt-current 2>&1)
RC_ADOPT_AGAIN=$?
[ "$RC_ADOPT_AGAIN" -ne 0 ] || fail "adopt-current must never overwrite an existing identity journal"
assert_contains "$ADOPT_AGAIN" "first-install-only" "repeat adoption refusal must explain the existing identity boundary"
pass "launcher: --adopt-current serializes and refuses to overwrite an existing journal"

# Negative: adopt-current from outside the live pane (mismatched pane id) must refuse.
HOME5B=$(new_home s5b launcher-s5b)
HERDR_WORKSPACE_ID="$WS5" HERDR_TAB_ID="$TAB5" HERDR_PANE_ID="w9:pfake" \
  run_launcher "$HOME5B" "$QUOTA_OK" --adopt-current >/dev/null 2>&1
RC_ADOPT_BAD=$?
[ "$RC_ADOPT_BAD" -ne 0 ] || fail "adopt-current must refuse when HERDR_PANE_ID does not match Herdr's own self-report"
pass "launcher: --adopt-current refuses a mismatched/unproven pane identity"

HOME5C=$(new_home s5c launcher-s5c)
WS5COUT=$(HERDR_SESSION="$SESSION" herdr workspace create --cwd "$HOME5C" --label launcher-s5c --no-focus --session "$SESSION")
WS5C=$(printf '%s' "$WS5COUT" | jq -r '.result.workspace.workspace_id')
TAB5COUT=$(HERDR_SESSION="$SESSION" herdr tab create --workspace "$WS5C" --cwd "$HOME5C" --label fm-primary --no-focus --session "$SESSION")
PANE5C=$(printf '%s' "$TAB5COUT" | jq -r '.result.root_pane.pane_id')
HERDR_SESSION="$SESSION" herdr pane run "$PANE5C" "'$FAKE_PI' --model foo --thinking low" --session "$SESSION" >/dev/null
sleep 1
CHECK5C=$(run_launcher "$HOME5C" "$QUOTA_OK" --check 2>&1)
RC5C=$?
[ "$RC5C" -ne 0 ] || fail "an unjournaled configured primary tab must refuse rather than be duplicated"
assert_contains "$CHECK5C" "ambiguous" "unjournaled configured tab collision must classify as ambiguous"
pass "launcher: an unjournaled configured primary tab refuses as ambiguous"

# =============================================================================
# Scenario 6: concurrent launches serialize through the single-flight lock.
# =============================================================================

HOME6=$(new_home s6 launcher-s6)
mkdir "$HOME6/state/.fm-launcher.lock" || fail "could not simulate a held launcher lock"
printf '%s\n' "$$" > "$HOME6/state/.fm-launcher.lock/pid"
printf '%s\n' "/nonexistent/fm-launcher.command" > "$HOME6/state/.fm-launcher.lock/launcher"
OUT6=$(run_launcher "$HOME6" "$QUOTA_OK" 2>&1)
RC6=$?
[ "$RC6" -ne 0 ] || fail "a concurrent launch must refuse while a live-pid lock is held"
assert_contains "$OUT6" "already in progress" "refusal must explain the concurrent-launch reason"
rm -rf "$HOME6/state/.fm-launcher.lock"
pass "launcher: a concurrent launch refuses while another launch's lock is held by a live pid"

# =============================================================================
# Scenario 7: ambiguity is always a refusal, never a guess. A live Firstmate
# session lock pointing at a PID outside the journaled pane's own process
# tree must refuse even though the journaled pane's agent still looks live.
# =============================================================================

HOME7=$(new_home s7 launcher-s7)
run_launcher_real "$HOME7" "$QUOTA_OK" >/dev/null
sleep 1
# A real, currently-alive pid that is NOT part of the journaled pane's process
# tree - this shell's own pid is guaranteed foreign to that pane.
printf '%s\n' "$$" > "$HOME7/state/.lock"
CHECK7=$(run_launcher "$HOME7" "$QUOTA_OK" --check 2>&1)
RC7=$?
[ "$RC7" -ne 0 ] || fail "a live foreign session-lock pid must force an ambiguous refusal: $CHECK7"
assert_contains "$CHECK7" "ambiguous" "expected an explicit ambiguous refusal message"
pass "launcher: a live session lock pointing outside the journaled pane's process tree refuses as ambiguous"

# =============================================================================
# Scenario 8: redaction. The log is mode 0600 and never carries raw quota
# JSON, credentials, or secret-shaped strings, across every scenario above.
# =============================================================================

for h in "$HOME1" "$HOME4" "$HOME4B" "$HOME5" "$HOME5B" "$HOME6" "$HOME7"; do
  LOG="$h/state/.fm-launcher.log"
  [ -f "$LOG" ] || continue
  MODE=$(stat -f '%Lp' "$LOG" 2>/dev/null || stat -c '%a' "$LOG")
  [ "$MODE" = 600 ] || fail "$LOG must be mode 0600, got $MODE"
  if grep -Eiq 'authorization|bearer|apikey|api_key|password|percentRemaining|"windows"' "$LOG"; then
    fail "$LOG contains a raw credential/quota-payload shaped string; logging must stay redacted"
  fi
done
pass "launcher: every scenario's log stays mode 0600 and redacted (no raw quota JSON or credential-shaped strings)"

echo "all fm-launcher-lifecycle tests passed"
