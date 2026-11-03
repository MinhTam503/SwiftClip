# Localization architecture

- `Localization` owns the persisted language selection and resolves System to the first supported preferred language, falling back to English.
- `L10n.Key` is the typed catalog. English and Vietnamese `.strings` must contain identical keys/placeholders; audit and tests enforce this.
- SwiftUI views observe the shared localizer. AppKit menus, status tooltip/accessibility label and window titles refresh on the language-change notification.
- `AppNotice`/`AppError` retain semantic keys and error codes. UI renders in the current app language rather than retaining a translated string from an older language.
- Original clipboard text/rich-text/binary representations, filenames, bundle IDs, SQLite tokens, shortcut settings and SF Symbols are data/protocol values; they are not translated.
- Timestamps use the popup-opening snapshot with the selected locale, without a real-time timer.
- Standard macOS dialogs/OS-owned services use the system language. No global language preference is modified.
- To add a new supported language: provide its lproj, extend AppLanguage/resolution, include it in Xcode/SwiftPM resources and parity tests. Do not put fallback UI prose into Swift files.
