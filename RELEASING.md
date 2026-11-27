# macOS releases

Pushes to `main` trigger the [Stable Sparkle release workflow](.github/workflows/sparkle-release.yml).
It uses Xcode 27.2 on GitHub's `xcode-27` runner. The release script runs with
`--ci --force`, so publishing does not wait for an iPhone App Store update.

The workflow builds the current `main`, increments the macOS patch version and
build number, and signs and notarizes the universal app and DMG. It publishes
`Diffs.dmg`, a signed `appcast.xml` with release notes, and `SHA256SUMS.txt`.
The draft's downloaded assets must match the local hashes and signatures
before the release becomes public.

Installed clients continue to read `appcast.xml` from `main`. The version and
feed are committed and pushed after the release goes public. The workflow uses
the built-in GitHub token with `contents: write`, so that push does not start
another release. The release tag records the source and generated metadata.

GitHub serializes releases and can coalesce pending pushes. Re-running a
published build skips publication or finishes pushing its feed. A retry can
replace assets in its own untagged draft. Tags and drafts for other builds
remain reserved. If a manual release changes the version or feed during the
archive, retry the workflow against current `main`.

## Signing configuration

Set these encrypted GitHub Actions repository secrets. Use the existing Diffs
Sparkle key and Developer ID identity so installed copies can verify updates.

| Secret | Value |
| --- | --- |
| `DIFFS_CERTIFICATE_P12` | Base64 of the Developer ID identity's PKCS#12 export |
| `DIFFS_CERTIFICATE_PASSWORD` | Password for that PKCS#12 export |
| `DIFFS_MAC_PROFILE` | Base64 of the manually managed Diffs Developer ID profile for all devices |
| `DIFFS_NOTARY_API_KEY` | App Store Connect API key used by notarization |
| `DIFFS_NOTARY_KEY_ID` | Notarization API key ID |
| `DIFFS_NOTARY_ISSUER_ID` | Notarization API issuer ID |
| `DIFFS_SPARKLE_PRIVATE_KEY` | Exported Sparkle key for `com.SilverMarcs.Atrium.sparkle` |

Use a manual `MAC_APP_DIRECT` profile for `com.SilverMarcs.Atrium` with the
communication notifications entitlement. Runner credentials live in a
temporary Keychain and protected files. The cleanup step removes both.

## Monitor and retry

```sh
gh run list --workflow sparkle-release.yml
gh run view RUN_ID --log-failed
gh run rerun RUN_ID
```

The workflow can also be dispatched manually from `main`. For nightly builds
or promotion, use `scripts/release.sh --help`. Let any running workflow
finish before starting a manual release.
