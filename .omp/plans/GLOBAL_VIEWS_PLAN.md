# Global views: drop repo/project scoping

## Context
Each Plotroom block now shows one repository (PR / GitHub-issue block) or one Jira project (issue block). The goal is to remove that scoping:
- "Filters" become **views**. Views search across all repositories/projects, and each view stores:
  - its integration (`github` | `jira`; the PR block only allows `github`),
  - its gh login (GitHub views),
  - a group-by property (default none),
  - the prompt ids offered under it.
- Settings become global:
  - views: per block type,
  - prompts: per block type, with the prompt↔view mapping on the view,
  - a repository → checkout map; per-repository branch format and setup commands,
  - a Jira project → repositories map,
  - one worktree root folder (relative paths resolve against the repository's checkout).
- When a worktree or prompt needs a mapping that doesn't exist, the window palette asks for it inline, then continues.
- User decisions:
  - each view has its own gh login;
  - a Jira project maps to many repositories (ask only when more than one is mapped);
  - each block has its own Views page;
  - grouping is configurable per view;
  - start fresh: new kv keys, old data ignored.

## Approach

Steps are ordered by dependency. Steps 1–2 change module APIs that step 4 consumes; run `python3 scripts/check.py test` only after step 8 (tests are rewritten in step 8).

### 1. Fetch layer: unscoped searches, explicit gh login
`plugin/github.luau`:
- Delete `M.account`, `M.setAccount`, `readAccounts`, `accountKey`, `MALFORMED` (L726-805) and `M.scopeProblem` (L807-836). kv `accounts` is no longer read.
- `searchAll(account: string?, query, qualifier, gql, jq, parse, shouldContinue, done)`:
  - drop the `repo` param, the scopeProblem gate (L876-882) and the account gate (L883-889);
  - build `query = query .. qualifier` (no `repo:` prefix);
  - pass `account` to `M.gh` and `observe` as now.
- New signatures. `account` nil or `""` = gh's active account; normalise `""` to nil at the top of each function:
  - `M.search(account: string?, query, shouldContinue, done)`
  - `M.issues(account: string?, query, shouldContinue, done)`
  - `M.checks(repo, number, account: string?, done, shouldContinue?)`
  - `M.issue(repo, number, account: string?, done, shouldContinue?)`
  - `M.pr(repo, number, account: string?, done)`
  - `M.clone(repo, path, account: string?, done)`

  Each one replaces its `M.account(repo)` gate with the passed `account`.
- In `M.gh` L559, change the not-signed-in message's tail from "or choose another account for this repository." to "or set another login on this view in Settings › Views."

`plugin/jira.luau`:
- `M.issues(query, shouldContinue, done)`:
  - drop the `project` param and its check (L242-244);
  - set the JQL to `"(" .. query .. ") ORDER BY updated DESC"`.
- `M.normalize(item, siteUrl)` derives the project from the key: `local project = string.match(key, "^(.-)%-%d+$")`. If it doesn't match, return the existing "without a key" error. Keep `key = lower(project) .. "#" .. key` and `repo = project`. Delete the `id` field (step 4 removes `Issue.id`).
- In `scopeProblem`, change the message at L172 to `"Unbalanced parentheses."`. The rest stays: quotes/parens must still balance because the query is wrapped in parentheses, and ORDER BY is still refused.

`plugin/github.luau` `normalizeIssue` (~L410-414): delete the `id = "n" .. n` field.

`plugin/tracker.luau`: delete `id` from `Issue` (L14).

### 2. Worktree layer: root folder, Jira worktrees inside a repository, path → item
`plugin/worktree.luau`:
- **`M.worktreesDir(place: string, checkoutRoot: string, done)`**:
  - `place == ""` → current behaviour (OMP_WORKTREE_DIR / omp `worktree.base` / `~/.omp/wt`).
  - `M.expandPath(place, HOME)` returns a path (absolute or `~/`) → use it.
  - Otherwise → `normalize(checkoutRoot .. "/" .. place)`. `normalize` is a new local that collapses `.` and `..` segments and repeated `/` lexically. No equivalent exists; it is needed because `reconcile` compares the target with git's absolute paths.

  Doc comment: worktrees keep plotroom's leaf names (`plotroom-…`) whatever the folder.
- **`M.open(checkout, repo, number, place: string, account: string?, done)`**: `readPr` passes `account` to `github.pr`; `proceed` calls `M.worktreesDir(place, info.root, …)`.
- **`M.openIssue(checkout, repo, key, branch, place: string, done)`**:
  - `repo` is always a GitHub `owner/name`;
  - `issueSlot` keeps only the owner/name branch (delete the Jira branch L850-852);
  - `proceed` calls `M.worktreesDir(place, info.root, …)`.

  So a Jira issue `ABC-12` worked in `o/r` lives in `plotroom-o_r-issue-ABC-12` with base ref `refs/plotroom-base/o/r`. Its branch-format hint "change the branch format in Settings › Worktrees" becomes "Settings › Repositories".
- **`M.validProject(repo)`**: true for a valid `owner/name` (`validSegment` on both parts) or `tracker.jiraProject(repo)`. It validates issue links; it is no longer derived from `issueSlot`.
- **`M.resolveRepository`**: delete the Jira branch (L340-346).
- **`M.claimCheckout(path, repo, account: string?, done)`**: delete the Jira refusal (L380-385); pass `account` to `github.clone`.
- **Replace `M.prOfPath` and `M.issueOfPath` with `M.itemOfPath(path: string): (string?, string?)`**. It returns the item key and `"pr"` | `"issue"`, or nil, from the first `/plotroom-<leaf>` segment of `path` (leaf ends at the next `/` or the end of the string):
  - `^plotroom%-([%w%-]+)_(.+)%-pr%-(%d+)$` → `lower(owner/name) .. "#" .. n`, `"pr"`. GitHub owners hold no `_`, so splitting at the first `_` is unambiguous.
  - `^plotroom%-(.+)%-issue%-([%w_%-]+)$`:
    - if the ref matches `^([A-Z][A-Z0-9_]+)%-%d+$` → `lower(project) .. "#" .. ref`, `"issue"` (any slot, so old `jira.abc` worktrees still match);
    - else the slot must be `<owner>_<name>` → `lower(owner/name) .. "#" .. ref`, `"issue"`.
  - Legacy `.plotroom/<owner>/<name>/pr-<n>` (old `prOfPath` mark) → PR key.

  Callers: host `openItems` (step 4) and window `targetPane` (L166-178), which compares against the target's key: PR `lower(repo).."#"..n`; issue `lower(repo).."#"..ref` with `repo` the GitHub owner/name or the Jira key, i.e. `string.lower(project) .. "#" .. ref` for Jira. Grep `prOfPath|issueOfPath` must then return nothing.

`plugin/tracker.luau`:
- `M.VARS = { "key", "slug", "owner", "repo", "project" }` (one list, since the branch format is per repository now).
- `M.formatProblem(fmt)` and `M.branchName(fmt, vars)` drop the `trackerId` param.

Smoke harness:
- `plugin/tests/runtime.luau` passes `""` as `place` (and `nil` account to `worktree.open`).
- `scripts/check.py` `sc_jira_issue`:
  - request `s.open_issue("o/r", "ABC-7", branch, root)`;
  - expect directory `s.tmp / "omp-wt" / "plotroom-o_r-issue-ABC-7"` and ref `refs/plotroom-base/o/r` (rename its check label accordingly);
  - docstring: the base comes from the GitHub repository's remote.

### 3. Host storage (new kv keys; old keys never read or written)
In `plugin/host.luau` storage section (L166-394), replace the filters/prompts/repos/setup/branches helpers.

| kv key | shape |
|---|---|
| `views-prs`, `views-issues` | `{version=1, nextId, items=[View]}`; `View = {id, name, integration: "github"|"jira", query, login: string?, group: string, prompts: {string}}` |
| `prompts-prs`, `prompts-issues` | `{version=1, nextId, items=[{id, name, text, key?, worktree?}]}` (no `filters`) |
| `checkouts` | `{[lower "owner/name"]: path}`; `""` = listed in Settings without a checkout |
| `branch-formats` | `{[lower "owner/name"]: format}` |
| `setup-commands` | `{[lower "owner/name"]: {string}}` |
| `jira-repos` | `{[KEY]: {lower "owner/name"}}` |
| `worktree-root` | string, absent = `""` |

- **Views store** (rename `Filter`/`Store`/`seeds`/`validStore`/`writeStore`/`loadStore` to `View`/`Views`/`seedViews`/`validViews`/`writeViews`/`loadViews`, keyed by `kind.viewsKey`). `validViews` rejects:
  - an integration outside `kind.integrations`;
  - a `login` that is not nil and doesn't match `^[%w%-]+$`;
  - a non-string `group`;
  - a non-array or non-string `prompts`.

  Otherwise it keeps the current load / seed / fail-closed rules and messages, with "filters" → "views" in the text.
- **Prompts** (`loadPrompts`, `editPrompts`, keyed by `kind.promptsKey`): drop `filters` from validation and writes. Delete `scopeOf`.
- **Repository maps**:
  - `readCheckouts()` (was `readRepos`);
  - `checkoutOf(repo)` reads `readCheckouts()[string.lower(repo)]`;
  - `saveCheckout(repo, path, keep?)` writes `checkouts` (same fail-closed logic);
  - `setupMap`/`setupOf`/`branchMap`/`branchFormatOf` key by `string.lower(repo)` on `setup-commands` / `branch-formats`.
  - Delete `projectKey`.
- **New `readJiraRepos(): ({[string]: {string}}?, string?)`**: fail-closed like `setupMap`, message "Saved Jira project repositories could not be read."
- **New `jiraReposOf(project): {string}`**: valid `owner/name` strings only, in saved order.
- **New `editJiraRepos(fn): string?`**: read, mutate, `kvSet("jira-repos")`, "Could not save: …".
- **New `readWorktreeRoot(): string`**: pcall `kv.get("worktree-root")`; non-string → `""`.
- **New `removeRepo(repo): string?`**: deletes the repository from `checkouts`, `branch-formats`, `setup-commands` and from every `jira-repos` list. Each map is written only if it was readable.

### 4. Host engine: views drive search, ids, grouping
`plugin/host.luau`.

**Kinds.** Delete `JIRA`, `setKind`, `showRepo`, `showJira`, `validFor`, `REPOS_HREF` uses on the queue, `NO_REPO`, `useRow`.
- New `Kind` = `{id, title, one, many, icon, pages, viewsKey, promptsKey, integrations: {string}, seeds: {View}, keys, vars}`.
- **PRS:**
  - `title="GitHub PRs"`, `pages={"views","prompts","repos","connection"}`, `viewsKey="views-prs"`, `promptsKey="prompts-prs"`, `integrations={"github"}`;
  - seeds: `{id="v1", name="My PRs", integration="github", query="is:open author:@me", group="none", prompts={}}` and `{id="v2", name="Review requested", query="is:open review-requested:@me", …}`.
- **ISSUES:**
  - `title="Issues"`, `pages={"views","prompts","repos","jira","connection"}`, `viewsKey="views-issues"`, `promptsKey="prompts-issues"`, `integrations={"github","jira"}`;
  - seeds: v1 "Assigned to me" `is:open assignee:@me`, v2 "Created by me" `is:open author:@me` (both github, group "none").
- **New `INTEGRATIONS`:**
  - `github = {label="GitHub", newQuery="is:open involves:@me", hint="GitHub search syntax, across every repository the login can see; repo:, org: and user: narrow it.", linked="Linked pull requests"}`;
  - `jira = {label="Jira", newQuery="assignee = currentUser() AND statusCategory != Done", hint="JQL across every project, listed newest update first, so leave out ORDER BY.", linked="Linked issues"}`.
- **New `trackerOf(state): string`**: the active view's integration, else `kind.integrations[1]`.
- Replace every `state.kind.tracker`:
  - with `trackerOf(state)` for searches, waits, heads/help and the Connection page;
  - with `item.tracker` (issues) or `"github"` (PRs) where an item is at hand: `itemActions` Open label uses `INTEGRATIONS[…].label`; `linkedNodes` takes the item's tracker for `linked` and its icon; `loadDetails` uses `TRACKERS[item.tracker]`.

  The grep `kind%.(tracker|site|place|pickHref|filtersKey|newQuery|linked)` must return nothing.
- `TRACKERS`:
  - `search(account: string?, query, live, done)`; jira = `function(_, q, live, done) jira.issues(q, live, done) end`;
  - delete `scope`;
  - github `detail` passes `login(state)` (make `detail` take `(item, account, done, live)`).

**State** (L119-157):
- delete `repo`, `resolving`;
- keep `launchCwd`, `claiming` (now the lowercase repo whose checkout row is busy), `account` (`""` = active gh account);
- `applied` holds the snapshot key it was fetched under.

**Identity and search:**
- `identify(state)`: `account = activeView.login or ""` (jira: `""`); if it changed → `forget`. No problem path.
- `snapKey(state, v)` = `v.integration .. "\0" .. account .. "\0" .. v.query`.
- `stale(state, v)` = `snapKey(state, v) ~= state.applied`.
- `refresh`:
  - drop the repo / `resolveRepo` branch (L826-833);
  - dispatch `github.search(login(state), query, current, landed)` (PRs) or `TRACKERS[trackerOf(state)].search(login(state), query, current, landed)`;
  - `waitOf`, the interval branch (L898-912) and the `github.accounts` warm-up switch on `trackerOf(state)`.
- Delete:
  - `resolveRepo`, `savedAccount`, `accountChanged`;
  - problem kinds `no-repo` and `account` from `TERMINAL`, `HEADS`, `HELP`, `JIRA_HEADS`, `JIRA_HELP`;
  - the `helpOf` no-repo branch.
- Rename identifiers: `activeFilter` → `activeView`, `switchFilter` → `switchView`, `updateFilter`/`addFilter`/`deleteFilter` → `updateView`/`addView`/`deleteView`. `filtered()` (local search) keeps its name.

**Picker ids (collision-free across repositories):**
- `itemId(item)` = `"n" .. (string.gsub(item.key, "[^%w%-]", function(c) return string.format("_%02x", string.byte(c)) end))`. Injective because `_` is itself encoded.
- `issueRow` uses `itemId(issue)` instead of `issue.id`; `itemOf` stays a scan over `itemId`.
- **`openItems(state)`**: returns a set of item **keys**: for each `tern.pane.list()` cwd, `worktree.itemOfPath(cwd)` whose kind matches the block (`"pr"` for prs, `"issue"` for issues). Every user switches to key lookup: `rowsOf` L2426 (`open[item.key]`), `itemActions` goto, `'g'` key L4021, preview chip L3239, `rowsOpen` cache string (sorted keys).

**Grouping:**
- New `GROUPS: {[kindId]: {[integration]: {{value, label, of: (any) -> string}}}}`:
  - prs/github: `repo` "Repository" (`pr.repo`), `author` "Author", `state` "State" (`STATE_BADGE[stateKind(pr)].text`), `review` "Review" (the review badge text `pickerItem`/`previewNodes` already compute, else "No review"), `checks` "Checks" (the checks badge text the row already uses, else "No checks"), `base` "Base branch";
  - issues/github: `repo` "Repository", `author` "Author", `state` "State" (`issueBadge(issue).text`), `assignee` "Assignee" (`assignees[1]` or "Unassigned");
  - issues/jira: `project` "Project" (`issue.repo`), `status` "Status" (`issueBadge(issue).text`), `type` "Type" (or "No type"), `priority` "Priority" (or "No priority"), `assignee` "Assignee" (or "Unassigned"), `reporter` "Reporter" (`issue.author`).

  Any other value (including `"none"`) = no grouping.
- `filtered()`:
  - add the active view's `group` to the cache check (`Visible.group`);
  - when a group spec applies, bucket the matching items by `of(item)`, order buckets by `string.lower(label)`, rebuild `items` in bucket order and emit `order` as `{group=label, label=label, count=#bucket}` followed by that bucket's ids.

  Navigation already walks `vis.items`, so headers are never selectable. `order` stays a `tern.json.array`.

**Sidebar:** in the issues block (more than one integration), each `scopes` entry gets `group = INTEGRATIONS[v.integration].label`; scopes are ordered github views then jira views, keeping store order within each.

**Heading:**
- title spans = `{ui.span(activeView and activeView.name or kind.title, "strong")}` plus the existing stale/partial marks (replaces the repo link L3503);
- delete the nocheckout notice (L3537-3551), `missingCheckout`, `needsCheckout`, `CHECKOUT_HREF`, the `.nocheckout` role suffix;
- empty text: `"No " .. many .. " match " .. v.name .. "."` / `"No saved views yet. Press s to add one."`;
- subtitle "Partial results: narrow this view".

**Actions / keys:**
- delete the `repos` action-bar entry, the `o` key, `pick-project` / `show-repo` / `show-jira` / `set-checkout` / `repos` events; remove `"o"` from `QUEUE_TAKEN`;
- `itemActions` always offers Worktree and prompt buttons (delete `made`);
- `w`, `a` and prompt shortcuts no longer call `needsCheckout`;
- key help:
  - delete the `o` rows;
  - PR `w` text → "Check it out in a worktree and open that in a new tab (Plotroom asks for the repository's checkout the first time)";
  - issue `w` text → "Create or reuse the selected issue's worktree on its own branch and open it in a new tab (Plotroom asks for the repository, and its checkout, the first time)";
  - `Tab` text "Switch between the view list and the …".

**Prompts offered:**
- `offered(state)`: active view `v`; `ids` = `v.prompts` filtered to existing prompts. If `#ids > 0`, offer those prompts (store order) with `here = true`; else every prompt with text, `here = false`.
- `menu` group = `"For " .. v.name` when `here`, else `"All prompts"`.

**init / save:**
- `save` returns `{version=2, launchCwd, activeViewId}` plus `pause = {kind, message}` for a terminal problem.
- `init`:
  - ignores saved state whose `version ~= 2` (fresh start);
  - restores `activeViewId` and the pause (when `launchCwd` matches, kinds auth/missing/not-found/invalid);
  - no repo.
- **Launch auto-map:** after the state is built, if `cwd` is known, `worktree.currentRepository(cwd, cb)`; in `cb`, if `found` and `checkoutOf(found.id) == nil` then `saveCheckout(found.id, found.checkout)`. Guard with `alive(state)`; ignore errors.

### 5. Settings pages
`PAGE_DEFS`:
- `views` = {label "Views", group "Queue", icon "funnel"}
- `prompts` = {"Prompts", "Queue", "app-omp"}
- `repos` = {"Repositories", "Code", "tree"}
- `jira` = {"Jira projects", "Code", "globe"}
- `connection` = {"Connection", "Connection", "globe"}

Delete the `filters`, `github`, `source`, `worktrees` pages. `s` opens `views`. `probeClis` runs when the `jira` page opens (was `source`).

**Views page** (section `view:<id>`, title name + " · active"):
- Rows:
  - `name:<id>` text;
  - `vint:<id>` (only when `#kind.integrations > 1`), single-choice chips, options `{value="github",label="GitHub"},{value="jira",label="Jira"}`;
  - `query:<id>` text mono, hint `INTEGRATIONS[v.integration].hint`;
  - `vlogin:<id>` (github views only), text, label "GitHub login", placeholder "Active gh account", hint "The search runs as this login, so @me means it. Empty: gh's active account.";
  - `vgroup:<id>`, single-choice chips, options `{value="none",label="None"}` + `GROUPS[kind.id][v.integration]`, label "Group by";
  - `vprompts:<id>`, multi chips, options = every prompt `{value=id,label=name}`, label "Prompts", hint "Offered under this view. None: every prompt.";
  - `delete:<id>`.
- Section `new`: `add` "Add view", hint "Starts as " .. label .. ": " .. newQuery .. "." (first integration).
- Lead: "Saved searches for the sidebar. GitHub views search every repository the view's login can see; Jira views search every project acli can see."
- **Single-choice chips:**
  - In `toggleScope`, rows `vint:`/`vgroup:` set the value to `{option}` instead of toggling.
  - In the window `change` event, take the first element of `ev.value` that differs from the stored value; ignore an empty array.
  - `vprompts:` uses the existing membership toggle (the old `pscope` code path, retargeted to `updateView`).
- **Commits** (`commitEdit`):
  - `query:` validates with `jira.scopeProblem` only for jira views;
  - `vlogin:` empty → nil, else must match `^[%w%-]+$` ("A GitHub login has letters, digits and hyphens only.");
  - an integration change sets `query = INTEGRATIONS[new].newQuery`, `login = nil`, `group = "none"`.
  - Any change to the active view's integration/query/login runs `changed(state)`; every write runs `propagate`.
  - `resetRow` for `vlogin:` clears it.

**Prompts page:** delete the `pscope` row and `setScope`. Lead mentions "Offer a prompt under particular views from Settings › Views."

**Repositories page:**
- Section `sec-wtroot` "Worktrees": row `wtroot` text mono, label "Folder", placeholder "omp's worktree folder", hint "Where new worktrees go. A relative path is resolved against each repository's checkout, such as ../worktrees. Empty: omp's folder.". Commit: write `worktree-root` (`""` allowed); `resetRow` → `""`.
- Per repository in `readCheckouts()` sorted by key, section `repo:<repo>` with title `<repo>`:
  - `checkout:<repo>`: the existing claim flow L2190-2225 parameterised by the row's repo; `claimCheckout(path, repo, login(state), cb)`; disabled "Checking the folder, or cloning into it…" while `state.claiming == repo`;
  - `branch:<repo>`: "Format (issue worktrees)", hint "Variables {key} {slug} {owner} {repo} {project}. Empty: {key}-{slug}.";
  - `setup:<repo>:<i>` and `setup:<repo>:new`: the existing setup rows;
  - `rremove:<repo>`: action `delete` → confirm → `removeRepo`.

  Parse row ids with `^checkout:(.+)$`, `^branch:(.+)$`, `^setup:(.+):(%w+)$`, `^rremove:(.+)$`.
- Section `rnew`: `radd` "Add repository", act `add-repo` → `state.cx:open("plotroom://repos")`.
- Lead: "Repositories you work in, each with its local checkout (used for worktrees and prompts), the branch format of its issue worktrees and setup commands. Opening Plotroom inside a checkout adds it."

**Jira projects page:**
- Per key in `readJiraRepos()` sorted, section `project:<KEY>`:
  - `jrepos:<KEY>`: multi chips, options = every repository in `checkouts`, values = `jiraReposOf(KEY)`; disabled "Add a repository first." when `checkouts` is empty; hint "Asked on first use when none is set; asked each time when several are.";
  - `jremove:<KEY>`: delete (confirm).
- Section `jnew`: `jadd` "Add project", act `add-jira` → open `plotroom://jira-projects`; disabled with the existing "Checking whether acli is installed…" / not-installed texts from `useRow`.

**Connection page:** the existing `status-line` Refresh section plus the quota meter (when `trackerOf(state) == "github"`, `github.quota(login(state))`). Lead "Views refresh every minute; GitHub views pace themselves to the login's API quota."

**Settings confirm:** `confirm` covers `delete:`, `pdelete:`, `rremove:`, `jremove:`.

**Host events:**
- `add-repo` (value `owner/name`, validated as `showRepo` did) → `saveCheckout(repo, "", true)`, then `openSettings(state, "repos", "checkout:" .. lower, true)`.
- `add-jira` (key, uppercased, `tracker.jiraProject`) → `editJiraRepos` adding `[KEY] = existing or {}`, then `openSettings(state, "jira", "jrepos:" .. KEY, false)`.

### 6. Window ↔ host: inline mapping in the palette
Bump `RPC_PROTOCOL` (host L2596) and `PROTOCOL` (window L27) to `"8"`.

**Host `prepare` (PR):**
- no checkout, or `worktree.NO_REPO` → `reply {needCheckout = lower(repo)}`;
- otherwise `worktree.open(checkout, repo, n, readWorktreeRoot(), login(state), cb)`;
- delete every `openSettings(… "worktrees" …)` call.

**Host `prepareIssue(state, id, repo, ref, wt, target: string?)`:**
- the code repository is `issue.repo` for GitHub issues;
- for Jira (`m = jiraReposOf(issue.repo)`):
  - `target` set → must be in `m`, else `{problem = target .. " is not a repository of " .. issue.repo .. "."}`;
  - `#m == 0` → `{needRepo = true, project = issue.repo, repos = <sorted checkouts keys>}`;
  - `#m == 1` → use it;
  - `#m > 1` → `{chooseRepo = true, project = issue.repo, repos = m}`.
- Then: no checkout / `NO_REPO` → `{needCheckout = code}`; `issueBranch(issue, code)`; `worktree.openIssue(checkout, code, ref, branch, readWorktreeRoot(), cb)`; `setupLine(code)`.
- `issueBranch(issue, code)`: `owner`/`repo` come from `code`; `project = issue.repo` for Jira, else `""`.

**New rpc ops:**
- `checkout` `{repo, path}` (any block):
  - repo is `owner/name` with `validSegment`; path is a non-blank string ≤ 4096 bytes;
  - `worktree.expandPath(trim(path), HOME)` else `{problem="That is not a usable path."}`;
  - set `state.claiming`, `worktree.claimCheckout(path, repo, login(state), cb)`, `saveCheckout(repo, root)`;
  - reply `{ok=true, root, cloned}` or `{problem}`.
- `map-jira` `{project, repo}` (issues block): validate both, `editJiraRepos` to append the lowercase repo if absent, `saveCheckout(repo, "", true)`; reply `{ok=true}` or `{problem}`.

**`issue` op:** accepts an optional `target` (`owner/name`). Drop the `jiraProject(repo) ~= (tracker == "jira")` check at L3001.

**`repos` op:** items from `readCheckouts()`, without `current`. **`profile` op:** drop `current`. **`jira-projects` op:** saved rows = `readJiraRepos()` keys with `repos = table.concat(jiraReposOf(key), ", ")`, without `path`/`current`.

**Window (`plugin/window.luau`):**
- `prepareTarget(cx, pane, t, prompt?, wt, target: string?)` sends `target` in the `issue` request and handles the new answers before `readyOf`:
  - **`needCheckout`:**
    - `cx2:prompt({placeholder = "Folder of your checkout of " .. a.needCheckout .. " (a new or empty folder gets a clone)", icon = "merge", action = "save"})`;
    - non-blank text → `ask(cx3, pane, "checkout", {repo = a.needCheckout, path = text}, CLONE_WAIT_MS, …)` where `CLONE_WAIT_MS = 11 * 60 * 1000` (longer than github `CLONE_MS`);
    - on `ok` → toast success (`"Cloned " .. repo` when `cloned`, else `"Checkout saved"`, detail `root`), then `prepareTarget(cx4, pane, t, prompt, wt, target)`;
    - on `problem` → toast error "Checkout not saved".
  - **`needRepo`:**
    - `cx2:pick` items: each `a.repos` entry `{label=repo, group="Repositories"}` + `{label="Other repository…", detail="Type owner/name", typed=true}`; placeholder `"Repository for Jira project " .. a.project .. "…"`, icon "merge", action "map";
    - typed → `cx:prompt` "owner/name";
    - then `ask "map-jira" {project, repo}` (MENU_MS) → on ok `prepareTarget(…, repo)`.
  - **`chooseRepo`:** `cx2:pick` of `a.repos`, placeholder `"Which repository for " .. t.label .. "?"`, action "open" → `prepareTarget(…, picked.label)`.

  Remove the `noRepo` toast.
- **Settings pickers:**
  - `pickRepo`/`pickProfile` send `{act="add-repo", value=repo}` (replace `showRepo`); placeholders "Add repository…" / "Add repository of @login…"; delete `current` handling.
  - `pickJira` sends `act="add-jira"`; saved rows' detail = `it.repos ~= "" and it.repos or "No repositories yet"`; placeholder "Add Jira project…".
- **Remove:** the `plotroom://checkout` route, the `repo` palette command (L~890), `showRepo`.
- **Copy:** `pickAgent` detail "Save prompts in Settings › Prompts (s)" stays.

### 7. Styles, manifest, copy
- `plugin/plotroom.css`: delete the `.nocheckout` rules and their comment (L114 to the end of that block).
- `plugin/plugin.toml` `description`: "A live GitHub pull request queue and GitHub or Jira issue list with saved views across repositories and Jira projects, Browser links, worktrees and agents."
- Grep `-i "filter"` in `plugin/*.luau` user-facing strings: rename to "view", except the local search placeholder "Filter the loaded …".

### 8. Tests (`plugin/tests/regression.luau`, `check.luau`)

**Harness:**
- `hostScene`/`openQueue`/`issueHost`/`openIssues` stay; the launch dir now only auto-maps the checkout.
- `jiraHost` seeds:
  - `checkouts = {["o/r"]="/work/r"}` with origin `https://github.com/o/r.git` (not gitlab);
  - `jira-repos = {ABC={"o/r"}}`;
  - `views-issues` with one jira view whose query yields `JIRA_ASSIGNED = "(assignee = currentUser() AND statusCategory != Done) ORDER BY updated DESC"`.
- `openJira` opens `issues` with saved `{version=2, launchCwd="/work/r", activeViewId=<jira view>}`.
- `savePrompts`/`saveIssuePrompts` write `prompts-prs`/`prompts-issues` without `filters`.

**Delete** (behaviour removed):
- account store: 3713, 3740, 3762, 3771, 6459, 6522, 6545;
- scopeProblem refusal: 3957, 4142 and the widening part of 4313;
- launch-dir no-remote problem: 5155;
- no-checkout heading: 5934, 7084;
- show-repo / repos picker as shown repo: 5965, 5979, 3089 (rewrite as Add-repository);
- Integration page: 7975;
- project pickers: 8229 (rewrite for the `jira-projects`/`repos` answers);
- 2547 rewritten under `worktreesDir`;
- remove `check.luau` asserts for `scopeProblem` (github), `prOfPath`, `issueOfPath`, and tracker `trackerId` args.

**Rewrite to the new contract**, keeping the behaviour they guard:
- search query assertions (`fields.q` no longer contains `repo:`; e.g. 4325/7252 expect `"is:open assignee:@me is:issue sort:updated-desc"`);
- Jira JQL (4566, 4659, 7940);
- Settings page/tab cycles (5450 → Views, Prompts, Repositories, Connection; issues adds Jira projects);
- seeds (5417, 7237);
- prompt chips (5619 → view `vprompts`), menu ordering (5809, 3168);
- setup/branch per repo (5366, 7464, 7552, 7595, 8108 with `branch-formats`/`setup-commands` keyed `o/r`);
- checkout claim/clone (6170, 6205, 6240 via `checkout:o/r` row);
- 3552 / 7731 / 7436 / 8378 (no checkout → the new palette flow);
- 4126, 4227, 4467, 4503, 6498, 6896 (account per view instead of per repo);
- smoke-equivalent 2766/2816 (Jira issue worktree in repo `o/r`).

**New cases** (each must fail if its logic breaks):
1. `github.search: no repo qualifier, runs as the view's login`: view login `work` → the gh call carries `GH_TOKEN` of `work`; `fields.q == "is:open author:@me is:pr sort:updated-desc"`.
2. `host: items from two repositories with the same number get distinct ids`: `o/a#12` and `o/b#12` both listed; a `select` on the second's id puts the cursor on `o/b#12`; the `w` link names `o/b`.
3. `host: view group-by emits headers`: group `repo` over items from `o/b`, `o/a`, `o/b` → `order == {{group="o/a",label="o/a",count=1}, <id a>, {group="o/b",…,count=2}, <id b1>, <id b2>}`; group `none` → no table entries.
4. `host: view prompts limit the menu`: prompts p1, p2; view lists {p2} → `menu` items == {p2} with group "For <view>"; empty list → both, group "All prompts".
5. `host: switching a view's integration resets its query, login and group`.
6. `window: PR worktree without a checkout asks for one, then continues`: `needCheckout` → prompt answered `/work/r` → `checkout` op saves `checkouts["o/r"]` → second `worktree` request → "Worktree ready for o/r#1".
7. `window: Jira issue picks its repository`:
   - 0 mapped → pick `o/r` → `jira-repos.ABC == {"o/r"}` → worktree `plotroom-o_r-issue-ABC-12`;
   - 2 mapped → `chooseRepo` pick → no kv write;
   - 1 mapped → no picker.
8. `worktree: worktree root`: `""` → OMP dir; `/abs/wt` → `/abs/wt/plotroom-o_r-pr-1`; `../wt` with checkout `/work/r` → target `/work/wt/plotroom-o_r-pr-1`.
9. `check.luau`: `itemOfPath` returns `("o/r#12","pr")` for `/x/plotroom-o_r-pr-12/sub`, `("abc#ABC-7","issue")` for `/x/plotroom-o_r-issue-ABC-7` and `/x/plotroom-jira.abc-issue-ABC-7`, `("o/r#7","issue")` for `/x/plotroom-o_r-issue-7`, nil for `/x/plotroom-o_r-prx`.
10. `host: removing a repository drops it from jira-repos, branch-formats and setup-commands`.
11. `host: launch dir maps its checkout once`: an empty `checkouts` gets `o/r=/work/r`; an existing `o/r=/elsewhere` is kept.

**Bench:** `hostScene(w, 0)` + 1000 PRs; budget unchanged.

## Critical files & anchors
- `plugin/host.luau`:
  - storage L166-394; identity/search L586-924; picker ids L490-529; `filtered` L541-575;
  - Kinds L1205-1330; `pageContent` L1450-1694; `commitEdit` L2076-2227;
  - rpc L2589-3010; `queuePicker` L3485-3624; init/save L3771-3866 / L4176-4184; key/event handlers L3872-4174.
- `plugin/github.luau`: account store / scope L726-836; `searchAll` L859-942; `checks`/`issue`/`pr`/`clone` gates (L1064, L1137, L1181, L575).
- `plugin/worktree.luau`: `worktreesDir` L485-500; `M.open` L673-840; `issueSlot`/`openIssue`/`issueOfPath` L845-1012; `resolveRepository`/`claimCheckout` L325-403; `prOfPath` L465-479.
- `plugin/window.luau`: `targetPane` L166-178; `prepareTarget` L446-475; pickers L551-650; `handle` L663-680; commands L820-894; `PROTOCOL` L27.
- `plugin/tests/regression.luau`: scene helpers (5010-5027, 7115-7199), cases as listed in step 8.

## Verification
1. `cd /Users/user/Code/andyhite/tern-plotroom && python3 scripts/check.py`. It must print `REGRESSION cases=N failed=0`, report no luau-lsp diagnostics, keep bench rows under 250 ms, and pass all 11 smoke scenarios. That includes `jira issue worktree` (now `plotroom-o_r-issue-ABC-7`) and `remote host`, where the launch dir auto-maps `o/remote`, so the worktree needs no palette prompt. Prerequisites: `python3 scripts/check.py tools` done once; Tern 0.8.3, git ≥ 2.36, `omp` on PATH.
2. New-behaviour checks: regression cases 1–11 in step 8 (run via `python3 scripts/check.py test`).
3. Manual, with `tern plugin link ./plugin` and a reload:
   - **PR block:** "My PRs" lists PRs from several repositories. Settings › Views › Group by "Repository" shows one header per repository with counts.
   - **Issues block:** add a view and pick Jira; the sidebar shows "GitHub" and "Jira" headers.
   - On a Jira issue, press `w` with no mapping: the palette asks for the repository, then (if unset) for its checkout folder, then opens the worktree tab `plotroom-<owner>_<name>-issue-<KEY>`.
   - Set Settings › Repositories › Folder to `../worktrees`; `w` on a PR makes `<checkout>/../worktrees/plotroom-…`.

## Assumptions & contingencies
- **Repositories are GitHub `owner/name` repositories.** Jira projects map only to those, and a checkout must have a github.com remote. The old ability to make a Jira worktree from a non-GitHub checkout (e.g. a gitlab origin) is dropped. If non-GitHub checkouts are needed, stop and say so before step 2.
- New issue views default to GitHub; Jira views are added with Add view + the integration chips. There are no Jira seeds.
- Clone-from-Settings and inline checkout claims run as the block's active view's login (the active gh account for Jira views).
- Grouping headers sort alphabetically by label (case-insensitive).
- If Tern's prefs `multi` control mishandles a single selection in step 5's single-choice chip rows (e.g. it sends unexpected arrays), implement `vint`/`vgroup` as action rows that cycle to the next option on Enter, with the current option as the hint.
- If the picker rejects mixed string/table `order` entries at runtime (step 4 grouping), emit headers only via `order` as the Tern docs specify (`{group,label,count}`) and verify with `tern plugin types`. If it still fails, stop and report rather than inventing another grouping mechanism.
