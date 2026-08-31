//
//  CleanupPlanService.swift
//  Burrow
//
//  Shared staged-plan service for MCP.  Discovery creates candidate IDs;
//  execution accepts only those IDs, rechecks the original identities and
//  scope timestamps, moves the stable subset to Trash, and writes a receipt.
//

import Foundation

struct CleanupPlanService: Sendable {
    let plans: StagedCleanupPlanStore
    let ledger: CleanupLedger

    init(plans: StagedCleanupPlanStore = .shared,
         ledger: CleanupLedger = .shared) {
        self.plans = plans
        self.ledger = ledger
    }

    func stage(list: CleanList, user: InvokingUserIdentity) throws -> StagedCleanupPlan {
        let snapshot = try CleanupSnapshot.capture(
            list: list, approvedRootURLs: CleanupSnapshot.approvedRoots(for: user))
        var locks = CleanLock.lockedPaths(in: list, running: CleanLock.runningApps())
        for skipped in snapshot.skipped {
            locks[skipped.path] = .notCleanable(reason: skipped.reason)
        }
        let plan = StagedCleanupPlan.make(
            list: list, snapshot: snapshot, locks: locks, now: snapshot.createdAt)
        try plans.save(plan)
        return plan
    }

    func execute(planID: UUID, revision: Int, candidateIDs: [String],
                 initiatedBy: String = "MCP Agent") throws -> CleanupRunRecord {
        try execute(planID: planID, revision: revision, candidateIDs: candidateIDs,
                    initiatedBy: initiatedBy, approvedRootURLs: nil, move: nil)
    }

    /// Injectable roots/mover keep the complete safety transaction testable
    /// without touching a user's real Trash.
    func execute(planID: UUID, revision: Int, candidateIDs: [String],
                 initiatedBy: String,
                 approvedRootURLs: [URL]?,
                 move: ((URL) throws -> URL)?) throws -> CleanupRunRecord {
        guard !candidateIDs.isEmpty, Set(candidateIDs).count == candidateIDs.count else {
            throw MCPToolError.badArguments("candidate_ids must be a non-empty list with no duplicates.")
        }
        guard let preview = plans.load(id: planID), preview.revision == revision else {
            throw MCPToolError.badArguments("Unknown cleanup plan or revision.")
        }
        let requested = Set(candidateIDs)
        let known = Set(preview.candidates.map(\.id))
        guard requested.isSubset(of: known) else {
            throw MCPToolError.badArguments("candidate_ids contains an item that Burrow did not stage.")
        }
        let disallowed = preview.candidates.filter {
            requested.contains($0.id) && !$0.selectedByDefault
        }
        guard disallowed.isEmpty else {
            throw MCPToolError.badArguments(
                "Burrow did not deterministically recommend these candidates: "
                    + disallowed.map(\.id).joined(separator: ", ")
                    + ". Review them in the Burrow UI instead.")
        }

        let runID = UUID()
        let plan = try plans.claim(id: planID, revision: revision, runID: runID)
        var record = CleanupRunRecord.reviewed(
            id: runID, planID: plan.id.uuidString.lowercased(), revision: plan.revision,
            source: .agent, mode: .trash, initiatedBy: initiatedBy,
            items: plan.candidates.map { candidate in
                CleanupRunRecord.Item(
                    id: candidate.id, path: candidate.path,
                    displayName: candidate.displayName, category: candidate.category,
                    sizeBytes: candidate.sizeBytes, policy: candidate.meaning,
                    selected: requested.contains(candidate.id), action: .none,
                    outcome: requested.contains(candidate.id) ? .pending : .skipped,
                    detail: requested.contains(candidate.id) ? nil : "Not selected by the Agent.",
                    trashDestination: nil)
            })
        try ledger.record(record)

        do {
            let selectedList = plan.list(selectedIDs: requested)
            let roots: [URL]
            if let approvedRootURLs {
                roots = approvedRootURLs
            } else {
                roots = CleanupSnapshot.approvedRoots(for: try InvokingUserIdentity.current())
            }
            // The original scan time is the scope cutoff. Capturing current
            // identities does not reset the clock or make intervening writes safe.
            let snapshot = try CleanupSnapshot.capture(
                list: selectedList, approvedRootURLs: roots, now: plan.createdAt)
            let capturedTokens = Dictionary(
                snapshot.items.map { ($0.identity.path, $0.identity.shellStatToken) },
                uniquingKeysWith: { first, _ in first })
            let stable = plan.candidates.filter {
                requested.contains($0.id)
                    && $0.identityToken != nil
                    && capturedTokens[$0.path] == $0.identityToken
            }
            let stablePaths = stable.map(\.path)
            let unstablePaths = Set(plan.candidates.filter { requested.contains($0.id) }.map(\.path))
                .subtracting(stablePaths)

            guard !stablePaths.isEmpty else {
                return try completedAsChanged(
                    record, plan: plan,
                    detail: "Every selected item changed identity or disappeared after the staged scan.")
            }
            let prepared: CleanupSnapshot.PlanPreparation
            do {
                prepared = try snapshot.preparePlan(selectedPaths: stablePaths)
            } catch CleanupSnapshot.SnapshotError.staleOrChanged {
                return try completedAsChanged(
                    record, plan: plan,
                    detail: "Every selected item changed after the staged scan.")
            }
            let changedPaths = unstablePaths.union(prepared.skippedChangedPaths)
            let result = move.map { CleanupExecutor.moveToTrash(prepared.plan, move: $0) }
                ?? CleanupExecutor.moveToTrash(prepared.plan)
            let outcomes = Dictionary(
                result.outcomes.map { ($0.path, $0) },
                uniquingKeysWith: { first, _ in first })

            for index in record.items.indices where record.items[index].selected {
                let path = record.items[index].path
                record.items[index].action = .trash
                if changedPaths.contains(path) {
                    record.items[index].outcome = .skipped
                    record.items[index].detail = "The item changed after the staged scan."
                } else if let outcome = outcomes[path] {
                    switch outcome.status {
                    case .trashed: record.items[index].outcome = .trashed
                    case .skipped: record.items[index].outcome = .skipped
                    case .failed: record.items[index].outcome = .failed
                    }
                    record.items[index].detail = outcome.detail
                    record.items[index].trashDestination = outcome.destination
                } else {
                    record.items[index].outcome = .skipped
                    record.items[index].detail = "The item did not reach the executable subset."
                }
            }
            let selectedItems = record.items.filter(\.selected)
            let success = selectedItems.filter { $0.outcome == .trashed }.count
            let failed = selectedItems.filter { $0.outcome == .failed }.count
            record.endedAt = Date()
            record.status = success == selectedItems.count ? .completed
                : success > 0 ? .partial : .failed
            record.reclaimedBytes = 0 // Trash is recoverable; bytes free when Trash empties.
            record.summary = "\(success) moved to Trash · \(selectedItems.count - success - failed) skipped · \(failed) failed"
            try ledger.record(record)
            plans.complete(id: plan.id, runID: runID)
            return record
        } catch {
            record.endedAt = Date()
            record.status = .failed
            record.summary = error.localizedDescription
            for index in record.items.indices
            where record.items[index].selected && record.items[index].outcome == .pending {
                record.items[index].outcome = .failed
                record.items[index].detail = error.localizedDescription
            }
            try? ledger.record(record)
            plans.complete(id: plan.id, runID: runID)
            throw error
        }
    }

    private func completedAsChanged(
        _ original: CleanupRunRecord,
        plan: StagedCleanupPlan,
        detail: String
    ) throws -> CleanupRunRecord {
        var record = original
        for index in record.items.indices
        where record.items[index].selected && record.items[index].outcome == .pending {
            record.items[index].action = .trash
            record.items[index].outcome = .skipped
            record.items[index].detail = detail
        }
        record.endedAt = Date()
        record.status = .failed
        record.summary = "0 moved to Trash · \(record.items.filter(\.selected).count) changed and skipped · 0 failed"
        try ledger.record(record)
        plans.complete(id: plan.id, runID: record.id)
        return record
    }
}

enum CleanupPlanWire {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else { return "{}" }
        return string
    }
}

struct CleanupRunsWire: Encodable, Sendable {
    let runs: [CleanupRunRecord]
}

struct CleanupRunDetailWire: Encodable, Sendable {
    let run: CleanupRunRecord
}
