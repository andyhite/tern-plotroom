--!strict
-- Local repository resolution and PR worktrees. Every command is an argv array
-- run through process.luau; nothing is ever interpolated into a shell.

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

local LOCAL_MS = 10 * 1000
local NET_MS = 120 * 1000
local ENV = { GIT_TERMINAL_PROMPT = "0" }

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

local function validSegment(s: string): boolean
	return s ~= "" and s ~= "." and s ~= ".." and string.match(s, "^[%w%-_%.]+$") ~= nil
end

-- "owner/repo" of a github.com remote URL (https, ssh://git@ or scp-like); nil otherwise.
function M.normalizeRemote(url: string): string?
	url = trim(url)
	local o, r = string.match(url, "^https://[^/]*github%.com/([^/]+)/([^/]+)$")
	if not o then
		o, r = string.match(url, "^ssh://git@github%.com/([^/]+)/([^/]+)$")
	end
	if not o then
		o, r = string.match(url, "^git@github%.com:([^/]+)/([^/]+)$")
	end
	if not o or not r then
		return nil
	end
	r = string.gsub(r, "/$", "")
	r = string.gsub(r, "%.git$", "")
	if not validSegment(o) or not validSegment(r) then
		return nil
	end
	return o .. "/" .. r
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
						for _, u in lines(urls or "") do
							local id = M.normalizeRemote(u)
							if id and string.lower(id) == want then
								return done({ root = root, commonDir = common, remote = names[i] }, nil, cxu)
							end
						end
						try(i + 1, cxu)
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
					for _, u in lines(urls or "") do
						local id = M.normalizeRemote(u)
						if id then
							return done(id, nil, cxu)
						end
					end
					try(i + 1, cxu)
				end)
			end
			try(1, cx2)
		end)
	end)
end

local function listWorktrees(root: string, done: Cb<{ Record }>)
	git(root, { "worktree", "list", "--porcelain", "-z" }, LOCAL_MS, function(out, err, cx)
		if not out then
			return done(nil, err, cx)
		end
		done(M.parseWorktrees(out), nil, cx)
	end)
end

-- "reuse" with the live record, "error" with a message, or "create".
function M.reconcile(recs: { Record }, branch: string, target: string): (string, any)
	for _, r in recs do
		if r.branch == "refs/heads/" .. branch then
			if r.locked or r.prunable or not tern.fs.exists(r.path) then
				return "error", "The worktree of " .. branch .. " at " .. r.path .. " is locked, prunable or missing; repair it manually (git worktree repair/prune)."
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

local function verify(path: string, common: string, done: Cb<string>)
	git(path, { "rev-parse", "--show-toplevel" }, LOCAL_MS, function(top, err, cx)
		if not top or trim(top) == "" then
			return done(nil, err or (path .. " is not a work tree."), cx)
		end
		git(path, { "rev-parse", "--path-format=absolute", "--git-common-dir" }, LOCAL_MS, function(cd, err2, cx2)
			if not cd then
				return done(nil, err2, cx2)
			end
			if trim(cd) ~= common then
				return done(nil, path .. " belongs to a different repository.", cx2)
			end
			done(path, nil, cx2)
		end)
	end)
end

-- Creates or reuses the worktree of PR `repo`#`number`; done(path, problem, cx).
-- Problem M.NO_REPO means neither the launch directory nor a saved mapping holds a matching checkout.
function M.open(launchCwd: string?, mappedPath: string?, repo: string, number: number, done: Cb<string>)
	local lrepo = string.lower(repo)
	local owner, name = string.match(lrepo, "^([^/]+)/([^/]+)$")
	if not owner or not name or not validSegment(owner) or not validSegment(name) then
		tern.timer(0, function(cx)
			done(nil, "Invalid repository " .. repo, cx)
		end)
		return
	end
	local suffix = owner .. "/" .. name .. "/pr-" .. number
	local branch = "plotroom/" .. suffix
	local ref = "refs/plotroom/" .. suffix

	local candidates: { string } = {}
	for _, p in { launchCwd, mappedPath } do
		if p and p ~= "" and not table.find(candidates, p) then
			table.insert(candidates, p)
		end
	end

	local function proceed(info: Repo, cx0: WindowCx?)
		github.pr(repo, number, function(meta, problem, cx1)
			if not meta then
				return done(nil, if problem then problem.message else "Could not read the pull request.", cx1)
			end
			if string.lower(meta.base) ~= lrepo then
				return done(nil, "The pull request's base is " .. meta.base .. ", not " .. repo .. ".", cx1)
			end
			listWorktrees(info.root, function(recs, err, cx2)
				if not recs then
					return done(nil, err, cx2)
				end
				local main = recs[1]
				if not main or string.sub(main.path, 1, 1) ~= "/" then
					return done(nil, "Could not find this repository's main worktree.", cx2)
				end
				local mainRoot = string.gsub(main.path, "/+$", "")
				local target = dirname(mainRoot) .. "/" .. basename(mainRoot) .. ".plotroom/" .. suffix
				local verdict, what = M.reconcile(recs, branch, target)
				if verdict == "error" then
					return done(nil, what :: string, cx2)
				elseif verdict == "reuse" then
					return verify((what :: Record).path, info.commonDir, done)
				end

				local function created(sha: string, attachBranch: boolean)
					tern.fs.mkdir(dirname(target))
					local args = if attachBranch
						then { "worktree", "add", target, branch }
						else { "worktree", "add", "-b", branch, target, sha }
					git(info.root, args, NET_MS, function(_, addErr, cx5)
						if addErr then
							-- Another window may have won the race: accept only a full match.
							return listWorktrees(info.root, function(again, _, cx6)
								local v, w = M.reconcile(again or {}, branch, target)
								if v == "reuse" then
									return verify((w :: Record).path, info.commonDir, done)
								end
								done(nil, addErr .. " (left as is: " .. target .. ")", cx6 or cx5)
							end)
						end
						verify(target, info.commonDir, function(path, verr, cx7)
							if not path then
								return done(nil, verr, cx7)
							end
							if attachBranch then
								return done(path, nil, cx7)
							end
							git(path, { "rev-parse", "HEAD" }, LOCAL_MS, function(head, herr, cx8)
								if not head or trim(head) ~= sha then
									return done(nil, herr or ("The new worktree is not at " .. sha .. "."), cx8)
								end
								done(path, nil, cx8)
							end)
						end)
					end)
				end

				local function afterFetch(sha: string, cx4: WindowCx?)
					git(info.root, { "rev-parse", "--verify", "--quiet", "refs/heads/" .. branch }, LOCAL_MS, function(tip, _, cx5, status)
						if tip then
							if trim(tip) ~= sha then
								return done(nil, "Local branch " .. branch .. " exists at a different commit than the pull request head; it is left untouched.", cx5)
							end
							return created(sha, true)
						elseif status ~= 1 then
							return done(nil, "Could not inspect branch " .. branch .. ".", cx5 or cx4)
						end
						created(sha, false)
					end)
				end

				git(info.root, { "fetch", "--no-tags", "--no-write-fetch-head", info.remote, "+refs/pull/" .. number .. "/head:" .. ref }, NET_MS, function(_, ferr, cx3)
					if ferr then
						return done(nil, ferr, cx3)
					end
					git(info.root, { "rev-parse", ref }, LOCAL_MS, function(fetched, rerr, cx4)
						if not fetched then
							return done(nil, rerr, cx4)
						end
						local sha = trim(fetched)
						if sha == meta.sha then
							return afterFetch(sha, cx4)
						end
						-- The PR moved between the metadata read and the fetch: accept only an exact match on a second read.
						github.pr(repo, number, function(again, _, cx5)
							if again and again.sha == sha then
								return afterFetch(sha, cx5)
							end
							done(nil, "The pull request changed while it was being fetched; Retry.", cx5)
						end)
					end)
				end)
			end)
		end)
	end

	local function try(i: number)
		if i > #candidates then
			return tern.timer(0, function(cx)
				done(nil, M.NO_REPO, cx)
			end)
		end
		M.resolveRepository(candidates[i], repo, function(info, _, cx)
			if info then
				return proceed(info, cx)
			end
			try(i + 1)
		end)
	end
	try(1)
end

return M
