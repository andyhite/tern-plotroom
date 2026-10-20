--!strict
-- The window half: opening Plotroom, validated PR links (Browser block, worktree tab, the PR's open tab, an agent
-- running a saved or typed prompt) and their keyboard-accessible palette commands.
-- This half runs on the machine showing the window; the block may run on a remote host. Whatever touches the checkout
-- or the saved prompts (git, gh, omp, kv) is asked of the block's host half (host/requests.luau);
-- this half only asks the user and arranges tabs.

local worktree = require("./worktree")
local flows = require("./flows")

local PRS_BLOCK = "plotroom.prs"
local ISSUE_ICON = "list-checks"
local SCHEME = "plotroom://"
local OPEN_NODE = "layer.queue.buttons.open"
local WORKTREE_NODE = "layer.queue.buttons.worktree"
local LINKED_NODE = "layer.queue.linked" -- the issue sidebar's linked pull requests; ".pr<i>" follows
-- The lists a check row can sit in (required, the others); ".run<i>" follows.
local CHECK_LISTS = { "layer.queue.required", "layer.queue.runs" }
local GOTO_NODE = "layer.queue.buttons.goto"
local AGENT_NODE = "layer.queue.buttons.agent" -- hidden: the `a` key's and palette command's link
local AGENTGO_NODE = "layer.queue.buttons.agentgo" -- hidden: Go to the item's recorded agent
local BUTTONS_PREFIX = "layer.queue.buttons." -- .. agentint | agentstop | agentmsg: the hidden links of the agent commands
local AGENT_CMD = { agentint = true, agentstop = true, agentmsg = true } -- Interrupt, Stop, Message
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
local PROTOCOL = "26" -- what host/core's RPC_PROTOCOL, shown by host/render's `main.rpc` node, must say
-- A clone for a checkout asked in the palette may run this long (longer than github.luau's CLONE_MS).
local CLONE_WAIT_MS = 11 * 60 * 1000
local RECENT_CAP = 5

local function strOf(v: any): string?
	return if type(v) == "string" then v else nil
end

-- A worktree the host prepared, as its answer says.
type Ready = { path: string, created: boolean, current: boolean, dirty: boolean?, summary: string, setup: string? }
-- What a link acts on: a PR (ref = its number) or an issue (ref = its tracker key). `tab` names its worktree's tab.
type Target = { kind: "pr" | "issue", repo: string, ref: string, label: string, tab: string }
-- A prompt to run: its text, the model omp runs it with (`omp --model`; nil: the agent command's default), and
-- whether its agent opens beside the queue in the queue's tab (`split`) rather than in a tab of its own. A saved action
-- also has its `id` and `name`, and `next`, the saved action to start when its agent finishes; `depth` counts the actions
-- chained before it and `tab` is the tab the previous one ran in, which the next one joins.
type Job = { text: string, model: string?, split: boolean?, status: string?, id: string?, name: string?, next: string?, depth: number?, tab: number? }
local MAX_CHAIN = 8 -- actions in one chain; Settings refuses loops, this stops one that got into the store anyway

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
	if not ok then
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
	if (kind ~= "open" and kind ~= "worktree" and kind ~= "goto" and kind ~= "agent" and kind ~= "agentgo" and not AGENT_CMD[kind or ""] and kind ~= "show" and kind ~= "run") or not owner or not repo or not worktree.validSegment(owner) or not worktree.validSegment(repo) then
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

-- Opens `url` beside `pane` as a plain link open would. Not `cx.browser`'s `open`: its `owner` is in the window's
-- global block ids, and a remote host's pane ids reach Luau translated, so it answers "no block" for a remote pane.
local function openUrl(cx: WindowCx, pane: number, url: string)
	cx.layout:focus(pane)
	cx:open(url, "beside")
end

-- Shows the pull request at `url` in `pane`, the Plotroom block the link came from (host/requests' `show`).
local function showPr(cx: WindowCx, pane: number, url: string)
	cx.session:event(pane, { ev = "action", act = "show-pr", value = url })
	cx.layout:focus(pane)
end

-- Whether the block in `pane` speaks this window's protocol; says so when it does not.
local function sameVersion(cx: WindowCx, pane: number): boolean
	if nodeProp(readNode(cx, pane, "main.rpc"), "text") == PROTOCOL then
		return true
	end
	cx:toast("error", "Plotroom on this block's host is another version", "Install this version there (tern plugin install), then open the block again.")
	return false
end

-- The focused Plotroom block's host announcing another protocol, as a status-line warning. Polled while that block is
-- focused (a remote reload changes the announcement either way); a missing marker is a host still loading, not a mismatch.
local WATCH_MS = 2000
local mismatched: number? = nil -- the focused pane whose host announces another protocol
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
	local flagged: number? = nil
	if pane and isPlotroom(cx, pane) then
		arm(WATCH_MS)
		local text = nodeProp(readNode(cx, pane, "main.rpc"), "text")
		if type(text) == "string" and text ~= PROTOCOL then
			flagged = pane
		end
	elseif watch then
		watch:cancel()
		watch = nil
	end
	if flagged ~= mismatched then
		mismatched = flagged
		tern.chrome.refresh()
	end
end

-- A plugin reload while a Plotroom block is focused fires no lifecycle event: start with a check of our own.
arm(0)

tern.chrome.status(function(pane: StatusPaneInfo): { StatusSegment }?
	if pane.pane ~= mismatched then
		return nil
	end
	return { { text = "Plotroom protocol mismatch", icon = "warning", tone = "error" } }
end)

local answered: (WindowCx, string) -> ()

-- Asks the host half of the Plotroom block in `pane` to run `op`, where the block runs. done(answer, cx) runs once,
-- with the decoded answer, when the host announces it (plotroom://rpc/<id>); with no answer within `ms`, a toast says
-- so instead. False when nothing was sent.
local function ask(cx: WindowCx, pane: number, op: string, args: { [string]: any }, ms: number, done: (any, WindowCx) -> ()): boolean
	if not sameVersion(cx, pane) then
		return false
	end
	requests += 1
	local id = string.format("q%dt%d", requests, math.floor(tern.now()))
	args.id, args.op = id, op
	local timer = tern.timer(ms, function(cx2: WindowCx?)
		if pending[id] then
			pending[id] = nil
			if cx2 then
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
	if r.setup then
		cx:run(newPane, r.setup .. "\r")
	end
	cx:toast(level, "Worktree ready for " .. t.label, if r.setup then r.summary .. " · running setup" else r.summary)
end

-- Starts an agent at `r.path` with `prompt`, as `omp --model <model>` when the prompt names one. `split`: as a block
-- beside the queue (pane `pane`), in its tab. Else `join` (a worktree): in the target's open tab when there is one,
-- else in a new tab. Not `join` (the main checkout): a new tab. A new worktree's setup commands run first in a shell
-- tab, which a `join` agent joins. ponytail: the agent starts without waiting for the setup commands; poll the
-- shell's `last` status if agents trip over a half-done setup.
local function finishAgent(cx: WindowCx, pane: number, t: Target, r: Ready, prompt: string, job: Job, join: boolean, info: flows.AgentInfo)
	local model, split = job.model, job.split == true
	local named = if job.id then job.name else nil -- a typed prompt has no name to show
	if model and not worktree.validModel(model) then
		return cx:toast("error", "Agent not started for " .. t.label, "The action's model is not one omp takes: " .. model)
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
		return cx:toast("success", if join then "Worktree ready" else "Checkout ready", path .. " (the source pane closed, so no agent was started)")
	end
	cx.sessions:switch(session)
	local setup = if join then r.setup else nil
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
	local ok, agent = pcall(function()
		-- Omitted, the command is the agent setting's (omp); a model needs its own command line.
		return cx.agents:start({ prompt = prompt, cwd = path, how = "tab", command = if model then "omp --model " .. model else nil })
	end)
	if not ok or type(agent) ~= "number" then
		return cx:toast("error", "Could not start an agent for " .. t.label, tostring(agent))
	end
	local chain: any = nil
	if job.id then
		chain = { action = job.id, name = job.name or "", next = job.next, kind = t.kind, repo = t.repo, ref = t.ref, depth = job.depth or 0, code = info.code, branch = info.branch }
	end
	flows.recordAgent(cx, pane, string.lower(t.repo) .. "#" .. t.ref, agent, chain, info)
	if split then
		if cx.layout:move(agent, pane, "right") then
			return cx:toast("success", "Agent started beside the queue for " .. t.label, named)
		end
		nameTab(cx, agent, t)
		return cx:toast("info", "Agent started in a new tab for " .. t.label, "It could not open beside the queue.")
	end
	if tab then
		local moved, why = cx.layout:move_to_tab(agent, tab)
		if moved then
			return cx:toast("success", "Agent started in the tab of " .. t.label, named)
		end
		nameTab(cx, agent, t)
		return cx:toast("info", "Agent started in a new tab for " .. t.label, "It could not join the tab: " .. (why or "unknown reason"))
	end
	nameTab(cx, agent, t)
	cx:toast("success", "Agent started for " .. t.label, named)
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
	}
end

-- A `{name}` variable in a prompt: letters, dots between words (`{github.user}`), as tracker.VAR spells it.
local VAR = "{([%a%.]+)}"

-- `{name}` variables a prompt may use, from the PR's coordinates and the host's fresh read of it; others stay as typed.
local function fill(prompt: string, owner: string, repo: string, n: number, a: any): string
	local vars: { [string]: string } = {
		url = "https://github.com/" .. owner .. "/" .. repo .. "/pull/" .. n,
		owner = owner,
		repo = repo,
		number = tostring(n),
	}
	for _, k in { "title", "author", "branch", "base", "remote", "github.user" } do
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
	local function done(a: any, cx2: WindowCx)
		if a.busy == true then
			return cx2:toast("info", "A worktree for " .. t.label .. " is already being prepared")
		elseif type(a.needCheckout) == "string" then
			local repo: string = a.needCheckout
			cx2:prompt({ placeholder = "Folder of your checkout of " .. repo .. " (a new or empty folder gets a clone)", icon = "merge", action = "save" }):next(function(text, _, cx3)
				if not cx3 or not text or not string.find(text, "%S") then
					return
				end
				ask(cx3, pane, "checkout", { repo = repo, path = text }, CLONE_WAIT_MS, function(b: any, cx4: WindowCx)
					if b.ok == true then
						cx4:toast("success", if b.cloned == true then "Cloned " .. repo else "Checkout saved", if type(b.root) == "string" then b.root else nil)
						return again(cx4, {})
					end
					cx4:toast("error", "Checkout not saved", if type(b.problem) == "string" then b.problem else "The block's host could not save it")
				end)
			end)
			return
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
			return cx2:toast("error", "Worktree failed", if type(a.problem) == "string" then a.problem else "The block's host gave no worktree")
		end
		local ready: Ready = r
		afterReady(cx2, ready, function()
			if not prompt then
				finishWorktree(cx2, pane, t, ready)
			elseif t.kind == "pr" then
				local owner, name = string.match(t.repo, "^([^/]+)/([^/]+)$")
				finishAgent(cx2, pane, t, ready, fill(prompt.text, owner or "", name or "", tonumber(t.ref) :: number, a), prompt, wt, { action = prompt.name, branch = strOf(a.branch), title = strOf(a.title) })
			else
				local vars: any = a.vars
				finishAgent(cx2, pane, t, ready, fillVars(prompt.text, vars), prompt, wt, { action = prompt.name, branch = if type(vars) == "table" then strOf(vars.branch) else nil, title = if type(vars) == "table" then strOf(vars.title) else nil, code = strOf(a.code) })
				if prompt.status then
					moveStatus(cx2, pane, t, prompt.status)
				end
			end
		end)
	end
	-- The users cost the host a gh (or acli) call, so they are asked for only when the prompt names one.
	local users = prompt ~= nil and (string.find(prompt.text, "{github.user}", 1, true) ~= nil or string.find(prompt.text, "{jira.user}", 1, true) ~= nil)
	local m: Settled = more or {}
	local sent = if t.kind == "pr"
		then ask(cx, pane, "worktree", { repo = t.repo, number = tonumber(t.ref), worktree = wt, users = users }, PREPARE_MS, done)
		else ask(cx, pane, "issue", { repo = t.repo, ref = t.ref, worktree = wt, target = m.target, pr = m.pr, fresh = m.fresh, base = m.base, users = users }, PREPARE_MS, done)
	if sent and wt and not more then
		cx:toast("info", "Preparing worktree for " .. t.label)
	end
end

-- A run link's saved prompt `id`: the block's host says what it is now, and only one it still offers runs.
local function runSaved(cx: WindowCx, pane: number, t: Target, id: string)
	ask(cx, pane, "menu", { only = id }, MENU_MS, function(a: any, cx2: WindowCx)
		for _, it in if type(a.items) == "table" then a.items else {} do
			if type(it) == "table" and it.id == id and type(it.send) == "string" then
				return prepareTarget(cx2, pane, t, { text = it.send, model = if type(it.model) == "string" then it.model else nil, split = it.split == true, status = if type(it.status) == "string" then it.status else nil, id = id, name = if type(it.label) == "string" then it.label else nil, next = if type(it.next) == "string" then it.next else nil }, it.worktree ~= false)
			end
		end
		cx2:toast("error", "That action is no longer offered here", if type(a.problem) == "string" then a.problem else "Refresh and try again.")
	end)
end

-- Asks for a prompt's text and runs it on the target in an agent in its worktree.
local function typePrompt(cx: WindowCx, pane: number, t: Target)
	cx:prompt({ placeholder = "Prompt for an agent on " .. t.label, icon = "merge", action = "send" }):next(function(text, _, cx2)
		if cx2 and text and string.find(text, "%S") then
			prepareTarget(cx2, pane, t, { text = text, name = "Typed prompt" }, true)
		end
	end)
end

-- Asks which saved prompt (Settings › Prompts, those the block's view offers) to run on the target, then
-- runs it in an agent where the prompt says (its worktree or the main checkout). "Type a prompt…" sends typed text
-- to the worktree.
local function pickMenu(cx: WindowCx, pane: number, t: Target)
	local function run(cx2: WindowCx, job: Job, wt: boolean)
		prepareTarget(cx2, pane, t, job, wt)
	end
	ask(cx, pane, "menu", {}, MENU_MS, function(a: any, cx2: WindowCx)
		if type(a.problem) == "string" then
			cx2:toast("error", "Saved actions are not listed", a.problem)
		end
		local all: { PickItem } = {}
		for _, it in if type(a.items) == "table" then a.items else {} do
			if type(it) == "table" and type(it.label) == "string" and type(it.send) == "string" then
				table.insert(all, {
					label = it.label,
					detail = if type(it.detail) == "string" then it.detail else nil,
					group = if type(it.group) == "string" then it.group else nil,
					send = it.send,
					model = if type(it.model) == "string" then it.model else nil,
					status = if type(it.status) == "string" then it.status else nil,
					id = if type(it.id) == "string" then it.id else nil,
					next = if type(it.next) == "string" then it.next else nil,
					worktree = it.worktree ~= false,
					split = it.split == true,
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
		cx2:pick({ items = items, placeholder = "Run on " .. t.label, icon = "merge", action = "run" }):next(function(item, _, cx3)
			if not item or not cx3 then
				return
			end
			if item.typed then
				return typePrompt(cx3, pane, t)
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
			run(cx3, { text = item.send, model = item.model, split = item.split == true, status = item.status, id = item.id, name = item.label, next = item.next }, item.worktree ~= false)
		end)
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
		{ label = "Go to agent (" .. flows.stateLabel(state) .. ")", detail = (if link.chain and link.chain.name ~= "" then link.chain.name .. " · pane " else "Pane ") .. link.agent, go = true },
		{ label = "Start another agent", detail = "Choose an action to run" },
	}
	cx:pick({ items = items, placeholder = "An agent already works on " .. t.label, icon = "merge", action = "choose" }):next(function(item, _, cx2)
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
				local path = if type(it.path) == "string" then it.path else "No local checkout yet"
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

-- Whether a linked pull request row of the pane's live issue sidebar carries exactly `url`.
local function linkedListed(cx: WindowCx, pane: number, url: string): boolean
	local list = readNode(cx, pane, LINKED_NODE)
	for _, row in if type(list) == "table" and type(list.c) == "table" then list.c else {} do
		if nodeProp(row, "href") == url then
			return true
		end
	end
	return false
end

local follow: (cx: WindowCx, pane: number, nodeId: string, missing: string?, typed: boolean?) -> ()

-- The order the palette's groups come in; a group the host names that is not here follows them. The host names the
-- item's own operations by its type (Jira - Issue, GitHub - PR, GitHub - Issue); the provider-only headings (GitHub,
-- Jira) are for what needs no item.
local GROUPS = { "Saved actions", "Jira - Issue", "GitHub - PR", "GitHub - Issue", "Inbox", "Triage", "Filter & Sort", "Views", "Worktree", "GitHub", "Jira", "Configuration" }

-- plotroom://more: the command palette of the Plotroom block `pane`, in groups. Only what applies to the selection now is
-- listed: the host names the queue actions (`queue`, each with its group, key and detail, sent back as its `queue`
-- action) and the flows.COMMANDS ids (`commands`, each with the group the host gives it) it will accept. With an item
-- selected, a typed prompt and the saved actions its view offers form the Saved actions group (each run through its
-- hidden link, as its key runs it); the agent picker is no row of its own.
local function palette(cx: WindowCx, pane: number)
	local hasItem = type(nodeProp(readNode(cx, pane, AGENT_NODE), "href")) == "string"
	ask(cx, pane, "menu", { palette = true }, MENU_MS, function(a: any, cx2: WindowCx)
		if hasItem and type(a.problem) == "string" then
			cx2:toast("error", "Saved actions are not listed", a.problem)
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
			add("Saved actions", { label = "Type a prompt…", detail = "Run your own text in an agent", typed = true })
			for _, it in if type(a.items) == "table" then a.items else {} do
				if type(it) == "table" and type(it.id) == "string" and type(it.label) == "string" then
					add("Saved actions", { label = it.label, detail = keyed(it.key, it.detail), run = it.id })
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
		cx2:pick({ items = items, placeholder = "Run a command", icon = "merge", action = "run" }):next(function(item, _, cx3)
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
					c.run(cx3, pane)
				end
			end
		end)
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
	elseif url == "plotroom://repos" or url == "plotroom://jira-projects" or url == "plotroom://confirm" then
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
	local wtn = if string.sub(url, 1, #WTOPEN_PREFIX) == WTOPEN_PREFIX then string.match(url, "^plotroom://worktrees/open/(%d+)$") else nil
	if url == "plotroom://more" or string.sub(url, 1, #WTOPEN_PREFIX) == WTOPEN_PREFIX then
		local row = tonumber(wtn)
		if not isPlotroom(cx, pane) then
			cx:toast("error", "Plotroom: link did not come from a Plotroom block")
		elseif url == "plotroom://more" then
			if nodeProp(readNode(cx, pane, MORE_NODE), "href") ~= url then
				cx:toast("error", "Plotroom: the command palette is not offered here")
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
		elseif nodeProp(readNode(cx, pane, OPEN_NODE), "href") ~= full then
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
		if not act or (act ~= "worktree" and act ~= "goto" and act ~= "agent" and act ~= "agentgo" and not AGENT_CMD[act or ""] and act ~= "run") or (act == "run" and not rid2) or not repo or not ref or not worktree.validProject(repo) or #ref > 64 then
			cx:toast("error", "Plotroom: malformed link")
			return true
		end
		if not isPlotroom(cx, pane) then
			cx:toast("error", "Plotroom: link did not come from a Plotroom block")
			return true
		end
		local node = if act == "goto" then GOTO_NODE elseif act == "agent" then AGENT_NODE elseif act == "agentgo" then AGENTGO_NODE elseif AGENT_CMD[act] then BUTTONS_PREFIX .. act elseif act == "run" then PROMPT_NODE .. (rid2 or "") else WORKTREE_NODE
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
	local node = if kind == "open"
		then OPEN_NODE
		elseif kind == "goto" then GOTO_NODE
		elseif kind == "agent" then AGENT_NODE
		elseif kind == "agentgo" then AGENTGO_NODE
		elseif AGENT_CMD[kind] then BUTTONS_PREFIX .. kind
		elseif kind == "run" then PROMPT_NODE .. (id or "")
		else WORKTREE_NODE
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

local function launchPane(cx: WindowCx): number?
	local source = cx.session:focused()
	local cwd: string? = nil
	if source then
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

tern.command({
	id = "open",
	title = "Plotroom: Open",
	icon = "merge",
	run = launch,
})

local function available(cx: WindowCx): boolean
	local pane = cx.session:focused()
	return pane ~= nil and isPlotroom(cx, pane)
end

flows.setup({
	ask = ask,
	isPlotroom = isPlotroom,
	readNode = readNode,
	nodeProp = nodeProp,
	sourceSession = sourceSession,
	targetPane = targetPane,
	launch = launchPane,
	follow = follow,
})

for _, c in flows.COMMANDS do
	tern.command({
		id = c.id,
		title = c.title,
		icon = "merge",
		available = if c.anywhere then nil else available,
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

tern.on("pane_created", function(_ev: any, cx: WindowCx)
	flows.ensureSync(cx)
	checkProtocol(cx)
end)

-- A finished agent's next action: starts for the same item, in the tab the agent ran in, when the agent's turn ended "done".
-- Any other result stops the chain, and a toast says why. The link keeps nothing to start afterwards, so another turn of
-- the same agent starts nothing.
local function advanceChain(cx: WindowCx, agent: number, result: string)
	local chain, pane = flows.takeChain(cx, agent)
	local next = if chain then chain.next else nil
	if not chain or not next then
		return
	elseif not pane then
		return cx:toast("info", "Next action waits for Plotroom", "Open Plotroom on the agent's host; the next time the agent finishes, the action starts.")
	end
	local t: Target
	if chain.kind == "pr" then
		local owner, name = string.match(chain.repo, "^([^/]+)/([^/]+)$")
		t = prTarget(owner or "", name or "", tonumber(chain.ref) or 0)
	else
		t = issueTarget(chain.repo, chain.ref)
	end
	local label = if chain.name ~= "" then chain.name else "the action"
	if result ~= "done" then
		local why = if result == "failed" then "The agent reported a failure." elseif result == "exited" then "The agent's program exited." else "The agent's pane was closed."
		return cx:toast("info", "Next action not started after " .. label .. " for " .. t.label, why)
	elseif chain.depth + 1 >= MAX_CHAIN then
		return cx:toast("info", "Next action not started after " .. label .. " for " .. t.label, "A chain of actions stops after " .. MAX_CHAIN .. ".")
	end
	local tab = cx.session:tab_of(agent)
	-- An issue action's `prs:<id>` next: the pull request on the worktree's branch in the code repository is the item.
	local prAction = if chain.kind == "issue" then string.match(next, "^prs:(.+)$") else nil
	local function start(cx2: WindowCx, a: any, target: Target, id: string)
		prepareTarget(cx2, pane, target, {
			text = a.send,
			model = if type(a.model) == "string" then a.model else nil,
			split = a.split == true,
			status = if type(a.status) == "string" then a.status else nil,
			id = id,
			name = if type(a.label) == "string" then a.label else nil,
			next = if type(a.next) == "string" then a.next else nil,
			depth = chain.depth + 1,
			tab = tab,
		}, a.worktree ~= false, if chain.kind == "issue" and chain.code then { target = chain.code } else {})
	end
	local function stop(cx2: WindowCx, why: string)
		cx2:toast("error", "Next action not started after " .. label .. " for " .. t.label, why)
	end
	if prAction then
		local code, branch = chain.code, chain.branch
		if not branch or not code then
			return stop(cx, "The agent did not run in a worktree, so no pull request can be found for its branch.")
		end
		local owner, name = string.match(code, "^([^/]+)/([^/]+)$")
		ask(cx, pane, "action", { kind = "pr", pid = prAction, repo = code, branch = branch }, PREPARE_MS, function(a: any, cx2: WindowCx)
			if type(a.send) ~= "string" or type(a.pr) ~= "number" or not owner or not name then
				return stop(cx2, if type(a.problem) == "string" then a.problem else "The action is gone.")
			end
			start(cx2, a, prTarget(owner, name, a.pr), prAction)
		end)
		return
	end
	ask(cx, pane, "action", { kind = chain.kind, pid = next }, MENU_MS, function(a: any, cx2: WindowCx)
		if type(a.send) ~= "string" then
			return stop(cx2, if type(a.problem) == "string" then a.problem else "The action is gone.")
		end
		start(cx2, a, t, next)
	end)
end

tern.on("agent_finished", function(ev: any, cx: WindowCx)
	flows.agentSync(cx)
	if type(ev) == "table" and type(ev.pane) == "number" and type(ev.result) == "string" then
		advanceChain(cx, ev.pane, ev.result)
	end
end)

tern.on("focus", function(_ev: any, cx: WindowCx)
	checkProtocol(cx)
end)

tern.command({
	id = "open-selected",
	title = "Plotroom: Open the selected PR or issue in Browser",
	icon = "merge",
	available = available,
	run = function(cx: WindowCx)
		selected(cx, OPEN_NODE)
	end,
})

tern.command({
	id = "worktree-selected",
	title = "Plotroom: Open the selected PR or issue in a worktree",
	icon = "merge",
	available = available,
	run = function(cx: WindowCx)
		selected(cx, WORKTREE_NODE)
	end,
})

tern.command({
	id = "goto-selected",
	title = "Plotroom: Go to the selected PR or issue's tab",
	icon = "merge",
	available = available,
	run = function(cx: WindowCx)
		selected(cx, GOTO_NODE, "The selected pull request has no open tab")
	end,
})

tern.command({
	id = "agent-selected",
	title = "Plotroom: Run an agent on the selected PR or issue",
	icon = "merge",
	available = available,
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
