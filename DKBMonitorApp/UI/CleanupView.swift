import DKBMonitorCore
import SwiftUI

/// Disk-reclaiming pane: known junk locations on one tab, a size-ranked
/// large-file scan on the other.
///
/// Both tabs delete only through the Trash (the Trash target itself aside)
/// and both put a confirmation dialog in front of every deletion — this is
/// the one pane in the app that destroys user data, so neither is optional.
///
/// Card/`GroupBox` styling follows `SystemView` rather than inventing a
/// second visual language for the same kind of page.
struct CleanupView: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case junk = "Junk Files"
        case largeFiles = "Large Files"
        var id: Self { self }
    }

    @Bindable private var viewModel = CleanupViewModel.shared
    @State private var tab: Tab = .junk
    @State private var isConfirmingJunkClean = false
    @State private var isConfirmingTrash = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch tab {
                case .junk: junkTab
                case .largeFiles: largeFilesTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let message = viewModel.statusMessage {
                Divider()
                Label(message, systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                // `.labelsHidden()` is required even with an empty title: the
                // label still claims layout space, which shows up as a gap on
                // the leading edge and squeezes the segments inside a fixed
                // frame. `.fixedSize()` then lets the control take its natural
                // width instead of a hardcoded one that has to be re-guessed
                // whenever a tab is renamed.
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .task {
            await viewModel.loadTargets()
            viewModel.loadScanRoots()
            if viewModel.junkSizes.isEmpty { await viewModel.measureJunk() }
        }
        .onDisappear {
            // The view model is a singleton, so leaving the pane doesn't tear
            // the scan down on its own — without this, walking a whole home
            // directory carries on in the background for a result list nobody
            // is looking at any more.
            viewModel.cancelScan()
        }
    }

    // MARK: - Junk

    private var junkTab: some View {
        ScrollView { junkContent }
    }

    /// Split out of the `ScrollView` for the same reason as `SystemView.content`
    /// — `ImageRenderer` renders a `ScrollView` blank.
    var junkContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            junkHeader
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(viewModel.junkTargets) { target in
                        junkRow(target)
                        if target.id != viewModel.junkTargets.last?.id { Divider() }
                    }
                }
                .padding(10)
            }
        }
        .padding(24)
    }

    private var junkHeader: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Reclaimable space").font(.headline)
                Text("Everything is moved to the Trash — except the Trash itself, which is emptied permanently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                Text(CleanupViewModel.formatBytes(viewModel.totalJunkBytes))
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .redacted(reason: viewModel.isMeasuring ? .placeholder : [])
                HStack(spacing: 8) {
                    if viewModel.isMeasuring {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Re-measure") { Task { await viewModel.measureJunk() } }
                    }
                    Button("Clean Selected") { isConfirmingJunkClean = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.junkSelection.isEmpty)
                }
            }
        }
        .confirmationDialog(
            "Clean \(CleanupViewModel.formatBytes(viewModel.selectedJunkBytes))?",
            isPresented: $isConfirmingJunkClean,
            titleVisibility: .visible
        ) {
            Button("Clean", role: .destructive) { Task { await viewModel.cleanSelected() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Selected caches move to the Trash. If the Trash is selected, it is emptied permanently and cannot be undone.")
        }
    }

    private func junkRow(_ target: JunkTarget) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { viewModel.junkSelection.contains(target.path) },
                set: { isOn in
                    if isOn { viewModel.junkSelection.insert(target.path) }
                    else { viewModel.junkSelection.remove(target.path) }
                }
            ))
            .labelsHidden()

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(target.name).font(.callout)
                    if target.deletesPermanently {
                        Text("Permanent")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.red.opacity(0.15), in: Capsule())
                            .foregroundStyle(.red)
                    }
                }
                Text(target.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

            Group {
                if let bytes = viewModel.junkSizes[target.path] {
                    Text(CleanupViewModel.formatBytes(bytes))
                } else {
                    Text("0 KB").redacted(reason: .placeholder)
                }
            }
            .font(.callout)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .help(target.displayPath)
    }

    // MARK: - Large files

    private var largeFilesTab: some View {
        VStack(spacing: 0) {
            scanControls
            Divider()
            scanResults
        }
    }

    private var scanControls: some View {
        HStack(spacing: 12) {
            Picker("Folder", selection: $viewModel.selectedRootPath) {
                ForEach(viewModel.scanRoots) { Text($0.title).tag($0.path) }
            }
            .frame(width: 200)

            Picker("Larger than", selection: $viewModel.minimumMB) {
                Text("20 MB").tag(20)
                Text("50 MB").tag(50)
                Text("100 MB").tag(100)
                Text("500 MB").tag(500)
                Text("1 GB").tag(1024)
            }
            .frame(width: 190)

            Toggle("Hidden files", isOn: $viewModel.includeHidden)

            Spacer()

            if viewModel.isScanning {
                ProgressView().controlSize(.small)
                Button("Stop") { viewModel.cancelScan() }
            } else {
                Button("Scan") { viewModel.startScan() }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.selectedRootPath.isEmpty)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var scanResults: some View {
        if viewModel.isScanning {
            scanProgress
        } else if let error = viewModel.scanErrorMessage {
            ContentUnavailableView {
                Label("Could not scan", systemImage: "folder.badge.questionmark")
            } description: {
                Text("\(error) macOS asks for permission the first time an app reads Desktop, Documents or Downloads — grant it in System Settings › Privacy & Security › Files and Folders.")
            }
        } else if viewModel.scanResults.isEmpty {
            ContentUnavailableView(
                viewModel.hasScanned ? "No files that large" : "No scan yet",
                systemImage: "doc.text.magnifyingglass",
                description: Text(viewModel.hasScanned
                    ? "Nothing in that folder is above the size threshold. Try a lower one."
                    : "Pick a folder and a size threshold, then press Scan.")
            )
        } else {
            resultsList
        }
    }

    private var scanProgress: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("\(viewModel.scannedFiles) items scanned").font(.callout)
            Text(viewModel.currentFolder)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(viewModel.scanResults.count) files · \(CleanupViewModel.formatBytes(viewModel.matchedBytes))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show in Finder") { viewModel.revealSelectedFiles() }
                    .disabled(viewModel.fileSelection.isEmpty)
                Button("Move to Trash") { isConfirmingTrash = true }
                    .disabled(viewModel.fileSelection.isEmpty)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)

            List(viewModel.scanResults, selection: $viewModel.fileSelection) { entry in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name).lineLimit(1)
                        Text(entry.folder)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Text(entry.modified.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(CleanupViewModel.formatBytes(entry.sizeBytes))
                        .monospacedDigit()
                        .frame(width: 80, alignment: .trailing)
                }
                .tag(entry.path)
            }
        }
        .confirmationDialog(
            "Move \(viewModel.fileSelection.count) file(s) to the Trash?",
            isPresented: $isConfirmingTrash,
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { Task { await viewModel.trashSelectedFiles() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They stay recoverable from the Trash until you empty it.")
        }
    }
}
