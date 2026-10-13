--!strict
-- The window half: opening Plotroom, validated PR links (Browser block, worktree tab, the PR's open tab, an agent
-- running a picked omp prompt template or skill) and their keyboard-accessible palette commands.
-- Anything that runs omp where project config can run code (listing skills, checking a template, starting an agent)
-- asks first.

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

-- Template files are listed and compared up to this size.
local TEMPLATE_CAP = 65536
-- omp loads prompt templates from every depth of a `prompts` directory. Looking through one gives up, and the agent
-- is refused, past this many entries or levels: a huge tree or a symlink loop must not hang the window.
local SCAN_ENTRIES = 2000
local SCAN_DEPTH = 8
local RISK = "Project config can run code"

-- The file a template row was listed from, as it read then: `text` is nil when it could not be read (or is over
-- TEMPLATE_CAP); `project` marks the repository's own templates, as opposed to the user's.
type Source = { path: string, text: string?, name: string, project: boolean }

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

-- The status of a worktree that is ready, published as soon as it exists so it stands whatever the tab or the agent
-- does next (and replaces an earlier failure card).
local function publishResult(cx: WindowCx, pane: number, repo: string, n: number, r: worktree.Result)
	local update = worktree.update(r)
	publish(cx, pane, {
		repo = repo,
		number = n,
		ok = true,
		created = r.created,
		current = r.head == r.prHead,
		dirty = r.dirty,
		path = r.path,
		root = r.root,
		branch = r.branch,
		ref = r.ref,
		head = r.head,
		prHead = r.prHead,
		prRef = r.prRef,
		summary = worktree.describe(r),
		update = if #update > 0 then update else nil,
		cleanup = worktree.cleanup(r),
	})
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

-- `repo`'s saved setup commands (Settings › Worktrees) as one shell line that stops at the first failure; nil if none.
local function setupLine(repo: string): string?
	local ok, map = pcall(tern.kv.get, "setup")
	local list = if ok and type(map) == "table" then map["github.com/" .. string.lower(repo)] else nil
	local cmds: { string } = {}
	if type(list) == "table" then
		for _, c in list do
			if type(c) == "string" and string.find(c, "%S") then
				table.insert(cmds, c)
			end
		end
	end
	return if #cmds > 0 then table.concat(cmds, " && ") else nil
end

local function finishWorktree(cx: WindowCx, pane: number, repo: string, n: number, r: worktree.Result)
	local summary = worktree.describe(r)
	local current = r.head == r.prHead
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
	local setup = if r.created then setupLine(repo) else nil
	if setup then
		cx:run(newPane, setup .. "\r")
	end
	cx:toast(level, "Worktree ready for " .. repo .. "#" .. n, if setup then summary .. " · running setup" else summary)
end

-- Starts an agent in the worktree with `prompt`: in the PR's open tab when there is one, else in a new tab. A new
-- worktree's setup commands run first in a shell tab the agent joins. ponytail: the agent starts without waiting
-- for them; poll the shell's `last` status if agents trip over a half-done setup.
local function finishAgent(cx: WindowCx, pane: number, repo: string, n: number, r: worktree.Result, prompt: string)
	local path = r.path
	local _, tab, found = prPane(cx, repo, n)
	local session = found or sourceSession(cx, pane)
	if not session then
		return cx:toast("success", "Worktree ready", path .. " (the source pane closed, so no agent was started)")
	end
	cx.sessions:switch(session)
	local setup = if r.created then setupLine(repo) else nil
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
local function afterReady(cx: WindowCx, r: worktree.Result, step: () -> ())
	local why: any
	local ok = xpcall(step, function(e: any)
		why = e
	end)
	if not ok then
		cx:toast("error", "Worktree ready, but its tab did not open", r.path .. " · " .. tostring(why))
	end
end

-- Consent before omp runs where project config can run code: a native picker whose first row, the one ↵ takes, is
-- Cancel. Nothing is remembered. A dismissed picker, Cancel or a callback without a window context ends it; `no`
-- only runs with a context.
local function confirm(cx: WindowCx, question: string, where: string, stays: string, yes: (WindowCx) -> (), no: ((WindowCx) -> ())?)
	local items: { PickItem } = {
		{ label = "Cancel", detail = stays, group = RISK },
		{ label = "Continue", detail = where, group = RISK, go = true },
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

local function readCapped(path: string): string?
	local ok, text = pcall(tern.fs.read, path, TEMPLATE_CAP)
	return if ok and type(text) == "string" then text else nil
end

-- omp's slash commands over its RPC mode, run in `cwd`: done(commands, problem, cx), the commands nil when omp did not
-- list them. Skills and file commands are in that list, prompt templates are not.
local function ompCatalog(cwd: string, done: ({ any }?, string?, WindowCx?) -> ())
	local ask = tern.json.encode({ id = "plotroom", type = "get_available_commands" }) .. "\n"
	process.run({ "omp", "--mode", "rpc", "--no-session" }, { cwd = cwd, stdin = ask, timeout_ms = RPC_MS }, function(result, problem, cx)
		if not result then
			return done(nil, problem, cx)
		end
		for line in string.gmatch(result.stdout, "[^\n]+") do
			local ok, msg = pcall(tern.json.decode, line)
			if ok and type(msg) == "table" and msg.id == "plotroom" then
				local cmds = if msg.success == true and type(msg.data) == "table" then msg.data.commands else nil
				if type(cmds) ~= "table" then
					return done(nil, "omp answered without a command list", cx)
				end
				return done(cmds, nil, cx)
			end
		end
		done(nil, if result.timed_out then "omp did not answer within 10 seconds" else "omp did not list its commands (exit " .. result.status .. ")", cx)
	end)
end

-- Where omp keeps the user's config (its templates and commands among it) unless something moves it.
local function userAgentDir(): string?
	local home = tern.getenv("HOME")
	return if home and home ~= "" then (string.gsub(home, "/+$", "")) .. "/.omp/agent" else nil
end

-- Where omp, run in `cwd`, reads the user's config: `omp config path`. A checkout's `.env` can move it, even into the
-- checkout. done(dir, problem, cx).
local function ompAgentDir(cwd: string, done: (string?, string?, WindowCx?) -> ())
	process.run({ "omp", "config", "path" }, { cwd = cwd, timeout_ms = RPC_MS }, function(result, problem, cx)
		if not result then
			return done(nil, problem, cx)
		end
		local dir = if result.status == 0 and not result.timed_out then string.match(result.stdout, "^(/[^\r\n]+)\r?\n?$") else nil
		done(dir, if dir then nil else "omp did not report its agent directory (exit " .. result.status .. ")", cx)
	end)
end

-- Adds to `found` the path of every entry called `file` below `dir`, as omp loads prompt templates from every depth.
-- Raises when the tree is bigger or deeper than a scan allows, which a symlink loop always is.
local function findNamed(dir: string, file: string, scan: { left: number }, depth: number, found: { string })
	local ok, entries = pcall(tern.fs.list, dir)
	if not ok then
		return -- a file, not a directory
	end
	for _, entry in entries do
		scan.left -= 1
		if scan.left < 0 or depth >= SCAN_DEPTH then
			error("more than " .. SCAN_ENTRIES .. " entries or " .. SCAN_DEPTH .. " levels of directories in a prompts directory", 0)
		end
		local path = dir .. "/" .. entry
		if entry == file then
			table.insert(found, path)
		end
		findNamed(path, file, scan, depth + 1, found)
	end
end

-- How omp's list names a command called `name` (a builtin's aliases count): its source; nil when the list has none.
local function listedAs(cmds: { any }, name: string): string?
	for _, c in cmds do
		if type(c) == "table" and (c.name == name or (type(c.aliases) == "table" and table.find(c.aliases, name) ~= nil)) then
			return tostring(c.source)
		end
	end
	return nil
end

-- Why `/name` of a picked template would no longer be that template; nil when it still is. Always: its file reads back
-- as it was listed. With the pull request's checkout `root`: every `<name>.md` anywhere under its `.omp/prompts` reads
-- back as the same text, and the repository's own template has one. With `agent`, where omp reads the user's config
-- there: unless that is ~/.omp/agent (a checkout's `.env` can move it, even into the checkout) its `prompts` are held
-- to the same, and the template must be somewhere. omp 18.10.3 reads the user's templates first, but that order has
-- no contract, so any difference refuses. Commands of the name are not looked for in files, whatever they are called
-- or wherever they sit: only omp's own list says which exist (`verify`).
local function mismatch(src: Source, root: string?, agent: string?): string?
	if src.text == nil or readCapped(src.path) ~= src.text then
		return src.path .. " is gone, unreadable, over 64 KiB or changed since it was listed"
	end
	if not root then
		return nil
	end
	local file = src.name .. ".md"
	local found: { string } = {}
	findNamed(root .. "/.omp/prompts", file, { left = SCAN_ENTRIES }, 0, found)
	local moved = if agent and agent ~= userAgentDir() then agent else nil
	if moved then
		findNamed(moved .. "/prompts", file, { left = SCAN_ENTRIES }, 0, found)
	end
	for _, path in found do
		if readCapped(path) ~= src.text then
			return "omp would read a different template: " .. path
		end
	end
	if #found == 0 then
		if moved then
			return "omp reads its templates from " .. moved .. "/prompts there, which has no " .. file
		elseif src.project then
			return "The pull request has no .omp/prompts/" .. file
		end
	end
	return nil
end

-- `mismatch` of a picked row, which has none when it is not a template. A filesystem call that raises ends it too.
local function unbound(item: PickItem, root: string?, agent: string?): string?
	local src = item.source :: Source?
	if not src then
		return nil
	end
	local ok, why = pcall(mismatch, src, root, agent)
	return if ok then why else "The checkout could not be inspected: " .. tostring(why)
end

-- Once the user agreed to run omp in `root`, asks omp itself about `/name` of a picked template there. A skill, file
-- command (from any config family, named by its file, its frontmatter or its directory), extension or builtin command
-- of that name runs instead, and omp's dispatch has no form that names the template: only omp's own list is
-- complete, so no list, or a command of the name in it, refuses. It also says where omp reads the user's templates
-- there, which a checkout's `.env` can change. The files are checked again last: the user may have waited.
-- done(cx, why): `why` is nil when the agent may start. Typed prompts, skills and file commands have no template to
-- bind and pass at once.
-- ponytail: code can answer for itself (an extension's input hook, an MCP server whose prompts connect after the list
-- is read), so only the consent covers that.
local function verify(cx: WindowCx, item: PickItem?, root: string, done: (WindowCx, string?) -> ())
	local src = if item then item.source :: Source? else nil
	if not item or not src then
		return done(cx, nil)
	end
	local name = src.name
	local function cannot(what: string, problem: string?): string
		return "omp could not " .. what .. " in the checkout, so /" .. name .. " cannot be confirmed: " .. tostring(problem)
	end
	ompAgentDir(root, function(agent, problem, cx2)
		if not cx2 then
			return
		end
		if not agent then
			return done(cx2, cannot("report where it reads templates", problem))
		end
		ompCatalog(root, function(cmds, problem2, cx3)
			if not cx3 then
				return
			end
			if not cmds then
				return done(cx3, cannot("list its commands", problem2))
			end
			local source = listedAs(cmds, name)
			if source then
				return done(cx3, "omp lists /" .. name .. " in the checkout (" .. source .. "), and that runs instead of your template")
			end
			done(cx3, unbound(item, root, agent))
		end)
	end)
end

-- With the worktree ready, an agent starts in it only if `/name` of the picked template still reaches that template
-- there (the file as listed, and nothing of the pull request's answering to the name) and the user agrees to run omp
-- in that checkout; setup commands and the agent come after.
local function startAgent(cx: WindowCx, pane: number, repo: string, n: number, r: worktree.Result, prompt: string, item: PickItem?)
	local title = "Agent not started for " .. repo .. "#" .. n
	local function refuse(cx2: WindowCx, why: string)
		cx2:toast("error", title, why .. " · The worktree is ready at " .. r.path)
	end
	local why = if item then unbound(item, r.path, nil) else nil
	if why then
		return refuse(cx, why)
	end
	local question = "Start an agent for " .. repo .. "#" .. n .. " in " .. r.path .. "? That checkout's project config can run code."
	confirm(cx, question, r.path, "The worktree stays; no agent starts", function(cx2: WindowCx)
		verify(cx2, item, r.path, function(cx3: WindowCx, why2: string?)
			if why2 then
				return refuse(cx3, why2)
			end
			afterReady(cx3, r, function()
				finishAgent(cx3, pane, repo, n, r, prompt)
			end)
		end)
	end, function(cx2: WindowCx)
		cx2:toast("info", title, "The worktree is ready at " .. r.path)
	end)
end

local function worktreePr(cx: WindowCx, pane: number, owner: string, repo: string, n: number, prompt: string?, item: PickItem?)
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
		publishResult(cx2, pane, full, n, result)
		afterReady(cx2, result, function()
			if prompt then
				startAgent(cx2, pane, full, n, result, prompt, item)
			else
				finishWorktree(cx2, pane, full, n, result)
			end
		end)
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

-- omp prompt templates in `dir` (`<name>.md`, frontmatter description as the detail), skipping names in `seen`. Each
-- row keeps its file as read: `/name` must still mean that when the agent runs.
local function templatesIn(dir: string, group: string, project: boolean, seen: { [string]: boolean }, out: { PickItem })
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
			local path = dir .. "/" .. file
			local text = readCapped(path)
			local front = if text then string.match(text, "^%-%-%-\r?\n(.-)\r?\n%-%-%-") else nil
			local desc = if front then string.match("\n" .. front .. "\n", "\ndescription:[ \t]*([^\r\n]-)[ \t]*\r?\n") else nil
			local source: Source = { path = path, text = text, name = name, project = project }
			table.insert(out, { label = "/" .. name, detail = if desc ~= "" then desc else nil, group = group, send = "/" .. name, source = source })
		end
	end
end

-- Prompt templates omp would expand: the nearest `.omp/prompts` above `cwd`, then `~/.omp/agent/prompts`. omp reads the
-- user's before the project's and the first of a name wins, so a user template hides a same-named repository one.
local function templates(cwd: string?): { PickItem }
	local seen: { [string]: boolean } = {}
	local user: { PickItem } = {}
	local agent = userAgentDir()
	if agent then
		templatesIn(agent .. "/prompts", "Your templates", false, seen, user)
	end
	local out: { PickItem } = {}
	local dir = cwd
	while dir and dir ~= "" and dir ~= "/" do
		if tern.fs.exists(dir .. "/.omp/prompts") then
			templatesIn(dir .. "/.omp/prompts", "This repository's templates", true, seen, out)
			break
		end
		dir = string.match(dir, "^(.*)/[^/]*$")
	end
	for _, t in user do
		table.insert(out, t)
	end
	return out
end

-- omp's skills and file commands as picker rows (prompt templates are not in its list); done(items, problem, cx).
local function ompCommands(cwd: string, done: ({ PickItem }, string?, WindowCx?) -> ())
	ompCatalog(cwd, function(cmds, problem, cx)
		local out: { PickItem } = {}
		if cmds then
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
		end
		done(out, problem, cx)
	end)
end

-- Asks which prompt template or skill to run on PR `owner/repo#n`, then runs it as `/<name> <PR URL>` in an agent
-- in the PR's worktree. "Type a prompt…" sends the typed text as it is. omp lists skills by running in the directory
-- Plotroom was opened in, where project config can run code, so that asks first; the home directory needs no asking,
-- omp never treats it as a project.
local function pickAgent(cx: WindowCx, pane: number, owner: string, repo: string, n: number)
	local full = owner .. "/" .. repo
	local cwd = launchDir(cx, pane)
	local function offer(cmds: { PickItem }, problem: string?, cx2: WindowCx?)
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
					local again = table.clone(c) -- the whole row, so it keeps the template it is bound to
					again.group = "Recent"
					table.insert(items, again)
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
			local why = unbound(item, nil, nil)
			if why then
				return cx3:toast("error", "Agent not started for " .. full .. "#" .. n, why)
			end
			local recent = readRecent()
			local at = table.find(recent, item.label)
			if at then
				table.remove(recent, at)
			end
			table.insert(recent, 1, item.label)
			recent[RECENT_CAP + 1] = nil
			pcall(tern.kv.set, RECENT_KEY, tern.json.array(recent)) -- best effort: a failed write only loses the order
			worktreePr(cx3, pane, owner, repo, n, item.send .. " https://github.com/" .. full .. "/pull/" .. n, item)
		end)
	end
	local home = tern.getenv("HOME")
	local dir = cwd or home or ""
	if dir == "" then
		return offer({}, "No directory is known to ask omp in", cx)
	end
	local function list()
		ompCommands(dir, offer)
	end
	if home and (string.gsub(dir, "/+$", "")) == (string.gsub(home, "/+$", "")) then
		return list()
	end
	confirm(cx, "Run omp in " .. dir .. " to list skills and commands? Its project config can run code.", dir, "Nothing is run", list)
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
