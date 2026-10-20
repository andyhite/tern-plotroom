--!strict
-- Regression cases: window module.

local h = require("../harness")
local asks = h.asks

type Worktree = h.Worktree
type World = h.World

local agentScene, answerOf, array, badgeOf, cardOf, cardSurface = h.agentScene, h.answerOf, h.array, h.badgeOf, h.cardOf, h.cardSurface
local cardText, commandsOf, countLog, eq, findKey, has = h.cardText, h.commandsOf, h.countLog, h.eq, h.findKey, h.has
local jsonEncode, lacks, linkQueue, listPr, prLink, prefsOf = h.jsonEncode, h.lacks, h.linkQueue, h.listPr, h.prLink, h.prefsOf
local pressCard, promptOf, promptPicks, request, requestsSent, runLink = h.pressCard, h.promptOf, h.promptPicks, h.request, h.requestsSent, h.runLink
local same, savePrompts, scene, sha, windowCase, yes = h.same, h.savePrompts, h.scene, h.sha, h.windowCase, h.yes

windowCase("window: the Add repository picker offers the saved repositories and each gh login, whose repositories it lists next; a pick or a typed one is saved and its checkout row opens", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	s.gh.tokens.octocat = "tok-octo"
	s.gh.tokens.work = "tok-work"
	s.gh.repos.work = { "z/z", "o/r" }
	local b = linkQueue(w, s)
	w.window.choose = { "@work", "z/z" }
	w.click("plotroom://repos")
	w.flush()
	local function labels(i: number): { string }
		local out: { string } = {}
		for _, item in w.window.picks[i].items do
			table.insert(out, item.label)
		end
		return out
	end
	same(labels(1), { "o/r", "@octocat", "@work", "Other repository…" }, "saved, then the gh logins (active first), then a typed one")
	eq(w.window.picks[1].items[1].detail, "/work/r", "a saved repository shows its checkout")
	same(labels(2), { "z/z", "o/r" }, "picking a login lists its repositories")
	eq(w.kv.get("checkouts")["z/z"], "", "the pick is saved without a checkout")
	eq(prefsOf(b).editing.row, "checkout:z/z", "and Settings opens on its checkout row")
	w.window.choose = "Other repository…"
	w.window.typed = " p/q "
	w.click("plotroom://repos")
	w.flush()
	eq(w.kv.get("checkouts")["p/q"], "", "so is a typed one")
	eq(prefsOf(b).editing.row, "checkout:p/q", "with its row open")
end)

windowCase("window: clicking Worktree coalesces repeats, notes the worktree on the block first, then opens its tab", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	local b = linkQueue(w, s)
	local cardAtTab: any = nil
	local newTab = w.cx.layout.new_tab
	w.cx.layout.new_tab = function(self: any, launch: any, reveal: any): number?
		cardAtTab = cardOf(b)
		return newTab(self, launch, reveal)
	end
	w.click(prLink("worktree", "o/r", 5))
	eq(w.toasts[1].level, "info", "start")
	has(w.toasts[1].text, "o/r#5", "names the pull request")
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(countLog(s.git, "worktree add"), 1, "created once")
	eq(answerOf(b, requestsSent(w)[2].id).busy, true, "the host answered the repeat that the PR is already being prepared")
	eq(w.toasts[3].level, "info", "a second click while it runs is told so")
	has(w.toasts[3].text, "o/r#5", "names the pull request")
	eq(w.toasts[4].level, "success", "level")
	has(w.toasts[4].text, "o/r#5", "names the pull request")
	has(w.toasts[4].sub, "Created", "a new worktree")
	has(w.toasts[4].sub, "Current", "at the PR head")
	has(w.toasts[4].sub, "bbbbbbb", "names the head")
	has(w.toasts[4].sub, "Clean", "without local changes")
	eq(#w.window.picks, 0, "the Worktree key asks nothing")
	yes(cardAtTab ~= nil, "the block showed its worktree card when the tab was opened")
	eq(cardAtTab.p.tone, "success", "a ready one")
	eq(badgeOf(b).tone, "success", "the row has its Worktree badge")
	has(cardText(b), s.target, "and the card says where the worktree is")
	same(w.window.switches, { 1 }, "the source session is switched to")
	eq(#w.window.launches, 1, "one tab: the repeated click opened none")
	eq(w.window.launches[1].cwd, s.target, "the new tab opens in the worktree")
	local named = ""
	for _, name in w.window.tabNames do
		named = name
	end
	eq(named, "PR #5 · r", "tab name")
	w.click(prLink("worktree", "o/r", 5))
	has(w.toasts[5].text, "o/r#5", "after it finished a click starts again")
	w.flush()
	has(w.toasts[6].sub, "Reused", "the second run reuses")
	has(w.toasts[6].sub, "Current", "and is current")
	has(w.toasts[6].sub, "Clean", "and clean")
	eq(commandsOf(b, "update"), nil, "no update commands: the worktree is current")
	yes(findKey(cardOf(b), "remove", "item") ~= nil, "the card offers to remove it")
	-- the card's Open in new tab is the Worktree button: its click reaches the window's flow, which opens another tab
	local tabs = #w.window.launches
	pressCard(b, "open")
	w.flush()
	eq(#w.window.launches, tabs + 1, "a tab opens in the worktree")
	eq(w.window.launches[tabs + 1].cwd, s.target, "at the worktree's path")
end)

windowCase("window: Agent lists the saved prompts of the active filter first, runs the pick with {url} replaced in the PR's worktree without asking, recent first next time", function(w: World)
	w.kv.put("views-prs", { version = 1, nextId = 3, items = array({
		{ id = "v1", name = "My PRs", integration = "github", query = "is:open author:@me", group = "none", prompts = array({ "p1", "p2" }) },
	}) })
	local s = agentScene(w)
	savePrompts(w, {
		promptOf("p1", "Review", "Review {url}\nthen summarise"),
		promptOf("p2", "Triage", "Triage {url}, then triage {url} again"),
		promptOf("p3", "Others", "Check the tests"),
		promptOf("p4", "Blank", ""),
		promptOf("p5", "Orphan", "Look into {url}"),
	})
	w.window.choose = "Review"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	local items = promptPicks(w)[1].items
	local labels: { string } = {}
	for _, item in items do
		table.insert(labels, item.label)
	end
	same(labels, { "Type a prompt…", "Review", "Triage" }, "typing, then only the prompts the view lists; one it leaves out and one with no text are not offered")
	eq(items[1].detail, "Send your own text", "typing says what it does")
	eq(items[2].group, "For My PRs", "a prompt of a restricted view has that view's group")
	eq(items[2].detail, "Review {url}", "and its first line as its detail")
	eq(items[3].group, "For My PRs", "so does the next")
	eq(#w.window.picks, 1, "nothing but the picker is asked")
	eq(#w.window.agents, 1, "one agent")
	eq(w.window.agents[1].command, nil, "a prompt without a model runs the agent setting's command")
	eq(w.window.agents[1].prompt, "Review https://github.com/o/r/pull/5\nthen summarise", "the pick runs with {url} replaced by the PR's link")
	eq(w.window.agents[1].cwd, s.target, "in the PR's worktree")
	eq(s.git.config["branch.feature.merge"], "refs/heads/feature", "its branch tracks the PR's head branch, so git pull and gh there find the PR")
	same(w.kv.get("agent-recent"), { "Review" }, "the pick is kept in kv, which outlives a plugin VM reboot")
	w.window.choose = "Start another agent" -- a live agent is offered first; the menu itself is dismissed
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	local again = promptPicks(w)[2].items
	eq(again[1].label, "Review", "the last pick comes first")
	eq(again[1].group, "Recent", "under Recent")
	eq(#w.window.agents, 1, "a dismissed picker runs nothing")
	w.window.choose = { "Start another agent", "Triage" }
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.window.agents[2].prompt, "Triage https://github.com/o/r/pull/5, then triage https://github.com/o/r/pull/5 again", "every {url} is replaced")
	same(w.kv.get("agent-recent"), { "Triage", "Review" }, "the newest pick leads")
	w.window.choose, w.window.typed = { "Start another agent", "Type a prompt…" }, "Fix the flaky test in {url}"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.window.agents[3].prompt, "Fix the flaky test in https://github.com/o/r/pull/5", "typed text gets {url} replaced too")
	w.window.choose, w.window.typed = { "Start another agent", "Type a prompt…" }, "{owner}/{repo}#{number} {title} by {author}: {branch} into {base} of {remote}, {nope}"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.window.agents[4].prompt, "o/r#5 Add a feature by ann: feature into main of origin, {nope}", "every variable is filled from a fresh read of the PR and its worktree's remote; an unknown one stays")
	eq(w.toasts[#w.toasts].sub, nil, "a typed prompt has no name, so the toast has no second line")
end)

windowCase("window: an unreadable agent-recent is not written over by a pick", function(w: World)
	agentScene(w)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	w.kv.put("agent-recent", { "Old" })
	w.kv.failGet["agent-recent"] = "disk offline"
	w.window.choose = "Review"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(#w.window.agents, 1, "the agent still starts")
	same(w.kv.get("agent-recent"), { "Old" }, "the unreadable list was left as it was")
end)

windowCase("window: with no prompts saved, a pull request offers the default prompts, each run where it says with every variable it names filled in", function(w: World)
	local s = agentScene(w)
	local defaults = (w.load("prompts") :: any).prs
	for i, d in defaults do
		local name = d.name
		w.window.choose = { "Start another agent", name }
		w.click(prLink("agent", "o/r", 5))
		w.flush()
		local agent = w.window.agents[i]
		eq(agent.cwd, if d.worktree == false then s.root else s.target, name .. " runs where its default says: the main checkout or the PR's worktree")
		local values: { [string]: string } = { number = "5", owner = "o", repo = "r", branch = "feature", base = "main", remote = "origin" }
		local lines = string.split(agent.prompt, "\n")
		local function present(line: string, what: string)
			local want = line:gsub("{(%w+)}", function(k)
				return values[k]
			end)
			eq(table.find(lines, want) ~= nil, true, name .. " has its " .. what .. " line filled in: " .. want)
		end
		local textLines = string.split(d.text, "\n")
		present(textLines[1], "first")
		for _, line in textLines do
			local names = line:find("{branch}", 1, true) or line:find("{base}", 1, true) or line:find("{remote}", 1, true)
			if names and not line:find("{github.user}", 1, true) then
				present(line, "branch/base/remote")
			end
		end
		lacks(agent.prompt, "{", name .. " has every variable it names filled in")
	end
	local labels: { string } = {}
	for _, item in promptPicks(w)[1].items do
		table.insert(labels, item.label)
	end
	local expected: { string } = { "Type a prompt…" }
	for _, d in defaults do
		table.insert(expected, d.name)
	end
	same(labels, expected, "typing, then the defaults prompts.luau exports")
	eq(w.kv.get("prompts-prs"), nil, "running them saves nothing")
end)

windowCase("window: Recent lists only prompts that are still saved, and with none saved the picker says where to write them", function(w: World)
	agentScene(w)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}") })
	w.window.choose = "Review"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	w.window.choose = { "Start another agent", "Triage" }
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	same(w.kv.get("agent-recent"), { "Triage", "Review" }, "two picks are remembered")
	savePrompts(w, { promptOf("p2", "Triage", "Triage {url}") })
	w.window.choose = "Start another agent"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	local rows = promptPicks(w)[3].items
	local labels: { string } = {}
	local groups: { string } = {}
	for _, item in rows do
		table.insert(labels, item.label)
		table.insert(groups, item.group or "")
	end
	same(labels, { "Triage", "Type a prompt…", "Triage" }, "a prompt deleted since is no longer a recent row")
	same(groups, { "Recent", "", "All actions" }, "the recent one leads, then typing, then the saved prompts")
	savePrompts(w, {})
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	local none = promptPicks(w)[4].items
	eq(#none, 1, "with nothing saved only typing is offered")
	eq(none[1].label, "Type a prompt…", "typing")
	eq(none[1].detail, "Save actions in Settings › Actions", "which says where to write prompts")
end)

windowCase("window: saved prompts the host cannot read are reported, and a prompt can still be typed", function(w: World)
	agentScene(w)
	w.kv.put("prompts-prs", "garbage")
	w.window.choose, w.window.typed = "Type a prompt…", "Look at {url}"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(w.toasts[1].level, "error", "the user is told")
	eq(w.toasts[1].text, "Saved actions are not listed", "what is missing")
	has(w.toasts[1].sub, "malformed", "and why")
	eq(#promptPicks(w)[1].items, 1, "the picker still opens")
	eq(w.window.agents[1].prompt, "Look at https://github.com/o/r/pull/5", "to type a prompt")
	eq(w.kv.get("prompts-prs"), "garbage", "and the saved prompts are untouched")
end)

windowCase("window: a card button's run link runs its prompt with every {url} replaced in the PR's worktree, with its model, as the prompt is saved now", function(w: World)
	local s, b = agentScene(w)
	local review = promptOf("p1", "Review", "Review {url}\nthen summarise {url}")
	review.model = "@slow"
	savePrompts(w, { review, promptOf("p2", "Triage", "Triage {url}") })
	b.render()
	cardSurface(w, b)
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	local ops: { string } = {}
	for _, q in requestsSent(w) do
		table.insert(ops, q.op)
	end
	same(ops, { "menu", "worktree" }, "the host is asked what the prompt is, then for the worktree")
	eq(requestsSent(w)[1].only, "p1", "and the request for the prompt names it")
	eq(#w.window.picks, 0, "nothing is asked: the button names its prompt")
	eq(#w.window.agents, 1, "the agent starts")
	eq(w.window.agents[1].prompt, "Review https://github.com/o/r/pull/5\nthen summarise https://github.com/o/r/pull/5", "with every {url} replaced by the PR's link")
	eq(w.window.agents[1].cwd, s.target, "in the PR's worktree")
	eq(w.window.agents[1].command, "omp --model @slow", "as omp with the prompt's model, a role alias here")
	savePrompts(w, { promptOf("p1", "Review", "Review quickly: {url}") })
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	eq(w.window.agents[2].prompt, "Review quickly: https://github.com/o/r/pull/5", "a prompt edited since the card was drawn runs as it is saved now")
	eq(w.window.agents[2].command, nil, "its model removed, the agent setting's command runs it")
	local bad = promptOf("p1", "Review", "Review {url}")
	bad.model = "opus; rm -rf ~"
	savePrompts(w, { bad })
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	eq(#w.window.agents, 2, "a model that is no model name starts nothing, as it would go on a command line")
	eq(w.toasts[#w.toasts].level, "error", "the user is told")
end)

windowCase("window: a PR prompt set to the main checkout starts its agent in a new tab at the checkout, with the PR's details and no worktree", function(w: World)
	local s, b = agentScene(w)
	local review = promptOf("p1", "Review", "Review {url}: {title} by {author}, {branch} into {base}")
	review.worktree = false
	savePrompts(w, { review })
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install" }) })
	b.render()
	cardSurface(w, b)
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	eq(requestsSent(w)[2].worktree, false, "the request says no worktree")
	eq(#w.window.agents, 1, "the agent starts")
	eq(w.window.agents[1].cwd, s.root, "in the main checkout")
	has(w.window.agents[1].prompt, "Review https://github.com/o/r/pull/5: ", "with the PR's variables filled in")
	lacks(w.window.agents[1].prompt, "{", "every one of them")
	eq(#w.window.runs, 0, "no setup commands ran")
	eq(countLog(s.git, "worktree add"), 0, "no worktree was made")
	eq(cardOf(b), nil, "nor noted on the block")
end)

windowCase("window: a prompt set to open in this tab starts its agent beside the queue, a new worktree's setup in a tab of its own", function(w: World)
	local s, b = agentScene(w)
	local review = promptOf("p1", "Review", "Review {url}")
	review.split = true
	savePrompts(w, { review })
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install" }) })
	b.render()
	cardSurface(w, b)
	local agent: number? = nil
	local start = w.cx.agents.start
	w.cx.agents.start = function(self: any, opts: any): number
		agent = start(self, opts)
		return agent :: number
	end
	w.click(runLink("o/r", 5, "p1"))
	w.flush()
	eq(w.window.agents[1].cwd, s.target, "the agent runs in the worktree")
	local queueTab = w.window.panes[1].tab
	eq(w.window.panes[agent :: number].tab, queueTab, "as a block in the queue's tab")
	eq(#w.window.runs, 1, "the setup commands ran")
	yes(w.window.panes[w.window.runs[1].pane].tab ~= queueTab, "in a tab of their own")
	eq(w.toasts[#w.toasts].text, "Agent started beside the queue for o/r#5", "the toast says where")
	eq(w.toasts[#w.toasts].sub, "Review", "the second line is the action's name, not its prompt")
end)

windowCase("window: a card button of a prompt the picker's size budget would cut still runs it, the request naming the prompt", function(w: World)
	local s, b = agentScene(w)
	local text = string.rep("x", 7900) .. " {url}"
	local list: { { [string]: any } } = {}
	for i = 1, 8 do
		table.insert(list, promptOf("p" .. i, "Big " .. i, text))
	end
	savePrompts(w, list)
	b.render()
	cardSurface(w, b)
	request(b, "all", { op = "menu" })
	yes(#answerOf(b, "all").items < 8, "the whole list does not fit one answer")
	w.click(runLink("o/r", 5, "p8"))
	w.flush()
	local sent = requestsSent(w)[1]
	eq(sent.op, "menu", "the host is asked about the prompt")
	eq(sent.only, "p8", "by its id alone")
	eq(#w.window.agents, 1, "the eighth button runs its prompt")
	eq(w.window.agents[1].prompt, string.rep("x", 7900) .. " https://github.com/o/r/pull/5", "with its whole text")
	eq(w.window.agents[1].cwd, s.target, "in the PR's worktree")
end)

windowCase("window: a run link the card does not show is refused before anything is asked", function(w: World)
	local _, b = agentScene(w)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	b.render()
	cardSurface(w, b)
	local sent, ran = #w.window.events, #w.calls
	local function refused(url: string, text: string, what: string)
		local said = #w.toasts
		w.click(url)
		w.flush()
		eq(#w.toasts, said + 1, what .. ": the user is told once")
		eq(w.toasts[#w.toasts].level, "error", what .. ": as an error")
		eq(w.toasts[#w.toasts].text, text, what .. ": what is wrong")
	end
	local unlisted = "Plotroom: that pull request is no longer listed"
	refused(runLink("o/r", 5, "p9"), unlisted, "a prompt with no button")
	refused(runLink("o/r", 6, "p1"), unlisted, "another pull request")
	refused(runLink("x/r", 5, "p1"), unlisted, "another repository")
	refused("plotroom://github/run/o/r/5", "Plotroom: malformed link", "a link with no prompt")
	refused(runLink("o/r", 5, "p-1"), "Plotroom: malformed link", "an id that is no word")
	eq(#w.window.events, sent, "nothing was asked of any host")
	eq(#w.calls, ran, "nothing ran")
	eq(#w.window.picks, 0, "and nothing was offered")
end)

windowCase("window: a link without the host's token is refused, so text in a description cannot run an action", function(w: World)
	local _, b = agentScene(w)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	b.render()
	cardSurface(w, b)
	local token = string.match(prLink("run", "o/r", 5), "%?k=(%x+)$")
	yes(token ~= nil and #token >= 24, "the card's links carry a long hex token")
	eq(h.buttonLink(b, "worktree"), prLink("worktree", "o/r", 5), "the hidden worktree link carries it")
	eq(h.buttonLink(b, "prompt-p1"), runLink("o/r", 5, "p1"), "so does a saved action's run link")
	lacks(h.cardText(b), token :: string, "it is never drawn")
	local sent, ran = #w.window.events, #w.calls
	local function refused(url: string, what: string)
		local said = #w.toasts
		w.click(url)
		w.flush()
		eq(w.toasts[said + 1].text, "Plotroom: that pull request is no longer listed", what .. ": no longer listed")
		lacks(w.toasts[said + 1].text .. (w.toasts[said + 1].sub or ""), token :: string, what .. ": the toast does not show the token")
	end
	refused("plotroom://github/run/o/r/5/p1", "a run link with no token")
	refused("plotroom://github/worktree/o/r/5", "a worktree link with no token")
	refused("plotroom://github/worktree/o/r/5?k=0123456789abcdef01234567", "a worktree link with a stale token")
	eq(#w.window.events, sent, "nothing was asked of any host")
	eq(#w.calls, ran, "nothing ran")
	eq(#w.window.agents, 0, "no agent started")
	eq(#w.window.launches, 0, "no tab opened")
end)

windowCase("window: a pull request whose head branch has shell characters is refused for Worktree and agents", function(w: World)
	local s = agentScene(w)
	for _, ref in { "x$(id)", "a;b", "-x", ".hidden" } do
		s.gh.meta["o/r#5"].ref = ref
		local said, ran = #w.toasts, #w.calls
		w.click(prLink("worktree", "o/r", 5))
		w.flush()
		has(w.toasts[#w.toasts].text .. (w.toasts[#w.toasts].sub or ""), "head branch", ref .. ": the worktree is refused")
		w.window.choose = "Type a prompt…"
		w.window.typed = "hi"
		said = #w.toasts
		w.click(prLink("agent", "o/r", 5))
		w.flush()
		eq(#w.window.agents, 0, ref .. ": no agent starts")
		eq(#w.window.launches, 0, ref .. ": no tab opens")
		yes(#w.toasts > said, ref .. ": the user is told")
		has(w.toasts[#w.toasts].text .. (w.toasts[#w.toasts].sub or ""), "head branch", ref .. ": the agent is refused for the branch")
		for i = ran + 1, #w.calls do
			lacks(table.concat(w.calls[i].argv, " "), ref, ref .. ": no command carried the branch")
		end
	end
end)

windowCase("window: a prompt no longer offered once the card was drawn gives a toast and runs nothing", function(w: World)
	local _, b = agentScene(w)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}"), promptOf("p2", "Triage", "Triage {url}") })
	b.render()
	cardSurface(w, b)
	-- Saves `list` instead, then clicks the first prompt's button on the card as it was drawn.
	local function gone(what: string, list: { { [string]: any } })
		savePrompts(w, list)
		local said = #w.toasts
		w.click(runLink("o/r", 5, "p1"))
		w.flush()
		eq(#w.toasts, said + 1, what .. ": the user is told once")
		eq(w.toasts[#w.toasts].level, "error", what .. ": as an error")
		eq(w.toasts[#w.toasts].text, "That action is no longer offered here", what .. ": what is wrong")
		eq(#w.window.agents, 0, what .. ": no agent")
		eq(cardOf(b), nil, what .. ": and no worktree was prepared")
	end
	gone("deleted", { promptOf("p2", "Triage", "Triage {url}") })
	gone("emptied", { promptOf("p1", "Review", "") })
end)

windowCase("window: the palette command Run an agent follows the card's unseen Agent link to the picker", function(w: World)
	local _, b = agentScene(w)
	savePrompts(w, { promptOf("p1", "Review", "Review {url}") })
	b.render()
	cardSurface(w, b)
	w.window.choose = "Review"
	w.command("agent-selected")
	w.flush()
	eq(#promptPicks(w), 1, "the picker opens")
	eq(w.window.agents[1].prompt, "Review https://github.com/o/r/pull/5", "and the pick runs")
end)

windowCase("window: a new worktree runs its repository's setup commands in its tab; a reused one does not", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install", "  ", "make" }), ["x/y"] = array({ "nope" }) })
	linkQueue(w, s)
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(#w.window.runs, 1, "setup runs once")
	eq(w.window.runs[1].text, "pnpm install && make\r", "this repository's commands, blanks dropped, stopping at the first failure")
	eq(w.window.panes[w.window.runs[1].pane].cwd, s.target, "typed into the worktree's new tab")
	has(w.toasts[#w.toasts].sub, "running setup", "the toast says so")
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(#w.window.runs, 1, "a reused worktree is not set up again")
end)

windowCase("window: an agent on a new worktree joins the tab where its setup runs", function(w: World)
	local s = agentScene(w)
	w.kv.put("setup-commands", { ["o/r"] = array({ "pnpm install" }) })
	w.window.choose, w.window.typed = "Type a prompt…", "go"
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(#w.window.runs, 1, "setup runs")
	local shell = w.window.panes[w.window.runs[1].pane]
	eq(shell.cwd, s.target, "in a shell in the worktree")
	eq(w.window.agents[1].prompt, "go", "the agent starts")
	local inTab = 0
	for _, p in w.window.panes do
		if p.tab == shell.tab then
			inTab += 1
		end
	end
	eq(inTab, 2, "and joins the setup shell's tab")
end)

windowCase("window: an answer that arrives without a window context starts nothing", function(w: World)
	agentScene(w)
	local ran = #w.calls
	w.window.typed = "go"
	w.window.decide = function(_opts: any): (string?, boolean?)
		return "Type a prompt…", true
	end
	w.click(prLink("agent", "o/r", 5))
	w.flush()
	eq(#w.calls, ran, "the picker, answered without a context, ran nothing")
	eq(#requestsSent(w), 1, "and asked the host for nothing beyond the prompts")
	eq(#w.toasts, 0, "or said anything")
end)

windowCase("window: a failing mkdir reports the failure, releases the PR, and the next click works", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	local b = linkQueue(w, s)
	w.fs.denyMkdir["/wt"] = "permission denied"
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.toasts[2].level, "error", "level")
	has(w.toasts[2].sub, "/wt", "names the path")
	has(w.toasts[2].sub, "permission denied", "and the reason")
	eq(cardOf(b).p.tone, "error", "the failure is noted on the block for the queue preview")
	has(cardText(b), "permission denied", "with its reason")
	eq(badgeOf(b), nil, "and no badge")
	w.fs.denyMkdir["/wt"] = nil
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.toasts[4].level, "success", "the retry succeeds: the PR was released, not 'already being prepared'")
	has(w.toasts[4].text, "o/r#5", "names the pull request")
	eq(cardOf(b).p.tone, "success", "and the card follows")
end)

windowCase("window: a tab that cannot open keeps the worktree path visible, the block noting it first", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	local b = linkQueue(w, s)
	w.window.newTab = "nil"
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.toasts[2].level, "error", "level")
	has(w.toasts[2].sub, s.target, "the path is shown")
	has(cardText(b), s.target, "and the block noted the worktree whatever its tab did")
	local raised = scene(w, worktree, "o", "q", 6)
	linkQueue(w, raised)
	w.window.newTab = "raise"
	w.click(prLink("worktree", "o/q", 6))
	w.flush()
	local last = w.toasts[#w.toasts]
	eq(last.level, "error", "a raising tab call ends the same way")
	has(last.sub, raised.target, "the path is shown")
end)

windowCase("window: a source pane that closed meanwhile gets a toast but no tab", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	local b = linkQueue(w, s)
	w.click(prLink("worktree", "o/r", 5))
	w.window.panes[1] = nil
	w.flush()
	eq(w.toasts[2].level, "success", "the worktree is ready")
	has(w.toasts[2].sub, s.target, "the path is shown")
	eq(#w.window.launches, 0, "no tab")
	has(cardText(b), s.target, "and the block noted the worktree")
end)

windowCase("window: PR worktree without a checkout asks for one, then continues", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	linkQueue(w, s)
	w.kv.put("checkouts", {})
	w.window.typed = "/work/r"
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	local sent = requestsSent(w)
	eq(#sent, 3, "the worktree request, the checkout it led to, then the worktree request again")
	eq(sent[1].op, "worktree", "first the worktree")
	eq(sent[2].op, "checkout", "then the folder the user gave")
	eq(sent[2].repo, "o/r", "for the repository")
	eq(sent[2].path, "/work/r", "and that path")
	eq(sent[3].op, "worktree", "and the worktree once more")
	eq(w.kv.get("checkouts")["o/r"], "/work/r", "the repository's checkout is saved under its lowercase name")
	eq(w.toasts[#w.toasts].level, "success", "the worktree is made")
	has(w.toasts[#w.toasts].text, "o/r#5", "for the pull request")
	eq(countLog(s.git, "worktree add"), 1, "once")
	w.window.typed = nil
	w.kv.put("checkouts", {})
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(#requestsSent(w), 4, "a dismissed question sends nothing more")
	eq(countLog(s.git, "worktree add"), 1, "and creates nothing")
end)

windowCase("window: any worktree failure is noted and toasted", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	local b = linkQueue(w, s)
	s.gh.meta["o/r#5"] = nil
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.toasts[2].level, "error", "level")
	has(w.toasts[2].sub, "not visible to this GitHub account", "gh's classified reason")
	eq(cardOf(b).p.tone, "error", "noted as a failure")
	has(cardText(b), "not visible to this GitHub account", "with that reason")
end)

windowCase("window: a remote host's pane gets its worktree from its own host; stale links and foreign panes reach nothing", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	local b = linkQueue(w, s)
	w.window.remoteHost = true
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.toasts[2].level, "success", "a remote host's pane is served: its block's host makes the worktree")
	has(cardText(b), s.target, "and its block shows it")
	local sent, ran, said = #w.window.events, #w.calls, #w.toasts
	w.click(prLink("worktree", "o/r", 6))
	eq(w.toasts[said + 1].level, "error", "a link the surface does not list")
	w.click("plotroom://github/worktree/o/../5")
	eq(w.toasts[said + 2].level, "error", "malformed")
	w.window.panes[1] = { block = "plugin.terminal", cwd = "/", tab = 1 }
	w.click(prLink("worktree", "o/r", 5))
	eq(w.toasts[said + 3].level, "error", "a pane that is not Plotroom")
	w.flush()
	eq(#w.window.events, sent, "nothing was asked of any host")
	eq(#w.calls, ran, "no process was started")
end)

windowCase("window: a worktree.open that raises releases the PR and says so", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "o", "r", 5)
	linkQueue(w, s)
	local patched: any = worktree
	local real = patched.open
	patched.open = function()
		error("boom", 0)
	end
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.toasts[2].level, "error", "level")
	has(w.toasts[2].sub, "boom", "reason")
	patched.open = real
	w.click(prLink("worktree", "o/r", 5))
	w.flush()
	eq(w.toasts[4].level, "success", "released: the retry works, it is not 'already being prepared'")
	has(w.toasts[4].text, "o/r#5", "names the pull request")
end)

windowCase("window: a legitimate .github repository gets a worktree through the whole link flow", function(w: World)
	local worktree = w.load("worktree") :: Worktree
	w.load("window")
	local s = scene(w, worktree, "github", ".github", 1)
	local b = linkQueue(w, s)
	w.click(prLink("worktree", "github/.github", 1))
	w.flush()
	eq(w.toasts[2].level, "success", "level")
	has(w.toasts[2].text, "github/.github#1", "names the pull request")
	has(cardText(b), "/wt/plotroom-github_.github-pr-1", "the directory keeps the real name")
	has(cardText(b), "feature", "the card shows the pull request's own head branch")
	eq(s.git.refs["refs/plotroom-pr/github/%2Egithub/pr-1"], sha("b"), "so is the fetched ref")
end)

windowCase("window: a block whose host does not announce this protocol is never asked, and the user is told", function(w: World)
	w.load("window")
	listPr(w, "o/r", 5)
	local function refused(what: string)
		local said = #w.toasts
		w.click(prLink("worktree", "o/r", 5))
		w.click(prLink("agent", "o/r", 5))
		eq(#w.toasts, said + 2, what .. ": each click is answered")
		for i = said + 1, said + 2 do
			eq(w.toasts[i].level, "error", what .. ": level")
			has(w.toasts[i].text, "another version", what .. ": the user is told")
		end
		eq(#w.window.events + #w.window.picks + #w.calls, 0, what .. ": nothing was sent, asked or run")
	end
	refused("a view without the marker")
	local surface: any = w.window.surfaces[1]
	surface.main = { id = "main", c = { { id = "main.rpc", p = { text = "2", hidden = true } } } }
	refused("another protocol's marker")
end)

windowCase("window: a request its block's host never answers gives up with a toast, and an answer that comes late is ignored", function(w: World)
	w.load("window")
	listPr(w, "o/r", 5)
	local surface: any = w.window.surfaces[1]
	local nodes: { any } = { { id = "main.rpc", p = { text = asks.protocol, hidden = true } } }
	surface.main = { id = "main", c = nodes }
	w.click(prLink("agent", "o/r", 5))
	w.click(prLink("worktree", "o/r", 5))
	local sent = requestsSent(w)
	eq(#sent, 2, "two requests are out")
	eq(sent[1].op, "menu", "the list")
	eq(sent[2].op, "worktree", "and the worktree")
	local function gaveUp(): number
		local n = 0
		for _, t in w.toasts do
			if string.find(t.text, "did not answer", 1, true) then
				n += 1
			end
		end
		return n
	end
	w.click("plotroom://rpc/" .. sent[1].id)
	w.advance(20 * 1000)
	eq(gaveUp(), 0, "a link announcing an answer that is not on screen leaves the list waited for")
	w.advance(20 * 1000)
	eq(gaveUp(), 1, "the list is given up after a while")
	eq(w.toasts[#w.toasts].level, "error", "with an error")
	w.advance(60 * 1000)
	eq(gaveUp(), 1, "a worktree takes longer: it is still waited for")
	w.advance(5 * 60 * 1000)
	eq(gaveUp(), 2, "and given up too in the end")
	local picks, tabs, said = #w.window.picks, #w.window.launches, #w.toasts
	table.insert(nodes, { id = "main.r" .. sent[1].id, p = { text = jsonEncode({ items = { { label = "/late", send = "/late" } } }), hidden = true } })
	table.insert(nodes, { id = "main.r" .. sent[2].id, p = { text = jsonEncode({ path = "/wt/late", summary = "Created", created = true, current = true }), hidden = true } })
	w.click("plotroom://rpc/" .. sent[1].id)
	w.click("plotroom://rpc/" .. sent[2].id)
	w.flush()
	eq(#w.window.picks, picks, "a late list opens no picker")
	eq(#w.window.launches, tabs, "a late worktree opens no tab")
	eq(#w.toasts, said, "and says nothing")
end)

windowCase("window: an answer already on screen is found by polling even when its link never arrives", function(w: World)
	w.load("window")
	listPr(w, "o/r", 5)
	local surface: any = w.window.surfaces[1]
	local nodes: { any } = { { id = "main.rpc", p = { text = asks.protocol, hidden = true } } }
	surface.main = { id = "main", c = nodes }
	w.click(prLink("agent", "o/r", 5))
	local sent = requestsSent(w)
	eq(#sent, 1, "the list is requested")
	local picks = #w.window.picks
	table.insert(nodes, { id = "main.r" .. sent[1].id, p = { text = jsonEncode({ items = { { label = "/go", send = "/go" } } }), hidden = true } })
	w.advance(1000)
	eq(#w.window.picks, picks + 1, "the list opens without any rpc link")
	w.advance(60 * 1000)
	for _, t in w.toasts do
		lacks(t.text, "did not answer", "and the request is not given up")
	end
end)

return {}
