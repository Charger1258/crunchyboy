# Stream Anime for iPhone — TV parity preview

Native SwiftUI app, installed through SideStore. Catalog requests, source resolution,
playback and history run on the iPhone. No hosted streaming backend is required.

## Current preview (0.2)

- Charcoal/orange TV theme, featured title, horizontal Popular, Recently Updated,
  Anime Series and Anime Films shelves, search, and full-screen profile selection.
- The TV app's generated anime-offline-database title aliases and AniBridge TVDB ranges
  bundled locally, with exact-title AniList fallback for unresolved identities.
- Structured episode coordinates and generic multi-title offset checks keep display
  numbering separate from the provider number used for playback. Unknown/ambiguous
  mappings retain provider coordinates; individual shows are never hardcoded.
- Related release discovery requires the same structured series identity. Episode
  thumbnails/titles use identity-checked ani.zip metadata and fall back gracefully.
- Primary ZokoAnime plus the TV app's two AniKoto HLS gateways resolve concurrently.
  Verified manifest quality ranks candidates; sources that fail during playback receive
  a persisted 30-minute cooldown. These are community sources, with no availability guarantee.
- Native AVPlayer, full picture aspect ratio, seek controls, resume, next episode,
  optional automatic next episode, and remembered subtitle language across episodes.
- A loopback-only HLS relay preserves allowed provider playback headers. External
  WebVTT/SRT caption files are exposed through HLS subtitle renditions; SRT timestamps
  are converted to WebVTT. Native embedded subtitles remain intact.
- Separate local profile histories, watched episode indicators, preview cards, and
  darkened caught-up cards. Home refreshes the six most recent watching titles to
  discover new episodes without changing history order.
- CI tests cover model/parser/playback infrastructure and native navigation. UI test
  screenshots are exported under build/artifacts/screenshots; catalog screenshots use
  live data, never title-specific substitutions or test mappings.

Still outside this pass: Crunchyroll sign-in/import and imported avatars, TV/phone sync,
AnimeGG MP4 fallback, picture-in-picture, and full offline/paginated library browsing.
Live streams and external captions still require physical iPhone testing. Automated
parser/navigation tests are not proof of working provider playback.

## Build with Codemagic

This folder is the entire `Charger1258/crunchyboy` repository. No Android build outputs,
personal watch history, cookies, passwords, signing keys, or private import snapshots belong here.

1. In your **personal** Codemagic account, add the private GitHub repository.
2. Choose the `codemagic.yaml` configuration from the repository root.
3. Select `ios-sidestore-preview` and start a build on the intended branch.
4. The workflow generates the Xcode project, runs simulator tests, compiles an **arm64
   iPhone device build**, and packages `StreamAnime-unsigned.ipa` as a downloadable artifact.
5. Download the IPA on the iPhone, share/open it in SideStore, and let SideStore sign/install it.

No Apple developer certificate, App Store Connect key, paid developer membership, or Apple
Account secret is required in Codemagic for this unsigned build. SideStore handles signing
on the phone. Do not choose a simulator `.app` as the installation artifact.

## Build on a compatible Mac

Requires Xcode with an iOS 17+ SDK and a simulator runtime, plus XcodeGen:

```sh
brew install xcodegen
bash scripts/test.sh
bash scripts/build-ipa.sh
```

`project.yml` is the source of truth. `StreamAnime.xcodeproj` is generated and ignored.
The SwiftSoup parser dependency is pinned to 2.7.7. IPA packaging refuses simulator builds.

## First device test

1. Install, launch, and choose a profile. Check Home and Search.
2. Open an anime, pick an episode, and confirm picture **and sound** on the actual iPhone.
3. Rotate the phone and seek both directions. Confirm the full picture remains visible.
4. Inspect the player's captions menu. Embedded subtitles should appear when supplied.
5. Close playback, reopen the Continue Watching card, and confirm resume position.
6. Finish an episode or use Next Episode; verify next-up and caught-up behavior.
7. Switch profiles and verify the other profile's history is separate.
8. If source playback fails, use Settings → Playback test with a known-working HTTPS HLS URL.
   Report the on-screen error, iPhone model and iOS version. Do not post signed stream URLs.

## Verification status

Windows validation checks Swift syntax/UTF-8, YAML/plist/assets and IPA packaging.
Codemagic compiles the native simulator and arm64 device targets, runs unit/UI tests,
and exports screenshots. Physical-device playback is a separate required check.

The test suite covers HTML identity checks, episode merging, resolver configuration decoding,
playlist URI rewriting, loopback binding, profile isolation, persistence and next-up behavior.
