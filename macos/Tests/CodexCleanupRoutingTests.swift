import XCTest
@testable import Burrow

final class CodexCleanupRoutingTests: XCTestCase {
    func testRoutingUpgradesRouterAndHostCandidatesButNeverLockedRows() {
        let routine = candidate("routine", path: "/tmp/routine")
        let routerUpgrade = candidate("router", path: "/tmp/ambiguous")
        let hostForced = candidate("forced", path: "/tmp/large", deep: true)
        let locked = candidate(
            "locked", path: "/tmp/running", runningApp: "Messages is open", deep: true)

        let routing = CodexCleanupAgentAdapter.resolveRouting(
            for: [routine, routerUpgrade, hostForced, locked],
            routerDeepReview: [
                .init(candidateId: routerUpgrade.candidateId, reason: "ambiguous owner"),
                .init(candidateId: locked.candidateId, reason: "router should not override safety"),
                .init(candidateId: "unknown", reason: "not in snapshot"),
            ])

        XCTAssertEqual(routing.deepReview.map(\.candidateId), ["router", "forced"])
        XCTAssertEqual(routing.passThroughCandidateIDs, ["routine"])
        XCTAssertEqual(routing.unresolvedCandidateIDs, ["locked"])
        let routerPayload = CodexCleanupAgentAdapter.routingPayloadJSON(
            for: [routine, routerUpgrade, hostForced, locked])
            .replacingOccurrences(of: "\\/", with: "/")
        XCTAssertTrue(routerPayload.contains(routine.path))
        XCTAssertFalse(routerPayload.contains(locked.path),
                       "locked rows must not consume router context")
    }

    func testFocusedReviewRoutesLockedCandidateToDeepAnalysis() {
        let locked = candidate(
            "locked", path: "/tmp/running", runningApp: "Messages is open", deep: true)

        let routing = CodexCleanupAgentAdapter.resolveRouting(
            for: [locked], routerDeepReview: [], focusedCandidateId: locked.candidateId)

        XCTAssertEqual(routing.deepReview.map(\.candidateId), ["locked"])
        XCTAssertTrue(routing.passThroughCandidateIDs.isEmpty)
        XCTAssertTrue(routing.unresolvedCandidateIDs.isEmpty)
    }

    func testRoutingKeepsAnOverlappingHierarchyInsideOneSafetyBoundary() {
        let parent = candidate("parent", path: "/tmp/cache")
        let child = candidate("child", path: "/tmp/cache/current-model")

        let routing = CodexCleanupAgentAdapter.resolveRouting(
            for: [parent, child],
            routerDeepReview: [.init(candidateId: "child", reason: "active model ambiguity")])

        XCTAssertEqual(Set(routing.deepReview.map(\.candidateId)), ["parent", "child"])
        XCTAssertTrue(routing.passThroughCandidateIDs.isEmpty)
        XCTAssertTrue(routing.unresolvedCandidateIDs.isEmpty)
    }

    func testLockedDescendantPreventsScannerParentPassThrough() {
        let parent = candidate("parent", path: "/tmp/cache")
        let runningChild = candidate(
            "running", path: "/tmp/cache/live", runningApp: "WaveScribe is open")

        let routing = CodexCleanupAgentAdapter.resolveRouting(
            for: [parent, runningChild], routerDeepReview: [])

        XCTAssertEqual(routing.deepReview.map(\.candidateId), ["parent"])
        XCTAssertTrue(routing.passThroughCandidateIDs.isEmpty)
        XCTAssertEqual(routing.unresolvedCandidateIDs, ["running"])
    }

    func testLockedBroadAncestorDoesNotForceIndependentChildIntoDeepReview() {
        let invalidRoot = candidate(
            "root", path: "/Users/test", runningApp: "This broad path is not cleanable")
        let cache = candidate("cache", path: "/Users/test/Library/Caches/app")

        let routing = CodexCleanupAgentAdapter.resolveRouting(
            for: [invalidRoot, cache], routerDeepReview: [])

        XCTAssertTrue(routing.deepReview.isEmpty)
        XCTAssertEqual(routing.passThroughCandidateIDs, ["cache"])
        XCTAssertEqual(routing.unresolvedCandidateIDs, ["root"])
    }

    func testUnresolvedChildInvalidatesCompletedAncestorJudgment() {
        let parent = candidate("parent", path: "/tmp/cache")
        let child = candidate("child", path: "/tmp/cache/model")

        let closed = CodexCleanupAgentAdapter.closeUnresolvedHierarchies(
            candidates: [parent, child],
            recommendations: [recommendation("parent")],
            unresolvedCandidateIDs: ["child"])

        XCTAssertTrue(closed.recommendations.isEmpty)
        XCTAssertEqual(closed.unresolvedCandidateIDs, ["parent", "child"])
    }

    func testUnresolvedBroadAncestorDoesNotInvalidateCompletedChildJudgment() {
        let parent = candidate("parent", path: "/tmp/cache")
        let child = candidate("child", path: "/tmp/cache/model")

        let closed = CodexCleanupAgentAdapter.closeUnresolvedHierarchies(
            candidates: [parent, child],
            recommendations: [recommendation("child")],
            unresolvedCandidateIDs: ["parent"])

        XCTAssertEqual(closed.recommendations.map(\.candidateId), ["child"])
        XCTAssertEqual(closed.unresolvedCandidateIDs, ["parent"])
    }

    func testReasoningBudgetMatchesStageComplexity() {
        XCTAssertEqual(CodexCleanupAgentAdapter.reasoningEffort(for: "triage"), "low")
        XCTAssertEqual(CodexCleanupAgentAdapter.reasoningEffort(for: "consistency"), "low")
        XCTAssertEqual(
            CodexCleanupAgentAdapter.reasoningEffort(for: "recommendation-0"), "low")
    }

    func testInteractiveCleanupUsesFastModelWithExplicitOverride() {
        XCTAssertEqual(CodexCleanupAgentAdapter.modelName(environment: [:]), "gpt-5.4-mini")
        XCTAssertEqual(CodexCleanupAgentAdapter.modelName(
            environment: ["BURROW_CODEX_MODEL": "gpt-5.6-terra"]), "gpt-5.6-terra")
    }

    func testCodexConnectionEnvironmentUsesOnlyAllowlistedNetworkValues() {
        let resolved = CodexCleanupAgentAdapter.networkEnvironmentOverrides(
            baseEnvironment: [
                "HTTPS_PROXY": "http://launch-proxy:7890",
                "DYLD_INSERT_LIBRARIES": "/tmp/injected.dylib",
            ],
            loginShellDump: """
            HTTP_PROXY=http://shell-proxy:7890
            HTTPS_PROXY=http://shell-proxy:7890
            NO_PROXY=localhost,127.0.0.1
            OPENAI_API_KEY=secret
            PATH=/untrusted/bin
            """)

        XCTAssertEqual(resolved["HTTP_PROXY"], "http://shell-proxy:7890")
        XCTAssertEqual(resolved["HTTPS_PROXY"], "http://launch-proxy:7890")
        XCTAssertEqual(resolved["NO_PROXY"], "localhost,127.0.0.1")
        XCTAssertNil(resolved["OPENAI_API_KEY"])
        XCTAssertNil(resolved["PATH"])
        XCTAssertNil(resolved["DYLD_INSERT_LIBRARIES"])
    }

    func testCodexConnectionEnvironmentRejectsControlCharactersAndHugeValues() {
        let resolved = CodexCleanupAgentAdapter.networkEnvironmentOverrides(
            baseEnvironment: [:],
            loginShellDump: "HTTP_PROXY=http://ok:7890\nHTTPS_PROXY=bad\u{0007}value\n"
                + "ALL_PROXY=" + String(repeating: "x", count: 4_097) + "\n")

        XCTAssertEqual(resolved, ["HTTP_PROXY": "http://ok:7890"])
    }

    func testDefaultRecommendationBatchesAreSmallEnoughForTheSharedBudget() {
        let values = (0..<11).map { candidate("c\($0)", path: "/tmp/c\($0)") }
        let batches = CodexCleanupAgentAdapter.recommendationBatches(for: values)

        XCTAssertEqual(batches.flatMap { $0 }.count, values.count)
        XCTAssertTrue(batches.allSatisfy { $0.count <= 4 })
    }

    func testPriorityReviewPaysForOneLargestImpactBoundary() {
        let values = (0..<9).map { index in
            candidate("c\(index)", path: "/tmp/c\(index)", size: Int64(index + 1) * 100)
        }

        let batch = CodexCleanupAgentAdapter.priorityReviewBatch(for: values)

        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch.map(\.candidateId), ["c8"])
    }

    func testEphemeralCodexEnvironmentCopiesThenRevokesOnlyTemporaryCredential() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-codex-environment-test-\(UUID().uuidString)")
        let sourceHome = root.appendingPathComponent("source-codex-home")
        let run = root.appendingPathComponent("run")
        try FileManager.default.createDirectory(at: sourceHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceCredential = sourceHome.appendingPathComponent("auth.json")
        try Data("fixture-credential".utf8).write(to: sourceCredential)

        let isolated = try CodexCleanupAgentAdapter.EphemeralCodexEnvironment(
            runDirectory: run, stage: "recommendation/priority",
            baseEnvironment: ["CODEX_HOME": sourceHome.path],
            userHome: root.appendingPathComponent("unused-home"))

        XCTAssertEqual(try Data(contentsOf: isolated.credentialURL),
                       Data("fixture-credential".utf8))
        let environment = isolated.applying(to: ["PATH": "/usr/bin"])
        XCTAssertEqual(environment["HOME"], isolated.homeURL.path)
        XCTAssertEqual(environment["CODEX_HOME"], isolated.codexHomeURL.path)
        isolated.revokeCredential()
        XCTAssertFalse(FileManager.default.fileExists(atPath: isolated.credentialURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceCredential.path),
                      "revocation must never touch the user's source credential")
    }

    func testRecommendationPromptDoesNotExposeUnrelatedPaths() {
        let target = candidate("target", path: "/Users/test/.cache/models")
        let child = candidate("child", path: "/Users/test/.cache/models/v1")
        let unrelated = candidate("other", path: "/Users/test/Secret/Unrelated-Path")
        let input = CleanupAgentAnalysisInput(
            planId: "plan", planRevision: 1, candidates: [target, child, unrelated])

        let prompt = CodexCleanupAgentAdapter.recommendationPrompt(
            input: input, batch: [target],
            triage: [
                .init(candidateId: "target", reason: "target reason"),
                .init(candidateId: "other", reason: "unrelated triage reason sentinel"),
            ], responseLanguage: "English")
        let decodedSlashes = prompt.replacingOccurrences(of: "\\/", with: "/")

        XCTAssertTrue(decodedSlashes.contains(target.path))
        XCTAssertTrue(decodedSlashes.contains(child.path), "hierarchy neighbors remain available")
        XCTAssertTrue(prompt.contains(unrelated.candidateId), "global index retains identity")
        XCTAssertFalse(decodedSlashes.contains(unrelated.path),
                       "unrelated paths must not leak into a batch")
        XCTAssertFalse(prompt.contains("unrelated triage reason sentinel"))
    }

    func testThreeWayCoverageRequiresDisjointExactPartition() {
        let values = [candidate("a", path: "/tmp/a"),
                      candidate("b", path: "/tmp/b"),
                      candidate("c", path: "/tmp/c")]
        let complete = CleanupAgentAnalysis(
            summary: "complete",
            recommendations: [recommendation("a")],
            passThroughCandidateIDs: ["b"], unresolvedCandidateIDs: ["c"])
        XCTAssertTrue(CodexCleanupAgentAdapter.hasExactThreeWayCoverage(
            complete, candidates: values))

        let duplicate = CleanupAgentAnalysis(
            summary: "bad", recommendations: [recommendation("a")],
            passThroughCandidateIDs: ["a", "b"], unresolvedCandidateIDs: ["c"])
        XCTAssertFalse(CodexCleanupAgentAdapter.hasExactThreeWayCoverage(
            duplicate, candidates: values))

        let missing = CleanupAgentAnalysis(
            summary: "bad", recommendations: [recommendation("a")],
            passThroughCandidateIDs: ["b"])
        XCTAssertFalse(CodexCleanupAgentAdapter.hasExactThreeWayCoverage(
            missing, candidates: values))
    }

    func testSoftBudgetSurfacesBoundedFailureInsteadOfClaimingReviewCompleted() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-routing-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("slow-codex")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let input = CleanupAgentAnalysisInput(
            planId: "plan", planRevision: 1,
            candidates: [candidate("a", path: "/tmp/a", deep: true)])

        do {
            _ = try await CodexCleanupAgentAdapter(
                executableOverride: executable.path, softBudget: 0.05).analyze(input)
            XCTFail("budget exhaustion must remain a visible retryable failure")
        } catch {
            XCTAssertEqual(
                error.localizedDescription,
                NSLocalizedString(
                    "Codex did not finish within the analysis time limit. Nothing was changed. Retry when the Agent is available.",
                    comment: "cleanup Agent timeout"))
        }
    }

    private func candidate(
        _ id: String, path: String, runningApp: String? = nil, deep: Bool = false,
        size: Int64 = 100
    ) -> CleanupAgentCandidateInput {
        CleanupAgentCandidateInput(
            candidateId: id, path: path, category: "Developer tools",
            sizeBytes: size, itemCount: 1, runningApp: runningApp,
            sensitivePathHint: false, deepReviewRequired: deep)
    }

    private func recommendation(
        _ id: String, evidence: [CleanupAgentEvidence] = [
            .init(basis: .observation, label: "Cache", detail: "Recreatable cache"),
        ]
    ) -> CleanupAgentRecommendation {
        CleanupAgentRecommendation(
            candidateId: id, disposition: .delete, reason: "unused cache",
            consequence: "rebuilt later", confidence: 0.9, evidence: evidence)
    }
}
