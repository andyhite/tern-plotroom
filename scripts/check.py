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
        through plugin.plotroom.smoke (plugin/tests/runtime.luau) with a fake gh on PATH, and a
        Plotroom block on an attached loopback host making its worktree through the real link flow.

Tools: LUAU, LUAU_LSP, TERN (paths) -> the cache below -> PATH. `tools` is the only network access.
Pinned: Luau 0.742, luau-lsp 1.70.1, Tern 0.8.3 (e2b8656). Cache: $XDG_CACHE_HOME or ~/.cache, plotroom-check/.
Smoke prerequisites: Tern 0.8.3 (TERN=/path or PATH), git >= 2.36, omp on PATH, Python 3.9+. No network; every repository,
fake gh/ssh, Tern directory and log lives under one temporary directory that is deleted afterwards.
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
TERN_VERSION = "0.8.3"
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
# plugin.plotroom.smoke (plugin/tests/runtime.luau) runs worktree.open (a PR's) or worktree.openIssue (an issue's) for each scenario; git is the oracle.

SMOKE_TOAST = "Plotroom self-test passed"
GIT_MIN = (2, 36)  # `git worktree list --porcelain -z` arrived in 2.36
SYSTEM_PATH = ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
SMOKE_TIMEOUT = 60  # seconds a single smoke request may take

# Fake gh: the canned pull request file, or the 404 gh prints for a pull request it cannot see; a search answers with the
# canned list in search.json (none: empty), a checks load with no checks, `auth status` with one signed-in login (the
# repository picker's list, warmed after a search). Header is prepended.
FAKE_GH = r'''
import json, os, re, sys
a = sys.argv[1:]
m = None
if len(a) == 6 and a[:3] == ["api", "--hostname", "github.com"] and a[4] == "--jq":
    m = re.fullmatch(r"repos/([^/]+)/([^/]+)/pulls/(\d+)", a[3])
if a[:2] == ["api", "graphql"]:
    fields = dict(x.split("=", 1) for x, flag in zip(a[1:], a) if flag in ("-f", "-F") and "=" in x)
    if "q" in fields:
        f = os.path.join(SMOKE, "search.json")
        items = json.load(open(f)) if os.path.exists(f) else []
        sys.stdout.write(json.dumps({"total": len(items), "next": None, "cost": 1, "items": items}))
        sys.exit(0)
    if "o" in fields:
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

# Fake ssh: only `git-upload-pack 'owner/name.git'`, served from the local bare repository.
FAKE_SSH = r'''
import os, shlex, sys
a = sys.argv[1:]
w = []
try:
    w = shlex.split(a[-1]) if a else []
except ValueError:
    pass
if len(w) == 2 and w[0] == "git-upload-pack" and not w[1].startswith("/") and ".." not in w[1].split("/"):
    os.execv(GIT, [GIT, "upload-pack", os.path.join(SMOKE, "remotes", w[1])])
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
            "smoke needs Tern %s: %s. Install it, or set TERN=/path/to/tern."
            % (TERN_VERSION, "TERN=%s is not an executable file" % given if given else "no `tern` on PATH")
        )
    done = run([tern, "--version"], timeout=30)
    banner = (done.stdout + done.stderr).strip()
    if TERN_VERSION not in banner:
        raise GateError("smoke needs Tern %s; %s reports %r. Install %s or set TERN=/path/to/tern." % (TERN_VERSION, tern, banner, TERN_VERSION))
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

    def repo(self, owner: str, name: str, dirname: str, prs: Tuple[int, ...]) -> None:
        """Bare remote with main and refs/pull/N/head, plus a checkout whose origin reads as github.com but goes through fake ssh."""
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
            self.shas[(key, n)] = self.push_pr(key, n, "main")
            self.canned(key, n, self.shas[(key, n)])

    def push_pr(self, key: str, n: int, base: str) -> str:
        """A new commit on top of `base` (a scratch ref), pushed (forced) to the bare remote's refs/pull/n/head."""
        r = self.repos[key]
        scratch, bare = r["scratch"], r["bare"]
        r["count"] = int(r["count"]) + 1  # type: ignore[arg-type]
        self.out(scratch, "checkout", "-q", "-B", "pr-%d" % n, base)  # type: ignore[arg-type]
        (scratch / ("pr-%d-%d.txt" % (n, r["count"]))).write_text("pull request %d, commit %d\n" % (n, r["count"]), encoding="utf-8")  # type: ignore[operator,index]
        self.out(scratch, "add", "-A")  # type: ignore[arg-type]
        self.out(scratch, "commit", "-q", "-m", "pr %d #%d" % (n, r["count"]))  # type: ignore[arg-type]
        sha = self.out(scratch, "rev-parse", "HEAD")  # type: ignore[arg-type]
        self.out(scratch, "push", "-q", "--force", str(bare), "%s:refs/pull/%d/head" % (sha, n))  # type: ignore[arg-type]
        self.out(scratch, "checkout", "-q", "main")  # type: ignore[arg-type]
        return sha

    def canned(self, key: str, n: int, sha: str) -> None:
        owner, name = key.split("/")
        meta = {"base": key, "sha": sha, "ref": "feature-%d" % n, "state": "open"}
        (self.smoke / "pr" / ("%s__%s__%d.json" % (owner, name, n))).write_text(json.dumps(meta), encoding="utf-8")

    def checkout(self, dirname: str) -> Path:
        return self.work / dirname

    def wt(self, key: str, n: int) -> Path:
        """Where Plotroom puts the worktree: <omp worktrees>/plotroom-<owner>_<repo as named>-pr-N, lowercase."""
        return self.tmp / "omp-wt" / ("plotroom-%s-pr-%d" % (key.lower().replace("/", "_", 1), n))

    def issue_wt(self, key: str, ref: str) -> Path:
        """Where Plotroom puts an issue's worktree: <omp worktrees>/plotroom-<owner>_<repo as named>-issue-<ref>, lowercase."""
        return self.tmp / "omp-wt" / ("plotroom-%s-issue-%s" % (key.lower().replace("/", "_", 1), ref.lower()))

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
                for key in ("text", "value", "label", "title"):
                    if isinstance(node.get(key), str):
                        out.append(node[key])
                walk(node.get("children") or [])
            elif isinstance(node, list):
                for child in node:
                    walk(child)

        walk(json.loads(self.ctl("tree")).get("tree"))
        return out

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
            [self.tern, "serve", "--control", str(self.sock)],
            cwd=str(self.cwd), env=self.env, stdin=subprocess.DEVNULL, stdout=self.logf, stderr=subprocess.STDOUT,
        )
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            if not self.alive():
                self.fail("server start", "tern serve running", "exited with %s" % (self.proc.returncode if self.proc else None))
            try:
                if run([self.tern, "ctl", "--control", str(self.sock), "state"], env=self.env, timeout=10).returncode == 0:
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

    def open(self, repo: str, number: int, checkout: Path) -> Dict[str, object]:
        request = {"op": "open", "repo": repo, "number": number, "checkout": str(checkout)}
        return self.run_request(request, "open %s#%d" % (repo, number))

    def open_issue(self, repo: str, key: str, branch: str, checkout: Path) -> Dict[str, object]:
        request = {"op": "issue", "repo": repo, "key": key, "branch": branch, "checkout": str(checkout)}
        return self.run_request(request, "open issue %s#%s" % (repo, key))

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
    r = s.opened(s.open("o/r", 1, root))
    s.eq("created", True, r.get("created"))
    s.eq("head", sha, r.get("head"))
    s.eq("prHead", sha, r.get("prHead"))
    s.eq("dirty", False, r.get("dirty"))
    s.eq("branch", "plotroom/o/r/pr-1", r.get("branch"))
    s.eq("ref", "refs/plotroom-pr/o/r/pr-1", r.get("ref"))
    s.same_path("path", wt, r.get("path"))
    s.same_path("root", root, r.get("root"))
    s.eq("worktree directory exists", True, wt.is_dir())
    s.eq("git rev-parse --show-toplevel in the worktree", os.path.realpath(str(wt)), os.path.realpath(s.out(wt, "rev-parse", "--show-toplevel")))
    s.eq("refs/plotroom-pr/o/r/pr-1", sha, s.out(root, "rev-parse", "--verify", "refs/plotroom-pr/o/r/pr-1"))
    s.eq("refs/heads/plotroom/o/r/pr-1", sha, s.out(root, "rev-parse", "--verify", "refs/heads/plotroom/o/r/pr-1"))
    short = s.git(root, "rev-parse", "plotroom/o/r/pr-1")
    s.eq("rev-parse plotroom/o/r/pr-1 exit status", 0, short.returncode)
    s.eq("rev-parse plotroom/o/r/pr-1 stderr has no 'ambiguous'", False, "ambiguous" in short.stderr.lower())
    s.eq("rev-parse plotroom/o/r/pr-1 stdout", sha, short.stdout.strip())
    s.eq("update", [], s.last.get("update"))  # type: ignore[union-attr]
    cleanup = s.last.get("cleanup")  # type: ignore[union-attr]
    s.eq("cleanup command count", 3, len(cleanup) if isinstance(cleanup, list) else cleanup)


def sc_reuse(s: Smoke) -> None:
    root, wt, sha = s.checkout("r"), s.wt("o/r", 1), s.shas[("o/r", 1)]
    r = s.opened(s.open("o/r", 1, root))
    s.eq("created", False, r.get("created"))
    s.eq("head", sha, r.get("head"))
    s.eq("dirty", False, r.get("dirty"))
    s.eq("refs/plotroom-pr/o/r/pr-1 untouched", sha, s.out(root, "rev-parse", "refs/plotroom-pr/o/r/pr-1"))
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
    update = s.last.get("update")  # type: ignore[union-attr]
    s.eq("update command count", 2, len(update) if isinstance(update, list) else update)
    s.contains("update[1]", " fetch ", update[0])  # type: ignore[index]
    s.contains("update[2]", "merge --ff-only", update[1])  # type: ignore[index]
    s.eq("worktree HEAD still old", old, s.out(wt, "rev-parse", "HEAD"))
    s.eq("refs/plotroom-pr/o/r/pr-1 still old (no fetch on reuse)", old, s.out(root, "rev-parse", "refs/plotroom-pr/o/r/pr-1"))
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


def sc_branch_elsewhere(s: Smoke) -> None:
    root, wt = s.checkout("r"), s.wt("o/r", 3)
    main = s.out(root, "rev-parse", "main")
    s.out(root, "branch", "plotroom/o/r/pr-3", main)
    listed = s.out(root, "worktree", "list", "--porcelain")
    s.refused(s.open("o/r", 3, root))
    s.eq("branch plotroom/o/r/pr-3 still at main", main, s.out(root, "rev-parse", "refs/heads/plotroom/o/r/pr-3"))
    s.eq("worktree directory for pr-3 exists", False, wt.exists())
    s.eq("git worktree list", listed, s.out(root, "worktree", "list", "--porcelain"))


def sc_dot_github(s: Smoke) -> None:
    root, wt, sha = s.checkout("dotgithub"), s.wt("github/.github", 1), s.shas[("github/.github", 1)]
    branch, ref = "plotroom/github/%2Egithub/pr-1", "refs/plotroom-pr/github/%2Egithub/pr-1"
    r = s.opened(s.open("github/.github", 1, root))
    s.eq("created", True, r.get("created"))
    s.eq("branch", branch, r.get("branch"))
    s.eq("ref", ref, r.get("ref"))
    s.eq("head", sha, r.get("head"))
    s.same_path("path", wt, r.get("path"))
    s.eq("worktree directory exists", True, wt.is_dir())
    s.eq("git check-ref-format --branch", 0, s.git(root, "check-ref-format", "--branch", branch).returncode)
    s.eq("git check-ref-format (ref)", 0, s.git(root, "check-ref-format", ref).returncode)
    s.eq(ref, sha, s.out(root, "rev-parse", "--verify", ref))
    s.eq("refs/heads/" + branch, sha, s.out(root, "rev-parse", "--verify", "refs/heads/" + branch))


def sc_recovery(s: Smoke) -> None:
    root, wt = s.checkout("r"), s.wt("o/r", 9)
    listed = s.out(root, "worktree", "list", "--porcelain")
    s.refused(s.open("o/r", 9, root))
    s.eq("(a) worktree directory for pr-9 exists", False, wt.exists())
    s.eq("(a) refs/plotroom-pr/o/r/pr-9 exists", False, s.git(root, "rev-parse", "--verify", "--quiet", "refs/plotroom-pr/o/r/pr-9").returncode == 0)
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
    blocker.unlink()
    r = s.opened(s.open("p/q", 1, q))
    s.eq("(b, retry) created", True, r.get("created"))
    s.eq("(b, retry) worktree directory exists", True, qwt.is_dir())


def sc_issue(s: Smoke) -> None:
    """An issue's worktree is a new branch at the remote's default branch, no upstream configured; opened again it is reused."""
    root, wt, branch = s.checkout("r"), s.issue_wt("o/r", "7"), "7-smoke-issue"
    base = s.out(s.repos["o/r"]["bare"], "rev-parse", "HEAD")  # type: ignore[arg-type]
    r = s.opened(s.open_issue("o/r", "7", branch, root))
    s.eq("created", True, r.get("created"))
    s.eq("head", base, r.get("head"))
    s.eq("branch", branch, r.get("branch"))
    s.eq("key", "7", r.get("key"))
    s.eq("dirty", False, r.get("dirty"))
    s.same_path("path", wt, r.get("path"))
    s.same_path("root", root, r.get("root"))
    s.eq("worktree directory exists", True, wt.is_dir())
    s.eq("git rev-parse --show-toplevel in the worktree", os.path.realpath(str(wt)), os.path.realpath(s.out(wt, "rev-parse", "--show-toplevel")))
    s.eq("git branch --show-current in the worktree", branch, s.out(wt, "branch", "--show-current"))
    s.eq("refs/heads/" + branch, base, s.out(root, "rev-parse", "--verify", "refs/heads/" + branch))
    s.eq("refs/plotroom-base/o/r", base, s.out(root, "rev-parse", "--verify", "refs/plotroom-base/o/r"))
    s.eq("git config branch.%s.merge exit status (no upstream)" % branch, 1, s.git(root, "config", "branch.%s.merge" % branch).returncode)
    s.contains("describe", branch, s.last.get("describe"))  # type: ignore[union-attr]
    cleanup = s.last.get("cleanup")  # type: ignore[union-attr]
    s.eq("cleanup command count", 2, len(cleanup) if isinstance(cleanup, list) else cleanup)
    again = s.opened(s.open_issue("o/r", "7", branch, root))
    s.eq("created (second open)", False, again.get("created"))
    s.eq("head (second open)", base, again.get("head"))
    s.eq("worktree HEAD untouched", base, s.out(wt, "rev-parse", "HEAD"))


def sc_jira_issue(s: Smoke) -> None:
    """A Jira issue's worktree: the directory keeps the key's case, the base comes from the checkout's first remote; opened again it is reused."""
    root, wt, branch = s.checkout("r"), s.tmp / "omp-wt" / "plotroom-jira.abc-issue-ABC-7", "ABC-7-smoke"
    base = s.out(s.repos["o/r"]["bare"], "rev-parse", "HEAD")  # type: ignore[arg-type]
    r = s.opened(s.open_issue("ABC", "ABC-7", branch, root))
    s.eq("created", True, r.get("created"))
    s.eq("head", base, r.get("head"))
    s.same_path("path", wt, r.get("path"))
    s.eq("git branch --show-current in the worktree", branch, s.out(wt, "branch", "--show-current"))
    s.eq("refs/plotroom-base/jira/abc", base, s.out(root, "rev-parse", "--verify", "refs/plotroom-base/jira/abc"))
    again = s.opened(s.open_issue("ABC", "ABC-7", branch, root))
    s.eq("created (second open)", False, again.get("created"))


def sc_remote_host(s: Smoke) -> None:
    """A Plotroom block on another host (an attached loopback daemon) gets its worktree from its own host half, run
    where the block runs: the window half only asks, then opens the PR's tab on that host."""
    root, wt, sha = s.checkout("remote"), s.wt("o/remote", 1), s.shas[("o/remote", 1)]
    stamp = "2026-01-01T00:00:00Z"
    pr = {"number": 1, "title": "Remote PR 1", "url": "https://github.com/o/remote/pull/1", "author": "octo", "state": "OPEN",
          "isDraft": False, "updatedAt": stamp, "createdAt": stamp, "head": "feature-1", "base": "main", "additions": 1,
          "deletions": 0, "changedFiles": 1, "comments": 0, "labels": [], "runs": [], "runTotal": 0}
    (s.smoke / "search.json").write_text(json.dumps([pr]), encoding="utf-8")
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
    s.ctl_ok("plugins", "run", "plugin.plotroom.worktree-selected")
    s.wait_text("the worktree toast", "Worktree ready for o/remote#1")
    st = s.state()
    s.eq("current host", "devbox", st["hosts"]["current"])  # type: ignore[index]
    s.eq("worktree HEAD", sha, s.out(wt, "rev-parse", "HEAD"))
    s.eq("the PR's tab", True, any(t.get("title") == "PR #1 · remote" for t in st["tabs"]))  # type: ignore[union-attr,attr-defined]
    s.eq("its pane is in the worktree", os.path.realpath(str(wt)), os.path.realpath(str(st["focused"].get("cwd") or "")))  # type: ignore[union-attr]


SCENARIOS = [
    ("create", sc_create),
    ("reuse", sc_reuse),
    ("dirty reuse", sc_dirty_reuse),
    ("advanced PR head", sc_advanced),
    ("post-checkout hook", sc_hook),
    ("branch elsewhere", sc_branch_elsewhere),
    (".github", sc_dot_github),
    ("recovery", sc_recovery),
    ("issue worktree", sc_issue),
    ("jira issue worktree", sc_jira_issue),
    ("remote host", sc_remote_host),
]


def check_smoke() -> str:
    tern, git, omp = smoke_prerequisites()
    started = time.monotonic()
    tmp = Path(tempfile.mkdtemp(prefix="plotroom-smoke-", dir="/tmp" if os.path.isdir("/tmp") else None)).resolve()
    s = Smoke(tern, git, omp, tmp)
    try:
        s.repo("o", "r", "r", (1, 2, 3))
        s.repo("github", ".github", "dotgithub", (1,))
        s.repo("p", "q", "q", (1,))
        s.repo("o", "remote", "remote", (1,))
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
