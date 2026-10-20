--!strict
-- Requests from window.luau (rpc) and the workflow requests: menu, worktree prepare, pickers, mutation plans, draft PR, export/import, palette actions.
-- window.luau runs on the machine showing the window, which for a pane on a remote host is not the machine holding
-- the checkout. So whatever reads the checkout or runs git, gh or omp runs here, where the block runs: the window sends
-- {act = "rpc", value = JSON {id, op, ...}}; the answer is the hidden node `main.r<id>` (JSON text), announced by
-- opening plotroom://rpc/<id>, which only the window waiting for that id acts on. `main.rpc` says which protocol this
-- host speaks, so a window never waits on a host running another Plotroom version.

local github = require("../github")
local jira = require("../jira")
local input = require("../input")
local keys = require("../keys")
local portable = require("../portable")
local process = require("../process")
local sorting = require("../sorting")
local tracker = require("../tracker")
local worktree = require("../worktree")

local core = require("./core")
local storage = require("./storage")
local engine = require("./engine")
local render = require("./render")
local settings = require("./settings")

type Prompt = core.Prompt
type Prompts = core.Prompts
type State = core.State

local COMMENT_ROWS, INTEGRATIONS, KINDS, clip, printable, stateKind, cli = core.COMMENT_ROWS, core.INTEGRATIONS, core.KINDS, core.clip, core.printable, core.stateKind, core.cli
local checkoutOf, editJiraRepos, editPrompts, isTable, jiraReposOf, loadAll, loadPrompts, loadViews, promptById = storage.checkoutOf, storage.editJiraRepos, storage.editPrompts, storage.isTable, storage.jiraReposOf, storage.loadAll, storage.loadPrompts, storage.loadViews, storage.promptById
local readCheckouts, readJiraRepos, saveCheckout, setupMap, setupOf, stringList, writeViews, formats = storage.readCheckouts, storage.readJiraRepos, storage.saveCheckout, storage.setupMap, storage.setupOf, storage.stringList, storage.writeViews, storage.formats
local activeView, alive, changed, detailKey, filtered, indexOf, issueVars, login, noteWorktree = engine.activeView, engine.alive, engine.changed, engine.detailKey, engine.filtered, engine.indexOf, engine.issueVars, engine.login, engine.noteWorktree
local offered, openItems, parseRepo, propagate, reloadViews, selected, snapKey, switchView, trim, me, ghActive = engine.offered, engine.openItems, engine.parseRepo, engine.propagate, engine.reloadViews, engine.selected, engine.snapKey, engine.switchView, input.trim, engine.me, engine.ghActive
local discardEdit = settings.discardEdit

local M = {}

M.seq = 0 -- confirmation tokens issued by this runtime

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

-- `repo`'s saved setup commands (Settings › Repositories) as one shell line that stops at the first failure, blank ones
-- left out; nil if none.
local function setupLine(repo: string): string?
	local map = setupMap()
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

-- The agent picker's rows: `offered`, each with its id so a prompt's run link can name it. With `only`, just that
-- prompt, so a shortcut never misses its prompt to the picker's size budget. With `palette`, the command palette's
-- queue actions too (M.paletteActions).
local function menu(state: State, id: string, only: string?, palette: boolean)
	local list, problem = offered(state)
	local active = activeView(state)
	local mine: { any } = {}
	for _, o in list do
		local p = o.prompt
		if only and p.id ~= only then
			continue
		end
		table.insert(mine, {
			id = p.id,
			label = clip(printable(p.name), 120),
			detail = clip(printable((if p.model then p.model .. " · " else "") .. (string.match(p.text, "^%s*([^\n]*)") or "")), 160),
			group = if o.here and active then "For " .. clip(printable(active.name), 60) else "All actions",
			send = p.text,
			model = p.model,
			worktree = p.worktree ~= false, -- where it runs: the item's worktree, else the main checkout
			split = if p.split then true else nil, -- its agent opens beside the queue; omitted: a tab of its own
			status = p.status, -- an issue action's Jira status to move to when its agent starts
			next = p.next, -- the action that starts when its agent finishes
			key = p.key,
		})
	end
	local items = capped(mine, function(row)
		return #tern.json.encode(row)
	end)
	reply(state, id, { items = tern.json.array(items), problem = problem, queue = if palette then tern.json.array(M.paletteActions(state)) else nil, commands = if palette then tern.json.array(M.commands(state)) else nil })
end

-- Creates or reuses the worktree of `repo`#`n` on the PR's own branch, in the folder the PR folder format names, and
-- notes the outcome; with `wt` false, answers the repository's main checkout as it is, reading only the PR's details.
-- Without a checkout of `repo` the answer asks the window for one. `users`: the answer carries `{github.user}` too,
-- for the prompt that runs there.
local function prepare(state: State, id: string, repo: string, n: number, wt: boolean, users: boolean)
	local key = string.lower(repo) .. "#" .. n
	if wt and preparing[key] then
		return reply(state, id, { busy = true })
	end
	local checkout = checkoutOf(repo)
	if not checkout then
		return reply(state, id, { needCheckout = string.lower(repo) })
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
				summary = "Main checkout",
				created = false,
				current = true,
				branch = meta.ref,
				base = meta.baseRef,
				title = meta.title,
				author = meta.author,
				["github.user"] = found["github.user"],
			})
		end)
	end
	if wt then
		preparing[key] = true
	end
	local function open(found: { [string]: string })
		local started, err = pcall(function()
			process.reset()
			worktree.open(checkout, repo, n, naming, login(state), function(r, problem)
				preparing[key] = nil
				if not alive(state) then
					return
				end
				if problem == worktree.NO_REPO then
					return reply(state, id, { needCheckout = string.lower(repo) })
				end
				if not r then
					local why = problem or "Worktree failed"
					noteWorktree(state, key, "prs", nil, why)
					return reply(state, id, { problem = why })
				end
				local current = r.head == r.prHead
				local summary = worktree.describe(r)
				noteWorktree(state, key, "prs", {
					root = r.root,
					path = r.path,
					branch = r.branch,
					ref = r.ref,
					current = current,
					dirty = r.dirty,
					summary = summary,
					update = worktree.update(r),
				}, nil)
				reply(state, id, {
					path = r.path,
					created = r.created,
					current = current,
					dirty = r.dirty,
					summary = summary,
					setup = if r.created then setupLine(repo) else nil,
					remote = r.remote,
					branch = r.prRef,
					base = r.prBase,
					title = r.title,
					author = r.author,
					["github.user"] = found["github.user"],
				})
			end)
		end)
		if not started then
			preparing[key] = nil
			reply(state, id, { problem = tostring(err) })
		end
	end
	local go: ({ [string]: string }) -> () = if wt then open else main
	if not users then
		return go({})
	end
	me.read(state, false, function(found)
		if alive(state) then
			go(found)
		elseif wt then
			preparing[key] = nil
		end
	end)
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
		return reply(state, id, { needCheckout = string.lower(code) })
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
				return reply(state, id, { needCheckout = string.lower(code) })
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
			return reply(state, id, { path = checkout, summary = "Main checkout", created = false, current = true, vars = vars, code = code })
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
		preparing[key] = true
		local started, err = pcall(function()
			process.reset()
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
					return reply(state, id, { needCheckout = string.lower(code) })
				end
				if not r then
					local failed = problem or "Worktree failed"
					noteWorktree(state, key, "issues", nil, failed)
					return reply(state, id, { problem = failed })
				end
				local summary = worktree.describeIssue(r)
				noteWorktree(state, key, "issues", {
					root = r.root,
					path = r.path,
					branch = r.branch,
					ref = r.ref,
					current = true,
					dirty = r.dirty,
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
					summary = summary,
					setup = if r.created then setupLine(code) else nil,
					vars = vars,
					code = code,
				})
			end)
		end)
		if not started then
			preparing[key] = nil
			reply(state, id, { problem = tostring(err) })
		end
	end

	if not need then
		return go({})
	end
	if wt then
		preparing[key] = true -- the users are read first: a repeat meanwhile is busy too
	end
	me.read(state, issue.tracker == "jira", function(found)
		if alive(state) then
			go(found)
		elseif wt then
			preparing[key] = nil
		end
	end)
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
	github.repos(login, function(names, problem)
		state.listing -= 1
		local more = capped(names or {}, function(name)
			return #name + 3
		end)
		reply(state, id, { repos = tern.json.array(more), problem = if problem then problem.message else nil })
	end)
end

-- The Jira project picker's list: every saved project with its repositories, sorted by key, then the projects acli
-- lists that are not saved, cut to MENU_BUDGET. Without the list, `problem` says why.
local function jiraProjects(state: State, id: string)
	local keys: { string } = {}
	local map: { [string]: any } = (readJiraRepos()) or {}
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
	state.settings, state.help, state.query, state.focus, state.boardOn, state.agentsOn = nil, false, nil, "list", false, false
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
	if plan.gen ~= state.gen or plan.view ~= state.activeId or plan.login ~= state.activeLogin or os.time() - plan.at > 300 or not chosen or chosen.key ~= plan.key then
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

-- The selected item as the window's palette commands see it.
function M.ctx(state: State, id: string)
	local item, snap = selected(state), state.snap
	local info: any = nil
	if item and snap then
		local prs = snap.kind == "prs"
		local note = state.notes[item.key]
		info = {
			kind = if prs then "pr" else "issue",
			tracker = if prs then "github" else item.tracker,
			repo = item.repo,
			ref = if prs then tostring(item.number) else item.ref,
			key = item.key,
			title = item.title,
			url = item.url,
			state = if prs then stateKind(item) else item.state,
			labels = M.strings(item.labels),
			assignees = M.strings(if prs then {} else item.assignees),
			status = if not prs and item.status then item.status.text else nil,
			number = if prs then item.number else nil,
		}
		local v = activeView(state)
		reply(state, id, { item = info, pinned = engine.pinFor(state.pins, item.key) ~= nil, view = if v then { name = v.name, kind = v.kind, integration = v.integration } else nil, worktree = if note and note.ok then note.path else nil })
		return
	end
	reply(state, id, { item = tern.json.null })
end

function M.labelOk(label: any): string?
	if type(label) ~= "string" or label == "" or #label > 50 or string.find(label, "[%c,]") or string.sub(label, 1, 1) == "-" then
		return nil
	end
	return label
end

-- The mutations of the selected item: asks for a confirmation (`offer`), or lists a Jira issue's transitions.
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
	if not item or not snap then
		return no("Select an item first.")
	end
	local name, prs = q.name, snap.kind == "prs"
	local target = if prs then item.repo .. "#" .. item.number else (if item.tracker == "jira" then item.ref else item.repo .. "#" .. item.ref)
	if name == "assign-me" then
		if prs then
			return no("Assigning works on issues; pull requests are not edited here.")
		elseif item.tracker == "jira" then
			return M.offer(state, id, item, {
				head = "Assign " .. item.ref .. " to you?",
				label = "Assign to me",
				lines = { target .. ": " .. printable(item.title), "Jira account: the one acli is signed in with", "Current assignee: " .. (if #item.assignees > 0 then table.concat(item.assignees, ", ") else "none") },
			}, function(done)
				jira.assignMe(item.ref, function(problem: github.Problem?)
					M.landed(state, done, problem, "Assigned " .. item.ref .. " to you")
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
			github.editIssue({ repo = item.repo, number = tonumber(item.ref) :: number, addAssignees = { "@me" }, removeAssignees = {}, addLabels = {}, removeLabels = {} }, account, function(problem: github.Problem?)
				M.landed(state, done, problem, "Assigned " .. target .. " to you")
			end)
		end)
	elseif name == "label-add" or name == "label-remove" then
		if prs or item.tracker ~= "github" then
			return no("Labels are edited on GitHub issues.")
		end
		local label = M.labelOk(q.label)
		if not label then
			return no("That is not a usable label (1 to 50 characters, no comma, not starting with a dash).")
		end
		local add = name == "label-add"
		if add == (table.find(item.labels, label) ~= nil) then
			return no(if add then "It already has that label." else "It does not have that label.")
		end
		local account = needAccount()
		if not account then
			return
		end
		return M.offer(state, id, item, {
			head = (if add then "Add" else "Remove") .. " label “" .. label .. "” on " .. target .. "?",
			label = if add then "Add label" else "Remove label",
			lines = { target .. ": " .. printable(item.title), "Account: @" .. account, (if add then "Add label: " else "Remove label: ") .. label },
		}, function(done)
			local e = { repo = item.repo, number = tonumber(item.ref) :: number, addAssignees = {}, removeAssignees = {}, addLabels = if add then { label } else {}, removeLabels = if add then {} else { label } }
			github.editIssue(e, account, function(problem: github.Problem?)
				M.landed(state, done, problem, (if add then "Added label " else "Removed label ") .. label .. " on " .. target)
			end)
		end)
	elseif name == "transition" then
		if prs or item.tracker ~= "jira" then
			return no("Transitions are for Jira issues.")
		end
		local key = state.gen
		jira.transitions(item.ref, function(list, problem)
			if not alive(state) then
				return
			elseif state.gen ~= key then
				return no("The view changed; ask again.")
			end
			if not list then
				return no(M.whyOf(problem))
			end
			local options: { any } = {}
			for _, t in list do
				table.insert(options, { id = t.id, name = t.name, to = t.to })
			end
			if q.to == nil then
				return reply(state, id, { options = tern.json.array(options), current = if item.status then item.status.text else nil })
			end
			local chosen: any = nil
			for _, t in list do
				if t.id == q.to then
					chosen = t
				end
			end
			if not chosen then
				return no("Jira no longer offers that transition for " .. item.ref .. ".")
			end
			local to: string = chosen.id
			M.offer(state, id, item, {
				head = "Move " .. item.ref .. " to " .. chosen.name .. "?",
				label = "Move to " .. chosen.name,
				lines = { item.ref .. ": " .. printable(item.title), "Jira account: the one acli is signed in with", "From: " .. (if item.status then item.status.text else "its current status"), "Transition: " .. chosen.name .. " (id " .. to .. ")" },
			}, function(done)
				jira.transition(item.ref, to, function(problem2: github.Problem?)
					M.landed(state, done, problem2, "Moved " .. item.ref .. " with “" .. chosen.name .. "”")
				end)
			end)
		end)
		return
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
	elseif name == "cancel-run" or name == "rerun-all" then
		if not prs then
			return no("Workflow runs belong to pull requests' checks.")
		end
		local cancel = name == "cancel-run"
		local open = M.pendingRuns(state, item)
		local run, names = M.runPick(state, id, q, item, function(r: github.Run): boolean
			if cancel then
				return r.status == "pending"
			end
			return r.runId ~= nil and not open[r.runId]
		end, if cancel then "No check of this pull request has a queued or running GitHub Actions run. Its checks may still be loading." else "No finished GitHub Actions run of this pull request can be rerun: every run has a check still queued or running, or its checks may still be loading.")
		if not run or not names then
			return
		end
		local account = needAccount()
		if not account then
			return
		end
		return M.offer(state, id, item, {
			head = (if cancel then "Cancel workflow run " else "Rerun every job of workflow run ") .. run .. " of " .. target .. "?",
			label = if cancel then "Cancel run" else "Rerun all jobs",
			lines = { target .. ": " .. printable(item.title), "Account: @" .. account, (if cancel then "Cancel run " else "Rerun all jobs of run ") .. run .. " (" .. clip(table.concat(names, ", "), 100) .. ")" },
		}, function(done)
			local function landed(problem: github.Problem?)
				M.landed(state, done, problem, (if cancel then "Cancelling run " else "Rerunning all jobs of run ") .. run .. " of " .. target)
			end
			if cancel then
				github.cancelRun(item.repo, run, account, landed)
			else
				github.rerunAll(item.repo, run, account, landed)
			end
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
		-- The whole normalized text is shown, a row per 100 characters (newlines as ⏎); a text that would not fit the
		-- window's rows is refused, so no tail goes unpreviewed.
		local shown = string.gsub(body, "\n", " ⏎ ")
		local rows: { string } = {}
		local from, total = 1, utf8.len(shown) or #shown
		while from <= total do
			local a, b = utf8.offset(shown, from), utf8.offset(shown, from + 100)
			table.insert(rows, string.sub(shown, a, if b then b - 1 else #shown))
			from += 100
		end
		if #rows > COMMENT_ROWS then
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

-- The checks of `item` (a pull request) as the preview shows them: the loaded list, else what the search carried.
function M.runsOf(state: State, item: any): { github.Run }
	local d = state.details[detailKey(state, item)]
	return if d then d.runs else item.runs
end

-- The ids of the item's workflow runs that still have a queued or running check.
function M.pendingRuns(state: State, item: any): { [string]: boolean }
	local open: { [string]: boolean } = {}
	for _, r in M.runsOf(state, item) do
		if r.runId and r.status == "pending" then
			open[r.runId] = true
		end
	end
	return open
end

-- The workflow run a mutation acts on among the item's checks `keep` lets through: its id and its checks' names, or nil
-- after answering (a problem when there is none, the list of runs to pick from when there are several).
function M.runPick(state: State, id: string, q: any, item: any, keep: (github.Run) -> boolean, none: string): (string?, { string }?)
	local ids: { string } = {}
	local names: { [string]: { string } } = {}
	for _, r in M.runsOf(state, item) do
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
	local out: { { id: string, group: string? } } = { { id = "open-url" }, { id = "export" }, { id = "import" } }
	local item, snap = if state.boardOn or state.agentsOn then nil else selected(state), state.snap
	if not item or not snap then
		return out
	end
	local group = if snap.kind == "prs" then "GitHub - PR" elseif item.tracker == "jira" then "Jira - Issue" else "GitHub - Issue"
	local function add(cmd: string)
		table.insert(out, { id = cmd, group = group })
	end
	if snap.kind == "prs" then
		local failed, pending = false, false
		local open = M.pendingRuns(state, item) -- a run with any unfinished job is not finished
		local finished = false
		for _, r in M.runsOf(state, item) do
			if r.runId then
				pending = pending or r.status == "pending"
				finished = finished or (r.status ~= "pending" and not open[r.runId])
				failed = failed or r.status == "failure"
			end
		end
		if failed then
			add("rerun-failed")
		end
		if finished then
			add("rerun-all")
		end
		if pending then
			add("cancel-run")
		end
		if item.state == "open" then
			add(if item.draft then "pr-ready" else "pr-draft")
		end
		add("comment")
		return out
	end
	add("assign-me")
	if item.tracker == "jira" then
		add("jira-transition")
	else
		add("label-add")
		if #item.labels > 0 then
			add("label-remove")
		end
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
		if type(title) ~= "string" or trim(title) == "" or #title > 256 or string.find(title, "[%c]") then
			return no("The title needs 1 to 256 characters on one line.")
		end
		if type(body) ~= "string" or #body > 8000 or string.find(body, "%z") then
			return no("The description is too long (8000 bytes at most).")
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
							state.draft = nil
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

-- Saved views and prompts in the shapes portable.luau takes.
function M.exportable(state: State, viewIds: any, promptIds: any): ({ any }?, { any }?, { any }?, string?)
	local views: { any } = {}
	local prompts: { any } = {}
	local pool: { any } = {}
	for _, kind in { KINDS.prs, KINDS.issues } do
		local store, why = loadPrompts(kind)
		if not store then
			return nil, nil, nil, why
		end
		for _, p in store.items do
			local entry = { id = p.id, kind = kind.id, name = p.name, text = p.text, key = p.key, worktree = p.worktree, split = p.split, model = p.model, status = p.status, next = p.next }
			table.insert(pool, entry)
			if isTable(promptIds) and table.find(promptIds, kind.id .. ":" .. p.id) then
				table.insert(prompts, entry)
			end
		end
	end
	if isTable(viewIds) then
		for _, v in state.views do
			if table.find(viewIds, v.id) then
				table.insert(views, { id = v.id, kind = v.kind, name = v.name, integration = v.integration, query = v.query, group = v.group, sort = v.sort, logins = v.logins, prompts = v.prompts })
			end
		end
	end
	return views, prompts, pool, nil
end

-- The saved stores of both kinds as portable.plan reads them; nil and why when one cannot be read.
function M.existing(): ({ [string]: any }?, string?)
	local out: { [string]: any } = {}
	for _, kind in { KINDS.prs, KINDS.issues } do
		local views, writable, err = loadViews(kind)
		if not writable then
			return nil, err
		end
		local prompts, perr = loadPrompts(kind)
		if not prompts then
			return nil, perr
		end
		out[kind.id] = { views = views, prompts = prompts }
	end
	return out, nil
end

-- The queue's reserved keys (every action's current key) for portable.plan: an imported action never takes one.
function M.reserve(): { [string]: boolean }
	local reserved: { [string]: boolean } = {}
	for _, key in keys.load() do
		if key ~= "" then
			reserved[key] = true
		end
	end
	return reserved
end

-- `q.path` as a file on this host (a path the user typed), nil and why when it is not a usable one.
function M.pathOf(raw: any): (string?, string?)
	local path = if type(raw) == "string" then worktree.expandPath(trim(raw), tern.getenv("HOME")) else nil
	if not path or #path > 4096 then
		return nil, "That is not a usable path."
	end
	return path, nil
end

-- Export in two steps, so what is confirmed is exactly what leaves: `preview` builds the JSON from the saved views and
-- actions and keeps that snapshot (token, JSON, counts, notes); `commit` (once, with the token and, for a file, its path)
-- copies or writes that very snapshot, whatever was saved meanwhile. A snapshot too big for the window's read is
-- file-only: its reply carries no JSON. The size limit is the importer's (portable.LIMIT), which build enforces.
M.EXPORT_COPY = 50000 -- bytes of an answer's JSON a window can still read back (the reply is escaped)

function M.export(state: State, id: string, q: any)
	if q.phase == "commit" then
		local held = state.exported
		state.exported = nil
		if not held or held.token ~= q.token then
			return reply(state, id, { problem = "That export preview expired; export again." })
		end
		local body: { [string]: any } = { count = held.count, notes = M.strings(held.notes) }
		local copyable = #tern.json.encode({ json = held.json }) <= M.EXPORT_COPY
		if q.path ~= nil then
			local path, bad = M.pathOf(q.path)
			if not path then
				return reply(state, id, { problem = bad })
			end
			local ok, err = pcall(function()
				if tern.fs.exists(path) then
					error("That file exists already; choose a new file name.", 0)
				end
				tern.fs.write(path, held.json)
			end)
			if not ok then
				return reply(state, id, { problem = "Not written: " .. tostring(err) })
			end
			body.ok, body.path = true, path
		elseif not copyable then
			return reply(state, id, { problem = "That export is too large to copy (" .. #held.json .. " bytes); export it to a file instead." })
		end
		if copyable and q.path == nil then
			body.json, body.ok = held.json, true
		end
		return reply(state, id, body)
	end
	local views, prompts, pool, why = M.exportable(state, q.views, q.prompts)
	if not views or not prompts or not pool then
		return reply(state, id, { problem = why or "Saved actions could not be read." })
	end
	local json, notes = portable.build(views, prompts, false, pool)
	if not json then
		return reply(state, id, { problem = notes[1] or "Nothing to export.", notes = M.strings(notes) })
	end
	-- What the document really holds (an action a selected view needs is added, a secret-like one left out).
	local count = { views = #views, prompts = #prompts }
	local ok, doc = pcall(tern.json.decode, json)
	if ok and isTable(doc) then
		count = { views = if isTable(doc.views) then #doc.views else count.views, prompts = if isTable(doc.prompts) then #doc.prompts else count.prompts }
	end
	M.seq += 1
	local token = string.format("x%d_%d", os.time(), M.seq)
	state.exported = { token = token, json = json, count = count, notes = notes }
	reply(state, id, { token = token, count = count, notes = M.strings(notes), size = #json, copyable = #tern.json.encode({ json = json }) <= M.EXPORT_COPY })
end

function M.exportList(state: State, id: string)
	local views: { any } = {}
	for _, v in state.views do
		if #views < 200 then
			table.insert(views, { id = v.id, name = v.name, kind = v.kind, integration = v.integration })
		end
	end
	local prompts: { any } = {}
	for _, kind in { KINDS.prs, KINDS.issues } do
		local store = loadPrompts(kind)
		local saved: { Prompt } = if store then store.items else {}
		for _, p in saved do
			if #prompts < 200 then
				table.insert(prompts, { id = kind.id .. ":" .. p.id, name = p.name, kind = kind.id })
			end
		end
	end
	reply(state, id, { views = tern.json.array(views), prompts = tern.json.array(prompts) })
end

function M.importPreview(state: State, id: string, q: any)
	local text = q.text
	if q.path ~= nil then
		local path, bad = M.pathOf(q.path)
		if not path then
			return reply(state, id, { problem = bad })
		end
		local ok, read = pcall(tern.fs.read, path, portable.LIMIT + 1)
		if not ok or type(read) ~= "string" then
			return reply(state, id, { problem = "That file could not be read: " .. tostring(read) })
		end
		text = read
	end
	if type(text) ~= "string" then
		return reply(state, id, { problem = "Paste the exported JSON or give a file path." })
	end
	local doc, why = portable.parse(text)
	if not doc then
		return reply(state, id, { problem = why or "That is not a Plotroom export." })
	end
	local existing, ewhy = M.existing()
	if not existing then
		return reply(state, id, { problem = ewhy or "Saved views or actions cannot be changed now." })
	end
	local plan = portable.plan(doc, existing, M.reserve())
	if #plan.entries > 150 then
		-- The preview lists every entry or none: nothing is written that was not shown.
		return reply(state, id, { problem = "This import has " .. #plan.entries .. " entries; Plotroom previews up to 150 at once. Export fewer views and actions at a time." })
	end
	M.seq += 1
	local token = string.format("i%d_%d", os.time(), M.seq)
	state.imported = { token = token, doc = doc, plan = plan }
	local entries: { any } = {}
	for i, e in plan.entries do
		if i <= 150 then
			table.insert(entries, { id = e.id, type = e.type, kind = e.kind, name = clip(e.name, 80), conflict = e.conflict, remap = M.strings(e.remap), slots = M.strings(e.slots) })
		end
	end
	reply(state, id, { token = token, entries = tern.json.array(entries), slots = M.strings(plan.slots), accounts = M.strings(ghActive.accounts), problems = M.strings(plan.problems) })
end

function M.importApply(state: State, id: string, q: any)
	local held = state.imported
	state.imported = nil
	if not held or held.token ~= q.token then
		return reply(state, id, { problem = "That import preview expired; start the import again." })
	end
	-- Choices come in by entry number; mapping by slot: "" skips the views that need it, "@active" is gh's active account.
	local choices: { [number]: string } = {}
	if isTable(q.choices) then
		for k, v in q.choices do
			local n = tonumber(k)
			if n and (v == "skip" or v == "replace" or v == "duplicate") then
				choices[n] = v
			end
		end
	end
	local mapping: { [string]: string } = {}
	if isTable(q.mapping) then
		for slot, who in q.mapping do
			if type(slot) == "string" and type(who) == "string" then
				if who == "@active" then
					mapping[slot] = ""
				elseif who ~= "" and string.match(who, "^[%w%-_]+$") and #who <= 64 then
					mapping[slot] = who
				end
			end
		end
	end
	-- Reread right now: read, merge and write run in one go, so nothing saved meanwhile is lost.
	local existing, why = M.existing()
	if not existing then
		return reply(state, id, { problem = why or "Saved views or actions cannot be changed now." })
	end
	local reserved = M.reserve()
	local result, notes = portable.apply(held.doc, held.plan, choices, mapping, existing, {
		sortValid = sorting.valid,
		integrationOn = cli.on,
		reserved = reserved,
		modelValid = worktree.validModel,
	})
	if not result then
		return reply(state, id, { problem = notes[1] or "Nothing could be imported.", notes = M.strings(notes) })
	end
	if next(result) == nil then
		-- Every entry was skipped (or refused): that is no import, and the window must not say it was.
		return reply(state, id, { ok = true, nothing = true, message = "Nothing was imported.", notes = M.strings(notes) })
	end
	local added = { views = 0, prompts = 0 }
	for kindId, out in result do
		local before = existing[kindId]
		if before then
			added.views += math.max(0, #out.views.items - #before.views.items)
			added.prompts += math.max(0, #out.prompts.items - #before.prompts.items)
		end
	end
	for kindId, out in result do
		local kind = KINDS[kindId]
		if kind then
			local err = editPrompts(kind, function(store: Prompts): string?
				store.items, store.nextId = out.prompts.items, out.prompts.nextId
				return nil
			end)
			err = err or writeViews(kind, out.views)
			if err then
				loadAll(state)
				return reply(state, id, { problem = "Not fully imported: " .. err })
			end
		end
	end
	reloadViews(state)
	propagate(state)
	reply(state, id, {
		ok = true,
		message = "Imported " .. added.views .. " view" .. (if added.views == 1 then "" else "s") .. " and " .. added.prompts .. " action" .. (if added.prompts == 1 then "" else "s") .. " (others replaced or left as they were).",
		counts = added,
		notes = M.strings(notes),
	})
end

-- Opens the item at `url` in this block: fetched first (gh or acli), so a missing or foreign item is reported, then shown
-- as the pin. Nothing is opened in a browser.
function M.openUrl(state: State, id: string, url: any)
	local pin = engine.pinView(url)
	if not pin then
		return reply(state, id, { problem = "That is not a GitHub pull request or issue URL, or a Jira issue URL." })
	elseif not cli.on(pin.integration) then
		return reply(state, id, { problem = (if pin.integration == "github" then "The GitHub CLI (gh)" else "The Atlassian CLI (acli)") .. " does not start on this host." })
	end
	engine.fetchPin(state, pin, function(): boolean
		return alive(state)
	end, function(result: any, problem: github.Problem?)
		if not alive(state) then
			return
		end
		if not result then
			return reply(state, id, { problem = M.whyOf(problem) })
		end
		-- What was fetched is shown at once; the pin's own refresh follows.
		local items = if pin.kind == "issues" then result.issues else result.prs
		if #items == 0 then
			return reply(state, id, { problem = "No " .. (if pin.kind == "issues" then "issue" else "pull request") .. " was found at that URL (it does not exist or this account cannot see it)." })
		end
		state.snaps[snapKey(pin, nil)] = { kind = pin.kind, items = items, total = result.total, complete = result.complete, fetched = os.time() }
		if not M.show(state, pin.query, true) then
			return reply(state, id, { problem = "Pins are full: unpin one of the " .. engine.PIN_CAP .. " pinned items first." })
		end
		state.cx:save() -- this landed outside a key or event: the pin is persisted now
		reply(state, id, { ok = true, message = "Showing " .. pin.name .. " in Plotroom" })
	end)
end

-- Window requests of flows.luau's workflows (rpc's last branch).
function M.workflowRpc(state: State, id: string, q: any)
	local op = q.op
	if op == "ctx" then
		M.ctx(state, id)
	elseif op == "act" and type(q.name) == "string" then
		M.act(state, id, q)
	elseif op == "commit" and type(q.token) == "string" then
		M.commit(state, id, q.token)
	elseif op == "draft" and type(q.phase) == "string" then
		M.draft(state, id, q)
	elseif op == "export-list" then
		M.exportList(state, id)
	elseif op == "export" then
		M.export(state, id, q)
	elseif op == "import" and q.phase == "preview" then
		M.importPreview(state, id, q)
	elseif op == "import" and q.phase == "apply" and type(q.token) == "string" then
		M.importApply(state, id, q)
	elseif op == "open-url" and type(q.url) == "string" and #q.url <= 2048 then
		M.openUrl(state, id, q.url)
	elseif op == "worktree-path" and type(q.n) == "number" then
		local row = engine.boardRows(state)[q.n]
		reply(state, id, if row and not row.missing then { path = row.path } else { problem = "That worktree is no longer listed." })
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
		local answer = { label = clip(printable(p.name), 120), send = p.text, model = p.model, worktree = p.worktree ~= false, split = if p.split then true else nil, status = p.status, next = p.next, pr = nil :: number? }
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
		menu(state, id, if type(q.only) == "string" then q.only else nil, q.palette == true)
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
		prepare(state, id, repo, n, q.worktree ~= false, q.users == true)
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
	elseif q.op == "move-status" and type(q.ref) == "string" and #q.ref <= 64 and type(q.status) == "string" and q.status ~= "" and #q.status <= portable.STATUS_CAP then
		moveStatus(state, id, q.ref, q.status)
	elseif q.op == "where" and (q.kind == "pr" or q.kind == "issue") and type(q.key) == "string" and #q.key <= 200 then
		-- The worktree folder of an item as its note has it (git's list or the last attempt), for the window's Go to tab:
		-- a note of the kind asked about.
		local note = state.notes[q.key]
		reply(state, id, { path = if note and note.ok and note.kind == (if q.kind == "pr" then "prs" else "issues") then note.path else nil })
	else
		M.workflowRpc(state, id, q)
	end
end

-- The queue actions the command palette offers now, in its order, each with its label, key ("": none) and group (and, for
-- a scope, the sidebar group it sits under as `detail`): the selected item's, then the view's, every sidebar scope
-- (`scope:<id>`, shown by engine.goScope) and the configuration's. Only what applies is listed. The Worktrees list offers
-- its own rows' actions, Refresh, the scopes, Settings and the shortcut list.
function M.paletteActions(state: State): { { id: string, label: string, key: string, group: string, detail: string? } }
	local map = keys.load()
	local labels: { [string]: string } = { unpin = "Unpin" }
	for _, a in keys.ACTIONS do
		labels[a.id] = a.label
	end
	local out: { { id: string, label: string, key: string, group: string, detail: string? } } = {}
	local function add(id: string, group: string)
		table.insert(out, { id = id, label = labels[id], key = map[id] or "", group = group })
	end
	local function views()
		for _, scope in (render.scopeRows(state)) do
			table.insert(out, { id = "scope:" .. scope.id, label = scope.label, key = "", group = "Views", detail = scope.group })
		end
	end
	local item = if state.boardOn or state.agentsOn then nil else selected(state)
	labels.agentint, labels.agentstop, labels.agentmsg = "Interrupt agent", "Stop agent…", "Message agent…"
	local function addAgentCommands()
		for _, id in { "agentint", "agentstop", "agentmsg" } do
			add(id, "Saved actions")
		end
	end
	if state.agentsOn and engine.agentSelected(state) then
		addAgentCommands()
	end
	if item then
		local tr: string = if state.kind.id == "issues" then item.tracker else "github"
		labels.open = "Open in " .. INTEGRATIONS[tr].label
		local group = if state.kind.id ~= "issues" then "GitHub - PR" elseif item.tracker == "jira" then "Jira - Issue" else "GitHub - Issue"
		add("open", group)
		add("worktree", group)
		if openItems(state)[item.key] then
			add("goto", group)
		end
		add("seen", "Triage")
		add("snooze", "Triage")
		if engine.pinFor(state.pins, item.key) then
			add("unpin", "Triage")
		end
		-- The agent picker is no row: the saved actions and Type a prompt are listed beside this.
		if state.agents[item.key] then
			add("agentgo", "Saved actions")
		end
		if state.agents[item.key] and state.agents[item.key] ~= "exited" then
			addAgentCommands()
		end
	end
	if state.boardOn then
		local row = engine.boardSelected(state)
		labels["wt-open"], labels["wt-remove"], labels["wt-cleanup"] = "Open worktree tab", "Remove worktree…", "Look for finished worktrees"
		if row then
			if not row.missing then
				add("wt-open", "Worktree")
			end
			if not row.main and not row.locked and not row.missing then -- the guard of boardAct and the Remove button
				add("wt-remove", "Worktree")
			end
		end
		add("wt-cleanup", "Worktree")
		add("refresh", "Filter & Sort")
		views()
		add("settings", "Configuration")
		add("help", "Configuration")
		return out
	end
	local view = activeView(state)
	for _, id in { "snoozed", "attention", "sort", "search", "refresh" } do
		if id ~= "sort" or (view and not engine.isPin(view.id) and #sorting.choices(view.kind, view.integration) > 0) then
			add(id, "Filter & Sort")
		end
	end
	views()
	add("settings", "Configuration")
	add("help", "Configuration")
	return out
end

return M
