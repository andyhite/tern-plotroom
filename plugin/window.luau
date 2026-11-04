--!strict
-- The window half: opening Plotroom, validated PR links (Browser block, worktree tab, the PR's open tab, an agent
-- running a saved or typed prompt) and their keyboard-accessible palette commands.
-- This half runs on the machine showing the window; the block may run on a remote host. Whatever touches the checkout
-- or the saved prompts (git, gh, omp, kv) is asked of the block's host half (host/requests.luau);
-- this half only asks the user and arranges tabs.

local worktree = require("./worktree")
local flows = require("./flows")
local rpc = require("./rpc")
local usage = require("./usage")
local prompts = require("./prompts")

-- Every palette command's title by id, for the usage report (flows.setup).
local TITLES: { [string]: string } = {}

-- tern.command, counting each run in this machine's usage as "palette:<id>".
local function command(def: CommandDef)
	TITLES[def.id] = def.title
	local run = def.run
	tern.command({
		id = def.id,
		title = def.title,
		icon = def.icon,
		available = def.available,
		run = function(cx: WindowCx)
			usage.bump("palette:" .. def.id)
			run(cx)
		end,
	})
end

local PRS_BLOCK = "plotroom.prs"
local ISSUE_ICON = "list-checks"
local SCHEME = "plotroom://"
local OPEN_NODE = flows.OPEN_NODE
local WORKTREE_NODE = "layer.queue.buttons.worktree"
local LINKED_NODE = "layer.queue.linked" -- the issue sidebar's linked pull requests; ".pr<i>" follows
local HEADPR_NODE = "layer.queue.headpr" -- the issue preview's head pull request row
local NOTED_NODE = "layer.queue.noted" -- the PR preview's noted issue row
-- The lists a check row can sit in (required, the others); ".run<i>" follows.
local CHECK_LISTS = { "layer.queue.required", "layer.queue.runs" }
local GOTO_NODE = "layer.queue.buttons.goto"
local AGENT_NODE = "layer.queue.buttons.agent" -- hidden: the `a` key's and palette command's link
local AGENTGO_NODE = flows.AGENTGO_NODE
local BUTTONS_PREFIX = "layer.queue.buttons." -- .. agentint | agentstop | agentmsg | agentreply | agentdisagree: the hidden links of the agent commands
local AGENT_CMD = { agentint = true, agentstop = true, agentmsg = true, agentreply = true, agentdisagree = true } -- Interrupt, Stop, Message, Reply (Now), Disagree with check
local MORE_NODE = "main.more" -- hidden: the command palette
local WTOPEN_PREFIX = "plotroom://worktrees/open/"
local PROMPT_NODE = "layer.queue.buttons.prompt-" -- .. a saved prompt's id: the hidden link its shortcut opens
-- How long the block's host may take to answer: listing saved prompts, preparing a worktree (fetch and add, 2 minutes
-- each).
local MENU_MS = 30 * 1000
-- How often a waiting request looks for its answer on screen, in case the host's link to it never arrives.
local POLL_MS = 500
local PREPARE_MS = 5 * 60 * 1000
-- Listing a gh login's repositories: a token read, then the REST API's pages (30 seconds each at most).
local REPOS_MS = 70 * 1000
-- A clone for a checkout asked in the palette may run this long (longer than github.luau's CLONE_MS).
local CLONE_WAIT_MS = 11 * 60 * 1000
local RECENT_CAP = 5

local strOf = flows.strOf

-- The valid link actions of an item (a PR link also takes open and show).
local VALID_ACTS = { worktree = true, goto = true, agent = true, agentgo = true, agentint = true, agentstop = true, agentmsg = true, agentreply = true, agentdisagree = true, run = true }

-- The hidden node whose href a link of action `act` must match (`id`: a saved prompt's id for `run`).
local function nodeOf(act: string, id: string?): string
	return if act == "open" then OPEN_NODE
		elseif act == "goto" then GOTO_NODE
		elseif act == "agent" then AGENT_NODE
		elseif act == "agentgo" then AGENTGO_NODE
		elseif AGENT_CMD[act] then BUTTONS_PREFIX .. act
		elseif act == "run" then PROMPT_NODE .. (id or "")
		else WORKTREE_NODE
end

-- A worktree the host prepared, as its answer says.
type Ready = { path: string, created: boolean, current: boolean, dirty: boolean?, summary: string, setup: string?, title: string? }
-- What a link acts on: a PR (ref = its number) or an issue (ref = its tracker key). `tab` names its worktree's tab.
type Target = { kind: "pr" | "issue", repo: string, ref: string, label: string, tab: string }
-- A prompt to run: its text, the model omp runs it with (`omp --model`; nil: the agent command's default), and
-- whether its agent opens beside the queue in the queue's tab (`split`) rather than in a tab of its own. A saved action
-- also has its `id` and `name`, and `next`, the saved action to start when its agent finishes; `depth` counts the actions
-- chained before it and `tab` is the tab the previous one ran in, which the next one joins. `outcome` (a saved action's
-- prompts.OUTCOMES id; nil: none) is what its run must leave behind, checked when the agent's turn ends. `checker` (nil:
-- none) is the saved action a fresh agent runs when a run of this one ends with a commit. `criteria` is the acceptance
-- criteria snapshot to fill `{criteria}` with ("": none saved; nil: read from the issue now, at dispatch). A check job
-- has `check`, the run it checks: its agent, start, the commit its report named and its action's name. A fix round
-- has `findings`, what to fix, for `{findings}`. A chain step's job has `from`, the step it starts, and `fail`, called
-- when its start fails on the way.
type Job = { text: string, model: string?, split: boolean?, status: string?, id: string?, name: string?, next: string?, depth: number?, tab: number?, outcome: string?, checker: string?, criteria: string?, check: { agent: number, started: number?, commit: string, action: string }?, findings: string?, from: flows.Step?, fail: ((WindowCx) -> ())? }

local function prTarget(owner: string, name: string, n: number): Target
	local repo = owner .. "/" .. name
	return { kind = "pr", repo = repo, ref = tostring(n), label = repo .. "#" .. n, tab = "PR #" .. n .. " · " .. name }
end

local function issueTarget(repo: string, ref: string): Target
	local name = string.match(repo, "/([^/]+)$")
	if name then
		return { kind = "issue", repo = repo, ref = ref, label = repo .. "#" .. ref, tab = "#" .. ref .. " · " .. name }
	end
	return { kind = "issue", repo = repo, ref = ref, label = ref, tab = ref }
end
-- Requests to a block's host waiting for their answer, by id.
type Pending = { pane: number, done: (any, WindowCx) -> (), timer: TimerHandle }
local pending: { [string]: Pending } = {}
local requests = 0
-- Picker labels chosen last, newest first. Kept in tern.kv: Tern reboots plugin VMs now and then, losing module state.
local RECENT_KEY = "agent-recent"

-- nil when the stored list cannot be read: it is then never written over.
local function readRecent(): { string }?
	local out: { string } = {}
	local ok, v = pcall(tern.kv.get, RECENT_KEY)
	if not ok or (v ~= nil and type(v) ~= "table") then
		return nil
	elseif type(v) == "table" then
		for _, label in v do
			if type(label) == "string" then
				table.insert(out, label)
			end
		end
	end
	return out
end

-- Whether `pane` runs the Plotroom block.
local function isPlotroom(cx: WindowCx, pane: number): boolean
	local info = cx.session:pane(pane)
	local block = if info then info.block else nil
	return type(block) == "string" and string.sub(block, -#PRS_BLOCK) == PRS_BLOCK
end

local function findNode(node: any, id: string): any?
	if type(node) ~= "table" then
		return nil
	end
	if node.id == id then
		return node
	end
	if type(node.c) == "table" then
		for _, child in node.c do
			local hit = findNode(child, id)
			if hit then
				return hit
			end
		end
	end
	return nil
end

-- One keyed node of a pane's current surface; nil when absent.
local function readNode(cx: WindowCx, pane: number, id: string): any?
	local ok, tree = pcall(function()
		return cx.session:surface(pane, { root = id, max_chars = 64000 })
	end)
	if not ok or type(tree) ~= "table" then
		return nil
	end
	for _, region in { tree.main, tree.dock, tree.layer } do
		local hit = findNode(region, id)
		if hit then
			return hit
		end
	end
	return nil
end

local function nodeProp(node: any, prop: string): any?
	if type(node) == "table" and type(node.p) == "table" then
		return node.p[prop]
	end
	return nil
end

-- `plotroom://github/<open|worktree|goto|agent|show>/<owner>/<repo>/<n>`, or `…/run/<owner>/<repo>/<n>/<prompt id>`:
-- the kind, the PR, and for `run` the saved prompt's id.
local function parseLink(url: string): (string?, string?, string?, number?, string?)
	local kind, owner, repo, n = string.match(url, "^plotroom://github/(%a+)/([^/]+)/([^/]+)/(%d+)$")
	local id: string? = nil
	if kind == "run" then
		kind = nil
	elseif not kind then
		owner, repo, n, id = string.match(url, "^plotroom://github/run/([^/]+)/([^/]+)/(%d+)/(%w+)$")
		kind = if id then "run" else nil
	end
	local num = tonumber(n)
	if not (VALID_ACTS[kind or ""] or kind == "open" or kind == "show") or not owner or not repo or not worktree.validSegment(owner) or not worktree.validSegment(repo) then
		return nil, nil, nil, nil, nil
	end
	if not num or num < 1 or num > 2147483647 then
		return nil, nil, nil, nil, nil
	end
	return kind, owner, repo, num, id
end

local function unpct(s: string): string
	return (string.gsub(s, "%%(%x%x)", function(h)
		return string.char(tonumber(h, 16) :: number)
	end))
end

-- `plotroom://github/check/<row>/<percent-encoded https URL>`: the row index and the page it links to.
local function parseCheck(url: string): (number?, string?)
	local i, enc = string.match(url, "^plotroom://github/check/(%d+)/(.+)$")
	local index = tonumber(i)
	if not index or not enc or index < 1 or index > 100000 then
		return nil, nil
	end
	local target = unpct(enc)
	if string.sub(target, 1, 8) ~= "https://" or string.find(target, "[%c%s]") then
		return nil, nil
	end
	return index, target
end

-- A pane in a tab of this window working in the worktree at `path`: pane, tab and session ids.
local function targetPane(cx: WindowCx, path: string): (number?, number?, number?)
	for _, p in cx.session:panes() do
		if p.tab and worktree.within(p.cwd or "", path) then
			for _, tb in cx.session:tabs() do
				if tb.id == p.tab then
					return p.pane, tb.id, tb.session
				end
			end
		end
	end
	return nil, nil, nil
end

-- Opens `url` beside `pane` as a plain link open would.
local function openUrl(cx: WindowCx, pane: number, url: string)
	cx.layout:focus(pane)
	cx:open(url, "beside")
end

-- Shows the pull request at `url` in `pane`, the Plotroom block the link came from (host/requests' `show`).
local function showPr(cx: WindowCx, pane: number, url: string)
	cx.session:event(pane, { ev = "action", act = "show-pr", value = url })
	cx.layout:focus(pane)
end

-- A `main.rpc` node's text as a protocol number; nil for none (a host still loading) or for garbage.
local function parseProtocol(text: any): number?
	return if type(text) == "string" and string.match(text, "^%d+$") then tonumber(text) else nil
end

-- The protocol the block in `pane` announces in its `main.rpc` node.
local function protocolOf(cx: WindowCx, pane: number): number?
	return parseProtocol(nodeProp(readNode(cx, pane, "main.rpc"), "text"))
end

-- Whether `p` lies in the range of host protocols this window asks: [rpc.MIN, rpc.PROTOCOL].
local function inRange(p: number?): boolean
	return p ~= nil and p >= rpc.MIN and p <= rpc.PROTOCOL
end

-- The name the user knows the block's host by: its host name, else its address, else a generic phrase.
local function hostName(cx: WindowCx, pane: number): string
	local h = flows.hostOf(cx, pane)
	local name = if h and h.name ~= "" then h.name elseif h and h.address ~= "" then h.address else nil
	return name or "this block's host"
end

-- Whether the block in `pane` speaks a protocol this window asks and, given `op`, one that knows that op; says so
-- when it does not, at once.
local function sameVersion(cx: WindowCx, pane: number, op: string?): boolean
	local p = protocolOf(cx, pane)
	if inRange(p) and (op == nil or (rpc.SINCE[op] or rpc.MIN) <= (p :: number)) then
		return true
	end
	if cx.session:pane(pane) == nil then
		return false -- the block is gone: not another version
	end
	local host = hostName(cx, pane)
	if inRange(p) then
		cx:toast("error", "Plotroom on " .. host .. " is an older version", "Install the current Plotroom on " .. host .. " (tern plugin install) to use this.")
	else
		cx:toast("error", "Plotroom on " .. host .. " is another version", "Install this version there (tern plugin install), then open the block again.")
	end
	return false
end

-- The focused Plotroom block's host announcing a protocol out of range, as a status-line warning naming that host.
-- Polled while that block is focused (a remote reload changes the announcement either way); a missing marker is a host
-- still loading, not a mismatch.
local WATCH_MS = 2000
local mismatched: { pane: number, host: string }? = nil -- the focused pane whose host announces another protocol
local pausedHooks: { [string]: boolean } = {} -- this plugin's own hooks paused over their budget (the `budget` event)
local watch: TimerHandle? = nil
local checkProtocol: (WindowCx) -> ()

-- One timer at a time: whoever finds none arms it, and its tick clears it before checking again.
local function arm(ms: number)
	if not watch then
		watch = tern.timer(ms, function(cx: WindowCx?)
			watch = nil
			if cx then
				checkProtocol(cx)
			end
		end)
	end
end

function checkProtocol(cx: WindowCx)
	local pane = cx.session:focused()
	local flagged: { pane: number, host: string }? = nil
	if pane and isPlotroom(cx, pane) then
		arm(WATCH_MS)
		local text = nodeProp(readNode(cx, pane, "main.rpc"), "text")
		if type(text) == "string" and not inRange(parseProtocol(text)) then
			flagged = { pane = pane, host = hostName(cx, pane) }
		end
	elseif watch then
		watch:cancel()
		watch = nil
	end
	local was = mismatched
	if (flagged and flagged.pane) ~= (was and was.pane) or (flagged and flagged.host) ~= (was and was.host) then
		mismatched = flagged
		tern.chrome.refresh()
	end
end

-- A plugin reload while a Plotroom block is focused fires no lifecycle event: start with a check of our own.
arm(0)

tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	local out: { StatusSegment } = {}
	if mismatched and pane.pane == mismatched.pane then
		table.insert(out, { text = "Plotroom on " .. mismatched.host .. " is a different version from this window's", icon = "warning", tone = "error" })
	end
	local paused = next(pausedHooks)
	if paused ~= nil then
		table.insert(out, { text = "Plotroom paused: " .. paused, icon = "warning", tone = "error" })
	end
	-- One count covers the agents that need input and the rest of Now: a click shows Now.
	local need = flows.needCount()
	if need > 0 then
		table.insert(out, { text = need .. " need you", icon = "inbox", command = "plugin.plotroom.now" })
	end
	return if #out > 0 then out else nil
end)

command({
	id = "agents-waiting",
	title = "Plotroom: Go to the first agent that needs input",
	icon = "merge",
	available = function(_cx: WindowCx): boolean
		return flows.waitingCount() > 0
	end,
	run = flows.goWaiting,
})

command({
	id = "now",
	title = "Plotroom: Show what needs you (Now)",
	icon = "inbox",
	available = function(_cx: WindowCx): boolean
		return flows.needCount() > 0
	end,
	run = flows.goNow,
})

local answered: (WindowCx, string) -> ()

-- Asks the host half of the Plotroom block in `pane` to run `op`, where the block runs. done(answer, cx) runs once,
-- with the decoded answer, when the host announces it (plotroom://rpc/<id>); with no answer within `ms`, a toast says
-- so instead. False when nothing was sent: an older host that does not know `op` is refused at once. `quiet` (a
-- background request): neither the refusal nor a missing answer is toasted.
local function ask(cx: WindowCx, pane: number, op: string, args: { [string]: any }, ms: number, done: (any, WindowCx) -> (), quiet: boolean?): boolean
	if quiet then
		local p = protocolOf(cx, pane)
		if not (inRange(p) and (rpc.SINCE[op] or rpc.MIN) <= (p :: number)) then
			return false
		end
	elseif not sameVersion(cx, pane, op) then
		return false
	end
	requests += 1
	local id = string.format("q%dt%d", requests, math.floor(tern.now()))
	args.id, args.op = id, op
	local timer = tern.timer(ms, function(cx2: WindowCx?)
		if pending[id] then
			pending[id] = nil
			if cx2 and not quiet then
				cx2:toast("error", "Plotroom: the block's host did not answer", "Try again; if it keeps happening, reload plugins on that host.")
			end
		end
	end)
	pending[id] = { pane = pane, done = done, timer = timer }
	local ok, why = pcall(function()
		cx.session:event(pane, { ev = "action", act = "rpc", value = tern.json.encode(args) })
	end)
	if not ok then
		timer:cancel()
		pending[id] = nil
		cx:toast("error", "Plotroom: the block could not be reached", tostring(why))
	else
		local function poll(cx2: WindowCx?)
			if cx2 and pending[id] then
				answered(cx2, id)
				if pending[id] then
					tern.timer(POLL_MS, poll)
				end
			end
		end
		tern.timer(POLL_MS, poll)
	end
	return ok
end

-- plotroom://rpc/<id>: the host answered request `id`. Only the window that asked acts, and only on the answer its
-- block shows: a link without one (stale, or not the host's) leaves the request waiting. `ask` also polls for the
-- answer, so one whose link was lost, or beat its rendered answer over a remote host, is still found.
function answered(cx: WindowCx, id: string)
	local p = pending[id]
	if not p then
		return
	end
	local text = nodeProp(readNode(cx, p.pane, "main.r" .. id), "text")
	if type(text) ~= "string" then
		return
	end
	pending[id] = nil
	p.timer:cancel()
	local ok, answer = pcall(tern.json.decode, text)
	if not ok or type(answer) ~= "table" then
		return cx:toast("error", "Plotroom: the block's answer could not be read")
	end
	p.done(answer, cx)
end

-- The command palette's and agent picker's rows the block in `pane` publishes on every render (host/requests'
-- paletteNode): read off its surface, so neither waits on the block's host. Nil, with a toast, when unreadable.
local function paletteOf(cx: WindowCx, pane: number): any?
	if not sameVersion(cx, pane) then
		return nil
	end
	local text = nodeProp(readNode(cx, pane, "main.palette"), "text")
	local ok, a = pcall(tern.json.decode, if type(text) == "string" then text else "")
	if not ok or type(a) ~= "table" then
		cx:toast("error", "Plotroom: the block's commands could not be read", "Try again in a moment.")
		return nil
	end
	return a
end

-- Focuses the tab working in the target's worktree, wherever the block's host noted it.
local function gotoTarget(cx: WindowCx, pane: number, t: Target)
	ask(cx, pane, "where", { kind = t.kind, key = string.lower(t.repo) .. "#" .. t.ref }, MENU_MS, function(a: any, cx2: WindowCx)
		local found, _, session = targetPane(cx2, if type(a.path) == "string" then a.path else "")
		if not found or not session then
			return cx2:toast("info", "No tab is open for " .. t.label)
		end
		cx2.sessions:switch(session)
		cx2.layout:focus(found)
	end)
end

-- The session holding `pane`'s tab, when it still exists.
local function sourceSession(cx: WindowCx, pane: number): number?
	local tab = cx.session:tab_of(pane)
	local sessionId: number? = nil
	if tab then
		for _, t in cx.session:tabs() do
			if t.id == tab then
				sessionId = t.session
			end
		end
	end
	for _, s in cx.session:sessions() do
		if s.id == sessionId then
			return sessionId
		end
	end
	return nil
end

-- Worktree path -> the title its tab shows (`#123 title`) and the name nameTab gave the tab, so a tab the user renamed
-- keeps theirs. ponytail: in memory, newest TAB_LABELS kept; a plugin reload forgets them and the tab shows its plain name.
local TAB_LABELS = 50
local tabLabels: { [string]: { label: string, name: string } } = {}
local tabLabelOrder: { string } = {}

local function labelTab(r: Ready, t: Target)
	if not r.title then
		return
	end
	local ref = if string.match(t.ref, "^%d+$") then "#" .. t.ref else t.ref
	local title = string.sub((string.gsub(r.title, "%c", " ")), 1, 60)
	if tabLabels[r.path] == nil then
		table.insert(tabLabelOrder, r.path)
		if #tabLabelOrder > TAB_LABELS then
			tabLabels[table.remove(tabLabelOrder, 1) :: string] = nil
		end
	end
	tabLabels[r.path] = { label = ref .. " " .. title, name = t.tab }
	tern.chrome.refresh()
end

tern.chrome.tab_title(function(tab: TabInfo): string?
	local cwd = tab.cwd
	if not cwd or cwd == "" then
		return nil
	end
	for path, e in tabLabels do
		if worktree.within(cwd, path) and (tab.name == nil or tab.name == e.name) then
			return e.label
		end
	end
	return nil
end)

-- Names the tab holding `pane` after the target.
local function nameTab(cx: WindowCx, pane: number, t: Target)
	local tab = cx.session:tab_of(pane)
	if tab then
		cx.layout:name_tab(tab, t.tab)
	end
end

local function finishWorktree(cx: WindowCx, pane: number, t: Target, r: Ready)
	-- Success only when nothing needs the user's attention.
	local level: ToastLevel = if r.current and r.dirty ~= true then "success" else "info"
	local sessionId = sourceSession(cx, pane)
	if not sessionId then
		return cx:toast(level, "Worktree ready (the source pane closed, so no tab was opened)", r.path .. " · " .. r.summary)
	end
	cx.sessions:switch(sessionId)
	local newPane = cx.layout:new_tab({ cwd = r.path })
	if not newPane then
		return cx:toast("error", "Worktree ready, but its tab did not open", r.path .. " · choose Worktree again to retry")
	end
	nameTab(cx, newPane, t)
	labelTab(r, t)
	if r.setup then
		cx:run(newPane, r.setup .. "\r")
	end
	cx:toast(level, "Worktree ready for " .. t.label, if r.setup then r.summary .. " · running setup" else r.summary)
end

-- The leaves of split tree `t` with their sizes, the tree laid over a w × h box ([1] is left/top at a split).
local function leaves(t: any, w: number, h: number, out: { { pane: number, w: number, h: number } })
	if type(t) ~= "table" then
		return
	elseif type(t.pane) == "number" then
		table.insert(out, { pane = t.pane, w = w, h = h })
		return
	end
	local r = if type(t.ratio) == "number" then t.ratio else 0.5
	if t.split == "right" then
		leaves(t[1], w * r, h, out)
		leaves(t[2], w * (1 - r), h, out)
	else
		leaves(t[1], w, h * r, out)
		leaves(t[2], w, h * (1 - r), out)
	end
end

local function tabLeaves(cx: WindowCx, tab: number?, w: number, h: number): { { pane: number, w: number, h: number } }
	local out = {}
	if tab then
		local ok, lay = pcall(function()
			return cx.session:layout(tab)
		end)
		if ok and type(lay) == "table" then
			leaves(lay.root, w, h, out)
		end
	end
	return out
end

-- Where the next agent goes in `tab` (docs/reference.md › Dispatch): the largest tiled pane, never the queue's pane
-- `queue` while another is there, split along its longer side; nil when the tab has no tree. The split tree gives only
-- ratios, so the frame's shape comes from the queue block's size in cells (its hidden `main.size`, a cell taken as twice
-- as tall as wide) over its share of its own tab; every tab of a window has that frame. Read before the agent starts,
-- so its own pane is never a candidate.
local function placement(cx: WindowCx, tab: number?, queue: number): (number?, Dir?)
	local fw, fh = 2, 1 -- ponytail: an older host publishes no size; a wide window is assumed
	local cols, rows = string.match(tostring(nodeProp(readNode(cx, queue, "main.size"), "text")), "^(%d+)x(%d+)$")
	if cols then
		for _, l in tabLeaves(cx, cx.session:tab_of(queue), 1, 1) do
			if l.pane == queue and l.w > 0 and l.h > 0 then
				fw, fh = tonumber(cols) :: number / l.w, 2 * tonumber(rows) :: number / l.h
			end
		end
	end
	local ls = tabLeaves(cx, tab, fw, fh)
	local best: { pane: number, w: number, h: number }? = nil
	for _, l in ls do
		if not (l.pane == queue and #ls > 1) and (best == nil or l.w * l.h > best.w * best.h * (1 + 1e-9)) then
			best = l
		end
	end
	if best == nil then
		return nil, nil
	end
	local side: Dir = if best.w >= best.h then "right" else "down"
	return best.pane, side
end

-- Starts an agent at `r.path` with `prompt` and the fixed end-of-run report contract (prompts.REPORT) after it, as
-- `omp --model <model>` when the prompt names one. `split`: as a block beside the queue (pane `pane`), in its tab,
-- where `placement` puts it. Else `join` (a worktree): in the target's open tab when there is one (where `placement`
-- puts it there), else in a new tab. Not `join` (the main checkout): a new tab. A new worktree's setup commands run first in a shell
-- tab, which a `join` agent joins. ponytail: the agent starts without waiting for the setup commands; poll the
-- shell's `last` status if agents trip over a half-done setup.
local function finishAgent(cx: WindowCx, pane: number, t: Target, r: Ready, prompt: string, job: Job, join: boolean, info: flows.AgentInfo): boolean
	local model, split = job.model, job.split == true
	local named = if job.id then job.name else nil -- a typed prompt has no name to show
	info.kind, info.model, info.runsIn = t.kind, model, if join then "worktree" else "main checkout"
	if model and not worktree.validModel(model) then
		cx:toast("error", "Agent not started for " .. t.label, "The action's model is not one omp takes: " .. model)
		return false
	end
	local path = r.path
	local tab: number? = nil
	local found: number? = nil
	if job.tab and not split then
		-- A chained action joins the tab of the one before it, while that tab is open.
		for _, tb in cx.session:tabs() do
			if tb.id == job.tab then
				tab, found = tb.id, tb.session
			end
		end
	end
	if not tab and join and not split then
		local _pane
		_pane, tab, found = targetPane(cx, path)
	end
	local session = found or sourceSession(cx, pane)
	if not session then
		cx:toast("success", if join then "Worktree ready" else "Checkout ready", path .. " (the source pane closed, so no agent was started)")
		return false
	end
	cx.sessions:switch(session)
	local setup = if join then r.setup else nil
	labelTab(r, t)
	if setup then
		local shell = cx.layout:new_tab({ cwd = path })
		if shell then
			cx:run(shell, setup .. "\r")
			nameTab(cx, shell, t)
			if not split then
				tab = cx.session:tab_of(shell)
			end
		else
			cx:toast("error", "Setup did not run for " .. t.label, "Its tab did not open.")
		end
	end
	-- A check run also gets the fixed check contract, naming the run it checks; the end-of-run contract stays last.
	local contract = (if job.check then prompts.checkBlock(job.check.action, job.check.commit) .. "\n\n" else "") .. prompts.REPORT
	-- Beside the queue, the agent splits the focused queue (no tab of its own, even briefly), then moves to its place.
	local target: number?, side: Dir? = placement(cx, if split then cx.session:tab_of(pane) else tab, pane)
	if split then
		cx.layout:focus(pane)
	end
	local ok, agent = pcall(function()
		-- Omitted, the command is the agent setting's (omp); a model needs its own command line.
		return cx.agents:start({ prompt = prompt .. "\n\n" .. contract, cwd = path, how = if split then "split" else "tab", command = if model then "omp --model " .. model else nil })
	end)
	if not ok or type(agent) ~= "number" then
		cx:toast("error", "Could not start an agent for " .. t.label, tostring(agent))
		return false
	end
	local chain: any = nil
	if job.id then
		chain = { action = job.id, name = job.name or "", next = job.next, kind = t.kind, repo = t.repo, ref = t.ref, depth = job.depth or 0, code = info.code, branch = info.branch, pane = pane, checker = job.checker }
		usage.bump("action:" .. (job.name or job.id))
	end
	info.cwd = path
	info.criteria, info.from = job.criteria, job.from
	if job.check then
		info.checkAgent, info.checkStarted = job.check.agent, job.check.started
	end
	flows.recordAgent(cx, pane, string.lower(t.repo) .. "#" .. t.ref, agent, chain, info)
	if split then
		if target and side then
			cx.layout:move(agent, target, side) -- refused, it stays where it split the queue
		end
		cx:toast("success", "Agent started beside the queue for " .. t.label, named)
		return true
	end
	if tab then
		if target and side and cx.layout:move(agent, target, side) then
			cx:toast("success", "Agent started in the tab of " .. t.label, named)
			return true
		end
		local moved, why = cx.layout:move_to_tab(agent, tab)
		if moved then
			cx:toast("success", "Agent started in the tab of " .. t.label, named)
			return true
		end
		nameTab(cx, agent, t)
		cx:toast("info", "Agent started in a new tab for " .. t.label, "It could not join the tab: " .. (why or "unknown reason"))
		return true
	end
	nameTab(cx, agent, t)
	cx:toast("success", "Agent started for " .. t.label, named)
	return true
end

-- The worktree exists whatever `step` does: a failing tab call must not hide its path.
local function afterReady(cx: WindowCx, r: Ready, step: () -> ())
	local why: any
	local ok = xpcall(step, function(e: any)
		why = e
	end)
	if not ok then
		cx:toast("error", "Worktree ready, but its tab did not open", r.path .. " · " .. tostring(why))
	end
end

-- The host's answer about a ready worktree; nil when it is not one.
local function readyOf(a: any): Ready?
	if type(a.path) ~= "string" or type(a.summary) ~= "string" then
		return nil
	end
	return {
		path = a.path,
		created = a.created == true,
		current = a.current == true,
		dirty = if type(a.dirty) == "boolean" then a.dirty else nil,
		summary = a.summary,
		setup = if type(a.setup) == "string" then a.setup else nil,
		title = if type(a.title) == "string" then a.title elseif type(a.vars) == "table" and type(a.vars.title) == "string" then a.vars.title else nil,
	}
end

-- A `{name}` variable in a prompt: letters, dots between words (`{github.user}`), as tracker.VAR spells it.
local VAR = "{([%a%.]+)}"

-- `{name}` variables a prompt may use, from the PR's coordinates and the host's fresh read of it; others stay as typed.
-- `{flaky}` reads "none" from a host older than protocol 39, which does not send it.
local function fill(prompt: string, owner: string, repo: string, n: number, a: any): string
	local vars: { [string]: string } = {
		url = "https://github.com/" .. owner .. "/" .. repo .. "/pull/" .. n,
		owner = owner,
		repo = repo,
		number = tostring(n),
		flaky = "none",
	}
	for _, k in { "title", "author", "branch", "base", "remote", "github.user", "criteria", "findings", "flaky", "failures" } do
		if type(a[k]) == "string" then
			vars[k] = a[k]
		end
	end
	return (string.gsub(prompt, VAR, vars))
end

-- An issue's prompt variables: the host's `vars` (strings only); others stay as typed.
local function fillVars(prompt: string, vars: any): string
	if type(vars) ~= "table" then
		return prompt
	end
	return (string.gsub(prompt, VAR, function(k: string): string
		local v = vars[k]
		return if type(v) == "string" then v else "{" .. k .. "}"
	end))
end

-- Asks the host to move a Jira issue to the status an action names (the host runs acli, no API token) and
-- toasts what came of it; nothing for an issue already there or one that is not Jira's. The agent does not wait for it.
local function moveStatus(cx: WindowCx, pane: number, t: Target, status: string)
	ask(cx, pane, "move-status", { ref = t.ref, status = status }, PREPARE_MS, function(a: any, cx2: WindowCx)
		if type(a.moved) == "string" then
			cx2:toast("success", "Moved " .. t.label .. " to " .. a.moved)
		elseif type(a.problem) == "string" then
			cx2:toast("error", "Not moved to " .. status .. ": " .. t.label, a.problem)
		end
	end)
end

-- What prepareTarget's earlier answers settled: the repository a Jira issue is worked in (`target`), and for a new issue
-- worktree the linked PR to check out (`pr`) or a new branch (`fresh`) from remote branch `base`.
type Settled = { target: string?, pr: number?, fresh: boolean?, base: string? }

local function settle(more: Settled?, add: Settled): Settled
	local out: Settled = if more then table.clone(more) else {}
	for k, v in add :: { [string]: any } do
		(out :: any)[k] = v
	end
	return out
end

-- Asks for the checkout of `repo` and has the block's host verify and save it (a new or empty folder gets a clone), then
-- runs `after`. `found`, the folder the host detected as one, is offered first as Use <path>; Another folder… asks.
local function askCheckout(cx: WindowCx, pane: number, repo: string, found: string?, after: ((WindowCx) -> ())?)
	local function claim(cx3: WindowCx, path: string)
		ask(cx3, pane, "checkout", { repo = repo, path = path }, CLONE_WAIT_MS, function(b: any, cx4: WindowCx)
			if b.ok == true then
				cx4:toast("success", if b.cloned == true then "Cloned " .. repo else "Checkout saved", if type(b.root) == "string" then b.root else nil)
				if after then
					after(cx4)
				end
				return
			end
			cx4:toast("error", "Checkout not saved", if type(b.problem) == "string" then b.problem else "The block's host could not save it")
		end)
	end
	local function prompt(cx2: WindowCx)
		cx2:prompt({ placeholder = "Folder of your checkout of " .. repo .. " (a new or empty folder gets a clone)", icon = "merge", action = "save" }):next(function(text, _, cx3)
			if cx3 and text and string.find(text, "%S") then
				claim(cx3, text)
			end
		end)
	end
	if not found then
		return prompt(cx)
	end
	local items: { PickItem } = {
		{ label = "Use " .. found, detail = "A checkout of " .. repo .. " found open in Tern" },
		{ label = "Another folder…", detail = "A new or empty folder gets a clone", typed = true },
	}
	cx:pick({ items = items, placeholder = "Checkout of " .. repo .. "?", icon = "merge", action = "save" }):next(function(item, _, cx3)
		if not item or not cx3 then
			return
		elseif item.typed then
			return prompt(cx3)
		end
		claim(cx3, found)
	end)
end

-- Has the block's host prepare the target's directory and run `prompt` there, or without `prompt` create or reuse its
-- worktree (noted on the block) and open its tab. `wt` false: the repository's main checkout, no worktree.
-- What the host still needs is asked in the palette, then this runs again with `more`: a checkout folder of the
-- repository (`needCheckout`), the repository a Jira project's issue is worked in (`needRepo`, or `chooseRepo` among
-- several), which of an issue's linked pull requests to check out or a new branch (`choosePr`), and the base branch a
-- new branch starts from (`chooseBase`).
local function prepareTarget(cx: WindowCx, pane: number, t: Target, prompt: Job?, wt: boolean, more: Settled?)
	local function again(cx3: WindowCx, add: Settled)
		prepareTarget(cx3, pane, t, prompt, wt, settle(more, add))
	end
	-- A chain step whose start fails on the way says so (Job.fail), so it counts and is tried again.
	local function failed(cx2: WindowCx)
		if prompt and prompt.fail then
			prompt.fail(cx2)
		end
	end
	local function done(a: any, cx2: WindowCx)
		if a.busy == true then
			failed(cx2)
			return cx2:toast("info", "A worktree for " .. t.label .. " is already being prepared")
		elseif type(a.needCheckout) == "string" then
			return askCheckout(cx2, pane, a.needCheckout, if type(a.found) == "string" then a.found else nil, function(cx4: WindowCx)
				again(cx4, {})
			end)
		elseif a.needRepo == true then
			local project: string = if type(a.project) == "string" then a.project else t.repo
			local items: { PickItem } = {}
			for _, name in if type(a.repos) == "table" then a.repos else {} do
				if type(name) == "string" then
					table.insert(items, { label = name, group = "Repositories" })
				end
			end
			table.insert(items, { label = "Other repository…", detail = "Type owner/name", typed = true })
			local function map(cx3: WindowCx, repo: string)
				ask(cx3, pane, "map-jira", { project = project, repo = repo }, MENU_MS, function(b: any, cx4: WindowCx)
					if b.ok == true then
						return again(cx4, { target = repo })
					end
					cx4:toast("error", "Repository not saved", if type(b.problem) == "string" then b.problem else "The block's host could not save it")
				end)
			end
			cx2:pick({ items = items, placeholder = "Repository for Jira project " .. project .. "…", icon = "merge", action = "map" }):next(function(item, _, cx3)
				if not item or not cx3 then
					return
				elseif item.typed then
					return cx3:prompt({ placeholder = "owner/name", icon = "merge", action = "map" }):next(function(text, _, cx4)
						if cx4 and text and string.find(text, "%S") then
							map(cx4, text)
						end
					end)
				end
				map(cx3, item.label)
			end)
			return
		elseif a.chooseRepo == true then
			local items: { PickItem } = {}
			for _, name in if type(a.repos) == "table" then a.repos else {} do
				if type(name) == "string" then
					table.insert(items, { label = name, group = "Repositories" })
				end
			end
			cx2:pick({ items = items, placeholder = "Which repository for " .. t.label .. "?", icon = "merge", action = "open" }):next(function(item, _, cx3)
				if item and cx3 then
					again(cx3, { target = item.label })
				end
			end)
			return
		elseif a.choosePr == true then
			local items: { PickItem } = {}
			for _, p in if type(a.prs) == "table" then a.prs else {} do
				if type(p) == "table" and type(p.number) == "number" and type(p.title) == "string" then
					local fork = if type(p.fork) == "string" and p.fork ~= "" then p.fork else nil
					local branch = if type(p.branch) == "string" then p.branch else nil
					table.insert(items, { label = "#" .. p.number .. " " .. p.title, detail = if fork then "Fork of " .. fork .. (if branch then " · " .. branch else "") else branch, group = "Linked pull requests", pr = p.number })
				end
			end
			table.insert(items, { label = "New branch…", detail = "Starts from a base branch you pick next", group = "Or", fresh = true })
			cx2:pick({ items = items, placeholder = "Which branch for " .. t.label .. "?", icon = "merge", action = "open" }):next(function(item, _, cx3)
				if not item or not cx3 then
					return
				end
				again(cx3, if item.fresh == true then { fresh = true } else { pr = item.pr })
			end)
			return
		elseif a.chooseBase == true then
			local items: { PickItem } = {}
			for i, name in if type(a.branches) == "table" then a.branches else {} do
				if type(name) == "string" then
					table.insert(items, { label = name, group = if i == 1 then "Default branch" else "Branches" })
				end
			end
			local branch = if type(a.branch) == "string" then a.branch else "the new branch"
			cx2:pick({ items = items, placeholder = "Start " .. branch .. " from…", icon = "merge", action = "open" }):next(function(item, _, cx3)
				if item and cx3 then
					again(cx3, { fresh = true, base = item.label })
				end
			end)
			return
		end
		local r = readyOf(a)
		if not r then
			failed(cx2)
			return cx2:toast("error", "Worktree failed", if type(a.problem) == "string" then a.problem else "The block's host gave no worktree")
		end
		local ready: Ready = r
		-- Starts the agent with the run's acceptance criteria `criteria` (Job.criteria) as its `{criteria}` block, added
		-- at the end when a builder with a checker, or a check, does not name it; a fix round's findings likewise.
		local function run(cx3: WindowCx, criteria: string?)
			afterReady(cx3, ready, function()
				if not prompt then
					return finishWorktree(cx3, pane, t, ready)
				elseif prompt.from and not flows.stillDue(prompt.from) then
					return -- the step ended while it was prepared (an action started by hand): no agent for it
				end
				local job: Job = table.clone(prompt)
				job.criteria = criteria
				local text = prompt.text
				if (prompt.checker or prompt.check) and not string.find(text, "{criteria}", 1, true) then
					text ..= "\n\n{criteria}"
				end
				if prompt.findings and not string.find(text, "{findings}", 1, true) then
					text ..= "\n\n{findings}"
				end
				local block, found = prompts.criteriaBlock(criteria), prompts.findingsBlock(prompt.findings)
				local started: boolean
				if t.kind == "pr" then
					local owner, name = string.match(t.repo, "^([^/]+)/([^/]+)$")
					a.criteria, a.findings = block, found
					started = finishAgent(cx3, pane, t, ready, fill(text, owner or "", name or "", tonumber(t.ref) :: number, a), job, wt, { action = prompt.name, branch = strOf(a.branch), title = strOf(a.title), outcome = prompt.outcome, login = strOf(a["github.user"]), ghRepo = t.repo, number = tonumber(t.ref) })
				else
					local vars: any = a.vars
					if type(vars) == "table" then
						vars.criteria, vars.findings = block, found
					end
					started = finishAgent(cx3, pane, t, ready, fillVars(text, vars), job, wt, { action = prompt.name, branch = if type(vars) == "table" then strOf(vars.branch) else nil, title = if type(vars) == "table" then strOf(vars.title) else nil, code = strOf(a.code), outcome = prompt.outcome, login = if type(vars) == "table" then strOf(vars["github.user"]) else nil, ghRepo = strOf(a.code) })
					if started and prompt.status then
						moveStatus(cx3, pane, t, prompt.status)
					end
				end
				if not started then
					failed(cx3)
				end
			end)
		end
		-- An issue run that has a checker or names {criteria} saves the issue's acceptance criteria now, at dispatch
		-- (host/requests' `criteria`); a check reuses the snapshot of the run it checks. A pull request has none.
		local wants = prompt ~= nil and prompt.criteria == nil and t.kind == "issue" and (prompt.checker ~= nil or string.find(prompt.text, "{criteria}", 1, true) ~= nil)
		if not wants then
			return run(cx2, if prompt then prompt.criteria else nil)
		end
		local sent = ask(cx2, pane, "criteria", { repo = t.repo, ref = t.ref }, PREPARE_MS, function(b: any, cx3: WindowCx)
			if type(b.problem) == "string" then
				cx3:toast("info", "No acceptance criteria saved for " .. t.label, b.problem)
			end
			run(cx3, if type(b.criteria) == "string" then b.criteria else "")
		end)
		if not sent then
			run(cx2, "")
		end
	end
	-- The users cost the host a gh (or acli) call, so they are asked for only when the prompt names one, or its outcome
	-- is checked as the GitHub login it runs as.
	local users = prompt ~= nil and (prompt.outcome ~= nil or string.find(prompt.text, "{github.user}", 1, true) ~= nil or string.find(prompt.text, "{jira.user}", 1, true) ~= nil)
	local m: Settled = more or {}
	local sent = if t.kind == "pr"
		then ask(cx, pane, "worktree", { repo = t.repo, number = tonumber(t.ref), worktree = wt, users = users, failures = prompt ~= nil and string.find(prompt.text, "{failures}", 1, true) ~= nil }, PREPARE_MS, done)
		else ask(cx, pane, "issue", { repo = t.repo, ref = t.ref, worktree = wt, target = m.target, pr = m.pr, fresh = m.fresh, base = m.base, users = users }, PREPARE_MS, done)
	if not sent then
		failed(cx)
	end
	if sent and wt and not more then
		cx:toast("info", "Preparing worktree for " .. t.label)
	end
end

-- The row that offers to go to the agent `link` already running on a target: its state, and the action it runs.
local function goAgentRow(link: any, state: string): PickItem
	local name = if link.chain and link.chain.name ~= "" then link.chain.name else link.action
	return { label = "Go to agent (" .. flows.stateLabel(state) .. ")", detail = if type(name) == "string" and name ~= "" then name else "A typed prompt", go = true }
end

-- Runs `go` unless an agent works on the target: then it offers Go to agent (its state) or starting anyway, and a
-- dismissed picker does nothing. `what` names what would start ("Start <what> anyway").
local function ifFree(cx: WindowCx, pane: number, t: Target, what: string, go: (WindowCx) -> ())
	local key = string.lower(t.repo) .. "#" .. t.ref
	local link, state = flows.liveAgent(cx, pane, key)
	if not link or not state then
		return go(cx)
	end
	local items: { PickItem } = {
		goAgentRow(link, state),
		{ label = "Start " .. what .. " anyway", detail = "Another agent for " .. t.label },
	}
	cx:pick({ items = items, placeholder = "An agent already works on " .. t.label, icon = "merge", action = "go or start" }):next(function(item, _, cx2)
		if not item or not cx2 then
			return
		elseif item.go == true then
			return flows.goAgent(cx2, pane, key)
		end
		go(cx2)
	end)
end

-- Starts saved prompt `id` on the target: the block's host says what it is now (one text, so the picker's size budget
-- never drops it), and only one it still offers runs. `checked`: the caller already asked about a live agent.
local function runSaved(cx: WindowCx, pane: number, t: Target, id: string, checked: boolean?)
	ask(cx, pane, "menu", { only = id }, MENU_MS, function(a: any, cx2: WindowCx)
		for _, it in if type(a.items) == "table" then a.items else {} do
			if type(it) == "table" and it.id == id and type(it.send) == "string" then
				local job: Job = { text = it.send, model = if type(it.model) == "string" then it.model else nil, split = it.split == true, status = if type(it.status) == "string" then it.status else nil, id = id, name = if type(it.label) == "string" then it.label else nil, next = if type(it.next) == "string" then it.next else nil, outcome = if type(it.outcome) == "string" then it.outcome else nil, checker = if type(it.checker) == "string" then it.checker else nil }
				local function go(cx3: WindowCx)
					prepareTarget(cx3, pane, t, job, it.worktree ~= false)
				end
				if checked then
					return go(cx2)
				end
				return ifFree(cx2, pane, t, job.name or "the action", go)
			end
		end
		cx2:toast("error", "That action is no longer offered here", if type(a.problem) == "string" then a.problem else "Refresh and try again.")
	end)
end

-- Asks for a prompt's text and runs it on the target in an agent in its worktree. `checked`: the caller already asked
-- about a live agent.
local function typePrompt(cx: WindowCx, pane: number, t: Target, checked: boolean?)
	local function askText(cx2: WindowCx)
		cx2:prompt({ placeholder = "Prompt for an agent on " .. t.label, icon = "merge", action = "send" }):next(function(text, _, cx3)
			if cx3 and text and string.find(text, "%S") then
				prepareTarget(cx3, pane, t, { text = text, name = "Typed prompt" }, true)
			end
		end)
	end
	if checked then
		return askText(cx)
	end
	ifFree(cx, pane, t, "a typed prompt", askText)
end

-- Asks which saved prompt (Settings › Actions, those the block's view offers) to run on the target, then
-- runs it in an agent where the prompt says (its worktree or the main checkout). "Type a prompt…" sends typed text
-- to the worktree.
local function pickMenu(cx: WindowCx, pane: number, t: Target)
	-- Rows without their text, so the picker's size budget never drops an action; the pick fetches its own.
	local a = paletteOf(cx, pane)
	if not a then
		return
	end
	if type(a.problem) == "string" then
		cx:toast("error", "Actions are not listed", a.problem)
	end
	local all: { PickItem } = {}
	for _, it in if type(a.items) == "table" then a.items else {} do
		if type(it) == "table" and type(it.label) == "string" and type(it.id) == "string" then
			table.insert(all, {
				label = it.label,
				detail = if type(it.detail) == "string" then it.detail else nil,
				group = if type(it.group) == "string" then it.group else nil,
				id = it.id,
			})
		end
	end
	local items: { PickItem } = {}
	local recentLabels: { string } = readRecent() or {}
	for _, label in recentLabels do
		for _, c in all do
			if c.label == label then
				local again = table.clone(c)
				again.group = "Recent"
				table.insert(items, again)
				break
			end
		end
	end
	table.insert(items, { label = "Type a prompt…", detail = if #all == 0 then "Save actions in Settings › Actions" else "Send your own text", typed = true })
	for _, c in all do
		table.insert(items, c)
	end
	cx:pick({ items = items, placeholder = "Run on " .. t.label, icon = "merge", action = "run" }):next(function(item, _, cx3)
		if not item or not cx3 then
			return
		end
		if item.typed then
			return typePrompt(cx3, pane, t, true)
		end
		local recent = readRecent()
		if recent then
			local at = table.find(recent, item.label)
			if at then
				table.remove(recent, at)
			end
			table.insert(recent, 1, item.label)
			recent[RECENT_CAP + 1] = nil
			pcall(tern.kv.set, RECENT_KEY, tern.json.array(recent)) -- best effort: a failed write only loses the order
		end
		runSaved(cx3, pane, t, item.id :: string, true)
	end)
end

-- An agent already linked to the target is offered first (its state shown); starting another goes to the menu.
local function pickAgent(cx: WindowCx, pane: number, t: Target)
	local key = string.lower(t.repo) .. "#" .. t.ref
	local link, state = flows.liveAgent(cx, pane, key)
	if not link or not state then
		return pickMenu(cx, pane, t)
	end
	local items: { PickItem } = {
		goAgentRow(link, state),
		{ label = "Start another agent", detail = "Choose an action to run" },
	}
	cx:pick({ items = items, placeholder = "An agent already works on " .. t.label, icon = "merge", action = "go or start" }):next(function(item, _, cx2)
		if not item or not cx2 then
			return
		elseif item.go == true then
			return flows.goAgent(cx2, pane, key)
		end
		pickMenu(cx2, pane, t)
	end)
end

-- Adds `repo` to Settings' repositories and opens its checkout row there; the block's host checks it.
local function addRepo(cx: WindowCx, pane: number, repo: string)
	cx.session:event(pane, { ev = "action", act = "add-repo", value = repo })
end

-- The repositories gh login `login` can access, listed by the block's host (its heading shows they are loading), to
-- pick the one to add.
local function pickProfile(cx: WindowCx, pane: number, login: string)
	ask(cx, pane, "profile", { login = login }, REPOS_MS, function(a: any, cx2: WindowCx)
		if type(a.problem) == "string" then
			return cx2:toast("error", "The repositories of @" .. login .. " are not listed", a.problem)
		end
		local items: { PickItem } = {}
		for _, name in if type(a.repos) == "table" then a.repos else {} do
			if type(name) == "string" then
				table.insert(items, { label = name })
			end
		end
		if #items == 0 then
			return cx2:toast("info", "@" .. login .. " has no repositories")
		end
		cx2:pick({ items = items, placeholder = "Add repository of @" .. login .. "…", icon = "merge", action = "add" }):next(function(item, _, cx3)
			if item and cx3 then
				addRepo(cx3, pane, item.label)
			end
		end)
	end)
end

-- Asks which repository to add to Settings: a saved one (its checkout as the detail), one of a signed-in gh login's
-- (picked next), or one typed as owner/name.
local function pickRepo(cx: WindowCx, pane: number)
	ask(cx, pane, "repos", {}, MENU_MS, function(a: any, cx2: WindowCx)
		if type(a.problem) == "string" then
			cx2:toast("error", "Your GitHub accounts are not listed", a.problem)
		end
		local items: { PickItem } = {}
		for _, it in if type(a.items) == "table" then a.items else {} do
			if type(it) == "table" and type(it.repo) == "string" then
				local path = if type(it.path) == "string" then it.path else "No checkout yet"
				table.insert(items, { label = it.repo, detail = path, group = "Saved", repo = it.repo })
			end
		end
		for _, acc in if type(a.accounts) == "table" then a.accounts else {} do
			if type(acc) == "table" and type(acc.login) == "string" then
				table.insert(items, { label = "@" .. acc.login, detail = "View repositories…", group = "GitHub accounts", login = acc.login })
			end
		end
		table.insert(items, { label = "Other repository…", detail = "Type owner/name", typed = true })
		cx2:pick({ items = items, placeholder = "Add repository…", icon = "merge", action = "add" }):next(function(item, _, cx3)
			if not item or not cx3 then
				return
			elseif item.login then
				return pickProfile(cx3, pane, item.login)
			elseif item.typed then
				return cx3:prompt({ placeholder = "owner/name", icon = "merge", action = "add" }):next(function(text, _, cx4)
					if cx4 and text and string.find(text, "%S") then
						addRepo(cx4, pane, text)
					end
				end)
			end
			addRepo(cx3, pane, item.repo)
		end)
	end)
end

-- Asks which Jira project to add to Settings: a saved one (its repositories as the detail), one acli lists, or one typed
-- by its key.
local function pickJira(cx: WindowCx, pane: number)
	ask(cx, pane, "jira-projects", {}, MENU_MS, function(a: any, cx2: WindowCx)
		if type(a.problem) == "string" then
			cx2:toast("error", "Your Jira projects are not listed", a.problem)
		end
		local items: { PickItem } = {}
		for _, it in if type(a.items) == "table" then a.items else {} do
			if type(it) == "table" and type(it.key) == "string" then
				if it.saved == true then
					local repos = if type(it.repos) == "string" and it.repos ~= "" then it.repos else "No repositories yet"
					table.insert(items, { label = it.key, detail = repos, group = "Saved", key = it.key })
				else
					table.insert(items, { label = it.key, detail = if type(it.name) == "string" then it.name else "", group = "Jira projects", key = it.key })
				end
			end
		end
		table.insert(items, { label = "Other project…", detail = "Type its key", typed = true })
		cx2:pick({ items = items, placeholder = "Add Jira project…", icon = ISSUE_ICON, action = "add" }):next(function(item, _, cx3)
			if not item or not cx3 then
				return
			elseif item.typed then
				return cx3:prompt({ placeholder = "Project key, such as ABC", icon = ISSUE_ICON, action = "add" }):next(function(text, _, cx4)
					if cx4 and text and string.find(text, "%S") then
						cx4.session:event(pane, { ev = "action", act = "add-jira", value = text })
					end
				end)
			end
			cx3.session:event(pane, { ev = "action", act = "add-jira", value = item.key })
		end)
	end)
end

-- plotroom://confirm: asks in the palette before the Plotroom block in `pane` deletes what its hidden `main.confirm`
-- node names (host/render's `deleteQuestion`). Cancel comes first, so Enter keeps it. The answer goes back to that block,
-- which acts only on the row it asked about.
local function confirmDelete(cx: WindowCx, pane: number)
	if not sameVersion(cx, pane) then
		return
	end
	local text = nodeProp(readNode(cx, pane, "main.confirm"), "text")
	local ok, q = pcall(tern.json.decode, if type(text) == "string" then text else "")
	if not ok or type(q) ~= "table" or type(q.row) ~= "string" or type(q.head) ~= "string" or type(q.label) ~= "string" then
		return cx:toast("error", "Plotroom: nothing to delete", "Press Delete again.")
	end
	local row: string = q.row
	local items: { PickItem } = {
		{ label = "Cancel", icon = "x" },
		{ label = q.label, detail = if type(q.detail) == "string" then q.detail else nil, icon = "trash", confirm = true },
	}
	cx:pick({ items = items, placeholder = q.head, icon = "trash" }):next(function(item, _, cx2)
		if cx2 then
			cx2.session:event(pane, { ev = "action", act = if item and item.confirm then "confirm-delete" else "cancel-delete", value = row })
		end
	end)
end

-- Whether check row `index` of the pane's live surface carries exactly `url`.
local function checkListed(cx: WindowCx, pane: number, index: number, url: string): boolean
	for _, list in CHECK_LISTS do
		if nodeProp(readNode(cx, pane, list .. ".run" .. index), "href") == url then
			return true
		end
	end
	return false
end

-- Whether a linked pull request row (issue sidebar's `linked`, or its worktree-branch `headpr`) of the pane's live
-- surface carries exactly `url`.
local function linkedListed(cx: WindowCx, pane: number, url: string): boolean
	for _, id in { LINKED_NODE, HEADPR_NODE } do
		local list = readNode(cx, pane, id)
		for _, row in if type(list) == "table" and type(list.c) == "table" then list.c else {} do
			if nodeProp(row, "href") == url then
				return true
			end
		end
	end
	return false
end

-- Whether the pull request preview's noted issue row carries exactly `url`.
local function noteListed(cx: WindowCx, pane: number, url: string): boolean
	local list = readNode(cx, pane, NOTED_NODE)
	for _, row in if type(list) == "table" and type(list.c) == "table" then list.c else {} do
		if nodeProp(row, "href") == url then
			return true
		end
	end
	return false
end

local follow: (cx: WindowCx, pane: number, nodeId: string, missing: string?, typed: boolean?) -> ()

-- The order the palette's groups come in; a group the host names that is not here follows them. The host names the
-- item's own operations by its type (Jira - Issue, GitHub - PR, GitHub - Issue); Next is its suggested next move.
local GROUPS = { "Next", "Actions", "Agents", "Jira - Issue", "GitHub - PR", "GitHub - Issue", "Now", "Triage", "Filter & Sort", "Views", "Worktree", "Configuration" }

-- plotroom://more: the command palette of the Plotroom block `pane`, in groups. Only what applies to the selection now is
-- listed: the block publishes the queue actions (`queue`, each with its group, key and detail, sent back as its `queue`
-- action) and the flows.COMMANDS ids (`commands`, each with the group the host gives it) it will accept. With an item
-- selected, a typed prompt and the saved actions its view offers form the Saved actions group (each run through its
-- hidden link, as its key runs it); the agent picker is no row of its own.
local function palette(cx: WindowCx, pane: number)
	local hasItem = type(nodeProp(readNode(cx, pane, AGENT_NODE), "href")) == "string"
	local a = paletteOf(cx, pane)
	if not a then
		return
	end
	if hasItem and type(a.problem) == "string" then
		cx:toast("error", "Actions are not listed", a.problem)
	end
	local function keyed(key: any, rest: any): string?
		local k = if type(key) == "string" and key ~= "" then "key " .. key else nil
		local r = if type(rest) == "string" and rest ~= "" then rest else nil
		return if k and r then k .. " · " .. r else k or r
	end
	local by: { [string]: { PickItem } } = {}
	local names: { string } = {}
	local function add(group: string, item: PickItem)
		if not by[group] then
			by[group] = {}
			table.insert(names, group)
		end
		item.group = group
		table.insert(by[group], item)
	end
	if hasItem then
		add("Actions", { label = "Type a prompt…", detail = "Run your own text in an agent", typed = true })
		for _, it in if type(a.items) == "table" then a.items else {} do
			if type(it) == "table" and type(it.id) == "string" and type(it.label) == "string" then
				add("Actions", { label = it.label, detail = keyed(it.key, it.detail), run = it.id })
			end
		end
	end
	for _, q in if type(a.queue) == "table" then a.queue else {} do
		if type(q) == "table" and type(q.id) == "string" and type(q.label) == "string" then
			add(if type(q.group) == "string" then q.group else "Filter & Sort", { label = q.label, detail = keyed(q.key, q.detail), queue = q.id })
		end
	end
	local offered: { [string]: string | boolean } = {}
	for _, c in if type(a.commands) == "table" then a.commands else {} do
		if type(c) == "table" and type(c.id) == "string" then
			offered[c.id] = if type(c.group) == "string" then c.group else true
		end
	end
	for i, c in flows.COMMANDS do
		local g = offered[c.id]
		if not c.keyed and g then
			add(if type(g) == "string" then g else c.group or "Configuration", { label = c.label, at = i })
		end
	end
	local items: { PickItem } = {}
	local placed: { [string]: boolean } = {}
	for _, g in GROUPS do
		placed[g] = true
		local group = by[g]
		if group then
			for _, it in group do
				table.insert(items, it)
			end
		end
	end
	for _, g in names do
		if not placed[g] then
			for _, it in by[g] do
				table.insert(items, it)
			end
		end
	end
	cx:pick({ items = items, placeholder = "Run a command", icon = "merge", action = "run" }):next(function(item, _, cx3)
		if not item or not cx3 or not isPlotroom(cx3, pane) then
			return
		elseif item.typed then
			follow(cx3, pane, AGENT_NODE, "Select a pull request or issue first", true)
		elseif type(item.run) == "string" then
			follow(cx3, pane, PROMPT_NODE .. item.run, "That action is no longer offered here")
		elseif type(item.queue) == "string" then
			cx3.session:event(pane, { ev = "action", act = "queue", value = item.queue })
		else
			local c = flows.COMMANDS[item.at :: number]
			if c then
				usage.bump("row:" .. c.id)
				c.run(cx3, pane)
			end
		end
	end)
end

-- Validates a plotroom:// link against the pane's live surface and runs it. `typed`: an agent link asks for a typed
-- prompt straight away (the command palette's Type a prompt…), not the agent picker. An action link ends in the host's
-- `?k=<token>`: it is parsed without it but compared with the node's href whole, so a link without the host's token
-- (written into a description, or from another run of the host) matches no node and is refused as no longer listed.
local function handle(cx: WindowCx, full: string, pane: number, typed: boolean?): boolean
	local url = string.gsub(full, "%?k=%x+$", "")
	local rid = string.match(url, "^plotroom://rpc/(%w+)$")
	if rid then
		answered(cx, rid)
		return true
	end
	local shown = string.match(url, "^plotroom://lens/show/(.+)$")
	if shown then
		-- The one link a pane that is not a Plotroom block may send (the shell lens's Show in Plotroom): it only shows a
		-- pull request page, which the block's host validates again.
		local page = unpct(shown)
		if #page > 2048 or not string.match(page, "^https://github%.com/[%w%._%-]+/[%w%._%-]+/pull/%d+$") then
			cx:toast("error", "Plotroom: malformed link")
		else
			flows.showUrl(cx, pane, page)
		end
		return true
	end
	if url == "plotroom://repos" or url == "plotroom://jira-projects" or url == "plotroom://confirm" then
		if not isPlotroom(cx, pane) then
			cx:toast("error", "Plotroom: link did not come from a Plotroom block")
		elseif url == "plotroom://repos" then
			pickRepo(cx, pane)
		elseif url == "plotroom://jira-projects" then
			pickJira(cx, pane)
		else
			confirmDelete(cx, pane)
		end
		return true
	end
	if url == "plotroom://worktrees/git" then
		if not isPlotroom(cx, pane) then
			cx:toast("error", "Plotroom: link did not come from a Plotroom block")
		else
			flows.openGit(cx, pane, full)
		end
		return true
	end
	local cOwner, cName = string.match(url, "^plotroom://checkout/([^/]+)/([^/]+)$")
	if string.sub(url, 1, 20) == "plotroom://checkout/" then
		-- The Get started checklist's line for a repository whose checkout was not found: ask for a folder.
		if not isPlotroom(cx, pane) then
			cx:toast("error", "Plotroom: link did not come from a Plotroom block")
		elseif not cOwner or not cName or not worktree.validSegment(cOwner) or not worktree.validSegment(cName) then
			cx:toast("error", "Plotroom: malformed link")
		else
			askCheckout(cx, pane, cOwner .. "/" .. cName, nil, nil)
		end
		return true
	end
	if url == "plotroom://next" then
		-- The Next move that is a window command (the block opens this for it): run as its Commands row runs it, and
		-- only while the block names it as `next` among the commands it offers.
		if not isPlotroom(cx, pane) then
			cx:toast("error", "Plotroom: link did not come from a Plotroom block")
			return true
		end
		local a = paletteOf(cx, pane)
		if not a then
			return true -- paletteOf toasted
		end
		local listed = false
		for _, c in if type(a.commands) == "table" then a.commands else {} do
			listed = listed or (type(c) == "table" and c.id == a.next)
		end
		for _, c in flows.COMMANDS do
			if listed and c.id == a.next then
				usage.bump("row:" .. c.id)
				c.run(cx, pane)
				return true
			end
		end
		cx:toast("info", "Plotroom: that move is no longer offered here")
		return true
	end
	local wtn = if string.sub(url, 1, #WTOPEN_PREFIX) == WTOPEN_PREFIX then string.match(url, "^plotroom://worktrees/open/(%d+)$") else nil
	if url == "plotroom://more" or string.sub(url, 1, #WTOPEN_PREFIX) == WTOPEN_PREFIX then
		local row = tonumber(wtn)
		if not isPlotroom(cx, pane) then
			cx:toast("error", "Plotroom: link did not come from a Plotroom block")
		elseif url == "plotroom://more" then
			if nodeProp(readNode(cx, pane, MORE_NODE), "href") ~= url then
				cx:toast("error", "Plotroom: Commands are not offered here")
			else
				palette(cx, pane)
			end
		elseif not row or row < 1 or row > 100000 then
			cx:toast("error", "Plotroom: malformed link")
		else
			flows.openWorktree(cx, pane, full, row)
		end
		return true
	end
	local index, target = parseCheck(url)
	if index and target then
		if not isPlotroom(cx, pane) then
			cx:toast("error", "Plotroom: link did not come from a Plotroom block")
		elseif not checkListed(cx, pane, index, url) then
			cx:toast("error", "Plotroom: that check is no longer listed", "Refresh and try again.")
		else
			openUrl(cx, pane, target)
		end
		return true
	end
	local issueOpen = string.match(url, "^plotroom://issue/open/(.+)$")
	if issueOpen then
		local page = unpct(issueOpen)
		if string.sub(page, 1, 8) ~= "https://" or string.find(page, "[%c%s]") then
			cx:toast("error", "Plotroom: malformed link")
		elseif not isPlotroom(cx, pane) then
			cx:toast("error", "Plotroom: link did not come from a Plotroom block")
		elseif nodeProp(readNode(cx, pane, OPEN_NODE), "href") ~= full and not noteListed(cx, pane, url) then
			cx:toast("error", "Plotroom: that issue is no longer listed", "Refresh and try again.")
		else
			openUrl(cx, pane, page)
		end
		return true
	end
	if string.sub(url, 1, 15) == "plotroom://issu" then
		local repo, ref, rid2 = string.match(url, "^plotroom://issue/run/(.+)/([%w_%-]+)/(%w+)$")
		local act: string? = if rid2 then "run" else nil
		if not act then
			act, repo, ref = string.match(url, "^plotroom://issue/(%a+)/(.+)/([%w_%-]+)$")
		end
		if not act or not VALID_ACTS[act] or (act == "run" and not rid2) or not repo or not ref or not worktree.validProject(repo) or #ref > 64 then
			cx:toast("error", "Plotroom: malformed link")
			return true
		end
		if not isPlotroom(cx, pane) then
			cx:toast("error", "Plotroom: link did not come from a Plotroom block")
			return true
		end
		local node = nodeOf(act, rid2)
		if nodeProp(readNode(cx, pane, node), "href") ~= full then
			cx:toast("error", "Plotroom: that issue is no longer listed", "Refresh and try again.")
			return true
		end
		local t = issueTarget(repo, ref)
		if act == "goto" then
			gotoTarget(cx, pane, t)
		elseif AGENT_CMD[act] then
			flows.agentCommand(cx, pane, string.lower(t.repo) .. "#" .. t.ref, act)
		elseif act == "agentgo" then
			flows.goAgent(cx, pane, string.lower(t.repo) .. "#" .. t.ref)
		elseif act == "agent" then
			if typed then
				typePrompt(cx, pane, t)
			else
				pickAgent(cx, pane, t)
			end
		elseif act == "run" and rid2 then
			runSaved(cx, pane, t, rid2)
		else
			prepareTarget(cx, pane, t, nil, true)
		end
		return true
	end
	local kind, owner, repo, n, id = parseLink(url)
	if not kind or not owner or not repo or not n then
		cx:toast("error", "Plotroom: malformed link")
		return true
	end
	if not isPlotroom(cx, pane) then
		cx:toast("error", "Plotroom: link did not come from a Plotroom block")
		return true
	end
	local node = nodeOf(kind, id)
	local present = if kind == "show" then linkedListed(cx, pane, url) else nodeProp(readNode(cx, pane, node), "href") == full
	if not present then
		cx:toast("error", "Plotroom: that pull request is no longer listed", "Refresh and try again.")
		return true
	end
	local t = prTarget(owner, repo, n)
	local page = "https://github.com/" .. owner .. "/" .. repo .. "/pull/" .. n
	if kind == "open" then
		openUrl(cx, pane, page)
	elseif kind == "show" then
		showPr(cx, pane, page)
	elseif kind == "goto" then
		gotoTarget(cx, pane, t)
	elseif AGENT_CMD[kind] then
		flows.agentCommand(cx, pane, string.lower(t.repo) .. "#" .. t.ref, kind)
	elseif kind == "agentgo" then
		flows.goAgent(cx, pane, string.lower(t.repo) .. "#" .. t.ref)
	elseif kind == "agent" then
		if typed then
			typePrompt(cx, pane, t)
		else
			pickAgent(cx, pane, t)
		end
	elseif kind == "run" and id then
		runSaved(cx, pane, t, id)
	else
		prepareTarget(cx, pane, t, nil, true)
	end
	return true
end

-- Follows the hidden link node `nodeId` of `pane` (`typed`: as handle's).
function follow(cx: WindowCx, pane: number, nodeId: string, missing: string?, typed: boolean?)
	local href = nodeProp(readNode(cx, pane, nodeId), "href")
	if type(href) ~= "string" then
		return cx:toast("info", missing or "Nothing is selected")
	end
	handle(cx, href, pane, typed)
end

local function selected(cx: WindowCx, nodeId: string, missing: string?)
	local pane = cx.session:focused()
	if not pane or not isPlotroom(cx, pane) then
		return cx:toast("error", "Focus a Plotroom block first")
	end
	follow(cx, pane, nodeId, missing)
end

tern.route.link(function(link: LinkRequest, cx: WindowCx): RouteDecision?
	if string.sub(link.url, 1, #SCHEME) ~= SCHEME then
		return nil
	end
	handle(cx, link.url, link.pane)
	return { handled = true }
end)

-- A closed pane may have held a PR's worktree, and the host hears no event for it: nudge this window's Plotroom
-- blocks so their "In tab" marks follow (the host renders after any event).
tern.on("pane_closed", function(_ev: any, cx: WindowCx)
	flows.agentSync(cx)
	for _, p in cx.session:panes() do
		if isPlotroom(cx, p.pane) then
			pcall(function()
				cx.session:event(p.pane, { ev = "action", act = "redraw" })
			end)
		end
	end
	checkProtocol(cx)
end)

-- A Plotroom block beside the focused pane, or in a tab of its own when none is focused; `folder` (the Files pane's
-- folder) is its starting folder instead of the focused pane's working directory. The block's host saves a checkout for
-- the repository of that folder when none is saved yet (host.luau: it never replaces a saved one), as for any launch there.
local function launchPane(cx: WindowCx, folder: string?): number?
	local source = cx.session:focused()
	local cwd: string? = folder
	if not cwd and source then
		local info = cx.session:pane(source)
		if info and info.cwd and info.cwd ~= "" then
			cwd = info.cwd
		end
	end
	local spec: Launch = { block = PRS_BLOCK, cwd = cwd, args = if cwd then { cwd } else nil }
	local pane = if source then cx.layout:split(source, "right", spec) else cx.layout:new_tab(spec)
	if not pane then
		cx:toast("error", "Plotroom is not loaded on this host")
	end
	return pane
end

local function launch(cx: WindowCx)
	launchPane(cx)
end

-- Files pane header button: Plotroom beside it, on the folder it shows. The new block runs on the host of the focused pane,
-- so a folder on another host is refused (a path of one host means nothing on the other). Nothing else is set up from it.
tern.files.button({
	id = "open-plotroom",
	title = "Open Plotroom",
	icon = "merge",
	run = function(files: FilesInfo, cx: WindowCx)
		local folder: string? = files.root
		if folder and (folder == "" or #folder > 4096 or string.find(folder, "%c")) then
			return cx:toast("error", "Plotroom not opened", "The folder's path is not usable.")
		end
		if folder and files.host ~= "" then
			local focused = cx.session:focused()
			local hosts = flows.hostsOf(cx)
			local name: string? = nil
			if focused and hosts then
				for _, h in hosts do
					if type(h.panes) == "table" and table.find(h.panes, focused) then
						if files.host == h.name or files.host == h.address or (h.kind == "local" and files.host == "local") then
							name = files.host
						end
					end
				end
			end
			if not name then
				return cx:toast("error", "Plotroom not opened", "Files shows a folder on " .. files.host .. ". Focus a pane on that host first.")
			end
		end
		launchPane(cx, folder)
	end,
})

command({
	id = "open",
	title = "Plotroom: Open",
	icon = "merge",
	run = launch,
})

-- Tern's palette lists only the entry points and cross-pane commands (Open, Open item by URL, Message an agent with
-- the selection…, Go to the first agent that needs input); every other command stays runnable by its action name
-- (`plugin.plotroom.<id>`: key binds, `tern ctl plugins run`) and is offered inside the block by Commands (`.`).
local function hidden(_cx: WindowCx): boolean
	return false
end

local drive: (WindowCx) -> () -- starts the chain steps due (flows.dueSteps); set below, by startStep

flows.setup({
	ask = ask,
	isPlotroom = isPlotroom,
	readNode = readNode,
	nodeProp = nodeProp,
	sourceSession = sourceSession,
	targetPane = targetPane,
	launch = launchPane,
	follow = follow,
	titles = TITLES,
	drive = function(cx: WindowCx)
		drive(cx)
	end,
})

for _, c in flows.COMMANDS do
	command({
		id = c.id,
		title = c.title,
		icon = "merge",
		available = if c.anywhere then nil else hidden,
		run = function(cx: WindowCx)
			local pane = cx.session:focused()
			if c.anywhere then
				return c.run(cx, pane or 0) -- 0: no block; the command finds or launches its own
			elseif not pane or not isPlotroom(cx, pane) then
				return cx:toast("error", "Focus a Plotroom block first")
			end
			c.run(cx, pane)
		end,
	})
end

-- The agents' status timer: running while a Plotroom block and a link exist; kv holds the links, so a plugin VM
-- reboot only needs the next of these to start it again.
tern.on("window_start", function(cx: WindowCx)
	flows.ensureSync(cx)
	checkProtocol(cx)
end)

-- A plugin reload fires no lifecycle event (see `arm(0)`): a live linked agent's timer starts again from here.
tern.timer(0, function(cx: WindowCx?)
	if cx then
		flows.ensureSync(cx)
	end
end)

-- Fires for every kind of block: the agents' timer may need starting whatever opened, but only a new Plotroom block
-- is worth a surface read (a protocol check), so a shell, file or Browser block opening costs no more than that.
tern.on("pane_created", function(ev: any, cx: WindowCx)
	flows.ensureSync(cx)
	if type(ev) ~= "table" or type(ev.pane) ~= "number" or isPlotroom(cx, ev.pane) then
		checkProtocol(cx)
	end
end)

-- Tern holds its state while it dispatches an agent event, so that handler reads nothing (no agents list, no surface):
-- it only queues one sync for the next frame (a timer of 0 ms, with a fresh cx), which several events share.
local syncQueued = false
local function syncSoon()
	if not syncQueued then
		syncQueued = true
		tern.timer(0, function(cx: WindowCx?)
			syncQueued = false
			if cx then
				flows.agentSync(cx)
				flows.ensureSync(cx)
			end
		end)
	end
end

-- A linked agent changed state (finished a turn, began waiting for input): tell the blocks now, not at the next tick.
-- The 4 s timer stays for what no event carries (an agent's last message, a delivery error) and for a reloaded host.
tern.on("agent_state", function(ev: any, _cx: WindowCx)
	if type(ev) == "table" and type(ev.pane) == "number" then
		syncSoon()
	end
end)

-- One of this plugin's own hooks was paused for running over its budget (Tern resumes it by itself): say so, since
-- the agents' status and the blocks' links wait while it is paused.
tern.on("budget", function(ev: any, cx: WindowCx?)
	if type(ev) ~= "table" or type(ev.hook) ~= "string" then
		return
	end
	if ev.state == "paused" then
		local first = next(pausedHooks) == nil
		pausedHooks[ev.hook] = true
		if first and cx then
			cx:toast("error", "Plotroom paused: " .. ev.hook, "It ran over its time budget" .. (if type(ev.paused_ms) == "number" then "; back in " .. math.ceil(ev.paused_ms / 1000) .. " s" else "") .. ".")
		end
	elseif ev.state == "resumed" then
		pausedHooks[ev.hook] = nil
		if cx and next(pausedHooks) == nil then
			cx:toast("info", "Plotroom resumed")
			syncSoon()
		end
	else
		return
	end
	tern.chrome.refresh()
end)

-- Starts a chain step flows.dueSteps made due, as a new agent from Plotroom block `s.block`, in the tab the run it
-- follows ran in: its check (the checker action on the same item, with the run's saved criteria and the fixed check
-- contract; it starts neither a checker nor a next action of its own: its verdict goes to the run it checks), its next
-- action (an issue action's `prs:<id>` runs on the pull request of the worktree's branch in the code repository), or a
-- fix round (the same action again, with the run's saved criteria and the findings as `{findings}`). A start that fails
-- on the way tells flows (startFailed), which counts it and tries again; a chain past MAX_CHAIN ends with a toast.
local function startStep(cx: WindowCx, s: flows.Step)
	local chain = s.chain
	local t: Target
	if chain.kind == "pr" then
		local owner, name = string.match(chain.repo, "^([^/]+)/([^/]+)$")
		t = prTarget(owner or "", name or "", tonumber(chain.ref) or 0)
	else
		t = issueTarget(chain.repo, chain.ref)
	end
	local label = if chain.name ~= "" then chain.name else "the action"
	local what = if s.step == "check" then "Check" elseif s.step == "fix" then "Fix round" else "Next action"
	local title = what .. " not started after " .. label .. " for " .. t.label
	if s.depth >= flows.MAX_CHAIN then
		flows.endStep(s)
		return cx:toast("info", title, "A chain of actions stops after " .. flows.MAX_CHAIN .. ".")
	end
	local function failed(cx2: WindowCx, why: string?)
		flows.startFailed(s)
		if why then
			cx2:toast("error", title, why)
		end
	end
	local tab = cx.session:tab_of(s.agent)
	local function start(cx2: WindowCx, a: any, target: Target, id: string)
		local check = s.step == "check"
		prepareTarget(cx2, s.block, target, {
			text = a.send,
			model = if type(a.model) == "string" then a.model else nil,
			split = a.split == true,
			status = if not check and type(a.status) == "string" then a.status else nil,
			id = id,
			name = if type(a.label) == "string" then a.label else nil,
			next = if not check and type(a.next) == "string" then a.next else nil,
			outcome = if type(a.outcome) == "string" then a.outcome else nil,
			checker = if not check and type(a.checker) == "string" then a.checker else nil,
			depth = s.depth,
			tab = tab,
			criteria = if s.step == "next" then nil else s.criteria or "",
			check = if check then { agent = s.agent, started = s.started, commit = s.commit or "", action = label } else nil,
			findings = if s.step == "fix" then s.findings else nil,
			from = s,
			fail = failed,
		}, a.worktree ~= false, if chain.kind == "issue" and chain.code then { target = chain.code } else {})
	end
	local pid = (if s.step == "check" then chain.checker elseif s.step == "fix" then chain.action else chain.next) :: string
	-- An issue action's `prs:<id>` next: the pull request on the worktree's branch in the code repository is the item.
	local prAction = if s.step == "next" and chain.kind == "issue" then string.match(pid, "^prs:(.+)$") else nil
	local sent: boolean
	if prAction then
		local code, branch = chain.code, chain.branch
		if not branch or not code then
			flows.endStep(s)
			return cx:toast("error", title, "The agent did not run in a worktree, so no pull request can be found for its branch.")
		end
		local owner, name = string.match(code, "^([^/]+)/([^/]+)$")
		sent = ask(cx, s.block, "action", { kind = "pr", pid = prAction, repo = code, branch = branch }, PREPARE_MS, function(a: any, cx2: WindowCx)
			if type(a.send) ~= "string" or type(a.pr) ~= "number" or not owner or not name then
				return failed(cx2, if type(a.problem) == "string" then a.problem else "The action is gone.")
			end
			start(cx2, a, prTarget(owner, name, a.pr), prAction)
		end)
	else
		sent = ask(cx, s.block, "action", { kind = chain.kind, pid = pid }, MENU_MS, function(a: any, cx2: WindowCx)
			if type(a.send) ~= "string" then
				return failed(cx2, if type(a.problem) == "string" then a.problem else "The action is gone.")
			end
			start(cx2, a, t, pid)
		end)
	end
	if not sent then
		failed(cx)
	end
end

drive = function(cx: WindowCx)
	for _, s in flows.dueSteps(cx) do
		startStep(cx, s)
	end
end

tern.on("agent_finished", function(ev: any, cx: WindowCx)
	if type(ev) == "table" and type(ev.pane) == "number" and type(ev.result) == "string" then
		flows.recordResult(cx, ev.pane, ev.result)
	end
	flows.agentSync(cx)
	drive(cx)
end)

tern.on("focus", function(_ev: any, cx: WindowCx)
	checkProtocol(cx)
end)

command({
	id = "open-selected",
	title = "Plotroom: Open the selected PR or issue in Browser",
	icon = "merge",
	available = hidden,
	run = function(cx: WindowCx)
		selected(cx, OPEN_NODE)
	end,
})

command({
	id = "worktree-selected",
	title = "Plotroom: Open the selected PR or issue in a worktree",
	icon = "merge",
	available = hidden,
	run = function(cx: WindowCx)
		selected(cx, WORKTREE_NODE)
	end,
})

command({
	id = "goto-selected",
	title = "Plotroom: Go to the selected PR or issue's tab",
	icon = "merge",
	available = hidden,
	run = function(cx: WindowCx)
		selected(cx, GOTO_NODE, "The selected pull request has no open tab")
	end,
})

command({
	id = "agent-selected",
	title = "Plotroom: Run an agent on the selected PR or issue",
	icon = "merge",
	available = hidden,
	run = function(cx: WindowCx)
		selected(cx, AGENT_NODE)
	end,
})

if tern.getenv("PLOTROOM_SELFTEST") == "1" then
	tern.command({
		id = "selftest",
		title = "Plotroom: Self-test",
		run = function(cx: WindowCx)
			require("./tests/check").run()
			cx:toast("success", "Plotroom self-test passed")
		end,
	})
	tern.command({
		id = "smoke",
		title = "Plotroom: Worktree smoke",
		run = function(cx: WindowCx)
			require("./tests/runtime").run(cx)
		end,
	})
end
