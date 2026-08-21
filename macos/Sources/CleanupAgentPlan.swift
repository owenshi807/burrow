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

struct CleanupAgentEvidence: Codable, Equatable, Sendable, Identifiable {
    let label: String
    let detail: String
    var id: String { label + "\u{1f}" + detail }
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
    @Published private(set) var revision = 0
    @Published private(set) var candidates: [CleanupPlanCandidate] = []
    @Published private(set) var recommendations: [String: CleanupCandidateRecommendation] = [:]
    @Published private(set) var selection: CleanSelection?
    @Published private(set) var selectedCandidateId: String?
    @Published private(set) var agentState: AgentState = .idle
    @Published private(set) var userOverrides: Set<String> = []

    private var pathToCandidateId: [String: String] = [:]
    private var currentAgentRunId: UUID?
    private var analysisTask: Task<Void, Never>?
    private let analyzer: any CleanupAgentAnalyzing

    init(analyzer: any CleanupAgentAnalyzing = CodexCleanupAgentAdapter()) {
        self.analyzer = analyzer
    }

    deinit { analysisTask?.cancel() }

    var agentDisplayName: String { analyzer.displayName }

    func load(list: CleanList,
              snapshot: CleanupSnapshot,
              locked: [String: CleanSelection.LockReason],
              hasAgentConsent: Bool) {
        analysisTask?.cancel()
        planId = UUID()
        revision = 1
        userOverrides = []
        currentAgentRunId = nil
        // Paths are the identity shared by selection, authorization and the
        // Agent. The scanner has emitted duplicate paths in production, so
        // canonicalize here too: callers can construct a CleanList directly
        // without passing through the text parser.
        let canonicalList = list.deduplicatedByPath()
        selection = CleanSelection(list: canonicalList, locked: locked)

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
                    locked: locked[item.path] != nil)
            }
        }
        pathToCandidateId = Dictionary(candidates.map { ($0.path, $0.id) },
                                       uniquingKeysWith: { first, _ in first })
        recommendations = Dictionary(candidates.map { candidate in
            let disposition: CleanupRecommendationDisposition = candidate.locked ? .keep : .delete
            let reason = candidate.locked
                ? Self.lockReasonText(locked[candidate.path])
                : NSLocalizedString("The deterministic scanner classified this as removable cache data.", comment: "")
            return (candidate.id, CleanupCandidateRecommendation(
                origin: .scanner, disposition: disposition, reason: reason,
                consequence: CleanReviewView.consequence(for: candidate.category),
                confidence: nil, evidence: [], agentRunId: nil))
        }, uniquingKeysWith: { first, _ in first })
        selectedCandidateId = candidates.first?.id
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
        analysisTask = Task { [weak self, analyzer] in
            do {
                let analysis = try await analyzer.analyze(input)
                guard !Task.isCancelled else { return }
                self?.apply(analysis, runId: runId, baseRevision: baseRevision)
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
        for candidate in targets where selection.isTicked(candidate.path) != shouldSelect {
            selection.toggle(candidate.path)
            userOverrides.insert(candidate.id)
        }
        self.selection = selection
        revision += 1
    }

    func selectAll() { setAll(selected: true) }
    func deselectAll() { setAll(selected: false) }

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

    var canUseAgentCTA: Bool {
        if case .ready = agentState { return userOverrides.isEmpty }
        return false
    }

    var sections: [CleanupDecisionSection] {
        let order: [CleanupRecommendationDisposition] = [.delete, .keep, .humanIntentRequired]
        return order.flatMap { disposition in
            let matching = candidates.filter { recommendation(for: $0.id).disposition == disposition }
            let categories: [[CleanupPlanCandidate]] = CleanImpactRanker.sorted(
                Dictionary(grouping: matching, by: \.category).map { (category: $0.key, value: $0.value) })
            return categories.map { candidates -> CleanupDecisionSection in
                CleanupDecisionSection(disposition: disposition,
                                       category: candidates[0].category,
                                       candidates: candidates)
            }
        }
    }

    private func apply(_ analysis: CleanupAgentAnalysis, runId: UUID, baseRevision: Int) {
        guard currentAgentRunId == runId else { return }
        let known = Set(candidates.map(\.id))
        var seen = Set<String>()
        var accepted = 0
        var nextSelection = selection

        for proposal in analysis.recommendations {
            guard known.contains(proposal.candidateId), seen.insert(proposal.candidateId).inserted,
                  !proposal.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let candidate = candidates.first { $0.id == proposal.candidateId }
            let disposition = candidate?.locked == true ? .keep : proposal.disposition
            recommendations[proposal.candidateId] = CleanupCandidateRecommendation(
                origin: .agent, disposition: disposition,
                reason: proposal.reason, consequence: proposal.consequence,
                confidence: min(max(proposal.confidence, 0), 1),
                evidence: Array(proposal.evidence.prefix(12)), agentRunId: runId)
            accepted += 1

            // A recommendation may set the staged selection only when it was
            // computed for the current revision and the user has not touched
            // this candidate. Explanations can still arrive after an edit.
            guard baseRevision == revision, !userOverrides.contains(proposal.candidateId),
                  let candidate, !candidate.locked, var value = nextSelection else { continue }
            let shouldSelect = disposition == .delete
            if value.isTicked(candidate.path) != shouldSelect { value.toggle(candidate.path) }
            nextSelection = value
        }
        selection = nextSelection
        revision += accepted > 0 ? 1 : 0
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
        agentState = .degraded(agent: analyzer.displayName, reason: error.localizedDescription)
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
