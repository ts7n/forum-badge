#!/usr/bin/env bash
# Build (and optionally sign + notarize) Forum Badge.
#
# Environment variables (all optional except when signing):
#   DEVELOPER_ID_APPLICATION   e.g. "Developer ID Application: Your Name (TEAMID)"
#                              If unset, the binary is ad-hoc signed (dev only).
#   NOTARY_KEYCHAIN_PROFILE    Name of a profile created with
#                              `xcrun notarytool store-credentials`.
#                              Only used when DEVELOPER_ID_APPLICATION is set.
#   SKIP_X86                   If set, skip the x86_64 slice (Apple-Silicon-only build).
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=ForumBadge
BUILD_DIR=build
APP="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
SOURCES=(
  ForumBadge/main.swift
  ForumBadge/AppDelegate.swift
  ForumBadge/Config.swift
  ForumBadge/FlowClient.swift
  ForumBadge/Preferences.swift
  ForumBadge/SelfRelocator.swift
)
DEPLOY_TARGET=13.0
FRAMEWORKS=(-framework AppKit -framework SwiftUI -framework ServiceManagement)

rm -rf "$BUILD_DIR"
mkdir -p "$MACOS"

echo "==> Compiling arm64 slice"
mkdir -p "$BUILD_DIR/arm64"
swiftc -O -target "arm64-apple-macos${DEPLOY_TARGET}" \
  "${FRAMEWORKS[@]}" \
  -o "$BUILD_DIR/arm64/$APP_NAME" \
  "${SOURCES[@]}"

if [[ -z "${SKIP_X86:-}" ]]; then
  echo "==> Compiling x86_64 slice"
  mkdir -p "$BUILD_DIR/x86_64"
  swiftc -O -target "x86_64-apple-macos${DEPLOY_TARGET}" \
    "${FRAMEWORKS[@]}" \
    -o "$BUILD_DIR/x86_64/$APP_NAME" \
    "${SOURCES[@]}"
  echo "==> Lipo-ing universal binary"
  lipo -create \
    "$BUILD_DIR/arm64/$APP_NAME" \
    "$BUILD_DIR/x86_64/$APP_NAME" \
    -output "$MACOS/$APP_NAME"
else
  cp "$BUILD_DIR/arm64/$APP_NAME" "$MACOS/$APP_NAME"
fi

# Stamp CFBundleVersion with a monotonic timestamp so notarization resubmissions
# of the same CFBundleShortVersionString don't get rejected.
BUILD_VERSION="$(date +%Y%m%d%H%M)"
sed -e "s/__CF_BUNDLE_VERSION__/${BUILD_VERSION}/" \
    ForumBadge/Info.plist > "$CONTENTS/Info.plist"
echo "==> Built $APP (CFBundleVersion=$BUILD_VERSION)"

# Strip any quarantine xattrs that sneaked in from source files.
xattr -cr "$APP"

if [[ -n "${DEVELOPER_ID_APPLICATION:-}" ]]; then
  echo "==> Codesigning with Developer ID"
  codesign --force --options runtime --timestamp \
    --entitlements entitlements.plist \
    --sign "$DEVELOPER_ID_APPLICATION" \
    "$APP"
  codesign --verify --strict --verbose=2 "$APP"

  if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    echo "==> Notarizing via $NOTARY_KEYCHAIN_PROFILE"
    ZIP="$BUILD_DIR/$APP_NAME-submit.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    xcrun notarytool submit "$ZIP" \
      --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
      --wait
    echo "==> Stapling ticket"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    rm -f "$ZIP"
    echo "==> Packaging stapled bundle for distribution"
    ditto -c -k --keepParent "$APP" "$BUILD_DIR/$APP_NAME.zip"
    echo "Distribution artifact: $BUILD_DIR/$APP_NAME.zip"
  else
    echo "==> Signed but not notarized (NOTARY_KEYCHAIN_PROFILE unset)."
    echo "    Other Macs will still warn on first launch."
  fi
else
  echo "==> Ad-hoc signing (DEVELOPER_ID_APPLICATION unset)"
  codesign --force --sign - "$APP"
  echo "    This build is fine for your own machine but not distributable."
fi

echo "Done."
