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
| `popover` | The popover's To Review tab (selected; My PRs shows "3 •"): To Review (one idle, one "Reviewing…" on devbox), Updated Since My Review (ready, 4 comments, "Ran on this Mac — devbox unreachable"), Other collapsed; at the bottom the resources footer (CPU 12%, RAM 640 MB, Disk 2.3 GB) |
| `popover-update` | The To Review tab with PRBar 1.3.0 offered: the blue "Update" capsule in the header, left of refresh and settings |
| `popover-mine` | The My PRs tab: My PRs with Feedback (Changes requested, failing CI with **Fix CI** next to Respond), Ready to Merge (one ready, one blocked) and Waiting for Review (collapsed) |
| `popover-mine-ci-fix` | The My PRs tab while a Fix CI waits to be pushed: the row's "CI fix ready" pill |
| `popover-empty` | The To Review tab with nothing to review ("Nothing to review 🎉"), Other collapsed |
| `popover-empty-mine` | The My PRs tab with nothing to do ("No PRs of yours need anything"), Waiting for Review collapsed |
| `review-window` | The Review window: Claude's summary, 3 kept findings (one expanded for editing), 2 discarded with reasons, a general comment, comments posted in Spanish; the header says the review ran "on devbox" |
| `review-published` | The Review window after posting, with a rule suggestion from the findings you usually discard |
| `review-chat` | The Review window with the chat open ("on devbox"): a question that narrowed #2 and a finding Claude added (#6) |
| `review-chat-rule` | The Review chat after “from now on…”: Claude’s rule proposal as a card, editable, with Save and Dismiss |
| `respond-choose` | Respond: choosing what to do with 3 comments (fix, reply, fix + reply) |
| `respond-ready-to-push` | Respond: 2 commits, the diff, the `package.json` warning, tests passed, Push and Reply |
| `respond-chat` | Respond, ready to push, with the chat open: a reply drafted for a reviewer and a change to the fixes’ code |
| `ci-fix-ready-to-push` | Fix CI: the failing checks (`test (node 20)`, `typecheck`) with what Claude saw of each, Claude's summary, the commit, the diff and Push (no replies) |
| `merge-window` | The Merge window: description, reviews, checks, unresolved conversations, files, and the bar with the method, the head and "Squash and Merge" |
| `merge-chat` | The Merge window with the read-only chat open ("on devbox", the repo's destination) |
| `activity` | PRBar Activity: CPU, RAM, Disk and Claude ("this month · estimated") tiles, what's running now by task (a review with its `claude` and `git`, its cost so far, with Stop), Claude usage (this month and the recent tasks with time, tokens and estimated cost), disk by category and Clean Up |
| `history` | The History window with reviews, responses and a Fix CI (each with its estimated Claude cost), the published review selected with its Claude line |
| `history-ci-fix` | The History window with the Fix CI entry selected: Claude's time, tokens and estimated cost, the commit and the diff stat |
| `settings-general` (with the Disk warning), `settings-claude`, `settings-instructions`, `settings-accounts`, `settings-repos`, `settings-slack` | Each Settings tab, configured. `settings-claude` includes Run On (after Chat): Default devbox, the table with This Mac and devbox (folder, "✓ Linux · claude 2.1.318 · logged in · 5 min ago", fallback on), Add SSH Host…, Test Connection, Remove; `settings-repos` shows "Run Claude on: Default (devbox)" and the warning "Last job ran on this Mac — devbox was unreachable (fallback)." |
| `settings-iphone` | Settings › iPhone connected to the relay: Open PRBar on your phone with the QR to the web app (`https://prbar.fcharbonnier.duckdns.org/`); "Connected to prbar.fcharbonnier.duckdns.org · 1 iPhone online", Pair iPhone…; two iPhones (one online with Face ID required, one last seen 5 min ago without it), keep awake and mailbox on |
| `settings-iphone-off` | iPhone access off (no "Open PRBar on your phone" QR until it is on) |
| `iphone-pair-qr`, `iphone-pair-code`, `iphone-enable` | Pair iPhone… with the pairing QR and its countdown; the 6-digit code with Codes Match; the Enable sheet (relay and enrollment token) |
| `notification` | **An illustration** of the "Review Ready" notification, not a capture of the real macOS banner |

Notes on fidelity (the windows are drawn offscreen and never shown):

- Windows include their title bar and toolbar. Effects the window server draws live (blur, Liquid Glass) are
  replaced by plain fills: the History sidebar is a flat rounded panel and the toolbar platters have no glass.
- Switches and checkboxes keep the gray "inactive window" tint even when on.
- In the dark Settings snapshots no toolbar tab is highlighted (the window title names the tab).
- Some windows are taller than their default size so the whole screen fits without scrolling.
- Nothing connects to a host: devbox's last check and where each job ran are sample data.
- Claude's costs are fictional sample numbers (the ledger and the running task's cost are filled in directly).
