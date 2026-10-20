--!strict
-- Regression cases: worktree module and its host-less flows.

local h = require("../harness")

type Call = h.Call
type GhReq = h.GhReq
type Git = h.Git
type Reply = h.Reply
type Scene = h.Scene
type Worktree = h.Worktree
type World = h.World

local case, countCalls, countLog, eq, has, jsonEncode = h.case, h.countCalls, h.countLog, h.eq, h.has, h.jsonEncode
local lacks, newGh, newGit, ranSince, same, scene = h.lacks, h.newGh, h.newGit, h.ranSince, h.same, h.scene
local sha, show, snapshot, validRef, windowCase, yes = h.sha, h.show, h.snapshot, h.validRef, h.windowCase, h.yes
local asks = h.asks

case("worktree: git-illegal names that GitHub allows are encoded in the fetched ref, never rejected", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local expect: { { string } } = {
		{ "github", ".github", "refs/plotroom-pr/github/%2Egithub/pr-1" },
		{ "o", "a..b", "refs/plotroom-pr/o/a.%2Eb/pr-1" },
		{ "o", "x.lock", "refs/plotroom-pr/o/x%2Elock/pr-1" },
		{ "o", ".lock", "refs/plotroom-pr/o/%2Elock/pr-1" },
		{ "o", "...", "refs/plotroom-pr/o/%2E.%2E/pr-1" },
		{ "o", "foo.js", "refs/plotroom-pr/o/foo.js/pr-1" },
		{ "O", "R", "refs/plotroom-pr/o/r/pr-1" },
		{ "-x", "a.", "refs/plotroom-pr/-x/a./pr-1" },
	}
	for _, row in expect do
		local ref = worktree.prRef(row[1], row[2], 1)
		eq(ref, row[3], "ref of " .. row[1] .. "/" .. row[2])
		yes(validRef(ref), "git accepts the ref of " .. row[2])
	end
end)

case("worktree: fetched ref names are injective and git-acceptable for every legal name over a small alphabet", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local alphabet = { ".", "a", "l", "o", "c", "k" }
	local seen: { [string]: string } = {}
	local count = 0
	local function visit(prefix: string, depth: number)
		if prefix ~= "" and worktree.validSegment(prefix) then
			local ref = worktree.prRef("o", prefix, 1)
			yes(validRef(ref), "ref for " .. prefix)
			local clash = seen[ref]
			if clash ~= nil then
				error("the names " .. clash .. " and " .. prefix .. " share the ref " .. ref, 0)
			end
			seen[ref] = prefix
			count += 1
			local needsEscape = string.sub(prefix, 1, 1) == "." or string.find(prefix, "..", 1, true) ~= nil or string.sub(prefix, -5) == ".lock"
			if not needsEscape and ref ~= "refs/plotroom-pr/o/" .. prefix .. "/pr-1" then
				error("the name " .. prefix .. " needs no escaping but became " .. ref, 0)
			end
		end
		if depth < 6 then
			for _, ch in alphabet do
				visit(prefix .. ch, depth + 1)
			end
		end
	end
	visit("", 0)
	yes(count > 20000, "only " .. count .. " names were generated")
end)

case("worktree.inventory: a checkout saved for two repositories lists each one's notes, every row under the repository its note names", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local board = w.load("board") :: typeof(require("../../board"))
	asks.bk.inventoryRepo(w) -- /wt/pr5 and /wt/issue are o/r's, /wt/foreign is x/y's
	local api: any = {
		inventory = worktree.inventory,
		dirty = function(_, done)
			done(false)
		end,
		inventoryDirty = worktree.inventoryDirty,
		removeEntry = worktree.removeEntry,
	}
	local b = board.new()
	board.load(b, api, { ["o/r"] = "/work/r", ["x/y"] = "/work/r" }, function()
		return true
	end, function() end)
	w.flush()
	local by: { [string]: string } = {}
	for _, r in b.rows do
		by[r.path] = r.repo .. (if r.number or r.key then " noted" else " unnoted")
	end
	eq(by["/wt/pr5"], "o/r noted", "o/r's pull request")
	eq(by["/wt/issue"], "o/r noted", "o/r's issue")
	eq(by["/wt/foreign"], "x/y noted", "x/y's issue is listed under x/y, noted")
	eq(by["/wt/lk"], "o/r unnoted", "an unnoted worktree stays with the first repository")
	eq(by["/work/r"], "o/r unnoted", "as does the main one")
	eq(#b.rows, 8, "each worktree is listed once")
	eq(#b.problems, 0, "no problem")
end)

case("worktree: a branch checked out in the main checkout is never reused as an item's worktree", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local main = { path = "/r", branch = "refs/heads/feature", bare = false, detached = false, locked = false, prunable = false }
	local verdict, why = worktree.reconcile({ main } :: any, "feature", "/wt/plotroom-o_r-pr-5")
	eq(verdict, "error", "the main checkout is not taken")
	has(why, "main checkout at /r", "and the message says where the branch is")
end)

case("worktree: validSegment accepts GitHub names and refuses path tricks", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	for _, name in { ".github", "a..b", "x.lock", "foo.js", "a-b_c", "A1" } do
		yes(worktree.validSegment(name), name .. " is a legal name")
	end
	for _, name in { "", ".", "..", "a/b", "a b", "a\n", "é", "a%2E" } do
		yes(not worktree.validSegment(name), show(name) .. " is refused")
	end
end)

case("worktree: remote URLs with a trailing slash still identify the repository", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	for _, url in { "https://github.com/o/r", "https://github.com/o/r/", "https://github.com/o/r.git/", "git@github.com:o/r/", "ssh://git@github.com/o/r.git/" } do
		eq(worktree.normalizeRemote(url), "o/r", url)
	end
	eq(worktree.normalizeRemote("https://github.com/o/"), nil, "an owner alone is not a repository")
end)

local function resultOf(created: boolean, head: string, prHead: string, dirty: boolean?): { [string]: any }
	return {
		path = "/wt/plotroom-o_r-pr-5",
		root = "/work/r",
		remote = "origin",
		branch = "feature",
		ref = "refs/plotroom-pr/o/r/pr-5",
		number = 5,
		created = created,
		head = head,
		prHead = prHead,
		prRef = "feature",
		prBase = "main",
		title = "Add a feature",
		author = "ann",
		dirty = dirty,
	}
end

case("worktree: describe says whether the worktree is current, different, modified or unchecked", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local fresh = worktree.describe(resultOf(true, sha("b"), sha("b"), false) :: any)
	has(fresh, "Created", "fresh")
	has(fresh, "Current", "fresh is current")
	has(fresh, "Clean", "fresh is clean")
	local advanced = worktree.describe(resultOf(false, sha("b"), sha("c"), true) :: any)
	has(advanced, "Reused", "advanced and modified")
	has(advanced, "Different", "advanced")
	has(advanced, "bbbbbbb", "names the local head")
	has(advanced, "ccccccc", "names the PR head")
	has(advanced, "Modified", "modified")
	has(worktree.describe(resultOf(false, sha("b"), sha("b"), nil) :: any), "unchecked", "status unknown is never Clean")
end)

case("worktree: update commands are single-line shell words, quoted for spaces, quotes and control characters", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local current = resultOf(false, sha("b"), sha("b"), false)
	same(worktree.update(current :: any), {}, "nothing to update when current")
	local behind = resultOf(false, sha("b"), sha("c"), false)
	same(worktree.update(behind :: any), { "git -C /wt/plotroom-o_r-pr-5 pull --ff-only" }, "update: one pull, for the branch tracks the PR's head branch, and only a fast-forward")
	local odd = resultOf(false, sha("b"), sha("c"), false)
	odd.path = "/tmp/a b/it's"
	eq(worktree.update(odd :: any)[1], "git -C '/tmp/a b/it'\\''s' pull --ff-only", "spaces and quotes")
	odd.path = "/tmp/a\nb"
	local entries = worktree.update(odd :: any)
	eq(entries[1], "git -C $'/tmp/a\\x0ab' pull --ff-only", "a newline")
	lacks(entries[1], "\n", "a command stays on one line")
end)

case("worktree: tilde writes the home folder as ~ and leaves every other path as it is", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	eq(worktree.tilde("/home/u/.omp/wt/plotroom-o_r-pr-5", "/home/u"), "~/.omp/wt/plotroom-o_r-pr-5", "under home")
	eq(worktree.tilde("/home/u", "/home/u"), "~", "home itself")
	eq(worktree.tilde("/home/user/wt", "/home/u"), "/home/user/wt", "a folder whose name only starts like home's")
	eq(worktree.tilde("/wt/x", "/home/u"), "/wt/x", "elsewhere")
	eq(worktree.tilde("/home/u/x", nil), "/home/u/x", "without a home")
	eq(worktree.tilde("/home/u/x", ""), "/home/u/x", "or with an empty one")
end)

-- ---- worktree.open against the git and gh models

-- worktree.open's naming callback for `s`: the scene's folder.
local function naming(s: Scene): (any) -> (string?, string?)
	return function(_meta: any): (string?, string?)
		return s.dir, nil
	end
end

type Opened = { calls: number, result: any, problem: string?, cx: any }

-- Opens the scene's PR from `checkout` (the scene's launch directory by default).
local function openWt(w: World, worktree: Worktree, s: Scene, checkout: string?, waitMs: number?): Opened
	local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
	worktree.open(checkout or s.launch, s.repo, s.number, naming(s), nil, function(result, problem, cx)
		out.calls += 1
		out.result = result
		out.problem = problem
		out.cx = cx
	end)
	w.flush()
	if waitMs then
		w.advance(waitMs)
	end
	return out
end

windowCase("worktree: a first open fetches the PR head into its own ref and reports Created, Current and Clean", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	yes(out.cx ~= nil, "the window cx reaches the callback")
	local r = out.result
	eq(r.path, "/wt/plotroom-o_r-pr-5", "path: a direct child of omp's worktrees directory")
	eq(r.root, "/work/r", "root")
	eq(r.remote, "origin", "remote")
	eq(r.branch, "feature", "branch: the pull request's own head branch")
	eq(r.ref, "refs/plotroom-pr/o/r/pr-5", "ref")
	eq(r.created, true, "created")
	eq(r.head, sha("b"), "head")
	eq(r.prHead, sha("b"), "prHead")
	eq(r.prRef, "feature", "prRef")
	eq(r.dirty, false, "dirty")
	eq(s.git.refs["refs/plotroom-pr/o/r/pr-5"], sha("b"), "the PR head is fetched into refs/plotroom-pr/")
	eq(s.git.refs["refs/heads/feature"], sha("b"), "the branch starts at the PR head")
	eq(s.git.worktrees[2].path, s.target, "the worktree is registered")
	eq(w.fs.mkdirs[1], "/wt", "omp's worktrees directory was created")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b feature " .. s.target .. " " .. sha("b")), 1, "added through omp worktree add")
	local created = worktree.describe(r)
	has(created, "Created", "summary: new")
	has(created, "Current", "summary: at the PR head")
	has(created, "Clean", "summary: no local changes")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/pull/5/head:refs/plotroom-pr/o/r/pr-5"), 1, "one fetch")
	eq(countLog(s.git, "worktree add -b feature " .. s.target .. " " .. sha("b")), 1, "one worktree add")
	lacks(table.concat(s.git.log, "\n"), "refs/plotroom/", "the old, ambiguous namespace is not used")
end)

windowCase("worktree: opening again reuses the worktree: no fetch, nothing changed, status read once", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	eq(openWt(w, worktree, s, nil, nil).result.created, true, "first open creates")
	local before, mark = snapshot(s.git), #s.git.log
	local again = openWt(w, worktree, s, nil, nil)
	eq(again.calls, 1, "done calls")
	eq(again.result.created, false, "created")
	eq(again.result.path, s.target, "path")
	eq(again.result.head, sha("b"), "head")
	eq(again.result.dirty, false, "dirty")
	eq(snapshot(s.git), before, "git state is untouched")
	eq(countLog(s.git, "fetch", mark), 0, "no fetch")
	eq(countLog(s.git, "worktree add", mark), 0, "no add")
	eq(countLog(s.git, "status --porcelain=v2 --branch --untracked-files=normal", mark), 1, "status is read once")
end)

windowCase("worktree: after the PR advanced a reused worktree stays where it is and says so", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	openWt(w, worktree, s, nil, nil)
	s.gh.meta["o/r#5"].sha = sha("c")
	s.git.served["refs/pull/5/head"] = sha("c")
	local before, mark = snapshot(s.git), #s.git.log
	local again = openWt(w, worktree, s, nil, nil)
	eq(again.result.created, false, "created")
	eq(again.result.head, sha("b"), "the worktree keeps its commit")
	eq(again.result.prHead, sha("c"), "the PR head is the new one")
	eq(snapshot(s.git), before, "no ref, branch or worktree moved")
	eq(countLog(s.git, "fetch", mark), 0, "no fetch on reuse")
	same(worktree.update(again.result), { "git -C " .. s.target .. " pull --ff-only" }, "the update command is offered, not run")
	local advanced = worktree.describe(again.result)
	has(advanced, "Different", "summary")
	has(advanced, "bbbbbbb", "names the local head")
	has(advanced, "ccccccc", "names the PR head")
end)

windowCase("worktree: a modified worktree is reported modified and kept exactly as it is", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	openWt(w, worktree, s, nil, nil)
	s.git.dirty[s.target] = " M src/a.lua\n?? notes.txt\n"
	s.gh.meta["o/r#5"].sha = sha("c")
	local before = snapshot(s.git)
	local again = openWt(w, worktree, s, nil, nil)
	eq(again.result.dirty, true, "dirty")
	eq(snapshot(s.git), before, "the changes and every ref are untouched")
	has(worktree.describe(again.result), "Modified", "summary")
end)

windowCase("worktree: a post-checkout hook's changes in a fresh worktree are reported, never a false Clean", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.afterAdd = function(path: string)
		s.git.dirty[path] = "?? generated.txt\n"
	end
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.result.created, true, "created")
	eq(out.result.dirty, true, "the hook's change is reported")
	local hooked = worktree.describe(out.result)
	has(hooked, "Created", "summary: new")
	has(hooked, "Current", "summary: at the PR head")
	has(hooked, "Modified", "summary: the hook's change")
	lacks(hooked, "Clean", "never a false Clean")
	local failing = scene(w, worktree, "o", "q", 7)
	failing.git.fail["status"] = { status = 128, stderr = "fatal: unable to read the index\n" }
	local unknown = openWt(w, worktree, failing, nil, nil)
	eq(unknown.result.created, true, "created")
	eq(unknown.result.dirty, nil, "a status that failed is unknown, not clean")
	has(worktree.describe(unknown.result), "unchecked", "summary")
end)

windowCase("worktree: a status that times out leaves dirty unknown instead of failing the open", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	openWt(w, worktree, s, nil, nil)
	s.git.fail["status"] = { delay = 60000 }
	local again = openWt(w, worktree, s, nil, 10000)
	eq(again.calls, 1, "done calls")
	eq(again.result.created, false, "created")
	eq(again.result.dirty, nil, "dirty")
end)

windowCase("worktree: a branch already at the PR head is attached, not recreated", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.refs["refs/heads/feature"] = sha("b")
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.problem, nil, "problem")
	eq(out.result.created, true, "created")
	eq(countLog(s.git, "worktree add " .. s.target .. " feature"), 1, "attached with the two-argument form")
	eq(countLog(s.git, "worktree add -b"), 0, "no new branch")
end)

windowCase("worktree: another window winning the add is accepted as a reuse, never an error", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.onAdd = function()
		s.git.onAdd = nil
		table.insert(s.git.worktrees, { path = s.target, branch = "refs/heads/" .. s.branch, head = sha("b"), locked = false })
		s.git.refs["refs/heads/" .. s.branch] = sha("b")
		w.fs.dirs[s.target] = true
	end
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	eq(out.result.created, false, "created: the other window made it")
	eq(out.result.path, s.target, "path")
	eq(out.result.dirty, false, "dirty")
end)

windowCase("worktree: a fetch that lost the ref lock continues only when the ref holds the PR head", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.lockFetch = { winner = sha("b") }
	local won = openWt(w, worktree, s, nil, nil)
	eq(won.problem, nil, "the other window fetched the same commit")
	eq(won.result.created, true, "created")
	local lost = scene(w, worktree, "o", "q", 6)
	lost.git.lockFetch = { winner = sha("e") }
	local other = openWt(w, worktree, lost, nil, nil)
	eq(other.result, nil, "a different commit in the ref fails")
	has(other.problem, "cannot lock ref", "git's message")
	local empty = scene(w, worktree, "o", "p", 8)
	empty.git.lockFetch = {}
	local none = openWt(w, worktree, empty, nil, nil)
	eq(none.result, nil, "an absent ref fails")
	has(none.problem, "cannot lock ref", "git's message")
end)

windowCase("worktree: a PR that moves during the fetch is accepted only on an exact second read", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.served["refs/pull/5/head"] = sha("c")
	local moved = openWt(w, worktree, s, nil, nil)
	eq(moved.result, nil, "gh still reports the old head")
	has(moved.problem, "changed", "the pull request moved")
	eq(#s.git.worktrees, 1, "nothing was created")
	local t = scene(w, worktree, "o", "q", 6)
	t.git.served["refs/pull/6/head"] = sha("c")
	t.git.onFetch = function()
		t.gh.meta["o/q#6"].sha = sha("c")
	end
	local settled = openWt(w, worktree, t, nil, nil)
	eq(settled.problem, nil, "the second read agrees with the fetched commit")
	eq(settled.result.head, sha("c"), "the worktree is at the commit that was fetched")
	eq(settled.result.prHead, sha("c"), "prHead")
end)

windowCase("worktree: a mkdir that raises ends the open once with its reason and creates nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	w.fs.denyMkdir["/wt"] = "permission denied"
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.result, nil, "no result")
	has(out.problem, "/wt", "names the directory")
	has(out.problem, "permission denied", "and the reason")
	eq(countLog(s.git, "worktree add"), 0, "git was never asked to add it")
	w.fs.denyMkdir["/wt"] = nil
	eq(openWt(w, worktree, s, nil, nil).result.created, true, "after the cause is fixed the next open works")
end)

windowCase("worktree: a filesystem call that raises mid-flow fails the request once", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	w.sdk.fs.exists = function(_path: string): boolean
		error("input/output error", 0)
	end
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.result, nil, "no result")
	has(out.problem, "input/output error", "the reason")
end)

windowCase("worktree: a runtime that reports one process twice still ends the open once", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local meta = s.gh.meta["o/r#5"]
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "pr" then
			return { stdout = jsonEncode(meta), repeatCallback = true }
		end
		return nil
	end
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	yes(out.result ~= nil or out.problem ~= nil, "an outcome")
end)

windowCase("worktree: a checkout of another repository is NO_REPO; the checkout given is the one used", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.remotes.origin = { "https://github.com/x/y.git" }
	local none = openWt(w, worktree, s, nil, nil)
	eq(none.calls, 1, "done calls")
	eq(none.problem, worktree.NO_REPO, "problem")
	eq(none.result, nil, "result")
	local other = newGit(w, "/work/other")
	other.remotes.origin = { "https://github.com/o/r.git" }
	other.served["refs/pull/5/head"] = sha("b")
	local given = openWt(w, worktree, s, "/work/other", nil)
	eq(given.problem, nil, "the given checkout resolves")
	eq(given.result.root, "/work/other", "root")
	eq(given.result.path, "/wt/plotroom-o_r-pr-5", "path")
end)

windowCase("worktree: omp's worktrees directory is OMP_WORKTREE_DIR, then worktree.base, then ~/.omp/wt; relative values are ignored", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.env.HOME = "/home/u"
	local base: string? = nil
	w.respond(function(call: Call): Reply?
		local a = call.argv
		return if a[1] == "omp" and a[2] == "config" then { stdout = jsonEncode({ key = "worktree.base", value = base }) .. "\n" } else nil
	end)
	local function dir(): string?
		local got: string? = nil
		worktree.worktreesDir(function(d: string?)
			got = d
		end)
		w.flush()
		return got
	end
	eq(dir(), "/home/u/.omp/wt", "unset: omp's default")
	base = "~/wts"
	eq(dir(), "/home/u/wts", "the setting, ~ expanded")
	base = "rel/wts"
	eq(dir(), "/home/u/.omp/wt", "a relative setting is ignored")
	base = "/cfg"
	w.env.OMP_WORKTREE_DIR = "/env/wt"
	eq(dir(), "/env/wt", "the environment variable wins")
	w.env.OMP_WORKTREE_DIR = "relative"
	eq(dir(), "/cfg", "a relative environment variable is ignored")
end)

windowCase("worktree: the worktrees directory is a clean path, so git's own listing of it matches", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.env.HOME = "/home/u"
	w.respond(function(call: Call): Reply?
		local a = call.argv
		return if a[1] == "omp" and a[2] == "config" then { stdout = jsonEncode({ key = "worktree.base", value = "/cfg/wts//" }) .. "\n" } else nil
	end)
	local function dir(): string?
		local got: string? = nil
		worktree.worktreesDir(function(d: string?)
			got = d
		end)
		w.flush()
		return got
	end
	eq(dir(), "/cfg/wts", "the setting's trailing slashes are dropped")
	w.env.OMP_WORKTREE_DIR = "/env//wt/"
	eq(dir(), "/env/wt", "so are the environment variable's, and doubled slashes inside")
	w.env.OMP_WORKTREE_DIR = "/"
	eq(dir(), "/", "the root stays the root")
	w.env.OMP_WORKTREE_DIR = "~/wt/"
	eq(dir(), "/home/u/wt", "after ~ expansion too")
end)

-- The commands spawned after entry `from` of the world's calls that can change a repository or add a worktree, in order,
-- every argument joined by spaces: everything but git's read-only commands (`omp worktree add` included).
local function worktreeWrites(w: World, from: number?): { string }
	local reads: { [string]: boolean } = { ["rev-parse"] = true, remote = true, status = true, ["ls-remote"] = true, ["check-ref-format"] = true, ["merge-base"] = true }
	local out: { string } = {}
	for i = (from or 0) + 1, #w.calls do
		local a = w.calls[i].argv
		local readOnly = reads[a[4] or ""] or (a[4] == "worktree" and a[5] == "list") or (a[4] == "config" and a[6] == "--get-regexp")
		local note = a[4] == "config" and a[5] == "--local" and string.match(a[6] or "", "^branch%..+%.plotroom%a+$") ~= nil
		if not note and ((a[1] == "omp" and a[2] == "worktree") or (a[1] == "git" and a[2] == "-C" and not readOnly)) then
			table.insert(out, table.concat(a, " "))
		end
	end
	return out
end

windowCase("worktree.open: a same-repo PR gets a worktree on its own head branch, tracking it, with the head fetched into its own ref", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	local r = out.result
	eq(r.path, s.target, "path")
	eq(r.branch, "feature", "branch: the PR's head branch, not a plotroom/... name")
	eq(r.ref, s.ref, "ref: where the PR head was fetched")
	eq(r.prRef, "feature", "prRef")
	eq(r.number, 5, "number")
	eq(r.created, true, "created")
	eq(r.head, sha("b"), "head")
	eq(r.prHead, sha("b"), "prHead")
	same(worktreeWrites(w), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/pull/5/head:refs/plotroom-pr/o/r/pr-5",
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/heads/feature:refs/remotes/origin/feature",
		"omp worktree add -q -C /work/r -b feature /wt/plotroom-o_r-pr-5 " .. sha("b"),
		"git -C /work/r config branch.feature.remote origin",
		"git -C /work/r config branch.feature.merge refs/heads/feature",
	}, "the PR head, its branch's remote-tracking ref, the worktree on a new branch at the PR head, then the upstream")
	eq(s.git.config["branch.feature.remote"], "origin", "the upstream's remote")
	eq(s.git.config["branch.feature.merge"], "refs/heads/feature", "and branch, so pull, push and gh pr view work there")
end)

windowCase("worktree.open: the new head branch starts at the PR's commit, wherever the remote's branch is now", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.served["refs/heads/feature"] = sha("c") -- pushed to since GitHub reported the PR head
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.problem, nil, "problem")
	eq(out.result.head, sha("b"), "the worktree is at the PR's head")
	eq(s.git.refs["refs/heads/feature"], sha("b"), "the branch starts there")
	eq(s.git.refs["refs/remotes/origin/feature"], sha("c"), "the remote-tracking ref says where the remote's branch is")
	eq(countLog(s.git, "worktree add -b feature " .. s.target .. " " .. sha("b")), 1, "created at the PR's commit")
end)

windowCase("worktree.open: the tracking fetch and the upstream write are best effort: a gone head branch or a failing git does not fail the open", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.served["refs/heads/feature"] = nil -- merged, and its branch deleted
	local gone = openWt(w, worktree, s, nil, nil)
	eq(gone.calls, 1, "done calls")
	eq(gone.problem, nil, "problem")
	eq(gone.result.created, true, "created")
	eq(gone.result.branch, "feature", "branch")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/feature:refs/remotes/origin/feature"), 1, "the head branch was asked for once")
	eq(s.git.refs["refs/remotes/origin/feature"], nil, "and not found")
	eq(s.git.refs["refs/heads/feature"], sha("b"), "the branch still starts at the PR head")
	eq(s.git.config["branch.feature.remote"], "origin", "and still tracks the remote")
	eq(s.git.config["branch.feature.merge"], "refs/heads/feature", "and the branch")
	-- the second fetch (and no other) fails for a reason of its own
	local t = scene(w, worktree, "o", "q", 6)
	t.git.onFetch = function()
		t.git.onFetch = nil
		t.git.fail["fetch"] = { status = 128, stderr = "fatal: unable to access 'https://github.com/o/q.git/': Could not resolve host: github.com\n" }
	end
	local offline = openWt(w, worktree, t, nil, nil)
	eq(offline.problem, nil, "problem when only the tracking fetch fails")
	eq(offline.result.created, true, "created")
	eq(countLog(t.git, "fetch"), 2, "both fetches were tried")
	eq(t.git.refs["refs/heads/feature"], sha("b"), "the branch exists")
	eq(t.git.config["branch.feature.remote"], "origin", "with its upstream")
	-- a config write that fails leaves the worktree made, without its upstream
	local u = scene(w, worktree, "o", "p", 7)
	u.git.fail["config"] = { status = 255, stderr = "error: could not lock config file .git/config: File exists\n" }
	local untracked = openWt(w, worktree, u, nil, nil)
	eq(untracked.problem, nil, "problem when the upstream cannot be written")
	eq(untracked.result.created, true, "created")
	eq(untracked.result.branch, "feature", "branch")
	eq(untracked.result.head, sha("b"), "head")
	eq(countLog(u.git, "config"), 3, "the notes were read, then both settings were tried")
	same(u.git.config, {}, "and none was written")
end)

windowCase("worktree.open: the repository's own remote, whatever its name, is fetched from and tracked", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.remotes = { origin = { "https://github.com/me/r.git" }, upstream = { "https://github.com/o/r.git" } }
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.problem, nil, "problem")
	eq(out.result.remote, "upstream", "remote")
	same(worktreeWrites(w), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head upstream +refs/pull/5/head:refs/plotroom-pr/o/r/pr-5",
		"git -C /work/r fetch --no-tags --no-write-fetch-head upstream +refs/heads/feature:refs/remotes/upstream/feature",
		"omp worktree add -q -C /work/r -b feature /wt/plotroom-o_r-pr-5 " .. sha("b"),
		"git -C /work/r config branch.feature.remote upstream",
		"git -C /work/r config branch.feature.merge refs/heads/feature",
	}, "every command names upstream, the remote that points at o/r")
end)

windowCase("worktree.open: a fork PR is on <fork owner>/<branch>, never fetched from origin, tracking the fork's branch by its URL", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local meta = s.gh.meta["o/r#5"]
	meta.headRepo, meta.headOwner = "fork/r", "fork"
	s.git.served["refs/heads/feature"] = sha("c") -- origin has an unrelated branch of that name
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	local r = out.result
	eq(r.branch, "fork/feature", "branch: the fork's owner and the head branch")
	eq(r.prRef, "feature", "prRef: the head branch as GitHub names it")
	eq(r.ref, s.ref, "ref")
	eq(r.head, sha("b"), "head")
	eq(r.title, "Add a feature", "title")
	eq(r.author, "ann", "author")
	eq(r.prBase, "main", "prBase")
	same(worktreeWrites(w), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/pull/5/head:refs/plotroom-pr/o/r/pr-5",
		"omp worktree add -q -C /work/r -b fork/feature /wt/plotroom-o_r-pr-5 " .. sha("b"),
		"git -C /work/r config branch.fork/feature.remote https://github.com/fork/r.git",
		"git -C /work/r config branch.fork/feature.merge refs/heads/feature",
	}, "one fetch, from origin: the fork's branch is not fetched, and the upstream is the fork's URL")
	same(s.git.config, {
		["branch.fork/feature.remote"] = "https://github.com/fork/r.git",
		["branch.fork/feature.merge"] = "refs/heads/feature",
	}, "the upstream is the fork's branch and nothing else is configured")
	-- a fork's main is its own branch, so the repository's main never meets it
	local t = scene(w, worktree, "o", "q", 6)
	local tm = t.gh.meta["o/q#6"]
	tm.headRepo, tm.headOwner, tm.ref = "other/q", "other", "main"
	local forked = openWt(w, worktree, t, nil, nil)
	eq(forked.problem, nil, "problem for a fork's main")
	eq(forked.result.branch, "other/main", "branch")
	eq(t.git.refs["refs/heads/other/main"], sha("b"), "the fork's main starts at the PR head")
	eq(t.git.refs["refs/heads/main"], sha("1"), "the repository's own main did not move")
	eq(t.git.worktrees[1].branch, "refs/heads/main", "and its checkout is still on it")
	eq(t.git.config["branch.other/main.merge"], "refs/heads/main", "the fork's branch is tracked as main")
	eq(t.git.config["branch.main.merge"], nil, "the repository's main was not configured")
end)

windowCase("worktree.open: a PR whose fork was deleted is on <head owner or author>/<branch> and tracks the PR's own ref", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local meta = s.gh.meta["o/r#5"]
	meta.headRepo, meta.headOwner = nil, "gone"
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.problem, nil, "problem")
	eq(out.result.branch, "gone/feature", "branch: the head's user, who is still named")
	same(worktreeWrites(w), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/pull/5/head:refs/plotroom-pr/o/r/pr-5",
		"omp worktree add -q -C /work/r -b gone/feature /wt/plotroom-o_r-pr-5 " .. sha("b"),
		"git -C /work/r config branch.gone/feature.remote origin",
		"git -C /work/r config branch.gone/feature.merge refs/pull/5/head",
	}, "only the PR's ref is fetched; the branch tracks it on origin, the head branch having gone with the fork")
	-- no head user either: the author's name
	local t = scene(w, worktree, "o", "q", 6)
	local tm = t.gh.meta["o/q#6"]
	tm.headRepo, tm.headOwner = nil, nil
	local nameless = openWt(w, worktree, t, nil, nil)
	eq(nameless.problem, nil, "problem without a head user")
	eq(nameless.result.branch, "ann/feature", "branch: the author's name")
	eq(t.git.config["branch.ann/feature.merge"], "refs/pull/6/head", "tracking the PR's ref")
	eq(countLog(t.git, "fetch"), 1, "one fetch")
end)

windowCase("worktree.open: a head repository that is the base repository in other letter case is not a fork", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.gh.meta["o/r#5"].headRepo = "O/R"
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.problem, nil, "problem")
	eq(out.result.branch, "feature", "branch: no fork prefix")
	eq(countLog(s.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/feature:refs/remotes/origin/feature"), 1, "its head branch is fetched from the repository's remote")
	eq(s.git.config["branch.feature.remote"], "origin", "and tracked there")
	eq(s.git.config["branch.feature.merge"], "refs/heads/feature", "as its own branch")
end)

windowCase("worktree.open: an existing local branch is attached at its own commit, never moved, and its upstream settings stay the user's", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.refs["refs/heads/feature"] = sha("d")
	s.git.config["branch.feature.remote"] = "mine"
	s.git.config["branch.feature.merge"] = "refs/heads/elsewhere"
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	local r = out.result
	eq(r.created, true, "created")
	eq(r.branch, "feature", "branch")
	eq(r.head, sha("d"), "head: the branch's own commit")
	eq(r.prHead, sha("b"), "prHead: the PR's")
	has(worktree.describe(r), "Different", "the summary says the worktree is not at the PR head")
	same(worktreeWrites(w), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/pull/5/head:refs/plotroom-pr/o/r/pr-5",
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/heads/feature:refs/remotes/origin/feature",
		"omp worktree add -q -C /work/r /wt/plotroom-o_r-pr-5 feature",
	}, "attached with the two-argument form: no new branch and no upstream written")
	same({ tip = s.git.refs["refs/heads/feature"], config = s.git.config }, {
		tip = sha("d"),
		config = { ["branch.feature.remote"] = "mine", ["branch.feature.merge"] = "refs/heads/elsewhere" },
	}, "the branch did not move and its upstream settings are untouched")
end)

windowCase("worktree.open: a local branch already at the PR head is attached, not recreated, a fork's branch included", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	s.git.refs["refs/heads/feature"] = sha("b")
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.problem, nil, "problem")
	eq(out.result.created, true, "created")
	eq(out.result.head, sha("b"), "head")
	same(worktreeWrites(w), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/pull/5/head:refs/plotroom-pr/o/r/pr-5",
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/heads/feature:refs/remotes/origin/feature",
		"omp worktree add -q -C /work/r /wt/plotroom-o_r-pr-5 feature",
	}, "attached by name, no -b")
	same(s.git.config, {}, "no upstream is written for a branch that was already there")
	local t = scene(w, worktree, "o", "q", 6)
	local tm = t.gh.meta["o/q#6"]
	tm.headRepo, tm.headOwner = "fork/q", "fork"
	t.git.refs["refs/heads/fork/feature"] = sha("b")
	local mark = #w.calls
	local forked = openWt(w, worktree, t, nil, nil)
	eq(forked.problem, nil, "problem for a fork's branch")
	eq(forked.result.branch, "fork/feature", "branch")
	same(worktreeWrites(w, mark), {
		"git -C /work/q fetch --no-tags --no-write-fetch-head origin +refs/pull/6/head:refs/plotroom-pr/o/q/pr-6",
		"omp worktree add -q -C /work/q /wt/plotroom-o_q-pr-6 fork/feature",
	}, "attached by name, nothing configured")
	same(t.git.config, {}, "no upstream for the fork's branch either")
end)

windowCase("worktree.open: the worktree that already holds the PR's branch is reused wherever it is, with nothing fetched, added or configured", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	table.insert(s.git.worktrees, { path = "/wt/elsewhere", branch = "refs/heads/feature", head = sha("d"), locked = false })
	s.git.refs["refs/heads/feature"] = sha("d")
	s.git.dirty["/wt/elsewhere"] = " M src/a.lua\n"
	w.fs.dirs["/wt/elsewhere"] = true
	local before = snapshot(s.git)
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	local r = out.result
	eq(r.created, false, "created")
	eq(r.path, "/wt/elsewhere", "path: the worktree that has the branch, not the folder the naming gave")
	eq(r.branch, "feature", "branch")
	eq(r.head, sha("d"), "head: its own commit")
	eq(r.prHead, sha("b"), "prHead")
	eq(r.dirty, true, "dirty: its changes are reported")
	same(worktreeWrites(w), {}, "nothing was fetched, added or configured")
	eq(snapshot(s.git), before, "git state is untouched")
	eq(#w.fs.mkdirs, 0, "no directory was made")
end)

windowCase("worktree.open: a branch noted for another pull request is refused, naming both, and nothing is reused or moved", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	table.insert(s.git.worktrees, { path = "/wt/elsewhere", branch = "refs/heads/feature", head = sha("d"), locked = false })
	s.git.refs["refs/heads/feature"] = sha("d")
	w.fs.dirs["/wt/elsewhere"] = true
	s.git.notes["branch.feature.plotroompr"] = "9"
	s.git.notes["branch.feature.plotroomrepo"] = "o/r"
	local before = snapshot(s.git)
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.result, nil, "no result")
	has(out.problem, "o/r#9", "names the PR that holds the branch")
	has(out.problem, "o/r#5", "and the one refused")
	same(worktreeWrites(w), {}, "nothing fetched, added or configured")
	eq(snapshot(s.git), before, "git state is untouched")
	-- the same PR (a note without a repository counts as this one) is reused as before
	s.git.notes["branch.feature.plotroompr"] = "5"
	s.git.notes["branch.feature.plotroomrepo"] = nil
	local again = openWt(w, worktree, s, nil, nil)
	eq(again.problem, nil, "the PR's own note does not collide")
	eq(again.result.path, "/wt/elsewhere", "and its worktree is reused")
end)

windowCase("worktree.open: a plain folder at the PR's folder, or a locked or missing worktree there or of its branch, ends the open, touching nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local function refused(what: string): string?
		local before = snapshot(s.git)
		local out = openWt(w, worktree, s, nil, nil)
		eq(out.calls, 1, what .. ": done calls")
		eq(out.result, nil, what .. ": no result")
		eq(snapshot(s.git), before, what .. ": git state is untouched")
		same(worktreeWrites(w), {}, what .. ": nothing fetched or added")
		eq(#w.fs.mkdirs, 0, what .. ": no directory made")
		return out.problem
	end
	w.fs.dirs[s.target] = true
	eq(refused("a plain folder"), s.target .. " already exists and is not the worktree of feature; move it away or remove it.", "a folder that is no worktree")
	table.insert(s.git.worktrees, { path = s.target, branch = "refs/heads/other", head = sha("d"), locked = true })
	eq(refused("a locked worktree of another branch at the folder"), "The worktree record at " .. s.target .. " belongs to something other than feature.", "one that cannot be used is neither reused nor replaced")
	s.git.worktrees[2].locked = false
	w.fs.dirs[s.target] = nil
	eq(refused("a worktree of another branch at the folder whose folder is gone"), "The worktree record at " .. s.target .. " belongs to something other than feature.", "nor is one with no folder")
	table.remove(s.git.worktrees, 2)
	table.insert(s.git.worktrees, { path = "/wt/locked", branch = "refs/heads/feature", head = sha("d"), locked = true })
	w.fs.dirs["/wt/locked"] = true
	local locked = refused("a locked worktree")
	has(locked, "The worktree of feature at /wt/locked is locked, prunable or missing", "the branch's worktree is locked")
	table.remove(s.git.worktrees, 2)
	table.insert(s.git.worktrees, { path = "/wt/gone", branch = "refs/heads/feature", head = sha("d"), locked = false })
	has(refused("a worktree whose folder is gone"), "The worktree of feature at /wt/gone is locked, prunable or missing", "the branch's worktree has no folder")
end)

windowCase("worktree.open: a worktree already in the PR's folder is its worktree whatever its branch (an earlier version's), reused with nothing fetched, added or configured", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	table.insert(s.git.worktrees, { path = s.target, branch = "refs/heads/plotroom/o/r/pr-5", head = sha("d"), locked = false })
	s.git.refs["refs/heads/plotroom/o/r/pr-5"] = sha("d")
	s.git.dirty[s.target] = " M src/a.lua\n"
	w.fs.dirs[s.target] = true
	local before = snapshot(s.git)
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	local r = out.result
	eq(r.created, false, "created")
	eq(r.path, s.target, "path: the folder the naming gave")
	eq(r.branch, "plotroom/o/r/pr-5", "branch: the one the worktree is on, not the PR's head branch")
	eq(r.ref, s.ref, "ref: the PR's own, as always")
	eq(r.head, sha("d"), "head: its own commit")
	eq(r.prHead, sha("b"), "prHead")
	eq(r.dirty, true, "dirty: its changes are reported")
	same(worktreeWrites(w), {}, "nothing was fetched, added or configured")
	eq(snapshot(s.git), before, "git state is untouched")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	local again = openWt(w, worktree, s, nil, nil)
	eq(again.result.branch, "plotroom/o/r/pr-5", "opened again, it is the same worktree")
	eq(again.result.created, false, "created")
end)

windowCase("worktree.open: the folder comes from the naming callback, which is given the PR; a later name still finds the PR's worktree", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local meta = s.gh.meta["o/r#5"]
	meta.headRepo, meta.headOwner = "fork/r", "fork"
	local seen: { any } = {}
	local dir = "my-pr-5"
	local function open(): Opened
		local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
		worktree.open(s.launch, s.repo, s.number, function(m: any): (string?, string?)
			table.insert(seen, m)
			return dir, nil
		end, nil, function(result, problem, cx)
			out.calls += 1
			out.result, out.problem, out.cx = result, problem, cx
		end)
		w.flush()
		return out
	end
	local out = open()
	eq(out.problem, nil, "problem")
	eq(out.result.path, "/wt/my-pr-5", "path: the name the callback gave")
	eq(out.result.branch, "fork/feature", "branch: it does not depend on the folder")
	eq(#seen, 1, "the callback ran once")
	local given: any = seen[1]
	eq(given.title, "Add a feature", "the callback was given the PR's title")
	eq(given.ref, "feature", "head branch")
	eq(given.fork, "fork", "fork owner")
	eq(given.forkRepo, "fork/r", "fork repository")
	eq(given.author, "ann", "author")
	eq(given.baseRef, "main", "base branch")
	eq(given.sha, sha("b"), "head commit")
	dir = "renamed-5" -- the user edits the format
	local mark = #w.calls
	local again = open()
	eq(again.problem, nil, "problem on the second open")
	eq(again.result.created, false, "created")
	eq(again.result.path, "/wt/my-pr-5", "the worktree that has the branch is still the PR's")
	same(worktreeWrites(w, mark), {}, "no second worktree, nothing fetched")
	eq(#seen, 2, "the callback is asked every time")
end)

windowCase("worktree.open: a naming callback that gives no name ends the open with its reason, creating nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local before = snapshot(s.git)
	local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
	worktree.open(s.launch, s.repo, s.number, function(_m: any): (string?, string?)
		return nil, "The folder format names {github.user}, which could not be read."
	end, nil, function(result, problem, cx)
		out.calls += 1
		out.result, out.problem, out.cx = result, problem, cx
	end)
	w.flush()
	eq(out.calls, 1, "done calls")
	eq(out.result, nil, "no result")
	eq(out.problem, "The folder format names {github.user}, which could not be read.", "problem: the callback's reason, as it gave it")
	eq(snapshot(s.git), before, "git state is untouched")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	same(worktreeWrites(w), {}, "nothing fetched or added")
end)

windowCase("worktree.open: a folder name that is not one plain path segment is refused, creating nothing; a name with a space works", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local before = snapshot(s.git)
	local bad: { { string } } = {
		{ "a slash", "pr/5" },
		{ "a path out of the folder", "../pr-5" },
		{ "an absolute path", "/tmp/pr-5" },
		{ "an empty name", "" },
		{ "a dot", "." },
		{ "two dots", ".." },
		{ "a newline", "pr\n5" },
		{ "an escape sequence", "pr-5\27[31m" },
		{ "201 bytes", string.rep("a", 201) },
	}
	for _, row in bad do
		s.dir = row[2]
		local out = openWt(w, worktree, s, nil, nil)
		eq(out.calls, 1, row[1] .. ": done calls")
		eq(out.result, nil, row[1] .. ": no result")
		has(out.problem, "Worktree folder name " .. row[2] .. " is not usable", row[1] .. ": names the folder name")
		has(out.problem, "Settings", row[1] .. ": says where to change it")
	end
	eq(snapshot(s.git), before, "git state is untouched")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	same(worktreeWrites(w), {}, "nothing fetched or added")
	s.dir = "my pr 5"
	local ok = openWt(w, worktree, s, nil, nil)
	eq(ok.problem, nil, "problem for a name with spaces")
	eq(ok.result.path, "/wt/my pr 5", "path")
	local added: any = nil
	for _, call in w.calls do
		if call.argv[1] == "omp" and call.argv[3] == "add" then
			added = call.argv
		end
	end
	same(added, { "omp", "worktree", "add", "-q", "-C", "/work/r", "-b", "feature", "/wt/my pr 5", sha("b") }, "the folder is one argument, never a shell word")
end)

windowCase("worktree.open: a PR whose base is another repository is refused, creating nothing; one in other letter case is accepted", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local before = snapshot(s.git)
	s.gh.meta["o/r#5"].base = "x/y"
	local out = openWt(w, worktree, s, nil, nil)
	eq(out.calls, 1, "done calls")
	eq(out.result, nil, "no result")
	eq(out.problem, "The pull request's base is x/y, not o/r.", "problem")
	eq(snapshot(s.git), before, "git state is untouched")
	same(worktreeWrites(w), {}, "nothing fetched or added")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	s.gh.meta["o/r#5"].base = "O/R"
	local cased = openWt(w, worktree, s, nil, nil)
	eq(cased.problem, nil, "problem when the base differs only in letter case")
	eq(cased.result.created, true, "created")
end)

windowCase("worktree.open: a PR that cannot be read ends the open with gh's problem, creating nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s = scene(w, worktree, "o", "r", 5)
	local before = snapshot(s.git)
	local function refused(what: string, reply: Reply, want: string)
		s.gh.override = function(req: GhReq): Reply?
			return if req.kind == "pr" then reply else nil
		end
		local out = openWt(w, worktree, s, nil, nil)
		eq(out.calls, 1, what .. ": done calls")
		eq(out.result, nil, what .. ": no result")
		has(out.problem, want, what .. ": gh's problem")
	end
	refused("a PR GitHub does not show", { status = 1, stderr = "gh: Not Found (HTTP 404)\n" }, "gh: Not Found (HTTP 404)")
	refused("a sign-in gh rejects", { status = 1, stderr = "gh: Bad credentials (HTTP 401)\n" }, "gh: Bad credentials (HTTP 401)")
	refused("an answer that is no PR", { stdout = "not json" }, "unexpected pull request metadata")
	eq(snapshot(s.git), before, "git state is untouched")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	same(worktreeWrites(w), {}, "nothing fetched or added")
end)

-- ---- worktree.remove against the git model

type Removed = { removal: any, problem: string?, dirty: boolean?, calls: number }

-- Removes the worktree `t` names (a worktree.Target) and returns the one answer remove gave.
local function removeWt(w: World, worktree: Worktree, t: { [string]: any }): Removed
	local out: Removed = { removal = nil, problem = nil, dirty = nil, calls = 0 }
	worktree.remove(t :: any, function(removal, problem, dirty)
		out.calls += 1
		out.removal = removal
		out.problem = problem
		out.dirty = dirty
	end)
	w.flush()
	return out
end

-- PR 5 of o/r with its worktree made, and what remove takes of it.
local function madeWt(w: World, worktree: Worktree): (Scene, { [string]: any })
	local s = scene(w, worktree, "o", "r", 5)
	local r = openWt(w, worktree, s).result
	return s, { root = r.root, path = r.path, branch = r.branch, ref = r.ref }
end

case("worktree: remove takes a clean pull request worktree, its branch once the fetched ref holds all of it, and that ref", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s, t = madeWt(w, worktree)
	local mark = #w.calls
	local out = removeWt(w, worktree, t)
	eq(out.calls, 1, "answered once")
	eq(out.problem, nil, "no problem")
	eq(out.removal.branch, "Branch feature was deleted too.", "the branch went with it")
	same(ranSince(w, mark), {
		"git -C /work/r worktree remove /wt/plotroom-o_r-pr-5",
		"git -C /work/r merge-base --is-ancestor refs/heads/feature refs/plotroom-pr/o/r/pr-5",
		"git -C /work/r branch -D feature",
		"git -C /work/r update-ref -d refs/plotroom-pr/o/r/pr-5",
	}, "the worktree without --force, then -D only after the ancestry check, then the ref")
	eq(#s.git.worktrees, 1, "only the main worktree is left")
	eq(s.git.refs["refs/heads/feature"], nil, "the branch is gone")
	eq(s.git.refs["refs/plotroom-pr/o/r/pr-5"], nil, "and the ref it was fetched into")
	eq(w.fs.dirs["/wt/plotroom-o_r-pr-5"], nil, "and the folder")
end)

case("worktree: remove keeps a pull request branch that holds commits of its own, with its ref, and says why", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s, t = madeWt(w, worktree)
	s.git.ahead["feature"] = true
	s.git.unmerged["feature"] = true
	local mark = #w.calls
	local out = removeWt(w, worktree, t)
	eq(out.problem, nil, "the worktree itself was removed")
	eq(out.removal.branch, "Branch feature was kept. The branch 'feature' is not fully merged.", "the branch stays, with git's reason")
	same(ranSince(w, mark), {
		"git -C /work/r worktree remove /wt/plotroom-o_r-pr-5",
		"git -C /work/r merge-base --is-ancestor refs/heads/feature refs/plotroom-pr/o/r/pr-5",
		"git -C /work/r branch -d feature",
	}, "-d, never -D, and the ref is not dropped")
	eq(#s.git.worktrees, 1, "the worktree is gone")
	eq(s.git.refs["refs/heads/feature"], sha("b"), "the branch keeps its commits")
	eq(s.git.refs["refs/plotroom-pr/o/r/pr-5"], sha("b"), "beside the ref")
end)

case("worktree: remove deletes a pull request branch that is ahead of its ref when git finds it merged, and the ref with it", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s, t = madeWt(w, worktree)
	s.git.ahead["feature"] = true -- merged into the checkout's HEAD: `unmerged` stays unset
	local mark = #w.calls
	local out = removeWt(w, worktree, t)
	eq(out.removal.branch, "Branch feature was deleted too.", "the branch goes")
	same(ranSince(w, mark), {
		"git -C /work/r worktree remove /wt/plotroom-o_r-pr-5",
		"git -C /work/r merge-base --is-ancestor refs/heads/feature refs/plotroom-pr/o/r/pr-5",
		"git -C /work/r branch -d feature",
		"git -C /work/r update-ref -d refs/plotroom-pr/o/r/pr-5",
	}, "through -d, which git allows, and then the ref")
	eq(s.git.refs["refs/plotroom-pr/o/r/pr-5"], nil, "the ref is gone")
end)

case("worktree: remove keeps unpushed commits of a pull request branch even when a tag has the branch's name", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s, t = madeWt(w, worktree)
	s.git.refs["refs/tags/feature"] = s.git.refs["refs/plotroom-pr/o/r/pr-5"] -- the tag sits at the fetched head
	s.git.ahead["feature"] = true -- the branch has moved on
	s.git.unmerged["feature"] = true
	local out = removeWt(w, worktree, t)
	eq(out.problem, nil, "the worktree itself was removed")
	eq(out.removal.branch, "Branch feature was kept. The branch 'feature' is not fully merged.", "the branch stays")
	eq(s.git.refs["refs/heads/feature"], sha("b"), "its commits are not lost")
end)

case("worktree: remove reads uncommitted changes from git whatever language git speaks", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s, t = madeWt(w, worktree)
	s.git.dirty["/wt/plotroom-o_r-pr-5"] = " M src/a.lua\n"
	local out = removeWt(w, worktree, t)
	eq(out.dirty, true, "dirty")
	has(out.problem, "uncommitted changes", "said plainly")
	eq(#s.git.worktrees, 2, "nothing was removed")
end)

case("worktree: remove stops at uncommitted changes, which git refuses to discard, and does nothing else", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s, t = madeWt(w, worktree)
	s.git.dirty["/wt/plotroom-o_r-pr-5"] = " M src/a.lua\n"
	local before = snapshot(s.git)
	local mark = #w.calls
	local out = removeWt(w, worktree, t)
	eq(out.calls, 1, "answered once")
	eq(out.removal, nil, "nothing was removed")
	eq(out.problem, "It has uncommitted changes; commit, stash or remove it yourself.", "the user is told what to do")
	eq(out.dirty, true, "and that the changes were why")
	same(ranSince(w, mark), { "git -C /work/r worktree remove /wt/plotroom-o_r-pr-5" }, "git was asked once, without --force")
	eq(snapshot(s.git), before, "no worktree, branch or ref changed")
end)

case("worktree: remove relays any other refusal of git, and says when a ref could not be dropped", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local s, t = madeWt(w, worktree)
	s.git.fail["worktree remove"] = { status = 128, stderr = "fatal: cannot remove a locked working tree, lock reason: moving\nuse 'remove -f -f' to override or unlock first\n" }
	local before = snapshot(s.git)
	local locked = removeWt(w, worktree, t)
	eq(locked.removal, nil, "nothing was removed")
	eq(locked.problem, "Cannot remove a locked working tree, lock reason: moving.", "git's first line, as a sentence")
	eq(locked.dirty, false, "which is not about changes")
	eq(snapshot(s.git), before, "nothing changed")
	s.git.fail["worktree remove"] = nil
	s.git.fail["update-ref"] = { status = 1, stderr = "error: cannot lock ref 'refs/plotroom-pr/o/r/pr-5'\n" }
	local out = removeWt(w, worktree, t)
	eq(out.removal.branch, "Branch feature was deleted too. Its fetched ref refs/plotroom-pr/o/r/pr-5 was kept. Cannot lock ref 'refs/plotroom-pr/o/r/pr-5'.", "a ref that stays is reported")
end)

-- ---- worktree.openIssue against the git model

type IssueRepo = { git: Git, target: string, launch: string }

-- A checkout of o/r at /work/r (launched from its src directory) whose origin is github.com/o/r and whose remote serves
-- its default branch main at sha("b"); `target` is where issue `ref`'s worktree goes (folder plotroom-o_r-issue-<ref>).
local function issueRepo(w: World, ref: string): IssueRepo
	local g = newGit(w, "/work/r")
	g.remotes.origin = { "https://github.com/o/r.git" }
	g.served["refs/heads/main"] = sha("b")
	g.defaultBranch = "main"
	w.fs.dirs["/work/r/src"] = true
	return { git = g, target = "/wt/plotroom-o_r-issue-" .. ref, launch = "/work/r/src" }
end

-- What an issue worktree is asked for (worktree.IssuePlan); the folder defaults to plotroom-o_r-issue-<key>.
type PlanAsk = { dir: string?, branch: string, pr: number?, fresh: boolean, base: string? }

-- Opens issue `key` of o/r as `plan` says, from `checkout` (the repository's src directory by default).
local function openIssuePlan(w: World, worktree: Worktree, r: IssueRepo, key: string, plan: PlanAsk, checkout: string?): Opened
	local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
	local asked = { dir = plan.dir or "plotroom-o_r-issue-" .. key, branch = plan.branch, pr = plan.pr, fresh = plan.fresh, base = plan.base }
	worktree.openIssue(checkout or r.launch, "o/r", key, asked, nil, function(result, problem, cx)
		out.calls += 1
		out.result = result
		out.problem = problem
		out.cx = cx
	end)
	w.flush()
	return out
end

-- Opens issue `key` of o/r on the new branch `branch`, made from the remote's main.
local function openIssueWt(w: World, worktree: Worktree, r: IssueRepo, key: string, branch: string, checkout: string?): Opened
	return openIssuePlan(w, worktree, r, key, { branch = branch, fresh = true, base = "main" }, checkout)
end

windowCase("worktree.openIssue: creates the issue's branch at the chosen base and reports Created and Clean", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local out = openIssueWt(w, worktree, r, "12", "12-fix-login", nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	yes(out.cx ~= nil, "the window cx reaches the callback")
	local res = out.result
	eq(res.path, r.target, "path: a direct child of omp's worktrees directory")
	eq(res.root, "/work/r", "root")
	eq(res.remote, "origin", "remote")
	eq(res.branch, "12-fix-login", "branch")
	eq(res.key, "12", "key")
	eq(res.created, true, "created")
	eq(res.head, sha("b"), "head: the remote's default branch")
	eq(res.dirty, false, "dirty")
	eq(w.fs.mkdirs[1], "/wt", "omp's worktrees directory was created")
	eq(countLog(r.git, "check-ref-format --branch 12-fix-login"), 1, "git checks the branch name first")
	eq(countLog(r.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/main:refs/remotes/origin/main"), 1, "the base is fetched into its remote-tracking ref")
	eq(r.git.refs["refs/remotes/origin/main"], sha("b"), "which holds the remote's commit")
	eq(r.git.refs["refs/heads/12-fix-login"], sha("b"), "the new branch starts there")
	eq(countCalls(w, "omp worktree add -q -C /work/r -b 12-fix-login " .. r.target .. " " .. sha("b")), 1, "added through omp worktree add")
	eq(r.git.worktrees[2].path, r.target, "the worktree is registered")
	eq(countLog(r.git, "config"), 0, "no upstream is configured: the user's first push -u sets it")
end)

windowCase("worktree.openIssue: a worktree at the issue's directory is reused whatever its branch, so is one that holds the branch elsewhere; a locked or missing one is an error", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	-- the issue's directory holds another branch
	table.insert(r.git.worktrees, { path = r.target, branch = "refs/heads/work-in-progress", head = sha("d"), locked = false })
	w.fs.dirs[r.target] = true
	local before = snapshot(r.git)
	local out = openIssueWt(w, worktree, r, "12", "12-fix-login", nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	eq(out.result.created, false, "created")
	eq(out.result.path, r.target, "path")
	eq(out.result.branch, "work-in-progress", "the branch is the worktree's own, not the one asked for")
	eq(out.result.head, sha("d"), "head")
	eq(out.result.dirty, false, "dirty")
	eq(snapshot(r.git), before, "git state is untouched")
	eq(countLog(r.git, "fetch"), 0, "no fetch")
	eq(countLog(r.git, "worktree add"), 0, "no add")
	-- the directory holds a detached HEAD
	table.insert(r.git.worktrees, { path = "/wt/plotroom-o_r-issue-13", head = sha("e"), locked = false })
	w.fs.dirs["/wt/plotroom-o_r-issue-13"] = true
	local detached = openIssueWt(w, worktree, r, "13", "13-docs", nil)
	eq(detached.result.created, false, "a detached worktree is reused too")
	eq(detached.result.branch, "13-docs", "and reported on the branch asked for")
	eq(detached.result.head, sha("e"), "at its own commit")
	-- another worktree holds the branch
	table.insert(r.git.worktrees, { path = "/wt/elsewhere", branch = "refs/heads/14-typo", head = sha("f"), locked = false })
	w.fs.dirs["/wt/elsewhere"] = true
	local elsewhere = openIssueWt(w, worktree, r, "14", "14-typo", nil)
	eq(elsewhere.result.created, false, "the worktree that has the branch is reused")
	eq(elsewhere.result.path, "/wt/elsewhere", "wherever it is")
	eq(elsewhere.result.branch, "14-typo", "branch")
	eq(countLog(r.git, "worktree add"), 0, "still no add")
	-- a locked worktree, and one whose directory is gone
	table.insert(r.git.worktrees, { path = "/wt/plotroom-o_r-issue-15", branch = "refs/heads/15-x", head = sha("a"), locked = true })
	w.fs.dirs["/wt/plotroom-o_r-issue-15"] = true
	local locked = openIssueWt(w, worktree, r, "15", "15-x", nil)
	eq(locked.result, nil, "a locked worktree is left alone")
	has(locked.problem, "locked, prunable or missing", "and the problem says what to look at")
	table.insert(r.git.worktrees, { path = "/wt/plotroom-o_r-issue-16", branch = "refs/heads/16-y", head = sha("c"), locked = false })
	local gone = openIssueWt(w, worktree, r, "16", "16-y", nil)
	eq(gone.result, nil, "so is one whose directory is gone")
	has(gone.problem, "locked, prunable or missing", "with the same problem")
	eq(countLog(r.git, "worktree add"), 0, "nothing was added")
end)

windowCase("worktree.openIssue: attaches an existing local branch without moving it", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	r.git.refs["refs/heads/12-fix-login"] = sha("d")
	local out = openIssueWt(w, worktree, r, "12", "12-fix-login", nil)
	eq(out.problem, nil, "problem")
	eq(out.result.created, true, "created")
	eq(out.result.head, sha("d"), "the worktree is at the branch's own commit")
	eq(out.result.branch, "12-fix-login", "branch")
	eq(r.git.refs["refs/heads/12-fix-login"], sha("d"), "the branch did not move")
	eq(countCalls(w, "omp worktree add -q -C /work/r " .. r.target .. " 12-fix-login"), 1, "attached with the two-argument form")
	eq(countLog(r.git, "worktree add -b"), 0, "no new branch")
	eq(countLog(r.git, "fetch"), 0, "and nothing fetched: the default branch is not needed")
end)

windowCase("worktree.openIssue: a branch name git rejects ends the request with the way to fix the format, and creates nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	r.git.fail["check-ref-format"] = { status = 1 }
	local before = snapshot(r.git)
	local out = openIssueWt(w, worktree, r, "12", "12-fix-login", nil)
	eq(out.calls, 1, "done calls")
	eq(out.result, nil, "no result")
	eq(out.problem, "Branch name 12-fix-login is not valid; change the branch format in Settings › Repositories.", "problem")
	eq(snapshot(r.git), before, "git state is untouched")
	eq(countLog(r.git, "fetch"), 0, "nothing was fetched")
	eq(countLog(r.git, "worktree add"), 0, "and nothing added")
end)

windowCase("worktree.openIssue: a repository, key or branch it cannot use ends the request without touching git; another repository's checkout is NO_REPO", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local function refused(what: string, repo: string, key: string, branch: string, want: string)
		local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
		worktree.openIssue(r.launch, repo, key, { dir = "plotroom-o_r-issue-" .. key, branch = branch, fresh = true, base = "main" }, nil, function(result, problem, cx)
			out.calls += 1
			out.result, out.problem, out.cx = result, problem, cx
		end)
		eq(out.calls, 0, what .. ": never synchronous")
		w.flush()
		eq(out.calls, 1, what .. ": done calls")
		eq(out.result, nil, what .. ": no result")
		has(out.problem, want, what .. ": the reason")
	end
	refused("a repository that is no owner/name", "o", "12", "12-x", "Invalid repository")
	refused("a dot-dot owner", "../r", "12", "12-x", "Invalid repository")
	refused("a key with a slash", "o/r", "1/2", "12-x", "Invalid issue")
	refused("a key over 64 bytes", "o/r", string.rep("1", 65), "12-x", "Invalid issue")
	refused("an empty key", "o/r", "", "12-x", "Invalid issue")
	refused("no branch", "o/r", "12", "", "Invalid issue")
	local folder = openIssuePlan(w, worktree, r, "12", { dir = "a/b", branch = "12-x", fresh = true, base = "main" }, nil)
	eq(folder.result, nil, "a folder name with a slash: no result")
	has(folder.problem, "Worktree folder name a/b is not usable", "a folder name with a slash: the reason")
	eq(#w.calls, 0, "no process was started")
	r.git.remotes.origin = { "https://github.com/x/y.git" }
	local none = openIssueWt(w, worktree, r, "12", "12-fix-login", nil)
	eq(none.calls, 1, "done calls")
	eq(none.problem, worktree.NO_REPO, "a checkout of another repository is NO_REPO")
	eq(none.result, nil, "result")
	local other = newGit(w, "/work/other")
	other.remotes.origin = { "https://github.com/o/r.git" }
	other.served["refs/heads/main"] = sha("c")
	local given = openIssueWt(w, worktree, r, "12", "12-fix-login", "/work/other")
	eq(given.problem, nil, "the checkout given resolves")
	eq(given.result.root, "/work/other", "and is the one used")
	eq(given.result.head, sha("c"), "with its own remote's base")
end)

windowCase("worktree.openIssue: a base that cannot be fetched creates neither branch nor worktree", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	r.git.served["refs/heads/main"] = nil
	local missing = openIssueWt(w, worktree, r, "12", "12-fix-login", nil)
	eq(missing.calls, 1, "done calls")
	eq(missing.result, nil, "no result")
	has(missing.problem, "couldn't find remote ref refs/heads/main", "git's own message")
	r.git.fail["fetch"] = {}
	local silent = openIssueWt(w, worktree, r, "12", "12-fix-login", nil)
	eq(silent.problem, "Could not read main of o/r.", "a fetch that left no ref says so")
	eq(r.git.refs["refs/heads/12-fix-login"], nil, "no branch was made")
	eq(#r.git.worktrees, 1, "and no worktree")
	eq(countLog(r.git, "worktree add"), 0, "git was never asked to add one")
end)

windowCase("worktree.openIssue: a Jira issue is made in the GitHub repository's checkout, in the repository's own directory", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "ABC-7")
	local function open(key: string): Opened
		return openIssuePlan(w, worktree, r, key, { branch = key .. "-fix", fresh = true, base = "main" }, nil)
	end
	local out = open("ABC-7")
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	eq(out.result.path, "/wt/plotroom-o_r-issue-ABC-7", "the repository's slot, the key in its own case")
	eq(out.result.remote, "origin", "origin")
	eq(out.result.key, "ABC-7", "key")
	eq(out.result.branch, "ABC-7-fix", "branch")
	eq(out.result.created, true, "created")
	eq(countLog(r.git, "fetch --no-tags --no-write-fetch-head origin +refs/heads/main:refs/remotes/origin/main"), 1, "the base is fetched into its remote-tracking ref")
	eq(r.git.refs["refs/heads/ABC-7-fix"], sha("b"), "the branch starts at the base")
	local again = open("ABC-7")
	eq(again.result.created, false, "the same issue again reuses its worktree")
	eq(again.result.path, out.result.path, "at the same path")
	-- the remote of the repository is the one used, whatever its name
	r.git.remotes = { zeta = { "https://github.com/x/z.git" }, upstream = { "https://github.com/o/r.git" } }
	eq(open("ABC-8").result.remote, "upstream", "the remote that points at o/r")
	-- a repository or key it cannot use
	local before = #w.calls
	for _, bad in { { "ABC", "ABC-1" }, { "o", "ABC-1" }, { "o/r", "ABC/1" }, { "o/r", "" } } do
		local refused: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
		worktree.openIssue(r.launch, bad[1], bad[2], { dir = "plotroom-x", branch = "x", fresh = true, base = "main" }, nil, function(result, problem, cx)
			refused.calls += 1
			refused.result, refused.problem, refused.cx = result, problem, cx
		end)
		w.flush()
		eq(refused.calls, 1, "done calls: " .. bad[1] .. " " .. bad[2])
		eq(refused.result, nil, "no result: " .. bad[1] .. " " .. bad[2])
		has(refused.problem, "Invalid", "the reason: " .. bad[1] .. " " .. bad[2])
	end
	eq(#w.calls, before, "no process was started")
end)

windowCase("worktree: a project is a Jira key or a GitHub repository, and a checkout is claimed by cloning when it is no work tree", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "ABC-7")
	yes(worktree.validProject("ABC") and worktree.validProject("A1_B") and worktree.validProject("o/r"), "a Jira key and a GitHub repository are projects")
	for _, bad in { "abc", "A", "o", "o/r/s", "" } do
		yes(not worktree.validProject(bad), "not a project: " .. bad)
	end
	local function claim(path: string): Opened
		local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
		worktree.claimCheckout(path, "o/r", nil, function(result, problem, cx)
			out.calls += 1
			out.result, out.problem, out.cx = result, problem, cx
		end)
		w.flush()
		return out
	end
	local ok = claim("/work/r/src")
	eq(ok.calls, 1, "done calls")
	eq(ok.problem, nil, "problem")
	eq(ok.result.root, "/work/r", "the checkout's root, found from a folder inside it")
	eq(ok.result.cloned, false, "used as it is")
	r.git.remotes = {}
	local bare = claim("/work/r")
	eq(bare.result, nil, "a checkout with no remote")
	eq(bare.problem, "No remote of /work/r points at github.com/o/r.", "has no remote of the repository")
	-- a folder that is no checkout, or is missing, is cloned into with gh
	local cloned = newGit(w, "/work/new")
	cloned.remotes.origin = { "https://github.com/o/r.git" }
	w.fs.dirs["/work/new"] = nil
	w.fs.dirs["/work/new/.git"] = nil
	w.respond(function(call: Call): Reply?
		if table.concat(call.argv, " ") == "gh repo clone o/r /work/new" then
			w.fs.dirs["/work/new"] = true
			w.fs.dirs["/work/new/.git"] = true
			return { stdout = "" }
		end
		return nil
	end)
	local made = claim("/work/new")
	eq(made.problem, nil, "a missing folder is cloned into: problem")
	eq(made.result.root, "/work/new", "and is the checkout")
	eq(made.result.cloned, true, "cloned")
	eq(countCalls(w, "gh repo clone o/r /work/new"), 1, "gh cloned once")
	w.fs.dirs["/work/plain"] = true
	w.respond(function(call: Call): Reply?
		if table.concat(call.argv, " ") == "gh repo clone o/r /work/plain" then
			return { status = 1, stderr = "fatal: destination path '/work/plain' already exists and is not an empty directory.\n" }
		end
		return nil
	end)
	local plain = claim("/work/plain")
	eq(plain.result, nil, "a folder that is no checkout and cannot be cloned into")
	has(plain.problem, "not an empty directory", "gh's reason is the problem")
end)

windowCase("worktree: claimCheckout answers a folder the runtime cannot look at with a problem, and never clones", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	issueRepo(w, "ABC-7")
	w.sdk.fs.exists = function(_path: string): boolean
		error("fs gone", 0)
	end
	local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
	worktree.claimCheckout("/work/new", "o/r", nil, function(result, problem, cx)
		out.calls += 1
		out.result, out.problem, out.cx = result, problem, cx
	end)
	w.flush()
	eq(out.calls, 1, "answered once")
	eq(out.result, nil, "no checkout")
	has(out.problem, "fs gone", "the reason")
	eq(countCalls(w, "gh repo clone o/r /work/new"), 0, "nothing was cloned")
end)

case("worktree: describeIssue says how the issue's worktree stands", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local function result(created: boolean, dirty: boolean?): any
		return {
			path = "/wt/plotroom-o_r-issue-12",
			root = "/work/r",
			remote = "origin",
			branch = "12-fix-login",
			key = "12",
			created = created,
			head = sha("b"),
			dirty = dirty,
		}
	end
	eq(worktree.describeIssue(result(true, false)), "Created · 12-fix-login at bbbbbbb · Clean", "a new, clean one")
	eq(worktree.describeIssue(result(false, true)), "Reused · 12-fix-login at bbbbbbb · Modified (uncommitted changes kept)", "a reused one with local changes")
	eq(worktree.describeIssue(result(false, nil)), "Reused · 12-fix-login at bbbbbbb · Changes unchecked", "a status that could not be read is never Clean")
end)

case("worktree: remove takes an issue's worktree, and its branch only when git agrees it is merged", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local repo = issueRepo(w, "12")
	local r = openIssueWt(w, worktree, repo, "12", "12-fix-login", nil).result
	repo.git.unmerged["12-fix-login"] = true
	local mark = #w.calls
	local kept = removeWt(w, worktree, { root = r.root, path = r.path, branch = r.branch })
	eq(kept.problem, nil, "the worktree is removed")
	eq(kept.removal.branch, "Branch 12-fix-login was kept. The branch '12-fix-login' is not fully merged.", "a branch with commits merged nowhere stays, and the user is told")
	same(ranSince(w, mark), {
		"git -C /work/r worktree remove /wt/plotroom-o_r-issue-12",
		"git -C /work/r branch -d 12-fix-login",
	}, "-d only: no ancestry check, no -D, and no ref to drop")
	eq(repo.git.refs["refs/heads/12-fix-login"], sha("b"), "the branch keeps its commits")
	repo.git.unmerged["12-fix-login"] = nil
	local again = openIssueWt(w, worktree, repo, "12", "12-fix-login", nil).result
	mark = #w.calls
	local gone = removeWt(w, worktree, { root = again.root, path = again.path, branch = again.branch })
	eq(gone.removal.branch, "Branch 12-fix-login was deleted too.", "a merged one goes with the next removal")
	same(ranSince(w, mark), {
		"git -C /work/r worktree remove /wt/plotroom-o_r-issue-12",
		"git -C /work/r branch -d 12-fix-login",
	}, "by -d")
	eq(repo.git.refs["refs/heads/12-fix-login"], nil, "the branch is gone")
end)

-- Reads the checkout `checkout` with worktree.scan for `wants` (item key -> how its worktree is known), lets everything that
-- starts finish, and answers the Scan and the problem; scan must answer once.
local function scanOf(w: World, worktree: Worktree, checkout: string, wants: { [string]: any }): (any, string?)
	local got: any = nil
	local why: string? = nil
	local calls = 0
	worktree.scan(checkout, wants, function(result, problem)
		calls += 1
		got, why = result, problem
	end)
	w.flush()
	eq(calls, 1, "scan reports once")
	return got, why
end

-- The item keys of a Scan's `found`, sorted.
local function foundKeys(scan: any): { string }
	local keys: { string } = {}
	for key in scan.found do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

case("worktree: scan finds the worktrees of the items it is given, by their branches or folder names, as git lists them, and leaves out what Plotroom cannot use or remove", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = newGit(w, "/work/r")
	local function add(path: string, branch: string?, head: string, locked: boolean?, folder: boolean?)
		table.insert(g.worktrees, { path = path, branch = if branch then "refs/heads/" .. branch else nil, head = head, locked = locked == true })
		if folder ~= false then
			w.fs.dirs[path] = true
		end
	end
	add("/wt/plotroom-o_r-pr-5", "feature", sha("b"))
	add("/wt/plotroom-o_r-pr-6", "feature-6", sha("b"), true)
	add("/wt/plotroom-o_r-pr-7", nil, sha("b"))
	add("/wt/plotroom-o_r-pr-8", "feature-8", sha("b"), false, false)
	add("/wt/anything", "bob/patch", sha("d"))
	add("/wt/plotroom-o_r-pr-3", "plotroom/o/r/pr-3", sha("f"))
	add("/home/u/plotroom-notes/wt/plotroom-o_r-pr-4", "plotroom/o/r/pr-4", sha("a"))
	add("/wt/plotroom-o_r-issue-12", "octocat/12-fix-login", sha("c"))
	add("/wt/plotroom-o_r-issue-13", nil, sha("c"))
	add("/wt/elsewhere", "other", sha("e"))
	local function pr(n: number, branch: string): any
		return { branches = { branch }, dirs = { "plotroom-o_r-pr-" .. n }, ref = "refs/plotroom-pr/o/r/pr-" .. n }
	end
	local wants = {
		["o/r#3"] = pr(3, "feature-3"),
		["o/r#4"] = pr(4, "feature-4"),
		["o/r#5"] = pr(5, "feature"),
		["o/r#6"] = pr(6, "feature-6"),
		["o/r#7"] = pr(7, "feature-7"),
		["o/r#8"] = pr(8, "feature-8"),
		["o/r#9"] = pr(9, "bob/patch"),
		["o/r#12"] = { branches = { "octocat/12-fix-login" }, dirs = { "plotroom-o_r-issue-12" } },
		["o/r#13"] = { branches = { "octocat/13-x" }, dirs = { "plotroom-o_r-issue-13" } },
		["o/r#14"] = pr(14, "feature-14"),
	}
	local scan, why = scanOf(w, worktree, "/work/r/src", wants)
	eq(why, nil, "problem")
	eq(scan.root, "/work/r", "the main worktree, whichever folder of the checkout was asked")
	same(foundKeys(scan), { "o/r#12", "o/r#3", "o/r#4", "o/r#5", "o/r#9" }, "found: a locked one, a detached one, one whose folder is gone, one no item names and an item with no worktree are left out")
	same(scan.found["o/r#5"], { root = "/work/r", path = "/wt/plotroom-o_r-pr-5", branch = "feature", head = sha("b"), ref = "refs/plotroom-pr/o/r/pr-5" }, "a pull request's: where it is, its branch and head, and the ref it is fetched into")
	same(scan.found["o/r#9"], { root = "/work/r", path = "/wt/anything", branch = "bob/patch", head = sha("d"), ref = "refs/plotroom-pr/o/r/pr-9" }, "a fork's is on its owner's branch, whatever its folder is called")
	eq(scan.found["o/r#3"].path, "/wt/plotroom-o_r-pr-3", "one on a branch an earlier version named is found by its folder")
	eq(scan.found["o/r#3"].branch, "plotroom/o/r/pr-3", "and says which branch it is on")
	eq(scan.found["o/r#4"].path, "/home/u/plotroom-notes/wt/plotroom-o_r-pr-4", "the folder's own name decides, not the folders above it")
	same(scan.found["o/r#12"], { root = "/work/r", path = "/wt/plotroom-o_r-issue-12", branch = "octocat/12-fix-login", head = sha("c") }, "an issue's has no fetched ref")
	eq(countLog(g, "worktree list"), 1, "one read of the checkout")
	for _, never in { "worktree add", "worktree remove", "status", "fetch", "branch", "merge", "config", "remote", "rev-parse" } do
		eq(countLog(g, never), 0, "git " .. never .. " was not run: scanning only lists")
	end
	eq(scanOf(w, worktree, "/wt/plotroom-o_r-pr-5", wants).root, "/work/r", "asked from a linked worktree, it still names the main one")
	same(foundKeys((scanOf(w, worktree, "/work/r", {}))), {}, "no item wanted, none found")
	g.fail["worktree list"] = { status = 128, stderr = "fatal: unable to read the worktrees\n" }
	local none, problem = scanOf(w, worktree, "/work/r", wants)
	eq(none, nil, "a checkout git cannot list gives no scan")
	has(problem, "unable to read the worktrees", "and git's reason")
	g.fail["worktree list"] = nil
	w.sdk.fs.exists = function(_path: string): boolean
		error("fs gone", 0)
	end
	same(foundKeys((scanOf(w, worktree, "/work/r", wants))), {}, "a runtime that cannot look at folders finds none, and still answers")
end)

case("worktree: scan knows a worktree by its branch before its folder, and takes the first git lists when an item has two", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = newGit(w, "/work/r")
	local function add(path: string, branch: string)
		table.insert(g.worktrees, { path = path, branch = "refs/heads/" .. branch, head = sha("b"), locked = false })
		w.fs.dirs[path] = true
	end
	add("/wt/shared", "feature-a")
	add("/wt/own", "feature-b")
	local scan = scanOf(w, worktree, "/work/r", {
		["o/r#1"] = { branches = { "feature-a" }, dirs = { "elsewhere" } },
		["o/r#2"] = { branches = { "feature-b" }, dirs = { "shared" } },
	})
	eq(scan.found["o/r#1"].path, "/wt/shared", "a worktree whose branch an item wants is that item's...")
	eq(scan.found["o/r#2"].path, "/wt/own", "...though another item names its folder, and that one has its own")
	-- an item with two worktrees: one on its branch, one in its folder
	add("/wt/by-branch", "feature-c")
	add("/wt/by-folder", "unrelated")
	local two = { ["o/r#3"] = { branches = { "feature-c" }, dirs = { "by-folder" } } }
	eq(scanOf(w, worktree, "/work/r", two).found["o/r#3"].path, "/wt/by-branch", "the first git lists is the item's")
	table.insert(g.worktrees, 2, table.remove(g.worktrees) :: any)
	eq(scanOf(w, worktree, "/work/r", two).found["o/r#3"].path, "/wt/by-folder", "whichever that is")
end)

case("worktree: scan gives a worktree to every item that names its branch or folder", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = newGit(w, "/work/r")
	table.insert(g.worktrees, { path = "/wt/a", branch = "refs/heads/fix-login", head = sha("b"), locked = false })
	table.insert(g.worktrees, { path = "/wt/plotroom-o_r-issue-9", branch = "refs/heads/other", head = sha("c"), locked = false })
	w.fs.dirs["/wt/a"] = true
	w.fs.dirs["/wt/plotroom-o_r-issue-9"] = true
	local scan = scanOf(w, worktree, "/work/r", {
		["o/r#12"] = { branches = { "fix-login" }, dirs = { "plotroom-o_r-issue-12" } },
		["o/r#45"] = { branches = { "fix-login" }, dirs = { "plotroom-o_r-pr-45" }, ref = "refs/plotroom-pr/o/r/pr-45" },
		["o/r#46"] = { branches = { "fix-login" }, dirs = { "plotroom-o_r-pr-46" }, ref = "refs/plotroom-pr/o/r/pr-46" },
		["o/r#9"] = { branches = { "x" }, dirs = { "plotroom-o_r-issue-9" } },
		["o/r#10"] = { branches = { "y" }, dirs = { "plotroom-o_r-issue-9" } },
	})
	same(foundKeys(scan), { "o/r#10", "o/r#12", "o/r#45", "o/r#46", "o/r#9" }, "an issue and pull requests on one branch, or in one folder, all have it")
	eq(scan.found["o/r#45"].ref, "refs/plotroom-pr/o/r/pr-45", "each keeps its own fetched ref")
	eq(scan.found["o/r#46"].ref, "refs/plotroom-pr/o/r/pr-46", "each keeps its own fetched ref")
	eq(scan.found["o/r#12"].path, "/wt/a", "the same worktree")
end)

case("worktree: scan gives a folder-only item the worktree a PR branch also matches, unless the item has a worktree of its own branch", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = newGit(w, "/work/r")
	local function add(path: string, branch: string)
		table.insert(g.worktrees, { path = path, branch = "refs/heads/" .. branch, head = sha("b"), locked = false })
		w.fs.dirs[path] = true
	end
	add("/wt/plotroom-o_r-issue-12", "fix-login")
	add("/wt/own", "feature-b")
	local scan = scanOf(w, worktree, "/work/r", {
		["o/r#45"] = { branches = { "fix-login" }, dirs = { "plotroom-o_r-pr-45" }, ref = "refs/plotroom-pr/o/r/pr-45" },
		["o/r#12"] = { branches = { "octocat/12-x" }, dirs = { "plotroom-o_r-issue-12" } },
		["o/r#13"] = { branches = { "feature-b" }, dirs = { "plotroom-o_r-issue-12" } },
	})
	eq(scan.found["o/r#45"].path, "/wt/plotroom-o_r-issue-12", "the PR by its branch")
	eq(scan.found["o/r#12"].path, "/wt/plotroom-o_r-issue-12", "the issue by its folder, though the branch is the PR's")
	eq(scan.found["o/r#13"].path, "/wt/own", "an item with a worktree on its own branch keeps that one")
end)

case("worktree: scan never reports the main worktree, whatever branch or folder name an item wants", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local g = newGit(w, "/work/r")
	table.insert(g.worktrees, { path = "/wt/plotroom-o_r-pr-5", branch = "refs/heads/feature", head = sha("b"), locked = false })
	w.fs.dirs["/wt/plotroom-o_r-pr-5"] = true
	local scan = scanOf(w, worktree, "/work/r", {
		["o/r#1"] = { branches = { "main" }, dirs = {} },
		["o/r#2"] = { branches = {}, dirs = { "r" } },
		["o/r#5"] = { branches = { "feature" }, dirs = {} },
	})
	same(foundKeys(scan), { "o/r#5" }, "the checkout is no item's worktree: not by its branch, not by its folder")
	eq(scan.root, "/work/r", "though it is the root")
end)

-- The branches of o/r that worktree.remoteBranches lists from `checkout`: its one answer (result: the names).
local function remoteBranchesOf(w: World, worktree: Worktree, checkout: string): Opened
	local out: Opened = { calls = 0, result = nil, problem = nil, cx = nil }
	worktree.remoteBranches(checkout, "o/r", function(names, problem, cx)
		out.calls += 1
		out.result, out.problem, out.cx = names, problem, cx
	end)
	w.flush()
	return out
end

windowCase("worktree.openIssue: a plan with neither a PR nor a new branch is UNDECIDED when no worktree is at the folder", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local before = snapshot(r.git)
	local out = openIssuePlan(w, worktree, r, "12", { branch = "12-fix-login", fresh = false }, nil)
	eq(out.calls, 1, "done calls")
	eq(out.result, nil, "no result")
	eq(out.problem, worktree.UNDECIDED, "problem: the caller has to choose between a linked PR's branch and a new one")
	eq(snapshot(r.git), before, "git state is untouched")
	same(worktreeWrites(w), {}, "nothing fetched or added")
	eq(#w.fs.mkdirs, 0, "no directory was made")
end)

windowCase("worktree.openIssue: a worktree already at the plan's folder is reused whatever the plan, on its own branch", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local gh = newGh(w)
	table.insert(r.git.worktrees, { path = r.target, branch = "refs/heads/work-in-progress", head = sha("d"), locked = false })
	w.fs.dirs[r.target] = true
	local before = snapshot(r.git)
	local plans: { { any } } = {
		{ "an undecided plan", { branch = "12-fix-login", fresh = false } },
		{ "a new branch without a base", { branch = "12-fix-login", fresh = true } },
		{ "a new branch from a base", { branch = "12-fix-login", fresh = true, base = "main" } },
		{ "a PR", { branch = "12-fix-login", pr = 7, fresh = false } },
	}
	for _, row in plans do
		local out = openIssuePlan(w, worktree, r, "12", row[2], nil)
		eq(out.calls, 1, row[1] .. ": done calls")
		eq(out.problem, nil, row[1] .. ": problem")
		eq(out.result.created, false, row[1] .. ": created")
		eq(out.result.path, r.target, row[1] .. ": path")
		eq(out.result.branch, "work-in-progress", row[1] .. ": the worktree's own branch, not the one asked for")
		eq(out.result.head, sha("d"), row[1] .. ": head")
		eq(out.result.dirty, false, row[1] .. ": dirty")
	end
	eq(snapshot(r.git), before, "git state is untouched")
	same(worktreeWrites(w), {}, "nothing fetched, added or configured")
	eq(#gh.requests, 0, "the PR was not even read")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	-- a detached HEAD has no branch of its own: the plan's is reported
	table.insert(r.git.worktrees, { path = "/wt/plotroom-o_r-issue-13", head = sha("e"), locked = false })
	w.fs.dirs["/wt/plotroom-o_r-issue-13"] = true
	local detached = openIssuePlan(w, worktree, r, "13", { branch = "13-docs", fresh = false }, nil)
	eq(detached.problem, nil, "problem for a detached worktree")
	eq(detached.result.created, false, "created")
	eq(detached.result.branch, "13-docs", "branch")
	eq(detached.result.head, sha("e"), "head")
end)

windowCase("worktree.openIssue: a plan with a PR puts the worktree on that PR's head branch as worktree.open does, in the plan's folder", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local gh = newGh(w)
	gh.meta["o/r#7"] = { base = "o/r", sha = sha("b"), ref = "fix-login", headRepo = "o/r", headOwner = "o", state = "open", baseRef = "main", title = "Fix login", author = "ann" }
	r.git.served["refs/pull/7/head"] = sha("b")
	r.git.served["refs/heads/fix-login"] = sha("b")
	local out = openIssuePlan(w, worktree, r, "12", { dir = "issue-12", branch = "", pr = 7, fresh = false }, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	local res = out.result
	eq(res.path, "/wt/issue-12", "path: the plan's folder")
	eq(res.root, "/work/r", "root")
	eq(res.remote, "origin", "remote")
	eq(res.branch, "fix-login", "branch: the PR's head branch, whatever the plan's own")
	eq(res.key, "12", "key")
	eq(res.ref, worktree.prRef("o", "r", 7), "ref: where the PR head was fetched")
	eq(res.number, 7, "number")
	eq(res.created, true, "created")
	eq(res.head, sha("b"), "head")
	eq(res.dirty, false, "dirty")
	same(worktreeWrites(w), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/pull/7/head:refs/plotroom-pr/o/r/pr-7",
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/heads/fix-login:refs/remotes/origin/fix-login",
		"omp worktree add -q -C /work/r -b fix-login /wt/issue-12 " .. sha("b"),
		"git -C /work/r config branch.fix-login.remote origin",
		"git -C /work/r config branch.fix-login.merge refs/heads/fix-login",
	}, "the PR's head, its branch's tracking ref, the worktree on a new branch there, then the upstream")
	same(r.git.config, { ["branch.fix-login.remote"] = "origin", ["branch.fix-login.merge"] = "refs/heads/fix-login" }, "the upstream")
	-- another issue linked to the same PR shares the PR's worktree, wherever it is
	local mark = #w.calls
	local shared = openIssuePlan(w, worktree, r, "14", { branch = "", pr = 7, fresh = false }, nil)
	eq(shared.problem, nil, "problem for a second issue")
	eq(shared.result.created, false, "created")
	eq(shared.result.path, "/wt/issue-12", "the worktree that has the PR's branch")
	eq(shared.result.key, "14", "key")
	eq(shared.result.ref, worktree.prRef("o", "r", 7), "ref")
	eq(shared.result.number, 7, "number")
	same(worktreeWrites(w, mark), {}, "nothing fetched, added or configured")
	-- a fork's PR is on the fork's branch
	gh.meta["o/r#8"] = { base = "o/r", sha = sha("b"), ref = "patch", headRepo = "fork/r", headOwner = "fork", state = "open", baseRef = "main", title = "Patch", author = "bo" }
	r.git.served["refs/pull/8/head"] = sha("b")
	local forked = openIssuePlan(w, worktree, r, "15", { branch = "", pr = 8, fresh = false }, nil)
	eq(forked.problem, nil, "problem for a fork's PR")
	eq(forked.result.branch, "fork/patch", "branch")
	eq(forked.result.number, 8, "number")
	eq(r.git.config["branch.fork/patch.remote"], "https://github.com/fork/r.git", "tracking the fork's URL")
	eq(r.git.config["branch.fork/patch.merge"], "refs/heads/patch", "and its branch")
end)

windowCase("worktree.openIssue: a plan's PR must merge into the repository (any letter case) and be readable, or nothing is created", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local gh = newGh(w)
	gh.meta["o/r#9"] = { base = "x/y", sha = sha("b"), ref = "feature", headRepo = "x/y", headOwner = "x", state = "open", baseRef = "main", title = "Elsewhere", author = "ann" }
	r.git.served["refs/pull/9/head"] = sha("b")
	local before = snapshot(r.git)
	local other = openIssuePlan(w, worktree, r, "12", { branch = "12-x", pr = 9, fresh = false }, nil)
	eq(other.calls, 1, "done calls")
	eq(other.result, nil, "no result")
	eq(other.problem, "Pull request #9 merges into x/y, not o/r.", "problem: another repository's PR")
	local missing = openIssuePlan(w, worktree, r, "12", { branch = "12-x", pr = 10, fresh = false }, nil)
	eq(missing.calls, 1, "done calls for an unreadable PR")
	eq(missing.result, nil, "no result for an unreadable PR")
	has(missing.problem, "gh: Not Found (HTTP 404)", "problem: gh's own")
	eq(snapshot(r.git), before, "git state is untouched")
	same(worktreeWrites(w), {}, "nothing fetched or added")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	gh.meta["o/r#9"].base = "O/R"
	local cased = openIssuePlan(w, worktree, r, "12", { branch = "12-x", pr = 9, fresh = false }, nil)
	eq(cased.problem, nil, "problem when the base differs only in letter case")
	eq(cased.result.number, 9, "number")
end)

windowCase("worktree.openIssue: a new branch without a base is NEED_BASE once its name is checked and no worktree has the branch", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local before = snapshot(r.git)
	local out = openIssuePlan(w, worktree, r, "12", { branch = "12-fix-login", fresh = true }, nil)
	eq(out.calls, 1, "done calls")
	eq(out.result, nil, "no result")
	eq(out.problem, worktree.NEED_BASE, "problem: the caller has to ask which branch to start from")
	eq(snapshot(r.git), before, "git state is untouched")
	same(worktreeWrites(w), {}, "nothing fetched or added")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	eq(countLog(r.git, "check-ref-format --branch 12-fix-login"), 1, "the branch name was checked")
	-- a name git refuses is refused first, whether or not a base was chosen
	local invalid = openIssuePlan(w, worktree, r, "13", { branch = "13 fix login", fresh = true }, nil)
	eq(invalid.result, nil, "no result for an invalid branch")
	eq(invalid.problem, "Branch name 13 fix login is not valid; change the branch format in Settings › Repositories.", "problem: the branch name, not NEED_BASE")
	local withBase = openIssuePlan(w, worktree, r, "13", { branch = "13 fix login", fresh = true, base = "main" }, nil)
	eq(withBase.problem, "Branch name 13 fix login is not valid; change the branch format in Settings › Repositories.", "problem with a base")
	same(worktreeWrites(w), {}, "still nothing fetched or added")
	-- a worktree that has the branch is reused: no base is needed
	table.insert(r.git.worktrees, { path = "/wt/elsewhere", branch = "refs/heads/14-typo", head = sha("f"), locked = false })
	w.fs.dirs["/wt/elsewhere"] = true
	local reused = openIssuePlan(w, worktree, r, "14", { branch = "14-typo", fresh = true }, nil)
	eq(reused.problem, nil, "problem when a worktree has the branch")
	eq(reused.result.created, false, "created")
	eq(reused.result.path, "/wt/elsewhere", "path: the worktree that has it")
	eq(reused.result.branch, "14-typo", "branch")
	eq(reused.result.head, sha("f"), "head")
	same(worktreeWrites(w), {}, "nothing was added")
end)

windowCase("worktree.openIssue: a new branch starts at the commit of its base as fetched from the remote, with no upstream", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local out = openIssuePlan(w, worktree, r, "12", { branch = "12-fix-login", fresh = true, base = "main" }, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	local res = out.result
	eq(res.created, true, "created")
	eq(res.path, r.target, "path")
	eq(res.branch, "12-fix-login", "branch")
	eq(res.key, "12", "key")
	eq(res.head, sha("b"), "head: the remote's main, not the checkout's own main at " .. sha("1"))
	eq(res.dirty, false, "dirty")
	eq(res.ref, nil, "no PR ref")
	eq(res.number, nil, "no PR number")
	same(worktreeWrites(w), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/heads/main:refs/remotes/origin/main",
		"omp worktree add -q -C /work/r -b 12-fix-login /wt/plotroom-o_r-issue-12 " .. sha("b"),
	}, "the base is fetched once, then the worktree is added on a new branch at that commit, and no upstream is written")
	eq(r.git.refs["refs/remotes/origin/main"], sha("b"), "the remote-tracking ref holds the remote's commit")
	eq(r.git.refs["refs/heads/12-fix-login"], sha("b"), "the new branch starts there")
	eq(r.git.refs["refs/heads/main"], sha("1"), "the checkout's own main did not move")
	same(r.git.config, {}, "no upstream: the first push -u sets it")
	-- a base that is not the default branch and has a slash, while the checkout's own branch of that name is somewhere else
	r.git.served["refs/heads/release/1.2"] = sha("c")
	r.git.refs["refs/heads/release/1.2"] = sha("d")
	local mark = #w.calls
	local release = openIssuePlan(w, worktree, r, "13", { branch = "13-docs", fresh = true, base = "release/1.2" }, nil)
	eq(release.problem, nil, "problem for a release base")
	eq(release.result.head, sha("c"), "head: the remote's release/1.2, not the local branch of that name")
	same(worktreeWrites(w, mark), {
		"git -C /work/r fetch --no-tags --no-write-fetch-head origin +refs/heads/release/1.2:refs/remotes/origin/release/1.2",
		"omp worktree add -q -C /work/r -b 13-docs /wt/plotroom-o_r-issue-13 " .. sha("c"),
	}, "the base is fetched under its own name")
	eq(r.git.refs["refs/heads/release/1.2"], sha("d"), "the local branch of that name did not move")
end)

windowCase("worktree.openIssue: a base that cannot be fetched or read creates nothing, and the problem is git's own", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local before = snapshot(r.git)
	local function refused(what: string, base: string): string?
		local out = openIssuePlan(w, worktree, r, "12", { branch = "12-fix-login", fresh = true, base = base }, nil)
		eq(out.calls, 1, what .. ": done calls")
		eq(out.result, nil, what .. ": no result")
		eq(snapshot(r.git), before, what .. ": no branch, ref or worktree was made")
		eq(#w.fs.mkdirs, 0, what .. ": no directory was made")
		return out.problem
	end
	has(refused("a branch the remote does not have", "gone"), "couldn't find remote ref refs/heads/gone", "git's message for a missing branch")
	r.git.fail["fetch"] = { status = 128, stderr = "fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com\n" }
	has(refused("a failing fetch", "main"), "Could not resolve host: github.com", "git's message for a failing fetch")
	r.git.fail["fetch"] = {} -- git says nothing and the ref is not there
	eq(refused("a fetch that leaves no ref", "main"), "Could not read main of o/r.", "a fetch that left nothing to start from")
	r.git.fail["fetch"] = nil
	local mark = #w.calls
	eq(refused("a base git rejects as a branch name", "bad name"), "Base branch bad name is not a valid branch name.", "the invalid base")
	same(worktreeWrites(w, mark), {}, "which is not fetched")
end)

windowCase("worktree.openIssue: a new branch that exists locally is attached at its own commit, without a base, and never moved", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	r.git.refs["refs/heads/12-fix-login"] = sha("d")
	local out = openIssuePlan(w, worktree, r, "12", { branch = "12-fix-login", fresh = true }, nil)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem: no base was needed")
	eq(out.result.created, true, "created")
	eq(out.result.branch, "12-fix-login", "branch")
	eq(out.result.head, sha("d"), "head: the branch's own commit")
	eq(r.git.refs["refs/heads/12-fix-login"], sha("d"), "the branch did not move")
	same(worktreeWrites(w), { "omp worktree add -q -C /work/r /wt/plotroom-o_r-issue-12 12-fix-login" }, "attached with the two-argument form: nothing fetched, no -b, no upstream")
	-- a base chosen anyway is not fetched either
	r.git.refs["refs/heads/13-docs"] = sha("e")
	local mark = #w.calls
	local based = openIssuePlan(w, worktree, r, "13", { branch = "13-docs", fresh = true, base = "main" }, nil)
	eq(based.problem, nil, "problem with a base")
	eq(based.result.head, sha("e"), "head")
	same(worktreeWrites(w, mark), { "omp worktree add -q -C /work/r /wt/plotroom-o_r-issue-13 13-docs" }, "the base is not needed, so not fetched")
end)

windowCase("worktree.openIssue: a folder name or branch that cannot be used ends the request, creating nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local before = snapshot(r.git)
	local bad: { { string } } = {
		{ "a slash", "issue/12" },
		{ "a path out of the folder", "../issue-12" },
		{ "an empty name", "" },
		{ "two dots", ".." },
		{ "a newline", "issue\n12" },
		{ "201 bytes", string.rep("a", 201) },
	}
	for _, row in bad do
		local out = openIssuePlan(w, worktree, r, "12", { dir = row[2], branch = "12-fix-login", fresh = true, base = "main" }, nil)
		eq(out.calls, 1, row[1] .. ": done calls")
		eq(out.result, nil, row[1] .. ": no result")
		has(out.problem, "Worktree folder name " .. row[2] .. " is not usable", row[1] .. ": names the folder name")
		has(out.problem, "Settings", row[1] .. ": says where to change it")
	end
	local nameless = openIssuePlan(w, worktree, r, "12", { branch = "", fresh = true, base = "main" }, nil)
	eq(nameless.result, nil, "no result for a new branch without a name")
	has(nameless.problem, "Invalid issue 12 of o/r", "problem: a new branch needs a name")
	eq(snapshot(r.git), before, "git state is untouched")
	eq(#w.fs.mkdirs, 0, "no directory was made")
	local spaced = openIssuePlan(w, worktree, r, "12", { dir = "issue 12", branch = "12-fix-login", fresh = true, base = "main" }, nil)
	eq(spaced.problem, nil, "problem for a folder name with spaces")
	eq(spaced.result.path, "/wt/issue 12", "path")
	local added: any = nil
	for _, call in w.calls do
		if call.argv[1] == "omp" and call.argv[3] == "add" then
			added = call.argv
		end
	end
	same(added, { "omp", "worktree", "add", "-q", "-C", "/work/r", "-b", "12-fix-login", "/wt/issue 12", sha("b") }, "the folder is one argument, never a shell word")
end)

windowCase("worktree.openIssue: a folder that is no worktree ends a PR or a new-branch plan, touching nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	local gh = newGh(w)
	gh.meta["o/r#7"] = { base = "o/r", sha = sha("b"), ref = "fix-login", headRepo = "o/r", headOwner = "o", state = "open", baseRef = "main", title = "Fix login", author = "ann" }
	r.git.served["refs/pull/7/head"] = sha("b")
	w.fs.dirs[r.target] = true
	local before = snapshot(r.git)
	local fresh = openIssuePlan(w, worktree, r, "12", { branch = "12-fix-login", fresh = true, base = "main" }, nil)
	eq(fresh.result, nil, "no result for a new branch")
	eq(fresh.problem, r.target .. " already exists and is not the worktree of 12-fix-login; move it away or remove it.", "problem for a new branch")
	local pr = openIssuePlan(w, worktree, r, "12", { branch = "", pr = 7, fresh = false }, nil)
	eq(pr.result, nil, "no result for a PR")
	eq(pr.problem, r.target .. " already exists and is not the worktree of fix-login; move it away or remove it.", "problem for a PR")
	eq(snapshot(r.git), before, "git state is untouched")
	same(worktreeWrites(w), {}, "nothing fetched or added")
	eq(#w.fs.mkdirs, 0, "no directory was made")
end)

windowCase("worktree.remoteBranches: lists the branches of the repository's own remote, its default branch first and the rest sorted", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	r.git.remotes = { origin = { "https://github.com/me/r.git" }, upstream = { "https://github.com/o/r.git" } }
	r.git.defaultBranch = "trunk"
	for _, name in { "zeta", "trunk", "release/2.0", "alpha", "release/10.0", "feat/x" } do
		r.git.served["refs/heads/" .. name] = sha("c")
	end
	local out = remoteBranchesOf(w, worktree, r.launch)
	eq(out.calls, 1, "done calls")
	eq(out.problem, nil, "problem")
	same(out.result, { "trunk", "alpha", "feat/x", "main", "release/10.0", "release/2.0", "zeta" }, "the default branch, then the others in name order")
	eq(countCalls(w, "git -C /work/r ls-remote --symref upstream HEAD refs/heads/*"), 1, "asked the remote that points at o/r, for HEAD and the branches")
	-- a remote that names no default branch: just the names, sorted
	r.git.defaultBranch = nil
	local plain = remoteBranchesOf(w, worktree, r.launch)
	eq(plain.problem, nil, "problem without a default branch")
	same(plain.result, { "alpha", "feat/x", "main", "release/10.0", "release/2.0", "trunk", "zeta" }, "sorted, none first")
	-- a remote with no branch at all
	r.git.served = {}
	local empty = remoteBranchesOf(w, worktree, r.launch)
	eq(empty.problem, nil, "problem for an empty remote")
	same(empty.result, {}, "no branches")
	-- git's own order is not relied on: whatever order the remote lists its refs in, the names come out sorted
	local listing = "ref: refs/heads/main\tHEAD\n" .. sha("c") .. "\tHEAD\n"
	for _, name in { "zeta", "main", "alpha", "release/10.0", "feat/x" } do
		listing ..= sha("c") .. "\trefs/heads/" .. name .. "\n"
	end
	w.respond(function(call: Call): Reply?
		return if table.concat(call.argv, " ") == "git -C /work/r ls-remote --symref upstream HEAD refs/heads/*" then { stdout = listing } else nil
	end)
	local shuffled = remoteBranchesOf(w, worktree, r.launch)
	eq(shuffled.problem, nil, "problem for an unsorted listing")
	same(shuffled.result, { "main", "alpha", "feat/x", "release/10.0", "zeta" }, "the default branch, then the rest sorted")
end)

windowCase("worktree.remoteBranches: a remote that cannot be listed is the problem, and a checkout of another repository is NO_REPO", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	local r = issueRepo(w, "12")
	r.git.fail["ls-remote"] = { status = 128, stderr = "fatal: unable to access 'https://github.com/o/r.git/': Could not resolve host: github.com\n" }
	local failed = remoteBranchesOf(w, worktree, r.launch)
	eq(failed.calls, 1, "done calls")
	eq(failed.result, nil, "no names")
	has(failed.problem, "Could not resolve host: github.com", "problem: git's own message")
	r.git.fail["ls-remote"] = nil
	r.git.remotes.origin = { "https://github.com/x/y.git" }
	local none = remoteBranchesOf(w, worktree, r.launch)
	eq(none.calls, 1, "done calls for another repository")
	eq(none.result, nil, "no names for another repository")
	eq(none.problem, worktree.NO_REPO, "problem: a checkout of another repository")
	eq(countLog(r.git, "ls-remote"), 1, "only the first checkout was listed")
end)

return {}
