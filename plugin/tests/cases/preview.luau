--!strict
-- Regression cases: every preview's parts in one shared order, and the states its loading sections share.

local h = require("../harness")

type Block = h.Block
type World = h.World

local EPOCH, array, asks, case, eq, factOf = h.EPOCH, h.array, h.asks, h.case, h.eq, h.factOf
local findKey, has, hostScene, issueHost, jiraHost, lacks = h.findKey, h.has, h.hostScene, h.issueHost, h.jiraHost, h.lacks
local leaveIssueWt, leaveWt, openIssues, openQueue, pickScope, pickerNode = h.leaveIssueWt, h.leaveWt, h.openIssues, h.openQueue, h.pickScope, h.pickerNode
local pickerOf, same, searchItem, showTab, statOf, yes = h.pickerOf, h.same, h.searchItem, h.showTab, h.statOf, h.yes

-- docs/reference.md › Finer points › Preview: the parts under every preview's head, in order (a pull request's under
-- its Overview tab).
local ORDER = { "status", "worktree", "agent", "description", "properties", "linked", "headpr" }
-- What may sit between the head and the parts: the title row (worktree, agent, Now), the stats and the tabs.
local TOP = { titlerow = true, stats = true, tabs = true }

-- The selected item's preview as its head, its title row, stats and tabs, then each part (by its rule), in the order
-- shown.
local function partsOf(b: Block): { string }
	local out: { string } = {}
	for _, kid in pickerNode(b).c do
		local key = kid.p and kid.p.key
		if key == "head" or TOP[key] then
			table.insert(out, key)
		elseif type(key) == "string" and string.sub(key, 1, 5) == "rule-" then
			table.insert(out, string.sub(key, 6))
		end
	end
	return out
end

-- The Worktrees table's card as partsOf reads a preview: "head" (the card's own), then each part by its rule.
local function cardParts(b: Block): { string }
	local out: { string } = { "head" }
	for _, kid in findKey(pickerNode(b), "worktree", "card").c do
		local key = kid.p and kid.p.key
		if type(key) == "string" and string.sub(key, 1, 5) == "rule-" then
			table.insert(out, string.sub(key, 6))
		end
	end
	return out
end

-- Whether `parts` start with the head and keep ORDER after what sits on top.
local function shared(parts: { string }): boolean
	if parts[1] ~= "head" then
		return false
	end
	local at = 0
	for i = 2, #parts do
		if not TOP[parts[i]] then
			local slot = table.find(ORDER, parts[i])
			if not slot or slot <= at then
				return false
			end
			at = slot
		end
	end
	return true
end

local function texts(b: Block): string
	local out: { string } = {}
	h.collectTexts(pickerNode(b), out)
	return table.concat(out, "\n")
end

case("preview: every variant shows its parts in the one shared order", function(w: World)
	-- a pull request with a worktree, a description, a closing issue, reviewers and checks
	local s = hostScene(w, 1)
	leaveWt(w, s, 1)
	asks.bk.tree(w, s.git, "/wt/free", "free") -- a worktree made for no item
	s.gh.about["o/r#1"] = {
		merge = "BLOCKED",
		body = "Why it changes.",
		reviews = array({ { login = "ann", state = "APPROVED" } }),
		closing = array({ { number = 9, title = "Login fails", url = "https://github.com/o/r/issues/9", state = "OPEN" } }),
	}
	local b = openQueue(w)
	w.advance(300)
	local pr = partsOf(b)
	same(pr, { "head", "stats", "tabs", "status", "worktree", "description", "properties", "linked" }, "a pull request: its Overview")
	yes(shared(pr), "in the shared order")
	for _, tab in { "checks", "threads", "reviewers" } do
		showTab(b, tab)
		same(partsOf(b), { "head", "stats", "tabs", tab }, "its " .. tab .. " tab draws only its own part")
	end
	showTab(b, "overview")
	-- the Agents scope
	asks.hx.agents(b, { ["o/r#1"] = { state = "idle", action = "Implement", branch = "feature", outcome = "pr", verdict = "not", last = "Done" } })
	pickScope(b, "agents")
	w.flush()
	local agent = partsOf(b)
	same(agent, { "head", "titlerow", "status", "agent" }, "an agent: what needs you, then the agent's own facts")
	yes(shared(agent), "in the shared order")
	-- the Worktrees table's card: its parts in the shared order under its own head
	pickScope(b, "worktrees")
	w.flush()
	local wt = cardParts(b)
	yes(shared(wt), "a worktree, in the shared order: " .. table.concat(wt, ","))
	asks.hx.pick(b, "o/r/free")
	local free = cardParts(b)
	yes(shared(free), "a worktree made for no item, in the shared order: " .. table.concat(free, ","))
	eq(free[#free], "properties", "a worktree made for no item ends with its git facts")
end)

case("preview: a GitHub issue keeps the shared order", function(w: World)
	local s = issueHost(w)
	leaveIssueWt(w, s, 12)
	s.gh.issueDetail["o/r#12"] = { body = "Steps.", linked = array({ { number = 45, title = "Fix", url = "https://github.com/o/r/pull/45", state = "OPEN", isDraft = false } }) }
	local b = openIssues(w)
	w.advance(300)
	local issue = partsOf(b)
	same(issue, { "head", "stats", "status", "worktree", "description", "properties", "linked" }, "a GitHub issue: no tabs")
	yes(shared(issue), "in the shared order")
end)

case("preview: a Jira issue keeps the shared order", function(w: World)
	local j = jiraHost(w)
	j.acli.views["ABC-12"] = { key = "ABC-12", fields = { description = { type = "doc", version = 1, content = { { type = "paragraph", content = { { type = "text", text = "Login fails." } } } } } } }
	local b = openIssues(w)
	w.advance(300)
	local jira = partsOf(b)
	same(jira, { "head", "stats", "status", "description", "properties", "linked" }, "a Jira issue")
	yes(shared(jira), "in the shared order")
	eq(findKey(findKey(pickerNode(b), "head", "card"), "meta", "text").p.spans[2].t, " · Jira", "its head names its tracker")
end)

case("preview: a worktree made for a pull request lists it under Linked pull requests, after its facts", function(w: World)
	local s = asks.hx.boardScene(w)
	s.gh.pulls["https://github.com/o/r/pull/5"] = searchItem(5, "o/r", EPOCH - 60, { title = "Fix the board" })
	local b = openQueue(w)
	pickScope(b, "worktrees")
	w.flush()
	w.advance(300)
	w.flush()
	local parts = cardParts(b)
	same(parts, { "head", "properties", "linked" }, "facts, then the item it was made for")
	eq(findKey(pickerNode(b), "pr-head").p.spans[1].t, "Linked pull requests", "under the heading every preview uses")
end)

case("preview: a worktree's linked read that fails is an error row with the tool's message, and its Retry reads it again", function(w: World)
	local s = asks.hx.boardScene(w)
	s.gh.pulls["https://github.com/o/r/pull/5"] = searchItem(5, "o/r", EPOCH - 60, { title = "Fix the board" })
	local failing = true
	s.gh.override = function(req: h.GhReq): h.Reply?
		if req.kind == "pull" and req.fields.q == "https://github.com/o/r/pull/5" and failing then
			return { status = 1, stderr = "gh: Server Error (HTTP 502)\n" }
		end
		return nil
	end
	local b = openQueue(w)
	pickScope(b, "worktrees")
	w.flush()
	w.advance(300)
	w.flush()
	local failed: any = findKey(pickerNode(b), "pr-state", "empty")
	yes(failed ~= nil, "the failed read is an empty under Linked pull requests")
	eq(failed.p.tone, "error", "in the error tone")
	eq(failed.p.title, "Could not load #5", "saying what failed")
	has(failed.p.text, "HTTP 502", "with the tool's message")
	local retry: any = findKey(failed, "pr-retry", "button")
	failing = false
	b.event({ ev = "action", id = "layer.queue.pr-state.pr-retry", act = retry.p.actions.click })
	w.flush()
	w.advance(300)
	w.flush()
	eq(findKey(pickerNode(b), "pr-state", "empty"), nil, "Retry read it again")
	has(texts(b), "Fix the board", "and the pull request shows")
end)

case("preview: loading sections are Tern skeletons shaped like them, a failed load an error empty with the tool's message and Retry, nothing an empty saying what is missing, all alike", function(w: World)
	local s = hostScene(w, 0)
	local failing = true
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 60) }
	s.gh.override = function(req: h.GhReq): h.Reply?
		if req.kind == "checks" and failing then
			return { status = 1, stderr = "gh: Server Error (HTTP 502)\n" }
		end
		return nil
	end
	local b = openQueue(w)
	-- the tab each section is drawn under
	local tabOf: { [string]: string } = { linked = "overview", description = "overview", reviewers = "reviewers", runs = "checks", threads = "threads" }
	local function under(key: string): any
		showTab(b, tabOf[key])
		return pickerNode(b)
	end
	local shapes: { [string]: string } = { linked = "rows", reviewers = "rows", runs = "rows", threads = "rows", description = "text" }
	for key, shape in shapes do
		local sk = findKey(under(key), key, "skeleton")
		yes(sk ~= nil, key .. " loads as a skeleton, keyed like the part it stands for")
		eq(sk.p.shape, shape, key .. "'s skeleton is shaped like it")
		lacks(texts(b), "Loading", key .. "'s tab: no Loading… text: the shapes say it")
	end
	w.advance(300)
	eq(findKey(under("runs"), "runs", "skeleton"), nil, "the skeletons go once the read ends")
	local whats: { [string]: string } = { linked = "linked issues", reviewers = "reviewers", runs = "checks", threads = "unresolved threads" }
	for key, what in whats do
		local e = findKey(under(key), key .. "-state", "empty")
		yes(e ~= nil, key .. ": a failed load is an empty")
		eq(e.p.tone, "error", key .. ": in the error tone")
		eq(e.p.variant, "inline", key .. ": one row in the section")
		eq(e.p.title, "Could not load " .. what, key .. ": saying what failed")
		has(e.p.text, "HTTP 502", key .. ": with the tool's message")
		has(e.p.text, "Trying again at ", key .. ": and when it is tried again")
		eq(findKey(e, key .. "-retry", "button").p.actions.click, "retry-checks", key .. ": its Retry child asks again")
	end
	failing = false
	b.event({ ev = "action", id = "layer.queue.threads-state.threads-retry", act = "retry-checks" })
	w.advance(300)
	local missing: { [string]: string } = { linked = "No linked issues", reviewers = "No reviewers", runs = "No checks", threads = "No unresolved threads" }
	for key, what in missing do
		local e = findKey(under(key), key, "empty")
		lacks(texts(b), "Could not load", key .. ": Retry loaded them")
		yes(e ~= nil, key .. ": nothing in it is an empty")
		eq(e.p.title, what, key .. ": saying what is missing")
		eq(e.p.tone, nil, key .. ": not an error")
	end
end)

case("preview: the merge state shows what the search carried until the details load, Unknown when GitHub has not computed it, and none for a merged pull request", function(w: World)
	local s = hostScene(w, 0)
	s.gh.items.octocat = {
		searchItem(1, "o/r", EPOCH - 60, { merge = "BEHIND" }),
		searchItem(2, "o/r", EPOCH - 120, { state = "MERGED", merge = "UNKNOWN" }),
	}
	s.gh.about["o/r#1"] = { merge = "UNKNOWN" }
	local b = openQueue(w)
	eq(factOf(b, "Merge"), "Behind base", "the search's merge state, before the details load")
	w.advance(300)
	eq(factOf(b, "Merge"), "Unknown", "GitHub not having computed it reads Unknown, never a lasting Checking…")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_232" })
	w.advance(300)
	eq(factOf(b, "Merge"), nil, "a merged pull request has no merge state to show")
end)

case("preview: a pull request lists the issues it closes and the one noted for its worktree under Linked issues, once each", function(w: World)
	local s = hostScene(w, 1)
	s.gh.about["o/r#1"] = {
		closing = array({
			{ number = 9, title = "Login fails", url = "https://github.com/o/r/issues/9", state = "OPEN" },
			{ number = 8, title = "Old bug", url = "https://github.com/o/r/issues/8", state = "CLOSED" },
			{ number = "x", title = "Malformed", url = "https://github.com/o/r/issues/7", state = "OPEN" },
		}),
	}
	local b = openQueue(w)
	w.advance(300)
	local rows: { string } = {}
	for _, item in findKey(pickerNode(b), "noted", "list").c do
		table.insert(rows, item.p.label .. " | " .. item.p.value .. " | " .. item.p.title .. " | " .. string.sub(item.p.href, 1, 22))
	end
	same(rows, {
		"Login fails | #9 | #9 · Open | plotroom://issue/open/",
		"Old bug | #8 | #8 · Closed | plotroom://issue/open/",
	}, "each closing issue with its number and state, opened in a Browser block; a malformed one is dropped")
	has(texts(b), "Linked issues", "under the Linked issues heading")
end)

case("preview: your blocked pull request leads with what blocks it; a review asked of you leads with its author, its size a stat", function(w: World)
	local s = hostScene(w, 0)
	s.gh.items.octocat = {
		searchItem(1, "o/r", EPOCH - 60, { author = "octocat", review = "CHANGES_REQUESTED" }),
		searchItem(2, "o/r", EPOCH - 120, { author = "ann", additions = 10, deletions = 5 }),
	}
	s.gh.about["o/r#2"] = { requested = array({ "octocat" }) }
	local b = openQueue(w)
	w.advance(300)
	local status: any = findKey(pickerNode(b), "stage", "kv")
	eq(status.p.items[1].k .. "/" .. status.p.items[2].k, "Stage/Blocked by", "the status part: the stage, then what blocks it")
	eq(factOf(b, "Blocked by"), "Address changes — Changes requested", "the blocking reason, as its job and what")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_232" })
	w.advance(300)
	local asked: any = findKey(pickerNode(b), "stage", "kv")
	eq(asked.p.items[2].k, "Author", "a review asked of you puts its author under the stage")
	eq(statOf(b, "Changes"), "+10 −5", "its size is the Changes stat")
	eq(findKey(pickerNode(b), "diff"), nil, "and no diff meter is left")
	local facts: any = findKey(pickerNode(b), "facts", "kv")
	for _, f in facts.p.items do
		yes(f.k ~= "Author", "the author is not repeated among the facts")
	end
end)

case("preview: a pull request's head is one card, four stats sit under it, and its tabs draw only the active panel; Tab and Shift+Tab switch them, wrapping, and ← reaches the views", function(w: World)
	local s = hostScene(w, 0)
	local done = "2026-01-01T00:00:00Z"
	local runs = array({
		h.checkRun("build", "COMPLETED", "FAILURE", done, { id = "A" }),
		h.checkRun("lint", "COMPLETED", "SUCCESS", done, { id = "B" }),
		h.checkRun("test", "COMPLETED", "SUCCESS", done, { id = "C" }),
	})
	s.gh.items.octocat = {
		searchItem(1, "o/r", EPOCH - 3 * 86400, { title = "Fix the race", author = "octocat", checks = "FAILURE", runs = runs, runTotal = 3, additions = 214, deletions = 37, comments = 14 }),
		searchItem(2, "o/r", EPOCH - 5 * 86400, { title = "Docs" }),
	}
	s.gh.checks["o/r#1"] = runs
	s.gh.about["o/r#1"] = {
		reviews = array({ { login = "ann", state = "CHANGES_REQUESTED" } }),
		requested = array({ "bob" }),
		threads = array({ { path = "src/a.lua", line = 12, by = "ann", body = "Rename this", url = "https://github.com/o/r/pull/1#discussion_r1" } }),
	}
	local b = openQueue(w)
	w.advance(300)
	-- the head card: the kind's icon, the title, the ref and where it lives, then at its end the state, the Next move,
	-- Copy link and Open
	local head: any = findKey(pickerNode(b), "head", "card")
	eq(head.p.icon, "merge", "a pull request's icon")
	eq(head.p.head, "layer.queue.head.top", "the card's head is its own column")
	eq(findKey(head, "title", "text").p.spans[1].t, "Fix the race", "the title first")
	local meta = findKey(head, "meta", "text").p.spans
	same({ meta[1].t, meta[1].s, meta[2].t }, { "#1 · o/r", "mono", " · GitHub" }, "then the meta line: number and repository in mono, then the integration")
	eq(head.p["end"], "layer.queue.head.end", "its end is the card's own row")
	local tail: { string } = {}
	for _, n in findKey(head, "end", "row").c do
		table.insert(tail, n.k .. ":" .. n.p.key)
	end
	same(tail, { "badge:state", "button:next", "button:copy", "icon:open" }, "the state, the Next move, Copy link and Open, in one row")
	eq(findKey(head, "next", "button").p.size, "sm", "the Next move is a small button")
	eq(findKey(pickerNode(b), "titlerow"), nil, "no title row of its own")
	-- the stats: four tiles, the failing checks in red
	local strip: any = findKey(pickerNode(b), "stats", "stats")
	eq(#strip.p.items, 4, "four tiles")
	same({ statOf(b, "Checks") }, { "1 of 3 failing", "error" }, "Checks: how many fail of all, in red")
	eq(strip.p.items[2].label, "Changes · 3 files", "Changes names how many files")
	eq(statOf(b, "Changes"), "+214 −37", "and the lines added and removed")
	eq(statOf(b, "Comments"), "14", "Comments")
	eq(statOf(b, "Age"), "3d", "Age: since it was opened")
	local facts: { string } = {}
	for _, f in findKey(pickerNode(b), "facts", "kv").p.items do
		table.insert(facts, f.k)
	end
	same(facts, { "Merge", "Author", "Updated" }, "no fact repeats a stat or the head: no Repository, Checks, Comments or Opened")
	-- the tabs: counts once known, only the active panel drawn
	local function tabs(): any
		return findKey(pickerNode(b), "tabs", "tabs").p
	end
	local labels: { string } = {}
	for _, t in tabs().items do
		local text: { string } = {}
		for _, sp in t.label do
			table.insert(text, sp.t)
		end
		table.insert(labels, t.id .. "=" .. table.concat(text))
	end
	same(labels, { "overview=Overview", "checks=Checks 3", "threads=Threads 1", "reviewers=Reviewers 2" }, "Overview, then each tab with its count")
	eq(tabs().active, "overview", "Overview is shown first")
	eq(tabs().variant, nil, "the underline strip, Tern's default")
	yes(findKey(pickerNode(b), "runs") == nil and findKey(pickerNode(b), "threads") == nil and findKey(pickerNode(b), "reviewers") == nil, "Overview draws neither the checks, the threads nor the reviewers")
	b.press("tab")
	eq(tabs().active, "checks", "Tab: the next tab")
	yes(findKey(pickerNode(b), "failing", "table") ~= nil, "the Checks tab draws the checks")
	eq(findKey(pickerNode(b), "description"), nil, "and nothing of Overview")
	b.press("tab")
	eq(findKey(pickerNode(b), "run1", "item").p.label, "Rename this", "the Threads tab draws the unresolved threads")
	b.press("tab")
	eq(#findKey(pickerNode(b), "reviewers", "list").c, 2, "the Reviewers tab, each reviewer a row")
	b.press("tab")
	eq(tabs().active, "overview", "Tab wraps round to Overview")
	b.press("tab", "s")
	eq(tabs().active, "reviewers", "Shift+Tab goes back, wrapping the other way")
	eq(pickerOf(b).focus, "list", "and the keys stay in the list")
	b.event({ ev = "select", id = "layer.queue.tabs", item = "threads" })
	eq(tabs().active, "threads", "a click on a tab shows it")
	b.event({ ev = "select", id = "layer.queue.tabs", item = "bogus" })
	eq(tabs().active, "threads", "a tab that does not exist changes nothing")
	b.press("down")
	eq(tabs().active, "threads", "the tab stays as the selection moves")
	b.press("left")
	eq(pickerOf(b).focus, "scopes", "← moves to the views")
	b.press("tab")
	eq(pickerOf(b).focus, "list", "Tab there goes back to the pull requests")
	eq(tabs().active, "threads", "without switching the tab")
end)

return {}
