//
//  CleanupAuthorization.swift
//  Burrow
//
//  The dry-run file is untrusted input.  A review is backed by one immutable
//  snapshot of canonical allow roots and lstat identities. The snapshot does
//  not become unsafe merely because the user spent time reviewing it: every
//  selected entry is revalidated when the user clicks Clean and again at the
//  privileged execution boundary. Changed entries are removed from the plan.
//  The confirmation renders that snapshot and execution consumes a sealed subset
//  of the same value; it never re-reads clean-list.txt for authority.
//

import Foundation
import CryptoKit
import Darwin

/// Detect any descendant created or mutated after a cleanup review without
/// storing a million-path manifest. APFS ctime is kernel-maintained and cannot
/// be preserved/backdated by an ordinary copy, so additions, replacements,
/// content writes, renames, and metadata edits all make the root ineligible.
enum CleanupScopeValidator {
    static func isUnchanged(root: String, expectedDevice: UInt64, since: Date) -> Bool {
        var pending = [root]
        var visited = 0
        let fileManager = FileManager.default

        while let path = pending.popLast() {
            visited += 1
            // A corrupt or unexpectedly enormous candidate should be split by
            // the scanner, not make the final confirmation appear hung.
            guard visited <= 1_000_000 else { return false }
            var info = stat()
            guard lstat(path, &info) == 0,
                  UInt64(info.st_dev) == expectedDevice else { return false }
            let changedAt = Date(timeIntervalSince1970:
                TimeInterval(info.st_ctimespec.tv_sec)
                + TimeInterval(info.st_ctimespec.tv_nsec) / 1_000_000_000)
            guard changedAt <= since else { return false }

            guard (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            guard let names = try? fileManager.contentsOfDirectory(atPath: path) else {
                return false
            }
            for name in names {
                pending.append((path as NSString).appendingPathComponent(name))
            }
        }
        return true
    }
}

enum CleanupRuntimeTranscript {
    static let cleanedPrefix = HelperRuntimeTranscript.cleanedPrefix
    static let skippedPrefix = HelperRuntimeTranscript.skippedPrefix
    static let cleaningPrefix = HelperRuntimeTranscript.cleaningPrefix

    static func paths(in lines: [String], prefix: String) -> Set<String> {
        Set(lines.compactMap { line in
            guard line.hasPrefix(prefix) else { return nil }
            let path = String(line.dropFirst(prefix.count))
            return path.isEmpty ? nil : path
        })
    }
}

/// Values that can associate a reviewed cache path with a live macOS app at
/// the privileged boundary.  `lsappinfo` reports both bundle identifiers and
/// display names; deriving the same identifiers from the path lets the root
/// shell repeat the "app open" guard after the password sheet has closed.
enum CleanupActiveAppBoundary {
    static func identityHints(for path: String) -> [String] {
        let components = (path as NSString).pathComponents.filter {
            $0 != "/" && !$0.isEmpty
        }
        let anchors: Set<String> = ["Caches", "Application Support", "Containers", "Group Containers"]
        var hints = Set<String>()
        for (index, component) in components.enumerated() {
            if anchors.contains(component), components.indices.contains(index + 1) {
                let tail = Array(components.dropFirst(index + 1).prefix(3))
                // Browser support trees often split the app name across
                // directories (`Google/Chrome`, `Microsoft/Edge`). Include
                // cumulative display-name forms, not only the first token.
                for length in 1...tail.count {
                    hints.insert(tail.prefix(length).joined(separator: " "))
                }
                let generic = Set(["cache", "caches", "data", "default", "profile", "profiles"])
                for value in tail where !generic.contains(value.lowercased()) {
                    hints.insert(value)
                }
            }
            if component.contains("."), !component.hasPrefix(".") {
                hints.insert(component)
                let parts = component.split(separator: ".").map(String.init)
                if parts.count >= 2 {
                    hints.insert(parts.suffix(2).joined(separator: " "))
                }
            }
        }
        return hints.filter { !$0.isEmpty }.sorted()
    }

    static func shellCheck(for path: String) -> String {
        let checks = identityHints(for: path).flatMap { hint in
            ["bundleID=\"\(hint)\"", "\"\(hint)\" ASN:"].map { marker in
                "/usr/bin/printf '%s\\n' \"$running_apps\" | /usr/bin/grep -F -q -- \(MoleCLI.shellQuote(marker))"
            }
        }
        return checks.isEmpty ? "/usr/bin/false" : "(" + checks.joined(separator: " || ") + ")"
    }
}

struct CleanupExecutionPlan: Sendable, Equatable {
    struct Item: Sendable, Equatable {
        /// The reviewed entry itself — the unit the preview actually showed
        /// the user, with its size and item count. Execution deletes the tree
        /// rooted at THIS pinned inode; it does not enumerate and pin every
        /// descendant, because the review never presented them individually.
        let identity: PinnedFileIdentity
        /// Descendants are not individually authorized, but any descendant
        /// created or mutated after the review changes its ctime. Before each
        /// irreversible boundary Burrow walks this root and drops it if that
        /// happened, so a long-lived review cannot absorb new content.
        let unchangedSince: Date

        func matchesCurrentScope() -> Bool {
            identity.matchesCurrent()
                && CleanupScopeValidator.isUnchanged(
                    root: identity.path,
                    expectedDevice: identity.device,
                    since: unchangedSince)
        }
    }

    let snapshotID: UUID
    let createdAt: Date
    /// Last exact in-process scope validation. The root shell uses this as a
    /// second boundary against changes while authentication is visible.
    let validatedAt: Date
    let approvedRoots: [PinnedFileIdentity]
    let items: [Item]
    private let seal: Data

    fileprivate init(snapshotID: UUID, createdAt: Date, validatedAt: Date,
                     approvedRoots: [PinnedFileIdentity], items: [Item]) {
        self.snapshotID = snapshotID
        self.createdAt = createdAt
        self.validatedAt = validatedAt
        self.approvedRoots = approvedRoots
        self.items = items
        self.seal = Self.makeSeal(snapshotID: snapshotID, createdAt: createdAt,
                                  validatedAt: validatedAt,
                                  roots: approvedRoots, items: items)
    }

    func validateForLaunch(now _: Date = Date()) -> Bool {
        validateEnvelopeForLaunch() && items.allSatisfy { $0.matchesCurrentScope() }
    }

    /// Validate plan-level authority without turning one volatile item into a
    /// batch-level failure. Seal, roots, and containment are global;
    /// item identity is deliberately checked by the caller per item.
    func validateEnvelopeForLaunch(now _: Date = Date()) -> Bool {
        guard !items.isEmpty,
              seal == Self.makeSeal(snapshotID: snapshotID, createdAt: createdAt,
                                    validatedAt: validatedAt,
                                    roots: approvedRoots, items: items),
              approvedRoots.allSatisfy({ $0.matchesCurrent() }) else { return false }
        let rootPrefixes: [(device: UInt64, path: String, prefix: String)] = approvedRoots.map {
            ($0.device, $0.path, $0.path.hasSuffix("/") ? $0.path : $0.path + "/")
        }
        return items.allSatisfy { item in
            let path = item.identity.path
            let device = item.identity.device
            return rootPrefixes.contains { root in
                device == root.device && path != root.path && path.hasPrefix(root.prefix)
            }
        }
    }

    struct Revalidation: Sendable, Equatable {
        let plan: CleanupExecutionPlan
        let skippedPaths: [String]
    }

    /// Drop only entries whose pinned identity changed. A fresh sealed plan is
    /// produced for the stable subset; global trust failures still fail closed.
    func revalidatedForLaunch(
        now: Date = Date(),
        runningApps: [CleanLock.RunningApp] = []
    ) -> Revalidation? {
        guard validateEnvelopeForLaunch() else { return nil }
        var stable: [Item] = []
        var skipped: [String] = []
        for item in items {
            if item.matchesCurrentScope(),
               CleanLock.lockReason(for: item.identity.path, running: runningApps) == nil {
                stable.append(item)
            }
            else { skipped.append(item.identity.path) }
        }
        guard !stable.isEmpty else { return nil }
        let plan = CleanupExecutionPlan(snapshotID: snapshotID, createdAt: createdAt,
                                        validatedAt: now,
                                        approvedRoots: approvedRoots,
                                        items: stable)
        guard plan.validateForLaunch() else { return nil }
        return Revalidation(plan: plan, skippedPaths: skipped)
    }

    /// Checks serialized into the administrator shell. They are intentionally
    /// repeated after the password dialog because that dialog is an unbounded
    /// attacker-controlled delay.
    func executionBoundaryChecks() -> [String] {
        approvedRoots.map { identity in
            let path = MoleCLI.shellQuote(identity.path)
            let token = MoleCLI.shellQuote(identity.shellStatToken)
            return "[ \"$(/usr/bin/stat -f '%d:%i:%u:%p' -- \(path) 2>/dev/null)\" = \(token) ]"
        }
    }

    /// The reviewed paths, deepest-first.
    ///
    /// Not cosmetic. The engine's export list routinely contains a parent and
    /// its own children as separate entries — `~/Library/Caches` alongside
    /// `~/Library/Caches/GeoServices` — because the writer collapses some
    /// categories to a parent while others name leaves. Deleting the parent
    /// first makes every nested entry vanish before its turn, and `find` then
    /// exits nonzero with "No such file or directory" for work that actually
    /// succeeded. Deepest-first removes the children before the parent, so
    /// each entry still exists when it is reached.
    ///
    /// Both elevation routes MUST use this order; the helper path skipping it
    /// is exactly how a fully successful clean reported "exit 1".
    func orderedReviewedPaths() -> [String] {
        func depth(_ path: String) -> Int { path.filter { $0 == "/" }.count }
        return items.map(\.identity.path).sorted { lhs, rhs in
            let l = depth(lhs), r = depth(rhs)
            return l == r ? lhs < rhs : l > r
        }
    }

    /// The shell-quoted form of `orderedReviewedPaths()`, for the delete loop.
    func quotedReviewedPaths() -> [String] {
        orderedReviewedPaths().map { MoleCLI.shellQuote($0) }
    }

    /// The complete irreversible cleanup: boundary checks, then the deletes.
    ///
    /// This lives beside the plan that authorizes it rather than inside the
    /// AppleScript builder, so a test can execute exactly the semantics that
    /// ship instead of reconstructing them from a quoted wrapper.
    ///
    /// `find -delete` is doing real safety work here, not just recursion.
    /// BSD `find` chdir's as it descends, so every unlink is relative to the
    /// directory it is standing in rather than a re-resolved path, and it
    /// refuses to delete any name whose path relative to "." contains a "/" —
    /// which is precisely the mid-walk directory-swap case.  Following
    /// symlinks is incompatible with `-delete`, so it cannot be redirected out
    /// of the tree, and `-x` holds it to the volume the boundary check pinned.
    ///
    /// A failing entry does not abandon the rest: the loop records it and the
    /// aggregate status reports it once.  `find` names each failing path on
    /// stderr, which the caller redirects into the run log, so the transcript
    /// says which entries survived.
    ///
    /// Success is decided by the POSTCONDITION, never by find's exit status.
    /// BSD `-delete` is documented to "always return true", so `find` exits 0
    /// having printed `unlink(...): Permission denied` and deleted nothing —
    /// trusting its status is how a cleanup that removed nothing reports
    /// "Done — caches cleared". Asking whether the entry is actually gone also
    /// covers the cases find never reports at all.
    func irreversibleCleanupShell() -> String {
        let checks = executionBoundaryChecks().map {
            $0 + " || exit \(ElevatedExitCode.boundaryCheckFailed)"
        }
        let ordered = items.sorted {
            let lhs = $0.identity.path.filter { $0 == "/" }.count
            let rhs = $1.identity.path.filter { $0 == "/" }.count
            return lhs == rhs ? $0.identity.path < $1.identity.path : lhs > rhs
        }
        // `stat`'s F format preserves the timespec fraction; unlike
        // `find -newerct`, this has no one-second blind window and does not
        // falsely reject an unchanged tree reviewed in the current second.
        let boundaryTime = String(
            format: "%.9f", locale: Locale(identifier: "en_US_POSIX"),
            validatedAt.timeIntervalSince1970)
        let itemSteps = ordered.map { item -> String in
            let identity = item.identity
            let path = MoleCLI.shellQuote(identity.path)
            let token = MoleCLI.shellQuote(identity.shellStatToken)
            let current = "$(/usr/bin/stat -f '%d:%i:%u:%p' -- \(path) 2>/dev/null)"
            let scopeTimes = "scope_times=$(/usr/bin/find -x \"$p\" -exec /usr/bin/stat -f '%.9Fc' -- {} + 2>/dev/null)"
            let scopeChanged = "/usr/bin/printf '%s\\n' \"$scope_times\" | /usr/bin/awk -v cutoff=\"$scope_cutoff\" '{ if (($1 + 0) > (cutoff + 0)) changed=1 } END { exit(changed ? 0 : 1) }'"
            let lsof = identity.isDirectory
                ? "/usr/sbin/lsof -n -P +D \"$p\" >/dev/null 2>&1"
                : "/usr/sbin/lsof -n -P -- \"$p\" >/dev/null 2>&1"
            let activeApp = CleanupActiveAppBoundary.shellCheck(for: identity.path)
            return "p=\(path); if [ \"\(current)\" = \(token) ] "
                + "&& \(scopeTimes) && [ -n \"$scope_times\" ] && ! (\(scopeChanged)) "
                + "&& ! \(lsof) && ! \(activeApp); then "
                + "attempted=$((attempted + 1)); p=\(path); "
                + "/usr/bin/printf '%s\\t%s\\n' 'BURROW_CLEANING' \"$p\"; "
                + "/usr/bin/find -x \"$p\" -depth -delete; "
                + "if [ -e \"$p\" ] || [ -L \"$p\" ]; then failed=1; "
                + "else /usr/bin/printf '%s\\t%s\\n' 'BURROW_CLEANED' \"$p\"; fi; "
                + "else skipped=$((skipped + 1)); "
                + "/usr/bin/printf '%s\\t%s\\n' 'BURROW_SKIPPED_CHANGED' \"$p\"; fi"
        }
        let loop = (["running_apps=$(/usr/bin/lsappinfo list 2>/dev/null)",
                     "[ -n \"$running_apps\" ] || exit \(ElevatedExitCode.boundaryCheckFailed)",
                     "scope_cutoff=\(MoleCLI.shellQuote(boundaryTime))",
                     "failed=0", "attempted=0", "skipped=0"] + itemSteps + [
            "[ \"$attempted\" -gt 0 ] || exit \(ElevatedExitCode.boundaryCheckFailed)",
            "[ \"$failed\" -eq 0 ]",
        ]).joined(separator: "; ")
        return (checks + [loop]).joined(separator: "; ")
    }

    private static func makeSeal(snapshotID: UUID, createdAt: Date, validatedAt: Date,
                                 roots: [PinnedFileIdentity], items: [Item]) -> Data {
        func line(_ i: PinnedFileIdentity) -> String {
            "\(i.path.utf8.count):\(i.path)|\(i.shellStatToken)"
        }
        let payload = ([snapshotID.uuidString,
                        String(createdAt.timeIntervalSince1970.bitPattern),
                        String(validatedAt.timeIntervalSince1970.bitPattern)]
            + roots.map { "root:\(line($0))" } + ["--items--"]
            + items.map {
                "item:\(line($0.identity))|\($0.unchangedSince.timeIntervalSince1970.bitPattern)"
            })
            .joined(separator: "\n")
        return Data(SHA256.hash(data: Data(payload.utf8)))
    }
}

struct CleanupSnapshot: Sendable, Equatable {
    struct PlanPreparation: Sendable, Equatable {
        let plan: CleanupExecutionPlan
        let skippedChangedPaths: [String]
    }

    enum SnapshotError: LocalizedError, Equatable {
        case noApprovedRoots
        case malformedPath(String)
        case symbolicLink(String)
        case outsideApprovedRoots(String)
        case unexpectedVolume(String)
        case missingPath(String)
        case selectionMismatch
        case staleOrChanged
        case overlappingCandidate(String)

        var errorDescription: String? {
            switch self {
            case .noApprovedRoots: return "No canonical cleanup roots are available."
            case .malformedPath(let p): return "The cleanup preview contained a malformed path: \(p)"
            case .symbolicLink(let p): return "The cleanup preview contained a symbolic link: \(p)"
            case .outsideApprovedRoots(let p):
                // Naming the offending path first: the old wording read as
                // though the listed path were the approved root, which sent
                // the reader looking in exactly the wrong place.
                return "\(p) is outside the folders Burrow is allowed to clean."
            case .unexpectedVolume(let p): return "The cleanup preview crossed onto an unexpected volume: \(p)"
            case .missingPath(let p): return "A reviewed cleanup item no longer exists: \(p)"
            case .selectionMismatch: return "The cleanup selection no longer matches the reviewed preview."
            case .staleOrChanged: return "Every selected cleanup item changed or is no longer available."
            case .overlappingCandidate(let p):
                return "\(p) contains cleanup candidates that are reviewed separately. Select those child items instead."
            }
        }
    }

    let id: UUID
    let createdAt: Date
    let list: CleanList
    let approvedRoots: [PinnedFileIdentity]
    let items: [CleanupExecutionPlan.Item]
    /// Preview entries this snapshot refused, and why.
    ///
    /// These exist because the engine's export list collapses siblings to
    /// their common PARENT: a category that removes two or more loose files
    /// sitting directly inside an approved root records the root itself. The
    /// `.DS_Store` sweep does exactly that — `find "$HOME" -name .DS_Store`
    /// over a home folder with more than one match collapses to `$HOME` — so
    /// accepting the entry would mean deleting the user's home directory.
    ///
    /// Refusing it is right. Refusing the WHOLE preview because of it was not:
    /// one 471 KB entry blocked 1.79 GB of legitimate cleanup, and the Clean
    /// button vanished with no way to proceed. Entries are independent, so a
    /// refusal is now per-entry and reported rather than fatal.
    let skipped: [SkippedEntry]

    struct SkippedEntry: Equatable, Sendable {
        let path: String
        let reason: String
    }

    static func capture(list: CleanList,
                        approvedRootURLs: [URL],
                        now: Date = Date()) throws -> Self {
        let roots = try approvedRootURLs.compactMap { raw -> PinnedFileIdentity? in
            guard let canonical = InvokingUserIdentity.canonicalPath(raw.path) else { return nil }
            let identity = try PinnedFileIdentity.capture(canonical)
            guard identity.isDirectory else { return nil }
            return identity
        }
        guard !roots.isEmpty else { throw SnapshotError.noApprovedRoots }

        var seen = Set<String>()
        var captured: [CleanupExecutionPlan.Item] = []
        var skipped: [SkippedEntry] = []
        let rawPaths = list.categories.flatMap(\.items).map(\.path)
        let overlappingParents = Set(rawPaths.filter { path in
            let prefix = path.hasSuffix("/") ? path : path + "/"
            return rawPaths.contains { $0 != path && $0.hasPrefix(prefix) }
        })

        // Every refusal below is per-entry. Skipping can only ever REMOVE
        // something from the delete set, so failing this way is strictly safer
        // than the previous behaviour, which was to abandon the whole plan.
        func refuse(_ path: String, _ error: SnapshotError) {
            skipped.append(SkippedEntry(path: path,
                                        reason: error.errorDescription ?? "Refused."))
        }

        for item in list.categories.flatMap(\.items) {
            let raw = item.path
            // Structural corruption is still FATAL. A relative path, a NUL, a
            // newline or a JSON fragment is not something the engine's export
            // writer can produce, so the list isn't the list — and a preview
            // that isn't trustworthy shouldn't be partially executed. Every
            // check below this one is about an entry being unrepresentable,
            // which is an ordinary fact about a well-formed list.
            guard !raw.isEmpty, raw.hasPrefix("/"),
                  !raw.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  !raw.hasPrefix("{"), !raw.hasPrefix("[") else {
                throw SnapshotError.malformedPath(raw)
            }
            var lst = stat()
            guard lstat(raw, &lst) == 0 else { refuse(raw, .missingPath(raw)); continue }
            guard (lst.st_mode & S_IFMT) != S_IFLNK else {
                refuse(raw, .symbolicLink(raw)); continue
            }
            guard let canonical = InvokingUserIdentity.canonicalPath(raw), canonical == raw else {
                refuse(raw, .symbolicLink(raw)); continue
            }
            if overlappingParents.contains(raw) {
                refuse(raw, .overlappingCandidate(raw)); continue
            }
            guard seen.insert(canonical).inserted else { continue }
            guard let identity = try? PinnedFileIdentity.capture(canonical) else {
                refuse(canonical, .missingPath(canonical)); continue
            }
            do {
                _ = try approvedRoot(for: canonical, device: identity.device, roots: roots)
            } catch let error as SnapshotError {
                refuse(canonical, error); continue
            }
            captured.append(.init(identity: identity, unchangedSince: now))
        }
        // Only a preview with NOTHING usable is fatal. Anything else stays
        // cleanable, minus the entries named in `skipped`.
        guard !captured.isEmpty else { throw SnapshotError.selectionMismatch }
        return Self(id: UUID(), createdAt: now,
                    list: list, approvedRoots: roots, items: captured, skipped: skipped)
    }

    static func approvedRoot(for path: String, device: UInt64,
                             roots: [PinnedFileIdentity]) throws -> PinnedFileIdentity {
        guard let root = roots.first(where: {
            path != $0.path && path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/")
        }) else { throw SnapshotError.outsideApprovedRoots(path) }
        guard device == root.device else { throw SnapshotError.unexpectedVolume(path) }
        return root
    }

    private func unvalidatedPlan(selectedPaths: [String], now _: Date) throws -> CleanupExecutionPlan {
        let selected = Set(selectedPaths)
        let byPath = Dictionary(uniqueKeysWithValues: items.map { ($0.identity.path, $0) })
        guard !selected.isEmpty, selected.count == selectedPaths.count,
              selected.allSatisfy({ byPath[$0] != nil }) else {
            throw SnapshotError.selectionMismatch
        }
        let ordered = items.filter { selected.contains($0.identity.path) }
        return CleanupExecutionPlan(snapshotID: id, createdAt: createdAt,
                                    validatedAt: createdAt,
                                    approvedRoots: approvedRoots, items: ordered)
    }

    func preparePlan(selectedPaths: [String], now: Date = Date()) throws -> PlanPreparation {
        let result = try unvalidatedPlan(selectedPaths: selectedPaths, now: now)
        guard let revalidated = result.revalidatedForLaunch(now: now) else {
            throw SnapshotError.staleOrChanged
        }
        return PlanPreparation(plan: revalidated.plan,
                               skippedChangedPaths: revalidated.skippedPaths)
    }

    func plan(selectedPaths: [String], now: Date = Date()) throws -> CleanupExecutionPlan {
        let result = try unvalidatedPlan(selectedPaths: selectedPaths, now: now)
        guard result.validateForLaunch(now: now) else { throw SnapshotError.staleOrChanged }
        return result
    }

    static func approvedRoots(for user: InvokingUserIdentity) -> [URL] {
        [URL(fileURLWithPath: user.canonicalHome, isDirectory: true),
         URL(fileURLWithPath: "/Library/Caches", isDirectory: true),
         URL(fileURLWithPath: "/Library/Logs", isDirectory: true),
         URL(fileURLWithPath: "/private/var/folders", isDirectory: true)]
    }
}

enum CleanupExecutor {
    struct Outcome: Sendable, Equatable {
        enum Status: Sendable, Equatable { case trashed, skipped, failed }
        let path: String
        let status: Status
        let destination: String?
        let detail: String?
    }

    struct Result: Sendable, Equatable {
        let moved: Int
        let skipped: Int
        let failed: Int
        let outcomes: [Outcome]

        init(moved: Int, skipped: Int, failed: Int, outcomes: [Outcome] = []) {
            self.moved = moved
            self.skipped = skipped
            self.failed = failed
            self.outcomes = outcomes
        }
    }

    static func moveToTrash(_ plan: CleanupExecutionPlan,
                            move: (URL) throws -> URL = systemTrashMove) -> Result {
        guard plan.validateEnvelopeForLaunch() else {
            return Result(
                moved: 0, skipped: 0, failed: plan.items.count,
                outcomes: plan.items.map {
                    Outcome(path: $0.identity.path, status: .failed, destination: nil,
                            detail: "The cleanup plan failed its launch validation.")
                })
        }
        var moved = 0, skipped = 0, failed = 0
        var outcomes: [Outcome] = []
        for item in plan.items {
            guard item.identity.matchesCurrent() else {
                skipped += 1
                outcomes.append(.init(path: item.identity.path, status: .skipped,
                                      destination: nil, detail: "The item changed after review."))
                continue
            }
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC |
                (item.identity.isDirectory ? O_DIRECTORY : 0)
            let descriptor = Darwin.open(item.identity.path, flags)
            guard descriptor >= 0 else {
                skipped += 1
                outcomes.append(.init(path: item.identity.path, status: .skipped,
                                      destination: nil, detail: "The item could not be opened safely."))
                continue
            }
            defer { Darwin.close(descriptor) }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0,
                  UInt64(opened.st_dev) == item.identity.device,
                  UInt64(opened.st_ino) == item.identity.inode,
                  UInt32(opened.st_uid) == item.identity.owner,
                  UInt16(opened.st_mode) == item.identity.mode else {
                skipped += 1
                outcomes.append(.init(path: item.identity.path, status: .skipped,
                                      destination: nil, detail: "The opened item no longer matched the reviewed identity."))
                continue
            }
            do {
                let source = URL(fileURLWithPath: item.identity.path)
                let destination = try move(source)
                guard let captured = try? PinnedFileIdentity.capture(destination.path),
                      captured.device == item.identity.device,
                      captured.inode == item.identity.inode,
                      captured.owner == item.identity.owner,
                      captured.mode == item.identity.mode else {
                    // FileManager's Trash operation is an atomic rename on the
                    // source volume, but its API is path-based. If another
                    // process swapped the name between our check and that
                    // rename, the returned destination contains the wrong
                    // vnode. Put that recoverable object back when possible;
                    // if its name was occupied again, leave it in Trash.
                    restoreUnreviewedItem(at: destination, to: source)
                    skipped += 1
                    outcomes.append(.init(path: item.identity.path, status: .skipped,
                                          destination: nil, detail: "A path race was detected; the unreviewed object was restored."))
                    continue
                }
                moved += 1
                outcomes.append(.init(path: item.identity.path, status: .trashed,
                                      destination: destination.path, detail: nil))
            } catch {
                failed += 1
                outcomes.append(.init(path: item.identity.path, status: .failed,
                                      destination: nil, detail: error.localizedDescription))
            }
        }
        return Result(moved: moved, skipped: skipped, failed: failed, outcomes: outcomes)
    }

    private static func systemTrashMove(_ source: URL) throws -> URL {
        var destination: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
        guard let destination else { throw CocoaError(.fileWriteUnknown) }
        return destination as URL
    }

    private static func restoreUnreviewedItem(at captured: URL, to original: URL) {
        var current = stat()
        guard lstat(original.path, &current) != 0, errno == ENOENT else { return }
        // moveItem refuses an occupied destination, so a second race can only
        // make restoration fail closed and leave the object recoverable.
        try? FileManager.default.moveItem(at: captured, to: original)
    }
}
