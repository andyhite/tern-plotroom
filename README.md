# Tern Plotroom

A Tern plugin. First tool: a live GitHub PR queue.

- **Open**: palette → `Plotroom: Open GitHub PRs`. The block remembers the launching pane's directory.
- **Filters**: saved GitHub search queries (New/Edit/Delete), stored in the plugin's `kv.json`. Every filter runs inside the launch directory's repository: the repo is the first github.com remote of that checkout (origin, then upstream, then alphabetical), read with local `git` only. No repo means no search and a Retry card. `repo:`, `org:`, `user:` and uppercase `OR` are rejected with a message, since they would widen the search.
- **PR list**: aligned columns (state, left-aligned `#number`, title, `@author`, age). Only the focused list (saved filters or PRs) shows its selected row; Tab switches, arrows act on the focused list.
- **Refresh**: one search request returns up to 100 results; a refresh pages up to 1000 (10 requests). It runs on launch, on filter changes (a cached result younger than the refresh interval is shown instead), on `r`/Refresh/Retry, and by timer. Re-selecting the active filter does nothing. The interval is 60 s while GitHub's `X-RateLimit-*` headers (read from the search responses themselves, never a separate `/rate_limit` call) show ample quota; otherwise the time to reset is spread over 80% of the remaining requests, divided across open Plotroom panes (they share one search quota), and never drops below 60 s. Remaining quota 0 pauses every trigger, manual ones included, until GitHub's reset; a `Retry-After` header (seconds or date) pauses until that deadline instead, and a rate-limit error without headers pauses for 5 min. A refresh cut off mid-way keeps the results received and says so. The header shows `Auto-refresh: every …, next HH:MM:SS` or `Paused by GitHub rate limit until HH:MM:SS`, with the search quota and its reset time.
- **PR click / `Open selected PR in Browser`**: opens one Browser block docked beside the queue.
- **Worktree**: creates (or reuses) `<repo>.plotroom/<owner>/<repo>/pr-N` on branch `plotroom/<owner>/<repo>/pr-N` in a new tab. The repository is the launch directory's checkout, else a path you map once.
- Uses your existing `gh` login. `gh`/`git` are found on Tern's PATH, else on your login shell's PATH.

Dev: `tern plugin types .` (writes the ignored `tern.d.luau`), `tern plugin link .`. With `PLOTROOM_SELFTEST=1` in Tern's environment the palette gains `Plotroom: Self-test` (runs `tests/check.luau`).
