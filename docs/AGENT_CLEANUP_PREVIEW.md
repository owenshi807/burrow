# Burrow Agent Cleanup Preview

Build date: 2026-08-21
Branch: `feat/agent-cleanup-plan`

## Product memory

This build turns the cleanup review into one shared decision surface. It does
not add a separate AI tab. Scanner facts, Agent judgments, user overrides, and
the final cleanup selection are projections of one revisioned plan.

The review is organized by Agent disposition first — **Suggested cleanup**,
**Suggested keep**, and **Needs your intent** — with the original scanner
categories nested inside. Each candidate carries its own judgment. The right
inspector shows the conclusion and consequence first; evidence and relationship
details stay collapsed until requested.

## Authority contract

- Codex receives candidate paths, sizes, and scanner categories only after the
  user accepts the in-product disclosure.
- Codex runs as an ephemeral, read-only analysis process. It receives no Burrow
  cleanup capability and cannot authorize or perform deletion.
- Agent output is a typed proposal. Burrow owns the canonical plan and applies
  deterministic safety locks before changing any checkbox.
- A user edit always wins over late or retried Agent output.
- Partial, duplicate, unknown, or schema-invalid Agent output disables the
  Agent shortcut and leaves the deterministic scanner result available.
- Final execution still uses Burrow's existing snapshot, identity, expiry, and
  confirmation protections.

## Requirements

- macOS 14 or later.
- A locally installed and authenticated Codex CLI for Agent analysis.
- Full Disk Access remains a Burrow permission, not an Agent permission.

## Deliberately deferred

This is the first end-to-end Agent-native slice, not the complete platform.
Generic MCP/Agent adapters, Agent-discovered candidates outside the scanner,
and a durable cross-restart decision journal remain follow-up work. The current
build fails safely to scanner-only review when Codex is absent or unavailable.

## Distribution note

The upstream engine submodule is not publicly accessible. This personal preview
bundles the universal `burrow` engine and `fclones` sidecar from the installed
Burrow 0.14.0 (build 26), which exactly matches this fork's upstream baseline;
the complete app is then re-signed and notarized as one distribution.

## Original app icon

The Burrow caretaker monkey is original generated artwork selected through a
multi-round mascot exploration. Its small teal cleaning brush communicates the
cleanup role while the character remains the primary identity. The production
asset preserves the selected warm-white scene inside a macOS rounded-square
mask so fur and tail edges stay clean on both light and dark desktops.

No third-party image asset is included in this repository or build.

Style prompt source:
https://gist.github.com/tanishqsh/ad7ef969cef9d7f3a5a688de49354084
