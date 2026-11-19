#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
export MACOSX_DEPLOYMENT_TARGET=14.0
build_dir="$PWD/.build"
staging="$build_dir/staging/Margin.app"
app="$build_dir/Margin.app"
mkdir -p "$staging/Contents/MacOS" "$staging/Contents/Resources"

xcrun swiftc -module-cache-path "$build_dir/ModuleCache" -swift-version 5 -O -module-name Margin Sources/*.swift -o "$staging/Contents/MacOS/Margin"
cp Resources/Info.plist "$staging/Contents/Info.plist"
cp Resources/Notes.applescript "$staging/Contents/Resources/Notes.applescript"
codesign --force --sign "${MARGIN_SIGNING_IDENTITY:--}" --options runtime \
    --entitlements Resources/Margin.entitlements "$staging"
codesign --verify --strict "$staging"

mkdir -p "$app"
ditto "$staging" "$app"
printf '%s\n' "$app"
