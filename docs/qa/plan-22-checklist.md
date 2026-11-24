# Plan 22 — Claude session in a terminal: manual checklist

Build and install the branch (`Scripts/bundle.sh`, then open `build/PRBar.app`), with at least one repo that has a
local folder and, for the runner rows, a runner set up in Settings › Claude › Run On.

## Settings and config
- [ ] Settings › General › Claude Sessions › Terminal lists Terminal, the installed ones among iTerm, Warp, Ghostty and
      Orca, and Custom…; an uninstalled one isn't listed, unless it was the saved one, which shows as "<Name> (not installed)".
- [ ] Custom… shows the Command field with the help "{dir} is the PR’s folder, {command} runs Claude. PRBar quotes both: don’t
      put them in quotes. PRBar runs the command in the background, so it should open the terminal and return."
- [ ] A Custom command with `"{command}"` or `'{dir}'` shows "Don’t put quotes around {dir} or {command}: PRBar quotes them."
      under the field, and the Terminal button shows the same alert.
- [ ] A Custom command that stays in the foreground (`/Applications/kitty.app/Contents/MacOS/kitty --directory {dir}
      /bin/zsh -lc {command}`, or `alacritty --working-directory {dir} -e /bin/zsh -lc {command}`) opens the session, and
      it is still alive more than 30 s later.
- [ ] Custom and Orca run from PRBar's GUI environment (minimal `PATH`): with `claude` installed through npm/nvm, a
      template without a login shell may fail to find it; `/bin/zsh -lc {command}` in the template fixes it. Note the result.
- [ ] With `CLAUDE_CONFIG_DIR` set in your shell: PRBar's sessions are saved under its own environment (`~/.claude`);
      check whether `--resume` in the terminal says "No conversation found" and note it (known limitation, spec T.5).
- [ ] `prbar config set terminal ghostty` changes the picker; `prbar config show` shows `"terminal": "ghostty"`.
- [ ] `prbar config set terminal-command "open -a Terminal"` fails (no `{command}`); with `{command}` it saves; `""` clears it.
- [ ] The Custom field saves on Return or when it loses focus (not on every keystroke); the red line updates while typing.
- [ ] An old `config.json` without these keys opens with Terminal.

## Review session
- [ ] Review a PR. When it finishes, the toolbar's Terminal button (left of Chat) is enabled; with the filter on there
      are two sessions: a menu with Review › Review · stage 1 / stage 2.
- [ ] For each installed terminal (Terminal, iTerm, Warp, Ghostty, Orca, Custom): choose it, open a review session.
      Claude Code opens interactive in the review's folder (`pwd` matches `prbar session list`), with the user's normal
      config (MCP, hooks, permissions), and the conversation continues where the review left it.
- [ ] After `/exit` the window stays open with a shell in the folder.
- [ ] Orca with a repo not added in Orca: alert "This folder isn’t in Orca. Add the repo in Orca or choose another
      terminal." with "Open Settings" (opens Settings › General; a runner error opens Settings › Claude).
- [ ] Orca with a repo whose local folder has a non-ASCII character (e.g. `~/Code/café`, added in Orca): the kept
      worktree under it opens in Orca (the `--worktree=path:…` selector matches; no "isn’t in Orca" alert).
- [ ] An uninstalled terminal saved in config (edit config.json): alert "<name> isn’t installed…".
- [ ] Publish the review: the folder is still there (`prbar session list <pr>` still lists the stages).
- [ ] Review the same PR again: the new review's sessions replace the old; the old folder is gone. Repeat with a
      `claude` (or `cd`) running inside the old folder: it stays (Activity shows it) and Clean Up removes it later.

## Fix sessions
- [ ] Respond to a PR of yours with two fixes, push. The Terminal menu shows Fixes › Fix 1: … and Fix 2: … (titles
      truncated to 50).
- [ ] Fix CI on a PR, push: the menu shows CI fix (and the Respond fixes are gone: same folder kind).
- [ ] While PRBar runs tests or a chat turn in the kept fix folder, that session is disabled in the menu (the review
      session stays enabled); with every session busy the button is disabled with "Claude is working on it" (hover it
      to see the reason); `prbar session open <pr>` on the busy one exits 6. ⌥⌘T is disabled only when the most recent
      session is busy.
- [ ] Commit and push from the terminal session in the kept folder: PRBar's next job on the PR uses a new folder and
      doesn't touch it.

## Runner
- [ ] With the repo set to run on a runner, review a PR. The session row says the runner's name (`prbar session list`).
- [ ] Open it in Terminal: `ssh -t` connects and `claude --resume` runs in the runner's folder.
- [ ] Open it in Orca: the terminal opens on the repo's local folder and runs the ssh command.

## Other entry points
- [ ] Pull Request › Open Claude Session in Terminal (⌥⌘T) opens the most recent session; disabled without sessions.
- [ ] Help › Keyboard Shortcuts lists ⌥⌘T.
- [ ] History › a review or Respond record with a kept folder shows Open in Terminal (a menu with several); an older
      record whose folder was replaced doesn't.
- [ ] `prbar session open <pr> --job review`, `--run 2`, `--job ci-fix` on a PR without Fix CI (exit 6).
- [ ] The iPhone app doesn't offer any of this; `sessionOpen` from the phone is denied.

## Cleanup
- [ ] Merge the PR: within a refresh or two (and at most an hour if it already left the list) the kept folders are
      gone, and `prbar session list` says "No Claude session for this PR yet.".
- [ ] Close a PR without merging: same.
- [ ] Leave uncommitted changes in a kept folder and merge the PR: the folder is NOT deleted (it stays for Clean Up), and
      Clean Up lists it as skipped ("has uncommitted changes").
- [ ] With `claude --resume` open in a clean kept folder, Clean Up skips it ("has a process working in it").
- [ ] Restart PRBar: kept folders survive the startup orphan cleanup (also on the runner).
- [ ] Activity and `prbar resources` count kept folders under worktrees; Activity shows them as "Kept", `prbar resources`
      doesn't count them as leftover, and the Clean Up preview (Activity and `prbar cleanup --preview`) tags them
      "(kept for Terminal)".
- [ ] Push fixes, then delete the PR's branch on GitHub and `git fetch --prune` in the clone: the kept fix folder is not
      reported as having unpushed commits (Clean Up removes it; a commit you add in it afterwards makes Clean Up skip it).
- [ ] A review that recorded no Claude session (or a pushed run without fix sessions): its folder is deleted as before.
- [ ] Remove a runner from Settings that had kept folders: the next time PRBar tries to remove them (at launch for
      replaced ones, or when the PR closes) their entries are dropped (logged), not retried forever.
- [ ] A leftover review/chat worktree (not kept) with uncommitted changes: kept at launch and listed by Clean Up as
      skipped, never deleted.
- [ ] `~/Library/Application Support/PRBar/terminal/` keeps no `.command` files older than a day after an opening.
