//
//  ActivityView.swift
//  Burrow
//
//  The Activity pane — Mole's cleanup history (`mo history --json`): past
//  clean / optimize / uninstall / purge sessions, what they removed and
//  what they skipped or failed. Distinct from the metrics "History" pane.
//

import SwiftUI

struct ActivityView: View {
    @StateObject private var model: ActivityModel
    @State private var selectedRun: CleanupRunRecord?

    init(feeds: FeedHub) {
        _model = StateObject(wrappedValue: ActivityModel(feeds: feeds))
    }

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 12)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The whole load/refresh lifecycle is one task-scoped feed
        // subscription (issue #53): the `history.sessions` pump ticks only
        // while this pane is on screen, and leaving it cancels the task,
        // which detaches the pump. No view-owned timer, no off-screen poll.
        .task { await model.subscribe() }
        .sheet(item: $selectedRun) { CleanupRunDetail(run: $0) }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Activity").font(Brand.serif(20, .medium)).foregroundStyle(Brand.textPrimary)
                Text("Recent Mole cleanup sessions").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            }
            Spacer()
            Button { model.reload() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.loading, model.runs.isEmpty, model.sessions.isEmpty {
            VStack { Spacer(); ProgressView("Reading history…").controlSize(.large)
                .font(Brand.mono(11)); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.sessions.isEmpty, model.runs.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "clock.badge.questionmark").font(.system(size: 26)).foregroundStyle(Brand.textTertiary)
                Text("No cleanup history yet").font(Brand.mono(12)).foregroundStyle(Brand.textSecondary)
                Text("Run a Clean or Optimize and it'll show up here.").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.runs) { run in
                        Button { selectedRun = run } label: {
                            CleanupRunRow(run: run)
                        }
                        .buttonStyle(.plain)
                    }
                    if !model.runs.isEmpty, !model.sessions.isEmpty {
                        HStack {
                            Text("Legacy engine history")
                                .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                            Rectangle().fill(Brand.hairline).frame(height: 1)
                        }
                        .padding(.vertical, 4)
                    }
                    ForEach(model.sessions) { SessionRow(session: $0) }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct CleanupRunRow: View {
    let run: CleanupRunRecord

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: run.mode == .trash ? "trash.circle.fill" : "sparkles")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                    Text(title).font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                    statusChip
                    Spacer()
                    Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Brand.textTertiary)
                }
                HStack(spacing: 12) {
                    Text(run.initiatedBy).font(Brand.mono(9)).foregroundStyle(Brand.textSecondary)
                    Text("\(run.items.filter(\.selected).count) items")
                        .font(Brand.mono(9)).foregroundStyle(Brand.textSecondary)
                    Text(Fmt.bytes(run.selectedBytes))
                        .font(Brand.mono(10, .semibold)).foregroundStyle(Brand.textPrimary)
                    Spacer()
                    if let summary = run.summary {
                        Text(summary).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary).lineLimit(1)
                    }
                }
            }
        }
    }

    private var title: String {
        run.mode == .trash ? NSLocalizedString("Cleanup to Trash", comment: "")
            : NSLocalizedString("Cleanup", comment: "")
    }
    private var accent: Color { run.status == .failed ? Brand.red : Tool.clean.accent }
    private var statusChip: some View {
        Text(run.status.rawValue.replacingOccurrences(of: "_", with: " "))
            .font(Brand.mono(8, .semibold)).foregroundStyle(accent)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(accent.opacity(0.12)))
    }
}

private struct CleanupRunDetail: View {
    let run: CleanupRunRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Cleanup receipt").font(Brand.serif(22, .medium))
                    Text(run.id.uuidString.lowercased())
                        .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                }
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
            }
            .padding(20)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 18) {
                        detailStat("Initiated by", run.initiatedBy)
                        detailStat("Mode", run.mode.rawValue)
                        detailStat("Status", run.status.rawValue)
                        detailStat("Selected", Fmt.bytes(run.selectedBytes))
                        Spacer()
                    }
                    ForEach(run.items.filter(\.selected).sorted { $0.sizeBytes > $1.sizeBytes }) { item in
                        GlassCard {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(item.displayName).font(Brand.sans(12, .semibold)).lineLimit(1)
                                    Spacer()
                                    Text(Fmt.bytes(item.sizeBytes)).font(Brand.mono(10, .semibold))
                                    Text(item.outcome.rawValue).font(Brand.mono(9))
                                        .foregroundStyle(item.outcome == .failed ? Brand.red : Brand.textSecondary)
                                }
                                Text(item.path).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                                    .textSelection(.enabled)
                                if let policy = item.policy {
                                    Text(policy.reason).font(Brand.sans(10)).foregroundStyle(Brand.textSecondary)
                                }
                                if let detail = item.detail {
                                    Text(detail).font(Brand.sans(10)).foregroundStyle(Brand.orange)
                                }
                                if let destination = item.trashDestination {
                                    Text("Trash: \(destination)").font(Brand.mono(9))
                                        .foregroundStyle(Brand.textTertiary).textSelection(.enabled)
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
    }

    private func detailStat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(Brand.mono(8)).foregroundStyle(Brand.textTertiary)
            Text(value).font(Brand.sans(11, .semibold)).foregroundStyle(Brand.textPrimary)
        }
    }
}

private struct SessionRow: View {
    let session: HistorySession

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: glyph).font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
                    Text(session.command.capitalized).font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                    if !session.isComplete {
                        Text("incomplete").font(Brand.mono(9)).foregroundStyle(Brand.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Brand.orange.opacity(0.15)))
                    }
                    Spacer()
                    Text(session.startedAt).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                }
                HStack(spacing: 14) {
                    stat("\(session.items)", "items")
                    if !session.size.isEmpty, session.size != "0B" { stat(session.size, "freed") }
                    if session.removed > 0 { stat("\(session.removed)", "removed", Brand.green) }
                    if session.skipped > 0 { stat("\(session.skipped)", "skipped", Brand.textSecondary) }
                    if session.failed > 0 { stat("\(session.failed)", "failed", Brand.red) }
                    Spacer()
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ color: Color = Brand.textPrimary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(Brand.mono(12, .semibold)).foregroundStyle(color)
            Text(label).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
        }
    }

    private var glyph: String {
        switch session.command {
        case "clean":     return "sparkles"
        case "optimize":  return "wand.and.stars"
        case "uninstall": return "trash"
        case "purge":     return "folder.badge.minus"
        case "installer": return "arrow.down.app"
        default:          return "clock.arrow.circlepath"
        }
    }
    private var accent: Color {
        switch session.command {
        case "clean":     return Tool.clean.accent
        case "optimize":  return Tool.optimize.accent
        case "uninstall": return Tool.apps.accent
        default:          return Brand.textSecondary
        }
    }
}

@MainActor
final class ActivityModel: ObservableObject {
    @Published var runs: [CleanupRunRecord] = []
    @Published var sessions: [HistorySession] = []
    @Published var loading = false

    private let feeds: FeedHub
    /// The subscribed sessions feed — held so the toolbar's manual refresh
    /// can poke it; lifecycle belongs to the view's `.task` below.
    private var feed: Feed<[HistorySession]>?

    init(feeds: FeedHub) {
        self.feeds = feeds
    }

    /// Park on the shared `history.sessions` pump (1 h cadence — the
    /// cleanup log doesn't move minute to minute) and apply every value
    /// until the surrounding task is cancelled.
    func subscribe() async {
        runs = await Task.detached(priority: .utility) {
            CleanupLedger.shared.recent(limit: 50)
        }.value
        let feed = feeds.feed("history.sessions", cadence: 3600) {
            await Task.detached(priority: .userInitiated) {
                MoleClient.history()
            }.value
        }
        self.feed = feed
        loading = sessions.isEmpty
        for await parsed in feed.subscribeValues() {
            sessions = parsed
            runs = await Task.detached(priority: .utility) {
                CleanupLedger.shared.recent(limit: 50)
            }.value
            loading = false
        }
    }

    /// The toolbar refresh button: poke the shared pump for an immediate
    /// re-read (coalesced with any in-flight fetch).
    func reload() {
        loading = true
        feed?.refresh()
        Task {
            runs = await Task.detached(priority: .utility) {
                CleanupLedger.shared.recent(limit: 50)
            }.value
            loading = false
        }
    }
}
