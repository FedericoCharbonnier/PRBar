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

`Scripts/ios-build-check.sh` compiles the app for the simulator, for the device SDK (unsigned) and the test bundle
without a run destination (it leaves out the asset catalog, which needs a simulator runtime). Build products go to
`ios/.build-xcode` (ignored).

## With the iOS platform installed

1. Xcode 26 or newer, plus Xcode › Settings › Components › iOS 26 (the platform and its simulator).
2. `brew install xcodegen`, then `Scripts/ios-generate.sh` (generates the ignored `ios/PRBarMobile.xcodeproj`).
3. Signing: `cp ios/Config/Local.xcconfig.example ios/Config/Local.xcconfig` and set `DEVELOPMENT_TEAM` to your Team ID
   (developer.apple.com › Membership). Simulator builds don't need it.
4. Simulator (`xcrun simctl list devices available | grep iPhone` for the name):
   `xcodebuild -project ios/PRBarMobile.xcodeproj -scheme PRBarMobile -destination 'platform=iOS Simulator,name=iPhone 17' build`
   and `… test`.
5. iPhone (cable, Developer Mode on, `xcrun devicectl list devices` for the UDID):
   `xcodebuild -project ios/PRBarMobile.xcodeproj -scheme PRBarMobile -destination 'platform=iOS,id=<UDID>' -allowProvisioningUpdates build`
   then `xcrun devicectl device install app --device <UDID> <path to PRBarMobile.app>`.
   "Automatically manage signing" creates the App ID `com.federico.prbar.ios`, the App Group
   `group.com.federico.prbar.ios` and the keychain group on the first build.

Development builds expire with their provisioning profile (a year with a paid account). Push (APNs sandbox in Debug)
and the notification extension arrive with plan 19 Task 8.

## State of the app

The app talks to the Mac through the relay (`LiveTransport` and `LivePairingService` in
`ios/PRBarMobile/App/AppBootstrap.swift`): pair it from PRBar › Settings › iPhone › Pair iPhone… (or `prbar remote
pair`) on a Mac with iPhone access enabled. The keychain, the cache and Face ID are the real ones.

Launch with `-demo` (Xcode › Scheme › Arguments, or `xcrun simctl launch <device> com.federico.prbar.ios -demo`) for
the design's sample data without network or keychain: pairing "succeeds" with code 482 913 a few seconds after
scanning any valid `prbar://pair` QR, and every screen shows the sample PRs (screenshots).

Still missing: push notifications and the notification extension (plan 19 Task 8, needs the Team ID), and the
checklists on a real iPhone.
