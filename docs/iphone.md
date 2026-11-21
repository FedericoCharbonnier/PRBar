# PRBar on your phone

PRBar on your phone is a remote control for PRBar on your Mac. It shows your PRs and their status, receives the same
notifications, and lets you review, respond, fix CI, chat with Claude and merge. **The Mac does all the work**
(GitHub, Claude, Slack, push, merge); the phone sends commands and shows what the Mac sends back.

It's a **web app** (PWA) that you add to your Home Screen: there's nothing to install from the App Store, no Apple
Developer account and no Xcode. Your relay server (`relay/`) serves it at `https://<relay host>/`, and the same relay
carries the messages between the Mac and the phone. The Mac connects *out* to the relay, so no port is opened on the
Mac, and everything between the Mac and the phone is end-to-end encrypted.

Requirements: an iPhone with **iOS 16.4 or newer** (the first version with notifications for Home Screen web apps),
used from Safari. It also works on Android with Chrome and in desktop browsers, but the iPhone is what it's made and
tested for.

## 1. Set up the relay and the Mac

`Scripts/iphone-setup.sh` does this for you. It asks before each step that touches something outside the repo and can
be run again at any time; without arguments it only shows what's done and what's left (relay health, push on, web app
served, PRBar installed, phone access on):

```
PRBAR_RELAY_SERVER=root@your-server Scripts/iphone-setup.sh --deploy-relay   # relay + web app; makes the push key the first time
PRBAR_RELAY_SERVER=root@your-server Scripts/iphone-setup.sh --install-mac    # this checkout's PRBar + phone access on
```

`PRBAR_RELAY_SERVER` is the ssh destination of the server that runs the relay; it's only read from the environment.
`PRBAR_RELAY_HOST` changes the relay's public host (default `prbar.fcharbonnier.duckdns.org`).

Without the script, turn on phone access in Settings › iPhone › **Allow iPhone remote control**, or:

```
prbar remote enable --relay prbar.fcharbonnier.duckdns.org
```

The first time, PRBar asks for the relay's **enrollment token** (`RELAY_ENROLL_TOKEN` in the relay's `.env`). It's
used once to create this Mac's account on the relay and is never stored (the script pipes it from the server straight
into `prbar`, without showing it). Turning access off and on again (`prbar remote disable` / `enable`) doesn't ask for
it. `prbar remote status` shows the connection and the web app's address.

Options:

- **Keep this Mac awake while charging** (`prbar remote keep-awake on`): while phone access is on and the Mac is on
  power, PRBar keeps it from idle sleep so the phone can reach it. The display still sleeps. With the lid closed and
  no external display, macOS sleeps anyway. `pmset -g assertions | grep PRBar` shows it.
- **Keep the last state on the relay for 7 days** (`prbar remote mailbox on|off`, on by default): the Mac leaves its
  latest PR list, encrypted for each paired phone, so the phone shows something recent while the Mac sleeps ("Last
  updated" is when the Mac wrote it). The phone never shows a copy older than 7 days or older than what it already
  has. Turning it off replaces it with an empty state (on the next connection if the Mac is offline).

## 2. Install the web app on the iPhone

1. On the Mac, Settings › iPhone shows **Open PRBar on your phone** with a QR code (only while phone access is on).
   Scan it with the iPhone's Camera; it opens `https://<relay host>/` in Safari.
2. In Safari: **Share › Add to Home Screen**.
3. Open PRBar **from the new icon**. iOS keeps the Home Screen app's data apart from Safari's, so everything (keys,
   pairing, notifications) lives in the installed app. Opened in Safari, the page only shows how to add it to the Home
   Screen and never creates keys.

On Android, Chrome offers an **Install** button instead.

## 3. Pair

On the Mac, Settings › iPhone › **Pair iPhone…** (or `prbar remote pair` in a terminal) shows a QR code. In the
installed app, give the phone a name, tap **Scan QR on your Mac** and scan it (or tap **Paste code** and paste the text
`prbar remote pair` prints), then tap **Pair**. Both screens show the same **6-digit code**: if they match, confirm on
the Mac (**Codes Match**, or answer `y`). The QR works once and expires in 5 minutes. If the codes don't match, tap
**Codes Don't Match** and cancel on the Mac: someone else may have scanned your QR. Scanning the pairing QR with the
Camera app instead only opens the page; it's not used outside the installed app.

When you tap **Pair**, iOS asks to save a **passkey** for PRBar (on the iPhone, in iCloud Keychain). That passkey is
how Face ID works here (next section). If you cancel it, or the browser has no passkeys, pairing still works but
everything that needs Face ID stays blocked ("Face ID isn't set up on this device. Pair it again.").

## Face ID

By default, **merge, push, approve and running the tests need Face ID** on the phone. Each of those requests is signed
with the passkey after Face ID (or the iPhone's passcode, if iOS offers it), and the **Mac checks the signature**: it
has to come from this phone's passkey, for this relay's address, for this exact request, within the last minute, with
the user verified. The relay can't fake it.

You can turn the requirement off per phone (Settings › iPhone on the Mac,
`prbar remote devices --require-face-id <phone> off`, or on the phone itself, which asks for Face ID to turn it off).
The phone can ask Claude to implement fixes and edit them in the chat without Face ID, but that never runs anything:
the repo's test command (and a push, which runs your git hooks) only runs on the Mac with a Face ID proof from that
phone. A change of this setting on the Mac reaches a connected phone right away.

Passkeys sync through iCloud Keychain, so another of your Apple devices could produce the same signature, but it would
also need this phone's session keys, which never leave it.

## Notifications

After pairing, tap the button to allow notifications (iOS only asks after a tap). They're the Mac's own (same rules,
same switches: the phone's Settings change the Mac's), sent through the relay and the browser's push service (Apple's
for iPhone) **encrypted for this phone**: the relay and the push service only see an opaque blob. The app decrypts the
real title and text before showing them, and drops anything older than a day or already shown (a relay sending an old
push again). If it can't decrypt one (the phone was revoked, or its data was wiped) you see "PRBar — New activity on
your Mac". Tapping a notification opens the PR on the right screen; there are no buttons on the notification itself,
and anything that needs Face ID asks for it in the app. The app icon's badge is the Mac's.

Notifications arrive while the phone is locked and while PRBar is closed. If you remove PRBar from the Home Screen or
turn its notifications off in iOS Settings, they stop.

## 4. Revoke, unpair, reset

- **Revoke** a phone from the Mac: Settings › iPhone › Revoke…, or `prbar remote revoke <phone>`. The Mac forgets its
  keys right away, so it can't connect again even if the relay misbehaves. If the Mac is offline (or phone access is
  off), the relay is told the next time the Mac connects: on every connection the Mac removes from the relay any phone
  it doesn't have, which also deletes its mailbox copy and its push subscription.
- **Unpair** from the phone: Settings › **Unpair This Mac**. The phone deletes its keys and tells the Mac.
- **Reset iPhone Access…** (`prbar remote reset`): new Mac keys and a new relay account, and every phone is removed.
  Use it if the relay or the Mac may be compromised. You'll need the enrollment token again. The relay can't delete
  accounts, so PRBar keeps the old account's relay key until it has removed every phone of that account from the relay
  (right away, or at the next start if the relay can't be reached), then forgets it.
- The passkey stays in iCloud Keychain after unpairing; you can delete it in the Passwords app (or Settings ›
  Passwords). Pairing again creates a new one.

### When iOS wipes the app's data

iOS may delete a web app's stored data if you don't open it for a few weeks, and clearing Safari's data (Settings ›
Apps › Safari › Clear History and Website Data) deletes it too. The app then shows "This device lost its pairing.
Pair it again from your Mac." Revoke the old entry on the Mac and pair again (section 3). Nothing on the Mac is lost.

## What the server can and can't see

The relay is yours, but it's worth knowing what a compromised server could do.

| The relay (and anyone who controls the server) can | It can't |
|---|---|
| See account, device and pairing ids, when each side is online, message sizes (padded) and timing, IP addresses, and the phones' push subscriptions | Read anything carried between the Mac and the phone: PRs, code, comments, chat, the Mac's state and notifications are encrypted end to end (Noise for sessions, HPKE for pushes and the mailbox) |
| Drop or delay messages, or make pairing fail (a temporary outage) | Send commands to the Mac: it doesn't have the phones' keys, and old commands expire (2 minutes, or the phone's own deadline) |
| Send an empty push ("New activity on your Mac") | Show a fake notification: the phone only shows what the Mac encrypted |
| Refuse to forget a revoked phone | Let a revoked phone back in: the Mac enforces revocation |
| — | Pair its own phone: it needs the secret in the QR and your OK on the 6-digit code |

**Accepted risk:** the same server serves the web app's code. Whoever controls it could change that code, and a
changed page running on your phone could read what you see in the app and act with your session, and ask you for
Face ID for something other than what it shows. The encryption still protects you against everything else: a
misconfigured proxy, the server's logs and backups, and the push services. This is the trade-off for not needing an
App Store app; keep the server's access (ssh keys, the account that hosts it) tight. The page is served with a strict
Content Security Policy (only its own code, no third-party scripts).

Frames are **not compressed** before encryption: a PR list mixes private data with titles anyone can write, and
compressed sizes would leak it. What the phone receives never includes local paths (your home folder, clones, worktree
and temporary folders, anywhere in a message, test output or chat), tool paths or SSH hosts from the Mac, terminal
escape codes or invisible bidi characters, and tokens that show up in test output are masked.

The Mac also caps what one phone can ask for (8 requests at a time, 30 in a burst then 5 per second, and a few new
secure sessions per minute), so a stolen phone or a misbehaving relay can't flood it.

What the phone can do is limited on purpose: it can read and act on PRs, but it can't change accounts, repos, tool
paths, SSH hosts, Slack, rules, prompts, updates or phone access itself ("This can't be done from iPhone. Use PRBar on
your Mac."). See the design specs for the details: `docs/superpowers/specs/2026-11-20-prbar-iphone-design.md` (parts P
and Q: relay, protocol, encryption) and `docs/superpowers/specs/2026-11-21-prbar-web-app-design.md` (part W: the web
app, passkeys, Web Push).
