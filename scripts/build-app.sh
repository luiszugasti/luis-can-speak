#!/bin/bash
# Builds Luis Can Speak.app into ./build without needing Xcode.
set -euo pipefail

readonly ROOT="$(cd "$(dirname "$0")/.." && pwd)"
readonly APP="${ROOT}/build/Luis Can Speak.app"

#######################################
# Compiles the Swift package and wraps the binary in an app bundle.
# Globals:
#   ROOT, APP
# Arguments:
#   None
# Outputs:
#   Writes progress and the app path to stdout.
# Returns:
#   0 on success, non-zero if the build fails.
#######################################
main() {
  cd "${ROOT}"
  # --disable-keychain keeps SwiftPM from asking the keychain for GitHub
  # passwords when it downloads FluidAudio, which is public.
  swift build -c release --disable-keychain

  rm -rf "${APP}"
  mkdir -p "${APP}/Contents/MacOS"
  local bin
  bin="$(swift build -c release --show-bin-path)"
  cp "${bin}/LuisCanSpeak" "${APP}/Contents/MacOS/LuisCanSpeak"

  # Resource bundles from Swift packages (FluidAudio ships some).
  mkdir -p "${APP}/Contents/Resources"
  for bundle in "${bin}"/*.bundle; do
    [[ -e "${bundle}" ]] && cp -R "${bundle}" "${APP}/Contents/Resources/"
  done
  cp "${ROOT}/Resources/Info.plist" "${APP}/Contents/Info.plist"

  # Ad-hoc signature. macOS ties the mic permission to it, so after a
  # rebuild macOS may ask for the microphone again.
  codesign --force --sign - "${APP}"
  echo "Built: ${APP}"
}

main "$@"
