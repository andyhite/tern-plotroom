--!strict
-- Smoke driver for a real Tern. window.luau registers `plugin.plotroom.smoke` (only with PLOTROOM_SELFTEST=1) to
-- call `run`: it reads $PLOTROOM_SMOKE_DIR/request.json, runs worktree.open or worktree.openIssue through the real
-- process runner (real git; the gh on PATH is a canned executable the gate wrote) and writes result.json.
-- scripts/check.py writes the request, creates the repositories and judges the outcome; nothing here decides pass or fail.

local worktree = require("../worktree")

local M = {}

local function write(dir: string, name: string, body: { [string]: any })
	tern.fs.write(dir .. "/" .. name, tern.json.encode(body))
end

-- Request: { op = "open", repo = "owner/name", number = N, checkout = path } or
-- { op = "issue", repo = "owner/name", key = "7", branch = "7-fix", checkout = path }.
-- Result: { ok, hasCx, result?, describe?, update? (open only), cleanup?, problem? }; a second `done` writes duplicate.json.
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
		and type(request.repo) == "string"
		and type(request.checkout) == "string"
		and (
			(request.op == "open" and type(request.number) == "number")
			or (request.op == "issue" and type(request.key) == "string" and type(request.branch) == "string")
		)
	if not valid then
		write(dir, "result.json", { ok = false, hasCx = true, problem = "bad request: " .. tostring(decoded) })
		cx:toast("error", "Plotroom smoke: bad request")
		return
	end
	local issue = request.op == "issue"
	local answers = 0
	-- worktree.open's Result or worktree.openIssue's IssueResult, each described by its own wording.
	local function finish(result: any, problem: string?, cx2: WindowCx?)
		answers += 1
		if answers > 1 then
			write(dir, "duplicate.json", { ok = false, problem = "done ran " .. answers .. " times" })
			return
		end
		local body: { [string]: any } = { ok = result ~= nil, hasCx = cx2 ~= nil }
		if result then
			body.result = result
			if issue then
				body.describe = worktree.describeIssue(result)
				body.cleanup = tern.json.array(worktree.cleanupIssue(result))
			else
				body.describe = worktree.describe(result)
				body.update = tern.json.array(worktree.update(result))
				body.cleanup = tern.json.array(worktree.cleanup(result))
			end
		else
			body.problem = problem or "no result and no problem"
		end
		write(dir, "result.json", body)
	end
	local started, why = pcall(function()
		if issue then
			worktree.openIssue(request.checkout, request.repo, request.key, request.branch, "", finish)
		else
			worktree.open(request.checkout, request.repo, request.number, "", nil, finish)
		end
	end)
	if not started then
		write(dir, "result.json", { ok = false, hasCx = true, problem = "worktree." .. (if issue then "openIssue" else "open") .. " raised: " .. tostring(why) })
	end
end

return M
