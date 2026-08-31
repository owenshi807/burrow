import XCTest
@testable import Burrow

final class CleanupRuntimeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let proposed = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-runtime-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: true)
        root = URL(fileURLWithPath: try XCTUnwrap(
            InvokingUserIdentity.canonicalPath(proposed.path)), isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testDeterministicPolicyDoesNotTreatUnknownOrModelsAsSafe() {
        let unknown = CleanList.Item(
            path: root.appendingPathComponent("mystery").path,
            sizeBytes: 10, sizeText: "10B", itemCount: nil)
        XCTAssertEqual(CleanupCandidatePolicy.classify(
            item: unknown, category: "Other", lock: nil).disposition, .review)

        let model = CleanList.Item(
            path: root.appendingPathComponent(".cache/huggingface/models--example").path,
            sizeBytes: 4_000_000_000, sizeText: "4GB", itemCount: nil)
        let meaning = CleanupCandidatePolicy.classify(
            item: model, category: "Developer tools", lock: nil)
        XCTAssertEqual(meaning.disposition, .review)
        XCTAssertEqual(meaning.regenerationCost, .high)
    }

    func testDeterministicPolicyRecommendsGeneratedCacheAndHonorsLocks() {
        let cache = CleanList.Item(
            path: root.appendingPathComponent("Example/Cache").path,
            sizeBytes: 1_024, sizeText: "1KB", itemCount: 1)
        XCTAssertEqual(CleanupCandidatePolicy.classify(
            item: cache, category: "App caches", lock: nil).disposition,
                       .recommendCleanup)
        XCTAssertEqual(CleanupCandidatePolicy.classify(
            item: cache, category: "App caches", lock: .appOpen(appName: "Example"))
            .disposition, .protect)
    }

    func testLedgerRoundTripsCompletePerItemReceipt() throws {
        let ledger = CleanupLedger(directory: root.appendingPathComponent("ledger"))
        let item = CleanupRunRecord.Item(
            id: "cand-1", path: "/tmp/cache", displayName: "cache",
            category: "App caches", sizeBytes: 42,
            policy: .init(disposition: .recommendCleanup, reason: "Generated",
                          ownerHint: "Example", recoverability: .regenerable,
                          regenerationCost: .low, sensitive: false,
                          evidence: ["Cache shape"]),
            selected: true, action: .trash, outcome: .trashed,
            detail: nil, trashDestination: "/tmp/Trash/cache")
        var run = CleanupRunRecord.reviewed(
            planID: "plan-1", revision: 1, source: .agent, mode: .trash,
            initiatedBy: "Test Agent", items: [item])
        run.status = .completed
        run.endedAt = Date()
        try ledger.record(run)

        let loaded = try XCTUnwrap(ledger.run(id: run.id))
        XCTAssertEqual(loaded.id, run.id)
        XCTAssertEqual(loaded.status, run.status)
        XCTAssertEqual(loaded.items, run.items)
        XCTAssertEqual(loaded.startedAt.timeIntervalSince1970,
                       run.startedAt.timeIntervalSince1970, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(loaded.endedAt).timeIntervalSince1970,
                       try XCTUnwrap(run.endedAt).timeIntervalSince1970,
                       accuracy: 0.000_001)
        XCTAssertEqual(ledger.recent(limit: 1).map(\.id), [run.id])
    }

    func testStagedPlanExecutesOnlyItsPinnedRecommendedCandidateAndRecordsTrashPath() throws {
        let cache = root.appendingPathComponent("Example/Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("generated".utf8).write(to: cache.appendingPathComponent("blob"))
        let list = CleanList(categories: [
            .init(name: "App caches", items: [
                .init(path: cache.path, sizeBytes: 9, sizeText: "9B", itemCount: 1),
            ]),
        ], summaryTotalText: "9B", summaryItemCount: 1)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        let plan = StagedCleanupPlan.make(list: list, snapshot: snapshot, locks: [:])
        let planStore = StagedCleanupPlanStore(directory: root.appendingPathComponent("plans"))
        let ledger = CleanupLedger(directory: root.appendingPathComponent("ledger"))
        try planStore.save(plan)
        let service = CleanupPlanService(plans: planStore, ledger: ledger)
        let candidate = try XCTUnwrap(plan.candidates.first)
        XCTAssertTrue(candidate.selectedByDefault)
        let persisted = try XCTUnwrap(planStore.load(id: plan.id))
        let persistedCandidate = try XCTUnwrap(persisted.candidates.first)
        XCTAssertEqual(persistedCandidate.id, candidate.id)
        XCTAssertEqual(persistedCandidate.identityToken, candidate.identityToken)
        let selectedList = persisted.list(selectedIDs: [candidate.id])
        XCTAssertEqual(selectedList.categories.flatMap(\.items).map(\.path), [cache.path])
        let recaptured = try CleanupSnapshot.capture(
            list: selectedList, approvedRootURLs: [root], now: persisted.createdAt)
        XCTAssertEqual(recaptured.items.map(\.identity.path), [cache.path])
        let fakeTrash = root.appendingPathComponent("fake-trash", isDirectory: true)

        let run = try service.execute(
            planID: plan.id, revision: plan.revision,
            candidateIDs: [candidate.id], initiatedBy: "Test Agent",
            approvedRootURLs: [root],
            move: { source in
                try FileManager.default.moveItem(at: source, to: fakeTrash)
                return fakeTrash
            })

        XCTAssertEqual(run.status, .completed)
        XCTAssertEqual(run.items.first(where: \.selected)?.outcome, .trashed)
        XCTAssertEqual(run.items.first(where: \.selected)?.trashDestination, fakeTrash.path)
        let receipt = try XCTUnwrap(ledger.run(id: run.id))
        XCTAssertEqual(receipt.id, run.id)
        XCTAssertEqual(receipt.status, run.status)
        XCTAssertEqual(receipt.items, run.items)
        XCTAssertEqual(receipt.summary, run.summary)
        XCTAssertThrowsError(try service.execute(
            planID: plan.id, revision: plan.revision,
            candidateIDs: [candidate.id], initiatedBy: "Test Agent",
            approvedRootURLs: [root], move: nil))
    }

    func testStagedPlanSkipsAReplacedCandidateWithoutCallingTheMover() throws {
        let cache = root.appendingPathComponent("Example/Cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: cache.appendingPathComponent("blob"))
        let list = CleanList(categories: [
            .init(name: "App caches", items: [
                .init(path: cache.path, sizeBytes: 3, sizeText: "3B", itemCount: 1),
            ]),
        ], summaryTotalText: "3B", summaryItemCount: 1)
        let snapshot = try CleanupSnapshot.capture(list: list, approvedRootURLs: [root])
        let plan = StagedCleanupPlan.make(list: list, snapshot: snapshot, locks: [:])
        let planStore = StagedCleanupPlanStore(directory: root.appendingPathComponent("plans"))
        let ledger = CleanupLedger(directory: root.appendingPathComponent("ledger"))
        try planStore.save(plan)
        let candidate = try XCTUnwrap(plan.candidates.first)

        try FileManager.default.removeItem(at: cache)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: cache.appendingPathComponent("blob"))
        var moverCalled = false
        let run = try CleanupPlanService(plans: planStore, ledger: ledger).execute(
            planID: plan.id, revision: plan.revision,
            candidateIDs: [candidate.id], initiatedBy: "Test Agent",
            approvedRootURLs: [root], move: { source in
                moverCalled = true
                return source
            })

        XCTAssertFalse(moverCalled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.path))
        XCTAssertEqual(run.status, .failed)
        XCTAssertEqual(run.items.first(where: \.selected)?.outcome, .skipped)
        XCTAssertTrue(run.items.first(where: \.selected)?.detail?.contains("changed") == true)
    }
}
