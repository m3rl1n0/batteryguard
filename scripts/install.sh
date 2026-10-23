#!/bin/bash
# Installa o aggiorna BatteryGuard dall'ultima release su GitHub.
# Uso: curl -fsSL https://github.com/m3rl1n0/batteryguard/releases/latest/download/install.sh | bash
#
# Non tocca il servizio root: l'attivazione resta all'app (password una volta).

set -euo pipefail

REPO="m3rl1n0/batteryguard"
APP_NAME="BatteryGuard"
BUNDLE_ID="com.alessiocardelli.batteryguard"
DEST="/Applications/${APP_NAME}.app"

say() { printf '%s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

check_system() {
  [ "$(uname -s)" = "Darwin" ] || fail "BatteryGuard runs on macOS only."

  local version major
  version="$(sw_vers -productVersion)"
  major="${version%%.*}"
  [ "$major" -ge 13 ] || fail "BatteryGuard needs macOS 13 Ventura or later (this Mac has ${version})."
}

latest_version() {
  # Il redirect di releases/latest porta a .../tag/vX.Y.Z: niente API, niente limiti di chiamate
  local url tag
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/${REPO}/releases/latest")"
  tag="${url##*/}"
  case "$tag" in
    v[0-9]*) printf '%s' "${tag#v}" ;;
    *) fail "Could not find the latest release." ;;
  esac
}

quit_running_app() {
  pgrep -xq "$APP_NAME" || return 0
  say "Quitting ${APP_NAME}..."
  # "tell application id" lancerebbe l'app se fosse chiusa: qui siamo certi che gira
  osascript -e "tell application id \"${BUNDLE_ID}\" to quit" >/dev/null 2>&1 || true
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -xq "$APP_NAME" || return 0
    sleep 0.5
  done
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 1
}

needs_sudo() {
  [ -w "/Applications" ] || return 0
  if [ -e "$DEST" ]; then
    # Una copia vecchia di proprietà di root non si sostituisce senza sudo
    [ -O "$DEST" ] || return 0
  fi
  return 1
}

main() {
  check_system

  local version zip
  version="$(latest_version)"
  zip="${APP_NAME}-${version}.zip"
  say "Installing ${APP_NAME} ${version}..."

  # globale, non local: la trap EXIT scatta dopo l'uscita da main
  tmp="$(mktemp -d -t batteryguard)"
  trap 'rm -rf "$tmp"' EXIT

  local base="https://github.com/${REPO}/releases/download/v${version}"
  curl -fsSL -o "${tmp}/${zip}" "${base}/${zip}" || fail "Download failed."
  curl -fsSL -o "${tmp}/SHA256SUMS" "${base}/SHA256SUMS" || fail "Download of SHA256SUMS failed."

  local expected actual
  expected="$(awk -v f="$zip" '$2 == f || $2 == "*"f { print $1 }' "${tmp}/SHA256SUMS")"
  [ -n "$expected" ] || fail "${zip} is not listed in SHA256SUMS."
  actual="$(shasum -a 256 "${tmp}/${zip}" | awk '{ print $1 }')"
  [ "$expected" = "$actual" ] || fail "Checksum mismatch for ${zip}. Nothing was installed."
  say "Checksum OK."

  ditto -x -k "${tmp}/${zip}" "${tmp}/unzipped"
  local src="${tmp}/unzipped/${APP_NAME}.app"
  [ -d "$src" ] || fail "${APP_NAME}.app not found in the archive."

  # curl non applica com.apple.quarantine: se c'è, qualcosa l'ha aggiunta, la togliamo solo dall'app
  if xattr -p com.apple.quarantine "${tmp}/${zip}" >/dev/null 2>&1; then
    xattr -dr com.apple.quarantine "$src"
  fi

  quit_running_app

  if needs_sudo; then
    say "Your user can't write to /Applications, so administrator rights are needed to copy the app."
    sudo rm -rf "$DEST"
    sudo ditto "$src" "$DEST"
  else
    rm -rf "$DEST"
    ditto "$src" "$DEST"
  fi

  say "Installed in ${DEST}."
  # Subito dopo la chiusura LaunchServices può rispondere -600 (app ancora in uscita): si riprova
  local try
  for try in 1 2 3 4 5; do
    open -a "$DEST" 2>/dev/null && break
    [ "$try" -lt 5 ] || fail "Could not open ${APP_NAME}. Open it from Applications."
    sleep 1
  done
  say "Opening ${APP_NAME}. Turn on the charge limit from the app (your password is asked once)."
}

# Tutto dentro main: se il download dello script si interrompe a metà, bash non esegue nulla
main "$@"
