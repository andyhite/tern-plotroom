--!strict
-- The Settings sheet: page content, editing, add/delete of views/prompts/repos/Jira projects, the Settings view.
local github = require("../github")
local input = require("../input")
local jira = require("../jira")
local keys = require("../keys")
local sorting = require("../sorting")
local tracker = require("../tracker")
local worktree = require("../worktree")
local core = require("./core")
local storage = require("./storage")
local engine = require("./engine")
local render = require("./render")

local ui = tern.ui

type Kind = core.Kind
type Prompt = core.Prompt
type Prompts = core.Prompts
type Settings = core.Settings
type State = core.State
type View = core.View

local INTEGRATIONS, KINDS, SETTINGS_ID, clip, groupsOf, printable, cli = core.INTEGRATIONS, core.KINDS, core.SETTINGS_ID, core.clip, core.groupsOf, core.printable, core.cli
local PROMPT_CAP, editJiraRepos, editPrompts, isTable, jiraReposOf, kindAndId, kvSet = storage.PROMPT_CAP, storage.editJiraRepos, storage.editPrompts, storage.isTable, storage.jiraReposOf, storage.kindAndId, storage.kvSet
local livePrompts, loadAll, loadPrompts, loadViews, promptById, readCheckouts, readJiraRepos = storage.livePrompts, storage.loadAll, storage.loadPrompts, storage.loadViews, storage.promptById, storage.readCheckouts, storage.readJiraRepos
local removeRepo, saveCheckout, setupMap, setupOf, stringList, writeViews, formats = storage.removeRepo, storage.saveCheckout, storage.setupMap, storage.setupOf, storage.stringList, storage.writeViews, storage.formats
local accountOf, activeView, alive, changed, groupLabel, login, orderedViews, parseRepo = engine.accountOf, engine.activeView, engine.alive, engine.changed, engine.groupLabel, engine.login, engine.orderedViews, engine.parseRepo
local propagate, retry, snapKey, switchView, trackerOf, viewOf, waitOf, ghActive = engine.propagate, engine.retry, engine.snapKey, engine.switchView, engine.trackerOf, engine.viewOf, engine.waitOf, engine.ghActive
local helpOverlay, paceLine, queuePicker, rpcNodes = render.helpOverlay, render.paceLine, render.queuePicker, render.rpcNodes

local M = {}

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

-- Where `list` holds the item with `id`, or 0.
local function indexOf(list: { View }, id: string): number
	for i, v in list do
		if v.id == id then
			return i
		end
	end
	return 0
end

-- Whether one of the kind's integrations is on.
local function usable(kind: Kind): boolean
	for _, i in kind.integrations do
		if cli.on(i) then
			return true
		end
	end
	return false
end

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
			if not engine.isPin(v.id) then
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
				local sortChoices = sorting.choices(v.kind, v.integration)
				if #sortChoices > 0 then
					local sortOptions: { any } = { { value = "default", label = "Default order" } }
					for _, c in sortChoices do
						table.insert(sortOptions, { value = c.value, label = c.label })
					end
					row({
						id = "vsort:" .. v.id,
						label = "Sort by",
						disabled = locked,
						control = { k = "choice", style = "menu", value = v.sort or "default", options = tern.json.array(sortOptions) },
					})
				end
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
				local missing = storage.missingViews(g.integration, g.views)
				if #missing > 0 then
					local locked: string? = nil
					for _, m in missing do
						locked = locked or state.locked[m.kind.id]
					end
					row({ id = "vrestore:" .. add, label = "", disabled = locked, control = { k = "action", act = "restore-views", label = "Restore defaults" } })
				end
			end
		end
	elseif s.page == "prompts" then
		for _, kind in { KINDS.prs, KINDS.issues } do
			-- A kind's prompts while one of its integrations is on: pull request prompts need gh.
			if not usable(kind) then
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
			if prompts and #require("../prompts").missing(kind.prompts, list) > 0 then
				row({ id = "prestore:" .. kind.id, label = "", control = { k = "action", act = "restore-prompts", label = "Restore defaults" } })
			end
		end
	elseif s.page == "keys" then
		local map, unreadable = keys.load()
		section("keys", "Queue")
		for _, a in keys.ACTIONS do
			row({
				id = "key:" .. a.id,
				label = a.label,
				disabled = unreadable,
				control = { k = "text", value = map[a.id], placeholder = "None" },
				changed = map[a.id] ~= a.default,
				defaultLabel = if a.default ~= "" then a.default else "None",
			})
		end
		-- Each saved action's own key, a card per kind while one of its integrations is on (as on the Actions page).
		for _, kind in { KINDS.prs, KINDS.issues } do
			local prompts = if usable(kind) then loadPrompts(kind) else nil
			if not prompts or #prompts.items == 0 then
				continue
			end
			section("pkeys:" .. kind.id, if kind.id == "prs" then "Pull request actions" else "Issue actions")
			for _, p in prompts.items do
				row({ id = "pkey:" .. kind.id .. ":" .. p.id, label = p.name, control = { k = "text", value = p.key or "", placeholder = "None" } })
			end
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
				disabled = if cli.claims[string.lower(repo)] then "Checking the folder, or cloning into it…" else nil,
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
function M.focusRows(state: State): { string }
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

function M.rowById(state: State, id: string): Row?
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
	local def = if s then M.rowById(state, row) else nil
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
	local target: View? = store.items[indexOf(store.items, id)]
	if not target then
		return "That view was deleted elsewhere."
	end
	local before = snapKey(target, state.activeLogin)
	fn(target)
	if target.sort and not sorting.valid(target.kind, target.integration, target.sort) then
		target.sort = nil -- a changed integration leaves the sort behind
	end
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

-- Saves the active view's next sort order (sorting.cycle; the one after the last is its default order). A pinned
-- pull request is no saved view and has none.
function M.cycleSort(state: State)
	local v = activeView(state)
	if not v or engine.isPin(v.id) then
		return state.cx:toast("info", "No sort to change", "A pinned item is a single item.")
	end
	local choices = sorting.choices(v.kind, v.integration)
	if #choices == 0 then
		return state.cx:toast("info", "This view has one order", "Sorting is not offered for " .. INTEGRATIONS[v.integration].label .. " " .. KINDS[v.kind].many .. " here.")
	end
	local nextSort = sorting.cycle(v.kind, v.integration, v.sort)
	local err = updateView(state, v.id, function(t: View)
		t.sort = nextSort
	end)
	if err then
		return state.cx:toast("error", "Sort not saved", err)
	end
	state.cx:toast("info", "Sorted: " .. sorting.label(nextSort), v.name)
end

-- Adds a view from a group's Add row `row` ("vadd:<integration>:<login>", the login empty for Jira) and opens its form
-- on the name: a view of that integration running as that login, of the active kind where the integration has it, else
-- an issue view.
local function addView(state: State, row: string)
	local s = state.settings
	local integration, login = string.match(row, "^vadd:(%a+):(.*)$")
	if not s or not integration or not cli.on(integration) or not INTEGRATIONS[integration] or not string.match(login or "", "^[%w%-_]*$") then
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

local function deleteView(state: State, s: Settings, id: string)
	local rowId = "vopen:" .. id -- the summary row shows why: the Delete row draws no label
	local view = viewOf(state, id)
	if not view then
		return
	end
	local kind = KINDS[view.kind]
	local place = math.max(indexOf(state.views, id), 1) -- where the view sits in the sidebar's list: its place goes to the view after it
	local store, writable, err = loadViews(kind)
	if not writable then
		loadAll(state)
		s.errors[rowId] = err or "Views cannot be saved."
		return
	end
	local at = indexOf(store.items, id)
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
local function deletePrompt(state: State, s: Settings, id: string)
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
local function deleteRepo(s: Settings, repo: string)
	local err = removeRepo(repo)
	s.errors["ropen:" .. repo] = err -- the summary row shows why: the Remove row draws no label
	if not err then
		s.focus = "radd"
	end
end

-- Removes Jira project `key` and its repositories.
local function deleteJira(s: Settings, key: string)
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
function M.setValue(state: State, row: string, value: any)
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
			local at = indexOf(src.items, id)
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
				-- Its sort goes along where the other kind offers it for this integration; else it is reset (said below).
				sort = if old.sort and sorting.valid(to.id, old.integration, old.sort) then old.sort else nil,
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
			if old.sort and not moved.sort then
				state.cx:toast("info", "Sort order reset", sorting.label(old.sort) .. " is not offered for " .. to.many .. "; the view uses its default order.")
			end
			return
		end
		s.errors[row] = updateView(state, id, function(v: View)
			if groupKnown(KINDS[v.kind], v.integration, chosen) then
				v.group = chosen
			end
		end)
	elseif kind == "vsort" then
		local view = viewOf(state, id)
		if not view or not choice or (choice ~= "default" and not sorting.valid(view.kind, view.integration, choice)) then
			return
		end
		s.errors[row] = updateView(state, id, function(v: View)
			v.sort = if choice == "default" then nil else choice
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
function M.pressOption(state: State, row: string, option: string)
	local s = state.settings
	local def = M.rowById(state, row)
	if not s or not def then
		return
	end
	local c = def.control
	if c.k == "choice" then
		s.pick = nil
		M.setValue(state, row, option)
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
	M.setValue(state, row, values)
end

-- Deletes what the delete row `s.confirm` names ("delete:<view id>", "pdelete:<prompt id>", "rremove:<repository>" or
-- "jremove:<project key>").
function M.confirmDelete(state: State)
	local s = state.settings
	if not s then
		return
	end
	local kind, id = string.match(s.confirm or "", "^(%a+):(.+)$")
	if not id then
		return
	end
	s.confirm = nil
	if kind == "delete" then
		deleteView(state, s, id)
	elseif kind == "pdelete" then
		deletePrompt(state, s, id)
	elseif kind == "rremove" then
		deleteRepo(s, id)
	elseif kind == "jremove" then
		deleteJira(s, id)
	end
end

function M.runAction(state: State, act: string, row: string)
	local s = state.settings
	if not s then
		return
	end
	if act == "add" then
		addView(state, row)
	elseif act == "add-prompt" then
		addPrompt(state, row)
	elseif act == "restore-views" then
		-- Saves back the default views the row's group has none of the same kind and name of, as views of that group
		-- (running as its login, as Add view's do); the others, edited defaults included, stay.
		local integration, login = string.match(row, "^vrestore:(%a+):(.*)$")
		if not integration or not login or not cli.on(integration) or not INTEGRATIONS[integration] or not string.match(login, "^[%w%-_]*$") then
			return
		end
		local label = string.lower(INTEGRATIONS[integration].label .. (if login ~= "" then " - " .. login else ""))
		local group: { View } = {}
		for _, v in state.views do
			if v.integration == integration and string.lower(groupLabel(v)) == label then
				table.insert(group, v)
			end
		end
		local missing = storage.missingViews(integration, group)
		local err: string? = nil
		for _, kind in { KINDS.prs, KINDS.issues } do
			local store, writable, why = loadViews(kind)
			local added = false
			for _, m in missing do
				if m.kind == kind then
					local d = m.seed
					table.insert(store.items, { id = kind.id .. ":v" .. store.nextId, kind = kind.id, name = d.name, integration = d.integration, query = d.query, logins = if login ~= "" then { login } else {}, group = d.group, prompts = {}, sort = d.sort })
					store.nextId += 1
					added = true
				end
			end
			if added and not err then
				err = if writable then writeViews(kind, store) else why or "Views cannot be saved."
			end
		end
		s.errors[row] = err
		loadAll(state)
		propagate(state)
		if not err then
			s.focus = "vadd:" .. integration .. ":" .. login -- the restore button is gone with nothing left to restore
		end
	elseif act == "restore-prompts" then
		-- Saves back the defaults no saved action is named like; the others, edited defaults included, stay.
		local kind = KINDS[string.match(row, "^prestore:(%a+)$") or ""]
		if kind then
			s.errors[row] = editPrompts(kind, function(store: Prompts): string?
				for _, d in require("../prompts").missing(kind.prompts, store.items) do
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
		state.cx:open("plotroom://repos")
	elseif act == "add-jira" then
		state.cx:open("plotroom://jira-projects")
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
function M.runRow(state: State, row: string?)
	local s = state.settings
	if not row or not s or (s.edit and s.edit.row == row) then
		return -- a click inside the field being edited keeps its draft
	end
	local def = M.rowById(state, row)
	if not def or def.disabled then
		return
	end
	local c = def.control
	if c.k == "text" then
		beginEdit(state, row)
	elseif c.k == "action" then
		M.runAction(state, c.act, row)
	elseif c.k == "choice" and c.style == "segmented" then
		local at = 0
		for i, o in c.options do
			if o.value == c.value then
				at = i
			end
		end
		local nextOption = c.options[at % #c.options + 1]
		s.focus = row
		M.setValue(state, row, nextOption.value)
	elseif c.k == "choice" then
		s.focus, s.pick = row, { row = row, option = c.value }
	elseif c.k == "multi" and c.options[1] then
		s.focus, s.pick = row, { row = row, option = c.options[1].value }
	end
end

-- Enter on a text row: saves it. A rejected value stays in the field with its warning, for a correction.
function M.commitEdit(state: State)
	local s = state.settings
	local e = if s then s.edit else nil
	if not s or not e then
		return
	end
	local text = input.trim(e.model.text)
	local row = e.row
	local def = M.rowById(state, row)
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
		local key = string.lower(repo)
		if cli.claims[key] then
			s.errors[row] = "A checkout of " .. repo .. " is already being set up."
			return
		end
		s.edit = nil
		local before = readCheckouts()[key]
		cli.claims[key] = true
		worktree.claimCheckout(path, repo, login(state), function(claimed, problem)
			cli.claims[key] = nil
			if not alive(state) then
				return
			end
			local root = if claimed then claimed.root else nil
			local err: string?
			if root and readCheckouts()[key] ~= before then
				err = repo .. "'s checkout was changed or removed while it was being set up" -- saving would undo that
			elseif root then
				err = saveCheckout(repo, root)
			else
				err = problem or "That path is not a checkout of " .. repo .. "."
			end
			if not err then
				s.errors[row] = nil
				local cloned = claimed ~= nil and claimed.cloned
				state.scanned = nil -- the new checkout may already hold worktrees: the next render scans it
				state.cx:toast("success", if cloned then "Cloned " .. repo else "Checkout saved", root)
			elseif state.settings == s and s.page == "repos" and not s.edit and readCheckouts()[key] ~= nil then
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
function M.discardEdit(state: State)
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
function M.showPage(state: State, s: Settings, page: string)
	M.discardEdit(state)
	s.page, s.focus, s.pick, s.errors = page, nil, nil, {}
	state.settingsPage = page
	if page == "views" then
		ghActive.note(state, true)
	elseif string.find(page, "^setup%-") then
		engine.probeClis(true)
	end
end

function M.resetRow(state: State, row: string)
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
function M.openSettings(state: State, page: string?, row: string?, edit: boolean?)
	M.discardEdit(state) -- releases the prompt editor's caret, if one was open
	local s: Settings = { page = "views", errors = {}, open = if row then string.match(row, "^%a+:(.+)$") else nil }
	state.settings = s
	M.showPage(state, s, cli.page(page or state.settingsPage))
	s.focus = row
	if edit and row then
		beginEdit(state, row)
	end
end

-- The window's repository picker chose `raw` ("owner/name", maybe typed): it is listed in Settings, which opens on
-- its checkout row to set it.
function M.addRepo(state: State, raw: any)
	local repo = parseRepo(raw)
	if not repo then
		return state.cx:toast("error", "Not a repository", "Type it as owner/name.")
	end
	local err = saveCheckout(repo, "", true)
	if err then
		return state.cx:toast("error", "Repository not saved", err)
	end
	M.openSettings(state, "repos", "checkout:" .. string.lower(repo), true)
end

-- The window's Jira project picker chose `raw` (a project key, maybe typed in lowercase): it is listed in Settings,
-- which opens on its repositories.
function M.addJira(state: State, raw: any)
	local key = string.upper(if type(raw) == "string" then input.trim(raw) else "")
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
	M.openSettings(state, "jira", "jrepos:" .. key, false)
end

function M.settingsView(state: State): BlockView
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

return M
