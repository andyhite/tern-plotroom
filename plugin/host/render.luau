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

local CHECK, INTEGRATIONS, ISSUE_ICON, KINDS, MERGE_STATE, REVIEW_BADGE, RPC_PROTOCOL, RUN_TONE, SETTINGS_KEYS, STAGE, STATE_BADGE, VERDICT_ROW, brief, duration, hrefOf, issueBadge, pct, printable, runHrefOf, spans, stateKind, cli = core.CHECK, core.INTEGRATIONS, core.ISSUE_ICON, core.KINDS, core.MERGE_STATE, core.REVIEW_BADGE, core.RPC_PROTOCOL, core.RUN_TONE, core.SETTINGS_KEYS, core.STAGE, core.STATE_BADGE, core.VERDICT_ROW, core.brief, core.duration, core.hrefOf, core.issueBadge, core.pct, core.printable, core.runHrefOf, core.spans, core.stateKind, core.cli
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

-- How a worktree report stands: error when it could not be prepared; otherwise no tone, since a stale, changed or clean
-- worktree is none of DESIGN.md's colour meanings (its badge text says which).
local function noteTone(note: Note): string?
	return if note.ok then nil else "error"
end

-- What a worktree's badge says on hover: its attempt's summary and where it is.
local function noteTitle(note: Note): string
	return (note.summary or "Worktree ready") .. (if note.path then " · " .. note.path else "")
end

-- The badge of stage `id` (engine.stage); a Worktree stage takes its worktree's tone and summary. A Blocked one says no
-- reason: its chips do.
local function stageBadge(id: string, note: Note?): { text: string, tone: string?, title: string? }
	if id == "worktree" and note then
		return { text = STAGE.worktree.text, tone = noteTone(note), title = noteTitle(note) }
	end
	return STAGE[id]
end

-- A Blocked pull request's chips (DESIGN.md › Status chips): one badge per engine.blockers reason, most severe first,
-- each naming its job; its detail is the tooltip.
local function chipBadges(blockers: { engine.Blocker }?): { any }
	local out: { any } = {}
	for _, b in (blockers or {}) :: { engine.Blocker } do
		table.insert(out, { text = b.chip, tone = "error", title = b.detail })
	end
	return out
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
	local detail: { any } = { ui.span(ref, "mono") }
	if repos and repo then
		table.insert(detail, " · ")
		table.insert(detail, ui.span(repo, "mono"))
	end
	return detail
end

-- A pull request's picker row: "#N · repo · <who or what blocks it>" (the first chip's detail, plain: the chips name
-- the jobs), or "New commits since you approved" when its head moved after your approval; its stage says Merged or
-- Closed, so only Draft is left of its state.
local function pickerItem(pr: github.Pr, note: Note?, stage: string, blockers: { engine.Blocker }?, repos: boolean): { [string]: any }
	local badges = worktreeBadges(note, stage)
	if stateKind(pr) == "draft" then
		table.insert(badges, STATE_BADGE.draft)
	end
	local detail = refDetail("#" .. pr.number, pr.repo, repos)
	local why = if blockers and blockers[1] then blockers[1].detail else nil
	if why then
		table.insert(detail, " · " .. why)
	elseif pr.newCommits then
		table.insert(detail, " · ")
		table.insert(detail, "New commits since you approved")
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
	working = { text = "Working", tone = "pending", title = "An agent is working on it" },
	waiting_input = { text = "Needs input", tone = "accent", title = "Its agent is waiting for your input" },
	idle = { text = "Idle", tone = "muted", title = "Its agent is idle; that does not mean the work is done" },
	exited = { text = "Exited", tone = "muted", title = "Its agent has exited" },
}

-- An agent's last end-of-run report as a badge: the agent's claim, never a sign the work is done.
local REPORT_BADGE: { [string]: { text: string, tone: string, title: string } } = {
	ok = { text = "Report: ok", tone = "muted", title = "Its agent reported nothing blocks it; a claim, not a check" },
	stuck = { text = "Report: stuck", tone = "error", title = "Its agent reported it cannot go on" },
	["needs-human"] = { text = "Report: needs human", tone = "accent", title = "Its agent reported it waits for you" },
	none = { text = "No report", tone = "muted", title = "Its agent's last turn ended without a valid end-of-run report" },
}

-- What checking a run's outcome on GitHub found, as a badge naming the outcome (prompts.OUTCOMES); nil when the action
-- names none or no check has answered yet.
local VERDICT_BADGE: { [string]: { text: string, tone: string, title: string } } = {
	verified = { text = "Verified", tone = "success", title = "GitHub shows what the run must leave behind: " },
	["not"] = { text = "Not verified", tone = "accent", title = "GitHub does not show what the run must leave behind: " },
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
	fail = { text = "Check failed", tone = "accent", title = "A fresh agent checked the work against the acceptance criteria and found what fails" },
}
local function checkBadge(info: { check: string? }?): { text: string, tone: string, title: string }?
	return if info then CHECK_BADGE[info.check or ""] else nil
end

-- Puts the stage, a Blocked PR's chips, the agent's state (when the stage does not already say it) and the triage mark
-- (New, Changed, Snoozed) in front of `row`'s badges. The stage badge carries no reason: the chips name each.
local function decorate(state: State, kind: string, item: any, row: { [string]: any }, stage: string, blockers: { engine.Blocker }?)
	local extra: { any } = { stageBadge(stage, state.notes[item.key]) }
	for _, c in chipBadges(blockers) do
		table.insert(extra, c)
	end
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
		table.insert(extra, { text = "Changed", tone = "accent", title = "Changed since you marked it seen" })
	end
	local badges: { any } = if row.badges then row.badges else {}
	for i, b in extra do
		table.insert(badges, i, b)
	end
	row.badges = badges
end

-- A working agent's clock (ms) and estimated bar (0-1; engine.agentClock), nil when the agent of item `key` is not
-- working. Tern ticks the clock; the view notes when the soonest bar it shows needs its next redraw (queuePicker).
local function working(state: State, key: string): (number?, number?)
	local elapsed, fraction, due = engine.agentClock(state, key)
	if due and (not state.barDue or due < state.barDue) then
		state.barDue = due
	end
	return elapsed, fraction
end

-- The Agents and Now pickers' columns: the estimated bar, then the clock, filled by clockFacts.
local CLOCK_COLUMNS = { { id = "bar", format = "bar" }, { id = "clock", format = "elapsed" } }

-- A picker row's facts for those columns; nil when its agent is not working.
local function clockFacts(state: State, key: string): { [string]: number }?
	local elapsed, fraction = working(state, key)
	return if elapsed then { clock = elapsed, bar = fraction } :: { [string]: number } else nil
end

-- A preview's Working line: the clock (`elapsed`, m:ss) and the estimated bar (`meter`) when there is one; nil when
-- the agent of item `key` is not working. A row, not a kv fact: a kv value holds spans only.
local function clockRow(state: State, key: string): Node?
	local elapsed, fraction = working(state, key)
	if not elapsed then
		return nil
	end
	local kids: { Node } = {
		ui.node("text", { key = "label", spans = { ui.span("Working", "muted") } }),
		ui.node("elapsed", { key = "clock", age = elapsed, format = "clock" }),
	}
	if fraction then
		table.insert(kids, ui.node("meter", { key = "bar", value = fraction, tone = "pending" }))
	end
	return ui.node("row", { key = "working", gap = "sm", align = "center" }, kids)
end

-- A preview's agent part: the Working line while its agent works, then `facts` (the agent's action, ...).
local function agentPart(state: State, key: string?, facts: { { [string]: any } }): { Node }
	local out: { Node } = {}
	local clock = if key then clockRow(state, key) else nil
	if clock then
		table.insert(out, clock)
	end
	if #facts > 0 then
		table.insert(out, ui.node("kv", { key = "agent", items = facts }))
	end

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
-- toned as its row badge, what blocks it, its agent's checked outcome and what its checker found (a failed check
-- lists its findings), then `lead`, the facts its stage acts on first (a review asked of you: its author); then how
-- long its agent has worked, while it works (clockRow).
local function stageFact(state: State, kind: string, item: any, lead: { { [string]: any } }?): { Node }
	local id, blockers = engine.stage(state, kind, item)
	local b = stageBadge(id, state.notes[item.key])
	local items: { { [string]: any } } = { { k = "Stage", v = { ui.span(b.text, b.tone) } } }
	-- Each reason a Blocked PR has, most severe first: its job, then who or what.
	for _, r in (blockers or {}) :: { engine.Blocker } do
		table.insert(items, { k = "Blocked by", v = if r.detail then { ui.span(r.chip, "error"), ui.span(" — " .. r.detail) } else { ui.span(r.chip, "error") } })
	end
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
	local out: { Node } = { ui.node("kv", { key = "stage", items = withValue(items) }) }
	local clock = clockRow(state, item.key)
	if clock then
		table.insert(out, clock)
	end
	return out
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
		local stage, blockers = engine.stage(state, snap.kind, item)
		local row: { [string]: any } = if issues then issueRow(item, state.notes[item.key], stage, repos) else pickerItem(item, state.notes[item.key], stage, blockers, repos)
		decorate(state, snap.kind, item, row, stage, blockers)
		row.tone = state.rings[item.key] -- an arrival (engine.arrive): plotroom.css rings the row in this tone
		table.insert(rows, row)
	end
	tern.json.array(rows)
	snap.rows, snap.rowsRev, snap.rowsMin, snap.rowsState = rows, state.noteSeq, minute, state.rev
	return rows
end

-- The agent map this block holds as one string, "key=state|action|branch|title|last|err|result|ended|attention|reason|blocker|outcome|verdict|check|findings|stop|since|expected|review;"
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
		table.insert(out, k .. "=" .. state.agents[k] .. "|" .. (info.action or "") .. "|" .. (info.branch or "") .. "|" .. (info.title or "") .. "|" .. (info.last or "") .. "|" .. (info.err or "") .. "|" .. (info.result or "") .. "|" .. (info.ended or "") .. "|" .. (info.attention or "") .. "|" .. (info.reason or "") .. "|" .. (info.blocker or "") .. "|" .. (info.outcome or "") .. "|" .. (info.verdict or "") .. "|" .. (info.check or "") .. "|" .. (info.findings or "") .. "|" .. (info.stop or "") .. "|" .. (info.since or "") .. "|" .. (info.expected or "") .. "|" .. (info.review or "") .. ";")
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
		-- Plotroom's omp extension and data directory on this host (core.omp), for the agents the window starts.
		ui.node("text", { key = "omp", text = core.omp(), hidden = true }),
	}
	for _, r in state.replies do
		table.insert(out, ui.node("text", { key = "r" .. r.id, text = r.text, hidden = true }))
	end
	return out
end

-- What a click does is drawn on the node itself (DESIGN.md › Buttons and links): an action is Tern's `button` kind, a
-- row or icon that opens something is a link (LINK, plotroom.css underlines it). A node with no click and no href is
-- neither.
local LINK = "plotroom.link"

-- Key names as Tern's keycaps read them: a keycap upper-cases every letter, so an upper-case key is Shift and its letter.
local function keyNames(ks: { string }?): { string }?
	if not ks then
		return nil
	end
	local out: { string } = {}
	for _, k in ks do
		if string.match(k, "^%u$") then
			table.insert(out, "shift")
			table.insert(out, string.lower(k))
		else
			table.insert(out, k)
		end
	end
	return out
end

-- A Tern button labelled `text` ("" with an `icon`: icon-only, named by `title`); `p` its props, `keys` the key names
-- of the key that does the same. Size `sm` (rows, the preview, cards) unless `p.size` says `md` (bars, overlays, heads).
local function button(text: string, p: { [string]: any }): Node
	p.size = p.size or "sm"
	p.keys = keyNames(p.keys)
	return ui.button(text, p)
end
M.button = button

-- Buttons side by side, wrapping when the preview is narrow (a list would stretch each ring across the row).
local function buttonRow(key: string, buttons: { Node }): Node
	return ui.node("row", { key = key, gap = "sm", wrap = true, align = "center" }, buttons)
end

-- Tern's four states of a part that loads (docs/reference.md › Finer points › Preview): a skeleton shaped like what is
-- on its way (`shape` "rows" or "text", `n` of them), keyed like the part, so the loaded part takes its place.
local function skeleton(key: string, shape: string, n: number): Node
	return ui.node("skeleton", { key = key, shape = shape, rows = if shape == "rows" then n else nil, lines = if shape == "text" then n else nil })
end

-- Nothing to show: one inline row saying what is missing.
local function emptyNode(key: string, title: string): Node
	return ui.node("empty", { key = key, variant = "inline", title = title })
end

-- A failed read: an inline error row (key `<key>-state`) with what failed, the tool's message and a Retry button (key
-- `<key>-retry`, click `act`).
local function failNode(key: string, title: string, message: string, aria: string, act: string): Node
	return ui.node("empty", { key = key .. "-state", variant = "inline", tone = "error", title = title, text = message }, {
		button("Retry", { key = key .. "-retry", icon = "redo", aria = aria, actions = { click = act } }),
	})
end

-- One section of a preview whose rows load, the same for every section: its heading, then while loading a skeleton
-- (`shape`, `n`: see skeleton), after a failed detail load (`fail`) or another failed read (`problem`) an error with why,
-- when it is tried again and Retry, else `body` or, with nothing in it, `No <what>`. `key` prefixes each node's key.
type Load = { loading: boolean?, fail: DetailFail?, problem: string? }
local function section(key: string, head: string, what: string, body: { Node }, load: Load, shape: string, n: number): { Node }
	local out: { Node } = { ui.node("text", { key = key .. "-head", spans = { ui.span(head, "strong") } }) }
	local fail = load.fail
	if load.loading then
		table.insert(out, skeleton(key, shape, n))
		return out
	elseif fail then
		local when = if fail.retryAt then "Trying again at " .. os.date("%H:%M:%S", fail.retryAt) .. "." else "Retry to load them."
		table.insert(out, failNode(key, "Could not load " .. what, brief(fail.problem.message) .. "  " .. when, "Retry loading " .. what, "retry-checks"))
	elseif load.problem then
		-- the Worktrees board's read: its Retry is the board's Refresh (host's retry-checks)
		table.insert(out, failNode(key, "Could not load " .. what, brief(load.problem), "Retry loading " .. what, "retry-checks"))
	elseif #body == 0 then
		table.insert(out, emptyNode(key, "No " .. what))
	end
	table.move(body, 1, #body, #out + 1, out)
	return out
end

-- The check row `item` of the selected pull request's Checks section names ("run<i>"), with that pull request.
local function checkOf(state: State, item: string): (github.Run?, github.Pr?)
	local i = tonumber(string.match(item, "^run(%d+)$"))
	local pr = if state.kind.id == "prs" then selected(state) else nil
	if not i or not pr then
		return nil, nil
	end
	local key = detailKey(state, pr)
	local d = if key then state.details[key] else nil
	return (if d then d.runs else pr.runs)[i], pr
end

-- The window link a check row's `act` follows (`open` its page, `ignore` the plan to ignore it), nil when the row does
-- not offer it. The hidden `checks` col carries the same links, so the window honours only these.
local function checkLink(state: State, act: string, item: string): string?
	local r, pr = checkOf(state, item)
	if not r or not pr then
		return nil
	end
	local i = string.sub(item, 4)
	if act == "open" then
		return if r.url then "plotroom://github/check/" .. i .. "/" .. pct(r.url) else nil
	elseif act == "ignore" then
		return if r.status == "failure" and not engine.ignored(state, pr, r) then "plotroom://github/ignore/" .. i .. "/" .. pct(r.name) else nil
	end
	return nil
end
M.checkLink = checkLink

-- A check row's right-click menu: each entry's action, labelled by Tern from it ("open" reads Open); Tern adds Copy row.
M.CHECK_MENU = { open = "open", ignore = "ignore-in-this-repo…" }
local CHECK_COLS: { Col } = {
	{ id = "check", head = "Check", grow = 1, priority = 2 },
	{ id = "workflow", head = "Workflow", priority = 0 },
	{ id = "took", head = "Took", align = "end", mono = true, priority = 1 },
}
-- How many lines of a failing check's excerpt show before its "N more lines".
local LOG_PREVIEW = 12

-- The Checks section of the selected PR (`section`): what the search carried stays listed under a failed load.
local function checksNodes(state: State, pr: github.Pr): { Node }
	local out: { Node } = {}
	local key = detailKey(state, pr)
	local d = if key then state.details[key] else nil
	local fail = if key then state.detailFail[key] else nil
	local runs: { github.Run } = if d then d.runs else pr.runs
	local total = if d then d.total else pr.runTotal

	-- Every check, grouped by state: Failing, Running and Queued, each headed with its count, then Passed and Skipped in
	-- one fold, folded ("Passed 12 · Skipped 1"); required first within a group (github.runs' order). Each group is a
	-- table: the check (a `workflow / job` name shows the job) after a dot in its status's tone, Required, a Likely flaky
	-- mark and why, and Ignored after it; the CI that ran it; how long it ran or has been running. A click opens its
	-- page; its menu also ignores a failing check in this repository (`checkLink`). The tooltip spells it all out.
	local marks = engine.flakyMarks(state, pr)
	local groups: { [string]: { TableRow } } = { failing = {}, running = {}, queued = {}, passed = {}, skipped = {} }
	local links: { Node } = {}
	local now = os.time()
	for i, r in runs do
		local workflow, job = string.match(r.name, "^(.*) / (.+)$")
		-- An ignored failing check still shows failing, marked Ignored (it blocks nothing).
		local ignored = r.status == "failure" and engine.ignored(state, pr, r)
		local mark = if marks and r.status == "failure" and r.url then marks[r.url] else nil
		local flaky = if mark then "Likely flaky · " .. mark.reason else nil
		local ci = r.ci or workflow
		local what = r.name .. " — " .. r.detail .. (if r.required then " (required)" else "") .. (if ignored then " (ignored)" else "") .. (if flaky then " — " .. flaky else "") .. (if ci then " · " .. ci else "")
		local name: { any } = { job or r.name }
		for _, note in { if r.required then "Required" else nil, flaky, if ignored then "Ignored" else nil } :: { string? } do
			if note then
				table.insert(name, ui.span(" · " .. note, "muted"))
			end
		end
		local id = "run" .. i
		local menu: { string } = {}
		for _, act in { "open", "ignore" } do
			local href = checkLink(state, act, id)
			if href then
				table.insert(menu, M.CHECK_MENU[act])
				table.insert(links, ui.node("text", { key = act .. i, href = href, hidden = true }))
			end
		end
		table.insert(groups[r.phase] or groups.skipped, {
			id = id,
			cells = { { text = name, dot = RUN_TONE[r.status] }, ci or "", if r.started then github.took(now - r.started) else r.took or "" },
			menu = if #menu > 0 then menu else nil,
			title = what,
		})
	end
	local function grid(k: string, rows: { TableRow }): Node
		local t = ui.table(CHECK_COLS, rows, { selectable = true })
		local p: { [string]: any } = t.p or {}
		p.key = k
		t.p = p
		return t
	end
	for _, g in { { "failing", "Failing" }, { "running", "Running" }, { "queued", "Queued" } } do
		local rows = groups[g[1]]
		if #rows > 0 then
			table.insert(out, ui.node("text", { key = g[1] .. "-head", spans = { ui.span(g[2] .. " " .. #rows, "muted") } }))
			table.insert(out, grid(g[1], rows))
		end
	end
	local done: { Node } = {}
	local count: { string } = {}
	for _, g in { { "passed", "Passed" }, { "skipped", "Skipped" } } do
		local rows = groups[g[1]]
		if #rows > 0 then
			table.insert(count, g[2] .. " " .. #rows)
			table.insert(done, grid(g[1], rows))
		end
	end
	if #done > 0 then
		table.insert(out, ui.node("section", { key = "done", head = { ui.span(table.concat(count, " · "), "muted") }, collapsible = true, collapsed = true }, done))
	end
	if #links > 0 then
		table.insert(out, ui.node("col", { key = "checks", hidden = true }, links))
	end
	-- Each failing check's first error line, its log excerpt under it (read once per check and head commit,
	-- engine.failures): code with that line marked, clamped to its first lines with Tern's "K more lines". Not in a
	-- collapsible section: Tern applies a code preview only while its disclosure is folded, and a folded section draws
	-- no body. No log viewer: the check's row above opens its page.
	local sha = if d and d.about then d.about.head else nil
	for i, r in runs do
		local log = if r.status == "failure" and sha then engine.ciLog(state, sha, r) else nil
		if log and log.lines then
			local line = log.first or "No error line: its last lines are kept"
			local at = if log.first then table.find(log.lines, log.first) else nil
			local body = { ui.node("code", { key = "log", text = table.concat(log.lines, "\n"), lang = "text", marks = if at then { { line = at, tone = "error" } } else nil, preview = { lines = LOG_PREVIEW } }) }
			if #log.refs > 0 then
				table.insert(body, 1, ui.node("text", { key = "refs", spans = { ui.span("Changed files it names: ", "muted"), ui.span(table.concat(log.refs, ", "), "code") } }))
			end
			table.insert(out, ui.node("section", { key = "fail" .. i, head = { ui.span(r.name .. ": ", "muted"), ui.span(core.clip(line, 160), if log.first then "error" else "muted") } }, body))
		elseif log and log.problem then
			table.insert(out, ui.node("text", { key = "fail" .. i, spans = { ui.span(r.name .. ": log not read: " .. log.problem, "muted") } }))
		end
	end
	if total > #runs then
		table.insert(out, ui.node("text", { key = "runs-more", spans = { ui.span((total - #runs) .. " more not loaded", "muted") } }))
	end
	return section("runs", "Checks", "checks", out, { loading = key ~= nil and d == nil and fail == nil, fail = fail }, "rows", 3)
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
	-- Show Draft review (palette only): while the item's newest run has a Draft review that opened, its agent exited or not.
	if (state.agentInfo[item.key] or {} :: core.AgentInfo).review then
		table.insert(out, { id = "agentreview", label = "agentreview", href = hrefOf(state, item, "agentreview") })
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
		button("", {
			key = "copy",
			icon = "copy",
			variant = "quiet",
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
			tone = "muted",
			title = note.summary,
		}))
	end
	table.insert(chips, ui.node("badge", {
		key = "changes",
		text = if note.dirty == true then "Uncommitted changes" elseif note.dirty == false then "Clean" else "Changes unchecked",
		tone = "muted",
		title = note.summary,
	}))
	local ahead = note.ahead or 0
	if ahead > 0 then
		table.insert(chips, ui.node("badge", { key = "ahead", text = ahead .. " unpushed", tone = "muted", title = "Commits on this branch its upstream does not have" }))
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
		table.insert(buttons, button("Go to tab", { key = "go", icon = "arrow-right", keys = tab.keys, aria = "Go to the tab working in this worktree", actions = { click = "goto" } }))
	else
		table.insert(buttons, button("Open in new tab", { key = "open", icon = "plus", keys = if fresh then fresh.keys else nil, aria = "Open a new tab in this worktree", actions = { click = "worktree" } }))
	end
	table.insert(buttons, button("Remove worktree", { key = "remove", icon = "trash", aria = "Remove this worktree", actions = { click = "remove-worktree" } }))
	if note.path and tern.fs.exists(note.path) then
		table.insert(buttons, button("Open Git view", { key = "git", icon = "merge", aria = "Open Tern's Git view on this worktree", actions = { click = "open-git" } }))
	end
	table.insert(body, buttonRow("actions", buttons))
	return { ui.node("card", { key = "worktree", tone = noteTone(note) }, body) }
end

-- The description part of the item with key `key`. A folded bare card shows its first lines under a fade and Tern's
-- own "N more lines" button; its head row is hidden by plotroom.css, so the text stands alone. `collapsed` mirrors
-- state.descOpen (set by the card's toggle event), so Show less, a value the card has not been sent yet, folds it again.
-- While the details load (`loading`), a skeleton of its first lines; nothing for a blank body.
local function descNodes(state: State, key: string, body: string?, loading: boolean): { Node }
	if loading then
		return { skeleton("description", "text", 3) }
	elseif not body or not string.find(body, "%S") then
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
		table.insert(nodes, button("Show less", { key = "less", icon = "chev-up", variant = "quiet", actions = { click = "fold-description" } }))
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
		return { head, skeleton("summary", "text", 3) }
	elseif status == "failed" then
		return { head, failNode("summary", "Summary not made", brief(text or ""), "Make the Summary again", "retry-summary") }
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

-- The preview's own controls under the Stage, as buttons: Unpin while the item is pinned, Unsnooze while it is snoozed
-- (nil when there is none). The Next move sits in the head card's end (itemHead).
local function previewControls(state: State, item: any): Node?
	local rows: { Node } = {}
	local map = keys.load()
	if engine.pinFor(state.pins, item.key) then
		table.insert(rows, button("Unpin", { key = "unpin", icon = "x", aria = "Unpin " .. item.key .. " from the Pins group", actions = { click = "unpin" } }))
	end
	local st = if state.snap then engine.status(state, state.snap.kind, item) else nil
	if st and st.snoozed then
		-- Snooze until tomorrow on a snoozed item ends its snooze (engine.mark), so its key is this button's.
		table.insert(rows, button("Snoozed until " .. os.date("%a %H:%M", st.snoozeUntil) .. " · Unsnooze", { key = "unsnooze", icon = "x", keys = keys.caps(map, "snooze"), aria = "End the snooze of " .. item.key, actions = { click = "unsnooze" } }))
	end
	if #rows > 0 then
		return buttonRow("controls", rows)
	end
	return nil
end

-- An item preview's head (PR and issue): one card, its icon the kind's, its head the title with its meta line under it
-- (the ref, where it lives and the integration), and at its end the state badge, the suggested next move for the
-- item's stage (engine.nextMove, run as the Next move queue action), Copy link and Open. The meta is a line of the head,
-- not Tern's `meta` prop: that one is drawn after the title on its line and is cut to nothing in a narrow preview.
local function itemHead(state: State, item: any, icon: string, ref: string, where: string, integration: string, badge: any, page: { copy: string, open: string, what: string }): Node
	local tail: { Node } = { ui.node("badge", { key = "state", text = badge.text, tone = badge.tone, title = badge.title }) }
	local move = engine.nextMove(state, state.kind.id, item)
	if move then
		table.insert(tail, button(move.label, { key = "next", icon = "arrow-right", keys = keys.caps(keys.load(), "next"), title = "Next move: " .. move.label, aria = "Next move: " .. move.label, actions = { click = "next" } }))
	end
	table.insert(tail, button("", { key = "copy", icon = "copy", variant = "quiet", href = page.copy, actions = { click = "copy" }, title = "Copy link", aria = "Copy link to " .. page.what }))
	table.insert(tail, ui.node("icon", { key = "open", name = "globe", role = LINK, href = page.open, actions = { click = "open" }, title = "Open", aria = "Open " .. page.what }))
	return ui.node("card", {
		key = "head",
		-- plotroom.css wraps the end under the title when both do not fit, instead of squeezing the title.
		role = "plotroom.head",
		icon = icon,
		head = core.QUEUE_ID .. ".head.top",
		["end"] = core.QUEUE_ID .. ".head.end",
	}, {
		ui.node("col", { key = "top" }, {
			ui.node("text", { key = "title", spans = { ui.span(item.title, "strong") } }),
			ui.node("text", { key = "meta", spans = { ui.span(ref .. " · " .. where, "mono"), ui.span(" · " .. integration, "muted") } }),
		}),
		ui.node("row", { key = "end", gap = "xs", align = "center", justify = "end", wrap = true }, tail),
	})
end

-- The strip of stat tiles under an item preview's head (at most four; Tern's `stats`).
local function statsNode(items: { { [string]: any } }): Node
	return ui.node("stats", { key = "stats", items = items })
end

-- A pull request's preview tabs, in order; only the active one's panel is drawn.
local TABS = { "overview", "checks", "threads", "reviewers" }
M.TABS = TABS

-- Whether the selected item's preview shows tabs: a pull request's, in a view's List (not Now, the Worktrees board, the
-- Agents list or a Board).
function M.tabsShown(state: State): boolean
	return state.kind.id == "prs" and not (state.boardOn or state.agentsOn or state.nowOn) and not engine.lanesShown(state) and selected(state) ~= nil
end

-- Tab and Shift+Tab (and the key footer's segs): the next (`d` 1) or previous (-1) preview tab, wrapping; false while
-- no tabs show.
function M.moveTab(state: State, d: number): boolean
	if not M.tabsShown(state) then
		return false
	end
	local at = table.find(TABS, state.previewTab or "overview") or 1
	state.previewTab = TABS[(at - 1 + d) % #TABS + 1]
	return true
end

-- The worktree, agent and Now previews' first rows, in one shape: its head (the ref, the kind tag and its state badge at
-- the right end, pushed there by an empty growing column), then its title.
local function headNodes(ref: string, tag: { text: string, tone: string }, badge: any, title: string): { Node }
	local head: { Node } = { ui.text({ ui.span(ref, "mono") }), ui.node("badge", { key = "integration", text = tag.text, tone = tag.tone }) }
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

-- The Checks tile of a pull request's stats: how many fail or run of all its checks (the rows read so far, `total` the
-- count GitHub gave), else its rollup (`check`); None without any.
local function checksStat(runs: { github.Run }, total: number, check: { text: string, tone: string }?): { [string]: any }
	local failing, running = 0, 0
	for _, r in runs do
		if r.phase == "failing" then
			failing += 1
		elseif r.phase == "running" or r.phase == "queued" then
			running += 1
		end
	end
	local n = math.max(total, #runs)
	if failing > 0 then
		return { label = "Checks", value = failing .. " of " .. n .. " failing", tone = CHECK.failure.tone }
	elseif running > 0 then
		return { label = "Checks", value = running .. " of " .. n .. " running", tone = CHECK.pending.tone }
	elseif check then
		return { label = "Checks", value = check.text, tone = check.tone, sub = if n > 0 then n .. (if n == 1 then " check" else " checks") else nil }
	end
	return { label = "Checks", value = "None" }
end

-- A tab's label: its name, then a muted count when there is one.
local function tabLabel(name: string, n: number?): { any }
	return if n then { ui.span(name .. " "), ui.span(tostring(n), "muted") } else { ui.span(name) }
end

-- pr: selected(state) while the active view lists pull requests; acts: itemActions(state, pr, open). The head card, the
-- stats, the tabs (Overview, Checks, Threads, Reviewers) and only the active tab's panel; Overview's parts follow the
-- order every preview shares (docs/reference.md › Triage › Preview).
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
	local load: Load = { loading = loading, fail = fail }
	-- The merge state as the search carried it until the details load; it says nothing about a merged or closed PR.
	local merge = if about then about.merge else pr.merge
	local m = if merge and pr.state == "open" then MERGE_STATE[merge] or MERGE_STATE.unknown else nil
	local runs: { github.Run } = if detail then detail.runs else pr.runs
	local total = math.max(if detail then detail.total else pr.runTotal, #runs)
	local reviewers: { Node } = {}
	for i, r in (if about then about.reviews else {}) :: { github.Review } do
		local v = VERDICT_ROW[r.state]
		if v then
			local what = "@" .. r.login .. " — " .. v.text
			table.insert(reviewers, ui.node("item", { key = "r" .. i, label = "@" .. r.login, icon = v.icon, tone = v.tone, title = what, aria = what }))
		end
	end
	local threadList: { github.Thread } = if about then about.threads else {}

	local out: { Node } = {
		buttonLinks(state, pr, acts),
		itemHead(state, pr, "merge", "#" .. pr.number, pr.repo, INTEGRATIONS.github.label, STATE_BADGE[stateKind(pr)] or STATE_BADGE.open, { copy = pr.url, open = hrefOf(state, pr, "open"), what = "pull request #" .. pr.number }),
		statsNode({
			checksStat(runs, total, check),
			{ label = "Changes · " .. pr.files .. (if pr.files == 1 then " file" else " files"), value = { ui.span("+" .. pr.additions .. " −" .. pr.deletions) } },
			{ label = "Comments", value = tostring(pr.comments) },
			{ label = "Age", value = github.age(pr.created), title = "Opened " .. github.age(pr.created) .. " ago" },
		}),
	}
	local tab = state.previewTab or "overview"
	table.insert(out, ui.node("tabs", {
		key = "tabs",
		role = "plotroom.tabs", -- plotroom.css wraps a strip wider than the preview instead of clipping its last tab
		active = tab,
		items = {
			{ id = "overview", label = tabLabel("Overview") },
			{ id = "checks", label = tabLabel("Checks", if total > 0 then total else nil) },
			{ id = "threads", label = tabLabel("Threads", if about then #threadList else nil) },
			{ id = "reviewers", label = tabLabel("Reviewers", if about then #reviewers else nil) },
		},
	}))
	local panel = out -- only the active tab's parts follow the tabs
	if tab == "checks" then
		addPart(panel, "checks", checksNodes(state, pr))
	elseif tab == "threads" then
		-- Unresolved review threads, read-only: who started each, where, its first line; each opens its thread on GitHub
		-- through the check link route (window.luau's CHECK_NODES).
		local threads: { Node } = {}
		for i, t in threadList do
			local where = if t.path then printable(t.path) .. (if t.line then ":" .. t.line else "") else nil
			local by = "@" .. t.by .. (if where then " · " .. where else "")
			local text = if t.text ~= "" then printable(t.text) else "(no text)"
			table.insert(threads, ui.node("item", {
				key = "run" .. i,
				role = LINK,
				label = text,
				detail = { ui.span(by, "muted") },
				icon = "message",
				title = by .. " — " .. text,
				aria = "Thread by " .. by .. ": " .. text,
				href = "plotroom://github/check/" .. i .. "/" .. pct(t.url),
				actions = { click = "open" },
			}))
		end
		addPart(panel, "threads", section("threads", "Unresolved threads", "unresolved threads", if #threads > 0 then { ui.node("list", { key = "threads" }, threads) } else {}, load, "rows", 2))
	elseif tab == "reviewers" then
		addPart(panel, "reviewers", section("reviewers", "Reviewers", "reviewers", if #reviewers > 0 then { ui.node("list", { key = "reviewers" }, reviewers) } else {}, load, "rows", 2))
	else
		-- A review asked of you leads with who wrote it; elsewhere it is a plain fact.
		local asked = engine.reviewAsked(state, pr)
		local author = { k = "Author", v = "@" .. pr.author }
		local facts: { { [string]: any } } = {
			{ k = "Merge", v = if m then { ui.span(m.text, m.tone) } else nil },
			{ k = "Review", v = if review then { ui.span(review.text, review.tone) } else nil },
			if asked then { k = "Author" } else author,
			{ k = "Updated", v = github.age(pr.updated) .. " ago" },
		}
		addPart(panel, "summary", summaryNodes(state, pr, true))
		local status: { Node } = stageFact(state, "prs", pr, if asked then { author } else nil)
		local controls = previewControls(state, pr)
		if controls then
			table.insert(status, controls)
		end
		addPart(panel, "status", status)
		addPart(panel, "worktree", worktreeNodes(state, pr.key, acts))
		addPart(panel, "description", descNodes(state, pr.key, if about then about.body else nil, loading))
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
		addPart(panel, "properties", properties)
		addPart(panel, "linked", section("linked", "Linked issues", "linked issues", linkedIssues(if about then about.closing else {}, if detail then detail.noted else nil), load, "rows", 2))
	end
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

-- The selected issue's preview: the head card, the stats (Comments, Age, Linked), then its parts in the order every
-- preview shares (docs/reference.md › Triage › Preview); no tabs. issue: selected(state) while the active view lists
-- issues; acts: itemActions(state, issue, open).
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
	-- The PR whose head is the issue's worktree branch joins a GitHub issue's linked pull requests; a Jira issue's
	-- linked items are issues, so it has a Linked pull requests section of its own while there is one.
	local headPr = headPrList(code, if loaded and not loaded.headLinked then loaded.headPr else nil)
	local linkedCount = if detail then #detail.linked + (if headPr then 1 else 0) else nil
	local out: { Node } = {
		buttonLinks(state, issue, acts),
		itemHead(state, issue, ISSUE_ICON, ref, issue.repo, INTEGRATIONS[issue.tracker].label, sb, { copy = issue.url, open = hrefOf(state, issue, "open"), what = "issue " .. ref }),
		statsNode({
			{ label = "Comments", value = if comments then tostring(comments) else "—" },
			{ label = "Age", value = if created then github.age(created) else "—", title = if created then "Opened " .. github.age(created) .. " ago" else nil },
			{ label = "Linked", value = if linkedCount then tostring(linkedCount) else "—" },
		}),
	}
	addPart(out, "summary", summaryNodes(state, issue, false))
	local status = stageFact(state, "issues", issue)
	local controls = previewControls(state, issue)
	if controls then
		table.insert(status, controls)
	end
	addPart(out, "status", status)
	addPart(out, "worktree", worktreeNodes(state, issue.key, acts))
	addPart(out, "description", descNodes(state, issue.key, if detail then detail.body else nil, loading))
	addPart(out, "properties", properties)
	local linked = linkedNodes(issue.tracker, detail)
	if headPr and issue.tracker == "github" then
		table.insert(linked, headPr)
	end
	local heading = INTEGRATIONS[issue.tracker].linked
	addPart(out, "linked", section("linked", heading, string.lower(heading), linked, { loading = loading, fail = fail }, "rows", 2))
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
			button("Close", { key = "close", size = "md", icon = "x", keys = { "esc" }, aria = "Close the shortcut list", actions = { click = "close-help" } }),
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
		icon = "sparkle",
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

-- The Worktrees table's node id (host.luau names its select and activate events by it) and its columns
-- (DESIGN.md › Worktrees table): Name hides last, Path is cut in the middle and hides first. Path grows with Name: Tern
-- cuts only a column that takes spare width, and hides one that does not fit whole (smoke's "some width shows Path cut").
M.WORKTREES_TABLE = core.QUEUE_ID .. ".worktrees.list.table"
local WORKTREES_CARD = core.QUEUE_ID .. ".worktrees.side.worktree"
local WORKTREE_COLS: { Col } = {
	{ id = "name", head = "Name", grow = 1, priority = 4 },
	{ id = "repo", head = "Repository", mono = true, priority = 1 },
	{ id = "status", head = "Status", priority = 3 },
	{ id = "linked", head = "Linked", mono = true, priority = 2 },
	{ id = "path", head = "Path", mono = true, truncate = "middle", grow = 2, priority = 0 },
}

-- The card beside the Worktrees table, of the selected worktree, in the order every preview shares (docs/reference.md
-- › Finer points › Preview): its name as the head, its branch as the meta and Remove at the head's end, then what it
-- needs (cleanup, a refusal), its git facts, the pull request and issue it was made for (each as the tracker answered,
-- or why not) and, hidden, the links the window opens its folder and the Git view with.
local function worktreeCard(state: State): Node?
	local row, at = engine.boardSelected(state)
	if not row then
		return nil
	end
	local p = board.preview(state.board, row)
	local facts: { { [string]: any } } = {}
	for _, f in p.facts do
		-- The changes are the table's Status cell (its tooltip spells them out), not a fact here too.
		if f[1] ~= "Status" then
			local style: string? = if f[1] == "Repository" then "mono" elseif f[1] == "Branch" or f[1] == "Path" or f[1] == "Head" then "code" else nil
			table.insert(facts, { k = f[1], v = { ui.span(f[2], style) } })
		end
	end
	local kids: { Node } = {}
	local removable = not row.locked and not row.missing -- the guard of engine.boardAct's wt-remove
	table.insert(kids, button("Remove", {
		key = "remove",
		icon = "trash",
		keys = keys.caps(keys.load(), "wt-remove"),
		aria = "Remove this worktree",
		disabled = if removable then nil else "Locked or missing worktrees are not removed here.",
		actions = { click = "wt-remove" },
	}))
	local cleanup = if row.candidate == "merged" then "Its pull request is merged" elseif row.candidate == "closed" then "Its item is closed" elseif row.candidateChecked then "Its item is still open" else nil
	local status: { Node } = {}
	local needs = withValue({
		{ k = "Cleanup", v = if cleanup then { ui.span(cleanup) } else nil },
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
			table.insert(body, emptyNode(key .. "-empty", sec.ref .. " was not found by its tracker."))
		elseif sec.state == "ready" and info then
			table.insert(body, ui.node("row", { key = key .. "-title", gap = "xs", align = "center" }, {
				ui.text({ ui.span(sec.ref, "mono") }),
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
		local nodes = section(key, heading, sec.ref, body, { loading = sec.state == "loading", problem = if sec.state == "error" then sec.problem or "no answer" else nil }, "text", 2)
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
	return ui.node("card", {
		key = "worktree",
		role = "plotroom.worktree",
		head = { ui.span(board.name(row), "strong") },
		meta = { ui.span(board.label(row), "mono") },
		["end"] = WORKTREES_CARD .. ".remove",
	}, kids)
end

-- The Worktrees table's Linked cell: a pull request's or GitHub issue's `#N` (an issue key is `repo#N` or `N`), else the
-- Jira key, else nothing (an unnoted worktree).
local function linkedOf(row: any): string
	if row.number then
		return "#" .. row.number
	end
	local key: string = row.key or ""
	local n = string.match(key, "#(%d+)$") or string.match(key, "^(%d+)$")
	return if n then "#" .. n else key
end

-- The Worktrees scope: its subtitle (the count, or that it is reading, and the first problems) in the picker's head,
-- and in the preview pane, which the `.board` role widens over the hidden list (plotroom.css), the table of every
-- linked worktree beside the selected one's card (DESIGN.md › Worktrees table).
local function boardView(state: State, props: { [string]: any }): Node
	local rows = engine.boardRows(state)
	local chosen = engine.boardSelected(state)
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
			table.insert(sub, ui.span(p, "error"))
		end
	end
	props.icon, props.title, props.subtitle, props.noun = "folder", { ui.span("Worktrees", "strong") }, sub, "worktrees"
	props.placeholder = "Worktrees are not searched"
	props.state, props.message, props.columns, props.query, props.cursor = "ready", nil, {}, nil, nil
	props.role ..= ".board"
	props.items, props.order, props.selected, props.hits = tern.json.array({}), tern.json.array({}), nil, nil
	local open = engine.boardOpen(state)
	local list: { TableRow } = {}
	for _, row in rows do
		local st = board.status(row, open[row.path] == true)
		table.insert(list, {
			id = pickerId("w", row.id),
			cells = {
				{ ui.span(board.name(row)) },
				{ ui.span(row.repo) },
				{ text = { ui.span(table.concat(st.words, " · ")) }, dot = st.tone, title = table.concat(st.titles, " · ") },
				{ ui.span(linkedOf(row)) },
				{ text = { ui.span(row.path) }, title = row.path },
			},
		})
	end
	local empty = if state.boardBusy and not state.board.loaded then "Reading checkouts…"
		elseif next(readCheckouts()) == nil then "No checkouts yet: add a repository's checkout in Settings › Repositories."
		else "No worktrees found."
	local t = ui.table(WORKTREE_COLS, list, { selectable = true, selected = if chosen then pickerId("w", chosen.id) else nil, empty = { ui.span(empty, "muted") } })
	local tp: { [string]: any } = t.p or {}
	tp.key = "table"
	t.p = tp
	local cols: { Node } = { ui.node("col", { key = "list", grow = 2, basis = 0 }, { t }) }
	local side = worktreeCard(state)
	if side then
		table.insert(cols, ui.node("col", { key = "side", grow = 1, basis = 0 }, { side }))
	end
	return ui.node("row", { key = "worktrees", gap = "md", align = "start" }, cols)
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
		{ k = "Action", v = if row.action then { ui.span(printable(row.action)) } else nil },
		{ k = "Branch", v = if row.branch then { ui.span(printable(row.branch), "code") } else nil },
		{ k = "Last run", v = if row.result then { ui.span(printable(row.result .. (if row.ended then " " .. row.ended else ""))) } else nil },
	})
	local kids: { Node } = headNodes(printable(row.key), { text = "Agent", tone = "muted" }, badge, printable(row.title or row.key))
	addPart(kids, "status", if #needs > 0 then { ui.node("kv", { key = "stage", items = needs }) } else {})
	addPart(kids, "agent", agentPart(state, row.key, agent))
	if href then
		local links: { Node } = { ui.node("text", { key = "agentgo", href = href }) }
		for _, act in AGENT_COMMANDS do
			table.insert(links, ui.node("text", { key = act, href = engine.agentHref(row.key, act) }))
		end
		if (state.agentInfo[row.key] or {} :: core.AgentInfo).review then
			table.insert(links, ui.node("text", { key = "agentreview", href = engine.agentHref(row.key, "agentreview") }))
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
		local facts = clockFacts(state, row.key)
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
		table.insert(items, { id = id, label = label, title = label, detail = detail, badges = badges, facts = facts })
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
	props.icon, props.title, props.noun = "sparkle", { ui.span("Agents", "strong") }, "agents"
	props.subtitle = { ui.span(#rows .. " agent" .. (if #rows == 1 then "" else "s"), "muted") }
	props.placeholder = "Agents are not searched"
	props.state = "ready"
	props.empty = { ui.span("No agents are running. Start one from a pull request or issue.", "muted") }
	props.items, props.order, props.hits, props.message = tern.json.array(items), tern.json.array(order), nil, nil
	props.selected = if current then pickerId("g", current.key) else nil
	props.columns, props.query, props.cursor = CLOCK_COLUMNS, nil, nil
end

-- What GitHub's notification reasons say, and how much each wants you; any other reason is shown as GitHub spelled it.
local REASON: { [string]: { text: string, tone: string } } = {
	review_requested = { text = "Review requested", tone = "accent" },
	mention = { text = "Mention", tone = "accent" },
	team_mention = { text = "Team mention", tone = "accent" },
	assign = { text = "Assigned", tone = "accent" },
	approval_requested = { text = "Approval requested", tone = "accent" },
	ci_activity = { text = "CI", tone = "muted" },
	security_alert = { text = "Security alert", tone = "error" },
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
			return { text = "Agent needs input", tone = "accent", title = "Its agent is waiting for your input" }, "Its agent is waiting for your input"
		elseif agent.stop then
			return { text = printable(agent.stop), tone = "accent", title = "Plotroom stopped the item's chain of actions" }, "Plotroom stopped the item's chain of actions: " .. printable(agent.stop)
		elseif agent.check == "fail" then
			return CHECK_BADGE.fail, CHECK_BADGE.fail.title
		elseif agent.attention == "stuck" or agent.attention == "needs-human" then
			local report = REPORT_BADGE[agent.attention]
			return { text = report.text, tone = report.tone, title = report.title }, report.title
		end
		return { text = verdict or "Not verified", tone = "accent", title = "GitHub does not show what its run must leave behind" }, "GitHub does not show what its run must leave behind: " .. (verdict or "Not verified")
	elseif row.rank == 2 then
		-- The chips after it name each job (`why` lists them), so the badge says only Blocked.
		return { text = "Blocked", tone = "error", title = "Your pull request is blocked: " .. (row.why or "") }, "Your pull request is blocked: " .. (row.why or "")
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
	return { text = "Assigned: " .. string.lower(row.why or ""), tone = "accent", title = "Assigned to you, " .. fresh }, "Assigned to you, " .. fresh
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
		stage = stageBadge((engine.stage(state, row.kind, item)), state.notes[item.key])
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
	local kids: { Node } = headNodes(ref, { text = if jira then INTEGRATIONS.jira.label else INTEGRATIONS.github.label, tone = "muted" }, badge, printable(row.title))
	addPart(kids, "status", {
		ui.node("kv", {
			key = "stage",
			items = withValue({
				{ k = "Why", v = { ui.span(sentence) } },
				{ k = "Stage", v = if stage then { ui.span(stage.text, stage.tone) } else nil },
				{ k = "Chain", v = if agent and agent.stop then { ui.span("Stopped: " .. printable(agent.stop), "accent") } else nil },
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
	local agentFacts = withValue({
		{ k = "Action", v = if agent and agent.action then { ui.span(printable(agent.action)) } else nil },
	})
	addPart(kids, "agent", agentPart(state, row.key, agentFacts))
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
		local chips: { any } = {}
		if row.item and row.kind then
			local stage, blockers = engine.stage(state, row.kind, row.item)
			local note = state.notes[row.key]
			-- Only a row listed as Blocked carries its chips and the first one's detail: elsewhere its first badge says why
			-- Now lists it.
			local mine = if row.rank == 2 then blockers else nil
			chips = chipBadges(mine)
			item = if row.kind == "issues" then issueRow(row.item, note, stage, true) else pickerItem(row.item, note, stage, mine, true)
		else
			local detail: { any } = {}
			if row.notice then
				table.insert(detail, ui.span(printable(row.notice.repo), "mono"))
				if row.notice.number then
					table.insert(detail, " · ")
					table.insert(detail, ui.span("#" .. row.notice.number, "mono"))
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
		item.facts = if row.key then clockFacts(state, row.key) else nil
		local badges: { any } = { badge }
		for _, c in chips do
			table.insert(badges, c)
		end
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
		table.insert(sub, ui.span((if #sub > 0 then " · " else "") .. printable(line), "error"))
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
	props.columns, props.query, props.cursor = CLOCK_COLUMNS, nil, nil
end

-- A card's right-click menu, as ids its `action` events carry (host.luau's Board card events): a view's card offers
-- what its keys do on the selected item; Now's only Open, Enter's: Worktree, Agent and Snooze act on a view's
-- selected item, which Now's row is not.
local CARD_MENU, NOW_CARD_MENU = { "open", "worktree", "agent", "snooze" }, { "open" }

-- A Board (engine.laneColumns, Now's or a view's): a row of columns, each a `card` headed by its name and count whose
-- cards scroll inside it, the fold's columns under a button that shows or hides them (open while the selection is in
-- it). A `scroll` has no selected item to keep in view and plugins get no scroll events, so each time the selection
-- moves to another card the block sends a `reveal` op for it once the view is drawn.
local function boardNode(state: State, bar: boolean?): Node
	local cols = engine.laneColumns(state)
	local at = engine.laneAt(state)
	local chosen = engine.laneSelected(state)
	local open = state.lanesFold or (at > 0 and cols[at].fold == true)
	-- A column caps its height so its cards scroll in it, in the block's sans lines (18px; a cell row is about nine
	-- tenths of one): the block's rows less the picker's head, the column's head and padding, the fold's button and, with
	-- `bar`, the key footer in the dock (24px). Measured in smoke's "Now as a Board", with a line or two to spare.
	local lines = math.max(6, math.floor(state.cx.rows * 0.9) - (if bar then 11 else 9))
	local menu = if state.nowOn then NOW_CARD_MENU else CARD_MENU
	local shown: string? = nil
	-- A card: its number (and Snoozed) as its head, and on Now why Now lists it; on a view what blocks it, else New or
	-- Changed, as its List row's badges say, as one badge under the head (a head `end` is drawn over the number in a
	-- narrow column); its title under it, clamped to two lines ending in `…`. A Blocked card has room for one badge: its
	-- most severe chip (the tooltip lists them all).
	local function card(row: any): Node
		local badge: { text: string, tone: string, title: string? }? = nil
		local snoozed = row.snoozed
		if state.nowOn then
			local why = nowWhy(row)
			badge = why
			if row.rank == 2 and row.item and row.kind then
				local _, blockers = engine.stage(state, row.kind, row.item)
				local first = if blockers then blockers[1] else nil
				if first then
					badge = { text = first.chip, tone = "error", title = why.title }
				end
			end
		else
			local _, blockers = engine.stage(state, row.kind, row.item)
			local st = engine.status(state, row.kind, row.item)
			snoozed = st and st.snoozed
			local chips: { string } = {}
			if blockers then
				for _, b in blockers do
					table.insert(chips, b.chip)
				end
			end
			badge = if #chips > 0 then { text = chips[1], tone = "error", title = table.concat(chips, " · ") }
				elseif st and st.fresh == "new" then { text = "New", tone = "accent", title = "Not marked seen yet" }
				elseif st and st.fresh == "changed" then { text = "Changed", tone = "accent", title = "Changed since you marked it seen" }
				else nil
		end
		local ref = if row.key then printable(row.key) elseif row.notice then printable(row.notice.repo) else ""
		local head: { any } = { ui.span(ref, "mono") }
		if snoozed then
			table.insert(head, ui.span(" · Snoozed", "muted"))
		end
		local kids: { Node } = {}
		if badge then
			table.insert(kids, ui.node("row", { key = "tags" }, { ui.node("badge", { key = "badge", text = badge.text, tone = badge.tone }) }))
		end
		table.insert(kids, ui.node("text", { key = "title", spans = { ui.span(printable(row.title)) }, lines = 2 }))
		local p: { [string]: any } = {
			key = row.id,
			head = head,
			selected = row.id == chosen,
			title = if badge then badge.title else nil,
			actions = { click = "lane-pick", dblclick = "open", menu = menu },
		}
		return ui.node("card", p, kids)
	end
	local function column(group: string, col: any): Node
		local cards: { Node } = {}
		local list = core.QUEUE_ID .. ".board." .. group .. "." .. col.id .. ".list"
		for _, row in col.rows do
			local id = list .. "." .. row.id
			table.insert(cards, card(row))
			if row.id == chosen then
				shown = id
			end
		end
		-- An empty lane is Tern's empty row in the scroller's place (and key).
		return ui.node("card", { key = col.id, head = col.label, meta = tostring(#col.rows), role = "plotroom.lane", grow = 1, basis = 0 }, {
			if #cards == 0 then emptyNode("list", "None") else ui.node("scroll", { key = "list", gap = "sm", max = { h = lines .. "lines" } }, cards),
		})
	end
	local lanes: { Node } = {}
	local folded: { Node } = {}
	local hidden: { string } = {}
	for _, col in cols do
		if col.fold then
			table.insert(folded, column("fold", col))
			table.insert(hidden, col.label .. " " .. #col.rows)
		else
			table.insert(lanes, column("lanes", col))
		end
	end
	local kids: { Node } = {
		ui.node("row", { key = "lanes", gap = "md", align = "start" }, lanes),
		buttonRow("foldbar", {
			button((if open then "Hide " else "Show ") .. table.concat(hidden, " · "), { key = "fold", size = "md", icon = if open then "chev" else "chev-r", actions = { click = "lanes-fold" } }),
		}),
	}
	if open then
		table.insert(kids, ui.node("row", { key = "fold", gap = "md", align = "start" }, folded))
	end
	if shown and shown ~= state.laneShown then
		local id: string = shown
		state.laneShown = id
		tern.timer(0, function()
			if engine.alive(state) and state.laneShown == id then
				state.cx:frame({ { "reveal", id, "nearest" } })
			end
		end)
	end
	return ui.node("col", { key = "board", role = "plotroom.board", gap = "sm" }, kids)
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
		local icon = if how == "done" then "check" elseif how == "todo" then "arrow-right" else nil
		-- A line's one action: a setup guide is a page it opens (a link row); anything else does the step (a button,
		-- with what it names beside it).
		if click and not string.find(click, "^setup%-guide=") then
			table.insert(lines, ui.node("row", { key = key, gap = "sm", wrap = true, align = "center" }, {
				button(label, { key = "do", icon = icon, href = href, actions = { click = click } }),
				ui.node("text", { key = "what", spans = { ui.span(value or "", "muted") } }),
			}))
			return
		end
		table.insert(lines, ui.node("item", {
			key = key,
			label = label,
			value = value,
			icon = icon,
			tone = if how == "done" then "success" elseif how == "wait" then "muted" else nil,
			href = href,
			actions = if click then { click = click } else nil,
			role = if click then LINK else nil,
		}))
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
			button("Use them", { key = "use", icon = "check", actions = { click = "setup-keys=use" } }),
			button("No thanks", { key = "no", icon = "x", actions = { click = "setup-keys=no" } }),
		})
	end
	if not state.getStarted and (asking or todo == 0) then
		return nil
	end
	return ui.node("card", { key = "get-started" }, {
		ui.node("text", { key = "head", spans = { ui.span("Get started", "strong"), ui.span("  " .. (if todo == 0 and not asking then "All set" else todo .. " to do"), "muted") } }),
		ui.node("col", { key = "lines", gap = "xs" }, lines),
		shortcuts,
		buttonRow("end", {
			button(if todo == 0 then "Close" else "Dismiss", { key = "dismiss", icon = "x", variant = "quiet", aria = "Hide the Get started checklist; Commands › Get started shows it again", actions = { click = "setup-dismiss" } }),
		}),
	})
end

-- The queue's picker; also drawn under Settings' side sheet, where keys go to Settings (so no search caret). `bar`: the
-- key footer sits under it.
function M.queuePicker(state: State, bar: boolean?): Node
	state.barDue = nil -- working() notes the soonest step of an estimated bar drawn below
	local snap, problem, view, item = state.snap, state.problem, activeView(state), selected(state)
	local vis = filtered(state)
	local open = openItems(state)
	local items: { any } = if snap then rowsOf(state, snap) else tern.json.array({})
	local order: { any } = if vis then vis.order else tern.json.array({})

	-- The active view's name is the heading; the sidebar lists them all.
	local title: { any } = { ui.span(if view then view.name else "Plotroom", "title") }
	if snap and problem then
		table.insert(title, ui.span("  stale", "muted"))
	elseif snap and not snap.complete then
		table.insert(title, ui.span("  partial", "muted"))
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
		note(ui.span("Paused by GitHub until " .. os.date("%H:%M:%S", os.time() + wait), "muted"))
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
		note(ui.span((headOf(state, problem.kind) or "Plotroom") .. ", showing the last results", "muted"))
	end
	if snap and not snap.complete then
		note(ui.span(snap.note or "Partial results: narrow this view", "muted"))
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
		-- and folds the scope rail into its dropdown at 127 columns or fewer (`.narrow`: the block's own width), and
		-- ends above the key footer (`.keys`).
		role = "plotroom.queue" .. (if state.settings then ".aside" else "") .. (if dropdown then ".narrow" else "") .. (if bar then ".keys" else ""),
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
	local laid = false -- Now is drawn as a Board
	if state.boardOn then
		cancelDetails(state) -- no checks load for a queue preview that is not shown
		preview = { boardView(state, props) }
	elseif state.agentsOn then
		cancelDetails(state)
		preview = agentsPreview(state)
		agentsProps(state, props)
	elseif state.nowOn and not (engine.lanesShown(state) and #engine.nowRows(state) > 0) then
		cancelDetails(state)
		nowProps(state, props)
		preview = nowPreview(state)
	elseif engine.lanesShown(state) and (state.nowOn or (vis ~= nil and #vis.items > 0)) then
		-- The Board takes the picker's place: its list is emptied and hidden (plotroom.css), the Board drawn in the
		-- preview pane, which then spans the picker. The search field stays: the Board lays out what it lets through.
		cancelDetails(state)
		if state.nowOn then
			nowProps(state, props)
			state.barDue = nil -- the Board draws no Now rows
		end
		laid = true
		preview = { boardNode(state, bar) }
		props.role ..= ".board"
		props.items, props.order, props.selected, props.hits = tern.json.array({}), tern.json.array({}), nil, nil
	else
		preview = if state.kind.id == "issues" then issuePreview(state, item, acts) else previewNodes(state, item, acts)
	end
	if not laid then
		state.laneShown = nil -- a Board drawn again starts at its scrollers' tops: its selected card is revealed anew
	end
	-- Narrow: the scope dropdown beside the title names the view or list, so the title keeps only its markers.
	if dropdown and activeScope and type(props.title) == "table" then
		local rest: { any } = {}
		for i = 2, #props.title do
			table.insert(rest, props.title[i])
		end
		props.title = if #rest > 0 then rest else nil
	end
	-- Tern: `preview = "none"` hides the pane; with no children it would say "Nothing to preview" in a big pane. The Board
	-- and the Worktrees table fill the pane: Get started stays with the List.
	local guide = if laid then nil else checklist(state)
	if guide then
		table.insert(preview, 1, guide)
	end
	local shown = props.selected ~= nil or guide ~= nil or laid or state.boardOn
	props.preview = if shown then "side" else "none"
	-- Tern ticks the clocks; an estimated bar moves only by a redraw, so draw again when the soonest shown bar reaches
	-- its next step (this draw replaces the one planned before it), and never without a bar to move.
	if state.barTimer then
		state.barTimer:cancel()
		state.barTimer = nil
	end
	if state.barDue then
		state.barTimer = tern.timer(state.barDue, function()
			state.barTimer = nil
			if engine.alive(state) then
				state.cx:render()
			end
		end)
	end
	return ui.node("picker", props, if shown then preview else {})
end

-- Every confirm (DESIGN.md › Confirm overlay): a modal overlay keyed `confirm`, its icon (`trash` unless `o.icon`), the
-- question as its head, the consequence in one sentence, the facts (a kv, or `o.lines` as they will be sent), and in
-- its foot Cancel first (quiet, Esc) and then the action (`danger` unless `o.calm`, its key `actKeys`). `o.act` nil: the
-- action is refused (the sentence says why) and only Cancel is offered.
local function confirmOverlay(o: { head: string, meta: string?, icon: string?, body: string, facts: { { [string]: any } }?, lines: { string }?, warn: string?, extra: Node?, label: string, actKeys: { string }, calm: boolean?, cancel: string, act: string? }): Node
	local icon = o.icon or "trash"
	local kids: { Node } = { ui.node("text", { key = "body", spans = { ui.span(o.body, "muted") } }) }
	if o.facts and #o.facts > 0 then
		table.insert(kids, ui.node("kv", { key = "facts", items = o.facts }))
	end
	if o.lines then
		for i, line in o.lines do
			table.insert(kids, ui.node("text", { key = "line-" .. i, spans = { ui.span(line) } }))
		end
	end
	if o.warn then
		table.insert(kids, ui.node("text", { key = "tab", spans = { ui.span(o.warn) } }))
	end
	if o.extra then
		table.insert(kids, o.extra)
	end
	local buttons: { Node } = { button("Cancel", { key = "cancel", size = "md", variant = "quiet", keys = { "esc" }, actions = { click = o.cancel } }) }
	if o.act then
		table.insert(buttons, button(o.label, { key = "act", size = "md", variant = if o.calm then nil else "danger", icon = icon, keys = o.actKeys, actions = { click = o.act } }))
	end
	table.insert(kids, ui.node("row", { key = "foot", gap = "sm", justify = "end", align = "center" }, buttons))
	return ui.node("overlay", { key = "confirm", modal = true, size = "sm", icon = icon, head = o.head, meta = o.meta, foot = "layer.confirm.foot" }, kids)
end

-- A guided mutation's plan (requests.offer), asked in the block: Enter commits it with the plan's own token, Esc drops
-- it. Not `danger`: it changes GitHub or Jira as shown, and destroys nothing Plotroom holds.
local function planConfirm(state: State): Node
	local plan = state.plan
	return confirmOverlay({
		head = plan.confirm.head,
		icon = "merge",
		body = "Sent once, exactly as shown; a change to the selection or the view first cancels it.",
		lines = plan.confirm.lines,
		label = plan.confirm.label,
		actKeys = { "enter" },
		calm = true,
		cancel = "plan-cancel",
		act = "plan-commit=" .. plan.token,
	})
end

-- Stop agent… on an item's live agent (`state.stopping`), asked in the block: Enter stops it, Esc keeps it working.
local function stopConfirm(key: string): Node
	return confirmOverlay({
		head = "Stop the agent for " .. key .. "?",
		icon = "x",
		body = "Its turn ends at once; its worktree and changes are kept.",
		label = "Stop agent",
		actKeys = { "enter" },
		cancel = "stop-cancel",
		act = "stop-agent",
	})
end

-- A message for an agent the window asks about (`state.messaging`, rpc `message`): its note and lines as they will be
-- sent; Enter or Send sends it, `n` or Add a note asks for the note, Esc drops it. Not `danger`: nothing is destroyed.
local function messageConfirm(m: { head: string, lines: { string }, note: boolean }): Node
	return confirmOverlay({
		head = m.head,
		icon = "merge",
		body = "Sent once, exactly as shown, to the agent.",
		lines = m.lines,
		extra = ui.node("row", { key = "notes", justify = "start" }, { button(if m.note then "Edit note…" else "Add a note…", { key = "note", size = "md", variant = "quiet", icon = "pen", keys = { "n" }, actions = { click = "message-note" } }) }),
		label = "Send",
		actKeys = { "enter" },
		calm = true,
		cancel = "message-cancel",
		act = "message-send",
	})
end

-- Settings' Delete or Remove row `s.confirm` asks here, in the block: Enter deletes, Esc keeps it.
function M.deleteConfirm(state: State): Node?
	local row = if state.settings then state.settings.confirm else nil
	local kind, id = string.match(row or "", "^(%a+):(.+)$")
	if not kind or not id then
		return nil
	end
	local head, label, body
	if kind == "pdelete" then
		local pk, pid = kindAndId(id)
		local prompts = if pk then loadPrompts(pk) else nil
		local p = if prompts then promptById(prompts, pid) else nil
		head, label, body = "Delete action “" .. (if p then p.name else "this action") .. "”?", "Delete action", "It is gone from every Plotroom pane."
	elseif kind == "rremove" then
		head, label, body = "Remove repository “" .. id .. "”?", "Remove repository", "Plotroom forgets its checkout and settings; no folder is touched."
	elseif kind == "jremove" then
		head, label, body = "Remove Jira project “" .. id .. "”?", "Remove project", "Plotroom forgets its repositories."
	elseif kind == "reset" then
		head, label = "Reset all settings?", "Reset all settings"
		body = "Views, actions, shortcuts, repositories, branch and folder formats and Get started go back to their defaults in every Plotroom pane; triage, usage and agents are kept."
	else
		local view = viewOf(state, id)
		head, label, body = "Delete view “" .. (if view then view.name else "this view") .. "”?", "Delete view", "It is gone from every Plotroom pane."
	end
	return confirmOverlay({ head = head, body = body, label = label, actKeys = { "enter" }, cancel = "cancel-delete", act = "confirm-delete" })
end

-- The Branch fact of a worktree removal: the branch and, muted, what becomes of it.
local function fateFact(branch: string?, fate: string): { [string]: any }
	local v: { any } = { ui.span(fate, "muted") }
	if branch then
		table.insert(v, 1, ui.span(branch, "code"))
		table.insert(v, 2, ui.span("  "))
	end
	return { k = "Branch", v = v }
end

local TAB_WARN = "A tab works in it and will be left in a folder that no longer exists."
local REMOVE_BODY = "Its folder is deleted; git refuses while it has uncommitted changes, and nothing is forced."

-- The modal that asks before a board row's worktree is removed; Enter or Esc keeps it, `d` or a click removes it.
local function boardConfirm(state: State): Node
	local row: any = nil
	for _, r in engine.boardRows(state) do
		if r.id == state.boardRemoving then
			row = r
		end
	end
	local facts = withValue({ { k = "Path", v = if row then { ui.span(row.path, "code") } else nil } })
	if row then
		table.insert(facts, fateFact(row.branch, board.fate(row)))
	end
	return confirmOverlay({
		head = "Remove this worktree?",
		body = REMOVE_BODY,
		facts = facts,
		warn = if row and engine.boardOpen(state)[row.path] then TAB_WARN else nil,
		label = "Remove",
		actKeys = { "d" },
		cancel = "wt-cancel-remove",
		act = "wt-confirm-remove",
	})
end

-- The modal that asks once before every finished worktree is removed: only the rows Find finished worktrees marked.
local function finishedConfirm(state: State): Node
	local items: { any } = {}
	local ids: { string } = state.boardFinished or {}
	local open = engine.boardOpen(state)
	local tabbed = false
	for _, id in ids do
		for _, r in engine.boardRows(state) do
			if r.id == id then
				table.insert(items, { k = board.label(r), v = { ui.span(r.path, "code") } })
				tabbed = tabbed or open[r.path] ~= nil
			end
		end
	end
	local n = #items
	local unchecked = board.unchecked(state.board)
	return confirmOverlay({
		head = "Remove " .. n .. " finished worktree" .. (if n == 1 then "" else "s") .. "?",
		meta = if unchecked > 0 then unchecked .. " not checked yet" else nil,
		body = "Each folder is deleted, then its branch unless that holds commits saved nowhere else; git keeps a worktree with uncommitted changes, and nothing is forced.",
		facts = withValue(items),
		warn = if tabbed then TAB_WARN else nil,
		label = "Remove all " .. n,
		actKeys = { "d" },
		cancel = "wt-cancel-remove",
		act = "wt-confirm-remove",
	})
end

-- `bar`: requests' keyBar, the key footer in the dock under the picker (plotroom.css ends the picker's sheet above it).
function M.queueView(state: State, palette: Node, bar: Node?): BlockView
	local layer: { Node } = { M.queuePicker(state, bar ~= nil) }
	local removing, stopping = state.removing, state.stopping
	local note = if removing then state.notes[removing] else nil
	if removing and note then
		-- A worktree's removal, asked from its card: where it is, and a warning while a tab works in it.
		local refusal = state.removeRefusal
		local facts = withValue({ { k = "Path", v = if note.path then { ui.span(note.path, "code") } else nil } })
		if not refusal then
			table.insert(facts, fateFact(note.branch, state.removeFate or "Reading its branch from git…"))
		end
		table.insert(layer, confirmOverlay({
			head = "Remove worktree?",
			body = refusal or REMOVE_BODY,
			facts = facts,
			warn = if openItems(state)[removing] then TAB_WARN else nil,
			label = "Remove",
			actKeys = { "d" },
			cancel = "cancel-remove",
			act = if refusal then nil else "confirm-remove",
		}))
	elseif state.boardOn and (state.boardRemoving or state.boardFinished) then
		table.insert(layer, if state.boardFinished then finishedConfirm(state) else boardConfirm(state))
	elseif state.plan then
		table.insert(layer, planConfirm(state))
	elseif stopping then
		table.insert(layer, stopConfirm(stopping.key))
	elseif state.messaging then
		table.insert(layer, messageConfirm(state.messaging))
	elseif state.help then
		table.insert(layer, M.helpOverlay(state))
	end
	return { main = ui.col(M.rpcNodes(state, palette)), dock = if bar then ui.col({ bar }) else nil, layer = ui.col(layer) }
end

return M
