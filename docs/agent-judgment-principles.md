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
- A reference proves current use only when its source is outside the candidate, still current, and points back to the candidate. Internal refs, manifests, indexes, blob links, aliases, and `current` pointers establish internal structure, not an external consumer.

Burrow verifies a claimed current consumer as a typed relationship, not prose:

- `sourcePath` must resolve to an existing independent object outside the candidate;
- `targetPath` must resolve to the candidate or one of its descendants;
- `current` must be true;
- `symbolic_link` must actually resolve from source to target, while
  `textual_path` must be a bounded regular file that actually contains the
  declared target path;
- `consumerBasis=external_current` and `decisionBasis=current_consumer` are rejected unless that relationship passes local canonical-path validation.

## 5. Verdict contract

### Delete

Recommend `delete` only when:

- direct evidence or verified relationships support removal;
- no unresolved current consumer or irreplaceable value remains;
- the candidate scope is homogeneous enough to act on;
- the consequence and recovery path are understood.

The typed decision basis must be `unused_recoverable`. A result that also
claims an external current consumer, mixed container, incomplete investigation,
user tradeoff, or sensitive/irreplaceable value is contradictory and is rejected.

### Keep

Recommend `keep` when:

- the object is active, current, referenced, sensitive, user-authored, or irreplaceable; or
- the investigation is incomplete or contradictory enough that deletion is not justified.

“Keep” can mean “currently valuable” or “not proven disposable.” The evidence panel should make the distinction clear.

A completed keep uses `current_consumer`, `mixed_container`, or
`sensitive_or_irreplaceable`. An incomplete investigation stays fail-closed but
does not count as a completed Agent plan merely because keeping is safer.

### Human intent required

Use `human_intent_required` only when factual investigation is substantially complete and the remaining decision is a real preference or cost tradeoff, such as whether a known-unused but expensive-to-recover asset is worth retaining.

Do not use this state as a substitute for missing investigation.
Its typed decision basis must be `user_tradeoff`.

## 6. Granularity before recommendation

A recommendation applies only to the object actually investigated.

- Do not delete a heterogeneous parent because some children are disposable.
- Prefer independently judged leaves when children have different owners, lifecycle states, consequences, or evidence.
- If the scanner produced a coarse candidate, the Agent may propose narrower candidates marked **Agent discovered**.
- A heterogeneous parent cannot count as a completed judgment until independently meaningful descendants have their own judgments. Keeping the parent is safe, but it is not evidence that every child remains useful.
- Burrow must reject overlapping execution scopes that could bypass a kept child through a selected parent.

## 7. Recommendation output

Each item-level judgment should answer, in this order:

1. **Judgment:** delete, keep, or human intent required.
2. **Reason:** the semantic conclusion, not a restatement of the path.
3. **Consequence:** what the user gains and what must happen if the content is needed again.
4. **Evidence:** observations, relationships, inferences, and gaps, each labeled by basis.
5. **Confidence:** calibrated to evidence coverage and contradictions.

The default UI shows the judgment and reason. Evidence and relationships remain attached to that item and expand on demand. Plan-wide totals are always computed by Burrow from typed judgments, never copied from Agent prose.

Large scans may be evaluated in bounded batches to keep structured output complete and reviewable. Batching is a transport boundary, not an evidence boundary: every batch retains the full snapshot and full triage as relationship context, and Burrow rejects the combined result unless each scanner candidate appears exactly once and every discovered child belongs to its batch's assigned parent. Parent/descendant hierarchies remain coherent while unrelated leaves may be packed together for bounded transport.

After the batches merge, a plan-wide consistency pass examines cross-item contradictions using the typed judgment details and relationship evidence. It is a veto gate only: it may reject the merged plan, but it may not invent a recommendation, alter a disposition, or expand the selected deletion set. Transport retries are similarly bounded and semantic: only explicit output-capacity or truncation failures may be split; rate limits, authentication, network, and input-context failures terminate the Agent run fail-closed.

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
- a model cannot pair `external_current`/`current_consumer` with `delete`;
- a cache-internal ref cannot be relabeled as an external current consumer;
- a homogeneous scope cannot claim `mixed_container` to bypass child judgments;
- an incomplete investigation cannot count as a completed keep.

The quality bar is not “the Agent produced an answer.” It is “the answer exposes enough verified reasoning that a user can trust, challenge, or override it without repeating the investigation.”

Candidate-level fail-closed behavior keeps that quality bar usable at scan scale. If one unlocked candidate has a missing, contradictory, inference-only, or otherwise incomplete judgment, Burrow converts only that candidate to an explicit conservative keep and removes it from the staged deletion set. Verified sibling judgments remain available. This fallback is attributed to Burrow, carries no Agent confidence or investigation claim, and must stay visible in the item UI; it never turns incomplete evidence into a delete recommendation or silently delegates an investigation gap to the user.
