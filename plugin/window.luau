--!strict
-- The window half: opening Plotroom, validated PR links (Browser block, worktree tab, the PR's open tab, an agent
-- running a picked omp prompt template or skill) and their keyboard-accessible palette commands.

local process = require("./process")
local worktree = require("./worktree")

local BLOCK = "plotroom.prs"
local SCHEME = "plotroom://"
local OPEN_NODE = "layer.queue.buttons.open"
local WORKTREE_NODE = "layer.queue.buttons.worktree"
local CHECK_NODE = "layer.queue.runs.run"
local GOTO_NODE = "layer.queue.buttons.goto"
local AGENT_NODE = "layer.queue.buttons.agent"
local RPC_MS = 10000
local RECENT_CAP = 5

-- Worktree requests in flight, so repeated clicks create it once.
local inflight: { [string]: boolean } = {}
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

local function parseLink(url: string): (string?, string?, string?, number?)
	local kind, owner, repo, n = string.match(url, "^plotroom://github/(%a+)/([^/]+)/([^/]+)/(%d+)$")
	local num = tonumber(n)
	if (kind ~= "open" and kind ~= "worktree" and kind ~= "goto" and kind ~= "agent") or not owner or not repo or not worktree.validSegment(owner) or not worktree.validSegment(repo) then
		return nil, nil, nil, nil
	end
	if not num or num < 1 or num > 2147483647 then
		return nil, nil, nil, nil
	end
	return kind, owner, repo, num
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

local function mappedPath(repo: string): string?
	local ok, repos = pcall(tern.kv.get, "repos")
	if ok and type(repos) == "table" then
		local p = repos["github.com/" .. string.lower(repo)]
		if type(p) == "string" then
			return p
		end
	end
	return nil
end

-- The directory the Plotroom block in `pane` was opened in, as its context line shows it; nil when unknown.
local function launchDir(cx: WindowCx, pane: number): string?
	local text = nodeProp(readNode(cx, pane, "main.context"), "text")
	return if type(text) == "string" and text ~= "" then text else nil
end

-- One persistent status per worktree attempt for the queue preview: an action event to the source pane, which
-- host.luau keeps per PR (`worktree-status`, payload JSON in `value`). A toast alone would vanish.
local function publish(cx: WindowCx, pane: number, status: { [string]: any })
	pcall(function()
		if cx.session:pane(pane) then
			cx.session:event(pane, { ev = "action", act = "worktree-status", value = tern.json.encode(status) })
		end
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

-- Names the tab holding `pane` "PR #n · <repo name>".
local function namePrTab(cx: WindowCx, pane: number, repo: string, n: number)
	local tab = cx.session:tab_of(pane)
	if tab then
		cx.layout:name_tab(tab, "PR #" .. n .. " · " .. (string.match(repo, "/(.+)$") or repo))
	end
end

local function finishWorktree(cx: WindowCx, pane: number, repo: string, n: number, r: worktree.Result)
	local summary = worktree.describe(r)
	local current = r.head == r.prHead
	local update = worktree.update(r)
	-- Published before the tab opens, so the preview still shows where the worktree is if the tab cannot open.
	publish(cx, pane, {
		repo = repo,
		number = n,
		ok = true,
		created = r.created,
		current = current,
		dirty = r.dirty,
		path = r.path,
		root = r.root,
		branch = r.branch,
		ref = r.ref,
		head = r.head,
		prHead = r.prHead,
		prRef = r.prRef,
		summary = summary,
		update = if #update > 0 then update else nil,
		cleanup = worktree.cleanup(r),
	})
	-- Success only when nothing needs the user's attention.
	local level: ToastLevel = if current and r.dirty ~= true then "success" else "info"
	local sessionId = sourceSession(cx, pane)
	if not sessionId then
		return cx:toast(level, "Worktree ready (the source pane closed, so no tab was opened)", r.path .. " · " .. summary)
	end
	cx.sessions:switch(sessionId)
	local newPane = cx.layout:new_tab({ cwd = r.path })
	if not newPane then
		return cx:toast("error", "Worktree ready, but its tab did not open", r.path .. " · choose Worktree again to retry")
	end
	namePrTab(cx, newPane, repo, n)
	cx:toast(level, "Worktree ready for " .. repo .. "#" .. n, summary)
end

-- Starts an agent in the worktree at `path` with `prompt`: in the PR's open tab when there is one, else in a new tab.
local function finishAgent(cx: WindowCx, pane: number, repo: string, n: number, path: string, prompt: string)
	local _, tab, found = prPane(cx, repo, n)
	local session = found or sourceSession(cx, pane)
	if not session then
		return cx:toast("success", "Worktree ready", path .. " (the source pane closed, so no agent was started)")
	end
	cx.sessions:switch(session)
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

local function worktreePr(cx: WindowCx, pane: number, owner: string, repo: string, n: number, prompt: string?)
	local full = owner .. "/" .. repo
	for _, h in cx.hosts:list() do
		if table.find(h.panes, pane) and h.kind ~= "local" then
			return cx:toast("error", "Open Plotroom on the local host to create a worktree")
		end
	end
	local flight = string.lower(full) .. "#" .. n
	if inflight[flight] then
		return cx:toast("info", "A worktree for " .. full .. "#" .. n .. " is already being prepared")
	end
	local launch = launchDir(cx, pane)
	inflight[flight] = true
	local function done(result: worktree.Result?, problem: string?, cx2: WindowCx?)
		inflight[flight] = nil
		if not cx2 then
			return
		end
		if problem == worktree.NO_REPO then
			if cx2.session:pane(pane) then
				cx2.session:event(pane, { ev = "action", act = "choose-repo", value = full })
			end
			return cx2:toast("info", "No local checkout of " .. full, "Enter its path in Plotroom, then try again.")
		end
		if not result then
			local why = problem or "Worktree failed"
			publish(cx2, pane, { repo = full, number = n, ok = false, message = why })
			return cx2:toast("error", "Worktree failed", why)
		end
		-- The worktree exists whatever happens next: a failing tab call must not hide its path.
		local ok, why = pcall(function()
			if prompt then
				finishAgent(cx2, pane, full, n, result.path, prompt)
			else
				finishWorktree(cx2, pane, full, n, result)
			end
		end)
		if not ok then
			cx2:toast("error", "Worktree ready, but its tab did not open", result.path .. " · " .. tostring(why))
		end
	end
	-- worktree.open always ends in done; if anything raises before it could start, release the PR here.
	local started, why = pcall(function()
		process.reset()
		cx:toast("info", "Preparing worktree for " .. full .. "#" .. n)
		worktree.open(launch, mappedPath(full), full, n, done)
	end)
	if not started then
		inflight[flight] = nil
		cx:toast("error", "Worktree failed", tostring(why))
	end
end

-- omp prompt templates in `dir` (`<name>.md`, frontmatter description as the detail), skipping names in `seen`.
local function templatesIn(dir: string, group: string, seen: { [string]: boolean }, out: { PickItem })
	local ok, files = pcall(function(): { string }
		return if tern.fs.exists(dir) then tern.fs.list(dir) else {}
	end)
	if not ok then
		return
	end
	table.sort(files)
	for _, file in files do
		local name = string.match(file, "^([^%.%s][^%s]*)%.md$")
		if name and not seen[name] then
			seen[name] = true
			local okr, text = pcall(tern.fs.read, dir .. "/" .. file, 65536)
			local front = if okr and type(text) == "string" then string.match(text, "^%-%-%-\r?\n(.-)\r?\n%-%-%-") else nil
			local desc = if front then string.match("\n" .. front .. "\n", "\ndescription:[ \t]*([^\r\n]-)[ \t]*\r?\n") else nil
			table.insert(out, { label = "/" .. name, detail = if desc ~= "" then desc else nil, group = group, send = "/" .. name })
		end
	end
end

-- Prompt templates omp would expand: the nearest `.omp/prompts` above `cwd`, then `~/.omp/agent/prompts`.
local function templates(cwd: string?): { PickItem }
	local out: { PickItem } = {}
	local seen: { [string]: boolean } = {}
	local dir = cwd
	while dir and dir ~= "" and dir ~= "/" do
		if tern.fs.exists(dir .. "/.omp/prompts") then
			templatesIn(dir .. "/.omp/prompts", "This repository's templates", seen, out)
			break
		end
		dir = string.match(dir, "^(.*)/[^/]*$")
	end
	local home = tern.getenv("HOME")
	if home and home ~= "" then
		templatesIn(home .. "/.omp/agent/prompts", "Your templates", seen, out)
	end
	return out
end

-- omp's skills and file commands, asked over its RPC mode (prompt templates are not in that list); done(items, problem, cx).
local function ompCommands(cwd: string, done: ({ PickItem }, string?, WindowCx?) -> ())
	local ask = tern.json.encode({ id = "plotroom", type = "get_available_commands" }) .. "\n"
	process.run({ "omp", "--mode", "rpc", "--no-session" }, { cwd = cwd, stdin = ask, timeout_ms = RPC_MS }, function(result, problem, cx)
		local out: { PickItem } = {}
		if not result then
			return done(out, problem, cx)
		end
		for line in string.gmatch(result.stdout, "[^\n]+") do
			local ok, msg = pcall(tern.json.decode, line)
			if ok and type(msg) == "table" and msg.id == "plotroom" then
				local cmds = if msg.success == true and type(msg.data) == "table" then msg.data.commands else nil
				if type(cmds) ~= "table" then
					return done(out, "omp answered without a command list", cx)
				end
				for _, c in cmds do
					if type(c) == "table" and type(c.name) == "string" and (c.source == "skill" or c.source == "file") and not string.find(c.name, "%s") then
						local desc = if type(c.description) == "string" then string.match(c.description, "^[^\r\n]*") else nil
						table.insert(out, {
							label = "/" .. c.name,
							detail = if desc ~= "" then desc else nil,
							group = if c.source == "skill" then "Skills" else "Commands",
							send = "/" .. c.name,
						})
					end
				end
				return done(out, nil, cx)
			end
		end
		done(out, if result.timed_out then "omp did not answer within 10 seconds" else "omp did not list its commands (exit " .. result.status .. ")", cx)
	end)
end

-- Asks which prompt template or skill to run on PR `owner/repo#n`, then runs it as `/<name> <PR URL>` in an agent
-- in the PR's worktree. "Type a prompt…" sends the typed text as it is.
local function pickAgent(cx: WindowCx, pane: number, owner: string, repo: string, n: number)
	local full = owner .. "/" .. repo
	local cwd = launchDir(cx, pane)
	ompCommands(cwd or tern.getenv("HOME") or ".", function(cmds, problem, cx2)
		if not cx2 then
			return
		end
		if problem then
			cx2:toast("info", "Skills are not listed", problem)
		end
		local all = templates(cwd)
		for _, c in cmds do
			table.insert(all, c)
		end
		local items: { PickItem } = {}
		for _, label in readRecent() do
			for _, c in all do
				if c.label == label then
					table.insert(items, { label = c.label, detail = c.detail, group = "Recent", send = c.send })
					break
				end
			end
		end
		table.insert(items, { label = "Type a prompt…", detail = "Send your own text", typed = true })
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
						worktreePr(cx4, pane, owner, repo, n, text)
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
			worktreePr(cx3, pane, owner, repo, n, item.send .. " https://github.com/" .. full .. "/pull/" .. n)
		end)
	end)
end

-- Validates a plotroom:// link against the pane's live surface and runs it.
local function handle(cx: WindowCx, url: string, pane: number): boolean
	local index, target = parseCheck(url)
	if index and target then
		if not isPlotroom(cx, pane) then
			cx:toast("error", "Plotroom: link did not come from a Plotroom block")
		elseif nodeProp(readNode(cx, pane, CHECK_NODE .. index), "href") ~= url then
			cx:toast("error", "Plotroom: that check is no longer listed", "Refresh and try again.")
		else
			openUrl(cx, pane, target, "the check")
		end
		return true
	end
	-- `plotroom://github/edit-template/<name>`: the host just created or found ~/.omp/agent/prompts/<name>.md.
	local tname = string.match(url, "^plotroom://github/edit%-template/([%w][%w%-_]*)$")
	if tname then
		local home = tern.getenv("HOME")
		local dir = if home and home ~= "" then home .. "/.omp/agent/prompts" else nil
		local path = if dir then dir .. "/" .. tname .. ".md" else nil
		if not isPlotroom(cx, pane) then
			cx:toast("error", "Plotroom: link did not come from a Plotroom block")
		elseif not dir or not path or not tern.fs.exists(path) then
			cx:toast("error", "Plotroom: there is no prompt template " .. tname)
		else
			local quoted = "'" .. string.gsub(path, "'", "'\\''") .. "'"
			if not cx.layout:split(pane, "right", { cwd = dir, command = "${VISUAL:-${EDITOR:-vi}} " .. quoted }) then
				cx:toast("error", "Plotroom: could not open an editor for " .. path)
			end
		end
		return true
	end
	local kind, owner, repo, n = parseLink(url)
	if not kind or not owner or not repo or not n then
		cx:toast("error", "Plotroom: malformed link")
		return true
	end
	if not isPlotroom(cx, pane) then
		cx:toast("error", "Plotroom: link did not come from a Plotroom block")
		return true
	end
	local node = if kind == "open" then OPEN_NODE elseif kind == "goto" then GOTO_NODE elseif kind == "agent" then AGENT_NODE else WORKTREE_NODE
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
