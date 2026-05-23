#!/bin/sh
# Inject the latest git tag's version into the built Info.plist so local
# Debug/Release builds report a truthful CFBundleShortVersionString. CI
# release builds pass MARKETING_VERSION explicitly via xcodebuild flags
# and are skipped here (the override is the authoritative version for
# shipped builds).
#
# Why this exists: the project file's MARKETING_VERSION is a static
# fallback. It drifts behind every release because nobody bumps it
# locally. The plugin compat gate (minAppVersion) needs the running app
# to report its real version, so the field has to track reality.

set -e

# CI builds use MARKETING_VERSION from release.yml; don't touch them.
if [ -n "$CI" ] || [ -n "$GITHUB_ACTIONS" ]; then
    echo "inject-version: CI=true, keeping xcodebuild override"
    exit 0
fi

# Shallow clones (rare locally; happens in some CI setups) might have no
# tags. Bail silently — the static pbxproj fallback takes over.
TAG=$(cd "$SRCROOT" && git describe --tags --abbrev=0 2>/dev/null || true)
if [ -z "$TAG" ]; then
    echo "inject-version: no git tag found, keeping pbxproj fallback"
    exit 0
fi

# v1.6.0 → 1.6.0
VERSION="${TAG#v}"

# Mirror release.yml's build-number math so CFBundleVersion (integer-
# compared by Sparkle) monotonically increases across releases:
# 1.2.0 → 10200, 1.2.3 → 10203, 2.0.0 → 20000.
BUILD_NUMBER=$(echo "$VERSION" | awk -F. '{ printf "%d", $1*10000 + $2*100 + $3 }')

PLIST="${BUILT_PRODUCTS_DIR}/${INFOPLIST_PATH}"
if [ ! -f "$PLIST" ]; then
    echo "inject-version: Info.plist not at $PLIST, skipping" >&2
    exit 0
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$PLIST"

echo "inject-version: $VERSION ($BUILD_NUMBER) from tag $TAG"
