#!/usr/bin/env bash
# fm-install-launcher.sh - install a personal one-command macOS launcher for
# this exact Firstmate checkout: a clickable .command file that starts or
# attaches a Herdr-backed Pi primary, pinned to a captain-chosen model.
#
# Usage:
#   bin/fm-install-launcher.sh <destination-directory>
#
# Reads captain-specific choices (model, reasoning, Pi executable, quota
# provider, optional reserve percent) from the local, gitignored
# config/launcher.conf (schema and defaults: docs/launcher.md). Refuses
# rather than picking any of those choices on the captain's behalf.
#
# Resolves this exact checkout's own root as the installed launcher's
# Firstmate home - never relative to the destination directory, so the
# installed copy works from any destination path (including one with
# spaces) without embedding this invocation's absolute checkout path as
# convenience-derived state; it is recorded explicitly as install-specific
# config instead.
#
# Writes two files to the destination, byte-identical to a bare re-run:
#   fm-launcher.command   the tracked template, copied verbatim, mode 0700
#   fm-launcher.conf      generated install-specific config, mode 0600
#
# Safe to re-run any time (e.g. after moving the destination or changing
# config/launcher.conf) - it always overwrites both generated files in place.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

die() {
  printf 'fm-install-launcher.sh: %s\n' "$*" >&2
  exit 1
}

DESTINATION=${1:-}
[ -n "$DESTINATION" ] || die "usage: fm-install-launcher.sh <destination-directory>"

CONF_SOURCE="$ROOT/config/launcher.conf"
[ -f "$CONF_SOURCE" ] || die "missing $CONF_SOURCE - copy docs/examples/launcher.conf there and fill in your model/reasoning/pi_bin/quota_provider choices first (see docs/launcher.md); refusing to guess captain-specific settings"

MODEL=""; THINKING=""; PI_BIN=""; QUOTA_PROVIDER=""; QUOTA_RESERVE_PERCENT=""
WORKSPACE_LABEL=""; TAB_LABEL=""
while IFS='=' read -r ck cv || [ -n "$ck" ]; do
  case "$ck" in
    ''|'#'*) continue ;;
  esac
  case "$ck" in
    model) MODEL=$cv ;;
    thinking) THINKING=$cv ;;
    pi_bin) PI_BIN=$cv ;;
    quota_provider) QUOTA_PROVIDER=$cv ;;
    quota_reserve_percent) QUOTA_RESERVE_PERCENT=$cv ;;
    workspace_label) WORKSPACE_LABEL=$cv ;;
    tab_label) TAB_LABEL=$cv ;;
    *) die "$CONF_SOURCE: unrecognized field '$ck' (see docs/launcher.md for the supported schema)" ;;
  esac
done < "$CONF_SOURCE"

[ -n "$MODEL" ] || die "$CONF_SOURCE is missing required field 'model' (e.g. model=openai-codex/gpt-5.6-sol)"
case "$MODEL" in
  */*) ;;
  *) die "$CONF_SOURCE: 'model' must be '<provider>/<model-id>', got '$MODEL'" ;;
esac
[ -n "$THINKING" ] || die "$CONF_SOURCE is missing required field 'thinking'"
case "$THINKING" in
  low|medium|high|xhigh|max) ;;
  *) die "$CONF_SOURCE: 'thinking' must be one of low|medium|high|xhigh|max (Pi's accepted --thinking levels), got '$THINKING'" ;;
esac
[ -n "$PI_BIN" ] || die "$CONF_SOURCE is missing required field 'pi_bin' (an absolute path to the pi executable, or the literal 'PATH' to resolve it through PATH at each run)"
case "$PI_BIN" in
  PATH) ;;
  /*) [ -x "$PI_BIN" ] || die "$CONF_SOURCE: pi_bin '$PI_BIN' is not an executable file" ;;
  *) die "$CONF_SOURCE: 'pi_bin' must be an absolute path or the literal 'PATH', got '$PI_BIN'" ;;
esac
[ -n "$QUOTA_PROVIDER" ] || die "$CONF_SOURCE is missing required field 'quota_provider' (e.g. quota_provider=codex)"
QUOTA_RESERVE_PERCENT="${QUOTA_RESERVE_PERCENT:-25}"
case "$QUOTA_RESERVE_PERCENT" in
  ''|*[!0-9]*) die "$CONF_SOURCE: 'quota_reserve_percent' must be a plain integer, got '$QUOTA_RESERVE_PERCENT'" ;;
esac
WORKSPACE_LABEL="${WORKSPACE_LABEL:-firstmate}"
TAB_LABEL="${TAB_LABEL:-fm-primary}"

mkdir -p "$DESTINATION" || die "could not create destination directory '$DESTINATION'"
DESTINATION="$(cd "$DESTINATION" && pwd)"

COMMAND_DEST="$DESTINATION/fm-launcher.command"
CONF_DEST="$DESTINATION/fm-launcher.conf"

cp "$ROOT/bin/templates/fm-launcher.command" "$COMMAND_DEST" || die "could not write $COMMAND_DEST"
chmod 0700 "$COMMAND_DEST" || die "could not chmod $COMMAND_DEST"

TMP_CONF=$(mktemp "$DESTINATION/.fm-launcher.conf.XXXXXX") || die "could not create a temp file in '$DESTINATION'"
chmod 0600 "$TMP_CONF" || { rm -f "$TMP_CONF"; die "could not chmod temp config"; }
{
  printf 'home=%s\n' "$ROOT"
  printf 'model=%s\n' "$MODEL"
  printf 'thinking=%s\n' "$THINKING"
  printf 'pi_bin=%s\n' "$PI_BIN"
  printf 'quota_provider=%s\n' "$QUOTA_PROVIDER"
  printf 'quota_reserve_percent=%s\n' "$QUOTA_RESERVE_PERCENT"
  printf 'workspace_label=%s\n' "$WORKSPACE_LABEL"
  printf 'tab_label=%s\n' "$TAB_LABEL"
} > "$TMP_CONF" || { rm -f "$TMP_CONF"; die "could not write temp config"; }
mv -f "$TMP_CONF" "$CONF_DEST" || die "could not install $CONF_DEST"

printf 'fm-install-launcher.sh: installed %s and %s (home=%s model=%s thinking=%s)\n' \
  "$COMMAND_DEST" "$CONF_DEST" "$ROOT" "$MODEL" "$THINKING"
