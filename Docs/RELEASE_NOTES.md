# Release notes

## 1.0.5

- Include the MIT license inside the installed app bundle as well as the source repository.
- Public distribution uses the audited, pinned GitHub Actions pipeline. Clipboard and UI behavior remain unchanged from 1.0.4.

## 1.0.4

- English and Vietnamese UI with an immediate, persisted language selection.
- Typed localization keys for app-owned UI, menus, tooltips, errors and static timestamps; clipboard data is not translated.
- Versioned DMG builds preserve older files and clean intermediate build output.
- Native SwiftUI/AppKit menu bar app, local SQLite/disk history, searchable/pinned text and images, supported URL/file/rich-text representations, Carbon shortcuts and SMAppService login support.

## 1.0.3

- Nonactivating popup preserves the destination app's activation context.
- First-mouse handling and bounded keyboard-focus readiness checks before sending one Command+V.

## 1.0.2

- Compact borderless popup, bounded adaptive height and best-effort placement around the focused field/pointer.
- Static timestamps refreshed on popup opening, not a real-time counter.

## 1.0.1

- Missing web accessibility metadata no longer automatically prevents native keyboard paste.
- Bounded focus retries, permission/secure-input checks and foreground revalidation.

## Distribution and known limitations

macOS 13+, universal Apple Silicon/Intel. Ad-hoc signed; not Developer ID signed or notarized. Gatekeeper may require app-specific approval. Updating may require removing/re-adding the installed app's Accessibility entry.

Auto Paste is best effort; macOS does not acknowledge delivery into every custom editor. Unmarked secrets cannot be reliably identified. History is local and unencrypted; use Pause/Ignore Apps for sensitive workflows. File URLs require the original files to remain available. CI success does not substitute for live paste, startup/reboot and OS/device acceptance tests.
