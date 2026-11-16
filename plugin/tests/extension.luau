--!strict
-- The fixtures Plotroom's omp extension (plugin/omp/plotroom.ts) and its Luau readers are both checked against, as one
-- JSON text: tests/extension.ts (`python3 scripts/check.py ext`) runs the extension's tools on every `input` and
-- expects exactly `out`, or the refusal `refused`; tests/cases/extension.luau feeds every `out` to the reader
-- (usage.reportOf for plotroom_report, host/review's parse for the Draft review file) and expects the same values, or
-- `read`'s where the reader cuts further (its caps are bytes, the extension's UTF-16 units). `limits` are the largest
-- Draft review file the block reads and the largest report text the window reads: the extension must stay under them,
-- and each reader must take exactly that much.
-- Two shorthands, expanded on both sides: {"$": [part, ...]} is the string of its parts, each a string or
-- [string, times]; {"$list": n, "of": x} is a list of n copies of x, with "{i}" in its strings replaced by 1..n.
return [==[
{
	"limits": { "file": 8000000, "reportText": 65536 },
	"reports": [
		{
			"name": "a report with every field keeps its commit in lower case",
			"input": { "attention": "ok", "reason": "Fixed the parser", "commit": "ABCDEF0123456789ABCDEF0123456789ABCDEF01", "pr": "https://github.com/o/r/pull/5", "evidence": ["python3 scripts/check.py test"], "blocker": null },
			"out": { "attention": "ok", "reason": "Fixed the parser", "commit": "abcdef0123456789abcdef0123456789abcdef01", "pr": "https://github.com/o/r/pull/5", "evidence": ["python3 scripts/check.py test"], "blocker": null }
		},
		{
			"name": "a checker's report keeps check and findings",
			"input": { "attention": "needs-human", "reason": "One criterion fails", "commit": null, "pr": null, "evidence": [], "blocker": null, "check": "fail", "findings": ["101 comments are proposed: ran extension.ts"] },
			"out": { "attention": "needs-human", "reason": "One criterion fails", "commit": null, "pr": null, "evidence": [], "blocker": null, "check": "fail", "findings": ["101 comments are proposed: ran extension.ts"] }
		},
		{
			"name": "a line is cut to 200 UTF-16 units, never inside a non-BMP character",
			"input": { "attention": "stuck", "reason": { "$": ["🎉 ", ["a", 196], "😀 tail"] }, "commit": null, "pr": null, "evidence": [{ "$": [["b", 199], "🎉 x"] }], "blocker": { "$": [["c", 199], "😀"] } },
			"out": { "attention": "stuck", "reason": { "$": ["🎉 ", ["a", 196]] }, "commit": null, "pr": null, "evidence": [{ "$": [["b", 199]] }], "blocker": { "$": [["c", 199]] } },
			"read": { "reason": { "$": ["🎉 ", ["a", 195]] } }
		},
		{
			"name": "control characters become spaces, blank lines are dropped and 20 are kept",
			"input": { "attention": "ok", "reason": "\tDone\nnow ", "commit": null, "pr": null, "evidence": { "$list": 21, "of": "e{i}" }, "blocker": " ", "findings": ["a\u0007b", "  ", ""] },
			"out": { "attention": "ok", "reason": "Done now", "commit": null, "pr": null, "evidence": { "$list": 20, "of": "e{i}" }, "blocker": null, "findings": ["a b"] }
		},
		{
			"name": "the largest report",
			"input": {
				"attention": "stuck",
				"reason": { "$": [["字", 200]] },
				"commit": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
				"pr": { "$": ["https://github.com/", ["a", 481]] },
				"evidence": { "$list": 20, "of": { "$": [["字", 200]] } },
				"blocker": { "$": [["字", 200]] },
				"check": "fail",
				"findings": { "$list": 20, "of": { "$": [["字", 200]] } }
			},
			"out": {
				"attention": "stuck",
				"reason": { "$": [["字", 200]] },
				"commit": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
				"pr": { "$": ["https://github.com/", ["a", 481]] },
				"evidence": { "$list": 20, "of": { "$": [["字", 200]] } },
				"blocker": { "$": [["字", 200]] },
				"check": "fail",
				"findings": { "$list": 20, "of": { "$": [["字", 200]] } }
			},
			"read": {
				"reason": { "$": [["字", 66]] },
				"evidence": { "$list": 20, "of": { "$": [["字", 66]] } },
				"blocker": { "$": [["字", 66]] },
				"findings": { "$list": 20, "of": { "$": [["字", 66]] } }
			}
		},
		{
			"name": "an unknown attention",
			"input": { "attention": "done", "reason": "Done", "commit": null, "pr": null, "evidence": [], "blocker": null },
			"refused": "attention must be one of ok, stuck, needs-human"
		},
		{
			"name": "a lone surrogate",
			"input": { "attention": "ok", "reason": "a\ud800b", "commit": null, "pr": null, "evidence": [], "blocker": null },
			"refused": "reason holds a broken character (a lone UTF-16 surrogate)"
		},
		{
			"name": "a blank reason",
			"input": { "attention": "ok", "reason": " \n ", "commit": null, "pr": null, "evidence": [], "blocker": null },
			"refused": "reason must be one line of text"
		},
		{
			"name": "a short commit",
			"input": { "attention": "ok", "reason": "Done", "commit": "abc1234", "pr": null, "evidence": [], "blocker": null },
			"refused": "commit must be a full commit SHA, or null"
		},
		{
			"name": "a pull request URL over 500 characters",
			"input": { "attention": "ok", "reason": "Done", "commit": null, "pr": { "$": ["https://github.com/", ["a", 482]] }, "evidence": [], "blocker": null },
			"refused": "pr must be a pull request URL, or null"
		},
		{
			"name": "evidence that is no list of strings",
			"input": { "attention": "ok", "reason": "Done", "commit": null, "pr": null, "evidence": [1], "blocker": null },
			"refused": "evidence must be a list of strings"
		}
	],
	"proposals": [
		{
			"name": "a proposal with every field keeps its head in lower case and drops unknown fields and a null startLine",
			"input": {
				"repo": "o/r", "number": 5, "head": "ABC1234", "summary": "Two problems.", "verdict": "request_changes", "extra": true,
				"comments": [
					{ "id": "c1", "path": "src/a.lua", "line": 3, "startLine": null, "side": "RIGHT", "kind": "problem", "body": "z is unused", "note": "x" },
					{ "id": "c-2_b", "path": "docs/read me.md", "line": 12, "startLine": 10, "side": "LEFT", "kind": "suggestion", "body": "Keep\tthis", "suggestion": "line 1\nline 2" }
				]
			},
			"out": {
				"repo": "o/r", "number": 5, "head": "abc1234", "summary": "Two problems.", "verdict": "request_changes",
				"comments": [
					{ "id": "c1", "path": "src/a.lua", "line": 3, "side": "RIGHT", "kind": "problem", "body": "z is unused" },
					{ "id": "c-2_b", "path": "docs/read me.md", "line": 12, "startLine": 10, "side": "LEFT", "kind": "suggestion", "body": "Keep\tthis", "suggestion": "line 1\nline 2" }
				]
			}
		},
		{
			"name": "a 20000-unit summary of 3-byte characters",
			"input": { "repo": "o/r", "number": 5, "head": "abc1234", "summary": { "$": [["字", 20000]] }, "verdict": "comment", "comments": [] },
			"out": { "repo": "o/r", "number": 5, "head": "abc1234", "summary": { "$": [["字", 20000]] }, "verdict": "comment", "comments": [] }
		},
		{
			"name": "a 20001-unit summary",
			"input": { "repo": "o/r", "number": 5, "head": "abc1234", "summary": { "$": [["a", 20001]] }, "verdict": "comment", "comments": [] },
			"refused": "summary is longer than 20000 characters"
		},
		{
			"name": "100 comments",
			"input": { "repo": "o/r", "number": 5, "head": "abc1234", "summary": "", "verdict": "comment", "comments": { "$list": 100, "of": { "id": "c{i}", "path": "src/a.lua", "line": 3, "side": "RIGHT", "kind": "nit", "body": "Nit {i}" } } },
			"out": { "repo": "o/r", "number": 5, "head": "abc1234", "summary": "", "verdict": "comment", "comments": { "$list": 100, "of": { "id": "c{i}", "path": "src/a.lua", "line": 3, "side": "RIGHT", "kind": "nit", "body": "Nit {i}" } } }
		},
		{
			"name": "101 comments",
			"input": { "repo": "o/r", "number": 5, "head": "abc1234", "summary": "", "verdict": "comment", "comments": { "$list": 101, "of": { "id": "c{i}", "path": "src/a.lua", "line": 3, "side": "RIGHT", "kind": "nit", "body": "Nit {i}" } } },
			"refused": "at most 100 comments"
		},
		{
			"name": "a lone surrogate in a comment",
			"input": { "repo": "o/r", "number": 5, "head": "abc1234", "summary": "", "verdict": "comment", "comments": [{ "id": "c1", "path": "src/a.lua", "line": 3, "side": "RIGHT", "kind": "problem", "body": "a\udc00" }] },
			"refused": "comments[0].body holds a broken character (a lone UTF-16 surrogate)"
		},
		{
			"name": "a \".\" path segment",
			"input": { "repo": "o/r", "number": 5, "head": "abc1234", "summary": "", "verdict": "comment", "comments": [{ "id": "c1", "path": "src/./a.lua", "line": 3, "side": "RIGHT", "kind": "problem", "body": "x" }] },
			"refused": "comments[0].path must not hold an empty, \".\" or \"..\" segment"
		},
		{
			"name": "a startLine after its line",
			"input": { "repo": "o/r", "number": 5, "head": "abc1234", "summary": "", "verdict": "comment", "comments": [{ "id": "c1", "path": "src/a.lua", "line": 3, "startLine": 4, "side": "RIGHT", "kind": "problem", "body": "x" }] },
			"refused": "comments[0].startLine must not be after line"
		},
		{
			"name": "a head of 6 hex digits",
			"input": { "repo": "o/r", "number": 5, "head": "abc123", "summary": "", "verdict": "comment", "comments": [] },
			"refused": "head must be the reviewed head commit's SHA"
		},
		{
			"name": "a head of 65 hex digits",
			"input": { "repo": "o/r", "number": 5, "head": { "$": [["a", 65]] }, "summary": "", "verdict": "comment", "comments": [] },
			"refused": "head is longer than 64 characters"
		},
		{
			"name": "the largest proposal: every text at its cap in 3-byte characters",
			"input": {
				"repo": "o/r", "number": 10000000, "head": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "summary": { "$": [["字", 20000]] }, "verdict": "approve",
				"comments": { "$list": 100, "of": { "id": "c{i}", "path": { "$": [["字", 1000]] }, "line": 10000000, "startLine": 1, "side": "LEFT", "kind": "nit", "body": { "$": [["字", 10000]] }, "suggestion": { "$": [["字", 10000]] } } }
			},
			"out": {
				"repo": "o/r", "number": 10000000, "head": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "summary": { "$": [["字", 20000]] }, "verdict": "approve",
				"comments": { "$list": 100, "of": { "id": "c{i}", "path": { "$": [["字", 1000]] }, "line": 10000000, "startLine": 1, "side": "LEFT", "kind": "nit", "body": { "$": [["字", 10000]] }, "suggestion": { "$": [["字", 10000]] } } }
			}
		}
	]
}
]==]
