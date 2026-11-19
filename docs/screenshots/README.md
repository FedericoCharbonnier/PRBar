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
| `popover` | The popover: To Review (one idle, one "Reviewing…"), Updated Since My Review (ready, 4 comments), My PRs with Feedback (Changes requested, Respond), Other collapsed |
| `popover-empty` | The "All Caught Up" state |
| `review-window` | The Review window: Claude's summary, 3 kept findings (one expanded for editing), 2 discarded with reasons, a general comment, comments posted in Spanish |
| `review-published` | The Review window after posting |
| `respond-choose` | Respond: choosing what to do with 3 comments (fix, reply, fix + reply) |
| `respond-ready-to-push` | Respond: 2 commits, the diff, the `package.json` warning, tests passed, Push and Reply |
| `history` | The History window with 6 reviews and responses, one selected |
| `settings-general`, `settings-claude`, `settings-accounts`, `settings-repos`, `settings-slack` | Each Settings tab, configured |
| `notification` | **An illustration** of the "Review Ready" notification, not a capture of the real macOS banner |

Notes on fidelity (the windows are drawn offscreen and never shown):

- Windows include their title bar and toolbar. Effects the window server draws live (blur, Liquid Glass) are
  replaced by plain fills: the History sidebar is a flat rounded panel and the toolbar platters have no glass.
- Switches and checkboxes keep the gray "inactive window" tint even when on.
- In the dark Settings snapshots no toolbar tab is highlighted (the window title names the tab).
- Some windows are taller than their default size so the whole screen fits without scrolling.
