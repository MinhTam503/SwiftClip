#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/release_app.sh
release_app=$(resolve_release_app)
mkdir -p .build/Profiling
# Profiling-only copy permits debugger attachment. Distributed app has no such entitlement.
ditto "$release_app" .build/Profiling/SwiftClip.app
cat > .build/Profiling/entitlements.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>
PLIST
mv .build/Profiling/SwiftClip.app/Contents/MacOS/SwiftClip .build/Profiling/SwiftClip.app/Contents/MacOS/SwiftClipProfile
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable SwiftClipProfile" .build/Profiling/SwiftClip.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.personal.swiftclip.profile" .build/Profiling/SwiftClip.app/Contents/Info.plist
codesign --force --sign - --entitlements .build/Profiling/entitlements.plist .build/Profiling/SwiftClip.app
trace="${1:-Allocations}"
output="${2:-/private/tmp/SwiftClip-$trace.trace}"
xcrun xctrace record --template "$trace" --time-limit 40s --output "$output" --launch -- "$PWD/.build/Profiling/SwiftClip.app/Contents/MacOS/SwiftClipProfile" --diagnostic-short --diagnostic-output /private/tmp/SwiftClip-profile-measurements.json
