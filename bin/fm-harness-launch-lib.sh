#!/usr/bin/env bash
# Shared verified harness launch argument mechanics.
# Sourced by fm-spawn.sh and fm-rollover.sh so a fresh-session rollover uses the
# same recorded model/effort interpretation as an initial launch.

fm_shell_quote() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

model_flag_for_harness() {
  local harness=$1 model=$2
  [ -n "$model" ] && [ "$model" != default ] || return 0
  case "$harness" in
    claude|codex|opencode|pi|pi-signed|grok|kimi)
      printf -- '--model %s ' "$(fm_shell_quote "$model")"
      ;;
  esac
}

effort_flag_for_harness() {
  local harness=$1 effort=$2
  [ -n "$effort" ] && [ "$effort" != default ] || return 0
  case "$harness" in
    claude)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--effort %s ' "$(fm_shell_quote "$effort")" ;;
      esac
      ;;
    codex)
      case "$effort" in
        low|medium|high|xhigh) printf -- '-c %s ' "$(fm_shell_quote "model_reasoning_effort=\"$effort\"")" ;;
      esac
      ;;
    grok)
      case "$effort" in
        low|medium|high) printf -- '--reasoning-effort %s ' "$(fm_shell_quote "$effort")" ;;
      esac
      ;;
    pi|pi-signed)
      case "$effort" in
        low|medium|high|xhigh|max) printf -- '--thinking %s ' "$(fm_shell_quote "$effort")" ;;
      esac
      ;;
  esac
}
