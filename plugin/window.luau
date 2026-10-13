--!strict
-- The window half: opening Plotroom, validated PR links (Browser block,
-- worktree tab) and their keyboard-accessible palette commands.

local process = require("./process")
local worktree = require("./worktree")

local BLOCK = "plotroom.prs"
local SCHEME = "plotroom://"
local OPEN_NODE = "layer.queue.buttons.open"
local WORKTREE_NODE = "layer.queue.buttons.worktree"
local CHECK_NODE = "layer.queue.runs.run"

-- Worktree requests in flight, so repeated clicks create it once.
local inflight: { [string]: boolean } = {}

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
		return cx.session:surface(pane, { root = id })
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
	if (kind ~= "open" and kind ~= "worktree") or not owner or not repo or not worktree.validSegment(owner) or not worktree.validSegment(repo) then
		return nil, nil, nil, nil
	end
	if not num or num < 1 or num > 2147483647 then
		return nil, nil, nil, nil
	end
	return kind, owner, repo, num
end

-- `plotroom://github/check/<row>/<percent-encoded https URL>`: the row index and the page it links to.
local function parseCheck(url: string): (number?, string?)
	local i, enc = string.match(url, "^plotroom://github/check/(%d+)/(.+)$")
	local index = tonumber(i)
	if not index or not enc or index < 1 or index > 100000 then
		return nil, nil
	end
	local target = string.gsub(enc, "%%(%x%x)", function(h)
		return string.char(tonumber(h, 16) :: number)
	end)
	if string.sub(target, 1, 8) ~= "https://" or string.find(target, "[%c%s]") then
		return nil, nil
	end
	return index, target
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

-- One persistent status per worktree attempt for the queue preview: an action event to the source pane, which
-- host.luau keeps per PR (`worktree-status`, payload JSON in `value`). A toast alone would vanish.
local function publish(cx: WindowCx, pane: number, status: { [string]: any })
	pcall(function()
		if cx.session:pane(pane) then
			cx.session:event(pane, { ev = "action", act = "worktree-status", value = tern.json.encode(status) })
		end
	end)
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
	local tab = cx.session:tab_of(pane)
	local sessionId: number? = nil
	if tab then
		for _, t in cx.session:tabs() do
			if t.id == tab then
				sessionId = t.session
			end
		end
	end
	local exists = false
	for _, s in cx.session:sessions() do
		exists = exists or s.id == sessionId
	end
	if not tab or not sessionId or not exists then
		return cx:toast(level, "Worktree ready (the source pane closed, so no tab was opened)", r.path .. " · " .. summary)
	end
	cx.sessions:switch(sessionId)
	local newPane = cx.layout:new_tab({ cwd = r.path })
	if not newPane then
		return cx:toast("error", "Worktree ready, but its tab did not open", r.path .. " · choose Worktree again to retry")
	end
	local newTab = cx.session:tab_of(newPane)
	if newTab then
		local name = string.match(repo, "/(.+)$") or repo
		cx.layout:name_tab(newTab, "PR #" .. n .. " · " .. name)
	end
	cx:toast(level, "Worktree ready for " .. repo .. "#" .. n, summary)
end

local function worktreePr(cx: WindowCx, pane: number, owner: string, repo: string, n: number)
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
	local launch = nodeProp(readNode(cx, pane, "main.context"), "text")
	if type(launch) ~= "string" or launch == "" then
		launch = nil
	end
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
			return cx2:toast("info", "No local checkout of " .. full, "Enter its path in Plotroom, then choose Worktree again.")
		end
		if not result then
			local why = problem or "Worktree failed"
			publish(cx2, pane, { repo = full, number = n, ok = false, message = why })
			return cx2:toast("error", "Worktree failed", why)
		end
		-- The worktree exists whatever happens next: a failing tab call must not hide its path.
		local ok, why = pcall(function()
			finishWorktree(cx2, pane, full, n, result)
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
	local node = if kind == "open" then OPEN_NODE else WORKTREE_NODE
	local present = nodeProp(readNode(cx, pane, node), "href") == url
	if not present then
		cx:toast("error", "Plotroom: that pull request is no longer listed", "Refresh and try again.")
		return true
	end
	if kind == "open" then
		openPr(cx, pane, owner, repo, n)
	else
		worktreePr(cx, pane, owner, repo, n)
	end
	return true
end

local function selected(cx: WindowCx, nodeId: string)
	local pane = cx.session:focused()
	if not pane or not isPlotroom(cx, pane) then
		return cx:toast("error", "Focus a Plotroom block first")
	end
	local href = nodeProp(readNode(cx, pane, nodeId), "href")
	if type(href) ~= "string" then
		return cx:toast("info", "No pull request is selected")
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
