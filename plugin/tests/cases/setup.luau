--!strict
-- Regression cases: the Get started checklist and checkout detection.

local h = require("../harness")

type Block = h.Block
type GhReq = h.GhReq
type Reply = h.Reply
type Worktree = h.Worktree
type World = h.World

local agentScene, asks, case, countCalls, eq, findKey, has = h.agentScene, h.asks, h.case, h.countCalls, h.eq, h.findKey, h.has
local hostScene, hx, linkQueue, newGit, promptOf, requestsSent = h.hostScene, h.hx, h.linkQueue, h.newGit, h.promptOf, h.requestsSent
local runLink, same, savePrompts, scene, windowCase, yes = h.runLink, h.same, h.savePrompts, h.scene, h.windowCase, h.yes
local cardSurface = h.cardSurface

-- The checklist card the queue shows, nil when it shows none.
local function guide(b: Block): any
	return findKey(b.view().layer, "get-started", "card")
end

-- The checklist line `key` (an item, or the shortcuts' row).
local function line(b: Block, key: string): any
	return findKey(guide(b), key)
end

-- The labels of the checklist's lines, in order.
local function labels(b: Block): { string }
	local out: { string } = {}
	for _, item in findKey(guide(b), "lines", "list").c do
		table.insert(out, item.p.label)
	end
	return out
end

-- A click on checklist node `key`, as Tern sends it: its click action split at `=` into act and value.
local function click(b: Block, key: string)
	local node = findKey(guide(b), key, "item")
	local act, value = string.match(node.p.actions.click, "^([^=]+)=?(.*)$")
	b.event({ ev = "action", id = "layer.queue.get-started." .. key, act = act, value = if value ~= "" then value else nil })
end

-- A fresh profile: nothing decided on the checklist, no one-key shortcuts.
local function fresh(w: World)
	local store: any = w.kv.store
	store["get-started"] = nil
	store.keys = nil
end

-- The queue opened in a folder that is no checkout, so nothing saves a checkout of o/r on launch.
local function openOutside(w: World): Block
	w.fs.dirs["/home/me"] = true
	local b = w.open(1, { "/home/me" })
	w.flush()
	return b
end

case("host: Get started lists gh, omp, the listed repository without a checkout and the one-key shortcuts, until it is dismissed for good", function(w: World)
	hostScene(w, 3)
	fresh(w)
	local b = openOutside(w)
	yes(guide(b) ~= nil, "a fresh profile shows the checklist")
	same(labels(b), { "gh signed in as @octocat", "omp installed", "Choose the checkout of o/r…" }, "gh and omp done, o/r's checkout to choose")
	local choose = line(b, "co:o/r").p
	eq(choose.href, "plotroom://checkout/o/r", "nothing was found: it asks the window for a folder")
	eq(choose.value, "A new or empty folder gets a clone", "and clone stays the fallback")
	has(findKey(line(b, "keys"), "what").p.spans[1].t, "One-key shortcuts (j k", "the shortcuts line names its keys")
	eq(findKey(line(b, "keys"), "use", "item").p.label, "Use them", "with Use them")
	eq(findKey(line(b, "keys"), "no", "item").p.label, "No thanks", "and No thanks")
	has(findKey(guide(b), "head").p.spans[2].t, "2 to do", "the head counts what is left")
	eq(h.pickerOf(b).preview, "side", "it shows in the preview")
	click(b, "dismiss")
	eq(guide(b), nil, "Dismiss hides it")
	same(w.kv.get("get-started"), { dismissed = true }, "for good, in kv")
	local other = w.open(2, { "/home/me" })
	w.flush()
	eq(guide(other), nil, "another block does not show it either")
	b.event({ ev = "action", act = "get-started" })
	w.flush()
	yes(guide(b) ~= nil, "Commands › Get started shows it again")
	eq(guide(other), nil, "in that block only")
	w.kv.put("get-started", "garbage")
	click(b, "dismiss")
	eq(w.toasts[#w.toasts].text, "Not saved", "a dismissal that cannot be saved says so")
	eq(w.kv.get("get-started"), "garbage", "and the unreadable store is never written over")
end)

case("host: Get started points to each setup guide while gh is signed out or omp is missing", function(w: World)
	local s = hostScene(w, 3)
	fresh(w)
	w.kv.put("checkouts", { ["o/r"] = "/work/r" })
	hx.uninstalled(w, "omp")
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "accounts" then
			return { status = 1, stdout = '{"hosts":{}}', stderr = "You are not logged into any GitHub hosts.\n" }
		end
		return nil
	end
	local b = openOutside(w)
	same(labels(b), { "Sign in to gh: run gh auth login", "Install omp, which runs the agents" }, "both lines say what to do")
	eq(line(b, "gh").p.value, "Setup guide ↗", "each with its setup guide")
	click(b, "gh")
	eq(w.opened[#w.opened], "https://cli.github.com/manual/gh_auth_login", "gh's sign-in guide")
	click(b, "omp")
	eq(w.opened[#w.opened], "https://github.com/can1357/oh-my-pi", "omp's install guide")
end)

case("host: without gh, Get started's gh line points to gh's install guide", function(w: World)
	hostScene(w, 3)
	fresh(w)
	hx.uninstalled(w, "gh")
	hx.uninstalled(w, "acli")
	local b = openOutside(w)
	same(labels(b), { "Install gh, GitHub's CLI", "omp installed" }, "gh to install; with no GitHub view nothing is listed, so no checkout to choose")
	click(b, "gh")
	eq(w.opened[#w.opened], "https://github.com/cli/cli#installation", "gh's install guide")
end)

case("host: Get started's shortcuts: Use them binds the one-key set, No thanks keeps the keys, and either is done", function(w: World)
	hostScene(w, 3)
	fresh(w)
	w.kv.put("checkouts", { ["o/r"] = "/work/r" })
	local b = openOutside(w)
	click(b, "use")
	eq((w.kv.get("keys") :: any).worktree, "w", "Use them binds the one-key set")
	eq((w.kv.get("get-started") :: any).shortcuts, "use", "and is saved as decided")
	eq(guide(b), nil, "every line done: the checklist goes")
	w.kv.put("get-started", {})
	local store: any = w.kv.store
	store.keys = nil
	b.event({ ev = "action", act = "get-started" })
	click(b, "no")
	eq(w.kv.get("keys"), nil, "No thanks binds nothing")
	eq((w.kv.get("get-started") :: any).shortcuts, "no", "and is saved as decided")
	eq(line(b, "keys").p.label, "One-key shortcuts: no thanks", "the line is done")
	eq(findKey(guide(b), "dismiss").p.label, "Close", "all done, Get started's card offers Close")
end)

case("host: checkout detection offers the folder Plotroom opened in when one of its remotes is the listed repository, and Use saves it", function(w: World)
	local s = hostScene(w, 3)
	fresh(w)
	-- a fork's checkout: launching saves it for the fork (its first remote), and o/r is its upstream
	s.git.remotes = { origin = { "https://github.com/me/r.git" }, upstream = { "https://github.com/o/r.git" } }
	local b = h.openQueue(w)
	eq(w.kv.get("checkouts")["me/r"], "/work/r", "the launch saved the fork")
	eq(line(b, "co:o/r").p.label, "Use /work/r as the checkout", "and detection offers the folder for o/r")
	eq(line(b, "co:o/r").p.value, "o/r", "naming the repository")
	click(b, "co:o/r")
	w.flush()
	eq(w.kv.get("checkouts")["o/r"], "/work/r", "Use saves it")
	eq(w.toasts[#w.toasts].text, "Checkout saved", "and says so")
	eq(line(b, "co:o/r"), nil, "the line is gone")
	eq(countCalls(w, "gh repo clone github.com/o/r /work/r"), 0, "nothing was cloned")
end)

case("host: checkout detection offers another pane's folder on this host, never a folder of another repository, and Use verifies it again", function(w: World)
	hostScene(w, 3)
	fresh(w)
	local wrong = newGit(w, "/code/x")
	wrong.remotes.origin = { "https://github.com/x/y.git" }
	table.insert(w.panes, { pane = 7, cwd = "/code/x" })
	local b = openOutside(w)
	eq(line(b, "co:o/r").p.label, "Choose the checkout of o/r…", "a checkout whose remote is another repository is not offered")
	local right = newGit(w, "/code/r")
	right.remotes.origin = { "git@github.com:o/r.git" }
	w.fs.dirs["/code/r/src"] = true
	table.insert(w.panes, { pane = 8, cwd = "/code/r/src" })
	b.event({ ev = "action", act = "get-started" }) -- asks again at once
	w.flush()
	eq(line(b, "co:o/r").p.label, "Use /code/r as the checkout", "a pane inside a checkout of o/r offers that checkout")
	right.remotes.origin = { "https://github.com/x/z.git" }
	click(b, "co:o/r")
	w.flush()
	eq(w.toasts[#w.toasts].text, "Checkout not saved", "Use verifies the folder again")
	has(w.toasts[#w.toasts].sub, "No remote of /code/r points at github.com/o/r", "and refuses a remote that changed meanwhile")
	eq(w.kv.get("checkouts"), nil, "nothing is saved")
end)

case("host: a pane on another host never counts for checkout detection", function(w: World)
	hostScene(w, 3)
	fresh(w)
	local there = newGit(w, "/code/r")
	there.remotes.origin = { "https://github.com/o/r.git" }
	w.window.panes[9] = { cwd = "/code/r", tab = 1 }
	w.window.hostOf[9] = 2
	local b = openOutside(w)
	eq(line(b, "co:o/r").p.label, "Choose the checkout of o/r…", "the other host's checkout is not offered")
	eq(countCalls(w, "git -C /code/r rev-parse --show-toplevel"), 0, "nor looked at")
end)

windowCase("window: the checklist's checkout line asks for a folder and saves it; a malformed link is refused", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	linkQueue(w, s)
	w.kv.put("checkouts", {})
	w.window.typed = "/work/r"
	w.click("plotroom://checkout/o/r")
	w.flush()
	has(w.window.prompts[1].placeholder, "Folder of your checkout of o/r", "the folder is asked")
	eq(w.kv.get("checkouts")["o/r"], "/work/r", "and saved")
	eq(w.toasts[#w.toasts].text, "Checkout saved", "the user is told")
	w.click("plotroom://checkout/o/r/x")
	w.flush()
	eq(w.toasts[#w.toasts].text, "Plotroom: malformed link", "a link that names no repository is refused")
	eq(#requestsSent(w), 1, "and asks nothing")
end)

windowCase("window: an action on a repository without a checkout offers the detected checkout before asking for a folder", function(w: World)
	local s, b = agentScene(w)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	w.kv.put("checkouts", {})
	b.render()
	cardSurface(w, b)
	w.window.choose = "Use " .. s.root
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	same(asks.rows(w.window.picks[1]), { "Use " .. s.root .. " — A checkout of o/r found open in Tern", "Another folder… — A new or empty folder gets a clone" }, "the checkout found, then any other folder")
	eq(w.kv.get("checkouts")["o/r"], s.root, "Use saves it")
	eq(#w.window.agents, 1, "and the action runs")
	eq(w.window.agents[1].cwd, s.target, "in the item's worktree")
end)

return {}
