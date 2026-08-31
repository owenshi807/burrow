import XCTest
@testable import Burrow

private struct RoutingContractAnalyzer: CleanupAgentAnalyzing {
    let displayName = "Routing Test Agent"
    let delayNanoseconds: UInt64
    let result: @Sendable (CleanupAgentAnalysisInput) -> CleanupAgentAnalysis

    func analyze(_ input: CleanupAgentAnalysisInput) async throws -> CleanupAgentAnalysis {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return result(input)
    }
}

@MainActor
final class CleanupAgentRoutingContractTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let proposed = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-routing-contract-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: proposed, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: try XCTUnwrap(
            InvokingUserIdentity.canonicalPath(proposed.path)))
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testMissingRoutingFieldsDecodeAsEmptyForOlderAgents() throws {
        let original = CleanupAgentAnalysis(summary: "legacy", recommendations: [])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "passThroughCandidateIDs")
        object.removeValue(forKey: "unresolvedCandidateIDs")
        object.removeValue(forKey: "discoveredCandidates")

        let decoded = try JSONDecoder().decode(
            CleanupAgentAnalysis.self,
            from: JSONSerialization.data(withJSONObject: object))

        XCTAssertEqual(decoded.passThroughCandidateIDs, [])
        XCTAssertEqual(decoded.unresolvedCandidateIDs, [])
        XCTAssertEqual(decoded.discoveredCandidates, [])
    }

    func testPassThroughRetainsScannerOriginAndSelection() async throws {
        let fixture = try makeFixture(count: 2)
        let analyzer = RoutingContractAnalyzer(delayNanoseconds: 0) { input in
            CleanupAgentAnalysis(
                summary: "one deep review, one scanner pass-through",
                recommendations: [Self.deleteRecommendation(input.candidates[0].candidateId)],
                passThroughCandidateIDs: [input.candidates[1].candidateId])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot,
                   locked: [:], hasAgentConsent: true)
        let passThrough = store.candidates[1]
        XCTAssertTrue(store.isSelected(passThrough))

        store.startAgentAnalysis()
        try await waitUntilReady(store)

        XCTAssertEqual(store.recommendation(for: passThrough.id).origin, .scanner)
        XCTAssertEqual(store.recommendation(for: passThrough.id).agentRunId, nil)
        XCTAssertTrue(store.isSelected(passThrough))
        XCTAssertEqual(store.agentProgress?.reviewedCount, 2)
    }

    func testUnresolvedRouteBecomesUnselectedBurrowSafetyKeep() async throws {
        let fixture = try makeFixture(count: 2)
        let analyzer = RoutingContractAnalyzer(delayNanoseconds: 0) { input in
            CleanupAgentAnalysis(
                summary: "one unresolved",
                recommendations: [],
                passThroughCandidateIDs: [input.candidates[1].candidateId],
                unresolvedCandidateIDs: [input.candidates[0].candidateId])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot,
                   locked: [:], hasAgentConsent: true)
        let unresolved = store.candidates[0]
        XCTAssertTrue(store.isSelected(unresolved))

        store.startAgentAnalysis()
        try await waitUntilReady(store)

        let recommendation = store.recommendation(for: unresolved.id)
        XCTAssertEqual(recommendation.origin, .burrowSafety)
        XCTAssertEqual(recommendation.disposition, .keep)
        XCTAssertFalse(store.isSelected(unresolved))
        XCTAssertEqual(store.agentProgress?.reviewedCount, 2)
    }

    func testMissingDuplicateAndOverlappingRoutesFailClosedPerCandidate() async throws {
        let fixture = try makeFixture(count: 3)
        let analyzer = RoutingContractAnalyzer(delayNanoseconds: 0) { input in
            let first = input.candidates[0].candidateId
            let third = input.candidates[2].candidateId
            return CleanupAgentAnalysis(
                summary: "malformed routing",
                recommendations: [Self.deleteRecommendation(first)],
                passThroughCandidateIDs: [first, "foreign-candidate"],
                unresolvedCandidateIDs: [third, third])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot,
                   locked: [:], hasAgentConsent: true)

        store.startAgentAnalysis()
        try await waitUntilReady(store)

        XCTAssertEqual(store.agentProgress?.reviewedCount, 3)
        for candidate in store.candidates {
            XCTAssertEqual(store.recommendation(for: candidate.id).origin, .burrowSafety)
            XCTAssertEqual(store.recommendation(for: candidate.id).disposition, .keep)
            XCTAssertFalse(store.isSelected(candidate))
        }
    }

    func testForeignRouteInvalidatesThePurportedExactPartition() async throws {
        let fixture = try makeFixture(count: 2)
        let analyzer = RoutingContractAnalyzer(delayNanoseconds: 0) { input in
            CleanupAgentAnalysis(
                summary: "foreign route",
                recommendations: [Self.deleteRecommendation(input.candidates[0].candidateId)],
                passThroughCandidateIDs: [input.candidates[1].candidateId, "foreign-candidate"])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot,
                   locked: [:], hasAgentConsent: true)

        store.startAgentAnalysis()
        try await waitUntilReady(store)

        XCTAssertTrue(store.candidates.allSatisfy {
            store.recommendation(for: $0.id).origin == .burrowSafety
                && !store.isSelected($0)
        })
    }

    func testLatePassThroughDoesNotOverwriteUserCheckboxOverride() async throws {
        let fixture = try makeFixture(count: 2)
        let analyzer = RoutingContractAnalyzer(delayNanoseconds: 80_000_000) { input in
            CleanupAgentAnalysis(
                summary: "late routing",
                recommendations: [Self.deleteRecommendation(input.candidates[1].candidateId)],
                passThroughCandidateIDs: [input.candidates[0].candidateId])
        }
        let store = CleanupPlanStore(analyzer: analyzer)
        store.load(list: fixture.list, snapshot: fixture.snapshot,
                   locked: [:], hasAgentConsent: true)
        let overridden = store.candidates[0]

        store.startAgentAnalysis()
        store.toggleCandidate(overridden.id)
        XCTAssertFalse(store.isSelected(overridden))
        try await waitUntilReady(store)

        XCTAssertFalse(store.isSelected(overridden))
        XCTAssertEqual(store.recommendation(for: overridden.id).origin, .scanner)
        XCTAssertTrue(store.userOverrides.contains(overridden.id))
        XCTAssertFalse(store.canUseAgentCTA)
    }

    nonisolated private static func deleteRecommendation(
        _ id: String
    ) -> CleanupAgentRecommendation {
        CleanupAgentRecommendation(
            candidateId: id,
            disposition: .delete,
            reason: "Direct inspection established that this cache is rebuildable.",
            consequence: "The owning tool recreates it on demand.",
            confidence: 0.94,
            evidence: [.init(
                basis: .observation,
                label: "Filesystem inspection",
                detail: "The candidate contains only rebuildable cache data.")])
    }

    private func makeFixture(count: Int) throws -> (list: CleanList, snapshot: CleanupSnapshot) {
        var items: [CleanList.Item] = []
        for index in 0..<count {
            let url = root.appendingPathComponent("Tool-\(index)/Cache", isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            items.append(.init(
                path: url.path,
                sizeBytes: Int64((index + 1) * 1_000),
                sizeText: "\(index + 1)KB",
                itemCount: index + 1))
        }
        let list = CleanList(
            categories: [.init(name: "Developer tools", items: items)],
            summaryTotalText: "fixture",
            summaryItemCount: count)
        return (list, try CleanupSnapshot.capture(list: list, approvedRootURLs: [root]))
    }

    private func waitUntilReady(_ store: CleanupPlanStore) async throws {
        for _ in 0..<150 {
            if case .ready = store.agentState { return }
            if case .degraded(_, let reason) = store.agentState {
                XCTFail(reason)
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Agent routing analysis timed out")
    }
}
