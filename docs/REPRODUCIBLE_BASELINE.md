# Reproducible environment and maintenance

## Canonical environment

The reproducible development and CI baseline uses CPython 3.12 and pip 26.1.2.
The package minimum remains Python 3.10; the platform locks certify the tested
3.12 environment and do not imply that every supported Python version was tested.

| Platform | Lock | Measured Python |
| --- | --- | --- |
| Linux x86_64 | `pylock.linux.toml` | 3.12.3 |
| Windows AMD64 | `pylock.windows.toml` | 3.12.0 |

Both PEP 751 locks include runtime, test and build dependencies with exact versions,
artifact URLs and hashes. They resolve MCP 2.2.0 and uvicorn 0.54.0. Linux contains
37 packages and Windows 39, including platform-specific dependencies.

Create and activate a fresh Python 3.12 virtual environment. From the repository,
select the lock for the current platform:

```bash
python -m pip install pip==26.1.2
python -m pip install -r pylock.linux.toml
python -m pip install --no-deps --no-build-isolation .
python -m pip check
python -m pytest tests -q
```

On Windows, use `pylock.windows.toml` in the second command. Install the Ruby
extension separately through SketchUp Extension Manager or the source-checkout
maintenance command. Start SketchUp with an open model before running live checks.

## Lock updates

Run `python scripts/lock_environment.py` on each target platform using Python 3.12
and pip 26.1.2. The generator reads runtime, dev and build requirements from
`pyproject.toml`. Review the changed artifacts and rerun the tests before accepting
an update. Installing a committed lock does not resolve newer package versions.

CI installs the corresponding lock, installs the provider without dependency
resolution or build isolation, checks dependency consistency and runs the suite.
Its release manifest binds the lock, installed dependency list and RBZ to the
commit/tree and observed runtime. A workflow configuration alone does not certify
that a particular commit has completed remote CI.

## Doctor

```bash
cdt-sketchup-doctor doctor --live
cdt-sketchup-doctor support-bundle
```

Doctor checks the declared MCP/uvicorn version ranges. When run from a source
checkout, installed-extension verification compares the loader and every Ruby
module by SHA-256 and rejects missing, changed or unexpected Ruby modules.
A wheel-only installation without the extension sources reports that comparison
as unavailable; it does not establish source equality. Live mode also verifies
the bridge handshake against SketchUp 2024 24.0.594 / Ruby 3.2.2.

Support bundles omit credentials. Keep bridge and MCP tokens outside the repository.

## Packaging and measured acceptance

RBZ packaging fixes timestamps, permissions and ZIP creator metadata. On the
tested Linux/Windows baseline, identical extension bytes produce the same archive:
`d36cd44b496802ad754816e72a32b9067e9f14d5575c8ec8d466b9796715abdc`.
The provider wheel and RBZ are separate artifacts; wheel byte reproducibility is
not asserted.

The 2026-09-30 acceptance source is `69a0aaaf85e591d314046574347899c11e813be6`:
Linux 242 passed / 2 skipped, Windows 244 passed, with 5 subtests passed on each.
Windows also passed standalone Ruby journal checks. Installed wheels on both
platforms expose 68 tools and construct the Streamable HTTP application.

Native acceptance on SketchUp 24.0.594 / Ruby 3.2.2 covered targeted mutation
identity (5/5), generic composition (9/9), recovery (9/9), public MCP response loss
and reconciliation (5/5), nested topology (4/4), client saturation (1/1), B4
machine certification, and rooted save/seal/stale/reseal/reopen (9/9).

Spatial classification matched 11/12 ideal analytic labels: the remaining
`5e-8 inch` penetration is below the documented `1e-7 inch` resolution and is
conservatively `touching`, never clear. Benchmark timing is machine-specific.
Client RSS was unavailable; saturation/post-ping checks are responsiveness proxies,
not direct UI frame telemetry.

See [Compatibility](COMPATIBILITY.md), [Security](SECURITY.md) and
[Tool Guide](TOOL_GUIDE.md) for the native bounds and recovery contract.
