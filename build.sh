#!/usr/bin/env bash
# Builds Cuecard.app, installs it to ~/Applications and launches it.
# Signs with a local self-signed identity so macOS keeps Cuecard's permissions across rebuilds
# (ad-hoc signatures change every build, which silently invalidates Accessibility and Screen Recording).
set -euo pipefail
cd "$(dirname "$0")"

APP="Cuecard"
BUILD="build"
BUNDLE="$BUILD/$APP.app"
DEST="$HOME/Applications/$APP.app"
SIGNING=".signing"
KEYCHAIN="$PWD/$SIGNING/cuecard-signing.keychain-db"
KEYCHAIN_PASS="cuecard-local"
IDENTITY="Cuecard Local Signing"

make_identity() {
  [[ -f "$KEYCHAIN" ]] && return 0
  echo "→ Creating local signing identity (one time)…"
  mkdir -p "$SIGNING"
  local tmp; tmp=$(mktemp -d)
  local searchlist; searchlist=$(security list-keychains -d user | tr -d '"')
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$IDENTITY" \
    -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
  /usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/id.p12" -passout pass:cuecard
  security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
  security set-keychain-settings "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
  security import "$tmp/id.p12" -k "$KEYCHAIN" -P cuecard -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null
  # create-keychain adds itself to the search list; put the list back the way it was.
  # shellcheck disable=SC2086
  security list-keychains -d user -s $searchlist
  rm -rf "$tmp"
}

sign() {
  local signed=0
  if make_identity && security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"; then
    # codesign only finds identities in keychains on the search list, so add ours for the duration of the call.
    local searchlist; searchlist=$(security list-keychains -d user | tr -d '"')
    # shellcheck disable=SC2086
    security list-keychains -d user -s $searchlist "$KEYCHAIN"
    codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" --identifier com.vaibhav.cuecard "$1" 2>/dev/null && signed=1
    # shellcheck disable=SC2086
    security list-keychains -d user -s $searchlist
  fi
  if [[ $signed == 1 ]]; then
    echo "→ Signed with $IDENTITY"
  else
    echo "→ Local identity unavailable; signing ad-hoc (permissions reset on each rebuild)"
    codesign --force --sign - --identifier com.vaibhav.cuecard "$1"
  fi
}

echo "→ Quitting running Cuecard…"
pkill -x "$APP" 2>/dev/null || true

rm -rf "$BUILD"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"

echo "→ Drawing icon…"
swiftc -O -target arm64-apple-macos14 -o "$BUILD/make-icon" Tools/icon/main.swift
"$BUILD/make-icon" "$BUILD/$APP.iconset"
iconutil -c icns "$BUILD/$APP.iconset" -o "$BUNDLE/Contents/Resources/$APP.icns"

echo "→ Compiling…"
swiftc -O -swift-version 5 -target arm64-apple-macos26 \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework Speech -framework Carbon -framework CoreAudio -framework EventKit -framework PDFKit -framework ServiceManagement \
  -o "$BUNDLE/Contents/MacOS/$APP" Sources/*.swift

cp Info.plist "$BUNDLE/Contents/Info.plist"

mkdir -p "$BUNDLE/Contents/Resources/Frames" && cp Frames/*.json "$BUNDLE/Contents/Resources/Frames/"
printf 'APPL????' > "$BUNDLE/Contents/PkgInfo"
sign "$BUNDLE"

echo "→ Installing to ${DEST}…"
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$BUNDLE" "$DEST"

if [[ "${1:-}" != "--no-launch" ]]; then
  open "$DEST"
  echo "✓ Cuecard is running. Look for the index card in the menu bar. ⌃⌥A listens, ⌃⌥S shows the panel."
fi
