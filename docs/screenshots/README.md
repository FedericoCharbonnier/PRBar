# PRBar screenshots

Rendered by PRBar's snapshot mode for presentations. **All data is fictional**: the accounts (`dev-sam`,
`dev-sam-work`), the `acme/*` repos, the people (`lucia-m`, `tomas-r`, `ana-p`), the PRs, reviews, comments,
paths and commits are sample data from `Sources/PRBar/Snapshots/SnapshotFixtures.swift`.

Regenerate with:

```sh
Scripts/snapshots.sh                     # docs/screenshots, light and dark
Scripts/snapshots.sh /tmp/shots dark     # another folder, one appearance
```

The script builds `build/PRBar.app` (without installing it) and runs
`PRBar --snapshots <dir> --appearance light|dark|both`. In that mode nothing real starts: no refresh, no
`gh`/`git`/`claude`, no Slack, no notifications, no worktree cleanup, and nothing is written outside `<dir>`.

Every screen comes in `-light` and `-dark`, at 2x:

| File | What it shows |
| --- | --- |
| `menubar-icon` | The menu bar icon with a badge of 5, on a menu-bar-like strip |
| `menubar-icon-update` | The same icon with the blue "update available" dot at the glyph's top-right corner |
| `popover` | The popover's To Review tab (selected; My PRs shows "3 •"): To Review (one idle, one "Reviewing…" on devbox), Updated Since My Review (the violet "Review ready · 4" pill, "Ran on this Mac — devbox unreachable"), Other collapsed. Under the tabs, the Claude strip (1 running · 1 ready); at the bottom the resources line (CPU, RAM, worktrees, this month's Claude cost); Open PRBar ⌘0, Settings… ⌘, and Quit PRBar ⌘Q are in the ⚙︎ menu at the top right |
| `popover-update` | The To Review tab with PRBar 1.3.0 offered: the update notice with its Update button in the footer |
| `popover-mine` | The My PRs tab: With Feedback (Changes requested, failing CI with **Fix CI** next to Respond), Ready to Merge (one ready, one blocked) and Waiting for Review (collapsed) |
| `popover-mine-ci-fix` | The My PRs tab while a Fix CI waits to be pushed: the row's violet "CI fix ready to push" pill |
| `popover-empty` | The To Review tab with nothing to review ("Nothing to review 🎉"), Other collapsed |
| `popover-empty-mine` | The My PRs tab with nothing to do ("No PRs of yours need anything"), Waiting for Review collapsed |
| `main-list` | The main window on To Review: sidebar (Pull Requests, Claude tasks, History, Activity; update, iPhone and Settings at the bottom), the PR list grouped by section (only sections with PRs, each with a disclosure chevron and the popover's captions, e.g. Other "drafts and nothing to do"), and the selected PR with where its review ran on its own line |
| `main-search` | The list filtered by the toolbar search: only sections with results, expanded |
| `main-empty` | The main window with nothing to review |
| `main-loading` | The main window before the first refresh |
| `main-review` | A PR's Review tab: Claude's summary, kept findings (one expanded for editing), discarded ones with reasons, a general comment |
| `main-review-chat` | The Review tab with the chat inspector open (340 pt, headed "Chat · on devbox"), including a "Save as rule" card |
| `main-details` | A PR's Details tab: description, reviews, checks, conversations and files |
| `main-merge` | Your PR's Merge tab: details plus the merge block with the method, "Head 2029172" and "Squash and Merge"; the list rows show their status line (Changes requested, merge blockers) |
| `main-respond-choose` | The Respond tab: choosing what to do with each comment (fix, reply, fix + reply) |
| `main-respond-focus` | Respond in focus mode with the chat beside it |
| `main-fix-ci-ready` | The Fix CI tab ready to push: failing checks, Claude's summary, the commit and the diff |
| `main-history` | History: reviews, responses and a Fix CI grouped by day, with the All · Reviews · Responses · Merges segmented filter and each record's Claude cost |
| `main-history-ci-fix` | History with the Fix CI record selected: time, tokens, estimated cost, the commit and the diff stat |
| `main-activity` | Activity: CPU, RAM, Disk and Claude tiles, what's running now (with Stop), Claude usage and disk by category |
| `main-update-sheet` | The update sheet over the main window |
| `pr-window` | A PR opened in its own window (⇧⌘O) on the Merge tab (the header doesn't repeat the `repo#N` of the title bar) |
| `settings-general` (with the Disk warning), `settings-claude`, `settings-instructions`, `settings-accounts`, `settings-repos`, `settings-slack` | Each Settings tab, configured. `settings-claude` is the Review page of Settings › Claude (Review · Respond · Model & Chat · Run On · Prompts); `settings-repos` shows "Run Claude on: Default (devbox)" and the warning "Last job ran on this Mac — devbox was unreachable (fallback)." |
| `settings-claude-run-on` | Settings › Claude › Run On: Default devbox, the table with This Mac and devbox (folder, "✓ Linux · claude 2.1.318 · logged in · 5 min ago", fallback on), Add SSH Host…, Test Connection, Remove |
| `settings-iphone` | Settings › iPhone connected to the relay: Open PRBar on your phone with the QR to the web app (`https://prbar.fcharbonnier.duckdns.org/`); "Connected to prbar.fcharbonnier.duckdns.org · 1 iPhone online", Pair iPhone…; two iPhones (one online with Face ID required, one last seen 5 min ago without it), keep awake and mailbox on |
| `settings-iphone-off` | iPhone access off (no "Open PRBar on your phone" QR until it is on) |
| `iphone-pair-qr`, `iphone-pair-code`, `iphone-enable` | Pair iPhone… with the pairing QR and its countdown; the 6-digit code with Codes Match; the Enable sheet (relay and enrollment token) |
| `notification` | **An illustration** of the "Review Ready" notification, not a capture of the real macOS banner |

Notes on fidelity (the windows are drawn offscreen and never shown):

- Windows include their title bar and toolbar. Effects the window server draws live (blur, Liquid Glass) are
  replaced by plain fills: the sidebar is a flat panel and the toolbar platters have no glass.
- Switches and checkboxes keep the gray "inactive window" tint even when on. Segmented controls (History's filter,
  Settings › Claude's pages) don't show their selected segment.
- In the dark Settings snapshots no toolbar tab is highlighted (the window title names the tab).
- Some windows are taller than their default size so the whole screen fits without scrolling.
- Nothing connects to a host: devbox's last check and where each job ran are sample data.
- Claude's costs are fictional sample numbers (the ledger and the running task's cost are filled in directly).
