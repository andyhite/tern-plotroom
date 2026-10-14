# Plotroom: GitHub Issues block

## Context

Add a second Tern block, `plotroom.issues` ("Plotroom · GitHub Issues"), that works like the PR queue (`plotroom.prs`):
- an issue list in a picker, filtered by saved filters
- a sidebar with the selected issue's details
- saved prompts sent to agents. Each prompt is set to run either in the issue's worktree or in the repository's main checkout (always a new tab).
- create or reuse a worktree and branch per issue. The branch name format is set per repository.
- open the issue on the web
- switch repositories. The default is the cwd's repository.

GitHub Issues comes first. Jira and Linear follow soon, so issue data is held in a tracker-neutral `Issue` type, and GitHub calls sit behind one dispatch table.

Decisions already made (user):
- one shared engine in `host.luau` for both blocks
- branch format per repository, default `{key}-{slug}`
- issue prompts kept separate from PR prompts
- a typed prompt in the `a` picker runs in the worktree
- sidebar shows the body and linked PRs

## Approach

Order: step 1 is a pure refactor (the PR suite must stay green). Steps 2–3 add new modules and functions with no callers yet. Steps 4–6 wire the issues block. Step 7 adds tests. Run `python3 scripts/check.py test` after steps 1, 3, 5.

Dependency graph after this change (update nothing else):
- `host → github, input, process, worktree, tracker`
- `github → process, input, tracker`
- `worktree → process, github`
- `window → worktree`
- `tracker → input`

### 1. Make `host.luau` a two-kind engine (PR behavior unchanged)

1. Add a constant table type near the top of `host.luau`:
   ```lua
   type Kind = {
   	id: string,        -- "prs" | "issues" (block id)
   	title: string,     -- "GitHub PRs" | "GitHub Issues" (block title without a filter)
   	one: string,       -- "pull request" | "issue"
   	many: string,      -- "pull requests" | "issues"
   	icon: string,      -- picker icon: "merge" | ISSUE_ICON
   	filtersKey: string, -- kv: "filters" | "issue-filters"
   	promptsKey: string, -- kv: "prompts" | "issue-prompts"
   	seeds: { Filter }, -- first-run filters
   	keys: { KeyHelp }, -- the `?` list of the queue
   	vars: { { k: { Span }, v: string } }, -- prompt editor legend
   }
   ```
   Define `PRS: Kind` with today's values:
   - `seeds()` items, nextId 3
   - `QUEUE_KEYS` → `PRS.keys`
   - `PROMPT_VARS` → `PRS.vars`
   - `local ISSUE_ICON = "circle-dot"`

   `ISSUES` comes in step 4. Add `kind: Kind` to `State`.

2. Snapshot items become kind-neutral:
   - `Snap.prs` → `Snap.items: { any }`
   - `Visible.prs` → `Visible.items: { any }`
   - Every reader of `.prs` in host.luau becomes `.items`: `selectedPr`, `prOfItem`, `filtered`, `ensureCursor`, `prune`, the `refresh` result store, `moveCursor`, `rowsOf`, scope counts in `queuePicker`, and `title`.
   - Rename `selectedPr` → `selected(state): any` and `prOfItem` → `itemOf(state, id): any`. PR-only code assigns the result to a `github.Pr` local.
   - In `refresh`, store `items = result.prs` (issues: `result.issues`).
   - The search call branches: `if state.kind.id == "issues" then TRACKERS.github.search(...) else github.search(...)`.

3. Kind-aware helpers, each replacing its PR-only version at every call site:
   - `itemId(state, item)`: `"n" .. item.number` (prs) or `"n" .. item.ref` (issues).
   - `matchItem(state, item, text)`: `github.match` (prs) or `tracker.match` (issues).
   - `openItems(state): { [string]: boolean }`: keyed by itemId. It replaces `openPrs`. PRs use `worktree.prOfPath`; issues use `worktree.issueOfPath`.
     - `rowsOf` builds `openKey` from the sorted itemIds.
     - `prActions`, `previewNodes` and the `g` key check test `open[itemId(state, item)]`.
   - `hrefOf(state, item, act): string`: the link for `open|worktree|goto|agent`. For prs it is `prHref`; for issues see step 4.
   - `runHrefOf(state, item, promptId)`: same split.
   - `openSelected` uses `hrefOf`; the prompt-shortcut key path uses `runHrefOf`.

4. Storage takes the kind. Every caller passes `state.kind` (`init` passes `kind`):
   - `seeds(kind)`, `loadStore(kind)`, `writeStore(kind, store)` use `kind.filtersKey` and `kind.seeds`.
   - `loadPrompts(kind)` and `editPrompts(kind, fn)` use `kind.promptsKey`.
   - Callers today: `reloadStore`, `updateFilter`, `addFilter`, `deleteFilter`, `init` / `editPrompts`, `pageContent`, `beginEdit`, `offered`, `confirmOverlay`, `settingsView` / `addPrompt`, `deletePrompt`, `setScope`, `commitEdit` (pkey, pname/ptext).
   - Find them all with `grep -n "loadStore(\|writeStore(\|loadPrompts(\|editPrompts(\|seeds(" plugin/host.luau`.

5. Text from the kind:
   - `HEADS.failed` stays for prs. Add `local function headOf(state, k): string` returning `HEADS[k]` or, for `failed`, `"Could not load " .. state.kind.many`. Use it at the 3 `HEADS[...]` sites.
   - The picker takes these from the kind: `icon`, `noun = kind.many`, `placeholder = "Filter the loaded " .. kind.many`, and the empty text `"No " .. kind.many .. " match " ..`.
   - `helpOverlay` uses `state.kind.keys`; its shortcut line uses `kind.one`.
   - `settingsView` legend uses `state.kind.vars`.
   - `title` falls back to `state.kind.title`.

6. Block definition:
   - Wrap the `tern.block.define("prs", {...})` table in `local function blockDef(kind: Kind): BlockDef<State>`; `init` sets `kind = kind`.
   - The `previous` reuse in `init` also requires `previous.kind == kind`.
   - Register with `tern.block.define("prs", blockDef(PRS))`. The `issues` registration comes in step 4.

7. `noteWorktree` takes a neutral report so both kinds can note results:
   `noteWorktree(state, key: string, r: { path: string, branch: string, created: boolean, current: boolean, dirty: boolean?, summary: string, update: { string }, cleanup: { string } }?, problem: string?)`.
   The PR `prepare` builds `r` from `worktree.Result` with the same values as today (`current = r.head == r.prHead`, `summary = worktree.describe`, `update`/`cleanup` from worktree.luau) and uses key `string.lower(repo) .. "#" .. n`.

8. `Detail` gains `issue: tracker.IssueDetail?`. `loadDetails` branches on the kind to fetch (step 4). PR loads are unchanged.

9. In `previewNodes`, hoist the local `ref(key, label, name)` closure to module level as `refRow(key, label, name): Node`, unchanged.

Gate: `python3 scripts/check.py test types` passes with zero changes to PR test expectations, except fixtures that touch renamed internals (none are exported).

### 2. Tracker-neutral issue model + GitHub issue reads

New `plugin/tracker.luau` (`--!strict`, `local M = {}`, requires `./input`):

```lua
export type Issue = {
	key: string,      -- identity, lowercase "owner/repo#12" (github.identity)
	tracker: string,  -- "github"
	repo: string,     -- "Owner/Repo" as GitHub spells it
	ref: string,      -- "12" (Jira later "ABC-12"): links, {key}, directory names; matches ^[%w%-]+$
	id: string,       -- picker id "n" .. ref
	title: string, url: string, author: string,
	state: string,    -- "open" | "closed"
	reason: string?,  -- closed: "completed" | "not-planned" | "duplicate"
	labels: { string }, assignees: { string },
	comments: number, created: number, updated: number,
}
export type Linked = { ref: string, title: string, url: string, state: string } -- state "open"|"draft"|"merged"|"closed"
export type IssueDetail = { body: string, milestone: string?, linked: { Linked } }
export type IssueResult = { issues: { Issue }, total: number, complete: boolean }
M.FORMAT_DEFAULT = "{key}-{slug}"
M.VARS = { "key", "slug", "owner", "repo" }
```

Functions:
- `M.slug(title): string`
  - lowercase the title
  - turn every run of characters outside `[a-z0-9]` (so all non-ASCII bytes too) into one `-`
  - trim leading and trailing `-`
  - cut to 40 bytes, then trim trailing `-` again
  - an empty result is `"issue"`
- `M.formatProblem(fmt): string?`. Errors, in this order:
  - `"A format is required."` for a blank format
  - `"Unknown variable {x}."` for the first `{name}` not in VARS
  - `"Include {key}, so each issue gets its own branch."` when `{key}` is missing
- `M.branchName(fmt, vars: { [string]: string }): (string?, string?)`: runs `formatProblem` first, then `string.gsub(fmt, "{(%a+)}", vars)`.
- `M.match(issue, needle)`: a copy of `github.match` (the title range via `input.u16`). Its fallback haystack is `"#" .. ref .. " " .. author .. " " .. labels joined by space .. " " .. assignees joined`.
- `M.reconcile(issues)`: a copy of `github.reconcile`, typed to Issue.

In `plugin/github.luau` (add `local tracker = require("./tracker")`):

1. Extract the paging loop of `M.search` (L783–834) into a local function:
   ```lua
   searchAll(repo, query, qualifier: string, gql: string, jq: string,
   	parse: (string) -> ({ total: number, next: string?, cost: number, raw: number, items: { any } }?, string?),
   	shouldContinue, done: ({ any }?, number, boolean, Problem?, number) -> ())
   ```
   - It keeps the early checks (empty query, `scopeProblem`, `M.account`).
   - It builds the query as `"repo:" .. repo .. " " .. query .. qualifier`.
   - `done` gets `(items, total, complete, problem, spent)`.

   `M.search` calls it with:
   - qualifier `" is:pr sort:updated-desc"`
   - `SEARCH_GQL` and `SEARCH_JQ`
   - a `parse` that maps `M.parsePage`'s `prs` field to `items`

   `M.search` then reconciles with `M.reconcile` and calls `done({ prs = ..., total, complete }, nil, spent)`. Keep `parsePage`'s `prs` field as it is (check.luau asserts it).
2. Add `ISSUE_GQL`:
   `query($q: String!, $after: String) { rateLimit { cost } search(query: $q, type: ISSUE, first: 100, after: $after) { issueCount pageInfo { hasNextPage endCursor } nodes { ... on Issue { number title url state stateReason updatedAt createdAt author { login } comments { totalCount } labels(first: 10) { nodes { name } } assignees(first: 10) { nodes { login } } } } } }`

   Add `ISSUE_JQ`. Copy `SEARCH_JQ`'s `total`/`next`/`cost` expressions verbatim, then:
   `items:[.data.search.nodes[]|{number,title,url,state,reason:.stateReason,updatedAt,createdAt,author:.author.login,comments:.comments.totalCount,labels:[.labels.nodes[]?.name],assignees:[.assignees.nodes[]?.login]}]`
3. `M.normalizeIssue(item): (tracker.Issue?, string?)`:
   - Require a number and a URL matching `^https://github%.com/([%w%-_%.]+)/([%w%-_%.]+)/issues/(%d+)$` whose number equals `item.number`. Errors: `"the search returned an item that is not an issue"` / `"the search returned an issue with an unexpected URL"`.
   - Require a string title.
   - `state`: `CLOSED` → `"closed"`, else `"open"`.
   - `reason` map: `COMPLETED → "completed"`, `NOT_PLANNED → "not-planned"`, `DUPLICATE → "duplicate"`.
   - author `"ghost"` when missing.
   - `key = M.identity(o, r, n)`, `ref = tostring(n)`, `id = "n" .. n`, `tracker = "github"`.

   `M.parseIssuePage(stdout)` mirrors `parsePage`, with field `issues`.
4. `M.issues(repo, query, shouldContinue, done: (tracker.IssueResult?, Problem?, number) -> ())`:
   - Calls `searchAll` with qualifier `" is:issue sort:updated-desc"`, `ISSUE_GQL`, `ISSUE_JQ` and the issue parse.
   - Reconciles with `tracker.reconcile`.
5. Extract the body cleanup in `M.about` (L877–883: CURSOR_SUMMARY strip and the BODY_CHARS cut) into `local function cleanBody(raw: any): string`. `M.about` calls it.
6. `M.issue(repo, number, done: (tracker.IssueDetail?, Problem?) -> (), shouldContinue: (() -> boolean)?)`, shaped like `M.checks`:
   - Before sending: the same `superseded` finish, account refusal and rate-limit wait checks.
   - One call: `gh api graphql --hostname github.com --include -f query=ISSUE_DETAIL_GQL -f o=<owner> -f r=<name> -F n=<number> --jq ISSUE_DETAIL_JQ`
   - `observe` the headers.
   - `ISSUE_DETAIL_GQL`: `query($o: String!, $r: String!, $n: Int!) { rateLimit { cost } repository(owner: $o, name: $r) { issue(number: $n) { body milestone { title } closedByPullRequestsReferences(first: 10, includeClosedPrs: true) { nodes { number title url state isDraft } } } } }`
   - `ISSUE_DETAIL_JQ`: `(.data.repository.issue // {}) | {body, milestone: .milestone.title, linked: [(.closedByPullRequestsReferences.nodes // [])[] | {number, title, url, state, isDraft}]}`
   - `linked` state: `MERGED → merged`, `CLOSED → closed`, `OPEN` + isDraft → `draft`, `OPEN → open`.
   - Drop entries without a number, title or `https://` URL.
   - `body = cleanBody(raw.body)`; `milestone` is a non-empty string or nil.
   - Failure: `{ kind = "failed", message = "gh printed unexpected issue data." }`.

### 3. Issue worktrees in `worktree.luau`

1. Extract from `M.open` the closures `finish`/`attempt`/`run` (L518–549) into a module-level factory:
   ```lua
   type Steps<T> = { finish: (T?, string?, WindowCx?) -> (), attempt: (WindowCx?, () -> ()) -> (), run: (string, { string }, number, (string, WindowCx?) -> ()) -> () }
   local function steps<T>(done: Cb<T>): Steps<T>
   ```
   `M.open` uses `local s = steps(done)` with no behavior change.

   Hoist two more helpers:
   - `inspectPath(s, path, commonDir, want: string?, step: (head, dirty: boolean?, cx) -> ())`: the toplevel, common-dir, `rev-parse HEAD` and status steps of `inspect` (L564–603). `want` is the HEAD a created worktree must have.
   - `addWorktree(s, root, target, branch, sha: string?, step: (path, created, cx) -> ())`: the mkdir + `omp worktree add` + race-reuse of `add` (L618–656). `sha == nil` means attach `{target, branch}`; otherwise `{"-b", branch, target, sha}`.

   PR `inspect` and `add` call these and keep building `Result` exactly as today.
2. Generalize the `reconcile` target-exists message (L398) to `target .. " already exists and is not the worktree of " .. branch .. "; move it away or remove it."`. Update regression assertions that match the old wording (`grep -n "is not this PR's worktree" plugin/tests`).
3. Add:
   ```lua
   export type IssueResult = { path: string, root: string, remote: string, branch: string, key: string, created: boolean, head: string, dirty: boolean? }
   function M.openIssue(checkout: string, repo: string, key: string, branch: string, done: Cb<IssueResult>)
   ```
   Steps:
   1. Validate. Owner and name must pass `validSegment` (lowercased, as in `M.open`), `key` must match `^[%w%-]+$` and be at most 64 bytes, and `branch` must be non-empty. Otherwise finish with `"Invalid repository …"` or `"Invalid issue …"` (deferred with `tern.timer(0, …)`).
   2. `dirName = "plotroom-" .. owner .. "_" .. name .. "-issue-" .. string.lower(key)`; `baseRef = "refs/plotroom-base/" .. refPart(owner) .. "/" .. refPart(name)`.
   3. `M.resolveRepository(checkout, repo)`. On failure, finish with `M.NO_REPO`.
   4. Run `M.worktreesDir`, then `git -C root check-ref-format --branch <branch>`. A nonzero exit finishes with `"Branch name " .. branch .. " is not valid; change the branch format in Settings › Worktrees."`.
   5. `git worktree list --porcelain -z`. Main-worktree checks and `root` work as in `M.open`; `target = base .. "/" .. dirName`.
   6. If any record has `path == target`, reuse it whatever its branch. A locked, prunable or missing one finishes with reconcile's locked message. Reuse goes to inspect with `created=false`, `want=nil`, and `branch` = the record's branch with `refs/heads/` stripped (or the requested branch if detached).
   7. Otherwise `M.reconcile(recs, branch, target)`:
      - `reuse` → inspect that path with `created=false`
      - `error` → finish
      - `create` → step 8
   8. Check whether the local branch exists: `git rev-parse --verify --quiet refs/heads/<branch>`.
      - It exists: `addWorktree(..., sha=nil)` (attach; the branch is never moved), then inspect with `want = tip`.
      - Status 1: `git fetch --no-tags --no-write-fetch-head <remote> +HEAD:<baseRef>` (NET_MS), then `git rev-parse --verify --quiet <baseRef>` → `sha`; an empty `sha` finishes with the fetch error or `"Could not read the default branch of " .. repo .. "."`. Then `addWorktree(..., sha)` and inspect with `want = sha`.
      - Any other status: `"Could not inspect branch …"`.
   9. No `git config branch.*` call (no upstream: the user's first `git push -u` sets it).
4. Also add:
   - `M.describeIssue(r): string` → `(Created|Reused) .. " · " .. branch .. " at " .. short(head) .. " · " .. (Modified (uncommitted changes kept)|Clean|Changes unchecked)`.
   - `M.cleanupIssue(r): { string }` → the first two lines of `M.cleanup` (worktree remove, branch -d).
   - `M.issueOfPath(path, repo): string?`: mark `"/plotroom-" .. owner .. "_" .. name .. "-issue-"` (lowercased repo). The ref matches `^([%w%-]+)(.*)$` with the rest `""` or starting with `/`.

### 4. The issues kind in `host.luau`

1. Define `ISSUES: Kind`:
   - `id "issues"`, `title "GitHub Issues"`, `one "issue"`, `many "issues"`, `icon ISSUE_ICON`
   - `filtersKey "issue-filters"`, `promptsKey "issue-prompts"`
   - seeds `{ {id="f1", name="Assigned to me", query="is:open assignee:@me"}, {id="f2", name="Created by me", query="is:open author:@me"} }`, nextId 3
   - `keys`: PRS.keys with "pull request" reworded to "issue", plus these exact texts:
     - `w`: "Create or reuse the selected issue's worktree on its own branch and open it in a new tab (without a saved checkout of the repository: set one)"
     - `a`: "Pick a saved prompt, or type one, and run it on the selected issue (typed prompts run in its worktree)"
   - `vars`: `{url}` Link to the issue, `{owner}`, `{repo}`, `{key}` Issue number, `{number}` Issue number, `{title}`, `{author}`, `{labels}` Labels, comma-separated, `{branch}` The worktree's branch (prompts that run in a worktree)

   Register `tern.block.define("issues", blockDef(ISSUES))`. Add `local TRACKERS = { github = { search = github.issues, detail = github.issue } }`; the issues kind calls only these two.
2. Prompts:
   - `Prompt` gains `worktree: boolean?`. `loadPrompts` rejects non-boolean non-nil; `editPrompts` writes it.
   - `addPrompt` sets `worktree = true` when `state.kind.id == "issues"`.
   - Prompts page (issues only) adds row `pwhere:<id>`, after `pscope:`:
     - label "Runs in"
     - hint "On: in the issue's worktree (made first if needed). Off: in the repository's main checkout, in a new tab."
     - control `{ k = "multi", values = tern.json.array(if p.worktree ~= false then {"worktree"} else {}), options = tern.json.array({ { value = "worktree", label = "Worktree" } }) }`
   - Generalize `toggleScope` to route `pwhere:` rows to `setWhere(state, id, on: boolean)`, which saves `p.worktree = on` via `editPrompts`. The `change` event with a table value on `pwhere:<id>` calls `setWhere(state, id, table.find(ev.value, "worktree") ~= nil)`.
   - `menu` adds `worktree = p.worktree ~= false` to each item for issues only.
3. Branch format, kv `branches` (`"github.com/<lower repo>"` → format string). Mirror `setupMap`'s fail-closed read in `branchMap()`.
   - `branchFormatOf(repo): string?`
   - `saveBranchFormat(state, fmt: string?): string?`, where nil deletes; it returns `NO_REPO` without a repo.
   - The Worktrees page (issues only) adds a section `sec-branch` ("Branch names for <repo>") between checkout and setup, with row `branch`:
     - label "Format"
     - hint `"Variables {key} {slug} {owner} {repo}. Empty: " .. tracker.FORMAT_DEFAULT .. "."`
     - text control `mono`, value saved-or-"", placeholder `tracker.FORMAT_DEFAULT`
     - `changed = saved ~= nil`, `defaultLabel = tracker.FORMAT_DEFAULT`, disabled `NO_REPO` without repo
   - `commitEdit`: empty → `saveBranchFormat(nil)`; else `tracker.formatProblem(text)` or save. `resetRow("branch")` clears it.
4. Views:
   - `issueRow(issue, note, open)`:
     - picker item `id = issue.id`, label/title = title
     - detail `{ ui.span("#" .. ref, "num"), " · ", ui.span("@" .. author, "mono"), " opened " .. github.age(created) .. " ago" }`, plus `" · " .. "@" .. assignees[1] .. (if #assignees > 1 then " +" .. (#assignees - 1) else "")` when assigned
     - mark author
     - badges: In tab, Worktree note (as PRs), a state badge when closed, labels
     - state badges: `completed = { text = "Completed", tone = "accent" }`, `["not-planned"] = { text = "Not planned", tone = "muted" }`, `duplicate = { text = "Duplicate", tone = "muted" }`, plain closed `{ text = "Closed", tone = "error" }`
     - `facts.comments` as PRs
   - `issuePreview(state, issue, open, acts)`, mirroring `previewNodes`:
     - hidden `buttons` col: every action's `href` keyed by action id, plus `agent` when Worktree is offered
     - head row: `#ref`, copy icon `href = url`, fill, state badge (Open success)
     - title
     - chips: In tab, labels
     - description card from `detail.issue.body` (same `plotroom.description` role and `descOpen` fold)
     - `worktreeNodes` part
     - properties part:
       - `refRow("branch", "Branch", name)` with name = `tracker.branchName(branchFormatOf(repo) or FORMAT_DEFAULT, vars)`; the row is left out when that errors
       - kv: Author, Assignees (`@a, @b` or muted None), Milestone (from detail, muted None), Comments, Opened, Updated
     - "Linked pull requests" part: `list` of `item` rows `{ key = "pr" .. i, label = "#" .. ref .. " " .. title, icon = "merge", tone = STATE_BADGE[state].tone, title = url }`, or the shimmer "Loading details…" while loading
     - A failed load shows the error and a Retry item like `checksNodes`, reusing act `retry-checks`.
   - `issueActions(state, issue, open)` (shape `PrAction`):
     - `open` "GitHub ↗" primary
     - when `checkoutOf(repo)`: `worktree` "Worktree" `w`
     - when open: `goto` "Go to tab" `g`
     - when there is a checkout: one per `offered` prompt (`prompt-<id>`)
   - Hrefs:
     - `issueHref(act, issue)` = `"plotroom://issue/" .. act .. "/" .. issue.repo .. "/" .. issue.ref` for `worktree|goto|agent`
     - `open` = `"plotroom://issue/open/" .. pct(issue.url)`
     - `issueRunHref(issue, id)` = `"plotroom://issue/run/" .. issue.repo .. "/" .. issue.ref .. "/" .. id`
   - `rowsOf`, `queuePicker`, `event` (action-bar dispatch) and the `key` handler branch on the kind to these functions.
   - `loadDetails` for issues calls `TRACKERS.github.detail(issue.repo, tonumber(issue.ref), …)` and stores `{ runs = {}, total = 0, round = round, issue = detail }`.
5. Settings page leads (issues), exact text:
   - filters: "Saved searches for the issue list's filter column. They run inside <where>, so repo:, org:, user: and OR are not allowed." Placeholders `Assigned to me` / `is:open assignee:@me`; new-filter hint "Starts as every open issue."
   - prompts: "Run a prompt on an issue from the action bar or the agent picker (a), in its worktree or the repository's main checkout. Variables such as {url} fill in the issue's details." New-prompt hint "Starts empty, runs in a worktree, offered under every filter."
   - github: "Issues load through GitHub's GraphQL API with your gh login."
   - worktrees: "Worktree (w) makes the issue's branch from the remote's default branch with omp and opens it in a new tab, which runs the setup commands when the worktree is new. Agents run there or in the main checkout. Both need the repository's local checkout."
6. RPC:
   - Bump `RPC_PROTOCOL` to `"6"`.
   - `rpc` accepts op `issue` only on issues blocks, and `worktree` only on prs blocks.
   - Validation for `issue`: `q.repo` is owner/name with valid segments, `q.ref` matches `^[%w%-]+$` and is ≤ 64 bytes, `q.worktree` is a boolean.

   `prepareIssue(state, id, repo, ref, wt)`:
   - Look the issue up in every cached `state.snaps` by key `string.lower(repo) .. "#" .. ref`. If it is missing, reply `{ problem = "That issue is not loaded here any more; Refresh and try again." }`.
   - No `checkoutOf(repo)`: open Settings › Worktrees › checkout and reply `{ noRepo = true }`.
   - `vars = { url, owner, repo (name), key = ref, number = ref, title, author, labels = table.concat(labels, ", ") }`.
   - `wt == false`: reply `{ path = checkout, summary = "Main checkout", created = false, current = true, vars = vars }`.
   - Otherwise:
     - `branch, why = tracker.branchName(format, { key = ref, slug = tracker.slug(title), owner, repo = name })`; on an error, reply `{ problem = why }`.
     - The `preparing` guard uses the same key.
     - `worktree.openIssue(checkout, repo, ref, branch, …)`: handle NO_REPO as `prepare` does. Note the result with `noteWorktree(state, key, { path, branch, created, current = true, dirty, summary = worktree.describeIssue(r), update = {}, cleanup = worktree.cleanupIssue(r) }, problem)`.
     - Reply `{ path, created, current = true, dirty, summary, setup = if created then setupLine(repo) else nil, vars = vars + { branch = r.branch } }`.

### 5. Window: two blocks, issue links, main-checkout agents

1. Bump `PROTOCOL` to `"6"`. `isPlotroom` accepts block suffix `plotroom.prs` or `plotroom.issues`.
2. Add `type Target = { kind: "pr" | "issue", owner: string, name: string, repo: string, ref: string, label: string, tab: string }`:
   - `label`: `repo .. "#" .. ref`
   - `tab`: `"PR #" .. ref .. " · " .. name` for PRs, `"#" .. ref .. " · " .. name` for issues

   Refactor these to take a `Target`:
   - `prPane` → `targetPane(cx, t)`: `prOfPath` for PRs, `issueOfPath` for issues
   - `gotoPr` → `gotoTarget`
   - `namePrTab` → `nameTab(cx, pane, t)`
   - `finishWorktree`, `startAgent`, `finishAgent`, `worktreePr` → `prepareTarget`, `runSaved`, `pickAgent`

   Toasts use `t.label`; texts otherwise unchanged.
3. `prepareTarget(cx, pane, t, prompt: string?, wt: boolean)`:
   - PRs: op `worktree` `{ repo, number }` as today.
   - Issues: op `issue` `{ repo, ref, worktree = wt }`.
   - Shared busy, noRepo and problem toasts.
   - Prompt filling: PRs use `fill` (unchanged). Issues use `fillVars(prompt, a.vars)`, which replaces only `{name}` keys whose `a.vars[name]` is a string; anything else stays as written.
   - `prompt == nil` goes to `finishWorktree`.
   - Toast while waiting: `wt` → "Preparing worktree for <label>"; otherwise none.
4. `finishAgent(cx, pane, t, r, prompt, join: boolean)`: `join` false (main checkout) skips the existing-tab lookup and the setup tab, and always starts the agent in a new tab (`how = "tab"`) named `t.tab`.

   `startAgent` passes `join = wt`. Its consent deny text is "The worktree stays; no agent starts" when `wt`, else "Nothing changes; no agent starts".
5. `runSaved` uses `it.worktree ~= false` (PR items have none, so they stay worktree). `pickAgent` passes each item's `worktree` through; the typed row always uses `wt = true`.
6. `handle` adds a link family before `parseLink`:
   - `^plotroom://issue/open/(.+)$`:
     - `unpct` must give `https://` with no spaces or control characters (reuse `parseCheck`'s test)
     - isPlotroom, plus the `OPEN_NODE` href equal to the link
     - then `openUrl(cx, pane, target, "the issue")`
   - `^plotroom://issue/(%a+)/([^/]+)/([^/]+)/([%w%-]+)$` with act in `worktree|goto|agent`, and `^plotroom://issue/run/([^/]+)/([^/]+)/([%w%-]+)/(%w+)$`:
     - owner and name must pass `validSegment`; ref is at most 64 bytes
     - check against the same node keys as PRs (`WORKTREE_NODE`, `GOTO_NODE`, `AGENT_NODE`, `PROMPT_NODE .. id`)
     - "no longer listed" toast text: "Plotroom: that issue is no longer listed"
   - Dispatch:
     - worktree → `prepareTarget(t, nil, true)`
     - goto → `gotoTarget`
     - agent → `pickAgent`
     - run → `runSaved`
7. Commands:
   - Extract the `open` command body into `launch(cx, block)`.
   - Add command `{ id = "open-issues", title = "Plotroom: Open GitHub Issues", icon = ISSUE_ICON, run = launch(cx, "plotroom.issues") }`.
   - Retitle the others to cover both blocks:
     - "Plotroom: Open the selected PR or issue in Browser"
     - "Plotroom: Open the selected PR or issue in a worktree"
     - "Plotroom: Go to the selected PR or issue's tab"
     - "Plotroom: Run an agent on the selected PR or issue"
   - `selected()` missing text: "Nothing is selected".

### 6. Manifest and CSS

- `plugin.toml`:
  - description "A live GitHub pull request and issue queue with saved filters, Browser links, worktrees and agents."
  - add `[[blocks]] id = "issues"`, `title = "Plotroom · GitHub Issues"`, `icon = "circle-dot"`, `palette = false`
- `plotroom.css`: every rule's selector gets a second selector with `[data-surface='plugin.plotroom.issues']` in place of `prs`, comma-listed. No `:is()`, so the stylesheet stays within the existing allowed syntax.

### 7. Tests

`plugin/tests/regression.luau`:
- `World.open(pane, args?, saved?, block: string?)` defaults `block` to `"prs"` (`blocks[block or "prs"]`).
- The fake gh (`newGh`):
  - classifies a search whose `q` contains `" is:issue "` as kind `"issue-search"`, served from `gh.issueItems[login]` (paged like `items`)
  - classifies a GraphQL call whose `query=` contains `issue(number: $n)` as kind `"issue"`, served from `gh.issueDetail["o/r#n"]`
- Add a helper `issueItem(n, repo, updated, extra?)` shaped like ISSUE_JQ output.

New cases:
1. `github.issues: searches is:issue in the repository and normalizes issues`. The `q` field equals `"repo:o/r is:open assignee:@me is:issue sort:updated-desc"`. The result has `ref "12"`, `id "n12"`, `reason "not-planned"` for `NOT_PLANNED`. An item with a `/pull/` URL fails with the "not an issue" message.
2. `github.issue: reads body, milestone and linked pull requests`. Draft maps to `draft`, MERGED to `merged`; a non-https URL entry is dropped.
3. `worktree.openIssue: creates the branch from the remote's default branch`. The argv sequence includes:
   - `check-ref-format --branch 12-fix-login`
   - `fetch --no-tags --no-write-fetch-head origin +HEAD:refs/plotroom-base/o/r`
   - `omp worktree add -q -C /work/r -b 12-fix-login <wt>/plotroom-o_r-issue-12 <sha>`

   No `config branch.` spawn. The result has `created=true` and `head=<sha>`.
4. `worktree.openIssue: reuses the worktree at the issue's directory whatever its branch` (no fetch, no add).
5. `worktree.openIssue: attaches an existing local branch without moving it` (add argv `<target> 12-fix-login`, no fetch).
6. `worktree.openIssue: refuses a branch name git rejects` (check-ref-format exit 1 → the Settings › Worktrees message, no add).
7. `host: the issues block lists issues under its own seeded filters`:
   - kv `issue-filters` is seeded and kv `filters` is untouched
   - title `"Plotroom · Assigned to me (3)"`
   - picker noun `"issues"`
8. `host: the issue preview shows body, assignees, milestone, linked PRs and the branch it would create`. Text contains `12-fix-login` and `#45`.
9. `host: a prompt set to the main checkout answers with the checkout and spawns nothing`. Uses rpc `issue {worktree=false}`; the answer has `path == "/work/r"` and `vars.title`, and `w.finish()` sees no unmatched spawns.
10. `host: the branch format rejects unknown variables and saves per repository`:
    - `{foo}` warns `Unknown variable {foo}.`
    - `x-{slug}` warns about `{key}`
    - `feat/{key}` saves to kv `branches["github.com/o/r"]`
    - reset clears it
11. `host: issue prompts are separate from PR prompts and carry Runs in` (kv `issue-prompts`; turning the `pwhere` chip off saves `worktree=false`; the menu item has `worktree=false`).
12. `window: Worktree on an issue opens a tab named "#12 · r" in plotroom-o_r-issue-12` (uses `w.window.panes[1].block = "plugin.plotroom.issues"` and a host block linked with `w.link`).
13. `window: a main-checkout prompt starts the agent in a new tab at the checkout after consent`. `w.window.agents` records `cwd="/work/r"`, `how="tab"`; no worktree request is sent.
14. `window: Open on an issue docks a Browser at its URL` and `window: a forged issue link not shown by the block is refused`.

`plugin/tests/check.luau` (pure asserts):
- `tracker.slug("Fix: Login → redirect!!") == "fix-login-redirect"`
- a 60-char title slugs to ≤ 40 bytes with no trailing `-`
- `tracker.slug("¡¿") == "issue"`
- `tracker.branchName("{key}-{slug}", {key="12", slug="x"}) == "12-x"`
- `worktree.issueOfPath("/wt/plotroom-o_r-issue-12/src", "O/R") == "12"`, and `nil` for `-pr-12`

Smoke:
- `runtime.luau` accepts `{ op = "issue", repo, key, branch, checkout }`, calls `worktree.openIssue`, and writes `{ ok, hasCx, result, describe = describeIssue, cleanup = cleanupIssue }`.
- `check.py`:
  - `Smoke.open_issue(repo, key, branch, checkout)`, mirroring `Smoke.open`
  - scenario `sc_issue`:
    - first open on `o/r` key `7`, branch `7-smoke-issue`:
      - `created == True`
      - `head ==` the bare remote's `rev-parse HEAD`
      - path `tmp/omp-wt/plotroom-o_r-issue-7`
      - `refs/heads/7-smoke-issue` at that sha
      - `git config branch.7-smoke-issue.merge` exits 1
    - second open → `created == False`
  - insert `("issue worktree", sc_issue)` before `("remote host", …)` in `SCENARIOS`

## Critical files & anchors

- `plugin/host.luau`:
  - `State` L69
  - storage L116–317
  - `refresh` L662
  - `pageContent` L1053
  - `commitEdit` L1592
  - `noteWorktree` L1993
  - `prepare` / `rpc` L2129–2251
  - `previewNodes` L2394
  - `queuePicker` L2579
  - `tern.block.define` L2848

  This is the whole engine refactor plus the issues kind.
- `plugin/github.luau`: `M.search` L756–835 (loop extraction), `M.about` L856 (`cleanBody`), `M.checks` L892 (template for `M.issue`).
- `plugin/worktree.luau`: `M.open` L503–753 (extract `steps`/`inspectPath`/`addWorktree`), `reconcile` L383, `prOfPath` L406 (template for `issueOfPath`).
- `plugin/window.luau`: `isPlotroom` L52, `parseLink`/`handle` L102/L581, `finishAgent` L289, `worktreePr` L404, commands L671.
- `plugin/tests/regression.luau`: `World.open` L1019, `newGh` L1540 (request classification L1617–1646), host helpers L3860+.

## Verification

1. After step 1: `python3 scripts/check.py test types`. Expect `REGRESSION cases=N failed=0` with N unchanged, and zero luau-lsp diagnostics. This proves the engine refactor kept PR behavior.
2. After step 7: `python3 scripts/check.py`. Expect test, types, bench and smoke all PASS. Requirements: tern 0.8.3, git ≥ 2.36, omp on PATH, tools via `python3 scripts/check.py tools`. Smoke now reports 10 real-git scenarios, including `issue worktree`.
3. Manual, in Tern, from a GitHub checkout (`tern plugin link ./plugin`):
   1. Palette → "Plotroom: Open GitHub Issues". The block opens on the cwd's repository with filters Assigned to me / Created by me.
   2. Select an issue. The sidebar shows the body, assignees, milestone, linked PRs and `Branch <n>-<slug>`.
   3. Press `Enter`. A Browser docks right, at `https://github.com/<o>/<r>/issues/<n>`.
   4. Press `w`. A tab named `#<n> · <repo>` opens in `~/.omp/wt/plotroom-<o>_<r>-issue-<n>`, and `git branch --show-current` prints `<n>-<slug>`. The row shows "In tab".
   5. In `s` › Prompts, add a prompt with Runs in off. Run it with its button and Allow it. An agent tab opens with cwd = the main checkout and no worktree is created.
   6. Press `o` and pick another repository. The list reloads for it.
   7. If the `circle-dot` icon renders blank, apply the icon contingency below.

## Assumptions & contingencies

- Base branch for new issue branches = the remote's default branch (`+HEAD` fetch). If git rejects the `HEAD` source in the refspec during smoke, use `git ls-remote --symref <remote> HEAD` to read `ref: refs/heads/<name>`, then fetch `+refs/heads/<name>:<baseRef>`.
- If GitHub rejects `closedByPullRequestsReferences` or `includeClosedPrs` (HTTP 422 / "doesn't exist on type"), drop the argument first, then the field. In that case the sidebar has no linked-PRs part.
- Icon `circle-dot` is unverified. If it renders blank, use `"message"` (a known Tern icon) for `ISSUE_ICON`, the manifest and the command.
- Issue filters and prompts are per kind (`issue-filters`, `issue-prompts`). When Jira or Linear land, issue filters get a `tracker` field (store version 2), and `TRACKERS` gains `account`/`wait`/`scopeProblem` entries. Today the engine calls these directly on `github`.
- A branch that exists only on the remote (someone pushed `12-fix-login`) is not detected; a fresh local branch is made from the default branch.
