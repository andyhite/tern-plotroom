--!strict
-- The one process runner gh and git share. The bare program name is spawned
-- first (the SDK looks it up on PATH). Only when the spawn itself fails is
-- the PATH of the user's login shell recovered, cached in memory, and
-- the same argv retried with it; a later failure under that PATH probes the login shell again (a newly installed program). A started process that exits nonzero is
-- never retried: that is an auth/API/git failure, not a discovery failure.

local M = {}

type Waiter = (string?, string?, WindowCx?) -> ()

local MARK_A = "\0PLOTROOM_PATH\0"
local MARK_B = "\0PLOTROOM_END\0"
local SCRIPT = "printf '\\0PLOTROOM_PATH\\0'; /usr/bin/printenv PATH; printf '\\0PLOTROOM_END\\0'"
local PROBE_TIMEOUT_MS = 5000

local recovered: string? = nil
local failed: string? = nil
local recovering: { Waiter }? = nil

-- Callbacks that need a fresh window cx get one from a zero-delay timer.
local function defer(fn: (WindowCx?) -> ())
	tern.timer(0, fn)
end

-- The PATH between the probe's markers, minus printenv's one trailing newline;
-- startup banners outside the markers are ignored.
function M.extractPath(out: string): string?
	local _, ae = string.find(out, MARK_A, 1, true)
	if not ae then
		return nil
	end
	local b = string.find(out, MARK_B, ae + 1, true)
	if not b then
		return nil
	end
	local path = string.sub(out, ae + 1, b - 1)
	if string.sub(path, -1) == "\n" then
		path = string.sub(path, 1, -2)
	end
	if path == "" or string.find(path, "\0", 1, true) then
		return nil
	end
	return path
end

local function recover(cb: Waiter)
	if failed then
		local msg = failed
		return defer(function(cx)
			cb(nil, msg, cx)
		end)
	end
	if recovered then
		local path = recovered
		return defer(function(cx)
			cb(path, nil, cx)
		end)
	end
	if recovering then
		table.insert(recovering, cb)
		return
	end
	recovering = { cb }
	local function finish(path: string?, err: string?, cx: WindowCx?)
		local waiters: { Waiter } = recovering or {}
		recovering = nil
		if path then
			recovered = path
		else
			failed = err or "unknown error"
		end
		for _, w in waiters do
			w(path, err, cx)
		end
	end
	local shell = tern.getenv("SHELL")
	if not shell or string.match(shell, "^/%S") == nil or not tern.fs.exists(shell) then
		defer(function(cx)
			finish(nil, "SHELL is not set to an absolute path of an installed shell", cx)
		end)
		return
	end
	local ok, err = pcall(function()
		tern.process.run(
			{ shell, "-l", "-i", "-c", SCRIPT },
			{ cwd = tern.getenv("HOME") or ".", timeout_ms = PROBE_TIMEOUT_MS },
			function(result: ProcessResult, cx: WindowCx?)
				local path = if result.status == 0 and not result.timed_out then M.extractPath(result.stdout) else nil
				if path then
					finish(path, nil, cx)
				elseif result.timed_out then
					finish(nil, "the shell did not answer within 5 seconds", cx)
				else
					finish(nil, "the shell did not report its PATH (exit " .. result.status .. ")", cx)
				end
			end
		)
	end)
	if not ok then
		local msg = tostring(err)
		defer(function(cx)
			finish(nil, msg, cx)
		end)
	end
end

local function explain(program: string, why: string): string
	return program
		.. " could not be started ("
		.. why
		.. "). It must be installed and available in the PATH of your configured shell; Tern looked in its own PATH and in the PATH of your login shell."
end

-- Forget failed lookups, so corrected shell configuration is found without
-- restarting Tern. The PATH recovered earlier is kept: a spawn that fails under
-- it probes the login shell again (see run). Explicit Retry calls this.
function M.reset()
	failed = nil
end

-- done(result, problem, cx): `problem` is set only when the program could not
-- be started; a started process always yields a result, whatever its status.
function M.run(argv: { string }, opts: ProcessOptions, done: (ProcessResult?, string?, WindowCx?) -> ())
	local function start(path: string?): (boolean, any)
		local env: { [string]: string } = {}
		local base = opts.env
		if base then
			for k, v in base do
				env[k] = v
			end
		end
		if path then
			env.PATH = path
		end
		local o: ProcessOptions = { cwd = opts.cwd, env = env, stdin = opts.stdin, timeout_ms = opts.timeout_ms }
		return pcall(function()
			tern.process.run(argv, o, function(result: ProcessResult, cx: WindowCx?)
				done(result, nil, cx)
			end)
		end)
	end
	local stale = recovered
	local ok, err = start(stale)
	if ok then
		return
	end
	local program = argv[1] or "program"
	-- A spawn that fails under the PATH found earlier asks the login shell once more: the program may be newly installed.
	recovered = nil
	recover(function(path, why, cx)
		if not path or path == stale then
			recovered = recovered or stale
			return done(nil, explain(program, if stale then tostring(err) else why or "unknown"), cx)
		end
		local ok2, err2 = start(path)
		if not ok2 then
			done(nil, explain(program, tostring(err2)), cx)
		end
	end)
end

return M
