# PRBar for iPhone

PRBar for iPhone is a remote control for PRBar on your Mac. It shows your PRs and their status, receives the same
notifications, and lets you review, respond, fix CI, chat with Claude and merge. **The Mac does all the work**
(GitHub, Claude, Slack, push, merge); the iPhone sends commands and shows what the Mac sends back.

The Mac and the iPhone talk through a small relay server (yours, see `relay/`). The Mac connects *out* to the relay,
so no port is opened on the Mac, and everything between the Mac and the iPhone is end-to-end encrypted.

## 1. Install the iPhone app

Until there's a public TestFlight, build it with Xcode. `Scripts/iphone-setup.sh` runs every step for you, asks before
each one that touches something outside the repo, and can be run again at any time (without arguments it only shows
what's done and what's left):

1. Install Xcode 26 (or newer) and add your Apple Developer account (Xcode › Settings › Accounts). `brew install xcodegen`.
2. Your Team ID (developer.apple.com › Membership) for signing:
   `Scripts/iphone-setup.sh --team-id <TEAM_ID>` (writes `ios/Config/Local.xcconfig`, which isn't in git).
3. Xcode's iOS platform (about 10 GB; the script checks the free disk first): `Scripts/iphone-setup.sh --ios-platform`.
4. Push notifications: create an APNs key (Certificates, Identifiers & Profiles › Keys › Apple Push Notifications
   service) and hand it to your relay's server:
   `PRBAR_RELAY_SERVER=root@your-server Scripts/iphone-setup.sh --apns-key ~/Downloads/AuthKey_<KEY_ID>.p8 --apns-key-id <KEY_ID>`.
   It checks the file is an APNs key (without printing it), copies it to the server, sets `APNS_KEY_ID`,
   `APNS_TEAM_ID` and `APNS_TOPIC` in the relay's settings, restarts the relay and checks push is on. Then delete the
   `.p8` from Downloads: it only needs to live on the server.
5. Connect the iPhone with a cable once, turn on Developer Mode (Settings › Privacy & Security), then
   `Scripts/iphone-setup.sh --install-iphone` builds the app signed for it and installs it.

`PRBAR_RELAY_SERVER` is the ssh destination of the server that runs the relay; it's only read from the environment.
Without the script: `Scripts/ios-generate.sh`, open `ios/PRBarMobile.xcodeproj`, choose the iPhone and press Run.

When a TestFlight or App Store link exists, save it on the Mac and Settings › iPhone shows it as a QR code under
**Get PRBar for iPhone** (scan it with the iPhone's Camera):

```
prbar remote app-link set https://testflight.apple.com/join/XXXXXXXX
prbar remote app-link clear
```

Only `https` links to `testflight.apple.com` or `apps.apple.com` are accepted. That QR is public and permanent; it's
never shown next to the pairing QR, which is secret and expires.

## 2. Turn on iPhone access on the Mac

Settings › iPhone › **Allow iPhone remote control**, or:

```
prbar remote enable --relay prbar.fcharbonnier.duckdns.org
```

or let the setup script do it with the token read straight from the relay's server (it's never shown or saved):
`PRBAR_RELAY_SERVER=root@your-server Scripts/iphone-setup.sh --install-mac` (it first offers to build and install this
checkout's PRBar, replacing the installed one).

The first time, PRBar asks for the relay's **enrollment token** (`RELAY_ENROLL_TOKEN` in the relay's `.env`). It's
used once to create this Mac's account on the relay and is never stored. Turning access off and on again
(`prbar remote disable` / `enable`) doesn't ask for it. `prbar remote status` shows the connection.

Options:

- **Keep this Mac awake while charging** (`prbar remote keep-awake on`): while iPhone access is on and the Mac is on
  power, PRBar keeps it from idle sleep so the iPhone can reach it. The display still sleeps. With the lid closed and
  no external display, macOS sleeps anyway. `pmset -g assertions | grep PRBar` shows it.
- **Keep the last state on the relay for 7 days** (`prbar remote mailbox on|off`, on by default): the Mac leaves its
  latest PR list, encrypted for each paired iPhone, so the iPhone shows something recent while the Mac sleeps
  ("Last updated" is when the Mac wrote it). The iPhone never shows a copy older than 7 days or older than what it
  already has. Turning it off replaces it with an empty state (on the next connection if the Mac is offline).

## 3. Pair the iPhone

Settings › iPhone › **Pair iPhone…** (or `prbar remote pair` in a terminal) shows a QR code. Scan it with the iPhone's
Camera or with PRBar on the iPhone. Both screens then show the same **6-digit code**: if they match, choose
**Codes Match** (or answer `y`). The QR works once and expires in 5 minutes. If the codes don't match, cancel:
someone else may have scanned your QR.

By default, **merge, push, approve and running the tests need Face ID** on the iPhone. You can turn it off per iPhone
(Settings › iPhone, `prbar remote devices --require-face-id <iphone> off`, or on the iPhone itself, which asks for Face
ID to turn it off). The iPhone can ask Claude to implement fixes and edit them in the chat without Face ID, but that
never runs anything: the repo's test command (and a push, which runs your git hooks) only runs on the Mac with a Face ID
proof from that iPhone, checked by the Mac. A change of this setting on the Mac reaches a connected iPhone right away.
If the Mac confirms the code before you tap **Codes Match** on the iPhone, the iPhone waits for your tap before it
stores the pairing.

## Notifications

After pairing, the iPhone asks to send you notifications. They're the Mac's own (same rules, same switches: the
iPhone's Settings change the Mac's), sent through the relay to Apple **encrypted for this iPhone**: the relay and Apple
only see "PRBar — New activity on your Mac". A small extension on the iPhone decrypts the real title and text before
they show, and drops anything older than a day or already shown (a relay sending an old push again). If it can't
decrypt one (the iPhone was revoked, or it was restarted and never unlocked since), you see the generic text.
Tapping opens the PR on the right screen; long-press for Review, Respond, Merge or Chat. Nothing runs from a
notification: Merge opens the merge sheet, with its Face ID step. The app icon's badge is the Mac's.

## 4. Revoke or reset

- **Revoke** an iPhone: Settings › iPhone › Revoke…, `prbar remote revoke <iphone>`, or "Unpair this iPhone" on the
  iPhone. The Mac forgets its keys right away, so it can't connect again even if the relay misbehaves. If the Mac is
  offline (or iPhone access is off), the relay is told the next time the Mac connects: on every connection the Mac
  removes from the relay any iPhone it doesn't have, which also deletes its mailbox copy.
- **Reset iPhone Access…** (`prbar remote reset`): new Mac keys and a new relay account, and every iPhone is removed.
  Use it if the relay or the Mac may be compromised. You'll need the enrollment token again. The relay can't delete
  accounts, so PRBar keeps the old account's relay key until it has removed every iPhone of that account from the relay
  (right away, or at the next start if the relay can't be reached), then forgets it.

## What the relay can and can't see

| The relay (and anyone who controls the server) can | It can't |
|---|---|
| See account, device and pairing ids, when each side is online, message sizes (padded to 256 bytes) and timing, IP addresses, and the iPhones' push tokens | Read anything: PRs, code, comments, chat, the Mac's state and notifications are encrypted end to end (Noise for sessions, HPKE for pushes and the mailbox) |
| Drop or delay messages, or make pairing fail (a temporary outage) | Send commands to the Mac: it doesn't have the iPhones' keys, and old commands expire (2 minutes, or the iPhone's own deadline) |
| Send an empty push ("New activity on your Mac") | Show a fake notification: the iPhone only shows what the Mac encrypted |
| Refuse to forget a revoked iPhone | Let a revoked iPhone back in: the Mac enforces revocation |
| — | Pair its own phone: it needs the secret in the QR and your OK on the 6-digit code |
| — | Merge, push, approve or run the tests without Face ID: the Mac checks the Face ID signature |

Frames are **not compressed** before encryption: a PR list mixes private data with titles anyone can write, and
compressed sizes would leak it. What the iPhone receives never includes local paths (your home folder, clones, worktree
and temporary folders, anywhere in a message, test output or chat), tool paths or SSH hosts from the Mac, terminal
escape codes or invisible bidi characters, and tokens that show up in test output are masked.

The Mac also caps what one iPhone can ask for (8 requests at a time, 30 in a burst then 5 per second, and a few new
secure sessions per minute), so a stolen phone or a misbehaving relay can't flood it.

What the iPhone can do is limited on purpose: it can read and act on PRs, but it can't change accounts, repos, tool
paths, SSH hosts, Slack, rules, prompts, updates or iPhone access itself ("This can't be done from iPhone. Use PRBar on
your Mac."). See the design spec, parts P and Q, for the details.
