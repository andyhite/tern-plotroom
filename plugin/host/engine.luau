--!strict
-- Per-pane lifecycle, identity and refresh, triage, pins, the Worktrees board glue, navigation, details loading, worktree notes, the `me` and `ghActive` tables, CLI probing.

local board = require("../board")
local github = require("../github")
local input = require("../input")
local jira = require("../jira")
local logs = require("../logs")
local process = require("../process")
local sorting = require("../sorting")
local tracker = require("../tracker")
local triage = require("../triage")
local worktree = require("../worktree")
local core = require("./core")
local storage = require("./storage")

local ui = tern.ui

type AgentInfo = core.AgentInfo
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
local clip, hrefOf, printable, running, splitRepo, cli = core.clip, core.hrefOf, core.printable, core.running, core.splitRepo, core.cli
local isTable, jiraReposOf, livePrompts, loadAll, loadPrompts, readCheckouts, formats =
	storage.isTable, storage.jiraReposOf, storage.livePrompts, storage.loadAll, storage.loadPrompts, storage.readCheckouts, storage.formats

local M = {}

-- gh's active login on this host once known (`login`), the logins signed in (`accounts`) and the helpers that use them:
-- the sidebar groups of views that run as one login.
local ghActive = {} :: {
	login: string?,
	accounts: { string },
	note: (State, boolean?) -> (),
	shown: (View) -> string,
	isActive: (State, Scope) -> boolean,
}
ghActive.accounts = {}
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
	local owner, name = splitRepo(if type(raw) == "string" then input.trim(raw) else "")
	if owner and name and worktree.validSegment(owner) and worktree.validSegment(name) then
		return owner .. "/" .. name
	end
	return nil
end

-- Picker ids hold no `/` or `#`: a kind prefix (n item, w worktree row, g agent row) and the key ("owner/repo#n", or
-- "abc#ABC-12") with every other character spelled `_xx`, `_` included, so two keys never share one.
function M.pickerId(prefix: string, key: string): string
	return prefix .. (string.gsub(key, "[^%w%-]", function(c: string): string
		return string.format("_%02x", string.byte(c))
	end))
end

function M.itemOf(state: State, id: string): any
	local snap = state.snap
	if snap then
		for _, item in snap.items do
			if M.pickerId("n", item.key) == id then
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
-- Mark seen action) and by `M.autoSeen` (an item whose preview is open).
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

-- Whether the agent of item `key` needs you: it waits for input; or, idle after its turn, its end-of-run report says
-- `stuck` or `needs-human`, its run's outcome was checked Not verified, it is a checker whose check failed, or its
-- item's chain stopped at a limit. A working agent does not (you answered it), and an exited one is no longer listed.
function M.needsYou(state: State, key: string): boolean
	local agent = state.agents[key]
	if agent == "waiting_input" then
		return true
	elseif agent ~= "idle" then
		return false
	end
	local info: AgentInfo = state.agentInfo[key] or {}
	return info.attention == "stuck" or info.attention == "needs-human" or info.verdict == "not" or info.check == "fail" or info.stop ~= nil
end

-- `item`'s stage, a core.STAGE id, from facts already here: the search's fields, its agent (state.agents, needsYou), its
-- worktree (state.notes) and, for an issue, the PR of its worktree's branch once the details loaded. `why` says what
-- blocks a PR. A fact GitHub did not give (merge state unknown) never makes Ready to merge.
function M.stage(state: State, kind: string, item: any): (string, string?)
	if item.state == "merged" or item.state == "closed" then
		return item.state
	end
	if M.needsYou(state, item.key) then
		return "needs"
	elseif state.agents[item.key] == "working" then
		return "working"
	end
	if kind == "prs" then
		local pr: github.Pr = item
		-- ponytail: the search cannot ask which checks are required; GitHub's merge state saying only optional checks
		-- fail (unstable) or none (ready) clears a failing rollup. Read the detail runs' `required` if that misleads.
		local failing = pr.checks == "failure" and pr.merge ~= "unstable" and pr.merge ~= "ready"
		if pr.review == "changes" or pr.merge == "conflicts" or failing then
			return "blocked", if pr.merge == "conflicts" then "Conflicts with its base" elseif pr.review == "changes" then "Changes requested" elseif M.allFlaky(state, pr) then "Checks failing (likely flaky)" else "Checks failing"
		elseif not pr.draft and pr.review == "approved" and pr.merge == "ready" and (pr.checks == "success" or pr.checks == nil) then
			return "ready"
		end
		return "pr"
	end
	local detail = state.details[M.detailKey(state, item)]
	local head = if detail then detail.headPr else nil
	if head and (head.state == "open" or head.state == "draft") then
		return "pr"
	end
	local note = state.notes[item.key]
	return if note and note.ok then "worktree" else "none"
end

-- The checks of `item` (a pull request) as the preview shows them: the loaded list, else what the search carried.
function M.runsOf(state: State, item: any): { github.Run }
	local d = state.details[M.detailKey(state, item)]
	return if d then d.runs else item.runs
end

-- Whether `item` (a pull request) has a failed workflow run Re-run failed checks can start again.
function M.rerunnable(state: State, item: any): boolean
	for _, r in M.runsOf(state, item) do
		if r.runId and r.status == "failure" then
			return true
		end
	end
	return false
end

-- The failing checks of `item` (a pull request), as the preview lists them.
function M.failing(state: State, item: any): { github.Run }
	local out: { github.Run } = {}
	for _, r in M.runsOf(state, item) do
		if r.status == "failure" then
			table.insert(out, r)
		end
	end
	return out
end

-- `pr`'s Likely flaky marks by check link while they were judged at its current head; nil otherwise (a new head drops them).
function M.flakyMarks(state: State, pr: any): { [string]: { name: string, reason: string } }?
	local f = state.flaky[pr.key]
	return if f and pr.headSha and f.sha == pr.headSha then f.marks else nil
end

-- Whether `pr` has a failing check and every failing check is Likely flaky.
function M.allFlaky(state: State, pr: any): boolean
	local marks = M.flakyMarks(state, pr)
	if not marks then
		return false
	end
	local failing = M.failing(state, pr)
	for _, r in failing do
		if not (r.url and marks[r.url]) then
			return false
		end
	end
	return #failing > 0
end

-- `{flaky}` of a pull request action: the item's Likely flaky checks with why and the head commit they were judged
-- at ("build (failed 3 of the last 20 runs on main) at head 1a2b3c4"), or "none" when no check of it is marked.
function M.flakyText(state: State, key: string): string
	local f = state.flaky[key]
	if not f then
		return "none"
	end
	local parts: { string } = {}
	for _, m in f.marks do
		table.insert(parts, m.name .. " (" .. m.reason .. ")")
	end
	if #parts == 0 then
		return "none"
	end
	table.sort(parts)
	return table.concat(parts, "; ") .. " at head " .. string.sub(f.sha, 1, 7)
end

-- Whether `pr` is someone else's open pull request that asks for the review of the login the view runs as (by name; a
-- team request does not count), as its loaded details say. Your dismissed review asks for it again.
function M.reviewAsked(state: State, pr: github.Pr): boolean
	local who = M.login(state) or ghActive.login
	if not who or pr.state ~= "open" or pr.draft or string.lower(pr.author) == string.lower(who) then
		return false
	end
	local d = state.details[M.detailKey(state, pr)]
	local reviews: { github.Review } = if d and d.about then d.about.reviews else {}
	for _, r in reviews do
		if (r.state == "requested" or r.state == "dismissed") and string.lower(r.login) == string.lower(who) then
			return true
		end
	end
	return false
end

-- The suggested next move for `item` (the selected one) in its stage, or nil when none applies: `id` is a queue action
-- (`worktree`, `agentgo`), `remove` (the worktree card's Remove worktree…), `cmd:<flows.COMMANDS id>` or
-- `run:<saved action id>`, each offered only where its own command is. A saved action is the one offered here under
-- that name (Review, Address feedback, Watch). "Yours" is a PR whose author is the login the view runs as. A Blocked
-- PR with failing checks is re-run only when every failing check is Likely flaky; else yours goes to Watch.
function M.nextMove(state: State, kind: string, item: any): { id: string, label: string }?
	local stage = M.stage(state, kind, item)
	local note = state.notes[item.key]
	local function action(name: string): { id: string, label: string }?
		for _, o in (M.offered(state)) do
			if string.lower(o.prompt.name) == string.lower(name) then
				return { id = "run:" .. o.prompt.id, label = o.prompt.name }
			end
		end
		return nil
	end
	if stage == "merged" or stage == "closed" then
		return if note and note.ok then { id = "remove", label = "Remove worktree…" } else nil
	elseif stage == "needs" or stage == "working" then
		return { id = "agentgo", label = "Go to agent" }
	elseif kind ~= "prs" then
		if stage == "none" then
			return { id = "worktree", label = "Worktree" }
		end
		return if stage == "worktree" and note and note.root and note.path then { id = "cmd:draft-pr", label = "Draft PR…" } else nil
	end
	local pr: github.Pr = item
	local who = M.login(state) or ghActive.login
	local me = if who then string.lower(who) else nil
	local mine = me ~= nil and string.lower(pr.author) == me
	if stage == "blocked" then
		local fix = if mine and pr.review == "changes" then action("Address feedback") else nil
		if fix or #M.failing(state, pr) == 0 then
			return fix
		elseif M.allFlaky(state, pr) and M.rerunnable(state, pr) then
			return { id = "cmd:rerun-failed", label = "Re-run failed checks" }
		end
		return if mine then action("Watch") else nil
	elseif stage == "ready" then
		return if pr.headSha then { id = "cmd:pr-merge", label = "Merge…" } else nil
	elseif pr.state ~= "open" then
		return nil
	elseif pr.draft then
		return if mine then { id = "cmd:pr-ready", label = "Ready for review…" } else nil
	elseif mine or not me then
		return nil
	end
	return if M.reviewAsked(state, pr) then action("Review") else nil
end

-- Whether the list shows `item`: everything except snoozed items (unless shown), though an agent that waits for input
-- always surfaces its item.
function M.keep(state: State, kind: string, item: any): boolean
	local shown = M.activeView(state)
	if shown and M.isPin(shown.id) then
		return true -- the one item shown on its own is never filtered out
	end
	if state.showSnoozed or M.needsYou(state, item.key) then
		return true
	end
	local store = M.store(state)
	return not (store and triage.snoozed(store, item, os.time()))
end

-- How many of `snap`'s items a sidebar scope counts: those its list shows, so snoozed ones are left out (unless shown).
function M.listedCount(state: State, snap: Snap, pinned: boolean): number
	if pinned or state.showSnoozed then
		return #snap.items
	end
	local n = 0
	local store = M.store(state)
	local now = os.time()
	for _, item in snap.items do
		if M.needsYou(state, item.key) or not (store and triage.snoozed(store, item, now)) then
			n += 1
		end
	end
	return n
end

-- How many of `snap`'s items snoozing keeps off the list.
function M.hiddenCount(state: State, snap: Snap): number
	local n = 0
	for _, item in snap.items do
		if not M.keep(state, snap.kind, item) then
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
		for _, g in core.groupsOf(snap.kind, view.integration) do
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
				hits[M.pickerId("n", item.key)] = { range }
				hasHits = true
			end
		end
	end
	local byCategory: ((any) -> number)? = if view and view.integration == "jira" and snap.kind == "issues" then tracker.categoryRank else nil
	local sorted: { any } = if view and view.sort then sorting.apply(kept, view.sort, byCategory) else kept
	if not spec then
		kept = sorted
	end
	local items: { any } = {}
	local order: { any } = {}
	if spec then
		-- Headers of the groups, each followed by its items; navigation walks `items`, so a header is never selected.
		local buckets: { [string]: { any } } = {}
		local labels: { string } = {}
		local ranks: { [string]: number } = {}
		for _, item in kept do
			local label = spec.of(item)
			if not buckets[label] then
				buckets[label] = {}
				table.insert(labels, label)
				if spec.rank then
					ranks[label] = spec.rank(item)
				end
			end
		end
		-- A sort orders the items of a group; the groups keep the order of the list they came in.
		local source: { any } = if view and view.sort then sorted else kept
		for _, item in source do
			table.insert(buckets[spec.of(item)], item)
		end
		if not spec.keep then
			local rank = spec.rank
			table.sort(labels, function(a: string, b: string): boolean
				if rank and ranks[a] ~= ranks[b] then
					return ranks[a] < ranks[b]
				end
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
				table.insert(order, M.pickerId("n", item.key))
			end
		end
	else
		for _, item in kept do
			table.insert(items, item)
			table.insert(order, M.pickerId("n", item.key))
		end
	end
	local out: Visible = { snap = snap, needle = text, group = group, rev = state.rev, items = items, order = tern.json.array(order), hits = if hasHits then hits else nil }
	state.vis = out
	return out
end

-- Moves the selection to `key` (nil: none).
function M.select(state: State, key: string?)
	state.cursor = key
	local v = if key then M.filtered(state) else nil
	state.cursorAt = if v then M.indexOf(v.items, key) else state.cursorAt
end

-- Keeps the selection on a listed item, so a nonempty list always has its preview open: the first item when nothing is
-- selected, the row that took the place of one that vanished (a refresh, a search, a snooze). An empty list selects
-- nothing.
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

local nowEnsure: (State) -> () -- M.nowEnsure, defined with Now below

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
			nowEnsure(s)
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
	if not item or not snap or state.boardOn or state.agentsOn or state.nowOn then
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

-- Shows or hides the snoozed items ("snoozed").
function M.toggle(state: State, what: string)
	if what ~= "snoozed" then
		return
	end
	state.showSnoozed = not state.showSnoozed
	state.rev += 1
	state.vis = nil
	M.ensureCursor(state)
	nowEnsure(state)
end

-- The gh login the active scope runs as (nil: the active gh account), for github.wait and quota and every gh call.
function M.login(state: State): string?
	local v = M.activeView(state)
	local who = if v then M.accountOf(v, state.activeLogin) else ""
	return if who ~= "" then who else nil
end

-- Verifies `path` as a checkout of `repo` (a new or empty folder gets a clone) and saves it. Returns `busy` when a setup of
-- the repository is already running; else `done(claimed, err)` runs once the checkout is saved (err nil) or refused, unless
-- the block is gone. `moved` is the problem when the saved checkout changed meanwhile.
function M.claimCheckout(state: State, repo: string, path: string, busy: string, moved: string, done: ({ root: string, cloned: boolean }?, string?) -> ()): string?
	local key = string.lower(repo)
	if cli.claims[key] then
		return busy
	end
	local before = readCheckouts()[key]
	cli.claims[key] = true
	worktree.claimCheckout(path, repo, M.login(state), function(claimed, problem)
		cli.claims[key] = nil
		if not M.alive(state) then
			return
		end
		local root = if claimed then claimed.root else nil
		local err: string?
		if root and readCheckouts()[key] ~= before then
			err = moved -- saving would undo that
		elseif root then
			err = storage.saveCheckout(repo, root)
		else
			err = problem or "That path is not a checkout of " .. repo .. "."
		end
		if not err then
			state.scanned = nil -- the new checkout may already hold worktrees: the next render scans it
			M.propagate(state)
		end
		done(claimed, err)
	end)
	return nil
end

-- ---------------------------------------------------------------- Get started

local GET_STARTED = "get-started" -- kv: { dismissed = true?, shortcuts = "use" | "no"? }
local SETUP_S = 10 -- while the checklist may show, its facts and detection are asked again at most this often

-- What the checklist knows of this host, as last asked; nil: not known yet.
M.setup = { omp = nil :: boolean?, signedIn = nil :: boolean? }

-- Where each checklist line that is not done points.
M.SETUP_GUIDES = {
	gh = "https://github.com/cli/cli#installation",
	["gh-login"] = "https://cli.github.com/manual/gh_auth_login",
	omp = "https://github.com/can1357/oh-my-pi",
} :: { [string]: string }

-- kv `get-started`; nil when it cannot be read (it is then never written over, and the checklist only shows when asked).
function M.getStarted(): { [string]: any }?
	return (storage.readMap(GET_STARTED, "the Get started checklist"))
end

-- Sets `field` of kv `get-started`; an error message or nil.
function M.saveGetStarted(field: string, value: any): string?
	return storage.editMap(GET_STARTED, "the Get started checklist", function(map: { [string]: any }): (string?, boolean?)
		map[field] = value
		return nil, nil
	end)
end

-- The repositories of the listed items that have no checkout, each once, in list order.
function M.missingCheckouts(state: State): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local saved = readCheckouts()
	local items: { any } = if state.snap then state.snap.items else {}
	for _, item in items do
		local repo: string? = if type(item.number) == "number" then item.repo else M.codeRepoOf(item)
		local key = if repo then string.lower(repo) else nil
		if repo and key and not seen[key] then
			seen[key] = true
			local path = saved[key]
			if type(path) ~= "string" or path == "" then
				table.insert(out, repo)
			end
		end
	end
	return out
end

-- The folders known to belong to some repository, in the order detection tries them: the one the block opened in, then
-- the working directory of every pane on this host. tern.pane.list lists only this host's panes, so a pane on another
-- host never counts.
function M.knownFolders(state: State): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	local function add(p: string?)
		if type(p) == "string" and p ~= "" and not seen[p] then
			seen[p] = true
			table.insert(out, p)
		end
	end
	add(state.launchCwd)
	for _, p in tern.pane.list() do
		add(p.cwd)
	end
	return out
end

-- The checkout of `repo` found among the known folders, verified as Settings verifies one; done(path?) unless the block
-- is gone. ponytail: git runs per folder per repository; cache per folder if many panes ever make it slow.
function M.detectCheckout(state: State, repo: string, done: (string?) -> ())
	worktree.findCheckout(M.knownFolders(state), repo, function(path)
		if M.alive(state) then
			done(path)
		end
	end)
end

-- Asks what the checklist shows: whether omp starts, whether gh is signed in, and a checkout folder for each listed
-- repository without one. Again only after SETUP_S, or at once when a listed repository was never looked for or gh,
-- found to start after the last round (its probe renders every block), was never asked about its sign-in.
function M.askSetup(state: State)
	local missing = M.missingCheckouts(state)
	local fresh = state.setupAt ~= nil and os.time() - state.setupAt < SETUP_S and (cli.installed.github ~= true or M.setup.signedIn ~= nil)
	for _, repo in missing do
		fresh = fresh and state.found ~= nil and state.found[string.lower(repo)] ~= nil
	end
	if state.setupAsking or fresh then
		return
	end
	state.setupAsking = true
	local found: { [string]: string | false } = {}
	local pending = 1
	local function one()
		pending -= 1
		if pending == 0 then
			state.setupAsking, state.setupAt, state.found = false, os.time(), found
			state.cx:render()
		end
	end
	pending += 1
	process.run({ "omp", "--version" }, { timeout_ms = 10000 }, function(result)
		M.setup.omp = result ~= nil
		if M.alive(state) then
			one()
		end
	end)
	if cli.on("github") then
		pending += 1
		github.accounts(function(list)
			M.setup.signedIn = list ~= nil and #list > 0
			if M.alive(state) then
				one()
			end
		end)
	end
	for _, repo in missing do
		pending += 1
		M.detectCheckout(state, repo, function(path)
			found[string.lower(repo)] = path or false
			one()
		end)
	end
	one()
end

-- Saves the folder detection found for `repo` as its checkout, verified again first.
function M.useFound(state: State, repo: string)
	local path = if state.found then state.found[string.lower(repo)] else nil
	if type(path) ~= "string" then
		return
	end
	local busy = M.claimCheckout(state, repo, path, "The checkout of " .. repo .. " is already being set up", "The checkout of " .. repo .. " changed meanwhile", function(claimed, err)
		if err or not claimed then
			state.cx:toast("error", "Checkout not saved", err)
		else
			state.cx:toast("success", "Checkout saved", claimed.root)
		end
		state.cx:render()
	end)
	if busy then
		state.cx:toast("info", busy)
	end
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

-- Drops what is loading or loaded for the previous identity (details, in-flight searches). Cached lists stay: they are
-- keyed by snapKey, which holds the login, integration and kind, so no identity sees another's.
-- ponytail: cached lists are never pruned (one per view and login visited); evict the oldest if memory ever shows.
local function forget(state: State)
	state.gen += 1
	state.snap, state.vis = nil, nil
	dropDetails(state)
end

-- `state.account`, `state.tracker` and `state.kind` are the identity everything on screen and in flight belongs to: the
-- active view's gh login, integration and kind. A different one drops its details and in-flight work, not the cached lists.
local function identify(state: State)
	local v = M.activeView(state)
	local account = if v then M.accountOf(v, state.activeLogin) else ""
	local integration = if v then v.integration else state.kind.integrations[1]
	local kind = if v then KINDS[v.kind] else state.kind
	-- A problem of this integration belongs to the login that raised it; one restored without it adopts the first
	-- login of its integration that is listed, whatever view came before.
	if state.problem and v and (state.problemBy or integration) == integration then
		if state.problemAccount == nil then
			state.problemAccount = account
		elseif account ~= state.problemAccount then
			state.problem = nil -- another login's failure is not this one's
		end
	end
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
	return if (state.problemBy or M.trackerOf(state)) == "jira" then JIRA_HEADS[k] else HEADS[k]
end

-- What to do about problem kind `k`, nil when there is no advice.
function M.helpOf(state: State, k: string): string?
	return if (state.problemBy or M.trackerOf(state)) == "jira" then JIRA_HELP[k] else HELP[k]
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

-- Checks, failures and folds of PRs that no cached snapshot lists any more (or lists with a newer update) cannot be
-- shown again; nor can the Likely flaky marks of a PR no snapshot lists.
local function prune(state: State)
	local keep: { [string]: boolean } = {}
	local listed: { [string]: boolean } = {}
	for _, snap in state.snaps do
		for _, item in snap.items do
			keep[M.detailKey(state, item)] = true
			listed[item.key] = true
		end
	end
	for key in state.flaky do
		if not listed[key] then
			state.flaky[key] = nil
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

-- Likely flaky (tern-plotroom#zaq6). A failing check of `pr` is Likely flaky when, in order: no FAILURE annotation
-- of it names a file the PR changes (one that does says the PR broke it); and it failed at least FLAKY_FAILS of the
-- last 20 runs of its workflow on the PR's base branch, or an earlier attempt of it passed on the same head commit.
-- done(marks by check link, problem). A check that is not a workflow run's has no base history.
local FLAKY_FAILS = 3
local function judgeFlaky(pr: github.Pr, failing: { github.Run }, account: string?, done: ({ [string]: { name: string, reason: string } }?, github.Problem?) -> ())
	github.evidence(pr.repo, pr.number, account, function(ev: github.Evidence?, problem: github.Problem?)
		if not ev then
			return done(nil, problem)
		end
		local marks: { [string]: { name: string, reason: string } } = {}
		if ev.head ~= pr.headSha then
			return done(marks, nil) -- the head moved since the search: the next refresh judges the new one
		end
		local at: { [string]: github.Attempted } = {}
		local passed: { [string]: boolean } = {}
		for _, r in ev.runs do
			if r.url then
				at[r.url] = r
			end
			if r.conclusion == "SUCCESS" then
				passed[(r.workflow or "") .. "\0" .. r.name] = true
			end
		end
		local open: { { url: string, name: string, run: github.Attempted } } = {}
		local workflows: { string } = {}
		local listed: { [string]: boolean } = {}
		for _, check in failing do
			local url = check.url
			local run = if url then at[url] else nil
			local blamed = false
			if run then
				for _, p in run.paths do
					blamed = blamed or ev.files[p] == true
				end
			end
			if url and run and not blamed then
				table.insert(open, { url = url, name = check.name, run = run })
				local wf = run.workflow
				if wf and not listed[wf] then
					listed[wf] = true
					table.insert(workflows, wf)
				end
			end
		end
		local history: { [string]: github.History } = {}
		local function decide()
			for _, o in open do
				local h = if o.run.workflow then history[o.run.workflow] else nil
				local reason = if h and h.failed >= FLAKY_FAILS
					then "failed " .. h.failed .. " of the last " .. h.total .. " runs on " .. pr.base
					elseif passed[(o.run.workflow or "") .. "\0" .. o.run.name] then "passed earlier on this commit"
					else nil
				if reason then
					marks[o.url] = { name = o.name, reason = reason }
				end
			end
			done(marks, nil)
		end
		local left = #workflows
		if left == 0 then
			return decide()
		end
		for _, wf in workflows do
			github.baseHistory(pr.repo, pr.base, wf, account, function(h: github.History?)
				if h then
					history[wf] = h
				end
				left -= 1
				if left == 0 then
					decide()
				end
			end)
		end
	end)
end

-- Judges Likely flaky for the shown list's Blocked pull requests with failing checks: at most FLAKY_ITEMS a refresh,
-- each at most once per head commit (a read the quota held back is tried again at the next refresh).
local FLAKY_ITEMS = 10
function M.gatherFlaky(state: State)
	local snap = state.snap
	if not snap or snap.kind ~= "prs" then
		return
	end
	local account = M.login(state)
	local started = 0
	for _, pr: github.Pr in snap.items do
		if started >= FLAKY_ITEMS then
			break
		end
		local key, sha = pr.key, pr.headSha
		local known = state.flaky[key]
		if sha and not state.flakyBusy[key] and not (known and known.sha == sha) and M.stage(state, "prs", pr) == "blocked" then
			local failing = M.failing(state, pr)
			if #failing > 0 then
				started += 1
				state.flakyBusy[key] = true
				judgeFlaky(pr, failing, account, function(marks, problem)
					if not M.alive(state) then
						return
					end
					state.flakyBusy[key] = nil
					if marks or (problem and problem.kind ~= "rate-limit") then
						state.flaky[key] = { sha = sha, marks = marks or {} }
						state.rev += 1
						state.cx:render()
					end
				end)
			end
		end
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
	M.nowRead(state) -- Now is read with every refresh, shown or not: its count is the pane title's and status line's
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
		if state.nowOn then
			schedule(state, POLL_MS) -- no view paces the refresh: Now is read again at the plain minute
		end
		return
	end
	-- The server's cooldown holds for every trigger, manual refresh included.
	local wait = M.waitOf(state)
	if wait > 0 then
		-- Nothing is loading: say why, so an uncached view does not show a spinner until the reset.
		state.problem, state.problemBy, state.problemAccount = { kind = "rate-limit", message = "GitHub's rate limit is reached; searches resume at " .. os.date("%H:%M:%S", os.time() + wait) .. "." }, "github", state.account
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
			local snap: Snap = { kind = kind, items = if issues then result.issues else result.prs, total = result.total, complete = result.complete, note = result.note, fetched = os.time() }
			state.snaps[key] = snap
			state.snap = snap
			state.round += 1 -- every loaded checks list is older than this result now
			state.problem = nil
			M.ensureCursor(state)
			prune(state)
			M.gatherFlaky(state)
			if integration == "github" then
				-- Warms the repository picker's list of gh logins (window.luau's pickRepo), so it opens without waiting on gh.
				ghActive.note(state)
			end
		else
			state.problem, state.problemBy, state.problemAccount = problem, integration, state.account
		end
		if spent > 0 then
			-- A finished snapshot shows the real points cost; a failed one keeps the larger known cost.
			state.cost = if result then spent else math.max(spent, state.cost)
			state.interval = github.interval(github.quota(M.login(state)), os.time(), state.cost + state.now.cost, openPanes(), POLL_MS)
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
	local v = M.activeView(state)
	-- A restored view is listed for the first time once the CLIs answer (applied is nil then): not a move.
	local first = state.applied == nil and v ~= nil and v.id == state.restoredId
	state.restoredId = nil
	local moved = not v or (M.snapKey(v, state.activeLogin) ~= state.applied and not first)
	-- "not-found" belongs to its view: another view clears it and searches; "auth" and "missing" hold every view.
	if p and (not TERMINAL[p.kind] or (moved and (p.kind == "invalid" or p.kind == "not-found"))) then
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
	github.forget()
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
	state.activeId, state.activeLogin, state.boardOn, state.agentsOn, state.nowOn = id, activeLogin, false, false, false
	state.cursor, state.cursorAt = nil, nil -- another view opens on its first item (ensureCursor)
	identify(state)
	M.changed(state) -- a click always refreshes; refresh itself dedupes, honors the cooldown and skips terminal problems
end

-- After another block wrote the views, on restore or once the CLIs answered: reread storage; what is shown must match
-- it: the kind, integration, query and login of the active view are what the block remembers it applied (its snapshot
-- key). Until every CLI answered, an active view that is not listed yet stays the active one.
function M.reloadViews(state: State)
	local boardOn, agentsOn, nowOn = state.boardOn, state.agentsOn, state.nowOn -- switchView leaves Now and the Worktrees and Agents scopes
	loadAll(state)
	local v = M.activeView(state)
	if not v then
		if cli.ready() then
			M.switchView(state, if state.views[1] then state.views[1].id else nil)
			state.boardOn, state.agentsOn, state.nowOn = boardOn, agentsOn, nowOn
		end
	elseif M.snapKey(v, state.activeLogin) ~= state.applied then
		M.changed(state)
	end
	if not state.now.loaded then
		if state.nowOn then
			M.refresh(state) -- Now's first read waits for the CLIs' answers, as the views' does
		else
			M.nowRead(state)
		end
	end
end

-- Every other live block of this runtime follows a change made in `origin`. Closed panes are retired, not rendered.
function M.propagate(origin: State)
	for _, s in running do
		if s ~= origin and M.alive(s) then
			s.scanned = nil
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
	return board.rows(state.board)
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
		removeEntry = worktree.removeEntry,
		dirty = function(path: string, done: (boolean?) -> ())
			for _, r in state.board.rows do
				if r.path == path then
					return worktree.dirty(path, function(dirty: boolean?)
						done(dirty)
					end)
				end
			end
			done(nil)
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
local function readNoted(key: string, rowRepo: string, account: string?, live: () -> boolean, done: (tracker.Issue?, github.Problem?, number?, string, string) -> ())
	local n, repo, ref = parseIssueRef(key, rowRepo)
	if n then
		github.issueItem(repo, n, account, function(issue, problem)
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
				readNoted(key, row.repo, nil, live, function(issue: tracker.Issue?, problem: github.Problem?, n: number?, repo: string, ref: string)
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
	state.boardOn, state.agentsOn, state.nowOn, state.focus = true, false, false, "list"
	M.boardLoad(state) -- every open rereads git: this block's own changes (removals, new worktrees) show at once
	M.boardEnsure(state)
end

-- Shows sidebar scope `scopeId` (render.scopeRows' id: "now", "worktrees", "agents", a pin or a view as one login runs
-- it), as a click on it does. false when the live sidebar has no such scope, so a stale id never jumps anywhere.
function M.goScope(state: State, scopeId: any): boolean
	if scopeId == "worktrees" then
		M.openBoard(state)
		return true
	elseif scopeId == "agents" then
		M.openAgents(state)
		return true
	elseif scopeId == "now" then
		M.openNow(state)
		return true
	end
	for _, scope in M.orderedViews(state) do
		if scope.id == scopeId then
			if ghActive.isActive(state, scope) then
				state.boardOn, state.agentsOn, state.nowOn = false, false, false -- the view already shown: its selection stays
				M.refresh(state) -- a click refreshes it
			else
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
		local id = M.pickerId("w", row.id)
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

-- Moves through the sidebar: Now first, then the views, then the Worktrees and Agents lists.
function M.moveView(state: State, delta: number)
	local items = M.orderedViews(state)
	local other = state.boardOn or state.agentsOn or state.nowOn -- a scope that is no view is shown
	local at = if state.nowOn then 1 elseif state.agentsOn then #items + 3 elseif state.boardOn then #items + 2 else 0
	if not other then
		for i, scope in items do
			if ghActive.isActive(state, scope) then
				at = i + 1
			end
		end
	end
	local to = math.clamp(at + delta, 1, #items + 3)
	if to == 1 then
		if not state.nowOn then
			M.openNow(state)
		end
		return
	elseif to == #items + 3 then
		if not state.agentsOn then
			M.openAgents(state)
		end
		return
	elseif to == #items + 2 then
		if not state.boardOn then
			M.openBoard(state)
		end
		return
	end
	local target = items[to - 1]
	if target and other and ghActive.isActive(state, target) then
		state.boardOn, state.agentsOn, state.nowOn = false, false, false
	elseif target and (other or not ghActive.isActive(state, target)) then
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
								M.nowRead(s) -- Now waited for this answer (its Jira query); a read already running is kept
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

local LOG_CHECKS = 5 -- failing checks whose logs one head commit reads
local LOG_RETRY_S = 300 -- a log that could not be read is read again after this
local LOG_KEEP = 64 -- logs kept per block: past it the cache starts over
-- ponytail: the cache starts over when full rather than evicting the oldest; an LRU if blocks watch many failing PRs.

-- The key of check `r`'s log at head commit `head`; nil for a check that is not a GitHub Actions run.
local function logKey(head: string, r: github.Run): string?
	return if r.runId and r.url then head .. "\0" .. r.url else nil
end

-- The log of check `r` at `head` as last read; nil while it is unread, or failed long enough ago to read again.
function M.ciLog(state: State, head: string, r: github.Run): core.CiLog?
	local key = logKey(head, r)
	local log = if key then state.ciLogs[key] else nil
	if log and log.problem and os.time() - log.at >= LOG_RETRY_S then
		return nil
	end
	return log
end

-- Reads check `r`'s failed log (`gh run view <run> --log-failed --job <job>`), cuts it (logs.parse), finds the lines of
-- `files` it names and keeps that as its CiLog; a read already running for it is waited on, not repeated.
local function readLog(state: State, repo: string, r: github.Run, key: string, files: { string }, done: (core.CiLog) -> ())
	local waiting = state.ciBusy[key]
	if waiting then
		table.insert(waiting, done)
		return
	end
	state.ciBusy[key] = { done }
	github.failedLog(repo, r.runId or "", github.jobIdOf(r.url), M.login(state), function(out, problem)
		local log: core.CiLog = { refs = {}, at = os.time() }
		local lines: { string } = {}
		local parts: { logs.Excerpt } = if out then logs.parse(out) else {}
		for _, ex in parts do
			if #parts > 1 then
				table.insert(lines, "== " .. ex.job .. " ==")
			end
			log.first = log.first or ex.first
			table.move(ex.lines, 1, #ex.lines, #lines + 1, lines)
		end
		if #lines > 0 then
			log.lines, log.refs = lines, logs.refs(lines, files)
		else
			local why = if problem then problem.message elseif out then "gh printed no failed step" else "gh printed nothing"
			log.problem = clip(printable((string.gsub(string.match(why, "^[^\n]*") or why, "[%.%s]+$", ""))), 200)
		end
		local count = 0
		for _ in state.ciLogs do
			count += 1
		end
		if count >= LOG_KEEP then
			state.ciLogs = {}
		end
		state.ciLogs[key] = log
		local waiters: { (core.CiLog) -> () } = state.ciBusy[key] or {}
		state.ciBusy[key] = nil
		for _, w in waiters do
			w(log)
		end
	end)
end

-- The checks of `runs` failing at `head` (at most LOG_CHECKS), each with its excerpt and the changed-file lines it names,
-- or why it has none; done(failures, read) once every log not read yet for this head is in (`read`: some were read,
-- so done ran later). Only an Actions check has a log Plotroom reads.
function M.failures(state: State, repo: string, head: string, runs: { github.Run }, files: { string }, done: ({ logs.Failure }, boolean) -> ())
	local list: { logs.Failure } = {}
	local pending = 0
	local function fill(f: logs.Failure, log: core.CiLog)
		if log.lines then
			f.lines, f.refs = log.lines, log.refs
		else
			f.problem = "Its log could not be read: " .. (log.problem or "") .. "."
		end
	end
	for _, r in runs do
		if r.status == "failure" and #list < LOG_CHECKS then
			local f: logs.Failure = { name = r.name, url = r.url }
			table.insert(list, f)
			local key = logKey(head, r)
			local log = M.ciLog(state, head, r)
			if not key then
				f.problem = "Not a GitHub Actions check: Plotroom read no log."
			elseif log then
				fill(f, log)
			else
				pending += 1
				readLog(state, repo, r, key, files, function(l)
					fill(f, l)
					pending -= 1
					if pending == 0 then
						done(list, true)
					end
				end)
			end
		end
	end
	if pending == 0 then
		done(list, false)
	end
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
			if details.headPr then
				state.noteSeq += 1 -- the picker's cached rows carry the stage, which the worktree branch's PR moves
			end
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
					loaded.headPr, loaded.headLinked = head, linked
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
		-- The failing checks' logs for the preview: read once per check and head commit, so a refresh reads none again.
		if about and about.head then
			M.failures(state, pr.repo, about.head, runs, about.files, function(_, read)
				if read and M.alive(state) then
					state.cx:render()
				end
			end)
		end
		-- The issue Plotroom noted for the worktree on this head branch, as the last worktree scan knew it (a checkout
		-- not scanned yet shows none; the next refresh's scan fills it). Two on one branch: the first noted wins.
		local checkout = storage.checkoutOf(pr.repo)
		local branch = worktree.prBranch(pr.head, pr.fork)
		local noted: string? = nil
		local first = math.huge
		for key, n in state.notes do
			if n.ok and n.kind == "issues" and n.root == checkout and n.branch == branch and n.seq < first then
				noted, first = key, n.seq
			end
		end
		if not noted then
			return land(nil, loaded, "")
		end
		readNoted(noted, pr.repo, M.login(state), live, function(issue)
			loaded.noted = issue
			land(nil, loaded, "")
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
		ahead = if r then r.ahead else nil,
		root = if r then r.root else nil,
		repo = if r then r.repo else nil,
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
	local owner, name = splitRepo(code)
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
function M.issueNames(issue: tracker.Issue, code: string, users: { [string]: string }, snap: { [string]: any }?): (string?, string?, string?)
	local owner, name = splitRepo(code)
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
	local branch, why = tracker.render(formats.issueBranch(code, snap), vars)
	if not branch then
		return nil, nil, why
	end
	local dir, dirWhy = tracker.render(formats.of("issuedir", snap), { key = issue.ref, slug = slug, owner = string.lower(owner or ""), repo = string.lower(name or "") }, true)
	if not dir then
		return nil, nil, dirWhy
	end
	return branch, dir, nil
end

-- How worktree.scan knows `item`'s worktree (a github.Pr, or a tracker.Issue worked in one of `codes`): a pull
-- request's by its head branch, an issue's by the branch the format names now; either by the folder name the format
-- names now.
function M.worktreeWant(state: State, kind: string, item: any, codes: { string }, snap: { [string]: any }?): worktree.Want
	local want: worktree.Want = { branches = {}, dirs = {} }
	if kind ~= "issues" then
		local owner, name = splitRepo(item.repo)
		table.insert(want.branches, worktree.prBranch(item.head, item.fork))
		want.ref = worktree.prRef(owner or "", name or "", item.number)
		local dir = formats.prDir(item.repo, item.number, item.title, snap)
		if dir then
			table.insert(want.dirs, dir)
		end
		return want
	end
	local users = me.of(state, item)
	for _, code in codes do
		local branch, dir = M.issueNames(item, code, users, snap)
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

-- The folder of the selected item's worktree card while it still exists: what Open in Git opens.
function M.cardPath(state: State): string?
	local item = M.selected(state)
	local note = if item then state.notes[item.key] else nil
	local path = if note and note.ok then note.path else nil
	return if path and tern.fs.exists(path) then path else nil
end

-- The card's Open in Git: true when there was a worktree to open.
function M.openGit(state: State): boolean
	if not M.cardPath(state) then
		return false
	end
	state.cx:render() -- the window reads the link from the shown surface
	state.cx:open(core.withToken(core.GIT_LINK))
	return true
end

-- The board's own actions (`act`: a Commands row's id or its key): true when it was one.
function M.boardAct(state: State, act: string): boolean
	local live = aliveFn(state)
	local row = M.boardSelected(state)
	if act == "retry" then
		if not state.boardBusy then
			state.board.details = {} -- Refresh reads the previewed pull request and issue again, not only git
		end
		M.boardLoad(state)
	elseif act == "wt-open" or act == "wt-git" then
		local _, at = M.boardSelected(state)
		if row and not row.missing then
			state.cx:render() -- the window reads the row's link from the shown surface
			state.cx:open(core.withToken(if act == "wt-git" then core.GIT_LINK else "plotroom://worktrees/open/" .. at))
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
		elseif row and not row.locked and not row.missing then
			state.boardRemoving = row.id
		elseif row then
			state.cx:toast("info", "Not removed here", "Locked or missing worktrees are not removed here.")
		end
	elseif act == "wt-remove-finished" then
		if state.boardBusy then
			state.cx:toast("info", "Still reading", "Remove them once the read has finished.")
		else
			local ids: { string } = {}
			for _, r in board.finished(state.board) do
				table.insert(ids, r.id)
			end
			if #ids == 0 then
				state.cx:toast("info", "No finished worktrees", "Run Find finished worktrees first; it marks the merged and closed ones.")
			else
				state.boardFinished = ids
			end
		end
	elseif act == "wt-cancel-remove" then
		state.boardRemoving = nil
		state.boardFinished = nil
	elseif act == "wt-confirm-remove" then
		local id, ids = state.boardRemoving, state.boardFinished
		state.boardRemoving, state.boardFinished = nil, nil
		local function landed()
			M.boardEnsure(state)
			for _, s in running do
				s.scanned = nil -- every block reads its notes from git again
				s.noteSeq += 1
				if s ~= state and M.alive(s) then
					s.cx:render()
				end
			end
			state.cx:render()
		end
		if ids and not state.boardBusy then
			state.boardBusy = true
			board.removeFinished(state.board, M.boardApi(state), ids, live, function(removed: number, kept: number)
				state.boardBusy = false
				state.cx:toast(if removed > 0 then "success" else "error", "Removed " .. removed .. ", kept " .. kept, if kept > 0 then "Kept worktrees have changes or could not be removed; nothing is forced" else nil)
				landed()
			end)
			state.cx:render()
		elseif id and not state.boardBusy then
			state.boardBusy = true
			board.remove(state.board, M.boardApi(state), id, live, function(ok: boolean, message: string)
				state.boardBusy = false
				state.cx:toast(if ok then "success" else "error", if ok then "Worktree removed" else "Worktree not removed", message)
				landed()
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
-- Events within the window share one timer, so a burst renders each block once.
local redrawPending = false
local function redrawQueues()
	if redrawPending then
		return
	end
	redrawPending = true
	tern.timer(250, function()
		redrawPending = false
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
-- A `git …` command finished in a pane inside a worktree some block has a note of: that card is read again at its
-- next render, so its badges follow `git commit` or `git pull` at once. Only the selected card is ever read.
-- ponytail: a read already under way when the command ends may predate it; the next finish or refresh corrects it.
tern.on("command_finished", function(ev: any, _cx: any)
	if type(ev) ~= "table" or type(ev.line) ~= "string" or type(ev.pane) ~= "number" or string.sub(ev.line, 1, 4) ~= "git " then
		return
	end
	local cwd: string? = nil
	for _, p in tern.pane.list() do
		if p.pane == ev.pane then
			cwd = p.cwd
		end
	end
	if not cwd then
		return
	end
	for _, s in running do
		local hit = false
		for _, note in s.notes do
			if note.ok and note.path and worktree.within(cwd, note.path) then
				note.checked = nil
				s.scanned = nil -- the sync badge and update command come from the scan: it runs again too
				hit = true
			end
		end
		if hit and M.alive(s) then
			s.cx:render()
		end
	end
end)
-- The window's report of its agents (`agent-status`: JSON of item key -> { state, action?, branch?, title?, last?, err?,
-- result?, ended?, attention?, reason?, blocker?, outcome?, verdict?, check?, findings?, stop?, since?, expected? }):
-- replaces what the rows show. An optional text that is not a clean string within its cap is dropped, never trusted,
-- and so are `since` and `expected` unless digits.
local INFO_CAPS: { [string]: number } = { action = 120, branch = 200, title = 256, last = 200, err = 200, result = 10, ended = 10, attention = 11, reason = 200, blocker = 200, outcome = 16, verdict = 10, check = 4, findings = 1000, stop = 40, since = 12, expected = 12 }
local DIGITS: { [string]: boolean } = { since = true, expected = true }
function M.agentStatus(state: State, raw: any)
	if type(raw) ~= "string" or #raw > 40000 then
		return
	end
	local ok, decoded = pcall(tern.json.decode, raw)
	if not ok or not isTable(decoded) then
		return
	end
	local map: { [string]: string } = {}
	local infos: { [string]: AgentInfo } = {}
	local count = 0
	for key, value in decoded do
		local clean = triage.sanitizeKey(key)
		local st = if isTable(value) then (value :: any).state else nil
		if clean and (st == "working" or st == "waiting_input" or st == "idle" or st == "exited") and count < 200 then
			map[clean] = st
			local info: { [string]: string } = {}
			for field, cap in INFO_CAPS do
				local text: any = (value :: any)[field]
				if type(text) == "string" and text ~= "" and #text <= cap and not string.find(text, "%c") and not (DIGITS[field] and not string.match(text, "^%d+$")) then
					info[field] = text
				end
			end
			infos[clean] = info :: any
			count += 1
		end
	end
	local same = true
	for k, v in map do
		local was, now = state.agentInfo[k], infos[k]
		same = same and state.agents[k] == v and was ~= nil
		if was then
			for field in INFO_CAPS do
				same = same and (was :: any)[field] == (now :: any)[field]
			end
		end
	end
	for k in state.agents do
		same = same and map[k] ~= nil
	end
	if not same then
		state.agents, state.agentInfo = map, infos
		state.rev += 1
		state.vis = nil
		if state.snap then
			M.ensureCursor(state)
		end
		M.agentEnsure(state)
		M.nowEnsure(state)
		state.cx:render()
	end
end

-- How long the agent of item `key` has worked (seconds; nil: it is not working, or the window gave no start) and how
-- far along it probably is, 0 to 0.95 (nil: its action has too few finished runs to expect a duration): the bar eases
-- toward 90% at the expected duration, then creeps, never full before the run ends. ponytail: the start is on the
-- window's clock, so a remote host whose clock is off shows the difference; send an age instead if that matters.
function M.agentClock(state: State, key: string): (number?, number?)
	local info = state.agentInfo[key]
	local since = if state.agents[key] == "working" and info and info.since then tonumber(info.since) else nil
	if not since then
		return nil, nil
	end
	local elapsed = math.max(0, os.time() - since)
	local expected = if info and info.expected then tonumber(info.expected) else nil
	return elapsed, if expected then math.min(0.95, 1 - math.exp(-2.3 * elapsed / math.max(expected, 1))) else nil
end

-- The Agents scope's rows: every agent not exited, by repository then item key. `repo` is the part of the key before `#`.
function M.agentRows(state: State): { any }
	local rows: { any } = {}
	for key, st in state.agents do
		if st ~= "exited" then
			local info: AgentInfo = state.agentInfo[key] or {}
			table.insert(rows, { key = key, state = st, repo = string.match(key, "^(.-)#") or key, action = info.action, branch = info.branch, title = info.title, last = info.last, err = info.err, result = info.result, ended = info.ended, attention = info.attention, reason = info.reason, blocker = info.blocker, outcome = info.outcome, verdict = info.verdict, check = info.check, findings = info.findings, needs = M.needsYou(state, key) })
		end
	end
	table.sort(rows, function(a: any, b: any): boolean
		return if a.repo ~= b.repo then a.repo < b.repo else a.key < b.key
	end)
	return rows
end

-- The row previewed and its place in the list (nil, 0 when there is none).
function M.agentSelected(state: State): (any, number)
	for i, row in M.agentRows(state) do
		if row.key == state.agentAt then
			return row, i
		end
	end
	return nil, 0
end

-- Keeps the preview on a listed agent while the scope is shown: the first when none is previewed or it went away.
function M.agentEnsure(state: State)
	if state.agentsOn and select(2, M.agentSelected(state)) == 0 then
		local first = M.agentRows(state)[1]
		state.agentAt = if first then first.key else nil
	end
end

-- Moves the previewed agent `delta` rows, clamped to the list.
function M.agentMove(state: State, delta: number)
	local rows = M.agentRows(state)
	if #rows > 0 then
		local _, at = M.agentSelected(state)
		state.agentAt = rows[math.clamp(math.max(at, 1) + delta, 1, #rows)].key
	end
end

-- Shows the Agents scope instead of a view or the Worktrees list.
function M.openAgents(state: State)
	state.agentsOn, state.boardOn, state.nowOn, state.focus = true, false, false, "list"
	M.agentEnsure(state)
end

-- The link the window follows for agent command `act` (agentgo, the default; agentint | agentstop | agentmsg) on item
-- `key` ("repo#ref"): a pull request's or GitHub issue's number, or a Jira issue's key (its project upper case, as the
-- window's issue links take it). nil for a key that is neither.
function M.agentHref(key: string, act: string?): string?
	local verb = act or "agentgo"
	local repo, n = string.match(key, "^([^/#]+/[^/#]+)#(%d+)$")
	if repo and n then
		return core.withToken("plotroom://github/" .. verb .. "/" .. repo .. "/" .. n)
	end
	local project, ref = string.match(key, "^([^#]+)#([%w_%-]+)$")
	if project and ref and not string.find(project, "/", 1, true) then
		return core.withToken("plotroom://issue/" .. verb .. "/" .. string.upper(project) .. "/" .. ref)
	end
	return nil
end

-- Runs agent command `act` (agentgo by default) on the previewed agent: the window follows the link its hidden node carries.
function M.agentGo(state: State, act: string?)
	local row = M.agentSelected(state)
	local href = if row then M.agentHref(row.key, act) else nil
	if href then
		state.cx:open(href)
	end
end

-- Runs agent command `act` (agentgo | agentreply) on the previewed Now row while its agent needs input: the window
-- follows the link Now's preview carries. false when the row is no such agent.
function M.nowAgent(state: State, act: string): boolean
	local row = M.nowSelected(state)
	local href = if row and row.rank == 1 and row.key and (act ~= "agentreply" or row.waiting) then M.agentHref(row.key, act) else nil
	if href then
		state.cx:open(href)
	end
	return href ~= nil
end

-- Now: everything that needs you, ranked. Its sources are fixed searches per signed-in gh login (the open pull requests
-- it wrote and is asked to review, the open issues assigned to it, with who changed them lately), Jira's open work
-- assigned to you while acli is on (the open sprint's, as My sprint reads it, while the site has sprints), and the unread
-- notifications every signed-in login takes part in; the agents come live from the window. Settings › Views › Now
-- switches reasons and accounts off (now.prefs): what is off is not read at all.
local NOW_MINE = "is:open author:@me archived:false"
local NOW_REVIEW = "is:open user-review-requested:@me draft:false archived:false"
local NOW_REVIEW_TEAMS = "is:open review-requested:@me draft:false archived:false" -- your teams' requests too
-- Reviews of yours that were dismissed ask for it again; GitHub's search has no qualifier for them, so these are kept
-- only where your latest review is dismissed. ponytail: every open PR you reviewed is read; narrow if it costs.
local NOW_DISMISSED = "is:open reviewed-by:@me -author:@me draft:false archived:false"
local NOW_ASSIGNED = "is:open assignee:@me archived:false"
local NOW_JIRA = "assignee = currentUser() AND statusCategory != Done"
local NOW_LABEL: { [string]: string } = { mine = "Your pull requests", review = "Review requests", assigned = "Assigned issues", notices = "Notifications" }

-- When assigned `issue` was last seen (its triage entry's time), nil when it never was (New).
local function seenAt(store: triage.Store, issue: any): number?
	local key = triage.sanitizeKey(issue.key)
	local e = if key then store.items[key] else nil
	return if e and e.seen ~= nil then e.at else nil
end

-- What Jira's answer about `issue` (jira.yours) holds for: the issue as it is now and when it was last seen.
local function yoursMark(store: triage.Store, issue: any): string
	return triage.signature("issues", issue) .. "|" .. tostring(seenAt(store, issue))
end

-- Reads Now's sources once, while none is being read. A source that cannot be read keeps its last answer and says why
-- (`now.problems`); a login GitHub's cooldown holds is not asked. Nothing falls back to another login: a login whose
-- notifications cannot be read keeps its own last ones. While a sign-in failure or a missing CLI holds the block, Now is
-- not read either: only Refresh tries again, as for the views. While the Jira site's sprints are being asked, Now waits
-- for the answer (probeClis reads it then): which Jira query it reads depends on it.
-- ponytail: a search failing for one login keeps that whole source's last answer; merge per login if several logins
-- fail apart often. A held sign-in pauses all of Now, not just that integration's sources.
function M.nowRead(state: State)
	local now = state.now
	local held = state.problem
	if now.busy or not M.alive(state) or not cli.ready() or cli.sprintsAsking or (held and (held.kind == "auth" or held.kind == "missing")) then
		return
	end
	now.busy = true
	now.prefs, now.prefsProblem = storage.readNow()
	local prefs = now.prefs
	local function on(reason: string): boolean
		return not prefs.off[reason]
	end
	ghActive.note(state, true) -- learns the signed-in logins for the next read
	local gen = now.gen
	local fresh: { [string]: { any } } = { mine = {}, review = {}, assigned = {}, notices = {} }
	local teams: { [string]: string } = {}
	local finder: { [string]: string } = {}
	local kept: { [string]: boolean } = {}
	local problems: { string } = {}
	local spent = 0
	local pending = 1
	local asked = false
	local function live(): boolean
		return M.alive(state) and gen == now.gen
	end
	local function say(which: string, who: string?, why: string)
		local line = NOW_LABEL[which] .. (if who then " (@" .. who .. ")" else "") .. ": " .. why
		if not table.find(problems, line) then
			table.insert(problems, line)
		end
	end
	local function fail(which: string, who: string?, why: string)
		kept[which] = true
		say(which, who, why)
	end
	-- One login's notifications that could not be read: it says why and keeps its own last ones.
	local function noticesFail(who: string, why: string)
		say("notices", who, why)
		for _, n in now.notices do
			if n.login == who then
				table.insert(fresh.notices, n)
			end
		end
	end
	local function settle()
		pending -= 1
		if pending > 0 or not live() then
			return -- a Mark read since this read began: its answer is older than the marks
		end
		local store = M.store(state)
		if not asked and not kept.assigned and store then
			-- Jira's New or Changed assigned issues: was the newest change your own? A "yours" answer is asked again
			-- every read (someone may have acted since); any other holds while the issue and its seen time do.
			asked = true
			local clock = os.time()
			for _, issue in fresh.assigned do
				local mark = yoursMark(store, issue)
				local had = now.yours[issue.key]
				if issue.tracker == "jira" and triage.status(store, "issues", issue, clock).fresh ~= "seen" and not (had and had.mark == mark and had.yours ~= true) then
					pending += 1
					jira.yours(issue.ref, seenAt(store, issue), function(yours: boolean?)
						now.yours[issue.key] = { mark = mark, yours = yours }
						settle()
					end)
				end
			end
			if pending > 0 then
				return
			end
		end
		local into = now :: any
		for _, which in { "mine", "review", "assigned", "notices" } do
			if not kept[which] then
				into[which] = fresh[which]
			end
		end
		if not kept.assigned then
			now.finder = finder
		end
		if not kept.review then
			now.teams = teams
		end
		local yours: { [string]: { mark: string, yours: boolean? } } = {}
		for _, issue in now.assigned do
			yours[issue.key] = now.yours[issue.key]
		end
		now.yours = yours
		now.busy, now.loaded, now.problems, now.cost, now.seq = false, true, problems, spent, now.seq + 1
		M.nowEnsure(state)
		state.cx:render()
	end
	local function search(which: string, account: string?, query: string, integration: string?, me: string?, dismissed: boolean?)
		pending += 1
		local asTeam = which == "review" and prefs.teams and not dismissed
		local function landed(result: any, problem: github.Problem?, cost: number)
			spent += cost or 0
			if result then
				for _, it in (if integration then result.issues else result.prs) do
					if dismissed and it.yourReview ~= "dismissed" then
						continue
					end
					table.insert(fresh[which], it)
					if integration == "github" and me and me ~= "" then
						finder[it.key] = me
					end
					-- A request asked of a team and not of you: the preview's Why line names the team.
					local direct = false
					for _, who in it.reviewers or {} do
						direct = direct or (me ~= nil and string.lower(who) == string.lower(me))
					end
					if asTeam and not direct and it.teams and #it.teams > 0 then
						teams[it.key] = "@" .. table.concat(it.teams, ", @")
					end
				end
			else
				fail(which, if integration == "jira" then nil else account or ghActive.login, if problem then problem.message else "It could not be read.")
			end
			settle()
		end
		if integration == "github" then
			github.issues(account, query, live, landed, true) -- with who changed each lately (nowRows)
		elseif integration then
			TRACKERS[integration].search(account, query, live, landed)
		else
			github.search(account, query, live, landed, asTeam)
		end
	end
	local function notices(who: string)
		pending += 1
		local function read(login: string)
			github.notifications(login, function(rows: { github.Notice }?, why: github.Problem?)
				if rows then
					for _, n in rows do
						table.insert(fresh.notices, n)
					end
					if #rows >= github.NOTICE_CAP then
						say("notices", login, "showing the newest " .. github.NOTICE_CAP .. "; the rest are on github.com")
					end
				else
					noticesFail(login, if why then why.message else "They could not be read.")
				end
				settle()
			end)
		end
		if who ~= "" then
			return read(who)
		end
		github.login(nil, function(found: string?, problem: github.Problem?)
			if not found then
				fail("notices", nil, if problem then problem.message else "gh's active login is unknown.")
				return settle()
			end
			read(found)
		end)
	end
	if cli.on("github") then
		local logins: { string } = if #ghActive.accounts > 0 then ghActive.accounts else { "" }
		for _, who in logins do
			local me = if who ~= "" then who else ghActive.login
			if me and prefs.logins[string.lower(me)] then
				continue -- switched off: not searched, its notifications not read
			end
			local account = if who == "" or who == ghActive.login then nil else who
			local wait = github.wait(os.time(), account)
			-- What this login is asked for, as the reasons switched on need: Blocked and Ready to merge share one search.
			local wants: { string } = {}
			if on("blocked") or on("ready") then
				table.insert(wants, "mine")
			end
			if on("review") then
				table.insert(wants, "review")
			end
			if on("assigned") then
				table.insert(wants, "assigned")
			end
			if wait > 0 then
				local why = "GitHub's rate limit is reached; read again after " .. os.date("%H:%M", os.time() + wait) .. "."
				for _, which in wants do
					fail(which, account, why)
				end
				if not on("notices") then
					continue
				elseif who ~= "" then
					noticesFail(who, why)
				else
					fail("notices", nil, why)
				end
			else
				for _, which in wants do
					if which == "mine" then
						search("mine", account, NOW_MINE, nil)
					elseif which == "review" then
						search("review", account, if prefs.teams then NOW_REVIEW_TEAMS else NOW_REVIEW, nil, me)
						search("review", account, NOW_DISMISSED, nil, me, true)
					else
						search("assigned", account, NOW_ASSIGNED, "github", me)
					end
				end
				if on("notices") then
					notices(who)
				end
			end
		end
	end
	if cli.on("jira") and prefs.jira and on("assigned") then
		search("assigned", nil, if cli.sprints == true then core.MY_SPRINT else NOW_JIRA, "jira")
	end
	settle()
end

-- Whether you made every change that makes assigned `issue` New or Changed, so Now leaves it out. GitHub: the events
-- since you last saw it (New: since its newest assignment to the login that found it) are all that login's, and none
-- of its later updates is left unexplained by them. Jira: jira.yours said so for the issue as it is now. What cannot be
-- read (no events, a cut timeline, no answer) is not yours: the row is listed.
local function ownChange(now: any, store: triage.Store, issue: any): boolean
	if issue.tracker == "jira" then
		local had = now.yours[issue.key]
		return had ~= nil and had.yours == true and had.mark == yoursMark(store, issue)
	end
	local found: string?, events: { tracker.Event }? = now.finder[issue.key], issue.events
	if not found or not events or #events == 0 then
		return false
	end
	local me = string.lower(found)
	local start = seenAt(store, issue)
	if not start then
		for _, e in events do
			if e.to and string.lower(e.to) == me and (not start or e.at > start) then
				start = e.at
			end
		end
	end
	if not start then
		return false
	end
	local newest, oldest, mine = 0, math.huge, false
	for _, e in events do
		newest, oldest = math.max(newest, e.at), math.min(oldest, e.at)
		if e.at >= start then
			if not e.by or string.lower(e.by) ~= me then
				return false
			end
			mine = true
		end
	end
	local cut = #events >= github.TIMELINE and oldest >= start -- older changes since then may not have been read
	return mine and not cut and issue.updated <= newest + 60
end

-- Now's rows, top first; each is { id, key?, rank, why?, kind?, item?, notice?, agent?, waiting?, title, url?, snoozed }.
-- Ranks: 1 an agent needs you (needsYou; `waiting`: it waits for input), 2 your pull request is Blocked (`why` says by
-- what), 3 your review is requested (oldest first; `why` names the teams it was asked of when not of you), 4 your pull
-- request is Ready to merge, 5 an unread notification you take part in, 6 an issue assigned to you is New or Changed
-- (`why`). A reason switched off in Settings › Views › Now lists nothing. An item is listed once, at its highest rank; a
-- snoozed one only while snoozed items are shown (an agent that needs you is always listed, as in the views).
function M.nowRows(state: State): { any }
	local now = state.now
	local clock = os.time()
	local cacheKey = now.seq .. "|" .. state.rev .. "|" .. tostring(state.showSnoozed) .. "|" .. (clock // 60)
	if now.rows and now.rowsKey == cacheKey then
		return now.rows
	end
	local store = M.store(state)
	local rows: { any } = {}
	local taken: { [string]: boolean } = {}
	local known: { [string]: { item: any, kind: string } } = {}
	for _, pr in now.mine do
		known[pr.key] = { item = pr, kind = "prs" }
	end
	for _, pr in now.review do
		known[pr.key] = { item = pr, kind = "prs" }
	end
	for _, issue in now.assigned do
		known[issue.key] = { item = issue, kind = "issues" }
	end
	local REASON_OF = { "", "blocked", "review", "ready", "notices", "assigned" }
	local off = now.prefs.off
	local function add(rank: number, kind: string?, item: any, why: string?)
		if taken[item.key] or off[REASON_OF[rank]] then
			return -- a reason switched off lists nothing, even before Now is read again
		end
		taken[item.key] = true
		local snoozed = store ~= nil and triage.snoozed(store, item, clock)
		if snoozed and not state.showSnoozed then
			return
		end
		table.insert(rows, { id = M.pickerId("n", item.key), key = item.key, rank = rank, why = why, kind = kind, item = item, title = item.title, url = item.url, snoozed = snoozed })
	end
	local waiting: { string } = {}
	for key in state.agents do
		if M.needsYou(state, key) then
			table.insert(waiting, key)
		end
	end
	table.sort(waiting)
	for _, key in waiting do
		local info: AgentInfo = state.agentInfo[key] or {}
		local found = known[key]
		taken[key] = true
		table.insert(rows, {
			id = M.pickerId("n", key),
			key = key,
			rank = 1,
			kind = if found then found.kind else nil,
			item = if found then found.item else nil,
			agent = info,
			waiting = state.agents[key] == "waiting_input", -- else idle: its report or its outcome check needs you
			title = if found then found.item.title elseif info.title then info.title else key,
			url = if found then found.item.url else nil,
			snoozed = false,
		})
	end
	local function newest(a: any, b: any): boolean
		return if a.updated ~= b.updated then a.updated > b.updated else a.key < b.key
	end
	local blocked: { any } = {}
	local ready: { any } = {}
	local why: { [string]: string } = {}
	for _, pr in now.mine do
		local stage, because = M.stage(state, "prs", pr)
		if stage == "blocked" then
			table.insert(blocked, pr)
			why[pr.key] = because or "Blocked"
		elseif stage == "ready" then
			table.insert(ready, pr)
		end
	end
	table.sort(blocked, newest)
	table.sort(ready, newest)
	local review: { github.Pr } = {}
	for _, pr in now.review do
		table.insert(review, pr)
	end
	table.sort(review, function(a: github.Pr, b: github.Pr): boolean
		return if a.created ~= b.created then a.created < b.created else a.key < b.key
	end)
	for _, pr in blocked do
		add(2, "prs", pr, why[pr.key])
	end
	for _, pr in review do
		add(3, "prs", pr, now.teams[pr.key]) -- `why`: the teams it was asked of, when not of you
	end
	for _, pr in ready do
		add(4, "prs", pr, nil)
	end
	local notices: { github.Notice } = {}
	for _, n in now.notices do
		table.insert(notices, n)
	end
	table.sort(notices, function(a: github.Notice, b: github.Notice): boolean
		return if a.updated ~= b.updated then a.updated > b.updated else a.id < b.id
	end)
	local shown: { github.Notice } = if off.notices then {} else notices
	for _, n in shown do
		local key = if n.number then string.lower(n.repo) .. "#" .. n.number else nil
		if not key then
			table.insert(rows, { id = "t" .. n.id, rank = 5, notice = n, title = n.title, snoozed = false })
		elseif not taken[key] then
			local found = known[key]
			taken[key] = true
			local item = if found then found.item else { key = key }
			local snoozed = store ~= nil and triage.snoozed(store, item, clock)
			if not snoozed or state.showSnoozed then
				table.insert(rows, { id = M.pickerId("n", key), key = key, rank = 5, notice = n, kind = if found then found.kind else nil, item = if found then found.item else nil, title = n.title, url = n.url, snoozed = snoozed })
			end
		end
	end
	local assigned: { any } = {}
	for _, issue in now.assigned do
		local st = if store then triage.status(store, "issues", issue, clock) else nil
		if st and st.fresh ~= "seen" and not ownChange(now, store :: triage.Store, issue) then
			why[issue.key] = if st.fresh == "new" then "New" else "Changed"
			table.insert(assigned, issue)
		end
	end
	table.sort(assigned, newest)
	for _, issue in assigned do
		add(6, "issues", issue, why[issue.key])
	end
	now.rows, now.rowsKey = rows, cacheKey
	return rows
end

-- How many need you: Now's rows that are not snoozed. What the sidebar's Now entry and the window's status line show.
function M.nowCount(state: State): number
	local n = 0
	for _, row in M.nowRows(state) do
		if not row.snoozed then
			n += 1
		end
	end
	return n
end

-- What needs you, by kind, in Now's rank order: `2 agents need you · 1 Blocked · 3 reviews requested`; nil when nothing
-- does. Snoozed rows are left out, as in nowCount. The pane title and Now's heading say it.
local SUMMARY: { { one: string, many: string } } = {
	{ one = "agent needs you", many = "agents need you" },
	{ one = "Blocked", many = "Blocked" },
	{ one = "review requested", many = "reviews requested" },
	{ one = "Ready to merge", many = "Ready to merge" },
	{ one = "notification", many = "notifications" },
	{ one = "assigned: new or changed", many = "assigned: new or changed" },
}
function M.nowSummary(state: State): string?
	local counts: { number } = { 0, 0, 0, 0, 0, 0 }
	for _, row in M.nowRows(state) do
		if not row.snoozed then
			counts[row.rank] += 1
		end
	end
	local parts: { string } = {}
	for rank, n in counts do
		if n > 0 then
			table.insert(parts, n .. " " .. (if n == 1 then SUMMARY[rank].one else SUMMARY[rank].many))
		end
	end
	return if #parts > 0 then table.concat(parts, " · ") else nil
end

-- The row previewed and its place in the list (nil, 0 when there is none).
function M.nowSelected(state: State): (any, number)
	for i, row in M.nowRows(state) do
		if row.id == state.nowAt then
			return row, i
		end
	end
	return nil, 0
end

-- Keeps the preview on a listed row while Now is shown: the first when none is previewed or it went away.
function M.nowEnsure(state: State)
	if state.nowOn and select(2, M.nowSelected(state)) == 0 then
		local first = M.nowRows(state)[1]
		state.nowAt = if first then first.id else nil
	end
end
nowEnsure = M.nowEnsure

-- Moves the previewed row `delta` rows, clamped to the list. A hand move: it stops Next in Now's walk.
function M.nowMove(state: State, delta: number)
	local rows = M.nowRows(state)
	if #rows > 0 then
		local _, at = M.nowSelected(state)
		state.nowAt = rows[math.clamp(math.max(at, 1) + delta, 1, #rows)].id
	end
	M.nowStop(state)
end

-- Now as a Board: its columns in order, each listing Now's rows (nowRows' order kept) by their item's stage. The last
-- two are the fold. A row with no item (an agent or a notification Now holds no item for) is in Needs you: Now lists it
-- because it needs you.
M.NOW_COLUMNS = {
	{ id = "needs", label = "Needs you" },
	{ id = "working", label = "Agent working" },
	{ id = "waiting", label = "Waiting" },
	{ id = "ready", label = "Ready to merge" },
	{ id = "none", label = "Not started", fold = true },
	{ id = "worktree", label = "Worktree", fold = true },
}
local COLUMN_OF: { [string]: string } = { needs = "needs", blocked = "needs", working = "working", pr = "waiting", ready = "ready", none = "none", worktree = "worktree" }
-- The narrowest block, in terminal columns, that lays Now out as a Board; a narrower one shows the List. Measured in
-- real Tern (c226): below about 80 columns a card's number and why it is listed no longer fit its column.
M.BOARD_MIN_COLS = 80

-- The Board's columns, { id, label, fold?, rows }, built once per nowRows answer.
function M.nowColumns(state: State): { any }
	local now = state.now
	local rows = M.nowRows(state)
	if now.cols and now.colsOf == rows then
		return now.cols :: { any }
	end
	local cols: { any } = {}
	local at: { [string]: any } = {}
	for _, c in M.NOW_COLUMNS do
		local col = { id = c.id, label = c.label, fold = c.fold, rows = {} }
		table.insert(cols, col)
		at[c.id] = col
	end
	for _, row in rows do
		local stage = if row.item and row.kind then (M.stage(state, row.kind, row.item)) else nil
		table.insert(at[COLUMN_OF[stage or ""] or "needs"].rows, row)
	end
	now.cols, now.colsOf = cols, rows
	return cols
end

-- Whether Now shows as a Board: chosen, and the block wide enough.
function M.nowBoardShown(state: State): boolean
	return state.nowOn and state.nowBoard and state.cx.cols >= M.BOARD_MIN_COLS
end

-- The selected row's column and place in it (0, 0 when none is selected).
function M.nowBoardAt(state: State): (number, number)
	for c, col in M.nowColumns(state) do
		for i, row in col.rows do
			if row.id == state.nowAt then
				return c, i
			end
		end
	end
	return 0, 0
end

-- Moves the Board's selection `dy` rows in its column, or `dx` columns across to the nearest column with rows, at the
-- same place or its last row. A move into the fold opens it.
function M.nowBoardMove(state: State, dx: number, dy: number)
	local cols = M.nowColumns(state)
	local c, i = M.nowBoardAt(state)
	if c == 0 then
		M.nowEnsure(state)
		c, i = M.nowBoardAt(state)
		if c == 0 then
			return
		end
	end
	if dy ~= 0 then
		local list = cols[c].rows
		i = math.clamp(i + dy, 1, #list)
	end
	if dx ~= 0 then
		local step = if dx < 0 then -1 else 1
		local to = c + step
		while cols[to] and #cols[to].rows == 0 do
			to += step
		end
		if cols[to] then
			c, i = to, math.min(i, #cols[to].rows)
		end
	end
	state.nowAt = cols[c].rows[i].id
	if cols[c].fold then
		state.nowFold = true
	end
end

-- Stops Next in Now's walk (the selection was moved by hand); its next step resumes from the selected row.
function M.nowStop(state: State)
	if state.nowWalk then
		state.nowWalk.at = nil
	end
end

-- Now's list as its row ids in order: a walk stops when it changes.
local function nowSig(rows: { any }): string
	local ids: { string } = {}
	for _, row in rows do
		table.insert(ids, row.id)
	end
	return table.concat(ids, "\n")
end

-- The selected row's place in Now while Next in Now walks on it, else nil. The walk stops for good once the selection
-- left the row it selected or the list changed under it.
function M.nowWalking(state: State): number?
	local walk = state.nowWalk
	if not walk or not walk.at or not state.nowOn then
		return nil
	end
	local rows = M.nowRows(state)
	local _, at = M.nowSelected(state)
	if walk.at ~= state.nowAt or at == 0 or walk.sig ~= nowSig(rows) then
		walk.at = nil
		return nil
	end
	return at
end

-- Next in Now: shows Now, then selects its first row, then each following one in its ranking; a stopped walk resumes
-- after the selected row. Past the last row it stays there and says so.
function M.nowNext(state: State): boolean
	if not state.nowOn then
		M.openNow(state)
	end
	state.focus = "list"
	local rows = M.nowRows(state)
	if #rows == 0 then
		if state.now.loaded then
			state.cx:toast("info", "Nothing needs you", "Now lists nothing right now.")
		end
		return true
	end
	local _, at = M.nowSelected(state)
	local to = if state.nowWalk == nil then 1 else at + 1
	if to > #rows then
		to = #rows
		state.cx:toast("info", "Last in Now", "Nothing comes after it.")
	end
	state.nowAt = rows[to].id
	state.nowWalk = { at = state.nowAt, sig = nowSig(rows) }
	return true
end

-- Shows Now instead of a view, and reads it. A walk of Next in Now starts over.
function M.openNow(state: State)
	state.nowOn, state.agentsOn, state.boardOn, state.focus = true, false, false, "list"
	state.nowWalk = nil
	M.nowEnsure(state)
	M.nowRead(state)
end

-- Now's switches changed (Settings › Views › Now, in `origin`): every live block rereads them, drops what is now off at
-- once and reads Now again, a read begun before the change being ignored.
function M.nowPrefsChanged(origin: State)
	for _, s in running do
		if M.alive(s) then
			local now = s.now
			now.prefs, now.prefsProblem = storage.readNow()
			now.gen += 1
			now.busy = false
			now.seq += 1
			M.nowEnsure(s)
			M.nowRead(s)
			if s ~= origin then
				s.cx:render()
			end
		end
	end
end

-- A palette command of the window about triage (`triage` event).
function M.triageEvent(state: State, value: any)
	if value == "seen" or value == "snooze" or value == "unsnooze" then
		M.mark(state, value)
	elseif value == "toggle-snoozed" then
		M.toggle(state, "snoozed")
	end
end

return M
