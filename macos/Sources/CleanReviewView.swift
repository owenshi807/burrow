//
//  CleanReviewView.swift
//  Burrow
//
//  One shared cleanup page. Scanner facts, Agent judgments, user overrides,
//  and the final staged selection are projections of CleanupPlanStore — there
//  is no separate "AI tab" and no second set of checkboxes to reconcile.
//

import SwiftUI
import AppKit

struct CleanReviewView: View {
    @ObservedObject var planStore: CleanupPlanStore
    var accent: Color = Tool.clean.accent
    var onEnableAgent: () -> Void
    var onRetryAgent: () -> Void
    var onConfirm: (CleanSelection) -> Void
    var onExit: () -> Void

    @State private var expanded: Set<String> = []
    @State private var evidenceExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 22).padding(.top, 6).padding(.bottom, 12)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    planColumn
                    // The default window leaves about 850 pt after the rail.
                    // At the old 920 pt breakpoint the evidence inspector was
                    // absent in the normal window, so selecting a row appeared
                    // to do nothing. 760 pt still leaves a usable plan column
                    // beside the inspector.
                    if proxy.size.width >= 760 {
                        Rectangle().fill(Brand.hairline).frame(width: 1)
                        inspector.frame(width: min(360, max(300, proxy.size.width * 0.29)))
                    }
                }
            }
        }
        .overlay(alignment: .bottom) { footer }
        .onExitCommand { onExit() }
        .onChange(of: planStore.selectedCandidateId) { _, _ in evidenceExpanded = false }
    }

    private var planColumn: some View {
        ScrollView {
            // Keep this eager. Updating one candidate while a section was
            // expanded could leave SwiftUI's LazyVStack placement graph in a
            // 100% CPU relayout loop on macOS 26. A cleanup review is bounded
            // to a small scanner result, so eager layout is cheap and stable.
            VStack(spacing: 12) {
                agentDisclosure
                ForEach(CleanupRecommendationDisposition.allCases, id: \.rawValue) { disposition in
                    let sections = planStore.sections.filter { $0.disposition == disposition }
                    if !sections.isEmpty {
                        decisionHeader(disposition, sections: sections)
                        ForEach(sections) { section in sectionCard(section) }
                    }
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 14)
            .padding(.bottom, 70)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Header and Agent state

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Ready to clean")
                        .font(Brand.serif(22, .medium)).foregroundStyle(Brand.textPrimary)
                    agentStatusChip
                }
                if let lockedSummary = planStore.selection?.lockedSummary {
                    Text(String(format: NSLocalizedString("Close %@ to clean another %@ · %d items", comment: "locked apps header"),
                                lockedSummary.appNames.joined(separator: ", "),
                                Fmt.bytes(lockedSummary.bytes), lockedSummary.itemCount))
                        .font(Brand.sans(11)).foregroundStyle(Brand.amber)
                } else {
                    Text("Agent judgments and scanner facts share one staged plan. Your edits always win.")
                        .font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
                }
            }
            Spacer()
            iconButton("chevron.left", help: NSLocalizedString("Back to results", comment: ""), action: onExit)
            iconButton("checkmark.circle", help: NSLocalizedString("Select all", comment: "")) { planStore.selectAll() }
            iconButton("xmark.circle", help: NSLocalizedString("Deselect all", comment: "")) { planStore.deselectAll() }
        }
    }

    @ViewBuilder
    private var agentStatusChip: some View {
        switch planStore.agentState {
        case .analyzing(let agent):
            Label(String(format: NSLocalizedString("%@ analyzing", comment: ""), agent), systemImage: "sparkles")
                .agentChip(color: accent)
        case .ready(let agent, _):
            Label(String(format: NSLocalizedString("Reviewed by %@", comment: ""), agent), systemImage: "sparkles")
                .agentChip(color: accent)
        case .degraded(let agent, _):
            Label(String(format: NSLocalizedString("%@ unavailable", comment: ""), agent), systemImage: "exclamationmark.triangle")
                .agentChip(color: Brand.amber)
        case .consentRequired:
            Label(NSLocalizedString("Agent off", comment: ""), systemImage: "sparkles")
                .agentChip(color: Brand.textTertiary)
        case .unavailable, .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var agentDisclosure: some View {
        switch planStore.agentState {
        case .analyzing(let agent):
            if let progress = planStore.agentProgress {
                agentRunningDisclosure(agent: agent, progress: progress)
            }
        case .consentRequired:
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 15)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Let your Codex analyze this scan")
                        .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                    Text("Candidate paths, sizes, and scanner categories go to your configured Codex model. Codex runs with read-only filesystem access but can inspect files your account can read. It receives no cleanup or authorization capability.")
                        .font(Brand.sans(10)).foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(NSLocalizedString("Analyze with Codex", comment: ""), action: onEnableAgent)
                    .buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
            }
            .padding(13).background(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.25)))
        case .degraded(_, let reason):
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Brand.amber)
                Text(reason).font(Brand.sans(10)).foregroundStyle(Brand.textSecondary).lineLimit(3)
                Spacer()
                Button(NSLocalizedString("Retry Agent", comment: ""), action: onRetryAgent)
                    .buttonStyle(.plain).font(Brand.sans(11, .semibold)).foregroundStyle(Brand.amber)
            }
            .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Brand.amber.opacity(0.08)))
        case .ready(_, let summary):
            agentCompletedDisclosure(summary: summary)
        default:
            EmptyView()
        }
    }

    private func agentRunningDisclosure(agent: String, progress: CleanupAgentProgress) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 11) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(accent)
                        .frame(width: 30, height: 30)
                        .background(RoundedRectangle(cornerRadius: 9).fill(accent.opacity(0.13)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activeAgentTitle(agent: agent, progress: progress))
                            .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                            .contentTransition(.numericText(value: Double(progress.reviewedCount ?? 0)))
                            .animation(reduceMotion ? nil : Brand.Motion.state,
                                       value: progress.reviewedCount)
                        Text(activeAgentDetail(progress.phase))
                            .font(Brand.sans(10)).foregroundStyle(Brand.textSecondary)
                            .id(progress.phase)
                            .transition(.opacity)
                            .animation(reduceMotion ? nil : Brand.Motion.state,
                                       value: progress.phase)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(elapsedText(progress.elapsed(at: context.date)))
                            .font(Brand.mono(11, .medium)).foregroundStyle(accent)
                        Text(agentDurationGuidance(progress.elapsed(at: context.date)))
                            .font(Brand.sans(9)).foregroundStyle(Brand.textTertiary)
                    }
                }

                HStack(spacing: 7) {
                    agentPhase("Candidates prepared", symbol: "checkmark.circle.fill", state: .done)
                    agentPhaseConnector(done: true)
                    agentPhase("Triage & deep review", symbol: "point.3.connected.trianglepath.dotted",
                               state: progress.phase == .investigating ? .active : .done)
                    agentPhaseConnector(done: progress.phase != .investigating)
                    agentPhase("Plan validation", symbol: "shield.checkered",
                               state: progress.phase == .validating ? .active : .pending)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(agentProgressAccessibility(progress))
            }
            .padding(13)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(accent.opacity(0.075)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(accent.opacity(0.24)))
        }
    }

    private func activeAgentTitle(agent: String, progress: CleanupAgentProgress) -> String {
        if let reviewed = progress.reviewedCount,
           progress.phase == .investigating,
           reviewed < progress.candidateCount {
            return String(
                format: NSLocalizedString("%@ has analyzed %d of %d candidates", comment: "cleanup Agent active progress title"),
                agent, reviewed, progress.candidateCount)
        }
        if progress.phase == .validating {
            return String(
                format: NSLocalizedString("%@ is validating %d judgments", comment: "cleanup Agent validation title"),
                agent, progress.candidateCount)
        }
        return String(
            format: NSLocalizedString("%@ is analyzing %d candidates", comment: "cleanup Agent active title"),
            agent, progress.candidateCount)
    }

    private func agentCompletedDisclosure(summary _: String) -> some View {
        let reviewed = planStore.agentProgress?.reviewedCount ?? planStore.totalCount
        let duration = planStore.agentProgress.map { elapsedText($0.elapsed()) }
        return HStack(alignment: .top, spacing: 11) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(String(
                    format: NSLocalizedString("Codex completed %d judgments", comment: "cleanup Agent completed title"),
                    reviewed))
                    .font(Brand.sans(12, .semibold)).foregroundStyle(Brand.textPrimary)
                if let duration {
                    Text(String(
                        format: NSLocalizedString("Finished in %@. Candidate mapping and path policy checks passed.", comment: "cleanup Agent completion metadata"),
                        duration))
                        .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                }
                Text(planStore.overallRecommendationText)
                    .font(Brand.sans(10)).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(accent.opacity(0.06)))
    }

    private enum AgentPhaseVisualState: Equatable { case done, active, pending }

    private func agentPhase(_ title: String, symbol: String,
                            state: AgentPhaseVisualState) -> some View {
        let color: Color = state == .pending ? Brand.textTertiary : accent
        return HStack(spacing: 5) {
            Group {
                if state == .active {
                    if reduceMotion {
                        Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                    } else {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.mini)
                            .scaleEffect(0.65)
                    }
                } else {
                    Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                }
            }
            .frame(width: 11, height: 11)
            Text(NSLocalizedString(title, comment: "cleanup Agent progress phase"))
                .font(Brand.sans(9, state == .active ? .semibold : .regular))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(state == .active ? accent.opacity(0.10) : Color.clear))
        .overlay(Capsule().strokeBorder(
            state == .active ? accent.opacity(0.24) : Color.clear,
            lineWidth: 1))
        .animation(reduceMotion ? nil : Brand.Motion.state, value: state)
    }

    private func agentPhaseConnector(done: Bool) -> some View {
        Rectangle().fill(done ? accent.opacity(0.65) : Brand.hairline)
            .frame(maxWidth: 22).frame(height: 1)
            .animation(reduceMotion ? nil : Brand.Motion.state, value: done)
    }

    private func activeAgentDetail(_ phase: CleanupAgentProgress.Phase) -> String {
        switch phase {
        case .investigating:
            return NSLocalizedString(
                "Checking app ownership, version relationships, active references, and rebuildability.",
                comment: "cleanup Agent investigation detail")
        case .validating:
            return NSLocalizedString(
                "Cross-checking the merged plan, then applying Burrow's deterministic safety rules.",
                comment: "cleanup Agent validation detail")
        case .completed:
            return NSLocalizedString("Analysis complete.", comment: "cleanup Agent completed detail")
        }
    }

    private func agentProgressAccessibility(_ progress: CleanupAgentProgress) -> String {
        let phase: String
        switch progress.phase {
        case .investigating: phase = NSLocalizedString("Triage and deep review in progress", comment: "")
        case .validating: phase = NSLocalizedString("Safety check in progress", comment: "")
        case .completed: phase = NSLocalizedString("Analysis complete", comment: "")
        }
        if let reviewed = progress.reviewedCount, progress.phase == .investigating {
            return String(
                format: NSLocalizedString("%@, %d of %d candidates reviewed, %@ elapsed", comment: "cleanup Agent progress accessibility with count"),
                phase, reviewed, progress.candidateCount, elapsedText(progress.elapsed()))
        }
        return String(
            format: NSLocalizedString("%@, %@ elapsed", comment: "cleanup Agent progress accessibility"),
            phase, elapsedText(progress.elapsed()))
    }

    private func elapsedText(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private func agentDurationGuidance(_ elapsed: TimeInterval) -> String {
        if elapsed >= 300 {
            return NSLocalizedString(
                "Still working — time varies with scan scope",
                comment: "cleanup Agent long-running duration guidance")
        }
        return NSLocalizedString(
            "Deep review may take several minutes",
            comment: "cleanup Agent duration guidance")
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Brand.textSecondary)
                .frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help).accessibilityLabel(help)
    }

    // MARK: - Decision groups and category cards

    private func decisionHeader(_ disposition: CleanupRecommendationDisposition,
                                sections: [CleanupDecisionSection]) -> some View {
        let candidates = sections.flatMap(\.candidates)
        let bytes = candidates.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(disposition.title).font(Brand.sans(14, .semibold)).foregroundStyle(Brand.textPrimary)
            Text("\(candidates.count)").font(Brand.mono(10, .medium)).foregroundStyle(disposition.color)
                .contentTransition(.numericText(value: Double(candidates.count)))
                .animation(reduceMotion ? nil : Brand.Motion.state, value: candidates.count)
            Spacer()
            Text(Fmt.bytes(bytes))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .contentTransition(.numericText(value: Double(bytes)))
                .animation(reduceMotion ? nil : Brand.Motion.state, value: bytes)
        }.padding(.top, 3)
    }

    private func sectionCard(_ section: CleanupDecisionSection) -> some View {
        let key = section.id
        let isOpen = expanded.contains(key)
        let state = planStore.categoryState(for: section.candidates)
        let selectedBytes = planStore.selectedBytes(in: section.candidates)
        let totalBytes = section.candidates.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return VStack(spacing: 0) {
            HStack(spacing: 11) {
                triStateBox(state) {
                    planStore.toggleCategory(section.category, disposition: section.disposition)
                }
                Button {
                    // Section identity and order stay fixed. Expanding is a
                    // direct disclosure, not a transition for every card.
                    if isOpen { expanded.remove(key) } else { expanded.insert(key) }
                } label: {
                    HStack(spacing: 11) {
                    Image(systemName: Self.glyph(for: section.category))
                        .font(.system(size: 13)).foregroundStyle(accent).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(NSLocalizedString(section.category, comment: "clean category"))
                                .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                            Text(String(
                                format: NSLocalizedString("%d/%d selected", comment: "category selection count"),
                                planStore.selectedCount(in: section.candidates),
                                section.candidates.count
                            ))
                                .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                                .contentTransition(.numericText(value: Double(
                                    planStore.selectedCount(in: section.candidates))))
                                .animation(reduceMotion ? nil : Brand.Motion.state,
                                           value: planStore.selectedCount(in: section.candidates))
                        }
                        Text(Self.consequence(for: section.category))
                            .font(Brand.sans(10)).foregroundStyle(Brand.textSecondary)
                    }
                    Spacer()
                    Text("\(Fmt.bytes(selectedBytes)) / \(Fmt.bytes(totalBytes))")
                        .font(Brand.mono(11, .medium)).foregroundStyle(Brand.blue)
                        .contentTransition(.numericText(value: Double(selectedBytes)))
                        .animation(reduceMotion ? nil : Brand.Motion.state, value: selectedBytes)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(Brand.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .animation(reduceMotion ? nil : Brand.Motion.disclosure, value: isOpen)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(13)

            if isOpen {
                Rectangle().fill(Brand.hairline).frame(height: 1).padding(.horizontal, 13)
                VStack(spacing: 0) {
                    ForEach(section.candidates) { candidate in candidateRow(candidate) }
                }.padding(.vertical, 4)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.cardFill))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private func triStateBox(_ state: CleanSelection.CategoryState,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(state == .none ? Color.white.opacity(0.07) : accent.opacity(0.9))
                    .frame(width: 17, height: 17)
                if state == .all {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                } else if state == .mixed {
                    Image(systemName: "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(.black)
                }
            }.overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Brand.hairline))
        }.buttonStyle(.plain)
    }

    // MARK: - Candidate row and inspector

    private func candidateRow(_ candidate: CleanupPlanCandidate) -> some View {
        let recommendation = planStore.recommendation(for: candidate.id)
        let selected = planStore.isSelected(candidate)
        let active = planStore.selectedCandidateId == candidate.id
        return HStack(spacing: 10) {
            Button { planStore.toggleCandidate(candidate.id) } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(selected ? accent.opacity(0.9) : Color.white.opacity(0.07))
                        .frame(width: 15, height: 15)
                    if selected { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.black) }
                }.overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Brand.hairline))
            }.buttonStyle(.plain).disabled(candidate.locked)

            // Selecting a leaf opens the evidence inspector; it does not
            // disclose another list level, so this row intentionally has no
            // chevron. Only sectionCard owns an actual disclosure control.
            Button { planStore.selectCandidate(candidate.id) } label: {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(candidate.displayName).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                        Text(candidate.abbreviatedPath).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    judgmentBadge(recommendation, candidate: candidate)
                    Text(candidate.sizeText).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                        .frame(minWidth: 56, alignment: .trailing)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(active ? accent.opacity(0.06) : Color.clear)
        .contextMenu {
            Button(NSLocalizedString("Reveal in Finder", comment: "")) { AnalyzeIcons.reveal(candidate.path) }
            Button(NSLocalizedString("Always skip this", comment: "")) {
                try? MoleWhitelist.live.add(candidate.path)
                if planStore.isSelected(candidate) { planStore.toggleCandidate(candidate.id) }
            }
        }
    }

    @ViewBuilder
    private func judgmentBadge(_ recommendation: CleanupCandidateRecommendation,
                               candidate: CleanupPlanCandidate) -> some View {
        if candidate.locked {
            Chip(text: NSLocalizedString("Protected", comment: ""), color: Brand.amber)
        } else if planStore.userOverrides.contains(candidate.id) {
            Chip(text: NSLocalizedString("Your choice", comment: ""), color: Brand.amber)
        } else if candidate.origin == .agentDiscovered {
            Chip(text: NSLocalizedString("Agent discovered", comment: ""), color: Brand.blue)
        } else if recommendation.origin == .burrowSafety {
            Chip(text: NSLocalizedString("Conservative keep", comment: ""), color: Brand.amber)
        } else if recommendation.origin == .agent {
            Chip(text: recommendation.disposition.shortTitle, color: recommendation.disposition.color)
        } else {
            Chip(text: NSLocalizedString("Scanner", comment: ""), color: Brand.blue)
        }
    }

    private var inspector: some View {
        Group {
            if let candidate = planStore.selectedCandidate {
                let recommendation = planStore.recommendation(for: candidate.id)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(candidate.displayName).font(Brand.serif(20, .medium)).foregroundStyle(Brand.textPrimary)
                            Text(candidate.abbreviatedPath).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                                .textSelection(.enabled)
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Label(recommendation.disposition.title, systemImage: recommendation.disposition.symbol)
                                    .font(Brand.sans(13, .semibold)).foregroundStyle(recommendation.disposition.color)
                                Spacer()
                                if let confidence = recommendation.confidence {
                                    Text("\(Int(confidence * 100))%")
                                        .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                                }
                            }
                            Text(recommendation.reason).font(Brand.sans(11)).foregroundStyle(Brand.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            if planStore.userOverrides.contains(candidate.id) {
                                Text(planStore.isSelected(candidate)
                                     ? NSLocalizedString("You chose to include this candidate in the current plan.", comment: "")
                                     : NSLocalizedString("You chose to keep this candidate in the current plan.", comment: ""))
                                    .font(Brand.sans(10, .semibold)).foregroundStyle(Brand.amber)
                            }
                        }
                        .padding(13)
                        .background(RoundedRectangle(cornerRadius: 13).fill(recommendation.disposition.color.opacity(0.08)))

                        VStack(alignment: .leading, spacing: 5) {
                            Text("Consequence").font(Brand.sans(11, .semibold)).foregroundStyle(Brand.textSecondary)
                            Text(recommendation.consequence).font(Brand.sans(11)).foregroundStyle(Brand.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("\(Fmt.bytes(candidate.sizeBytes)) · \(candidate.category)")
                                .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                        }

                        if !recommendation.evidence.isEmpty {
                            DisclosureGroup(isExpanded: $evidenceExpanded) {
                                VStack(alignment: .leading, spacing: 9) {
                                    ForEach(recommendation.evidence) { evidence in
                                        VStack(alignment: .leading, spacing: 2) {
                                            HStack(spacing: 6) {
                                                Text(evidence.basis.title)
                                                    .font(Brand.mono(8, .semibold))
                                                    .foregroundStyle(evidence.basis.color)
                                                    .padding(.horizontal, 5).padding(.vertical, 2)
                                                    .background(Capsule().fill(evidence.basis.color.opacity(0.12)))
                                                Text(evidence.label)
                                                    .font(Brand.sans(10, .semibold))
                                                    .foregroundStyle(Brand.textPrimary)
                                            }
                                            Text(evidence.detail).font(Brand.sans(10)).foregroundStyle(Brand.textSecondary)
                                                .fixedSize(horizontal: false, vertical: true)
                                        }
                                    }
                                    if let investigation = recommendation.investigation {
                                        Rectangle().fill(Brand.hairline).frame(height: 1)
                                        ForEach(Array(investigationMetadataRows(investigation).enumerated()),
                                                id: \.offset) { _, row in
                                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                Text(row.0).font(Brand.sans(10, .semibold))
                                                    .foregroundStyle(Brand.textPrimary)
                                                Spacer(minLength: 8)
                                                Text(row.1).font(Brand.mono(8, .semibold))
                                                    .foregroundStyle(Brand.textSecondary)
                                                    .padding(.horizontal, 6).padding(.vertical, 3)
                                                    .background(Capsule().fill(Brand.textSecondary.opacity(0.10)))
                                            }
                                        }
                                        ForEach(Array(investigationRows(investigation).enumerated()), id: \.offset) { _, row in
                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack(spacing: 6) {
                                                    Text(row.1.state.title)
                                                        .font(Brand.mono(8, .semibold))
                                                        .foregroundStyle(row.1.state.color)
                                                        .padding(.horizontal, 5).padding(.vertical, 2)
                                                        .background(Capsule().fill(row.1.state.color.opacity(0.12)))
                                                    Text(row.0).font(Brand.sans(10, .semibold))
                                                        .foregroundStyle(Brand.textPrimary)
                                                }
                                                Text(row.1.detail).font(Brand.sans(10))
                                                    .foregroundStyle(Brand.textSecondary)
                                                    .fixedSize(horizontal: false, vertical: true)
                                            }
                                        }
                                    }
                                }.padding(.top, 9)
                            } label: {
                                Text(String(format: NSLocalizedString("Evidence and checks · %d", comment: ""),
                                            recommendation.evidence.count + (recommendation.investigation == nil ? 0 : 9)))
                                    .font(Brand.sans(11, .semibold)).foregroundStyle(Brand.textSecondary)
                            }.tint(accent)
                        }

                        HStack(spacing: 12) {
                            Button(NSLocalizedString("Reveal in Finder", comment: "")) { AnalyzeIcons.reveal(candidate.path) }
                            Button(NSLocalizedString("Ask Codex to reassess", comment: ""), action: onRetryAgent)
                        }
                        .buttonStyle(.plain).font(Brand.sans(10, .semibold)).foregroundStyle(accent)
                    }
                    .padding(18).padding(.bottom, 70)
                }.scrollIndicators(.hidden)
            } else {
                overallInspector
            }
        }.background(Brand.nearBlack.opacity(0.35))
    }

    private var overallInspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 17) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(overallInspectorTitle)
                        .font(Brand.serif(20, .medium)).foregroundStyle(Brand.textPrimary)
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        Text(snapshotAgeText(at: context.date))
                            .font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    Label("Plan-wide judgment", systemImage: "sparkles")
                        .font(Brand.sans(13, .semibold)).foregroundStyle(accent)
                    Text(planStore.overallRecommendationText)
                        .font(Brand.sans(11)).foregroundStyle(Brand.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(13)
                .background(RoundedRectangle(cornerRadius: 13).fill(accent.opacity(0.08)))

                VStack(spacing: 10) {
                    overviewMetric(.delete)
                    overviewMetric(.humanIntentRequired)
                    overviewMetric(.keep)
                }

                if !planStore.userOverrides.isEmpty {
                    Text(String(
                        format: NSLocalizedString("Your %d manual changes are already applied to the staged plan; Codex's original judgment remains visible on each item.", comment: "cleanup overview manual changes"),
                        planStore.userOverrides.count))
                        .font(Brand.sans(10, .semibold)).foregroundStyle(Brand.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("Select any item to inspect its reason and evidence. You can include a suggested keep or exclude a suggested cleanup; your choice wins.")
                    .font(Brand.sans(10)).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(NSLocalizedString("Ask Codex to reassess the full scan", comment: ""), action: onRetryAgent)
                    .buttonStyle(.plain).font(Brand.sans(10, .semibold)).foregroundStyle(accent)
            }
            .padding(18).padding(.bottom, 70)
        }
        .scrollIndicators(.hidden)
    }

    private func overviewMetric(_ disposition: CleanupRecommendationDisposition) -> some View {
        HStack(spacing: 10) {
            Image(systemName: disposition.symbol)
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(disposition.color)
                .frame(width: 20, height: 20)
                .background(Circle().fill(disposition.color.opacity(0.1)))
            Text(disposition.title).font(Brand.sans(11, .semibold)).foregroundStyle(Brand.textPrimary)
            Spacer()
            Text("\(planStore.recommendationCount(for: disposition)) · \(Fmt.bytes(planStore.recommendationBytes(for: disposition)))")
                .font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
        }
    }

    private var overallInspectorTitle: String {
        switch planStore.agentState {
        case .ready:
            return NSLocalizedString("Burrow reviewed plan", comment: "cleanup overall inspector")
        case .analyzing:
            return NSLocalizedString("Codex is analyzing", comment: "cleanup overall inspector")
        case .degraded:
            return NSLocalizedString("Codex review incomplete", comment: "cleanup overall inspector")
        default:
            return NSLocalizedString("Scanner baseline", comment: "cleanup overall inspector")
        }
    }

    private func snapshotAgeText(at now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(planStore.snapshotCreatedAt) / 60))
        if minutes == 0 {
            return NSLocalizedString("All scanner candidates · captured just now", comment: "cleanup snapshot age")
        }
        return String(
            format: NSLocalizedString("All scanner candidates · captured %d min ago · rechecked at cleanup", comment: "cleanup snapshot age"),
            minutes)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(String(
                format: NSLocalizedString("%d/%d selected", comment: "plan selection count"),
                planStore.selectedCount,
                planStore.totalCount
            ))
                .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                .contentTransition(.numericText(value: Double(planStore.selectedCount)))
                .animation(reduceMotion ? nil : Brand.Motion.state,
                           value: planStore.selectedCount)
            if !planStore.userOverrides.isEmpty {
                Text(String(format: NSLocalizedString("%d manual changes", comment: ""), planStore.userOverrides.count))
                    .font(Brand.mono(9)).foregroundStyle(Brand.amber)
            }
            Spacer()
            Button {
                if let selection = planStore.selection { onConfirm(selection) }
            } label: {
                Text(pillLabel).font(Brand.sans(13, .semibold)).foregroundStyle(.black)
                    .contentTransition(.numericText(value: Double(planStore.selectedBytes)))
                    .animation(reduceMotion ? nil : Brand.Motion.state,
                               value: planStore.selectedBytes)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                    .background(Capsule().fill(Color.white))
            }
            .buttonStyle(.plain).disabled(!planStore.canConfirmPlan)
            .opacity(planStore.canConfirmPlan ? 1 : 0.5)
        }
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(LinearGradient(colors: [Brand.nearBlack.opacity(0), Brand.nearBlack.opacity(0.92)],
                                   startPoint: .top, endPoint: .bottom).allowsHitTesting(false))
    }

    private var pillLabel: String {
        let total = Fmt.bytes(planStore.selectedBytes)
        if case .analyzing = planStore.agentState {
            return NSLocalizedString("Waiting for Codex analysis", comment: "cleanup confirm pill")
        }
        if case .degraded = planStore.agentState {
            return NSLocalizedString("Codex review incomplete · Retry", comment: "cleanup confirm pill")
        }
        if planStore.canUseAgentCTA {
            return String(format: NSLocalizedString("Clean verified plan · %@", comment: ""), total)
        }
        if !planStore.userOverrides.isEmpty {
            return String(format: NSLocalizedString("Clean current plan · %@", comment: ""), total)
        }
        return Store.cacheRemovalMode == .trash
            ? String(format: NSLocalizedString("Move to Trash · %@", comment: "confirm pill"), total)
            : String(format: NSLocalizedString("Permanently clean · %@", comment: "confirm pill"), total)
    }

    // MARK: - Category chrome

    static func glyph(for category: String) -> String {
        switch category {
        case "User essentials":       return "person.crop.circle"
        case "App caches":            return "shippingbox"
        case "Browsers":              return "globe"
        case "Cloud & Office":        return "icloud"
        case "Developer tools":       return "hammer"
        case "AI Tools", "AI tools":  return "sparkles"
        case "Communication":         return "bubble.left.and.bubble.right"
        case "Applications":          return "app.badge"
        case "Virtualization":        return "server.rack"
        case "Application Support":   return "folder.badge.gearshape"
        case "App leftovers":         return "trash.slash"
        default:                       return "tray.full"
        }
    }

    static func consequence(for category: String) -> String {
        switch category {
        case "User essentials":
            return NSLocalizedString("System-managed caches and logs. Regenerated as macOS needs them.", comment: "")
        case "App caches", "Applications", "Application Support":
            return NSLocalizedString("App temporary files. Regenerated next launch.", comment: "")
        case "Browsers":
            return NSLocalizedString("Page caches — sites load a touch slower on first visit.", comment: "")
        case "Developer tools":
            return NSLocalizedString("Build and package caches. First build will be slower.", comment: "")
        case "AI Tools", "AI tools":
            return NSLocalizedString("Model and tool caches. Re-downloaded on next use.", comment: "")
        case "Communication":
            return NSLocalizedString("Message media caches. Re-fetched when you scroll back.", comment: "")
        case "Virtualization":
            return NSLocalizedString("VM and container caches. Images re-pull on next run.", comment: "")
        case "Cloud & Office":
            return NSLocalizedString("Sync caches. Files re-sync from the cloud.", comment: "")
        case "App leftovers":
            return NSLocalizedString("Files from apps that are no longer installed.", comment: "")
        default:
            return NSLocalizedString("Cache files. Regenerated as needed.", comment: "")
        }
    }

    private func investigationRows(
        _ investigation: CleanupAgentInvestigation
    ) -> [(String, CleanupAgentCheck)] {
        [
            (NSLocalizedString("Scope", comment: "cleanup investigation check"), investigation.scope),
            (NSLocalizedString("Ownership", comment: "cleanup investigation check"), investigation.ownership),
            (NSLocalizedString("Consumers", comment: "cleanup investigation check"), investigation.consumers),
            (NSLocalizedString("Lifecycle", comment: "cleanup investigation check"), investigation.lifecycle),
            (NSLocalizedString("Recovery", comment: "cleanup investigation check"), investigation.recovery),
            (NSLocalizedString("Sensitivity", comment: "cleanup investigation check"), investigation.sensitivity),
        ]
    }

    private func investigationMetadataRows(
        _ investigation: CleanupAgentInvestigation
    ) -> [(String, String)] {
        var rows = [
            (NSLocalizedString("Scope type", comment: "cleanup investigation metadata"),
             investigation.scopeKind.title),
            (NSLocalizedString("Consumer evidence", comment: "cleanup investigation metadata"),
             investigation.consumerBasis.title),
            (NSLocalizedString("Decision basis", comment: "cleanup investigation metadata"),
             investigation.decisionBasis.title),
        ]
        if !investigation.consumerReference.sourcePath.isEmpty {
            rows.append((
                NSLocalizedString("Consumer source", comment: "cleanup investigation metadata"),
                NSString(string: investigation.consumerReference.sourcePath).abbreviatingWithTildeInPath))
        }
        if !investigation.consumerReference.targetPath.isEmpty {
            rows.append((
                NSLocalizedString("Consumer target", comment: "cleanup investigation metadata"),
                NSString(string: investigation.consumerReference.targetPath).abbreviatingWithTildeInPath))
        }
        return rows
    }
}

private extension View {
    func agentChip(color: Color) -> some View {
        self.font(Brand.mono(9, .medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}

private extension CleanupRecommendationDisposition {
    var title: String {
        switch self {
        case .delete: return NSLocalizedString("Suggested cleanup", comment: "")
        case .keep: return NSLocalizedString("Suggested keep", comment: "")
        case .humanIntentRequired: return NSLocalizedString("Needs your intent", comment: "")
        }
    }

    var shortTitle: String {
        switch self {
        case .delete: return NSLocalizedString("Agent: clean", comment: "")
        case .keep: return NSLocalizedString("Agent: keep", comment: "")
        case .humanIntentRequired: return NSLocalizedString("Agent: ask", comment: "")
        }
    }

    var symbol: String {
        switch self {
        case .delete: return "sparkles"
        case .keep: return "shield.checkered"
        case .humanIntentRequired: return "person.crop.circle.badge.questionmark"
        }
    }

    var color: Color {
        switch self {
        case .delete: return Tool.clean.accent
        case .keep: return Brand.blue
        case .humanIntentRequired: return Brand.amber
        }
    }
}

private extension CleanupAgentEvidenceBasis {
    var title: String {
        switch self {
        case .observation: return NSLocalizedString("Observed", comment: "cleanup Agent evidence basis")
        case .relationship: return NSLocalizedString("Relationship", comment: "cleanup Agent evidence basis")
        case .inference: return NSLocalizedString("Inference", comment: "cleanup Agent evidence basis")
        case .gap: return NSLocalizedString("Not verified", comment: "cleanup Agent evidence basis")
        }
    }

    var color: Color {
        switch self {
        case .observation, .relationship: return Tool.clean.accent
        case .inference: return Brand.blue
        case .gap: return Brand.amber
        }
    }
}

private extension CleanupAgentCheckState {
    var title: String {
        switch self {
        case .verified: return NSLocalizedString("Verified", comment: "cleanup investigation state")
        case .notApplicable: return NSLocalizedString("N/A", comment: "cleanup investigation state")
        case .unknown: return NSLocalizedString("Not verified", comment: "cleanup investigation state")
        }
    }

    var color: Color {
        switch self {
        case .verified: return Tool.clean.accent
        case .notApplicable: return Brand.textTertiary
        case .unknown: return Brand.amber
        }
    }
}

private extension CleanupAgentScopeKind {
    var title: String {
        switch self {
        case .homogeneous: return NSLocalizedString("Homogeneous", comment: "cleanup scope kind")
        case .heterogeneous: return NSLocalizedString("Heterogeneous", comment: "cleanup scope kind")
        case .unknown: return NSLocalizedString("Unknown", comment: "cleanup scope kind")
        }
    }
}

private extension CleanupAgentConsumerBasis {
    var title: String {
        switch self {
        case .externalCurrent: return NSLocalizedString("External · current", comment: "cleanup consumer basis")
        case .externalInactive: return NSLocalizedString("External · inactive", comment: "cleanup consumer basis")
        case .internalOnly: return NSLocalizedString("Internal only", comment: "cleanup consumer basis")
        case .noneFound: return NSLocalizedString("None found", comment: "cleanup consumer basis")
        case .unknown: return NSLocalizedString("Unknown", comment: "cleanup consumer basis")
        }
    }
}

private extension CleanupAgentDecisionBasis {
    var title: String {
        switch self {
        case .currentConsumer: return NSLocalizedString("Current consumer", comment: "cleanup decision basis")
        case .mixedContainer: return NSLocalizedString("Mixed container", comment: "cleanup decision basis")
        case .incompleteInvestigation: return NSLocalizedString("Incomplete review", comment: "cleanup decision basis")
        case .userTradeoff: return NSLocalizedString("User tradeoff", comment: "cleanup decision basis")
        case .unusedRecoverable: return NSLocalizedString("Unused · recoverable", comment: "cleanup decision basis")
        case .sensitiveOrIrreplaceable: return NSLocalizedString("Sensitive or irreplaceable", comment: "cleanup decision basis")
        }
    }
}

extension CleanList.Item {
    var displayName: String { (path as NSString).lastPathComponent }
    var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}
