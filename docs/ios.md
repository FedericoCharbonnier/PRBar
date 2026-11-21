# PRBar on iPhone: build, sign and install

The iPhone app lives in `ios/`: `ios/project.yml` (XcodeGen), `ios/PRBarMobile` (app target) and the
`ios/PRBarMobileKit` package (logic and views, also builds on macOS). Design reference: `ios/DESIGN.md`. Decisions:
spec R.7 (`docs/superpowers/specs/2026-11-20-prbar-iphone-design.md`).

## Without Xcode's iOS platform (logic, views, renders)

```
cd ios/PRBarMobileKit
swift test                       # view models, store, cache, keychain, pairing, Face ID logic, LiveTransport
swift run PRBarMobileSnapshots   # every screen id, light and dark, to ios/snapshots/ (demo data)
```

End to end on this Mac, no simulator: `Scripts/ios-e2e.sh` (needs Go) builds the relay into a temporary folder, runs
it on 127.0.0.1 and drives the phone's view models over `LiveTransport` against a real `RemoteAccessService` with
fixture PRs: pairing (QR, code, acknowledgement), home, review toggle, approve and merge with Face ID proofs (software
key), chat, revoke, a relay 4403 that must not unpair, a Mac that registers again at the relay without going offline
(the phone must rebuild its session) and Face ID turned off and on from the Mac mid-session. Without
`PRBAR_RELAY_BIN` the suite is skipped.

Security review decisions that show in the app (spec P.16): "Tests" on the Respond screen asks for Face ID (the Mac
runs the repo's test command); the pairing is stored only after **Codes Match** on the phone; the mailbox's `home` is
shown only when it is newer than what the phone has and at most 7 days old, with the Mac's time as "Last updated"; a
dead session (Mac reconnected, `bye`, timeout) reconnects and resubscribes on its own.

`Scripts/ios-build-check.sh` compiles the app (with the notification extension embedded) for the simulator, for the device SDK (unsigned) and the test bundle
without a run destination (it leaves out the asset catalog, which needs a simulator runtime). Build products go to
`ios/.build-xcode` (ignored).

## With the iOS platform installed

1. Xcode 26 or newer, plus Xcode › Settings › Components › iOS 26 (the platform and its simulator).
2. `brew install xcodegen`, then `Scripts/ios-generate.sh` (generates the ignored `ios/PRBarMobile.xcodeproj`).
3. Signing: `Scripts/iphone-setup.sh --team-id <TEAM_ID>` (or copy `ios/Config/Local.xcconfig.example` to
   `ios/Config/Local.xcconfig` and set `DEVELOPMENT_TEAM`; developer.apple.com › Membership). Simulator builds don't
   need it. The team also gives the keychain group its prefix (`$(AppIdentifierPrefix)com.federico.prbar.ios.shared`),
   which the app and the notification extension share.
4. Simulator (`xcrun simctl list devices available | grep iPhone` for the name):
   `xcodebuild -project ios/PRBarMobile.xcodeproj -scheme PRBarMobile -destination 'platform=iOS Simulator,name=iPhone 17' build`
   and `… test`.
5. iPhone (cable, Developer Mode on, `xcrun devicectl list devices` for the UDID):
   `xcodebuild -project ios/PRBarMobile.xcodeproj -scheme PRBarMobile -destination 'platform=iOS,id=<UDID>' -allowProvisioningUpdates build`
   then `xcrun devicectl device install app --device <UDID> <path to PRBarMobile.app>`.
   "Automatically manage signing" creates the App IDs `com.federico.prbar.ios` (Push Notifications, App Groups) and
   `com.federico.prbar.ios.notifications`, the App Group `group.com.federico.prbar.ios` and the keychain group on the
   first build. `Scripts/iphone-setup.sh --install-iphone` does steps 2 and 5 (finds the iPhone, checks Developer
   Mode, builds Debug signed into `ios/.build-xcode/device` and installs it).

Development builds expire with their provisioning profile (a year with a paid account). Debug builds use the APNs
sandbox (`aps-environment` development, and the app tells the relay `env: sandbox`); Release builds use production. One
build setting per configuration (`PRBAR_APS_ENVIRONMENT`/`PRBAR_PUSH_ENVIRONMENT` in `project.yml`) drives both.

## Push notifications

- `PRBarMobileNotifications` (notification service extension, links only `PRBarMobileCore`): opens the HPKE envelope
  in the push's `e` field with `devicePushKey` and the paired Mac from the shared keychain group, rejects pushes older
  than 24 h (or more than 10 min in the future) and ids already shown (last 200, `Push/seen.json` in the App Group),
  and replaces title, body, thread, badge and category, leaving `deepLink`/`pr` in `userInfo`. Anything else, and
  running out of time, keeps the relay's "PRBar — New activity on your Mac". The logic is `PushOpener`,
  `PushNotificationProcessor` and `PushCategory` in the kit (`PushTests`, `swift test`).
- The app registers for APNs after the notification permission and on every launch, and sends the token to the relay
  (`apns` frame) on every connection. Categories `PR` (generic), `PR.review`, `PR.respond`, `PR.merge`, all actions
  `.foreground`; the delegate opens the deep link and shows no banner for the PR on screen. The icon's badge follows
  the Mac's `badgeCount`.
- The relay needs the APNs key: `Scripts/iphone-setup.sh --apns-key … --apns-key-id …` (docs/iphone.md).

## State of the app

The app talks to the Mac through the relay (`LiveTransport` and `LivePairingService` in
`ios/PRBarMobile/App/AppBootstrap.swift`): pair it from PRBar › Settings › iPhone › Pair iPhone… (or `prbar remote
pair`) on a Mac with iPhone access enabled. The keychain, the cache and Face ID are the real ones.

Launch with `-demo` (Xcode › Scheme › Arguments, or `xcrun simctl launch <device> com.federico.prbar.ios -demo`) for
the design's sample data without network or keychain: pairing "succeeds" with code 482 913 a few seconds after
scanning any valid `prbar://pair` QR, and every screen shows the sample PRs (screenshots).

Still missing: the checklist on a real iPhone (`docs/qa/plan-19-checklist.md`), which needs the Team ID, the APNs
key, Xcode's iOS platform and the iPhone (`Scripts/iphone-setup.sh` without arguments shows what's left).
