--!strict
-- Regression cases: window flows (status, draft PR, open-url, palette), triage, sort, mutations, the Worktrees board, keys, views and agents.

local h = require("../harness")

type AcliReq = h.AcliReq
type Block = h.Block
type GhReq = h.GhReq
type Reply = h.Reply
type World = h.World

local EPOCH, JIRA_ASSIGNED, acliCount, answerOf, array = h.EPOCH, h.JIRA_ASSIGNED, h.acliCount, h.answerOf, h.array
local asks, buttonLink, case, checkRun, collectTexts, confirmOf = h.asks, h.buttonLink, h.case, h.checkRun, h.collectTexts, h.confirmOf
local countLog, detailText, eq, expand, findKey, goToSettings = h.countLog, h.detailText, h.eq, h.expand, h.findKey, h.goToSettings
local has, hostScene, hx, issueHost, issueItem, jiraHost = h.has, h.hostScene, h.hx, h.issueHost, h.issueItem, h.jiraHost
local jiraItem, jsonDecode, jsonEncode, lacks, listed, manyItems = h.jiraItem, h.jsonDecode, h.jsonEncode, h.lacks, h.listed, h.manyItems
local openIssues, openQueue, pickScope, pickerNode, pickerOf, prLink = h.openIssues, h.openQueue, h.pickScope, h.pickerNode, h.pickerOf, h.prLink
local ranSince, refreshNow, request, requestsOf, requestsSent = h.ranSince, h.refreshNow, h.request, h.requestsOf, h.requestsSent
local rowIn, runLink, same, searchItem, sha = h.rowIn, h.runLink, h.same, h.searchItem, h.sha
local show, windowCase, yes = h.show, h.windowCase, h.yes
local iso = h.iso

type FlowStub = { reply: (string, any) -> any, link: (string, string) -> (), ops: () -> { string }, palette: (any) -> () }

-- A Plotroom block's host that answers by hand: `reply(op, answer)` answers the oldest unanswered request of that op
-- (through the block's hidden r<id> node and its rpc link) and returns the request; `link(node id, href)` keeps a
-- hidden link node the window validates a link against; `palette(rows)` publishes the block's main.palette node.
local function flowHost(w: World, pane: number?): FlowStub
	local at = pane or 1
	local main: { any } = { { id = "main.rpc", p = { text = asks.protocol, hidden = true } }, { id = "main.more", p = { href = "plotroom://more", hidden = true } } }
	-- The host acknowledges an agent-status event by publishing main.agents: the sorted `key=state;` signature.
	local session: any = w.cx.session
	local sendEvent = session.event
	session.event = function(self: any, id: number, ev: { [string]: any })
		sendEvent(self, id, ev)
		if id == at and ev.act == "agent-status" then
			local map: any = jsonDecode(ev.value)
			local keys: { string } = {}
			for k in map do
				table.insert(keys, k)
			end
			table.sort(keys)
			local sig = ""
			for _, k in keys do
				local r = map[k]
				sig ..= k .. "=" .. r.state .. "|" .. (r.action or "") .. "|" .. (r.branch or "") .. "|" .. (r.title or "") .. "|" .. (r.last or "") .. "|" .. (r.err or "") .. "|" .. (r.result or "") .. "|" .. (r.ended or "") .. "|" .. (r.attention or "") .. "|" .. (r.reason or "") .. "|" .. (r.blocker or "") .. "|" .. (r.outcome or "") .. "|" .. (r.verdict or "") .. "|" .. (r.check or "") .. "|" .. (r.findings or "") .. "|" .. (r.stop or "") .. "|" .. (r.since or "") .. "|" .. (r.expected or "") .. ";"
			end
			for i = #main, 1, -1 do
				if main[i].id == "main.agents" then
					table.remove(main, i)
				end
			end
			table.insert(main, { id = "main.agents", p = { text = sig, hidden = true } })
		end
	end
	local layer: { any } = {}
	w.window.surfaces[at] = { main = { id = "main", c = main }, layer = { id = "layer", c = layer } }
	local done: { [string]: boolean } = {}
	for _, q in requestsSent(w) do
		done[q.id] = true -- what was asked before this stub is not its to answer
	end
	return {
		reply = function(op: string, answer: any): any
			for _, q in requestsSent(w) do
				if q.op == op and not done[q.id] then
					done[q.id] = true
					table.insert(main, { id = "main.r" .. q.id, p = { text = jsonEncode(answer), hidden = true } })
					w.click("plotroom://rpc/" .. q.id, at)
					w.flush()
					return q
				end
			end
			error("no unanswered request of op " .. op, 2)
		end,
		link = function(id: string, href: string)
			table.insert(layer, { id = id, p = { href = href } })
		end,
		ops = function(): { string }
			local out: { string } = {}
			for _, q in requestsSent(w) do
				table.insert(out, q.op)
			end
			return out
		end,
		palette = function(rows: any)
			for i = #main, 1, -1 do
				if main[i].id == "main.palette" then
					table.remove(main, i)
				end
			end
			table.insert(main, { id = "main.palette", p = { text = jsonEncode(rows), hidden = true } })
		end,
	}
end

local function flowRows(pick: any): { string }
	local out: { string } = {}
	for _, item in pick.items do
		table.insert(out, item.label)
	end
	return out
end

-- An agent block `pane` in a tab of its own on host `hostId`, linked to `key` in kv (as the window would have kept it).
local function seedAgent(w: World, pane: number, state: string, hostId: number, key: string)
	w.window.panes[pane] = { cwd = "/wt/seed" .. pane, tab = pane }
	table.insert(w.window.tabs, { id = pane, session = 1 })
	w.window.agentStates[pane] = state
	w.window.hostOf[pane] = hostId
	local links: any = w.kv.get("agent-links") or {}
	table.insert(links, { key = key, agent = pane, host = { id = hostId, name = "", address = if hostId == 1 then "" else "host" .. hostId }, at = 1 })
	w.kv.put("agent-links", links)
end

local function statusEvents(w: World): { any }
	local out: { any } = {}
	for _, e in w.window.events do
		if e.ev.act == "agent-status" then
			table.insert(out, { pane = e.pane, map = jsonDecode(e.ev.value) })
		end
	end
	return out
end

-- Starts an agent on o/r#5 through the real link flow: menu pick, worktree answer, cx.agents:start.
local function startAgentOn(w: World, st: FlowStub)
	st.link("layer.queue.buttons.agent", "plotroom://github/agent/o/r/5")
	st.palette({ items = { { id = "p1", label = "Review" } } })
	w.window.choose = "Review"
	w.click("plotroom://github/agent/o/r/5")
	w.flush()
	st.reply("menu", { items = { { id = "p1", label = "Review", send = "Review {url}", worktree = true } } })
	st.reply("worktree", { path = "/wt/r5", summary = "Created", created = true, current = true, branch = "fix-5", title = "Fix the thing" })
end

windowCase("window flows: an agent started from a block is linked in kv and the block hears its state", function(w: World)
	w.load("window")
	local st = flowHost(w)
	startAgentOn(w, st)
	eq(#w.window.agents, 1, "the agent started")
	local links: any = w.kv.get("agent-links")
	eq(#links, 1, "one link kept")
	eq(links[1].key, "o/r#5", "under the lowercase item key")
	eq(links[1].host.id, 1, "with the block's host")
	eq(w.window.agentStates[links[1].agent], "working", "to the agent block the start made")
	local status = statusEvents(w)
	eq(#status, 1, "the block was told at once")
	same(status[1].map, { ["o/r#5"] = { state = "working", action = "Review", branch = "fix-5", title = "Fix the thing", since = tostring(links[1].started) } }, "the state of the key with what the link recorded, and since when it works")
	eq(links[1].action, "Review", "the action's name is kept on the link")
	eq(links[1].branch, "fix-5", "and the branch")
	eq(links[1].title, "Fix the thing", "and the item's title")
	eq(status[1].pane, 1, "the Plotroom block")
	w.advance(4100)
	eq(#statusEvents(w), 1, "nothing changed: nothing more is sent")
	w.window.agentStates[links[1].agent] = "waiting_input"
	w.advance(4000)
	eq(#statusEvents(w), 2, "a changed state is sent")
	same(statusEvents(w)[2].map, { ["o/r#5"] = { state = "waiting_input", action = "Review", branch = "fix-5", title = "Fix the thing" } }, "in full")
	w.window.panes[links[1].agent] = nil
	w.advance(4000)
	same(statusEvents(w)[3].map, { ["o/r#5"] = { state = "exited" } }, "a closed agent pane is exited, with no texts")
	w.advance(12000)
	eq(#statusEvents(w), 3, "and then it is quiet")
end)

windowCase("window flows: a working agent is told since when its run works and, once its action has 5 finished runs, their median; a later turn only since it was seen working", function(w: World)
	w.load("window")
	local runs: { any } = {}
	for i, d in { 60, 300, 120, 240 } do
		table.insert(runs, { key = "o/r#" .. i, action = "Review", started = EPOCH - 5000, ended = EPOCH - 5000 + d, result = "done" })
	end
	table.insert(runs, { key = "o/r#9", action = "Watch", started = EPOCH - 5000, ended = EPOCH - 4000, result = "done" })
	w.kv.put("runs", runs)
	local st = flowHost(w)
	startAgentOn(w, st)
	local link: any = (w.kv.get("agent-links") :: any)[1]
	local told: any = statusEvents(w)[1].map["o/r#5"]
	eq(told.since, tostring(link.started), "since its run started")
	eq(told.expected, nil, "4 runs of Review: nothing to expect")
	w.advance(200 * 1000)
	w.window.agentStates[link.agent] = "idle"
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	local idle: any = statusEvents(w)[#statusEvents(w)].map["o/r#5"]
	same({ idle.state, idle.since or "-", idle.expected or "-" }, { "idle", "-", "-" }, "an idle agent has no clock")
	w.window.agentStates[link.agent] = "working"
	local before = w.seconds()
	w.advance(4000)
	local again = statusEvents(w)[#statusEvents(w)].map["o/r#5"]
	yes(tonumber(again.since) :: number >= before, "a later turn works since it was first seen working, not since its run started")
	eq(again.expected, nil, "and expects nothing: the run log times first turns")
	w.window.panes[link.agent] = nil
	w.advance(4000)
	startAgentOn(w, st)
	local second: any = (w.kv.get("agent-links") :: any)[1]
	yes(second.agent ~= link.agent, "a second agent started")
	local fifth = statusEvents(w)[#statusEvents(w)].map["o/r#5"]
	same({ fifth.since, fifth.expected }, { tostring(second.started), "200" }, "the first run made 5: the median of 60, 120, 200, 240 and 300 seconds")
end)

windowCase("window status: agents needing input are counted in the one need-you count on every pane, toast once, and the mismatch warning stays", function(w: World)
	w.load("window")
	local st = flowHost(w)
	startAgentOn(w, st)
	local agent = (w.kv.get("agent-links") :: any)[1].agent
	local function texts(pane: number): { string }
		local out: { string } = {}
		for _, s in ((w.window.status :: any)({ pane = pane }) or {}) do
			table.insert(out, s.text)
		end
		return out
	end
	eq(#texts(1), 0, "no segment while nothing waits")
	local toasts = #w.toasts
	local before = w.window.refreshes
	w.window.agentStates[agent] = "waiting_input"
	w.advance(4000)
	same(texts(7), { "1 need you" }, "every pane shows the one count, which covers the agent")
	eq(#w.toasts, toasts + 1, "the agent's entry toasts once")
	eq(w.toasts[#w.toasts].text, "o/r#5 needs input", "naming its item")
	eq(w.toasts[#w.toasts].sub, "Review", "and its action")
	eq(w.window.refreshes, before + 1, "the status line was redrawn once")
	w.advance(12000)
	eq(#w.toasts, toasts + 1, "staying there toasts nothing more")
	eq(w.window.refreshes, before + 1, "and redraws nothing")
	eq(((w.window.status :: any)({ pane = 1 }))[1].command, "plugin.plotroom.now", "the segment shows Now")
	same(w.palette(), { "agent-message-selection", "agents-waiting", "now", "open", "open-url" }, "Tern's palette offers Now and the jump while one waits")
	w.window.focused = 1
	w.command("agents-waiting")
	eq(w.window.focused, agent, "the jump focuses the waiting agent's pane")
	w.window.surfaces[1] = { main = { id = "main", c = { { id = "main.rpc", p = { text = "9", hidden = true } } } } }
	w.window.focused = 1
	w.window.handlers.focus({ pane = 1, tab = 1 }, w.cx)
	same(texts(1), { "Plotroom on host1 is a different version from this window's", "1 need you" }, "the mismatch warning still shows beside it")
	w.window.agentStates[agent] = "working"
	w.advance(4000)
	same(texts(7), {}, "the count clears as soon as none waits")
	w.window.agentStates[agent] = "waiting_input"
	w.advance(4000)
	eq(#w.toasts, toasts + 2, "entering again toasts again")
end)

windowCase("window status: only agents the Agents list covers count, and closing Plotroom does not re-toast a waiting agent", function(w: World)
	w.load("window")
	local st = flowHost(w)
	startAgentOn(w, st)
	local links = w.kv.get("agent-links") :: any
	local agent = links[1].agent
	local older: any = table.clone(links[1])
	older.host = table.clone(older.host)
	older.host.id += 1
	w.kv.put("agent-links", { older })
	w.window.agentStates[agent] = "waiting_input"
	local toasts = #w.toasts
	local function shown(): number
		return #((w.window.status :: any)({ pane = 7 }) or {})
	end
	w.advance(4000)
	eq(shown(), 0, "a waiting agent on a host with no Plotroom block is not counted")
	eq(#w.toasts, toasts, "nor toasted")
	w.kv.put("agent-links", links)
	w.advance(4000)
	eq(shown(), 1, "on the block's host it is counted")
	eq(#w.toasts, toasts + 1, "and toasted once")
	local block = w.window.panes[1].block
	w.window.panes[1].block = nil
	w.advance(4000)
	eq(shown(), 0, "with no Plotroom pane the shown count clears")
	w.window.panes[1].block = block
	w.window.handlers.pane_created({ pane = 1 }, w.cx)
	w.advance(4000)
	eq(shown(), 1, "reopening shows it again")
	eq(#w.toasts, toasts + 1, "reopening toasts an agent that never stopped waiting nothing")
end)

windowCase("window status: an agent that leaves the covered set while still waiting is not toasted again when it returns", function(w: World)
	w.load("window")
	local st = flowHost(w)
	startAgentOn(w, st)
	local agent = (w.kv.get("agent-links") :: any)[1].agent
	w.window.panes[8] = { block = "plugin.plotroom.prs", cwd = "/work/r", tab = 1 }
	w.window.hostOf[8] = 2
	w.window.agentStates[agent] = "waiting_input"
	local toasts = #w.toasts
	w.advance(4000)
	eq(#w.toasts, toasts + 1, "toasted once")
	local block = w.window.panes[1].block
	w.window.panes[1].block = nil
	w.advance(4000)
	eq(#w.toasts, toasts + 1, "host 1's block closed while host 2's stays: nothing more")
	w.window.panes[1].block = block
	w.window.handlers.pane_created({ pane = 1 }, w.cx)
	w.advance(4000)
	eq(#w.toasts, toasts + 1, "reopened: still no second toast")
end)

-- Starts the saved action Review (model opus, in its worktree) on o/r#5 through the agent picker; the new link.
local function startReview(w: World): any
	local url = "plotroom://github/agent/o/r/5"
	local st = flowHost(w)
	st.link("layer.queue.buttons.agent", url)
	st.palette({ items = { { id = "p1", label = "Review" } } })
	w.window.choose = "Review"
	w.click(url)
	w.flush()
	st.reply("menu", { items = { { id = "p1", label = "Review", send = "Review {url}", worktree = true, model = "opus" } } })
	st.reply("worktree", { path = "/wt/r5", summary = "Created", created = true, current = true, branch = "fix-5", title = "Fix the thing" })
	return (w.kv.get("agent-links") :: any)[1]
end

windowCase("window flows: an agent's first turn end appends one run to the run log, newest first, keeping the newest 1000; later turns add none", function(w: World)
	w.load("window")
	local old: { any } = {}
	for i = 1, 1000 do
		table.insert(old, { key = "o/r#" .. i, action = "Old", result = "done", ended = EPOCH - i })
	end
	w.kv.put("runs", array(old))
	local link = startReview(w)
	eq((w.kv.get("usage") :: any).counts["action:Review"].n, 1, "the started action is counted by name")
	w.advance(90 * 1000)
	w.window.handlers.agent_finished({ pane = link.agent, result = "failed" }, w.cx)
	w.flush()
	local runs: any = w.kv.get("runs")
	eq(#runs, 1000, "the cap holds")
	same(runs[1], { key = "o/r#5", action = "Review", kind = "pr", model = "opus", runsIn = "worktree", started = link.started, ended = link.started + 90, result = "failed", attention = "none", ghRepo = "o/r", number = 5, branch = "fix-5", depth = 0 }, "the run: item key, action, kind, model, where it ran, start, end, result, what GitHub knows its work by, no report, and depth 0: started by hand")
	eq(runs[2].key, "o/r#1", "the earlier runs follow")
	eq(runs[1000].key, "o/r#999", "and the oldest one went")
	lacks(jsonEncode(runs[1]), "Fix the thing", "no item title is kept")
	lacks(jsonEncode(runs[1]), "pull/5", "nor the prompt's text")
	w.advance(600 * 1000)
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	runs = w.kv.get("runs")
	eq(runs[1].result, "failed", "a later turn of the same agent adds no run")
	eq(runs[2].key, "o/r#1", "nor pushes one out")
	eq((w.kv.get("agent-links") :: any)[1].result, "done", "while its link still shows the latest turn")
end)

-- `agent`'s turn, as cx.agents:transcript gives it: its prompt, one assistant message per tool call in `calls`, then
-- `text` as its last message. `before`: messages of earlier turns, oldest first.
local function lastSays(w: World, agent: number, text: string, calls: { any }?, before: { any }?)
	local msgs: { any } = table.clone(before or {})
	table.insert(msgs, { role = "user", text = "go", tools = {} })
	for _, c in calls or {} :: { any } do
		table.insert(msgs, { role = "assistant", text = "", tools = { c } })
	end
	table.insert(msgs, { role = "assistant", text = text, tools = {} })
	w.window.transcripts[agent] = msgs
end

-- A plotroom_report call as omp's transcript shows it (Tern 0.9.13, omp 18.18): omp names a tool the agent reaches
-- through its xd:// device "write" and keeps the label as `title`; the extension's result text is the report's JSON,
-- then a line for the agent. `refused`: a call the extension refused, with omp's error text.
local function reportCall(json: string, refused: boolean?): any
	if refused then
		return { name = "write", title = "Plotroom: report", role = "omp.tool.write", status = "error", tone = "error", text = "Invalid args for xd://plotroom_report: Validation failed\n\nReceived arguments:\n" .. json }
	end
	return { name = "write", title = "Plotroom: report", role = "omp.tool.write", status = "done", text = json .. "\nReported. End your turn now." }
end

-- `agent`'s turn ends with one plotroom_report call giving `json`, then a last message.
local function reports(w: World, agent: number, json: string)
	lastSays(w, agent, "All set: the tests pass.", { reportCall(json) })
end

windowCase("window flows: a valid end-of-run report call goes on the run record and the Agents list, nothing else the agent said is kept, and it never marks work done", function(w: World)
	w.load("window")
	local link = startReview(w)
	eq(w.window.agents[1].report, true, "the action's prompt ends with the fixed contract")
	local commit = string.rep("A1", 20)
	lastSays(w, link.agent, "All set: the tests pass.", {
		reportCall(`\{"attention":"ok","reason":"draft","commit":null,"pr":null,"evidence":[],"blocker":null}`),
		{ name = "bash", title = "Bash", status = "done", text = "{\"attention\":\"ok\",\"reason\":\"another tool's output\",\"evidence\":[]}" },
		reportCall(`\{"attention":"stuck","reason":"The migration fails","commit":"{commit}","pr":"https://github.com/o/r/pull/9","evidence":["luau tests: 3 failed"],"blocker":"No test database"}`),
	})
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	local run: any = (w.kv.get("runs") :: any)[1]
	eq(run.result, "done", "the turn's result is Tern's, whatever the report claims")
	same({ run.attention, run.reason, run.commit, run.pr, run.blocker }, { "stuck", "The migration fails", string.lower(commit), "https://github.com/o/r/pull/9", "No test database" }, "the last call's report is on the run record")
	same(run.evidence, { "luau tests: 3 failed" }, "with its evidence")
	lacks(jsonEncode(w.kv.get("runs")), "All set", "no other agent output is stored in the run log")
	lacks(jsonEncode(w.kv.get("agent-links")), "All set", "nor on the link")
	local links: any = w.kv.get("agent-links")
	same({ links[1].attention, links[1].reason, links[1].blocker }, { "stuck", "The migration fails", "No test database" }, "the link keeps what the Agents list shows")
	w.advance(4100)
	local row: any = statusEvents(w)[#statusEvents(w)].map["o/r#5"]
	same({ row.attention, row.reason, row.blocker }, { "stuck", "The migration fails", "No test database" }, "and the block is told it")
	eq(row.result, "done", "beside the turn's result")
end)

windowCase("window flows: a refused report call is not read; the corrected call after it is", function(w: World)
	w.load("window")
	local link = startReview(w)
	lastSays(w, link.agent, "Done.", {
		reportCall(`\{"attention":"bogus","reason":"first try","evidence":[]}`, true),
		reportCall(`\{"attention":"needs-human","reason":"Second call","commit":null,"pr":null,"evidence":["ran it"],"blocker":null}`),
	})
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	local run: any = (w.kv.get("runs") :: any)[1]
	same({ run.attention, run.reason }, { "needs-human", "Second call" }, "the corrected call is recorded")
	lacks(jsonEncode(w.kv.get("runs")), "bogus", "the refused one is not")
	w.window.panes[link.agent] = nil
	local other = startReview(w)
	lastSays(w, other.agent, "Gave up.", { reportCall(`\{"attention":"ok","reason":"Only try","evidence":[]}`, true) })
	w.window.handlers.agent_finished({ pane = other.agent, result = "done" }, w.cx)
	w.flush()
	eq((w.kv.get("runs") :: any)[1].attention, "none", "a turn whose only call was refused records No report")
end)

windowCase("window flows: a turn end reported before omp's transcript has the turn's last calls waits for them, then records the report", function(w: World)
	w.load("window")
	local link = startReview(w)
	local refused = reportCall(`\{"attention":"bogus","reason":"first try","evidence":[]}`, true)
	-- As Tern 0.9.13 reported it: the turn's end while the corrected call was still queued, with no reply yet.
	w.window.transcripts[link.agent] = {
		{ role = "user", text = "go", tools = {} },
		{ role = "assistant", text = "", tools = { refused } },
		{ role = "assistant", text = "", tools = { { name = "write", title = "queued Plotroom: report", status = "pending", text = "" } } },
	}
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	eq(w.kv.get("runs"), nil, "nothing is recorded while the transcript lags")
	lastSays(w, link.agent, "done", { refused, reportCall(`\{"attention":"stuck","reason":"Second call","commit":null,"pr":null,"evidence":["ran it"],"blocker":"No database","check":"fail","findings":["a finding"]}`) })
	w.advance(1000)
	w.flush()
	local run: any = (w.kv.get("runs") :: any)[1]
	same({ run.attention, run.reason, run.blocker }, { "stuck", "Second call", "No database" }, "once it has them, the corrected call is recorded")
	eq(#(w.kv.get("runs") :: any), 1, "as one run")
	w.window.panes[link.agent] = nil
	local other = startReview(w)
	-- An agent started with the extension (its link names a run) whose transcript is still empty: waited on too.
	local links: any = w.kv.get("agent-links")
	for _, l in links do
		if l.agent == other.agent then
			l.run = "1794245000-abcdef"
		end
	end
	w.kv.put("agent-links", links)
	w.window.transcripts[other.agent] = {}
	w.window.handlers.agent_finished({ pane = other.agent, result = "done" }, w.cx)
	w.advance(9000)
	eq(#(w.kv.get("runs") :: any), 1, "a transcript that never settles is waited on for up to 10 seconds")
	w.advance(1000)
	eq((w.kv.get("runs") :: any)[1].attention, "none", "then recorded as it is")
	w.window.panes[other.agent] = nil
	local plain = startReview(w)
	w.window.handlers.agent_finished({ pane = plain.agent, result = "done" }, w.cx)
	w.flush()
	eq(#(w.kv.get("runs") :: any), 3, "an agent started without the extension has no omp chat to wait for")
end)

windowCase("window flows: a turn end whose pane closes while its transcript lags is still recorded, with the report read before it closed", function(w: World)
	w.load("window")
	local link = startReview(w)
	-- The accepted call is in, the reply is not: unsettled.
	lastSays(w, link.agent, "", { reportCall(`\{"attention":"needs-human","reason":"Which base?","commit":null,"pr":null,"evidence":[],"blocker":null}`) })
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	eq(w.kv.get("runs"), nil, "nothing is recorded while the transcript lags")
	w.window.panes[link.agent] = nil
	w.window.transcripts[link.agent] = nil
	w.advance(11000)
	local runs: any = w.kv.get("runs")
	eq(#runs, 1, "the closed pane's turn is one run")
	same({ runs[1].result, runs[1].attention, runs[1].reason }, { "done", "needs-human", "Which base?" }, "with the report read before the pane closed")
	local l: any = (w.kv.get("agent-links") :: any)[1]
	same({ l.result, l.attention, l.reason }, { "done", "needs-human", "Which base?" }, "on the link too")
end)

-- `agent`'s chat as turn 1 (report `stuck`, settled), the user's reply, then turn 2 (report `ok`, settled).
local function repliedTo(w: World, agent: number)
	lastSays(w, agent, "Turn 2.", { reportCall(`\{"attention":"ok","reason":"Turn two","commit":null,"pr":null,"evidence":[],"blocker":null}`) }, {
		{ role = "user", text = "go", tools = {} },
		{ role = "assistant", text = "", tools = { reportCall(`\{"attention":"stuck","reason":"Turn one","commit":null,"pr":null,"evidence":[],"blocker":"No database"}`) } },
		{ role = "assistant", text = "Turn 1.", tools = {} },
	})
	local msgs = w.window.transcripts[agent]
	msgs[4].text = "reply"
end

windowCase("window flows: a prompt sent to the agent during the settle wait does not change which turn's report is recorded", function(w: World)
	w.load("window")
	local link = startReview(w)
	lastSays(w, link.agent, "", { reportCall(`\{"attention":"stuck","reason":"Turn one","commit":null,"pr":null,"evidence":[],"blocker":"No database"}`) })
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	eq(w.kv.get("runs"), nil, "the turn end waits for the transcript")
	repliedTo(w, link.agent)
	w.advance(1000)
	w.flush()
	local runs: any = w.kv.get("runs")
	eq(#runs, 1, "one run")
	same({ runs[1].attention, runs[1].reason }, { "stuck", "Turn one" }, "carrying the turn that ended, not the new one")
	-- The new prompt arrives while turn 1's last reply still lags: the turn is over all the same.
	w.window.panes[link.agent] = nil
	local other = startReview(w)
	lastSays(w, other.agent, "", { reportCall(`\{"attention":"stuck","reason":"Turn one","commit":null,"pr":null,"evidence":[],"blocker":null}`) })
	w.window.handlers.agent_finished({ pane = other.agent, result = "done" }, w.cx)
	w.flush()
	local msgs = w.window.transcripts[other.agent]
	table.insert(msgs, { role = "user", text = "reply", tools = {} })
	w.advance(1000)
	w.flush()
	runs = w.kv.get("runs")
	eq(#runs, 2, "recorded at once")
	eq(runs[1].attention, "stuck", "with its report")
end)

windowCase("window flows: a second turn end during the settle wait yields one run carrying the first turn's report", function(w: World)
	w.load("window")
	local link = startReview(w)
	lastSays(w, link.agent, "", { reportCall(`\{"attention":"stuck","reason":"Turn one","commit":null,"pr":null,"evidence":[],"blocker":"No database"}`) })
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	eq(w.kv.get("runs"), nil, "the turn end waits for the transcript")
	repliedTo(w, link.agent)
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.advance(11000)
	w.flush()
	local runs: any = w.kv.get("runs")
	eq(#runs, 1, "exactly one run")
	same({ runs[1].attention, runs[1].reason, runs[1].blocker }, { "stuck", "Turn one", "No database" }, "with turn 1's report")
	local l: any = (w.kv.get("agent-links") :: any)[1]
	same({ l.result, l.attention, l.reason }, { "done", "ok", "Turn two" }, "the link shows turn 2's report")
end)

-- A link started with Plotroom's omp extension (`run` set), whose first turn ended with a needs-human report, recorded.
local function askedOnce(w: World): any
	local link = startReview(w)
	local links: any = w.kv.get("agent-links")
	links[1].run = "1794245000-abcdef"
	w.kv.put("agent-links", links)
	lastSays(w, link.agent, "Which base?", { reportCall(`\{"attention":"needs-human","reason":"Which base?","commit":null,"pr":null,"evidence":[],"blocker":null}`) })
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	eq((w.kv.get("agent-links") :: any)[1].attention, "needs-human", "turn 1 is recorded")
	return link
end

windowCase("window flows: a later turn end read before its prompt reached the transcript records that turn's report once it shows", function(w: World)
	w.load("window")
	local link = askedOnce(w)
	local turn1 = table.clone(w.window.transcripts[link.agent])
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	eq((w.kv.get("agent-links") :: any)[1].result, "done", "nothing new is recorded from turn 1's messages")
	local commit = string.rep("b", 40)
	lastSays(w, link.agent, "Done.", { reportCall(`\{"attention":"ok","reason":"Based on main","commit":"{commit}","pr":null,"evidence":["ran it"],"blocker":null}`) }, turn1)
	w.advance(11000)
	w.flush()
	local l: any = (w.kv.get("agent-links") :: any)[1]
	same({ l.attention, l.reason, l.commit }, { "ok", "Based on main", commit }, "turn 2's report is recorded")
	eq(#(w.kv.get("runs") :: any), 1, "as no second run")
end)

windowCase("window flows: a later turn end whose transcript already shows that turn is recorded at once", function(w: World)
	w.load("window")
	local link = askedOnce(w)
	lastSays(w, link.agent, "Done.", { reportCall(`\{"attention":"ok","reason":"Based on main","commit":null,"pr":null,"evidence":[],"blocker":null}`) }, table.clone(w.window.transcripts[link.agent]))
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	same({ (w.kv.get("agent-links") :: any)[1].attention, (w.kv.get("agent-links") :: any)[1].reason }, { "ok", "Based on main" }, "without waiting")
end)

windowCase("window flows: a turn with no report call records No report, and a later turn's valid report replaces it without a second run", function(w: World)
	w.load("window")
	local link = startReview(w)
	-- An earlier turn's call (before this turn's prompt) is not this turn's report.
	lastSays(w, link.agent, "Finished. Nothing to report.", nil, {
		{ role = "user", text = "earlier", tools = {} },
		{ role = "assistant", text = "", tools = { reportCall(`\{"attention":"ok","reason":"Earlier turn","evidence":[]}`) } },
	})
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	local run: any = (w.kv.get("runs") :: any)[1]
	eq(run.attention, "none", "the run records No report")
	eq(run.reason, nil, "with no reason")
	eq((w.kv.get("agent-links") :: any)[1].attention, "none", "and so does the link")
	reports(w, link.agent, `\{"attention": "needs-human", "reason": "Which base?", "commit": null, "pr": null, "evidence": [], "blocker": null}`)
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	local l: any = (w.kv.get("agent-links") :: any)[1]
	same({ l.attention, l.reason }, { "needs-human", "Which base?" }, "a later valid report is shown")
	eq(l.blocker, nil, "with no blocker")
	eq(#(w.kv.get("runs") :: any), 1, "and adds no run")
	lastSays(w, link.agent, "A reply to a typed message, with no report")
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	eq((w.kv.get("agent-links") :: any)[1].attention, "needs-human", "a later turn with no report keeps the one shown")
end)

windowCase("window flows: a fenced plotroom-report block in the agent's message is not read", function(w: World)
	w.load("window")
	local link = startReview(w)
	lastSays(w, link.agent, "Done.\n\n```plotroom-report\n{\"attention\": \"ok\", \"reason\": \"Shipped\", \"evidence\": []}\n```")
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	eq((w.kv.get("runs") :: any)[1].attention, "none", "only the tool call is a report")
	lacks(jsonEncode(w.kv.get("runs")), "Shipped", "and none of it is kept")
end)

-- Starts the saved action `name` with outcome `outcome` on o/r#5 as gh login cat; its link and the worktree request.
local function startWithOutcome(w: World, st: FlowStub, name: string, outcome: string): (any, any)
	local url = "plotroom://github/agent/o/r/5"
	st.link("layer.queue.buttons.agent", url)
	st.palette({ items = { { id = "p1", label = name } } })
	w.window.choose = name
	w.click(url)
	w.flush()
	st.reply("menu", { items = { { id = "p1", label = name, send = "Work on {url}", worktree = true, outcome = outcome } } })
	local asked = st.reply("worktree", { path = "/wt/r5", summary = "Created", created = true, current = true, branch = "fix-5", title = "Fix the thing", ["github.user"] = "cat" })
	return (w.kv.get("agent-links") :: any)[1], asked
end

-- The newest outcome request the window sent, decoded.
local function outcomeAsks(w: World): { any }
	local out: { any } = {}
	for _, q in requestsSent(w) do
		if q.op == "outcome" then
			table.insert(out, q)
		end
	end
	return out
end

windowCase("window flows: an action's outcome is checked as the run's login at each turn end; the verdict goes on the link, the run and the block", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local link, asked = startWithOutcome(w, st, "Address feedback", "replied")
	eq(asked.users, true, "the login is asked for even though the prompt names none: the outcome is checked as it")
	same({ link.outcome, link.login, link.ghRepo, link.number, link.branch }, { "replied", "cat", "o/r", 5, "fix-5" } :: { any }, "the link keeps what the check needs")
	local commit = sha("a")
	reports(w, link.agent, `\{"attention": "ok", "reason": "Replied and pushed", "commit": "{commit}", "pr": null, "evidence": [], "blocker": null}`)
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	eq((w.kv.get("runs") :: any)[1].outcome, "replied", "the run records its outcome")
	eq((w.kv.get("runs") :: any)[1].verdict, nil, "and no verdict before the check answers: never Verified on no data")
	local q = st.reply("outcome", { verdict = "not" })
	same({ q.outcome, q.repo, q.number, q.branch, q.commit, q.since, q.login }, { "replied", "o/r", 5, "fix-5", commit, link.started, "cat" } :: { any }, "the check names the run's facts, its start and login")
	eq((w.kv.get("agent-links") :: any)[1].verdict, "not", "Not verified on the link")
	eq((w.kv.get("runs") :: any)[1].verdict, "not", "and on the run")
	w.advance(4100)
	local row: any = statusEvents(w)[#statusEvents(w)].map["o/r#5"]
	same({ row.outcome, row.verdict }, { "replied", "not" }, "and the block is told it")
	reports(w, link.agent, `\{"attention": "ok", "reason": "Done now", "commit": null, "pr": null, "evidence": [], "blocker": null}`)
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	q = st.reply("outcome", { verdict = "verified" })
	eq(q.commit, commit, "a later turn is checked again, with the last commit reported")
	eq((w.kv.get("runs") :: any)[1].verdict, "verified", "the same run is Verified")
	eq(#(w.kv.get("runs") :: any), 1, "with no second run")
	for _, t in w.toasts do
		lacks(t.text, "did not answer", "no check is toasted")
	end
end)

windowCase("window flows: an action with no outcome is never checked, and a host too old to check is not asked or toasted", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local link = startReview(w)
	eq(link.outcome, nil, "Review here names no outcome")
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	eq(#outcomeAsks(w), 0, "no check")
	eq((w.kv.get("runs") :: any)[1].outcome, nil, "and no outcome on the run")
	w.window.panes[link.agent] = nil -- that agent is gone, so nothing asks about starting another
	local main: any = w.window.surfaces[1].main.c
	main[1].p.text = "35"
	local toasts = #w.toasts
	local other = startWithOutcome(w, st, "Watch", "merged")
	w.window.handlers.agent_finished({ pane = other.agent, result = "done" }, w.cx)
	w.flush()
	w.advance(130 * 1000)
	eq(#outcomeAsks(w), 0, "a host on protocol 35 is not asked, at the turn end or later")
	eq((w.kv.get("agent-links") :: any)[1].verdict, nil, "the run has no verdict")
	for i = toasts + 1, #w.toasts do
		lacks(w.toasts[i].text, "older version", "and no version toast is shown for it")
	end
end)

windowCase("window flows: an Unchecked run is checked again once a refresh, a Merged one until it merges or its agent exits", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local link = startWithOutcome(w, st, "Watch", "merged")
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	st.reply("outcome", { verdict = "unchecked", why = "HTTP 502" })
	eq((w.kv.get("agent-links") :: any)[1].verdict, "unchecked", "Unchecked")
	w.advance(30 * 1000)
	eq(#outcomeAsks(w), 1, "not again within the minute")
	w.advance(35 * 1000)
	eq(#outcomeAsks(w), 2, "asked again at the next refresh")
	st.reply("outcome", { verdict = "not" })
	w.advance(65 * 1000)
	eq(#outcomeAsks(w), 3, "Merged and Not verified while its agent runs: asked again")
	st.reply("outcome", { verdict = "verified" })
	w.advance(130 * 1000)
	eq(#outcomeAsks(w), 3, "Verified: never again")
	eq((w.kv.get("runs") :: any)[1].verdict, "verified", "the run is Verified")
	w.window.panes[link.agent] = nil
	local other = startWithOutcome(w, st, "Watch", "merged")
	w.window.handlers.agent_finished({ pane = other.agent, result = "done" }, w.cx)
	w.flush()
	st.reply("outcome", { verdict = "not" })
	w.window.panes[other.agent] = nil
	w.advance(130 * 1000)
	eq(#outcomeAsks(w), 4, "an exited agent's Merged run is not checked again")
	eq((w.kv.get("agent-links") :: any)[1].verdict, "not", "and stays Not verified")
end)

case("usage: reportOf takes only a well-formed report object", function(w: World)
	local usage: any = w.load("usage")
	local sha = string.rep("f", 40)
	local ok = usage.reportOf({ attention = "ok", reason = "Done", commit = sha, evidence = { "ran it" } })
	same({ ok.attention, ok.reason, ok.commit }, { "ok", "Done", sha }, "a valid report")
	eq(ok.pr, nil, "a missing pr is absent")
	eq(ok.blocker, nil, "and so is a missing blocker")
	same(ok.evidence, { "ran it" }, "evidence is kept")
	eq(usage.reportOf({ attention = "ok", reason = "Done", commit = string.rep("f", 64), evidence = {} }).commit, string.rep("f", 64), "a SHA-256 commit is a full SHA too")
	eq(usage.reportOf(nil), nil, "no report")
	local bad: { [string]: any } = {
		["not an object"] = "{\"attention\": \"ok\"}",
		["no attention"] = { reason = "Done", evidence = {} },
		["an unknown attention"] = { attention = "done", reason = "Done", evidence = {} },
		["no reason"] = { attention = "ok", evidence = {} },
		["a blank reason"] = { attention = "ok", reason = "  ", evidence = {} },
		["a short commit"] = { attention = "ok", reason = "Done", commit = "abc1234", evidence = {} },
		["a commit that is no hex"] = { attention = "ok", reason = "Done", commit = string.rep("g", 40), evidence = {} },
		["a pr that is no URL"] = { attention = "ok", reason = "Done", pr = "#9", evidence = {} },
		["no evidence"] = { attention = "ok", reason = "Done" },
		["evidence that is no list of strings"] = { attention = "ok", reason = "Done", evidence = { 1 } },
		["a blocker that is no string"] = { attention = "stuck", reason = "Blocked", evidence = {}, blocker = 5 },
	}
	for why, r in bad do
		eq(usage.reportOf(r), nil, why)
	end
end)

windowCase("window flows: an oversized report is cut to the store caps", function(w: World)
	w.load("window")
	local link = startReview(w)
	local evidence: { string } = {}
	for i = 1, 30 do
		table.insert(evidence, `"{i}{string.rep("e", 500)}"`)
	end
	reports(w, link.agent, `\{"attention": "stuck", "reason": "{string.rep("r", 1000)}", "pr": "https://github.com/o/r/pull/{string.rep("9", 900)}", "evidence": [{table.concat(evidence, ",")}], "blocker": "{string.rep("b", 1000)}"}`)
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	local run: any = (w.kv.get("runs") :: any)[1]
	eq(run.attention, "stuck", "an oversized report is still read")
	eq(#run.reason, 200, "its reason cut to 200 bytes")
	eq(#run.blocker, 200, "and its blocker")
	eq(#run.pr, 500, "its pull request URL to 500")
	eq(#run.evidence, 20, "20 evidence strings kept")
	eq(#run.evidence[1], 200, "each cut to 200 bytes")
	local l: any = (w.kv.get("agent-links") :: any)[1]
	same({ #l.reason, #l.blocker }, { 200, 200 }, "the link's texts are cut as well")
end)

windowCase("window flows: a report whose line plotroom_report cut at a non-BMP character is recorded", function(w: World)
	w.load("window")
	local link = startReview(w)
	-- The extension's exact result text (plugin/omp/plotroom.ts) for reason "🎉 " .. 196 "a" .. "😀 tail", evidence
	-- 199 "b" .. "🎉 x" and blocker 199 "c" .. "😀": each 😀/🎉 straddled the 200-unit cut and was dropped whole.
	local party = "\u{1F389}"
	reports(w, link.agent, `\{"attention":"stuck","reason":"{party} {string.rep("a", 196)}","commit":null,"pr":null,"evidence":["{string.rep("b", 199)}"],"blocker":"{string.rep("c", 199)}"}`)
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	local run: any = (w.kv.get("runs") :: any)[1]
	local reason = `{party} {string.rep("a", 195)}`
	same({ run.attention, run.reason, run.blocker }, { "stuck", reason, string.rep("c", 199) }, "the run records its attention and reason, cut whole to 200 bytes")
	same(run.evidence, { string.rep("b", 199) }, "and its evidence")
	local l: any = (w.kv.get("agent-links") :: any)[1]
	same({ l.attention, l.reason }, { "stuck", reason }, "and so does the link")
end)

windowCase("window flows: a malformed run log or usage store is never overwritten, and the report says which part is missing", function(w: World)
	w.load("window")
	w.kv.put("runs", { { key = 5 } })
	w.kv.put("usage", { since = "yesterday" })
	local link = startReview(w)
	w.window.handlers.agent_finished({ pane = link.agent, result = "done" }, w.cx)
	w.flush()
	same(w.kv.get("runs"), { { key = 5 } }, "the malformed run log is left as it is")
	same(w.kv.get("usage"), { since = "yesterday" }, "and so is the malformed usage store")
	w.window.focused = 1
	w.command("usage-report")
	same(w.kv.get("usage"), { since = "yesterday" }, "running the report does not write it either")
	local text = w.copied[#w.copied]
	has(text, "Usage counts on the block's host could not be read", "the host published no counts")
	has(text, "Usage counts on this machine is malformed", "this machine's store is named")
	has(text, "The run log is malformed", "and so is the run log")
	eq(w.toasts[#w.toasts].text, "Usage report copied, with parts missing", "the toast says parts are missing")
end)

windowCase("window flows: Copy usage report lists both machines' counts by name and the runs by action, with results and median run time", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local hostUsage = { since = EPOCH - 2 * 86400, counts = { ["queue:refresh"] = { n = 3, at = EPOCH - 60 }, ["row:export"] = { n = 9, at = EPOCH } } }
	table.insert(w.window.surfaces[1].main.c, { id = "main.usage", p = { text = jsonEncode({ usage = hostUsage }), hidden = true } })
	-- This machine's store: its own commands and actions; a queue count here is the host's to report.
	w.kv.put("usage", { since = EPOCH - 3600, counts = { ["queue:refresh"] = { n = 50, at = EPOCH }, ["action:Review"] = { n = 4, at = EPOCH - 120 } } })
	w.kv.put(
		"runs",
		array({
			{ key = "o/r#1", action = "Review", result = "done", started = EPOCH - 1000, ended = EPOCH - 940 },
			{ key = "o/r#2", action = "Review", result = "failed", started = EPOCH - 1000, ended = EPOCH - 880 },
			{ key = "o/r#3", action = "Review", result = "done", started = EPOCH - 1000, ended = EPOCH - 400 },
			{ key = "o/r#4", action = "Fix", result = "closed", ended = EPOCH },
		})
	)
	st.palette({ items = {}, commands = { { id = "usage-report" } } })
	w.window.choose = "Copy usage report"
	w.click("plotroom://more")
	w.flush()
	local text = w.copied[#w.copied]
	has(text, "Since " .. os.date("!%Y-%m-%d", EPOCH - 2 * 86400), "since the first recorded day of either machine")
	has(text, "Queue action · Refresh · 3 · last " .. os.date("!%Y-%m-%d %H:%M", EPOCH - 60), "the host's queue action, by its label")
	lacks(text, "· 50 ·", "this machine's copy of a queue count is not the host's")
	lacks(text, "· 9 ·", "nor is the host's copy of a window count")
	has(text, "Commands row · Copy usage report · 1", "the Commands row just picked counts on this machine")
	has(text, "Action · Review · 4", "a saved action by name")
	has(text, "Review · 3 runs · done 2, failed 1, exited 0, closed 0 · median 2m 0s", "runs grouped by action, with each result and the median")
	has(text, "Fix · 1 run · done 0, failed 0, exited 0, closed 1 · median unknown", "a run with no recorded start has no time")
	lacks(text, "Missing", "nothing is missing")
	w.window.focused = 1
	w.command("usage-report")
	has(w.copied[#w.copied], "Tern's palette command · Copy usage report · 1", "the Tern palette command counts by its title")
end)

windowCase("window flows: links survive a plugin VM reboot (kv) and the timer starts again with the window", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agentgo", "plotroom://github/agentgo/o/r/5")
	seedAgent(w, 50, "idle", 1, "o/r#5")
	local start: any = w.window.handlers.window_start
	start(w.cx)
	w.advance(4100)
	same(statusEvents(w)[1].map, { ["o/r#5"] = { state = "idle" } }, "the saved link gives the state, and no texts for a link saved without them")
	w.window.choose = nil
	w.click("plotroom://github/agentgo/o/r/5")
	eq(w.window.focused, 50, "the link focuses the recorded agent")
end)

windowCase("window flows: a reload with a live linked agent restarts the status timer", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agentgo", "plotroom://github/agentgo/o/r/5")
	seedAgent(w, 50, "idle", 1, "o/r#5")
	w.load("window") -- the plugin reloads with the link saved in kv
	w.advance(4100)
	eq(#statusEvents(w) >= 1, true, "the load itself started the timer")
end)

local function announce(w: World, pane: number, text: string?)
	w.window.surfaces[pane] = if text then { main = { id = "main", c = { { id = "main.rpc", p = { text = text, hidden = true } } } } } else {}
end

local function protocolWarning(w: World, pane: number): string?
	local segments = (w.window.status :: any)({ pane = pane })
	return if segments then segments[1].text else nil
end

windowCase("window status: a mismatched host warns while its block is focused, a missing marker waits, and it follows the host back to a match", function(w: World)
	w.load("window")
	announce(w, 1, "2")
	w.window.handlers.window_start(w.cx)
	eq(protocolWarning(w, 1), "Plotroom on host1 is a different version from this window's", "an announcement of another protocol warns at once, naming the host")
	eq(w.window.refreshes, 1, "the status line was redrawn")
	announce(w, 1, asks.protocol)
	w.advance(2100)
	eq(protocolWarning(w, 1), nil, "a reloaded host that matches clears it while focused")
	announce(w, 1, "3")
	w.advance(2000)
	eq(protocolWarning(w, 1), "Plotroom on host1 is a different version from this window's", "and a later mismatch warns again")
	announce(w, 1, nil)
	w.advance(2000)
	eq(protocolWarning(w, 1), nil, "a host that has not announced yet is loading, not mismatched")
	announce(w, 1, asks.protocol)
	w.advance(2000)
	eq(protocolWarning(w, 1), nil, "and its marker arriving as a match stays quiet")
	local before = w.window.refreshes
	w.advance(10000)
	eq(w.window.refreshes, before, "polling with no change redraws nothing")
	eq(w.window.reads[1], 11, "one read at start, one at load and one per tick: a single timer")
end)

windowCase("window status: a window loaded while a Plotroom block is focused checks without any lifecycle event, with one timer", function(w: World)
	announce(w, 1, "2")
	w.load("window")
	eq(protocolWarning(w, 1), nil, "nothing is read while the plugin loads")
	w.advance(1)
	eq(protocolWarning(w, 1), "Plotroom on host1 is a different version from this window's", "the load's own check warns")
	eq(w.window.reads[1], 1, "with one read")
	w.window.handlers.focus({ pane = 1, tab = 1 }, w.cx)
	w.window.handlers.window_start(w.cx)
	eq(w.window.reads[1], 3, "events check at once")
	w.advance(2000)
	eq(w.window.reads[1], 4, "and add no second timer")
	w.advance(6000)
	eq(w.window.reads[1], 7, "one read per tick afterwards")
end)

windowCase("window status: only the focused Plotroom pane is checked, and leaving it stops the polling and the warning", function(w: World)
	w.load("window")
	w.window.panes[2] = { block = "plugin.terminal", cwd = "/", tab = 1 }
	w.window.panes[3] = { block = "plugin.plotroom.prs", cwd = "/work/r", tab = 1 }
	announce(w, 1, "2")
	announce(w, 3, asks.protocol)
	w.window.handlers.pane_created({ pane = 3 }, w.cx)
	eq(protocolWarning(w, 1), "Plotroom on host1 is a different version from this window's", "the focused pane's host is checked")
	eq(w.window.reads[3], nil, "an unfocused Plotroom pane is not read")
	w.window.focused = 3
	w.window.handlers.focus({ pane = 3, tab = 1 }, w.cx)
	eq(protocolWarning(w, 1), nil, "another matching pane does not carry the first one's warning")
	eq(w.window.reads[3], 1, "the newly focused pane is read at once")
	w.window.focused = 2
	w.window.handlers.focus({ pane = 2, tab = 1 }, w.cx)
	local reads = { w.window.reads[1], w.window.reads[3] }
	w.advance(20000)
	same({ w.window.reads[1], w.window.reads[3] }, reads, "an unrelated pane stops the polling")
	w.window.focused = 1
	w.window.handlers.focus({ pane = 1, tab = 1 }, w.cx)
	eq(protocolWarning(w, 1), "Plotroom on host1 is a different version from this window's", "focus back checks at once")
	w.window.panes[1] = nil
	w.window.focused = 2
	w.window.handlers.pane_closed({ pane = 1 }, w.cx)
	eq(protocolWarning(w, 1), nil, "a closed pane's warning is cleared")
end)

windowCase("window flows: a link recorded for another host is ignored, and an agent on another host is not linked", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agentgo", "plotroom://github/agentgo/x/y/1")
	seedAgent(w, 51, "idle", 2, "x/y#1")
	seedAgent(w, 52, "idle", 1, "o/r#9")
	w.window.handlers.window_start(w.cx)
	w.advance(4100)
	same(statusEvents(w)[1].map, { ["o/r#9"] = { state = "idle" } }, "the other host's key is not in this block's map")
	w.window.focused = 1
	local said = #w.toasts
	w.click("plotroom://github/agentgo/x/y/1")
	eq(w.window.focused, 1, "its agent is not focused")
	eq(w.toasts[said + 1].text, "No agent is running for x/y#1", "and the link says so")
	-- a new agent block on another host than the block: no link
	local before = #(w.kv.get("agent-links") :: any)
	w.window.hostOf = setmetatable({ [1] = 1 }, { __index = function() return 2 end }) :: any
	startAgentOn(w, st)
	eq(#w.window.agents, 1, "the agent started")
	eq(#(w.kv.get("agent-links") :: any), before, "but no link was saved")
end)

windowCase("window flows: a malformed agent-links store is never written over", function(w: World)
	w.load("window")
	local st = flowHost(w)
	w.kv.put("agent-links", { { key = 5 } })
	local before = w.kv.store["agent-links"]
	startAgentOn(w, st)
	eq(#w.window.agents, 1, "the agent started")
	eq(w.kv.store["agent-links"], before, "the store is as it was")
	eq(w.toasts[#w.toasts - 1].text, "Agent started, but not linked to o/r#5", "and the user is told")
end)

windowCase("window flows: an agent-links store whose texts are not strings is malformed and never written over", function(w: World)
	w.load("window")
	local st = flowHost(w)
	seedAgent(w, 50, "idle", 1, "o/r#4")
	local links: any = w.kv.get("agent-links")
	links[1].action = 5
	w.kv.put("agent-links", links)
	local before = w.kv.store["agent-links"]
	startAgentOn(w, st)
	eq(w.kv.store["agent-links"], before, "the store is as it was")
end)

windowCase("window flows: a Jira issue's agentgo link goes to the agent recorded under its lower-case project key", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agentgo", "plotroom://issue/agentgo/ABC/ABC-12")
	seedAgent(w, 50, "working", 1, "abc#ABC-12")
	w.click("plotroom://issue/agentgo/ABC/ABC-12")
	eq(w.window.focused, 50, "the recorded pane is focused")
end)

windowCase("window flows: Interrupt, Stop and Message reach the recorded agent's pane, Stop's Cancel stops nothing, and an exited agent, a blank message or a refused one only toasts", function(w: World)
	w.load("window")
	local st = flowHost(w)
	for _, act in { "agentint", "agentstop", "agentmsg" } do
		st.link("layer.queue.buttons." .. act, h.prLink(act, "o/r", 5))
	end
	seedAgent(w, 50, "idle", 1, "o/r#4")
	seedAgent(w, 51, "working", 1, "o/r#5")
	local calls = w.window.agentCalls
	w.click(h.prLink("agentint", "o/r", 5))
	same(calls, { { op = "interrupt", pane = 51 } }, "Interrupt reaches the recorded pane, not its neighbour")
	eq(w.window.agentStates[51], "working", "and closes nothing")
	w.window.choose = "Cancel"
	w.click(h.prLink("agentstop", "o/r", 5))
	w.flush()
	eq(#calls, 1, "Stop's Cancel stops nothing")
	eq(w.window.picks[#w.window.picks].items[1].label, "Cancel", "Cancel is the first row")
	w.window.choose = "Stop agent"
	w.click(h.prLink("agentstop", "o/r", 5))
	w.flush()
	same(calls[2], { op = "stop", pane = 51 }, "the Stop row stops it")
	w.window.typed = "  keep going  "
	w.click(h.prLink("agentmsg", "o/r", 5))
	w.flush()
	same(calls[3], { op = "ask", pane = 51, text = "keep going" }, "Message sends the trimmed line")
	w.window.typed = "   "
	w.click(h.prLink("agentmsg", "o/r", 5))
	w.flush()
	eq(#calls, 3, "a blank message sends nothing")
	eq(w.toasts[#w.toasts].level, "info", "and says so")
	w.window.typed = "hi"
	w.window.askFails = true
	w.click(h.prLink("agentmsg", "o/r", 5))
	w.flush()
	eq(#calls, 3, "a message the agent cannot take sends nothing")
	eq(w.toasts[#w.toasts].level, "error", "and toasts")
	w.window.agentStates[51] = nil
	w.window.panes[51] = nil
	w.click(h.prLink("agentint", "o/r", 5))
	eq(#calls, 3, "an exited agent gets nothing")
	eq(w.toasts[#w.toasts].text, "No agent is running for o/r#5", "and the toast says so")
	w.click(h.prLink("agentint", "o/r", 6))
	eq(w.toasts[#w.toasts].level, "error", "a link its node does not carry is refused")
end)

windowCase("window flows: Now's Reply… sends one line to an agent that needs input, and one that stopped waiting before the reply is sent gets Message agent's toast with nothing sent", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agentreply", h.prLink("agentreply", "o/r", 5))
	seedAgent(w, 51, "waiting_input", 1, "o/r#5")
	local calls = w.window.agentCalls
	w.window.typed = "  yes, rebase it  "
	w.click(h.prLink("agentreply", "o/r", 5))
	w.flush()
	same(calls, { { op = "ask", pane = 51, text = "yes, rebase it" } }, "the reply is sent as Message agent… sends it, trimmed")
	has(w.window.prompts[#w.window.prompts].placeholder, "Reply to the agent of o/r#5", "it asked for one line")
	-- The agent stops waiting while the reply is typed (the prompt answers on a later turn).
	local asked = #w.window.prompts
	w.window.typed = "too late"
	w.click(h.prLink("agentreply", "o/r", 5))
	w.window.agentStates[51] = "working"
	w.flush()
	eq(#w.window.prompts, asked + 1, "the line was asked for while it waited")
	eq(#calls, 1, "nothing is sent once it stopped waiting")
	eq(w.toasts[#w.toasts].text, "No agent is running for o/r#5", "and the toast is Message agent's")
	w.click(h.prLink("agentreply", "o/r", 5))
	w.flush()
	eq(#w.window.prompts, asked + 1, "an agent that no longer waits is not asked for a reply at all")
	eq(w.toasts[#w.toasts].text, "No agent is running for o/r#5", "it toasts the same")
	w.window.agentStates[51] = "waiting_input"
	w.window.typed = "   "
	w.click(h.prLink("agentreply", "o/r", 5))
	w.flush()
	eq(#calls, 1, "a blank reply sends nothing")
	eq(w.toasts[#w.toasts].text, "Nothing to send: the message was blank", "and says so")
end)

windowCase("window flows: an agent link switches to the exact recorded pane, even with other agents in the same folder", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agentgo", "plotroom://github/agentgo/o/r/5")
	seedAgent(w, 50, "idle", 1, "o/r#4")
	seedAgent(w, 51, "working", 1, "o/r#5")
	w.window.panes[50].cwd = w.window.panes[51].cwd
	w.click("plotroom://github/agentgo/o/r/5")
	eq(w.window.focused, 51, "the recorded pane, not a pane in the same cwd")
	eq(w.window.switches[#w.window.switches], 1, "in its session")
	local said = #w.toasts
	w.click("plotroom://github/agentgo/o/r/6")
	eq(w.toasts[said + 1].level, "error", "a link its node does not carry is refused")
end)

windowCase("window flows: a live agent is offered before another is started", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agent", "plotroom://github/agent/o/r/5")
	st.palette({ items = {} })
	seedAgent(w, 50, "waiting_input", 1, "o/r#5")
	w.window.choose = "Go to agent (needs input)"
	w.click("plotroom://github/agent/o/r/5")
	w.flush()
	same(flowRows(w.window.picks[1]), { "Go to agent (needs input)", "Start another agent" }, "the existing agent first")
	same(st.ops(), {}, "the host is asked nothing")
	eq(w.window.focused, 50, "going to it focuses it")
	w.window.choose = "Start another agent"
	local picks = #w.window.picks
	w.click("plotroom://github/agent/o/r/5")
	w.flush()
	eq(#w.window.picks, picks + 2, "another agent leads to the usual menu")
	-- an exited agent is not offered
	w.window.agentStates[50] = "exited"
	picks = #w.window.picks
	w.click("plotroom://github/agent/o/r/5")
	w.flush()
	eq(#w.window.picks, picks + 1, "the menu again, with nothing offered before it")
	same(st.ops(), {}, "and the host still asked nothing")
end)

windowCase("window flows: a plan is confirmed Cancel first, and nothing is committed on Cancel, dismissal or a target row", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local function plan(token: string)
		w.command("assign-me")
		w.flush()
		st.reply("act", { token = token, confirm = { head = "Assign o/r#7 to you?", label = "Assign", lines = { "o/r#7", "as octocat" } } })
	end
	plan("t1")
	same(flowRows(w.window.picks[1]), { "Cancel", "Assign", "o/r#7", "as octocat" }, "Cancel, the commit choice, then the target lines")
	eq(w.window.picks[1].placeholder, "Assign o/r#7 to you?", "the host's head")
	w.window.choose = nil
	plan("t2")
	w.window.choose = "Cancel"
	plan("t3")
	w.window.choose = "o/r#7"
	plan("t4")
	same(st.ops(), { "act", "act", "act", "act" }, "no commit for a dismissal, Cancel or a target row")
	w.window.choose = "Assign"
	plan("t5")
	local ops = st.ops()
	eq(ops[#ops], "commit", "the choice commits")
	local commit = st.reply("commit", { ok = true, message = "Assigned", url = "https://github.com/o/r/issues/7" })
	eq(commit.token, "t5", "with the token of this very plan")
	eq(w.toasts[#w.toasts].text, "Assigned", "the result is told")
	eq(w.toasts[#w.toasts].sub, "https://github.com/o/r/issues/7", "with its link")
	w.command("assign-me")
	w.flush()
	st.reply("act", { problem = "Already assigned" })
	eq(w.toasts[#w.toasts].level, "error", "a refusal is an error")
	eq(w.toasts[#w.toasts].sub, "Already assigned", "that says why")
end)

windowCase("window flows: the draft PR flow asks info, destination, bases, preview, edits, plan, confirm, then commits", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local reviews = 0
	w.window.decide = function(opts: any): (string?, boolean?)
		local ph: string = opts.placeholder or ""
		if string.find(ph, "^Where should the draft PR") then
			return "Open the pull request on o/r", nil
		elseif string.find(ph, "^Open a draft PR from feat into") then
			return "develop", nil
		elseif string.find(ph, "^Draft PR: ") then
			reviews += 1
			return if reviews == 1 then "Edit title…" else "Create with this title and description", nil
		end
		return "Create draft PR", nil
	end
	w.window.typedQueue = { "New title" }
	w.command("draft-pr")
	w.flush()
	st.reply("draft", { repo = "o/r", branch = "feat", path = "/wt/r5", destinations = { { repo = "o/r", remote = "origin" } } })
	same(flowRows(w.window.picks[1]), { "Open the pull request on o/r" }, "a single destination is still asked, and named")
	eq(w.window.picks[1].items[1].detail, "origin", "with its remote")
	local bases = st.reply("draft", { repo = "o/r", remote = "origin", bases = { "develop", "main" }, defaultBase = "main" })
	eq(bases.repo, "o/r", "the bases are asked for the chosen repository")
	same(flowRows(w.window.picks[2]), { "main", "develop" }, "the default base first, the others after")
	local preview = st.reply("draft", { draft = true, token = "d1", repo = "o/r", title = "Add thing", body = "Body", commits = { "abc1234 Add thing" }, branch = "feat", base = "develop", remote = "origin", count = 1, needsPush = true })
	eq(preview.base, "develop", "the preview is for the picked base")
	eq(preview.repo, "o/r", "and the chosen repository")
	eq(w.window.picks[3].items[1].label, "Cancel", "the review lists Cancel first")
	eq(w.window.picks[3].items[2].label, "Create with this title and description", "then the way on")
	eq(w.window.prompts[1].value, "Add thing", "the title edit starts from the host's title")
	local plan = st.reply("draft", { token = "p1", confirm = { head = "Push feat and create draft PR", label = "Create draft PR", lines = { "Repository: o/r", "Push feat to origin" } } })
	eq(plan.title, "New title", "the edited title is planned")
	eq(plan.body, "Body", "the body as the host made it")
	eq(plan.token, "d1", "under the preview's token")
	same(flowRows(w.window.picks[#w.window.picks]), { "Cancel", "Create draft PR", "Repository: o/r", "Push feat to origin" }, "the plan's confirm, Cancel first")
	local phases: { string } = {}
	for _, q in requestsSent(w) do
		if q.op == "draft" then
			table.insert(phases, q.phase)
		end
	end
	same(phases, { "info", "bases", "preview", "plan" }, "phases in order")
	local ops = st.ops()
	eq(ops[#ops], "commit", "then the commit")
	local commit = st.reply("commit", { ok = true, message = "Draft PR created", url = "https://github.com/o/r/pull/9" })
	eq(commit.token, "p1", "with the plan's token")
	eq(w.toasts[#w.toasts].sub, "https://github.com/o/r/pull/9", "the toast links the PR")
end)

windowCase("window flows: several draft destinations are all offered, the chosen one gets the bases, and cancelling sends nothing more", function(w: World)
	w.load("window")
	local st = flowHost(w)
	w.window.choose = "Open the pull request on up/r"
	w.command("draft-pr")
	w.flush()
	st.reply("draft", { repo = "me/r", branch = "feat", destinations = { { repo = "me/r", remote = "origin" }, { repo = "up/r", remote = "upstream" } } })
	same(flowRows(w.window.picks[1]), { "Open the pull request on me/r", "Open the pull request on up/r" }, "every destination, the default first")
	w.window.choose = nil
	local sent = #requestsSent(w)
	local bases = st.reply("draft", { repo = "up/r", remote = "upstream", bases = { "main" }, defaultBase = "main" })
	eq(bases.repo, "up/r", "the bases of the chosen destination")
	w.flush()
	eq(#requestsSent(w), sent, "a dismissed base picker sends nothing")
	-- cancelling the destination picker sends nothing after info
	w.command("draft-pr")
	w.flush()
	st.reply("draft", { repo = "me/r", branch = "feat", destinations = { { repo = "me/r", remote = "origin" } } })
	local asked: any = requestsSent(w)[#requestsSent(w)]
	eq(asked.phase, "info", "only info was asked")
	eq(#requestsSent(w), sent + 1, "nothing followed a dismissed destination picker")
end)

windowCase("window flows: rerun-failed offers every failed run, plans the picked one, and sends nothing when cancelled", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local runs: { any } = {}
	for i = 1, 8 do
		table.insert(runs, { id = tostring(1000 + i), label = "CI run " .. i })
	end
	w.window.choose = "CI run 7"
	w.command("rerun-failed")
	w.flush()
	st.reply("act", { runs = runs })
	eq(#w.window.picks[1].items, 8, "all eight runs are in the picker")
	local again = st.reply("act", { token = "r1", confirm = { head = "Re-run?", label = "Re-run", lines = { "o/r run 1007" } } })
	eq(again.run, "1007", "the 7th run's id is sent")
	eq(again.name, "rerun-failed", "for the same action")
	w.window.choose = nil
	local sent = #requestsSent(w)
	w.command("rerun-failed")
	w.flush()
	st.reply("act", { runs = runs })
	eq(#requestsSent(w), sent + 1, "a cancelled run picker sends nothing more")
end)

windowCase("window flows: Ignore this check… offers the failing checks the host names, plans the picked one, and sends nothing when cancelled", function(w: World)
	w.load("window")
	local st = flowHost(w)
	w.window.choose = "lint"
	w.command("ignore-check")
	w.flush()
	st.reply("act", { checks = { "approval", "lint" } })
	same(flowRows(w.window.picks[1]), { "approval", "lint" }, "every failing check the host named")
	local again = st.reply("act", { token = "i1", confirm = { head = "Ignore lint in o/r?", label = "Ignore check", lines = { "x" } } })
	eq(again.name, "ignore-check", "the same action")
	eq(again.check, "lint", "with the picked check")
	w.window.choose = nil
	local sent = #requestsSent(w)
	w.command("ignore-check")
	w.flush()
	st.reply("act", { checks = { "approval", "lint" } })
	eq(#requestsSent(w), sent + 1, "a cancelled check picker sends nothing more")
end)

windowCase("window flows: Esc on the draft title prompt returns to the review with the earlier values", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local reviews = 0
	w.window.decide = function(opts: any): (string?, boolean?)
		local ph: string = opts.placeholder or ""
		if string.find(ph, "^Where should") then
			return "Open the pull request on o/r", nil
		elseif string.find(ph, "^Open a draft PR from") then
			return "main", nil
		elseif string.find(ph, "^Draft PR: ") then
			reviews += 1
			return if reviews <= 2 then "Edit title…" else "Create with this title and description", nil
		end
		return "Cancel", nil
	end
	w.window.typedQueue = { "New title" }
	w.window.typed = nil -- then Esc
	w.command("draft-pr")
	w.flush()
	st.reply("draft", { repo = "o/r", branch = "feat", destinations = { { repo = "o/r", remote = "origin" } } })
	st.reply("draft", { repo = "o/r", remote = "origin", bases = { "main" }, defaultBase = "main" })
	st.reply("draft", { draft = true, token = "d1", repo = "o/r", title = "Add thing", body = "Body", commits = {}, branch = "feat", base = "main", remote = "origin", count = 1, needsPush = false })
	eq(reviews, 3, "the review came back after the edit and after Esc")
	local plan = st.reply("draft", { token = "p1", confirm = { head = "Create", label = "Create draft PR", lines = { "Repository: o/r" } } })
	eq(plan.title, "New title", "the earlier (edited) title is planned")
	eq(plan.body, "Body", "and the earlier body")
end)

windowCase("window flows: agent status is resent when the block's acknowledgement is absent or differs", function(w: World)
	w.load("window")
	flowHost(w)
	seedAgent(w, 50, "idle", 1, "o/r#5")
	w.window.handlers.window_start(w.cx)
	w.advance(4100)
	eq(#statusEvents(w), 1, "sent once")
	w.advance(8000)
	eq(#statusEvents(w), 1, "the host holds it: quiet")
	local main: any = (w.window.surfaces[1] :: any).main.c
	for i = #main, 1, -1 do
		if main[i].id == "main.agents" then
			table.remove(main, i)
		end
	end
	w.advance(4000)
	eq(#statusEvents(w), 2, "a host that lost its map (no acknowledgement) is told again")
end)

windowCase("window flows: the status report stays under the host's 40000-byte cap when titles are mostly JSON escapes", function(w: World)
	w.load("window")
	flowHost(w)
	for i = 1, 100 do
		seedAgent(w, 50 + i, "idle", 1, "o/r#" .. i)
	end
	local links: any = w.kv.get("agent-links")
	for _, l in links do
		l.title = string.rep("\1", 100) -- 100 raw bytes, 600 once JSON-encoded
	end
	w.kv.put("agent-links", links)
	w.window.handlers.window_start(w.cx)
	w.advance(4100)
	local sent: any = nil
	for _, e in w.window.events do
		if e.ev.act == "agent-status" then
			sent = e.ev.value
		end
	end
	yes(sent ~= nil and #sent <= 40000, "the encoded report is within the host's cap")
	eq(statusEvents(w)[1].map["o/r#100"].state, "idle", "every agent still has its state")
end)

windowCase("window flows: palette commands send plain events, and the command palette lists, in its groups, the typed prompt, the saved actions, the queue's actions and only the commands the host says apply", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local function last(): any
		return w.window.events[#w.window.events].ev
	end
	local rows: { any } = {
		{ "mark-seen", "triage", "seen" },
		{ "snooze", "triage", "snooze" },
		{ "toggle-snoozed", "triage", "toggle-snoozed" },
		{ "sort", "sort", "next" },
		{ "worktrees-open", "open-worktrees" },
	}
	for _, row in rows do
		w.command(row[1])
		same(last(), { ev = "action", act = row[2], value = row[3] }, row[1])
	end
	-- What the host says applies with no item selected, and with a GitHub issue selected.
	local views = { id = "scope:worktrees", label = "Worktrees", key = "", group = "Views", detail = "Worktrees" }
	local nothing: { queue: { any }, commands: { { id: string, group: string? } } } = {
		queue = { { id = "snoozed", label = "Show or hide snoozed", key = "", group = "Filter & Sort" }, views, { id = "settings", label = "Settings", key = "", group = "Configuration" } },
		commands = { { id = "open-url" }, { id = "worktrees-open" } },
	}
	local issue: { queue: { any }, commands: { { id: string, group: string? } } } = {
		queue = {
			{ id = "open", label = "Open", key = "", group = "GitHub - Issue" },
			{ id = "seen", label = "Mark seen", key = "m", group = "Triage" },
			{ id = "agentgo", label = "Go to agent", key = "", group = "Actions" },
			views,
			{ id = "settings", label = "Settings", key = "", group = "Configuration" },
		},
		commands = {
			{ id = "open-url" },
			{ id = "assign-me", group = "GitHub - Issue" },
			{ id = "issue-close", group = "GitHub - Issue" },
			{ id = "comment", group = "GitHub - Issue" },
			{ id = "draft-pr", group = "GitHub - Issue" },
		},
	}
	-- Publishes `ctx` as the block's palette and opens it: what it lists, by label, and the pick.
	local function palette(choose: string?, ctx: any): ({ string }, any)
		st.palette({
			items = { { id = "p1", label = "Review", detail = "Review {url}", key = "e", worktree = true } },
			queue = ctx.queue,
			commands = ctx.commands,
		})
		w.window.choose = choose
		local picks = #w.window.picks
		w.click("plotroom://more")
		w.flush()
		local pick = w.window.picks[picks + 1]
		return flowRows(pick), pick
	end
	local listed, pick = palette(nil, nothing)
	same(listed, { "Show or hide snoozed", "Worktrees", "Open item by URL…", "Settings" }, "with no item selected: what needs none, in the group order, the queue's actions before the commands of their group; Worktrees is the Views scope, not a command of its own")
	eq(pick.items[1].group, "Filter & Sort", "the view's action under Filter & Sort")
	eq(pick.items[2].group, "Views", "a scope under Views")
	eq(pick.items[2].detail, "Worktrees", "naming the sidebar group it sits under")
	eq(pick.items[3].group, "Views", "and Open item by URL with it")
	st.link("layer.queue.buttons.agent", prLink("agent", "o/r", 5))
	st.link("layer.queue.buttons.prompt-p1", runLink("o/r", 5, "p1"))
	listed, pick = palette(nil, issue)
	same(listed, { "Type a prompt…", "Review", "Go to agent", "Open", "Assign to me", "Comment…", "Close issue…", "Draft PR…", "Mark seen", "Worktrees", "Open item by URL…", "Settings" }, "with an item selected: Actions first (typed prompt, actions, Go to agent), then its type's operations (Draft PR among them), Triage, Views and Configuration, and nothing the host did not name")
	eq(table.find(listed, "Agent picker"), nil, "there is no agent picker row")
	eq(table.find(listed, "Re-run failed checks"), nil, "nor a re-run without a failed run")
	local byLabel: { [string]: any } = {}
	for _, row in pick.items do
		byLabel[row.label] = row
	end
	eq(byLabel["Open"].group, "GitHub - Issue", "Open carries the item's type")
	eq(byLabel["Mark seen"].group, "Triage", "marking seen is Triage")
	eq(byLabel["Type a prompt…"].group, "Actions", "the typed prompt is under Actions")
	eq(byLabel["Go to agent"].group, "Actions", "Go to agent is too")
	eq(byLabel["Assign to me"].group, "GitHub - Issue", "the host's group for an issue operation")
	eq(byLabel["Draft PR…"].group, "GitHub - Issue", "draft creation belongs to the selected issue")
	local every: { queue: { any }, commands: { { id: string, group: string? } } } = {
		queue = { { id = "extra", label = "Extra", key = "", group = "Elsewhere" } },
		commands = {
			{ id = "rerun-failed", group = "GitHub - PR" },
			{ id = "pr-ready", group = "GitHub - PR" },
			{ id = "pr-merge", group = "GitHub - PR" },
			{ id = "pr-approve", group = "GitHub - PR" },
			{ id = "pr-request-changes", group = "GitHub - PR" },
			{ id = "pr-update-branch", group = "GitHub - PR" },
			{ id = "pr-empty-commit", group = "GitHub - PR" },
			{ id = "comment", group = "GitHub - PR" },
			{ id = "draft-pr", group = "GitHub - Issue" },
			{ id = "open-url" },
			{ id = "usage-report" },
			{ id = "worktrees-open" },
			{ id = "mark-seen" },
			{ id = "no-such-command" },
		},
	}
	listed = palette(nil, every)
	same(listed, { "Type a prompt…", "Review", "Comment…", "Ready for review…", "Merge…", "Approve…", "Request changes…", "Update branch…", "Push empty commit…", "Re-run failed checks", "Draft PR…", "Open item by URL…", "Copy usage report", "Extra" }, "every group in its place: Saved actions, Jira - Issue, GitHub - PR, GitHub - Issue, Views, Configuration, then one the window does not know; a keyed command and an unknown id are never listed")
	palette("Mark seen", issue)
	same(last(), { ev = "action", act = "queue", value = "seen" }, "a queue action is sent back as the block's queue action")
	palette("Assign to me", issue)
	eq(st.ops()[#st.ops()], "act", "an item command runs its flow")
	w.window.typed = "  Looks good to me  "
	palette("Comment…", issue)
	local commentAsk = requestsSent(w)[#requestsSent(w)]
	eq(commentAsk.op, "act", "Comment asks the host")
	eq(commentAsk.name, "comment", "for a comment")
	eq(commentAsk.text, "Looks good to me", "with the typed text, trimmed")
	w.window.typed = nil
	palette("Review", issue)
	eq(st.ops()[#st.ops()], "menu", "a saved action runs through its hidden link: the host is asked for it")
	eq(requestsSent(w)[#requestsSent(w)].only, "p1", "just that one")
	st.reply("menu", { items = {} })
	w.window.typed = "Fix the flaky test"
	palette("Type a prompt…", issue)
	local wt = st.reply("worktree", { path = "/wt/five", summary = "Created", created = true, current = true })
	eq(wt.number, 5, "a typed prompt prepares the selected item's worktree, with no agent picker")
	local said = #w.toasts
	w.window.surfaces[1] = { main = { id = "main", c = { { id = "main.rpc", p = { text = asks.protocol } } } } }
	w.click("plotroom://more")
	eq(w.toasts[said + 1].level, "error", "a link the block does not carry is refused")
end)

windowCase("window flows: the Next row leads Commands, and plotroom://next runs the window command the block names as its next move only while it offers it", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local queue = {
		{ id = "open", label = "Open", key = "", group = "GitHub - PR" },
		{ id = "next", label = "Ready for review…", key = "x", group = "Next" },
	}
	st.palette({ items = {}, queue = queue, commands = { { id = "pr-ready", group = "GitHub - PR" } }, next = "pr-ready" })
	st.link("layer.queue.buttons.agent", prLink("agent", "o/r", 7))
	w.window.choose = nil
	w.click("plotroom://more")
	w.flush()
	local pick = w.window.picks[#w.window.picks]
	eq(pick.items[1].label, "Ready for review…", "the next move is the first row")
	eq(pick.items[1].group, "Next", "under Next")
	eq(pick.items[1].detail, "key x", "with its key")
	w.click("plotroom://next")
	w.flush()
	eq(st.ops()[#st.ops()], "act", "the link runs the command's own flow")
	eq(requestsSent(w)[#requestsSent(w)].name, "pr-ready", "the one named, which plans before anything is sent")
	local ops = #st.ops()
	st.palette({ items = {}, queue = queue, commands = { { id = "pr-ready", group = "GitHub - PR" } }, next = "pr-merge" })
	w.click("plotroom://next")
	w.flush()
	eq(#st.ops(), ops, "a command the block does not offer is never run")
	eq(w.toasts[#w.toasts].text, "Plotroom: that move is no longer offered here", "and says so")
end)

windowCase("window flows: comment, close, reopen, ready for review and convert to draft ask the host to plan and only a confirmed plan is committed, Cancel first", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local function plan(command: string, head: string, label: string): any
		w.command(command)
		w.flush()
		return st.reply("act", { token = "t-" .. command, confirm = { head = head, label = label, lines = { "o/r#7: Fix login", "Account: @octocat" } } })
	end
	local asked = plan("issue-close", "Close o/r#7?", "Close issue")
	eq(asked.name, "issue-close", "Close issue asks for the issue-close plan")
	same(flowRows(w.window.picks[#w.window.picks]), { "Cancel", "Close issue", "o/r#7: Fix login", "Account: @octocat" }, "Cancel first, then the choice, then the plan's lines")
	eq(w.window.picks[#w.window.picks].placeholder, "Close o/r#7?", "under the host's question")
	same(st.ops(), { "act" }, "nothing is committed before it is confirmed")
	w.window.choose = "Cancel"
	asked = plan("issue-reopen", "Reopen o/r#7?", "Reopen issue")
	eq(asked.name, "issue-reopen", "Reopen issue asks for issue-reopen")
	asked = plan("pr-ready", "Mark o/r#7 ready for review?", "Ready for review")
	eq(asked.name, "pr-ready", "Ready for review asks for pr-ready")
	asked = plan("pr-draft", "Convert o/r#7 to a draft?", "Convert to draft")
	eq(asked.name, "pr-draft", "Convert to draft asks for pr-draft")
	same(st.ops(), { "act", "act", "act", "act" }, "Cancel committed none of the four")
	w.window.choose = "Close issue"
	plan("issue-close", "Close o/r#7?", "Close issue")
	local ops = st.ops()
	eq(ops[#ops], "commit", "the confirming row commits")
	eq(st.reply("commit", { ok = true, message = "Closed o/r#7" }).token, "t-issue-close", "with the token of that very plan")
	eq(w.toasts[#w.toasts].text, "Closed o/r#7", "and the result is told")
	w.window.typed = "  Thanks, merging\nsoon  "
	w.window.choose = "Add comment"
	w.command("comment")
	w.flush()
	local commentAsk = st.reply("act", { token = "t-comment", confirm = { head = "Comment on o/r#7?", label = "Add comment", lines = { "o/r#7: Fix login", "Comment (20 characters): Thanks, merging ⏎ soon" } } })
	eq(commentAsk.name, "comment", "Comment asks for a comment plan")
	eq(commentAsk.text, "Thanks, merging\nsoon", "with the typed text, trimmed")
	eq(st.reply("commit", { ok = true, message = "Commented on o/r#7" }).token, "t-comment", "and commits only once confirmed")
	w.window.typed = "   "
	local before = #requestsSent(w)
	w.command("comment")
	w.flush()
	eq(#requestsSent(w), before, "a blank comment asks nothing")
	w.window.typed = nil
end)

windowCase("window flows: Mark read… asks the host to plan Now's threads and commits only a confirmed plan, Cancel first, with the account in the confirm", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local function plan(): any
		w.command("mark-read")
		w.flush()
		return st.reply("act", { token = "t-read", confirm = { head = "Mark 3 notifications read?", label = "Mark 3 read", lines = { "Account: @octocat", "Mark 3 notifications read (GitHub keeps them in the inbox; none is marked done)", "o/r: 3" } } })
	end
	w.window.choose = "Cancel"
	eq(plan().name, "mark-read", "asks for the mark-read plan")
	same(flowRows(w.window.picks[#w.window.picks]), { "Cancel", "Mark 3 read", "Account: @octocat", "Mark 3 notifications read (GitHub keeps them in the inbox; none is marked done)", "o/r: 3" }, "Cancel first, then the choice, then the account and what happens")
	same(st.ops(), { "act" }, "Cancel commits nothing")
	w.window.choose = "Mark 3 read"
	plan()
	local ops = st.ops()
	eq(ops[#ops], "commit", "the confirming row commits")
	eq(st.reply("commit", { ok = true, message = "Marked 3 notifications read as @octocat" }).token, "t-read", "with the token of that very plan")
	eq(w.toasts[#w.toasts].text, "Marked 3 notifications read as @octocat", "the result is told")
	w.command("mark-read")
	w.flush()
	st.reply("act", { problem = "Now lists no notifications to mark read." })
	eq(w.toasts[#w.toasts].text, "Not marked read", "a refusal is titled for the command")
end)

windowCase("window flows: Merge picks one of the host's methods (or auto-merge), Approve's comment is optional, Request changes needs one, Update branch and Push empty commit plan; every plan is Cancel first and nothing commits unconfirmed", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local function lastAsk(): any
		return requestsSent(w)[#requestsSent(w)]
	end
	local lines = { "o/r#7: Fix login", "Account: @octocat" }
	w.window.choose = "Rebase and merge"
	w.command("pr-merge")
	w.flush()
	st.reply("act", { methods = { { id = "squash", label = "Squash and merge" }, { id = "rebase", label = "Rebase and merge" } }, auto = true })
	same(flowRows(w.window.picks[#w.window.picks]), { "Squash and merge", "Rebase and merge", "Auto-merge when checks pass", "Auto-merge when checks pass" }, "the allowed methods, then auto-merge for each while checks are pending")
	eq(lastAsk().name .. ":" .. tostring(lastAsk().method) .. ":" .. tostring(lastAsk().auto), "pr-merge:rebase:false", "the picked method is planned, not auto")
	w.window.choose = "Cancel"
	st.reply("act", { token = "t-merge", confirm = { head = "Merge o/r#7?", label = "Merge", lines = lines } })
	same(flowRows(w.window.picks[#w.window.picks]), { "Cancel", "Merge", "o/r#7: Fix login", "Account: @octocat" }, "Cancel first, then the choice, then the plan's lines")
	w.window.choose = "Auto-merge when checks pass"
	w.command("pr-merge")
	w.flush()
	st.reply("act", { methods = { { id = "squash", label = "Squash and merge" } }, auto = true })
	eq(lastAsk().name .. ":" .. tostring(lastAsk().method) .. ":" .. tostring(lastAsk().auto), "pr-merge:squash:true", "auto-merge plans its method with auto")
	w.window.choose = "Cancel"
	st.reply("act", { problem = "stop" })
	w.window.typed = "  Ship it  "
	w.command("pr-approve")
	w.flush()
	eq(lastAsk().name .. ":" .. tostring(lastAsk().text), "pr-approve:Ship it", "Approve sends the trimmed comment")
	st.reply("act", { token = "t-approve", confirm = { head = "Approve o/r#7?", label = "Approve", lines = lines } })
	same(flowRows(w.window.picks[#w.window.picks]), { "Cancel", "Approve", "o/r#7: Fix login", "Account: @octocat" }, "Approve is Cancel first")
	w.window.typed = "   "
	w.command("pr-approve")
	w.flush()
	eq(lastAsk().name .. ":" .. tostring(lastAsk().text), "pr-approve:nil", "a blank approval comment is none")
	st.reply("act", { problem = "stop" })
	local before = #requestsSent(w)
	w.command("pr-request-changes")
	w.flush()
	eq(#requestsSent(w), before, "a blank request for changes asks nothing")
	w.window.typed = "Please add tests"
	w.command("pr-request-changes")
	w.flush()
	eq(lastAsk().name .. ":" .. tostring(lastAsk().text), "pr-request-changes:Please add tests", "Request changes sends its comment")
	st.reply("act", { token = "t-changes", confirm = { head = "Request changes on o/r#7?", label = "Request changes", lines = lines } })
	same(flowRows(w.window.picks[#w.window.picks]), { "Cancel", "Request changes", "o/r#7: Fix login", "Account: @octocat" }, "Request changes is Cancel first")
	w.window.typed = nil
	w.command("pr-update-branch")
	w.flush()
	eq(lastAsk().name, "pr-update-branch", "Update branch asks for its plan")
	st.reply("act", { token = "t-update", confirm = { head = "Update the branch of o/r#7?", label = "Update branch", lines = lines } })
	same(flowRows(w.window.picks[#w.window.picks]), { "Cancel", "Update branch", "o/r#7: Fix login", "Account: @octocat" }, "Update branch is Cancel first")
	w.window.typed = nil
	w.command("pr-empty-commit")
	w.flush()
	eq(lastAsk().name, "pr-empty-commit", "Push empty commit asks for its plan")
	st.reply("act", { token = "t-empty", confirm = { head = "Push an empty commit to o/r#7?", label = "Push empty commit", lines = lines } })
	same(flowRows(w.window.picks[#w.window.picks]), { "Cancel", "Push empty commit", "o/r#7: Fix login", "Account: @octocat" }, "Push empty commit is Cancel first")
	for _, op in st.ops() do
		yes(op ~= "commit", "Cancel committed nothing")
	end
end)

windowCase("window flows: a Worktrees list link opens the path, or focuses the tab already there", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.wtopen", "plotroom://worktrees/open/2")
	w.click("plotroom://worktrees/open/2")
	w.flush()
	local req = st.reply("worktree-path", { path = "/wt/one" })
	eq(req.n, 2, "row 2 is asked for")
	eq(w.window.launches[1].cwd, "/wt/one", "a tab opens at its path")
	local tabs = #w.window.launches
	w.click("plotroom://worktrees/open/2")
	w.flush()
	st.reply("worktree-path", { path = "/wt/one" })
	eq(#w.window.launches, tabs, "a tab already working there is focused instead")
	yes(w.window.focused ~= 1, "and focused")
	local said = #w.toasts
	w.click("plotroom://worktrees/open/3")
	eq(w.toasts[said + 1].level, "error", "a row the node does not carry is refused")
end)

windowCase("window flows: Open in Git opens Tern's git block on the host's path, and is refused for a remote block, a stale link and a git that fails", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local url = h.tokened("plotroom://worktrees/git")
	st.link("layer.queue.buttons.git", url)
	w.click(url)
	w.flush()
	st.reply("git-path", { path = "/wt/one" })
	same(w.window.gitOpened, { "/wt/one" }, "the git block opens on the folder the host names")
	w.click(url)
	w.flush()
	st.reply("git-path", { problem = "That worktree is no longer there." })
	eq(w.toasts[#w.toasts].text, "Git not opened", "a host that has no folder any more says so")
	eq(#w.window.gitOpened, 1, "and nothing opens")
	w.window.gitFail = "no repository"
	w.click(url)
	w.flush()
	st.reply("git-path", { path = "/wt/one" })
	w.flush()
	eq(w.toasts[#w.toasts].sub, "no repository", "a git block that fails to open is told")
	w.window.gitFail = nil
	local asked, said = #requestsSent(w), #w.toasts
	w.window.remoteHost = true
	w.click(url)
	w.flush()
	eq(#requestsSent(w), asked, "a remote block is not even asked")
	eq(w.toasts[said + 1].level, "error", "it is refused")
	eq(#w.window.gitOpened, 2, "and nothing opens: Tern's git block reads this machine's repositories")
	w.window.remoteHost = false
	local surface: any = w.window.surfaces[1]
	surface.layer.c = {}
	said = #w.toasts
	w.click(url)
	w.flush()
	eq(w.toasts[said + 1].level, "error", "a link the block does not carry is refused")
end)

windowCase("window flows: Open item by URL reuses a Plotroom block, and launches one (waiting for it) when there is none", function(w: World)
	w.load("window")
	local st = flowHost(w)
	w.window.typed = "https://github.com/o/r/pull/5"
	w.command("open-url")
	w.flush()
	local req = st.reply("open-url", { ok = true, message = "Opened o/r#5" })
	eq(req.url, "https://github.com/o/r/pull/5", "the URL goes to the block")
	eq(#w.window.launches, 0, "no block is launched")
	eq(w.toasts[#w.toasts].text, "Opened o/r#5", "the answer is told")
	-- no Plotroom block: launch one, wait for its protocol node, then send
	w.window.panes[1].block = nil
	w.window.surfaces[1] = nil
	w.command("open-url")
	w.flush()
	eq(#w.window.launches, 1, "a block is launched")
	local launched = 0
	for id, p in w.window.panes do
		if p.block == "plotroom.prs" then
			launched = id
		end
	end
	w.advance(1200)
	same(st.ops(), { "open-url" }, "nothing is sent while the block is not ready")
	local st2 = flowHost(w, launched)
	w.advance(2000)
	same(st2.ops(), { "open-url", "open-url" }, "once it says its protocol the URL is sent, to the launched block")
	st2.reply("open-url", { problem = "Not an item URL" })
	eq(w.toasts[#w.toasts].level, "error", "a refusal is an error")
	-- never ready: a toast, after about ten seconds
	w.window.panes[launched] = nil
	w.window.surfaces[launched] = nil
	w.command("open-url")
	w.flush()
	w.advance(11000)
	eq(w.toasts[#w.toasts].text, "Plotroom did not start in time", "a block that never answers is given up on")
end)

windowCase("window flows: Open item by URL waits for an existing Plotroom block that has not rendered yet, and sends at once to a ready one", function(w: World)
	w.load("window")
	-- ready: the URL goes out with no timer step
	local st = flowHost(w)
	w.window.typed = "https://github.com/o/r/pull/5"
	w.command("open-url")
	w.flush()
	same(st.ops(), { "open-url" }, "a ready block is asked at once")
	st.reply("open-url", { ok = true, message = "Opened o/r#5" })
	-- existing but not rendered yet: it says its protocol a few hundred ms later
	w.window.surfaces[1] = {}
	local said = #w.toasts
	w.command("open-url")
	w.flush()
	w.advance(700)
	same(st.ops(), { "open-url" }, "nothing is sent before the block renders")
	local st2 = flowHost(w)
	w.advance(500)
	same(st2.ops(), { "open-url", "open-url" }, "once it renders the URL is sent to it")
	st2.reply("open-url", { ok = true, message = "Opened o/r#5" })
	eq(#w.window.launches, 0, "no block is launched")
	for i = said + 1, #w.toasts do
		yes(w.toasts[i].text ~= "Plotroom did not start in time", "a block that renders late is not given up on")
	end
	eq(w.toasts[#w.toasts].text, "Opened o/r#5", "the item is opened")
	-- existing and never rendered: the same budget as a launched block, then a toast
	w.window.surfaces[1] = {}
	said = #w.toasts
	w.command("open-url")
	w.flush()
	w.advance(9000)
	eq(#w.toasts, said, "the budget is not spent before ten seconds")
	w.advance(2000)
	eq(w.toasts[#w.toasts].text, "Plotroom did not start in time", "a block that never renders is given up on")
	same(st2.ops(), { "open-url", "open-url" }, "and no URL is sent")
end)

case("lens: a gh pr create transcript offers to show, copy and open the new pull request; output without its URL stays raw", function(w: World)
	w.load("host")
	local def: any = w.lenses["pr-create"]
	yes(def ~= nil, "the manifest's lens is defined")
	local url = "https://github.com/o/r/pull/45"
	local function run(lines: { string }, status: number?): (any, any)
		local state = def.open({ line = "gh pr create", typed = "gh pr create", program = "gh", args = { "pr", "create" } }, w.cx)
		for _, text in lines do
			def.line(state, { text = text, links = {} })
		end
		def.finish(state, status or 0)
		return state, def.view(state)
	end
	local _, view = run({ "Creating pull request for fix into main in o/r", "", url })
	local show = findKey(view, "show", "item")
	eq(show.p.label, "Show in Plotroom", "the lens offers Show in Plotroom")
	eq(show.p.href, "plotroom://lens/show/" .. "https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F45", "as a link carrying the page")
	eq(findKey(view, "browser", "item").p.href, url, "Open in browser opens the page")
	eq(findKey(view, "url", "text").p.spans[1].t, url, "the URL is shown")
	local copy = findKey(view, "copy", "item")
	eq(copy.p.href, url, "Copy carries the URL, which Tern's copy action copies")
	eq(copy.p.actions.click, "copy", "by the built-in copy action")
	eq(def.event, nil, "the lens handles no events of its own")
	local _, none = run({ "aborted: could not push", "pull requests are listed at https://github.com/o/r/pulls" })
	eq(none, nil, "output without a pull request URL shows the raw output")
	local _, exists = run({ "a pull request for branch \"fix\" into branch \"main\" already exists:", url }, 1)
	eq(exists, nil, "gh's already-exists failure (exit 1) shows its raw output, not the old pull request")
end)

windowCase("window flows: the lens's show link works from a shell pane, while an item link from it is still refused", function(w: World)
	w.load("window")
	local st = flowHost(w)
	w.window.panes[2] = { block = "plugin.terminal", cwd = "/", tab = 1 }
	local page = "https://github.com/o/r/pull/45"
	w.click("plotroom://lens/show/https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F45", 2)
	w.flush()
	eq(st.reply("open-url", { ok = true, message = "Showing o/r#45 in Plotroom" }).url, page, "the page goes to the block as Open item by URL sends it")
	eq(#w.window.launches, 0, "no block is launched while one is open")
	local said = #w.toasts
	w.click("plotroom://lens/show/https%3A%2F%2Fevil.example%2Fx", 2)
	eq(w.toasts[said + 1].text, "Plotroom: malformed link", "a page that is no pull request is refused")
	st.link("layer.queue.buttons.worktree", "plotroom://github/worktree/o/r/45")
	w.click("plotroom://github/worktree/o/r/45", 2)
	eq(w.toasts[said + 2].text, "Plotroom: link did not come from a Plotroom block", "a worktree link from the shell pane is refused")
	same(st.ops(), { "open-url" }, "and nothing else was asked of the block")
end)

windowCase("window flows: the lens's show link with no Plotroom block focuses the shell pane before launching one", function(w: World)
	w.load("window")
	w.window.panes[1].block = nil
	w.window.panes[2] = { block = "plugin.terminal", cwd = "/lens", tab = 1 }
	w.window.panes[3] = { block = "plugin.terminal", cwd = "/other", tab = 1 }
	w.window.focused = 3
	w.click("plotroom://lens/show/https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fpull%2F45", 2)
	w.flush()
	eq(#w.window.launches, 1, "a Plotroom block is launched")
	eq(w.window.launches[1].cwd, "/lens", "beside the pane the lens is in, not the focused one")
end)

case("host triage: unseen rows are New, the selected row is marked seen on its own and saved to kv triage, a refresh writes nothing, a changed check or review shows Changed on a row nobody reads and is marked again on the row being read", function(w: World)
	local s = hostScene(w, 3)
	local b = openQueue(w)
	eq(pickerOf(b).selected, "no_2fr_231", "the first row is selected on arrival")
	same(asks.hx.marks(b), { "-", "New", "New" }, "and its preview marked it seen: the others are New")
	eq(#w.toasts, 0, "without a toast")
	local saved: any = w.kv.get("triage")
	eq(saved.version, 1, "the store is versioned")
	same(asks.hx.keys(saved.items), { "o/r#1" }, "and holds the one row")
	eq(#saved.items["o/r#1"].seen, 16, "by its signature")
	b.press("down")
	same(asks.hx.marks(b), { "-", "-", "New" }, "moving on marks the next one too")
	eq(b.press("escape"), false, "Escape closes no preview: it is left to the pane")
	eq(pickerOf(b).selected, "no_2fr_232", "the selection stays")
	local text = w.kv.store["triage"]
	refreshNow(w, b)
	eq(w.kv.store["triage"], text, "a refresh writes nothing")
	same(asks.hx.marks(b), { "-", "-", "New" }, "the refreshed rows are still seen")
	s.gh.items.octocat[1] = searchItem(1, "o/r", EPOCH - 60, { checks = "FAILURE" })
	refreshNow(w, b)
	same(asks.hx.marks(b), { "Changed", "-", "New" }, "the same update time with new checks is Changed on a row nobody has open")
	eq(w.kv.store["triage"], text, "showing it writes nothing")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_231" })
	same(asks.hx.marks(b), { "-", "-", "New" }, "opening it marks it seen again")
	local again = w.kv.store["triage"]
	yes(again ~= text, "and saves that")
	s.gh.items.octocat[1] = searchItem(1, "o/r", EPOCH - 60, { checks = "FAILURE", review = "REVIEW_REQUIRED" })
	refreshNow(w, b)
	same(asks.hx.marks(b), { "-", "-", "New" }, "a new review decision on the row being read is marked at once")
	yes(w.kv.store["triage"] ~= again, "with its new signature saved")
	b.typeText("m")
	eq(w.toasts[#w.toasts].text, "Marked seen", "m still marks and says so")
end)

case("host triage: a save that fails is told once and tried again only when the row changes", function(w: World)
	local s = hostScene(w, 3)
	w.kv.failSet["triage"] = "read-only file system"
	local b = openQueue(w)
	eq(w.toasts[#w.toasts].level, "error", "a save that fails is an error toast")
	eq(w.toasts[#w.toasts].text, "Not saved", "saying nothing was saved")
	same(asks.hx.marks(b), { "New", "New", "New" }, "the row stays New")
	local told = #w.toasts
	b.render()
	b.render()
	w.advance(61 * 1000)
	eq(#w.toasts, told, "later renders and polls do not try again, or tell again")
	w.kv.failSet["triage"] = nil
	b.render()
	eq(w.kv.store["triage"], nil, "even once the disk works")
	s.gh.items.octocat[1] = searchItem(1, "o/r", EPOCH - 60, { checks = "FAILURE" })
	refreshNow(w, b)
	same(asks.hx.marks(b), { "-", "New", "New" }, "a change to the row tries again, and saves")
end)

case("host triage: z snoozes the selected row until 08:00 tomorrow and the row that takes its place is selected, Z lists snoozed rows with a Snoozed badge, z on one ends the snooze, and a snooze that ran out hides nothing", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	local all = { "no_2fr_231", "no_2fr_232", "no_2fr_233" }
	eq(pickerOf(b).selected, "no_2fr_231", "the first row is selected")
	b.typeText("z")
	same(listed(b), { "no_2fr_232", "no_2fr_233" }, "the snoozed row leaves the list")
	eq(pickerOf(b).selected, "no_2fr_232", "and the row that took its place is selected")
	has(w.toasts[#w.toasts].text, "Snoozed until", "the toast says so")
	eq(pickerOf(b).scopes[2].count, 2, "the sidebar count leaves the snoozed row out")
	has(w.toasts[#w.toasts].text, "08:00", "tomorrow morning")
	local entry: any = w.kv.get("triage").items["o/r#1"]
	eq(entry.snoozeUntil, EPOCH + 20 * 3600, "saved until 08:00 the next day")
	eq(type(entry.seen), "string", "it was marked seen when it was selected; snoozing itself marks nothing")
	b.typeText("Z")
	eq(pickerOf(b).scopes[2].count, 3, "and counts it again while snoozed rows are listed")
	same(listed(b), all, "Z lists the snoozed rows too")
	eq(asks.hx.mark(b, "no_2fr_231"), "Snoozed", "the snoozed one wears a Snoozed badge")
	eq(asks.hx.mark(b, "no_2fr_232"), "-", "the row that took its place is read now")
	eq(asks.hx.mark(b, "no_2fr_233"), "New", "the others keep theirs")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_231" })
	b.typeText("z")
	eq(w.toasts[#w.toasts].text, "Snooze ended", "z on a snoozed row ends the snooze")
	eq(asks.hx.mark(b, "no_2fr_231"), "-", "it stays seen: ending a snooze marks nothing")
	eq(w.kv.get("triage").items["o/r#1"].snoozeUntil, nil, "and the saved snooze is gone")
	b.typeText("Z")
	same(listed(b), all, "hiding snoozed rows hides nothing while none is")
	w.kv.put("triage", { version = 1, items = { ["o/r#2"] = { at = 1, snoozeUntil = EPOCH - 10 }, ["o/r#3"] = { at = 1, snoozeUntil = EPOCH + 3600 } } })
	local c = openQueue(w, 2)
	same(listed(c), { "no_2fr_231", "no_2fr_232" }, "a snooze that ran out hides its row no longer, one still running does")
end)

case("host triage: a malformed or unreadable kv triage is never overwritten: marking is refused with an error toast and no row is marked", function(w: World)
	hostScene(w, 3)
	w.kv.put("triage", { version = 7, items = {} })
	local bad = w.kv.store["triage"]
	local b = openQueue(w)
	same(asks.hx.marks(b), { "-", "-", "-" }, "without a trusted store no row is marked")
	for _, key in { "m", "z" } do
		b.typeText(key)
		local t = w.toasts[#w.toasts]
		eq(t.level, "error", key .. ": an error toast")
		eq(t.text, "Not saved", key .. ": says nothing was saved")
		has(t.sub, "malformed", key .. ": and why")
		eq(w.kv.store["triage"], bad, key .. ": the saved text is untouched")
	end
	w.kv.put("triage", { version = 1, items = { ["o/r#1"] = { at = "yesterday" } } })
	local odd = w.kv.store["triage"]
	b.typeText("m")
	has(w.toasts[#w.toasts].sub, "malformed", "an entry of the wrong shape makes the store untrusted")
	eq(w.kv.store["triage"], odd, "and is left as it is")
	w.kv.failGet["triage"] = "disk offline"
	b.typeText("m")
	has(w.toasts[#w.toasts].sub, "disk offline", "an unreadable store says why")
	w.kv.failGet["triage"] = nil
	eq(w.kv.store["triage"], odd, "and is not touched")
	w.kv.put("triage", { version = 1, items = {} })
	b.typeText("m")
	eq(w.toasts[#w.toasts].text, "Marked seen", "a readable store works again")
	yes(w.kv.get("triage").items["o/r#1"] ~= nil, "and holds the mark")
end)

case("host triage: two blocks share the store: a row seen or snoozed in one reaches the other", function(w: World)
	hostScene(w, 3)
	local a = openQueue(w, 1)
	local c = openQueue(w, 2)
	same(asks.hx.marks(c), { "-", "New", "New" }, "the row the first block read is seen in both")
	eq(pickerOf(c).selected, "no_2fr_231", "and each selects its own first row")
	local drawn = c.renders()
	a.press("down")
	yes(c.renders() > drawn, "the other block is drawn again")
	same(asks.hx.marks(c), { "-", "-", "New" }, "and shows the next row seen")
	eq(pickerOf(c).selected, "no_2fr_231", "without moving its own selection")
	c.typeText("z")
	same(listed(c), { "no_2fr_232", "no_2fr_233" }, "a snooze in the second block hides the row there")
	same(listed(a), { "no_2fr_232", "no_2fr_233" }, "and in the first")
	eq(pickerOf(a).selected, "no_2fr_232", "where the selection is untouched")
end)

case("host sort: a saved sort orders the list, one this view cannot take is dropped, and the Sort by row saves a choice, refuses a foreign one and resets to the default order", function(w: World)
	local s = hostScene(w, 3)
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 300), searchItem(2, "o/r", EPOCH - 60), searchItem(3, "o/r", EPOCH - 180, { review = "REVIEW_REQUIRED" }) }
	w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "My PRs", integration = "github", query = "is:open author:@me", logins = array({}), group = "none", prompts = array({}), sort = "priority" },
		{ id = "v2", name = "Review requested", integration = "github", query = "is:open review-requested:@me", logins = array({}), group = "none", prompts = array({}), sort = "oldest" },
	}) })
	local b = openQueue(w)
	same(listed(b), { "no_2fr_232", "no_2fr_233", "no_2fr_231" }, "a sort pull requests do not offer is dropped: the default order stays")
	pickScope(b, "prs:v2")
	w.flush()
	same(listed(b), { "no_2fr_231", "no_2fr_233", "no_2fr_232" }, "a saved oldest-first sort orders the other view")
	pickScope(b, "prs:v1")
	w.flush()
	goToSettings(b, "views")
	expand(b, "vopen:prs:v1")
	eq(rowIn(b, "vsort:prs:v1").control.value, "default", "the row shows the dropped sort as the default order")
	same(asks.hx.options(b, "vsort:prs:v1"), { "default", "updated", "oldest", "review", "size" }, "pull requests offer these four")
	b.event({ ev = "change", id = "layer.settings", item = "vsort:prs:v1", value = "review" })
	eq(w.kv.get("views-prs").items[1].sort, "review", "a choice is saved with the view")
	same(listed(b), { "no_2fr_233", "no_2fr_232", "no_2fr_231" }, "review required first, then the newest update")
	b.event({ ev = "change", id = "layer.settings", item = "vsort:prs:v1", value = "priority" })
	eq(w.kv.get("views-prs").items[1].sort, "review", "another integration's sort is refused")
	b.event({ ev = "change", id = "layer.settings", item = "vsort:prs:v1", value = "updated" })
	same(listed(b), { "no_2fr_232", "no_2fr_233", "no_2fr_231" }, "the newest update first")
	b.event({ ev = "change", id = "layer.settings", item = "vsort:prs:v1", value = "default" })
	eq(w.kv.get("views-prs").items[1].sort, nil, "the default order saves no sort")
	same(listed(b), { "no_2fr_232", "no_2fr_233", "no_2fr_231" }, "and is the default order")
end)

case("host sort: o cycles the view's sorts, saves each with the view and ends on the default order, which leaves the search order untouched", function(w: World)
	local s = hostScene(w, 3)
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 300), searchItem(2, "o/r", EPOCH - 60), searchItem(3, "o/r", EPOCH - 180, { review = "REVIEW_REQUIRED" }) }
	local b = openQueue(w)
	same(listed(b), { "no_2fr_232", "no_2fr_233", "no_2fr_231" }, "without a sort the default order is kept")
	local steps: { { string } } = {
		{ "updated", "Sorted: Recently updated", "no_2fr_232", "no_2fr_233", "no_2fr_231" },
		{ "oldest", "Sorted: Oldest waiting", "no_2fr_231", "no_2fr_233", "no_2fr_232" },
		{ "review", "Sorted: Review required first", "no_2fr_233", "no_2fr_232", "no_2fr_231" },
		{ "size", "Sorted: Largest changes first", "no_2fr_232", "no_2fr_233", "no_2fr_231" },
	}
	for _, step in steps do
		b.typeText("o")
		eq(w.kv.get("views-prs").items[1].sort, step[1], step[1] .. ": saved with the view")
		eq(w.toasts[#w.toasts].text, step[2], step[1] .. ": the toast names it")
		same(listed(b), { step[3], step[4], step[5] }, step[1] .. ": the list follows")
	end
	b.typeText("o")
	eq(w.kv.get("views-prs").items[1].sort, nil, "after the last comes the default order, saved as none")
	eq(w.toasts[#w.toasts].text, "Sorted: Default order", "named")
	same(listed(b), { "no_2fr_232", "no_2fr_233", "no_2fr_231" }, "the default order again")
	b.typeText("/")
	b.typeText("o")
	eq(pickerOf(b).query, "o", "while searching o is text")
	eq(w.kv.get("views-prs").items[1].sort, nil, "and sorts nothing")
end)

case("host sort: Oldest waiting ranks by creation, and Largest changes first by additions plus deletions", function(w: World)
	local s = hostScene(w, 3)
	s.gh.items.octocat = {
		searchItem(1, "o/r", EPOCH - 60, { createdAt = iso(EPOCH - 900), additions = 1, deletions = 1 }),
		searchItem(2, "o/r", EPOCH - 300, { createdAt = iso(EPOCH - 100), additions = 40, deletions = 5 }),
		searchItem(3, "o/r", EPOCH - 180, { createdAt = iso(EPOCH - 500), additions = 3, deletions = 90 }),
	}
	w.kv.put("views-prs", { version = 1, nextId = 2, items = array({ { id = "v1", name = "My PRs", integration = "github", query = "is:open author:@me", logins = array({}), group = "none", prompts = array({}), sort = "oldest" } }) })
	local b = openQueue(w)
	same(listed(b), { "no_2fr_231", "no_2fr_233", "no_2fr_232" }, "oldest by creation: the recently updated one made first is first")
	goToSettings(b, "views")
	expand(b, "vopen:prs:v1")
	b.event({ ev = "change", id = "layer.settings", item = "vsort:prs:v1", value = "size" })
	same(listed(b), { "no_2fr_233", "no_2fr_232", "no_2fr_231" }, "size: 93 lines, then 45, then 2")
end)

case("host sort: switching to a view with the same query and another sort shows its order and its first item before any search lands", function(w: World)
	local s = hostScene(w, 3)
	s.gh.items.octocat = {
		searchItem(1, "o/r", EPOCH - 60, { additions = 1, deletions = 1 }),
		searchItem(2, "o/r", EPOCH - 300, { additions = 40, deletions = 5 }),
		searchItem(3, "o/r", EPOCH - 180, { additions = 3, deletions = 90 }),
	}
	w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "Mine", integration = "github", query = "is:open author:@me", logins = array({}), group = "none", prompts = array({}), sort = "updated" },
		{ id = "v2", name = "Mine big", integration = "github", query = "is:open author:@me", logins = array({}), group = "none", prompts = array({}), sort = "size" },
	}) })
	local b = openQueue(w)
	same(listed(b), { "no_2fr_231", "no_2fr_233", "no_2fr_232" }, "Mine: recently updated first")
	eq(pickerOf(b).selected, "no_2fr_231", "on its first item")
	s.gh.override = function(req: GhReq): Reply?
		return if req.kind == "search" then { delay = 60 * 1000, status = 1, stderr = "HTTP 502: Bad Gateway\n" } else nil
	end
	pickScope(b, "prs:v2")
	w.flush()
	eq(pickerOf(b).scope, "prs:v2", "Mine big")
	same(listed(b), { "no_2fr_233", "no_2fr_232", "no_2fr_231" }, "in its own order while its search has not landed")
	eq(pickerOf(b).selected, "no_2fr_233", "on the first item of that order")
	w.advance(1000)
	local seen: { string } = {}
	for key, e in w.kv.get("triage").items do
		if e.seen then
			table.insert(seen, key)
		end
	end
	table.sort(seen)
	same(seen, { "o/r#1", "o/r#3" }, "only the item each view opened on was marked seen")
end)

case("host sort: a Jira view offers priority alone, o turns it on and off, and GitHub issues offer updated and oldest", function(w: World)
	local s = jiraHost(w)
	s.acli.searches[JIRA_ASSIGNED] = { jiraItem("ABC-12", "Fix login", { priority = { name = "Low" } }), jiraItem("ABC-13", "Old bug", { priority = { name = "Highest" } }) }
	local b = openIssues(w)
	same(listed(b), { "nabc_23ABC-12", "nabc_23ABC-13" }, "acli's order without a sort")
	b.typeText("o")
	eq(w.kv.get("views-issues").items[1].sort, "priority", "o saves the one sort Jira has")
	same(listed(b), { "nabc_23ABC-13", "nabc_23ABC-12" }, "Highest before Low")
	b.typeText("o")
	eq(w.kv.get("views-issues").items[1].sort, nil, "o again is the default order")
	same(listed(b), { "nabc_23ABC-12", "nabc_23ABC-13" }, "acli's order")
	goToSettings(b, "views")
	expand(b, "vopen:issues:v1")
	same(asks.hx.options(b, "vsort:issues:v1"), { "default", "priority" }, "the Sort by row lists only that")
	b.event({ ev = "change", id = "layer.settings", item = "vsort:issues:v1", value = "updated" })
	eq(w.kv.get("views-issues").items[1].sort, nil, "a GitHub sort is refused for a Jira view")
end)

case("host sort: GitHub issues offer updated and oldest, never a review order", function(w: World)
	issueHost(w)
	local b = openIssues(w)
	goToSettings(b, "views")
	expand(b, "vopen:issues:v1")
	same(asks.hx.options(b, "vsort:issues:v1"), { "default", "updated", "oldest" }, "the Sort by row lists those")
	local before = w.kv.store["views-issues"]
	b.event({ ev = "change", id = "layer.settings", item = "vsort:issues:v1", value = "review" })
	eq(w.kv.store["views-issues"], before, "an order only pull requests have is refused: nothing was written")
	b.event({ ev = "change", id = "layer.settings", item = "vsort:issues:v1", value = "oldest" })
	eq(w.kv.get("views-issues").items[1].sort, "oldest", "oldest is saved")
	same(listed(b), { "no_2fr_2314", "no_2fr_2313", "no_2fr_2312" }, "the longest waiting issue first")
end)

case("host agents: agent-status shows a badge per row, drops values and keys it does not know, replaces the whole map and caps it at 200 keys", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	asks.hx.agents(b, { ["o/r#1"] = "working", ["o/r#2"] = "waiting_input", ["o/r#3"] = "idle" })
	same({ asks.hx.agent(b, "no_2fr_231"), asks.hx.agent(b, "no_2fr_232"), asks.hx.agent(b, "no_2fr_233") }, { "Agent working", "Needs you", "Idle" }, "one badge per state")
	asks.hx.agents(b, { ["o/r#3"] = "exited" })
	same({ asks.hx.agent(b, "no_2fr_231"), asks.hx.agent(b, "no_2fr_232"), asks.hx.agent(b, "no_2fr_233") }, { "-", "-", "Exited" }, "a new report replaces the whole map")
	asks.hx.agents(b, { ["o/r#1"] = "sleeping", ["o/r#2"] = "working", ["bad\nkey"] = "working" })
	same({ asks.hx.agent(b, "no_2fr_231"), asks.hx.agent(b, "no_2fr_232"), asks.hx.agent(b, "no_2fr_233") }, { "-", "Agent working", "-" }, "an unknown state is dropped")
	eq(b.state().agents["bad\nkey"], nil, "and so is a key with a control character")
	b.event({ ev = "action", act = "agent-status", value = jsonEncode({ ["o/r#2"] = "idle", pad = string.rep("x", 40000) }) })
	b.event({ ev = "action", act = "agent-status", value = "not json" })
	b.event({ ev = "action", act = "agent-status", value = 5 })
	eq(asks.hx.agent(b, "no_2fr_232"), "Agent working", "an oversize, malformed or mistyped report changes nothing")
	local many: { [string]: string } = {}
	for i = 1, 230 do
		many["x/y#" .. i] = "working"
	end
	asks.hx.agents(b, many)
	local n = 0
	for _ in b.state().agents do
		n += 1
	end
	eq(n, 200, "at most 200 keys are kept")
end)

case("host agents: Go to agent is a Commands row, a hidden link and the G key only for a row whose agent state is known", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	local function offered(): boolean
		return table.find(hx.palette(w, b).ids, "agentgo") ~= nil
	end
	eq(offered(), false, "no state yet: no Commands row")
	eq(buttonLink(b, "agentgo"), nil, "and no link")
	eq(b.press("G", "s", "G"), false, "G is left to the pane")
	asks.hx.agents(b, { ["o/r#1"] = "working" })
	eq(offered(), true, "a known state adds the row")
	eq(hx.palette(w, b).keys.agentgo, "G", "with its key")
	eq(buttonLink(b, "agentgo"), prLink("agentgo", "o/r", 1), "and the link the window follows")
	eq(b.press("G", "s", "G"), true, "G is handled")
	eq(w.opened[#w.opened], prLink("agentgo", "o/r", 1), "and opens the link")
	b.typeText("j")
	eq(offered(), false, "a row with no state has no Commands row")
	eq(buttonLink(b, "agentgo"), nil, "nor a link")
	eq(b.press("G", "s", "G"), false, "and G is the pane's again")
	asks.hx.agents(b, {})
	b.typeText("k")
	eq(offered(), false, "an empty report takes the row away")
end)

case("host mutations: assign-me offers a plan naming the issue and the account that only its commit runs", function(w: World)
	local s = issueHost(w)
	local seen = asks.hx.writes(s.gh)
	local b = openIssues(w)
	local p = asks.hx.ask(w, b, { op = "act", name = "assign-me" })
	yes(type(p.token) == "string" and p.token ~= "", "a plan carries its token")
	eq(p.confirm.head, "Assign o/r#12 to you?", "the question names the issue")
	eq(p.confirm.label, "Assign to me", "the confirming choice")
	eq(p.confirm.lines[1], "o/r#12: Fix login", "the first line is the issue")
	has(p.confirm.lines[2], "octocat", "the second is the account")
	eq(p.confirm.lines[3], "Current assignees: ann, bob", "the third what it has now")
	eq(#seen, 0, "a plan sends nothing")
	local done = asks.hx.ask(w, b, { op = "commit", token = p.token })
	eq(done.ok, true, "the commit answers ok")
	eq(done.message, "Assigned o/r#12 to you", "and what it did")
	same(seen, { "gh issue edit 12 --repo github.com/o/r --add-assignee=@me" }, "one gh call: assign me, nothing else")
	local sent = requestsOf(s.gh, "other")
	eq(sent[#sent].login, "octocat", "run with the token of the account the plan named")
	eq(sent[#sent].call.env.GH_TOKEN, "tok-octocat", "and its token, in the environment")
	local pr = asks.hx.ask(w, b, { op = "act", name = "bogus" })
	eq(pr.problem, "Plotroom does not know that command.", "an unknown command is refused")
end)

case("host mutations: a commit with no token, a made-up or replaced token, after the selection, the view or five minutes changed, or twice sends nothing", function(w: World)
	local s = issueHost(w)
	local seen = asks.hx.writes(s.gh)
	local b = openIssues(w)
	local function plan(): any
		return asks.hx.ask(w, b, { op = "act", name = "assign-me" })
	end
	local function commit(token: any): any
		return asks.hx.ask(w, b, { op = "commit", token = token })
	end
	request(b, "n1", { op = "commit" })
	w.flush()
	eq(answerOf(b, "n1"), nil, "a commit with no token is not answered")
	has(commit("p1_1_123456").problem, "no longer valid", "a made-up token")
	local first = plan()
	local second = plan()
	has(commit(first.token).problem, "no longer valid", "the token of a replaced plan")
	has(commit(second.token).problem, "no longer valid", "a refused commit drops the pending plan as well")
	local moved = plan()
	b.typeText("j")
	has(commit(moved.token).problem, "selection or the view changed", "after the selection moved")
	b.typeText("k")
	local viewed = plan()
	pickScope(b, "issues:v2")
	w.flush()
	has(commit(viewed.token).problem, "selection or the view changed", "after the view changed")
	pickScope(b, "issues:v1")
	w.flush()
	local late = plan()
	w.advance(301 * 1000)
	has(commit(late.token).problem, "nothing was sent", "after five minutes")
	eq(#seen, 0, "none of them sent anything")
	local good = plan()
	eq(commit(good.token).ok, true, "a fresh plan commits")
	eq(#seen, 1, "once")
	has(commit(good.token).problem, "no longer valid", "the same token twice")
	eq(#seen, 1, "sends nothing again")
end)

-- gh's answer to `gh issue view <n>` of o/r as the guarded writes read it: issue n is in state live[n] ("OPEN" or "CLOSED").
local function issueViews(live: { [string]: string }): (string) -> Reply?
	return function(line: string): Reply?
		local n = string.match(line, "^gh issue view (%d+) ")
		if n then
			return { stdout = jsonEncode({ number = tonumber(n), state = live[n], url = "https://github.com/o/r/issues/" .. n }) }
		end
		return nil
	end
end

local function issueView(n: string): string
	return "gh issue view " .. n .. " --repo github.com/o/r --json number,state,url"
end

case("host mutations: close and reopen run gh issue close or reopen on the planned issue, refuse an issue already in that state, and one that changed after the plan", function(w: World)
	local s = issueHost(w)
	local live: { [string]: string } = { ["12"] = "OPEN", ["13"] = "CLOSED" }
	local seen = asks.hx.writes(s.gh, issueViews(live))
	local b = openIssues(w)
	local function plan(name: string): any
		return asks.hx.ask(w, b, { op = "act", name = name })
	end
	local function commit(p: any): any
		return asks.hx.ask(w, b, { op = "commit", token = p.token })
	end
	local function refused(name: string, why: string)
		local p = plan(name)
		yes(p.problem ~= nil and p.token == nil, why .. ": refused with no plan")
	end
	-- #12 is open
	refused("issue-reopen", "an open issue is not reopened")
	eq(#seen, 0, "and nothing was sent")
	eq(commit(plan("issue-close")).ok, true, "closing the open issue commits")
	same(seen, { issueView("12"), "gh issue close 12 --repo github.com/o/r" }, "it reads the issue, then closes it with no reason or other flag")
	local stale = plan("issue-close")
	live["12"] = "CLOSED" -- closed elsewhere after the plan
	yes(commit(stale).problem ~= nil, "an issue closed after the plan is refused at commit")
	eq(#seen, 3, "only its state was read again: no second close")
	-- #13 is closed
	b.typeText("j")
	refused("issue-close", "a closed issue is not closed again")
	eq(#seen, 3, "and nothing was sent")
	eq(commit(plan("issue-reopen")).ok, true, "reopening the closed issue commits")
	same({ seen[4], seen[5] }, { issueView("13"), "gh issue reopen 13 --repo github.com/o/r" }, "it reads the issue, then reopens it")
	local late = plan("issue-reopen")
	live["13"] = "OPEN" -- reopened elsewhere after the plan
	yes(commit(late).problem ~= nil, "an issue reopened after the plan is refused at commit")
	eq(#seen, 6, "only its state was read again: no second reopen")
end)

case("host mutations: ready for review and convert to draft run gh pr ready, with --undo only for the draft, refuse a pull request already in that state, and one that changed after the plan", function(w: World)
	local s = hostScene(w, 0)
	s.gh.items.octocat = { searchItem(5, "o/r", EPOCH - 60, { isDraft = true }), searchItem(6, "o/r", EPOCH - 120) }
	local drafts: { [string]: boolean } = { ["5"] = true, ["6"] = false }
	local seen = asks.hx.writes(s.gh, function(line: string): Reply?
		local n = string.match(line, "^gh pr view (%d+) ")
		if n then
			return { stdout = jsonEncode({ number = tonumber(n), state = "OPEN", isDraft = drafts[n], url = "https://github.com/o/r/pull/" .. n }) }
		end
		return nil
	end)
	local function view(n: string): string
		return "gh pr view " .. n .. " --repo github.com/o/r --json number,state,isDraft,url"
	end
	local b = openQueue(w)
	local function plan(name: string): any
		return asks.hx.ask(w, b, { op = "act", name = name })
	end
	local function commit(p: any): any
		return asks.hx.ask(w, b, { op = "commit", token = p.token })
	end
	local function refused(name: string, why: string)
		local p = plan(name)
		yes(p.problem ~= nil and p.token == nil, why .. ": refused with no plan")
	end
	-- #5 is a draft
	refused("pr-draft", "a draft is not converted to a draft")
	eq(#seen, 0, "and nothing was sent")
	eq(commit(plan("pr-ready")).ok, true, "marking the draft ready commits")
	same(seen, { view("5"), "gh pr ready 5 --repo github.com/o/r" }, "it reads the pull request, then marks it ready: no --undo")
	local stale = plan("pr-ready")
	drafts["5"] = false -- marked ready elsewhere after the plan
	yes(commit(stale).problem ~= nil, "a pull request marked ready after the plan is refused at commit")
	eq(#seen, 3, "only its state was read again: nothing more was sent")
	-- #6 is ready for review
	b.typeText("j")
	refused("pr-ready", "a pull request ready for review is not marked ready again")
	eq(#seen, 3, "and nothing was sent")
	eq(commit(plan("pr-draft")).ok, true, "converting the ready pull request commits")
	same({ seen[4], seen[5] }, { view("6"), "gh pr ready 6 --repo github.com/o/r --undo" }, "it reads the pull request, then converts it with --undo")
	local late = plan("pr-draft")
	drafts["6"] = true -- converted elsewhere after the plan
	yes(commit(late).problem ~= nil, "a pull request converted after the plan is refused at commit")
	eq(#seen, 6, "only its state was read again: nothing more was sent")
end)

case("host mutations: switching gh's active account between plan and commit still runs the planned login with its token", function(w: World)
	local s = issueHost(w)
	local seen = asks.hx.writes(s.gh, issueViews({ ["12"] = "OPEN" }))
	s.gh.tokens.work = "tok-work"
	local b = openIssues(w)
	local p = asks.hx.ask(w, b, { op = "act", name = "issue-close" })
	has(p.confirm.lines[2], "octocat", "the plan names the account gh was using")
	s.gh.active = "work" -- `gh auth switch` before the confirm
	w.advance(30 * 1000)
	eq(asks.hx.ask(w, b, { op = "commit", token = p.token }).ok, true, "committed within five minutes")
	same(seen, { issueView("12"), "gh issue close 12 --repo github.com/o/r" }, "the issue is read and closed")
	local sent = requestsOf(s.gh, "other")
	eq(#sent, 2, "both commands ran")
	for _, req in sent do
		eq(req.login, "octocat", "as the planned login, not the active one")
		eq(req.call.env.GH_TOKEN, "tok-octocat", "with that login's token")
	end
end)

case("host mutations: on a Jira issue assign-me runs acli", function(w: World)
	local s = jiraHost(w)
	local ran: { string } = {}
	s.acli.override = function(req: AcliReq): Reply?
		if req.kind == "other" then
			table.insert(ran, table.concat(req.argv, " "))
			return { stdout = "✓ done\n" }
		end
		return nil
	end
	local b = openIssues(w)
	local p = asks.hx.ask(w, b, { op = "act", name = "assign-me" })
	eq(p.confirm.head, "Assign ABC-12 to you?", "the question names the issue")
	eq(p.confirm.lines[1], "ABC-12: Fix login", "the issue")
	eq(p.confirm.lines[2], "Jira account: ann@example.com at https://acme.atlassian.net", "the account and site")
	has(p.confirm.lines[3], "Current assignee:", "and what it has now")
	eq(#ran, 0, "a plan runs nothing")
	eq(asks.hx.ask(w, b, { op = "commit", token = p.token }).message, "Assigned ABC-12 to you", "committed")
	same(ran, { "acli jira workitem assign --key ABC-12 --assignee @me --yes" }, "one acli call for the signed-in user")
end)

case("host mutations: a Jira comment shows the whole text and the full account and site, and is sent only as that account on that site", function(w: World)
	local s = jiraHost(w)
	s.acli.views["ABC-12"] = jiraItem("ABC-12", "Fix login")
	local ran: { string } = {}
	local auth = "✓ Authenticated\n  Site: acme.atlassian.net\n  Email: ann@example.com\n"
	s.acli.override = function(req: AcliReq): Reply?
		if req.kind == "auth" then
			return { stdout = auth }
		elseif req.kind == "other" then
			table.insert(ran, table.concat(req.argv, " "))
			return { stdout = "✓ done\n" }
		end
		return nil
	end
	local b = openIssues(w)
	local text = string.rep("a", 2999) .. "TAIL"
	local p = asks.hx.ask(w, b, { op = "act", name = "comment", text = text })
	has(p.confirm.lines[2], "ann@example.com", "the full email is shown, not its local part")
	has(p.confirm.lines[2], "https://acme.atlassian.net", "with its site")
	local shown = table.concat(p.confirm.lines, "", 4)
	eq(shown, text, "every character of the text is in the rows, the tail too")
	local long = asks.hx.ask(w, b, { op = "act", name = "comment", text = string.rep("b", 3700) })
	has(long.problem, "too long to show", "a text that would not show in full is refused")
	eq(#ran, 0, "planning wrote nothing")
	auth = "✓ Authenticated\n  Site: acme.atlassian.net\n  Email: ann@other.org\n"
	has(asks.hx.ask(w, b, { op = "commit", token = p.token }).problem, "account changed", "the same local part at another domain is another account")
	eq(#ran, 0, "and nothing was written")
	auth = "✓ Authenticated\n  Site: acme.atlassian.net\n  Email: ann@example.com\n"
	p = asks.hx.ask(w, b, { op = "act", name = "comment", text = "Looks good" })
	auth = "✓ Authenticated\n  Site: elsewhere.atlassian.net\n  Email: ann@example.com\n"
	has(asks.hx.ask(w, b, { op = "commit", token = p.token }).problem, "account changed", "the same email on another site is refused too")
	eq(#ran, 0, "nothing was written there either")
	auth = "✓ Authenticated\n  Site: acme.atlassian.net\n  Email: ann@example.com\n"
	p = asks.hx.ask(w, b, { op = "act", name = "comment", text = "Looks good" })
	eq(asks.hx.ask(w, b, { op = "commit", token = p.token }).message, "Commented on ABC-12", "the same account and site commits")
	same(ran, { "acli jira workitem comment create --key ABC-12 --body=Looks good" }, "one comment, as shown")
end)

case("host mutations: a Jira assign names the account and site and is refused when acli's account changed since the plan", function(w: World)
	local s = jiraHost(w)
	s.acli.views["ABC-12"] = jiraItem("ABC-12", "Fix login")
	local ran: { string } = {}
	local auth = "✓ Authenticated\n  Site: acme.atlassian.net\n  Email: ann@example.com\n"
	s.acli.override = function(req: AcliReq): Reply?
		if req.kind == "auth" then
			return { stdout = auth }
		elseif req.kind == "other" then
			table.insert(ran, table.concat(req.argv, " "))
			return { stdout = "✓ done\n" }
		end
		return nil
	end
	local b = openIssues(w)
	local p = asks.hx.ask(w, b, { op = "act", name = "assign-me" })
	has(p.confirm.lines[2], "ann@example.com", "assign names the full email")
	has(p.confirm.lines[2], "https://acme.atlassian.net", "and the site")
	auth = "✓ Authenticated\n  Site: acme.atlassian.net\n  Email: ann@other.org\n"
	has(asks.hx.ask(w, b, { op = "commit", token = p.token }).problem, "account changed", "another account is refused")
	eq(#ran, 0, "and nothing was assigned")
end)

case("host mutations: a Jira assign works for a signed-in email whose local part has an apostrophe", function(w: World)
	local s = jiraHost(w)
	s.acli.views["ABC-12"] = jiraItem("ABC-12", "Fix login")
	local ran: { string } = {}
	s.acli.override = function(req: AcliReq): Reply?
		if req.kind == "auth" then
			return { stdout = "✓ Authenticated\n  Site: acme.atlassian.net\n  Email: pat.o'brien@corp.com\n" }
		elseif req.kind == "other" then
			table.insert(ran, table.concat(req.argv, " "))
			return { stdout = "✓ done\n" }
		end
		return nil
	end
	local b = openIssues(w)
	local p = asks.hx.ask(w, b, { op = "act", name = "assign-me" })
	eq(p.problem, nil, "the sign-in names its email")
	eq(p.confirm.lines[2], "Jira account: pat.o'brien@corp.com at https://acme.atlassian.net", "the whole email, apostrophe and all")
	eq(asks.hx.ask(w, b, { op = "commit", token = p.token }).message, "Assigned ABC-12 to you", "committed as that account")
	same(ran, { "acli jira workitem assign --key ABC-12 --assignee @me --yes" }, "acli assigned it")
end)

case("host mutations: rerun-failed plans the failed runs by their real run ids, runs view then rerun, and refuses a pull request with none", function(w: World)
	local s = hostScene(w, 0)
	local base = "https://github.com/o/r"
	local done = "2026-01-01T00:00:00Z"
	local checks = {
		checkRun("build", "COMPLETED", "FAILURE", done, { id = "A", detailsUrl = base .. "/actions/runs/123/job/9" }),
		checkRun("lint", "COMPLETED", "FAILURE", done, { id = "B", detailsUrl = base .. "/actions/runs/123/job/10" }),
		checkRun("deploy", "COMPLETED", "FAILURE", done, { id = "C", detailsUrl = base .. "/runs/77" }),
		checkRun("test", "COMPLETED", "SUCCESS", done, { id = "D", detailsUrl = base .. "/actions/runs/124/job/1" }),
	}
	local legacy = { checkRun("old", "COMPLETED", "FAILURE", done, { id = "E", detailsUrl = base .. "/runs/78" }) }
	s.gh.items.octocat = {
		searchItem(1, "o/r", EPOCH - 60, { checks = "FAILURE", runs = array(checks), runTotal = 4 }),
		searchItem(2, "o/r", EPOCH - 120, { checks = "FAILURE", runs = array(legacy), runTotal = 1 }),
	}
	s.gh.checks["o/r#1"] = checks
	s.gh.checks["o/r#2"] = legacy
	local seen = asks.hx.writes(s.gh, function(line: string): Reply?
		if line == "gh run view 123 --repo github.com/o/r --json databaseId,status,conclusion,url" then
			return { stdout = jsonEncode({ databaseId = 123, status = "completed", conclusion = "failure", url = base .. "/actions/runs/123" }) }
		end
		return nil
	end)
	local b = openQueue(w)
	w.advance(300)
	has(asks.hx.ask(w, b, { op = "act", name = "assign-me" }).problem, "Assigning works on issues", "assigning is for issues")
	local p = asks.hx.ask(w, b, { op = "act", name = "rerun-failed" })
	eq(p.confirm.head, "Rerun failed jobs of o/r#1?", "the question names the pull request")
	eq(p.confirm.label, "Rerun failed jobs", "the confirming choice")
	eq(#p.confirm.lines, 3, "one line for the pull request, one for the account, one for the run")
	eq(p.confirm.lines[1], "o/r#1: PR 1", "the pull request")
	eq(p.confirm.lines[3], "Rerun the failed jobs of workflow run 123 (build, lint)", "the one run that has an id, with its failed checks; a check-run link has none")
	eq(#seen, 0, "a plan runs nothing")
	local r = asks.hx.ask(w, b, { op = "commit", token = p.token })
	eq(r.ok, true, "committed")
	same(seen, {
		"gh run view 123 --repo github.com/o/r --json databaseId,status,conclusion,url",
		"gh run rerun 123 --repo github.com/o/r --failed",
	}, "the run is read again, then only its failed jobs rerun")
	b.typeText("j")
	w.advance(300)
	has(asks.hx.ask(w, b, { op = "act", name = "rerun-failed" }).problem, "has a GitHub Actions run to rerun", "a failed check with no run id is not rerun")
	eq(#seen, 2, "and sends nothing")
end)

case("host mutations: rerun-failed with several failed workflow runs lists them, plans exactly the picked one, refuses one that did not fail, and reruns only that run", function(w: World)
	local s = hostScene(w, 0)
	local base = "https://github.com/o/r"
	local done = "2026-01-01T00:00:00Z"
	local checks: { any } = {}
	for i = 1, 7 do
		table.insert(checks, checkRun("job" .. i, "COMPLETED", "FAILURE", done, { id = "J" .. i, detailsUrl = base .. "/actions/runs/20" .. i .. "/job/1" }))
	end
	s.gh.items.octocat = { searchItem(1, "o/r", EPOCH - 60, { checks = "FAILURE", runs = array(checks), runTotal = 7 }) }
	s.gh.checks["o/r#1"] = checks
	local seen = asks.hx.writes(s.gh, function(line: string): Reply?
		local id = string.match(line, "^gh run view (%d+) ")
		if id then
			return { stdout = jsonEncode({ databaseId = tonumber(id), status = "completed", conclusion = "failure", url = base .. "/actions/runs/" .. id }) }
		end
		return nil
	end)
	local b = openQueue(w)
	w.advance(300)
	local listing = asks.hx.ask(w, b, { op = "act", name = "rerun-failed" })
	eq(#listing.runs, 7, "all seven failed runs are pickable")
	eq(listing.runs[1].id, "201", "by run id")
	has(listing.runs[1].label, "job1", "labelled with its failed checks")
	eq(listing.token, nil, "listing is no plan")
	eq(#seen, 0, "nothing was sent")
	local missing = asks.hx.ask(w, b, { op = "act", name = "rerun-failed", run = "999" })
	has(missing.problem, "no longer one this action applies to", "a run that is not among the failed ones is refused")
	eq(#seen, 0, "with no gh call")
	local p = asks.hx.ask(w, b, { op = "act", name = "rerun-failed", run = "205" })
	eq(p.confirm.lines[3], "Rerun the failed jobs of workflow run 205 (job5)", "the plan names the picked run alone")
	eq(#p.confirm.lines, 3, "and no other")
	eq(#seen, 0, "a plan sends nothing")
	eq(asks.hx.ask(w, b, { op = "commit", token = p.token }).ok, true, "committed")
	same(seen, {
		"gh run view 205 --repo github.com/o/r --json databaseId,status,conclusion,url",
		"gh run rerun 205 --repo github.com/o/r --failed",
	}, "exactly the picked run is read and rerun")
end)

case("host mutations: a gh account that cannot sign in fails the commit closed: the plan names it, nothing is sent", function(w: World)
	local s = issueHost(w)
	s.gh.tokens.work = "tok-work"
	s.gh.issueItems.work = { issueItem(12, "o/r", EPOCH - 60, { title = "Fix login" }) }
	w.kv.put("views-issues", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Work", integration = "github", query = "is:open assignee:@me", logins = array({ "work" }), group = "none", prompts = array({}) },
	}) })
	local seen = asks.hx.writes(s.gh)
	local b = openIssues(w)
	eq(pickerOf(b).selected, "no_2fr_2312", "the work account's issue is selected")
	local p = asks.hx.ask(w, b, { op = "act", name = "assign-me" })
	eq(p.confirm.lines[2], "Account: @work", "the plan names the view's account")
	s.gh.tokens["work"] = nil :: any
	w.advance(61000) -- the token cached by the plan's reads has expired
	local r = asks.hx.ask(w, b, { op = "commit", token = p.token })
	has(r.problem, "not signed in", "the commit says the account is not signed in")
	eq(r.ok, nil, "and is no success")
	eq(#seen, 0, "no gh mutation was spawned")
end)

case("host draft: info, preview, plan and commit push the previewed commit unforced, then create the draft pull request and pin it", function(w: World)
	local s = asks.hx.draftScene(w)
	local created = "https://github.com/o/r/pull/21"
	local seen = asks.hx.writes(s.gh, function(line: string): Reply?
		if string.find(line, "pr create", 1, true) then
			return { stdout = created .. "\n" }
		end
		return nil
	end)
	s.gh.pulls[created] = searchItem(21, "o/r", EPOCH - 10, { title = "Fix login flow", isDraft = true })
	local b = openIssues(w)
	local info = asks.hx.ask(w, b, { op = "draft", phase = "info" })
	eq(info.repo, "o/r", "the repository")
	has(info.branch, "12-fix-login", "the worktree's branch")
	eq(info.path, "/wt/plotroom-o_r-issue-12", "and folder")
	eq(#info.destinations, 1, "one remote: one destination, still listed")
	eq(info.destinations[1].repo, "o/r", "the checkout's repository")
	eq(info.destinations[1].remote, "origin", "on origin")
	local bases = asks.hx.ask(w, b, { op = "draft", phase = "bases", repo = "o/r" })
	eq(bases.bases[1], "main", "the remote's branches are the bases")
	eq(bases.defaultBase, "main", "the default one first")
	local pv = asks.hx.ask(w, b, { op = "draft", phase = "preview", repo = "o/r", base = "main" })
	eq(pv.draft, true, "a preview")
	eq(pv.branch, "12-fix-login", "of the branch")
	eq(pv.base, "main", "over the base")
	eq(pv.remote, "origin", "pushed to the repository's remote")
	eq(pv.count, 2, "two commits")
	eq(#pv.commits, 2, "listed")
	eq(pv.needsPush, true, "the remote lacks the branch")
	eq(pv.body, "Closes #12", "the issue is closed by the body")
	eq(#s.git.pushes, 0, "a preview pushes nothing")
	local plan = asks.hx.ask(w, b, { op = "draft", phase = "plan", token = pv.token, title = "Fix login flow", body = pv.body })
	eq(plan.confirm.head, "Create a draft pull request?", "the question")
	eq(plan.confirm.label, "Push and create draft", "the confirming choice says it pushes")
	eq(plan.confirm.lines[1], "Repository: o/r", "the repository")
	eq(plan.confirm.lines[2], "First pushes 12-fix-login to origin (never forced)", "the push is a line of its own")
	has(plan.confirm.lines[3], "12-fix-login → main (2 commits)", "the branch and base")
	eq(plan.confirm.lines[4], "Title: Fix login flow", "the title")
	has(plan.confirm.lines[5], "Opens a draft pull request", "and what is created")
	eq(#s.git.pushes, 0, "a plan pushes nothing")
	eq(#seen, 0, "and creates nothing")
	local mark = #w.calls
	local done = asks.hx.ask(w, b, { op = "commit", token = plan.token })
	eq(done.ok, true, "the commit answers ok")
	eq(done.url, created, "with the new pull request's URL")
	same(s.git.pushes, { "push --no-force-with-lease origin " .. sha("c") .. ":refs/heads/12-fix-login" }, "the previewed commit was pushed, not forced")
	same(seen, { "gh pr create --repo github.com/o/r --draft --base=main --head=12-fix-login --title=Fix login flow --body=Closes #12" }, "one draft pull request, from that branch to that base")
	local pushAt: number?, createAt: number? = nil, nil
	for i, line in ranSince(w, mark) do
		if not pushAt and string.find(line, "push --no-force-with-lease", 1, true) then
			pushAt = i
		end
		if not createAt and string.find(line, "pr create", 1, true) then
			createAt = i
		end
	end
	yes(pushAt ~= nil and createAt ~= nil and pushAt < createAt, "the push came before the pull request was created")
	eq(pickerOf(b).scopes[2].label, "o/r#21", "the new pull request is the pinned scope")
	eq(pickerOf(b).selected, "no_2fr_2321", "and selected")
	eq(pickerOf(b).items[1].label, "Fix login flow", "showing the created pull request")
	same(b.saved().pins, { created }, "the created pull request is the saved pin")
end)

case("host draft: a repository that is not one of the worktree's remotes is refused before any fetch, push or create, and a second GitHub remote is a destination of its own", function(w: World)
	local s = asks.hx.draftScene(w)
	s.git.remotes.upstream = { "https://github.com/u/r.git" }
	local created = "https://github.com/u/r/pull/3"
	local seen = asks.hx.writes(s.gh, function(line: string): Reply?
		if string.find(line, "pr create", 1, true) then
			return { stdout = created .. "\n" }
		end
		return nil
	end)
	s.gh.pulls[created] = searchItem(3, "u/r", EPOCH - 10, { title = "Fix login flow", isDraft = true })
	local b = openIssues(w)
	local info = asks.hx.ask(w, b, { op = "draft", phase = "info" })
	eq(#info.destinations, 2, "both GitHub remotes are destinations")
	eq(info.destinations[1].repo, "o/r", "the checkout's saved repository first")
	eq(info.destinations[1].remote, "origin", "on its remote")
	eq(info.destinations[2].repo, "u/r", "the second remote's repository after it")
	eq(info.destinations[2].remote, "upstream", "on its own remote")
	eq(info.repo, "o/r", "the default is the first")
	local fetches = countLog(s.git, "fetch")
	local repos: { any } = {}
	table.insert(repos, "evil/x")
	table.insert(repos, "O/R/x")
	table.insert(repos, 5)
	for _, bad in repos do
		for _, phase in { "bases", "preview" } do
			local r = asks.hx.ask(w, b, { op = "draft", phase = phase, repo = bad, base = "main" })
			has(r.problem, "not one of this worktree's GitHub remotes", phase .. " refuses " .. show(bad))
		end
	end
	has(asks.hx.ask(w, b, { op = "draft", phase = "preview", base = "main" }).problem, "not one of this worktree's GitHub remotes", "no repository at all")
	eq(countLog(s.git, "fetch"), fetches, "nothing was fetched for any of them")
	eq(#s.git.pushes, 0, "nor pushed")
	eq(#seen, 0, "nor created")
	local bases = asks.hx.ask(w, b, { op = "draft", phase = "bases", repo = "u/r" })
	eq(bases.repo, "u/r", "the bases are the second repository's")
	eq(bases.defaultBase, "main", "with its default first")
	local pv = asks.hx.ask(w, b, { op = "draft", phase = "preview", repo = "u/r", base = "main" })
	eq(pv.repo, "u/r", "the preview is for it")
	eq(pv.remote, "upstream", "pushed to its remote")
	eq(pv.body, "Issue: https://github.com/o/r/issues/12", "the body links an issue of another repository")
	local plan = asks.hx.ask(w, b, { op = "draft", phase = "plan", token = pv.token, title = "Fix login flow", body = pv.body })
	eq(plan.confirm.lines[1], "Repository: u/r", "the plan names it")
	eq(plan.confirm.lines[2], "First pushes 12-fix-login to upstream (never forced)", "and the remote it pushes to")
	eq(#s.git.pushes, 0, "a plan pushes nothing")
	local done = asks.hx.ask(w, b, { op = "commit", token = plan.token })
	eq(done.url, created, "the pull request is created")
	same(s.git.pushes, { "push --no-force-with-lease upstream " .. sha("c") .. ":refs/heads/12-fix-login" }, "the branch went to THAT remote")
	same(seen, { "gh pr create --repo github.com/u/r --draft --base=main --head=12-fix-login --title=Fix login flow --body=Issue: https://github.com/o/r/issues/12" }, "on that repository")
end)

case("host draft: only an issue with a worktree starts a draft, the commit reads the branch again even when no push is needed, and title and body are limited", function(w: World)
	local s, tree = asks.hx.draftScene(w)
	s.gh.items.octocat = manyItems("o/r", 3)
	local seen = asks.hx.writes(s.gh)
	local b = openIssues(w)
	local function draft(body: { [string]: any }): any
		return asks.hx.ask(w, b, body)
	end
	b.typeText("j")
	has(draft({ op = "draft", phase = "info" }).problem, "Make a worktree for o/r#13 first", "an issue without a worktree")
	b.typeText("k")
	pickScope(b, "prs:v1")
	w.flush()
	has(draft({ op = "draft", phase = "info" }).problem, "Select an issue that has a worktree", "a pull request")
	pickScope(b, "issues:v1")
	w.flush()
	eq(pickerOf(b).selected, "no_2fr_2312", "back on the issue with the worktree")
	has(draft({ op = "draft", phase = "preview", repo = "o/r", base = "--evil" }).problem, "not a branch name", "a base that looks like an option")
	has(draft({ op = "draft", phase = "bogus" }).problem, "does not know that step", "an unknown step")
	local pv = draft({ op = "draft", phase = "preview", repo = "o/r", base = "main" })
	local function plan(title: string, body: string): any
		return draft({ op = "draft", phase = "plan", token = pv.token, title = title, body = body })
	end
	has(plan("", "b").problem, "title needs 1 to 256", "an empty title")
	has(plan("   ", "b").problem, "title needs 1 to 256", "a blank one")
	has(plan(string.rep("x", 257), "b").problem, "title needs 1 to 256", "a title of 257 bytes")
	has(plan("a\nb", "b").problem, "title needs 1 to 256", "a title of two lines")
	has(plan("ok", string.rep("y", 8001)).problem, "too long", "a body of 8001 bytes")
	has(plan("caf\255", "b").problem, "title needs 1 to 256", "a title that is not UTF-8 is refused at the plan, as createPr would, not after the push")
	has(plan("ok", "b\255").problem, "body", "a body that is not UTF-8")
	has(plan("ok", "b\1").problem, "body", "a body with a control byte")
	yes(plan(string.rep("é", 256), "b\n\tc").token ~= nil, "256 characters of 512 bytes, and a body's tabs and newlines, pass")
	yes(plan(string.rep("x", 256), string.rep("y", 8000)).token ~= nil, "a title of 256 and a body of 8000 bytes pass")
	has(draft({ op = "draft", phase = "plan", token = "d0_0", title = "t", body = "b" }).problem, "Preview the draft again", "a plan for a preview this block never made")
	eq(#s.git.pushes, 0, "nothing was pushed")
	eq(#seen, 0, "nor created")
	s.git.refs["refs/remotes/origin/12-fix-login"] = sha("c")
	local synced = draft({ op = "draft", phase = "preview", repo = "o/r", base = "main" })
	eq(synced.needsPush, false, "the remote already has the commit")
	local plan2 = draft({ op = "draft", phase = "plan", token = synced.token, title = "T", body = "B" })
	eq(plan2.confirm.label, "Create draft", "no push is offered")
	lacks(table.concat(plan2.confirm.lines, "\n"), "First pushes", "or listed")
	s.git.counts[sha("d")] = 3
	tree.head = sha("d")
	has(asks.hx.ask(w, b, { op = "commit", token = plan2.token }).problem, "moved since the preview", "a HEAD that moved is caught though no push was planned")
	eq(#s.git.pushes, 0, "nothing was pushed")
	eq(#seen, 0, "and no pull request was created")
end)

case("host draft: the commit is refused when the remote's copy of the branch changed since the confirmed preview, or the view changed after the plan, with no push and no create", function(w: World)
	local s = asks.hx.draftScene(w)
	local seen = asks.hx.writes(s.gh)
	local b = openIssues(w)
	local function planned(): any
		local pv = asks.hx.ask(w, b, { op = "draft", phase = "preview", repo = "o/r", base = "main" })
		eq(pv.needsPush, true, "the preview needs a push")
		return asks.hx.ask(w, b, { op = "draft", phase = "plan", token = pv.token, title = "T", body = "B" })
	end
	local p = planned()
	s.git.refs["refs/remotes/origin/12-fix-login"] = sha("c")
	has(asks.hx.ask(w, b, { op = "commit", token = p.token }).problem, "moved since the preview", "someone pushed the branch meanwhile: needsPush changed")
	eq(#s.git.pushes, 0, "nothing was pushed")
	eq(#seen, 0, "nothing was created")
	s.git.refs["refs/remotes/origin/12-fix-login"] = nil
	local q = planned()
	pickScope(b, "issues:v2")
	w.flush()
	has(asks.hx.ask(w, b, { op = "commit", token = q.token }).problem, "selection or the view changed", "the view changed after the plan")
	eq(#s.git.pushes, 0, "still nothing was pushed")
	eq(#seen, 0, "and nothing created")
end)

case("host draft: a draft previewed again while the commit pushes does not stop the commit", function(w: World)
	local s = asks.hx.draftScene(w)
	local created = "https://github.com/o/r/pull/21"
	asks.hx.writes(s.gh, function(line: string): Reply?
		if string.find(line, "pr create", 1, true) then
			return { stdout = created .. "\n" }
		end
		return nil
	end)
	s.gh.pulls[created] = searchItem(21, "o/r", EPOCH - 10, { title = "Fix login flow", isDraft = true })
	local b = openIssues(w)
	local pv = asks.hx.ask(w, b, { op = "draft", phase = "preview", repo = "o/r", base = "main" })
	local plan = asks.hx.ask(w, b, { op = "draft", phase = "plan", token = pv.token, title = "T", body = "B" })
	request(b, "late", { op = "commit", token = plan.token })
	local again = asks.hx.ask(w, b, { op = "draft", phase = "preview", repo = "o/r", base = "main" })
	w.flush()
	eq(answerOf(b, "late").ok, true, "the commit went through")
	yes(again.token ~= pv.token, "the second preview is a draft of its own")
	eq(pickerOf(b).scopes[2].label, "o/r#21", "and the new pull request is pinned")
end)

case("host mutations: with no known GitHub account every GitHub plan refuses and spawns nothing", function(w: World)
	local s = asks.hx.draftScene(w)
	s.gh.items.octocat = manyItems("o/r", 2)
	local seen: { string } = {}
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "accounts" then
			return { status = 1, stderr = "gh: unavailable\n" }
		elseif req.kind == "other" then
			table.insert(seen, table.concat(req.call.argv, " "))
			return { stdout = "" }
		end
		return nil
	end
	local b = openIssues(w)
	local unknown = "Could not tell which GitHub account is active"
	has(asks.hx.ask(w, b, { op = "act", name = "assign-me" }).problem, unknown, "assign-me")
	local pv = asks.hx.ask(w, b, { op = "draft", phase = "preview", repo = "o/r", base = "main" })
	has(asks.hx.ask(w, b, { op = "draft", phase = "plan", token = pv.token, title = "T", body = "B" }).problem, unknown, "a draft plan")
	pickScope(b, "prs:v1")
	w.flush()
	has(asks.hx.ask(w, b, { op = "act", name = "rerun-failed" }).problem, "has a GitHub Actions run to rerun", "a pull request with no failed run is refused first")
	eq(#seen, 0, "no gh mutation was spawned")
	eq(#s.git.pushes, 0, "nothing was pushed")
end)

case("host: returning from the Worktrees list to the view already shown, by palette or sidebar, keeps its selection", function(w: World)
	asks.hx.boardScene(w)
	local b = openQueue(w)
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_232" })
	b.event({ ev = "action", act = "queue", value = "scope:worktrees" })
	w.flush()
	eq(pickerOf(b).scope, "worktrees", "the list is shown")
	b.event({ ev = "action", act = "queue", value = "scope:prs:v1" })
	w.flush()
	eq(pickerOf(b).scope, "prs:v1", "back on the view")
	eq(pickerOf(b).selected, "no_2fr_232", "by the palette: the same row is selected")
	pickScope(b, "worktrees")
	w.flush()
	pickScope(b, "prs:v1")
	w.flush()
	eq(pickerOf(b).selected, "no_2fr_232", "by the sidebar: the same row")
end)

case("host agents: the Agents scope lists agents that are not exited by repository with item, action, branch and state, counts them in the sidebar, and Enter goes to the selected one, a Jira issue's too", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	local scopes = pickerOf(b).scopes
	eq(scopes[#scopes].id, "agents", "the sidebar's last scope is the Agents scope")
	eq(scopes[#scopes].label, "Agents", "named so")
	eq(scopes[#scopes].count, 0, "with no agent to count")
	asks.hx.agents(b, {
		["o/r#1"] = { state = "working", action = "Review", branch = "fix-1", title = "Fix one" },
		["o/r#2"] = "waiting_input", -- a link saved before the texts were recorded
		["o/r#3"] = "exited",
		["x/y#4"] = { state = "idle", action = "Watch", title = "Other" },
	})
	scopes = pickerOf(b).scopes
	eq(scopes[#scopes].count, 3, "the exited agent is not counted")
	pickScope(b, "agents")
	w.flush()
	eq(pickerOf(b).scope, "agents", "opening it makes it the active scope")
	eq(pickerOf(b).noun, "agents", "the list holds agents")
	local rows: { string } = {}
	for _, item in pickerOf(b).items do
		table.insert(rows, item.label .. " | " .. detailText(item) .. " | " .. item.badges[1].text)
	end
	same(rows, { "Fix one | Review · fix-1 | Working", "o/r#2 | o/r#2 | Needs input", "Other | Watch | Idle" }, "title, action and branch and the state badge; an old link shows its key and state; an exited agent is hidden")
	eq(pickerOf(b).order[1].label, "o/r", "grouped by repository")
	eq(pickerOf(b).order[1].count, 2, "counting its agents")
	eq(pickerOf(b).order[4].label, "x/y", "the next repository after them")
	eq(pickerOf(b).selected, "go_2fr_231", "the first agent is selected on arrival")
	eq(findKey(pickerNode(b), "agentgo").p.href, h.tokened("plotroom://github/agentgo/o/r/1"), "its hidden link is the agent's")
	b.press("down")
	eq(pickerOf(b).selected, "go_2fr_232", "Down moves to the next")
	eq(b.press("enter"), true, "Enter goes to its agent")
	eq(w.opened[#w.opened], h.tokened("plotroom://github/agentgo/o/r/2"), "through its link")
	b.press("end")
	eq(pickerOf(b).selected, "gx_2fy_234", "End jumps to the last agent")
	b.press("home")
	eq(pickerOf(b).selected, "go_2fr_231", "Home jumps to the first agent")
	asks.hx.agents(b, { ["abc#ABC-12"] = "working" })
	eq(pickerOf(b).selected, "gabc_23ABC-12", "an agent that went away hands the selection on")
	eq(findKey(pickerNode(b), "agentgo").p.href, h.tokened("plotroom://issue/agentgo/ABC/ABC-12"), "a Jira issue's link names its project in upper case")
	b.press("enter")
	eq(w.opened[#w.opened], h.tokened("plotroom://issue/agentgo/ABC/ABC-12"), "and Enter follows it")
	asks.hx.agents(b, { ["abc#ABC-12"] = "exited" })
	eq(#pickerOf(b).items, 0, "no agent left: no row")
	eq(pickerOf(b).selected, nil, "and none selected")
	pickScope(b, "prs:v1")
	eq(pickerOf(b).scope, "prs:v1", "a click on the view leaves the Agents scope")
end)

case("host agents: an Agents row and its preview show the end-of-run report's attention, reason and blocker, or No report", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	asks.hx.agents(b, {
		["o/r#1"] = { state = "idle", action = "Review", title = "Fix one", result = "done", attention = "stuck", reason = "The migration fails", blocker = "No test database" },
		["o/r#2"] = { state = "idle", action = "Watch", title = "Fix two", result = "done", attention = "none" },
		["o/r#3"] = { state = "working", action = "Fix", title = "Fix three" },
	})
	pickScope(b, "agents")
	w.flush()
	local rows: { string } = {}
	for _, item in pickerOf(b).items do
		table.insert(rows, detailText(item) .. " | " .. (if item.badges[2] then item.badges[2].text else "-"))
	end
	same(rows, {
		"Review: done · No test database · The migration fails | Report: stuck",
		"Watch: done | No report",
		"Fix | -",
	}, "the report's badge, blocker and reason on the row; No report when there was none; nothing before a turn ended")
	local text = b.text()
	has(text, "Report: stuck", "the preview names the attention")
	has(text, "The migration fails", "the reason")
	has(text, "No test database", "and the blocker")
	b.press("down")
	has(b.text(), "No report", "an agent with no report says so")
	lacks(b.text(), "Blocker", "with no blocker row")
end)

case("host agents: Interrupt, Stop and Message agent are palette rows and hidden links only while the selected item or Agents row has a live agent, and open the window's link", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	local function has3(p: any): boolean
		return table.find(p.ids, "agentint") ~= nil and table.find(p.ids, "agentstop") ~= nil and table.find(p.ids, "agentmsg") ~= nil
	end
	yes(not has3(hx.palette(w, b)), "no agent: no rows")
	asks.hx.agents(b, { ["o/r#1"] = "exited" })
	yes(table.find(hx.palette(w, b).ids, "agentint") == nil, "an exited agent: no rows")
	eq(findKey(pickerNode(b), "agentint"), nil, "nor hidden link")
	asks.hx.agents(b, { ["o/r#1"] = "working", ["o/r#2"] = "idle" })
	local p = hx.palette(w, b)
	yes(has3(p), "a live agent: the three rows")
	eq(p.labels.agentint, "Interrupt agent", "named so")
	eq(p.labels.agentstop, "Stop agent…", "Stop asks first")
	eq(p.labels.agentmsg, "Message agent…", "and Message asks for a line")
	eq(p.groups.agentstop, "Actions", "in the Actions group")
	eq(findKey(pickerNode(b), "agentstop").p.href, prLink("agentstop", "o/r", 1), "the hidden link the window checks")
	b.event({ ev = "action", act = "queue", value = "agentmsg" })
	eq(w.opened[#w.opened], prLink("agentmsg", "o/r", 1), "the palette pick opens the selected item's link")
	b.typeText("j")
	b.typeText("j")
	local opened = #w.opened
	b.event({ ev = "action", act = "queue", value = "agentint" })
	eq(#w.opened, opened, "a row with no agent opens nothing")
	pickScope(b, "agents")
	w.flush()
	yes(has3(hx.palette(w, b)), "the Agents scope offers them for the selected agent")
	eq(findKey(pickerNode(b), "agentint").p.href, prLink("agentint", "o/r", 1), "its hidden link names that agent")
	b.event({ ev = "action", act = "queue", value = "agentint" })
	eq(w.opened[#w.opened], prLink("agentint", "o/r", 1), "and the pick opens it")
	asks.hx.agents(b, {})
	yes(not has3(hx.palette(w, b)), "no agent listed: no rows")
end)

case("host agents: Now's row and preview show what an agent that needs input last said, with Reply… and Go to agent, and the row leaves once the agent stops waiting", function(w: World)
	local s = hostScene(w, 3)
	h.newAcli(w)
	s.gh.tokens.octocat = "tok-octocat"
	s.gh.queries["author:@me archived:false"], s.gh.queries["user-review-requested:@me"], s.gh.queries["assignee:@me archived:false"] = {}, {}, {}
	s.gh.inbox.octocat = {}
	w.setOpensNow(true)
	local b = w.open(1, { "/work/r" })
	w.flush()
	asks.hx.agents(b, { ["o/r#5"] = { state = "waiting_input", action = "Review", title = "Fix five", last = "Rebase onto main first?" } })
	local row = pickerOf(b).items[1]
	eq(row.badges[1].text, "Agent needs input", "the agent is Now's row")
	local detail: { string } = {}
	collectTexts(row.detail, detail)
	has(table.concat(detail), "Rebase onto main first?", "which shows its last message")
	has(b.text(), "Rebase onto main first?", "and so does the preview")
	local labels = hx.palette(w, b).labels
	eq(labels.agentreply, "Reply…", "Commands offers Reply…")
	eq(labels.agentgo, "Go to agent", "and Go to agent")
	eq(findKey(pickerNode(b), "agentreply").p.href, prLink("agentreply", "o/r", 5), "Reply's hidden link the window checks")
	eq(findKey(pickerNode(b), "agentgo").p.href, prLink("agentgo", "o/r", 5), "and Go to agent's")
	b.event({ ev = "action", id = "layer.queue", act = "agentreply" })
	eq(w.opened[#w.opened], prLink("agentreply", "o/r", 5), "Reply… opens the window's reply link")
	b.event({ ev = "action", id = "layer.queue", act = "agentgo" })
	eq(w.opened[#w.opened], prLink("agentgo", "o/r", 5), "Go to agent opens the agent's link")
	local p = hx.palette(w, b)
	eq(p.labels.agentreply, "Reply…", "Commands offers Reply…")
	eq(p.groups.agentgo, "Now", "and Go to agent, under Now")
	asks.hx.agents(b, { ["o/r#5"] = { state = "working", action = "Review", title = "Fix five" } })
	eq(#pickerOf(b).items, 0, "once the agent stops waiting its row leaves Now")
	eq(findKey(pickerNode(b), "agentreply"), nil, "with its Reply link")
	yes(table.find(hx.palette(w, b).ids, "agentreply") == nil, "and Commands' Reply…")
	local opened = #w.opened
	b.event({ ev = "action", id = "layer.queue", act = "agentreply" })
	eq(#w.opened, opened, "a Reply… click with no such row opens nothing")
end)

case("host agents: the palette on the Agents list offers Go to agent, the views, Settings and help, and no queue row", function(w: World)
	hostScene(w, 3)
	w.kv.store.keys = nil :: any
	local b = openQueue(w)
	asks.hx.agents(b, { ["o/r#1"] = { state = "working", action = "Review", title = "Fix one" } })
	pickScope(b, "agents")
	w.flush()
	local p = hx.palette(w, b)
	local expected: { string } = { "agentgo", "agentint", "agentstop", "agentmsg", "nownext" }
	for _, scope in pickerOf(b).scopes do
		table.insert(expected, "scope:" .. scope.id)
	end
	table.insert(expected, "settings")
	table.insert(expected, "help")
	same(p.ids, expected, "Go to agent and the agent commands, Next in Now, then every scope, Settings and help")
	eq(p.groups.agentgo, "Agents", "Go to agent is the Agents group")
	eq(p.groups.agentstop, "Agents", "so are the agent commands")
	for _, id in { "snooze", "snoozed", "sort", "search", "refresh", "seen" } do
		eq(table.find(p.ids, id), nil, id .. " is not offered")
	end
	local opened = #w.opened
	b.event({ ev = "action", act = "queue", value = "snooze" })
	eq(#w.opened, opened, "a queue row sent anyway does nothing")
	b.event({ ev = "action", act = "queue", value = "agentgo" })
	eq(w.opened[#w.opened], h.tokened("plotroom://github/agentgo/o/r/1"), "Go to agent follows the selected row's link")
	asks.hx.agents(b, { ["o/r#1"] = "exited" })
	eq(table.find(hx.palette(w, b).ids, "agentgo"), nil, "with no agent row there is nothing to go to")
end)

case("host agents: agent-status drops texts that are not clean strings within their caps", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	asks.hx.agents(b, { ["o/r#1"] = { state = "working", action = 5, branch = string.rep("b", 201), title = "bad\ntitle" } })
	pickScope(b, "agents")
	w.flush()
	eq(pickerOf(b).items[1].label, "o/r#1", "a malformed title is not shown")
	eq(detailText(pickerOf(b).items[1]), "o/r#1", "nor a malformed action or an oversize branch")
	asks.hx.agents(b, { ["o/r#1"] = "working" })
	same(b.state().agentInfo["o/r#1"], {}, "the old shape of a status row is a row with no texts")
end)
case("host worktrees board: the Worktrees scope lists every linked worktree of every saved checkout, never the checkout itself, not only the shown view's repository, with badges, an open link and a way back", function(w: World)
	local s = asks.hx.boardScene(w)
	local b = openQueue(w)
	local scopes = pickerOf(b).scopes
	eq(scopes[#scopes - 1].id, "worktrees", "the sidebar's last but one scope is the Worktrees scope")
	eq(scopes[#scopes - 1].label, "Worktrees", "named so")
	eq(scopes[#scopes - 1].count, nil, "with no count until it was read")
	eq(pickerOf(b).scope, "prs:v1", "the view is the active scope")
	pickScope(b, "worktrees")
	w.flush()
	eq(pickerOf(b).scope, "worktrees", "opening it makes it the active scope")
	eq(pickerOf(b).noun, "worktrees", "the board lists worktrees")
	same(asks.hx.board(b), { "o/r/feature", "o/r/lk", "x/y/yb" }, "every checkout's linked worktrees, sorted by repository then branch, the other repository's too, never a main checkout")
	local groups: { string } = {}
	local headingOf: { [string]: string } = {}
	local heading = ""
	for _, entry in pickerOf(b).order do
		if type(entry) == "table" then
			heading = entry.group
			table.insert(groups, heading)
		else
			headingOf[entry] = heading
		end
	end
	local under: { [string]: string } = {}
	for _, name in asks.hx.board(b) do
		under[name] = headingOf[asks.hx.rowId(b, name)]
	end
	same(groups, { "o/r", "x/y" }, "one group per repository")
	same(under, { ["o/r/feature"] = "o/r", ["o/r/lk"] = "o/r", ["x/y/yb"] = "x/y" }, "each row under its repository's group")
	scopes = pickerOf(b).scopes
	eq(scopes[#scopes - 1].count, 3, "the scope counts them")
	for _, name in asks.hx.board(b) do
		lacks(asks.hx.badges(b, name), "Main", "no row is badged Main: " .. name)
	end
	has(asks.hx.badges(b, "o/r/lk"), "Locked", "a locked worktree is marked")
	has(asks.hx.badges(b, "o/r/lk"), "Unnoted", "and one no item was noted for")
	lacks(asks.hx.badges(b, "o/r/feature"), "Unnoted", "a pull request's is linked")
	lacks(asks.hx.badges(b, "o/r/feature"), "In tab", "no tab works in it yet")
	eq(detailText(asks.hx.rowItem(b, "o/r/feature")), "/wt/pr5 · #5", "a row shows its folder and its pull request")
	table.insert(w.panes, { pane = 9, cwd = "/wt/pr5/src" })
	b.render()
	has(asks.hx.badges(b, "o/r/feature"), "In tab", "a tab working in it marks the row")
	lacks(asks.hx.badges(b, "x/y/yb"), "In tab", "and no other")
	eq(pickerOf(b).selected, asks.hx.rowId(b, "o/r/feature"), "the first row is selected on arrival")
	eq(findKey(pickerNode(b), "wtopen").p.href, h.tokened("plotroom://worktrees/open/1"), "its hidden link carries the row's number")
	eq(b.press("enter"), true, "Enter opens it")
	eq(w.opened[#w.opened], h.tokened("plotroom://worktrees/open/1"), "through that link")
	b.press("end")
	eq(pickerOf(b).selected, asks.hx.rowId(b, "x/y/yb"), "End jumps to the last worktree")
	b.press("home")
	eq(pickerOf(b).selected, asks.hx.rowId(b, "o/r/feature"), "Home jumps back to the first")
	eq(asks.hx.ask(w, b, { op = "worktree-path", n = 1 }).path, "/wt/pr5", "the window asks the host for the folder by number")
	eq(asks.hx.ask(w, b, { op = "worktree-path", n = 3 }).path, "/wt/yb", "another repository's too")
	eq(findKey(pickerNode(b), "git").p.href, h.tokened("plotroom://worktrees/git"), "the row has its Open in Git link")
	eq(asks.hx.ask(w, b, { op = "git-path" }).path, "/wt/pr5", "which the host answers with the selected row's folder")
	b.event({ ev = "action", id = "layer.queue", act = "queue", value = "wt-git" })
	eq(w.opened[#w.opened], h.tokened("plotroom://worktrees/git"), "the palette's Open in Git opens it")
	has(asks.hx.ask(w, b, { op = "worktree-path", n = 9 }).problem, "no longer listed", "a number no row has")
	eq(asks.hx.ask(w, b, { op = "worktree-path", n = "1" }), nil, "a number that is no number is not answered")
	eq(countLog(s.git, "worktree remove"), 0, "nothing was removed")
	eq(b.press("escape"), false, "Escape closes no preview: it is left to the pane")
	eq(pickerOf(b).selected, asks.hx.rowId(b, "o/r/feature"), "the row stays selected")
	eq(pickerOf(b).scope, "worktrees", "and the list is still shown")
	pickScope(b, "prs:v1")
	eq(pickerOf(b).scope, "prs:v1", "a click on the view leaves it")
	eq(pickerOf(b).noun, "pull requests", "which lists pull requests again")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "its rows")
	pickScope(b, "worktrees")
	pickScope(b, "prs:v1")
	eq(pickerOf(b).scope, "prs:v1", "a click on the view leaves the board too")
	same(listed(b), { "no_2fr_231", "no_2fr_232", "no_2fr_233" }, "with its rows")
end)

case("host worktrees board: the changes of every worktree are read on their own and again every 30 seconds while the board is shown, never after it is left; u marks closed and merged items as cleanup candidates without removing anything", function(w: World)
	local s, y = asks.hx.boardScene(w)
	asks.bk.tree(w, s.git, "/wt/iss", "12-fix")
	s.git.notes["branch.12-fix.plotroomkey"] = "o/r#12"
	s.git.notes["branch.12-fix.plotroomrepo"] = "o/r"
	s.git.dirty["/wt/pr5"] = " M a.txt\n"
	s.gh.pulls["https://github.com/o/r/pull/5"] = searchItem(5, "o/r", EPOCH - 60, { state = "MERGED" })
	s.gh.pulls["https://github.com/o/r/issues/12"] = issueItem(12, "o/r", EPOCH - 60, { state = "CLOSED", reason = "COMPLETED" })
	w.kv.put("keys", { ["wt-cleanup"] = "u" })
	local b = openQueue(w)
	pickScope(b, "worktrees")
	w.flush()
	same(asks.hx.board(b), { "o/r/12-fix", "o/r/feature", "o/r/lk", "x/y/yb" }, "the rows")
	has(asks.hx.badges(b, "o/r/feature"), "Changes", "a worktree with uncommitted changes says so with no key pressed")
	for _, name in { "o/r/12-fix", "o/r/lk", "x/y/yb" } do
		lacks(asks.hx.badges(b, name), "Changes", name .. ": has none")
	end
	s.git.dirty["/wt/pr5"] = nil
	local reads = countLog(s.git, "status")
	w.advance(29000)
	eq(countLog(s.git, "status"), reads, "the changes are not read again before 30 seconds")
	w.advance(1000)
	yes(countLog(s.git, "status") > reads, "they are read again 30 seconds after the last scan")
	has(asks.hx.badges(b, "o/r/feature"), "Clean", "and the badge follows")
	lacks(asks.hx.badges(b, "o/r/feature"), "Changes", "the old one is gone")
	b.typeText("u")
	w.flush()
	has(w.toasts[#w.toasts].text, "Checked 2 worktrees", "u counts the two worktrees gh could answer for")
	has(asks.hx.badges(b, "o/r/feature"), "Merged", "a merged pull request is a candidate")
	has(asks.hx.badges(b, "o/r/12-fix"), "Closed", "a closed issue too")
	lacks(asks.hx.badges(b, "x/y/yb"), "Merged", "a pull request gh cannot see is none")
	lacks(asks.hx.badges(b, "x/y/yb"), "Closed", "neither closed")
	lacks(asks.hx.badges(b, "o/r/lk"), "Closed", "a worktree with no item is not asked about")
	eq(countLog(s.git, "worktree remove"), 0, "nothing was removed in o/r")
	eq(countLog(y, "worktree remove"), 0, "nor in x/y")
	eq(#s.git.worktrees, 4, "every worktree is still there")
	same(asks.hx.board(b), { "o/r/12-fix", "o/r/feature", "o/r/lk", "x/y/yb" }, "and listed")
	pickScope(b, "prs:v1")
	eq(pickerOf(b).scope, "prs:v1", "a click on the view leaves the list")
	eq(b.state().boardTimer, nil, "stops its scan timer")
	local left = countLog(s.git, "status")
	w.advance(120 * 1000)
	eq(countLog(s.git, "status"), left, "and nothing reads the worktrees any more")
end)

case("host worktrees board: Remove finished worktrees asks once for only the rows u marked, Esc keeps all, d removes clean ones one at a time and keeps a dirty one", function(w: World)
	local s = asks.hx.boardScene(w)
	asks.bk.tree(w, s.git, "/wt/iss", "12-fix")
	s.git.notes["branch.12-fix.plotroomkey"] = "o/r#12"
	s.git.notes["branch.12-fix.plotroomrepo"] = "o/r"
	s.gh.pulls["https://github.com/o/r/pull/5"] = searchItem(5, "o/r", EPOCH - 60, { state = "MERGED" })
	s.gh.pulls["https://github.com/o/r/issues/12"] = issueItem(12, "o/r", EPOCH - 60, { state = "CLOSED", reason = "COMPLETED" })
	w.kv.put("keys", { ["wt-cleanup"] = "u" })
	local b = openQueue(w)
	pickScope(b, "worktrees")
	w.flush()
	local function remove()
		b.event({ ev = "action", act = "queue", value = "wt-remove-finished" })
	end
	remove()
	eq(confirmOf(b), nil, "nothing is marked before Find finished worktrees")
	eq(w.toasts[#w.toasts].text, "No finished worktrees", "and it says so")
	b.typeText("u")
	w.flush()
	s.git.dirty["/wt/pr5"] = " M a.txt\n"
	remove()
	local overlay = confirmOf(b)
	yes(overlay ~= nil, "it asks")
	local texts: { string } = {}
	collectTexts(overlay, texts)
	local text = table.concat(texts, " ")
	has(text, "/wt/pr5", "the merged row is listed")
	has(text, "/wt/iss", "and the closed one")
	lacks(text, "/wt/lk", "an unmarked row is not")
	has(text, "Remove 2 finished worktrees", "with their count")
	b.press("escape")
	eq(confirmOf(b), nil, "Esc closes it")
	eq(countLog(s.git, "worktree remove"), 0, "and keeps all")
	remove()
	b.press("enter")
	eq(countLog(s.git, "worktree remove"), 0, "Enter keeps all")
	remove()
	b.typeText("d")
	w.flush()
	eq(countLog(s.git, "worktree remove /wt/iss"), 1, "the clean one went through git")
	eq(countLog(s.git, "worktree remove /wt/pr5"), 1, "git was asked about the dirty one once, and refused")
	for _, line in s.git.log do
		lacks(line, "--force", "never forced")
	end
	eq(w.toasts[#w.toasts].text, "Removed 1, kept 1", "the toast counts both")
	yes(table.find(asks.hx.board(b), "o/r/feature") ~= nil, "the dirty one is still listed")
	eq(table.find(asks.hx.board(b), "o/r/12-fix"), nil, "the clean one left")
end)

case("host worktrees board: the preview of a row names its branch, the pull request or issue it was made for as the tracker answered, its branch, repository, path and head, and stays open on Escape", function(w: World)
	local s = asks.hx.boardScene(w)
	s.gh.pulls["https://github.com/o/r/pull/5"] = searchItem(5, "o/r", EPOCH - 60, { title = "Fix the board" })
	local b = openQueue(w)
	pickScope(b, "worktrees")
	w.flush()
	local seenBefore = w.kv.store["triage"]
	eq(pickerOf(b).selected, asks.hx.rowId(b, "o/r/feature"), "the first row is selected on arrival")
	eq(pickerOf(b).preview, "side", "and its preview is open")
	w.advance(300)
	w.flush()
	eq(pickerOf(b).selected, asks.hx.rowId(b, "o/r/feature"), "a row event selects it")
	eq(findKey(findKey(pickerNode(b), "titlerow"), "title").p.spans[1].t, "feature", "the preview's title is its branch")
	local row: any = nil
	for _, item in pickerOf(b).items do
		if item.id == asks.hx.rowId(b, "o/r/feature") then
			row = item
		end
	end
	eq(row.title, "feature", "the row's title is its branch")
	eq(row.detail[1].t, "/wt/pr5", "the line under it is the worktree's full path")
	eq(row.detail[3].t, "#5", "then the pull request's number")
	has(b.text(), "Linked pull requests", "the pull request it was made for is under the linked pull requests")
	has(b.text(), "#5", "named by its number")
	has(b.text(), "Fix the board", "with the title the tracker answered")
	local facts: { [string]: string } = {}
	for _, fact in findKey(pickerNode(b), "facts", "kv").p.items do
		facts[fact.k] = fact.v[1].t
	end
	eq(facts.Branch, "feature", "the branch")
	eq(facts.Repository, "o/r", "the repository")
	eq(facts.Path, "/wt/pr5", "the path")
	yes(facts.Head ~= nil and #facts.Head <= 8, "a short head")
	eq(facts.Status, nil, "the changes are not a fact")
	local state: any = findKey(findKey(pickerNode(b), "head"), "state", "badge")
	yes(state ~= nil and state.p.title ~= nil, "they are the head's badge, the status in its tooltip")
	eq(findKey(pickerNode(b), "close-preview"), nil, "no Close preview row is offered")
	eq(b.press("escape"), false, "Escape closes nothing")
	eq(pickerOf(b).selected, asks.hx.rowId(b, "o/r/feature"), "the preview stays open")
	eq(pickerOf(b).scope, "worktrees", "on the list")
	b.event({ ev = "select", id = "layer.queue", item = asks.hx.rowId(b, "o/r/lk") })
	eq(pickerOf(b).selected, asks.hx.rowId(b, "o/r/lk"), "another row can be picked")
	b.event({ ev = "select", id = "layer.queue", item = asks.hx.rowId(b, "o/r/feature") })
	b.event({ ev = "action", id = "layer.queue", act = "refresh" })
	w.flush()
	eq(pickerOf(b).scope, "worktrees", "a refresh keeps the board")
	w.advance(300)
	w.flush()
	has(b.text(), "Fix the board", "the preview read the tracker again")
	s.gh.pulls["https://github.com/o/r/pull/5"] = searchItem(5, "o/r", EPOCH - 60, { title = "Merged since" })
	w.flush()
	has(b.text(), "Fix the board", "nothing changes until Refresh")
	b.event({ ev = "action", id = "layer.queue", act = "refresh" })
	w.advance(300)
	w.flush()
	has(b.text(), "Merged since", "Refresh reads the previewed pull request again, not only git")
	eq(w.kv.store["triage"], seenBefore, "reading worktrees marks no pull request seen")
end)

case("host worktrees board: u asks about at most twenty worktrees a press, rows not yet asked first, and removes none", function(w: World)
	local s = hostScene(w, 3)
	for i = 1, 25 do
		asks.bk.tree(w, s.git, "/wt/n" .. i, "n" .. i)
		s.git.notes["branch.n" .. i .. ".plotroompr"] = tostring(100 + i)
		s.gh.pulls["https://github.com/o/r/pull/" .. (100 + i)] = searchItem(100 + i, "o/r", EPOCH - 60)
		s.git.notes["branch.n" .. i .. ".plotroomrepo"] = "o/r"
	end
	w.kv.put("keys", { ["wt-cleanup"] = "u" })
	local b = openQueue(w)
	pickScope(b, "worktrees")
	w.flush()
	eq(#asks.hx.board(b), 25, "the 25 linked worktrees")
	local before = #requestsOf(s.gh, "pull")
	b.typeText("u")
	w.flush()
	eq(#requestsOf(s.gh, "pull") - before, 20, "twenty were asked")
	has(w.toasts[#w.toasts].text, "Checked 20 worktrees", "the toast says so")
	eq(w.toasts[#w.toasts].sub, "5 more not checked: run Find finished worktrees again", "and that five were left")
	local asked = 0
	for _, row in b.state().board.rows do
		if row.candidateChecked then
			asked += 1
		end
	end
	eq(asked, 20, "twenty rows were checked")
	b.typeText("u")
	w.flush()
	for _, row in b.state().board.rows do
		yes(row.candidateChecked, "every row was checked after the second press: " .. row.path)
	end
	eq(countLog(s.git, "worktree remove"), 0, "nothing was removed")
	eq(#asks.hx.board(b), 25, "every row is still listed")
end)

case("host worktrees board: a preview read that lands while a cleanup runs leaves the board busy until the cleanup ends", function(w: World)
	local s = asks.hx.boardScene(w)
	s.gh.pulls["https://github.com/o/r/pull/5"] = searchItem(5, "o/r", EPOCH - 60, { title = "Fix the board" })
	local b = openQueue(w)
	pickScope(b, "worktrees")
	w.flush()
	w.advance(300)
	w.flush()
	eq(pickerOf(b).selected, asks.hx.rowId(b, "o/r/feature"), "pull request 5's worktree is previewed")
	has(b.text(), "Fix the board", "and its pull request was read")
	s.gh.override = function(req: GhReq): Reply?
		if req.kind == "checks" and req.fields.o == "o" and req.fields.r == "r" and req.fields.n == "5" then
			return { stdout = '{"next":null,"nodes":[],"total":0}', delay = 1000 }
		elseif req.kind == "pull" and req.fields.q == "https://github.com/x/y/pull/7" then
			return { stdout = '{"cost":1,"items":[],"next":null,"total":0}', delay = 5000 }
		end
		return nil
	end
	b.typeText("r")
	w.flush()
	yes(not b.state().boardBusy, "the reload is over")
	has(b.text(), "Loading #5…", "and the preview reads pull request 5 again")
	b.typeText("u")
	w.flush()
	yes(b.state().boardBusy, "the cleanup holds the board")
	has(b.text(), "Reading checkouts…", "which the header says")
	w.advance(1000)
	local function cleanups(): number
		local n = 0
		for _, t in w.toasts do
			if string.find(t.text, "^Checked ") then
				n += 1
			end
		end
		return n
	end
	has(b.text(), "Fix the board", "the preview's read has landed")
	eq(cleanups(), 0, "while the cleanup still waits on gh")
	yes(b.state().boardBusy, "the board stays busy while the cleanup runs")
	b.typeText("d")
	eq(asks.toasted(w, "Still reading"), 1, "Remove waits for the cleanup")
	eq(b.state().boardRemoving, nil, "and asks nothing meanwhile")
	w.advance(4000)
	eq(cleanups(), 1, "the cleanup ends with its toast")
	yes(not b.state().boardBusy, "and only then is the board free")
end)

case("host worktrees board: no action bar; Commands offers Find and Remove finished worktrees, and a bound key works", function(w: World)
	asks.hx.boardScene(w)
	w.kv.store.keys = nil :: any
	local b = openQueue(w)
	pickScope(b, "worktrees")
	w.flush()
	eq(pickerOf(b).actions, nil, "no action bar")
	local p = hx.palette(w, b)
	yes(table.find(p.ids, "wt-cleanup") ~= nil and table.find(p.ids, "wt-remove-finished") ~= nil, "Commands offers both")
	eq(p.keys["wt-cleanup"], "", "Find finished worktrees has no key by default")
	eq(b.press("u", nil, "u"), false, "u is no shortcut by default")
	w.kv.put("keys", { ["wt-cleanup"] = "u" })
	b.render()
	eq(hx.palette(w, b).keys["wt-cleanup"], "u", "bound, Commands shows its key")
	eq(b.press("u", nil, "u"), true, "and u runs it")
end)

case("host worktrees board: d asks first, Enter or Esc keeps the worktree, d again removes it without force, and dirty and locked rows are refused", function(w: World)
	local s = asks.hx.boardScene(w)
	w.kv.put("keys", { ["wt-remove"] = "d" })
	local b = openQueue(w)
	pickScope(b, "worktrees")
	w.flush()
	eq(pickerOf(b).selected, asks.hx.rowId(b, "o/r/feature"), "the first row is selected on arrival")
	eq(table.find(hx.palette(w, b).ids, "wt-remove") ~= nil, true, "so Commands offers Remove for its linked worktree")
	b.typeText("d")
	local overlay = confirmOf(b)
	yes(overlay ~= nil, "d asks first")
	local texts: { string } = {}
	collectTexts(overlay, texts)
	has(table.concat(texts, " "), "/wt/pr5", "naming its folder")
	eq(countLog(s.git, "worktree remove"), 0, "nothing was removed yet")
	b.press("enter")
	eq(confirmOf(b), nil, "Enter keeps it")
	b.typeText("d")
	b.press("escape")
	eq(confirmOf(b), nil, "Esc keeps it")
	eq(countLog(s.git, "worktree remove"), 0, "nothing was removed")
	yes(table.find(asks.hx.board(b), "o/r/feature") ~= nil, "and it is still listed")
	s.git.dirty["/wt/pr5"] = " M a.txt\n"
	b.typeText("d")
	b.typeText("d")
	w.flush()
	eq(w.toasts[#w.toasts].level, "error", "a dirty worktree is refused")
	eq(w.toasts[#w.toasts].text, "Worktree not removed", "the toast says so")
	eq(w.toasts[#w.toasts].sub, "It has uncommitted changes; commit, stash or remove it yourself.", "and why: git's own refusal")
	eq(countLog(s.git, "worktree remove /wt/pr5"), 1, "git was asked once, and refused")
	s.git.dirty["/wt/pr5"] = nil
	b.typeText("d")
	b.typeText("d")
	w.flush()
	eq(w.toasts[#w.toasts].text, "Worktree removed", "a clean one is removed")
	eq(countLog(s.git, "worktree remove /wt/pr5"), 2, "by one more git command")
	for _, line in s.git.log do
		if string.sub(line, 1, 15) == "worktree remove" then
			lacks(line, "--force", "never forced")
			lacks(line, " -f", "nor with -f")
		end
	end
	same(asks.hx.board(b), { "o/r/lk", "x/y/yb" }, "the row left the board")
	yes(pickerOf(b).selected ~= nil, "the row that took its place is previewed")
	b.event({ ev = "select", id = "layer.queue", item = asks.hx.rowId(b, "o/r/lk") })
	b.typeText("d")
	eq(confirmOf(b), nil, "a locked row: d asks nothing")
	eq(w.toasts[#w.toasts].text, "Not removed here", "and says why")
	eq(w.toasts[#w.toasts].sub, "Locked or missing worktrees are not removed here.", "in full")
	eq(table.find(hx.palette(w, b).ids, "wt-remove"), nil, "the palette lists no Remove either")
	eq(countLog(s.git, "worktree remove /work/r"), 0, "the main checkout was never offered to git")
	eq(countLog(s.git, "worktree remove /wt/lk"), 0, "nor the locked one")
end)

case("host open-url: a GitHub pull request, a GitHub issue and a Jira issue URL are fetched and shown as pinned scopes that accumulate, the other views stay, and the pins are saved", function(w: World)
	local s = jiraHost(w)
	local prUrl = "https://github.com/o/r/pull/45"
	local issueUrl = "https://github.com/o/r/issues/12"
	s.gh.pulls[prUrl] = searchItem(45, "o/r", EPOCH - 60)
	s.gh.pulls[issueUrl] = issueItem(12, "o/r", EPOCH - 60, { title = "Fix login" })
	s.acli.views["ABC-12"] = jiraItem("ABC-12", "Fix login")
	local b = openIssues(w)
	local function labels(): { string }
		local out: { string } = {}
		for _, scope in pickerOf(b).scopes do
			table.insert(out, scope.label)
		end
		return out
	end
	local r = asks.hx.ask(w, b, { op = "open-url", url = prUrl })
	eq(r.ok, true, "a pull request URL is accepted")
	eq(r.message, "Showing o/r#45 in Plotroom", "and said so")
	eq(requestsOf(s.gh, "pull")[1].fields.q, prUrl, "gh looked it up by its URL")
	eq(pickerOf(b).scopes[2].label, "o/r#45", "it is the first scope after Now")
	eq(pickerOf(b).scopes[2].group, "Pins", "under the Pins group")
	eq(pickerOf(b).scope, "pin:o/r#45", "and the active one, by its item's key")
	eq(pickerOf(b).selected, "no_2fr_2345", "its pull request is selected")
	yes(table.find(labels(), "Assigned to me") ~= nil, "the other views are still in the sidebar")
	same(b.saved().pins, { prUrl }, "the pin is saved with the block")
	eq(b.saved().activeViewId, "pin:o/r#45", "and its scope is the saved active view")
	r = asks.hx.ask(w, b, { op = "open-url", url = issueUrl })
	eq(r.message, "Showing o/r#12 in Plotroom", "an issue URL is shown the same way")
	same({ labels()[2], labels()[3] }, { "o/r#45", "o/r#12" }, "the new pin joins the earlier one, after Now")
	eq(pickerOf(b).scope, "pin:o/r#12", "and is the active scope")
	eq(pickerOf(b).noun, "issues", "the pin lists issues")
	eq(pickerOf(b).selected, "no_2fr_2312", "with its issue selected")
	yes(table.find(labels(), "Assigned to me") ~= nil, "the other views stay")
	same(b.saved().pins, { prUrl, issueUrl }, "an issue pin is saved by its URL after the first")
	local again = asks.hx.ask(w, b, { op = "open-url", url = prUrl })
	eq(again.ok, true, "the same URL again is accepted")
	same({ labels()[2], labels()[3] }, { "o/r#45", "o/r#12" }, "without a second pin")
	eq(#b.saved().pins, 2, "or a second saved URL")
	eq(pickerOf(b).scope, "pin:o/r#45", "it shows the pin it already has")
	local restored = w.open(2, { "/work/r" }, b.saved())
	w.flush()
	same({ pickerOf(restored).scopes[2].label, pickerOf(restored).scopes[3].label }, { "o/r#45", "o/r#12" }, "a restored block shows both pins again")
	eq(pickerOf(restored).scope, "pin:o/r#45", "on the active one")
	eq(pickerOf(restored).selected, "no_2fr_2345", "with its pull request selected")
	r = asks.hx.ask(w, b, { op = "open-url", url = "https://acme.atlassian.net/browse/ABC-12" })
	eq(r.message, "Showing ABC-12 in Plotroom", "a Jira browse URL is shown too")
	yes(acliCount(s.acli, "view") >= 1, "acli read the work item")
	eq(pickerOf(b).scopes[4].label, "ABC-12", "as a pinned scope, though the Jira view lists the issue")
	eq(pickerOf(b).scope, "pin:abc#ABC-12", "the active one")
	eq(pickerOf(b).selected, "nabc_23ABC-12", "selected")
	yes(table.find(labels(), "Assigned to me") ~= nil, "beside the Jira view")
	same(b.saved().pins, { prUrl, issueUrl, "https://acme.atlassian.net/browse/ABC-12" }, "and saved")
	eq(b.saved().activeViewId, "pin:abc#ABC-12", "the Jira pin's id is saved whole")
end)

case("host open-url: another site's URL, garbage, an item that is not found and an oversize URL are refused with nothing shown and no gh or acli call for a URL that names no item", function(w: World)
	local s = jiraHost(w)
	s.acli.views["ABC-12"] = jiraItem("ABC-12", "Fix login")
	local b = openIssues(w)
	eq(asks.hx.ask(w, b, { op = "open-url", url = "https://acme.atlassian.net/browse/ABC-12" }).ok, true, "a first pin, though the view lists it")
	local views = acliCount(s.acli, "view")
	local function same_pin()
		eq(pickerOf(b).scopes[2].label, "ABC-12", "the pin is as it was")
	end
	for _, url in {
		"garbage",
		"",
		"https://evil.com/o/r/pull/1",
		"https://github.com.evil.com/o/r/pull/1",
		"http://github.com/o/r/pull/1",
		"https://github.com/o/r/commit/1",
		"https://acme.atlassian.net/wiki/x",
	} do
		local calls = #w.calls
		local r = asks.hx.ask(w, b, { op = "open-url", url = url })
		has(r.problem, "not a GitHub pull request or issue URL, or a Jira issue URL", "refused: " .. url)
		eq(r.ok, nil, "not accepted: " .. url)
		eq(#w.calls, calls, "nothing was spawned for " .. url)
		same_pin()
	end
	local other = asks.hx.ask(w, b, { op = "open-url", url = "https://other.atlassian.net/browse/ABC-12" })
	has(other.problem, "other.atlassian.net", "another Jira site is refused, naming it")
	eq(acliCount(s.acli, "view"), views, "its work item was never read")
	same_pin()
	eq(asks.hx.ask(w, b, { op = "open-url", url = "https://github.com/o/r/" .. string.rep("a", 2049) }), nil, "a URL over 2048 bytes is not answered")
	local missing = asks.hx.ask(w, b, { op = "open-url", url = "https://github.com/o/r/pull/999" })
	yes(missing.problem ~= nil and missing.ok == nil, "a pull request gh cannot see is reported, not shown")
	same_pin()
end)

case("host open-url: the pin cap refuses only a new pin, tells Open by URL, and a pin already kept is shown again; a pin scope has no sort", function(w: World)
	local s = jiraHost(w)
	local url = function(n: number): string
		return "https://github.com/o/r/pull/" .. n
	end
	for n = 1, 21 do
		s.gh.pulls[url(n)] = searchItem(n, "o/r", EPOCH - 60)
	end
	local b = openIssues(w)
	for n = 1, 20 do
		eq(asks.hx.ask(w, b, { op = "open-url", url = url(n) }).ok, true, "pin " .. n)
	end
	goToSettings(b, "general")
	local scopeBefore = pickerOf(b).scope
	local full = asks.hx.ask(w, b, { op = "open-url", url = url(21) })
	has(full.problem, "Pins are full", "a 21st pin is refused to the window, not answered with success")
	eq(full.ok, nil, "no contradictory success")
	eq(#b.saved().pins, 20, "and nothing was added")
	yes(b.state().settings ~= nil, "a refused pin leaves Settings open")
	eq(pickerOf(b).scope, scopeBefore, "and the shown scope as it was")
	eq(asks.hx.ask(w, b, { op = "open-url", url = url(3) }).ok, true, "a pin already kept is shown again at the cap")
	eq(table.find(hx.palette(w, b).ids, "sort"), nil, "a pin scope offers no sort order")
end)

case("host open-url: a lookup that answers another item than the URL names shows nothing and leaves the pin as it was", function(w: World)
	local s = jiraHost(w)
	local good = "https://github.com/o/r/pull/45"
	local wrong = "https://github.com/o/r/pull/46"
	s.gh.pulls[good] = searchItem(45, "o/r", EPOCH - 60)
	s.gh.pulls[wrong] = searchItem(99, "o/r", EPOCH - 60) -- gh answers a different pull request than the one asked for
	local b = openIssues(w)
	eq(asks.hx.ask(w, b, { op = "open-url", url = good }).ok, true, "a first pin")
	eq(pickerOf(b).scopes[2].label, "o/r#45", "it is pinned")
	same(listed(b), { "no_2fr_2345" }, "and lists only that pull request")
	local r = asks.hx.ask(w, b, { op = "open-url", url = wrong })
	yes(r.problem ~= nil and r.ok == nil, "the answer for another item is refused")
	eq(pickerOf(b).scopes[2].label, "o/r#45", "the earlier pin is still the first scope after Now")
	same(listed(b), { "no_2fr_2345" }, "and still lists only its own pull request")
end)

case("host keys: a saved custom key equal to an action's default leaves that action with no key, the binding keeps working, and Settings shows the removal", function(w: World)
	hostScene(w, 3)
	w.kv.put("keys", { worktree = "." })
	local b = openQueue(w)
	eq(hx.palette(w, b).keys.worktree, ".", "the custom binding is the Worktree key")
	local opened = #w.opened
	eq(b.press(".", nil, "."), true, ". is handled")
	eq(w.opened[#w.opened], prLink("worktree", "o/r", 1), "and still makes the worktree")
	eq(#w.opened, opened + 1, "it opened no palette")
	goToSettings(b, "general")
	eq(rowIn(b, "key:more").control.value, "", "Settings shows the shortcut removed")
	same(w.kv.get("keys"), { worktree = "." }, "nothing was written")
end)

case("host views: moving a view to the other kind keeps a sort that kind offers, and resets one it does not with a toast", function(w: World)
	hostScene(w, 3)
	w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "Reviews", integration = "github", query = "is:open", logins = array({}), group = "none", prompts = array({}), sort = "review" },
		{ id = "v2", name = "Recent", integration = "github", query = "is:open author:@me", logins = array({}), group = "none", prompts = array({}), sort = "updated" },
	}) })
	w.kv.put("views-issues", { version = 1, nextId = 2, items = array({
		{ id = "v1", name = "Mine", integration = "github", query = "is:open assignee:@me", logins = array({}), group = "none", prompts = array({}) },
	}) })
	local b = openQueue(w)
	goToSettings(b, "views")
	expand(b, "vopen:prs:v2")
	b.event({ ev = "change", id = "layer.settings", item = "vkind:prs:v2", value = "issues" })
	local moved: any = w.kv.get("views-issues").items[#w.kv.get("views-issues").items]
	eq(moved.name, "Recent", "the view moved")
	eq(moved.sort, "updated", "a sort issues offer is kept")
	for _, t in w.toasts do
		lacks(t.text, "Sort order reset", "and nothing was said")
	end
	expand(b, "vopen:prs:v1")
	b.event({ ev = "change", id = "layer.settings", item = "vkind:prs:v1", value = "issues" })
	moved = w.kv.get("views-issues").items[#w.kv.get("views-issues").items]
	eq(moved.name, "Reviews", "the second view moved")
	eq(moved.sort, nil, "a review order issues do not offer is reset")
	eq(w.toasts[#w.toasts].text, "Sort order reset", "and a toast says so")
	has(w.toasts[#w.toasts].sub, "Review required first", "naming the order")
end)

case("host agents: the hidden main.agents node says the agent map as sorted key=state; pairs, empty with none, and a reloaded block starts empty", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	local function sig(block: Block): any
		return findKey(block.view().main, "agents").p.text
	end
	eq(sig(b), "", "no agents: empty")
	asks.hx.agents(b, { ["o/r#2"] = "idle", ["o/r#1"] = "working" })
	eq(sig(b), "o/r#1=working|||||||||||||||||;o/r#2=idle|||||||||||||||||;", "pairs in key order")
	asks.hx.agents(b, {})
	eq(sig(b), "", "an empty report empties it")
	asks.hx.agents(b, { ["o/r#3"] = "waiting_input" })
	eq(sig(b), "o/r#3=waiting_input|||||||||||||||||;", "one pair")
	local again = w.open(2, { "/work/r" }, b.saved())
	w.flush()
	eq(sig(again), "", "a reloaded block holds no map, so the window sends it again")
	asks.hx.agents(b, { ["o/r#4"] = { state = "working", action = "Review", branch = "fix", title = "Fix it", attention = "stuck", reason = "Tests fail", blocker = "No database", outcome = "pr", verdict = "not", check = "fail", findings = "AC2 unmet", stop = "3 failed checks" } })
	eq(sig(b), "o/r#4=working|Review|fix|Fix it|||||stuck|Tests fail|No database|pr|not|fail|AC2 unmet|3 failed checks||;", "the recorded texts are part of it")
end)

case("host move-status: moves a Jira issue with acli, leaves one already there alone, and says acli's reason when it refuses", function(w: World)
	local s = jiraHost(w)
	s.acli.views["ABC-12"] = jiraItem("ABC-12", "Fix login", { status = { name = "In Progress", statusCategory = { key = "indeterminate" } } })
	local ran: { string } = {}
	local refuse = false
	s.acli.override = function(req: AcliReq): Reply?
		if req.kind == "other" then
			table.insert(ran, table.concat(req.argv, " "))
			return if refuse then { status = 1, stderr = "✗ Error: status 'Blocked' not found\n" } else { stdout = "✓ done\n" }
		end
		return nil
	end
	local b = openIssues(w)
	local function move(status: string, ref: string?): any
		return asks.hx.ask(w, b, { op = "move-status", ref = ref or "ABC-12", status = status })
	end
	eq(move("in progress").already, true, "an issue already there (any case) is left alone")
	eq(#ran, 0, "and acli runs nothing")
	eq(move("12", "12").skipped, true, "a GitHub issue's number is no Jira key")
	eq(move("Done").moved, "Done", "the move works")
	same(ran, { "acli jira workitem transition --key ABC-12 --status Done --yes" }, "by one acli transition of the key to the status")
	refuse = true
	local none = move("Blocked")
	has(none.problem, "status 'Blocked' not found", "an acli failure is the problem, in acli's words")
	eq(#ran, 2, "it was tried once")
end)

-- Starts the action Review (p1, next p2, outcome Review posted) on o/r#5 through the real link flow and returns its link.
local function startChained(w: World, st: FlowStub): any
	st.link("layer.queue.buttons.agent", "plotroom://github/agent/o/r/5")
	st.palette({ items = { { id = "p1", label = "Review" } } })
	w.window.choose = if #w.window.agents > 0 then { "Start another agent", "Review" } else "Review"
	w.click("plotroom://github/agent/o/r/5")
	w.flush()
	st.reply("menu", { items = { { id = "p1", label = "Review", send = "Review {url}", worktree = true, next = "p2", outcome = "review" } } })
	st.reply("worktree", { path = "/wt/r5", summary = "Created", created = true, current = true })
	return (w.kv.get("agent-links") :: any)[1]
end

local function agentFinished(w: World, pane: number, result: string)
	w.window.handlers.agent_finished({ pane = pane, result = result }, w.cx)
	w.flush()
end

local function countOps(st: FlowStub, op: string): number
	local n = 0
	for _, o in st.ops() do
		n += if o == op then 1 else 0
	end
	return n
end

windowCase("window flows: a Verified run starts its action's next action for the same item, in its tab and worktree, once", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local first = startChained(w, st)
	eq(first.chain.action, "p1", "the link keeps the action the agent ran")
	eq(first.chain.next, "p2", "and the one to start when it finishes")
	agentFinished(w, first.agent, "done")
	eq(st.ops()[#st.ops()], "outcome", "done asks for the run's outcome first")
	eq(countOps(st, "action"), 0, "and starts nothing before the verdict")
	st.reply("outcome", { verdict = "unchecked" })
	eq(countOps(st, "action"), 0, "an Unchecked run waits")
	w.advance(61 * 1000) -- an Unchecked run is checked again once a refresh
	st.reply("outcome", { verdict = "verified" })
	eq(countOps(st, "action"), 1, "a Verified run asks the block's host for the next action")
	st.reply("action", { label = "Fix", send = "Fix {url}", worktree = true })
	st.reply("worktree", { path = "/wt/r5", summary = "Reused", created = false, current = true })
	eq(#w.window.agents, 2, "the next agent started")
	eq(w.window.agents[2].prompt, "Fix https://github.com/o/r/pull/5", "with the next action's text")
	eq(w.window.agents[2].cwd, "/wt/r5", "in the same worktree")
	local links: any = w.kv.get("agent-links")
	eq(#links, 2, "both agents stay linked")
	eq(links[1].chain.action, "p2", "the newest is the next action's")
	eq(links[1].chain.name, "Fix", "named for it")
	eq(links[1].chain.depth, 1, "one step along the chain")
	eq(links[1].chain.next, nil, "and with no next of its own")
	eq(links[2].gate, "over", "the run it followed has done its part")
	eq(w.window.panes[links[1].agent].tab, w.window.panes[first.agent].tab, "in the tab of the agent that finished")
	agentFinished(w, first.agent, "done")
	st.reply("outcome", { verdict = "verified" })
	w.advance(60 * 1000)
	eq(countOps(st, "action"), 1, "another turn of the same agent, Verified again, starts nothing")
	agentFinished(w, links[1].agent, "done")
	eq(countOps(st, "action"), 1, "an action without a next action ends the chain")
end)

-- Answers every request of `op` still unanswered with `answer`; how many there were.
local function answerAll(st: FlowStub, op: string, answer: any): number
	local n = 0
	while pcall(st.reply, op, answer) do
		n += 1
	end
	return n
end

windowCase("window flows: a failed, exited or closed agent stops its chain with a toast, and a next action that is gone starts nothing", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local first = startChained(w, st)
	agentFinished(w, first.agent, "failed")
	eq(w.toasts[#w.toasts].text, "Next action not started after Review for o/r#5", "the toast names the action and the item")
	eq(w.toasts[#w.toasts].sub, "The agent reported a failure.", "and why")
	agentFinished(w, first.agent, "done")
	answerAll(st, "outcome", { verdict = "verified" })
	eq(countOps(st, "action"), 0, "the chain stays stopped, even when its run is Verified")
	eq(#w.window.agents, 1, "no second agent")
	local second = startChained(w, st)
	agentFinished(w, second.agent, "closed")
	eq(w.toasts[#w.toasts].sub, "The agent's pane was closed.", "a closed pane says so")
	local third = startChained(w, st)
	agentFinished(w, third.agent, "done")
	answerAll(st, "outcome", { verdict = "verified" })
	st.reply("action", { problem = "That action no longer exists." })
	eq(w.toasts[#w.toasts].text, "Next action not started after Review for o/r#5", "a next action that was deleted is toasted")
	eq(w.toasts[#w.toasts].sub, "That action no longer exists.", "with the host's reason")
	eq(#w.window.agents, 3, "and no agent starts for it")
end)

windowCase("window flows: a done turn whose pane closes while its transcript lags still records one done run and decides its chain", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local first = startChained(w, st)
	local ok = reportCall(`\{"attention":"ok","reason":"Reviewed","commit":null,"pr":null,"evidence":[],"blocker":null}`)
	lastSays(w, first.agent, "", { ok })
	agentFinished(w, first.agent, "done")
	eq(w.kv.get("runs"), nil, "the turn end waits for the transcript")
	w.window.panes[first.agent] = nil
	w.advance(11000)
	local runs: any = w.kv.get("runs")
	eq(#runs, 1, "one run")
	eq(runs[1].result, "done", "done")
	eq((w.kv.get("agent-links") :: any)[1].result, "done", "on the link too")
	st.reply("outcome", { verdict = "verified" })
	eq(countOps(st, "action"), 1, "the chain is decided: a Verified run asks for the next action")
	answerAll(st, "action", { problem = "That action no longer exists." })
	-- Tern reports the closed pane while the turn still waits: the waited turn is recorded first, as done.
	local second = startChained(w, st)
	lastSays(w, second.agent, "", { ok })
	agentFinished(w, second.agent, "done")
	agentFinished(w, second.agent, "closed")
	w.window.panes[second.agent] = nil
	w.advance(11000)
	runs = w.kv.get("runs")
	eq(#runs, 2, "one more run")
	same({ runs[2].result, runs[2].reason }, { "done", "Reviewed" }, "done, with its report")
end)

windowCase("window flows: Go to agent names the action an agent ran, so the agents of one item can be told apart", function(w: World)
	w.load("window")
	local st = flowHost(w)
	startChained(w, st)
	w.window.choose = "Go to agent (working)"
	w.click("plotroom://github/agent/o/r/5")
	w.flush()
	local pick = w.window.picks[#w.window.picks]
	eq(pick.items[1].detail, "Review", "the agent is listed under its action's name, never its pane")
	eq(pick.action, "go or start", "and Enter says it goes to the agent or starts another")
end)

-- Starts the issue action Implement (p1, next prs:p2, outcome PR opened) on o/r#12 through the real link flow and
-- returns its link; `wt` false runs it in the main checkout, which has no branch.
local function startIssueChained(w: World, st: FlowStub, wt: boolean): any
	st.link("layer.queue.buttons.agent", "plotroom://issue/agent/o/r/12")
	st.palette({ items = { { id = "p1", label = "Implement" } } })
	w.window.choose = if #w.window.agents > 0 then { "Start another agent", "Implement" } else "Implement"
	w.click("plotroom://issue/agent/o/r/12")
	w.flush()
	st.reply("menu", { items = { { id = "p1", label = "Implement", send = "Do {url}", worktree = wt, next = "prs:p2", outcome = "pr" } } })
	local vars: any = { url = "https://github.com/o/r/issues/12", title = "Fix login" }
	if wt then
		vars.branch = "12-fix"
	end
	st.reply("issue", { path = "/wt/i12", summary = "Created", created = true, current = true, vars = vars, code = "o/r" })
	return (w.kv.get("agent-links") :: any)[1]
end

windowCase("window flows: an action's Move to status that acli refuses is an error toast with acli's message, and the agent has started", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agent", "plotroom://issue/agent/o/r/12")
	st.palette({ items = { { id = "p1", label = "Implement" } } })
	w.window.choose = "Implement"
	w.click("plotroom://issue/agent/o/r/12")
	w.flush()
	st.reply("menu", { items = { { id = "p1", label = "Implement", send = "Do {url}", worktree = true, status = "Blocked" } } })
	st.reply("issue", { path = "/wt/i12", summary = "Created", created = true, current = true, vars = { url = "https://github.com/o/r/issues/12", title = "Fix login", branch = "12-fix" }, code = "o/r" })
	eq(#w.window.agents, 1, "the agent started")
	local asked = st.reply("move-status", { problem = "status 'Blocked' not found" })
	eq(asked.status, "Blocked", "the host was asked for the action's status")
	local last = w.toasts[#w.toasts]
	eq(last.level, "error", "an error toast")
	has(last.sub, "status 'Blocked' not found", "with acli's message")
end)

windowCase("window flows: an issue action whose next is a pull request action runs it on the pull request of the worktree's branch, in the same worktree and tab", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local first = startIssueChained(w, st, true)
	eq(first.chain.next, "prs:p2", "the link keeps the qualified next")
	eq(first.chain.branch, "12-fix", "the worktree's branch")
	eq(first.chain.code, "o/r", "and the code repository")
	agentFinished(w, first.agent, "done")
	st.reply("outcome", { verdict = "verified" })
	local asked = st.reply("action", { label = "Watch", send = "Watch {url}", worktree = true, pr = 45 })
	eq(asked.kind, "pr", "a pull request action is asked for")
	eq(asked.pid, "p2", "by its own id")
	eq(asked.repo, "o/r", "with the code repository")
	eq(asked.branch, "12-fix", "and the branch its pull request is looked up by")
	local prepared = st.reply("worktree", { path = "/wt/i12", summary = "Reused", created = false, current = true })
	eq(prepared.number, 45, "the worktree is the found pull request's")
	eq(prepared.repo, "o/r", "of the code repository")
	eq(#w.window.agents, 2, "the next agent started")
	eq(w.window.agents[2].prompt, "Watch https://github.com/o/r/pull/45", "with the pull request's variables")
	eq(w.window.agents[2].cwd, "/wt/i12", "in the same worktree")
	local links: any = w.kv.get("agent-links")
	eq(links[1].key, "o/r#45", "linked to the pull request")
	eq(links[1].chain.kind, "pr", "as a pull request action")
	eq(links[1].chain.depth, 1, "one step along the chain")
	eq(w.window.panes[links[1].agent].tab, w.window.panes[first.agent].tab, "in the tab of the agent that finished")
end)

windowCase("window flows: an issue action's pull request action stops with a toast when there is no open pull request, the lookup fails, or the action ran in the main checkout", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local first = startIssueChained(w, st, true)
	agentFinished(w, first.agent, "done")
	st.reply("outcome", { verdict = "verified" })
	st.reply("action", { problem = "No pull request of o/r has 12-fix as its branch." })
	eq(w.toasts[#w.toasts].text, "Next action not started after Implement for o/r#12", "the toast names the action and the issue")
	eq(w.toasts[#w.toasts].sub, "No pull request of o/r has 12-fix as its branch.", "and why")
	eq(#w.window.agents, 1, "nothing started")
	local second = startIssueChained(w, st, true)
	eq((w.kv.get("agent-links") :: any)[2].gate, "over", "an action started by hand ends the earlier run's step")
	agentFinished(w, second.agent, "done")
	st.reply("outcome", { verdict = "verified" })
	st.reply("action", { problem = "The pull request of 12-fix (#40) is merged, not open." })
	has(w.toasts[#w.toasts].sub, "merged", "a merged one is not run on")
	eq(#w.window.agents, 2, "and nothing started")
	local third = startIssueChained(w, st, false)
	eq(third.chain.branch, nil, "the main checkout has no branch")
	local asked = countOps(st, "action")
	agentFinished(w, third.agent, "done")
	st.reply("outcome", { verdict = "verified" })
	eq(countOps(st, "action"), asked, "no lookup is asked")
	has(w.toasts[#w.toasts].sub, "worktree", "the toast says there is no branch to look up")
	eq((w.kv.get("agent-links") :: any)[1].gate, "over", "and the chain ends there")
	eq(#w.window.agents, 3, "and nothing started")
end)

case("host action: with a repository and branch it finds the open or draft pull request on that branch and answers its number, and anything else is a problem", function(w: World)
	local s = hostScene(w, 3)
	w.kv.put("prompts-prs", { version = 1, nextId = 2, items = array({ { id = "p1", name = "Watch", text = "Watch {url}" } }) })
	local b = openQueue(w)
	local function ask(branch: string): any
		return asks.hx.ask(w, b, { op = "action", kind = "pr", pid = "p1", repo = "o/r", branch = branch })
	end
	s.gh.heads["o/r@draft"] = { { number = 7, title = "Draft", state = "OPEN", isDraft = true, url = "https://github.com/o/r/pull/7" } }
	s.gh.heads["o/r@merged"] = { { number = 8, title = "Done", state = "MERGED", isDraft = false, url = "https://github.com/o/r/pull/8" } }
	s.gh.heads["o/r@closed"] = { { number = 9, title = "Shut", state = "CLOSED", isDraft = false, url = "https://github.com/o/r/pull/9" } }
	s.gh.heads["o/r@forked"] = {
		{ number = 11, title = "Fork's", state = "OPEN", isDraft = false, isCrossRepository = true, url = "https://github.com/o/r/pull/11" },
		{ number = 8, title = "Done", state = "MERGED", isDraft = false, isCrossRepository = false, url = "https://github.com/o/r/pull/8" },
	}
	local found = ask("draft")
	eq(found.pr, 7, "a draft one is found")
	eq(found.send, "Watch {url}", "with the action")
	has(ask("merged").problem, "merged", "a merged one is not run on")
	has(ask("closed").problem, "closed", "nor a closed one")
	has(ask("forked").problem, "merged", "a fork's open pull request of the same branch name is not the branch's own")
	has(ask("none").problem, "No pull request", "no pull request on the branch")
	eq(asks.hx.ask(w, b, { op = "action", kind = "pr", pid = "p1" }).pr, nil, "without a branch it only answers the action")
	has(asks.hx.ask(w, b, { op = "action", kind = "pr", pid = "p9", repo = "o/r", branch = "draft" }).problem, "no longer exists", "a deleted action is a problem before any lookup")
end)

windowCase("window flows: a chain stops after 8 actions and an exited agent stops it, each with a toast", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local first = startChained(w, st)
	local links: any = w.kv.get("agent-links")
	links[1].chain.depth = 7
	w.kv.put("agent-links", links)
	agentFinished(w, first.agent, "done")
	st.reply("outcome", { verdict = "verified" })
	eq(countOps(st, "action"), 0, "no request for a ninth action")
	eq(w.toasts[#w.toasts].sub, "A chain of actions stops after 8.", "the toast says why")
	eq((w.kv.get("agent-links") :: any)[1].gate, "over", "and the chain ends there")
	local second = startChained(w, st)
	agentFinished(w, second.agent, "exited")
	eq(w.toasts[#w.toasts].sub, "The agent's program exited.", "an exited result toasts")
end)

windowCase("window flows: a Verified run's next action waits while its host has no Plotroom block, and starts once one opens", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local first = startChained(w, st)
	agentFinished(w, first.agent, "done")
	w.window.panes[1].block = nil
	st.reply("outcome", { verdict = "verified" })
	eq(countOps(st, "action"), 0, "nothing is asked with no block")
	eq((w.kv.get("agent-links") :: any)[1].gate, "next", "the next action stays due")
	w.advance(10 * 1000)
	eq(countOps(st, "action"), 0, "and waits")
	w.window.panes[1].block = "plugin.plotroom.prs"
	w.window.handlers.pane_created({ pane = 1 }, w.cx)
	w.flush()
	eq(countOps(st, "action"), 1, "a Plotroom block opening starts it")
end)

windowCase("window flows: an action with a next action but no outcome or checker starts nothing, and says why", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agent", "plotroom://github/agent/o/r/5")
	st.palette({ items = { { id = "p1", label = "Review" } } })
	w.window.choose = "Review"
	w.click("plotroom://github/agent/o/r/5")
	w.flush()
	st.reply("menu", { items = { { id = "p1", label = "Review", send = "Review {url}", worktree = true, next = "p2" } } })
	st.reply("worktree", { path = "/wt/r5", summary = "Created", created = true, current = true })
	local first = (w.kv.get("agent-links") :: any)[1]
	agentFinished(w, first.agent, "done")
	w.advance(10 * 1000)
	eq(countOps(st, "action"), 0, "nothing verifies the run, so its next action never starts")
	eq(w.toasts[#w.toasts].text, "Next action not started after Review for o/r#5", "the toast names the action and the item")
	has(w.toasts[#w.toasts].sub, "an outcome or a checker", "and says what would let it start")
end)

windowCase("window flows: a pane id reused by a newer link never starts an older chain, and recording an agent drops older links of its pane", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local first = startChained(w, st)
	local links: any = w.kv.get("agent-links")
	local newest = table.clone(links[1])
	newest.chain = nil
	w.kv.put("agent-links", { newest, links[1] })
	agentFinished(w, first.agent, "done")
	answerAll(st, "outcome", { verdict = "verified" })
	eq(countOps(st, "action"), 0, "the older link's chain is ignored")
	w.kv.put("agent-links", { links[1] })
	local f: any = w.load("flows")
	f.recordAgent(w.cx, 1, "o/r#9", first.agent, nil, nil)
	local after: any = w.kv.get("agent-links")
	eq(#after, 1, "one link for the pane")
	eq(after[1].key, "o/r#9", "the newest")
end)

windowCase("window flows: a chained issue step reuses the code repository the chain recorded", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agent", "plotroom://issue/agent/o/r/12")
	st.palette({ items = { { id = "p1", label = "Implement" } } })
	w.window.choose = "Implement"
	w.click("plotroom://issue/agent/o/r/12")
	w.flush()
	st.reply("menu", { items = { { id = "p1", label = "Implement", send = "Do {url}", worktree = true, next = "p2", outcome = "pr" } } })
	st.reply("issue", { path = "/wt/i12", summary = "Created", created = true, current = true, vars = { url = "https://github.com/o/r/issues/12", branch = "12-fix" }, code = "x/code" })
	local first = (w.kv.get("agent-links") :: any)[1]
	agentFinished(w, first.agent, "done")
	st.reply("outcome", { verdict = "verified" })
	st.reply("action", { label = "Fix", send = "Fix {url}", worktree = true })
	local asked = st.reply("issue", { path = "/wt/i12", summary = "Reused", created = false, current = true, vars = {}, code = "x/code" })
	eq(asked.target, "x/code", "the host is told the repository, so it asks nothing")
end)

windowCase("window flows: an action whose agent could not start moves no Jira status", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agent", "plotroom://issue/agent/o/r/12")
	st.palette({ items = { { id = "p1", label = "Implement" } } })
	w.cx.agents.start = function(_self: any, _opts: any): number
		error("no agent program", 0)
	end
	w.window.choose = "Implement"
	w.click("plotroom://issue/agent/o/r/12")
	w.flush()
	st.reply("menu", { items = { { id = "p1", label = "Implement", send = "Do {url}", worktree = true, status = "Blocked" } } })
	st.reply("issue", { path = "/wt/i12", summary = "Created", created = true, current = true, vars = { url = "https://github.com/o/r/issues/12", title = "Fix login", branch = "12-fix" }, code = "o/r" })
	eq(#w.window.agents, 0, "no agent started")
	eq(w.toasts[#w.toasts].level, "error", "the user is told")
	eq(table.find(st.ops(), "move-status"), nil, "and the status is not moved")
end)

windowCase("window flows: a listed pane whose directory is not the link's is not its agent", function(w: World)
	w.load("window")
	local f: any = w.load("flows")
	seedAgent(w, 50, "working", 1, "o/r#5")
	local links: any = w.kv.get("agent-links")
	eq(f.liveAgent(w.cx, 1, "o/r#5") ~= nil, true, "a link with no directory matches by pane")
	links[1].cwd = "/wt/seed50"
	w.kv.put("agent-links", links)
	eq(f.liveAgent(w.cx, 1, "o/r#5") ~= nil, true, "so does one whose directory the pane still has")
	links[1].cwd = "/wt/other"
	w.kv.put("agent-links", links)
	eq(f.liveAgent(w.cx, 1, "o/r#5"), nil, "a pane id reused by another directory is no one's agent")
end)

windowCase("window flows: a chain's next action starts from the block that started the chain, else the lowest block on the host", function(w: World)
	w.load("window")
	local f: any = w.load("flows")
	local st = flowHost(w)
	local first = startChained(w, st)
	eq(first.chain.pane, 1, "the link records the block the chain started from")
	w.window.panes[3] = { block = "plugin.plotroom.prs", cwd = "/work/r", tab = 1 }
	local links: any = w.kv.get("agent-links")
	links[1].chain.pane, links[1].gate = 3, "next"
	w.kv.put("agent-links", links)
	local due = f.dueSteps(w.cx)
	eq(due[1].block, 3, "the starting block is preferred over a lower one")
	f.endStep(due[1])
	w.kv.put("agent-links", links)
	w.window.panes[3].block = nil
	due = f.dueSteps(w.cx)
	eq(due[1].block, 1, "once it is no Plotroom block the lowest one on the host runs it")
end)

windowCase("window flows: a failed turn ends the chain even with no Plotroom block open, and says the next action was not started", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local first = startChained(w, st)
	w.window.panes[1].block = nil
	agentFinished(w, first.agent, "failed")
	eq((w.kv.get("agent-links") :: any)[1].gate, "over", "the chain ends")
	has(w.toasts[#w.toasts].text, "Next action not started", "and the user is told")
	w.window.panes[1].block = "plugin.plotroom.prs"
	agentFinished(w, first.agent, "done")
	answerAll(st, "outcome", { verdict = "verified" })
	eq(countOps(st, "action"), 0, "a later finish starts nothing")
end)

windowCase("window flows: the status timer stops with no live agent", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agentgo", "plotroom://github/agentgo/o/r/5")
	seedAgent(w, 50, "working", 1, "o/r#5")
	w.window.handlers.window_start(w.cx)
	w.window.agentStates[50] = "exited"
	w.advance(4000)
	local sent = #statusEvents(w)
	w.window.agentStates[50] = "working"
	w.advance(12000)
	eq(#statusEvents(w), sent, "nothing is watched once no agent is live")
end)

windowCase("window flows: one pane_closed runs agent sync, redraw and the protocol check", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agentgo", "plotroom://github/agentgo/o/r/5")
	seedAgent(w, 50, "idle", 1, "o/r#5")
	announce(w, 1, "2")
	w.window.handlers.pane_closed({ pane = 9 }, w.cx)
	eq(#statusEvents(w), 1, "the agent map was sent")
	local redraws = 0
	for _, e in w.window.events do
		if e.ev.act == "redraw" then
			redraws += 1
		end
	end
	eq(redraws, 1, "the block was redrawn")
	eq(protocolWarning(w, 1), "Plotroom on host1 is a different version from this window's", "and the protocol check ran")
end)

windowCase("window flows: the status map carries an agent's last message cut to 200 bytes and its delivery error", function(w: World)
	w.load("window")
	local st = flowHost(w)
	st.link("layer.queue.buttons.agentgo", "plotroom://github/agentgo/o/r/5")
	seedAgent(w, 50, "idle", 1, "o/r#5")
	w.window.agentNotes[50] = { last_message = string.rep("x", 300), delivery_error = "omp needs updating" }
	w.window.handlers.window_start(w.cx)
	w.advance(4100)
	local row: any = statusEvents(w)[1].map["o/r#5"]
	eq(#row.last, 200, "the last message is cut to 200 bytes")
	eq(row.err, "omp needs updating", "the delivery error is sent")
	local links: any = w.kv.get("agent-links")
	eq(links[1].last, nil, "neither is saved on the link")
end)

windowCase("window flows: an agent's result and time are saved on its link and survive a reload", function(w: World)
	w.load("window")
	flowHost(w)
	seedAgent(w, 50, "idle", 1, "o/r#5")
	agentFinished(w, 50, "done")
	local links: any = w.kv.get("agent-links")
	eq(links[1].result, "done", "the result is saved")
	yes(string.match(links[1].ended, "^%d%d:%d%d$") ~= nil, "with the time")
	local sent = statusEvents(w)
	eq(sent[#sent].map["o/r#5"].result, "done", "the block hears it")
	eq(sent[#sent].map["o/r#5"].ended, links[1].ended, "with the time")
	local reloaded = flowHost(w) -- a block that has lost the map
	w.window.handlers.window_start(w.cx)
	local before = #statusEvents(w)
	w.advance(4100)
	eq(#statusEvents(w), before + 1, "the reload sends the map again")
	eq(statusEvents(w)[before + 1].map["o/r#5"].result, "done", "a reloaded block is told the saved result again")
	reloaded.ops()
end)

windowCase("window flows: an agent-links row whose result is not a string is malformed and never written over", function(w: World)
	w.load("window")
	flowHost(w)
	seedAgent(w, 50, "idle", 1, "o/r#4")
	local links: any = w.kv.get("agent-links")
	links[1].result = 5
	w.kv.put("agent-links", links)
	local before = w.kv.store["agent-links"]
	agentFinished(w, 50, "done")
	eq(w.kv.store["agent-links"], before, "the store is as it was")
end)

case("host agents: the Agents list shows the last message, delivery error and last run", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	asks.hx.agents(b, { ["o/r#1"] = { state = "idle", action = "Review", last = "All checks pass", err = "omp needs updating", result = "done", ended = "14:02" } })
	pickScope(b, "agents")
	w.flush()
	local detail = detailText(pickerOf(b).items[1])
	has(detail, "Review: done 14:02", "the row says how the last run ended")
	has(detail, "All checks pass", "the last message")
	has(detail, "omp needs updating", "and the delivery error")
	asks.hx.agents(b, { ["o/r#1"] = { state = "idle", last = "bad\ntext", result = 5 } })
	same(b.state().agentInfo["o/r#1"], {}, "texts that are not clean strings are dropped")
end)

case("host agents: a working agent shows its clock, and its estimated bar once its action expects a duration, in the Agents list, its preview and the item's preview, drawn again once a second", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	local now = w.seconds()
	-- The bar's cells as "filled/all": the pending span (agent working) is how far along the run probably is.
	local function bar(spans: { any }): string
		local filled, all = 0, 0
		for _, s in spans do
			if type(s) == "table" and string.find(s.t, "━", 1, true) then
				local n = utf8.len(s.t) :: number
				all += n
				filled += if s.s == "pending" then n else 0
			end
		end
		return filled .. "/" .. all
	end
	local function fact(key: string): { any }?
		for _, part in { "stage", "agent" } do
			local facts: any = findKey(pickerNode(b), part, "kv")
			for _, item in if facts then facts.p.items else {} do
				if item.k == key then
					return item.v
				end
			end
		end
		return nil
	end
	asks.hx.agents(b, {
		["o/r#1"] = { state = "working", action = "Review", title = "Fix one", since = tostring(now - 67), expected = "100" },
		["o/r#2"] = { state = "working", action = "Watch", title = "Fix two", since = tostring(now - 5) },
		["o/r#3"] = { state = "idle", action = "Fix", title = "Fix three", since = tostring(now - 5), expected = "100" },
	})
	has(h.factOf(b, "Working") :: string, "1:07", "the item's preview shows the clock")
	eq(bar(fact("Working") :: any), "7/10", "and the bar at 1 - e^(-2.3 * 67 / 100), 79%")
	b.typeText("j")
	eq(h.factOf(b, "Working"), "0:05", "an action with too few runs to expect a duration: the clock alone")
	b.typeText("j")
	eq(h.factOf(b, "Working"), nil, "an idle agent: no clock")
	pickScope(b, "agents")
	w.flush()
	local rows: { string } = {}
	for _, item in pickerOf(b).items do
		table.insert(rows, detailText(item) .. " " .. bar(item.detail))
	end
	same(rows, { "━━━━━━━━━━ 1:07 · Review 7/10", "0:05 · Watch 0/0", "Fix 0/0" }, "the Agents rows lead with the bar and clock of a working agent")
	has(h.factOf(b, "Working") :: string, "1:07", "and so does its preview")
	local drawn = b.renders()
	w.advance(1000)
	eq(b.renders(), drawn + 1, "a second later the view is drawn again")
	eq(h.factOf(b, "Working"), "━━━━━━━━━━ 1:08", "with the clock moved on")
	w.advance(3000)
	eq(b.renders(), drawn + 4, "once a second")
	b.press("down")
	eq(b.renders(), drawn + 5, "a key press draws it once")
	w.advance(1000)
	eq(b.renders(), drawn + 6, "and adds no redraw of its own")
	asks.hx.agents(b, { ["o/r#1"] = { state = "working", action = "Review", since = tostring(w.seconds() - 100), expected = "100" } })
	eq(bar(fact("Working") :: any), "8/10", "at the expected duration the bar is at 90%")
	asks.hx.agents(b, { ["o/r#1"] = { state = "working", action = "Review", since = tostring(now - 100000), expected = "100" } })
	eq(bar(fact("Working") :: any), "9/10", "and it is never full before the run ends")
	asks.hx.agents(b, { ["o/r#1"] = { state = "working", action = "Review", since = "soon", expected = "-5" } })
	eq(h.factOf(b, "Working"), nil, "a start that is not digits is dropped")
	asks.hx.agents(b, { ["o/r#1"] = { state = "idle", action = "Review" } })
	w.advance(1000)
	drawn = b.renders()
	w.advance(5000)
	eq(b.renders(), drawn, "no working agent shown: nothing is drawn again")
end)

case("host agents: a run's checked outcome shows on its row, the preview and the Agents list; Not verified or a stuck report is Needs you while the agent is idle", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	local function badges(id: string): { string }
		for _, row in pickerOf(b).items do
			if row.id == id then
				local out: { string } = {}
				for _, badge in row.badges or {} do
					table.insert(out, badge.text)
				end
				return out
			end
		end
		return {}
	end
	asks.hx.agents(b, {
		["o/r#1"] = { state = "idle", action = "Implement", outcome = "pr", verdict = "not" },
		["o/r#2"] = { state = "idle", action = "Review", outcome = "review", verdict = "verified" },
		["o/r#3"] = { state = "idle", action = "Watch", outcome = "merged", verdict = "unchecked", attention = "stuck" },
	})
	eq(asks.hx.stage(b, "no_2fr_231"), "Needs you", "Not verified is Needs you")
	has(table.concat(badges("no_2fr_231"), ","), "Not verified", "and its row says Not verified")
	eq(asks.hx.stage(b, "no_2fr_232"), "PR open", "Verified leaves the stage to GitHub")
	has(table.concat(badges("no_2fr_232"), ","), "Verified", "and its row says Verified")
	eq(asks.hx.stage(b, "no_2fr_233"), "Needs you", "a stuck report is Needs you, Unchecked or not")
	has(table.concat(badges("no_2fr_233"), ","), "Unchecked", "and its row says Unchecked")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_231" })
	eq(h.factOf(b, "Outcome"), "PR opened: Not verified", "the preview names the outcome and its verdict")
	asks.hx.agents(b, { ["o/r#1"] = { state = "working", outcome = "pr", verdict = "not" } })
	eq(asks.hx.stage(b, "no_2fr_231"), "Agent working", "once you answer it, the agent works again")
	asks.hx.agents(b, { ["o/r#1"] = { state = "exited" } })
	eq(asks.hx.stage(b, "no_2fr_231"), "PR open", "an exited agent's outcome no longer shows")
	asks.hx.agents(b, { ["o/r#1"] = { state = "idle", action = "Implement", outcome = "pr", verdict = "verified" } })
	pickScope(b, "agents")
	w.flush()
	has(table.concat(badges("go_2fr_231"), ","), "Verified", "the Agents row says it")
	local out: { string } = {}
	collectTexts(pickerNode(b), out)
	has(table.concat(out, "|"), "PR opened: Verified", "and so does its preview")
	asks.hx.agents(b, { ["o/r#1"] = { state = "idle", outcome = "pr", verdict = "maybe" } })
	same(badges("go_2fr_231"), { "Idle" }, "a verdict that is none of the three shows nothing")
end)

case("usage: medians expect a duration only of an action with 5 timed runs, the middle one or the mean of the middle two", function(w: World)
	local usage: any = w.load("usage")
	local runs: { any } = {}
	local function add(action: string, d: number?, started: number?)
		table.insert(runs, { key = "o/r#1", action = action, started = started or (if d then EPOCH else nil), ended = EPOCH + (d or 0), result = "done" })
	end
	for _, d in { 50, 10, 60, 30, 20, 40 } do
		add("Six", d)
	end
	for _, d in { 10, 20, 30, 40 } do
		add("Four", d)
	end
	add("Four", nil) -- an old run with no start is not timed
	add("Four", 5, EPOCH + 10) -- nor one that ended before it started
	for _, d in { 1, 2, 3, 4, 5 } do
		add("", d)
	end
	same(usage.medians(runs), { Six = 35 }, "6 runs: the mean of the middle two; 4 timed runs and an unnamed action expect nothing")
	add("Four", 90)
	same(usage.medians(runs), { Six = 35, Four = 30 }, "a fifth timed run: its middle one")
end)

case("host outcome: the block answers an outcome check with GitHub's verdict, and a malformed one is Unchecked without asking", function(w: World)
	local s = hostScene(w, 3)
	local b = openQueue(w)
	local before = #s.gh.requests
	local a = asks.hx.ask(w, b, { op = "outcome", outcome = "pr", repo = "o/r", since = EPOCH, login = "octocat" })
	same({ a.verdict, a.why }, { "not", "The run had no branch." }, "a run that left no branch opened no pull request")
	for _, bad: { [string]: any } in { { repo = "nope" }, { commit = "abc" }, { number = 1.5 }, { branch = "a\nb" }, { since = "now" } } :: { any } do
		local q: { [string]: any } = { op = "outcome", outcome = "pushed", repo = "o/r", branch = "b", since = EPOCH, login = "octocat" }
		for k, v in bad do
			q[k] = v
		end
		eq(asks.hx.ask(w, b, q).verdict, "unchecked", "malformed: " .. jsonEncode(bad))
	end
	eq(#s.gh.requests, before, "GitHub was never asked")
end)

case("host actions: default actions name their outcome, a saved action without one reads as None, and Settings sets it", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	local storage: any = w.load("host/storage")
	local core: any = w.load("host/core")
	local function outcomes(kind: any): { string }
		local out: { string } = {}
		for _, p in storage.loadPrompts(kind).items do
			table.insert(out, p.name .. "=" .. (p.outcome or "none"))
		end
		return out
	end
	w.kv.put("prompts-prs", nil)
	w.kv.put("prompts-issues", nil)
	same(outcomes(core.KINDS.prs), { "Review=review", "Quick review=review", "Address feedback=replied", "Watch=merged" }, "pull request defaults")
	same(outcomes(core.KINDS.issues), { "Implement=pr", "Fix=pr", "Plan=none", "Check=none" }, "issue defaults")
	w.kv.put("prompts-prs", { version = 1, nextId = 3, items = array({ { id = "p1", name = "Review", text = "Review {url}" }, { id = "p2", name = "Later", text = "x", outcome = "a-future-one" } }) })
	same(outcomes(core.KINDS.prs), { "Review=none", "Later=none" }, "a saved action without an outcome, or with one this version does not know, has none")
	goToSettings(b, "prompts")
	expand(b, "popen:prs:p1")
	local row = rowIn(b, "poutcome:prs:p1")
	eq(row.label, "Outcome", "the action's Outcome row")
	eq(row.control.value, "none", "reads None")
	local labels: { string } = {}
	for _, o in row.control.options do
		table.insert(labels, o.label)
	end
	same(labels, { "None", "Review posted", "PR opened", "Pushed", "Replied to feedback", "Merged" }, "with the six outcomes")
	b.event({ ev = "change", id = "layer.settings", item = "poutcome:prs:p1", value = "pushed" })
	eq((w.kv.get("prompts-prs") :: any).items[1].outcome, "pushed", "a choice is saved")
	b.event({ ev = "change", id = "layer.settings", item = "poutcome:prs:p1", value = "bogus" })
	eq((w.kv.get("prompts-prs") :: any).items[1].outcome, "pushed", "an outcome not offered changes nothing")
	b.event({ ev = "change", id = "layer.settings", item = "poutcome:prs:p1", value = "none" })
	eq((w.kv.get("prompts-prs") :: any).items[1].outcome, nil, "None clears it")
end)

case("usage: the report counts each action's outcomes as verified, not verified and unchecked", function(w: World)
	local usage: any = w.load("usage")
	local prompts: any = w.load("prompts")
	local runs: { any } = {
		{ key = "o/r#1", action = "Implement", result = "done", ended = EPOCH, outcome = "pr", verdict = "verified" },
		{ key = "o/r#2", action = "Implement", result = "done", ended = EPOCH, outcome = "pr", verdict = "verified" },
		{ key = "o/r#3", action = "Implement", result = "done", ended = EPOCH, outcome = "pr", verdict = "not" },
		{ key = "o/r#4", action = "Implement", result = "failed", ended = EPOCH, outcome = "pr" },
		{ key = "o/r#5", action = "Plan", result = "done", ended = EPOCH },
	}
	local text = usage.report({ host = { value = { since = 0, counts = {} } }, here = { value = { since = 0, counts = {} } }, runs = { value = runs }, name = function(id: string): string
		return id
	end, outcome = prompts.outcomeLabel })
	has(text, "Implement · 4 runs", "the action's runs")
	has(text, "  Outcome PR opened · verified 2, not verified 1, unchecked 1", "and its outcome counts: a run never checked counts as unchecked")
	lacks(string.match(text, "Plan[^\n]*\n[^\n]*") or "", "Outcome", "an action with no outcome has no outcome line")
end)

-- ---------------------------------------------------------------- agent events, Files, selection

local function reviewWith(w: World, label: (string, number) -> string?)
	local reviews = 0
	w.window.decide = function(opts: any): (string?, boolean?)
		local ph: string = opts.placeholder or ""
		if string.find(ph, "^Send the selection %(") then
			return "o/r#5", nil
		end
		reviews += 1
		return label(ph, reviews), nil
	end
end

local function pickRows(pick: any): { string }
	local out: { string } = {}
	for _, item in pick.items do
		table.insert(out, item.label)
	end
	return out
end

windowCase("window events: agent_state tells the blocks at once and toasts a waiting agent; the 4 s timer still carries last messages and delivery errors", function(w: World)
	w.load("window")
	local st = flowHost(w)
	startAgentOn(w, st)
	local agent = (w.kv.get("agent-links") :: any)[1].agent
	local told, toasts = #statusEvents(w), #w.toasts
	local reads = w.window.reads[1] or 0
	w.window.agentStates[agent] = "waiting_input"
	w.window.handlers.agent_state({ pane = agent, old = "working", new = "waiting_input" }, w.cx)
	w.window.handlers.agent_state({ pane = agent, old = "working", new = "waiting_input" }, w.cx)
	eq(#statusEvents(w), told, "the handler itself reads and sends nothing: Tern holds its state while it dispatches")
	eq(w.window.reads[1] or 0, reads, "no surface was read inside the event")
	w.advance(1)
	eq(#statusEvents(w), told + 1, "the next frame sends the new state once, long before the 4 s tick, though two events came")
	eq(statusEvents(w)[told + 1].map["o/r#5"].state, "waiting_input", "which is the new one")
	eq(w.toasts[toasts + 1].text, "o/r#5 needs input", "and the waiting agent is toasted")
	w.window.handlers.agent_state("nonsense", w.cx)
	w.window.handlers.agent_state({ new = "idle" }, w.cx)
	w.advance(1)
	eq(#statusEvents(w), told + 1, "an event with no pane does nothing")
	w.window.agentNotes[agent] = { last_message = "All done", delivery_error = "omp busy" }
	w.advance(4000)
	local map = statusEvents(w)[told + 2].map["o/r#5"]
	eq(map.last, "All done", "the timer's reconciliation carries the last message, which no event does")
	eq(map.err, "omp busy", "and the delivery error")
end)

windowCase("window events: pane_created of any block kind starts the agents' timer, and only a new Plotroom block pays for a protocol read", function(w: World)
	w.load("window")
	flowHost(w)
	w.advance(1)
	seedAgent(w, 5, "working", 1, "o/r#5")
	w.window.panes[6] = { block = nil, cwd = "/x", tab = 6, kind = "browser" }
	local reads = w.window.reads[1] or 0
	w.window.handlers.pane_created({ pane = 6 }, w.cx)
	eq(w.window.reads[1] or 0, reads, "a Browser block opening reads no surface for the protocol check")
	w.window.agentStates[5] = "waiting_input"
	w.advance(4000)
	eq(w.toasts[#w.toasts].text, "o/r#5 needs input", "yet the timer it started saw the waiting agent")
	local before = w.window.reads[1] or 0
	w.window.handlers.pane_created({ pane = 1 }, w.cx)
	eq((w.window.reads[1] or 0) > before, true, "a new Plotroom block is checked")
end)

windowCase("window events: a hook paused over budget shows in the status line and toasts once, and resuming says so", function(w: World)
	w.load("window")
	w.advance(1)
	local function texts(): { string }
		local out: { string } = {}
		for _, s in ((w.window.status :: any)({ pane = 7 }) or {}) do
			table.insert(out, s.text)
		end
		return out
	end
	local toasts, refreshes = #w.toasts, w.window.refreshes
	w.window.handlers.budget({ hook = "timer", state = "paused", ms = 5, paused_ms = 5000 }, w.cx)
	eq(w.toasts[toasts + 1].text, "Plotroom paused: timer", "named")
	eq(w.toasts[toasts + 1].level, "error", "as an error")
	same(texts(), { "Plotroom paused: timer" }, "and shown on every pane's status line")
	eq(w.window.refreshes, refreshes + 1, "which was redrawn")
	w.window.handlers.budget({ hook = "status", state = "paused", ms = 4, paused_ms = 5000 }, w.cx)
	eq(#w.toasts, toasts + 1, "a second pause adds no toast")
	w.window.handlers.budget({ hook = "timer", state = "resumed" }, w.cx)
	eq(#w.toasts, toasts + 1, "one still paused: nothing said")
	w.window.handlers.budget({ hook = "status", state = "resumed" }, w.cx)
	eq(w.toasts[#w.toasts].text, "Plotroom resumed", "the last resume is said")
	same(texts(), {}, "and the status line is clean")
	w.window.handlers.budget({ hook = 5, state = "paused" }, w.cx)
	w.window.handlers.budget("x", w.cx)
	same(texts(), {}, "malformed events change nothing")
end)

windowCase("window files: the Files button opens Plotroom on the folder it shows, refuses another host's folder, and writes nothing", function(w: World)
	w.load("window")
	local button = w.window.filesButtons["open-plotroom"]
	eq(button.title, "Open Plotroom", "the button's tooltip")
	local kv: { [string]: string } = {}
	for k, v in w.kv.store do
		kv[k] = v
	end
	button.run({ root = "/work/other", host = "", selection = {}, tab = "files" }, w.cx)
	local launched = w.window.launches[#w.window.launches]
	eq(launched.block, "plotroom.prs", "a Plotroom block")
	eq(launched.cwd, "/work/other", "on the Files folder")
	same(launched.args, { "/work/other" }, "which it is given as its argument")
	same(w.kv.store, kv, "no store was written")
	local count = #w.window.launches
	button.run({ root = "/home/me/x", host = "elsewhere", selection = {}, tab = "files" }, w.cx)
	eq(#w.window.launches, count, "a folder on another host opens nothing")
	eq(w.toasts[#w.toasts].text, "Plotroom not opened", "and says so")
	has(w.toasts[#w.toasts].sub, "elsewhere", "naming the host")
	button.run({ root = "/bad\npath", host = "", selection = {}, tab = "files" }, w.cx)
	eq(#w.window.launches, count, "a path with a control character opens nothing")
	button.run({ root = nil, host = "", selection = {}, tab = "files" }, w.cx)
	eq(w.window.launches[#w.window.launches].cwd, "/work/r", "with no folder it opens as Open does, in the focused pane's directory")
end)

windowCase("window selection: the user picks the agent, reviews every line and sends only by the Send row; cancelling, a dead agent and a refused delivery send nothing", function(w: World)
	w.load("window")
	local st = flowHost(w)
	startAgentOn(w, st)
	local agent = (w.kv.get("agent-links") :: any)[1].agent
	w.window.selection = { pane = 1, kind = "terminal", text = "local x = 1\r\n\treturn x" }
	reviewWith(w, function(_ph, _n)
		return "Cancel"
	end)
	w.command("agent-message-selection")
	w.flush()
	eq(w.window.selectionAsks[1].max_chars, 4000, "the selection is read with an explicit cap")
	same(pickRows(w.window.picks[#w.window.picks - 1]), { "o/r#5" }, "the agents to choose from: each live linked one")
	same(pickRows(w.window.picks[#w.window.picks]), { "Cancel", "Send to o/r#5", "Add a note…", "Selected in the terminal block:", "local x = 1", "\treturn x" }, "the review: Cancel first, then Send, then every line as it will be sent")
	eq(#w.window.agentCalls, 0, "Cancel sends nothing")
	reviewWith(w, function(_ph, _n)
		return nil
	end)
	w.command("agent-message-selection")
	w.flush()
	eq(#w.window.agentCalls, 0, "dismissing the review sends nothing")
	reviewWith(w, function(_ph, _n)
		return "Send to o/r#5"
	end)
	w.command("agent-message-selection")
	w.flush()
	same(w.window.agentCalls, { { op = "ask", pane = agent, text = "Selected in the terminal block:\nlocal x = 1\n\treturn x" } }, "Send delivers it whole, newlines kept")
	eq(w.toasts[#w.toasts].text, "Sent to the agent of o/r#5", "and says so")
	w.window.askFails = true
	w.command("agent-message-selection")
	w.flush()
	eq(w.toasts[#w.toasts].text, "Could not message the agent for o/r#5", "a refused delivery is an error")
	w.window.askFails = false
	w.window.agentStates[agent] = "exited"
	local calls = #w.window.agentCalls
	w.command("agent-message-selection")
	w.flush()
	eq(w.toasts[#w.toasts].text, "No linked agent is running", "an exited agent is not offered")
	eq(#w.window.agentCalls, calls, "and nothing is sent")
end)

windowCase("window selection: a note is added by one line, a long selection is clipped in view and in the send, and a file's selection comes from read", function(w: World)
	w.load("window")
	local st = flowHost(w)
	startAgentOn(w, st)
	local lines: { string } = {}
	for i = 1, 50 do
		table.insert(lines, "line " .. i)
	end
	w.window.selection = { pane = 1, kind = "terminal", text = table.concat(lines, "\n"), chars_clipped = true }
	w.window.typed = "see this"
	local sent = ""
	reviewWith(w, function(_ph, n)
		if n == 1 then
			return "Add a note…"
		end
		return "Send to o/r#5"
	end)
	w.command("agent-message-selection")
	w.flush()
	local review = w.window.picks[#w.window.picks]
	has(review.items[3].label, "Edit note", "after a note the row offers to edit it")
	eq(review.items[4].label, "see this", "the note is shown first, in its own group")
	local rows = pickRows(review)
	eq(rows[#rows], "[clipped: first 40 of 50 lines]", "the cut is a row, so it is explicit")
	eq(rows[#rows - 1], "line 40", "after the 40th line")
	sent = (w.window.agentCalls[1] :: any).text
	eq(string.sub(sent, 1, #"see this\n\nSelected in the terminal block:\nline 1"), "see this\n\nSelected in the terminal block:\nline 1", "the note leads the message")
	eq(string.find(sent, "line 41", 1, true), nil, "no line past the shown ones is sent")
	has(w.window.picks[#w.window.picks - 2].placeholder, "clipped", "the picker says the reader clipped it")
	w.window.agentCalls = {}
	w.window.typed = string.rep("x", 401)
	reviewWith(w, function(_ph, n)
		return if n == 1 then "Add a note…" else "Send to o/r#5"
	end)
	w.command("agent-message-selection")
	w.flush()
	eq(#w.window.agentCalls, 0, "a note over its cap is refused")
	w.window.selection = nil
	w.window.docs["/work/f.txt"] = "alpha\nbeta"
	w.window.fileRead = { kind = "file", path = "/work/f.txt", selection = { anchor = 0, head = 10 } }
	w.window.typed = nil
	reviewWith(w, function(_ph, _n)
		return "Send to o/r#5"
	end)
	w.command("agent-message-selection")
	w.flush()
	eq((w.window.agentCalls[1] :: any).text, "Selected in the file block:\nalpha\nbeta", "a file's selection is read from its text by its offsets")
	w.window.fileRead = nil
	w.command("agent-message-selection")
	eq(w.toasts[#w.toasts].text, "Select some text first", "no selection at all is said, and nothing is offered")
end)

windowCase("window selection: a file's selection is only byte offsets, so its text is read from the file: reversed, nonzero and multibyte ranges are cut exactly, and anything unsure is refused", function(w: World)
	w.load("window")
	local st = flowHost(w)
	startAgentOn(w, st)
	local text = "héllo wörld\nline2"
	w.window.docs["/work/f.txt"] = text
	local function select(anchor: number, head: number)
		w.window.fileRead = { kind = "file", path = "/work/f.txt", selection = { anchor = anchor, head = head }, size = #text }
	end
	reviewWith(w, function(_ph, _n)
		return "Send to o/r#5"
	end)
	local function run()
		w.window.agentCalls = {}
		w.command("agent-message-selection")
		w.flush()
	end
	select(0, 6)
	run()
	eq((w.window.agentCalls[1] :: any).text, "Selected in the file block:\nhéllo", "a multibyte range from the start")
	same(w.window.docReads, { "/work/f.txt" }, "the file was read once")
	select(13, 7)
	run()
	eq((w.window.agentCalls[1] :: any).text, "Selected in the file block:\nwörld", "a reversed nonzero range")
	select(0, #text)
	run()
	eq((w.window.agentCalls[1] :: any).text, "Selected in the file block:\nhéllo wörld\nline2", "select all keeps the line break")
	local said = #w.toasts
	select(2, 5)
	run()
	eq(#w.window.agentCalls, 0, "a start inside a character sends nothing")
	eq(w.toasts[#w.toasts].text, "The selection could not be read", "and says so")
	select(0, 99)
	run()
	eq(#w.window.agentCalls, 0, "an end past the file sends nothing")
	has(w.toasts[#w.toasts].sub, "changed", "the file changed since")
	select(4, 4)
	run()
	eq(w.toasts[#w.toasts].text, "Select some text first", "an empty range is no selection")
	eq(#w.toasts > said, true, "each refusal toasted")
	select(0, 6)
	w.window.agentCalls = {}
	w.command("agent-message-selection")
	select(1, 6) -- the user moved the selection while the file was being read
	w.flush()
	eq(#w.window.agentCalls, 0, "a selection that moved during the read sends nothing")
	eq(w.toasts[#w.toasts].text, "The selection changed while the file was read", "and says so")
	w.window.docs["/work/f.txt"] = nil
	select(0, 6)
	run()
	eq(w.toasts[#w.toasts].text, "The file could not be read", "a file that cannot be read is an error")
	w.window.docs["/work/f.txt"] = text
	w.window.hostOf[1] = 2
	local reads = #w.window.docReads
	run()
	eq(w.toasts[#w.toasts].text, "That file is on another host", "a file of another host is refused")
	eq(#w.window.docReads, reads, "and never read")
	w.window.hostOf[1] = nil
	w.window.docs["/work/f.txt"] = string.rep("line\n", 1000)
	w.window.fileRead = { kind = "file", path = "/work/f.txt", selection = { anchor = 0, head = 5000 }, size = 5000 }
	run()
	has((w.window.agentCalls[1] :: any).text, "[clipped: first 40 of 800 lines]", "a big range is cut at the 4000-byte cap, then shown and sent as 40 lines")
	has(w.window.picks[#w.window.picks - 1].placeholder, "4000 characters, clipped", "and the picker says it was clipped")
end)

windowCase("window selection: with a file focused another block's old selection is never taken for it, and the count is characters", function(w: World)
	w.load("window")
	local st = flowHost(w)
	startAgentOn(w, st)
	w.window.panes[2] = { block = nil, cwd = "/", tab = 1, kind = "terminal" }
	w.window.selection = { pane = 2, kind = "terminal", text = "stale terminal text" }
	w.window.panes[1].kind = "file"
	w.window.docs["/work/f.txt"] = "日本語 text"
	w.window.fileRead = { kind = "file", path = "/work/f.txt", selection = { anchor = 0, head = 9 }, size = 14 }
	reviewWith(w, function(_ph, _n)
		return "Send to o/r#5"
	end)
	w.command("agent-message-selection")
	w.flush()
	eq((w.window.agentCalls[1] :: any).text, "Selected in the file block:\n日本語", "the focused file's own range is what is offered")
	has(w.window.picks[#w.window.picks - 1].placeholder, "(3 characters)", "counted in characters, not bytes")
	w.window.panes[1].kind = nil
	w.window.agentCalls = {}
	w.command("agent-message-selection")
	w.flush()
	eq((w.window.agentCalls[1] :: any).text, "Selected in the terminal block:\nstale terminal text", "with no file focused the plain selection call is used, as before")
end)

windowCase("window selection: only an agent on the host its link recorded is offered, and another host's is named", function(w: World)
	w.load("window")
	local st = flowHost(w)
	startAgentOn(w, st)
	local links = w.kv.get("agent-links") :: any
	links[1].host = { id = 2, name = "", address = "host2" }
	w.kv.put("agent-links", links)
	w.window.selection = { pane = 1, kind = "terminal", text = "x" }
	w.command("agent-message-selection")
	w.flush()
	eq(w.toasts[#w.toasts].text, "No linked agent is running", "a link whose host is not the agent pane's is not offered (a pane id may be reused)")
	seedAgent(w, 5, "working", 2, "x/y#1")
	w.window.decide = function(_opts: any): (string?, boolean?)
		return "Cancel", nil
	end
	w.command("agent-message-selection")
	w.flush()
	local rows = w.window.picks[#w.window.picks].items
	eq(#rows, 1, "the one matching agent is offered")
	eq(rows[1].label, "x/y#1", "by its item")
	has(rows[1].detail, "host2", "with the host it runs on")
	eq(#w.window.agentCalls, 0, "nothing was sent")
end)

case("lens: only a github.com pull request is offered Show in Plotroom; another host keeps Copy and Open in browser", function(w: World)
	w.load("host")
	local def: any = w.lenses["pr-create"]
	local url = "https://git.example.com/o/r/pull/45"
	local state = def.open({ line = "gh pr create", typed = "gh pr create", program = "gh", args = { "pr", "create" } }, w.cx)
	def.line(state, { text = url, links = {} })
	def.finish(state, 0)
	local view = def.view(state)
	eq(findKey(view, "show", "item"), nil, "no Show in Plotroom for a host Plotroom cannot parse")
	eq(findKey(view, "copy", "item").p.href, url, "Copy stays")
	eq(findKey(view, "browser", "item").p.href, url, "and Open in browser")
end)

windowCase("window flows: the lens's show link refuses a pull request on another host than github.com", function(w: World)
	w.load("window")
	flowHost(w)
	w.window.panes[2] = { block = "plugin.terminal", cwd = "/", tab = 1 }
	w.click("plotroom://lens/show/https%3A%2F%2Fgit.example.com%2Fo%2Fr%2Fpull%2F45", 2)
	eq(w.toasts[#w.toasts].text, "Plotroom: malformed link", "refused")
	eq(#w.window.events, 0, "and no block is told anything")
end)

windowCase("window flows: the issue preview's Pull request row and the PR preview's Issue row are followed", function(w: World)
	w.load("window")
	flowHost(w)
	local layer: any = w.window.surfaces[1].layer.c
	local show = "plotroom://github/show/o/r/45"
	table.insert(layer, { id = "layer.queue.headpr", c = { { id = "layer.queue.headpr.hp1", p = { href = show } } } })
	w.click(show)
	eq(w.window.events[#w.window.events].ev.act, "show-pr", "the head pull request row shows the pull request")
	eq(w.window.events[#w.window.events].ev.value, "https://github.com/o/r/pull/45", "named by its page")
	local issue = "https://github.com/o/r/issues/12"
	local open = "plotroom://issue/open/https%3A%2F%2Fgithub.com%2Fo%2Fr%2Fissues%2F12"
	local said = #w.toasts
	w.window.opensBrowser = true
	w.click(open)
	eq(w.toasts[said + 1].text, "Plotroom: that issue is no longer listed", "an issue no row lists is refused")
	table.insert(layer, { id = "layer.queue.noted", c = { { id = "layer.queue.noted.issue1", p = { href = open } } } })
	w.click(open)
	same(w.window.browser, { { url = issue, how = "beside", beside = 1 } }, "the noted issue row opens the issue")
end)

windowCase("window status: one need-you count, the largest of the Plotroom blocks, redrawn only on change, hidden at zero, and a click shows Now in that block", function(w: World)
	w.load("window")
	flowHost(w)
	w.window.panes[2] = { block = "plugin.plotroom.prs", cwd = "/work/r", tab = 1 }
	flowHost(w, 2)
	local main: any = w.window.surfaces[1].main.c
	local other: any = w.window.surfaces[2].main.c
	local function texts(): { string }
		local out: { string } = {}
		for _, s in ((w.window.status :: any)({ pane = 7 }) or {}) do
			table.insert(out, s.text)
		end
		return out
	end
	table.insert(main, { id = "main.need", p = { text = "0", hidden = true } })
	table.insert(other, { id = "main.need", p = { text = "0", hidden = true } })
	w.window.handlers.window_start(w.cx)
	same(texts(), {}, "nothing at zero")
	local before = w.window.refreshes
	main[#main].p.text = "2"
	other[#other].p.text = "3"
	w.advance(4000)
	same(texts(), { "3 need you" }, "the largest count shows on every pane: blocks of one host list the same Now")
	eq(((w.window.status :: any)({ pane = 7 }))[1].command, "plugin.plotroom.now", "a click runs the Now command")
	eq(w.window.refreshes, before + 1, "redrawn once")
	w.advance(8000)
	eq(w.window.refreshes, before + 1, "and not again while it stays")
	w.window.focused = 7
	w.command("now")
	eq(w.window.focused, 2, "the command focuses the block whose count shows")
	same(w.window.events[#w.window.events], { pane = 2, ev = { ev = "action", act = "open-now" } }, "and tells it to show Now")
	main[#main].p.text = "0"
	other[#other].p.text = "0"
	w.advance(4000)
	same(texts(), {}, "hidden again at zero")
end)

windowCase("window tabs: a worktree's tab is titled after its item, unless the user renamed it", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local link = h.prLink("worktree", "o/r", 5)
	st.link("layer.queue.buttons.worktree", link)
	w.click(link)
	w.flush()
	st.reply("worktree", { path = "/wt/pr5", summary = "ready", created = false, current = true, title = "Fix the thing" })
	w.flush()
	local title: any = w.window.tabTitle
	eq(title({ cwd = "/wt/pr5/src" }), "#5 Fix the thing", "a tab working in the worktree")
	eq(title({ cwd = "/wt/pr5", name = "PR #5 · r" }), "#5 Fix the thing", "its own automatic name is replaced")
	eq(title({ cwd = "/wt/pr5", name = "mine" }), nil, "a name the user chose stays")
	eq(title({ cwd = "/wt/other" }), nil, "another directory keeps the default")
end)

case("host worktrees board: opening the list again reads git again, and a worktree whose folder is gone is not opened", function(w: World)
	local s = asks.hx.boardScene(w)
	local b = openQueue(w)
	pickScope(b, "worktrees")
	w.flush()
	eq(table.find(asks.hx.board(b), "o/r/newb"), nil, "the board does not list a worktree git has not got yet")
	asks.bk.tree(w, s.git, "/wt/newb", "newb") -- made outside the board, as removing and making worktrees is
	pickScope(b, "prs:v1")
	pickScope(b, "worktrees")
	w.flush()
	yes(table.find(asks.hx.board(b), "o/r/newb") ~= nil, "opening it again shows what git lists now")
	w.fs.dirs["/wt/pr5"] = nil
	has(asks.hx.ask(w, b, { op = "worktree-path", n = 1 }).problem, "no longer listed", "a row whose folder is gone is not opened")
	has(asks.hx.ask(w, b, { op = "git-path" }).problem, "no longer there", "nor is it opened in Git")
end)

case("host mutations: a confirmation older than five minutes says it expired", function(w: World)
	local s = issueHost(w)
	local seen = asks.hx.writes(s.gh, issueViews({ ["12"] = "OPEN" }))
	local b = openIssues(w)
	local p = asks.hx.ask(w, b, { op = "act", name = "issue-close" })
	local before = #seen
	w.advance(301 * 1000)
	eq(asks.hx.ask(w, b, { op = "commit", token = p.token }).problem, "That confirmation expired after 5 minutes; nothing was sent.", "the age is named, not a changed selection")
	eq(#seen, before, "and nothing was sent")
end)

-- Starts Implement (p1, checked by p4, next `next`) on issue o/r#12 in its worktree; the host reads its acceptance
-- criteria as `criteria`. Returns the builder's link.
local function startChecked(w: World, st: FlowStub, criteria: string, next: string?): any
	st.link("layer.queue.buttons.agent", "plotroom://issue/agent/o/r/12")
	st.palette({ items = { { id = "p1", label = "Implement" } } })
	w.window.choose = if #w.window.agents > 0 then { "Start another agent", "Implement" } else "Implement"
	w.click("plotroom://issue/agent/o/r/12")
	w.flush()
	st.reply("menu", { items = { { id = "p1", label = "Implement", send = "Do {url}", worktree = true, checker = "p4", next = next } } })
	st.reply("issue", { path = "/wt/i12", summary = "Created", created = true, current = true, vars = { url = "https://github.com/o/r/issues/12", title = "Fix login", branch = "12-fix" }, code = "o/r" })
	local asked = st.reply("criteria", { criteria = criteria })
	eq(asked.repo .. "#" .. asked.ref, "o/r#12", "the criteria are read from the issue at dispatch")
	return (w.kv.get("agent-links") :: any)[1]
end

-- The builder `link` ends its turn with a report naming `commit` (nil: none) and attention `attention` (default ok).
local function builderEnds(w: World, link: any, commit: string?, attention: string?)
	local named = if commit then `"{commit}"` else "null"
	reports(w, link.agent, `\{"attention": "{attention or "ok"}", "reason": "Ready to ship", "commit": {named}, "pr": null, "evidence": [], "blocker": null}`)
	agentFinished(w, link.agent, "done")
end

-- The builder `link` ends its turn with a report naming `commit`; the host answers the checker action Check and its
-- worktree. Returns the checker's link.
local function builderCommits(w: World, st: FlowStub, link: any, commit: string): any
	builderEnds(w, link, commit, "needs-human")
	local asked = st.reply("action", { label = "Check", send = "Check {key} on {branch}\n\n{criteria}", worktree = true })
	eq(asked.pid, "p4", "the host is asked for the checker action")
	local prepared = st.reply("issue", { path = "/wt/i12", summary = "Reused", created = false, current = true, vars = { key = "12", branch = "12-fix" }, code = "o/r" })
	eq(prepared.target, "o/r", "on the same item, in the repository the run was worked in")
	return (w.kv.get("agent-links") :: any)[1]
end

-- The checker `link` ends its turn with verdict `check` (nil: none given) and `findings`.
local function checkSays(w: World, link: any, check: string?, findings: { string }?)
	local verdict = if check then `, "check": "{check}"` else ""
	reports(w, link.agent, `\{"attention": "ok", "reason": "Checked", "commit": null, "pr": null, "evidence": [], "blocker": null{verdict}, "findings": {jsonEncode(array(findings or {}))}}`)
	agentFinished(w, link.agent, "done")
end

-- The host answers a fix round's request for the builder action Implement (checked by p4, next `next`) and its worktree;
-- returns the fix round's link.
local function fixRound(w: World, st: FlowStub, next: string?): any
	local asked = st.reply("action", { label = "Implement", send = "Do {url}", worktree = true, checker = "p4", next = next })
	eq(asked.pid, "p1", "a fix round asks for the builder's own action")
	st.reply("issue", { path = "/wt/i12", summary = "Reused", created = false, current = true, vars = { url = "https://github.com/o/r/issues/12", branch = "12-fix" }, code = "o/r" })
	return (w.kv.get("agent-links") :: any)[1]
end

-- The builder's run (not its checker's) that started at `started`.
local function runAt(w: World, started: number): any
	for _, r in w.kv.get("runs") :: any do
		if r.started == started and not r.checking then
			return r
		end
	end
	return nil
end

windowCase("window flows: a run that ends with a commit starts its checker as a fresh agent on the same item, with the criteria saved at dispatch", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local builder = startChecked(w, st, "- [ ] Login works\n- [ ] Errors say why")
	local prompt: string = w.window.agents[1].prompt
	has(prompt, "Do https://github.com/o/r/issues/12", "the builder's prompt")
	has(prompt, "<criteria>", "gets the criteria block, added since its text names none")
	has(prompt, "- [ ] Login works\n- [ ] Errors say why", "with the saved criteria")
	eq(builder.criteria, "- [ ] Login works\n- [ ] Errors say why", "which are saved on the run")
	eq(builder.chain.checker, "p4", "and the link knows its checker")
	local commit = sha("c")
	builderEnds(w, builder, nil, "needs-human")
	eq(countOps(st, "action"), 0, "a turn with no commit that asks for you starts no check and no fix round")
	eq((w.kv.get("agent-links") :: any)[1].gate, "held", "the chain waits for you")
	local checker = builderCommits(w, st, builder, commit)
	eq(countOps(st, "criteria"), 1, "the checker gets the run's snapshot: the issue is not read again")
	eq(#w.window.agents, 2, "a second agent started")
	yes(checker.agent ~= builder.agent, "a new agent, never the builder's pane")
	eq(w.window.panes[checker.agent].tab, w.window.panes[builder.agent].tab, "in the builder's tab")
	local cp: string = w.window.agents[2].prompt
	has(cp, "Check 12 on 12-fix", "the checker action's text")
	has(cp, "- [ ] Login works\n- [ ] Errors say why", "with the same criteria")
	has(cp, "<plotroom-check>", "and the fixed check contract")
	has(cp, "the run of Implement that ended at commit " .. commit, "naming the run and its commit")
	eq(w.window.agents[2].report, true, "the end-of-run contract still comes last")
	same({ checker.checkAgent, checker.checkStarted, checker.criteria }, { builder.agent, builder.started, builder.criteria } :: { any }, "the checker's link names the run it checks and keeps its criteria")
	eq(checker.chain.checker, nil, "a check has no checker of its own")
	eq(checker.chain.depth, 1, "and is a step of the chain")
	agentFinished(w, builder.agent, "done")
	eq(countOps(st, "action"), 1, "another turn ending at the same commit starts no second check")
	reports(w, checker.agent, `\{"attention": "ok", "reason": "Checked", "commit": "{sha("d")}", "pr": null, "evidence": [], "blocker": null, "check": "pass", "findings": []}`)
	agentFinished(w, checker.agent, "done")
	eq(countOps(st, "action"), 1, "a passing check of an action with no next action starts nothing")
end)

windowCase("window flows: a seed Fix on a Jira issue that committed and stops at its Ship ask waits for you, then goes on to Check and Watch; a report naming no commit still starts a fix round", function(w: World)
	w.load("window")
	local fix: any = (w.load("prompts") :: any).issues[2]
	eq(fix.name, "Fix", "the issue defaults' Fix")
	same({ fix.checker, fix.next }, { "p4", "prs:p4" } :: { any }, "is checked by Check, then leads into Watch")
	local st = flowHost(w)
	local function start(): any
		st.link("layer.queue.buttons.agent", "plotroom://issue/agent/ABC/ABC-12")
		st.palette({ items = { { id = "p2", label = "Fix" } } })
		w.window.choose = if #w.window.agents > 0 then { "Start another agent", "Fix" } else "Fix"
		w.click("plotroom://issue/agent/ABC/ABC-12")
		w.flush()
		st.reply("menu", { items = { { id = "p2", label = "Fix", send = "Fix {key}", worktree = true, checker = fix.checker, next = fix.next } } })
		st.reply("issue", { path = "/wt/abc12", summary = "Created", created = true, current = true, vars = { key = "ABC-12", branch = "ABC-12-login" }, code = "o/r" })
		st.reply("criteria", { criteria = "AC1 login works" })
		return (w.kv.get("agent-links") :: any)[1]
	end
	local builder = start()
	eq(builder.key, "abc#ABC-12", "a Jira issue's run")
	-- The turn ends at the Ship ask: the agent's last message is the ask, with no report yet.
	lastSays(w, builder.agent, "Fixed and pushed; draft PR opened. Which of these should I do?")
	w.window.agentStates[builder.agent] = "waiting_input"
	agentFinished(w, builder.agent, "done")
	eq(countOps(st, "action"), 0, "no fix round and no check starts")
	eq((w.kv.get("agent-links") :: any)[1].gate, "held", "the chain waits for you")
	-- A report that says ok with no commit, while the agent still shows its ask, waits too.
	reports(w, builder.agent, `\{"attention": "ok", "reason": "Asked what to ship", "commit": null, "pr": null, "evidence": [], "blocker": null}`)
	agentFinished(w, builder.agent, "done")
	eq(countOps(st, "action"), 0, "an agent waiting on its ask starts no fix round")
	eq((w.kv.get("agent-links") :: any)[1].gate, "held", "and still waits")
	-- You answer; the agent ships and ends with its report naming the commit it made.
	w.window.agentStates[builder.agent] = "idle"
	reports(w, builder.agent, `\{"attention": "ok", "reason": "Shipped", "commit": "{sha("c")}", "pr": "https://github.com/o/r/pull/45", "evidence": [], "blocker": null}`)
	agentFinished(w, builder.agent, "done")
	local asked = st.reply("action", { label = "Check", send = "Check {key}", worktree = true })
	eq(asked.pid, "p4", "Check starts for the commit")
	st.reply("issue", { path = "/wt/abc12", summary = "Reused", created = false, current = true, vars = { key = "ABC-12", branch = "ABC-12-login" }, code = "o/r" })
	local checker = (w.kv.get("agent-links") :: any)[1]
	has(w.window.agents[2].prompt, "ended at commit " .. sha("c"), "naming the commit")
	checkSays(w, checker, "pass")
	local next = st.reply("action", { label = "Watch", send = "Watch {url}", worktree = true, pr = 45 })
	same({ next.kind, next.pid, next.repo, next.branch }, { "pr", "p4", "o/r", "ABC-12-login" } :: { any }, "a passing check starts Watch on the branch's pull request")
	st.reply("worktree", { path = "/wt/abc12", summary = "Reused", created = false, current = true })
	eq(w.window.agents[3].prompt, "Watch https://github.com/o/r/pull/45", "which runs")
	eq(countOps(st, "action"), 2, "and no fix round ever started")
	-- A run whose report names no commit, with nothing waiting on you, still starts a fix round.
	local again = start()
	w.window.agentStates[again.agent] = "idle"
	reports(w, again.agent, `\{"attention": "ok", "reason": "Nothing to change", "commit": null, "pr": null, "evidence": [], "blocker": null}`)
	agentFinished(w, again.agent, "done")
	local round = st.reply("action", { label = "Fix", send = "Fix {key}", worktree = true, checker = "p4", next = "prs:p4" })
	eq(round.pid, "p2", "the fix round runs Fix again")
end)

windowCase("window flows: the default Check acts as the run's GitHub login and leaves the tree as it found it", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local builder = startChecked(w, st, "- [ ] Login works")
	builderEnds(w, builder, sha("c"), "needs-human")
	local check = (w.load("prompts") :: any).issues[4]
	eq(check.name, "Check", "the issue defaults' checker")
	st.reply("action", { label = "Check", send = check.text, worktree = true })
	local prepared = st.reply("issue", { path = "/wt/i12", summary = "Reused", created = false, current = true, vars = { key = "12", url = "https://github.com/o/r/issues/12", title = "Fix login", owner = "o", repo = "r", branch = "12-fix", base = "main", remote = "origin", ["github.user"] = "cat" }, code = "o/r" })
	eq(prepared.users, true, "the host is asked for the gh login the checker runs as")
	local cp: string = w.window.agents[2].prompt
	has(cp, "act only as @cat", "the checker acts as the run's login")
	has(cp, "`GH_TOKEN=$(gh auth token --user cat)`", "its gh and networked git commands use that login's token")
	has(cp, "Scratch files go in a temp dir outside the repo", "scratch files stay out of the builder's worktree")
	has(cp, "`git status --porcelain` clean, or what you left and why", "and the report says how the tree was left")
	lacks(cp, "{github.user}", "the login is filled in")
end)

windowCase("window flows: a passing check marks the checked run Checked; a failing one keeps its findings for the preview and Now", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local builder = startChecked(w, st, "- [ ] Login works")
	local checker = builderCommits(w, st, builder, sha("c"))
	reports(w, checker.agent, `\{"attention": "ok", "reason": "All met", "commit": null, "pr": null, "evidence": ["luau tests pass"], "blocker": null, "check": "PASS", "findings": []}`)
	agentFinished(w, checker.agent, "done")
	eq(runAt(w, builder.started).check, "pass", "the checked run is Checked")
	eq(runAt(w, builder.started).criteria, "- [ ] Login works", "and keeps its criteria")
	eq((w.kv.get("agent-links") :: any)[1].check, "pass", "the checker's link says it")
	w.advance(4100)
	local row: any = statusEvents(w)[#statusEvents(w)].map["o/r#12"]
	same({ row.check, row.findings }, { "pass" } :: { any }, "and the block is told: a pass, no findings")
	-- a run started again by hand is checked again, and this check fails
	local second = startChecked(w, st, "- [ ] Login works")
	local again = builderCommits(w, st, second, sha("e"))
	checkSays(w, again, "fail", { "Login works: no test covers a wrong password", "Errors say why: the toast is empty" })
	eq(runAt(w, second.started).check, "fail", "the run's check is a fail")
	same(runAt(w, second.started).findings, { "Login works: no test covers a wrong password", "Errors say why: the toast is empty" }, "with its findings")
	w.advance(4100)
	row = statusEvents(w)[#statusEvents(w)].map["o/r#12"]
	same({ row.check, row.findings }, { "fail", "Login works: no test covers a wrong password · Errors say why: the toast is empty" }, "the block gets the findings")
	-- a checker that gives no verdict fails: missing data never passes
	local fix = fixRound(w, st)
	local third = builderCommits(w, st, fix, sha("f"))
	checkSays(w, third, nil)
	local l: any = (w.kv.get("agent-links") :: any)[1]
	same({ l.check, l.findings }, { "fail", "The checker gave no pass or fail." }, "a report without a check is a fail, saying so")
end)

-- The run log's record of item `key`'s run that started at `started`.
local function loggedRun(w: World, key: string, started: number?): any
	for _, r in (w.kv.get("runs") or {}) :: any do
		if r.key == key and r.started == started then
			return r
		end
	end
	return nil
end

windowCase("window flows: Disagree with check… records a disagreement, with an optional one-line reason, on the run the checker checked, even once the checker exited", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local link = "plotroom://issue/agentdisagree/o/r/12"
	st.link("layer.queue.buttons.agentdisagree", link)
	local builder = startChecked(w, st, "- [ ] Login works")
	w.window.typed = "too strict"
	w.click(link)
	w.flush()
	has(w.toasts[#w.toasts].text, "No check to disagree with for o/r#12", "no verdict yet: nothing to disagree with")
	eq(loggedRun(w, "o/r#12", builder.started), nil, "and nothing is recorded")
	w.advance(60 * 1000) -- the builder's turn takes a minute: its checker starts later
	local checker = builderCommits(w, st, builder, sha("c"))
	reports(w, checker.agent, `\{"attention": "ok", "reason": "All met", "commit": null, "pr": null, "evidence": [], "blocker": null, "check": "pass", "findings": []}`)
	agentFinished(w, checker.agent, "done")
	local run = loggedRun(w, "o/r#12", builder.started)
	eq(type(run.checkedAt), "number", "the builder's run is a checked run from its verdict")
	eq(run.disagree, nil, "with no disagreement yet")
	eq(loggedRun(w, "o/r#12", checker.started).checkedAt, nil, "the checker's own run is no checked run")
	local checkerPane = w.window.panes[checker.agent]
	w.window.panes[checker.agent] = nil -- the checker exited
	w.advance(4100)
	same(statusEvents(w)[#statusEvents(w)].map["o/r#12"], { state = "exited", check = "pass" }, "an exited checker still tells the block its verdict, and nothing else")
	w.window.typed = nil
	w.click(link)
	w.flush()
	eq(loggedRun(w, "o/r#12", builder.started).disagree, nil, "Escape records nothing")
	w.window.typed = "  The criteria\nnever asked for that  "
	w.click(link)
	w.flush()
	eq(loggedRun(w, "o/r#12", builder.started).disagree, "The criteria never asked for that", "the reason, as one trimmed line")
	eq(w.toasts[#w.toasts].text, "Disagreement recorded for o/r#12", "and says so")
	w.window.typed = ""
	w.click(link)
	w.flush()
	eq(loggedRun(w, "o/r#12", builder.started).disagree, "", "a reason is optional: a second disagreement replaces the first")
	-- a new verdict on the same run (a later turn of its checker) is a new decision: the disagreement was about the
	-- earlier one
	w.window.panes[checker.agent] = checkerPane
	checkSays(w, checker, "fail", { "AC1" })
	eq(loggedRun(w, "o/r#12", builder.started).disagree, nil, "a new verdict drops the disagreement with the old one")
end)

windowCase("window flows: a Plotroom block opened after the checker exited is still told its verdict, so Disagree with check… is offered there", function(w: World)
	w.load("window")
	w.kv.put("agent-links", array({ { key = "o/r#12", agent = 9, host = { id = 1, name = "", address = "" }, at = 1, checkAgent = 9, check = "pass" } }))
	w.advance(4100)
	flowHost(w) -- a fresh block: it holds no agent map yet
	w.window.handlers.pane_created({ pane = 1 }, w.cx)
	w.advance(4100)
	local events = statusEvents(w)
	yes(#events > 0, "no agent is live, yet the new block is told")
	same(events[#events].map["o/r#12"], { state = "exited", check = "pass" }, "the exited checker's verdict, which offers Disagree with check…")
	local told = #events
	w.advance(8200)
	eq(#statusEvents(w), told, "once the block holds it, it is not told again")
end)

windowCase("window flows: an undecided checked run is asked whether its work merged, as its login, and counts as agreed once it did", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local now = EPOCH
	local day = 86400
	w.kv.put(
		"runs",
		array({
			{ key = "o/r#12", action = "Implement", result = "done", started = now - 900, ended = now - 600, check = "pass", checkedAt = now - 300, login = "cat", ghRepo = "o/r", branch = "12-fix" },
			{ key = "o/r#5", action = "Fix", result = "done", started = now - 900, ended = now - 600, check = "fail", checkedAt = now - 300, disagree = "", login = "cat", ghRepo = "o/r", number = 5 },
			{ key = "o/r#6", action = "Fix", result = "done", started = now - 9 * day, ended = now - 8 * day, check = "pass", checkedAt = now - 8 * day, login = "cat", ghRepo = "o/r", number = 6 },
			{ key = "o/r#7", action = "Fix", result = "done", started = now - 900, ended = now - 600, check = "pass", checkedAt = now - 300 },
			{ key = "o/r#8", action = "Check", result = "done", started = now - 500, ended = now - 400, check = "pass", login = "cat", ghRepo = "o/r", number = 8 },
		})
	)
	w.advance(4100)
	local asked = outcomeAsks(w)
	eq(#asked, 1, "only the undecided checked run that names its work is asked: a disagreement or a week-old verdict is decided, and a checker's own run is no checked run")
	same({ asked[1].outcome, asked[1].repo, asked[1].branch, asked[1].login, asked[1].since }, { "merged", "o/r", "12-fix", "cat", 0 } :: { any }, "Merged, on the run's branch, as its login")
	eq(asked[1].number, nil, "an issue's run names no pull request")
	st.reply("outcome", { verdict = "not" })
	w.advance(60 * 1000)
	eq(#outcomeAsks(w), 1, "not merged: not asked again within ten minutes")
	w.advance(600 * 1000)
	eq(#outcomeAsks(w), 2, "asked again at the next sweep")
	st.reply("outcome", { verdict = "verified" })
	eq(loggedRun(w, "o/r#12", now - 900).merged, true, "its work merged")
	w.advance(600 * 1000)
	eq(#outcomeAsks(w), 2, "a decided run is never asked again")
	w.window.focused = 1
	w.command("usage-report")
	local text = w.copied[#w.copied]
	has(text, "Checked runs 4 · disagreements 1 · undecided 1", "the checked runs: merged, disagreed, a week old and one still undecided")
	has(text, "Agreement 66% (2 of the last 3 decided runs) · Autopilot gate 80% over 20 decided runs · not met", "agreement over the decided runs, beside the gate")
end)

windowCase("window flows: a merge-sweep ask still in flight is not sent twice, and one never answered is asked again at the next sweep", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local now = EPOCH
	w.kv.put("runs", array({ { key = "o/r#12", action = "Implement", result = "done", started = now - 900, ended = now - 600, check = "pass", checkedAt = now - 300, login = "cat", ghRepo = "o/r", number = 12 } }))
	w.advance(4100)
	eq(#outcomeAsks(w), 1, "the first sweep asks")
	w.advance(80 * 1000)
	eq(#outcomeAsks(w), 1, "while that ask is in flight, later ticks send no second ask")
	w.advance(600 * 1000)
	local asked = outcomeAsks(w)
	eq(#asked, 2, "the ask went unanswered past its timeout: the next sweep asks again")
	same({ asked[2].outcome, asked[2].repo, asked[2].number, asked[2].login }, { "merged", "o/r", 12, "cat" } :: { any }, "the same run, Merged, as its login")
	st.reply("outcome", { verdict = "not" }) -- the first ask's answer, too late: dropped
	st.reply("outcome", { verdict = "verified" })
	eq(loggedRun(w, "o/r#12", now - 900).merged, true, "the second ask's answer marks its work merged")
end)

case("usage: a checked run is agreed once merged or a week after its verdict, disagreed once you said so; agreement is over the last 20 decided runs, beside the Autopilot gate", function(w: World)
	local usage: any = w.load("usage")
	local now = EPOCH
	local week = 7 * 86400
	eq(usage.agreement({ checkedAt = now - week + 1 }, now), nil, "undecided a second before the week is out")
	eq(usage.agreement({ checkedAt = now - week }, now), "agreed", "agreed once it is")
	eq(usage.agreement({ checkedAt = now - 60, merged = true }, now), "agreed", "or once its work merged")
	eq(usage.agreement({ checkedAt = now - 2 * week, merged = true, disagree = "" }, now), "disagreed", "a disagreement wins over both")
	eq(usage.agreement({ check = "pass" }, now), nil, "a run with no recorded verdict is no checked run")
	local function report(runs: { any }): string
		return usage.report({ host = { value = { since = 0, counts = {} } }, here = { value = { since = 0, counts = {} } }, runs = { value = runs }, name = function(id: string): string
			return id
		end, outcome = function(): string?
			return nil
		end })
	end
	local function checked(n: number, fields: { [string]: any }): any
		local r: any = { key = "o/r#" .. n, action = "Implement", result = "done", ended = now - n, check = "pass", checkedAt = now - 60 }
		for k, v in fields do
			r[k] = v
		end
		return r
	end
	local runs: { any } = { checked(1, {}), { key = "o/r#2", action = "Check", result = "done", ended = now, check = "pass" } } -- undecided, and a checker's own run
	table.insert(runs, checked(3, { disagree = "too strict" }))
	table.insert(runs, checked(4, { disagree = "", merged = true }))
	for i = 5, 21 do
		table.insert(runs, checked(i, if i % 2 == 0 then { merged = true } else { checkedAt = now - week }))
	end
	for i = 22, 26 do
		table.insert(runs, checked(i, { disagree = "" }))
	end
	local text = report(runs)
	has(text, "Checked runs 25 · disagreements 7 · undecided 1", "every checked run, every disagreement and those still undecided")
	has(text, "Agreement 85% (17 of the last 20 decided runs) · Autopilot gate 80% over 20 decided runs · met", "the newest 20 decided runs: 17 agreed and 3 disagreed, older ones left out")
	for _ = 22, 26 do
		table.remove(runs) -- the older disagreements: 19 decided runs are left
	end
	text = report(runs)
	has(text, "Agreement 89% (17 of the last 19 decided runs) · Autopilot gate 80% over 20 decided runs · not met", "fewer than 20 decided runs never meet the gate")
	has(report({}), "Agreement unknown: no decided runs yet", "with none decided, agreement is unknown")
end)

windowCase("window flows: a failed check starts the builder's action again with the findings as {findings} and the same criteria; a passing one then starts the next action", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local builder = startChecked(w, st, "- [ ] Login works", "p3")
	local checker = builderCommits(w, st, builder, sha("c"))
	eq(countOps(st, "action"), 1, "while the check runs, the next action waits")
	checkSays(w, checker, "fail", { "Login works: no test covers a wrong password" })
	local fix = fixRound(w, st, "p3")
	eq(#w.window.agents, 3, "a fresh agent runs the fix round")
	local fp: string = w.window.agents[3].prompt
	has(fp, "Do https://github.com/o/r/issues/12", "the builder action's own text")
	has(fp, "<findings>", "with the findings block, added since its text names none")
	has(fp, "- Login works: no test covers a wrong password", "holding the checker's findings")
	has(fp, "- [ ] Login works", "and the criteria saved at dispatch")
	eq(countOps(st, "criteria"), 1, "which are not read again")
	same({ fix.chain.action, fix.chain.depth, fix.criteria }, { "p1", 2, "- [ ] Login works" } :: { any }, "the same action, two steps on (after the check), with the same criteria")
	eq(w.window.panes[fix.agent].tab, w.window.panes[builder.agent].tab, "in the builder's tab")
	local check2 = builderCommits(w, st, fix, sha("d"))
	checkSays(w, check2, "pass")
	local asked = st.reply("action", { label = "Ship", send = "Ship {url}", worktree = true })
	eq(asked.pid, "p3", "a passing check starts the next action")
	st.reply("issue", { path = "/wt/i12", summary = "Reused", created = false, current = true, vars = { url = "https://github.com/o/r/issues/12", branch = "12-fix" }, code = "o/r" })
	eq(w.window.agents[#w.window.agents].prompt, "Ship https://github.com/o/r/issues/12", "which runs")
	lacks(w.window.agents[#w.window.agents].prompt, "<findings>", "a next action is no fix round")
end)

windowCase("window flows: a fix round of the seed Implement or Fix reads its findings before the workflow, which builds on the last round's commits without asking", function(w: World)
	w.load("window")
	local prompts: any = w.load("prompts")
	local st = flowHost(w)
	local run = startChecked(w, st, "- [ ] Login works")
	for round, seed in { prompts.issues[1], prompts.issues[2] } do
		local checker = builderCommits(w, st, run, sha(tostring(round)))
		checkSays(w, checker, "fail", { "Login works: round " .. round .. " has no wrong-password test" })
		st.reply("action", { label = seed.name, send = seed.text, worktree = true, checker = "p4" })
		st.reply("issue", { path = "/wt/i12", summary = "Reused", created = false, current = true, vars = { url = "https://github.com/o/r/issues/12", branch = "12-fix" }, code = "o/r" })
		run = (w.kv.get("agent-links") :: any)[1]
		local p: string = w.window.agents[#w.window.agents].prompt
		local findings = string.find(p, "- Login works: round " .. round .. " has no wrong-password test", 1, true)
		local criteria, workflow = string.find(p, "- [ ] Login works", 1, true), string.find(p, "<workflow>", 1, true)
		local rule = string.find(p, "<findings> lists findings → this is a fix round: build on the existing commits without asking", 1, true)
		local ask = string.find(p, "Commits beyond base with no PR → ask", 1, true)
		yes(criteria and findings and workflow and rule and ask, seed.name .. ": the criteria, the findings and both preflight rules are in the prompt")
		yes((criteria :: number) < (findings :: number) and (findings :: number) < (workflow :: number), seed.name .. ": the findings follow the criteria, before the workflow")
		yes((rule :: number) < (ask :: number), seed.name .. ": the fix-round rule comes before the ask about commits beyond base")
		local _, blocks = string.gsub(p, "<findings>\n", "")
		eq(blocks, 1, seed.name .. ": one findings block, not one more appended at the end")
	end
end)

windowCase("window flows: after 3 failed checks on an item the chain stops at Needs you with 3 failed checks", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local run = startChecked(w, st, "- [ ] Login works")
	for i = 1, 3 do
		local checker = builderCommits(w, st, run, sha(tostring(i)))
		checkSays(w, checker, "fail", { "AC1 unmet, round " .. i })
		if i < 3 then
			run = fixRound(w, st)
		end
	end
	eq(countOps(st, "action"), 5, "three checks and two fix rounds, no third round")
	eq(w.toasts[#w.toasts].text, "Chain stopped for o/r#12", "the toast names the item")
	eq(w.toasts[#w.toasts].sub, "3 failed checks", "and the limit")
	local links: any = w.kv.get("agent-links")
	eq(links[1].stop, "3 failed checks", "the item's newest link says why, for Now")
	w.advance(4100)
	eq(statusEvents(w)[#statusEvents(w)].map["o/r#12"].stop, "3 failed checks", "and the block is told")
	w.advance(120 * 1000)
	eq(countOps(st, "action"), 5, "nothing starts later either")
end)

windowCase("window flows: 3 runs in a row with no new commit stop the chain with 3 runs without progress; a run with no new commit is not checked again", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local builder = startChecked(w, st, "- [ ] Login works")
	local checker = builderCommits(w, st, builder, sha("c"))
	checkSays(w, checker, "fail", { "AC1 unmet" })
	local run = fixRound(w, st)
	for i = 1, 3 do
		builderEnds(w, run, sha("c")) -- the commit the checked run already named
		eq(countOps(st, "criteria"), 1, "nothing is read for it")
		if i < 3 then
			run = fixRound(w, st)
			has(w.window.agents[#w.window.agents].prompt, "no new commit", "the next round is told the last one named no new commit")
			has(w.window.agents[#w.window.agents].prompt, "AC1 unmet", "and the last check's findings")
		end
	end
	eq(countOps(st, "action"), 4, "one check, three fix rounds, and no fourth round")
	eq(w.toasts[#w.toasts].sub, "3 runs without progress", "the chain stops for no progress")
	eq((w.kv.get("agent-links") :: any)[1].stop, "3 runs without progress", "at Needs you")
	local runs: any = w.kv.get("runs")
	same({ runs[1].depth, runs[2].depth, runs[3].depth }, { 6, 4, 2 } :: { any }, "the counters come from the item's runs in the run log")
end)

windowCase("window flows: 3 failed starts stop the chain with 3 failed starts, each tried again after a wait", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local first = startChained(w, st)
	agentFinished(w, first.agent, "done")
	st.reply("outcome", { verdict = "verified" })
	st.reply("action", { problem = "The block's host is busy." })
	eq(w.toasts[#w.toasts].sub, "The block's host is busy.", "a failed start says why")
	w.advance(10 * 1000)
	eq(countOps(st, "action"), 1, "and is not tried again at once")
	w.advance(25 * 1000)
	eq(countOps(st, "action"), 2, "but after a wait")
	st.reply("action", { label = "Fix", send = "Fix {url}", worktree = true })
	st.reply("worktree", { problem = "git worktree add failed" })
	w.advance(35 * 1000)
	eq(countOps(st, "action"), 3, "a worktree that fails counts as a failed start too")
	w.cx.agents.start = function(_self: any, _opts: any): number
		error("no agent program", 0)
	end
	st.reply("action", { label = "Fix", send = "Fix {url}", worktree = true })
	st.reply("worktree", { path = "/wt/r5", summary = "Reused", created = false, current = true })
	eq(runAt(w, first.started).starts, 3, "three failed starts are on the run")
	w.advance(35 * 1000)
	eq(countOps(st, "action"), 3, "no fourth try")
	eq(w.toasts[#w.toasts].text, "Chain stopped for o/r#5", "the chain stops")
	eq(w.toasts[#w.toasts].sub, "3 failed starts", "for its failed starts")
	eq((w.kv.get("agent-links") :: any)[1].stop, "3 failed starts", "at Needs you")
end)

windowCase("window flows: starting an action by hand resets the counters and ends the item's open steps", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local run = startChecked(w, st, "- [ ] Login works")
	for i = 1, 2 do
		checkSays(w, builderCommits(w, st, run, sha(tostring(i))), "fail", { "AC1" })
		run = fixRound(w, st)
	end
	-- the third round ends with a commit, and while its check is being started the user starts Implement by hand
	builderEnds(w, run, sha("3"))
	eq((w.kv.get("agent-links") :: any)[1].gate, "check", "a check is due")
	local hand = startChecked(w, st, "- [ ] Login works")
	local links: any = w.kv.get("agent-links")
	eq(links[2].gate, "over", "the hand start ended the open step")
	local agents = #w.window.agents
	st.reply("action", { label = "Check", send = "Check {key}", worktree = true })
	st.reply("issue", { path = "/wt/i12", summary = "Reused", created = false, current = true, vars = { key = "12" }, code = "o/r" })
	eq(#w.window.agents, agents, "the check already on its way starts no agent")
	local checks = countOps(st, "action")
	checkSays(w, builderCommits(w, st, hand, sha("4")), "fail", { "AC1" })
	eq(countOps(st, "action"), checks + 2, "its own check failed once and a fix round starts: the counters began again")
	eq(runAt(w, hand.started).depth, 0, "the run started by hand is where the counting starts")
end)

windowCase("window flows: a plugin reload mid-chain resumes the due step from the stored chain, without a duplicate agent", function(w: World)
	w.load("window")
	local st = flowHost(w)
	local first = startChained(w, st)
	agentFinished(w, first.agent, "done")
	st.reply("outcome", { verdict = "verified" })
	eq(countOps(st, "action"), 1, "the next action's start began")
	w.advance(1000) -- request ids carry the clock, so the reloaded plugin's never repeat the old one's
	w.reload("window") -- before the host answered: the request dies with the old VM
	w.flush()
	eq(countOps(st, "action"), 2, "the reloaded plugin starts the step again from kv")
	pcall(st.reply, "action", { label = "Fix", send = "Fix {url}", worktree = true }) -- the dead request's answer finds no one
	eq(#w.window.agents, 1, "the old request starts nothing")
	st.reply("action", { label = "Fix", send = "Fix {url}", worktree = true })
	st.reply("worktree", { path = "/wt/r5", summary = "Reused", created = false, current = true })
	eq(#w.window.agents, 2, "the next agent started once")
	w.reload("window")
	w.flush()
	w.advance(60 * 1000)
	eq(countOps(st, "action"), 2, "a reload after it started starts nothing more")
	eq(#w.window.agents, 2, "no duplicate agent")
end)

-- Starts o/r#5's chained next action, failing the agent-links store (`fail`: the kv's failGet or failSet) from the
-- moment its agent starts until it is recorded; returns that agent's pane.
local function startUnlinked(w: World, st: FlowStub, fail: { [string]: string }): number
	local first = startChained(w, st)
	agentFinished(w, first.agent, "done")
	st.reply("outcome", { verdict = "verified" })
	local start, pane = w.cx.agents.start, 0
	w.cx.agents.start = function(self: any, opts: any): number
		fail["agent-links"] = "store broken"
		pane = start(self, opts)
		return pane
	end
	st.reply("action", { label = "Fix", send = "Fix {url}", worktree = true })
	st.reply("worktree", { path = "/wt/r5", summary = "Reused", created = false, current = true })
	fail["agent-links"] = nil
	w.cx.agents.start = start
	eq(#w.window.agents, 2, "the step's agent started")
	return pane
end

for _, t in { { "saved", "failSet", "The agent links could not be saved." }, { "read", "failGet", "The saved agent links could not be read." } } do
	windowCase("window flows: a chain step's agent whose links cannot be " .. t[1] .. " is not started again while it runs, nor counted a failed start", function(w: World)
		w.load("window")
		local st = flowHost(w)
		local pane = startUnlinked(w, st, (w.kv :: any)[t[2]])
		local subs: { string } = {}
		for _, toast in w.toasts do
			table.insert(subs, toast.sub or "")
		end
		has(table.concat(subs, "\n"), t[3], "the start says it is not linked")
		w.advance(60 * 1000)
		eq(countOps(st, "action"), 1, "the next tick starts no second agent for the step")
		w.advance(13 * 60 * 1000)
		eq(countOps(st, "action"), 1, "nor does one past the start's time limit")
		eq(#w.window.agents, 2, "one agent for the step")
		eq(runAt(w, (w.kv.get("agent-links") :: any)[1].started).starts or 0, 0, "and no failed start is counted")
		w.window.agentStates[pane] = "exited"
		w.advance(5 * 1000)
		eq(countOps(st, "action"), 2, "once that agent exited, the step it never ended is due again")
	end)
end

case("host agents: a passing check shows Checked; a failing one is Needs you with its findings in the preview", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	local function badges(id: string): string
		for _, row in pickerOf(b).items do
			if row.id == id then
				local out: { string } = {}
				for _, badge in row.badges or {} do
					table.insert(out, badge.text)
				end
				return table.concat(out, ",")
			end
		end
		return ""
	end
	asks.hx.agents(b, {
		["o/r#1"] = { state = "idle", action = "Check", check = "fail", findings = "AC1: no test · AC2: empty toast" },
		["o/r#2"] = { state = "idle", action = "Check", check = "pass" },
		["o/r#3"] = { state = "working", action = "Check", check = "fail", findings = "AC1" },
	})
	eq(asks.hx.stage(b, "no_2fr_231"), "Needs you", "a failed check is Needs you")
	has(badges("no_2fr_231"), "Check failed", "and its row says Check failed")
	eq(asks.hx.stage(b, "no_2fr_232"), "PR open", "a pass leaves the stage to GitHub")
	has(badges("no_2fr_232"), "Checked", "and its row says Checked")
	eq(asks.hx.stage(b, "no_2fr_233"), "Agent working", "a working agent does not need you")
	b.event({ ev = "select", id = "layer.queue", item = "no_2fr_231" })
	eq(h.factOf(b, "Check"), "Check failed", "the preview says the check failed")
	eq(h.factOf(b, "Findings"), "AC1: no test · AC2: empty toast", "with its findings")
	pickScope(b, "agents")
	w.flush()
	has(badges("go_2fr_232"), "Checked", "the Agents row says it")
end)

case("host agents: Disagree with check… is a Commands row and hidden link only while the selected item's checker has a verdict, exited or not, and opens the window's link", function(w: World)
	hostScene(w, 3)
	local b = openQueue(w)
	local function offered(): boolean
		return table.find(hx.palette(w, b).ids, "agentdisagree") ~= nil
	end
	asks.hx.agents(b, { ["o/r#1"] = { state = "idle", action = "Implement" } })
	yes(not offered(), "an agent with no check: no row")
	eq(findKey(pickerNode(b), "agentdisagree"), nil, "nor hidden link")
	asks.hx.agents(b, { ["o/r#1"] = { state = "idle", action = "Check", check = "pass" } })
	local p = hx.palette(w, b)
	eq(p.labels.agentdisagree, "Disagree with check…", "a checker with a verdict: the row, named so")
	eq(p.groups.agentdisagree, "Actions", "in the Actions group")
	asks.hx.agents(b, { ["o/r#1"] = { state = "exited", check = "fail" } })
	yes(offered(), "still offered once the checker exited")
	eq(findKey(pickerNode(b), "agentdisagree").p.href, prLink("agentdisagree", "o/r", 1), "the hidden link the window checks")
	b.event({ ev = "action", act = "queue", value = "agentdisagree" })
	eq(w.opened[#w.opened], prLink("agentdisagree", "o/r", 1), "the pick opens the selected item's link")
	b.typeText("j")
	local opened = #w.opened
	yes(not offered(), "another item with no check: no row")
	b.event({ ev = "action", act = "queue", value = "agentdisagree" })
	eq(#w.opened, opened, "and the action opens nothing")
end)

case("host criteria: the block reads an issue's acceptance criteria from GitHub's task list or Jira's section, and says why when it cannot", function(w: World)
	local s = issueHost(w)
	s.gh.issueDetail["o/r#12"] = { body = "Login fails.\n\n- [ ] Login works\n- [x] Logout works\n\nThanks", linked = array({}) }
	local b = openIssues(w)
	eq(asks.hx.ask(w, b, { op = "criteria", repo = "o/r", ref = "12" }).criteria, "- [ ] Login works\n- [x] Logout works", "GitHub: the task-list lines")
	s.gh.issueDetail["o/r#12"] = { body = "Just fix it.", linked = array({}) }
	eq(asks.hx.ask(w, b, { op = "criteria", repo = "o/r", ref = "12" }).criteria, "Just fix it.", "no task list: the whole description")
	has(asks.hx.ask(w, b, { op = "criteria", repo = "o/r", ref = "99" }).problem, "not loaded", "an issue not loaded here is refused")
end)

case("host criteria: a Jira issue's criteria are its description's Acceptance criteria section", function(w: World)
	local s = jiraHost(w)
	local function text(t: string): any
		return { type = "text", text = t }
	end
	s.acli.views["ABC-12"] = {
		key = "ABC-12",
		fields = {
			description = {
				type = "doc",
				version = 1,
				content = array({
					{ type = "paragraph", content = array({ text("Login fails on Safari.") }) },
					{ type = "heading", attrs = { level = 2 }, content = array({ text("Acceptance criteria") }) },
					{ type = "bulletList", content = array({ { type = "listItem", content = array({ { type = "paragraph", content = array({ text("AC1 login works") }) } }) } }) },
					{ type = "heading", attrs = { level = 2 }, content = array({ text("Notes") }) },
					{ type = "paragraph", content = array({ text("Seen since 2.3") }) },
				}),
			},
		},
	}
	local b = openIssues(w)
	local got: string = asks.hx.ask(w, b, { op = "criteria", repo = "ABC", ref = "ABC-12" }).criteria
	has(got, "AC1 login works", "the section's items")
	lacks(got, "Safari", "not the text before it")
	lacks(got, "Seen since", "nor the next section")
end)

return {}
