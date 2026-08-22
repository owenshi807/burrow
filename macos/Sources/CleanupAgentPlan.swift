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

enum CleanupRecommendationDisposition: String, Codable, Sendable, CaseIterable {
    case delete
    case keep
    case humanIntentRequired = "human_intent_required"
}

enum CleanupRecommendationOrigin: String, Codable, Sendable {
    case scanner
    case agent
    case user
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

struct CleanupAgentRecommendation: Codable, Equatable, Sendable {
    let candidateId: String
    let disposition: CleanupRecommendationDisposition
    let reason: String
    let consequence: String
    let confidence: Double
    let evidence: [CleanupAgentEvidence]
}

struct CleanupAgentAnalysis: Codable, Equatable, Sendable {
    let summary: String
    let recommendations: [CleanupAgentRecommendation]
}

struct CleanupAgentCandidateInput: Codable, Equatable, Sendable {
    let candidateId: String
    let path: String
    let category: String
    let sizeBytes: Int64
    let itemCount: Int?
    let runningApp: String?
    let sensitivePathHint: Bool
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
}

struct CleanupCandidateRecommendation: Equatable {
    let origin: CleanupRecommendationOrigin
    let disposition: CleanupRecommendationDisposition
    let reason: String
    let consequence: String
    let confidence: Double?
    let evidence: [CleanupAgentEvidence]
    let agentRunId: UUID?
}

struct CleanupDecisionSection: Identifiable, Equatable {
    let disposition: CleanupRecommendationDisposition
    let category: String
    let candidates: [CleanupPlanCandidate]
    var id: String { disposition.rawValue + "\u{1f}" + category }
}

struct CleanupAgentProgress: Equatable {
    enum Phase: Equatable {
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
            "Codex did not finish within 10 minutes. Nothing was changed. Retry when the Agent is available.",
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

    private var pathToCandidateId: [String: String] = [:]
    private var currentAgentRunId: UUID?
    private var analysisTask: Task<Void, Never>?
    private let analyzer: any CleanupAgentAnalyzing
    private let analysisTimeoutNanoseconds: UInt64

    init(analyzer: any CleanupAgentAnalyzing = CodexCleanupAgentAdapter(),
         analysisTimeoutNanoseconds: UInt64 = 600_000_000_000) {
        self.analyzer = analyzer
        self.analysisTimeoutNanoseconds = analysisTimeoutNanoseconds
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
        agentProgress = nil
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
                    locked: effectiveLocks[item.path] != nil)
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
                    runningApp: candidate.locked ? "locked or active" : nil,
                    sensitivePathHint: SensitiveRemnantMatcher.isSensitive(candidate.path))
            })
        agentState = .analyzing(agent: analyzer.displayName)
        agentProgress = CleanupAgentProgress(
            startedAt: Date(), candidateCount: candidates.count,
            phase: .investigating, reviewedCount: nil, finishedAt: nil)
        let timeout = analysisTimeoutNanoseconds
        analysisTask = Task { [weak self, analyzer] in
            do {
                let analysis = try await Self.analyze(input, with: analyzer, timeoutNanoseconds: timeout)
                guard !Task.isCancelled else { return }
                self?.markValidating(runId: runId)
                // The validation is real and normally sub-frame. Keep the
                // named phase visible briefly so the transition is legible,
                // without pretending that it represents a percentage.
                try await Task.sleep(nanoseconds: 240_000_000)
                guard !Task.isCancelled else { return }
                self?.apply(analysis, runId: runId)
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
        userOverrides.insert(id)
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
            userOverrides.insert(candidate.id)
            if selection.isTicked(candidate.path) != shouldSelect {
                selection.toggle(candidate.path)
            }
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
        return String(
            format: NSLocalizedString("Reviewed %d candidates. Recommend cleaning %d (%@), keeping %d (%@), and leaving %d (%@) for your decision.", comment: "derived cleanup Agent summary"),
            candidates.count,
            deleteCount, Fmt.bytes(recommendationBytes(for: .delete)),
            keepCount, Fmt.bytes(recommendationBytes(for: .keep)),
            intentCount, Fmt.bytes(recommendationBytes(for: .humanIntentRequired)))
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
                    grouped[category].map { (category: category, value: $0) }
                })
            return categories.map { candidates -> CleanupDecisionSection in
                CleanupDecisionSection(disposition: disposition,
                                       category: candidates[0].category,
                                       candidates: candidates)
            }
        }
    }

    private func apply(_ analysis: CleanupAgentAnalysis, runId: UUID) {
        guard currentAgentRunId == runId else { return }
        let known = Set(candidates.map(\.id))
        var seen = Set<String>()
        var accepted = 0
        var nextSelection = selection

        for proposal in analysis.recommendations {
            guard known.contains(proposal.candidateId), seen.insert(proposal.candidateId).inserted,
                  !proposal.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !proposal.consequence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !proposal.evidence.isEmpty,
                  proposal.disposition == .keep || proposal.evidence.contains(where: {
                      $0.basis == .observation || $0.basis == .relationship
                  }) else { continue }
            let candidate = candidates.first { $0.id == proposal.candidateId }
            let policy: (disposition: CleanupRecommendationDisposition, reason: String?, consequence: String?) = candidate.map {
                policyDisposition(proposed: proposal.disposition, candidate: $0)
            } ?? (disposition: proposal.disposition, reason: nil, consequence: nil)
            let disposition = policy.disposition
            recommendations[proposal.candidateId] = CleanupCandidateRecommendation(
                origin: .agent, disposition: disposition,
                reason: policy.reason ?? proposal.reason,
                consequence: policy.consequence ?? proposal.consequence,
                confidence: min(max(proposal.confidence, 0), 1),
                evidence: Array(proposal.evidence.prefix(12)), agentRunId: runId)
            accepted += 1

            // Merge at candidate granularity. Editing one row while Codex is
            // working protects that row only; unrelated rows still receive
            // their Agent selection. The run ID already rejects results from
            // an obsolete/reloaded plan, so a global revision gate would make
            // one user edit leave scanner checkboxes under Agent judgments.
            guard !userOverrides.contains(proposal.candidateId),
                  let candidate, !candidate.locked, var value = nextSelection else { continue }
            let shouldSelect = disposition == .delete
            if value.isTicked(candidate.path) != shouldSelect { value.toggle(candidate.path) }
            nextSelection = value
        }
        selection = nextSelection
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
        timeoutNanoseconds: UInt64
    ) async throws -> CleanupAgentAnalysis {
        try await withThrowingTaskGroup(of: CleanupAgentAnalysis.self) { group in
            group.addTask { try await analyzer.analyze(input) }
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

    private func setAll(selected shouldSelect: Bool) {
        guard var selection else { return }
        for candidate in candidates where !candidate.locked {
            if selection.isTicked(candidate.path) != shouldSelect { selection.toggle(candidate.path) }
            userOverrides.insert(candidate.id)
        }
        self.selection = selection
        revision += 1
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
