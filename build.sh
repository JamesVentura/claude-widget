#!/bin/bash
# Assemble « Claude Widget.app » à partir de src/ et resources/.
# Aucune dépendance : swiftc est fourni avec les outils de développement d'Apple.
set -e
cd "$(dirname "$0")"

APP="Claude Widget.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp resources/Info.plist   "$APP/Contents/Info.plist"
cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

swiftc -O -o "$APP/Contents/MacOS/ClaudeWidget" src/*.swift

touch "$APP"   # force le Finder à relire le bundle
echo "✅ $(pwd)/$APP"
echo "   Double-clique dessus, ou : open \"$APP\""
