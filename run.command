#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

BUILD_DIR=build
APP_NAME=ForumBadge
APP="$BUILD_DIR/$APP_NAME.app"

mkdir -p "$BUILD_DIR/$APP_NAME.app/Contents/MacOS"

# Compile and link (no Xcode project)
swiftc -o "$BUILD_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" \
  ForumBadge/main.swift ForumBadge/AppDelegate.swift \
  -framework AppKit

# Copy Info.plist into the bundle
cp ForumBadge/Info.plist "$BUILD_DIR/$APP_NAME.app/Contents/Info.plist"

# Run the app (starts in background, menu bar only)
open "$APP"
echo "Built and launched service."
echo "Press any key to close this window."
read -n 1 -s
