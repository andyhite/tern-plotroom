// Plotroom's omp extension. Plotroom starts every agent it runs as
//   PLOTROOM_RUN=<run id> PLOTROOM_DATA=<Plotroom's data directory> omp -e <this file> …
// so only those agents load it; nothing is installed into omp. Without both variables it registers nothing.
//
// Tool `plotroom_propose_review` writes the agent's proposed review, validated, to
//   <PLOTROOM_DATA>/runs/<PLOTROOM_RUN>/review.json
// replacing the file on every call (a revised proposal), for Plotroom's Draft review block to read. The file is one
// JSON object (docs/reference.md › Dispatch › Draft review file):
//   version   1
//   run       the run id (PLOTROOM_RUN)
//   at        when it was written, ISO 8601 UTC
//   repo      "owner/name" of the pull request
//   number    the pull request's number
//   head      the head commit SHA the agent reviewed
//   summary   the review's body (may be "")
//   verdict   "comment" | "approve" | "request_changes"
//   comments  [{ id, path, line, startLine?, side, kind, body, suggestion? }] (at most 100):
//     id          unique within the proposal, letters, digits, "_" and "-" (at most 64)
//     path        repository-relative file path, "/"-separated, no "." or ".." segment
//     line        the (last) line commented on, 1-based; startLine (optional) the first line of a range, <= line
//     side        "RIGHT" (the head's lines) | "LEFT" (the base's lines)
//     kind        "problem" | "question" | "suggestion" | "nit"
//     body        the comment's text; suggestion (optional) replacement text for the lines, without fences
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import * as fs from "node:fs";
import * as path from "node:path";

const SUMMARY_CAP = 20000;
const BODY_CAP = 10000;
const PATH_CAP = 1000;
const COMMENTS_CAP = 100;
const LINE_CAP = 10_000_000;

export const VERDICTS = ["comment", "approve", "request_changes"] as const;
export const SIDES = ["RIGHT", "LEFT"] as const;
export const KINDS = ["problem", "question", "suggestion", "nit"] as const;

export const DONE = "Plotroom opened this Draft review beside you. End your turn now; the user's choices arrive as the next message.";

export type Comment = {
	id: string;
	path: string;
	line: number;
	startLine?: number;
	side: (typeof SIDES)[number];
	kind: (typeof KINDS)[number];
	body: string;
	suggestion?: string;
};
export type Proposal = {
	repo: string;
	number: number;
	head: string;
	summary: string;
	verdict: (typeof VERDICTS)[number];
	comments: Comment[];
};

// Control characters other than tab and newline: never part of a review's text.
const CONTROL = /[\u0000-\u0008\u000b-\u001f\u007f]/;

function text(v: unknown, what: string, cap: number): string {
	if (typeof v !== "string") throw new Error(`${what} must be a string`);
	if (v.length > cap) throw new Error(`${what} is longer than ${cap} characters`);
	if (CONTROL.test(v)) throw new Error(`${what} holds a control character`);
	return v;
}

function count(v: unknown, what: string): number {
	if (typeof v !== "number" || !Number.isInteger(v) || v < 1 || v > LINE_CAP) throw new Error(`${what} must be a positive whole number`);
	return v;
}

function oneOf<T extends string>(v: unknown, what: string, allowed: readonly T[]): T {
	if (typeof v !== "string" || !(allowed as readonly string[]).includes(v)) throw new Error(`${what} must be one of ${allowed.join(", ")}`);
	return v as T;
}

function relPath(v: unknown, what: string): string {
	const p = text(v, what, PATH_CAP);
	if (p === "" || p.startsWith("/") || p.includes("\\") || /[\n\t]/.test(p)) throw new Error(`${what} must be a relative path with "/" separators`);
	for (const seg of p.split("/")) {
		if (seg === "" || seg === "." || seg === "..") throw new Error(`${what} must not hold an empty, "." or ".." segment`);
	}
	return p;
}

// The proposal as the file stores it, or an Error naming the first thing wrong. Unknown fields are dropped.
export function validate(input: unknown): Proposal {
	if (typeof input !== "object" || input === null) throw new Error("the input must be an object");
	const o = input as Record<string, unknown>;
	const repo = text(o.repo, "repo", 200);
	if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) throw new Error('repo must be "owner/name"');
	const head = text(o.head, "head", 64);
	if (!/^[0-9a-f]{7,64}$/i.test(head)) throw new Error("head must be the reviewed head commit's SHA");
	if (!Array.isArray(o.comments)) throw new Error("comments must be a list");
	if (o.comments.length > COMMENTS_CAP) throw new Error(`at most ${COMMENTS_CAP} comments`);
	const seen = new Set<string>();
	const comments = o.comments.map((raw, i): Comment => {
		const at = `comments[${i}]`;
		if (typeof raw !== "object" || raw === null) throw new Error(`${at} must be an object`);
		const c = raw as Record<string, unknown>;
		const id = text(c.id, `${at}.id`, 64);
		if (!/^[\w-]+$/.test(id)) throw new Error(`${at}.id must be letters, digits, "_" or "-"`);
		if (seen.has(id)) throw new Error(`${at}.id "${id}" is used twice`);
		seen.add(id);
		const line = count(c.line, `${at}.line`);
		const startLine = c.startLine === undefined || c.startLine === null ? undefined : count(c.startLine, `${at}.startLine`);
		if (startLine !== undefined && startLine > line) throw new Error(`${at}.startLine must not be after line`);
		const suggestion = c.suggestion === undefined || c.suggestion === null ? undefined : text(c.suggestion, `${at}.suggestion`, BODY_CAP);
		const out: Comment = {
			id,
			path: relPath(c.path, `${at}.path`),
			line,
			side: oneOf(c.side, `${at}.side`, SIDES),
			kind: oneOf(c.kind, `${at}.kind`, KINDS),
			body: text(c.body, `${at}.body`, BODY_CAP),
		};
		if (startLine !== undefined) out.startLine = startLine;
		if (suggestion !== undefined) out.suggestion = suggestion;
		return out;
	});
	return {
		repo,
		number: count(o.number, "number"),
		head: head.toLowerCase(),
		summary: text(o.summary, "summary", SUMMARY_CAP),
		verdict: oneOf(o.verdict, "verdict", VERDICTS),
		comments,
	};
}

// Writes the proposal for run `run` under data directory `data` and returns the file's path. Written to a temporary
// file first, then renamed over the old one, so a reader never sees half a proposal.
export function write(data: string, run: string, proposal: Proposal, now: Date = new Date()): string {
	const dir = path.join(data, "runs", run);
	fs.mkdirSync(dir, { recursive: true });
	const file = path.join(dir, "review.json");
	const tmp = `${file}.${process.pid}.tmp`;
	fs.writeFileSync(tmp, `${JSON.stringify({ version: 1, run, at: now.toISOString(), ...proposal }, null, "\t")}\n`);
	fs.renameSync(tmp, file);
	return file;
}

export default function plotroom(pi: ExtensionAPI) {
	const run = process.env.PLOTROOM_RUN ?? "";
	const data = process.env.PLOTROOM_DATA ?? "";
	if (!/^[\w-]{1,64}$/.test(run) || !path.isAbsolute(data)) return;
	const z = pi.zod;
	pi.registerTool({
		name: "plotroom_propose_review",
		label: "Plotroom: propose review",
		description:
			"Propose a pull request review to the user instead of posting it. Plotroom shows it as a Draft review beside you, where the user keeps, edits or drops each comment and picks the verdict. Calling it again replaces the proposal. After calling it, end your turn: the user's choices arrive as the next message.",
		parameters: z.object({
			repo: z.string().describe('The pull request\'s repository, "owner/name"'),
			number: z.number().describe("The pull request's number"),
			head: z.string().describe("The head commit SHA you reviewed"),
			summary: z.string().describe("The review's summary (its body); may be empty"),
			verdict: z.enum(VERDICTS).describe("The verdict you propose"),
			comments: z
				.array(
					z.object({
						id: z.string().describe('Unique id within this proposal, e.g. "c1"'),
						path: z.string().describe("Repository-relative file path"),
						line: z.number().describe("The line commented on (the last line of a range), 1-based"),
						startLine: z.number().optional().describe("The first line of a multi-line range"),
						side: z.enum(SIDES).describe("RIGHT: the head's version of the line; LEFT: the base's (a deleted line)"),
						kind: z.enum(KINDS).describe("What the comment is"),
						body: z.string().describe("The comment's text"),
						suggestion: z.string().optional().describe("Replacement text for the lines, without ``` fences"),
					}),
				)
				.describe("Inline comments, at most 100"),
		}),
		async execute(_id: string, params: unknown) {
			try {
				write(data, run, validate(params));
			} catch (e) {
				return { content: [{ type: "text", text: `Not proposed: ${e instanceof Error ? e.message : String(e)}. Fix it and call plotroom_propose_review again.` }], isError: true };
			}
			return { content: [{ type: "text", text: DONE }] };
		},
	});
}
