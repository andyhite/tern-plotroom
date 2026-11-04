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

-- The checkout of o/r with the worktree /wt/r5 at HEAD; gh answers the pull request with head `prHead` (HEAD) on base
-- main, and git the diff. Returns the diff commands run.
local function reviewScene(w: World, prHead: string?): { string }
	local g = asks.bk.repo(w)
	asks.bk.tree(w, g, "/wt/r5", "fix-5", HEAD)
	local diffs: { string } = {}
	w.respond(function(call: h.Call): h.Reply?
		local a = call.argv
		if a[1] == "gh" and table.find(a, "repos/o/r/pulls/5") then
			return { stdout = jsonEncode({ base = "o/r", sha = prHead or HEAD, ref = "fix-5", headRepo = "o/r", state = "open", baseRef = "main", title = "Fix", author = "octo" }) }
		elseif a[1] == "git" and a[4] == "diff" then
			table.insert(diffs, table.concat(a, " "))
			return { stdout = DIFF }
		end
		return nil
	end)
	w.fs.files[FILE] = jsonEncode(proposal())
	return diffs
end

local function openReview(w: World, pane: number?): Block
	w.load("host")
	local b = w.openReview(pane or 2, { "r1", "/wt/r5" })
	w.flush()
	return b
end

local function textOf(node: any): string
	local out: { string } = {}
	collectTexts(node, out)
	return table.concat(out, "\n")
end

-- The ids of the comment cards in the order they are drawn.
local function cardIds(b: Block): { string }
	local out: { string } = {}
	for i = 1, 10 do
		local card = findKey(b.view().main, "c" .. i, "card")
		if card then
			table.insert(out, string.match(textOf(card), "Edit comment (%S+)") or "?")
		end
	end
	return out
end

-- The choices the block's last Send carries (hidden main.send): the message's JSON block, decoded, and the text.
local function sentChoices(b: Block): (any, string)
	local node = findKey(b.view().main, "send", "text")
	yes(node, "the block publishes main.send")
	local o: any = jsonDecode(node.p.text)
	local json = string.match(o.text, "```json\n(.-)\n```")
	return jsonDecode(json :: string), o.text
end

case("review: the block shows the Draft review on its diff, comments grouped by file, and one off the diff cannot be kept", function(w: World)
	local diffs = reviewScene(w)
	local b = openReview(w)
	eq(b.title(), "Draft review · o/r#5", "titled by its pull request")
	same(diffs, { "git -C /wt/r5 diff --no-color --no-ext-diff -U3 --src-prefix=a/ --dst-prefix=b/ refs/remotes/origin/main..." .. HEAD .. " --" }, "the diff of the reviewed head against the base, where the agent worked, argv only")
	local main = b.view().main
	eq(findKey(main, "run", "text").p.text, "r1", "the run is published for the window")
	same(cardIds(b), { "c1", "c4", "c2", "c3" }, "grouped by file in the order the proposal names them, the comment off the diff last")
	local d = findKey(findKey(main, "c1", "card"), "diff", "col").c[1]
	eq(d.k, "diff", "Tern's diff node")
	eq(d.p.text, "--- a/src/a.lua\n+++ b/src/a.lua\n@@ -1,4 +1,5 @@\n local x = 1\n-local y = 2\n+local y = 3\n+local z = 4\n return x\n -- end\n", "the card's diff is Tern's diff node of the rows around its line")
	eq(d.p.path, "src/a.lua", "highlighted as its file")
	yes(findKey(findKey(main, "c2", "card"), "diff", "col"), "a LEFT comment on a removed line is on the diff too")
	local f1 = findKey(main, "f1", "section")
	same({ f1.p.head[1].t, findKey(f1, "c1", "card") ~= nil, findKey(f1, "c2", "card") ~= nil, findKey(f1, "c3", "card") } :: { any }, { "src/a.lua", true, true, nil } :: { any }, "src/a.lua's section holds c1 and c4")
	local off = findKey(main, "off", "section")
	has(textOf(off), "Not on a changed line", "the off-diff section is headed so")
	has(textOf(off), "Why?", "and holds c3")
	lacks(textOf(off), "keep=", "with no Keep or Drop button")
	has(textOf(findKey(main, "c4", "card")), "Dropped", "c3 starts dropped")
	has(textOf(findKey(main, "c1", "card")), "Kept", "a comment on the diff starts kept")
	-- j to c3 (the 4th card), Space: refused with why.
	b.typeText("jjjj")
	b.typeText(" ")
	eq(w.toasts[#w.toasts].text, "Not on a changed line", "Space on it says why it cannot be kept")
	has(textOf(findKey(b.view().main, "c4", "card")), "Dropped", "and it stays dropped")
	w.finish()
end)

case("review: keys pick, edit, keep and drop; Send carries the kept comments as edited, the dropped ids, verdict, summary and instructions", function(w: World)
	reviewScene(w)
	local b = openReview(w)
	-- The summary is first: e edits it.
	b.typeText("e")
	yes(findKey(b.view().main, "summary", "card") and findKey(findKey(b.view().main, "summary", "card"), "text", "editor"), "e on the summary opens its editor")
	b.typeText(" Fix both.")
	b.press("escape")
	-- c1: edit its body.
	b.typeText("j")
	has(textOf(findKey(findKey(b.view().main, "c1", "card"), "buttons")), "Space", "the selected card shows its keys beside its buttons")
	b.typeText("e")
	b.press("backspace")
	b.typeText("d here")
	b.press("escape")
	-- c4: drop it.
	b.typeText("j ")
	has(textOf(findKey(b.view().main, "c2", "card")), "Dropped", "Space drops the selected comment")
	-- Request changes.
	b.typeText("3")
	eq(findKey(b.view().main, "request_changes", "item").p.tone, "accent", "3 picks Request changes")
	-- The instructions line, last: two more j past c2 and c3.
	b.typeText("jjje")
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
	has(textOf(findKey(b.view().main, "send-card")), "Sending…", "it shows it is sending")
	b.event({ ev = "action", act = "sent" })
	has(textOf(b.view().main), "Sent", "the window's answer: Sent")
	b.typeText("kkkk ")
	has(textOf(findKey(b.view().main, "c1", "card")), "Kept", "after Send nothing changes")
	lacks(textOf(findKey(b.view().main, "send-card")), "Send to agent", "and there is no second Send")
	eq(b.saved().sent, AT1, "it stays Sent after a restart")
	w.finish()
end)

case("review: a head that moved since the review is said, and Send asks the agent to check the new commits first", function(w: World)
	reviewScene(w, sha("e"))
	local b = openReview(w)
	has(textOf(findKey(b.view().main, "moved", "text")), "head moved to eeeeeee", "the block says so")
	b.press("enter", "m")
	local _, text = sentChoices(b)
	has(text, "head moved to eeeeeeeeeeee since your review: check the new commits first", "and Send asks for it")
	w.finish()
end)

case("review: a reload keeps your edits for the same proposal and starts over for a revised one; a gone agent gets Copy", function(w: World)
	reviewScene(w)
	local b = openReview(w)
	b.typeText("j ")
	b.event({ ev = "action", act = "reload" })
	w.flush()
	has(textOf(findKey(b.view().main, "c1", "card")), "Dropped", "the same file: the choice stays")
	local revised = proposal(AT2)
	revised.summary = "Revised."
	w.fs.files[FILE] = jsonEncode(revised)
	b.event({ ev = "action", act = "reload" })
	w.flush()
	has(textOf(findKey(b.view().main, "c1", "card")), "Kept", "a revised proposal starts over")
	has(textOf(findKey(b.view().main, "summary", "card")), "Revised.", "with its summary")
	b.press("enter", "m")
	b.event({ ev = "action", act = "gone", value = "The agent that proposed this review is gone." })
	has(textOf(findKey(b.view().main, "send-card")), "The agent that proposed this review is gone.", "the block says why")
	b.typeText("c")
	local _, text = sentChoices(b)
	eq(w.copied[#w.copied], text, "c copies the message for the agent")
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
	queueStub(w, "44")
	seedRun(w)
	finished(w)
	eq(#h.requestsSent(w), 0, "a host before protocol 45 is not asked")
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
	w.flush()
	local call = w.window.agentCalls[#w.window.agentCalls]
	local _, text = sentChoices(b)
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
	has(textOf(findKey(b.view().main, "send-card")), "gone", "the block says so")
	yes(findKey(b.view().main, "copy", "item"), "and offers Copy")
	w.finish()
end)

return {}
