#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/release_app.sh
source_app=$(resolve_release_app "${1:-}")
[[ -x "$source_app/Contents/MacOS/SwiftClip" ]] || { echo 'Run Scripts/build_release.sh first.'; exit 1; }
codesign --verify --deep --strict "$source_app"
if pgrep -x SwiftClip >/dev/null; then
  osascript -e 'tell application id "com.personal.swiftclip" to quit'
  for attempt in {1..30}; do if ! pgrep -x SwiftClip >/dev/null; then break; fi; sleep 0.2; done
  if pgrep -x SwiftClip >/dev/null; then echo 'SwiftClip is still running; close it and retry.'; exit 1; fi
fi
staging=$(mktemp -d /Applications/.SwiftClip-install.XXXXXX)
trap 'rmdir "$staging" 2>/dev/null || true' EXIT
ditto "$source_app" "$staging/SwiftClip.app"
codesign --verify --deep --strict "$staging/SwiftClip.app"
if [[ -d /Applications/SwiftClip.app ]]; then
  backup="$HOME/Library/Application Support/SwiftClip/AppBackups/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup"
  mv /Applications/SwiftClip.app "$backup/SwiftClip.app"
fi
if ! mv "$staging/SwiftClip.app" /Applications/SwiftClip.app; then
  if [[ -n "${backup:-}" ]]; then mv "$backup/SwiftClip.app" /Applications/SwiftClip.app; fi
  echo "Install failed; staged application: $staging/SwiftClip.app"; exit 1
fi
open /Applications/SwiftClip.app
