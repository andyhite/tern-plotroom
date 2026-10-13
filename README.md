<div align="center">

# ⎇ Tern Plotroom

**Your GitHub PR queue, inside [Tern](https://docs.stencil.so/tern).**
Triage with the keyboard. One key checks a PR out into its own worktree. Another points an agent at it.

[![check](https://github.com/andyhite/tern-plotroom/actions/workflows/check.yml/badge.svg)](https://github.com/andyhite/tern-plotroom/actions/workflows/check.yml)
![Tern 0.8.3](https://img.shields.io/badge/Tern-0.8.3-blue)

</div>

```
 ┌─ Plotroom · GitHub PRs ──────────────────────────────────────────── ⚙ ↻ ─┐
 │ Filters          │  #482  fix: debounce search input         ✓ 3/3  In tab │
 │ ▸ Needs review   │  #479  feat: worktree setup commands       ● 1/4        │
 │   Mine           │  #471  chore: bump luau-lsp                ✓ 2/2  Wtree │
 │   Drafts         │  #468  docs: README, but fancy             ○ 0/1        │
 │                  │                                                         │
 │ Auto-refresh: every 60 s, next 14:02:11  ·  4,991 / 5,000 until 14:30     │
 └──────────────────────────────── ?  keys  ·  /  search  ·  w  worktree ─────┘
```

## Install

Requires Tern 0.8.3, `gh` signed in to github.com, `git` ≥ 2.36 and [`omp`](https://github.com/can1357/oh-my-pi) (worktrees and agents).

```sh
tern plugin install github.com/andyhite/tern-plotroom/plugin
```

Then, from any pane: palette → **Plotroom: Open GitHub PRs**. Opened inside a github.com checkout, it shows that repository and saves the checkout as the one its worktrees come from; anywhere else, pick a repository with `o`.

Update later with the same command plus `--force`.

**Remote hosts.** A Plotroom pane on a remote host works like a local one: the queue, worktrees and agents run on that host, with its `gh`, `git`, `omp`, checkouts and saved settings. Install the same Plotroom version on both machines (the command above, run on each). With a different version on the remote, the Worktree and Agent actions say so instead of running.

## What it does

| | |
| --- | --- |
| 🔍 **Saved filters** | Any GitHub search query, scoped to the repository shown. `o` (or clicking the repository name in the heading) picks another: a saved one, one of a signed-in `gh` account's (pick the account, then its repository), or any typed `owner/name`. |
| ⚡ **Polite refresh** | Every 60 s while quota is ample; backs off from GitHub's rate-limit headers instead of hammering. |
| ✅ **Checks and details** | The selected PR's full check list, re-runs collapsed to the newest, with its merge state (conflicts, behind base, blocked, ready), each reviewer's latest verdict and who is still requested, and its description folded above the facts. Reloaded on every successful refresh, so check status changes show up even when the PR itself is unchanged. |
| 🌳 **Worktrees** | `w` checks the PR out with `omp worktree add` into omp's worktree directory (default `~/.omp/wt`) as `plotroom-<owner>_<repo>-pr-N`, and opens a tab there. Never resets, cleans or deletes anything of yours. Needs the repository's local checkout (Settings › Worktrees); without one, Worktree, agents and prompts are hidden and `w` asks for it. |
| 🤖 **Agents** | The queue's action bar has one button per saved prompt (Settings › Prompts) offered under the current filter; each runs that prompt on the PR with [omp](https://github.com/can1357/oh-my-pi), inside its worktree. Give a prompt a shortcut key to run it straight from the queue. `a` picks one, or lets you type one. |
| 👤 **Per-repo accounts** | Work and personal `gh` logins on one machine. Tokens stay in memory, never on disk. |

## Keys

Press `?` in the block for this list.

| Key | Does |
| --- | --- |
| `↑` `↓` / `j` `k` | Move |
| `Tab` | Switch between filters and PRs |
| `Enter` | Open the PR in a Browser block beside the queue |
| `w` | Create or reuse the PR's worktree in a new tab |
| `g` | Go to the tab already working in that worktree |
| `a` | Pick a saved prompt, or type one, and run it on the PR |
| `o` | Show another repository |
| your keys | Run the saved prompt with that shortcut on the PR (listed under `?`) |
| `/` | Search loaded PRs |
| `r` | Refresh now |
| `s` | Settings: filters, agent prompts, GitHub account, worktree checkout path and setup commands |

## Worktrees

```mermaid
flowchart LR
    W([w]) --> E{exists?}
    E -- no --> F[fetch refs/pull/N/head] --> C[omp worktree add] --> S[your setup commands] --> T[open tab]
    E -- yes --> R[reuse as-is] --> T
```

- Worktrees go in omp's worktree directory: `OMP_WORKTREE_DIR`, else omp's `worktree.base` setting, else `~/.omp/wt`. The repository's saved checkout (Settings › Worktrees; opening Plotroom inside a checkout, or a linked worktree of it, saves its main checkout) is only where the worktree is added from.
- Branch `plotroom/<owner>/<repo>/pr-N` tracks `refs/pull/N/head`, so `gh pr view` and `git pull` work inside it without arguments.
- Reused worktrees are never updated. The preview shows `Created|Reused · Current|Different · Clean|Modified` and offers the `fetch` + `merge --ff-only` and cleanup commands for you to run.
- Plotroom never runs `reset`, `clean`, `stash`, `worktree remove`, `prune`, `branch -d`, or `update-ref -d`.
- **Setup commands** (Settings › Worktrees) run in the new tab's shell when a worktree is *created*. They execute the PR's code (`pnpm install` runs its scripts), so leave them empty for repos that take untrusted PRs.
- **Prompts** (Settings › Prompts) become buttons in the queue's action bar and rows in the `a` picker. Each has a name, multi-line text (Edit… opens an editor; Enter is a new line, ⌘↵ saves, Esc cancels), an optional one-key shortcut (not one the queue uses: `j k w g a o r s / ?`) and the filters it is offered under; with none turned on it is offered under every filter. In a prompt, or a typed one, `{url}`, `{owner}`, `{repo}`, `{number}`, `{title}`, `{author}`, `{branch}` (the PR's head branch) and `{base}` (the branch it merges into) become the PR's details, read fresh from GitHub; any other `{…}` stays as written. Prompts are saved per machine, like filters.

## Trust

- No shell: `gh`, `git`, `ssh -G` and `omp` run as argv arrays. If they are not on Tern's PATH, your login shell is run once to find them.
- No secrets on disk. `kv.json` holds filters, agent prompts, checkout paths, setup commands, logins and recent agent picks in plaintext.
- A saved account that cannot be used **fails closed**: nothing falls back to your active `gh` login.
- Agents read PR text written by whoever opened the PR. Be careful with agents that can act.
- **Agents can run project code.** `omp` loads the project configuration of the directory it starts in (extensions, hooks, MCP servers), not only your setup commands. That code is trusted once you allow it, not sandboxed. So before starting an agent Plotroom asks every time, naming the PR's worktree, with Deny as the first choice. It asks once the worktree exists and before `omp` runs in it, setup commands run or the agent starts. Deny leaves the worktree as created and runs no `omp` in it, no setup commands and no agent, so the PR's project configuration is not executed.

SSH aliases (`git@github.com-work:…`) count as GitHub when `ssh -G` resolves them to `github.com`.

<details>
<summary><b>Finer points</b> (refresh, partial results, accounts, ref names, errors)</summary>

**Refresh.** Up to 10 requests of 100 results per refresh (GitHub's 1,000 cap). Interval is 60 s with ample quota; otherwise time-to-reset is spread over 80 % of remaining requests across open panes, never under 60 s. Quota 0 or `Retry-After` pauses everything until reset. A failed page discards that refresh and keeps the last complete result marked `stale`. Terminal errors (`gh` missing, not signed in, HTTP 422, unusable account) stop auto-refresh until you press `r`.

**Filters.** `repo:`, `org:`, `user:` and bare `OR` are rejected: every filter stays inside the repository shown (opened in a checkout: its first github.com remote, origin, upstream, then alphabetical).

**Accounts.** The GitHub settings page sets a `gh` login per repo. Each `gh` call then runs `gh auth token --user <login>` and passes the result as `GH_TOKEN` to that one child. Manage logins with `gh auth login` / `gh auth switch`.

**Refs.** Fetches land in `refs/plotroom-pr/<owner>/<repo>/pr-N`. Names git refuses (`.github`, `a..b`) are `%2E`-encoded in branch and ref only; the directory keeps the raw name.

**Errors you can act on.** Branch exists elsewhere with no worktree: the message gives the `worktree add` command. Target directory exists but is not this PR: move it. Locked or prunable record: `git worktree repair` or `prune`. Tab did not open: press `w` again, it reuses.

</details>

## Development

```sh
git clone git@github.com:andyhite/tern-plotroom.git && cd tern-plotroom
tern plugin link ./plugin          # live-reloads on edit; never link the repo root (.git churn)
python3 scripts/check.py tools     # pinned luau + luau-lsp
python3 scripts/check.py           # test · types · bench · smoke
```

| | |
| --- | --- |
| `plugin/host.luau` | the `prs` block: queue, filters, prompts, refresh, state; worktrees and the agent menu for the window, run where the block runs |
| `plugin/window.luau` | links, palette commands, the pickers and tabs of the worktree and agent flows |
| `plugin/github.luau` · `worktree.luau` · `process.luau` · `input.luau` | `gh` search, worktrees, argv process runner, text input (one line or many) |
| `plugin/tests/` | `regression.luau` (fake SDK), `check.luau` (pure asserts), `runtime.luau` (real-Tern smoke) |
| `scripts/check.py` | the gate; CI runs `--ci` (no smoke, Tern is not available there) |

`link` and `install` are exclusive per id: switch with `tern plugin remove plotroom` / `tern plugin unlink plotroom` first.
