//
//  CleanImpactRanker.swift
//  Burrow
//
//  Orders clean review items by deletion impact (PRD §Clean): safest /
//  most-regenerable first, user-visible state last. Pure — keyed off the
//  category name the engine reports. Lower rank = safer = shown first.
//

import Foundation

enum CleanImpactRanker {
    /// 0 = pure regenerable cache … 4 = credentials / user state.
    static func rank(category: String) -> Int {
        let c = category.lowercased()
        if c.contains("credential") || c.contains("keychain") || c.contains("login") { return 4 }
        if c.contains("document") || c.contains("state") || c.contains("essential") { return 3 }
        if c.contains("log") || c.contains("leftover") || c.contains("trash") { return 2 }
        if c.contains("download") || c.contains("derived") || c.contains("build") || c.contains("artifact") { return 1 }
        if c.contains("cache") || c.contains("browser") { return 0 }
        return 3   // unknown is not a synonym for regenerable cache
    }

    /// Stable ascending-impact sort, preserving input order within a rank.
    static func sorted<T>(_ items: [(category: String, value: T)]) -> [T] {
        items.enumerated()
            .sorted { (rank(category: $0.element.category), $0.offset) < (rank(category: $1.element.category), $1.offset) }
            .map { $0.element.value }
    }
}
