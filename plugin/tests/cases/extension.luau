--!strict
-- Regression cases: the Luau readers of what Plotroom's omp extension (plugin/omp/plotroom.ts) writes, over the fixtures
-- tests/extension.ts runs the extension on (tests/extension.luau): every output it gives is read back the same.

local h = require("../harness")
local fixtures = require("../extension")

type World = h.World

local array, case, eq, jsonDecode, jsonEncode, same, windowCase, yes = h.array, h.case, h.eq, h.jsonDecode, h.jsonEncode, h.same, h.windowCase, h.yes

-- The fixture's shorthands, as tests/extension.luau describes them. Lists come back tagged as arrays (the fixture has
-- no empty objects), so an empty list compares equal to a decoded one.
local function expand(v: any, i: number?): any
	if type(v) == "string" then
		return if i then (string.gsub(v, "{i}", tostring(i))) else v
	elseif type(v) ~= "table" then
		return v
	elseif v["$"] then
		local parts: { string } = {}
		for _, p in v["$"] do
			table.insert(parts, if type(p) == "table" then string.rep(p[1], p[2]) else p)
		end
		return table.concat(parts)
	elseif v["$list"] then
		local out = {}
		for k = 1, v["$list"] do
			table.insert(out, expand(v.of, k))
		end
		return array(out)
	end
	local out = {}
	for k, x in v do
		out[k] = expand(x, i)
	end
	return if next(v) == nil or v[1] ~= nil then array(out) else out
end

local FIXTURES = jsonDecode(fixtures)

case("extension: the Draft review block reads every proposal plotroom_propose_review writes as written, up to the file limit", function(w: World)
	local review = w.load("host/review") :: any
	eq(review.FILE_BYTES, FIXTURES.limits.file, "the block reads files as large as the extension writes, and no larger")
	local AT = "2026-11-16T10:00:00.000Z"
	for _, c in FIXTURES.proposals do
		if c.out then
			local file = expand(c.out)
			file.version, file.run, file.at = 1, "r1", AT
			local got, why = review.parse(jsonEncode(file))
			yes(got, c.name .. ": read, not refused: " .. tostring(why))
			local want = expand(c.out)
			want.at = AT
			same(expand(got), want, c.name)
		end
	end
end)

windowCase("extension: the run log reads every report plotroom_report gives the same, cut only to its byte caps", function(w: World)
	local usage = w.load("usage") :: any
	eq((w.load("flows") :: any).REPORT_BYTES, FIXTURES.limits.reportText, "the window reads report texts as large as the extension gives")
	for _, c in FIXTURES.reports do
		if c.out then
			local want = expand(c.out)
			for k, v in (c.read or {}) :: { [string]: any } do
				want[k] = expand(v)
			end
			want.findings = want.findings or array({})
			same(expand(usage.reportOf(expand(c.out))), want, c.name)
		end
	end
end)
