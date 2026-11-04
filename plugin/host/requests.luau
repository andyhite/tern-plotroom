--!strict
-- Requests from window.luau (rpc) and the workflow requests: menu, worktree prepare, pickers, mutation plans, draft PR, palette actions.
-- window.luau runs on the machine showing the window, which for a pane on a remote host is not the machine holding
-- the checkout. So whatever reads the checkout or runs git, gh or omp runs here, where the block runs: the window sends
-- {act = "rpc", value = JSON {id, op, ...}}; the answer is the hidden node `main.r<id>` (JSON text), announced by
-- opening plotroom://rpc/<id>, which only the window waiting for that id acts on. `main.rpc` says which protocol this
-- host speaks, so a window never waits on a host running another Plotroom version.

local github = require("../github")
local jira = require("../jira")
local input = require("../input")
local keys = require("../keys")
local process = require("../process")
local sorting = require("../sorting")
local tracker = require("../tracker")
local usage = require("../usage")
local worktree = require("../worktree")
local logs = require("../logs")

local core = require("./core")
local storage = require("./storage")
local engine = require("./engine")
local render = require("./render")
local settings = require("./settings")

local ui = tern.ui

type State = core.State
type Prompt = core.Prompt
-- A queue action Commands offers (paletteActions); `key` "" when none.
type QueueAction = { id: string, label: string, key: string, group: string, detail: string? }
type KeyEntry = { key: string, label: string, first: number, use: number, at: number }

local COMMENT_ROWS, KINDS, clip, printable, cli = core.COMMENT_ROWS, core.KINDS, core.clip, core.printable, core.cli
local checkoutOf, editJiraRepos, isTable, jiraReposOf, loadPrompts, promptById = storage.checkoutOf, storage.editJiraRepos, storage.isTable, storage.jiraReposOf, storage.loadPrompts, storage.promptById
local readCheckouts, readMap, saveCheckout, setupOf, stringList, formats = storage.readCheckouts, storage.readMap, storage.saveCheckout, storage.setupOf, storage.stringList, storage.formats
local activeView, alive, changed, detailKey, filtered, indexOf, issueVars, login, noteWorktree = engine.activeView, engine.alive, engine.changed, engine.detailKey, engine.filtered, engine.indexOf, engine.issueVars, engine.login, engine.noteWorktree
local offered, openItems, parseRepo, selected, snapKey, switchView, trim, me, ghActive = engine.offered, engine.openItems, engine.parseRepo, engine.selected, engine.snapKey, engine.switchView, input.trim, engine.me, engine.ghActive
local discardEdit = settings.discardEdit

local M = {}

M.seq = 0 -- confirmation tokens issued by this runtime
local NOW_KEY = "\0now" -- the key of Now's Mark all notifications read… plan: no item key holds a NUL

local REPLY_CAP = 8 -- answers kept on screen, newest last: windows read theirs once announced
-- Picker rows sent stop at this much encoded text: the answer must fit the window's 64000-character surface read.
local MENU_BUDGET = 48000

-- The prefix of `list` whose running `cost` stays within MENU_BUDGET.
local function capped(list: { any }, cost: (any) -> number): { any }
	local out: { any } = {}
	local size = 0
	for _, v in list do
		size += cost(v)
		if size > MENU_BUDGET then
			break
		end
		table.insert(out, v)
	end
	return out
end

-- Pull requests and issues whose worktree is being prepared or removed on this host ("owner/repo#n", lowercase): one
-- at a time, whichever window asks.
local preparing: { [string]: boolean } = {}
M.preparing = preparing

local function reply(state: State, id: string, body: { [string]: any })
	if not alive(state) then
		return
	end
	for i, r in state.replies do
		if r.id == id then
			table.remove(state.replies, i)
			break
		end
	end
	table.insert(state.replies, { id = id, text = tern.json.encode(body) })
	if #state.replies > REPLY_CAP then
		table.remove(state.replies, 1)
	end
	state.cx:render() -- the answer is on screen before the window is told to read it
	state.cx:open("plotroom://rpc/" .. id)
end

-- Answers `id` that `repo` needs a checkout, with the folder detection found for it (`found`), if any, so the window
-- offers Use <path> before asking for one.
local function needCheckout(state: State, id: string, repo: string)
	engine.detectCheckout(state, repo, function(path)
		reply(state, id, { needCheckout = string.lower(repo), found = path })
	end)
end

-- `repo`'s saved setup commands (Settings › Repositories) as one shell line that stops at the first failure, blank ones
-- left out; nil if none.
local function setupLine(repo: string): string?
	local map = readMap("setup-commands", "setup commands")
	local cmds: { string } = {}
	local saved: { string } = if map then setupOf(map, repo) else {}
	for _, c in saved do
		if string.find(c, "%S") then
			table.insert(cmds, c)
		end
	end
	return if #cmds > 0 then table.concat(cmds, " && ") else nil
end

-- The issue with identity `key` (lowercase "owner/repo#ref") as the freshest cached snapshot lists it; nil when none does.
local function loadedIssue(state: State, key: string): tracker.Issue?
	local found: tracker.Issue? = nil
	for _, snap in state.snaps do
		if snap.kind == "issues" then
			for _, item in snap.items do
				if item.key == key and (not found or item.updated > found.updated) then
					found = item
				end
			end
		end
	end
	return found
end

-- The prompt variables the item `item` (selected(state)) fills from what the queue already holds; nil without one.
-- Variables only a worktree knows (branch of an issue, remote, the logins) stay unfilled.
local function itemVars(item: any): { [string]: string }?
	if not item then
		return nil
	elseif type(item.number) == "number" then
		local owner, name = string.match(item.repo, "^([^/]+)/(.+)$")
		return { url = item.url, owner = owner or "", repo = name or "", number = tostring(item.number), title = item.title, author = item.author, branch = item.head, base = item.base }
	end
	local code = engine.codeRepoOf(item)
	local vars = issueVars(item, code or "")
	if not code then
		local open: any = vars
		open.owner, open.repo = nil, nil
	end
	return vars
end

-- An action's detail: its model and its prompt's first line with `vars` filled; a line that still names a variable
-- is left out, so no `{placeholder}` ever shows.
local function actionDetail(p: Prompt, vars: { [string]: string }?): string?
	local line = string.match(p.text, "^%s*([^\n]*)") or ""
	line = string.gsub(line, tracker.VAR, function(k: string): string
		return if vars and vars[k] then vars[k] else "{" .. k .. "}"
	end)
	if string.find(line, tracker.VAR) then
		line = ""
	end
	local text = (if p.model then p.model .. (if line ~= "" then " · " else "") else "") .. line
	return if text ~= "" then clip(printable(text), 160) else nil
end

-- The agent picker's rows: `offered`, each with its id so a prompt's run link can name it. With `only`, just that
-- prompt, so a shortcut never misses its prompt to the picker's size budget. Without `withText`, no prompt text: the
-- palette and the picker show names and run actions through their links.
local function menuRows(state: State, only: string?, withText: boolean): ({ any }, string?)
	local list, problem = offered(state)
	local active = activeView(state)
	local vars = itemVars(if state.boardOn or state.agentsOn or state.nowOn then nil else selected(state))
	local mine: { any } = {}
	for _, o in list do
		local p = o.prompt
		if only and p.id ~= only then
			continue
		end
		table.insert(mine, {
			id = p.id,
			label = clip(printable(p.name), 120),
			detail = actionDetail(p, vars),
			group = if o.here and active then "For " .. clip(printable(active.name), 60) else "All actions",
			send = if withText then p.text else nil,
			model = p.model,
			worktree = p.worktree ~= false, -- where it runs: the item's worktree, else the main checkout
			split = if p.split then true else nil, -- its agent opens beside the queue; omitted: a tab of its own
			status = p.status, -- an issue action's Jira status to move to when its agent starts
			next = p.next, -- the action that starts when its agent finishes
			outcome = p.outcome, -- what its run must leave behind (prompts.OUTCOMES); omitted: none
			checker = p.checker, -- the action a fresh agent runs to check a run of it that ends with a commit
			key = p.key,
		})
	end
	return capped(mine, function(row)
		return #tern.json.encode(row)
	end), problem
end

local function menu(state: State, id: string, only: string?)
	local items, problem = menuRows(state, only, true)
	reply(state, id, { items = tern.json.array(items), problem = problem })
end

-- The hidden `main.palette` node, on every render: the command palette's and the agent picker's rows (saved actions
-- without their text, queue actions, window commands), so the window opens either without a round trip to this host.
-- `queue`: paletteActions(state), which keyBar shares.
function M.paletteNode(state: State, queue: { QueueAction }): Node
	local items, problem = menuRows(state, nil, false)
	local item = if state.boardOn or state.agentsOn or state.nowOn then nil else selected(state)
	local move = if item then engine.nextMove(state, state.kind.id, item) else nil
	-- The window command the Next move runs (`next`), when it is one: the window runs it as its own row would.
	local cmd = if move then string.match(move.id, "^cmd:(.+)$") else nil
	local text = tern.json.encode({ items = tern.json.array(items), problem = problem, queue = tern.json.array(queue), commands = tern.json.array(M.commands(state)), next = cmd })
	return ui.node("text", { key = "palette", text = text, hidden = true })
end

local KEY_BAR_MAX = 5
local KEY_BAR_FIRST = { more = 1, help = 2, next = 3 } -- Commands, Shortcut list, the Next move, in this order

-- The key footer under the queue: at most KEY_BAR_MAX keys that work now, each with what it does. From `queue`
-- (paletteActions(state)) plus Commands, the Agent picker and the selected item's saved actions with a key of their
-- own: Commands, Shortcut list and the Next move first, then the most used (this host's usage counts), ties in
-- Commands' order. An action with no key is not listed, and a key shows only what it runs: a saved action's key over a
-- built-in one only where it beats it (keys.YIELDS). Nil when no key is bound.
function M.keyBar(state: State, queue: { QueueAction }): Node?
	local map = keys.load()
	local u = usage.readUsage()
	local counts = if u then u.counts else {}
	local function used(id: string): number
		local c = counts[id]
		return if c then c.n else 0
	end
	local byKey: { [string]: KeyEntry } = {}
	local saved: { [string]: boolean } = {}
	local list: { KeyEntry } = {}
	local n = 0
	-- `use`: its usage count id; `first`: its place among KEY_BAR_FIRST, else after them.
	local function add(key: string, label: string, use: string, first: number?, isSaved: boolean)
		n += 1
		local e: KeyEntry = { key = key, label = label, first = first or 99, use = used(use), at = n }
		byKey[key] = e
		saved[key] = isSaved
		table.insert(list, e)
	end
	local item = if state.boardOn or state.agentsOn or state.nowOn then nil else selected(state)
	if item then
		-- The key handler runs the last offered action holding a key.
		local mine = offered(state)
		local last: { [string]: Prompt } = {}
		for _, o in mine do
			local p = o.prompt
			if p.key and p.key ~= "" and string.match(p.id, "^%w+$") then
				last[p.key] = p
			end
		end
		for _, o in mine do
			local p = o.prompt
			if p.key and last[p.key] == p then
				add(p.key, clip(printable(p.name), 40), "action:" .. p.name, nil, true)
			end
		end
	end
	local rows: { QueueAction } = { { id = "more", label = "Commands", key = map.more or "", group = "" } }
	if item then
		table.insert(rows, { id = "agent", label = "Agent picker", key = map.agent or "", group = "" })
	end
	for _, a in queue do
		table.insert(rows, a)
	end
	for _, a in rows do
		local held = byKey[a.key]
		if a.key == "" or (held and not saved[a.key]) or (held and keys.YIELDS[a.id]) then
			continue
		elseif held then
			-- A built-in key that is not one of keys.YIELDS runs before the saved action holding it.
			table.remove(list, table.find(list, held))
		end
		add(a.key, a.label, "queue:" .. a.id, KEY_BAR_FIRST[a.id], false)
	end
	table.sort(list, function(x: KeyEntry, y: KeyEntry): boolean
		if x.first ~= y.first then
			return x.first < y.first
		elseif x.use ~= y.use then
			return x.use > y.use
		end
		return x.at < y.at
	end)
	local nodes: { Node } = {}
	for i = 1, math.min(#list, KEY_BAR_MAX) do
		local e = list[i]
		table.insert(nodes, ui.node("text", { key = "k" .. i, spans = { ui.span(e.key, "key"), ui.span(" " .. e.label, "muted") } }))
	end
	return if #nodes > 0 then ui.node("row", { key = "keybar", role = "plotroom.keys", gap = "md", align = "center" }, nodes) else nil
end

-- Marks `key` busy and runs `open`, which starts a worktree and answers `id` itself; if it raises, the mark is cleared
-- and the request answers the problem.
local function startWorktree(state: State, id: string, key: string, open: () -> ())
	preparing[key] = true
	local started, err = pcall(function()
		process.reset()
		open()
	end)
	if not started then
		preparing[key] = nil
		reply(state, id, { problem = tostring(err) })
	end
end

-- Reads the users `go` needs (`jira`: the Jira one too) and calls it; a block gone meanwhile only clears `key`'s busy
-- mark (set when `wt`).
local function readUsers(state: State, key: string, wt: boolean, jira: boolean, go: ({ [string]: string }) -> ())
	me.read(state, jira, function(found)
		if alive(state) then
			go(found)
		elseif wt then
			preparing[key] = nil
		end
	end)
end

-- The `{failures}` block of `repo`#`n`: its checks read fresh, then each failing check's log, read once per head commit
-- (engine.failures); a checks read that fails says so in the block.
local function readFailures(state: State, repo: string, n: number, go: (string) -> ())
	github.checks(repo, n, login(state), function(runs, _, problem, about)
		local head = if about then about.head else nil
		if not runs or not about or not head then
			local why = if problem then problem.message else "GitHub named no head commit."
			return go("<failures>\nPlotroom could not read the checks: " .. clip(printable(why), 300) .. "\n</failures>")
		end
		engine.failures(state, repo, head, runs, about.files, function(list)
			go(logs.block(head, list, storage.PROMPT_CAP))
		end)
	end)
end

-- Creates or reuses the worktree of `repo`#`n` on the PR's own branch, in the folder the PR folder format names, and
-- notes the outcome; with `wt` false, answers the repository's main checkout as it is, reading only the PR's details.
-- Without a checkout of `repo` the answer asks the window for one. `users`: the answer carries `{github.user}` too,
-- and `failures` the `{failures}` block, for the prompt that runs there. `premerge`: an agent will resolve conflicts
-- there, so a clean worktree of a PR GitHub reports conflicting first gets its base merged (worktree.premerge), and the
-- answer carries what that did (`merge`).
local function prepare(state: State, id: string, repo: string, n: number, wt: boolean, users: boolean, failures: boolean, premerge: boolean)
	local failed: string? = nil
	local key = string.lower(repo) .. "#" .. n
	if wt and preparing[key] then
		return reply(state, id, { busy = true })
	end
	local checkout = checkoutOf(repo)
	if not checkout then
		return needCheckout(state, id, repo)
	end
	local function naming(meta: github.PrMeta): (string?, string?)
		return formats.prDir(repo, n, meta.title)
	end
	local function main(found: { [string]: string })
		github.pr(repo, n, login(state), function(meta, problem)
			if not alive(state) then
				return
			elseif not meta then
				return reply(state, id, { problem = if problem then problem.message else "Could not read the pull request." })
			end
			reply(state, id, {
				path = checkout,
				summary = "Checkout",
				created = false,
				current = true,
				branch = meta.ref,
				base = meta.baseRef,
				title = meta.title,
				author = meta.author,
				["github.user"] = found["github.user"],
				failures = failed,
			})
		end)
	end
	if wt then
		preparing[key] = true
	end
	local function open(found: { [string]: string })
		startWorktree(state, id, key, function()
			worktree.open(checkout, repo, n, naming, login(state), function(r, problem)
				preparing[key] = nil
				if not alive(state) then
					return
				end
				if problem == worktree.NO_REPO then
					return needCheckout(state, id, repo)
				end
				if not r then
					local why = problem or "Worktree failed"
					noteWorktree(state, key, "prs", nil, why)
					return reply(state, id, { problem = why })
				end
				local function answer(merge: worktree.Merge?)
					local current = r.head == r.prHead
					local summary = worktree.describe(r)
					noteWorktree(state, key, "prs", {
						root = r.root,
						repo = repo,
						path = r.path,
						branch = r.branch,
						ref = r.ref,
						current = current,
						dirty = r.dirty,
						ahead = r.ahead,
						summary = summary,
						update = worktree.update(r),
					}, nil)
					reply(state, id, {
						path = r.path,
						created = r.created,
						current = current,
						dirty = r.dirty,
						ahead = r.ahead,
						summary = if r.fork and r.created then summary .. " (setup skipped: fork PR)" else summary,
						setup = if r.created and not r.fork then setupLine(repo) else nil,
						remote = r.remote,
						branch = r.prRef,
						base = r.prBase,
						title = r.title,
						author = r.author,
						["github.user"] = found["github.user"],
						failures = failed,
						merge = merge,
					})
				end
				if not (premerge and r.conflicts and r.dirty == false and r.prBase ~= "") then
					return answer(nil)
				end
				preparing[key] = true -- a second request waits for the merge, as for the worktree
				worktree.premerge(r.path, r.remote, r.prBase, function(merge)
					preparing[key] = nil
					if alive(state) then
						answer(merge)
					end
				end)
			end)
		end)
	end
	local go: ({ [string]: string }) -> () = if wt then open else main
	local function start(found: { [string]: string })
		if not failures then
			return go(found)
		end
		readFailures(state, repo, n, function(text)
			if not alive(state) then
				if wt then
					preparing[key] = nil
				end
				return
			end
			failed = text
			go(found)
		end)
	end
	if not users then
		return start({})
	end
	readUsers(state, key, wt, false, start)
end

-- How the window answered an issue worktree's questions: a linked PR to check out, or a new branch (`fresh`) from `base`.
type IssueChoice = { pr: number?, fresh: boolean, base: string? }

-- Answers the window's request for issue `ref`'s checkout: its worktree (made first if needed), or, with `wt` false,
-- the repository's main checkout. Either way `vars` fill in the prompt that runs there (with `users`, `{github.user}`
-- and `{jira.user}` too). The repository is the GitHub issue's own; a Jira issue's is `target` (a repository of its
-- project), the project's only one, or asked for: the answer is needRepo (none mapped yet), chooseRepo (several) or
-- needCheckout. A new worktree is on the branch of the issue's linked PR when exactly one still has its branch
-- (choosePr asks among several: `choice.pr`, or `choice.fresh` for a new branch), else on a new branch from the base
-- chooseBase asks for (`choice.base`).
local function prepareIssue(state: State, id: string, repo: string, ref: string, wt: boolean, target: string?, choice: IssueChoice, users: boolean)
	local key = string.lower(repo) .. "#" .. ref
	local issue = loadedIssue(state, key)
	if not issue then
		return reply(state, id, { problem = "That issue is not loaded here any more; Refresh and try again." })
	end
	if wt and preparing[key] then
		return reply(state, id, { busy = true })
	end
	local code = issue.repo
	if issue.tracker == "jira" then
		local mapped = jiraReposOf(issue.repo)
		if target then
			local want = string.lower(target)
			local found: string? = nil
			for _, m in mapped do
				if string.lower(m) == want then
					found = m
				end
			end
			if not found then
				return reply(state, id, { problem = target .. " is not a repository of " .. issue.repo .. "." })
			end
			code = found
		elseif #mapped == 0 then
			local names: { string } = {}
			for name in readCheckouts() do
				if type(name) == "string" then
					table.insert(names, name)
				end
			end
			table.sort(names)
			return reply(state, id, { needRepo = true, project = issue.repo, repos = tern.json.array(names) })
		elseif #mapped == 1 then
			code = mapped[1]
		else
			return reply(state, id, { chooseRepo = true, project = issue.repo, repos = tern.json.array(mapped) })
		end
	end
	local checkout = checkoutOf(code)
	if not checkout then
		return needCheckout(state, id, code)
	end
	local vars = issueVars(issue, code)
	local fmt = formats.issueBranch(code)
	local need = users or (wt and me.named(fmt))

	-- No worktree yet and nothing chosen: the linked PRs whose branch is still there decide. While gh is off (a Jira
	-- issue) none are looked up: a new branch.
	local function undecided()
		if not cli.on("github") then
			preparing[key] = nil
			return prepareIssue(state, id, repo, ref, wt, target, { fresh = true }, users)
		end
		github.linkedPrs(code, issue.ref, login(state), function(prs, problem)
			preparing[key] = nil -- the read is over: what it found is asked or acted on next
			if not alive(state) then
				return
			end
			if not prs then
				return reply(state, id, { problem = "The pull requests linked to " .. tracker.refLabel(issue.ref) .. " could not be read: " .. (if problem then problem.message else "gh failed") })
			end
			local live: { any } = {}
			local same: { any } = {}
			for _, p in prs do
				if p.branch then
					local row = { number = p.number, title = clip(printable(p.title), 160), branch = p.branch, fork = if p.fork then clip(printable(p.fork), 100) else nil }
					table.insert(live, row)
					if not p.fork then
						table.insert(same, row)
					end
				end
			end
			-- A fork's pull request is never picked unasked: only a single same-repository one is.
			if #live == 0 then
				return prepareIssue(state, id, repo, ref, wt, target, { fresh = true }, users)
			elseif #same == 1 then
				return prepareIssue(state, id, repo, ref, wt, target, { pr = same[1].number, fresh = false }, users)
			end
			reply(state, id, { choosePr = true, prs = tern.json.array(live) })
		end)
	end

	-- A new branch that does not exist yet: the remote's branches to start it from.
	local function needBase(branch: string)
		worktree.remoteBranches(checkout, code, function(names, why)
			preparing[key] = nil -- the read is over: its answer is the question
			if not alive(state) then
				return
			end
			if why == worktree.NO_REPO then
				return needCheckout(state, id, code)
			end
			if not names then
				return reply(state, id, { problem = why or "The remote's branches could not be listed." })
			end
			local list = capped(names, function(b)
				return #b + 3
			end)
			reply(state, id, { chooseBase = true, branch = branch, branches = tern.json.array(list) })
		end)
	end

	local function go(found: { [string]: string })
		if need then
			vars["github.user"] = found["github.user"] or ""
			vars["jira.user"] = found["jira.user"] or ""
		end
		if not wt then
			return reply(state, id, { path = checkout, summary = "Checkout", created = false, current = true, vars = vars, code = code })
		end
		local branch, dir, why = engine.issueNames(issue, code, found)
		if not branch or not dir then
			preparing[key] = nil -- marked busy while the users were read
			return reply(state, id, { problem = why })
		end
		for _, u in { "github.user", "jira.user" } do
			if found[u] == "" and string.find(fmt, "{" .. u .. "}", 1, true) and (u == "github.user" or issue.tracker == "jira") then
				preparing[key] = nil
				local fix = if u == "jira.user" then "sign in with acli jira auth login" elseif cli.on("github") then "sign in with gh auth login" else "install gh (Settings › GitHub)"
				return reply(state, id, { problem = "The branch format names {" .. u .. "}, which could not be read: " .. fix .. ", or change the format in Settings › Repositories." })
			end
		end
		local made: string = branch
		startWorktree(state, id, key, function()
			local plan: worktree.IssuePlan = { dir = dir, branch = made, pr = choice.pr, fresh = choice.fresh, base = choice.base }
			worktree.openIssue(checkout, code, ref, plan, login(state), function(r, problem)
				if not alive(state) then
					preparing[key] = nil
					return
				end
				-- Still busy while gh or git is read for the question (undecided, needBase clear it when they answer).
				if problem == worktree.UNDECIDED then
					return undecided()
				elseif problem == worktree.NEED_BASE then
					return needBase(made)
				end
				preparing[key] = nil
				if problem == worktree.NO_REPO then
					return needCheckout(state, id, code)
				end
				if not r then
					local failed = problem or "Worktree failed"
					noteWorktree(state, key, "issues", nil, failed)
					return reply(state, id, { problem = failed })
				end
				local summary = worktree.describeIssue(r)
				noteWorktree(state, key, "issues", {
					root = r.root,
					repo = code,
					path = r.path,
					branch = r.branch,
					ref = r.ref,
					current = true,
					dirty = r.dirty,
					ahead = r.ahead,
					summary = summary,
					update = {},
				}, nil)
				vars.branch = r.branch
				vars.base = choice.base or ""
				vars.remote = r.remote
				reply(state, id, {
					path = r.path,
					created = r.created,
					current = true,
					dirty = r.dirty,
					ahead = r.ahead,
					summary = if r.fork and r.created then summary .. " (setup skipped: fork PR)" else summary,
					setup = if r.created and not r.fork then setupLine(code) else nil,
					vars = vars,
					code = code,
				})
			end)
		end)
	end

	if not need then
		return go({})
	end
	if wt then
		preparing[key] = true -- the users are read first: a repeat meanwhile is busy too
	end
	readUsers(state, key, wt, issue.tracker == "jira", go)
end

-- The repository picker's first page: every saved repository with its checkout, sorted by name, and the gh logins
-- signed in to github.com (none while gh is off), whose repositories the picker offers next (`profile`). Without the
-- logins, `problem` says why.
local function repos(state: State, id: string)
	local items: { any } = {}
	for name, path in readCheckouts() do
		if type(name) == "string" then
			table.insert(items, { repo = name, path = if type(path) == "string" and path ~= "" then path else nil })
		end
	end
	table.sort(items, function(a, b)
		return a.repo < b.repo
	end)
	if not cli.on("github") then
		return reply(state, id, { items = tern.json.array(items), accounts = tern.json.array({}) })
	end
	state.listing += 1
	github.accounts(function(accounts, problem)
		state.listing -= 1
		reply(state, id, { items = tern.json.array(items), accounts = tern.json.array(accounts or {}), problem = if problem then problem.message else nil })
	end)
end

-- The repository picker's second page: the repositories gh login `login` can access, most recently pushed first, cut
-- to MENU_BUDGET. Without them, `problem` says why.
local function profile(state: State, id: string, login: string)
	state.listing += 1
	github.repos(login, MENU_BUDGET, function(names, problem)
		state.listing -= 1
		reply(state, id, { repos = tern.json.array(names or {}), problem = if problem then problem.message else nil })
	end)
end

-- The Jira project picker's list: every saved project with its repositories, sorted by key, then the projects acli
-- lists that are not saved, cut to MENU_BUDGET. Without the list, `problem` says why.
local function jiraProjects(state: State, id: string)
	local keys: { string } = {}
	local map: { [string]: any } = (readMap("jira-repos", "Jira project repositories")) or {}
	for key in map do
		if type(key) == "string" and tracker.jiraProject(key) then
			table.insert(keys, key)
		end
	end
	table.sort(keys)
	local saved: { [string]: boolean } = {}
	for _, key in keys do
		saved[key] = true
	end
	jira.projects(function(listed, problem)
		local list: { { key: string, name: string } } = listed or {}
		local names: { [string]: string } = {}
		for _, p in list do
			names[p.key] = p.name
		end
		local rows: { any } = {}
		for _, key in keys do
			table.insert(rows, { key = key, name = names[key], repos = table.concat(jiraReposOf(key), ", "), saved = true })
		end
		for _, p in list do
			if not saved[p.key] then
				table.insert(rows, { key = p.key, name = p.name, saved = false })
			end
		end
		local items = capped(rows, function(row)
			return #tern.json.encode(row)
		end)
		reply(state, id, { items = tern.json.array(items), problem = if problem then problem.message else nil })
	end)
end

-- Verifies `raw` as a checkout of `repo` (a new or empty folder gets a clone) and saves it; the answer is {ok, root,
-- cloned} or {problem}.
local function claim(state: State, id: string, repo: string, raw: string)
	local path = worktree.expandPath(trim(raw), tern.getenv("HOME"))
	if not path then
		return reply(state, id, { problem = "That is not a usable path." })
	end
	local busy = engine.claimCheckout(state, repo, path, "A checkout of " .. repo .. " is already being set up; try again when it is done.", repo .. "'s checkout was changed or removed while it was being set up.", function(claimed, err)
		if err or not claimed then
			return reply(state, id, { problem = err })
		end
		reply(state, id, { ok = true, root = claimed.root, cloned = claimed.cloned })
	end)
	if busy then
		reply(state, id, { problem = busy })
	end
end

-- Adds `repo` to the repositories Jira project `project` is worked in, and lists it in Settings.
local function mapJira(state: State, id: string, project: string, repo: string)
	local lower = string.lower(repo)
	local err = editJiraRepos(function(map: { [string]: any }): string?
		local list = stringList(map[project])
		if not table.find(list, lower) then
			table.insert(list, lower)
		end
		map[project] = list
		return nil
	end)
	err = err or saveCheckout(lower, "", true)
	if not err then
		engine.propagate(state)
	end
	reply(state, id, if err then { problem = err } else { ok = true })
end

-- The item at `url` (a pull request, GitHub issue or Jira issue URL) shown in this block, whichever view is active:
-- selected in place when the active list already holds it, else in its pinned scope (pins accumulate; the other views
-- stay in the sidebar). false when `url` names no item, or when a new pin would pass PIN_CAP: then nothing changes.
function M.show(state: State, url: any, force: boolean?): boolean
	local pin = engine.pinView(url)
	if not pin then
		return false
	end
	local key = engine.pinKey(pin)
	local have = engine.pinFor(state.pins, key)
	local snap = state.snap
	-- `force` (open by URL, a created pull request) pins the item even when the shown list holds it, so it is the scope
	-- the block shows and saves; the link of an issue's pull request only selects it in place when it is listed (as the
	-- list is without a search, which showing clears). An item pinned already is the same pin (by key), never a second one.
	local query = state.query
	state.query = nil
	local shown = filtered(state)
	state.query = query
	local needsPin = force or not snap or snap.kind ~= pin.kind or indexOf(if shown then shown.items else {}, key) == 0 or activeView(state) == nil
	if needsPin and not have and #state.pins >= engine.PIN_CAP then
		state.cx:toast("error", "Pins are full", "Unpin one of the " .. engine.PIN_CAP .. " pinned items first.")
		return false
	end
	discardEdit(state)
	state.settings, state.help, state.query, state.focus, state.boardOn, state.agentsOn, state.nowOn = nil, false, nil, "list", false, false, false
	if needsPin then
		if not have then
			table.insert(state.pins, pin)
		end
		switchView(state, (have or pin).id)
	end
	engine.select(state, key)
	return true
end

-- Unpins the selected item. The other pins and the saved views stay; when the unpinned item's scope
-- was the one shown, the first saved view opens with nothing selected. false when that item is not pinned.
function M.unpin(state: State): boolean
	local chosen = selected(state)
	local pin = if chosen then engine.pinFor(state.pins, chosen.key) else nil
	local at = if pin then table.find(state.pins, pin) else nil
	if not pin or not at then
		return false
	end
	table.remove(state.pins, at)
	if state.activeId == pin.id then
		local first = state.views[1]
		switchView(state, if first then first.id else nil)
	end
	state.cx:toast("info", "Unpinned " .. pin.name)
	return true
end

function M.whyOf(problem: github.Problem?): string
	return if problem then problem.message else "It did not work."
end

-- The gh login an account-bound action runs as, settled once when the plan is made and passed to every later step: the
-- view's own login, else the login gh's active account resolved to; nil when neither is known (nothing is then sent).
function M.concrete(state: State): string?
	return login(state) or ghActive.login
end

-- Keeps `run` as the one plan waiting for the window's confirmation and answers with what to confirm. Nothing is sent
-- anywhere until the window answers `commit` with this token while the selection and the view are as they were.
function M.offer(state: State, id: string, item: any, confirm: { head: string, label: string, lines: { string } }, run: ((any) -> ()) -> ())
	M.seq += 1
	local token = string.format("p%d_%d_%d", os.time(), M.seq, math.random(100000, 999999))
	state.plan = { token = token, key = item.key, gen = state.gen, view = state.activeId, login = state.activeLogin, at = os.time(), run = run }
	reply(state, id, { token = token, confirm = { head = confirm.head, label = confirm.label, lines = tern.json.array(confirm.lines) } })
end

-- Runs the plan the window confirmed: only the one this block offered last, once, within five minutes, and only while the
-- same item is selected in the same view.
function M.commit(state: State, id: string, token: any)
	local plan = state.plan
	state.plan = nil
	if not plan or plan.token ~= token then
		return reply(state, id, { problem = "That confirmation is no longer valid; nothing was sent. Ask again." })
	end
	local chosen = selected(state)
	-- Now's plan holds while Now is shown; every other plan, while its item is the selected one.
	local here = if plan.key == NOW_KEY then state.nowOn else chosen ~= nil and chosen.key == plan.key
	if os.time() - plan.at > 300 then
		return reply(state, id, { problem = "That confirmation expired after 5 minutes; nothing was sent." })
	elseif plan.gen ~= state.gen or plan.view ~= state.activeId or plan.login ~= state.activeLogin or not here then
		return reply(state, id, { problem = "The selection or the view changed since you were asked; nothing was sent." })
	end
	plan.run(function(body: any)
		reply(state, id, body)
	end)
end

-- A finished mutation: the list reads the item again.
function M.landed(state: State, done: (any) -> (), problem: github.Problem?, message: string)
	if problem then
		return done({ problem = M.whyOf(problem) })
	end
	if alive(state) then
		changed(state)
	end
	done({ ok = true, message = message })
end

-- A copy of a list of strings for an answer.
function M.strings(list: { string }): any
	local out: { string } = {}
	for _, s in list do
		table.insert(out, s)
	end
	return tern.json.array(out)
end

-- The whole normalized text as confirmation rows, a row per 100 characters (newlines as ⏎); nil when it would not fit the
-- window's rows, so no tail goes unpreviewed.
function M.previewRows(body: string): { string }?
	local shown = string.gsub(body, "\n", " ⏎ ")
	local rows: { string } = {}
	local from, total = 1, utf8.len(shown) or #shown
	while from <= total do
		local a, b = utf8.offset(shown, from), utf8.offset(shown, from + 100)
		table.insert(rows, string.sub(shown, a, if b then b - 1 else #shown))
		from += 100
	end
	return if #rows > COMMENT_ROWS then nil else rows
end

local METHODS: { [string]: string } = {
	squash = "Squash and merge",
	merge = "Create a merge commit",
	rebase = "Rebase and merge",
}

-- The preview says the PR can merge now (ready or unstable): `gh pr merge --auto` would merge it at once, not wait for checks.
local function mergesNow(state: State, item: any): boolean
	local d = state.details[detailKey(state, item)]
	local merge = if d and d.about then d.about.merge else nil
	return merge == "ready" or merge == "unstable"
end

-- Push empty commit… applies: an open PR of the repository itself (not a fork's branch) with a known head whose preview
-- shows the branch neither behind its base (Update branch… covers that) nor in conflict, nor its merge state unknown.
local function emptyCommits(state: State, item: any): boolean
	local d = state.details[detailKey(state, item)]
	local merge = if d and d.about then d.about.merge else nil
	return item.state == "open" and item.fork == nil and type(item.headSha) == "string" and merge ~= nil and merge ~= "behind" and merge ~= "conflicts" and merge ~= "unknown"
end

-- Every notification thread Now read, while Now is shown and its Notifications reason is on: also those whose item Now
-- lists for a higher reason, a second thread on one item and a snoozed item's, so Mark all notifications read… leaves none unread.
local function unread(state: State): { github.Notice }
	return if state.nowOn and not state.now.prefs.off.notices then state.now.notices else {}
end

-- The plan of Now's Mark all notifications read…: every thread Now read (unread), grouped by the gh login each was read as (both
-- settled now: the commit marks exactly these, each as exactly its login, whatever the list or gh's active account
-- become) and one confirm naming every account. Read, never done: GitHub keeps the threads.
function M.markReadPlan(state: State, id: string)
	local logins: { string } = {}
	local idsOf: { [string]: { string } } = {}
	local perRepo: { [string]: number } = {}
	local repos: { string } = {}
	local n = 0
	for _, notice in unread(state) do
		local login = notice.login
		if login then
			if not idsOf[login] then
				idsOf[login] = {}
				table.insert(logins, login)
			end
			table.insert(idsOf[login], notice.id)
			n += 1
			local where = login .. " " .. notice.repo
			if not perRepo[where] then
				perRepo[where] = 0
				table.insert(repos, where)
			end
			perRepo[where] += 1
		end
	end
	if n == 0 then
		return reply(state, id, { problem = "Now lists no notifications to mark read." })
	end
	table.sort(logins)
	table.sort(repos)
	local several = #logins > 1
	local named: { string } = {}
	for _, login in logins do
		table.insert(named, "@" .. login)
	end
	local things = n .. " notification" .. (if n == 1 then "" else "s")
	local lines: { string } = { (if several then "Accounts: " else "Account: ") .. table.concat(named, ", "), "Mark " .. things .. " read (GitHub keeps them in the inbox; none is marked done)" }
	for i, where in repos do
		if i > 8 then
			table.insert(lines, "and " .. (#repos - 8) .. " more repositories")
			break
		end
		local login, repo = string.match(where, "^(%S+) (.*)$")
		table.insert(lines, (if several then "@" .. (login or "") .. " " else "") .. (repo or where) .. ": " .. perRepo[where])
	end
	M.offer(state, id, { key = NOW_KEY }, { head = "Mark " .. things .. " read?", label = "Mark " .. n .. " read", lines = lines }, function(done)
		local marked = 0
		local function finish(answer: any)
			if alive(state) then
				state.now.gen += 1 -- reads begun before this mark are stale; one fresh read replaces them
				state.now.busy = false
				engine.nowRead(state) -- Now reads again: what was marked is gone from it
			end
			done(answer)
		end
		-- Each login's threads as that login, one login after another; the first failure stops the rest.
		local function step(i: number)
			local login = logins[i]
			if login == nil then
				return finish({ ok = true, message = "Marked " .. things .. " read as " .. table.concat(named, " and ") })
			end
			github.markRead(idsOf[login], login, function(problem: github.Problem?, count: number)
				marked += count
				if problem then
					return finish({ problem = (if marked > 0 then "Marked " .. marked .. " of " .. n .. " read, then stopped: " else "") .. M.whyOf(problem) })
				end
				step(i + 1)
			end)
		end
		step(1)
	end)
end

-- The mutations of the selected item: asks for a confirmation (`offer`).
function M.act(state: State, id: string, q: any)
	local item, snap = selected(state), state.snap
	local function no(why: string)
		reply(state, id, { problem = why })
	end
	local function needAccount(): string?
		local account = M.concrete(state)
		if not account then
			no("Could not tell which GitHub account is active; Refresh, then try again.")
		end
		return account
	end
	if q.name == "mark-read" then
		return M.markReadPlan(state, id)
	elseif not item or not snap then
		return no("Select an item first.")
	end
	local name, prs = q.name, snap.kind == "prs"
	local target = if prs then item.repo .. "#" .. item.number else (if item.tracker == "jira" then item.ref else item.repo .. "#" .. item.ref)
	if name == "assign-me" then
		if prs then
			return no("Assigning works on issues; pull requests are not edited here.")
		elseif item.tracker == "jira" then
			local gen = state.gen
			return jira.identity(function(who: jira.Identity?, problem: github.Problem?)
				if not alive(state) then
					return
				elseif not who then
					return no(M.whyOf(problem))
				elseif state.gen ~= gen then
					return no("The view changed; ask again.")
				end
				M.offer(state, id, item, {
					head = "Assign " .. item.ref .. " to you?",
					label = "Assign to me",
					lines = { target .. ": " .. printable(item.title), "Jira account: " .. printable(who.email) .. " at " .. printable(who.site), "Current assignee: " .. (if #item.assignees > 0 then table.concat(item.assignees, ", ") else "none") },
				}, function(done)
					jira.assignMe(item.ref, who, function(problem2: github.Problem?)
						M.landed(state, done, problem2, "Assigned " .. item.ref .. " to you")
					end)
				end)
			end)
		end
		local account = needAccount()
		if not account then
			return
		end
		return M.offer(state, id, item, {
			head = "Assign " .. target .. " to you?",
			label = "Assign to me",
			lines = { target .. ": " .. printable(item.title), "Account: @" .. account, "Current assignees: " .. (if #item.assignees > 0 then table.concat(item.assignees, ", ") else "none") },
		}, function(done)
			github.editIssue({ repo = item.repo, number = tonumber(item.ref) :: number, addAssignees = { "@me" }, removeAssignees = {} }, account, function(problem: github.Problem?)
				M.landed(state, done, problem, "Assigned " .. target .. " to you")
			end)
		end)
	elseif name == "rerun-failed" then
		if not prs then
			return no("Failed checks are rerun on pull requests.")
		end
		local run, names = M.runPick(state, id, q, item, function(r: github.Run): boolean
			return r.status == "failure"
		end, "No failed check of this pull request has a GitHub Actions run to rerun. Its checks may still be loading.")
		if not run or not names then
			return
		end
		local account = needAccount()
		if not account then
			return
		end
		return M.offer(state, id, item, {
			head = "Rerun failed jobs of " .. target .. "?",
			label = "Rerun failed jobs",
			lines = {
				target .. ": " .. printable(item.title),
				"Account: @" .. account,
				"Rerun the failed jobs of workflow run " .. run .. " (" .. clip(table.concat(names, ", "), 100) .. ")",
			},
		}, function(done)
			github.rerunFailed(item.repo, run, account, function(problem: github.Problem?)
				M.landed(state, done, problem, "Rerunning the failed jobs of run " .. run .. " of " .. target)
			end)
		end)
	elseif name == "ignore-check" then
		if not prs then
			return no("Checks are ignored on pull requests.")
		end
		local failing: { string } = {}
		for _, r in engine.runsOf(state, item) do
			if r.status == "failure" and not engine.ignored(state, item, r) and not table.find(failing, r.name) then
				table.insert(failing, r.name)
			end
		end
		local check: any = q.check
		if check == nil and #failing == 1 then
			check = failing[1]
		end
		if check == nil then
			if #failing == 0 then
				return no("No failing check of this pull request is left to ignore. Its checks may still be loading.")
			end
			return reply(state, id, { checks = M.strings(failing) })
		elseif type(check) ~= "string" or not table.find(failing, check) then
			return no("That check is no longer failing on this pull request; nothing was saved.")
		end
		local picked: string = check
		local repo = item.repo
		return M.offer(state, id, item, {
			head = "Ignore " .. clip(printable(picked), 100) .. " in " .. repo .. "?",
			label = "Ignore check",
			lines = {
				"A pull request of " .. repo .. " whose only failing checks are ignored ones is not Blocked",
				"The check still shows failing, marked Ignored, and keeps it out of Ready to merge",
				"Remove it in Settings › Repositories",
			},
		}, function(done)
			local err = storage.editIgnored(repo, function(list: { string })
				if not table.find(list, picked) then
					table.insert(list, picked)
				end
			end)
			if err then
				return done({ problem = err })
			end
			if alive(state) then
				storage.loadAll(state)
				state.cx:render()
			end
			engine.propagate(state)
			done({ ok = true, message = "Ignoring " .. clip(printable(picked), 100) .. " in " .. repo })
		end)
	elseif name == "issue-close" or name == "issue-reopen" then
		if prs or item.tracker ~= "github" then
			return no("Closing and reopening works on GitHub issues.")
		end
		local close = name == "issue-close"
		if item.state ~= (if close then "open" else "closed") then
			return no(if close then "That issue is not open." else "That issue is not closed.")
		end
		local account = needAccount()
		if not account then
			return
		end
		return M.offer(state, id, item, {
			head = (if close then "Close " else "Reopen ") .. target .. "?",
			label = if close then "Close issue" else "Reopen issue",
			lines = { target .. ": " .. printable(item.title), "Account: @" .. account, if close then "Close the open issue (GitHub's default reason)" else "Reopen the closed issue" },
		}, function(done)
			github.setIssueState(item.repo, tonumber(item.ref) :: number, if close then "close" else "reopen", account, function(problem: github.Problem?)
				M.landed(state, done, problem, (if close then "Closed " else "Reopened ") .. target)
			end)
		end)
	elseif name == "pr-ready" or name == "pr-draft" then
		if not prs then
			return no("Draft state is for pull requests.")
		end
		local ready = name == "pr-ready"
		if item.state ~= "open" or item.draft ~= ready then
			return no(if ready then "That pull request is not an open draft." else "That pull request is not open and ready for review.")
		end
		local account = needAccount()
		if not account then
			return
		end
		return M.offer(state, id, item, {
			head = (if ready then "Mark " else "Convert ") .. target .. (if ready then " ready for review?" else " to a draft?"),
			label = if ready then "Ready for review" else "Convert to draft",
			lines = { target .. ": " .. printable(item.title), "Account: @" .. account, if ready then "Take it out of draft" else "Put it back in draft" },
		}, function(done)
			github.setPrReady(item.repo, item.number, ready, account, function(problem: github.Problem?)
				M.landed(state, done, problem, (if ready then "Marked ready for review: " else "Converted to draft: ") .. target)
			end)
		end)
	elseif name == "pr-merge" then
		if not prs then
			return no("Merging is for pull requests.")
		elseif item.state ~= "open" or item.draft then
			return no("That pull request is not open and ready for review.")
		elseif not item.headSha then
			return no("GitHub did not say which commit this pull request is at; Refresh, then try again.")
		end
		local account = needAccount()
		if not account then
			return
		end
		local method, auto = q.method, q.auto == true
		if method ~= nil and (type(method) ~= "string" or not METHODS[method]) then
			return no("That is not a merge method.")
		elseif auto and (item.checks ~= "pending" or mergesNow(state, item)) then
			return no("Auto-merge is offered while checks are pending and the pull request cannot merge yet.")
		end
		local key, gen = item.key, state.gen
		-- The methods are read from the repository's settings at both steps: only one it allows is ever planned.
		github.mergeMethods(item.repo, account, function(allowed: { string }?, problem: github.Problem?)
			if not alive(state) then
				return
			end
			local chosen = selected(state)
			if state.gen ~= gen or not chosen or chosen.key ~= key then
				return no("The selection changed; ask again.")
			elseif not allowed then
				return no(M.whyOf(problem))
			elseif #allowed == 0 then
				return no("The repository allows no merge method.")
			end
			if method == nil then
				local options: { any } = {}
				for _, m in allowed do
					table.insert(options, { id = m, label = METHODS[m] })
				end
				return reply(state, id, { methods = tern.json.array(options), auto = chosen.checks == "pending" and not mergesNow(state, chosen) })
			elseif not table.find(allowed, method) then
				return no("The repository does not allow that merge method.")
			end
			local sha = chosen.headSha
			if not sha or sha ~= item.headSha then
				return no("The pull request moved since you were asked; Refresh, then try again.")
			end
			local how: string = METHODS[method]
			M.offer(state, id, chosen, {
				head = (if auto then "Auto-merge " else "Merge ") .. target .. "?",
				label = if auto then "Merge when checks pass" else "Merge",
				lines = {
					target .. ": " .. printable(chosen.title),
					"Account: @" .. account,
					"Method: " .. how .. (if auto then " when checks pass" else ""),
					if auto then "Auto-merge is enabled with this commit; GitHub then merges a later push by anyone with write access once checks pass" else "Only commit " .. string.sub(sha, 1, 7) .. " is merged; a push since refuses it",
					"The branch is kept",
				},
			}, function(done)
				github.setPrMerge(item.repo, item.number, method, auto, sha, account, function(problem2: github.Problem?)
					M.landed(state, done, problem2, (if auto then "Auto-merge enabled: " else "Merged: ") .. target)
				end)
			end)
		end)
		return
	elseif name == "pr-approve" or name == "pr-request-changes" then
		if not prs then
			return no("Reviews are for pull requests.")
		elseif item.state ~= "open" then
			return no("That pull request is not open.")
		end
		local approve = name == "pr-approve"
		local body = if q.text == nil then nil else github.commentText(q.text)
		if q.text ~= nil and not body then
			return no("A comment is plain text without control characters, up to 4000 characters.")
		elseif not approve and not body then
			return no("Requesting changes needs a comment.")
		end
		local rows = if body then M.previewRows(body) else {}
		if not rows then
			return no("That comment is too long to show in full for confirmation; shorten it.")
		end
		local account = needAccount()
		if not account then
			return
		end
		local lines = { target .. ": " .. printable(item.title), "Account: @" .. account }
		if body then
			table.insert(lines, "Comment (" .. (utf8.len(body) or #body) .. " characters):")
			table.move(rows, 1, #rows, #lines + 1, lines)
		else
			table.insert(lines, "No comment")
		end
		return M.offer(state, id, item, {
			head = (if approve then "Approve " else "Request changes on ") .. target .. "?",
			label = if approve then "Approve" else "Request changes",
			lines = lines,
		}, function(done)
			github.reviewPr(item.repo, item.number, approve, body, account, function(problem: github.Problem?)
				M.landed(state, done, problem, (if approve then "Approved " else "Requested changes on ") .. target)
			end)
		end)
	elseif name == "pr-update-branch" then
		if not prs then
			return no("Updating a branch is for pull requests.")
		end
		local d = state.details[detailKey(state, item)]
		if item.state ~= "open" or not d or not d.about or d.about.merge ~= "behind" then
			return no("That pull request is not open and behind its base branch.")
		end
		local account = needAccount()
		if not account then
			return
		end
		return M.offer(state, id, item, {
			head = "Update the branch of " .. target .. "?",
			label = "Update branch",
			lines = { target .. ": " .. printable(item.title), "Account: @" .. account, "Merge " .. printable(item.base) .. " into " .. printable(item.head) .. " (GitHub's default update)" },
		}, function(done)
			github.updatePrBranch(item.repo, item.number, account, function(problem: github.Problem?)
				M.landed(state, done, problem, "Updated the branch of " .. target)
			end)
		end)
	elseif name == "pr-empty-commit" then
		if not prs then
			return no("Empty commits are for pull requests.")
		elseif not emptyCommits(state, item) then
			return no("That pull request is not open with its own branch up to date and free of conflicts; Update branch… covers a branch behind its base.")
		end
		local account = needAccount()
		if not account then
			return
		end
		local sha: string = item.headSha
		return M.offer(state, id, item, {
			head = "Push an empty commit to " .. target .. "?",
			label = "Push empty commit",
			lines = {
				target .. ": " .. printable(item.title),
				"Account: @" .. account,
				"Branch: " .. printable(item.head),
				"Head: " .. string.sub(sha, 1, 7) .. "; the new commit has its tree and it as parent, so checks run again",
				"Refused if the branch moved since",
			},
		}, function(done)
			github.emptyCommit(item.repo, item.number, item.head, sha, account, function(problem: github.Problem?)
				M.landed(state, done, problem, "Pushed an empty commit to " .. target)
			end)
		end)
	elseif name == "comment" then
		local body = github.commentText(q.text)
		if not body then
			return no("A comment is plain text without control characters, up to 4000 characters.")
		end
		local isJira = not prs and item.tracker == "jira"
		local account = if isJira then nil else needAccount()
		if not isJira and not account then
			return
		end
		local rows = M.previewRows(body)
		if not rows then
			return no("That comment is too long to show in full for confirmation; shorten it.")
		end
		-- `who` is the Jira account (full email and site) acli runs as, read now and read again at commit by jira.comment:
		-- the comment is never sent as another account or to another site.
		local function offerComment(who: jira.Identity?)
			local lines = { target .. ": " .. printable(item.title), if who then "Jira account: " .. printable(who.email) .. " at " .. printable(who.site) else "Account: @" .. (account :: string), "Comment (" .. (utf8.len(body) or #body) .. " characters):" }
			table.move(rows, 1, #rows, #lines + 1, lines)
			M.offer(state, id, item, { head = "Comment on " .. target .. "?", label = "Add comment", lines = lines }, function(done)
				local function landed(problem: github.Problem?)
					M.landed(state, done, problem, "Commented on " .. target)
				end
				if not who then
					return github.comment(item.repo, if prs then item.number else tonumber(item.ref) :: number, body, account, landed)
				end
				jira.comment(item.ref, body, who, landed)
			end)
		end
		if not isJira then
			return offerComment(nil)
		end
		local gen = state.gen
		return jira.identity(function(who: jira.Identity?, problem: github.Problem?)
			if not alive(state) then
				return
			end
			local chosen = selected(state)
			if not who then
				return no(M.whyOf(problem))
			elseif state.gen ~= gen or not chosen or chosen.key ~= item.key then
				return no("The selection changed; ask again.")
			end
			offerComment(who)
		end)
	end
	no("Plotroom does not know that command.")
end

-- The workflow run a mutation acts on among the item's checks `keep` lets through: its id and its checks' names, or nil
-- after answering (a problem when there is none, the list of runs to pick from when there are several).
function M.runPick(state: State, id: string, q: any, item: any, keep: (github.Run) -> boolean, none: string): (string?, { string }?)
	local ids: { string } = {}
	local names: { [string]: { string } } = {}
	for _, r in engine.runsOf(state, item) do
		local run = r.runId
		if run and keep(r) then
			if not names[run] then
				names[run] = {}
				table.insert(ids, run)
			end
			table.insert(names[run], r.name)
		end
	end
	if #ids == 0 then
		reply(state, id, { problem = none })
		return nil, nil
	end
	local run: string? = q.run
	if run == nil and #ids == 1 then
		run = ids[1]
	end
	if run == nil then
		local listed: { any } = {}
		for i, rid in ids do
			if i <= 100 then
				table.insert(listed, { id = rid, label = "Run " .. rid .. ": " .. clip(table.concat(names[rid], ", "), 100) })
			end
		end
		reply(state, id, { runs = tern.json.array(listed) })
		return nil, nil
	end
	local picked: string = run
	if not names[picked] then
		reply(state, id, { problem = "That workflow run is no longer one this action applies to; nothing was sent." })
		return nil, nil
	end
	return picked, names[picked]
end

-- The window commands (flows.COMMANDS ids) that apply to what is selected now: nothing is offered that the selected
-- item, its tracker or its checks cannot take. The window's palette lists exactly these (answer to `menu` with `palette`).
-- An item's own operation carries the heading of its type (`group`: "GitHub - PR", "GitHub - Issue" or "Jira - Issue");
-- without one the command's own heading in flows.COMMANDS stands.
function M.commands(state: State): { { id: string, group: string? } }
	local out: { { id: string, group: string? } } = { { id = "open-url" }, { id = "get-started" }, { id = "usage-report" } }
	if #unread(state) > 0 then
		table.insert(out, { id = "mark-read", group = "Now" })
	end
	local item, snap = if state.boardOn or state.agentsOn or state.nowOn then nil else selected(state), state.snap
	if not item or not snap then
		return out
	end
	local group = if snap.kind == "prs" then "GitHub - PR" elseif item.tracker == "jira" then "Jira - Issue" else "GitHub - Issue"
	local function add(cmd: string)
		table.insert(out, { id = cmd, group = group })
	end
	if snap.kind == "prs" then
		if engine.rerunnable(state, item) then
			add("rerun-failed")
		end
		for _, r in engine.runsOf(state, item) do
			if r.status == "failure" and not engine.ignored(state, item, r) then
				add("ignore-check")
				break
			end
		end
		if item.state == "open" then
			add(if item.draft then "pr-ready" else "pr-draft")
			if not item.draft and item.headSha then
				add("pr-merge")
			end
			add("pr-approve")
			add("pr-request-changes")
			local d = state.details[detailKey(state, item)]
			if d and d.about and d.about.merge == "behind" then
				add("pr-update-branch")
			end
			if emptyCommits(state, item) then
				add("pr-empty-commit")
			end
		end
		add("comment")
		return out
	end
	add("assign-me")
	if item.tracker ~= "jira" then
		add(if item.state == "open" then "issue-close" else "issue-reopen")
	end
	add("comment")
	local note = state.notes[item.key]
	if note and note.ok and note.root and note.path then
		add("draft-pr")
	end
	return out
end

-- The URLs of the pins, in order, for the block's save; nil when there are none.
function M.pinUrls(state: State): { string }?
	local urls: { string } = {}
	for _, p in state.pins do
		table.insert(urls, p.query)
	end
	return if #urls > 0 then urls else nil
end

-- The repository whose saved checkout is `root`, nil when none is.
function M.repoOfRoot(root: string): string?
	for repo, path in readCheckouts() do
		if path == root and type(repo) == "string" then
			return repo
		end
	end
	return nil
end

-- The guided draft pull request (issues with a worktree): `info` the base choices, `preview` what a draft from the
-- worktree's branch holds, `plan` the title and body to confirm. The commit step pushes (never forced, never commits)
-- and creates a draft pull request, after reading the branch and base again: what was confirmed is what is sent.
function M.draft(state: State, id: string, q: any)
	local item, snap = selected(state), state.snap
	local function no(why: string)
		reply(state, id, { problem = why })
	end
	local function needAccount(): string?
		local account = M.concrete(state)
		if not account then
			no("Could not tell which GitHub account is active; Refresh, then try again.")
		end
		return account
	end
	if not item or not snap or snap.kind ~= "issues" then
		return no("Select an issue that has a worktree: the draft starts from its branch.")
	end
	local note = state.notes[item.key]
	local root, path = if note then note.root else nil, if note then note.path else nil
	if not note or not note.ok or not root or not path then
		return no("Make a worktree for " .. item.key .. " first (the Worktree button); the draft starts from its branch.")
	end
	local gen = state.gen
	-- The repositories a draft may target: the GitHub remotes of this worktree's checkout, read again by every step, so a
	-- repository the window names is only ever one of them (never typed text); the saved repository of the checkout first.
	local saved = M.repoOfRoot(root)
	local function destinations(done: ({ { repo: string, remote: string } }) -> ())
		worktree.draftDestinations(path, function(list, problem)
			if not alive(state) then
				return
			elseif state.gen ~= gen then
				return no("The view changed; ask again.")
			elseif not list or #list == 0 then
				return no(problem or "That worktree has no GitHub remote to open a pull request on.")
			end
			local ordered: { { repo: string, remote: string } } = {}
			for _, d in list do
				if saved and string.lower(d.repo) == string.lower(saved) then
					table.insert(ordered, 1, d)
				else
					table.insert(ordered, d)
				end
			end
			done(ordered)
		end)
	end
	-- The destination `q.repo` names among `list`; false (and a refusal) when it is none of them.
	local function chosen(list: { { repo: string, remote: string } }): { repo: string, remote: string }?
		if type(q.repo) == "string" then
			for _, d in list do
				if string.lower(d.repo) == string.lower(q.repo) then
					return d
				end
			end
		end
		no("That repository is not one of this worktree's GitHub remotes; nothing was prepared.")
		return nil
	end
	if q.phase == "info" then
		destinations(function(list)
			local out: { any } = {}
			for i, d in list do
				table.insert(out, { repo = d.repo, remote = d.remote })
			end
			reply(state, id, { destinations = tern.json.array(out), repo = list[1].repo, branch = note.branch, path = path })
		end)
	elseif q.phase == "bases" then
		destinations(function(list)
			local d = chosen(list)
			if not d then
				return
			end
			worktree.remoteBranches(root, d.repo, function(names, problem)
				if not alive(state) then
					return
				elseif state.gen ~= gen then
					return no("The view changed; ask again.")
				elseif not names or #names == 0 then
					return no(if problem == worktree.NO_REPO then "That worktree's folder is not a checkout of " .. d.repo .. "." else (problem or "The repository's branches could not be listed."))
				end
				local bases: { string } = {}
				for i, n in names do
					if i <= 50 then
						table.insert(bases, n)
					end
				end
				reply(state, id, { repo = d.repo, remote = d.remote, bases = M.strings(bases), defaultBase = bases[1] })
			end)
		end)
	elseif q.phase == "preview" then
		local base = q.base
		if type(base) ~= "string" or #base > 255 or string.find(base, "^%-") or string.find(base, "[%c%s]") then
			return no("That is not a branch name.")
		end
		destinations(function(list)
			local d = chosen(list)
			if not d then
				return
			end
			local repo = d.repo
			worktree.draftPreview(path, repo, base, function(draft, problem)
				if not alive(state) then
					return
				elseif state.gen ~= gen then
					return no("The view changed; ask again.")
				end
				if not draft then
					return no(problem or "The branch could not be read.")
				end
				local body = if item.tracker == "github" and string.lower(item.repo) == string.lower(repo) then "Closes #" .. item.ref else "Issue: " .. item.url
				M.seq += 1
				local token = string.format("d%d_%d", os.time(), M.seq)
				state.draft = { token = token, key = item.key, draft = draft, body = body, gen = gen }
				reply(state, id, {
					draft = true,
					token = token,
					repo = repo,
					title = draft.title,
					body = body,
					commits = M.strings(draft.commits),
					branch = draft.branch,
					base = draft.base,
					remote = draft.remote,
					count = draft.count,
					needsPush = draft.needsPush,
					dirty = draft.dirty,
				})
			end)
		end)
	elseif q.phase == "plan" then
		local d = state.draft
		local title, body = q.title, q.body
		if not d or d.token ~= q.token or d.key ~= item.key or d.gen ~= state.gen then
			return no("Preview the draft again: the selection or the view changed.")
		end
		if type(body) == "string" and #body > 8000 then
			return no("The description is too long (8000 bytes at most).")
		end
		-- The same check createPr makes: a title or body it would refuse must not reach the push.
		local why = github.prText(if type(title) == "string" then trim(title) else title, body)
		if why then
			return no(why)
		end
		local draft = d.draft
		-- The account is settled now and used by every later step, whatever view is shown meanwhile.
		local account = needAccount()
		if not account then
			return
		end
		local lines: { string } = {
			"Repository: " .. draft.repo,
			"Branch: " .. draft.branch .. " → " .. draft.base .. " (" .. draft.count .. " commit" .. (if draft.count == 1 then "" else "s") .. ")",
			"Title: " .. title,
			"Opens a draft pull request, as @" .. account,
		}
		if draft.needsPush then
			table.insert(lines, 2, "First pushes " .. draft.branch .. " to " .. draft.remote .. " (never forced)")
		end
		if draft.dirty then
			table.insert(lines, "Uncommitted changes in the worktree are not included; nothing is committed")
		end
		M.offer(state, id, item, { head = "Create a draft pull request?", label = if draft.needsPush then "Push and create draft" else "Create draft", lines = lines }, function(done)
			-- The branch, its head and the base are read again: a commit or a fetch since the preview cancels it.
			worktree.draftPreview(draft.path, draft.repo, draft.base, function(fresh, problem)
				if not fresh then
					return done({ problem = problem or "The branch could not be read again; nothing was sent." })
				elseif fresh.head ~= draft.head or fresh.branch ~= draft.branch or fresh.baseSha ~= draft.baseSha or fresh.remote ~= draft.remote or fresh.needsPush ~= draft.needsPush then
					return done({ problem = "The branch or its base moved since the preview; nothing was pushed or created. Preview again." })
				end
				local function create()
					github.createPr({ repo = draft.repo, base = draft.base, head = draft.branch, title = trim(title), body = body, draft = true }, account, function(url, problem2)
						if not url then
							return done({ problem = M.whyOf(problem2) })
						end
						if alive(state) then
							if state.draft == d then -- a draft previewed meanwhile is not the one this plan made
								state.draft = nil
							end
							M.show(state, url, true)
							state.cx:save() -- landed outside an event: persist the pin now
							state.cx:render()
						end
						done({ ok = true, url = url, message = "Draft pull request created: " .. url })
					end)
				end
				if fresh.needsPush then
					worktree.pushBranch(fresh, function(perr)
						if perr then
							return done({ problem = perr })
						end
						create()
					end)
				else
					create()
				end
			end)
		end)
	else
		no("Plotroom does not know that step.")
	end
end

-- Opens the item at `url` in this block: fetched first (gh or acli), so a missing or foreign item is reported, then shown
-- as the pin. Nothing is opened in a browser. `done(problem, message)` tells the outcome: a window request replies with it,
-- a paste toasts it.
function M.openUrl(state: State, url: any, done: (string?, string?) -> ())
	local pin = engine.pinView(url)
	if not pin then
		return done("That is not a GitHub pull request or issue URL, or a Jira issue URL.")
	elseif not cli.on(pin.integration) then
		return done((if pin.integration == "github" then "The GitHub CLI (gh)" else "The Atlassian CLI (acli)") .. " does not start on this host.")
	end
	engine.fetchPin(state, pin, function(): boolean
		return alive(state)
	end, function(result: any, problem: github.Problem?)
		if not alive(state) then
			return
		end
		if not result then
			return done(M.whyOf(problem))
		end
		-- What was fetched is shown at once; the pin's own refresh follows.
		local items = if pin.kind == "issues" then result.issues else result.prs
		if #items == 0 then
			return done("No " .. (if pin.kind == "issues" then "issue" else "pull request") .. " was found at that URL (it does not exist or this account cannot see it).")
		end
		state.snaps[snapKey(pin, nil)] = { kind = pin.kind, items = items, total = result.total, complete = result.complete, fetched = os.time() }
		if not M.show(state, pin.query, true) then
			return done("Pins are full: unpin one of the " .. engine.PIN_CAP .. " pinned items first.")
		end
		state.cx:save() -- this landed outside a key or event: the pin is persisted now
		done(nil, "Showing " .. pin.name .. " in Plotroom")
	end)
end

-- A paste into the queue (not while searching): opens the first item URL in `text` as Open item by URL does, the answer
-- a toast; text with none says so.
function M.paste(state: State, text: string)
	local found: string? = nil
	for url in string.gmatch(text, "https?://[^%s<>\"']+") do
		local clean = string.gsub(url, "[%.,;:!%?%)%]}]+$", "")
		if not found and #clean <= 2048 and engine.pinView(clean) then
			found = clean
		end
	end
	if not found then
		return state.cx:toast("info", "No item URL pasted", "Paste a GitHub pull request or issue URL, or a Jira issue URL.")
	end
	M.openUrl(state, found, function(problem: string?, message: string?)
		if problem then
			state.cx:toast("error", "Could not open the item", problem)
		else
			state.cx:toast("success", message or "Opened")
		end
		state.cx:render()
	end)
end

-- The selected item's link, number (`#N`, or the Jira key) and branch (a pull request's head, else its worktree's); the
-- branch is nil when it has none.
function M.copyTexts(state: State): { link: string, number: string, branch: string? }?
	local item = selected(state)
	if not item or state.boardOn or state.agentsOn then
		return nil
	end
	local prs = state.kind.id ~= "issues"
	local note = state.notes[item.key]
	local branch: string? = if prs and type(item.head) == "string" then item.head elseif note and note.ok then note.branch else nil
	local number = if prs then "#" .. item.number elseif item.tracker == "jira" then item.ref else "#" .. item.ref
	return { link = item.url, number = number, branch = if branch and branch ~= "" then branch else nil }
end

-- Copies the selected item's `what` ("copy-link", "copy-number" or "copy-branch"); false when it has none.
function M.copy(state: State, what: string): boolean
	local t = M.copyTexts(state)
	local text = if not t then nil elseif what == "copy-link" then t.link elseif what == "copy-number" then t.number else t.branch
	if not text then
		return false
	end
	state.cx:copy(text)
	state.cx:toast("success", "Copied", text)
	return true
end

-- Window requests of flows.luau's workflows (rpc's last branch).
function M.workflowRpc(state: State, id: string, q: any)
	local op = q.op
	if op == "act" and type(q.name) == "string" then
		M.act(state, id, q)
	elseif op == "commit" and type(q.token) == "string" then
		M.commit(state, id, q.token)
	elseif op == "draft" and type(q.phase) == "string" then
		M.draft(state, id, q)
	elseif op == "open-url" and type(q.url) == "string" and #q.url <= 2048 then
		M.openUrl(state, q.url, function(problem: string?, message: string?)
			reply(state, id, if problem then { problem = problem } else { ok = true, message = message })
		end)
	elseif op == "worktree-path" and type(q.n) == "number" then
		local row = engine.boardRows(state)[q.n]
		reply(state, id, if row and not row.missing and tern.fs.exists(row.path) then { path = row.path } else { problem = "That worktree is no longer listed." })
	elseif op == "git-path" then
		-- The worktree Open in Git is about: the Worktrees list's selected row, else the selected item's card.
		local row = if state.boardOn then engine.boardSelected(state) else nil
		local path = if state.boardOn then (if row and not row.missing and tern.fs.exists(row.path) then row.path else nil) else engine.cardPath(state)
		reply(state, id, if path then { path = path } else { problem = "That worktree is no longer there." })
	end
end

-- Moves Jira issue `ref` to the status named `status`, as an action's setting asks when its agent starts: nothing when
-- the issue is there already (compared case-insensitively), else `acli jira workitem transition --status`, so no API
-- token is needed. Replies {moved = <status>}, {already = true}, {skipped = true} (not a Jira key) or {problem}. No
-- confirm: the action's status is the user's own setting. acli's refusal (no such status, a transition that needs
-- fields) is the problem.
local function moveStatus(state: State, id: string, ref: string, status: string)
	if not string.match(ref, "^[A-Z][A-Z0-9_]*%-%d+$") then
		return reply(state, id, { skipped = true })
	end
	local want = string.lower(status)
	jira.item(ref, function(issue, problem)
		if not issue then
			return reply(state, id, { problem = M.whyOf(problem) })
		elseif issue.status and string.lower(issue.status.text) == want then
			return reply(state, id, { already = true })
		end
		jira.moveTo(ref, status, function(problem2: github.Problem?)
			if problem2 then
				return reply(state, id, { problem = M.whyOf(problem2) })
			end
			reply(state, id, { moved = status })
		end)
	end)
end

-- One request from the window. Untrusted shape: anything malformed is dropped (the window gives up waiting).
function M.rpc(state: State, raw: any)
	if type(raw) ~= "string" or #raw > 120000 then
		return
	end
	local ok, q = pcall(tern.json.decode, raw)
	if not ok or not isTable(q) or type(q.id) ~= "string" or not string.match(q.id, "^%w+$") or #q.id > 40 then
		return
	end
	local id: string = q.id
	if q.op == "action" and (q.kind == "pr" or q.kind == "issue") and type(q.pid) == "string" and #q.pid <= 64 then
		-- One saved action by id, whatever view offers it: what a finished agent's next action runs. With `repo` and
		-- `branch` (a pull request action after an issue's): also the open or draft pull request of that repository whose
		-- head is the branch, as `pr`; any other answer is a problem, and nothing runs.
		local store, why = loadPrompts(if q.kind == "pr" then KINDS.prs else KINDS.issues)
		local p = if store then promptById(store, q.pid) else nil
		if not p or p.text == "" then
			return reply(state, id, { problem = why or "That action no longer exists." })
		end
		local answer = { label = clip(printable(p.name), 120), send = p.text, model = p.model, worktree = p.worktree ~= false, split = if p.split then true else nil, status = p.status, next = p.next, outcome = p.outcome, checker = p.checker, pr = nil :: number? }
		if q.repo == nil and q.branch == nil then
			return reply(state, id, answer)
		end
		local repo = if q.kind == "pr" then parseRepo(q.repo) else nil
		local branch = q.branch
		if not repo or type(branch) ~= "string" or branch == "" or #branch > 255 or string.find(branch, "%c") then
			return
		end
		github.pullByHead(repo, branch, login(state), function(pr, problem)
			if not alive(state) then
				return
			elseif problem then
				return reply(state, id, { problem = "The pull request of " .. branch .. " could not be looked up: " .. M.whyOf(problem) })
			elseif not pr then
				return reply(state, id, { problem = "No pull request of " .. repo .. " has " .. branch .. " as its branch." })
			elseif pr.state ~= "open" and pr.state ~= "draft" then
				return reply(state, id, { problem = "The pull request of " .. branch .. " (#" .. pr.number .. ") is " .. pr.state .. ", not open." })
			end
			answer.pr = pr.number
			reply(state, id, answer)
		end)
	elseif q.op == "menu" then
		menu(state, id, if type(q.only) == "string" then q.only else nil)
	elseif q.op == "repos" then
		repos(state, id)
	elseif q.op == "profile" and type(q.login) == "string" and string.match(q.login, "^[%w%-_]+$") then
		profile(state, id, q.login)
	elseif q.op == "worktree" then
		local repo = parseRepo(q.repo)
		local n = q.number
		if not repo then
			return
		end
		if type(n) ~= "number" or n < 1 or n > 2147483647 or n ~= math.floor(n) then
			return
		end
		if q.worktree ~= nil and type(q.worktree) ~= "boolean" then
			return
		end
		prepare(state, id, repo, n, q.worktree ~= false, q.users == true, q.failures == true, q.premerge == true)
	elseif q.op == "checkout" then
		local repo = parseRepo(q.repo)
		local path = q.path
		if not repo or type(path) ~= "string" or #path > 4096 or trim(path) == "" then
			return
		end
		claim(state, id, repo, path)
	elseif q.op == "map-jira" then
		local repo = parseRepo(q.repo)
		local project = q.project
		if type(project) ~= "string" or not tracker.jiraProject(project) then
			return
		end
		if not repo then
			return reply(state, id, { problem = "Type it as owner/name." })
		end
		mapJira(state, id, project, repo)
	elseif q.op == "jira-projects" then
		jiraProjects(state, id)
	elseif q.op == "issue" then
		local repo, ref = q.repo, q.ref
		-- A GitHub repository or a Jira project key: the link's repository is whatever the window was handed.
		if type(repo) ~= "string" or not worktree.validProject(repo) then
			return
		end
		if type(ref) ~= "string" or #ref > 64 or not string.match(ref, "^[%w_%-]+$") or type(q.worktree) ~= "boolean" then
			return
		end
		local target: string? = nil
		if q.target ~= nil then
			target = parseRepo(q.target)
			if not target then
				return
			end
		end
		local pr, base = q.pr, q.base
		if pr ~= nil and (type(pr) ~= "number" or pr < 1 or pr > 2147483647 or pr ~= math.floor(pr)) then
			return
		end
		-- git checks the name itself; this only keeps options and odd bytes out of its argv.
		if base ~= nil and (type(base) ~= "string" or #base > 255 or string.find(base, "^%-") or string.find(base, "[%c%s]")) then
			return
		end
		prepareIssue(state, id, repo, ref, q.worktree, target, { pr = pr, fresh = q.fresh == true, base = base }, q.users == true)
	elseif q.op == "criteria" and type(q.repo) == "string" and worktree.validProject(q.repo) and type(q.ref) == "string" and #q.ref <= 64 and string.match(q.ref, "^[%w_%-]+$") then
		-- The acceptance criteria of a loaded issue, read fresh from its tracker when a run is dispatched
		-- (tracker.criteria): {criteria} ("" for an empty description), or {problem}.
		local issue = loadedIssue(state, string.lower(q.repo) .. "#" .. q.ref)
		if not issue then
			return reply(state, id, { problem = "That issue is not loaded here any more." })
		end
		local found: tracker.Issue = issue
		local function got(detail: tracker.IssueDetail?, problem: github.Problem?)
			if not alive(state) then
				return
			elseif not detail then
				return reply(state, id, { problem = "Its description could not be read: " .. (if problem then M.whyOf(problem) else "no answer") })
			end
			reply(state, id, { criteria = tracker.criteria(found.tracker, detail.body) })
		end
		if found.tracker == "jira" then
			jira.issue(found.ref, got)
		else
			github.issue(found.repo, tonumber(found.ref) :: number, login(state), got)
		end
	elseif q.op == "move-status" and type(q.ref) == "string" and #q.ref <= 64 and type(q.status) == "string" and q.status ~= "" and #q.status <= core.STATUS_CAP then
		moveStatus(state, id, q.ref, q.status)
	elseif q.op == "where" and (q.kind == "pr" or q.kind == "issue") and type(q.key) == "string" and #q.key <= 200 then
		-- The worktree folder of an item as its note has it (git's list or the last attempt), for the window's Go to tab:
		-- a note of the kind asked about.
		local note = state.notes[q.key]
		reply(state, id, { path = if note and note.ok and note.kind == (if q.kind == "pr" then "prs" else "issues") then note.path else nil })
	elseif q.op == "outcome" then
		-- Checks what a run left behind on GitHub as the run's login (github.outcome): {verdict, why?}.
		local repo, n, branch, commit = parseRepo(q.repo), q.number, q.branch, q.commit
		local function textOk(v: any, cap: number): boolean
			return v == nil or (type(v) == "string" and v ~= "" and #v <= cap and not string.find(v, "%c"))
		end
		if
			not repo
			or type(q.outcome) ~= "string"
			or type(q.login) ~= "string"
			or #q.login > 64
			or type(q.since) ~= "number"
			or (n ~= nil and not (type(n) == "number" and n >= 1 and n == math.floor(n)))
			or not textOk(branch, 255)
			or not (commit == nil or (type(commit) == "string" and string.match(commit, "^%x+$") and (#commit == 40 or #commit == 64)))
		then
			return reply(state, id, { verdict = "unchecked", why = "The check was malformed." })
		end
		github.outcome({ outcome = q.outcome, repo = repo, number = n, branch = branch, commit = commit, since = q.since, login = q.login }, function(verdict: string, why: string?)
			reply(state, id, { verdict = verdict, why = why })
		end)
	else
		M.workflowRpc(state, id, q)
	end
end

-- The queue actions the command palette offers now, in its order, each with its label, key ("": none) and group (and, for
-- a scope, the sidebar group it sits under as `detail`): the selected item's (its next move first, named as the move),
-- then the view's, every sidebar scope
-- (`scope:<id>`, shown by engine.goScope) and the configuration's. Only what applies is listed. The Worktrees list offers
-- its own rows' actions, Refresh, the scopes, Settings and the shortcut list; the Agents list Go to agent, the scopes,
-- Settings and the shortcut list; Now Reply… and Go to agent (while its row's agent needs input), Show or hide snoozed,
-- Refresh, the scopes, Settings and the shortcut list. Next in Now is offered everywhere.
function M.paletteActions(state: State): { QueueAction }
	local map = keys.load()
	local labels: { [string]: string } = { unpin = "Unpin" }
	for _, a in keys.ACTIONS do
		labels[a.id] = a.label
	end
	local out: { QueueAction } = {}
	local function add(id: string, group: string)
		table.insert(out, { id = id, label = labels[id], key = map[id] or "", group = group })
	end
	local function views()
		for _, scope in (render.scopeRows(state)) do
			table.insert(out, { id = "scope:" .. scope.id, label = scope.label, key = "", group = "Views", detail = scope.group })
		end
	end
	local item = if state.boardOn or state.agentsOn or state.nowOn then nil else selected(state)
	labels.agentint, labels.agentstop, labels.agentmsg, labels.agentdisagree = "Interrupt agent", "Stop agent…", "Message agent…", "Disagree with check…"
	local function addAgentCommands(group: string)
		for _, id in { "agentint", "agentstop", "agentmsg" } do
			add(id, group)
		end
	end
	if item then
		labels.open = "Open"
		labels["open-git"] = "Open Git view"
		-- The suggested next move for the item's stage leads, under Next, named as the move (engine.nextMove).
		local move = engine.nextMove(state, state.kind.id, item)
		if move then
			labels.next = move.label
			add("next", "Next")
		end
		local group = if state.kind.id ~= "issues" then "GitHub - PR" elseif item.tracker == "jira" then "Jira - Issue" else "GitHub - Issue"
		add("open", group)
		add("worktree", group)
		if engine.cardPath(state) then
			add("open-git", group)
		end
		if openItems(state)[item.key] then
			add("goto", group)
		end
		local copy = M.copyTexts(state)
		if copy then
			labels["copy-link"], labels["copy-number"], labels["copy-branch"] = "Copy link", "Copy number", "Copy branch"
			add("copy-link", group)
			add("copy-number", group)
			if copy.branch then
				add("copy-branch", group)
			end
		end
		add("seen", "Triage")
		add("snooze", "Triage")
		if engine.pinFor(state.pins, item.key) then
			add("unpin", "Triage")
		end
		-- The agent picker is no row: the saved actions and Type a prompt are listed beside this.
		if state.agents[item.key] then
			add("agentgo", "Actions")
		end
		if state.agents[item.key] and state.agents[item.key] ~= "exited" then
			addAgentCommands("Actions")
		end
		local info = state.agentInfo[item.key]
		if info and info.check then
			add("agentdisagree", "Actions")
		end
	end
	if state.agentsOn then
		if select(2, engine.agentSelected(state)) > 0 then
			add("agentgo", "Agents")
			addAgentCommands("Agents")
		end
		add("nownext", "Now")
		views()
		add("settings", "Configuration")
		add("help", "Configuration")
		return out
	end
	if state.boardOn then
		local row = engine.boardSelected(state)
		labels["wt-open"], labels["wt-remove"], labels["wt-remove-finished"], labels["wt-git"] = "Open worktree tab", "Remove worktree…", "Remove finished worktrees…", "Open Git view"
		if row then
			if not row.missing then
				add("wt-open", "Worktree")
				add("wt-git", "Worktree")
			end
			if not row.locked and not row.missing then -- the guard of boardAct and the Remove button
				add("wt-remove", "Worktree")
			end
		end
		add("wt-cleanup", "Worktree")
		add("wt-remove-finished", "Worktree")
		add("refresh", "Filter & Sort")
		add("nownext", "Now")
		views()
		add("settings", "Configuration")
		add("help", "Configuration")
		return out
	end
	if state.nowOn then
		local row = engine.nowSelected(state)
		if row and row.rank == 1 and row.key and engine.agentHref(row.key) then
			if row.waiting then
				labels.agentreply = "Reply…"
				add("agentreply", "Now")
			end
			add("agentgo", "Now")
		end
		add("snoozed", "Filter & Sort")
		add("refresh", "Filter & Sort")
		add("nownext", "Now")
		views()
		add("settings", "Configuration")
		add("help", "Configuration")
		return out
	end
	local view = activeView(state)
	for _, id in { "snoozed", "sort", "search", "refresh" } do
		if id ~= "sort" or (view and not engine.isPin(view.id) and #sorting.choices(view.kind, view.integration) > 0) then
			add(id, "Filter & Sort")
		end
	end
	add("nownext", "Now")
	views()
	add("settings", "Configuration")
	add("help", "Configuration")
	return out
end

return M
