#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/release_app.sh
release_app=$(resolve_release_app)
mode=--diagnostic
if [[ "${1:-}" == --short ]]; then mode=--diagnostic-short; fi
mkdir -p dist
# Unique identity prevents Instruments/LaunchServices from selecting this process
# while a normal SwiftClip instance is open. Code and Release settings are unchanged.
mkdir -p .build/Benchmark
ditto "$release_app" .build/Benchmark/SwiftClip.app
mv .build/Benchmark/SwiftClip.app/Contents/MacOS/SwiftClip .build/Benchmark/SwiftClip.app/Contents/MacOS/SwiftClipBenchmark
/usr/libexec/PlistBuddy -c "Set :CFBundleName SwiftClip Benchmark" .build/Benchmark/SwiftClip.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.personal.swiftclip.benchmark" .build/Benchmark/SwiftClip.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable SwiftClipBenchmark" .build/Benchmark/SwiftClip.app/Contents/Info.plist
codesign --force --sign - .build/Benchmark/SwiftClip.app
caffeinate -i "$PWD/.build/Benchmark/SwiftClip.app/Contents/MacOS/SwiftClipBenchmark" "$mode" --diagnostic-output "$PWD/dist/benchmark.json"
python3 -c 'import json; data=json.load(open("dist/benchmark.json")); assert data[-1]["phase"] == "after_clear_all", "Benchmark interrupted before completion"; assert not any(row.get("interruptedBySleep",False) for row in data), "Sleep interrupted benchmark"'
python3 -m json.tool dist/benchmark.json
