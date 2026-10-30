#!/usr/bin/env python3
"""Verification gate for the Plotroom plugin. Standard library only, Python 3.9+.

    python3 scripts/check.py            test + types + bench + smoke (the full local gate)
    python3 scripts/check.py --ci       test + types + bench; smoke is reported NOT RUN (Tern is not on CI)
    python3 scripts/check.py test       standalone Luau regression suite (fake Tern SDK) only
    python3 scripts/check.py types      luau-lsp analyze against the pinned Tern SDK only (`test` also checks plugin.toml's version against RPC_PROTOCOL)
    python3 scripts/check.py bench      1000-PR queue render benchmark only
    python3 scripts/check.py smoke      isolated headless Tern + real git only
    python3 scripts/check.py tools      download the pinned Luau and luau-lsp (sha256-verified)

test    plugin/tests/regression.luau (which also runs the plugin/tests/check.luau selftest), run by the
        Luau CLI from a temporary bundle: every plugin/**/*.luau module (subfolders included) wrapped as function(tern, require, os),
        so each case gets a fresh fake SDK (virtual clock, process, kv, fs, json, ui, blocks) and fresh
        module state. No network, no git, no files outside a temporary directory.
types   luau-lsp analyze --platform standard against scripts/tern-0.9.8.d.luau (a copy of the SDK that
        `tern plugin types` writes), over plugin/**/*.luau (subfolders included). Any diagnostic, warnings
        included, fails: luau-lsp exits 0 on lint warnings.
bench   renders the real queue view with 1000 PRs and fails above PLOTROOM_BENCH_BUDGET_MS per render.
smoke   scripts/smoke.py: `tern serve` headless on temporary directories, real git; see its docstring.

Tools: LUAU, LUAU_LSP, TERN (paths) -> the cache below -> PATH. `tools` is the only network access.
Pinned: Luau 0.743, luau-lsp 1.70.1, Tern 0.9.8 (f21d9a3). Cache: $XDG_CACHE_HOME or ~/.cache, plotroom-check/.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path
from typing import Callable, List, Tuple

ROOT = Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "plugin"
SDK = ROOT / "scripts" / "tern-0.9.8.d.luau"
SDK_SHA256 = "f56084a35c5cdb24e33b7bacda8baa9a3d1504fd3e31a20d3a8c31f3e0c0a32b"
LUAU_VERSION = "0.743"
LSP_VERSION = "1.70.1"
TERN_VERSION = "0.9.8"  # the SDK pin
BENCH_BUDGET_MS = float(os.environ.get("PLOTROOM_BENCH_BUDGET_MS", "25"))
BENCH_PAYLOAD_MAX = 600000

# sha256 of the release assets, as GitHub publishes them.
TOOLS = {
    "luau": {
        "version": LUAU_VERSION,
        "base": "https://github.com/luau-lang/luau/releases/download/%s/" % LUAU_VERSION,
        "member": "luau",
        "assets": {
            "Darwin": ("luau-macos.zip", "4334afbfb0c05ee697c9bfea64a85f950249c1e8f6f7d99aaa5a24ee362b09c3"),
            "Linux": ("luau-ubuntu.zip", "99d45afb4afaee00ba631c526c8e8c76c67b60f6f119953ce6409be6d6953663"),
        },
    },
    "luau-lsp": {
        "version": LSP_VERSION,
        "base": "https://github.com/JohnnyMorganz/luau-lsp/releases/download/%s/" % LSP_VERSION,
        "member": "luau-lsp",
        "assets": {
            "Darwin": ("luau-lsp-macos.zip", "7d3936e8dec6dc77547abd061d2e950da392562a5f94858b880f23dba50d84cd"),
            "Linux": ("luau-lsp-linux-x86_64.zip", "1a2ea1ae4f98f8946cefd970a4b54853e11ab4775e6932faa7f60cf920346567"),
        },
    },
}

class GateError(Exception):
    """A check failed or a prerequisite is missing; the message says what to do."""


def say(message: str = "") -> None:
    print(message, flush=True)


def run(cmd: List[str], **kw) -> "subprocess.CompletedProcess[str]":
    kw.setdefault("capture_output", True)
    kw.setdefault("text", True)
    kw.setdefault("encoding", "utf-8")
    kw.setdefault("errors", "replace")
    return subprocess.run(cmd, **kw)


# --------------------------------------------------------------------------- tools


def cache_dir() -> Path:
    base = os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache")
    return Path(base) / "plotroom-check"


def cached_tool(name: str) -> Path:
    spec = TOOLS[name]
    return cache_dir() / ("%s-%s" % (name, spec["version"])) / spec["member"]


def find_tool(name: str, env_var: str) -> Path:
    given = os.environ.get(env_var)
    if given:
        path = Path(given).expanduser()
        if not (path.is_file() and os.access(path, os.X_OK)):
            raise GateError("%s=%s is not an executable file" % (env_var, given))
        return path
    path = cached_tool(name)
    if path.is_file():
        return path
    found = shutil.which(TOOLS[name]["member"])
    if found:
        return Path(found)
    raise GateError(
        "%s %s not found: set %s=/path/to/%s, or run `python3 scripts/check.py tools` "
        "(sha256-pinned download into %s)" % (name, TOOLS[name]["version"], env_var, TOOLS[name]["member"], cache_dir())
    )


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def install_tools() -> str:
    system = platform.system()
    if system == "Linux" and platform.machine() not in ("x86_64", "AMD64"):
        raise GateError("no pinned Linux build for %s: set LUAU and LUAU_LSP to your own binaries" % platform.machine())
    lines = []
    for name, spec in TOOLS.items():
        asset = spec["assets"].get(system)
        if asset is None:
            raise GateError("no pinned %s build for %s: set LUAU / LUAU_LSP yourself" % (name, system))
        zip_name, want = asset
        dest = cached_tool(name)
        if dest.is_file():
            lines.append("%s %s: already at %s" % (name, spec["version"], dest))
            continue
        url = spec["base"] + zip_name
        say("check: downloading %s" % url)
        request = urllib.request.Request(url, headers={"User-Agent": "plotroom-check"})
        with urllib.request.urlopen(request, timeout=120) as response:
            data = response.read()
        got = hashlib.sha256(data).hexdigest()
        if got != want:
            raise GateError("%s: sha256 %s does not match the pinned %s; nothing was installed" % (url, got, want))
        dest.parent.mkdir(parents=True, exist_ok=True)
        archive = dest.parent / zip_name
        archive.write_bytes(data)
        try:
            with zipfile.ZipFile(archive) as bundle:
                members = [m for m in bundle.namelist() if not m.endswith("/") and Path(m).name == spec["member"]]
                if not members:
                    raise GateError("%s holds no %s" % (zip_name, spec["member"]))
                tmp = dest.with_name(dest.name + ".part")
                tmp.write_bytes(bundle.read(members[0]))
        finally:
            archive.unlink()
        tmp.chmod(0o755)
        os.replace(tmp, dest)
        lines.append("%s %s: installed %s (asset sha256 %s verified)" % (name, spec["version"], dest, want))
    return "\n".join(lines)


# --------------------------------------------------------------------------- sources


def plugin_files() -> List[Path]:
    """Every Luau file of the package, subfolders included, except the SDK definitions."""
    return [p for p in sorted(PLUGIN.rglob("*.luau")) if not p.name.endswith(".d.luau")]


def module_name(path: Path) -> str:
    return path.relative_to(PLUGIN).with_suffix("").as_posix()


# Each module becomes function(tern, require, os): its free `tern` and `os` are the world's fakes and
# its relative requires resolve inside the bundle, so one world's module state never leaks into the next.
BUNDLE_HEAD = """-- generated by scripts/check.py; do not edit
local sources = {}
"""

BUNDLE_TAIL = """
local function resolve(from, path)
	local parts = {}
	for segment in string.gmatch(string.match(from, "^(.*)/[^/]*$") or "", "[^/]+") do
		table.insert(parts, segment)
	end
	for segment in string.gmatch(path, "[^/]+") do
		if segment == ".." then
			table.remove(parts)
		elseif segment ~= "." then
			table.insert(parts, segment)
		end
	end
	return table.concat(parts, "/")
end

local function instantiate(tern, fakeOs)
	local loaded, started = {}, {}
	local function load(name)
		if not started[name] then
			local source = sources[name]
			if not source then
				error("bundle: no module " .. name)
			end
			started[name] = true
			loaded[name] = source(tern, function(path)
				return load(resolve(name, path))
			end, fakeOs)
		end
		return loaded[name]
	end
	return load
end

local regression = instantiate(nil, os)("tests/regression")
"""

DRIVERS = {"test": "regression.run(instantiate)\n", "bench": "regression.bench(instantiate)\n"}

Span = Tuple[int, int, str]


def build_bundle(mode: str) -> Tuple[str, List[Span]]:
    lines = BUNDLE_HEAD.split("\n")[:-1]
    spans: List[Span] = []
    for path in plugin_files():
        name = module_name(path)
        body = path.read_text(encoding="utf-8").split("\n")
        if body and body[-1] == "":
            body.pop()
        lines.append('sources["%s"] = function(tern, require, os)' % name)
        first = len(lines) + 1
        lines.extend(body)
        spans.append((first, len(lines), name))
        lines.append("end")
    lines.extend(BUNDLE_TAIL.split("\n"))
    lines.extend(DRIVERS[mode].split("\n"))
    return "\n".join(lines), spans


def remap(text: str, spans: List[Span]) -> str:
    """Rewrite bundle line numbers in Luau errors as plugin/<module>.luau:<line>."""

    def sub(match: "re.Match[str]") -> str:
        line = int(match.group(1))
        for first, last, name in spans:
            if first <= line <= last:
                return "plugin/%s.luau:%d" % (name, line - first + 1)
        return match.group(0)

    return re.sub(r"\S*plotroom-bundle\.luau:(\d+)", sub, text)


def run_bundle(luau: Path, mode: str) -> Tuple[int, str, str]:
    source, spans = build_bundle(mode)
    with tempfile.TemporaryDirectory(prefix="plotroom-bundle-") as tmp:
        script = Path(tmp) / "plotroom-bundle.luau"
        script.write_text(source, encoding="utf-8")
        done = run([str(luau), str(script)], cwd=str(ROOT), timeout=600)
    return done.returncode, remap(done.stdout, spans), remap(done.stderr, spans)


# --------------------------------------------------------------------------- checks


def luau_banner(luau: Path) -> str:
    # The Luau CLI has no --version: identify the binary by hash; `tools` installs the pinned release.
    return "luau %s (sha256 %s; pinned release %s)" % (luau, sha256_file(luau)[:16], LUAU_VERSION)


def check_css() -> None:
    """plotroom.css: scoped selectors, and none of the syntax Tern's engine rejects (docs.stencil.so/tern/styles/css.md)."""
    scope = "[data-surface='plugin.plotroom.prs']"
    text = re.sub(r"/\*.*?\*/", "", (PLUGIN / "plotroom.css").read_text(encoding="utf-8"), flags=re.S)
    problems = []
    for match in re.finditer(r"([^{};]+)\{", text):
        prelude = match.group(1).strip()
        if prelude.startswith("@") or re.fullmatch(r"(from|to|[\d.]+%)(\s*,\s*(from|to|[\d.]+%))*", prelude):
            continue
        for selector in prelude.split(","):
            if not selector.strip().startswith(scope):
                problems.append("selector outside the block's scope: %s" % selector.strip())
    for bad in (r"\d(rem|ch)\b", r":has\(", r"\b(margin|padding|border|inset)-(inline|block)\b", r"\binset-(inline|block)\b"):
        for found in re.finditer(bad, text):
            problems.append("unsupported CSS %r" % found.group(0))
    if problems:
        raise GateError("plugin/plotroom.css: " + "; ".join(problems[:5]))


def check_test() -> str:
    check_css()
    unlisted = [p.stem for p in sorted((PLUGIN / "tests" / "cases").glob("*.luau")) if 'require("./cases/%s")' % p.stem not in (PLUGIN / "tests" / "regression.luau").read_text(encoding="utf-8")]
    if unlisted:
        raise GateError("plugin/tests/cases/ files not required by plugin/tests/regression.luau (they would run nothing): %s" % ", ".join(unlisted))
    luau = find_tool("luau", "LUAU")
    say("test: " + luau_banner(luau))
    code, out, err = run_bundle(luau, "test")
    sys.stdout.write(out)
    sys.stderr.write(err)
    match = re.search(r"^REGRESSION cases=(\d+) failed=(\d+)$", out, re.M)
    if code != 0 or not match or int(match.group(2)) != 0:
        raise GateError("regression suite failed (exit %d)" % code)
    cases = int(match.group(1))
    return "%d regression cases" % cases


def check_types() -> str:
    lsp = find_tool("luau-lsp", "LUAU_LSP")
    version = run([str(lsp), "--version"], timeout=60)
    reported = (version.stdout + version.stderr).strip()
    if LSP_VERSION not in reported:
        raise GateError("luau-lsp reports %r, the gate is pinned to %s: run `python3 scripts/check.py tools`" % (reported, LSP_VERSION))
    if not SDK.is_file() or sha256_file(SDK) != SDK_SHA256:
        raise GateError("%s is missing or differs from its pinned sha256 %s" % (SDK, SDK_SHA256))
    live = PLUGIN / "tern.d.luau"
    if live.is_file() and sha256_file(live) != SDK_SHA256:
        say("types: note: plugin/tern.d.luau differs from the pinned Tern %s SDK snapshot; the snapshot is used" % TERN_VERSION)
    files = [str(p.relative_to(ROOT)) for p in plugin_files()]
    say("types: luau-lsp %s, %d files, SDK %s" % (reported, len(files), SDK.name))
    done = run(
        [str(lsp), "analyze", "--platform", "standard", "--definitions", str(SDK.relative_to(ROOT))] + files,
        cwd=str(ROOT),
        timeout=600,
    )
    # luau-lsp prints diagnostics on stderr and exits 0 when only lint warnings were reported.
    seen = set()
    diagnostics: List[str] = []
    for line in (done.stdout + "\n" + done.stderr).splitlines():
        if line.startswith("[INFO] Loading definitions file:"):
            continue
        if line.strip() and line not in seen:
            seen.add(line)
            diagnostics.append(line)
    if done.returncode != 0 or diagnostics:
        for line in diagnostics:
            say(line)
        raise GateError("luau-lsp reported %d diagnostic line(s) (exit %d); the gate requires none" % (len(diagnostics), done.returncode))
    return "%d files, 0 diagnostics" % len(files)


def check_bench() -> str:
    luau = find_tool("luau", "LUAU")
    code, out, err = run_bundle(luau, "bench")
    sys.stdout.write(out)
    sys.stderr.write(err)
    if code != 0:
        raise GateError("benchmark did not complete (exit %d)" % code)
    rows = [l for l in out.splitlines() if l.startswith("BENCH ")]
    if not rows:
        raise GateError("benchmark printed no BENCH rows")
    worst = 0.0
    for row in rows:
        fields = dict(re.findall(r"(\w+)=([0-9.]+)", row))
        if "ms" in fields:
            worst = max(worst, float(fields["ms"]))
        if row.startswith("BENCH payload") and float(fields["bytes"]) >= BENCH_PAYLOAD_MAX:
            raise GateError("payload %d bytes is not under %d" % (float(fields["bytes"]), BENCH_PAYLOAD_MAX))
    if worst > BENCH_BUDGET_MS:
        raise GateError("slowest render %.1f ms exceeds the %.0f ms budget (PLOTROOM_BENCH_BUDGET_MS)" % (worst, BENCH_BUDGET_MS))
    return "%d rows, slowest %.1f ms (budget %.0f ms)" % (len(rows), worst, BENCH_BUDGET_MS)


def check_version() -> str:
    """plugin.toml's version minor tracks RPC_PROTOCOL, so `tern plugin list` tells two hosts' builds apart."""
    core = (PLUGIN / "host" / "core.luau").read_text(encoding="utf-8")
    proto = re.search(r'^M\.RPC_PROTOCOL = "(\d+)"', core, re.M)
    version = re.search(r'^version = "([^"]*)"', (PLUGIN / "plugin.toml").read_text(encoding="utf-8"), re.M)
    if not proto or not version:
        raise GateError("cannot read RPC_PROTOCOL from plugin/host/core.luau or version from plugin/plugin.toml")
    want = "0.%s.0" % proto.group(1)
    if version.group(1) != want:
        raise GateError("plugin/plugin.toml version is %s but RPC_PROTOCOL is %s: set version = \"%s\"" % (version.group(1), proto.group(1), want))
    return "plugin %s = protocol %s" % (version.group(1), proto.group(1))


def load_smoke():
    sys.modules.setdefault("check", sys.modules[__name__])  # run as __main__: smoke.py must share this module's GateError
    import smoke

    return smoke


def check_smoke() -> str:
    return load_smoke().check_smoke()


# --------------------------------------------------------------------------- main


def summarize(results: List[Tuple[str, str, str]]) -> int:
    say("")
    say("== summary ==")
    width = max(len(name) for name, _, _ in results)
    lines = []
    for name, status, detail in results:
        lines.append("%-*s  %-7s  %s" % (width, name, status, detail))
    for line in lines:
        say(line)
    failed = any(status == "FAIL" for _, status, _ in results)
    skipped = [name for name, status, _ in results if status == "NOT RUN"]
    if failed:
        verdict = "FAILED"
    elif skipped:
        verdict = "PASSED the portable subset; %s NOT RUN" % ", ".join(skipped)
    else:
        verdict = "PASSED"
    say(verdict)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("### Plotroom gate\n\n```\n%s\n%s\n```\n" % ("\n".join(lines), verdict))
    if skipped and os.environ.get("GITHUB_ACTIONS") == "true":
        say("::notice title=Plotroom gate::%s NOT RUN: real-Tern smoke needs Tern, which is not available on CI" % ", ".join(skipped))
    return 1 if failed else 0


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description="Plotroom verification gate", formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", nargs="?", default="all", choices=["all", "test", "types", "bench", "smoke", "tools"])
    parser.add_argument("--ci", action="store_true", help="skip the real-Tern smoke and say so (Tern is not available on CI)")
    args = parser.parse_args(argv)

    if args.command == "tools":
        try:
            say(install_tools())
        except GateError as error:
            say("tools: FAIL: %s" % error)
            return 1
        say("export LUAU=%s LUAU_LSP=%s" % (cached_tool("luau"), cached_tool("luau-lsp")))
        return 0

    plan: List[Tuple[str, Callable[[], str]]] = []
    if args.command in ("all", "test"):
        plan.append(("test", check_test))
        plan.append(("version", check_version))
    if args.command in ("all", "types"):
        plan.append(("types", check_types))
    if args.command in ("all", "bench"):
        plan.append(("bench", check_bench))
    results: List[Tuple[str, str, str]] = []
    if args.command in ("all", "smoke") and not args.ci:
        plan.append(("smoke", check_smoke))

    for name, check in plan:
        say("== %s ==" % name)
        started = time.time()
        try:
            detail = check()
            results.append((name, "PASS", "%s (%.1fs)" % (detail, time.time() - started)))
        except GateError as error:
            say("%s: FAIL: %s" % (name, error))
            results.append((name, "FAIL", str(error)))
        except subprocess.TimeoutExpired as error:
            say("%s: FAIL: timed out: %s" % (name, error))
            results.append((name, "FAIL", "timed out"))
    if args.command in ("all", "smoke"):
        if args.ci:
            load_smoke()  # a syntax or import error in smoke.py must still fail CI
            results.append(("smoke", "NOT RUN", "--ci: Tern is not available on CI; run `python3 scripts/check.py smoke` locally"))
        else:
            results.extend(("smoke", "WARN", warning) for warning in load_smoke().WARNINGS)
    return summarize(results)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
