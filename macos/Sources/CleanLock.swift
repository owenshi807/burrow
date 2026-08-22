//
//  CleanLock.swift
//  Burrow
//
//  Maps clean-preview cache paths to running apps so the review screen
//  can badge them "App open", keep them unticked, and tell the user the
//  upside of quitting ("Close Helium … to clean another N GB"). The
//  classifier is pure; the AppKit edge (the live app list) is one call.
//

import Foundation
import AppKit

enum CleanLock {
    struct RunningApp: Sendable {
        let bundleID: String
        let name: String
    }

    /// The live list, regular apps only — menu-bar agents and daemons
    /// aren't something the user can reasonably "close".
    static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let name = app.localizedName else { return nil }
                return RunningApp(bundleID: app.bundleIdentifier ?? "", name: name)
            }
    }

    /// Whether `path` belongs to one of `running`'s caches: a path
    /// component equal to the app's bundle id (Containers/, Caches/) or
    /// exactly the app's name (Application Support/<Name>/…).
    static func lockReason(for path: String,
                           running: [RunningApp]) -> CleanSelection.LockReason? {
        let components = (path as NSString).pathComponents.filter { $0 != "/" }
        let normalized = components.map(normalize)
        var identityKeys = Set(normalized.filter { !$0.isEmpty })
        // Some products split a display name into vendor/product directories,
        // e.g. `Application Support/Google/Chrome` for “Google Chrome”.
        // Compare short adjacent windows as well as literal components.
        for start in normalized.indices {
            for length in 2...3 where start + length <= normalized.count {
                identityKeys.insert(normalized[start..<(start + length)].joined())
            }
        }
        for app in running {
            let bundleKey = normalize(app.bundleID)
            if !bundleKey.isEmpty, identityKeys.contains(bundleKey) {
                return .appOpen(appName: app.name)
            }
            let nameKey = normalize(app.name)
            if !nameKey.isEmpty, identityKeys.contains(nameKey) {
                return .appOpen(appName: app.name)
            }
        }
        return nil
    }

    private static func normalize(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }

    /// The full map for a parsed preview.
    static func lockedPaths(in list: CleanList,
                            running: [RunningApp]) -> [String: CleanSelection.LockReason] {
        var out: [String: CleanSelection.LockReason] = [:]
        for item in list.categories.flatMap(\.items) {
            if let reason = lockReason(for: item.path, running: running) {
                out[item.path] = reason
            }
        }
        return out
    }
}
