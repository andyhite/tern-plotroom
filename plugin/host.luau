--!strict
-- The Plotroom block: one engine for live GitHub pull request queues and GitHub or Jira issue lists, with saved, editable views of both.

local github = require("./github")
local input = require("./input")
local jira = require("./jira")
local keys = require("./keys")
local process = require("./process")
local tracker = require("./tracker")
local worktree = require("./worktree")

local ui = tern.ui

local POLL_MS = 60 * 1000
local COST_GUESS = 10
local DETAIL_DEBOUNCE_MS = 300 -- the cursor must rest this long on an item before its checks load, or its worktree's changes are read
local DETAIL_RETRY_S = 15 -- a failed checks load tries again after this long, doubling up to DETAIL_RETRY_MAX_S
local DETAIL_RETRY_MAX_S = 300
local NOTE_CAP = 20 -- worktree attempt reports kept per block; the worktrees git lists are all kept
local ISSUE_ICON = "list-checks" -- the icon of issue views, as in window.luau; a name outside Tern's icon set (`circle-dot` is one) draws blank
-- How an issue view lists a tracker's issues (as a gh login; Jira ignores it) and loads one issue's details.
type TrackerApi = {
	search: (string?, string, () -> boolean, (tracker.IssueResult?, github.Problem?, number) -> ()) -> (),
	detail: (tracker.Issue, string?, (tracker.IssueDetail?, github.Problem?) -> (), () -> boolean) -> (),
}
local TRACKERS: { [string]: TrackerApi } = {
	github = {
		search = github.issues,
		detail = function(issue, account, done, live)
			github.issue(issue.repo, tonumber(issue.ref) :: number, account, done, live)
		end,
	},
	jira = {
		search = function(_account, query, live, done)
			jira.issues(query, live, done)
		end,
		detail = function(issue, _account, done, live)
			jira.issue(issue.ref, done, live)
		end,
	},
}

-- A saved search: `kind` is what it lists ("prs" | "issues", a key of KINDS) and its `id` is "<kind>:<its id in that
-- kind's kv store>" (the pinned pull request's is "pin"), so ids are the block's own whichever store a view is in.
-- `integration` is the tracker it asks ("github" | "jira"), `logins` the gh logins a GitHub view runs
-- as (none: gh's active account; with several, the view is one sidebar scope under each login, running as it),
-- `group` how the list is grouped ("none" or a GROUPS value) and `prompts` the ids of the prompts offered under it, in
-- its kind's prompt store (none: every prompt).
type View = { id: string, kind: string, name: string, integration: string, query: string, logins: { string }, group: string, prompts: { string } }
type Views = { version: number, nextId: number, items: { View } }
-- An agent prompt from Settings › Prompts; the views list which of them they offer. `key` runs it on the selected
-- item from the queue. `worktree` (nil means true) says where it runs: in the item's worktree, or in the repository's
-- main checkout. `split` (nil means false) opens its agent as a block beside the queue in the queue's tab rather than
-- in a tab of its own. `model` (nil: omp's default) is what `omp --model` runs it with: a model pattern or a role
-- alias such as @slow.
type Prompt = { id: string, name: string, text: string, key: string?, worktree: boolean?, split: boolean?, model: string? }
type Prompts = { version: number, nextId: number, items: { Prompt } }
-- A row of a `?` list: its fixed keys, then the configured key of each of its `actions` (Settings › Keyboard shortcuts; a removed
-- one adds none), and what they do. A row left with no key is not listed.
type KeyHelp = { keys: { string }, actions: { string }?, text: string }
-- What tells pull request views and issue views apart; the rest is one engine. The active view's is State.kind.
type Kind = {
	id: string, -- "prs" | "issues": a View's and a Snap's `kind`, and the prefix of the ids of its views
	label: string, -- "Pull requests" | "Issues"
	one: string, -- "pull request" | "issue"
	many: string, -- "pull requests" | "issues"
	icon: string, -- the icon of its views in the sidebar, and the picker's
	viewsKey: string, -- kv key of the saved views
	promptsKey: string, -- kv key of the saved prompts
	integrations: { string }, -- the trackers its views may use, the first a new view's: "github" | "jira" (keys TRACKERS and INTEGRATIONS)
	seeds: { { id: string, name: string, integration: string, query: string, group: string } }, -- the views of a first run, by their id in the kv store
	keys: { KeyHelp }, -- the `?` list of the queue
	vars: { { k: { Span }, v: string } }, -- the prompt editor's legend of variables
	prompts: { { id: string, name: string, text: string, worktree: boolean? } }, -- offered until its saved prompts are first changed
}
-- `rows` caches the picker rows; `rowsRev` (worktree reports) and `rowsMin` (the minute, for the ages) say what built them.
type Snap = {
	kind: string, -- what its items are: "prs" (github.Pr) or "issues" (tracker.Issue)
	items: { any },
	total: number,
	complete: boolean,
	fetched: number,
	rows: { any }?,
	rowsRev: number?,
	rowsMin: number?,
	rowsOpen: string?, -- the key that goes to a tab, then the ids of the items open in a tab, comma-joined
}
-- What the local search lets through: computed once per snapshot and search text.
type Visible = { snap: Snap, needle: string, group: string, items: { any }, order: { any }, hits: { [string]: any }? }
-- One way to group a list: the view's `group` value, its label in Settings and the group an item falls in. `keep`: the
-- groups follow the list's order (status, sorted by its category) instead of their labels'.
type Group = { value: string, label: string, of: (any) -> string, keep: boolean? }
-- The two kinds of view by id ("prs" | "issues"); assigned below, with the wording and keys each brings.
local KINDS: { [string]: Kind }
-- What each kind can group each integration's items by; assigned below, once the badges it reads are defined.
local GROUPS: { [string]: { [string]: { Group } } }
local function groupsOf(kindId: string, integration: string): { Group }
	local list: { Group } = GROUPS[kindId][integration] or {}
	return list
end
-- `round` is the State.round it was loaded in: an older list is still shown while it loads again.
-- `about` is the PR's merge state, reviewers and description, nil when gh did not print them. `issue` is an issue's
-- body, milestone and linked pull requests (a PR's `runs` and `total` are then empty).
type Detail = { runs: { github.Run }, total: number, round: number, about: github.About?, issue: tracker.IssueDetail? }
-- A checks load that failed: why, how often, and when to try again (nil: only an explicit Retry).
type DetailFail = { problem: github.Problem, tries: number, retryAt: number? }
-- The one checks load waiting out its debounce or retry delay. Its identity is the table: only the owner may clear it.
type Attempt = { key: string, timer: TimerHandle? }
-- What the worktree card and the row's badge say of an item's worktree. Nothing is saved: git is the source, so a fresh
-- block (or one after a plugin reload) shows the worktrees that exist. Every scan of the listed items' checkouts (`git
-- worktree list`, after each refresh, Worktree attempt and removal) gives a worktree its `root`, `path`, `branch`, `ref`
-- (what removing it takes), `head` and, for a pull request, `current` (its head is the PR's head the last refresh saw)
-- and the `update` commands; it takes the note of a worktree git no longer lists. `dirty` is read with `git status`
-- for the selected item only: nil until then (`checked`: in which State.round; `checking`: that read is on its way). A
-- note also starts as the outcome of a Worktree attempt (a report, or why there is none), which the next scan confirms
-- (`git`). `refused` is why the last removal did not go through. `kind` is what the item is: a worktree is never read as
-- the other kind's (a note of a pull request has the head to compare, an issue's has none).
type Note = {
	seq: number,
	kind: string, -- what its item is: "prs" or "issues"
	at: number,
	ok: boolean,
	current: boolean,
	dirty: boolean?,
	root: string?,
	path: string?,
	branch: string?,
	ref: string?,
	summary: string?,
	message: string?,
	refused: string?,
	update: { string },
	git: boolean?,
	head: string?,
	checked: number?,
	checking: boolean?,
}
-- What a worktree attempt found, as the preview notes it: the same for pull requests and issues. `current`: the
-- worktree holds what it should (a PR's head; an issue's branch always does). `ref`: a pull request's fetched ref.
type Report = { root: string, path: string, branch: string, ref: string?, current: boolean, dirty: boolean?, summary: string, update: { string } }
type Settings = {
	page: string, -- "views" | "prompts" | "keys" | "worktrees" | "repos" | "jira" | "connection"
	focus: string?, -- focused prefs row id
	open: string?, -- the item whose form is expanded: a view or prompt ("<kind id>:<saved id>"), a repository or a Jira project key; every other one shows as a one-row summary
	edit: { row: string, model: input.Model }?, -- text row being edited; a multi-line model is a prompt's text; a shortcut row ("key:", "pkey:") takes the next key
	pick: { row: string, option: string? }?, -- a choice or chips row the keys drive, `option` highlighted
	errors: { [string]: string? }, -- row id -> warning under the row
	confirm: string?, -- delete row ("delete:<view id>", "pdelete:<prompt id>", "rremove:<repo>" or "jremove:<key>") awaiting confirmation; view and prompt ids are qualified by their kind
}

type State = {
	cx: BlockCx,
	kind: Kind, -- the active view's, as identify keeps it (a block with no view keeps its last)
	launchCwd: string?,
	activeId: string?,
	activeLogin: string?, -- the gh login of the active scope when the view lists several: each login is its own scope in the sidebar (nil: the first)
	views: { View }, -- every saved view of both kinds, pull request views first (kv views-prs, then views-issues)
	pin: View?, -- one pull request shown on its own (showPr), the sidebar's first scope; never saved with the views
	locked: { [string]: string }, -- kind id -> why its saved views cannot be changed (unreadable, malformed, unwritable); absent: they can
	snaps: { [string]: Snap },
	snap: Snap?,
	cursor: string?,
	focus: string, -- the picker part the keys drive: "list" | "scopes"
	inflight: number?, -- generation of the search request that owns the spinner
	gen: number,
	account: string, -- the gh login ("" = the active gh account) the data and requests belong to
	tracker: string, -- the integration the data and requests belong to
	applied: string?, -- the snapshot key (snapKey) the shown snapshot belongs to
	cost: number,
	interval: number?,
	nextAt: number?,
	claiming: string?, -- lowercase repository whose checkout folder is being verified or cloned into
	problem: github.Problem?,
	timer: TimerHandle?,
	query: input.Model?, -- nil: the search is hidden
	help: boolean, -- the shortcut list is open
	vis: Visible?,
	details: { [string]: Detail }, -- loaded details per item: all checks of a PR, the body of an issue (key: account, item and update time)
	detailFail: { [string]: DetailFail },
	detailBusy: { [string]: boolean }, -- checks loads running
	detailAttempt: Attempt?,
	round: number, -- search results taken so far: checks can finish without moving a PR's update time, so each result makes the loaded checks stale
	notes: { [string]: Note }, -- worktree cards by item key
	descOpen: string?, -- key of the item whose description is unfolded; the view mirrors it so Show less can fold it again
	removing: string?, -- key of the item whose worktree the user is asked to remove (a confirm overlay); nil: none
	noteSeq: number, -- moves whenever a note changes: the picker's cached rows carry the Worktree badges
	scanned: Snap?, -- the snapshot whose checkouts the last scan was started for; nil: a scan is due (a worktree was made or removed)
	scanning: boolean, -- a scan of the shown items' checkouts is running
	settings: Settings?,
	settingsPage: string?, -- the Settings page last shown: Settings opens on it again
	replies: { { id: string, text: string } }, -- answers to window requests, oldest first
	listing: number, -- repository picker lists still waiting on GitHub: the heading shows a loader meanwhile
}

local running: { [number]: State } = {}

-- The CLI each integration runs on, whether it starts on this host (`installed`; absent: not known yet) and where its
-- install guide is. An integration is on only once its CLI is known to start: until then none of its views, groups
-- or requests exist, and while it does not start Settings shows its setup page instead.
local cli = {
	list = {
		{ id = "github", argv = { "gh", "--version" }, url = "https://github.com/cli/cli#installation" },
		{ id = "jira", argv = { "acli", "--version" }, url = "https://developer.atlassian.com/cloud/acli/guides/install-acli/" },
	},
	installed = {} :: { [string]: boolean },
	probing = {} :: { [string]: boolean },
	moved = false, -- an answer of the probes running differs from the one before
}

-- Whether integration `id` ("github" | "jira") is on: its CLI starts on this host.
function cli.on(id: string): boolean
	return cli.installed[id] == true
end

-- Whether every CLI's answer is in: before that, no view is shown or loaded.
function cli.ready(): boolean
	for _, c in cli.list do
		if cli.installed[c.id] == nil then
			return false
		end
	end
	return true
end

-- gh's active login on this host once known (`login`), the logins signed in (`accounts`) and the helpers that use them:
-- the sidebar groups of views that run as one login.
local ghActive: {
	login: string?,
	accounts: { string },
	note: (State, boolean?) -> (),
	shown: (View) -> string,
	isActive: (State, Scope) -> boolean,
} = {
	login = nil,
	accounts = {},
	note = function() end,
	shown = function()
		return ""
	end,
	isActive = function()
		return false
	end,
}

-- ---------------------------------------------------------------- storage

-- `type(v) == "table"` without refining an untrusted `any`.
local function isTable(v: any): boolean
	return type(v) == "table"
end

local function seedViews(kind: Kind): Views
	local items: { View } = {}
	for _, v in kind.seeds do
		table.insert(items, { id = kind.id .. ":" .. v.id, kind = kind.id, name = v.name, integration = v.integration, query = v.query, logins = {}, group = v.group, prompts = {} })
	end
	return { version = 1, nextId = #items + 1, items = items }
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
			or (f.login ~= nil and (type(f.login) ~= "string" or not string.match(f.login, "^[%w%-]+$")))
			or type(f.group) ~= "string"
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
			if type(who) ~= "string" or not string.match(who, "^[%w%-]+$") then
				return nil
			end
			if not seen[string.lower(who)] and f.integration == "github" then
				seen[string.lower(who)] = true
				table.insert(logins, who)
			end
		end
		table.insert(items, { id = kind.id .. ":" .. f.id, kind = kind.id, name = f.name, integration = f.integration, query = f.query, logins = logins, group = f.group, prompts = prompts })
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

local function writeViews(kind: Kind, store: Views): string?
	local items: { any } = {}
	for _, v in store.items do
		table.insert(items, { id = string.sub(v.id, #kind.id + 2), name = v.name, integration = v.integration, query = v.query, logins = tern.json.array(v.logins), group = v.group, prompts = tern.json.array(v.prompts) })
	end
	return kvSet(kind.viewsKey, { version = 1, nextId = store.nextId, items = tern.json.array(items) })
end

-- views, writable, error. The views' ids are "<kind>:<saved id>". An absent key is seeded; unreadable or malformed
-- storage is never overwritten: seeds are shown but Save is disabled.
local function loadViews(kind: Kind): (Views, boolean, string?)
	local ok, v = pcall(tern.kv.get, kind.viewsKey)
	if not ok then
		return seedViews(kind), false, "Saved " .. kind.one .. " views could not be read: " .. tostring(v)
	end
	if v == nil then
		local s = seedViews(kind)
		local err = writeViews(kind, s)
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
local function loadAll(state: State)
	local all: { View } = {}
	for _, kind in { KINDS.prs, KINDS.issues } do
		local store, writable, err = loadViews(kind)
		if writable then
			state.locked[kind.id] = nil
		else
			state.locked[kind.id] = err or "Saved " .. kind.one .. " views are read-only."
		end
		for _, v in store.items do
			if cli.on(v.integration) then
				table.insert(all, v)
			end
		end
	end
	state.views = all
end

-- The kind and the saved id of a view or prompt as Settings names it: "<kind id>:<id in that kind's kv store>".
local function kindAndId(qid: string): (Kind?, string)
	local k, id = string.match(qid, "^(%a+):(.+)$")
	return (if k then KINDS[k] else nil), id or qid
end

-- The strings of a saved list; anything else in it is dropped.
local function stringList(v: any): { string }
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
local function readCheckouts(): { [string]: any }
	local ok, v = pcall(tern.kv.get, "checkouts")
	if ok and isTable(v) then
		return v
	end
	return {}
end

-- The saved local checkout of `repo`, nil when none: then the window's palette asks for one before anything makes a
-- worktree of it.
local function checkoutOf(repo: string): string?
	local path = readCheckouts()[string.lower(repo)]
	return if type(path) == "string" and path ~= "" then path else nil
end

-- Saves `path` as `repo`'s checkout ("": none, but still listed); with `keep`, only a repository not saved yet. Fails
-- closed when the saved map cannot be read.
local function saveCheckout(repo: string, path: string, keep: boolean?): string?
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

-- Saved worktree setup commands per repository (kv "setup-commands", keyed like "checkouts"), or nil and why
-- when unreadable: a write then fails closed rather than overwrite them.
local function setupMap(): ({ [string]: any }?, string?)
	local ok, stored = pcall(tern.kv.get, "setup-commands")
	if not ok or (stored ~= nil and not isTable(stored)) then
		return nil, "Saved setup commands could not be read."
	end
	return if stored ~= nil then stored else {}, nil
end

local function setupOf(map: { [string]: any }, repo: string): { string }
	return stringList(map[string.lower(repo)])
end

-- Branch and worktree folder name formats (Settings › Repositories). One table: host.luau is at Luau's 200-local limit.
local formats = {}

-- Saved branch name formats per repository (kv "branch-formats", keyed like "checkouts"), or nil and why when
-- unreadable: a write then fails closed rather than overwrite them.
function formats.repoMap(): ({ [string]: any }?, string?)
	local ok, stored = pcall(tern.kv.get, "branch-formats")
	if not ok or (stored ~= nil and not isTable(stored)) then
		return nil, "Saved branch formats could not be read."
	end
	return if stored ~= nil then stored else {}, nil
end

-- The branch name format saved for `repo`; nil when none is (the Worktrees format applies) or they cannot be read.
function formats.repoOf(repo: string): string?
	local map = formats.repoMap()
	local fmt = if map then map[string.lower(repo)] else nil
	return if type(fmt) == "string" and fmt ~= "" then fmt else nil
end

-- Saved repositories per Jira project (kv "jira-repos": KEY to lowercase "owner/name" list), or nil and why when
-- unreadable: a write then fails closed rather than overwrite them.
local function readJiraRepos(): ({ [string]: any }?, string?)
	local ok, stored = pcall(tern.kv.get, "jira-repos")
	if not ok or (stored ~= nil and not isTable(stored)) then
		return nil, "Saved Jira project repositories could not be read."
	end
	return if stored ~= nil then stored else {}, nil
end

-- The repositories Jira project `project` is worked in: the valid "owner/name" strings saved for it, in saved order.
local function jiraReposOf(project: string): { string }
	local map = readJiraRepos()
	local out: { string } = {}
	for _, r in stringList(if map then map[project] else nil) do
		local owner, name = string.match(r, "^([^/]+)/([^/]+)$")
		if owner and name and worktree.validSegment(owner) and worktree.validSegment(name) then
			table.insert(out, r)
		end
	end
	return out
end

-- Rereads the Jira project map, lets `fn` change it (an error string aborts) and saves it; an error message or nil.
local function editJiraRepos(fn: ({ [string]: any }) -> string?): string?
	local map, err = readJiraRepos()
	if not map then
		return err
	end
	local ferr = fn(map)
	if ferr then
		return ferr
	end
	local out: { [string]: any } = {}
	for key, list in map do
		out[key] = tern.json.array(stringList(list))
	end
	local werr = kvSet("jira-repos", out)
	return if werr then "Could not save: " .. werr else nil
end

-- Name formats for every repository (Settings › Repositories › Worktrees): the branch of an issue's worktree, and the
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
local function removeRepo(repo: string): string?
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
	local jerr = editJiraRepos(function(map: { [string]: any }): string?
		for project, list in map do
			local keep: { string } = {}
			for _, r in stringList(list) do
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
local PROMPT_CAP = 8000 -- bytes of one prompt's text: several must fit one answer to the window (MENU_BUDGET)

-- Saved agent prompts (kv prompts-prs / prompts-issues; absent: the kind's default prompts, saved with the first edit),
-- or nil and why when unreadable or malformed: a write then fails closed rather than overwrite them.
local function loadPrompts(kind: Kind): (Prompts?, string?)
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
		then
			return nil, PROMPTS_BAD
		end
		table.insert(items, { id = p.id, name = p.name, text = p.text, key = p.key, worktree = p.worktree, split = p.split, model = p.model })
	end
	return { version = 1, nextId = v.nextId, items = items }, nil
end

-- Rereads the prompts, lets `fn` change them (an error string aborts) and saves them; an error message or nil.
local function editPrompts(kind: Kind, fn: (Prompts) -> string?): string?
	local store, err = loadPrompts(kind)
	if not store then
		return err
	end
	local ferr = fn(store)
	if ferr then
		return ferr
	end
	local items: { any } = {}
	for _, p in store.items do
		table.insert(items, { id = p.id, name = p.name, text = p.text, key = p.key, worktree = p.worktree, split = p.split, model = p.model })
	end
	local werr = kvSet(kind.promptsKey, { version = 1, nextId = store.nextId, items = tern.json.array(items) })
	return if werr then "Could not save: " .. werr else nil
end

local function promptById(store: Prompts, id: string): Prompt?
	for _, p in store.items do
		if p.id == id then
			return p
		end
	end
	return nil
end

-- The prompts view `v` lists, as ids of prompts that still exist, in the prompts' order; empty: it lists none.
local function livePrompts(v: View, list: { Prompt }): { string }
	local out: { string } = {}
	for _, p in list do
		if table.find(v.prompts, p.id) then
			table.insert(out, p.id)
		end
	end
	return out
end

-- ---------------------------------------------------------------- lifecycle

-- Cancels the checks load waiting out its debounce or retry delay, if any.
local function cancelDetails(state: State)
	local waiting = state.detailAttempt
	if waiting then
		state.detailAttempt = nil
		if waiting.timer then
			waiting.timer:cancel()
		end
	end
end

-- Forgets every loaded or failed checks list. Loads still running are dropped when they land: they compare the account.
local function dropDetails(state: State)
	cancelDetails(state)
	state.details, state.detailFail = {}, {}
end

local function retire(state: State)
	if running[state.cx.pane] == state then
		running[state.cx.pane] = nil
	end
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	dropDetails(state)
	state.inflight = nil
	state.snap, state.vis = nil, nil
	state.snaps = {}
	state.problem = nil
	state.cursor = nil
end

local function alive(state: State): boolean
	if running[state.cx.pane] ~= state then
		return false
	end
	for _, p in tern.pane.list() do
		if p.pane == state.cx.pane then
			return true
		end
	end
	retire(state)
	return false
end

-- Learns gh's active login (cached by github.accounts) and redraws when it changed, so views without a login of their own
-- sit under whichever account is active. Only views of GitHub ask (`always`: asked anyway), and never while gh is off.
function ghActive.note(state: State, always: boolean?)
	local any = always == true and cli.on("github")
	for _, v in state.views do
		any = any or v.integration == "github"
	end
	if not any then
		return
	end
	github.accounts(function(list)
		local found: string? = nil
		local names: { string } = {}
		if list then
			for _, a in list do
				table.insert(names, a.login)
				if a.active then
					found = a.login
				end
			end
		end
		local known = table.concat(ghActive.accounts, ",")
		if list then
			ghActive.accounts = names
		end
		if (found and found ~= ghActive.login) or (list ~= nil and known ~= table.concat(names, ",")) then
			ghActive.login = found or ghActive.login
			if alive(state) then
				state.cx:render()
			end
		end
	end)
end

local function activeView(state: State): View?
	local pin = state.pin
	if pin and pin.id == state.activeId and cli.on("github") then
		return pin
	end
	for _, v in state.views do
		if v.id == state.activeId then
			return v
		end
	end
	return nil
end

-- The gh login view `v` runs as in the scope that picked `login` (nil, or one it does not list: its first): "" is gh's
-- active account. Jira has none.
local function accountOf(v: View, login: string?): string
	if v.integration ~= "github" or #v.logins == 0 then
		return ""
	end
	if login then
		for _, who in v.logins do
			if string.lower(who) == string.lower(login) then
				return who
			end
		end
	end
	return v.logins[1]
end

-- The logins a view's summary in Settings names: its own, in the order saved; else gh's active one ("" while that is
-- unknown, and for Jira, which has none).
function ghActive.shown(v: View): string
	if v.integration ~= "github" then
		return ""
	end
	return if #v.logins > 0 then table.concat(v.logins, ", ") else (ghActive.login or "")
end

-- One row of the sidebar: a view as one login runs it. A view that lists several logins is one scope under each login's
-- group (`login` is that login, the scope's id "<view id>@<login>"); any other view is one scope, under its login's
-- group or, with none, under gh's active one. `shown` is the login its group names ("" for Jira, or while unknown).
type Scope = { id: string, view: View, login: string?, shown: string }

-- The scopes as the sidebar lists them: the pinned pull request first (while gh is on), as gh's active login runs it;
-- then, by integration, each one's views within the group of the login they run as (pull request views, then issue
-- views, each in store order); groups by login, sorted by name.
local function orderedViews(state: State): { Scope }
	local out: { Scope } = {}
	local pin = state.pin
	if pin and cli.on("github") then
		table.insert(out, { id = pin.id, view = pin, login = nil, shown = ghActive.login or "" })
	end
	for _, id in { "github", "jira" } do
		local keys: { string } = {}
		local groups: { [string]: { Scope } } = {}
		for _, v in state.views do
			if v.integration ~= id then
				continue
			end
			local runs: { string } = if #v.logins > 0 and id == "github" then v.logins else { "" }
			for _, who in runs do
				local shown = if who ~= "" then who elseif id == "github" then (ghActive.login or "") else ""
				local key = string.lower(shown)
				if not groups[key] then
					groups[key] = {}
					table.insert(keys, key)
				end
				table.insert(groups[key], {
					id = if #v.logins > 1 then v.id .. "@" .. who else v.id,
					view = v,
					login = if who ~= "" then who else nil,
					shown = shown,
				})
			end
		end
		table.sort(keys)
		for _, key in keys do
			for _, scope in groups[key] do
				table.insert(out, scope)
			end
		end
	end
	return out
end

-- Whether `scope` is the one the block shows: its view, and for a view of several logins its login.
function ghActive.isActive(state: State, scope: Scope): boolean
	if scope.view.id ~= state.activeId then
		return false
	end
	return #scope.view.logins <= 1 or string.lower(scope.login or "") == string.lower(accountOf(scope.view, state.activeLogin))
end

local function indexOf(items: { any }, key: string?): number
	for i, item in items do
		if item.key == key then
			return i
		end
	end
	return 0
end

-- The item under the cursor, a github.Pr (prs) or a tracker.Issue (issues); nil when there is none.
local function selected(state: State): any
	local snap = state.snap
	if snap then
		return snap.items[indexOf(snap.items, state.cursor)]
	end
	return nil
end

-- Keys ("owner/repo#n", "abc#ABC-12") of the items whose worktree (as its note has it) holds some pane's cwd on this host.
local function openItems(state: State): { [string]: boolean }
	local open: { [string]: boolean } = {}
	local mine: { [string]: string } = {}
	for key, note in state.notes do
		if note.ok and note.path then
			mine[key] = note.path
		end
	end
	if next(mine) == nil then
		return open
	end
	for _, p in tern.pane.list() do
		local cwd = p.cwd
		if cwd then
			for key, path in mine do
				if worktree.within(cwd, path) then
					open[key] = true
				end
			end
		end
	end
	return open
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

-- `raw` as a GitHub "owner/name" (both parts valid worktree segments, trimmed); nil when it is not one.
local function parseRepo(raw: any): string?
	local owner, name = string.match(if type(raw) == "string" then trim(raw) else "", "^([^/]+)/([^/]+)$")
	if owner and name and worktree.validSegment(owner) and worktree.validSegment(name) then
		return owner .. "/" .. name
	end
	return nil
end

-- Picker ids hold no `/` or `#`: the item's key ("owner/repo#n", or "abc#ABC-12") with every other character spelled
-- `_xx`, `_` included, so two keys never share one.
local function itemId(item: any): string
	return "n" .. (string.gsub(item.key, "[^%w%-]", function(c: string): string
		return string.format("_%02x", string.byte(c))
	end))
end

local function itemOf(state: State, id: string): any
	local snap = state.snap
	if snap then
		for _, item in snap.items do
			if itemId(item) == id then
				return item
			end
		end
	end
	return nil
end

-- Whether `item` matches the search text, and the matched UTF-16 range in its title (nil when elsewhere or blank).
local function matchItem(kind: string, item: any, text: string): (boolean, { number }?)
	if kind == "issues" then
		return tracker.match(item, text)
	end
	return github.match(item, text)
end

-- The items the local search lets through, in snapshot order, with their picker ids and title hits. Recomputed only when
-- the snapshot or the search text changes.
local function filtered(state: State): Visible?
	local snap = state.snap
	if not snap then
		return nil
	end
	local text = if state.query then state.query.text else ""
	local view = activeView(state)
	local group = if view then view.group else "none"
	local cached = state.vis
	if cached and cached.snap == snap and cached.needle == text and cached.group == group then
		return cached
	end
	local spec: Group? = nil
	if view then
		for _, g in groupsOf(snap.kind, view.integration) do
			if g.value == group then
				spec = g
			end
		end
	end
	local kept: { any } = {}
	local hits: { [string]: any } = {}
	local hasHits = false
	local blank = trim(text) == ""
	for _, item in snap.items do
		local ok = true
		local range: { number }? = nil
		if not blank then
			ok, range = matchItem(snap.kind, item, text)
		end
		if ok then
			table.insert(kept, item)
			if range then
				hits[itemId(item)] = { range }
				hasHits = true
			end
		end
	end
	local items: { any } = {}
	local order: { any } = {}
	if spec then
		-- Headers of the groups, in label order, each followed by its items; navigation walks `items`, so a header is never selected.
		local buckets: { [string]: { any } } = {}
		local labels: { string } = {}
		for _, item in kept do
			local label = spec.of(item)
			local bucket = buckets[label]
			if not bucket then
				bucket = {}
				buckets[label] = bucket
				table.insert(labels, label)
			end
			table.insert(bucket, item)
		end
		if not spec.keep then
			table.sort(labels, function(a: string, b: string): boolean
				local x, y = string.lower(a), string.lower(b)
				if x ~= y then
					return x < y
				end
				return a < b
			end)
		end
		for _, label in labels do
			local bucket = buckets[label]
			table.insert(order, { group = label, label = label, count = #bucket })
			for _, item in bucket do
				table.insert(items, item)
				table.insert(order, itemId(item))
			end
		end
	else
		for _, item in kept do
			table.insert(items, item)
			table.insert(order, itemId(item))
		end
	end
	local out: Visible = { snap = snap, needle = text, group = group, items = items, order = tern.json.array(order), hits = if hasHits then hits else nil }
	state.vis = out
	return out
end

-- Keep the cursor on a visible result (the first when it vanished).
local function ensureCursor(state: State)
	local v = filtered(state)
	local items: { any } = if v then v.items else {}
	if indexOf(items, state.cursor) == 0 then
		state.cursor = if items[1] then items[1].key else nil
	end
end

-- ---------------------------------------------------------------- identity

-- The gh login the active scope runs as (nil: the active gh account), for github.wait and quota and every gh call.
local function login(state: State): string?
	local v = activeView(state)
	local who = if v then accountOf(v, state.activeLogin) else ""
	return if who ~= "" then who else nil
end

-- The active view's integration: what a search, wait or heading of the block belongs to.
local function trackerOf(state: State): string
	local v = activeView(state)
	return if v then v.integration else state.kind.integrations[1]
end

-- Seconds every pane must still wait before a search of this block's tracker: only GitHub has a shared quota.
local function waitOf(state: State): number
	return if trackerOf(state) == "github" then github.wait(os.time(), login(state)) else 0
end

-- Cache key of a snapshot: what it lists, integration, the gh login the scope runs as and query.
local function snapKey(v: View, login: string?): string
	return v.kind .. "\0" .. v.integration .. "\0" .. string.lower(accountOf(v, login)) .. "\0" .. v.query
end

-- Cache key of an item's loaded details (a PR's checks, an issue's body); the login is part of it, so one identity
-- never sees another's.
local function detailKey(state: State, item: any): string
	return state.account .. "\0" .. item.key .. "@" .. item.updated
end

-- Drops everything shown, cached or running under the previous gh identity.
local function forget(state: State)
	state.gen += 1
	state.snaps, state.snap, state.vis, state.problem = {}, nil, nil, nil
	dropDetails(state)
end

-- `state.account`, `state.tracker` and `state.kind` are the identity everything on screen and in flight belongs to: the
-- active view's gh login, integration and kind. A different one drops all data and problems of the old one.
local function identify(state: State)
	local v = activeView(state)
	local account = if v then accountOf(v, state.activeLogin) else ""
	local integration = if v then v.integration else state.kind.integrations[1]
	local kind = if v then KINDS[v.kind] else state.kind
	if account ~= state.account or integration ~= state.tracker or kind ~= state.kind then
		state.account, state.tracker, state.kind = account, integration, kind
		forget(state)
	end
end

-- Shows the cached snapshot of the active scope.
local function showSnapshot(state: State)
	identify(state)
	local v = activeView(state)
	state.applied = if v then snapKey(v, state.activeLogin) else nil
	state.snap = if v then state.snaps[snapKey(v, state.activeLogin)] else nil
	ensureCursor(state)
end

local refresh: (State) -> ()

-- Problems that retrying cannot fix by itself: no automatic refresh until an explicit Retry. "invalid" belongs to one
-- query, "not-found" to a repository or project the login cannot see (each tracker's classifier reports it).
local TERMINAL: { [string]: boolean } = { auth = true, missing = true, ["not-found"] = true, invalid = true }

local HEADS: { [string]: string } = {
	missing = "GitHub CLI not found",
	auth = "GitHub CLI not signed in",
	["rate-limit"] = "GitHub rate limit",
	["not-found"] = "Repository not visible",
	invalid = "GitHub rejected the search",
}
local HELP: { [string]: string } = {
	missing = "Install the GitHub CLI (cli.github.com) so it is on your shell's PATH, then Refresh.",
	auth = "Run gh auth login in a terminal, then Refresh.",
	["rate-limit"] = "Searches resume automatically when GitHub's limit resets.",
	["not-found"] = "Check this view's GitHub login in Settings › Views, then Refresh.",
	invalid = "Check the view's query and login in Settings › Views, then Refresh.",
}
local JIRA_HEADS: { [string]: string } = {
	missing = "Atlassian CLI not found",
	auth = "Atlassian CLI not signed in",
	["rate-limit"] = "Jira rate limit",
	["not-found"] = "Project not visible",
	invalid = "Jira rejected the search",
}
local JIRA_HELP: { [string]: string } = {
	missing = "Install Atlassian's CLI (acli) so it is on your shell's PATH, then Refresh.",
	auth = "Run acli jira auth login in a terminal, then Refresh.",
	["rate-limit"] = "Searches resume at the next refresh.",
	["not-found"] = "Check the view's JQL in Settings › Views, then Refresh.",
	invalid = "Check the view's JQL in Settings › Views, then Refresh.",
}

-- The heading of problem kind `k`, nil when it has none; a failed load names what it was loading.
local function headOf(state: State, k: string): string?
	if k == "failed" then
		return "Could not load " .. state.kind.many
	end
	return if trackerOf(state) == "jira" then JIRA_HEADS[k] else HEADS[k]
end

-- What to do about problem kind `k`, nil when there is no advice.
local function helpOf(state: State, k: string): string?
	return if trackerOf(state) == "jira" then JIRA_HELP[k] else HELP[k]
end

-- Panes of this runtime that still exist; they share one search quota.
local function openPanes(): number
	local open: { [number]: boolean } = {}
	for _, p in tern.pane.list() do
		open[p.pane] = true
	end
	local n = 0
	for pane in running do
		if open[pane] then
			n += 1
		end
	end
	return math.max(1, n)
end

-- Arms the next automatic refresh, never earlier than the server's cooldown allows.
local function schedule(state: State, ms: number)
	if state.timer then
		state.timer:cancel()
	end
	ms = math.max(ms, waitOf(state) * 1000)
	state.nextAt = os.time() + math.ceil(ms / 1000)
	state.timer = tern.timer(ms, function()
		if not alive(state) then
			return
		end
		state.timer = nil
		refresh(state)
		state.cx:render()
	end)
end


-- Checks, failures and folds of PRs that no cached snapshot lists any more (or lists with a newer update) cannot be shown again.
local function prune(state: State)
	local live: { [string]: boolean } = {}
	local keep: { [string]: boolean } = {}
	for _, snap in state.snaps do
		for _, item in snap.items do
			live[item.key] = true
			local key = detailKey(state, item)
			if key then
				keep[key] = true
			end
		end
	end
	for key in state.details do
		if not keep[key] then
			state.details[key] = nil
		end
	end
	for key in state.detailFail do
		if not keep[key] then
			state.detailFail[key] = nil
		end
	end
end

refresh = function(state: State)
	if not alive(state) then
		return
	end
	if state.timer then
		state.timer:cancel()
		state.timer = nil
	end
	identify(state)
	local halted = state.problem
	if halted and TERMINAL[halted.kind] then
		return
	end
	if state.inflight == state.gen then
		return -- the request for the current query is already running
	end
	local v = activeView(state)
	if not v then
		state.problem = nil
		return
	end
	-- The server's cooldown holds for every trigger, manual refresh included.
	local wait = waitOf(state)
	if wait > 0 then
		-- Nothing is loading: say why, so an uncached view does not show a spinner until the reset.
		state.problem = { kind = "rate-limit", message = "GitHub's rate limit is reached; searches resume at " .. os.date("%H:%M:%S", os.time() + wait) .. "." }
		return schedule(state, wait * 1000)
	end
	local gen, query, integration = state.gen, v.query, v.integration
	local key = snapKey(v, state.activeLogin)
	state.inflight = gen
	local function current(): boolean
		return running[state.cx.pane] == state and state.gen == gen
	end
	local kind = v.kind -- what this request lists, whichever view is active when it lands
	local issues = kind == "issues"
	-- `result` is a github.SearchResult (prs) or a tracker.IssueResult (issues).
	local function landed(result: any, problem: github.Problem?, spent: number)
		if not alive(state) then
			return
		end
		if state.inflight == gen then
			state.inflight = nil
		end
		if state.gen ~= gen or (problem and problem.kind == "superseded") then
			-- The query or the login changed meanwhile and its own request is running or paused: only the spent quota counts.
			if spent > 0 then
				state.cost = math.max(spent, state.cost)
			end
			state.cx:render()
			return
		end
		if result then
			if issues then
				tracker.byStatus(result.issues)
			end
			local snap: Snap = { kind = kind, items = if issues then result.issues else result.prs, total = result.total, complete = result.complete, fetched = os.time() }
			state.snaps[key] = snap
			state.snap = snap
			state.round += 1 -- every loaded checks list is older than this result now
			state.problem = nil
			ensureCursor(state)
			prune(state)
			if integration == "github" then
				-- Warms the repository picker's list of gh logins (window.luau's pickRepo), so it opens without waiting on gh.
				ghActive.note(state)
			end
		else
			state.problem = problem
		end
		if spent > 0 then
			-- A finished snapshot shows the real points cost; a failed one keeps the larger known cost.
			state.cost = if result then spent else math.max(spent, state.cost)
			state.interval = github.interval(github.quota(login(state)), os.time(), state.cost, openPanes(), POLL_MS)
		elseif result and integration == "jira" then
			state.interval = POLL_MS -- Jira has no quota to pace: the plain minute
		else
			state.interval = nil -- nothing was sent (invalid query): no quota to pace
		end
		if not (problem and TERMINAL[problem.kind]) then
			schedule(state, state.interval or POLL_MS)
		end
		state.cx:render()
	end
	if issues then
		TRACKERS[integration].search(login(state), query, current, landed)
	elseif v == state.pin then
		github.pull(login(state), query, current, landed) -- the pin's query is its PR's URL
	else
		github.search(login(state), query, current, landed)
	end
end

-- A different applied query or login: invalidate whatever is in flight and reload now. A rejected query (HTTP 422)
-- belonged to the old query; the other pauses are about the environment and stay.
local function changed(state: State)
	state.gen += 1
	local p = state.problem
	if p and (p.kind == "invalid" or not TERMINAL[p.kind]) then
		state.problem = nil
	end
	showSnapshot(state)
	refresh(state)
end

-- Explicit user retry (`r`, Refresh, Retry): also asks again which CLIs start (one installed or removed meanwhile turns
-- its integration on or off once answered), forgets Jira's site and retries failed checks loads. The search it starts
-- makes the loaded checks stale (State.round): the selected PR's load again once it lands.
local function retry(state: State)
	process.reset()
	jira.reset()
	cli.probe(true)
	local p = state.problem
	if p and TERMINAL[p.kind] then
		state.problem = nil
	end
	state.detailFail = {}
	cancelDetails(state)
	if state.inflight == state.gen then
		local v = activeView(state)
		state.cx:toast("info", "Already refreshing", if v then v.name else nil)
	end
	refresh(state)
end

local function switchView(state: State, id: string?, activeLogin: string?)
	state.activeId, state.activeLogin = id, activeLogin
	identify(state)
	local v = activeView(state)
	local cached = if v then state.snaps[snapKey(v, state.activeLogin)] else nil
	local age = if cached then os.time() - cached.fetched else 0
	local fresh = math.floor((state.interval or POLL_MS) / 1000)
	local halted = state.problem
	local blocked = false
	if halted then
		blocked = TERMINAL[halted.kind] == true and halted.kind ~= "invalid"
	end
	if cached and state.inflight == nil and age < fresh and not blocked then
		-- A snapshot younger than the refresh interval: show it and keep polling on its schedule.
		state.problem = nil
		showSnapshot(state)
		schedule(state, (fresh - age) * 1000)
	else
		changed(state)
	end
end

-- After another block wrote the views, on restore or once the CLIs answered: reread storage; what is shown must match
-- it: the kind, integration, query and login of the active view are what the block remembers it applied (its snapshot
-- key). Until every CLI answered, an active view that is not listed yet stays the active one.
local function reloadViews(state: State)
	loadAll(state)
	local v = activeView(state)
	if not v then
		if cli.ready() then
			switchView(state, if state.views[1] then state.views[1].id else nil)
		end
	elseif snapKey(v, state.activeLogin) ~= state.applied then
		changed(state)
	end
end

-- Every other live block of this runtime follows a change made in `origin`. Closed panes are retired, not rendered.
local function propagate(origin: State)
	for _, s in running do
		if s ~= origin and alive(s) then
			reloadViews(s)
			s.cx:render()
		end
	end
end

-- ---------------------------------------------------------------- navigation

-- Moves the cursor `delta` rows through the visible items, clamped to the list.
local function moveCursor(state: State, delta: number)
	local v = filtered(state)
	if not v or #v.items == 0 then
		return
	end
	local i = indexOf(v.items, state.cursor)
	state.cursor = v.items[math.clamp(i + delta, 1, #v.items)].key
end

local function moveView(state: State, delta: number)
	local items = orderedViews(state)
	local at = 0
	for i, scope in items do
		if ghActive.isActive(state, scope) then
			at = i
		end
	end
	local target = items[math.clamp(at + delta, 1, math.max(1, #items))]
	if target and not ghActive.isActive(state, target) then
		switchView(state, target.view.id, target.login)
	end
end

-- ---------------------------------------------------------------- view

-- A span list for a node prop; spans and plain strings may mix.
local function spans(...: Span | string): { Span | string }
	return { ... }
end

-- Percent-encodes everything but unreserved URL characters.
local function pct(s: string): string
	return (string.gsub(s, "[^%w%-_%.~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function prHref(act: string, pr: github.Pr): string
	return "plotroom://github/" .. act .. "/" .. pr.repo .. "/" .. pr.number
end

-- The link that runs saved prompt `id` (letters and digits) on `pr`: the prompt's shortcut opens it.
local function runHref(pr: github.Pr, id: string): string
	return "plotroom://github/run/" .. pr.repo .. "/" .. pr.number .. "/" .. id
end

-- The same links for an issue: open carries the percent-encoded URL (the window compares it with the one shown), the
-- others the repository and the issue's ref.
local function issueHref(act: string, issue: tracker.Issue): string
	if act == "open" then
		return "plotroom://issue/open/" .. pct(issue.url)
	end
	return "plotroom://issue/" .. act .. "/" .. issue.repo .. "/" .. issue.ref
end

local function issueRunHref(issue: tracker.Issue, id: string): string
	return "plotroom://issue/run/" .. issue.repo .. "/" .. issue.ref .. "/" .. id
end

-- The link of action `act` (open | worktree | goto | agent) on `item`, and of the button that runs prompt `id` on it.
local function hrefOf(state: State, item: any, act: string): string
	return if state.kind.id == "issues" then issueHref(act, item) else prHref(act, item)
end

local function runHrefOf(state: State, item: any, id: string): string
	return if state.kind.id == "issues" then issueRunHref(item, id) else runHref(item, id)
end

-- "45s", "3m 20s", "1h 5m" for a whole number of seconds.
local function duration(s: number): string
	s = math.max(0, math.ceil(s))
	if s < 60 then
		return s .. "s"
	elseif s < 3600 then
		return (s // 60) .. "m" .. (if s % 60 > 0 then " " .. s % 60 .. "s" else "")
	end
	return (s // 3600) .. "h" .. (if s % 3600 >= 60 then " " .. (s % 3600) // 60 .. "m" else "")
end

-- `s` with control characters as spaces and, when it is not valid UTF-8, every non-ASCII byte as "?".
local function printable(s: string): string
	local out = string.gsub(s, "%c", " ")
	if utf8.len(out) == nil then
		out = string.gsub(out, "[\128-\255]", "?")
	end
	return out
end

-- `s` (valid UTF-8, see printable) cut to `max` characters.
local function clip(s: string, max: number): string
	local cut = utf8.offset(s, max + 1)
	return if cut and cut <= #s then string.sub(s, 1, cut - 1) .. "…" else s
end

-- The first line of `s`, cut to 160 characters.
local function brief(s: string): string
	return clip(printable(string.match(s, "[^\n]*") or ""), 160)
end

-- The adaptive refresh pace: cooldown while the server holds us back, else the interval and the next refresh (the
-- quota sits under this row). Nothing when no request was sent (invalid query).
local function paceLine(state: State): string?
	local halted = state.problem
	if halted and TERMINAL[halted.kind] then
		return "Auto-refresh paused: " .. (headOf(state, halted.kind) or halted.kind) .. ". Fix it, then Refresh."
	end
	local now = os.time()
	local wait = waitOf(state)
	if wait > 0 then
		return "Paused by GitHub rate limit until " .. os.date("%H:%M:%S", now + wait)
	elseif state.interval and state.nextAt and state.timer then
		return "Auto-refresh every " .. duration(state.interval / 1000) .. ", next at " .. os.date("%H:%M", state.nextAt) .. "."
	end
	return nil
end

-- ---------------------------------------------------------------- settings and queue views

local QUEUE_ID = "layer.queue"
local SETTINGS_ID = "layer.settings"
-- The Settings pages, in order, the same whatever the active kind: one that `needs` an integration only while it is on,
-- the `setup` page of one (its install guide) only while its CLI is known not to start.
local PAGE_DEFS: { { id: string, label: string, group: string, icon: string, needs: string?, setup: string? } } = {
	{ id = "views", label = "Views", group = "Queue", icon = "funnel" },
	{ id = "prompts", label = "Actions", group = "Queue", icon = "prompt" },
	{ id = "keys", label = "Keyboard shortcuts", group = "Queue", icon = "keyboard" },
	{ id = "worktrees", label = "Worktrees", group = "Code", icon = "tree" },
	{ id = "repos", label = "Repositories", group = "Code", icon = "folder" },
	{ id = "jira", label = "Jira projects", group = "Code", icon = "kanban", needs = "jira" },
	{ id = "connection", label = "Refresh", group = "Connection", icon = "gauge" },
	{ id = "setup-github", label = "GitHub", group = "Setup", icon = "merge", setup = "github" },
	{ id = "setup-jira", label = "Jira", group = "Setup", icon = "kanban", setup = "jira" },
}

-- The Settings pages shown now, as prefs takes them.
function cli.pages(): { { id: string, label: string, group: string, icon: string } }
	local out: { { id: string, label: string, group: string, icon: string } } = {}
	for _, p in PAGE_DEFS do
		if (not p.needs or cli.on(p.needs)) and (not p.setup or cli.installed[p.setup] == false) then
			table.insert(out, { id = p.id, label = p.label, group = p.group, icon = p.icon })
		end
	end
	return out
end

-- Page `id` while Settings shows it, else Views.
function cli.page(id: string?): string
	for _, p in cli.pages() do
		if p.id == id then
			return p.id
		end
	end
	return "views"
end

-- Asks each CLI whether it starts, once (`again`: those already answered too, as Refresh does). Once every answer is
-- in and one changed, every block rereads its views (an integration turned on or off), and a Settings page that went
-- with it (a setup page once its CLI starts) gives way to Views.
function cli.probe(again: boolean?)
	for _, c in cli.list do
		if (again or cli.installed[c.id] == nil) and not cli.probing[c.id] then
			cli.probing[c.id] = true
			process.run(c.argv, { timeout_ms = 10000 }, function(result)
				cli.probing[c.id] = nil
				cli.moved = cli.moved or cli.installed[c.id] ~= (result ~= nil)
				cli.installed[c.id] = result ~= nil
				if next(cli.probing) ~= nil or not cli.moved then
					return
				end
				cli.moved = false
				for _, s in running do
					if alive(s) then
						reloadViews(s)
						local set = s.settings
						if set and cli.page(set.page) ~= set.page then
							set.page, set.focus, set.pick, s.settingsPage = "views", nil, nil, "views"
						end
						ghActive.note(s, set ~= nil)
						s.cx:render()
					end
				end
			end)
		end
	end
end

-- The pickers the window opens for Settings' add rows (window.luau's `pickRepo` and `pickJira`).
local REPOS_HREF = "plotroom://repos"
local JIRA_HREF = "plotroom://jira-projects"

-- What each integration is called, what a new view of it starts as, what its query row is labelled, and the heading of
-- an issue's linked items.
type Integration = { label: string, newQuery: string, query: string, linked: string }
local INTEGRATIONS: { [string]: Integration } = {
	github = {
		label = "GitHub",
		newQuery = "is:open involves:@me",
		query = "Search query",
		linked = "Linked pull requests",
	},
	jira = {
		label = "Jira",
		newQuery = "assignee = currentUser() AND statusCategory != Done",
		query = "JQL",
		linked = "Linked issues",
	},
}

-- The sidebar group a view sits under: "GitHub - andyhite" for a view with its own login.
local function groupLabel(v: View): string
	local login = ghActive.shown(v)
	return if login ~= "" then INTEGRATIONS[v.integration].label .. " - " .. login else INTEGRATIONS[v.integration].label
end

local STATE_BADGE: { [string]: { text: string, tone: string } } = {
	open = { text = "Open", tone = "success" },
	draft = { text = "Draft", tone = "muted" },
	merged = { text = "Merged", tone = "accent" },
	closed = { text = "Closed", tone = "error" },
	done = { text = "Done", tone = "success" },
}
-- Why a closed issue closed; any other reason (or none) is a plain Closed.
local CLOSED_REASON: { [string]: { text: string, tone: string } } = {
	completed = { text = "Completed", tone = "accent" },
	["not-planned"] = { text = "Not planned", tone = "muted" },
	duplicate = { text = "Duplicate", tone = "muted" },
}
local REVIEW_BADGE: { [string]: { text: string, tone: string } } = {
	approved = { text = "Approved", tone = "success" },
	changes = { text = "Changes requested", tone = "error" },
	required = { text = "Review required", tone = "warning" },
}
local RUN_TONE: { [string]: string } = { success = "success", failure = "error", pending = "warning", neutral = "muted" }
local RUN_ICON: { [string]: string } = { success = "check", failure = "x", pending = "clock", neutral = "minus" }
local MERGE_STATE: { [string]: { text: string, tone: string } } = {
	conflicts = { text = "Conflicts", tone = "error" },
	behind = { text = "Behind base", tone = "warning" },
	blocked = { text = "Blocked", tone = "warning" },
	unstable = { text = "Checks failing", tone = "warning" },
	ready = { text = "Ready", tone = "success" },
	draft = { text = "Draft", tone = "muted" },
	unknown = { text = "Checking…", tone = "muted" },
}
local VERDICT_ROW: { [string]: { text: string, tone: string, icon: string } } = {
	approved = { text = "Approved", tone = "success", icon = "check" },
	changes = { text = "Changes requested", tone = "error", icon = "x" },
	commented = { text = "Commented", tone = "muted", icon = "message" },
	dismissed = { text = "Dismissed", tone = "muted", icon = "slash" },
	requested = { text = "Requested", tone = "warning", icon = "clock" },
}
local CHECK: { [string]: { text: string, tone: string, mark: string } } = {
	success = { text = "Passing", tone = "success", mark = "✓" },
	failure = { text = "Failing", tone = "error", mark = "✗" },
	pending = { text = "Pending", tone = "warning", mark = "●" },
}

-- The two kinds of view the engine runs. `keys` is the `?` list of the queue (every shortcut of the kind, concise);
-- `vars` the prompt editor's legend of the variables a prompt may use.
KINDS = {
	prs = {
		id = "prs",
		label = "Pull requests",
		one = "pull request",
		many = "pull requests",
		icon = "merge",
		viewsKey = "views-prs",
		promptsKey = "prompts-prs",
		integrations = { "github" },
		seeds = {
			{ id = "v1", name = "My PRs", integration = "github", query = "is:open author:@me", group = "none" },
			{ id = "v2", name = "Review requested", integration = "github", query = "is:open review-requested:@me", group = "none" },
		},
		keys = {
			{ keys = { "↑", "↓" }, actions = { "down", "up" }, text = "Move through the pull requests (Page Up/Down jump ten, Home/End the ends)" },
			{ keys = { "Enter" }, text = "Open the selected pull request in a Browser block beside this one" },
			{ keys = {}, actions = { "worktree" }, text = "Check it out in a worktree and open that in a new tab (Plotroom asks for the repository's checkout the first time)" },
			{ keys = {}, actions = { "goto" }, text = "Go to the tab working in the selected pull request's worktree" },
			{ keys = {}, actions = { "agent" }, text = "Pick a saved action, or type a prompt, and run it on the selected pull request in its worktree" },
			{ keys = {}, actions = { "search" }, text = "Search the loaded pull requests; Esc clears the search, a second Esc closes it" },
			{ keys = { "Tab" }, text = "Switch between the view list and the pull requests" },
			{ keys = {}, actions = { "refresh" }, text = "Refresh now" },
			{ keys = {}, actions = { "settings" }, text = "Settings" },
			{ keys = {}, actions = { "help" }, text = "Show or hide this list" },
		},
		-- The variables window.luau's `fill` replaces in a prompt; keep the two in step.
		vars = {
			{ k = { ui.span("{url}", "code") }, v = "Link to the pull request" },
			{ k = { ui.span("{owner}", "code") }, v = "Repository owner" },
			{ k = { ui.span("{repo}", "code") }, v = "Repository name" },
			{ k = { ui.span("{number}", "code") }, v = "Pull request number" },
			{ k = { ui.span("{title}", "code") }, v = "Title" },
			{ k = { ui.span("{author}", "code") }, v = "Author's login" },
			{ k = { ui.span("{branch}", "code") }, v = "Head branch on GitHub" },
			{ k = { ui.span("{base}", "code") }, v = "Branch it merges into" },
			{ k = { ui.span("{remote}", "code") }, v = "Git remote of the repository in its checkout (actions that run in a worktree)" },
			{ k = { ui.span("{github.user}", "code") }, v = "Your GitHub login (the view's account, else gh's active one)" },
		},
		prompts = require("./prompts").prs,
	},
	issues = {
		id = "issues",
		label = "Issues",
		one = "issue",
		many = "issues",
		icon = ISSUE_ICON,
		viewsKey = "views-issues",
		promptsKey = "prompts-issues",
		integrations = { "github", "jira" },
		seeds = {
			{ id = "v1", name = "Assigned to me", integration = "github", query = "is:open assignee:@me", group = "none" },
			{ id = "v2", name = "Created by me", integration = "github", query = "is:open author:@me", group = "none" },
			{ id = "v3", name = "Assigned to me", integration = "jira", query = "assignee = currentUser() AND statusCategory != Done", group = "none" },
			{ id = "v4", name = "Created by me", integration = "jira", query = "reporter = currentUser() AND statusCategory != Done", group = "none" },
		},
		keys = {
			{ keys = { "↑", "↓" }, actions = { "down", "up" }, text = "Move through the issues (Page Up/Down jump ten, Home/End the ends)" },
			{ keys = { "Enter" }, text = "Open the selected issue in a Browser block beside this one" },
			{ keys = {}, actions = { "worktree" }, text = "Create or reuse the selected issue's worktree and open it in a new tab: on its linked pull request's branch (Plotroom asks which when several have one), else on a new branch from the base you pick (Plotroom asks for the repository, and its checkout, the first time)" },
			{ keys = {}, actions = { "goto" }, text = "Go to the tab working in the selected issue's worktree" },
			{ keys = {}, actions = { "agent" }, text = "Pick a saved action, or type a prompt, and run it on the selected issue (typed prompts run in its worktree)" },
			{ keys = {}, actions = { "search" }, text = "Search the loaded issues; Esc clears the search, a second Esc closes it" },
			{ keys = { "Tab" }, text = "Switch between the view list and the issues" },
			{ keys = {}, actions = { "refresh" }, text = "Refresh now" },
			{ keys = {}, actions = { "settings" }, text = "Settings" },
			{ keys = {}, actions = { "help" }, text = "Show or hide this list" },
		},
		-- The variables prepareIssue sends the window (issueVars; `branch`, `base` and `remote` too when it runs in a
		-- worktree), which fills them in: each tracker filling its own.
		vars = {
			{ k = { ui.span("{url}", "code") }, v = "Link to the issue" },
			{ k = { ui.span("{key}", "code") }, v = "Issue number (GitHub) or key (Jira, ABC-12)" },
			{ k = { ui.span("{title}", "code") }, v = "Title" },
			{ k = { ui.span("{author}", "code") }, v = "Author's login (GitHub) or reporter's name (Jira)" },
			{ k = { ui.span("{labels}", "code") }, v = "Labels, comma-separated" },
			{ k = { ui.span("{branch}", "code") }, v = "The worktree's branch (actions that run in a worktree)" },
			{ k = { ui.span("{base}", "code") }, v = "The base branch a new worktree branch was made from (empty when Plotroom reused a branch)" },
			{ k = { ui.span("{remote}", "code") }, v = "Git remote of the repository in its checkout (actions that run in a worktree)" },
			{ k = { ui.span("{owner}", "code") }, v = "Owner of the repository the issue is worked in" },
			{ k = { ui.span("{repo}", "code") }, v = "Name of that repository" },
			{ k = { ui.span("{number}", "code") }, v = "Issue number (GitHub)" },
			{ k = { ui.span("{project}", "code") }, v = "Project key (Jira)" },
			{ k = { ui.span("{status}", "code") }, v = "Status (Jira)" },
			{ k = { ui.span("{type}", "code") }, v = "Issue type (Jira)" },
			{ k = { ui.span("{github.user}", "code") }, v = "Your GitHub login (the view's account, else gh's active one)" },
			{ k = { ui.span("{jira.user}", "code") }, v = "Your Jira sign-in's email before the @ (Jira)" },
		},
		prompts = require("./prompts").issues,
	},
}

local SETTINGS_KEYS: { KeyHelp } = {
	{ keys = { "↑", "↓" }, text = "Move between rows" },
	{ keys = { "Enter" }, text = "Edit a text row, press its button, switch a choice to its next option or open its menu; while editing, Enter saves" },
	{ keys = { "⌘↵" }, text = "Save an action's prompt (Enter there starts a new line)" },
	{ keys = { "←", "→", "Space" }, text = "In an open choice, move and pick; on chips, move and turn one on or off" },
	{ keys = { "⌫" }, text = "On a shortcut row after Enter: remove the shortcut (any other key becomes it)" },
	{ keys = { "Esc" }, text = "Cancel the edit or close the choice; with nothing open, close Settings" },
	{ keys = { "Tab" }, text = "Next page (Shift+Tab: previous page)" },
	{ keys = {}, actions = { "help" }, text = "Show or hide this list" },
}

local function stateKind(pr: github.Pr): string
	if pr.state == "merged" or pr.state == "closed" then
		return pr.state
	end
	return if pr.draft then "draft" else "open"
end

-- An issue's state badge: its workflow status (Jira), else Open, or why it was closed.
local function issueBadge(issue: tracker.Issue): { text: string, tone: string }
	if issue.status then
		return issue.status
	end
	if issue.state ~= "closed" then
		return STATE_BADGE.open
	end
	return CLOSED_REASON[issue.reason or ""] or STATE_BADGE.closed
end

GROUPS = {
	prs = {
		github = {
			{ value = "repo", label = "Repository", of = function(pr: any): string return pr.repo end },
			{ value = "author", label = "Author", of = function(pr: any): string return pr.author end },
			{ value = "state", label = "State", of = function(pr: any): string return STATE_BADGE[stateKind(pr)].text end },
			{ value = "review", label = "Review", of = function(pr: any): string return if pr.review then REVIEW_BADGE[pr.review].text else "No review" end },
			{ value = "checks", label = "Checks", of = function(pr: any): string return if pr.checks then CHECK[pr.checks].text else "No checks" end },
			{ value = "base", label = "Base branch", of = function(pr: any): string return pr.base end },
		},
	},
	issues = {
		github = {
			{ value = "repo", label = "Repository", of = function(issue: any): string return issue.repo end },
			{ value = "author", label = "Author", of = function(issue: any): string return issue.author end },
			{ value = "state", label = "State", keep = true, of = function(issue: any): string return issueBadge(issue).text end },
			{ value = "assignee", label = "Assignee", of = function(issue: any): string return issue.assignees[1] or "Unassigned" end },
		},
		jira = {
			{ value = "project", label = "Project", of = function(issue: any): string return issue.repo end },
			{ value = "status", label = "Status", keep = true, of = function(issue: any): string return issueBadge(issue).text end },
			{ value = "type", label = "Type", of = function(issue: any): string return issue.type or "No type" end },
			{ value = "priority", label = "Priority", of = function(issue: any): string return issue.priority or "No priority" end },
			{ value = "assignee", label = "Assignee", of = function(issue: any): string return issue.assignees[1] or "Unassigned" end },
			{ value = "reporter", label = "Reporter", of = function(issue: any): string return issue.author end },
		},
	},
}

type Row = {
	id: string,
	label: string,
	hint: string?,
	control: { [string]: any },
	changed: boolean?,
	defaultLabel: string?,
	warning: string?,
	disabled: string?,
}

-- sections and extra children of the open settings page.
local function pageContent(state: State): ({ any }, { Node })
	local s = state.settings :: Settings
	local sections: { any } = {}
	local extra: { Node } = {}
	-- `section` starts a card (under `title`), `row` adds to the last one started; prefs skips a card left empty.
	local function section(id: string, title: string?)
		table.insert(sections, { id = id, title = title, rows = {} })
	end
	local function row(r: Row)
		table.insert(sections[#sections].rows, r)
	end
	-- The open view's or prompt's form is a card of its own ("form:<id>") where it sits in its list, its first row the
	-- one that closes it (Edit turns Done in place); the list goes on in a card after it. First in its group, the form
	-- takes over the group's card, title and all.
	local function openCard(id: string)
		if #sections[#sections].rows > 0 then
			section("form:" .. id)
		else
			sections[#sections].id = "form:" .. id
		end
	end
	if s.page == "views" then
		-- The saved prompts of each kind, read once: a view offers those of its own kind.
		local promptLists: { [string]: { Prompt } } = {}
		local kindOptions: { any } = {}
		for _, kind in { KINDS.prs, KINDS.issues } do
			local prompts = loadPrompts(kind)
			promptLists[kind.id] = if prompts then prompts.items else {}
			table.insert(kindOptions, { value = kind.id, label = kind.label })
		end
		-- The groups, in the sidebar's order: one for each signed-in gh login while gh is on and one for Jira while acli
		-- is, each ending in an Add button for a view of its own (`add`: "<integration>:<login>", addView); and one for each
		-- other group a listed view sits in (a login no longer signed in, several logins, gh's active one while unknown),
		-- without one. A view of several logins, in each one's group in the sidebar, has its own here.
		local groups: { { label: string, integration: string, add: string?, views: { View } } } = {}
		local byLabel: { [string]: { label: string, integration: string, add: string?, views: { View } } } = {}
		local function groupOf(label: string, integration: string, add: string?): { label: string, integration: string, add: string?, views: { View } }
			local key = string.lower(label)
			local found = byLabel[key]
			if found then
				return found
			end
			local g = { label = label, integration = integration, add = add, views = {} }
			byLabel[key] = g
			table.insert(groups, g)
			return g
		end
		if cli.on("github") then
			for _, who in ghActive.accounts do
				groupOf(INTEGRATIONS.github.label .. " - " .. who, "github", "github:" .. who)
			end
		end
		if cli.on("jira") then
			groupOf(INTEGRATIONS.jira.label, "jira", "jira:")
		end
		for _, scope in orderedViews(state) do
			local v = scope.view
			if v ~= state.pin then
				local g = groupOf(groupLabel(v), v.integration, if v.integration == "jira" then "jira:" else nil)
				if not table.find(g.views, v) then
					table.insert(g.views, v)
				end
			end
		end
		table.sort(groups, function(a, b)
			if a.integration ~= b.integration then
				return a.integration == "github"
			end
			return string.lower(a.label) < string.lower(b.label)
		end)
		for _, g in groups do
			if #g.views > 0 then
				section("group:" .. string.lower(g.label), g.label)
			end
			for _, v in g.views do
				local kind = KINDS[v.kind]
				local list = promptLists[v.kind]
				local locked = state.locked[v.kind]
				local name = v.name .. (if v.id == state.activeId then " · active" else "")
				if s.open ~= v.id then
					row({
						id = "vopen:" .. v.id,
						label = name,
						hint = clip(printable(kind.label .. " · " .. v.query), 120),
						control = { k = "action", act = "expand", label = "Edit" },
					})
					continue
				end
				openCard(v.id)
				row({ id = "vopen:" .. v.id, label = name, control = { k = "action", act = "collapse", label = "Done" } })
				-- Right after Done in key order; plotroom.css draws its button left of Done, on the summary row.
				row({ id = "delete:" .. v.id, label = "Delete view", disabled = locked, control = { k = "action", act = "delete", label = "Delete" } })
				row({ id = "name:" .. v.id, label = "Name", disabled = locked, control = { k = "text", value = v.name, placeholder = if v.kind == "issues" then "Assigned to me" else "My PRs" } })
				-- Its integration and logins are its group's; Type only where the other kind has its integration.
				local other = if v.kind == "prs" then "issues" else "prs"
				if table.find(KINDS[other].integrations, v.integration) then
					row({
						id = "vkind:" .. v.id,
						label = "Type",
						-- A move writes both kinds' saved views.
						disabled = locked or state.locked[other],
						control = { k = "choice", style = "segmented", value = v.kind, options = tern.json.array(kindOptions) },
					})
				end
				local info = INTEGRATIONS[v.integration]
				row({
					id = "query:" .. v.id,
					label = info.query,
					disabled = locked,
					control = { k = "text", value = v.query, placeholder = info.newQuery, mono = true },
				})
				local groupOptions: { any } = { { value = "none", label = "None" } }
				for _, by in groupsOf(v.kind, v.integration) do
					table.insert(groupOptions, { value = by.value, label = by.label })
				end
				row({
					id = "vgroup:" .. v.id,
					label = "Group by",
					disabled = locked,
					control = { k = "choice", style = "menu", value = v.group, options = tern.json.array(groupOptions) },
				})
				local promptOptions: { any } = {}
				for _, p in list do
					table.insert(promptOptions, { value = p.id, label = p.name })
				end
				row({
					id = "vprompts:" .. v.id,
					label = "Actions offered",
					disabled = locked or (if #list == 0 then "No " .. kind.one .. " actions yet" else nil),
					control = { k = "multi", values = tern.json.array(livePrompts(v, list)), options = tern.json.array(promptOptions) },
				})
				section("after:" .. v.id)
			end
			local add = g.add
			if add then
				-- prefs draws no section without rows, so an empty group's title goes on its Add button's.
				local kind = if table.find(state.kind.integrations, g.integration) then state.kind else KINDS.issues
				section((if #g.views > 0 then "add:" else "add-to:") .. add, if #g.views > 0 then nil else g.label)
				row({ id = "vadd:" .. add, label = "", disabled = state.locked[kind.id], control = { k = "action", act = "add", label = "Add view" } })
			end
		end
	elseif s.page == "prompts" then
		for _, kind in { KINDS.prs, KINDS.issues } do
			-- A kind's prompts while one of its integrations is on: pull request prompts need gh.
			local usable = false
			for _, i in kind.integrations do
				usable = usable or cli.on(i)
			end
			if not usable then
				continue
			end
			local prompts, unreadable = loadPrompts(kind)
			local list: { Prompt } = if prompts then prompts.items else {}
			local title = if kind.id == "prs" then "Pull request actions" else "Issue actions"
			section("prompts:" .. kind.id, title)
			for _, p in list do
				local qid = kind.id .. ":" .. p.id
				local first = string.match(p.text, "^%s*([^\n]*)") or ""
				if s.open ~= qid then
					local parts: { string } = { if first ~= "" then first else "Empty" }
					if p.key and p.key ~= "" then
						table.insert(parts, "key " .. p.key)
					end
					if p.model then
						table.insert(parts, p.model)
					end
					row({
						id = "popen:" .. qid,
						label = p.name,
						hint = clip(printable(table.concat(parts, " · ")), 120),
						control = { k = "action", act = "expand", label = "Edit" },
					})
					continue
				end
				openCard(qid)
				row({ id = "popen:" .. qid, label = p.name, control = { k = "action", act = "collapse", label = "Done" } })
				-- Right after Done in key order; plotroom.css draws its button left of Done, on the summary row.
				row({ id = "pdelete:" .. qid, label = "Delete action", control = { k = "action", act = "delete", label = "Delete" } })
				row({ id = "pname:" .. qid, label = "Name", control = { k = "text", value = p.name, placeholder = "Review" } })
				row({
					id = "ptext:" .. qid,
					label = "Prompt",
					hint = if first ~= "" then clip(printable(first), 80) else "Empty",
					control = { k = "action", act = "edit-prompt", label = "Edit…" },
				})
				row({ id = "pkey:" .. qid, label = "Shortcut", control = { k = "text", value = p.key or "", placeholder = "None" } })
				row({
					id = "pmodel:" .. qid,
					label = "Model",
					control = { k = "text", value = p.model or "", placeholder = "omp's default", mono = true },
					changed = p.model ~= nil,
					defaultLabel = "omp's default",
				})
				row({
					id = "pwhere:" .. qid,
					label = "Runs in",
					control = {
						k = "choice",
						style = "segmented",
						value = if p.worktree ~= false then "worktree" else "checkout",
						options = tern.json.array({ { value = "worktree", label = "Worktree" }, { value = "checkout", label = "Main checkout" } }),
					},
				})
				row({
					id = "psplit:" .. qid,
					label = "Opens in",
					control = {
						k = "choice",
						style = "segmented",
						value = if p.split then "split" else "tab",
						options = tern.json.array({ { value = "tab", label = "New tab" }, { value = "split", label = "Beside the queue" } }),
					},
				})
				section("after:" .. qid)
			end
			-- prefs draws no section without rows, so with none saved the kind's title goes on its buttons'.
			section((if #list > 0 then "add:" else "add-to:") .. kind.id, if #list > 0 then nil else title)
			row({ id = "padd:" .. kind.id, label = "", disabled = unreadable, control = { k = "action", act = "add-prompt", label = "Add action" } })
			if prompts and #require("./prompts").missing(kind.prompts, list) > 0 then
				row({ id = "prestore:" .. kind.id, label = "", control = { k = "action", act = "restore-prompts", label = "Restore defaults" } })
			end
		end
	elseif s.page == "keys" then
		local map, unreadable = keys.load()
		section("keys")
		for _, a in keys.ACTIONS do
			row({
				id = "key:" .. a.id,
				label = a.label,
				disabled = unreadable,
				control = { k = "text", value = map[a.id], placeholder = "None" },
				changed = map[a.id] ~= a.default,
				defaultLabel = a.default,
			})
		end
	elseif s.page == "worktrees" then
		section("sec-names", "Names")
		for _, f in {
			{ id = "branch", label = "Issue branch name", vars = tracker.VARS },
			{ id = "prdir", label = "Pull request folder name", vars = tracker.DIR_VARS },
			{ id = "issuedir", label = "Issue folder name", vars = tracker.DIR_VARS },
		} do
			if f.id == "prdir" and not cli.on("github") then
				continue -- pull requests need gh
			end
			local saved = formats.saved(f.id)
			row({
				id = "fmt:" .. f.id,
				label = f.label,
				hint = "{" .. table.concat(f.vars, "} {") .. "}",
				control = { k = "text", value = saved, placeholder = formats.DEFAULTS[f.id], mono = true },
				changed = saved ~= "",
				defaultLabel = formats.DEFAULTS[f.id],
			})
		end
	elseif s.page == "repos" then
		local checkouts = readCheckouts()
		local names: { string } = {}
		for name in checkouts do
			if type(name) == "string" then
				table.insert(names, name)
			end
		end
		table.sort(names)
		local repoFormats, formatsOff = formats.repoMap()
		local setups, setupsOff = setupMap()
		section("repos")
		for _, repo in names do
			local path = checkouts[repo]
			local mapped = if type(path) == "string" and path ~= "" then path else nil
			local fmt = if repoFormats then formats.repoOf(repo) else nil
			local cmds: { string } = if setups then setupOf(setups, repo) else {}
			if s.open ~= repo then
				local parts: { string } = { mapped or "No local checkout" }
				if fmt then
					table.insert(parts, fmt)
				end
				if #cmds > 0 then
					table.insert(parts, #cmds .. (if #cmds == 1 then " setup command" else " setup commands"))
				end
				row({
					id = "ropen:" .. repo,
					label = repo,
					hint = clip(printable(table.concat(parts, " · ")), 120),
					control = { k = "action", act = "expand", label = "Edit" },
				})
				continue
			end
			openCard(repo)
			row({ id = "ropen:" .. repo, label = repo, control = { k = "action", act = "collapse", label = "Done" } })
			-- Right after Done in key order; plotroom.css draws its button left of Done, on the summary row.
			row({ id = "rremove:" .. repo, label = "Remove repository", control = { k = "action", act = "delete", label = "Remove" } })
			row({
				id = "checkout:" .. repo,
				label = "Local checkout",
				control = { k = "text", value = mapped or "", placeholder = "~/Code/" .. (string.match(repo, "/(.+)$") or repo), mono = true },
				changed = mapped ~= nil,
				defaultLabel = "Not set",
				disabled = if state.claiming == repo then "Checking the folder, or cloning into it…" else nil,
			})
			row({
				id = "branch:" .. repo,
				label = "Issue branch name",
				control = { k = "text", value = fmt or "", placeholder = formats.of("branch"), mono = true },
				changed = fmt ~= nil,
				defaultLabel = "the Worktrees page's format",
				disabled = formatsOff,
			})
			for i, c in cmds do
				row({
					id = "setup:" .. repo .. ":" .. i,
					label = "Setup command " .. i,
					disabled = setupsOff,
					control = { k = "text", value = c, placeholder = "Empty removes it", mono = true },
				})
			end
			row({
				id = "setup:" .. repo .. ":new",
				label = "Add setup command",
				disabled = setupsOff,
				control = { k = "text", value = "", placeholder = if #cmds == 0 then "pnpm install" else "cp ../repo/.env .", mono = true },
			})
			section("after:" .. repo)
		end
		-- Add repository and Add project open the window's pickers.
		section("add:repo")
		row({ id = "radd", label = "", control = { k = "action", act = "add-repo", label = "Add repository" } })
	elseif s.page == "jira" then
		local map, unreadable = readJiraRepos()
		local keys: { string } = {}
		local saved: { [string]: any } = map or {}
		for key in saved do
			if type(key) == "string" then
				table.insert(keys, key)
			end
		end
		table.sort(keys)
		local options: { any } = {}
		local known: { string } = {}
		for name in readCheckouts() do
			if type(name) == "string" then
				table.insert(known, name)
			end
		end
		table.sort(known)
		for _, name in known do
			table.insert(options, { value = name, label = name })
		end
		section("projects")
		for _, key in keys do
			local repos = jiraReposOf(key)
			if s.open ~= key then
				row({
					id = "jopen:" .. key,
					label = key,
					hint = clip(printable(if #repos > 0 then table.concat(repos, ", ") else "No repositories"), 120),
					control = { k = "action", act = "expand", label = "Edit" },
				})
				continue
			end
			openCard(key)
			row({ id = "jopen:" .. key, label = key, control = { k = "action", act = "collapse", label = "Done" } })
			-- Right after Done in key order; plotroom.css draws its button left of Done, on the summary row.
			row({ id = "jremove:" .. key, label = "Remove project", disabled = unreadable, control = { k = "action", act = "delete", label = "Remove" } })
			row({
				id = "jrepos:" .. key,
				label = "Repositories",
				disabled = unreadable or (if #options == 0 then "Add a repository first." else nil),
				control = { k = "multi", values = tern.json.array(repos), options = tern.json.array(options) },
			})
			section("after:" .. key)
		end
		section("add:jira")
		row({ id = "jadd", label = "", disabled = unreadable, control = { k = "action", act = "add-jira", label = "Add project" } })
	elseif s.page == "setup-github" or s.page == "setup-jira" then
		-- An integration whose CLI does not start: only the way to its install guide.
		local gh = s.page == "setup-github"
		section("setup")
		row({
			id = if gh then "guide:github" else "guide:jira",
			label = if gh then "Install gh, then sign in with gh auth login" else "Install acli, then sign in with acli jira auth login",
			hint = if gh then "gh is not installed on this host" else "acli is not installed on this host",
			control = { k = "action", act = "guide", label = "Setup guide ↗" },
		})
	else
		local now = os.time()
		local wait = waitOf(state)
		table.insert(sections, {
			-- prefs draws its one in-section slot (a child with role omp.prefs.preview.status) only after this id.
			id = "status-line",
			rows = {
				{
					id = "refresh",
					label = "Refresh now",
					hint = paceLine(state),
					control = { k = "action", act = "refresh", label = "Refresh" },
					disabled = if wait > 0 then "Paused by GitHub until " .. os.date("%H:%M:%S", now + wait) else nil,
				},
			},
		})
		local q = if trackerOf(state) == "github" then github.quota(login(state)) else nil
		if q and q.limit and q.limit > 0 and q.remaining then
			local left = q.remaining .. " of " .. q.limit .. " points left" .. (if q.reset then ", resets " .. os.date("%H:%M", q.reset) else "")
			-- Laid out as a prefs row: label and hint at the left, the meter where a control sits.
			table.insert(
				extra,
				ui.node("row", { key = "quota", role = "omp.prefs.preview.status", gap = "md", align = "center" }, {
					ui.node("col", { key = "lbl", grow = 1 }, {
						ui.text({ ui.span("API quota") }),
						ui.text({ ui.span(left, "muted") }),
					}),
					ui.node("meter", { key = "used", value = 1 - q.remaining / q.limit, thresholds = { warn = 0.8, bad = 0.95 }, size = "md", basis = 0.3 }),
				})
			)
		end
	end
	local capture = if s.edit and string.match(s.edit.row, "^p?key:") then s.edit.row else nil
	for _, sec in sections do
		for _, r in sec.rows do
			local err = s.errors[r.id]
			if err then
				r.warning = err
			end
			if r.id == capture then
				r.hint = "Backspace removes it; Esc cancels."
				r.control.placeholder = "Press a key"
			end
		end
	end
	return sections, extra
end

-- Ids of the page's rows the keys can reach, in order.
local function focusRows(state: State): { string }
	local out: { string } = {}
	local sections = pageContent(state)
	for _, sec in sections do
		for _, row in sec.rows do
			if not row.disabled then
				table.insert(out, row.id)
			end
		end
	end
	return out
end

local function rowById(state: State, id: string): Row?
	local sections = pageContent(state)
	for _, sec in sections do
		for _, row in sec.rows do
			if row.id == id then
				return row
			end
		end
	end
	return nil
end

-- The caret's field (the TSP focus op; a view diff never moves it): the prompt editor while its text is edited.
local PROMPT_FIELD = SETTINGS_ID .. ".prompt.draft"
local function focusPrompt(state: State, on: boolean)
	local op: { any } = { "focus", if on then PROMPT_FIELD else tern.json.null }
	state.cx:frame({ op })
end

-- Opens a text row for editing, or a prompt's text (its "ptext:" row) in the multi-line editor card.
local function beginEdit(state: State, row: string, initial: string?)
	local s = state.settings
	local def = if s then rowById(state, row) else nil
	if not s or not def or def.disabled then
		return
	end
	local id = string.match(row, "^ptext:(.+)$")
	local pk, pid = kindAndId(id or "")
	local prompts = if pk then loadPrompts(pk) else nil
	local p = if prompts then promptById(prompts, pid) else nil
	if not p and def.control.k ~= "text" then
		return
	end
	s.focus, s.pick = row, nil
	s.errors[row] = nil
	-- A shortcut row starts empty: the next key pressed is the shortcut (the block's key handler).
	local draft = initial or (if string.match(row, "^p?key:") then "" else def.control.value)
	s.edit = { row = row, model = if p then input.new(initial or p.text, true) else input.new(draft) }
	if p then
		focusPrompt(state, true)
	end
end

-- Ends a save attempt: `err` is shown under the row and the edit stays open for a correction; on success the
-- row's warning is cleared and the edit closes.
local function settle(s: Settings, row: string, err: string?)
	if err then
		s.errors[row] = err
	else
		s.errors[row] = nil
		s.edit = nil
	end
end

-- Clears `repo`'s checkout; it stays listed.
local function clearCheckout(state: State, repo: string): string?
	local err = saveCheckout(repo, "")
	if not err then
		state.cx:toast("success", "Checkout cleared", repo)
	end
	return err
end

-- Rereads `repo`'s setup commands, lets `fn` change them (an error string aborts) and saves them.
local function editSetup(repo: string, fn: ({ string }) -> string?): string?
	local map, err = setupMap()
	if not map then
		return err
	end
	local list = setupOf(map, repo)
	local ferr = fn(list)
	if ferr then
		return ferr
	end
	map[string.lower(repo)] = if #list > 0 then tern.json.array(list) else nil
	local werr = kvSet("setup-commands", map)
	return if werr then "Could not save: " .. werr else nil
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

local function viewOf(state: State, id: string): View?
	for _, v in state.views do
		if v.id == id then
			return v
		end
	end
	return nil
end

-- Whether `value` is a group-by of views of `integration` (every kind accepts "none").
local function groupKnown(kind: Kind, integration: string, value: string): boolean
	if value == "none" then
		return true
	end
	for _, g in groupsOf(kind.id, integration) do
		if g.value == value then
			return true
		end
	end
	return false
end

-- Rereads the views of view `id`'s kind, applies `fn` to it and writes them back; an error message or nil. A change to
-- the active view's integration, query or login reloads it.
local function updateView(state: State, id: string, fn: (View) -> ()): string?
	local current = viewOf(state, id)
	if not current then
		return "That view was deleted elsewhere."
	end
	local kind = KINDS[current.kind]
	local store, writable, err = loadViews(kind)
	if not writable then
		loadAll(state)
		return err or "Views cannot be saved."
	end
	local target: View? = nil
	for _, v in store.items do
		if v.id == id then
			target = v
		end
	end
	if not target then
		return "That view was deleted elsewhere."
	end
	local before = snapKey(target, state.activeLogin)
	fn(target)
	local werr = writeViews(kind, store)
	if werr then
		return "Could not save: " .. werr
	end
	loadAll(state)
	if id == state.activeId then
		-- A login the view no longer lists is no longer a scope: the view's first takes over.
		state.activeLogin = if #target.logins > 1 then accountOf(target, state.activeLogin) else nil
		if snapKey(target, state.activeLogin) ~= before then
			changed(state)
		end
	end
	propagate(state)
	return nil
end

-- Adds a view from a group's Add row `row` ("vadd:<integration>:<login>", the login empty for Jira) and opens its form
-- on the name: a view of that integration running as that login, of the active kind where the integration has it, else
-- an issue view.
local function addView(state: State, row: string)
	local s = state.settings
	local integration, login = string.match(row, "^vadd:(%a+):(.*)$")
	if not s or not integration or not cli.on(integration) or not INTEGRATIONS[integration] or not string.match(login or "", "^[%w%-]*$") then
		return
	end
	local kind = if table.find(state.kind.integrations, integration) then state.kind else KINDS.issues
	local logins: { string } = if login and login ~= "" then { login } else {}
	local store, writable, err = loadViews(kind)
	if not writable then
		loadAll(state)
		s.errors[row] = err or "Views cannot be saved."
		return
	end
	local id = kind.id .. ":v" .. store.nextId
	store.nextId += 1
	table.insert(store.items, { id = id, kind = kind.id, name = "New view", integration = integration, query = INTEGRATIONS[integration].newQuery, logins = logins, group = "none", prompts = {} })
	local werr = writeViews(kind, store)
	if werr then
		s.errors[row] = "Could not save: " .. werr
		return
	end
	s.errors[row] = nil
	loadAll(state)
	switchView(state, id)
	propagate(state)
	s.open = id
	beginEdit(state, "name:" .. id, "")
end

local function deleteView(state: State, id: string)
	local s = state.settings
	if not s then
		return
	end
	s.confirm = nil
	local rowId = "vopen:" .. id -- the summary row shows why: the Delete row draws no label
	local view = viewOf(state, id)
	if not view then
		return
	end
	local kind = KINDS[view.kind]
	local place = 1 -- where the view sits in the sidebar's list: its place goes to the view after it
	for i, v in state.views do
		if v.id == id then
			place = i
		end
	end
	local store, writable, err = loadViews(kind)
	if not writable then
		loadAll(state)
		s.errors[rowId] = err or "Views cannot be saved."
		return
	end
	local at = 0
	for i, v in store.items do
		if v.id == id then
			at = i
		end
	end
	if at == 0 then
		return
	end
	table.remove(store.items, at)
	local werr = writeViews(kind, store)
	if werr then
		s.errors[rowId] = "Could not delete: " .. werr
		return
	end
	s.errors[rowId] = nil
	loadAll(state)
	local nextV = state.views[math.min(place, #state.views)]
	if id == state.activeId then
		switchView(state, if nextV then nextV.id else nil)
	end
	s.focus = if nextV then "vopen:" .. nextV.id else nil
	propagate(state)
end

-- Adds a prompt to the kv store of the kind whose add row `row` ("padd:<kind id>") was pressed, and opens it.
local function addPrompt(state: State, row: string)
	local s = state.settings
	local kind = KINDS[string.match(row, "^padd:(%a+)$") or ""]
	if not s or not kind then
		return
	end
	local id = ""
	local err = editPrompts(kind, function(store: Prompts): string?
		id = "p" .. store.nextId
		store.nextId += 1
		table.insert(store.items, { id = id, name = "New action", text = "", worktree = if kind.id == "issues" then true else nil })
		return nil
	end)
	s.errors[row] = err
	if not err then
		id = kind.id .. ":" .. id
		s.open = id
		beginEdit(state, "pname:" .. id, "")
	end
end

-- Deletes prompt `id` as Settings names it: "<kind id>:<id in that kind's store>".
local function deletePrompt(state: State, id: string)
	local s = state.settings
	if not s then
		return
	end
	s.confirm = nil
	local kind, saved = kindAndId(id)
	if not kind then
		return
	end
	local e = s.edit
	if e and (e.row == "ptext:" .. id or e.row == "pname:" .. id) then
		if e.model.multi then
			focusPrompt(state, false)
		end
		s.edit = nil -- the prompt being edited goes
	end
	local err = editPrompts(kind, function(store: Prompts): string?
		for i, p in store.items do
			if p.id == saved then
				table.remove(store.items, i)
				break
			end
		end
		return nil
	end)
	s.errors["popen:" .. id] = err -- the summary row shows why: the Delete row draws no label
	if not err then
		s.focus = "padd:" .. kind.id
	end
end

-- Removes repository `repo` everywhere it is saved.
local function deleteRepo(state: State, repo: string)
	local s = state.settings
	if not s then
		return
	end
	s.confirm = nil
	local err = removeRepo(repo)
	s.errors["ropen:" .. repo] = err -- the summary row shows why: the Remove row draws no label
	if not err then
		s.focus = "radd"
	end
end

-- Removes Jira project `key` and its repositories.
local function deleteJira(state: State, key: string)
	local s = state.settings
	if not s then
		return
	end
	s.confirm = nil
	local err = editJiraRepos(function(map: { [string]: any }): string?
		map[key] = nil
		return nil
	end)
	s.errors["jopen:" .. key] = err -- the summary row shows why: the Remove row draws no label
	if not err then
		s.focus = "jadd"
	end
end

-- Saves row `row`'s new value as its control sends it: a choice row's option (a string: a view's type and group-by,
-- where a prompt runs and opens) or a chips row's options now on (an array).
-- A value of another shape, or an option the row does not offer, changes nothing.
local function setValue(state: State, row: string, value: any)
	local s = state.settings
	if not s then
		return
	end
	local choice: string? = if type(value) == "string" then value else nil
	local values: { any } = if isTable(value) then value else {}
	local kind, id = string.match(row, "^(%a+):(.+)$")
	if not kind or not id then
		return
	end
	if kind == "pwhere" or kind == "psplit" then
		local on = choice == (if kind == "pwhere" then "worktree" else "split")
		local pk, pid = kindAndId(id)
		if not pk or not (on or choice == (if kind == "pwhere" then "checkout" else "tab")) then
			return
		end
		s.errors[row] = editPrompts(pk, function(store: Prompts): string?
			local p = promptById(store, pid)
			if not p then
				return "That action was deleted elsewhere."
			elseif kind == "pwhere" then
				p.worktree = on
			else
				p.split = on
			end
			return nil
		end)
	elseif kind == "vgroup" or kind == "vkind" then
		local view = viewOf(state, id)
		if not view or not choice then
			return
		end
		local current = if kind == "vkind" then view.kind else view.group
		if choice == current then
			return
		end
		local chosen: string = choice
		if kind == "vkind" then
			-- The view moves to the other kind's kv store, under a new id there; it is written there first, so a failure
			-- leaves the original. Its integration, logins and query stay, and so does its group-by while it still holds;
			-- the prompts it offered are ids of the other kind's prompts: none. Pull requests are GitHub's alone, so a Jira
			-- view has no Type row and does not move.
			local to: Kind? = KINDS[chosen]
			if not to or not table.find(to.integrations, view.integration) then
				return
			end
			local from = KINDS[view.kind]
			local src, srcWritable, srcErr = loadViews(from)
			local dst, dstWritable, dstErr = loadViews(to)
			if not srcWritable or not dstWritable then
				loadAll(state)
				s.errors[row] = (if srcWritable then dstErr else srcErr) or "Views cannot be saved."
				return
			end
			local at = 0
			for i, v in src.items do
				if v.id == id then
					at = i
				end
			end
			if at == 0 then
				s.errors[row] = "That view was deleted elsewhere."
				return
			end
			local old = src.items[at]
			local moved: View = {
				id = to.id .. ":v" .. dst.nextId,
				kind = to.id,
				name = old.name,
				integration = old.integration,
				query = old.query,
				logins = old.logins,
				group = if groupKnown(to, old.integration, old.group) then old.group else "none",
				prompts = {},
			}
			dst.nextId += 1
			table.insert(dst.items, moved)
			local werr = writeViews(to, dst)
			if werr then
				s.errors[row] = "Could not save: " .. werr
				return
			end
			table.remove(src.items, at)
			local rerr = writeViews(from, src)
			if rerr then
				table.remove(dst.items) -- the copy is the last one: taken back out, so the view is not in both lists
				local uerr = writeViews(to, dst)
				loadAll(state)
				s.errors[row] = "Could not save: " .. rerr .. (if uerr then ". The copy it made could not be taken back: " .. uerr else "")
				return
			end
			s.errors[row] = nil
			loadAll(state)
			if state.activeId == id then
				switchView(state, moved.id, if #moved.logins > 1 then accountOf(moved, state.activeLogin) else nil)
			end
			s.open, s.focus = moved.id, "vkind:" .. moved.id
			propagate(state)
			return
		end
		s.errors[row] = updateView(state, id, function(v: View)
			if groupKnown(KINDS[v.kind], v.integration, chosen) then
				v.group = chosen
			end
		end)
	elseif kind == "vprompts" then
		local view = viewOf(state, id)
		if not view then
			return
		end
		local prompts, err = loadPrompts(KINDS[view.kind])
		if not prompts then
			s.errors[row] = err
			return
		end
		local keep: { string } = {}
		for _, p in prompts.items do
			if table.find(values, p.id) then
				table.insert(keep, p.id)
			end
		end
		s.errors[row] = updateView(state, id, function(v: View)
			v.prompts = keep
		end)
	elseif kind == "jrepos" then
		local have = readCheckouts()
		local keep: { string } = {}
		for _, x in values do
			if type(x) == "string" and have[x] ~= nil then
				table.insert(keep, x)
			end
		end
		table.sort(keep)
		s.errors[row] = editJiraRepos(function(map: { [string]: any }): string?
			map[id] = keep
			return nil
		end)
	end
end

-- Enter or Space on option `option` of row `row` while the keys drive it: a choice row takes it (and closes), a chips
-- row turns it on or off.
local function pressOption(state: State, row: string, option: string)
	local s = state.settings
	local def = rowById(state, row)
	if not s or not def then
		return
	end
	local c = def.control
	if c.k == "choice" then
		s.pick = nil
		setValue(state, row, option)
		return
	end
	local values: { any } = {}
	for _, v in c.values do -- a tern.json.array: table.clone refuses its protected metatable
		table.insert(values, v)
	end
	local at = table.find(values, option)
	if at then
		table.remove(values, at)
	else
		table.insert(values, option)
	end
	setValue(state, row, values)
end

-- Deletes what the delete row `s.confirm` names ("delete:<view id>", "pdelete:<prompt id>", "rremove:<repository>" or
-- "jremove:<project key>").
local function confirmDelete(state: State)
	local s = state.settings
	local kind, id = string.match(if s and s.confirm then s.confirm else "", "^(%a+):(.+)$")
	if not id then
		return
	end
	if kind == "delete" then
		deleteView(state, id)
	elseif kind == "pdelete" then
		deletePrompt(state, id)
	elseif kind == "rremove" then
		deleteRepo(state, id)
	elseif kind == "jremove" then
		deleteJira(state, id)
	end
end

-- What the window's palette asks before Delete or Remove row `row` acts (hidden node `main.confirm`, read by
-- window.luau's `confirmDelete`): the question, the destructive choice and what it does.
local function deleteQuestion(state: State, row: string): { [string]: string }
	local kind, id = string.match(row, "^(%a+):(.+)$")
	if kind == "pdelete" then
		local pk, pid = kindAndId(id or "")
		local prompts = if pk then loadPrompts(pk) else nil
		local p = if prompts then promptById(prompts, pid) else nil
		return { row = row, head = "Delete action “" .. (if p then p.name else "this action") .. "”?", label = "Delete action", detail = "Gone from every Plotroom pane" }
	elseif kind == "rremove" then
		return { row = row, head = "Remove repository “" .. (id or "") .. "”?", label = "Remove repository", detail = "Forgets its checkout and settings; no folder is touched" }
	elseif kind == "jremove" then
		return { row = row, head = "Remove Jira project “" .. (id or "") .. "”?", label = "Remove project", detail = "Forgets its repositories" }
	end
	local view = viewOf(state, id or "")
	return { row = row, head = "Delete view “" .. (if view then view.name else "this view") .. "”?", label = "Delete view", detail = "Gone from every Plotroom pane" }
end

local function runAction(state: State, act: string, row: string)
	local s = state.settings
	if not s then
		return
	end
	if act == "add" then
		addView(state, row)
	elseif act == "add-prompt" then
		addPrompt(state, row)
	elseif act == "restore-prompts" then
		-- Saves back the defaults no saved action is named like; the others, edited defaults included, stay.
		local kind = KINDS[string.match(row, "^prestore:(%a+)$") or ""]
		if kind then
			s.errors[row] = editPrompts(kind, function(store: Prompts): string?
				for _, d in require("./prompts").missing(kind.prompts, store.items) do
					table.insert(store.items, { id = "p" .. store.nextId, name = d.name, text = d.text, worktree = d.worktree })
					store.nextId += 1
				end
				return nil
			end)
			if not s.errors[row] then
				s.focus = "padd:" .. kind.id -- the restore button is gone with nothing left to restore
			end
		end
	elseif act == "expand" or act == "collapse" then
		-- One form open at a time; a single-line edit in progress belongs to the form being left.
		if s.edit and not s.edit.model.multi then
			s.errors[s.edit.row] = nil
			s.edit = nil
		end
		local which, id = string.match(row, "^(%a+):(.+)$")
		if act == "expand" then
			-- The form's first field takes the focus.
			local first = ({ vopen = "name:", popen = "pname:", ropen = "checkout:", jopen = "jrepos:" } :: { [string]: string })[which or ""]
			s.open = id
			s.focus = (first or "") .. (id or "")
		else
			s.open = nil
			s.focus = row
		end
	elseif act == "edit-prompt" then
		beginEdit(state, row)
	elseif act == "delete" then
		-- The window's palette asks (window.luau's `confirmDelete`); its answer comes back as confirm-delete for this row.
		s.confirm = row
		state.cx:render() -- the question is on screen before the window is told to read it
		state.cx:open("plotroom://confirm")
	elseif act == "refresh" then
		retry(state)
	elseif act == "add-repo" then
		state.cx:open(REPOS_HREF)
	elseif act == "add-jira" then
		state.cx:open(JIRA_HREF)
	elseif act == "guide" then
		for _, c in cli.list do
			if row == "guide:" .. c.id then
				state.cx:open(c.url)
			end
		end
	end
end

-- Enter on a row, or a click on its field or popup: edits a text row, presses a button, switches a segmented choice to
-- its next option (its segments show no keyboard highlight), or hands the keys to a menu choice (opened on the current
-- option) or chips row (on its first option).
local function runRow(state: State, row: string?)
	local s = state.settings
	if not row or not s or (s.edit and s.edit.row == row) then
		return -- a click inside the field being edited keeps its draft
	end
	local def = rowById(state, row)
	if not def or def.disabled then
		return
	end
	local c = def.control
	if c.k == "text" then
		beginEdit(state, row)
	elseif c.k == "action" then
		runAction(state, c.act, row)
	elseif c.k == "choice" and c.style == "segmented" then
		local at = 0
		for i, o in c.options do
			if o.value == c.value then
				at = i
			end
		end
		local nextOption = c.options[at % #c.options + 1]
		s.focus = row
		setValue(state, row, nextOption.value)
	elseif c.k == "choice" then
		s.focus, s.pick = row, { row = row, option = c.value }
	elseif c.k == "multi" and c.options[1] then
		s.focus, s.pick = row, { row = row, option = c.options[1].value }
	end
end

-- Enter on a text row: saves it. A rejected value stays in the field with its warning, for a correction.
local function commitEdit(state: State)
	local s = state.settings
	local e = if s then s.edit else nil
	if not s or not e then
		return
	end
	local text = trim(e.model.text)
	local row = e.row
	local def = rowById(state, row)
	-- An action's unchanged name still saves: naming a new one "New action" must open its text all the same.
	if not def or (text == def.control.value and not string.match(row, "^pname:")) then
		settle(s, row, nil) -- nothing to save: the edit closes, and a warning about the rejected draft goes with it
		return
	end
	local kind, id = string.match(row, "^(%a+):(.+)$")
	if (kind == "name" or kind == "query") and id then
		local view = viewOf(state, id)
		local err: string? = nil
		if text == "" then
			err = if kind == "name" then "A name is required." else "A query is required."
		elseif kind == "query" and view and view.integration == "jira" then
			err = jira.scopeProblem(text)
		end
		if not err then
			err = updateView(state, id, function(v: View)
				if kind == "name" then
					v.name = text
				else
					v.query = text
				end
			end)
		end
		settle(s, row, err)
	elseif kind == "pmodel" and id then
		local err: string? = nil
		local pk, pid = kindAndId(id)
		if text ~= "" and not worktree.validModel(text) then
			err = "A model such as opus or provider/model-id, or a role such as @slow."
		elseif not pk then
			err = "That action was deleted elsewhere."
		else
			err = editPrompts(pk, function(store: Prompts): string?
				local p = promptById(store, pid)
				if not p then
					return "That action was deleted elsewhere."
				end
				p.model = if text ~= "" then text else nil
				return nil
			end)
		end
		settle(s, row, err)
	elseif kind == "pkey" and id then
		local pk, pid = kindAndId(id)
		local err: string? = keys.shape(text)
		if not err and keys.action((keys.load()), text) then
			err = "The queue already uses " .. text .. "."
		end
		if not err and not pk then
			err = "That action was deleted elsewhere."
		end
		if not err and pk then
			err = editPrompts(pk, function(store: Prompts): string?
				local p = promptById(store, pid)
				if not p then
					return "That action was deleted elsewhere."
				end
				for _, other in store.items do
					if other ~= p and text ~= "" and other.key == text then
						return "Already the shortcut of " .. other.name .. "."
					end
				end
				p.key = if text ~= "" then text else nil
				return nil
			end)
		end
		settle(s, row, err)
	elseif kind == "key" and id then
		-- A key some saved prompt of either kind runs cannot also be an action's: the keys are shared by both kinds.
		local function promptKey(): string?
			for _, other in { KINDS.prs, KINDS.issues } do
				local prompts, bad = loadPrompts(other)
				if not prompts then
					return bad
				end
				for _, p in prompts.items do
					if p.key == text then
						return "Already the shortcut of the " .. other.one .. " action “" .. printable(p.name) .. "”."
					end
				end
			end
			return nil
		end
		local map, unreadable = keys.load()
		local err = unreadable or keys.problem(map, id, text)
		if not err and text ~= "" then
			err = promptKey()
		end
		err = err or keys.save(id, text)
		settle(s, row, err)
		if not err then
			propagate(state)
		end
	elseif (kind == "pname" or kind == "ptext") and id then
		local err: string? = nil
		local empty = false
		local pk, pid = kindAndId(id)
		if text == "" then
			err = if kind == "pname" then "A name is required." else "A prompt is required."
		elseif #text > PROMPT_CAP then
			err = "Over " .. PROMPT_CAP .. " bytes; shorten it."
		elseif not pk then
			err = "That action was deleted elsewhere."
		else
			err = editPrompts(pk, function(store: Prompts): string?
				local p = promptById(store, pid)
				if not p then
					return "That action was deleted elsewhere."
				end
				if kind == "pname" then
					p.name = text
				else
					p.text = text
				end
				empty = p.text == ""
				return nil
			end)
		end
		settle(s, row, err)
		if not err and empty then
			beginEdit(state, "ptext:" .. id) -- a new prompt: named, now write it
		elseif not err and kind == "ptext" then
			focusPrompt(state, false)
		end
	elseif kind == "setup" and id then
		local repo, slot = string.match(row, "^setup:(.+):(%w+)$")
		if not repo then
			return
		end
		local at = tonumber(slot) -- nil: the "Add a command" row
		local err = editSetup(repo, function(list: { string }): string?
			if at and at > #list then
				return "That command was removed elsewhere."
			elseif not at then
				table.insert(list, text)
			elseif text == "" then
				table.remove(list, at)
			else
				list[at] = text
			end
			return nil
		end)
		settle(s, row, err)
		if not err and at and text == "" then
			s.focus = "setup:" .. repo .. ":new"
		end
	elseif kind == "branch" and id then
		-- Empty goes back to the default format; anything else must be a format that can name a branch.
		settle(s, row, if text == "" then formats.saveRepo(id, nil) else (tracker.formatProblem(text) or formats.saveRepo(id, text)))
	elseif kind == "fmt" and id and formats.KEYS[id] then
		-- Empty goes back to the default; anything else must be a format that can name a branch (or folder).
		settle(s, row, if text == "" then formats.save(id, "") else (tracker.formatProblem(text, id ~= "branch") or formats.save(id, text)))
	elseif kind == "checkout" and id then
		local repo = id
		if text == "" then
			settle(s, row, clearCheckout(state, repo))
			return
		end
		local path, why = worktree.expandPath(text, tern.getenv("HOME"))
		if not path then
			s.errors[row] = why or "That is not a usable path."
			return
		end
		s.edit = nil
		state.claiming = repo
		worktree.claimCheckout(path, repo, login(state), function(claimed, problem)
			if not alive(state) then
				return
			end
			state.claiming = nil
			local root = if claimed then claimed.root else nil
			local err = if root then saveCheckout(repo, root) else (problem or "That path is not a checkout of " .. repo .. ".")
			if not err then
				s.errors[row] = nil
				local cloned = claimed ~= nil and claimed.cloned
				state.scanned = nil -- the new checkout may already hold worktrees: the next render scans it
				state.cx:toast("success", if cloned then "Cloned " .. repo else "Checkout saved", root)
			elseif state.settings == s and s.page == "repos" then
				s.open = repo -- its form, should it have been closed meanwhile
				beginEdit(state, row, text) -- the draft stays for a correction; this clears the row's warning, so set it after
				s.errors[row] = err
			else
				state.cx:toast("error", "Checkout not saved", err) -- Settings closed, or the Repositories page that shows the row was left
			end
			state.cx:render()
		end)
	end
end

-- Escape (or clicking away) leaves a text row without saving; the row's warning belonged to the rejected value.
local function discardEdit(state: State)
	local s = state.settings
	local e = if s then s.edit else nil
	if s and e then
		s.edit = nil
		s.errors[e.row] = nil
		if e.model.multi then
			focusPrompt(state, false)
		end
	end
end

-- Opens Settings page `page` with nothing focused or being edited. Views learns the signed-in gh logins (a group each);
-- a setup page asks again whether the CLIs start, so one installed meanwhile turns its integration on.
local function showPage(state: State, s: Settings, page: string)
	discardEdit(state)
	s.page, s.focus, s.pick, s.errors = page, nil, nil, {}
	state.settingsPage = page
	if page == "views" then
		ghActive.note(state, true)
	elseif string.find(page, "^setup%-") then
		cli.probe(true)
	end
end

local function resetRow(state: State, row: string)
	local s = state.settings
	if not s then
		return
	end
	local kind, id = string.match(row, "^(%a+):(.+)$")
	local err: string? = nil
	if kind == "checkout" and id then
		err = clearCheckout(state, id)
	elseif kind == "branch" and id then
		err = formats.saveRepo(id, nil)
	elseif kind == "fmt" and id and formats.KEYS[id] then
		err = formats.save(id, "")
	elseif kind == "pmodel" and id then
		local pk, pid = kindAndId(id)
		if pk then
			err = editPrompts(pk, function(store: Prompts): string?
				local p = promptById(store, pid)
				if p then
					p.model = nil
				end
				return nil
			end)
		end
	elseif kind == "key" and id then
		err = keys.save(id, nil)
		if not err then
			propagate(state)
		end
	end
	s.errors[row] = err
	if not err and s.edit and s.edit.row == row then
		s.edit = nil
	end
end

-- Opens Settings on `page`, else the page it last showed, else Views (also for a page it does not show now). With
-- `row` ("<field>:<item>"), the item's form is open and `row` focused.
local function openSettings(state: State, page: string?, row: string?, edit: boolean?)
	discardEdit(state) -- releases the prompt editor's caret, if one was open
	local s: Settings = { page = "views", errors = {}, open = if row then string.match(row, "^%a+:(.+)$") else nil }
	state.settings = s
	showPage(state, s, cli.page(page or state.settingsPage))
	s.focus = row
	if edit and row then
		beginEdit(state, row)
	end
end

-- The window's repository picker chose `raw` ("owner/name", maybe typed): it is listed in Settings, which opens on
-- its checkout row to set it.
local function addRepo(state: State, raw: any)
	local repo = parseRepo(raw)
	if not repo then
		return state.cx:toast("error", "Not a repository", "Type it as owner/name.")
	end
	local err = saveCheckout(repo, "", true)
	if err then
		return state.cx:toast("error", "Repository not saved", err)
	end
	openSettings(state, "repos", "checkout:" .. string.lower(repo), true)
end

-- The window's Jira project picker chose `raw` (a project key, maybe typed in lowercase): it is listed in Settings,
-- which opens on its repositories.
local function addJira(state: State, raw: any)
	local key = string.upper(if type(raw) == "string" then trim(raw) else "")
	if not tracker.jiraProject(key) then
		return state.cx:toast("error", "Not a Jira project key", "Type its key, such as ABC.")
	end
	local err = editJiraRepos(function(map: { [string]: any }): string?
		map[key] = stringList(map[key])
		return nil
	end)
	if err then
		return state.cx:toast("error", "Jira project not saved", err)
	end
	openSettings(state, "jira", "jrepos:" .. key, false)
end

local function openSelected(state: State, act: string, rerender: boolean)
	local item = selected(state)
	if item then
		if rerender then
			state.cx:render() -- sends the new preview before the open request
		end
		state.cx:open(hrefOf(state, item, act))
	end
end

-- How a worktree report stands: success only for a current, clean worktree; a stale or changed one deserves a look.
-- nil (no tone) while its changes are unread, as for a worktree the last scan found: git has not been asked yet.
local function noteTone(note: Note): string?
	if not note.ok then
		return "error"
	elseif not note.current or note.dirty == true then
		return "warning"
	end
	return if note.dirty == false then "success" else nil
end

-- The "In tab" and "Worktree" badges an item's row starts with; `one` names the item in the tooltip, `go` is the key that
-- goes to the tab ("": none).
local function tabBadges(one: string, note: Note?, open: boolean, go: string): { any }
	local badges: { any } = {}
	if open then
		table.insert(badges, { text = "In tab", tone = "accent", title = "A tab works in this " .. one .. "'s worktree" .. (if go ~= "" then " (" .. go .. " goes there)" else "") })
	end
	if note and note.ok then
		table.insert(badges, {
			text = "Worktree",
			tone = noteTone(note),
			title = (note.summary or "Worktree ready") .. (if note.path then " · " .. note.path else ""),
		})
	end
	return badges
end

local function pickerItem(pr: github.Pr, note: Note?, open: boolean, go: string): { [string]: any }
	local check = if pr.checks then CHECK[pr.checks] else nil
	local kind = stateKind(pr)
	local badges = tabBadges("pull request", note, open, go)
	if kind ~= "open" then
		table.insert(badges, STATE_BADGE[kind])
	end
	for _, l in pr.labels do
		table.insert(badges, { text = l })
	end
	-- The integration comes first, on the title's row.
	table.insert(badges, 1, { text = INTEGRATIONS.github.label, tone = "muted" })
	-- GitHub's list row: "#N · @author opened 2h ago · Review required · ✓ 3/5", the review and checks as toned text so
	-- they don't read as the state and label badges.
	local detail: { any } = { ui.span("#" .. pr.number, "num"), " · ", ui.span(pr.repo, "mono"), " · ", ui.span("@" .. pr.author, "mono"), " opened " .. github.age(pr.created) .. " ago" }
	local review = if pr.review then REVIEW_BADGE[pr.review] else nil
	if review then
		table.insert(detail, " · ")
		table.insert(detail, ui.span(review.text, review.tone))
	end
	if check and pr.runTotal > 0 then
		-- ponytail: passes among the search's first 25 checks (the total is exact); read the detail runs if that misleads.
		local ok = 0
		for _, r in pr.runs do
			if r.status == "success" or r.status == "neutral" then
				ok += 1
			end
		end
		table.insert(detail, " · ")
		table.insert(detail, ui.span(check.mark .. " " .. ok .. "/" .. pr.runTotal, check.tone))
	end
	return {
		id = itemId(pr),
		label = pr.title,
		title = pr.title,
		detail = detail,
		mark = { text = pr.author, seed = pr.author },
		badges = if #badges > 0 then badges else nil,
		facts = { comments = if pr.comments > 0 then tostring(pr.comments) else nil }, -- the icon is CSS (plotroom.css)
	}
end

-- An issue's picker row: "#N · repo · @author opened 2h ago" (Jira: "ABC-12 · Author · Type"); its integration, workflow
-- status or, once closed, its state, and its labels as badges. The preview lists the assignees; the rows do not.
local function issueRow(issue: tracker.Issue, note: Note?, open: boolean, go: string): { [string]: any }
	local badges = tabBadges("issue", note, open, go)
	if issue.status or issue.state == "closed" then
		table.insert(badges, issueBadge(issue))
	end
	for _, l in issue.labels do
		table.insert(badges, { text = l })
	end
	table.insert(badges, 1, { text = INTEGRATIONS[issue.tracker].label, tone = if issue.tracker == "jira" then "accent" else "muted" })
	local at = if issue.tracker == "github" then "@" else ""
	local detail: { any } = { ui.span(tracker.refLabel(issue.ref), "num") }
	if issue.tracker == "github" then
		table.insert(detail, " · ")
		table.insert(detail, ui.span(issue.repo, "mono")) -- a Jira key already names its project
	end
	table.insert(detail, " · ")
	table.insert(detail, ui.span(at .. issue.author, "mono"))
	if issue.created > 0 then
		table.insert(detail, " opened " .. github.age(issue.created) .. " ago")
	end
	if issue.type then
		table.insert(detail, " · " .. issue.type)
	end
	return {
		id = itemId(issue),
		label = issue.title,
		title = issue.title,
		detail = detail,
		mark = { text = issue.author, seed = issue.author },
		badges = if #badges > 0 then badges else nil,
		facts = { comments = if issue.comments > 0 then tostring(issue.comments) else nil }, -- the comment icon is CSS (plotroom.css)
	}
end

-- The picker rows of a snapshot, built once: again only when a worktree report arrives, the minute changes (the
-- ages), the set of items open in a tab changes or so does the key that goes to a tab.
local function rowsOf(state: State, snap: Snap, open: { [string]: boolean }): { any }
	local minute = os.time() // 60
	local go = (keys.load())["goto"]
	local ids: { string } = {}
	for id in open do
		table.insert(ids, id)
	end
	table.sort(ids)
	local openKey = go .. "|" .. table.concat(ids, ",")
	local cached = snap.rows
	if cached and snap.rowsRev == state.noteSeq and snap.rowsMin == minute and snap.rowsOpen == openKey then
		return cached
	end
	local rows: { any } = {}
	local issues = snap.kind == "issues"
	for _, item in snap.items do
		local isOpen = open[item.key] == true
		table.insert(rows, if issues then issueRow(item, state.notes[item.key], isOpen, go) else pickerItem(item, state.notes[item.key], isOpen, go))
	end
	tern.json.array(rows)
	snap.rows, snap.rowsRev, snap.rowsMin, snap.rowsOpen = rows, state.noteSeq, minute, openKey
	return rows
end

-- Link to a check's page: its row index (the window reads the live row to validate) and the percent-encoded URL.
local function checkHref(i: number, url: string): string
	return "plotroom://github/check/" .. i .. "/" .. pct(url)
end

local loadDetails: (State, string) -> ()

-- Loads the checks of `key` after `ms`. One attempt waits at a time; a new one replaces it.
local function armDetails(state: State, key: string, ms: number)
	cancelDetails(state)
	local attempt: Attempt = { key = key, timer = nil }
	state.detailAttempt = attempt
	attempt.timer = tern.timer(ms, function()
		if state.detailAttempt ~= attempt then
			return -- replaced or cancelled: the slot belongs to someone else now
		end
		state.detailAttempt = nil
		if alive(state) then
			loadDetails(state, key)
		end
	end)
end

-- Remembers why the checks of `key` could not be loaded (the preview says so) and when to try again: a rate limit
-- waits for its reset, other failures back off, and problems retrying cannot fix (sign-in, access, gh missing) wait
-- for an explicit Retry.
local function failDetails(state: State, key: string, problem: github.Problem)
	local prev = state.detailFail[key]
	local tries = if prev then prev.tries + 1 else 1
	local now = os.time()
	local retryAt: number? = nil
	if problem.kind == "rate-limit" then
		retryAt = now + math.max(waitOf(state), DETAIL_RETRY_S)
	elseif not TERMINAL[problem.kind] then
		retryAt = now + math.min(DETAIL_RETRY_S * 2 ^ (tries - 1), DETAIL_RETRY_MAX_S)
	end
	state.detailFail[key] = { problem = problem, tries = tries, retryAt = retryAt }
end

-- Whether the checks of `key` were loaded after the latest search (an older list is shown, but loads again).
local function upToDate(state: State, key: string): boolean
	local d = state.details[key]
	return d ~= nil and d.round == state.round
end

loadDetails = function(state: State, key: string)
	local item = selected(state)
	if not item or detailKey(state, item) ~= key or upToDate(state, key) or state.detailBusy[key] then
		return -- the cursor moved on, or it is loaded or loading already: a render asks again if it still matters
	end
	local snap = state.snap
	local account, round, kind = state.account, state.round, if snap then snap.kind else state.kind.id
	local function current(): boolean
		return state.account == account and state.round == round and state.kind.id == kind
	end
	local function live(): boolean
		return running[state.cx.pane] == state and current()
	end
	state.detailBusy[key] = true
	if kind == "issues" then
		-- A GitHub load, like github.checks, sends nothing while the quota is spent or the login unusable: it
		-- answers with that problem, which failDetails paces.
		TRACKERS[item.tracker].detail(item, login(state), function(detail, problem)
			state.detailBusy[key] = nil
			if not alive(state) then
				return
			end
			if not current() or (problem and problem.kind == "superseded") then
				state.cx:render() -- another identity or a newer search owns the preview now: its own render asks for fresh details
				return
			end
			if detail then
				state.details[key] = { runs = {}, total = 0, round = round, issue = detail }
				state.detailFail[key] = nil
			else
				failDetails(state, key, problem or { kind = "failed", message = "The issue could not be read." })
			end
			state.cx:render()
		end, live)
		return
	end
	local pr: github.Pr = item
	-- github.checks sends nothing while the quota is spent or the saved login unusable: it answers with that problem, which failDetails paces.
	github.checks(pr.repo, pr.number, login(state), function(runs, total, problem, about)
		state.detailBusy[key] = nil
		if not alive(state) then
			return
		end
		if not current() or (problem and problem.kind == "superseded") then
			state.cx:render() -- another identity or a newer search owns the preview now: its own render asks for fresh checks
			return
		end
		if runs then
			state.details[key] = { runs = runs, total = total, round = round, about = about }
			state.detailFail[key] = nil
		else
			failDetails(state, key, problem or { kind = "failed", message = "The checks could not be read." })
		end
		state.cx:render()
	end, live)
end

-- Once the cursor rests on a PR with checks, loads all of them with their required flags (the search carries the first
-- 25, unflagged, and shows them meanwhile; checks loaded before the latest search show meanwhile too, and load again).
-- Once it rests on an issue, loads its body, milestone and linked pull requests. Idempotent: every render calls it. A
-- load waits out a debounce and a failed one its retry delay; moving to another item cancels the wait.
local function wantDetails(state: State, item: any)
	local key = detailKey(state, item)
	local waiting = state.detailAttempt
	if waiting and waiting.key ~= key then
		cancelDetails(state)
		waiting = nil
	end
	if not key or waiting or upToDate(state, key) or state.detailBusy[key] then
		return
	end
	local fail = state.detailFail[key]
	if not fail then
		armDetails(state, key, DETAIL_DEBOUNCE_MS)
	elseif fail.retryAt then
		armDetails(state, key, math.max(0, fail.retryAt - os.time()) * 1000)
	end
end

-- Keeps the outcome of a worktree attempt (a report, or why there is none) for the queue preview: persistent, unlike
-- a toast. `key` is the item's key (lowercase "owner/repo#n"). The next render scans the checkouts again, so git
-- confirms a report. Only the attempts git has not confirmed count against NOTE_CAP: a block may hold more worktrees
-- than that.
local function noteWorktree(state: State, key: string, kind: string, r: Report?, problem: string?)
	local note: Note = {
		seq = state.noteSeq + 1,
		kind = kind,
		at = os.time(),
		ok = r ~= nil,
		current = r ~= nil and r.current,
		dirty = if r then r.dirty else nil,
		root = if r then r.root else nil,
		path = if r then r.path else nil,
		branch = if r then r.branch else nil,
		ref = if r then r.ref else nil,
		summary = if r then r.summary else nil,
		message = if problem then clip(printable(problem), 1500) else nil,
		update = if r then r.update else {},
		checked = if r and r.dirty ~= nil then state.round else nil, -- the attempt has just read `git status`
	}
	state.notes[key] = note
	state.noteSeq = note.seq
	state.scanned = nil
	local count, oldest = 0, nil :: string?
	local oldestSeq = math.huge
	for other, n in state.notes do
		if not n.git then
			count += 1
			if n.seq < oldestSeq then
				oldest, oldestSeq = other, n.seq
			end
		end
	end
	if count > NOTE_CAP and oldest then
		state.notes[oldest] = nil
	end
end

-- ---------------------------------------------------------------- requests from window.luau
-- window.luau runs on the machine showing the window, which for a pane on a remote host is not the machine holding
-- the checkout. So whatever reads the checkout or runs git, gh or omp runs here, where the block runs: the window sends
-- {act = "rpc", value = JSON {id, op, ...}}; the answer is the hidden node `main.r<id>` (JSON text), announced by
-- opening plotroom://rpc/<id>, which only the window waiting for that id acts on. `main.rpc` says which protocol this
-- host speaks, so a window never waits on a host running another Plotroom version.

local RPC_PROTOCOL = "13"
local REPLY_CAP = 8 -- answers kept on screen, newest last: windows read theirs once announced
-- Picker rows sent stop at this much encoded text: the answer must fit the window's 64000-character surface read.
local MENU_BUDGET = 48000

-- Pull requests and issues whose worktree is being prepared or removed on this host ("owner/repo#n", lowercase): one
-- at a time, whichever window asks.
local preparing: { [string]: boolean } = {}

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

local function rpcNodes(state: State): { Node }
	local out: { Node } = { ui.node("text", { key = "rpc", text = RPC_PROTOCOL, hidden = true }) }
	for _, r in state.replies do
		table.insert(out, ui.node("text", { key = "r" .. r.id, text = r.text, hidden = true }))
	end
	local s = state.settings
	if s and s.confirm then
		table.insert(out, ui.node("text", { key = "confirm", text = tern.json.encode(deleteQuestion(state, s.confirm)), hidden = true }))
	end
	return out
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

-- The variables of an issue's prompts and branch name (KINDS.issues.vars lists them); `code` is the GitHub repository the
-- issue is worked in. `branch`, `base` and `remote` are only known once a worktree exists.
local function issueVars(issue: tracker.Issue, code: string): { [string]: string }
	local owner, name = string.match(code, "^([^/]+)/([^/]+)$")
	local vars: { [string]: string } = {
		url = issue.url,
		key = issue.ref,
		title = issue.title,
		author = issue.author,
		labels = table.concat(issue.labels, ", "),
		owner = owner or "",
		repo = name or "",
	}
	if issue.tracker == "jira" then
		vars.project = issue.repo
		vars.status = if issue.status then issue.status.text else ""
		vars.type = issue.type or ""
	else
		vars.number = issue.ref
	end
	return vars
end

-- The GitHub repository an issue is worked in: its own, or the one its Jira project maps to when that is exactly one;
-- nil while the choice is still to be made.
local function codeRepoOf(issue: tracker.Issue): string?
	if issue.tracker ~= "jira" then
		return issue.repo
	end
	local mapped = jiraReposOf(issue.repo)
	return if #mapped == 1 then mapped[1] else nil
end

-- `{github.user}` and `{jira.user}`: who you are on GitHub and Jira, for branch formats and prompts.
local me = {}

-- Reads `{github.user}` (the login the active view's gh account is, else gh's active one; "" while gh is off) and,
-- `jiraToo`, `{jira.user}`; done(users), "" for one that could not be read.
function me.read(state: State, jiraToo: boolean, done: ({ [string]: string }) -> ())
	local account = login(state)
	local function read(gh: string?)
		if gh and not account then
			ghActive.login = gh
		end
		local users: { [string]: string } = { ["github.user"] = gh or "", ["jira.user"] = "" }
		if not jiraToo then
			return done(users)
		end
		jira.user(function(ju)
			if ju then
				users["jira.user"] = ju
			end
			done(users)
		end)
	end
	if cli.on("github") then
		github.login(account, read)
	else
		read(nil)
	end
end

-- Whether `text` names `{github.user}` or `{jira.user}`.
function me.named(text: string): boolean
	return string.find(text, "{github.user}", 1, true) ~= nil or string.find(text, "{jira.user}", 1, true) ~= nil
end

-- The users known without asking for `issue` (a Jira user only for a Jira issue); an unknown one is left out. The active
-- view's own gh login is its user; else gh's active login, once ghActive.note or me.read found it. The Jira user is
-- known once a Jira search found the site.
function me.of(state: State, issue: tracker.Issue): { [string]: string }
	return {
		["github.user"] = login(state) or ghActive.login,
		["jira.user"] = if issue.tracker == "jira" then jira.known() else "",
	}
end

-- The branch format an issue's new branch in `code` gets: the repository's own, else the Worktrees one.
function formats.issueBranch(code: string): string
	return formats.repoOf(code) or formats.of("branch")
end

-- The branch a new worktree of `issue` in `code` gets (formats.issueBranch over its variables and `users`; a user not
-- in `users` stays as its variable), and its worktree's folder name. nil and why when a format cannot name one.
function formats.issue(issue: tracker.Issue, code: string, users: { [string]: string }): (string?, string?, string?)
	local owner, name = string.match(code, "^([^/]+)/([^/]+)$")
	local slug = tracker.slug(issue.title)
	local vars: { [string]: string } = {
		key = issue.ref,
		slug = slug,
		owner = owner or "",
		repo = name or "",
		project = if issue.tracker == "jira" then issue.repo else "",
		["github.user"] = users["github.user"] or "{github.user}",
		["jira.user"] = users["jira.user"] or "{jira.user}",
	}
	local branch, why = tracker.render(formats.issueBranch(code), vars)
	if not branch then
		return nil, nil, why
	end
	local dir, dirWhy = tracker.render(formats.of("issuedir"), { key = issue.ref, slug = slug, owner = string.lower(owner or ""), repo = string.lower(name or "") }, true)
	if not dir then
		return nil, nil, dirWhy
	end
	return branch, dir, nil
end

-- The folder name pull request `n` of `repo` ("owner/name") titled `title` gets, or nil and why.
function formats.prDir(repo: string, n: number, title: string): (string?, string?)
	local owner, name = string.match(string.lower(repo), "^([^/]+)/([^/]+)$")
	return tracker.render(formats.of("prdir"), { key = tostring(n), slug = tracker.slug(title), owner = owner or "", repo = name or "" }, true)
end

-- How worktree.scan knows `item`'s worktree (a github.Pr, or a tracker.Issue worked in one of `codes`): a pull
-- request's by its head branch, an issue's by the branch the format names now; either by the folder name the format
-- names now.
function formats.want(state: State, kind: string, item: any, codes: { string }): worktree.Want
	local want: worktree.Want = { branches = {}, dirs = {} }
	if kind ~= "issues" then
		local owner, name = string.match(item.repo, "^([^/]+)/([^/]+)$")
		table.insert(want.branches, worktree.prBranch(item.head, item.fork))
		want.ref = worktree.prRef(owner or "", name or "", item.number)
		local dir = formats.prDir(item.repo, item.number, item.title)
		if dir then
			table.insert(want.dirs, dir)
		end
		return want
	end
	local users = me.of(state, item)
	for _, code in codes do
		local branch, dir = formats.issue(item, code, users)
		if branch and dir then
			table.insert(want.branches, branch)
			table.insert(want.dirs, dir)
		end
	end
	return want
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

-- The saved prompts offered under the active view, those with text: the ones the view lists (`here`), else every one;
-- and why the prompts could not be read.
local function offered(state: State): ({ { prompt: Prompt, here: boolean } }, string?)
	local active = activeView(state)
	local prompts, problem = loadPrompts(if active then KINDS[active.kind] else state.kind)
	local list: { Prompt } = if prompts then prompts.items else {}
	local ids = if active then livePrompts(active, list) else {}
	local out: { { prompt: Prompt, here: boolean } } = {}
	for _, p in list do
		if p.text ~= "" and (#ids == 0 or table.find(ids, p.id) ~= nil) then
			table.insert(out, { prompt = p, here = #ids > 0 })
		end
	end
	return out, problem
end

-- The agent picker's rows: `offered`, each with its id so a prompt's run link can name it. With `only`, just that
-- prompt, so a shortcut never misses its prompt to the picker's size budget.
local function menu(state: State, id: string, only: string?)
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
		})
	end
	local items: { any } = {}
	local size = 0
	for _, row in mine do
		size += #tern.json.encode(row)
		if size > MENU_BUDGET then
			break
		end
		table.insert(items, row)
	end
	reply(state, id, { items = tern.json.array(items), problem = problem })
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
			for _, p in prs do
				if p.branch then
					table.insert(live, { number = p.number, title = clip(printable(p.title), 160), branch = p.branch })
				end
			end
			if #live == 0 then
				return prepareIssue(state, id, repo, ref, wt, target, { fresh = true }, users)
			elseif #live == 1 then
				return prepareIssue(state, id, repo, ref, wt, target, { pr = live[1].number, fresh = false }, users)
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
			local list: { string } = {}
			local size = 0
			for _, b in names do
				size += #b + 3
				if size > MENU_BUDGET then
					break
				end
				table.insert(list, b)
			end
			reply(state, id, { chooseBase = true, branch = branch, branches = tern.json.array(list) })
		end)
	end

	local function go(found: { [string]: string })
		if need then
			vars["github.user"] = found["github.user"] or ""
			vars["jira.user"] = found["jira.user"] or ""
		end
		if not wt then
			return reply(state, id, { path = checkout, summary = "Main checkout", created = false, current = true, vars = vars })
		end
		local branch, dir, why = formats.issue(issue, code, found)
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
		local more: { string } = {}
		local size = 0
		local list: { string } = names or {}
		for _, name in list do
			size += #name + 3
			if size > MENU_BUDGET then
				break
			end
			table.insert(more, name)
		end
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
		local items: { any } = {}
		local size = 0
		for _, row in rows do
			size += #tern.json.encode(row)
			if size > MENU_BUDGET then
				break
			end
			table.insert(items, row)
		end
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
	local key = string.lower(repo)
	state.claiming = key
	worktree.claimCheckout(path, repo, login(state), function(claimed, problem)
		if state.claiming == key then
			state.claiming = nil
		end
		local root = if claimed then claimed.root else nil
		if not root then
			return reply(state, id, { problem = problem or "That path is not a checkout of " .. repo .. "." })
		end
		local err = saveCheckout(repo, root)
		if err then
			return reply(state, id, { problem = err })
		end
		state.scanned = nil -- the new checkout may already hold worktrees: the reply's render scans it
		reply(state, id, { ok = true, root = root, cloned = claimed ~= nil and claimed.cloned })
	end)
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

-- One request from the window. Untrusted shape: anything malformed is dropped (the window gives up waiting).
local function rpc(state: State, raw: any)
	if type(raw) ~= "string" or #raw > 16384 then
		return
	end
	local ok, q = pcall(tern.json.decode, raw)
	if not ok or not isTable(q) or type(q.id) ~= "string" or not string.match(q.id, "^%w+$") or #q.id > 40 then
		return
	end
	local id: string = q.id
	if q.op == "menu" then
		menu(state, id, if type(q.only) == "string" then q.only else nil)
	elseif q.op == "repos" then
		repos(state, id)
	elseif q.op == "profile" and type(q.login) == "string" and string.match(q.login, "^[%w%-]+$") then
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
		if not repo or type(project) ~= "string" or not tracker.jiraProject(project) then
			return
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
	elseif q.op == "where" and (q.kind == "pr" or q.kind == "issue") and type(q.key) == "string" and #q.key <= 200 then
		-- The worktree folder of an item as its note has it (git's list or the last attempt), for the window's Go to tab:
		-- a note of the kind asked about.
		local note = state.notes[q.key]
		reply(state, id, { path = if note and note.ok and note.kind == (if q.kind == "pr" then "prs" else "issues") then note.path else nil })
	end
end

-- The checks of the selected PR once loaded (Tern's shimmer meanwhile), with an error, its retry time and a Retry
-- button when the load failed.
local function checksNodes(state: State, pr: github.Pr): { Node }
	local out: { Node } = {}
	local key = detailKey(state, pr)
	local d = if key then state.details[key] else nil
	local fail = if key then state.detailFail[key] else nil
	local runs: { github.Run } = if d then d.runs else pr.runs
	local total = if d then d.total else pr.runTotal
	local loading = pr.checks ~= nil and key ~= nil and d == nil and fail == nil
	if #runs == 0 and not loading and not fail then
		return out
	end
	table.insert(out, ui.node("text", { key = "runs-head", spans = { ui.span("Checks", "strong") } }))
	if loading then
		table.insert(out, ui.node("shimmer", { key = "runs-loading", text = "Loading checks…" }))
		return out
	elseif fail then
		local when = if fail.retryAt then "Trying again at " .. os.date("%H:%M:%S", fail.retryAt) .. "." else "Retry to load them."
		table.insert(
			out,
			ui.node("text", {
				key = "runs-state",
				spans = { ui.span("Could not load all checks: " .. brief(fail.problem.message), "error"), ui.span("  " .. when, "muted") },
			})
		)
		table.insert(
			out,
			ui.node("item", { key = "runs-retry", label = "Retry", icon = "redo", aria = "Retry loading all checks", actions = { click = "retry-checks" } })
		)
	end
	-- Every check, required ones apart, each group worst first (github.runs' order). The icon and its tone are the
	-- status (the tooltip spells it out), so the value is only how long it took. A `workflow / job` name shows the job,
	-- with the workflow dim after it and cut first. Only `item` rows go in a list: other kinds get no row behaviour.
	local groups: { [string]: { Node } } = { required = {}, runs = {} }
	for i, r in runs do
		local workflow, job = string.match(r.name, "^(.*) / (.+)$")
		local what = r.name .. " — " .. r.detail .. (if r.required then " (required)" else "")
		local props: { [string]: any } = {
			key = "run" .. i,
			label = job or r.name,
			detail = workflow,
			value = r.took,
			icon = RUN_ICON[r.status],
			tone = RUN_TONE[r.status],
			title = what,
			aria = what,
		}
		if r.url then
			props.href = checkHref(i, r.url)
			props.actions = { click = "open" }
		end
		table.insert(groups[if r.required then "required" else "runs"], ui.node("item", props))
	end
	local function head(key: string, text: string)
		table.insert(out, ui.node("text", { key = key, spans = { ui.span(text, "muted") } }))
	end
	if #groups.required > 0 then
		head("required-head", "Required · " .. #groups.required)
		table.insert(out, ui.node("list", { key = "required" }, groups.required))
	end
	if #groups.runs > 0 then
		if #groups.required > 0 then
			head("optional-head", "Optional · " .. #groups.runs)
		end
		table.insert(out, ui.node("list", { key = "runs" }, groups.runs))
	end
	if total > #runs then
		table.insert(out, ui.node("text", { key = "runs-more", spans = { ui.span((total - #runs) .. " more not loaded", "muted") } }))
	end
	return out
end

-- The selected item's action-bar buttons, each with the link it opens: Open, Worktree, Go to tab while a tab works in
-- it, and Agent (the `a` picker of the saved prompts offered under this view, or typed text). A missing repository or
-- checkout is asked for in the window's palette when one is needed. A button's `keys` are its keycap: the configured
-- key of Worktree, Go to tab and Agent (Settings › Keyboard shortcuts; none once removed).
type Action = { id: string, label: string, keys: { string }?, href: string, primary: boolean? }
local function itemActions(state: State, item: any, open: { [string]: boolean }): { Action }
	local tr: string = if state.kind.id == "issues" then item.tracker else "github"
	local map = keys.load()
	-- ↗, not a Nerd Font icon: an action label is plain text in Tern's sans face. No keycap: Enter is the queue's default.
	local out: { Action } = {
		{ id = "open", label = INTEGRATIONS[tr].label .. " ↗", href = hrefOf(state, item, "open"), primary = true },
		{ id = "worktree", label = "Worktree", keys = keys.caps(map, "worktree"), href = hrefOf(state, item, "worktree") },
	}
	if open[item.key] then
		table.insert(out, { id = "goto", label = "Go to tab", keys = keys.caps(map, "goto"), href = hrefOf(state, item, "goto") })
	end
	table.insert(out, { id = "agent", label = "Agent", keys = keys.caps(map, "agent"), href = hrefOf(state, item, "agent") })
	return out
end

-- The window honours only links the block shows, so each button's link, and each offered prompt's (its shortcut
-- key runs it), also sits here unseen for the window (and the palette commands) to read.
local function buttonLinks(state: State, item: any, acts: { Action }): Node
	local links: { Node } = {}
	for _, a in acts do
		table.insert(links, ui.node("text", { key = a.id, href = a.href }))
	end
	local prompts: { { prompt: Prompt, here: boolean } } = offered(state)
	for _, o in prompts do
		local id = o.prompt.id
		if string.match(id, "^%w+$") then
			table.insert(links, ui.node("text", { key = "prompt-" .. id, href = runHrefOf(state, item, id) }))
		end
	end
	return ui.node("col", { key = "buttons", hidden = true }, links)
end

-- Each part below the head sits under a hairline rule; a part with nothing to show brings none.
local function addPart(out: { Node }, key: string, nodes: { Node })
	if #nodes > 0 then
		table.insert(out, ui.node("rule", { key = "rule-" .. key }))
		table.move(nodes, 1, #nodes, #out + 1, out)
	end
end

-- A kv value is spans only, so a copy icon cannot sit in one: Branch and Base are rows of their own, spaced like
-- the kv's rows they head. `full` is what the tooltip shows and the copy icon copies when `name` is a shortened form.
local function refRow(key: string, label: string, name: string, full: string?): Node
	local whole = full or name
	return ui.node("row", { key = key, role = "plotroom.ref", gap = "xs", align = "center" }, {
		ui.node("text", { key = "k", grow = 1, shrink = 0, spans = { ui.span(label, "muted") } }),
		-- Cut in the middle (prefix and ticket suffix both matter), at most 28 cells; Tern's tooltip shows it whole.
		ui.node("text", { key = "v", truncate = "middle", shrink = 1, max = { w = "28ch" }, title = full, spans = { ui.span(name, "code") } }),
		ui.node("icon", {
			key = "copy",
			name = "copy",
			href = whole,
			actions = { click = "copy" },
			title = "Copy " .. string.lower(label),
			aria = "Copy the " .. string.lower(label) .. " " .. whole,
		}),
	})
end

-- The worktree card of the item with key `key`: persistent, with what Plotroom found (whether the worktree is at the
-- pull request's head and has uncommitted changes, where it is) and what to do with it: go to or open its tab, remove
-- it. acts: itemActions(...) of that item, whose keycaps the rows show. A failed attempt is its message alone.
local function worktreeNodes(state: State, key: string, acts: { Action }): { Node }
	local note = state.notes[key]
	if not note then
		return {}
	end
	-- No card head: Tern indents a headed card's body 36px to line up with a role icon this card has none of. The
	-- heading is the body's first row instead, so every row starts at the same edge.
	local checked = ui.node("text", { key = "checked", basis = "content", spans = { ui.span("checked " .. os.date("%H:%M", note.at), "muted") } })
	local function heading(extra: Node?): Node
		return ui.node("row", { key = "head", gap = "sm", align = "center" }, {
			ui.node("text", { key = "title", basis = "content", spans = { ui.span("Worktree", "strong") } }),
			extra or ui.node("row", { key = "none" }),
			ui.node("row", { key = "fill", grow = 1 }),
			checked,
		})
	end
	if not note.ok then
		local why = ui.node("text", { key = "message", spans = { ui.span(note.message or "The worktree could not be prepared.", "error") } })
		return { ui.node("card", { key = "worktree", tone = "error" }, { heading(), why }) }
	end
	-- The badges are the answer; the attempt's one-line summary is their tooltip.
	local chips: { Node } = {}
	if note.kind == "prs" then
		table.insert(chips, ui.node("badge", {
			key = "sync",
			text = if note.current then "Up to date" else "Not at PR head",
			tone = if note.current then "success" else "warning",
			title = note.summary,
		}))
	end
	table.insert(chips, ui.node("badge", {
		key = "changes",
		text = if note.dirty == true then "Uncommitted changes" elseif note.dirty == false then "Clean" else "Changes unchecked",
		tone = if note.dirty == true then "warning" elseif note.dirty == false then "success" else "muted",
		title = note.summary,
	}))
	local body: { Node } = { heading(ui.node("row", { key = "status", gap = "xs", wrap = true }, chips)) }
	if note.refused then
		table.insert(body, ui.node("text", { key = "refused", spans = { ui.span("Not removed. " .. note.refused, "error") } }))
	end
	if note.branch then
		table.insert(body, refRow("wbranch", "Branch", note.branch))
	end
	if note.path then
		table.insert(body, refRow("wpath", "Path", worktree.tilde(note.path, tern.getenv("HOME")), note.path))
	end
	if #note.update > 0 then
		-- A shell fence: Tern draws it with its own Copy button. The fence outgrows any backtick run in a path.
		local text = table.concat(note.update, "\n")
		local fence = "```"
		while string.find(text, fence, 1, true) do
			fence ..= "`"
		end
		local commands = ui.node("md", { key = "commands", text = fence .. "sh\n" .. text .. "\n" .. fence })
		local fold: { [string]: any } = { key = "update", head = { ui.span("Take the pull request's newer commits", "muted") }, collapsible = true, collapsed = true }
		table.insert(body, ui.node("section", fold, { commands }))
	end
	-- itemActions offers Go to tab only while a tab works in the worktree; otherwise Worktree opens one.
	local tab: Action? = nil
	local fresh: Action? = nil
	for _, a in acts do
		if a.id == "goto" then
			tab = a
		elseif a.id == "worktree" then
			fresh = a
		end
	end
	-- Buttons sized to their label (plotroom.css draws the ring), left to right: the tab, then Remove.
	local buttons: { Node } = {}
	local function button(p: { [string]: any })
		p.role, p.basis = "plotroom.button", "content"
		table.insert(buttons, ui.node("item", p))
	end
	if tab then
		button({ key = "go", label = "Go to tab", icon = "arrow-right", hint = tab.keys, aria = "Go to the tab working in this worktree", actions = { click = "goto" } })
	else
		button({ key = "open", label = "Open in new tab", icon = "plus", hint = if fresh then fresh.keys else nil, aria = "Open a new tab in this worktree", actions = { click = "worktree" } })
	end
	button({ key = "remove", label = "Remove worktree", icon = "trash", tone = "error", aria = "Remove this worktree", actions = { click = "remove-worktree" } })
	table.insert(body, ui.node("row", { key = "actions", gap = "sm", wrap = true }, buttons))
	return { ui.node("card", { key = "worktree", tone = noteTone(note) }, body) }
end

-- The description card of the item with key `key`, with no rule: it reads as part of the head. A folded bare card
-- shows its first lines under a fade and Tern's own "N more lines" button; its head row is hidden by plotroom.css, so
-- the text stands alone. `collapsed` mirrors state.descOpen (set by the card's toggle event), so Show less, a value
-- the card has not been sent yet, folds it again.
local function addDescription(out: { Node }, state: State, key: string, body: string)
	local unfolded = state.descOpen == key
	local nodes: { Node } = {
		ui.node("card", {
			key = "description",
			role = "plotroom.description",
			variant = "bare",
			collapsible = true,
			collapsed = not unfolded,
			preview = { lines = 6 },
		}, {
			ui.node("md", { key = "body", text = body }),
		}),
	}
	if unfolded then
		table.insert(nodes, ui.node("item", { key = "less", label = "Show less", icon = "chev-up", tone = "muted", actions = { click = "fold-description" } }))
	end
	table.move(nodes, 1, #nodes, #out + 1, out)
end

-- The sidebar's facts that have a value; a row without one is not shown.
local function withValue(facts: { { [string]: any } }): { { [string]: any } }
	local out = {}
	for _, f in facts do
		if f.v ~= nil then
			table.insert(out, f)
		end
	end
	return out
end

-- pr: selected(state) while the active view lists pull requests; acts: itemActions(state, pr, open).
local function previewNodes(state: State, pr: github.Pr?, open: { [string]: boolean }, acts: { Action }): { Node }
	if not pr then
		cancelDetails(state)
		return {}
	end
	-- The detail load also brings the merge state, reviewers and description, so a PR without checks needs it too.
	wantDetails(state, pr)
	local check = if pr.checks then CHECK[pr.checks] else nil
	local review = if pr.review then REVIEW_BADGE[pr.review] else nil
	local sb = STATE_BADGE[stateKind(pr)] or STATE_BADGE.open
	local chips: { Node } = {}
	if open[pr.key] then
		table.insert(chips, ui.node("badge", { key = "tab", text = "In tab", tone = "accent" }))
	end
	for i, l in pr.labels do
		table.insert(chips, ui.node("badge", { key = "label" .. i, text = l }))
	end
	local dkey = detailKey(state, pr)
	local detail = if dkey then state.details[dkey] else nil
	local about = if detail then detail.about else nil
	local loading = dkey ~= nil and detail == nil and state.detailFail[dkey] == nil
	local facts: { { [string]: any } } = {
		{ k = "Repository", v = { ui.span(pr.repo, "mono") } },
		{ k = "Author", v = "@" .. pr.author },
		{ k = "Checks", v = if check then { ui.span(check.text, check.tone) } else nil },
		{ k = "Review", v = if review then { ui.span(review.text, review.tone) } else nil },
		{ k = "Comments", v = { ui.span(tostring(pr.comments), "num") } },
		{ k = "Opened", v = github.age(pr.created) .. " ago" },
		{ k = "Updated", v = github.age(pr.updated) .. " ago" },
	}
	if about then
		local m = MERGE_STATE[about.merge] or MERGE_STATE.unknown
		table.insert(facts, 2, { k = "Merge", v = { ui.span(m.text, m.tone) } })
	end
	local out: { Node } = {
		buttonLinks(state, pr, acts),
		-- The PR's state sits at the head row's right end; an empty growing column pushes it there.
		ui.node("row", { key = "head", gap = "xs", align = "center" }, {
			ui.text({ ui.span("#" .. pr.number, "num") }),
			ui.node("icon", {
				key = "copy",
				name = "copy",
				href = pr.url,
				actions = { click = "copy" },
				title = "Copy link",
				aria = "Copy link to pull request #" .. pr.number,
			}),
			ui.node("col", { key = "fill", grow = 1 }),
			ui.node("badge", { key = "state", text = sb.text, tone = sb.tone }),
		}),
		ui.node("row", { key = "titlerow", gap = "xs", align = "center" }, {
			ui.node("text", { key = "title", spans = { ui.span(pr.title, "strong") } }),
			ui.node("badge", { key = "integration", text = INTEGRATIONS.github.label, tone = "muted" }),
		}),
	}
	if #chips > 0 then
		table.insert(out, ui.node("row", { key = "chips", gap = "xs", wrap = true }, chips))
	end
	addPart(out, "worktree", worktreeNodes(state, pr.key, acts))
	if about and string.find(about.body, "%S") then
		addDescription(out, state, pr.key, about.body)
	end
	local properties: { Node } = {
		ui.node("col", { key = "about", gap = "sm" }, {
			refRow("branch", "Branch", pr.head),
			refRow("base", "Base", pr.base),
			ui.node("kv", { key = "facts", items = withValue(facts) }),
		}),
	}
	local added, removed = pr.additions, pr.deletions
	if added + removed > 0 then
		table.insert(
			properties,
			ui.node("meter", {
				key = "diff",
				parts = {
					{ value = added / (added + removed), token = "ins", label = "+" .. added },
					{ value = removed / (added + removed), token = "error", label = "−" .. removed },
				},
				label = spans(ui.span("+" .. added, "ins"), " ", ui.span("−" .. removed, "error")),
				total = pr.files .. (if pr.files == 1 then " file" else " files"),
			})
		)
	end
	addPart(out, "properties", properties)
	if about and #about.reviews > 0 then
		local rows: { Node } = {}
		for i, r in about.reviews do
			local v = VERDICT_ROW[r.state]
			if v then
				local what = "@" .. r.login .. " — " .. v.text
				table.insert(rows, ui.node("item", { key = "r" .. i, label = "@" .. r.login, icon = v.icon, tone = v.tone, title = what, aria = what }))
			end
		end
		addPart(out, "reviewers", {
			ui.node("text", { key = "reviewers-head", spans = { ui.span("Reviewers", "strong") } }),
			ui.node("list", { key = "reviewers" }, rows),
		})
	elseif loading then
		addPart(out, "reviewers", {
			ui.node("text", { key = "reviewers-head", spans = { ui.span("Reviewers", "strong") } }),
			ui.node("shimmer", { key = "reviewers-loading", text = "Loading reviewers…" }),
		})
	end
	addPart(out, "checks", checksNodes(state, pr))
	return out
end

-- The items that go with an issue, once its details loaded (Tern's shimmer meanwhile): the pull requests that close a
-- GitHub issue, each a link that shows it in this block (window.luau's `showPr`), the issues linked to a Jira
-- one. Or why the details did not load, with a Retry button; nothing when there are none. Like the checks: one row per
-- item, its title with the number or key at the right, the icon and its tone the state (the tooltip names it); Jira's
-- under a muted heading per relation ("Blocks · 1"), in the order Jira first names each. Items without a relation
-- (GitHub's) are the one list keyed "linked", which window.luau reads.
local function linkedNodes(tr: string, detail: tracker.IssueDetail?, fail: DetailFail?, loading: boolean): { Node }
	local head = ui.node("text", { key = "linked-head", spans = { ui.span(INTEGRATIONS[tr].linked, "strong") } })
	if detail then
		if #detail.linked == 0 then
			return {}
		end
		local groups: { { relation: string?, rows: { Node } } } = {}
		local at: { [string]: number } = {} -- relation ("" for none) -> its group
		for i, l in detail.linked do
			local look = l.status or STATE_BADGE[l.state] or STATE_BADGE.open
			local what = tracker.refLabel(l.ref) .. " · " .. look.text
			local props: { [string]: any } = {
				key = "pr" .. i,
				label = l.title,
				value = tracker.refLabel(l.ref),
				icon = if l.state == "done" then "check" elseif l.state == "closed" then "x" elseif tr == "jira" then ISSUE_ICON else "merge",
				tone = look.tone,
				title = what,
				aria = l.title .. ", " .. what,
			}
			local o, r, n = github.parsePrUrl(l.url)
			if tr == "github" and o and r and n then
				props.href, props.actions = "plotroom://github/show/" .. o .. "/" .. r .. "/" .. n, { click = "open" }
			end
			local k = l.relation or ""
			if not at[k] then
				table.insert(groups, { relation = l.relation, rows = {} })
				at[k] = #groups
			end
			table.insert(groups[at[k]].rows, ui.node("item", props))
		end
		local out: { Node } = { head }
		for g, group in groups do
			local relation = group.relation
			if relation then
				local name = if relation == "subtask" then "Subtasks" else string.upper(string.sub(relation, 1, 1)) .. string.sub(relation, 2)
				table.insert(out, ui.node("text", { key = "linked-head" .. g, spans = { ui.span(name .. " · " .. #group.rows, "muted") } }))
			end
			table.insert(out, ui.node("list", { key = if relation then "linked" .. g else "linked" }, group.rows))
		end
		return out
	elseif loading then
		return { head, ui.node("shimmer", { key = "linked-loading", text = "Loading details…" }) }
	elseif fail then
		local when = if fail.retryAt then "Trying again at " .. os.date("%H:%M:%S", fail.retryAt) .. "." else "Retry to load them."
		return {
			head,
			ui.node("text", {
				key = "linked-state",
				spans = { ui.span("Could not load the details: " .. brief(fail.problem.message), "error"), ui.span("  " .. when, "muted") },
			}),
			ui.node("item", { key = "linked-retry", label = "Retry", icon = "redo", aria = "Retry loading the details", actions = { click = "retry-checks" } }),
		}
	end
	return {}
end

-- The selected issue's sidebar: head, labels, description, worktree report, properties and its linked items. issue:
-- selected(state) while the active view lists issues; acts: itemActions(state, issue, open).
local function issuePreview(state: State, issue: tracker.Issue?, open: { [string]: boolean }, acts: { Action }): { Node }
	if not issue then
		cancelDetails(state)
		return {}
	end
	-- The body, the tracker's own rows and the linked items come with the detail load.
	wantDetails(state, issue)
	local sb = issueBadge(issue)
	local chips: { Node } = {}
	if open[issue.key] then
		table.insert(chips, ui.node("badge", { key = "tab", text = "In tab", tone = "accent" }))
	end
	for i, l in issue.labels do
		table.insert(chips, ui.node("badge", { key = "label" .. i, text = l }))
	end
	local dkey = detailKey(state, issue)
	local loaded = if dkey then state.details[dkey] else nil
	local detail = if loaded then loaded.issue else nil
	local fail = if dkey then state.detailFail[dkey] else nil
	local loading = dkey ~= nil and detail == nil and fail == nil
	local at = if issue.tracker == "github" then "@" else ""
	local facts: { { [string]: any } } = {
		{ k = if issue.tracker == "jira" then "Project" else "Repository", v = { ui.span(issue.repo, "mono") } },
		{ k = if issue.tracker == "jira" then "Reporter" else "Author", v = at .. issue.author },
		{ k = "Assignees", v = if #issue.assignees > 0 then at .. table.concat(issue.assignees, ", " .. at) else nil },
	}
	if issue.type then
		table.insert(facts, { k = "Type", v = issue.type })
	end
	if issue.priority then
		table.insert(facts, { k = "Priority", v = issue.priority })
	end
	-- The tracker's own rows are only known once the details load; a row without a value is left out.
	for _, name in tracker.FIELDS[issue.tracker] do
		local fields: { tracker.Field } = if detail then detail.fields else {}
		for _, f in fields do
			if f.label == name and f.value then
				table.insert(facts, { k = name, v = { ui.span(f.value) } })
			end
		end
	end
	-- A GitHub search carries the comment count and the dates; a Jira search carries none, so they come with the details.
	local comments = if detail and detail.comments then detail.comments elseif issue.tracker == "github" then issue.comments else nil
	local created = if issue.created > 0 then issue.created elseif detail then detail.created else nil
	local updated = if issue.updated > 0 then issue.updated elseif detail then detail.updated else nil
	if comments then
		table.insert(facts, { k = "Comments", v = { ui.span(tostring(comments), "num") } })
	end
	if created then
		table.insert(facts, { k = "Opened", v = github.age(created) .. " ago" })
	end
	if updated then
		table.insert(facts, { k = "Updated", v = github.age(updated) .. " ago" })
	end
	-- The Branch row shows the branch a new worktree would make (a linked PR's is taken instead); without one (a saved
	-- format is unusable) there is none. A user not known yet (me.of) shows as its variable.
	local about: { Node } = {}
	local code = codeRepoOf(issue)
	local branch = if code then (formats.issue(issue, code, me.of(state, issue))) else nil
	if branch then
		table.insert(about, refRow("branch", "Branch", branch))
	end
	table.insert(about, ui.node("kv", { key = "facts", items = withValue(facts) }))
	local ref = tracker.refLabel(issue.ref)
	local out: { Node } = {
		buttonLinks(state, issue, acts),
		-- The issue's state sits at the head row's right end; an empty growing column pushes it there.
		ui.node("row", { key = "head", gap = "xs", align = "center" }, {
			ui.text({ ui.span(ref, "num") }),
			ui.node("icon", {
				key = "copy",
				name = "copy",
				href = issue.url,
				actions = { click = "copy" },
				title = "Copy link",
				aria = "Copy link to issue " .. ref,
			}),
			ui.node("col", { key = "fill", grow = 1 }),
			ui.node("badge", { key = "state", text = sb.text, tone = sb.tone }),
		}),
		ui.node("row", { key = "titlerow", gap = "xs", align = "center" }, {
			ui.node("text", { key = "title", spans = { ui.span(issue.title, "strong") } }),
			ui.node("badge", { key = "integration", text = INTEGRATIONS[issue.tracker].label, tone = if issue.tracker == "jira" then "accent" else "muted" }),
		}),
	}
	if #chips > 0 then
		table.insert(out, ui.node("row", { key = "chips", gap = "xs", wrap = true }, chips))
	end
	if detail and string.find(detail.body, "%S") then
		addDescription(out, state, issue.key, detail.body)
	end
	addPart(out, "worktree", worktreeNodes(state, issue.key, acts))
	addPart(out, "properties", { ui.node("col", { key = "about", gap = "sm" }, about) })
	addPart(out, "linked", linkedNodes(issue.tracker, detail, fail, loading))
	return out
end

local function helpOverlay(state: State): Node
	local map = keys.load()
	local listed: { KeyHelp } = if state.settings then SETTINGS_KEYS else state.kind.keys
	local rows: { KeyHelp } = {}
	for _, h in listed do
		local caps = table.clone(h.keys)
		local actions: { string } = h.actions or {}
		for _, id in actions do
			if map[id] ~= "" then
				table.insert(caps, map[id])
			end
		end
		if #caps > 0 then
			table.insert(rows, { keys = caps, text = h.text })
		end
	end
	local shortcuts: { { prompt: Prompt, here: boolean } } = if state.settings then {} else offered(state)
	for _, o in shortcuts do
		if o.prompt.key then
			table.insert(rows, { keys = { o.prompt.key }, text = "Run the action “" .. printable(o.prompt.name) .. "” on the selected " .. state.kind.one })
		end
	end
	-- Each row its keycaps in a column of their own, never narrower than they are, then what they do in the body font: a
	-- kv's key column is measured as text, so four keycaps ran into the description.
	local lines: { Node } = {}
	for n, h in rows do
		local caps: { Span | string } = {}
		for i, label in h.keys do
			if i > 1 then
				table.insert(caps, " ")
			end
			table.insert(caps, ui.span(label, "key"))
		end
		table.insert(
			lines,
			ui.node("row", { key = "r" .. n, gap = "md", align = "start" }, {
				ui.node("text", { key = "caps", spans = caps, wrap = "none", basis = "content", min = { w = "13ch" } }),
				ui.node("text", { key = "text", spans = { ui.span(h.text) }, grow = 1 }),
			})
		)
	end
	return ui.node("overlay", { key = "help", modal = true, size = "md", head = "Keyboard shortcuts" }, {
		ui.node("col", { key = "keys", gap = "xs" }, lines),
		ui.node("list", { key = "buttons" }, {
			ui.node("item", { key = "close", label = "Close", icon = "x", hint = { "esc" }, aria = "Close the shortcut list", actions = { click = "close-help" } }),
		}),
	})
end

-- The queue's picker; also drawn under Settings' side sheet, where keys go to Settings (so no search caret).
local function queuePicker(state: State): Node
	local snap, problem, view, item = state.snap, state.problem, activeView(state), selected(state)
	local vis = filtered(state)
	local items: { any } = {}
	local order: { any } = {}
	local open = openItems(state)
	if snap then
		items = rowsOf(state, snap, open)
	else
		tern.json.array(items)
	end
	if vis then
		order = vis.order
	else
		tern.json.array(order)
	end

	-- The active view's name is the heading; the sidebar lists them all.
	local title: { any } = { ui.span(if view then view.name else "Plotroom", "strong") }
	if snap and problem then
		table.insert(title, ui.span("  stale", "warning"))
	elseif snap and not snap.complete then
		table.insert(title, ui.span("  partial", "warning"))
	end
	local subtitle: { any } = {}
	local function note(span: any)
		if #subtitle > 0 then
			table.insert(subtitle, ui.span(" · ", "muted"))
		end
		table.insert(subtitle, span)
	end
	if state.inflight == state.gen then
		local busy: any = ui.span("Refreshing…", "muted")
		busy.fx = "shimmer"
		note(busy)
	elseif snap then
		note(ui.span("updated " .. os.date("%H:%M", snap.fetched), "muted"))
	end
	if state.listing > 0 then
		local busy: any = ui.span("Loading repositories…", "muted")
		busy.fx = "shimmer"
		note(busy)
	end
	if problem and snap then
		note(ui.span((headOf(state, problem.kind) or "Plotroom") .. ", showing the last results", "warning"))
	end
	if snap and not snap.complete then
		note(ui.span("Partial results: narrow this view", "warning"))
	end
	for _, id in { "prs", "issues" } do
		local locked = state.locked[id]
		if locked then
			note(ui.span(locked, "error"))
		end
	end

	-- Views of several integrations are grouped in the sidebar by integration, the pull request and issue views of one
	-- together; so are views that run as several logins (a view of several is one entry in each login's group).
	local scopeList = orderedViews(state)
	local seen: { [string]: boolean } = {}
	local integrations = 0
	local grouped = false
	for _, scope in scopeList do
		if not seen[scope.view.integration] then
			seen[scope.view.integration] = true
			integrations += 1
		end
		grouped = grouped or #scope.view.logins > 1
	end
	grouped = grouped or integrations > 1
	local scopes: { any } = {}
	local activeScope: string? = nil
	for _, scope in scopeList do
		local v = scope.view
		local cached = state.snaps[snapKey(v, scope.login)]
		if ghActive.isActive(state, scope) then
			activeScope = scope.id
		end
		table.insert(scopes, {
			id = scope.id,
			label = v.name,
			icon = KINDS[v.kind].icon,
			count = if cached then #cached.items else nil,
			group = if grouped then INTEGRATIONS[v.integration].label .. (if scope.shown ~= "" then " - " .. scope.shown else "") else nil,
		})
	end

	local wait = waitOf(state)
	local map = keys.load()
	local acts: { Action } = if item then itemActions(state, item, open) else {}
	-- Settings and Refresh on the left;
	-- the selected item's buttons on the right, Open last in the corner.
	local actions: { any } = {
		{ id = "settings", label = "Settings", keys = keys.caps(map, "settings") },
		{
			id = "retry",
			label = "Refresh",
			keys = keys.caps(map, "refresh"),
			disabled = if wait > 0 then "Paused by GitHub until " .. os.date("%H:%M:%S", os.time() + wait) else nil,
		},
	}
	for _, a in acts do
		if not a.primary then
			table.insert(actions, { id = a.id, label = a.label, keys = a.keys, ["end"] = true })
		end
	end
	for _, a in acts do
		if a.primary then
			table.insert(actions, { id = a.id, label = a.label, keys = a.keys, primary = true })
		end
	end

	-- Neither integration is on: the setup pages in Settings are all there is.
	local none = cli.ready() and not cli.on("github") and not cli.on("jira")

	local props: { [string]: any } = {
		key = "queue",
		-- plotroom.css narrows the queue by the Settings sheet's width (`.aside`), so the sheet sits beside it, not over it.
		role = "plotroom.queue" .. (if state.settings then ".aside" else ""),
		size = "screen",
		layout = "cards",
		preview = "side",
		icon = state.kind.icon,
		title = title,
		subtitle = if #subtitle > 0 then subtitle else nil,
		noun = state.kind.many,
		placeholder = "Filter the loaded " .. state.kind.many,
		-- Nothing loads until the CLIs answered.
		state = if not snap and problem then "error" elseif not snap and (view or not cli.ready()) then "loading" else "ready",
		empty = {
			ui.span(
				if view then "No " .. state.kind.many .. " match " .. view.name .. "."
					else (if none then "Neither gh nor acli is installed on this host. " else "No saved views yet. ")
						.. (if map.settings ~= "" then "Press " .. map.settings .. " to " else "Open Settings to ")
						.. (if none then "set one up." else "add one."),
				"muted"
			),
		},
		items = items,
		order = order,
		hits = if vis then vis.hits else nil,
		selected = if item then itemId(item) else nil,
		focus = state.focus,
		scopes = tern.json.array(scopes),
		scope = activeScope,
		columns = { { id = "comments", format = "text", priority = 50 } },
		actions = actions,
	}
	if state.query then
		local qp = input.props(state.query)
		props.query = qp.text
		props.cursor = if state.settings then nil else qp.cursor
	end
	if not snap and problem then
		props.message = spans(ui.span(headOf(state, problem.kind) or "Plotroom", "strong"), "  ", problem.message, "  ", ui.span(helpOf(state, problem.kind) or "", "muted"))
	end
	local preview = if state.kind.id == "issues" then issuePreview(state, item, open, acts) else previewNodes(state, item, open, acts)
	return ui.node("picker", props, preview)
end

local function queueView(state: State): BlockView
	local layer: { Node } = { queuePicker(state) }
	local removing = state.removing
	local note = if removing then state.notes[removing] else nil
	if removing and note then
		-- A worktree's removal, asked from its card: where it is, and a warning while a tab works in it.
		local facts: { { [string]: any } } = {}
		if note.path then
			table.insert(facts, { k = "Path", v = { ui.span(note.path, "code") } })
		end
		if note.branch then
			table.insert(facts, { k = "Branch", v = { ui.span(note.branch, "code") } })
		end
		local kids: { Node } = {
			ui.node("text", {
				key = "body",
				spans = {
					ui.span(
						"Its folder is deleted, then its branch unless that holds commits saved nowhere else. Git refuses while the worktree has uncommitted changes. Press d to remove it; Enter or Esc keeps it.",
						"muted"
					),
				},
			}),
			ui.node("kv", { key = "facts", items = facts }),
		}
		if openItems(state)[removing] then
			table.insert(kids, ui.node("text", { key = "tab", spans = { ui.span("A tab works in it and will be left in a folder that no longer exists.", "warning") } }))
		end
		table.insert(kids, ui.node("list", { key = "buttons" }, {
			ui.node("item", { key = "keep", label = "Keep", icon = "check", hint = { "enter" }, actions = { click = "cancel-remove" } }),
			ui.node("item", { key = "delete", label = "Remove", icon = "trash", tone = "error", hint = { "d" }, actions = { click = "confirm-remove" } }),
		}))
		table.insert(layer, ui.node("overlay", { key = "confirm", modal = true, size = "sm", head = "Remove worktree?" }, kids))
	elseif state.help then
		table.insert(layer, helpOverlay(state))
	end
	return { main = ui.col(rpcNodes(state)), layer = ui.col(layer) }
end

local function settingsView(state: State): BlockView
	local s = state.settings :: Settings
	local sections, extra = pageContent(state)
	local props: { [string]: any } = {
		key = "settings",
		title = "Plotroom",
		pages = tern.json.array(cli.pages()),
		page = s.page,
		sections = sections,
		focus = s.focus,
	}
	local e = s.edit
	if e and e.model.multi then
		-- A prompt's text: the multi-line editor in the page's editor card, as Tern draws no multi-line control.
		local p = input.props(e.model)
		local id = string.match(e.row, "^ptext:(.+)$")
		local pk, pid = kindAndId(id or "")
		local prompts = if pk then loadPrompts(pk) else nil
		local prompt = if prompts then promptById(prompts, pid) else nil
		local err = s.errors[e.row]
		local kids: { Node } = {
			ui.node("text", {
				key = "head",
				spans = { ui.span("Prompt · " .. (if prompt then prompt.name else ""), "strong") },
			}),
			ui.node("editor", {
				key = "draft",
				text = p.text,
				cursor = p.cursor,
				anchor = p.anchor,
				placeholder = "Review {url}: …",
				maxLines = 16,
				min = { h = "6lines" },
				aria = "Prompt text",
			}),
			ui.node("section", { key = "vars", head = { ui.span("Variables", "muted") }, collapsible = true, collapsed = true }, {
				ui.node("kv", { key = "list", items = (pk or state.kind).vars }),
			}),
		}
		if err then
			table.insert(kids, ui.node("text", { key = "error", spans = { ui.span(err, "error") } }))
		end
		table.insert(
			kids,
			ui.node("row", { key = "buttons", role = "omp.actions" }, {
				ui.node("row", { key = "save", role = "omp.btn", tone = "accent", gap = "xs", align = "center", actions = { click = "save-prompt" } }, {
					ui.node("icon", { key = "i", name = "save" }),
					ui.text({ ui.span("Save") }),
				}),
				ui.node("row", { key = "cancel", role = "omp.btn", gap = "xs", align = "center", actions = { click = "cancel-prompt" } }, {
					ui.node("icon", { key = "i", name = "x" }),
					ui.text({ ui.span("Cancel") }),
				}),
			})
		)
		table.insert(extra, ui.node("col", { key = "prompt", role = "omp.prefs.editor", gap = "md" }, kids))
	elseif e then
		local p = input.props(e.model)
		props.editing = { row = e.row, draft = p.text, cursor = p.cursor }
	elseif s.pick then
		props.editing = { row = s.pick.row, option = s.pick.option }
	end
	-- In the layer, prefs is Tern's side sheet docked at the right, over the queue.
	local layer: { Node } = { queuePicker(state), ui.node("prefs", props, extra) }
	if state.help then
		table.insert(layer, helpOverlay(state))
	end
	return { main = ui.col(rpcNodes(state)), layer = ui.col(layer) }
end

-- A pane moved into or out of a PR worktree, or ended: redraw every queue so "In tab" marks follow. Deferred, since
-- the host's pane list still holds an exiting pane while its event runs (observed: an undeferred redraw kept the mark).
local function redrawQueues()
	tern.timer(250, function()
		for _, s in running do
			if alive(s) then
				s.cx:render()
			end
		end
	end)
end
tern.on("cwd", function(_ev: any, _cx: any)
	redrawQueues()
end)
tern.on("pane_exited", function(_ev: any, _cx: any)
	redrawQueues()
end)

-- ---------------------------------------------------------------- block

-- The block: one engine for pull request and issue views alike, each taking its search, details and wording from its kind.
local function blockDef(): BlockDef<State>
	-- Kept in here: the module is at Luau's 200-local limit.
	-- The pinned scope of the pull request at `url` (untrusted: anything but a canonical PR URL is nil). Its name is
	-- "owner/name#N"; lowercased, that is the PR's key. Its id is no saved view's (theirs are "<kind>:v<n>").
	local function pinView(url: any): View?
		local o, r, n = github.parsePrUrl(url)
		if not o or not r or not n then
			return nil
		end
		return { id = "pin", kind = "prs", name = o .. "/" .. r .. "#" .. n, integration = "github", query = url, logins = {}, group = "none", prompts = {} }
	end
	-- The window shows the pull request at `url` (an issue's linked PR) in this block, whichever view is active: selected
	-- in the active scope when that lists pull requests and has this one, else in the pinned scope, which replaces any
	-- earlier pin and is a pull request one, so the active kind follows it. The other views stay in the sidebar to go back to.
	-- ponytail: the pin runs as gh's active login; pass the issue view's login along if a private repository needs another.
	local function showPr(state: State, url: any)
		local pin = pinView(url)
		if not pin then
			return
		end
		local key = string.lower(pin.name)
		discardEdit(state)
		state.settings, state.help, state.query, state.focus = nil, false, nil, "list"
		local snap = state.snap
		if not snap or snap.kind ~= "prs" or indexOf(snap.items, key) == 0 then
			state.pin = pin
			switchView(state, pin.id)
		end
		state.cursor = key
	end
	-- The button `id` of the selected item (itemActions' ids): opens its link, as the button's key does.
	local function openAction(state: State, id: string)
		local chosen = selected(state)
		local acts: { Action } = if chosen then itemActions(state, chosen, openItems(state)) else {}
		for _, a in acts do
			if a.id == id then
				state.cx:open(a.href)
			end
		end
	end
	-- One line for the badges' tooltip on where the worktree of `note` stands (`item`: the listed item it is of); nil
	-- when that cannot be said: its head is unread, or a pull request's head is unknown.
	local function summaryOf(issues: boolean, note: Note, item: any): string?
		local head = note.head
		if not head then
			return nil
		elseif issues then
			return worktree.describeIssue({ created = false, branch = note.branch or "", head = head, dirty = note.dirty })
		end
		local prHead = if item then item.headSha else nil
		if not prHead then
			return nil
		end
		return worktree.describe({ created = false, head = head, prHead = prHead, prRef = item.head, dirty = note.dirty })
	end
	-- Brings the notes into line with what the scans read, `scans[1..count]` (a failed scan is absent): the note of a
	-- worktree that is listed follows its head; a listed worktree of a listed item with no note of it, or only a note of
	-- another worktree, gets one (root, path, branch, ref and, for a pull request, whether it is at the head the last
	-- refresh saw; `dirty` is unread); the ok note of a worktree its checkout no longer lists goes. A report of a worktree
	-- attempt stands until a later scan confirms it: the refresh's head may predate it. A failed attempt's note stays as
	-- it is: it answers the last Worktree press, and it names no worktree to ask git about. true when anything changed.
	-- ponytail: `current` follows the head the last refresh saw, so a pull request pushed since then reads as it was until
	-- the next refresh; a card that must be exact needs the PR read again.
	local function applyScans(state: State, scans: { [number]: worktree.Scan? }, count: number, scanned: string): boolean
		local listed: { [string]: any } = {} -- every item of the scanned kind's lists by key: its freshest listing
		for _, snap in state.snaps do
			if snap.kind == scanned then
				for _, item in snap.items do
					local seen = listed[item.key]
					if not seen or item.updated > seen.updated then
						listed[item.key] = item
					end
				end
			end
		end
		local lists: { [string]: { [string]: worktree.Found } } = {} -- main worktree -> what git lists there
		local pick: { [string]: worktree.Found } = {} -- one worktree per item: the one its note is about, else the first
		for i = 1, count do
			local scan = scans[i]
			if scan then
				lists[scan.root] = scan.found
				for key, f in scan.found do
					local note = state.notes[key]
					if pick[key] == nil or (note ~= nil and note.path == f.path) then
						pick[key] = f
					end
				end
			end
		end
		local changed = false
		for key, note in state.notes do
			local at = if note.ok and note.root then lists[note.root] else nil
			if at and at[key] == nil then
				state.notes[key] = nil
				changed = true
			end
		end
		local now = os.time()
		for key, f in pick do
			local item = listed[key]
			local note = state.notes[key]
			-- A worktree is of the kind its note says; one with no note yet is of an item of the scanned list.
			local kind = if note then note.kind else scanned
			local issues = kind == "issues"
			local sha: string? = if item and not issues then item.headSha else nil
			if note and note.ok and note.path == f.path then
				local current = if sha then f.head == sha else note.current
				local moved = note.git == true and (f.head ~= note.head or current ~= note.current)
				note.git, note.head, note.at = true, f.head, now
				if moved then
					note.current = current
					if current then
						note.update = {}
					elseif sha then
						note.update = worktree.update({ path = f.path, head = f.head, prHead = sha })
					end
					note.summary = summaryOf(issues, note, item) or note.summary
					changed = true
				end
			elseif item and (not note or note.ok) then
				local current = if sha then f.head == sha else true
				local fresh: Note = {
					seq = state.noteSeq + 1,
					kind = kind,
					at = now,
					ok = true,
					current = current,
					dirty = nil,
					root = f.root,
					path = f.path,
					branch = f.branch,
					ref = f.ref,
					summary = nil,
					message = nil,
					refused = nil,
					update = if not current and sha then worktree.update({ path = f.path, head = f.head, prHead = sha }) else {},
					git = true,
					head = f.head,
					checked = nil,
					checking = nil,
				}
				fresh.summary = summaryOf(issues, fresh, item)
				state.notes[key] = fresh
				changed = true
			end
		end
		return changed
	end
	-- Scans the checkouts of the shown items (a pull request's repository, an issue's, a Jira project's repositories:
	-- the saved checkout of each) with one `worktree list` apiece and applies what they read. Idempotent, as every render
	-- asks: it runs for a snapshot it has not scanned yet, or when `state.scanned` was reset (a worktree attempt, a
	-- removal, a checkout saved), one at a time. A scan that failed changes nothing, and so does one that a note changed
	-- under: it may predate that attempt or removal, so it is dropped and made again.
	local scanWorktrees: (State) -> ()
	scanWorktrees = function(state: State)
		local snap = state.snap
		if not snap or state.scanning or state.scanned == snap or not alive(state) then
			return
		end
		state.scanned = snap
		local issues = snap.kind == "issues"
		local paths: { string } = {}
		local wants: { [string]: { [string]: worktree.Want } } = {} -- checkout -> item key -> how its worktree is known
		local saved = readCheckouts() -- one read, not one per repository
		for _, item in snap.items do
			local codes: { string } = if issues and item.tracker == "jira" then jiraReposOf(item.repo) else { item.repo }
			for _, code in codes do
				local path = saved[string.lower(code)]
				if type(path) == "string" and path ~= "" then
					if not wants[path] then
						wants[path] = {}
						table.insert(paths, path)
					end
					wants[path][item.key] = formats.want(state, snap.kind, item, { code })
				end
			end
		end
		if #paths == 0 then
			return
		end
		-- A noted worktree is still known by what it was in its own checkout, though its item left the list or a format
		-- changed since.
		for key, note in state.notes do
			local root = note.root
			if note.ok and note.branch and note.path and root and wants[root] then
				local w = wants[root][key] or { branches = {}, dirs = {}, ref = note.ref }
				table.insert(w.branches, note.branch)
				table.insert(w.dirs, string.match(note.path, "([^/]+)/*$") or "")
				wants[root][key] = w
			end
		end
		state.scanning = true
		local rev = state.noteSeq
		local scans: { [number]: worktree.Scan? } = {}
		-- One checkout at a time: a list of many repositories must not start a git process for each at once.
		local function step(i: number)
			if i <= #paths and alive(state) then
				local once = false
				worktree.scan(paths[i], wants[paths[i]], function(scan)
					if not once then
						once = true
						scans[i] = scan -- nil for a scan that failed
						step(i + 1)
					end
				end)
				return
			end
			state.scanning = false
			if not alive(state) then
				return
			end
			if state.noteSeq ~= rev then
				state.scanned = nil
			elseif applyScans(state, scans, #paths, snap.kind) then
				state.noteSeq += 1
				state.cx:render()
			end
			scanWorktrees(state) -- the shown snapshot may have changed meanwhile
		end
		step(1)
	end
	-- Reads `git status` of the selected item's worktree once the cursor has rested on it (never one per row), and
	-- again after each refresh: the card's Clean / Uncommitted changes badge and the row's tone follow. Idempotent: every
	-- render asks.
	local function inspectSelected(state: State)
		local item = selected(state)
		local note = if item then state.notes[item.key] else nil
		local path = if note then note.path else nil
		if not item or not note or not note.ok or not path or note.checking or note.checked == state.round then
			return
		end
		local key, round = item.key, state.round
		note.checking = true
		tern.timer(DETAIL_DEBOUNCE_MS, function()
			local at = selected(state)
			if not alive(state) or state.notes[key] ~= note or not at or at.key ~= key then
				note.checking = nil
				return -- the cursor moved on or the note went: a render asks again if it still matters
			end
			worktree.dirty(path, function(dirty)
				note.checking = nil
				note.checked = round
				if not alive(state) or state.notes[key] ~= note or dirty == nil or dirty == note.dirty then
					return
				end
				note.dirty = dirty
				note.summary = summaryOf(note.kind == "issues", note, item) or note.summary
				state.noteSeq += 1
				state.cx:render()
			end)
		end)
	end
	-- The card's Remove worktree: asks first (a confirm overlay), and not while the worktree is being prepared or removed.
	local function askRemove(state: State)
		local chosen = selected(state)
		local note = if chosen then state.notes[chosen.key] else nil
		if not chosen or not note or not note.ok then
			return
		end
		if preparing[chosen.key] then
			return state.cx:toast("info", "Worktree is busy", "Plotroom is still working on it; try again in a moment.")
		end
		state.removing = chosen.key
	end
	-- Removes the worktree whose removal was confirmed, on this host where git runs (never in a window). A removal drops
	-- the note in every block of this host, and the row's Worktree badge with it; a refusal keeps the note, with the
	-- reason on its card. Either way the next render scans the checkouts again, so git has the last word.
	local function removeNow(state: State)
		local key = state.removing
		state.removing = nil
		local note = if key then state.notes[key] else nil
		if not key or not note or not note.ok then
			return
		end
		local root, path, branch = note.root, note.path, note.branch
		if not root or not path or not branch then
			return
		end
		if preparing[key] then
			return state.cx:toast("info", "Worktree is busy", "Plotroom is still working on it; try again in a moment.")
		end
		preparing[key] = true
		state.cx:toast("info", "Removing the worktree of " .. key .. "…")
		worktree.remove({ root = root, path = path, branch = branch, ref = note.ref }, function(removal, why, dirty)
			preparing[key] = nil
			if not alive(state) then
				return
			end
			if removal then
				for _, s in running do
					if s.notes[key] then
						s.notes[key] = nil
						s.noteSeq += 1
						s.scanned = nil
						if s ~= state and alive(s) then
							s.cx:render()
						end
					end
				end
				state.cx:toast("success", "Worktree removed", removal.branch)
			else
				note.refused = why
				if dirty then
					note.dirty = true
				end
				state.cx:toast("error", "Worktree not removed", why)
			end
			state.noteSeq += 1 -- the picker's cached rows carry the Worktree badge
			state.scanned = nil
			state.cx:render()
		end)
	end
	return {
		init = function(cx: BlockCx, args: { string }, saved: any): State
			local cwd: string? = nil
			local from: { any } = { if isTable(saved) then saved.launchCwd else nil, args[1], cx.cwd }
			for _, c in from do
				if type(c) == "string" and c ~= "" and tern.fs.exists(c) then
					cwd = c
					break
				end
			end
			local previous = running[cx.pane]
			if previous and previous.launchCwd == cwd and alive(previous) then
				-- The runtime re-runs init on every settings reload (observed every 7-15 s).
				-- Keep the live state: a fresh one would restart the GitHub search each time, flashing the spinner/card.
				previous.cx = cx
				return previous
			end
			if previous then
				retire(previous)
			end
			-- State saved by another Plotroom version is ignored: a fresh start.
			local mine = isTable(saved) and saved.version == 2
			-- The saved view id is the view's own in its kv store (the pin's is "pin"); `activeKind` says which store: what
			-- the older PR block saved has none, and anything but "issues" is a pull request view.
			local active: string? = nil
			if mine and type(saved.activeViewId) == "string" then
				local own: string = saved.activeViewId
				active = if own == "pin" then own else (if saved.activeKind == "issues" then "issues" else "prs") .. ":" .. own
			end
			local sp: { kind: string, message: string }? = nil
			if mine and isTable(saved.pause) and saved.launchCwd == cwd then
				local k, m = saved.pause.kind, saved.pause.message
				if type(m) == "string" and (k == "auth" or k == "missing" or k == "not-found" or k == "invalid") then
					sp = { kind = k :: string, message = m }
				end
			end
			local state: State = {
				cx = cx,
				kind = KINDS.prs,
				launchCwd = cwd,
				activeId = active,
				views = {},
				locked = {},
				-- A block launched to show one pull request (window.luau's `showPr`) starts on it; a restored one keeps its pin.
				pin = pinView(if mine then saved.pin else args[2]),
				snaps = {},
				snap = nil,
				cursor = nil,
				focus = "list",
				inflight = nil,
				gen = 0,
				account = "",
				tracker = "github",
				applied = nil,
				claiming = nil,
				cost = COST_GUESS,
				interval = nil,
				nextAt = nil,
				problem = if sp then { kind = sp.kind, message = sp.message } else nil,
				timer = nil,
				query = nil,
				help = false,
				vis = nil,
				details = {},
				detailFail = {},
				detailBusy = {},
				detailAttempt = nil,
				round = 0,
				notes = {},
				descOpen = nil,
				removing = nil,
				noteSeq = 0,
				scanned = nil,
				scanning = false,
				settings = nil,
				replies = {},
				listing = 0,
			}
			loadAll(state)
			if state.pin and not mine then
				state.activeId, state.cursor = state.pin.id, string.lower(state.pin.name)
			elseif not activeView(state) and cli.ready() then
				state.activeId = if state.views[1] then state.views[1].id else nil
			end
			-- What the first scope runs as is the identity from the start, so a restored pause survives identify. A saved
			-- login the view no longer lists falls back to the view's first. Before the CLIs answered no view is listed: the
			-- restored one and its login are kept for when it is.
			local picked = if mine and type(saved.activeLogin) == "string" then saved.activeLogin else nil
			local first = activeView(state)
			state.activeLogin = picked
			if first then
				state.activeLogin = if #first.logins > 1 then accountOf(first, picked) else nil
				state.kind = KINDS[first.kind]
				state.account, state.tracker, state.applied = accountOf(first, state.activeLogin), first.integration, snapKey(first, state.activeLogin)
			end
			running[cx.pane] = state
			cli.probe() -- the first block of this runtime: its views are listed once the CLIs answer
			if cwd then
				-- Launching inside a checkout maps its repository to it, unless it has one already.
				worktree.currentRepository(cwd, function(found)
					if found and alive(state) and checkoutOf(found.id) == nil then
						saveCheckout(found.id, found.checkout)
						-- A checkout that is new may already hold worktrees, and the first refresh may have landed without it.
						state.scanned = nil
						scanWorktrees(state)
					end
				end)
			end
			ghActive.note(state)
			refresh(state)
			return state
		end,

		title = function(state: State): string?
			local snap = state.snap
			local v = activeView(state)
			return if v then "Plotroom · " .. v.name .. (if snap then " (" .. #snap.items .. ")" else "") else "Plotroom"
		end,

		view = function(state: State, _cx: BlockCx): BlockView
			scanWorktrees(state)
			inspectSelected(state)
			return if state.settings then settingsView(state) else queueView(state)
		end,

		key = function(state: State, key: Key, cx: BlockCx): boolean?
			local plain = not (key.ctrl or key.alt or key.meta)
			local name = key.name
			local k = key.text or name
			local s = state.settings
			if state.removing and not state.notes[state.removing] then
				state.removing = nil -- its note was evicted: nothing left to ask about
			end
			if state.removing and not s then
				-- Like a delete: Enter keeps the worktree, only a deliberate `d` or a click removes it.
				if name == "enter" or name == "escape" then
					state.removing = nil
				elseif plain and k == "d" then
					removeNow(state)
				else
					return false
				end
				return true
			end
			if state.help then
				if name == "escape" or name == "enter" or (plain and keys.action((keys.load()), k) == "help") then
					state.help = false
					return true
				end
				return false
			end
			if s then
				local e = s.edit
				if e and string.match(e.row, "^p?key:") then
					-- A shortcut row takes the next key as the shortcut: Backspace or Delete removes it, Esc or Enter keeps it.
					if name == "escape" or name == "enter" then
						discardEdit(state)
					elseif name == "backspace" or name == "delete" then
						e.model = input.new("")
						commitEdit(state)
					elseif plain and key.text and key.text ~= "" then
						-- Checked before commitEdit, which trims: a Space would otherwise save as no shortcut.
						local bad = keys.shape(key.text)
						if bad then
							s.errors[e.row] = bad
						else
							e.model = input.new(key.text)
							commitEdit(state)
						end
					end
					return true
				elseif e then
					if name == "escape" then
						discardEdit(state)
					elseif name == "enter" and (not e.model.multi or key.meta or key.ctrl) then
						commitEdit(state)
					elseif not input.key(e.model, key, function(t)
						cx:copy(t)
					end) then
						return false
					end
					return true
				end
				local pick = s.pick
				local pdef = if pick then rowById(state, pick.row) else nil
				if pick and pdef then
					local c = pdef.control
					-- A choice's menu runs down the sheet, chips across it.
					local vertical = c.k == "choice" and (name == "up" or name == "down")
					if name == "left" or name == "right" or vertical then
						local list: { any } = {}
						for _, o in c.options do
							table.insert(list, o.value)
						end
						local at = table.find(list, pick.option) or 0
						local back = name == "left" or name == "up"
						pick.option = list[math.clamp(at + (if back then -1 else 1), 1, math.max(#list, 1))]
						return true
					elseif (name == "enter" or name == "space") and pick.option then
						pressOption(state, pick.row, pick.option)
						return true
					elseif name == "escape" then
						s.pick = nil
						return true
					end
				end
				s.pick = nil -- any other key leaves the chips
				if name == "escape" then
					state.settings = nil
				elseif name == "tab" and plain then
					local pages = cli.pages()
					local at = 1
					for i, p in pages do
						if p.id == s.page then
							at = i
						end
					end
					showPage(state, s, pages[((at - 1 + (if key.shift then -1 else 1)) % #pages) + 1].id)
				elseif plain and keys.action((keys.load()), k) == "help" then
					state.help = true
				elseif name == "up" or name == "down" then
					local rows = focusRows(state)
					if #rows == 0 then
						return false
					end
					local at = if s.focus then table.find(rows, s.focus) else nil
					local down = name == "down"
					s.focus = rows[if at then math.clamp(at + (if down then 1 else -1), 1, #rows) elseif down then 1 else #rows]
				elseif name == "enter" or name == "space" then
					runRow(state, s.focus)
				else
					return false
				end
				return true
			end

			local searching = state.query ~= nil
			local scopes = state.focus == "scopes"
			-- The queue action the key is (Settings › Keyboard shortcuts). While searching it is text, and with ctrl, alt or meta it is no shortcut.
			local act = if plain and not searching then keys.action((keys.load()), k) else nil
			if name == "tab" and plain then
				state.focus = if scopes then "list" else "scopes"
			elseif name == "escape" then
				local q = state.query
				if q then
					state.query = if q.text ~= "" then input.new("") else nil
					ensureCursor(state)
				elseif scopes then
					state.focus = "list"
				else
					return false
				end
			elseif name == "up" or act == "up" then
				if scopes then
					moveView(state, -1)
				else
					moveCursor(state, -1)
				end
			elseif name == "down" or act == "down" then
				if scopes then
					moveView(state, 1)
				else
					moveCursor(state, 1)
				end
			elseif name == "page_up" or name == "page_down" then
				moveCursor(state, if name == "page_up" then -10 else 10)
			elseif not searching and (name == "home" or name == "end") then
				local d = if name == "home" then -100000 else 100000
				if scopes then
					moveView(state, d)
				else
					moveCursor(state, d)
				end
			elseif name == "enter" then
				if scopes then
					state.focus = "list"
				else
					openSelected(state, "open", false)
				end
			elseif state.query then
				local q = state.query
				local before = q.text
				if not input.key(q, key, function(t)
					cx:copy(t)
				end) then
					return false
				end
				if q.text ~= before then
					ensureCursor(state)
				end
			elseif act == "search" then
				state.query = input.new("")
			elseif act == "help" then
				state.help = true
			elseif act == "refresh" then
				retry(state)
			elseif act == "settings" then
				openSettings(state)
			elseif act == "worktree" then
				openSelected(state, "worktree", false)
			elseif act == "goto" then
				local chosen = selected(state)
				if not chosen or not openItems(state)[chosen.key] then
					return false
				end
				openSelected(state, "goto", false)
			elseif act == "agent" then
				openSelected(state, "agent", false)
			else
				-- A saved prompt's own key runs it, through its button's link (the window honours only links shown).
				local chosen = selected(state)
				local hit: Prompt? = nil
				local list: { { prompt: Prompt, here: boolean } } = if plain and chosen then offered(state) else {}
				for _, o in list do
					if o.prompt.key == k and string.match(o.prompt.id, "^%w+$") then
						hit = o.prompt
					end
				end
				if not chosen or not hit then
					return false
				end
				state.cx:open(runHrefOf(state, chosen, hit.id))
			end
			return true
		end,

		event = function(state: State, ev: UiEvent, _cx: BlockCx)
			if not alive(state) then
				return
			end
			local s = state.settings
			local act = if ev.ev == "action" and type(ev.act) == "string" then ev.act else nil
			local item = if type(ev.item) == "string" then ev.item else nil
			-- Ends the single-line edit in progress (none: true): saves it, drops an empty draft or a shortcut being captured,
			-- and is false when a refused draft stays open with its warning. The prompt editor card stays open.
			local function leaveEdit(s: Settings): boolean
				local e = s.edit
				if not e or e.model.multi then
					return true
				end
				local capture = string.match(e.row, "^p?key:") ~= nil
				if not capture then
					commitEdit(state)
				end
				if s.edit and not capture and trim(s.edit.model.text) ~= "" then
					return false
				end
				discardEdit(state)
				return true
			end
			if act == "retry-checks" then
				local chosen = selected(state)
				local key = if chosen then detailKey(state, chosen) else nil
				if key then
					state.detailFail[key] = nil
					cancelDetails(state)
				end
			elseif act == "rpc" then
				rpc(state, ev.value)
			elseif act == "show-pr" then
				showPr(state, ev.value)
			elseif act == "add-repo" and ev.id ~= SETTINGS_ID then
				addRepo(state, ev.value)
			elseif act == "add-jira" and ev.id ~= SETTINGS_ID then
				addJira(state, ev.value)
			elseif act == "fold-description" then
				state.descOpen = nil
			elseif ev.ev == "toggle" and ev.key == "description" then
				local chosen = selected(state)
				state.descOpen = if chosen and ev.collapsed == false then chosen.key else nil
			elseif act == "close-help" then
				state.help = false
			elseif act == "confirm-delete" or act == "cancel-delete" then
				-- The window palette's answer, acted on only for the row this block asked about.
				if s and s.confirm and s.confirm == ev.value then
					if act == "confirm-delete" then
						confirmDelete(state)
					else
						s.confirm = nil
					end
				end
			elseif act == "remove-worktree" then
				-- Its question is a modal over the queue, which Settings' sheet does not draw: Settings closes first.
				if s then
					discardEdit(state)
					state.settings = nil
				end
				askRemove(state)
			elseif act == "confirm-remove" then
				if state.removing then
					removeNow(state)
				end
			elseif act == "cancel-remove" then
				state.removing = nil
			elseif act == "goto" or act == "worktree" then
				-- The worktree card's rows and the action bar's buttons alike: a click in the preview carries the row's own id.
				openAction(state, act)
			elseif act == "save-prompt" or act == "cancel-prompt" then
				-- The editor card's buttons: their own ids, not the prefs node's.
				if s and act == "save-prompt" then
					commitEdit(state)
				elseif s then
					discardEdit(state)
				end
			elseif s and ev.id == SETTINGS_ID then
				-- A click on another row or button (a menu, a field, Done, Delete...) first saves the line being typed:
				-- a refused draft keeps its row open with the warning, an empty one (a new view's untouched name) is
				-- dropped, and so is a shortcut being captured. A menu option under the pointer ("<row>=<value>") is no
				-- click.
				local e = s.edit
				local target: string? = if ev.ev == "action" and act ~= "page" and act ~= "close" and type(ev.value) == "string"
					then ev.value
					elseif ev.ev ~= "action" and item and not string.find(item, "=", 1, true) then item
					else nil
				if e and target and target ~= e.row and not leaveEdit(s) then
					return
				end
				if act == "page" then
					for _, p in cli.pages() do
						if p.id == ev.value then
							showPage(state, s, p.id)
						end
					end
				elseif act == "close" then
					discardEdit(state)
					if ev.value == nil then
						state.settings = nil
					else
						s.pick = nil -- a click outside an open choice's menu, or away from a text being edited
					end
				elseif act == "add" or act == "add-prompt" or act == "restore-prompts" or act == "edit-prompt" or act == "delete" or act == "refresh" or act == "add-repo" or act == "add-jira" or act == "guide" or act == "expand" or act == "collapse" then
					if type(ev.value) == "string" then
						s.focus = ev.value
						runAction(state, act, ev.value)
					end
				elseif ev.ev == "activate" and item then
					runRow(state, item) -- a click on a text field or a choice's popup
				elseif ev.ev == "select" and item then
					-- The pointer on an open menu's option ("<row>=<value>") moves the keys' highlight there; a click on a row
					-- off its control focuses it.
					local menu, option = string.match(item, "^(.-)=(.*)$")
					if menu and s.pick and s.pick.row == menu then
						s.pick.option = option
					elseif not menu then
						s.focus, s.pick = item, nil
					end
				elseif ev.ev == "change" and item and (ev.value == nil or ev.value == tern.json.null) then
					resetRow(state, item)
				elseif ev.ev == "change" and item then
					s.focus = item
					if type(ev.value) == "string" then
						s.pick = nil -- a choice made closes its menu
					end
					setValue(state, item, ev.value)
				end
			elseif ev.id == QUEUE_ID then
				-- The queue beside Settings' sheet takes clicks too (its keys stay Settings'): one first ends the line
				-- being typed, as a click on another Settings row does.
				if s and s.edit then
					leaveEdit(s)
				end
				if ev.ev == "select" or ev.ev == "activate" then
					local picked = if item then itemOf(state, item) else nil
					if not picked then
						return -- a refresh replaced the snapshot
					end
					state.cursor, state.focus = picked.key, "list"
					if ev.ev == "activate" then
						openSelected(state, "open", true)
					end
				elseif act == "scope" then
					state.focus = "list"
					local scopeId = ev.value
					if type(scopeId) == "string" then
						for _, scope in orderedViews(state) do
							if scope.id == scopeId and not ghActive.isActive(state, scope) then
								switchView(state, scope.view.id, scope.login)
								break
							end
						end
					end
				elseif act == "clear" or act == "close" then
					state.query = nil
					ensureCursor(state)
				elseif act == "settings" then
					-- Settings' own button: opens Settings, or closes the sheet it sits beside.
					if s then
						discardEdit(state)
						state.settings = nil
					else
						openSettings(state)
					end
				elseif act == "retry" then
					retry(state)
				elseif act then
					-- An item's button in the action bar: open its link, as its key does.
					openAction(state, act)
				end
			end
		end,

		save = function(state: State): any
			local p = state.problem
			local pause: { kind: string, message: string }? = nil
			if p and TERMINAL[p.kind] then
				pause = { kind = p.kind, message = p.message }
			end
			-- The active view as its kv store has it: the saved id without the kind, and the kind only for an issue view (a
			-- save without one is a pull request view's, as the older PR block saved). Read from its id, as one restored
			-- before the CLIs answered is not listed yet.
			local kind, own = kindAndId(state.activeId or "")
			return {
				version = 2,
				launchCwd = state.launchCwd,
				activeViewId = if state.activeId then own else nil,
				activeKind = if kind == KINDS.issues then "issues" else nil,
				activeLogin = state.activeLogin,
				pause = pause,
				pin = if state.pin then state.pin.query else nil,
			}
		end,
	}
end

tern.block.define("prs", blockDef())
