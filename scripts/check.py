#!/usr/bin/env python3
"""Verification gate for the Plotroom plugin. Standard library only, Python 3.9+.

Platforms: `tools` downloads pinned builds for macOS and Linux x86_64 only. Elsewhere (Windows, Linux arm64) set LUAU and LUAU_LSP to your own binaries; smoke needs a POSIX host (it uses /tmp, /bin/sh and /dev/null).

    python3 scripts/check.py            test + types + bench + smoke (the full local gate)
    python3 scripts/check.py --ci       test + types + bench; smoke is reported NOT RUN (Tern is not on CI)
    python3 scripts/check.py test       standalone Luau regression suite (fake Tern SDK) only; also checks plugin.toml's version has a CHANGELOG.md entry, and the docs stage: the markdown's relative links and #anchors resolve, README's screenshots are each used and under 400 KB
    python3 scripts/check.py test -k <substring> [-v]
                                        only the cases whose name contains <substring> (also PLOTROOM_CASE=<substring>); -v prints `RUN <name>` before each case,
                                        so a hang or timeout names the case that never returned
    python3 scripts/check.py types      luau-lsp analyze against the pinned Tern SDK only
    python3 scripts/check.py bench      1000-PR queue render benchmark only
    python3 scripts/check.py ext        the omp extension (plugin/omp/plotroom.ts) over its fixtures only
    python3 scripts/check.py smoke      isolated headless Tern + real git only
    python3 scripts/check.py tools      download the pinned Luau and luau-lsp (sha256-verified)

test    plugin/tests/regression.luau (which also runs the plugin/tests/check.luau selftest), run by the
        Luau CLI from a temporary bundle: every plugin/**/*.luau module (subfolders included) wrapped as function(tern, require, os),
        so each case gets a fresh fake SDK (virtual clock, process, kv, fs, json, ui, blocks) and fresh
        module state. No network, no git, no files outside a temporary directory.
types   luau-lsp analyze --platform standard against scripts/tern-0.9.13.d.luau (a copy of the SDK that
        `tern plugin types` writes), over plugin/**/*.luau (subfolders included). Any diagnostic, warnings
        included, fails: luau-lsp exits 0 on lint warnings.
bench   renders the real queue view with 1000 PRs and fails when a row is above its budget (BENCH_BUDGETS_MS, else 25 ms; PLOTROOM_BENCH_BUDGET_MS sets one ceiling for all rows) or has neither ms= nor bytes=.
ext     plugin/tests/extension.ts, run by bun (else node >= 23.6, which strips types): the omp extension's two tools
        over the fixtures it shares with its Luau readers (plugin/tests/extension.luau; the `test` stage reads them
        back in Luau). NOT RUN when neither runtime is on PATH.
smoke   scripts/smoke.py: `tern serve` headless on temporary directories, real git; its docstring lists the scenarios (SCENARIOS) and env vars
        (TERN, PLOTROOM_SMOKE_SHOTS).

Tools: LUAU, LUAU_LSP, TERN (paths) -> the cache below -> PATH. `tools` is the only network access.
Pinned: Luau 0.743 (its binary's sha256 is checked on every run: the Luau CLI has no --version), luau-lsp 1.70.1, Tern 0.9.13 SDK (stencil-hq/tern-sdk 0479f70, the minimum supported Tern).
Cache: $XDG_CACHE_HOME or ~/.cache, plotroom-check/.
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
from typing import Callable, List, Optional, Tuple

ROOT = Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "plugin"
SDK = ROOT / "scripts" / "tern-0.9.13.d.luau"
SDK_SHA256 = "50ac8b5dcc41f6e853730d05db5525566992d765e5d3a249ce5e0a5ec4f7749e"
LUAU_VERSION = "0.743"
LSP_VERSION = "1.70.1"
TERN_VERSION = "0.9.13"  # the SDK pin and the minimum Tern smoke accepts
# One ceiling for every row of the bench, from the environment; unset, each row takes BENCH_BUDGETS_MS or the default.
BENCH_BUDGET_ENV = os.environ.get("PLOTROOM_BENCH_BUDGET_MS")
BENCH_DEFAULT_MS = 25.0
# Per-row ceilings (ms) for the cheap steps, about 4x their measured median over 1000 PRs, so a 10x regression fails;
# the heavy ones (rebuilds, boards, runs-index) keep the default.
BENCH_BUDGETS_MS = {
    "render": 5.0,
    "cursor-down": 5.0,
    "seen-render": 5.0,
    "views-render": 5.0,
    "settings-key": 5.0,
    "search-keystroke": 10.0,
    "now-cursor-down": 10.0,
    "now-render": 10.0,
    "scan": 15.0,
}
BENCH_PAYLOAD_MAX = 600000
IMAGE_MAX = 400000  # README screenshots, bytes (AGENTS.md: each under 400 KB)

# sha256 of the release assets, as GitHub publishes them. "binary" is the sha256 of the extracted luau
# executable per platform: the Luau CLI has no --version, so the hash is how a 0.743 binary is told from another.
TOOLS = {
    "luau": {
        "version": LUAU_VERSION,
        "base": "https://github.com/luau-lang/luau/releases/download/%s/" % LUAU_VERSION,
        "member": "luau",
        "binary": {
            "Darwin": "08c4781cacc4f16c1025fd954028465a7ff3a458279e4b5fef6eceb19acb8e76",
            "Linux": "416fec2184d0bd238be24721f0369ec1d38b09da21032d6845e5f6648f69f2f8",
        },
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


class NotRun(Exception):
    """A check that needs a runtime this machine lacks; the message says which."""


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
        return path if name != "luau" else pinned_luau(path, cached=False)
    path = cached_tool(name)
    if path.is_file():
        return path if name != "luau" else pinned_luau(path, cached=True)
    found = shutil.which(TOOLS[name]["member"])
    if found:
        return Path(found) if name != "luau" else pinned_luau(Path(found), cached=False)
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


DOWNLOAD_ATTEMPTS = 3


def download(url: str) -> bytes:
    """GET url, retrying a transient failure; any that persists is a GateError, not a traceback."""
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        say("check: downloading %s%s" % (url, "" if attempt == 1 else " (attempt %d of %d)" % (attempt, DOWNLOAD_ATTEMPTS)))
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "plotroom-check"})
            with urllib.request.urlopen(request, timeout=120) as response:
                return response.read()
        except OSError as error:  # URLError, HTTPError, socket.timeout and a reset are all OSError
            if attempt == DOWNLOAD_ATTEMPTS:
                raise GateError("download of %s failed after %d attempts: %s; rerun `python3 scripts/check.py tools`" % (url, attempt, error))
            say("check: download failed (%s); retrying" % error)
            time.sleep(attempt)  # ponytail: 1s then 2s, fixed; jitter if many jobs ever share one host
    raise AssertionError("unreachable")


def luau_is_pinned(path: Path) -> bool:
    return sha256_file(path) == TOOLS["luau"]["binary"].get(platform.system())


def pinned_luau(path: Path, cached: bool) -> Path:
    """A luau that is not the pinned 0.743 binary: an error from the cache (edited or corrupt), a warning from
    LUAU or PATH (your own build, or a platform with no pinned one)."""
    if luau_is_pinned(path):
        return path
    if cached:
        raise GateError("%s does not match the pinned Luau %s binary (sha256 %s): run `python3 scripts/check.py tools` to reinstall it" % (path, LUAU_VERSION, TOOLS["luau"]["binary"].get(platform.system())))
    say("check: WARNING: %s is not the pinned Luau %s binary; results may differ from the gate's" % (path, LUAU_VERSION))
    return path


def install_tools() -> str:
    system = platform.system()

    def asset_for(name: str):
        if system == "Linux" and platform.machine() not in ("x86_64", "AMD64"):
            raise GateError("no pinned Linux build for %s: set LUAU and LUAU_LSP to your own binaries" % platform.machine())
        asset = TOOLS[name]["assets"].get(system)
        if asset is None:
            raise GateError("no pinned %s build for %s: set LUAU / LUAU_LSP yourself" % (name, system))
        return asset

    lines = []
    for name, spec in TOOLS.items():
        zip_name, want = asset_for(name)
        dest = cached_tool(name)
        if dest.is_file() and (name != "luau" or luau_is_pinned(dest)):
            lines.append("%s %s: already at %s" % (name, spec["version"], dest))
            continue
        url = spec["base"] + zip_name
        data = download(url)
        got = hashlib.sha256(data).hexdigest()
        if got != want:
            raise GateError("%s: sha256 %s does not match the pinned %s; nothing was installed" % (url, got, want))
        archive = dest.parent / zip_name
        tmp = dest.with_name(dest.name + ".part")
        try:
            dest.parent.mkdir(parents=True, exist_ok=True)
            archive.write_bytes(data)
            with zipfile.ZipFile(archive) as bundle:
                members = [m for m in bundle.namelist() if not m.endswith("/") and Path(m).name == spec["member"]]
                if not members:
                    raise GateError("%s holds no %s" % (zip_name, spec["member"]))
                tmp.write_bytes(bundle.read(members[0]))
            if name == "luau" and not luau_is_pinned(tmp):
                raise GateError("the extracted %s is not the pinned Luau %s binary; nothing was installed" % (spec["member"], LUAU_VERSION))
            tmp.chmod(0o755)
            os.replace(tmp, dest)
        except (OSError, zipfile.BadZipFile) as error:
            raise GateError("installing %s failed: %s" % (zip_name, error))
        finally:
            archive.unlink(missing_ok=True)
            tmp.unlink(missing_ok=True)
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
	local loaded, started, loading = {}, {}, {}
	local function load(name)
		if loading[name] then
			error("bundle: cyclic require " .. name)
		end
		if not started[name] then
			local source = sources[name]
			if not source then
				error("bundle: no module " .. name)
			end
			started[name] = true
			loading[name] = true
			loaded[name] = source(tern, function(path)
				return load(resolve(name, path))
			end, fakeOs)
			loading[name] = nil
		end
		return loaded[name]
	end
	return load
end

local regression = instantiate(nil, os)("tests/regression")
"""

DRIVERS = {"test": "regression.run(instantiate%s)\n", "bench": "regression.bench(instantiate)\n"}

Span = Tuple[int, int, str]


def luau_string(text: str) -> str:
    """A Luau string literal for any text: every byte as a decimal escape, so no quote or backslash needs care."""
    return '"' + "".join("\\%03d" % b for b in text.encode("utf-8")) + '"'


def build_bundle(mode: str, case_filter: Optional[str] = None, verbose: bool = False) -> Tuple[str, List[Span]]:
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
    driver = DRIVERS[mode]
    if mode == "test":
        driver = driver % (", %s, %s" % (luau_string(case_filter) if case_filter else "nil", "true" if verbose else "false"))
    lines.extend(driver.split("\n"))
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


def run_on_pty(cmd: List[str], cwd: str, timeout: float) -> Tuple[int, str]:
    """Run cmd with stdout and stderr on a pty and return (exit code, output). Luau's print is block-buffered on a pipe, so a
    killed run loses everything it printed; on a pty it is line-buffered and the output up to the kill survives.
    Raises GateError naming the last `RUN <case>` line when the run outlives timeout."""
    import pty
    import select

    master, slave = pty.openpty()
    proc = subprocess.Popen(cmd, cwd=cwd, stdin=subprocess.DEVNULL, stdout=slave, stderr=slave)
    os.close(slave)
    chunks: List[bytes] = []
    deadline = time.time() + timeout
    try:
        while True:
            if time.time() > deadline:
                proc.kill()
                proc.wait()
                running = [l for l in b"".join(chunks).decode("utf-8", "replace").splitlines() if l.startswith("RUN ")]
                raise GateError("timed out after %ds; last case started: %s" % (timeout, running[-1][4:] if running else "none"))
            if not select.select([master], [], [], 0.5)[0]:
                continue
            try:
                data = os.read(master, 65536)
            except OSError:  # Linux: EIO once the child has closed the pty
                data = b""
            if not data:
                break
            chunks.append(data)
    finally:
        os.close(master)
    return proc.wait(), b"".join(chunks).decode("utf-8", "replace").replace("\r\n", "\n")


def run_bundle(luau: Path, mode: str, case_filter: Optional[str] = None, verbose: bool = False, timeout: int = 600) -> Tuple[int, str, str]:
    source, spans = build_bundle(mode, case_filter, verbose)
    with tempfile.TemporaryDirectory(prefix="plotroom-bundle-") as tmp:
        script = Path(tmp) / "plotroom-bundle.luau"
        script.write_text(source, encoding="utf-8")
        if verbose:  # a pty keeps the RUN lines of a run that never returns
            code, out = run_on_pty([str(luau), str(script)], str(ROOT), timeout)
            return code, remap(out, spans), ""
        done = run([str(luau), str(script)], cwd=str(ROOT), timeout=timeout)
    return done.returncode, remap(done.stdout, spans), remap(done.stderr, spans)


# --------------------------------------------------------------------------- checks


def luau_banner(luau: Path) -> str:
    # The Luau CLI has no --version: the binary is identified by hash; `tools` installs the pinned release.
    verdict = "pinned release %s verified" % LUAU_VERSION if luau_is_pinned(luau) else "NOT the pinned release %s" % LUAU_VERSION
    return "luau %s (sha256 %s; %s)" % (luau, sha256_file(luau)[:16], verdict)


CSS_SCOPES = ("[data-surface='plugin.plotroom.prs']", "[data-surface='plugin.plotroom.review']")
# AGENTS.md › Code Conventions: lengths are px/em/vw/vh/% only (Tern also accepts ch, but the sheet stays off it); times,
# angles and grid tracks take the units Tern's CSS reference lists.
CSS_UNITS = {"px", "em", "vw", "vh", "%", "s", "ms", "deg", "rad", "grad", "turn", "fr"}
# Tern drops every logical property ("Coming from the web" in its CSS reference): any name with an inline/block segment
# (margin-inline, inline-size, min-block-size, inset-inline-start, ...) and the corner radii.
CSS_LOGICAL = re.compile(r"(^|-)(inline|block)(-|$)|^border-(start|end)-(start|end)-radius$")


def css_strip_comments(text: str) -> str:
    out: List[str] = []
    quote = ""
    i = 0
    while i < len(text):
        c = text[i]
        if quote:
            out.append(c)
            if c == "\\":
                out.append(text[i + 1 : i + 2])
                i += 1
            elif c == quote:
                quote = ""
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = len(text) if end < 0 else end + 1
        else:
            if c in "\"'":
                quote = c
            out.append(c)
        i += 1
    return "".join(out)


def css_split(text: str, sep: str) -> List[str]:
    """Split at sep outside strings, parentheses and brackets (a `;` in url() or a `,` in :is(a, b) stays put)."""
    parts: List[str] = []
    quote = ""
    depth = 0
    start = 0
    i = 0
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\":
                i += 1
            elif c == quote:
                quote = ""
        elif c in "\"'":
            quote = c
        elif c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif c == sep and depth <= 0:
            parts.append(text[start:i])
            start = i + 1
        i += 1
    parts.append(text[start:])
    return parts


def css_rules(text: str) -> List[Tuple[str, List[str]]]:
    """(prelude, own declarations) of every block of a comment-free sheet, inner blocks first."""
    rules: List[Tuple[str, List[str]]] = []
    frames: List[Tuple[str, List[str]]] = []
    quote = ""
    depth = 0
    start = 0
    i = 0
    while i < len(text):
        c = text[i]
        if quote:
            if c == "\\":
                i += 1
            elif c == quote:
                quote = ""
        elif c in "\"'":
            quote = c
        elif c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        elif depth <= 0 and c == "{":
            frames.append((text[start:i].strip(), []))
            start = i + 1
        elif depth <= 0 and c == ";":
            if frames:
                frames[-1][1].append(text[start:i])
            start = i + 1
        elif depth <= 0 and c == "}":
            if frames:
                prelude, decls = frames.pop()
                decls.append(text[start:i])
                rules.append((prelude, [d.strip() for d in decls if d.strip()]))
            start = i + 1
        i += 1
    return rules


def css_unit_problems(value: str) -> List[str]:
    value = re.sub(r"\"[^\"]*\"|'[^']*'|url\([^)]*\)|#[0-9a-fA-F]+\b|var\(\s*--[\w-]+", "", value)
    return [
        "unsupported unit %r" % found.group(0)
        for found in re.finditer(r"(?<![\w.])(?:\d+\.?\d*|\.\d+)([a-zA-Z%]+)", value)
        if found.group(1).lower() not in CSS_UNITS
    ]


def css_problems(source: str) -> List[str]:
    """What plotroom.css (or a fixture) breaks: scoped selectors, and none of the syntax Tern's engine rejects (docs.stencil.so/tern/styles/css.md)."""
    text = css_strip_comments(source)
    problems: List[str] = []
    rules = css_rules(text)
    for prelude, decls in rules:
        if prelude.startswith("@"):
            problems.extend(css_unit_problems(prelude))
        elif not re.fullmatch(r"(from|to|[\d.]+%)(\s*,\s*(from|to|[\d.]+%))*", prelude):
            for selector in css_split(prelude, ","):
                if not selector.strip().startswith(CSS_SCOPES):
                    problems.append("selector outside the block's scope: %s" % selector.strip())
            if ":has(" in prelude:
                problems.append("unsupported CSS ':has('")
        for decl in decls:
            name, _, value = decl.partition(":")
            name = name.strip().lower()
            if CSS_LOGICAL.search(name):
                problems.append("unsupported CSS property %r" % name)
            problems.extend(css_unit_problems(value))
    # DESIGN.md: colours are Tern variables (no hex or literal rgb/hsl), and a meaning colour comes from a node's tone,
    # never from this file.
    for bad in (r"#[0-9a-fA-F]{3,8}\b", r"\b(rgba?|hsla?)\(\s*[\d.]", r"var\(--(bad|ok|warn|live|sf-bad|sf-ok|sf-warn|sf-info)\)"):
        for found in re.finditer(bad, text):
            problems.append("colour outside DESIGN.md %r" % found.group(0))
    # Tern's Styling views: a plugin animation stops under .sf-still and pauses under .sf-paused (a hidden pane), so
    # every rule that runs a named animation has both, on its selector with the state class on the block's scope.
    for prelude, decls in rules:
        if not any(re.match(r"animation\s*:\s*(?!none\b)[a-z]", d) for d in decls):
            continue
        for selector in css_split(prelude, ","):
            selector = selector.strip()
            scope = next((s for s in CSS_SCOPES if selector.startswith(s)), None)
            if scope is None:
                continue
            for state, declaration in (("sf-still", r"animation\s*:\s*none\b"), ("sf-paused", r"animation-play-state\s*:\s*paused\b")):
                want = scope + "." + state + selector[len(scope):]
                if not any(want in [s.strip() for s in css_split(p, ",")] and any(re.match(declaration, d) for d in ds) for p, ds in rules):
                    problems.append("animation without a .%s rule: %s" % (state, selector))
    return problems


_P = CSS_SCOPES[0]
CSS_GOOD = """
/* a comment with a stray { and 5rem */
%(p)s .a:is(.b, .c)[data-x='a{b;c,d'] { margin: -2px 1.5em .5em 0; width: calc(100%% - 4px); text-align: start; flex: 1fr; transition: opacity 150ms, color .2s; transform: rotate(45deg); }
%(p)s .u { background-image: url("data:image/svg+xml;utf8,<svg width='2'/>"); content: "}; 3pt"; border-radius: 4px; height: 100vh; max-width: 50vw; color: var(--a1); }
@media (max-width: 600px) { %(p)s .m { padding: 2px; } }
@keyframes spin { from { opacity: 0; } 50%% { opacity: .5; } to { opacity: 1; } }
%(p)s .spin { animation: spin 1s linear infinite; }
%(p)s.sf-still .spin { animation: none; }
%(p)s.sf-paused .spin { animation-play-state: paused; }
""" % {"p": _P}
# (snippet, the one problem it must report); every snippet is otherwise scoped and valid.
CSS_BAD = [(snippet.replace("S", _P), expect) for snippet, expect in [
    (".x { color: red; }", "outside the block's scope: .x"),
    ("S :is(.a, .b), .x { color: red; }", "outside the block's scope: .x"),
    ("S .a:has(.b) { color: red; }", "':has('"),
    ("S .a { width: 2rem; }", "'2rem'"),
    ("S .a { width: 3ch; }", "'3ch'"),
    ("S .a { margin: -1pt; }", "'1pt'"),
    ("S .a { width: 1cm; }", "'1cm'"),
    ("S .a { width: 50vmin; }", "'50vmin'"),
    ("S .a { width: 50vmax; }", "'50vmax'"),
    ("S .a { height: 1lh; }", "'1lh'"),
    ("S .a { height: 100dvh; }", "'100dvh'"),
    ("S .a { width: 10cqw; }", "'10cqw'"),
    ("S .a { width: calc(1em + 2pt); }", "'2pt'"),
    ("@media (max-width: 40rem) { S .a { color: red; } }", "'40rem'"),
    ("S .a { inline-size: 1px; }", "'inline-size'"),
    ("S .a { block-size: 1px; }", "'block-size'"),
    ("S .a { min-inline-size: 1px; }", "'min-inline-size'"),
    ("S .a { max-block-size: 1px; }", "'max-block-size'"),
    ("S .a { margin-inline: 1px; }", "'margin-inline'"),
    ("S .a { padding-block-start: 1px; }", "'padding-block-start'"),
    ("S .a { inset-inline-start: 1px; }", "'inset-inline-start'"),
    ("S .a { border-start-start-radius: 1px; }", "'border-start-start-radius'"),
    ("S .a { color: #fff; }", "'#fff'"),
    ("S .a { color: rgb(1 2 3); }", "'rgb(1'"),
    ("S .a { color: var(--bad); }", "'var(--bad)'"),
    ("S .a { animation: spin 1s; }", "animation without a .sf-still rule"),
    ("S .a { animation: spin 1s; }\nS.sf-still .a { animation: none; }", "animation without a .sf-paused rule"),
    # a `;` or `}` inside url() or a string must not hide the declaration after it
    ("S .a { background-image: url(\"data:image/svg+xml;utf8,<svg/>\"); margin-inline: 1px; }", "'margin-inline'"),
    ("S .a { content: \"};\"; width: 2pt; }", "'2pt'"),
]]


def check_css_lint() -> None:
    """Prove css_problems still rejects every known-bad sheet and accepts the good one (a regex edit must not turn the lint into a no-op)."""
    wrong = ["a good sheet was rejected: " + "; ".join(css_problems(CSS_GOOD))] if css_problems(CSS_GOOD) else []
    for snippet, expect in CSS_BAD:
        found = css_problems(snippet)
        if not any(expect in p for p in found):
            wrong.append("%r reported %r, not %r" % (snippet, found, expect))
    if wrong:
        raise GateError("scripts/check.py css lint self-test: " + "; ".join(wrong[:5]))


def check_css() -> None:
    problems = css_problems((PLUGIN / "plotroom.css").read_text(encoding="utf-8"))
    if problems:
        raise GateError("plugin/plotroom.css: " + "; ".join(problems[:5]))


def check_test(case_filter: Optional[str] = None, verbose: bool = False) -> str:
    check_css_lint()
    check_css()
    unlisted = [p.stem for p in sorted((PLUGIN / "tests" / "cases").glob("*.luau")) if 'require("./cases/%s")' % p.stem not in (PLUGIN / "tests" / "regression.luau").read_text(encoding="utf-8")]
    if unlisted:
        raise GateError("plugin/tests/cases/ files not required by plugin/tests/regression.luau (they would run nothing): %s" % ", ".join(unlisted))
    luau = find_tool("luau", "LUAU")
    say("test: " + luau_banner(luau))
    code, out, err = run_bundle(luau, "test", case_filter, verbose)
    sys.stdout.write(out)
    sys.stderr.write(err)
    match = re.search(r"^REGRESSION cases=(\d+) failed=(\d+)$", out, re.M)
    if code != 0 or not match or int(match.group(2)) != 0:
        raise GateError("regression suite failed (exit %d)" % code)
    cases = int(match.group(1))
    return "%d regression cases%s" % (cases, " (only those named %r: not the full gate)" % case_filter if case_filter else "")


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
    worst = ("", 0.0, 0.0)  # row name, ms, its budget: the row closest to (or furthest over) its budget
    for row in rows:
        name = row.split()[1]
        fields = dict(re.findall(r"(\w+)=([0-9.]+)", row))
        if "ms" in fields:
            budget = float(BENCH_BUDGET_ENV) if BENCH_BUDGET_ENV else BENCH_BUDGETS_MS.get(name, BENCH_DEFAULT_MS)
            ms = float(fields["ms"])
            if ms > budget:
                raise GateError("bench row %s took %.1f ms, over its %.0f ms budget (BENCH_BUDGETS_MS, PLOTROOM_BENCH_BUDGET_MS)" % (name, ms, budget))
            if worst[0] == "" or ms / budget > worst[1] / worst[2]:
                worst = (name, ms, budget)
        elif "bytes" in fields:
            if name.startswith("payload") and float(fields["bytes"]) >= BENCH_PAYLOAD_MAX:
                raise GateError("bench row %s is %d bytes, not under %d" % (name, float(fields["bytes"]), BENCH_PAYLOAD_MAX))
        else:
            raise GateError("bench row %s has neither ms= nor bytes=, so no budget covers it: %s" % (name, row))
    return "%d rows, closest to budget: %s %.1f of %.0f ms" % (len(rows), worst[0], worst[1], worst[2])


def check_version() -> str:
    """plugin.toml's version has its own `## [<version>]` heading in CHANGELOG.md, so every release says what changed."""
    version = re.search(r'^version = "([^"]*)"', (PLUGIN / "plugin.toml").read_text(encoding="utf-8"), re.M)
    if not version:
        raise GateError("cannot read version from plugin/plugin.toml")
    changelog = ROOT / "CHANGELOG.md"
    text = changelog.read_text(encoding="utf-8") if changelog.is_file() else ""
    if not re.search(r"^## \[%s\]" % re.escape(version.group(1)), text, re.M):
        raise GateError("CHANGELOG.md has no \"## [%s]\" heading for plugin/plugin.toml's version" % version.group(1))
    return "plugin %s is in CHANGELOG.md" % version.group(1)


def md_fenced(text: str) -> str:
    """Markdown without fenced code blocks, so a heading or link shown as an example is not read as one."""
    return re.sub(r"^(```|~~~).*?^\1[ \t]*$", "", text, flags=re.M | re.S)


def md_text(text: str) -> str:
    """md_fenced, and inline code spans blanked as well (a link inside one is an example too)."""
    return re.sub(r"`[^`\n]*`", "", md_fenced(text))


def md_slugs(text: str) -> set:
    """The anchors GitHub gives each heading: lowercase, inline markup and punctuation dropped, spaces to hyphens, repeats suffixed -1, -2."""
    seen: dict = {}
    slugs = set()
    for heading in re.findall(r"^#{1,6}[ \t]+(.+?)[ \t#]*$", md_fenced(text), re.M):
        heading = re.sub(r"!?\[([^\]]*)\]\([^)]*\)", r"\1", heading)
        slug = re.sub(r"[^\w\- ]", "", heading.replace("`", "").replace("*", "").lower()).replace(" ", "-")
        count = seen.get(slug, 0)
        seen[slug] = count + 1
        slugs.add(slug if count == 0 else "%s-%d" % (slug, count))
    return slugs


def md_link_problems(root: Path, files: List[Path]) -> List[str]:
    """Every relative link or image in `files` (relative to root) names a file that exists and, with #anchor, a heading in it."""
    problems = []
    slugs: dict = {}
    for path in files:
        for target in re.findall(r"\]\(<?([^)\s>]+)", md_text(path.read_text(encoding="utf-8"))):
            if re.match(r"[a-z][a-z0-9+.-]*:", target, re.I):
                continue
            name, _, anchor = target.partition("#")
            dest = (path.parent / name).resolve() if name else path
            where = "%s: %s" % (path.relative_to(root), target)
            if not dest.is_file():
                problems.append("%s: no such file" % where)
            elif anchor and dest.suffix == ".md":
                if dest not in slugs:
                    slugs[dest] = md_slugs(dest.read_text(encoding="utf-8"))
                if anchor not in slugs[dest]:
                    problems.append("%s: no such heading" % where)
    return problems


def check_docs() -> str:
    """Docs hold together: relative links and #anchors in the markdown resolve, and README's screenshots are all used and under 400 KB."""
    with tempfile.TemporaryDirectory() as tmp:  # prove the link check against known-bad links, as CSS_BAD does for the CSS lint
        sample = Path(tmp) / "a.md"
        sample.write_text("# Intake: Now, views and `Pins`\n\n## Dup\n\n## Dup\n\n[ok](#intake-now-views-and-pins) [ok](a.md#dup-1) [web](https://x.y/z#q)\n\n```\n[x](gone.md)\n```\n", encoding="utf-8")
        if md_link_problems(Path(tmp), [sample]):
            raise GateError("docs link check flags good links")
        sample.write_text("[a](gone.md) [b](#nope) [c](a.md#nope) ![d](img.png)\n", encoding="utf-8")
        if len(md_link_problems(Path(tmp), [sample])) != 4:
            raise GateError("docs link check misses bad links")
    problems = md_link_problems(ROOT, sorted(ROOT.glob("*.md")) + sorted((ROOT / "docs").glob("*.md")))
    images = sorted((ROOT / "docs" / "images").glob("*.png"))
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    for image in images:
        if image.stat().st_size > IMAGE_MAX:
            problems.append("docs/images/%s is %d bytes, over %d" % (image.name, image.stat().st_size, IMAGE_MAX))
        if "docs/images/%s" % image.name not in readme:
            problems.append("docs/images/%s is not used by README.md" % image.name)
    if problems:
        raise GateError("; ".join(problems[:8]))
    return "links resolve, %d screenshots under %d KB" % (len(images), IMAGE_MAX // 1000)


def ext_runtime() -> List[str]:
    """bun, else node 23.6 or newer (it runs .ts files as they are); [] when neither is on PATH."""
    bun = shutil.which("bun")
    if bun:
        return [bun]
    node = shutil.which("node")
    version = re.match(r"v(\d+)\.(\d+)", run([node, "--version"]).stdout) if node else None
    return [node] if node and version and (int(version.group(1)), int(version.group(2))) >= (23, 6) else []


def check_ext() -> str:
    runtime = ext_runtime()
    if not runtime:
        raise NotRun("needs bun, or node 23.6 or newer, on PATH")
    banner = run(runtime + ["--version"]).stdout.strip()
    say("ext: %s %s" % (runtime[0], banner))
    done = run(runtime + [str(PLUGIN / "tests" / "extension.ts")], cwd=str(ROOT), timeout=300)
    sys.stdout.write(done.stdout)
    sys.stderr.write(done.stderr)
    match = re.search(r"^EXT cases=(\d+) failed=(\d+)$", done.stdout, re.M)
    if done.returncode != 0 or not match or int(match.group(2)) != 0:
        raise GateError("plugin/tests/extension.ts failed (exit %d)" % done.returncode)
    return "%s extension cases (%s %s)" % (match.group(1), Path(runtime[0]).name, banner)


def load_smoke():
    sys.modules.setdefault("check", sys.modules[__name__])  # run as __main__: smoke.py must share this module's GateError
    import smoke

    return smoke


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
    if os.environ.get("GITHUB_ACTIONS") == "true":
        for name, status, detail in results:
            if status == "NOT RUN":
                say("::notice title=Plotroom gate::%s NOT RUN: %s" % (name, detail))
    return 1 if failed else 0


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(description="Plotroom verification gate", formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", nargs="?", default="all", choices=["all", "test", "types", "bench", "ext", "smoke", "tools"])
    parser.add_argument("--ci", action="store_true", help="skip the real-Tern smoke and say so (Tern is not available on CI)")
    parser.add_argument("-k", dest="case_filter", metavar="SUBSTRING", default=None, help="test only: run just the regression cases whose name contains SUBSTRING (default: $PLOTROOM_CASE)")
    parser.add_argument("-v", "--verbose", action="store_true", help="test only: print `RUN <name>` before each case, so a hang names its case")
    args = parser.parse_args(argv)
    if (args.case_filter or args.verbose) and args.command != "test":
        parser.error("-k and -v apply to `test` only")
    if args.command == "test" and not args.case_filter:
        args.case_filter = os.environ.get("PLOTROOM_CASE") or None

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
        plan.append(("test", lambda: check_test(args.case_filter, args.verbose)))
        plan.append(("version", check_version))
        plan.append(("docs", check_docs))
    if args.command in ("all", "types"):
        plan.append(("types", check_types))
    if args.command in ("all", "bench"):
        plan.append(("bench", check_bench))
    if args.command in ("all", "ext"):
        plan.append(("ext", check_ext))
    results: List[Tuple[str, str, str]] = []
    if args.command in ("all", "smoke") and not args.ci:
        plan.append(("smoke", load_smoke().check_smoke))

    for name, check in plan:
        say("== %s ==" % name)
        started = time.time()
        try:
            detail = check()
            results.append((name, "PASS", "%s (%.1fs)" % (detail, time.time() - started)))
        except GateError as error:
            say("%s: FAIL: %s" % (name, error))
            results.append((name, "FAIL", str(error)))
        except NotRun as why:
            say("%s: NOT RUN: %s" % (name, why))
            results.append((name, "NOT RUN", str(why)))
        except subprocess.TimeoutExpired as error:
            say("%s: FAIL: timed out: %s" % (name, error))
            results.append((name, "FAIL", "timed out" + ("; rerun `python3 scripts/check.py test -v` to name the case that hangs" if name == "test" else "")))
    if args.command in ("all", "smoke"):
        if args.ci:
            load_smoke()  # a syntax or import error in smoke.py must still fail CI
            results.append(("smoke", "NOT RUN", "--ci: Tern is not available on CI; run `python3 scripts/check.py smoke` locally"))
        else:
            results.extend(("smoke", "WARN", warning) for warning in load_smoke().WARNINGS)
    return summarize(results)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
