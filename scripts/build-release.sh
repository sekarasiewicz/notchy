#!/bin/bash
# Builds a Release, ad-hoc signed Notchy.app and zips it into dist/Notchy.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild -project Notchy.xcodeproj -scheme Notchy -configuration Release \
  -derivedDataPath build/release \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES build | tail -3

APP="build/release/Build/Products/Release/Notchy.app"
mkdir -p dist
rm -f dist/Notchy.zip
ditto -c -k --keepParent "$APP" dist/Notchy.zip
echo "dist/Notchy.zip: $(du -h dist/Notchy.zip | cut -f1)"
