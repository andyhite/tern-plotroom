--!strict
-- The Settings sheet: page content, editing, add/delete of views/prompts/repos/Jira projects, the Settings view.
local github = require("../github")
local input = require("../input")
local jira = require("../jira")
local keys = require("../keys")
local defaults = require("../prompts")
local sorting = require("../sorting")
local process = require("../process")
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
type PromptSeed = defaults.Seed

local INTEGRATIONS, KINDS, SETTINGS_ID, clip, printable, cli = core.INTEGRATIONS, core.KINDS, core.SETTINGS_ID, core.clip, core.printable, core.cli
local PROMPT_CAP, chainReaches, editJiraRepos, editPrompts, editSetup, isTable, jiraReposOf, kindAndId, nextOf = storage.PROMPT_CAP, storage.chainReaches, storage.editJiraRepos, storage.editPrompts, storage.editSetup, storage.isTable, storage.jiraReposOf, storage.kindAndId, storage.nextOf
local livePrompts, loadAll, loadPrompts, loadViews, promptById, readCheckouts, readMap = storage.livePrompts, storage.loadAll, storage.loadPrompts, storage.loadViews, storage.promptById, storage.readCheckouts, storage.readMap
local removeRepo, saveCheckout, seedNext, setupOf, stringList, writeViews, formats = storage.removeRepo, storage.saveCheckout, storage.seedNext, storage.setupOf, storage.stringList, storage.writeViews, storage.formats
local accountOf, activeView, changed, groupLabel, login, orderedViews, parseRepo = engine.accountOf, engine.activeView, engine.changed, engine.groupLabel, engine.login, engine.orderedViews, engine.parseRepo
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

-- What omp lists for Settings › Actions › Model, asked again each time the Actions page opens: `models`, the chat
-- models' selectors ("provider/id") in omp's order, grouped by provider; `roles`, the role aliases of omp's config
-- (minus `default`, which is omp's default) with the model each names; `known`, every selector, bare id and "@role"
-- (lowercase) a saved model is matched against. `failed`: why omp listed no models, which turns the row into the text
-- field. Nothing yet: still asking. One list for the host, as it is omp's.
type OmpModels = { loading: boolean, models: { string }?, roles: { { name: string, model: string } }?, known: { [string]: string }?, failed: string?, waiters: { () -> () } }
local omp: OmpModels = { loading = false, waiters = {} }
M.omp = omp

-- Asks omp for its models and role aliases (unless already asking), then runs `done` and draws `state` again.
function M.loadModels(state: State?, done: (() -> ())?)
	if done then
		table.insert(omp.waiters, done)
	end
	if omp.loading then
		return
	end
	omp.loading = true
	local pending = 2
	local models: { string }, roles: { { name: string, model: string } }, known: { [string]: string } = {}, {}, {}
	local failed: string? = nil
	local function finish()
		pending -= 1
		if pending > 0 then
			return
		end
		omp.loading, omp.failed = false, failed
		omp.models, omp.roles, omp.known = if failed then nil else models, if failed then nil else roles, if failed then nil else known
		local waiters = omp.waiters
		omp.waiters = {}
		for _, w in waiters do
			w()
		end
		if state and engine.alive(state) then
			state.cx:render()
		end
	end
	process.run({ "omp", "models", "--json" }, { timeout_ms = 30000 }, function(res, problem)
		local ok, data = pcall(tern.json.decode, if res and res.status == 0 and not res.timed_out then res.stdout else "")
		local list = if ok and isTable(data) and isTable(data.models) then data.models else nil
		if not list then
			failed = problem or (if res and res.stderr ~= "" then clip(printable(res.stderr), 200) else "omp did not list its models.")
			return finish()
		end
		-- Grouped by provider, in the order omp names them.
		local byProvider: { [string]: { string } } = {}
		local providers: { string } = {}
		for _, m in list do
			if isTable(m) and type(m.selector) == "string" and type(m.provider) == "string" and (m.kind == nil or m.kind == "chat") and worktree.validModel(m.selector) then
				if not byProvider[m.provider] then
					byProvider[m.provider] = {}
					table.insert(providers, m.provider)
				end
				table.insert(byProvider[m.provider], m.selector)
				known[string.lower(m.selector)] = m.selector
				if type(m.id) == "string" then
					known[string.lower(m.id)] = m.selector
				end
			end
		end
		for _, p in providers do
			for _, sel in byProvider[p] do
				table.insert(models, sel)
			end
		end
		if #models == 0 then
			failed = "omp lists no models."
		end
		finish()
	end)
	process.run({ "omp", "config", "get", "modelRoles", "--json" }, { timeout_ms = 30000 }, function(res)
		-- omp's own roles (its --smol, --slow and --plan) resolve with no config; the config names their models and adds
		-- roles of its own. Unset, or omp could not say: just omp's roles, with no model named.
		local named: { [string]: string } = {}
		local ok, data = pcall(tern.json.decode, if res and res.status == 0 and not res.timed_out then res.stdout else "")
		if ok and isTable(data) and isTable(data.value) then
			for name, model in data.value do
				if type(name) == "string" and name ~= "default" and type(model) == "string" and worktree.validModel("@" .. name) then
					named[name] = clip(printable(model), 100)
				end
			end
		end
		for _, name in { "plan", "slow", "smol" } do
			named[name] = named[name] or ""
		end
		for name, model in named do
			table.insert(roles, { name = name, model = model })
			known["@" .. string.lower(name)] = "@" .. name
		end
		table.sort(roles, function(a, b)
			return a.name < b.name
		end)
		finish()
	end)
end

-- What `model` (a saved action's) is in omp's list: the selector or "@role" it names, also with an effort suffix
-- ("gpt-5.2:high"); nil when omp does not list it. Always nil while the list is not known.
function M.listedModel(model: string): string?
	local known = omp.known
	if not known then
		return nil
	end
	local lower = string.lower(model)
	local base, level = string.match(lower, "^(.-):(%a+)$")
	return known[lower] or (if base and worktree.validEffort(level :: string) then known[base] else nil)
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
	-- A list row of the open form's kind: closed, a summary row (`prefix` .. `id`) with an Edit button and the hint `hint()`
	-- says, and true; open, the form's card and the row that closes it (Edit turns Done in place), and false. The form's
	-- delete button sits right after Done in key order; plotroom.css draws it left of Done, on the summary row.
	local function summary(prefix: string, id: string, label: string, hint: () -> string): boolean
		if s.open ~= id then
			row({ id = prefix .. id, label = label, hint = clip(printable(hint()), 120), control = { k = "action", act = "expand", label = "Edit" } })
			return true
		end
		openCard(id)
		row({ id = prefix .. id, label = label, control = { k = "action", act = "collapse", label = "Done" } })
		return false
	end
	if s.page == "views" then
		-- Now's card first: which reasons and accounts feed Now, each switched on or off. Switches saved where they
		-- cannot be read, or malformed, are shown as the defaults Now runs with, and say why instead of changing.
		local prefs, unreadable = storage.readNow()
		local function switch(on: boolean): { [string]: any }
			return { k = "switch", on = on }
		end
		-- List or Board, for Now and for each view (engine.lanesShown).
		local function layout(board: boolean): { [string]: any }
			return { k = "choice", style = "segmented", value = if board then "board" else "list", options = tern.json.array({ { value = "list", label = "List" }, { value = "board", label = "Board" } }) }
		end
		section("now")
		if not summary("nopen:", "now", "Now", function()
			local listed: { string } = {}
			for _, r in core.NOW_REASONS do
				if not prefs.off[r.id] then
					table.insert(listed, r.label)
				end
			end
			return (if #listed > 0 then table.concat(listed, " · ") else "Only agents") .. (if prefs.board then " · Board" else "")
		end) then
			row({ id = "now:layout", label = "Layout", hint = "A narrow block shows the List", disabled = unreadable, control = layout(prefs.board) })
			for _, r in core.NOW_REASONS do
				row({ id = "now:" .. r.id, label = r.label, disabled = unreadable, control = switch(not prefs.off[r.id]) })
				if r.id == "review" then
					row({ id = "now:teams", label = "Include team review requests", hint = "Requests of a team you are on, not only of you", disabled = unreadable, control = switch(prefs.teams) })
				end
			end
			section("now-accounts", "Accounts")
			if cli.on("github") then
				for _, who in ghActive.accounts do
					row({ id = "now:login:" .. who, label = INTEGRATIONS.github.label .. " - " .. who, disabled = unreadable, control = switch(not prefs.logins[string.lower(who)]) })
				end
			end
			if cli.on("jira") then
				row({ id = "now:jira", label = INTEGRATIONS.jira.label, disabled = unreadable, control = switch(prefs.jira) })
			end
		end
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
				if summary("vopen:", v.id, name, function()
					return kind.label .. " · " .. v.query .. (if v.layout == "board" then " · Board" else "")
				end) then
					continue
				end
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
						control = { k = "choice", style = "menu", value = v.kind, options = tern.json.array(kindOptions) },
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
				for _, by in core.groupsOf(v.kind, v.integration) do
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
				row({ id = "vlayout:" .. v.id, label = "Layout", disabled = locked, control = layout(v.layout == "board") })
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
					row({ id = "vrestore:" .. add, label = "", disabled = locked, control = { k = "action", act = "restore-views", label = "Add missing defaults" } })
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
				if summary("popen:", qid, p.name, function()
					-- The first line is cut short of the row's 120 so a model after it still shows.
					local parts: { string } = { if first ~= "" then clip(first, 80) else "Empty" }
					if p.model then
						table.insert(parts, p.model)
					end
					if p.effort then
						table.insert(parts, p.effort)
					end
					return table.concat(parts, " · ")
				end) then
					continue
				end
				row({ id = "pdelete:" .. qid, label = "Delete action", control = { k = "action", act = "delete", label = "Delete" } })
				row({ id = "pname:" .. qid, label = "Name", control = { k = "text", value = p.name, placeholder = "Review" } })
				row({
					id = "ptext:" .. qid,
					label = "Prompt",
					hint = if first ~= "" then clip(printable(first), 80) else "Empty",
					control = { k = "action", act = "edit-prompt", label = "Edit…" },
				})
				-- Picked from omp's list in the window's picker; a text field while omp lists no models.
				local model = p.model
				row({
					id = "pmodel:" .. qid,
					label = "Model",
					hint = if model and omp.known and not M.listedModel(model) then "Not in omp's list" else nil,
					control = if omp.failed
						then { k = "text", value = model or "", placeholder = "omp's default", mono = true }
						else { k = "action", act = "pick-model", label = model or "omp's default" },
					changed = model ~= nil,
					defaultLabel = "omp's default",
				})
				local efforts: { any } = { { value = "default", label = "omp's default" } }
				for _, level in worktree.EFFORTS do
					table.insert(efforts, { value = level, label = if level == "xhigh" then "XHigh" else string.upper(string.sub(level, 1, 1)) .. string.sub(level, 2) })
				end
				row({
					id = "peffort:" .. qid,
					label = "Effort",
					hint = "How hard the model thinks (omp --thinking)",
					control = { k = "choice", style = "segmented", value = p.effort or "default", options = tern.json.array(efforts) },
				})
				if kind.id == "issues" then
					row({
						id = "pstatus:" .. qid,
						label = "Move to status",
						hint = "Jira issues move here when the agent starts",
						control = { k = "text", value = p.status or "", placeholder = "Leave the status alone" },
						changed = p.status ~= nil,
						defaultLabel = "Leave the status alone",
					})
				end
				row({
					id = "pwhere:" .. qid,
					label = "Runs in",
					control = {
						k = "choice",
						style = "segmented",
						value = if p.worktree ~= false then "worktree" else "checkout",
						options = tern.json.array({ { value = "worktree", label = "Worktree" }, { value = "checkout", label = "Checkout" } }),
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
				local outcomes: { any } = {}
				for _, o in require("../prompts").OUTCOMES do
					table.insert(outcomes, { value = o.id, label = o.label })
				end
				row({
					id = "poutcome:" .. qid,
					label = "Outcome",
					hint = "What its run must leave behind, checked on GitHub when the agent's turn ends",
					control = { k = "choice", style = "menu", value = p.outcome or "none", options = tern.json.array(outcomes) },
				})
				local nextOptions: { any } = { { value = "none", label = "None" } }
				for _, other in list do
					if other.id ~= p.id and not chainReaches(prompts :: Prompts, p.id, other.id) then
						table.insert(nextOptions, { value = other.id, label = clip(printable(other.name), 60) })
					end
				end
				-- An issue action may also lead into a pull request action (Implement → Watch), labelled by its kind.
				local prSaved = if kind.id == "issues" and usable(KINDS.prs) then loadPrompts(KINDS.prs) else nil
				local prItems: { Prompt } = if prSaved then prSaved.items else {}
				for _, other in prItems do
					table.insert(nextOptions, { value = "prs:" .. other.id, label = clip(printable(other.name), 48) .. " (pull request)" })
				end
				local nextKind, nextId = nextOf(kind, p.next or "")
				local nextStore = if p.next == nil then nil elseif nextKind == kind then prompts else prSaved
				row({
					id = "pnext:" .. qid,
					label = "Next action",
					hint = "Starts for the same item, in the same tab and worktree, once this action's run is Verified or its check passes",
					control = { k = "choice", style = "menu", value = if p.next and nextStore and promptById(nextStore :: Prompts, nextId) then p.next else "none", options = tern.json.array(nextOptions) },
				})
				local checkers: { any } = { { value = "none", label = "None" } }
				for _, other in list do
					if other.id ~= p.id then
						table.insert(checkers, { value = other.id, label = clip(printable(other.name), 60) })
					end
				end
				row({
					id = "pchecker:" .. qid,
					label = "Checked by",
					hint = "When its run ends with a commit, a fresh agent runs this action on the same item and checks the work against the acceptance criteria",
					control = { k = "choice", style = "menu", value = p.checker or "none", options = tern.json.array(checkers) },
				})
				section("after:" .. qid)
			end
			-- prefs draws no section without rows, so with none saved the kind's title goes on its buttons'.
			section((if #list > 0 then "add:" else "add-to:") .. kind.id, if #list > 0 then nil else title)
			row({ id = "padd:" .. kind.id, label = "", disabled = unreadable, control = { k = "action", act = "add-prompt", label = "Add action" } })
			if prompts and #require("../prompts").missing(kind.prompts, list) > 0 then
				row({ id = "prestore:" .. kind.id, label = "", control = { k = "action", act = "restore-prompts", label = "Add missing defaults" } })
			end
		end
	elseif s.page == "repos" then
		-- The default name formats, then each repository's form, then the Jira projects while acli is on.
		section("sec-names", "Name formats")
		for _, f in {
			{ id = "branch", label = "Issue branch name", vars = tracker.VARS },
			{ id = "prdir", label = "Pull request folder name", vars = tracker.DIR_VARS },
			{ id = "issuedir", label = "Issue folder name", vars = tracker.DIR_VARS },
		} do
			if f.id == "prdir" and not cli.on("github") then
				continue -- pull requests need gh
			end
			local saved, unreadable = formats.saved(f.id)
			row({
				id = "fmt:" .. f.id,
				label = f.label,
				hint = "{" .. table.concat(f.vars, "} {") .. "}",
				control = { k = "text", value = saved, placeholder = formats.DEFAULTS[f.id], mono = true },
				changed = saved ~= "",
				defaultLabel = formats.DEFAULTS[f.id],
				disabled = unreadable,
			})
		end
		local checkouts = readCheckouts()
		local names: { string } = {}
		for name in checkouts do
			if type(name) == "string" then
				table.insert(names, name)
			end
		end
		table.sort(names)
		local repoFormats, formatsOff = readMap("branch-formats", "branch formats")
		local setups, setupsOff = readMap("setup-commands", "setup commands")
		section("repos", "Repositories")
		for _, repo in names do
			local path = checkouts[repo]
			local mapped = if type(path) == "string" and path ~= "" then path else nil
			local fmt = if repoFormats then formats.repoOf(repo) else nil
			local cmds: { string } = if setups then setupOf(setups, repo) else {}
			if summary("ropen:", repo, repo, function()
				local parts: { string } = { mapped or "No checkout" }
				if fmt then
					table.insert(parts, fmt)
				end
				if #cmds > 0 then
					table.insert(parts, #cmds .. (if #cmds == 1 then " setup command" else " setup commands"))
				end
				return table.concat(parts, " · ")
			end) then
				continue
			end
			row({ id = "rremove:" .. repo, label = "Remove repository", control = { k = "action", act = "delete", label = "Remove" } })
			row({
				id = "checkout:" .. repo,
				label = "Checkout",
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
				defaultLabel = "the Name formats default",
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
		-- Add repository and Add project open the window's pickers. prefs draws no section without rows, so with none
		-- listed the card's title goes on its Add button's.
		section(if #names > 0 then "add:repo" else "add-to:repo", if #names > 0 then nil else "Repositories")
		row({ id = "radd", label = "", control = { k = "action", act = "add-repo", label = "Add repository" } })
		-- Ignored checks (Ignore this check… adds them), one row per repository and check name, each removed at once.
		local ignoredMap, ignoredOff = storage.readIgnored()
		local ignored: { [string]: { string } } = ignoredMap or {}
		local ignoredRepos: { string } = {}
		for repo in ignored do
			table.insert(ignoredRepos, repo)
		end
		table.sort(ignoredRepos)
		if ignoredOff or #ignoredRepos > 0 then
			section("ignored", "Ignored checks")
		end
		if ignoredOff then
			row({ id = "ignored", label = "Ignored checks", warning = ignoredOff, disabled = ignoredOff, control = { k = "action", act = "unignore", label = "Remove" } })
		end
		for _, repo in ignoredRepos do
			for _, name in ignored[repo] do
				row({ id = "unignore:" .. repo .. ":" .. name, label = clip(printable(name), 120), hint = repo, control = { k = "action", act = "unignore", label = "Remove" } })
			end
		end
		if cli.on("jira") then
			local map, unreadable = readMap("jira-repos", "Jira project repositories")
			local keys: { string } = {}
			local saved: { [string]: any } = map or {}
			for key in saved do
				if type(key) == "string" then
					table.insert(keys, key)
				end
			end
			table.sort(keys)
			local options: { any } = {}
			for _, name in names do
				table.insert(options, { value = name, label = name })
			end
			section("projects", "Jira projects")
			for _, key in keys do
				local repos = jiraReposOf(key)
				if summary("jopen:", key, key, function()
					return if #repos > 0 then table.concat(repos, ", ") else "No repositories"
				end) then
					continue
				end
				row({ id = "jremove:" .. key, label = "Remove project", disabled = unreadable, control = { k = "action", act = "delete", label = "Remove" } })
				row({
					id = "jrepos:" .. key,
					label = "Repositories",
					disabled = unreadable or (if #options == 0 then "Add a repository first." else nil),
					control = { k = "multi", values = tern.json.array(repos), options = tern.json.array(options) },
				})
				section("after:" .. key)
			end
			section(if #keys > 0 then "add:jira" else "add-to:jira", if #keys > 0 then nil else "Jira projects")
			row({ id = "jadd", label = "", disabled = unreadable, control = { k = "action", act = "add-jira", label = "Add project" } })
		end
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
	else -- general: the keyboard shortcuts, then Refresh now with the pacing and GitHub's quota
		local map, unreadable = keys.load()
		section("keys", "Keyboard shortcuts")
		local presets: { string } = {}
		for _, a in keys.ACTIONS do
			if a.preset then
				table.insert(presets, a.preset)
			end
		end
		row({ id = "kpreset", label = "Use one-key shortcuts", hint = "Binds " .. table.concat(presets, " ") .. " to the actions with no key; a shortcut you removed stays removed", disabled = unreadable, control = { k = "action", act = "preset-keys", label = "Use" } })
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
		-- Summaries at the top of a preview: on or off, and the model omp writes them with.
		local sp, sproblem = storage.readSummary()
		section("summary", "Summary")
		row({
			id = "summary:on",
			label = "Summaries",
			hint = sproblem or "A few sentences about the selected item, written by a small model",
			disabled = sproblem,
			control = { k = "switch", on = sp.on },
		})
		-- Picked from omp's list in the window's picker, as an action's Model is; a text field while omp lists no models.
		local smodel = sp.model
		local sdefault = require("../summary").MODEL
		row({
			id = "summary:model",
			label = "Summary model",
			hint = if smodel and omp.known and not M.listedModel(smodel) then "Not in omp's list" else nil,
			disabled = sproblem,
			control = if omp.failed
				then { k = "text", value = smodel or "", placeholder = sdefault .. " (omp's small model)", mono = true }
				else { k = "action", act = "pick-model", label = smodel or sdefault },
			changed = smodel ~= nil,
			defaultLabel = sdefault .. " (omp's small model)",
		})
		-- Where a turn end's Draft review opens (Settings › General › Draft review).
		local glimpse, rproblem = storage.readReview()
		section("review", "Draft review")
		row({
			id = "review:opens",
			label = "Draft review opens",
			hint = rproblem or "Over the agent's tab, it shows until you click outside it; Show Draft review brings it back",
			disabled = rproblem,
			control = {
				k = "choice",
				style = "segmented",
				value = if glimpse then "glimpse" else "split",
				options = tern.json.array({ { value = "split", label = "Beside the agent" }, { value = "glimpse", label = "Over the agent's tab" } }),
			},
		})
		local now = os.time()
		local wait = waitOf(state)
		table.insert(sections, {
			-- prefs draws its one in-section slot (a child with role omp.prefs.preview.status) only after this id.
			id = "status-line",
			title = "Refresh",
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
		section("reset", "Reset")
		row({
			id = "reset:all",
			label = "Reset all settings",
			hint = "Clears views, actions, shortcuts, repositories, branch and folder formats and Get started; keeps triage, usage and agents",
			control = { k = "action", act = "reset-all", label = "Reset" },
		})
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

-- Edits prompt `qid` ("<kind id>:<id in that kind's store>") under editPrompts: `fn(store, prompt, kind, saved id)` returns an
-- error message or nil. A prompt gone elsewhere is "That action was deleted elsewhere.", or with `quiet` no change.
local function editPrompt(state: State, qid: string, fn: (Prompts, Prompt, Kind, string) -> string?, quiet: boolean?): string?
	local gone = if quiet then nil else "That action was deleted elsewhere."
	local pk, pid = kindAndId(qid)
	if not pk then
		return gone
	end
	local err = editPrompts(pk, function(store: Prompts): string?
		local p = promptById(store, pid)
		if not p then
			return gone
		end
		return fn(store, p, pk, pid)
	end)
	if not err then
		propagate(state)
	end
	return err
end

-- Opens a text row for editing, or a prompt's text (its "ptext:" row) in the multi-line editor card.
local function beginEdit(state: State, row: string, initial: string?)
	local s = state.settings
	local def = if s then M.rowById(state, row) else nil
	if not s or not def or def.disabled then
		return
	end
	if s.edit and s.edit.model.multi then
		return -- an open prompt draft is not overwritten
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
		propagate(state)
	end
	return err
end

-- Whether `value` is a group-by of views of `integration` (every kind accepts "none").
local function groupKnown(kind: Kind, integration: string, value: string): boolean
	if value == "none" then
		return true
	end
	for _, g in core.groupsOf(kind.id, integration) do
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
	if not v then
		return state.cx:toast("info", "No sort to change", "No view is shown.")
	elseif engine.isPin(v.id) then
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

-- Saves Now's layout (Settings › Views › Now › Layout): an error message or nil. Every block draws it at once.
function M.nowLayout(state: State, board: boolean): string?
	local err = storage.editNow(function(p)
		p.board = board
	end)
	if not err then
		engine.nowPrefsChanged(state, true)
	end
	return err
end

-- Commands › Show as Board / Show as List: the other layout for Now or the active view, saved where Settings › Views
-- saves it. A pinned item is no saved view and has none.
function M.toggleLayout(state: State): boolean
	local err: string?
	if state.nowOn then
		err = M.nowLayout(state, not state.now.prefs.board)
	else
		local v = activeView(state)
		if not v or engine.isPin(v.id) then
			return false
		end
		err = updateView(state, v.id, function(t: View)
			t.layout = if t.layout == "board" then nil else "board"
		end)
	end
	if err then
		state.cx:toast("error", "Layout not saved", err)
	end
	return true
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
		propagate(state)
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
		for _, p in store.items do
			if p.next == saved then
				p.next = nil -- a next action that is gone is dropped
			end
			if p.checker == saved then
				p.checker = nil -- so is a checker
			end
		end
		return nil
	end)
	if not err and kind.id == "prs" then
		-- Issue actions name it as `prs:<id>`. Only an issue store that has one is written: a store with nothing saved
		-- keeps its seeded defaults unsaved. ponytail: an unreadable issue store keeps its bytes and its dangling next,
		-- which Settings shows as None and a finished agent reports as gone.
		local issues = loadPrompts(KINDS.issues)
		local names = false
		local items: { Prompt } = if issues then issues.items else {}
		for _, p in items do
			names = names or p.next == id
		end
		if names then
			editPrompts(KINDS.issues, function(store: Prompts): string?
				for _, p in store.items do
					if p.next == id then
						p.next = nil
					end
				end
				return nil
			end)
		end
	end
	if not err then
		propagate(state)
	end
	s.errors["popen:" .. id] = err -- the summary row shows why: the Delete row draws no label
	if not err then
		s.focus = "padd:" .. kind.id
	end
end

-- Removes repository `repo` everywhere it is saved.
local function deleteRepo(state: State, s: Settings, repo: string)
	local err = removeRepo(repo)
	s.errors["ropen:" .. repo] = err -- the summary row shows why: the Remove row draws no label
	if not err then
		propagate(state)
		s.focus = "radd"
	end
end

-- Removes Jira project `key` and its repositories.
local function deleteJira(state: State, s: Settings, key: string)
	local err = editJiraRepos(function(map: { [string]: any }): string?
		map[key] = nil
		return nil
	end)
	s.errors["jopen:" .. key] = err -- the summary row shows why: the Remove row draws no label
	if not err then
		propagate(state)
		s.focus = "jadd"
	end
end

-- Saves row `row`'s new value as its control sends it: a switch row's state (a boolean), a choice row's option (a
-- string: a view's type and group-by, where a prompt runs and opens) or a chips row's options now on (an array).
-- A value of another shape, or an option the row does not offer, changes nothing.
function M.setValue(state: State, row: string, value: any)
	local s = state.settings
	if not s then
		return
	end
	local choice: string? = if type(value) == "string" then value else nil
	local switched: boolean? = if type(value) == "boolean" then value else nil
	local values: { any } = if isTable(value) then value else {}
	local kind, id = string.match(row, "^(%a+):(.+)$")
	if not kind or not id then
		return
	end
	if kind == "now" and id == "layout" then
		if choice ~= "list" and choice ~= "board" then
			return
		end
		s.errors[row] = M.nowLayout(state, choice == "board")
	elseif kind == "now" then
		-- One of Now's switches (Settings › Views › Now): a reason, team review requests, a gh login or Jira.
		local who = string.match(id, "^login:([%w%-_]+)$")
		local reason = false
		for _, r in core.NOW_REASONS do
			reason = reason or r.id == id
		end
		if switched == nil or not (who or reason or id == "teams" or id == "jira") then
			return
		end
		local on: boolean = switched
		s.errors[row] = storage.editNow(function(p)
			if who then
				p.logins[string.lower(who)] = not on -- editNow saves only the ones that are off
			elseif id == "teams" then
				p.teams = on
			elseif id == "jira" then
				p.jira = on
			else
				p.off[id] = not on
			end
		end)
		if not s.errors[row] then
			engine.nowPrefsChanged(state)
		end
	elseif kind == "summary" and id == "on" then
		if switched == nil then
			return
		end
		local on: boolean = switched
		s.errors[row] = storage.editSummary(function(p)
			p.on = on
		end)
		if not s.errors[row] then
			propagate(state)
		end
	elseif kind == "review" and id == "opens" then
		if choice ~= "split" and choice ~= "glimpse" then
			return
		end
		s.errors[row] = storage.saveReview(choice == "glimpse")
		if not s.errors[row] then
			propagate(state)
		end
	elseif kind == "pnext" then
		if not choice then
			return
		end
		local to: string? = if choice == "none" then nil else choice
		s.errors[row] = editPrompt(state, id, function(store, p, pk, pid)
			local tk, tid = nextOf(pk, to or "")
			local tstore = if to == nil then nil elseif tk == pk then store else loadPrompts(tk)
			if to and not (tstore and promptById(tstore, tid)) then
				return "That action was deleted elsewhere."
			elseif to and tk == pk and chainReaches(store, pid, to) then
				return "That would make a loop of actions."
			end
			p.next = to
			return nil
		end)
	elseif kind == "pmodel" or (kind == "summary" and id == "model") then
		-- The window's model picker: a model or role omp listed (the row's reset is omp's default, or @smol for Summaries).
		if not (choice and worktree.validModel(choice)) then
			return
		end
		s.errors[row] = if kind == "summary"
			then storage.editSummary(function(p)
				p.model = choice
			end)
			else editPrompt(state, id, function(_, p)
				p.model = choice
				return nil
			end)
		if kind == "summary" and not s.errors[row] then
			propagate(state)
		end
	elseif kind == "peffort" then
		if not (choice and (choice == "default" or worktree.validEffort(choice))) then
			return
		end
		s.errors[row] = editPrompt(state, id, function(_, p)
			p.effort = if choice == "default" then nil else choice
			return nil
		end)
	elseif kind == "poutcome" then
		if not (choice and (choice == "none" or require("../prompts").outcomeLabel(choice))) then
			return
		end
		s.errors[row] = editPrompt(state, id, function(_, p)
			p.outcome = if choice == "none" then nil else choice
			return nil
		end)
	elseif kind == "pchecker" then
		if not choice then
			return
		end
		s.errors[row] = editPrompt(state, id, function(store, p)
			if choice == p.id then
				return "An action cannot check itself."
			elseif choice ~= "none" and not promptById(store, choice) then
				return "That action was deleted elsewhere."
			end
			p.checker = if choice == "none" then nil else choice
			return nil
		end)
	elseif kind == "pwhere" or kind == "psplit" then
		local yes = if kind == "pwhere" then "worktree" else "split"
		local no = if kind == "pwhere" then "checkout" else "tab"
		local on = choice == yes
		if not (on or choice == no) then
			return
		end
		s.errors[row] = editPrompt(state, id, function(_, p)
			if kind == "pwhere" then
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
				layout = old.layout,
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
			if #old.prompts > 0 then
				state.cx:toast("info", #old.prompts .. (if #old.prompts == 1 then " offered action cleared" else " offered actions cleared"), old.name .. " is a " .. to.one .. " view now; pick its actions again.")
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
	elseif kind == "vlayout" then
		if choice ~= "list" and choice ~= "board" or not viewOf(state, id) then
			return
		end
		s.errors[row] = updateView(state, id, function(v: View)
			v.layout = if choice == "board" then "board" else nil
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
		if not s.errors[row] then
			propagate(state)
		end
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

-- The confirmed Reset all settings: deletes every settings key (storage.resetAll), then this block and every other one
-- rereads storage and shows the defaults. Keys that could not be deleted are named on the row.
local function resetAll(state: State)
	local s = state.settings
	if not s then
		return
	end
	local failed = storage.resetAll()
	s.edit, s.pick, s.open, s.confirm = nil, nil, nil, nil
	s.errors = {}
	if #failed > 0 then
		s.errors["reset:all"] = "Could not clear: " .. table.concat(failed, ", ")
	end
	state.getStarted = nil
	engine.reloadViews(state)
	propagate(state)
	engine.nowPrefsChanged(state)
	if #failed > 0 then
		state.cx:toast("error", "Some settings were not reset", table.concat(failed, ", "))
	else
		state.cx:toast("success", "Settings reset")
	end
end

-- Deletes what the delete row `s.confirm` names ("delete:<view id>", "pdelete:<prompt id>", "rremove:<repository>",
-- "jremove:<project key>"), or resets every setting ("reset:all").
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
		deleteRepo(state, s, id)
	elseif kind == "jremove" then
		deleteJira(state, s, id)
	elseif kind == "reset" then
		resetAll(state)
	end
end

-- Binds the one-key shortcuts (keys.preset) and says so; why not, or nil. Keys of saved prompt actions are as taken as
-- another action's.
function M.presetKeys(state: State): string?
	local used: { [string]: boolean } = {}
	local err: string? = select(2, keys.load())
	for _, other in { KINDS.prs, KINDS.issues } do
		if err then
			break
		end
		local prompts, bad = loadPrompts(other)
		if not prompts then
			err = bad
			break
		end
		for _, p in prompts.items do
			if p.key then
				used[p.key] = true
			end
		end
	end
	local skipped: { string }? = nil
	if not err then
		skipped, err = keys.preset(used)
	end
	if skipped then
		propagate(state)
		state.cx:toast("success", "One-key shortcuts set", if #skipped > 0 then "Skipped, key in use: " .. table.concat(skipped, ", ") else nil)
	end
	return err
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
	elseif act == "preset-keys" then
		s.errors[row] = M.presetKeys(state)
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
				local added: { [Prompt]: PromptSeed } = {} -- an added default -> its seed
				for _, d in require("../prompts").missing(kind.prompts, store.items) do
					local p: Prompt = { id = "p" .. store.nextId, name = d.name, text = d.text, worktree = d.worktree, split = d.split, model = d.model, outcome = d.outcome }
					table.insert(store.items, p)
					store.nextId += 1
					added[p] = d
				end
				-- A default's checker and next are named by seed id: each is the saved action named like that seed.
				for p, seed in added do
					p.next = seedNext(kind, seed.next, store.items)
					for _, d in kind.prompts do
						if d.id == seed.checker then
							for _, other in store.items do
								if other.name == d.name and other ~= p then
									p.checker = other.id
								end
							end
						end
					end
				end
				return nil
			end)
			if not s.errors[row] then
				propagate(state)
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
			s.focus = if which == "nopen" then "now:blocked" else (first or "") .. (id or "")
		else
			s.open = nil
			s.focus = row
		end
	elseif act == "edit-prompt" then
		beginEdit(state, row)
	elseif act == "delete" or act == "reset-all" then
		-- Asked in the block (render's `deleteConfirm` overlay); its Enter or button runs confirmDelete, Esc or Cancel drops it.
		s.confirm = row
	elseif act == "refresh" then
		retry(state)
	elseif act == "add-repo" then
		state.cx:open("plotroom://repos")
	elseif act == "pick-model" then
		-- The window's picker (window.luau's `pickModel`) asks this block for omp's list; its pick comes back as the row's change.
		local id = string.match(row, "^pmodel:(%a+:[%w]+)$") or (if row == "summary:model" then row else nil)
		if id then
			state.cx:open("plotroom://model/" .. id)
		end
	elseif act == "add-jira" then
		state.cx:open("plotroom://jira-projects")
	elseif act == "guide" then
		for _, c in cli.list do
			if row == "guide:" .. c.id then
				state.cx:open(c.url)
			end
		end
	elseif act == "unignore" then
		local repo, name = string.match(row, "^unignore:([^:]+):(.+)$")
		if repo and name then
			s.errors[row] = storage.editIgnored(repo, function(list: { string })
				local i = table.find(list, name)
				if i then
					table.remove(list, i)
				end
			end)
			if not s.errors[row] then
				s.focus = "radd" -- the removed row is gone
			end
			loadAll(state)
			propagate(state)
		end
	end
end

-- Enter on a row, or a click on its field or popup: edits a text row, presses a button, flips a switch, switches a
-- segmented choice to its next option (its segments show no keyboard highlight), or hands the keys to a menu choice
-- (opened on the current option) or chips row (on its first option).
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
	elseif c.k == "switch" then
		s.focus = row
		M.setValue(state, row, not c.on)
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
	if not e.model.multi and (not def or (text == def.control.value and not string.match(row, "^pname:"))) then
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
	elseif kind == "pstatus" and id then
		local err: string? = nil
		if #text > core.STATUS_CAP or string.find(text, "%c") then
			err = "A status name on one line, at most " .. core.STATUS_CAP .. " characters."
		else
			err = editPrompt(state, id, function(_, p)
				p.status = if text ~= "" then text else nil
				return nil
			end)
		end
		settle(s, row, err)
	elseif kind == "pmodel" and id then
		local err: string? = nil
		if text ~= "" and not worktree.validModel(text) then
			err = "A model such as opus or provider/model-id, or a role such as @slow."
		else
			err = editPrompt(state, id, function(_, p)
				p.model = if text ~= "" then text else nil
				return nil
			end)
		end
		settle(s, row, err)
	elseif kind == "summary" and id == "model" then
		local err: string? = nil
		if text ~= "" and not worktree.validModel(text) then
			err = "A model such as haiku or provider/model-id, or a role such as @smol."
		else
			err = storage.editSummary(function(p)
				p.model = if text ~= "" then text else nil
			end)
			if not err then
				propagate(state)
			end
		end
		settle(s, row, err)
	elseif kind == "pkey" and id then
		local err: string? = keys.shape(text)
		if not err and keys.action((keys.load()), text) then
			err = "The queue already uses " .. text .. "."
		end
		if not err then
			err = editPrompt(state, id, function(store, p)
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
		if text == "" then
			err = if kind == "pname" then "A name is required." else "A prompt is required."
		elseif kind == "pname" and #text > core.NAME_CAP then
			err = "A name is at most " .. core.NAME_CAP .. " characters."
		elseif #text > PROMPT_CAP then
			err = "Over " .. PROMPT_CAP .. " bytes; shorten it."
		else
			err = editPrompt(state, id, function(_, p)
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
		if not err then
			propagate(state)
		end
		if not err and at and text == "" then
			s.focus = "setup:" .. repo .. ":new"
		end
	elseif kind == "branch" and id then
		-- Empty goes back to the default format; anything else must be a format that can name a branch.
		local err = if text == "" then formats.saveRepo(id, nil) else (tracker.formatProblem(text) or formats.saveRepo(id, text))
		settle(s, row, err)
		if not err then
			propagate(state)
		end
	elseif kind == "fmt" and id and formats.KEYS[id] then
		-- Empty goes back to the default; anything else must be a format that can name a branch (or folder).
		local err = if text == "" then formats.save(id, "") else (tracker.formatProblem(text, id ~= "branch") or formats.save(id, text))
		settle(s, row, err)
		if not err then
			propagate(state)
		end
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
		local draft = s.edit
		s.edit = nil
		local busy = engine.claimCheckout(state, repo, path, "A checkout of " .. repo .. " is already being set up.", repo .. "'s checkout was changed or removed while it was being set up", function(claimed, err)
			if not err then
				s.errors[row] = nil
				local cloned = claimed ~= nil and claimed.cloned
				state.cx:toast("success", if cloned then "Cloned " .. repo else "Checkout saved", if claimed then claimed.root else nil)
			elseif state.settings == s and s.page == "repos" and not s.edit and readCheckouts()[key] ~= nil then
				s.open = repo -- its form, should it have been closed meanwhile
				beginEdit(state, row, text) -- the draft stays for a correction; this clears the row's warning, so set it after
				s.errors[row] = err
			else
				state.cx:toast("error", "Checkout not saved", err) -- Settings closed, or the Repositories page that shows the row was left
			end
			state.cx:render()
		end)
		if busy then
			s.edit, s.errors[row] = draft, busy
		end
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
-- a setup page asks again whether the CLIs start, so one installed meanwhile turns its integration on; Actions asks
-- omp again for the models its Model rows offer, as General does for Summary model.
function M.showPage(state: State, s: Settings, page: string)
	M.discardEdit(state)
	s.page, s.focus, s.pick, s.errors = page, nil, nil, {}
	state.settingsPage = page
	if page == "views" then
		ghActive.note(state, true)
	elseif string.find(page, "^setup%-") then
		engine.probeClis(true)
	elseif page == "prompts" or page == "general" then
		M.loadModels(state)
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
		if not err then
			propagate(state)
		end
	elseif kind == "fmt" and id and formats.KEYS[id] then
		err = formats.save(id, "")
		if not err then
			propagate(state)
		end
	elseif (kind == "pmodel" or kind == "pstatus") and id then
		err = editPrompt(state, id, function(_, p)
			if kind == "pmodel" then
				p.model = nil
			else
				p.status = nil
			end
			return nil
		end, true)
	elseif kind == "summary" and id == "model" then
		err = storage.editSummary(function(p)
			p.model = nil
		end)
		if not err then
			propagate(state)
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
	propagate(state)
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
	propagate(state)
	M.openSettings(state, "repos", "jrepos:" .. key, false)
end

-- The name of the action a `next` or checker reference `ref` names, prefixed by its kind ("prs:Watch"): `ids` maps each
-- kind's ids to names. nil for no reference or one that names nothing.
local function refName(kind: Kind, ref: string?, ids: { [string]: { [string]: string } }): string?
	if not ref then
		return nil
	end
	local target, id = storage.nextOf(kind, ref)
	local name = ids[target.id][id]
	return if name then target.id .. ":" .. name else nil
end

-- How many of `kind`'s saved actions (`items`) differ from its default actions: one not named like a default, or named
-- like one but with another prompt, model, effort, status, place, outcome, next action or checker (references compared
-- by the name they lead to), and each default no saved action is named like. A key is counted on General instead.
local function changedActions(kind: Kind, items: { Prompt }, prItems: { Prompt }): number
	local seedIds: { [string]: { [string]: string } } = { prs = {}, issues = {} }
	local savedIds: { [string]: { [string]: string } } = { prs = {}, issues = {} }
	for _, k in { KINDS.prs, KINDS.issues } do
		for _, d in k.prompts do
			seedIds[k.id][d.id] = d.name
		end
	end
	for _, p in prItems do
		savedIds.prs[p.id] = p.name
	end
	for _, p in items do
		savedIds[kind.id][p.id] = p.name
	end
	local function outcome(o: string?): string?
		return if o == "none" then nil else o
	end
	local n = #defaults.missing(kind.prompts, items)
	for _, p in items do
		local d: PromptSeed? = nil
		for _, seed in kind.prompts do
			if seed.name == p.name then
				d = seed
			end
		end
		if
			not d
			or d.text ~= p.text
			or (d.worktree ~= false) ~= (p.worktree ~= false)
			or (d.split == true) ~= (p.split == true)
			or d.model ~= p.model
			or p.effort ~= nil
			or p.status ~= nil
			or outcome(d.outcome) ~= outcome(p.outcome)
			or refName(kind, d.next, seedIds) ~= refName(kind, p.next, savedIds)
			or refName(kind, d.checker, seedIds) ~= refName(kind, p.checker, savedIds)
		then
			n += 1
		end
	end
	return n
end

-- Page id -> how many of the settings, views, actions and formats on that page differ from the defaults, for the
-- count beside each page in Settings' nav. Views: Now's switches and Layout, and the views (as changedActions counts
-- actions: query, group, sort, layout, accounts and actions offered). Actions: the actions. Repositories: the name
-- formats and each repository's checkout and branch format (the rows with a changed dot). General: the keyboard
-- shortcuts, the actions' keys, the Summary settings and where a Draft review opens. A store that cannot be read counts as its defaults.
local function pageChanges(state: State): { [string]: number }
	local now = storage.readNow()
	local views = 0
	for _, r in core.NOW_REASONS do
		views += if now.off[r.id] then 1 else 0
	end
	views += (if now.teams then 1 else 0) + (if now.board then 1 else 0) + (if cli.on("jira") and not now.jira then 1 else 0)
	if cli.on("github") then
		for _, who in ghActive.accounts do
			views += if now.logins[string.lower(who)] then 1 else 0
		end
	end
	for _, kind in { KINDS.prs, KINDS.issues } do
		for _, d in kind.seeds do
			local seen = false
			for _, v in state.views do
				seen = seen or (v.kind == kind.id and v.name == d.name)
			end
			if not seen and cli.on(d.integration) and (not d.sprint or cli.sprints == true) then
				views += 1
			end
		end
	end
	for _, v in state.views do
		local d: core.Seed? = nil
		for _, seed in KINDS[v.kind].seeds do
			if seed.name == v.name then
				d = seed
			end
		end
		if not d or d.integration ~= v.integration or d.query ~= v.query or d.group ~= v.group or d.sort ~= v.sort or v.layout ~= nil or #v.logins > 0 or #v.prompts > 0 then
			views += 1
		end
	end
	local actions, keyed = 0, 0
	local prSaved = if usable(KINDS.prs) then loadPrompts(KINDS.prs) else nil
	for _, kind in { KINDS.prs, KINDS.issues } do
		local saved = if kind == KINDS.prs then prSaved elseif usable(kind) then loadPrompts(kind) else nil
		if saved then
			actions += changedActions(kind, saved.items, if prSaved then prSaved.items else {})
			for _, p in saved.items do
				keyed += if p.key and p.key ~= "" then 1 else 0
			end
		end
	end
	local repos = 0
	for _, f in { "branch", "prdir", "issuedir" } do
		if f ~= "prdir" or cli.on("github") then
			repos += if formats.saved(f) ~= "" then 1 else 0
		end
	end
	for repo, path in readCheckouts() do
		if type(repo) == "string" then
			repos += (if type(path) == "string" and path ~= "" then 1 else 0) + (if formats.repoOf(repo) then 1 else 0)
		end
	end
	local general = keyed
	local map = keys.load()
	for _, a in keys.ACTIONS do
		general += if map[a.id] ~= a.default then 1 else 0
	end
	local summary = storage.readSummary()
	general += (if summary.on then 0 else 1) + (if summary.model then 1 else 0) + (if storage.readReview() then 1 else 0)
	return { views = views, prompts = actions, repos = repos, general = general }
end

function M.settingsView(state: State, palette: Node): BlockView
	local s = state.settings :: Settings
	local sections, extra = pageContent(state)
	local changes = pageChanges(state)
	local pages: { any } = {}
	for _, p in cli.pages() do
		table.insert(pages, { id = p.id, label = p.label, group = p.group, icon = p.icon, changed = changes[p.id] or 0 })
	end
	local props: { [string]: any } = {
		key = "settings",
		title = "Plotroom",
		pages = tern.json.array(pages),
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
			-- Read only: Plotroom appends it to every action's prompt and parses what it asks for (PRODUCT.md › Principles 7).
			ui.node("section", { key = "report", head = { ui.span("End-of-run report · added by Plotroom, not editable", "muted") }, collapsible = true }, {
				ui.node("md", { key = "text", text = "````text\n" .. require("../prompts").REPORT .. "\n````" }),
			}),
		}
		if err then
			table.insert(kids, ui.node("text", { key = "error", spans = { ui.span(err, "error") } }))
		end
		table.insert(
			kids,
			ui.node("row", { key = "buttons", role = "omp.actions" }, {
				ui.node("row", { key = "save", role = "omp.btn", gap = "xs", align = "center", actions = { click = "save-prompt" } }, {
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
	local ask = render.deleteConfirm(state)
	if ask then
		table.insert(layer, ask)
	elseif state.help then
		table.insert(layer, helpOverlay(state))
	end
	return { main = ui.col(rpcNodes(state, palette)), layer = ui.col(layer) }
end

return M
