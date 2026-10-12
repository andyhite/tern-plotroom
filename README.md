# Tern Plotroom

A Tern plugin. First tool: a live GitHub PR queue.

- **Open**: palette → `Plotroom: Open GitHub PRs`. The block remembers the launching pane's directory.
- **Filters**: saved GitHub search queries (New/Edit/Delete), stored in the plugin's `kv.json`. Every filter runs inside the launch directory's repository: the repo is the first github.com remote of that checkout (origin, then upstream, then alphabetical), read with local `git` only. No repo means no search and a Retry card. `repo:`, `org:`, `user:` and uppercase `OR` are rejected with a message, since they would widen the search.
- **PR list**: aligned columns (state, left-aligned `#number`, title, `@author`, age). Only the focused list (saved filters or PRs) shows its selected row; Tab switches, arrows act on the focused list.
- **Refresh**: one search request returns up to 100 results; a refresh pages up to 1000 (10 requests). It runs on launch, on filter changes (a cached result younger than the refresh interval is shown instead), on `r`/Refresh/Retry, and by timer. Re-selecting the active filter does nothing. The interval is 60 s while GitHub's `X-RateLimit-*` headers (read from the search responses themselves, never a separate `/rate_limit` call) show ample quota; otherwise the time to reset is spread over 80% of the remaining requests, divided across open Plotroom panes (panes using the same account share its search quota), and never drops below 60 s. Remaining quota 0 pauses every trigger, manual ones included, until GitHub's reset; a `Retry-After` header (seconds or date) pauses until that deadline instead, and a rate-limit error without headers pauses for 5 min. A refresh cut off mid-way keeps the results received and says so. The header shows `Auto-refresh: every …, next HH:MM:SS` or `Paused by GitHub rate limit until HH:MM:SS`, with the search quota and its reset time.
- **PR click / `Open selected PR in Browser`**: opens one Browser block docked beside the queue.
- **Worktree**: creates (or reuses) `<repo>.plotroom/<owner>/<repo>/pr-N` on branch `plotroom/<owner>/<repo>/pr-N` in a new tab. The repository is the launch directory's checkout, else a path you map once.
- **SSH aliases**: a remote such as `git@github.com-personal:owner/repo.git` or `ssh://git@alias:2222/owner/repo` counts as GitHub when `ssh -G [-p port] git@<alias>` (reads your ssh config, opens no connection) reports `hostname github.com`. Host-name guesses are never used; other hosts are rejected. The remote is not rewritten, so `git fetch` keeps using the alias and its key.
- **Paused states**: with no GitHub repo, or after a terminal `gh` error (auth, missing CLI, not found, search rejected with HTTP 422), auto-refresh stops and the header says so ("Auto-refresh unavailable/paused…"). Nothing re-runs git or `gh` on its own, not on filter selection and not after a plugin reload (the pause is saved with the block state). Only Retry, `r`, Refresh or saving a different account (an intentional retry) tries again, once.
- **Account**: the toolbar's `Account` button sets a `gh` login for this repo (stored in the plugin's `kv.json`; empty means the active `gh` account). It never switches `gh`'s global account and stores no tokens. Saving clears cached results and does one refresh. An SSH key or alias selects only the git transport, not the API account: PR searches use `gh`'s login for github.com, so a repo under another account needs its login set here.
- Uses your existing `gh` login. `gh`/`git` are found on Tern's PATH, else on your login shell's PATH.

The package lives in `plugin/` (manifest, runtime modules, CSS, self-test); the repo root holds only docs and tooling, so linking `plugin/` never watches `.git`.

Dev: `tern plugin link ./plugin` (live reload: Tern watches the linked tree recursively and reloads on any change, [lifecycle](https://docs.stencil.so/tern/concepts/lifecycle.md)). `tern plugin types ./plugin` writes the ignored `plugin/tern.d.luau` (editor types only). With `PLOTROOM_SELFTEST=1` in Tern's environment the palette gains `Plotroom: Self-test` (runs `plugin/tests/check.luau`).

Clean install: `tern plugin install ./plugin --force` copies the package; a plain reload does not re-copy it, so re-run this after edits. See the [CLI reference](https://docs.stencil.so/tern/reference/cli.md).

Switching modes: `link` refuses while an installed copy exists, and `install --force` never replaces a link.
- Installed copy → live dev: `tern plugin remove plotroom && tern plugin link ./plugin`
- Live dev → clean install: `tern plugin unlink plotroom && tern plugin install ./plugin --force` (`unlink` leaves `./plugin` untouched)

Never link the repo root: it would also watch `.git`, whose metadata (e.g. the `fsmonitor` cookie) changes about once a second and reloads the plugin every 1-2 s.
