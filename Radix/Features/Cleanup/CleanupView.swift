import SwiftUI

/// Sidebar section with one row per cleanup category and its safe-to-free total.
struct CleanupSidebarSection: View {
    @ObservedObject var cleanup: CleanupModel

    var body: some View {
        Section("Cleanup") {
            ForEach(CleanupCategory.allCases) { category in
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(category.title)
                        Text(subtitle(category))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: category.systemImage)
                }
                .tag(category.sidebarID)
            }
        }
        .onAppear { cleanup.scanAllIfNeeded() }
    }

    private func subtitle(_ category: CleanupCategory) -> String {
        let state = cleanup.state(category)
        if state.isScanning && state.scannedAt == nil { return String(localized: "Scanning…") }
        if state.items.isEmpty { return state.notice == nil ? String(localized: "Nothing found") : String(localized: "Unavailable") }
        let safe = cleanup.totalFrees(category, safety: .safe)
        return safe > 0
            ? String(localized: "\(RadixFormatters.size(safe)) safe to free")
            : String(localized: "Items: \(state.items.count)")
    }
}

/// Detail view for one cleanup category: what is there, what removal frees, and the remove flow.
struct CleanupView: View {
    let category: CleanupCategory
    @ObservedObject var cleanup: CleanupModel
    @State private var confirmsRemoval = false

    private var state: CleanupModel.CategoryState { cleanup.state(category) }
    private var selected: [CleanupItem] { cleanup.selectedItems(in: category) }
    private var selectedFrees: Int64 { selected.compactMap(\.frees).reduce(0, +) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if !cleanup.lastOutcomes.isEmpty, cleanup.lastOutcomes.first?.item.category == category {
                outcomeBanner
            }
            Divider()
            if state.items.isEmpty {
                emptyState
            } else {
                table
            }
            Divider()
            bottomBar
        }
        .navigationTitle(category.title)
        .alert(String(localized: "Remove the selected items?"), isPresented: $confirmsRemoval) {
            Button("Remove", role: .destructive) {
                Task { await cleanup.removeSelected(in: category) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmationMessage)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: category.systemImage)
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(category.title).font(.title2.weight(.semibold))
                Text(category.summary).foregroundStyle(.secondary)
                if cleanup.snapshotsPresent {
                    Text("A Time Machine local snapshot exists. Sizes show the space that returns after macOS deletes the snapshot.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notice = state.notice {
                    Text(notice).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(RadixFormatters.size(cleanup.totalFrees(category, safety: .safe)))
                    .font(.title2.monospacedDigit().weight(.semibold))
                Text("safe to free").font(.caption).foregroundStyle(.secondary)
            }
            Button {
                cleanup.refresh(category)
            } label: {
                if state.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
            }
            .disabled(state.isScanning || cleanup.isRemoving)
        }
        .padding(16)
    }

    private var table: some View {
        Table(state.items, selection: $cleanup.selection) {
            TableColumn("Name") { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).lineLimit(1)
                    Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .help(item.subtitle)
            }
            .width(min: 220, ideal: 360)
            TableColumn("Status") { item in
                CleanupStatusBadge(item: item)
            }
            .width(min: 160, ideal: 240)
            TableColumn("Frees") { item in
                Group {
                    if let frees = item.frees {
                        Text(RadixFormatters.size(frees))
                    } else if item.measurePaths.isEmpty {
                        Text(verbatim: "—")
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                }
                .monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .help(item.holds.map { String(localized: "Holds \(RadixFormatters.size($0)) with shared blocks counted once") } ?? "")
            }
            .width(min: 70, ideal: 90)
            TableColumn("Last Used") { item in
                Text(verbatim: item.lastUsed.map { $0.formatted(.relative(presentation: .named)) } ?? "—")
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if state.isScanning {
                ProgressView()
                Text("Scanning…").foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
                Text("Nothing to clean up here.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var bottomBar: some View {
        HStack {
            Button("Select Safe Items") { cleanup.selectSafeItems(in: category) }
                .disabled(state.items.isEmpty || cleanup.isRemoving)
            Spacer()
            if cleanup.isRemoving {
                ProgressView().controlSize(.small)
                Text("Removing…").foregroundStyle(.secondary)
            } else if !selected.isEmpty {
                Text("Selected: \(selected.count) · frees \(RadixFormatters.size(selectedFrees))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Button("Remove…", role: .destructive) { confirmsRemoval = true }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selected.isEmpty || cleanup.isRemoving)
        }
        .padding(12)
    }

    private var outcomeBanner: some View {
        let failed = cleanup.lastOutcomes.filter { !$0.succeeded }
        let succeeded = cleanup.lastOutcomes.count - failed.count
        return HStack(alignment: .top) {
            Image(systemName: failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(failed.isEmpty ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Removed: \(succeeded) of \(cleanup.lastOutcomes.count)")
                ForEach(failed) { outcome in
                    Text(verbatim: "\(outcome.item.title): \(outcome.detail)").font(.caption).foregroundStyle(.secondary)
                }
                Text(verbatim: "~/Library/Logs/Radix/cleanup.log").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Dismiss") { cleanup.dismissOutcomes() }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }

    private var confirmationMessage: String {
        var lines = [String(localized: "This frees about \(RadixFormatters.size(selectedFrees)).")]
        let holdsData = selected.filter { $0.safety == .holdsData }
        if holdsData.contains(where: { if case .removeWorktree = $0.action { true } else { false } }) {
            lines.append(String(localized: "Worktrees with local work are saved to ~/Archive/radix-cleanup first. If a save fails, nothing is removed."))
        }
        if holdsData.contains(where: { if case .deleteDockerVolume = $0.action { true } else { false } }) {
            lines.append(String(localized: "Docker volumes hold data that exists only here. Their data is deleted."))
        }
        if selected.contains(where: { if case .deleteRebuildableFolders = $0.action { true } else { false } }) {
            lines.append(String(localized: "Build folders are deleted permanently, not moved to the Trash. The next build makes them again."))
        }
        if category == .simulators {
            lines.append(String(localized: "Deleted simulators lose their installed apps and data."))
        }
        return lines.joined(separator: "\n\n")
    }
}

private struct CleanupStatusBadge: View {
    let item: CleanupItem

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(item.blockedReason ?? item.status).lineLimit(1)
        }
        .foregroundStyle(item.blockedReason == nil ? .primary : .secondary)
        .help(item.blockedReason.map { String(localized: "Cannot remove: \($0)") } ?? item.status)
    }

    private var color: Color {
        if item.blockedReason != nil { return .gray }
        switch item.safety {
        case .safe: return .green
        case .review: return .yellow
        case .holdsData: return .orange
        }
    }
}
