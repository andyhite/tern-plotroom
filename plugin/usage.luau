--!strict
-- How often each command ran and how each agent run ended, on this machine only: kv `usage` (id -> count and last use,
-- and the day counting began) and kv `runs` (one record per agent run, newest first, at most RUNS_CAP). Ids are
-- "<where>:<what>": "queue:<action id>" (the host's queue actions), "row:<command id>" (Commands rows the window runs),
-- "palette:<command id>" (Tern palette commands) and "action:<name>" (saved actions started). Neither store holds item
-- titles or prompt text, and of an agent's output a run keeps only its end-of-run report (reportOf), cut to the caps
-- below. A store that cannot be read or is malformed is never written over.

local M = {}

M.USAGE_KEY = "usage"
M.RUNS_KEY = "runs"
M.RUNS_CAP = 1000
local IDS_CAP = 500 -- ids kept; the least recently used goes first
local ID_CAP = 200
local TEXT_CAP = 200
local COMMIT_CAP, PR_CAP, EVIDENCE_N = 64, 500, 20 -- a SHA-256 commit id; a pull request URL; evidence strings kept
local REPORT_BYTES = 64 * 1024 -- a longer report block is not read
-- A run's saved acceptance criteria (tracker.CRITERIA_CHARS characters, up to 4 bytes each). ponytail: kept on every
-- run that has them, so a full log of such runs is ~8 MB; keep them on the newest runs only if kv `runs` gets slow.
M.CRITERIA_CAP = 8000
M.ATTENTION = { ok = true, stuck = true, ["needs-human"] = true }
M.VERDICTS = { verified = true, ["not"] = true, unchecked = true }
M.CHECKS = { pass = true, fail = true }
M.AGREE_AFTER_S = 7 * 86400 -- a checked run with no disagreement counts as agreed this long after its verdict
M.AGREEMENT_N, M.AGREEMENT_GATE = 20, 0.8 -- PRODUCT.md › Metrics row 6: the Autopilot gate

export type Count = { n: number, at: number }
export type Usage = { since: number, counts: { [string]: Count } }
-- `runsIn`: "worktree" or "main checkout"; `started`/`ended`: seconds since the epoch (an old link has no start).
-- `attention`..`blocker`: the agent's end-of-run report (`attention` "none": it gave no valid one; nil: a run logged
-- before reports were read). `outcome`: what the action said the run must leave behind (a prompts.OUTCOMES id; nil:
-- none), `verdict`: what checking it on GitHub found last (verified | not | unchecked). `criteria`: the acceptance
-- criteria saved on it at dispatch. `check`: what its checker found (pass | fail; nil: not checked), with `findings`.
-- `login`, `ghRepo`, `number` and `branch`: what GitHub knows the run's work by, for its merge. A checked run (one a
-- checker's verdict was recorded on; a checker's own run never is) has `checkedAt`, the verdict's time; `disagree`, the
-- reason you gave for disagreeing with it ("" for none; nil: no disagreement); `merged`, true once its work merged.
export type Run = { key: string, action: string, kind: string?, model: string?, runsIn: string?, started: number?, ended: number, result: string, attention: string?, reason: string?, commit: string?, pr: string?, evidence: { string }?, blocker: string?, outcome: string?, verdict: string?, criteria: string?, check: string?, findings: { string }?, login: string?, ghRepo: string?, number: number?, branch: string?, checkedAt: number?, disagree: string?, merged: boolean? }
-- What the fixed contract (prompts.REPORT) asks an agent to end its turn with: a claim, never an outcome. A checker's
-- report also has `check` (pass | fail; prompts.checkBlock) and `findings`.
export type Report = { attention: string, reason: string, commit: string?, pr: string?, evidence: { string }, blocker: string?, check: string?, findings: { string } }

-- `s` as one line of at most `cap` bytes, cut at a character boundary; nil when it is no string or empty.
function M.line(s: any, cap: number): string?
	if type(s) ~= "string" then
		return nil
	end
	local text = string.sub((string.gsub(s, "%c", " ")), 1, cap)
	while #text > 0 and not utf8.len(text) do
		text = string.sub(text, 1, -2)
	end
	return if string.find(text, "%S") then text else nil
end

local function whole(v: any): boolean
	return type(v) == "number" and v >= 0 and v % 1 == 0
end

local function textOk(v: any, cap: number): boolean
	return type(v) == "string" and #v <= cap
end

-- A usage store decoded from kv or JSON, or nil when it is malformed.
function M.parseUsage(v: any): Usage?
	if type(v) ~= "table" or not whole(v.since) or type(v.counts) ~= "table" then
		return nil
	end
	local counts: { [string]: Count } = {}
	for id, c in v.counts do
		if not textOk(id, ID_CAP) or type(c) ~= "table" or not whole(c.n) or not whole(c.at) then
			return nil
		end
		counts[id] = { n = c.n, at = c.at }
	end
	return { since = v.since, counts = counts }
end

-- The saved usage, or nil and why when it cannot be read or is malformed; nothing saved yet is an empty store.
function M.readUsage(): (Usage?, string?)
	local ok, v = pcall(tern.kv.get, M.USAGE_KEY)
	if not ok then
		return nil, "could not be read"
	elseif v == nil then
		return { since = 0, counts = {} }, nil
	end
	local u = M.parseUsage(v)
	return u, if u then nil else "is malformed"
end

-- The text of the host's hidden `main.usage` node: its usage store, or why it cannot be read, as JSON.
-- ponytail: one kv read per render; cache in the block's State if it shows up in a profile.
function M.published(): string
	local u, why = M.readUsage()
	return tern.json.encode(if u then { usage = { since = u.since, counts = u.counts } } else { problem = why })
end

-- Counts one use of `id` now. Nothing is written when the store cannot be read or is malformed.
function M.bump(id: string)
	local key = M.line(id, ID_CAP)
	local u = M.readUsage()
	if not key or not u then
		return
	end
	local now = os.time()
	local c = u.counts[key]
	u.counts[key] = { n = (if c then c.n else 0) + 1, at = now }
	if u.since == 0 then
		u.since = now
	end
	local ids: { string } = {}
	for k in u.counts do
		table.insert(ids, k)
	end
	if #ids > IDS_CAP then
		table.sort(ids, function(a, b)
			return u.counts[a].at > u.counts[b].at
		end)
		for i = IDS_CAP + 1, #ids do
			u.counts[ids[i]] = nil
		end
	end
	pcall(tern.kv.set, M.USAGE_KEY, { since = u.since, counts = u.counts })
end

-- `v` as a list of strings, or nil when it is no list or holds anything else.
local function strings(v: any): { string }?
	if type(v) ~= "table" then
		return nil
	end
	local out: { string } = {}
	local n = 0
	for i, s in v do
		if type(i) ~= "number" or type(s) ~= "string" then
			return nil
		end
		out[i] = s
		n += 1
	end
	return if #out == n then out else nil
end

-- The report in the last `plotroom-report` block of `text` (an agent's last message), fields cut to the run log's caps;
-- nil when there is none or it is malformed: not one JSON object, an unknown `attention`, no `reason`, a `commit` that
-- is no full SHA, a `pr` that is no URL, `evidence` that is no list of strings, or a `blocker` that is no string.
function M.reportOf(text: any): Report?
	if type(text) ~= "string" then
		return nil
	end
	local body: string? = nil
	for b in string.gmatch(text .. "\n", "```plotroom%-report[ \t]*\r?\n(.-)\r?\n[ \t]*```[ \t]*\r?\n") do
		body = b
	end
	if not body or #body > REPORT_BYTES then
		return nil
	end
	local ok, r = pcall(tern.json.decode, body)
	if not ok or type(r) ~= "table" then
		return nil
	end
	local evidence = strings(r.evidence)
	local commit, pr = r.commit, r.pr
	if
		type(r.attention) ~= "string"
		or not M.ATTENTION[r.attention]
		or not M.line(r.reason, TEXT_CAP)
		or not evidence
		or (commit ~= nil and (type(commit) ~= "string" or not string.match(commit, "^%x+$") or (#commit ~= 40 and #commit ~= 64)))
		or (pr ~= nil and (type(pr) ~= "string" or not string.match(pr, "^https?://%S+$")))
		or (r.blocker ~= nil and type(r.blocker) ~= "string")
	then
		return nil
	end
	local function cut(list: { string }?): { string }
		local kept: { string } = {}
		for _, s in (list or {}) :: { string } do
			local l = M.line(s, TEXT_CAP)
			if l and #kept < EVIDENCE_N then
				table.insert(kept, l)
			end
		end
		return kept
	end
	-- A check that is neither pass nor fail is none (a checker's run then counts as a fail); findings that are no list
	-- of strings are none.
	local check = if type(r.check) == "string" then string.lower(r.check) else nil
	return {
		attention = r.attention,
		reason = M.line(r.reason, TEXT_CAP) :: string,
		commit = if commit then string.lower(commit) else nil,
		pr = M.line(pr, PR_CAP),
		evidence = cut(evidence),
		blocker = M.line(r.blocker, TEXT_CAP),
		check = if check and M.CHECKS[check] then check else nil,
		findings = cut(strings(r.findings)),
	}
end

local function runOf(r: any): Run?
	if type(r) ~= "table" then
		return nil
	end
	local evidence = if r.evidence ~= nil then strings(r.evidence) else nil
	local findings = if r.findings ~= nil then strings(r.findings) else nil
	if
		not textOk(r.key, ID_CAP)
		or not textOk(r.action, TEXT_CAP)
		or not textOk(r.result, TEXT_CAP)
		or not whole(r.ended)
		or (r.kind ~= nil and not textOk(r.kind, TEXT_CAP))
		or (r.model ~= nil and not textOk(r.model, TEXT_CAP))
		or (r.runsIn ~= nil and not textOk(r.runsIn, TEXT_CAP))
		or (r.started ~= nil and not whole(r.started))
		or (r.attention ~= nil and not (M.ATTENTION[r.attention] or r.attention == "none"))
		or (r.reason ~= nil and not textOk(r.reason, TEXT_CAP))
		or (r.commit ~= nil and not textOk(r.commit, COMMIT_CAP))
		or (r.pr ~= nil and not textOk(r.pr, PR_CAP))
		or (r.evidence ~= nil and (not evidence or #evidence > EVIDENCE_N))
		or (r.blocker ~= nil and not textOk(r.blocker, TEXT_CAP))
		or (r.outcome ~= nil and not textOk(r.outcome, ID_CAP))
		or (r.verdict ~= nil and not M.VERDICTS[r.verdict])
		or (r.criteria ~= nil and not textOk(r.criteria, M.CRITERIA_CAP))
		or (r.check ~= nil and not M.CHECKS[r.check])
		or (r.findings ~= nil and (not findings or #findings > EVIDENCE_N))
		or (r.login ~= nil and not textOk(r.login, TEXT_CAP))
		or (r.ghRepo ~= nil and not textOk(r.ghRepo, TEXT_CAP))
		or (r.number ~= nil and not whole(r.number))
		or (r.branch ~= nil and not textOk(r.branch, TEXT_CAP))
		or (r.checkedAt ~= nil and not whole(r.checkedAt))
		or (r.disagree ~= nil and not textOk(r.disagree, TEXT_CAP))
		or (r.merged ~= nil and r.merged ~= true)
	then
		return nil
	end
	for _, list in { evidence or {} :: { string }, findings or {} :: { string } } do
		for _, s in list do
			if not textOk(s, TEXT_CAP) then
				return nil
			end
		end
	end
	return { key = r.key, action = r.action, kind = r.kind, model = r.model, runsIn = r.runsIn, started = r.started, ended = r.ended, result = r.result, attention = r.attention :: string?, reason = r.reason, commit = r.commit, pr = r.pr, evidence = if evidence then tern.json.array(evidence) :: any else nil, blocker = r.blocker, outcome = r.outcome, verdict = r.verdict :: string?, criteria = r.criteria, check = r.check :: string?, findings = if findings then tern.json.array(findings) :: any else nil, login = r.login, ghRepo = r.ghRepo, number = r.number, branch = r.branch, checkedAt = r.checkedAt, disagree = r.disagree, merged = r.merged :: boolean? }
end

-- The run log, newest first, or nil and why when it cannot be read or is malformed.
function M.readRuns(): ({ Run }?, string?)
	local ok, v = pcall(tern.kv.get, M.RUNS_KEY)
	if not ok then
		return nil, "could not be read"
	elseif v == nil then
		return {}, nil
	elseif type(v) ~= "table" then
		return nil, "is malformed"
	end
	local out: { Run } = {}
	for _, r in v do
		local run = runOf(r)
		if not run then
			return nil, "is malformed"
		end
		table.insert(out, run)
	end
	return out, nil
end

-- Puts `run` first in the log, keeping the newest RUNS_CAP. Nothing is written when the log cannot be read or is malformed.
function M.appendRun(run: Run)
	local runs = M.readRuns()
	local clean = runOf({
		key = M.line(run.key, ID_CAP),
		action = M.line(run.action, TEXT_CAP) or "",
		kind = M.line(run.kind, TEXT_CAP),
		model = M.line(run.model, TEXT_CAP),
		runsIn = M.line(run.runsIn, TEXT_CAP),
		started = run.started,
		ended = run.ended,
		result = M.line(run.result, TEXT_CAP),
		attention = run.attention,
		reason = M.line(run.reason, TEXT_CAP),
		commit = run.commit,
		pr = M.line(run.pr, PR_CAP),
		evidence = run.evidence,
		blocker = M.line(run.blocker, TEXT_CAP),
		outcome = M.line(run.outcome, ID_CAP),
		verdict = run.verdict,
		criteria = M.text(run.criteria, M.CRITERIA_CAP),
		check = run.check,
		findings = run.findings,
		login = M.line(run.login, TEXT_CAP),
		ghRepo = M.line(run.ghRepo, TEXT_CAP),
		number = run.number,
		branch = M.line(run.branch, TEXT_CAP),
	})
	if not runs or not clean then
		return
	end
	local rows: { any } = { clean }
	for i = 1, math.min(#runs, M.RUNS_CAP - 1) do
		table.insert(rows, runs[i])
	end
	pcall(tern.kv.set, M.RUNS_KEY, tern.json.array(rows))
end

-- `s` cut to at most `cap` bytes at a character boundary, line breaks kept; nil when it is no string or blank.
function M.text(s: any, cap: number): string?
	if type(s) ~= "string" or not string.find(s, "%S") then
		return nil
	end
	local text = string.sub(s, 1, cap)
	while #text > 0 and not utf8.len(text) do
		text = string.sub(text, 1, -2)
	end
	return text
end

-- Records what a checker found (`check`: pass | fail, with `findings`) on the run of item `key` that started at
-- `started`, now: it is a checked run from then, and a disagreement with an earlier verdict is dropped (it was about
-- that verdict). Nothing is written when the log cannot be read or is malformed, the run is not in it, or `check` is
-- not one of CHECKS.
function M.setCheck(key: string, started: number?, check: string, findings: { string })
	local runs = M.readRuns()
	if not runs or not M.CHECKS[check] then
		return
	end
	for _, r in runs do
		if r.key == key and r.started == started then
			local kept: { string } = {}
			for _, f in findings do
				local l = M.line(f, TEXT_CAP)
				if l and #kept < EVIDENCE_N then
					table.insert(kept, l)
				end
			end
			r.check, r.findings = check, if #kept > 0 then tern.json.array(kept) :: any else nil
			r.checkedAt, r.disagree = os.time(), nil
			pcall(tern.kv.set, M.RUNS_KEY, tern.json.array(runs :: any))
			return
		end
	end
end

-- Records `verdict` on the run of item `key` that started at `started` (the newest such). Nothing is written when the log
-- cannot be read or is malformed, the run is not in it, or the verdict is not one of VERDICTS.
function M.setVerdict(key: string, started: number?, verdict: string)
	local runs = M.readRuns()
	if not runs or not M.VERDICTS[verdict] then
		return
	end
	for _, r in runs do
		if r.key == key and r.started == started then
			if r.verdict ~= verdict then
				r.verdict = verdict
				pcall(tern.kv.set, M.RUNS_KEY, tern.json.array(runs :: any))
			end
			return
		end
	end
end

-- Changes the run of item `key` that started at `started` with `change` (false: leave it) and saves the log; whether
-- it was saved. Nothing is written when the log cannot be read or is malformed, or the run is not in it.
local function onRun(key: string, started: number?, change: (Run) -> boolean): boolean
	local runs = M.readRuns()
	if not runs then
		return false
	end
	for _, r in runs do
		if r.key == key and r.started == started then
			return change(r) and (pcall(tern.kv.set, M.RUNS_KEY, tern.json.array(runs :: any)))
		end
	end
	return false
end

-- Records that you disagree with the checker's verdict on the checked run of item `key` that started at `started`,
-- with `reason` cut to one line ("" for none); a second one replaces the first. Whether it was saved: never on a run
-- with no verdict.
function M.setDisagree(key: string, started: number?, reason: string?): boolean
	return onRun(key, started, function(r: Run): boolean
		if not r.checkedAt then
			return false
		end
		r.disagree = M.line(reason, TEXT_CAP) or ""
		return true
	end)
end

-- Records that the work of the run of item `key` that started at `started` merged.
function M.setMerged(key: string, started: number?)
	onRun(key, started, function(r: Run): boolean
		r.merged = true
		return true
	end)
end

-- Whether you agree with the checker on run `r` at time `now`: "disagreed" once you recorded a disagreement, else
-- "agreed" once its work merged or AGREE_AFTER_S after the verdict; nil while undecided or for a run with no verdict.
function M.agreement(r: Run, now: number): string?
	if not r.checkedAt then
		return nil
	elseif r.disagree then
		return "disagreed"
	elseif r.merged or now - r.checkedAt >= M.AGREE_AFTER_S then
		return "agreed"
	end
	return nil
end

local function day(t: number): string
	return os.date("%Y-%m-%d", t) :: string
end

local function duration(s: number): string
	s = math.floor(s + 0.5)
	if s < 60 then
		return s .. "s"
	elseif s < 3600 then
		return (s // 60) .. "m " .. (s % 60) .. "s"
	end
	return (s // 3600) .. "h " .. ((s % 3600) // 60) .. "m"
end

local RESULTS = { "done", "failed", "exited", "closed" }
local WHERE = { queue = "Queue action", row = "Commands row", palette = "Tern's palette command", action = "Action" }
local ORDER = { queue = 1, row = 2, palette = 3, action = 4 }

export type Part<T> = { value: T?, problem: string? }
export type Inputs = {
	host: Part<Usage>, -- the block's host: its "queue:" counts are taken
	here: Part<Usage>, -- this machine: every other count
	runs: Part<{ Run }>,
	name: (id: string) -> string, -- what a count's id is called
	outcome: (id: string) -> string?, -- what an outcome id is called (prompts.outcomeLabel); nil: none
}

-- The plain-text report: the counts since the first recorded day, then the runs by action. A part that could not be
-- read is named, and the rest is reported all the same.
function M.report(i: Inputs): string
	local rows: { { where: string, what: string, id: string, c: Count } } = {}
	local since: number? = nil
	local function earliest(t: number?)
		if t and t > 0 and (not since or t < since) then
			since = t
		end
	end
	local function take(u: Usage?, host: boolean)
		if not u then
			return
		end
		earliest(u.since)
		for id, c in u.counts do
			local where, what = string.match(id, "^(%a+):(.+)$")
			if where and WHERE[where] and (where == "queue") == host then
				table.insert(rows, { where = where, what = what :: string, id = id, c = c })
			end
		end
	end
	take(i.host.value, true)
	take(i.here.value, false)
	local runs: { Run } = i.runs.value or {}
	for _, r in runs do
		earliest(r.started or r.ended)
	end
	table.sort(rows, function(a, b)
		if a.where ~= b.where then
			return ORDER[a.where] < ORDER[b.where]
		elseif a.c.n ~= b.c.n then
			return a.c.n > b.c.n
		end
		return a.id < b.id
	end)

	local out = { "Plotroom usage report", if since then "Since " .. day(since :: number) else "Nothing recorded yet" }
	local missing: { string } = {}
	if i.host.problem then
		table.insert(missing, "Usage counts on the block's host " .. i.host.problem .. "; its queue actions are left out.")
	end
	if i.here.problem then
		table.insert(missing, "Usage counts on this machine " .. i.here.problem .. "; its commands and actions are left out.")
	end
	if i.runs.problem then
		table.insert(missing, "The run log " .. i.runs.problem .. "; runs are left out.")
	end
	if #missing > 0 then
		table.insert(out, "")
		table.insert(out, "Missing")
		for _, m in missing do
			table.insert(out, m)
		end
	end

	table.insert(out, "")
	table.insert(out, "Commands")
	for _, r in rows do
		table.insert(out, WHERE[r.where] .. " · " .. i.name(r.id) .. " · " .. r.c.n .. " · last " .. os.date("%Y-%m-%d %H:%M", r.c.at))
	end
	if #rows == 0 then
		table.insert(out, "None")
	end

	table.insert(out, "")
	table.insert(out, "Runs")
	local groups: { [string]: { results: { [string]: number }, times: { number }, n: number, outcomes: { [string]: { [string]: number } } } } = {}
	local names: { string } = {}
	for _, r in runs do
		local name = if r.action ~= "" then r.action else "Unnamed"
		local g = groups[name]
		if not g then
			g = { results = {}, times = {}, n = 0, outcomes = {} }
			groups[name] = g
			table.insert(names, name)
		end
		g.n += 1
		g.results[r.result] = (g.results[r.result] or 0) + 1
		if r.started and r.ended >= r.started then
			table.insert(g.times, r.ended - r.started)
		end
		local label = if r.outcome then i.outcome(r.outcome) else nil
		if label then
			-- A run whose check never answered (no verdict) counts as Unchecked: missing data is never Verified.
			local v = r.verdict or "unchecked"
			local o = g.outcomes[label] or {}
			g.outcomes[label] = o
			o[v] = (o[v] or 0) + 1
		end
	end
	table.sort(names, function(a, b)
		return if groups[a].n ~= groups[b].n then groups[a].n > groups[b].n else a < b
	end)
	for _, name in names do
		local g = groups[name]
		local parts: { string } = {}
		for _, res in RESULTS do
			table.insert(parts, res .. " " .. (g.results[res] or 0))
		end
		local others: { string } = {}
		for res, n in g.results do
			if not table.find(RESULTS, res) then
				table.insert(others, res .. " " .. n)
			end
		end
		table.sort(others)
		for _, o in others do
			table.insert(parts, o)
		end
		local median = "unknown"
		local t = g.times
		if #t > 0 then
			table.sort(t)
			local mid = (#t + 1) // 2
			median = duration(if #t % 2 == 1 then t[mid] else (t[mid] + t[mid + 1]) / 2)
		end
		table.insert(out, name .. " · " .. g.n .. (if g.n == 1 then " run" else " runs") .. " · " .. table.concat(parts, ", ") .. " · median " .. median)
		local labels: { string } = {}
		for label in g.outcomes do
			table.insert(labels, label)
		end
		table.sort(labels)
		for _, label in labels do
			local o = g.outcomes[label]
			table.insert(out, "  Outcome " .. label .. " · verified " .. (o.verified or 0) .. ", not verified " .. (o["not"] or 0) .. ", unchecked " .. (o.unchecked or 0))
		end
	end
	if #names == 0 then
		table.insert(out, "None")
	end

	-- Checker agreement (PRODUCT.md › Metrics row 6): the log is newest first, so the last decided runs lead.
	table.insert(out, "")
	table.insert(out, "Checker agreement")
	local now = os.time()
	local checked, disagreed, undecided, decided, agreed = 0, 0, 0, 0, 0
	for _, r in runs do
		local a = M.agreement(r, now)
		checked += if r.checkedAt then 1 else 0
		disagreed += if a == "disagreed" then 1 else 0
		undecided += if r.checkedAt and not a then 1 else 0
		if a and decided < M.AGREEMENT_N then
			decided += 1
			agreed += if a == "agreed" then 1 else 0
		end
	end
	table.insert(out, "Checked runs " .. checked .. " · disagreements " .. disagreed .. " · undecided " .. undecided)
	local met = decided >= M.AGREEMENT_N and agreed >= M.AGREEMENT_GATE * decided
	local gate = "Autopilot gate " .. math.floor(M.AGREEMENT_GATE * 100) .. "% over " .. M.AGREEMENT_N .. " decided runs · " .. (if met then "met" else "not met")
	if decided == 0 then
		table.insert(out, "Agreement unknown: no decided runs yet · " .. gate)
	else
		table.insert(out, "Agreement " .. (agreed * 100 // decided) .. "% (" .. agreed .. " of the last " .. decided .. " decided " .. (if decided == 1 then "run" else "runs") .. ") · " .. gate)
	end
	return table.concat(out, "\n") .. "\n"
end

return M
