import XCTest
@testable import Burrow

private struct FakeCleanupAnalyzer: CleanupAgentAnalyzing {
    let displayName = "Test Agent"
    let delay: UInt64
    let makeAnalysis: @Sendable (CleanupAgentAnalysisInput) -> CleanupAgentAnalysis

    func analyze(_ input: CleanupAgentAnalysisInput) async throws -> CleanupAgentAnalysis {
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return makeAnalysis(input)
    }
}

@MainActor
final class CleanupAgentPlanTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-agent-plan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: try XCTUnwrap(InvokingUserIdentity.canonicalPath(root.path)))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testAgentRecommendationsUpdateOneCanonicalSelection() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "one keep, one delete", recommendations: [
                .init(candidateId: input.candidates[0].candidateId, disposition: .keep,
                      reason: "Still referenced by the installed app.",
                      consequence: "Keeping it preserves the active model.", confidence: 0.98,
                      evidence: [.init(label: "Installed app", detail: "Reference found")]),
                .init(candidateId: input.candidates[1].candidateId, disposition: .delete,
                      reason: "Superseded build output.", consequence: "Rebuilds on demand.",
                      confidence: 0.94, evidence: [.init(label: "Filesystem", detail: "Verified")]),
            ])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilReady(store)

        XCTAssertFalse(store.isSelected(store.candidates[0]))
        XCTAssertTrue(store.isSelected(store.candidates[1]))
        XCTAssertEqual(store.recommendation(for: store.candidates[0].id).origin, .agent)
        XCTAssertEqual(store.sections.first?.disposition, .delete)
        XCTAssertTrue(store.canUseAgentCTA)
    }

    func testLateAgentResultNeverOverwritesUserOverride() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 80_000_000) { input in
            CleanupAgentAnalysis(summary: "delete both", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .delete,
                      reason: "Rebuildable.", consequence: "Recreated later.",
                      confidence: 0.9, evidence: [.init(label: "Filesystem", detail: "Verified")])
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        let first = try XCTUnwrap(store.candidates.first)
        store.toggleCandidate(first.id) // scanner selected → explicit user keep
        try await waitUntilReady(store)

        XCTAssertFalse(store.isSelected(first), "late Agent output cannot replace a user decision")
        XCTAssertEqual(store.recommendation(for: first.id).origin, .agent,
                       "the explanation may still arrive")
        XCTAssertFalse(store.canUseAgentCTA)
    }

    func testOneUserOverrideDoesNotBlockAgentSelectionForOtherCandidates() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 80_000_000) { input in
            CleanupAgentAnalysis(summary: "keep both", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .keep,
                      reason: "Still needed.", consequence: "Keeping preserves it.",
                      confidence: 0.9,
                      evidence: [.init(label: "Reference", detail: "Verified")])
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        let first = store.candidates[0]
        let second = store.candidates[1]
        store.toggleCandidate(first.id) // explicit keep while analysis is running
        try await waitUntilReady(store)

        XCTAssertFalse(store.isSelected(first), "the user's row remains untouched")
        XCTAssertFalse(store.isSelected(second), "the unrelated row adopts the Agent keep judgment")
        XCTAssertTrue(store.userOverrides.contains(first.id))
        XCTAssertFalse(store.userOverrides.contains(second.id))
    }

    func testAgentProgressExposesRealStagesCandidateCountAndCompletion() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 60_000_000) { input in
            CleanupAgentAnalysis(summary: "done", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .delete,
                      reason: "Rebuildable.", consequence: "Recreated later.",
                      confidence: 0.9, evidence: [.init(label: "Filesystem", detail: "Verified")])
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()

        XCTAssertEqual(store.agentProgress?.candidateCount, 2)
        XCTAssertEqual(store.agentProgress?.phase, .investigating)
        try await waitUntilProgress(store, phase: .validating)
        try await waitUntilReady(store)

        XCTAssertEqual(store.agentProgress?.phase, .completed)
        XCTAssertEqual(store.agentProgress?.reviewedCount, 2)
        XCTAssertGreaterThan(store.agentProgress?.elapsed() ?? 0, 0)
    }

    func testAgentTimeoutBecomesVisibleFailureAndDoesNotChangeSelection() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 2_000_000_000) { input in
            CleanupAgentAnalysis(summary: "late", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .keep,
                      reason: "Late.", consequence: "None.", confidence: 1,
                      evidence: [.init(label: "Filesystem", detail: "Verified")])
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer, analysisTimeoutNanoseconds: 5_000_000)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        let originalSelectedCount = store.selectedCount
        let originalSelectedBytes = store.selectedBytes
        store.startAgentAnalysis()
        try await waitUntilFinished(store)

        guard case .degraded(_, let reason) = store.agentState else {
            return XCTFail("timeout must become a visible degraded state")
        }
        XCTAssertTrue(reason.contains("10"))
        XCTAssertEqual(store.selectedCount, originalSelectedCount)
        XCTAssertEqual(store.selectedBytes, originalSelectedBytes)
        XCTAssertEqual(store.agentProgress?.phase, .investigating)
    }

    func testLockedCandidateCannotBeSelectedByAgent() async throws {
        let fixture = try makeFixture()
        let lockedPath = fixture.list.categories[0].items[0].path
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "unsafe proposal", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .delete,
                      reason: "Delete.", consequence: "None.", confidence: 1,
                      evidence: [.init(label: "Filesystem", detail: "Verified")])
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot,
                   locked: [lockedPath: .appOpen(appName: "WaveScribe")], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilReady(store)

        let locked = try XCTUnwrap(store.candidates.first { $0.path == lockedPath })
        XCTAssertFalse(store.isSelected(locked))
        XCTAssertEqual(store.recommendation(for: locked.id).disposition, .keep)
    }

    func testLoadDeduplicatesOnePathReportedByMultipleScannerCategories() throws {
        let shared = root.appendingPathComponent("shared-cache")
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: false)
        let duplicateList = CleanList(
            categories: [
                .init(name: "App caches", items: [
                    .init(path: shared.path, sizeBytes: 2_000, sizeText: "2KB", itemCount: 2),
                ]),
                .init(name: "Application Support", items: [
                    .init(path: shared.path, sizeBytes: 2_000, sizeText: "2KB", itemCount: 2),
                ]),
            ], summaryTotalText: "2KB", summaryItemCount: 2)
        let snapshot = try CleanupSnapshot.capture(list: duplicateList, approvedRootURLs: [root])
        let store = CleanupPlanStore(analyzer: FakeCleanupAnalyzer(delay: 0) { _ in
            CleanupAgentAnalysis(summary: "", recommendations: [])
        })

        store.load(list: duplicateList, snapshot: snapshot, locked: [:], hasAgentConsent: false)

        XCTAssertEqual(store.candidates.count, 1)
        XCTAssertEqual(store.candidates.first?.path, shared.path)
        XCTAssertEqual(store.sections.flatMap(\.candidates).count, 1)
        XCTAssertEqual(store.totalCount, 1)
        XCTAssertEqual(store.selectedCount, 1)
        XCTAssertEqual(store.selectedBytes, 2_000)
    }

    func testReviewStartsWithPlanWideInspectorAndKeepsStableCategoryOrder() async throws {
        let categoryNames = ["Browsers", "App caches", "Developer tools", "Applications"]
        var categories: [CleanList.Category] = []
        for (index, name) in categoryNames.enumerated() {
            let path = root.appendingPathComponent("category-\(index)")
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            categories.append(.init(name: name, items: [
                .init(path: path.path, sizeBytes: Int64(index + 1), sizeText: "1B", itemCount: 1),
            ]))
        }
        let list = CleanList(categories: categories, summaryTotalText: "4B", summaryItemCount: 4)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "Do not trust my 999-item arithmetic.", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .delete,
                      reason: "Verified leaf cache.", consequence: "Rebuilds on demand.",
                      confidence: 0.9,
                      evidence: [.init(label: "Filesystem", detail: "Leaf cache verified")])
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: list, snapshot: snapshot, locked: [:], hasAgentConsent: true)

        XCTAssertNil(store.selectedCandidateId, "the inspector starts with the full-plan judgment")
        store.startAgentAnalysis()
        try await waitUntilReady(store)

        XCTAssertEqual(store.sections.filter { $0.disposition == .delete }.map(\.category), categoryNames)
        XCTAssertTrue(store.overallRecommendationText.contains("Reviewed 4 candidates"))
        XCTAssertFalse(store.overallRecommendationText.contains("999"),
                       "authoritative overview arithmetic is derived, never copied from model prose")
    }

    func testLargeLocalModelRequiresHumanDecisionEvenWhenAgentSuggestsDelete() async throws {
        let model = root.appendingPathComponent("huggingface-whisper-model")
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: false)
        let list = CleanList(categories: [.init(name: "Developer tools", items: [
            .init(path: model.path, sizeBytes: 3_860_000_000, sizeText: "3.86GB", itemCount: 5),
        ])], summaryTotalText: "3.86GB", summaryItemCount: 5)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "Unused model cache.", recommendations: [
                .init(candidateId: input.candidates[0].candidateId, disposition: .delete,
                      reason: "No active consumer found.", consequence: "Downloads again when needed.",
                      confidence: 0.95,
                      evidence: [.init(label: "Consumer check", detail: "No installed reference found")]),
            ])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: list, snapshot: snapshot, locked: [:], hasAgentConsent: true)

        let baseline = try XCTUnwrap(store.candidates.first)
        XCTAssertEqual(store.recommendation(for: baseline.id).disposition, .humanIntentRequired,
                       "large-model policy applies before Codex returns")
        XCTAssertFalse(store.isSelected(baseline))
        store.startAgentAnalysis()
        try await waitUntilReady(store)

        let candidate = try XCTUnwrap(store.candidates.first)
        XCTAssertEqual(store.recommendation(for: candidate.id).disposition, .humanIntentRequired)
        XCTAssertFalse(store.isSelected(candidate), "large offline models never enter the plan without a user choice")
        store.toggleCandidate(candidate.id)
        XCTAssertTrue(store.isSelected(candidate), "the user can include a verified zombie model")
    }

    func testAgentCannotDeleteParentThatContainsIndependentlyJudgedChildren() async throws {
        let parent = root.appendingPathComponent("GoogleUpdater")
        let child = parent.appendingPathComponent("crx_cache")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let list = CleanList(categories: [.init(name: "Browsers", items: [
            .init(path: parent.path, sizeBytes: 800, sizeText: "800B", itemCount: 2),
            .init(path: child.path, sizeBytes: 700, sizeText: "700B", itemCount: 1),
        ])], summaryTotalText: "800B", summaryItemCount: 2)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "Cache found.", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .delete,
                      reason: "Rebuildable.", consequence: "Downloads again.", confidence: 0.9,
                      evidence: [.init(label: "Filesystem", detail: "Inspected")])
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: list, snapshot: snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilReady(store)

        let parentCandidate = try XCTUnwrap(store.candidates.first { $0.path == parent.path })
        let childCandidate = try XCTUnwrap(store.candidates.first { $0.path == child.path })
        XCTAssertEqual(store.recommendation(for: parentCandidate.id).disposition, .keep)
        XCTAssertEqual(store.recommendation(for: childCandidate.id).disposition, .delete)
        XCTAssertFalse(store.isSelected(parentCandidate))
        XCTAssertTrue(store.isSelected(childCandidate))
        store.toggleCandidate(parentCandidate.id)
        XCTAssertFalse(store.isSelected(parentCandidate),
                       "a coarse parent cannot be manually reintroduced over child judgments")
    }

    func testCategoryChoiceProtectsEveryCandidateFromLateAgentMerge() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 80_000_000) { input in
            CleanupAgentAnalysis(summary: "keep both", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .keep,
                      reason: "Referenced.", consequence: "Keeping preserves it.", confidence: 0.9,
                      evidence: [.init(label: "Reference", detail: "Verified")])
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        store.toggleCategory("AI Tools")
        store.toggleCategory("AI Tools") // explicit category-level include
        try await waitUntilReady(store)

        let candidate = try XCTUnwrap(store.candidates.first { $0.category == "AI Tools" })
        XCTAssertTrue(store.userOverrides.contains(candidate.id))
        XCTAssertTrue(store.isSelected(candidate), "the explicit category decision wins")
    }

    func testAgentInProgressOrDegradedCannotConfirmScannerFallback() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 2_000_000_000) { _ in
            CleanupAgentAnalysis(summary: "", recommendations: [])
        }
        let store = CleanupPlanStore(analyzer: analyzer, analysisTimeoutNanoseconds: 5_000_000)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        XCTAssertFalse(store.canConfirmPlan)
        try await waitUntilFinished(store)
        XCTAssertFalse(store.canConfirmPlan)
    }

    func testPartialUnknownAndDuplicateRecommendationsAreIgnoredAndDegradeShortcut() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            let known = input.candidates[0].candidateId
            return CleanupAgentAnalysis(summary: "mixed payload", recommendations: [
                .init(candidateId: "unknown", disposition: .delete, reason: "No.",
                      consequence: "No.", confidence: 1,
                      evidence: [.init(label: "Filesystem", detail: "Verified")]),
                .init(candidateId: known, disposition: .keep, reason: "First valid answer.",
                      consequence: "Keep.", confidence: 0.8,
                      evidence: [.init(label: "Filesystem", detail: "Verified")]),
                .init(candidateId: known, disposition: .delete, reason: "Duplicate.",
                      consequence: "Delete.", confidence: 1,
                      evidence: [.init(label: "Filesystem", detail: "Verified")]),
            ])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilFinished(store)

        let first = store.candidates[0]
        XCTAssertEqual(store.recommendation(for: first.id).reason, "First valid answer.")
        XCTAssertNil(store.recommendations["unknown"])
        XCTAssertFalse(store.canUseAgentCTA)
        guard case .degraded(_, let reason) = store.agentState else {
            return XCTFail("partial analysis must be visibly degraded")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertTrue(reason.contains("1"))
        XCTAssertTrue(reason.contains("2"))
    }

    func testLiveCodexReturnsSchemaValidCandidateJudgmentsWhenEnabled() async throws {
        guard Foundation.ProcessInfo.processInfo.environment["BURROW_RUN_CODEX_INTEGRATION"] == "1" else {
            throw XCTSkip("Set BURROW_RUN_CODEX_INTEGRATION=1 for the authenticated Codex smoke test")
        }
        let input = CleanupAgentAnalysisInput(
            planId: UUID().uuidString, planRevision: 1,
            candidates: [
                .init(candidateId: "cand-active-model",
                      path: "/Applications/WaveScribe.app/Contents/Resources/qwen3-speech/models/current",
                      category: "AI Tools", sizeBytes: 2_000_000_000, itemCount: 12,
                      runningApp: "WaveScribe", sensitivePathHint: false),
                .init(candidateId: "cand-old-build",
                      path: "/private/tmp/WaveScribe-old-build/DerivedData",
                      category: "Developer tools", sizeBytes: 800_000_000, itemCount: 4000,
                      runningApp: nil, sensitivePathHint: false),
            ])
        let result = try await CodexCleanupAgentAdapter().analyze(input)
        XCTAssertEqual(Set(result.recommendations.map(\.candidateId)),
                       Set(input.candidates.map(\.candidateId)))
        XCTAssertTrue(result.recommendations.allSatisfy { (0...1).contains($0.confidence) })
        XCTAssertTrue(result.recommendations.allSatisfy { !$0.reason.isEmpty })
    }

    private func makeFixture() throws -> (list: CleanList, snapshot: CleanupSnapshot) {
        let active = root.appendingPathComponent("active-model")
        let old = root.appendingPathComponent("old-build")
        try FileManager.default.createDirectory(at: active, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: false)
        let list = CleanList(
            categories: [
                .init(name: "AI Tools", items: [
                    .init(path: active.path, sizeBytes: 2_000, sizeText: "2KB", itemCount: 2),
                ]),
                .init(name: "Developer tools", items: [
                    .init(path: old.path, sizeBytes: 4_000, sizeText: "4KB", itemCount: 4),
                ]),
            ], summaryTotalText: "6KB", summaryItemCount: 6)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        return (list, snapshot)
    }

    private func waitUntilReady(_ store: CleanupPlanStore) async throws {
        for _ in 0..<100 {
            if case .ready = store.agentState { return }
            if case .degraded(_, let reason) = store.agentState {
                XCTFail(reason); return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Agent analysis timed out")
    }

    private func waitUntilFinished(_ store: CleanupPlanStore) async throws {
        for _ in 0..<100 {
            switch store.agentState {
            case .ready, .degraded: return
            default: break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Agent analysis timed out")
    }

    private func waitUntilProgress(_ store: CleanupPlanStore,
                                   phase: CleanupAgentProgress.Phase) async throws {
        for _ in 0..<100 {
            if store.agentProgress?.phase == phase { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Agent progress never reached \(phase)")
    }
}
