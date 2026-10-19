--!strict
-- Per-pane lifecycle, identity and refresh, triage, pins, the Worktrees board glue, navigation, details loading, worktree notes, the `me` and `ghActive` tables, CLI probing.

local board = require("../board")
local github = require("../github")
local input = require("../input")
local jira = require("../jira")
local process = require("../process")
local sorting = require("../sorting")
local tracker = require("../tracker")
local triage = require("../triage")
local worktree = require("../worktree")
local core = require("./core")
local storage = require("./storage")

local ui = tern.ui

type Attempt = core.Attempt
type Group = core.Group
type Note = core.Note
type Prompt = core.Prompt
type Report = core.Report
type Snap = core.Snap
type State = core.State
type View = core.View
type Visible = core.Visible

local DETAIL_DEBOUNCE_MS, DETAIL_RETRY_MAX_S, DETAIL_RETRY_S = core.DETAIL_DEBOUNCE_MS, core.DETAIL_RETRY_MAX_S, core.DETAIL_RETRY_S
local INTEGRATIONS, KINDS, NOTE_CAP, POLL_MS, TRACKERS = core.INTEGRATIONS, core.KINDS, core.NOTE_CAP, core.POLL_MS, core.TRACKERS
local clip, groupsOf, hrefOf, printable, running, cli = core.clip, core.groupsOf, core.hrefOf, core.printable, core.running, core.cli
local isTable, jiraReposOf, livePrompts, loadAll, loadPrompts, readCheckouts, formats =
	storage.isTable, storage.jiraReposOf, storage.livePrompts, storage.loadAll, storage.loadPrompts, storage.readCheckouts, storage.formats

local M = {}

-- gh's active login on this host once known (`login`), the logins signed in (`accounts`) and the helpers that use them:
-- the sidebar groups of views that run as one login.
local ghActive: {
	login: string?,
	accounts: { string },
	note: (State, boolean?) -> (),
	shown: (View) -> string,
	isActive: (State, Scope) -> boolean,
} = {
	login = nil,
	accounts = {},
	note = function() end,
	shown = function()
		return ""
	end,
	isActive = function()
		return false
	end,
}
M.ghActive = ghActive

-- Cancels the checks load waiting out its debounce or retry delay, if any.
function M.cancelDetails(state: State)
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
	M.cancelDetails(state)
	state.details, state.detailFail = {}, {}
end

function M.retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
	end
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	if state.boardTimer then
		state.boardTimer:cancel()
		state.boardTimer = nil
	end
	dropDetails(state)
	state.inflight = nil
	state.snap, state.vis = nil, nil
	state.snaps = {}
	state.problem = nil
	state.cursor, state.cursorAt = nil, nil
end

function M.alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	M.retire(state)
	return false
end

-- `M.alive(state)` as the stale guard callbacks take.
local function aliveFn(state: State): () -> boolean
	return function(): boolean
		return M.alive(state)
	end
end

-- Learns gh's active login (cached by github.accounts) and redraws when it changed, so views without a login of their own
-- sit under whichever account is active. Only views of GitHub ask (`always`: asked anyway), and never while gh is off.
function ghActive.note(state: State, always: boolean?)
	local any = always == true and cli.on("github")
	for _, v in state.views do
		any = any or v.integration == "github"
	end
	if not any then
		return
	end
	github.accounts(function(list)
		local found: string? = nil
		local names: { string } = {}
		if list then
			for _, a in list do
				table.insert(names, a.login)
				if a.active then
					found = a.login
				end
			end
		end
		local known = table.concat(ghActive.accounts, ",")
		if list then
			ghActive.accounts = names
		end
		if (found and found ~= ghActive.login) or (list ~= nil and known ~= table.concat(names, ",")) then
			ghActive.login = found or ghActive.login
			if M.alive(state) then
				state.cx:render()
			end
		end
	end)
end

function M.activeView(state: State): View?
	for _, pin in state.pins do
		if pin.id == state.activeId and cli.ready() and cli.on(pin.integration) then
			return pin
		end
	end
	for _, v in state.views do
		if v.id == state.activeId then
			return v
		end
	end
	return nil
end

-- The gh login view `v` runs as in the scope that picked `login` (nil, or one it does not list: its first): "" is gh's
-- active account. Jira has none.
function M.accountOf(v: View, login: string?): string
	if v.integration ~= "github" or #v.logins == 0 then
		return ""
	end
	if login then
		for _, who in v.logins do
			if string.lower(who) == string.lower(login) then
				return who
			end
		end
	end
	return v.logins[1]
end

-- The logins a view's summary in Settings names: its own, in the order saved; else gh's active one ("" while that is
-- unknown, and for Jira, which has none).
function ghActive.shown(v: View): string
	if v.integration ~= "github" then
		return ""
	end
	return if #v.logins > 0 then table.concat(v.logins, ", ") else (ghActive.login or "")
end

-- One row of the sidebar: a view as one login runs it. A view that lists several logins is one scope under each login's
-- group (`login` is that login, the scope's id "<view id>@<login>"); any other view is one scope, under its login's
-- group or, with none, under gh's active one. `shown` is the login its group names ("" for Jira, or while unknown).
type Scope = { id: string, view: View, login: string?, shown: string }

-- The scopes as the sidebar lists them: the pinned pull request first (while gh is on), as gh's active login runs it;
-- then, by integration, each one's views within the group of the login they run as (pull request views, then issue
-- views, each in store order); groups by login, sorted by name.
function M.orderedViews(state: State): { Scope }
	local out: { Scope } = {}
	for _, pin in state.pins do
		if cli.ready() and cli.on(pin.integration) then
			table.insert(out, { id = pin.id, view = pin, login = nil, shown = if pin.integration == "github" then ghActive.login or "" else "" })
		end
	end
	for _, id in { "github", "jira" } do
		local keys: { string } = {}
		local groups: { [string]: { Scope } } = {}
		for _, v in state.views do
			if v.integration ~= id then
				continue
			end
			local runs: { string } = if #v.logins > 0 and id == "github" then v.logins else { "" }
			for _, who in runs do
				local shown = if who ~= "" then who elseif id == "github" then (ghActive.login or "") else ""
				local key = string.lower(shown)
				if not groups[key] then
					groups[key] = {}
					table.insert(keys, key)
				end
				table.insert(groups[key], {
					id = if #v.logins > 1 then v.id .. "@" .. who else v.id,
					view = v,
					login = if who ~= "" then who else nil,
					shown = shown,
				})
			end
		end
		table.sort(keys)
		for _, key in keys do
			for _, scope in groups[key] do
				table.insert(out, scope)
			end
		end
	end
	return out
end

-- Whether `scope` is the one the block shows: its view, and for a view of several logins its login.
function ghActive.isActive(state: State, scope: Scope): boolean
	if scope.view.id ~= state.activeId then
		return false
	end
	return #scope.view.logins <= 1 or string.lower(scope.login or "") == string.lower(M.accountOf(scope.view, state.activeLogin))
end

function M.indexOf(items: { any }, key: string?): number
	for i, item in items do
		if item.key == key then
			return i
		end
	end
	return 0
end

-- The item under the cursor, a github.Pr (prs) or a tracker.Issue (issues); nil when there is none.
function M.selected(state: State): any
	local snap = state.snap
	if snap then
		return snap.items[M.indexOf(snap.items, state.cursor)]
	end
	return nil
end

-- Keys ("owner/repo#n", "abc#ABC-12") of the items whose worktree (as its note has it) holds some pane's cwd on this host.
function M.openItems(state: State): { [string]: boolean }
	local open: { [string]: boolean } = {}
	local mine: { [string]: string } = {}
	for key, note in state.notes do
		if note.ok and note.path then
			mine[key] = note.path
		end
	end
	if next(mine) == nil then
		return open
	end
	for _, p in tern.pane.list() do
		local cwd = p.cwd
		if cwd then
			for key, path in mine do
				if worktree.within(cwd, path) then
					open[key] = true
				end
			end
		end
	end
	return open
end

-- `raw` as a GitHub "owner/name" (both parts valid worktree segments, trimmed); nil when it is not one.
function M.parseRepo(raw: any): string?
	local owner, name = string.match(if type(raw) == "string" then input.trim(raw) else "", "^([^/]+)/([^/]+)$")
	if owner and name and worktree.validSegment(owner) and worktree.validSegment(name) then
		return owner .. "/" .. name
	end
	return nil
end

-- Picker ids hold no `/` or `#`: the item's key ("owner/repo#n", or "abc#ABC-12") with every other character spelled
-- `_xx`, `_` included, so two keys never share one.
function M.itemId(item: any): string
	return "n" .. (string.gsub(item.key, "[^%w%-]", function(c: string): string
		return string.format("_%02x", string.byte(c))
	end))
end

function M.itemOf(state: State, id: string): any
	local snap = state.snap
	if snap then
		for _, item in snap.items do
			if M.itemId(item) == id then
				return item
			end
		end
	end
	return nil
end

-- Whether `item` matches the search text, and the matched UTF-16 range in its title (nil when elsewhere or blank).
local function matchItem(kind: string, item: any, text: string): (boolean, { number }?)
	if kind == "issues" then
		return tracker.match(item, text)
	end
	return github.match(item, text)
end

-- The seen / snooze store (kv "triage"), read once and kept until a change (`M.triageChanged`) or `again`; nil while its kv
-- is unreadable or malformed (`triageProblem` says why), and nothing writes it then. Seen is marked by `M.mark` (the
-- Mark seen action) and by `M.autoSeen` (an item whose preview is open, unless the attention filter chose it itself).
function M.store(state: State, again: boolean?): any
	if again then
		state.triage, state.triageProblem = nil, nil
	end
	if state.triage == nil and state.triageProblem == nil then
		local store, why = triage.load()
		state.triage, state.triageProblem = store, why
	end
	return state.triage
end

-- Where `item` stands in the triage store (nil without a readable store).
function M.status(state: State, kind: string, item: any): any
	local store = M.store(state)
	return if store then triage.status(store, kind, item, os.time()) else nil
end

-- Whether `item` needs attention: unseen or changed (and not snoozed), or its agent waits for input. An idle or exited
-- agent is neither: it says nothing about the item being dealt with.
function M.needs(state: State, kind: string, item: any): boolean
	local agent = state.agents[item.key]
	local st = M.status(state, kind, item)
	if st then
		return triage.attention(st, agent)
	end
	return agent == "waiting_input"
end

-- Whether the list shows `item`: with the attention filter only what needs it; else everything except snoozed items
-- (unless shown), though an agent that waits for input always surfaces its item.
function M.keep(state: State, kind: string, item: any): boolean
	local shown = M.activeView(state)
	if shown and M.isPin(shown.id) then
		return true -- the one item shown on its own is never filtered out
	end
	if state.attention then
		-- The item being read stays listed, though reading it marked it seen: it goes when the selection moves or closes.
		return item.key == state.cursor or M.needs(state, kind, item)
	end
	if state.showSnoozed or state.agents[item.key] == "waiting_input" then
		return true
	end
	local st = M.status(state, kind, item)
	return not (st and st.snoozed)
end

-- How many of `snap`'s items a sidebar scope counts: those its list shows, so snoozed ones are left out (unless shown).
-- ponytail: ignores the attention filter, which depends on the open selection; count it too if asked.
function M.listedCount(state: State, snap: Snap, pinned: boolean): number
	if pinned or state.showSnoozed then
		return #snap.items
	end
	local n = 0
	for _, item in snap.items do
		local st = M.status(state, snap.kind, item)
		if state.agents[item.key] == "waiting_input" or not (st and st.snoozed) then
			n += 1
		end
	end
	return n
end

-- The items the local search lets through, in snapshot order, with their picker ids and title hits. Recomputed only when
-- the snapshot or the search text changes.
function M.filtered(state: State): Visible?
	local snap = state.snap
	if not snap then
		return nil
	end
	local text = if state.query then state.query.text else ""
	local view = M.activeView(state)
	local group = if view then view.group else "none"
	local cached = state.vis
	if cached and cached.snap == snap and cached.needle == text and cached.group == group and cached.rev == state.rev then
		return cached
	end
	local spec: Group? = nil
	if view then
		for _, g in groupsOf(snap.kind, view.integration) do
			if g.value == group then
				spec = g
			end
		end
	end
	local kept: { any } = {}
	local hits: { [string]: any } = {}
	local hasHits = false
	local blank = input.trim(text) == ""
	for _, item in snap.items do
		local ok = true
		local range: { number }? = nil
		if not blank then
			ok, range = matchItem(snap.kind, item, text)
		end
		if ok and not M.keep(state, snap.kind, item) then
			ok = false
		end
		if ok then
			table.insert(kept, item)
			if range then
				hits[M.itemId(item)] = { range }
				hasHits = true
			end
		end
	end
	local sorted: { any } = if view and view.sort then sorting.apply(kept, view.sort) else kept
	if not spec then
		kept = sorted
	end
	local items: { any } = {}
	local order: { any } = {}
	if spec then
		-- Headers of the groups, in label order, each followed by its items; navigation walks `items`, so a header is never selected.
		local buckets: { [string]: { any } } = {}
		local labels: { string } = {}
		for _, item in kept do
			local label = spec.of(item)
			if not buckets[label] then
				buckets[label] = {}
				table.insert(labels, label)
			end
		end
		-- A sort orders the items of a group; the groups keep the order of the list they came in.
		local source: { any } = if view and view.sort then sorted else kept
		for _, item in source do
			table.insert(buckets[spec.of(item)], item)
		end
		if not spec.keep then
			table.sort(labels, function(a: string, b: string): boolean
				local x, y = string.lower(a), string.lower(b)
				if x ~= y then
					return x < y
				end
				return a < b
			end)
		end
		for _, label in labels do
			local bucket = buckets[label]
			table.insert(order, { group = label, label = label, count = #bucket })
			for _, item in bucket do
				table.insert(items, item)
				table.insert(order, M.itemId(item))
			end
		end
	else
		for _, item in kept do
			table.insert(items, item)
			table.insert(order, M.itemId(item))
		end
	end
	local out: Visible = { snap = snap, needle = text, group = group, rev = state.rev, items = items, order = tern.json.array(order), hits = if hasHits then hits else nil }
	state.vis = out
	return out
end

-- Moves the selection to `key` (nil: none). With the attention filter the list holds the selected item, so it is rebuilt.
function M.select(state: State, key: string?)
	if state.cursor ~= key then
		state.cursor = key
		if state.attention then
			state.vis = nil
		end
	end
	local v = if key then M.filtered(state) else nil
	state.cursorAt = if v then M.indexOf(v.items, key) else state.cursorAt
end

-- Keeps the selection on a listed item, so a nonempty list always has its preview open: the first item when nothing is
-- selected, the row that took the place of one that vanished (a refresh, a search, a snooze). An empty list selects
-- nothing. Under the attention filter the selected row stays listed though reading it marks it seen (M.keep), so a pick
-- is read once and the next row is not picked until the selection moves.
function M.ensureCursor(state: State)
	if not state.snap then
		return
	end
	local v = M.filtered(state)
	local items: { any } = if v then v.items else {}
	local at = M.indexOf(items, state.cursor)
	if at > 0 then
		state.cursorAt = at
		return
	end
	local pick = items[math.clamp(state.cursorAt or 1, 1, math.max(#items, 1))]
	M.select(state, if pick then pick.key else nil)
end

-- The saved state changed (here or in another block): every block rereads it and shows the new list, its cursor on a
-- row that is still listed.
function M.triageChanged(state: State)
	for _, s in running do
		s.triage, s.triageProblem = nil, nil
		s.rev += 1
		s.vis = nil
		if M.alive(s) then
			if s.snap then
				M.ensureCursor(s)
			end
			if s ~= state then
				s.cx:render()
			end
		end
	end
end

-- `act` ("seen" | "snooze" | "unsnooze") on the selected item, saved to the triage store at once (the store is reread
-- first and never overwritten when unreadable). The cursor moves to the neighbour when the item leaves the list.
function M.mark(state: State, act: string)
	local item, snap = M.selected(state), state.snap
	if not item or not snap then
		return
	end
	local store = M.store(state, true)
	if not store then
		return state.cx:toast("error", "Not saved", state.triageProblem or "The saved triage state could not be read.")
	end
	local now = os.time()
	local until_ = triage.tomorrow(now)
	if act == "seen" then
		triage.markSeen(store, snap.kind, item, now)
	elseif act == "snooze" then
		local st = triage.status(store, snap.kind, item, now)
		if st.snoozed then
			act = "unsnooze" -- snoozing a snoozed item ends the snooze
			triage.unsnooze(store, item.key)
		else
			triage.snooze(store, snap.kind, item, until_, now)
		end
	elseif act == "unsnooze" then
		triage.unsnooze(store, item.key)
	else
		return
	end
	local err = triage.save(store)
	if err then
		state.triage, state.triageProblem = nil, nil
		return state.cx:toast("error", "Not saved", err)
	end
	M.triageChanged(state) -- an item that left the list hands the selection to the row that took its place (ensureCursor)
	state.cx:toast("success", if act == "seen" then "Marked seen" elseif act == "snooze" then "Snoozed until " .. os.date("%a %H:%M", until_) else "Snooze ended", item.key)
end

-- The selected item is marked seen as its preview is shown, with the data it shows now: a later refresh that changes it
-- marks it again while it stays shown. Never on a background fetch or the list's Worktrees.
function M.autoSeen(state: State)
	local item, snap = M.selected(state), state.snap
	if not item or not snap or state.boardOn then
		return
	end
	local st = M.status(state, snap.kind, item)
	if not st or st.fresh == "seen" then
		return
	end
	local sig = item.key .. "\0" .. triage.signature(snap.kind, item)
	if state.seenTried == sig then
		return
	end
	state.seenTried = sig
	local store = M.store(state, true)
	if not store then
		return -- unreadable: nothing is written over it (the header says why)
	end
	triage.markSeen(store, snap.kind, item, os.time())
	local err = triage.save(store)
	if err then
		state.triage, state.triageProblem = nil, nil
		return state.cx:toast("error", "Not saved", err)
	end
	M.triageChanged(state)
end

-- Turns the snoozed items' listing ("snoozed") or the needs-attention filter ("attention") on or off.
function M.toggle(state: State, what: string)
	if what == "snoozed" then
		state.showSnoozed = not state.showSnoozed
	elseif what == "attention" then
		state.attention = not state.attention
	else
		return
	end
	state.rev += 1
	state.vis = nil
	M.ensureCursor(state)
end

-- The gh login the active scope runs as (nil: the active gh account), for github.wait and quota and every gh call.
function M.login(state: State): string?
	local v = M.activeView(state)
	local who = if v then M.accountOf(v, state.activeLogin) else ""
	return if who ~= "" then who else nil
end

-- The active view's integration: what a search, wait or heading of the block belongs to.
function M.trackerOf(state: State): string
	local v = M.activeView(state)
	return if v then v.integration else state.kind.integrations[1]
end

-- Seconds every pane must still wait before a search of this block's tracker: only GitHub has a shared quota.
function M.waitOf(state: State): number
	return if M.trackerOf(state) == "github" then github.wait(os.time(), M.login(state)) else 0
end

-- Cache key of a snapshot: what it lists, integration, the gh login the scope runs as and query.
function M.snapKey(v: View, login: string?): string
	return v.kind .. "\0" .. v.integration .. "\0" .. string.lower(M.accountOf(v, login)) .. "\0" .. v.query
end

-- Cache key of an item's loaded details (a PR's checks, an issue's body); the login is part of it, so one identity
-- never sees another's.
function M.detailKey(state: State, item: any): string
	return state.account .. "\0" .. item.key .. "@" .. item.updated
end

-- Drops everything shown, cached or running under the previous gh identity.
local function forget(state: State)
	state.gen += 1
	state.snaps, state.snap, state.vis, state.problem = {}, nil, nil, nil
	dropDetails(state)
end

-- `state.account`, `state.tracker` and `state.kind` are the identity everything on screen and in flight belongs to: the
-- active view's gh login, integration and kind. A different one drops all data and problems of the old one.
local function identify(state: State)
	local v = M.activeView(state)
	local account = if v then M.accountOf(v, state.activeLogin) else ""
	local integration = if v then v.integration else state.kind.integrations[1]
	local kind = if v then KINDS[v.kind] else state.kind
	if account ~= state.account or integration ~= state.tracker or kind ~= state.kind then
		state.account, state.tracker, state.kind = account, integration, kind
		forget(state)
	end
end

-- Shows the cached snapshot of the active scope.
local function showSnapshot(state: State)
	identify(state)
	local v = M.activeView(state)
	state.applied = if v then M.snapKey(v, state.activeLogin) else nil
	state.snap = if v then state.snaps[M.snapKey(v, state.activeLogin)] else nil
	M.ensureCursor(state)
end

-- Problems that retrying cannot fix by itself: no automatic refresh until an explicit Retry. "invalid" belongs to one
-- query, "not-found" to a repository or project the login cannot see (each tracker's classifier reports it).
local TERMINAL: { [string]: boolean } = { auth = true, missing = true, ["not-found"] = true, invalid = true }
M.TERMINAL = TERMINAL

local HEADS: { [string]: string } = {
	missing = "GitHub CLI not found",
	auth = "GitHub CLI not signed in",
	["rate-limit"] = "GitHub rate limit",
	["not-found"] = "Repository not visible",
	invalid = "GitHub rejected the search",
}
local HELP: { [string]: string } = {
	missing = "Install the GitHub CLI (cli.github.com) so it is on your shell's PATH, then Refresh.",
	auth = "Run gh auth login in a terminal, then Refresh.",
	["rate-limit"] = "Searches resume automatically when GitHub's limit resets.",
	["not-found"] = "Check this view's GitHub login in Settings › Views, then Refresh.",
	invalid = "Check the view's query and login in Settings › Views, then Refresh.",
}
local JIRA_HEADS: { [string]: string } = {
	missing = "Atlassian CLI not found",
	auth = "Atlassian CLI not signed in",
	["rate-limit"] = "Jira rate limit",
	["not-found"] = "Project not visible",
	invalid = "Jira rejected the search",
}
local JIRA_HELP: { [string]: string } = {
	missing = "Install Atlassian's CLI (acli) so it is on your shell's PATH, then Refresh.",
	auth = "Run acli jira auth login in a terminal, then Refresh.",
	["rate-limit"] = "Searches resume at the next refresh.",
	["not-found"] = "Check the view's JQL in Settings › Views, then Refresh.",
	invalid = "Check the view's JQL in Settings › Views, then Refresh.",
}

-- The heading of problem kind `k`, nil when it has none; a failed load names what it was loading.
function M.headOf(state: State, k: string): string?
	if k == "failed" then
		return "Could not load " .. state.kind.many
	end
	return if M.trackerOf(state) == "jira" then JIRA_HEADS[k] else HEADS[k]
end

-- What to do about problem kind `k`, nil when there is no advice.
function M.helpOf(state: State, k: string): string?
	return if M.trackerOf(state) == "jira" then JIRA_HELP[k] else HELP[k]
end

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
	ms = math.max(ms, M.waitOf(state) * 1000)
	state.nextAt = os.time() + math.ceil(ms / 1000)
	state.timer = tern.timer(ms, function()
		if not M.alive(state) then
			return
		end
		state.timer = nil
		M.refresh(state)
		state.cx:render()
	end)
end

-- Checks, failures and folds of PRs that no cached snapshot lists any more (or lists with a newer update) cannot be shown again.
local function prune(state: State)
	local keep: { [string]: boolean } = {}
	for _, snap in state.snaps do
		for _, item in snap.items do
			keep[M.detailKey(state, item)] = true
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
end

-- The item key (as the lists key it: lowercase "owner/repo#n", Jira "abc#ABC-12") of the pin named `name` of `integration`.
local function keyOf(name: string, integration: string): string
	local project = string.match(name, "^([^%-]+)%-%d+$")
	return if integration == "jira" and project then string.lower(project) .. "#" .. name else string.lower(name)
end

-- The item key of pin `v`.
function M.pinKey(v: View): string
	return keyOf(v.name, v.integration)
end

M.PIN_CAP = 20 -- pins kept and saved; a pin past it is refused with a toast, never dropped silently

-- Whether view id `id` is a pin's ("pin:<item key>").
function M.isPin(id: string?): boolean
	return id ~= nil and string.sub(id, 1, 4) == "pin:"
end

-- The pin for item `key` in `pins`, nil when there is none.
function M.pinFor(pins: { View }, key: string): View?
	for _, p in pins do
		if M.pinKey(p) == key then
			return p
		end
	end
	return nil
end

-- The pinned scope of the item at `url` (untrusted: anything but a github.com pull request or issue URL or a Jira
-- issue URL is nil): a view of one item, apart from the saved views. Its name is "owner/name#N" or the Jira key, and
-- its id is made from the item's key so each item has one.
function M.pinView(url: any): View?
	if type(url) ~= "string" then
		return nil
	end
	local function pin(name: string, integration: string, kind: string, query: string): View
		return { id = "pin:" .. keyOf(name, integration), kind = kind, name = name, integration = integration, query = query, logins = {}, group = "none", prompts = {} }
	end
	local item = github.parseItemUrl(url)
	if item then
		local pr = item.kind == "pr"
		return pin(item.repo .. "#" .. item.number, "github", if pr then "prs" else "issues", "https://github.com/" .. item.repo .. (if pr then "/pull/" else "/issues/") .. item.number)
	end
	local key = jira.parseUrl(url)
	return if key then pin(key, "jira", "issues", url) else nil
end

-- Loads the one item of pin `v` as a search would (`landed` takes a SearchResult or IssueResult). It runs as gh's active
-- login, as a pin always has; a Jira URL must belong to the site acli is signed in to (jira.keyOfUrl).
-- ponytail: the pin runs as gh's active login; pass the issue view's login along if a private repository needs another.
function M.fetchPin(state: State, v: View, live: () -> boolean, landed: (any, github.Problem?, number) -> ())
	-- Whatever the lookup answers, the pin lists only the item its URL names: nothing else is ever shown under it.
	local want = M.pinKey(v)
	if v.kind == "prs" then
		return github.pull(nil, v.query, live, function(result: any, problem: github.Problem?, spent: number)
			if result then
				local only: { any } = {}
				for _, pr in result.prs do
					if pr.key == want then
						table.insert(only, pr)
					end
				end
				result = { prs = only, total = #only, complete = true }
			end
			landed(result, problem, spent)
		end)
	end
	local function one(issue: tracker.Issue?, problem: github.Problem?)
		if issue and issue.key == want then
			landed({ issues = { issue }, total = 1, complete = true }, nil, 0)
		elseif issue then
			landed({ issues = {}, total = 0, complete = true }, nil, 0)
		else
			landed(nil, problem or { kind = "failed", message = "That item could not be loaded." }, 0)
		end
	end
	if v.integration == "github" then
		local item = github.parseItemUrl(v.query)
		if not item or item.kind ~= "issue" then
			return landed(nil, { kind = "invalid", message = "That is not a GitHub issue URL." }, 0)
		end
		github.issueItem(item.repo, item.number, nil, one, live)
	else
		jira.keyOfUrl(v.query, function(key: string?, problem: github.Problem?)
			if not key then
				return one(nil, problem)
			end
			jira.item(key, one, live)
		end)
	end
end

function M.refresh(state: State)
	if not M.alive(state) then
		return
	end
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	identify(state)
	local halted = state.problem
	if halted and TERMINAL[halted.kind] then
		return
	end
	if state.inflight == state.gen then
		return -- the request for the current query is already running
	end
	local v = M.activeView(state)
	if not v then
		state.problem = nil
		return
	end
	-- The server's cooldown holds for every trigger, manual refresh included.
	local wait = M.waitOf(state)
	if wait > 0 then
		-- Nothing is loading: say why, so an uncached view does not show a spinner until the reset.
		state.problem = { kind = "rate-limit", message = "GitHub's rate limit is reached; searches resume at " .. os.date("%H:%M:%S", os.time() + wait) .. "." }
		return schedule(state, wait * 1000)
	end
	local gen, query, integration = state.gen, v.query, v.integration
	local key = M.snapKey(v, state.activeLogin)
	state.inflight = gen
	local function current(): boolean
		return running[state.cx.pane] == state and state.gen == gen
	end
	local kind = v.kind -- what this request lists, whichever view is active when it lands
	local issues = kind == "issues"
	-- `result` is a github.SearchResult (prs) or a tracker.IssueResult (issues).
	local function landed(result: any, problem: github.Problem?, spent: number)
		if not M.alive(state) then
			return
		end
		if state.inflight == gen then
			state.inflight = nil
		end
		if state.gen ~= gen or (problem and problem.kind == "superseded") then
			-- The query or the login changed meanwhile and its own request is running or paused: only the spent quota counts.
			if spent > 0 then
				state.cost = math.max(spent, state.cost)
			end
			state.cx:render()
			return
		end
		if result then
			if issues then
				tracker.byStatus(result.issues)
			end
			local snap: Snap = { kind = kind, items = if issues then result.issues else result.prs, total = result.total, complete = result.complete, fetched = os.time() }
			state.snaps[key] = snap
			state.snap = snap
			state.round += 1 -- every loaded checks list is older than this result now
			state.problem = nil
			M.ensureCursor(state)
			prune(state)
			if integration == "github" then
				-- Warms the repository picker's list of gh logins (window.luau's pickRepo), so it opens without waiting on gh.
				ghActive.note(state)
			end
		else
			state.problem = problem
		end
		if spent > 0 then
			-- A finished snapshot shows the real points cost; a failed one keeps the larger known cost.
			state.cost = if result then spent else math.max(spent, state.cost)
			state.interval = github.interval(github.quota(M.login(state)), os.time(), state.cost, openPanes(), POLL_MS)
		elseif result and integration == "jira" then
			state.interval = POLL_MS -- Jira has no quota to pace: the plain minute
		else
			state.interval = nil -- nothing was sent (invalid query): no quota to pace
		end
		if not (problem and TERMINAL[problem.kind]) then
			schedule(state, state.interval or POLL_MS)
		end
		state.cx:render()
	end
	if M.isPin(v.id) then
		M.fetchPin(state, v, current, landed) -- the pin's query is its item's URL
	elseif issues then
		TRACKERS[integration].search(M.login(state), query, current, landed)
	else
		github.search(M.login(state), query, current, landed)
	end
end

-- A different applied query or login: invalidate whatever is in flight and reload now. A rejected query (HTTP 422)
-- belonged to the old query; the other pauses are about the environment and stay.
function M.changed(state: State)
	state.gen += 1
	local p = state.problem
	if p and (p.kind == "invalid" or not TERMINAL[p.kind]) then
		state.problem = nil
	end
	showSnapshot(state)
	M.refresh(state)
end

-- Explicit user retry (`r`, Refresh, Retry): also asks again which CLIs start (one installed or removed meanwhile turns
-- its integration on or off once answered), forgets Jira's site and retries failed checks loads. The search it starts
-- makes the loaded checks stale (State.round): the selected PR's load again once it lands.
function M.retry(state: State)
	process.reset()
	jira.reset()
	M.probeClis(true)
	local p = state.problem
	if p and TERMINAL[p.kind] then
		state.problem = nil
	end
	state.detailFail = {}
	M.cancelDetails(state)
	if state.inflight == state.gen then
		local v = M.activeView(state)
		state.cx:toast("info", "Already refreshing", if v then v.name else nil)
	end
	M.refresh(state)
end

function M.switchView(state: State, id: string?, activeLogin: string?)
	state.activeId, state.activeLogin, state.boardOn = id, activeLogin, false
	state.cursor, state.cursorAt = nil, nil -- another view opens on its first item (ensureCursor)
	identify(state)
	local v = M.activeView(state)
	local cached = if v then state.snaps[M.snapKey(v, state.activeLogin)] else nil
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
		M.changed(state)
	end
end

-- After another block wrote the views, on restore or once the CLIs answered: reread storage; what is shown must match
-- it: the kind, integration, query and login of the active view are what the block remembers it applied (its snapshot
-- key). Until every CLI answered, an active view that is not listed yet stays the active one.
function M.reloadViews(state: State)
	local boardOn = state.boardOn -- switchView leaves the Worktrees scope
	loadAll(state)
	local v = M.activeView(state)
	if not v then
		if cli.ready() then
			M.switchView(state, if state.views[1] then state.views[1].id else nil)
			state.boardOn = boardOn
		end
	elseif M.snapKey(v, state.activeLogin) ~= state.applied then
		M.changed(state)
	end
end

-- Every other live block of this runtime follows a change made in `origin`. Closed panes are retired, not rendered.
function M.propagate(origin: State)
	for _, s in running do
		if s ~= origin and M.alive(s) then
			M.reloadViews(s)
			s.cx:render()
		end
	end
end

-- The Worktrees scope of the sidebar lists every worktree of every saved checkout, whatever the shown view and its query
-- are: where the open ones are, their branch and folder, the item each was made for, whether a tab works in it and,
-- on request, its uncommitted changes and whether its pull request or issue is closed (a cleanup candidate). Each is
-- removed on its own, never forced. The model is board.luau's; git is read only on this host.

function M.boardRows(state: State): { any }
	return board.rows(state.board, { showMain = true })
end

-- The picker id of a row: no `/` or `#`, as an item's.
function M.boardId(row: any): string
	return "w" .. (string.gsub(row.id, "[^%w%-]", function(c: string): string
		return string.format("_%02x", string.byte(c))
	end))
end

-- The row previewed (board.selected) and its place in the list (nil, 0 when there is none).
function M.boardSelected(state: State): (any, number)
	for i, row in M.boardRows(state) do
		if row.id == state.board.selected then
			return row, i
		end
	end
	return nil, 0
end

-- Keeps the preview on a listed worktree while the list is shown: the first when none is previewed, the row that took the
-- place of one that vanished (a removal, a reload). An empty list previews nothing.
function M.boardEnsure(state: State)
	if not state.boardOn then
		return
	end
	local rows = M.boardRows(state)
	local _, at = M.boardSelected(state)
	if at > 0 then
		state.boardAt = at
	elseif #rows > 0 then
		M.boardPick(state, rows[math.clamp(state.boardAt or 1, 1, #rows)])
	elseif state.board.selected then
		board.close(state.board)
	end
end

-- The backend the board model calls: git on this host only. `dirty` reads one folder, and only one the latest inventory listed.
function M.boardApi(state: State): any
	return {
		inventory = worktree.inventory,
		inventoryDirty = worktree.inventoryDirty,
		removeEntry = worktree.removeEntry,
		dirty = function(path: string, done: (boolean?, string?) -> ())
			for _, r in state.board.rows do
				if r.path == path then
					return worktree.dirty(path, function(dirty: boolean?)
						done(dirty, if dirty == nil then "git status could not tell" else nil)
					end)
				end
			end
			done(nil, "That folder is not a listed worktree.")
		end,
	}
end

-- The pieces of the issue key a board row was noted for. A worktree is noted by its issue's ref ("12", "ABC-1"); a key
-- "owner/repo#12" names its repository itself. Returns the GitHub issue number (nil when the ref is not a plain one), the
-- repository it is in (the key's, else `rowRepo`) and the ref.
local function parseIssueRef(key: string, rowRepo: string): (number?, string, string)
	local owner, tail = string.match(key, "^(.+)#([%w_%-]+)$")
	local ref: string = tail or key
	local n = tonumber(ref)
	return (if n and tostring(n) == ref then n else nil), (if owner and string.find(owner, "/", 1, true) then owner else rowRepo), ref
end

-- Reads the issue a worktree was noted for (`key` as parseIssueRef takes it): GitHub's by number, Jira's by key. done(issue,
-- problem, number, repo, ref): `number` is set for a GitHub issue; no issue and no problem for a key that is neither.
local function readNoted(key: string, rowRepo: string, live: () -> boolean, done: (tracker.Issue?, github.Problem?, number?, string, string) -> ())
	local n, repo, ref = parseIssueRef(key, rowRepo)
	if n then
		github.issueItem(repo, n, nil, function(issue, problem)
			done(issue, problem, n, repo, ref)
		end, live)
	elseif string.match(ref, "^%u[%u%d_]*%-%d+$") then
		jira.item(ref, function(issue, problem)
			done(issue, problem, nil, repo, ref)
		end, live)
	else
		done(nil, nil, nil, repo, ref)
	end
end

-- How the preview reads the pull request and the issue a worktree was made for (the model decides which to ask). The
-- first read after a pick waits for the cursor to rest. A description or a linked item that cannot be read leaves the
-- rest of the answer as it is; `related` is only what the tracker itself links within the same repository.
function M.boardLinks(state: State): any
	local live = aliveFn(state)
	local function later(row: any, run: () -> ())
		if state.boardWait then
			state.boardWait = false
			tern.timer(DETAIL_DEBOUNCE_MS, function()
				if M.alive(state) and state.board.selected == row.id then
					run()
				end
			end)
		else
			run()
		end
	end
	return {
		pr = function(row: any, number: number, done: (any, string?) -> ())
			later(row, function()
				github.pull(nil, "https://github.com/" .. row.repo .. "/pull/" .. number, live, function(result: any, problem: github.Problem?)
					local pr = if result and result.prs then result.prs[1] else nil
					if not pr then
						return done(nil, if problem then problem.message else nil)
					end
					local info: { [string]: any } = { ref = "#" .. number, title = pr.title, state = if pr.draft then "draft" else pr.state, person = "@" .. pr.author, url = pr.url, tracker = "github " .. row.repo }
					-- The description comes with the checks read.
					github.checks(row.repo, number, nil, function(_runs: any, _total: number, _problem: any, about: github.About?)
						if about and string.find(about.body, "%S") then
							info.excerpt = about.body
						end
						done(info, nil)
					end, live)
				end)
			end)
		end,
		issue = function(row: any, key: string, done: (any, string?) -> ())
			local function base(issue: tracker.Issue, where: string, label: string): { [string]: any }
				local who = issue.assignees[1]
				return {
					ref = label,
					title = issue.title,
					state = if issue.status then issue.status.text else issue.state,
					person = if who then (if issue.tracker == "github" then "@" else "") .. who else nil,
					url = issue.url,
					tracker = where,
				}
			end
			later(row, function()
				readNoted(key, row.repo, live, function(issue: tracker.Issue?, problem: github.Problem?, n: number?, repo: string, ref: string)
					if not issue then
						return done(nil, if problem then problem.message else nil)
					end
					if n then
						local info = base(issue, "github " .. repo, "#" .. n)
						github.issue(repo, n, nil, function(detail: tracker.IssueDetail?)
							if detail then
								if string.find(detail.body, "%S") then
									info.excerpt = detail.body
								end
								for _, l in detail.linked do
									local o, r, num = github.parsePrUrl(l.url)
									if o and r and num and string.lower(o .. "/" .. r) == string.lower(repo) then
										info.related = { number = num }
										break
									end
								end
							end
							done(info, nil)
						end, live)
					else
						local info = base(issue, "jira " .. (string.match(ref, "^(.-)%-%d+$") or ref), ref)
						jira.issue(ref, function(detail: tracker.IssueDetail?)
							if detail and string.find(detail.body, "%S") then
								info.excerpt = detail.body
							end
							done(info, nil)
						end, live)
					end
				end)
			end)
		end,
		-- The PR whose head is `branch`, for a row noted with an issue but no PR: GitHub's own answer (a lookup of
		-- `gh pr list --head`), none when there is none. A failed lookup shows nothing.
		head = function(row: any, branch: string, done: (number?) -> ())
			later(row, function()
				github.pullByHead(row.repo, branch, nil, function(pr: github.HeadPr?)
					done(if pr then pr.number else nil)
				end)
			end)
		end,
	}
end

-- Previews `row`; the pull request and issue it was made for are read once.
function M.boardPick(state: State, row: any)
	state.boardWait = true
	for i, r in M.boardRows(state) do
		if r.id == row.id then
			state.boardAt = i
		end
	end
	board.select(state.board, M.boardLinks(state), row.id, aliveFn(state), function()
		state.cx:render()
	end)
end

function M.boardMove(state: State, delta: number)
	local rows = M.boardRows(state)
	if #rows > 0 then
		local _, at = M.boardSelected(state)
		M.boardPick(state, rows[math.clamp(at + delta, 1, #rows)])
	end
end

-- The worktrees' uncommitted changes are read on their own while the board is shown (board.scan paces itself: it does
-- nothing unless due); `force` after a load or Refresh. A timer asks again; leaving the board stops the scan and the timer.
function M.boardScan(state: State, force: boolean?)
	if not state.boardOn then
		if state.board.scanning then
			board.stop(state.board)
		end
		if state.boardTimer then
			state.boardTimer:cancel()
			state.boardTimer = nil
		end
		return
	end
	board.scan(state.board, M.boardApi(state), os.time(), function(): boolean
		return M.alive(state) and state.boardOn
	end, function()
		state.cx:render()
	end, force)
	if not state.boardTimer then
		-- Asked again when the next scan is due, not a full interval after this call.
		local at = state.board.scanAt
		local wait = if at then math.max(1, board.SCAN_SECONDS - (os.time() - at)) else board.SCAN_SECONDS
		state.boardTimer = tern.timer(wait * 1000, function()
			state.boardTimer = nil
			if M.alive(state) then
				M.boardScan(state)
			end
		end)
	end
end

-- Reads every saved checkout's worktrees again, one checkout at a time; one read at a time.
function M.boardLoad(state: State)
	if state.boardBusy then
		return
	end
	local checkouts: { [string]: string } = {}
	for repo, path in readCheckouts() do
		if type(repo) == "string" and type(path) == "string" and path ~= "" then
			checkouts[repo] = path
		end
	end
	state.boardBusy = true
	local settled = false -- board.select (through board.load) calls this again as each preview read lands
	board.load(state.board, M.boardApi(state), checkouts, aliveFn(state), function()
		if not settled then
			settled = true
			state.boardBusy = false
			M.boardEnsure(state)
			M.boardScan(state, true)
		end
		state.cx:render()
	end)
	state.cx:render()
end

function M.openBoard(state: State)
	state.boardOn, state.focus = true, "list"
	if not state.board.loaded then
		M.boardLoad(state)
	end
	M.boardEnsure(state)
end

-- Shows sidebar scope `scopeId` (render.scopeRows' id: "worktrees", a pin or a view as one login runs it), as a click on
-- it does. false when the live sidebar has no such scope, so a stale id never jumps anywhere.
function M.goScope(state: State, scopeId: any): boolean
	if scopeId == "worktrees" then
		M.openBoard(state)
		return true
	end
	for _, scope in M.orderedViews(state) do
		if scope.id == scopeId then
			if state.boardOn and ghActive.isActive(state, scope) then
				state.boardOn = false -- back to the view already shown: its selection stays
			elseif state.boardOn or not ghActive.isActive(state, scope) then
				M.switchView(state, scope.view.id, scope.login)
			end
			return true
		end
	end
	return false
end

-- The folders (as the rows have them) some pane of this host works in.
function M.boardOpen(state: State): { [string]: boolean }
	local open: { [string]: boolean } = {}
	local panes = tern.pane.list()
	for _, row in M.boardRows(state) do
		for _, p in panes do
			if p.cwd and worktree.within(p.cwd, row.path) then
				open[row.path] = true
			end
		end
	end
	return open
end

-- Whether an item's pull request or issue is closed, merged or open, as the board's cleanup check asks: GitHub pull
-- requests by number, GitHub issues and Jira issues by the key the worktree was noted for.
function M.boardCheck(state: State): any
	local live = aliveFn(state)
	local function closedOrOpen(issue: tracker.Issue?): string
		return if not issue then "unknown" elseif issue.state == "closed" then "closed" else "open"
	end
	return function(row: any, done: (string) -> ())
		local number: number? = row.number
		local key: string = row.key or ""
		local n, repo, ref = parseIssueRef(key, row.repo)
		if number then
			github.pull(nil, "https://github.com/" .. row.repo .. "/pull/" .. number, live, function(result: any)
				local pr = if result and result.prs then result.prs[1] else nil
				done(if not pr then "unknown" elseif pr.state == "merged" then "merged" elseif pr.state == "closed" then "closed" else "open")
			end)
		elseif n then
			github.issueItem(repo, n, nil, function(issue: tracker.Issue?)
				done(closedOrOpen(issue))
			end, live)
		elseif string.match(ref, "^%u[%u%d_]*%-%d+$") then
			jira.item(ref, function(issue: tracker.Issue?)
				done(closedOrOpen(issue))
			end, live)
		else
			done("unknown")
		end
	end
end

-- The picker's rows and order for the board: a group per repository.
function M.boardItems(state: State): ({ any }, { any })
	local open = M.boardOpen(state)
	local items: { any } = {}
	local order: { any } = {}
	local groups: { [string]: { any } } = {}
	local names: { string } = {}
	for _, row in M.boardRows(state) do
		local label = board.label(row)
		local detail: { any } = { ui.span(row.path, "mono") }
		if row.key or row.number then
			table.insert(detail, " · ")
			table.insert(detail, ui.span(if row.number then "#" .. row.number else row.key, "num"))
		end
		local id = M.boardId(row)
		table.insert(items, { id = id, label = label, title = label, detail = detail, badges = board.badges(row, open[row.path] == true) })
		if not groups[row.repo] then
			groups[row.repo] = {}
			table.insert(names, row.repo)
		end
		table.insert(groups[row.repo], id)
	end
	for _, name in names do
		table.insert(order, { group = name, label = name, count = #groups[name] })
		for _, id in groups[name] do
			table.insert(order, id)
		end
	end
	return items, order
end

-- Moves the cursor `delta` rows through the visible items, clamped to the list.
function M.moveCursor(state: State, delta: number)
	local v = M.filtered(state)
	if not v or #v.items == 0 then
		return
	end
	local i = M.indexOf(v.items, state.cursor)
	M.select(state, v.items[math.clamp(i + delta, 1, #v.items)].key)
end

function M.moveView(state: State, delta: number)
	local items = M.orderedViews(state)
	local at = if state.boardOn then #items + 1 else 0
	if not state.boardOn then
		for i, scope in items do
			if ghActive.isActive(state, scope) then
				at = i
			end
		end
	end
	-- The Worktrees list is the last entry of the sidebar.
	local to = math.clamp(at + delta, 1, #items + 1)
	if to == #items + 1 then
		if not state.boardOn then
			M.openBoard(state)
		end
		return
	end
	local target = items[to]
	if target and state.boardOn and ghActive.isActive(state, target) then
		state.boardOn = false
	elseif target and (state.boardOn or not ghActive.isActive(state, target)) then
		M.switchView(state, target.view.id, target.login)
	end
end

-- Asks each CLI whether it starts, once (`again`: those already answered too, as Refresh does). Once every answer is
-- in and one changed, every block rereads its views (an integration turned on or off), and a Settings page that went
-- with it (a setup page once its CLI starts) gives way to Views.
function M.probeClis(again: boolean?)
	for _, c in cli.list do
		if (again or cli.installed[c.id] == nil) and not cli.probing[c.id] then
			cli.probing[c.id] = true
			process.run(c.argv, { timeout_ms = 10000 }, function(result)
				cli.probing[c.id] = nil
				cli.moved = cli.moved or cli.installed[c.id] ~= (result ~= nil)
				cli.installed[c.id] = result ~= nil
				if c.id == "jira" and result and not cli.sprintsAsking then
					-- Before the views are reread below, so a first run's issue views wait for the answer.
					cli.sprintsAsking = true
					jira.sprints(function(has: boolean?)
						cli.sprintsAsking, cli.sprints = false, has
						if not cli.ready() then
							return -- the reread once every CLI answered reads it
						end
						for _, s in running do
							if M.alive(s) then
								M.reloadViews(s)
								s.cx:render()
							end
						end
					end)
				end
				if next(cli.probing) ~= nil or not cli.moved then
					return
				end
				cli.moved = false
				for _, s in running do
					if M.alive(s) then
						M.reloadViews(s)
						local set = s.settings
						if set and cli.page(set.page) ~= set.page then
							set.page, set.focus, set.pick, s.settingsPage = "views", nil, nil, "views"
						end
						ghActive.note(s, set ~= nil)
						s.cx:render()
					end
				end
			end)
		end
	end
end

-- The sidebar group a view sits under: "GitHub - andyhite" for a view with its own login.
function M.groupLabel(v: View): string
	local login = ghActive.shown(v)
	return if login ~= "" then INTEGRATIONS[v.integration].label .. " - " .. login else INTEGRATIONS[v.integration].label
end

function M.viewOf(state: State, id: string): View?
	for _, v in state.views do
		if v.id == id then
			return v
		end
	end
	return nil
end

function M.openSelected(state: State, act: string, rerender: boolean)
	local item = M.selected(state)
	if item then
		if rerender then
			state.cx:render() -- sends the new preview before the open request
		end
		state.cx:open(hrefOf(state, item, act))
	end
end

local loadDetails: (State, string) -> ()

-- Loads the checks of `key` after `ms`. One attempt waits at a time; a new one replaces it.
local function armDetails(state: State, key: string, ms: number)
	M.cancelDetails(state)
	local attempt: Attempt = { key = key, timer = nil }
	state.detailAttempt = attempt
	attempt.timer = tern.timer(ms, function()
		if state.detailAttempt ~= attempt then
			return -- replaced or cancelled: the slot belongs to someone else now
		end
		state.detailAttempt = nil
		if M.alive(state) then
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
		retryAt = now + math.max(M.waitOf(state), DETAIL_RETRY_S)
	elseif not TERMINAL[problem.kind] then
		retryAt = now + math.min(DETAIL_RETRY_S * 2 ^ (tries - 1), DETAIL_RETRY_MAX_S)
	end
	state.detailFail[key] = { problem = problem, tries = tries, retryAt = retryAt }
end

-- Whether the checks of `key` were loaded after the latest search (an older list is shown, but loads again).
local function upToDate(state: State, key: string): boolean
	local d = state.details[key]
	return d ~= nil and d.round == state.round
end

loadDetails = function(state: State, key: string)
	local item = M.selected(state)
	if not item or M.detailKey(state, item) ~= key or upToDate(state, key) or state.detailBusy[key] then
		return -- the cursor moved on, or it is loaded or loading already: a render asks again if it still matters
	end
	local snap = state.snap
	local account, round, kind = state.account, state.round, if snap then snap.kind else state.kind.id
	local function current(): boolean
		return state.account == account and state.round == round and state.kind.id == kind
	end
	local function live(): boolean
		return running[state.cx.pane] == state and current()
	end
	-- Where a load lands. A load of another identity or an older search is not stored: its own render asks again.
	-- Otherwise `details` is kept (and a failure forgotten), or, when nil, the failure paced by failDetails.
	local function land(problem: github.Problem?, details: core.Detail?, unread: string)
		state.detailBusy[key] = nil
		if not M.alive(state) then
			return
		end
		if not current() or (problem and problem.kind == "superseded") then
			state.cx:render() -- another identity or a newer search owns the preview now: its own render asks for fresh details
			return
		end
		if details then
			state.details[key] = details
			state.detailFail[key] = nil
		else
			failDetails(state, key, problem or { kind = "failed", message = unread })
		end
		state.cx:render()
	end
	state.detailBusy[key] = true
	if kind == "issues" then
		-- A GitHub load, like github.checks, sends nothing while the quota is spent or the login unusable: it
		-- answers with that problem, which failDetails paces.
		TRACKERS[item.tracker].detail(item, M.login(state), function(detail, problem)
			if not detail then
				return land(problem, nil, "The issue could not be read.")
			end
			local loaded: core.Detail = { runs = {}, total = 0, round = round, issue = detail }
			-- The PR of the worktree's branch, as far as the scan knew the worktree when this load ran (a later refresh
			-- loads again). Best effort: a failed lookup shows none.
			local note, code = state.notes[item.key], M.codeRepoOf(item)
			local branch = if note and note.ok then note.branch else nil
			if not branch or not code or not cli.on("github") then
				return land(nil, loaded, "")
			end
			github.pullByHead(code, branch, M.login(state), function(head)
				if head then
					local linked = false
					for _, l in detail.linked do
						local o, r, n = github.parsePrUrl(l.url)
						linked = linked or (n == head.number and o ~= nil and r ~= nil and string.lower(o .. "/" .. r) == string.lower(code))
					end
					if not linked then
						loaded.headPr = head
					end
				end
				land(nil, loaded, "")
			end)
		end, live)
		return
	end
	local pr: github.Pr = item
	-- github.checks sends nothing while the quota is spent or the saved login unusable: it answers with that problem, which failDetails paces.
	github.checks(pr.repo, pr.number, M.login(state), function(runs, total, problem, about)
		if not runs then
			return land(problem, nil, "The checks could not be read.")
		end
		local loaded: core.Detail = { runs = runs, total = total, round = round, about = about }
		-- The issue Plotroom noted for the worktree on this head branch, read from the checkout's git config. Best effort.
		local checkout = readCheckouts()[string.lower(pr.repo)]
		if type(checkout) ~= "string" or checkout == "" then
			return land(nil, loaded, "")
		end
		worktree.inventory(checkout, pr.repo, function(entries)
			local noted: string? = nil
			for _, e in entries or ({} :: { worktree.Entry }) do
				if not e.main and e.branch == pr.head and e.key then
					noted = e.key
					break
				end
			end
			if not noted then
				return land(nil, loaded, "")
			end
			readNoted(noted, pr.repo, live, function(issue)
				loaded.noted = issue
				land(nil, loaded, "")
			end)
		end)
	end, live)
end

-- Once the cursor rests on a PR with checks, loads all of them with their required flags (the search carries the first
-- 25, unflagged, and shows them meanwhile; checks loaded before the latest search show meanwhile too, and load again).
-- Once it rests on an issue, loads its body, milestone and linked pull requests. Idempotent: every render calls it. A
-- load waits out a debounce and a failed one its retry delay; moving to another item cancels the wait.
function M.wantDetails(state: State, item: any)
	local key = M.detailKey(state, item)
	local waiting = state.detailAttempt
	if waiting and waiting.key ~= key then
		M.cancelDetails(state)
		waiting = nil
	end
	if not key or waiting or upToDate(state, key) or state.detailBusy[key] then
		return
	end
	local fail = state.detailFail[key]
	if not fail then
		armDetails(state, key, DETAIL_DEBOUNCE_MS)
	elseif fail.retryAt then
		armDetails(state, key, math.max(0, fail.retryAt - os.time()) * 1000)
	end
end

-- Keeps the outcome of a worktree attempt (a report, or why there is none) for the queue preview: persistent, unlike
-- a toast. `key` is the item's key (lowercase "owner/repo#n"). The next render scans the checkouts again, so git
-- confirms a report. Only the attempts git has not confirmed count against NOTE_CAP: a block may hold more worktrees
-- than that.
function M.noteWorktree(state: State, key: string, kind: string, r: Report?, problem: string?)
	local note: Note = {
		seq = state.noteSeq + 1,
		kind = kind,
		at = os.time(),
		ok = r ~= nil,
		current = r ~= nil and r.current,
		dirty = if r then r.dirty else nil,
		root = if r then r.root else nil,
		path = if r then r.path else nil,
		branch = if r then r.branch else nil,
		ref = if r then r.ref else nil,
		summary = if r then r.summary else nil,
		message = if problem then clip(printable(problem), 1500) else nil,
		update = if r then r.update else {},
		checked = if r and r.dirty ~= nil then state.round else nil, -- the attempt has just read `git status`
	}
	state.notes[key] = note
	state.noteSeq = note.seq
	state.scanned = nil
	local count, oldest = 0, nil :: string?
	local oldestSeq = math.huge
	for other, n in state.notes do
		if not n.git then
			count += 1
			if n.seq < oldestSeq then
				oldest, oldestSeq = other, n.seq
			end
		end
	end
	if count > NOTE_CAP and oldest then
		state.notes[oldest] = nil
	end
end

-- The variables of an issue's prompts and branch name (KINDS.issues.vars lists them); `code` is the GitHub repository the
-- issue is worked in. `branch`, `base` and `remote` are only known once a worktree exists.
function M.issueVars(issue: tracker.Issue, code: string): { [string]: string }
	local owner, name = string.match(code, "^([^/]+)/([^/]+)$")
	local vars: { [string]: string } = {
		url = issue.url,
		key = issue.ref,
		title = issue.title,
		author = issue.author,
		labels = table.concat(issue.labels, ", "),
		owner = owner or "",
		repo = name or "",
	}
	if issue.tracker == "jira" then
		vars.project = issue.repo
		vars.status = if issue.status then issue.status.text else ""
		vars.type = issue.type or ""
	else
		vars.number = issue.ref
	end
	return vars
end

-- The GitHub repository an issue is worked in: its own, or the one its Jira project maps to when that is exactly one;
-- nil while the choice is still to be made.
function M.codeRepoOf(issue: tracker.Issue): string?
	if issue.tracker ~= "jira" then
		return issue.repo
	end
	local mapped = jiraReposOf(issue.repo)
	return if #mapped == 1 then mapped[1] else nil
end

-- `{github.user}` and `{jira.user}`: who you are on GitHub and Jira, for branch formats and prompts.
local me = {}
M.me = me

-- Reads `{github.user}` (the login the active view's gh account is, else gh's active one; "" while gh is off) and,
-- `jiraToo`, `{jira.user}`; done(users), "" for one that could not be read.
function me.read(state: State, jiraToo: boolean, done: ({ [string]: string }) -> ())
	local account = M.login(state)
	local function read(gh: string?)
		if gh and not account then
			ghActive.login = gh
		end
		local users: { [string]: string } = { ["github.user"] = gh or "", ["jira.user"] = "" }
		if not jiraToo then
			return done(users)
		end
		jira.user(function(ju)
			if ju then
				users["jira.user"] = ju
			end
			done(users)
		end)
	end
	if cli.on("github") then
		github.login(account, read)
	else
		read(nil)
	end
end

-- Whether `text` names `{github.user}` or `{jira.user}`.
function me.named(text: string): boolean
	return string.find(text, "{github.user}", 1, true) ~= nil or string.find(text, "{jira.user}", 1, true) ~= nil
end

-- The users known without asking for `issue` (a Jira user only for a Jira issue); an unknown one is left out. The active
-- view's own gh login is its user; else gh's active login, once ghActive.note or me.read found it. The Jira user is
-- known once a Jira search found the site.
function me.of(state: State, issue: tracker.Issue): { [string]: string }
	return {
		["github.user"] = M.login(state) or ghActive.login,
		["jira.user"] = if issue.tracker == "jira" then jira.known() else "",
	}
end

-- The branch a new worktree of `issue` in `code` gets (formats.issueBranch over its variables and `users`; a user not
-- in `users` stays as its variable), and its worktree's folder name. nil and why when a format cannot name one.
function M.issueNames(issue: tracker.Issue, code: string, users: { [string]: string }): (string?, string?, string?)
	local owner, name = string.match(code, "^([^/]+)/([^/]+)$")
	local slug = tracker.slug(issue.title)
	local vars: { [string]: string } = {
		key = issue.ref,
		slug = slug,
		owner = owner or "",
		repo = name or "",
		project = if issue.tracker == "jira" then issue.repo else "",
		["github.user"] = users["github.user"] or "{github.user}",
		["jira.user"] = users["jira.user"] or "{jira.user}",
	}
	local branch, why = tracker.render(formats.issueBranch(code), vars)
	if not branch then
		return nil, nil, why
	end
	local dir, dirWhy = tracker.render(formats.of("issuedir"), { key = issue.ref, slug = slug, owner = string.lower(owner or ""), repo = string.lower(name or "") }, true)
	if not dir then
		return nil, nil, dirWhy
	end
	return branch, dir, nil
end

-- How worktree.scan knows `item`'s worktree (a github.Pr, or a tracker.Issue worked in one of `codes`): a pull
-- request's by its head branch, an issue's by the branch the format names now; either by the folder name the format
-- names now.
function M.worktreeWant(state: State, kind: string, item: any, codes: { string }): worktree.Want
	local want: worktree.Want = { branches = {}, dirs = {} }
	if kind ~= "issues" then
		local owner, name = string.match(item.repo, "^([^/]+)/([^/]+)$")
		table.insert(want.branches, worktree.prBranch(item.head, item.fork))
		want.ref = worktree.prRef(owner or "", name or "", item.number)
		local dir = formats.prDir(item.repo, item.number, item.title)
		if dir then
			table.insert(want.dirs, dir)
		end
		return want
	end
	local users = me.of(state, item)
	for _, code in codes do
		local branch, dir = M.issueNames(item, code, users)
		if branch and dir then
			table.insert(want.branches, branch)
			table.insert(want.dirs, dir)
		end
	end
	return want
end

-- The saved prompts offered under the active view, those with text: the ones the view lists (`here`), else every one;
-- and why the prompts could not be read.
function M.offered(state: State): ({ { prompt: Prompt, here: boolean } }, string?)
	local active = M.activeView(state)
	local prompts, problem = loadPrompts(if active then KINDS[active.kind] else state.kind)
	local list: { Prompt } = if prompts then prompts.items else {}
	local ids = if active then livePrompts(active, list) else {}
	local out: { { prompt: Prompt, here: boolean } } = {}
	for _, p in list do
		if p.text ~= "" and (#ids == 0 or table.find(ids, p.id) ~= nil) then
			table.insert(out, { prompt = p, here = #ids > 0 })
		end
	end
	return out, problem
end

-- The board's own actions (`act`: the action bar's id or its key): true when it was one.
function M.boardAct(state: State, act: string): boolean
	local live = aliveFn(state)
	local row = M.boardSelected(state)
	if act == "retry" then
		if not state.boardBusy then
			state.board.details = {} -- Refresh reads the previewed pull request and issue again, not only git
		end
		M.boardLoad(state)
	elseif act == "wt-open" then
		local _, at = M.boardSelected(state)
		if row and not row.missing then
			state.cx:render() -- the window reads the row's link from the shown surface
			state.cx:open("plotroom://worktrees/open/" .. at)
		end
	elseif act == "wt-cleanup" then
		if not state.boardBusy then
			state.boardBusy = true
			board.findCandidates(state.board, M.boardCheck(state), live, function(checked: number, skipped: number)
				state.boardBusy = false
				state.cx:toast("info", "Checked " .. checked .. " worktree" .. (if checked == 1 then "" else "s") .. " against GitHub and Jira", if skipped > 0 then skipped .. " more not checked: run Find finished worktrees again" else "Closed and merged ones are marked; nothing is removed")
				state.cx:render()
			end)
			state.cx:render()
		end
	elseif act == "wt-remove" then
		if state.boardBusy then
			state.cx:toast("info", "Still reading", "Remove it once the read has finished.")
		elseif row and not row.main and not row.locked and not row.missing then
			state.boardRemoving = row.id
		end
	elseif act == "wt-cancel-remove" then
		state.boardRemoving = nil
	elseif act == "wt-confirm-remove" then
		local id = state.boardRemoving
		state.boardRemoving = nil
		if id and not state.boardBusy then
			state.boardBusy = true
			board.remove(state.board, M.boardApi(state), id, live, function(ok: boolean, message: string)
				state.boardBusy = false
				state.cx:toast(if ok then "success" else "error", if ok then "Worktree removed" else "Worktree not removed", message)
				M.boardEnsure(state)
				for _, s in running do
					s.scanned = nil -- every block reads its notes from git again
					s.noteSeq += 1
					if s ~= state and M.alive(s) then
						s.cx:render()
					end
				end
				state.cx:render()
			end)
			state.cx:render()
		end
	else
		return false
	end
	return true
end

-- A pane moved into or out of a PR worktree, or ended: redraw every queue so "In tab" marks follow. Deferred, since
-- the host's pane list still holds an exiting pane while its event runs (observed: an undeferred redraw kept the mark).
local function redrawQueues()
	tern.timer(250, function()
		for _, s in running do
			if M.alive(s) then
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
-- The window's report of its agents' states (`agent-status`: JSON of item key -> state): replaces what the rows show.
function M.agentStatus(state: State, raw: any)
	if type(raw) ~= "string" or #raw > 40000 then
		return
	end
	local ok, decoded = pcall(tern.json.decode, raw)
	if not ok or not isTable(decoded) then
		return
	end
	local map: { [string]: string } = {}
	local count = 0
	for key, value in decoded do
		local clean = triage.sanitizeKey(key)
		if clean and (value == "working" or value == "waiting_input" or value == "idle" or value == "exited") and count < 200 then
			map[clean] = value
			count += 1
		end
	end
	local same = true
	for k, v in map do
		same = same and state.agents[k] == v
	end
	for k in state.agents do
		same = same and map[k] ~= nil
	end
	if not same then
		state.agents = map
		state.rev += 1
		state.vis = nil
		if state.snap then
			M.ensureCursor(state)
		end
		state.cx:render()
	end
end

-- A palette command of the window about triage (`triage` event).
function M.triageEvent(state: State, value: any)
	if value == "seen" or value == "snooze" or value == "unsnooze" then
		M.mark(state, value)
	elseif value == "toggle-snoozed" then
		M.toggle(state, "snoozed")
	elseif value == "toggle-attention" then
		M.toggle(state, "attention")
	end
end

return M
