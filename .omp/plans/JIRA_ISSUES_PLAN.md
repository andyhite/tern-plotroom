# Plotroom: Jira issues in the issues block

## Context

The `issues` block (`plugin.plotroom.issues`) lists GitHub issues only. It must also list Jira issues. Same block, renamed to something generic.
- Settings gets an Integration page. It offers GitHub (`gh`) and Jira (Atlassian's `acli`). An integration whose CLI does not start on the block's host is shown disabled.
- Choosing an integration opens that integration's project picker: GitHub repository or Jira project key. The block switches only after a project is picked.
- Existing GitHub-issue behavior stays the same: filters, prompts, worktrees, agents, links and the repository picker.
- The sidebar shows one shared set of rows (union) plus rows specific to each tracker.

User decisions:
- Jira goes through **acli** (Atlassian's official CLI, Cloud only).
- Saved issue prompts are **shared** across integrations (kv `issue-prompts`).

Facts about acli 1.3.x, observed on this machine:
- `acli jira workitem search --jql Q --limit N --json --fields F` prints a JSON array of raw REST issues `{key, fields{...}}`.
- `--fields` accepts only `key, summary, status, issuetype, priority, assignee, reporter, labels, description, creator`. So the list has no created/updated/comment fields.
- An empty result prints `[\n  null\n]`.
- `status.statusCategory.key` is one of `new | indeterminate | done`.
- `acli jira workitem view KEY --json --fields '*all'` prints the full REST issue. It has `created`, `updated` (`2026-05-27T09:38:49.512-0500`), `comment.total`, `issuelinks`, `subtasks`, `parent`, `components`, `fixVersions`, the sprint custom field (an array of `{boardId, state, name}`) and an ADF `description`.
- `acli jira project list --paginate --json` prints `[{key, name, ...}]`.
- `acli jira auth status` prints `✓ Authenticated\n  Site: circuit-ai.atlassian.net\n ...`. The issue `self` URLs are internal API hosts, so the browse URL comes from this site.
- Errors are printed on stderr, starting `✗ Error:`. Examples:
  - `✗ Error: unauthorized: use 'acli jira auth login' to authenticate`
  - `✗ Error: failed to parse JQL query: field 'bogus' does not exist…`
  - `✗ Error: failed to parse JQL query: the value 'nopexyz' does not exist for the field 'project'.`
- A search of 100 issues takes about 3 s and returns about 400 KB.

## Approach

Build order: run `python3 scripts/check.py test types` after each numbered step and keep it green. In each step, update the existing tests that pin a changed signature or wording (step 10 lists the new tests).

Dependency graph after this change:
- `host → github, input, process, tracker, worktree, jira`
- `jira → process, tracker, github`
- `worktree → process, github, tracker`
- `github → process, input, tracker`
- `tracker → input`
- `window → worktree`

### 1. Tracker-neutral model (`plugin/tracker.luau`, `plugin/github.luau`, host call sites)

**`tracker.luau`**

Extend the types (keep every existing field):
```lua
export type Issue = {
	key: string, -- identity, lowercase project: GitHub "owner/repo#12" (github.identity), Jira "abc#ABC-12"
	tracker: string, -- "github" | "jira"
	repo: string, -- the project: GitHub "Owner/Repo" as GitHub spells it, or a Jira project key "ABC"
	ref: string, -- "12" or "ABC-12": links, {key}, directory names; matches ^[%w_%-]+$
	id: string, -- picker id "n" .. ref
	title: string, url: string, author: string,
	state: string, -- "open" | "closed"
	reason: string?, -- GitHub, closed: "completed" | "not-planned" | "duplicate"
	status: { text: string, tone: string }?, -- Jira: the workflow status as a badge, toned by its category
	type: string?, -- Jira issue type
	priority: string?, -- Jira priority
	labels: { string }, assignees: { string },
	comments: number, -- Jira: 0, its count comes with the details
	created: number, updated: number, -- Jira: 0 (unknown); the details carry them
}
export type Linked = { ref: string, title: string, url: string, state: string, relation: string? } -- state "open"|"draft"|"merged"|"closed"|"done"; relation (Jira) "blocks", "is blocked by", "subtask", …
export type Field = { label: string, value: string? } -- nil value: shown as None
export type IssueDetail = { body: string, fields: { Field }, linked: { Linked }, comments: number?, created: number?, updated: number? }
```

New and changed members:
- `M.VARS = { github = { "key", "slug", "owner", "repo" }, jira = { "key", "slug", "project" } }`. This replaces the flat list.
- `M.FIELDS = { github = { "Milestone" }, jira = { "Parent", "Sprint", "Components", "Fix versions" } }`. These are the detail rows each tracker fills, in order.
- `M.formatProblem(fmt: string, trackerId: string): string?`. It checks `{name}` against `M.VARS[trackerId]`. The messages are unchanged.
- `M.branchName(fmt: string, trackerId: string, vars): (string?, string?)`. It passes `trackerId` to `formatProblem`.
- `M.refLabel(ref: string): string` returns `"#" .. ref` when the ref is all digits, else the ref unchanged.
- `M.jiraProject(s: string): boolean` is true when `#s <= 32` and `s` matches `^[A-Z][A-Z0-9_]+$`.
- `M.match`: the fallback haystack starts with `M.refLabel(issue.ref)` instead of `"#" .. issue.ref`.

**`github.luau`**
- `M.epoch(iso)` now honors an optional offset. Match `^(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$`. Then match `rest` against `^[%.%d]*([%+%-])(%d%d):?(%d%d)$`. With a sign, subtract `sign * (hh*3600 + mm*60)`. Without one (`Z` or nothing), the time is UTC as today.
- `M.issue` returns `fields = { { label = "Milestone", value = <non-empty milestone or nil> } }` instead of `milestone`. Everything else stays as it is.

**Host call sites**
- `issueBranch`: `tracker.branchName(format, issue.tracker, vars)`.
  - Jira vars are `{ key, slug, project = issue.repo }`.
  - GitHub vars are as today.
- `commitEdit`, `row == "branch"`: `tracker.formatProblem(text, state.kind.tracker)`.
- Branch row hint: `"Variables {" .. table.concat(tracker.VARS[state.kind.tracker], "} {") .. "}. Empty: " .. tracker.FORMAT_DEFAULT .. "."`. The GitHub text stays identical.
- `"#" .. ref` becomes `tracker.refLabel(ref)` in four places:
  - `issueRow` detail
  - the `issuePreview` head span
  - the `issuePreview` aria (`"Copy link to issue " .. refLabel`)
  - `linkedNodes` labels
- Add `tracker: string` to the `Kind` type now. PRS and ISSUES get `tracker = "github"`; step 4 adds the other fields. This lets step 1 already use `state.kind.tracker`.
- `issuePreview`'s Milestone row reads `detail.fields` (the entry with label `"Milestone"`) instead of `detail.milestone`, keeping today's `…`/None rendering. Step 6 then generalizes the facts.

### 2. Worktrees for Jira projects (`plugin/worktree.luau`)

Add `local tracker = require("./tracker")`.

1. Add a local `issueSlot(repo: string): (string?, string?)` that returns the directory slot and the base-ref part:
   - GitHub `owner/name` (lowercased; both parts pass `M.validSegment`): `owner .. "_" .. name` and `refPart(owner) .. "/" .. refPart(name)`.
   - `tracker.jiraProject(repo)`: `"jira." .. string.lower(repo)` and `"jira/" .. string.lower(repo)`. GitHub owners never contain `.`, so a Jira slot cannot collide with a GitHub one.
   - Anything else: `nil, nil`.

   Add `M.validProject(repo: string): boolean` = `issueSlot(repo) ~= nil`.
2. `M.resolveRepository(path, repo, done)` gets a Jira branch. When `tracker.jiraProject(repo)`, it does not scan URLs, because a Jira project's checkout may use any host.
   - After `rankedRemotes`, use `names[1]`: `done({ root, commonDir = common, remote = names[1] })`.
   - With no remote: `done(nil, root .. " has no git remote to branch from.", cx)`.
   - Update the doc comment.
3. `M.claimCheckout`: in `clone()`, when `tracker.jiraProject(repo)`, nothing is cloned. Instead:
   ```lua
   tern.timer(0, function(cx) done(nil, "That folder is not a git checkout. A Jira project names no repository to clone, so enter the folder of an existing checkout.", cx) end)
   ```
4. `M.openIssue`:
   - Validate with `local slot, base = issueSlot(repo)`. Nil gives `"Invalid repository " .. repo`. The key pattern becomes `^[%w_%-]+$`.
   - `dirName = "plotroom-" .. slot .. "-issue-" .. key`. **Drop `string.lower(key)`**: the directory keeps the key's case, so `issueOfPath` returns exactly `item.ref` (`ABC-12`). GitHub keys are digits, so nothing changes for GitHub.
   - `baseRef = "refs/plotroom-base/" .. base`.
   - The rest is unchanged. `resolveRepository` handles Jira.
5. `M.issueOfPath(path, repo)`:
   - Mark `"/plotroom-" .. slot .. "-issue-"`. A nil slot returns nil.
   - Ref pattern `^([%w_%-]+)(.*)$`.
   - Update the header comments of `openIssue` and `issueOfPath`.

### 3. New module `plugin/jira.luau` (no callers yet)

`--!strict`, `local M = {}`, requires `./process`, `./tracker` and `./github` (for `epoch` only).

`type Problem = { kind: string, message: string }` is structurally the same as `github.Problem`.

Constants:
- `TIMEOUT_MS = 60*1000`
- `M.LIMIT = 100`. Carry the comment `-- ponytail: the newest 100 by update per filter; page with --paginate if filters need more`.
- `SEARCH_FIELDS = "key,summary,status,issuetype,priority,assignee,reporter,labels"` (the only fields acli's search allows)
- `BODY_CHARS = 20000`
- `TONE = { new = "muted", indeterminate = "warning", done = "success" }`

Functions:
- local `acli(args, done: (string?, Problem?) -> ())`:
  - Runs `process.run({"acli", ...args}, { timeout_ms = TIMEOUT_MS }, …)`.
  - No result: `{ kind = "missing", message = <process problem or "acli could not be started"> }`.
  - `timed_out`: `{ kind = "failed", message = "acli did not answer within 60 seconds." }`.
  - Nonzero status: `M.classify(stdout .. "\n" .. stderr)`.
  - Otherwise `done(stdout)`.
- `M.classify(text): Problem`:
  - `line` = the capture of `Error:%s*([^\n]+)`, else the first non-blank line, else `"acli failed."`.
  - Then, on `string.lower(text)`, in this order:
    1. `unauthorized` or `auth login` gives `auth` with message `"acli is not signed in to Jira: " .. line`.
    2. `failed to parse jql` plus `field 'project'` gives `not-found`.
    3. `failed to parse jql` gives `invalid`.
    4. `429` or `rate limit` gives `rate-limit`.
    5. Anything else gives `failed`.
  - Every kind except the first uses `line` as its message.
- Site cache:
  - Module local `site: string?`.
  - `M.reset()` clears it. The host's `retry` calls it.
  - local `withSite(done)` returns the cached value. Otherwise it runs `acli jira auth status` and matches `Site:%s*([%w%.%-]+)`. A match caches `"https://" .. host`. No match gives `{ kind = "auth", message = "acli did not name a Jira site; run acli jira auth login." }`.
  - Any search or view that ends with an `auth` problem clears `site`.
- local `decode(stdout)`: `pcall(tern.json.decode, string.sub(stdout, (string.find(stdout, "[%[{]") or 1)))`. Starting at the first `[`/`{` skips any update notice acli prints.
- `M.scopeProblem(query): string?`:
  - Walk the query bytes, tracking a quote (`"` or `'`, with `\` escaping the next byte) and the paren depth outside quotes.
  - If depth goes below 0: `"Unbalanced parentheses: a filter cannot close the project's scope."`
  - If a quote is still open or the depth is not 0 at the end: `"Unbalanced quotes or parentheses."`
  - If the text outside quotes, lowercased, matches `order%s+by`: `"Leave out ORDER BY: issues are listed newest update first."`
- `M.normalize(item, project, siteUrl): (tracker.Issue?, string?)`:
  - Requires `item.key` (a string matching `^[A-Z][A-Z0-9_]*%-%d+$`), a table `item.fields` and a string `fields.summary`. Otherwise: `"acli returned a work item without a key or summary"`.
  - `category = fields.status.statusCategory.key`.
  - Fields:
    - `key = string.lower(project) .. "#" .. item.key`
    - `tracker = "jira"`, `repo = project`, `ref = item.key`, `id = "n" .. item.key`
    - `title = summary`, `url = siteUrl .. "/browse/" .. item.key`
    - `author = fields.reporter.displayName or "Unknown"`
    - `state = if category == "done" then "closed" else "open"`, `reason = nil`
    - `status = { text = fields.status.name, tone = TONE[category] or "muted" }`, or nil when there is no status name
    - `type = fields.issuetype.name`, `priority = fields.priority.name`
    - `labels` = the strings of `fields.labels`
    - `assignees = { fields.assignee.displayName }` when present, else `{}`
    - `comments = 0`, `created = 0`, `updated = 0`
  - Read every nested field defensively; `fields.assignee` may be JSON null.
- `M.issues(project, query, shouldContinue, done: (tracker.IssueResult?, Problem?, number) -> ())`. Spent is always 0. Steps:
  1. A blank query fails with `{failed, "The filter query is empty."}`.
  2. `M.scopeProblem(query)` fails with `invalid` and spawns nothing.
  3. `withSite`.
  4. If `not shouldContinue()`, answer `{ kind = "superseded", message = "" }`.
  5. Run `acli jira workitem search --jql <jql> --limit 100 --json --fields <SEARCH_FIELDS>`, where `jql = 'project = "' .. project .. '" AND (' .. query .. ') ORDER BY updated DESC'`.
  6. Decode the output. An array is expected; skip elements that are not tables or equal `tern.json.null`; also accept `null` for an empty result.
  7. Normalize every element. Any reject fails with `{failed, "acli printed something other than a search result"}` (or the reject's reason).
  8. Keep acli's order; do not call `tracker.reconcile`.
  9. `done({ issues, total = #issues, complete = #issues < M.LIMIT }, nil, 0)`.

  Early failures are deferred with `tern.timer(0, …)`, as in `github.issue`.
- `M.issue(key, done: (tracker.IssueDetail?, Problem?) -> (), shouldContinue?)`. It mirrors `github.issue`'s superseded and finish handling. It validates the key, calls `withSite`, then runs `acli jira workitem view <key> --json --fields *all` and builds the detail from `data.fields`:
  - `body`: `M.adf(description)` for a table, the string itself for a string, else `""`. Cut to `BODY_CHARS` characters on a UTF-8 boundary and append `…`.
  - `fields`, in `tracker.FIELDS.jira` order:
    - Parent: `parent.key .. " " .. parent.fields.summary`.
    - Sprint: the first `customfield_*` value that is an array of tables with a string `state` and a number `boardId`. Use the `name` of the entry whose state is `active`, else `future`, else the last entry. Comment it `-- ponytail: sprint field found by shape, not by its configured id`.
    - Components: names joined with `", "`.
    - Fix versions: `fixVersions` names joined with `", "`.
    - Each is nil when absent.
  - `linked`:
    - Each `issuelinks[]`: the other issue is `outwardIssue` (relation `type.outward`), else `inwardIssue` (relation `type.inward`).
    - Each `subtasks[]` has relation `"subtask"`.
    - Every entry gets `ref = other.key`, `title = other.fields.summary`, `url = site .. "/browse/" .. key`, and `state = if other.fields.status.statusCategory.key == "done" then "done" else "open"`.
    - Drop entries without a key or summary.
  - `comments = fields.comment.total` (a number or nil); `created`/`updated` via `github.epoch`.
  - Bad JSON fails with `{failed, "acli printed unexpected issue data."}`.
- `M.projects(done: ({ { key: string, name: string } }?, Problem?) -> ())`:
  - Runs `acli jira project list --paginate --json`.
  - Keeps entries whose `key` passes `tracker.jiraProject`; a missing name becomes `""`.
  - Sorts by key.
  - No cache; comment it `-- ponytail: read on every picker open (~1 s); cache like github's lists if it drags`.
- `M.adf(node): string`, ADF to markdown:
  - `doc` and unknown nodes: their content's blocks joined by blank lines.
  - `paragraph`: inline text. `heading`: `string.rep("#", attrs.level) .. " "` plus inline text.
  - `bulletList` and `orderedList`: items `- ` / `N. `; nested lists are indented two spaces.
  - `codeBlock`: a fenced block with `attrs.language`. `blockquote`: `> ` on every line. `rule`: `---`.
  - `table`: `| a | b |` rows, with `| --- |…` after the first.
  - `panel`/`expand`/`nestedExpand`: their content.
  - Inline nodes:
    - `text` marks: code `` `t` ``, strong `**t**`, em `*t*`, strike `~~t~~`, link `[t](href)`.
    - `hardBreak`: `\n`. `mention`: `attrs.text`. `emoji`: `attrs.text` or `attrs.shortName`.
    - `inlineCard`/`blockCard`: `attrs.url`. `status`: `attrs.text`.
    - `media*` and `date`: nothing.
  - Trim the result.

### 4. Host engine: a Jira kind and tracker dispatch (`plugin/host.luau`)

1. Add `local jira = require("./jira")`.

   Replace `TRACKERS` (L19-21) with this table. Remove the ponytail comment above it.
   ```lua
   -- How the issues kind lists a tracker's issues, loads one issue's details and checks a filter query.
   local TRACKERS = {
   	github = { search = github.issues, scope = github.scopeProblem, detail = function(issue: tracker.Issue, done: (tracker.IssueDetail?, github.Problem?) -> (), live: () -> boolean) github.issue(issue.repo, tonumber(issue.ref) :: number, done, live) end },
   	jira = { search = jira.issues, scope = jira.scopeProblem, detail = function(issue: tracker.Issue, done: (tracker.IssueDetail?, github.Problem?) -> (), live: () -> boolean) jira.issue(issue.ref, done, live) end },
   }
   ```
   Callers:
   - `refresh` L818-822: `TRACKERS[state.kind.tracker].search(...)` for issues; PRs still use `github.search`.
   - `loadDetails` L2232-2251: `TRACKERS[state.kind.tracker].detail(item, cb, live)`.
   - `commitEdit` L1854: `TRACKERS[state.kind.tracker].scope(text)`.
2. Besides `tracker` (added in step 1), the `Kind` type (L32-43) gains:
   - `site: string`: "GitHub" | "Jira", for the Open button
   - `place: string`: "repository" | "project"
   - `pickHref: string`: the window's picker of that place
   - `pages: { string }`: Settings page ids in order
   - `newQuery: string`: the query a new filter starts with
   - `linked: string`: the issue sidebar heading of linked items; "" for PRs

   Move `REPOS_HREF` (L2046) up next to `SETTINGS_ID` (L1058), and add `local JIRA_HREF = "plotroom://jira-projects"` there.

   Values:
   - `PRS`: `tracker="github", site="GitHub", place="repository", pickHref=REPOS_HREF, pages={"filters","prompts","github","worktrees"}, newQuery="is:open", linked=""`
   - `ISSUES`: the same tracker, site, place and pickHref, plus `pages={"filters","prompts","source","worktrees"}, newQuery="is:open", linked="Linked pull requests"`. Its title stays `"GitHub Issues"`.
   - New `JIRA: Kind`:
     - `id="issues"`, `tracker="jira"`, `title="Jira Issues"`, `one="issue"`, `many="issues"`, `icon=ISSUE_ICON`
     - `site="Jira"`, `place="project"`, `pickHref=JIRA_HREF`
     - `pages` as ISSUES
     - `filtersKey="jira-filters"`, `promptsKey="issue-prompts"` (shared with ISSUES)
     - seeds `{ {id="f1", name="Assigned to me", query="assignee = currentUser() AND statusCategory != Done"}, {id="f2", name="Reported by me", query="reporter = currentUser() AND statusCategory != Done"} }`
     - `newQuery="statusCategory != Done"`, `linked="Linked issues"`
   - Build `ISSUES.keys` and `JIRA.keys` with one local function `issueKeys(o: string)`. It returns today's ISSUES.keys with the `o` row text replaced:
     - ISSUES keeps "Show another repository: a saved one, or type owner/name".
     - JIRA uses "Show another Jira project: a saved one, one acli lists, or type its key".
   - Both issue kinds use one `ISSUE_VARS` legend, in this order:
     - `{url}` Link to the issue
     - `{key}` Issue number (GitHub) or key (Jira, ABC-12)
     - `{title}` Title
     - `{author}` Author's login (GitHub) or reporter's name (Jira)
     - `{labels}` Labels, comma-separated
     - `{branch}` The worktree's branch (prompts that run in a worktree)
     - `{owner}` Repository owner (GitHub)
     - `{repo}` Repository name (GitHub)
     - `{number}` Issue number (GitHub)
     - `{project}` Project key (Jira)
     - `{status}` Status (Jira)
     - `{type}` Issue type (Jira)
3. GitHub-only calls get a tracker guard:
   - New `savedAccount(state, repo): (string?, github.Problem?)` returns `nil, nil` unless `state.kind.tracker == "github"`, else `github.account(repo)`. Use it in `identify` (L571), `stale` (L901) and the settings account row (L1328). Jira's account is therefore always `""`.
   - New `waitOf(state): number` returns `if state.kind.tracker == "github" then github.wait(os.time(), login(state)) else 0`. Use it at L649, L754, L1046, L1332, L2206 and L3202. The `state.account` guard at L1332/L3202 stays.
   - L802 `github.accounts(...)` warm-up runs only when the tracker is github.
   - L806-812 interval: `state.interval = if spent > 0 then github.interval(...) elseif result and state.kind.tracker == "jira" then POLL_MS else nil`.
   - `addFilter` (L1624) uses `state.kind.newQuery` instead of `"is:open"`.
4. Problem wording per tracker:
   - Add `JIRA_HEADS`:
     - `missing="Atlassian CLI not found"`
     - `auth="Atlassian CLI not signed in"`
     - `["rate-limit"]="Jira rate limit"`
     - `["not-found"]="Project not visible"`
     - `invalid="Jira rejected the search"`
   - Add `JIRA_HELP`:
     - `missing="Install Atlassian's CLI (acli) so it is on your shell's PATH, then Refresh."`
     - `auth="Run acli jira auth login in a terminal, then Refresh."`
     - `["rate-limit"]="Searches resume at the next refresh."`
     - `["not-found"]="Check the project key, or pick another project (o), then Refresh."`
     - `invalid="Check the filter's JQL in Settings › Filters, then Refresh."`
   - `headOf` reads `JIRA_HEADS` for the jira tracker.
   - New `helpOf(state, k)`:
     - Reads `JIRA_HELP` for the jira tracker.
     - For `k == "no-repo"` on an issues kind: `"Press o to pick a repository, open Plotroom inside a checkout of one, or choose Jira in Settings › Integration."`
     - Otherwise `HELP[k]`.
   - L3262 uses `helpOf`.
   - Rewrite the `TERMINAL` comment so `not-found` covers both trackers.
5. kv keys for a project. Add:
   ```lua
   local function projectKey(repo: string): string
   	return if tracker.jiraProject(repo) then "jira/" .. repo else "github.com/" .. string.lower(repo)
   end
   ```
   It replaces `"github.com/" .. string.lower(repo)` in `checkoutOf`, `saveCheckout`, `setupOf`, `branchFormatOf`, `editSetup` and `saveBranchFormat` (L217, 229, 250, 274, 1551, 1567). Update the comment on L205.
6. `issueVars(issue)`:
   - All: `url, key = ref, title, author, labels`.
   - GitHub `owner/name` repos add `owner, repo = name, number = ref`.
   - Jira adds `project = issue.repo, status = issue.status and issue.status.text or "", type = issue.type or ""`.
7. `rpc`:
   - Bump `RPC_PROTOCOL` to `"7"`.
   - `issue` op: replace the owner/name parse with `worktree.validProject(q.repo)` and `tracker.jiraProject(q.repo) == (state.kind.tracker == "jira")`. The ref pattern becomes `^[%w_%-]+$`. Call `prepareIssue(state, id, q.repo, ref, q.worktree)`.
   - New op `jira-projects`, issues blocks only: `jiraProjects(state, id)`.
     - `saved` = every `readRepos()` key matching `^jira/(.+)$` that passes `jiraProject`, mapped to its path. When the block is on Jira, also add the shown project (`""` if it is unsaved).
     - Then `jira.projects`. The items are the saved keys sorted, `{ key, name = <listed name or nil>, path = <non-empty path or nil>, saved = true, current = key == shown }`, followed by the listed keys not saved, `{ key, name, saved = false }`.
     - Cut the items at `MENU_BUDGET` as `menu` does.
     - `reply(state, id, { items, problem = problem and problem.message })`.
   - `repos` and `profile`: `current` is the shown repo only when `state.kind.tracker == "github"`, so a Jira key never enters the GitHub list.

### 5. Host: switching integration and the Integration page

1. Switching:
   - Move `showRepo` (L853-866) to just after the `JIRA` definition.
   - Add beside it:
     ```lua
     local function setKind(state: State, kind: Kind)
     	if state.kind == kind then return end
     	state.kind = kind
     	state.store, state.writable, state.storeError = loadStore(kind)
     	state.activeId = if state.store.items[1] then state.store.items[1].id else nil
     	state.account, state.query, state.interval, state.nextAt, state.descOpen = nil, nil, nil, nil, nil
     	forget(state) -- drops snapshots, details and problems of the other tracker
     end
     ```
   - `showRepo`:
     - `local wanted = if state.kind.id == "issues" then ISSUES else state.kind`.
     - The early "same repo" return also requires `state.kind == wanted`.
     - Call `setKind(state, wanted)` before setting `state.repo`.
   - New `showJira(state, raw)`:
     - Returns unless `state.kind.id == "issues"`.
     - `key = string.upper(trim(raw))`.
     - An invalid key toasts `("error", "Not a Jira project key", "Type its key, such as ABC.")`.
     - Otherwise `saveCheckout(key, "", true)`.
     - Returns if already `JIRA` with that repo.
     - Otherwise `setKind(state, JIRA)`, set `state.repo, state.problem, state.cursor = key, nil, nil`, then `changed(state)`.
   - Event handler, top level next to `show-repo`:
     - `act == "show-jira"` calls `showJira(state, ev.value)`.
     - `act == "pick-project"` calls `state.cx:open(state.kind.pickHref)`.
2. Opening the picker uses `state.kind.pickHref` in these places:
   - the `o` key (L3657)
   - the queue's `repos` action (L3785)
   - the heading link (L3145)

   The action-bar button label is `if state.kind.place == "project" then "Project" else "Repository"`.
3. `blockDef(kind)` renames its parameter to `base`. In `init`:
   - Reuse `previous` when `previous.kind.id == base.id` (it was `previous.kind == kind`). Without this, a Jira block restarts on every settings reload.
   - Choose `kind = if base.id == "issues" and isTable(saved) and saved.tracker == "jira" then JIRA else base` before `loadStore`.
   - Validate `shown` and the pause's `repo` with a helper `validFor(kind, repo)`. Jira uses `tracker.jiraProject`; GitHub uses today's owner/name + `validSegment` check.
   - If `kind == JIRA` and there is no valid `shown`, fall back to `kind = base` with no repo and no pause.
   - `save` adds `tracker = state.kind.tracker`.
4. Pages:
   - Replace `PAGES` and `PAGE_DEFS` with `PAGE_DEFS: { [string]: {id,label,group,icon} }`, which adds `source = { id = "source", label = "Integration", group = "Connection", icon = "globe" }`.
   - `settingsView` passes `pages = tern.json.array(<PAGE_DEFS[id] for id in state.kind.pages>)`.
   - Tab cycling (L3560-3561) and the `page` event (L3725) use `state.kind.pages`.
   - Settings type comment: add "source".
5. CLI probe. Add near the top, module level:
   ```lua
   local CLIS = { { id = "github", argv = { "gh", "--version" } }, { id = "jira", argv = { "acli", "--version" } } }
   local installed: { [string]: boolean } = {} -- tracker id -> its CLI starts on this host; absent: not checked yet
   local probing: { [string]: boolean } = {}
   ```
   `probeClis()` is defined after `running`/`alive`. For each CLI not known and not probing:
   - `process.run(argv, { timeout_ms = 10000 }, fn)`.
   - On answer, `installed[id] = result ~= nil`, then render every alive state with `settings`.

   Who calls it:
   - New `showPage(state, s, page)` does `discardEdit`, sets `s.page`, clears `focus`/`pick`/`errors`, and calls `probeClis()` when `page == "source"`. It replaces the bodies at L3560-3563 and L3726-3727.
   - `openSettings` calls `probeClis()` when `page == "source"`.
   - `retry` calls `table.clear(installed)` and `jira.reset()`.
6. Integration page. In `pageContent`, the branch for `"github"` becomes `s.page == "github" or s.page == "source"`. Set `jiraOn = state.kind.tracker == "jira"`.
   - `"source"` first inserts section `{ id = "sec-source", title = "Integration", rows = { useRow(state, "github"), useRow(state, "jira") } }`. `useRow` builds:
     - `id = "use:" .. id`
     - `label` "GitHub" | "Jira"
     - `control = { k = "action", act = "use-github" | "use-jira", label = <current: "Change repository" | "Change project"; else "Use GitHub" | "Use Jira"> }`
     - `hint`:
       - Current: `"In use" .. (state.repo and ": " .. state.repo or "") .. "."`.
       - GitHub, not current: `"Issues of a GitHub repository, read with gh."`.
       - Jira, not current: `"Issues of a Jira Cloud project, read with Atlassian's acli."`.
     - `disabled`:
       - `installed[id] == nil`: `"Checking whether <gh|acli> is installed…"`.
       - `installed[id] == false`, GitHub: `"gh is not installed on this host. Install the GitHub CLI (cli.github.com) to use GitHub."`.
       - `installed[id] == false`, Jira: `"acli is not installed on this host. Install Atlassian's CLI (developer.atlassian.com/cloud/acli) and sign in with acli jira auth login to use Jira."`.
   - `lead`:
     - "source" + GitHub: today's `"Issues load through GitHub's GraphQL API with your gh login."`.
     - "source" + Jira: `"Issues load through Atlassian's acli as the account it is signed in to (acli jira auth login), the newest 100 per filter."`.
     - "github": `"Pull requests load through GitHub's GraphQL API with your gh login."`.
   - The `sec-account` section and the quota `extra` appear only when `not jiraOn`.
   - In `status-line`:
     - `disabled` uses `waitOf(state)`.
     - The fallback hint is `"Auto-refresh every minute."` for Jira and stays as today for GitHub.
   - `runAction`:
     - `"use-github"` opens `state.cx:open(REPOS_HREF)`.
     - `"use-jira"` opens `state.cx:open(JIRA_HREF)`.
   - The event list at L3736 also accepts `"use-github"` and `"use-jira"`.

   The block switches only when the picker answers, through `show-repo` or `show-jira`.
7. Jira wording in the other pages. GitHub strings stay byte-identical, since `place` reads "repository" for GitHub.
   - Filters, Jira:
     - lead `"Saved JQL searches for the issue list's filter column. Each runs as project = " .. where .. " AND (your query), newest update first, so it may not close that parenthesis or add ORDER BY."`
     - query hint `"JQL."`
     - query placeholder `"assignee = currentUser() AND statusCategory != Done"`
   - Prompts lead and the `pwhere` hint: `"the repository's main checkout"` becomes `"the " .. state.kind.place .. "'s main checkout"`.
   - Worktrees lead: `"the repository's local checkout"` becomes `"the " .. place .. "'s local checkout"`.
   - Checkout hint for Jira: `"Worktrees of " .. where .. " are made from this git checkout, on a new branch from its first remote's default branch (origin, then upstream, then by name). The folder must already be a checkout; nothing is cloned for Jira."`

### 6. Host: issue views for both trackers

- `issueBadge`: return `issue.status` when set; otherwise as today.
- `issueRow`:
  - Insert the state badge when `issue.status` is set or the issue is closed.
  - Set `at = if issue.tracker == "github" then "@" else ""`.
  - Detail: `refLabel`, `" · "`, `ui.span(at .. author, "mono")`.
  - Then `" opened <age> ago"` only when `issue.created > 0`.
  - Then `" · " .. issue.type` when set.
  - Then the first assignee as `" · " .. at .. first (+N)`.
  - GitHub output is unchanged.
- `issuePreview` facts, in order:
  1. `{ k = if jira then "Reporter" else "Author", v = at .. author }`.
  2. Assignees joined by `", " .. at`, or muted None.
  3. Type and Priority, when set on the issue.
  4. Each `tracker.FIELDS[issue.tracker]` label: muted `"…"` until the details load, then the matching `detail.fields` value, or muted None.
  5. Comments: `detail.comments`, else `issue.comments` for GitHub, else muted `"…"`.
  6. Opened: `issue.created > 0`, else `detail.created`, else muted `"…"`.
  7. Updated: likewise, from `updated`.

  GitHub renders the same rows as today: Author, Assignees, Milestone, Comments, Opened, Updated.
- `linkedNodes(kind, detail, fail, loading)`:
  - Heading `kind.linked`.
  - Row label `(l.relation and l.relation .. " " or "") .. tracker.refLabel(l.ref) .. " " .. l.title`.
  - Icon `if kind.tracker == "jira" then ISSUE_ICON else "merge"`.
  - Add `done = { text = "Done", tone = "success" }` to `STATE_BADGE`.
  - The caller passes `state.kind`.
- `itemActions`: the open label is `state.kind.site .. " ↗"`.

### 7. Window (`plugin/window.luau`)

1. Set `PROTOCOL = "7"`.
2. `Target` drops `owner`/`name`.
   - `prTarget` keeps its signature.
   - At L459, PR prompt filling splits `t.repo` with `^([^/]+)/([^/]+)$` for `fill`.
   - `issueTarget(repo: string, ref: string)`:
     - GitHub (`/([^/]+)$` matches): label `repo .. "#" .. ref`, tab `"#" .. ref .. " · " .. name`.
     - Jira: label and tab are both `ref`.
3. Issue links. Parse `run` first: `^plotroom://issue/run/(.+)/([%w_%-]+)/(%w+)$`. Otherwise use `^plotroom://issue/(%a+)/(.+)/([%w_%-]+)$`, with act in `worktree|goto|agent` only. Validate with `worktree.validProject(repo)` and `#ref <= 64`. The host's `issueHref`/`issueRunHref` already build `issue/<act>/<repo>/<ref>` for both trackers, so they need no change.
4. Add `plotroom://jira-projects` to the repos/checkout branch of `handle`, as `pickJira(cx, pane)`:
   - `ask(cx, pane, "jira-projects", {}, MENU_MS, …)`.
   - A `problem` toasts `("error", "Your Jira projects are not listed", problem)`. The picker still opens.
   - Items:
     - Saved: label = key, detail = path or "No local checkout: no worktrees", group "Saved".
     - Listed: label = key, detail = name, group "Jira projects".
     - Each item carries `current` and `key`.
   - Then `{ label = "Other project…", detail = "Type its key", typed = true }`.
   - Picker `{ placeholder = "Open Jira project…", icon = ISSUE_ICON, action = "open" }`.
   - A typed entry prompts `{ placeholder = "Project key, such as ABC", icon = ISSUE_ICON, action = "open" }`.
   - The choice sends `cx.session:event(pane, { ev = "action", act = "show-jira", value = key })`.
5. Commands:
   - `open-issues` is titled `"Plotroom: Open Issues"`.
   - The `repo` command is titled `"Plotroom: Show another repository or project"`. Its `run` sends `{ ev = "action", act = "pick-project" }` to the focused pane instead of calling `pickRepo`.

### 8. Manifest (`plugin/plugin.toml`)

- The `issues` block's `title` becomes `"Plotroom · Issues"`. Keep the id `issues`, so saved panes, window `BLOCKS` and every CSS selector still work. No CSS changes.
- `description = "A live GitHub pull request queue and GitHub or Jira issue list with saved filters, Browser links, worktrees and agents."`

### 9. Smoke (`scripts/check.py`)

Add `sc_jira_issue`, inserted after `("issue worktree", sc_issue)` as `("jira issue worktree", sc_jira_issue)`:
- Setup: `root = s.checkout("r")`, `wt = s.tmp / "omp-wt" / "plotroom-jira.abc-issue-ABC-7"`.
- `s.open_issue("ABC", "ABC-7", "ABC-7-smoke", root)` must report:
  - `created` True
  - `head` == the `o/r` bare `HEAD`
  - `path` == `wt`
  - `git branch --show-current` == `ABC-7-smoke`
  - `refs/plotroom-base/jira/abc` == base
- A second open reports `created` False.

`runtime.luau` needs no change: it passes `repo` through.

### 10. Tests (`plugin/tests/regression.luau`, `plugin/tests/check.luau`)

Harness:
- `type Jira = typeof(require("../jira"))`.
- `newGh` answers `argv[2] == "--version"` with `{ stdout = "gh version 2.98.0\n" }`.
- New `newAcli(w)` with fields:
  - `site = "acme.atlassian.net"` (nil = signed out)
  - `searches: { [jql]: { item } }`
  - `views: { [key]: any }`
  - `projects: { any }`
  - `requests: { { kind, argv } }`
  - `override`

  Its responder handles `argv[1] == "acli"`:
  - `--version`: version text.
  - `jira auth status`: the Site text, or status 1 with `✗ Error: unauthorized: use 'acli jira auth login' to authenticate`.
  - `jira workitem search`: looked up by the `--jql` value. Empty prints `"[\n  null\n]\n"`.
  - `jira workitem view <key>`.
  - `jira project list`.
- `jiraItem(key, summary, fields?)` returns `{ key, fields = { summary, status = {name="To Do", statusCategory={key="new"}}, issuetype={name="Task"}, priority={name="Medium"}, reporter={displayName="Ann Lee"}, assignee=NULL, labels=array({}) } + fields }`.
- `jiraHost(w)`:
  - git `/work/r`, origin `git@gitlab.com:o/r.git`, `served.HEAD = sha("b")`.
  - kv `repos["jira/ABC"] = "/work/r"`.
  - Searches for the "Assigned to me" JQL: ABC-12 "Fix login" (In Progress/indeterminate, Bug, High, assignee Bob Ray, label ui) and ABC-13 "Old bug" (Done/done).
- `openJira(w)` = `w.open(1, {"/work/r"}, { version = 1, launchCwd = "/work/r", repo = "ABC", tracker = "jira" }, "issues")` then `flush`.

New cases. Each asserts observable output:
1. `jira.issues: one search scoped to the project, newest update first, normalized`:
   - Exact `--jql` `project = "ABC" AND (assignee = currentUser() AND statusCategory != Done) ORDER BY updated DESC`, `--limit 100`, `--fields key,summary,status,issuetype,priority,assignee,reporter,labels`.
   - ABC-12 has `key "abc#ABC-12"`, `id "nABC-12"`, `url "https://acme.atlassian.net/browse/ABC-12"`, `status {text="In Progress", tone="warning"}` and `state "open"`; ABC-13 has `state "closed"`.
   - `[null]` gives 0 issues, complete. 100 items give `complete=false`.
2. `jira.issues: problems`:
   - acli raising (`{ raise = "no such file or directory" }`, no SHELL) gives `missing`.
   - Signed out gives `auth`.
   - JQL error gives `invalid`.
   - Project error gives `not-found`.
   - `a = 1) OR (b = 2` and `x ORDER BY created` give `invalid` with no acli call.
3. `jira.issue: body as markdown, fields, links and dates`:
   - The ADF heading, a strong link and a bullet list become markdown.
   - Parent, Sprint (active entry), Components and Fix versions come in order.
   - An outward `blocks` link with done status gives `{relation="blocks", state="done"}`; a subtask gives relation "subtask".
   - `comments` comes from `comment.total`; `created` from `2026-05-27T09:38:49.512-0500` equals `github.epoch("2026-05-27T14:38:49Z")`.
4. `host: a Jira issues block lists its project under Jira filters and saves its tracker`:
   - kv `jira-filters` is seeded and `issue-filters` is absent.
   - Title `"Plotroom · Assigned to me (2)"`.
   - Row detail `"ABC-12 · Ann Lee · Bug · Bob Ray"`; status badge text "In Progress".
   - Open action label `"Jira ↗"`.
   - `save().tracker == "jira"` and `.repo == "ABC"`.
5. `host: Settings › Integration offers installed CLIs only and switches by picking a project`. From a GitHub issues block (`issueHost` + an acli responder that raises):
   - `page("source")` spawns `gh --version` and `acli --version`.
   - `use:jira` is disabled with the missing text; `use:github` is enabled and labeled "Change repository".
   - With acli answering, its action opens `plotroom://jira-projects`.
   - The `show-jira` event with `"abc"` switches: the heading is "ABC", kv `jira-filters` is used, `save().tracker == "jira"`.
   - A `show-repo` `"o/r"` switches back to GitHub filters.
6. `host: a Jira issue request makes its worktree from the project's checkout on any remote`:
   - rpc `issue {repo="ABC", ref="ABC-12", worktree=true}` answers `path "/wt/plotroom-jira.abc-issue-ABC-12"` and summary `"Created · ABC-12-fix-login at bbbbbbb · Clean"`.
   - The git log has `fetch --no-tags --no-write-fetch-head origin +HEAD:refs/plotroom-base/jira/abc`.
   - `vars.project == "ABC"`, `vars.key == "ABC-12"`.
   - With a pane cwd inside that worktree, the row shows the "In tab" badge (the uppercase ref matches).
   - An `issue` rpc with `repo="o/r"` on this Jira block is dropped (no answer).
7. `host: the Jira preview shows the union rows and Jira's own`:
   - `factOf` Reporter "Ann Lee", Type "Bug", Priority "High", Sprint, Comments "2", Opened/Updated ages.
   - The heading "Linked issues"; a row label like `"blocks ABC-3 Login API"`.
8. `window: Jira project picker lists saved and acli's projects; a typed key shows it` (window case linked to the block):
   - Picks items `ABC` (group Saved, detail `/work/r`) and `XYZ` (group Jira projects, detail its name).
   - Typing `xyz` makes the block show `XYZ`.
9. `window: Worktree on a Jira issue opens a tab named "ABC-12"`, via link `plotroom://issue/worktree/ABC/ABC-12`.

`check.luau` (pure asserts; add `local jira = require("../jira")`):
- Update the existing `branchName`/`formatProblem` calls to pass `"github"`.
- `tracker.formatProblem("{project}-{key}", "jira") == nil`.
- `tracker.formatProblem("{owner}-{key}", "jira") == "Unknown variable {owner}."`.
- `tracker.refLabel("12") == "#12"`, `tracker.refLabel("ABC-12") == "ABC-12"`.
- `tracker.jiraProject("ABC")` is true; it is false for `"abc"`, `"A"` and `"o/r"`.
- `worktree.issueOfPath("/wt/plotroom-jira.abc-issue-ABC-12/src", "ABC") == "ABC-12"`.
- `worktree.issueOfPath("/wt/plotroom-jira.abc-issue-ABC-12", "o/r") == nil`.
- `github.epoch` offset equality, as in case 3.
- `jira.scopeProblem('summary ~ "a) OR (b"') == nil`; `jira.scopeProblem("a = 1) OR (b = 2") ~= nil`.

Existing tests to update for the new behavior:
- Issues-block `page("github")` becomes `page("source")`, with `gh --version`/`acli --version` responders.
- `detail.milestone` becomes `detail.fields[1]`.
- Legend text and the Tab-cycle test: the issues block cycles `source`; the PR block is unchanged.

## Critical files & anchors

- `plugin/host.luau`:
  - `TRACKERS` L21
  - `Kind` L32
  - `identify` L566
  - `refresh` L721-823
  - `showRepo` L854 (moves)
  - `PAGES`/`PAGE_DEFS` L1059
  - kinds L1111-1186
  - `pageContent` L1225
  - `commitEdit` L1834
  - `loadDetails` L2219
  - `issueVars` L2387
  - `rpc` L2652
  - `linkedNodes`/`issuePreview` L3002-3097
  - `queuePicker` L3127
  - `blockDef` L3399
  - event handler L3678
  - `save` L3799
- `plugin/worktree.luau`: `resolveRepository` L323, `claimCheckout` L360, `openIssue` L830-944, `issueOfPath` L964. This is where the slot, remote choice and case-preserving directory name live.
- `plugin/window.luau`: `Target`/`issueTarget` L34-44, the PR `fill` call L459, `handle` L625-699, commands L783-857.
- `plugin/tests/regression.luau`: `newGh` L1568 (add `--version`), `issueHost`/`openIssues`/`issueWindow` L6453-6484 (templates for the Jira helpers), the issues settings-lead test ~L7098.

## Verification

Prerequisites, from `/Users/user/Code/andyhite/tern-plotroom`:
- `python3 scripts/check.py tools` done once.
- Tern 0.8.3, git ≥ 2.36, `omp`, and `acli` signed in (`acli jira auth status`).

1. After each step: `python3 scripts/check.py test types`. Expect `REGRESSION cases=N failed=0` and zero luau-lsp diagnostics.
2. At the end: `python3 scripts/check.py`. Expect test, types, bench and smoke all to pass. The smoke run includes `jira issue worktree`: `plotroom-jira.abc-issue-ABC-7` is created on branch `ABC-7-smoke` from the remote's HEAD, then reused.
3. Manual, with `tern plugin link ./plugin`:
   1. In a GitHub checkout, palette → "Plotroom: Open Issues". GitHub issues show exactly as before.
   2. Press `s`, then Tab to Integration. GitHub shows "Change repository"; Jira shows "Use Jira" (enabled, since acli is installed).
   3. Use Jira opens a picker listing the site's projects (`CAR`, `OXYGEN`, …). Pick `OXYGEN`.
      - The heading reads `OXYGEN`; the filters are "Assigned to me" / "Reported by me".
      - Rows look like `OXYGEN-2539 · Andrew Hite · Task · Andrew Hite`, with a status badge ("Proposed", muted).
   4. Select an issue. The sidebar shows:
      - the description as markdown
      - Reporter, Assignees, Type, Priority
      - Parent and Sprint (`Circuit :: 2026-10-13` on a sprint issue)
      - Comments, Opened, Updated
      - "Linked issues" (`relates to CC-1360 …` on OXYGEN-3339)
   5. Enter docks a Browser at `https://circuit-ai.atlassian.net/browse/<KEY>`.
   6. Set Settings › Worktrees › Path to a local checkout, then press `w`.
      - A tab named `<KEY>` opens in `~/.omp/wt/plotroom-jira.oxygen-issue-<KEY>`.
      - `git branch --show-current` prints `<KEY>-<slug>`.
      - The row shows In tab.
   7. A saved prompt from the GitHub block appears in the action bar here (shared prompts).
   8. Close and reopen Tern: the pane restores on OXYGEN with Jira filters.
   9. Settings › Integration › Change repository picks a GitHub repo; the block switches back.

## Assumptions & contingencies

- The block id stays `issues`. Only the titles become generic ("Plotroom · Issues", "Plotroom: Open Issues"). If the user wants a new id, add it to window `BLOCKS`, every CSS selector and `plugin.toml`, and expect existing panes to reset.
- An integration is "available" when its CLI starts (`--version`). Sign-in is not probed; a signed-out CLI shows its auth problem after picking.
- A new issues block still defaults to GitHub from the launch directory. Remembering the last Jira project for new blocks is out of scope.
- If acli rejects a field in `SEARCH_FIELDS` (`field 'x' is not allowed`), drop that field and leave its Issue value nil.
- If `acli jira auth status` stops printing `Site:`, read the site from `acli jira auth status --json` when available. Otherwise the problem stays `auth` with the message above.
- If a Jira search prints `[]` or `null` for no results instead of `[null]`, step 3's decode accepts all three, so nothing changes.
