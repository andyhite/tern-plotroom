--!strict
-- Plotroom host core: types, constants, kinds and groups, badges, Settings page defs, the `cli` table and pure text/href helpers.
local github = require("../github")
local input = require("../input")
local jira = require("../jira")
local tracker = require("../tracker")
local prompts = require("../prompts")

local ui = tern.ui

local M = {}

M.POLL_MS = 60 * 1000
M.COST_GUESS = 10
M.DETAIL_DEBOUNCE_MS = 300 -- the cursor must rest this long on an item before its checks load, or its worktree's changes are read
M.DETAIL_RETRY_S = 15 -- a failed checks load tries again after this long, doubling up to DETAIL_RETRY_MAX_S
M.DETAIL_RETRY_MAX_S = 300
M.NOTE_CAP = 20 -- worktree attempt reports kept per block; the worktrees git lists are all kept
M.COMMENT_ROWS = 36 -- the rows of a comment's text a confirmation shows: the window shows 40 (flows.luau MAX_ROWS), 3 are the target, account and count
M.ISSUE_ICON = "list-checks" -- the icon of issue views, as in window.luau; a name outside Tern's icon set (`circle-dot` is one) draws blank
-- How an issue view lists a tracker's issues (as a gh login; Jira ignores it) and loads one issue's details.
export type TrackerApi = {
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
M.TRACKERS = TRACKERS

-- A saved search: `kind` is what it lists ("prs" | "issues", a key of KINDS) and its `id` is "<kind>:<its id in that
-- kind's kv store>" (a pin's is "pin:<item key>", see engine.pinView), so ids are the block's own whichever store a view is in.
-- `integration` is the tracker it asks ("github" | "jira"), `logins` the gh logins a GitHub view runs
-- as (none: gh's active account; with several, the view is one sidebar scope under each login, running as it),
-- `group` how the list is grouped ("none" or a GROUPS value) and `prompts` the ids of the prompts offered under it, in
-- its kind's prompt store (none: every prompt).
export type View = { id: string, kind: string, name: string, integration: string, query: string, logins: { string }, group: string, prompts: { string }, sort: string? }
export type Views = { version: number, nextId: number, items: { View } }
-- An agent prompt from Settings › Prompts; the views list which of them they offer. `key` runs it on the selected
-- item from the queue. `worktree` (nil means true) says where it runs: in the item's worktree, or in the repository's
-- main checkout. `split` (nil means false) opens its agent as a block beside the queue in the queue's tab rather than
-- in a tab of its own. `model` (nil: omp's default) is what `omp --model` runs it with: a model pattern or a role
-- alias such as @slow. `next` (nil: none) is the id of another prompt of the kind that starts for the same item, in the same
-- tab and worktree, when this prompt's agent finishes. `carly` (nil means false) has Carly told when its agent finishes.
export type Prompt = { id: string, name: string, text: string, key: string?, worktree: boolean?, split: boolean?, model: string?, status: string?, next: string?, carly: boolean? }
export type Prompts = { version: number, nextId: number, items: { Prompt } }
-- A row of a `?` list: its fixed keys, then the configured key of each of its `actions` (Settings › Keyboard shortcuts; a removed
-- one adds none), and what they do. A row left with no key is not listed.
export type KeyHelp = { keys: { string }, actions: { string }?, text: string }
-- A default view; its id in the kv store is "v<its place in Kind.seeds>". `sprint`: offered only while the Jira site is
-- known to have sprints (cli.sprints).
export type Seed = { name: string, integration: string, query: string, group: string, sort: string?, sprint: boolean? }
-- What tells pull request views and issue views apart; the rest is one engine. The active view's is State.kind.
export type Kind = {
	id: string, -- "prs" | "issues": a View's and a Snap's `kind`, and the prefix of the ids of its views
	label: string, -- "Pull requests" | "Issues"
	one: string, -- "pull request" | "issue"
	many: string, -- "pull requests" | "issues"
	icon: string, -- the icon of its views in the sidebar, and the picker's
	viewsKey: string, -- kv key of the saved views
	promptsKey: string, -- kv key of the saved prompts
	integrations: { string }, -- the trackers its views may use, the first a new view's: "github" | "jira" (keys TRACKERS and INTEGRATIONS)
	seeds: { Seed }, -- the views of a first run and of Settings › Views › Restore defaults, in order
	keys: { KeyHelp }, -- the `?` list of the queue
	vars: { { k: { Span }, v: string } }, -- the prompt editor's legend of variables
	prompts: { { id: string, name: string, text: string, worktree: boolean? } }, -- offered until its saved prompts are first changed
}
-- `rows` caches the picker rows; `rowsRev` (worktree reports) and `rowsMin` (the minute, for the ages) say what built them.
export type Snap = {
	kind: string, -- what its items are: "prs" (github.Pr) or "issues" (tracker.Issue)
	items: { any },
	total: number,
	complete: boolean,
	fetched: number,
	rows: { any }?,
	rowsRev: number?,
	rowsMin: number?,
	rowsOpen: string?, -- the key that goes to a tab, then the ids of the items open in a tab, comma-joined
	need: number?, -- how many of its items need attention (set with `rows`)
}
-- What the local search lets through: computed once per snapshot and search text.
export type Visible = { snap: Snap, needle: string, group: string, rev: number, items: { any }, order: { any }, hits: { [string]: any }? }
-- One way to group a list: the view's `group` value, its label in Settings and the group an item falls in. `keep`: the
-- groups follow the list's order (GitHub state) instead of their labels'. `rank`: the groups go by their items' rank
-- (Jira status category), then by label.
export type Group = { value: string, label: string, of: (any) -> string, keep: boolean?, rank: ((any) -> number)? }
-- What each kind can group each integration's items by; assigned below, once the badges it reads are defined.
local GROUPS: { [string]: { [string]: { Group } } }
function M.groupsOf(kindId: string, integration: string): { Group }
	local list: { Group } = GROUPS[kindId][integration] or {}
	return list
end
-- `round` is the State.round it was loaded in: an older list is still shown while it loads again.
-- `about` is the PR's merge state, reviewers and description, nil when gh did not print them. `issue` is an issue's
-- body, milestone and linked pull requests (a PR's `runs` and `total` are then empty). `headPr` is the PR whose head is
-- the branch of the issue's worktree, `noted` the issue Plotroom noted for the PR's head branch's worktree; each nil
-- when there is none (or the lookup failed: it is best effort).
export type Detail = { runs: { github.Run }, total: number, round: number, about: github.About?, issue: tracker.IssueDetail?, headPr: github.HeadPr?, noted: tracker.Issue? }
-- A checks load that failed: why, how often, and when to try again (nil: only an explicit Retry).
export type DetailFail = { problem: github.Problem, tries: number, retryAt: number? }
-- The one checks load waiting out its debounce or retry delay. Its identity is the table: only the owner may clear it.
export type Attempt = { key: string, timer: TimerHandle? }
-- What the worktree card and the row's badge say of an item's worktree. Nothing is saved: git is the source, so a fresh
-- block (or one after a plugin reload) shows the worktrees that exist. Every scan of the listed items' checkouts (`git
-- worktree list`, after each refresh, Worktree attempt and removal) gives a worktree its `root`, `path`, `branch`, `ref`
-- (what removing it takes), `head` and, for a pull request, `current` (its head is the PR's head the last refresh saw)
-- and the `update` commands; it takes the note of a worktree git no longer lists. `dirty` is read with `git status`
-- for the selected item only: nil until then (`checked`: in which State.round; `checking`: that read is on its way). A
-- note also starts as the outcome of a Worktree attempt (a report, or why there is none), which the next scan confirms
-- (`git`). `refused` is why the last removal did not go through. `kind` is what the item is: a worktree is never read as
-- the other kind's (a note of a pull request has the head to compare, an issue's has none).
export type Note = {
	seq: number,
	kind: string, -- what its item is: "prs" or "issues"
	at: number,
	ok: boolean,
	current: boolean,
	dirty: boolean?,
	ahead: number?, -- commits its branch holds that its upstream lacks, read with `dirty`; nil without an upstream
	root: string?,
	repo: string?, -- the repository whose checkout `root` is: what `removeEntry` re-reads git's list for
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
export type Report = { root: string, repo: string, path: string, branch: string, ref: string?, current: boolean, dirty: boolean?, ahead: number?, summary: string, update: { string } }
export type Settings = {
	page: string, -- "views" | "prompts" | "keys" | "worktrees" | "repos" | "jira" | "connection"
	focus: string?, -- focused prefs row id
	open: string?, -- the item whose form is expanded: a view or prompt ("<kind id>:<saved id>"), a repository or a Jira project key; every other one shows as a one-row summary
	edit: { row: string, model: input.Model }?, -- text row being edited; a multi-line model is a prompt's text; a shortcut row ("key:", "pkey:") takes the next key
	pick: { row: string, option: string? }?, -- a choice or chips row the keys drive, `option` highlighted
	errors: { [string]: string? }, -- row id -> warning under the row
	confirm: string?, -- delete row ("delete:<view id>", "pdelete:<prompt id>", "rremove:<repo>" or "jremove:<key>") awaiting confirmation; view and prompt ids are qualified by their kind
}

-- What the window recorded about an agent when it started it: the action's name, the worktree's branch, the item's title.
export type AgentInfo = { action: string?, branch: string?, title: string?, last: string?, err: string?, result: string?, ended: string? }

-- The Inbox list's model: the notifications gh's active login was last read to have (`login`: whose), why they could not be
-- read (`problem`), whether a read is running and whether one has answered.
export type Inbox = { login: string?, rows: { github.Notice }, problem: github.Problem?, busy: boolean, loaded: boolean, gen: number } -- gen: bumped by Mark read, so a read that began before it is ignored

export type State = {
	cx: BlockCx,
	kind: Kind, -- the active view's, as identify keeps it (a block with no view keeps its last)
	launchCwd: string?,
	activeId: string?,
	activeLogin: string?, -- the gh login of the active scope when the view lists several: each login is its own scope in the sidebar (nil: the first)
	views: { View }, -- every saved view of both kinds, pull request views first (kv views-prs, then views-issues)
	pins: { View }, -- items pinned by URL (requests.show), each a one-item scope under the sidebar's Pins group, in the order pinned; never saved with the views
	locked: { [string]: string }, -- kind id -> why its saved views cannot be changed (unreadable, malformed, unwritable); absent: they can
	snaps: { [string]: Snap },
	snap: Snap?,
	cursor: string?,
	cursorAt: number?, -- the cursor's place in the list: a vanished item hands the selection to the row that took its place
	focus: string, -- the picker part the keys drive: "list" | "scopes"
	inflight: number?, -- generation of the search request that owns the spinner
	gen: number,
	account: string, -- the gh login ("" = the active gh account) the data and requests belong to
	tracker: string, -- the integration the data and requests belong to
	applied: string?, -- the snapshot key (snapKey) the shown snapshot belongs to
	cost: number,
	interval: number?,
	nextAt: number?,
	problem: github.Problem?,
	problemBy: string?, -- the integration that raised `problem`: it labels it, whatever view is shown
	problemAccount: string?, -- the account that raised it; nil on a restored pause until the first identify adopts one
	restoredId: string?, -- the view id the block was restored on, until its first listing (changed)
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
	removeFate: string?, -- what removal does to that worktree's branch, as git lists it now; nil while it is read
	removeRefusal: string?, -- why that removal will be refused (no repository, git no longer lists it, git failed); nil: none known
	noteSeq: number, -- moves whenever a note changes: the picker's cached rows carry the Worktree badges
	scanned: Snap?, -- the snapshot whose checkouts the last scan was started for; nil: a scan is due (a worktree was made or removed)
	scanning: boolean, -- a scan of the shown items' checkouts is running
	settings: Settings?,
	settingsPage: string?, -- the Settings page last shown: Settings opens on it again
	replies: { { id: string, text: string } }, -- answers to window requests, oldest first
	listing: number, -- repository picker lists still waiting on GitHub: the heading shows a loader meanwhile
	rev: number, -- moves whenever triage, sort or the attention filter changes: the visible list and the picker rows carry it
	triage: any, -- the personal seen / snooze store (triage.Store) as last read; nil until read or while its kv is unreadable (`triageProblem`)
	triageProblem: string?,
	showSnoozed: boolean, -- snoozed items are listed (marked) instead of hidden
	attention: boolean, -- only items that need attention are listed: unseen or changed ones, and those whose agent waits for input
	seenTried: string?, -- "<item key>\0<signature>" an automatic mark-seen was last tried for (a failed save is not retried until the item changes)
	agents: { [string]: string }, -- item key -> its agent's state as the window last reported it (working | waiting_input | idle | exited)
	agentInfo: { [string]: AgentInfo }, -- item key -> what the window recorded about its agent (an old link has none)
	agentsOn: boolean, -- the Agents scope is shown instead of a view
	agentAt: string?, -- the item key of the Agents row previewed
	inboxOn: boolean, -- the Inbox list is shown instead of a view
	inboxAt: string?, -- the thread id of the Inbox row previewed
	inbox: Inbox,
	plan: any, -- the one mutation plan waiting for the window's confirmation (requests.offer), nil: none
	draft: any, -- the guided pull request draft in progress (host-side preview of the last `draft` request), nil: none
	imported: any, -- the parsed import waiting for its choices, nil: none
	exported: any, -- the export snapshot waiting for its commit (token, json, count, notes), nil: none
	board: any, -- the Worktrees board's model (board.Board)
	boardOn: boolean, -- the Worktrees scope is shown instead of a view
	boardTimer: TimerHandle?, -- the next automatic read of the board's worktree changes, while the board is shown
	boardWait: boolean?, -- the next preview read of a picked worktree waits out DETAIL_DEBOUNCE_MS, so scrolling does not read every row
	boardRemoving: string?, -- the board row whose removal is being confirmed
	boardFinished: { string }?, -- the board rows whose removal is being confirmed together (Remove finished worktrees)
	boardBusy: boolean, -- an inventory, a changes read, a cleanup check or a removal is running
	boardAt: number?, -- the previewed row's place in the list: a removed row hands the preview to the row that took its place
}

M.running = {} :: { [number]: State }

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
	claims = {} :: { [string]: true }, -- lowercase repositories whose checkout folder is being verified or cloned into, in any pane
	moved = false, -- an answer of the probes running differs from the one before
	-- Whether the Jira site has sprints (jira.sprints, asked each time acli is found to start); nil while unknown.
	sprints = nil :: boolean?,
	sprintsAsking = false,
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
M.cli = cli

-- A span list for a node prop; spans and plain strings may mix.
function M.spans(...: Span | string): { Span | string }
	return { ... }
end

-- Percent-encodes everything but unreserved URL characters.
function M.pct(s: string): string
	return (string.gsub(s, "[^%w%-_%.~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

-- Made when the host starts and carried by every action link the block renders for the window, so the window's
-- exact-href check refuses a plotroom:// link typed into a description. Never rendered, toasted or stored.
-- ponytail: math.random, seeded by Luau from the clock and an address; a stronger source if Tern ever offers one.
M.TOKEN = string.format("%06x%06x%06x%06x", math.random(0, 0xFFFFFF), math.random(0, 0xFFFFFF), math.random(0, 0xFFFFFF), math.random(0, 0xFFFFFF))

-- `href` with the host's token (the window strips `?k=<token>` before parsing, and compares the whole link).
function M.withToken(href: string): string
	return href .. "?k=" .. M.TOKEN
end

-- The link of action `act` (open | worktree | goto | agent) on `item`: a pull request's carries its repository and
-- number; an issue's open carries the percent-encoded URL (the window compares it with the one shown), the others the
-- repository and the issue's ref.
function M.hrefOf(state: State, item: any, act: string): string
	if state.kind.id == "issues" then
		if act == "open" then
			return M.withToken("plotroom://issue/open/" .. M.pct(item.url))
		end
		return M.withToken("plotroom://issue/" .. act .. "/" .. item.repo .. "/" .. item.ref)
	end
	return M.withToken("plotroom://github/" .. act .. "/" .. item.repo .. "/" .. item.number)
end

-- The link of the button that runs saved prompt `id` (letters and digits) on `item`: the prompt's shortcut opens it.
function M.runHrefOf(state: State, item: any, id: string): string
	if state.kind.id == "issues" then
		return M.withToken("plotroom://issue/run/" .. item.repo .. "/" .. item.ref .. "/" .. id)
	end
	return M.withToken("plotroom://github/run/" .. item.repo .. "/" .. item.number .. "/" .. id)
end

-- "45s", "3m 20s", "1h 5m" for a whole number of seconds.
function M.duration(s: number): string
	s = math.max(0, math.ceil(s))
	if s < 60 then
		return s .. "s"
	elseif s < 3600 then
		return (s // 60) .. "m" .. (if s % 60 > 0 then " " .. s % 60 .. "s" else "")
	end
	return (s // 3600) .. "h" .. (if s % 3600 >= 60 then " " .. (s % 3600) // 60 .. "m" else "")
end

-- `s` with control characters as spaces and, when it is not valid UTF-8, every non-ASCII byte as "?".
function M.printable(s: string): string
	local out = string.gsub(s, "%c", " ")
	if utf8.len(out) == nil then
		out = string.gsub(out, "[\128-\255]", "?")
	end
	return out
end

-- `s` (valid UTF-8, see printable) cut to `max` characters.
function M.clip(s: string, max: number): string
	local cut = utf8.offset(s, max + 1)
	return if cut and cut <= #s then string.sub(s, 1, cut - 1) .. "…" else s
end

-- The first line of `s`, cut to 160 characters.
function M.brief(s: string): string
	return M.clip(M.printable(string.match(s, "[^\n]*") or ""), 160)
end

M.QUEUE_ID = "layer.queue"
M.SETTINGS_ID = "layer.settings"
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

-- What each integration is called, what a new view of it starts as, what its query row is labelled, and the heading of
-- an issue's linked items.
export type Integration = { label: string, newQuery: string, query: string, linked: string }
M.INTEGRATIONS = {
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
} :: { [string]: Integration }

M.STATE_BADGE = {
	open = { text = "Open", tone = "success" },
	draft = { text = "Draft", tone = "muted" },
	merged = { text = "Merged", tone = "accent" },
	closed = { text = "Closed", tone = "error" },
	done = { text = "Done", tone = "success" },
} :: { [string]: { text: string, tone: string } }
-- Why a closed issue closed; any other reason (or none) is a plain Closed.
local CLOSED_REASON: { [string]: { text: string, tone: string } } = {
	completed = { text = "Completed", tone = "accent" },
	["not-planned"] = { text = "Not planned", tone = "muted" },
	duplicate = { text = "Duplicate", tone = "muted" },
}
M.REVIEW_BADGE = {
	approved = { text = "Approved", tone = "success" },
	changes = { text = "Changes requested", tone = "error" },
	required = { text = "Review required", tone = "warning" },
} :: { [string]: { text: string, tone: string } }
M.RUN_TONE = { success = "success", failure = "error", pending = "warning", neutral = "muted" } :: { [string]: string }
M.RUN_ICON = { success = "check", failure = "x", pending = "clock", neutral = "minus" } :: { [string]: string }
M.MERGE_STATE = {
	conflicts = { text = "Conflicts", tone = "error" },
	behind = { text = "Behind base", tone = "warning" },
	blocked = { text = "Blocked", tone = "warning" },
	unstable = { text = "Checks failing", tone = "warning" },
	ready = { text = "Ready", tone = "success" },
	draft = { text = "Draft", tone = "muted" },
	unknown = { text = "Checking…", tone = "muted" },
} :: { [string]: { text: string, tone: string } }
M.VERDICT_ROW = {
	approved = { text = "Approved", tone = "success", icon = "check" },
	changes = { text = "Changes requested", tone = "error", icon = "x" },
	commented = { text = "Commented", tone = "muted", icon = "message" },
	dismissed = { text = "Dismissed", tone = "muted", icon = "slash" },
	requested = { text = "Requested", tone = "warning", icon = "clock" },
} :: { [string]: { text: string, tone: string, icon: string } }
M.CHECK = {
	success = { text = "Passing", tone = "success", mark = "✓" },
	failure = { text = "Failing", tone = "error", mark = "✗" },
	pending = { text = "Pending", tone = "warning", mark = "●" },
} :: { [string]: { text: string, tone: string, mark: string } }

-- The two kinds of view the engine runs. `keys` is the `?` list of the queue (every shortcut of the kind, concise);
-- `vars` the prompt editor's legend of the variables a prompt may use.
local KINDS: { [string]: Kind } = {
	prs = {
		id = "prs",
		label = "Pull requests",
		one = "pull request",
		many = "pull requests",
		icon = "merge",
		viewsKey = "views-prs",
		promptsKey = "prompts-prs",
		integrations = { "github" },
		-- archived:false: an archived repository's open items can never be acted on. Review requested is direct requests
		-- only (review-requested also matches every team a login is on); Reviewed by me holds the PRs a review took
		-- out of the requests, until GitHub asks again.
		seeds = {
			{ name = "My PRs", integration = "github", query = "is:open author:@me archived:false", group = "repo" },
			{ name = "Review requested", integration = "github", query = "is:open user-review-requested:@me draft:false archived:false", group = "none", sort = "oldest" },
			{ name = "Team reviews", integration = "github", query = "is:open team-review-requested-user:@me draft:false archived:false", group = "repo" },
			{ name = "Reviewed by me", integration = "github", query = "is:open reviewed-by:@me -author:@me -review-requested:@me archived:false", group = "repo" },
		},
		keys = {
			{ keys = { "↑", "↓" }, actions = { "down", "up" }, text = "Move through the pull requests (Page Up/Down jump ten, Home/End the ends)" },
			{ keys = { "Enter" }, text = "Open the selected pull request in a Browser block beside this one" },
			{ keys = {}, actions = { "worktree" }, text = "Check it out in a worktree and open that in a new tab (Plotroom asks for the repository's checkout the first time)" },
			{ keys = {}, actions = { "goto" }, text = "Go to the tab working in the selected pull request's worktree" },
			{ keys = {}, actions = { "agent" }, text = "Pick a saved action, or type a prompt, and run it on the selected pull request in its worktree" },
			{ keys = {}, actions = { "agentgo" }, text = "Go to the selected pull request's agent, its exact pane (its badge says whether it works, waits for input, is idle or exited)" },
			{ keys = {}, actions = { "seen" }, text = "Mark the selected pull request seen (opening its preview does it too): New and Changed show until then" },
			{ keys = {}, actions = { "snooze" }, text = "Snooze the selected pull request until tomorrow morning" },
			{ keys = {}, actions = { "snoozed" }, text = "Show or hide snoozed pull requests" },
			{ keys = {}, actions = { "attention" }, text = "List only pull requests that need attention: unseen or changed, or whose agent waits for input" },
			{ keys = {}, actions = { "sort" }, text = "Switch this view to its next sort order (saved with the view)" },
			{ keys = {}, actions = { "more" }, text = "Command palette: every action above, saved actions or a typed prompt, rerun failed checks, guided draft pull request, export and import, open by URL" },
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
		prompts = prompts.prs,
	},
	issues = {
		id = "issues",
		label = "Issues",
		one = "issue",
		many = "issues",
		icon = M.ISSUE_ICON,
		viewsKey = "views-issues",
		promptsKey = "prompts-issues",
		integrations = { "github", "jira" },
		-- Jira: hierarchyLevel < 1 keeps epics (level 1, whatever the site calls them) out of all but My epics, and works
		-- on a site without an Epic type, where `issuetype != Epic` does not parse. Sprint views need a Sprint field.
		seeds = {
			{ name = "Assigned to me", integration = "github", query = "is:open assignee:@me archived:false", group = "repo" },
			{ name = "Created by me", integration = "github", query = "is:open author:@me -assignee:@me archived:false", group = "repo" },
			{ name = "My sprint", integration = "jira", query = "assignee = currentUser() AND sprint in openSprints() AND statusCategory != Done AND hierarchyLevel < 1", group = "status", sprint = true },
			{ name = "Up next", integration = "jira", query = 'assignee = currentUser() AND sprint in openSprints() AND statusCategory = "To Do" AND hierarchyLevel < 1', group = "none", sprint = true },
			{ name = "In progress", integration = "jira", query = 'assignee = currentUser() AND sprint in openSprints() AND statusCategory = "In Progress" AND hierarchyLevel < 1', group = "status", sprint = true },
			{ name = "Up for grabs", integration = "jira", query = 'assignee is EMPTY AND sprint in openSprints() AND statusCategory = "To Do" AND hierarchyLevel < 1', group = "none", sprint = true },
			{ name = "Assigned to me", integration = "jira", query = "assignee = currentUser() AND statusCategory != Done AND hierarchyLevel < 1", group = "status" },
			{ name = "My epics", integration = "jira", query = "assignee = currentUser() AND hierarchyLevel = 1 AND statusCategory != Done", group = "status" },
			{ name = "Created by me", integration = "jira", query = "reporter = currentUser() AND (assignee is EMPTY OR assignee != currentUser()) AND statusCategory != Done AND hierarchyLevel < 1", group = "assignee" },
		},
		keys = {
			{ keys = { "↑", "↓" }, actions = { "down", "up" }, text = "Move through the issues (Page Up/Down jump ten, Home/End the ends)" },
			{ keys = { "Enter" }, text = "Open the selected issue in a Browser block beside this one" },
			{ keys = {}, actions = { "worktree" }, text = "Create or reuse the selected issue's worktree and open it in a new tab: on its linked pull request's branch (Plotroom asks which when several have one), else on a new branch from the base you pick (Plotroom asks for the repository, and its checkout, the first time)" },
			{ keys = {}, actions = { "goto" }, text = "Go to the tab working in the selected issue's worktree" },
			{ keys = {}, actions = { "agent" }, text = "Pick a saved action, or type a prompt, and run it on the selected issue (typed prompts run in its worktree)" },
			{ keys = {}, actions = { "agentgo" }, text = "Go to the selected issue's agent, its exact pane (its badge says whether it works, waits for input, is idle or exited)" },
			{ keys = {}, actions = { "seen" }, text = "Mark the selected issue seen (opening its preview does it too): New and Changed show until then" },
			{ keys = {}, actions = { "snooze" }, text = "Snooze the selected issue until tomorrow morning" },
			{ keys = {}, actions = { "snoozed" }, text = "Show or hide snoozed issues" },
			{ keys = {}, actions = { "attention" }, text = "List only issues that need attention: unseen or changed, or whose agent waits for input" },
			{ keys = {}, actions = { "sort" }, text = "Switch this view to its next sort order (saved with the view)" },
			{ keys = {}, actions = { "more" }, text = "Command palette: every action above, saved actions or a typed prompt, assign to me, labels, Jira transition, guided draft PR, export and import, open by URL" },
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
		prompts = prompts.issues,
	},
}
M.KINDS = KINDS

M.SETTINGS_KEYS = {
	{ keys = { "↑", "↓" }, text = "Move between rows" },
	{ keys = { "Enter" }, text = "Edit a text row, press its button, switch a choice to its next option or open its menu; while editing, Enter saves" },
	{ keys = { "⌘↵" }, text = "Save an action's prompt (Enter there starts a new line)" },
	{ keys = { "←", "→", "Space" }, text = "In an open choice, move and pick; on chips, move and turn one on or off" },
	{ keys = { "⌫" }, text = "On a shortcut row after Enter: remove the shortcut (any other key becomes it)" },
	{ keys = { "Esc" }, text = "Cancel the edit or close the choice; with nothing open, close Settings" },
	{ keys = { "Tab" }, text = "Next page (Shift+Tab: previous page)" },
	{ keys = {}, actions = { "help" }, text = "Show or hide this list" },
} :: { KeyHelp }

function M.stateKind(pr: github.Pr): string
	if pr.state == "merged" or pr.state == "closed" then
		return pr.state
	end
	return if pr.draft then "draft" else "open"
end

-- An issue's state badge: its workflow status (Jira), else Open, or why it was closed.
function M.issueBadge(issue: tracker.Issue): { text: string, tone: string }
	if issue.status then
		return issue.status
	end
	if issue.state ~= "closed" then
		return M.STATE_BADGE.open
	end
	return CLOSED_REASON[issue.reason or ""] or M.STATE_BADGE.closed
end

GROUPS = {
	prs = {
		github = {
			{ value = "repo", label = "Repository", of = function(pr: any): string return pr.repo end },
			{ value = "author", label = "Author", of = function(pr: any): string return pr.author end },
			{ value = "state", label = "State", of = function(pr: any): string return M.STATE_BADGE[M.stateKind(pr)].text end },
			{ value = "review", label = "Review", of = function(pr: any): string return if pr.review then M.REVIEW_BADGE[pr.review].text else "No review" end },
			{ value = "checks", label = "Checks", of = function(pr: any): string return if pr.checks then M.CHECK[pr.checks].text else "No checks" end },
			{ value = "base", label = "Base branch", of = function(pr: any): string return pr.base end },
		},
	},
	issues = {
		github = {
			{ value = "repo", label = "Repository", of = function(issue: any): string return issue.repo end },
			{ value = "author", label = "Author", of = function(issue: any): string return issue.author end },
			{ value = "state", label = "State", keep = true, of = function(issue: any): string return M.issueBadge(issue).text end },
			{ value = "assignee", label = "Assignee", of = function(issue: any): string return issue.assignees[1] or "Unassigned" end },
		},
		jira = {
			{ value = "project", label = "Project", of = function(issue: any): string return issue.repo end },
			{ value = "status", label = "Status", rank = tracker.categoryRank, of = function(issue: any): string return M.issueBadge(issue).text end },
			{ value = "type", label = "Type", of = function(issue: any): string return issue.type or "No type" end },
			{ value = "priority", label = "Priority", of = function(issue: any): string return issue.priority or "No priority" end },
			{ value = "assignee", label = "Assignee", of = function(issue: any): string return issue.assignees[1] or "Unassigned" end },
			{ value = "reporter", label = "Reporter", of = function(issue: any): string return issue.author end },
		},
	},
}

M.RPC_PROTOCOL = "28"

-- Open in Git: the link of the worktree the card (or the Worktrees list's selected row) offers; its hidden node `git`
-- under `buttons` carries it, and the window asks the host for the path (rpc `git-path`).
M.GIT_LINK = "plotroom://worktrees/git"

return M
