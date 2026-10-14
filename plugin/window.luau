--!strict
-- The window half: opening Plotroom, validated PR links (Browser block, worktree tab, the PR's open tab, an agent
-- running a saved or typed prompt) and their keyboard-accessible palette commands.
-- This half runs on the machine showing the window; the block may run on a remote host. Whatever touches the checkout
-- or the saved prompts (git, gh, omp, kv) is asked of the block's host half (host.luau, "requests from window.luau");
-- this half only asks the user and arranges tabs. Starting an agent runs omp where project config can run code, so it
-- asks first.

local worktree = require("./worktree")

local BLOCKS = { "plotroom.prs", "plotroom.issues" }
local ISSUE_ICON = "circle-dot"
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
-- Listing a gh login's repositories: a token read, then the REST API's pages (30 seconds each at most).
local REPOS_MS = 70 * 1000
local PROTOCOL = "8" -- what host.luau's `main.rpc` node must say
-- A clone for a checkout asked in the palette may run this long (longer than github.luau's CLONE_MS).
local CLONE_WAIT_MS = 11 * 60 * 1000
local RECENT_CAP = 5
local RISK = "Project config can run code"

-- A worktree the host prepared, as its answer says.
type Ready = { path: string, created: boolean, current: boolean, dirty: boolean?, summary: string, setup: string? }
-- What a link acts on: a PR (ref = its number) or an issue (ref = its tracker key). `tab` names its worktree's tab.
type Target = { kind: "pr" | "issue", repo: string, ref: string, label: string, tab: string }

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
	if type(block) ~= "string" then
		return false
	end
	for _, b in BLOCKS do
		if string.sub(block, -#b) == b then
			return true
		end
	end
	return false
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

-- A pane in a tab of this window working in the target's Plotroom worktree: pane, tab and session ids.
local function targetPane(cx: WindowCx, t: Target): (number?, number?, number?)
	local key = string.lower(t.repo) .. "#" .. t.ref
	for _, p in cx.session:panes() do
		local found, what = worktree.itemOfPath(p.cwd or "")
		if p.tab and found == key and what == t.kind then
			for _, tb in cx.session:tabs() do
				if tb.id == p.tab then
					return p.pane, tb.id, tb.session
				end
			end
		end
	end
	return nil, nil, nil
end

local function gotoTarget(cx: WindowCx, t: Target)
	local pane, _, session = targetPane(cx, t)
	if not pane or not session then
		return cx:toast("info", "No tab is open for " .. t.label)
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

-- Starts an agent at `r.path` with `prompt`. `join` (a worktree): in the target's open tab when there is one, else in
-- a new tab, a new worktree's setup commands running first in a shell tab the agent joins. Not `join` (the main
-- checkout): always a new tab, no setup. ponytail: the agent starts without waiting for the setup commands; poll the
-- shell's `last` status if agents trip over a half-done setup.
local function finishAgent(cx: WindowCx, pane: number, t: Target, r: Ready, prompt: string, join: boolean)
	local path = r.path
	local tab: number? = nil
	local found: number? = nil
	if join then
		local _pane
		_pane, tab, found = targetPane(cx, t)
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
			tab = cx.session:tab_of(shell)
		else
			cx:toast("error", "Setup did not run for " .. t.label, "Its tab did not open.")
		end
	end
	local ok, agent = pcall(function()
		return cx.agents:start({ prompt = prompt, cwd = path, how = "tab" })
	end)
	if not ok or type(agent) ~= "number" then
		return cx:toast("error", "Could not start an agent for " .. t.label, tostring(agent))
	end
	if tab then
		local moved, why = cx.layout:move_to_tab(agent, tab)
		if moved then
			return cx:toast("success", "Agent started in the tab of " .. t.label, prompt)
		end
		nameTab(cx, agent, t)
		return cx:toast("info", "Agent started in a new tab for " .. t.label, "It could not join the tab: " .. (why or "unknown reason"))
	end
	nameTab(cx, agent, t)
	cx:toast("success", "Agent started for " .. t.label, prompt)
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

-- With the directory ready, the agent starts once the user agrees to run omp there, where project config can run
-- code; setup commands and the agent come after.
local function startAgent(cx: WindowCx, pane: number, t: Target, r: Ready, prompt: string, wt: boolean)
	local question = "Start an agent for " .. t.label .. "?"
	confirm(cx, question, "Runs omp in " .. r.path, if wt then "The worktree stays; no agent starts" else "Nothing changes; no agent starts", function(cx2: WindowCx)
		afterReady(cx2, r, function()
			finishAgent(cx2, pane, t, r, prompt, wt)
		end)
	end, function(cx2: WindowCx)
		cx2:toast("info", "Agent not started for " .. t.label, (if wt then "The worktree is ready at " else "The checkout is at ") .. r.path)
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

-- An issue's prompt variables: the host's `vars` (strings only); others stay as typed.
local function fillVars(prompt: string, vars: any): string
	if type(vars) ~= "table" then
		return prompt
	end
	return (string.gsub(prompt, "{(%a+)}", function(k: string): string
		local v = vars[k]
		return if type(v) == "string" then v else "{" .. k .. "}"
	end))
end

-- Has the block's host prepare the target's directory and run `prompt` there, or without `prompt` create or reuse its
-- worktree (noted on the block) and open its tab. `wt` false (issues only): the repository's main checkout, no worktree.
-- What the host still needs is asked in the palette, then this runs again: a checkout folder of the repository
-- (`needCheckout`), the repository a Jira project's issue is worked in (`needRepo`, or `chooseRepo` among several, which
-- `target` then names).
local function prepareTarget(cx: WindowCx, pane: number, t: Target, prompt: string?, wt: boolean, target: string?)
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
						return prepareTarget(cx4, pane, t, prompt, wt, target)
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
						return prepareTarget(cx4, pane, t, prompt, wt, repo)
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
					prepareTarget(cx3, pane, t, prompt, wt, item.label)
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
				startAgent(cx2, pane, t, ready, fill(prompt, owner or "", name or "", tonumber(t.ref) :: number, a), wt)
			else
				startAgent(cx2, pane, t, ready, fillVars(prompt, a.vars), wt)
			end
		end)
	end
	local sent = if t.kind == "pr"
		then ask(cx, pane, "worktree", { repo = t.repo, number = tonumber(t.ref) }, PREPARE_MS, done)
		else ask(cx, pane, "issue", { repo = t.repo, ref = t.ref, worktree = wt, target = target }, PREPARE_MS, done)
	if sent and wt then
		cx:toast("info", "Preparing worktree for " .. t.label)
	end
end

-- An action-bar button's saved prompt `id`: the block's host says what it is now, and only one it still offers runs.
local function runSaved(cx: WindowCx, pane: number, t: Target, id: string)
	ask(cx, pane, "menu", { only = id }, MENU_MS, function(a: any, cx2: WindowCx)
		for _, it in if type(a.items) == "table" then a.items else {} do
			if type(it) == "table" and it.id == id and type(it.send) == "string" then
				return prepareTarget(cx2, pane, t, it.send, it.worktree ~= false)
			end
		end
		cx2:toast("error", "That prompt is no longer offered here", if type(a.problem) == "string" then a.problem else "Refresh and try again.")
	end)
end

-- Asks which saved prompt (Settings › Prompts, those the block's view offers) to run on the target, then
-- runs it in an agent where the prompt says (its worktree or the main checkout). "Type a prompt…" sends typed text
-- to the worktree.
local function pickAgent(cx: WindowCx, pane: number, t: Target)
	local function run(cx2: WindowCx, text: string, wt: boolean)
		prepareTarget(cx2, pane, t, text, wt)
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
					worktree = it.worktree ~= false,
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
		cx2:pick({ items = items, placeholder = "Run on " .. t.label, icon = "merge", action = "run" }):next(function(item, _, cx3)
			if not item or not cx3 then
				return
			end
			if item.typed then
				return cx3:prompt({ placeholder = "Prompt for an agent on " .. t.label, icon = "merge", action = "send" }):next(function(text, _, cx4)
					if cx4 and text and string.find(text, "%S") then
						run(cx4, text, true)
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
			run(cx3, item.send, item.worktree ~= false)
		end)
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
	elseif url == "plotroom://repos" or url == "plotroom://jira-projects" then
		if not isPlotroom(cx, pane) then
			cx:toast("error", "Plotroom: link did not come from a Plotroom block")
		elseif url == "plotroom://repos" then
			pickRepo(cx, pane)
		else
			pickJira(cx, pane)
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
			openUrl(cx, pane, target, "the check")
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
		elseif nodeProp(readNode(cx, pane, OPEN_NODE), "href") ~= url then
			cx:toast("error", "Plotroom: that issue is no longer listed", "Refresh and try again.")
		else
			openUrl(cx, pane, page, "the issue")
		end
		return true
	end
	if string.sub(url, 1, 15) == "plotroom://issu" then
		local repo, ref, rid2 = string.match(url, "^plotroom://issue/run/(.+)/([%w_%-]+)/(%w+)$")
		local act: string? = if rid2 then "run" else nil
		if not act then
			act, repo, ref = string.match(url, "^plotroom://issue/(%a+)/(.+)/([%w_%-]+)$")
		end
		if (act ~= "worktree" and act ~= "goto" and act ~= "agent" and act ~= "run") or (act == "run" and not rid2) or not repo or not ref or not worktree.validProject(repo) or #ref > 64 then
			cx:toast("error", "Plotroom: malformed link")
			return true
		end
		if not isPlotroom(cx, pane) then
			cx:toast("error", "Plotroom: link did not come from a Plotroom block")
			return true
		end
		local node = if act == "goto" then GOTO_NODE elseif act == "agent" then AGENT_NODE elseif act == "run" then PROMPT_NODE .. (rid2 or "") else WORKTREE_NODE
		if nodeProp(readNode(cx, pane, node), "href") ~= url then
			cx:toast("error", "Plotroom: that issue is no longer listed", "Refresh and try again.")
			return true
		end
		local t = issueTarget(repo, ref)
		if act == "goto" then
			gotoTarget(cx, t)
		elseif act == "agent" then
			pickAgent(cx, pane, t)
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
		elseif kind == "run" then PROMPT_NODE .. (id or "")
		else WORKTREE_NODE
	local present = nodeProp(readNode(cx, pane, node), "href") == url
	if not present then
		cx:toast("error", "Plotroom: that pull request is no longer listed", "Refresh and try again.")
		return true
	end
	local t = prTarget(owner, repo, n)
	if kind == "open" then
		openPr(cx, pane, owner, repo, n)
	elseif kind == "goto" then
		gotoTarget(cx, t)
	elseif kind == "agent" then
		pickAgent(cx, pane, t)
	elseif kind == "run" and id then
		runSaved(cx, pane, t, id)
	else
		prepareTarget(cx, pane, t, nil, true)
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
		return cx:toast("info", missing or "Nothing is selected")
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

local function launch(cx: WindowCx, block: string)
	local source = cx.session:focused()
	local cwd: string? = nil
	if source then
		local info = cx.session:pane(source)
		if info and info.cwd and info.cwd ~= "" then
			cwd = info.cwd
		end
	end
	local spec: Launch = { block = block, cwd = cwd, args = if cwd then { cwd } else nil }
	local pane = if source then cx.layout:split(source, "right", spec) else cx.layout:new_tab(spec)
	if not pane then
		cx:toast("error", "Plotroom is not loaded on this host")
	end
end

tern.command({
	id = "open",
	title = "Plotroom: Open GitHub PRs",
	icon = "merge",
	run = function(cx: WindowCx)
		launch(cx, "plotroom.prs")
	end,
})

tern.command({
	id = "open-issues",
	title = "Plotroom: Open Issues",
	icon = ISSUE_ICON,
	run = function(cx: WindowCx)
		launch(cx, "plotroom.issues")
	end,
})

local function available(cx: WindowCx): boolean
	local pane = cx.session:focused()
	return pane ~= nil and isPlotroom(cx, pane)
end

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
