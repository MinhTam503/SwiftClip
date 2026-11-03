# Releases

## Create a public release

1. Merge reviewed changes into `main`; let CI pass.
2. Set `CFBundleShortVersionString` and increment `CFBundleVersion` in `Resources/Info.plist`.
3. Update `Docs/RELEASE_NOTES.md`, test and commit the release metadata.
4. Push a tag that exactly matches the app version:
   ```sh
   git tag -a v1.0.9 -m "SwiftClip 1.0.9"
   git push origin v1.0.9
   ```
5. Watch the **Release** workflow. It audits/tests the source, builds an Apple Silicon + Intel DMG, verifies the signature/resources/image checksum and uploads an Actions artifact.
6. The publish job verifies the downloaded checksum, creates a draft release with the DMG/checksum asset, then publishes it. Download and manually validate the release on a Mac.

Existing releases/assets are not replaced. If a run leaves a draft after a publishing failure, review it before retrying; the workflow deliberately stops when that tag already has a release. Do not delete a published release just to reuse its version.

The manual **Run workflow** option builds an Actions artifact only. Tag pushes publish a release. Public Releases downloads are suitable for users; Actions artifacts require GitHub access and expire after 14 days.

## Local build

```sh
bash Scripts/build_release.sh
```

Output: `dist/SwiftClip<version>.dmg`. Existing images remain; a same-version rebuild receives a timestamp/suffix. The script validates localization, builds Release, signs ad-hoc, verifies the bundle, creates/verifies the DMG, writes an ignored local report, then cleans `.build`. Local DMGs are not committed to Git.

## Signing

This pipeline intentionally needs no paid Apple Developer account or signing secret. The app is ad-hoc signed, not Developer ID signed/notarized. Document Gatekeeper and Accessibility reapproval with every release. Do not add private TCC entitlements or weaken the designated requirement to avoid permission prompts.

A future Developer ID/notarization pipeline needs appropriate Apple credentials, a reviewed signing approach and secure GitHub secrets—not files committed to the repository. Do not claim notarization until it has actually passed.

## What CI does not validate

CI tests native rendering, algorithms, private pasteboard round trips, storage, hotkey registration and paste readiness policy. It does not grant Accessibility to the delivered app, confirm real-browser paste delivery, log out/reboot a user machine or prove compatibility with every macOS/Intel installation. Follow `Docs/MANUAL_ACCEPTANCE.md` before describing broader compatibility as tested.
