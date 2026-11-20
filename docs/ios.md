# PRBar on iPhone: build, sign and install

The iPhone app lives in `ios/`: `ios/project.yml` (XcodeGen), `ios/PRBarMobile` (app target) and the
`ios/PRBarMobileKit` package (logic and views, also builds on macOS). Design reference: `ios/DESIGN.md`. Decisions:
spec R.7 (`docs/superpowers/specs/2026-11-20-prbar-iphone-design.md`).

## Without Xcode's iOS platform (logic, views, renders)

```
cd ios/PRBarMobileKit
swift test                       # view models, store, cache, keychain, pairing, Face ID logic
swift run PRBarMobileSnapshots   # every screen id, light and dark, to ios/snapshots/
```

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

Until the relay transport (plans 17 and 18) is wired in `ios/PRBarMobile/App/AppBootstrap.swift`, the app runs on
demo data: pairing "succeeds" with code 482 913 a few seconds after scanning any valid `prbar://pair` QR, and the lists,
review, respond, merge, chat, activity and settings show the design's sample PRs. The keychain, the cache and Face ID
are the real ones.
