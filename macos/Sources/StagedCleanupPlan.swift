//
//  StagedCleanupPlan.swift
//  Burrow
//
//  Persisted capability object for MCP cleanup.  An Agent may select only
//  candidate IDs emitted by this plan; it never supplies deletion paths.
//  Execution recaptures and compares the original file identity and scopes
//  every candidate to the original scan time.
//

import Foundation
import CryptoKit

struct StagedCleanupPlan: Codable, Equatable, Identifiable, Sendable {
    enum ExecutionState: String, Codable, Sendable { case staged, executing, completed }

    struct Candidate: Codable, Equatable, Identifiable, Sendable {
        let id: String
        let path: String
        let displayName: String
        let category: String
        let sizeBytes: Int64
        let sizeText: String
        let itemCount: Int?
        let identityToken: String?
        let meaning: CleanupCandidateMeaning
        let selectedByDefault: Bool
    }

    let id: UUID
    let revision: Int
    let createdAt: Date
    let candidates: [Candidate]
    let scannerSkipped: [String: String]
    var executionState: ExecutionState
    var executionRunID: UUID?

    static func make(list: CleanList,
                     snapshot: CleanupSnapshot,
                     locks: [String: CleanSelection.LockReason],
                     now: Date = Date()) -> StagedCleanupPlan {
        let id = UUID()
        let identities = Dictionary(
            snapshot.items.map { ($0.identity.path, $0.identity.shellStatToken) },
            uniquingKeysWith: { first, _ in first })
        let skipped = Dictionary(
            snapshot.skipped.map { ($0.path, $0.reason) },
            uniquingKeysWith: { first, _ in first })
        let candidates = list.categories.flatMap { category in
            category.items.map { item -> Candidate in
                let effectiveLock = locks[item.path]
                    ?? skipped[item.path].map { .notCleanable(reason: $0) }
                let meaning = CleanupCandidatePolicy.classify(
                    item: item, category: category.name, lock: effectiveLock)
                return Candidate(
                    id: candidateID(planID: id, path: item.path,
                                    token: identities[item.path] ?? "refused"),
                    path: item.path, displayName: item.displayName,
                    category: category.name, sizeBytes: item.sizeBytes,
                    sizeText: item.sizeText, itemCount: item.itemCount,
                    identityToken: identities[item.path], meaning: meaning,
                    selectedByDefault: meaning.disposition == .recommendCleanup
                        && identities[item.path] != nil)
            }
        }
        return StagedCleanupPlan(
            id: id, revision: 1, createdAt: snapshot.createdAt,
            candidates: candidates, scannerSkipped: skipped,
            executionState: .staged, executionRunID: nil)
    }

    func list(selectedIDs: Set<String>? = nil) -> CleanList {
        let selected = selectedIDs ?? Set(candidates.map(\.id))
        let grouped = Dictionary(grouping: candidates.filter { selected.contains($0.id) }, by: \.category)
        let categories = grouped.keys.sorted().map { category in
            CleanList.Category(name: category, items: grouped[category, default: []].map {
                CleanList.Item(path: $0.path, sizeBytes: $0.sizeBytes,
                               sizeText: $0.sizeText, itemCount: $0.itemCount)
            })
        }
        return CleanList(categories: categories, summaryTotalText: nil,
                         summaryItemCount: categories.flatMap(\.items).count)
    }

    private static func candidateID(planID: UUID, path: String, token: String) -> String {
        let digest = SHA256.hash(data: Data("\(planID.uuidString)\u{1f}\(path)\u{1f}\(token)".utf8))
        return "cand-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

final class StagedCleanupPlanStore: @unchecked Sendable {
    static let shared = StagedCleanupPlanStore(directory: defaultDirectory())

    let directory: URL
    private let lock = NSLock()

    init(directory: URL) { self.directory = directory }

    func save(_ plan: StagedCleanupPlan) throws {
        lock.lock(); defer { lock.unlock() }
        try saveUnlocked(plan)
    }

    func load(id: UUID) -> StagedCleanupPlan? {
        lock.lock(); defer { lock.unlock() }
        return loadUnlocked(id: id)
    }

    /// Atomically reserve one staged plan.  A second Agent call receives the
    /// same run id instead of executing the file set twice.
    func claim(id: UUID, revision: Int, runID: UUID) throws -> StagedCleanupPlan {
        lock.lock(); defer { lock.unlock() }
        guard var plan = loadUnlocked(id: id), plan.revision == revision else {
            throw MCPToolError.badArguments("Unknown cleanup plan or revision.")
        }
        guard plan.executionState == .staged else {
            throw MCPToolError.badArguments(
                "Cleanup plan already \(plan.executionState.rawValue)"
                    + (plan.executionRunID.map { " as run \($0.uuidString.lowercased())" } ?? "") + ".")
        }
        plan.executionState = .executing
        plan.executionRunID = runID
        try saveUnlocked(plan)
        return plan
    }

    func complete(id: UUID, runID: UUID) {
        lock.lock(); defer { lock.unlock() }
        guard var plan = loadUnlocked(id: id), plan.executionRunID == runID else { return }
        plan.executionState = .completed
        try? saveUnlocked(plan)
    }

    private func saveUnlocked(_ plan: StagedCleanupPlan) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plan).write(to: fileURL(id: plan.id), options: [.atomic])
    }

    private func loadUnlocked(id: UUID) -> StagedCleanupPlan? {
        guard let data = try? Data(contentsOf: fileURL(id: id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let value = try? decoder.decode(StagedCleanupPlan.self, from: data) { return value }
        let legacy = JSONDecoder()
        legacy.dateDecodingStrategy = .iso8601
        return try? legacy.decode(StagedCleanupPlan.self, from: data)
    }

    private func fileURL(id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
    }

    private static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Burrow/CleanupPlans", isDirectory: true)
    }
}
