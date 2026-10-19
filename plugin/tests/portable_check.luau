--!strict
-- Assertions over portable.luau: export, strict import, plan and apply. Pure: no kv, network or git.

local portable = require("../portable")

local M = {}

local function existing(): portable.Existing
	return {
		prs = { views = { items = {}, nextId = 1 }, prompts = { items = {}, nextId = 1 } },
		issues = { views = { items = {}, nextId = 1 }, prompts = { items = {}, nextId = 1 } },
	}
end

local ok: portable.Ok = {
	sortValid = function(_kind: string, _integration: string, sort: string): boolean
		return sort == "updated"
	end,
	integrationOn = function(_id: string): boolean
		return true
	end,
	reserved = {},
}

local function prompt(id: string, name: string, text: string, key: string?): portable.ExPrompt
	return { id = id, kind = "prs", name = name, text = text, key = key }
end

-- A minimal valid export document, changed by `mutate` before it is encoded.
local function doc(mutate: ((any) -> ())?): string
	local d: any = {
		format = "plotroom-export",
		version = 1,
		prompts = tern.json.array({}),
		views = tern.json.array({
			{ kind = "prs", name = "V", integration = "github", query = "is:open", group = "", accounts = tern.json.array({}), prompts = tern.json.array({}) },
		}),
	}
	if mutate then
		mutate(d)
	end
	return tern.json.encode(d)
end

function M.run()
	-- build: secrets and logins stay home
	local views: { portable.ExView } = {
		{ id = "prs:v1", kind = "prs", name = "Mine", integration = "github", query = "is:open", group = "", sort = "updated", logins = { "andyhite", "bob" }, prompts = { "p1", "p2" } },
		{ id = "issues:v1", kind = "issues", name = "Tickets", integration = "jira", query = "project = X", group = "Work", logins = {}, prompts = {} },
	}
	local leaky = prompt("p2", "Leaky", "use ghp_" .. string.rep("a", 36) .. " and password=hunter2")
	local text, notes = portable.build(views, { prompt("p1", "Review", "Review the PR.", "r"), leaky }, nil, { leaky })
	assert(text and #notes > 0, "an export with a leaky action still builds, with a note")
	assert(not string.find(text, "andyhite", 1, true) and not string.find(text, "bob", 1, true), "logins never leave")
	assert(not string.find(text, "ghp_", 1, true) and not string.find(text, "hunter2", 1, true), "secrets never leave")
	assert(string.find(text, "account-1", 1, true) and string.find(text, "account-2", 1, true), "accounts are anonymous slots")
	assert(not portable.build(views, { leaky }, true), "secretFree refuses a leaky action")
	for _, secret in { "ghp_" .. string.rep("a", 36), "github_pat_" .. string.rep("b", 30), "AKIA" .. string.rep("A", 16), "-----BEGIN RSA PRIVATE KEY-----", "Bearer " .. string.rep("x", 30), "password=hunter2" } do
		local t = portable.build({}, { prompt("p9", "S", "x " .. secret) })
		assert(t == nil, "secret excluded: " .. secret)
	end
	assert(portable.build({}, { prompt("p9", "Fine", "Use password={value}.") }), "a placeholder is not a secret")
	local big: { portable.ExPrompt } = {}
	for i = 1, 8 do
		table.insert(big, prompt("p" .. i, "N" .. i, string.rep("y", 8000)))
	end
	assert(portable.build({}, big) == nil, "over the limit builds nothing")

	-- parse -> plan -> apply round trip
	local d = portable.parse(text)
	assert(d and #d.views == 2 and #d.prompts == 1, "the leaky action is not in the document")
	assert(d.views[1].slots[1] == "account-1" and d.views[1].slots[2] == "account-2" and #d.views[1].prompts == 1, "slots and references parsed")
	local empty = existing()
	local plan = portable.plan(d, empty)
	assert(#plan.entries == 3 and #plan.slots == 2, "views then actions, two slots")
	assert(plan.entries[1].conflict == nil and plan.entries[1].remap[1] == "runs as account slot account-1", "the slot is announced")
	local map = { ["account-1"] = "alice", ["account-2"] = "" }
	local out1, notes1 = portable.apply(d, plan, {}, map, empty, ok)
	assert(out1 and out1.prs and out1.issues, "both kinds change")
	local v1 = out1.prs.views.items[1]
	assert(v1.id == "prs:v1" and v1.name == "Mine" and v1.sort == "updated" and #v1.logins == 1 and v1.logins[1] == "alice", "view added with its mapped login")
	assert(out1.prs.prompts.items[1].id == "p1" and v1.prompts[1] == "p1" and out1.prs.prompts.nextId == 2 and out1.prs.views.nextId == 2, "ids advance and references follow")
	assert(out1.issues.views.items[1].id == "issues:v1" and #empty.prs.views.items == 0 and #notes1 == 0, "the input stores are untouched")

	-- fail closed: an unmapped slot skips the view
	local out2, notes2 = portable.apply(d, plan, {}, {}, empty, ok)
	assert(out2 and out2.prs and #out2.prs.views.items == 0 and #out2.prs.prompts.items == 1 and #notes2 == 1, "unmapped slots skip only the view")
	local out2b = portable.apply(d, plan, {}, { ["account-1"] = "a b", ["account-2"] = "" }, empty, ok)
	assert(out2b and out2b.prs and #out2b.prs.views.items == 0, "an invalid login skips the view")

	-- skip / replace / duplicate against what the first import saved
	local saved = out1
	local plan2 = portable.plan(d, saved)
	assert(plan2.entries[1].conflict == "same-name", "a view with slots is never identical")
	assert(plan2.entries[2].conflict == "identical" and plan2.entries[3].conflict == "identical", "same content is identical")
	local out3 = portable.apply(d, plan2, {}, map, saved, ok)
	assert(out3 and next(out3) == nil, "conflicts are skipped by default")
	local rep = portable.apply(d, plan2, { [1] = "replace" }, { ["account-1"] = "carol", ["account-2"] = "carol" }, saved, ok)
	assert(rep and rep.prs and #rep.prs.views.items == 1 and rep.prs.views.items[1].id == "prs:v1", "replace keeps the id")
	assert(#rep.prs.views.items[1].logins == 1 and rep.prs.views.items[1].logins[1] == "carol", "replace updates logins, deduplicated")
	assert(saved.prs.views.items[1].logins[1] == "alice", "replace works on a copy")
	local dup = portable.apply(d, plan2, { [1] = "duplicate" }, map, saved, ok)
	assert(dup and dup.prs and #dup.prs.views.items == 2, "duplicate adds")
	assert(dup.prs.views.items[2].name == "Mine (imported)" and dup.prs.views.items[2].id == "prs:v2" and dup.prs.views.items[2].prompts[1] == "p1", "duplicate is renamed and keeps the existing action")
	local dup2 = portable.apply(d, plan2, { [1] = "duplicate" }, map, dup, ok)
	assert(dup2 and dup2.prs and dup2.prs.views.items[3].name == "Mine (imported 2)", "duplicate names stay unique")
	local repPrompt = portable.apply(d, plan2, { [3] = "duplicate" }, map, saved, ok)
	assert(repPrompt and repPrompt.prs and repPrompt.prs.prompts.items[2].name == "Review (imported)" and repPrompt.prs.prompts.items[2].key == nil, "a duplicated action loses a shortcut already in use")

	-- views refused by the host's rules
	local off: portable.Ok = { sortValid = ok.sortValid, integrationOn = function(id: string): boolean return id ~= "jira" end, reserved = {} }
	local outOff, notesOff = portable.apply(d, plan, {}, map, empty, off)
	assert(outOff and outOff.issues == nil and #notesOff == 1, "an integration that is off skips its view")
	local badSort = portable.parse(doc(function(x: any)
		x.views[1].sort = "nope"
	end))
	assert(badSort, "an unknown sort still parses")
	local badPlan = portable.plan(badSort, empty)
	local outSort, notesSort = portable.apply(badSort, badPlan, {}, {}, empty, ok)
	assert(outSort and next(outSort) == nil and #notesSort == 1, "an invalid sort skips the view")

	-- shortcut collisions and reserved keys
	local keyed = portable.parse(portable.build({}, { prompt("p1", "Review", "Review.", "r"), prompt("p2", "Quit", "Bye.", "q") }) or "")
	assert(keyed, "keyed actions parse")
	local taken = existing()
	table.insert(taken.prs.prompts.items, { id = "p6", name = "Other", text = "x", key = "r" })
	taken.prs.prompts.nextId = 7
	portable.reservedKeys = { q = true }
	local keyPlan = portable.plan(keyed, taken)
	portable.reservedKeys = {}
	assert(keyPlan.entries[1].remap[1] == "shortcut r removed: already used by Other", "an action's shortcut collision is announced")
	assert(string.find(keyPlan.entries[2].remap[1], "shortcut q removed", 1, true), "a reserved key is announced")
	local keyOut = portable.apply(keyed, keyPlan, {}, {}, taken, { sortValid = ok.sortValid, integrationOn = ok.integrationOn, reserved = { q = true } })
	local added = keyOut and keyOut.prs and keyOut.prs.prompts.items
	assert(added and added[2].id == "p7" and added[2].key == nil and added[3].id == "p8" and added[3].key == nil, "colliding shortcuts are dropped, ids are fresh")

	-- an action id is remapped in the view that lists it
	local linked = portable.parse(doc(function(x: any)
		x.prompts = tern.json.array({ { id = "prs:p1", kind = "prs", name = "Act", text = "Do it." } })
		x.views[1].prompts = tern.json.array({ "prs:p1" })
	end))
	assert(linked, "a linked export parses")
	local linkedOut = portable.apply(linked, portable.plan(linked, taken), {}, {}, taken, ok)
	assert(linkedOut and linkedOut.prs and linkedOut.prs.views.items[1].prompts[1] == "p7", "the view lists the action's new id")

	-- strict parse
	assert(portable.parse(doc()), "the base document parses")
	assert(not portable.parse(string.rep("x", portable.LIMIT + 1)), "oversize")
	assert(not portable.parse("not json"), "not JSON")
	assert(not portable.parse(tern.json.encode({ format = "other", version = 1 })), "wrong format")
	assert(not portable.parse(doc(function(x: any)
		x.version = 2
	end)), "wrong version")
	assert(not portable.parse(doc(function(x: any)
		x.views[1].setup = "make"
	end)), "a setup field")
	assert(not portable.parse(doc(function(x: any)
		x.views[1].extra = { Path = "/tmp" }
	end)), "a nested path field")
	for _, field in { "checkout", "token", "secret" } do
		assert(not portable.parse(doc(function(x: any)
			x.views[1][field] = "v"
		end)), "a " .. field .. " field")
	end
	assert(not portable.parse(doc(function(x: any)
		x.views[1].name = "a\nb"
	end)), "control character in a name")
	assert(not portable.parse(doc(function(x: any)
		x.views[1].query = "a\nb"
	end)), "a multiline query")
	assert(not portable.parse(doc(function(x: any)
		x.views[1].kind = "boards"
	end)), "unknown kind")
	assert(not portable.parse(doc(function(x: any)
		x.views[1].integration = "gitlab"
	end)), "unknown integration")
	local _, why = portable.parse(doc(function(x: any)
		x.views[1].integration = "jira"
	end))
	assert(why and string.find(why, "pull request views are GitHub views", 1, true), "a pull request view on Jira is refused")
	local mixed, mixedNotes = portable.build({ { id = "prs:v2", kind = "prs", name = "Bad", integration = "jira", query = "", group = "", logins = {}, prompts = {} } }, {})
	assert(mixed == nil and #mixedNotes > 0, "build leaves out a pull request view on Jira")
	assert(not portable.parse(doc(function(x: any)
		x.views[1].name = string.rep("n", 121)
	end)), "name over the cap")
	assert(not portable.parse(doc(function(x: any)
		x.prompts = tern.json.array({ { id = "prs:p1", kind = "prs", name = "A", text = "t", key = "ab" } })
	end)), "a two-character shortcut")
	assert(not portable.parse(doc(function(x: any)
		x.prompts = tern.json.array({ { id = "prs:p1", kind = "prs", name = "A", text = string.rep("t", 8001) } })
	end)), "text over the cap")
	assert(not portable.parse(doc(function(x: any)
		x.views[1].prompts = tern.json.array({ "prs:p9" })
	end)), "a dangling action reference")
	assert(not portable.parse(doc(function(x: any)
		local many: { any } = {}
		for i = 1, 101 do
			table.insert(many, { kind = "prs", name = "V" .. i, integration = "github", query = "", group = "" })
		end
		x.views = tern.json.array(many)
	end)), "too many views")
	local ignored = portable.parse(doc(function(x: any)
		x.views[1].color = "red"
	end))
	assert(ignored and (ignored.views[1] :: any).color == nil, "unknown keys are dropped")

	-- an issue action's status survives export and import, and only an issue action may have one
	local moving: portable.ExPrompt = { id = "p1", kind = "issues", name = "Fix", text = "Fix it.", status = "In Review" }
	local moved = portable.parse(portable.build({}, { moving }) or "")
	assert(moved and moved.prompts[1].status == "In Review", "the status is exported and parsed")
	local movedOut = portable.apply(moved, portable.plan(moved, empty), {}, {}, empty, ok)
	assert(movedOut and movedOut.issues and movedOut.issues.prompts.items[1].status == "In Review", "and saved")
	assert(portable.plan(moved, movedOut).entries[1].conflict == "identical", "a saved status makes the same action identical")
	local other = portable.parse(portable.build({}, { { id = "p1", kind = "issues", name = "Fix", text = "Fix it." } }) or "")
	assert(other and portable.plan(other, movedOut).entries[1].conflict == "same-name", "another status is a different action")
	assert(portable.build({}, { { id = "p1", kind = "prs", name = "R", text = "Review.", status = "Done" } }) == nil, "a pull request action has no status")
	assert(not portable.parse(doc(function(x: any)
		x.prompts = tern.json.array({ { id = "issues:p1", kind = "issues", name = "A", text = "t", status = string.rep("s", portable.STATUS_CAP + 1) } })
	end)), "a status over the cap")
end

return M
