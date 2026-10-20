--!strict
-- Local repository resolution and PR worktrees. Every command Plotroom runs is an argv array run through
-- process.luau; nothing is ever interpolated into a shell. (`update` only formats commands for the user to run
-- themselves; `remove` deletes a worktree and its branch only as far as plain git allows; `scan` and `dirty` only read.)

local github = require("./github")
local input = require("./input")
local process = require("./process")
local tracker = require("./tracker")

local trim = input.trim

local M = {}

M.NO_REPO = "no-local-repository"
-- openIssue's questions back: whether the issue gets a new branch or a linked PR's (UNDECIDED), and, for a new branch,
-- which remote branch it starts from (NEED_BASE).
M.UNDECIDED = "undecided"
M.NEED_BASE = "need-base"

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
	branch: string, -- the PR's head branch, a fork's as `<fork owner>/<branch>`
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

-- `ref` and `number` when the worktree is on a linked pull request's branch.
export type IssueResult = {
	path: string,
	root: string,
	remote: string,
	branch: string,
	key: string,
	created: boolean,
	head: string,
	dirty: boolean?,
	ref: string?,
	number: number?,
}

-- A worktree Plotroom made, as `scan` finds it: `root` the checkout's main worktree, `branch` its short name, `head` its
-- HEAD, `ref` a pull request's fetched ref.
export type Found = { root: string, path: string, branch: string, head: string, ref: string? }
-- What `scan` read of one checkout: its main worktree and the worktrees it found, by item key.
export type Scan = { root: string, found: { [string]: Found } }
-- How `scan` knows an item's worktree: by its branch (a pull request's head branch, an issue's new branch) or its folder
-- name (as the folder format names it now); `ref` is a pull request's fetched ref.
export type Want = { branches: { string }, dirs: { string }, ref: string? }

-- What `openIssue` is asked for: the worktree's folder name, and the branch it is on: PR `pr`'s head branch, or (`fresh`)
-- `branch`, made from remote branch `base` when it does not exist yet. Neither `pr` nor `fresh`: undecided.
export type IssuePlan = { dir: string, branch: string, pr: number?, fresh: boolean, base: string? }

-- Where a worktree goes: the repository, its main worktree, the worktree records and the target folder.
type Spot = { info: Repo, root: string, recs: { Record }, target: string }

-- A pull request checkout: the worktree, its local branch and HEAD, whether this call made it, its changes.
type Opened = { path: string, branch: string, head: string, created: boolean, dirty: boolean?, ref: string }

local LOCAL_MS = 10 * 1000
local NET_MS = 120 * 1000
local REMOVE_MS = 120 * 1000 -- deleting a worktree's whole folder (node_modules and all) takes a while
-- No prompts; status never takes the index lock, so reading a worktree cannot make the user's own git command fail.
local ENV = { GIT_TERMINAL_PROMPT = "0", GIT_OPTIONAL_LOCKS = "0" }

type Cb<T> = (T?, string?, WindowCx?) -> ()

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
	-- LC_ALL only for git: remove reads git's English "modified or untracked" to tell uncommitted changes
	process.run(argv, { timeout_ms = ms, env = { GIT_TERMINAL_PROMPT = "0", GIT_OPTIONAL_LOCKS = "0", LC_ALL = "C" } }, function(result, perr, cx)
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

-- A prompt's model as `omp --model` takes it: a model pattern ("opus", "anthropic/claude-opus-4-5", "gpt-5.2:high")
-- or an omp role alias ("@slow"). The window puts it on a shell command line, so only these characters pass.
function M.validModel(s: string): boolean
	return #s <= 100 and string.match(s, "^@?[%w][%w%._:/%-]*$") ~= nil
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

-- The ref PR `number`'s head is fetched into; lowercase. Not a branch: removing the worktree compares the branch with
-- it to tell whether the branch holds commits the pull request does not.
function M.prRef(owner: string, name: string, number: number): string
	return "refs/plotroom-pr/" .. refPart(string.lower(owner)) .. "/" .. refPart(string.lower(name)) .. "/pr-" .. number
end

-- The local branch a pull request is checked out on: its head branch `ref`, a fork's as `<fork owner>/<ref>` so a fork's
-- `main` never meets the repository's own.
function M.prBranch(ref: string, fork: string?): string
	return if fork then fork .. "/" .. ref else ref
end

-- A worktree folder name as a format renders it: one path segment, printable.
function M.validLeaf(s: string): boolean
	return s ~= "" and s ~= "." and s ~= ".." and #s <= 200 and not string.find(s, "[/%c]")
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

-- `path` with its leading `home` folder written `~`, as expandPath reads it back; unchanged anywhere else.
function M.tilde(path: string, home: string?): string
	if home and home ~= "" and (path == home or string.sub(path, 1, #home + 1) == home .. "/") then
		return "~" .. string.sub(path, #home + 1)
	end
	return path
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
-- cx is nil in the host.
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

-- Makes `path` the checkout of `repo`: a folder inside a work tree of it is used as it is (`cloned` false); a folder that
-- is missing, or not inside any work tree, gets `gh repo clone` as `account` (git refuses a non-empty one, and that is
-- the problem reported); a work tree of another repository is refused. done({ root, cloned }, problem, cx); cx is nil
-- in the host.
function M.claimCheckout(path: string, repo: string, account: string?, done: Cb<{ root: string, cloned: boolean }>)
	local function resolved(cloned: boolean)
		M.resolveRepository(path, repo, function(info, why, cx)
			if not info then
				return done(nil, if cloned then "Cloned " .. repo .. ", but " .. (why or "it could not be read") else why, cx)
			end
			done({ root = info.root, cloned = cloned }, nil, cx)
		end)
	end
	local function clone()
		github.clone(repo, path, account, function(problem, cx)
			if problem then
				return done(nil, problem.message, cx)
			end
			resolved(true)
		end)
	end
	local okExists, there = pcall(tern.fs.exists, path)
	if not okExists then
		return done(nil, "Could not look at " .. path .. ": " .. tostring(there), nil)
	end
	if not there then
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

-- "reuse" with the live record, "error" with a message, or "create". `recs[1]` is the main worktree: a branch checked
-- out there is never reused (it is no item's worktree, and git will not check it out twice).
function M.reconcile(recs: { Record }, branch: string, target: string): (string, any)
	for i, r in recs do
		if r.branch == "refs/heads/" .. branch then
			if i == 1 then
				return "error", "Branch " .. branch .. " is checked out in your main checkout at " .. r.path .. "; switch that checkout to another branch, then choose Worktree again."
			elseif r.locked or r.prunable or not tern.fs.exists(r.path) then
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

-- Whether `path` is the worktree at `root` or a directory inside it.
function M.within(path: string, root: string): boolean
	return root ~= "" and (path == root or string.sub(path, 1, #root + 1) == root .. "/")
end

-- The worktrees of the items `wants` names (by item key) in the checkout at `checkout` (any folder of it), read from
-- git's own list: a worktree is an item's when its branch is one of the item's `branches` or its folder name one of its
-- `dirs`, a branch match first. Left out, as nothing Plotroom can use or remove: the main worktree, a locked or
-- prunable record, one whose folder is gone and a detached one. One `worktree list`, local git only, nothing written.
-- done(scan, problem): on a problem nothing is known, so the caller changes nothing.
-- ponytail: an issue worktree whose branch and folder both differ from what the formats name now (a format changed
-- since it was made) is not found; match on `git config` notes if formats change often.
function M.scan(checkout: string, wants: { [string]: Want }, done: (Scan?, string?) -> ())
	git(checkout, { "worktree", "list", "--porcelain", "-z" }, LOCAL_MS, function(out, err)
		if not out then
			return done(nil, err or "git worktree list failed")
		end
		local recs = M.parseWorktrees(out)
		local main = recs[1]
		if not main or string.sub(main.path, 1, 1) ~= "/" then
			return done(nil, "Could not find this repository's main worktree.")
		end
		local byBranch: { [string]: { string } } = {}
		local byDir: { [string]: { string } } = {}
		local function add(map: { [string]: { string } }, name: string, key: string)
			map[name] = map[name] or {}
			table.insert(map[name], key)
		end
		for key, want in wants do
			for _, b in want.branches do
				add(byBranch, b, key)
			end
			for _, d in want.dirs do
				add(byDir, d, key)
			end
		end
		local result: Scan = { root = (string.gsub(main.path, "/+$", "")), found = {} }
		-- A record on a branch some item wants goes to those items; the items that only name its folder get it after
		-- the whole list, when no record of their own branch had it.
		local function give(key: string, path: string, branch: string, head: string)
			if result.found[key] == nil then
				result.found[key] = { root = result.root, path = path, branch = branch, head = head, ref = wants[key].ref }
			end
		end
		local later: { { path: string, branch: string, head: string, keys: { string } } } = {}
		for i = 2, #recs do
			local r = recs[i]
			local branch = if r.branch then string.match(r.branch, "^refs/heads/(.+)$") else nil
			if branch and r.head and not r.locked and not r.prunable then
				local byB = byBranch[branch]
				local byD = byDir[string.match(r.path, "([^/]+)/*$") or ""]
				if byB or byD then
					-- A folder the runtime cannot even look at is as good as gone.
					local here, there = pcall(tern.fs.exists, r.path)
					if here and there then
						-- Every item that names it has it: an issue worked on its PR's branch, PRs of one head branch.
						for _, key in byB or byD :: { string } do
							give(key, r.path, branch, r.head)
						end
						if byB and byD then
							table.insert(later, { path = r.path, branch = branch, head = r.head, keys = byD })
						end
					end
				end
			end
		end
		for _, l in later do
			for _, key in l.keys do
				give(key, l.path, l.branch, l.head)
			end
		end
		done(result, nil)
	end)
end

-- A path without doubled or trailing slashes, as git lists it ("/" stays).
local function clean(p: string?): string?
	return if p then (string.gsub(string.gsub(p, "/+", "/"), "(.)/$", "%1")) else nil
end

-- The folder new worktrees go in, each a direct child (`omp worktree clear` deletes nested directories there): omp's
-- worktrees directory, where omp's own PR checkouts and `omp worktree clear` live: OMP_WORKTREE_DIR, else omp's
-- `worktree.base` setting, else ~/.omp/wt (as in omp, a value that is neither absolute nor `~/` is ignored).
-- ponytail: omp profiles (OMP_PROFILE) are not followed; set worktree.base if you use one.
function M.worktreesDir(done: (string?, string?, WindowCx?) -> ())
	local home = tern.getenv("HOME")
	local env = clean((M.expandPath(tern.getenv("OMP_WORKTREE_DIR") or "", home)))
	if env then
		tern.timer(0, function(cx)
			done(env, nil, cx)
		end)
		return
	end
	process.run({ "omp", "config", "get", "worktree.base", "--json" }, { timeout_ms = LOCAL_MS }, function(res, _, cx)
		local ok, data = pcall(tern.json.decode, if res and res.status == 0 and not res.timed_out then res.stdout else "")
		local set = if ok and type(data) == "table" and type(data.value) == "string" then M.expandPath(data.value, home) else nil
		local dir = clean(set or M.expandPath("~/.omp/wt", home))
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

-- How a worktree stands against its pull request, on one line for the toast and the queue preview. It reads only
-- these fields, so a worktree `scan` found describes itself the same way once its pull request is known.
function M.describe(r: { created: boolean, head: string, prHead: string, prRef: string, dirty: boolean? }): string
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

-- The command that brings the PR's newer commits into a worktree that is not at its head; none when it is. Only shown
-- to the user: the branch tracks the PR's head branch, `--ff-only` refuses rather than rewrite local commits, and a
-- pull refuses to overwrite local changes. Reads only these fields, as `describe` does.
function M.update(r: { path: string, head: string, prHead: string }): { string }
	if r.head == r.prHead then
		return {}
	end
	return { "git -C " .. shellWord(r.path) .. " pull --ff-only" }
end

-- What `remove` takes of a worktree: where it is and what Plotroom made for it. `ref` is a pull request's fetched ref.
export type Target = { root: string, path: string, branch: string, ref: string? }

-- What `remove` did besides removing the worktree: `branch` says in a sentence what became of its branch.
export type Removal = { branch: string }

-- Git's reason as a sentence out of a failed `git` step: "git branch -d failed: error: the branch is not fully merged"
-- gives "The branch is not fully merged.".
local function reasonOf(problem: string?): string
	local why = string.match(problem or "", "^git [^:]* failed: (.*)$") or problem or "git could not be started"
	why = string.gsub(why, "^%a+: ", "")
	why = string.gsub(why, "^%l", string.upper)
	return if string.find(why, "[%.!%?]$") then why else why .. "."
end

-- Removes the worktree of `t`, then its branch, and forces nothing: git itself stops at uncommitted changes (then
-- nothing is done: done(nil, why, dirty), `dirty` when that was the reason) and `branch -d` at commits merged nowhere.
-- A pull request's branch goes with `-D` when `merge-base --is-ancestor` says the fetched ref already holds every commit
-- of it (nothing only the branch has is lost), and the fetched ref goes with it. A branch git keeps stays with its ref,
-- and the Removal says so. Host only: git runs where the checkout is, so there is no window cx.
function M.remove(t: Target, done: (Removal?, string?, boolean?) -> ())
	local branch, ref = t.branch, t.ref
	local function finish(said: string)
		done({ branch = said }, nil, nil)
	end
	local function dropRef(said: string)
		if not ref then
			return finish(said)
		end
		git(t.root, { "update-ref", "-d", ref }, LOCAL_MS, function(_, err, _, status)
			finish(if status == 0 then said else said .. " Its fetched ref " .. ref .. " was kept. " .. reasonOf(err))
		end)
	end
	local function dropBranch(flag: string)
		git(t.root, { "branch", flag, branch }, LOCAL_MS, function(_, err, _, status)
			if status ~= 0 then
				return finish("Branch " .. branch .. " was kept. " .. reasonOf(err))
			end
			dropRef("Branch " .. branch .. " was deleted too.")
		end)
	end
	git(t.root, { "worktree", "remove", t.path }, REMOVE_MS, function(_, err, _, status)
		if status ~= 0 then
			local dirty = err ~= nil and string.find(err, "modified or untracked", 1, true) ~= nil
			return done(nil, if dirty then "It has uncommitted changes; commit, stash or remove it yourself." else reasonOf(err), dirty)
		end
		if not ref then
			return dropBranch("-d")
		end
		git(t.root, { "merge-base", "--is-ancestor", "refs/heads/" .. branch, ref }, LOCAL_MS, function(_, _, _, merged)
			dropBranch(if merged == 0 then "-D" else "-d")
		end)
	end)
end

-- Plotroom notes which item a worktree's branch belongs to in the checkout's own git config (`branch.<b>.plotroomkey`
-- for an issue, `.plotroompr` for a pull request), so the inventory still knows it once the item leaves the query.
-- Best effort: a failed write only leaves the worktree unlabelled.
local function note(root: string, branch: string, repo: string, key: string?, pr: number?, done: (WindowCx?) -> ())
	local pairs_: { { string } } = { { "plotroomrepo", repo } }
	if key then
		table.insert(pairs_, { "plotroomkey", key })
	end
	if pr then
		table.insert(pairs_, { "plotroompr", tostring(pr) })
	end
	local function set(i: number, cx: WindowCx?)
		local p = pairs_[i]
		if not p then
			return done(cx)
		end
		git(root, { "config", "--local", "branch." .. branch .. "." .. p[1], p[2] }, LOCAL_MS, function(_, _, cx2)
			set(i + 1, cx2 or cx)
		end)
	end
	set(1, nil)
end

-- One worktree of the checkout, as `inventory` lists it. `key` (issue) and `number` (pull request) only when Plotroom
-- noted them; `ref` is that pull request's fetched ref. `main` rows are listed but never removable.
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
	inferred: boolean?, -- `number` was guessed from an older Plotroom's ref or branch, not noted
	repo: string?, -- the repository the branch's note names (nil: no note)
}

-- Every worktree of the checkout at `checkout`, the main one first, with the item Plotroom noted for each branch.
-- `repo` ("owner/name") only names a pull request's fetched ref. Local git only, nothing written.
function M.inventory(checkout: string, repo: string, done: ({ Entry }?, string?) -> ())
	local owner, name = string.match(repo, "^([^/]+)/([^/]+)$")
	if not owner or not name or not M.validSegment(owner) or not M.validSegment(name) then
		return done(nil, "Invalid repository " .. repo)
	end
	git(checkout, { "worktree", "list", "--porcelain", "-z" }, LOCAL_MS, function(out, err)
		if not out then
			return done(nil, err or "git worktree list failed")
		end
		local recs = M.parseWorktrees(out)
		local main = recs[1]
		if not main or string.sub(main.path, 1, 1) ~= "/" then
			return done(nil, "Could not find this repository's main worktree.")
		end
		local root = string.gsub(main.path, "/+$", "")
		-- Exit 1 is "no such key": nothing noted yet.
		git(root, { "config", "--local", "--get-regexp", "^branch\\..*\\.plotroom(key|pr|repo)$" }, LOCAL_MS, function(cfg)
			local keys: { [string]: string } = {}
			local prs: { [string]: number } = {}
			local repos: { [string]: string } = {}
			for l in string.gmatch(cfg or "", "[^\n]+") do
				local b, what, v = string.match(l, "^branch%.(.+)%.plotroom(%a+) (.+)$")
				if b and v and what == "key" then
					keys[b] = v
				elseif b and v and what == "repo" then
					repos[b] = v
				elseif b and v and what == "pr" and tonumber(v) then
					prs[b] = tonumber(v) :: number
				end
			end
			-- Worktrees made before notes existed: this repository's fetched PR refs name a pull request by the commit
			-- they hold, and an earlier version's branches were `plotroom/…/pr-N`. A commit two refs hold names none.
			local prefix = string.sub(M.prRef(owner, name, 0), 1, -2)
			local legacyBranch = "^plotroom/" .. string.gsub(string.lower(owner .. "/" .. name), "%p", "%%%0") .. "/pr%-(%d+)$"
			git(root, { "for-each-ref", "--format=%(objectname) %(refname)", prefix .. "*" }, LOCAL_MS, function(refs)
				local byHead: { [string]: number? } = {}
				local refPat = "^(%x+) " .. string.gsub(prefix, "%p", "%%%0") .. "(%d+)$"
				for l in string.gmatch(refs or "", "[^\n]+") do
					local sha, n = string.match(l, refPat)
					if sha then
						byHead[sha] = if byHead[sha] == nil then tonumber(n) else -1
					end
				end
				local entries: { Entry } = {}
				for i, r in recs do
					local branch = if r.branch then string.match(r.branch, "^refs/heads/(.+)$") else nil
					local here, there = pcall(tern.fs.exists, r.path)
					-- A note made for another repository is not this one's.
					local mine = branch ~= nil and (repos[branch] == nil or string.lower(repos[branch]) == string.lower(repo))
					local n = if branch and mine then prs[branch] else nil
					local inferred = false
					if i > 1 and branch and mine and not n and not keys[branch] then
						local legacy = tonumber(string.match(string.lower(branch), legacyBranch) or "") or (if r.head then byHead[r.head] else nil)
						if legacy and legacy > 0 then
							n, inferred = legacy, true
						end
					end
					table.insert(entries, {
						path = r.path,
						root = root,
						branch = branch,
						head = r.head,
						main = i == 1,
						detached = r.detached,
						locked = r.locked,
						prunable = r.prunable,
						missing = not (here and there),
						key = if branch and mine then keys[branch] else nil,
						number = n,
						ref = if n then M.prRef(owner, name, n) else nil,
						inferred = if inferred then true else nil,
						repo = if branch then repos[branch] else nil,
					})
				end
				done(entries, nil)
			end)
		end)
	end)
end

-- The entry of `inventory` at exactly `path` (never the main worktree) that still has `branch` (nil: detached): what a
-- window remembers is only a claim, so every action re-reads git's list and acts on its record, not the string.
local function claim(checkout: string, repo: string, path: string, branch: string?, done: (Entry?, string?) -> ())
	M.inventory(checkout, repo, function(entries, err)
		if not entries then
			return done(nil, err)
		end
		for _, e in entries do
			if e.path == path then
				if e.main then
					return done(nil, "That is the main checkout; Plotroom never removes it.")
				elseif e.branch ~= branch then
					return done(nil, "The worktree at " .. path .. " changed (it is on " .. (e.branch or "no branch") .. " now); reload the list.")
				end
				return done(e, nil)
			end
		end
		done(nil, path .. " is not a worktree of this repository any more; reload the list.")
	end)
end

-- Whether the worktree at `path` (checked against git's list as `claim` does) has uncommitted changes.
-- done(dirty, problem); dirty nil when git could not tell.
function M.inventoryDirty(checkout: string, repo: string, path: string, branch: string?, done: (boolean?, string?) -> ())
	claim(checkout, repo, path, branch, function(e, why)
		if not e then
			return done(nil, why)
		elseif e.missing then
			return done(nil, "The folder " .. path .. " is gone.")
		end
		M.dirty(e.path, function(dirty)
			done(dirty, nil)
		end)
	end)
end

-- Removes one inventory worktree without force, as `remove` does for an item's: a locked, prunable or missing one, the
-- main checkout and one that is no longer at `path` on `branch` are refused. Only a branch Plotroom noted (an issue key
-- or a pull request number, not a guessed one) goes with the worktree, as `remove` does it; any other branch is kept,
-- and a detached worktree has no branch to drop.
-- done(removal, problem, dirty).
function M.removeEntry(checkout: string, repo: string, path: string, branch: string?, done: (Removal?, string?, boolean?) -> ())
	claim(checkout, repo, path, branch, function(e, why)
		if not e then
			return done(nil, why, nil)
		elseif e.locked or e.prunable or e.missing then
			return done(nil, "The worktree at " .. path .. " is locked, prunable or missing; repair it yourself (git worktree repair or prune).", nil)
		end
		local b = e.branch
		if not b then
			return git(e.root, { "worktree", "remove", e.path }, REMOVE_MS, function(_, err, _, status)
				if status ~= 0 then
					local dirty = err ~= nil and string.find(err, "modified or untracked", 1, true) ~= nil
					return done(nil, if dirty then "It has uncommitted changes; commit, stash or remove it yourself." else reasonOf(err), dirty)
				end
				done({ branch = "It had no branch." }, nil, nil)
			end)
		end
		if e.key == nil and (e.number == nil or e.inferred == true) then
			return git(e.root, { "worktree", "remove", e.path }, REMOVE_MS, function(_, err, _, status)
				if status ~= 0 then
					local dirty = err ~= nil and string.find(err, "modified or untracked", 1, true) ~= nil
					return done(nil, if dirty then "It has uncommitted changes; commit, stash or remove it yourself." else reasonOf(err), dirty)
				end
				done({ branch = "Branch " .. b .. " was kept." }, nil, nil)
			end)
		end
		M.remove({ root = e.root, path = e.path, branch = b, ref = e.ref }, done)
	end)
end

-- What a draft pull request would be, as `draftPreview` reads it now. Everything `pushBranch` and the window's
-- confirmation need is here: `pushBranch` pushes exactly `head` to `branch` on `remote` and only while both still hold.
export type Draft = {
	path: string,
	root: string,
	repo: string,
	remote: string, -- the checkout's remote of `repo`: where the branch is pushed
	branch: string,
	head: string,
	base: string, -- the branch it would merge into
	baseSha: string, -- that branch as `remote` last fetched it
	count: number, -- commits `branch` has over the base
	commits: { string }, -- the newest 20, `<short sha> <subject>`
	upstream: string?, -- the branch's configured upstream, if any
	remoteHead: string?, -- `branch` on `remote` as last fetched
	needsPush: boolean, -- `remoteHead` is not `head`
	dirty: boolean?,
	title: string,
}

-- Current branch and HEAD of the work tree at `path`; fails on a detached HEAD.
local function headOf(path: string, done: (string?, string?, string?) -> ())
	git(path, { "symbolic-ref", "-q", "HEAD" }, LOCAL_MS, function(b, _, _, status)
		local branch = if b then string.match(trim(b), "^refs/heads/(.+)$") else nil
		if not branch then
			return done(nil, nil, if status == 1 then "HEAD is detached; check out a branch first." else "Could not read the current branch.")
		end
		git(path, { "rev-parse", "--verify", "HEAD" }, LOCAL_MS, function(h, err)
			if not h then
				return done(nil, nil, err or "Could not read HEAD.")
			end
			done(branch, trim(h), nil)
		end)
	end)
end

-- The GitHub repositories a draft PR from the work tree at `path` may target: one per distinct github.com repository
-- among its checkout's remotes (origin first), spelled as the remote URL spells it. Local git only; the same remote
-- `draftPreview`, `remoteBranches` and `pushBranch` then resolve for that repo. done(list, problem).
function M.draftDestinations(path: string, done: ({ { repo: string, remote: string } }?, string?) -> ())
	topLevel(path, function(root, err)
		if not root then
			return done(nil, err)
		end
		rankedRemotes(root, function(names, err2)
			if not names then
				return done(nil, err2)
			end
			local out: { { repo: string, remote: string } } = {}
			local seen: { [string]: boolean } = {}
			local function try(i: number)
				if i > #names then
					if #out == 0 then
						return done(nil, root .. " has no github.com remote.")
					end
					return done(out, nil)
				end
				git(root, { "remote", "get-url", "--all", names[i] }, LOCAL_MS, function(urls)
					scan(lines(urls or ""), nil, nil, function(id)
						if id and not seen[string.lower(id)] then
							seen[string.lower(id)] = true
							table.insert(out, { repo = id, remote = names[i] })
						end
						try(i + 1)
					end)
				end)
			end
			try(1)
		end)
	end)
end

-- Reads what a draft PR from the work tree at `path` into `base` of `repo` would hold. The base is fetched from the
-- remote first (network, up to two minutes; a failed fetch is a problem, never a stale base), so call it on a
-- deliberate request only. Nothing is pushed or created. done(draft, problem).
function M.draftPreview(path: string, repo: string, base: string, done: (Draft?, string?) -> ())
	M.resolveRepository(path, repo, function(info, why)
		if not info then
			return done(nil, why)
		end
		local root, remote = info.root, info.remote
		git(root, { "check-ref-format", "--branch", base }, LOCAL_MS, function(_, _, _, st)
			if st ~= 0 then
				return done(nil, "Base branch " .. base .. " is not a valid branch name.")
			end
			headOf(root, function(branch, head, err)
				if not branch or not head then
					return done(nil, err)
				elseif branch == base then
					return done(nil, "The current branch is the base " .. base .. "; there is nothing to propose.")
				end
				local baseRef = "refs/remotes/" .. remote .. "/" .. base
				-- The base is fetched (read-only, into its remote-tracking ref) so a preview never waits on the user.
				git(root, { "fetch", "--no-tags", "--no-write-fetch-head", remote, "+refs/heads/" .. base .. ":" .. baseRef }, NET_MS, function(_, ferr)
				if ferr then
					return done(nil, "Could not fetch " .. base .. " from " .. remote .. ": " .. reasonOf(ferr))
				end
				git(root, { "rev-parse", "--verify", "--quiet", baseRef }, LOCAL_MS, function(bs)
					if not bs then
						return done(nil, remote .. "/" .. base .. " could not be read.")
					end
					local baseSha = trim(bs)
					git(root, { "rev-list", "--count", baseSha .. ".." .. head }, LOCAL_MS, function(c, cerr)
						local count = tonumber(trim(c or ""))
						if not count then
							return done(nil, cerr or "Could not count the commits.")
						elseif count == 0 then
							return done(nil, branch .. " has no commits over " .. base .. ".")
						end
						git(root, { "log", "-n", "20", "--format=%h %s", baseSha .. ".." .. head }, LOCAL_MS, function(log)
							local commits = lines(log or "")
							git(root, { "rev-parse", "--abbrev-ref", "--symbolic-full-name", branch .. "@{upstream}" }, LOCAL_MS, function(up)
								git(root, { "rev-parse", "--verify", "--quiet", "refs/remotes/" .. remote .. "/" .. branch }, LOCAL_MS, function(rh)
									local remoteHead = if rh then trim(rh) else nil
									M.dirty(root, function(dirty)
										local title = if count == 1 and commits[1]
											then string.gsub(commits[1], "^%S+ ", "")
											else (string.gsub(branch, "[-_/]+", " "))
										done({
											path = path,
											root = root,
											repo = repo,
											remote = remote,
											branch = branch,
											head = head,
											base = base,
											baseSha = baseSha,
											count = count,
											commits = commits,
											upstream = if up and trim(up) ~= "" then trim(up) else nil,
											remoteHead = remoteHead,
											needsPush = remoteHead ~= head,
											dirty = dirty,
											title = title,
										}, nil)
									end)
								end)
							end)
						end)
					end)
				end)
				end)
			end)
		end)
	end)
end

-- Pushes what `draft` previewed: commit `draft.head` to `draft.branch` on `draft.remote`, never forced and never
-- committing anything. Refused when the work tree is on another branch or commit than previewed, or the remote no
-- longer is the repository's, so what the user confirmed is what goes. A rejected (non-fast-forward) push is an error.
-- done(problem): nil when pushed.
function M.pushBranch(draft: Draft, done: (string?) -> ())
	M.resolveRepository(draft.path, draft.repo, function(info, why)
		if not info then
			return done(why)
		elseif info.remote ~= draft.remote or info.root ~= draft.root then
			return done("The repository's remote changed since the preview; preview again.")
		end
		headOf(draft.root, function(branch, head, err)
			if not branch or not head then
				return done(err)
			elseif branch ~= draft.branch or head ~= draft.head then
				return done("The branch moved since the preview (" .. branch .. " at " .. short(head) .. "); preview again.")
			end
			local dest = "refs/heads/" .. draft.branch
			-- Straight through process.run: git's one-line summary of a rejected push would only say "To <url>".
			process.run({ "git", "-C", draft.root, "push", "--no-force-with-lease", draft.remote, draft.head .. ":" .. dest }, { timeout_ms = NET_MS, env = ENV }, function(res, perr)
				if not res then
					return done(perr or "git could not be started")
				elseif res.timed_out then
					return done("git push timed out")
				elseif res.status == 0 then
					return done(nil)
				end
				local why = string.match(res.stderr, "[^\n]*! %[[^\n]*") or string.match(res.stderr, "fatal: ([^\n]+)") or string.match(res.stderr, "[Ee]rror: ([^\n]+)") or firstLine(res.stderr)
				done("The push was refused: " .. trim(why))
			end)
		end)
	end)
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

-- Whether the worktree at `path` has uncommitted changes (what `git status` lists, untracked files too); nil when git
-- could not tell: a failed or slow status is never reported as clean. done(dirty, cx): cx is nil in the host.
function M.dirty(path: string, done: (boolean?, WindowCx?) -> ())
	git(path, { "status", "--porcelain", "--untracked-files=normal" }, LOCAL_MS, function(status, _, cx)
		done(if status then status ~= "" else nil, cx)
	end)
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
				M.dirty(path, function(dirty, cx4)
					s.attempt(cx4, function()
						step(head, dirty, cx4)
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

-- Resolves `checkout` as a checkout of `repo`, the worktrees folder and the main worktree, then runs `step` with where
-- the worktree named `dir` goes. Ends the request with M.NO_REPO when `checkout` is not one of `repo`.
local function locate<T>(s: Steps<T>, checkout: string, repo: string, dir: string, step: (Spot, WindowCx?) -> ())
	if not M.validLeaf(dir) then
		tern.timer(0, function(cx)
			s.finish(nil, "Worktree folder name " .. dir .. " is not usable; change its format in Settings › Worktrees.", cx)
		end)
		return
	end
	M.resolveRepository(checkout, repo, function(info, _, cx)
		s.attempt(cx, function()
			if not info then
				return s.finish(nil, M.NO_REPO, cx)
			end
			M.worktreesDir(function(base, why, cx0)
				if not base then
					return s.finish(nil, why, cx0)
				end
				s.run(info.root, { "worktree", "list", "--porcelain", "-z" }, LOCAL_MS, function(out, cx1)
					local recs = M.parseWorktrees(out)
					local main = recs[1]
					if not main or string.sub(main.path, 1, 1) ~= "/" then
						return s.finish(nil, "Could not find this repository's main worktree.", cx1)
					end
					step({ info = info, root = (string.gsub(main.path, "/+$", "")), recs = recs, target = base .. "/" .. dir }, cx1)
				end)
			end)
		end)
	end)
end

-- Checks out pull request `number` of `repo` (as `meta` read it) at `spot.target` on its own head branch (prBranch): the
-- worktree that already has that branch is reused, an existing local branch is attached whatever its commit (it is the
-- user's), and a new one starts at the PR head, tracking the head branch (a fork's through its URL) so `git pull`,
-- `git push` and `gh pr view` work there. A worktree that already exists is only read.
local function checkoutPr<T>(s: Steps<T>, spot: Spot, repo: string, number: number, meta: github.PrMeta, account: string?, cx0: WindowCx?, step: (Opened, github.PrMeta, WindowCx?) -> ())
	local owner, name = string.match(repo, "^([^/]+)/([^/]+)$")
	local ref = M.prRef(owner or "", name or "", number)
	local branch = M.prBranch(meta.ref, meta.fork)
	local info = spot.info

	local function inspect(m: github.PrMeta, path: string, created: boolean, want: string?, onBranch: string?)
		inspectPath(s, path, info.commonDir, want, function(head, dirty, cx)
			step({ path = path, branch = onBranch or branch, head = head, created = created, dirty = dirty, ref = ref }, m, cx)
		end)
	end

	-- Only a branch made here gets an upstream: an existing one keeps the user's.
	local function track(m: github.PrMeta, path: string)
		local remote = if m.forkRepo then "https://github.com/" .. m.forkRepo .. ".git" else info.remote
		-- A deleted fork took its branch along; the pull request's own ref still holds the head.
		local merge = if m.fork and not m.forkRepo then "refs/pull/" .. number .. "/head" else "refs/heads/" .. m.ref
		git(info.root, { "config", "branch." .. branch .. ".remote", remote }, LOCAL_MS, function(_, _, cx)
			git(info.root, { "config", "branch." .. branch .. ".merge", merge }, LOCAL_MS, function(_, _, cx2)
				s.attempt(cx2 or cx, function()
					inspect(m, path, true, m.sha)
				end)
			end)
		end)
	end

	local function afterFetch(m: github.PrMeta, cx: WindowCx?)
		git(info.root, { "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch }, LOCAL_MS, function(tip, _, cx1, status)
			s.attempt(cx1 or cx, function()
				if tip then
					local at = trim(tip)
					return addWorktree(s, spot.root, spot.target, branch, nil, function(path, created)
						inspect(m, path, created, if created then at else nil)
					end, cx1)
				elseif status ~= 1 then
					return s.finish(nil, "Could not inspect branch " .. branch .. ".", cx1 or cx)
				end
				addWorktree(s, spot.root, spot.target, branch, m.sha, function(path, created)
					if created then
						return track(m, path)
					end
					inspect(m, path, false, nil)
				end, cx1)
			end)
		end)
	end

	-- A same-repository head branch into its remote-tracking ref, best effort (a merged PR's branch may be deleted), so
	-- the new branch's upstream is known at once.
	local function onward(m: github.PrMeta, cx: WindowCx?)
		if m.fork then
			return afterFetch(m, cx)
		end
		local tracking = "+refs/heads/" .. m.ref .. ":refs/remotes/" .. info.remote .. "/" .. m.ref
		git(info.root, { "fetch", "--no-tags", "--no-write-fetch-head", info.remote, tracking }, NET_MS, function(_, _, cx1)
			s.attempt(cx1 or cx, function()
				afterFetch(m, cx1 or cx)
			end)
		end)
	end

	-- The PR head into our own ref (removal compares the branch with it), then on with the commit that ref holds.
	local function fetch(m: github.PrMeta)
		git(info.root, { "fetch", "--no-tags", "--no-write-fetch-head", info.remote, "+refs/pull/" .. number .. "/head:" .. ref }, NET_MS, function(_, ferr, cx)
			s.attempt(cx, function()
				-- Another window fetching the same ref can hold Git's lock: what counts is the commit the ref holds.
				git(info.root, { "rev-parse", "--verify", "--quiet", ref }, LOCAL_MS, function(out, _, cx1)
					s.attempt(cx1 or cx, function()
						local sha = if out then trim(out) else ""
						if sha == "" or (ferr and sha ~= m.sha) then
							return s.finish(nil, ferr or ("Could not read " .. ref .. " after fetching it."), cx1 or cx)
						elseif sha == m.sha then
							return onward(m, cx1)
						end
						-- The PR moved between the metadata read and the fetch: accept only an exact match on a second read.
						github.pr(repo, number, account, function(again, problem, cx2)
							s.attempt(cx2, function()
								if not again then
									return s.finish(nil, if problem then problem.message else "Could not read the pull request.", cx2)
								elseif again.sha ~= sha then
									return s.finish(nil, "The pull request changed while it was being fetched; Retry.", cx2)
								end
								onward(again, cx2)
							end)
						end)
					end)
				end)
			end)
		end)
	end

	-- A worktree already at the PR's folder is its own whatever its branch (an earlier version's `plotroom/…/pr-N`).
	for i = 2, #spot.recs do
		local r = spot.recs[i]
		local on = if r.branch then string.match(r.branch, "^refs/heads/(.+)$") else nil
		if r.path == spot.target and on and r.branch ~= "refs/heads/" .. branch and not r.locked and not r.prunable and tern.fs.exists(r.path) then
			return inspect(meta, r.path, false, nil, on)
		end
	end
	local function decide(cx: WindowCx?)
		local verdict, what = M.reconcile(spot.recs, branch, spot.target)
		if verdict == "error" then
			return s.finish(nil, what :: string, cx)
		elseif verdict == "reuse" then
			return inspect(meta, (what :: Record).path, false, nil)
		end
		fetch(meta)
	end
	-- A branch noted for another pull request is never reused or moved: `alice/x` (a same-repository head) and alice's
	-- fork branch `x` share a local name.
	git(info.root, { "config", "--local", "--get-regexp", "^branch\\..*\\.plotroom(pr|repo)$" }, LOCAL_MS, function(cfg, _, cxn)
		s.attempt(cxn or cx0, function()
			local other: number?
			local at = repo
			for l in string.gmatch(cfg or "", "[^\n]+") do
				local b, what, v = string.match(l, "^branch%.(.+)%.plotroom(%a+) (.+)$")
				if b == branch and what == "pr" then
					other = tonumber(v)
				elseif b == branch and what == "repo" then
					at = v :: string
				end
			end
			if not other or (other == number and string.lower(at) == string.lower(repo)) then
				return decide(cxn or cx0)
			end
			s.finish(nil, "Branch " .. branch .. " is already the worktree branch of " .. at .. "#" .. other .. "; " .. repo .. "#" .. number .. " would need the same local branch. Remove that worktree first.", cxn or cx0)
		end)
	end)
end

-- Creates or reuses the worktree of pull request `number` of `repo` (checkoutPr) in the worktrees folder, under the
-- folder name `naming` gives the PR (nil and why when it cannot). done(result, problem, cx) runs exactly once, even
-- when a step raises. Problem M.NO_REPO means `checkout` is not a checkout of `repo`.
function M.open(checkout: string, repo: string, number: number, naming: (github.PrMeta) -> (string?, string?), account: string?, done: Cb<Result>)
	local owner, name = string.match(repo, "^([^/]+)/([^/]+)$")
	if not owner or not name or not M.validSegment(owner) or not M.validSegment(name) then
		tern.timer(0, function(cx)
			done(nil, "Invalid repository " .. repo, cx)
		end)
		return
	end
	local s = steps(function(r: Result?, problem: string?, cx: WindowCx?)
		if not r then
			return done(nil, problem, cx)
		end
		note(r.root, r.branch, repo, nil, r.number, function(cx2)
			done(r, nil, cx2 or cx)
		end)
	end)
	github.pr(repo, number, account, function(meta, problem, cx)
		s.attempt(cx, function()
			if not meta then
				return s.finish(nil, if problem then problem.message else "Could not read the pull request.", cx)
			elseif string.lower(meta.base) ~= string.lower(repo) then
				return s.finish(nil, "The pull request's base is " .. meta.base .. ", not " .. repo .. ".", cx)
			end
			local found: github.PrMeta = meta
			local dir, why = naming(found)
			if not dir then
				return s.finish(nil, why, cx)
			end
			locate(s, checkout, repo, dir, function(spot, cx1)
				checkoutPr(s, spot, repo, number, found, account, cx1, function(o, m, cx2)
					s.finish({
						path = o.path,
						root = spot.root,
						remote = spot.info.remote,
						branch = o.branch,
						ref = o.ref,
						number = number,
						created = o.created,
						head = o.head,
						prHead = m.sha,
						prRef = m.ref,
						prBase = m.baseRef,
						title = m.title,
						author = m.author,
						dirty = o.dirty,
					}, nil, cx2)
				end)
			end)
		end)
	end)
end

-- The branches of `repo`'s remote, its default branch first, then by name; done(names, problem, cx). Problem M.NO_REPO
-- means `checkout` is not a checkout of `repo`.
function M.remoteBranches(checkout: string, repo: string, done: Cb<{ string }>)
	M.resolveRepository(checkout, repo, function(info, _, cx)
		if not info then
			return done(nil, M.NO_REPO, cx)
		end
		git(info.root, { "ls-remote", "--symref", info.remote, "HEAD", "refs/heads/*" }, NET_MS, function(out, err, cx1)
			if not out then
				return done(nil, err, cx1)
			end
			local default = string.match(out, "ref: refs/heads/(%S+)%s+HEAD")
			local names: { string } = {}
			for name in string.gmatch(out, "%x+\trefs/heads/([^\n]+)") do
				if name ~= default then
					table.insert(names, name)
				end
			end
			table.sort(names)
			if default then
				table.insert(names, 1, default)
			end
			done(names, nil, cx1)
		end)
	end)
end

-- Whether `repo` is a project issue links may name: a GitHub `owner/name` or a Jira project key.
function M.validProject(repo: string): boolean
	local owner, name = string.match(repo, "^([^/]+)/([^/]+)$")
	return (owner ~= nil and name ~= nil and M.validSegment(owner) and M.validSegment(name)) or tracker.jiraProject(repo)
end

-- Creates or reuses the worktree of issue `key` of the GitHub repository `repo`, in the worktrees folder as `plan.dir`.
-- A worktree already there is reused whatever its branch. Otherwise it is on PR `plan.pr`'s branch (checkoutPr), or
-- (`plan.fresh`) on `plan.branch`: attached when that local branch exists (never moved), else made from remote branch
-- `plan.base`, fetched first. done(result, problem, cx) runs exactly once. Problems M.NO_REPO (`checkout` is not one of
-- `repo`), M.UNDECIDED (no worktree yet, and neither `pr` nor `fresh`) and M.NEED_BASE (a new branch and no `base`)
-- ask the caller for more.
function M.openIssue(checkout: string, repo: string, key: string, plan: IssuePlan, account: string?, done: Cb<IssueResult>)
	local owner, name = string.match(repo, "^([^/]+)/([^/]+)$")
	local bad: string? = nil
	if not owner or not name or not M.validSegment(owner) or not M.validSegment(name) then
		bad = "Invalid repository " .. repo
	elseif not string.match(key, "^[%w_%-]+$") or #key > 64 or (plan.fresh and plan.branch == "") then
		bad = "Invalid issue " .. key .. " of " .. repo
	end
	if bad then
		local why: string = bad
		tern.timer(0, function(cx)
			done(nil, why, cx)
		end)
		return
	end
	local branch = plan.branch
	local s = steps(function(r: IssueResult?, problem: string?, cx: WindowCx?)
		if not r then
			return done(nil, problem, cx)
		end
		note(r.root, r.branch, repo, r.key, r.number, function(cx2)
			done(r, nil, cx2 or cx)
		end)
	end)
	local finish, attempt = s.finish, s.attempt

	local function inspect(spot: Spot, path: string, created: boolean, want: string?, rbranch: string)
		inspectPath(s, path, spot.info.commonDir, want, function(head, dirty, cx)
			finish({ path = path, root = spot.root, remote = spot.info.remote, branch = rbranch, key = key, created = created, head = head, dirty = dirty }, nil, cx)
		end)
	end

	-- A new branch at remote branch `base`, fetched into its remote-tracking ref first.
	local function create(spot: Spot, base: string, cx: WindowCx?)
		local info = spot.info
		local tracking = "refs/remotes/" .. info.remote .. "/" .. base
		git(info.root, { "check-ref-format", "--branch", base }, LOCAL_MS, function(_, _, cx1, status)
			attempt(cx1 or cx, function()
				if status ~= 0 then
					return finish(nil, "Base branch " .. base .. " is not a valid branch name.", cx1 or cx)
				end
				git(info.root, { "fetch", "--no-tags", "--no-write-fetch-head", info.remote, "+refs/heads/" .. base .. ":" .. tracking }, NET_MS, function(_, ferr, cx2)
					attempt(cx2, function()
						git(info.root, { "rev-parse", "--verify", "--quiet", tracking }, LOCAL_MS, function(out, _, cx3)
							attempt(cx3 or cx2, function()
								local sha = if out then trim(out) else ""
								if ferr or sha == "" then
									return finish(nil, ferr or ("Could not read " .. base .. " of " .. repo .. "."), cx3 or cx2)
								end
								addWorktree(s, spot.root, spot.target, branch, sha, function(path, created)
									inspect(spot, path, created, if created then sha else nil, branch)
								end, cx3 or cx2)
							end)
						end)
					end)
				end)
			end)
		end)
	end

	-- The issue's own branch: reused where a worktree has it, attached when it exists, else made from `plan.base`.
	local function fresh(spot: Spot, cx: WindowCx?)
		local info = spot.info
		git(info.root, { "check-ref-format", "--branch", branch }, LOCAL_MS, function(_, _, cx1, status)
			attempt(cx1 or cx, function()
				if status ~= 0 then
					return finish(nil, "Branch name " .. branch .. " is not valid; change the branch format in Settings › Repositories.", cx1 or cx)
				end
				local verdict, what = M.reconcile(spot.recs, branch, spot.target)
				if verdict == "error" then
					return finish(nil, what :: string, cx1 or cx)
				elseif verdict == "reuse" then
					return inspect(spot, (what :: Record).path, false, nil, branch)
				end
				git(info.root, { "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch }, LOCAL_MS, function(tip, _, cx2, st)
					attempt(cx2 or cx1, function()
						local base = plan.base
						if tip then
							local at = trim(tip)
							return addWorktree(s, spot.root, spot.target, branch, nil, function(path, created)
								inspect(spot, path, created, if created then at else nil, branch)
							end, cx2)
						elseif st ~= 1 then
							return finish(nil, "Could not inspect branch " .. branch .. ".", cx2 or cx1)
						elseif not base then
							return finish(nil, M.NEED_BASE, cx2 or cx1)
						end
						create(spot, base, cx2)
					end)
				end)
			end)
		end)
	end

	locate(s, checkout, repo, plan.dir, function(spot, cx)
		for _, r in spot.recs do
			if r.path == spot.target then
				local rb = if r.branch then string.gsub(r.branch, "^refs/heads/", "") else branch
				if r.locked or r.prunable or not tern.fs.exists(r.path) then
					return finish(nil, "The worktree of " .. rb .. " at " .. r.path .. " is locked, prunable or missing. If another window is creating it, choose Worktree again in a moment; otherwise repair it yourself (git worktree repair or prune).", cx)
				end
				return inspect(spot, r.path, false, nil, rb)
			end
		end
		local pr = plan.pr
		if pr then
			local n: number = pr
			github.pr(repo, n, account, function(meta, problem, cx1)
				attempt(cx1, function()
					if not meta then
						return finish(nil, if problem then problem.message else "Could not read the pull request.", cx1)
					elseif string.lower(meta.base) ~= string.lower(repo) then
						return finish(nil, "Pull request #" .. n .. " merges into " .. meta.base .. ", not " .. repo .. ".", cx1)
					end
					checkoutPr(s, spot, repo, n, meta, account, cx1, function(o, _, cx2)
						finish({ path = o.path, root = spot.root, remote = spot.info.remote, branch = o.branch, key = key, created = o.created, head = o.head, dirty = o.dirty, ref = o.ref, number = n }, nil, cx2)
					end)
				end)
			end)
			return
		elseif not plan.fresh then
			return finish(nil, M.UNDECIDED, cx)
		end
		fresh(spot, cx)
	end)
end

-- How an issue's worktree stands, on one line; like `describe`, it reads only these fields.
function M.describeIssue(r: { created: boolean, branch: string, head: string, dirty: boolean? }): string
	local changes = if r.dirty == true
		then "Modified (uncommitted changes kept)"
		elseif r.dirty == false then "Clean"
		else "Changes unchecked"
	return (if r.created then "Created" else "Reused") .. " · " .. r.branch .. " at " .. short(r.head) .. " · " .. changes
end

return M
