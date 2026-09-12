# AGENTS.md — CDT-SketchUp

`CDT-SketchUp` is a domain-neutral **Generic CAD Primitive / Execution Engine** for SketchUp.

Internal development instructions are maintained locally in `_private/AGENTS.md` and are intentionally not published. If that file exists in the working copy, read it before substantial development work.

Public architectural invariant:

- provider runtime owns generic SketchUp/CAD execution mechanics only;
- architecture/structure/MEP/mechanical/interior/infrastructure business logic belongs to external Domain Agents;
- TCVN/QCVN/compliance and discipline Audit Report logic must not be added to this provider;
- no arbitrary Ruby/script execution surface;
- capability claims must match measured native behavior.

Public product architecture and security documentation are in `docs/ARCHITECTURE.md` and `docs/SECURITY.md`.

Public/private boundary:

- public (Git) keeps product-facing contracts/guides only — what an integrator needs to USE the provider;
- research, development plans, roadmaps, internal direction, session handoffs and evidence transcripts live in `_private/` (gitignored, never committed).
