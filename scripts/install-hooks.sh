#!/bin/bash
# Adds the Luis Can Speak hooks to ~/.claude/settings.json, or removes them
# with --uninstall. Makes a timestamped backup first. Safe to run twice.
set -euo pipefail

readonly ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly HOOK="${ROOT}/hooks/luis-can-speak-hook.sh"
readonly SETTINGS="${HOME}/.claude/settings.json"

#######################################
# Writes the merged settings file.
# Globals:
#   HOOK, SETTINGS
# Arguments:
#   $1 - "install" or "uninstall".
# Outputs:
#   Writes the backup path to stdout.
# Returns:
#   0 on success, non-zero if jq fails.
#######################################
main() {
  local mode="${1:-install}"
  [[ -f "${SETTINGS}" ]] || echo '{}' > "${SETTINGS}"

  local backup="${SETTINGS}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "${SETTINGS}" "${backup}"
  echo "Backup: ${backup}"

  chmod +x "${HOOK}"

  local tmp
  tmp="$(mktemp)"
  jq --arg hook "${HOOK}" --arg mode "${mode}" '
    def mine: (.hooks // []) | any(.command | tostring | contains("luis-can-speak-hook"));
    def entry($event; $timeout; $matcher):
      { hooks: [ { type: "command", command: ($hook + " " + $event), timeout: $timeout } ] }
      + (if $matcher == null then {} else { matcher: $matcher } end);

    # Drop any old Luis Can Speak entries first, so running twice is harmless.
    .hooks = ((.hooks // {}) | with_entries(.value |= map(select(mine | not))))
    | if $mode == "install" then
        .hooks.UserPromptSubmit += [entry("UserPromptSubmit"; 10; null)]
        | .hooks.Stop             += [entry("Stop"; 10; null)]
        | .hooks.StopFailure      += [entry("StopFailure"; 10; null)]
        | .hooks.PermissionRequest += [entry("PermissionRequest"; 600; null)]
        | .hooks.PreToolUse       += [entry("PreToolUse"; 600; "AskUserQuestion")]
        | .hooks.Elicitation      += [entry("Elicitation"; 600; null)]
      else . end
    # Leave out events that end up empty.
    | .hooks |= with_entries(select(.value | length > 0))
  ' "${SETTINGS}" > "${tmp}"
  mv "${tmp}" "${SETTINGS}"
  chmod 600 "${SETTINGS}"
  echo "${mode} done: ${SETTINGS}"
}

case "${1:-}" in
  --uninstall) main uninstall ;;
  *) main install ;;
esac
