# Tern Plotroom

A Tern plugin. First tool: a live GitHub PR queue.

- **Open**: palette → `Plotroom: Open GitHub PRs`. The block remembers the launching pane's directory.
- **Filters**: saved GitHub search queries (New/Edit/Delete). Stored in the plugin's `kv.json`; the queue refreshes the selected one every 60 s.
- **PR click / `Open selected PR in Browser`**: opens one Browser block docked beside the queue.
- **Worktree**: creates (or reuses) `<repo>.plotroom/<owner>/<repo>/pr-N` on branch `plotroom/<owner>/<repo>/pr-N` in a new tab. The repository is the launch directory's checkout, else a path you map once.
- Uses your existing `gh` login. `gh`/`git` are found on Tern's PATH, else on your login shell's PATH.

Dev: `tern plugin types .` (writes the ignored `tern.d.luau`), `tern plugin link .`. With `PLOTROOM_SELFTEST=1` in Tern's environment the palette gains `Plotroom: Self-test` (runs `tests/check.luau`).
