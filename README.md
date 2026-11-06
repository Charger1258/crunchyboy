# Stream Anime for iPhone — first playback preview

Native SwiftUI app, installed through SideStore. Catalog requests, source resolution,
playback and history run on the iPhone. No hosted streaming backend is required.

## First version

- Popular/recent anime and title search from the existing HiAnime provider.
- Provider-linked seasons, episode selection, and an extendable stream-adapter interface.
- The Android app's primary subtitled ZokoAnime resolver, ported to Swift.
- AVPlayer with the original video aspect ratio, seeking, resume, and a next-episode action.
- On-device loopback HLS relay for the provider's Referer/Origin requirements. The listener
  binds to 127.0.0.1, lives only during playback, and forwards playlists, segments, keys,
  byte ranges and subtitle renditions already carried in HLS. It does not host a public server.
- Local profiles and separate watch history. Continue/Up Next launches playback; caught-up
  titles open the show. Known episode lists survive incomplete provider responses.
- A direct HTTPS stream test under Settings, to separate player failures from provider failures.

This is **not feature parity with Android yet**. Crunchyroll sign-in/import, imported profile
pictures, AniBridge metadata grouping, episode stills, additional stream adapters, standalone
subtitle-file integration, automatic catalog refresh, picture-in-picture, and TV/phone sync
are follow-up work. Provider season labels are used in this preview; no individual show is
hardcoded. Embedded HLS captions use the native player controls.

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

Windows-side validation can check Swift syntax, YAML/plist/assets, and the IPA packager.
SwiftUI/AVFoundation compilation and simulator tests require the first Mac build. Playback
and SideStore compatibility must then be verified on a physical iPhone; they are not assumed.

The test suite covers HTML identity checks, episode merging, resolver configuration decoding,
playlist URI rewriting, loopback binding, profile isolation, persistence and next-up behavior.
