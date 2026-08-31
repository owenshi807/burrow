//
//  CleanupLedger.swift
//  Burrow
//
//  Durable receipt for every Burrow-owned cleanup.  The UI can stay a simple
//  list + detail sheet; the record underneath preserves the complete chain:
//  scanner meaning, selection, revalidation, action, outcome, and recovery.
//

import Foundation

struct CleanupRunRecord: Codable, Equatable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable { case manual, agent, scheduled, legacyEngine = "legacy_engine" }
    enum Mode: String, Codable, Sendable { case trash, permanent, engineManaged = "engine_managed" }
    enum Status: String, Codable, Sendable { case running, completed, partial, failed, stopped }

    struct Item: Codable, Equatable, Identifiable, Sendable {
        enum Action: String, Codable, Sendable { case trash, remove, none }
        enum Outcome: String, Codable, Sendable { case pending, removed, trashed, skipped, failed }

        let id: String
        let path: String
        let displayName: String
        let category: String
        let sizeBytes: Int64
        let policy: CleanupCandidateMeaning?
        let selected: Bool
        var action: Action
        var outcome: Outcome
        var detail: String?
        var trashDestination: String?
    }

    let id: UUID
    let planID: String?
    let planRevision: Int?
    let source: Source
    let mode: Mode
    let initiatedBy: String
    let scannerVersion: String
    let appVersion: String
    let startedAt: Date
    var endedAt: Date?
    var status: Status
    let selectedBytes: Int64
    var reclaimedBytes: Int64
    var items: [Item]
    var summary: String?
}

struct CleanupLedger: Sendable {
    static let shared = CleanupLedger(directory: defaultDirectory())
    static let maximumRuns = 500

    let directory: URL

    init(directory: URL) { self.directory = directory }

    func record(_ run: CleanupRunRecord) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        // Preserve sub-second scan/validation cutoffs. ISO-8601's default
        // formatter truncates them, which can make an unchanged item look as
        // though it was modified after the review when the plan is reloaded.
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(run)
        try data.write(to: fileURL(for: run.id), options: [.atomic])
        try pruneIfNeeded()
    }

    func run(id: UUID) -> CleanupRunRecord? {
        decode(fileURL(for: id))
    }

    func recent(limit: Int = 50) -> [CleanupRunRecord] {
        let capped = min(max(limit, 1), Self.maximumRuns)
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return urls.filter { $0.pathExtension == "json" }
            .compactMap(decode)
            .sorted { $0.startedAt > $1.startedAt }
            .prefix(capped).map { $0 }
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
    }

    private func decode(_ url: URL) -> CleanupRunRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        if let value = try? decoder.decode(CleanupRunRecord.self, from: data) { return value }
        // Development builds before the runtime contract used ISO-8601.
        let legacy = JSONDecoder()
        legacy.dateDecodingStrategy = .iso8601
        return try? legacy.decode(CleanupRunRecord.self, from: data)
    }

    private func pruneIfNeeded() throws {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]).filter { $0.pathExtension == "json" }
        guard urls.count > Self.maximumRuns else { return }
        let sorted = urls.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return lhs > rhs
        }
        for url in sorted.dropFirst(Self.maximumRuns) { try? FileManager.default.removeItem(at: url) }
    }

    private static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("Burrow/CleanupRuns", isDirectory: true)
    }
}

extension CleanupRunRecord {
    static func reviewed(
        id: UUID = UUID(), planID: String? = nil, revision: Int? = nil, source: Source,
        mode: Mode, initiatedBy: String, items: [Item], startedAt: Date = Date()
    ) -> CleanupRunRecord {
        CleanupRunRecord(
            id: id, planID: planID, planRevision: revision,
            source: source, mode: mode, initiatedBy: initiatedBy,
            scannerVersion: "burrow-clean-list-v1",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
            startedAt: startedAt, endedAt: nil, status: .running,
            selectedBytes: items.filter(\.selected).reduce(0) { $0 + $1.sizeBytes },
            reclaimedBytes: 0, items: items, summary: nil)
    }
}
