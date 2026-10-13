--!strict
-- Local repository resolution and PR worktrees. Every command Plotroom runs is an argv array run through
-- process.luau; nothing is ever interpolated into a shell. (`update` and `cleanup` only format commands for the
-- user to run themselves.)

local process = require("./process")
local github = require("./github")

local M = {}

M.NO_REPO = "no-local-repository"

export type Repo = { root: string, commonDir: string, remote: string }
export type Record = {
	path: string,
	head: string?,
	branch: string?,
	bare: boolean,
	detached: boolean,
	locked: boolean,
	prunable: boolean,
}

-- What `open` hands back: where the worktree is, what belongs to it, whether this call made it, and how its HEAD
-- compares with the pull request's. `dirty` is nil when git could not tell.
export type Result = {
	path: string,
	root: string, -- the main worktree, for `git -C`
	remote: string,
	branch: string,
	ref: string, -- the ref the PR head was fetched into
	number: number,
	created: boolean, -- this call made the worktree; false = one already existed
	head: string, -- the worktree's HEAD
	prHead: string, -- the pull request's head, as GitHub reports it now
	prRef: string, -- the pull request's head branch on GitHub
	dirty: boolean?,
}

type Plan = { info: Repo, meta: github.PrMeta, root: string, target: string }

local LOCAL_MS = 10 * 1000
local NET_MS = 120 * 1000
-- No prompts; status never takes the index lock, so reading a worktree cannot make the user's own git command fail.
local ENV = { GIT_TERMINAL_PROMPT = "0", GIT_OPTIONAL_LOCKS = "0" }

type Cb<T> = (T?, string?, WindowCx?) -> ()

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") or ""
end

local function firstLine(s: string): string
	return string.match(s, "[^\n]+") or ""
end

local function lines(s: string): { string }
	local out = {}
	for l in string.gmatch(s, "[^\n]+") do
		local t = trim(l)
		if t ~= "" then
			table.insert(out, t)
		end
	end
	return out
end

-- Runs `git -C root <args>`; done(stdout, problem, cx, status). A nonzero exit
-- is a problem naming the failed operation.
local function git(
	root: string,
	args: { string },
	ms: number,
	done: (string?, string?, WindowCx?, number?) -> ()
)
	local argv: { string } = { "git", "-C", root }
	for _, a in args do
		table.insert(argv, a)
	end
	process.run(argv, { timeout_ms = ms, env = ENV }, function(result, perr, cx)
		if not result then
			return done(nil, perr or "git could not be started", cx, nil)
		end
		if result.timed_out then
			return done(nil, "git " .. (args[1] or "") .. " timed out", cx, -1)
		end
		if result.status ~= 0 then
			local why = firstLine(result.stderr)
			return done(nil, "git " .. table.concat(args, " ", 1, math.min(#args, 2)) .. " failed: " .. why, cx, result.status)
		end
		done(result.stdout, nil, cx, 0)
	end)
end

-- A GitHub owner or repository name, as repository links and Git operations accept it.
function M.validSegment(s: string): boolean
	return s ~= "" and s ~= "." and s ~= ".." and string.match(s, "^[%w%-_%.]+$") ~= nil
end

-- One name as a ref component. Git refuses a component that starts with a dot, holds `..` or ends in `.lock`, all
-- of which GitHub allows (`.github`, `a..b`, `x.lock`), so each such dot becomes `%2E`. A GitHub name never holds
-- `%`, so two names cannot collide, and every other name is unchanged.
local function refPart(s: string): string
	s = string.gsub(s, "^%.", "%%2E")
	s = string.gsub(s, "%.%.", ".%%2E")
	s = string.gsub(s, "%.lock$", "%%2Elock")
	return s
end

-- The local branch and the fetched ref of PR `number`; lowercase, like the worktree directory.
function M.refNames(owner: string, name: string, number: number): (string, string)
	local part = refPart(string.lower(owner)) .. "/" .. refPart(string.lower(name)) .. "/pr-" .. number
	-- Not under refs/plotroom/: the branch's short name would then also match the fetched ref, and Git warns it is ambiguous.
	return "plotroom/" .. part, "refs/plotroom-pr/" .. part
end

-- Transport host (lowercase), "owner/repo" and whether it is an SSH form of a
-- remote URL (https, ssh://git@host[:port]/ or scp-like git@host:); nils when unparsable.
function M.parseRemote(url: string): (string?, string?, boolean, string?)
	url = trim(url)
	local host, path
	local ssh = false
	local port: string? = nil
	local bad: boolean? = nil
	local auth, p = string.match(url, "^https://([^/]+)/(.+)$")
	if auth then
		host, path = string.match(auth, "([^@]+)$"), p
	else
		local a, p2 = string.match(url, "^ssh://git@([^/]+)/(.+)$")
		if a then
			local h, pt = string.match(a, "^([^:]+):?(%d*)$")
			if not h then
				bad = true
			end
			host, path = h, p2
			if pt and pt ~= "" then
				port = pt
			end
		else
			host, path = string.match(url, "^git@([^:/]+):(.+)$")
		end
		ssh = true
	end
	if not host or not path or string.match(host, "^%w[%w%.%-_]*$") == nil or (bad ~= nil) then
		return nil, nil, false
	end
	local o, r = string.match((string.gsub(path, "/+$", "")), "^([^/]+)/([^/]+)$")
	if not o or not r then
		return nil, nil, false
	end
	r = string.gsub(r, "%.git$", "")
	if not M.validSegment(o) or not M.validSegment(r) then
		return nil, nil, false
	end
	return string.lower(host), o .. "/" .. r, ssh, port
end

-- "owner/repo" of a remote URL whose host is literally github.com; nil otherwise.
function M.normalizeRemote(url: string): string?
	local host, id = M.parseRemote(url)
	return if host == "github.com" then id else nil
end

-- The `hostname` ssh would connect to, from `ssh -G` output.
function M.sshHostname(out: string): string?
	local h = string.match(out, "^hostname (%S+)") or string.match(out, "\nhostname (%S+)")
	return if h then string.lower(h) else nil
end

-- Like normalizeRemote, but an SSH host alias counts when `ssh -G` (reads the
-- user's ssh config, opens no connection) resolves it to github.com. The
-- remote itself is never rewritten, so git keeps using the alias for transport.
function M.identify(url: string, cx: WindowCx?, done: (string?, WindowCx?) -> ())
	local host, id, ssh, port = M.parseRemote(url)
	if not id or host == "github.com" then
		return done(if host == "github.com" then id else nil, cx)
	end
	if not ssh then
		return done(nil, cx)
	end
	local argv = { "ssh", "-G" }
	if port then
		table.insert(argv, "-p")
		table.insert(argv, port)
	end
	table.insert(argv, "--")
	table.insert(argv, "git@" .. (host :: string))
	process.run(argv, { timeout_ms = LOCAL_MS }, function(res, _, cx2)
		if res and res.status == 0 and not res.timed_out and M.sshHostname(res.stdout) == "github.com" then
			return done(id, cx2 or cx)
		end
		done(nil, cx2 or cx)
	end)
end

-- First URL of `urls` that identifies as a github.com repository (and equals `want`, lowercase, when given).
local function scan(urls: { string }, want: string?, cx: WindowCx?, done: (string?, WindowCx?) -> ())
	local function step(i: number, cxi: WindowCx?)
		if i > #urls then
			return done(nil, cxi)
		end
		M.identify(urls[i], cxi, function(id, cx2)
			if id and (not want or string.lower(id) == want) then
				return done(id, cx2)
			end
			step(i + 1, cx2)
		end)
	end
	step(1, cx)
end

-- Records of `git worktree list --porcelain -z`: NUL-terminated fields, an
-- extra NUL between records. Paths may hold spaces and newlines.
function M.parseWorktrees(out: string): { Record }
	local recs: { Record } = {}
	local cur: Record? = nil
	local pos = 1
	while pos <= #out do
		local nul = string.find(out, "\0", pos, true) or (#out + 1)
		local field = string.sub(out, pos, nul - 1)
		pos = nul + 1
		if field == "" then
			cur = nil
		else
			local key, value = string.match(field, "^(%S+) ?(.*)$")
			if key == "worktree" then
				cur = { path = value or "", bare = false, detached = false, locked = false, prunable = false }
				table.insert(recs, cur :: Record)
			elseif cur then
				local r = cur :: Record
				if key == "HEAD" then
					r.head = value
				elseif key == "branch" then
					r.branch = value
				elseif key == "bare" then
					r.bare = true
				elseif key == "detached" then
					r.detached = true
				elseif key == "locked" then
					r.locked = true
				elseif key == "prunable" then
					r.prunable = true
				end
			end
		end
	end
	return recs
end

local function dirname(p: string): string
	return string.match(p, "^(.*)/[^/]+$") or "."
end

local function basename(p: string): string
	return string.match(p, "([^/]+)$") or p
end

-- Expands only a leading `~/`; anything else must already be absolute.
function M.expandPath(p: string, home: string?): (string?, string?)
	p = trim(p)
	if p == "~" or string.sub(p, 1, 2) == "~/" then
		if not home or home == "" then
			return nil, "HOME is not set"
		end
		p = home .. string.sub(p, 2)
	end
	if string.sub(p, 1, 1) ~= "/" then
		return nil, "Enter an absolute path (or one starting with ~/)."
	end
	return p, nil
end

-- Remote names of the checkout at `root`, origin first, then upstream, then lexical.
local function rankedRemotes(root: string, done: (({ string }?, string?, WindowCx?) -> ()))
	git(root, { "remote" }, LOCAL_MS, function(rem, err, cx)
		if not rem then
			return done(nil, err, cx)
		end
		local names: { string } = {}
		for _, n in lines(rem) do
			if string.sub(n, 1, 1) ~= "-" then
				table.insert(names, n)
			end
		end
		local function rank(n: string): number
			return if n == "origin" then 0 elseif n == "upstream" then 1 else 2
		end
		table.sort(names, function(a, b)
			if rank(a) ~= rank(b) then
				return rank(a) < rank(b)
			end
			return a < b
		end)
		done(names, nil, cx)
	end)
end

local function topLevel(path: string, done: Cb<string>)
	git(path, { "rev-parse", "--show-toplevel" }, LOCAL_MS, function(top, err, cx)
		if not top then
			return done(nil, err, cx)
		end
		local root = trim(top)
		if root == "" then
			return done(nil, "That path is not inside a Git work tree.", cx)
		end
		done(root, nil, cx)
	end)
end

-- The checkout at `path` (any subdirectory or linked worktree) whose remotes
-- include `repo`; done(info, problem, cx). cx is nil in the host.
function M.resolveRepository(path: string, repo: string, done: Cb<Repo>)
	local want = string.lower(repo)
	topLevel(path, function(root, err, cx)
		if not root then
			return done(nil, err, cx)
		end
		git(root, { "rev-parse", "--path-format=absolute", "--git-common-dir" }, LOCAL_MS, function(cd, err2, cx2)
			if not cd then
				return done(nil, err2, cx2)
			end
			local common = trim(cd)
			rankedRemotes(root, function(names, err3, cx3)
				if not names then
					return done(nil, err3, cx3)
				end
				local function try(i: number, cxi: WindowCx?)
					if i > #names then
						return done(nil, "No remote of " .. root .. " points at github.com/" .. repo .. ".", cxi)
					end
					git(root, { "remote", "get-url", "--all", names[i] }, LOCAL_MS, function(urls, _, cxu)
						scan(lines(urls or ""), want, cxu, function(id, cx2)
							if id then
								return done({ root = root, commonDir = common, remote = names[i] }, nil, cx2)
							end
							try(i + 1, cx2)
						end)
					end)
				end
				try(1, cx3)
			end)
		end)
	end)
end

-- "owner/repo" of the checkout at `path`: the first github.com remote in
-- origin/upstream/lexical order; local git only, no network.
function M.currentRepository(path: string, done: Cb<string>)
	topLevel(path, function(root, err, cx)
		if not root then
			return done(nil, err, cx)
		end
		rankedRemotes(root, function(names, err2, cx2)
			if not names then
				return done(nil, err2, cx2)
			end
			local function try(i: number, cxi: WindowCx?)
				if i > #names then
					return done(nil, root .. " has no github.com remote.", cxi)
				end
				git(root, { "remote", "get-url", "--all", names[i] }, LOCAL_MS, function(urls, _, cxu)
					scan(lines(urls or ""), nil, cxu, function(id, cx2)
						if id then
							return done(id, nil, cx2)
						end
						try(i + 1, cx2)
					end)
				end)
			end
			try(1, cx2)
		end)
	end)
end

-- "reuse" with the live record, "error" with a message, or "create".
function M.reconcile(recs: { Record }, branch: string, target: string): (string, any)
	for _, r in recs do
		if r.branch == "refs/heads/" .. branch then
			if r.locked or r.prunable or not tern.fs.exists(r.path) then
				return "error", "The worktree of " .. branch .. " at " .. r.path .. " is locked, prunable or missing. If another window is creating it, choose Worktree again in a moment; otherwise repair it yourself (git worktree repair or prune)."
			end
			return "reuse", r
		end
	end
	for _, r in recs do
		if r.path == target then
			return "error", "The worktree record at " .. target .. " belongs to something other than " .. branch .. "."
		end
	end
	if tern.fs.exists(target) then
		return "error", target .. " already exists and is not this PR's worktree; move it away or remove it."
	end
	return "create", nil
end

-- `s` as one shell word on a single line, for the commands shown to the user (Plotroom never runs them): bare when
-- plain, else single-quoted, else ANSI-C quoted (bash, zsh) when it holds control characters such as a newline.
local function shellWord(s: string): string
	if string.match(s, "^[%w%-_%./%+=:,@%%]+$") then
		return s
	end
	if string.find(s, "%c") then
		local esc = string.gsub(s, "[%c\\']", function(c)
			return string.format("\\x%02x", string.byte(c))
		end)
		return "$'" .. esc .. "'"
	end
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

local function short(sha: string): string
	return string.sub(sha, 1, 7)
end

-- How a worktree stands against its pull request, on one line for the toast and the queue preview.
function M.describe(r: Result): string
	local origin = if r.created then "Created" else "Reused"
	local fresh = if r.head == r.prHead
		then "Current (PR head " .. short(r.head) .. " on " .. r.prRef .. ")"
		else "Different (local " .. short(r.head) .. ", PR head " .. short(r.prHead) .. " on " .. r.prRef .. "; not updated)"
	local changes = if r.dirty == true
		then "Modified (uncommitted changes kept)"
		elseif r.dirty == false then "Clean"
		else "Changes unchecked"
	return origin .. " · " .. fresh .. " · " .. changes
end

-- Commands that bring the PR's newer commits into a worktree that is not at its head; none when it is. Only shown
-- to the user: `--ff-only` refuses rather than rewrite local commits, and merge refuses to overwrite local changes.
function M.update(r: Result): { string }
	if r.head == r.prHead then
		return {}
	end
	local at = "git -C " .. shellWord(r.path)
	return {
		at .. " fetch " .. shellWord(r.remote) .. " refs/pull/" .. r.number .. "/head",
		at .. " merge --ff-only FETCH_HEAD",
	}
end

-- Commands that remove the worktree, then its branch, then the ref fetched for it. Only shown to the user: the
-- first two refuse to discard local changes or unmerged commits (`--force` and `-D` stay the user's own decision),
-- the last drops only the ref Plotroom fetched.
function M.cleanup(r: Result): { string }
	local at = "git -C " .. shellWord(r.root)
	return {
		at .. " worktree remove " .. shellWord(r.path),
		at .. " branch -d " .. shellWord(r.branch),
		at .. " update-ref -d " .. shellWord(r.ref),
	}
end

-- Creates or reuses the worktree of PR `repo`#`number`; done(result, problem, cx) runs exactly once, even when a
-- step raises. A worktree that already exists is only read, never changed or updated. Problem M.NO_REPO means
-- neither the launch directory nor a saved mapping holds a matching checkout.
function M.open(launchCwd: string?, mappedPath: string?, repo: string, number: number, done: Cb<Result>)
	local lrepo = string.lower(repo)
	local owner, name = string.match(lrepo, "^([^/]+)/([^/]+)$")
	if not owner or not name or not M.validSegment(owner) or not M.validSegment(name) then
		tern.timer(0, function(cx)
			done(nil, "Invalid repository " .. repo, cx)
		end)
		return
	end
	-- The directory keeps the names as they are; the branch and the ref encode what Git refuses.
	local suffix = owner .. "/" .. name .. "/pr-" .. number
	local branch, ref = M.refNames(owner, name, number)

	local candidates: { string } = {}
	for _, p in { launchCwd, mappedPath } do
		if p and p ~= "" and not table.find(candidates, p) then
			table.insert(candidates, p)
		end
	end

	local finished = false
	local function finish(result: Result?, problem: string?, cx: WindowCx?)
		if not finished then
			finished = true
			done(result, problem, cx)
		end
	end
	-- Runs fn; an error it raises (a failed fs call, a bug) fails the request instead of escaping into the runtime,
	-- where done would never run and the caller would wait forever.
	local function attempt(cx: WindowCx?, fn: () -> ())
		local why: any
		local ok = xpcall(fn, function(e: any)
			why = e
		end)
		if not ok then
			if finished then
				error(why, 0) -- done itself raised: not ours to swallow
			end
			finish(nil, "Worktree step failed: " .. tostring(why), cx)
		end
	end
	-- `git -C dir args`: a failure ends the request, otherwise step(stdout, cx).
	local function run(dir: string, args: { string }, ms: number, step: (string, WindowCx?) -> ())
		git(dir, args, ms, function(out, err, cx)
			if not out then
				return finish(nil, err or "git failed", cx)
			end
			attempt(cx, function()
				step(out, cx)
			end)
		end)
	end
	-- The pull request's current head and base, read from GitHub.
	local function readPr(step: (github.PrMeta, WindowCx?) -> ())
		github.pr(repo, number, function(meta, problem, cx)
			if not meta then
				return finish(nil, if problem then problem.message else "Could not read the pull request.", cx)
			end
			attempt(cx, function()
				step(meta, cx)
			end)
		end)
	end

	-- Confirms `path` is a work tree of this repository, then reports its HEAD and whether it has changes. A worktree
	-- made just now must sit at the PR head; it is read for changes too, since a checkout hook may have written some.
	local function inspect(plan: Plan, path: string, created: boolean)
		run(path, { "rev-parse", "--show-toplevel" }, LOCAL_MS, function(top, cx1)
			if trim(top) == "" then
				return finish(nil, path .. " is not a work tree.", cx1)
			end
			run(path, { "rev-parse", "--path-format=absolute", "--git-common-dir" }, LOCAL_MS, function(common, cx2)
				if trim(common) ~= plan.info.commonDir then
					return finish(nil, path .. " belongs to a different repository.", cx2)
				end
				run(path, { "rev-parse", "HEAD" }, LOCAL_MS, function(out, cx3)
					local head = trim(out)
					if created and head ~= plan.meta.sha then
						return finish(nil, "The new worktree is not at " .. plan.meta.sha .. ".", cx3)
					end
					-- A failed or slow status leaves `dirty` unknown instead of failing the open.
					git(path, { "status", "--porcelain", "--untracked-files=normal" }, LOCAL_MS, function(status, _, cx4)
						attempt(cx4, function()
							local result: Result = {
								path = path,
								root = plan.root,
								remote = plan.info.remote,
								branch = branch,
								ref = ref,
								number = number,
								created = created,
								head = head,
								prHead = plan.meta.sha,
								prRef = plan.meta.ref,
								dirty = if status then status ~= "" else nil,
							}
							finish(result, nil, cx4)
						end)
					end)
				end)
			end)
		end)
	end

	-- Adds the worktree: on a new branch at `sha`, or on the branch that already sits there.
	local function add(plan: Plan, sha: string, attach: boolean, cx: WindowCx?)
		local parent = dirname(plan.target)
		local why: any
		local ok = xpcall(tern.fs.mkdir, function(e: any)
			why = e
		end, parent)
		if not ok then
			return finish(nil, "Could not create " .. parent .. ": " .. tostring(why), cx)
		end
		local args = if attach
			then { "worktree", "add", plan.target, branch }
			else { "worktree", "add", "-b", branch, plan.target, sha }
		git(plan.info.root, args, NET_MS, function(_, addErr, cx5)
			attempt(cx5, function()
				if not addErr then
					return inspect(plan, plan.target, true)
				end
				-- Another window may have won the race: accept only a full match.
				git(plan.info.root, { "worktree", "list", "--porcelain", "-z" }, LOCAL_MS, function(out, _, cx6)
					attempt(cx6 or cx5, function()
						local verdict, what = M.reconcile(if out then M.parseWorktrees(out) else {}, branch, plan.target)
						if verdict == "reuse" then
							return inspect(plan, (what :: Record).path, false)
						end
						finish(nil, addErr .. " (left as is: " .. plan.target .. ")", cx6 or cx5)
					end)
				end)
			end)
		end)
	end

	-- The branch exists but not at the PR head and no worktree has it: left alone, with the ways forward spelled out.
	local function branchConflict(plan: Plan, tip: string, sha: string): string
		local at = "git -C " .. shellWord(plan.root)
		return "Local branch " .. branch .. " is at " .. short(tip) .. ", not at the pull request head " .. short(sha)
			.. ", and no worktree has it checked out, so it was left untouched. To reopen it as it is: "
			.. at .. " worktree add " .. shellWord(plan.target) .. " " .. shellWord(branch)
			.. ". To start over from the PR head instead: " .. at .. " branch -D " .. shellWord(branch)
			.. " (it drops commits only that branch holds), then choose Worktree again."
	end

	-- With the PR head `sha` fetched: use the branch if it already sits there, refuse it if it is elsewhere, else make it.
	local function afterFetch(plan: Plan, sha: string, cx4: WindowCx?)
		git(plan.info.root, { "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch }, LOCAL_MS, function(tip, _, cx5, status)
			attempt(cx5 or cx4, function()
				if tip then
					if trim(tip) ~= sha then
						return finish(nil, branchConflict(plan, trim(tip), sha), cx5)
					end
					return add(plan, sha, true, cx5)
				elseif status ~= 1 then
					return finish(nil, "Could not inspect branch " .. branch .. ".", cx5 or cx4)
				end
				add(plan, sha, false, cx5)
			end)
		end)
	end

	-- Fetches the PR head into our own ref and carries on with the commit that ref holds.
	local function fetch(plan: Plan)
		git(plan.info.root, { "fetch", "--no-tags", "--no-write-fetch-head", plan.info.remote, "+refs/pull/" .. number .. "/head:" .. ref }, NET_MS, function(_, ferr, cx3)
			attempt(cx3, function()
				-- Another window fetching the same ref can hold Git's lock: what counts is the commit the ref holds.
				git(plan.info.root, { "rev-parse", "--verify", "--quiet", ref }, LOCAL_MS, function(out, _, cx4)
					attempt(cx4 or cx3, function()
						local sha = if out then trim(out) else ""
						if sha == "" or (ferr and sha ~= plan.meta.sha) then
							return finish(nil, ferr or ("Could not read " .. ref .. " after fetching it."), cx4 or cx3)
						elseif sha == plan.meta.sha then
							return afterFetch(plan, sha, cx4)
						end
						-- The PR moved between the metadata read and the fetch: accept only an exact match on a second read.
						readPr(function(again, cx5)
							if again.sha ~= sha then
								return finish(nil, "The pull request changed while it was being fetched; Retry.", cx5)
							end
							afterFetch({ info = plan.info, meta = again, root = plan.root, target = plan.target }, sha, cx5)
						end)
					end)
				end)
			end)
		end)
	end

	local function proceed(info: Repo)
		readPr(function(meta, cx1)
			if string.lower(meta.base) ~= lrepo then
				return finish(nil, "The pull request's base is " .. meta.base .. ", not " .. repo .. ".", cx1)
			end
			run(info.root, { "worktree", "list", "--porcelain", "-z" }, LOCAL_MS, function(out, cx2)
				local recs = M.parseWorktrees(out)
				local main = recs[1]
				if not main or string.sub(main.path, 1, 1) ~= "/" then
					return finish(nil, "Could not find this repository's main worktree.", cx2)
				end
				local root = string.gsub(main.path, "/+$", "")
				local plan: Plan = {
					info = info,
					meta = meta,
					root = root,
					target = dirname(root) .. "/" .. basename(root) .. ".plotroom/" .. suffix,
				}
				local verdict, what = M.reconcile(recs, branch, plan.target)
				if verdict == "error" then
					return finish(nil, what :: string, cx2)
				elseif verdict == "reuse" then
					return inspect(plan, (what :: Record).path, false)
				end
				fetch(plan)
			end)
		end)
	end

	local function try(i: number)
		if i > #candidates then
			tern.timer(0, function(cx)
				finish(nil, M.NO_REPO, cx)
			end)
			return
		end
		M.resolveRepository(candidates[i], repo, function(info, _, cx)
			attempt(cx, function()
				if info then
					proceed(info)
				else
					try(i + 1)
				end
			end)
		end)
	end
	try(1)
end

return M
