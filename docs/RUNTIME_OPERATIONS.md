# Runtime operation

The default `cdt-sketchup` connects to the local Ruby bridge. For split-host operation, keep both native listeners on loopback and forward the agent through verified SSH. The agent attaches to SketchUp; opening a model remains an operator action.

## Workstation

Install the platform lock and the same provider wheel on both hosts. Install/hash-check the matching Ruby extension, then open the intended model explicitly. Start the agent in the interactive CAD user's session:

```powershell
cdt-sketchup-agent --port 9857 --token-file <existing-credential> --stop-file <owned-stop-marker> --metadata-file <owned-agent-metadata>
```

The existing credential is read without provisioning or logging. The metadata contains only PID, generation and port. A stop marker requests graceful agent shutdown; it never closes SketchUp. Remove that marker explicitly before the next start.

## Provider

Forward a gateway loopback port to the workstation agent through SSH with host-key checking. Set:

| Variable | Value |
|---|---|
| CDT_SKETCHUP_RUNTIME_ENDPOINT | Forwarded loopback HTTP URL |
| CDT_SKETCHUP_RUNTIME_TOKEN_FILE | Existing private credential reference |
| CDT_SKETCHUP_RUNTIME_STATE_FILE | Durable, provider-owned binding JSON |
| CDT_SKETCHUP_MCP_TRANSPORT | `streamable-http` (default) or `stdio` |

All three runtime variables are required together. The binding must exist before provider start:

```text
cdt-sketchup-runtime bind --state-file <binding> --endpoint <loopback-url> --token-file <credential> --generation <observed-agent-generation>
```

This explicit operator command verifies heartbeat, native ping and document readback. Stop the provider before binding/recovery; an exclusive OS file lock rejects concurrent ownership. Run only one configured provider against the native session.

## Recovery

Generation changes never silently rebind. Writes persist a pending marker before dispatch; lost completion or provider cancellation blocks later writes across provider restart. Reads remain available on the pinned generation. A changed agent generation requires explicit selection again.

Use `cdt-sketchup-runtime inspect --state-file <binding>` while the provider is stopped. For a pending strict operation, `recover` accepts the same arguments as `bind` and queries the native journal without replay. It clears the fence only for a committed or independently verified rolled-back receipt with the exact pending mutation ID and request hash. Journal miss/expiry, model changes or incomplete proof keep the fence. Pending external file/application effects require manual native review; this command cannot clear them. Preserve the binding and evidence rather than deleting uncertain state.

After a SketchUp restart, its in-memory journal is lost. Public `reconcile_operation` can compare independently retained before/post-state evidence, but an operator must resolve the durable pending state before resuming writes. Never retry a mutation merely because its response was lost.
