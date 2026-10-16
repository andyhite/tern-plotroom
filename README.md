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

Requires Tern 0.8.3, `git` ≥ 2.36 and [`omp`](https://github.com/can1357/oh-my-pi) (worktrees and agents), plus the CLI of each integration you use: `gh` signed in to github.com for GitHub, Atlassian's [`acli`](https://developer.atlassian.com/cloud/acli) signed in (`acli jira auth login`) for Jira. An integration is only there while its CLI is installed on the block's host: without `gh`, Plotroom has no GitHub views, groups or prompts, only Settings › GitHub with a **Setup guide** button to gh's install instructions; without `acli`, the same for Jira (Settings › Jira). Install the CLI, then Refresh (or show its setup page again) and the integration turns on.

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
| 🤖 **Agents** | The queue's action bar has one **Agent** button (`a`): pick a saved action (Settings › Actions) offered under the current view, or type a prompt, and it starts an [omp](https://github.com/can1357/oh-my-pi) agent block (Tern's `cx.agents:start`) inside the item's worktree (or, as the action says, the repository's main checkout) with that prompt, no questions asked. An action may name the model omp runs it with (`omp --model`): a role alias such as `@slow`, or a model such as `opus`. Give an action a shortcut key to run it straight from the queue. |
| 🔗 **Linked PRs** | On an issue, click a linked pull request to show it in the same block: it is selected in the active view when that lists pull requests and has it; otherwise it is looked up alone under an `owner/name#N` entry at the top of the sidebar, and the other views stay there to go back to. |
| 👤 **Per-view accounts** | Work and personal `gh` logins on one machine: each signed-in login has its own group of views in the sidebar, searching as that login. Tokens stay in memory, never on disk. |

## Keys

Press `?` in the block for this list, which shows the keys as you have set them. `j` `k` `w` `g` `a` `G` `m` `z` `Z` `n` `o` `.` `/` `r` `s` `?` are the defaults: Settings › Keyboard shortcuts changes or removes each one (Enter on its row, then the new key, or Backspace to remove it), for pull requests and issues alike and per machine (the arrows, `Enter`, `Tab`, `Esc`, Page Up/Down, Home and End are fixed).

| Key | Does |
| --- | --- |
| `↑` `↓` / `j` `k` | Move |
| `Tab` | Switch between the views and the list |
| `Enter` | Open the PR or issue in a Browser block beside the queue |
| `w` | Create or reuse the PR's worktree in a new tab |
| `g` | Go to the tab already working in that worktree |
| `a` | Pick a saved prompt, or type one, and run it on the PR |
| `G` | Go to the agent started from this row (its exact pane) |
| `m` | Mark the item seen |
| `z` | Snooze it until 08:00 local time on the next calendar day; on a snoozed item, end the snooze |
| `Z` | Show or hide snoozed items |
| `n` | List only items that need attention |
| `o` | This view's next sort order |
| `.` | Item commands (the same list as the palette's `Plotroom:` commands below) |
| your keys | Run the saved action with that shortcut on the item (listed under `?`) |
| `/` | Search the loaded PRs or issues |
| `r` | Refresh now |
| `s` | Settings, on the page it last showed: views, actions, keyboard shortcuts, worktrees (name formats), repositories (checkouts, branch formats, setup commands), Jira projects (while `acli` is installed), refresh, and the setup page of `gh` or `acli` while it is not installed |

A saved action's own shortcut wins over `G` `m` `z` `Z` `n` `o` `.` while that action is offered for the selected item: it was that key first. Remove or change the action's key (Settings › Actions) to use the built-in one. Likewise a key you saved for any queue action is yours first: a newer built-in whose default is that key starts with no shortcut (for example, if you set Refresh to `o`, Next sort order is unbound until you give it a key). Imports never take a key the queue already uses.

## Triage, agents and commands

- **Triage is local and explicit.** Each item shows **New** (never marked seen) or **Changed** (its state, title, review, checks, head, comments, labels or assignees differ from when you pressed `m`). Moving the cursor never marks anything seen. `z` snoozes until 08:00 local time on the next calendar day, even when it is still early morning (a **Snoozed** badge when listed with `Z`). `n` keeps only items that need attention: unseen, changed and not snoozed, or whose agent waits for input. An agent waiting for input surfaces its item even when snoozed. Seen and snooze state is per machine (kv `triage`) and cannot be shared by export.
- **Agent states are not results.** A row's badge is the state of the agent pane started from it: Working, Needs input, Idle or Exited. Only Needs input asks for you; Idle and Exited do not mean the work succeeded. `G` or `Plotroom: Go to the selected item's agent` focuses exactly that pane. The link is remembered per host: it counts only for a Plotroom block on the machine that started the agent, so a remote block never jumps to a local agent's pane.
- **Sorting.** `o` cycles the active view through its sorts and saves it with the view (Settings › Views › Sort by, or Default order). GitHub pull requests: Recently updated, Oldest waiting, Review required first. GitHub issues: Recently updated, Oldest waiting. Jira issues: Priority (Jira lists keep no update time). A group's items are sorted inside it. A pinned item has no sort. Changing a GitHub view's Type keeps its sort where the new type offers it; otherwise the view returns to default order and a toast says so.
- **Item commands** (`.`, or the palette's `Plotroom:` entries) change things on GitHub or Jira only after a confirmation that names the item and account and lists exactly what will be sent; its first row is Cancel. The GitHub account is fixed when the plan is made, so a later account switch cannot redirect a confirmed command. They are: assign a GitHub or Jira issue to you, add or remove a GitHub issue's label, move a Jira issue through one of its transitions, and re-run failed checks. **Re-run failed checks** lists every failed GitHub Actions workflow run of the pull request in a picker and re-runs only the failed jobs of the one you select; checks without an Actions run are not touched.
- **Jira transitions need an API token.** Listing and applying transitions uses Jira's REST API, which `acli` does not offer. Create a standard Jira API token (id.atlassian.com › Security › API tokens), export it as `PLOTROOM_JIRA_API_TOKEN` in the environment Tern starts from **on the host the block runs on**, and restart Tern. Plotroom reads it per call, never stores or logs it and never puts it in a command line. It uses the site and email `acli` is signed in with, and first asks Jira `/myself` who the token belongs to (that request is authenticated with the token): if it is not the `acli` account, no transition is applied. Without the token, the command explains this; assigning a Jira issue to you keeps using `acli`.
- **Draft pull request** (issue with a Plotroom worktree). Pick the GitHub repository (every distinct GitHub remote of the checkout) and then a base branch (remote default first); every step checks the repository is still one of them. The preview shows the title, description, `branch → base`, the commits, whether the branch must be pushed and that uncommitted changes stay out. Edit the title or description (the description prompt is one line and replaces all of it; Esc while editing returns to the previous review, it does not abort), then confirm. Before anything is sent the branch, its head and the base are read again; if they moved, or if whether it needs pushing changed, nothing is pushed or created. Otherwise the branch is pushed if needed (never forced, nothing is committed) and a **draft** pull request is created as the view's account.
- **Open item by URL** (palette): a GitHub pull request or issue URL, or a Jira issue URL. It is fetched first, so a missing or unreachable item is reported, then always shown alone at the top of the sidebar as a pin, even when a listed view already holds it; nothing opens in a browser. The pin is saved with the pane, so reopening Plotroom refetches and shows it again.
- **Export and import** (palette) move saved views and actions between machines; they change only Plotroom's own saved views and actions, never GitHub or Jira. Export picks what to include, then shows the counts and any notes (actions left out, what is not included) with Cancel first; nothing is copied or written until you choose. You then pick **Copy to the clipboard** or **Write to a file…** (a path on the block's host, a new file only); each does only that. The confirmed export is exactly the snapshot you were shown, even if settings change meanwhile. A large export is file-only, to stay within the limit for passing it back to the window; the importer accepts up to 60000 bytes. It holds names, queries, groups, sorts and action text, keys, model and placement. It has no field for checkout paths, setup commands, tokens or logins: accounts leave as anonymous slots (`account-1`). An action whose text matches a few credential patterns (GitHub and AWS tokens, bearer tokens, private-key headers, `password=` followed by a literal) is left out with a note; that check cannot catch every secret, so read action text before sharing a file. Import takes pasted JSON or a file path on the block's host and previews what the file holds, including shortcut removals, account slots to map and what will be skipped, and writes nothing until you confirm; if everything ends up skipped it says so and changes nothing. More than 150 entries at once are refused before the preview (a file holds at most 100 views and 100 actions). A same-name item can be skipped, replaced or duplicated (an identical one skipped or duplicated); each account slot is mapped to a signed-in login, gh's active account, or skipped views; an action shortcut that a queue key or another action holds is removed. Both stores are read again when it writes.

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

- **The Worktrees view** (last in the sidebar) lists every worktree of every saved checkout straight from git, whatever the current query: branch, path and badges (Main, In tab, Changes/Clean, Merged/Closed, Locked, Missing, Unnoted). `Enter` opens one in a tab, `c` reads its uncommitted changes, `u` asks GitHub or Jira whether the items of up to 20 worktrees per press are merged or closed (a badge only, nothing is removed), `d` asks and then `d` again removes (Enter or Esc keeps it). Removal is never forced and refuses the main worktree, a locked or missing one and one with uncommitted changes. Only a branch Plotroom noted for a pull request or issue (kept in the checkout's own git config) is deleted with its worktree, and then like Remove worktree below; a worktree marked Unnoted keeps its branch. At most 200 rows and 50 checkouts are read.
- Worktrees go in omp's worktree directory: `OMP_WORKTREE_DIR`, else omp's `worktree.base` setting, else `~/.omp/wt`; Plotroom has no folder setting of its own. The repository's saved checkout (Settings › Repositories; opening Plotroom inside a checkout, or a linked worktree of it, saves its main checkout) is only where the worktree is added from.
- A pull request's worktree is on its own head branch, tracking it on GitHub (a fork's as `<fork owner>/<branch>`, tracking the fork), so `git pull`, `git push` and `gh pr view` work inside it without arguments. A local branch of that name that already exists is used as it is, never moved. A worktree an earlier version made at the PR's folder (on `plotroom/<owner>/<repo>/pr-N`) is still reused.
- An issue's worktree is on the branch of its linked pull request when exactly one still has its branch on GitHub; with several, Plotroom asks which, or a New branch. A GitHub issue's linked PRs are those that close it; a Jira issue's are the pull requests of its repository whose title or head branch names its key. A new branch asks for the base branch it starts from (the remote's default first), fetches that base, and is named by the branch format.
- **Name formats** (Settings › Worktrees): the new issue branch (default `{github.user}/{key}-{slug}`; a repository can have its own, under Settings › Repositories) and the folder names of PR and issue worktrees (defaults `plotroom-{owner}_{repo}-pr-{key}` and `plotroom-{owner}_{repo}-issue-{key}`, where `{owner}` and `{repo}` are lowercase). A branch format takes `{key}` `{slug}` `{owner}` `{repo}` `{project}` `{github.user}` `{jira.user}`; a folder format takes `{key}` `{slug}` `{owner}` `{repo}` and no `/`. Both need `{key}`. `{github.user}` is the view's `gh` account, else `gh`'s active one; `{jira.user}` is your Jira sign-in's email before the `@`.
- Reused worktrees are never updated. The preview's worktree card shows `Up to date|Not at PR head` and `Clean|Uncommitted changes|Changes unchecked` badges (their tooltip is the one-line summary), its branch and path, and, when the worktree is not at the PR's head, the `git pull --ff-only` command for you to run. Its buttons: **Go to tab** while a tab works in it (else **Open in new tab**), and **Remove worktree**.
- **The card is read from git, not remembered.** After every refresh, Worktree press and removal (and when a checkout is saved) Plotroom lists the saved checkouts of the repositories on screen with `git worktree list`; it never asks per row. A worktree is a PR's when it is on the PR's head branch or in the folder the PR folder format names; an issue's when it is on the branch or in the folder the issue formats name now. So a block opened later, or after a plugin reload, shows the card and the row's **Worktree** badge of every such worktree, with no Worktree press; one you removed yourself leaves at the next refresh; and a read that fails changes nothing. `Up to date` compares the worktree's HEAD with the PR head the last refresh saw (a PR pushed since reads as it was until the next refresh). `Clean` / `Uncommitted changes` is read with `git status` for the selected PR only, once the cursor rests on it and again after each refresh; until then the badge says `Changes unchecked` and the row's badge has no colour.
- **Remove worktree** asks first (`d` or Remove removes it; Enter or Esc keeps it) and runs on the host that has the checkout: `git worktree remove` without `--force`, so git refuses a worktree with uncommitted changes and the card says why. Then its branch: a pull request's goes with `branch -D` only when `git merge-base --is-ancestor` finds every commit of it in the ref fetched for the PR (and that ref goes too), else with `branch -d`; an issue's goes with `branch -d`. A branch git keeps stays, with its ref, and the toast names it. Plotroom never runs `reset`, `clean`, `stash` or `prune`.
- **Setup commands** (Settings › Repositories) run in the new tab's shell when a worktree is *created*. They execute the PR's code (`pnpm install` runs its scripts), so leave them empty for repos that take untrusted PRs.
- **Actions** (Settings › Actions) become rows in the Agent picker (`a`, or the action bar's Agent button). Pull requests and issues each keep their own actions; the page lists both. Each has a name, a multi-line prompt (Edit… opens an editor; Enter is a new line, ⌘↵ saves, Esc cancels), an optional one-key shortcut (not a key the queue uses, as set in Settings › Keyboard shortcuts) and the views it is offered under; with none turned on it is offered under every view of its type. In a PR action's prompt, or a typed one, `{url}`, `{owner}`, `{repo}`, `{number}`, `{title}`, `{author}`, `{branch}` (the PR's head branch), `{base}` (the branch it merges into), `{remote}` (the checkout's git remote of the repository) and `{github.user}` (your GitHub login) become the PR's details, read fresh from GitHub; an issue's actions also take `{jira.user}`, and in a worktree `{base}` (the base a new branch was made from; empty when Plotroom reused a branch) and `{remote}`. Any other `{…}` stays as written. Actions are saved per machine, like views.
- **Default actions**: until you change a kind's actions, pull requests offer **Review** (an evidence-based review, posted only as you authorize), **Address feedback** (a fix-and-reply plan you approve before anything is pushed or posted) and **Watch** (keeps your own PR green until it merges, escalating what it may not decide), and issues offer **Implement** (features and tasks), **Fix** (bugs: reproduce, root cause, regression test) and **Plan** (an epic broken into tickets, filed as you approve; runs in the main checkout). They are written for omp in Plotroom's worktrees: they act as `{github.user}` through `gh auth token --user`, use `acli` for Jira, ask through omp's `ask` tool, and push or post nothing without your explicit answer. The first change on the page (an edit, a new action, a delete) saves them as yours. **Restore defaults**, shown while a kind lacks one, adds back each default no saved action is named like; an edited default keeps your text (delete it, then restore, to get the original back).
- **Action models**: an action's Model (empty: omp's default) starts its agent as `omp --model <model>`. Anything `omp --model` takes works: a role alias from your omp config (`@slow`, `@smol`, `@plan`), a fuzzy pattern (`opus`) or `provider/model-id`.
- **Where an action runs**: an action's Runs in is Worktree by default: the item's worktree, made first if needed. Pick Main checkout for actions that need no checkout of the item's branch (review a PR, break an epic into tickets): the agent starts in the repository's main checkout, with no worktree made and no setup commands. The prompt's variables are filled in either way, except `{remote}` and an issue's `{branch}` and `{base}`.
- **Where its agent opens**: by default in a New tab (the worktree's open tab, when there is one). Set an action's Opens in to Beside the queue to open the agent as a block beside the queue, in the queue's tab; a new worktree's setup commands still run in their own tab.

## Trust

- No shell: `gh`, `git`, `ssh -G` and `omp` run as argv arrays. If they are not on Tern's PATH, your login shell is run once to find them. The one exception is the agent block, which Tern starts through your login shell: Plotroom passes it `omp --model <model>` only for a model made of model-name characters (letters, digits, `@ . _ : / -`).
- Plotroom never persists integration credentials: `gh` tokens are fetched per call and `PLOTROOM_JIRA_API_TOKEN` is read from the environment only, never saved, logged or passed as an argument. `kv.json` is plaintext and holds what you saved: views (and their sort), agent prompts, shortcut keys, checkout paths, setup commands, name formats, logins, recent agent picks, agent links (item key, agent pane, host) and triage memory (item key, signature hash, snooze time). Text you type into an action or a setup command is stored as typed, so keep secrets out of it.
- Every command that writes to GitHub or Jira (assign, labels, transitions, re-run, draft pull request) is confirmed first, and the confirmed plan is what runs. Import is confirmed too, but only changes Plotroom's own saved views and actions.
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
| `plugin/flows.luau` | window side of the workflow commands: agent links and status, confirmed mutations, draft PR, export/import, open by URL, the palette list |
| `plugin/triage.luau` · `sorting.luau` · `portable.luau` · `board.luau` | seen/snooze memory, per-view sorts, export/import format and plan, the Worktrees view's model |
| `plugin/github.luau` · `jira.luau` · `tracker.luau` · `worktree.luau` · `process.luau` · `input.luau` · `keys.luau` · `prompts.luau` | `gh` search and writes, Jira through `acli` (and its REST API for transitions), tracker-neutral issues and name formats, worktrees and their inventory, argv process runner, text input (one line or many), the queue's rebindable keys, the default prompts |
| `plugin/tests/` | `regression.luau` (fake SDK), `check.luau` (pure asserts), `runtime.luau` (real-Tern smoke) |
| `scripts/check.py` | the gate; CI runs `--ci` (no smoke, Tern is not available there). Smoke runs on Tern 0.8.3 or 0.8.4 against temporary local repositories and a fake `gh`: worktrees, inventory, draft preview and push, triage/sort/board, URL, export/import, agents |

`link` and `install` are exclusive per id: switch with `tern plugin remove plotroom` / `tern plugin unlink plotroom` first.
