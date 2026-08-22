# Agent Judgment Principles

Burrow's Agent should discover the meaning of cleanup candidates, not classify them by appearance. A path, category, size, age, or familiar product name can tell the Agent where to investigate. It cannot decide the outcome.

This document is the product contract for Agent-generated cleanup advice. It applies to scanner candidates and to additional candidates discovered by an Agent.

## 1. Separate facts, judgment, safety, and intent

Four actors have different authority:

1. **Scanner: facts and candidates.** It reports paths, measurements, coarse categories, and deterministic locks. It does not understand whether an object still matters to the user.
2. **Agent: semantic investigation.** It establishes ownership, consumers, lifecycle state, recoverability, and consequence, then proposes a judgment.
3. **Burrow: deterministic safety.** It validates scope, identity, containment, symlinks, active use, changes since review, and the exact result at execution time. It never trusts Agent prose as deletion authority.
4. **User: genuine value tradeoffs.** The user decides only when the relevant facts are known and the remaining question is preference, cost, or future intent.

Unknown facts are not “user intent.” If the Agent can investigate a question, the Agent should investigate it. If it cannot, the default is keep and the missing check must be visible.

## 2. Investigate the object, not the label

For each candidate, the Agent builds the smallest useful object model:

- **Scope and granularity:** Is this one homogeneous object, or a parent containing independently meaningful children?
- **Identity and ownership:** What created it? Which installed app, project, account, package, or workflow owns it? Does that owner still exist?
- **Consumers and references:** Is it referenced by a running process, current configuration, manifest, alias, package record, version pointer, or recent workflow?
- **Lifecycle:** Is it current, duplicated, superseded, orphaned, incomplete, generated, cached, archival, or user-authored?
- **Recovery:** Is it recreated automatically, rebuilt locally, downloaded again, restored from a trusted source, or impossible to recover? What time, bandwidth, and workflow cost does recovery impose?
- **Sensitivity:** Could it contain credentials, settings, source material, recordings, messages, licensed assets, or other user value?
- **Contradictions and gaps:** Which signals disagree? Which relevant checks could not be completed?

Investigation should follow relationships. For example, a candidate may lead to an installed bundle, which leads to a configuration reference, which leads to the currently selected version. That relationship is more meaningful than any token in the original path.

## 3. Depth is driven by impact, not content type

The Agent spends more effort when a wrong decision would cost more. Deepening triggers include:

- heterogeneous or overly broad scope;
- ambiguous or multiple possible owners;
- expensive or uncertain recovery;
- sensitive or user-authored content risk;
- contradictory usage signals;
- a large effect on disk space or workflow;
- evidence that the scanner missed related leaves or versions.

These triggers change the investigation budget, never the verdict. There is no universal size threshold, age threshold, directory-name rule, product allowlist, or content-type rule that means delete or keep.

## 4. Evidence has an epistemic type

Every evidence item declares how it is known:

- **Observation:** directly inspected filesystem, process, package, configuration, or application metadata.
- **Relationship:** ownership, consumer, reference, version, duplicate, or replacement relationship established from inspected facts.
- **Inference:** hypothesis from naming, location, size, age, or convention. It guides the next check but cannot independently support deletion.
- **Gap:** a relevant check that could not be completed.

Evidence requirements:

- Never claim a check that was not performed.
- Distinguish “not found” from “does not exist.”
- Absence of recent access is weak evidence because many applications do not update timestamps reliably.
- Confidence summarizes evidence quality; it never replaces evidence.
- A delete recommendation requires at least one observation or verified relationship.

## 5. Verdict contract

### Delete

Recommend `delete` only when:

- direct evidence or verified relationships support removal;
- no unresolved current consumer or irreplaceable value remains;
- the candidate scope is homogeneous enough to act on;
- the consequence and recovery path are understood.

### Keep

Recommend `keep` when:

- the object is active, current, referenced, sensitive, user-authored, or irreplaceable; or
- the investigation is incomplete or contradictory enough that deletion is not justified.

“Keep” can mean “currently valuable” or “not proven disposable.” The evidence panel should make the distinction clear.

### Human intent required

Use `human_intent_required` only when factual investigation is substantially complete and the remaining decision is a real preference or cost tradeoff, such as whether a known-unused but expensive-to-recover asset is worth retaining.

Do not use this state as a substitute for missing investigation.

## 6. Granularity before recommendation

A recommendation applies only to the object actually investigated.

- Do not delete a heterogeneous parent because some children are disposable.
- Prefer independently judged leaves when children have different owners, lifecycle states, consequences, or evidence.
- If the scanner produced a coarse candidate, the Agent may propose narrower candidates marked **Agent discovered**.
- Burrow must reject overlapping execution scopes that could bypass a kept child through a selected parent.

## 7. Recommendation output

Each item-level judgment should answer, in this order:

1. **Judgment:** delete, keep, or human intent required.
2. **Reason:** the semantic conclusion, not a restatement of the path.
3. **Consequence:** what the user gains and what must happen if the content is needed again.
4. **Evidence:** observations, relationships, inferences, and gaps, each labeled by basis.
5. **Confidence:** calibrated to evidence coverage and contradictions.

The default UI shows the judgment and reason. Evidence and relationships remain attached to that item and expand on demand. Plan-wide totals are always computed by Burrow from typed judgments, never copied from Agent prose.

## 8. User corrections are context, not global rules

When a user changes an Agent recommendation, Burrow preserves that choice for the current plan. A future preference system may remember the correction with its scope and rationale.

A correction must not silently become a universal product rule. “Delete this unused asset” does not mean all assets of the same type, size, vendor, or location are disposable.

## 9. Execution remains deterministic

Agent advice never authorizes deletion by itself. At the final action boundary Burrow must still:

- verify the selected candidate identity and containment;
- verify that the candidate and descendants have not changed since review;
- skip candidates used by an active application;
- reject unsafe parent/child overlap;
- report the exact paths cleaned and skipped;
- fail closed when the execution boundary cannot be verified.

This separation lets the Agent reason deeply without turning probabilistic judgment into filesystem authority.

## 10. Evaluation scenarios

Tests and review fixtures should cover behaviors, not brands:

- identical-looking candidates with different verified consumers receive different judgments;
- a large recoverable object and a small irreplaceable object are not judged by size;
- an orphaned older version is distinguished from the active version through references;
- a heterogeneous parent is split into independently judged children;
- filename-only inference cannot produce an executable delete recommendation;
- an unavailable ownership or consumer check becomes a visible gap and a keep judgment;
- a fully investigated preference tradeoff becomes human intent required;
- a user override affects only the explicitly changed candidate;
- a changed or newly active candidate is skipped at execution time.

The quality bar is not “the Agent produced an answer.” It is “the answer exposes enough verified reasoning that a user can trust, challenge, or override it without repeating the investigation.”
