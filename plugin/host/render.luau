--!strict
-- View builders: picker rows, previews, checks, help overlay, sidebar scopes, hidden rpc nodes.
local board = require("../board")
local github = require("../github")
local input = require("../input")
local keys = require("../keys")
local tracker = require("../tracker")
local triage = require("../triage")
local worktree = require("../worktree")
local usage = require("../usage")
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

local CHECK, INTEGRATIONS, ISSUE_ICON, KINDS, MERGE_STATE, REVIEW_BADGE, RPC_PROTOCOL, RUN_ICON, RUN_TONE, SETTINGS_KEYS, STAGE, STATE_BADGE, VERDICT_ROW, brief, duration, hrefOf, issueBadge, pct, printable, runHrefOf, spans, stateKind, cli = core.CHECK, core.INTEGRATIONS, core.ISSUE_ICON, core.KINDS, core.MERGE_STATE, core.REVIEW_BADGE, core.RPC_PROTOCOL, core.RUN_ICON, core.RUN_TONE, core.SETTINGS_KEYS, core.STAGE, core.STATE_BADGE, core.VERDICT_ROW, core.brief, core.duration, core.hrefOf, core.issueBadge, core.pct, core.printable, core.runHrefOf, core.spans, core.stateKind, core.cli
local kindAndId, loadPrompts, promptById, readCheckouts = storage.kindAndId, storage.loadPrompts, storage.promptById, storage.readCheckouts
local TERMINAL, activeView, cancelDetails, codeRepoOf, detailKey, filtered, headOf, helpOf, pickerId, offered, openItems, orderedViews, selected, snapKey, viewOf, waitOf, wantDetails, ghActive, me = engine.TERMINAL, engine.activeView, engine.cancelDetails, engine.codeRepoOf, engine.detailKey, engine.filtered, engine.headOf, engine.helpOf, engine.pickerId, engine.offered, engine.openItems, engine.orderedViews, engine.selected, engine.snapKey, engine.viewOf, engine.waitOf, engine.wantDetails, engine.ghActive, engine.me

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
	elseif kind == "reset" then
		return {
			row = row,
			head = "Reset all settings?",
			label = "Reset all settings",
			detail = "Clears views, actions, shortcuts, repositories, branch and folder formats and Get started in every Plotroom pane; keeps triage, usage and agents",
		}
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

-- What a worktree's badge says on hover: its attempt's summary and where it is.
local function noteTitle(note: Note): string
	return (note.summary or "Worktree ready") .. (if note.path then " · " .. note.path else "")
end

-- The badge of stage `id` (engine.stage); a Worktree stage takes its worktree's tone and summary, a Blocked one says why.
local function stageBadge(id: string, why: string?, note: Note?): { text: string, tone: string?, title: string? }
	if id == "worktree" and note then
		return { text = STAGE.worktree.text, tone = noteTone(note), title = noteTitle(note) }
	end
	local b = STAGE[id]
	return if why then { text = b.text, tone = b.tone, title = why } else b
end

-- The Worktree badge an item's row starts with, left to the stage badge when that says Worktree.
local function worktreeBadges(note: Note?, stage: string): { any }
	local badges: { any } = {}
	if note and note.ok and stage ~= "worktree" then
		table.insert(badges, { text = "Worktree", tone = noteTone(note), title = noteTitle(note) })
	end
	return badges
end

-- The picker row `key` shows: only what decides at the list level (LEDGER.md › Picker rows); labels, age, the
-- review and the checks are the preview's.
local function finishRow(key: string, title: string, author: string, detail: { any }, badges: { any }): { [string]: any }
	return {
		id = pickerId("n", key),
		label = title,
		title = title,
		detail = detail,
		mark = { text = author },
		badges = if #badges > 0 then badges else nil,
	}
end

-- "#N", then " · repo" when `repos` (the view spans more than one repository).
local function refDetail(ref: string, repo: string?, repos: boolean): { any }
	local detail: { any } = { ui.span(ref, "num") }
	if repos and repo then
		table.insert(detail, " · ")
		table.insert(detail, ui.span(repo, "mono"))
	end
	return detail
end

-- A pull request's picker row: "#N · repo · <what blocks it>", or "New commits since you approved" when its head moved
-- after your approval; its stage says Merged or Closed, so only Draft is left of its state.
local function pickerItem(pr: github.Pr, note: Note?, stage: string, why: string?, repos: boolean): { [string]: any }
	local badges = worktreeBadges(note, stage)
	if stateKind(pr) == "draft" then
		table.insert(badges, STATE_BADGE.draft)
	end
	local detail = refDetail("#" .. pr.number, pr.repo, repos)
	if why then
		table.insert(detail, " · ")
		table.insert(detail, ui.span(why, "error"))
	elseif pr.newCommits then
		table.insert(detail, " · ")
		table.insert(detail, ui.span("New commits since you approved", "warning"))
	end
	return finishRow(pr.key, pr.title, pr.author, detail, badges)
end

-- An issue's picker row: "#N · repo" (Jira: "ABC-12 · Type", the key already names its project); its workflow status
-- or why it closed (the stage already says Closed).
local function issueRow(issue: tracker.Issue, note: Note?, stage: string, repos: boolean): { [string]: any }
	local badges = worktreeBadges(note, stage)
	local sb = issueBadge(issue)
	if issue.status or (issue.state == "closed" and sb ~= STATE_BADGE.closed) then
		table.insert(badges, sb)
	end
	local detail = refDetail(tracker.refLabel(issue.ref), if issue.tracker == "github" then issue.repo else nil, repos)
	if issue.type then
		table.insert(detail, " · " .. issue.type)
	end
	return finishRow(issue.key, issue.title, issue.author, detail, badges)
end

-- An agent's state as a row badge: the window reports it (`agent-status`); an idle or exited agent is no sign the work is done.
local AGENT_BADGE: { [string]: { text: string, tone: string, title: string } } = {
	working = { text = "Working", tone = "accent", title = "An agent is working on it" },
	waiting_input = { text = "Needs input", tone = "warning", title = "Its agent is waiting for your input" },
	idle = { text = "Idle", tone = "muted", title = "Its agent is idle; that does not mean the work is done" },
	exited = { text = "Exited", tone = "muted", title = "Its agent has exited" },
}

-- An agent's last end-of-run report as a badge: the agent's claim, never a sign the work is done.
local REPORT_BADGE: { [string]: { text: string, tone: string, title: string } } = {
	ok = { text = "Report: ok", tone = "muted", title = "Its agent reported nothing blocks it; a claim, not a check" },
	stuck = { text = "Report: stuck", tone = "error", title = "Its agent reported it cannot go on" },
	["needs-human"] = { text = "Report: needs human", tone = "warning", title = "Its agent reported it waits for you" },
	none = { text = "No report", tone = "muted", title = "Its agent's last turn ended without a valid end-of-run report" },
}

-- What checking a run's outcome on GitHub found, as a badge naming the outcome (prompts.OUTCOMES); nil when the action
-- names none or no check has answered yet.
local VERDICT_BADGE: { [string]: { text: string, tone: string, title: string } } = {
	verified = { text = "Verified", tone = "success", title = "GitHub shows what the run must leave behind: " },
	["not"] = { text = "Not verified", tone = "warning", title = "GitHub does not show what the run must leave behind: " },
	unchecked = { text = "Unchecked", tone = "muted", title = "GitHub could not be read, so it is checked again at the next refresh: " },
}
local function verdictBadge(info: { outcome: string?, verdict: string? }?): { text: string, tone: string, title: string }?
	local label = if info then require("../prompts").outcomeLabel(info.outcome) else nil
	local b = if info and label then VERDICT_BADGE[info.verdict or ""] else nil
	return if b and label then { text = b.text, tone = b.tone, title = b.title .. label } else nil
end

-- The Outcome fact: "<outcome>: <verdict>", nil when verdictBadge has none.
local function verdictText(info: { outcome: string?, verdict: string? }?): string?
	local b = verdictBadge(info)
	local label = if info then require("../prompts").outcomeLabel(info.outcome) else nil
	return if b and label then label .. ": " .. b.text else nil
end

-- What a checker found on the run it checked (`check`), as a badge; nil while there is no verdict.
local CHECK_BADGE: { [string]: { text: string, tone: string, title: string } } = {
	pass = { text = "Checked", tone = "success", title = "A fresh agent checked the work against the acceptance criteria and found every one met" },
	fail = { text = "Check failed", tone = "warning", title = "A fresh agent checked the work against the acceptance criteria and found what fails" },
}
local function checkBadge(info: { check: string? }?): { text: string, tone: string, title: string }?
	return if info then CHECK_BADGE[info.check or ""] else nil
end

-- Puts the stage, the agent's state (when the stage does not already say it) and the triage mark (New, Changed,
-- Snoozed) in front of `row`'s badges. The stage badge carries no reason: a Blocked row's detail says what blocks it.
local function decorate(state: State, kind: string, item: any, row: { [string]: any }, stage: string)
	local extra: { any } = { stageBadge(stage, nil, state.notes[item.key]) }
	local agent = AGENT_BADGE[state.agents[item.key] or ""]
	if agent and stage ~= "working" and stage ~= "needs" then
		table.insert(extra, agent)
	end
	local info = if state.agents[item.key] and state.agents[item.key] ~= "exited" then state.agentInfo[item.key] else nil
	local verdict, checked = verdictBadge(info), checkBadge(info)
	if verdict then
		table.insert(extra, verdict)
	end
	if checked then
		table.insert(extra, checked)
	end
	local st = engine.status(state, kind, item)
	if st and st.snoozed then
		table.insert(extra, { text = "Snoozed", tone = "muted", title = "Snoozed until " .. os.date("%a %H:%M", st.snoozeUntil or 0) })
	elseif st and st.fresh == "new" then
		table.insert(extra, { text = "New", tone = "accent", title = "Not marked seen yet" })
	elseif st and st.fresh == "changed" then
		table.insert(extra, { text = "Changed", tone = "warning", title = "Changed since you marked it seen" })
	end
	local badges: { any } = if row.badges then row.badges else {}
	for i, b in extra do
		table.insert(badges, i, b)
	end
	row.badges = badges
end

local BAR_CELLS = 10

-- A working agent's thin bar of how far along it probably is (engine.agentClock; only when its action has runs enough to
-- expect a duration) and its clock, m:ss; nil when the agent of item `key` is not working. The view redraws itself
-- a second later (queuePicker), and nothing on it animates.
local function agentClock(state: State, key: string): { any }?
	local elapsed, fraction = engine.agentClock(state, key)
	if not elapsed then
		return nil
	end
	state.clocked = true
	local out: { any } = {}
	if fraction then
		local filled = math.floor(fraction * BAR_CELLS) -- 95% is 9 of 10: never a full bar before the run ends
		if filled > 0 then
			table.insert(out, ui.span(string.rep("━", filled), "accent"))
		end
		if filled < BAR_CELLS then
			table.insert(out, ui.span(string.rep("━", BAR_CELLS - filled), "muted"))
		end
		table.insert(out, " ")
	end
	table.insert(out, ui.span(string.format("%d:%02d", elapsed // 60, elapsed % 60), "num"))
	return out
end

-- The facts that have a value; a row without one is not shown.
local function withValue(facts: { { [string]: any } }): { { [string]: any } }
	local out = {}
	for _, f in facts do
		if f.v ~= nil then
			table.insert(out, f)
		end
	end
	return out
end

-- The status part of a PR's or issue's preview (what blocks it or needs you), under its next move: the item's stage,
-- toned as its row badge, what blocks it, how long its agent has worked (while it works), its agent's checked outcome
-- and what its checker found (a failed check lists
-- its findings), then `lead`, the facts its stage acts on first (a review asked of you: its author).
local function stageFact(state: State, kind: string, item: any, lead: { { [string]: any } }?): Node
	local id, why = engine.stage(state, kind, item)
	local b = stageBadge(id, why, state.notes[item.key])
	local items: { { [string]: any } } = { { k = "Stage", v = { ui.span(b.text, b.tone) } } }
	if id == "blocked" and why then
		table.insert(items, { k = "Blocked by", v = { ui.span(why, "error") } })
	end
	table.insert(items, { k = "Working", v = agentClock(state, item.key) })
	local live = state.agents[item.key] and state.agents[item.key] ~= "exited"
	local info = if live then state.agentInfo[item.key] else nil
	if verdictBadge(info) then
		table.insert(items, { k = "Outcome", v = { ui.span(verdictText(info) :: string, (verdictBadge(info) :: any).tone) } })
	end
	local c = checkBadge(info)
	if c and info then
		table.insert(items, { k = "Check", v = { ui.span(c.text, c.tone) } })
		if info.check == "fail" and info.findings then
			table.insert(items, { k = "Findings", v = { ui.span(printable(info.findings)) } })
		end
	end
	if lead then
		for _, f in lead do
			table.insert(items, f)
		end
	end
	return ui.node("kv", { key = "stage", items = withValue(items) })
end

-- The picker rows of a snapshot, built once: again only when a worktree report arrives, the block's state changes or
-- the minute does (a snooze ends).
local function rowsOf(state: State, snap: Snap): { any }
	local minute = os.time() // 60
	local cached = snap.rows
	if cached and snap.rowsRev == state.noteSeq and snap.rowsMin == minute and snap.rowsState == state.rev then
		return cached
	end
	-- A repository is worth a row's room only when the rows span more than one.
	local repos, first = false, nil
	for _, item in snap.items do
		local repo = item.repo or ""
		first = first or repo
		if repo ~= first then
			repos = true
			break
		end
	end
	local rows: { any } = {}
	local issues = snap.kind == "issues"
	for _, item in snap.items do
		local stage, why = engine.stage(state, snap.kind, item)
		local row = if issues then issueRow(item, state.notes[item.key], stage, repos) else pickerItem(item, state.notes[item.key], stage, why, repos)
		decorate(state, snap.kind, item, row, stage)
		table.insert(rows, row)
	end
	tern.json.array(rows)
	snap.rows, snap.rowsRev, snap.rowsMin, snap.rowsState = rows, state.noteSeq, minute, state.rev
	return rows
end

-- The agent map this block holds as one string, "key=state|action|branch|title|last|err|result|ended|attention|reason|blocker|outcome|verdict|check|findings|stop|since|expected;"
-- per entry in key order: the hidden `main.agents` node says it, so a window that sent its map to an earlier run of this
-- block (a reload) sees the block no longer holds it and sends again. flows.luau's `signature` spells it the same.
local function agentSig(state: State): string
	local names: { string } = {}
	for k in state.agents do
		table.insert(names, k)
	end
	table.sort(names)
	local out: { string } = {}
	for _, k in names do
		local info: core.AgentInfo = state.agentInfo[k] or {}
		table.insert(out, k .. "=" .. state.agents[k] .. "|" .. (info.action or "") .. "|" .. (info.branch or "") .. "|" .. (info.title or "") .. "|" .. (info.last or "") .. "|" .. (info.err or "") .. "|" .. (info.result or "") .. "|" .. (info.ended or "") .. "|" .. (info.attention or "") .. "|" .. (info.reason or "") .. "|" .. (info.blocker or "") .. "|" .. (info.outcome or "") .. "|" .. (info.verdict or "") .. "|" .. (info.check or "") .. "|" .. (info.findings or "") .. "|" .. (info.stop or "") .. "|" .. (info.since or "") .. "|" .. (info.expected or "") .. ";")
	end
	return table.concat(out)
end

-- `palette`: requests' paletteNode (render cannot require requests).
function M.rpcNodes(state: State, palette: Node): { Node }
	local out: { Node } = {
		ui.node("text", { key = "rpc", text = RPC_PROTOCOL, hidden = true }),
		ui.node("text", { key = "agents", text = agentSig(state), hidden = true }),
		-- How many need you (Now's rows not snoozed): the sidebar counts it, and the window's status line takes it.
		ui.node("text", { key = "need", text = tostring(engine.nowCount(state)), hidden = true }),
		-- The command palette's link (its key and button open it), with or without a selected item.
		ui.node("text", { key = "more", href = "plotroom://more", hidden = true }),
		palette,
		-- This host's usage counts (usage.luau), for the window's Copy usage report.
		ui.node("text", { key = "usage", text = usage.published(), hidden = true }),
		-- The block's size in cells, `<cols>x<rows>`: the window's agent placement derives the tab's shape from it.
		ui.node("text", { key = "size", text = state.cx.cols .. "x" .. state.cx.rows, hidden = true }),
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

-- What a click does is drawn on the node itself (plotroom.css): an action is a button (BUTTON, a ring sized to its label),
-- a row or icon that opens something is a link (LINK, the accent label). A node with no click and no href has neither.
local BUTTON, LINK = "plotroom.button", "plotroom.link"

-- An action `item` drawn as a button; `p` is its props.
local function button(p: { [string]: any }): Node
	p.role, p.basis = BUTTON, "content"
	return ui.node("item", p)
end

-- Buttons side by side, wrapping when the preview is narrow (a list would stretch each ring across the row).
local function buttonRow(key: string, buttons: { Node }): Node
	return ui.node("row", { key = key, gap = "sm", wrap = true, align = "center" }, buttons)
end

-- One section of a preview whose rows load, the same for every section: its heading, then while loading Tern's shimmer
-- (`Loading <what>…`), after a failed detail load (`fail`) why, when it is tried again and a Retry button, after another
-- failed read (`problem`, retried by its own Refresh) why, else `body` or, with nothing in it, `No <what>`. `key`
-- prefixes each node's key.
type Load = { loading: boolean?, fail: DetailFail?, problem: string? }
local function section(key: string, head: string, what: string, body: { Node }, load: Load): { Node }
	local out: { Node } = { ui.node("text", { key = key .. "-head", spans = { ui.span(head, "strong") } }) }
	local fail = load.fail
	if load.loading then
		table.insert(out, ui.node("shimmer", { key = key .. "-loading", text = "Loading " .. what .. "…" }))
		return out
	elseif fail then
		local when = if fail.retryAt then "Trying again at " .. os.date("%H:%M:%S", fail.retryAt) .. "." else "Retry to load them."
		table.insert(out, ui.node("text", { key = key .. "-state", spans = { ui.span("Could not load " .. what .. ": " .. brief(fail.problem.message), "error"), ui.span("  " .. when, "muted") } }))
		table.insert(out, button({ key = key .. "-retry", label = "Retry", icon = "redo", aria = "Retry loading " .. what, actions = { click = "retry-checks" } }))
	elseif load.problem then
		table.insert(out, ui.node("text", { key = key .. "-state", spans = { ui.span("Could not load " .. what .. ": " .. brief(load.problem), "error") } }))
	elseif #body == 0 then
		table.insert(out, ui.node("text", { key = key .. "-empty", spans = { ui.span("No " .. what, "muted") } }))
	end
	table.move(body, 1, #body, #out + 1, out)
	return out
end

-- The Checks section of the selected PR (`section`): what the search carried stays listed under a failed load.
local function checksNodes(state: State, pr: github.Pr): { Node }
	local out: { Node } = {}
	local key = detailKey(state, pr)
	local d = if key then state.details[key] else nil
	local fail = if key then state.detailFail[key] else nil
	local runs: { github.Run } = if d then d.runs else pr.runs
	local total = if d then d.total else pr.runTotal

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
			props.actions, props.role = { click = "open" }, LINK
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
	return section("runs", "Checks", "checks", out, { loading = key ~= nil and d == nil and fail == nil, fail = fail })
end

-- The selected item's actions, each with the link it opens: Open (its page, the preview head's icon), Worktree, Go to
-- tab while a tab works in it, Agent (the picker of the saved prompts offered under this view, or typed text), Go to
-- agent and Seen. A missing repository or checkout is asked for in the window's palette when one is needed. An
-- action's `keys` are its keycap: its configured key (Settings › General), which the worktree card's rows show.
local AGENT_COMMANDS = { "agentint", "agentstop", "agentmsg" } -- Interrupt, Stop and Message the selected item's live agent
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
	-- The agent commands (palette only, no key): linked only while the agent is not exited.
	if state.agents[item.key] and state.agents[item.key] ~= "exited" then
		for _, act in AGENT_COMMANDS do
			table.insert(out, { id = act, label = act, href = hrefOf(state, item, act) })
		end
	end
	-- Disagree with check… (palette only): while the item's newest agent is a checker with a verdict, exited or not.
	if (state.agentInfo[item.key] or {} :: core.AgentInfo).check then
		table.insert(out, { id = "agentdisagree", label = "agentdisagree", href = hrefOf(state, item, "agentdisagree") })
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
	if engine.cardPath(state) then
		table.insert(links, ui.node("text", { key = "git", href = core.withToken(core.GIT_LINK) }))
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
			role = BUTTON,
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
	local ahead = note.ahead or 0
	if ahead > 0 then
		table.insert(chips, ui.node("badge", { key = "ahead", text = ahead .. " unpushed", tone = "warning", title = "Commits on this branch its upstream does not have" }))
	end
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
	-- Buttons sized to their label, left to right: the tab, then Remove.
	local buttons: { Node } = {}
	if tab then
		table.insert(buttons, button({ key = "go", label = "Go to tab", icon = "arrow-right", hint = tab.keys, aria = "Go to the tab working in this worktree", actions = { click = "goto" } }))
	else
		table.insert(buttons, button({ key = "open", label = "Open in new tab", icon = "plus", hint = if fresh then fresh.keys else nil, aria = "Open a new tab in this worktree", actions = { click = "worktree" } }))
	end
	table.insert(buttons, button({ key = "remove", label = "Remove worktree", icon = "trash", tone = "error", aria = "Remove this worktree", actions = { click = "remove-worktree" } }))
	if note.path and tern.fs.exists(note.path) then
		table.insert(buttons, button({ key = "git", label = "Open Git view", icon = "merge", aria = "Open Tern's Git view on this worktree", actions = { click = "open-git" } }))
	end
	table.insert(body, buttonRow("actions", buttons))
	return { ui.node("card", { key = "worktree", tone = noteTone(note) }, body) }
end

-- The description part of the item with key `key`. A folded bare card shows its first lines under a fade and Tern's
-- own "N more lines" button; its head row is hidden by plotroom.css, so the text stands alone. `collapsed` mirrors
-- state.descOpen (set by the card's toggle event), so Show less, a value the card has not been sent yet, folds it again.
-- Nothing for a blank body.
local function descNodes(state: State, key: string, body: string?): { Node }
	if not body or not string.find(body, "%S") then
		return {}
	end
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
		table.insert(nodes, button({ key = "less", label = "Show less", icon = "chev-up", tone = "muted", actions = { click = "fold-description" } }))
	end
	return nodes
end

-- The Summary part of the selected `item` (`pr`: a pull request), engine.wantSummary's: plain text, never markdown or a
-- link, since a model wrote it from untrusted text. Nothing while Summaries are off or the cursor has not rested yet.
local function summaryNodes(state: State, item: any, pr: boolean): { Node }
	local status, text = engine.wantSummary(state, item, pr)
	local head = ui.node("text", { key = "summary-head", spans = { ui.span("Summary", "strong") } })
	if status == "done" then
		return { head, ui.node("text", { key = "summary", spans = { ui.span(text or "") } }) }
	elseif status == "busy" then
		return { head, ui.node("shimmer", { key = "summary-loading", text = "Summarizing…" }) }
	elseif status == "failed" then
		return { head, ui.node("text", { key = "summary-state", spans = { ui.span("Summary not made: " .. brief(text or ""), "muted") } }) }
	end
	return {}
end

-- The pull request whose head is an issue's worktree branch, a row that shows it in this block (window.luau's `showPr`;
-- the list keyed "headpr", which window.luau reads); nil without one. `repo` is where the PR is.
local function headPrList(repo: string?, pr: github.HeadPr?): Node?
	if not pr or not repo then
		return nil
	end
	local look = STATE_BADGE[pr.state] or STATE_BADGE.open
	local what = "#" .. pr.number .. " · " .. look.text
	return ui.node("list", { key = "headpr" }, {
		ui.node("item", {
			key = "hp1",
			role = LINK,
			label = pr.title,
			value = "#" .. pr.number,
			icon = if pr.state == "merged" then "check" elseif pr.state == "closed" then "x" else "merge",
			tone = look.tone,
			title = what,
			aria = pr.title .. ", " .. what,
			href = "plotroom://github/show/" .. repo .. "/" .. pr.number,
			actions = { click = "open" },
		}),
	})
end

-- A pull request's linked issues (those it closes, then the one Plotroom noted for its worktree, once): key, title and
-- status, each a link that opens it in a Browser block (as the issue's own Open does), in the list keyed "noted", which
-- window.luau reads. Nothing without any.
local function linkedIssues(closing: { tracker.Linked }, noted: tracker.Issue?): { Node }
	local all: { any } = table.clone(closing)
	local listed = false
	for _, c in closing do
		listed = listed or (noted ~= nil and c.url == noted.url)
	end
	if noted and not listed then
		table.insert(all, noted)
	end
	if #all == 0 then
		return {}
	end
	local rows: { Node } = {}
	for i, issue in all do
		local look = issue.status or STATE_BADGE[issue.state] or STATE_BADGE.open
		local ref = tracker.refLabel(issue.ref)
		local what = ref .. " · " .. look.text
		table.insert(rows, ui.node("item", {
			key = "issue" .. i,
			role = LINK,
			label = issue.title,
			value = ref,
			icon = if issue.state == "closed" or issue.state == "done" then "check" else ISSUE_ICON,
			tone = look.tone,
			title = what,
			aria = issue.title .. ", " .. what,
			href = "plotroom://issue/open/" .. pct(issue.url),
			actions = { click = "open" },
		}))
	end
	return { ui.node("list", { key = "noted" }, rows) }
end

-- The preview's own controls, as buttons: the suggested next move for the item's stage (engine.nextMove, run as the
-- Next move queue action), then Unpin while the item is pinned, Unsnooze while it is snoozed (nil when there is none).
local function previewControls(state: State, item: any): Node?
	local rows: { Node } = {}
	local move = engine.nextMove(state, state.kind.id, item)
	if move then
		local map = keys.load()
		table.insert(rows, button({ key = "next", label = move.label, value = "Next", icon = "arrow-right", tone = "accent", hint = keys.caps(map, "next"), aria = "Next move: " .. move.label, actions = { click = "next" } }))
	end
	if engine.pinFor(state.pins, item.key) then
		table.insert(rows, button({ key = "unpin", label = "Unpin", icon = "x", aria = "Unpin " .. item.key .. " from the Pins group", actions = { click = "unpin" } }))
	end
	local st = if state.snap then engine.status(state, state.snap.kind, item) else nil
	if st and st.snoozed then
		table.insert(rows, button({ key = "unsnooze", label = "Snoozed until " .. os.date("%a %H:%M", st.snoozeUntil) .. " · Unsnooze", icon = "x", aria = "End the snooze of " .. item.key, actions = { click = "unsnooze" } }))
	end
	if #rows > 0 then
		return buttonRow("controls", rows)
	end
	return nil
end

-- Every preview's first rows, in one shape: its head (the ref, the tracker or kind tag, the copy and open icons when it
-- has a page, and its state badge at the right end, pushed there by an empty growing column), then its title.
local function headNodes(ref: string, tag: { text: string, tone: string }, page: { copy: string, open: string, what: string }?, badge: any, title: string): { Node }
	local head: { Node } = { ui.text({ ui.span(ref, "num") }), ui.node("badge", { key = "integration", text = tag.text, tone = tag.tone }) }
	if page then
		table.insert(head, ui.node("icon", { key = "copy", name = "copy", role = BUTTON, href = page.copy, actions = { click = "copy" }, title = "Copy link", aria = "Copy link to " .. page.what }))
		table.insert(head, ui.node("icon", { key = "open", name = "globe", role = LINK, href = page.open, actions = { click = "open" }, title = "Open", aria = "Open " .. page.what }))
	end
	table.insert(head, ui.node("col", { key = "fill", grow = 1 }))
	if badge then
		table.insert(head, ui.node("badge", { key = "state", text = badge.text, tone = badge.tone, title = badge.title }))
	end
	return {
		ui.node("row", { key = "head", gap = "xs", align = "center" }, head),
		ui.node("row", { key = "titlerow", gap = "xs", align = "center" }, {
			ui.node("text", { key = "title", spans = { ui.span(title, "strong") } }),
		}),
	}
end

-- An item's labels, as badges among its facts (nil without any).
local function labelRow(labels: { string }): Node?
	local chips: { Node } = {}
	for i, l in labels do
		table.insert(chips, ui.node("badge", { key = "label" .. i, text = l }))
	end
	return if #chips > 0 then ui.node("row", { key = "chips", gap = "xs", wrap = true }, chips) else nil
end

-- pr: selected(state) while the active view lists pull requests; acts: itemActions(state, pr, open). The parts follow
-- the order every preview shares (docs/reference.md › Finer points › Preview).
local function previewNodes(state: State, pr: github.Pr?, acts: { Action }): { Node }
	if not pr then
		cancelDetails(state)
		return {}
	end
	-- The detail load also brings the merge state, reviewers, closing issues and description, so every PR needs it.
	wantDetails(state, pr)
	local check = if pr.checks then CHECK[pr.checks] else nil
	local review = if pr.review then REVIEW_BADGE[pr.review] else nil
	local dkey = detailKey(state, pr)
	local detail = if dkey then state.details[dkey] else nil
	local about = if detail then detail.about else nil
	local fail = if dkey then state.detailFail[dkey] else nil
	local loading = dkey ~= nil and detail == nil and fail == nil
	-- The merge state as the search carried it until the details load; it says nothing about a merged or closed PR.
	local merge = if about then about.merge else pr.merge
	local m = if merge and pr.state == "open" then MERGE_STATE[merge] or MERGE_STATE.unknown else nil
	local added, removed = pr.additions, pr.deletions
	local diff = if added + removed > 0
		then ui.node("meter", {
			key = "diff",
			parts = {
				{ value = added / (added + removed), token = "ins", label = "+" .. added },
				{ value = removed / (added + removed), token = "error", label = "−" .. removed },
			},
			label = spans(ui.span("+" .. added, "ins"), " ", ui.span("−" .. removed, "error")),
			total = pr.files .. (if pr.files == 1 then " file" else " files"),
		})
		else nil
	-- A review asked of you leads with who wrote it and how big it is; elsewhere they are plain facts.
	local asked = engine.reviewAsked(state, pr)
	local author = { k = "Author", v = "@" .. pr.author }
	local facts: { { [string]: any } } = {
		{ k = "Repository", v = { ui.span(pr.repo, "mono") } },
		{ k = "Merge", v = if m then { ui.span(m.text, m.tone) } else nil },
		{ k = "Checks", v = if check then { ui.span(check.text, check.tone) } else nil },
		{ k = "Review", v = if review then { ui.span(review.text, review.tone) } else nil },
		if asked then { k = "Author" } else author,
		{ k = "Comments", v = { ui.span(tostring(pr.comments), "num") } },
		{ k = "Opened", v = github.age(pr.created) .. " ago" },
		{ k = "Updated", v = github.age(pr.updated) .. " ago" },
	}
	local sb = STATE_BADGE[stateKind(pr)] or STATE_BADGE.open
	local out: { Node } = { buttonLinks(state, pr, acts) }
	local top = headNodes("#" .. pr.number, { text = INTEGRATIONS.github.label, tone = "muted" }, { copy = pr.url, open = hrefOf(state, pr, "open"), what = "pull request #" .. pr.number }, sb, pr.title)
	table.move(top, 1, #top, #out + 1, out)
	local controls = previewControls(state, pr)
	if controls then
		table.insert(out, controls)
	end
	addPart(out, "summary", summaryNodes(state, pr, true))
	local status: { Node } = { stageFact(state, "prs", pr, if asked then { author } else nil) }
	if asked and diff then
		table.insert(status, diff)
	end
	addPart(out, "status", status)
	addPart(out, "worktree", worktreeNodes(state, pr.key, acts))
	addPart(out, "description", descNodes(state, pr.key, if about then about.body else nil))
	local properties: { Node } = {
		ui.node("col", { key = "about", gap = "sm" }, {
			refRow("branch", "Branch", pr.head),
			refRow("base", "Base", pr.base),
			ui.node("kv", { key = "facts", items = withValue(facts) }),
		}),
	}
	local labels = labelRow(pr.labels)
	if labels then
		table.insert(properties, labels)
	end
	if diff and not asked then
		table.insert(properties, diff)
	end
	addPart(out, "properties", properties)
	local load: Load = { loading = loading, fail = fail }
	addPart(out, "linked", section("linked", "Linked issues", "linked issues", linkedIssues(if about then about.closing else {}, if detail then detail.noted else nil), load))
	local reviewers: { Node } = {}
	local reviews: { github.Review } = if about then about.reviews else {}
	for i, r in reviews do
		local v = VERDICT_ROW[r.state]
		if v then
			local what = "@" .. r.login .. " — " .. v.text
			table.insert(reviewers, ui.node("item", { key = "r" .. i, label = "@" .. r.login, icon = v.icon, tone = v.tone, title = what, aria = what }))
		end
	end
	addPart(out, "reviewers", section("reviewers", "Reviewers", "reviewers", if #reviewers > 0 then { ui.node("list", { key = "reviewers" }, reviewers) } else {}, load))
	addPart(out, "checks", checksNodes(state, pr))
	return out
end

-- The rows of the items linked to an issue (its Linked section's body, `section`): the pull requests that close a
-- GitHub issue, each a link that shows it in this block (window.luau's `showPr`), the issues linked to a Jira one. Like
-- the checks: one row per item, its title with the number or key at the right, the icon and its tone the state (the
-- tooltip names it); Jira's under a muted heading per relation ("Blocks · 1"), in the order Jira first names each.
-- Items without a relation (GitHub's) are the one list keyed "linked", which window.luau reads.
local function linkedNodes(tr: string, detail: tracker.IssueDetail?): { Node }
	local out: { Node } = {}
	if not detail then
		return out

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
			props.href, props.actions, props.role = "plotroom://github/show/" .. o .. "/" .. r .. "/" .. n, { click = "open" }, LINK
		end
		local k = l.relation or ""
		if not at[k] then
			table.insert(groups, { relation = l.relation, rows = {} })
			at[k] = #groups
		end
		table.insert(groups[at[k]].rows, ui.node("item", props))
	end
	for g, group in groups do
		local relation = group.relation
		if relation then
			local name = if relation == "subtask" then "Subtasks" else string.upper(string.sub(relation, 1, 1)) .. string.sub(relation, 2)
			table.insert(out, ui.node("text", { key = "linked-head" .. g, spans = { ui.span(name .. " · " .. #group.rows, "muted") } }))
		end
		table.insert(out, ui.node("list", { key = if relation then "linked" .. g else "linked" }, group.rows))
	end
	return out
end

-- The selected issue's preview, in the order every preview shares (docs/reference.md › Finer points › Preview). issue:
-- selected(state) while the active view lists issues; acts: itemActions(state, issue, open).
local function issuePreview(state: State, issue: tracker.Issue?, acts: { Action }): { Node }
	if not issue then
		cancelDetails(state)
		return {}
	end
	-- The body, the tracker's own rows and the linked items come with the detail load.
	wantDetails(state, issue)
	local sb = issueBadge(issue)
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
	local properties: { Node } = { ui.node("col", { key = "about", gap = "sm" }, about) }
	local labels = labelRow(issue.labels)
	if labels then
		table.insert(properties, labels)
	end
	local ref = tracker.refLabel(issue.ref)
	local out: { Node } = { buttonLinks(state, issue, acts) }
	local tag = { text = INTEGRATIONS[issue.tracker].label, tone = if issue.tracker == "jira" then "accent" else "muted" }
	local top = headNodes(ref, tag, { copy = issue.url, open = hrefOf(state, issue, "open"), what = "issue " .. ref }, sb, issue.title)
	table.move(top, 1, #top, #out + 1, out)
	local controls = previewControls(state, issue)
	if controls then
		table.insert(out, controls)
	end
	addPart(out, "summary", summaryNodes(state, issue, false))
	addPart(out, "status", { stageFact(state, "issues", issue) })
	addPart(out, "worktree", worktreeNodes(state, issue.key, acts))
	addPart(out, "description", descNodes(state, issue.key, if detail then detail.body else nil))
	addPart(out, "properties", properties)
	-- The PR whose head is the issue's worktree branch joins a GitHub issue's linked pull requests; a Jira issue's
	-- linked items are issues, so it has a Linked pull requests section of its own while there is one.
	local headPr = headPrList(code, if loaded and not loaded.headLinked then loaded.headPr else nil)
	local linked = linkedNodes(issue.tracker, detail)
	if headPr and issue.tracker == "github" then
		table.insert(linked, headPr)
	end
	local heading = INTEGRATIONS[issue.tracker].linked
	addPart(out, "linked", section("linked", heading, string.lower(heading), linked, { loading = loading, fail = fail }))
	if headPr and issue.tracker ~= "github" then
		addPart(out, "headpr", { ui.node("text", { key = "headpr-head", spans = { ui.span(INTEGRATIONS.github.linked, "strong") } }), headPr })
	end
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
		buttonRow("buttons", {
			button({ key = "close", label = "Close", icon = "x", hint = { "esc" }, aria = "Close the shortcut list", actions = { click = "close-help" } }),
		}),
	})
end

-- The sidebar's scopes in its order, and the id of the one shown: Now, the pins, then the views grouped by integration
-- (and login), then the Worktrees and Agents lists. Each is { id, label, icon, count, group }; the sidebar and the command
-- palette's Views group both list these rows, and engine.goScope shows one.
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
		label = "Worktrees",
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
	-- Now comes first: it is the list that opens, and the one place that answers what needs you.
	table.insert(scopes, 1, {
		id = "now",
		label = "Now",
		icon = "inbox",
		count = if not dropdown and (state.now.loaded or next(state.agents) ~= nil) then engine.nowCount(state) else nil,
		group = if grouped then "Now" else nil,
	})
	if state.boardOn then
		activeScope = "worktrees"
	elseif state.agentsOn then
		activeScope = "agents"
	elseif state.nowOn then
		activeScope = "now"
	end
	return scopes, activeScope
end

-- The board's preview of the selected worktree, in the order every preview shares (docs/reference.md › Finer points ›
-- Preview): its repository and changes, its folder's name, what it needs (cleanup, a refusal), its git facts, the pull
-- request and issue it was made for (each as the tracker answered, or why not) and, hidden, the link the window opens
-- its folder with.
local function boardPreview(state: State): { Node }
	local row, at = engine.boardSelected(state)
	if not row then
		return {}
	end
	local p = board.preview(state.board, row)
	local changes: { text: string, tone: string, title: string? } = if row.missing then { text = "Missing", tone = "error" }
		elseif row.dirty == true then { text = "Changes", tone = "warning" }
		elseif row.dirty == false then { text = "Clean", tone = "success" }
		elseif row.scannedAt then { text = "Unknown", tone = "muted" }
		else { text = "Reading…", tone = "muted" }
	local facts: { { [string]: any } } = {}
	for _, f in p.facts do
		local style: string? = if f[1] == "Repository" then "mono" elseif f[1] == "Branch" or f[1] == "Path" or f[1] == "Head" then "code" else nil
		if f[1] == "Status" then
			changes.title = f[2] -- the head's badge says it
		else
			table.insert(facts, { k = f[1], v = { ui.span(f[2], style) } })
		end
	end
	local kids: { Node } = headNodes(row.repo, { text = "Worktree", tone = "muted" }, nil, changes, p.title)
	local cleanup = if row.candidate == "merged" then "Its pull request is merged" elseif row.candidate == "closed" then "Its item is closed" elseif row.candidateChecked then "Its item is still open" else nil
	local status: { Node } = {}
	local needs = withValue({
		{ k = "Cleanup", v = if cleanup then { ui.span(cleanup, if row.candidate then "warning" else nil) } else nil },
		{ k = "Locked", v = if row.locked then { ui.span("Locked with git worktree lock") } else nil },
	})
	if #needs > 0 then
		table.insert(status, ui.node("kv", { key = "stage", items = needs }))
	end
	if row.refused then
		table.insert(status, ui.node("text", { key = "refused", spans = { ui.span(row.refused, "error") } }))
	end
	addPart(kids, "status", status)
	addPart(kids, "properties", { ui.node("kv", { key = "facts", items = withValue(facts) }) })
	local linked: { Node } = {}
	local function half(key: string, heading: string, sec: any)
		if not sec then
			return
		end
		local info = sec.info
		local body: { Node } = {}
		if sec.state == "empty" or (sec.state == "ready" and not info) then
			table.insert(body, ui.node("text", { key = key .. "-empty", spans = { ui.span(sec.ref .. " was not found by its tracker.", "muted") } }))
		elseif sec.state == "ready" and info then
			table.insert(body, ui.node("row", { key = key .. "-title", gap = "xs", align = "center" }, {
				ui.text({ ui.span(sec.ref, "num") }),
				ui.node("text", { key = "t", spans = { ui.span(printable(info.title), "strong") } }),
				ui.node("badge", { key = "state", text = printable(info.state), tone = "muted" }),
			}))
			local rows: { { [string]: any } } = {
				{ k = "Tracker", v = { ui.span(printable(info.tracker), "mono") } },
				{ k = if key == "pr" then "Author" else "Assignee", v = if info.person then { ui.span(printable(info.person)) } else nil },
			}
			table.insert(body, ui.node("kv", { key = key .. "-facts", items = withValue(rows) }))
			if info.excerpt then
				table.insert(body, ui.node("text", { key = key .. "-excerpt", spans = { ui.span(printable(info.excerpt), "muted") } }))
			end
		end
		local nodes = section(key, heading, sec.ref, body, { loading = sec.state == "loading", problem = if sec.state == "error" then sec.problem or "no answer" else nil })
		table.move(nodes, 1, #nodes, #linked + 1, linked)
	end
	half("pr", INTEGRATIONS.github.linked, p.pr)
	half("issue", INTEGRATIONS.jira.linked, p.issue)
	addPart(kids, "linked", linked)
	local links: { Node } = { ui.node("text", { key = "wtopen", href = core.withToken("plotroom://worktrees/open/" .. at) }) }
	if not row.missing then
		table.insert(links, ui.node("text", { key = "git", href = core.withToken(core.GIT_LINK) }))
	end
	table.insert(kids, ui.node("col", { key = "buttons", hidden = true }, links))
	return kids
end

-- Turns the queue's picker props into the Worktrees board's: its rows and subtitle.
local function boardProps(state: State, props: { [string]: any })
	local items, order = engine.boardItems(state)
	local row = engine.boardSelected(state)
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
	props.icon, props.title, props.subtitle, props.noun = "folder", { ui.span("Worktrees", "strong") }, sub, "worktrees"
	props.placeholder = "Worktrees are not searched"
	props.state = if state.boardBusy and not state.board.loaded then "loading" else "ready"
	props.empty = { ui.span(if next(readCheckouts()) == nil then "No checkouts yet: add a repository's checkout in Settings › Repositories." else "No worktrees found.", "muted") }
	props.items, props.order, props.hits, props.message = tern.json.array(items), tern.json.array(order), nil, nil
	props.selected = if row then pickerId("w", row.id) else nil
	props.columns, props.query, props.cursor = {}, nil, nil
end

-- The Agents scope's preview of the selected agent, in the order every preview shares (docs/reference.md › Finer points
-- › Preview): its item and state, what needs you (its report, outcome and check), the agent's action, branch and last
-- run, and, hidden, the link the window goes to its tab with.
local function agentsPreview(state: State): { Node }
	local row = engine.agentSelected(state)
	if not row then
		return {}
	end
	local badge = AGENT_BADGE[row.state]
	local report = REPORT_BADGE[row.attention or ""]
	local href = engine.agentHref(row.key)
	local verdict = verdictBadge(row)
	local checked = checkBadge(row)
	local needs = withValue({
		{ k = "Report", v = if report then { ui.span(report.text, report.tone) } else nil },
		{ k = "Outcome", v = if verdict then { ui.span(verdictText(row) :: string, verdict.tone) } else nil },
		{ k = "Check", v = if checked then { ui.span(checked.text, checked.tone) } else nil },
		{ k = "Findings", v = if row.check == "fail" and row.findings then { ui.span(printable(row.findings)) } else nil },
		{ k = "Reason", v = if report and row.reason then { ui.span(printable(row.reason)) } else nil },
		{ k = "Blocker", v = if report and row.blocker then { ui.span(printable(row.blocker), "error") } else nil },
		{ k = "Last message", v = if row.last then { ui.span(printable(row.last)) } else nil },
		{ k = "Not delivered", v = if row.err then { ui.span(printable(row.err), "error") } else nil },
	})
	local agent = withValue({
		{ k = "Working", v = agentClock(state, row.key) },
		{ k = "Action", v = if row.action then { ui.span(printable(row.action)) } else nil },
		{ k = "Branch", v = if row.branch then { ui.span(printable(row.branch), "code") } else nil },
		{ k = "Last run", v = if row.result then { ui.span(printable(row.result .. (if row.ended then " " .. row.ended else ""))) } else nil },
	})
	local kids: { Node } = headNodes(printable(row.key), { text = "Agent", tone = "muted" }, nil, badge, printable(row.title or row.key))
	addPart(kids, "status", if #needs > 0 then { ui.node("kv", { key = "stage", items = needs }) } else {})
	addPart(kids, "agent", if #agent > 0 then { ui.node("kv", { key = "agent", items = agent }) } else {})
	if href then
		local links: { Node } = { ui.node("text", { key = "agentgo", href = href }) }
		for _, act in AGENT_COMMANDS do
			table.insert(links, ui.node("text", { key = act, href = engine.agentHref(row.key, act) }))
		end
		table.insert(kids, ui.node("col", { key = "buttons", hidden = true }, links))
	end
	return kids
end

-- Turns the queue's picker props into the Agents scope's: a group per repository, each agent's item, action, branch and state.
local function agentsProps(state: State, props: { [string]: any })
	local rows = engine.agentRows(state)
	local current = engine.agentSelected(state)
	local items: { any } = {}
	local order: { any } = {}
	local groups: { [string]: { any } } = {}
	local names: { string } = {}
	for _, row in rows do
		local label = printable(row.title or row.key)
		local detail: { any } = {}
		if row.action then
			table.insert(detail, ui.span(printable(row.action .. (if row.result then ": " .. row.result .. (if row.ended then " " .. row.ended else "") else ""))))
		elseif row.result then
			table.insert(detail, ui.span(printable(row.result .. (if row.ended then " " .. row.ended else ""))))
		end
		if row.branch then
			table.insert(detail, if #detail > 0 then " · " else "")
			table.insert(detail, ui.span(printable(row.branch), "mono"))
		end
		if #detail == 0 then
			detail = { ui.span(printable(row.key), "mono") }
		end
		local clock = agentClock(state, row.key)
		if clock then
			table.insert(clock, " · ")
			table.move(detail, 1, #detail, #clock + 1, clock)
			detail = clock
		end
		local report = REPORT_BADGE[row.attention or ""]
		if row.err then
			table.insert(detail, " · ")
			table.insert(detail, ui.span(printable(row.err), "error"))
		end
		if report and row.blocker then
			table.insert(detail, " · ")
			table.insert(detail, ui.span(printable(row.blocker), "error"))
		end
		if report and row.reason then
			table.insert(detail, " · ")
			table.insert(detail, ui.span(printable(row.reason)))
		end
		if row.last then
			table.insert(detail, " · ")
			table.insert(detail, ui.span(printable(row.last), "muted"))
		end
		local id = pickerId("g", row.key)
		local badges: { any } = { AGENT_BADGE[row.state] }
		if report then
			table.insert(badges, report)
		end
		local verdict = verdictBadge(row)
		if verdict then
			table.insert(badges, verdict)
		end
		local checked = checkBadge(row)
		if checked then
			table.insert(badges, checked)
		end
		table.insert(items, { id = id, label = label, title = label, detail = detail, badges = badges })
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
	props.selected = if current then pickerId("g", current.key) else nil
	props.columns, props.query, props.cursor = {}, nil, nil
end

-- What GitHub's notification reasons say, and how much each wants you; any other reason is shown as GitHub spelled it.
local REASON: { [string]: { text: string, tone: string } } = {
	review_requested = { text = "Review requested", tone = "accent" },
	mention = { text = "Mention", tone = "accent" },
	team_mention = { text = "Team mention", tone = "accent" },
	assign = { text = "Assigned", tone = "accent" },
	approval_requested = { text = "Approval requested", tone = "accent" },
	ci_activity = { text = "CI", tone = "warning" },
	security_alert = { text = "Security alert", tone = "warning" },
	author = { text = "Your item", tone = "muted" },
	comment = { text = "Comment", tone = "muted" },
	state_change = { text = "State change", tone = "muted" },
	subscribed = { text = "Subscribed", tone = "muted" },
	manual = { text = "Subscribed by you", tone = "muted" },
}
local function reasonOf(reason: string): { text: string, tone: string }
	local known = REASON[reason]
	if known then
		return known
	end
	local words = string.gsub(reason, "_", " ")
	return { text = string.upper(string.sub(words, 1, 1)) .. string.sub(words, 2), tone = "muted" }
end

-- Why Now lists `row` (engine.nowRows): its badge, and the sentence its preview says it with.
local function nowWhy(row: any): ({ text: string, tone: string, title: string }, string)
	if row.rank == 1 then
		local agent = row.agent or {}
		local verdict = verdictText(agent)
		if row.waiting then
			return { text = "Agent needs input", tone = "warning", title = "Its agent is waiting for your input" }, "Its agent is waiting for your input"
		elseif agent.stop then
			return { text = printable(agent.stop), tone = "warning", title = "Plotroom stopped the item's chain of actions" }, "Plotroom stopped the item's chain of actions: " .. printable(agent.stop)
		elseif agent.check == "fail" then
			return CHECK_BADGE.fail, CHECK_BADGE.fail.title
		elseif agent.attention == "stuck" or agent.attention == "needs-human" then
			local report = REPORT_BADGE[agent.attention]
			return { text = report.text, tone = report.tone, title = report.title }, report.title
		end
		return { text = verdict or "Not verified", tone = "warning", title = "GitHub does not show what its run must leave behind" }, "GitHub does not show what its run must leave behind: " .. (verdict or "Not verified")
	elseif row.rank == 2 then
		return { text = "Blocked: " .. string.lower(row.why or ""), tone = "error", title = "Your pull request is blocked" }, "Your pull request is blocked: " .. string.lower(row.why or "")
	elseif row.rank == 3 then
		local asked = if row.why
			then "Your team's review is requested: " .. printable(row.why)
			elseif row.item and row.item.yourReview == "dismissed" then "Your review was dismissed, so it is requested again"
			else "Your review is requested"
		return { text = "Review requested", tone = "accent", title = asked }, asked
	elseif row.rank == 4 then
		return { text = "Ready to merge", tone = "success", title = "Your pull request is ready to merge" }, "Your pull request is ready to merge"
	elseif row.rank == 5 then
		local reason = reasonOf(row.notice.reason)
		return { text = reason.text, tone = "accent", title = "GitHub notified you: " .. reason.text }, "An unread notification you take part in: " .. reason.text
	end
	local fresh = if row.why == "New" then "and you haven't seen it yet" else "and changed since you last saw it"
	return { text = "Assigned: " .. string.lower(row.why or ""), tone = if row.why == "New" then "accent" else "warning", title = "Assigned to you, " .. fresh }, "Assigned to you, " .. fresh
end

-- Now's preview of the selected row, in the order every preview shares (docs/reference.md › Finer points › Preview):
-- its item and why it is listed, its title, what needs you (why, its stage, its agent's report, outcome and check, when
-- a snooze ends), its agent's action, when GitHub last updated it, and what Enter does.
local function nowPreview(state: State): { Node }
	local row = engine.nowSelected(state)
	if not row then
		return {}
	end
	local badge, sentence = nowWhy(row)
	local item, n, agent = row.item, row.notice, row.agent
	local stage: { text: string, tone: string? }? = nil
	if item and row.kind then
		local id, why = engine.stage(state, row.kind, item)
		stage = stageBadge(id, why, state.notes[item.key])
	end
	local go = if row.rank == 1 and row.key then engine.agentHref(row.key) else nil
	local reply = if go and row.waiting then engine.agentHref(row.key, "agentreply") else nil
	local enter = if go then "Enter goes to the agent." elseif row.url then "Enter shows it in Plotroom." else "Enter has nothing to show for it."
	-- The links Go to agent and Reply… open (the window honours only links its block shows).
	local links: { Node } = {}
	if go then
		table.insert(links, ui.node("text", { key = "agentgo", href = go }))
	end
	if reply then
		table.insert(links, ui.node("text", { key = "agentreply", href = reply }))
	end
	local report = if agent then REPORT_BADGE[agent.attention or ""] else nil
	local store = engine.store(state)
	local snoozeEnd = if row.snoozed and store and row.key then triage.snoozeEnd(store, { key = row.key }, os.time()) else nil
	local jira = (item and item.tracker == "jira") or (row.key ~= nil and string.match(row.key, "#%u[%u%d]*%-%d+$") ~= nil)
	local ref = if row.key then printable(row.key) elseif n then printable(n.repo) else ""
	local kids: { Node } = headNodes(ref, { text = if jira then INTEGRATIONS.jira.label else INTEGRATIONS.github.label, tone = if jira then "accent" else "muted" }, nil, badge, printable(row.title))
	addPart(kids, "status", {
		ui.node("kv", {
			key = "stage",
			items = withValue({
				{ k = "Why", v = { ui.span(sentence) } },
				{ k = "Stage", v = if stage then { ui.span(stage.text, stage.tone) } else nil },
				{ k = "Chain", v = if agent and agent.stop then { ui.span("Stopped: " .. printable(agent.stop), "warning") } else nil },
				{ k = "Outcome", v = if verdictText(agent) then { ui.span(verdictText(agent) :: string, (verdictBadge(agent) :: any).tone) } else nil },
				{ k = "Check", v = if checkBadge(agent) then { ui.span((checkBadge(agent) :: any).text, (checkBadge(agent) :: any).tone) } else nil },
				{ k = "Findings", v = if agent and agent.check == "fail" and agent.findings then { ui.span(printable(agent.findings)) } else nil },
				{ k = "Report", v = if report and agent.attention ~= "none" then { ui.span(report.text, report.tone) } else nil },
				{ k = "Reason", v = if report and agent.reason then { ui.span(printable(agent.reason)) } else nil },
				{ k = "Blocker", v = if report and agent.blocker then { ui.span(printable(agent.blocker), "error") } else nil },
				{ k = "Last message", v = if agent and agent.last then { ui.span(printable(agent.last)) } else nil },
				{ k = "Snoozed", v = if snoozeEnd then { ui.span("Until " .. os.date("%a %H:%M", snoozeEnd), "muted") } else nil },
			}),
		}),
	})
	local working = if row.key then agentClock(state, row.key) else nil
	local agentFacts = withValue({
		{ k = "Working", v = working },
		{ k = "Action", v = if agent and agent.action then { ui.span(printable(agent.action)) } else nil },
	})
	addPart(kids, "agent", if #agentFacts > 0 then { ui.node("kv", { key = "agent", items = agentFacts }) } else {})
	addPart(kids, "properties", if n and n.updated > 0 then { ui.node("kv", { key = "facts", items = { { k = "Updated", v = { ui.span(os.date("%Y-%m-%d %H:%M", n.updated)) } } } }) } else {})
	table.insert(kids, ui.node("text", { key = "enter", spans = { ui.span(enter, "muted") } }))
	table.insert(kids, ui.node("col", { key = "buttons", hidden = true }, links))
	return kids
end

-- Turns the queue's picker props into Now's: its rows top first, each as its view shows it with why it is listed first.
local function nowProps(state: State, props: { [string]: any })
	local now = state.now
	local rows = engine.nowRows(state)
	local current = engine.nowSelected(state)
	local items: { any } = {}
	local order: { any } = {}
	for _, row in rows do
		local badge = nowWhy(row)
		local item: { [string]: any }
		if row.item and row.kind then
			local stage = engine.stage(state, row.kind, row.item)
			local note = state.notes[row.key]
			-- Now spans every repository; its first badge already says what blocks a PR.
			item = if row.kind == "issues" then issueRow(row.item, note, stage, true) else pickerItem(row.item, note, stage, nil, true)
		else
			local detail: { any } = {}
			if row.notice then
				table.insert(detail, ui.span(printable(row.notice.repo), "mono"))
				if row.notice.number then
					table.insert(detail, " · ")
					table.insert(detail, ui.span("#" .. row.notice.number, "num"))
				end
			else
				table.insert(detail, ui.span(printable(row.key), "mono"))
			end
			if row.agent and row.agent.action then
				table.insert(detail, " · " .. printable(row.agent.action))
			end
			item = { label = printable(row.title), title = printable(row.title), detail = detail }
		end
		-- What an agent that needs input last said, as the Agents list shows it.
		if row.rank == 1 and row.agent and row.agent.last then
			table.insert(item.detail, " · ")
			table.insert(item.detail, ui.span(printable(row.agent.last), "muted"))
		end
		-- How long the item's agent has worked, while it works.
		local clock = if row.key then agentClock(state, row.key) else nil
		if clock then
			table.insert(item.detail, " · ")
			for _, s in clock do
				table.insert(item.detail, s)
			end
		end
		local badges: { any } = { badge }
		if row.snoozed then
			table.insert(badges, { text = "Snoozed", tone = "muted", title = "Snoozed until 08:00" })
		end
		for _, b in item.badges or {} do
			table.insert(badges, b)
		end
		item.id, item.badges = row.id, badges
		table.insert(items, item)
		table.insert(order, row.id)
	end
	local sub: { any } = {}
	if now.busy then
		local busy: any = ui.span("Reading…", "muted")
		busy.fx = "shimmer"
		table.insert(sub, busy)
	end
	local need = engine.nowSummary(state)
	if need then
		table.insert(sub, ui.span((if #sub > 0 then " · " else "") .. need, "accent"))
	end
	for _, line in now.problems do
		table.insert(sub, ui.span((if #sub > 0 then " · " else "") .. printable(line), "warning"))
	end
	if state.showSnoozed then
		table.insert(sub, ui.span((if #sub > 0 then " · " else "") .. "Snoozed shown", "muted"))
	end
	-- How many are listed: "N left" at rest, "n of N" while Next in Now walks them.
	local title: { any } = { ui.span("Now", "strong") }
	if now.loaded or #rows > 0 then
		local walking = engine.nowWalking(state)
		table.insert(title, ui.span(" · " .. (if walking then walking .. " of " .. #rows else #rows .. " left"), "muted"))
	end
	props.icon, props.title, props.noun = "inbox", title, "items"
	props.subtitle = if #sub > 0 then sub else nil
	props.placeholder = "Now is not searched"
	props.state = if not now.loaded and #rows == 0 then "loading" else "ready"
	props.message = nil
	-- Every reason switched off (Settings › Views › Now): only the agents that need you are listed.
	local allOff = true
	for _, r in core.NOW_REASONS do
		allOff = allOff and now.prefs.off[r.id] == true
	end
	props.empty = { ui.span(if allOff then "Only agents are listed: Settings › Views › Now" else "Nothing needs you right now.", "muted") }
	props.items, props.order, props.hits = tern.json.array(items), tern.json.array(order), nil
	props.selected = if current then current.id else nil
	props.columns, props.query, props.cursor = {}, nil, nil
end

-- The one-key shortcuts as the checklist decided them ("use" | "no"), "set" when none is left to bind, else nil.
local function shortcutsChoice(saved: { [string]: any }?): string?
	local chosen = if saved then saved.shortcuts else nil
	if chosen == "use" or chosen == "no" then
		return chosen
	end
	local map = keys.load()
	for _, a in keys.ACTIONS do
		if a.preset and map[a.id] == "" then
			return nil
		end
	end
	return "set"
end

-- The Get started checklist (PRODUCT.md › Principles 4), shown above the preview until every line is done or it is
-- dismissed (kv `get-started`), and whenever Commands › Get started opened it. Each line has one action; a done line
-- has none. Lines still being asked hide it, unless Get started opened it.
local function checklist(state: State): Node?
	if state.boardOn or state.agentsOn then -- Now shows it too: a new block opens there, and no line needs a selection
		return nil
	end
	local saved = engine.getStarted()
	if not state.getStarted and (not saved or saved.dismissed == true) then
		return nil
	end
	engine.askSetup(state)
	local setup = engine.setup
	local lines: { Node } = {}
	local todo, asking = 0, false
	local function line(key: string, label: string, how: string, click: string?, value: string?, href: string?)
		if how == "todo" then
			todo += 1
		elseif how == "wait" then
			asking = true
		end
		local props: { [string]: any } = {
			key = key,
			label = label,
			value = value,
			icon = if how == "done" then "check" elseif how == "todo" then "arrow-right" else nil,
			tone = if how == "done" then "success" elseif how == "wait" then "muted" else nil,
			href = href,
		}
		-- A line's one action: a setup guide is a page it opens, anything else does the step.
		if click then
			props.actions = { click = click }
			props.role = if string.find(click, "^setup%-guide=") then LINK else BUTTON
		end
		table.insert(lines, ui.node("item", props))
	end
	local gh = cli.installed.github
	if gh == nil or (gh and setup.signedIn == nil) then
		line("gh", "Checking gh…", "wait")
	elseif not gh then
		line("gh", "Install gh, GitHub's CLI", "todo", "setup-guide=gh", "Setup guide ↗")
	elseif not setup.signedIn then
		line("gh", "Sign in to gh: run gh auth login", "todo", "setup-guide=gh-login", "Setup guide ↗")
	else
		line("gh", "gh signed in" .. (if ghActive.login then " as @" .. ghActive.login else ""), "done")
	end
	if setup.omp == nil then
		line("omp", "Checking omp…", "wait")
	elseif setup.omp then
		line("omp", "omp installed", "done")
	else
		line("omp", "Install omp, which runs the agents", "todo", "setup-guide=omp", "Setup guide ↗")
	end
	for _, repo in engine.missingCheckouts(state) do
		local key = string.lower(repo)
		local path = if state.found then state.found[key] else nil
		if path == nil then
			line("co:" .. key, "Looking for a checkout of " .. repo .. "…", "wait")
		elseif type(path) == "string" then
			line("co:" .. key, "Use " .. worktree.tilde(path, tern.getenv("HOME")) .. " as the checkout", "todo", "setup-use=" .. repo, repo)
		else
			line("co:" .. key, "Choose the checkout of " .. repo .. "…", "todo", "open", "A new or empty folder gets a clone", "plotroom://checkout/" .. repo)
		end
	end
	local choice = shortcutsChoice(saved)
	local shortcuts: Node
	if choice then
		shortcuts = ui.node("item", { key = "keys", label = if choice == "no" then "One-key shortcuts: no thanks" else "One-key shortcuts on", icon = "check", tone = "success" })
	else
		todo += 1
		local letters: { string } = {}
		for _, a in keys.ACTIONS do
			if a.preset then
				table.insert(letters, a.preset)
			end
		end
		shortcuts = ui.node("row", { key = "keys", gap = "sm", wrap = true, align = "center" }, {
			ui.node("text", { key = "what", spans = { ui.span("One-key shortcuts (" .. table.concat(letters, " ") .. ")") } }),
			button({ key = "use", label = "Use them", icon = "check", actions = { click = "setup-keys=use" } }),
			button({ key = "no", label = "No thanks", icon = "x", actions = { click = "setup-keys=no" } }),
		})
	end
	if not state.getStarted and (asking or todo == 0) then
		return nil
	end
	return ui.node("card", { key = "get-started" }, {
		ui.node("text", { key = "head", spans = { ui.span("Get started", "strong"), ui.span("  " .. (if todo == 0 and not asking then "All set" else todo .. " to do"), "muted") } }),
		ui.node("list", { key = "lines" }, lines),
		shortcuts,
		buttonRow("end", {
			button({ key = "dismiss", label = if todo == 0 then "Close" else "Dismiss", icon = "x", tone = "muted", aria = "Hide the Get started checklist; Commands › Get started shows it again", actions = { click = "setup-dismiss" } }),
		}),
	})
end

-- The queue's picker; also drawn under Settings' side sheet, where keys go to Settings (so no search caret).
function M.queuePicker(state: State): Node
	state.clocked = false -- agentClock marks it again while a working agent's clock is drawn
	local snap, problem, view, item = state.snap, state.problem, activeView(state), selected(state)
	local vis = filtered(state)
	local open = openItems(state)
	local items: { any } = if snap then rowsOf(state, snap) else tern.json.array({})
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
	local wait = waitOf(state)
	if wait > 0 then
		note(ui.span("Paused by GitHub until " .. os.date("%H:%M:%S", os.time() + wait), "warning"))
	end
	if state.showSnoozed then
		note(ui.span("Snoozed shown", "muted"))
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
		note(ui.span(snap.note or "Partial results: narrow this view", "warning"))
	end
	for _, id in { "prs", "issues" } do
		local locked = state.locked[id]
		if locked then
			note(ui.span(locked, "error"))
		end
	end

	local dropdown = state.cx.cols <= 127
	local scopes, activeScope = M.scopeRows(state)
	local map = keys.load()
	local acts: { Action } = if item then itemActions(state, item, open) else {}
	local hidden = if snap and view and vis and #vis.items == 0 then engine.hiddenCount(state, snap) else 0
	local hiddenHow = if map.snoozed ~= "" then "press " .. map.snoozed else "pick Show or hide snoozed in Commands"

	-- Neither integration is on: the setup pages in Settings are all there is.
	local none = cli.ready() and not cli.on("github") and not cli.on("jira")

	local props: { [string]: any } = {
		key = "queue",
		-- plotroom.css narrows the queue by the Settings sheet's width (`.aside`), so the sheet sits beside it, not over it,
		-- and folds the scope rail into its dropdown at 127 columns or fewer (`.narrow`: the block's own width).
		role = "plotroom.queue" .. (if state.settings then ".aside" else "") .. (if dropdown then ".narrow" else ""),
		size = "screen",
		layout = "cards",
		preview = "none",
		icon = state.kind.icon,
		title = title,
		subtitle = if #subtitle > 0 then subtitle else nil,
		noun = state.kind.many,
		placeholder = "Search the loaded " .. state.kind.many,
		-- Nothing loads until the CLIs answered.
		state = if not snap and problem then "error" elseif not snap and (view or not cli.ready()) then "loading" else "ready",
		empty = {
			ui.span(
				if view then (if hidden > 0 and snap and hidden == #snap.items then hidden .. " " .. (if hidden == 1 then state.kind.one else state.kind.many) .. " hidden by snoozing; " .. hiddenHow .. " to show " .. (if hidden == 1 then "it" else "them") .. "." elseif state.query and input.trim(state.query.text) ~= "" then "No loaded " .. state.kind.many .. " match “" .. state.query.text .. "”." else "No " .. state.kind.many .. " match " .. view.name .. ".")
					else (if none then "Neither gh nor acli is installed on this host. " else "No views yet. ")
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
		selected = if item then pickerId("n", item.key) else nil,
		focus = state.focus,
		scopes = tern.json.array(scopes),
		scope = activeScope,
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
	elseif state.nowOn then
		cancelDetails(state)
		preview = nowPreview(state)
		nowProps(state, props)
	else
		preview = if state.kind.id == "issues" then issuePreview(state, item, acts) else previewNodes(state, item, acts)
	end
	-- Narrow: the scope dropdown beside the title names the view or list, so the title keeps only its markers.
	if dropdown and activeScope and type(props.title) == "table" then
		local rest: { any } = {}
		for i = 2, #props.title do
			table.insert(rest, props.title[i])
		end
		props.title = if #rest > 0 then rest else nil
	end
	-- Tern: `preview = "none"` hides the pane; with no children it would say "Nothing to preview" in a big pane.
	local guide = checklist(state)
	if guide then
		table.insert(preview, 1, guide)
	end
	local shown = props.selected ~= nil or guide ~= nil
	props.preview = if shown then "side" else "none"
	-- A working agent's clock is shown: draw again a second from now, once (a key press redraws it no sooner).
	if state.clocked and not state.clockTimer then
		state.clockTimer = tern.timer(1000, function()
			state.clockTimer = nil
			if engine.alive(state) then
				state.cx:render()
			end
		end)
	end
	return ui.node("picker", props, if shown then preview else {})
end

-- The Keep/Remove modal both worktree removals ask with: `tabbed` adds the warning that a tab works in the folder.
local function removeOverlay(head: string, body: string, facts: { { [string]: any } }, tabbed: any, keepAct: string, dropAct: string?): Node
	local kids: { Node } = {
		ui.node("text", { key = "body", spans = { ui.span(body, "muted") } }),
		ui.node("kv", { key = "facts", items = facts }),
	}
	if tabbed then
		table.insert(kids, ui.node("text", { key = "tab", spans = { ui.span("A tab works in it and will be left in a folder that no longer exists.", "warning") } }))
	end
	local buttons: { Node } = {
		button({ key = "keep", label = "Keep", icon = "check", hint = { "enter" }, actions = { click = keepAct } }),
	}
	if dropAct then
		table.insert(buttons, button({ key = "delete", label = "Remove", icon = "trash", tone = "error", hint = { "d" }, actions = { click = dropAct } }))
	end
	table.insert(kids, buttonRow("buttons", buttons))
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
	local body = "Its folder is deleted. " .. (if row then board.fate(row) else "") .. " Git refuses while the worktree has uncommitted changes, and nothing is forced. Press d to remove it; Enter or Esc keeps it."
	return removeOverlay("Remove this worktree?", body, facts, row and engine.boardOpen(state)[row.path], "wt-cancel-remove", "wt-confirm-remove")
end

-- The modal that asks once before every finished worktree is removed: only the rows Find finished worktrees marked.
local function finishedConfirm(state: State): Node
	local items: { any } = {}
	local ids: { string } = state.boardFinished or {}
	for _, id in ids do
		for _, r in engine.boardRows(state) do
			if r.id == id then
				table.insert(items, { k = board.label(r), v = { ui.span(r.path, "code") } })
			end
		end
	end
	local n = #items
	local tabbed = false
	local open = engine.boardOpen(state)
	for _, id in ids do
		for _, r in engine.boardRows(state) do
			if r.id == id and open[r.path] then
				tabbed = true
			end
		end
	end
	local unchecked = board.unchecked(state.board)
	local body = "Each worktree's folder is deleted, then its branch unless that holds commits saved nowhere else. Git refuses a worktree with uncommitted changes, which is kept; nothing is forced. "
		.. (if unchecked > 0 then unchecked .. " worktree" .. (if unchecked == 1 then " was" else "s were") .. " not checked yet. " else "")
		.. "Press d to remove all " .. n .. "; Enter or Esc keeps them."
	return removeOverlay("Remove " .. n .. " finished worktree" .. (if n == 1 then "" else "s") .. "?", body, withValue(items), tabbed, "wt-cancel-remove", "wt-confirm-remove")
end

function M.queueView(state: State, palette: Node): BlockView
	local layer: { Node } = { M.queuePicker(state) }
	local removing = state.removing
	local note = if removing then state.notes[removing] else nil
	if removing and note then
		-- A worktree's removal, asked from its card: where it is, and a warning while a tab works in it.
		local facts = withValue({
			{ k = "Path", v = if note.path then { ui.span(note.path, "code") } else nil },
			{ k = "Branch", v = if note.branch then { ui.span(note.branch, "code") } else nil },
		})
		local body = if state.removeRefusal then state.removeRefusal .. " Enter or Esc closes this."
			else "Its folder is deleted. " .. (state.removeFate or "Reading its branch from git…") .. " Git refuses while the worktree has uncommitted changes. Press d to remove it; Enter or Esc keeps it."
		table.insert(layer, removeOverlay("Remove worktree?", body, facts, openItems(state)[removing], "cancel-remove", if state.removeRefusal then nil else "confirm-remove"))
	elseif state.boardOn and (state.boardRemoving or state.boardFinished) then
		table.insert(layer, if state.boardFinished then finishedConfirm(state) else boardConfirm(state))
	elseif state.help then
		table.insert(layer, M.helpOverlay(state))
	end
	return { main = ui.col(M.rpcNodes(state, palette)), layer = ui.col(layer) }
end

return M
