--!strict
-- The `prs` block: a live GitHub PR queue with saved, editable filters.

local github = require("./github")
local input = require("./input")
local process = require("./process")
local worktree = require("./worktree")

local ui = tern.ui

local POLL_MS = 60 * 1000
local COST_GUESS = 10

type Filter = { id: string, name: string, query: string }
type Store = { version: number, nextId: number, items: { Filter } }
type Snap = { prs: { github.Pr }, total: number, complete: boolean, fetched: number }
type Settings = {
	page: string, -- "filters" | "github" | "worktrees"
	focus: string?, -- focused prefs row id
	edit: { row: string, model: input.Model }?, -- text row being edited
	errors: { [string]: string }, -- row id -> warning under the row
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
	loading: boolean,
	gen: number,
	repo: string?,
	cost: number,
	interval: number?,
	nextAt: number?,
	resolving: boolean,
	problem: github.Problem?,
	timer: TimerHandle?,
	query: input.Model?, -- nil: the search is hidden
	details: { [string]: { runs: { github.Run }, total: number } }, -- all checks per PR (key .. "@" .. updated)
	detailAsk: string?, -- the details key being loaded
	expanded: { [string]: boolean }, -- PR keys whose check list is unfolded
	settings: Settings?,
}

local running: { [number]: State } = {}

-- ---------------------------------------------------------------- storage

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
	if type(v) ~= "table" or v.version ~= 1 or type(v.nextId) ~= "number" or type(v.items) ~= "table" then
		return nil
	end
	local items: { Filter } = {}
	for _, f in v.items do
		if type(f) ~= "table" or type(f.id) ~= "string" or type(f.name) ~= "string" or type(f.query) ~= "string" then
			return nil
		end
		table.insert(items, { id = f.id, name = f.name, query = f.query })
	end
	return { version = 1, nextId = v.nextId, items = items }
end

local function writeStore(store: Store): string?
	local ok, err = pcall(tern.kv.set, "filters", {
		version = 1,
		nextId = store.nextId,
		items = tern.json.array(store.items),
	})
	if ok then
		return nil
	end
	return tostring(err)
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
	if ok and type(v) == "table" then
		return v
	end
	return {}
end

-- ---------------------------------------------------------------- lifecycle

local function retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
	end
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	state.loading = false
	state.snap = nil
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

-- The PRs the local search lets through, in snapshot order.
local function visible(state: State): { github.Pr }
	local snap = state.snap
	if not snap then
		return {}
	end
	local q = state.query
	if not q or trim(q.text) == "" then
		return snap.prs
	end
	local out: { github.Pr } = {}
	for _, pr in snap.prs do
		if github.match(pr, q.text) then
			table.insert(out, pr)
		end
	end
	return out
end

-- Keep the cursor on a visible result (the first when it vanished).
local function ensureCursor(state: State)
	local vis = visible(state)
	if indexOf(vis, state.cursor) == 0 then
		state.cursor = if vis[1] then vis[1].key else nil
	end
end

-- The saved gh login of the launch repo (nil: the active gh account); part of every quota and cache identity.
local function acct(state: State): string?
	return if state.repo then github.account(state.repo) else nil
end

local function snapKey(state: State, query: string): string
	return (state.repo or "") .. "\0" .. (acct(state) or "") .. "\0" .. query
end

local function showSnapshot(state: State)
	local f = activeFilter(state)
	state.snap = if f and state.repo then state.snaps[snapKey(state, f.query)] else nil
	ensureCursor(state)
end

local refresh: (State) -> ()

-- Problems that retrying cannot fix by itself: no automatic refresh until an
-- explicit Retry. ("not-found" is reserved for the GitHub layer's classifier.)
local TERMINAL: { [string]: boolean } = { auth = true, missing = true, ["not-found"] = true, invalid = true }

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
	ms = math.max(ms, github.wait(os.time(), acct(state)) * 1000)
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
	local halted = state.problem
	if halted and TERMINAL[halted.kind] then
		return
	end
	if state.loading then
		return
	end
	local f = activeFilter(state)
	if not f then
		state.problem = nil
		return
	end
	-- The server's cooldown holds for every trigger, manual refresh included.
	local wait = github.wait(os.time(), acct(state))
	if wait > 0 then
		-- Nothing is loading: say why, so an uncached filter does not show a spinner until the reset.
		state.problem = { kind = "rate-limit", message = "GitHub's rate limit is reached; searches resume at " .. os.date("%H:%M:%S", os.time() + wait) .. "." }
		return schedule(state, wait * 1000)
	end
	state.loading = true
	local gen, query = state.gen, f.query
	local key = snapKey(state, query)
	github.search(repo, query, function()
		return running[state.cx.pane] == state and state.gen == gen
	end, function(result, problem, spent)
		if not alive(state) then
			return
		end
		state.loading = false
		if state.gen ~= gen or (problem and problem.kind == "superseded") then
			refresh(state)
			state.cx:render()
			return
		end
		if result then
			state.snaps[key] = { prs = result.prs, total = result.total, complete = result.complete, fetched = os.time() }
			state.snap = state.snaps[key]
			state.problem = nil
			ensureCursor(state)
		else
			state.problem = problem
		end
		if spent > 0 then
			-- A finished snapshot shows the real points cost; a failed one keeps the larger known cost.
			state.cost = if result then spent else math.max(spent, state.cost)
			state.interval = github.interval(github.quota(acct(state)), os.time(), state.cost, openPanes(), POLL_MS)
		else
			state.interval = nil -- nothing was sent (invalid query): no quota to pace
		end
		if not (problem and TERMINAL[problem.kind]) then
			schedule(state, state.interval or POLL_MS)
		end
		state.cx:render()
	end)
end

-- A different applied query: invalidate whatever is in flight and reload now.
local function changed(state: State)
	state.gen += 1
	if state.repo and not (state.problem and TERMINAL[state.problem.kind]) then
		state.problem = nil
	end
	showSnapshot(state)
	refresh(state)
end

-- Explicit user retry (`r`, Refresh, Retry): also looks for a repository again.
local function retry(state: State)
	process.reset()
	local p = state.problem
	if p and (TERMINAL[p.kind] or (not state.repo and p.kind == "no-repo")) then
		state.problem = nil
	end
	refresh(state)
end

local function switchFilter(state: State, id: string?)
	state.activeId = id
	local f = activeFilter(state)
	local s = if f and state.repo then state.snaps[snapKey(state, f.query)] else nil
	local age = if s then os.time() - s.fetched else 0
	local fresh = math.floor((state.interval or POLL_MS) / 1000)
	local halted = state.problem
	if s and not state.loading and age < fresh and not (halted and TERMINAL[halted.kind]) then
		-- A snapshot younger than the refresh interval: show it and keep polling on its schedule.
		state.problem = nil
		showSnapshot(state)
		schedule(state, (fresh - age) * 1000)
	else
		changed(state)
	end
end

-- After another block wrote the filters, or on restore: reread storage.
local function reloadStore(state: State)
	local store, writable, err = loadStore()
	state.store, state.writable, state.storeError = store, writable, err
	if not activeFilter(state) then
		switchFilter(state, if store.items[1] then store.items[1].id else nil)
	end
end

local function propagate(origin: State)
	for _, s in running do
		if s ~= origin then
			reloadStore(s)
			s.cx:render()
		end
	end
end

-- ---------------------------------------------------------------- navigation

-- Moves the cursor `delta` rows through the visible PRs, clamped to the list.
local function moveCursor(state: State, delta: number)
	local vis = visible(state)
	if #vis == 0 then
		return
	end
	local i = indexOf(vis, state.cursor)
	state.cursor = vis[math.clamp(i + delta, 1, #vis)].key
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
		return "Auto-refresh paused: " .. halted.kind .. " error. Fix it, then Refresh."
	end
	local now = os.time()
	local q = github.quota(acct(state))
	local wait = github.wait(now, acct(state))
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
local HEADS: { [string]: string } = {
	missing = "GitHub CLI not found",
	auth = "GitHub CLI not signed in",
	["rate-limit"] = "GitHub rate limit",
	["not-found"] = "Repository not visible",
	invalid = "GitHub rejected the search",
	["no-repo"] = "No GitHub repository",
	failed = "Could not load pull requests",
}
local HELP: { [string]: string } = {
	missing = "Install the GitHub CLI (cli.github.com) so it is on your shell's PATH, then Refresh.",
	auth = "Run gh auth login in a terminal, then Refresh.",
	["rate-limit"] = "Searches resume automatically when GitHub's limit resets.",
	["not-found"] = "Check this repository's account in Settings › GitHub, then Refresh.",
	invalid = "Check the filter query and this repository's account in Settings, then Refresh.",
	["no-repo"] = "Open Plotroom from a checkout of a GitHub repository.",
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
			table.insert(sections, {
				id = "filter:" .. f.id,
				title = f.name .. (if active then " · showing" else ""),
				rows = {
					{ id = "name:" .. f.id, label = "Name", disabled = locked, control = { k = "text", value = f.name, placeholder = "My PRs" } },
					{
						id = "query:" .. f.id,
						label = "Query",
						hint = "GitHub search syntax, run inside " .. where .. ".",
						disabled = locked,
						control = { k = "text", value = f.query, placeholder = "is:open author:@me", mono = true },
					},
					{ id = "delete:" .. f.id, label = "Delete filter", disabled = locked, control = { k = "action", act = "delete", label = "Delete" } },
				},
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
	elseif s.page == "github" then
		lead = "Plotroom reads pull requests through GitHub's GraphQL API with your gh login."
		local account = if state.repo then github.account(state.repo) else nil
		local now = os.time()
		local wait = github.wait(now, acct(state))
		table.insert(sections, {
			id = "sec-account",
			title = "Account",
			rows = {
				{
					id = "account",
					label = "gh account",
					hint = "Login used for " .. where .. ". Empty: the active gh account.",
					control = { k = "text", value = account or "", placeholder = "Active gh account" },
					changed = account ~= nil,
					defaultLabel = "Active gh account",
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
		local q = github.quota(acct(state))
		if q and q.limit and q.remaining then
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
			row.warning = s.errors[row.id]
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

-- Saves (nil clears) the local checkout of the launch repo. Fails closed when the saved map cannot be read.
local function setCheckout(state: State, root: string?): string?
	local repo = state.repo
	if not repo then
		return NO_REPO
	end
	local ok, v = pcall(tern.kv.get, "repos")
	if not ok or (v ~= nil and type(v) ~= "table") then
		return "Saved checkouts could not be read"
	end
	local repos: { [string]: string } = if type(v) == "table" then v else {}
	repos["github.com/" .. string.lower(repo)] = root
	local ok2, err = pcall(tern.kv.set, "repos", repos)
	if not ok2 then
		return "Could not save: " .. tostring(err)
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

-- New account: old snapshots, problem and quota belong to the old identity; one authorized refresh.
local function accountChanged(state: State)
	state.gen += 1
	state.snaps, state.snap, state.problem = {}, nil, nil
	state.cx:toast("success", "GitHub account saved", "Refreshing " .. (state.repo or ""))
	retry(state)
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
	state.store, state.writable, state.storeError = store, true, nil
	if id == state.activeId then
		local nextF = store.items[math.min(at, #store.items)]
		switchFilter(state, if nextF then nextF.id else nil)
	end
	s.focus = "add"
	propagate(state)
end

local function runAction(state: State, act: string, row: string)
	local s = state.settings
	if not s then
		return
	end
	if act == "add" then
		addFilter(state)
	elseif act == "delete" then
		s.confirm = string.match(row, "^delete:(.+)$")
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

local function commitEdit(state: State)
	local s = state.settings
	local e = if s then s.edit else nil
	if not s or not e then
		return
	end
	local text = trim(e.model.text)
	local row = e.row
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
		if err then
			s.errors[row] = err
		else
			s.edit = nil
		end
	elseif row == "account" then
		local repo = state.repo
		if not repo then
			s.errors.account = NO_REPO
			return
		end
		local err = github.setAccount(repo, text)
		if err then
			s.errors.account = err
		else
			s.edit = nil
			accountChanged(state)
		end
	elseif row == "checkout" then
		if text == "" then
			local err = clearCheckout(state)
			if err then
				s.errors.checkout = err
			else
				s.edit = nil
			end
			return
		end
		local repo = state.repo
		if not repo then
			s.errors.checkout = NO_REPO
			return
		end
		local path, why = worktree.expandPath(text, tern.getenv("HOME"))
		if not path then
			s.errors.checkout = why
			return
		end
		s.busy, s.edit = true, nil
		worktree.resolveRepository(path, repo, function(info, problem)
			if not alive(state) or state.settings ~= s then
				return
			end
			s.busy = false
			if not info then
				beginEdit(state, "checkout", text) -- clears the row's error, so set it after
				s.errors.checkout = problem
			else
				local err = setCheckout(state, info.root)
				if err then
					s.errors.checkout = err
				else
					state.cx:toast("success", "Checkout saved", info.root)
				end
			end
			state.cx:render()
		end)
	end
end

-- Leaving a text row saves a changed value; a second Escape after a rejected save discards it.
local function endEdit(state: State)
	local s = state.settings
	local e = if s then s.edit else nil
	if not s or not e then
		return
	end
	local def = rowById(state, e.row)
	if s.errors[e.row] or not def or trim(e.model.text) == def.control.value then
		s.edit = nil
	else
		commitEdit(state)
	end
end

local function resetRow(state: State, row: string)
	local s = state.settings
	if not s then
		return
	end
	local err: string? = nil
	if row == "account" and state.repo then
		err = github.setAccount(state.repo, nil)
		if not err then
			accountChanged(state)
		end
	elseif row == "checkout" then
		err = clearCheckout(state)
	end
	if err then
		s.errors[row] = err
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

local function pickerItem(pr: github.Pr): { [string]: any }
	local check = if pr.checks then CHECK[pr.checks] else nil
	local kind = stateKind(pr)
	local badges: { any } = {}
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
		detail = "#" .. pr.number .. " · " .. pr.author .. " · " .. pr.head,
		mark = { text = pr.author, seed = pr.author },
		dot = if check then check.dot else nil,
		badges = if #badges > 0 then badges else nil,
		facts = {
			changes = { ui.span("+" .. pr.additions, "ins"), " ", ui.span("−" .. pr.deletions, "error") },
			updated = github.age(pr.updated),
		},
	}
end

local CHECK_LIMIT = 8

-- Link to a check's page: its row index (the window reads the live row to validate) and the percent-encoded URL.
local function checkHref(i: number, url: string): string
	local enc = string.gsub(url, "[^%w%-_%.~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
	return "plotroom://github/check/" .. i .. "/" .. enc
end

local function detailKey(pr: github.Pr): string
	return pr.key .. "@" .. pr.updated
end

-- Once the cursor rests on a PR, loads all of its checks with required flags (the search carries only the first 25,
-- unflagged, and shows meanwhile). A failed load keeps the search's checks. Idempotent: the view calls it every render.
local function wantDetails(state: State, pr: github.Pr)
	local key = detailKey(pr)
	if state.details[key] or state.detailAsk == key then
		return
	end
	state.detailAsk = key
	tern.timer(300, function()
		if not alive(state) then
			return
		end
		local cur = selectedPr(state)
		if not cur or detailKey(cur) ~= key then
			return -- the cursor moved on; its own render asks again
		end
		github.checks(pr.repo, pr.number, function(runs, total)
			if not alive(state) then
				return
			end
			if state.detailAsk == key then
				state.detailAsk = nil
			end
			state.details[key] = if runs then { runs = runs, total = total } else { runs = pr.runs, total = pr.runTotal }
			state.cx:render()
		end)
	end)
end

local function previewNodes(state: State): { Node }
	local pr = selectedPr(state)
	if not pr then
		return {}
	end
	if pr.checks then
		wantDetails(state, pr)
	end
	local d = state.details[detailKey(pr)]
	local runs = if d then d.runs else pr.runs
	local total = if d then d.total else pr.runTotal
	local check = if pr.checks then CHECK[pr.checks] else nil
	local review = if pr.review then REVIEW_BADGE[pr.review] else nil
	local sb = STATE_BADGE[stateKind(pr)]
	local chips: { Node } = { ui.node("badge", { key = "state", text = sb.text, tone = sb.tone }) }
	for i, l in pr.labels do
		table.insert(chips, ui.node("badge", { key = "label" .. i, text = l }))
	end
	local function ref(key: string, label: string, value: string): Node
		return ui.el("div", { key = key, class = "plotroom-fact", title = value }, {
			ui.el("span", { class = "k", text = label }),
			ui.el("span", { class = "v", text = value }),
		})
	end
	local facts = {
		{ k = "Number", v = "#" .. pr.number },
		{ k = "Author", v = "@" .. pr.author },
		{ k = "Checks", v = { if check then ui.span(check.text, check.tone) else ui.span("None", "muted") } },
		{ k = "Review", v = { if review then ui.span(review.text, review.tone) else ui.span("None", "muted") } },
		{ k = "Comments", v = { ui.span(tostring(pr.comments), "num") } },
		{ k = "Opened", v = github.age(pr.created) .. " ago" },
		{ k = "Updated", v = github.age(pr.updated) .. " ago" },
	}
	-- Buttons sit above the facts so a short pane never clips them.
	local buttons = ui.el("div", { key = "buttons", class = "plotroom-actions" }, {
		ui.el("button", {
			key = "open",
			class = "plotroom-btn primary",
			text = "Open",
			href = prHref("open", pr),
			actions = { click = "open" },
			title = "Open in a Browser block",
		}, { ui.node("kbd", { keys = { "enter" } }) }),
		ui.el("button", {
			key = "worktree",
			class = "plotroom-btn",
			text = "Worktree",
			href = prHref("worktree", pr),
			actions = { click = "open" },
			title = "Check out in a worktree tab",
		}, { ui.node("kbd", { keys = { "w" } }) }),
		ui.el("button", { key = "copy", class = "plotroom-btn", text = "Copy link", href = pr.url, actions = { click = "copy" } }),
	})
	local out: { Node } = {
		ui.node("text", { key = "title", role = "plotroom.title", spans = { ui.span(pr.title, "strong") } }),
		ui.node("row", { key = "chips", gap = "xs", wrap = true }, chips),
		buttons,
		ui.node("kv", { key = "facts", items = facts }),
		ref("head", "Branch", pr.head),
		ref("base", "Base", pr.base),
	}
	local a, d = pr.additions, pr.deletions
	if a + d > 0 then
		table.insert(
			out,
			ui.node("meter", {
				key = "diff",
				parts = {
					{ value = a / (a + d), token = "ins", label = "+" .. a },
					{ value = d / (a + d), token = "error", label = "−" .. d },
				},
				label = { ui.span("+" .. a, "ins"), " ", ui.span("−" .. d, "error") },
				total = pr.files .. (if pr.files == 1 then " file" else " files"),
			})
		)
	end
	if #runs > 0 then
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
		local fold = math.max(CHECK_LIMIT, required) -- required checks never fold away
		local expanded = state.expanded[pr.key] == true
		local shown = if expanded then #runs else math.min(#runs, fold)
		local list: { Node } = {}
		local function sub(key: string, text: string)
			table.insert(list, ui.node("text", { key = key, spans = { ui.span(text, "muted") } }))
		end
		for i = 1, shown do
			local r = runs[i]
			if required > 0 and i == 1 then
				sub("req-head", "Required · " .. required)
			elseif required > 0 and i == required + 1 then
				sub("other-head", "Other · " .. (#runs - required))
			end
			local props: { [string]: any } = {
				key = "run" .. i,
				class = "plotroom-run",
				title = r.name .. " — " .. r.detail .. (if r.required then " (required)" else ""),
			}
			if r.url then
				props.href = checkHref(i, r.url)
				props.actions = { click = "open" }
			end
			table.insert(
				list,
				ui.el(if r.url then "button" else "div", props, {
					ui.el("span", { class = "dot" }, { ui.text({ ui.span("●", RUN_TONE[r.status]) }) }),
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
	end
	return out
end

local function queueView(state: State): BlockView
	local snap, problem, f, pr = state.snap, state.problem, activeFilter(state), selectedPr(state)
	local items: { any } = {}
	local order: { string } = {}
	local hits: { [string]: any } = {}
	local needle = if state.query then state.query.text else ""
	if snap then
		for _, p in snap.prs do
			table.insert(items, pickerItem(p))
		end
		for _, p in visible(state) do
			table.insert(order, itemId(p))
			local _, range = github.match(p, needle)
			if range then
				hits[itemId(p)] = { range }
			end
		end
	end

	local title: { any } = { ui.span(if f then f.name else "Pull requests") }
	if snap and problem then
		table.insert(title, ui.span("  stale", "warning"))
	elseif snap and not snap.complete then
		table.insert(title, ui.span("  partial", "warning"))
	end
	local subtitle: { any } = { ui.span(state.repo or "No repository", "muted") }
	if state.loading then
		local busy: any = ui.span("Refreshing…", "muted")
		busy.fx = "shimmer"
		table.insert(subtitle, ui.span(" · ", "muted"))
		table.insert(subtitle, busy)
	elseif snap then
		table.insert(subtitle, ui.span(" · updated " .. os.date("%H:%M", snap.fetched), "muted"))
	end
	if problem and snap then
		table.insert(subtitle, ui.span(" · " .. (HEADS[problem.kind] or "Plotroom") .. ", showing the last results", "warning"))
	end
	if snap and not snap.complete then
		table.insert(subtitle, ui.span(" · Partial results: narrow this filter", "warning"))
	end
	if state.storeError then
		table.insert(subtitle, ui.span(" · " .. state.storeError, "error"))
	end

	local scopes: { any } = {}
	for _, fl in state.store.items do
		local cached = if state.repo then state.snaps[snapKey(state, fl.query)] else nil
		table.insert(scopes, { id = fl.id, label = fl.name, icon = "funnel", count = if cached then #cached.prs else nil })
	end

	local wait = github.wait(os.time(), acct(state))
	local actions: { any } = {}
	table.insert(actions, { id = "settings", label = "Settings", keys = { "s" } })
	table.insert(actions, {
		id = "retry",
		label = "Refresh",
		keys = { "r" },
		disabled = if wait > 0 then "Paused by GitHub until " .. os.date("%H:%M:%S", os.time() + wait) else nil,
	})

	local props: { [string]: any } = {
		key = "queue",
		size = "screen",
		layout = "cards",
		preview = "side",
		icon = "merge",
		title = title,
		subtitle = subtitle,
		noun = "pull requests",
		placeholder = "Filter the loaded pull requests",
		state = if not snap and problem then "error" elseif not snap and f then "loading" else "ready",
		empty = {
			ui.span(if f then "No pull requests match " .. f.name .. "." else "No saved filters yet. Press s to add one.", "muted"),
		},
		items = tern.json.array(items),
		order = tern.json.array(order),
		hits = if next(hits) then hits else nil,
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
		props.message = { ui.span(HEADS[problem.kind] or "Plotroom", "strong"), "  ", problem.message, "  ", ui.span(HELP[problem.kind] or "", "muted") }
	end
	return { main = ui.col({ contextNode(state) }), layer = ui.col({ ui.node("picker", props, previewNodes(state)) }) }
end

local function confirmOverlay(state: State, id: string): Node
	local name = "this filter"
	for _, f in state.store.items do
		if f.id == id then
			name = f.name
		end
	end
	return ui.node("overlay", { key = "confirm", modal = true, size = "sm", head = "Delete filter “" .. name .. "”?" }, {
		ui.node("text", { key = "body", spans = { ui.span("Every Plotroom pane loses this saved search.", "muted") } }),
		ui.el("div", { key = "buttons", class = "plotroom-actions" }, {
			ui.el("button", { key = "delete", class = "plotroom-btn danger", text = "Delete", actions = { click = "confirm-delete" } }, {
				ui.node("kbd", { keys = { "enter" } }),
			}),
			ui.el("button", { key = "keep", class = "plotroom-btn", text = "Keep", actions = { click = "cancel-delete" } }, {
				ui.node("kbd", { keys = { "esc" } }),
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
	return {
		main = ui.col({ contextNode(state), ui.node("prefs", props, extra) }),
		layer = if s.confirm then ui.col({ confirmOverlay(state, s.confirm) }) else nil,
	}
end

-- ---------------------------------------------------------------- block

tern.block.define("prs", {
	init = function(cx: BlockCx, args: { string }, saved: any): State
		local cwd: string? = nil
		for _, c in { if type(saved) == "table" then saved.launchCwd else nil, args[1], cx.cwd } do
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
		local active = if type(saved) == "table" and type(saved.activeFilterId) == "string" then saved.activeFilterId else nil
		local sp = nil
		if type(saved) == "table" and type(saved.pause) == "table" and saved.launchCwd == cwd then
			local k, m, r = saved.pause.kind, saved.pause.message, saved.pause.repo
			if type(m) == "string" and (k == "no-repo" or ((k == "auth" or k == "missing" or k == "not-found" or k == "invalid") and type(r) == "string")) then
				sp = { kind = k, message = m, repo = if type(r) == "string" then r else nil }
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
			loading = false,
			gen = 0,
			repo = if sp then sp.repo else nil,
			resolving = false,
			cost = COST_GUESS,
			interval = nil,
			nextAt = nil,
			problem = if sp then { kind = sp.kind, message = sp.message } else nil,
			timer = nil,
			query = nil,
			details = {},
			detailAsk = nil,
			expanded = {},
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
		local s = state.settings
		if s then
			if s.confirm then
				if name == "enter" then
					deleteFilter(state, s.confirm)
				elseif name == "escape" then
					s.confirm = nil
				else
					return false
				end
				return true
			end
			local e = s.edit
			if e then
				if name == "escape" then
					endEdit(state)
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
		local k = key.text or name
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
		elseif plain and k == "r" then
			retry(state)
		elseif plain and k == "s" then
			openSettings(state, "filters")
		elseif plain and k == "w" then
			openSelected(state, "worktree", false)
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
				state.expanded[pr.key] = if state.expanded[pr.key] then nil else true
			end
		elseif act == "choose-repo" then
			openSettings(state, "worktrees", "checkout", true)
		elseif act == "confirm-delete" then
			if s and s.confirm then
				deleteFilter(state, s.confirm)
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
					endEdit(state)
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
			end
		end
	end,

	save = function(state: State): any
		local p = state.problem
		local pause = nil
		if p and (TERMINAL[p.kind] or p.kind == "no-repo") then
			pause = { kind = p.kind, message = p.message, repo = state.repo }
		end
		return { version = 1, launchCwd = state.launchCwd, activeFilterId = state.activeId, pause = pause }
	end,
})
