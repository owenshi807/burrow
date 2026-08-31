# Burrow Agent Safety Runtime v1

Version: 0.15.0 preview 1
Baseline: `agent-runtime-baseline-2026-08-31`

Burrow is the local maintenance safety runtime. An Agent is a replaceable
reasoning layer: it can investigate meaning and propose a selection, but it
never turns a pathname from prose into deletion authority.

## Contract

1. **Discover:** Burrow's scanner emits measured filesystem candidates.
2. **Interpret:** Burrow adds a model-free typed meaning. Generated caches may
   be recommended; unknown ownership requires review; active, sensitive, and
   user-authored state is protected. Local models are not default cleanup.
3. **Reason:** an Agent may add evidence and narrower candidates. Its output is
   a proposal against the plan revision, not a filesystem command.
4. **Stage:** `burrow_stage_cleanup_plan` freezes candidate IDs, identities,
   dispositions, recovery cost, and evidence.
5. **Approve:** the Agent or user selects only IDs from that immutable plan.
6. **Execute:** `burrow_execute_cleanup_plan` consumes the exact plan ID,
   revision, and candidate IDs. MCP execution is limited to Burrow's
   deterministic `recommend_cleanup` subset.
7. **Revalidate:** Burrow repeats containment, identity, subtree-change, and
   active-use checks at the action boundary. Drift removes an item from the
   executable subset; elapsed minutes alone do not expire a plan.
8. **Recover and account:** v1 moves MCP items to Trash. Every GUI and MCP clean
   writes a durable run receipt with initiator, plan, mode, per-item policy,
   selection, action, outcome, skip reason, and Trash destination.

## MCP flow

```text
burrow_stage_cleanup_plan
  -> inspect candidates[].meaning
  -> obtain user approval for candidate IDs
  -> burrow_execute_cleanup_plan(plan_id, revision, candidate_ids, confirm=true)
  -> burrow_cleanup_runs(run_id)
```

`burrow_clean` remains a compatibility preview. Broad `confirm:true` execution
is refused because it cannot prove that approval and execution refer to the
same filesystem set.

## Persistence

- Staged plans: `~/Library/Application Support/Burrow/CleanupPlans/`
- Cleanup receipts: `~/Library/Application Support/Burrow/CleanupRuns/`
- Maximum retained unified receipts: 500

These records contain local paths and stay on the Mac. They are not model
context unless the user or Agent explicitly reads a receipt through MCP.

## Deliberate limits in v1

- MCP cleanup is Trash-only and does not empty Trash.
- Unknown/review candidates must be handled in Burrow's UI; an Agent cannot
  escalate its own uncertain judgment into MCP deletion.
- Legacy engine-managed cleans get a run-level receipt while the engine's
  existing history/deletion logs remain the source of exact legacy paths.
- Cleanup plan sharing between the native review UI and external MCP clients is
  the next consolidation step; both already use the same safety primitives and
  receipt format.
