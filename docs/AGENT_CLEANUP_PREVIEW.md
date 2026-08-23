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

- Codex receives candidate paths, sizes, scanner categories, deterministic
  depth requirements, and active-lock context only after the
  user accepts the in-product disclosure.
- Codex runs as an ephemeral, read-only analysis process. It receives no Burrow
  cleanup capability and cannot authorize or perform deletion.
- Agent output is a typed proposal. Burrow owns the canonical plan and applies
  deterministic safety locks before changing any checkbox.
- A user edit always wins over late or retried Agent output.
- Partial, duplicate, unknown, or schema-invalid Agent output disables the
  Agent shortcut and leaves the deterministic scanner result available.
- Agent analysis runs as triage followed by deep review. Burrow forces high-
  impact, sensitive, locked, and heterogeneous candidates into deep review
  even if the Agent's triage omits them.
- Final recommendations are produced in bounded batches while each batch can
  still inspect the full snapshot for cross-item relationships. Burrow accepts
  a batch only when it returns exactly every assigned scanner candidate once;
  a missing, duplicate, or foreign judgment fails the whole Agent plan closed.
  Up to three read-only batches run concurrently, and oversized parent/child
  hierarchies are partitioned without assigning any candidate twice.
- The merged result passes a final plan-wide consistency review before Burrow
  applies local policy. That gate can reject contradictory judgments but cannot
  create recommendations, change dispositions, or authorize deletion.
- Adaptive retry is limited to explicit output-capacity or truncation failures.
  Rate limits, authentication, network errors, and input-context failures stop
  the run instead of multiplying calls. The UI reports completed candidate
  counts and the final validation phase; a 20-minute fail-safe leaves the
  cleanup selection unchanged.
- A delete or human-intent judgment is rejected while any required scope,
  ownership, consumer, lifecycle, recovery, or sensitivity check is unknown.
- Burrow cross-validates typed scope, consumer, decision, and disposition
  fields. A claimed current consumer must include an existing canonical source
  outside the candidate and a target inside it; internal cache refs cannot
  prove current use. Contradictory combinations fail closed rather than being
  repaired from Agent prose.
- Agent-discovered candidates are limited to strict descendants of a scanner
  candidate whose original pinned identity and subtree are still unchanged.
  Refused, locked, replaced, or changed parents cannot authorize discovery.
  Burrow canonicalizes and measures accepted children under one bounded,
  cancellable budget, then rebuilds the cleanup list, active locks, selection,
  and snapshot atomically before they can be selected.
- If the user changes the staged selection while Agent analysis is running,
  any later-discovered child starts unselected and is recorded as a manual
  override. Late analysis can explain a new item but cannot silently grow the
  user's cleanup plan.
- Final execution uses the snapshot owned by the visible plan, including any
  validated Agent-discovered leaves, with the existing identity, boundary, and
  confirmation protections.

## Requirements

- macOS 14 or later.
- A locally installed and authenticated Codex CLI for Agent analysis.
- Full Disk Access remains a Burrow permission, not an Agent permission.

## Deliberately deferred

This is the first end-to-end Agent-native slice, not the complete platform.
Generic MCP/Agent adapters, discovery outside an existing scanner candidate,
and a durable cross-restart decision journal remain follow-up work. The current
build fails safely to scanner-only review when Codex is absent or unavailable.

## Distribution note

The upstream engine submodule is not publicly accessible. This personal preview
bundles the complete universal legacy runtime — both `Resources/burrow` and its
required `Resources/engine` tree — from the official Burrow 0.14.0 release ZIP,
plus the `fclones` sidecar. The complete app is then re-signed and notarized as
one distribution. A conductor without its sibling engine is rejected at build time.

## Original app icon

The Burrow caretaker monkey is original generated artwork selected through a
multi-round mascot exploration. Its small teal cleaning brush communicates the
cleanup role while the character remains the primary identity. The production
asset preserves the selected warm-white scene inside a macOS rounded-square
mask so fur and tail edges stay clean on both light and dark desktops.

No third-party image asset is included in this repository or build.

Style prompt source:
https://gist.github.com/tanishqsh/ad7ef969cef9d7f3a5a688de49354084
