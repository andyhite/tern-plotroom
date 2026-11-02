// kata for omp: a port of the hooks `kata agent-hook install` writes for Claude Code and Pi.
// Adds kata's agent contract to the system prompt of every main-agent request. When a
// launcher sets KATA_REF, it also tracks work.attention at session start and end.
let contract; // Fixed for the process; read once.

async function readContract(pi, cwd) {
	try {
		const r = await pi.exec("kata", ["agent-contract-hook"], { cwd, timeout: 10_000 });
		if (r.code === 0) return JSON.parse(r.stdout).hookSpecificOutput?.additionalContext;
	} catch {}
}

export default function kata(pi) {
	pi.on("before_agent_start", async (event, ctx) => {
		if (event.reason !== "prompt" || ctx.agent?.kind === "sub") return;
		contract ??= await readContract(pi, ctx.cwd);
		if (!contract) return ctx.ui?.notify("kata contract unavailable; run kata quickstart --format contract and follow it", "warning");
		return { systemPrompt: [...event.systemPrompt, `<kata_contract>\n${contract}\n</kata_contract>`] };
	});
	if (!process.env.KATA_REF) return;
	const attention = (mode, ctx) =>
		ctx.agent?.kind === "sub" ? undefined : pi.exec("kata", ["agent-hook", "attention", mode], { cwd: ctx.cwd, timeout: 2_000 });
	pi.on("session_start", (_event, ctx) => attention("start", ctx));
	pi.on("session_shutdown", (_event, ctx) => attention("end", ctx));
}
