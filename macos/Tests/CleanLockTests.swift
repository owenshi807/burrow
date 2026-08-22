//
//  CleanLockTests.swift
//  BurrowTests
//
//  Locked-item detection for the Clean review: a cache path that belongs
//  to a RUNNING app gets the "App open" badge, starts unticked, and
//  feeds the "Close X, Y to clean another N GB" header. The classifier
//  is pure — the view feeds it the live NSRunningApplication list.
//

import XCTest
@testable import Burrow

final class CleanLockTests: XCTestCase {
    let running: [CleanLock.RunningApp] = [
        .init(bundleID: "net.imput.helium", name: "Helium"),
        .init(bundleID: "com.anthropic.claudefordesktop", name: "Claude"),
    ]

    func testContainerPath_matchesByBundleID() {
        let reason = CleanLock.lockReason(
            for: "/Users/x/Library/Containers/net.imput.helium/Data/Library/Caches/x",
            running: running)
        XCTAssertEqual(reason, .appOpen(appName: "Helium"))
    }

    func testCachesPath_matchesByBundleID() {
        let reason = CleanLock.lockReason(
            for: "/Users/x/Library/Caches/com.anthropic.claudefordesktop",
            running: running)
        XCTAssertEqual(reason, .appOpen(appName: "Claude"))
    }

    func testApplicationSupportPath_matchesByAppName() {
        let reason = CleanLock.lockReason(
            for: "/Users/x/Library/Application Support/Claude/Cache",
            running: running)
        XCTAssertEqual(reason, .appOpen(appName: "Claude"))
    }

    func testSplitBrowserVendorAndProductMatchesDisplayName() {
        let reason = CleanLock.lockReason(
            for: "/Users/x/Library/Application Support/Google/Chrome/Default/CRX-cache",
            running: [.init(bundleID: "com.google.Chrome", name: "Google Chrome")])
        XCTAssertEqual(reason, .appOpen(appName: "Google Chrome"))
    }

    func testUnrelatedPath_isNotLocked() {
        XCTAssertNil(CleanLock.lockReason(for: "/Users/x/.npm/_cacache", running: running))
        XCTAssertNil(CleanLock.lockReason(for: "/Users/x/Library/Caches/com.apple.helpd", running: running))
    }

    /// Substring accidents must not lock: "Helium 2" the folder is not
    /// "Helium" the app unless the path component matches exactly.
    func testNameMatch_isExactComponentNotSubstring() {
        XCTAssertNil(CleanLock.lockReason(
            for: "/Users/x/Library/Application Support/HeliumExtra/Cache",
            running: running))
    }
}
