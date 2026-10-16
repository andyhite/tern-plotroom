--!strict
-- Pure assertions over triage.luau; no kv access (load/save are covered through validate/prune).

local triage = require("../triage")

local M = {}

local function pr(extra: { [string]: any }?): { [string]: any }
	local t: { [string]: any } = {
		key = "o/r#5", state = "OPEN", title = "T", draft = false, updated = "2026-01-01", headSha = "abc",
		review = "none", checks = "pending", comments = 1, additions = 1, deletions = 2, files = 3,
		labels = { "b", "a" }, runs = { { name = "ci", status = "failure" }, { name = "lint", status = "success" } }, runTotal = 2,
	}
	local over: { [string]: any } = extra :: any
	if over then
		for k, v in over do
			t[k] = v
		end
	end
	return t
end

function M.run()
	local now = 1_000_000
	local s = triage.empty()

	-- new / seen / changed
	local p = pr()
	assert(triage.status(s, "prs", p, now).fresh == "new")
	triage.markSeen(s, "prs", p, now)
	assert(triage.status(s, "prs", p, now).fresh == "seen")
	assert(triage.status(s, "prs", pr({ labels = { "a", "b" } }), now).fresh == "seen", "label order is irrelevant")
	assert(triage.status(s, "prs", pr({ review = "approved" }), now).fresh == "changed")
	assert(triage.status(s, "prs", pr({ title = "T2" }), now).fresh == "changed")
	-- a check run flipping with `updated` unchanged
	local flipped = pr({ runs = { { name = "ci", status = "success" }, { name = "lint", status = "success" } } })
	assert(flipped.updated == p.updated)
	assert(triage.status(s, "prs", flipped, now).fresh == "changed")
	assert(#triage.signature("prs", p) == 16)
	-- issues: jira updated is 0, status and priority still count
	local i1 = { key = "abc#ABC-1", state = "open", title = "x", status = { text = "To Do" }, updated = 0 }
	local i2 = { key = "abc#ABC-1", state = "open", title = "x", status = { text = "Done" }, updated = 0 }
	assert(triage.signature("issues", i1) ~= triage.signature("issues", i2))
	assert(triage.signature("issues", i1) ~= triage.signature("issues", { key = i1.key, state = "open", title = "x", status = i1.status, updated = 0, priority = "High" }))

	-- snooze does not mark seen; expires at untilTs
	local q = pr({ key = "o/r#9" })
	triage.snooze(s, "prs", q, now + 100, now)
	local st = triage.status(s, "prs", q, now)
	assert(st.fresh == "new" and st.snoozed and st.snoozeUntil == now + 100)
	assert(not triage.status(s, "prs", q, now + 100).snoozed)
	triage.unsnooze(s, "o/r#9")
	assert(not triage.status(s, "prs", q, now).snoozed)

	-- tomorrow: next calendar day at local 08:00, strictly later
	local t = triage.tomorrow(now)
	local d0 = os.date("*t", now) :: any
	local d1 = os.date("*t", t) :: any
	assert(t > now and d1.hour == 8 and d1.min == 0 and d1.sec == 0)
	assert(os.time({ year = d1.year, month = d1.month, day = d1.day - 1, hour = 12 }) == os.time({ year = d0.year, month = d0.month, day = d0.day, hour = 12 }))
	assert(triage.tomorrow(now) == t, "deterministic")

	-- attention matrix
	local newSt: triage.Status = { fresh = "new", snoozed = false }
	local seenSt: triage.Status = { fresh = "seen", snoozed = false }
	local snoozedSt: triage.Status = { fresh = "changed", snoozed = true, snoozeUntil = 5 }
	assert(triage.attention(newSt, nil))
	assert(triage.attention(newSt, "idle") and triage.attention(newSt, "working") and triage.attention(newSt, "exited"))
	assert(not triage.attention(seenSt, "idle") and not triage.attention(seenSt, nil))
	assert(not triage.attention(snoozedSt, "idle"))
	assert(triage.attention(snoozedSt, "waiting_input"))
	assert(triage.attention(seenSt, "waiting_input"))

	-- sanitizeKey
	assert(triage.sanitizeKey("o/r#5") == "o/r#5")
	assert(triage.sanitizeKey("a\nb") == nil and triage.sanitizeKey("") == nil and triage.sanitizeKey(5) == nil)
	assert(triage.sanitizeKey(string.rep("x", 201)) == nil and triage.sanitizeKey(string.rep("x", 200)) ~= nil)

	-- prune: oldest go first, active snoozes survive
	local big = triage.empty()
	for n = 1, triage.CAP + 3 do
		big.items["k" .. n] = { at = n }
	end
	big.items["k1"].snoozeUntil = now + 1000
	triage.prune(big, now)
	local count = 0
	for _ in big.items do
		count += 1
	end
	assert(count == triage.CAP)
	assert(big.items["k1"] ~= nil, "an active snooze is kept")
	assert(big.items["k2"] == nil and big.items["k4"] == nil and big.items["k5"] ~= nil)

	-- malformed stores are rejected
	assert(triage.validate(triage.empty()) == nil)
	assert(triage.validate(s) == nil)
	assert(triage.validate("x") ~= nil)
	assert(triage.validate({ version = 2, items = {} }) ~= nil)
	assert(triage.validate({ version = 1, items = { ["a"] = { at = "x" } } }) ~= nil)
	assert(triage.validate({ version = 1, items = { ["a\n"] = { at = 1 } } }) ~= nil)
	assert(triage.validate({ version = 1, items = { a = { at = 1, seen = 5 } } }) ~= nil)
end

return M
