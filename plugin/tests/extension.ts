// Runs Plotroom's omp extension (plugin/omp/plotroom.ts) over the fixtures it shares with its Luau readers
// (tests/extension.luau, which says what they hold): `python3 scripts/check.py ext`, with bun or node >= 23.6. Both
// tools are called the way omp calls them, through the extension's default export with a fake ExtensionAPI. Prints
// `EXT cases=N failed=M` and exits 1 on a failure.
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import plotroom, { DONE, validate, validateReport, write } from "../omp/plotroom.ts";

type Case = { name: string; input: unknown; out?: unknown; read?: unknown; refused?: string };
type Result = { content: { type: string; text: string }[]; isError?: boolean; details?: unknown };
type Execute = (id: string, params: unknown) => Promise<Result>;

// The fixture's shorthands, as tests/extension.luau describes them.
function expand(v: unknown, i = 0): unknown {
	if (typeof v === "string") return i ? v.replaceAll("{i}", String(i)) : v;
	if (Array.isArray(v)) return v.map(x => expand(x, i));
	if (v === null || typeof v !== "object") return v;
	const o = v as Record<string, unknown>;
	if ("$" in o) return (o.$ as unknown[]).map(p => (Array.isArray(p) ? (p[0] as string).repeat(p[1] as number) : p)).join("");
	if ("$list" in o) return Array.from({ length: o.$list as number }, (_, k) => expand(o.of, k + 1));
	return Object.fromEntries(Object.entries(o).map(([k, x]) => [k, expand(x, i)]));
}

const source = fs.readFileSync(new URL("./extension.luau", import.meta.url), "utf8");
const fixtures = expand(JSON.parse(source.slice(source.indexOf("[==[") + 4, source.lastIndexOf("]==]")))) as {
	limits: { file: number; reportText: number };
	reports: Case[];
	proposals: Case[];
};
const { limits } = fixtures;

const data = fs.mkdtempSync(path.join(os.tmpdir(), "plotroom-ext-"));
const file = path.join(data, "runs", "r1", "review.json");
process.env.PLOTROOM_RUN = "r1";
process.env.PLOTROOM_DATA = data;
// omp's zod: only chained to build the tools' parameter schemas, which the tools check again themselves. The fake API
// has only what the extension calls, so it is cast to omp's ExtensionAPI.
const z: object = new Proxy(function () {}, { get: () => z, apply: () => z });
const tools: Record<string, Execute> = {};
const api = { zod: z, registerTool: (t: { name: string; execute: Execute }) => void (tools[t.name] = t.execute) };
plotroom(api as unknown as Parameters<typeof plotroom>[0]);

let cases = 0;
let failed = 0;
async function check(name: string, fn: () => Promise<void> | void) {
	cases++;
	try {
		await fn();
	} catch (e) {
		failed++;
		console.log(`FAIL ${name}\n${e instanceof Error ? e.message : String(e)}\n`);
	}
}

try {
	await check("both tools are registered", () => assert.deepEqual(Object.keys(tools).sort(), ["plotroom_propose_review", "plotroom_report"]));

	for (const c of fixtures.reports) {
		await check(`plotroom_report: ${c.name}`, async () => {
			const r = await tools.plotroom_report("t", c.input);
			if (c.refused !== undefined) {
				assert.throws(() => validateReport(c.input), { message: c.refused });
				assert.deepEqual(r, { content: [{ type: "text", text: `Not reported: ${c.refused}. Fix it and call plotroom_report again.` }], isError: true });
				return;
			}
			assert.deepEqual(validateReport(c.input), c.out);
			assert.deepEqual(r.details, c.out);
			const text = r.content[0].text;
			// The window decodes the text's first line (flows' turnReport) and reads at most `reportText` bytes of it.
			assert.deepEqual(JSON.parse(text.split("\n")[0]), c.out);
			assert.ok(Buffer.byteLength(text) <= limits.reportText, `the result text is ${Buffer.byteLength(text)} bytes, over ${limits.reportText}`);
		});
	}

	for (const c of fixtures.proposals) {
		await check(`plotroom_propose_review: ${c.name}`, async () => {
			fs.rmSync(file, { force: true });
			const r = await tools.plotroom_propose_review("t", c.input);
			if (c.refused !== undefined) {
				assert.throws(() => validate(c.input), { message: c.refused });
				assert.deepEqual(r, { content: [{ type: "text", text: `Not proposed: ${c.refused}. Fix it and call plotroom_propose_review again.` }], isError: true });
				assert.ok(!fs.existsSync(file), "a refused proposal writes no file");
				return;
			}
			assert.deepEqual(validate(c.input), c.out);
			assert.deepEqual(r, { content: [{ type: "text", text: DONE }] });
			const raw = fs.readFileSync(file);
			assert.ok(raw.length <= limits.file, `the file is ${raw.length} bytes, over ${limits.file}`);
			const { version, run, at, ...rest } = JSON.parse(raw.toString("utf8"));
			assert.deepEqual({ version, run }, { version: 1, run: "r1" });
			assert.match(at, /^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z$/);
			assert.deepEqual(rest, c.out);
		});
	}

	await check("write: a file of exactly `file` bytes is written, one byte more is refused", () => {
		const p = { repo: "o/r", number: 1, head: "abc1234", summary: "", verdict: "comment" as const, comments: [] };
		const now = new Date(0);
		const room = limits.file - fs.statSync(write(data, "r2", p, now)).size;
		assert.equal(fs.statSync(write(data, "r2", { ...p, summary: "a".repeat(room) }, now)).size, limits.file);
		assert.throws(() => write(data, "r2", { ...p, summary: "a".repeat(room + 1) }, now), { message: `the proposal is over ${limits.file} bytes as written; shorten it` });
	});
} finally {
	fs.rmSync(data, { recursive: true, force: true });
}

console.log(`EXT cases=${cases} failed=${failed}`);
if (failed > 0) process.exit(1);
