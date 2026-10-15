<div align="center">

# ⎇ Tern Plotroom

**Your pull requests and issues, in one block inside [Tern](https://docs.stencil.so/tern).**
Triage with the keyboard. One key checks a PR or issue out into its own worktree. Another points an agent at it.

[![check](https://github.com/andyhite/tern-plotroom/actions/workflows/check.yml/badge.svg)](https://github.com/andyhite/tern-plotroom/actions/workflows/check.yml)
![Tern 0.8.3](https://img.shields.io/badge/Tern-0.8.3-blue)

</div>

```
 ┌─ Plotroom · My PRs ────────────────────────────────────────────────── ⚙ ↻ ─┐
 │ Views            │  #482  fix: debounce search input         ✓ 3/3  In tab │
 │ ▸ Needs review   │  #479  feat: worktree setup commands       ● 1/4        │
 │   Assigned to me │  #471  chore: bump luau-lsp                ✓ 2/2  Wtree │
 │   Drafts         │  #468  docs: README, but fancy             ○ 0/1        │
 │                  │                                                         │
 │ Auto-refresh: every 60 s, next 14:02:11  ·  4,991 / 5,000 until 14:30     │
 └──────────────────────────────── ?  keys  ·  /  search  ·  w  worktree ─────┘
```

## Install

Requires Tern 0.8.3, `gh` signed in to github.com, `git` ≥ 2.36 and [`omp`](https://github.com/can1357/oh-my-pi) (worktrees and agents). Jira views also need Atlassian's [`acli`](https://developer.atlassian.com/cloud/acli) signed in (`acli jira auth login`).

```sh
tern plugin install github.com/andyhite/tern-plotroom/plugin
```

Then, from any pane: palette → **Plotroom: Open**. One Plotroom block holds every saved view in its sidebar: GitHub pull requests and issues, and Jira issues. Opened inside a github.com checkout, it saves that checkout as the one its worktrees come from (Settings › Repositories).

Update later with the same command plus `--force`.

**From the separate Issues block.** There is no *Plotroom: Open Issues* command any more: Plotroom: Open is the one entry point and shows issue views too. Tern has no way to convert a pane, so a pane of the old Issues block does not work in the new version: close it and open Plotroom once. A pane of the old PR block reopens as it was. Your saved views and prompts are not touched: the new block reads them where they are.

**Remote hosts.** A Plotroom pane on a remote host works like a local one: the queue, worktrees and agents run on that host, with its `gh`, `git`, `omp`, checkouts and saved settings. Install the same Plotroom version on both machines (the command above, run on each). With a different version on the remote, the Worktree and Agent actions say so instead of running.

## What it does

| | |
| --- | --- |
| 🔍 **Typed views** | Saved searches in one sidebar, each a **Pull requests** or an **Issues** view. A GitHub view takes a GitHub search query across every repository its login can see (`repo:`, `org:` and `user:` narrow it); a Jira view takes JQL across every project `acli` can see. The sidebar groups the GitHub pull request and issue views together, with Jira views alongside. Settings › Views has a group for each `gh` login signed in and one for Jira while `acli` is installed, each with its views and an **Add view** button: the new view searches as that login (or through Jira) and is of the active view's type, an Issues view for Jira. A view's form holds its Type (GitHub views), name, query, grouping and prompts. Changing a view's Type keeps its name and query but not the prompts offered under it. Issue views list In Progress, then To Do, then Done. |
| ⚡ **Polite refresh** | Every 60 s while quota is ample; backs off from GitHub's rate-limit headers instead of hammering. |
| ✅ **Checks and details** | The selected PR's full check list, re-runs collapsed to the newest, with its merge state (conflicts, behind base, blocked, ready), each reviewer's latest verdict and who is still requested, and its description folded above the facts. Reloaded on every successful refresh, so check status changes show up even when the PR itself is unchanged. |
| 🌳 **Worktrees** | `w` checks the PR out on its own head branch with `omp worktree add` into omp's worktree directory (default `~/.omp/wt`) as `plotroom-<owner>_<repo>-pr-N` (the folder name format is yours to change), and opens a tab there. On an issue, `w` uses the issue's linked pull request's branch, else a new branch from a base you pick. Never resets or cleans anything of yours; the preview's worktree card can remove the worktree, asking first and never forcing it. Needs the repository's local checkout (Settings › Repositories); without one, Worktree, agents and prompts ask for it. |
| 🤖 **Agents** | The queue's action bar has one button per saved prompt (Settings › Prompts) offered under the current view; each starts an [omp](https://github.com/can1357/oh-my-pi) agent block (Tern's `cx.agents:start`) inside the item's worktree (or, as the prompt says, the repository's main checkout) with the prompt, no questions asked. A prompt may name the model omp runs it with (`omp --model`): a role alias such as `@slow`, or a model such as `opus`. Give a prompt a shortcut key to run it straight from the queue. `a` picks one, or lets you type one. |
| 🔗 **Linked PRs** | On an issue, click a linked pull request to show it in the same block: it is selected in the active view when that lists pull requests and has it; otherwise it is looked up alone under an `owner/name#N` entry at the top of the sidebar, and the other views stay there to go back to. |
| 👤 **Per-view accounts** | Work and personal `gh` logins on one machine: each signed-in login has its own group of views in the sidebar, searching as that login. Tokens stay in memory, never on disk. |

## Keys

Press `?` in the block for this list, which shows the keys as you have set them. `j` `k` `w` `g` `a` `/` `r` `s` `?` are the defaults: Settings › Keys changes or removes each one (Enter on its row, then the new key, or Backspace to remove it), for pull requests and issues alike and per machine (the arrows, `Enter`, `Tab`, `Esc`, Page Up/Down, Home and End are fixed).

| Key | Does |
| --- | --- |
| `↑` `↓` / `j` `k` | Move |
| `Tab` | Switch between the views and the list |
| `Enter` | Open the PR or issue in a Browser block beside the queue |
| `w` | Create or reuse the PR's worktree in a new tab |
| `g` | Go to the tab already working in that worktree |
| `a` | Pick a saved prompt, or type one, and run it on the PR |
| your keys | Run the saved prompt with that shortcut on the PR (listed under `?`) |
| `/` | Search the loaded PRs or issues |
| `r` | Refresh now |
| `s` | Settings, on the page it last showed: views, prompts, keys, worktrees (folder and name formats), repositories (checkouts, branch formats, setup commands), Jira projects, refresh |

## Worktrees

```mermaid
flowchart LR
    W([w]) --> E{exists?}
    E -- yes --> R[reuse as-is] --> T[open tab]
    E -- "no, PR" --> F[fetch the PR head] --> C[omp worktree add on its branch] --> S[your setup commands] --> T
    E -- "no, issue" --> L{linked PR with a live branch?}
    L -- "one (or the one you pick)" --> F
    L -- "none (or New branch…)" --> B[pick a base, fetch it] --> N[new branch from the format] --> C
```

- Worktrees go in omp's worktree directory: `OMP_WORKTREE_DIR`, else omp's `worktree.base` setting, else `~/.omp/wt` (Settings › Worktrees › Folder overrides it). The repository's saved checkout (Settings › Repositories; opening Plotroom inside a checkout, or a linked worktree of it, saves its main checkout) is only where the worktree is added from.
- A pull request's worktree is on its own head branch, tracking it on GitHub (a fork's as `<fork owner>/<branch>`, tracking the fork), so `git pull`, `git push` and `gh pr view` work inside it without arguments. A local branch of that name that already exists is used as it is, never moved. A worktree an earlier version made at the PR's folder (on `plotroom/<owner>/<repo>/pr-N`) is still reused.
- An issue's worktree is on the branch of its linked pull request when exactly one still has its branch on GitHub; with several, Plotroom asks which, or a New branch. A GitHub issue's linked PRs are those that close it; a Jira issue's are the pull requests of its repository whose title or head branch names its key. A new branch asks for the base branch it starts from (the remote's default first), fetches that base, and is named by the branch format.
- **Name formats** (Settings › Worktrees): the new issue branch (default `{github.user}/{key}-{slug}`; a repository can have its own, under Settings › Repositories) and the folder names of PR and issue worktrees (defaults `plotroom-{owner}_{repo}-pr-{key}` and `plotroom-{owner}_{repo}-issue-{key}`, where `{owner}` and `{repo}` are lowercase). A branch format takes `{key}` `{slug}` `{owner}` `{repo}` `{project}` `{github.user}` `{jira.user}`; a folder format takes `{key}` `{slug}` `{owner}` `{repo}` and no `/`. Both need `{key}`. `{github.user}` is the view's `gh` account, else `gh`'s active one; `{jira.user}` is your Jira sign-in's email before the `@`.
- Reused worktrees are never updated. The preview's worktree card shows `Up to date|Not at PR head` and `Clean|Uncommitted changes|Changes unchecked` badges (their tooltip is the one-line summary), its branch and path, and, when the worktree is not at the PR's head, the `git pull --ff-only` command for you to run. Its buttons: **Go to tab** while a tab works in it (else **Open in new tab**), and **Remove worktree**.
- **The card is read from git, not remembered.** After every refresh, Worktree press and removal (and when a checkout is saved) Plotroom lists the saved checkouts of the repositories on screen with `git worktree list`; it never asks per row. A worktree is a PR's when it is on the PR's head branch or in the folder the PR folder format names; an issue's when it is on the branch or in the folder the issue formats name now. So a block opened later, or after a plugin reload, shows the card and the row's **Worktree** badge of every such worktree, with no Worktree press; one you removed yourself leaves at the next refresh; and a read that fails changes nothing. `Up to date` compares the worktree's HEAD with the PR head the last refresh saw (a PR pushed since reads as it was until the next refresh). `Clean` / `Uncommitted changes` is read with `git status` for the selected PR only, once the cursor rests on it and again after each refresh; until then the badge says `Changes unchecked` and the row's badge has no colour.
- **Remove worktree** asks first (`d` or Remove removes it; Enter or Esc keeps it) and runs on the host that has the checkout: `git worktree remove` without `--force`, so git refuses a worktree with uncommitted changes and the card says why. Then its branch: a pull request's goes with `branch -D` only when `git merge-base --is-ancestor` finds every commit of it in the ref fetched for the PR (and that ref goes too), else with `branch -d`; an issue's goes with `branch -d`. A branch git keeps stays, with its ref, and the toast names it. Plotroom never runs `reset`, `clean`, `stash` or `prune`.
- **Setup commands** (Settings › Repositories) run in the new tab's shell when a worktree is *created*. They execute the PR's code (`pnpm install` runs its scripts), so leave them empty for repos that take untrusted PRs.
- **Prompts** (Settings › Prompts) become buttons in the queue's action bar and rows in the `a` picker. Pull requests and issues each keep their own prompts; the page lists both. Each has a name, multi-line text (Edit… opens an editor; Enter is a new line, ⌘↵ saves, Esc cancels), an optional one-key shortcut (not a key the queue uses, as set in Settings › Keys) and the views it is offered under; with none turned on it is offered under every view of its type. In a PR prompt, or a typed one, `{url}`, `{owner}`, `{repo}`, `{number}`, `{title}`, `{author}`, `{branch}` (the PR's head branch), `{base}` (the branch it merges into) and `{github.user}` (your GitHub login) become the PR's details, read fresh from GitHub; an issue's prompts also take `{jira.user}`. Any other `{…}` stays as written. Prompts are saved per machine, like views.
- **Prompt models**: a prompt's Model (empty: omp's default) starts its agent as `omp --model <model>`. Anything `omp --model` takes works: a role alias from your omp config (`@slow`, `@smol`, `@plan`), a fuzzy pattern (`opus`) or `provider/model-id`.
- **Where a prompt runs**: a prompt's Runs in is Worktree by default: the item's worktree, made first if needed. Pick Main checkout for prompts that need no checkout of the item's branch (review a PR, break an epic into tickets): the agent starts in the repository's main checkout, with no worktree made and no setup commands. The prompt's variables are filled in either way, except an issue's `{branch}`.
- **Where its agent opens**: by default in a New tab (the worktree's open tab, when there is one). Set a prompt's Opens in to Beside the queue to open the agent as a block beside the queue, in the queue's tab; a new worktree's setup commands still run in their own tab.

## Trust

- No shell: `gh`, `git`, `ssh -G` and `omp` run as argv arrays. If they are not on Tern's PATH, your login shell is run once to find them. The one exception is the agent block, which Tern starts through your login shell: Plotroom passes it `omp --model <model>` only for a model made of model-name characters (letters, digits, `@ . _ : / -`).
- No secrets on disk. `kv.json` holds views, agent prompts, shortcut keys, checkout paths, setup commands, name formats, logins and recent agent picks in plaintext.
- A saved account that cannot be used **fails closed**: nothing falls back to your active `gh` login.
- Agents read PR and issue text written by whoever wrote it. Be careful with agents that can act.
- **Agents can run project code.** `omp` loads the project configuration of the directory it starts in (extensions, hooks, MCP servers), not only your setup commands. That code is trusted, not sandboxed, and Plotroom starts the agent without asking once the worktree is ready, so only run prompts on PRs whose project configuration you trust.

SSH aliases (`git@github.com-work:…`) count as GitHub when `ssh -G` resolves them to `github.com`.

<details>
<summary><b>Finer points</b> (refresh, partial results, accounts, ref names, errors)</summary>

**Refresh.** Up to 10 requests of 100 results per refresh (GitHub's 1,000 cap). Interval is 60 s with ample quota; otherwise time-to-reset is spread over 80 % of remaining requests across open panes, never under 60 s. Quota 0 or `Retry-After` pauses everything until reset. A failed page discards that refresh and keeps the last complete result marked `stale`. Terminal errors (`gh` missing, not signed in, HTTP 422, unusable account) stop auto-refresh until you press `r`.

**Views.** GitHub views search every repository the login can see, as GitHub search does; `repo:`, `org:` and `user:` narrow a view. Jira views are JQL over every project `acli` can see.

**Accounts.** A GitHub view added under a login's group in Settings › Views searches as that login: each `gh` call runs `gh auth token --user <login>` and passes the result as `GH_TOKEN` to that one child. The default views search as `gh`'s active login. Manage logins with `gh auth login` / `gh auth switch`.

**Refs.** Fetches land in `refs/plotroom-pr/<owner>/<repo>/pr-N` (names git refuses, such as `.github` or `a..b`, `%2E`-encoded); a same-repository head branch is also fetched into its remote-tracking ref, and a new issue branch's base into `refs/remotes/<remote>/<base>`.

**Errors you can act on.** Target directory exists but is not this item's worktree: move it. Locked or prunable record: `git worktree repair` or `prune`. A branch or folder format that cannot name one: change it in Settings › Worktrees (a repository's own branch format: Settings › Repositories). Tab did not open: press `w` again, it reuses.

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
| `plugin/host.luau` | the one `prs` block (shown as Plotroom): pull request and issue views by kind, prompts, refresh, state; worktrees and the agent menu for the window, run where the block runs |
| `plugin/window.luau` | links, palette commands, the pickers and tabs of the worktree and agent flows |
| `plugin/github.luau` · `jira.luau` · `tracker.luau` · `worktree.luau` · `process.luau` · `input.luau` · `keys.luau` | `gh` search, Jira through `acli`, tracker-neutral issues and name formats, worktrees, argv process runner, text input (one line or many), the queue's rebindable keys |
| `plugin/tests/` | `regression.luau` (fake SDK), `check.luau` (pure asserts), `runtime.luau` (real-Tern smoke) |
| `scripts/check.py` | the gate; CI runs `--ci` (no smoke, Tern is not available there) |

`link` and `install` are exclusive per id: switch with `tern plugin remove plotroom` / `tern plugin unlink plotroom` first.
