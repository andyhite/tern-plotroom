# Repository Guidelines

## Project Overview

Tern Plotroom is a [Tern](https://tern.sh) terminal plugin, written in Luau, that renders a live GitHub pull-request queue in one block (`plugin.plotroom.prs`): keyboard triage, Browser docking, and one-key PR worktrees. Data comes from the `gh` CLI (GraphQL) and `git`; there is no server component.

## Architecture & Data Flow

Two Luau runtimes talk through Tern:

- **Host** (`plugin/host.luau`): runs where the block runs (the remote host's daemon for a remote pane). Owns per-pane `State` (module table `running`, keyed by pane), polls GitHub, persists prefs in `tern.kv`, returns a declarative `ui.el`/`ui.node` tree from `view`, and does all checkout work (git, gh, omp) and saved-prompt reads for the window. Registered via `tern.block.define("prs", {init, title, view, key, event, save})`.
- **Window** (`plugin/window.luau`): runs on the machine showing the window, so it never touches a checkout. Registers `tern.route.link` for `plotroom://github/<open|worktree|goto|agent>/<owner>/<repo>/<n>` and `plotroom://github/run/<owner>/<repo>/<n>/<prompt id>` links, `tern.command` ids (`open`, `open-selected`, `worktree-selected`, `goto-selected`, `agent-selected`), reads host nodes by dotted key (the hidden `layer.queue.buttons.<open|worktree|goto|agent|prompt-<id>>` links that mirror the picker's action bar, and the check rows `layer.queue.<required|runs>.run<i>`) via `cx.session:surface`, and only follows a link whose node shows that exact href. Asks the user (pickers, consent) and arranges tabs/agents.
- **Window → host requests** (host section "requests from window.luau", window `ask`/`answered`): window sends `{ev="action", act="rpc", value=JSON{id, op, ...}}` with ops `menu` (saved prompts offered under the active filter) and `worktree`; the host answers in hidden node `main.r<id>` (JSON), renders, then opens `plotroom://rpc/<id>`, which only the asking window acts on. Hidden `main.rpc` holds the protocol version (`RPC_PROTOCOL` in host, `PROTOCOL` in window); bump both together when the request/answer shapes change, since a remote host may run another Plotroom version.
- **Shared helpers** (no cycles): `host → github, input, process, worktree`; `window → worktree`; `worktree → process, github`; `github → process, input`; `process`, `input` have no requires.
  - `github.luau`: `gh` runner, paged GraphQL `search`, `parsePage`/`normalize`/`classify`, account switching, rate-limit quota.
  - `worktree.luau`: repo resolution, worktree create/reuse (`M.open`), `prOfPath`, ref validation.
  - `process.luau`: the single process runner `M.run(argv, opts, done)`; recovers PATH via login shell, always calls `done`, never throws.
  - `input.luau`: pure text model, single-line or `multi` (UTF-16 offsets for the SDK).
- Persistence: `tern.kv` keys `filters`, `prompts`, `repos`, `setup`, `accounts` (host, per machine), `agent-recent` (window). Store changes fan out to other live blocks via `propagate`.
- Settings multi-line text: Tern 0.8.3 `prefs` has no multi-line control, so a prompt's text is an `editor` node inside a `col` child with `role = "omp.prefs.editor"`, which `prefs` draws as a card over the page; keys still reach the block's `key` handler.

## Key Directories

- `plugin/` — the plugin (`plugin.toml` manifest, `*.luau` modules, `plotroom.css`). Everything shipped lives here.
- `plugin/tests/` — `regression.luau` (fake-SDK suite + bench), `check.luau` (pure assert selftest, also runnable in-app), `runtime.luau` (smoke driver against real Tern/git).
- `scripts/` — `check.py` (the verification gate) and `tern-0.8.3.d.luau` (pinned SDK type snapshot, sha256-checked).
- `.github/workflows/check.yml` — CI; `.omp/plans/` — historical design plans (README supersedes them).

## Development Commands

```sh
tern plugin link ./plugin          # install for local use
python3 scripts/check.py tools     # download pinned luau 0.742 + luau-lsp 1.70.1 (macOS / Linux x86_64)
python3 scripts/check.py           # all: test + types + bench + smoke
python3 scripts/check.py test      # regression suite only (also: types | bench | smoke)
python3 scripts/check.py --ci      # what CI runs: smoke reported NOT RUN
tern plugin types plugin           # refresh gitignored plugin/tern.d.luau for editor types
```

Tool lookup order: env `LUAU`/`LUAU_LSP`/`TERN` → `~/.cache/plotroom-check/` (`$XDG_CACHE_HOME`) → PATH. Missing tool = failure, not skip. `PLOTROOM_BENCH_BUDGET_MS` (default 250) caps the slowest bench row. `types` fails on **any** luau-lsp diagnostic, warnings included, over `plugin/*.luau` and `plugin/tests/*.luau`.

## Code Conventions & Common Patterns

- `--!strict` at the top of every module. Modules are `local M = {}` + `function M.x`; `host`/`window` expose only registrations.
- Naming: files lowercase single word; functions/locals camelCase (`loadStore`, `kvSet`); constants SCREAMING_SNAKE (`POLL_MS`, `GH_TIMEOUT_MS`); types PascalCase, `export type` when shared; action/check ids kebab-case (`retry-checks`, `prompt-<id>`); kv keys lowercase words.
- Async is callbacks only, no coroutines. Shape: `done(value?, problem?, cx?)`. `process.run` is the only way to spawn anything.
- Errors are values: `Problem = {kind, message}`, kinds `auth|missing|rate-limit|invalid|not-found|failed|account|superseded` (`github.luau` L10-12). Wrap `tern.kv`/`tern.json` calls in `pcall`; never overwrite unreadable or malformed storage; validate untrusted input at the boundary (`validStore`, `parsePage`, size caps).
- Stale-callback guards are mandatory: check `alive(state)` and `state.gen` in host callbacks; window uses `defer` to fetch a fresh `cx`.
- Security: every command is an argv array (`{"git", "worktree", "add", ...}`); never build shell strings.
- UI: native Tern kinds only (`picker`, `prefs`, `list`/`item`, `overlay`, `kv`, `badge`, `md`, `meter`, `spinner`, `icon`…); there is no native button, so buttons are the picker's action bar (`prActions`) or `item` rows with `hint` keycaps and `actions={click=...}`. No `ui.el` with plugin classes. Keys must be stable because window locates nodes by dotted key. Items are keyed `n<number>`; picker `layer.queue`; Settings is `layer.settings`, a `prefs` in the layer (Tern's right-docked side sheet) drawn over the queue picker.
- CSS (`plotroom.css`): only where no kind or prop covers it (a handful of rules); never restyle what a kind draws. Every selector starts with `[data-surface='plugin.plotroom.prs']`; use Tern tokens; no logical properties, `rem`/`ch`, or `:has()`.
- Deliberate shortcuts carry a `ponytail:` comment naming the ceiling and upgrade path.
- Annotate with SDK types from `tern.d.luau` (`BlockCx`, `WindowCx`, `Node`, `BlockView`, `ProcessResult`, `TimerHandle`, ...).

## Important Files

- `plugin/plugin.toml` — manifest: id `plotroom`, `host`, `window`, `styles`, block `prs`.
- `plugin/host.luau` (~2650 lines) — state type ~L64, storage ~L107-203, lifecycle `retire`/`alive`, window requests (`reply`, `menu`, `prepare`, `rpc`), views, block define, event handler.
- `plugin/window.luau` — link routing, palette commands, requests to the host (`ask`, `answered`), worktree/agent flows (`finishWorktree`, `finishAgent`, `confirm`, `startAgent`, `worktreePr`, `pickAgent`). `selftest`/`smoke` commands only when `PLOTROOM_SELFTEST=1`.
- `scripts/check.py` — pins at L51-56 (SDK sha256, Luau 0.742, luau-lsp 1.70.1, Tern 0.8.3); bundle builder `build_bundle`; stages `check_test`/`check_types`/`check_bench`/`check_smoke`.
- `scripts/tern-0.8.3.d.luau` — tracked SDK snapshot used by `types`; changing it requires updating the sha in `check.py`.

## Runtime/Tooling Preferences

- Luau (Tern's embedded runtime), not Lua 5.x: no `goto`, string/UTF-8 helpers per Luau. Type-checked with luau-lsp 1.70.1 against Tern 0.8.3 definitions.
- `scripts/check.py` is Python 3.9+, stdlib only; no pip, no package.json, no Makefile. Do not add dependencies.
- Smoke needs real `tern` 0.8.3, git ≥ 2.36 (`worktree list --porcelain -z`) and `omp` on PATH (worktrees are created with `omp worktree add`); it is local-only (CI skips it). CI: ubuntu-latest, `tools` then `--ci`, actions pinned by SHA.
- `plugin/tern.d.luau` is gitignored editor output; never commit it or depend on it in checks.

## Testing & QA

- No framework. `check.py test` bundles every `plugin/*.luau` and `plugin/tests/*.luau` into one temp script (each module wrapped as `function(tern, require, os)`) and runs `luau` on it. Pass = exit 0 and stdout `REGRESSION cases=N failed=0`.
- Add cases to `plugin/tests/regression.luau` with `case("module: behavior", fn)` (host context) or `windowCase(...)` (window context). Each case gets a fresh `World` (`newWorld`): fake SDK with virtual clock (`advance`/`runUntil`/`flush`), in-memory `fs`/`kv`, and `w.respond(fn)` to answer `process.run` spawns; unmatched spawns fail the case at `w.finish()`. Assertion helpers: `eq`, `same`, `yes`, `has`, `lacks`.

```lua
case("input: clean drops only malformed bytes and control characters", function(w: World)
	local input = w.load("input") :: Input
	eq(input.clean("é\x80b"), "éb", "stray continuation byte after a valid character")
end)
```

- Prefer behavioral assertions (rendered text, argv, kv contents, toasts). Case names are prefixed by module (`github.search:`, `worktree:`, `host:`).
- Pure helpers with no SDK dependency go in `plugin/tests/check.luau` (bare `assert`), which runs both in the bundle and in-app via the `selftest` palette command.
- No coverage tool or threshold. Bench rows (`BENCH <name> ms=…`, 1000 PRs) must stay under budget; smoke covers 8 real-git worktree scenarios (create, reuse, dirty reuse, advanced head, post-checkout hook, branch elsewhere, `.github`, recovery) plus a block on an attached loopback host (`remote loopback`) making its worktree through the real window → host → window link flow.
- Fake-SDK window cases that need the host's answers use `linkQueue`/`agentScene`, which `w.link` a real host block to the window's pane.
- The fake `tern.json.array` and decoded JSON arrays carry a protected metatable as in real Tern, so `table.clone` on them fails in tests too; copy with a loop. `cx:frame` ops are recorded in `w.frames` (`caretOf(w)` reads the last `focus` op).
- Before finishing any change: `python3 scripts/check.py` (or `--ci` without Tern) must pass clean.
