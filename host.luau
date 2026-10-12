--!strict
-- The `prs` block: a live GitHub PR queue with saved, editable filters.

local github = require("./github")
local input = require("./input")
local process = require("./process")
local worktree = require("./worktree")

local ui = tern.ui

local POLL_MS = 60 * 1000
local COST_GUESS = 10
local PAGE_SIZE = 100
local LIST_ID = "main.prs."
local FILTERS_ID = "main.filters."
local FIELD_IDS = { name = "main.f-name", query = "main.f-query", path = "main.f-path" }

type Filter = { id: string, name: string, query: string }
type Store = { version: number, nextId: number, items: { Filter } }
type Snap = { prs: { github.Pr }, total: number, complete: boolean, fetched: number }
type Form = {
	id: string?,
	name: input.Model,
	query: input.Model,
	focus: string,
	error: string?,
}
type RepoForm = { repo: string, path: input.Model, focus: string, error: string?, busy: boolean }

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
	page: number,
	focus: string,
	loading: boolean,
	gen: number,
	repo: string?,
	cost: number,
	interval: number?,
	nextAt: number?,
	resolving: boolean,
	problem: github.Problem?,
	timer: TimerHandle?,
	form: Form?,
	confirmDelete: boolean,
	repoForm: RepoForm?,
	notice: string?,
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

-- Keep the cursor on a result (the first when it vanished) and its page in range.
local function ensureCursor(state: State)
	local snap = state.snap
	if not snap or #snap.prs == 0 then
		state.cursor, state.page = nil, 1
		return
	end
	local i = indexOf(snap.prs, state.cursor)
	if i == 0 then
		i = 1
		state.cursor = snap.prs[1].key
	end
	state.page = (i - 1) // PAGE_SIZE + 1
end

local function snapKey(state: State, query: string): string
	return (state.repo or "") .. "\0" .. query
end

local function showSnapshot(state: State)
	local f = activeFilter(state)
	state.snap = if f and state.repo then state.snaps[snapKey(state, f.query)] else nil
	ensureCursor(state)
end

local refresh: (State) -> ()

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
	ms = math.max(ms, github.wait(os.time()) * 1000)
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
		return resolveRepo(state)
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
	local wait = github.wait(os.time())
	if wait > 0 then
		-- Nothing is loading: say why, so an uncached filter does not show a spinner until the reset.
		state.problem = { kind = "rate-limit", message = "GitHub's search rate limit is reached; searches resume automatically (see the time above)." }
		return schedule(state, wait * 1000)
	end
	state.loading = true
	local gen, query = state.gen, f.query
	local key = snapKey(state, query)
	github.search(repo, query, function()
		return running[state.cx.pane] == state and state.gen == gen
	end, function(result, problem, requests)
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
		if requests > 0 then
			-- A finished snapshot shows the real page count; a failed one keeps the larger known cost.
			state.cost = if result then requests else math.max(requests, state.cost)
			state.interval = github.interval(github.quota(), os.time(), state.cost, openPanes(), POLL_MS)
		else
			state.interval = nil -- nothing was sent (invalid query): no quota to pace
		end
		schedule(state, state.interval or POLL_MS)
		state.cx:render()
	end)
end

-- A different applied query: invalidate whatever is in flight and reload now.
local function changed(state: State)
	state.gen += 1
	state.problem = nil
	showSnapshot(state)
	refresh(state)
end

local function switchFilter(state: State, id: string?)
	state.form = nil
	state.confirmDelete = false
	state.activeId = id
	local f = activeFilter(state)
	local s = if f and state.repo then state.snaps[snapKey(state, f.query)] else nil
	local age = if s then os.time() - s.fetched else 0
	local fresh = math.floor((state.interval or POLL_MS) / 1000)
	if s and not state.loading and age < fresh then
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

-- ---------------------------------------------------------------- editing

local function focusField(state: State, field: string?)
	state.cx:render()
	state.cx:frame({ { "focus", if field and FIELD_IDS[field] then FIELD_IDS[field] else tern.json.null } })
end

local function openForm(state: State, edit: boolean)
	local f = if edit then activeFilter(state) else nil
	if edit and not f then
		return
	end
	state.confirmDelete = false
	state.repoForm = nil
	state.form = {
		id = if f then f.id else nil,
		name = input.new(if f then f.name else ""),
		query = input.new(if f then f.query else ""),
		focus = "name",
		error = nil,
	}
	focusField(state, "name")
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

local function saveForm(state: State)
	local form = state.form
	if not form then
		return
	end
	local name, query = trim(form.name.text), trim(form.query.text)
	if name == "" or query == "" then
		form.error = "Name and query are both required."
		return
	end
	-- Reread so another window's edits are not clobbered.
	local store, writable, err = loadStore()
	if not writable then
		state.store, state.writable, state.storeError = store, false, err
		form.error = err or "Filters cannot be saved."
		return
	end
	local id = form.id
	local appliedChanged = true
	if id then
		local found = false
		for _, f in store.items do
			if f.id == id then
				appliedChanged = f.query ~= query or state.activeId ~= id
				f.name, f.query = name, query
				found = true
			end
		end
		if not found then
			form.error = "That filter was deleted elsewhere."
			return
		end
	else
		id = "f" .. store.nextId
		store.nextId += 1
		table.insert(store.items, { id = id, name = name, query = query })
	end
	local werr = writeStore(store)
	if werr then
		form.error = "Could not save: " .. werr
		return
	end
	state.store, state.writable, state.storeError = store, true, nil
	state.form = nil
	state.activeId = id
	if appliedChanged then
		changed(state)
	end
	propagate(state)
	focusField(state, nil)
end

local function deleteActive(state: State)
	state.confirmDelete = false
	local store, writable, err = loadStore()
	if not writable then
		state.notice = err
		return
	end
	local at = 0
	for i, f in store.items do
		if f.id == state.activeId then
			at = i
		end
	end
	if at == 0 then
		return
	end
	table.remove(store.items, at)
	local werr = writeStore(store)
	if werr then
		state.notice = "Could not delete: " .. werr
		return
	end
	state.store = store
	local nextF = store.items[math.min(at, #store.items)]
	switchFilter(state, if nextF then nextF.id else nil)
	propagate(state)
end

-- ---------------------------------------------------------------- repository mapping

local function saveRepo(state: State)
	local rf = state.repoForm
	if not rf or rf.busy then
		return
	end
	local path, why = worktree.expandPath(rf.path.text, tern.getenv("HOME"))
	if not path then
		rf.error = why
		return
	end
	rf.busy, rf.error = true, nil
	local repo = rf.repo
	worktree.resolveRepository(path, repo, function(info, problem)
		if not alive(state) then
			return
		end
		local cur = state.repoForm
		if cur ~= rf then
			return
		end
		rf.busy = false
		if not info then
			rf.error = problem
		else
			local repos = readRepos()
			repos["github.com/" .. string.lower(repo)] = info.root
			local ok, err = pcall(tern.kv.set, "repos", repos)
			if not ok then
				rf.error = "Could not save: " .. tostring(err)
			else
				state.repoForm = nil
				state.notice = "Repository saved; choose Worktree again"
				focusField(state, nil)
			end
		end
		state.cx:render()
	end)
end

-- ---------------------------------------------------------------- navigation

local function moveCursor(state: State, to: number)
	local snap = state.snap
	if not snap or #snap.prs == 0 then
		return
	end
	local pr = snap.prs[math.clamp(to, 1, #snap.prs)]
	state.cursor = pr.key
	ensureCursor(state)
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

local function goPage(state: State, page: number)
	local snap = state.snap
	if not snap then
		return
	end
	local pages = math.max(1, (#snap.prs + PAGE_SIZE - 1) // PAGE_SIZE)
	page = math.clamp(page, 1, pages)
	local pr = snap.prs[(page - 1) * PAGE_SIZE + 1]
	if pr then
		state.cursor = pr.key
		ensureCursor(state)
	end
end

local function formFields(state: State): { string }
	if state.form then
		return { "name", "query", "save", "cancel" }
	elseif state.repoForm then
		return { "path", "save", "cancel" }
	end
	return {}
end

local function cycle(state: State, back: boolean)
	local fields = formFields(state)
	local cur = if state.form then state.form.focus elseif state.repoForm then state.repoForm.focus else ""
	if #fields == 0 then
		state.focus = if state.focus == "filters" then "prs" else "filters"
		return
	end
	local at = table.find(fields, cur) or 1
	local nextAt = ((at - 1 + (if back then -1 else 1)) % #fields) + 1
	local nf = fields[nextAt]
	if state.form then
		state.form.focus = nf
	elseif state.repoForm then
		state.repoForm.focus = nf
	end
	focusField(state, nf)
end

local function cancelForms(state: State)
	state.form = nil
	state.repoForm = nil
	state.confirmDelete = false
	focusField(state, nil)
end

local function activate(state: State, act: string)
	if act == "save" then
		if state.form then
			saveForm(state)
		elseif state.repoForm then
			saveRepo(state)
		end
	elseif act == "cancel" then
		cancelForms(state)
	end
end

-- ---------------------------------------------------------------- view

local function badge(label: string, act: string, tone: string, key: string?): Node
	local node = ui.badge(label, tone)
	local p: { [string]: any } = node.p or {}
	p.actions = { click = act }
	if key then
		p.key = key
	end
	node.p = p
	return node
end

local function button(state: State, label: string, act: string, focusName: string): Node
	local focused = (state.form and state.form.focus == focusName) or (state.repoForm and state.repoForm.focus == focusName)
	return badge(if focused then "▸ " .. label else label, act, if focused then "accent" else "neutral", nil)
end

local function field(label: string, key: string, model: input.Model, focused: boolean, placeholder: string): { Node }
	local props = input.props(model)
	props.key = key
	props.placeholder = placeholder
	props.aria = label
	return {
		ui.text({ ui.span(label, if focused then "strong" else "muted") }),
		ui.node("input", props),
	}
end

local function stateWord(pr: github.Pr): string
	if pr.state == "merged" then
		return "merged"
	elseif pr.state == "closed" then
		return "closed"
	elseif pr.draft then
		return "draft"
	end
	return "open"
end

local function stateTone(word: string): string
	return if word == "merged" then "accent" elseif word == "closed" then "error" elseif word == "draft" then "warning" else "success"
end

local function prHref(kind: string, pr: github.Pr): string
	return "plotroom://github/" .. kind .. "/" .. pr.repo .. "/" .. pr.number
end

local function problemCard(state: State, problem: github.Problem): Node
	local heads = {
		missing = "GitHub CLI not found",
		auth = "GitHub CLI not signed in",
		["rate-limit"] = "GitHub rate limit",
		failed = "Could not load pull requests",
	}
	local help = {
		missing = "Install the GitHub CLI (https://cli.github.com) so it is on the PATH of your shell, then Retry.",
		auth = "Run `gh auth login` in a terminal, then Retry.",
		["rate-limit"] = "Searches resume automatically at the time shown above.",
		failed = "",
	}
	local kids: { Node } = { ui.md(problem.message .. "\n\n" .. (help[problem.kind] or "")) }
	table.insert(kids, ui.row({ badge("Retry", "retry", "accent", nil) }))
	local card = ui.card({ ui.span(heads[problem.kind] or "Plotroom", "strong") }, kids)
	local p: { [string]: any } = card.p or {}
	p.tone = "error"
	card.p = p
	return card
end

local function filtersList(state: State): Node
	local items: { Item } = {}
	for _, f in state.store.items do
		table.insert(items, { label = { ui.span(f.name) }, value = { ui.span(f.query, "muted") }, icon = "filter" })
	end
	local list = ui.list(items)
	local kids = list.c or {}
	for i, f in state.store.items do
		local p: { [string]: any } = kids[i].p or {}
		p.key = f.id
		kids[i].p = p
	end
	local p: { [string]: any } = list.p or {}
	p.key = "filters"
	p.selected = if state.focus == "filters" and state.activeId then FILTERS_ID .. state.activeId else nil
	p.max = { lines = 3 }
	p.empty = { ui.span("Add a filter", "muted") }
	list.p = p
	return list
end

local function prList(state: State, snap: Snap): Node
	local items: { Item } = {}
	local first = (state.page - 1) * PAGE_SIZE + 1
	local last = math.min(#snap.prs, first + PAGE_SIZE - 1)
	for i = first, last do
		local pr = snap.prs[i]
		local word = stateWord(pr)
		table.insert(items, {
			label = {
				ui.span(word, stateTone(word)),
				ui.span("#" .. pr.number, "muted num"),
				ui.span(pr.title),
			},
			value = { ui.span("@" .. pr.author, "muted"), ui.span(github.age(pr.updated), "muted num") },
			icon = "merge",
			tone = if pr.draft then "muted" else nil,
		})
	end
	local list = ui.list(items)
	local kids = list.c or {}
	for i = first, last do
		local pr = snap.prs[i]
		local p: { [string]: any } = kids[i - first + 1].p or {}
		p.key = pr.key
		p.href = prHref("open", pr)
		p.actions = { click = "open" }
		kids[i - first + 1].p = p
	end
	local p: { [string]: any } = list.p or {}
	p.key = "prs"
	p.role = "pr-list"
	p.selected = if state.focus == "prs" and state.cursor then LIST_ID .. state.cursor else nil
	-- List rows are ~1.5 cells tall; ~22 cells go to the header, filters, toolbar, pager and dock.
	p.max = { lines = math.max(3, math.floor((state.cx.rows - 22) / 1.55)) }
	p.empty = { ui.span("No pull requests match this filter.", "muted") }
	list.p = p
	return list
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
		return nil
	end
	local now = os.time()
	local q = github.quota()
	local wait = github.wait(now)
	local line: string
	if wait > 0 then
		line = "Paused by GitHub rate limit until " .. os.date("%H:%M:%S", now + wait)
	elseif state.interval and state.nextAt and state.timer then
		line = "Auto-refresh: every " .. duration(state.interval / 1000) .. ", next " .. os.date("%H:%M:%S", state.nextAt)
	else
		return nil
	end
	if q and q.remaining and q.limit and q.reset and q.reset > now then
		line ..= " · search quota " .. q.remaining .. "/" .. q.limit .. ", resets " .. os.date("%H:%M:%S", q.reset)
	end
	return line
end

local function mainView(state: State): Node
	local kids: { Node } = {}
	local snap = state.snap
	local status: { Span | string } = { ui.span("GitHub PRs", "strong") }
	if snap then
		table.insert(status, ui.span("  " .. #snap.prs .. " shown", "muted"))
	end
	if state.loading then
		table.insert(status, ui.span("  refreshing…", "muted"))
	elseif snap then
		table.insert(status, ui.span("  updated " .. os.date("%H:%M", snap.fetched), "muted"))
	end
	table.insert(kids, ui.text(status))
	local pace = paceLine(state)
	if pace then
		table.insert(kids, ui.text({ ui.span(pace, "muted") }))
	end
	table.insert(kids, ui.node("text", { key = "context", text = state.launchCwd or "", role = "repo-context", tone = "muted" }))
	if not state.launchCwd then
		table.insert(kids, ui.text({ ui.span("No launch directory: worktrees need a local repository path.", "muted") }))
	end
	if state.storeError then
		table.insert(kids, ui.text({ ui.span(state.storeError, "error") }))
	end
	table.insert(kids, filtersList(state))
	local f = activeFilter(state)
	if f then
		table.insert(kids, ui.text({ ui.span("query ", "muted"), ui.span(f.query, "strong") }))
	end
	table.insert(kids, ui.row({
		badge("New", "new", "neutral", nil),
		badge("Edit", "edit", "neutral", nil),
		badge("Delete", "delete", "neutral", nil),
		badge("Refresh", "refresh", "accent", nil),
	}))

	local form = state.form
	if form then
		local fk: { Node } = { ui.rule(if form.id then "Edit filter" else "New filter") }
		for _, n in field("Name", "f-name", form.name, form.focus == "name", "My PRs") do
			table.insert(fk, n)
		end
		for _, n in field("Query", "f-query", form.query, form.focus == "query", "is:open author:@me") do
			table.insert(fk, n)
		end
		if form.error then
			table.insert(fk, ui.text({ ui.span(form.error, "error") }))
		end
		table.insert(fk, ui.row({ button(state, "Save", "save", "save"), button(state, "Cancel", "cancel", "cancel") }))
		for _, n in fk do
			table.insert(kids, n)
		end
	end
	if state.confirmDelete and f then
		table.insert(kids, ui.text({ ui.span("Delete filter “" .. f.name .. "”?  ", "warning") }))
		table.insert(kids, ui.row({ badge("Delete", "confirm-delete", "error", nil), badge("Keep", "cancel-delete", "neutral", nil) }))
	end
	local rf = state.repoForm
	if rf then
		table.insert(kids, ui.rule("Local checkout"))
		table.insert(kids, ui.md("No local checkout of **" .. rf.repo .. "** was found. Enter the path of one."))
		for _, n in field("Path", "f-path", rf.path, rf.focus == "path", "~/Code/" .. (string.match(rf.repo, "/(.+)$") or "repo")) do
			table.insert(kids, n)
		end
		if rf.error then
			table.insert(kids, ui.text({ ui.span(rf.error, "error") }))
		end
		table.insert(kids, ui.row({ button(state, if rf.busy then "Checking…" else "Save", "save", "save"), button(state, "Cancel", "cancel", "cancel") }))
	end
	if state.notice then
		table.insert(kids, ui.text({ ui.span(state.notice, "success") }))
	end

	local problem = state.problem
	if problem and not snap then
		table.insert(kids, problemCard(state, problem))
	elseif problem then
		table.insert(kids, ui.row({
			ui.badge("stale", "warning"),
			ui.text({ ui.span(problem.message .. "  showing the last complete list", "warning") }),
			badge("Retry", "retry", "accent", nil),
		}))
	end
	if snap then
		if not snap.complete then
			table.insert(kids, ui.text({
				ui.span("Partial results: " .. #snap.prs .. " loaded of " .. snap.total .. " matches. Narrow this filter.", "warning"),
			}))
		end
		table.insert(kids, prList(state, snap))
		if #snap.prs > PAGE_SIZE then
			local first = (state.page - 1) * PAGE_SIZE + 1
			local last = math.min(#snap.prs, first + PAGE_SIZE - 1)
			table.insert(kids, ui.row({
				badge("◀ Previous", "prev", "neutral", nil),
				ui.text({ ui.span(first .. "–" .. last .. " of " .. #snap.prs, "muted num") }),
				badge("Next ▶", "next", "neutral", nil),
			}))
		end
	elseif not problem and f then
		table.insert(kids, ui.progress(nil, "Loading pull requests…"))
	end
	return ui.col(kids)
end

local function dockView(state: State): Node
	local kids: { Node } = {}
	local pr = selectedPr(state)
	if pr then
		local word = stateWord(pr)
		table.insert(kids, ui.text({
			ui.span(word .. "  ", stateTone(word)),
			ui.span(pr.repo .. "#" .. pr.number .. "  ", "muted"),
			ui.span(pr.title, "strong"),
		}))
		local open = badge("Open PR", "open", "accent", "open-pr")
		local wt = badge("Worktree", "open", "neutral", "worktree")
		local po: { [string]: any } = open.p or {}
		po.href = prHref("open", pr)
		open.p = po
		local pw: { [string]: any } = wt.p or {}
		pw.href = prHref("worktree", pr)
		wt.p = pw
		table.insert(kids, open)
		table.insert(kids, wt)
	else
		table.insert(kids, ui.text({ ui.span("No pull request selected", "muted") }))
	end
	table.insert(kids, ui.text({ ui.span("tab switch list  ↑↓ move  r refresh", "dim") }))
	return ui.col(kids)
end

-- ---------------------------------------------------------------- block

local function modelFor(state: State, id: string): input.Model?
	if state.form then
		if id == FIELD_IDS.name then
			return state.form.name
		elseif id == FIELD_IDS.query then
			return state.form.query
		end
	end
	if state.repoForm and id == FIELD_IDS.path then
		return state.repoForm.path
	end
	return nil
end

local function focusedModel(state: State): input.Model?
	local name = if state.form then state.form.focus elseif state.repoForm then state.repoForm.focus else nil
	if name and FIELD_IDS[name] then
		return modelFor(state, FIELD_IDS[name])
	end
	return nil
end

tern.block.define("prs", {
	features = { "edit", "undo" },

	init = function(cx: BlockCx, args: { string }, saved: any): State
		local previous = running[cx.pane]
		if previous then
			retire(previous)
		end
		local cwd: string? = nil
		for _, c in { if type(saved) == "table" then saved.launchCwd else nil, args[1], cx.cwd } do
			if type(c) == "string" and c ~= "" and tern.fs.exists(c) then
				cwd = c
				break
			end
		end
		local store, writable, err = loadStore()
		local active = if type(saved) == "table" and type(saved.activeFilterId) == "string" then saved.activeFilterId else nil
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
			page = 1,
			focus = "prs",
			loading = false,
			gen = 0,
			repo = nil,
			resolving = false,
			cost = COST_GUESS,
			interval = nil,
			nextAt = nil,
			problem = nil,
			timer = nil,
			form = nil,
			confirmDelete = false,
			repoForm = nil,
			notice = nil,
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
		if snap then
			return "Plotroom · GitHub PRs (" .. #snap.prs .. ")"
		end
		return "Plotroom · GitHub PRs"
	end,

	view = function(state: State, _cx: BlockCx): BlockView
		return { main = mainView(state), dock = dockView(state) }
	end,

	key = function(state: State, key: Key, cx: BlockCx): boolean?
		if key.name == "tab" and not key.ctrl and not key.alt and not key.meta then
			cycle(state, key.shift)
			return true
		end
		if state.form or state.repoForm then
			local focus = if state.form then state.form.focus else (state.repoForm :: RepoForm).focus
			if key.name == "escape" then
				cancelForms(state)
			elseif key.name == "enter" then
				activate(state, if focus == "cancel" then "cancel" else "save")
			else
				local m = focusedModel(state)
				if not m or not input.key(m, key, function(t)
					cx:copy(t)
				end) then
					return false
				end
			end
			return true
		end
		if state.confirmDelete then
			if key.name == "enter" then
				deleteActive(state)
			elseif key.name == "escape" then
				state.confirmDelete = false
			else
				return false
			end
			return true
		end
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local k = key.text or key.name
		if state.focus == "filters" then
			if key.name == "up" then
				moveFilter(state, -1)
			elseif key.name == "down" then
				moveFilter(state, 1)
			elseif key.name == "home" then
				moveFilter(state, -1000)
			elseif key.name == "end" then
				moveFilter(state, 1000)
			elseif k ~= "r" then
				return false
			end
		else
			local i = indexOf(if state.snap then state.snap.prs else {}, state.cursor)
			local n = if state.snap then #state.snap.prs else 0
			if key.name == "up" or k == "k" then
				moveCursor(state, i - 1)
			elseif key.name == "down" or k == "j" then
				moveCursor(state, i + 1)
			elseif key.name == "page_up" then
				moveCursor(state, i - PAGE_SIZE)
			elseif key.name == "page_down" then
				moveCursor(state, i + PAGE_SIZE)
			elseif key.name == "home" then
				moveCursor(state, 1)
			elseif key.name == "end" then
				moveCursor(state, n)
			elseif k ~= "r" then
				return false
			end
		end
		if k == "r" then
			process.reset()
			refresh(state)
		end
		return true
	end,

	event = function(state: State, ev: UiEvent, cx: BlockCx)
		if not alive(state) then
			return
		end
		if ev.ev == "select" and ev.id == "main.filters" and type(ev.item) == "string" then
			state.focus = "filters"
			local id = string.sub(ev.item, #FILTERS_ID + 1)
			if id ~= state.activeId then
				switchFilter(state, id)
			end
		elseif ev.ev == "select" and ev.id == "main.prs" and type(ev.item) == "string" then
			state.focus = "prs"
			state.cursor = string.sub(ev.item, #LIST_ID + 1)
			ensureCursor(state)
		elseif ev.ev == "focus" and type(ev.id) == "string" then
			for name, id in FIELD_IDS do
				if id == ev.id then
					if state.form and name ~= "path" then
						state.form.focus = name
					elseif state.repoForm and name == "path" then
						state.repoForm.focus = name
					end
					focusField(state, name)
				end
			end
		elseif ev.ev == "edit" and type(ev.id) == "string" then
			local m = modelFor(state, ev.id)
			if m then
				input.edit(m, ev)
			end
		elseif ev.ev == "undo" and type(ev.id) == "string" then
			local m = modelFor(state, ev.id)
			if m then
				input.undo(m)
			end
		elseif ev.ev == "action" and type(ev.act) == "string" then
			local act = ev.act
			if act == "new" then
				openForm(state, false)
			elseif act == "edit" then
				openForm(state, true)
			elseif act == "delete" then
				if activeFilter(state) then
					state.form = nil
					state.confirmDelete = true
				end
			elseif act == "confirm-delete" then
				deleteActive(state)
			elseif act == "cancel-delete" then
				state.confirmDelete = false
			elseif act == "refresh" then
				state.notice = nil
				refresh(state)
			elseif act == "retry" then
				process.reset()
				refresh(state)
			elseif act == "prev" then
				goPage(state, state.page - 1)
			elseif act == "next" then
				goPage(state, state.page + 1)
			elseif act == "save" or act == "cancel" then
				activate(state, act)
			elseif act == "choose-repo" and type(ev.value) == "string" then
				state.form = nil
				state.confirmDelete = false
				state.notice = nil
				state.repoForm = { repo = ev.value, path = input.new(""), focus = "path", error = nil, busy = false }
				focusField(state, "path")
			end
		end
	end,

	save = function(state: State): any
		return { version = 1, launchCwd = state.launchCwd, activeFilterId = state.activeId }
	end,
})
