"""Doctor & Maintenance CLI — install, verify and repair the provider and bridge.

Wing: code | Topic: sketchup_product | Updated: 2026-09-12
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import platform
import shutil
import socket
import sys
from dataclasses import dataclass
from pathlib import Path

try:
    from .contract import CONTRACT_VERSION, PROVIDER_VERSION
except ImportError:  # pragma: no cover - direct script use
    from cdt_sketchup.contract import CONTRACT_VERSION, PROVIDER_VERSION

BRIDGE_PORT = 9876
MCP_PORT = 8765
MEASURED_SKETCHUP_VERSION = "24.0.594"
MEASURED_RUBY_VERSION = "3.2.2"


@dataclass
class Check:
    """One doctor check outcome without secret material."""

    name: str
    passed: bool
    detail: str


def repo_root() -> Path | None:
    """Locate the source tree; None for site-packages installs without sources."""
    here = Path(__file__).resolve()
    for candidate in (here, *here.parents):
        if (candidate / "extension" / "cdt_sketchup" / "main.rb").is_file():
            return candidate
    return None


def plugins_dir() -> Path:
    """SketchUp Plugins directory, overridable for tests and advanced setups."""
    override = os.environ.get("CDT_SKETCHUP_PLUGINS_DIR", "")
    if override.strip():
        return Path(override).expanduser()
    if sys.platform == "win32":
        appdata = os.environ.get("APPDATA", "")
        if appdata.strip():
            return Path(appdata) / "SketchUp" / "SketchUp 2024" / "SketchUp" / "Plugins"
    return Path.home() / ".sketchup" / "Plugins"


def bridge_token_file() -> Path:
    """Bridge credential path using the same rule as the Ruby extension."""
    configured = os.environ.get("CDT_SKETCHUP_BRIDGE_TOKEN_FILE", "")
    if configured.strip():
        return Path(configured).expanduser()
    local_app_data = os.environ.get("LOCALAPPDATA", "")
    if local_app_data.strip():
        return Path(local_app_data) / "CDT-SketchUp" / "bridge.token"
    return Path.home() / ".cdt-sketchup" / "bridge.token"


def file_sha256(path: Path) -> str:
    """SHA-256 hex digest of a file."""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def port_listening(port: int) -> bool:
    """True when something accepts loopback TCP on the port."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.settimeout(0.3)
        return sock.connect_ex(("127.0.0.1", port)) == 0


def mask_home(value: str) -> str:
    """Replace the user home prefix so bundles never leak usernames."""
    home = str(Path.home())
    return value.replace(home, "~") if home and value.startswith(home) else value


def check_python() -> Check:
    """Python version and mandatory dependencies."""
    if sys.version_info < (3, 10):
        return Check("python", False, f"requires >=3.10, found {platform.python_version()}")
    try:
        import mcp  # noqa: F401
    except ImportError:
        return Check("python", False, "mcp package is not installed")
    try:
        import uvicorn  # noqa: F401
    except ImportError:
        return Check("python", False, "uvicorn package is not installed")
    return Check("python", True, f"{platform.python_version()} with mcp+uvicorn")


def check_extension_sources() -> Check:
    """Extension source tree presence and module count."""
    root = repo_root()
    if root is None:
        return Check("extension-sources", False, "source tree unavailable (binary install)")
    modules = sorted((root / "extension").rglob("*.rb"))
    main = root / "extension" / "cdt_sketchup" / "main.rb"
    if not main.is_file():
        return Check("extension-sources", False, "main.rb entry point is missing")
    if len(main.read_text(encoding="utf-8").splitlines()) >= 300:
        return Check("extension-sources", False, "main.rb entry point exceeds 300 lines")
    return Check("extension-sources", True, f"{len(modules)} Ruby modules")


def check_extension_installed() -> Check:
    """Installed extension matches the repository sources by content hash."""
    root = repo_root()
    target = plugins_dir() / "cdt_sketchup" / "main.rb"
    if not target.is_file():
        return Check("extension-installed", False, f"not installed at {mask_home(str(target))}")
    if root is None:
        return Check("extension-installed", True, "installed (source tree unavailable for comparison)")
    try:
        same = file_sha256(target) == file_sha256(root / "extension" / "cdt_sketchup" / "main.rb")
    except OSError as exc:
        return Check("extension-installed", False, f"unreadable: {exc}")
    if not same:
        return Check("extension-installed", False, "installed main.rb differs from repository")
    return Check("extension-installed", True, "installed files match repository")


def check_bridge_token() -> Check:
    """Bridge credential exists without ever exposing its content."""
    path = bridge_token_file()
    if not path.is_file():
        return Check("bridge-token", False, f"missing at {mask_home(str(path))} (created on bridge start)")
    return Check("bridge-token", True, f"present at {mask_home(str(path))}")


def check_ports() -> Check:
    """Loopback ports for bridge and provider."""
    bridge = port_listening(BRIDGE_PORT)
    provider = port_listening(MCP_PORT)
    if bridge:
        return Check("ports", True, f"bridge :{BRIDGE_PORT} listening, provider :{MCP_PORT} {'up' if provider else 'down'}")
    return Check("ports", False, f"bridge :{BRIDGE_PORT} is not listening (start SketchUp first)")


def bridge_probe() -> dict:
    """Live bridge probe; raises on transport failure."""
    from .bridge import BridgeClient

    async def _probe() -> dict:
        return await BridgeClient().probe()

    return asyncio.run(_probe())


def check_handshake() -> Check:
    """Provider/extension handshake against the measured runtime matrix."""
    try:
        probe = bridge_probe()
    except Exception as exc:
        return Check("handshake", False, f"bridge unreachable: {type(exc).__name__}")
    if not probe.get("bridge_connected") or not probe.get("live_model"):
        return Check("handshake", False, f"bridge degraded: {probe.get('detail')}")
    runtime = probe.get("runtime") or {}
    sketchup = runtime.get("sketchup_version", "?")
    ruby = runtime.get("ruby_version", "?")
    if sketchup != MEASURED_SKETCHUP_VERSION or ruby != MEASURED_RUBY_VERSION:
        return Check(
            "handshake",
            False,
            f"unmeasured runtime SketchUp {sketchup} / Ruby {ruby} "
            f"(measured {MEASURED_SKETCHUP_VERSION}/{MEASURED_RUBY_VERSION})",
        )
    return Check("handshake", True, f"SketchUp {sketchup} / Ruby {ruby}")


def run_doctor(live: bool = False) -> tuple[list[Check], int]:
    """Run all checks; exit code 0 only when every check passes."""
    checks = [
        check_python(),
        check_extension_sources(),
        check_extension_installed(),
        check_bridge_token(),
        check_ports(),
    ]
    if live:
        checks.append(check_handshake())
    code = 0 if all(check.passed for check in checks) else 1
    return checks, code


def install_extension() -> int:
    """Copy the repository extension tree into the SketchUp Plugins directory."""
    root = repo_root()
    if root is None:
        print("install-extension: source tree unavailable")
        return 1
    source = root / "extension" / "cdt_sketchup"
    target = plugins_dir() / "cdt_sketchup"
    loader_source = root / "extension" / "cdt_sketchup.rb"
    loader_target = plugins_dir() / "cdt_sketchup.rb"
    try:
        if target.is_dir():
            shutil.rmtree(target)
        shutil.copytree(source, target)
        shutil.copyfile(loader_source, loader_target)
    except OSError as exc:
        print(f"install-extension: failed: {exc}")
        return 1
    print(f"install-extension: installed to {mask_home(str(target))}")
    return 0


def uninstall_extension() -> int:
    """Remove the installed extension without touching anything else."""
    target = plugins_dir() / "cdt_sketchup"
    loader_target = plugins_dir() / "cdt_sketchup.rb"
    try:
        if target.is_dir():
            shutil.rmtree(target)
        if loader_target.is_file() and loader_target.read_text(encoding="utf-8").find("CDTSketchUp") >= 0:
            loader_target.unlink()
    except OSError as exc:
        print(f"uninstall-extension: failed: {exc}")
        return 1
    print("uninstall-extension: removed")
    return 0


def repair_token() -> int:
    """Delete the bridge credential so the next bridge start regenerates it."""
    path = bridge_token_file()
    try:
        if path.is_file():
            path.unlink()
    except OSError as exc:
        print(f"repair-token: failed: {exc}")
        return 1
    print(f"repair-token: cleared {mask_home(str(path))}; restart the bridge to regenerate")
    return 0


def support_bundle() -> dict:
    """Sanitized diagnostics bundle; never includes secrets or token material."""
    try:
        from importlib.metadata import version

        mcp_version = version("mcp")
    except Exception:
        mcp_version = "unknown"
    bundle = {
        "provider": "CDT-SketchUp",
        "provider_version": PROVIDER_VERSION,
        "contract_version": CONTRACT_VERSION,
        "platform": platform.platform(),
        "python": platform.python_version(),
        "mcp": mcp_version,
        "plugins_dir": mask_home(str(plugins_dir())),
        "token_present": bridge_token_file().is_file(),
        "bridge_port_listening": port_listening(BRIDGE_PORT),
        "provider_port_listening": port_listening(MCP_PORT),
    }
    try:
        probe = bridge_probe()
        bundle["bridge"] = {
            "connected": bool(probe.get("bridge_connected")),
            "live_model": bool(probe.get("live_model")),
            "runtime": probe.get("runtime") or {},
        }
    except Exception as exc:
        bundle["bridge"] = {"connected": False, "error": type(exc).__name__}
    return bundle


def print_doctor(live: bool = False) -> int:
    """Print human-readable doctor output."""
    checks, code = run_doctor(live=live)
    for check in checks:
        mark = "PASS" if check.passed else "FAIL"
        print(f"[{mark}] {check.name}: {check.detail}")
    return code


def main(argv: list[str] | None = None) -> int:
    """CLI entry point."""
    args = list(sys.argv[1:] if argv is None else argv)
    command = args[0] if args else "doctor"
    if command == "doctor":
        return print_doctor(live="--live" in args)
    if command == "install-extension":
        return install_extension()
    if command == "uninstall-extension":
        return uninstall_extension()
    if command == "repair-token":
        return repair_token()
    if command == "support-bundle":
        payload = support_bundle()
        text = json.dumps(payload, indent=2, sort_keys=True)
        if "--out" in args:
            Path(args[args.index("--out") + 1]).write_text(text, encoding="utf-8")
        else:
            print(text)
        return 0
    print(f"unknown command: {command} (doctor [--live] | install-extension | uninstall-extension | repair-token | support-bundle [--out PATH])")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
