# PRBar for iPhone

PRBar for iPhone is a remote control for PRBar on your Mac. It shows your PRs and their status, receives the same
notifications, and lets you review, respond, fix CI, chat with Claude and merge. **The Mac does all the work**
(GitHub, Claude, Slack, push, merge); the iPhone sends commands and shows what the Mac sends back.

The Mac and the iPhone talk through a small relay server (yours, see `relay/`). The Mac connects *out* to the relay,
so no port is opened on the Mac, and everything between the Mac and the iPhone is end-to-end encrypted.

## 1. Install the iPhone app

Until there's a public TestFlight, build it with Xcode:

1. Install Xcode 26 (or newer) and add your Apple Developer account (Xcode › Settings › Accounts).
2. Generate the project: `Scripts/ios-generate.sh` (XcodeGen; `ios/project.yml` is the source of truth).
3. Put your team in `ios/Config/Local.xcconfig` (not in git): `DEVELOPMENT_TEAM = ABCDE12345`.
4. Connect the iPhone with a cable once, turn on Developer Mode (Settings › Privacy & Security), open
   `ios/PRBarMobile.xcodeproj`, choose the iPhone and press Run.

(The iOS project arrives with plan 19; until then this section describes how it will be installed.)

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

The first time, PRBar asks for the relay's **enrollment token** (`RELAY_ENROLL_TOKEN` in the relay's `.env`). It's
used once to create this Mac's account on the relay and is never stored. Turning access off and on again
(`prbar remote disable` / `enable`) doesn't ask for it. `prbar remote status` shows the connection.

Options:

- **Keep this Mac awake while charging** (`prbar remote keep-awake on`): while iPhone access is on and the Mac is on
  power, PRBar keeps it from idle sleep so the iPhone can reach it. The display still sleeps. With the lid closed and
  no external display, macOS sleeps anyway. `pmset -g assertions | grep PRBar` shows it.
- **Keep the last state on the relay for 7 days** (`prbar remote mailbox on|off`, on by default): the Mac leaves its
  latest PR list, encrypted for each paired iPhone, so the iPhone shows something recent while the Mac sleeps.
  Turning it off replaces it with an empty state.

## 3. Pair the iPhone

Settings › iPhone › **Pair iPhone…** (or `prbar remote pair` in a terminal) shows a QR code. Scan it with the iPhone's
Camera or with PRBar on the iPhone. Both screens then show the same **6-digit code**: if they match, choose
**Codes Match** (or answer `y`). The QR works once and expires in 5 minutes. If the codes don't match, cancel:
someone else may have scanned your QR.

By default, **merge, push and approve need Face ID** on the iPhone. You can turn it off per iPhone (Settings ›
iPhone, `prbar remote devices --require-face-id <iphone> off`, or on the iPhone itself, which asks for Face ID to turn
it off).

## 4. Revoke or reset

- **Revoke** an iPhone: Settings › iPhone › Revoke…, `prbar remote revoke <iphone>`, or "Unpair this iPhone" on the
  iPhone. The Mac forgets its keys right away, so it can't connect again even if the relay misbehaves.
- **Reset iPhone Access…** (`prbar remote reset`): new Mac keys and a new relay account, and every iPhone is removed.
  Use it if the relay or the Mac may be compromised. You'll need the enrollment token again.

## What the relay can and can't see

| The relay (and anyone who controls the server) can | It can't |
|---|---|
| See account, device and pairing ids, when each side is online, message sizes (padded to 256 bytes) and timing, IP addresses, and the iPhones' push tokens | Read anything: PRs, code, comments, chat, the Mac's state and notifications are encrypted end to end (Noise for sessions, HPKE for pushes and the mailbox) |
| Drop or delay messages, or make pairing fail (a temporary outage) | Send commands to the Mac: it doesn't have the iPhones' keys, and old commands expire (2 minutes, or the iPhone's own deadline) |
| Send an empty push ("New activity on your Mac") | Show a fake notification: the iPhone only shows what the Mac encrypted |
| Refuse to forget a revoked iPhone | Let a revoked iPhone back in: the Mac enforces revocation |
| — | Pair its own phone: it needs the secret in the QR and your OK on the 6-digit code |
| — | Merge, push or approve without Face ID: the Mac checks the Face ID signature |

Frames are **not compressed** before encryption: a PR list mixes private data with titles anyone can write, and
compressed sizes would leak it. What the iPhone receives never includes local paths or tool paths from the Mac.

The Mac also caps what one iPhone can ask for (8 requests at a time, 30 in a burst then 5 per second, and a few new
secure sessions per minute), so a stolen phone or a misbehaving relay can't flood it.

What the iPhone can do is limited on purpose: it can read and act on PRs, but it can't change accounts, repos, tool
paths, SSH hosts, Slack, rules, prompts, updates or iPhone access itself ("This can't be done from iPhone. Use PRBar on
your Mac."). See the design spec, parts P and Q, for the details.
