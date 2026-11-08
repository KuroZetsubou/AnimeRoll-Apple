# AnimeRoll for Apple platforms

SwiftUI apps for [AnimeRoll Server](https://github.com/KuroZetsubou/AnimeRoll-Server): iPhone, iPhone Duo (foldable), iPad and Apple TV.
Everything shared lives in the `AnimeRollKit` Swift package (API client, session and passkeys, offline downloads,
player model, design system); `iOS/` and `tvOS/` hold the app targets.

```
AnimeRollKit/   shared Swift package
iOS/            iPhone + iPad app
tvOS/           Apple TV app
```

## Build

Requirements: Xcode 27+ (iOS / tvOS 18 minimum deployment), [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cd iOS  && xcodegen generate && open AnimeRoll.xcodeproj
cd tvOS && xcodegen generate && open AnimeRollTV.xcodeproj
```

Before running on a device:

1. Set your own `DEVELOPMENT_TEAM` in `project.yml`, and change `PRODUCT_BUNDLE_IDENTIFIER` /
   `bundleIdPrefix` if you do not want the default `com.kurozetsubou.animeroll`.
2. A free "Personal Team" can sign and run the app, but Apple does not allow *Associated Domains* on
   personal teams, so passkeys are not available there: sign in with username and password.
3. **Passkeys** (paid developer account): in `project.yml`, under `entitlements › properties`, set
   `com.apple.developer.associated-domains: ["webcredentials:your-domain"]`, run `xcodegen generate` again and
   add `TEAMID.<bundle id>` (and `.tv`) to `AnimeRoll__Apple__AppIds` in the server `.env`.

On first launch enter the address of your server (`https://your-domain`) and sign in.

## Notes

- Native AVPlayer playback (PiP, AirPlay) with ASS subtitles rendered by libass, multi-track audio, resume,
  automatic next episode.
- **iPhone Duo**: the layout follows the hinge (`UIHingeInteraction`, iOS 27.1+): closed, open (two panes),
  tabletop and book postures. On other devices only the screen width matters.
- In a Debug simulator build you can skip the login screen:
  `SIMCTL_CHILD_AR_DEBUG_USER=… SIMCTL_CHILD_AR_DEBUG_PASS=… xcrun simctl launch <device> <bundle id>`;
  force a hinge posture with `SIMCTL_CHILD_AR_DEBUG_HINGE=closed|partial|open`.
- tvOS: AniList is connected from the phone (it is tied to the account on the server). Downloads on Apple TV
  live in the system cache, which tvOS may purge when it needs space.

## License

© 2026 KuroZetsubou. Licensed under [Creative Commons Attribution-NonCommercial-ShareAlike 4.0 International](LICENSE)
(CC BY-NC-SA 4.0): you may share and adapt it for non-commercial purposes, with credit, and you must distribute your
changes under the same license. It is provided "as is", without warranty, and no patent rights are granted.
This is a source-available license, not an OSI-approved open source license.
