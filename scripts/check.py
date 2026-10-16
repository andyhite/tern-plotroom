#!/usr/bin/env python3
"""Verification gate for the Plotroom plugin. Standard library only, Python 3.9+.

    python3 scripts/check.py            test + types + bench + smoke (the full local gate)
    python3 scripts/check.py --ci       test + types + bench; smoke is reported NOT RUN (Tern is not on CI)
    python3 scripts/check.py test       standalone Luau regression suite (fake Tern SDK) only
    python3 scripts/check.py types      luau-lsp analyze against the pinned Tern SDK only
    python3 scripts/check.py bench      1000-PR queue render benchmark only
    python3 scripts/check.py smoke      isolated headless Tern + real git only
    python3 scripts/check.py tools      download the pinned Luau and luau-lsp (sha256-verified)

test    plugin/tests/regression.luau (which also runs the plugin/tests/check.luau selftest), run by the
        Luau CLI from a temporary bundle: every plugin/*.luau module wrapped as function(tern, require, os),
        so each case gets a fresh fake SDK (virtual clock, process, kv, fs, json, ui, blocks) and fresh
        module state. No network, no git, no files outside a temporary directory.
types   luau-lsp analyze --platform standard against scripts/tern-0.8.3.d.luau (a copy of the SDK that
        `tern plugin types` writes), over plugin/*.luau and plugin/tests/*.luau. Any diagnostic, warnings
        included, fails: luau-lsp exits 0 on lint warnings.
bench   renders the real queue view with 1000 PRs and fails above PLOTROOM_BENCH_BUDGET_MS per render.
smoke   `tern serve` headless on temporary directories only (never the live daemon or plugin registry):
        the selftest toast, no stylesheet errors in the log, real-git worktree scenarios driven
        through plugin.plotroom.smoke (plugin/tests/runtime.luau: open, open an issue's, remote branches, scan)
        with a fake gh on PATH, and a Plotroom block on an attached loopback host that shows a worktree made
        before it (read from git), then makes its worktree through the real link flow.

Tools: LUAU, LUAU_LSP, TERN (paths) -> the cache below -> PATH. `tools` is the only network access.
Pinned: Luau 0.742, luau-lsp 1.70.1, Tern 0.8.3 (e2b8656). Cache: $XDG_CACHE_HOME or ~/.cache, plotroom-check/.
Smoke prerequisites: Tern 0.8.3, 0.8.4, 0.9.0 or 0.9.1 (TERN=/path or PATH; the SDK snapshot stays the pinned 0.8.3), git >= 2.36, omp on PATH,
Python 3.9+. No network; every repository (bare remotes included), fake gh/ssh, Tern directory and log lives under one temporary
directory that is deleted afterwards.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

ROOT = Path(__file__).resolve().parent.parent
PLUGIN = ROOT / "plugin"
SDK = ROOT / "scripts" / "tern-0.8.3.d.luau"
SDK_SHA256 = "9de89a72134645d64ea6adf595691b04a24ab6aae3f9f90ecd89a0bb79c4e95e"
LUAU_VERSION = "0.742"
LSP_VERSION = "1.70.1"
TERN_VERSION = "0.8.3"  # the SDK pin
SMOKE_TERN_VERSIONS = ("0.8.3", "0.8.4", "0.9.0", "0.9.1")  # runtimes the smoke accepts; `tern --version` must start with `tern <version>`
BENCH_BUDGET_MS = float(os.environ.get("PLOTROOM_BENCH_BUDGET_MS", "250"))

# sha256 of the release assets, as GitHub publishes them.
TOOLS = {
    "luau": {
        "version": LUAU_VERSION,
        "base": "https://github.com/luau-lang/luau/releases/download/%s/" % LUAU_VERSION,
        "member": "luau",
        "assets": {
            "Darwin": ("luau-macos.zip", "bdd415766fbe03bc090b65fa6141531a4a54608db95a5350a5a0b49862bdac83"),
            "Linux": ("luau-ubuntu.zip", "152058b98c60ff1f5b5ec9bca0b8eb37793cae161dd3a05608cc3d8738ba1a4d"),
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

# Tern variables that would point `tern serve` at the live window or daemon.
TERN_UNSET = (
    "TERN_PANE",
    "TERN_PANE_SOCKET",
    "TERN_WINDOW_KEY",
    "TERN_WINDOW_SOCKET",
    "TERN_ACP",
    "TERN_IDENTITY",
    "TERN_COMPLETE",
    "TERN_LENSES",
)


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
    """Every Luau file of the package except the SDK definitions."""
    files = [p for p in sorted(PLUGIN.glob("*.luau")) if not p.name.endswith(".d.luau")]
    files += sorted((PLUGIN / "tests").glob("*.luau"))
    return files


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


def check_test() -> str:
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
    if worst > BENCH_BUDGET_MS:
        raise GateError("slowest render %.1f ms exceeds the %.0f ms budget (PLOTROOM_BENCH_BUDGET_MS)" % (worst, BENCH_BUDGET_MS))
    return "%d rows, slowest %.1f ms (budget %.0f ms)" % (len(rows), worst, BENCH_BUDGET_MS)


# --------------------------------------------------------------------------- smoke
# One isolated headless `tern serve` (everything under a temp dir), a fake gh and ssh, real git repositories.
# plugin.plotroom.smoke (plugin/tests/runtime.luau) runs worktree.open (a PR's), worktree.openIssue (an issue's), worktree.remoteBranches or
# worktree.scan for each scenario; git is the oracle.

SMOKE_TOAST = "Plotroom self-test passed"
GIT_MIN = (2, 36)  # `git worktree list --porcelain -z` arrived in 2.36
SYSTEM_PATH = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
SMOKE_TIMEOUT = 60  # seconds a single smoke request may take

# Fake gh: `--version` (the block asks whether gh starts before it lists GitHub views), the canned pull request file (the
# answer the real call's --jq prints, see Smoke.canned), or the 404 gh prints for a pull request it cannot see; a search
# answers with the canned list in search.json (none: empty), a checks load with no checks, `auth status` with one
# signed-in login (the repository picker's list, warmed after a search). Header is prepended.
FAKE_GH = r'''
import json, os, re, sys
a = sys.argv[1:]
m = None
if a == ["--version"]:
    sys.stdout.write("gh version 2.98.0 (smoke)\n")
    sys.exit(0)
if len(a) == 6 and a[:3] == ["api", "--hostname", "github.com"] and a[4] == "--jq":
    m = re.fullmatch(r"repos/([^/]+)/([^/]+)/pulls/(\d+)", a[3])
if a[:2] == ["api", "graphql"]:
    fields = dict(x.split("=", 1) for x, flag in zip(a[1:], a) if flag in ("-f", "-F") and "=" in x)
    if "q" in fields and "/issues/" in fields["q"]:  # one issue by its URL, from issues.json (issues are never in the pull request list)
        f = os.path.join(SMOKE, "issues.json")
        items = [i for i in (json.load(open(f)) if os.path.exists(f) else []) if fields["q"].endswith("/issues/%s" % i.get("number"))]
        sys.stdout.write(json.dumps({"total": len(items), "next": None, "cost": 1, "items": items}))
        sys.exit(0)
    if "q" in fields:
        f = os.path.join(SMOKE, "search.json")
        items = json.load(open(f)) if os.path.exists(f) else []
        pinned = re.search(r"/pull/(\d+)", fields["q"])  # a pull request URL asks for that one item, as GitHub's search does
        if pinned:
            items = [i for i in items if str(i.get("number")) == pinned.group(1)]
        sys.stdout.write(json.dumps({"total": len(items), "next": None, "cost": 1, "items": items}))
        sys.exit(0)
    if "o" in fields:
        if "first: 25" in fields.get("query", ""):  # the pull requests that close an issue (the --jq answer is a list): none
            sys.stdout.write("[]")
            sys.exit(0)
        sys.stdout.write(json.dumps({"total": 0, "next": None, "nodes": []}))
        sys.exit(0)
if a == ["auth", "status", "--hostname", "github.com", "--json", "hosts"]:
    sys.stdout.write(json.dumps({"hosts": {"github.com": [{"state": "success", "active": True, "host": "github.com", "login": "smoke"}]}}))
    sys.exit(0)
if m:
    f = os.path.join(SMOKE, "pr", "%s__%s__%s.json" % m.groups())
    if os.path.exists(f):
        with open(f) as handle:
            sys.stdout.write(handle.read())
        sys.exit(0)
    sys.stderr.write("gh: Not Found (HTTP 404)\n")
    sys.exit(1)
with open(os.path.join(SMOKE, "unexpected.log"), "a") as log:
    log.write("gh %r\n" % (a,))
sys.exit(2)
'''

# Fake ssh: only `git-upload-pack` / `git-receive-pack 'owner/name.git'`, served from the local bare repository (never a real remote).
FAKE_SSH = r'''
import os, shlex, sys
a = sys.argv[1:]
w = []
try:
    w = shlex.split(a[-1]) if a else []
except ValueError:
    pass
if len(w) == 2 and w[0] in ("git-upload-pack", "git-receive-pack") and not w[1].startswith("/") and ".." not in w[1].split("/"):
    os.execv(GIT, [GIT, w[0][4:], os.path.join(SMOKE, "remotes", w[1])])
with open(os.path.join(SMOKE, "unexpected.log"), "a") as log:
    log.write("ssh %r\n" % (a,))
sys.exit(2)
'''


def smoke_prerequisites() -> Tuple[str, str, str]:
    """(tern, git, omp) executables, or a GateError saying what to install."""
    given = os.environ.get("TERN")
    tern = str(Path(given).expanduser()) if given else shutil.which("tern")
    if not tern or not os.path.isfile(tern) or not os.access(tern, os.X_OK):
        raise GateError(
            "smoke needs Tern %s: %s. Install one, or set TERN=/path/to/tern."
            % (" or ".join(SMOKE_TERN_VERSIONS), "TERN=%s is not an executable file" % given if given else "no `tern` on PATH")
        )
    done = run([tern, "--version"], timeout=30)
    banner = (done.stdout + done.stderr).strip()
    reported = re.match(r"(?:tern\s+)?v?(\d+\.\d+\.\d+)(?=[\s(]|$)", banner, re.IGNORECASE)
    if not reported or reported.group(1) not in SMOKE_TERN_VERSIONS:
        raise GateError("smoke needs Tern %s; %s reports %r. Install one or set TERN=/path/to/tern." % (" or ".join(SMOKE_TERN_VERSIONS), tern, banner))
    git = shutil.which("git")
    if not git:
        raise GateError("smoke needs git >= %d.%d on PATH; none found." % GIT_MIN)
    said = run([git, "--version"], timeout=30).stdout.strip()
    m = re.search(r"git version (\d+)\.(\d+)", said)
    if not m or (int(m.group(1)), int(m.group(2))) < GIT_MIN:
        raise GateError("smoke needs git >= %d.%d; %s reports %r. Upgrade git." % (GIT_MIN + (git, said)))
    omp = shutil.which("omp")
    if not omp:
        raise GateError("smoke needs omp on PATH: Plotroom creates worktrees with `omp worktree add`.")
    return tern, git, omp


def file_tail(path: Path, count: int = 40) -> str:
    try:
        return "\n".join(path.read_text(encoding="utf-8", errors="replace").splitlines()[-count:])
    except OSError as why:
        return "(unreadable: %s)" % why


class Smoke:
    """The isolated Tern session, its fakes and fixtures, and the assertion helpers; label names the running scenario."""

    def __init__(self, tern: str, git: str, omp: str, tmp: Path):
        self.tern, self.gitbin, self.tmp = tern, git, tmp
        self.smoke = tmp / "smoke"
        self.sock = tmp / "ctl.sock"
        self.work = tmp / "work"
        self.label = "setup"
        self.last: object = None
        self.toast = False
        self.proc: "Optional[subprocess.Popen]" = None
        self.logf = None
        self.repos: Dict[str, Dict[str, object]] = {}
        self.shas: Dict[Tuple[str, int], str] = {}
        for d in ("bin", "gitssh", "work", "scratch", "home", "logs", "blobs", "config"):
            (tmp / d).mkdir()
        for d in ("pr", "remotes"):
            (self.smoke / d).mkdir(parents=True)
        self.fixtures = tmp / "ws" / "crates" / "plugins" / "fixtures"
        self.cwd = tmp / "ws" / "crates" / "tern"
        (self.cwd / "goldens").mkdir(parents=True)
        shutil.copytree(PLUGIN, self.fixtures / "plotroom")
        header = "#!%s\nSMOKE = %r\nGIT = %r\n" % (sys.executable, str(self.smoke), git)
        for path, body in ((tmp / "bin" / "gh", FAKE_GH), (tmp / "gitssh" / "ssh", FAKE_SSH)):
            path.write_text(header + body, encoding="utf-8")
            path.chmod(0o755)
        paths = [str(tmp / "bin")] + SYSTEM_PATH
        for tool in (git, omp):
            if os.path.dirname(tool) not in paths:
                paths.append(os.path.dirname(tool))
        drop = ("GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "GH_ENTERPRISE_TOKEN")
        base = {k: v for k, v in os.environ.items() if not k.startswith("GIT_") and k not in TERN_UNSET and k not in drop}
        iso = {
            "PATH": os.pathsep.join(paths),
            "SHELL": "/bin/sh",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_SSH": str(tmp / "gitssh" / "ssh"),
        }
        self.env = dict(base, **iso)
        self.env.update(
            TERN_BLOB_DIR=str(tmp / "blobs"),
            TERN_CONFIG_DIR=str(tmp / "config"),
            TERN_DAEMON_SOCKET=str(tmp / "daemon.sock"),
            STENCIL_LOG_DIR=str(tmp / "logs"),
            STENCIL_FIXTURE_ROOT=str(self.cwd),
            PLOTROOM_SELFTEST="1",
            PLOTROOM_SMOKE_DIR=str(self.smoke),
            OMP_WORKTREE_DIR=str(tmp / "omp-wt"),
        )
        # A private HOME keeps the user's ~/.gitconfig out of fixtures too.
        self.genv = dict(base, **iso)
        self.genv.update(
            HOME=str(tmp / "home"),
            XDG_CONFIG_HOME=str(tmp / "home" / ".config"),
            GIT_TERMINAL_PROMPT="0",
            GIT_AUTHOR_NAME="Smoke",
            GIT_AUTHOR_EMAIL="smoke@example.invalid",
            GIT_COMMITTER_NAME="Smoke",
            GIT_COMMITTER_EMAIL="smoke@example.invalid",
        )

    # ----- assertions

    def fail(self, what: str, expected: object, actual: object) -> None:
        raise GateError("smoke %s: %s\n  expected: %s\n  actual:   %s" % (self.label, what, expected, actual))

    def eq(self, what: str, expected: object, actual: object) -> None:
        if expected != actual:
            self.fail(what, repr(expected), repr(actual))

    def contains(self, what: str, needle: str, hay: object) -> None:
        if not isinstance(hay, str) or needle not in hay:
            self.fail(what, "contains %r" % needle, repr(hay))

    def same_path(self, what: str, expected: Path, actual: object) -> None:
        if not isinstance(actual, str) or os.path.realpath(actual) != os.path.realpath(str(expected)):
            self.fail(what, "path %s" % os.path.realpath(str(expected)), repr(actual))

    # ----- git oracle and fixtures

    def git(self, cwd: Path, *args: str) -> "subprocess.CompletedProcess[str]":
        try:
            return run([self.gitbin, "-C", str(cwd)] + list(args), env=self.genv, timeout=SMOKE_TIMEOUT)
        except subprocess.TimeoutExpired:
            raise GateError("smoke %s: git -C %s %s timed out after %d s" % (self.label, cwd, " ".join(args), SMOKE_TIMEOUT))

    def out(self, cwd: Path, *args: str) -> str:
        done = self.git(cwd, *args)
        if done.returncode != 0:
            self.fail("git -C %s %s" % (cwd, " ".join(args)), "exit 0", "exit %d: %s" % (done.returncode, done.stderr.strip()))
        return done.stdout.rstrip("\n")

    def repo(self, owner: str, name: str, dirname: str, prs: Tuple[int, ...], deleted: Tuple[int, ...] = ()) -> None:
        """Bare remote with main and, for each PR, refs/pull/N/head and its head branch refs/heads/feature-N (not for `deleted`: merged, then the branch was
        deleted), plus a checkout (cloned first, so it knows none of them) whose origin reads as github.com but goes through fake ssh."""
        key = "%s/%s" % (owner, name)
        scratch = self.tmp / "scratch" / ("%s__%s" % (owner, name))
        bare = self.smoke / "remotes" / owner / ("%s.git" % name)
        scratch.mkdir()
        bare.parent.mkdir(exist_ok=True)
        self.out(scratch, "-c", "init.defaultBranch=main", "init", "-q")
        (scratch / "README.md").write_text("base of %s\n" % key, encoding="utf-8")
        self.out(scratch, "add", "README.md")
        self.out(scratch, "commit", "-q", "-m", "base")
        self.out(self.tmp, "clone", "-q", "--bare", str(scratch), str(bare))
        checkout = self.work / dirname
        self.out(self.tmp, "clone", "-q", str(bare), str(checkout))
        self.out(checkout, "remote", "set-url", "origin", "git@github.com:%s/%s.git" % (owner, name))
        self.repos[key] = {"scratch": scratch, "bare": bare, "count": 0}
        for n in prs:
            self.shas[(key, n)] = self.push_pr(key, n, "main", branch=n not in deleted)
            self.canned(key, n, self.shas[(key, n)])

    def push_pr(self, key: str, n: int, base: str, branch: bool = True) -> str:
        """A new commit on top of `base` (a scratch ref), pushed (forced) to the bare remote's refs/pull/n/head and, as the PR's head branch, to
        refs/heads/feature-n (`branch` False: the head lives in a fork, not here)."""
        r = self.repos[key]
        scratch, bare = r["scratch"], r["bare"]
        r["count"] = int(r["count"]) + 1  # type: ignore[arg-type]
        self.out(scratch, "checkout", "-q", "-B", "pr-%d" % n, base)  # type: ignore[arg-type]
        (scratch / ("pr-%d-%d.txt" % (n, r["count"]))).write_text("pull request %d, commit %d\n" % (n, r["count"]), encoding="utf-8")  # type: ignore[operator,index]
        self.out(scratch, "add", "-A")  # type: ignore[arg-type]
        self.out(scratch, "commit", "-q", "-m", "pr %d #%d" % (n, r["count"]))  # type: ignore[arg-type]
        sha = self.out(scratch, "rev-parse", "HEAD")  # type: ignore[arg-type]
        heads = ["%s:refs/heads/feature-%d" % (sha, n)] if branch else []
        self.out(scratch, "push", "-q", "--force", str(bare), "%s:refs/pull/%d/head" % (sha, n), *heads)  # type: ignore[arg-type]
        self.out(scratch, "checkout", "-q", "main")  # type: ignore[arg-type]
        return sha

    def advance(self, key: str) -> str:
        """A new commit on the bare remote's main, so a checkout's remote-tracking main is behind it until something fetches."""
        r = self.repos[key]
        scratch, bare = r["scratch"], r["bare"]
        r["count"] = int(r["count"]) + 1  # type: ignore[arg-type]
        self.out(scratch, "checkout", "-q", "main")  # type: ignore[arg-type]
        (scratch / ("main-%d.txt" % r["count"])).write_text("main moved, commit %d\n" % r["count"], encoding="utf-8")  # type: ignore[operator,index]
        self.out(scratch, "add", "-A")  # type: ignore[arg-type]
        self.out(scratch, "commit", "-q", "-m", "main #%d" % r["count"])  # type: ignore[arg-type]
        self.out(scratch, "push", "-q", str(bare), "main")  # type: ignore[arg-type]
        return self.out(scratch, "rev-parse", "HEAD")  # type: ignore[arg-type]

    def canned(self, key: str, n: int, sha: str, fork: str = "", gone: bool = False) -> None:
        """What the fake gh prints for PR n of `key` (the --jq answer): head `sha` on branch feature-n of the repository itself, of `fork`'s copy of it,
        or (`gone`) of that copy after it was deleted (no head repository then, only its owner)."""
        owner, name = key.split("/")
        who = fork or owner
        meta = {"base": key, "sha": sha, "ref": "feature-%d" % n, "headRepo": None if gone else "%s/%s" % (who, name), "headOwner": who, "state": "open",
                "baseRef": "main", "title": "Smoke PR %d" % n, "author": "octo"}
        (self.smoke / "pr" / ("%s__%s__%d.json" % (owner, name, n))).write_text(json.dumps(meta), encoding="utf-8")

    def fork_pr(self, key: str, n: int, gone: bool = False) -> None:
        """PR n of `key` from forkowner's copy of it: the remote holds only refs/pull/n/head for it (its branch lives in the fork); gh names the fork or,
        once it was deleted (`gone`), only its owner. The repository has a branch of its own called feature-n, at main: not the fork's."""
        self.shas[(key, n)] = self.push_pr(key, n, "main", branch=False)
        self.out(self.repos[key]["scratch"], "push", "-q", str(self.bare(key)), "main:refs/heads/feature-%d" % n)  # type: ignore[arg-type]
        self.canned(key, n, self.shas[(key, n)], fork="forkowner", gone=gone)

    def checkout(self, dirname: str) -> Path:
        return self.work / dirname

    def bare(self, key: str) -> Path:
        return self.repos[key]["bare"]  # type: ignore[return-value]

    def ref(self, cwd: Path, name: str) -> Optional[str]:
        """The commit `name` names in `cwd`'s repository, or None when there is no such ref."""
        done = self.git(cwd, "rev-parse", "--verify", "--quiet", name)
        if done.returncode not in (0, 1):
            self.fail("git -C %s rev-parse --verify --quiet %s" % (cwd, name), "exit 0 or 1", "exit %d: %s" % (done.returncode, done.stderr.strip()))
        return done.stdout.strip() if done.returncode == 0 else None

    def config(self, cwd: Path, key: str) -> Optional[str]:
        """The value of git config `key` in `cwd`'s repository, or None when it is not set."""
        done = self.git(cwd, "config", "--get", key)
        if done.returncode not in (0, 1):
            self.fail("git -C %s config --get %s" % (cwd, key), "exit 0 or 1", "exit %d: %s" % (done.returncode, done.stderr.strip()))
        return done.stdout.strip() if done.returncode == 0 else None

    def folders(self) -> List[str]:
        """What omp's worktrees folder holds, sorted."""
        base = self.tmp / "omp-wt"
        return sorted(p.name for p in base.iterdir()) if base.is_dir() else []

    def pr_dir(self, key: str, n: int) -> str:
        """The folder name the default PR format gives: plotroom-<owner>_<repo>-pr-N, owner and repo lowercase."""
        return "plotroom-%s-pr-%d" % (key.lower().replace("/", "_", 1), n)

    def issue_dir(self, key: str, ref: str) -> str:
        """The default issue format's: plotroom-<owner>_<repo>-issue-<ref>; the ref keeps its case (Jira's ABC-7)."""
        return "plotroom-%s-issue-%s" % (key.lower().replace("/", "_", 1), ref)

    def wt(self, key: str, n: int) -> Path:
        """Where Plotroom puts PR n's worktree: a direct child of omp's worktrees folder, named by the default PR format."""
        return self.tmp / "omp-wt" / self.pr_dir(key, n)

    def issue_wt(self, key: str, ref: str) -> Path:
        """Where Plotroom puts an issue's worktree under the default issue format."""
        return self.tmp / "omp-wt" / self.issue_dir(key, ref)

    # ----- the Tern session

    def alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def ctl(self, *args: str, timeout: int = SMOKE_TIMEOUT) -> str:
        cmd = [self.tern, "ctl", "--control", str(self.sock)] + list(args)
        try:
            done = run(cmd, env=self.env, timeout=timeout)
        except subprocess.TimeoutExpired:
            raise GateError("smoke %s: `tern ctl %s` timed out after %d s" % (self.label, " ".join(args), timeout))
        if done.returncode != 0:
            raise GateError("smoke %s: `tern ctl %s` exit %d: %s%s" % (self.label, " ".join(args), done.returncode, done.stdout.strip(), done.stderr.strip()))
        return done.stdout

    def ctl_ok(self, *args: str) -> None:
        said = self.ctl(*args)
        try:
            ok = json.loads(said).get("ok") is True
        except (ValueError, AttributeError):
            ok = False
        if not ok:
            self.fail("`tern ctl %s`" % " ".join(args), '{"ok":true}', repr(said.strip()))

    def state(self) -> Dict[str, object]:
        return json.loads(self.ctl("state"))

    def texts(self) -> List[str]:
        """Every text, value, label and title in the UI tree."""
        out: List[str] = []

        def walk(node: object) -> None:
            if isinstance(node, dict):
                for key in ("text", "value", "label", "title", "placeholder"):
                    if isinstance(node.get(key), str):
                        out.append(node[key])
                walk(node.get("children") or [])
                walk(node.get("spans") or [])
            elif isinstance(node, list):
                for child in node:
                    walk(child)

        walk(json.loads(self.ctl("tree")).get("tree"))
        return out

    def preview_texts(self) -> List[str]:
        """Texts inside the drawn native preview slot (`pk-pv-slot`) that has a positive-size rect; empty when no such slot is drawn."""
        out: List[str] = []

        def sized(node: Dict[str, object]) -> bool:
            r = node.get("rect")
            if isinstance(r, dict):
                w, h = r.get("w", r.get("width")), r.get("h", r.get("height"))
            elif isinstance(r, list) and len(r) >= 4:
                w, h = r[2], r[3]
            else:
                return False
            return isinstance(w, (int, float)) and isinstance(h, (int, float)) and w > 0 and h > 0

        def collect(node: object) -> None:
            if isinstance(node, dict):
                for key in ("text", "value", "label", "title"):
                    if isinstance(node.get(key), str) and node[key].strip():
                        out.append(node[key])
                collect(node.get("children") or [])
                collect(node.get("spans") or [])
            elif isinstance(node, list):
                for child in node:
                    collect(child)

        def walk(node: object) -> None:
            if isinstance(node, dict):
                if "pk-pv-slot" in str(node.get("class") or "").split() and sized(node):
                    collect(node)
                else:
                    walk(node.get("children") or [])
            elif isinstance(node, list):
                for child in node:
                    walk(child)

        walk(json.loads(self.ctl("tree")).get("tree"))
        return out

    def previewing(self) -> bool:
        """A nonempty native preview is rendered: a row is selected, the sized `pk-pv-slot` holds text, and that text names the selected row; no placeholder."""
        chosen = [str(c) for c in self.selection() if c]
        inside = self.preview_texts()
        return bool(chosen) and bool(inside) and any(c in t for c in chosen for t in inside) and not any("Nothing to preview" in t for t in inside)

    def select_row(self) -> None:
        """A nonempty list opens with its first row selected; if none is (an empty or still-loading list), choose one (Down) as a user does; a selection already held is kept."""
        if not self.selection():
            self.ctl_ok("key", "Down")
        self.wait_until("a row is selected", lambda: len(self.selection()) >= 1)

    def selection(self) -> List[object]:
        """The primary label of every row visibly selected. Tern 0.9.1 can leave a stale `sel` class (and aria-selected) on the row just left when the new
        selection's row changes in the same render, so while the native `pk-selbar` is drawn, only `sel` rows that sit exactly under it count; with no bar
        (older Tern) the `pk-row`+`sel` classes decide. Empty: nothing is chosen."""
        rows: List[Tuple[str, Optional[List[float]]]] = []
        bars: List[List[float]] = []

        def rect(node: Dict[str, object]) -> Optional[List[float]]:
            r = node.get("rect")
            if isinstance(r, list) and len(r) >= 4 and all(isinstance(v, (int, float)) for v in r[:4]):
                return [float(v) for v in r[:4]]
            return None

        def label(node: object) -> Optional[str]:
            if isinstance(node, dict):
                if "pk-label" in str(node.get("class") or "").split() and isinstance(node.get("text"), str):
                    return node["text"]
                for child in node.get("children") or []:
                    found = label(child)
                    if found is not None:
                        return found
            return None

        def walk(node: object) -> None:
            if isinstance(node, dict):
                tokens = str(node.get("class") or "").split()
                if "pk-row" in tokens and "sel" in tokens:
                    rows.append((label(node) or "", rect(node)))
                elif "pk-selbar" in tokens and rect(node):
                    bars.append(rect(node))  # type: ignore[arg-type]
                walk(node.get("children") or [])
            elif isinstance(node, list):
                for child in node:
                    walk(child)

        walk(json.loads(self.ctl("tree")).get("tree"))
        if not bars:
            return [name for name, _ in rows]
        return [name for name, r in rows if r and any(abs(r[0] - b[0]) < 1 and abs(r[1] - b[1]) < 1 and abs(r[3] - b[3]) < 1 for b in bars)]

    def wait_text(self, what: str, needle: str) -> None:
        deadline = time.monotonic() + SMOKE_TIMEOUT
        while not any(needle in t for t in self.texts()):
            if not self.alive() or time.monotonic() > deadline:
                self.fail(what, "a UI text containing %r within %d s" % (needle, SMOKE_TIMEOUT), [t for t in self.texts() if re.search(r"Plotroom|PR |orktree|rror", t)][-10:])
            time.sleep(0.2)

    def start(self) -> None:
        self.label = "tern serve"
        self.logf = open(self.tmp / "serve.log", "wb")
        self.proc = subprocess.Popen(
            [self.tern, "serve", "--control", str(self.sock)] + (["--out", os.environ["PLOTROOM_SMOKE_SHOTS"]] if os.environ.get("PLOTROOM_SMOKE_SHOTS") else []),
            cwd=str(self.cwd), env=self.env, stdin=subprocess.DEVNULL, stdout=self.logf, stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if not self.alive():
                self.fail("server start", "tern serve running", "exited with %s" % (self.proc.returncode if self.proc else None))
            try:
                if run([self.tern, "ctl", "--control", str(self.sock), "state"], env=self.env, timeout=10).returncode == 0:
                    # Wide enough that a split pane keeps the native side preview (it hides below 640 px a pane; the default 1280 splits to 611).
                    self.ctl_ok("resize", "2200", "1000")
                    return
            except subprocess.TimeoutExpired:
                pass
            time.sleep(0.3)
        self.fail("server start", "control socket answering within 60 s", "no answer from %s" % self.sock)

    def selftest(self) -> None:
        self.label = "selftest"
        self.ctl_ok("plugins", "fixtures")
        self.ctl_ok("plugins", "run", "plugin.plotroom.selftest")
        deadline = time.monotonic() + 20
        tree = ""
        while time.monotonic() < deadline:
            if not self.alive():
                self.fail("server", "running", "exited")
            tree = self.ctl("tree")
            if SMOKE_TOAST in tree:
                self.toast = True
                return
            time.sleep(0.2)
        seen = [l.strip() for l in tree.splitlines() if re.search(r"plotroom|plugin|error|fail", l, re.I)]
        self.fail("UI tree text after plugins run plugin.plotroom.selftest", "a text node %r" % SMOKE_TOAST, seen[-10:] or "no Plotroom/plugin text at all")

    def open(self, repo: str, number: int, checkout: Path, pr_dir: Optional[str] = None) -> Dict[str, object]:
        """worktree.open; `pr_dir` is the folder-name format that names the worktree (default: Plotroom's own)."""
        request: Dict[str, object] = {"op": "open", "repo": repo, "number": number, "checkout": str(checkout)}
        if pr_dir is not None:
            request["prDir"] = pr_dir
        return self.run_request(request, "open %s#%d" % (repo, number))

    def open_issue(self, repo: str, key: str, plan: Dict[str, object], checkout: Path) -> Dict[str, object]:
        """worktree.openIssue with `plan` (see issue_plan)."""
        request = {"op": "issue", "repo": repo, "key": key, "plan": plan, "checkout": str(checkout)}
        return self.run_request(request, "open issue %s#%s" % (repo, key))

    def scan(self, root: Path, wants: Dict[str, Dict[str, object]], at: Optional[Path] = None) -> Dict[str, Dict[str, object]]:
        """worktree.scan of the checkout whose main worktree is `root`, asked from `at` (default: `root`), for `wants` (item key -> see `want`): what it
        finds, by item key."""
        data = self.run_request({"op": "scan", "checkout": str(at or root), "wants": wants}, "scan %s for %d item(s)" % (at or root, len(wants)))
        self.eq("ok (problem: %r)" % data.get("problem"), True, data.get("ok"))
        scan = data.get("scan")
        if not isinstance(scan, dict):
            self.fail("scan", "an object with root and found", repr(scan))
        self.same_path("root (the main worktree, whichever folder was asked)", root, scan.get("root"))
        found = scan.get("found")
        if found == []:  # Tern writes a table with nothing in it as a list
            found = {}
        if not isinstance(found, dict):
            self.fail("scan", "found: an object", repr(found))
        return found  # type: ignore[return-value]

    def remote_branches(self, repo: str, checkout: Path) -> List[str]:
        """worktree.remoteBranches: the branches of `repo`'s remote, as Plotroom lists them."""
        request = {"op": "branches", "repo": repo, "checkout": str(checkout)}
        names = self.opened(self.run_request(request, "branches of %s" % repo)).get("branches")
        if not isinstance(names, list):
            self.fail("branches", "a list", repr(names))
        return names  # type: ignore[return-value]

    def run_request(self, request: Dict[str, object], what: str) -> Dict[str, object]:
        result, dup = self.smoke / "result.json", self.smoke / "duplicate.json"
        if result.exists():
            result.unlink()
        (self.smoke / "request.json").write_text(json.dumps(request), encoding="utf-8")
        self.ctl_ok("plugins", "run", "plugin.plotroom.smoke")
        deadline = time.monotonic() + SMOKE_TIMEOUT
        while True:
            if result.exists():
                try:
                    data = json.loads(result.read_text(encoding="utf-8"))
                    break
                except ValueError:
                    pass  # half-written: read again
            if not self.alive():
                self.fail(what, "result.json", "tern serve exited")
            if time.monotonic() > deadline:
                self.fail(what, "result.json within %d s" % SMOKE_TIMEOUT, "none (see the serve log tail below)")
            time.sleep(0.1)
        self.last = data
        if dup.exists():
            self.fail(what, "done runs once (no duplicate.json)", dup.read_text(encoding="utf-8"))
        return data

    def opened(self, data: Dict[str, object]) -> Dict[str, object]:
        """The structured result of an open that must have succeeded."""
        self.eq("ok (problem: %r)" % data.get("problem"), True, data.get("ok"))
        self.eq("hasCx", True, data.get("hasCx"))
        result = data.get("result")
        if not isinstance(result, dict):
            self.fail("result", "an object", repr(result))
        return result  # type: ignore[return-value]

    def refused(self, data: Dict[str, object]) -> str:
        """The problem text of an open that must have failed."""
        self.eq("ok (result: %r)" % data.get("result"), False, data.get("ok"))
        self.eq("hasCx", True, data.get("hasCx"))
        problem = data.get("problem")
        if not isinstance(problem, str):
            self.fail("problem", "a string", repr(problem))
        return problem  # type: ignore[return-value]

    def cd(self, root: Path) -> None:
        """The focused shell reports `root` as its directory (OSC 7), so Plotroom opens in that checkout."""
        self.ctl_ok("run", json.dumps("cd %s && printf '\\033]7;file://localhost%%s\\033\\\\' \"$PWD\"" % root))
        deadline = time.monotonic() + SMOKE_TIMEOUT
        while os.path.realpath(str(self.state()["focused"].get("cwd") or "")) != os.path.realpath(str(root)):  # type: ignore[union-attr]
            if time.monotonic() > deadline:
                self.fail("the shell's directory", str(root), self.state()["focused"])
            time.sleep(0.2)

    def count(self, text: str) -> int:
        """How many nodes of the UI tree are exactly `text` (a badge)."""
        return sum(1 for t in self.texts() if t == text)

    def shot(self, name: str) -> None:
        """A headless render of the session into $PLOTROOM_SMOKE_SHOTS/<name>.png (with its layout JSON) when that is set; nothing otherwise."""
        if os.environ.get("PLOTROOM_SMOKE_SHOTS"):
            self.ctl_ok("shot", name)

    def wait_until(self, what: str, ok: "Callable[[], bool]") -> None:
        deadline = time.monotonic() + SMOKE_TIMEOUT
        while not ok():
            if not self.alive() or time.monotonic() > deadline:
                self.fail(what, "true within %d s" % SMOKE_TIMEOUT, "never (ui texts: %r)" % self.texts()[:40])
            time.sleep(0.2)

    def stop(self) -> None:
        if self.proc is not None and self.proc.poll() is None:
            try:
                run([self.tern, "ctl", "--control", str(self.sock), "quit"], env=self.env, timeout=10)
            except (subprocess.TimeoutExpired, OSError):
                pass
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
                try:
                    self.proc.wait(5)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
                    self.proc.wait()
        if self.logf:
            self.logf.close()

    def log_text(self) -> str:
        parts = []
        for path in sorted((self.tmp / "logs").rglob("*")) + [self.tmp / "serve.log"]:
            if path.is_file():
                parts.append(path.read_text(encoding="utf-8", errors="replace"))
        return "\n".join(parts)

    def dump(self) -> None:
        say("--- tern serve output (tail) ---")
        say(file_tail(self.tmp / "serve.log"))
        for path in sorted((self.tmp / "logs").rglob("*")):
            if path.is_file():
                say("--- %s (tail) ---" % path.name)
                say(file_tail(path))

    def final(self) -> None:
        self.label = "final checks"
        bad = self.smoke / "unexpected.log"
        if bad.exists() and bad.read_text(encoding="utf-8").strip():
            self.fail("fake gh/ssh invocations outside the protocol", "none (no unexpected.log)", bad.read_text(encoding="utf-8").strip())
        if (self.smoke / "duplicate.json").exists():
            self.fail("duplicate.json", "never written", "exists")
        if not any(p.is_file() and p.stat().st_size for p in (self.tmp / "logs").rglob("*")):
            self.fail("isolated log directory %s" % (self.tmp / "logs"), "a non-empty Tern log (else the CSS check is vacuous)", "empty")
        css = [l for l in self.log_text().splitlines() if "plugin style sheet has errors" in l]
        if css:
            self.fail("plugin/plotroom.css in the Tern log", "no 'plugin style sheet has errors' line", css[:5])
        if not self.toast:
            self.fail("selftest toast", SMOKE_TOAST, "never seen")


# ----- scenarios: each takes the Smoke and raises GateError through its assertions


def sc_create(s: Smoke) -> None:
    root, wt, sha = s.checkout("r"), s.wt("o/r", 1), s.shas[("o/r", 1)]
    ref = "refs/plotroom-pr/o/r/pr-1"
    s.eq("refs/remotes/origin/feature-1 before (the checkout predates the branch)", None, s.ref(root, "refs/remotes/origin/feature-1"))
    r = s.opened(s.open("o/r", 1, root))
    s.eq("created", True, r.get("created"))
    s.eq("head", sha, r.get("head"))
    s.eq("prHead", sha, r.get("prHead"))
    s.eq("dirty", False, r.get("dirty"))
    s.eq("branch (the PR's own head branch)", "feature-1", r.get("branch"))
    s.eq("ref", ref, r.get("ref"))
    s.eq("prRef", "feature-1", r.get("prRef"))
    s.eq("prBase", "main", r.get("prBase"))
    s.eq("number", 1, r.get("number"))
    s.eq("title", "Smoke PR 1", r.get("title"))
    s.eq("author", "octo", r.get("author"))
    s.same_path("path", wt, r.get("path"))
    s.same_path("root", root, r.get("root"))
    s.eq("worktree directory exists", True, wt.is_dir())
    s.eq("git rev-parse --show-toplevel in the worktree", os.path.realpath(str(wt)), os.path.realpath(s.out(wt, "rev-parse", "--show-toplevel")))
    s.eq("git branch --show-current in the worktree", "feature-1", s.out(wt, "branch", "--show-current"))
    s.eq(ref, sha, s.ref(root, ref))
    s.eq("refs/heads/feature-1", sha, s.ref(root, "refs/heads/feature-1"))
    s.eq("refs/remotes/origin/feature-1 (fetched for the upstream)", sha, s.ref(root, "refs/remotes/origin/feature-1"))
    s.eq("branch.feature-1.remote", "origin", s.config(root, "branch.feature-1.remote"))
    s.eq("branch.feature-1.merge", "refs/heads/feature-1", s.config(root, "branch.feature-1.merge"))
    s.eq("the worktree's upstream", "origin/feature-1", s.out(wt, "rev-parse", "--abbrev-ref", "@{upstream}"))
    short = s.git(root, "rev-parse", "feature-1")
    s.eq("rev-parse feature-1 exit status", 0, short.returncode)
    s.eq("rev-parse feature-1 stderr has no 'ambiguous'", False, "ambiguous" in short.stderr.lower())
    s.eq("rev-parse feature-1 stdout", sha, short.stdout.strip())
    s.eq("branches in the old plotroom/ namespace", "", s.out(root, "for-each-ref", "refs/heads/plotroom"))
    s.eq("update", [], s.last.get("update"))  # type: ignore[union-attr]


def sc_reuse(s: Smoke) -> None:
    root, wt, sha = s.checkout("r"), s.wt("o/r", 1), s.shas[("o/r", 1)]
    r = s.opened(s.open("o/r", 1, root))
    s.eq("created", False, r.get("created"))
    s.eq("head", sha, r.get("head"))
    s.eq("dirty", False, r.get("dirty"))
    s.eq("branch", "feature-1", r.get("branch"))
    s.same_path("path", wt, r.get("path"))
    s.eq("refs/plotroom-pr/o/r/pr-1 untouched", sha, s.ref(root, "refs/plotroom-pr/o/r/pr-1"))
    s.eq("worktree HEAD untouched", sha, s.out(wt, "rev-parse", "HEAD"))


def local_changes(s: Smoke, wt: Path) -> Tuple[bytes, bytes, str]:
    return (wt / "untracked-note.txt").read_bytes(), (wt / "README.md").read_bytes(), s.out(wt, "status", "--porcelain", "--untracked-files=normal")


def sc_dirty_reuse(s: Smoke) -> None:
    root, wt = s.checkout("r"), s.wt("o/r", 1)
    (wt / "untracked-note.txt").write_bytes(b"untracked\x00 bytes\n")
    with open(str(wt / "README.md"), "ab") as handle:
        handle.write(b"local edit\n")
    before = local_changes(s, wt)
    s.contains("status before", "untracked-note.txt", before[2])
    s.contains("status before", "README.md", before[2])
    r = s.opened(s.open("o/r", 1, root))
    s.eq("created", False, r.get("created"))
    s.eq("dirty", True, r.get("dirty"))
    s.eq("untracked bytes, tracked bytes and status after", before, local_changes(s, wt))


def sc_advanced(s: Smoke) -> None:
    root, wt, old = s.checkout("r"), s.wt("o/r", 1), s.shas[("o/r", 1)]
    before = local_changes(s, wt)
    new = s.push_pr("o/r", 1, "pr-1")
    s.canned("o/r", 1, new)
    r = s.opened(s.open("o/r", 1, root))
    s.eq("created", False, r.get("created"))
    s.eq("head", old, r.get("head"))
    s.eq("prHead", new, r.get("prHead"))
    s.eq("dirty", True, r.get("dirty"))
    s.eq("update (one pull: the branch tracks the PR's head branch)", ["git -C %s pull --ff-only" % wt], s.last.get("update"))  # type: ignore[union-attr]
    s.eq("worktree HEAD still old", old, s.out(wt, "rev-parse", "HEAD"))
    s.eq("refs/plotroom-pr/o/r/pr-1 still old (no fetch on reuse)", old, s.out(root, "rev-parse", "refs/plotroom-pr/o/r/pr-1"))
    s.eq("refs/heads/feature-1 still old (never moved)", old, s.ref(root, "refs/heads/feature-1"))
    s.eq("refs/remotes/origin/feature-1 still old (no fetch on reuse)", old, s.ref(root, "refs/remotes/origin/feature-1"))
    s.eq("untracked bytes, tracked bytes and status after", before, local_changes(s, wt))


def sc_hook(s: Smoke) -> None:
    root, wt, sha = s.checkout("r"), s.wt("o/r", 2), s.shas[("o/r", 2)]
    hook = root / ".git" / "hooks" / "post-checkout"
    hook.write_text("#!/bin/sh\necho made-by-hook > hook-made.txt\n", encoding="utf-8")
    hook.chmod(0o755)
    try:
        r = s.opened(s.open("o/r", 2, root))
    finally:
        hook.unlink()
    s.eq("created", True, r.get("created"))
    s.eq("head", sha, r.get("head"))
    s.eq("hook ran in the new worktree (hook-made.txt)", True, (wt / "hook-made.txt").is_file())
    s.contains("git status after the hook", "hook-made.txt", s.out(wt, "status", "--porcelain"))
    s.eq("dirty reflects the post-hook state", True, r.get("dirty"))


def sc_existing_branch(s: Smoke) -> None:
    """The PR's head branch exists already, at another commit: the worktree attaches to it at ITS commit; the branch is never moved and gets no upstream."""
    root, wt, sha = s.checkout("r"), s.wt("o/r", 3), s.shas[("o/r", 3)]
    main = s.out(root, "rev-parse", "main")
    s.out(root, "branch", "feature-3", main)
    r = s.opened(s.open("o/r", 3, root))
    s.eq("created", True, r.get("created"))
    s.eq("branch", "feature-3", r.get("branch"))
    s.eq("head (the branch's own commit)", main, r.get("head"))
    s.eq("prHead", sha, r.get("prHead"))
    s.eq("head is not the PR's head", True, r.get("head") != r.get("prHead"))
    s.same_path("path", wt, r.get("path"))
    s.eq("worktree directory exists", True, wt.is_dir())
    s.eq("worktree HEAD", main, s.out(wt, "rev-parse", "HEAD"))
    s.eq("git branch --show-current in the worktree", "feature-3", s.out(wt, "branch", "--show-current"))
    s.eq("refs/heads/feature-3 untouched", main, s.ref(root, "refs/heads/feature-3"))
    s.eq("refs/plotroom-pr/o/r/pr-3 (the PR's head, fetched all the same)", sha, s.ref(root, "refs/plotroom-pr/o/r/pr-3"))
    s.eq("branch.feature-3.remote (the user's branch gets no upstream)", None, s.config(root, "branch.feature-3.remote"))
    s.eq("branch.feature-3.merge", None, s.config(root, "branch.feature-3.merge"))
    s.contains("describe", "Different", s.last.get("describe"))  # type: ignore[union-attr]
    s.eq("update (catching up is the user's)", ["git -C %s pull --ff-only" % wt], s.last.get("update"))  # type: ignore[union-attr]


def sc_deleted_branch(s: Smoke) -> None:
    """A PR whose head branch is gone from the remote (merged, then deleted) still opens, from its refs/pull/N/head: the fetch of the branch fails quietly and
    the new branch records its upstream all the same."""
    root, wt, sha = s.checkout("r"), s.wt("o/r", 10), s.shas[("o/r", 10)]
    s.eq("refs/heads/feature-10 of the remote", None, s.ref(s.bare("o/r"), "refs/heads/feature-10"))
    r = s.opened(s.open("o/r", 10, root))
    s.eq("created", True, r.get("created"))
    s.eq("branch", "feature-10", r.get("branch"))
    s.eq("head", sha, r.get("head"))
    s.same_path("path", wt, r.get("path"))
    s.eq("worktree directory exists", True, wt.is_dir())
    s.eq("refs/heads/feature-10", sha, s.ref(root, "refs/heads/feature-10"))
    s.eq("refs/remotes/origin/feature-10 (nothing to fetch)", None, s.ref(root, "refs/remotes/origin/feature-10"))
    s.eq("branch.feature-10.remote", "origin", s.config(root, "branch.feature-10.remote"))
    s.eq("branch.feature-10.merge", "refs/heads/feature-10", s.config(root, "branch.feature-10.merge"))


def sc_dot_github(s: Smoke) -> None:
    root, wt, sha = s.checkout("dotgithub"), s.wt("github/.github", 1), s.shas[("github/.github", 1)]
    ref = "refs/plotroom-pr/github/%2Egithub/pr-1"
    r = s.opened(s.open("github/.github", 1, root))
    s.eq("created", True, r.get("created"))
    s.eq("branch", "feature-1", r.get("branch"))
    s.eq("ref", ref, r.get("ref"))
    s.eq("head", sha, r.get("head"))
    s.same_path("path", wt, r.get("path"))
    s.eq("worktree directory exists", True, wt.is_dir())
    s.eq("the worktrees folder holds the folder with the repository's leading dot", True, "plotroom-github_.github-pr-1" in s.folders())
    s.eq("git check-ref-format (ref)", 0, s.git(root, "check-ref-format", ref).returncode)
    s.eq(ref, sha, s.ref(root, ref))
    s.eq("refs/heads/feature-1", sha, s.ref(root, "refs/heads/feature-1"))
    s.eq("branch.feature-1.remote", "origin", s.config(root, "branch.feature-1.remote"))


def sc_recovery(s: Smoke) -> None:
    root, wt = s.checkout("r"), s.wt("o/r", 9)
    listed = s.out(root, "worktree", "list", "--porcelain")
    s.refused(s.open("o/r", 9, root))
    s.eq("(a) worktree directory for pr-9 exists", False, wt.exists())
    s.eq("(a) refs/plotroom-pr/o/r/pr-9", None, s.ref(root, "refs/plotroom-pr/o/r/pr-9"))
    s.eq("(a) refs/heads/feature-9", None, s.ref(root, "refs/heads/feature-9"))
    s.eq("(a) git worktree list", listed, s.out(root, "worktree", "list", "--porcelain"))
    sha = s.push_pr("o/r", 9, "main")
    s.canned("o/r", 9, sha)
    r = s.opened(s.open("o/r", 9, root))
    s.eq("(a, retry) created", True, r.get("created"))
    s.eq("(a, retry) head", sha, r.get("head"))
    s.eq("(a, retry) worktree directory exists", True, wt.is_dir())

    q, qwt = s.checkout("q"), s.wt("p/q", 1)
    blocker = qwt
    blocker.write_text("in the way\n", encoding="utf-8")
    listed = s.out(q, "worktree", "list", "--porcelain")
    problem = s.refused(s.open("p/q", 1, q))
    s.contains("(b) problem names the blocking path", str(blocker), problem)
    s.eq("(b) git worktree list", listed, s.out(q, "worktree", "list", "--porcelain"))
    s.eq("(b) blocker still a regular file", True, blocker.is_file())
    s.eq("(b) refs/heads/feature-1", None, s.ref(q, "refs/heads/feature-1"))
    blocker.unlink()
    r = s.opened(s.open("p/q", 1, q))
    s.eq("(b, retry) created", True, r.get("created"))
    s.eq("(b, retry) worktree directory exists", True, qwt.is_dir())


def sc_fork(s: Smoke) -> None:
    """A fork's PR is checked out on `<fork owner>/<head branch>`, made from the commit the repository's own refs/pull/N/head holds. The branch tracks the
    fork's branch by URL, or, when the fork was deleted, the PR's own ref; the repository's own branch of the same name is neither used nor fetched."""
    root = s.checkout("r")
    for n, remote, merge in (
        (4, "https://github.com/forkowner/r.git", "refs/heads/feature-4"),
        (5, "origin", "refs/pull/5/head"),
    ):
        sha, wt, branch, ref = s.shas[("o/r", n)], s.wt("o/r", n), "forkowner/feature-%d" % n, "refs/plotroom-pr/o/r/pr-%d" % n
        r = s.opened(s.open("o/r", n, root))
        s.eq("#%d created" % n, True, r.get("created"))
        s.eq("#%d branch" % n, branch, r.get("branch"))
        s.eq("#%d ref" % n, ref, r.get("ref"))
        s.eq("#%d prRef (the head branch on GitHub)" % n, "feature-%d" % n, r.get("prRef"))
        s.eq("#%d head" % n, sha, r.get("head"))
        s.same_path("#%d path" % n, wt, r.get("path"))
        s.eq("#%d worktree directory exists" % n, True, wt.is_dir())
        s.eq("#%d git branch --show-current in the worktree" % n, branch, s.out(wt, "branch", "--show-current"))
        s.eq("#%d %s" % (n, ref), sha, s.ref(root, ref))
        s.eq("#%d refs/heads/%s" % (n, branch), sha, s.ref(root, "refs/heads/" + branch))
        s.eq("#%d branch.%s.remote" % (n, branch), remote, s.config(root, "branch.%s.remote" % branch))
        s.eq("#%d branch.%s.merge" % (n, branch), merge, s.config(root, "branch.%s.merge" % branch))
        s.eq("#%d refs/heads/feature-%d (the fork's branch name is not made here)" % (n, n), None, s.ref(root, "refs/heads/feature-%d" % n))
        s.eq("#%d refs/remotes/origin/feature-%d (the repository's own branch of that name is not fetched)" % (n, n), None, s.ref(root, "refs/remotes/origin/feature-%d" % n))


def sc_pr_dir(s: Smoke) -> None:
    """The worktree's folder is what `naming` makes of the PR (or what an issue's plan names), a direct child of omp's worktrees folder: a format that
    cannot name one stops the open before anything is made, and so does a name that is not one path segment; once another name was used the default one
    is never made, and the next open, whatever the format, finds the worktree where it is."""
    root, sha, leaf = s.checkout("r"), s.shas[("o/r", 7)], "smoke-o_r-7-smoke-pr-7"  # {slug} of the title "Smoke PR 7"
    wt, plain = s.tmp / "omp-wt" / leaf, s.wt("o/r", 7)
    before, listed = s.folders(), s.out(root, "worktree", "list", "--porcelain")
    problem = s.refused(s.open("o/r", 7, root, pr_dir="smoke-{slug}"))
    s.contains("(no {key}) problem", "{key}", problem)
    s.eq("(no {key}) worktrees folder", before, s.folders())
    s.eq("(no {key}) git worktree list", listed, s.out(root, "worktree", "list", "--porcelain"))
    s.eq("(no {key}) refs/heads/feature-7", None, s.ref(root, "refs/heads/feature-7"))
    s.eq("(no {key}) refs/plotroom-pr/o/r/pr-7", None, s.ref(root, "refs/plotroom-pr/o/r/pr-7"))
    problem = s.refused(s.open_issue("o/r", "9", issue_plan("../escape-9", "smoke/9", fresh=True, base="main"), root))
    s.contains("(not one path segment) problem", "not usable", problem)
    s.eq("(not one path segment) worktrees folder", before, s.folders())
    s.eq("(not one path segment) next to the worktrees folder", False, (s.tmp / "escape-9").exists())
    s.eq("(not one path segment) refs/heads/smoke/9", None, s.ref(root, "refs/heads/smoke/9"))
    r = s.opened(s.open("o/r", 7, root, pr_dir="smoke-{owner}_{repo}-{key}-{slug}"))
    s.eq("created", True, r.get("created"))
    s.eq("branch", "feature-7", r.get("branch"))
    s.eq("head", sha, r.get("head"))
    s.same_path("path", wt, r.get("path"))
    s.eq("worktrees folder (the new one is a direct child)", sorted(before + [leaf]), s.folders())
    s.eq("the default folder is not made", False, plain.exists())
    again = s.opened(s.open("o/r", 7, root))
    s.eq("created (reopened under the default format)", False, again.get("created"))
    s.same_path("path (reopened under the default format)", wt, again.get("path"))
    s.eq("worktrees folder (reopened)", sorted(before + [leaf]), s.folders())


def issue_plan(dirname: str, branch: str, fresh: bool = False, pr: Optional[int] = None, base: Optional[str] = None) -> Dict[str, object]:
    """A worktree.IssuePlan as the request spells it: the worktree's folder name, the issue's own branch, whether that is made new (`fresh`) or a linked
    PR's branch (`pr`) is used instead, and the remote branch a new one starts from (`base`)."""
    plan: Dict[str, object] = {"dir": dirname, "branch": branch, "fresh": fresh}
    if pr is not None:
        plan["pr"] = pr
    if base is not None:
        plan["base"] = base
    return plan


def issue_flow(s: Smoke, ref: str, branch: str) -> Path:
    """An issue's new-branch worktree, as its caller walks it: with no worktree and nothing decided the answer is "undecided", with a new branch and no base
    "need-base", and neither makes anything (nor fetches); with a base the branch starts at the remote's freshly fetched branch, no upstream configured;
    opened again, even by a plan that decides nothing and names another branch, the worktree is reused as it is. Returns the worktree."""
    root, wt, dirname = s.checkout("r"), s.issue_wt("o/r", ref), s.issue_dir("o/r", ref)
    listed = s.out(root, "worktree", "list", "--porcelain")
    base = s.advance("o/r")  # the checkout's refs/remotes/origin/main is behind the remote's main until something fetches it
    stale = s.ref(root, "refs/remotes/origin/main")
    s.eq("refs/remotes/origin/main is behind the remote's main", True, stale != base)

    def nothing_made(step: str) -> None:
        s.eq("(%s) worktree directory exists" % step, False, wt.exists())
        s.eq("(%s) refs/heads/%s" % (step, branch), None, s.ref(root, "refs/heads/" + branch))
        s.eq("(%s) git worktree list" % step, listed, s.out(root, "worktree", "list", "--porcelain"))
        s.eq("(%s) refs/remotes/origin/main (nothing fetched)" % step, stale, s.ref(root, "refs/remotes/origin/main"))

    s.eq("(undecided) problem", "undecided", s.refused(s.open_issue("o/r", ref, issue_plan(dirname, branch), root)))
    nothing_made("undecided")
    s.eq("(need-base) problem", "need-base", s.refused(s.open_issue("o/r", ref, issue_plan(dirname, branch, fresh=True), root)))
    nothing_made("need-base")
    problem = s.refused(s.open_issue("o/r", ref, issue_plan(dirname, branch, fresh=True, base="no-such-branch"), root))
    s.contains("(missing base) problem", "no-such-branch", problem)
    nothing_made("missing base")
    r = s.opened(s.open_issue("o/r", ref, issue_plan(dirname, branch, fresh=True, base="main"), root))
    s.eq("created", True, r.get("created"))
    s.eq("head (the remote's main, fetched)", base, r.get("head"))
    s.eq("branch", branch, r.get("branch"))
    s.eq("key", ref, r.get("key"))
    s.eq("dirty", False, r.get("dirty"))
    s.eq("ref (only a linked PR's worktree has one)", None, r.get("ref"))
    s.eq("number (likewise)", None, r.get("number"))
    s.same_path("path", wt, r.get("path"))
    s.same_path("root", root, r.get("root"))
    s.eq("worktree directory exists", True, wt.is_dir())
    s.eq("git rev-parse --show-toplevel in the worktree", os.path.realpath(str(wt)), os.path.realpath(s.out(wt, "rev-parse", "--show-toplevel")))
    s.eq("git branch --show-current in the worktree", branch, s.out(wt, "branch", "--show-current"))
    s.eq("refs/heads/" + branch, base, s.ref(root, "refs/heads/" + branch))
    s.eq("refs/remotes/origin/main (fetched)", base, s.ref(root, "refs/remotes/origin/main"))
    s.eq("refs/plotroom-base (gone)", "", s.out(root, "for-each-ref", "refs/plotroom-base"))
    s.eq("branch.%s.remote (no upstream)" % branch, None, s.config(root, "branch.%s.remote" % branch))
    s.eq("branch.%s.merge (no upstream)" % branch, None, s.config(root, "branch.%s.merge" % branch))
    s.contains("describe", branch, s.last.get("describe"))  # type: ignore[union-attr]
    other = branch + "-renamed"
    again = s.opened(s.open_issue("o/r", ref, issue_plan(dirname, other), root))
    s.eq("created (second open)", False, again.get("created"))
    s.eq("branch (second open: the worktree's own, not the plan's)", branch, again.get("branch"))
    s.eq("head (second open)", base, again.get("head"))
    s.eq("worktree HEAD untouched", base, s.out(wt, "rev-parse", "HEAD"))
    s.eq("refs/heads/" + other, None, s.ref(root, "refs/heads/" + other))
    return wt


def sc_issue(s: Smoke) -> None:
    """A GitHub issue's worktree: a new branch from a remote branch the caller picks, in the folder the plan names. The branch outlives the worktree: with
    it removed, a new-branch plan with no base attaches the branch at its own commit."""
    root, branch = s.checkout("r"), "smoke/7-smoke-issue"
    wt = issue_flow(s, "7", branch)
    own = s.ref(root, "refs/heads/" + branch)
    s.out(root, "worktree", "remove", str(wt))
    s.advance("o/r")  # a base fetched now would be a newer commit than the branch's
    r = s.opened(s.open_issue("o/r", "7", issue_plan(s.issue_dir("o/r", "7"), branch, fresh=True), root))
    s.eq("(branch kept) created", True, r.get("created"))
    s.eq("(branch kept) head (the branch's own commit)", own, r.get("head"))
    s.eq("(branch kept) refs/heads/%s untouched" % branch, own, s.ref(root, "refs/heads/" + branch))
    s.eq("(branch kept) worktree directory exists", True, wt.is_dir())


def sc_jira_issue(s: Smoke) -> None:
    """A Jira issue's worktree in a GitHub repository goes the same way; its folder keeps the key's case."""
    issue_flow(s, "ABC-7", "ABC-7-smoke")
    s.eq("the worktrees folder holds the key's own case", True, "plotroom-o_r-issue-ABC-7" in s.folders())


def sc_issue_pr(s: Smoke) -> None:
    """An issue's worktree on a linked PR: the folder is the issue's, the branch the PR's own (tracking it, as a PR's worktree does); the branch the plan
    names is never made. Opened again, it is reused."""
    root, sha, wt, mine = s.checkout("r"), s.shas[("o/r", 6)], s.issue_wt("o/r", "8"), "smoke/8-own-branch"
    dirname = s.issue_dir("o/r", "8")
    r = s.opened(s.open_issue("o/r", "8", issue_plan(dirname, mine, pr=6), root))
    s.eq("created", True, r.get("created"))
    s.eq("branch (the PR's)", "feature-6", r.get("branch"))
    s.eq("number", 6, r.get("number"))
    s.eq("ref", "refs/plotroom-pr/o/r/pr-6", r.get("ref"))
    s.eq("key", "8", r.get("key"))
    s.eq("head", sha, r.get("head"))
    s.same_path("path", wt, r.get("path"))
    s.same_path("root", root, r.get("root"))
    s.eq("worktree directory exists", True, wt.is_dir())
    s.eq("git branch --show-current in the worktree", "feature-6", s.out(wt, "branch", "--show-current"))
    s.eq("refs/plotroom-pr/o/r/pr-6", sha, s.ref(root, "refs/plotroom-pr/o/r/pr-6"))
    s.eq("refs/heads/feature-6", sha, s.ref(root, "refs/heads/feature-6"))
    s.eq("refs/remotes/origin/feature-6 (fetched for the upstream)", sha, s.ref(root, "refs/remotes/origin/feature-6"))
    s.eq("branch.feature-6.remote", "origin", s.config(root, "branch.feature-6.remote"))
    s.eq("branch.feature-6.merge", "refs/heads/feature-6", s.config(root, "branch.feature-6.merge"))
    s.eq("refs/heads/" + mine + " (the plan's branch is not made)", None, s.ref(root, "refs/heads/" + mine))
    s.contains("describe", "feature-6", s.last.get("describe"))  # type: ignore[union-attr]
    again = s.opened(s.open_issue("o/r", "8", issue_plan(dirname, mine), root))
    s.eq("created (second open)", False, again.get("created"))
    s.eq("branch (second open)", "feature-6", again.get("branch"))
    s.eq("head (second open)", sha, again.get("head"))


def sc_remote_branches(s: Smoke) -> None:
    """worktree.remoteBranches lists the remote's branches with `git ls-remote --symref`: its default branch first, then the rest sorted."""
    bare = s.bare("o/r")
    default = s.out(bare, "symbolic-ref", "--short", "HEAD")
    rest = sorted(b for b in s.out(bare, "for-each-ref", "--format=%(refname:lstrip=2)", "refs/heads").split("\n") if b != default)
    s.eq("a branch sorts before the default one (else its being first proves nothing)", True, bool(rest) and rest[0] < default)
    s.eq("branches of o/r", [default] + rest, s.remote_branches("o/r", s.checkout("r")))


def want(branch: str, dirname: str, ref: Optional[str] = None) -> Dict[str, object]:
    """A worktree.Want as the scan request spells it: an item's worktree is the one on `branch` (matched first) or in the folder `dirname`; `ref` is the ref
    a PR's head was fetched into."""
    out: Dict[str, object] = {"branches": [branch], "dirs": [dirname]}
    if ref is not None:
        out["ref"] = ref
    return out


def sc_scan(s: Smoke) -> None:
    """What the worktree card reads from git: each item's worktree among the ones the scenarios before made, found by the branch or the folder name the item
    wants (a branch first), with the branch it is on, its head and a PR's fetched ref; the main checkout, a detached or locked worktree and one no item wants
    are left out."""
    root, omp = s.checkout("r"), s.tmp / "omp-wt"
    # Where each PR's worktree is and the branch it is on: PR 7's folder was named by another format, the forks' branches are their owner's.
    places = {n: s.wt("o/r", n) for n in (1, 2, 3, 4, 5, 9, 10)}
    places[7] = omp / "smoke-o_r-7-smoke-pr-7"
    branches = {n: "feature-%d" % n for n in (1, 2, 3, 7, 9, 10)}
    branches.update({4: "forkowner/feature-4", 5: "forkowner/feature-5"})

    def pr(n: int, branch: str) -> Dict[str, object]:
        return want(branch, s.pr_dir("o/r", n), "refs/plotroom-pr/o/r/pr-%d" % n)

    wants = {"o/r#%d" % n: pr(n, branches.get(n, "feature-%d" % n)) for n in (1, 2, 3, 4, 5, 6, 7, 9, 10)}
    found = s.scan(root, wants)
    s.eq("pull requests found (6 has no worktree yet)", sorted("o/r#%d" % n for n in places), sorted(found))
    for n, path in places.items():
        one = found["o/r#%d" % n]
        s.same_path("#%d path" % n, path, one.get("path"))
        s.same_path("#%d root" % n, root, one.get("root"))
        s.eq("#%d branch" % n, branches[n], one.get("branch"))
        s.eq("#%d head (the worktree's, not the PR's)" % n, s.out(path, "rev-parse", "HEAD"), one.get("head"))
        s.eq("#%d ref" % n, "refs/plotroom-pr/o/r/pr-%d" % n, one.get("ref"))
    s.eq("#3 is on a commit of its own", True, found["o/r#3"].get("head") != s.shas[("o/r", 3)])
    s.eq("asked from a linked worktree, the same are found", sorted(found), sorted(s.scan(root, wants, at=places[1])))
    # The folder of a PR is its own whatever branch it is on; a detached or locked worktree, a branch no item wants and the main checkout itself are no item's.
    own, detached, locked, elsewhere = (omp / s.pr_dir("o/r", 8), omp / s.pr_dir("o/r", 11), omp / s.pr_dir("o/r", 12), omp / "elsewhere")
    s.out(root, "worktree", "add", "-q", "-b", "my-own-work", str(own))
    s.out(root, "worktree", "add", "-q", "--detach", str(detached))
    s.out(root, "worktree", "add", "-q", "-b", "feature-12", str(locked))
    s.out(root, "worktree", "lock", str(locked))
    s.out(root, "worktree", "add", "-q", "-b", "unrelated-work", str(elsewhere))
    wants.update({"o/r#%d" % n: pr(n, "feature-%d" % n) for n in (8, 11, 12)})
    wants["o/r#99"] = want("main", root.name)
    more = s.scan(root, wants)
    s.eq("found: PR 8's folder holds a worktree on the user's own branch; 11 is detached, 12 locked, 99 is the main checkout", sorted(list(found) + ["o/r#8"]), sorted(more))
    s.same_path("#8 path", own, more["o/r#8"].get("path"))
    s.eq("#8 branch (the user's own)", "my-own-work", more["o/r#8"].get("branch"))
    s.out(root, "worktree", "unlock", str(locked))
    for path in (own, detached, locked, elsewhere):
        s.out(root, "worktree", "remove", str(path))
    s.out(root, "branch", "-D", "my-own-work", "feature-12", "unrelated-work")
    issues = s.scan(root, {
        "o/r#7": want("smoke/7-smoke-issue", s.issue_dir("o/r", "7")),
        "abc#ABC-7": want("ABC-7-smoke", s.issue_dir("o/r", "ABC-7")),
        "o/r#8": want("smoke/8-own-branch", s.issue_dir("o/r", "8")),
    })
    s.eq("issues found (8 has no worktree yet)", ["abc#ABC-7", "o/r#7"], sorted(issues))
    seven = issues["o/r#7"]
    s.same_path("#7 path", s.issue_wt("o/r", "7"), seven.get("path"))
    s.eq("#7 branch", "smoke/7-smoke-issue", seven.get("branch"))
    s.eq("#7 head", s.out(s.issue_wt("o/r", "7"), "rev-parse", "HEAD"), seven.get("head"))
    s.eq("an issue has no fetched ref", None, seven.get("ref"))
    s.same_path("a Jira issue's path (the key keeps its case)", s.issue_wt("o/r", "ABC-7"), issues["abc#ABC-7"].get("path"))
    # A format changed since the worktrees were made: the branch alone, or the folder alone, still finds one.
    moved = s.scan(root, {"o/r#7": want("renamed-by-a-format", s.issue_dir("o/r", "7")), "abc#ABC-7": want("ABC-7-smoke", "named-by-another-format")})
    s.eq("found by the folder alone, or by the branch alone", ["abc#ABC-7", "o/r#7"], sorted(moved))
    s.eq("#7 says the branch it is on, not the one wanted", "smoke/7-smoke-issue", moved["o/r#7"].get("branch"))
    s.eq("no item wanted, none found", {}, s.scan(root, {}))
    dot = s.scan(s.checkout("dotgithub"), {"github/.github#1": want("feature-1", s.pr_dir("github/.github", 1), "refs/plotroom-pr/github/%2Egithub/pr-1")})
    s.eq(".github found", ["github/.github#1"], sorted(dot))
    s.eq(".github branch", "feature-1", dot["github/.github#1"].get("branch"))
    s.eq(".github ref", "refs/plotroom-pr/github/%2Egithub/pr-1", dot["github/.github#1"].get("ref"))


def sc_remote_host(s: Smoke) -> None:
    """A Plotroom block on another host (an attached loopback daemon) shows a worktree that was made before it existed
    on its card from git alone, then gets its worktree from its own host half, run where the block runs: the window half
    only asks, then opens the PR's tab on that host."""
    root, wt, sha = s.checkout("remote"), s.wt("o/remote", 1), s.shas[("o/remote", 1)]
    stamp = "2026-01-01T00:00:00Z"
    pr = {"number": 1, "title": "Remote PR 1", "url": "https://github.com/o/remote/pull/1", "author": "octo", "state": "OPEN",
          "isDraft": False, "updatedAt": stamp, "createdAt": stamp, "head": "feature-1", "base": "main", "additions": 1,
          "deletions": 0, "changedFiles": 1, "comments": 0, "labels": [], "runs": [], "runTotal": 0}
    (s.smoke / "search.json").write_text(json.dumps([pr]), encoding="utf-8")
    # What an earlier session (or omp itself) left: the host half lists the checkout from its own view, so the card needs no press.
    branch, ref = "plotroom/o/remote/pr-1", "refs/plotroom-pr/o/remote/pr-1"
    s.out(root, "fetch", "-q", "origin", "+refs/pull/1/head:" + ref)
    s.out(root, "worktree", "add", "-q", "-b", branch, str(wt), ref)
    s.out(root, "config", "branch.%s.remote" % branch, "origin")
    s.ctl_ok("remote", "loopback", "u@devbox")
    # The shell reports its directory (OSC 7), so Plotroom opens in the checkout.
    s.ctl_ok("run", json.dumps("cd %s && printf '\\033]7;file://localhost%%s\\033\\\\' \"$PWD\"" % root))
    deadline = time.monotonic() + SMOKE_TIMEOUT
    while os.path.realpath(str(s.state()["focused"].get("cwd") or "")) != os.path.realpath(str(root)):  # type: ignore[union-attr]
        if time.monotonic() > deadline:
            s.fail("the shell's directory", str(root), s.state()["focused"])
        time.sleep(0.2)
    s.ctl_ok("plugins", "run", "plugin.plotroom.open")
    s.wait_text("the remote block lists the PR", "Remote PR 1")
    s.wait_text("the row of the worktree made before the block, with its place read from git", str(wt))
    s.select_row()
    s.out(root, "worktree", "remove", str(wt))
    s.out(root, "branch", "-D", branch)
    s.out(root, "update-ref", "-d", ref)
    s.ctl_ok("plugins", "run", "plugin.plotroom.worktree-selected")
    s.wait_text("the worktree toast", "Worktree ready for o/remote#1")
    st = s.state()
    s.eq("current host", "devbox", st["hosts"]["current"])  # type: ignore[index]
    s.eq("worktree HEAD", sha, s.out(wt, "rev-parse", "HEAD"))
    s.eq("worktree branch (the PR's own)", "feature-1", s.out(wt, "branch", "--show-current"))
    s.eq("worktree upstream", "origin/feature-1", s.out(wt, "rev-parse", "--abbrev-ref", "@{upstream}"))
    s.eq("the PR's tab", True, any(t.get("title") == "PR #1 · remote" for t in st["tabs"]))  # type: ignore[union-attr,attr-defined]
    s.eq("its pane is in the worktree", os.path.realpath(str(wt)), os.path.realpath(str(st["focused"].get("cwd") or "")))  # type: ignore[union-attr]


def sc_inventory(s: Smoke) -> None:
    """worktree.inventory lists the checkout's worktrees as git does (the main one first, never removable), with the pull request Plotroom noted for a
    branch; inventoryDirty and removeEntry act only on the worktree git still lists at that path and branch: never the main checkout, a locked, prunable
    or changed one, never one with uncommitted changes (nothing is forced). A clean one goes, its branch with it, and a detached one has none to drop."""
    root, key = s.checkout("inv"), "i/nv"
    base = s.tmp / "wts"
    base.mkdir(exist_ok=True)
    a, b, c, d = (base / n for n in ("a", "b", "c", "d"))
    s.out(root, "worktree", "add", "-q", "-b", "plotroom-a", str(a))
    s.out(root, "config", "branch.plotroom-a.plotroompr", "7")
    s.out(root, "config", "branch.plotroom-a.plotroomrepo", key)
    s.out(root, "worktree", "add", "-q", "--detach", str(b))
    s.out(root, "worktree", "add", "-q", "-b", "locked-c", str(c))
    s.out(root, "worktree", "lock", str(c))
    s.out(root, "worktree", "add", "-q", "-b", "gone-d", str(d))
    shutil.rmtree(str(d))

    def call(op: str, **rest: object) -> Dict[str, object]:
        return s.run_request(dict(rest, op=op, repo=key, checkout=str(root)), "%s %s" % (op, key))

    def refused(what: str, needle: str, **rest: object) -> None:
        data = call(**dict(rest, op="removeEntry"))
        s.eq("%s: ok (data: %r)" % (what, data.get("data")), False, data.get("ok"))
        s.contains(what, needle, data.get("problem"))

    data = call("inventory")
    s.eq("inventory ok (problem: %r)" % data.get("problem"), True, data.get("ok"))
    entries = data.get("data")
    if not isinstance(entries, list) or not entries:
        s.fail("inventory", "a list of worktrees", repr(entries))
    s.same_path("the first entry is the main worktree", root, entries[0].get("path"))
    s.eq("main flag", True, entries[0].get("main"))
    by = {os.path.realpath(e["path"]): e for e in entries}

    def at(p: Path) -> Dict[str, object]:
        e = by.get(os.path.realpath(str(p)))
        if e is None:
            s.fail("inventory entry", str(p), sorted(by))
        return e  # type: ignore[return-value]

    s.eq("main: only one", [True], [e["main"] for e in entries if e["main"]])
    s.eq("a: branch", "plotroom-a", at(a).get("branch"))
    s.eq("a: the noted pull request", 7, at(a).get("number"))
    s.eq("a: its fetched ref", "refs/plotroom-pr/i/nv/pr-7", at(a).get("ref"))
    s.eq("a: not main, locked or missing", [False, False, False], [at(a).get(k) for k in ("main", "locked", "missing")])
    s.eq("b: detached", True, at(b).get("detached"))
    s.eq("b: no branch", None, at(b).get("branch"))
    s.eq("c: locked", True, at(c).get("locked"))
    s.eq("c: no item noted", None, at(c).get("number"))
    s.eq("d: folder missing", True, at(d).get("missing"))
    s.eq("the folder a was never touched by listing", True, a.is_dir())

    clean = call("inventoryDirty", path=str(a), branch="plotroom-a")
    s.eq("clean: ok (problem: %r)" % clean.get("problem"), True, clean.get("ok"))
    s.eq("clean a", False, (clean.get("data") or {}).get("dirty"))  # type: ignore[union-attr]
    (a / "scratch.txt").write_text("uncommitted\n", encoding="utf-8")
    s.eq("dirty a", True, (call("inventoryDirty", path=str(a), branch="plotroom-a").get("data") or {}).get("dirty"))  # type: ignore[union-attr]

    refused("the main checkout", "main checkout", path=str(root), branch="main")
    refused("a branch that changed", "changed", path=str(a), branch="somewhere-else")
    refused("a locked worktree", "locked", path=str(c), branch="locked-c")
    refused("a missing folder", "missing", path=str(d), branch="gone-d")
    refused("not a worktree", "not a worktree", path=str(base / "nothing"), branch="x")
    refused("uncommitted changes", "", path=str(a), branch="plotroom-a")
    s.eq("a kept with its changes", True, (a / "scratch.txt").is_file())
    s.eq("a's branch kept", True, s.ref(root, "refs/heads/plotroom-a") is not None)

    (a / "scratch.txt").unlink()
    done = call("removeEntry", path=str(a), branch="plotroom-a")
    s.eq("remove a: ok (problem: %r)" % done.get("problem"), True, done.get("ok"))
    s.eq("a's folder is gone", False, a.exists())
    s.eq("a's worktree is no longer listed", False, str(a) in s.out(root, "worktree", "list", "--porcelain"))
    removed = call("removeEntry", path=str(b))
    s.eq("remove detached b: ok (problem: %r)" % removed.get("problem"), True, removed.get("ok"))
    s.eq("b says it had no branch", "It had no branch.", (removed.get("data") or {}).get("branch"))  # type: ignore[union-attr]
    s.eq("b's folder is gone", False, b.exists())
    s.eq("c (locked) is still there", True, c.is_dir())
    s.eq("main still listed first", os.path.realpath(str(root)), os.path.realpath(s.out(root, "worktree", "list", "--porcelain").split("\n")[0][len("worktree "):]))


def sc_draft_push(s: Smoke) -> None:
    """A draft pull request's preview reads the branch against the base as the local bare remote has it, and writes nothing there; the push sends exactly the
    previewed commit, never force: it is refused once the branch moved after the preview or the remote's branch diverged, and a refused or failed push leaves
    the remote as it was. Every remote is a local bare repository behind the fake ssh; nothing real is contacted."""
    root, key, bare = s.checkout("draft"), "d/raft", s.bare("d/raft")

    def commit(name: str) -> str:
        (root / name).write_text(name + "\n", encoding="utf-8")
        s.out(root, "add", name)
        s.out(root, "commit", "-q", "-m", "add " + name)
        return s.out(root, "rev-parse", "HEAD")

    def preview(base: str = "main") -> Dict[str, object]:
        return s.run_request({"op": "draft", "repo": key, "path": str(root), "base": base, "checkout": str(root)}, "draft preview of %s into %s" % (key, base))

    def push(draft: object) -> Dict[str, object]:
        return s.run_request({"op": "push", "draft": draft, "checkout": str(root)}, "push of the previewed draft")

    def remote_topic() -> Optional[str]:
        return s.ref(bare, "refs/heads/topic")

    def previewed(base: str = "main") -> Dict[str, object]:
        data = preview(base)
        s.eq("preview ok (problem: %r)" % data.get("problem"), True, data.get("ok"))
        draft = data.get("data")
        if not isinstance(draft, dict):
            s.fail("draft", "an object", repr(draft))
        return draft  # type: ignore[return-value]

    main = s.out(root, "rev-parse", "main")
    # Nothing to propose: on the base itself, then a branch with no commit of its own.
    s.contains("on the base itself", "nothing to propose", preview().get("problem"))
    s.out(root, "checkout", "-q", "-b", "topic")
    s.contains("no commits over the base", "no commits", preview().get("problem"))
    s.eq("a base that does not exist is no draft", False, preview("no-such-base").get("ok"))
    s.eq("a base that is no branch name is no draft", False, preview("bad..name").get("ok"))
    first = commit("one.txt")
    draft = previewed()
    s.eq("branch", "topic", draft.get("branch"))
    s.eq("head", first, draft.get("head"))
    s.eq("base", "main", draft.get("base"))
    s.eq("base commit (as the remote has it)", main, draft.get("baseSha"))
    s.eq("commits over the base", 1, draft.get("count"))
    s.eq("one commit's subject is the title", "add one.txt", draft.get("title"))
    s.contains("the commit line", "add one.txt", (draft.get("commits") or [""])[0])  # type: ignore[index]
    s.eq("not on the remote yet", True, draft.get("needsPush"))
    s.eq("the preview pushed nothing", None, remote_topic())
    s.eq("the preview made no remote-tracking branch", None, s.ref(root, "refs/remotes/origin/topic"))
    # Push: the previewed commit lands on the remote's branch of that name.
    sent = push(draft)
    s.eq("push ok (problem: %r)" % sent.get("problem"), True, sent.get("ok"))
    s.eq("the remote's topic is the previewed commit", first, remote_topic())
    s.eq("nothing left to push after it", False, previewed().get("needsPush"))
    # A second commit after the preview: the old preview no longer says what is on the branch, so nothing is pushed.
    stale = previewed()
    second = commit("two.txt")
    moved = push(stale)
    s.eq("stale push refused", False, moved.get("ok"))
    s.contains("why", "moved since the preview", moved.get("problem"))
    s.eq("the remote kept the first commit", first, remote_topic())
    s.eq("a fresh preview pushes the new commit", True, push(previewed()).get("ok"))
    s.eq("the remote's topic is the second commit", second, remote_topic())
    # The remote's branch diverged (someone else's work): a plain push is rejected, never forced.
    scratch = s.repos[key]["scratch"]
    s.out(scratch, "checkout", "-q", "-B", "other", "main")  # type: ignore[arg-type]
    (scratch / "theirs.txt").write_text("theirs\n", encoding="utf-8")  # type: ignore[operator]
    s.out(scratch, "add", "-A")  # type: ignore[arg-type]
    s.out(scratch, "commit", "-q", "-m", "theirs")  # type: ignore[arg-type]
    theirs = s.out(scratch, "rev-parse", "HEAD")  # type: ignore[arg-type]
    s.out(scratch, "push", "-q", "--force", str(bare), "%s:refs/heads/topic" % theirs)  # type: ignore[arg-type]
    s.out(scratch, "checkout", "-q", "main")  # type: ignore[arg-type]
    third = commit("three.txt")
    rejected = push(previewed())
    s.eq("diverged push refused (head %s)" % third, False, rejected.get("ok"))
    s.eq("the remote's work is untouched, nothing forced", theirs, remote_topic())
    # A detached HEAD has no branch to propose.
    s.out(root, "checkout", "-q", "--detach")
    s.contains("detached", "detached", preview().get("problem"))
    s.out(root, "checkout", "-q", "topic")


def sc_workflow(s: Smoke) -> None:
    """The workflow commands on a real Plotroom block, run through the palette ids a user runs: mark seen drops one "New" badge and nothing else; snooze hides
    the item until the snoozed listing is turned on (it then wears a "Snoozed" badge); the attention filter names itself; the next sort order says which it
    is; the Worktrees list lists a worktree git has, an unnoted one marked as such. The list is what the fake gh answers; no remote is written."""
    root, wt = s.checkout("flow"), s.tmp / "wts" / "flow-board"
    stamp = "2026-01-01T00:00:00Z"
    prs = [
        {"number": n, "title": "Flow PR %d" % n, "url": "https://github.com/f/low/pull/%d" % n, "author": "octo", "state": "OPEN", "isDraft": False,
         "updatedAt": "2026-01-0%dT00:00:00Z" % (3 - n), "createdAt": stamp, "head": "feature-%d" % n, "base": "main", "additions": 1, "deletions": 0,
         "changedFiles": 1, "comments": 0, "labels": [], "runs": [], "runTotal": 0}
        for n in (1, 2)
    ]
    (s.smoke / "search.json").write_text(json.dumps(prs), encoding="utf-8")
    s.cd(root)
    s.ctl_ok("plugins", "run", "plugin.plotroom.open")
    s.wait_text("the first pull request", "Flow PR 1")
    s.wait_text("the second pull request", "Flow PR 2")
    s.wait_until("unseen pull requests wear New", lambda: s.count("New") >= 1)
    # A nonempty queue opens with its first row selected and previewed natively; that arrival marks only it seen, and idle time marks no other.
    s.wait_until("the first row is selected when the queue opens", lambda: len(s.selection()) == 1)
    s.wait_until("its native preview is rendered (title drawn outside the rows)", lambda: s.previewing())
    chosen = s.selection()
    time.sleep(2.0)
    left = s.count("New")
    s.eq("the arrival marked only the selected row seen: the other stays New", 1, left)
    s.shot("initial-auto-selected")
    s.eq("no empty preview pane", False, any("Nothing to preview" in t for t in s.texts()))
    s.eq("no Close preview control anywhere", False, any("Close preview" in t for t in s.texts()))
    # The palette (primary key ".") is grouped; the selected pull request's provider operations sit in the typed group, local state in Triage.
    s.ctl_ok("key", ".")
    s.wait_text("the palette lists the queue's own commands", "Refresh")
    for group in ("GitHub - PR", "Triage", "Filter & Sort", "Views"):
        s.wait_text("the palette group %s" % group, group)
    shown = s.texts()
    s.eq("the palette lists Saved actions first, then the item's operations, then Filter & Sort", True, shown.index("Saved actions") < shown.index("GitHub - PR") < shown.index("Filter & Sort"))
    s.eq("no Agent picker entry in the primary palette", False, any(t == "Agent picker" for t in s.texts()))
    s.eq("no Close preview command", False, any(t == "Close preview" for t in s.texts()))
    s.eq("the unscoped provider-only groups are not the item's", False, any(t == "GitHub - Issue" for t in s.texts()))
    s.wait_text("the selected item's commands", "Mark seen")
    s.shot("palette-selected")
    s.ctl_ok("key", "Escape")
    s.wait_until("the palette is closed", lambda: not any(t == "Refresh" for t in s.texts()))
    s.eq("the palette left the selection alone", chosen, s.selection())
    s.eq("and its preview", True, s.previewing())
    # Selecting a second unread row marks that one seen by itself: exactly one more New badge goes.
    s.ctl_ok("key", "Down")
    s.wait_until("the second row is selected", lambda: len(s.selection()) == 1 and s.selection() != chosen)
    s.wait_until("its preview is rendered", lambda: s.previewing())
    s.wait_until("selecting alone drops one more New badge", lambda: s.count("New") == left - 1)
    s.ctl_ok("key", "Up")
    s.wait_until("back on the first row", lambda: s.selection() == chosen)
    # A compact window (default 1280 wide, panes ~611 px) still shows a readable preview; Escape never closes it.
    s.ctl_ok("resize", "1280", "800")
    s.wait_until("the compact preview is rendered", lambda: s.previewing())
    s.eq("the compact preview keeps the selection", chosen, s.selection())
    s.shot("compact-preview")
    s.ctl_ok("key", "Escape")
    time.sleep(1.0)
    s.eq("Escape keeps the selection", chosen, s.selection())
    s.eq("and the preview", True, s.previewing())
    s.ctl_ok("resize", "2200", "1000")
    s.wait_until("the wide preview is rendered", lambda: s.previewing())
    s.shot("preview-kept")
    s.ctl_ok("plugins", "run", "plugin.plotroom.snooze")
    s.wait_text("the snooze toast", "Snoozed until")
    s.wait_until("the snoozed pull request is hidden", lambda: not any("Flow PR 1" in t for t in s.texts()))
    s.eq("the other pull request stays listed", True, any("Flow PR 2" in t for t in s.texts()))
    s.ctl_ok("plugins", "run", "plugin.plotroom.toggle-snoozed")
    s.wait_until("the snoozed pull request is listed again, marked", lambda: s.count("Snoozed") >= 1 and any("Flow PR 1" in t for t in s.texts()))
    s.ctl_ok("plugins", "run", "plugin.plotroom.toggle-snoozed")
    s.wait_until("hidden again", lambda: not any("Flow PR 1" in t for t in s.texts()))
    held = s.selection()
    s.ctl_ok("plugins", "run", "plugin.plotroom.attention")
    s.wait_text("the attention filter is named", "Needs attention only")
    s.ctl_ok("plugins", "run", "plugin.plotroom.attention")
    time.sleep(1.0)
    s.eq("a filter toggled and undone keeps the selection steady", held, s.selection())
    s.ctl_ok("plugins", "run", "plugin.plotroom.sort")
    s.wait_text("the sort toast", "Sorted: ")
    s.wait_until("the sort is stated in the view's own line, not only a toast", lambda: any(t.startswith("Sort: ") for t in s.texts()))
    s.shot("sorted")
    # The board: one unnoted worktree, made dirty with no press; one linked to the pull request the fake gh answers for.
    linked = s.tmp / "wts" / "flow-linked"
    s.out(root, "worktree", "add", "-q", "-b", "board-branch", str(wt))
    s.out(root, "worktree", "add", "-q", "-b", "board-linked", str(linked))
    s.out(root, "config", "branch.board-linked.plotroompr", "1")
    s.out(root, "config", "branch.board-linked.plotroomrepo", "f/low")
    both = s.tmp / "wts" / "flow-both"
    s.out(root, "worktree", "add", "-q", "-b", "board-both", str(both))
    s.out(root, "config", "branch.board-both.plotroompr", "2")
    s.out(root, "config", "branch.board-both.plotroomkey", "f/low#9")
    s.out(root, "config", "branch.board-both.plotroomrepo", "f/low")
    (s.smoke / "issues.json").write_text(json.dumps([{"number": 9, "title": "Flow issue 9", "url": "https://github.com/f/low/issues/9", "state": "OPEN", "reason": None,
                                                      "updatedAt": stamp, "createdAt": stamp, "author": "octo", "comments": 0, "labels": [], "assignees": []}]), encoding="utf-8")
    (wt / "dirty.txt").write_text("uncommitted\n", encoding="utf-8")
    # Views holds every sidebar scope: jump to the Worktrees list through the palette's Views group (the sidebar's own dispatch).
    s.ctl_ok("key", ".")
    s.wait_text("the palette", "Refresh")
    s.wait_text("the Views group names the Worktrees list scope", "Worktrees list")
    s.wait_text("and Open item by URL", "Open item by URL")
    s.eq("the old board wording is gone", False, any("Worktrees board" in t for t in s.texts()))
    s.ctl_ok("type", json.dumps("Worktrees list"))
    time.sleep(0.5)
    s.ctl_ok("key", "Enter")
    s.wait_text("the Worktrees list lists the worktree git has, unnoted", "Unnoted")
    s.wait_text("and the main worktree", "Main")
    s.wait_text("the dirty worktree says so by itself", "Changes")
    s.wait_until("the list opens with a row selected and previewed", lambda: len(s.selection()) == 1 and s.previewing())
    s.eq("no empty preview pane", False, any("Nothing to preview" in t for t in s.texts()))
    s.eq("no Close preview control", False, any("Close preview" in t for t in s.texts()))
    s.shot("board-initial")
    seen_linked = seen_plain = seen_both = False
    for n in range(9):  # walk the rows from the auto-selected first one: each selection shows its preview
        if n:
            s.ctl_ok("key", "Down")
        time.sleep(0.7)
        ts = s.texts()
        if len(s.selection()) != 1 or not s.preview_texts():  # one visible row, and its native preview slot holds content
            continue
        if any(t.startswith("Pull request #2") for t in ts):
            # a worktree made for an issue AND its pull request: both as the tracker answered, not placeholders
            deadline = time.monotonic() + SMOKE_TIMEOUT
            while not (any("Flow PR 2" in t for t in s.texts()) and any("Flow issue 9" in t for t in s.texts())):
                if time.monotonic() > deadline or not s.alive():
                    s.fail("the both-linked preview's fetched titles", "texts with 'Flow PR 2' and 'Flow issue 9'", [t for t in s.texts() if "#2" in t or "#9" in t or "Loading" in t])
                time.sleep(0.2)
            seen_both = True
            s.eq("no placeholder is left in the both-linked preview", False, any(t.startswith("Loading") and ("#2" in t or "#9" in t) for t in s.texts()))
            s.shot("board-both-preview")
        elif any(t.startswith("Pull request #1") for t in ts):
            # the tracker's answer, not the placeholder
            deadline = time.monotonic() + SMOKE_TIMEOUT
            while not any("Flow PR 1" in t for t in s.texts()):
                if time.monotonic() > deadline or not s.alive():
                    s.fail("the linked preview's fetched title", "a text with 'Flow PR 1'", [t for t in s.texts() if "#1" in t])
                time.sleep(0.2)
            seen_linked = True
            s.eq("the fetched title replaced Loading #1", False, any(t.startswith("Loading #1") for t in s.texts()))
            s.shot("board-linked-preview")
        # An unlinked worktree's preview is titled by its folder: that text twice (the row's label and the preview's title).
        elif sum(1 for t in ts if t == wt.name) >= 2:
            seen_plain = True
            s.shot("board-unlinked-preview")
        if seen_linked and seen_plain and seen_both:
            break
    s.eq("a worktree linked to both a pull request and an issue previews both fetched titles", True, seen_both)
    s.eq("the linked worktree's preview names its pull request by the fetched title", True, seen_linked)
    s.eq("the unlinked worktree's preview falls back to its folder name, apart from its row", True, seen_plain)
    s.ctl_ok("key", "Escape")
    time.sleep(1.0)
    s.eq("Escape keeps the list's selection", 1, len(s.selection()))
    s.eq("and its preview", True, s.previewing())
    # Views jump back to a normal view by its sidebar name.
    s.ctl_ok("key", ".")
    s.wait_text("the palette", "Refresh")
    s.ctl_ok("type", json.dumps("My PRs"))
    time.sleep(0.5)
    s.ctl_ok("key", "Enter")
    s.wait_until("the normal view's queue is back, not the worktrees", lambda: any("Flow PR 2" in t for t in s.texts()) and not any(t == "Unnoted" for t in s.texts()))
    s.wait_until("it opens with a row selected and previewed", lambda: len(s.selection()) == 1 and s.previewing())


def sc_prompts(s: Smoke) -> None:
    """The prompt and picker flows, typed and picked as a user does: Open item by URL pins the pull request the (fake) gh answers for; Export saves the picked
    view to a file; Import of that file asks before it writes: its Cancel row (first, so Enter) writes nothing, its Import row does. Every write is to the
    block's own plugin store or a file under the temporary directory. Continues in the checkout and block `sc_workflow` left."""
    exported = s.tmp / "exported.json"
    listed = json.loads((s.smoke / "search.json").read_text(encoding="utf-8"))
    stamp = "2026-01-01T00:00:00Z"
    listed.append({"number": 5, "title": "Pinned PR 5", "url": "https://github.com/f/low/pull/5", "author": "octo", "state": "OPEN", "isDraft": False,
                   "updatedAt": stamp, "createdAt": stamp, "head": "feature-5", "base": "main", "additions": 1, "deletions": 0, "changedFiles": 1,
                   "comments": 0, "labels": [], "runs": [], "runTotal": 0})
    (s.smoke / "search.json").write_text(json.dumps(listed), encoding="utf-8")
    s.ctl_ok("plugins", "run", "plugin.plotroom.open-url")
    s.wait_text("the URL prompt", "GitHub pull request or issue URL")
    s.ctl_ok("type", json.dumps("https://github.com/f/low/pull/5"))
    s.ctl_ok("key", "Enter")
    s.wait_text("the pinned pull request", "f/low#5")
    s.wait_text("the requested pull request's row", "Pinned PR 5")
    s.wait_until("no other pull request under the pin", lambda: not any("Flow PR" in t for t in s.texts()))
    s.shot("url")
    # A second pin joins the first (grouped, each its own view); the row of the one requested shows while it is the active pin.
    listed.append(dict(listed[-1], number=6, title="Pinned PR 6", url="https://github.com/f/low/pull/6", head="feature-6"))
    (s.smoke / "search.json").write_text(json.dumps(listed), encoding="utf-8")
    s.ctl_ok("plugins", "run", "plugin.plotroom.open-url")
    s.wait_text("the URL prompt again", "GitHub pull request or issue URL")
    s.ctl_ok("type", json.dumps("https://github.com/f/low/pull/6"))
    s.ctl_ok("key", "Enter")
    s.wait_text("the second pinned pull request", "Pinned PR 6")
    s.wait_text("the first pin is still there", "f/low#5")
    s.wait_text("and the second", "f/low#6")
    s.shot("pins")
    s.wait_until("the Pins group is in the scopes", lambda: any(t == "Pins" for t in s.texts()))
    s.wait_until("the pinned item's native preview is rendered", lambda: len(s.selection()) == 1 and s.previewing())
    # Unpin through the palette (primary key "."), filtered to the one command: only the target goes, the other pin stays.
    s.ctl_ok("key", ".")
    s.wait_text("the palette", "Refresh")
    s.ctl_ok("type", json.dumps("Unpin"))
    time.sleep(0.5)
    s.ctl_ok("key", "Enter")
    s.wait_until("the unpinned item is gone", lambda: not any("f/low#6" in t for t in s.texts() if not t.startswith("Unpinned")))
    s.eq("the other pin remains", True, any("f/low#5" in t for t in s.texts()))
    s.eq("the Pins group is still listed", True, any(t == "Pins" for t in s.texts()))
    s.shot("unpinned")
    # Views holds the pins too: jump to the remaining pin through the palette.
    s.ctl_ok("key", ".")
    s.wait_text("the palette", "Refresh")
    s.ctl_ok("type", json.dumps("f/low#5"))
    time.sleep(0.5)
    s.ctl_ok("key", "Enter")
    s.wait_until("the remaining pin's item previews", lambda: any("Pinned PR 5" in t for t in s.texts()) and s.previewing())

    def export_through(confirm: bool) -> None:
        s.ctl_ok("plugins", "run", "plugin.plotroom.export")
        s.wait_text("the export picker", "Pick what to export")
        s.ctl_ok("picker", "down")  # past Done, onto the first view
        s.ctl_ok("picker", "enter")  # toggles it
        s.wait_text("one view picked", "1 picked")
        s.ctl_ok("picker", "enter")  # Done
        s.wait_text("what leaves is confirmed first, with the host's real counts", "Export 1 view(s), 0 action(s)")
        s.shot("export-confirm" if confirm else "export-cancel")
        s.eq("the confirmation wrote no file yet", False, exported.exists())
        if not confirm:
            s.ctl_ok("picker", "enter")  # Cancel, first
            time.sleep(1.5)
            s.eq("cancelling wrote no file", False, exported.exists())
            s.eq("cancelling exported nothing", False, any(t.startswith("Exported ") for t in s.texts()))
            return
        s.ctl_ok("picker", "down")  # past Cancel
        s.ctl_ok("picker", "down")  # past Copy: Write to a file…
        s.ctl_ok("picker", "enter")
        s.wait_text("the file prompt", "File path to write the export to")
        s.ctl_ok("type", json.dumps(str(exported)))
        s.ctl_ok("key", "Enter")
        s.wait_text("the export toast", "Exported 1 view(s), 0 action(s)")

    export_through(False)
    export_through(True)
    deadline = time.monotonic() + SMOKE_TIMEOUT
    while not exported.is_file():
        if time.monotonic() > deadline:
            s.fail("the export file", str(exported), "never written")
        time.sleep(0.2)
    time.sleep(0.5)
    text = exported.read_text(encoding="utf-8")
    try:
        data = json.loads(text)
    except ValueError as why:
        s.fail("the export file", "JSON", why)
    s.eq("the export is an object", True, isinstance(data, dict))
    s.eq("exactly the one picked view", 1, len(data.get("views") or []))  # type: ignore[union-attr]
    s.eq("and no action", 0, len(data.get("prompts") or []))  # type: ignore[union-attr]
    view = data["views"][0]  # type: ignore[index]
    s.eq("the view is complete", True, all(k in view for k in ("kind", "name", "integration", "query", "group")))
    s.eq("it holds nothing local (no checkout path)", False, str(s.tmp) in text.replace(str(exported), ""))
    s.shot("export")

    def import_through(confirm: bool) -> None:
        s.ctl_ok("plugins", "run", "plugin.plotroom.import")
        s.wait_text("the import prompt", "Paste exported JSON")
        s.ctl_ok("type", json.dumps(str(exported)))
        s.ctl_ok("key", "Enter")
        s.wait_text("what the file holds", "Import: what the file holds")
        s.ctl_ok("picker", "down")  # past Cancel
        s.ctl_ok("picker", "enter")  # Continue
        # Conflicts (the view is already here) and account slots each ask once more; the second row of a conflict is "Duplicate".
        deadline = time.monotonic() + SMOKE_TIMEOUT
        asked = 0
        while not any(re.match(r"Import \d+ item\(s\)$", t) for t in s.texts()):
            if time.monotonic() > deadline or not s.alive():
                s.fail("the import confirmation", "a picker headed 'Import N item(s)'", s.texts()[:40])
            ts = s.texts()
            if any("is already here" in t for t in ts) and asked < 5:
                asked += 1
                s.ctl_ok("picker", "down")
                s.ctl_ok("picker", "enter")
                time.sleep(0.5)
            elif any("Which account takes" in t for t in ts) and asked < 5:
                asked += 1
                s.ctl_ok("picker", "enter")
                time.sleep(0.5)
            time.sleep(0.2)
        s.shot("import-confirm" if confirm else "import-cancel")
        if confirm:
            s.ctl_ok("picker", "down")  # past Cancel
        s.ctl_ok("picker", "enter")

    import_through(False)
    time.sleep(1.5)
    s.eq("cancelling imports nothing", False, any("Imported " in t and " view" in t for t in s.texts()))
    import_through(True)
    s.wait_text("the import toast counts what was added (the duplicate)", "Imported 1 view and 0 actions")
    s.shot("imported")


def sc_agent(s: Smoke) -> None:
    """An agent started from a pull request's row, with the agent setting pointed at a local script that only prints and sleeps (no omp, no model, no
    network): the PR's worktree is made, the agent's pane starts in it and is linked to the PR, `agent-go` focuses exactly that pane, and asking again
    offers the running agent first (Go to agent) before Start another; dismissing that offer starts nothing."""
    root, wt = s.checkout("agent"), s.wt("a/gent", 1)
    fake = s.tmp / "fake-agent.sh"
    fake.write_text("#!/bin/sh\necho 'smoke agent: no model is called'\nexec sleep 3600\n", encoding="utf-8")
    fake.chmod(0o755)
    stamp = "2026-01-01T00:00:00Z"
    pr = {"number": 1, "title": "Agent PR 1", "url": "https://github.com/a/gent/pull/1", "author": "octo", "state": "OPEN", "isDraft": False,
          "updatedAt": stamp, "createdAt": stamp, "head": "feature-1", "base": "main", "additions": 1, "deletions": 0, "changedFiles": 1, "comments": 0,
          "labels": [], "runs": [], "runTotal": 0}
    (s.smoke / "search.json").write_text(json.dumps([pr]), encoding="utf-8")
    s.ctl_ok("agent-command", str(fake))
    s.ctl_ok("tab", "new")  # a real shell: the focused pane before this one is an earlier scenario's Plotroom block
    s.ctl_ok("ready")
    queue_tab = len(s.state()["tabs"])  # type: ignore[arg-type]
    s.cd(root)
    s.ctl_ok("plugins", "run", "plugin.plotroom.open")
    s.wait_text("the pull request", "Agent PR 1")
    s.select_row()
    s.ctl_ok("plugins", "run", "plugin.plotroom.agent-selected")
    s.wait_text("the action picker", "Run on ")
    s.ctl_ok("picker", "enter")  # "Type a prompt…", first when nothing ran before
    s.wait_text("the prompt", "Prompt for an agent on")
    s.ctl_ok("type", json.dumps("smoke prompt"))
    s.ctl_ok("key", "Enter")
    s.wait_text("the agent toast", "Agent started")
    s.eq("the worktree was made for it", True, wt.is_dir())

    def agent_focused() -> bool:
        return os.path.realpath(str(s.state()["focused"].get("cwd") or "")) == os.path.realpath(str(wt))  # type: ignore[union-attr]

    s.wait_until("the agent's pane is focused in the worktree", agent_focused)
    tabs = len(s.state()["tabs"])  # type: ignore[arg-type]

    def back_to_queue() -> None:
        s.ctl_ok("tab", str(queue_tab))
        s.wait_until("the queue's tab is focused again", lambda: not agent_focused())
        s.select_row()

    back_to_queue()
    s.ctl_ok("plugins", "run", "plugin.plotroom.agent-go")
    s.wait_until("agent-go focuses the pane the link names", agent_focused)
    s.shot("agent")

    back_to_queue()
    s.ctl_ok("plugins", "run", "plugin.plotroom.agent-selected")
    s.wait_text("the duplicate-launch offer", "An agent already works on")
    s.wait_text("Go to agent comes first", "Go to agent (")
    s.wait_text("Start another agent is the other choice", "Start another agent")
    s.shot("agent-offer")
    s.ctl_ok("picker", "esc")
    time.sleep(1.0)
    s.eq("dismissing the offer started nothing", tabs, len(s.state()["tabs"]))  # type: ignore[arg-type]
    s.eq("the queue's tab still has focus", False, agent_focused())
    s.ctl_ok("plugins", "run", "plugin.plotroom.agent-selected")
    s.wait_text("the offer again", "An agent already works on")
    s.ctl_ok("picker", "enter")  # Go to agent
    s.wait_until("the offer's Go to agent focuses the agent", agent_focused)
    s.eq("still one agent's tab", tabs, len(s.state()["tabs"]))  # type: ignore[arg-type]

    # Draft PR: only an issue with a worktree can start one (it starts from the issue's branch), so pin a GitHub issue by URL, make its worktree, commit
    # in it, and walk the draft up to its review: destination picker first, then the bases, then the review. Dismissing the review writes nothing
    # (no `gh pr create` is reached, nothing is pushed, and the fake gh logs any call it does not know).
    stamp = "2026-01-01T00:00:00Z"
    issue = {"number": 9, "title": "Draft issue 9", "url": "https://github.com/a/gent/issues/9", "state": "OPEN", "reason": None, "updatedAt": stamp,
             "createdAt": stamp, "author": "octo", "comments": 0, "labels": [], "assignees": []}
    (s.smoke / "issues.json").write_text(json.dumps([issue]), encoding="utf-8")
    back_to_queue()
    s.ctl_ok("plugins", "run", "plugin.plotroom.open-url")
    s.wait_text("the URL prompt", "GitHub pull request or issue URL")
    s.ctl_ok("type", json.dumps("https://github.com/a/gent/issues/9"))
    s.ctl_ok("key", "Enter")
    s.wait_text("the pinned issue's row", "Draft issue 9")
    s.select_row()
    s.ctl_ok("plugins", "run", "plugin.plotroom.worktree-selected")
    issue_wt = s.issue_wt("a/gent", "9")
    deadline = time.monotonic() + SMOKE_TIMEOUT
    while not issue_wt.is_dir():
        if time.monotonic() > deadline or not s.alive():
            s.fail("the issue's worktree", str(issue_wt), s.texts()[:40])
        ts = s.texts()
        if any(t.startswith("Which branch for") for t in ts):
            s.ctl_ok("picker", "enter")  # no linked pull request: New branch…
        elif any(t.startswith("Start ") and t.endswith(" from…") for t in ts):
            s.ctl_ok("picker", "enter")  # the default branch
        time.sleep(0.7)
    s.wait_text("the worktree toast", "Worktree ready for")
    (issue_wt / "draft-work.txt").write_text("work\n", encoding="utf-8")
    s.out(issue_wt, "add", "draft-work.txt")
    s.out(issue_wt, "commit", "-q", "-m", "draft work")
    refs_before = s.out(s.bare("a/gent"), "for-each-ref", "--format=%(refname) %(objectname)")
    back_to_queue()
    s.ctl_ok("plugins", "run", "plugin.plotroom.draft-pr")
    s.wait_text("the destination picker comes first", "Where should the draft PR from")
    s.wait_text("it offers the repository itself", "Open the pull request on a/gent")
    s.shot("draft-destination")
    s.ctl_ok("picker", "enter")
    s.wait_text("then the base picker", "Open a draft PR from")
    s.ctl_ok("picker", "enter")  # the default branch
    s.wait_text("then the review of the draft", "Draft PR: ")
    s.shot("draft-review")
    s.ctl_ok("picker", "esc")
    time.sleep(1.0)
    s.eq("dismissing the review pushed nothing: the remote's refs are as before", refs_before, s.out(s.bare("a/gent"), "for-each-ref", "--format=%(refname) %(objectname)"))


SCENARIOS = [
    ("create", sc_create),
    ("reuse", sc_reuse),
    ("dirty reuse", sc_dirty_reuse),
    ("advanced PR head", sc_advanced),
    ("post-checkout hook", sc_hook),
    ("existing branch", sc_existing_branch),
    ("deleted head branch", sc_deleted_branch),
    (".github", sc_dot_github),
    ("recovery", sc_recovery),
    ("fork PRs", sc_fork),
    ("folder names", sc_pr_dir),
    ("issue worktree", sc_issue),
    ("jira issue worktree", sc_jira_issue),
    ("scan", sc_scan),
    ("issue on a linked PR", sc_issue_pr),
    ("remote branches", sc_remote_branches),
    ("remote host", sc_remote_host),
    ("worktree inventory", sc_inventory),
    ("draft preview and push", sc_draft_push),
    ("triage, sort and worktrees board", sc_workflow),
    ("URL, export and import prompts", sc_prompts),
    ("agent launch, jump and duplicate offer", sc_agent),
]


def check_smoke() -> str:
    tern, git, omp = smoke_prerequisites()
    started = time.monotonic()
    tmp = Path(tempfile.mkdtemp(prefix="plotroom-smoke-", dir="/tmp" if os.path.isdir("/tmp") else None)).resolve()
    s = Smoke(tern, git, omp, tmp)
    try:
        s.repo("o", "r", "r", (1, 2, 3, 6, 7, 10), deleted=(10,))
        s.fork_pr("o/r", 4)
        s.fork_pr("o/r", 5, gone=True)
        s.repo("github", ".github", "dotgithub", (1,))
        s.repo("p", "q", "q", (1,))
        s.repo("o", "remote", "remote", (1,))
        s.repo("i", "nv", "inv", ())
        s.repo("d", "raft", "draft", ())
        s.repo("f", "low", "flow", (5,))
        s.repo("a", "gent", "agent", (1,))
        s.start()
        s.selftest()
        for number, (name, scenario) in enumerate(SCENARIOS, 1):
            s.label = "scenario %d (%s)" % (number, name)
            try:
                scenario(s)
            except GateError as why:
                raise GateError("%s\n  last smoke result: %s" % (why, json.dumps(s.last)))
        s.final()
        return "selftest toast, css clean, %d real-git scenarios (%.1f s)" % (len(SCENARIOS), time.monotonic() - started)
    except BaseException:
        s.dump()
        raise
    finally:
        s.stop()
        shutil.rmtree(str(tmp), ignore_errors=True)


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
    if args.command in ("all", "types"):
        plan.append(("types", check_types))
    if args.command in ("all", "bench"):
        plan.append(("bench", check_bench))
    results: List[Tuple[str, str, str]] = []
    if args.command in ("all", "smoke"):
        if args.ci:
            results.append(("smoke", "NOT RUN", "--ci: Tern is not available on CI; run `python3 scripts/check.py smoke` locally"))
        else:
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
    order = {"test": 0, "types": 1, "bench": 2, "smoke": 3}
    results.sort(key=lambda row: order[row[0]])
    return summarize(results)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
