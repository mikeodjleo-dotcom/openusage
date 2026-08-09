# Aix distribution

The Aix build keeps the normal OpenUsage menu-bar UI and Sparkle update experience while carrying the local multi-Codex-account extension.

## Update path

1. `.github/workflows/aix-upstream-sync.yml` checks `robinebers/openusage` daily.
2. New upstream commits are merged into the fork's `main` without rewriting history.
3. The merged source must pass `swift test` before it is pushed or tagged.
4. A successful sync creates an `aix-v<upstream-version>-aix.<run>` tag.
5. The existing release workflow builds, Developer-ID signs, optionally notarizes, and publishes the tagged DMG and Sparkle appcast.
6. Installed Aix builds check that fork-owned appcast on the same hourly schedule as official OpenUsage.

Merge conflicts and failing tests stop the chain before publication. They require a source fix; the workflow never force-pushes or publishes an unverified merge.

## Separation from the official build

- Bundle ID: `com.linchen.openusage.aix`
- UI and app name: OpenUsage
- Update signing key and appcast: owned by the fork
- iCloud sync: disabled because the fork does not own the official CloudKit container

The different bundle ID prevents an official update from replacing the modified build. The initial app may be installed at `/Applications/OpenUsage Aix.app`; Sparkle continues updating that bundle in place even though its displayed product name remains OpenUsage.

## One-time fork setup

The fork must use `main` as its maintained branch, enable GitHub Pages for the `gh-pages` branch, and provide `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_TEAM_ID`, `SPARKLE_PRIVATE_KEY`, and `SPARKLE_PUBLIC_KEY`. `APPLE_ID` and `APPLE_PASSWORD` enable Apple notarization when available; without them, the explicitly approved personal Aix build remains Developer-ID signed and Sparkle-EdDSA verified but is published unnotarized. The iCloud profile secrets are not used for Aix tags.

Run **Aix Upstream Sync** once with `force_release` enabled to publish the initial build. After that, upstream changes flow through the scheduled verification and release path automatically.
