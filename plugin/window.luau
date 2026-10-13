--!strict
-- The window half: opening Plotroom, validated PR links (Browser block, worktree tab, the PR's open tab, an agent
-- running a saved or typed prompt) and their keyboard-accessible palette commands.
-- This half runs on the machine showing the window; the block may run on a remote host. Whatever touches the checkout
-- or the saved prompts (git, gh, omp, kv) is asked of the block's host half (host.luau, "requests from window.luau");
-- this half only asks the user and arranges tabs. Starting an agent runs omp where project config can run code, so it
-- asks first.

local worktree = require("./worktree")

local BLOCK = "plotroom.prs"
local SCHEME = "plotroom://"
local OPEN_NODE = "layer.queue.buttons.open"
local WORKTREE_NODE = "layer.queue.buttons.worktree"
-- The lists a check row can sit in (required, the others); ".run<i>" follows.
local CHECK_LISTS = { "layer.queue.required", "layer.queue.runs" }
local GOTO_NODE = "layer.queue.buttons.goto"
local AGENT_NODE = "layer.queue.buttons.agent" -- hidden: the `a` key's and palette command's link
local PROMPT_NODE = "layer.queue.buttons.prompt-" -- .. a saved prompt's id: its action-bar button's hidden link
-- How long the block's host may take to answer: listing saved prompts, preparing a worktree (fetch and add, 2 minutes
-- each).
local MENU_MS = 30 * 1000
local PREPARE_MS = 5 * 60 * 1000
local PROTOCOL = "4" -- what host.luau's `main.rpc` node must say
local RECENT_CAP = 5
local RISK = "Project config can run code"

-- A worktree the host prepared, as its answer says.
type Ready = { path: string, created: boolean, current: boolean, dirty: boolean?, summary: string, setup: string? }
-- Requests to a block's host waiting for their answer, by id.
type Pending = { pane: number, done: (any, WindowCx) -> (), timer: TimerHandle }
local pending: { [string]: Pending } = {}
local requests = 0
-- Picker labels chosen last, newest first. Kept in tern.kv: Tern reboots plugin VMs now and then, losing module state.
local RECENT_KEY = "agent-recent"

local function readRecent(): { string }
	local out: { string } = {}
	local ok, v = pcall(tern.kv.get, RECENT_KEY)
	if ok and type(v) == "table" then
		for _, label in v do
			if type(label) == "string" then
				table.insert(out, label)
			end
		end
	end
	return out
end

local function isPlotroom(cx: WindowCx, pane: number): boolean
	local info = cx.session:pane(pane)
	local block = if info then info.block else nil
	return type(block) == "string" and string.sub(block, -#BLOCK) == BLOCK
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

-- `plotroom://github/<open|worktree|goto|agent>/<owner>/<repo>/<n>`, or `…/run/<owner>/<repo>/<n>/<prompt id>`: the kind,
-- the PR, and for `run` the saved prompt's id.
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
	if (kind ~= "open" and kind ~= "worktree" and kind ~= "goto" and kind ~= "agent" and kind ~= "run") or not owner or not repo or not worktree.validSegment(owner) or not worktree.validSegment(repo) then
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

-- A pane in a tab of this window working in PR `repo`#`n`'s Plotroom worktree: pane, tab and session ids.
local function prPane(cx: WindowCx, repo: string, n: number): (number?, number?, number?)
	for _, p in cx.session:panes() do
		if p.tab and worktree.prOfPath(p.cwd or "", repo) == n then
			for _, t in cx.session:tabs() do
				if t.id == p.tab then
					return p.pane, t.id, t.session
				end
			end
		end
	end
	return nil, nil, nil
end

local function gotoPr(cx: WindowCx, repo: string, n: number)
	local pane, _, session = prPane(cx, repo, n)
	if not pane or not session then
		return cx:toast("info", "No tab is open for " .. repo .. "#" .. n)
	end
	cx.sessions:switch(session)
	cx.layout:focus(pane)
end

-- Opens `url` in a Browser block docked right of `pane`.
local function openUrl(cx: WindowCx, pane: number, url: string, what: string)
	cx.browser:call({ op = "open", owner = pane, url = url }):next(function(result, err, cx2)
		if not cx2 then
			return
		end
		if err or not result or result.error or not result.ok then
			local why = err or (if result and result.error then result.error.message else "no result")
			return cx2:toast("error", "Could not open " .. what, why)
		end
		local browserPane = result.ok.block
		if type(browserPane) ~= "number" then
			return cx2:toast("error", "Browser opened but did not report its block", tern.json.encode(result.ok))
		end
		local ok, why = cx2.layout:dock(browserPane, pane, "right", { focus = true })
		if not ok then
			cx2:toast("error", "Could not dock the Browser block", why)
		end
	end)
end

local function openPr(cx: WindowCx, pane: number, owner: string, repo: string, n: number)
	openUrl(cx, pane, "https://github.com/" .. owner .. "/" .. repo .. "/pull/" .. n, "the pull request")
end

-- Asks the host half of the Plotroom block in `pane` to run `op`, where the block runs. done(answer, cx) runs once,
-- with the decoded answer, when the host announces it (plotroom://rpc/<id>); with no answer within `ms`, a toast says
-- so instead. False when nothing was sent.
local function ask(cx: WindowCx, pane: number, op: string, args: { [string]: any }, ms: number, done: (any, WindowCx) -> ()): boolean
	if nodeProp(readNode(cx, pane, "main.rpc"), "text") ~= PROTOCOL then
		cx:toast("error", "Plotroom on this block's host is another version", "Install this version there (tern plugin install), then open the block again.")
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
	end
	return ok
end

-- plotroom://rpc/<id>: the host answered request `id`. Only the window that asked acts, and only on the answer its
-- block shows: a link without one (stale, or not the host's) leaves the request waiting.
local function answered(cx: WindowCx, id: string)
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

-- Names the tab holding `pane` "PR #n · <repo name>".
local function namePrTab(cx: WindowCx, pane: number, repo: string, n: number)
	local tab = cx.session:tab_of(pane)
	if tab then
		cx.layout:name_tab(tab, "PR #" .. n .. " · " .. (string.match(repo, "/(.+)$") or repo))
	end
end

local function finishWorktree(cx: WindowCx, pane: number, repo: string, n: number, r: Ready)
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
	namePrTab(cx, newPane, repo, n)
	if r.setup then
		cx:run(newPane, r.setup .. "\r")
	end
	cx:toast(level, "Worktree ready for " .. repo .. "#" .. n, if r.setup then r.summary .. " · running setup" else r.summary)
end

-- Starts an agent in the worktree with `prompt`: in the PR's open tab when there is one, else in a new tab. A new
-- worktree's setup commands run first in a shell tab the agent joins. ponytail: the agent starts without waiting
-- for them; poll the shell's `last` status if agents trip over a half-done setup.
local function finishAgent(cx: WindowCx, pane: number, repo: string, n: number, r: Ready, prompt: string)
	local path = r.path
	local _, tab, found = prPane(cx, repo, n)
	local session = found or sourceSession(cx, pane)
	if not session then
		return cx:toast("success", "Worktree ready", path .. " (the source pane closed, so no agent was started)")
	end
	cx.sessions:switch(session)
	local setup = r.setup
	if setup then
		local shell = cx.layout:new_tab({ cwd = path })
		if shell then
			cx:run(shell, setup .. "\r")
			namePrTab(cx, shell, repo, n)
			tab = cx.session:tab_of(shell)
		else
			cx:toast("error", "Setup did not run for " .. repo .. "#" .. n, "Its tab did not open.")
		end
	end
	local ok, agent = pcall(function()
		return cx.agents:start({ prompt = prompt, cwd = path, how = "tab" })
	end)
	if not ok or type(agent) ~= "number" then
		return cx:toast("error", "Could not start an agent for " .. repo .. "#" .. n, tostring(agent))
	end
	if tab then
		local moved, why = cx.layout:move_to_tab(agent, tab)
		if moved then
			return cx:toast("success", "Agent started in the tab of " .. repo .. "#" .. n, prompt)
		end
		namePrTab(cx, agent, repo, n)
		return cx:toast("info", "Agent started in a new tab for " .. repo .. "#" .. n, "It could not join the pull request's tab: " .. (why or "unknown reason"))
	end
	namePrTab(cx, agent, repo, n)
	cx:toast("success", "Agent started for " .. repo .. "#" .. n, prompt)
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

-- Consent before omp runs where project config can run code: a native picker whose first row, the one ↵ takes, is
-- Deny. `question` is the short placeholder; `where` (the full path) and `stays` are the rows' details. A dismissed
-- picker, Deny or a callback without a window context ends it; `no` only runs with a context.
local function confirm(cx: WindowCx, question: string, where: string, stays: string, yes: (WindowCx) -> (), no: ((WindowCx) -> ())?)
	local items: { PickItem } = {
		{ label = "Deny", detail = stays, group = RISK },
		{ label = "Allow", detail = where, group = RISK, go = true },
	}
	cx:pick({ items = items, placeholder = question, icon = "merge" }):next(function(item, _, cx2)
		if not cx2 then
			return
		end
		if item and item.go == true then
			return yes(cx2)
		end
		if no then
			no(cx2)
		end
	end)
end

-- With the worktree ready, the agent starts once the user agrees to run omp in that checkout, where project config can
-- run code; setup commands and the agent come after.
local function startAgent(cx: WindowCx, pane: number, repo: string, n: number, r: Ready, prompt: string)
	local question = "Start an agent for " .. repo .. "#" .. n .. "?"
	confirm(cx, question, "Runs omp in " .. r.path, "The worktree stays; no agent starts", function(cx2: WindowCx)
		afterReady(cx2, r, function()
			finishAgent(cx2, pane, repo, n, r, prompt)
		end)
	end, function(cx2: WindowCx)
		cx2:toast("info", "Agent not started for " .. repo .. "#" .. n, "The worktree is ready at " .. r.path)
	end)
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

-- `{name}` variables a prompt may use, from the PR's coordinates and the host's fresh read of it; others stay as typed.
local function fill(prompt: string, owner: string, repo: string, n: number, a: any): string
	local vars: { [string]: string } = {
		url = "https://github.com/" .. owner .. "/" .. repo .. "/pull/" .. n,
		owner = owner,
		repo = repo,
		number = tostring(n),
	}
	for _, k in { "title", "author", "branch", "base" } do
		if type(a[k]) == "string" then
			vars[k] = a[k]
		end
	end
	return (string.gsub(prompt, "{(%a+)}", vars))
end

-- Has the block's host create or reuse the PR's worktree (and note it on the block), then opens its tab, or with
-- `prompt` starts an agent in it, its variables filled.
local function worktreePr(cx: WindowCx, pane: number, owner: string, repo: string, n: number, prompt: string?)
	local full = owner .. "/" .. repo
	local sent = ask(cx, pane, "worktree", { repo = full, number = n }, PREPARE_MS, function(a: any, cx2: WindowCx)
		if a.busy == true then
			return cx2:toast("info", "A worktree for " .. full .. "#" .. n .. " is already being prepared")
		elseif a.noRepo == true then
			return cx2:toast("info", "No local checkout of " .. full, "Enter its path in Plotroom, then try again.")
		end
		local r = readyOf(a)
		if not r then
			return cx2:toast("error", "Worktree failed", if type(a.problem) == "string" then a.problem else "The block's host gave no worktree")
		end
		local ready: Ready = r
		afterReady(cx2, ready, function()
			if prompt then
				startAgent(cx2, pane, full, n, ready, fill(prompt, owner, repo, n, a))
			else
				finishWorktree(cx2, pane, full, n, ready)
			end
		end)
	end)
	if sent then
		cx:toast("info", "Preparing worktree for " .. full .. "#" .. n)
	end
end

-- An action-bar button's saved prompt `id`: the block's host says what it is now, and only one it still offers runs.
local function runSaved(cx: WindowCx, pane: number, owner: string, repo: string, n: number, id: string)
	ask(cx, pane, "menu", { only = id }, MENU_MS, function(a: any, cx2: WindowCx)
		for _, it in if type(a.items) == "table" then a.items else {} do
			if type(it) == "table" and it.id == id and type(it.send) == "string" then
				return worktreePr(cx2, pane, owner, repo, n, it.send)
			end
		end
		cx2:toast("error", "That prompt is no longer offered here", if type(a.problem) == "string" then a.problem else "Refresh and try again.")
	end)
end

-- Asks which saved prompt (Settings › Prompts, those offered under the block's filter) to run on PR `owner/repo#n`,
-- then runs it in an agent in the PR's worktree. "Type a prompt…" sends typed text the same way.
local function pickAgent(cx: WindowCx, pane: number, owner: string, repo: string, n: number)
	local full = owner .. "/" .. repo
	local function run(cx2: WindowCx, text: string)
		worktreePr(cx2, pane, owner, repo, n, text)
	end
	ask(cx, pane, "menu", {}, MENU_MS, function(a: any, cx2: WindowCx)
		if type(a.problem) == "string" then
			cx2:toast("error", "Saved prompts are not listed", a.problem)
		end
		local all: { PickItem } = {}
		for _, it in if type(a.items) == "table" then a.items else {} do
			if type(it) == "table" and type(it.label) == "string" and type(it.send) == "string" then
				table.insert(all, {
					label = it.label,
					detail = if type(it.detail) == "string" then it.detail else nil,
					group = if type(it.group) == "string" then it.group else nil,
					send = it.send,
				})
			end
		end
		local items: { PickItem } = {}
		for _, label in readRecent() do
			for _, c in all do
				if c.label == label then
					local again = table.clone(c)
					again.group = "Recent"
					table.insert(items, again)
					break
				end
			end
		end
		table.insert(items, { label = "Type a prompt…", detail = if #all == 0 then "Save prompts in Settings › Prompts (s)" else "Send your own text", typed = true })
		for _, c in all do
			table.insert(items, c)
		end
		cx2:pick({ items = items, placeholder = "Run on " .. full .. "#" .. n, icon = "merge", action = "run" }):next(function(item, _, cx3)
			if not item or not cx3 then
				return
			end
			if item.typed then
				return cx3:prompt({ placeholder = "Prompt for an agent on " .. full .. "#" .. n, icon = "merge", action = "send" }):next(function(text, _, cx4)
					if cx4 and text and string.find(text, "%S") then
						run(cx4, text)
					end
				end)
			end
			local recent = readRecent()
			local at = table.find(recent, item.label)
			if at then
				table.remove(recent, at)
			end
			table.insert(recent, 1, item.label)
			recent[RECENT_CAP + 1] = nil
			pcall(tern.kv.set, RECENT_KEY, tern.json.array(recent)) -- best effort: a failed write only loses the order
			run(cx3, item.send)
		end)
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

-- Validates a plotroom:// link against the pane's live surface and runs it.
local function handle(cx: WindowCx, url: string, pane: number): boolean
	local rid = string.match(url, "^plotroom://rpc/(%w+)$")
	if rid then
		answered(cx, rid)
		return true
	end
	local index, target = parseCheck(url)
	if index and target then
		if not isPlotroom(cx, pane) then
			cx:toast("error", "Plotroom: link did not come from a Plotroom block")
		elseif not checkListed(cx, pane, index, url) then
			cx:toast("error", "Plotroom: that check is no longer listed", "Refresh and try again.")
		else
			openUrl(cx, pane, target, "the check")
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
		elseif kind == "run" then PROMPT_NODE .. (id or "")
		else WORKTREE_NODE
	local present = nodeProp(readNode(cx, pane, node), "href") == url
	if not present then
		cx:toast("error", "Plotroom: that pull request is no longer listed", "Refresh and try again.")
		return true
	end
	if kind == "open" then
		openPr(cx, pane, owner, repo, n)
	elseif kind == "goto" then
		gotoPr(cx, owner .. "/" .. repo, n)
	elseif kind == "agent" then
		pickAgent(cx, pane, owner, repo, n)
	elseif kind == "run" and id then
		runSaved(cx, pane, owner, repo, n, id)
	else
		worktreePr(cx, pane, owner, repo, n, nil)
	end
	return true
end

local function selected(cx: WindowCx, nodeId: string, missing: string?)
	local pane = cx.session:focused()
	if not pane or not isPlotroom(cx, pane) then
		return cx:toast("error", "Focus a Plotroom block first")
	end
	local href = nodeProp(readNode(cx, pane, nodeId), "href")
	if type(href) ~= "string" then
		return cx:toast("info", missing or "No pull request is selected")
	end
	handle(cx, href, pane)
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
	for _, p in cx.session:panes() do
		if isPlotroom(cx, p.pane) then
			pcall(function()
				cx.session:event(p.pane, { ev = "action", act = "redraw" })
			end)
		end
	end
end)

tern.command({
	id = "open",
	title = "Plotroom: Open GitHub PRs",
	icon = "merge",
	run = function(cx: WindowCx)
		local source = cx.session:focused()
		local cwd: string? = nil
		if source then
			local info = cx.session:pane(source)
			if info and info.cwd and info.cwd ~= "" then
				cwd = info.cwd
			end
		end
		local launch: Launch = { block = BLOCK, cwd = cwd, args = if cwd then { cwd } else nil }
		local pane = if source then cx.layout:split(source, "right", launch) else cx.layout:new_tab(launch)
		if not pane then
			cx:toast("error", "Plotroom is not loaded on this host")
		end
	end,
})

local function available(cx: WindowCx): boolean
	local pane = cx.session:focused()
	return pane ~= nil and isPlotroom(cx, pane)
end

tern.command({
	id = "open-selected",
	title = "Plotroom: Open selected PR in Browser",
	icon = "merge",
	available = available,
	run = function(cx: WindowCx)
		selected(cx, OPEN_NODE)
	end,
})

tern.command({
	id = "worktree-selected",
	title = "Plotroom: Open selected PR in a worktree",
	icon = "merge",
	available = available,
	run = function(cx: WindowCx)
		selected(cx, WORKTREE_NODE)
	end,
})

tern.command({
	id = "goto-selected",
	title = "Plotroom: Go to the selected PR's tab",
	icon = "merge",
	available = available,
	run = function(cx: WindowCx)
		selected(cx, GOTO_NODE, "The selected pull request has no open tab")
	end,
})

tern.command({
	id = "agent-selected",
	title = "Plotroom: Run an agent on the selected PR",
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
