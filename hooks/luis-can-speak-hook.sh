#!/bin/bash
# Forwards a Claude Code hook event to the Luis Can Speak menu bar app and
# prints the app's reply, which Claude Code reads as this hook's output.
#
# If the app isn't running, curl fails at once and the script prints nothing,
# so Claude Code carries on as normal.
#
# Usage (from ~/.claude/settings.json): luis-can-speak-hook.sh <EventName>

readonly PORT=47321

#######################################
# Sends the hook's JSON input to the app and prints the reply.
# Globals:
#   CMUX_SURFACE_ID - the cmux terminal surface this Claude session runs in.
#   PORT
# Arguments:
#   $1 - hook event name, for example PermissionRequest.
# Outputs:
#   Writes the app's JSON reply to stdout.
# Returns:
#   0 always, so a missing app never blocks Claude Code.
#######################################
main() {
  local event="$1"
  local max_time=5
  # These events wait while you answer out loud.
  case "${event}" in
    PermissionRequest | PreToolUse | Elicitation) max_time=590 ;;
  esac

  curl --silent --show-error --fail \
    --max-time "${max_time}" \
    --connect-timeout 1 \
    --header "Content-Type: application/json" \
    --header "X-Cmux-Surface: ${CMUX_SURFACE_ID:-}" \
    --data-binary @- \
    "http://127.0.0.1:${PORT}/hook/${event}" 2>/dev/null
  return 0
}

main "$@"
