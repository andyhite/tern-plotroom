--!strict
-- View builders: picker rows, previews, checks, help overlay, sidebar scopes, hidden rpc nodes.
local board = require("../board")
local github = require("../github")
local input = require("../input")
local keys = require("../keys")
local sorting = require("../sorting")
local tracker = require("../tracker")
local worktree = require("../worktree")
local core = require("./core")
local storage = require("./storage")
local engine = require("./engine")

local ui = tern.ui

type DetailFail = core.DetailFail
type KeyHelp = core.KeyHelp
type Note = core.Note
type Prompt = core.Prompt
type Snap = core.Snap
type State = core.State

local CHECK, INTEGRATIONS, ISSUE_ICON, KINDS, MERGE_STATE, REVIEW_BADGE, RPC_PROTOCOL, RUN_ICON, RUN_TONE, SETTINGS_KEYS, STATE_BADGE, VERDICT_ROW, brief, duration, hrefOf, issueBadge, pct, printable, runHrefOf, spans, stateKind, cli = core.CHECK, core.INTEGRATIONS, core.ISSUE_ICON, core.KINDS, core.MERGE_STATE, core.REVIEW_BADGE, core.RPC_PROTOCOL, core.RUN_ICON, core.RUN_TONE, core.SETTINGS_KEYS, core.STATE_BADGE, core.VERDICT_ROW, core.brief, core.duration, core.hrefOf, core.issueBadge, core.pct, core.printable, core.runHrefOf, core.spans, core.stateKind, core.cli
local kindAndId, loadPrompts, promptById, readCheckouts = storage.kindAndId, storage.loadPrompts, storage.promptById, storage.readCheckouts
local TERMINAL, activeView, cancelDetails, codeRepoOf, detailKey, filtered, headOf, helpOf, itemId, offered, openItems, orderedViews, selected, snapKey, viewOf, waitOf, wantDetails, ghActive, me = engine.TERMINAL, engine.activeView, engine.cancelDetails, engine.codeRepoOf, engine.detailKey, engine.filtered, engine.headOf, engine.helpOf, engine.itemId, engine.offered, engine.openItems, engine.orderedViews, engine.selected, engine.snapKey, engine.viewOf, engine.waitOf, engine.wantDetails, engine.ghActive, engine.me

local M = {}

-- The adaptive refresh pace: cooldown while the server holds us back, else the interval and the next refresh (the
-- quota sits under this row). Nothing when no request was sent (invalid query).
function M.paceLine(state: State): string?
	local halted = state.problem
	if halted and TERMINAL[halted.kind] then
		return "Auto-refresh paused: " .. (headOf(state, halted.kind) or halted.kind) .. ". Fix it, then Refresh."
	end
	local now = os.time()
	local wait = waitOf(state)
	if wait > 0 then
		return "Paused by GitHub rate limit until " .. os.date("%H:%M:%S", now + wait)
	elseif state.interval and state.nextAt then
		return "Auto-refresh every " .. duration(state.interval / 1000) .. ", next at " .. os.date("%H:%M", state.nextAt) .. "."
	end
	return nil
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
	}
end

-- An agent's state as a row badge: the window reports it (`agent-status`); an idle or exited agent is no sign the work is done.
local AGENT_BADGE: { [string]: { text: string, tone: string, title: string } } = {
	working = { text = "Working", tone = "accent", title = "An agent is working on it" },
	waiting_input = { text = "Needs input", tone = "warning", title = "Its agent is waiting for your input" },
	idle = { text = "Idle", tone = "muted", title = "Its agent is idle; that does not mean the work is done" },
	exited = { text = "Exited", tone = "muted", title = "Its agent has exited" },
}

-- Puts the triage mark (New, Changed, Snoozed) and the agent's state in front of `row`'s badges.
local function decorate(state: State, kind: string, item: any, row: { [string]: any })
	local extra: { any } = {}
	local agent = AGENT_BADGE[state.agents[item.key] or ""]
	if agent then
		table.insert(extra, agent)
	end
	local st = engine.status(state, kind, item)
	if st and st.snoozed then
		table.insert(extra, { text = "Snoozed", tone = "muted", title = "Snoozed until " .. os.date("%a %H:%M", st.snoozeUntil or 0) })
	elseif st and st.fresh == "new" then
		table.insert(extra, { text = "New", tone = "accent", title = "Not marked seen yet" })
	elseif st and st.fresh == "changed" then
		table.insert(extra, { text = "Changed", tone = "warning", title = "Changed since you marked it seen" })
	end
	if #extra > 0 then
		local badges: { any } = if row.badges then row.badges else {}
		for i, b in extra do
			table.insert(badges, i, b)
		end
		row.badges = badges
	end
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
	local openKey = go .. "|" .. table.concat(ids, ",") .. "|" .. state.rev
	local cached = snap.rows
	if cached and snap.rowsRev == state.noteSeq and snap.rowsMin == minute and snap.rowsOpen == openKey then
		return cached
	end
	local rows: { any } = {}
	local need = 0
	local issues = snap.kind == "issues"
	for _, item in snap.items do
		local isOpen = open[item.key] == true
		local row = if issues then issueRow(item, state.notes[item.key], isOpen, go) else pickerItem(item, state.notes[item.key], isOpen, go)
		decorate(state, snap.kind, item, row)
		if engine.needs(state, snap.kind, item) then
			need += 1
		end
		table.insert(rows, row)
	end
	tern.json.array(rows)
	snap.rows, snap.rowsRev, snap.rowsMin, snap.rowsOpen, snap.need = rows, state.noteSeq, minute, openKey, need
	return rows
end

-- The agent map this block holds as one string, "key=state|action|branch|title;" per entry in key order: the hidden
-- `main.agents` node says it, so a window that sent its map to an earlier run of this block (a reload) sees the block no
-- longer holds it and sends again. flows.luau's `signature` spells it the same.
local function agentSig(state: State): string
	local names: { string } = {}
	for k in state.agents do
		table.insert(names, k)
	end
	table.sort(names)
	local out: { string } = {}
	for _, k in names do
		local info: core.AgentInfo = state.agentInfo[k] or {}
		table.insert(out, k .. "=" .. state.agents[k] .. "|" .. (info.action or "") .. "|" .. (info.branch or "") .. "|" .. (info.title or "") .. ";")
	end
	return table.concat(out)
end

function M.rpcNodes(state: State): { Node }
	local out: { Node } = {
		ui.node("text", { key = "rpc", text = RPC_PROTOCOL, hidden = true }),
		ui.node("text", { key = "agents", text = agentSig(state), hidden = true }),
		-- The command palette's link (its key and button open it), with or without a selected item.
		ui.node("text", { key = "more", href = "plotroom://more", hidden = true }),
	}
	for _, r in state.replies do
		table.insert(out, ui.node("text", { key = "r" .. r.id, text = r.text, hidden = true }))
	end
	local s = state.settings
	if s and s.confirm then
		table.insert(out, ui.node("text", { key = "confirm", text = tern.json.encode(deleteQuestion(state, s.confirm)), hidden = true }))
	end
	return out
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
			props.href = "plotroom://github/check/" .. i .. "/" .. pct(r.url)
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

-- The selected item's actions, each with the link it opens: Open (its page, the preview head's icon), Worktree, Go to
-- tab while a tab works in it, Agent (the picker of the saved prompts offered under this view, or typed text), Go to
-- agent and Seen. A missing repository or checkout is asked for in the window's palette when one is needed. An
-- action's `keys` are its keycap: its configured key (Settings › Keyboard shortcuts); the action bar shows only those
-- that have one.
type Action = { id: string, label: string, keys: { string }?, href: string }
local function itemActions(state: State, item: any, open: { [string]: boolean }): { Action }
	local map = keys.load()
	local out: { Action } = {
		{ id = "open", label = "Open", href = hrefOf(state, item, "open") },
		{ id = "worktree", label = "Worktree", keys = keys.caps(map, "worktree"), href = hrefOf(state, item, "worktree") },
	}
	if open[item.key] then
		table.insert(out, { id = "goto", label = "Go to tab", keys = keys.caps(map, "goto"), href = hrefOf(state, item, "goto") })
	end
	table.insert(out, { id = "agent", label = "Agent", keys = keys.caps(map, "agent"), href = hrefOf(state, item, "agent") })
	-- The window's link to the agent it recorded for this item, offered only while it has reported that agent's state.
	if state.agents[item.key] then
		table.insert(out, { id = "agentgo", label = "Go to agent", keys = keys.caps(map, "agentgo"), href = hrefOf(state, item, "agentgo") })
	end
	-- Triage is the block's own (no link).
	table.insert(out, { id = "seen", label = "Seen", keys = keys.caps(map, "seen"), href = "" })
	return out
end

-- The window honours only links the block shows, so each button's link, and each offered prompt's (its shortcut
-- key runs it), also sits here unseen for the window (and the palette commands) to read.
local function buttonLinks(state: State, item: any, acts: { Action }): Node
	local links: { Node } = {}
	for _, a in acts do
		if a.href ~= "" then
			table.insert(links, ui.node("text", { key = a.id, href = a.href }))
		end
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

-- The pull request whose head is an issue's worktree branch, a link that shows it in this block (window.luau's `showPr`)
-- under a "Pull request" heading; nothing without one. `repo` is where the PR is.
local function headPrNodes(repo: string?, pr: github.HeadPr?): { Node }
	if not pr or not repo then
		return {}
	end
	local look = STATE_BADGE[pr.state] or STATE_BADGE.open
	local what = "#" .. pr.number .. " · " .. look.text
	return {
		ui.node("text", { key = "headpr-head", spans = { ui.span("Pull request", "strong") } }),
		ui.node("list", { key = "headpr" }, {
			ui.node("item", {
				key = "hp1",
				label = pr.title,
				value = "#" .. pr.number,
				icon = if pr.state == "merged" then "check" elseif pr.state == "closed" then "x" else "merge",
				tone = look.tone,
				title = what,
				aria = pr.title .. ", " .. what,
				href = "plotroom://github/show/" .. repo .. "/" .. pr.number,
				actions = { click = "open" },
			}),
		}),
	}
end

-- The issue Plotroom noted for a pull request's worktree: key, title and status, a link that opens it in a Browser
-- block (as the issue's own Open does); nothing without one.
local function notedNodes(issue: tracker.Issue?): { Node }
	if not issue then
		return {}
	end
	local look = issue.status or STATE_BADGE[issue.state] or STATE_BADGE.open
	local ref = tracker.refLabel(issue.ref)
	local what = ref .. " · " .. look.text
	return {
		ui.node("text", { key = "noted-head", spans = { ui.span("Issue", "strong") } }),
		ui.node("list", { key = "noted" }, {
			ui.node("item", {
				key = "issue1",
				label = issue.title,
				value = ref,
				icon = ISSUE_ICON,
				tone = look.tone,
				title = what,
				aria = issue.title .. ", " .. what,
				href = "plotroom://issue/open/" .. pct(issue.url),
				actions = { click = "open" },
			}),
		}),
	}
end

-- The preview's own controls, native action rows: Unpin while the item is pinned (nil otherwise).
local function previewControls(state: State, item: any): Node?
	if engine.pinFor(state.pins, item.key) then
		return ui.node("list", { key = "controls" }, {
			ui.node("item", { key = "unpin", label = "Unpin", icon = "x", aria = "Unpin " .. item.key .. " from the Pins group", actions = { click = "unpin" } }),
		})
	end
	return nil
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
			ui.node("badge", { key = "integration", text = INTEGRATIONS.github.label, tone = "muted" }),
			ui.node("icon", {
				key = "copy",
				name = "copy",
				href = pr.url,
				actions = { click = "copy" },
				title = "Copy link",
				aria = "Copy link to pull request #" .. pr.number,
			}),
			ui.node("icon", {
				key = "open",
				name = "globe",
				href = hrefOf(state, pr, "open"),
				actions = { click = "open" },
				title = "Open in " .. INTEGRATIONS.github.label,
				aria = "Open pull request #" .. pr.number .. " in " .. INTEGRATIONS.github.label,
			}),
			ui.node("col", { key = "fill", grow = 1 }),
			ui.node("badge", { key = "state", text = sb.text, tone = sb.tone }),
		}),
		ui.node("row", { key = "titlerow", gap = "xs", align = "center" }, {
			ui.node("text", { key = "title", spans = { ui.span(pr.title, "strong") } }),
		}),
	}
	local controls = previewControls(state, pr)
	if controls then
		table.insert(out, controls)
	end
	if #chips > 0 then
		table.insert(out, ui.node("row", { key = "chips", gap = "xs", wrap = true }, chips))
	end
	addPart(out, "worktree", worktreeNodes(state, pr.key, acts))
	addPart(out, "noted", notedNodes(if detail then detail.noted else nil))
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
	local branch = if code then (engine.issueNames(issue, code, me.of(state, issue))) else nil
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
			ui.node("badge", { key = "integration", text = INTEGRATIONS[issue.tracker].label, tone = if issue.tracker == "jira" then "accent" else "muted" }),
			ui.node("icon", {
				key = "copy",
				name = "copy",
				href = issue.url,
				actions = { click = "copy" },
				title = "Copy link",
				aria = "Copy link to issue " .. ref,
			}),
			ui.node("icon", {
				key = "open",
				name = "globe",
				href = hrefOf(state, issue, "open"),
				actions = { click = "open" },
				title = "Open in " .. INTEGRATIONS[issue.tracker].label,
				aria = "Open issue " .. ref .. " in " .. INTEGRATIONS[issue.tracker].label,
			}),
			ui.node("col", { key = "fill", grow = 1 }),
			ui.node("badge", { key = "state", text = sb.text, tone = sb.tone }),
		}),
		ui.node("row", { key = "titlerow", gap = "xs", align = "center" }, {
			ui.node("text", { key = "title", spans = { ui.span(issue.title, "strong") } }),
		}),
	}
	local controls = previewControls(state, issue)
	if controls then
		table.insert(out, controls)
	end
	if #chips > 0 then
		table.insert(out, ui.node("row", { key = "chips", gap = "xs", wrap = true }, chips))
	end
	if detail and string.find(detail.body, "%S") then
		addDescription(out, state, issue.key, detail.body)
	end
	addPart(out, "worktree", worktreeNodes(state, issue.key, acts))
	addPart(out, "properties", { ui.node("col", { key = "about", gap = "sm" }, about) })
	addPart(out, "linked", linkedNodes(issue.tracker, detail, fail, loading))
	addPart(out, "headpr", headPrNodes(code, if loaded then loaded.headPr else nil))
	return out
end

function M.helpOverlay(state: State): Node
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

-- The sidebar's scopes in its order, and the id of the one shown: the pins, then the views grouped by integration (and
-- login), then the Worktrees list. Each is { id, label, icon, count, group }; the sidebar and the command palette's Views
-- group both list these rows, and engine.goScope shows one.
function M.scopeRows(state: State): ({ any }, string?)
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
	grouped = grouped or integrations > 1 or #state.pins > 0
	local dropdown = state.cx.cols <= 127
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
			label = if dropdown then INTEGRATIONS[v.integration].label .. (if scope.shown ~= "" then " - " .. scope.shown else "") .. ": " .. v.name else v.name,
			icon = KINDS[v.kind].icon,
			count = if not dropdown and cached then engine.listedCount(state, cached, engine.isPin(v.id)) else nil,
			group = if engine.isPin(v.id) then "Pins" elseif grouped then INTEGRATIONS[v.integration].label .. (if scope.shown ~= "" then " - " .. scope.shown else "") else nil,
		})
	end
	table.insert(scopes, {
		id = "worktrees",
		label = "Worktrees list",
		icon = "folder",
		count = if not dropdown and state.board.loaded then #engine.boardRows(state) else nil,
		group = if grouped then "Worktrees" else nil,
	})
	table.insert(scopes, {
		id = "agents",
		label = "Agents",
		icon = "bot",
		count = if not dropdown then #engine.agentRows(state) else nil,
		group = if grouped then "Agents" else nil,
	})
	if state.boardOn then
		activeScope = "worktrees"
	elseif state.agentsOn then
		activeScope = "agents"
	end
	return scopes, activeScope
end

-- The board's preview of the selected worktree: its folder's name, the pull request and issue it was made for (each as
-- the tracker answered, or why not), its git facts and, hidden, the link the window opens its folder with.
local function boardPreview(state: State): { Node }
	local row, at = engine.boardSelected(state)
	if not row then
		return {}
	end
	local p = board.preview(state.board, row)
	local kids: { Node } = {
		ui.node("row", { key = "titlerow", gap = "xs", align = "center" }, {
			ui.node("text", { key = "title", spans = { ui.span(p.title, "strong") } }),
		}),
	}
	local function section(key: string, head: string, sec: any)
		if not sec then
			return
		end
		table.insert(kids, ui.node("rule", { key = "rule-" .. key }))
		local info = sec.info
		local nodes: { Node } = { ui.node("text", { key = key .. "-head", spans = { ui.span(head .. " " .. sec.ref, "strong") } }) }
		if sec.state == "loading" then
			table.insert(nodes, ui.node("shimmer", { key = key .. "-loading", text = "Loading " .. sec.ref .. "…" }))
		elseif sec.state == "error" then
			table.insert(nodes, ui.node("text", { key = key .. "-problem", spans = { ui.span("Could not read " .. sec.ref .. ": " .. brief(sec.problem or "no answer"), "error") } }))
		elseif sec.state == "empty" or not info then
			table.insert(nodes, ui.node("text", { key = key .. "-empty", spans = { ui.span(sec.ref .. " was not found by its tracker.", "muted") } }))
		else
			table.insert(nodes, ui.node("row", { key = key .. "-title", gap = "xs", align = "center" }, {
				ui.node("text", { key = "t", spans = { ui.span(printable(info.title), "strong") } }),
				ui.node("badge", { key = "state", text = printable(info.state), tone = "muted" }),
			}))
			local facts: { { [string]: any } } = {
				{ k = "Tracker", v = { ui.span(printable(info.tracker), "mono") } },
				{ k = if key == "pr" then "Author" else "Assignee", v = if info.person then { ui.span(printable(info.person)) } else nil },
			}
			table.insert(nodes, ui.node("kv", { key = key .. "-facts", items = withValue(facts) }))
			if info.excerpt then
				table.insert(nodes, ui.node("text", { key = key .. "-excerpt", spans = { ui.span(printable(info.excerpt), "muted") } }))
			end
		end
		table.move(nodes, 1, #nodes, #kids + 1, kids)
	end
	section("pr", "Pull request", p.pr)
	section("issue", "Issue", p.issue)
	local facts: { { [string]: any } } = {}
	for _, f in p.facts do
		local style: string? = if f[1] == "Repository" then "mono" elseif f[1] == "Branch" or f[1] == "Path" or f[1] == "Head" then "code" else nil
		table.insert(facts, { k = f[1], v = { ui.span(f[2], style) } })
	end
	local cleanup = if row.candidate == "merged" then "Its pull request is merged" elseif row.candidate == "closed" then "Its item is closed" elseif row.candidateChecked then "Its item is still open" else nil
	if cleanup then
		table.insert(facts, { k = "Cleanup", v = { ui.span(cleanup) } })
	end
	table.insert(kids, ui.node("rule", { key = "rule-facts" }))
	table.insert(kids, ui.node("kv", { key = "facts", items = withValue(facts) }))
	if row.refused then
		table.insert(kids, ui.node("text", { key = "refused", spans = { ui.span(row.refused, "error") } }))
	end
	table.insert(kids, ui.node("col", { key = "buttons", hidden = true }, { ui.node("text", { key = "wtopen", href = "plotroom://worktrees/open/" .. at }) }))
	return kids
end

-- Only buttons with a key show.
local function keyed(actions: { any }): { any }
	local out: { any } = {}
	for _, a in actions do
		if a.keys then
			table.insert(out, a)
		end
	end
	return out
end

-- Turns the queue's picker props into the Worktrees board's: its rows, subtitle and action bar.
local function boardProps(state: State, props: { [string]: any })
	local items, order = engine.boardItems(state)
	local row = engine.boardSelected(state)
	local map = keys.load()
	local rows = engine.boardRows(state)
	local sub: { any } = {}
	if state.boardBusy then
		local busy: any = ui.span("Reading checkouts…", "muted")
		busy.fx = "shimmer"
		table.insert(sub, busy)
	else
		table.insert(sub, ui.span(#rows .. " worktree" .. (if #rows == 1 then "" else "s"), "muted"))
	end
	for i, p in state.board.problems do
		if i <= 2 then
			table.insert(sub, ui.span(" · ", "muted"))
			table.insert(sub, ui.span(p, "warning"))
		end
	end
	local removable = row and not row.main and not row.locked and not row.missing
	props.icon, props.title, props.subtitle, props.noun = "folder", { ui.span("Worktrees", "strong") }, sub, "worktrees"
	props.placeholder = "Worktrees are not searched"
	props.state = if state.boardBusy and not state.board.loaded then "loading" else "ready"
	props.empty = { ui.span(if next(readCheckouts()) == nil then "No saved checkouts yet: add a repository's checkout in Settings." else "No worktrees found.", "muted") }
	props.items, props.order, props.hits, props.message = tern.json.array(items), tern.json.array(order), nil, nil
	props.selected = if row then engine.boardId(row) else nil
	props.columns, props.query, props.cursor = {}, nil, nil
	local actions: { any } = {
		{ id = "settings", label = "Settings", keys = keys.caps(map, "settings") },
		{ id = "retry", label = "Refresh", keys = keys.caps(map, "refresh"), disabled = if state.boardBusy then "Reading…" else nil },
		{ id = "more", label = "Commands", keys = keys.caps(map, "more") },
		{ id = "wt-cleanup", label = "Find cleanup", keys = keys.caps(map, "wt-cleanup"), ["end"] = true, disabled = if state.boardBusy then "Reading…" else nil },
		{ id = "wt-remove", label = "Remove", keys = keys.caps(map, "wt-remove"), ["end"] = true, disabled = if removable then nil else "The main, locked or missing worktrees are not removed here" },
	}
	props.actions = keyed(actions)
end

-- The Agents scope's preview of the selected agent: its item, its action, branch and state, and, hidden, the link the window
-- goes to its tab with.
local function agentsPreview(state: State): { Node }
	local row = engine.agentSelected(state)
	if not row then
		return {}
	end
	local badge = AGENT_BADGE[row.state]
	local href = engine.agentHref(row.key)
	local facts: { { [string]: any } } = withValue({
		{ k = "Item", v = { ui.span(printable(row.key), "mono") } },
		{ k = "Action", v = if row.action then { ui.span(printable(row.action)) } else nil },
		{ k = "Branch", v = if row.branch then { ui.span(printable(row.branch), "code") } else nil },
	})
	local kids: { Node } = {
		ui.node("row", { key = "titlerow", gap = "xs", align = "center" }, {
			ui.node("text", { key = "title", spans = { ui.span(printable(row.title or row.key), "strong") } }),
			ui.node("badge", { key = "state", text = badge.text, tone = badge.tone, title = badge.title }),
		}),
		ui.node("kv", { key = "facts", items = facts }),
	}
	if href then
		table.insert(kids, ui.node("col", { key = "buttons", hidden = true }, { ui.node("text", { key = "agentgo", href = href }) }))
	end
	return kids
end

-- Turns the queue's picker props into the Agents scope's: a group per repository, each agent's item, action, branch and state.
local function agentsProps(state: State, props: { [string]: any })
	local rows = engine.agentRows(state)
	local current = engine.agentSelected(state)
	local map = keys.load()
	local items: { any } = {}
	local order: { any } = {}
	local groups: { [string]: { any } } = {}
	local names: { string } = {}
	for _, row in rows do
		local label = printable(row.title or row.key)
		local detail: { any } = {}
		if row.action then
			table.insert(detail, ui.span(printable(row.action)))
		end
		if row.branch then
			table.insert(detail, if #detail > 0 then " · " else "")
			table.insert(detail, ui.span(printable(row.branch), "mono"))
		end
		if #detail == 0 then
			detail = { ui.span(printable(row.key), "mono") }
		end
		local id = engine.agentId(row)
		table.insert(items, { id = id, label = label, title = label, detail = detail, badges = { AGENT_BADGE[row.state] } })
		if not groups[row.repo] then
			groups[row.repo] = {}
			table.insert(names, row.repo)
		end
		table.insert(groups[row.repo], id)
	end
	for _, name in names do
		table.insert(order, { group = name, label = name, count = #groups[name] })
		for _, id in groups[name] do
			table.insert(order, id)
		end
	end
	props.icon, props.title, props.noun = "bot", { ui.span("Agents", "strong") }, "agents"
	props.subtitle = { ui.span(#rows .. " agent" .. (if #rows == 1 then "" else "s"), "muted") }
	props.placeholder = "Agents are not searched"
	props.state = "ready"
	props.empty = { ui.span("No agents are running. Start one from a pull request or issue.", "muted") }
	props.items, props.order, props.hits, props.message = tern.json.array(items), tern.json.array(order), nil, nil
	props.selected = if current then engine.agentId(current) else nil
	props.columns, props.query, props.cursor = {}, nil, nil
	props.actions = keyed({
		{ id = "settings", label = "Settings", keys = keys.caps(map, "settings") },
		{ id = "more", label = "Commands", keys = keys.caps(map, "more") },
		{ id = "agentgo", label = "Go to agent", keys = keys.caps(map, "agentgo"), ["end"] = true, disabled = if current then nil else "No agent is listed" },
	})
end

-- The queue's picker; also drawn under Settings' side sheet, where keys go to Settings (so no search caret).
function M.queuePicker(state: State): Node
	local snap, problem, view, item = state.snap, state.problem, activeView(state), selected(state)
	local vis = filtered(state)
	local open = openItems(state)
	local items: { any } = if snap then rowsOf(state, snap, open) else tern.json.array({})
	local order: { any } = if vis then vis.order else tern.json.array({})

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
	-- Sort order and the attention filter share the bottom row with the actions (plotroom.css).
	local strip: { string } = {}
	if state.attention then
		table.insert(strip, "Needs attention only")
	end
	if view and not engine.isPin(view.id) then
		-- Always shown, attention filter or not: which order the list is in. A view with no saved sort keeps the search's own.
		table.insert(strip, 1, "Sort: " .. (if view.sort then sorting.label(view.sort) elseif view.kind == "issues" then "Default (status order)" else "Default (search order)"))
	end
	if state.showSnoozed then
		note(ui.span("Snoozed shown", "muted"))
	end
	if snap and snap.need and snap.need > 0 then
		note(ui.span(snap.need .. " need attention", "accent"))
	end
	if state.triageProblem then
		note(ui.span(state.triageProblem, "error"))
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

	local dropdown = state.cx.cols <= 127
	local scopes, activeScope = M.scopeRows(state)

	local wait = waitOf(state)
	local map = keys.load()
	local acts: { Action } = if item then itemActions(state, item, open) else {}
	-- Only buttons with a key show: Settings and Refresh on the left, the selected item's on the right, the command
	-- palette last in the corner.
	local all: { any } = {
		{ id = "settings", label = "Settings", keys = keys.caps(map, "settings") },
		{
			id = "retry",
			label = "Refresh",
			keys = keys.caps(map, "refresh"),
			disabled = if wait > 0 then "Paused by GitHub until " .. os.date("%H:%M:%S", os.time() + wait) else nil,
		},
	}
	for _, a in acts do
		table.insert(all, { id = a.id, label = a.label, keys = a.keys, ["end"] = true })
	end
	table.insert(all, { id = "more", label = "Commands", keys = keys.caps(map, "more"), primary = true })
	local actions = keyed(all)

	-- Neither integration is on: the setup pages in Settings are all there is.
	local none = cli.ready() and not cli.on("github") and not cli.on("jira")

	local props: { [string]: any } = {
		key = "queue",
		-- plotroom.css narrows the queue by the Settings sheet's width (`.aside`), so the sheet sits beside it, not over it,
		-- and folds the scope rail into its dropdown at 127 columns or fewer (`.narrow`: the block's own width).
		role = "plotroom.queue" .. (if state.settings then ".aside" else "") .. (if dropdown then ".narrow" else "") .. (if not state.boardOn and not state.agentsOn and #strip > 0 then ".footer-status" else ""),
		size = "screen",
		layout = "cards",
		preview = "none",
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
						.. (if map.settings ~= "" then "Press " .. map.settings .. " to "
							elseif map.more ~= "" then "Press " .. map.more .. " and pick Settings to "
							else "Open Settings to ")
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
	local preview: { Node }
	if state.boardOn then
		cancelDetails(state) -- no checks load for a queue preview that is not shown
		preview = boardPreview(state)
		boardProps(state, props)
	elseif state.agentsOn then
		cancelDetails(state)
		preview = agentsPreview(state)
		agentsProps(state, props)
	else
		preview = if state.kind.id == "issues" then issuePreview(state, item, open, acts) else previewNodes(state, item, open, acts)
		if #strip > 0 then
			props.strip = { label = table.concat(strip, " · "), items = tern.json.array({}) }
		end
	end
	-- Tern: `preview = "none"` hides the pane; with no children it would say "Nothing to preview" in a big pane.
	props.preview = if props.selected then "side" else "none"
	return ui.node("picker", props, if props.selected then preview else {})
end

-- The Keep/Remove modal both worktree removals ask with: `tabbed` adds the warning that a tab works in the folder.
local function removeOverlay(head: string, body: string, facts: { { [string]: any } }, tabbed: any, keepAct: string, dropAct: string): Node
	local kids: { Node } = {
		ui.node("text", { key = "body", spans = { ui.span(body, "muted") } }),
		ui.node("kv", { key = "facts", items = facts }),
	}
	if tabbed then
		table.insert(kids, ui.node("text", { key = "tab", spans = { ui.span("A tab works in it and will be left in a folder that no longer exists.", "warning") } }))
	end
	table.insert(kids, ui.node("list", { key = "buttons" }, {
		ui.node("item", { key = "keep", label = "Keep", icon = "check", hint = { "enter" }, actions = { click = keepAct } }),
		ui.node("item", { key = "delete", label = "Remove", icon = "trash", tone = "error", hint = { "d" }, actions = { click = dropAct } }),
	}))
	return ui.node("overlay", { key = "confirm", modal = true, size = "sm", head = head }, kids)
end

-- The modal that asks before a board row's worktree is removed; Enter or Esc keeps it, `d` or a click removes it.
local function boardConfirm(state: State): Node
	local row: any = nil
	for _, r in engine.boardRows(state) do
		if r.id == state.boardRemoving then
			row = r
		end
	end
	local facts = withValue({
		{ k = "Path", v = if row then { ui.span(row.path, "code") } else nil },
		{ k = "Branch", v = if row and row.branch then { ui.span(row.branch, "code") } else nil },
	})
	local body = "Its folder is deleted, then its branch unless that holds commits saved nowhere else. Git refuses while the worktree has uncommitted changes, and nothing is forced. Press d to remove it; Enter or Esc keeps it."
	return removeOverlay("Remove this worktree?", body, facts, row and engine.boardOpen(state)[row.path], "wt-cancel-remove", "wt-confirm-remove")
end

function M.queueView(state: State): BlockView
	local layer: { Node } = { M.queuePicker(state) }
	local removing = state.removing
	local note = if removing then state.notes[removing] else nil
	if removing and note then
		-- A worktree's removal, asked from its card: where it is, and a warning while a tab works in it.
		local facts = withValue({
			{ k = "Path", v = if note.path then { ui.span(note.path, "code") } else nil },
			{ k = "Branch", v = if note.branch then { ui.span(note.branch, "code") } else nil },
		})
		local body = "Its folder is deleted, then its branch unless that holds commits saved nowhere else. Git refuses while the worktree has uncommitted changes. Press d to remove it; Enter or Esc keeps it."
		table.insert(layer, removeOverlay("Remove worktree?", body, facts, openItems(state)[removing], "cancel-remove", "confirm-remove"))
	elseif state.boardOn and state.boardRemoving then
		table.insert(layer, boardConfirm(state))
	elseif state.help then
		table.insert(layer, M.helpOverlay(state))
	end
	return { main = ui.col(M.rpcNodes(state)), layer = ui.col(layer) }
end

return M
