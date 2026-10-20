# Repository Guidelines

## Project Overview

Tern Plotroom is a [Tern](https://tern.sh) terminal plugin, written in Luau, that renders one block (shown as Plotroom, id `plugin.plotroom.prs`, manifest block id `prs`) for a live queue of GitHub pull requests, GitHub issues and Jira issues: one sidebar of typed saved views, keyboard triage, Browser docking, and one-key worktrees. Data comes from the `gh` CLI (GraphQL), Atlassian's `acli` (Jira) and `git`; there is no server component. README.md is the user-facing spec; this file is for contributors.

There is one block. `Plotroom: Open` is its one entry point; other palette commands act on the focused Plotroom block (except `Open item by URL`, which launches one). The `KINDS` table (`prs`, `issues`) in `plugin/host/core.luau` fixes per kind the label, icon, kv keys, allowed integrations, seed views and default prompts. Behavior is documented in README.md and in comments next to the code; read those before changing it.

## Architecture & Data Flow

Two Luau runtimes talk through Tern:

- **Host** (`plugin/host.luau` + `plugin/host/`): runs where the block runs (the remote host's daemon for a remote pane). Owns per-pane `State` (`running`, keyed by pane), polls GitHub and Jira, persists prefs in `tern.kv`, returns a declarative `ui` tree from `view`, and does all checkout work (git, gh, omp) for the window. `host.luau` is the entry point: requires, the queue action dispatcher, the `blockDef` handlers (plus the worktree card helpers `summaryOf`/`applyScans`/`scanWorktrees`/`inspectSelected`/`askRemove`/`removeNow`, kept inside `blockDef`) and `tern.block.define("prs", {...})`.
- **Window** (`plugin/window.luau`): runs on the machine showing the window, so it never touches a checkout. Registers `tern.route.link` for `plotroom://…` links and palette commands, and asks the host through `{ev="action", act="rpc", value=JSON{id, op, ...}}` requests. `flows.luau` is the window's workflow side (agent links/status, confirmed mutations, draft PR, export/import, open by URL).

Host layers (`plugin/host/`; each module may require only those to its left, no cycles):

`core` (types, constants, `KINDS`/`GROUPS`, badges, the `cli` table, `running`, pure text/href helpers) ← `storage` (kv stores, name `formats`) ← `engine` (lifecycle, identity/refresh, triage, pins, Worktrees board glue, navigation, details, worktree notes, `me`, `ghActive`, CLI probing) ← `render` (rows, previews, checks, help, scopes, hidden rpc nodes) ← `settings` (Settings sheet) ← `requests` (window requests, workflow requests, export/import, palette actions).

Shared helpers (no cycles; require only what is listed, the rest require none): `tracker` → `input`; `github` → `process`, `input`, `tracker`; `jira` → `process`, `input`, `tracker`, `github`; `worktree` → `process`, `input`, `tracker`, `github`; `process`, `input`, `keys`, `prompts` and the pure models `triage`, `sorting`, `portable`, `board` require nothing. `window → flows, worktree`; `flows` takes what window owns through `flows.setup(Env)`.

A change to a shared store (views, prompts, checkouts, ...) fans out to the other live blocks through `propagate` (engine), which rereads storage and renders them.

Invariants (keep when editing):

- Integrations follow their CLI: no view is listed or searched until every CLI probe answered; an integration is on only while its CLI starts.
- Worktrees always go in omp's worktree directory; there is no Plotroom setting for it. The worktree card is a memory cache of git, never the source.
- Views span repositories; checkouts are kv `checkouts` (`""` = listed without a checkout) and are requested from the window when missing.
- Block `save` is version 2 (any other version restores fresh).
- The palette's Jira transition… picker uses `tern.fetch` with `PLOTROOM_JIRA_API_TOKEN` read per call from the host environment; the token is never in kv, argv or a message. An action's Move to status uses `acli jira workitem transition --status` and needs no token.
- Every async mutation captures the concrete gh login at plan time and uses it at commit.
- Guided mutations are plan-then-commit: the confirm lists Cancel first, and commit runs only after the confirm with that plan's token.
- Bump `RPC_PROTOCOL` (host) and `PROTOCOL` (window) together when an rpc shape changes, and set `plugin/plugin.toml`'s `version` to `0.<RPC_PROTOCOL>.0` (`check.py` fails when they differ, so `tern plugin list` tells two hosts' builds apart).
- kv stores that cannot be read or are malformed are never written over (`views-*`, `prompts-*`, `keys`, `triage`, `agent-links`, ...).

## Key Directories

- `plugin/` — everything shipped: `plugin.toml` manifest, `host.luau`, `host/*.luau`, `window.luau`, helper modules, `plotroom.css`.
- `plugin/tests/` — `regression.luau` (runner), `harness.luau` (fake SDK, `case`/`windowCase`, assertions, shared fixtures), `cases/<area>.luau` (one file per area), `check.luau` (pure assert selftest, also runnable in-app), `runtime.luau` (smoke driver against real Tern/git).
- `scripts/` — `check.py` (the verification gate), `smoke.py` (smoke stage), `tern-0.8.3.d.luau` (pinned SDK type snapshot, sha256-checked).
- `.github/workflows/check.yml` — CI.

## Development Commands

```sh
tern plugin link ./plugin          # install for local use
python3 scripts/check.py tools     # download pinned luau 0.743 + luau-lsp 1.70.1 (macOS / Linux x86_64)
python3 scripts/check.py           # all: test + types + bench + smoke
python3 scripts/check.py test      # regression suite only (also: types | bench | smoke)
python3 scripts/check.py --ci      # what CI runs: smoke reported NOT RUN
tern plugin types plugin           # refresh gitignored plugin/tern.d.luau for editor types
```

Tool lookup order: env `LUAU`/`LUAU_LSP`/`TERN` → `~/.cache/plotroom-check/` (`$XDG_CACHE_HOME`) → PATH. Missing tool = failure, not skip. `PLOTROOM_BENCH_BUDGET_MS` (default 250) caps the slowest bench row. `types` fails on **any** luau-lsp diagnostic, warnings included, over `plugin/**/*.luau`.

## Code Conventions & Common Patterns

- `--!strict` at the top of every module. Modules are `local M = {}` + `function M.x` + `return M`; `require` paths are relative to the requiring file. `host.luau`/`window.luau` expose only registrations.
- Put new host code in the module of its layer; do not hide helpers on catch-all tables.
- Naming: files lowercase single word; functions/locals camelCase; constants SCREAMING_SNAKE; types PascalCase (`export type` when shared); action/check ids kebab-case; kv keys lowercase words.
- Async is callbacks only, no coroutines. Shape: `done(value?, problem?, cx?)`. `process.run` is the only way to spawn anything.
- Errors are values: `Problem = {kind, message}` (kinds in `github.luau`). Wrap `tern.kv`/`tern.json` calls in `pcall`; validate untrusted input at the boundary (store validators, `parsePage`, size caps).
- Stale-callback guards are mandatory: check `alive(state)` and `state.gen` in host callbacks; the window uses `defer` to fetch a fresh `cx`.
- Security: every command is an argv array; never build shell strings.
- UI: native Tern kinds only (`picker`, `prefs`, `list`/`item`, `overlay`, `kv`, `badge`, `md`, `meter`, `spinner`, `icon`…); there is no native button, so buttons are the picker's action bar or `item` rows with `hint` keycaps and `actions={click=...}`. Keys must be stable because the window locates nodes by dotted key. Tern 0.8.3 `prefs` has no multi-line control: prompt text is an `editor` node under `role = "omp.prefs.editor"`.
- CSS (`plotroom.css`): only where no kind or prop covers it; never restyle what a kind draws. Every selector starts with `[data-surface='plugin.plotroom.prs']`; use Tern tokens; no logical properties, `rem`/`ch`, or `:has()`.
- Deliberate shortcuts carry a `ponytail:` comment naming the ceiling and upgrade path.
- Annotate with SDK types from `tern.d.luau` (`BlockCx`, `WindowCx`, `Node`, `BlockView`, `ProcessResult`, `TimerHandle`, ...).

## Important Files

- `plugin/plugin.toml` — manifest: id `plotroom`, `host`, `window`, `styles`, one block `prs` (title Plotroom, icon `merge`).
- `plugin/host.luau` — block entry point; `plugin/host/*.luau` — host logic by layer (see Architecture).
- `plugin/window.luau` — link routing, palette commands, requests to the host, worktree/agent flows. No consent step: agents start once the worktree is ready. `selftest`/`smoke` commands only when `PLOTROOM_SELFTEST=1`.
- `plugin/flows.luau` — window workflow flows and `COMMANDS`.
- `plugin/prompts.luau` — default prompts; every `{var}` one names must be filled where it runs.
- `scripts/check.py` — pins (SDK sha256, Luau, luau-lsp, Tern), `plugin_files()` (bundles `plugin/**/*.luau`), bundle builder, test/types/bench stages, CLI. `scripts/smoke.py` — the smoke stage.
- `scripts/tern-0.8.3.d.luau` — tracked SDK snapshot used by `types`; changing it requires updating the sha in `check.py`.

## Runtime/Tooling Preferences

- Luau (Tern's embedded runtime), not Lua 5.x: no `goto`. Type-checked with luau-lsp 1.70.1 against Tern 0.8.3 definitions.
- `scripts/*.py` are Python 3.9+, stdlib only; no pip, package.json or Makefile. Do not add dependencies.
- Smoke needs real `tern` (any version; types stay pinned to 0.8.3), git ≥ 2.36 and `omp` on PATH; it is local-only (CI skips it). Smoke generates the installed Tern's SDK types and shows a WARN row (never a failure) when their sha256 differs from the pinned snapshot. CI: ubuntu-latest, `tools` then `--ci`, actions pinned by SHA, checkout with `persist-credentials: false`.
- `plugin/tern.d.luau` is gitignored editor output; never commit it or depend on it in checks.

## Testing & QA

- No framework. `check.py test` bundles every `plugin/**/*.luau` into one temp script (each module wrapped as `function(tern, require, os)`, named by its path under `plugin/`, e.g. `host/core`) and runs `luau` on it. Pass = exit 0 and stdout `REGRESSION cases=N failed=0`.
- `regression.luau` is the runner. Add a case to the file in `plugin/tests/cases/` for its area, binding the harness helpers as locals, with `case("module: behavior", fn)` (host context) or `windowCase(...)` (window context). A new `tests/cases/<area>.luau` must be `require`d from `tests/regression.luau`, or its cases never run and the gate fails. Each case gets a fresh `World` (`newWorld`): fake SDK with virtual clock (`advance`/`runUntil`/`flush`), in-memory `fs`/`kv`, and `w.respond(fn)` to answer `process.run` spawns; unmatched spawns fail the case at `w.finish()`. Assertions: `eq`, `same`, `yes`, `has`, `lacks`.

```lua
case("input: clean drops only malformed bytes and control characters", function(w: World)
	local input = w.load("input") :: Input
	eq(input.clean("é\x80b"), "éb", "stray continuation byte after a valid character")
end)
```

- Prefer behavioral assertions (rendered text, argv, kv contents, toasts). Case names are prefixed by module.
- Pure helpers with no SDK dependency go in `plugin/tests/check.luau` (bare `assert`), which runs in the bundle and in-app via the `selftest` palette command.
- No coverage tool. Bench rows (`BENCH <name> ms=…`, 1000 PRs) must stay under budget. Smoke (`scripts/smoke.py`) covers real-git worktree scenarios and real Plotroom blocks with a fake gh; its scenarios are listed in `SCENARIOS` in `scripts/smoke.py` (see its header).
- Fake-SDK window cases that need the host's answers use `linkQueue`/`agentScene`, which `w.link` a real host block to the window's pane.
- A block probes `gh --version` and `acli --version` before listing any view: `newWorld` answers them (installed, with sprints) unless a model (`newGh`, `newAcli`) answers first; `hx.uninstalled(w, program)` makes one fail to start.
- Host scenes save fixture views (ungrouped, unsorted) unless the case saved that store first; a case about default views clears `views-prs`/`views-issues` first.
- `newWorld` seeds kv `keys` with classic one-key bindings so cases drive the queue by key; a case about the real defaults clears it first. With no `prompts-*` in kv a kind offers default prompts: a case about an empty prompt store saves one first.
- The fake `tern.json.array` and decoded arrays carry a protected metatable as in real Tern, so `table.clone` on them fails in tests too; copy with a loop.
- Before finishing any change: `python3 scripts/check.py` (or `--ci` without Tern) must pass clean.
