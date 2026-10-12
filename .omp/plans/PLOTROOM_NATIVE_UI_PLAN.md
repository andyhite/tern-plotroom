# Plotroom native UI: picker queue, prefs settings, GraphQL PR data

## Context

The Plotroom block (`plotroom.prs`) is a plain one-line list. Its config is a pile of badge buttons and inline forms (New/Edit/Delete filter, Account, checkout path). The user wants a polished tool that uses the Tern SDK's own UI kinds, styled like the PR Guide / Tern-Me-On / rmon examples, with every setting moved into Tern's settings layout if the SDK allows it.

Findings that shape the plan:
- **Tern Preferences can't host plugin settings.** `plugin.toml` rejects unknown keys, and Preferences › Plugins only enables or disables plugins (docs.stencil.so/tern/concepts/packages.md).
- **The SDK's `prefs` node draws that same Preferences page** (nav, pages, switches, text rows, Reset, Close) inside a block (elements/work.md#prefs). All config moves there.
- **`plugin/tern.d.luau` (gitignored, editor types only) is byte-identical to `stencil-hq/tern-sdk` main**, so the current docs describe the installed Tern 0.8.2.

User decisions:
1. **Queue layout:** a full-pane native `picker`:
   - a filter column
   - two-line rows with author avatars, CI dots and badges
   - `/` search, a preview pane and a keycap action bar
2. **Row data:** review decision, CI rollup and +/- lines. This switches PR search from REST to GitHub GraphQL. A live probe confirmed it costs 1–2 points per 100-row page, out of 5000/hr.

## Approach

Repo root: `/Users/user/Code/andyhite/tern-plotroom`. Commit `88eb298` moved the whole plugin package into `plugin/`; the root now holds only `README.md`, `.gitignore` and `.omp/`.
- Every source file this plan edits is under `plugin/`. A bare file name below means `plugin/<name>`: `host.luau` is `plugin/host.luau`, `tests/check.luau` is `plugin/tests/check.luau`.
- `require` paths are relative to the requiring file, so `./github` (modules) and `../github` (tests) stay as they are.
- Add no Luau or CSS files at the repo root.

Three steps, in order. After each step, the self-test passes and the block loads.

### 0. Baseline

The concurrent fix agent has landed (`cb6dc0e`, `11794d6`, `88eb298`; clean tree). Build on it as is.
- Anchors confirmed at `88eb298`: `invalid` in `M.classify` (`github.luau`), `TERMINAL.invalid` and pause persistence in `save`/`init` (`host.luau`), `github.account`/`setAccount`, and `worktree.identify` (SSH host aliases, resolved with `ssh -G`).
- Keep every behavior those commits added: per-repo `gh` accounts, `TERMINAL` problem kinds, pause persistence, `classify` kinds and SSH-alias remote detection.
- If `git log --oneline 88eb298..HEAD -- plugin` lists commits, re-read the symbols they touch before editing.
- Symbol names below are the anchors. Re-read each one before editing it.

### 1. PR data through GitHub GraphQL (`plugin/github.luau`, `plugin/tests/check.luau`)

The old list view keeps working after this step: the `Pr` fields only grow.

**`Pr` type.** Keep `key, repo, number, title, url, author, state, draft, updated`. Add:
- `created: number`
- `head: string`
- `base: string`
- `additions: number`
- `deletions: number`
- `files: number`
- `comments: number`
- `review: string?`: `"approved"` | `"changes"` | `"required"`
- `checks: string?`: `"success"` | `"failure"` | `"pending"`
- `labels: { string }`

`state` keeps the values `"open"` | `"closed"` | `"merged"`.

**Query constants.** Replace the REST `SEARCH_JQ` with these two single-line constants. Both were verified live against `cli/cli`, cursor paging included:
```lua
local SEARCH_GQL = "query($q: String!, $after: String) { rateLimit { cost } search(query: $q, type: ISSUE, first: 100, after: $after) { issueCount pageInfo { hasNextPage endCursor } nodes { ... on PullRequest { number title url isDraft state updatedAt createdAt author { login } headRefName baseRefName additions deletions changedFiles comments { totalCount } reviewDecision labels(first: 10) { nodes { name } } commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } } } } }"
local SEARCH_JQ = "{total:.data.search.issueCount,next:(if .data.search.pageInfo.hasNextPage then .data.search.pageInfo.endCursor else null end),cost:.data.rateLimit.cost,items:[.data.search.nodes[]|{number,title,url,isDraft,state,updatedAt,createdAt,author:.author.login,head:.headRefName,base:.baseRefName,additions,deletions,changedFiles,comments:.comments.totalCount,review:.reviewDecision,checks:.commits.nodes[0].commit.statusCheckRollup.state,labels:[.labels.nodes[]?.name]}]}"
```
`PR_JQ` and `M.pr` (REST, used by worktrees) stay unchanged.

**`M.normalize(item)`** now reads the jq output shape:
- **Reject** with the existing messages when:
  - `type(item) ~= "table"` or `type(item.number) ~= "number"`: "the search returned an item that is not a pull request". A non-PR GraphQL node arrives as `{}`.
  - `M.parsePrUrl(item.url)` fails, or its number differs from `item.number`: the URL message.
  - `item.title` is not a string: the title message.
- **Map:**
  - `state`: `MERGED`→`"merged"`, `CLOSED`→`"closed"`, else `"open"`
  - `draft = item.isDraft == true`
  - `author` = the string, else `"ghost"`
  - `updated`/`created`: `M.epoch` of `updatedAt`/`createdAt`, else `0`
  - `head`/`base`: the string, else `""`
  - `additions`, `deletions`, `files` (`changedFiles`), `comments`: a non-negative number, else `0`
  - `labels`: the string entries of `item.labels`
- **Lookup tables:**
  - `REVIEW = { APPROVED = "approved", CHANGES_REQUESTED = "changes", REVIEW_REQUIRED = "required" }`
  - `CHECKS = { SUCCESS = "success", FAILURE = "failure", ERROR = "failure", PENDING = "pending", EXPECTED = "pending" }`
  - Unknown or absent keys give `nil`.

**`M.parsePage(stdout)`**
- Returns `{ total, next: string?, cost, raw, prs }`.
- Fails with the existing "gh printed something other than a search result" unless `items` is a table and `total` is a number.
- `next`: a non-empty string, else `nil`.
- `cost`: a positive number, else `1`.
- `raw = #data.items`.
- Drop `incomplete`: GraphQL has no such flag.

**`M.search`**
- The empty-query and `scopeProblem` early exits are unchanged.
- Build `q = "repo:" .. repo .. " " .. query .. " is:pr sort:updated-desc"`. The sort makes the first 1000 results the most recently updated, as REST `sort=updated` did.
- Replace `fetch(page)` with `fetch(after: string?)`. Argv:
  `{ "api", "graphql", "--hostname", "github.com", "--include", "-f", "query=" .. SEARCH_GQL, "-f", "q=" .. q }`
  When `after` is set, add `"-f", "after=" .. after`. Then add `"--jq", SEARCH_JQ`.
- Rename the done callback's third value from requests to **points spent**:
  - `spent += 1` right before each request. This mirrors today's `requests += 1`.
  - After a parsed page, `spent += pg.cost - 1`.
- `total` comes from the first page (`after == nil`).
- Stop with `finish(false)` when `pg.next == nil` or `loaded >= math.min(total, CAP)`.
- Keep the quota-exhausted `finish(true)` check.
- `complete = not cut and total <= CAP`.
- Every quota, `RATE_S` fallback and `shouldContinue` line stays as it is.

**`M.parseResponse`.** The resource filter now keeps `graphql`: `string.lower(v) ~= "graphql"` → `return nil, rest`. Update its comment. Verified: GraphQL responses carry `X-Ratelimit-Resource: graphql` with a limit of 5000 points.

**`M.classify`**
- **Rate limits.** The test becomes `string.find(err, "HTTP 429", 1, true) or string.find(low, "rate limit", 1, true)`. This replaces the old 429/403-plus-rate-limit test. GraphQL primary limits return HTTP 200, so `gh` exits 1 with stderr `gh: API rate limit exceeded…`. Verified: GraphQL errors exit 1, stdout keeps headers and body, and stderr is `gh: <message>`.
- **Unsearchable repos.** Next to the HTTP 422 check, add: `string.find(low, "cannot be searched", 1, true)` → `{ kind = "invalid", message = "GitHub rejected the search: " .. firstLines(err, 3) }`. This is GraphQL's message for a repository the account can't search.

**`M.match(pr, needle): (boolean, { number }?)`** is new. It is the queue's local search. No equivalent exists. Add `local input = require("./input")` at the top.
```lua
function M.match(pr: Pr, needle: string): (boolean, { number }?)
	local q = string.lower(string.match(needle, "^%s*(.-)%s*$") or "")
	if q == "" then
		return true, nil
	end
	local at = string.find(string.lower(pr.title), q, 1, true)
	if at then
		return true, { input.u16(pr.title, at - 1), input.u16(pr.title, at - 1 + #q) }
	end
	return string.find(string.lower("#" .. pr.number .. " " .. pr.author .. " " .. pr.head), q, 1, true) ~= nil, nil
end
```

**`plugin/tests/check.luau`**
- **Fixtures.** Rewrite `item(n, repo, updated, extra)` in the jq-output shape:
  `{ number = n, title = "T" .. n, url = "https://github.com/" .. repo .. "/pull/" .. n, author = "u", state = "OPEN", isDraft = false, updatedAt = updated, createdAt = updated, head = "b" .. n, base = "main", additions = 1, deletions = 2, changedFiles = 3, comments = 4, labels = tern.json.array({}) }`
  - `page(items, total, next)` encodes `{ total = total or #items, cost = 1, next = next, items = tern.json.array(items) }`.
- **Existing assertions, same intent:**
  - Malformed JSON and `{}` are rejected.
  - A `{}` item (non-PR) is rejected.
  - Foreign URLs and mismatched numbers are rejected.
  - Empty results parse.
  - Dedupe and order. Item 2 uses `isDraft = true`; item 3 uses `state = "MERGED"`.
  - The display spelling is preserved.
- **New behavior assertions:**
  - `review = "CHANGES_REQUESTED", checks = "ERROR", labels = tern.json.array({ "bug" })` → `review == "changes"`, `checks == "failure"`, `labels[1] == "bug"`, `additions == 1`, `files == 3`, `comments == 4`, `head == "b5"`, `base == "main"`.
  - An item whose `author` is set to `nil` after construction → `author == "ghost"`.
  - `page(..., 250, "Y3Vy")` → `next == "Y3Vy"`.
  - `github.parsePage(tern.json.encode({ total = 0, items = tern.json.array({}) }))` (no `cost` or `next` keys) → `cost == 1` and `next == nil`.
  - `github.classify` with stderr `gh: API rate limit exceeded for user ID 1.` → `rate-limit`.
  - `github.classify` with stderr `gh: The listed users and repositories cannot be searched either because the resources do not exist or you do not have permission to view them.` → `invalid`.
  - `github.match` on `normalize(item(12, "a/b", …, { title = "Fix 😀 parser", author = "octo", head = "fix/lexer" }))`:
    - `" PARSER "` → `true, {7, 13}` (a UTF-16 range)
    - `"#12"` → `true` with no range
    - `"lexer"` → `true`
    - `"zzz"` → `false`
- In the `real` header sample, change `X-Ratelimit-Resource: search` to `graphql`. Keep the `core`-is-ignored assertion.

### 2. Picker queue, prefs settings, link plumbing (`plugin/host.luau`, `plugin/input.luau`, `plugin/window.luau`, `plugin/tests/check.luau`)

The block view becomes one of two modes, chosen by `state.settings`:
- **Queue mode:**
  - `layer` = a `picker` sheet with `size = "screen"`.
  - `main` = one hidden context node.
  - No `dock`.
- **Settings mode:**
  - `main` = context node + a `prefs` page.
  - `layer` = a delete-confirm `overlay` only while one is pending.

`tern.ui` builders don't cover `picker`/`prefs`/`overlay`/`kbd`/`elapsed`, so use `ui.node(kind, props, children)` for those.

Wrap any table prop that may be empty (`items`, `order`, `scopes`) in `tern.json.array(...)`. Leave optional props `nil` instead of `{}` (`badges`, `hits`).

#### 2a. Delete what the new views replace

**`plugin/host.luau`, removed outright:**
- Types `Form`, `RepoForm`
- State fields `page`, `form`, `confirmDelete`, `repoForm`, `notice`
- Constants `LIST_ID`, `FILTERS_ID`, `FIELD_IDS`, `PAGE_SIZE`
- Functions `focusField`, `openForm`, `saveForm`, `deleteActive`, `saveRepo`, `goPage`, `formFields`, `cycle`, `cancelForms`, `activate`, `badge`, `button`, `field`, `stateWord`, `stateTone`, `problemCard`, `filtersList`, `prList`, `mainView`, `dockView`, `modelFor`, `focusedModel`
- `features = { "edit", "undo" }`. No `input`/`editor` nodes remain. Undo then arrives as ⌘Z/⌃Z keys, which `input.key` already handles.
- The `focus`/`edit`/`undo` event branches.

**`plugin/host.luau`, kept but edited:**
- In `switchFilter`, remove the `state.form = nil` and `state.confirmDelete = false` lines.
- **Definition order.** Luau locals must be defined above their first use.
  - `trim`, `itemId`, `prOfItem` and `visible` go directly above `ensureCursor`, after `selectedPr`. `showSnapshot` and `refresh` already call `ensureCursor`.
  - `moveCursor` stays in the navigation section.
  - Everything else that is new goes after `paceLine`, in this order:
    1. constants and lookup tables (`QUEUE_ID` … `HELP`)
    2. `stateKind`, `contextNode`
    3. `pageContent`, `focusRows`, `rowById`
    4. `beginEdit`
    5. `setCheckout`, `clearCheckout`, `accountChanged`, `updateFilter`, `addFilter`, `deleteFilter`
    6. `runAction`, `runRow`, `commitEdit`, `resetRow`, `openSettings`, `openSelected`
    7. `pickerItem`, `previewNodes`, `queueView`, `confirmOverlay`, `settingsView`

**`plugin/input.luau`:**
- Delete `M.edit`, `M.fromU16` and `M.len16`. Their only callers were native edit events.
- Update the header comment: offsets are converted to UTF-16 for drawn fields (picker search, settings rows).

**`plugin/tests/check.luau`:**
- Delete the `fromU16` assertion and both `input.edit` assertions.
- Replace `input.len16(m.text) == 4` with `input.u16(m.text, #m.text) == 4`.

#### 2b. State and helpers (`plugin/host.luau`)

```lua
type Settings = {
	page: string,                                    -- "filters" | "github" | "worktrees"
	focus: string?,                                  -- focused prefs row id
	edit: { row: string, model: input.Model }?,      -- text row being edited
	errors: { [string]: string },                    -- row id -> warning under the row
	busy: boolean,                                   -- checkout path being verified
	confirm: string?,                                -- filter id awaiting delete confirmation
}
```

**`State`:**
- `focus` becomes `"list" | "scopes"`, the picker part the keys drive. Default `"list"`.
- Add `query: input.Model?`. `nil` means the search is hidden.
- Add `settings: Settings?`.
- `init` sets `focus = "list"`, `query = nil`, `settings = nil`.
- `save` is unchanged.

**Constants:**
- `QUEUE_ID = "layer.queue"`
- `SETTINGS_ID = "main.settings"`
- `PAGES = { "filters", "github", "worktrees" }`
- `PAGE_DEFS`:
  `{ { id = "filters", label = "Filters", group = "Queue", icon = "funnel" }, { id = "github", label = "GitHub", group = "Connection", icon = "globe" }, { id = "worktrees", label = "Worktrees", group = "Connection", icon = "tree" } }`
- `NO_REPO = "No GitHub repository for the launch directory."`

**Helpers:**
- `itemId(pr)` returns `"n" .. pr.number`. Search is scoped to one repo, so numbers are unique. Use this, not `pr.key`, so picker ids hold no `/` or `#`.
- `prOfItem(state, id)` scans `state.snap.prs` for the match.
- `visible(state)`: no snapshot → `{}`; blank query text → `snap.prs`; otherwise the PRs where `github.match(pr, state.query.text)` is true.
- `ensureCursor(state)` is rewritten: if `indexOf(visible(state), state.cursor) == 0`, set `state.cursor` to the first visible PR's key, or `nil`.
- `moveCursor(state, delta)` is rewritten: clamp `index + delta` inside `visible(state)`. Home/End pass `-100000`/`100000`.
- `selectedPr` is unchanged.
- `openSelected(state, kind, rerender)`: with a selected `pr`, call `if rerender then state.cx:render() end` then `state.cx:open(prHref(kind, pr))`. `prHref` is unchanged.
- `contextNode(state)` returns `ui.node("text", { key = "context", text = state.launchCwd or "", hidden = true })`. `window.luau` reads `main.context` for worktrees.
- `stateKind(pr)`: `pr.state` when merged or closed, else `"draft"` if `pr.draft`, else `"open"`.
- **Lookup tables:**
  - `STATE_BADGE = { open = { text = "Open", tone = "success" }, draft = { text = "Draft", tone = "muted" }, merged = { text = "Merged", tone = "accent" }, closed = { text = "Closed", tone = "error" } }`
  - `REVIEW_BADGE = { approved = { text = "Approved", tone = "success" }, changes = { text = "Changes requested", tone = "error" }, required = { text = "Review required", tone = "warning" } }`
  - `CHECK = { success = { text = "Passing", tone = "success", dot = "success" }, failure = { text = "Failing", tone = "error", dot = "error" }, pending = { text = "Pending", tone = "warning", dot = "pending" } }`
- **`HEADS`:**
  - `missing` = "GitHub CLI not found"
  - `auth` = "GitHub CLI not signed in"
  - `rate-limit` = "GitHub rate limit"
  - `not-found` = "Repository not visible"
  - `invalid` = "GitHub rejected the search"
  - `no-repo` = "No GitHub repository"
  - `failed` = "Could not load pull requests"
- **`HELP`:**
  - `missing` = "Install the GitHub CLI (cli.github.com) so it is on your shell's PATH, then Refresh."
  - `auth` = "Run gh auth login in a terminal, then Refresh."
  - `rate-limit` = "Searches resume automatically when GitHub's limit resets."
  - `not-found` = "Check this repository's account in Settings › GitHub, then Refresh."
  - `invalid` = "Check the filter query and this repository's account in Settings, then Refresh."
  - `no-repo` = "Open Plotroom from a checkout of a GitHub repository."
- **`paceLine`:**
  - Change the `" · search quota "` wording to `" · GraphQL quota "`.
  - In both "… then Retry." texts, change "Retry" to "Refresh".
- **`refresh`:**
  - Rename its done-callback variable `requests` to `spent` (points). Same logic.
  - In the rate-limit branch, set the problem message to `"GitHub's rate limit is reached; searches resume at " .. os.date("%H:%M:%S", os.time() + wait) .. "."`. The picker error card has no time line above it.

#### 2c. Queue view (`queueView(state): BlockView`)

**`pickerItem(pr)`** returns:
```lua
{
	id = itemId(pr),
	label = pr.title,
	title = pr.title, -- row tooltip
	detail = "#" .. pr.number .. " · " .. pr.author .. " · " .. pr.head,
	mark = { text = pr.author, seed = pr.author }, -- initials avatar
	dot = if check then check.dot else nil, -- CI corner dot; check = if pr.checks then CHECK[pr.checks] else nil
	badges = <nil when empty>,
	facts = {
		changes = { ui.span("+" .. pr.additions, "ins"), " ", ui.span("−" .. pr.deletions, "error") },
		updated = github.age(pr.updated),
	},
}
```
Deletions use the `error` token, not `del`. In a plugin, `del` draws grey and struck through, because `--sf-c-del` falls back to `--t3`. The same applies to the diff meter below.

Badge order, at most three shown (the picker adds "+N" for the rest):
1. `STATE_BADGE[stateKind(pr)]` unless the PR is open
2. `REVIEW_BADGE[pr.review]` when `pr.review` is set. Never index a lookup table with `nil`.
3. one `{ text = label }` per label (no tone)

**`previewNodes(state)`** builds the picker children. Nothing is selected → `{}`, which shows "Nothing to preview". Otherwise, in order:
1. `ui.node("text", { key = "title", role = "plotroom.title", spans = { ui.span(pr.title, "strong") } })`
2. `ui.node("row", { key = "chips", gap = "xs", wrap = true }, …)`: one badge node `{ key = "state", text, tone }` from `STATE_BADGE`, then `{ key = "label" .. i, text = label }` per label.
3. `ui.node("kv", { key = "facts", items = facts })`. A raw `kv` node needs named `{ k = …, v = … }` items; positional pairs draw nothing:
   ```lua
   local facts = {
     { k = "Number", v = "#" .. pr.number },
     { k = "Author", v = "@" .. pr.author },
     { k = "Branch", v = pr.head .. " → " .. pr.base },
     { k = "Checks", v = if check then ui.span(check.text, check.tone) else ui.span("None", "muted") },
     { k = "Review", v = if review then ui.span(review.text, review.tone) else ui.span("None", "muted") },
     { k = "Comments", v = ui.span(tostring(pr.comments), "num") },
     { k = "Opened", v = github.age(pr.created) .. " ago" },
     { k = "Updated", v = github.age(pr.updated) .. " ago" },
   }
   ```
   Here `check = if pr.checks then CHECK[pr.checks] else nil` and `review = if pr.review then REVIEW_BADGE[pr.review] else nil`.
4. When `additions + deletions > 0`, a diff meter:
   ```lua
   ui.node("meter", {
     key = "diff",
     parts = {
       { value = a / (a + d), token = "ins", label = "+" .. a },
       { value = d / (a + d), token = "error", label = "−" .. d },
     },
     label = { ui.span("+" .. a, "ins"), " ", ui.span("−" .. d, "error") },
     total = files .. (files == 1 and " file" or " files"),
   })
   ```
5. `ui.el("div", { key = "buttons", class = "plotroom-actions" }, …)` holding three buttons:
   - `ui.el("button", { key = "open", class = "plotroom-btn primary", text = "Open", href = prHref("open", pr), actions = { click = "open" }, title = "Open in a Browser block" }, { ui.node("kbd", { keys = { "enter" } }) })`
   - `ui.el("button", { key = "worktree", class = "plotroom-btn", text = "Worktree", href = prHref("worktree", pr), actions = { click = "open" }, title = "Check out in a worktree tab" }, { ui.node("kbd", { keys = { "w" } }) })`
   - `ui.el("button", { key = "copy", class = "plotroom-btn", text = "Copy link", href = pr.url, actions = { click = "copy" } })`

   The built-in `open` action routes the click through the clicking window's `tern.route.link`, so a click opens in that window only. The built-in `copy` action copies `href`. Node ids become `layer.queue.buttons.open` / `.worktree`.

**Picker props**
- Snapshot-derived: `items` = `pickerItem` for every `snap.prs` entry. `order` = `itemId` of `visible(state)`. `hits[itemId] = { range }` for each `github.match` range. Set `hits` to `nil` when empty.
- `key = "queue"`, `size = "screen"`, `layout = "cards"`, `preview = "side"`, `icon = "merge"`.
- `title` (spans):
  - The active filter name, else `"Pull requests"`.
  - Plus `ui.span("  stale", "warning")` when a snapshot and a problem coexist.
  - Else plus `ui.span("  partial", "warning")` when `not snap.complete`.
- `subtitle` (spans):
  - `ui.span(state.repo or "No repository", "muted")`
  - then either:
    - while `state.loading`: `" · "` plus a shimmering `Refreshing…`. Write it as `local busy: any = ui.span("Refreshing…", "muted")` then `busy.fx = "shimmer"`. Never start a statement with `(`: Luau parses it as a call on the previous line.
    - otherwise: `" · updated HH:MM"`, from `snap.fetched`
  - with a problem and a snapshot: `" · <HEADS[kind]>, showing the last results"` (warning)
  - when partial: `" · Partial results: narrow this filter"` (warning)
  - with `storeError`: `" · " .. storeError` (error)
- Search fields:
  - `noun = "pull requests"`, `placeholder = "Filter the loaded pull requests"`
  - `query`/`cursor` from `input.props(state.query)` (`text` and `cursor`). Both `nil` when not searching.
- Loading and error states:
  - `state`: `"error"` when there is no snapshot and a problem; `"loading"` when there is no snapshot and an active filter; else `"ready"`.
  - `message` (error only): `{ ui.span(HEADS[kind] or "Plotroom", "strong"), "  ", problem.message, "  ", ui.span(HELP[kind] or "", "muted") }`.
  - `empty`: `"No pull requests match " .. f.name .. "."`, or `"No saved filters yet. Press s to add one."` without filters.
  - `total = snap and snap.total`. The count then reads "shown of total" while searching or when partial.
- Selection and focus: `selected = if pr then itemId(pr) else nil` (with `pr = selectedPr(state)`), `focus = state.focus`.
- `scopes`: one `{ id = f.id, label = f.name, icon = "funnel", group = "Filters", count = #cached.prs }` per stored filter. `cached = state.snaps[snapKey(state, f.query)]` when `state.repo` is set; `count = nil` when nothing is cached. `scope = state.activeId`.
- `columns = { { id = "changes", head = "Changes", format = "text", priority = 50 }, { id = "updated", head = "Updated", format = "time", priority = 90 } }`
- `actions`, in this order:
  - `{ id = "clear", label = "Clear search", keys = { "esc" } }`, only while `state.query`
  - `{ id = "search", label = "Search", keys = { "/" } }`
  - `{ id = "filters", label = "Filters", keys = { "tab" } }`, only when `#state.store.items > 0`. Otherwise the empty state would offer it as its button.
  - `{ id = "settings", label = "Settings", keys = { "s" } }`
  - `{ id = "retry", label = "Refresh", keys = { "r" }, disabled = <"Paused by GitHub until HH:MM:SS" while github.wait > 0> }`. The id `retry` is what the picker's error card offers as its button.
  - `{ id = "worktree", label = "Worktree", keys = { "w" }, ["end"] = true, disabled = <"Select a pull request" without one> }`
  - `{ id = "open", label = "Open", keys = { "enter" }, primary = true, disabled = <same> }`

**Return value:** `{ main = ui.col({ contextNode(state) }), layer = ui.col({ ui.node("picker", props, previewNodes(state)) }) }`.

**`title(state)`:** `"Plotroom · " .. (activeFilter and its name or "GitHub PRs") .. (snap and " (" .. #snap.prs .. ")" or "")`.

#### 2d. Settings view (`settingsView(state): BlockView`)

`pageContent(state)` returns `sections, lead, extra` for `state.settings.page`. `focusRows(state)` and `rowById(state, id)` both read the same sections, so view, keys and events share one row source. `focusRows` lists row ids in order, skipping rows with `disabled`.

`local where = state.repo or "the launch repository"` is used in the strings below. When the filter store is not writable, every filter row gets `disabled = locked`, with `local locked = if state.writable then nil else (state.storeError or "Saved filters are read-only.")`.

**Filters page**
- `lead` = `"Saved GitHub searches, listed in the queue's filter column. Each runs inside " .. where .. ", so repo:, org:, user: and OR are not allowed."`
- One section per filter: `{ id = "filter:" .. f.id, title = f.name .. (active and " · showing" or "") }`, with three rows:
  - `{ id = "name:" .. id, label = "Name", control = { k = "text", value = f.name, placeholder = "My PRs" } }`
  - `{ id = "query:" .. id, label = "Query", hint = "GitHub search syntax, run inside " .. where .. ".", control = { k = "text", value = f.query, placeholder = "is:open author:@me", mono = true } }`
  - `{ id = "delete:" .. id, label = "Delete filter", control = { k = "action", act = "delete", label = "Delete" } }`
- A last section `{ id = "new" }` with `{ id = "add", label = "New filter", hint = "Adds a filter for open pull requests; name it and edit its query.", control = { k = "action", act = "add", label = "Add filter" } }`.
- Each row carries `warning = s.errors[row.id]` and `disabled = locked`.

**GitHub page**
- `lead` = "Plotroom reads pull requests through GitHub's GraphQL API with your gh login."
- Section `sec-account` (title "Account"), one row:
  `{ id = "account", label = "gh account", hint = "Login used for " .. where .. ". Empty: the active gh account.", control = { k = "text", value = github.account(repo) or "", placeholder = "Active gh account" }, changed = <account set>, defaultLabel = "Active gh account", warning = s.errors.account, disabled = <NO_REPO without state.repo> }`
- Section `sec-refresh` (title "Refresh"), one row:
  `{ id = "refresh", label = "Refresh now", hint = paceLine(state) or "Refreshes every minute while quota allows.", control = { k = "action", act = "refresh", label = "Refresh" } }`
  - `disabled` = `"Paused by GitHub until HH:MM:SS"` while waiting, else `NO_REPO` without a repo.
- `extra` = `{ ui.node("card", { key = "quota", head = { ui.span("GitHub API quota", "strong") } }, kids) }`, only when `github.quota(acct(state))` has `limit` and `remaining`. `kids`:
  - `ui.node("meter", { key = "used", value = 1 - remaining / limit, thresholds = { warn = 0.8, bad = 0.95 }, label = { ui.span(remaining .. " of " .. limit .. " points left", "num") }, total = q.reset and ("resets " .. os.date("%H:%M", q.reset)) })`
  - When `state.timer and state.nextAt > now`, also a countdown row:
    `ui.node("row", { key = "next" }, { ui.text({ ui.span("Next refresh in", "muted") }), ui.node("elapsed", { age = (now - state.nextAt) * 1000, format = "clock" }) })`
    A negative age counts down.

**Worktrees page**
- `lead` = `"Worktree checks a pull request out in <checkout>.plotroom/<owner>/<repo>/pr-N on branch plotroom/<owner>/<repo>/pr-N and opens it in a new tab."` This is a plain string: the angle-bracket words are literal text, and there are no backticks.
- Section `sec-checkout` (title "Local checkout"), one row:
  `{ id = "checkout", label = if state.repo then "Checkout of " .. state.repo else "Local checkout", hint = "Used when the launch directory (" .. (state.launchCwd or "none") .. ") is not a checkout of " .. where .. ".", control = { k = "text", value = <mapped path or "">, placeholder = state.launchCwd or "~/Code/repo", mono = true }, changed = <mapping set>, defaultLabel = "Launch directory", warning = s.errors.checkout }`
  - Section ids differ from row ids because prefs `focus` accepts either.
  - `disabled` = `"Checking the checkout…"` while `s.busy`, else `NO_REPO` without a repo.
  - The mapped path is `readRepos()["github.com/" .. string.lower(state.repo)]` when that is a string, else `""`. Reuse `readRepos` (storage section) for this read; its only other caller, `saveRepo`, is deleted. Writes still go through `setCheckout`, which fails closed.

**View**
- `prefs` props: `{ key = "settings", title = "Plotroom", pages = PAGE_DEFS, page = s.page, lead, sections, focus = s.focus, editing }`.
  - While editing, `editing = { row = s.edit.row, draft = p.text, cursor = p.cursor }` with `p = input.props(s.edit.model)`.
- `main = ui.col({ contextNode(state), ui.node("prefs", props, extra) })`.
- While `s.confirm` is set, `layer = ui.col({ overlay })`. The overlay:
  ```lua
  ui.node("overlay", { key = "confirm", modal = true, size = "sm", head = "Delete filter “<name>”?" }, {
    ui.node("text", { key = "body", spans = { ui.span("Every Plotroom pane loses this saved search.", "muted") } }),
    ui.el("div", { key = "buttons", class = "plotroom-actions" }, {
      -- Delete: class "plotroom-btn danger", click "confirm-delete", kbd { "enter" }
      -- Keep:   class "plotroom-btn",        click "cancel-delete",  kbd { "esc" }
    }),
  })
  ```

#### 2e. Settings logic (`plugin/host.luau`)

**Opening and editing**
- `openSettings(state, page, row?, edit?)` sets `state.settings = { page = page, focus = row, errors = {}, busy = false }`. With `edit`, it calls `beginEdit(state, row)`.
- `beginEdit(state, row, initial?)`:
  - Ignore missing rows, disabled rows, and non-`text` controls.
  - Set `s.focus = row`, clear `s.errors[row]`.
  - `s.edit = { row, model = input.new(initial or def.control.value) }`.
- `runAction(state, act, row)`:
  - `add` → `addFilter`
  - `delete` → `s.confirm = string.match(row, "^delete:(.+)$")`
  - `refresh` → `retry(state)`
- `runRow(state, row?)`: return at once when `row` is `nil` (every row may be disabled). Text rows → `beginEdit`; action rows → `runAction`. Disabled rows do nothing.

**`commitEdit(state)`** uses `text = trim(model.text)`:
- **`name:<id>` / `query:<id>`:**
  - Empty text → `errors[row]` = "A name is required." / "A query is required."
  - For queries, a `github.scopeProblem(text)` result goes to `errors[row]`.
  - Otherwise call `updateFilter(state, id, fn)`. It reuses `saveForm`'s reread-then-write rules:
    - `loadStore()`
    - not writable → record `storeError` and return it
    - id gone → "That filter was deleted elsewhere."
    - apply `fn`, then `writeStore`; a failure returns "Could not save: …"
    - set `state.store/writable/storeError`
    - if `id == state.activeId` and the query changed → `changed(state)`
    - `propagate(state)`
  - A returned error goes to `errors[row]`. Success clears `s.edit`.
- **`account`:**
  - `github.setAccount(state.repo, text)`. An error goes to `errors.account`.
  - On success: clear `s.edit`, then `accountChanged(state)`. This is today's `saveRepo` account branch:
    - `gen += 1`
    - `snaps, snap, problem = {}, nil, nil`
    - `state.cx:toast("success", "GitHub account saved", "Refreshing " .. repo)`
    - `retry(state)`
- **`checkout`:**
  - Empty text → `clearCheckout`.
  - Otherwise `worktree.expandPath(text, tern.getenv("HOME"))`. A failure goes to `errors.checkout`.
  - Then `s.busy = true`, `s.edit = nil`, and call `worktree.resolveRepository(path, state.repo, cb)`.
  - The callback returns early unless `alive(state) and state.settings == s`. It sets `s.busy = false`.
  - Failure → `beginEdit(state, "checkout", text)` first, then `s.errors.checkout = problem`. `beginEdit` clears the row's error, so this order keeps the warning.
  - Success → `local err = setCheckout(state, info.root)`. An error goes to `s.errors.checkout`, with no toast. Otherwise `state.cx:toast("success", "Checkout saved", info.root)`.
  - Either way it calls `state.cx:render()`.

**Storage helpers**
- `setCheckout(state, root?)` reads the map with `pcall(tern.kv.get, "repos")`. It **fails closed**: a read error returns "Saved checkouts could not be read" rather than overwriting. It sets or clears `"github.com/" .. lower(repo)` and `pcall(tern.kv.set, …)`, returning an error string or `nil`.
- `clearCheckout` = `setCheckout(state, nil)`, then toast "Checkout cleared".
- `resetRow(state, row)` handles prefs Reset:
  - `account` → `setAccount(repo, nil)`, then `accountChanged`
  - `checkout` → `clearCheckout`
  - Errors go to `errors[row]`.

**Filter add and delete**
- `addFilter(state)`:
  - `loadStore()`; not writable → `errors.add`.
  - `id = "f" .. nextId`, `nextId += 1`.
  - Insert `{ id, name = "New filter", query = "is:open" }`, then `writeStore`.
  - Set the store fields, then `switchFilter(state, id)` (matches today's New flow), then `propagate`.
  - Finally `beginEdit(state, "name:" .. id, "")`.
- `deleteFilter(state, id)` generalizes `deleteActive`:
  - Clear `s.confirm`, reread the store, remove `id`, `writeStore`. Errors go to `errors["delete:" .. id]`.
  - If it was active, `switchFilter` to the neighbor (`items[min(at, #items)]`).
  - `s.focus = "add"`, then `propagate`.

#### 2f. Keys (`key` handler)

**Settings mode, checked in this order:**
1. With `s.confirm`: Enter → `deleteFilter`; Escape → cancel; other keys → `false`.
2. With `s.edit`: Escape → `s.edit = nil`; Enter → `commitEdit`; else `input.key(s.edit.model, key, function(t) cx:copy(t) end)`, returning `false` when that returns false.
3. Otherwise:
   - Escape → `state.settings = nil`.
   - Tab / Shift+Tab → cycle `PAGES`; reset `focus`, `edit` and `errors`.
   - Up/Down → move `s.focus` through `focusRows`. From `nil`, Down picks the first row and Up picks the last.
   - Enter/Space → `runRow(state, s.focus)`.
   - Anything else → `false`.

**Queue mode** (`plain` = no ctrl/alt/meta):
- **Tab** (plain) toggles `state.focus` between `"list"` and `"scopes"`.
- **Movement:**
  - Up/Down move the cursor in list focus and call `moveFilter` in scopes focus. When not searching, `k`/`j` do the same.
  - Page Up/Page Down move the cursor by 10 (list focus).
  - Home/End go to the first/last row, or filter, only when not searching (they edit the query while searching).
- **Enter:** in scopes focus it switches focus to `"list"`; otherwise `openSelected(state, "open", false)`.
- **Escape:**
  - While searching: non-empty text → `input.new("")`; else `state.query = nil`. Then `ensureCursor`.
  - Else in scopes focus → `"list"`.
  - Else → `false`.
- **While searching**, every other key goes to `input.key(state.query, …)`. Call `ensureCursor` when the text changed. Unhandled keys return `false`.
- **Plain single keys**, only when not searching:
  - `/` → `state.query = input.new("")`
  - `r` → `retry`
  - `s` → `openSettings(state, "filters")`
  - `w` → `openSelected(state, "worktree", false)`
  - else → `false`

#### 2g. Events (`event` handler)

Keep the `alive` guard. Dispatch on `act` first; these acts can arrive without an id:
- `choose-repo` (sent by `window.luau` on `worktree.NO_REPO`) → `openSettings(state, "worktrees", "checkout", true)`
- `confirm-delete` → `deleteFilter(state, state.settings.confirm)`, only when `state.settings and state.settings.confirm`; otherwise a no-op
- `cancel-delete` → `state.settings.confirm = nil` under the same guard

**Settings mode** handles only `ev.id == SETTINGS_ID`:
- `action page` (with a valid `value`) → switch page and clear `focus`/`edit`/`errors`.
- `action close`: without `value` → `state.settings = nil`; with one → `s.edit = nil`.
- `action add|delete|refresh` (`value = row`) → `s.focus = value` and `runAction`.
- `activate` → `beginEdit(item)`.
- `select` → `s.focus = item`.
- `change` with `value == nil or value == tern.json.null` (Reset) → `resetRow(item)`.

**Queue mode** handles only `ev.id == QUEUE_ID`:
- `select` → `local pr = prOfItem(state, ev.item)`. If it is `nil` (a refresh replaced the snapshot), ignore the event. Otherwise `state.cursor = pr.key`, `state.focus = "list"`.
- `activate` → set the cursor the same way, ignoring `nil`, then `openSelected(state, "open", true)`. The explicit render sends the new preview before the open request.
- `action scope` → `focus = "list"`. If `value` is a stored filter id and is not active, `switchFilter`.
- `action clear` or `close` → `state.query = nil`, then `ensureCursor`.
- `action search` → `state.query = state.query or input.new("")`.
- `action filters` → toggle focus.
- `action settings` → `openSettings(state, "filters")`.
- `action retry` → `retry(state)`.
- `action open` or `worktree` → `openSelected(state, act, false)`.

`view = function(state) return if state.settings then settingsView(state) else queueView(state) end`.

#### 2h. Link plumbing (`plugin/window.luau`)

1. Add `local OPEN_NODE = "layer.queue.buttons.open"` and `local WORKTREE_NODE = "layer.queue.buttons.worktree"`.
2. `handle`: replace the presence block with one check: `nodeProp(readNode(cx, pane, if kind == "open" then OPEN_NODE else WORKTREE_NODE), "href") == url`. Keep the existing "no longer listed" toast.
3. `openPr`: delete the "Keep the dock's selection…" comment and its `cx.session:event(... "select" ...)` line. Rows are no longer nodes, and the preview already shows the selected PR.
4. The `open-selected` / `worktree-selected` commands call `selected(cx, OPEN_NODE)` / `selected(cx, WORKTREE_NODE)`.
5. Remove `local github = require("./github")`. It has no other use in this file.

Enter, `w`, a double-click on a row and the action bar all reach this path through host `cx:open`. A preview-button click reaches it through the window's own route.

### 3. Styles (`plugin/plotroom.css`, full replacement)

Delete every current rule; they style the removed list. New sheet: every selector starts with `[data-surface='plugin.plotroom.prs']`, and colors come only from Tern tokens.
- **Picker head:** `.sf-picker.no-query .pk-esc { display: none; }`. With no search open, Esc has nothing to close.
- **Settings:** `.sf-prefs .pf-search { display: none; }`. There are too few rows to need search.
- **Preview title:** `[data-role='plotroom.title'] { font-size: 15px; line-height: 1.35; }`
- **Button row:** `.plotroom-actions { display: flex; flex-wrap: wrap; gap: 6px; }`
- **Buttons:**
  - `button.plotroom-btn { display: inline-flex; align-items: center; gap: 8px; padding: 4px 10px; border-radius: var(--r-ctl); background: var(--raise); box-shadow: inset 0 0 0 1px var(--l3); color: var(--t1); font-family: var(--sans); font-size: 12px; transition: background-color 120ms var(--ease), transform 120ms var(--out); }`
  - `:hover { background: var(--l2); }`
  - `:active { transform: scale(0.97); }`
  - `.primary { background: var(--accent-fill); box-shadow: none; color: #fff; }`
  - `.danger { background: var(--bad-fill); box-shadow: none; color: #fff; }`
  - `.primary .kbd, .danger .kbd { background: rgba(255, 255, 255, 0.18); box-shadow: none; color: #fff; }`
  - `@media (prefers-reduced-motion: reduce) { … button.plotroom-btn { transition: none; } }`
- **Header comment:** "Every rule is scoped to the block's regions; colors, radii and fonts are Tern tokens."
- Do not add `cursor: pointer`. Tern draws actions with the arrow cursor.

## Critical files & anchors

| File | Anchor | Why |
| --- | --- | --- |
| `plugin/host.luau` | Section dividers `editing`, `repository mapping`, `navigation`, `view` and `block` (`-- ---… <name>`); `switchFilter`; `readRepos` | Everything in those five sections is replaced except `trim`, `moveCursor`, `moveFilter`, `prHref`, `duration` and `paceLine`. The `storage` and `lifecycle` sections (`refresh`, `schedule`, `retry`, `changed`) are kept. |
| `plugin/github.luau` | `SEARCH_JQ`, `M.normalize`, `M.parsePage`, `M.search`, `M.parseResponse`, `M.classify` | The REST search becomes GraphQL. Quota pacing math is untouched. |
| `plugin/window.luau` | `openPr`, `handle`, the `open-selected`/`worktree-selected` commands | Link validation moves to the preview button nodes. |
| `plugin/tests/check.luau` | `item`/`page` helpers, the search-page asserts, the `input` asserts | Fixtures change shape. The new parser, classify and match asserts go here. |
| `plugin/input.luau` | `M.edit`, `M.fromU16`, `M.len16` | Dead once native edit events go away. |

## Verification

**Prerequisites**
- Run commands from the repo root, `/Users/user/Code/andyhite/tern-plotroom`.
- The plugin is linked from `plugin/`: `tern plugin list` shows `plotroom 0.1.0 … ready`, and `~/Library/Application Support/Tern/plugins/plotroom.path` contains `/Users/user/Code/andyhite/tern-plotroom/plugin`. Saving any file under `plugin/` reloads the plugin.
  - If `plotroom.path` names any other directory, run `tern plugin unlink plotroom && tern plugin link ./plugin`. Never link the repo root: Tern would also watch `.git` and reload the plugin every 1–2 s.
- `gh` is signed in.
- Fixture: `git clone --depth 1 https://github.com/cli/cli /tmp/plotroom-fixture/cli` (a public repo with reviews, CI and labels).

**Dev window and self-test.** Start the window and session once. Rerun the last two commands after each step:
```sh
PLOTROOM_SELFTEST=1 tern --control /tmp/plotroom-ui.sock &
C="tern ctl --control /tmp/plotroom-ui.sock"
$C ready && $C session new plotroom-dev && $C ready
$C run "cd /tmp/plotroom-fixture/cli"
$C plugins run plugin.plotroom.selftest     # runs plugin/tests/check.luau: toast "Plotroom self-test passed"; a failed assert is an error toast
tern plugin list                            # plotroom … ready
```

**Step 1 (data):** the self-test passes, and the old list still loads PRs. Open it with `$C plugins run plugin.plotroom.open`.

**Step 2–3 (UI)**, in the dev window after `$C plugins run plugin.plotroom.open`. Each item gives the action, then the expected result.
1. **Queue renders as a picker.**
   - Run `$C tree "[data-surface='plugin.plotroom.prs'] .sf-picker"`.
   - Expect count 1, with "My PRs" and "Review requested" in the scope column.
2. **Settings page and filter creation.**
   - Keys: `$C key s`, `$C key ArrowUp` (focuses "New filter"), `$C key Enter`, `$C type "Open PRs"`, `$C key Enter`, `$C key ArrowDown` (Query row), `$C key Enter` (edit), `$C key Enter` (commit), `$C key Escape` (close settings).
   - The harness uses DOM key names: `Enter`, `Escape`, `Tab`, `ArrowUp`, `ArrowDown`. Single characters (`s`, `w`, `/`) stay as they are.
   - Expect a full Preferences-style page with Filters/GitHub/Worktrees nav.
   - After Escape, the queue shows the "Open PRs" scope selected with a count.
   - `$C shot plotroom-queue` shows two-line rows:
     - initials avatars with CI corner dots
     - Merged/Draft/Approved/Changes-requested badges and labels
     - a "+N −M" Changes column and an Updated column
     - a preview with title, kv facts, a green/red diff meter and Open/Worktree/Copy link buttons with keycaps
     - an action bar reading Search / · Filters ⇥ · Settings S · Refresh R · Worktree W · Open ⏎
3. **Search.**
   - Run `$C key /`, `$C type "fix"`.
   - Expect the count to read "N of M" and "fix" marked in titles (`$C shot plotroom-search`).
   - Then `$C key Escape` twice; the full list returns.
4. **Open.** The Browser docks with focus, so refocus the queue with `$C focus left` after each open.
   - `$C key Enter` → exactly one Browser block docks right on `github.com/cli/cli/pull/<selected>` (`$C shot plotroom-open`). Then `$C focus left`.
   - `$C dblclick "[data-surface='plugin.plotroom.prs'] .pk-row:not(.sel)"` → that PR opens, with no "no longer listed" toast. Then `$C focus left`.
   - `$C plugins run plugin.plotroom.open-selected` → it opens too. Then `$C focus left`.
5. **Worktree.**
   - `$C key w` → toast "Worktree ready for cli/cli#N" and a new tab "PR #N · cli". Then `$C previous-tab` returns to the queue.
   - `git -C /tmp/plotroom-fixture/cli worktree list` includes `/tmp/plotroom-fixture/cli.plotroom/cli/cli/pr-N`.
6. **Settings: GitHub page.**
   - In the queue, run `$C key s`, then `$C key Tab`.
   - Expect the "GitHub API quota" card: a meter reading "… of 5000 points left" and a ticking "Next refresh in" countdown.
7. **Settings: Worktrees page.**
   - Run `$C key Tab`, `$C key ArrowDown`, `$C key Enter`, `$C type "/nonexistent"`, `$C key Enter`.
   - Expect a warning under the Checkout row and no mapping saved (the `kv.json` `repos` key is unchanged).
   - Then `$C key Escape` closes the reopened edit.
8. **Delete filter.**
   - Run `$C key Tab` (to Filters), `$C key ArrowUp` twice (New filter, then "Delete filter" under "Open PRs"), `$C key Enter`.
   - Expect a modal "Delete filter “Open PRs”?".
   - Then `$C key Enter` deletes it and `$C key Escape` closes settings. The queue falls back to a remaining filter.
9. **Error state.**
   - Run `$C focus left` (the shell), `$C run "cd /tmp"`, then `$C plugins run plugin.plotroom.open`.
   - Expect the picker error card "No GitHub repository" with a Refresh button.
10. **Wrap up.** Close the dev session (`$C session close`) and quit (`$C quit`).

## Assumptions & contingencies

- **Multiple windows (accepted by the user).** Enter, `w`, row activation and the action bar open through host `cx:open`. Every window showing the session runs the route, so a session shown in two windows opens two Browsers. A preview-button click stays window-local.
- **Route pane.** If `handle` rejects host opens with "link did not come from a Plotroom block" (the route's `link.pane` is not the block's pane): in `handle`, fall back to `cx.session:focused()` when that pane `isPlotroom`.
- **Open/frame race.** If double-clicking a non-selected row toasts "no longer listed" (the open beat the frame): in `openSelected`, send the open from `tern.timer(0, function() if alive(state) then state.cx:open(href) end end)` instead.
- **Picker child nodes unreadable.** If `cx.session:surface(pane, { root = "layer.queue.buttons.open" })` finds nothing: add two hidden carrier nodes to `main` in queue mode, `ui.node("text", { key = "open", text = "", hidden = true, href = prHref("open", pr) })` and the same for `worktree`. Point `OPEN_NODE`/`WORKTREE_NODE` at `main.open`/`main.worktree`.
- **Hidden context node.** If `main.context` can't be read while `hidden`: drop `hidden` in queue mode only. The screen picker covers `main` anyway.
- **Row rebuilds.** If typing in search visibly rebuilds or flickers rows: cache the `items` array in state per `state.snap` and reuse the same table.
- **Kinds missing.** If `tree` shows no `.sf-picker` or `.sf-prefs` (the kind is drawn as a plain div): stop and report. Do not build a substitute UI.
- **Scope choices; the user can override any of these:**
  - Labels render as untoned badges (picker badges take tones, not GitHub hex colors).
  - Avatars are initials (`mark`), not GitHub images.
  - Settings search is hidden.
  - Filters can't be reordered.
