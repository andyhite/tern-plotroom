--!strict
-- Saved views, prompts, checkouts, setup commands, Jira project map and the name formats, all in kv.
local sorting = require("../sorting")
local tracker = require("../tracker")
local worktree = require("../worktree")
local core = require("./core")

type Kind = core.Kind
type Prompt = core.Prompt
type Prompts = core.Prompts
type Seed = core.Seed
type State = core.State
type View = core.View
type Views = core.Views

local KINDS, cli = core.KINDS, core.cli

local M = {}

-- `type(v) == "table"` without refining an untrusted `any`.
local function isTable(v: any): boolean
	return type(v) == "table"
end
M.isTable = isTable

-- The default views of `kind` a first run saves. A sprint view left out keeps its id unused, so nextId follows them all.
local function seedViews(kind: Kind): Views
	local items: { View } = {}
	for i, v in kind.seeds do
		if not v.sprint or cli.sprints == true then
			table.insert(items, { id = kind.id .. ":v" .. i, kind = kind.id, name = v.name, integration = v.integration, query = v.query, logins = {}, group = v.group, prompts = {}, sort = v.sort })
		end
	end
	return { version = 1, nextId = #kind.seeds + 1, items = items }
end

-- The default views of `integration` that `views` (one Settings › Views group) has none of the same kind and name of,
-- in order: what its Restore defaults saves back. An edited default keeps its name, so it is never replaced.
function M.missingViews(integration: string, views: { View }): { { kind: Kind, seed: Seed } }
	local out: { { kind: Kind, seed: Seed } } = {}
	for _, kind in { KINDS.prs, KINDS.issues } do
		for _, d in kind.seeds do
			local found = d.integration ~= integration or (d.sprint == true and cli.sprints ~= true)
			for _, v in views do
				found = found or (v.kind == kind.id and v.name == d.name)
			end
			if not found then
				table.insert(out, { kind = kind, seed = d })
			end
		end
	end
	return out
end

local function validViews(kind: Kind, v: any): Views?
	if not isTable(v) or v.version ~= 1 or type(v.nextId) ~= "number" or not isTable(v.items) then
		return nil
	end
	local items: { View } = {}
	for _, f in v.items do
		if
			not isTable(f)
			or type(f.id) ~= "string"
			or type(f.name) ~= "string"
			or type(f.query) ~= "string"
			or type(f.integration) ~= "string"
			or not table.find(kind.integrations, f.integration)
			or (f.logins ~= nil and not isTable(f.logins))
			or (f.login ~= nil and (type(f.login) ~= "string" or not string.match(f.login, "^[%w%-_]+$")))
			or type(f.group) ~= "string"
			or (f.sort ~= nil and type(f.sort) ~= "string")
			or not isTable(f.prompts)
		then
			return nil
		end
		local prompts: { string } = {}
		for _, p in f.prompts do
			if type(p) ~= "string" then
				return nil
			end
			table.insert(prompts, p)
		end
		-- The gh logins a GitHub view runs as; a view saved with one `login` loads as a list of one.
		local logins: { string } = {}
		local seen: { [string]: boolean } = {}
		local saved: { any } = if f.logins ~= nil then f.logins else (if f.login ~= nil then { f.login } else {})
		for _, who in saved do
			if type(who) ~= "string" or not string.match(who, "^[%w%-_]+$") then
				return nil
			end
			if not seen[string.lower(who)] and f.integration == "github" then
				seen[string.lower(who)] = true
				table.insert(logins, who)
			end
		end
		-- A sort this version does not know (a newer one saved it) is dropped: the view keeps the default order.
		local sort: string? = if f.sort ~= nil and sorting.valid(kind.id, f.integration, f.sort) then f.sort else nil
		table.insert(items, { id = kind.id .. ":" .. f.id, kind = kind.id, name = f.name, integration = f.integration, query = f.query, logins = logins, group = f.group, prompts = prompts, sort = sort })
	end
	return { version = 1, nextId = v.nextId, items = items }
end

-- tern.kv.set raises on failure and returns nothing: the error text, or nil when saved.
local function kvSet(key: string, value: any): string?
	local ok, err = pcall(function(): string?
		tern.kv.set(key, value)
		return nil
	end)
	if ok then
		return nil
	end
	return tostring(err)
end

function M.writeViews(kind: Kind, store: Views): string?
	local items: { any } = {}
	for _, v in store.items do
		table.insert(items, { id = string.sub(v.id, #kind.id + 2), name = v.name, integration = v.integration, query = v.query, logins = tern.json.array(v.logins), group = v.group, prompts = tern.json.array(v.prompts), sort = v.sort })
	end
	return kvSet(kind.viewsKey, { version = 1, nextId = store.nextId, items = tern.json.array(items) })
end

-- views, writable, error. The views' ids are "<kind>:<saved id>". An absent key is seeded; unreadable or malformed
-- storage is never overwritten: seeds are shown but Save is disabled.
function M.loadViews(kind: Kind): (Views, boolean, string?)
	local ok, v = pcall(tern.kv.get, kind.viewsKey)
	if not ok then
		return seedViews(kind), false, "Saved " .. kind.one .. " views could not be read: " .. tostring(v)
	end
	if v == nil then
		local s = seedViews(kind)
		-- Which issue views a first run gets waits on the Jira site's sprints: saved once acli and the site answered.
		if kind.id == "issues" and (cli.installed.jira == nil or cli.sprintsAsking) then
			return s, true, nil
		end
		local err = M.writeViews(kind, s)
		if err then
			return s, false, "Saved " .. kind.one .. " views could not be written: " .. err
		end
		return s, true, nil
	end
	local s = validViews(kind, v)
	if not s then
		return seedViews(kind), false, "Saved " .. kind.one .. " views are malformed; not overwriting them."
	end
	return s, true, nil
end

-- Rereads both kinds' saved views into `state.views`, pull request views first, and notes per kind whether they can be
-- changed (`state.locked`: why not). Each kind keeps its own kv store, which a view's id names. A view of an integration
-- that is not on stays saved but is left out.
function M.loadAll(state: State)
	local all: { View } = {}
	for _, kind in { KINDS.prs, KINDS.issues } do
		local store, writable, err = M.loadViews(kind)
		if writable then
			state.locked[kind.id] = nil
		else
			state.locked[kind.id] = err or "Saved " .. kind.one .. " views are read-only."
		end
		for _, v in store.items do
			if cli.ready() and cli.on(v.integration) then
				table.insert(all, v)
			end
		end
	end
	state.views = all
	state.rev += 1 -- a view's sort or prompts may have changed: the visible list and the rows are built again
	state.vis = nil
end

-- The kind and the saved id of a view or prompt as Settings names it: "<kind id>:<id in that kind's kv store>".
function M.kindAndId(qid: string): (Kind?, string)
	local k, id = string.match(qid, "^(%a+):(.+)$")
	return (if k then KINDS[k] else nil), id or qid
end

-- The strings of a saved list; anything else in it is dropped.
function M.stringList(v: any): { string }
	local out: { string } = {}
	if isTable(v) then
		for _, x in v do
			if type(x) == "string" then
				table.insert(out, x)
			end
		end
	end
	return out
end

-- Saved repositories (kv "checkouts", keyed by lowercase "owner/name") to their local checkout; "" marks one listed
-- in Settings without a checkout.
function M.readCheckouts(): { [string]: any }
	local ok, v = pcall(tern.kv.get, "checkouts")
	if ok and isTable(v) then
		return v
	end
	return {}
end

-- The saved local checkout of `repo`, nil when none: then the window's palette asks for one before anything makes a
-- worktree of it.
function M.checkoutOf(repo: string): string?
	local path = M.readCheckouts()[string.lower(repo)]
	return if type(path) == "string" and path ~= "" then path else nil
end

-- Saves `path` as `repo`'s checkout ("": none, but still listed); with `keep`, only a repository not saved yet. Fails
-- closed when the saved map cannot be read.
function M.saveCheckout(repo: string, path: string, keep: boolean?): string?
	local ok, stored = pcall(tern.kv.get, "checkouts")
	if not ok or (stored ~= nil and not isTable(stored)) then
		return "Saved checkouts could not be read"
	end
	local repos: { [string]: any } = if stored ~= nil then stored else {}
	local key = string.lower(repo)
	if repos[key] == path or (keep and repos[key] ~= nil) then
		return nil
	end
	repos[key] = path
	local err = kvSet("checkouts", repos)
	return if err then "Could not save: " .. err else nil
end

-- A saved map under kv `key` (`what` names it in the message), or nil and why when unreadable: a write then fails
-- closed rather than overwrite it.
local function readMap(key: string, what: string): ({ [string]: any }?, string?)
	local ok, stored = pcall(tern.kv.get, key)
	if not ok or (stored ~= nil and not isTable(stored)) then
		return nil, "Saved " .. what .. " could not be read."
	end
	return if stored ~= nil then stored else {}, nil
end

-- Saved worktree setup commands per repository (kv "setup-commands", keyed like "checkouts"), or nil and why when
-- unreadable.
function M.setupMap(): ({ [string]: any }?, string?)
	return readMap("setup-commands", "setup commands")
end

function M.setupOf(map: { [string]: any }, repo: string): { string }
	return M.stringList(map[string.lower(repo)])
end

-- Rereads `repo`'s setup commands, lets `fn` change them (an error string aborts) and saves them.
function M.editSetup(repo: string, fn: ({ string }) -> string?): string?
	local map, err = M.setupMap()
	if not map then
		return err
	end
	local list = M.setupOf(map, repo)
	local ferr = fn(list)
	if ferr then
		return ferr
	end
	map[string.lower(repo)] = if #list > 0 then tern.json.array(list) else nil
	local werr = kvSet("setup-commands", map)
	return if werr then "Could not save: " .. werr else nil
end

-- Branch and worktree folder name formats (folders: Settings › Worktrees; branch: there, or per repository in Settings › Repositories). One table keeps the format helpers together.
local formats = {}
M.formats = formats

-- Saved branch name formats per repository (kv "branch-formats", keyed like "checkouts"), or nil and why when
-- unreadable.
function formats.repoMap(): ({ [string]: any }?, string?)
	return readMap("branch-formats", "branch formats")
end

-- The branch name format saved for `repo`; nil when none is (the Worktrees format applies) or they cannot be read.
function formats.repoOf(repo: string): string?
	local map = formats.repoMap()
	local fmt = if map then map[string.lower(repo)] else nil
	return if type(fmt) == "string" and fmt ~= "" then fmt else nil
end

-- Saved repositories per Jira project (kv "jira-repos": KEY to lowercase "owner/name" list), or nil and why when
-- unreadable.
function M.readJiraRepos(): ({ [string]: any }?, string?)
	return readMap("jira-repos", "Jira project repositories")
end

-- The repositories Jira project `project` is worked in: the valid "owner/name" strings saved for it, in saved order.
function M.jiraReposOf(project: string): { string }
	local map = M.readJiraRepos()
	local out: { string } = {}
	for _, r in M.stringList(if map then map[project] else nil) do
		local owner, name = string.match(r, "^([^/]+)/([^/]+)$")
		if owner and name and worktree.validSegment(owner) and worktree.validSegment(name) then
			table.insert(out, r)
		end
	end
	return out
end

-- Rereads the Jira project map, lets `fn` change it (an error string aborts) and saves it; an error message or nil.
function M.editJiraRepos(fn: ({ [string]: any }) -> string?): string?
	local map, err = M.readJiraRepos()
	if not map then
		return err
	end
	local ferr = fn(map)
	if ferr then
		return ferr
	end
	local out: { [string]: any } = {}
	for key, list in map do
		out[key] = tern.json.array(M.stringList(list))
	end
	local werr = kvSet("jira-repos", out)
	return if werr then "Could not save: " .. werr else nil
end

-- Name formats for every repository (Settings › Worktrees): the branch of an issue's worktree, and the
-- folder names of PR and issue worktrees. Kept under kv formats.KEYS; "" or unset is the default.
formats.KEYS = { branch = "branch-format", prdir = "pr-dir-format", issuedir = "issue-dir-format" } :: { [string]: string }
formats.DEFAULTS = { branch = tracker.BRANCH_DEFAULT, prdir = tracker.PR_DIR_DEFAULT, issuedir = tracker.ISSUE_DIR_DEFAULT } :: { [string]: string }

function formats.saved(which: string): string
	local ok, v = pcall(tern.kv.get, formats.KEYS[which])
	return if ok and type(v) == "string" then v else ""
end

function formats.of(which: string): string
	local f = formats.saved(which)
	return if f ~= "" then f else formats.DEFAULTS[which]
end

-- Deletes `repo` from the checkouts, branch formats, setup commands and every Jira project's repositories. A map is
-- only written when it was readable; the first failure is returned.
function M.removeRepo(repo: string): string?
	local key = string.lower(repo)
	local failed: string? = nil
	for _, name in { "checkouts", "branch-formats", "setup-commands" } do
		local ok, stored = pcall(tern.kv.get, name)
		if ok and isTable(stored) and stored[key] ~= nil then
			stored[key] = nil
			local err = kvSet(name, stored)
			failed = failed or (if err then "Could not save: " .. err else nil)
		end
	end
	local jerr = M.editJiraRepos(function(map: { [string]: any }): string?
		for project, list in map do
			local keep: { string } = {}
			for _, r in M.stringList(list) do
				if string.lower(r) ~= key then
					table.insert(keep, r)
				end
			end
			map[project] = keep
		end
		return nil
	end)
	return failed or jerr
end

local PROMPTS_BAD = "Saved actions are malformed; not overwriting them."
M.PROMPT_CAP = 8000 -- bytes of one prompt's text: several must fit one answer to the window (MENU_BUDGET)

-- Saved agent prompts (kv prompts-prs / prompts-issues; absent: the kind's default prompts, saved with the first edit),
-- or nil and why when unreadable or malformed: a write then fails closed rather than overwrite them.
function M.loadPrompts(kind: Kind): (Prompts?, string?)
	local ok, v = pcall(tern.kv.get, kind.promptsKey)
	if not ok then
		return nil, "Saved actions could not be read: " .. tostring(v)
	end
	if v == nil then
		local seeds: { Prompt } = {}
		for _, p in kind.prompts do
			table.insert(seeds, { id = p.id, name = p.name, text = p.text, worktree = p.worktree })
		end
		return { version = 1, nextId = #seeds + 1, items = seeds }, nil
	end
	if not isTable(v) or v.version ~= 1 or type(v.nextId) ~= "number" or not isTable(v.items) then
		return nil, PROMPTS_BAD
	end
	local items: { Prompt } = {}
	for _, p in v.items do
		if
			not isTable(p)
			or type(p.id) ~= "string"
			or type(p.name) ~= "string"
			or type(p.text) ~= "string"
			or (p.key ~= nil and type(p.key) ~= "string")
			or (p.worktree ~= nil and type(p.worktree) ~= "boolean")
			or (p.split ~= nil and type(p.split) ~= "boolean")
			or (p.model ~= nil and type(p.model) ~= "string")
			or (p.status ~= nil and type(p.status) ~= "string")
			or (p.next ~= nil and type(p.next) ~= "string")
		then
			return nil, PROMPTS_BAD
		end
		table.insert(items, { id = p.id, name = p.name, text = p.text, key = p.key, worktree = p.worktree, split = p.split, model = p.model, status = p.status, next = p.next })
	end
	return { version = 1, nextId = v.nextId, items = items }, nil
end

-- Rereads the prompts, lets `fn` change them (an error string aborts) and saves them; an error message or nil.
function M.editPrompts(kind: Kind, fn: (Prompts) -> string?): string?
	local store, err = M.loadPrompts(kind)
	if not store then
		return err
	end
	local ferr = fn(store)
	if ferr then
		return ferr
	end
	local items: { any } = {}
	for _, p in store.items do
		table.insert(items, { id = p.id, name = p.name, text = p.text, key = p.key, worktree = p.worktree, split = p.split, model = p.model, status = p.status, next = p.next })
	end
	local werr = kvSet(kind.promptsKey, { version = 1, nextId = store.nextId, items = tern.json.array(items) })
	return if werr then "Could not save: " .. werr else nil
end

function M.promptById(store: Prompts, id: string): Prompt?
	for _, p in store.items do
		if p.id == id then
			return p
		end
	end
	return nil
end

-- The kind and saved id a prompt's `next` names: a bare id is of the prompt's own kind, `prs:<id>` (an issue action's
-- only) a pull request action.
function M.nextOf(kind: Kind, nxt: string): (Kind, string)
	local id = string.match(nxt, "^prs:(.+)$")
	if id and kind.id == "issues" then
		return KINDS.prs, id
	end
	return kind, nxt
end

-- Whether following `next` from prompt `from` leads back to it (a prompt naming itself included): a cycle. A qualified
-- next (`prs:<id>`) leaves the store, and a pull request action never chains back, so it ends the walk.
function M.chainReaches(store: Prompts, from: string, next: string): boolean
	local seen: { [string]: boolean } = {}
	local at: string? = next
	while at and not seen[at] do
		if at == from then
			return true
		end
		seen[at] = true
		local p = M.promptById(store, at)
		at = if p then p.next else nil
	end
	return false
end

-- The prompts view `v` lists, as ids of prompts that still exist, in the prompts' order; empty: it lists none.
function M.livePrompts(v: View, list: { Prompt }): { string }
	local out: { string } = {}
	for _, p in list do
		if table.find(v.prompts, p.id) then
			table.insert(out, p.id)
		end
	end
	return out
end

-- Saves `fmt` as `repo`'s branch name format (nil: back to the default). Fails closed when the saved formats cannot
-- be read.
function formats.saveRepo(repo: string, fmt: string?): string?
	local map, err = formats.repoMap()
	if not map then
		return err
	end
	map[string.lower(repo)] = fmt
	local werr = kvSet("branch-formats", map)
	return if werr then "Could not save: " .. werr else nil
end

-- Saves name format `which` (a formats.KEYS key; "" is the default).
function formats.save(which: string, fmt: string): string?
	local err = kvSet(formats.KEYS[which], fmt)
	return if err then "Could not save: " .. err else nil
end

-- The branch format an issue's new branch in `code` gets: the repository's own, else the Worktrees one.
function formats.issueBranch(code: string): string
	return formats.repoOf(code) or formats.of("branch")
end

-- The folder name pull request `n` of `repo` ("owner/name") titled `title` gets, or nil and why.
function formats.prDir(repo: string, n: number, title: string): (string?, string?)
	local owner, name = string.match(string.lower(repo), "^([^/]+)/([^/]+)$")
	return tracker.render(formats.of("prdir"), { key = tostring(n), slug = tracker.slug(title), owner = owner or "", repo = name or "" }, true)
end

return M
