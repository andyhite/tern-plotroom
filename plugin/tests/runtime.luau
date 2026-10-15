--!strict
-- Smoke driver for a real Tern. window.luau registers `plugin.plotroom.smoke` (only with PLOTROOM_SELFTEST=1) to
-- call `run`: it reads $PLOTROOM_SMOKE_DIR/request.json, runs worktree.open, worktree.openIssue or worktree.scan
-- through the real process runner (real git; the gh on PATH is a canned executable the gate wrote) and writes
-- result.json. scripts/check.py writes the request, creates the repositories and judges the outcome; nothing here
-- decides pass or fail.

local worktree = require("../worktree")

local M = {}

local function write(dir: string, name: string, body: { [string]: any })
	tern.fs.write(dir .. "/" .. name, tern.json.encode(body))
end

-- Request: { op = "open", repo = "owner/name", number = N, checkout = path },
-- { op = "issue", repo = "owner/name", key = "7", branch = "7-fix", checkout = path } or
-- { op = "scan", kind = "pr" | "issue", checkout = path }.
-- Result: { ok, hasCx, result?, describe?, update? (open only), problem? } or, for a scan, { ok, scan?, problem? }; a
-- second `done` writes duplicate.json.
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
	local valid = type(request) == "table"
		and type(request.checkout) == "string"
		and (
			(request.op == "open" and type(request.repo) == "string" and type(request.number) == "number")
			or (request.op == "issue" and type(request.repo) == "string" and type(request.key) == "string" and type(request.branch) == "string")
			or (request.op == "scan" and (request.kind == "pr" or request.kind == "issue"))
		)
	if not valid then
		write(dir, "result.json", { ok = false, hasCx = true, problem = "bad request: " .. tostring(decoded) })
		cx:toast("error", "Plotroom smoke: bad request")
		return
	end
	local issue = request.op == "issue"
	local answers = 0
	-- True for the first answer; a second one is written apart, so the gate sees a runtime that reports twice.
	local function once(): boolean
		answers += 1
		if answers > 1 then
			write(dir, "duplicate.json", { ok = false, problem = "done ran " .. answers .. " times" })
		end
		return answers == 1
	end
	-- worktree.open's Result or worktree.openIssue's IssueResult, each described by its own wording.
	local function finish(result: any, problem: string?, cx2: WindowCx?)
		if not once() then
			return
		end
		local body: { [string]: any } = { ok = result ~= nil, hasCx = cx2 ~= nil }
		if result then
			body.result = result
			if issue then
				body.describe = worktree.describeIssue(result)
			else
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
	local started, why = pcall(function()
		if request.op == "scan" then
			worktree.scan(request.checkout, request.kind, scanned)
		elseif issue then
			worktree.openIssue(request.checkout, request.repo, request.key, request.branch, "", finish)
		else
			worktree.open(request.checkout, request.repo, request.number, "", nil, finish)
		end
	end)
	if not started then
		write(dir, "result.json", { ok = false, hasCx = true, problem = "worktree." .. (if request.op == "scan" then "scan" elseif issue then "openIssue" else "open") .. " raised: " .. tostring(why) })
	end
end

return M
