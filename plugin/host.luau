--!strict
-- The `prs` block: a live GitHub PR queue with saved, editable filters.

local github = require("./github")
local input = require("./input")
local process = require("./process")
local worktree = require("./worktree")

local ui = tern.ui

local POLL_MS = 60 * 1000
local COST_GUESS = 10
local DETAIL_DEBOUNCE_MS = 300 -- the cursor must rest this long on a PR before its checks load
local DETAIL_RETRY_S = 15 -- a failed checks load tries again after this long, doubling up to DETAIL_RETRY_MAX_S
local DETAIL_RETRY_MAX_S = 300
local NOTE_CAP = 20 -- worktree reports kept per block

type Filter = { id: string, name: string, query: string }
type Store = { version: number, nextId: number, items: { Filter } }
-- `rows` caches the picker rows; `rowsRev` (worktree reports) and `rowsMin` (the minute, for the ages) say what built them.
type Snap = {
	prs: { github.Pr },
	total: number,
	complete: boolean,
	fetched: number,
	rows: { any }?,
	rowsRev: number?,
	rowsMin: number?,
	rowsOpen: string?, -- the open-in-a-tab PR numbers, comma-joined
}
-- What the local search lets through: computed once per snapshot and search text.
type Visible = { snap: Snap, needle: string, prs: { github.Pr }, order: { string }, hits: { [string]: any }? }
type Detail = { runs: { github.Run }, total: number }
-- A checks load that failed: why, how often, and when to try again (nil: only an explicit Retry).
type DetailFail = { problem: github.Problem, tries: number, retryAt: number? }
-- The one checks load waiting out its debounce or retry delay. Its identity is the table: only the owner may clear it.
type Attempt = { key: string, timer: TimerHandle? }
-- What the window last reported about a PR's worktree (act "worktree-status"); kept in memory only.
type Note = {
	seq: number,
	at: number,
	ok: boolean,
	created: boolean,
	current: boolean,
	dirty: boolean?,
	path: string?,
	branch: string?,
	summary: string?,
	message: string?,
	update: { string },
	cleanup: { string },
}
type Settings = {
	page: string, -- "filters" | "github" | "worktrees"
	focus: string?, -- focused prefs row id
	edit: { row: string, model: input.Model }?, -- text row being edited
	errors: { [string]: string? }, -- row id -> warning under the row
	busy: boolean, -- checkout path being verified
	confirm: string?, -- filter id awaiting delete confirmation
}

type State = {
	cx: BlockCx,
	launchCwd: string?,
	activeId: string?,
	store: Store,
	writable: boolean,
	storeError: string?,
	snaps: { [string]: Snap },
	snap: Snap?,
	cursor: string?,
	focus: string, -- the picker part the keys drive: "list" | "scopes"
	inflight: number?, -- generation of the search request that owns the spinner
	gen: number,
	repo: string?,
	account: string?, -- the gh login ("" = the active gh account) the data and requests belong to; nil: not read yet, or unreadable
	applied: string?, -- the query text the shown snapshot belongs to
	cost: number,
	interval: number?,
	nextAt: number?,
	resolving: boolean,
	problem: github.Problem?,
	timer: TimerHandle?,
	query: input.Model?, -- nil: the search is hidden
	help: boolean, -- the shortcut list is open
	vis: Visible?,
	details: { [string]: Detail }, -- all checks per PR (key: account, PR and update time)
	detailFail: { [string]: DetailFail },
	detailBusy: { [string]: boolean }, -- checks loads running
	detailAttempt: Attempt?,
	expanded: { [string]: boolean }, -- PR keys whose check list is unfolded
	notes: { [string]: Note }, -- worktree reports by PR key
	noteSeq: number,
	settings: Settings?,
}

local running: { [number]: State } = {}

-- ---------------------------------------------------------------- storage

-- `type(v) == "table"` without refining an untrusted `any`.
local function isTable(v: any): boolean
	return type(v) == "table"
end

local function seeds(): Store
	return {
		version = 1,
		nextId = 3,
		items = {
			{ id = "f1", name = "My PRs", query = "is:open author:@me" },
			{ id = "f2", name = "Review requested", query = "is:open review-requested:@me" },
		},
	}
end

local function validStore(v: any): Store?
	if not isTable(v) or v.version ~= 1 or type(v.nextId) ~= "number" or not isTable(v.items) then
		return nil
	end
	local items: { Filter } = {}
	for _, f in v.items do
		if not isTable(f) or type(f.id) ~= "string" or type(f.name) ~= "string" or type(f.query) ~= "string" then
			return nil
		end
		table.insert(items, { id = f.id, name = f.name, query = f.query })
	end
	return { version = 1, nextId = v.nextId, items = items }
end

-- tern.kv.set raises on failure and returns nothing: the error text, or nil when saved.
local function kvSet(key: string, value: any): string?
	local ok, err = pcall(function(): string?
		tern.kv.set(key, value)
		return nil
	end)
	if ok then
		return nil
	end
	return tostring(err)
end

local function writeStore(store: Store): string?
	local items: { any } = {}
	for _, f in store.items do
		table.insert(items, { id = f.id, name = f.name, query = f.query })
	end
	return kvSet("filters", { version = 1, nextId = store.nextId, items = tern.json.array(items) })
end

-- store, writable, error. An absent key is seeded; unreadable or malformed
-- storage is never overwritten: seeds are shown but Save is disabled.
local function loadStore(): (Store, boolean, string?)
	local ok, v = pcall(tern.kv.get, "filters")
	if not ok then
		return seeds(), false, "Saved filters could not be read: " .. tostring(v)
	end
	if v == nil then
		local s = seeds()
		local err = writeStore(s)
		if err then
			return s, false, "Saved filters could not be written: " .. err
		end
		return s, true, nil
	end
	local s = validStore(v)
	if not s then
		return seeds(), false, "Saved filters are malformed; not overwriting them."
	end
	return s, true, nil
end

local function readRepos(): { [string]: string }
	local ok, v = pcall(tern.kv.get, "repos")
	if ok and isTable(v) then
		return v
	end
	return {}
end

-- ---------------------------------------------------------------- lifecycle

-- Cancels the checks load waiting out its debounce or retry delay, if any.
local function cancelDetails(state: State)
	local waiting = state.detailAttempt
	if waiting then
		state.detailAttempt = nil
		if waiting.timer then
			waiting.timer:cancel()
		end
	end
end

-- Forgets every loaded or failed checks list. Loads still running are dropped when they land: they compare the account.
local function dropDetails(state: State)
	cancelDetails(state)
	state.details, state.detailFail = {}, {}
end

local function retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
	end
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	dropDetails(state)
	state.inflight = nil
	state.snap, state.vis = nil, nil
	state.snaps = {}
	state.problem = nil
	state.cursor = nil
end

local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	retire(state)
	return false
end

local function activeFilter(state: State): Filter?
	for _, f in state.store.items do
		if f.id == state.activeId then
			return f
		end
	end
	return nil
end

local function indexOf(prs: { github.Pr }, key: string?): number
	for i, pr in prs do
		if pr.key == key then
			return i
		end
	end
	return 0
end

local function selectedPr(state: State): github.Pr?
	local snap = state.snap
	if snap then
		return snap.prs[indexOf(snap.prs, state.cursor)]
	end
	return nil
end

-- Numbers of the launch repo's PRs whose Plotroom worktree holds some pane's cwd on this host.
local function openPrs(state: State): { [number]: boolean }
	local open: { [number]: boolean } = {}
	local repo = state.repo
	if repo then
		for _, p in tern.pane.list() do
			local n = if p.cwd then worktree.prOfPath(p.cwd, repo) else nil
			if n then
				open[n] = true
			end
		end
	end
	return open
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

-- Picker ids hold no `/` or `#`; search is scoped to one repo, so numbers are unique.
local function itemId(pr: github.Pr): string
	return "n" .. pr.number
end

local function prOfItem(state: State, id: string): github.Pr?
	local snap = state.snap
	if snap then
		for _, pr in snap.prs do
			if itemId(pr) == id then
				return pr
			end
		end
	end
	return nil
end

-- The PRs the local search lets through, in snapshot order, with their picker ids and title hits. Recomputed only when
-- the snapshot or the search text changes.
local function filtered(state: State): Visible?
	local snap = state.snap
	if not snap then
		return nil
	end
	local text = if state.query then state.query.text else ""
	local cached = state.vis
	if cached and cached.snap == snap and cached.needle == text then
		return cached
	end
	local prs: { github.Pr } = {}
	local order: { string } = {}
	local hits: { [string]: any } = {}
	local hasHits = false
	local blank = trim(text) == ""
	for _, pr in snap.prs do
		local ok = true
		local range: { number }? = nil
		if not blank then
			ok, range = github.match(pr, text)
		end
		if ok then
			table.insert(prs, pr)
			local id = itemId(pr)
			table.insert(order, id)
			if range then
				hits[id] = { range }
				hasHits = true
			end
		end
	end
	local out: Visible = { snap = snap, needle = text, prs = prs, order = tern.json.array(order), hits = if hasHits then hits else nil }
	state.vis = out
	return out
end

-- Keep the cursor on a visible result (the first when it vanished).
local function ensureCursor(state: State)
	local v = filtered(state)
	local prs: { github.Pr } = if v then v.prs else {}
	if indexOf(prs, state.cursor) == 0 then
		state.cursor = if prs[1] then prs[1].key else nil
	end
end

-- ---------------------------------------------------------------- identity

-- The gh login for github.wait/quota (nil: the active gh account).
local function login(state: State): string?
	local a = state.account
	return if a ~= nil and a ~= "" then a else nil
end

-- Cache key of a snapshot: repository, gh account and query. nil while the account is unknown or unreadable.
local function snapKey(state: State, query: string): string?
	local repo, account = state.repo, state.account
	if not repo or not account then
		return nil
	end
	return repo .. "\0" .. account .. "\0" .. query
end

-- Cache key of a PR's loaded checks; the account is part of it, so one identity never sees another's list.
local function detailKey(state: State, pr: github.Pr): string?
	local account = state.account
	if not account then
		return nil
	end
	return account .. "\0" .. pr.key .. "@" .. pr.updated
end

-- Drops everything shown, cached or running under the previous gh identity.
local function forget(state: State)
	state.gen += 1
	state.snaps, state.snap, state.vis, state.problem = {}, nil, nil, nil
	dropDetails(state)
end

-- Rereads the repository's saved gh account: `state.account` is the identity everything on screen and in flight belongs to. A
-- different one (or none) drops all data and problems of the old one; an unreadable one says why. False: no request may run.
local function identify(state: State): boolean
	local repo = state.repo
	if not repo then
		return false
	end
	local saved, why = github.account(repo)
	local now = if why then nil else (saved or "")
	local before = state.account
	if now ~= before then
		state.account = now
		if before ~= nil then
			forget(state)
		end
	end
	local p = state.problem
	if why then
		state.problem = { kind = "account", message = why.message }
	elseif p and p.kind == "account" then
		state.problem = nil
	end
	return now ~= nil
end

-- Shows the cached snapshot of the active filter (none while the account is unknown).
local function showSnapshot(state: State)
	identify(state)
	local f = activeFilter(state)
	state.applied = if f then f.query else nil
	local key = if f then snapKey(state, f.query) else nil
	state.snap = if key then state.snaps[key] else nil
	ensureCursor(state)
end

local refresh: (State) -> ()

-- Problems that retrying cannot fix by itself: no automatic refresh until an explicit Retry. "invalid" belongs to one
-- query, "account" to an unreadable saved account. ("not-found" is reserved for the GitHub layer's classifier.)
local TERMINAL: { [string]: boolean } = { auth = true, missing = true, ["not-found"] = true, invalid = true, account = true }

local HEADS: { [string]: string } = {
	missing = "GitHub CLI not found",
	auth = "GitHub CLI not signed in",
	["rate-limit"] = "GitHub rate limit",
	["not-found"] = "Repository not visible",
	invalid = "GitHub rejected the search",
	account = "GitHub account unavailable",
	["no-repo"] = "No GitHub repository",
	failed = "Could not load pull requests",
}
local HELP: { [string]: string } = {
	missing = "Install the GitHub CLI (cli.github.com) so it is on your shell's PATH, then Refresh.",
	auth = "Run gh auth login in a terminal, then Refresh.",
	["rate-limit"] = "Searches resume automatically when GitHub's limit resets.",
	["not-found"] = "Check this repository's account in Settings › GitHub, then Refresh.",
	invalid = "Check the filter query and this repository's account in Settings, then Refresh.",
	account = "Fix or clear this repository's account in Settings › GitHub, then Refresh (a damaged saved-accounts file needs a manual repair).",
	["no-repo"] = "Open Plotroom from a checkout of a GitHub repository.",
}

-- Panes of this runtime that still exist; they share one search quota.
local function openPanes(): number
	local open: { [number]: boolean } = {}
	for _, p in tern.pane.list() do
		open[p.pane] = true
	end
	local n = 0
	for pane in running do
		if open[pane] then
			n += 1
		end
	end
	return math.max(1, n)
end

-- Arms the next automatic refresh, never earlier than the server's cooldown allows.
local function schedule(state: State, ms: number)
	if state.timer then
		state.timer:cancel()
	end
	ms = math.max(ms, github.wait(os.time(), login(state)) * 1000)
	state.nextAt = os.time() + math.ceil(ms / 1000)
	state.timer = tern.timer(ms, function()
		if not alive(state) then
			return
		end
		state.timer = nil
		refresh(state)
		state.cx:render()
	end)
end

-- The repository of the launch directory, from local git only. Fails closed:
-- without one no search runs.
local function resolveRepo(state: State)
	if state.resolving then
		return
	end
	local cwd = state.launchCwd
	if not cwd then
		state.problem = { kind = "no-repo", message = "No launch directory, so there is no repository to show pull requests for." }
		return
	end
	state.resolving = true
	worktree.currentRepository(cwd, function(repo, why)
		if not alive(state) then
			return
		end
		state.resolving = false
		if repo then
			state.repo, state.problem = repo, nil
			showSnapshot(state)
			refresh(state)
		else
			state.problem = { kind = "no-repo", message = "No GitHub repository for " .. cwd .. ": " .. (why or "unknown") }
		end
		state.cx:render()
	end)
end

-- Checks, failures and folds of PRs that no cached snapshot lists any more (or lists with a newer update) cannot be shown again.
local function prune(state: State)
	local live: { [string]: boolean } = {}
	local keep: { [string]: boolean } = {}
	for _, snap in state.snaps do
		for _, pr in snap.prs do
			live[pr.key] = true
			local key = detailKey(state, pr)
			if key then
				keep[key] = true
			end
		end
	end
	for key in state.details do
		if not keep[key] then
			state.details[key] = nil
		end
	end
	for key in state.detailFail do
		if not keep[key] then
			state.detailFail[key] = nil
		end
	end
	for key in state.expanded do
		if not live[key] then
			state.expanded[key] = nil
		end
	end
end

refresh = function(state: State)
	if not alive(state) then
		return
	end
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	local repo = state.repo
	if not repo then
		-- A failed lookup stays failed until an explicit Retry: nothing else may respawn git.
		local p = state.problem
		if p and p.kind == "no-repo" then
			return
		end
		return resolveRepo(state)
	end
	if not identify(state) then
		return -- the saved account is unreadable: nothing may run as another identity
	end
	local halted = state.problem
	if halted and TERMINAL[halted.kind] then
		return
	end
	if state.inflight == state.gen then
		return -- the request for the current query is already running
	end
	local f = activeFilter(state)
	if not f then
		state.problem = nil
		return
	end
	-- The server's cooldown holds for every trigger, manual refresh included.
	local wait = github.wait(os.time(), login(state))
	if wait > 0 then
		-- Nothing is loading: say why, so an uncached filter does not show a spinner until the reset.
		state.problem = { kind = "rate-limit", message = "GitHub's rate limit is reached; searches resume at " .. os.date("%H:%M:%S", os.time() + wait) .. "." }
		return schedule(state, wait * 1000)
	end
	local gen, query = state.gen, f.query
	local key = snapKey(state, query)
	if not key then
		return
	end
	state.inflight = gen
	github.search(repo, query, function()
		return running[state.cx.pane] == state and state.gen == gen
	end, function(result, problem, spent)
		if not alive(state) then
			return
		end
		if state.inflight == gen then
			state.inflight = nil
		end
		if state.gen ~= gen or (problem and problem.kind == "superseded") then
			-- The query or the account changed meanwhile and its own request is running or paused: only the spent quota counts.
			if spent > 0 then
				state.cost = math.max(spent, state.cost)
			end
			state.cx:render()
			return
		end
		if problem and problem.kind == "account" then
			-- The saved account became unreadable under the request: nothing of the old identity may stay on screen.
			state.account = nil
			forget(state)
			state.problem = problem
			state.cx:render()
			return
		end
		if result then
			local snap: Snap = { prs = result.prs, total = result.total, complete = result.complete, fetched = os.time() }
			state.snaps[key] = snap
			state.snap = snap
			state.problem = nil
			ensureCursor(state)
			prune(state)
		else
			state.problem = problem
		end
		if spent > 0 then
			-- A finished snapshot shows the real points cost; a failed one keeps the larger known cost.
			state.cost = if result then spent else math.max(spent, state.cost)
			state.interval = github.interval(github.quota(login(state)), os.time(), state.cost, openPanes(), POLL_MS)
		else
			state.interval = nil -- nothing was sent (invalid query): no quota to pace
		end
		if not (problem and TERMINAL[problem.kind]) then
			schedule(state, state.interval or POLL_MS)
		end
		state.cx:render()
	end)
end

-- A different applied query or account: invalidate whatever is in flight and reload now. A rejected query (HTTP 422)
-- belonged to the old query; the other pauses are about the environment and stay.
local function changed(state: State)
	state.gen += 1
	local p = state.problem
	if state.repo and p and (p.kind == "invalid" or not TERMINAL[p.kind]) then
		state.problem = nil
	end
	showSnapshot(state)
	refresh(state)
end

-- Explicit user retry (`r`, Refresh, Retry): also looks for a repository again and retries failed checks loads.
local function retry(state: State)
	process.reset()
	local p = state.problem
	if p and (TERMINAL[p.kind] or (not state.repo and p.kind == "no-repo")) then
		state.problem = nil
	end
	state.detailFail = {}
	cancelDetails(state)
	if state.repo and state.inflight == state.gen then
		state.cx:toast("info", "Already refreshing", state.repo)
	end
	refresh(state)
end

local function switchFilter(state: State, id: string?)
	state.activeId = id
	identify(state)
	local f = activeFilter(state)
	local key = if f then snapKey(state, f.query) else nil
	local cached = if key then state.snaps[key] else nil
	local age = if cached then os.time() - cached.fetched else 0
	local fresh = math.floor((state.interval or POLL_MS) / 1000)
	local halted = state.problem
	local blocked = false
	if halted then
		blocked = TERMINAL[halted.kind] == true and halted.kind ~= "invalid"
	end
	if cached and state.inflight == nil and age < fresh and not blocked then
		-- A snapshot younger than the refresh interval: show it and keep polling on its schedule.
		state.problem = nil
		showSnapshot(state)
		schedule(state, (fresh - age) * 1000)
	else
		changed(state)
	end
end

-- Whether what the block shows no longer fits the active filter's query or the repository's saved account (changed by
-- another block). The block remembers what it applied: reading the account again after the write would see the new one both times.
local function stale(state: State, f: Filter): boolean
	if f.query ~= state.applied then
		return true
	end
	local repo = state.repo
	if not repo then
		return false
	end
	local saved, why = github.account(repo)
	local now = if why then nil else (saved or "")
	return now ~= state.account
end

-- After another block wrote the filters or the repository's account, or on restore: reread storage; what is shown must match it.
local function reloadStore(state: State)
	local store, writable, err = loadStore()
	state.store, state.writable, state.storeError = store, writable, err
	local f = activeFilter(state)
	if not f then
		switchFilter(state, if store.items[1] then store.items[1].id else nil)
	elseif stale(state, f) then
		changed(state)
	end
end

-- Every other live block of this runtime follows a change made in `origin`. Closed panes are retired, not rendered.
local function propagate(origin: State)
	for _, s in running do
		if s ~= origin and alive(s) then
			reloadStore(s)
			s.cx:render()
		end
	end
end

-- ---------------------------------------------------------------- navigation

-- Moves the cursor `delta` rows through the visible PRs, clamped to the list.
local function moveCursor(state: State, delta: number)
	local v = filtered(state)
	if not v or #v.prs == 0 then
		return
	end
	local i = indexOf(v.prs, state.cursor)
	state.cursor = v.prs[math.clamp(i + delta, 1, #v.prs)].key
end

local function moveFilter(state: State, delta: number)
	local items = state.store.items
	local at = 0
	for i, f in items do
		if f.id == state.activeId then
			at = i
		end
	end
	local target = items[math.clamp(at + delta, 1, math.max(1, #items))]
	if target and target.id ~= state.activeId then
		switchFilter(state, target.id)
	end
end

-- ---------------------------------------------------------------- view

-- A span list for a node prop; spans and plain strings may mix.
local function spans(...: Span | string): { Span | string }
	return { ... }
end

local function prHref(kind: string, pr: github.Pr): string
	return "plotroom://github/" .. kind .. "/" .. pr.repo .. "/" .. pr.number
end

-- "45s", "3m 20s", "1h 5m" for a whole number of seconds.
local function duration(s: number): string
	s = math.max(0, math.ceil(s))
	if s < 60 then
		return s .. "s"
	elseif s < 3600 then
		return (s // 60) .. "m" .. (if s % 60 > 0 then " " .. s % 60 .. "s" else "")
	end
	return (s // 3600) .. "h" .. (if s % 3600 >= 60 then " " .. (s % 3600) // 60 .. "m" else "")
end

-- `s` with control characters as spaces and, when it is not valid UTF-8, every non-ASCII byte as "?".
local function printable(s: string): string
	local out = string.gsub(s, "%c", " ")
	if utf8.len(out) == nil then
		out = string.gsub(out, "[\128-\255]", "?")
	end
	return out
end

-- `s` (valid UTF-8, see printable) cut to `max` characters.
local function clip(s: string, max: number): string
	local cut = utf8.offset(s, max + 1)
	return if cut and cut <= #s then string.sub(s, 1, cut - 1) .. "…" else s
end

-- The first line of `s`, cut to 160 characters.
local function brief(s: string): string
	return clip(printable(string.match(s, "[^\n]*") or ""), 160)
end

-- The adaptive refresh pace: cooldown while the server holds us back, else the
-- interval and quota behind the next automatic refresh. Nothing without a repo
-- or when no request was sent (invalid query).
local function paceLine(state: State): string?
	if not state.repo then
		local p = state.problem
		if p and p.kind == "no-repo" then
			return "Auto-refresh unavailable: no GitHub repository. Refresh to look again."
		end
		return nil
	end
	local halted = state.problem
	if halted and TERMINAL[halted.kind] then
		return "Auto-refresh paused: " .. (HEADS[halted.kind] or halted.kind) .. ". Fix it, then Refresh."
	end
	local now = os.time()
	local who = login(state)
	local q = github.quota(who)
	local wait = github.wait(now, who)
	local line: string
	if wait > 0 then
		line = "Paused by GitHub rate limit until " .. os.date("%H:%M:%S", now + wait)
	elseif state.interval and state.nextAt and state.timer then
		line = "Auto-refresh: every " .. duration(state.interval / 1000) .. ", next " .. os.date("%H:%M:%S", state.nextAt)
	else
		return nil
	end
	if q and q.remaining and q.limit and q.reset and q.reset > now then
		line ..= " · GraphQL quota " .. q.remaining .. "/" .. q.limit .. ", resets " .. os.date("%H:%M:%S", q.reset)
	end
	return line
end

-- ---------------------------------------------------------------- settings and queue views

local QUEUE_ID = "layer.queue"
local SETTINGS_ID = "main.settings"
local PAGES = { "filters", "github", "worktrees" }
local PAGE_DEFS = {
	{ id = "filters", label = "Filters", group = "Queue", icon = "funnel" },
	{ id = "github", label = "GitHub", group = "Connection", icon = "globe" },
	{ id = "worktrees", label = "Worktrees", group = "Connection", icon = "tree" },
}
local NO_REPO = "No GitHub repository for the launch directory."

local STATE_BADGE: { [string]: { text: string, tone: string } } = {
	open = { text = "Open", tone = "success" },
	draft = { text = "Draft", tone = "muted" },
	merged = { text = "Merged", tone = "accent" },
	closed = { text = "Closed", tone = "error" },
}
local REVIEW_BADGE: { [string]: { text: string, tone: string } } = {
	approved = { text = "Approved", tone = "success" },
	changes = { text = "Changes requested", tone = "error" },
	required = { text = "Review required", tone = "warning" },
}
local RUN_TONE: { [string]: string } = { success = "success", failure = "error", pending = "warning", neutral = "muted" }
local CHECK: { [string]: { text: string, tone: string, dot: string } } = {
	success = { text = "Passing", tone = "success", dot = "success" },
	failure = { text = "Failing", tone = "error", dot = "error" },
	pending = { text = "Pending", tone = "warning", dot = "pending" },
}

type KeyHelp = { keys: { string }, text: string }

-- The `?` lists: every shortcut of the mode, concise.
local QUEUE_KEYS: { KeyHelp } = {
	{ keys = { "↑", "↓" }, text = "Move through the pull requests (j and k too; Page Up/Down jump ten, Home/End the ends)" },
	{ keys = { "Enter" }, text = "Open the selected pull request in a Browser block beside this one" },
	{ keys = { "w" }, text = "Check it out in a worktree and open that in a new tab" },
	{ keys = { "g" }, text = "Go to the tab working in the selected pull request's worktree" },
	{ keys = { "a" }, text = "Run an omp prompt template or skill on the selected pull request, picked from a list" },
	{ keys = { "/" }, text = "Search the loaded pull requests; Esc clears the search, a second Esc closes it" },
	{ keys = { "Tab" }, text = "Switch between the filter list and the pull requests" },
	{ keys = { "r" }, text = "Refresh now" },
	{ keys = { "s" }, text = "Settings" },
	{ keys = { "?" }, text = "Show or hide this list" },
}
local SETTINGS_KEYS: { KeyHelp } = {
	{ keys = { "↑", "↓" }, text = "Move between rows" },
	{ keys = { "Enter" }, text = "Edit a text row or press its button; while editing, Enter saves" },
	{ keys = { "Esc" }, text = "Cancel the edit without saving; with nothing being edited, close Settings" },
	{ keys = { "Tab" }, text = "Next page (Shift+Tab: previous page)" },
	{ keys = { "?" }, text = "Show or hide this list" },
}

local function stateKind(pr: github.Pr): string
	if pr.state == "merged" or pr.state == "closed" then
		return pr.state
	end
	return if pr.draft then "draft" else "open"
end

-- Hidden node that carries the launch directory for window.luau (`main.context`).
local function contextNode(state: State): Node
	return ui.node("text", { key = "context", text = state.launchCwd or "", hidden = true })
end

type Row = {
	id: string,
	label: string,
	hint: string?,
	control: { [string]: any },
	changed: boolean?,
	defaultLabel: string?,
	warning: string?,
	disabled: string?,
}

local TEMPLATE_NAME = "^[%w][%w%-_]*$"
local TEMPLATE_SKELETON = "---\ndescription: \nargument-hint: <pull request URL>\n---\n\nReview $ARGUMENTS and list the risks.\n"

-- omp's user prompt template directory, nil without HOME.
local function promptDir(): string?
	local home = tern.getenv("HOME")
	return if home and home ~= "" then home .. "/.omp/agent/prompts" else nil
end

-- sections, lead and extra children of the open settings page.
local function pageContent(state: State): ({ any }, string, { Node })
	local s = state.settings :: Settings
	local where = state.repo or "the launch repository"
	local sections: { any } = {}
	local extra: { Node } = {}
	local lead = ""
	if s.page == "filters" then
		lead = "Saved GitHub searches, listed in the queue's filter column. Each runs inside "
			.. where
			.. ", so repo:, org:, user: and OR are not allowed."
		local locked = if state.writable then nil else (state.storeError or "Saved filters are read-only.")
		for _, f in state.store.items do
			local active = f.id == state.activeId
			local rows: { Row } = {
				{ id = "name:" .. f.id, label = "Name", disabled = locked, control = { k = "text", value = f.name, placeholder = "My PRs" } },
				{
					id = "query:" .. f.id,
					label = "Query",
					hint = "GitHub search syntax, run inside " .. where .. ".",
					disabled = locked,
					control = { k = "text", value = f.query, placeholder = "is:open author:@me", mono = true },
				},
			}
			table.insert(rows, { id = "delete:" .. f.id, label = "Delete filter", disabled = locked, control = { k = "action", act = "delete", label = "Delete" } })
			table.insert(sections, {
				id = "filter:" .. f.id,
				title = f.name .. (if active then " · showing" else ""),
				rows = rows,
			})
		end
		table.insert(sections, {
			id = "new",
			rows = {
				{
					id = "add",
					label = "New filter",
					hint = "Adds a filter for open pull requests; name it and edit its query.",
					disabled = locked,
					control = { k = "action", act = "add", label = "Add filter" },
				},
			},
		})
		local dir = promptDir()
		table.insert(sections, {
			id = "templates",
			title = "Prompt templates",
			rows = {
				{
					id = "newtpl",
					label = "Create or edit a prompt template",
					hint = "Type its name: Plotroom creates " .. (dir or "~/.omp/agent/prompts") .. "/<name>.md if needed and opens it in $EDITOR.",
					disabled = if dir then nil else "HOME is not set.",
					control = { k = "text", value = "", placeholder = "review-pr", mono = true },
				},
			},
		})
	elseif s.page == "github" then
		lead = "Plotroom reads pull requests through GitHub's GraphQL API with your gh login."
		local account: string? = nil
		local unreadable: github.Problem? = nil
		if state.repo then
			account, unreadable = github.account(state.repo)
		end
		local now = os.time()
		local who = login(state)
		local wait = if state.account then github.wait(now, who) else 0
		table.insert(sections, {
			id = "sec-account",
			title = "Account",
			rows = {
				{
					id = "account",
					label = "gh account",
					hint = "Login used for " .. where .. ". Empty: the active gh account.",
					control = {
						k = "text",
						value = account or "",
						placeholder = if unreadable then "Saved account unreadable" else "Active gh account",
					},
					changed = account ~= nil,
					defaultLabel = "Active gh account",
					warning = if unreadable then unreadable.message else nil,
					disabled = if state.repo then nil else NO_REPO,
				},
			},
		})
		table.insert(sections, {
			id = "sec-refresh",
			title = "Refresh",
			rows = {
				{
					id = "refresh",
					label = "Refresh now",
					hint = paceLine(state) or "Refreshes every minute while quota allows.",
					control = { k = "action", act = "refresh", label = "Refresh" },
					disabled = if wait > 0 then "Paused by GitHub until " .. os.date("%H:%M:%S", now + wait) elseif state.repo then nil else NO_REPO,
				},
			},
		})
		local q = github.quota(who)
		if q and q.limit and q.limit > 0 and q.remaining then
			local kids: { Node } = {
				ui.node("meter", {
					key = "used",
					value = 1 - q.remaining / q.limit,
					thresholds = { warn = 0.8, bad = 0.95 },
					label = { ui.span(q.remaining .. " of " .. q.limit .. " points left", "num") },
					total = if q.reset then "resets " .. os.date("%H:%M", q.reset) else nil,
				}),
			}
			local nextAt = state.nextAt
			if state.timer and nextAt and nextAt > now then
				table.insert(
					kids,
					ui.node("row", { key = "next" }, {
						ui.text({ ui.span("Next refresh in", "muted") }),
						ui.node("elapsed", { age = (now - nextAt) * 1000, format = "clock" }),
					})
				)
			end
			table.insert(extra, ui.node("card", { key = "quota", head = { ui.span("GitHub API quota", "strong") } }, kids))
		end
	else
		lead = "Worktree checks a pull request out in <checkout>.plotroom/<owner>/<repo>/pr-N on branch plotroom/<owner>/<repo>/pr-N and opens it in a new tab."
		local mapped = if state.repo then readRepos()["github.com/" .. string.lower(state.repo)] else nil
		table.insert(sections, {
			id = "sec-checkout",
			title = "Local checkout",
			rows = {
				{
					id = "checkout",
					label = if state.repo then "Checkout of " .. state.repo else "Local checkout",
					hint = "Used when the launch directory (" .. (state.launchCwd or "none") .. ") is not a checkout of " .. where .. ".",
					control = {
						k = "text",
						value = if type(mapped) == "string" then mapped else "",
						placeholder = state.launchCwd or "~/Code/repo",
						mono = true,
					},
					changed = type(mapped) == "string",
					defaultLabel = "Launch directory",
					disabled = if s.busy then "Checking the checkout…" elseif state.repo then nil else NO_REPO,
				},
			},
		})
	end
	for _, sec in sections do
		for _, row in sec.rows do
			local err = s.errors[row.id]
			if err then
				row.warning = err
			end
		end
	end
	return sections, lead, extra
end

-- Ids of the page's rows the keys can reach, in order.
local function focusRows(state: State): { string }
	local out: { string } = {}
	local sections = pageContent(state)
	for _, sec in sections do
		for _, row in sec.rows do
			if not row.disabled then
				table.insert(out, row.id)
			end
		end
	end
	return out
end

local function rowById(state: State, id: string): Row?
	local sections = pageContent(state)
	for _, sec in sections do
		for _, row in sec.rows do
			if row.id == id then
				return row
			end
		end
	end
	return nil
end

local function beginEdit(state: State, row: string, initial: string?)
	local s = state.settings
	local def = if s then rowById(state, row) else nil
	if not s or not def or def.disabled or def.control.k ~= "text" then
		return
	end
	s.focus = row
	s.errors[row] = nil
	s.edit = { row = row, model = input.new(initial or def.control.value) }
end

-- Ends a save attempt: `err` is shown under the row and the edit stays open for a correction; on success the
-- row's warning is cleared and the edit closes.
local function settle(s: Settings, row: string, err: string?)
	if err then
		s.errors[row] = err
	else
		s.errors[row] = nil
		s.edit = nil
	end
end

-- Saves (nil clears) the local checkout of the launch repo. Fails closed when the saved map cannot be read.
local function setCheckout(state: State, root: string?): string?
	local repo = state.repo
	if not repo then
		return NO_REPO
	end
	local ok, stored = pcall(tern.kv.get, "repos")
	if not ok or (stored ~= nil and not isTable(stored)) then
		return "Saved checkouts could not be read"
	end
	local repos: { [string]: string } = if stored ~= nil then stored else {}
	local key = "github.com/" .. string.lower(repo)
	if root then
		repos[key] = root
	else
		repos[key] = nil
	end
	local err = kvSet("repos", repos)
	if err then
		return "Could not save: " .. err
	end
	return nil
end

local function clearCheckout(state: State): string?
	local err = setCheckout(state, nil)
	if not err then
		state.cx:toast("success", "Checkout cleared", state.repo or "")
	end
	return err
end

-- New account: everything cached or running under the old one is dropped, here and in every other block (they compare
-- the account they applied with the saved one), and each block refreshes once as an intentional retry.
local function accountChanged(state: State)
	forget(state)
	state.cx:toast("success", "GitHub account saved", "Refreshing " .. (state.repo or ""))
	retry(state)
	propagate(state)
end

-- Rereads the store, applies `fn` to filter `id` and writes it back; an error message or nil.
local function updateFilter(state: State, id: string, fn: (Filter) -> ()): string?
	local store, writable, err = loadStore()
	if not writable then
		state.store, state.writable, state.storeError = store, false, err
		return err or "Filters cannot be saved."
	end
	local target: Filter? = nil
	for _, f in store.items do
		if f.id == id then
			target = f
		end
	end
	if not target then
		return "That filter was deleted elsewhere."
	end
	local before = target.query
	fn(target)
	local werr = writeStore(store)
	if werr then
		return "Could not save: " .. werr
	end
	state.store, state.writable, state.storeError = store, true, nil
	if id == state.activeId and target.query ~= before then
		changed(state)
	end
	propagate(state)
	return nil
end

local function addFilter(state: State)
	local s = state.settings
	if not s then
		return
	end
	local store, writable, err = loadStore()
	if not writable then
		state.store, state.writable, state.storeError = store, false, err
		s.errors.add = err or "Filters cannot be saved."
		return
	end
	local id = "f" .. store.nextId
	store.nextId += 1
	table.insert(store.items, { id = id, name = "New filter", query = "is:open" })
	local werr = writeStore(store)
	if werr then
		s.errors.add = "Could not save: " .. werr
		return
	end
	s.errors.add = nil
	state.store, state.writable, state.storeError = store, true, nil
	switchFilter(state, id)
	propagate(state)
	beginEdit(state, "name:" .. id, "")
end

local function deleteFilter(state: State, id: string)
	local s = state.settings
	if not s then
		return
	end
	s.confirm = nil
	local rowId = "delete:" .. id
	local store, writable, err = loadStore()
	if not writable then
		state.store, state.writable, state.storeError = store, false, err
		s.errors[rowId] = err or "Filters cannot be saved."
		return
	end
	local at = 0
	for i, f in store.items do
		if f.id == id then
			at = i
		end
	end
	if at == 0 then
		return
	end
	table.remove(store.items, at)
	local werr = writeStore(store)
	if werr then
		s.errors[rowId] = "Could not delete: " .. werr
		return
	end
	s.errors[rowId] = nil
	state.store, state.writable, state.storeError = store, true, nil
	if id == state.activeId then
		local nextF = store.items[math.min(at, #store.items)]
		switchFilter(state, if nextF then nextF.id else nil)
	end
	s.focus = "add"
	propagate(state)
end

-- Deletes the filter whose delete row `s.confirm` names ("delete:<id>").
local function confirmDelete(state: State)
	local s = state.settings
	local id = string.match(if s and s.confirm then s.confirm else "", "^delete:(.+)$")
	if id then
		deleteFilter(state, id)
	end
end

local function runAction(state: State, act: string, row: string)
	local s = state.settings
	if not s then
		return
	end
	if act == "add" then
		addFilter(state)
	elseif act == "delete" then
		s.confirm = row
	elseif act == "refresh" then
		retry(state)
	end
end

local function runRow(state: State, row: string?)
	if not row then
		return
	end
	local def = rowById(state, row)
	if not def or def.disabled then
		return
	end
	if def.control.k == "text" then
		beginEdit(state, row)
	elseif def.control.k == "action" then
		runAction(state, def.control.act, row)
	end
end

-- Enter on a text row: saves it. A rejected value stays in the field with its warning, for a correction.
local function commitEdit(state: State)
	local s = state.settings
	local e = if s then s.edit else nil
	if not s or not e then
		return
	end
	local text = trim(e.model.text)
	local row = e.row
	local def = rowById(state, row)
	if not def or text == def.control.value then
		settle(s, row, nil) -- nothing to save: the edit closes, and a warning about the rejected draft goes with it
		return
	end
	local kind, id = string.match(row, "^(%a+):(.+)$")
	if (kind == "name" or kind == "query") and id then
		local err: string? = nil
		if text == "" then
			err = if kind == "name" then "A name is required." else "A query is required."
		elseif kind == "query" then
			err = github.scopeProblem(text)
		end
		if not err then
			err = updateFilter(state, id, function(f: Filter)
				if kind == "name" then
					f.name = text
				else
					f.query = text
				end
			end)
		end
		settle(s, row, err)
	elseif row == "newtpl" then
		local name = string.gsub(text, "%.md$", "")
		local dir = promptDir()
		local err: string? = nil
		if not string.match(name, TEMPLATE_NAME) or #name > 64 then
			err = "Use letters, digits, - and _ (at most 64), starting with a letter or digit."
		elseif not dir then
			err = "HOME is not set."
		else
			local path = dir .. "/" .. name .. ".md"
			local ok, why = pcall(function()
				if not tern.fs.exists(path) then
					tern.fs.mkdir(dir)
					tern.fs.write(path, TEMPLATE_SKELETON)
				end
			end)
			if ok then
				state.cx:open("plotroom://github/edit-template/" .. name) -- the window opens it in $EDITOR
			else
				err = "Could not create " .. path .. ": " .. tostring(why)
			end
		end
		settle(s, row, err)
	elseif row == "account" then
		local repo = state.repo
		if not repo then
			s.errors.account = NO_REPO
			return
		end
		local err = github.setAccount(repo, text)
		settle(s, row, err)
		if not err then
			accountChanged(state)
		end
	elseif row == "checkout" then
		if text == "" then
			settle(s, row, clearCheckout(state))
			return
		end
		local repo = state.repo
		if not repo then
			s.errors.checkout = NO_REPO
			return
		end
		local path, why = worktree.expandPath(text, tern.getenv("HOME"))
		if not path then
			s.errors.checkout = why or "That is not a usable path."
			return
		end
		s.busy, s.edit = true, nil
		worktree.resolveRepository(path, repo, function(info, problem)
			if not alive(state) then
				return
			end
			s.busy = false
			local root = if info then info.root else nil
			local err = if root then setCheckout(state, root) else (problem or "That path is not a checkout of " .. repo .. ".")
			if not err then
				s.errors.checkout = nil
				state.cx:toast("success", "Checkout saved", root)
			elseif state.settings == s then
				beginEdit(state, "checkout", text) -- the draft stays for a correction; this clears the row's warning, so set it after
				s.errors.checkout = err
			else
				state.cx:toast("error", "Checkout not saved", err)
			end
			state.cx:render()
		end)
	end
end

-- Escape (or clicking away) leaves a text row without saving; the row's warning belonged to the rejected value.
local function discardEdit(state: State)
	local s = state.settings
	local e = if s then s.edit else nil
	if s and e then
		s.edit = nil
		s.errors[e.row] = nil
	end
end

local function resetRow(state: State, row: string)
	local s = state.settings
	if not s then
		return
	end
	local repo = state.repo
	local err: string? = nil
	if row == "account" and repo then
		err = github.setAccount(repo, nil)
		if not err then
			accountChanged(state)
		end
	elseif row == "checkout" then
		err = clearCheckout(state)
	end
	s.errors[row] = err
	if not err and s.edit and s.edit.row == row then
		s.edit = nil
	end
end

local function openSettings(state: State, page: string, row: string?, edit: boolean?)
	state.settings = { page = page, focus = row, errors = {}, busy = false }
	if edit and row then
		beginEdit(state, row)
	end
end

local function openSelected(state: State, kind: string, rerender: boolean)
	local pr = selectedPr(state)
	if pr then
		if rerender then
			state.cx:render() -- sends the new preview before the open request
		end
		state.cx:open(prHref(kind, pr))
	end
end

-- How a worktree report stands: success only for a current, clean worktree; anything else deserves a look.
local function noteTone(note: Note): string
	if not note.ok then
		return "error"
	end
	return if note.current and note.dirty == false then "success" else "warning"
end

local function pickerItem(pr: github.Pr, note: Note?, open: boolean): { [string]: any }
	local check = if pr.checks then CHECK[pr.checks] else nil
	local kind = stateKind(pr)
	local badges: { any } = {}
	if open then
		table.insert(badges, { text = "In tab", tone = "accent", title = "A tab works in this pull request's worktree (g goes there)" })
	end
	if note and note.ok then
		table.insert(badges, {
			text = "Worktree",
			tone = noteTone(note),
			title = (note.summary or "Worktree ready") .. (if note.path then " · " .. note.path else ""),
		})
	end
	if kind ~= "open" then
		table.insert(badges, STATE_BADGE[kind])
	end
	local review = if pr.review then REVIEW_BADGE[pr.review] else nil
	if review then
		table.insert(badges, review)
	end
	for _, l in pr.labels do
		table.insert(badges, { text = l })
	end
	return {
		id = itemId(pr),
		label = pr.title,
		title = pr.title,
		-- The check state is spelled out: the corner dot alone is color.
		detail = "#" .. pr.number .. " · " .. pr.author .. (if check then " · " .. check.text else "") .. " · " .. pr.head,
		mark = { text = pr.author, seed = pr.author },
		dot = if check then check.dot else nil,
		badges = if #badges > 0 then badges else nil,
		facts = {
			changes = spans(ui.span("+" .. pr.additions, "ins"), " ", ui.span("−" .. pr.deletions, "error")),
			updated = github.age(pr.updated),
		},
	}
end

-- The picker rows of a snapshot, built once: again only when a worktree report arrives, the minute changes (the
-- ages) or the set of PRs open in a tab changes.
local function rowsOf(state: State, snap: Snap, open: { [number]: boolean }): { any }
	local minute = os.time() // 60
	local nums: { number } = {}
	for n in open do
		table.insert(nums, n)
	end
	table.sort(nums)
	local openKey = table.concat(nums, ",")
	local cached = snap.rows
	if cached and snap.rowsRev == state.noteSeq and snap.rowsMin == minute and snap.rowsOpen == openKey then
		return cached
	end
	local rows: { any } = {}
	for _, pr in snap.prs do
		table.insert(rows, pickerItem(pr, state.notes[pr.key], open[pr.number] == true))
	end
	tern.json.array(rows)
	snap.rows, snap.rowsRev, snap.rowsMin, snap.rowsOpen = rows, state.noteSeq, minute, openKey
	return rows
end

local CHECK_LIMIT = 8

-- Percent-encodes everything but unreserved URL characters.
local function pct(s: string): string
	return (string.gsub(s, "[^%w%-_%.~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

-- Link to a check's page: its row index (the window reads the live row to validate) and the percent-encoded URL.
local function checkHref(i: number, url: string): string
	return "plotroom://github/check/" .. i .. "/" .. pct(url)
end

local loadDetails: (State, string) -> ()

-- Loads the checks of `key` after `ms`. One attempt waits at a time; a new one replaces it.
local function armDetails(state: State, key: string, ms: number)
	cancelDetails(state)
	local attempt: Attempt = { key = key, timer = nil }
	state.detailAttempt = attempt
	attempt.timer = tern.timer(ms, function()
		if state.detailAttempt ~= attempt then
			return -- replaced or cancelled: the slot belongs to someone else now
		end
		state.detailAttempt = nil
		if alive(state) then
			loadDetails(state, key)
		end
	end)
end

-- Remembers why the checks of `key` could not be loaded (the preview says so) and when to try again: a rate limit
-- waits for its reset, other failures back off, and problems retrying cannot fix (sign-in, access, gh missing) wait
-- for an explicit Retry.
local function failDetails(state: State, key: string, problem: github.Problem)
	local prev = state.detailFail[key]
	local tries = if prev then prev.tries + 1 else 1
	local now = os.time()
	local retryAt: number? = nil
	if problem.kind == "rate-limit" then
		retryAt = now + math.max(github.wait(now, login(state)), DETAIL_RETRY_S)
	elseif not TERMINAL[problem.kind] then
		retryAt = now + math.min(DETAIL_RETRY_S * 2 ^ (tries - 1), DETAIL_RETRY_MAX_S)
	end
	state.detailFail[key] = { problem = problem, tries = tries, retryAt = retryAt }
end

loadDetails = function(state: State, key: string)
	local pr = selectedPr(state)
	if not pr or detailKey(state, pr) ~= key or state.details[key] or state.detailBusy[key] then
		return -- the cursor moved on, or it is loaded or loading already: a render asks again if it still matters
	end
	local account = state.account
	state.detailBusy[key] = true
	-- github.checks sends nothing while the quota is spent or the saved login unusable: it answers with that problem, which failDetails paces.
	github.checks(pr.repo, pr.number, function(runs, total, problem)
		state.detailBusy[key] = nil
		if not alive(state) then
			return
		end
		if state.account ~= account or (problem and problem.kind == "superseded") then
			state.cx:render() -- another identity owns the preview now: its own render asks for its own checks
			return
		end
		if runs then
			state.details[key] = { runs = runs, total = total }
			state.detailFail[key] = nil
		else
			failDetails(state, key, problem or { kind = "failed", message = "The checks could not be read." })
		end
		state.cx:render()
	end, function()
		return running[state.cx.pane] == state and state.account == account
	end)
end

-- Once the cursor rests on a PR with checks, loads all of them with their required flags (the search carries the first
-- 25, unflagged, and shows them meanwhile). Idempotent: every render calls it. A load waits out a debounce and a failed
-- one its retry delay; moving to another PR cancels the wait.
local function wantDetails(state: State, pr: github.Pr)
	local key = detailKey(state, pr)
	local waiting = state.detailAttempt
	if waiting and waiting.key ~= key then
		cancelDetails(state)
		waiting = nil
	end
	if not key or waiting or state.details[key] or state.detailBusy[key] then
		return
	end
	local fail = state.detailFail[key]
	if not fail then
		armDetails(state, key, DETAIL_DEBOUNCE_MS)
	elseif fail.retryAt then
		armDetails(state, key, math.max(0, fail.retryAt - os.time()) * 1000)
	end
end

-- A worktree attempt reported by the window (act "worktree-status", value: JSON). Untrusted: every field is checked and bounded.
local function oneLine(v: any, max: number): string?
	if type(v) == "string" and #v <= max and string.find(v, "%c") == nil and utf8.len(v) ~= nil then
		return v
	end
	return nil
end

-- At most six one-line strings.
local function commandList(v: any): { string }
	local out: { string } = {}
	if isTable(v) then
		for _, item in v do
			local line = oneLine(item, 2000)
			if line and line ~= "" and #out < 6 then
				table.insert(out, line)
			end
		end
	end
	return out
end

local function noteWorktree(state: State, raw: any)
	if type(raw) ~= "string" or #raw > 16384 then
		return
	end
	local ok, data = pcall(tern.json.decode, raw)
	if not ok or not isTable(data) then
		return
	end
	local repo, number = data.repo, data.number
	if type(repo) ~= "string" or type(number) ~= "number" or number < 1 or number ~= math.floor(number) then
		return
	end
	local message: string? = nil
	if type(data.message) == "string" then
		message = clip(printable(data.message), 1500)
	end
	local note: Note = {
		seq = state.noteSeq + 1,
		at = os.time(),
		ok = data.ok == true,
		created = data.created == true,
		current = data.current == true,
		dirty = if type(data.dirty) == "boolean" then data.dirty else nil,
		path = oneLine(data.path, 4096),
		branch = oneLine(data.branch, 512),
		summary = oneLine(data.summary, 600),
		message = message,
		update = commandList(data.update),
		cleanup = commandList(data.cleanup),
	}
	state.notes[string.lower(repo) .. "#" .. number] = note
	state.noteSeq = note.seq
	local count, oldest = 0, nil :: string?
	local oldestSeq = math.huge
	for key, n in state.notes do
		count += 1
		if n.seq < oldestSeq then
			oldest, oldestSeq = key, n.seq
		end
	end
	if count > NOTE_CAP and oldest then
		state.notes[oldest] = nil
	end
end

-- Copies the selected PR's update or cleanup commands. They are only shown and copied, never run.
local function copyCommands(state: State, which: any)
	local pr = selectedPr(state)
	local note = if pr then state.notes[pr.key] else nil
	local list: { string }? = nil
	if note and which == "update" then
		list = note.update
	elseif note and which == "cleanup" then
		list = note.cleanup
	end
	if list and #list > 0 then
		state.cx:copy(table.concat(list, "\n"))
		state.cx:toast("success", "Copied the " .. tostring(which) .. " commands", "Run them yourself; Plotroom never does")
	end
end

-- The worktree report of a PR: persistent, with what the window found and the commands the user may run.
local function worktreeNodes(state: State, pr: github.Pr): { Node }
	local note = state.notes[pr.key]
	if not note then
		return {}
	end
	local tone = noteTone(note)
	local body: { Node } = {}
	if note.ok then
		local text = note.summary or (if note.created then "Created" else "Reused")
		table.insert(body, ui.node("text", { key = "summary", spans = { ui.span(text) } }))
		local facts: { { [string]: any } } = {}
		if note.path then
			table.insert(facts, { k = "Path", v = note.path })
		end
		if note.branch then
			table.insert(facts, { k = "Branch", v = note.branch })
		end
		table.insert(body, ui.node("kv", { key = "facts", items = facts }))
		local function commands(id: string, title: string, list: { string })
			if #list == 0 then
				return
			end
			local kids: { Node } = {}
			for i, line in list do
				table.insert(kids, ui.el("div", { key = "c" .. i, class = "plotroom-cmd", text = line }))
			end
			table.insert(
				kids,
				ui.el("button", {
					key = "copy",
					class = "plotroom-btn",
					text = "Copy",
					aria = "Copy the " .. id .. " commands",
					actions = { click = "copy-wt=" .. id },
				})
			)
			table.insert(body, ui.node("section", { key = id, head = { ui.span(title, "muted") }, collapsible = true, collapsed = true }, kids))
		end
		commands("update", "Take the pull request's newer commits", note.update)
		commands("cleanup", "Remove this worktree when you are done", note.cleanup)
		table.insert(body, ui.node("text", { key = "never", spans = { ui.span("Plotroom never updates or removes a worktree; run these yourself.", "muted") } }))
	else
		table.insert(body, ui.node("text", { key = "message", spans = { ui.span(note.message or "The worktree could not be prepared.", "error") } }))
	end
	local head = spans(ui.span("Worktree", "strong"), ui.span("  checked " .. os.date("%H:%M", note.at), "muted"))
	return { ui.node("card", { key = "worktree", tone = tone, head = head }, body) }
end

-- The checks of the selected PR: all of them once loaded (the search's first ones meanwhile), with the load's state:
-- pending, or an error with its retry time and a Retry button.
local function checksNodes(state: State, pr: github.Pr): { Node }
	local out: { Node } = {}
	local key = detailKey(state, pr)
	local d = if key then state.details[key] else nil
	local fail = if key then state.detailFail[key] else nil
	local runs: { github.Run } = if d then d.runs else pr.runs
	local total = if d then d.total else pr.runTotal
	local loading = pr.checks ~= nil and key ~= nil and d == nil and fail == nil
	if #runs == 0 and not loading and not fail then
		return out
	end
	local tally: { [string]: number } = {}
	local required = 0
	for _, r in runs do
		tally[r.status] = (tally[r.status] or 0) + 1
		if r.required then
			required += 1
		end
	end
	local parts: { string } = {}
	for _, p in { { "failure", "failing" }, { "pending", "pending" }, { "success", "passed" }, { "neutral", "skipped" } } do
		if tally[p[1]] then
			table.insert(parts, tally[p[1]] .. " " .. p[2])
		end
	end
	table.insert(
		out,
		ui.node("text", {
			key = "runs-head",
			spans = { ui.span("Checks", "strong"), ui.span("  " .. table.concat(parts, " · "), "muted") },
		})
	)
	if loading then
		table.insert(out, ui.node("text", { key = "runs-state", spans = { ui.span("Loading all checks…", "muted") } }))
	elseif fail then
		local when = if fail.retryAt then "Trying again at " .. os.date("%H:%M:%S", fail.retryAt) .. "." else "Retry to load them."
		table.insert(
			out,
			ui.node("text", {
				key = "runs-state",
				spans = { ui.span("Could not load all checks: " .. brief(fail.problem.message), "error"), ui.span("  " .. when, "muted") },
			})
		)
		table.insert(
			out,
			ui.el("button", { key = "runs-retry", class = "plotroom-btn", text = "Retry", aria = "Retry loading all checks", actions = { click = "retry-checks" } })
		)
	end
	local fold = math.max(CHECK_LIMIT, required) -- required checks never fold away
	local expanded = state.expanded[pr.key] == true
	local shown = if expanded then #runs else math.min(#runs, fold)
	local list: { Node } = {}
	local function sub(id: string, text: string)
		table.insert(list, ui.node("text", { key = id, spans = { ui.span(text, "muted") } }))
	end
	for i = 1, shown do
		local r = runs[i]
		if required > 0 and i == 1 then
			sub("req-head", "Required · " .. required)
		elseif required > 0 and i == required + 1 then
			sub("other-head", "Other · " .. (#runs - required))
		end
		local what = r.name .. " — " .. r.detail .. (if r.required then " (required)" else "")
		local props: { [string]: any } = {
			key = "run" .. i,
			class = "plotroom-run",
			title = what,
			aria = what,
		}
		if r.url then
			props.href = checkHref(i, r.url)
			props.actions = { click = "open" }
		end
		table.insert(
			list,
			ui.el(if r.url then "button" else "div", props, {
				ui.el("span", { class = "dot", attrs = { ["aria-hidden"] = true } }, { ui.text({ ui.span("●", RUN_TONE[r.status]) }) }),
				ui.el("span", { class = "name", text = r.name }),
				ui.el("span", { class = "detail", text = r.detail }),
			})
		)
	end
	table.insert(out, ui.el("div", { key = "runs", class = "plotroom-runs" }, list))
	if #runs > fold then
		table.insert(
			out,
			ui.el("button", {
				key = "runs-toggle",
				class = "plotroom-more",
				text = if expanded then "Show fewer" else "Show " .. (#runs - shown) .. " more",
				actions = { click = "more-checks" },
			})
		)
	end
	if total > #runs then
		table.insert(out, ui.node("text", { key = "runs-more", spans = { ui.span((total - #runs) .. " more not loaded", "muted") } }))
	end
	return out
end

local function previewNodes(state: State, open: { [number]: boolean }): { Node }
	local pr = selectedPr(state)
	if not pr then
		cancelDetails(state)
		return {}
	end
	if pr.checks then
		wantDetails(state, pr)
	else
		cancelDetails(state)
	end
	local check = if pr.checks then CHECK[pr.checks] else nil
	local review = if pr.review then REVIEW_BADGE[pr.review] else nil
	local sb = STATE_BADGE[stateKind(pr)] or STATE_BADGE.open
	local chips: { Node } = { ui.node("badge", { key = "state", text = sb.text, tone = sb.tone }) }
	if open[pr.number] then
		table.insert(chips, ui.node("badge", { key = "tab", text = "In tab", tone = "accent" }))
	end
	for i, l in pr.labels do
		table.insert(chips, ui.node("badge", { key = "label" .. i, text = l }))
	end
	-- Branch chips: CSS cuts long names with an ellipsis; the full name is the tooltip and accessible name.
	local function ref(key: string, label: string, value: string): Node
		return ui.el("span", { key = key, class = "plotroom-ref " .. key, text = value, title = value, aria = label .. " " .. value })
	end
	local facts: { { [string]: any } } = {
		{ k = "Author", v = "@" .. pr.author },
		{ k = "Checks", v = { if check then ui.span(check.text, check.tone) else ui.span("None", "muted") } },
		{ k = "Review", v = { if review then ui.span(review.text, review.tone) else ui.span("None", "muted") } },
		{ k = "Comments", v = { ui.span(tostring(pr.comments), "num") } },
		{ k = "Opened", v = github.age(pr.created) .. " ago" },
		{ k = "Updated", v = github.age(pr.updated) .. " ago" },
	}
	-- Buttons sit above the facts so a short pane never clips them.
	local btns: { Node } = {
		ui.el("button", {
			key = "open",
			class = "plotroom-btn primary",
			text = "Open",
			href = prHref("open", pr),
			actions = { click = "open" },
			title = "Open in a Browser block",
			aria = "Open pull request #" .. pr.number .. " in a Browser block",
		}, { ui.node("kbd", { keys = { "enter" } }) }),
		ui.el("button", {
			key = "worktree",
			class = "plotroom-btn",
			text = "Worktree",
			href = prHref("worktree", pr),
			actions = { click = "open" },
			title = "Check out in a worktree tab",
			aria = "Check out pull request #" .. pr.number .. " in a worktree tab",
		}, { ui.node("kbd", { keys = { "w" } }) }),
		ui.el("button", {
			key = "agent",
			class = "plotroom-btn",
			text = "Agent",
			href = prHref("agent", pr),
			actions = { click = "open" },
			title = "Pick an omp prompt template or skill and run it in this pull request's worktree",
			aria = "Run an agent on pull request #" .. pr.number,
		}, { ui.node("kbd", { keys = { "a" } }) }),
	}
	if open[pr.number] then
		table.insert(
			btns,
			ui.el("button", {
				key = "goto",
				class = "plotroom-btn",
				text = "Go to tab",
				href = prHref("goto", pr),
				actions = { click = "open" },
				title = "Show the tab working in this pull request's worktree",
			}, { ui.node("kbd", { keys = { "g" } }) })
		)
	end
	local buttons = ui.el("div", { key = "buttons", class = "plotroom-actions" }, btns)
	local out: { Node } = {
		ui.el("div", { key = "head", class = "plotroom-head" }, {
			ui.el("button", {
				key = "copy",
				class = "plotroom-num",
				text = "#" .. pr.number,
				href = pr.url,
				actions = { click = "copy" },
				title = "Copy link",
				aria = "Copy link to pull request #" .. pr.number,
			}, { ui.el("span", { class = "icon", text = "⧉", attrs = { ["aria-hidden"] = true } }) }),
			ref("branch", "Branch", pr.head),
			ui.el("span", { key = "into", class = "plotroom-into", text = "→", attrs = { ["aria-hidden"] = true } }),
			ref("base", "Base", pr.base),
		}),
		ui.node("text", { key = "title", role = "plotroom.title", spans = { ui.span(pr.title, "strong") } }),
		ui.node("row", { key = "chips", gap = "xs", wrap = true }, chips),
		buttons,
	}
	for _, n in worktreeNodes(state, pr) do
		table.insert(out, n)
	end
	table.insert(out, ui.node("kv", { key = "facts", items = facts }))
	local added, removed = pr.additions, pr.deletions
	if added + removed > 0 then
		table.insert(
			out,
			ui.node("meter", {
				key = "diff",
				parts = {
					{ value = added / (added + removed), token = "ins", label = "+" .. added },
					{ value = removed / (added + removed), token = "error", label = "−" .. removed },
				},
				label = spans(ui.span("+" .. added, "ins"), " ", ui.span("−" .. removed, "error")),
				total = pr.files .. (if pr.files == 1 then " file" else " files"),
			})
		)
	end
	for _, n in checksNodes(state, pr) do
		table.insert(out, n)
	end
	return out
end

local function helpOverlay(state: State): Node
	local rows: { KeyHelp } = if state.settings then SETTINGS_KEYS else QUEUE_KEYS
	local items: { { [string]: any } } = {}
	for _, h in rows do
		local caps: { Span | string } = {}
		for i, label in h.keys do
			if i > 1 then
				table.insert(caps, " ")
			end
			table.insert(caps, ui.span(label, "key"))
		end
		table.insert(items, { k = caps, v = h.text })
	end
	return ui.node("overlay", { key = "help", modal = true, size = "md", head = "Keyboard shortcuts" }, {
		ui.node("kv", { key = "keys", items = items }),
		ui.el("div", { key = "buttons", class = "plotroom-actions" }, {
			ui.el("button", {
				key = "close",
				class = "plotroom-btn",
				text = "Close",
				aria = "Close the shortcut list",
				actions = { click = "close-help" },
			}, { ui.node("kbd", { keys = { "esc" } }) }),
		}),
	})
end

local function queueView(state: State): BlockView
	local snap, problem, f, pr = state.snap, state.problem, activeFilter(state), selectedPr(state)
	local v = filtered(state)
	local items: { any } = {}
	local order: { string } = {}
	local open = openPrs(state)
	if snap then
		items = rowsOf(state, snap, open)
	else
		tern.json.array(items)
	end
	if v then
		order = v.order
	else
		tern.json.array(order)
	end

	-- The repo is the heading: the filter's name is already the selected scope.
	local title: { any } = { ui.span(state.repo or "No repository") }
	if snap and problem then
		table.insert(title, ui.span("  stale", "warning"))
	elseif snap and not snap.complete then
		table.insert(title, ui.span("  partial", "warning"))
	end
	local subtitle: { any } = {}
	local function note(span: any)
		if #subtitle > 0 then
			table.insert(subtitle, ui.span(" · ", "muted"))
		end
		table.insert(subtitle, span)
	end
	if state.inflight == state.gen then
		local busy: any = ui.span("Refreshing…", "muted")
		busy.fx = "shimmer"
		note(busy)
	elseif snap then
		note(ui.span("updated " .. os.date("%H:%M", snap.fetched), "muted"))
	end
	if problem and snap then
		note(ui.span((HEADS[problem.kind] or "Plotroom") .. ", showing the last results", "warning"))
	end
	if snap and not snap.complete then
		note(ui.span("Partial results: narrow this filter", "warning"))
	end
	if state.storeError then
		note(ui.span(state.storeError, "error"))
	end

	local scopes: { any } = {}
	for _, fl in state.store.items do
		local k = snapKey(state, fl.query)
		local cached = if k then state.snaps[k] else nil
		table.insert(scopes, { id = fl.id, label = fl.name, icon = "funnel", count = if cached then #cached.prs else nil })
	end

	local wait = if state.account then github.wait(os.time(), login(state)) else 0
	local actions: { any } = {
		{ id = "settings", label = "Settings", keys = { "s" } },
		{
			id = "retry",
			label = "Refresh",
			keys = { "r" },
			disabled = if wait > 0 then "Paused by GitHub until " .. os.date("%H:%M:%S", os.time() + wait) else nil,
		},
	}

	local props: { [string]: any } = {
		key = "queue",
		size = "screen",
		layout = "cards",
		preview = "side",
		icon = "merge",
		title = title,
		subtitle = if #subtitle > 0 then subtitle else nil,
		noun = "pull requests",
		placeholder = "Filter the loaded pull requests",
		state = if not snap and problem then "error" elseif not snap and f then "loading" else "ready",
		empty = {
			ui.span(if f then "No pull requests match " .. f.name .. "." else "No saved filters yet. Press s to add one.", "muted"),
		},
		items = items,
		order = order,
		hits = if v then v.hits else nil,
		selected = if pr then itemId(pr) else nil,
		focus = state.focus,
		scopes = tern.json.array(scopes),
		scope = state.activeId,
		columns = {
			{ id = "changes", format = "text", priority = 50 },
			{ id = "updated", format = "time", priority = 90 },
		},
		actions = actions,
	}
	if state.query then
		local qp = input.props(state.query)
		props.query, props.cursor = qp.text, qp.cursor
	end
	if not snap and problem then
		props.message = spans(ui.span(HEADS[problem.kind] or "Plotroom", "strong"), "  ", problem.message, "  ", ui.span(HELP[problem.kind] or "", "muted"))
	end
	local layer: { Node } = { ui.node("picker", props, previewNodes(state, open)) }
	if state.help then
		table.insert(layer, helpOverlay(state))
	end
	return { main = ui.col({ contextNode(state) }), layer = ui.col(layer) }
end

local function confirmOverlay(state: State, row: string): Node
	local id = string.match(row, "^delete:(.+)$")
	local name = "this filter"
	for _, f in state.store.items do
		if f.id == id then
			name = f.name
		end
	end
	local head = "Delete filter “" .. name .. "”?"
	local body = "Every Plotroom pane loses this saved search."
	return ui.node("overlay", { key = "confirm", modal = true, size = "sm", head = head }, {
		ui.node("text", {
			key = "body",
			spans = { ui.span(body .. " Press d to delete it; Enter or Esc keeps it.", "muted") },
		}),
		ui.el("div", { key = "buttons", class = "plotroom-actions" }, {
			ui.el("button", { key = "keep", class = "plotroom-btn", text = "Keep", actions = { click = "cancel-delete" } }, {
				ui.node("kbd", { keys = { "enter" } }),
			}),
			ui.el("button", { key = "delete", class = "plotroom-btn danger", text = "Delete", actions = { click = "confirm-delete" } }, {
				ui.node("kbd", { keys = { "d" } }),
			}),
		}),
	})
end

local function settingsView(state: State): BlockView
	local s = state.settings :: Settings
	local sections, lead, extra = pageContent(state)
	local props: { [string]: any } = {
		key = "settings",
		title = "Plotroom",
		pages = PAGE_DEFS,
		page = s.page,
		lead = lead,
		sections = sections,
		focus = s.focus,
	}
	if s.edit then
		local p = input.props(s.edit.model)
		props.editing = { row = s.edit.row, draft = p.text, cursor = p.cursor }
	end
	local layer: Node? = nil
	if s.confirm then
		layer = ui.col({ confirmOverlay(state, s.confirm) })
	elseif state.help then
		layer = ui.col({ helpOverlay(state) })
	end
	return {
		main = ui.col({ contextNode(state), ui.node("prefs", props, extra) }),
		layer = layer,
	}
end

-- A pane moved into or out of a PR worktree, or ended: redraw every queue so "In tab" marks follow. Deferred, since
-- the host's pane list still holds an exiting pane while its event runs (observed: an undeferred redraw kept the mark).
local function redrawQueues()
	tern.timer(250, function()
		for _, s in running do
			if alive(s) then
				s.cx:render()
			end
		end
	end)
end
tern.on("cwd", function(_ev: any, _cx: any)
	redrawQueues()
end)
tern.on("pane_exited", function(_ev: any, _cx: any)
	redrawQueues()
end)

-- ---------------------------------------------------------------- block

tern.block.define("prs", {
	init = function(cx: BlockCx, args: { string }, saved: any): State
		local cwd: string? = nil
		local from: { any } = { if isTable(saved) then saved.launchCwd else nil, args[1], cx.cwd }
		for _, c in from do
			if type(c) == "string" and c ~= "" and tern.fs.exists(c) then
				cwd = c
				break
			end
		end
		local previous = running[cx.pane]
		if previous and previous.launchCwd == cwd and alive(previous) then
			-- The runtime re-runs init on every settings reload (observed every 7-15 s).
			-- Keep the live state: a fresh one would restart the repo lookup and the
			-- GitHub search each time, flashing the spinner/card.
			previous.cx = cx
			return previous
		end
		if previous then
			retire(previous)
		end
		local store, writable, err = loadStore()
		local active: string? = nil
		if isTable(saved) and type(saved.activeFilterId) == "string" then
			active = saved.activeFilterId
		end
		local sp: { kind: string, message: string, repo: string? }? = nil
		if isTable(saved) and isTable(saved.pause) and saved.launchCwd == cwd then
			local k: string, m, r = saved.pause.kind, saved.pause.message, saved.pause.repo
			if type(m) == "string" and (k == "no-repo" or ((k == "auth" or k == "missing" or k == "not-found" or k == "invalid") and type(r) == "string")) then
				local pause: { kind: string, message: string, repo: string? } = { kind = k :: string, message = m, repo = if type(r) == "string" then r else nil }
				sp = pause
			end
		end
		local state: State = {
			cx = cx,
			launchCwd = cwd,
			activeId = active,
			store = store,
			writable = writable,
			storeError = err,
			snaps = {},
			snap = nil,
			cursor = nil,
			focus = "list",
			inflight = nil,
			gen = 0,
			repo = if sp then sp.repo else nil,
			account = nil,
			applied = nil,
			resolving = false,
			cost = COST_GUESS,
			interval = nil,
			nextAt = nil,
			problem = if sp then { kind = sp.kind, message = sp.message } else nil,
			timer = nil,
			query = nil,
			help = false,
			vis = nil,
			details = {},
			detailFail = {},
			detailBusy = {},
			detailAttempt = nil,
			expanded = {},
			notes = {},
			noteSeq = 0,
			settings = nil,
		}
		if not activeFilter(state) then
			state.activeId = if store.items[1] then store.items[1].id else nil
		end
		running[cx.pane] = state
		refresh(state)
		return state
	end,

	title = function(state: State): string?
		local snap = state.snap
		local f = activeFilter(state)
		return "Plotroom · " .. (if f then f.name else "GitHub PRs") .. (if snap then " (" .. #snap.prs .. ")" else "")
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		return if state.settings then settingsView(state) else queueView(state)
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		local plain = not (key.ctrl or key.alt or key.meta)
		local name = key.name
		local k = key.text or name
		local s = state.settings
		if state.help then
			if name == "escape" or name == "enter" or (plain and k == "?") then
				state.help = false
				return true
			end
			return false
		end
		if s then
			if s.confirm then
				-- Enter keeps the filter or command: deleting takes a deliberate `d` or a click.
				if name == "enter" or name == "escape" then
					s.confirm = nil
				elseif plain and k == "d" then
					confirmDelete(state)
				else
					return false
				end
				return true
			end
			local e = s.edit
			if e then
				if name == "escape" then
					discardEdit(state)
				elseif name == "enter" then
					commitEdit(state)
				elseif not input.key(e.model, key, function(t)
					cx:copy(t)
				end) then
					return false
				end
				return true
			end
			if name == "escape" then
				state.settings = nil
			elseif name == "tab" and plain then
				local at = table.find(PAGES, s.page) or 1
				s.page = PAGES[((at - 1 + (if key.shift then -1 else 1)) % #PAGES) + 1]
				s.focus, s.edit, s.errors = nil, nil, {}
			elseif plain and k == "?" then
				state.help = true
			elseif name == "up" or name == "down" then
				local rows = focusRows(state)
				if #rows == 0 then
					return false
				end
				local at = if s.focus then table.find(rows, s.focus) else nil
				local down = name == "down"
				s.focus = rows[if at then math.clamp(at + (if down then 1 else -1), 1, #rows) elseif down then 1 else #rows]
			elseif name == "enter" or name == "space" then
				runRow(state, s.focus)
			else
				return false
			end
			return true
		end

		local searching = state.query ~= nil
		local scopes = state.focus == "scopes"
		if name == "tab" and plain then
			state.focus = if scopes then "list" else "scopes"
		elseif name == "escape" then
			local q = state.query
			if q then
				state.query = if q.text ~= "" then input.new("") else nil
				ensureCursor(state)
			elseif scopes then
				state.focus = "list"
			else
				return false
			end
		elseif name == "up" or (not searching and plain and k == "k") then
			if scopes then
				moveFilter(state, -1)
			else
				moveCursor(state, -1)
			end
		elseif name == "down" or (not searching and plain and k == "j") then
			if scopes then
				moveFilter(state, 1)
			else
				moveCursor(state, 1)
			end
		elseif name == "page_up" or name == "page_down" then
			moveCursor(state, if name == "page_up" then -10 else 10)
		elseif not searching and (name == "home" or name == "end") then
			local d = if name == "home" then -100000 else 100000
			if scopes then
				moveFilter(state, d)
			else
				moveCursor(state, d)
			end
		elseif name == "enter" then
			if scopes then
				state.focus = "list"
			else
				openSelected(state, "open", false)
			end
		elseif state.query then
			local q = state.query
			local before = q.text
			if not input.key(q, key, function(t)
				cx:copy(t)
			end) then
				return false
			end
			if q.text ~= before then
				ensureCursor(state)
			end
		elseif plain and k == "/" then
			state.query = input.new("")
		elseif plain and k == "?" then
			state.help = true
		elseif plain and k == "r" then
			retry(state)
		elseif plain and k == "s" then
			openSettings(state, "filters")
		elseif plain and k == "w" then
			openSelected(state, "worktree", false)
		elseif plain and k == "g" then
			local pr = selectedPr(state)
			if not pr or not openPrs(state)[pr.number] then
				return false
			end
			openSelected(state, "goto", false)
		elseif plain and k == "a" then
			openSelected(state, "agent", false)
		else
			return false
		end
		return true
	end,

	event = function(state: State, ev: UiEvent, _cx: BlockCx)
		if not alive(state) then
			return
		end
		local s = state.settings
		local act = if ev.ev == "action" and type(ev.act) == "string" then ev.act else nil
		local item = if type(ev.item) == "string" then ev.item else nil
		if act == "more-checks" then
			local pr = selectedPr(state)
			if pr then
				if state.expanded[pr.key] then
					state.expanded[pr.key] = nil
				else
					state.expanded[pr.key] = true
				end
			end
		elseif act == "retry-checks" then
			local pr = selectedPr(state)
			local key = if pr then detailKey(state, pr) else nil
			if key then
				state.detailFail[key] = nil
				cancelDetails(state)
			end
		elseif act == "copy-wt" then
			copyCommands(state, ev.value)
		elseif act == "worktree-status" then
			noteWorktree(state, ev.value)
		elseif act == "close-help" then
			state.help = false
		elseif act == "choose-repo" then
			openSettings(state, "worktrees", "checkout", true)
		elseif act == "confirm-delete" then
			if s and s.confirm then
				confirmDelete(state)
			end
		elseif act == "cancel-delete" then
			if s then
				s.confirm = nil
			end
		elseif s then
			if ev.id ~= SETTINGS_ID then
				return
			end
			if act == "page" then
				if type(ev.value) == "string" and table.find(PAGES, ev.value) then
					s.page, s.focus, s.edit, s.errors = ev.value, nil, nil, {}
				end
			elseif act == "close" then
				if ev.value == nil then
					state.settings = nil
				else
					discardEdit(state)
				end
			elseif act == "add" or act == "delete" or act == "refresh" then
				if type(ev.value) == "string" then
					s.focus = ev.value
					runAction(state, act, ev.value)
				end
			elseif ev.ev == "activate" and item then
				beginEdit(state, item)
			elseif ev.ev == "select" and item then
				s.focus = item
			elseif ev.ev == "change" and item and (ev.value == nil or ev.value == tern.json.null) then
				resetRow(state, item)
			end
		elseif ev.id == QUEUE_ID then
			if ev.ev == "select" or ev.ev == "activate" then
				local pr = if item then prOfItem(state, item) else nil
				if not pr then
					return -- a refresh replaced the snapshot
				end
				state.cursor, state.focus = pr.key, "list"
				if ev.ev == "activate" then
					openSelected(state, "open", true)
				end
			elseif act == "scope" then
				state.focus = "list"
				if type(ev.value) == "string" and ev.value ~= state.activeId then
					for _, f in state.store.items do
						if f.id == ev.value then
							switchFilter(state, f.id)
						end
					end
				end
			elseif act == "clear" or act == "close" then
				state.query = nil
				ensureCursor(state)
			elseif act == "settings" then
				openSettings(state, "filters")
			elseif act == "retry" then
				retry(state)
			elseif act == "open" or act == "worktree" then
				openSelected(state, act, false)
			end
		end
	end,

	save = function(state: State): any
		local p = state.problem
		local pause: { kind: string, message: string, repo: string? }? = nil
		local terminal = p ~= nil and (p.kind == "no-repo" or (TERMINAL[p.kind] and p.kind ~= "account"))
		if p and terminal then
			pause = { kind = p.kind, message = p.message, repo = state.repo }
		end
		return { version = 1, launchCwd = state.launchCwd, activeFilterId = state.activeId, pause = pause }
	end,
})
