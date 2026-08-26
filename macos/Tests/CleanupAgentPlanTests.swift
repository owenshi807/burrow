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
                      evidence: [.init(label: "Installed app", detail: "Reference found")],
                      investigation: .verifiedKeepFixture),
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

    func testMatchingAgentRecommendationClearsRedundantOverrideWithoutAffectingOtherCandidates() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 80_000_000) { input in
            CleanupAgentAnalysis(summary: "keep both", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .keep,
                      reason: "Still needed.", consequence: "Keeping preserves it.",
                      confidence: 0.9,
                      evidence: [.init(label: "Reference", detail: "Verified")],
                      investigation: .verifiedKeepFixture)
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
        XCTAssertFalse(store.userOverrides.contains(first.id),
                       "a matching final Agent judgment makes the provisional override redundant")
        XCTAssertFalse(store.userOverrides.contains(second.id))
        XCTAssertTrue(store.canUseAgentCTA)
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
        XCTAssertEqual(store.agentProgress?.phase, .routing)
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
        XCTAssertEqual(
            reason,
            NSLocalizedString(
                "Codex did not finish within the analysis time limit. Nothing was changed. Retry when the Agent is available.",
                comment: "cleanup Agent timeout"
            )
        )
        XCTAssertEqual(store.selectedCount, originalSelectedCount)
        XCTAssertEqual(store.selectedBytes, originalSelectedBytes)
        XCTAssertEqual(store.agentProgress?.phase, .routing)
    }

    func testStoppingAgentCancelsRunAndPreservesScannerPlan() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 2_000_000_000) { input in
            CleanupAgentAnalysis(summary: "late", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .keep,
                      reason: "Late.", consequence: "None.", confidence: 1,
                      evidence: [.init(label: "Filesystem", detail: "Verified")])
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        let originalSelectedCount = store.selectedCount
        let originalSelectedBytes = store.selectedBytes

        store.startAgentAnalysis()
        store.stopAgentAnalysis()

        guard case .stopped(let agent) = store.agentState else {
            return XCTFail("stopping must become visible immediately")
        }
        XCTAssertEqual(agent, "Test Agent")
        XCTAssertEqual(store.selectedCount, originalSelectedCount)
        XCTAssertEqual(store.selectedBytes, originalSelectedBytes)
        XCTAssertTrue(store.canConfirmPlan)

        try await Task.sleep(nanoseconds: 100_000_000)
        guard case .stopped = store.agentState else {
            return XCTFail("a cancelled late result must not overwrite stopped state")
        }
        XCTAssertTrue(store.candidates.allSatisfy {
            store.recommendation(for: $0.id).origin == .scanner
        })
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

    func testReviewStartsWithPlanWideInspectorAndOrdersDeleteGroupsBySize() async throws {
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

        XCTAssertEqual(store.sections.filter { $0.disposition == .delete }.map(\.category),
                       ["Applications", "Developer tools", "App caches", "Browsers"])
        let localizedSummary = String(
            format: NSLocalizedString(
                "Reviewed %d candidates. Recommend cleaning %d (%@), keeping %d (%@), and leaving %d (%@) for your decision.",
                comment: "derived cleanup Agent summary"),
            4,
            store.recommendationCount(for: .delete),
            Fmt.bytes(store.recommendationBytes(for: .delete)),
            store.recommendationCount(for: .keep),
            Fmt.bytes(store.recommendationBytes(for: .keep)),
            store.recommendationCount(for: .humanIntentRequired),
            Fmt.bytes(store.recommendationBytes(for: .humanIntentRequired)))
        XCTAssertEqual(store.overallRecommendationText, localizedSummary)
        XCTAssertFalse(store.overallRecommendationText.contains("999"),
                       "authoritative overview arithmetic is derived, never copied from model prose")
    }

    func testSizeTypeAndPathDoNotOverrideEvidenceBackedAgentJudgment() async throws {
        let asset = root.appendingPathComponent("large-offline-asset/objects/current")
        try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: true)
        let list = CleanList(categories: [.init(name: "Developer tools", items: [
            .init(path: asset.path, sizeBytes: 5_000_000_000, sizeText: "5GB", itemCount: 5),
        ])], summaryTotalText: "5GB", summaryItemCount: 5)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "Unused recoverable asset.", recommendations: [
                .init(candidateId: input.candidates[0].candidateId, disposition: .delete,
                      reason: "The installed owner points to a different current asset.",
                      consequence: "This retired asset can be downloaded again when needed.",
                      confidence: 0.95,
                      evidence: [.init(
                        basis: .relationship,
                        label: "Current version reference",
                        detail: "The owner's inspected manifest identifies another asset as current."
                      )]),
            ])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: list, snapshot: snapshot, locked: [:], hasAgentConsent: true)

        let baseline = try XCTUnwrap(store.candidates.first)
        XCTAssertEqual(store.recommendation(for: baseline.id).disposition, .delete)
        XCTAssertTrue(store.isSelected(baseline))
        store.startAgentAnalysis()
        try await waitUntilReady(store)

        let candidate = try XCTUnwrap(store.candidates.first)
        XCTAssertEqual(store.recommendation(for: candidate.id).disposition, .delete)
        XCTAssertTrue(store.isSelected(candidate),
                      "size, content type and path shape must not override a verified semantic judgment")
    }

    func testHumanIntentComesFromInvestigatedTradeoffNotAContentHeuristic() async throws {
        let asset = root.appendingPathComponent("offline-asset")
        try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: false)
        let list = CleanList(categories: [.init(name: "Applications", items: [
            .init(path: asset.path, sizeBytes: 50_000, sizeText: "50KB", itemCount: 1),
        ])], summaryTotalText: "50KB", summaryItemCount: 1)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "One recovery-cost decision remains.", recommendations: [
                .init(candidateId: input.candidates[0].candidateId,
                      disposition: .humanIntentRequired,
                      reason: "The asset is unused, but restoring it requires a paid archive request.",
                      consequence: "Deleting saves space now; restoring later costs time and money.",
                      confidence: 0.92,
                      evidence: [
                        .init(basis: .relationship, label: "Consumer inventory",
                              detail: "No current project or installed application references this asset."),
                        .init(basis: .observation, label: "Recovery policy",
                              detail: "The inspected account policy requires a paid archive restore."),
                      ], investigation: .verifiedHumanIntentFixture),
            ])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: list, snapshot: snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilReady(store)

        let candidate = try XCTUnwrap(store.candidates.first)
        XCTAssertEqual(store.recommendation(for: candidate.id).disposition, .humanIntentRequired)
        XCTAssertFalse(store.isSelected(candidate))
        store.toggleCandidate(candidate.id)
        XCTAssertTrue(store.isSelected(candidate), "the user decides the remaining value tradeoff")
    }

    func testInferenceAloneCannotProduceAnExecutableDeleteRecommendation() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "Filename-only guess.", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .delete,
                      reason: "The name looks obsolete.", consequence: "Unknown.", confidence: 0.8,
                      evidence: [.init(basis: .inference, label: "Naming convention",
                                       detail: "The directory name resembles an old build.")])
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilFinished(store)

        guard case .ready = store.agentState else {
            return XCTFail("unsupported deletion judgments should close at the candidate boundary")
        }
        XCTAssertEqual(store.selectedCount, 0)
        XCTAssertTrue(store.recommendations.values.allSatisfy {
            $0.origin == .burrowSafety && $0.disposition == .keep
        })
        XCTAssertFalse(store.canConfirmPlan, "there is no remaining selected cleanup")
    }

    func testInvestigationGapCannotBeRelabeledAsHumanIntent() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "Ownership could not be checked.", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .humanIntentRequired,
                      reason: "Ask the user because ownership is unknown.",
                      consequence: "The deletion consequence is unknown.", confidence: 0.3,
                      evidence: [.init(basis: .gap, label: "Ownership check",
                                       detail: "The relevant metadata was unavailable.")])
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilFinished(store)

        guard case .ready = store.agentState else {
            return XCTFail("missing investigation should become a conservative keep")
        }
        XCTAssertTrue(store.recommendations.values.allSatisfy {
            $0.origin == .burrowSafety && $0.disposition == .keep
        })
        XCTAssertFalse(store.canConfirmPlan)
    }

    func testExplicitIncompleteInvestigationCanOnlyProduceAgentKeep() async throws {
        let fixture = try makeFixture()
        let incomplete = CleanupAgentInvestigation(
            scope: .init(), ownership: .init(state: .unknown, detail: "Owner unavailable."),
            consumers: .init(state: .unknown, detail: "Consumers unavailable."),
            lifecycle: .init(), recovery: .init(), sensitivity: .init(),
            unresolvedGaps: ["No independent consumer record was available."],
            deepReviewCompleted: false,
            decisionBasis: .incompleteInvestigation)
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "Conservative keep", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .keep,
                      reason: "Deletion is not justified by current evidence.",
                      consequence: "Keeping preserves the current state.", confidence: 0.4,
                      evidence: [.init(basis: .gap, label: "Consumer check",
                                       detail: "Independent usage could not be verified.")],
                      investigation: incomplete)
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilReady(store)

        XCTAssertEqual(store.selectedCount, 0)
        XCTAssertTrue(store.recommendations.values.allSatisfy {
            $0.origin == .agent && $0.disposition == .keep
                && $0.investigation?.decisionBasis == .incompleteInvestigation
        })
    }

    func testJudgmentContractIsGeneralAndEvidenceDriven() {
        let principles = CleanupAgentJudgmentPrinciples.core
        XCTAssertTrue(principles.contains("No product name, content type, size threshold"))
        XCTAssertTrue(principles.contains("Absence of evidence is not evidence of absence"))
        XCTAssertTrue(principles.contains("human_intent_required"))
        XCTAssertTrue(principles.contains("relationship"))
        XCTAssertTrue(principles.contains("does not by itself prove an external consumer"))
        XCTAssertTrue(principles.contains("natural child boundaries"))
        XCTAssertTrue(principles.contains("consumerBasis=external_current"))
        XCTAssertTrue(principles.contains("valid conservative keep"))
    }

    func testCleanupAgentOutputLanguageFollowsBurrowLanguageOverride() {
        XCTAssertEqual(
            CleanupAgentJudgmentPrinciples.responseLanguage(
                appLanguage: "zh-Hans", preferredLocalization: "en"),
            "Simplified Chinese (简体中文)")
        XCTAssertEqual(
            CleanupAgentJudgmentPrinciples.responseLanguage(
                appLanguage: "zh-Hant", preferredLocalization: "en"),
            "Traditional Chinese (繁體中文，台灣用語)")
        XCTAssertEqual(
            CleanupAgentJudgmentPrinciples.responseLanguage(
                appLanguage: "", preferredLocalization: "ru"),
            "Russian (русский)")
        XCTAssertEqual(
            CleanupAgentJudgmentPrinciples.responseLanguage(
                appLanguage: "en", preferredLocalization: "zh-Hans"),
            "English")
    }

    func testCleanupAgentPromptReceivesTheUserFacingLanguage() {
        let language = "Simplified Chinese (简体中文)"
        let recommendation = CleanupAgentJudgmentPrinciples.prompt(
            inputJSON: "{}", triageJSON: "[]", targetCandidateIDs: [],
            responseLanguage: language)
        XCTAssertTrue(recommendation.contains(
            "Write all user-facing text in \(language)."))
    }

    func testCodexRecommendationsAreSplitIntoBoundedStableBatches() {
        let candidates = (0..<53).map { index in
            CleanupAgentCandidateInput(
                candidateId: "candidate-\(index)", path: "/tmp/candidate-\(index)",
                category: "Developer tools", sizeBytes: Int64(index), itemCount: nil,
                runningApp: nil, sensitivePathHint: false)
        }

        let batches = CodexCleanupAgentAdapter.recommendationBatches(
            for: candidates, maximumSize: 24)

        XCTAssertEqual(batches.map(\.count), [24, 24, 5])
        XCTAssertEqual(batches.flatMap { $0.map(\.candidateId) },
                       candidates.map(\.candidateId))
    }

    func testCodexBatchingKeepsAncestorAndDescendantInOneJudgmentContext() {
        func candidate(_ id: String, _ path: String) -> CleanupAgentCandidateInput {
            .init(candidateId: id, path: path, category: "Developer tools",
                  sizeBytes: 1, itemCount: nil, runningApp: nil,
                  sensitivePathHint: false)
        }
        let candidates = [
            candidate("parent", "/tmp/cache"),
            candidate("unrelated-a", "/tmp/other-a"),
            candidate("unrelated-b", "/tmp/other-b"),
            candidate("child", "/tmp/cache/version-1"),
        ]

        let batches = CodexCleanupAgentAdapter.recommendationBatches(
            for: candidates, maximumSize: 2)
        let relatedBatch = try? XCTUnwrap(batches.first { batch in
            batch.contains { $0.candidateId == "parent" }
        })

        XCTAssertEqual(Set(relatedBatch?.map(\.candidateId) ?? []), ["parent", "child"])
    }

    func testCodexBatchingBoundsOneCoarseParentWithManyDescendants() {
        var candidates: [CleanupAgentCandidateInput] = [
            .init(candidateId: "home", path: "/Users/example", category: "User basics",
                  sizeBytes: 1, itemCount: nil, runningApp: nil,
                  sensitivePathHint: true),
        ]
        candidates += (0..<122).map { index in
            .init(candidateId: "child-\(index)",
                  path: "/Users/example/Library/Caches/app-\(index)/cache",
                  category: "Application caches", sizeBytes: 1, itemCount: nil,
                  runningApp: nil, sensitivePathHint: false)
        }

        let batches = CodexCleanupAgentAdapter.recommendationBatches(
            for: candidates, maximumSize: 12)
        let returned = batches.flatMap { $0.map(\.candidateId) }

        XCTAssertTrue(batches.allSatisfy { !$0.isEmpty && $0.count <= 12 })
        XCTAssertEqual(returned.count, candidates.count)
        XCTAssertEqual(Set(returned), Set(candidates.map(\.candidateId)))
        XCTAssertEqual(returned.filter { $0 == "home" }.count, 1)
        XCTAssertEqual(batches.count, 12)
    }

    func testOnlyOutputCapacityFailuresAreEligibleForAdaptiveSplit() {
        XCTAssertTrue(CodexCleanupAgentAdapter.isSplittableResponseError(.missingResponse))
        XCTAssertTrue(CodexCleanupAgentAdapter.isSplittableResponseError(
            .exited(1, "maximum output length exceeded")))
        XCTAssertFalse(CodexCleanupAgentAdapter.isSplittableResponseError(
            .exited(1, "authentication required")))
        XCTAssertFalse(CodexCleanupAgentAdapter.isSplittableResponseError(
            .exited(1, "response rate limit exceeded")))
        XCTAssertFalse(CodexCleanupAgentAdapter.isSplittableResponseError(
            .exited(1, "input context_length exceeds maximum")))
        XCTAssertFalse(CodexCleanupAgentAdapter.isSplittableResponseError(
            .launchFailed("permission denied")))
    }

    func testCodexBatchCoverageRejectsMissingDuplicateAndForeignJudgments() {
        func recommendation(_ id: String) -> CleanupAgentRecommendation {
            .init(candidateId: id, disposition: .keep, reason: "Keep.",
                  consequence: "No change.", confidence: 0.8,
                  evidence: [.init(label: "Observed", detail: "Verified.")])
        }
        let exact = CleanupAgentAnalysis(
            summary: "Complete.", recommendations: [recommendation("a"), recommendation("b")])
        let missing = CleanupAgentAnalysis(
            summary: "Missing.", recommendations: [recommendation("a")])
        let duplicate = CleanupAgentAnalysis(
            summary: "Duplicate.", recommendations: [recommendation("a"), recommendation("a")])
        let foreign = CleanupAgentAnalysis(
            summary: "Foreign.", recommendations: [recommendation("a"), recommendation("c")])

        XCTAssertTrue(CodexCleanupAgentAdapter.hasExactBatchCoverage(exact, targetIDs: ["a", "b"]))
        XCTAssertFalse(CodexCleanupAgentAdapter.hasExactBatchCoverage(missing, targetIDs: ["a", "b"]))
        XCTAssertFalse(CodexCleanupAgentAdapter.hasExactBatchCoverage(duplicate, targetIDs: ["a", "b"]))
        XCTAssertFalse(CodexCleanupAgentAdapter.hasExactBatchCoverage(foreign, targetIDs: ["a", "b"]))
    }

    func testRecommendationSchemaConstrainsBatchCountAndCandidateIdentity() throws {
        let data = try CodexCleanupAgentAdapter.schemaData(
            targetCandidateIDs: ["focused-candidate"])
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try XCTUnwrap(root["properties"] as? [String: Any])
        let recommendations = try XCTUnwrap(
            properties["recommendations"] as? [String: Any])
        XCTAssertEqual(recommendations["minItems"] as? Int, 1)
        XCTAssertEqual(recommendations["maxItems"] as? Int, 1)

        let item = try XCTUnwrap(recommendations["items"] as? [String: Any])
        let itemProperties = try XCTUnwrap(item["properties"] as? [String: Any])
        let candidateID = try XCTUnwrap(itemProperties["candidateId"] as? [String: Any])
        XCTAssertEqual(candidateID["enum"] as? [String], ["focused-candidate"])

        let discovered = try XCTUnwrap(
            properties["discoveredCandidates"] as? [String: Any])
        let discoveredItem = try XCTUnwrap(discovered["items"] as? [String: Any])
        let discoveredProperties = try XCTUnwrap(
            discoveredItem["properties"] as? [String: Any])
        let parentID = try XCTUnwrap(
            discoveredProperties["parentCandidateId"] as? [String: Any])
        XCTAssertEqual(parentID["enum"] as? [String], ["focused-candidate"])
    }

    func testInternalSelfReferenceCannotCompleteCurrentConsumerKeep() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "Self-reference only.", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .keep,
                      reason: "An internal ref points to a snapshot.",
                      consequence: "Keep until external use is established.", confidence: 0.7,
                      evidence: [.init(basis: .observation, label: "Internal ref",
                                       detail: "The ref source and target are inside the candidate.")],
                      investigation: .init(
                        scope: .init(), ownership: .init(), consumers: .init(),
                        lifecycle: .init(), recovery: .init(), sensitivity: .init(),
                        unresolvedGaps: [], deepReviewCompleted: true,
                        scopeKind: .homogeneous, consumerBasis: .internalOnly,
                        decisionBasis: .currentConsumer))
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilFinished(store)

        XCTAssertFalse(store.canConfirmPlan)
        XCTAssertEqual(store.agentProgress?.reviewedCount, store.candidates.count)
        XCTAssertTrue(store.recommendations.values.allSatisfy { $0.origin == .burrowSafety })
    }

    func testHeterogeneousParentWithoutChildJudgmentsCannotComplete() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "Mixed parent.", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .keep,
                      reason: "The parent contains independently useful objects.",
                      consequence: "Keep the parent pending child analysis.", confidence: 0.8,
                      evidence: [.init(basis: .observation, label: "Mixed scope",
                                       detail: "Children have different lifecycle states.")],
                      investigation: .init(
                        scope: .init(), ownership: .init(), consumers: .init(),
                        lifecycle: .init(), recovery: .init(), sensitivity: .init(),
                        unresolvedGaps: [], deepReviewCompleted: true,
                        scopeKind: .heterogeneous, consumerBasis: .noneFound,
                        decisionBasis: .mixedContainer))
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilFinished(store)

        XCTAssertFalse(store.canConfirmPlan)
        XCTAssertEqual(store.agentProgress?.reviewedCount, store.candidates.count)
        XCTAssertTrue(store.recommendations.values.allSatisfy { $0.origin == .burrowSafety })
    }

    func testExternalCurrentConsumerCanNeverBeCombinedWithDelete() async throws {
        let fixture = try makeFixture()
        let source = root.appendingPathComponent("installed-app-config.json")
        let targetPaths = fixture.list.categories.flatMap(\.items).map(\.path)
        try Data(targetPaths.joined(separator: "\n").utf8).write(to: source)
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "Contradictory delete.", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .delete,
                      reason: "Claims removal despite a current consumer.",
                      consequence: "Would break the consumer.", confidence: 0.99,
                      evidence: [.init(basis: .relationship, label: "Current consumer",
                                       detail: "An installed configuration points to the candidate.")],
                      investigation: .init(
                        scope: .init(), ownership: .init(), consumers: .init(),
                        lifecycle: .init(), recovery: .init(), sensitivity: .init(),
                        unresolvedGaps: [], deepReviewCompleted: true,
                        consumerBasis: .externalCurrent,
                        decisionBasis: .currentConsumer,
                        consumerReference: .init(
                            kind: .textualPath, sourcePath: source.path,
                            targetPath: $0.path, current: true)))
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilFinished(store)

        XCTAssertFalse(store.canConfirmPlan)
        XCTAssertEqual(store.agentProgress?.reviewedCount, store.candidates.count)
        XCTAssertTrue(store.recommendations.values.allSatisfy { $0.origin == .burrowSafety })
    }

    func testInternalReferenceCannotBeRelabeledExternalCurrent() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "False external label.", recommendations: input.candidates.map {
                let source = URL(fileURLWithPath: $0.path).appendingPathComponent("refs-main")
                try! Data($0.path.utf8).write(to: source)
                return .init(
                    candidateId: $0.candidateId, disposition: .keep,
                    reason: "The candidate points to itself.", consequence: "No external use proven.",
                    confidence: 0.9,
                    evidence: [.init(basis: .observation, label: "Internal pointer",
                                     detail: "The source lives inside the candidate.")],
                    investigation: .init(
                        scope: .init(), ownership: .init(), consumers: .init(),
                        lifecycle: .init(), recovery: .init(), sensitivity: .init(),
                        unresolvedGaps: [], deepReviewCompleted: true,
                        consumerBasis: .externalCurrent,
                        decisionBasis: .currentConsumer,
                        consumerReference: .init(
                            kind: .textualPath, sourcePath: source.path,
                            targetPath: $0.path, current: true)))
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilFinished(store)

        XCTAssertFalse(store.canConfirmPlan)
        XCTAssertEqual(store.agentProgress?.reviewedCount, store.candidates.count)
        XCTAssertTrue(store.recommendations.values.allSatisfy { $0.origin == .burrowSafety })
    }

    func testHomogeneousMixedContainerLabelCannotBypassChildRequirement() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "Contradictory scope.", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .keep,
                      reason: "Calls a homogeneous row mixed.", consequence: "Must be rejected.",
                      confidence: 0.8,
                      evidence: [.init(basis: .observation, label: "Scope",
                                       detail: "No child judgment was produced.")],
                      investigation: .init(
                        scope: .init(), ownership: .init(), consumers: .init(),
                        lifecycle: .init(), recovery: .init(), sensitivity: .init(),
                        unresolvedGaps: [], deepReviewCompleted: true,
                        scopeKind: .homogeneous, consumerBasis: .noneFound,
                        decisionBasis: .mixedContainer))
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilFinished(store)

        XCTAssertFalse(store.canConfirmPlan)
        XCTAssertEqual(store.agentProgress?.reviewedCount, store.candidates.count)
        XCTAssertTrue(store.recommendations.values.allSatisfy { $0.origin == .burrowSafety })
    }

    func testVerifiedExternalCurrentReferenceCanCompleteKeep() async throws {
        let fixture = try makeFixture()
        let source = root.appendingPathComponent("installed-owner.app")
        let targetPaths = fixture.list.categories.flatMap(\.items).map(\.path)
        try Data(targetPaths.joined(separator: "\n").utf8).write(to: source)
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "Verified current consumers.", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .keep,
                      reason: "An independent installed owner points to this candidate.",
                      consequence: "Keeping preserves the active workflow.", confidence: 0.98,
                      evidence: [.init(basis: .relationship, label: "External reference",
                                       detail: "The source is outside the candidate.")],
                      investigation: .init(
                        scope: .init(), ownership: .init(), consumers: .init(),
                        lifecycle: .init(), recovery: .init(), sensitivity: .init(),
                        unresolvedGaps: [], deepReviewCompleted: true,
                        consumerBasis: .externalCurrent,
                        decisionBasis: .currentConsumer,
                        consumerReference: .init(
                            kind: .textualPath, sourcePath: source.path,
                            targetPath: $0.path, current: true)))
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilReady(store)

        XCTAssertTrue(store.canUseAgentCTA)
        XCTAssertEqual(store.agentProgress?.reviewedCount, fixture.list.categories.flatMap(\.items).count)
        XCTAssertTrue(store.candidates.allSatisfy { !store.isSelected($0) })
    }

    func testRelativeSymbolicLinkCanGroundExternalCurrentKeep() async throws {
        let candidate = root.appendingPathComponent("active-model", isDirectory: true)
        let source = root.appendingPathComponent("consumer-current")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            atPath: source.path, withDestinationPath: candidate.lastPathComponent)
        let list = CleanList(categories: [.init(name: "Local models", items: [
            .init(path: candidate.path, sizeBytes: 100, sizeText: "100B", itemCount: 1),
        ])], summaryTotalText: "100B", summaryItemCount: 1)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "Verified symlink.", recommendations: [
                .init(candidateId: input.candidates[0].candidateId, disposition: .keep,
                      reason: "An external current symlink resolves to the candidate.",
                      consequence: "Keeping preserves the active consumer.", confidence: 0.99,
                      evidence: [.init(basis: .relationship, label: "Symlink",
                                       detail: "The relative link resolves to this candidate.")],
                      investigation: .init(
                        scope: .init(), ownership: .init(), consumers: .init(),
                        lifecycle: .init(), recovery: .init(), sensitivity: .init(),
                        unresolvedGaps: [], deepReviewCompleted: true,
                        consumerBasis: .externalCurrent, decisionBasis: .currentConsumer,
                        consumerReference: .init(
                            kind: .symbolicLink, sourcePath: source.path,
                            targetPath: candidate.path, current: true))),
            ])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: list, snapshot: snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilReady(store)

        XCTAssertTrue(store.canUseAgentCTA)
        XCTAssertEqual(store.agentProgress?.reviewedCount, 1)
    }

    func testSymbolicLinkToDifferentTargetCannotGroundCurrentKeep() async throws {
        let candidate = root.appendingPathComponent("reviewed-model", isDirectory: true)
        let other = root.appendingPathComponent("different-model", isDirectory: true)
        let source = root.appendingPathComponent("consumer-current")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: other.path)
        let list = CleanList(categories: [.init(name: "Local models", items: [
            .init(path: candidate.path, sizeBytes: 100, sizeText: "100B", itemCount: 1),
        ])], summaryTotalText: "100B", summaryItemCount: 1)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "Wrong target.", recommendations: [
                .init(candidateId: input.candidates[0].candidateId, disposition: .keep,
                      reason: "The link actually resolves elsewhere.",
                      consequence: "Must not count as current use.", confidence: 0.99,
                      evidence: [.init(basis: .relationship, label: "Symlink",
                                       detail: "The declared and actual targets differ.")],
                      investigation: .init(
                        scope: .init(), ownership: .init(), consumers: .init(),
                        lifecycle: .init(), recovery: .init(), sensitivity: .init(),
                        unresolvedGaps: [], deepReviewCompleted: true,
                        consumerBasis: .externalCurrent, decisionBasis: .currentConsumer,
                        consumerReference: .init(
                            kind: .symbolicLink, sourcePath: source.path,
                            targetPath: candidate.path, current: true))),
            ])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: list, snapshot: snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilFinished(store)

        XCTAssertEqual(store.agentProgress?.reviewedCount, store.candidates.count)
        XCTAssertTrue(store.recommendations.values.allSatisfy { $0.origin == .burrowSafety })
        XCTAssertFalse(store.canConfirmPlan)
    }

    func testTextualReferenceRequiresACompletePathToken() async throws {
        let candidate = root.appendingPathComponent("model", isDirectory: true)
        let source = root.appendingPathComponent("consumer.conf")
        try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false)
        try Data((candidate.path + "-old").utf8).write(to: source)
        let list = CleanList(categories: [.init(name: "Local models", items: [
            .init(path: candidate.path, sizeBytes: 100, sizeText: "100B", itemCount: 1),
        ])], summaryTotalText: "100B", summaryItemCount: 1)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "Prefix collision.", recommendations: [
                .init(candidateId: input.candidates[0].candidateId, disposition: .keep,
                      reason: "A different path merely shares the target prefix.",
                      consequence: "Must not count as a consumer.", confidence: 0.99,
                      evidence: [.init(basis: .observation, label: "Configuration",
                                       detail: "Only a suffixed path is present.")],
                      investigation: .init(
                        scope: .init(), ownership: .init(), consumers: .init(),
                        lifecycle: .init(), recovery: .init(), sensitivity: .init(),
                        unresolvedGaps: [], deepReviewCompleted: true,
                        consumerBasis: .externalCurrent, decisionBasis: .currentConsumer,
                        consumerReference: .init(
                            kind: .textualPath, sourcePath: source.path,
                            targetPath: candidate.path, current: true))),
            ])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: list, snapshot: snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilFinished(store)

        XCTAssertEqual(store.agentProgress?.reviewedCount, store.candidates.count)
        XCTAssertTrue(store.recommendations.values.allSatisfy { $0.origin == .burrowSafety })
        XCTAssertFalse(store.canConfirmPlan)
    }

    func testConsumerReferenceCannotBeHiddenBehindAnotherBasisOrHumanIntent() async throws {
        let fixture = try makeFixture()
        let source = root.appendingPathComponent("consumer-config.txt")
        let paths = fixture.list.categories.flatMap(\.items).map(\.path)
        try Data(paths.joined(separator: "\n").utf8).write(to: source)
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "Hidden current references.", recommendations: [
                .init(candidateId: input.candidates[0].candidateId, disposition: .delete,
                      reason: "Hides a current reference behind none_found.",
                      consequence: "Would remove used content.", confidence: 1,
                      evidence: [.init(basis: .relationship, label: "Reference",
                                       detail: "Contradictory typed fields.")],
                      investigation: .init(
                        scope: .init(), ownership: .init(), consumers: .init(),
                        lifecycle: .init(), recovery: .init(), sensitivity: .init(),
                        unresolvedGaps: [], deepReviewCompleted: true,
                        consumerBasis: .noneFound, decisionBasis: .unusedRecoverable,
                        consumerReference: .init(
                            kind: .textualPath, sourcePath: source.path,
                            targetPath: input.candidates[0].path, current: true))),
                .init(candidateId: input.candidates[1].candidateId,
                      disposition: .humanIntentRequired,
                      reason: "Hides current use as a preference.",
                      consequence: "Would delegate a factual conflict.", confidence: 1,
                      evidence: [.init(basis: .relationship, label: "Reference",
                                       detail: "A current external consumer exists.")],
                      investigation: .init(
                        scope: .init(), ownership: .init(), consumers: .init(),
                        lifecycle: .init(), recovery: .init(), sensitivity: .init(),
                        unresolvedGaps: [], deepReviewCompleted: true,
                        consumerBasis: .externalCurrent, decisionBasis: .userTradeoff,
                        consumerReference: .init(
                            kind: .textualPath, sourcePath: source.path,
                            targetPath: input.candidates[1].path, current: true))),
            ])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilFinished(store)

        XCTAssertFalse(store.canConfirmPlan)
        XCTAssertEqual(store.agentProgress?.reviewedCount, store.candidates.count)
        XCTAssertTrue(store.recommendations.values.allSatisfy { $0.origin == .burrowSafety })
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
            CleanupAgentAnalysis(summary: "delete both", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .delete,
                      reason: "Rebuildable.", consequence: "Recreated on demand.", confidence: 0.9,
                      evidence: [.init(label: "Filesystem", detail: "Verified")])
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        store.toggleCategory("AI Tools") // explicit category-level keep
        try await waitUntilReady(store)

        let candidate = try XCTUnwrap(store.candidates.first { $0.category == "AI Tools" })
        XCTAssertTrue(store.userOverrides.contains(candidate.id))
        XCTAssertFalse(store.isSelected(candidate), "the explicit category decision wins")
    }

    func testTogglingBackToAgentRecommendationRemovesOverrideAndRestoresShortcut() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "delete both", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .delete,
                      reason: "Rebuildable.", consequence: "Recreated on demand.", confidence: 0.9,
                      evidence: [.init(label: "Filesystem", detail: "Verified")])
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilReady(store)

        let candidate = try XCTUnwrap(store.candidates.first)
        store.toggleCandidate(candidate.id)
        XCTAssertTrue(store.userOverrides.contains(candidate.id))
        XCTAssertFalse(store.canUseAgentCTA)

        store.toggleCandidate(candidate.id)
        XCTAssertFalse(store.userOverrides.contains(candidate.id))
        XCTAssertTrue(store.canUseAgentCTA)
    }

    func testDeleteRowsAreSortedLargestFirstWithStablePathTieBreak() async throws {
        let small = root.appendingPathComponent("small")
        let largeB = root.appendingPathComponent("large-b")
        let largeA = root.appendingPathComponent("large-a")
        for url in [small, largeB, largeA] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
        let list = CleanList(categories: [.init(name: "Developer tools", items: [
            .init(path: small.path, sizeBytes: 10, sizeText: "10B", itemCount: 1),
            .init(path: largeB.path, sizeBytes: 50, sizeText: "50B", itemCount: 1),
            .init(path: largeA.path, sizeBytes: 50, sizeText: "50B", itemCount: 1),
        ])], summaryTotalText: "110B", summaryItemCount: 3)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "ordered", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .delete,
                      reason: "Rebuildable.", consequence: "Recreated on demand.", confidence: 0.9,
                      evidence: [.init(label: "Filesystem", detail: "Verified")])
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: list, snapshot: snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilReady(store)

        let rows = try XCTUnwrap(store.sections.first { $0.disposition == .delete }).candidates
        XCTAssertEqual(rows.map(\.path), [largeA.path, largeB.path, small.path])
    }

    func testUnknownStructuredCheckBlocksDeleteEvenWithRelationshipEvidence() async throws {
        let fixture = try makeFixture()
        let incomplete = CleanupAgentInvestigation(
            scope: .init(), ownership: .init(),
            consumers: .init(state: .unknown, detail: "Consumer index was unavailable."),
            lifecycle: .init(), recovery: .init(), sensitivity: .init(),
            unresolvedGaps: ["Active consumers were not verified."],
            deepReviewCompleted: true)
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "incomplete", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .delete,
                      reason: "Appears unused.", consequence: "Would be rebuilt.", confidence: 0.8,
                      evidence: [.init(basis: .relationship, label: "Owner",
                                       detail: "An owner relationship was found.")],
                      investigation: incomplete)
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilFinished(store)

        guard case .ready = store.agentState else {
            return XCTFail("an unresolved structured check should close at the candidate boundary")
        }
        XCTAssertTrue(store.recommendations.values.allSatisfy {
            $0.origin == .burrowSafety && $0.disposition == .keep
        })
        XCTAssertFalse(store.canConfirmPlan)
    }

    func testAgentDiscoveredChildIsRemeasuredPinnedAndMarkedWithoutTrustingReportedSize() async throws {
        let parent = root.appendingPathComponent("model-cache", isDirectory: true)
        let child = parent.appendingPathComponent("retired-model.bin")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try Data(repeating: 0x5A, count: 16_384).write(to: child)
        let list = CleanList(categories: [.init(name: "Local models", items: [
            .init(path: parent.path, sizeBytes: 16_384, sizeText: "16KB", itemCount: 1),
        ])], summaryTotalText: "16KB", summaryItemCount: 1)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(
                summary: "one narrower stale asset",
                recommendations: [
                    .init(candidateId: input.candidates[0].candidateId, disposition: .keep,
                          reason: "The parent also contains current assets.",
                          consequence: "Keeping it protects the current model.", confidence: 0.98,
                          evidence: [.init(basis: .relationship, label: "Container scope",
                                           detail: "The parent contains mixed-lifecycle assets.")],
                          investigation: .verifiedMixedFixture),
                ],
                discoveredCandidates: [
                    .init(parentCandidateId: input.candidates[0].candidateId,
                          path: child.path, sizeBytes: 999_999_999,
                          disposition: .delete,
                          reason: "No installed consumer references this retired version.",
                          consequence: "The retired model can be downloaded again.",
                          confidence: 0.96,
                          evidence: [.init(basis: .relationship, label: "Consumer inventory",
                                           detail: "Current consumers reference a different model version.")],
                          investigation: .verifiedFixture),
                ])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: list, snapshot: snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilReady(store)

        let discovered = try XCTUnwrap(store.candidates.first { $0.path == child.path })
        XCTAssertEqual(discovered.origin, .agentDiscovered)
        XCTAssertNotEqual(discovered.sizeBytes, 999_999_999)
        XCTAssertGreaterThan(discovered.sizeBytes, 0)
        XCTAssertTrue(store.executionSnapshot?.items.contains {
            $0.identity.path == child.path
        } == true)
        XCTAssertTrue(store.isSelected(discovered))

        let coarseParent = try XCTUnwrap(store.candidates.first { $0.path == parent.path })
        XCTAssertTrue(coarseParent.locked)
        XCTAssertFalse(store.isSelected(coarseParent))
    }

    func testDuplicateAgentDiscoveredPathCannotUseFirstValidDelete() async throws {
        let parent = root.appendingPathComponent("duplicate-model-cache", isDirectory: true)
        let child = parent.appendingPathComponent("retired-model.bin")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try Data(repeating: 0x31, count: 4_096).write(to: child)
        let list = CleanList(categories: [.init(name: "Local models", items: [
            .init(path: parent.path, sizeBytes: 4_096, sizeText: "4KB", itemCount: 1),
        ])], summaryTotalText: "4KB", summaryItemCount: 1)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            let parentID = input.candidates[0].candidateId
            return CleanupAgentAnalysis(
                summary: "conflicting duplicate child",
                recommendations: [
                    .init(candidateId: parentID, disposition: .keep,
                          reason: "The parent would contain independently judged children.",
                          consequence: "Keep the coarse parent.", confidence: 0.9,
                          evidence: [.init(basis: .observation, label: "Scope",
                                           detail: "Mixed child lifecycle was inspected.")],
                          investigation: .verifiedMixedFixture),
                ],
                discoveredCandidates: [
                    .init(parentCandidateId: parentID, path: child.path, sizeBytes: 4_096,
                          disposition: .delete, reason: "Observed unused.",
                          consequence: "Can be restored.", confidence: 0.95,
                          evidence: [.init(basis: .observation, label: "Lifecycle",
                                           detail: "No active use was observed.")],
                          investigation: .verifiedFixture),
                    .init(parentCandidateId: parentID, path: child.path, sizeBytes: 4_096,
                          disposition: .keep, reason: "Conflicting duplicate.",
                          consequence: "Keep it.", confidence: 0.95,
                          evidence: [.init(basis: .observation, label: "Lifecycle",
                                           detail: "Conflicting state was returned.")],
                          investigation: .verifiedKeepFixture),
                ])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: list, snapshot: snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilReady(store)

        XCTAssertFalse(store.candidates.contains { $0.path == child.path })
        let coarse = try XCTUnwrap(store.candidates.first)
        XCTAssertEqual(store.recommendation(for: coarse.id).origin, .burrowSafety)
        XCTAssertEqual(store.recommendation(for: coarse.id).disposition, .keep)
        XCTAssertFalse(store.isSelected(coarse))
    }

    func testRefusedOrLockedScannerParentCannotAuthorizeAgentDiscoveredChild() async throws {
        let safe = root.appendingPathComponent("safe-cache", isDirectory: true)
        let sensitiveChild = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: sensitiveChild, withIntermediateDirectories: false)
        let list = CleanList(categories: [.init(name: "App caches", items: [
            .init(path: root.path, sizeBytes: 100_000, sizeText: "100KB", itemCount: 2),
            .init(path: safe.path, sizeBytes: 1_000, sizeText: "1KB", itemCount: 1),
        ])], summaryTotalText: "101KB", summaryItemCount: 3)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        XCTAssertFalse(snapshot.items.contains { $0.identity.path == root.path })
        let refusedRootPath = root.path
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            let refused = input.candidates.first { $0.path == refusedRootPath }!
            return CleanupAgentAnalysis(
                summary: "refused parent must stay refused",
                recommendations: input.candidates.map {
                    .init(candidateId: $0.candidateId,
                          disposition: $0.candidateId == refused.candidateId ? .keep : .delete,
                          reason: "Deterministic result.", consequence: "No widening.", confidence: 0.9,
                          evidence: [.init(label: "Filesystem", detail: "Verified")],
                          investigation: $0.candidateId == refused.candidateId
                            ? .verifiedKeepFixture : .verifiedFixture)
                },
                discoveredCandidates: [
                    .init(parentCandidateId: refused.candidateId,
                          path: sensitiveChild.path, sizeBytes: 50_000,
                          disposition: .delete, reason: "Unsafe widening attempt.",
                          consequence: "Would delete user content.", confidence: 1,
                          evidence: [.init(basis: .relationship, label: "Claim",
                                           detail: "Must not be trusted.")],
                          investigation: .verifiedFixture),
                ])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: list, snapshot: snapshot,
                   locked: [root.path: .notCleanable(reason: "Refused root")],
                   hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilReady(store)

        XCTAssertFalse(store.candidates.contains { $0.path == sensitiveChild.path })
        XCTAssertFalse(store.executionSnapshot?.items.contains {
            $0.identity.path == sensitiveChild.path
        } == true)
    }

    func testSelectionEditDuringAnalysisKeepsLateDiscoveredChildUnselected() async throws {
        let parent = root.appendingPathComponent("cache", isDirectory: true)
        let child = parent.appendingPathComponent("old.bin")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try Data(repeating: 1, count: 8_192).write(to: child)
        let list = CleanList(categories: [.init(name: "Local models", items: [
            .init(path: parent.path, sizeBytes: 8_192, sizeText: "8KB", itemCount: 1),
        ])], summaryTotalText: "8KB", summaryItemCount: 1)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        let analyzer = FakeCleanupAnalyzer(delay: 80_000_000) { input in
            CleanupAgentAnalysis(
                summary: "late child",
                recommendations: [
                    .init(candidateId: input.candidates[0].candidateId, disposition: .keep,
                          reason: "Mixed parent.", consequence: "Keep the container.", confidence: 0.9,
                          evidence: [.init(label: "Scope", detail: "Verified")],
                          investigation: .verifiedMixedFixture),
                ],
                discoveredCandidates: [
                    .init(parentCandidateId: input.candidates[0].candidateId,
                          path: child.path, sizeBytes: 8_192, disposition: .delete,
                          reason: "Retired leaf.", consequence: "Recreated if needed.", confidence: 0.9,
                          evidence: [.init(basis: .relationship, label: "Lifecycle",
                                           detail: "A current replacement exists.")],
                          investigation: .verifiedFixture),
                ])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: list, snapshot: snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        store.deselectAll()
        try await waitUntilReady(store)

        let discovered = try XCTUnwrap(store.candidates.first { $0.path == child.path })
        XCTAssertFalse(store.isSelected(discovered))
        XCTAssertTrue(store.userOverrides.contains(discovered.id))
        XCTAssertFalse(store.canUseAgentCTA)
    }

    func testSamePathParentReplacementCannotTransferDiscoveryAuthority() async throws {
        let parent = root.appendingPathComponent("replaceable-cache", isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        let list = CleanList(categories: [.init(name: "App caches", items: [
            .init(path: parent.path, sizeBytes: 4_096, sizeText: "4KB", itemCount: 1),
        ])], summaryTotalText: "4KB", summaryItemCount: 1)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        let replacementChild = parent.appendingPathComponent("new-tree.bin")
        let analyzer = FakeCleanupAnalyzer(delay: 80_000_000) { input in
            CleanupAgentAnalysis(
                summary: "same path, different tree",
                recommendations: [
                    .init(candidateId: input.candidates[0].candidateId, disposition: .keep,
                          reason: "Parent changed.", consequence: "Keep it.", confidence: 1,
                          evidence: [.init(label: "Identity", detail: "Must be revalidated")],
                          investigation: .verifiedKeepFixture),
                ],
                discoveredCandidates: [
                    .init(parentCandidateId: input.candidates[0].candidateId,
                          path: replacementChild.path, sizeBytes: 4_096,
                          disposition: .delete, reason: "Untrusted replacement child.",
                          consequence: "Must not enter the plan.", confidence: 1,
                          evidence: [.init(basis: .relationship, label: "Claim",
                                           detail: "The old identity does not authorize this tree.")],
                          investigation: .verifiedFixture),
                ])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: list, snapshot: snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()

        try FileManager.default.removeItem(at: parent)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try Data(repeating: 7, count: 4_096).write(to: replacementChild)
        try await waitUntilReady(store)

        XCTAssertFalse(store.candidates.contains { $0.path == replacementChild.path })
        XCTAssertFalse(store.executionSnapshot?.items.contains {
            $0.identity.path == replacementChild.path
        } == true)
    }

    func testParentReplacementAfterChildSnapshotStillRejectsDiscoveryMerge() async throws {
        let parent = root.appendingPathComponent("capture-window", isDirectory: true)
        let child = parent.appendingPathComponent("leaf.bin")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        try Data(repeating: 2, count: 4_096).write(to: child)
        let list = CleanList(categories: [.init(name: "App caches", items: [
            .init(path: parent.path, sizeBytes: 4_096, sizeText: "4KB", itemCount: 1),
        ])], summaryTotalText: "4KB", summaryItemCount: 1)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(
                summary: "post-capture race",
                recommendations: [
                    .init(candidateId: input.candidates[0].candidateId, disposition: .keep,
                          reason: "Mixed parent.", consequence: "Keep it.", confidence: 1,
                          evidence: [.init(label: "Scope", detail: "Verified")],
                          investigation: .verifiedKeepFixture),
                ],
                discoveredCandidates: [
                    .init(parentCandidateId: input.candidates[0].candidateId,
                          path: child.path, sizeBytes: 4_096, disposition: .delete,
                          reason: "Old leaf.", consequence: "Recreated on demand.", confidence: 1,
                          evidence: [.init(basis: .relationship, label: "Lifecycle",
                                           detail: "A replacement exists.")],
                          investigation: .verifiedFixture),
                ])
        }
        var hookRan = false
        let store = CleanupPlanStore(
            analyzer: analyzer,
            discoverySnapshotCapturedHook: {
                hookRan = true
                try! FileManager.default.removeItem(at: parent)
                try! FileManager.default.createDirectory(at: parent,
                                                         withIntermediateDirectories: false)
                try! Data(repeating: 9, count: 4_096).write(to: child)
            })
        store.load(list: list, snapshot: snapshot, locked: [:], hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilReady(store)

        XCTAssertTrue(hookRan)
        XCTAssertFalse(store.candidates.contains { $0.origin == .agentDiscovered })
        XCTAssertEqual(store.executionSnapshot?.id, snapshot.id)
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

    func testInvalidAgentClaimForLockedCandidateConvergesToBurrowSafetyKeep() async throws {
        let fixture = try makeFixture()
        let lockedPath = fixture.list.categories[0].items[0].path
        let contradictory = CleanupAgentInvestigation(
            scope: .init(), ownership: .init(), consumers: .init(),
            lifecycle: .init(), recovery: .init(), sensitivity: .init(),
            unresolvedGaps: [], deepReviewCompleted: true,
            consumerBasis: .externalCurrent,
            decisionBasis: .currentConsumer,
            consumerReference: .none)
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            CleanupAgentAnalysis(summary: "locked row", recommendations: input.candidates.map {
                if $0.path == lockedPath {
                    return .init(candidateId: $0.candidateId, disposition: .delete,
                                 reason: "Untrusted current-consumer claim.",
                                 consequence: "Must not control cleanup.", confidence: 1,
                                 evidence: [.init(basis: .inference, label: "Claim",
                                                  detail: "Unverified")],
                                 investigation: contradictory)
                }
                return .init(candidateId: $0.candidateId, disposition: .keep,
                             reason: "Verified keep.", consequence: "No change.", confidence: 0.9,
                             evidence: [.init(basis: .observation, label: "Safety",
                                              detail: "Verified")],
                             investigation: .verifiedKeepFixture)
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot,
                   locked: [lockedPath: .appOpen(appName: "Messages")],
                   hasAgentConsent: true)
        store.startAgentAnalysis()
        try await waitUntilReady(store)

        let candidate = try XCTUnwrap(store.candidates.first { $0.path == lockedPath })
        let result = store.recommendation(for: candidate.id)
        XCTAssertEqual(result.origin, .burrowSafety)
        XCTAssertEqual(result.disposition, .keep)
        XCTAssertTrue(result.reason.contains("Messages"))
        XCTAssertFalse(store.isSelected(candidate))
        XCTAssertTrue(store.canUseAgentCTA)
    }

    func testPartialUnknownAndDuplicateRecommendationsBecomeConservativeKeeps() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 0) { input in
            let known = input.candidates[0].candidateId
            return CleanupAgentAnalysis(summary: "mixed payload", recommendations: [
                .init(candidateId: "unknown", disposition: .delete, reason: "No.",
                      consequence: "No.", confidence: 1,
                      evidence: [.init(label: "Filesystem", detail: "Verified")]),
                .init(candidateId: known, disposition: .keep, reason: "First valid answer.",
                      consequence: "Keep.", confidence: 0.8,
                      evidence: [.init(label: "Filesystem", detail: "Verified")],
                      investigation: .verifiedKeepFixture),
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
        XCTAssertEqual(store.recommendation(for: first.id).origin, .burrowSafety)
        XCTAssertEqual(store.recommendation(for: first.id).disposition, .keep)
        XCTAssertFalse(store.isSelected(first))
        XCTAssertNil(store.recommendations["unknown"])
        XCTAssertTrue(store.canUseAgentCTA)
        guard case .ready = store.agentState else {
            return XCTFail("missing rows should be conservatively kept without blocking valid siblings")
        }
        let second = store.candidates[1]
        XCTAssertEqual(store.recommendation(for: second.id).origin, .burrowSafety)
        XCTAssertEqual(store.recommendation(for: second.id).disposition, .keep)
        XCTAssertFalse(store.isSelected(second))
    }

    func testCandidateReassessmentSendsAndUpdatesOnlyTheSelectedCandidate() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 40_000_000) { input in
            XCTAssertEqual(input.candidates.count, 1)
            return CleanupAgentAnalysis(summary: "single row", recommendations: [
                .init(candidateId: input.candidates[0].candidateId, disposition: .keep,
                      reason: "Current consumer verified.", consequence: "Keep it in place.",
                      confidence: 0.96,
                      evidence: [.init(basis: .observation, label: "Reference", detail: "Verified")],
                      investigation: .verifiedKeepFixture),
            ])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        let target = store.candidates[0]
        let untouched = store.candidates[1]

        store.startCandidateReassessment(target.id)

        XCTAssertTrue(store.isReassessingCandidate(target.id))
        XCTAssertFalse(store.isReassessingCandidate(untouched.id))
        guard case .idle = store.agentState else {
            return XCTFail("a row-level task must not replace the plan-wide status")
        }
        try await waitUntilCandidateFinished(store)

        XCTAssertEqual(store.recommendation(for: target.id).origin, .agent)
        XCTAssertEqual(store.recommendation(for: target.id).disposition, .keep)
        XCTAssertFalse(store.isSelected(target))
        XCTAssertEqual(store.recommendation(for: untouched.id).origin, .scanner)
        XCTAssertEqual(store.recommendation(for: untouched.id).disposition, .delete)
        XCTAssertTrue(store.isSelected(untouched))
        guard case .idle = store.agentState else {
            return XCTFail("completing one row must not claim a full-plan review")
        }
    }

    func testCandidateReassessmentAnalyzesProtectedSelectedCandidate() async throws {
        let fixture = try makeFixture()
        let protectedPath = fixture.list.categories[0].items[0].path
        let analyzer = FakeCleanupAnalyzer(delay: 40_000_000) { input in
            XCTAssertEqual(input.candidates.count, 1)
            XCTAssertEqual(input.focusedCandidateId, input.candidates[0].candidateId)
            XCTAssertNotNil(input.candidates[0].runningApp)
            XCTAssertTrue(input.candidates[0].deepReviewRequired)
            return CleanupAgentAnalysis(summary: "focused protected row", recommendations: [
                .init(candidateId: input.candidates[0].candidateId, disposition: .keep,
                      reason: "This selected directory is a mixed active cache container.",
                      consequence: "Keep the parent and inspect narrower children.",
                      confidence: 0.95,
                      evidence: [.init(basis: .observation, label: "Directory scope",
                                       detail: "The selected parent contains multiple consumers.")],
                      investigation: .verifiedKeepFixture),
            ])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(
            list: fixture.list, snapshot: fixture.snapshot,
            locked: [protectedPath: .notCleanable(reason: "Broad parent is protected")],
            hasAgentConsent: true)
        let target = try XCTUnwrap(store.candidates.first(where: { $0.path == protectedPath }))
        let untouched = try XCTUnwrap(store.candidates.first(where: { $0.id != target.id }))

        store.startCandidateReassessment(target.id)
        try await waitUntilCandidateFinished(store)

        let judgment = store.recommendation(for: target.id)
        XCTAssertEqual(judgment.origin, .agent)
        XCTAssertEqual(judgment.disposition, .keep)
        XCTAssertTrue(judgment.evidence.contains(where: {
            $0.detail.contains("mixed active cache container")
        }))
        XCTAssertFalse(store.isSelected(target))
        XCTAssertEqual(store.recommendation(for: untouched.id).origin, .scanner)
    }

    func testStoppingCandidateReassessmentPreservesThePreviousJudgment() async throws {
        let fixture = try makeFixture()
        let analyzer = FakeCleanupAnalyzer(delay: 1_000_000_000) { input in
            CleanupAgentAnalysis(summary: "late", recommendations: input.candidates.map {
                .init(candidateId: $0.candidateId, disposition: .keep,
                      reason: "Late result.", consequence: "Must never land.", confidence: 1,
                      evidence: [.init(label: "Late", detail: "Cancelled")],
                      investigation: .verifiedKeepFixture)
            })
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot, locked: [:], hasAgentConsent: true)
        let target = store.candidates[0]

        store.startCandidateReassessment(target.id)
        store.stopAgentAnalysis()

        guard case .stopped(let candidateId, _) = store.candidateAgentState else {
            return XCTFail("the stopped state must remain attached to the target row")
        }
        XCTAssertEqual(candidateId, target.id)
        XCTAssertEqual(store.recommendation(for: target.id).origin, .scanner)
        XCTAssertTrue(store.isSelected(target))
        XCTAssertTrue(store.canConfirmPlan)
        guard case .idle = store.agentState else {
            return XCTFail("stopping one row must not stop the plan-wide review state")
        }
    }

    func testLiveCodexReturnsSchemaValidCandidateJudgmentsWhenEnabled() async throws {
        guard Foundation.ProcessInfo.processInfo.environment["BURROW_RUN_CODEX_INTEGRATION"] == "1" else {
            throw XCTSkip("Set BURROW_RUN_CODEX_INTEGRATION=1 for the authenticated Codex smoke test")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-live-codex-fixture-\(UUID().uuidString)")
        let cache = root.appendingPathComponent("ExampleEditor/DerivedData", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("generated object fixture".utf8).write(
            to: cache.appendingPathComponent("example.o"))
        defer { try? FileManager.default.removeItem(at: root) }
        let input = CleanupAgentAnalysisInput(
            planId: UUID().uuidString, planRevision: 1,
            candidates: [
                .init(candidateId: "cand-old-build",
                      path: cache.path,
                      category: "Developer tools", sizeBytes: 800_000_000, itemCount: 4000,
                      runningApp: nil, sensitivePathHint: false,
                      deepReviewRequired: true),
            ])
        let result = try await CodexCleanupAgentAdapter(softBudget: 85).analyze(input)
        XCTAssertTrue(CodexCleanupAgentAdapter.hasExactThreeWayCoverage(
            result, candidates: input.candidates))
        XCTAssertEqual(result.recommendations.map(\.candidateId), ["cand-old-build"])
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

    private func waitUntilCandidateFinished(_ store: CleanupPlanStore) async throws {
        for _ in 0..<100 {
            if !store.hasActiveAgentAnalysis { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Candidate reassessment timed out")
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
