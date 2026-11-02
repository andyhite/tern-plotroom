--!strict
-- Smoke driver for a real Tern. window.luau registers `plugin.plotroom.smoke` (only with PLOTROOM_SELFTEST=1) to
-- call `run`: it reads $PLOTROOM_SMOKE_DIR/request.json, runs worktree.open, worktree.openIssue,
-- worktree.remoteBranches or worktree.scan through the real process runner (real git; the gh on PATH is a canned
-- executable the gate wrote) and writes result.json. scripts/check.py writes the request, creates the repositories and
-- judges the outcome; nothing here decides pass or fail.

local github = require("../github")
local process = require("../process")
local tracker = require("../tracker")
local worktree = require("../worktree")

local M = {}

local function write(dir: string, name: string, body: { [string]: any })
	tern.fs.write(dir .. "/" .. name, tern.json.encode(body))
end

-- The plan an issue request spells out, as host.luau hands it to worktree.openIssue; nil when it is malformed.
local function planOf(p: any): worktree.IssuePlan?
	if type(p) ~= "table" or type(p.dir) ~= "string" or type(p.branch) ~= "string" or type(p.fresh) ~= "boolean" then
		return nil
	elseif (p.pr ~= nil and type(p.pr) ~= "number") or (p.base ~= nil and type(p.base) ~= "string") then
		return nil
	end
	return { dir = p.dir, branch = p.branch, pr = p.pr, fresh = p.fresh, base = p.base }
end

-- A list of strings, copied (a decoded JSON array is protected); nil when it is no list of strings.
local function stringsOf(list: any): { string }?
	if type(list) ~= "table" then
		return nil
	end
	local out: { string } = {}
	for _, s in list do
		if type(s) ~= "string" then
			return nil
		end
		table.insert(out, s)
	end
	return out
end

-- The wants a scan request spells out, as engine.worktreeWant builds them (item key -> how its worktree is known);
-- nil when they are malformed.
local function wantsOf(p: any): { [string]: worktree.Want }?
	if type(p) ~= "table" then
		return nil
	end
	local out: { [string]: worktree.Want } = {}
	for key, w in p do
		local branches = if type(w) == "table" then stringsOf(w.branches) else nil
		local dirs = if type(w) == "table" then stringsOf(w.dirs) else nil
		if type(key) ~= "string" or not branches or not dirs or (w.ref ~= nil and type(w.ref) ~= "string") then
			return nil
		end
		out[key] = { branches = branches, dirs = dirs, ref = w.ref }
	end
	return out
end

-- worktree.open's `naming`, as host.luau builds it: the folder format filled in for pull request `number` of `repo`.
local function naming(repo: string, number: number, format: string): (github.PrMeta) -> (string?, string?)
	local owner, name = string.match(string.lower(repo), "^([^/]+)/([^/]+)$")
	return function(meta: github.PrMeta): (string?, string?)
		return tracker.render(format, { key = tostring(number), slug = tracker.slug(meta.title), owner = owner or "", repo = name or "" }, true)
	end
end

-- Request, each with `checkout` (a local checkout; for a scan any folder of it) and, but for a scan, `repo` ("owner/name"):
--   { op = "open", number = N, prDir? = folder-name format (default: tracker.PR_DIR_DEFAULT) }
--   { op = "issue", key = "7" | "ABC-7", plan = { dir, branch, fresh, pr?, base? } }   (worktree.IssuePlan)
--   { op = "branches" }
--   { op = "scan", wants = { [item key] = { branches = { names }, dirs = { folder names }, ref? } } }   (worktree.Want)
-- Result: { ok, hasCx, result?, describe? (open, issue), update? (open), problem? }; the sentinel problems of
-- openIssue ("undecided", "need-base") arrive as `problem`; `result` of "branches" is { branches = { names } }. A scan
-- (the host half's read, which has no window context to report) answers { ok, scan?, problem? }.
-- The local-git reads and writes of the worktree inventory and draft PRs likewise answer { ok, data?, problem? }
-- (`data` is what the call returned: entries, a Draft, or { pushed = true } / { branch = <Removal's sentence> }):
--   { op = "inventory" }   { op = "removeEntry", path, branch? }
--   { op = "draft", path, base }   { op = "push", draft = <a Draft as "draft" answered it> }
-- A second `done` writes duplicate.json.
function M.run(cx: WindowCx)
	local dir = tern.getenv("PLOTROOM_SMOKE_DIR")
	if not dir or dir == "" then
		cx:toast("error", "Plotroom smoke: PLOTROOM_SMOKE_DIR is not set")
		return
	end
	local read, decoded = pcall(function(): any
		return tern.json.decode(tern.fs.read(dir .. "/request.json"))
	end)
	local request: any = if read then decoded else nil
	local plan = if type(request) == "table" then planOf(request.plan) else nil
	local wants = if type(request) == "table" then wantsOf(request.wants) else nil
	local valid = type(request) == "table"
		and type(request.checkout) == "string"
		and (
			(request.op == "open" and type(request.repo) == "string" and type(request.number) == "number" and (request.prDir == nil or type(request.prDir) == "string"))
			or (request.op == "issue" and type(request.repo) == "string" and type(request.key) == "string" and plan ~= nil)
			or (request.op == "branches" and type(request.repo) == "string")
			or (request.op == "scan" and wants ~= nil)
			or (request.op == "inventory" and type(request.repo) == "string")
			or (request.op == "removeEntry" and type(request.repo) == "string" and type(request.path) == "string" and (request.branch == nil or type(request.branch) == "string"))
			or (request.op == "draft" and type(request.repo) == "string" and type(request.path) == "string" and type(request.base) == "string")
			or (request.op == "push" and type(request.draft) == "table")
		)
	if not valid then
		write(dir, "result.json", { ok = false, hasCx = true, problem = "bad request: " .. tostring(decoded) })
		cx:toast("error", "Plotroom smoke: bad request")
		return
	end
	local op: string = request.op
	local answers = 0
	-- True for the first answer; a second one is written apart, so the gate sees a runtime that reports twice.
	local function once(): boolean
		answers += 1
		if answers > 1 then
			write(dir, "duplicate.json", { ok = false, problem = "done ran " .. answers .. " times" })
		end
		return answers == 1
	end
	-- worktree.open's Result, worktree.openIssue's IssueResult (each described by its own wording) or the branch list.
	local function finish(result: any, problem: string?, cx2: WindowCx?)
		if not once() then
			return
		end
		local body: { [string]: any } = { ok = result ~= nil, hasCx = cx2 ~= nil }
		if result then
			body.result = result
			if op == "issue" then
				body.describe = worktree.describeIssue(result)
			elseif op == "open" then
				body.describe = worktree.describe(result)
				body.update = tern.json.array(worktree.update(result))
			end
		else
			body.problem = problem or "no result and no problem"
		end
		write(dir, "result.json", body)
	end
	-- worktree.scan's Scan: the host half's read of a checkout, which has no window context to report.
	local function scanned(scan: worktree.Scan?, problem: string?)
		if once() then
			write(dir, "result.json", { ok = scan ~= nil, scan = scan, problem = if scan then nil else (problem or "no scan and no problem") })
		end
	end
	-- The inventory and draft calls: no window context, one `data` answer.
	local function answered(data: any, problem: string?)
		if once() then
			write(dir, "result.json", { ok = problem == nil, data = data, problem = problem })
		end
	end
	-- Run from a process callback, as the host runs its requests (from an event): a headless Tern keeps no clock between commands, so a timer
	-- armed while this command runs (the immediate refusals of worktree.open and openIssue) would wait for the next event.
	process.run({ "git", "--version" }, { timeout_ms = 10 * 1000 }, function()
		local started, why = pcall(function()
			if op == "scan" then
				worktree.scan(request.checkout, wants :: { [string]: worktree.Want }, scanned)
			elseif op == "inventory" then
				worktree.inventory(request.checkout, request.repo, function(entries, problem)
					answered(if entries then tern.json.array(entries) else nil, problem)
				end)
			elseif op == "removeEntry" then
				worktree.removeEntry(request.checkout, request.repo, request.path, request.branch, function(removal, problem, dirty)
					answered(if removal then { branch = removal.branch } else { dirty = dirty }, problem)
				end)
			elseif op == "draft" then
				worktree.draftPreview(request.path, request.repo, request.base, function(draft, problem)
					answered(draft, problem)
				end)
			elseif op == "push" then
				worktree.pushBranch(request.draft :: worktree.Draft, function(problem)
					answered({ pushed = problem == nil }, problem)
				end)
			elseif op == "issue" then
				worktree.openIssue(request.checkout, request.repo, request.key, plan :: worktree.IssuePlan, nil, finish)
			elseif op == "branches" then
				worktree.remoteBranches(request.checkout, request.repo, function(names: { string }?, problem: string?, cx2: WindowCx?)
					finish(if names then { branches = tern.json.array(names) } else nil, problem, cx2)
				end)
			else
				local format: string = request.prDir or tracker.PR_DIR_DEFAULT
				worktree.open(request.checkout, request.repo, request.number, naming(request.repo, request.number, format), nil, finish)
			end
		end)
		if not started then
			local what = if op == "issue" then "openIssue" elseif op == "branches" then "remoteBranches" elseif op == "open" then "open" else op
			write(dir, "result.json", { ok = false, hasCx = true, problem = "worktree." .. what .. " raised: " .. tostring(why) })
		end
	end)
end

return M
