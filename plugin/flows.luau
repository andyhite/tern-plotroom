--!strict
-- The window's workflow flows: agent links (which agent pane works on which item, kept in kv `agent-links`, and the
-- timer that tells each Plotroom block how those agents are doing), the guided mutations (assign, labels,
-- re-run, draft PR: always plan, Cancel-first confirm, commit), Open item by URL and the
-- commands the command palette lists. window.luau injects what it owns (`setup`), so there is no require cycle.

local input = require("./input")
local keys = require("./keys")
local prompts = require("./prompts")
local usage = require("./usage")
local trim = input.trim

local M = {}

export type Env = {
	-- `quiet`: a background request: an older host or no answer is not toasted (no answer: done is not called).
	ask: (cx: WindowCx, pane: number, op: string, args: { [string]: any }, ms: number, done: (any, WindowCx) -> (), quiet: boolean?) -> boolean,
	isPlotroom: (cx: WindowCx, pane: number) -> boolean,
	readNode: (cx: WindowCx, pane: number, id: string) -> any?,
	nodeProp: (node: any, prop: string) -> any?,
	sourceSession: (cx: WindowCx, pane: number) -> number?,
	targetPane: (cx: WindowCx, path: string) -> (number?, number?, number?),
	launch: (cx: WindowCx) -> number?,
	-- Follows the hidden link node `nodeId` of `pane` (the same validation as a click on it); `missing` is said when
	-- the node has none; `typed` asks for a typed prompt.
	follow: (cx: WindowCx, pane: number, nodeId: string, missing: string?, typed: boolean?) -> (),
	-- Every Tern palette command's title by id (window.luau fills it as it registers them), for the usage report.
	titles: { [string]: string },
	-- Starts the chain steps now due (dueSteps); flows calls it when a verdict or the 4 s tick may have made one due.
	drive: (cx: WindowCx) -> (),
}

-- A Plotroom block's host: Tern's slot id and its address ("" for this machine), the name only for people.
type HostId = { id: number, name: string, address: string }
-- The saved action an agent ran, kept with its link: `next` (nil once started or stopped) is the action to start when the
-- agent finishes, for the same item (`kind`, `repo`, `ref`), or `prs:<id>` for a pull request action on the pull request
-- of the agent's worktree `branch` in the code repository `code` (an issue's `repo` can be a Jira project key); `depth`
-- counts the actions chained before it. `checker` (nil: none) is the action that checks a run of it ending with a commit.
type Chain = { action: string, name: string, next: string?, kind: string, repo: string, ref: string, depth: number, code: string?, branch: string?, pane: number?, checker: string? }
-- `started` (seconds since the epoch), `kind`, `model` and `runsIn` go into the run log (usage.luau) when its turn ends.
-- `attention`, `reason` and `blocker`: its agent's last end-of-run report (`attention` "none": no valid one), for the
-- Agents list. `outcome` (a prompts.OUTCOMES id; nil: none) is what its action says the run must leave behind, checked
-- on GitHub as gh login `login` on repository `ghRepo` (pull request `number`, the worktree's `branch`, the report's
-- `commit`); `verdict` is what the last check found (verified | not | unchecked) and `checked` when it was asked.
-- `criteria`: the acceptance criteria saved on the run at dispatch. A builder's `checkedCommit` is the last commit a
-- checker was started for. A checker's link names the run it checks (`checkAgent`, `checkStarted`) and what it found
-- (`check`: pass | fail; `findings` joined by " · ").
-- `gate`: where a run of a chained or checked action stands in its chain (GATES); `gateFindings` the findings a fix
-- round gets as `{findings}`, one per line. `stop`: why its item's chain stopped at Needs you (a limit; on the item's
-- newest link, so a later run clears it).
-- `run`: as on AgentInfo. `reviewed`: when the newest Draft review file of that run opened in the review block was
-- written (its `at`), so a turn end opens it only for a newer one. `turns`: how many prompts its recorded turns covered
-- (the settle wait's count), so a later turn end of an agent with `run` waits until the transcript shows a newer prompt.
type Link = { key: string, agent: number, host: HostId, at: number, chain: Chain?, action: string?, branch: string?, title: string?, result: string?, ended: string?, cwd: string?, started: number?, kind: string?, model: string?, runsIn: string?, attention: string?, reason: string?, blocker: string?, outcome: string?, verdict: string?, login: string?, ghRepo: string?, number: number?, commit: string?, checked: number?, criteria: string?, checkedCommit: string?, checkAgent: number?, checkStarted: number?, check: string?, findings: string?, gate: string?, gateFindings: string?, stop: string?, run: string?, reviewed: string?, turns: number? }
-- What a link says about its agent beyond the item key (the action's name, the worktree's branch, the item's title); `code`
-- (an issue's code repository) is only for its chain. `kind` ("pr"/"issue"), `model` (nil: omp's default) and `runsIn`
-- ("worktree" or "main checkout") are for the run log; `outcome`, `login`, `ghRepo` and `number` for its outcome check;
-- `criteria`, `checkAgent` and `checkStarted` as on Link. `from`: the chain step this agent was started for.
-- `run`: the run id its agent was started with (PLOTROOM_RUN), naming its Draft review folder; nil when it started
-- without Plotroom's omp extension.
export type AgentInfo = { action: string?, branch: string?, title: string?, code: string?, cwd: string?, kind: string?, model: string?, runsIn: string?, outcome: string?, login: string?, ghRepo: string?, number: number?, criteria: string?, checkAgent: number?, checkStarted: number?, from: Step?, run: string? }
-- `since` and `expected` (whole seconds as text) only while the agent is working: when its run or turn began on this
-- machine's clock, and the median of its action's finished runs (usage.medians; nil: too few, or a later turn).
type StatusRow = { state: string, action: string?, branch: string?, title: string?, last: string?, err: string?, result: string?, ended: string?, attention: string?, reason: string?, blocker: string?, outcome: string?, verdict: string?, check: string?, findings: string?, stop: string?, since: string?, expected: string? }
-- A chain step due to start (dueSteps), from the run of `agent` (its link's `host` and `started`) on item `key`:
-- `step` "check" (checker `chain.checker` on `commit`), "next" (`chain.next`) or "fix" (`chain.action` again, with
-- `findings`), at chain `depth`, from Plotroom block `block`, with the run's saved `criteria`.
export type Step = { step: string, chain: Chain, key: string, agent: number, host: HostId, started: number?, commit: string?, criteria: string?, findings: string?, block: number, depth: number }
type Notes = { [number]: { last: string?, err: string? } }
type Plan = { token: string, head: string, label: string, lines: { string } }

local LINKS_KEY = "agent-links"
local LINKS_CAP = 200
local ACTION_CAP, BRANCH_CAP, TITLE_CAP = 60, 200, 100 -- the host takes up to 120, 200 and 256; a branch is also what an outcome is checked on
local LAST_CAP, RESULT_CAP = 200, 10 -- an agent's last message or delivery error; a run's result and its HH:MM
local FINDINGS_CAP = 1000 -- a check's findings as one line (the host takes up to 1000)
local FIX_CAP = 5000 -- a fix round's findings, one per line (a report keeps 20 of 200 bytes each)
local STOP_CAP = 40 -- why a chain stopped (the host takes up to 40)
-- A run's place in its chain (Link.gate): "outcome" waits for its outcome's verdict, "check" for its check to start and
-- "checking" for the check's verdict; "next" and "fix" are due to start (the next action, or the action again for a fix
-- round); "held" waits for the user (its report asked for them) and is decided again at the agent's next turn end;
-- "over" ends it here. Nil: not decided yet, or not chained.
local GATES = { outcome = true, check = true, checking = true, next = true, fix = true, held = true, over = true }
local STARTS = { check = true, next = true, fix = true } -- the gates that start an agent
M.LIMIT = 3 -- failed checks, runs without progress or failed starts that stop a chain at Needs you
M.MAX_CHAIN = 8 -- actions in one chain, checks included; Settings refuses loops, this stops one that got into the store anyway
M.NO_COMMIT = "The last run named no new commit on its branch, so there was nothing new to check."
local INFO_BYTES = 30000
local SYNC_MS = 4000
local ACT_MS = 30 * 1000
local COMMIT_MS = 3 * 60 * 1000
local EXPECTED_S = 300 -- the run log's medians are read again at most this often, and after every run it gains
local DRAFT_MS = 3 * 60 * 1000 -- the host's ls-remote/fetch may take 120 s
local OPEN_URL_TRIES = 20 -- of 500 ms: a launched block has 10 seconds to say its protocol
local OPEN_URL_STEP_MS = 500
local MAX_TITLE = 256
local MAX_BODY = 8000
local MAX_ROWS = 40
local AGENTGO_NODE = "layer.queue.buttons.agentgo"
local OPEN_NODE = "layer.queue.buttons.open"
M.AGENTGO_NODE, M.OPEN_NODE = AGENTGO_NODE, OPEN_NODE
local WTOPEN_NODE = "layer.queue.buttons.wtopen"
local GIT_NODE = "layer.queue.buttons.git"

local env: Env? = nil

function M.setup(e: Env)
	env = e
end

local function e(): Env
	return env :: Env
end

function M.strOf(v: any): string?
	return if type(v) == "string" then v else nil
end

local function problemOf(a: any): string?
	return M.strOf(a.problem)
end

-- ---------------------------------------------------------------- agent links

local STATES = { working = "working", waiting_input = "needs input", idle = "idle", exited = "exited" }

function M.stateLabel(state: string): string
	return STATES[state] or state
end

-- The window's host list, nil when it cannot be read.
local function hostsOf(cx: WindowCx): { any }?
	local ok, hosts = pcall(function()
		return cx.hosts:list()
	end)
	return if ok and type(hosts) == "table" then hosts else nil
end
M.hostsOf = hostsOf

-- The host of the block `pane`: nil when no host lists it.
local function hostOf(cx: WindowCx, pane: number): HostId?
	local hosts = hostsOf(cx)
	if not hosts then
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
M.hostOf = hostOf

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
			or (r.checker ~= nil and type(r.checker) ~= "string")
		then
			return nil
		end
		c = { action = r.action, name = r.name, next = r.next, kind = tostring(r.kind), repo = r.repo, ref = r.ref, depth = r.depth, code = r.code, branch = r.branch, pane = r.pane, checker = r.checker }
	end
	-- A link saved before the texts were recorded has none; one with a text that is no string is malformed.
	local texts: { [string]: string } = {}
	for _, field in { "action", "branch", "title", "result", "ended", "cwd", "kind", "model", "runsIn", "attention", "reason", "blocker", "outcome", "verdict", "login", "ghRepo", "commit", "criteria", "checkedCommit", "check", "findings", "gate", "gateFindings", "stop", "run", "reviewed" } do
		local v = row[field]
		if v ~= nil and type(v) ~= "string" then
			return nil
		end
		texts[field] = v
	end
	for _, field in { "started", "number", "checked", "checkAgent", "checkStarted", "turns" } do
		if row[field] ~= nil and type(row[field]) ~= "number" then
			return nil
		end
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
		started = row.started,
		kind = clip(texts.kind, ACTION_CAP),
		model = clip(texts.model, ACTION_CAP),
		runsIn = clip(texts.runsIn, ACTION_CAP),
		attention = clip(texts.attention, ACTION_CAP),
		reason = clip(texts.reason, LAST_CAP),
		blocker = clip(texts.blocker, LAST_CAP),
		outcome = clip(texts.outcome, ACTION_CAP),
		verdict = if texts.verdict and usage.VERDICTS[texts.verdict] then texts.verdict else nil,
		login = clip(texts.login, ACTION_CAP),
		ghRepo = clip(texts.ghRepo, TITLE_CAP),
		number = row.number,
		commit = clip(texts.commit, ACTION_CAP + 4),
		checked = row.checked,
		criteria = usage.text(texts.criteria, usage.CRITERIA_CAP),
		checkedCommit = clip(texts.checkedCommit, ACTION_CAP + 4),
		checkAgent = row.checkAgent,
		checkStarted = row.checkStarted,
		check = if texts.check and usage.CHECKS[texts.check] then texts.check else nil,
		findings = clip(texts.findings, FINDINGS_CAP),
		gate = if texts.gate and GATES[texts.gate] then texts.gate else nil,
		gateFindings = usage.text(texts.gateFindings, FIX_CAP),
		stop = clip(texts.stop, STOP_CAP),
		run = clip(texts.run, ACTION_CAP),
		reviewed = clip(texts.reviewed, ACTION_CAP),
		turns = row.turns,
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
		table.insert(rows, { key = l.key, agent = l.agent, host = { id = l.host.id, name = l.host.name, address = l.host.address }, at = l.at, chain = l.chain, action = l.action, branch = l.branch, title = l.title, result = l.result, ended = l.ended, cwd = l.cwd, started = l.started, kind = l.kind, model = l.model, runsIn = l.runsIn, attention = l.attention, reason = l.reason, blocker = l.blocker, outcome = l.outcome, verdict = l.verdict, login = l.login, ghRepo = l.ghRepo, number = l.number, commit = l.commit, checked = l.checked, criteria = l.criteria, checkedCommit = l.checkedCommit, checkAgent = l.checkAgent, checkStarted = l.checkStarted, check = l.check, findings = l.findings, gate = l.gate, gateFindings = l.gateFindings, stop = l.stop, run = l.run, reviewed = l.reviewed, turns = l.turns })
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

-- When each linked agent pane was first seen working in its current turn (os.time); cleared once it is not.
local workingSince: { [number]: number } = {}
-- The run log's medians (usage.medians) as last read, and when; nil: read again when next needed.
local medians: { [string]: number }? = nil
local mediansAt = 0

local function expectedOf(name: string): number?
	if not medians or os.time() - mediansAt >= EXPECTED_S then
		medians, mediansAt = usage.medians(usage.readRuns() or {}), os.time()
	end
	return (medians :: { [string]: number })[name]
end

-- key -> state (and what the link recorded about the agent) for the links recorded on `host` (the newest link of a key
-- counts); an agent pane no longer listed is exited. An exited agent carries no text but its checker verdict (`check`,
-- for Disagree with check…): its row is not shown, and the report stays small. A working agent's run (its first turn)
-- started when its link says and expects its action's median; a later turn started when it was first seen working
-- and expects nothing (the run log times first turns only). ponytail: the texts stop at INFO_BYTES of
-- JSON-encoded size (escapes count: the host's cap is on the encoded report), so a report of many live agents stays
-- under its 40000-byte cap with state and verdict only for the rest; raise the host's cap with the count of agents if
-- that is ever too few.
local function statusMap(links: { Link }, host: HostId, states: { [number]: string }, cwds: { [number]: string }, notes: Notes): { [string]: StatusRow }
	local map: { [string]: StatusRow } = {}
	local count = 0
	local bytes = 0
	for _, l in links do
		if map[l.key] == nil and hostSame(l.host, host) and count < LINKS_CAP then
			local state = stateOf(l, states, cwds) or "exited"
			local note: { last: string?, err: string? } = notes[l.agent] or {}
			local row: StatusRow = { state = state, check = l.check }
			local full: StatusRow = { state = state, action = l.action, branch = l.branch, title = l.title, last = note.last, err = note.err, result = l.result, ended = l.ended, attention = l.attention, reason = l.reason, blocker = l.blocker, outcome = l.outcome, verdict = if l.outcome then l.verdict else nil, check = l.check, findings = if l.check == "fail" then l.findings else nil, stop = l.stop }
			if state == "working" then
				local first = l.result == nil and l.started ~= nil
				local since = if first then l.started else workingSince[l.agent]
				local expected = if first then expectedOf(if l.chain and l.chain.name ~= "" then l.chain.name else l.action or "") else nil
				full.since = if since then tostring(since) else nil
				full.expected = if expected then tostring(math.floor(expected + 0.5)) else nil
			end
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

-- "key=state|action|branch|title|last|err|result|ended|attention|reason|blocker|outcome|verdict|check|findings|stop|since|expected;"
-- per key in order: host/render's `agentSig` spells it the same.
local function signature(map: { [string]: StatusRow }): string
	local keys: { string } = {}
	for k in map do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts: { string } = {}
	for _, k in keys do
		local r = map[k]
		table.insert(parts, k .. "=" .. r.state .. "|" .. (r.action or "") .. "|" .. (r.branch or "") .. "|" .. (r.title or "") .. "|" .. (r.last or "") .. "|" .. (r.err or "") .. "|" .. (r.result or "") .. "|" .. (r.ended or "") .. "|" .. (r.attention or "") .. "|" .. (r.reason or "") .. "|" .. (r.blocker or "") .. "|" .. (r.outcome or "") .. "|" .. (r.verdict or "") .. "|" .. (r.check or "") .. "|" .. (r.findings or "") .. "|" .. (r.stop or "") .. "|" .. (r.since or "") .. "|" .. (r.expected or "") .. ";")
	end
	return table.concat(parts, "")
end

local waiting: { number } = {} -- linked agent panes in "waiting_input", ascending
local waitingSet: { [number]: boolean } = {}

-- How many linked agents wait for input now (what the status line shows).
function M.waitingCount(): number
	return #waiting
end

local need = 0 -- the largest Now count of the Plotroom blocks (their hidden `main.need`)
local needPane: number? = nil -- the block that count is of
local needTimer: TimerHandle? = nil

-- How many need you now (what the status line shows): the largest Now count of the open blocks, and at least the agents
-- that wait for input. ponytail: the largest, not the sum, as blocks of one host list the same Now; sum per host if
-- blocks of several hosts with different work are common.
function M.needCount(): number
	return math.max(need, #waiting)
end

-- Reads each Plotroom block's count; redraws the status line only when the largest changed.
function M.needSync(cx: WindowCx)
	local most, at = 0, nil
	for _, pane in plotroomPanes(cx) do
		local n = tonumber(e().nodeProp(e().readNode(cx, pane, "main.need"), "text"))
		if n and math.floor(n) > most then
			most, at = math.floor(n), pane
		end
	end
	needPane = at
	if most ~= need then
		need = most
		tern.chrome.refresh()
	end
end

local timer: TimerHandle? = nil -- the agents' status timer: runs only while a linked agent is live
local told: { [number]: boolean } = {} -- Plotroom panes seen holding their host's agent map (agentSync)

local function needTick(cx: WindowCx?)
	needTimer = nil
	if not cx then
		return -- the window went away: the next window_start or pane_created starts it again
	end
	M.needSync(cx)
	M.recheck(cx) -- outcomes due again, at most once a refresh each
	if timer == nil and #readLinks() > 0 then
		-- no live agent, so the status timer is off: a block opened since is still told exited agents' verdicts
		-- (Disagree with check…), again each tick until it has rendered its main.agents
		for _, pane in plotroomPanes(cx) do
			if not told[pane] then
				M.agentSync(cx)
				break
			end
		end
	end
	e().drive(cx) -- chain steps due, and starts that failed or were cut by a reload
	if #plotroomPanes(cx) > 0 then
		needTimer = tern.timer(SYNC_MS, needTick)
	end
end

-- Focuses the Plotroom block whose count the status line shows (else the first one) and shows Now in it.
function M.goNow(cx: WindowCx)
	local pane = needPane or plotroomPanes(cx)[1]
	if not pane then
		return cx:toast("info", "No Plotroom block is open")
	end
	local session = e().sourceSession(cx, pane)
	if session then
		cx.sessions:switch(session)
	end
	cx.layout:focus(pane)
	cx.session:event(pane, { ev = "action", act = "open-now" })
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
		told = {}
		trackWaiting(cx, {}, nil, {})
		return
	end
	local states, notes, cwds = agentStates(cx)
	if not states then
		return
	end
	local now = os.time()
	for pane in workingSince do
		if states[pane] ~= "working" then
			workingSince[pane] = nil
		end
	end
	for pane, st in states do
		if st == "working" and not workingSince[pane] then
			workingSince[pane] = now
		end
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
	local nowTold: { [number]: boolean } = {} -- rebuilt each sync, so a closed pane's id is never remembered
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
			if ack ~= nil then
				nowTold[pane] = true -- a rendered block takes the event at once; one not rendered yet is told again
			end
		end
	end
	told = nowTold
end

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
	if needTimer == nil and #plotroomPanes(cx) > 0 then
		needTick(cx)
	end
	if timer == nil and active(cx) then
		timer = tern.timer(SYNC_MS, tick)
	end
end

-- Chain steps whose start is in flight in this plugin VM, by stepId -> when it began (dueSteps), and steps whose last
-- start failed -> when they may be tried again (startFailed).
local starting: { [string]: number } = {}
local retryAt: { [string]: number } = {}
local RETRY_S = 30
local function stepId(host: HostId, agent: number, started: number?): string
	return host.id .. "|" .. host.address .. "|" .. agent .. "|" .. (started or 0)
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
	local out: { Link } = { { key = key, agent = agent, host = host, at = math.floor(tern.now()), chain = chain, action = if info then clip(info.action, ACTION_CAP) else nil, branch = if info then clip(info.branch, BRANCH_CAP) else nil, title = if info then clip(info.title, TITLE_CAP) else nil, cwd = if info and info.cwd and #info.cwd <= 4096 then info.cwd else nil, started = os.time(), kind = if info then clip(info.kind, ACTION_CAP) else nil, model = if info then clip(info.model, ACTION_CAP) else nil, runsIn = if info then clip(info.runsIn, ACTION_CAP) else nil, outcome = if info and prompts.outcomeLabel(info.outcome) then info.outcome else nil, login = if info then clip(info.login, ACTION_CAP) else nil, ghRepo = if info then clip(info.ghRepo, TITLE_CAP) else nil, number = if info then info.number else nil, criteria = if info then usage.text(info.criteria, usage.CRITERIA_CAP) else nil, checkAgent = if info then info.checkAgent else nil, checkStarted = if info then info.checkStarted else nil, run = if info then clip(info.run, ACTION_CAP) else nil } }
	-- The agent of a chain step ends that step on the run it came from (a check now waits for its verdict); one started
	-- by hand ends every open step of its item, so an older chain never starts an agent beside it.
	local from = if info then info.from else nil
	for _, l in links do
		if l.agent ~= agent and (not (l.key == key and hostSame(l.host, host)) or l.chain ~= nil) then
			if from and l.agent == from.agent and hostSame(l.host, from.host) and l.started == from.started and l.gate == from.step then
				l.gate = if from.step == "check" then "checking" else "over"
			elseif not from and l.key == key and hostSame(l.host, host) and l.gate and l.gate ~= "over" then
				l.gate = "over"
			end
			table.insert(out, l)
		end
	end
	if from then
		starting[stepId(from.host, from.agent, from.started)] = nil
	end
	if not writeLinks(out) then
		return cx:toast("info", "Agent started, but not linked to " .. key, "The agent links could not be saved.")
	end
	M.agentSync(cx)
	M.ensureSync(cx)
end

-- The Plotroom block on `host` to start a chain's next action or check from: `from` (the block that started the chain)
-- while it is still one on that host, else the lowest; nil when none is open there.
local function chainBlock(cx: WindowCx, host: HostId, from: number?): number?
	local block: number? = nil
	for _, p in plotroomPanes(cx) do
		local ph = hostOf(cx, p)
		if ph and hostSame(ph, host) then
			if p == from then
				return p
			end
			block = block or p
		end
	end
	return block
end

-- The item a chain works on as the user reads it: "o/r#12", or a Jira issue's key.
local function itemLabel(c: Chain): string
	return if string.find(c.repo, "/", 1, true) then c.repo .. "#" .. c.ref else c.ref
end

local function actionLabel(c: Chain): string
	return if c.name ~= "" then c.name else "the action"
end

-- Ends link `l`'s chain at Needs you for `why` (a limit): the item's newest link on its host carries it, for Now.
local function stopChain(cx: WindowCx, links: { Link }, l: Link, why: string)
	l.gate = "over"
	for _, x in links do
		if x.key == l.key and hostSame(x.host, l.host) then
			x.stop = why
			break
		end
	end
	cx:toast("info", "Chain stopped for " .. (if l.chain then itemLabel(l.chain) else l.key), why)
end

-- A checker's verdict on the run it checks (`c` is the checker's link, in `links`): a pass makes that run's next action
-- due, a fail a fix round with the checker's `findings`, until LIMIT failed checks on the item stop the chain. Only a
-- run whose check is still awaited moves.
local function settleCheck(cx: WindowCx, links: { Link }, c: Link, verdict: string, findings: { string }, runs: { usage.Run }?)
	for _, b in links do
		if b.agent == c.checkAgent and hostSame(b.host, c.host) and b.started == c.checkStarted then
			if b.gate ~= "checking" or not b.chain then
				return
			elseif verdict == "pass" then
				b.gate = if b.chain.next then "next" else "over"
			elseif runs and usage.strikes(runs, b.key).checks >= M.LIMIT then
				stopChain(cx, links, b, M.LIMIT .. " failed checks")
			else
				b.gate, b.gateFindings = "fix", usage.text(table.concat(findings, "\n"), FIX_CAP)
			end
			return
		end
	end
end

-- Whether link `l`'s agent waits for input now (an ask it is showing).
local function waitsForInput(cx: WindowCx, l: Link): boolean
	local states, _, cwds = agentStates(cx)
	return states ~= nil and stateOf(l, states, cwds) == "waiting_input"
end

-- Where the run on link `l` (in `links`) goes at its agent's turn end, for an action with a next action or a checker,
-- decided once (again only while it waits for the user): another result than "done" ends the chain; a new commit
-- starts the check; a report that asks for the user waits for them; so does a checked action's turn that ends with no
-- report, or with its agent waiting for input (a Ship ask the report did not follow): nothing says it made no commit;
-- any other checked action's run without a new commit starts another round, until LIMIT such runs in a row; an action
-- with an outcome waits for its verdict; one with neither has nothing that could verify it, so its next action never
-- starts. `runs` (nil: unreadable) counts the limits.
local function gateRun(cx: WindowCx, links: { Link }, l: Link, result: string, report: usage.Report?, runs: { usage.Run }?)
	local c = l.chain
	if not c or l.checkAgent or not (c.next or c.checker) or not (l.gate == nil or l.gate == "held") then
		return
	end
	local label, item = actionLabel(c), itemLabel(c)
	if result ~= "done" then
		l.gate = "over"
		if c.next then
			cx:toast("info", "Next action not started after " .. label .. " for " .. item, if result == "failed" then "The agent reported a failure." elseif result == "exited" then "The agent's program exited." else "The agent's pane was closed.")
		end
		return
	end
	local s = usage.strikes(runs or {}, l.key)
	local commit = if report then report.commit else nil
	if c.checker and commit and s.idle == 0 then
		l.gate, l.checkedCommit = "check", commit
	elseif report and (report.attention == "stuck" or report.attention == "needs-human") then
		l.gate = "held"
	elseif c.checker and (not report or waitsForInput(cx, l)) then
		l.gate = "held"
	elseif c.checker then
		if s.idle >= M.LIMIT then
			return stopChain(cx, links, l, M.LIMIT .. " runs without progress")
		end
		local lines = { M.NO_COMMIT }
		for _, f in s.findings do
			table.insert(lines, f)
		end
		l.gate, l.gateFindings = "fix", usage.text(table.concat(lines, "\n"), FIX_CAP)
	elseif l.outcome then
		l.gate = "outcome"
	else
		l.gate = "over"
		return cx:toast("info", "Next action not started after " .. label .. " for " .. item, "Nothing verifies its run: give " .. label .. " an outcome or a checker in Settings › Actions.")
	end
	if STARTS[l.gate :: string] and not chainBlock(cx, l.host, c.pane) then
		cx:toast("info", (if l.gate == "check" then "Check" else "Fix round") .. " waits for Plotroom", "Open Plotroom on the agent's host; it starts then.")
	end
end

-- How long a step's start may take before it counts as failed: the action (30 s), then the worktree and the criteria
-- (5 minutes each), with room for a question the start asks on the way.
local START_S = 12 * 60

-- The chain steps due to start now: each link whose gate starts an agent and whose start is not in flight in this
-- plugin VM (a reload forgets those, so a start a reload cut off is due again; one that got as far as recording its
-- agent ended the gate, so nothing starts twice), with a Plotroom block on its host. A start in flight past START_S
-- counts as failed; LIMIT failed starts on the item stop the chain. Each returned step is marked in flight.
function M.dueSteps(cx: WindowCx): { Step }
	local due: { Step } = {}
	local links, healthy = readLinks()
	if not healthy then
		return due
	end
	local now = os.time()
	local runs: { usage.Run }? = nil
	local changed = false
	for _, l in links do
		local c = l.chain
		if c and l.gate and STARTS[l.gate] then
			local id = stepId(l.host, l.agent, l.started)
			local at: number? = starting[id]
			if at and now - at >= START_S then
				starting[id], at = nil, nil
				usage.addStart(l.key, l.started)
				runs = nil
			end
			local block = if at or now < (retryAt[id] or 0) then nil else chainBlock(cx, l.host, c.pane)
			if block then
				local read = runs or usage.readRuns() or {}
				runs = read
				if usage.strikes(read, l.key).starts >= M.LIMIT then
					stopChain(cx, links, l, M.LIMIT .. " failed starts")
					changed = true
				else
					starting[id] = now
					table.insert(due, { step = l.gate :: string, chain = table.clone(c), key = l.key, agent = l.agent, host = l.host, started = l.started, commit = l.checkedCommit, criteria = l.criteria, findings = l.gateFindings, block = block, depth = c.depth + (if l.gate ~= "check" and c.checker then 2 else 1) })
				end
			end
		end
	end
	if changed then
		writeLinks(links)
	end
	return due
end

-- A step's start failed (the action is gone, no worktree, the agent did not start, the request was not sent): it
-- counts on its run in the run log, and dueSteps tries again after RETRY_S.
function M.startFailed(s: Step)
	local id = stepId(s.host, s.agent, s.started)
	if starting[id] then
		starting[id], retryAt[id] = nil, os.time() + RETRY_S
		usage.addStart(s.key, s.started)
	end
end

-- Whether step `s` is still due on its run: one ended meanwhile (an action started by hand) starts no agent.
function M.stillDue(s: Step): boolean
	for _, l in (readLinks()) do
		if l.agent == s.agent and hostSame(l.host, s.host) and l.started == s.started then
			return l.gate == s.step
		end
	end
	return false
end

-- Ends step `s` without starting it (the chain is too long).
function M.endStep(s: Step)
	starting[stepId(s.host, s.agent, s.started)] = nil
	local links, healthy = readLinks()
	if not healthy then
		return
	end
	for _, l in links do
		if l.agent == s.agent and hostSame(l.host, s.host) and l.started == s.started then
			if l.gate == s.step then
				l.gate = "over"
				writeLinks(links)
			end
			return
		end
	end
end

-- The agent pane `agent`'s omp chat transcript, whole (the settle wait counts its prompts from the start); nil when it
-- cannot be read. ponytail: one full read per settle try (at most SETTLE_TRIES + 1 per turn end); read a window and align
-- it if long chats make that slow.
local REPORT_TOOL, REPORT_TITLE, REPORT_BYTES, ALL_MSGS = "plotroom_report", "Plotroom: report", 64 * 1024, 1000000
local function transcriptOf(cx: WindowCx, agent: number): { any }?
	local ok, msgs = pcall(function()
		return cx.agents:transcript(agent, { last = ALL_MSGS })
	end)
	return if ok and type(msgs) == "table" then msgs else nil
end

-- How many prompts (user messages) transcript `msgs` has.
local function promptsIn(msgs: { any }): number
	local n = 0
	for _, m in msgs do
		if type(m) == "table" and m.role == "user" then
			n += 1
		end
	end
	return n
end

-- Transcript `msgs` cut before the prompt that follows turn `turn` (the number of prompts up to and including that turn's;
-- 0: the chat's first turn, whose prompt was not in yet), and whether such a newer prompt was there.
local function upToTurn(msgs: { any }, turn: number): ({ any }, boolean)
	local out: { any } = {}
	local n = 0
	for _, m in msgs do
		if type(m) == "table" and m.role == "user" then
			if n >= math.max(turn, 1) or (turn == 0 and n == 0 and #out > 0) then
				return out, true
			end
			n += 1
		end
		table.insert(out, m)
	end
	return out, false
end

-- Whether transcript `msgs` shows its turn over: it ends with the agent's reply (text, and no tool call still running).
-- Tern can report a turn's end before omp's transcript has the turn's last tool calls and reply, or any message at all
-- (seen with Tern 0.9.13 and omp 18.18: up to a few seconds later), so recordResult waits for it. An empty transcript
-- is over unless `omp` (an agent started with Plotroom's omp extension): another agent has no omp chat to wait for.
local function settled(msgs: { any }, omp: boolean): boolean
	local m: any = msgs[#msgs]
	if m == nil then
		return not omp
	elseif type(m) ~= "table" or m.role ~= "assistant" or type(m.text) ~= "string" or not string.find(m.text, "%S") then
		return false
	end
	for _, t in (if type(m.tools) == "table" then m.tools else {}) :: { any } do
		if type(t) == "table" and t.status ~= "done" and t.status ~= "error" then
			return false
		end
	end
	return true
end

-- The end-of-run report of the turn transcript `msgs` ends with: the result of the turn's last plotroom_report call
-- (Plotroom's omp extension, plugin/omp/plotroom.ts) that the tool accepted, read back to the turn's prompt, decoded
-- (usage.reportOf checks it); nil when there is none or it cannot be read. omp names a tool the agent reaches through an
-- xd:// device by the device's verb ("write") and keeps the tool's label as `title`, so the call is known by either. A
-- refused call (status "error") is skipped: the corrected one counts. The extension's result text is the report's JSON
-- on its first line.
local function turnReport(msgs: { any }?): any
	for i = #(msgs or {}), 1, -1 do
		local m: any = (msgs :: { any })[i]
		if type(m) ~= "table" or m.role ~= "assistant" then
			return nil
		end
		local tools: any = if type(m.tools) == "table" then m.tools else {}
		for j = #tools, 1, -1 do
			local t: any = tools[j]
			if type(t) == "table" and (t.name == REPORT_TOOL or t.title == REPORT_TITLE) and t.status == "done" then
				if type(t.text) ~= "string" or #t.text > REPORT_BYTES then
					return nil
				end
				local decoded, r = pcall(tern.json.decode, string.match(t.text, "^[^\n]*") :: string)
				return if decoded then r else nil
			end
		end
	end
	return nil
end

-- How long an outcome check may take the block's host (one gh token read and one GraphQL read, 30 s each at most), and
-- how often an Unchecked run, or a Merged one whose agent still runs, is checked again: the default refresh pace
-- (host/core POLL_MS).
local OUTCOME_MS = 90 * 1000
local RECHECK_S = 60
local checking: { [string]: number } = {} -- "<host>|<agent>|<started>" -> when its check was asked, while in flight

-- The lowest Plotroom block on `host`, the one outcome checks ask; nil when none is open there.
local function blockOn(cx: WindowCx, host: HostId): number?
	for _, p in plotroomPanes(cx) do
		local ph = hostOf(cx, p)
		if ph and hostSame(ph, host) then
			return p
		end
	end
	return nil
end

-- Asks a Plotroom block on link `l`'s host to check its outcome on GitHub as the run's login (host/requests' `outcome`
-- op), then records the verdict on the link (read again, so a newer write is kept) and on its run in the run log, and
-- tells the blocks. A run whose chain waits for this verdict moves: Verified makes its next action due, Not verified
-- ends the chain with a toast (the run is Needs you); Unchecked waits for the next check. Asked quietly: no toasts, as
-- a background check. Nothing without a block on that host, a check of the same run in flight, or a host too old to
-- check: a later tick asks again.
local function checkOutcome(cx: WindowCx, l: Link)
	local id = l.host.id .. "|" .. l.host.address .. "|" .. l.agent .. "|" .. (l.started or 0)
	local block = blockOn(cx, l.host)
	if not l.outcome or not block or (checking[id] and os.time() - checking[id] < OUTCOME_MS // 1000 * 2) then
		return
	end
	checking[id] = os.time()
	local args = { outcome = l.outcome, repo = l.ghRepo, number = l.number, branch = l.branch, commit = l.commit, since = l.started or 0, login = l.login }
	local sent = e().ask(cx, block, "outcome", args, OUTCOME_MS, function(a: any, cx2: WindowCx)
		checking[id] = nil
		local verdict = if type(a.verdict) == "string" and usage.VERDICTS[a.verdict] then a.verdict else "unchecked"
		local links, healthy = readLinks()
		if not healthy then
			return
		end
		for _, x in links do
			if x.agent == l.agent and hostSame(x.host, l.host) and x.started == l.started then
				x.verdict, x.checked = verdict, os.time()
				if x.gate == "outcome" and x.chain then
					if verdict == "verified" then
						x.gate = "next"
					elseif verdict == "not" then
						x.gate = "over"
						cx2:toast("info", "Next action not started after " .. actionLabel(x.chain) .. " for " .. itemLabel(x.chain), "Not verified: GitHub does not show " .. (prompts.outcomeLabel(x.outcome) or "its outcome") .. ".")
					end
				end
				if writeLinks(links) then
					usage.setVerdict(x.key, x.started, verdict)
					M.agentSync(cx2)
					e().drive(cx2)
				end
				return
			end
		end
	end, true)
	if not sent then
		checking[id] = nil
	end
end

-- How often the checked runs still undecided (usage.agreement) are asked whether their work merged, and which are in
-- flight ("<key>|<started>").
local MERGE_SWEEP_S = 10 * 60
local sweptAt = 0
local merging: { [string]: boolean } = {}

-- Asks the lowest Plotroom block, as each run's login, whether the work of every undecided checked run merged (the
-- `outcome` op with Merged), and marks those that did. Quiet, like checkOutcome. A run that names no login, repository,
-- pull request or branch waits out its AGREE_AFTER_S. ponytail: one block asks for every host's runs; a login that only
-- another host holds stays undecided until the time rule, so keep the host on the run if that shows up.
local function checkMerges(cx: WindowCx, now: number)
	local block = plotroomPanes(cx)[1]
	local runs = if block then usage.readRuns() else nil
	for _, r in runs or {} :: { usage.Run } do
		local id = r.key .. "|" .. (r.started or 0)
		if r.checkedAt and not usage.agreement(r, now) and r.login and r.ghRepo and (r.number or r.branch) and not merging[id] then
			merging[id] = true
			local key, started = r.key, r.started
			local args = { outcome = "merged", repo = r.ghRepo, number = r.number, branch = r.branch, since = 0, login = r.login }
			local sent = e().ask(cx, block :: number, "outcome", args, OUTCOME_MS, function(a: any, _cx2: WindowCx)
				merging[id] = nil
				if a.verdict == "verified" then
					usage.setMerged(key, started)
				end
			end, true)
			if not sent then
				merging[id] = nil
			end
		end
	end
end

-- Checks again what is due: each item's newest link (per host) whose run has ended and whose outcome was never checked
-- (no block, or an older host, at its turn end), is Unchecked, or is Merged and Not verified while its agent has not
-- exited, once per RECHECK_S; and the merges of undecided checked runs once per MERGE_SWEEP_S.
function M.recheck(cx: WindowCx)
	local now = os.time()
	if now - sweptAt >= MERGE_SWEEP_S then
		sweptAt = now
		checkMerges(cx, now)
	end
	local links, healthy = readLinks()
	if not healthy or #links == 0 then
		return
	end
	local states, _, cwds = agentStates(cx)
	local seen: { [string]: boolean } = {}
	for _, l in links do
		local k = l.host.id .. "|" .. l.host.address .. "|" .. l.key
		if not seen[k] then
			seen[k] = true
			local live = states ~= nil and (stateOf(l, states, cwds) or "exited") ~= "exited"
			local due = l.verdict == nil or l.verdict == "unchecked" or (l.outcome == "merged" and l.verdict == "not" and live)
			if l.outcome and l.result and due and now - (l.checked or 0) >= RECHECK_S then
				checkOutcome(cx, l)
			end
		end
	end
end

-- Saves how the agent pane `agent`'s turn ended (done, failed, exited, closed), when (HH:MM) and the end-of-run report
-- of that turn (turnReport, usage.reportOf) on its link, for the Agents list. The first turn end of a link appends its run,
-- with that report, to the run log (kv `runs`): a run ends with its agent's first turn, so later turns of the same
-- agent add no record. A turn with no valid report records "none" on the first turn and keeps the shown report on a
-- later one (a prompt typed into the agent carries no contract). Every turn end of a link whose action names an
-- outcome checks it (checkOutcome), with the commit the newest report named. Nothing for an agent with no link or a
-- store that cannot be read.
-- A checker's run (its link names the run it checks) records its verdict, on its first turn end or a later one whose
-- report gives one: the report's `check`, else fail (missing data never passes), with its findings, on its link and
-- on the checked run in the run log, and settles that run's chain (settleCheck). Any other run's chain is decided by
-- gateRun. The caller starts what became due (window's drive).
-- While the agent's transcript does not show its turn over yet (settled) and the agent is still there (the turn ended
-- done or failed), this waits: it runs again SETTLE_MS later, at most SETTLE_TRIES times, then records what the
-- transcript shows, and starts what became due itself. The wait keeps the host and link found at the turn end and the
-- newest transcript read: when the pane closes during it (no host lists it, or its transcript cannot be read), the turn
-- is recorded with that read at the next retry, and a turn end of the same pane that arrives during it (closed, exited)
-- records the waited turn first. The waited turn is the one the first read ends in (counted by its prompts): every
-- later read is cut before the next prompt, and a next prompt (a message sent to the agent meanwhile) ends the wait.
-- For an agent with Plotroom's extension (`run`), a read with no more prompts than its recorded turns covered (`turns`)
-- does not show the ended turn yet: it waits too, and on giving up records that turn with no report.
local SETTLE_MS, SETTLE_TRIES = 1000, 10
type Wait = { host: HostId, result: string, msgs: { any }?, tries: number, turn: number? }
local waits: { [number]: Wait } = {} -- agent pane -> its turn end waiting for the transcript

local function recordTurn(cx: WindowCx, links: { Link }, l: Link, result: string, msgs: { any }?)
	local first = l.result == nil
	local report = usage.reportOf(turnReport(msgs))
	l.result, l.ended = clip(result, RESULT_CAP), os.date("%H:%M")
	if report then
		l.attention, l.reason, l.blocker = report.attention, clip(report.reason, LAST_CAP), clip(report.blocker, LAST_CAP)
		l.commit = report.commit or l.commit
	elseif first then
		l.attention, l.reason, l.blocker = "none", nil, nil
	end
	local verdict: string? = nil
	local findings: { string } = {}
	if l.checkAgent and (first or (report and report.check)) then
		verdict = if report and report.check then report.check else "fail"
		findings = if report then report.findings else {}
		if verdict == "fail" and #findings == 0 then
			findings = { if not report then "The checker ended without a report." elseif not report.check then "The checker gave no pass or fail." else "The checker gave no findings." }
		end
		l.check, l.findings = verdict, clip(table.concat(findings, " · "), FINDINGS_CAP)
	end
	if first then
		usage.appendRun({
			key = l.key,
			action = if l.chain and l.chain.name ~= "" then l.chain.name else l.action or "",
			kind = l.kind,
			model = l.model,
			runsIn = l.runsIn,
			started = l.started,
			ended = os.time(),
			result = result,
			attention = if report then report.attention else "none",
			reason = if report then report.reason else nil,
			commit = if report then report.commit else nil,
			pr = if report then report.pr else nil,
			evidence = if report then report.evidence else nil,
			blocker = if report then report.blocker else nil,
			outcome = l.outcome,
			criteria = l.criteria,
			check = verdict,
			findings = if verdict then findings else nil,
			login = l.login,
			ghRepo = l.ghRepo,
			number = l.number,
			branch = l.branch,
			depth = if l.chain then l.chain.depth else nil,
			checking = if l.checkAgent then true else nil,
		})
		medians = nil -- the next working agent expects the log's new median
	elseif report and report.commit then
		usage.setCommit(l.key, l.started, report.commit)
	end
	if verdict then
		usage.setCheck(l.key, l.checkStarted, verdict, findings)
	end
	local runs = usage.readRuns()
	if verdict then
		settleCheck(cx, links, l, verdict, findings, runs)
	else
		gateRun(cx, links, l, result, report, runs)
	end
	if writeLinks(links) then
		checkOutcome(cx, l)
	end
end

-- Records (or keeps waiting on) the turn end `wt` of the agent pane `agent`; `final`: record now with the newest read.
local function settle(cx: WindowCx, agent: number, wt: Wait, final: boolean)
	local links, healthy = readLinks()
	if not healthy then
		return
	end
	for _, l in links do
		if l.agent == agent and hostSame(l.host, wt.host) then
			local gone = wt.tries > 0 and not hostOf(cx, agent)
			local read = if gone then nil else transcriptOf(cx, agent)
			local msgs, newer = nil, false
			if read then
				local n = promptsIn(read)
				if wt.turn == nil and not (l.run and (l.turns or 0) > 0 and n <= (l.turns :: number)) then
					wt.turn = n
				end
				if wt.turn then
					msgs, newer = upToTurn(read, wt.turn :: number)
				end
			end
			local live = wt.result == "done" or wt.result == "failed"
			local waiting = if msgs then not newer and not settled(msgs, l.run ~= nil) else read ~= nil
			if not final and waiting and live and wt.tries < SETTLE_TRIES then
				wt.msgs, wt.tries = msgs, wt.tries + 1
				waits[agent] = wt
				tern.timer(SETTLE_MS, function(cx2: WindowCx?)
					if cx2 and waits[agent] == wt then
						waits[agent] = nil
						settle(cx2, agent, wt, false)
						M.agentSync(cx2)
						e().drive(cx2)
					end
				end)
				return
			end
			l.turns = wt.turn or l.turns
			recordTurn(cx, links, l, wt.result, msgs or wt.msgs)
			return
		end
	end
end

function M.recordResult(cx: WindowCx, agent: number, result: string)
	local pending = waits[agent]
	if pending then
		waits[agent] = nil
		settle(cx, agent, pending, true)
	end
	local host = hostOf(cx, agent)
	if host then
		settle(cx, agent, { host = host, result = result, tries = 0 }, false)
	end
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
	local hosts = hostsOf(cx)
	local local_ = false
	if hosts then
		for _, h in hosts do
			if type(h.panes) == "table" and table.find(h.panes, pane) then
				local_ = h.kind == "local"
			end
		end
	end
	if not local_ then
		return cx:toast("error", "Open Git view works on this machine's worktrees only", "This block runs on another host.")
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

-- Interrupt, Stop, Message or Reply (`act`: agentint | agentstop | agentmsg | agentreply) the live agent recorded for
-- `key`. Stop asks first; each step looks the agent up again, so one that exited meanwhile only toasts. Reply is Now's
-- Message agent… for an agent that needs input: one that stopped waiting gets the same toast and nothing is sent.
-- agentdisagree is Disagree with check… (M.disagree), which needs no live agent.
function M.agentCommand(cx: WindowCx, pane: number, key: string, act: string)
	if act == "agentdisagree" then
		return M.disagree(cx, pane, key)
	end
	local waiting = act == "agentreply"
	local function reachable(cx2: WindowCx): Link?
		local link, state = M.liveAgent(cx2, pane, key)
		return if link and (not waiting or state == "waiting_input") then link else nil
	end
	local function run(cx2: WindowCx, what: string, fn: (number) -> ...any)
		local link = reachable(cx2)
		if not link then
			return cx2:toast("info", "No agent is running for " .. key)
		end
		local ok, err = pcall(fn, link.agent)
		if not ok then
			cx2:toast("error", "Could not " .. what .. " the agent for " .. key, tostring(err))
		end
	end
	if not reachable(cx) then
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
	elseif act == "agentmsg" or waiting then
		cx:prompt({ placeholder = (if waiting then "Reply to the agent of " else "Message for the agent of ") .. key, icon = "merge", action = "send" }):next(function(text, _, cx2)
			local line = if text then trim(text) else ""
			if cx2 and line ~= "" then
				run(cx2, "message", function(agent)
					cx2.agents:ask(agent, line)
				end)
			elseif cx2 and text then
				cx2:toast("info", "Nothing to send: the message was blank")
			end
		end)
	end
end

-- Disagree with check…: the newest link of `key` on `pane`'s host must be a checker with a verdict (exited or not);
-- asks for an optional one-line reason, then records the disagreement on the run that checker checked (usage.setDisagree).
-- Escape records nothing.
function M.disagree(cx: WindowCx, pane: number, key: string)
	local host = hostOf(cx, pane)
	local checker: Link? = nil
	for _, l in (readLinks()) do
		if host and l.key == key and hostSame(l.host, host) then
			checker = if l.checkAgent and l.check then l else nil
			break
		end
	end
	if not checker then
		return cx:toast("info", "No check to disagree with for " .. key)
	end
	local c = checker :: Link
	cx:prompt({ placeholder = "Why the check of " .. key .. " is wrong (optional)", icon = "merge", action = "record" }):next(function(text, _, cx2)
		if not cx2 or text == nil then
			return
		elseif usage.setDisagree(key, c.checkStarted, trim(text)) then
			cx2:toast("success", "Disagreement recorded for " .. key, "The usage report counts it against the checker.")
		else
			cx2:toast("error", "Disagreement not recorded for " .. key, "The checked run is not in the run log, or the log cannot be read.")
		end
	end)
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

-- ---------------------------------------------------------------- Draft review

local REVIEW_BLOCK = "plotroom.review"

-- Whether `pane` runs the Draft review block.
local function isReview(cx: WindowCx, pane: number): boolean
	local info = cx.session:pane(pane)
	local block = if info then info.block else nil
	return type(block) == "string" and string.sub(block, -#REVIEW_BLOCK) == REVIEW_BLOCK
end

-- The Draft review block open for run `run` (its hidden `main.run`), if any.
local function reviewPane(cx: WindowCx, run: string): number?
	for _, p in cx.session:panes() do
		if isReview(cx, p.pane) and e().nodeProp(e().readNode(cx, p.pane, "main.run"), "text") == run then
			return p.pane
		end
	end
	return nil
end

-- A turn of `agent` ended: when its run (Link.run) has a Draft review file newer than the last one opened (`reviewed`),
-- the Draft review block opens beside the agent, or the one open for that run reloads. The file is on the agent's
-- host, so a Plotroom block there is asked (rpc `review`); with none open there, or an older host, nothing opens.
function M.reviewAfter(cx: WindowCx, agent: number)
	local host = hostOf(cx, agent)
	local link: Link? = nil
	for _, l in (readLinks()) do
		if host and l.agent == agent and hostSame(l.host, host) then
			link = l
			break
		end
	end
	local run = if link then link.run else nil
	local block = if host and run then blockOn(cx, host) else nil
	if not host or not run or not block then
		return
	end
	e().ask(cx, block, "review", { run = run }, ACT_MS, function(a: any, cx2: WindowCx)
		local at = if type(a.at) == "string" and #a.at <= ACTION_CAP then a.at else nil
		local links, healthy = readLinks()
		if not at or not healthy then
			return
		end
		for _, l in links do
			if l.agent == agent and hostSame(l.host, host) and l.run == run then
				if l.reviewed and l.reviewed >= at then
					return
				end
				l.reviewed = at
				writeLinks(links)
				local open = reviewPane(cx2, run)
				if open then
					pcall(function()
						cx2.session:event(open, { ev = "action", act = "reload" })
					end)
					return
				end
				local ok, pane = pcall(function()
					return cx2:new_block(REVIEW_BLOCK, { run, l.cwd or "", l.login or "" }, "split", { target = agent, dir = "right" })
				end)
				if not ok or not pane then
					cx2:toast("error", "The Draft review for " .. l.key .. " did not open", if ok then "Tern opened no block." else tostring(pane))
				end
				return
			end
		end
	end, true)
end

-- Review/send's message `o`, read off the block in `pane`, goes to its run's agent; `answer` tells the block.
local function deliver(cx: WindowCx, pane: number, o: { run: string, text: string }, answer: (string, string?) -> ())
	local host = hostOf(cx, pane)
	local link: Link? = nil
	for _, l in (readLinks()) do
		if host and l.run == o.run and hostSame(l.host, host) then
			link = l
			break
		end
	end
	local states, _, cwds = agentStates(cx)
	local s = if link and states then stateOf(link, states, cwds) else nil
	if not link or s == nil or s == "exited" then
		return answer("gone", "The agent that proposed this review is gone.")
	end
	local agent = link.agent
	local sent, err = pcall(function()
		cx.agents:ask(agent, o.text)
	end)
	if not sent then
		-- Tern's error, without the Luau prefix and traceback: "agent already has a pending prompt".
		local why = string.gsub(string.match(tostring(err), "^[^\n]*") or "", "^runtime error: ", "")
		why = string.gsub(why, "%s*stack traceback:.*$", "")
		return answer("gone", "The agent could not take the message: " .. why .. ".")
	end
	answer("sent")
	cx:toast("success", "Sent your Draft review to the agent of " .. link.key)
end

-- How long, and how often, review/send looks for the block's message: on a remote host its link can arrive before the
-- render that shows the message.
local SEND_READ_MS, SEND_READ_STEP_MS = 3000, 250
local reading: { [number]: number } = {} -- pane -> its latest review/send link; an older one's wait stops

-- plotroom://review/send from Draft review block `pane`: its message (hidden `main.send`) goes to the agent of its run by
-- `agents:ask`, and the block is told `sent`, or `gone` with why (it then offers Copy). A message not shown yet is
-- looked for again for up to SEND_READ_MS; a later link from the pane takes over the wait, so one Send sends once.
function M.reviewSend(cx: WindowCx, pane: number)
	if not isReview(cx, pane) then
		return cx:toast("error", "Plotroom: link did not come from a Draft review block")
	end
	local token = (reading[pane] or 0) + 1
	reading[pane] = token
	local waited = 0
	local function try(cx2: WindowCx)
		if reading[pane] ~= token then
			return
		end
		local function answer(act: string, why: string?)
			pcall(function()
				cx2.session:event(pane, { ev = "action", act = act, value = why })
			end)
		end
		local ok, o = pcall(tern.json.decode, tostring(e().nodeProp(e().readNode(cx2, pane, "main.send"), "text")))
		if not ok or type(o) ~= "table" or type(o.run) ~= "string" or type(o.text) ~= "string" or o.text == "" then
			if waited < SEND_READ_MS then
				waited += SEND_READ_STEP_MS
				tern.timer(SEND_READ_STEP_MS, function(cx3: WindowCx?)
					if cx3 then
						try(cx3)
					end
				end)
				return
			end
			return answer("gone", "The message could not be read.")
		end
		deliver(cx2, pane, o, answer)
	end
	try(cx)
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
	local hosts = hostsOf(cx)
	if hosts then
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
	cx:pick({ items = items, placeholder = placeholder, icon = "merge", action = "send" }):next(function(item, _, cx2)
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

-- ---------------------------------------------------------------- item actions

local function assignMe(cx: WindowCx, pane: number)
	planAct(cx, pane, "Not assigned", { name = "assign-me" })
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

-- Ignore this check…: the host answers the failing checks not yet ignored to pick from (several) or a plan.
local function ignoreCheck(cx: WindowCx, pane: number)
	local title = "Check not ignored"
	e().ask(cx, pane, "act", { name = "ignore-check" }, ACT_MS, function(a: any, cx2: WindowCx)
		local why = problemOf(a)
		if why then
			return cx2:toast("error", title, why)
		elseif type(a.checks) ~= "table" then
			return M.confirmPlan(cx2, pane, a, nil)
		end
		local items: { PickItem } = {}
		for _, name in a.checks do
			if type(name) == "string" then
				table.insert(items, { label = name, check = name })
			end
		end
		if #items == 0 then
			return cx2:toast("info", "No failing check to ignore")
		end
		cx2:pick({ items = items, placeholder = "Which failing check to ignore in this repository?", icon = "merge", action = "plan" }):next(function(item, _, cx3)
			if item and cx3 then
				planAct(cx3, pane, title, { name = "ignore-check", check = item.check })
			end
		end)
	end)
end

-- Now's notifications marked read: the host names the listed threads and the account in the confirm.
local function markRead(cx: WindowCx, pane: number)
	planAct(cx, pane, "Not marked read", { name = "mark-read" })
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

local function prEmptyCommit(cx: WindowCx, pane: number)
	planAct(cx, pane, "No empty commit pushed", { name = "pr-empty-commit" })
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
	cx:pick({ items = items, placeholder = "Draft PR: " .. title, icon = "merge", action = "create or edit" }):next(function(item, _, cx2)
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
		cx2:pick({ items = dests, placeholder = "Where should the draft PR from " .. branch .. " go?", icon = "merge", action = "open" }):next(function(dest, _, cx3)
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

-- Palette commands the window registers (id, title) and its command palette lists (label, under `group`) when the host
-- says they apply to the selection now (`menu`'s `commands`) unless `keyed`: the palette lists those as the queue action
-- they are (or, as Worktrees list, as the Views scope). An item's own operation has no `group`: the host names it by the
-- item's type (GitHub - PR, GitHub - Issue, Jira - Issue). All but `anywhere` ones need a focused Plotroom block, which
-- the window checks.
export type Command = { id: string, title: string, label: string, group: string?, run: (WindowCx, number) -> (), anywhere: boolean?, keyed: boolean? }

local usageReport: (WindowCx, number) -> () -- below: it names the commands of this list

M.COMMANDS = {
	{ id = "open-url", title = "Plotroom: Open item by URL", label = "Open item by URL…", group = "Views", run = M.openByUrl, anywhere = true },
	{ id = "get-started", title = "Plotroom: Get started", label = "Get started", group = "Configuration", run = send("get-started", nil) },
	{
		id = "agent-message-selection",
		title = "Plotroom: Message an agent with the selection…",
		label = "Message an agent with the selection…",
		group = "Actions",
		run = function(cx: WindowCx, _pane: number)
			M.messageSelection(cx)
		end,
		anywhere = true,
	},
	{ id = "mark-read", title = "Plotroom: Mark all of Now's notifications read", label = "Mark all notifications read…", group = "Now", run = markRead },
	{
		id = "agent-go",
		title = "Plotroom: Go to the selected item's agent",
		label = "Go to agent",
		group = "Actions",
		keyed = true,
		run = function(cx: WindowCx, pane: number)
			e().follow(cx, pane, AGENTGO_NODE, "The selected item has no agent")
		end,
	},
	{ id = "assign-me", title = "Plotroom: Assign the selected issue to me", label = "Assign to me", run = assignMe },
	{ id = "comment", title = "Plotroom: Comment on the selected item", label = "Comment…", run = comment },
	{ id = "issue-close", title = "Plotroom: Close the selected GitHub issue", label = "Close issue…", run = issueClose },
	{ id = "issue-reopen", title = "Plotroom: Reopen the selected GitHub issue", label = "Reopen issue…", run = issueReopen },
	{ id = "pr-ready", title = "Plotroom: Mark the selected draft PR ready for review", label = "Ready for review…", run = prReady },
	{ id = "pr-draft", title = "Plotroom: Convert the selected PR to a draft", label = "Convert to draft…", run = prDraft },
	{ id = "pr-merge", title = "Plotroom: Merge the selected PR", label = "Merge…", run = prMerge },
	{ id = "pr-approve", title = "Plotroom: Approve the selected PR", label = "Approve…", run = prApprove },
	{ id = "pr-request-changes", title = "Plotroom: Request changes on the selected PR", label = "Request changes…", run = prRequestChanges },
	{ id = "pr-update-branch", title = "Plotroom: Update the selected PR's branch from its base", label = "Update branch…", run = prUpdateBranch },
	{ id = "pr-empty-commit", title = "Plotroom: Push an empty commit to the selected PR's branch so its checks run again", label = "Push empty commit…", run = prEmptyCommit },
	{ id = "rerun-failed", title = "Plotroom: Re-run the selected PR's failed checks", label = "Re-run failed checks", run = rerunFailed },
	{ id = "ignore-check", title = "Plotroom: Ignore a failing check of the selected PR", label = "Ignore this check…", run = ignoreCheck },
	{ id = "draft-pr", title = "Plotroom: Open a draft PR from the selected item's worktree", label = "Draft PR…", run = draftPr },
	{
		id = "usage-report",
		title = "Plotroom: Copy usage report",
		label = "Copy usage report",
		group = "Configuration",
		run = function(cx: WindowCx, pane: number)
			usageReport(cx, pane)
		end,
	},
	{ id = "mark-seen", title = "Plotroom: Mark the selected item seen", label = "Mark seen", group = "Triage", run = send("triage", "seen"), keyed = true },
	{ id = "snooze", title = "Plotroom: Snooze the selected item until tomorrow", label = "Snooze until tomorrow", group = "Triage", run = send("triage", "snooze"), keyed = true },
	{ id = "toggle-snoozed", title = "Plotroom: Show or hide snoozed items", label = "Show or hide snoozed", group = "Filter & Sort", run = send("triage", "toggle-snoozed"), keyed = true },
	{ id = "sort", title = "Plotroom: Next sort order", label = "Next sort order", group = "Filter & Sort", run = send("sort", "next"), keyed = true },
	{ id = "worktrees-open", title = "Plotroom: Open Worktrees", label = "Worktrees", group = "Views", run = send("open-worktrees", nil), keyed = true },
} :: { Command }

-- ---------------------------------------------------------------- usage report

-- What usage id `id` is called in the report: a queue action's label, a command's title, a saved action's name.
local function usageName(id: string): string
	local where, what = string.match(id, "^(%a+):(.+)$")
	if where == "queue" then
		for _, a in keys.ACTIONS do
			if a.id == what then
				return a.label
			end
		end
	elseif where == "row" or where == "palette" then
		for _, c in M.COMMANDS do
			if c.id == what then
				return if where == "row" then c.label else c.title
			end
		end
		local title = e().titles[what :: string]
		if title then
			return title
		end
	end
	return what or id
end

-- Copy usage report: this machine's counts and run log, and the block's host's queue action counts (its hidden
-- `main.usage` node), as plain text on the clipboard. Nothing leaves the machine.
function usageReport(cx: WindowCx, pane: number)
	local hostPart: usage.Part<usage.Usage> = { problem = "could not be read" }
	local text = e().nodeProp(e().readNode(cx, pane, "main.usage"), "text")
	local ok, a = pcall(tern.json.decode, if type(text) == "string" then text else "")
	if ok and type(a) == "table" and type(a.problem) == "string" then
		hostPart = { problem = usage.line(a.problem, 80) or "could not be read" }
	elseif ok and type(a) == "table" and type(a.usage) == "table" then
		local u = usage.parseUsage(a.usage)
		hostPart = if u then { value = u } else { problem = "is malformed" }
	end
	local here, hereWhy = usage.readUsage()
	local runs, runsWhy = usage.readRuns()
	local report = usage.report({ host = hostPart, here = { value = here, problem = hereWhy }, runs = { value = runs, problem = runsWhy }, name = usageName, outcome = prompts.outcomeLabel })
	cx:copy(report)
	local missing = (if hostPart.problem then 1 else 0) + (if hereWhy then 1 else 0) + (if runsWhy then 1 else 0)
	if missing > 0 then
		cx:toast("info", "Usage report copied, with parts missing", "The report says which.")
	else
		cx:toast("success", "Usage report copied to the clipboard")
	end
end

return M
