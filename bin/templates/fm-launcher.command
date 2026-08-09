#!/usr/bin/env bash
# fm-launcher.command - one-click launcher template: start/attach the named
# default Herdr session, then start or resume exactly one Pi-backed
# Firstmate primary in it, and attach the visible Herdr client so the
# captain lands in the same working environment every time.
#
# This file is a tracked, generic template. `bin/fm-install-launcher.sh`
# installs it byte-identical to a chosen destination alongside a generated
# per-install config file (default `fm-launcher.conf`, same directory) that
# carries every install-specific value: the Firstmate home, the pinned
# model/reasoning, the Pi executable, and the quota provider/reserve. See
# docs/launcher.md for the config schema, defaults, and setup.
#
# This is a personal convenience artifact, not a control plane. It never
# stops/deletes/restarts/updates the Herdr server/session, never force-kills
# processes, and never destructively repairs an ambiguous or husk endpoint -
# it stops with a diagnostic and points at Firstmate's normal recovery.
#
# Modes:
#   --check          dependency/config/model/quota/ambiguity checks only, no mutation
#   --dry-run        print the redacted intended action only, no mutation
#   --adopt-current  first-install only: record the identity of an already-live
#                     primary pane this is run from; never starts/checks quota
#   (default)        start-or-attach the primary and attach the Herdr client
#
# Testing overrides (never used by an installed copy in ordinary use):
#   FM_LAUNCHER_CONF_OVERRIDE    - overrides the config file path (tests only)
#   FM_LAUNCHER_SESSION_OVERRIDE - overrides the Herdr session name (tests only)
#   FM_LAUNCHER_HOME_OVERRIDE    - overrides the resolved Firstmate home (tests only)
#   FM_LAUNCHER_PI_BIN_OVERRIDE  - overrides the resolved Pi executable path (tests
#                                  only, so lab tests never invoke a real model)
#   FM_LAUNCHER_QUOTA_BIN_OVERRIDE - overrides the resolved quota-axi executable
#                                  (tests only, so lab tests never make real
#                                  provider/account calls)
set -u
set -o pipefail

readonly FM_LAUNCHER_HARNESS="pi"
readonly FM_LAUNCHER_BACKEND="herdr"
readonly FM_LAUNCHER_LOG_MAX_BYTES=204800

# ---------------------------------------------------------------------------
# Resolve this launcher's own real path, independent of caller cwd/symlinks -
# every install-specific value (including FM_HOME) is read from the config
# file that lives beside this exact resolved path, never derived from it.
# ---------------------------------------------------------------------------
resolve_self_dir() {
  local src="${BASH_SOURCE[0]}" dir
  while [ -L "$src" ]; do
    dir=$(cd -P "$(dirname "$src")" && pwd)
    src=$(readlink "$src")
    case "$src" in /*) ;; *) src="$dir/$src" ;; esac
  done
  cd -P "$(dirname "$src")" && pwd
}
SELF_DIR=$(resolve_self_dir) || { echo "error: could not resolve launcher's own path" >&2; exit 1; }

CONF_FILE="${FM_LAUNCHER_CONF_OVERRIDE:-$SELF_DIR/fm-launcher.conf}"
if [ ! -f "$CONF_FILE" ]; then
  echo "error: launcher config not found at $CONF_FILE - reinstall with bin/fm-install-launcher.sh (see docs/launcher.md)" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Parse the generated config file: plain "key=value" lines, one per line,
# blank lines and lines starting with "#" ignored. Every value is treated as
# a literal string (never eval'd), so spaces in paths are preserved exactly.
# ---------------------------------------------------------------------------
CONF_HOME=""; CONF_MODEL=""; CONF_THINKING=""; CONF_PI_BIN=""
CONF_QUOTA_PROVIDER=""; CONF_QUOTA_RESERVE_PERCENT=""
CONF_WORKSPACE_LABEL=""; CONF_TAB_LABEL=""
while IFS='=' read -r ck cv || [ -n "$ck" ]; do
  case "$ck" in
    ''|'#'*) continue ;;
  esac
  case "$ck" in
    home) CONF_HOME=$cv ;;
    model) CONF_MODEL=$cv ;;
    thinking) CONF_THINKING=$cv ;;
    pi_bin) CONF_PI_BIN=$cv ;;
    quota_provider) CONF_QUOTA_PROVIDER=$cv ;;
    quota_reserve_percent) CONF_QUOTA_RESERVE_PERCENT=$cv ;;
    workspace_label) CONF_WORKSPACE_LABEL=$cv ;;
    tab_label) CONF_TAB_LABEL=$cv ;;
  esac
done < "$CONF_FILE"

[ -n "$CONF_HOME" ] || { echo "error: launcher config $CONF_FILE is missing required field 'home' - reinstall with bin/fm-install-launcher.sh (see docs/launcher.md)" >&2; exit 1; }
[ -n "$CONF_MODEL" ] || { echo "error: launcher config $CONF_FILE is missing required field 'model' - reinstall with bin/fm-install-launcher.sh (see docs/launcher.md)" >&2; exit 1; }
[ -n "$CONF_THINKING" ] || { echo "error: launcher config $CONF_FILE is missing required field 'thinking' - reinstall with bin/fm-install-launcher.sh (see docs/launcher.md)" >&2; exit 1; }
[ -n "$CONF_PI_BIN" ] || { echo "error: launcher config $CONF_FILE is missing required field 'pi_bin' - reinstall with bin/fm-install-launcher.sh (see docs/launcher.md)" >&2; exit 1; }
[ -n "$CONF_QUOTA_PROVIDER" ] || { echo "error: launcher config $CONF_FILE is missing required field 'quota_provider' - reinstall with bin/fm-install-launcher.sh (see docs/launcher.md)" >&2; exit 1; }
CONF_QUOTA_RESERVE_PERCENT="${CONF_QUOTA_RESERVE_PERCENT:-25}"
CONF_WORKSPACE_LABEL="${CONF_WORKSPACE_LABEL:-firstmate}"
CONF_TAB_LABEL="${CONF_TAB_LABEL:-fm-primary}"
case "$CONF_QUOTA_RESERVE_PERCENT" in
  0|[1-9]|[1-9][0-9]|100) ;;
  *) echo "error: launcher config quota_reserve_percent must be a canonical integer from 0 through 100, got '$CONF_QUOTA_RESERVE_PERCENT'" >&2; exit 1 ;;
esac

readonly FM_LAUNCHER_MODEL="$CONF_MODEL"
FM_LAUNCHER_MODEL_PROVIDER="${CONF_MODEL%%/*}"
FM_LAUNCHER_MODEL_ID="${CONF_MODEL#*/}"
readonly FM_LAUNCHER_MODEL_PROVIDER FM_LAUNCHER_MODEL_ID
case "$FM_LAUNCHER_MODEL_PROVIDER" in
  [Aa][Nn][Tt][Hh][Rr][Oo][Pp][Ii][Cc])
    echo "error: launcher config model provider 'anthropic' is forbidden because this launcher routes models through Pi" >&2
    exit 1
    ;;
esac
readonly FM_LAUNCHER_THINKING="$CONF_THINKING"
readonly FM_LAUNCHER_WORKSPACE_LABEL="$CONF_WORKSPACE_LABEL"
readonly FM_LAUNCHER_TAB_LABEL="$CONF_TAB_LABEL"
readonly FM_LAUNCHER_QUOTA_PROVIDER="$CONF_QUOTA_PROVIDER"
readonly FM_LAUNCHER_QUOTA_RESERVE_PERCENT="$CONF_QUOTA_RESERVE_PERCENT"

# Resolved real executable. A literal "PATH" config value means "resolve
# through PATH at each run" (an explicit operator choice, not a silent
# fallback); anything else must be an absolute path pinned at install time -
# either way a missing/non-executable/unresolvable result is a hard refusal,
# never a silent fall back to a different binary.
if [ -n "${FM_LAUNCHER_PI_BIN_OVERRIDE:-}" ]; then
  FM_LAUNCHER_PI_BIN="$FM_LAUNCHER_PI_BIN_OVERRIDE"
elif [ "$CONF_PI_BIN" = "PATH" ]; then
  FM_LAUNCHER_PI_BIN=$(command -v pi 2>/dev/null) || { echo "error: launcher config pi_bin=PATH but no 'pi' executable is on PATH" >&2; exit 1; }
else
  case "$CONF_PI_BIN" in
    /*) ;;
    *) echo "error: launcher config pi_bin must be an absolute path or the literal 'PATH', got '$CONF_PI_BIN'" >&2; exit 1 ;;
  esac
  FM_LAUNCHER_PI_BIN="$CONF_PI_BIN"
fi
readonly FM_LAUNCHER_PI_BIN

FM_HOME="${FM_LAUNCHER_HOME_OVERRIDE:-$CONF_HOME}"

if [ ! -f "$FM_HOME/AGENTS.md" ] || [ ! -d "$FM_HOME/bin" ]; then
  echo "error: resolved Firstmate home '$FM_HOME' does not look like a Firstmate checkout (missing AGENTS.md or bin/); refusing to start" >&2
  exit 1
fi

FM_LAUNCHER_MIN_PROTOCOL=$(cat "$FM_HOME/bin/herdr-min-protocol" 2>/dev/null) \
  || { echo "error: could not read the shared Herdr protocol floor from $FM_HOME/bin/herdr-min-protocol" >&2; exit 1; }
case "$FM_LAUNCHER_MIN_PROTOCOL" in
  ''|*[!0-9]*) echo "error: invalid Herdr protocol floor in $FM_HOME/bin/herdr-min-protocol" >&2; exit 1 ;;
esac
readonly FM_LAUNCHER_MIN_PROTOCOL

STATE_DIR="$FM_HOME/state"
mkdir -p "$STATE_DIR" 2>/dev/null || { echo "error: could not create/access $STATE_DIR" >&2; exit 1; }
LOG_FILE="$STATE_DIR/.fm-launcher.log"
LOCK_DIR="$STATE_DIR/.fm-launcher.lock"
IDENTITY_FILE="$STATE_DIR/.fm-launcher-primary-identity"

# Deterministic PATH for every OTHER tool this launcher shells out to (herdr,
# jq, quota-axi). Pi itself is resolved as described above, never through
# this PATH when a pinned absolute path was configured. A double-clicked
# .command on macOS runs with a minimal non-interactive-shell PATH, not the
# captain's normal Terminal PATH.
PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/bin:$PATH"
export PATH

MODE="run"
case "${1:-}" in
  --check) MODE="check" ;;
  --dry-run) MODE="dry-run" ;;
  --adopt-current) MODE="adopt-current" ;;
  --help|-h)
    cat <<'EOF'
Usage: fm-launcher.command [--check|--dry-run|--adopt-current]
  --check          run dependency/config/model/quota/ambiguity checks only
  --dry-run        print the redacted intended action only, no mutation
  --adopt-current  first-install only: run this FROM INSIDE the exact live
                    Herdr Pi primary pane you want this launcher to manage.
                    Verifies HERDR_WORKSPACE_ID/TAB_ID/PANE_ID against the
                    live agent/process, then atomically records that exact
                    identity as the launcher's journal. Never renames,
                    closes, or launches anything, and never checks or
                    consumes model quota (it only records an identity that
                    already exists).
  (default)        start-or-attach the primary and attach the Herdr client
EOF
    exit 0
    ;;
  '') ;;
  *) echo "error: unknown argument '$1' (use --check, --dry-run, --adopt-current, or no argument)" >&2; exit 2 ;;
esac

SESSION="${FM_LAUNCHER_SESSION_OVERRIDE:-default}"

# ---------------------------------------------------------------------------
# Bounded, redacted logging. Never logs command substitutions that could
# contain credentials, auth files, full environments, prompts, or source.
# ---------------------------------------------------------------------------
log() {  # <level> <message>
  local level="$1" msg="$2" ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown-time)
  if [ -f "$LOG_FILE" ]; then
    local size
    size=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$size" ] && [ "$size" -gt "$FM_LAUNCHER_LOG_MAX_BYTES" ] 2>/dev/null; then
      tail -c "$((FM_LAUNCHER_LOG_MAX_BYTES / 2))" "$LOG_FILE" > "$LOG_FILE.trim" 2>/dev/null \
        && mv -f "$LOG_FILE.trim" "$LOG_FILE" 2>/dev/null
    fi
  fi
  printf '%s [%s] %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE" 2>/dev/null
  chmod 0600 "$LOG_FILE" 2>/dev/null || true
}
die() { log ERROR "$1"; echo "error: $1" >&2; exit 1; }

log INFO "launcher invoked mode=$MODE session=$SESSION home=$FM_HOME"

# ---------------------------------------------------------------------------
# Single-flight home-scoped launcher lock (distinct from Firstmate's own
# session lock, which this launcher never touches or treats as cleanup
# authority). Recovers a stale lock only after proving both that its recorded
# pid is dead AND that the lock was written by this exact launcher script at
# this exact home.
# ---------------------------------------------------------------------------
LOCK_HELD=0
acquire_lock() {
  local existing_pid existing_launcher
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" > "$LOCK_DIR/pid"
    printf '%s\n' "$SELF_DIR/fm-launcher.command" > "$LOCK_DIR/launcher"
    LOCK_HELD=1
    return 0
  fi
  existing_pid=$(cat "$LOCK_DIR/pid" 2>/dev/null | tr -d '[:space:]')
  existing_launcher=$(cat "$LOCK_DIR/launcher" 2>/dev/null)
  if [ -n "$existing_pid" ] && kill -0 "$existing_pid" 2>/dev/null; then
    die "another launch is already in progress (pid $existing_pid) - wait for it to finish, or attach directly with: herdr session attach $SESSION"
  fi
  if [ "$existing_launcher" != "$SELF_DIR/fm-launcher.command" ]; then
    die "a launcher lock exists at $LOCK_DIR but was not recorded by this exact launcher; refusing to remove it automatically - inspect and remove it by hand if you are certain it is stale"
  fi
  # Recorded process is dead and the lock belongs to this exact launcher/home: safe to reclaim.
  rm -rf "$LOCK_DIR" 2>/dev/null
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    die "could not reclaim a stale launcher lock at $LOCK_DIR (lost a race) - try again"
  fi
  printf '%s\n' "$$" > "$LOCK_DIR/pid"
  printf '%s\n' "$SELF_DIR/fm-launcher.command" > "$LOCK_DIR/launcher"
  LOCK_HELD=1
  log INFO "reclaimed stale launcher lock (dead pid $existing_pid)"
  return 0
}
release_lock() {
  [ "$LOCK_HELD" = 1 ] || return 0
  rm -rf "$LOCK_DIR" 2>/dev/null
}
trap release_lock EXIT

# ---------------------------------------------------------------------------
# Step 1: required binaries and versions. Pi is resolved as described above
# (pinned absolute path, or PATH only when the config explicitly says so).
# herdr/jq/quota-axi still come from the deterministic PATH set above.
# ---------------------------------------------------------------------------
check_tools() {
  if [ ! -x "$FM_LAUNCHER_PI_BIN" ]; then
    die "resolved Pi executable not found or not executable at $FM_LAUNCHER_PI_BIN - reinstall/repair that path before using this launcher (never falls back to a different binary)"
  fi
  local missing=()
  for t in herdr jq quota-axi; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    die "missing required tool(s): ${missing[*]} - install them (see docs/herdr-backend.md and docs/launcher.md) before using this launcher"
  fi

  local status protocol version
  status=$(HERDR_SESSION="$SESSION" herdr status --json --session "$SESSION" 2>/dev/null) \
    || die "'herdr status --json' failed; is herdr installed correctly?"
  protocol=$(printf '%s' "$status" | jq -r '.client.protocol // empty' 2>/dev/null)
  version=$(printf '%s' "$status" | jq -r '.client.version // empty' 2>/dev/null)
  case "$protocol" in
    ''|*[!0-9]*) die "could not read herdr client protocol; refusing to use an unverified herdr build" ;;
  esac
  if [ "$protocol" -lt "$FM_LAUNCHER_MIN_PROTOCOL" ]; then
    die "herdr protocol $protocol (version ${version:-unknown}) is older than the required minimum $FM_LAUNCHER_MIN_PROTOCOL; run 'herdr update' first"
  fi
  local pi_version
  pi_version=$("$FM_LAUNCHER_PI_BIN" --version 2>/dev/null)
  log INFO "tool check passed (herdr protocol=$protocol version=${version:-unknown}; pi=$FM_LAUNCHER_PI_BIN version=${pi_version:-unknown})"
}

# ---------------------------------------------------------------------------
# Step 2: quota gate for the configured provider backing the Pi primary this
# launcher starts. Runs before any action that can start or recover Pi.
# Requires fresh first-party OAuth (never API-key routing), known quota
# semantics, and >= the configured reserve percent remaining in every
# account/weekly window. Prints only a redacted pass/fail summary, never the
# raw payload.
# ---------------------------------------------------------------------------
check_quota() {
  local out quota_bin="${FM_LAUNCHER_QUOTA_BIN_OVERRIDE:-quota-axi}"
  out=$("$quota_bin" --provider "$FM_LAUNCHER_QUOTA_PROVIDER" --json --allow-keychain-prompt 2>/dev/null) \
    || die "'$quota_bin --provider $FM_LAUNCHER_QUOTA_PROVIDER --json' failed - is quota-axi installed and configured?"

  local status source sem_status
  status=$(printf '%s' "$out" | jq -r '.providers[0].state.status // empty')
  source=$(printf '%s' "$out" | jq -r '.providers[0].source // empty')
  sem_status=$(printf '%s' "$out" | jq -r '.providers[0].quotaSemantics.status // empty')

  if [ "$status" != fresh ]; then
    die "$FM_LAUNCHER_QUOTA_PROVIDER quota is not fresh (status=$status) - run: quota-axi --provider $FM_LAUNCHER_QUOTA_PROVIDER --allow-keychain-prompt   and approve Keychain access, then try again"
  fi
  case "$source" in
    oauth|oauth-file|oauth-profile) ;;
    *) die "$FM_LAUNCHER_QUOTA_PROVIDER quota source '$source' is not first-party OAuth (looks like API-key routing) - log in with the subscription CLI flow, not an API key. This launcher never attempts API-key or extra-spend login on the captain's behalf." ;;
  esac
  if [ "$sem_status" != known ]; then
    die "$FM_LAUNCHER_QUOTA_PROVIDER quota semantics are '$sem_status' (not known) - refusing to launch on unknown availability"
  fi

  # Every included account/weekly window individually - the configured
  # reserve floor, checked on every window that bounds ordinary included
  # usage (never the unlimited-credits/pay-per-use surface).
  local windows low_window remaining_report
  windows=$(printf '%s' "$out" | jq -ce '
    [.providers[0].windows[]? | select(.kind=="weekly" or .kind=="session")]
    | select(length > 0)
    | select(all(.[]; (.id | type) == "string" and (.id | length) > 0 and
                      (.percentRemaining | type) == "number" and
                      .percentRemaining >= 0 and .percentRemaining <= 100))
  ' 2>/dev/null) || die "$FM_LAUNCHER_QUOTA_PROVIDER quota payload has no valid included usage windows with numeric percentRemaining values - refusing to launch on unknown availability"
  low_window=$(printf '%s' "$windows" | jq -er --argjson floor "$FM_LAUNCHER_QUOTA_RESERVE_PERCENT" '
    [.[] | select(.percentRemaining < $floor) | (.id+"="+(.percentRemaining|tostring)+"%")] | join(",")
  ' 2>/dev/null) || die "could not evaluate the configured quota reserve floor"
  remaining_report=$(printf '%s' "$windows" | jq -er '
    [.[] | (.id+"="+(.percentRemaining|tostring)+"%")] | join(",")
  ' 2>/dev/null) || die "could not summarize the configured quota windows"
  if [ -n "$low_window" ]; then
    die "$FM_LAUNCHER_QUOTA_PROVIDER included window(s) below the configured ${FM_LAUNCHER_QUOTA_RESERVE_PERCENT}% reserve floor: $low_window - refusing to start the Pi primary (never falls back to paid extra usage). Wait for the window to reset, or start Firstmate manually once quota has recovered."
  fi
  log INFO "quota check passed (provider=$FM_LAUNCHER_QUOTA_PROVIDER source=$source windows: ${remaining_report:-none})"
}

# ---------------------------------------------------------------------------
# Step 3: model preflight. Runs the resolved Pi binary's own offline model
# catalog lookup (no network, no model call, no session) and requires an
# EXACT provider+model row match, refusing a missing/renamed/fuzzy model
# rather than trusting a hardcoded assumption that it still exists.
# ---------------------------------------------------------------------------
check_model_pin() {
  [ "$FM_LAUNCHER_MODEL" = "${FM_LAUNCHER_MODEL_PROVIDER}/${FM_LAUNCHER_MODEL_ID}" ] || die "internal: model pin constants disagree"

  local out match
  out=$("$FM_LAUNCHER_PI_BIN" --offline --list-models "$FM_LAUNCHER_MODEL" 2>/dev/null)
  match=$(printf '%s\n' "$out" | awk -v p="$FM_LAUNCHER_MODEL_PROVIDER" -v m="$FM_LAUNCHER_MODEL_ID" '$1==p && $2==m {print; found=1} END{exit !found}')
  if [ -z "$match" ]; then
    die "Pi's model catalog has no exact '$FM_LAUNCHER_MODEL' entry (checked via '$FM_LAUNCHER_PI_BIN --offline --list-models $FM_LAUNCHER_MODEL') - refusing rather than falling back to a different model"
  fi
  log INFO "model preflight ok ($FM_LAUNCHER_MODEL @ $FM_LAUNCHER_THINKING confirmed in Pi's model catalog)"
}

hcli() { herdr "$@" --session "$SESSION"; }  # HERDR_SESSION not required; --session is authoritative (docs/herdr-backend.md).

# ensure_server: start the Herdr server for SESSION headless if it is not
# already running - Herdr's own ordinary documented start primitive (a bare
# socket CLI call does NOT auto-start the server; mirrored from Firstmate's
# own herdr adapter's fm_backend_herdr_server_ensure in bin/backends/herdr.sh).
# Only ever called from the real mutating run path, never from --check/--dry-run.
ensure_server() {
  local running
  running=$(hcli status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
  [ "$running" = true ] && return 0
  log INFO "starting Herdr server for session '$SESSION' (headless, ordinary documented start)"
  ( hcli server >/dev/null 2>&1 & ) || die "could not start the Herdr server for session '$SESSION'"
  local _i
  for _i in $(seq 1 20); do
    running=$(hcli status --json 2>/dev/null | jq -r '.server.running // false' 2>/dev/null)
    [ "$running" = true ] && return 0
    sleep 0.5
  done
  die "Herdr server for session '$SESSION' did not report running within 10s"
}

# ---------------------------------------------------------------------------
# Step 4a: prove the session itself is not started as a side effect of
# reading its state. `herdr session list --json` is server-global (no
# --session target) and never creates anything.
# ---------------------------------------------------------------------------
session_exists() {
  local list
  list=$(herdr session list --json 2>/dev/null) || return 1
  printf '%s' "$list" | jq -e --arg s "$SESSION" '.sessions[]? | select(.name==$s and .running==true)' >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Step 4b: locate the exact primary and classify state:
#   absent    - no journal and no live session-lock owner (safe to create)
#   alive     - the exact journaled identity is live (and, when checkable,
#               corroborated by Firstmate's own session lock)
#   dead      - the exact journaled tab/pane exists, proven to be a childless
#               idle-shell husk (safe to recovery-start in place)
#   ambiguous - anything that cannot be classified with full confidence
# Sets WS_ID, TAB_ID, PANE_ID, TERMINAL_ID as available.
#
# Identity is EXCLUSIVELY the exact recorded journal (workspace_id/tab_id/
# pane_id/terminal_id) - never a cwd-wide scan: a legitimate crewmate/
# secondmate Pi pane can share the exact same cwd as the primary, so a
# session-wide "any pi agent at this cwd" scan false-positives as "duplicate
# primary" against ordinary fleet activity. Corroborated only by a single
# targeted `agent get` on that one journaled pane_id, plus a read-only check
# of Firstmate's own home-scoped session lock (state/.lock) when present.
# The lock is only ever read, never written/cleared/treated as launcher
# cleanup authority.
# ---------------------------------------------------------------------------
WS_ID=""; TAB_ID=""; PANE_ID=""; TERMINAL_ID=""; STATE=""
SESSION_LOCK_FILE="$FM_HOME/state/.lock"

read_identity_journal() {  # sets J_* globals; returns 1 if absent, 2 if unreadable/malformed
  J_WS=""; J_TAB=""; J_PANE=""; J_TERM=""; J_HOME=""
  J_BACKEND=""; J_HARNESS=""; J_MODEL=""; J_THINKING=""; J_SESSION=""
  [ -f "$IDENTITY_FILE" ] || return 1
  local k v
  while IFS='=' read -r k v; do
    case "$k" in
      workspace_id) J_WS=$v ;;
      tab_id) J_TAB=$v ;;
      pane_id) J_PANE=$v ;;
      terminal_id) J_TERM=$v ;;
      home) J_HOME=$v ;;
      backend) J_BACKEND=$v ;;
      harness) J_HARNESS=$v ;;
      model) J_MODEL=$v ;;
      thinking) J_THINKING=$v ;;
      session) J_SESSION=$v ;;
    esac
  done < "$IDENTITY_FILE"
  [ -n "$J_WS" ] && [ -n "$J_TAB" ] && [ -n "$J_PANE" ] && [ -n "$J_TERM" ] && [ -n "$J_HOME" ] \
    && [ -n "$J_BACKEND" ] && [ -n "$J_HARNESS" ] && [ -n "$J_MODEL" ] \
    && [ -n "$J_THINKING" ] && [ -n "$J_SESSION" ] || return 2
}

write_identity_journal() {  # <workspace> <tab> <pane> <terminal_id>
  local tmp
  tmp=$(mktemp "$STATE_DIR/.fm-launcher-primary-identity.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f "$tmp"; return 1; }
  {
    printf 'home=%s\n' "$FM_HOME"
    printf 'backend=%s\n' "$FM_LAUNCHER_BACKEND"
    printf 'harness=%s\n' "$FM_LAUNCHER_HARNESS"
    printf 'model=%s\n' "$FM_LAUNCHER_MODEL"
    printf 'thinking=%s\n' "$FM_LAUNCHER_THINKING"
    printf 'session=%s\n' "$SESSION"
    printf 'workspace_id=%s\n' "$1"
    printf 'tab_id=%s\n' "$2"
    printf 'pane_id=%s\n' "$3"
    printf 'terminal_id=%s\n' "$4"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$IDENTITY_FILE"
}

# Read-only: the pid Firstmate's own session lock currently records, or empty
# if the lock file is absent/malformed. Never written, moved, or removed by
# this launcher - Firstmate's own session-start/recovery is the sole owner.
read_session_lock_pid() {
  local pid
  [ -f "$SESSION_LOCK_FILE" ] || { echo ""; return; }
  pid=$(cat "$SESSION_LOCK_FILE" 2>/dev/null | tr -d '[:space:]')
  case "$pid" in ''|*[!0-9]*) echo "" ;; *) echo "$pid" ;; esac
}

session_lock_pid_alive() {  # <pid>
  [ -n "$1" ] && kill -0 "$1" 2>/dev/null
}

# True if the session-lock pid appears among the exact pane's own process
# tree (its shell or one of its foreground processes), via Herdr's read-only
# `pane process-info`. This is corroboration, not the primary proof: a
# journal+live-agent match on the exact pane is already sufficient identity,
# but when the lock file IS present and alive, it must point at THIS pane -
# a live lock pointing somewhere else means the journal is stale/foreign.
pane_holds_pid() {  # <pane_id> <pid>
  local info found
  info=$(hcli pane process-info --pane "$1" 2>/dev/null) || return 1
  found=$(printf '%s' "$info" | jq -r --arg pid "$2" '
    .result.process_info as $p
    | (($p.shell_pid|tostring)==$pid) or
      ([$p.foreground_processes[]?.pid|tostring] | index($pid) != null)
  ' 2>/dev/null)
  [ "$found" = true ]
}

unjournaled_label_collision() {
  local workspaces workspace_ids workspace_count workspace_id tabs tab_count
  workspaces=$(hcli workspace list 2>/dev/null) || return 2
  workspace_ids=$(printf '%s' "$workspaces" | jq -ce --arg label "$FM_LAUNCHER_WORKSPACE_LABEL" \
    'select((.result.workspaces | type) == "array") | [.result.workspaces[] | select(.label == $label) | .workspace_id]' 2>/dev/null) || return 2
  workspace_count=$(printf '%s' "$workspace_ids" | jq -er 'length' 2>/dev/null) || return 2
  [ "$workspace_count" -le 1 ] || return 1
  [ "$workspace_count" -eq 1 ] || return 0
  workspace_id=$(printf '%s' "$workspace_ids" | jq -er '.[0]' 2>/dev/null) || return 2
  tabs=$(hcli tab list --workspace "$workspace_id" 2>/dev/null) || return 2
  tab_count=$(printf '%s' "$tabs" | jq -er --arg label "$FM_LAUNCHER_TAB_LABEL" \
    'select((.result.tabs | type) == "array") | [.result.tabs[] | select(.label == $label)] | length' 2>/dev/null) || return 2
  [ "$tab_count" -eq 0 ] || return 1
}

classify() {
  if ! session_exists; then
    STATE=absent
    log INFO "herdr session '$SESSION' does not exist yet"
    return
  fi

  local lock_pid="" journal_status collision_status
  lock_pid=$(read_session_lock_pid)

  read_identity_journal
  journal_status=$?
  if [ "$journal_status" -ne 0 ]; then
    if [ "$journal_status" -eq 2 ] || { [ -e "$IDENTITY_FILE" ] && [ ! -f "$IDENTITY_FILE" ]; }; then
      STATE=ambiguous
      log ERROR "launcher identity journal exists but is unreadable or malformed - refusing to create another primary"
      return
    fi
    # No identity journal (never adopted/created by this launcher). Never
    # scan the session for "any pi at this cwd" and never silently adopt -
    # that heuristic is exactly what produces false-positive duplicates
    # against ordinary crewmate/secondmate Pi activity at the same cwd. If
    # Firstmate's own session lock is live, some primary-like process
    # already owns this home's session without our journal knowing about
    # it - point the captain at --adopt-current instead of guessing.
    if [ -n "$lock_pid" ] && session_lock_pid_alive "$lock_pid"; then
      STATE=ambiguous
      log ERROR "no launcher identity journal, but Firstmate's session lock (pid $lock_pid) is live - a primary may already be running unrecorded; refusing to guess (use --adopt-current from inside it)"
      return
    fi
    unjournaled_label_collision
    collision_status=$?
    if [ "$collision_status" -ne 0 ]; then
      STATE=ambiguous
      if [ "$collision_status" -eq 1 ]; then
        log ERROR "no launcher identity journal, but the configured workspace/tab label already exists or is non-unique - refusing to identify or duplicate it"
      else
        log ERROR "no launcher identity journal, and the configured workspace/tab labels could not be inspected reliably - refusing to create another primary"
      fi
      return
    fi
    STATE=absent
    log INFO "no identity journal and no live session-lock owner; treating as absent"
    return
  fi

  if [ "$J_HOME" != "$FM_HOME" ]; then
    # A journal exists but was written for a different home (should never
    # happen since it lives under this exact home's state/, but check
    # anyway rather than trusting it blindly).
    STATE=ambiguous
    log ERROR "identity journal home '$J_HOME' does not match resolved FM_HOME '$FM_HOME'"
    return
  fi

  if [ "$J_BACKEND" != "$FM_LAUNCHER_BACKEND" ] || [ "$J_HARNESS" != "$FM_LAUNCHER_HARNESS" ] \
     || [ "$J_MODEL" != "$FM_LAUNCHER_MODEL" ] || [ "$J_THINKING" != "$FM_LAUNCHER_THINKING" ] \
     || [ "$J_SESSION" != "$SESSION" ]; then
    STATE=ambiguous
    log ERROR "identity journal runtime pin does not match the configured backend, harness, model, thinking, or session - refusing to attach or recover it"
    return
  fi

  # Single targeted read on the exact journaled pane only - never a
  # session-wide scan.
  local agentinfo agent_kind agent_cwd agent_ws agent_tab agent_term
  agentinfo=$(hcli agent get "$J_PANE" 2>/dev/null)
  agent_kind=$(printf '%s' "$agentinfo" | jq -r '.result.agent.agent // empty' 2>/dev/null)
  if [ -n "$agent_kind" ]; then
    agent_cwd=$(printf '%s' "$agentinfo" | jq -r '.result.agent.cwd // empty')
    agent_ws=$(printf '%s' "$agentinfo" | jq -r '.result.agent.workspace_id // empty')
    agent_tab=$(printf '%s' "$agentinfo" | jq -r '.result.agent.tab_id // empty')
    agent_term=$(printf '%s' "$agentinfo" | jq -r '.result.agent.terminal_id // empty')
    if [ "$agent_kind" = "$FM_LAUNCHER_HARNESS" ] && [ "$agent_cwd" = "$FM_HOME" ] \
       && [ "$agent_ws" = "$J_WS" ] && [ "$agent_tab" = "$J_TAB" ] && [ "$agent_term" = "$J_TERM" ]; then
      # Exact identity confirmed live. Corroborate with the session lock
      # ONLY when the lock is present and alive - an absent/dead lock (no
      # active supervision cycle yet, e.g. right after boot) is not itself
      # disqualifying since exact pane identity is already sufficient proof.
      if [ -n "$lock_pid" ] && session_lock_pid_alive "$lock_pid"; then
        if ! pane_holds_pid "$J_PANE" "$lock_pid"; then
          STATE=ambiguous
          log ERROR "journaled pane $J_PANE has a live '$FM_LAUNCHER_HARNESS' agent, but Firstmate's live session lock (pid $lock_pid) does not belong to that pane's process tree - refusing to trust a possibly-stale journal"
          return
        fi
        log INFO "session-lock corroboration confirmed (pid $lock_pid belongs to journaled pane $J_PANE)"
      fi
      WS_ID=$J_WS; TAB_ID=$J_TAB; PANE_ID=$J_PANE; TERMINAL_ID=$J_TERM
      STATE=alive
      log INFO "exact recorded primary identity confirmed live (ws=$WS_ID tab=$TAB_ID pane=$PANE_ID term=$TERMINAL_ID)"
      return
    fi
    # A live agent exists at the journaled pane id, but its own reported
    # identity fields don't exactly match (Herdr recycled the pane id after
    # a restart, or it's a different kind/cwd). Never adopt it.
    STATE=ambiguous
    log ERROR "journaled pane $J_PANE reports a live agent that does not exactly match the recorded identity (kind=$agent_kind cwd=$agent_cwd ws=$agent_ws tab=$agent_tab term=$agent_term) - refusing to treat it as ours"
    return
  fi

  # No live agent at the journaled pane. If Firstmate's session lock is
  # live, refuse rather than guess whether this is a genuine husk.
  if [ -n "$lock_pid" ] && session_lock_pid_alive "$lock_pid"; then
    STATE=ambiguous
    log ERROR "journaled pane $J_PANE has no live agent, but Firstmate's session lock (pid $lock_pid) is live elsewhere - refusing to guess; inspect by hand"
    return
  fi

  # Does the exact journaled pane still exist at all?
  local paneinfo pane_term pane_cwd
  paneinfo=$(hcli pane get "$J_PANE" 2>/dev/null)
  if [ -n "$paneinfo" ] && printf '%s' "$paneinfo" | jq -e --arg p "$J_PANE" '.result.pane.pane_id==$p' >/dev/null 2>&1; then
    pane_term=$(printf '%s' "$paneinfo" | jq -r '.result.pane.terminal_id // empty')
    pane_cwd=$(printf '%s' "$paneinfo" | jq -r '.result.pane.cwd // empty')
    if [ "$pane_term" = "$J_TERM" ] && [ "$pane_cwd" = "$FM_HOME" ]; then
      WS_ID=$J_WS; TAB_ID=$J_TAB; PANE_ID=$J_PANE; TERMINAL_ID=$J_TERM
      STATE=dead
      log ERROR "recorded primary pane $PANE_ID still exists (same terminal_id, cwd) but has no live '$FM_LAUNCHER_HARNESS' agent - candidate husk, pending process-info proof"
      return
    fi
    # Same pane id but different terminal_id/cwd means Herdr recycled the
    # id after a restart - never trust a recycled id as our own endpoint.
    STATE=ambiguous
    log ERROR "recorded pane id $J_PANE exists but its terminal_id/cwd no longer match the recorded identity - refusing to treat it as ours"
    return
  fi

  # Recorded pane is entirely gone and no live session-lock owner exists.
  # Safe to treat as absent and create a fresh, newly-identified primary.
  STATE=absent
  log INFO "recorded primary identity's pane no longer exists and no live session-lock owner found; treating as absent"
}

# ---------------------------------------------------------------------------
# Husk proof: only called when STATE=dead, immediately before recovery-start.
# Requires the pane's process-info to show a single childless idle shell
# (the shell_pid itself, and no OTHER foreground process/job) at the exact
# journaled terminal/cwd. Any child process, any extra foreground process,
# an unreadable process table, or a mismatched terminal/cwd refuses rather
# than guessing - this convenience launcher never destructively repairs a
# husk it cannot positively prove is idle.
# ---------------------------------------------------------------------------
husk_is_safe_to_recover() {  # <pane_id> <terminal_id>
  local info shell_pid fg_count fg_pid fg_name
  info=$(hcli pane process-info --pane "$1" 2>/dev/null) || { log ERROR "husk proof: pane process-info failed for $1"; return 1; }
  shell_pid=$(printf '%s' "$info" | jq -r '.result.process_info.shell_pid // empty')
  fg_count=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_processes | length' 2>/dev/null)
  if [ -z "$shell_pid" ] || [ -z "$fg_count" ]; then
    log ERROR "husk proof: unreadable process-info for pane $1"
    return 1
  fi
  if [ "$fg_count" -gt 1 ]; then
    log ERROR "husk proof: pane $1 has $fg_count foreground processes (expected at most the idle shell alone) - refusing as not provably idle"
    return 1
  fi
  if [ "$fg_count" -eq 1 ]; then
    fg_pid=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_processes[0].pid // empty')
    fg_name=$(printf '%s' "$info" | jq -r '.result.process_info.foreground_processes[0].name // empty')
    if [ "$fg_pid" != "$shell_pid" ]; then
      log ERROR "husk proof: pane $1's sole foreground process (pid $fg_pid, $fg_name) is not the shell itself (pid $shell_pid) - a foreground job is running, refusing"
      return 1
    fi
    case "$fg_name" in
      bash|zsh|sh|dash|ksh) ;;
      *) log ERROR "husk proof: pane $1's foreground process '$fg_name' is not a recognized idle shell - refusing"; return 1 ;;
    esac
  fi
  log INFO "husk proof: pane $1 confirmed a childless idle shell (shell_pid=$shell_pid, foreground_processes=$fg_count)"
  return 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
check_tools
check_model_pin

# ---------------------------------------------------------------------------
# --adopt-current: guarded first-install bootstrap. Deliberately runs BEFORE
# check_quota: adoption only ever records an identity that already exists
# (tool presence, the exact model pin, the current live pane, and a real
# process, all independently proven below) - it never starts, resumes, or
# talks to a model, so it must never require or consume any model quota. It
# must be run FROM INSIDE the exact live Herdr Pi primary pane it will
# adopt. Herdr injects HERDR_WORKSPACE_ID/HERDR_TAB_ID/HERDR_PANE_ID into
# every pane it manages; this cross-checks those against `herdr pane
# current` (self-report) and a targeted `agent get`/`process-info` on that
# exact pane before atomically seeding the identity journal. Never renames,
# closes, or launches anything - only records the identity that already
# exists. Every other mode (check/dry-run/start/recovery) still runs the
# full quota gate below, since those paths can start or resume a model.
# ---------------------------------------------------------------------------
if [ "$MODE" = adopt-current ]; then
  acquire_lock
  [ ! -e "$IDENTITY_FILE" ] \
    || die "adopt-current is first-install-only and an identity journal already exists at $IDENTITY_FILE - refusing to overwrite it"
  for v in HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID; do
    [ -n "${!v:-}" ] || die "adopt-current must be run FROM INSIDE the live Herdr Pi primary pane you want to adopt - $v is not set in this environment (it is not a Herdr-managed pane)"
  done
  cur=$(herdr pane current --session "$SESSION" 2>/dev/null) || die "adopt-current: 'herdr pane current' failed - is this really running inside a Herdr-managed pane in session '$SESSION'?"
  cur_pane=$(printf '%s' "$cur" | jq -r '.result.pane.pane_id // empty')
  cur_ws=$(printf '%s' "$cur" | jq -r '.result.pane.workspace_id // empty')
  cur_tab=$(printf '%s' "$cur" | jq -r '.result.pane.tab_id // empty')
  cur_term=$(printf '%s' "$cur" | jq -r '.result.pane.terminal_id // empty')
  cur_cwd=$(printf '%s' "$cur" | jq -r '.result.pane.cwd // empty')
  cur_agent=$(printf '%s' "$cur" | jq -r '.result.pane.agent // empty')
  [ "$cur_pane" = "$HERDR_PANE_ID" ] && [ "$cur_ws" = "$HERDR_WORKSPACE_ID" ] && [ "$cur_tab" = "$HERDR_TAB_ID" ] \
    || die "adopt-current: this process's own HERDR_* env (ws=$HERDR_WORKSPACE_ID tab=$HERDR_TAB_ID pane=$HERDR_PANE_ID) does not match Herdr's own 'pane current' report (ws=$cur_ws tab=$cur_tab pane=$cur_pane) - refusing"
  [ "$cur_agent" = "$FM_LAUNCHER_HARNESS" ] \
    || die "adopt-current: the current pane's detected agent is '$cur_agent', not '$FM_LAUNCHER_HARNESS' - run this from inside the actual Pi primary, not any other pane"
  [ "$cur_cwd" = "$FM_HOME" ] \
    || die "adopt-current: the current pane's cwd is '$cur_cwd', not the resolved Firstmate home '$FM_HOME' - refusing to adopt a pane at the wrong cwd"
  [ -n "$cur_term" ] || die "adopt-current: could not read a terminal_id for the current pane - refusing"
  # Process-info proof that a real pi process is actually running in this
  # exact pane (not just a shell that happens to be labeled cwd-correct).
  procinfo=$(hcli pane process-info --pane "$cur_pane" 2>/dev/null)
  pi_present=$(printf '%s' "$procinfo" | jq -r \
    --arg n "$FM_LAUNCHER_HARNESS" \
    --arg model "$FM_LAUNCHER_MODEL" \
    --arg thinking "$FM_LAUNCHER_THINKING" '
    def effective_options($argv):
      ($argv | index("--")) as $boundary
      | if $boundary == null then $argv else $argv[0:$boundary] end;
    def flag_values($argv; $flag):
      [effective_options($argv) as $args
       | range(0; ($args | length)) as $i
       | select($args[$i] == $flag and ($i + 1) < ($args | length))
       | $args[$i + 1]];
    [.result.process_info.foreground_processes[]?
     | select(.argv0 == $n or .name == $n)
     | .argv as $argv
     | select(($argv | type) == "array" and all($argv[]; type == "string"))
     | select(flag_values($argv; "--model") == [$model])
     | select(flag_values($argv; "--thinking") == [$thinking])]
    | length == 1
  ' 2>/dev/null)
  [ "$pi_present" = true ] || die "adopt-current: process-info for pane $cur_pane does not prove exactly one live '$FM_LAUNCHER_HARNESS' process with model '$FM_LAUNCHER_MODEL' and thinking '$FM_LAUNCHER_THINKING' - refusing to adopt an unpinned pane"
  write_identity_journal "$cur_ws" "$cur_tab" "$cur_pane" "$cur_term" \
    || die "adopt-current: could not persist the identity journal"
  log INFO "adopt-current: seeded identity journal from live self-verified primary (ws=$cur_ws tab=$cur_tab pane=$cur_pane term=$cur_term)"
  echo "adopt-current: OK - recorded this exact pane (workspace $cur_ws, tab $cur_tab, pane $cur_pane) as the launcher's managed primary. Nothing was renamed, closed, or launched."
  exit 0
fi

if [ "$MODE" = check ]; then
  check_quota
  before_sessions=$(herdr session list --json 2>/dev/null)
  classify
  after_sessions=$(herdr session list --json 2>/dev/null)
  if [ "$before_sessions" != "$after_sessions" ]; then
    echo "check: FAIL - session list changed during a read-only check (possible unintended session creation); see $LOG_FILE" >&2
    log ERROR "check aborted: session list snapshot changed across classify()"
    exit 1
  fi
  case "$STATE" in
    absent)
      if session_exists; then
        echo "check: OK - prerequisites satisfied; session exists but no primary found yet (would create one on next run); confirmed this check did not start it"
      else
        echo "check: OK - prerequisites satisfied; no primary exists yet and the Herdr session itself is absent (would be started only by a real launch, never by --check)"
      fi
      log INFO "check passed, state=absent, session_exists=$(session_exists && echo yes || echo no)"
      exit 0
      ;;
    alive) echo "check: OK - prerequisites satisfied; exact primary is alive (would attach on next run)"; log INFO "check passed, state=alive"; exit 0 ;;
    dead)
      if husk_is_safe_to_recover "$PANE_ID" "$TERMINAL_ID"; then
        echo "check: OK - the primary tab exists as a provably idle husk (childless shell); would run the pinned pi command in that exact pane on next run, never close/replace it"
        log INFO "check passed, state=dead, husk proven safe"
        exit 0
      fi
      echo "check: FAIL - the primary tab exists but is not a provably idle husk (extra foreground process, unreadable process-info, or mismatched terminal/cwd); see $LOG_FILE. Let Firstmate's normal recovery reconcile it before using this launcher again."
      log ERROR "check failed, state=dead, husk not proven safe"
      exit 1
      ;;
    ambiguous|*) echo "check: FAIL - ambiguous, foreign, or unreadable primary-like endpoint detected; see $LOG_FILE for details. Do not launch until a human inspects Herdr session '$SESSION'."; log ERROR "check failed, state=ambiguous"; exit 1 ;;
  esac
fi

if [ "$MODE" = dry-run ]; then
  check_quota
  classify
  echo "dry-run: session=$SESSION workspace-label=$FM_LAUNCHER_WORKSPACE_LABEL tab-label=$FM_LAUNCHER_TAB_LABEL model=$FM_LAUNCHER_MODEL thinking=$FM_LAUNCHER_THINKING pi-bin=$FM_LAUNCHER_PI_BIN"
  case "$STATE" in
    absent) echo "dry-run: would start/attach the Herdr session as needed, create workspace/tab as needed, and start a new Pi primary, then attach the Herdr client" ;;
    alive) echo "dry-run: would attach the Herdr client to the exact live, identity-matched primary (tab $TAB_ID)" ;;
    dead)
      if husk_is_safe_to_recover "$PANE_ID" "$TERMINAL_ID"; then
        echo "dry-run: would run the pinned pi command in the exact existing husk pane $PANE_ID (proven childless idle shell) and attach - never close/replace it"
      else
        echo "dry-run: would refuse - primary tab exists but is not a provably idle husk; would print the manual recovery pointer instead of mutating anything"
      fi
      ;;
    ambiguous|*) echo "dry-run: would refuse - ambiguous, foreign, or duplicate primary-like endpoint detected" ;;
  esac
  exit 0
fi

acquire_lock
classify
case "$STATE" in
  dead)
    # Recovery restarts Pi and can consume model quota, so enforce the reserve
    # after exact locked classification and immediately before mutation.
    check_quota
    # Reboot recovery: run the pinned Pi command in the EXACT existing husk
    # pane only after process-info proves a childless idle shell at the
    # journaled terminal/cwd. Never close, prune, or replace the pane -
    # `pane run` types into the existing shell exactly like a captain would.
    if ! husk_is_safe_to_recover "$PANE_ID" "$TERMINAL_ID"; then
      die "the Firstmate primary tab in Herdr session '$SESSION' exists but is not a provably idle husk (extra foreground process, unreadable process-info, or mismatched terminal/cwd). This convenience launcher does not repair it destructively - open Herdr ('herdr session attach $SESSION'), let Firstmate's normal session-start/recovery reconcile it, and then re-run this launcher. Details: $LOG_FILE"
    fi
    log INFO "recovering proven idle husk in existing pane $PANE_ID (never closing/replacing it)"
    if ! hcli pane run "$PANE_ID" "'$FM_LAUNCHER_PI_BIN' --model '$FM_LAUNCHER_MODEL' --thinking '$FM_LAUNCHER_THINKING'" >/dev/null 2>&1; then
      die "could not run pi in the existing husk pane (pane $PANE_ID)"
    fi
    log INFO "started resolved pi binary in the existing recovered pane $PANE_ID"
    ;;
  ambiguous)
    die "found an unlabeled, duplicate, unreadable, or foreign primary-like Herdr endpoint in session '$SESSION' (expected workspace '$FM_LAUNCHER_WORKSPACE_LABEL', tab '$FM_LAUNCHER_TAB_LABEL', cwd '$FM_HOME'). Refusing to adopt, close, or replace it. Inspect it yourself with: herdr session attach $SESSION   - then resolve the collision before re-running this launcher. Details: $LOG_FILE"
    ;;
  absent)
    # A new primary can consume model quota. A live primary, by contrast, is
    # only focused/attached below and must remain usable below the reserve.
    check_quota
    log INFO "no exact-identity primary found; creating (this is the one path allowed to start an absent session, via Herdr's ordinary documented server-start primitive)"
    ensure_server
    if [ -z "$WS_ID" ]; then
      wslist=$(hcli workspace list 2>/dev/null) || wslist=""
      ws_matches=$(printf '%s' "$wslist" | jq -r --arg l "$FM_LAUNCHER_WORKSPACE_LABEL" '.result.workspaces[]? | select(.label==$l) | .workspace_id' 2>/dev/null)
      ws_count=$(printf '%s' "$ws_matches" | grep -c . || true)
      if [ "$ws_count" -gt 1 ]; then
        die "multiple workspaces labeled '$FM_LAUNCHER_WORKSPACE_LABEL' appeared just before create (race) - refusing; re-run once the collision is resolved"
      elif [ "$ws_count" -eq 1 ]; then
        WS_ID=$ws_matches
      else
        out=$(hcli workspace create --cwd "$FM_HOME" --label "$FM_LAUNCHER_WORKSPACE_LABEL" --no-focus 2>&1) \
          || die "could not create the '$FM_LAUNCHER_WORKSPACE_LABEL' Herdr workspace"
        WS_ID=$(printf '%s' "$out" | jq -r '.result.workspace.workspace_id // empty')
        [ -n "$WS_ID" ] || die "workspace create returned no workspace id"
        log INFO "created workspace $WS_ID"
      fi
    fi
    unjournaled_label_collision
    collision_status=$?
    if [ "$collision_status" -ne 0 ]; then
      die "the configured workspace/tab label is already present, duplicated, or unreadable without an exact usable journal - refusing to create another primary"
    fi
    out=$(hcli tab create --workspace "$WS_ID" --cwd "$FM_HOME" --label "$FM_LAUNCHER_TAB_LABEL" --no-focus \
      --env "FM_HOME=$FM_HOME" --env "FM_BACKEND=$FM_LAUNCHER_BACKEND" --env "FM_PI_HARNESS=$FM_LAUNCHER_HARNESS" 2>&1) \
      || die "could not create the '$FM_LAUNCHER_TAB_LABEL' tab"
    TAB_ID=$(printf '%s' "$out" | jq -r '.result.tab.tab_id // empty')
    PANE_ID=$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id // empty')
    TERMINAL_ID=$(printf '%s' "$out" | jq -r '.result.root_pane.terminal_id // empty')
    [ -n "$TAB_ID" ] && [ -n "$PANE_ID" ] && [ -n "$TERMINAL_ID" ] || die "tab create returned incomplete ids"
    log INFO "created tab $TAB_ID pane $PANE_ID terminal $TERMINAL_ID"
    write_identity_journal "$WS_ID" "$TAB_ID" "$PANE_ID" "$TERMINAL_ID" \
      || die "could not persist the launcher identity journal - refusing to start an unrecorded primary"
    # Fixed argv against the resolved binary, run once via herdr's supported
    # pane-run primitive (never a duplicated lifecycle system, and never
    # `exec` - a failed `exec` silently destroys the pane instead of leaving
    # a debuggable husk). The tracked .pi/extensions/*.ts auto-load once Pi
    # starts here (project trust approved once per clone) - this launcher
    # never passes -e itself, so extensions are never duplicated.
    if ! hcli pane run "$PANE_ID" "'$FM_LAUNCHER_PI_BIN' --model '$FM_LAUNCHER_MODEL' --thinking '$FM_LAUNCHER_THINKING'" >/dev/null 2>&1; then
      die "could not start pi in the new pane (pane $PANE_ID)"
    fi
    log INFO "started resolved pi binary in pane $PANE_ID"
    ;;
  alive)
    log INFO "exact primary already alive (tab $TAB_ID); attaching"
    ;;
esac

# Focus, then attach the visible client. If attachment fails, print the
# exact manual recovery command rather than launching another primary.
hcli workspace focus "$WS_ID" >/dev/null 2>&1
hcli tab focus "$TAB_ID" >/dev/null 2>&1
log INFO "attaching Herdr client to session $SESSION"
# Deliberately not `exec`: exec would replace this process on successful
# launch of the client binary even if the client itself then exits with an
# error (e.g. a nested-Herdr refusal), which would silently swallow that
# failure instead of falling through to the manual-recovery message below.
herdr session attach "$SESSION"
attach_rc=$?
if [ "$attach_rc" -ne 0 ]; then
  echo "error: could not attach the Herdr client (exit $attach_rc). The primary is running/selected - attach manually with:" >&2
  echo "  herdr session attach $SESSION" >&2
  log ERROR "client attach failed (exit $attach_rc); printed manual recovery command"
  exit 1
fi
