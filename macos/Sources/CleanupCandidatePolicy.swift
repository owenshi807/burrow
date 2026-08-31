//
//  CleanupCandidatePolicy.swift
//  Burrow
//
//  Deterministic, model-free meaning for one scanner candidate.  The scanner
//  finds paths; this layer says what Burrow itself knows about the cost and
//  safety of removing them.  Unknown never means safe.
//

import Foundation

enum CleanupPolicyDisposition: String, Codable, Sendable {
    case recommendCleanup = "recommend_cleanup"
    case review
    case protect
}

enum CleanupRecoverability: String, Codable, Sendable {
    case regenerable
    case redownloadable
    case trashOnly = "trash_only"
    case unknown
    case irreplaceable
}

enum CleanupRegenerationCost: String, Codable, Sendable {
    case low
    case medium
    case high
    case unknown
}

struct CleanupCandidateMeaning: Codable, Equatable, Sendable {
    let disposition: CleanupPolicyDisposition
    let reason: String
    let ownerHint: String?
    let recoverability: CleanupRecoverability
    let regenerationCost: CleanupRegenerationCost
    let sensitive: Bool
    let evidence: [String]
}

enum CleanupCandidatePolicy {
    /// Model/cache trees can be very large and are technically re-downloadable,
    /// but Burrow cannot prove which installed product consumes them from a
    /// path alone.  They are investigation targets, never default cleanup.
    private static let modelNeedles = [
        "/.cache/huggingface", "/models--", "/models/", "/model/",
        "/whisper", "/ollama", "/lm studio", "/mlx",
    ]

    /// User-created, conversational, credential, and workspace state stays
    /// protected even when a scanner accidentally labels its parent a cache.
    private static let protectedNeedles = [
        "/messages/", "/mail/", "/notes/",
        "/.ssh", "/.gnupg", "keychain", "credential", "password", "secret",
        "/.codex/sessions", "/.claude/projects", "/chat", "/conversation",
    ]

    static func classify(item: CleanList.Item,
                         category: String,
                         lock: CleanSelection.LockReason?) -> CleanupCandidateMeaning {
        let path = item.path.lowercased()
        let categoryText = category.lowercased()
        let leaf = (item.path as NSString).lastPathComponent.lowercased()

        if let lock {
            return .init(
                disposition: .protect,
                reason: lockReason(lock),
                ownerHint: ownerHint(for: item.path),
                recoverability: .unknown,
                regenerationCost: .unknown,
                sensitive: SensitiveRemnantMatcher.isSensitive(item.path),
                evidence: ["Burrow safety lock"])
        }

        let isUserCollectionRoot = ["documents", "desktop", "workspace", "source", "src"]
            .contains(leaf)
        if protectedNeedles.contains(where: path.contains)
            || isUserCollectionRoot
            || categoryText.contains("essential")
            || categoryText.contains("document")
            || categoryText.contains("state") {
            return .init(
                disposition: .protect,
                reason: "This path can contain user-created, conversational, credential, or workspace state.",
                ownerHint: ownerHint(for: item.path),
                recoverability: .irreplaceable,
                regenerationCost: .high,
                sensitive: true,
                evidence: ["Protected path or scanner category"])
        }

        if modelNeedles.contains(where: path.contains) {
            return .init(
                disposition: .review,
                reason: "Local model data may still be consumed by an installed product; ownership must be established before cleanup.",
                ownerHint: ownerHint(for: item.path),
                recoverability: .redownloadable,
                regenerationCost: .high,
                sensitive: false,
                evidence: ["Local model path"])
        }

        let isPythonCache = leaf == "__pycache__" || path.hasSuffix("/.pytest_cache")
        let isPackageCache = path.contains("/.bun/install/cache")
            || path.contains("/.npm/_cacache")
            || path.contains("/.cargo/registry/cache")
            || path.contains("/.gem/") && leaf == "cache"
        let isBuildArtifact = categoryText.contains("derived")
            || categoryText.contains("build")
            || categoryText.contains("artifact")
            || leaf == "deriveddata"
        let isExplicitCache = leaf == "cache" || leaf == "code cache"
            || leaf == "gpu cache" || leaf == "cache.storage"
            || path.contains("/library/caches/")
            || categoryText.contains("cache")
        let isLog = leaf == "logs" || leaf.hasSuffix(".log") || categoryText.contains("log")

        if isPythonCache || isLog {
            return .init(
                disposition: .recommendCleanup,
                reason: "Generated diagnostic or interpreter cache data; applications recreate it when needed.",
                ownerHint: ownerHint(for: item.path),
                recoverability: .regenerable,
                regenerationCost: .low,
                sensitive: false,
                evidence: ["Generated cache/log shape"])
        }

        if isPackageCache || isBuildArtifact || isExplicitCache {
            let expensive = isPackageCache || item.sizeBytes >= 1_024 * 1_024 * 1_024
            return .init(
                disposition: .recommendCleanup,
                reason: expensive
                    ? "Regenerable cache data, but rebuilding or downloading it again may take time."
                    : "Regenerable cache or build data with no user-authored source files in the candidate itself.",
                ownerHint: ownerHint(for: item.path),
                recoverability: isPackageCache ? .redownloadable : .regenerable,
                regenerationCost: expensive ? .high : .medium,
                sensitive: false,
                evidence: [isPackageCache ? "Package cache shape" : "Cache/build shape"])
        }

        return .init(
            disposition: .review,
            reason: "Burrow recognizes the scanner candidate but cannot prove its owner, consumer, or recovery path deterministically.",
            ownerHint: ownerHint(for: item.path),
            recoverability: .unknown,
            regenerationCost: .unknown,
            sensitive: SensitiveRemnantMatcher.isSensitive(item.path),
            evidence: ["Scanner candidate; semantic ownership unresolved"])
    }

    private static func lockReason(_ lock: CleanSelection.LockReason) -> String {
        switch lock {
        case .appOpen(let app): return "\(app) is running and may be using this path."
        case .systemBusy: return "A system service is currently using this path."
        case .notCleanable(let reason): return reason
        }
    }

    private static func ownerHint(for path: String) -> String? {
        let components = (path as NSString).pathComponents
        for anchor in ["Caches", "Application Support", "Containers", "Group Containers"] {
            if let index = components.firstIndex(of: anchor), components.indices.contains(index + 1) {
                return components[index + 1]
            }
        }
        if path.contains("/.bun/") { return "Bun" }
        if path.contains("/.npm/") { return "npm" }
        if path.contains("/.cargo/") { return "Cargo" }
        if path.contains("/.gem/") { return "RubyGems" }
        if path.contains("/.cache/huggingface") { return "Hugging Face consumer unresolved" }
        return nil
    }
}
