--!strict
-- Regression cases: the Draft review block (host/review.luau), the window opening it at a turn end and its Send.

local h = require("../harness")

type Block = h.Block
type World = h.World

local array, asks, case, collectTexts, eq, findKey = h.array, h.asks, h.case, h.collectTexts, h.eq, h.findKey
local has, jsonDecode, jsonEncode, lacks, same, sha, windowCase, yes = h.has, h.jsonDecode, h.jsonEncode, h.lacks, h.same, h.sha, h.windowCase, h.yes

local AT1, AT2 = "2026-11-04T10:00:00.000Z", "2026-11-04T11:00:00.000Z"
local HEAD = sha("c")
local FILE = "/data/plotroom/runs/r1/review.json"

-- src/a.lua: old lines 1-4, new lines 1-5 (new 2 and 3 added, old 2 removed); README.md: new line 11 added.
local DIFF = table.concat({
	"diff --git a/src/a.lua b/src/a.lua",
	"index 1111111..2222222 100644",
	"--- a/src/a.lua",
	"+++ b/src/a.lua",
	"@@ -1,4 +1,5 @@",
	" local x = 1",
	"-local y = 2",
	"+local y = 3",
	"+local z = 4",
	" return x",
	" -- end",
	"diff --git a/README.md b/README.md",
	"--- a/README.md",
	"+++ b/README.md",
	"@@ -10,2 +10,3 @@",
	" intro",
	"+new line",
	" outro",
	"",
}, "\n")

local function proposal(at: string?): { [string]: any }
	return {
		version = 1,
		run = "r1",
		at = at or AT1,
		repo = "o/r",
		number = 5,
		head = HEAD,
		summary = "Two problems.",
		verdict = "comment",
		comments = array({
			{ id = "c1", path = "src/a.lua", line = 3, side = "RIGHT", kind = "problem", body = "z is unused" },
			{ id = "c2", path = "README.md", line = 11, side = "RIGHT", kind = "nit", body = "Typo" },
			{ id = "c3", path = "src/a.lua", line = 40, side = "RIGHT", kind = "question", body = "Why?" },
			{ id = "c4", path = "src/a.lua", line = 2, side = "LEFT", kind = "suggestion", body = "Keep 2", suggestion = "local y = 2" },
		}),
	}
end

-- The checkout of o/r with the worktree /wt/r5 at HEAD; gh answers the pull request (by octo) with head `prHead` (HEAD)
-- on base main, which the remote serves at sha("1"), and git the diff; gh's active login is `active` (octocat). Returns
-- the diff commands run and the checkout.
local function reviewScene(w: World, prHead: string?, active: string?): ({ string }, h.Git)
	local g = asks.bk.repo(w)
	asks.bk.tree(w, g, "/wt/r5", "fix-5", HEAD)
	g.served["refs/heads/main"] = sha("1")
	local diffs: { string } = {}
	w.respond(function(call: h.Call): h.Reply?
		local a = call.argv
		if a[1] == "gh" and table.find(a, "repos/o/r/pulls/5") then
			return { stdout = jsonEncode({ base = "o/r", sha = prHead or HEAD, ref = "fix-5", headRepo = "o/r", state = "open", baseRef = "main", title = "Fix", author = "octo" }) }
		elseif a[1] == "gh" and a[2] == "auth" and a[3] == "status" then
			return { stdout = jsonEncode({ hosts = { ["github.com"] = array({ { login = active or "octocat", active = true, state = "success" } }) } }) }
		elseif a[1] == "gh" and a[2] == "auth" and a[3] == "token" then
			return { stdout = "gho_token\n" }
		elseif a[1] == "git" and a[4] == "diff" then
			table.insert(diffs, table.concat(a, " "))
			return { stdout = DIFF }
		end
		return nil
	end)
	w.fs.files[FILE] = jsonEncode(proposal())
	return diffs, g
end

local function openReview(w: World, pane: number?, login: string?): Block
	w.load("host")
	local b = w.openReview(pane or 2, { "r1", "/wt/r5", login :: any })
	w.flush()
	return b
end

local function textOf(node: any): string
	local out: { string } = {}
	collectTexts(node, out)
	return table.concat(out, "\n")
end


-- The choices the block's last Send carries (hidden main.send): the message's JSON block, decoded, and the text.
local function sentChoices(b: Block): (any, string)
	local node = findKey(b.view().main, "send", "text")
	yes(node, "the block publishes main.send")
	local o: any = jsonDecode(node.p.text)
	local json = string.match(o.text, "```json\n(.-)\n```")
	return jsonDecode(json :: string), o.text
end

local function navRows(b: Block): { any }
	return findKey(b.view().main, "nav", "list").c
end

-- The nav item keys in order, and what row i says it is (Kept/Dropped).
local function navKeys(b: Block): { string }
	local out: { string } = {}
	for _, it in navRows(b) do
		table.insert(out, it.p.key)
	end
	return out
end

local function navState(b: Block, i: number): string
	return navRows(b)[i + 1].p.value[1].t
end

local function selectedOf(b: Block): string
	return findKey(b.view().main, "nav", "list").p.selected
end

local function detailText(b: Block): string
	return textOf(findKey(b.view().main, "detail"))
end

local function clean(b: Block, why: string)
	same(h.hx.miscued(b.view().main), {}, why .. ": every click has its button look and nothing else does")
	same(h.hx.offPalette(b.view().main), {}, why .. ": nothing is coloured outside DESIGN.md")
end

case("review: the navigator lists the summary, the comments grouped by file, then the instructions; one off the diff cannot be kept", function(w: World)
	local diffs = reviewScene(w)
	local b = openReview(w)
	eq(b.title(), "Draft review · o/r#5", "titled by its pull request")
	same(diffs, { "git -C /wt/r5 diff --no-color --no-ext-diff -U3 --src-prefix=a/ --dst-prefix=b/ refs/remotes/origin/main..." .. HEAD .. " --" }, "the diff of the reviewed head against the base, where the agent worked, argv only")
	local main = b.view().main
	eq(findKey(main, "run", "text").p.text, "r1", "the run is published for the window")
	same(navKeys(b), { "n0", "n1", "n2", "n3", "n4", "n5" }, "summary, four comments, instructions")
	same({ navState(b, 1), navState(b, 4) }, { "Kept", "Dropped" }, "on the diff starts kept, off it dropped")
	eq(selectedOf(b), "main.body.nav.n0", "the summary is selected first")
	-- Only the selected item's detail is drawn.
	lacks(detailText(b), "z is unused", "the summary's detail holds no comment")
	b.event({ ev = "select", id = "main.body.nav", item = "main.body.nav.n2" })
	has(detailText(b), "Keep 2", "the second row is c4: file order")
	b.event({ ev = "select", id = "main.body.nav", item = "main.body.nav.n4" })
	has(detailText(b), "Why?", "the last row is the one off the diff")
	b.event({ ev = "select", id = "main.body.nav", item = "main.body.nav.n1" })
	local d = findKey(findKey(b.view().main, "detail"), "diff", "col").c[1]
	eq(d.k, "diff", "Tern's diff node")
	eq(d.p.text, "--- a/src/a.lua\n+++ b/src/a.lua\n@@ -1,4 +1,5 @@\n local x = 1\n-local y = 2\n+local y = 3\n+local z = 4\n return x\n -- end\n", "the diff of the rows around the line")
	eq(d.p.path, "src/a.lua", "highlighted as its file")
	has(detailText(b), "z is unused", "and the comment")
	b.event({ ev = "select", id = "main.body.nav", item = "main.body.nav.n3" })
	yes(findKey(findKey(b.view().main, "detail"), "diff", "col"), "a LEFT comment on a removed line is on the diff too")
	-- j to c3 (the 4th comment), where Space is refused with why.
	b.typeText("j")
	has(detailText(b), "Why?", "c3 is selected")
	has(detailText(b), "Not on a changed line", "and says it cannot be kept")
	lacks(textOf(findKey(findKey(b.view().main, "detail"), "buttons")), "Keep", "with no Keep button")
	b.typeText(" ")
	eq(w.toasts[#w.toasts].text, "Not on a changed line", "Space on it says why it cannot be kept")
	eq(navState(b, 4), "Dropped", "and it stays dropped")
	clean(b, "the loaded review")
	w.finish()
end)

case("review: with a stale local base ref the diff is read against the base's tip now, as GitHub's is", function(w: World)
	local diffs, g = reviewScene(w)
	local tracking = "refs/remotes/origin/main"
	-- The checkout last fetched main at sha("0"); the remote's main is sha("1"), which the pull request merged. Against the
	-- old merge-base the diff also holds the base's newer commit (src/base.lua line 5); against the tip only the PR's own.
	g.refs[tracking] = sha("0")
	local stale = DIFF .. table.concat({ "diff --git a/src/base.lua b/src/base.lua", "--- a/src/base.lua", "+++ b/src/base.lua", "@@ -4,2 +4,3 @@", " four", "+five", " six", "" }, "\n")
	w.respond(function(call: h.Call): h.Reply?
		local a = call.argv
		if a[1] == "git" and a[4] == "diff" then
			table.insert(diffs, table.concat(a, " "))
			return { stdout = if g.refs[tracking] == sha("1") then DIFF else stale }
		end
		return nil
	end)
	local p = proposal()
	p.comments = array({
		{ id = "c1", path = "src/a.lua", line = 3, side = "RIGHT", kind = "problem", body = "z is unused" },
		{ id = "c5", path = "src/base.lua", line = 5, side = "RIGHT", kind = "nit", body = "Base's own line" },
	})
	w.fs.files[FILE] = jsonEncode(p)
	local b = openReview(w)
	eq(h.countLog(g, "fetch --no-tags --no-write-fetch-head origin +refs/heads/main:" .. tracking), 1, "the base is fetched")
	eq(g.refs[tracking], sha("1"), "to the remote's tip")
	eq(#diffs, 1, "before the one diff is read")
	same(navKeys(b), { "n0", "n1", "n2", "n3" }, "summary, two comments, instructions")
	b.event({ ev = "select", id = "main.body.nav", item = "main.body.nav.n1" })
	has(detailText(b), "z is unused", "the PR's own line is first")
	eq(navState(b, 1), "Kept", "placed and kept")
	yes(findKey(findKey(b.view().main, "detail"), "diff", "col"), "with its diff excerpt")
	b.event({ ev = "select", id = "main.body.nav", item = "main.body.nav.n2" })
	has(detailText(b), "Base's own line", "the base-only line")
	has(detailText(b), "Not on a changed line", "is not on the pull request's diff")
	eq(navState(b, 2), "Dropped", "and cannot be kept")
	w.finish()
end)

case("review: a comment on a file whose path has a space is placed, though git ends its header lines with a tab", function(w: World)
	local diffs = reviewScene(w)
	-- As git writes it: a path holding a space ends its ---/+++ lines with a tab, which is not part of the path.
	local spaced = DIFF .. table.concat({ "diff --git a/a b.txt b/a b.txt", "new file mode 100644", "index 0000000..587be6b", "--- /dev/null", "+++ b/a b.txt\t", "@@ -0,0 +1 @@", "+x", "" }, "\n")
	w.respond(function(call: h.Call): h.Reply?
		local a = call.argv
		if a[1] == "git" and a[4] == "diff" then
			table.insert(diffs, table.concat(a, " "))
			return { stdout = spaced }
		end
		return nil
	end)
	local p = proposal()
	p.comments = array({ { id = "c1", path = "a b.txt", line = 1, side = "RIGHT", kind = "nit", body = "Say y" } })
	w.fs.files[FILE] = jsonEncode(p)
	local b = openReview(w)
	eq(navState(b, 1), "Kept", "placed and kept")
	b.event({ ev = "select", id = "main.body.nav", item = "main.body.nav.n1" })
	local d = findKey(findKey(b.view().main, "detail"), "diff", "col").c[1]
	eq(d.p.path, "a b.txt", "with its diff excerpt, on the path without the tab")
	has(d.p.text, "+x", "around its line")
	local toasts = #w.toasts
	b.typeText(" ")
	eq(navState(b, 1), "Dropped", "Space drops it")
	b.typeText(" ")
	eq(navState(b, 1), "Kept", "and keeps it again")
	for i = toasts + 1, #w.toasts do
		yes(w.toasts[i].text ~= "Not on a changed line", "with no Not on a changed line toast")
	end
	w.finish()
end)

case("review: a base that cannot be fetched is said, not read stale", function(w: World)
	local diffs, g = reviewScene(w)
	g.served["refs/heads/main"] = nil
	local b = openReview(w)
	has(textOf(b.view().main), "The diff could not be read", "the block says so")
	same(diffs, {}, "and reads no diff")
	w.finish()
end)

case("review: keys and clicks pick, edit, keep and drop; Send carries the kept comments as edited, the dropped ids, verdict, summary and instructions", function(w: World)
	reviewScene(w)
	local b = openReview(w)
	-- The summary is first: e edits it, Done leaves.
	b.typeText("e")
	yes(findKey(findKey(b.view().main, "detail"), "text", "editor"), "e on the summary opens its editor")
	clean(b, "editing the summary")
	b.typeText(" Fix both.")
	b.event({ ev = "action", act = "done" })
	lacks(textOf(findKey(b.view().main, "detail")), "Done", "Done leaves the editor")
	-- c1: edit its body.
	b.typeText("j")
	eq(selectedOf(b), "main.body.nav.n1", "j moves the selection")
	b.typeText("e")
	b.press("backspace")
	b.typeText("d here")
	b.press("escape")
	-- c4: drop it with a click on its Drop button.
	b.typeText("j")
	b.event({ ev = "action", act = "keep", value = "2" })
	eq(navState(b, 2), "Dropped", "Drop drops the comment")
	b.event({ ev = "action", act = "keep", value = "2" })
	eq(navState(b, 2), "Kept", "and Keep keeps it again")
	b.typeText(" ")
	eq(navState(b, 2), "Dropped", "Space drops the selected comment")
	-- Request changes.
	b.typeText("3")
	eq(findKey(b.view().main, "request_changes", "item").p.icon, "check", "3 picks Request changes")
	eq(findKey(b.view().main, "comment", "item").p.icon, nil, "and only it has the check")
	has(textOf(findKey(b.view().main, "count")), "2 kept · 2 dropped", "the count follows")
	-- The instructions are last: Edit instructions opens them.
	local edit: any = findKey(b.view().main, "edit", "item")
	yes(h.hx.ternIcon(edit.p.icon), "the Edit button wears an icon Tern draws: " .. tostring(edit.p.icon))
	b.event({ ev = "select", id = "main.body.nav", item = "main.body.nav.n5" })
	b.event({ ev = "action", act = "edit", value = "5" })
	b.typeText("tone down c1")
	b.press("enter", "m")
	local opened = w.opened[#w.opened]
	eq(string.match(opened, "^(plotroom://review/send)%?k=%x+$"), "plotroom://review/send", "⌘↵ asks the window to send it")
	local choices, text = sentChoices(b)
	eq(choices.verdict, "request_changes", "the verdict picked")
	eq(choices.summary, "Two problems. Fix both.", "the summary as edited")
	same(choices.comments, { { id = "c1", path = "src/a.lua", line = 3, side = "RIGHT", body = "z is unuse" .. "d here" }, { id = "c2", path = "README.md", line = 11, side = "RIGHT", body = "Typo" } }, "the kept comments exactly as edited")
	same(choices.dropped, { "c4", "c3" }, "the dropped ids, the one off the diff included")
	same({ choices.repo, choices.number, choices.head } :: { any }, { "o/r", 5, HEAD } :: { any }, "for the pull request and head reviewed")
	has(text, "My instructions: tone down c1", "the typed instructions go with it")
	lacks(text, "head moved", "the head did not move")
	yes(findKey(b.view().main, "sending"), "it shows it is sending")
	b.typeText("3")
	b.event({ ev = "action", act = "edit", value = "1" })
	b.event({ ev = "action", act = "verdict", value = "approve" })
	eq(sentChoices(b).verdict, "request_changes", "while sending the verdict stays")
	clean(b, "sending")
	b.event({ ev = "action", act = "sent" })
	yes(findKey(b.view().main, "sent", "badge"), "the window's answer: Sent")
	b.event({ ev = "select", id = "main.body.nav", item = "main.body.nav.n1" })
	b.typeText("k ")
	eq(navState(b, 1), "Kept", "after Send nothing changes")
	eq(findKey(b.view().main, "send", "item"), nil, "and there is no second Send")
	clean(b, "sent")
	eq(b.saved().sent, AT1, "it stays Sent after a restart")
	w.finish()
end)

-- The verdict buttons the decision row offers, in order, and the one with the check.
local function verdicts(b: Block): ({ string }, string?)
	local keys: { string } = {}
	local on: string? = nil
	for _, v in { "comment", "approve", "request_changes" } do
		local node = findKey(findKey(b.view().main, "bar", "row"), v, "item")
		if node then
			table.insert(keys, v)
			on = if node.p.icon == "check" then v else on
		end
	end
	return keys, on
end

case("review: on your own pull request only Comment is offered, and keys and actions cannot pick another", function(w: World)
	reviewScene(w)
	local b = openReview(w, nil, "Octo")
	local keys, on = verdicts(b)
	same(keys, { "comment" }, "only Comment is offered on a pull request by the block's login (any case)")
	eq(on, "comment", "and it is picked")
	for _, k in { "2", "3" } do
		b.typeText(k)
		eq(select(2, verdicts(b)), "comment", k .. " leaves the verdict Comment")
	end
	for _, v in { "approve", "request_changes" } do
		b.event({ ev = "action", act = "verdict", value = v })
		eq(select(2, verdicts(b)), "comment", "verdict=" .. v .. " leaves the verdict Comment")
	end
	clean(b, "own pull request")
	b.press("enter", "m")
	eq(sentChoices(b).verdict, "comment", "Send carries Comment")
	w.finish()
end)

for _, proposed in { "approve", "request_changes" } do
	case("review: a proposed " .. proposed .. " on your own pull request opens as Comment, says why and sends Comment", function(w: World)
		-- with no login the block takes gh's active one
		reviewScene(w, nil, "octo")
		local p = proposal()
		p.verdict = proposed
		w.fs.files[FILE] = jsonEncode(p)
		local b = openReview(w)
		local keys, on = verdicts(b)
		same(keys, { "comment" }, "only Comment is offered")
		eq(on, "comment", "Comment is selected")
		local own = findKey(b.view().main, "own", "text")
		has(textOf(own), "GitHub refuses Approve and Request changes on it", "a line says why")
		eq(own.p.spans[1].s, "muted", "muted")
		b.press("enter", "m")
		local choices, text = sentChoices(b)
		eq(choices.verdict, "comment", "Send carries Comment")
		has(text, '"verdict":"comment"', "the message's JSON says comment")
		w.finish()
	end)
end

case("review: on someone else's pull request all three verdicts are offered and 1/2/3 pick each", function(w: World)
	reviewScene(w)
	local p = proposal()
	p.verdict = "approve"
	w.fs.files[FILE] = jsonEncode(p)
	local b = openReview(w, nil, "octocat")
	local keys, on = verdicts(b)
	same(keys, { "comment", "approve", "request_changes" }, "every verdict is offered")
	eq(on, "approve", "the proposed verdict is picked")
	eq(findKey(b.view().main, "own"), nil, "and nothing says otherwise")
	for i, v in { "comment", "approve", "request_changes" } do
		b.typeText(tostring(i))
		eq(select(2, verdicts(b)), v, i .. " picks " .. v)
	end
	b.event({ ev = "action", act = "verdict", value = "approve" })
	eq(select(2, verdicts(b)), "approve", "verdict=approve picks Approve")
	b.press("enter", "m")
	eq(sentChoices(b).verdict, "approve", "Send carries it")
	w.finish()
end)

case("review: nothing is edited, kept or sent while the diff loads", function(w: World)
	reviewScene(w)
	w.load("host")
	local b = w.openReview(2, { "r1", "/wt/r5" })
	b.event({ ev = "select", id = "main.body.nav", item = "main.body.nav.n1" })
	local placeholder: any = findKey(b.view().main, "diff", "skeleton")
	eq(placeholder and placeholder.p.shape, "block", "a skeleton stands where the comment's diff goes while it is read")
	lacks(textOf(b.view().main), "Reading the diff", "with no spinner line")
	b.typeText("e ")
	lacks(detailText(b), "Done", "a comment cannot be edited yet")
	eq(navState(b, 1), "Kept", "nor kept or dropped")
	local before = #w.opened
	b.press("enter", "m")
	eq(#w.opened, before, "nor sent")
	clean(b, "loading")
	w.flush()
	eq(findKey(b.view().main, "diff", "skeleton"), nil, "the loaded diff takes its place")
	yes(findKey(b.view().main, "diff", "col") ~= nil, "under the same key")
	eq(navState(b, 1), "Kept", "the loaded review starts as proposed")
	w.finish()
end)

case("review: a head that moved since the review is said, and Send asks the agent to check the new commits first", function(w: World)
	reviewScene(w, sha("e"))
	local b = openReview(w)
	same(findKey(b.view().main, "moved", "text").p.spans[2], { t = "eeeeeee", s = "mono" }, "the block says so, the SHA a machine string")
	b.press("enter", "m")
	local _, text = sentChoices(b)
	has(text, "head moved to eeeeeeeeeeee since your review: check the new commits first", "and Send asks for it")
	w.finish()
end)

case("review: both blocks open in Tern's sans face, and the Draft review's pull request and head SHA stay mono", function(w: World)
	reviewScene(w)
	local b = openReview(w)
	eq(w.blocks.prs.font, "sans", "the queue block")
	eq(w.blocks.review.font, "sans", "the Draft review block")
	same(findKey(b.view().main, "head", "text").p.spans, {
		{ t = "o/r#5", s = "mono" },
		{ t = "  ·  Draft review of ", s = "muted" },
		{ t = string.sub(HEAD, 1, 7), s = "mono" },
	}, "the head line's machine strings are mono spans, its prose sans")
	w.finish()
end)

case("review: a head named by a short SHA has not moved while the PR's head starts with it", function(w: World)
	reviewScene(w)
	local p = proposal()
	p.head = string.upper(string.sub(HEAD, 1, 7))
	w.fs.files[FILE] = jsonEncode(p)
	local b = openReview(w)
	eq(findKey(b.view().main, "moved", "text"), nil, "the block says nothing about the head moving")
	b.press("enter", "m")
	local _, text = sentChoices(b)
	lacks(text, "head moved", "and Send does not ask to check new commits")
	w.finish()
end)

case("review: a short SHA that is not the start of the PR's head has moved", function(w: World)
	reviewScene(w, sha("e"))
	local p = proposal()
	p.head = string.sub(HEAD, 1, 7)
	w.fs.files[FILE] = jsonEncode(p)
	local b = openReview(w)
	same(findKey(b.view().main, "moved", "text").p.spans[2], { t = "eeeeeee", s = "mono" }, "the block says so")
	b.press("enter", "m")
	local _, text = sentChoices(b)
	has(text, "head moved to eeeeeeeeeeee since your review: check the new commits first", "and Send asks for it")
	w.finish()
end)

case("review: the block reads the heads plotroom_propose_review accepts, 7 to 64 hex digits, and no others", function(w: World)
	local review = w.load("host/review") :: any
	local function read(head: string): (any, string?)
		local p = proposal()
		p.head = head
		return review.parse(jsonEncode(p))
	end
	for _, head in { "abc1234", "ABC1234", string.rep("a", 64) } do
		yes(read(head), "reads head " .. head)
	end
	for _, head in { "abc123", string.rep("a", 65), "abc123g" } do
		local got, why = read(head)
		eq(got, nil, "refuses head " .. head)
		eq(why, "The Draft review file is malformed.", "as malformed: " .. head)
	end
	w.finish()
end)

case("review: a reload keeps your edits for the same proposal and starts over for a revised one; a gone agent gets Copy", function(w: World)
	reviewScene(w)
	local b = openReview(w)
	b.typeText("j ")
	b.event({ ev = "action", act = "reload" })
	w.flush()
	eq(navState(b, 1), "Dropped", "the same file: the choice stays")
	local revised = proposal(AT2)
	revised.summary = "Revised."
	w.fs.files[FILE] = jsonEncode(revised)
	b.event({ ev = "action", act = "reload" })
	w.flush()
	eq(navState(b, 1), "Kept", "a revised proposal starts over")
	has(detailText(b), "Revised.", "with its summary")
	b.press("enter", "m")
	local _, text = sentChoices(b)
	b.event({ ev = "action", act = "gone", value = "The agent that proposed this review is gone." })
	has(textOf(findKey(b.view().main, "gone")), "The agent that proposed this review is gone.", "the block says why")
	clean(b, "a gone agent")
	b.typeText("c")
	eq(w.copied[#w.copied], text, "c copies the message for the agent")
	w.finish()
end)

case("review: a reload onto a file Plotroom cannot read shows why in the error tone and Send sends nothing of the old proposal", function(w: World)
	reviewScene(w)
	local b = openReview(w)
	yes(findKey(b.view().main, "send", "item"), "proposal A is sendable")
	local wrong = proposal(AT2)
	wrong.version = 2
	local bad = proposal(AT2)
	bad.comments[1].side = nil
	local files: { { file: { [string]: any }, why: string } } = {
		{ file = wrong, why = "The Draft review file is not one Plotroom reads (version 1)." },
		{ file = bad, why = "Comment 1 of the Draft review file is malformed." },
	}
	for _, f in files do
		w.fs.files[FILE] = jsonEncode(f.file)
		b.event({ ev = "action", act = "reload" })
		w.flush()
		local problem: any = findKey(b.view().main, "problem", "text")
		yes(problem, "the block says why: " .. f.why)
		eq(problem.p.spans[1].t, f.why, "the file's reason")
		eq(problem.p.spans[1].s, "error", "in the error tone")
		eq(findKey(b.view().main, "send", "item"), nil, "no Send button for the old proposal")
		eq(b.title(), "Draft review", "nor its title")
		local before = #w.opened
		b.press("enter", "m")
		b.event({ ev = "action", act = "send" })
		w.flush()
		eq(#w.opened, before, "Send by key or button opens nothing")
		eq(findKey(b.view().main, "send", "text"), nil, "and publishes no main.send")
	end
	w.fs.files[FILE] = jsonEncode(proposal(AT2))
	b.event({ ev = "action", act = "reload" })
	w.flush()
	yes(findKey(b.view().main, "send", "item"), "a readable file again is sendable")
	w.finish()
end)

case("review: the window's review request answers when the run's Draft review file was written", function(w: World)
	h.hostScene(w)
	local b = h.openQueue(w)
	w.fs.files[FILE] = jsonEncode(proposal())
	h.request(b, "q1", { op = "review", run = "r1" })
	same(h.answerOf(b, "q1"), { at = AT1 }, "the file's at")
	h.request(b, "q2", { op = "review", run = "r2" })
	same(h.answerOf(b, "q2"), {}, "no file: no at")
	h.request(b, "q3", { op = "review", run = "../x" })
	eq(h.answerOf(b, "q3"), nil, "a run id that is not one is not answered")
	w.finish()
end)

-- A Plotroom queue block on pane 1 (the window's surface only) that answers the `review` request with `at`; its protocol
-- is the current one, or `protocol`.
local function queueStub(w: World, protocol: string?): (string?) -> ()
	local main: { any } = { { id = "main.rpc", p = { text = protocol or tostring((w.load("rpc") :: any).PROTOCOL), hidden = true } } }
	w.window.surfaces[1] = { main = { id = "main", c = main } }
	local answered: { [string]: boolean } = {}
	return function(at: string?)
		for _, q in h.requestsSent(w) do
			if q.op == "review" and not answered[q.id] then
				answered[q.id] = true
				table.insert(main, { id = "main.r" .. q.id, p = { text = jsonEncode({ at = at }), hidden = true } })
				w.click("plotroom://rpc/" .. q.id, 1)
				w.flush()
				return
			end
		end
		error("no review request waits", 2)
	end
end

-- The agent pane 20 in tab 1, linked to o/r#5 with run r1, started in /wt/r5 as octocat.
local function seedRun(w: World)
	w.window.panes[20] = { cwd = "/wt/r5", tab = 1 }
	w.window.agentStates[20] = "idle"
	w.kv.put("agent-links", { { key = "o/r#5", agent = 20, host = { id = 1, name = "", address = "" }, at = 1, run = "r1", cwd = "/wt/r5", login = "octocat" } })
end

local function finished(w: World)
	w.window.handlers.agent_finished({ pane = 20, result = "done" }, w.cx)
	w.flush()
end

local function reviewLaunches(w: World): { any }
	local out: { any } = {}
	for _, l in w.window.launches do
		if l.newBlock then
			table.insert(out, l)
		end
	end
	return out
end

windowCase("review: a turn end with a newer Draft review opens the block beside the agent once; an open block reloads", function(w: World)
	w.load("window")
	local answer = queueStub(w)
	seedRun(w)
	finished(w)
	answer(AT1)
	local opened = reviewLaunches(w)
	eq(#opened, 1, "the Draft review opened")
	local got: { any } = { opened[1].kind, opened[1].args, opened[1].how, opened[1].opts }
	same(got, { "plotroom.review", { "r1", "/wt/r5", "octocat" }, "split", { target = 20, dir = "right" } } :: { any }, "beside the agent, with its run, folder and login")
	eq((w.kv.get("agent-links") :: any)[1].reviewed, AT1, "the link remembers which proposal opened")
	finished(w)
	answer(AT1)
	eq(#reviewLaunches(w), 1, "the same proposal does not open again")
	finished(w)
	answer(nil)
	eq(#reviewLaunches(w), 1, "a turn with no file opens nothing")
	-- The block is open for r1: a revised proposal reloads it.
	local pane = 0
	for id, p in w.window.panes do
		if p.block == "plugin.plotroom.review" then
			pane = id
		end
	end
	w.window.surfaces[pane] = { main = { id = "main", c = { { id = "main.run", p = { text = "r1", hidden = true } } } } }
	finished(w)
	answer(AT2)
	eq(#reviewLaunches(w), 1, "no second block")
	local last = w.window.events[#w.window.events]
	local reload: { any } = { last.pane, last.ev.act }
	same(reload, { pane, "reload" } :: { any }, "the open one reloads")
	w.finish()
end)

windowCase("review: an older host is not asked, and a link with no run opens nothing", function(w: World)
	w.load("window")
	queueStub(w, "45")
	seedRun(w)
	finished(w)
	eq(#h.requestsSent(w), 0, "a host before protocol 46 is not asked")
	w.window.surfaces[1].main.c[1].p.text = tostring((w.load("rpc") :: any).PROTOCOL)
	w.kv.put("agent-links", { { key = "o/r#5", agent = 20, host = { id = 1, name = "", address = "" }, at = 1, cwd = "/wt/r5" } })
	finished(w)
	eq(#h.requestsSent(w), 0, "an agent started without the extension has no Draft review")
	w.finish()
end)

windowCase("review: Send hands the agent the block's message, and a gone agent is told to the block, which offers Copy", function(w: World)
	w.load("window")
	reviewScene(w)
	seedRun(w)
	local b = openReview(w, 30)
	w.window.panes[30] = { block = "plugin.plotroom.review", cwd = "", tab = 1 }
	w.link(b)
	b.press("enter", "m")
	local _, text = sentChoices(b)
	w.flush()
	local call = w.window.agentCalls[#w.window.agentCalls]
	local got: { any } = { call.op, call.pane, call.text }
	same(got, { "ask", 20, text } :: { any }, "the message goes to the run's agent as is")
	has(textOf(b.view().main), "Sent", "the block shows Sent")
	eq(w.toasts[#w.toasts].text, "Sent your Draft review to the agent of o/r#5", "and a toast says so")
	-- A revised proposal, and the agent exited meanwhile.
	w.fs.files[FILE] = jsonEncode(proposal(AT2))
	b.event({ ev = "action", act = "reload" })
	w.flush()
	w.window.agentStates[20] = "exited"
	local asked = #w.window.agentCalls
	b.press("enter", "m")
	w.flush()
	eq(#w.window.agentCalls, asked, "nothing goes to a gone agent")
	has(textOf(findKey(b.view().main, "gone")), "gone", "the block says so")
	yes(findKey(b.view().main, "copy", "item"), "and offers Copy")
	w.finish()
end)

windowCase("review: Send goes only to the run's agent pane while it is listed in the link's folder, not to a reused pane id", function(w: World)
	w.load("window")
	reviewScene(w)
	seedRun(w)
	-- After a restart pane 20 is another agent, live, in another worktree.
	w.window.panes[20].cwd = "/wt/r9"
	local b = openReview(w, 30)
	w.window.panes[30] = { block = "plugin.plotroom.review", cwd = "", tab = 1 }
	w.link(b)
	b.press("enter", "m")
	w.flush()
	eq(#w.window.agentCalls, 0, "nothing goes to the agent in another folder")
	has(textOf(findKey(b.view().main, "gone")), "gone", "the block is told the agent is gone")
	-- The same pane listed in the link's folder: Send delivers there.
	w.window.panes[20].cwd = "/wt/r5"
	b.event({ ev = "action", act = "reload" })
	w.flush()
	b.press("enter", "m")
	w.flush()
	local call = w.window.agentCalls[#w.window.agentCalls]
	local got: { any } = { #w.window.agentCalls, call and call.op, call and call.pane }
	same(got, { 1, "ask", 20 } :: { any }, "sent to the run's agent")
	yes(findKey(b.view().main, "sent", "badge"), "the block shows Sent")
	w.finish()
end)

windowCase("review: a review/send link from the Draft review pane sends only the user's one Send", function(w: World)
	w.load("window")
	reviewScene(w)
	seedRun(w)
	local b = openReview(w, 30)
	w.window.panes[30] = { block = "plugin.plotroom.review", cwd = "", tab = 1 }
	w.link(b)
	-- Before Send: a link (say, in the summary) sends nothing and leaves the block as it was.
	w.click("plotroom://review/send", 30)
	w.flush()
	eq(#w.window.agentCalls, 0, "no Send pressed, nothing goes to the agent")
	yes(findKey(b.view().main, "send", "item"), "the Send button stays")
	eq(findKey(b.view().main, "gone"), nil, "and there is no error row")
	-- After Send: the same link, with and without a token, does not send again.
	b.press("enter", "m")
	w.flush()
	eq(#w.window.agentCalls, 1, "the user's Send goes once")
	w.click("plotroom://review/send", 30)
	w.click("plotroom://review/send?k=" .. string.rep("a", 16), 30)
	w.flush()
	eq(#w.window.agentCalls, 1, "a replayed link does not send again")
	yes(findKey(b.view().main, "sent", "badge"), "the block still shows Sent")
	eq(findKey(b.view().main, "gone"), nil, "with no error row")
	w.finish()
end)

windowCase("review: a send link that arrives before the block shows its message still sends it once the message shows", function(w: World)
	w.load("window")
	reviewScene(w)
	seedRun(w)
	local b = openReview(w, 30)
	w.window.panes[30] = { block = "plugin.plotroom.review", cwd = "", tab = 1 }
	-- Not linked yet: the window sees no main.send, as when a remote host's link beats its render.
	b.press("enter", "m")
	local _, text = sentChoices(b)
	w.click(w.opened[#w.opened], 30)
	w.flush()
	eq(#w.window.agentCalls, 0, "nothing to read yet, nothing sent")
	w.advance(300)
	w.link(b)
	w.advance(300)
	eq(#w.window.agentCalls, 1, "the message that showed a few hundred ms later is sent")
	eq(w.window.agentCalls[1].text, text, "as the block shows it")
	yes(findKey(b.view().main, "sent", "badge"), "and the block shows Sent")
	w.advance(10000)
	eq(#w.window.agentCalls, 1, "once")
	w.finish()
end)

case("review: a Send that no answer reaches leaves Sending after a while and offers Copy", function(w: World)
	reviewScene(w)
	local review = w.load("host/review") :: any
	local b = openReview(w)
	b.press("enter", "m")
	yes(findKey(b.view().main, "sending"), "it shows it is sending")
	w.advance(review.SEND_TIMEOUT_MS - 1)
	yes(findKey(b.view().main, "sending"), "still sending just before the timeout")
	w.advance(1)
	eq(findKey(b.view().main, "sending"), nil, "no longer sending")
	has(textOf(findKey(b.view().main, "gone")), "may not have reached the agent", "the block says so")
	yes(findKey(b.view().main, "copy", "item"), "and offers Copy")
	b.typeText("c")
	has(w.copied[#w.copied], "```json", "Copy puts the message on the clipboard")
	b.event({ ev = "action", act = "sent" })
	eq(findKey(b.view().main, "sent", "badge"), nil, "a late answer does not take it back to Sent")
	w.finish()
end)

-- `unit` repeated to n UTF-16 units, as the tool counts them (a CJK character is one unit, three UTF-8 bytes).
local function fill(unit: string, n: number): string
	return string.rep(unit, n // (utf8.len(unit) or 1))
end

case("review: the largest proposal the tool accepts (100 comments of 10000-unit multi-line bodies and suggestions) is read and every comment listed", function(w: World)
	reviewScene(w)
	local p = proposal()
	p.summary = fill("s\n", 20000)
	local comments = {}
	for i = 1, 100 do
		comments[i] = { id = "c" .. i, path = "src/a.lua", line = 3, side = "RIGHT", kind = "problem", body = fill("x\n", 10000), suggestion = fill("y\n", 10000) }
	end
	p.comments = array(comments)
	w.fs.files[FILE] = jsonEncode(p)
	yes(#w.fs.files[FILE] > 2 * 1000 * 1000, "over the old 2 MB cap")
	local review = w.load("host/review") :: any
	eq(review.fileAt("r1"), AT1, "fileAt reads it, so the window opens the block")
	local b = openReview(w)
	eq(#navKeys(b), 102, "the summary, all 100 comments and the instructions")
	lacks(textOf(b.view().main), "malformed", "nothing is reported malformed")
	w.finish()
end)

case("review: a 10000-character CJK body and suggestion the tool accepts is listed, not malformed", function(w: World)
	reviewScene(w)
	local p = proposal()
	p.summary = fill("漢", 20000)
	p.comments = array({ { id = "c1", path = fill("漢", 1000), line = 3, side = "RIGHT", kind = "problem", body = fill("漢", 10000), suggestion = fill("字", 10000) } })
	w.fs.files[FILE] = jsonEncode(p)
	local review = w.load("host/review") :: any
	local got = review.parse(w.fs.files[FILE])
	yes(got, "parse returns the proposal")
	eq(#got.comments[1].body, 30000, "a 30000-byte body")
	eq(review.fileAt("r1"), AT1, "fileAt reads it")
	local b = openReview(w)
	same(navKeys(b), { "n0", "n1", "n2" }, "the comment is listed")
	lacks(textOf(b.view().main), "malformed", "not reported malformed")
	w.finish()
end)

case("review: a Draft review file Plotroom cannot read shows why, not Reading the Draft review", function(w: World)
	local wrong = proposal()
	wrong.version = 2
	w.fs.files[FILE] = jsonEncode(wrong)
	local text = textOf(openReview(w).view().main)
	has(text, "The Draft review file is not one Plotroom reads (version 1).", "a version 2 file says so")
	lacks(text, "Reading the Draft review", "not still reading")

	local bad = proposal()
	bad.comments[1].side = nil
	w.fs.files[FILE] = jsonEncode(bad)
	text = textOf(openReview(w, 3).view().main)
	has(text, "Comment 1 of the Draft review file is malformed.", "the malformed comment is named")
	lacks(text, "Reading the Draft review", "not still reading")

	w.fs.files[FILE] = nil
	text = textOf(openReview(w, 4).view().main)
	has(text, "There is no Draft review for this run on this host.", "no file says so")
	lacks(text, "Reading the Draft review", "not still reading")
	w.finish()
end)

return {}
