#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
xcode-select -p >/dev/null
xcrun --find swiftc >/dev/null
[[ -f SwiftClip.xcodeproj/project.pbxproj && -f SwiftClip.xcodeproj/xcshareddata/xcschemes/SwiftClip.xcscheme ]]
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
[[ "$version" =~ ^[0-9]+(\.[0-9]+){1,3}$ ]] || { echo 'Invalid release version'; exit 1; }
python3 Scripts/check_localization.py
mkdir -p dist Docs .build
artifact="SwiftClip${version}"
# Never overwrite any previously delivered disk image, including a same-version rebuild.
if [[ -e "dist/$artifact.dmg" ]]; then artifact="$artifact-$(date +%Y%m%d-%H%M%S)"; fi
suffix=1
candidate="$artifact"
while [[ -e "dist/$candidate.dmg" ]]; do candidate="$artifact-$suffix"; suffix=$((suffix + 1)); done
artifact="$candidate"
if [[ ! -f Resources/AppIcon.icns || Resources/AppIcon.png -nt Resources/AppIcon.icns ]]; then bash Scripts/build_icon.sh; fi
stage=$(mktemp -d "$PWD/.build/release-stage.XXXXXX")
trap 'rm -rf "$stage"' EXIT
xcodebuild -project SwiftClip.xcodeproj -scheme SwiftClip -configuration Release -derivedDataPath .build/ReleaseApp -destination 'generic/platform=macOS' ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build > "$stage/build.log" 2>&1 || { tail -80 "$stage/build.log"; exit 1; }
built='.build/ReleaseApp/Build/Products/Release/SwiftClip.app'
[[ -x "$built/Contents/MacOS/SwiftClip" ]]
[[ -f "$built/Contents/Resources/LICENSE" ]]
ditto "$built" "$stage/SwiftClip.app"
codesign --force --sign - --timestamp=none "$stage/SwiftClip.app"
codesign --verify --deep --strict "$stage/SwiftClip.app"
[[ -f "$stage/SwiftClip.app/Contents/Resources/en.lproj/Localizable.strings" ]]
[[ -f "$stage/SwiftClip.app/Contents/Resources/vi.lproj/Localizable.strings" ]]
mkdir "$stage/dmg"
ditto "$stage/SwiftClip.app" "$stage/dmg/SwiftClip.app"
ln -s /Applications "$stage/dmg/Applications"
# hdiutil is available on every supported macOS runner. New diskutil image
# subcommands vary between macOS versions and are not suitable for CI probing.
hdiutil create -volname SwiftClip -srcfolder "$stage/dmg" -format UDZO "$stage/$artifact.dmg" > "$stage/dmg.log" 2>&1 || { cat "$stage/dmg.log"; exit 1; }
hdiutil verify "$stage/$artifact.dmg" > "$stage/verify.log"
# -n plus the source check protects an existing image even if another process creates it.
mv -n "$stage/$artifact.dmg" "dist/$artifact.dmg"
[[ ! -e "$stage/$artifact.dmg" ]] || { echo 'Release path already exists; existing image preserved.'; exit 1; }
{
  echo "# SwiftClip $version Build Report"
  date '+Build date: %Y-%m-%d %H:%M:%S %Z'
  sw_vers
  xcodebuild -version
  file "$stage/SwiftClip.app/Contents/MacOS/SwiftClip"
  echo 'Configuration: Release; macOS minimum: 13.0; languages: English, Vietnamese; no third-party dependencies.'
  echo 'Signing: ad-hoc. No Developer ID, notarization, provisioning, or paid account.'
  codesign -dv --verbose=2 "$stage/SwiftClip.app" 2>&1
  shasum -a 256 "dist/$artifact.dmg"
  cat Docs/RELEASE_NOTES.md
  if [[ -f Docs/BENCHMARK.md ]]; then cat Docs/BENCHMARK.md; fi
} > "Docs/BUILD_REPORT_$version.md"
cp "Docs/BUILD_REPORT_$version.md" Docs/BUILD_REPORT.md
# Remove only intermediate build output after a successful, checksum-verified image.
# All old DMGs, installed applications, settings and clipboard history remain untouched.
rm -rf .build
trap - EXIT
printf 'Created: %s/dist/%s.dmg\nBuild intermediates cleaned; older DMGs preserved.\n' "$PWD" "$artifact"
