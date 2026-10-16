--!strict
-- The window's workflow flows: agent links (which agent pane works on which item, kept in kv `agent-links`, and the
-- timer that tells each Plotroom block how those agents are doing), the guided mutations (assign, labels, Jira
-- transition, re-run, draft PR, export, import: always plan, Cancel-first confirm, commit), Open item by URL and the
-- commands the command palette lists. window.luau injects what it owns (`setup`), so there is no require cycle.

local M = {}

export type Env = {
	ask: (cx: WindowCx, pane: number, op: string, args: { [string]: any }, ms: number, done: (any, WindowCx) -> ()) -> boolean,
	isPlotroom: (cx: WindowCx, pane: number) -> boolean,
	readNode: (cx: WindowCx, pane: number, id: string) -> any?,
	nodeProp: (node: any, prop: string) -> any?,
	sourceSession: (cx: WindowCx, pane: number) -> number?,
	targetPane: (cx: WindowCx, path: string) -> (number?, number?, number?),
	launch: (cx: WindowCx) -> number?,
	-- Follows the hidden link node `nodeId` of `pane` (the same validation as a click on it); `missing` is said when
	-- the node has none.
	follow: (cx: WindowCx, pane: number, nodeId: string, missing: string?) -> (),
}

-- A Plotroom block's host: Tern's slot id and its address ("" for this machine), the name only for people.
type HostId = { id: number, name: string, address: string }
type Link = { key: string, agent: number, host: HostId, at: number }
type Plan = { token: string, head: string, label: string, lines: { string } }

local LINKS_KEY = "agent-links"
local LINKS_CAP = 200
local SYNC_MS = 4000
local ACT_MS = 30 * 1000
local COMMIT_MS = 3 * 60 * 1000
local DRAFT_MS = 3 * 60 * 1000 -- the host's ls-remote/fetch may take 120 s
local OPEN_URL_TRIES = 20 -- of 500 ms: a launched block has 10 seconds to say its protocol
local OPEN_URL_STEP_MS = 500
local MAX_TITLE = 256
local MAX_BODY = 8000
local MAX_ROWS = 40
local AGENTGO_NODE = "layer.queue.buttons.agentgo"
local WTOPEN_NODE = "layer.queue.buttons.wtopen"

local env: Env? = nil

function M.setup(e: Env)
	env = e
end

local function e(): Env
	return env :: Env
end

local function problemOf(a: any): string?
	return if type(a.problem) == "string" then a.problem else nil
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

-- ---------------------------------------------------------------- agent links

local STATES = { working = "working", waiting_input = "needs input", idle = "idle", exited = "exited" }

function M.stateLabel(state: string): string
	return STATES[state] or state
end

-- The host of the block `pane`: nil when no host lists it.
local function hostOf(cx: WindowCx, pane: number): HostId?
	local ok, hosts = pcall(function()
		return cx.hosts:list()
	end)
	if not ok or type(hosts) ~= "table" then
		return nil
	end
	for _, h in hosts do
		if type(h.panes) == "table" and table.find(h.panes, pane) then
			return {
				id = h.id,
				name = if type(h.name) == "string" then string.sub(h.name, 1, 128) else "",
				address = if type(h.address) == "string" then string.sub(h.address, 1, 256) else "",
			}
		end
	end
	return nil
end

local function hostSame(a: HostId, b: HostId): boolean
	return a.id == b.id and a.address == b.address
end

local function linkOf(row: any): Link?
	if type(row) ~= "table" or type(row.key) ~= "string" or row.key == "" or #row.key > 200 or type(row.agent) ~= "number" or type(row.at) ~= "number" then
		return nil
	end
	local h = row.host
	if type(h) ~= "table" or type(h.id) ~= "number" or type(h.name) ~= "string" or type(h.address) ~= "string" then
		return nil
	end
	return { key = row.key, agent = row.agent, host = { id = h.id, name = h.name, address = h.address }, at = row.at }
end

-- The saved links, newest first, and whether the store was readable: a store that is not (a failing read, a value
-- that is not a list of links) is never written over.
local function readLinks(): ({ Link }, boolean)
	local ok, v = pcall(tern.kv.get, LINKS_KEY)
	if not ok then
		return {}, false
	elseif v == nil then
		return {}, true
	elseif type(v) ~= "table" then
		return {}, false
	end
	local out: { Link } = {}
	for _, row in v do
		local l = linkOf(row)
		if not l then
			return {}, false
		end
		table.insert(out, l)
	end
	return out, true
end

local function writeLinks(links: { Link }): boolean
	local rows: { any } = {}
	for i = 1, math.min(#links, LINKS_CAP) do
		local l = links[i]
		table.insert(rows, { key = l.key, agent = l.agent, host = { id = l.host.id, name = l.host.name, address = l.host.address }, at = l.at })
	end
	return (pcall(tern.kv.set, LINKS_KEY, tern.json.array(rows)))
end

-- pane -> state of every agent block now listed; nil when the list cannot be read.
local function agentStates(cx: WindowCx): { [number]: string }?
	local ok, list = pcall(function()
		return cx.agents:list()
	end)
	if not ok or type(list) ~= "table" then
		return nil
	end
	local out: { [number]: string } = {}
	for _, a in list do
		if type(a) == "table" and type(a.pane) == "number" then
			out[a.pane] = if type(a.state) == "string" and STATES[a.state] then a.state else "idle"
		end
	end
	return out
end

local function plotroomPanes(cx: WindowCx): { number }
	local out: { number } = {}
	for _, p in cx.session:panes() do
		if e().isPlotroom(cx, p.pane) then
			table.insert(out, p.pane)
		end
	end
	table.sort(out)
	return out
end

-- key -> state for the links recorded on `host` (the newest link of a key counts); an agent pane no longer listed is
-- exited.
local function statusMap(links: { Link }, host: HostId, states: { [number]: string }): { [string]: string }
	local map: { [string]: string } = {}
	local count = 0
	for _, l in links do
		if map[l.key] == nil and hostSame(l.host, host) and count < LINKS_CAP then
			map[l.key] = states[l.agent] or "exited"
			count += 1
		end
	end
	return map
end

local function signature(map: { [string]: string }): string
	local keys: { string } = {}
	for k in map do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts: { string } = {}
	for _, k in keys do
		table.insert(parts, k .. "=" .. map[k] .. ";")
	end
	return table.concat(parts, "")
end

-- Tells each Plotroom block the full state map of its host's agents whenever the block's own acknowledgement
-- (hidden `main.agents`: the signature of the map it holds) is absent or differs, so a reloaded host is told again.
function M.agentSync(cx: WindowCx)
	local panes = plotroomPanes(cx)
	if #panes == 0 then
		return
	end
	local links = readLinks()
	local states = agentStates(cx)
	if not states then
		return
	end
	for _, pane in panes do
		local host = hostOf(cx, pane)
		if host then
			local map = statusMap(links, host, states)
			local sig = signature(map)
			local ack = e().nodeProp(e().readNode(cx, pane, "main.agents"), "text")
			if ack ~= sig and not (ack == nil and sig == "") then
				pcall(function()
					cx.session:event(pane, { ev = "action", act = "agent-status", value = tern.json.encode(map) })
				end)
			end
		end
	end
end

local timer: TimerHandle? = nil

-- Whether there is anything to tell: a Plotroom block and a link.
local function active(cx: WindowCx): boolean
	if #plotroomPanes(cx) == 0 then
		return false
	end
	local links = readLinks()
	return #links > 0
end

local function tick(cx: WindowCx?)
	timer = nil
	if not cx then
		return -- the window went away: the next window_start, pane_created or link starts it again
	end
	M.agentSync(cx)
	if active(cx) then
		timer = tern.timer(SYNC_MS, tick)
	end
end

-- Starts the status timer when it is not running and there is something to tell.
function M.ensureSync(cx: WindowCx)
	if timer == nil and active(cx) then
		timer = tern.timer(SYNC_MS, tick)
	end
end

-- Records that agent block `agent`, started from the Plotroom block `pane`, works on `key`. No link when the two are
-- not on the same host, or the saved links cannot be read.
function M.recordAgent(cx: WindowCx, pane: number, key: string, agent: number)
	local host, agentHost = hostOf(cx, pane), hostOf(cx, agent)
	if not host or not agentHost or not hostSame(host, agentHost) then
		return
	end
	local links, healthy = readLinks()
	if not healthy then
		return cx:toast("info", "Agent started, but not linked to " .. key, "The saved agent links could not be read.")
	end
	local out: { Link } = { { key = key, agent = agent, host = host, at = math.floor(tern.now()) } }
	for _, l in links do
		if not (l.key == key and hostSame(l.host, host)) then
			table.insert(out, l)
		end
	end
	if not writeLinks(out) then
		return cx:toast("info", "Agent started, but not linked to " .. key, "The agent links could not be saved.")
	end
	pcall(function()
		cx.session:event(pane, { ev = "action", act = "agent-link", value = tern.json.encode({ key = key, agent = agent }) })
	end)
	M.agentSync(cx)
	M.ensureSync(cx)
end

-- The newest link for `key` on `pane`'s host, and its state; nil link when none, with state "exited" for one whose
-- agent is gone.
function M.liveAgent(cx: WindowCx, pane: number, key: string): (Link?, string?)
	local host = hostOf(cx, pane)
	local states = agentStates(cx)
	if not host or not states then
		return nil, nil
	end
	for _, l in (readLinks()) do
		if l.key == key and hostSame(l.host, host) then
			local state = states[l.agent] or "exited"
			return if state == "exited" then nil else l, state
		end
	end
	return nil, nil
end

-- Switches to the exact agent pane recorded for `key` and focuses it.
function M.goAgent(cx: WindowCx, pane: number, key: string)
	local link = M.liveAgent(cx, pane, key)
	if not link then
		return cx:toast("info", "No agent is running for " .. key)
	end
	local session = e().sourceSession(cx, link.agent)
	if not session then
		return cx:toast("info", "The agent for " .. key .. " is not in a tab")
	end
	cx.sessions:switch(session)
	cx.layout:focus(link.agent)
end

-- ---------------------------------------------------------------- worktrees

-- Opens (or focuses the tab already working in) the worktree at `path`.
function M.openPath(cx: WindowCx, pane: number, path: string)
	if path == "" or #path > 4096 or string.find(path, "%c") then
		return cx:toast("error", "Plotroom: that worktree path is not usable")
	end
	local found, _, session = e().targetPane(cx, path)
	if found and session then
		cx.sessions:switch(session)
		return cx.layout:focus(found)
	end
	local sessionId = e().sourceSession(cx, pane)
	if not sessionId then
		return cx:toast("info", "The source pane closed, so no tab was opened", path)
	end
	cx.sessions:switch(sessionId)
	if not cx.layout:new_tab({ cwd = path }) then
		cx:toast("error", "The worktree's tab did not open", path)
	end
end

-- plotroom://worktrees/open/<n>: the host names row n's path; the link is valid only while its node says so.
function M.openWorktree(cx: WindowCx, pane: number, url: string, n: number)
	if e().nodeProp(e().readNode(cx, pane, WTOPEN_NODE), "href") ~= url then
		return cx:toast("error", "Plotroom: that worktree is no longer listed", "Refresh and try again.")
	end
	e().ask(cx, pane, "worktree-path", { n = n }, ACT_MS, function(a: any, cx2: WindowCx)
		local why = problemOf(a)
		if why then
			return cx2:toast("error", "Worktree not opened", why)
		elseif type(a.path) ~= "string" then
			return cx2:toast("error", "Worktree not opened", "The block's host gave no path")
		end
		M.openPath(cx2, pane, a.path)
	end)
end

-- ---------------------------------------------------------------- confirmation

-- Cancel FIRST (Enter keeps it), then the destructive choice, then the plan's target lines as rows. onConfirm runs
-- only for the confirm row: a dismissed picker, Cancel or a target row does nothing.
local function confirmPick(cx: WindowCx, head: string, label: string, lines: { string }, onConfirm: (WindowCx) -> ())
	local items: { PickItem } = { { label = "Cancel", icon = "x" }, { label = label, confirm = true } }
	for i, line in lines do
		if i > MAX_ROWS then
			break
		end
		table.insert(items, { label = line, group = "Target" })
	end
	cx:pick({ items = items, placeholder = head, icon = "merge", action = "confirm" }):next(function(item, _, cx2)
		if cx2 and item and item.confirm == true then
			onConfirm(cx2)
		end
	end)
end

local function planOf(a: any): Plan?
	local c = a.confirm
	if type(a.token) ~= "string" or a.token == "" or type(c) ~= "table" or type(c.head) ~= "string" or type(c.label) ~= "string" then
		return nil
	end
	local lines: { string } = {}
	if type(c.lines) == "table" then
		for _, line in c.lines do
			if type(line) == "string" and line ~= "" then
				table.insert(lines, line)
			end
		end
	end
	return { token = a.token, head = c.head, label = c.label, lines = lines }
end

-- Shows the host's plan reply `plan` (`{token, confirm = {head, label, lines}}`): Cancel first, then the commit choice
-- and its lines. Only a confirmed plan sends `commit` with its own token (never kept past this call), and the result
-- or problem is toasted; `done` runs after a commit that succeeded.
function M.confirmPlan(cx: WindowCx, pane: number, plan: any, done: ((WindowCx, any) -> ())?)
	local p = if type(plan) == "table" then planOf(plan) else nil
	if not p then
		local why = if type(plan) == "table" then problemOf(plan) else nil
		return cx:toast("error", "Plotroom: nothing to confirm", why or "The block's host gave no plan.")
	end
	local token = p.token
	confirmPick(cx, p.head, p.label, p.lines, function(cx2: WindowCx)
		e().ask(cx2, pane, "commit", { token = token }, COMMIT_MS, function(a: any, cx3: WindowCx)
			local why = problemOf(a)
			if why then
				return cx3:toast("error", "Not done", why)
			elseif a.ok ~= true then
				return cx3:toast("error", "Not done", "The block's host gave no result")
			end
			cx3:toast("success", if type(a.message) == "string" then a.message else "Done", if type(a.url) == "string" then a.url else nil)
			if done then
				done(cx3, a)
			end
		end)
	end)
end

-- Asks the host for an `act`; a plan reply is confirmed, a problem is toasted under `title`.
local function planAct(cx: WindowCx, pane: number, title: string, args: { [string]: any })
	e().ask(cx, pane, "act", args, ACT_MS, function(a: any, cx2: WindowCx)
		local why = problemOf(a)
		if why then
			return cx2:toast("error", title, why)
		end
		M.confirmPlan(cx2, pane, a, nil)
	end)
end

-- The selected item of the pane's active view, as the host says; nothing selected is said.
local function withItem(cx: WindowCx, pane: number, done: (any, WindowCx) -> ())
	e().ask(cx, pane, "ctx", {}, ACT_MS, function(a: any, cx2: WindowCx)
		local why = problemOf(a)
		local item = a.item
		if why then
			return cx2:toast("error", "Plotroom: the selected item is not known", why)
		elseif type(item) ~= "table" or type(item.key) ~= "string" then
			return cx2:toast("info", "Select a pull request or issue first")
		end
		done(item, cx2)
	end)
end

-- ---------------------------------------------------------------- item actions

local function assignMe(cx: WindowCx, pane: number)
	planAct(cx, pane, "Not assigned", { name = "assign-me" })
end

local function labelAdd(cx: WindowCx, pane: number)
	cx:prompt({ placeholder = "Label to add to the selected issue", icon = "merge", action = "add" }):next(function(text, _, cx2)
		local label = if text then trim(text) else ""
		if cx2 and label ~= "" then
			planAct(cx2, pane, "Label not added", { name = "label-add", label = label })
		end
	end)
end

local function labelRemove(cx: WindowCx, pane: number)
	withItem(cx, pane, function(item: any, cx2: WindowCx)
		local items: { PickItem } = {}
		for _, label in if type(item.labels) == "table" then item.labels else {} do
			if type(label) == "string" and label ~= "" then
				table.insert(items, { label = label, group = "Labels" })
			end
		end
		if #items == 0 then
			return cx2:toast("info", item.key .. " has no labels")
		end
		cx2:pick({ items = items, placeholder = "Remove a label from " .. item.key, icon = "merge", action = "remove" }):next(function(picked, _, cx3)
			if cx3 and picked then
				planAct(cx3, pane, "Label not removed", { name = "label-remove", label = picked.label })
			end
		end)
	end)
end

local function jiraTransition(cx: WindowCx, pane: number)
	e().ask(cx, pane, "act", { name = "transition" }, ACT_MS, function(a: any, cx2: WindowCx)
		local why = problemOf(a)
		if why then
			return cx2:toast("error", "Transitions are not listed", why)
		end
		local items: { PickItem } = {}
		local ids: { [string]: boolean } = {}
		for _, o in if type(a.options) == "table" then a.options else {} do
			if type(o) == "table" and type(o.id) == "string" and type(o.name) == "string" then
				ids[o.id] = true
				table.insert(items, { label = o.name, optionId = o.id, current = o.name == a.current or o.id == a.current })
			end
		end
		if #items == 0 then
			return cx2:toast("info", "No transitions are offered for this issue")
		end
		cx2:pick({ items = items, placeholder = "Move the selected issue to…", icon = "merge", action = "move" }):next(function(picked, _, cx3)
			if cx3 and picked and ids[picked.optionId] then
				planAct(cx3, pane, "Not moved", { name = "transition", to = picked.optionId })
			end
		end)
	end)
end

-- A workflow-run action on the selected pull request's checks: the host answers the runs to pick from (several) or a plan.
local function runAction(cx: WindowCx, pane: number, name: string, title: string, none: string, placeholder: string)
	e().ask(cx, pane, "act", { name = name }, ACT_MS, function(a: any, cx2: WindowCx)
		local why = problemOf(a)
		if why then
			return cx2:toast("error", title, why)
		elseif type(a.runs) ~= "table" then
			return M.confirmPlan(cx2, pane, a, nil)
		end
		local items: { PickItem } = {}
		for _, r in a.runs do
			if type(r) == "table" and (type(r.id) == "string" or type(r.id) == "number") and type(r.label) == "string" then
				table.insert(items, { label = r.label, runId = r.id })
			end
		end
		if #items == 0 then
			return cx2:toast("info", none)
		end
		cx2:pick({ items = items, placeholder = placeholder, icon = "merge", action = "plan" }):next(function(item, _, cx3)
			if item and cx3 then
				planAct(cx3, pane, title, { name = name, run = item.runId })
			end
		end)
	end)
end

local function rerunFailed(cx: WindowCx, pane: number)
	runAction(cx, pane, "rerun-failed", "Nothing to re-run", "No failed runs to re-run", "Which failed run to re-run?")
end

local function rerunAll(cx: WindowCx, pane: number)
	runAction(cx, pane, "rerun-all", "Nothing to re-run", "No finished runs to re-run", "Which run to re-run in full?")
end

local function cancelRun(cx: WindowCx, pane: number)
	runAction(cx, pane, "cancel-run", "Nothing to cancel", "No queued or running workflow runs", "Which running workflow run to cancel?")
end

local function issueClose(cx: WindowCx, pane: number)
	planAct(cx, pane, "Issue not closed", { name = "issue-close" })
end

local function issueReopen(cx: WindowCx, pane: number)
	planAct(cx, pane, "Issue not reopened", { name = "issue-reopen" })
end

local function prReady(cx: WindowCx, pane: number)
	planAct(cx, pane, "Not marked ready", { name = "pr-ready" })
end

local function prDraft(cx: WindowCx, pane: number)
	planAct(cx, pane, "Not converted to a draft", { name = "pr-draft" })
end

-- One-line prompt; the host validates the text and shows exactly what it will post when it asks for the confirmation.
local function comment(cx: WindowCx, pane: number)
	cx:prompt({ placeholder = "Comment to add to the selected item", icon = "merge", action = "review" }):next(function(text, _, cx2)
		if cx2 and text and trim(text) ~= "" then
			planAct(cx2, pane, "Comment not added", { name = "comment", text = trim(text) })
		end
	end)
end

-- ---------------------------------------------------------------- draft PR

-- The preview's review picker: Cancel first, then the way on, the edits and what will happen. A prompt left with Esc
-- returns here with the earlier values; only Cancel (or dismissing this picker) ends the flow.
local function reviewDraft(cx: WindowCx, pane: number, p: any, title: string, body: string)
	local items: { PickItem } = {
		{ label = "Cancel", icon = "x" },
		{ label = "Create with this title and description", detail = string.format("%s → %s · %d commit(s)", tostring(p.branch), tostring(p.base), if type(p.count) == "number" then p.count else 0), go = true },
		{ label = "Edit title…", detail = title, edit = "title", group = "Edit" },
		{ label = "Edit description…", detail = (string.match(body, "[^\n]*")) or "", edit = "body", group = "Edit" },
	}
	if p.needsPush == true then
		table.insert(items, { label = "Push " .. tostring(p.branch) .. " to " .. tostring(p.remote), group = "Will happen" })
	end
	if p.dirty == true then
		table.insert(items, { label = "Uncommitted changes stay out of the PR", group = "Note" })
	end
	for i, line in if type(p.commits) == "table" then p.commits else {} do
		if i > MAX_ROWS then
			break
		end
		if type(line) == "string" then
			table.insert(items, { label = line, group = "Commits" })
		end
	end
	cx:pick({ items = items, placeholder = "Draft PR: " .. title, icon = "merge", action = "choose" }):next(function(item, _, cx2)
		if not item or not cx2 then
			return
		elseif item.edit == "title" or item.edit == "body" then
			local isTitle = item.edit == "title"
			-- ponytail: the prompt is one line, so editing the description replaces all of it; a multi-line editor needs a host-side form.
			return cx2:prompt({ value = if isTitle then title else body, placeholder = if isTitle then "Draft PR title" else "Draft PR description", icon = "merge", action = "save" }):next(function(text, _, cx3)
				if not cx3 then
					return
				elseif not text then
					return reviewDraft(cx3, pane, p, title, body) -- Esc: back to the review, earlier values intact
				end
				local t, b = title, body
				if isTitle then
					t = trim(text)
				else
					b = text
				end
				if t == "" or #t > MAX_TITLE or #b > MAX_BODY then
					cx3:toast("error", "Not changed", "The title takes 1 to " .. MAX_TITLE .. " bytes, the description up to " .. MAX_BODY .. ".")
					return reviewDraft(cx3, pane, p, title, body)
				end
				reviewDraft(cx3, pane, p, t, b)
			end)
		elseif item.go ~= true then
			return
		end
		e().ask(cx2, pane, "draft", { phase = "plan", token = p.token, title = title, body = body }, DRAFT_MS, function(a: any, cx3: WindowCx)
			local why = problemOf(a)
			if why then
				return cx3:toast("error", "Draft PR not planned", why)
			end
			M.confirmPlan(cx3, pane, a, nil)
		end)
	end)
end

local function draftPr(cx: WindowCx, pane: number)
	e().ask(cx, pane, "draft", { phase = "info" }, DRAFT_MS, function(info: any, cx2: WindowCx)
		local why = problemOf(info)
		if why then
			return cx2:toast("error", "Draft PR not started", why)
		end
		-- Only a destination the host listed is ever sent back.
		local dests: { PickItem } = {}
		for _, d in if type(info.destinations) == "table" then info.destinations else {} do
			if type(d) == "table" and type(d.repo) == "string" and d.repo ~= "" then
				table.insert(dests, { label = "Open the pull request on " .. d.repo, detail = if type(d.remote) == "string" then d.remote else nil, repo = d.repo })
			end
		end
		if #dests == 0 then
			return cx2:toast("error", "Draft PR not started", "The block's host offered no repository")
		end
		local branch = if type(info.branch) == "string" then info.branch else "this branch"
		cx2:pick({ items = dests, placeholder = "Where should the draft PR from " .. branch .. " go?", icon = "merge", action = "choose" }):next(function(dest, _, cx3)
			if not dest or not cx3 then
				return
			end
			local repo: string = dest.repo
			e().ask(cx3, pane, "draft", { phase = "bases", repo = repo }, DRAFT_MS, function(b: any, cx4: WindowCx)
				local why1 = problemOf(b)
				if why1 then
					return cx4:toast("error", "Draft PR not started", why1)
				end
				local default = if type(b.defaultBase) == "string" then b.defaultBase else nil
				local items: { PickItem } = {}
				if default then
					table.insert(items, { label = default, group = "Default branch" })
				end
				for _, name in if type(b.bases) == "table" then b.bases else {} do
					if type(name) == "string" and name ~= default then
						table.insert(items, { label = name, group = "Branches" })
					end
				end
				if #items == 0 then
					return cx4:toast("error", "Draft PR not started", "The block's host offered no base branch")
				end
				cx4:pick({ items = items, placeholder = "Open a draft PR from " .. branch .. " into…", icon = "merge", action = "preview" }):next(function(base, _, cx5)
					if not base or not cx5 then
						return
					end
					e().ask(cx5, pane, "draft", { phase = "preview", repo = repo, base = base.label }, DRAFT_MS, function(p: any, cx6: WindowCx)
						local why2 = problemOf(p)
						if why2 then
							return cx6:toast("error", "Draft PR not previewed", why2)
						elseif type(p.token) ~= "string" or type(p.title) ~= "string" or type(p.body) ~= "string" then
							return cx6:toast("error", "Draft PR not previewed", "The block's host gave no draft")
						end
						reviewDraft(cx6, pane, p, p.title, p.body)
					end)
				end)
			end)
		end)
	end)
end

-- ---------------------------------------------------------------- export / import

local function exportFlow(cx: WindowCx, pane: number)
	e().ask(cx, pane, "export-list", {}, ACT_MS, function(a: any, cx2: WindowCx)
		local why = problemOf(a)
		if why then
			return cx2:toast("error", "Nothing to export", why)
		end
		local entries: { { kind: string, id: any, label: string, detail: string } } = {}
		for _, v in if type(a.views) == "table" then a.views else {} do
			if type(v) == "table" and v.id ~= nil and type(v.name) == "string" then
				table.insert(entries, { kind = "view", id = v.id, label = v.name, detail = tostring(v.kind) .. " · " .. tostring(v.integration) })
			end
		end
		for _, v in if type(a.prompts) == "table" then a.prompts else {} do
			if type(v) == "table" and v.id ~= nil and type(v.name) == "string" then
				table.insert(entries, { kind = "prompt", id = v.id, label = v.name, detail = tostring(v.kind) })
			end
		end
		if #entries == 0 then
			return cx2:toast("info", "No views or actions to export")
		end
		local chosen: { [number]: boolean } = {}
		local function finish(cx3: WindowCx)
			local views: { any } = {}
			local prompts: { any } = {}
			for i, entry in entries do
				if chosen[i] then
					table.insert(if entry.kind == "view" then views else prompts, entry.id)
				end
			end
			if #views + #prompts == 0 then
				return cx3:toast("info", "Nothing was picked to export")
			end
			local args: { [string]: any } = { views = tern.json.array(views), prompts = tern.json.array(prompts) }
			e().ask(cx3, pane, "export", args, ACT_MS, function(r: any, cx5: WindowCx)
				local why2 = problemOf(r)
				if why2 then
					return cx5:toast("error", "Not exported", why2)
				elseif type(r.token) ~= "string" or r.token == "" then
					return cx5:toast("error", "Not exported", "The block's host gave no export to confirm")
				end
				-- What leaves is the host's own snapshot: its actual counts and notes are confirmed, then that snapshot is committed.
				local token: string = r.token
				local nv = if type(r.count) == "table" then tonumber(r.count.views) or 0 else 0
				local np = if type(r.count) == "table" then tonumber(r.count.prompts) or 0 else 0
				local actual = string.format("%d view(s), %d action(s)", nv, np)
				local copyable = r.copyable ~= false
				local rows: { PickItem } = { { label = "Cancel", icon = "x" } }
				if copyable then
					table.insert(rows, { label = "Copy to the clipboard", detail = actual, mode = "copy" })
				else
					table.insert(rows, { label = "Too large to copy: file only", group = "Note" })
				end
				table.insert(rows, { label = "Write to a file…", detail = actual, mode = "file" })
				for i, n in if type(r.notes) == "table" then r.notes else {} do
					if type(n) == "string" and i <= MAX_ROWS then
						table.insert(rows, { label = n, group = "Notes" })
					end
				end
				local function commit(cx6: WindowCx, path: string?)
					local ca: { [string]: any } = { phase = "commit", token = token }
					if path then
						ca.path = path
					end
					e().ask(cx6, pane, "export", ca, ACT_MS, function(r2: any, cx7: WindowCx)
						local why3 = problemOf(r2)
						if why3 then
							return cx7:toast("error", "Not exported", why3)
						elseif r2.ok ~= true then
							return cx7:toast("error", "Not exported", "The block's host did not confirm it")
						end
						local parts: { string } = {}
						if type(r2.json) == "string" then
							cx7:copy(r2.json)
							table.insert(parts, "Copied to the clipboard")
						end
						if type(r2.path) == "string" then
							table.insert(parts, "saved to " .. r2.path)
						end
						cx7:toast("success", "Exported " .. actual, table.concat(parts, " · "))
					end)
				end
				cx5:pick({ items = rows, placeholder = "Export " .. actual, icon = "merge", action = "export" }):next(function(item, _, cx6)
					if not item or not cx6 then
						return
					elseif item.mode == "copy" then
						commit(cx6, nil)
					elseif item.mode == "file" then
						cx6:prompt({ placeholder = "File path to write the export to", icon = "merge", action = "export" }):next(function(text, _, cx7)
							local path = if text then trim(text) else ""
							if cx7 and path ~= "" then
								commit(cx7, path)
							end
						end)
					end
				end)
			end)
		end
		local function round(cx3: WindowCx)
			local picked = 0
			for i in chosen do
				if chosen[i] then
					picked += 1
				end
			end
			local items: { PickItem } = { { label = "Done", detail = picked .. " picked", done = true } }
			for i, entry in entries do
				table.insert(items, { label = entry.label, detail = entry.detail, group = if entry.kind == "view" then "Views" else "Actions", current = chosen[i] == true, at = i })
			end
			cx3:pick({ items = items, placeholder = "Pick what to export (no tokens, paths or checkouts are included)", icon = "merge", action = "toggle" }):next(function(item, _, cx4)
				if not item or not cx4 then
					return
				elseif item.done == true then
					return finish(cx4)
				end
				local at: number = item.at
				chosen[at] = not chosen[at]
				round(cx4)
			end)
		end
		round(cx2)
	end)
end

local CONFLICT_CHOICES = {
	["same-name"] = { { "skip", "Skip", "Keep yours" }, { "replace", "Replace", "Overwrite yours" }, { "duplicate", "Duplicate", "Keep both" } },
	identical = { { "skip", "Skip", "Already the same" }, { "duplicate", "Duplicate", "Keep both" } },
}

local function importPreview(cx: WindowCx, pane: number, r: any)
	local entries: { any } = {}
	local lines: { string } = {}
	for _, en in if type(r.entries) == "table" then r.entries else {} do
		if type(en) == "table" and type(en.id) == "number" and type(en.name) == "string" then
			table.insert(entries, en)
			table.insert(lines, en.name .. " (" .. tostring(en.type) .. ")" .. (if type(en.conflict) == "string" then " · " .. en.conflict else ""))
		end
	end
	local problems: { string } = {}
	for _, p in if type(r.problems) == "table" then r.problems else {} do
		if type(p) == "string" then
			table.insert(problems, p)
		end
	end
	if #entries == 0 or type(r.token) ~= "string" then
		return cx:toast("error", "Nothing to import", problems[1] or "The file holds no views or actions")
	end
	local token: string = r.token
	local slots: { string } = {}
	for _, s in if type(r.slots) == "table" then r.slots else {} do
		if type(s) == "string" then
			table.insert(slots, s)
		end
	end
	local accounts: { string } = {}
	for _, s in if type(r.accounts) == "table" then r.accounts else {} do
		if type(s) == "string" then
			table.insert(accounts, s)
		end
	end
	local choices: { [string]: string } = {}
	local mapping: { [string]: string } = {}
	local notes: { string } = {}
	local remaps: { string } = {}
	for _, en in entries do
		for _, rm in if type(en.remap) == "table" then en.remap else {} do
			if type(rm) == "string" then
				table.insert(remaps, en.name .. ": " .. rm)
			end
		end
	end

	local function apply(cx2: WindowCx)
		local lines2: { string } = {}
		for _, n in notes do
			table.insert(lines2, n)
		end
		for _, p in remaps do
			table.insert(lines2, p)
		end
		for _, p in problems do
			table.insert(lines2, p)
		end
		confirmPick(cx2, "Import " .. #entries .. " item(s)", "Import", lines2, function(cx3: WindowCx)
			e().ask(cx3, pane, "import", { phase = "apply", token = token, choices = choices, mapping = mapping }, COMMIT_MS, function(a: any, cx4: WindowCx)
				local why = problemOf(a)
				if why then
					return cx4:toast("error", "Not imported", why)
				end
				local counts = if type(a.counts) == "table" then string.format(" (%d view(s), %d action(s))", tonumber(a.counts.views) or 0, tonumber(a.counts.prompts) or 0) else ""
				local msg = if type(a.message) == "string" then a.message elseif a.ok == true then "Imported" else "Not imported"
				local out: { string } = {}
				for _, n in if type(a.notes) == "table" then a.notes else {} do
					if type(n) == "string" then
						table.insert(out, n)
					end
				end
				local sub: string? = if #out > 0 then table.concat(out, " · ") else nil
				if a.ok ~= true then
					cx4:toast("error", "Not imported", sub or msg)
				elseif a.nothing == true then
					cx4:toast("info", "Nothing was imported", sub or msg)
				else
					cx4:toast("success", msg .. counts, sub)
				end
			end)
		end)
	end
	local function slotAt(cx2: WindowCx, i: number)
		local slot = slots[i]
		if not slot then
			return apply(cx2)
		end
		local items: { PickItem } = { { label = "Skip views using it", value = "" }, { label = "gh active account", value = "@active" } }
		for _, login in accounts do
			table.insert(items, { label = login, value = login, group = "Signed-in accounts" })
		end
		cx2:pick({ items = items, placeholder = "Which account takes the exported slot " .. slot .. "?", icon = "merge", action = "map" }):next(function(item, _, cx3)
			if not item or not cx3 then
				return
			end
			local v: string = item.value
			mapping[slot] = v
			table.insert(notes, slot .. " → " .. (if v == "" then "skipped" elseif v == "@active" then "gh active account" else v))
			slotAt(cx3, i + 1)
		end)
	end
	local function entryAt(cx2: WindowCx, i: number)
		local en = entries[i]
		if not en then
			return slotAt(cx2, 1)
		end
		local options = if type(en.conflict) == "string" then CONFLICT_CHOICES[en.conflict] else nil
		if not options then
			return entryAt(cx2, i + 1)
		end
		local items: { PickItem } = {}
		for _, o in options do
			table.insert(items, { label = o[2], detail = o[3], choice = o[1] })
		end
		cx2:pick({ items = items, placeholder = en.name .. " is already here (" .. en.conflict .. ")", icon = "merge", action = "choose" }):next(function(item, _, cx3)
			if not item or not cx3 then
				return
			end
			choices[tostring(en.id)] = item.choice
			table.insert(notes, en.name .. " → " .. string.lower(item.label))
			entryAt(cx3, i + 1)
		end)
	end
	-- The summary: Cancel first, then what the file holds; Continue goes through the conflicts.
	local items: { PickItem } = { { label = "Cancel", icon = "x" }, { label = "Continue", detail = #entries .. " item(s)", go = true } }
	for i, line in lines do
		if i > MAX_ROWS then
			break
		end
		table.insert(items, { label = line, group = "In the file" })
	end
	for _, p in problems do
		table.insert(items, { label = p, group = "Problems" })
	end
	for _, p in remaps do
		table.insert(items, { label = p, group = "Changes on import" })
	end
	cx:pick({ items = items, placeholder = "Import: what the file holds", icon = "merge", action = "continue" }):next(function(item, _, cx2)
		if cx2 and item and item.go == true then
			entryAt(cx2, 1)
		end
	end)
end

local function importFlow(cx: WindowCx, pane: number)
	cx:prompt({ placeholder = "Paste exported JSON, or the path of a file on the block's host", icon = "merge", action = "preview" }):next(function(text, _, cx2)
		local typed = if text then trim(text) else ""
		if not cx2 or typed == "" then
			return
		end
		local args: { [string]: any } = { phase = "preview" }
		if string.sub(typed, 1, 1) == "{" then
			args.text = typed
		else
			args.path = typed
		end
		if #tern.json.encode(args) > 65000 then
			return cx2:toast("error", "Not imported", "That is too long: paste a file path instead")
		end
		e().ask(cx2, pane, "import", args, ACT_MS, function(r: any, cx3: WindowCx)
			local why = problemOf(r)
			if why then
				return cx3:toast("error", "Not imported", why)
			end
			importPreview(cx3, pane, r)
		end)
	end)
end

-- ---------------------------------------------------------------- open item by URL

-- Sends open-url once the block in `pane` has published its protocol node: a launched block needs a moment.
local function whenReady(cx: WindowCx, pane: number, tries: number, fn: (WindowCx) -> ())
	if type(e().nodeProp(e().readNode(cx, pane, "main.rpc"), "text")) == "string" then
		return fn(cx)
	elseif tries <= 0 then
		return cx:toast("error", "Plotroom did not start in time", "Open the item again once its block shows.")
	end
	tern.timer(OPEN_URL_STEP_MS, function(cx2: WindowCx?)
		if cx2 then
			whenReady(cx2, pane, tries - 1, fn)
		end
	end)
end

local function sendUrl(cx: WindowCx, pane: number, url: string)
	e().ask(cx, pane, "open-url", { url = url }, ACT_MS, function(a: any, cx2: WindowCx)
		local why = problemOf(a)
		if why then
			return cx2:toast("error", "Item not opened", why)
		end
		cx2:toast(if a.ok == true then "success" else "error", if type(a.message) == "string" then a.message elseif a.ok == true then "Item opened" else "Item not opened")
		cx2.layout:focus(pane)
	end)
end

-- Plotroom: Open item by URL. A focused Plotroom block takes it, else the lowest existing one, else one is launched.
function M.openByUrl(cx: WindowCx, _pane: number?)
	cx:prompt({ placeholder = "GitHub pull request or issue URL, or a Jira issue URL", icon = "merge", action = "open" }):next(function(text, _, cx2)
		local url = if text then trim(text) else ""
		if not cx2 or url == "" then
			return
		elseif string.sub(url, 1, 8) ~= "https://" or #url > 2048 or string.find(url, "[%c%s]") then
			return cx2:toast("error", "Not an item URL", "Paste an https:// pull request, issue or Jira URL.")
		end
		local focused = cx2.session:focused()
		local pane: number? = if focused and e().isPlotroom(cx2, focused) then focused else plotroomPanes(cx2)[1]
		if pane then
			cx2.layout:focus(pane)
			return whenReady(cx2, pane, 0, function(cx3: WindowCx)
				sendUrl(cx3, pane :: number, url)
			end)
		end
		local launched = e().launch(cx2)
		if not launched then
			return
		end
		whenReady(cx2, launched, OPEN_URL_TRIES, function(cx3: WindowCx)
			sendUrl(cx3, launched, url)
		end)
	end)
end

-- ---------------------------------------------------------------- plain events and the command list

local function send(act: string, value: string?): (WindowCx, number) -> ()
	return function(cx: WindowCx, pane: number)
		cx.session:event(pane, { ev = "action", act = act, value = value })
	end
end

local function triage(value: string): (WindowCx, number) -> ()
	return send("triage", value)
end

-- Palette commands the window registers (id, title) and its command palette lists (label, under `group`) when the host
-- says they apply to the selection now (`menu`'s `commands`) unless `keyed`: the palette lists those as the queue action
-- they are. All but `anywhere` ones need a focused Plotroom block, which the window checks.
export type Command = { id: string, title: string, label: string, group: string, run: (WindowCx, number) -> (), anywhere: boolean?, keyed: boolean? }

M.COMMANDS = {
	{ id = "open-url", title = "Plotroom: Open item by URL", label = "Open item by URL…", group = "View", run = M.openByUrl, anywhere = true },
	{
		id = "agent-go",
		title = "Plotroom: Go to the selected item's agent",
		label = "Go to agent",
		group = "Agents",
		keyed = true,
		run = function(cx: WindowCx, pane: number)
			e().follow(cx, pane, AGENTGO_NODE, "The selected item has no agent")
		end,
	},
	{ id = "assign-me", title = "Plotroom: Assign the selected issue to me", label = "Assign to me", group = "Item", run = assignMe },
	{ id = "comment", title = "Plotroom: Comment on the selected item", label = "Comment…", group = "Item", run = comment },
	{ id = "label-add", title = "Plotroom: Add a label to the selected issue", label = "Add label…", group = "GitHub", run = labelAdd },
	{ id = "label-remove", title = "Plotroom: Remove a label from the selected issue", label = "Remove label…", group = "GitHub", run = labelRemove },
	{ id = "issue-close", title = "Plotroom: Close the selected GitHub issue", label = "Close issue…", group = "GitHub", run = issueClose },
	{ id = "issue-reopen", title = "Plotroom: Reopen the selected GitHub issue", label = "Reopen issue…", group = "GitHub", run = issueReopen },
	{ id = "pr-ready", title = "Plotroom: Mark the selected draft PR ready for review", label = "Ready for review…", group = "GitHub", run = prReady },
	{ id = "pr-draft", title = "Plotroom: Convert the selected PR to a draft", label = "Convert to draft…", group = "GitHub", run = prDraft },
	{ id = "jira-transition", title = "Plotroom: Move the selected Jira issue to another status", label = "Jira transition…", group = "Jira", run = jiraTransition },
	{ id = "rerun-failed", title = "Plotroom: Re-run the selected PR's failed checks", label = "Re-run failed checks", group = "CI", run = rerunFailed },
	{ id = "rerun-all", title = "Plotroom: Re-run every job of one of the selected PR's finished runs", label = "Re-run all jobs…", group = "CI", run = rerunAll },
	{ id = "cancel-run", title = "Plotroom: Cancel a running workflow run of the selected PR", label = "Cancel running workflow…", group = "CI", run = cancelRun },
	{ id = "draft-pr", title = "Plotroom: Open a draft PR from the selected item's worktree", label = "Draft PR…", group = "Worktree", run = draftPr },
	{ id = "export", title = "Plotroom: Export views and actions", label = "Export views and actions…", group = "Configuration", run = exportFlow },
	{ id = "import", title = "Plotroom: Import views and actions", label = "Import views and actions…", group = "Configuration", run = importFlow },
	{ id = "mark-seen", title = "Plotroom: Mark the selected item seen", label = "Mark seen", group = "Item", run = triage("seen"), keyed = true },
	{ id = "snooze", title = "Plotroom: Snooze the selected item", label = "Snooze", group = "Item", run = triage("snooze"), keyed = true },
	{ id = "toggle-snoozed", title = "Plotroom: Show or hide snoozed items", label = "Show or hide snoozed", group = "View", run = triage("toggle-snoozed"), keyed = true },
	{ id = "attention", title = "Plotroom: Show only items needing attention", label = "Needs attention filter", group = "View", run = triage("toggle-attention"), keyed = true },
	{ id = "sort", title = "Plotroom: Next sort order", label = "Next sort order", group = "View", run = send("sort", "next"), keyed = true },
	{ id = "worktrees-open", title = "Plotroom: Open the Worktrees board", label = "Worktrees board", group = "Worktree", run = send("open-worktrees", nil) },
} :: { Command }

return M
