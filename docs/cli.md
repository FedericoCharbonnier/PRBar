# prbar — PRBar from the terminal

`prbar` controls PRBar.app: everything you can do in the menu bar, the Review, Respond and History windows and
Settings, you can do from the terminal. The app does the work (it’s the only one that writes the config, runs Claude
and posts); `prbar` asks it over a private socket.

## Install

`Scripts/bundle.sh --install` installs PRBar.app in `~/Applications` and links the CLI at `~/.local/bin/prbar`
(or `$PRBAR_BIN_DIR/prbar`). If that folder isn’t in your `PATH`, add `export PATH="$HOME/.local/bin:$PATH"` to
`~/.zshrc`. The link points inside the app, so updates (`prbar update`) update the CLI too.

Shell completion: `prbar completion zsh > ~/.zfunc/_prbar` (also `bash` and `fish`).

If PRBar isn’t running, `prbar` opens it in the background and waits up to 10 seconds. `prbar doctor`, `prbar version`,
`prbar completion`, `prbar app start`, `prbar app logs`, `prbar repo open` and `prbar notify system-settings` work
without the app.

## PRs

`owner/repo#N`, `repo#N` (when only one configured repo has that name) or the PR’s URL. The PR has to be in PRBar’s
list (`prbar prs`).

Findings are numbered like in the Review window (`#1`, `#2`…, including the ones discarded by the filter and the ones
the chat added); comments in Respond are numbered like in the Respond window. You can also use their ids (`f2`,
`thread:…`).

## Commands

`prbar help <command>` shows a command’s help, and a group’s subcommands (`prbar help review`; `prbar review --help`
shows the help of `review start`, the group’s default subcommand).

| Command | Does |
|---|---|
| `prbar status [--json]` | What the menu bar shows: counts, running jobs, issues |
| `prbar prs [--list to-review\|updated\|mine\|ready-to-merge\|other] [--account L]` | The PRs |
| `prbar refresh` | Refresh now |
| `prbar open <pr> [--review\|--respond\|--posted\|--worktree] [--copy]` | Open the PR, its window, the posted review or the worktree; `--copy` copies the link |
| `prbar history [--repo R] [--kind review\|respond] [--search Q] [--limit N]` | History |
| `prbar history show <id> [--open-log\|--reveal-log]` | One record (id or its first 4+ characters), with its chat |
| `prbar history reopen <id>` | Open to Post |
| `prbar app start\|quit\|settings [tab]\|history [id]` | The app (tabs: `general`, `claude`, `instructions`, `accounts`, `repos`, `slack`) |
| `prbar app logs [--app\|--slack\|--update] [--path]` | Open a log (PRBar’s, the Slack connector’s, the last update’s) |
| `prbar doctor [--json]` | Check the installation |
| `prbar version [--json]` | prbar’s and the app’s versions (About PRBar) |
| `prbar completion zsh\|bash\|fish` | Shell completion script |
| `prbar review <pr> [--wait]` | Review with Claude |
| `prbar review show <pr> [--full]` | Findings, selection, texts |
| `prbar review edit <pr> <n> [--title T] [--body B\|--body-file F\|--editor]` | Edit a finding |
| `prbar review include\|exclude <pr> <n>… \| --all` | Choose what to post (Select All / None) |
| `prbar review comment <pr> --text T\|--editor` | General comment |
| `prbar review publish <pr> --comment\|--request-changes\|--approve [--only 1,3] [--no-comments] [--all-in-body] [--yes]` | Post |
| `prbar review cancel\|dismiss <pr>` | Cancel / dismiss |
| `prbar respond <pr> [--wait]` | Analyze the feedback on your PR |
| `prbar respond show <pr> [--full]` | Analysis, choices, fixes |
| `prbar respond select <pr> <n>… --implement\|--reply-only\|--skip [--no-reply] [--reply T] [--plan T]`, `--reset` | Choose |
| `prbar respond implement\|test <pr> [--wait]` | Implement the fixes / run the tests |
| `prbar respond diff <pr> [--stat]` | The diff that would be pushed |
| `prbar respond push <pr> [--wait] [--yes]` | Push and reply |
| `prbar respond reply-only <pr> [--wait] [--yes]` | Only replies |
| `prbar respond cancel\|dismiss <pr>` | Cancel / dismiss |
| `prbar chat <pr> ["message"]` | Chat with Claude about the review or the Respond analysis; without a message in a terminal, an interactive chat (`/undo`, `/show`, `/stop`, `/quit`); without a terminal the message comes from stdin |
| `prbar chat <pr> --undo [--yes]\|--show\|--stop` | Undo Claude’s last change (asks if it would discard your manual edits), print the conversation, stop the answer |
| `prbar merge <pr> [--method squash\|merge\|rebase] [--yes]` | Merge a PR of yours that’s Ready to Merge (the repo’s method unless `--method`) |
| `prbar merge <pr> --dismiss` | Dismiss the row’s merge error |
| `prbar config show`, `prbar config set refresh-interval 1\|2\|5\|10`, `… launch-at-login on\|off`, `… confirm-merge on\|off` | General |
| `prbar account list\|reload`, `prbar account enable\|disable <login>` | Accounts |
| `prbar repo list\|available\|add\|remove\|branches\|open`, `prbar repo set <repo> [--path P\|none] [--worktrees P\|default] [--test-command C] [--branches a,b] [--add-branch b] [--remove-branch b] [--channel #name\|ID\|none] [--merge-method squash\|merge\|rebase\|default]` | Repos |
| `prbar follow list [repo]`, `prbar follow add\|remove <repo> <users…>`, `prbar follow suggestions <repo>` | People to follow |
| `prbar notify list\|enable\|disable\|system-settings`, `prbar notify set <kind> on\|off` | Notifications (`new-to-review`, `reviewed-updated`, `my-feedback`, `review-finished`, `approved-or-ci`, `ready-to-merge`) |
| `prbar claude show\|reset\|skills`, `prbar claude set [--review-skill S] [--filter on\|off] [--filter-skill S] [--respond-skill S] [--model M] [--chat on\|off] [--chat-model M\|same]` | Claude |
| `prbar tools list`, `prbar tools set <gh\|git\|claude> <path>`, `prbar tools reset <tool>` | Tool paths |
| `prbar slack show\|enable\|disable\|check\|channels [--reload]` | Slack |
| `prbar slack provider connector\|token`, `prbar slack token set [--stdin]\|clear` | Connection |
| `prbar slack set <announce\|updated\|merged\|react-start\|react-comment\|rounds\|react-approve> on\|off` | Toggles |
| `prbar slack emoji eyes\|comment\|approved <name>`, `prbar slack search-days <7–90>` | Reactions |
| `prbar slack template list\|show\|set\|reset <new-pr\|update\|round\|merged> [text\|--editor]` | Templates (`myPR.merged` is an alias of `merged`) |
| `prbar slack test [--yes]` | Test message to your DM |

## Interactive and scripts

In a terminal (stdin and stdout are a TTY, no `--json`): colored tables (`NO_COLOR` turns color off), and:

- `review publish` without `--only`: a checkbox list of the findings (↑↓ or j/k, space toggles, `a`/`n` all/none,
  `e` edits the comment in `$EDITOR`, ↩ done, `q` cancels), then a confirmation with the review type and the number of
  comments. What you choose is applied in the app, so the window shows the same.
- `respond push` / `reply-only`: the summary and the diff stat, then a confirmation.
- `merge`: a confirmation with the PR and the method (whatever “Confirm before merging” says: the app’s dialog
  doesn’t show up for the CLI).
- `repo remove`, `slack token clear`: a confirmation (only in a terminal).

Without a terminal (a script, a pipe, `--json`) `prbar` never asks. Commands that post, push or approve
(`review publish`, `respond push`, `respond reply-only`, `merge`, `slack test`) **need `--yes`**; without it they exit with 4.

`--wait` prints progress to stderr. Ctrl-C cancels the job in the app too and exits with 130.

## `--json`

```json
{ "schemaVersion": 1, "data": … }
```

Keys are sorted; dates are ISO 8601. `data` is the command’s result: `StatusInfo`, `[PRInfo]`, `ReviewInfo`,
`RespondInfo`, `[HistoryEntryInfo]`, `HistoryDetail`, … (see `Sources/PRBarCore/CommandResults.swift`). Commands with
nothing to return give `{"ok": true}`. New optional keys may appear; renaming or removing one bumps `schemaVersion`.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | OK |
| 1 | Error |
| 2 | Invalid usage |
| 3 | PRBar isn’t available (not running and couldn’t start, or an incompatible version) |
| 4 | Confirmation required (`--yes`) |
| 5 | Not found (PR, repo, account, finding, record) |
| 6 | Invalid state (e.g. posting without a ready review) |
| 10 | `prbar update --check`: there’s a new version |
| 130 | Canceled (Ctrl-C, or you said no) |

## Security

The socket is `~/Library/Application Support/PRBar/prbar.sock`, created with permissions 0600 in a 0700 folder. The
app checks each connection’s user (`getpeereid`) and rejects anyone else; there’s no network. The first message is a
handshake with the protocol version: if `prbar` and the app don’t match, you get
“prbar X can’t talk to PRBar Y — run `prbar update` or reinstall”. Tokens never travel from the app to the CLI;
`prbar slack token set` sends the token you type to the app (never on the command line: it asks without echo or reads
`--stdin`).

## Environment

| Variable | |
|---|---|
| `PRBAR_SOCKET` | Another socket path (development and tests); with it `prbar` never opens the app |
| `PRBAR_BIN_DIR` | Where `bundle.sh --install` puts the `prbar` link |
| `NO_COLOR` | No colors |
| `VISUAL`, `EDITOR` | Editor for `--editor` and `e` in the picker |

## Slack user token

At api.slack.com/apps → Create New App → From scratch → OAuth & Permissions → User Token Scopes: `chat:write`,
`reactions:write`, `channels:history`, `groups:history`, `channels:read`, `groups:read` → Install to Workspace → copy
the User OAuth Token (`xoxp-…`) → `prbar slack token set`.
