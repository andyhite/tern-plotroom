--!strict
-- Local repository resolution and PR worktrees. Every command Plotroom runs is an argv array run through
-- process.luau; nothing is ever interpolated into a shell. (`update` and `cleanup` only format commands for the
-- user to run themselves.)

local process = require("./process")
local github = require("./github")
local tracker = require("./tracker")

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
	prBase: string, -- the branch it merges into; "" when GitHub did not say
	title: string,
	author: string,
	dirty: boolean?,
}

export type IssueResult = {
	path: string,
	root: string,
	remote: string,
	branch: string,
	key: string,
	created: boolean,
	head: string,
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

-- The checkout at `path` (any subdirectory or linked worktree) whose remotes include `repo`; done(info, problem, cx).
-- cx is nil in the host. A Jira project names no repository, so any checkout with a remote is its checkout, and the
-- first remote (origin, then upstream, then by name) is the one to branch from.
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
				if tracker.jiraProject(repo) then
					-- no URL names a Jira project, so the checkout is the user's choice, whatever its host
					if not names[1] then
						return done(nil, root .. " has no git remote to branch from.", cx3)
					end
					return done({ root = root, commonDir = common, remote = names[1] }, nil, cx3)
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

-- Makes `path` the checkout of `repo`: a folder inside a work tree of it is used as it is (`cloned` false); a folder that
-- is missing, or not inside any work tree, gets `gh repo clone` (git refuses a non-empty one, and that is the problem
-- reported); a work tree of another repository is refused. A Jira project names no repository to clone: a folder
-- outside a work tree is refused. done({ root, cloned }, problem, cx); cx is nil in the host.
function M.claimCheckout(path: string, repo: string, done: Cb<{ root: string, cloned: boolean }>)
	local function resolved(cloned: boolean)
		M.resolveRepository(path, repo, function(info, why, cx)
			if not info then
				return done(nil, if cloned then "Cloned " .. repo .. ", but " .. (why or "it could not be read") else why, cx)
			end
			done({ root = info.root, cloned = cloned }, nil, cx)
		end)
	end
	local function clone()
		if tracker.jiraProject(repo) then
			tern.timer(0, function(cx)
				done(nil, "That folder is not a git checkout. A Jira project names no repository to clone, so enter the folder of an existing checkout.", cx)
			end)
			return
		end
		github.clone(repo, path, function(problem, cx)
			if problem then
				return done(nil, problem.message, cx)
			end
			resolved(true)
		end)
	end
	if not tern.fs.exists(path) then
		return clone()
	end
	topLevel(path, function(root)
		if root then
			resolved(false)
		else
			clone()
		end
	end)
end

-- "owner/repo" of the checkout at `path` (the first github.com remote in origin/upstream/lexical order) and its main
-- checkout: a linked worktree's main one, so a saved checkout outlives the worktree. Local git only, no network.
function M.currentRepository(path: string, done: Cb<{ id: string, checkout: string }>)
	topLevel(path, function(root, err, cx)
		if not root then
			return done(nil, err, cx)
		end
		git(root, { "rev-parse", "--path-format=absolute", "--git-common-dir" }, LOCAL_MS, function(cd, err1, cx1)
			if not cd then
				return done(nil, err1, cx1)
			end
			-- `<main>/.git` for a checkout and its linked worktrees; anything else (a bare repository) keeps the top level.
			local checkout = string.match(trim(cd), "^(/.+)/%.git$") or root
			rankedRemotes(root, function(names, err2, cx2)
				if not names then
					return done(nil, err2, cx2)
				end
				local function try(i: number, cxi: WindowCx?)
					if i > #names then
						return done(nil, root .. " has no github.com remote.", cxi)
					end
					git(root, { "remote", "get-url", "--all", names[i] }, LOCAL_MS, function(urls, _, cxu)
						scan(lines(urls or ""), nil, cxu, function(id, cx3)
							if id then
								return done({ id = id, checkout = checkout }, nil, cx3)
							end
							try(i + 1, cx3)
						end)
					end)
				end
				try(1, cx2)
			end)
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
		return "error", target .. " already exists and is not the worktree of " .. branch .. "; move it away or remove it."
	end
	return "create", nil
end

-- The PR number whose Plotroom worktree holds `path` (the worktree root or any directory inside it), nil otherwise:
-- `<omp worktrees>/plotroom-<owner>_<repo>-pr-N` as `M.open` creates it, or `<checkout>.plotroom/<owner>/<repo>/pr-N`
-- from earlier versions, lowercase.
function M.prOfPath(path: string, repo: string): number?
	local owner, name = string.match(string.lower(repo), "^([^/]+)/([^/]+)$")
	if not owner or not name then
		return nil
	end
	for _, mark in { "/plotroom-" .. owner .. "_" .. name .. "-pr-", ".plotroom/" .. owner .. "/" .. name .. "/pr-" } do
		local _, e = string.find(path, mark, 1, true)
		if e then
			local n, rest = string.match(string.sub(path, e + 1), "^(%d+)(.*)$")
			if n and rest and (rest == "" or string.sub(rest, 1, 1) == "/") then
				return tonumber(n)
			end
		end
	end
	return nil
end

-- omp's worktrees directory, where omp's own PR checkouts and `omp worktree clear` live: OMP_WORKTREE_DIR, else
-- omp's `worktree.base` setting, else ~/.omp/wt. As in omp, a value that is neither absolute nor `~/` is ignored.
-- ponytail: omp profiles (OMP_PROFILE) are not followed; set worktree.base if you use one.
function M.worktreesDir(done: (string?, string?, WindowCx?) -> ())
	local home = tern.getenv("HOME")
	local env = M.expandPath(tern.getenv("OMP_WORKTREE_DIR") or "", home)
	if env then
		tern.timer(0, function(cx)
			done(env, nil, cx)
		end)
		return
	end
	process.run({ "omp", "config", "get", "worktree.base", "--json" }, { timeout_ms = LOCAL_MS }, function(res, _, cx)
		local ok, data = pcall(tern.json.decode, if res and res.status == 0 and not res.timed_out then res.stdout else "")
		local set = if ok and type(data) == "table" and type(data.value) == "string" then M.expandPath(data.value, home) else nil
		local dir = set or M.expandPath("~/.omp/wt", home)
		done(dir, if dir then nil else "HOME is not set, so omp's worktree directory is unknown.", cx)
	end)
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

-- Shared by `open` and `openIssue`: `finish` reports the result exactly once; `attempt` runs fn and fails the request
-- on an error it raises (a failed fs call, a bug) instead of letting it escape into the runtime, where done would
-- never run and the caller would wait forever; `run` is `git -C dir args`, a failure ending the request.
type Steps<T> = {
	finish: (T?, string?, WindowCx?) -> (),
	attempt: (WindowCx?, () -> ()) -> (),
	run: (string, { string }, number, (string, WindowCx?) -> ()) -> (),
}

local function steps<T>(done: Cb<T>): Steps<T>
	local finished = false
	local function finish(result: T?, problem: string?, cx: WindowCx?)
		if not finished then
			finished = true
			done(result, problem, cx)
		end
	end
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
	return { finish = finish, attempt = attempt, run = run }
end

-- Confirms `path` is a work tree of the repository whose git common dir is `commonDir`, then reports its HEAD and
-- whether it has changes. A worktree made just now must sit at `want`; it is read for changes too, since a checkout
-- hook may have written some.
local function inspectPath<T>(s: Steps<T>, path: string, commonDir: string, want: string?, step: (string, boolean?, WindowCx?) -> ())
	s.run(path, { "rev-parse", "--show-toplevel" }, LOCAL_MS, function(top, cx1)
		if trim(top) == "" then
			return s.finish(nil, path .. " is not a work tree.", cx1)
		end
		s.run(path, { "rev-parse", "--path-format=absolute", "--git-common-dir" }, LOCAL_MS, function(common, cx2)
			if trim(common) ~= commonDir then
				return s.finish(nil, path .. " belongs to a different repository.", cx2)
			end
			s.run(path, { "rev-parse", "HEAD" }, LOCAL_MS, function(out, cx3)
				local head = trim(out)
				if want and head ~= want then
					return s.finish(nil, "The new worktree is not at " .. want .. ".", cx3)
				end
				-- A failed or slow status leaves `dirty` unknown instead of failing the open.
				git(path, { "status", "--porcelain", "--untracked-files=normal" }, LOCAL_MS, function(status, _, cx4)
					s.attempt(cx4, function()
						step(head, if status then status ~= "" else nil, cx4)
					end)
				end)
			end)
		end)
	end)
end

-- Adds the worktree at `target`: on a new branch at `sha`, or (sha nil) on the branch that already exists. A lost
-- race is accepted only when the other window made the very same worktree.
local function addWorktree<T>(s: Steps<T>, root: string, target: string, branch: string, sha: string?, step: (string, boolean, WindowCx?) -> (), cx: WindowCx?)
	local parent = dirname(target)
	local why: any
	local ok = xpcall(tern.fs.mkdir, function(e: any)
		why = e
	end, parent)
	if not ok then
		return s.finish(nil, "Could not create " .. parent .. ": " .. tostring(why), cx)
	end
	-- Through omp, so the worktree starts as omp's copy-on-write clone when `worktree.clone` is on (ignored build
	-- output such as node_modules carries over) and `omp worktree` lists it.
	local argv = { "omp", "worktree", "add", "-q", "-C", root }
	local rest: { string } = if sha then { "-b", branch, target, sha } else { target, branch }
	for _, a in rest do
		table.insert(argv, a)
	end
	process.run(argv, { timeout_ms = NET_MS, env = ENV }, function(res, perr, cx5)
		local addErr = if not res
			then (perr or "omp could not be started")
			elseif res.timed_out then "omp worktree add timed out"
			elseif res.status ~= 0 then "omp worktree add failed: " .. firstLine(if res.stderr ~= "" then res.stderr else res.stdout)
			else nil
		s.attempt(cx5, function()
			if not addErr then
				return step(target, true, cx5)
			end
			-- Another window may have won the race: accept only a full match.
			git(root, { "worktree", "list", "--porcelain", "-z" }, LOCAL_MS, function(out, _, cx6)
				s.attempt(cx6 or cx5, function()
					local verdict, what = M.reconcile(if out then M.parseWorktrees(out) else {}, branch, target)
					if verdict == "reuse" then
						return step((what :: Record).path, false, cx6 or cx5)
					end
					s.finish(nil, addErr .. " (left as is: " .. target .. ")", cx6 or cx5)
				end)
			end)
		end)
	end)
end

-- once, even when a step raises. A worktree that already exists is only read, never changed or updated. Problem
-- M.NO_REPO means `checkout` is not a checkout of `repo`.
function M.open(checkout: string, repo: string, number: number, done: Cb<Result>)
	local lrepo = string.lower(repo)
	local owner, name = string.match(lrepo, "^([^/]+)/([^/]+)$")
	if not owner or not name or not M.validSegment(owner) or not M.validSegment(name) then
		tern.timer(0, function(cx)
			done(nil, "Invalid repository " .. repo, cx)
		end)
		return
	end
	-- A direct child of omp's worktrees directory: `omp worktree clear` treats nested directories there as stray and
	-- deletes them. GitHub owners hold no `_`, so the name is unambiguous; it keeps the names as they are, while the
	-- branch and the ref encode what Git refuses.
	local dirName = "plotroom-" .. owner .. "_" .. name .. "-pr-" .. number
	local branch, ref = M.refNames(owner, name, number)

	local s = steps(done)
	local finish, attempt, run = s.finish, s.attempt, s.run
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
		inspectPath(s, path, plan.info.commonDir, if created then plan.meta.sha else nil, function(head, dirty, cx)
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
				prBase = plan.meta.baseRef,
				title = plan.meta.title,
				author = plan.meta.author,
				dirty = dirty,
			}
			s.finish(result, nil, cx)
		end)
	end

	-- Best effort, before the worktree is reported: an upstream of refs/pull/N/head lets `gh pr view` (and so
	-- /review and the like) inside the worktree find the PR, although the branch is not the PR's head branch.
	local function ready(plan: Plan, path: string, created: boolean)
		git(plan.info.root, { "config", "branch." .. branch .. ".remote", plan.info.remote }, LOCAL_MS, function(_, _, cx)
			git(plan.info.root, { "config", "branch." .. branch .. ".merge", "refs/pull/" .. number .. "/head" }, LOCAL_MS, function(_, _, cx2)
				attempt(cx2 or cx, function()
					inspect(plan, path, created)
				end)
			end)
		end)
	end

	-- Adds the worktree: on a new branch at `sha`, or on the branch that already sits there.
	local function add(plan: Plan, sha: string, attach: boolean, cx: WindowCx?)
		addWorktree(s, plan.info.root, plan.target, branch, if attach then nil else sha, function(path, created)
			ready(plan, path, created)
		end, cx)
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
		M.worktreesDir(function(base, why, cx0)
			if not base then
				return finish(nil, why, cx0)
			end
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
					local plan: Plan = {
						info = info,
						meta = meta,
						root = (string.gsub(main.path, "/+$", "")),
						target = base .. "/" .. dirName,
					}
					local verdict, what = M.reconcile(recs, branch, plan.target)
					if verdict == "error" then
						return finish(nil, what :: string, cx2)
					elseif verdict == "reuse" then
						return ready(plan, (what :: Record).path, false)
					end
					fetch(plan)
				end)
			end)
		end)
	end

	M.resolveRepository(checkout, repo, function(info, _, cx)
		attempt(cx, function()
			if info then
				proceed(info)
			else
				finish(nil, M.NO_REPO, cx)
			end
		end)
	end)
end

-- The directory slot and the base ref's path part of the issues of `repo`; nils when it is neither. A GitHub `owner/name`
-- gives `owner_name` and `owner/name` (lowercase), a Jira project key `jira.abc` and `jira/abc`: a GitHub owner holds
-- no `.`, so no two projects share a slot.
local function issueSlot(repo: string): (string?, string?)
	local owner, name = string.match(string.lower(repo), "^([^/]+)/([^/]+)$")
	if owner and name and M.validSegment(owner) and M.validSegment(name) then
		return owner .. "_" .. name, refPart(owner) .. "/" .. refPart(name)
	end
	if tracker.jiraProject(repo) then
		return "jira." .. string.lower(repo), "jira/" .. string.lower(repo)
	end
	return nil, nil
end

-- Whether `repo` is a project Plotroom makes issue worktrees for: a GitHub `owner/name` or a Jira project key.
function M.validProject(repo: string): boolean
	return issueSlot(repo) ~= nil
end

-- Creates or reuses the worktree of issue `key` of `repo` on `branch`, in `<omp worktrees>/plotroom-<slot>-issue-<key>`:
-- the slot is `<owner>_<repo>` (GitHub) or `jira.<project>` (Jira), lowercase; the key keeps its case, so `issueOfPath`
-- gives it back as it is. A worktree already at that directory is reused whatever its branch; an existing local branch
-- is attached, never moved; a new branch starts at the remote's default branch. done(result, problem, cx) runs exactly
-- once. Problem M.NO_REPO means `checkout` is not a checkout of `repo`.
function M.openIssue(checkout: string, repo: string, key: string, branch: string, done: Cb<IssueResult>)
	local slot, basePart = issueSlot(repo)
	local bad: string? = nil
	if not slot or not basePart then
		bad = "Invalid repository " .. repo
	elseif not string.match(key, "^[%w_%-]+$") or #key > 64 or branch == "" then
		bad = "Invalid issue " .. key .. " of " .. repo
	end
	if bad or not slot or not basePart then
		tern.timer(0, function(cx)
			done(nil, bad, cx)
		end)
		return
	end
	local dirName = "plotroom-" .. slot .. "-issue-" .. key
	local baseRef = "refs/plotroom-base/" .. basePart

	local s = steps(done)
	local finish, attempt, run = s.finish, s.attempt, s.run

	local function inspect(info: Repo, root: string, path: string, created: boolean, want: string?, rbranch: string)
		inspectPath(s, path, info.commonDir, want, function(head, dirty, cx)
			finish({
				path = path,
				root = root,
				remote = info.remote,
				branch = rbranch,
				key = key,
				created = created,
				head = head,
				dirty = dirty,
			}, nil, cx)
		end)
	end

	local function create(info: Repo, root: string, target: string)
		git(info.root, { "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch }, LOCAL_MS, function(tip, _, cx, status)
			attempt(cx, function()
				if tip then
					return addWorktree(s, root, target, branch, nil, function(path, created)
						inspect(info, root, path, created, trim(tip), branch)
					end, cx)
				elseif status ~= 1 then
					return finish(nil, "Could not inspect branch " .. branch .. ".", cx)
				end
				git(info.root, { "fetch", "--no-tags", "--no-write-fetch-head", info.remote, "+HEAD:" .. baseRef }, NET_MS, function(_, ferr, cx3)
					attempt(cx3, function()
						git(info.root, { "rev-parse", "--verify", "--quiet", baseRef }, LOCAL_MS, function(out, _, cx4)
							attempt(cx4 or cx3, function()
								local sha = if out then trim(out) else ""
								if sha == "" then
									return finish(nil, ferr or ("Could not read the default branch of " .. repo .. "."), cx4 or cx3)
								end
								addWorktree(s, root, target, branch, sha, function(path, created)
									inspect(info, root, path, created, sha, branch)
								end, cx4 or cx3)
							end)
						end)
					end)
				end)
			end)
		end)
	end

	local function proceed(info: Repo)
		M.worktreesDir(function(base, why, cx0)
			if not base then
				return finish(nil, why, cx0)
			end
			git(info.root, { "check-ref-format", "--branch", branch }, LOCAL_MS, function(_, _, cx1, status)
				attempt(cx1, function()
					if status ~= 0 then
						return finish(nil, "Branch name " .. branch .. " is not valid; change the branch format in Settings › Worktrees.", cx1)
					end
					run(info.root, { "worktree", "list", "--porcelain", "-z" }, LOCAL_MS, function(out, cx2)
						local recs = M.parseWorktrees(out)
						local main = recs[1]
						if not main or string.sub(main.path, 1, 1) ~= "/" then
							return finish(nil, "Could not find this repository's main worktree.", cx2)
						end
						local root = (string.gsub(main.path, "/+$", ""))
						local target = base .. "/" .. dirName
						for _, r in recs do
							if r.path == target then
								local rb = if r.branch then string.gsub(r.branch, "^refs/heads/", "") else branch
								if r.locked or r.prunable or not tern.fs.exists(r.path) then
									return finish(nil, "The worktree of " .. rb .. " at " .. r.path .. " is locked, prunable or missing. If another window is creating it, choose Worktree again in a moment; otherwise repair it yourself (git worktree repair or prune).", cx2)
								end
								return inspect(info, root, r.path, false, nil, rb)
							end
						end
						local verdict, what = M.reconcile(recs, branch, target)
						if verdict == "error" then
							return finish(nil, what :: string, cx2)
						elseif verdict == "reuse" then
							return inspect(info, root, (what :: Record).path, false, nil, branch)
						end
						create(info, root, target)
					end)
				end)
			end)
		end)
	end

	M.resolveRepository(checkout, repo, function(info, _, cx)
		attempt(cx, function()
			if info then
				proceed(info)
			else
				finish(nil, M.NO_REPO, cx)
			end
		end)
	end)
end

function M.describeIssue(r: IssueResult): string
	local changes = if r.dirty == true
		then "Modified (uncommitted changes kept)"
		elseif r.dirty == false then "Clean"
		else "Changes unchecked"
	return (if r.created then "Created" else "Reused") .. " · " .. r.branch .. " at " .. short(r.head) .. " · " .. changes
end

-- Commands that remove the worktree, then its branch. Only shown to the user, as `cleanup`.
function M.cleanupIssue(r: IssueResult): { string }
	local at = "git -C " .. shellWord(r.root)
	return {
		at .. " worktree remove " .. shellWord(r.path),
		at .. " branch -d " .. shellWord(r.branch),
	}
end

-- The issue ref whose Plotroom worktree holds `path` (the root or any directory inside it), nil otherwise.
function M.issueOfPath(path: string, repo: string): string?
	local slot = issueSlot(repo)
	if not slot then
		return nil
	end
	local _, e = string.find(path, "/plotroom-" .. slot .. "-issue-", 1, true)
	if e then
		local ref, rest = string.match(string.sub(path, e + 1), "^([%w_%-]+)(.*)$")
		if ref and rest and (rest == "" or string.sub(rest, 1, 1) == "/") then
			return ref
		end
	end
	return nil
end

return M
