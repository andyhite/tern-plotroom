--!strict
-- The Draft review block (manifest block `review`, title Draft review; docs/reference.md › Land › Draft review): the
-- review an agent Plotroom started proposed (`plugin/omp/plotroom.ts` writes it to `runs/<run>/review.json` in
-- Plotroom's data directory), shown on its pull request's diff beside that agent. You keep, edit or drop each comment,
-- edit the summary, pick the verdict and send your choices back; the window hands them to the agent
-- (`plotroom://review/send`). Nothing here posts to GitHub. Outside the host layer chain, like lens: requires core and
-- render (its button), and requests asks it for a run's file (`fileAt`).
local github = require("../github")
local input = require("../input")
local worktree = require("../worktree")
local core = require("./core")
local render = require("./render")

local ui = tern.ui
local button = render.button

local M = {}

-- The tool (plugin/omp/plotroom.ts) caps texts in UTF-16 units and the file at FILE_BYTES; UTF-8 takes at most 3 bytes
-- per UTF-16 unit, so its largest proposal (100 comments of 10000-unit bodies and suggestions, all CJK) is ~6.4 MB.
local FILE_BYTES = 8 * 1000 * 1000
local SUMMARY_BYTES, BODY_BYTES, PATH_BYTES = 3 * 20000, 3 * 10000, 3 * 1000
local DIFF_BYTES = 20 * 1000 * 1000 -- a diff over this is not read (the comments are listed without their lines)
local CONTEXT = 8 -- rows of diff a comment's card shows around its line
-- How long Sending waits for the window's sent or gone (the window looks for the message for 3 s): a link that never
-- arrives (a remote host's lost link) then falls back to Copy.
M.SEND_TIMEOUT_MS = 15 * 1000

M.VERDICTS = { "comment", "approve", "request_changes" }
local REGULAR_COLS = 100 -- panes narrower than this stack the navigator above the detail (a `col` split)
-- The split's shares, navigator first, until you drag its handle; and each pane's minimum along it.
local SIZES: { [string]: { number } } = { row = { 0.3, 0.7 }, col = { 0.3, 0.7 } }
local MINS: { [string]: { string } } = { row = { "24ch", "40ch" }, col = { "3lines", "8lines" } }
local VERDICT_LABEL: { [string]: string } = { comment = "Comment", approve = "Approve", request_changes = "Request changes" }
local KIND_LABEL: { [string]: string } = { problem = "Problem", question = "Question", suggestion = "Suggestion", nit = "Nit" }

export type Comment = { id: string, path: string, line: number, startLine: number?, side: string, kind: string, body: string, suggestion: string? }
-- A Draft review file as the omp extension writes it (plotroom.ts › validate): `at` tells a revised proposal apart.
export type Proposal = { at: string, repo: string, number: number, head: string, summary: string, verdict: string, comments: { Comment } }
-- One diff row: `t` is " ", "+" or "-"; `o` and `n` its old and new line numbers (on a "+" row `o` is the old line
-- that would come next, on a "-" row `n` the new one), as a hunk header counts them.
type Row = { t: string, text: string, o: number, n: number }
export type Diff = { [string]: { { Row } } } -- a file's path (its old one when deleted) -> its hunks
-- A comment's card: `model` its body as edited, `excerpt` the diff around its line (nil: not on a changed line, so
-- GitHub refuses it and it cannot be kept), `suggested` its suggestion as a diff of the lines it replaces (nil: shown
-- as code).
type Card = { c: Comment, model: input.Model, keep: boolean, excerpt: string?, suggested: string? }
type State = {
	cx: BlockCx,
	run: string,
	cwd: string,
	login: string?,
	gen: number,
	p: Proposal?,
	problem: string?, -- the file could not be read
	diffProblem: string?, -- the diff could not be read: every comment is listed, none placed
	loading: boolean,
	cards: { Card },
	summary: input.Model,
	note: input.Model, -- the line of instructions sent with your choices
	verdict: string,
	own: boolean, -- the pull request is the login's own: GitHub refuses Approve and Request changes, so only Comment
	at: number, -- 0 the summary, 1..#cards a comment, #cards + 1 the instructions
	editing: boolean,
	head: string?, -- the pull request's head now; differs from p.head when it moved since the review
	sending: boolean,
	sends: number, -- Sends so far: a timeout acts only for the Send that armed it
	sent: boolean,
	gone: string?, -- why Send could not reach the agent: Copy is offered
	message: string?, -- what Send hands the agent (hidden `main.send`)
	sizes: { [string]: { number } }, -- the split's shares you dragged, by its `dir` ("row" or "col")
}

local function isTable(v: any): boolean
	return type(v) == "table"
end

local function text(v: any, cap: number): string?
	return if type(v) == "string" and #v <= cap and utf8.len(v) ~= nil then v else nil
end

local function whole(v: any): number?
	return if type(v) == "number" and v >= 1 and v <= 10000000 and v == math.floor(v) then v else nil
end

-- A split's two shares (navigator, detail) as Tern's `change` sends them or as saved, or nil when `v` is not that.
local function sharesOf(v: any): { number }?
	if not isTable(v) or #v ~= 2 then
		return nil
	end
	local a, b = v[1], v[2]
	return if type(a) == "number" and type(b) == "number" and a > 0 and a < 1 and b > 0 and b < 1 then { a, b } else nil
end

-- The Draft review file's text as a Proposal, or nil and why. The extension validated it; this checks the shape again,
-- since anything on disk may have changed.
function M.parse(raw: string): (Proposal?, string?)
	local ok, o = pcall(tern.json.decode, raw)
	if not ok or not isTable(o) or o.version ~= 1 then
		return nil, "The Draft review file is not one Plotroom reads (version 1)."
	end
	local repo, head, at = text(o.repo, 200), text(o.head, 64), text(o.at, 64)
	local number, summary = whole(o.number), text(o.summary, SUMMARY_BYTES)
	if not repo or not string.match(repo, "^[%w%-_%.]+/[%w%-_%.]+$") or not head or #head < 7 or not string.match(head, "^%x+$") or not at or not number or not summary or not VERDICT_LABEL[o.verdict] or not isTable(o.comments) then
		return nil, "The Draft review file is malformed."
	end
	local comments: { Comment } = {}
	for i, c in o.comments do
		local id, path, body = if isTable(c) then text(c.id, 64) else nil, if isTable(c) then text(c.path, PATH_BYTES) else nil, if isTable(c) then text(c.body, BODY_BYTES) else nil
		local line = if isTable(c) then whole(c.line) else nil
		local start = if isTable(c) and c.startLine ~= nil then whole(c.startLine) else nil
		local suggestion = if isTable(c) and c.suggestion ~= nil then text(c.suggestion, BODY_BYTES) else nil
		if
			not id
			or not string.match(id, "^[%w_%-]+$")
			or not path
			or not line
			or not body
			or (c.startLine ~= nil and (not start or start > line))
			or (c.suggestion ~= nil and not suggestion)
			or (c.side ~= "RIGHT" and c.side ~= "LEFT")
			or not KIND_LABEL[c.kind]
			or i > 100
		then
			return nil, "Comment " .. i .. " of the Draft review file is malformed."
		end
		table.insert(comments, { id = id, path = path, line = line, startLine = start, side = c.side :: string, kind = c.kind, body = body, suggestion = suggestion })
	end
	return { at = at, repo = repo, number = number, head = string.lower(head), summary = summary, verdict = o.verdict, comments = comments }, nil
end

-- A unified diff (`git diff`, a/ and b/ prefixes) by file. Git ends a ---/+++ path that holds a space with a tab, which
-- is not part of the path. ponytail: a path git quotes (special characters) is kept quoted, so comments on it are not
-- placed; unquote C-style escapes if that shows up.
function M.parseDiff(raw: string): Diff
	local files: Diff = {}
	local old: string?, new: string? = nil, nil
	local hunks: { { Row } }? = nil
	local hunk: { Row }? = nil
	local o, n = 0, 0
	for line in string.gmatch(raw, "([^\n]*)\n?") do
		local c = string.sub(line, 1, 1)
		if string.sub(line, 1, 11) == "diff --git " then
			old, new, hunks, hunk = nil, nil, nil, nil
		elseif not hunk and string.sub(line, 1, 4) == "--- " then
			old = if line == "--- /dev/null" then nil else string.match(line, "^%-%-%- a/(.-)\t?$")
		elseif not hunk and string.sub(line, 1, 4) == "+++ " then
			new = if line == "+++ /dev/null" then nil else string.match(line, "^%+%+%+ b/(.-)\t?$")
			local path = new or old
			if path then
				local list = files[path] or {}
				files[path] = list
				hunks = list
			end
		elseif string.sub(line, 1, 3) == "@@ " and hunks then
			local a, b = string.match(line, "^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
			if a and b then
				o, n = tonumber(a) :: number, tonumber(b) :: number
				hunk = {}
				table.insert(hunks, hunk :: { Row })
			end
		elseif hunk and (c == " " or c == "+" or c == "-") then
			table.insert(hunk, { t = c :: string, text = string.sub(line, 2), o = o, n = n })
			if c ~= "+" then
				o += 1
			end
			if c ~= "-" then
				n += 1
			end
		elseif hunk and c ~= "\\" then
			hunk = nil -- the next file's header (or the end)
		end
	end
	return files
end

-- Where comment `c` sits in `diff`: its hunk and the row of its (last) line, when that line, and the first of its range,
-- are lines of one hunk on its side (GitHub takes a comment only there).
local function locate(diff: Diff, c: Comment): ({ Row }?, number?)
	local right = c.side == "RIGHT"
	local function rowOf(h: { Row }, line: number): number?
		for i, r in h do
			if (right and r.t ~= "-" and r.n == line) or (not right and r.t ~= "+" and r.o == line) then
				return i
			end
		end
		return nil
	end
	for _, h in diff[c.path] or ({} :: { { Row } }) do
		local at = rowOf(h, c.line)
		if at and (not c.startLine or rowOf(h, c.startLine :: number)) then
			return h, at
		end
	end
	return nil, nil
end

-- The unified diff of CONTEXT rows of hunk `h` around row `at`, for Tern's `diff` node; nil when `c` is not on a line of `diff`.
function M.excerpt(diff: Diff, c: Comment): string?
	local h, at = locate(diff, c)
	if not h or not at then
		return nil
	end
	local last = math.min(#h, at + CONTEXT // 2)
	local first = math.max(1, last - CONTEXT + 1)
	last = math.min(#h, first + CONTEXT - 1)
	local olds, news = 0, 0
	local out: { string } = {}
	for i = first, last do
		local r = h[i]
		olds += if r.t ~= "+" then 1 else 0
		news += if r.t ~= "-" then 1 else 0
		table.insert(out, r.t .. r.text)
	end
	local head = "--- a/" .. c.path .. "\n+++ b/" .. c.path .. "\n@@ -" .. h[first].o .. "," .. olds .. " +" .. h[first].n .. "," .. news .. " @@\n"
	return head .. table.concat(out, "\n") .. "\n"
end

-- Suggestion `c.suggestion` as a unified diff for Tern's `diff` node: the lines it replaces (startLine..line of the new
-- side, as the diff has them) removed and the suggestion added; nil when it has none, is on the old side (GitHub
-- applies suggestions to the new one) or its lines are not all on the diff, and then it is shown as code.
function M.suggestionDiff(diff: Diff, c: Comment): string?
	local h = locate(diff, c)
	local suggestion = c.suggestion
	if not h or not suggestion or c.side ~= "RIGHT" then
		return nil
	end
	local first = c.startLine or c.line
	local out: { string } = {}
	for _, r in h do
		if r.t ~= "-" and r.n >= first and r.n <= c.line then
			table.insert(out, "-" .. r.text)
		end
	end
	if #out ~= c.line - first + 1 then
		return nil
	end
	local added = 0
	for line in string.gmatch((string.gsub(suggestion, "\n$", "")) .. "\n", "([^\n]*)\n") do
		table.insert(out, "+" .. line)
		added += 1
	end
	return "@@ -" .. first .. "," .. #out - added .. " +" .. first .. "," .. added .. " @@\n" .. table.concat(out, "\n") .. "\n"
end

-- Whether the pull request's head `now` is not the reviewed one. The review may name its head by an abbreviated SHA
-- (plotroom.ts › validate takes 7 to 64 hex digits), so a head that starts with it has not moved.
function M.moved(p: Proposal, now: string?): boolean
	return now ~= nil and string.sub(string.lower(now), 1, #p.head) ~= p.head
end

-- What Send hands the agent: your choices as one JSON object (the kept comments exactly as edited, the dropped ids, the
-- verdict and the summary), the line of instructions you typed, and, when the pull request's head moved since the
-- review (`head` now), a request to check the new commits first.
function M.message(p: Proposal, kept: { Comment }, dropped: { string }, verdict: string, summary: string, note: string, head: string?): string
	local comments: { any } = {}
	for _, c in kept do
		table.insert(comments, { id = c.id, path = c.path, line = c.line, startLine = c.startLine, side = c.side, body = c.body, suggestion = c.suggestion })
	end
	local choices = tern.json.encode({
		repo = p.repo,
		number = p.number,
		head = p.head,
		verdict = verdict,
		summary = summary,
		comments = tern.json.array(comments),
		dropped = tern.json.array(dropped),
	})
	local lines = {
		"My choices for your Draft review of " .. p.repo .. "#" .. p.number .. " (head " .. string.sub(p.head, 1, 12) .. "), sent from Plotroom's review block.",
	}
	if head and M.moved(p, head) then
		table.insert(lines, "The pull request's head moved to " .. string.sub(head, 1, 12) .. " since your review: check the new commits first. If they change your findings, propose the review again instead of posting.")
	end
	table.insert(lines, "Post exactly these choices as one review: the kept comments as written (path, line, startLine, side, body; a suggestion as a suggestion block), the summary as its body and the verdict. Post nothing that is not here; the dropped comment ids are not posted.")
	local typed = input.trim(note)
	if typed ~= "" then
		table.insert(lines, "My instructions: " .. typed)
	end
	table.insert(lines, "")
	table.insert(lines, "```json")
	table.insert(lines, choices)
	table.insert(lines, "```")
	return table.concat(lines, "\n")
end

-- The Draft review file of run `run` on this host (`<data directory>/runs/<run>/review.json`).
function M.fileOf(run: string): string
	return tern.plugin.data .. "/runs/" .. run .. "/review.json"
end

function M.validRun(run: any): boolean
	return type(run) == "string" and #run <= 64 and string.match(run, "^[%w_%-]+$") ~= nil
end

-- When run `run`'s Draft review file was written (its `at`), nil when there is none it can read: the window's
-- `review` request, which opens the block on a newer one.
function M.fileAt(run: string): string?
	local ok, raw = pcall(tern.fs.read, M.fileOf(run), FILE_BYTES)
	local p = if ok then M.parse(raw) else nil
	return if p then p.at else nil
end

local function alive(state: State, gen: number): boolean
	return state.gen == gen
end

-- Places the comments on `diff` (nil: unread, every comment listed and keepable), on-diff ones grouped by file in the
-- order the proposal first names each file, those not on a changed line last.
local function place(state: State, p: Proposal, diff: Diff?)
	local order: { string } = {}
	local byFile: { [string]: { Card } } = {}
	local off: { Card } = {}
	for _, c in p.comments do
		local excerpt = if diff then M.excerpt(diff, c) else nil
		local card: Card = { c = c, model = input.new(c.body, true), keep = diff == nil or excerpt ~= nil, excerpt = excerpt, suggested = if diff then M.suggestionDiff(diff, c) else nil }
		if diff and not excerpt then
			table.insert(off, card)
		else
			if not byFile[c.path] then
				byFile[c.path] = {}
				table.insert(order, c.path)
			end
			table.insert(byFile[c.path], card)
		end
	end
	local cards: { Card } = {}
	for _, path in order do
		for _, card in byFile[path] do
			table.insert(cards, card)
		end
	end
	for _, card in off do
		table.insert(cards, card)
	end
	state.cards = cards
end

-- Reads the run's Draft review file again: a new proposal (another `at`) starts over; the same one keeps your edits;
-- one that cannot be read drops the proposal it replaced (and anything it had in flight), so Send never posts it.
-- Then the pull request's head and base (gh) and the diff the review is about (git, where the agent worked).
local function load(state: State)
	local ok, raw = pcall(tern.fs.read, M.fileOf(state.run), FILE_BYTES)
	local p, why: string? = nil, "There is no Draft review for this run on this host."
	if ok then
		p, why = M.parse(raw)
	end
	if not p then
		state.gen += 1
		state.p, state.problem, state.loading, state.sending, state.message = nil, why, false, false, nil
		return
	end
	local cur = state.p
	if cur and cur.at == p.at then
		return
	end
	state.gen += 1
	local gen = state.gen
	state.p, state.problem, state.diffProblem, state.head, state.own = p, nil, nil, nil, false
	state.summary, state.note, state.verdict = input.new(p.summary, true), input.new("", false), p.verdict
	state.at, state.editing, state.sending, state.sent, state.gone, state.message = 0, false, false, false, nil, nil
	state.loading = true
	place(state, p, nil)
	local function diffFailed(problem: string)
		state.loading, state.diffProblem = false, problem
		state.cx:render()
	end
	github.pr(p.repo, p.number, state.login, function(meta, problem)
		if not alive(state, gen) then
			return
		elseif not meta then
			return diffFailed("The pull request could not be read: " .. (if problem then problem.message else "gh gave no answer."))
		end
		state.head = meta.sha
		-- The run's login, or gh's active one when the block has none; unknown, every verdict stays offered.
		github.login(state.login, function(who)
			if not alive(state, gen) then
				return
			end
			if who and meta.author and string.lower(who) == string.lower(meta.author) then
				state.own, state.verdict = true, "comment"
			end
			worktree.reviewDiff(state.cwd, p.repo, p.number, meta.baseRef, p.head, function(out, problem2)
				if not alive(state, gen) then
					return
				elseif not out then
					return diffFailed("The diff could not be read: " .. (problem2 or "git gave no answer."))
				elseif #out > DIFF_BYTES then
					return diffFailed("The diff is too large to show.")
				end
				state.loading = false
				place(state, p, M.parseDiff(out))
				state.cx:render()
			end)
		end)
	end)
end

-- Picks verdict `v` when it may be picked now: not once sending or sent, and only Comment on your own pull request.
local function pick(state: State, v: string?)
	if v and VERDICT_LABEL[v] and not state.sent and not state.sending and (v == "comment" or not state.own) then
		state.verdict = v
	end
end

local function last(state: State): number
	return #state.cards + 1
end

-- The text model the selection edits.
local function modelAt(state: State): input.Model
	if state.at == 0 then
		return state.summary
	elseif state.at > #state.cards then
		return state.note
	end
	return state.cards[state.at].model
end

-- The message of your choices now (M.message).
local function messageOf(state: State): string?
	local p = state.p
	if not p then
		return nil
	end
	local kept: { Comment } = {}
	local dropped: { string } = {}
	for _, card in state.cards do
		if card.keep then
			local c = table.clone(card.c)
			c.body = card.model.text
			table.insert(kept, c)
		else
			table.insert(dropped, card.c.id)
		end
	end
	return M.message(p, kept, dropped, state.verdict, state.summary.text, state.note.text, state.head)
end

-- Send: the message is rendered (hidden `main.send`, only while sending, so a later or early review/send link from this
-- pane finds nothing to send) before the window is told to read it; it answers `sent` or `gone`, taken only while sending.
local function send(state: State)
	if not state.p or state.sent or state.sending or state.loading then
		return
	end
	state.editing, state.sending, state.gone = false, true, nil
	state.message = messageOf(state)
	state.sends += 1
	local n, gen = state.sends, state.gen
	state.cx:render()
	state.cx:open(core.withToken("plotroom://review/send"))
	tern.timer(M.SEND_TIMEOUT_MS, function()
		if state.sending and state.sends == n and alive(state, gen) then
			state.sending = false
			state.gone = "No answer came back, so the message may not have reached the agent. Copy the message and give it to the agent yourself."
			pcall(function()
				state.cx:render()
			end)
		end
	end)
end

local function toggle(state: State, i: number)
	local card = state.cards[i]
	if not card or state.sent or state.sending or state.loading then
		return
	elseif not card.excerpt and state.diffProblem == nil then
		return state.cx:toast("info", "Not on a changed line", "GitHub refuses a comment outside the pull request's diff, so it cannot be kept.")
	end
	card.keep = not card.keep
end

local function edit(state: State, i: number)
	if state.sent or state.sending or not state.p or (i >= 1 and i <= #state.cards and state.loading) then
		return
	end
	state.at, state.editing = i, true
end

-- The split's direction: side by side in regular panes, stacked in compact ones.
local function dirOf(state: State): string
	return if state.cx.cols < REGULAR_COLS then "col" else "row"
end

local function textNode(key: string, s: string, tone: string?): Node
	return ui.node("text", { key = key, spans = { ui.span(s, tone) } })
end

local function editorOf(key: string, m: input.Model, aria: string, lines: number): Node
	local p = input.props(m)
	return ui.node("editor", { key = key, text = p.text, cursor = p.cursor, anchor = p.anchor, maxLines = lines, aria = aria })
end

local function whereOf(c: Comment): string
	return (if c.startLine and c.startLine ~= c.line then "lines " .. c.startLine .. "–" .. c.line else "line " .. c.line) .. (if c.side == "LEFT" then " (old)" else "")
end
-- A finding's first line of feedback, cut short: the navigator's row title.
local function titleOf(card: Card): string
	local line = string.match(card.model.text, "[^\n]+") or card.c.id
	line = string.gsub(line, "^[#>%-%*%s]+", "")
	if utf8.len(line) :: number > 48 then
		line = string.sub(line, 1, (utf8.offset(line, 48) :: number) - 1) .. "…"
	end
	return line
end


-- The navigator: Summary, each finding in file order, Instructions. The split around it sizes it.
local function navNode(state: State): Node
	local items: { Node } = {
		ui.node("item", { key = "n0", label = "Summary" }),
	}
	for i, card in state.cards do
		local c = card.c
		table.insert(items, ui.node("item", {
			key = "n" .. i,
			label = { ui.span((string.match(c.path, "[^/]+$") or c.path) .. ":" .. c.line, "mono") },
			title = KIND_LABEL[c.kind] .. " · " .. c.path .. ":" .. c.line .. " · " .. titleOf(card),
			value = { ui.span(if card.keep then "Kept" else "Dropped", "muted") },
		}))
	end
	table.insert(items, ui.node("item", { key = "n" .. last(state), label = "Instructions", value = if state.note.text ~= "" then { ui.span("Added", "muted") } else nil }))
	return ui.node("list", { key = "nav", selected = "main.body.nav.n" .. state.at }, items)
end

-- Edit (or Done) for the selected item, plus Keep/Drop for a finding: the card's head controls (`end`).
local function actionsNode(state: State, i: number): Node
	local buttons: { Node } = {}
	local card = state.cards[i]
	local what = if i == 0 then "the summary" elseif card then "comment " .. card.c.id else "the instructions"
	if card and card.excerpt or (card and state.diffProblem) then
		table.insert(buttons, button(if card.keep then "Drop" else "Keep", { key = "keep", icon = if card.keep then "x" else "check", keys = { "space" }, aria = (if card.keep then "Drop " else "Keep ") .. what, actions = { click = "keep=" .. i } }))
	end
	if state.editing then
		table.insert(buttons, button("Done", { key = "done", icon = "check", keys = { "esc" }, aria = "Finish editing " .. what, actions = { click = "done" } }))
	else
		table.insert(buttons, button(if i == 0 then "Edit summary" elseif card then "Edit" else "Edit instructions", { key = "edit", icon = "pen", keys = { "e" }, aria = "Edit " .. what, actions = { click = "edit=" .. i } }))
	end
	return ui.node("row", { key = "end", gap = "sm", align = "center" }, buttons)
end

-- The selected item as one card: its head (Summary, Instructions, or a finding's path with its lines as meta) and the
-- controls at the head's end, then the diff, feedback and suggestion.
local function detailNode(state: State): Node
	local i = state.at
	local card = state.cards[i]
	local kids: { Node } = {}
	local props: { [string]: any } = { key = "detail" }
	if i == 0 then
		props.head = { ui.span("Summary") }
		if state.editing then
			table.insert(kids, editorOf("text", state.summary, "Summary", 10))
		elseif state.summary.text ~= "" then
			table.insert(kids, ui.node("md", { key = "text", text = input.clean(state.summary.text, true) }))
		else
			table.insert(kids, textNode("text", "(no summary)", "muted"))
		end
	elseif card then
		local c = card.c
		props.head, props.meta = { ui.span(c.path, "mono") }, { ui.span(whereOf(c)) }
		if not card.excerpt and not state.loading and not state.diffProblem then
			table.insert(kids, textNode("why", "Not on a changed line: GitHub refuses a comment outside the pull request's diff, so it cannot be kept.", "muted"))
		end
		if card.excerpt then
			-- Tern's diff builder makes the node; a keyed col holds it (the builder's node is not ours to change).
			table.insert(kids, ui.node("col", { key = "diff" }, { ui.diff(card.excerpt, c.path) }))
		elseif state.loading then
			-- the diff is still being read: its shape, where it will go
			table.insert(kids, ui.node("skeleton", { key = "diff", shape = "block", min = { h = "8lines" } }))
		end
		if state.editing then
			table.insert(kids, editorOf("body", card.model, "Comment " .. c.id, 12))
		else
			table.insert(kids, ui.node("md", { key = "body", text = input.clean(card.model.text, true) }))
		end
		if c.suggestion then
			-- The lines it replaces and the suggestion as a diff when the diff has them all, else the suggestion as code.
			local shown = if card.suggested
				then ui.node("diff", { key = "diff", text = card.suggested, path = c.path })
				else ui.node("code", { key = "code", text = c.suggestion, lang = string.match(c.path, "%.(%w+)$") })
			table.insert(kids, ui.node("section", { key = "suggestion", head = { ui.span("Suggested change", "muted") }, collapsible = true, collapsed = true }, { shown }))
		end
	else
		props.head = { ui.span("Instructions for the agent (optional)") }
		if state.editing then
			table.insert(kids, editorOf("note", state.note, "Instructions for the agent", 1))
		else
			table.insert(kids, textNode("note", if state.note.text ~= "" then state.note.text else "Press e to add a line, such as “tone down c3”", if state.note.text ~= "" then nil else "muted"))
		end
	end
	if not state.sent and not state.sending and not (card and state.loading) then
		table.insert(kids, actionsNode(state, i))
		props["end"] = "main.body.detail.end"
	end
	return ui.node("card", props, kids)
end

local function view(state: State): BlockView
	local p = state.p
	local main: { Node } = {
		ui.node("text", { key = "run", text = state.run, hidden = true }),
	}
	if state.sending and state.message then
		table.insert(main, ui.node("text", { key = "send", text = tern.json.encode({ run = state.run, text = state.message }), hidden = true }))
	end
	if not p then
		table.insert(main, textNode("problem", state.problem or "Reading the Draft review…", if state.problem then "error" else "muted"))
		return { main = ui.col(main) }
	end
	table.insert(main, ui.node("text", { key = "head", spans = {
		ui.span(p.repo .. "#" .. p.number, "mono"),
		ui.span("  ·  Draft review of ", "muted"),
		ui.span(string.sub(p.head, 1, 7), "mono"),
	} }))
	table.insert(main, ui.node("text", { key = "moves", spans = { ui.span("j/k move  ·  Space keep or drop  ·  e edit", "muted") } }))
	-- The decision row: verdict, count, then Send (or its status).
	local kept = 0
	for _, card in state.cards do
		kept += if card.keep then 1 else 0
	end
	local bar: { Node } = {}
	if state.sent or state.sending then
		table.insert(bar, textNode("verdict", "Verdict: " .. VERDICT_LABEL[state.verdict], "muted"))
	else
		local choices: { Node } = {}
		for i, v in M.VERDICTS do
			if v == "comment" or not state.own then
				table.insert(choices, button(VERDICT_LABEL[v], { key = v, on = state.verdict == v, keys = { tostring(i) }, aria = "Verdict: " .. VERDICT_LABEL[v], actions = { click = "verdict=" .. v } }))
			end
		end
		table.insert(bar, ui.node("buttons", { key = "verdict", size = "md", label = "Verdict" }, choices))
	end
	table.insert(bar, textNode("count", kept .. " kept · " .. (#state.cards - kept) .. " dropped", "muted"))
	if state.sent then
		table.insert(bar, ui.node("badge", { key = "sent", text = "Sent", tone = "muted" }))
	elseif not state.loading then
		-- Busy while the window carries it to the agent: a spinner in the icon's place, and it sends nothing more.
		table.insert(bar, button(if state.sending then "Sending…" else "Send to agent", { key = "send", size = "md", icon = "arrow-right", busy = state.sending == true, keys = { "cmd", "enter" }, aria = "Send your choices to the agent", actions = { click = "send" } }))
	end
	table.insert(main, ui.node("row", { key = "bar", gap = "sm", wrap = true, align = "center" }, bar))
	if state.own and not state.sent and not state.sending then
		table.insert(main, textNode("own", "Your own pull request: GitHub refuses Approve and Request changes on it, so the verdict is Comment.", "muted"))
	end
	if state.sent then
		table.insert(main, textNode("sent", "Sent to the agent. It posts the review; a revised proposal opens here again.", "muted"))
	end
	if state.gone then
		table.insert(main, ui.node("row", { key = "gone", gap = "sm", wrap = true, align = "center" }, {
			textNode("why", state.gone, "error"),
			button("Copy", { key = "copy", size = "md", icon = "copy", keys = { "c" }, aria = "Copy the message for the agent", actions = { click = "copy" } }),
		}))
	end
	if state.head and M.moved(p, state.head) then
		table.insert(main, ui.node("text", { key = "moved", spans = {
			ui.span("The pull request's head moved to ", "muted"),
			ui.span(string.sub(state.head, 1, 7), "mono"),
			ui.span(" since this review: Send asks the agent to check the new commits first.", "muted"),
		} }))
	end
	if state.diffProblem then
		table.insert(main, textNode("diff-problem", state.diffProblem .. " Every comment is listed without its lines.", "error"))
	end
	-- The navigator and the selected item in a split you resize. It grows into the pane's height, so a long item
	-- scrolls in its own pane.
	local dir = dirOf(state)
	table.insert(main, ui.node("split", { key = "body", dir = dir, sizes = state.sizes[dir] or SIZES[dir], min = MINS[dir], grow = 1 }, { navNode(state), detailNode(state) }))
	return { main = ui.col(main) }
end

local function copy(state: State)
	local m = state.message or messageOf(state)
	if m then
		state.cx:copy(m)
		state.cx:toast("success", "Copied the message for the agent")
	end
end

function M.define()
	tern.block.define("review", {
		font = "sans",
		init = function(cx: BlockCx, args: { string }, saved: any): State
			local a: any = args
			if (not a or not a[1]) and isTable(saved) and saved.version == 1 then
				a = { saved.run, saved.cwd, saved.login }
			end
			local run, cwd, login = if a then a[1] else nil, if a then a[2] else nil, if a then a[3] else nil
			local state: State = {
				cx = cx,
				run = if M.validRun(run) then run else "",
				cwd = if type(cwd) == "string" and string.sub(cwd, 1, 1) == "/" and #cwd <= 4096 and not string.find(cwd, "%c") then cwd else "",
				login = if type(login) == "string" and string.match(login, "^[%w%-]+$") then login else nil,
				gen = 0,
				loading = false,
				cards = {},
				summary = input.new("", true),
				note = input.new("", false),
				verdict = "comment",
				own = false,
				at = 0,
				editing = false,
				sending = false,
				sends = 0,
				sent = false,
				sizes = {},
			}
			if isTable(saved) and saved.version == 1 and isTable(saved.sizes) then
				for _, dir in { "row", "col" } do
					local shares = sharesOf(saved.sizes[dir])
					if shares then
						state.sizes[dir] = shares
					end
				end
			end
			if state.run == "" or state.cwd == "" then
				state.problem = "This block was opened without a run and its folder."
			else
				load(state)
				-- A block restored after a restart keeps that it was sent (edits are not saved).
				-- ponytail: edits are lost on a restart; save the cards' text if that ever hurts.
				local p = state.p
				if p and isTable(saved) and saved.sent == p.at then
					state.sent = true
				end
			end
			return state
		end,

		title = function(state: State): string?
			local p = state.p
			return if p then "Draft review · " .. p.repo .. "#" .. p.number else "Draft review"
		end,

		view = function(state: State, _cx: BlockCx): BlockView
			return view(state)
		end,

		key = function(state: State, key: Key, _cx: BlockCx): boolean?
			local name = key.name
			if state.editing then
				if name == "escape" then
					state.editing = false
					return true
				elseif name == "enter" and (key.meta or key.ctrl) then
					send(state)
					return true
				end
				local m = modelAt(state)
				if name == "enter" and not m.multi then
					state.editing = false
					return true
				end
				return input.key(m, key, function(s: string)
					state.cx:copy(s)
				end)
			end
			local ch = key.text or name
			if name == "down" or ch == "j" then
				state.at = math.min(state.at + 1, last(state))
			elseif name == "up" or ch == "k" then
				state.at = math.max(state.at - 1, 0)
			elseif name == "space" then
				toggle(state, state.at)
			elseif ch == "e" or (name == "enter" and not key.meta and not key.ctrl) then
				edit(state, state.at)
			elseif name == "enter" then
				send(state)
			elseif ch == "1" or ch == "2" or ch == "3" then
				pick(state, M.VERDICTS[tonumber(ch) :: number])
			elseif ch == "c" and state.gone then
				copy(state)
			else
				return false
			end
			return true
		end,

		event = function(state: State, ev: UiEvent, _cx: BlockCx)
			if ev.ev == "select" then
				-- A click on the navigator's native list: ev.item is the row's full node id.
				local i = if ev.id == "main.body.nav" then tonumber(string.match(tostring(ev.item), "^main%.body%.nav%.n(%d+)$")) else nil
				if i and i <= last(state) then
					state.at, state.editing = i, false
				end
				return
			elseif ev.ev == "change" and ev.id == "main.body" then
				-- You dragged the split's handle: its shares, kept for the block in its direction (saved, so a restart keeps them).
				local dir = dirOf(state)
				state.sizes[dir] = sharesOf(ev.value) or state.sizes[dir]
				return
			elseif ev.ev ~= "action" then
				return
			end
			local act, value = ev.act, ev.value
			if act == "reload" then
				load(state)
			elseif act == "sent" and state.sending then
				state.sending, state.sent, state.gone = false, true, nil
			elseif act == "gone" and state.sending then
				state.sending = false
				state.gone = (if type(value) == "string" then string.sub(value, 1, 300) else "The agent could not take the message.") .. " Copy the message and give it to the agent yourself."
			elseif act == "send" then
				send(state)
			elseif act == "copy" then
				copy(state)
			elseif act == "done" then
				state.editing = false
			elseif act == "verdict" then
				pick(state, value)
			elseif act == "select" and tonumber(value) then
				local i = tonumber(value) :: number
				if i >= 0 and i <= last(state) then
					state.at, state.editing = i, false
				end
			elseif act == "keep" and tonumber(value) then
				state.at = tonumber(value) :: number
				toggle(state, state.at)
			elseif act == "edit" and tonumber(value) then
				local i = tonumber(value) :: number
				if i >= 0 and i <= last(state) then
					edit(state, i)
				end
			end
		end,

		save = function(state: State): any
			local p = state.p
			return { version = 1, run = state.run, cwd = state.cwd, login = state.login, sent = if p and state.sent then p.at else nil, sizes = state.sizes }
		end,
	})
end

return M
