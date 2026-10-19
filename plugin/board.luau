--!strict
-- Model of the independent "Worktrees" sidebar view: every saved checkout's worktrees, beyond the current view or query.
-- Pure state plus calls into an injected backend `api` (worktree.luau); the host renders rows and supplies `live`/`check`.

local M = {}

M.CAP_ROWS = 200
M.CAP_CHECKOUTS = 50
M.CAP_CHECKS = 20
M.CAP_SCANS = 40 -- worktrees whose changes one automatic scan reads
M.SCAN_SECONDS = 30 -- an automatic scan is due again this long after the last one started
M.EXCERPT = 280

export type Removal = { branch: string }
export type Entry = {
	path: string,
	root: string,
	branch: string?,
	head: string?,
	main: boolean,
	detached: boolean,
	locked: boolean,
	prunable: boolean,
	missing: boolean,
	key: string?,
	number: number?,
	ref: string?,
	inferred: boolean?,
}
export type Api = {
	inventory: (checkout: string, repo: string, done: (entries: { Entry }?, problem: string?) -> ()) -> (),
	-- Read-only status of a path the last `inventory` listed (the host refuses any other path), for the automatic scan.
	dirty: (path: string, done: (dirty: boolean?, problem: string?) -> ()) -> (),
	inventoryDirty: (
		checkout: string,
		repo: string,
		path: string,
		branch: string?,
		done: (dirty: boolean?, problem: string?) -> ()
	) -> (),
	removeEntry: (
		checkout: string,
		repo: string,
		path: string,
		branch: string?,
		done: (removal: Removal?, problem: string?, dirty: boolean?) -> ()
	) -> (),
}

-- What a linked pull request or issue looks like once read. `tracker` names where it lives ("github o/r", "jira PROJ"),
-- `related` is a counterpart the tracker itself links (an issue key on a PR, a PR number on an issue) and the adapter
-- has checked against the repository or project; it is never guessed from branch text.
export type Info = {
	ref: string,
	title: string,
	state: string,
	person: string?, -- author (PR) or assignee (issue)
	excerpt: string?,
	url: string?,
	tracker: string,
	related: { key: string?, number: number? }?,
}
export type Links = {
	pr: (row: Row, number: number, done: (info: Info?, problem: string?) -> ()) -> (),
	issue: (row: Row, key: string, done: (info: Info?, problem: string?) -> ()) -> (),
	-- The number of the pull request whose head branch is `branch` (nil: none, or the lookup failed).
	head: (row: Row, branch: string, done: (number: number?) -> ()) -> (),
}
-- One half of the preview: loading, ready (`info`), failed (`problem`) or empty (read fine, nothing there).
export type Section = { state: "loading" | "ready" | "error" | "empty", info: Info?, problem: string?, ref: string }
export type Details = { pr: Section?, issue: Section?, sig: string? }

export type Row = {
	id: string,
	repo: string,
	checkout: string,
	path: string,
	branch: string?,
	head: string?,
	main: boolean,
	key: string?,
	number: number?,
	inferred: boolean?,
	locked: boolean,
	missing: boolean,
	dirty: boolean?,
	checking: boolean?,
	candidate: "closed" | "merged" | nil,
	candidateChecked: boolean?,
	refused: string?,
	scannedAt: number?, -- when the last automatic read of it finished; with `dirty` nil that read failed
}
export type Board = {
	rows: { Row },
	loading: boolean,
	round: number,
	problems: { string },
	loaded: boolean,
	selected: string?, -- the previewed row; nil = none (the initial state, and after `close`)
	details: { [string]: Details },
	links: Links?, -- the adapter of the last `select`, to read the preview again after a reload
	detailRound: number,
	scanning: boolean,
	scanRound: number,
	scanAt: number?,
}
export type Check = (row: Row, done: (state: "open" | "closed" | "merged" | "unknown") -> ()) -> ()

function M.new(): Board
	return {
		rows = {},
		loading = false,
		round = 0,
		problems = {},
		loaded = false,
		selected = nil,
		details = {},
		detailRound = 0,
		scanning = false,
		scanRound = 0,
		scanAt = nil,
	}
end

local function find(board: Board, id: string): Row?
	for _, r in board.rows do
		if r.id == id then
			return r
		end
	end
	return nil
end

local function order(a: Row, b: Row): boolean
	if a.repo ~= b.repo then
		return a.repo < b.repo
	end
	local x, y = a.branch or a.path, b.branch or b.path
	if x ~= y then
		return x < y
	end
	return a.path < b.path
end

-- Loads one checkout at a time, repos in sorted order; a checkout path given for two repos is read once (first repo).
-- ponytail: a full reload re-reads every checkout; per-checkout refresh if that ever hurts.
function M.load(board: Board, api: Api, checkouts: { [string]: string }, live: () -> boolean, done: () -> ())
	board.round += 1
	local round = board.round
	board.loading = true
	board.scanning = false
	board.scanRound += 1
	local function alive(): boolean
		return board.round == round and live()
	end

	local repos: { string } = {}
	for repo, path in checkouts do
		if path ~= "" then
			table.insert(repos, repo)
		end
	end
	table.sort(repos)
	local seen: { [string]: boolean } = {}
	local queue: { { repo: string, path: string } } = {}
	local problems: { string } = {}
	for _, repo in repos do
		local path = checkouts[repo]
		if not seen[path] then
			seen[path] = true
			if #queue < M.CAP_CHECKOUTS then
				table.insert(queue, { repo = repo, path = path })
			else
				table.insert(problems, repo .. ": skipped, more than " .. M.CAP_CHECKOUTS .. " checkouts")
			end
		end
	end

	local old: { [string]: Row } = {}
	for _, r in board.rows do
		old[r.id] = r
	end
	local rows: { Row } = {}
	local ids: { [string]: boolean } = {}

	local function finish()
		table.sort(rows, order)
		if #rows > M.CAP_ROWS then
			for i = #rows, M.CAP_ROWS + 1, -1 do
				rows[i] = nil
			end
			table.insert(problems, "Showing the first " .. M.CAP_ROWS .. " worktrees")
		end
		board.rows = rows
		board.problems = problems
		board.loading = false
		board.loaded = true
		board.scanAt = nil
		-- a read in flight belongs to a replaced row object and would never answer: drop it, then read the preview again
		for rid, d in board.details do
			if not find(board, rid) or (d.pr and d.pr.state == "loading") or (d.issue and d.issue.state == "loading") then
				board.details[rid] = nil
			end
		end
		if board.selected and board.links then
			return M.select(board, board.links, board.selected, live, done)
		end
		done()
	end

	local function step(i: number)
		if not alive() then
			return
		end
		local q = queue[i]
		if not q then
			return finish()
		end
		api.inventory(q.path, q.repo, function(entries, problem)
			if not alive() then
				return
			end
			if not entries then
				table.insert(problems, q.repo .. ": " .. (problem or "could not list worktrees"))
			else
				for _, e in entries do
					local id = q.repo .. "\0" .. e.path
					if not ids[id] then
						ids[id] = true
						local prev = old[id]
						table.insert(rows, {
							id = id,
							repo = q.repo,
							checkout = q.path,
							path = e.path,
							branch = e.branch,
							head = e.head,
							main = e.main,
							key = e.key,
							number = e.number,
							inferred = e.inferred,
							locked = e.locked,
							missing = e.missing or e.prunable,
							dirty = if prev and not (e.missing or e.prunable) then prev.dirty else nil,
							scannedAt = if prev then prev.scannedAt else nil,
							candidate = if prev then prev.candidate else nil,
							candidateChecked = if prev then prev.candidateChecked else nil,
						})
					end
				end
			end
			step(i + 1)
		end)
	end
	step(1)
end

function M.rows(board: Board, opts: { showMain: boolean? }): { Row }
	local out: { Row } = {}
	for _, r in board.rows do
		if opts.showMain == true or not r.main then
			table.insert(out, r)
		end
	end
	table.sort(out, order)
	return out
end

-- Asks `check` about the rows a merged/closed pull request or issue could make cleanup candidates. Only a cap's worth per
-- call, unchecked rows first; nothing is removed here.
function M.findCandidates(board: Board, check: Check, live: () -> boolean, done: (checked: number, skipped: number) -> ())
	local todo: { Row } = {}
	for _, r in board.rows do
		if not r.main and not r.missing and (r.key ~= nil or r.number ~= nil) and r.inferred ~= true then
			table.insert(todo, r)
		end
	end
	table.sort(todo, function(a, b)
		local x, y = a.candidateChecked == true, b.candidateChecked == true
		if x ~= y then
			return y
		end
		return order(a, b)
	end)
	local skipped = math.max(0, #todo - M.CAP_CHECKS)
	local n = math.min(#todo, M.CAP_CHECKS)
	local answered = 0
	local function step(i: number)
		if not live() then
			return
		end
		if i > n then
			return done(answered, skipped)
		end
		local row = todo[i]
		check(row, function(state)
			if not live() then
				return
			end
			if state ~= "unknown" then
				answered += 1
				row.candidateChecked = true
				row.candidate = if state == "closed" or state == "merged" then state else nil
			end
			step(i + 1)
		end)
	end
	step(1)
end

function M.remove(board: Board, api: Api, id: string, live: () -> boolean, done: (ok: boolean, message: string) -> ())
	local row = find(board, id)
	if not row then
		return done(false, "That worktree is no longer listed.")
	end
	local function refuse(why: string)
		row.refused = why
		done(false, why)
	end
	if row.main then
		return refuse("The main worktree is never removed.")
	elseif row.locked then
		return refuse("The worktree is locked.")
	elseif row.missing then
		return refuse("The worktree folder is missing; prune it with git.")
	end
	row.refused = nil
	api.inventoryDirty(row.checkout, row.repo, row.path, row.branch, function(dirty, problem)
		if not live() then
			return
		end
		if dirty ~= false then
			row.dirty = dirty
			return refuse(if dirty then "The worktree has uncommitted changes." else problem or "Could not tell whether the worktree is clean.")
		end
		row.dirty = false
		api.removeEntry(row.checkout, row.repo, row.path, row.branch, function(removal, why, nowDirty)
			if not live() then
				return
			end
			if not removal then
				if nowDirty then
					row.dirty = true
				end
				return refuse(why or "Could not remove the worktree.")
			end
			local at = table.find(board.rows, row)
			if at then
				table.remove(board.rows, at)
			end
			done(true, removal.branch)
		end)
	end)
end

-- The visible name: the folder's own name, which is what the user called the worktree. Branch, repository and path are
-- secondary facts (`M.facts`).
function M.label(row: Row): string
	return string.match(row.path, "([^/\\]+)[/\\]*$") or row.branch or "(detached)"
end

function M.detail(row: Row): string
	return row.branch or "(detached)"
end

local function short(s: string, n: number): string
	return if #s > n then string.sub(s, 1, n) else s
end

-- Git facts, after the linked PR/issue context: [label, value] pairs the preview lists with native key/value rows.
function M.facts(row: Row): { { string } }
	local out: { { string } } = {
		{ "Branch", row.branch or "(detached)" },
		{ "Repository", row.repo },
		{ "Path", row.path },
	}
	if row.head then
		table.insert(out, { "Head", short(row.head, 8) })
	end
	local status = if row.missing then "Folder missing"
		elseif row.dirty == true then "Uncommitted changes"
		elseif row.dirty == false then "Clean"
		elseif row.scannedAt then "Unknown: could not read changes"
		else "Reading…"
	table.insert(out, { "Status", status })
	return out
end

-- A tracker description as a short plain excerpt: whitespace collapsed, cut on a character boundary.
local function excerpt(s: string?): string?
	if not s then
		return nil
	end
	local t = string.gsub(string.gsub(s, "%s+", " "), "^ ", "")
	t = string.gsub(t, " $", "")
	if t == "" then
		return nil
	end
	if #t <= M.EXCERPT then
		return t
	end
	local cut = utf8.offset(t, 0, M.EXCERPT + 1) or (M.EXCERPT + 1)
	return string.sub(t, 1, cut - 1) .. "…"
end

-- The preview of a row: its title, the linked PR and issue sections (each only when known) and the git facts.
function M.preview(board: Board, row: Row): { title: string, pr: Section?, issue: Section?, facts: { { string } } }
	local d = board.details[row.id]
	return { title = M.label(row), pr = if d then d.pr else nil, issue = if d then d.issue else nil, facts = M.facts(row) }
end

-- Previews `id` (nil closes it) and reads its linked pull request and issue through `links`, once per row until a read
-- fails. A counterpart the first read's tracker links (and the adapter verified) fills in the missing one, and so does
-- GitHub's pull request whose head is the row's branch (`links.head`: a head-ref match is GitHub's answer, not a
-- guess); branch text itself never does. `done` runs after every visible change; a superseded, closed or removed
-- preview is ignored.
function M.select(board: Board, links: Links, id: string?, live: () -> boolean, done: () -> (), refresh: boolean?)
	local row = if id then find(board, id) else nil
	if not row then
		board.detailRound += 1
		board.selected = nil
		return done()
	end
	local rid = row.id
	-- a changed link, branch or head makes what was read stale
	local sig = table.concat({ row.key or "", tostring(row.number or ""), row.branch or "", row.head or "" }, "\0")
	board.links = links
	local d = board.details[rid]
	if d and d.sig == sig and refresh ~= true then
		local loading, failed = false, false
		for _, s in { d.pr, d.issue } do
			if s and s.state == "loading" then
				loading = true
			elseif s and s.state == "error" then
				failed = true
			end
		end
		-- reads of this very preview still running keep their round; a finished clean one needs nothing
		if (loading and board.selected == rid) or not (loading or failed) then
			board.selected = rid
			return done()
		end
	end
	board.detailRound += 1
	local round = board.detailRound
	board.selected = rid
	d = { sig = sig }
	board.details[rid] = d
	local function alive(): boolean
		return board.detailRound == round and board.selected == rid and find(board, rid) == row and live()
	end
	local function fetch(kind: "pr" | "issue", ref: string, run: (finish: (Info?, string?) -> ()) -> (), after: () -> ())
		local section: Section = { state = "loading", ref = ref }
		(d :: Details)[kind] = section
		run(function(info, problem)
			if not alive() then
				return
			end
			if info then
				info.excerpt = excerpt(info.excerpt)
				section.state, section.info = "ready", info
			elseif problem then
				section.state, section.problem = "error", problem
			else
				section.state = "empty"
			end
			done()
			after()
		end)
	end
	local function fetchPr(n: number, after: () -> ())
		fetch("pr", "#" .. n, function(f)
			links.pr(row :: Row, n, f)
		end, after)
	end
	local function fetchIssue(key: string, after: () -> ())
		fetch("issue", key, function(f)
			links.issue(row :: Row, key, f)
		end, after)
	end
	local function enrich()
		local dd = d :: Details
		if dd.pr and dd.issue then
			return
		end
		local from = (dd.pr or dd.issue) :: Section?
		local rel = if from and from.info then from.info.related else nil
		if rel and not dd.issue and rel.key then
			return fetchIssue(rel.key, function() end)
		elseif rel and not dd.pr and rel.number then
			return fetchPr(rel.number, function() end)
		end
		-- An issue and no PR its tracker links: GitHub may still know one whose head is the worktree's branch.
		local branch = row.branch
		if dd.issue and not dd.pr and branch then
			links.head(row :: Row, branch, function(n)
				if n and alive() and not dd.pr then
					fetchPr(n, function() end)
				end
			end)
		end
	end
	local function second()
		if row.key then
			fetchIssue(row.key, enrich)
		else
			enrich()
		end
	end
	if row.number then
		fetchPr(row.number, second)
	elseif row.key then
		fetchIssue(row.key, enrich)
	end
	done()
end

-- Closes the preview and ignores whatever its reads still bring.
function M.close(board: Board)
	board.detailRound += 1
	board.selected = nil
end

-- Stops an automatic scan in flight; its callbacks are ignored.
function M.stop(board: Board)
	board.scanRound += 1
	board.scanning = false
	board.scanAt = nil
end

-- Reads the uncommitted changes of the listed worktrees on its own: one at a time, at most CAP_SCANS (unread first, then
-- by list order), each folder once. Returns whether a scan started: not while the board loads or scans, and not before
-- SCAN_SECONDS since the last unless `force`. Cheap to call from a timer or a render; it does nothing when not due.
-- A read that fails leaves `dirty` nil with `dirtyProblem`; it is never shown as clean. `live` false (the board is not on
-- screen) stops the scan and nothing schedules another. `now` is seconds on any steady clock.
function M.scan(board: Board, api: Api, now: number, live: () -> boolean, done: () -> (), force: boolean?): boolean
	if board.loading or board.scanning or not live() then
		return false
	end
	if not force and board.scanAt and now - board.scanAt < M.SCAN_SECONDS then
		return false
	end
	local groups: { { Row } } = {}
	local byKey: { [string]: { Row } } = {}
	for _, r in board.rows do
		if not r.missing then
			local k = r.path
			if byKey[k] then
				table.insert(byKey[k], r)
			else
				byKey[k] = { r }
				table.insert(groups, byKey[k])
			end
		end
	end
	if #groups == 0 then
		board.scanAt = now
		return false
	end
	table.sort(groups, function(a, b)
		local function sel(g: { Row }): boolean
			for _, r in g do
				if r.id == board.selected then
					return true
				end
			end
			return false
		end
		local s, t = sel(a), sel(b)
		if s ~= t then
			return s
		end
		-- never read first, then the longest ago: successive scans cover every row, failing ones included
		local x, y = a[1].scannedAt or -1, b[1].scannedAt or -1
		if x ~= y then
			return x < y
		end
		return order(a[1], b[1])
	end)
	board.scanning = true
	board.scanAt = now
	board.scanRound += 1
	local round, loadRound = board.scanRound, board.round
	local function alive(): boolean
		return board.scanRound == round and board.round == loadRound and live()
	end
	-- a scan that goes offscreen stops without counting as done: the next one is due at once
	local function abandon()
		if board.scanRound == round then
			board.scanning = false
			board.scanAt = nil
		end
	end
	local n = math.min(#groups, M.CAP_SCANS)
	local function step(i: number)
		if not alive() then
			return abandon()
		end
		if i > n then
			board.scanning = false
			return done()
		end
		local g = groups[i]
		local r = g[1]
		api.dirty(r.path, function(dirty)
			if not alive() then
				return abandon()
			end
			for _, x in g do
				if find(board, x.id) == x then
					x.dirty = dirty
					x.scannedAt = now
				end
			end
			done()
			step(i + 1)
		end)
	end
	step(1)
	return true
end

function M.badges(row: Row, openTab: boolean): { { text: string, tone: string, title: string? } }
	local out: { { text: string, tone: string, title: string? } } = {}
	if row.main then
		table.insert(out, { text = "Main", tone = "accent", title = "The repository's main worktree" })
	end
	if openTab then
		table.insert(out, { text = "In tab", tone = "accent", title = "Open in a tab" })
	end
	if row.dirty == true then
		table.insert(out, { text = "Changes", tone = "warning", title = "Uncommitted changes" })
	elseif row.dirty == false then
		table.insert(out, { text = "Clean", tone = "success", title = nil })
	elseif row.scannedAt and not row.missing then
		table.insert(out, { text = "Unknown", tone = "muted", title = "Changes could not be read" })
	end
	if row.candidate then
		local c: string = row.candidate
		table.insert(out, {
			text = if c == "merged" then "Merged" else "Closed",
			tone = "warning",
			title = "Cleanup candidate: its pull request or issue is " .. c,
		})
	end
	if row.locked then
		table.insert(out, { text = "Locked", tone = "muted", title = "Locked with git worktree lock" })
	end
	if row.missing then
		table.insert(out, { text = "Missing", tone = "error", title = "The folder is gone" })
	end
	if not row.main and not row.key and not row.number then
		table.insert(out, { text = "Unnoted", tone = "muted", title = "Not linked to an item" })
	end
	return out
end

return M
