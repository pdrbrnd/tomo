#!/bin/sh
# Inject latest git tag into the built Info.plist for local builds so
# CFBundleShortVersionString tracks reality. CI release builds pass
# MARKETING_VERSION via xcodebuild flags and skip this script.
# Skipped when pbxproj's MARKETING_VERSION is already newer than the last
# tag — e.g. between bumping for the next release and actually tagging it.

set -e

if [ -n "$CI" ] || [ -n "$GITHUB_ACTIONS" ]; then
    exit 0
fi

TAG=$(cd "$SRCROOT" && git describe --tags --abbrev=0 2>/dev/null || true)
if [ -z "$TAG" ]; then
    exit 0
fi

TAG_VERSION="${TAG#v}"
PBX_VERSION="${MARKETING_VERSION:-0.0.0}"

# If pbxproj is already at or ahead of the tag, keep the pbxproj value.
HIGHER=$(printf '%s\n%s\n' "$TAG_VERSION" "$PBX_VERSION" | sort -V | tail -n1)
if [ "$HIGHER" = "$PBX_VERSION" ] && [ "$PBX_VERSION" != "$TAG_VERSION" ]; then
    echo "inject-version: pbxproj ($PBX_VERSION) > tag ($TAG_VERSION), keeping pbxproj"
    exit 0
fi

VERSION="$TAG_VERSION"
# Match release.yml's math so Sparkle's CFBundleVersion stays monotonic:
# 1.2.0 → 10200, 1.2.3 → 10203, 2.0.0 → 20000.
BUILD_NUMBER=$(echo "$VERSION" | awk -F. '{ printf "%d", $1*10000 + $2*100 + $3 }')

PLIST="${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}"
[ -f "$PLIST" ] || exit 0

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"

echo "inject-version: $VERSION ($BUILD_NUMBER) from tag $TAG"
