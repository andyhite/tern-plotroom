--!strict
-- Smoke driver for a real Tern. window.luau registers `plugin.plotroom.smoke` (only with PLOTROOM_SELFTEST=1) to
-- call `run`: it reads $PLOTROOM_SMOKE_DIR/request.json, runs worktree.open through the real process runner (real
-- git; the gh on PATH is a canned executable the gate wrote) and writes result.json. scripts/check.py writes the
-- request, creates the repositories and judges the outcome; nothing here decides pass or fail.

local worktree = require("../worktree")

local M = {}

local function write(dir: string, name: string, body: { [string]: any })
	tern.fs.write(dir .. "/" .. name, tern.json.encode(body))
end

-- Request: { op = "open", repo = "owner/name", number = N, checkout = path }.
-- Result: { ok, hasCx, result?, describe?, update?, cleanup?, problem? }; a second `done` writes duplicate.json.
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
	if type(request) ~= "table" or request.op ~= "open" or type(request.repo) ~= "string" or type(request.number) ~= "number" or type(request.checkout) ~= "string" then
		write(dir, "result.json", { ok = false, hasCx = true, problem = "bad request: " .. tostring(decoded) })
		cx:toast("error", "Plotroom smoke: bad request")
		return
	end
	local answers = 0
	local started, why = pcall(function()
		worktree.open(request.checkout, request.repo, request.number, function(result, problem, cx2)
			answers += 1
			if answers > 1 then
				write(dir, "duplicate.json", { ok = false, problem = "done ran " .. answers .. " times" })
				return
			end
			local body: { [string]: any } = { ok = result ~= nil, hasCx = cx2 ~= nil }
			if result then
				body.result = result
				body.describe = worktree.describe(result)
				body.update = tern.json.array(worktree.update(result))
				body.cleanup = tern.json.array(worktree.cleanup(result))
			else
				body.problem = problem or "no result and no problem"
			end
			write(dir, "result.json", body)
		end)
	end)
	if not started then
		write(dir, "result.json", { ok = false, hasCx = true, problem = "worktree.open raised: " .. tostring(why) })
	end
end

return M
