--!strict
-- Regression cases: every preview's parts in one shared order, and the states its loading sections share.

local h = require("../harness")

type Block = h.Block
type World = h.World

local EPOCH, array, asks, case, eq, factOf = h.EPOCH, h.array, h.asks, h.case, h.eq, h.factOf
local findKey, has, hostScene, issueHost, jiraHost, lacks = h.findKey, h.has, h.hostScene, h.issueHost, h.jiraHost, h.lacks
local leaveIssueWt, leaveWt, openIssues, openQueue, pickScope, pickerNode = h.leaveIssueWt, h.leaveWt, h.openIssues, h.openQueue, h.pickScope, h.pickerNode
local same, searchItem, yes = h.same, h.searchItem, h.yes

-- docs/reference.md › Finer points › Preview: the parts under every preview's head and title, in order.
local ORDER = { "status", "worktree", "agent", "description", "properties", "linked", "headpr", "reviewers", "checks" }

-- The selected item's preview as its head, its title, then each part (by its rule), in the order shown.
local function partsOf(b: Block): { string }
	local out: { string } = {}
	for _, kid in pickerNode(b).c do
		local key = kid.p and kid.p.key
		if key == "head" or key == "titlerow" then
			table.insert(out, key)
		elseif type(key) == "string" and string.sub(key, 1, 5) == "rule-" then
			table.insert(out, string.sub(key, 6))
		end
	end
	return out
end

-- Whether `parts` start with the head and title and keep ORDER after them.
local function shared(parts: { string }): boolean
	if parts[1] ~= "head" or parts[2] ~= "titlerow" then
		return false
	end
	local at = 0
	for i = 3, #parts do
		local slot = table.find(ORDER, parts[i])
		if not slot or slot <= at then
			return false
		end
		at = slot
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
	same(pr, { "head", "titlerow", "status", "worktree", "description", "properties", "linked", "reviewers", "checks" }, "a pull request")
	yes(shared(pr), "in the shared order")
	-- the Agents scope
	asks.hx.agents(b, { ["o/r#1"] = { state = "idle", action = "Implement", branch = "feature", outcome = "pr", verdict = "not", last = "Done" } })
	pickScope(b, "agents")
	w.flush()
	local agent = partsOf(b)
	same(agent, { "head", "titlerow", "status", "agent" }, "an agent: what needs you, then the agent's own facts")
	yes(shared(agent), "in the shared order")
	-- the Worktrees board
	pickScope(b, "worktrees")
	w.flush()
	local wt = partsOf(b)
	yes(shared(wt), "a worktree, in the shared order: " .. table.concat(wt, ","))
	b.event({ ev = "select", id = "layer.queue", item = asks.hx.rowId(b, "o/r/free") })
	local free = partsOf(b)
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
	same(issue, { "head", "titlerow", "status", "worktree", "description", "properties", "linked" }, "a GitHub issue")
	yes(shared(issue), "in the shared order")
end)

case("preview: a Jira issue keeps the shared order", function(w: World)
	local j = jiraHost(w)
	j.acli.views["ABC-12"] = { key = "ABC-12", fields = { description = { type = "doc", version = 1, content = { { type = "paragraph", content = { { type = "text", text = "Login fails." } } } } } } }
	local b = openIssues(w)
	w.advance(300)
	local jira = partsOf(b)
	same(jira, { "head", "titlerow", "status", "description", "properties", "linked" }, "a Jira issue")
	yes(shared(jira), "in the shared order")
	eq(findKey(findKey(pickerNode(b), "head"), "integration").p.text, "Jira", "its head names its tracker")
end)

case("preview: a worktree made for a pull request lists it under Linked pull requests, after its facts", function(w: World)
	local s = asks.hx.boardScene(w)
	s.gh.pulls["https://github.com/o/r/pull/5"] = searchItem(5, "o/r", EPOCH - 60, { title = "Fix the board" })
	local b = openQueue(w)
	pickScope(b, "worktrees")
	w.flush()
	w.advance(300)
	w.flush()
	local parts = partsOf(b)
	same(parts, { "head", "titlerow", "properties", "linked" }, "facts, then the item it was made for")
	eq(findKey(pickerNode(b), "pr-head").p.spans[1].t, "Linked pull requests", "under the heading every preview uses")
	eq(findKey(findKey(pickerNode(b), "head"), "integration").p.text, "Worktree", "its head names what it is")
end)

case("preview: the loading sections say Loading, then on a failed load why with Retry, else No <what>, all alike", function(w: World)
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
	local loading = texts(b)
	has(loading, "Loading linked issues…", "the linked issues shimmer")
	has(loading, "Loading reviewers…", "the reviewers")
	has(loading, "Loading checks…", "and the checks")
	w.advance(300)
	local failed = texts(b)
	has(failed, "Could not load linked issues: ", "a failed load says so under Linked issues")
	has(failed, "Could not load reviewers: ", "under Reviewers: they no longer vanish")
	has(failed, "Could not load checks: ", "and under Checks")
	for _, key in { "linked-retry", "reviewers-retry", "runs-retry" } do
		eq(findKey(pickerNode(b), key, "item").p.actions.click, "retry-checks", key .. " asks again")
	end
	failing = false
	h.refreshNow(w, b)
	w.advance(300)
	local empty = texts(b)
	lacks(empty, "Could not load", "the retry loaded them")
	has(empty, "No linked issues", "an empty section says so")
	has(empty, "No reviewers", "Reviewers too")
	has(empty, "No checks", "and Checks")
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

case("preview: your blocked pull request leads with what blocks it; a review asked of you leads with its author and size", function(w: World)
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
	eq(factOf(b, "Blocked by"), "Changes requested", "the blocking reason")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_232" })
	w.advance(300)
	local asked: any = findKey(pickerNode(b), "stage", "kv")
	eq(asked.p.items[2].k, "Author", "a review asked of you puts its author under the stage")
	yes(findKey(asked, "diff") == nil and findKey(findKey(pickerNode(b), "about"), "diff") == nil, "the size sits in the status part, not the facts")
	local facts: any = findKey(pickerNode(b), "facts", "kv")
	for _, f in facts.p.items do
		yes(f.k ~= "Author", "the author is not repeated among the facts")
	end
	local parts = pickerNode(b).c
	local statusAt, diffAt, propsAt = 0, 0, 0
	for i, kid in parts do
		statusAt = if kid.p and kid.p.key == "rule-status" then i else statusAt
		diffAt = if kid.p and kid.p.key == "diff" then i else diffAt
		propsAt = if kid.p and kid.p.key == "rule-properties" then i else propsAt
	end
	yes(statusAt < diffAt and diffAt < propsAt, "the diff meter sits in the status part, above the facts")
end)

return {}
