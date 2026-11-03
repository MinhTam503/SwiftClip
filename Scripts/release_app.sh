#!/bin/bash
# Sourced by install/profile/benchmark helpers. Echo only the verified bundle path.
resolve_release_app() {
  if [[ -x "$PWD/dist/SwiftClip.app/Contents/MacOS/SwiftClip" ]]; then printf '%s\n' "$PWD/dist/SwiftClip.app"; return; fi
  local image="${1:-}" mountpoint target
  if [[ -z "$image" ]]; then
    image=$(find "$PWD/dist" -maxdepth 1 -name 'SwiftClip*.dmg' -type f -print | while IFS= read -r path; do stat -f '%m %N' "$path"; done | sort -rn | head -1 | cut -d' ' -f2-)
  fi
  [[ -f "$image" ]] || { echo 'No release DMG found. Run Scripts/build_release.sh first.' >&2; return 1; }
  mountpoint=$(mktemp -d /private/tmp/swiftclip-unpack.XXXXXX)
  if diskutil image attach --help >/dev/null 2>&1; then
    diskutil image attach --readOnly --mountOptions nobrowse --mountPoint "$mountpoint" "$image" >/dev/null
  else
    hdiutil attach "$image" -readonly -nobrowse -mountpoint "$mountpoint" >/dev/null
  fi
  mkdir -p "$PWD/.build"
  target="$(mktemp -d "$PWD/.build/unpacked-release.XXXXXX")/SwiftClip.app"
  if ! ditto "$mountpoint/SwiftClip.app" "$target"; then
    diskutil eject "$mountpoint" >/dev/null 2>&1 || hdiutil detach "$mountpoint" >/dev/null
    rmdir "$mountpoint"; return 1
  fi
  diskutil eject "$mountpoint" >/dev/null 2>&1 || hdiutil detach "$mountpoint" >/dev/null
  rmdir "$mountpoint"
  codesign --verify --deep --strict "$target"
  printf '%s\n' "$target"
}
