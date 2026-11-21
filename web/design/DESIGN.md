# PRBar for iPhone — design digest

Source: the user's Claude Design project "PRBar iOS" (`PRBar iOS.dc.html` + `Screen.dc.html` and its imports). This digest is the
reference implementers follow. Screen ids match `Screen.dc.html` (`group:variant`). Device: iPhone 16 Pro, 393×852 pt.
Everything uses system controls, SF Symbols and SF Pro with Dynamic Type; minimum 44 pt touch targets even when a capsule
is drawn 30–32 pt tall. At accessibility text sizes the PR row title takes as many lines as it needs and the row's button
moves to its own line. All sample data below is fictional and is only for previews/snapshots.

## Tokens

| Token | Light | Dark | Use |
|---|---|---|---|
| bg | #F2F2F7 | #000000 | screen background (grouped) |
| bg2 | #FFFFFF | #1C1C1E | cards / grouped rows; Chat and Pairing screen background |
| bg3 | #E9E9EB | #2C2C2E | Claude chat bubble |
| sheet | #F2F2F7 | #1C1C1E | sheet background |
| fg / fg2 / fg3 | #000 / #5E5E63 / #8A8A8E | #FFF / #AEAEB2 / #7C7C80 | label / secondary / tertiary |
| sep | rgba(60,60,67,.18) | rgba(84,84,88,.55) | separators (0.5 pt) |
| fill / fill2 | rgba(118,118,128,.12/.22) | rgba(118,118,128,.24/.36) | neutral fills, switch off track |
| accent | #2D4EFF | #3B5BFF | primary buttons, switch on |
| accentfg / accentbg | #2D4EFF / rgba(45,78,255,.10) | #8FA3FF / rgba(80,110,255,.22) | tinted buttons |
| green / greenbg | #12793A / #E1F3E6 | #30D158 / rgba(48,209,88,.18) | approved, passing, additions |
| orange / orangebg | #A65300 / #FCEBD8 | #FF9F0A / rgba(255,159,10,.18) | changes requested, Medium |
| red / redbg | #C42B1F / #FBE5E3 | #FF6961 / rgba(255,69,58,.20) | failures, High, Stop, deletions |
| violet / violetbg | #6B2FB3 / #EFE6FB | #D2B3FF / rgba(150,90,230,.28) | "Claude working", summary card |
| blue / bluebg | #1F5FBF / #E3EDFB | #7FB0FF / rgba(80,140,255,.20) | Low severity |
| codebg | #F5F6F8 | #121214 | code/log blocks |
| addbg / delbg | rgba(40,170,80,.13) / rgba(230,60,50,.11) | rgba(48,209,88,.16) / rgba(255,69,58,.16) | diff lines |
| glass | Liquid Glass material (`.glassEffect()`) on iOS 26 | | nav buttons, tab bar, bottom action bars, chat input |
| hud | rgba(246,246,248,.88) | rgba(38,38,42,.90) | menus, Face ID HUD (use system) |
| connected dot | #30C559 | #30C559 | Mac connected; offline uses fg3 |
| badge | #E5372B | | tab badge |
| app tile | #2D4EFF | | app glyph tile (Welcome 100 pt r23, Settings 40 pt r11, notifications 38 pt r9) |

Mono font: SF Mono (`.monospaced()`). Avatar colors are per person (deterministic from login), white initials.
Corner radii: cards 22–24, capsules = height/2, code blocks 12–18, sheet top 38.

## Navigation
Floating Liquid Glass tab bar (system `TabView`, iOS 26 style), 4 tabs:
`To Review` (tray, red badge = count of items needing action) · `My PRs` (app glyph `prbar` as custom symbol) · `Activity` (gauge) · `Settings` (gearshape).
Selected tab: accentfg tint on a fill capsule. Detail screens push from rows; nav bar uses glass circular buttons
(44 pt): Back (chevron.left) on the left, contextual buttons on the right.

## Components

**Mac pill (top of Home and Activity, leading):** glass capsule 44 pt: 32 pt circle (fill) with `laptopcomputer`, then
"Diego's MacBook Pro" (14 semibold) over a 7 pt dot + "Connected · updated just now" (12, fg2). Offline: grey dot,
"Offline · last seen 8:12 AM". VoiceOver: "<Mac>, connected, updated just now". Home also has a trailing glass circle
button "Filter" (`line.3.horizontal.decrease`); the web app leaves it out until it has a defined behaviour. The pill has
no action of its own (not a button).

**Section header:** title 17 semibold + count 15 fg2 + trailing chevron (down when open, right when collapsed); the whole
header toggles; VO "<title>, <n>, expanded/collapsed". Rows are grouped in a bg2 card r24 with 0.5 pt separators inset 62.

**PR row** (`PRRow`), padding 12×16, gap 12:
- Leading 34 pt circle: author avatar (initials) on To Review; on My PRs a state icon on a tinted circle
  (text.bubble/orange for feedback, checkmark/green ready, xmark/red CI failing).
- Title 15 semibold, max 2 lines; trailing age (13, fg2) on the title baseline.
- Meta line 13 fg2: `web-app#491 · develop` (single line, tail truncation).
- Optional status line 13 medium with SF Symbol in its color: violet `terminal` "2 agents · on devbox";
  orange `exclamationmark.triangle.fill` "Changes requested · 2 comments"; green `checkmark.circle.fill`
  "Approved by 2 · checks passing"; red `xmark.octagon.fill` "2 checks failed".
- Bottom line: mono 12 `+214` (green) `−38` (red), trailing action capsule (30 pt, 14 semibold):
  Review (accentbg/accentfg) · Reviewing… (violetbg/violet + small spinner) · "4 comments" (greenbg/green +
  checkmark.circle.fill) · Respond (accentbg) · Merge… (accent fill, white) · Fix CI (redbg/red).
- Disabled/offline: everything fg2/fg3, avatar fg3, action capsule fill/fg3, VO "<action>, unavailable".
- Row VO: "<title>, <repo#n>, <age>, <add> additions, <del> deletions".

**Bottom action bar:** pinned 30 pt above bottom over a bg gradient fade (150 pt): secondary glass capsule (54 pt)
+ primary accent capsule (54 pt, white, often with `faceid` glyph when it needs Face ID).

**Face ID HUD:** use the system LocalAuthentication prompt (design shows the standard 156 pt HUD with `faceid` 66 pt + "Face ID").

## Screens

### pair:welcome / pair:scan / pair:paired (01 · first time only)
- welcome (bg2): app tile 100 pt with shadow; "Welcome to PRBar" (34 bold); "Your Mac does the work. Your iPhone is the remote."
  Three features (icon 28 accentfg + title 16 semibold + text 15 fg2): `bolt.fill` "Live from your Mac" — "Reviews, CI and Claude's
  progress as they happen."; `checkmark.circle` "Act from anywhere" — "Review, respond, fix CI and merge with a tap.";
  `lock.shield` "End-to-end encrypted" — "Your iPhone reaches your Mac through a relay that can’t read your data."
  Bottom: accent button 56 pt `qrcode.viewfinder` "Scan QR on your Mac"; caption 13 fg2 "On your Mac, open PRBar › Settings › Pair iPhone."
- scan: full-screen camera; glass xmark "Cancel" top-left; "Scan the QR code" (24 bold, white) + "It's in PRBar › Settings › Pair
  iPhone on your Mac." (16, white 78%); 260 pt viewfinder with rounded white corner brackets (5 pt, r26); bottom glass chip
  `lock.fill` "End-to-end encrypted pairing".
- paired: green 88 pt circle checkmark; "Paired with Diego's MacBook Pro" (28 bold, balanced); "Check that this code matches the
  one on your Mac."; six digit tiles 44×58 r14 fill, mono 28 semibold, extra 14 pt gap after the 3rd digit (VO "Verification code
  4 8 2 9 1 3"); `lock.fill` "Connected through an encrypted relay" (13 fg2). Buttons: accent "Codes Match" (56), red text "Codes Don't Match" (50).

### home (02 · To Review) and home:mine (03 · My PRs)
Mac pill + Filter; large title "To Review" / "My PRs" (34 bold). Pull to refresh. Sections:
- To Review: "To Review" (LM web-app#491 Review; TR api#317 Reviewing… status "2 agents · on devbox"), "Updated Since My Review"
  (AP web-app#482 "4 comments").
- My PRs: "My PRs with Feedback" (#475 Respond), "Ready to Merge" (#322 Merge…), "CI Failing" (#488 Fix CI),
  "Waiting for Review 2" (collapsed).

### home:offline (11)
Same layout; above the sections a bg2 card r24: 76 pt circle (fill, fg2) with `laptopcomputer` 40 + `moon.zzz` 20 badge top-right;
"Diego's MacBook Pro is offline or asleep" (17 semibold); "Last connected today at 8:12 AM. You're seeing cached data, and actions
are off until your Mac is back." (15 fg2); tinted button 44 pt `arrow.clockwise` "Try Again". Section titles fg2; rows disabled.

### review, review:menu, review:faceid, review:posted (04)
- Nav: Back; trailing glass group with `bubble.left.and.bubble.right` (Chat with Claude) and `ellipsis` (More).
- Header: mono 13 fg2 "acme/api #317"; title 24 bold; author line: 22 pt avatar + "Tomás Ruiz · 12 min · +46 −12"; branch chips
  (mono 12 on fill r6) `fix/session-expiry` → `main` "· 5 files".
- Claude's summary card (violetbg r22): `sparkles` "Claude's summary" + trailing "2 agents · 3m 40s" (violet 13 semibold); body 15.
- "Findings" (20 bold) + trailing "3 of 4 included". Finding cards (bg2 r22): severity pill (High red / Medium orange / Low blue,
  dot + label, 22 pt), mono file:line (truncating), trailing system Toggle (VO "Include finding N, <sev>"); text 15 (fg2 when
  excluded); "Edit comment" (`pencil`, accentfg, 40 pt).
- Bottom bar: glass decision picker (flex) with colored icon + label + `chevron.up.chevron.down` (VO "Review decision: Approve",
  opens a menu) and accent "Post" with `faceid` (VO "Post review, requires Face ID").
- menu: system menu with checkmark on the selected: Comment (`text.bubble`), Request Changes (`exclamationmark.triangle`, orange),
  Approve (`checkmark.circle`, green).
- faceid: system biometric prompt over the screen.
- posted: green 92 pt circle checkmark; "Review posted" (28 bold); "Approved api#317 with 3 comments."; inset grouped card rows:
  Decision → "Approve" (green semibold), Inline comments → 3, Posted from → "Diego's MacBook Pro". Buttons: tinted "View on GitHub"
  `arrow.up.right`, accent "Done".

### edit (05 · sheet over review)
Large sheet (grabber). Header: glass "Discard" (red) · "Edit Comment" / "Finding 1 of 4" (13 fg2) · accent "Save". Severity pill +
mono file:line; code excerpt (codebg r18, mono 12, line numbers fg3, the commented line highlighted redbg); "COMMENT" caption;
multiline editor (bg2 r20, min 250 pt, 17) with Markdown; footer "Markdown supported · posts on line 88".

### respond, respond:fixci, respond:diff (06)
- Nav: Back · title ("Respond" / "Fix CI" / "Changes") · Chat button.
- Header: mono repo "acme/web-app #475"; title 24 bold; status line (orange `exclamationmark.triangle.fill` "Changes requested by
  Laura Méndez" / red `xmark.octagon.fill` "2 checks failed" / green "2 files · tests passing").
- respond: "Feedback" (20 bold) + "2 of 2 selected"; comment cards bg2 r22 with leading 26 pt round checkbox (accent, checkmark),
  20 pt avatar + name + "· 2h", mono file:line, text 15.
- fixci: "Failed checks" + "2 of 9"; per check card: `xmark.octagon.fill` red + name 15 semibold + duration; log excerpt (codebg r12,
  mono 11.5, line height 1.6; red for failure lines, fg2 for detail). After progress: list of changed files (`doc.text`, mono path,
  +/−, chevron) → opens diff.
- Progress card (bg2 r22): header `sparkles` "Claude is fixing 2 comments" (violet) / "Fixed · tests passing" (green) + elapsed;
  stage rows 44 pt: Analyzing / Implementing / Running tests; icon = spinner (current, violet) / `checkmark.circle.fill` green (done)
  / `circle.dashed` fg3 (pending); label 16 (semibold when current) + time (tabular); optional mono sub-line ("Editing
  src/reports/export.ts", "2 failures in 2 files", "142 passed").
- diff: file chips (selected = fg fill with bg text, "export.ts +9 −4"; others bg2 with colored counts); diff card: header `doc.text`
  path + counts; lines mono 11.5, line height 1.85, gutter number fg3, sign column (+ green, − red, hunk header accentbg/accentfg),
  add/del backgrounds; horizontal scroll (VO "Diff, scrolls horizontally"). Then "Reply to Laura Méndez" card with the drafted reply.
- Bottom bar: secondary "Stop" (red, `stop.fill`) while running / "Undo" (`arrow.uturn.backward`) when done; primary "Push & Reply"
  (Respond) or "Push" (Fix CI) with `faceid`, disabled (fill/fg3) while running.

### merge, merge:faceid, merge:merged (07)
- Nav: Back (Close `xmark` on merged) · trailing Chat ("Ask Claude about this PR").
- Header: "acme/api #322"; title; branch chips `feat/idempotent-retries` → `main` + "+96 −14".
- Description card (bg2 r22, 15). Summary card rows (46 pt): reviewer avatars "Laura Méndez — ✓ Approved", "Tomás Ruiz — ✓ Approved"
  (green semibold); `checklist` Checks "✓ 9 passing"; `text.bubble` Unresolved conversations "None"; `doc.text` Files "4 changed" + chevron.
- "MERGE METHOD" caption; segmented control Squash / Merge / Rebase; note under it: Squash "3 commits become one commit on main." /
  Merge "Adds a merge commit and keeps all 3 commits." / Rebase "Replays the 3 commits on top of main."
- Full-width accent 58 pt "Merge" with `faceid` (VO "Merge, requires Face ID").
- merged: accent 96 pt circle `arrow.triangle.merge`; "Merged" (30 bold); "api#322 was squashed into main."; chip `number`
  "Posted in #web-reviews"; tinted "View on GitHub", accent "Done".

### chat:review, chat:respond, chat:merge (08)
bg2 background. Nav: Back · centered `sparkles`(violet) "Claude" + subtitle ("api#317 · Review" / "web-app#475 · Respond" /
"api#322 · Merge"). Timestamp "Today 9:38 AM". Bubbles 17 pt, r20: mine accent/white trailing (max 270), Claude bg3 leading (max 290);
10 pt gap when the speaker changes. Action card (Claude made a change): bg2 with 1 pt sep stroke, 34 pt violet circle `pencil`,
title 15 semibold ("Changed finding #3" / "Edited fix in src/reports/export.ts") + detail 13 fg2 ("Severity Medium → Low" /
"+1 −1 · tests re-running"), trailing tinted "Undo". Typing indicator (three dots in a bg3 capsule) + "Claude is typing".
Merge chat is read-only: top notice (fill r18) `lock.fill` "Read-only. Claude can answer questions about this PR but won't change it."
Input: glass capsule 48 pt, placeholder "Message Claude" / "Ask about this PR", round send button `arrow.up` (disabled = fill/fg3).

### activity (09)
Mac pill; "Activity" large title. Three stat tiles (bg2 r20): `cpu` CPU "38%" "12 cores" (green bar); `memorychip` Memory "11.2 GB"
"of 16 GB" (orange bar 70%); `internaldrive` Disk "212 GB" "free of 512" (accentfg bar). "Running 2": task rows with violet
spinner circle, title ("Reviewing api#317", "Fixing CI on web-app#488") and sub ("2 agents · 4:12 · ~$0.38", "Running tests ·
2:03 · ~$0.21"), red tinted "Stop" (`stop.fill`). "Claude this month": "$48.20" (34 bold) "estimated · November"; stacked bar
(violet reviews / accentfg fixes / fg3 chat); legend rows: Reviews 31 $29.10, Fixes 12 $14.60, Chat 46 msgs $4.50.

### settings (10)
Large title "Settings". Card: Mac tile (accent 40 pt r11 `laptopcomputer`), "Diego's MacBook Pro", dot + "Connected · end-to-end
encrypted"; red row "Unpair This Mac". NOTIFICATIONS toggles: Review ready, New PR to review, Changes requested on my PRs, Ready to
merge, CI failed on my PRs. SECURITY: "Require Face ID for merge, push and approve" (on). CLAUDE: Repositories (3 ›), Claude rules (5 ›).

### lock (notifications)
Lock-screen notification style (app tile 38 pt r9 with glyph): "Review ready · api#317" — "4 comments to choose from" (now);
"Changes requested on web-app#475" — "Laura Méndez" (4m ago); "Ready to merge · api#322" — "Approved by 2, checks passing" (12m ago);
"CI failed · web-app#488" — "2 checks" (20m ago).

## Flows shown
1. Lock notification → review → edit → review:menu (Approve) → review:faceid → review:posted.
2. home:mine → merge → merge:faceid → merge:merged.
