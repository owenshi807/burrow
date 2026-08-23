# 001 — Refine cleanup Agent progress motion

- **Status**: DONE
- **Commit**: f265e82
- **Severity**: MEDIUM
- **Category**: Purpose, easing, accessibility, cohesion
- **Estimated scope**: 2 files, about 100 lines

## Problem

The Cleanup Agent progress card names the current phase, but the active node is
only distinguished by a static tint. The elapsed time, selected counts, and
selected bytes also change without continuity. The current phase therefore
looks paused even while Codex is working.

`macos/Sources/CleanReviewView.swift:157` currently wraps the card in a
one-second `TimelineView`, while `agentPhase` at approximately line 227 renders
the current state as a static capsule:

```swift
.background(Capsule().fill(state == .active ? accent.opacity(0.14) : Color.clear))
```

There is no `accessibilityReduceMotion` branch in this view. Animating the
whole card, disclosure height, or result ordering would be harmful: this screen
previously had placement instability and deliberately uses an eager stack.

## Target

- Add shared SwiftUI motion tokens:
  - state change: `Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)`
  - disclosure cue: `Animation.timingCurve(0.77, 0, 0.175, 1, duration: 0.16)`
  - active pulse: `Animation.easeInOut(duration: 0.7).repeatForever(autoreverses: true)`
- The active phase uses a small progress spinner or pulsing indicator plus a
  subtle capsule border/fill pulse. Done and pending nodes remain static.
- Phase color, icon state, connector fill, and detail text retarget with the
  180 ms state token. Do not animate node geometry.
- Selected counts and byte totals use SwiftUI numeric content transitions on
  event-driven changes only. Do not animate the elapsed timer or snapshot age.
- Reduce Motion disables repeating pulse, numeric movement, and chevron
  rotation. It may retain a 150 ms opacity-only status crossfade.
- Accordion bodies remain non-animated. Only the chevron uses the 160 ms
  disclosure token.

## Repo conventions to follow

- Shared visual tokens live in `macos/Sources/Brand.swift`.
- `macos/Sources/AnalyzeView.swift` already branches on
  `@Environment(\.accessibilityReduceMotion)` for a pulsing progress affordance.
- `macos/Sources/CleanView.swift` already uses
  `.contentTransition(.numericText(value:))` for event-driven byte changes.
- The cleanup review intentionally does not animate disclosure content or card
  placement; preserve that stability contract.

## Steps

1. Add `Brand.Motion.state`, `Brand.Motion.disclosure`, and
   `Brand.Motion.pulse` to `macos/Sources/Brand.swift`.
2. Add `accessibilityReduceMotion` and a private active-pulse state to
   `CleanReviewView`.
3. Replace the active phase's static icon with an explicit in-progress
   affordance. Pulse only opacity/border/fill, never layout properties.
4. Animate phase color/icon/connector changes with `Brand.Motion.state`; add a
   keyed opacity transition for the active phase detail.
5. Apply `.numericText` only to selection counts and selected byte totals.
6. Apply `Brand.Motion.disclosure` only to the chevron rotation; keep the body
   insertion/removal transaction animation-free.
7. Add focused tests for stable order and Reduce Motion-accessible labels where
   the existing SwiftUI test surface permits it.

## Boundaries

- Do NOT animate section ordering, row insertion/removal, card position, card
  height, or the expanded candidate body.
- Do NOT add a motion dependency.
- Do NOT animate the one-second elapsed timer or minute-based snapshot age.
- Do NOT change cleanup selection or authorization behavior in this plan.

## Verification

- **Mechanical**: run the macOS unit tests and a Release build; both must pass.
- **Feel check**: launch Burrow, start a cleanup scan and Agent analysis, and
  confirm:
  - exactly one progress phase visibly breathes/spins at a time;
  - the active cue changes to validation without moving the nodes;
  - selected counts/bytes pop smoothly only when selection changes;
  - repeatedly expanding a category never changes card order or animates body
    height;
  - with Reduce Motion enabled, repeating and spatial motion stops while the
    current phase remains unambiguous.
- **Done when**: the current processing node is obvious at a glance, numbers
  retain continuity, and no list/card placement animation has been introduced.

## Completion evidence

- The full macOS suite passes: 1,294 tests, 2 skipped, 0 failures.
- A universal Release build passes and the installed Developer ID build was
  exercised through a real 123-candidate scan and 129-candidate Agent plan.
- The live progress card advanced through triage/deep review and plan
  validation, displayed successful-batch counts, elapsed time, an active busy
  indicator, and the long-running fallback copy without moving section cards.
- The final plan preserved stable section order, default-collapsed item
  evidence, and descending-by-size item order. No permanent cleanup was run.
