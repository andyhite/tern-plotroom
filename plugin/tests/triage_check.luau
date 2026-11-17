--!strict
-- Pure assertions over triage.luau; no kv access (load/save are covered in tests/cases/basics.luau, with the fake kv).

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
	-- the published FNV-1a 32-bit vectors: a multiply that rounds past 2^53 gets the longer ones wrong
	assert(triage.fnv("", 2166136261) == 0x811c9dc5)
	assert(triage.fnv("a", 2166136261) == 0xe40c292c)
	assert(triage.fnv("foobar", 2166136261) == 0xbf9cf968)

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
	-- a snooze ends early when the item is no longer as it was snoozed; one saved before that was recorded runs to its time
	triage.snooze(s, "prs", q, now + 100, now)
	assert(triage.snoozed(s, "prs", q, now))
	local worse = pr({ key = "o/r#9", checks = "FAILURE" })
	assert(not triage.status(s, "prs", worse, now).snoozed and not triage.snoozed(s, "prs", worse, now))
	assert(triage.snoozed(s, nil, worse, now), "no kind, no signature to compare")
	s.items["o/r#9"].snoozeSig = nil
	assert(triage.snoozed(s, "prs", worse, now))
	triage.unsnooze(s, "o/r#9")
	-- snoozing a seen item keeps when it was seen: only markSeen moves seenAt
	triage.markSeen(s, "prs", q, now)
	assert(s.items["o/r#9"].seenAt == now)
	triage.snooze(s, "prs", q, now + 500, now + 50)
	assert(s.items["o/r#9"].seenAt == now and s.items["o/r#9"].at == now + 50)
	triage.unsnooze(s, "o/r#9")
	triage.markSeen(s, "prs", q, now + 60)
	assert(s.items["o/r#9"].seenAt == now + 60)

	-- tomorrow: next calendar day at local 08:00, strictly later
	local t = triage.tomorrow(now)
	local d0 = os.date("*t", now) :: any
	local d1 = os.date("*t", t) :: any
	assert(t > now and d1.hour == 8 and d1.min == 0 and d1.sec == 0)
	assert(os.time({ year = d1.year, month = d1.month, day = d1.day - 1, hour = 12 }) == os.time({ year = d0.year, month = d0.month, day = d0.day, hour = 12 }))
	assert(triage.tomorrow(now) == t, "deterministic")

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
	-- entries written before seenAt existed still load; a malformed seenAt does not
	assert(triage.validate({ version = 1, items = { a = { at = 1, seen = "s", snoozeUntil = 2 } } }) == nil)
	assert(triage.validate({ version = 1, items = { a = { at = 1, seen = "s", seenAt = "x" } } }) ~= nil)
	-- a seen or snoozeSig longer than 64 is malformed, exactly 64 is not
	assert(triage.validate({ version = 1, items = { a = { at = 1, seen = string.rep("x", 65) } } }) ~= nil)
	assert(triage.validate({ version = 1, items = { a = { at = 1, snoozeSig = string.rep("x", 65) } } }) ~= nil)
	assert(triage.validate({ version = 1, items = { a = { at = 1, seen = string.rep("x", 64), snoozeSig = string.rep("x", 64) } } }) == nil)
	-- items as a JSON array (integer keys) is malformed
	assert(triage.validate({ version = 1, items = { { at = 1 } } }) ~= nil)
	assert(triage.validate({ version = 2, items = {} }) == "Saved triage state is from a newer Plotroom; not overwriting it.")
	assert(triage.validate({ version = "2", items = {} }) == "Saved triage state is malformed; not overwriting it.")

	-- an item whose key fails sanitizeKey is never recorded or snoozed
	local nk = triage.empty()
	for _, bad in { "a\nb", "" } do
		local unkeyed = pr({ key = bad })
		triage.markSeen(nk, "prs", unkeyed, now)
		triage.snooze(nk, "prs", unkeyed, now + 100, now)
		assert(next(nk.items) == nil, "no entry for an unkeyed item")
		assert(triage.status(nk, "prs", unkeyed, now).fresh == "new")
		assert(not triage.snoozed(nk, "prs", unkeyed, now) and triage.snoozeEnd(nk, unkeyed, now) == nil)
	end
	local nokey = pr()
	nokey.key = nil
	triage.markSeen(nk, "prs", nokey, now)
	assert(next(nk.items) == nil, "no entry for an item without a key")

	-- snoozeEnd: the clock end while a snooze runs, nil before one is set, after it ends, and once unsnoozed;
	-- an item changed since the snooze still reports it (only the signature is skipped)
	local se = triage.empty()
	local sp = pr({ key = "o/r#20" })
	assert(triage.snoozeEnd(se, sp, now) == nil)
	triage.markSeen(se, "prs", sp, now)
	triage.snooze(se, "prs", sp, now + 100, now)
	assert(triage.snoozeEnd(se, sp, now) == now + 100)
	assert(triage.snoozeEnd(se, sp, now + 100) == nil, "ends at the time")
	local sc = pr({ key = "o/r#20", checks = "FAILURE" })
	assert(triage.snoozeEnd(se, sc, now) == now + 100, "snoozeEnd ignores the signature")
	-- seen + changed + snoozed: the snooze is over (the item changed), but it still reads changed
	local stc = triage.status(se, "prs", sc, now)
	assert(stc.fresh == "changed" and not stc.snoozed and stc.snoozeUntil == nil)
	assert(not triage.snoozed(se, "prs", sc, now))
	local stu = triage.status(se, "prs", sp, now)
	assert(stu.fresh == "seen" and stu.snoozed and stu.snoozeUntil == now + 100)
	triage.unsnooze(se, "o/r#20")
	assert(triage.snoozeEnd(se, sp, now) == nil)

	-- prune: equal `at` falls back to the key, smaller key dropped first
	local tie = triage.empty()
	for n = 1, triage.CAP + 2 do
		tie.items[string.format("k%05d", n)] = { at = 7 }
	end
	triage.prune(tie, now)
	assert(tie.items["k00001"] == nil and tie.items["k00002"] == nil and tie.items["k00003"] ~= nil)
	-- a snooze that has run out is no longer protected from pruning
	local lapsed = triage.empty()
	for n = 1, triage.CAP + 1 do
		lapsed.items["k" .. n] = { at = n + 10 }
	end
	lapsed.items["old"] = { at = 1, snoozeUntil = now - 1 }
	triage.prune(lapsed, now)
	assert(lapsed.items["old"] == nil, "an ended snooze is pruned by age")

	-- signatures: every field the item kind lists moves it, and only those
	local base = pr()
	local sig = triage.signature("prs", base)
	for _, over in ({
		{ draft = true }, { files = 4 }, { runTotal = 3 }, { comments = 2 }, { additions = 9 }, { labels = { "a" } },
		{ assignees = { "me" } }, { headSha = "def" }, { state = "MERGED" },
	} :: { { [string]: any } }) do
		assert(triage.signature("prs", pr(over)) ~= sig, "pr signature moves")
	end
	assert(triage.signature("prs", pr({ updated = "2027-01-01" })) == sig, "a PR's updated is not part of its signature")
	local ib: { [string]: any } = { key = "o/r#7", state = "open", title = "x", status = { text = "To Do" }, updated = 0 }
	local function issue(over: { [string]: any }): { [string]: any }
		local t = table.clone(ib)
		for k, v in over do
			t[k] = v
		end
		return t
	end
	local isig = triage.signature("issues", ib)
	for _, over in ({
		{ comments = 2 }, { labels = { "bug" } }, { assignees = { "me" } }, { category = "done" }, { reason = "r" }, { updated = 5 },
	} :: { { [string]: any } }) do
		assert(triage.signature("issues", issue(over)) ~= isig, "issue signature moves")
	end
	assert(triage.signature("issues", issue({ labels = { "b", "a" } })) == triage.signature("issues", issue({ labels = { "a", "b" } })))
end

return M
