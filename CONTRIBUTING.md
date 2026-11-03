# Contributing

## Development

Use full Xcode on macOS. Open `SwiftClip.xcodeproj` (scheme `SwiftClip`) or run:

```sh
python3 Scripts/check_publication.py
python3 Scripts/check_localization.py
swift test --scratch-path .build/Tests
bash Scripts/build_release.sh
```

Keep SwiftUI, AppKit, clipboard monitoring, paste orchestration, storage and localization responsibilities separate. Avoid new dependencies and idle background work. Do not add network access, analytics or real clipboard data to tests. The popup must remain keyboard-accessible and use bounded work for large histories/images.

## Before a pull request

- Explain the behavior being fixed, the change and meaningful validation.
- Use synthetic clipboard data. Redact screenshots and logs.
- Add regression coverage for important engine/storage/focus logic; do not mirror cosmetic implementation details in tests.
- Put application-owned UI prose in both EN/VI `.strings` catalogs with typed keys. Preserve placeholder signatures and do not translate payloads or storage/protocol identifiers.
- Run both audits and tests. Verify changes affecting permissions, focus, startup or custom editors manually and state anything not tested.
- Keep secrets, local reports, caches, binaries and signing material out of Git. `.gitignore` is defense-in-depth, not a substitute for reviewing the staged diff.

MIT applies to this repository. Contributions are expected under that license. Report security concerns through [SECURITY.md](SECURITY.md), not public reproductions containing private information.
