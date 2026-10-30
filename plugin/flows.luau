--!strict
-- The window's workflow flows: agent links (which agent pane works on which item, kept in kv `agent-links`, and the
-- timer that tells each Plotroom block how those agents are doing), the guided mutations (assign, labels, Jira
-- transition, re-run, draft PR, export, import: always plan, Cancel-first confirm, commit), Open item by URL and the
-- commands the command palette lists. window.luau injects what it owns (`setup`), so there is no require cycle.

local input = require("./input")
local trim = input.trim

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
	-- the node has none; `typed` asks for a typed prompt; `mode` varies what the link does ("preview": opens the page in a
	-- floating Browser over the block; "agentpick": the Message link sends a picked page element).
	follow: (cx: WindowCx, pane: number, nodeId: string, missing: string?, typed: boolean?, mode: string?) -> (),
}

-- A Plotroom block's host: Tern's slot id and its address ("" for this machine), the name only for people.
type HostId = { id: number, name: string, address: string }
-- The saved action an agent ran, kept with its link: `next` (nil once started or stopped) is the action to start when the
-- agent finishes, for the same item (`kind`, `repo`, `ref`), or `prs:<id>` for a pull request action on the pull request
-- of the agent's worktree `branch` in the code repository `code` (an issue's `repo` can be a Jira project key); `depth`
-- counts the actions chained before it.
type Chain = { action: string, name: string, next: string?, kind: string, repo: string, ref: string, depth: number, code: string?, branch: string?, pane: number? }
type Link = { key: string, agent: number, host: HostId, at: number, chain: Chain?, action: string?, branch: string?, title: string?, result: string?, ended: string?, cwd: string? }
-- What a link says about its agent beyond the item key (the action's name, the worktree's branch, the item's title); `code`
-- (an issue's code repository) is only for its chain.
export type AgentInfo = { action: string?, branch: string?, title: string?, code: string?, cwd: string? }
type StatusRow = { state: string, action: string?, branch: string?, title: string?, last: string?, err: string?, result: string?, ended: string? }
type Notes = { [number]: { last: string?, err: string? } }
type Plan = { token: string, head: string, label: string, lines: { string } }

local LINKS_KEY = "agent-links"
local LINKS_CAP = 200
local ACTION_CAP, BRANCH_CAP, TITLE_CAP = 60, 100, 100 -- the host takes up to 120, 200 and 256
local LAST_CAP, RESULT_CAP = 200, 10 -- an agent's last message or delivery error; a run's result and its HH:MM
local INFO_BYTES = 30000
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
local OPEN_NODE = "layer.queue.buttons.open"
local AGENTMSG_NODE = "layer.queue.buttons.agentmsg" -- hidden: the Message link, whose node also says an agent is recorded
local WTOPEN_NODE = "layer.queue.buttons.wtopen"
local GIT_NODE = "layer.queue.buttons.git"

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

-- `s` as one clean line of at most `cap` bytes; nil for nothing (or only blanks) to say.
local function clip(s: string?, cap: number): string?
	if not s then
		return nil
	end
	local text = string.gsub(input.clean(string.sub(s, 1, cap)), "%c", " ")
	return if string.find(text, "%S") then text else nil
end

local function linkOf(row: any): Link?
	if type(row) ~= "table" or type(row.key) ~= "string" or row.key == "" or #row.key > 200 or type(row.agent) ~= "number" or type(row.at) ~= "number" then
		return nil
	end
	local h = row.host
	if type(h) ~= "table" or type(h.id) ~= "number" or type(h.name) ~= "string" or type(h.address) ~= "string" then
		return nil
	end
	local c: Chain? = nil
	if row.chain ~= nil then
		local r = row.chain
		if
			type(r) ~= "table"
			or type(r.action) ~= "string"
			or type(r.name) ~= "string"
			or (r.next ~= nil and type(r.next) ~= "string")
			or (r.kind ~= "pr" and r.kind ~= "issue")
			or type(r.repo) ~= "string"
			or type(r.ref) ~= "string"
			or type(r.depth) ~= "number"
			or (r.code ~= nil and type(r.code) ~= "string")
			or (r.branch ~= nil and type(r.branch) ~= "string")
			or (r.pane ~= nil and type(r.pane) ~= "number")
		then
			return nil
		end
		c = { action = r.action, name = r.name, next = r.next, kind = tostring(r.kind), repo = r.repo, ref = r.ref, depth = r.depth, code = r.code, branch = r.branch, pane = r.pane }
	end
	-- A link saved before the texts were recorded has none; one with a text that is no string is malformed.
	local texts: { [string]: string } = {}
	for _, field in { "action", "branch", "title", "result", "ended", "cwd" } do
		local v = row[field]
		if v ~= nil and type(v) ~= "string" then
			return nil
		end
		texts[field] = v
	end
	return {
		key = row.key,
		agent = row.agent,
		host = { id = h.id, name = h.name, address = h.address },
		at = row.at,
		chain = c,
		action = clip(texts.action, ACTION_CAP),
		branch = clip(texts.branch, BRANCH_CAP),
		title = clip(texts.title, TITLE_CAP),
		result = clip(texts.result, RESULT_CAP),
		ended = clip(texts.ended, RESULT_CAP),
		cwd = texts.cwd, -- where its agent started: a pane id reused after a restart is told apart by it; an old link has none
	}
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
		table.insert(rows, { key = l.key, agent = l.agent, host = { id = l.host.id, name = l.host.name, address = l.host.address }, at = l.at, chain = l.chain, action = l.action, branch = l.branch, title = l.title, result = l.result, ended = l.ended, cwd = l.cwd })
	end
	return (pcall(tern.kv.set, LINKS_KEY, tern.json.array(rows)))
end

-- pane -> state of every agent block now listed, pane -> its last message and delivery error (each cut to
-- LAST_CAP bytes) and pane -> its working directory; nil states when the list cannot be read.
local function agentStates(cx: WindowCx): ({ [number]: string }?, Notes, { [number]: string })
	local ok, list = pcall(function()
		return cx.agents:list()
	end)
	local notes: Notes = {}
	local cwds: { [number]: string } = {}
	if not ok or type(list) ~= "table" then
		return nil, notes, cwds
	end
	local out: { [number]: string } = {}
	for _, a in list do
		if type(a) == "table" and type(a.pane) == "number" then
			out[a.pane] = if type(a.state) == "string" and STATES[a.state] then a.state else "idle"
			if type(a.cwd) == "string" then
				cwds[a.pane] = a.cwd
			end
			notes[a.pane] = {
				last = if type(a.last_message) == "string" then clip(a.last_message, LAST_CAP) else nil,
				err = if type(a.delivery_error) == "string" then clip(a.delivery_error, LAST_CAP) else nil,
			}
		end
	end
	return out, notes, cwds
end

-- The state of link `l`'s agent: nil when its pane is not listed, or lists another working directory than the link's
-- (a pane id reused after a restart). A link without a directory, or a listing without one, matches by pane alone.
local function stateOf(l: Link, states: { [number]: string }, cwds: { [number]: string }): string?
	local s = states[l.agent]
	local at = cwds[l.agent]
	if s and l.cwd and at and at ~= l.cwd then
		return nil
	end
	return s
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

-- key -> state (and what the link recorded about the agent) for the links recorded on `host` (the newest link of a key
-- counts); an agent pane no longer listed is exited. An exited agent carries no text: its row is not shown, and the
-- report stays small. ponytail: the texts stop at INFO_BYTES of JSON-encoded size (escapes count: the host's cap is on the
-- encoded report), so a report of many live agents stays under its 40000-byte cap with state only for the rest; raise the host's cap with the count of agents if that is ever too few.
local function statusMap(links: { Link }, host: HostId, states: { [number]: string }, cwds: { [number]: string }, notes: Notes): { [string]: StatusRow }
	local map: { [string]: StatusRow } = {}
	local count = 0
	local bytes = 0
	for _, l in links do
		if map[l.key] == nil and hostSame(l.host, host) and count < LINKS_CAP then
			local state = stateOf(l, states, cwds) or "exited"
			local note: { last: string?, err: string? } = notes[l.agent] or {}
			local row: StatusRow = { state = state }
			local full: StatusRow = { state = state, action = l.action, branch = l.branch, title = l.title, last = note.last, err = note.err, result = l.result, ended = l.ended }
			local size = #tern.json.encode({ [l.key] = full }) + 1
			if state ~= "exited" and bytes + size <= INFO_BYTES then
				row = full
				bytes += size
			end
			map[l.key] = row
			count += 1
		end
	end
	return map
end

-- "key=state|action|branch|title|last|err|result|ended;" per key in order: host/render's `agentSig` spells it the same.
local function signature(map: { [string]: StatusRow }): string
	local keys: { string } = {}
	for k in map do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts: { string } = {}
	for _, k in keys do
		local r = map[k]
		table.insert(parts, k .. "=" .. r.state .. "|" .. (r.action or "") .. "|" .. (r.branch or "") .. "|" .. (r.title or "") .. "|" .. (r.last or "") .. "|" .. (r.err or "") .. "|" .. (r.result or "") .. "|" .. (r.ended or "") .. ";")
	end
	return table.concat(parts, "")
end

local waiting: { number } = {} -- linked agent panes in "waiting_input", ascending
local waitingSet: { [number]: boolean } = {}

-- How many linked agents wait for input now (what the status line shows).
function M.waitingCount(): number
	return #waiting
end

local attention = 0 -- items needing attention, summed over the Plotroom blocks (their hidden `main.need`)
local attentionTimer: TimerHandle? = nil

-- How many items need attention now (what the status line shows).
function M.attentionCount(): number
	return attention
end

-- Reads each Plotroom block's count; redraws the status line only when the sum changed.
function M.attentionSync(cx: WindowCx)
	local sum = 0
	for _, pane in plotroomPanes(cx) do
		local n = tonumber(e().nodeProp(e().readNode(cx, pane, "main.need"), "text"))
		if n and n > 0 then
			sum += math.floor(n)
		end
	end
	if sum ~= attention then
		attention = sum
		tern.chrome.refresh()
	end
end

local function attentionTick(cx: WindowCx?)
	attentionTimer = nil
	if not cx then
		return -- the window went away: the next window_start or pane_created starts it again
	end
	M.attentionSync(cx)
	if #plotroomPanes(cx) > 0 then
		attentionTimer = tern.timer(SYNC_MS, attentionTick)
	end
end

-- Recomputes the waiting agents among `links` (only the ones the Agents list covers: see agentSync) from `states`;
-- toasts each agent that just entered waiting_input, and redraws the status line when the shown set changed. `states`
-- nil (no Plotroom pane) only clears the shown count: the toasted set stays until a real read shows an agent left.
local function trackWaiting(cx: WindowCx, links: { Link }, states: { [number]: string }?, cwds: { [number]: string })
	local now: { [number]: Link } = {}
	for _, l in links do
		if states and stateOf(l, states, cwds) == "waiting_input" and now[l.agent] == nil then
			now[l.agent] = l
		end
	end
	local list: { number } = {}
	local nowSet: { [number]: boolean } = {}
	for pane in now do
		table.insert(list, pane)
		nowSet[pane] = true
	end
	table.sort(list)
	local changed = #list ~= #waiting
	for i, pane in list do
		changed = changed or waiting[i] ~= pane
		if not waitingSet[pane] then
			local l = now[pane]
			cx:toast("info", l.key .. " needs input", l.action)
		end
	end
	waiting = list
	if states then
		-- keep every toasted pane still waiting, even one the covered set dropped, so it is not toasted again on return
		for pane in waitingSet do
			if states[pane] == "waiting_input" then
				nowSet[pane] = true
			end
		end
		waitingSet = nowSet
	end
	if changed then
		tern.chrome.refresh()
	end
end

-- Focuses the first agent that waits for input.
function M.goWaiting(cx: WindowCx)
	local agent = waiting[1]
	if not agent then
		return cx:toast("info", "No agent needs input")
	end
	local session = e().sourceSession(cx, agent)
	if not session then
		return cx:toast("info", "That agent is not in a tab")
	end
	cx.sessions:switch(session)
	cx.layout:focus(agent)
end

-- Tells each Plotroom block the full state map of its host's agents whenever the block's own acknowledgement
-- (hidden `main.agents`: the signature of the map it holds) is absent or differs, so a reloaded host is told again.
function M.agentSync(cx: WindowCx)
	local panes = plotroomPanes(cx)
	local links = readLinks()
	if #panes == 0 then
		trackWaiting(cx, {}, nil, {})
		return
	end
	local states, notes, cwds = agentStates(cx)
	if not states then
		return
	end
	local covered: { Link } = {} -- the newest link per key on each Plotroom pane's host, as statusMap picks
	for _, pane in panes do
		local host = hostOf(cx, pane)
		local seen: { [string]: boolean } = {}
		for _, l in links do
			if host and not seen[l.key] and hostSame(l.host, host) then
				seen[l.key] = true
				table.insert(covered, l)
			end
		end
	end
	trackWaiting(cx, covered, states, cwds)
	for _, pane in panes do
		local host = hostOf(cx, pane)
		if host then
			local map = statusMap(links, host, states, cwds, notes)
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

-- Whether there is anything to tell: a Plotroom block and a linked agent that has not exited.
local function active(cx: WindowCx): boolean
	local links = readLinks() -- the cheap read first: pane_created fires for every kind of block
	if #links == 0 or #plotroomPanes(cx) == 0 then
		return false
	end
	local states, _, cwds = agentStates(cx)
	if not states then
		return true -- unreadable list: keep watching
	end
	for _, l in links do
		local s = stateOf(l, states, cwds)
		if s ~= nil and s ~= "exited" then
			return true
		end
	end
	return false
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
	if attentionTimer == nil and #plotroomPanes(cx) > 0 then
		attentionTick(cx)
	end
	if timer == nil and active(cx) then
		timer = tern.timer(SYNC_MS, tick)
	end
end

-- Records that agent block `agent`, started from the Plotroom block `pane`, works on `key`. No link when the two are
-- not on the same host, or the saved links cannot be read. `chain`: the saved action it ran; earlier agents of the key
-- that ran a saved action stay linked, so a chain's panes can each be mapped back to their action.
function M.recordAgent(cx: WindowCx, pane: number, key: string, agent: number, chain: Chain?, info: AgentInfo?)
	local host, agentHost = hostOf(cx, pane), hostOf(cx, agent)
	if not host or not agentHost or not hostSame(host, agentHost) then
		return
	end
	local links, healthy = readLinks()
	if not healthy then
		return cx:toast("info", "Agent started, but not linked to " .. key, "The saved agent links could not be read.")
	end
	local out: { Link } = { { key = key, agent = agent, host = host, at = math.floor(tern.now()), chain = chain, action = if info then clip(info.action, ACTION_CAP) else nil, branch = if info then clip(info.branch, BRANCH_CAP) else nil, title = if info then clip(info.title, TITLE_CAP) else nil, cwd = if info and info.cwd and #info.cwd <= 4096 then info.cwd else nil } }
	for _, l in links do
		if l.agent ~= agent and (not (l.key == key and hostSame(l.host, host)) or l.chain ~= nil) then
			table.insert(out, l)
		end
	end
	if not writeLinks(out) then
		return cx:toast("info", "Agent started, but not linked to " .. key, "The agent links could not be saved.")
	end
	M.agentSync(cx)
	M.ensureSync(cx)
end

-- The chain of the finished agent pane `agent`, once: its link says what to start next, and the next action is cleared
-- so a later finish of the same agent (another turn) starts nothing. `result`: how the turn ended; any but "done" clears
-- it whether or not a block is open. Returns that chain and the Plotroom block on the agent's host to start it from (the
-- block that started the chain while it is still one on that host, else the lowest); nil for an agent with no next
-- action or an unreadable store; no block for a "done" turn leaves the action for the agent's next finish.
function M.takeChain(cx: WindowCx, agent: number, result: string): (Chain?, number?)
	local host = hostOf(cx, agent)
	local links, healthy = readLinks()
	if not host or not healthy then
		return nil, nil
	end
	for _, l in links do
		if l.agent == agent and hostSame(l.host, host) then
			-- The newest link of the pane only: a pane id reused after a restart never starts an older chain.
			if not (l.chain and l.chain.next) then
				return nil, nil
			end
			local block: number? = nil
			local from = l.chain.pane
			for _, p in plotroomPanes(cx) do
				local ph = hostOf(cx, p)
				if ph and hostSame(ph, host) then
					if p == from then
						block = p
						break
					end
					block = block or p
				end
			end
			-- No Plotroom block on that host: the next action stays for the agent's next finish.
			if not block and result == "done" then
				return table.clone(l.chain), nil
			end
			local taken: Chain = table.clone(l.chain)
			l.chain.next = nil
			if not writeLinks(links) then
				return nil, nil
			end
			return taken, block
		end
	end
	return nil, nil
end

-- Saves how the agent pane `agent`'s turn ended (done, failed, exited, closed) and when (HH:MM) on its link, for the
-- Agents list and Carly's `plotroom_agents`. Nothing for an agent with no link or a store that cannot be read.
function M.recordResult(cx: WindowCx, agent: number, result: string)
	local host = hostOf(cx, agent)
	local links, healthy = readLinks()
	if not healthy or not host then
		return
	end
	for _, l in links do
		if l.agent == agent and hostSame(l.host, host) then
			l.result, l.ended = clip(result, RESULT_CAP), os.date("%H:%M")
			writeLinks(links)
			return
		end
	end
end

-- The linked agents, newest first, for Carly's `plotroom_agents`: item key, action name, state and (once its turn
-- ended) result. A finished agent that is gone stays listed with state "exited". Read-only.
function M.agentList(cx: WindowCx): { { item: string, action: string, state: string, result: string? } }
	local out = {}
	local states, _, cwds = agentStates(cx)
	if not states then
		return out
	end
	for _, l in (readLinks()) do
		local state = stateOf(l, states, cwds) or (if l.result then "exited" else nil)
		if state then
			table.insert(out, { item = l.key, action = if l.chain and l.chain.name ~= "" then l.chain.name else l.action or "", state = state, result = l.result })
		end
	end
	return out
end

-- The newest link for `key` on `pane`'s host, and its state; nil link when none, with state "exited" for one whose
-- agent is gone.
function M.liveAgent(cx: WindowCx, pane: number, key: string): (Link?, string?)
	local host = hostOf(cx, pane)
	local states, _, cwds = agentStates(cx)
	if not host or not states then
		return nil, nil
	end
	for _, l in (readLinks()) do
		if l.key == key and hostSame(l.host, host) then
			local state = stateOf(l, states, cwds) or "exited"
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

-- plotroom://worktrees/git: opens Tern's git block on the worktree the block's card (or selected Worktrees row) is about.
-- Tern's git block reads this machine's repositories, so a block on a remote host is refused.
function M.openGit(cx: WindowCx, pane: number, url: string)
	if e().nodeProp(e().readNode(cx, pane, GIT_NODE), "href") ~= url then
		return cx:toast("error", "Plotroom: that worktree is no longer listed", "Refresh and try again.")
	end
	local ok, hosts = pcall(function()
		return cx.hosts:list()
	end)
	local local_ = false
	if ok and type(hosts) == "table" then
		for _, h in hosts do
			if type(h.panes) == "table" and table.find(h.panes, pane) then
				local_ = h.kind == "local"
			end
		end
	end
	if not local_ then
		return cx:toast("error", "Open in Git works on this machine's worktrees only", "This block runs on another host.")
	end
	e().ask(cx, pane, "git-path", {}, ACT_MS, function(a: any, cx2: WindowCx)
		local why = problemOf(a)
		if why then
			return cx2:toast("error", "Git not opened", why)
		elseif type(a.path) ~= "string" or a.path == "" or #a.path > 4096 or string.find(a.path, "%c") then
			return cx2:toast("error", "Git not opened", "The block's host gave no usable path")
		end
		cx2.git:open(a.path):next(function(_, err, cx3)
			if err and cx3 then
				cx3:toast("error", "Git not opened", err)
			end
		end)
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

-- Interrupt, Stop or Message (`act`: agentint | agentstop | agentmsg) the live agent recorded for `key`. Stop asks first;
-- each step looks the agent up again, so one that exited meanwhile only toasts.
function M.agentCommand(cx: WindowCx, pane: number, key: string, act: string)
	local function run(cx2: WindowCx, what: string, fn: (number) -> ...any)
		local link = M.liveAgent(cx2, pane, key)
		if not link then
			return cx2:toast("info", "No agent is running for " .. key)
		end
		local ok, err = pcall(fn, link.agent)
		if not ok then
			cx2:toast("error", "Could not " .. what .. " the agent for " .. key, tostring(err))
		end
	end
	if not M.liveAgent(cx, pane, key) then
		return cx:toast("info", "No agent is running for " .. key)
	end
	if act == "agentint" then
		run(cx, "interrupt", function(agent)
			cx.agents:interrupt(agent)
		end)
	elseif act == "agentstop" then
		confirmPick(cx, "Stop the agent for " .. key .. "?", "Stop agent", { key }, function(cx2)
			run(cx2, "stop", function(agent)
				cx2.agents:stop(agent)
			end)
		end)
	elseif act == "agentmsg" then
		cx:prompt({ placeholder = "Message for the agent of " .. key, icon = "merge", action = "send" }):next(function(text, _, cx2)
			local line = if text then trim(text) else ""
			if cx2 and line ~= "" then
				run(cx2, "message", function(agent)
					cx2.agents:ask(agent, line)
				end)
			elseif cx2 and text then
				cx2:toast("info", "Nothing to send: the message was blank")
			end
		end)
	elseif act == "agentpick" then
		local link = M.liveAgent(cx, pane, key)
		if link then
			M.pickPage(cx, key, link.agent)
		end
	end
end

-- ---------------------------------------------------------------- context for an agent

local SEL_CHARS = 4000 -- the most of a selection or a picked element's text put in a draft; more is clipped, and the draft says so

-- Whether the agent in `pane` is listed and has not exited.
local function agentLive(cx: WindowCx, agent: number): boolean
	local states = agentStates(cx)
	local s = if states then states[agent] else nil
	return s ~= nil and s ~= "exited"
end

local LINE_CHARS = 300 -- a context line is shown (and sent) up to this many bytes
local NOTE_CHARS = 400

-- `text` as the lines that are both shown in the review and sent (so what is read is what goes): at most MAX_ROWS lines
-- of LINE_CHARS bytes; each cut is said by a closing line. `clipped`: the text was already cut by the reader.
local function contextLines(text: string, clipped: boolean): { string }
	local out: { string } = {}
	local total, cut = 0, false
	local body = (string.gsub((string.gsub(text, "\r\n?", "\n")), "\n+$", ""))
	for line in string.gmatch(body .. "\n", "([^\n]*)\n") do
		total += 1
		if #out < MAX_ROWS then
			if #line > LINE_CHARS then
				local at = LINE_CHARS
				while at > 0 and string.byte(line, at + 1) and bit32.band(string.byte(line, at + 1), 0xC0) == 0x80 do
					at -= 1 -- never cut inside a UTF-8 character
				end
				line, cut = string.sub(line, 1, at) .. "…", true
			end
			table.insert(out, line)
		end
	end
	if total > #out or cut or clipped then
		table.insert(out, "[clipped: " .. (if total > #out then "first " .. #out .. " of " .. total .. " lines" else "long lines or the end of the text cut") .. "]")
	end
	return out
end

-- Sends `body` to `agent` by `agents:ask`; an agent that exited meanwhile or a refused delivery sends nothing and says why.
local function sendTo(cx: WindowCx, agent: number, key: string, body: string)
	if not agentLive(cx, agent) then
		return cx:toast("info", "No agent is running for " .. key)
	end
	local ok, err = pcall(function()
		cx.agents:ask(agent, body)
	end)
	if ok then
		cx:toast("success", "Sent to the agent of " .. key)
	else
		cx:toast("error", "Could not message the agent for " .. key, tostring(err))
	end
end

-- The review of a message for `agent`: the picker lists, Cancel first, Send, a one-line note the user types (the prompt
-- is one line, so the note is the editable part) and then every line of `context` as it will be sent, newlines
-- kept. Nothing is sent but by the Send row; Escape or Cancel sends nothing.
local function review(cx: WindowCx, agent: number, key: string, head: string, context: { string }, note: string)
	local items: { PickItem } = { { label = "Cancel", icon = "x" }, { label = "Send to " .. key, icon = "merge", confirm = true }, { label = if note == "" then "Add a note…" else "Edit note…", icon = "pencil", edit = true } }
	if note ~= "" then
		table.insert(items, { label = note, group = "Note", icon = "merge" })
	end
	for _, line in context do
		table.insert(items, { label = if line == "" then " " else line, group = "Message" })
	end
	cx:pick({ items = items, placeholder = head, icon = "merge", action = "confirm" }):next(function(item, _, cx2)
		if not cx2 or not item then
			return
		elseif item.edit == true then
			cx2:prompt({ value = note, placeholder = "A note for the agent of " .. key .. " (one line)", icon = "merge", action = "review" }):next(function(text, _, cx3)
				if not cx3 or not text then
					return
				end
				local line = trim((string.gsub(text, "%c", " ")))
				if (utf8.len(line) or #line) > NOTE_CHARS then
					return cx3:toast("error", "The note is too long", "At most " .. NOTE_CHARS .. " characters.")
				end
				review(cx3, agent, key, head, context, line)
			end)
		elseif item.confirm == true then
			sendTo(cx2, agent, key, (if note ~= "" then note .. "\n\n" else "") .. table.concat(context, "\n"))
		end
	end)
end

type Picked = { pane: number, kind: string, text: string, clipped: boolean }
-- A selected range of a file block: `session:read` gives a file's selection only as `{anchor, head}` byte offsets into
-- its text, and `session:selection` gives none, so the text is read from the file (`docs:read`, with unsaved edits).
type FileSel = { pane: number, path: string, lo: number, hi: number, size: number? }

-- The selection now, read at once (before any picker, prompt or the file read moves focus or time on): a Picked text
-- for the focused block's, else any block's (`session:selection`); or, for a focused file with a range selected, the
-- offsets to cut its text by. Nothing for neither.
local function captureSelection(cx: WindowCx): (Picked?, FileSel?)
	local focused = cx.session:focused()
	local focusedInfo = if focused then cx.session:pane(focused) else nil
	-- `selection(nil)` is the focused block's, else any block's, and a file's range is never in it: with a file focused,
	-- ask for it by its pane, so another block's old selection is not taken for it.
	local onFile = focusedInfo ~= nil and focusedInfo.kind == "file"
	local ok, sel = pcall(function()
		return cx.session:selection(if onFile then focused else nil, { max_chars = SEL_CHARS })
	end)
	if ok and type(sel) == "table" and type(sel.text) == "string" and sel.text ~= "" then
		return { pane = sel.pane, kind = sel.kind, text = sel.text, clipped = sel.chars_clipped == true }, nil
	end
	if not focused then
		return nil, nil
	end
	local okRead, readAny = pcall(function()
		return cx.session:read(focused, { lines = 1 })
	end)
	local read: any = readAny
	if okRead and type(read) == "table" and read.kind == "file" and type(read.path) == "string" and read.path ~= "" and type(read.selection) == "table" then
		local a, b = read.selection.anchor, read.selection.head
		if type(a) == "number" and type(b) == "number" and a >= 0 and b >= 0 and a == math.floor(a) and b == math.floor(b) and a ~= b then
			return nil, { pane = focused, path = read.path, lo = math.min(a, b), hi = math.max(a, b), size = if type(read.size) == "number" then read.size else nil }
		end
	end
	return nil, nil
end

-- The bytes [lo, hi) of `text` when both ends fall on character boundaries (never silently moved), cut to SEL_CHARS
-- bytes on a boundary; and whether it was cut. Nothing, and why, when it cannot be cut.
local function sliceFile(text: string, lo: number, hi: number): (string?, boolean, string?)
	local function inside(at: number): boolean -- the byte at 0-based `at` continues a character
		local b = string.byte(text, at + 1)
		return b ~= nil and bit32.band(b, 0xC0) == 0x80
	end
	if hi > #text then
		return nil, false, "The file changed since it was selected."
	elseif inside(lo) or inside(hi) then
		return nil, false, "The selection does not fall on character boundaries."
	end
	local stop, clipped = hi, false
	if hi - lo > SEL_CHARS then
		stop, clipped = lo + SEL_CHARS, true
		while stop > lo and inside(stop) do
			stop -= 1
		end
	end
	return string.sub(text, lo + 1, stop), clipped, nil
end

-- Whether `pane` runs on this machine (the one `docs:read` reads files of).
local function isLocalPane(cx: WindowCx, pane: number): boolean
	local ok, hosts = pcall(function()
		return cx.hosts:list()
	end)
	if ok and type(hosts) == "table" then
		for _, h in hosts do
			if type(h.panes) == "table" and table.find(h.panes, pane) then
				return h.kind == "local"
			end
		end
	end
	return false
end

-- The agent picker, then the review, for the selection `sel`.
local function offerSelection(cx: WindowCx, sel: Picked)
	local links, healthy = readLinks()
	local states, _, cwds = agentStates(cx)
	if not healthy or not states then
		return cx:toast("error", "The linked agents could not be read", "Try again in a moment.")
	end
	local items: { PickItem } = {}
	local seen: { [number]: boolean } = {}
	for _, l in links do
		local state = stateOf(l, states, cwds)
		if state and state ~= "exited" and not seen[l.agent] then
			local host = hostOf(cx, l.agent)
			-- A pane id is reused after a restart: only an agent on the recorded host belongs to the link.
			if host and hostSame(host, l.host) then
				seen[l.agent] = true
				local where = if l.host.address ~= "" then " · " .. (if l.host.name ~= "" then l.host.name else l.host.address) else ""
				table.insert(items, { label = l.key, detail = (l.action or "agent") .. " · " .. M.stateLabel(state) .. where, icon = "merge", agent = l.agent })
			end
		end
	end
	if #items == 0 then
		return cx:toast("info", "No linked agent is running", "Start an agent from a Plotroom item first.")
	end
	local info = cx.session:pane(sel.pane)
	local shown = if info and type(info.title) == "string" then clip(info.title, 80) else nil
	local title = if shown then ' "' .. shown .. '"' else ""
	local head = "Selected in the " .. sel.kind .. " block" .. title .. ":"
	local context = contextLines(sel.text, sel.clipped)
	table.insert(context, 1, head)
	local placeholder = "Send the selection (" .. (utf8.len(sel.text) or #sel.text) .. " characters" .. (if sel.clipped then ", clipped" else "") .. ") to which agent?"
	cx:pick({ items = items, placeholder = placeholder, icon = "merge", action = "choose" }):next(function(item, _, cx2)
		if not cx2 or not item or type(item.agent) ~= "number" then
			return
		end
		review(cx2, item.agent, item.label, "Send the selection to the agent of " .. item.label .. "?", context, "")
	end)
end

-- Plotroom: Message an agent with the selection…: the selection is read first and kept; the user then picks which linked
-- agent takes it (each live agent once) and reviews the message, which names the block it came from and says when it
-- was clipped. A file's text is read from the file after the offsets were taken; the offsets are used only while that
-- block still shows the same selection (and size) once the text arrived, and only on this machine.
-- ponytail: an edit that keeps the size and the selection between the two reads goes unseen; re-read until stable if it matters.
function M.messageSelection(cx: WindowCx)
	local sel, file = captureSelection(cx)
	if sel then
		return offerSelection(cx, sel)
	elseif not file then
		return cx:toast("info", "Select some text first", "In a terminal, agent, Browser, file or Plotroom block, then run the command again.")
	elseif not isLocalPane(cx, file.pane) then
		return cx:toast("error", "That file is on another host", "A file's selection is read on this machine only.")
	end
	cx.docs:read(file.path):next(function(text, err, cx2)
		if not cx2 then
			return
		elseif err or type(text) ~= "string" then
			return cx2:toast("error", "The file could not be read", if err then tostring(err) else nil)
		end
		local again, now = captureSelection(cx2)
		if again or not now or now.pane ~= file.pane or now.path ~= file.path or now.lo ~= file.lo or now.hi ~= file.hi or now.size ~= file.size then
			return cx2:toast("info", "The selection changed while the file was read", "Select it again.")
		end
		local slice, clipped, why = sliceFile(text, file.lo, file.hi)
		if not slice then
			return cx2:toast("error", "The selection could not be read", why)
		end
		offerSelection(cx2, { pane = file.pane, kind = "file", text = slice, clipped = clipped })
	end)
end

-- The Browser blocks this window shows (the ones `cx.browser`'s pick can drive), as picker rows.
local function browserRows(cx: WindowCx): { PickItem }
	local rows: { PickItem } = {}
	for _, p in cx.session:panes() do
		if p.kind == "browser" and p.parked ~= true and p.tab ~= nil then -- one the user can see and click
			local title = if type(p.title) == "string" and p.title ~= "" then p.title else "Browser"
			table.insert(rows, { label = title, detail = p.url, icon = "globe", browser = p.pane })
		end
	end
	table.sort(rows, function(a: PickItem, b: PickItem)
		return (a.browser :: number) < (b.browser :: number)
	end)
	return rows
end

-- The picked element as a draft: the page, then the element's role, name, selector and (clipped) text. Its value is left
-- out on purpose: a form field may hold a password.
local function pickDraft(picked: any, url: any, title: any): string
	local lines: { string } = {}
	local page = clip(if type(title) == "string" then title else nil, 200)
	table.insert(lines, "Page: " .. (page or "(untitled)") .. " <" .. (clip(if type(url) == "string" then url else nil, 500) or "") .. ">")
	local what = clip(if type(picked.tag) == "string" then picked.tag else nil, 40) or "element"
	if type(picked.role) == "string" and picked.role ~= "" then
		what ..= " role=" .. (clip(picked.role, 40) or "")
	end
	if type(picked.name) == "string" and picked.name ~= "" then
		what ..= ' name="' .. (clip(picked.name, 200) or "") .. '"'
	end
	table.insert(lines, "Element: " .. what)
	if type(picked.selector) == "string" and picked.selector ~= "" then
		table.insert(lines, "Selector: " .. (clip(picked.selector, 300) or ""))
	end
	if type(picked.text) == "string" and picked.text ~= "" then
		local text = clip(picked.text, SEL_CHARS) or ""
		table.insert(lines, "Text: " .. text .. (if #picked.text > SEL_CHARS then " … [clipped to " .. SEL_CHARS .. " bytes]" else ""))
	end
	return table.concat(lines, "\n")
end

-- Plotroom: Send a Browser page element to the selected item's agent…: the user picks (if several) one of the window's
-- Browser blocks and clicks an element in it (`cx.browser` pick; Escape cancels); the element and its page are the draft
-- the user edits before it is sent to `agent`. Only a Browser block already open is used: none is opened here (the
-- Open commands do, on the link path, and whatever profile Tern gives that Browser block is the one the page is read in).
function M.pickPage(cx: WindowCx, key: string, agent: number)
	local rows = browserRows(cx)
	if #rows == 0 then
		return cx:toast("info", "Open a Browser block first", "Use Open in Browser on the item, then run this again.")
	end
	local function start(cx2: WindowCx, block: number)
		local session = e().sourceSession(cx2, block)
		if session then
			cx2.sessions:switch(session)
		end
		cx2.layout:focus(block)
		cx2:toast("info", "Click an element in the Browser", "Escape cancels.")
		cx2.browser:call({ op = "pick", block = block }):next(function(result, err, cx3)
			if not cx3 then
				return
			end
			local bad = if err then tostring(err) elseif type(result) ~= "table" then "Browser gave no answer" elseif result.error then tostring(result.error.message) else nil
			local ok: any = if type(result) == "table" then result.ok else nil
			if bad or type(ok) ~= "table" then
				return cx3:toast("error", "Could not pick a page element", bad or "Browser gave no answer")
			elseif ok.cancelled == true then
				return cx3:toast("info", "Nothing picked", "The pick was cancelled.")
			elseif type(ok.picked) ~= "table" then
				return cx3:toast("error", "Could not pick a page element", "Browser gave no element")
			end
			local context = contextLines(pickDraft(ok.picked, ok.url, ok.title), false)
			review(cx3, agent, key, "Send this page element to the agent of " .. key .. "?", context, "")
		end)
	end
	if #rows == 1 then
		return start(cx, rows[1].browser :: number)
	end
	cx:pick({ items = rows, placeholder = "Pick an element in which Browser?", icon = "globe", action = "pick" }):next(function(item, _, cx2)
		if cx2 and item and type(item.browser) == "number" then
			start(cx2, item.browser)
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

-- The Inbox list's notifications marked read: the host names the listed threads and the account in the confirm.
local function inboxRead(cx: WindowCx, pane: number)
	planAct(cx, pane, "Not marked read", { name = "inbox-read" })
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

-- The host answers the methods the repository allows (and whether auto-merge applies); the plan comes with the choice.
local function prMerge(cx: WindowCx, pane: number)
	e().ask(cx, pane, "act", { name = "pr-merge" }, ACT_MS, function(a: any, cx2: WindowCx)
		local why = problemOf(a)
		if why then
			return cx2:toast("error", "Not merged", why)
		end
		local items: { PickItem } = {}
		local methods: { { id: string, label: string } } = {}
		for _, m in if type(a.methods) == "table" then a.methods else {} do
			if type(m) == "table" and type(m.id) == "string" and type(m.label) == "string" then
				table.insert(methods, { id = m.id, label = m.label })
				table.insert(items, { label = m.label, method = m.id, group = "Merge now" })
			end
		end
		if a.auto == true then
			for _, m in methods do
				table.insert(items, { label = "Auto-merge when checks pass", detail = m.label, method = m.id, auto = true, group = "Checks pending" })
			end
		end
		if #items == 0 then
			return cx2:toast("info", "The repository offers no merge method")
		end
		cx2:pick({ items = items, placeholder = "Merge the selected PR…", icon = "merge", action = "plan" }):next(function(picked, _, cx3)
			if picked and cx3 then
				planAct(cx3, pane, "Not merged", { name = "pr-merge", method = picked.method, auto = picked.auto == true })
			end
		end)
	end)
end

-- One-line prompt; an approval's comment is optional (empty sends none), a request for changes needs one.
local function prApprove(cx: WindowCx, pane: number)
	cx:prompt({ placeholder = "Approval comment (optional)", icon = "merge", action = "plan" }):next(function(text, _, cx2)
		if cx2 and text then
			local t = trim(text)
			planAct(cx2, pane, "Not approved", { name = "pr-approve", text = if t == "" then nil else t })
		end
	end)
end

local function prRequestChanges(cx: WindowCx, pane: number)
	cx:prompt({ placeholder = "What needs to change on the selected PR?", icon = "merge", action = "plan" }):next(function(text, _, cx2)
		if cx2 and text and trim(text) ~= "" then
			planAct(cx2, pane, "Changes not requested", { name = "pr-request-changes", text = trim(text) })
		end
	end)
end

local function prUpdateBranch(cx: WindowCx, pane: number)
	planAct(cx, pane, "Branch not updated", { name = "pr-update-branch" })
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
				local askFile: (WindowCx) -> ()
				local function commit(cx6: WindowCx, path: string?)
					local ca: { [string]: any } = { phase = "commit", token = token }
					if path then
						ca.path = path
					end
					e().ask(cx6, pane, "export", ca, ACT_MS, function(r2: any, cx7: WindowCx)
						local why3 = problemOf(r2)
						if why3 then
							cx7:toast("error", "Not exported", why3)
							if r2.retry == true then
								askFile(cx7) -- the host kept the snapshot: another file name tries it again
							end
							return
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
				askFile = function(cxp: WindowCx)
					cxp:prompt({ placeholder = "File path to write the export to", icon = "merge", action = "export" }):next(function(text, _, cx7)
						local path = if text then trim(text) else ""
						if cx7 and path ~= "" then
							commit(cx7, path)
						end
					end)
				end
				cx5:pick({ items = rows, placeholder = "Export " .. actual, icon = "merge", action = "export" }):next(function(item, _, cx6)
					if not item or not cx6 then
						return
					elseif item.mode == "copy" then
						commit(cx6, nil)
					elseif item.mode == "file" then
						askFile(cx6)
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

-- Opens `url` in the Plotroom block `pane`, or in a launched one when there is none.
local function openIn(cx: WindowCx, pane: number?, url: string)
	if pane then
		cx.layout:focus(pane)
		return whenReady(cx, pane, 0, function(cx3: WindowCx)
			sendUrl(cx3, pane :: number, url)
		end)
	end
	local launched = e().launch(cx)
	if not launched then
		return
	end
	whenReady(cx, launched, OPEN_URL_TRIES, function(cx3: WindowCx)
		sendUrl(cx3, launched, url)
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
		openIn(cx2, if focused and e().isPlotroom(cx2, focused) then focused else plotroomPanes(cx2)[1], url)
	end)
end

-- The shell lens's Show in Plotroom: `url` opens, as Open item by URL does, in a Plotroom block on the host of `from`
-- (the pane the lens is in), else a block is launched there.
function M.showUrl(cx: WindowCx, from: number, url: string)
	local host = hostOf(cx, from)
	local found: number? = nil
	for _, p in plotroomPanes(cx) do
		local ph = hostOf(cx, p)
		if host and ph and hostSame(ph, host) then
			found = p
			break
		end
	end
	if not found then
		cx.layout:focus(from)
	end
	openIn(cx, found, url)
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
-- they are (or, as Worktrees list, as the Views scope). An item's own operation has no `group`: the host names it by the
-- item's type (GitHub - PR, GitHub - Issue, Jira - Issue). All but `anywhere` ones need a focused Plotroom block, which
-- the window checks.
export type Command = { id: string, title: string, label: string, group: string?, run: (WindowCx, number) -> (), anywhere: boolean?, keyed: boolean? }

M.COMMANDS = {
	{ id = "open-url", title = "Plotroom: Open item by URL", label = "Open item by URL…", group = "Views", run = M.openByUrl, anywhere = true },
	{
		id = "open-preview",
		title = "Plotroom: Preview the selected PR or issue",
		label = "Open floating preview",
		keyed = false,
		run = function(cx: WindowCx, pane: number)
			e().follow(cx, pane, OPEN_NODE, "Select a pull request or issue first", nil, "preview")
		end,
	},
	{
		id = "agent-pick-page",
		title = "Plotroom: Send a Browser page element to the selected item's agent…",
		label = "Send page element to agent…",
		group = "Saved actions",
		run = function(cx: WindowCx, pane: number)
			e().follow(cx, pane, AGENTMSG_NODE, "The selected item has no agent", nil, "agentpick")
		end,
	},
	{
		id = "agent-message-selection",
		title = "Plotroom: Message an agent with the selection…",
		label = "Message an agent with the selection…",
		group = "Saved actions",
		run = function(cx: WindowCx, _pane: number)
			M.messageSelection(cx)
		end,
		anywhere = true,
	},
	{ id = "inbox-read", title = "Plotroom: Mark the Inbox's notifications read", label = "Mark read…", group = "Inbox", run = inboxRead },
	{
		id = "agent-go",
		title = "Plotroom: Go to the selected item's agent",
		label = "Go to agent",
		group = "Saved actions",
		keyed = true,
		run = function(cx: WindowCx, pane: number)
			e().follow(cx, pane, AGENTGO_NODE, "The selected item has no agent")
		end,
	},
	{ id = "assign-me", title = "Plotroom: Assign the selected issue to me", label = "Assign to me", run = assignMe },
	{ id = "comment", title = "Plotroom: Comment on the selected item", label = "Comment…", run = comment },
	{ id = "label-add", title = "Plotroom: Add a label to the selected issue", label = "Add label…", run = labelAdd },
	{ id = "label-remove", title = "Plotroom: Remove a label from the selected issue", label = "Remove label…", run = labelRemove },
	{ id = "issue-close", title = "Plotroom: Close the selected GitHub issue", label = "Close issue…", run = issueClose },
	{ id = "issue-reopen", title = "Plotroom: Reopen the selected GitHub issue", label = "Reopen issue…", run = issueReopen },
	{ id = "pr-ready", title = "Plotroom: Mark the selected draft PR ready for review", label = "Ready for review…", run = prReady },
	{ id = "pr-draft", title = "Plotroom: Convert the selected PR to a draft", label = "Convert to draft…", run = prDraft },
	{ id = "pr-merge", title = "Plotroom: Merge the selected PR", label = "Merge…", run = prMerge },
	{ id = "pr-approve", title = "Plotroom: Approve the selected PR", label = "Approve…", run = prApprove },
	{ id = "pr-request-changes", title = "Plotroom: Request changes on the selected PR", label = "Request changes…", run = prRequestChanges },
	{ id = "pr-update-branch", title = "Plotroom: Update the selected PR's branch from its base", label = "Update branch…", run = prUpdateBranch },
	{ id = "jira-transition", title = "Plotroom: Move the selected Jira issue to another status", label = "Jira transition…", run = jiraTransition },
	{ id = "rerun-failed", title = "Plotroom: Re-run the selected PR's failed checks", label = "Re-run failed checks", run = rerunFailed },
	{ id = "rerun-all", title = "Plotroom: Re-run every job of one of the selected PR's finished runs", label = "Re-run all jobs…", run = rerunAll },
	{ id = "cancel-run", title = "Plotroom: Cancel a running workflow run of the selected PR", label = "Cancel running workflow…", run = cancelRun },
	{ id = "draft-pr", title = "Plotroom: Open a draft PR from the selected item's worktree", label = "Draft PR…", run = draftPr },
	{ id = "export", title = "Plotroom: Export views and actions", label = "Export views and actions…", group = "Configuration", run = exportFlow },
	{ id = "import", title = "Plotroom: Import views and actions", label = "Import views and actions…", group = "Configuration", run = importFlow },
	{ id = "mark-seen", title = "Plotroom: Mark the selected item seen", label = "Mark seen", group = "Triage", run = triage("seen"), keyed = true },
	{ id = "snooze", title = "Plotroom: Snooze the selected item", label = "Snooze", group = "Triage", run = triage("snooze"), keyed = true },
	{ id = "toggle-snoozed", title = "Plotroom: Show or hide snoozed items", label = "Show or hide snoozed", group = "Filter & Sort", run = triage("toggle-snoozed"), keyed = true },
	{ id = "attention", title = "Plotroom: Show only items needing attention", label = "Needs attention filter", group = "Filter & Sort", run = triage("toggle-attention"), keyed = true },
	{ id = "sort", title = "Plotroom: Next sort order", label = "Next sort order", group = "Filter & Sort", run = send("sort", "next"), keyed = true },
	{ id = "worktrees-open", title = "Plotroom: Open the Worktrees list", label = "Worktrees list", group = "Views", run = send("open-worktrees", nil), keyed = true },
} :: { Command }

return M
