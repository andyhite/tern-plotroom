--!strict
-- Model of the independent "Worktrees" sidebar view: every saved checkout's worktrees, beyond the current view or query.
-- Pure state plus calls into an injected backend `api` (worktree.luau); the host renders rows and supplies `live`/`check`.

local M = {}

M.CAP_ROWS = 200
M.CAP_CHECKOUTS = 50
M.CAP_CHECKS = 20

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
}
export type Board = { rows: { Row }, loading: boolean, round: number, problems: { string }, loaded: boolean }
export type Check = (row: Row, done: (state: "open" | "closed" | "merged" | "unknown") -> ()) -> ()

function M.new(): Board
	return { rows = {}, loading = false, round = 0, problems = {}, loaded = false }
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
							dirty = if prev then prev.dirty else nil,
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

function M.inspect(board: Board, api: Api, id: string, live: () -> boolean, done: () -> ())
	local row = find(board, id)
	if not row then
		return done()
	end
	row.checking = true
	api.inventoryDirty(row.checkout, row.repo, row.path, row.branch, function(dirty)
		if not live() then
			return
		end
		row.checking = nil
		if find(board, id) == row then
			row.dirty = dirty
		end
		done()
	end)
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

function M.label(row: Row): string
	return row.branch or "(detached)"
end

function M.detail(row: Row): string
	return row.path
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
