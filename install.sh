#!/bin/bash
# Installs Notchy into /Applications.
#
#   From a clone:   ./install.sh
#   Without clone:  curl -fsSL https://raw.githubusercontent.com/sekarasiewicz/notchy/main/install.sh | bash
set -euo pipefail

ZIP_URL="https://raw.githubusercontent.com/sekarasiewicz/notchy/main/dist/Notchy.zip"
DEST="/Applications/Notchy.app"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [ -f "$(dirname "$0")/dist/Notchy.zip" ] 2>/dev/null; then
  cp "$(dirname "$0")/dist/Notchy.zip" "$TMP/Notchy.zip"
else
  echo "Downloading Notchy..."
  curl -fsSL "$ZIP_URL" -o "$TMP/Notchy.zip"
fi

ditto -x -k "$TMP/Notchy.zip" "$TMP"

if pgrep -xq Notchy; then
  echo "Stopping running Notchy..."
  osascript -e 'tell application id "dev.karasiewicz.Notchy" to quit' >/dev/null 2>&1 || true
  sleep 1
fi

rm -rf "$DEST"
mv "$TMP/Notchy.app" "$DEST"
# Ad-hoc signed build: strip quarantine so Gatekeeper does not block it.
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "Installed to $DEST"
open "$DEST"
echo "Notchy is running. Grant Accessibility access when asked (System Settings → Privacy & Security → Accessibility)."
