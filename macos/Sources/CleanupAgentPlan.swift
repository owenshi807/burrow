//
//  CleanupAgentPlan.swift
//  Burrow
//
//  Canonical, revisioned cleanup state shared by the scanner, the user's
//  Agent, and the native review UI. Agent output is a proposal. Only this
//  reducer mutates selection, and a user override is never overwritten by a
//  late or retried Agent run.
//

import Foundation
import SwiftUI
import CryptoKit
import Darwin

enum CleanupRecommendationDisposition: String, Codable, Sendable, CaseIterable {
    case delete
    case keep
    case humanIntentRequired = "human_intent_required"
}

enum CleanupRecommendationOrigin: String, Codable, Sendable {
    case scanner
    case agent
    case burrowSafety = "burrow_safety"
    case user
}

enum CleanupCandidateOrigin: String, Codable, Sendable {
    case scanner
    case agentDiscovered = "agent_discovered"
}

enum CleanupAgentEvidenceBasis: String, Codable, Sendable {
    /// Directly inspected filesystem, process, package, configuration, or
    /// application metadata.
    case observation
    /// A relationship established from inspected facts: owner, consumer,
    /// active reference, version lineage, duplicate, or replacement.
    case relationship
    /// A hypothesis from naming, location, age, size, or convention. Useful
    /// for deciding what to inspect next, never enough by itself to delete.
    case inference
    /// A relevant check could not be completed. This uncertainty must remain
    /// visible instead of being converted into confidence.
    case gap
}

struct CleanupAgentEvidence: Codable, Equatable, Sendable, Identifiable {
    let basis: CleanupAgentEvidenceBasis
    let label: String
    let detail: String

    init(basis: CleanupAgentEvidenceBasis = .observation,
         label: String,
         detail: String) {
        self.basis = basis
        self.label = label
        self.detail = detail
    }

    var id: String { basis.rawValue + "\u{1f}" + label + "\u{1f}" + detail }
}

enum CleanupAgentCheckState: String, Codable, Sendable {
    case verified
    case notApplicable = "not_applicable"
    case unknown
}

enum CleanupAgentScopeKind: String, Codable, Sendable {
    case homogeneous
    case heterogeneous
    case unknown
}

enum CleanupAgentConsumerBasis: String, Codable, Sendable {
    case externalCurrent = "external_current"
    case externalInactive = "external_inactive"
    case internalOnly = "internal_only"
    case noneFound = "none_found"
    case unknown
}

enum CleanupAgentDecisionBasis: String, Codable, Sendable {
    case currentConsumer = "current_consumer"
    case mixedContainer = "mixed_container"
    case incompleteInvestigation = "incomplete_investigation"
    case userTradeoff = "user_tradeoff"
    case unusedRecoverable = "unused_recoverable"
    case sensitiveOrIrreplaceable = "sensitive_or_irreplaceable"
}

/// A machine-checkable consumer relationship. The source must be an
/// independent object outside the cleanup candidate and the target must be
/// the candidate (or one of its descendants). Free-form evidence cannot
/// substitute for this relationship when an Agent claims current use.
struct CleanupAgentConsumerReference: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case none
        case symbolicLink = "symbolic_link"
        case textualPath = "textual_path"
    }

    let kind: Kind
    let sourcePath: String
    let targetPath: String
    let current: Bool

    static let none = CleanupAgentConsumerReference(
        kind: .none, sourcePath: "", targetPath: "", current: false)
}

struct CleanupAgentCheck: Codable, Equatable, Sendable {
    let state: CleanupAgentCheckState
    let detail: String

    init(state: CleanupAgentCheckState = .verified, detail: String = "Verified by the Agent.") {
        self.state = state
        self.detail = detail
    }
}

/// Machine-checkable coverage for the semantic investigation. Free-form
/// evidence remains useful to a human, but it cannot be the only thing that
/// decides whether a delete or intent judgment is complete.
struct CleanupAgentInvestigation: Codable, Equatable, Sendable {
    let scope: CleanupAgentCheck
    let ownership: CleanupAgentCheck
    let consumers: CleanupAgentCheck
    let lifecycle: CleanupAgentCheck
    let recovery: CleanupAgentCheck
    let sensitivity: CleanupAgentCheck
    let unresolvedGaps: [String]
    let deepReviewCompleted: Bool
    let scopeKind: CleanupAgentScopeKind
    let consumerBasis: CleanupAgentConsumerBasis
    let decisionBasis: CleanupAgentDecisionBasis
    let consumerReference: CleanupAgentConsumerReference

    init(scope: CleanupAgentCheck,
         ownership: CleanupAgentCheck,
         consumers: CleanupAgentCheck,
         lifecycle: CleanupAgentCheck,
         recovery: CleanupAgentCheck,
         sensitivity: CleanupAgentCheck,
         unresolvedGaps: [String],
         deepReviewCompleted: Bool,
         scopeKind: CleanupAgentScopeKind = .homogeneous,
         consumerBasis: CleanupAgentConsumerBasis = .noneFound,
         decisionBasis: CleanupAgentDecisionBasis = .unusedRecoverable,
         consumerReference: CleanupAgentConsumerReference = .none) {
        self.scope = scope
        self.ownership = ownership
        self.consumers = consumers
        self.lifecycle = lifecycle
        self.recovery = recovery
        self.sensitivity = sensitivity
        self.unresolvedGaps = unresolvedGaps
        self.deepReviewCompleted = deepReviewCompleted
        self.scopeKind = scopeKind
        self.consumerBasis = consumerBasis
        self.decisionBasis = decisionBasis
        self.consumerReference = consumerReference
    }

    static let verifiedFixture = CleanupAgentInvestigation(
        scope: .init(), ownership: .init(), consumers: .init(),
        lifecycle: .init(), recovery: .init(), sensitivity: .init(),
        unresolvedGaps: [], deepReviewCompleted: true)

    static let verifiedKeepFixture = CleanupAgentInvestigation(
        scope: .init(), ownership: .init(), consumers: .init(),
        lifecycle: .init(), recovery: .init(), sensitivity: .init(),
        unresolvedGaps: [], deepReviewCompleted: true,
        decisionBasis: .sensitiveOrIrreplaceable)

    static let verifiedHumanIntentFixture = CleanupAgentInvestigation(
        scope: .init(), ownership: .init(), consumers: .init(),
        lifecycle: .init(), recovery: .init(), sensitivity: .init(),
        unresolvedGaps: [], deepReviewCompleted: true,
        decisionBasis: .userTradeoff)

    static let verifiedMixedFixture = CleanupAgentInvestigation(
        scope: .init(), ownership: .init(), consumers: .init(),
        lifecycle: .init(), recovery: .init(), sensitivity: .init(),
        unresolvedGaps: [], deepReviewCompleted: true,
        scopeKind: .heterogeneous, decisionBasis: .mixedContainer)

    var hasUnknownRequiredFact: Bool {
        [scope, ownership, consumers, lifecycle, recovery, sensitivity]
            .contains { $0.state == .unknown }
    }
}

struct CleanupAgentRecommendation: Codable, Equatable, Sendable {
    let candidateId: String
    let disposition: CleanupRecommendationDisposition
    let reason: String
    let consequence: String
    let confidence: Double
    let evidence: [CleanupAgentEvidence]
    let investigation: CleanupAgentInvestigation

    init(candidateId: String,
         disposition: CleanupRecommendationDisposition,
         reason: String,
         consequence: String,
         confidence: Double,
         evidence: [CleanupAgentEvidence],
         investigation: CleanupAgentInvestigation = .verifiedFixture) {
        self.candidateId = candidateId
        self.disposition = disposition
        self.reason = reason
        self.consequence = consequence
        self.confidence = confidence
        self.evidence = evidence
        self.investigation = investigation
    }
}

struct CleanupAgentDiscoveredCandidate: Codable, Equatable, Sendable {
    let parentCandidateId: String
    let path: String
    let sizeBytes: Int64
    let disposition: CleanupRecommendationDisposition
    let reason: String
    let consequence: String
    let confidence: Double
    let evidence: [CleanupAgentEvidence]
    let investigation: CleanupAgentInvestigation
}

struct CleanupAgentAnalysis: Codable, Equatable, Sendable {
    let summary: String
    let recommendations: [CleanupAgentRecommendation]
    let discoveredCandidates: [CleanupAgentDiscoveredCandidate]

    init(summary: String,
         recommendations: [CleanupAgentRecommendation],
         discoveredCandidates: [CleanupAgentDiscoveredCandidate] = []) {
        self.summary = summary
        self.recommendations = recommendations
        self.discoveredCandidates = discoveredCandidates
    }
}

struct CleanupAgentCandidateInput: Codable, Equatable, Sendable {
    let candidateId: String
    let path: String
    let category: String
    let sizeBytes: Int64
    let itemCount: Int?
    let runningApp: String?
    let sensitivePathHint: Bool
    let deepReviewRequired: Bool

    init(candidateId: String, path: String, category: String,
         sizeBytes: Int64, itemCount: Int?, runningApp: String?,
         sensitivePathHint: Bool, deepReviewRequired: Bool = false) {
        self.candidateId = candidateId
        self.path = path
        self.category = category
        self.sizeBytes = sizeBytes
        self.itemCount = itemCount
        self.runningApp = runningApp
        self.sensitivePathHint = sensitivePathHint
        self.deepReviewRequired = deepReviewRequired
    }
}

struct CleanupAgentAnalysisInput: Codable, Equatable, Sendable {
    let planId: String
    let planRevision: Int
    let candidates: [CleanupAgentCandidateInput]
}

protocol CleanupAgentAnalyzing: Sendable {
    var displayName: String { get }
    func analyze(_ input: CleanupAgentAnalysisInput) async throws -> CleanupAgentAnalysis
}

protocol CleanupAgentProgressAnalyzing: Sendable {
    func analyze(
        _ input: CleanupAgentAnalysisInput,
        progress: @escaping @Sendable (CleanupAgentProgress.Phase, Int?) -> Void
    ) async throws -> CleanupAgentAnalysis
}

struct CleanupPlanCandidate: Identifiable, Equatable {
    let id: String
    let path: String
    let category: String
    let sizeBytes: Int64
    let sizeText: String
    let itemCount: Int?
    let displayName: String
    let abbreviatedPath: String
    let locked: Bool
    let origin: CleanupCandidateOrigin
}

struct CleanupCandidateRecommendation: Equatable {
    let origin: CleanupRecommendationOrigin
    let disposition: CleanupRecommendationDisposition
    let reason: String
    let consequence: String
    let confidence: Double?
    let evidence: [CleanupAgentEvidence]
    let agentRunId: UUID?
    let investigation: CleanupAgentInvestigation?

    init(origin: CleanupRecommendationOrigin,
         disposition: CleanupRecommendationDisposition,
         reason: String,
         consequence: String,
         confidence: Double?,
         evidence: [CleanupAgentEvidence],
         agentRunId: UUID?,
         investigation: CleanupAgentInvestigation? = nil) {
        self.origin = origin
        self.disposition = disposition
        self.reason = reason
        self.consequence = consequence
        self.confidence = confidence
        self.evidence = evidence
        self.agentRunId = agentRunId
        self.investigation = investigation
    }
}

struct CleanupDecisionSection: Identifiable, Equatable {
    let disposition: CleanupRecommendationDisposition
    let category: String
    let candidates: [CleanupPlanCandidate]
    var id: String { disposition.rawValue + "\u{1f}" + category }
}

struct CleanupAgentProgress: Equatable {
    enum Phase: Equatable, Hashable {
        case investigating
        case validating
        case completed
    }

    let startedAt: Date
    let candidateCount: Int
    var phase: Phase
    var reviewedCount: Int?
    var finishedAt: Date?

    func elapsed(at date: Date = Date()) -> TimeInterval {
        max(0, (finishedAt ?? date).timeIntervalSince(startedAt))
    }
}

private enum CleanupAgentRunError: LocalizedError {
    case timedOut

    var errorDescription: String? {
        NSLocalizedString(
            "Codex did not finish within 20 minutes. Nothing was changed. Retry when the Agent is available.",
            comment: "cleanup Agent timeout"
        )
    }
}

@MainActor
final class CleanupPlanStore: ObservableObject {
    enum AgentState: Equatable {
        case unavailable(String)
        case consentRequired
        case idle
        case analyzing(agent: String)
        case ready(agent: String, summary: String)
        case degraded(agent: String, reason: String)
    }

    @Published private(set) var planId = UUID()
    @Published private(set) var snapshotCreatedAt = Date()
    @Published private(set) var revision = 0
    @Published private(set) var candidates: [CleanupPlanCandidate] = []
    @Published private(set) var recommendations: [String: CleanupCandidateRecommendation] = [:]
    @Published private(set) var selection: CleanSelection?
    @Published private(set) var selectedCandidateId: String?
    @Published private(set) var agentState: AgentState = .idle
    @Published private(set) var agentProgress: CleanupAgentProgress?
    @Published private(set) var userOverrides: Set<String> = []
    @Published private(set) var executionSnapshot: CleanupSnapshot?

    private var pathToCandidateId: [String: String] = [:]
    private var currentLocks: [String: CleanSelection.LockReason] = [:]
    private var currentAgentRunId: UUID?
    private var currentAgentRunBaseRevision: Int?
    private var analysisTask: Task<Void, Never>?
    private let analyzer: any CleanupAgentAnalyzing
    private let analysisTimeoutNanoseconds: UInt64
    private let discoverySnapshotCapturedHook: () -> Void

    init(analyzer: any CleanupAgentAnalyzing = CodexCleanupAgentAdapter(),
         analysisTimeoutNanoseconds: UInt64 = 1_200_000_000_000,
         discoverySnapshotCapturedHook: @escaping () -> Void = {}) {
        self.analyzer = analyzer
        self.analysisTimeoutNanoseconds = analysisTimeoutNanoseconds
        self.discoverySnapshotCapturedHook = discoverySnapshotCapturedHook
    }

    deinit { analysisTask?.cancel() }

    var agentDisplayName: String { analyzer.displayName }

    func load(list: CleanList,
              snapshot: CleanupSnapshot,
              locked: [String: CleanSelection.LockReason],
              hasAgentConsent: Bool) {
        analysisTask?.cancel()
        planId = UUID()
        snapshotCreatedAt = snapshot.createdAt
        revision = 1
        userOverrides = []
        currentAgentRunId = nil
        currentAgentRunBaseRevision = nil
        agentProgress = nil
        executionSnapshot = snapshot
        // Paths are the identity shared by selection, authorization and the
        // Agent. The scanner has emitted duplicate paths in production, so
        // canonicalize here too: callers can construct a CleanList directly
        // without passing through the text parser.
        let canonicalList = list.deduplicatedByPath()
        let candidatePaths = canonicalList.categories.flatMap(\.items).map(\.path)
        let coarseParentPaths = Set(candidatePaths.filter { path in
            let prefix = path.hasSuffix("/") ? path : path + "/"
            return candidatePaths.contains { $0 != path && $0.hasPrefix(prefix) }
        })
        var effectiveLocks = locked
        for path in coarseParentPaths where effectiveLocks[path] == nil {
            effectiveLocks[path] = .notCleanable(reason: NSLocalizedString(
                "This parent contains separately judged cleanup candidates. Select the verified child items instead.",
                comment: "coarse cleanup parent lock"))
        }
        selection = CleanSelection(list: canonicalList, locked: effectiveLocks)
        currentLocks = effectiveLocks

        let snapshotItems = Dictionary(
            snapshot.items.map { ($0.identity.path, $0.identity) },
            uniquingKeysWith: { first, _ in first })
        candidates = canonicalList.categories.flatMap { category in
            category.items.map { item in
                let identityToken = snapshotItems[item.path]?.shellStatToken ?? "refused"
                let id = Self.candidateId(planId: planId, path: item.path,
                                          identityToken: identityToken)
                return CleanupPlanCandidate(
                    id: id, path: item.path, category: category.name,
                    sizeBytes: item.sizeBytes, sizeText: item.sizeText,
                    itemCount: item.itemCount, displayName: item.displayName,
                    abbreviatedPath: item.abbreviatedPath,
                    locked: effectiveLocks[item.path] != nil,
                    origin: .scanner)
            }
        }
        pathToCandidateId = Dictionary(candidates.map { ($0.path, $0.id) },
                                       uniquingKeysWith: { first, _ in first })
        recommendations = Dictionary(candidates.map { candidate in
            let scannerDisposition: CleanupRecommendationDisposition = candidate.locked ? .keep : .delete
            let policy = policyDisposition(proposed: scannerDisposition, candidate: candidate)
            let disposition = policy.disposition
            let reason = effectiveLocks[candidate.path].map(Self.lockReasonText)
                ?? policy.reason
                ?? NSLocalizedString("The deterministic scanner classified this as removable cache data.", comment: "")
            return (candidate.id, CleanupCandidateRecommendation(
                origin: .scanner, disposition: disposition, reason: reason,
                consequence: policy.consequence ?? CleanReviewView.consequence(for: candidate.category),
                confidence: nil, evidence: [], agentRunId: nil))
        }, uniquingKeysWith: { first, _ in first })
        if var staged = selection {
            for candidate in candidates
            where recommendation(for: candidate.id).disposition != .delete
                && staged.isTicked(candidate.path) {
                staged.toggle(candidate.path)
            }
            selection = staged
        }
        // Start with the plan-wide judgment. A row becomes the inspector focus
        // only after the user explicitly selects it.
        selectedCandidateId = nil
        agentState = hasAgentConsent ? .idle : .consentRequired
    }

    func startAgentAnalysis() {
        guard !candidates.isEmpty else { return }
        analysisTask?.cancel()
        let runId = UUID()
        currentAgentRunId = runId
        let baseRevision = revision
        currentAgentRunBaseRevision = baseRevision
        let totalBytes = max(Int64(1), candidates.reduce(0) { $0 + $1.sizeBytes })
        let input = CleanupAgentAnalysisInput(
            planId: planId.uuidString,
            planRevision: baseRevision,
            candidates: candidates.map { candidate in
                CleanupAgentCandidateInput(
                    candidateId: candidate.id,
                    path: candidate.path,
                    category: candidate.category,
                    sizeBytes: candidate.sizeBytes,
                    itemCount: candidate.itemCount,
                    runningApp: currentLocks[candidate.path].map(Self.lockReasonText),
                    sensitivePathHint: SensitiveRemnantMatcher.isSensitive(candidate.path),
                    deepReviewRequired: candidate.locked
                        || SensitiveRemnantMatcher.isSensitive(candidate.path)
                        || candidate.sizeBytes >= 512 * 1_024 * 1_024
                        || candidate.sizeBytes * 10 >= totalBytes
                        || candidates.contains(where: {
                            $0.id != candidate.id
                                && $0.path.hasPrefix(candidate.path.hasSuffix("/")
                                    ? candidate.path : candidate.path + "/")
                        }))
            })
        agentState = .analyzing(agent: analyzer.displayName)
        agentProgress = CleanupAgentProgress(
            startedAt: Date(), candidateCount: candidates.count,
            phase: .investigating, reviewedCount: nil, finishedAt: nil)
        let timeout = analysisTimeoutNanoseconds
        let progressTarget = WeakCleanupPlanStore(self)
        analysisTask = Task { [weak self, analyzer] in
            do {
                let analysis = try await Self.analyze(
                    input, with: analyzer, timeoutNanoseconds: timeout,
                    progress: { phase, reviewedCount in
                        Task { @MainActor in
                            guard let store = progressTarget.value,
                                  store.currentAgentRunId == runId else { return }
                            store.agentProgress?.phase = phase
                            if let reviewedCount {
                                store.agentProgress?.reviewedCount = reviewedCount
                            }
                        }
                    })
                guard let scoped = self?.prevalidatedDiscoveryScope(in: analysis) else { return }
                let measurementTask = Task.detached(priority: .utility) {
                    Self.measuringDiscoveredCandidates(in: scoped)
                }
                let measured = await withTaskCancellationHandler {
                    await measurementTask.value
                } onCancel: {
                    measurementTask.cancel()
                }
                guard !Task.isCancelled else { return }
                self?.markValidating(runId: runId)
                // The validation is real and normally sub-frame. Keep the
                // named phase visible briefly so the transition is legible,
                // without pretending that it represents a percentage.
                try await Task.sleep(nanoseconds: 240_000_000)
                guard !Task.isCancelled else { return }
                self?.apply(measured, runId: runId)
            } catch {
                guard !Task.isCancelled else { return }
                self?.finishDegraded(error, runId: runId)
            }
        }
    }

    func selectCandidate(_ id: String) { selectedCandidateId = id }

    func toggleCandidate(_ id: String) {
        guard let candidate = candidates.first(where: { $0.id == id }), !candidate.locked,
              var selection else { return }
        selection.toggle(candidate.path)
        self.selection = selection
        syncOverride(for: candidate, selection: selection)
        if selection.selectedCount == 0 { selectedCandidateId = nil }
        revision += 1
    }

    func toggleCategory(_ category: String,
                        disposition: CleanupRecommendationDisposition? = nil) {
        guard var selection else { return }
        let targets = candidates.filter {
            $0.category == category && !($0.locked) &&
                (disposition == nil || recommendation(for: $0.id).disposition == disposition)
        }
        guard !targets.isEmpty else { return }
        let shouldSelect = targets.contains { !selection.isTicked($0.path) }
        for candidate in targets {
            if selection.isTicked(candidate.path) != shouldSelect {
                selection.toggle(candidate.path)
            }
            syncOverride(for: candidate, selection: selection)
        }
        self.selection = selection
        revision += 1
    }

    func selectAll() { setAll(selected: true) }
    func deselectAll() {
        setAll(selected: false)
        selectedCandidateId = nil
    }

    func categoryState(for candidates: [CleanupPlanCandidate]) -> CleanSelection.CategoryState {
        let tickable = candidates.filter { !$0.locked }
        let selected = tickable.filter(isSelected).count
        if selected == 0 { return .none }
        return selected == tickable.count ? .all : .mixed
    }

    func selectedCount(in candidates: [CleanupPlanCandidate]) -> Int {
        candidates.filter(isSelected).count
    }

    func selectedBytes(in candidates: [CleanupPlanCandidate]) -> Int64 {
        candidates.filter(isSelected).reduce(0) { $0 + $1.sizeBytes }
    }

    func isSelected(_ candidate: CleanupPlanCandidate) -> Bool {
        selection?.isTicked(candidate.path) ?? false
    }

    func recommendation(for candidateId: String) -> CleanupCandidateRecommendation {
        recommendations[candidateId] ?? CleanupCandidateRecommendation(
            origin: .scanner, disposition: .keep,
            reason: NSLocalizedString("No recommendation is available.", comment: ""),
            consequence: "", confidence: nil, evidence: [], agentRunId: nil)
    }

    var selectedCandidate: CleanupPlanCandidate? {
        candidates.first { $0.id == selectedCandidateId }
    }

    var selectedCount: Int { selection?.selectedCount ?? 0 }
    var totalCount: Int { selection?.totalCount ?? candidates.count }
    var selectedBytes: Int64 { selection?.selectedBytes ?? 0 }

    func recommendationCount(for disposition: CleanupRecommendationDisposition) -> Int {
        candidates.filter { recommendation(for: $0.id).disposition == disposition }.count
    }

    func recommendationBytes(for disposition: CleanupRecommendationDisposition) -> Int64 {
        candidates.filter { recommendation(for: $0.id).disposition == disposition }
            .reduce(0) { $0 + $1.sizeBytes }
    }

    /// Program-derived copy for the overview and completion card. The model's
    /// prose is useful context, but it is not allowed to invent authoritative
    /// counts or bytes.
    var overallRecommendationText: String {
        let deleteCount = recommendationCount(for: .delete)
        let keepCount = recommendationCount(for: .keep)
        let intentCount = recommendationCount(for: .humanIntentRequired)
        let summary = String(
            format: NSLocalizedString("Reviewed %d candidates. Recommend cleaning %d (%@), keeping %d (%@), and leaving %d (%@) for your decision.", comment: "derived cleanup Agent summary"),
            candidates.count,
            deleteCount, Fmt.bytes(recommendationBytes(for: .delete)),
            keepCount, Fmt.bytes(recommendationBytes(for: .keep)),
            intentCount, Fmt.bytes(recommendationBytes(for: .humanIntentRequired)))
        let conservativeCount = candidates.filter { candidate in
            !candidate.locked && recommendation(for: candidate.id).origin == .burrowSafety
        }.count
        guard conservativeCount > 0 else { return summary }
        return summary + " " + String(
            format: NSLocalizedString(
                "Burrow conservatively kept %d items because Codex did not establish a complete deletion basis.",
                comment: "candidate-level Agent fallback summary"),
            conservativeCount)
    }

    var canUseAgentCTA: Bool {
        if case .ready = agentState { return userOverrides.isEmpty }
        return false
    }

    var canConfirmPlan: Bool {
        guard selectedCount > 0 else { return false }
        switch agentState {
        case .analyzing, .degraded:
            return false
        default:
            return true
        }
    }

    var sections: [CleanupDecisionSection] {
        let order: [CleanupRecommendationDisposition] = [.delete, .keep, .humanIntentRequired]
        return order.flatMap { disposition in
            let matching = candidates.filter { recommendation(for: $0.id).disposition == disposition }
            var categoryOrder: [String] = []
            var grouped: [String: [CleanupPlanCandidate]] = [:]
            for candidate in matching {
                if grouped[candidate.category] == nil { categoryOrder.append(candidate.category) }
                grouped[candidate.category, default: []].append(candidate)
            }
            let categories: [[CleanupPlanCandidate]] = CleanImpactRanker.sorted(
                categoryOrder.compactMap { category in
                    grouped[category].map { candidates in
                        let ordered = candidates.sorted {
                            if $0.sizeBytes != $1.sizeBytes { return $0.sizeBytes > $1.sizeBytes }
                            return $0.path < $1.path
                        }
                        return (category: category, value: ordered)
                    }
                })
            let orderedCategories = disposition == .delete
                ? categories.sorted {
                    let lhs = $0.reduce(Int64(0)) { $0 + $1.sizeBytes }
                    let rhs = $1.reduce(Int64(0)) { $0 + $1.sizeBytes }
                    if lhs != rhs { return lhs > rhs }
                    return $0[0].category < $1[0].category
                }
                : categories
            return orderedCategories.map { candidates -> CleanupDecisionSection in
                CleanupDecisionSection(disposition: disposition,
                                       category: candidates[0].category,
                                       candidates: candidates)
            }
        }
    }

    private func apply(_ analysis: CleanupAgentAnalysis, runId: UUID) {
        guard currentAgentRunId == runId else { return }
        let discoveredRecommendations = integrateDiscoveredCandidates(
            analysis.discoveredCandidates, runId: runId)
        let known = Set(candidates.map(\.id))
        var seen = Set<String>()
        var resolved = Set<String>()
        var accepted = 0
        var nextSelection = selection

        func stageSafetyKeep(
            _ candidate: CleanupPlanCandidate,
            reason: String,
            consequence: String,
            evidence: [CleanupAgentEvidence],
            forceDeselect: Bool = false
        ) {
            guard resolved.insert(candidate.id).inserted else { return }
            recommendations[candidate.id] = CleanupCandidateRecommendation(
                origin: .burrowSafety,
                disposition: .keep,
                reason: reason,
                consequence: consequence,
                confidence: nil,
                evidence: evidence,
                agentRunId: runId,
                investigation: nil)
            accepted += 1
            guard (forceDeselect || !userOverrides.contains(candidate.id)),
                  var value = nextSelection,
                  value.isTicked(candidate.path) else { return }
            value.toggle(candidate.path)
            nextSelection = value
        }

        let allProposals = analysis.recommendations + discoveredRecommendations
        let proposedCandidateIDs = Set(allProposals.map(\.candidateId))
        let proposalCounts = Dictionary(grouping: allProposals, by: \.candidateId)
            .mapValues(\.count)
        for proposal in allProposals {
            guard known.contains(proposal.candidateId), seen.insert(proposal.candidateId).inserted,
                  let candidate = candidates.first(where: { $0.id == proposal.candidateId }) else {
                continue
            }

            if proposalCounts[proposal.candidateId, default: 0] != 1 {
                let reason = NSLocalizedString(
                    "Codex returned conflicting duplicate judgments for this item.",
                    comment: "duplicate Agent judgment conservative keep reason")
                stageSafetyKeep(
                    candidate,
                    reason: reason,
                    consequence: NSLocalizedString(
                        "Burrow excluded this item from the Agent cleanup plan. Retry the analysis if you want a new judgment.",
                        comment: "missing Agent judgment conservative keep consequence"),
                    evidence: [CleanupAgentEvidence(
                        basis: .gap,
                        label: NSLocalizedString("Agent judgment incomplete", comment: ""),
                        detail: reason)])
                continue
            }

            // Active, refused, or overlapping candidates are already outside
            // the executable plan. If the Agent's supporting relationship is
            // not machine-verifiable, the deterministic lock is still enough
            // to complete this row safely: keep it unselected and attribute
            // the decision to Burrow, not to the unverified Agent claim. A
            // protected row must not make the other valid judgments unusable.
            if candidate.locked {
                let lockReason = Self.lockReasonText(currentLocks[candidate.path])
                stageSafetyKeep(
                    candidate,
                    reason: lockReason,
                    consequence: NSLocalizedString(
                        "This protected item is excluded from cleanup. Close the related app or resolve the safety condition, then rescan if you want it reviewed again.",
                        comment: "protected cleanup candidate consequence"),
                    evidence: [CleanupAgentEvidence(
                        basis: .observation,
                        label: NSLocalizedString("Burrow safety check", comment: ""),
                        detail: lockReason)],
                    forceDeselect: true)
                continue
            }

            let hasRequiredText = !proposal.reason.trimmingCharacters(
                in: .whitespacesAndNewlines).isEmpty
                && !proposal.consequence.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty
                && !proposal.evidence.isEmpty
            let isComplete = hasRequiredText && isSemanticallyComplete(
                proposal, candidate: candidate,
                proposedCandidateIDs: proposedCandidateIDs)
            let hasDeletionEvidence = proposal.disposition == .keep
                || proposal.evidence.contains(where: {
                    $0.basis == .observation || $0.basis == .relationship
                })
            guard isComplete, hasDeletionEvidence else {
                let reason = NSLocalizedString(
                    "Codex did not establish a complete, non-contradictory basis for deleting this item.",
                    comment: "conservative keep reason")
                stageSafetyKeep(
                    candidate,
                    reason: reason,
                    consequence: NSLocalizedString(
                        "Burrow excluded this item from the Agent cleanup plan. You can inspect it manually or retry the analysis after its ownership or usage becomes verifiable.",
                        comment: "conservative keep consequence"),
                    evidence: [CleanupAgentEvidence(
                        basis: .gap,
                        label: NSLocalizedString("Host verification incomplete", comment: ""),
                        detail: reason)])
                continue
            }
            let policy = policyDisposition(proposed: proposal.disposition, candidate: candidate)
            let disposition = policy.disposition
            recommendations[proposal.candidateId] = CleanupCandidateRecommendation(
                origin: .agent, disposition: disposition,
                reason: policy.reason ?? proposal.reason,
                consequence: policy.consequence ?? proposal.consequence,
                confidence: min(max(proposal.confidence, 0), 1),
                evidence: Array(proposal.evidence.prefix(12)), agentRunId: runId,
                investigation: proposal.investigation)
            resolved.insert(proposal.candidateId)
            accepted += 1

            // Merge at candidate granularity. Editing one row while Codex is
            // working protects that row only; unrelated rows still receive
            // their Agent selection. The run ID already rejects results from
            // an obsolete/reloaded plan, so a global revision gate would make
            // one user edit leave scanner checkboxes under Agent judgments.
            guard !userOverrides.contains(proposal.candidateId),
                  !candidate.locked, var value = nextSelection else { continue }
            let shouldSelect = disposition == .delete
            if value.isTicked(candidate.path) != shouldSelect { value.toggle(candidate.path) }
            nextSelection = value
        }

        // Adapter implementations are expected to return exact coverage, but
        // the reducer still closes any missing/duplicate/invalid row at the
        // candidate boundary. A missing judgment can only shrink the staged
        // deletion set; it never forces unrelated valid recommendations into
        // a plan-wide degraded state.
        for candidate in candidates where !resolved.contains(candidate.id) {
            let reason = NSLocalizedString(
                "Codex did not return a complete judgment for this item.",
                comment: "missing Agent judgment conservative keep reason")
            stageSafetyKeep(
                candidate,
                reason: reason,
                consequence: NSLocalizedString(
                    "Burrow excluded this item from the Agent cleanup plan. Retry the analysis if you want a new judgment.",
                    comment: "missing Agent judgment conservative keep consequence"),
                evidence: [CleanupAgentEvidence(
                    basis: .gap,
                    label: NSLocalizedString("Agent judgment incomplete", comment: ""),
                    detail: reason)])
        }
        selection = nextSelection
        if let nextSelection {
            for id in Array(userOverrides) {
                if let candidate = candidates.first(where: { $0.id == id }) {
                    syncOverride(for: candidate, selection: nextSelection)
                }
            }
        }
        revision += accepted > 0 ? 1 : 0
        agentProgress?.phase = .completed
        agentProgress?.reviewedCount = accepted
        agentProgress?.finishedAt = Date()
        if accepted == candidates.count {
            agentState = .ready(agent: analyzer.displayName, summary: analysis.summary)
        } else if accepted > 0 {
            agentState = .degraded(
                agent: analyzer.displayName,
                reason: String(
                    format: NSLocalizedString(
                        "The Agent judged %d of %d candidates. Burrow kept the scanner result for the rest and disabled the Agent shortcut.",
                        comment: "partial Agent analysis"
                    ),
                    accepted,
                    candidates.count
                )
            )
        } else {
            agentState = .degraded(
                agent: analyzer.displayName,
                reason: NSLocalizedString("The Agent returned no valid candidate judgments.", comment: "")
            )
        }
    }

    /// Accepts only narrower descendants of a scanner-produced parent. The
    /// Agent may discover useful granularity, but it cannot widen cleanup into
    /// an unrelated path. Every accepted child is then recaptured by the same
    /// canonical-path, symlink, volume, root and overlap checks as scanner
    /// output before it can appear in `CleanSelection`.
    private func integrateDiscoveredCandidates(
        _ proposals: [CleanupAgentDiscoveredCandidate],
        runId _: UUID
    ) -> [CleanupAgentRecommendation] {
        guard !proposals.isEmpty, let oldSelection = selection,
              let oldSnapshot = executionSnapshot else { return [] }

        let parents = validatedDiscoveryParents(
            in: oldSnapshot,
            proposedParentIDs: Set(proposals.map(\.parentCandidateId)))
        let existingIDsByPath = Dictionary(candidates.map { ($0.path, $0.id) },
                                           uniquingKeysWith: { first, _ in first })
        let existingPaths = Set(candidates.map(\.path))
        let canonicalProposalCounts = Dictionary(
            grouping: proposals.prefix(256).compactMap { proposal -> String? in
                guard proposal.path.hasPrefix("/"),
                      let canonical = InvokingUserIdentity.canonicalPath(proposal.path),
                      canonical == proposal.path else { return nil }
                return canonical
            }, by: { $0 }).mapValues(\.count)
        var acceptedPaths = Set<String>()
        var proposalByPath: [String: CleanupAgentDiscoveredCandidate] = [:]
        var itemsByCategory: [String: [CleanList.Item]] = [:]

        for proposal in proposals.prefix(256) {
            guard let parent = parents[proposal.parentCandidateId],
                  proposal.path.hasPrefix("/"),
                  !proposal.path.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }),
                  let canonical = InvokingUserIdentity.canonicalPath(proposal.path),
                  canonical == proposal.path,
                  canonicalProposalCounts[canonical] == 1,
                  canonical != parent.path,
                  canonical.hasPrefix(parent.path.hasSuffix("/")
                                      ? parent.path : parent.path + "/"),
                  !existingPaths.contains(canonical),
                  acceptedPaths.insert(canonical).inserted else { continue }
            let bytes = max(0, proposal.sizeBytes)
            itemsByCategory[parent.category, default: []].append(.init(
                path: canonical, sizeBytes: bytes,
                sizeText: Fmt.bytes(bytes), itemCount: nil))
            proposalByPath[canonical] = proposal
        }
        guard !proposalByPath.isEmpty else { return [] }

        var mergedCategories = oldSelection.list.categories
        for (category, items) in itemsByCategory {
            if let index = mergedCategories.firstIndex(where: { $0.name == category }) {
                mergedCategories[index].items.append(contentsOf: items)
            } else {
                mergedCategories.append(.init(name: category, items: items))
            }
        }
        let mergedList = CleanList(
            categories: mergedCategories,
            summaryTotalText: oldSelection.list.summaryTotalText,
            summaryItemCount: nil).deduplicatedByPath()

        let approvedURLs = oldSnapshot.approvedRoots.map {
            URL(fileURLWithPath: $0.path, isDirectory: true)
        }
        guard let mergedSnapshot = try? CleanupSnapshot.capture(
            list: mergedList, approvedRootURLs: approvedURLs) else { return [] }
        discoverySnapshotCapturedHook()
        let proposedParentIDs = Set(proposalByPath.values.map(\.parentCandidateId))
        let parentsStillUnchanged = Set(validatedDiscoveryParents(
            in: oldSnapshot,
            proposedParentIDs: proposedParentIDs).keys)
        // This check is intentionally AFTER the new child snapshot exists.
        // If the original parent changed before it, reject the whole discovery
        // merge. If it changes after it, the already-pinned child identities
        // fail the ordinary execution-boundary revalidation instead.
        guard parentsStillUnchanged == proposedParentIDs else { return [] }
        let executablePaths = Set(mergedSnapshot.items.map(\.identity.path))
        let safeDiscoveredPaths = Set(proposalByPath.keys).intersection(executablePaths)
        guard !safeDiscoveredPaths.isEmpty else { return [] }

        var locks = currentLocks
        let liveLocks = CleanLock.lockedPaths(in: mergedList, running: CleanLock.runningApps())
        for (path, reason) in liveLocks { locks[path] = reason }
        for entry in mergedSnapshot.skipped {
            locks[entry.path] = .notCleanable(reason: entry.reason)
        }

        let oldSelectedPaths = Set(oldSelection.list.categories.flatMap(\.items)
            .map(\.path).filter(oldSelection.isTicked))
        var rebuiltSelection = CleanSelection(list: mergedList, locked: locks)
        for item in mergedList.categories.flatMap(\.items) {
            if existingPaths.contains(item.path),
               rebuiltSelection.isTicked(item.path) != oldSelectedPaths.contains(item.path) {
                rebuiltSelection.toggle(item.path)
            }
        }
        let selectionChangedDuringRun = currentAgentRunBaseRevision.map { revision != $0 } ?? false
        if selectionChangedDuringRun {
            // A user edit during analysis is intent about the staged plan as
            // it existed then. Late-discovered rows must never silently grow
            // that plan; keep them off until the user explicitly includes
            // them after seeing the Agent's reason.
            for path in safeDiscoveredPaths where rebuiltSelection.isTicked(path) {
                rebuiltSelection.toggle(path)
            }
        }

        let snapshotItems = Dictionary(
            mergedSnapshot.items.map { ($0.identity.path, $0.identity) },
            uniquingKeysWith: { first, _ in first })
        candidates = mergedList.categories.flatMap { category in
            category.items.map { item in
                let token = snapshotItems[item.path]?.shellStatToken ?? "refused"
                return CleanupPlanCandidate(
                    // Recapturing a finer-grained plan deliberately refuses
                    // the coarse parent. Preserve IDs for scanner candidates
                    // so the Agent response still maps to the reviewed object;
                    // only newly discovered children receive a fresh ID.
                    id: existingIDsByPath[item.path]
                        ?? Self.candidateId(planId: planId, path: item.path, identityToken: token),
                    path: item.path, category: category.name,
                    sizeBytes: item.sizeBytes, sizeText: item.sizeText,
                    itemCount: item.itemCount, displayName: item.displayName,
                    abbreviatedPath: item.abbreviatedPath,
                    locked: locks[item.path] != nil,
                    origin: safeDiscoveredPaths.contains(item.path) ? .agentDiscovered : .scanner)
            }
        }
        pathToCandidateId = Dictionary(candidates.map { ($0.path, $0.id) },
                                       uniquingKeysWith: { first, _ in first })
        if selectionChangedDuringRun {
            for path in safeDiscoveredPaths {
                if let id = pathToCandidateId[path] { userOverrides.insert(id) }
            }
        }
        currentLocks = locks
        selection = rebuiltSelection
        executionSnapshot = mergedSnapshot

        return safeDiscoveredPaths.compactMap { path in
            guard let proposal = proposalByPath[path],
                  let id = pathToCandidateId[path] else { return nil }
            return CleanupAgentRecommendation(
                candidateId: id, disposition: proposal.disposition,
                reason: proposal.reason, consequence: proposal.consequence,
                confidence: proposal.confidence, evidence: proposal.evidence,
                investigation: proposal.investigation)
        }
    }

    private func isSemanticallyComplete(
        _ proposal: CleanupAgentRecommendation,
        candidate: CleanupPlanCandidate,
        proposedCandidateIDs: Set<String>
    ) -> Bool {
        let investigation = proposal.investigation
        guard investigation.deepReviewCompleted,
              investigation.unresolvedGaps.isEmpty,
              !investigation.hasUnknownRequiredFact,
              investigation.scopeKind != .unknown,
              investigation.consumerBasis != .unknown,
              !proposal.evidence.contains(where: { $0.basis == .gap }) else { return false }

        let hasJudgedDescendant = hasStrictDescendant(
            of: candidate, proposedCandidateIDs: proposedCandidateIDs)
        let hasExternalCurrentConsumer = hasValidExternalConsumerReference(
            investigation.consumerReference, for: candidate)

        // Cross-field consistency is enforced locally. The model cannot turn
        // contradictory typed labels into an executable recommendation.
        guard investigation.decisionBasis != .incompleteInvestigation else { return false }
        let claimsCurrentConsumer = investigation.consumerBasis == .externalCurrent
            || investigation.decisionBasis == .currentConsumer
        if claimsCurrentConsumer {
            guard investigation.consumerBasis == .externalCurrent,
                  investigation.decisionBasis == .currentConsumer,
                  hasExternalCurrentConsumer else { return false }
        } else if investigation.consumerReference != .none {
            return false
        }
        if investigation.scopeKind == .heterogeneous
            || investigation.decisionBasis == .mixedContainer {
            guard investigation.scopeKind == .heterogeneous,
                  investigation.decisionBasis == .mixedContainer,
                  hasJudgedDescendant else { return false }
        }

        switch proposal.disposition {
        case .delete:
            return investigation.decisionBasis == .unusedRecoverable
                && investigation.consumerBasis != .externalCurrent
                && investigation.consumerReference == .none
        case .keep:
            return [.currentConsumer, .mixedContainer, .sensitiveOrIrreplaceable]
                .contains(investigation.decisionBasis)
        case .humanIntentRequired:
            return investigation.decisionBasis == .userTradeoff
                && investigation.consumerBasis != .externalCurrent
                && investigation.consumerReference == .none
        }
    }

    private func hasStrictDescendant(
        of candidate: CleanupPlanCandidate,
        proposedCandidateIDs: Set<String>
    ) -> Bool {
        let prefix = candidate.path.hasSuffix("/") ? candidate.path : candidate.path + "/"
        return candidates.contains {
            $0.id != candidate.id
                && proposedCandidateIDs.contains($0.id)
                && $0.path.hasPrefix(prefix)
        }
    }

    private func hasValidExternalConsumerReference(
        _ reference: CleanupAgentConsumerReference,
        for candidate: CleanupPlanCandidate
    ) -> Bool {
        guard reference.current,
              reference.kind != .none,
              reference.sourcePath.hasPrefix("/"),
              reference.targetPath.hasPrefix("/"),
              let source = canonicalSourceLocation(reference.sourcePath),
              let target = InvokingUserIdentity.canonicalPath(reference.targetPath),
              let candidateCanonical = InvokingUserIdentity.canonicalPath(candidate.path) else {
            return false
        }
        let candidatePrefix = candidateCanonical.hasSuffix("/")
            ? candidateCanonical : candidateCanonical + "/"
        let sourceIsIndependent = source != candidateCanonical && !source.hasPrefix(candidatePrefix)
        let targetIsCandidate = target == candidateCanonical || target.hasPrefix(candidatePrefix)
        guard sourceIsIndependent, targetIsCandidate else { return false }

        var sourceStat = stat()
        guard lstat(source, &sourceStat) == 0 else { return false }

        switch reference.kind {
        case .none:
            return false
        case .symbolicLink:
            guard (sourceStat.st_mode & S_IFMT) == S_IFLNK else { return false }
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let length = Darwin.readlink(source, &buffer, buffer.count - 1)
            guard length > 0 else { return false }
            let rawTarget = String(decoding: buffer.prefix(Int(length)).map(UInt8.init(bitPattern:)),
                                   as: UTF8.self)
            let resolvedPath = rawTarget.hasPrefix("/")
                ? rawTarget
                : URL(fileURLWithPath: source).deletingLastPathComponent()
                    .appendingPathComponent(rawTarget).standardizedFileURL.path
            var verifiedStat = stat()
            guard lstat(source, &verifiedStat) == 0,
                  verifiedStat.st_dev == sourceStat.st_dev,
                  verifiedStat.st_ino == sourceStat.st_ino,
                  (verifiedStat.st_mode & S_IFMT) == S_IFLNK else { return false }
            return InvokingUserIdentity.canonicalPath(resolvedPath) == target
        case .textualPath:
            guard (sourceStat.st_mode & S_IFMT) == S_IFREG,
                  sourceStat.st_size >= 0,
                  sourceStat.st_size <= 1_048_576 else { return false }
            let fd = Darwin.open(source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { return false }
            defer { Darwin.close(fd) }
            var openedStat = stat()
            guard fstat(fd, &openedStat) == 0,
                  openedStat.st_dev == sourceStat.st_dev,
                  openedStat.st_ino == sourceStat.st_ino,
                  (openedStat.st_mode & S_IFMT) == S_IFREG else { return false }
            var data = Data()
            var bytes = [UInt8](repeating: 0, count: 16_384)
            while data.count <= 1_048_576 {
                let count = bytes.withUnsafeMutableBytes {
                    Darwin.read(fd, $0.baseAddress, $0.count)
                }
                guard count >= 0 else { return false }
                if count == 0 { break }
                data.append(bytes, count: count)
            }
            guard data.count <= 1_048_576 else { return false }
            return dataContainsPathToken(data, path: reference.targetPath)
                || dataContainsPathToken(data, path: target)
        }
    }

    private func dataContainsPathToken(_ data: Data, path: String) -> Bool {
        let bytes = [UInt8](data)
        let needle = Array(path.utf8)
        guard !needle.isEmpty, needle.count <= bytes.count else { return false }
        let leadingBoundary = Set("\"'=:([,{ \t\r\n".utf8)
        let trailingBoundary = Set("\"',;:)]} \t\r\n".utf8)
        var start = 0
        while start + needle.count <= bytes.count {
            if bytes[start..<(start + needle.count)].elementsEqual(needle) {
                let leadingOK = start == 0 || leadingBoundary.contains(bytes[start - 1])
                let end = start + needle.count
                let trailingOK = end == bytes.count || trailingBoundary.contains(bytes[end])
                if leadingOK && trailingOK { return true }
            }
            start += 1
        }
        return false
    }

    private func canonicalSourceLocation(_ path: String) -> String? {
        guard path.hasPrefix("/"),
              !path.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..",
              let parent = InvokingUserIdentity.canonicalPath(
                url.deletingLastPathComponent().path) else { return nil }
        return URL(fileURLWithPath: parent).appendingPathComponent(name).path
    }

    /// Rejects untrusted discovery paths before any recursive filesystem work.
    /// Discovery is an analysis enhancement, not a way to widen a refused or
    /// active scanner candidate into a new cleanup authorization.
    private func prevalidatedDiscoveryScope(
        in analysis: CleanupAgentAnalysis
    ) -> CleanupAgentAnalysis {
        guard let snapshot = executionSnapshot else {
            return CleanupAgentAnalysis(summary: analysis.summary,
                                        recommendations: analysis.recommendations)
        }
        let parents = validatedDiscoveryParents(
            in: snapshot,
            proposedParentIDs: Set(analysis.discoveredCandidates.map(\.parentCandidateId)))
        let canonicalProposalCounts = Dictionary(
            grouping: analysis.discoveredCandidates.prefix(256).compactMap {
                proposal -> String? in
                guard proposal.path.hasPrefix("/"),
                      let canonical = InvokingUserIdentity.canonicalPath(proposal.path),
                      canonical == proposal.path else { return nil }
                return canonical
            }, by: { $0 }).mapValues(\.count)
        var seen = Set<String>()
        let scoped = analysis.discoveredCandidates.prefix(256).compactMap { proposal -> CleanupAgentDiscoveredCandidate? in
            guard let parent = parents[proposal.parentCandidateId],
                  proposal.path.hasPrefix("/"),
                  !proposal.path.unicodeScalars.contains(where: {
                      CharacterSet.controlCharacters.contains($0)
                  }),
                  let canonical = InvokingUserIdentity.canonicalPath(proposal.path),
                  canonical == proposal.path,
                  canonicalProposalCounts[canonical] == 1,
                  canonical != parent.path,
                  canonical.hasPrefix(parent.path.hasSuffix("/")
                                      ? parent.path : parent.path + "/"),
                  seen.insert(canonical).inserted else { return nil }
            return proposal
        }
        return CleanupAgentAnalysis(summary: analysis.summary,
                                    recommendations: analysis.recommendations,
                                    discoveredCandidates: scoped)
    }

    /// A matching path string is not authority: the scanner parent may have
    /// been replaced at the same pathname while the Agent was working. Only
    /// an unchanged identity + subtree from the original snapshot can scope a
    /// discovered child. This is repeated after measurement to close that
    /// additional race window.
    private func validatedDiscoveryParents(
        in snapshot: CleanupSnapshot,
        proposedParentIDs: Set<String>
    ) -> [String: CleanupPlanCandidate] {
        let itemByPath = Dictionary(snapshot.items.map { ($0.identity.path, $0) },
                                    uniquingKeysWith: { first, _ in first })
        return Dictionary(uniqueKeysWithValues: candidates.compactMap { candidate in
            guard proposedParentIDs.contains(candidate.id),
                  candidate.origin == .scanner,
                  !candidate.locked,
                  let pinned = itemByPath[candidate.path],
                  pinned.matchesCurrentScope() else { return nil }
            return (candidate.id, candidate)
        })
    }

    private func finishDegraded(_ error: Error, runId: UUID) {
        guard currentAgentRunId == runId else { return }
        agentProgress?.finishedAt = Date()
        agentState = .degraded(agent: analyzer.displayName, reason: error.localizedDescription)
    }

    private func markValidating(runId: UUID) {
        guard currentAgentRunId == runId else { return }
        agentProgress?.phase = .validating
    }

    private static func analyze(
        _ input: CleanupAgentAnalysisInput,
        with analyzer: any CleanupAgentAnalyzing,
        timeoutNanoseconds: UInt64,
        progress: @escaping @Sendable (CleanupAgentProgress.Phase, Int?) -> Void
    ) async throws -> CleanupAgentAnalysis {
        try await withThrowingTaskGroup(of: CleanupAgentAnalysis.self) { group in
            group.addTask {
                if let reporting = analyzer as? any CleanupAgentProgressAnalyzing {
                    return try await reporting.analyze(input, progress: progress)
                }
                return try await analyzer.analyze(input)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw CleanupAgentRunError.timedOut
            }
            guard let result = try await group.next() else {
                throw CleanupAgentRunError.timedOut
            }
            group.cancelAll()
            return result
        }
    }

    nonisolated private static func measuringDiscoveredCandidates(
        in analysis: CleanupAgentAnalysis
    ) -> CleanupAgentAnalysis {
        let deadline = Date().addingTimeInterval(2)
        var remainingEntries = 100_000
        var measured: [CleanupAgentDiscoveredCandidate] = []
        for proposal in analysis.discoveredCandidates {
            guard !Task.isCancelled, remainingEntries > 0, Date() < deadline else { break }
            guard let bytes = measuredAllocatedBytes(
                at: proposal.path,
                deadline: deadline,
                remainingEntries: &remainingEntries) else { continue }
            measured.append(CleanupAgentDiscoveredCandidate(
                parentCandidateId: proposal.parentCandidateId,
                path: proposal.path,
                sizeBytes: bytes,
                disposition: proposal.disposition,
                reason: proposal.reason,
                consequence: proposal.consequence,
                confidence: proposal.confidence,
                evidence: proposal.evidence,
                investigation: proposal.investigation))
        }
        return CleanupAgentAnalysis(
            summary: analysis.summary,
            recommendations: analysis.recommendations,
            discoveredCandidates: measured)
    }

    nonisolated private static func measuredAllocatedBytes(
        at path: String,
        deadline: Date,
        remainingEntries: inout Int
    ) -> Int64? {
        let fm = FileManager.default
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey,
        ]
        guard !Task.isCancelled, remainingEntries > 0, Date() < deadline else { return nil }
        guard let rootValues = try? url.resourceValues(forKeys: keys),
              rootValues.isSymbolicLink != true else { return nil }
        remainingEntries -= 1
        guard !Task.isCancelled, Date() < deadline else { return nil }
        if rootValues.isDirectory != true {
            return Int64(rootValues.totalFileAllocatedSize
                         ?? rootValues.fileAllocatedSize ?? 0)
        }
        guard remainingEntries > 0 else { return nil }
        guard let enumerator = fm.enumerator(
            at: url, includingPropertiesForKeys: Array(keys),
            options: [], errorHandler: { _, _ in true }) else { return nil }
        var bytes: Int64 = 0
        while true {
            guard !Task.isCancelled, remainingEntries > 0, Date() < deadline else { return nil }
            guard let next = enumerator.nextObject() else { break }
            guard !Task.isCancelled, Date() < deadline else { return nil }
            guard let child = next as? URL else { continue }
            remainingEntries -= 1
            guard !Task.isCancelled, Date() < deadline else { return nil }
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            bytes += Int64(values.totalFileAllocatedSize
                           ?? values.fileAllocatedSize ?? 0)
        }
        return bytes
    }

    private func setAll(selected shouldSelect: Bool) {
        guard var selection else { return }
        for candidate in candidates where !candidate.locked {
            if selection.isTicked(candidate.path) != shouldSelect { selection.toggle(candidate.path) }
            syncOverride(for: candidate, selection: selection)
        }
        self.selection = selection
        revision += 1
    }

    private func syncOverride(for candidate: CleanupPlanCandidate,
                              selection: CleanSelection) {
        let recommendedSelection = recommendation(for: candidate.id).disposition == .delete
            && !candidate.locked
        if selection.isTicked(candidate.path) == recommendedSelection {
            userOverrides.remove(candidate.id)
        } else {
            userOverrides.insert(candidate.id)
        }
    }

    private func policyDisposition(
        proposed: CleanupRecommendationDisposition,
        candidate: CleanupPlanCandidate
    ) -> (disposition: CleanupRecommendationDisposition, reason: String?, consequence: String?) {
        if candidate.locked {
            return (.keep, nil, nil)
        }

        // A parent that contains independently judged candidates is not one
        // homogeneous cleanup unit. Preserve it and let the leaf candidates
        // carry the decisions. This prevents a kept child from being deleted
        // through an Agent-selected ancestor.
        let prefix = candidate.path.hasSuffix("/") ? candidate.path : candidate.path + "/"
        if proposed == .delete,
           candidates.contains(where: { $0.id != candidate.id && $0.path.hasPrefix(prefix) }) {
            return (
                .keep,
                NSLocalizedString("Burrow kept this parent folder because the scan contains child items with their own judgments. Clean the verified child items instead.", comment: "coarse cleanup candidate policy"),
                NSLocalizedString("Keeping the parent protects unlisted or differently judged content inside it.", comment: "coarse cleanup candidate consequence")
            )
        }

        return (proposed, nil, nil)
    }

    private static func candidateId(planId: UUID, path: String, identityToken: String) -> String {
        let digest = SHA256.hash(data: Data("\(planId.uuidString)\u{1f}\(path)\u{1f}\(identityToken)".utf8))
        return "cand-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func lockReasonText(_ reason: CleanSelection.LockReason?) -> String {
        switch reason {
        case .appOpen(let app): return String(format: NSLocalizedString("%@ is open, so this candidate must stay.", comment: ""), app)
        case .systemBusy: return NSLocalizedString("A system service is using this candidate.", comment: "")
        case .notCleanable(let reason): return reason
        case .none: return NSLocalizedString("Burrow's safety policy keeps this candidate.", comment: "")
        }
    }
}

/// Carries a non-owning MainActor reference through the Agent's Sendable
/// progress callback without making the analysis task retain its store.
private final class WeakCleanupPlanStore: @unchecked Sendable {
    weak var value: CleanupPlanStore?

    @MainActor init(_ value: CleanupPlanStore) {
        self.value = value
    }
}
