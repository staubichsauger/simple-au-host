import AppKit
import SwiftUI

private enum MultiTrackWorkspaceTab: String, CaseIterable, Identifiable {
    case perform = "Perform"
    case rack = "Rack"
    case show = "Show"
    case setup = "Setup"

    var id: String { rawValue }
}

private struct PendingSessionLoadRequest {
    let url: URL
    let sessionName: String
}

struct MultiTrackView: View {
    @StateObject private var viewModel = MultiTrackViewModel()
    let closeCoordinator: AppCloseCoordinator
    @State private var selectedTab: MultiTrackWorkspaceTab = .rack
    @State private var showsDiagnostics = true
    @State private var showsEmbeddedPluginPane = true
    @State private var pendingSessionLoadRequest: PendingSessionLoadRequest?
    @State private var showsNewSessionConfirmation = false
    @State private var tuningPopoutPanel: NSPanel?

    init(closeCoordinator: AppCloseCoordinator) {
        self.closeCoordinator = closeCoordinator
    }

    var body: some View {
        StudioShell(
            eyebrow: "",
            title: "",
            subtitle: ""
        ) {
            EmptyView()
        } content: {
            VStack(alignment: .leading, spacing: 18) {
                workspaceTabs
                workspaceBody
            }
        }
        .task {
            selectedTab = viewModel.launchesIntoPerformViewOnStartup ? .perform : .rack
            await viewModel.loadAsync()
            await viewModel.applyStartupSessionPreferenceIfNeededAsync()
            viewModel.applyStartupEnginePreferenceIfNeeded()
            configureCloseHandling()
            updateTelemetryPublishing()
        }
        .onChange(of: selectedTab) { _, _ in
            updateTelemetryPublishing()
            if selectedTab != .rack {
                viewModel.clearEmbeddedPluginEditor()
            }
        }
        .onChange(of: showsDiagnostics) { _, _ in
            updateTelemetryPublishing()
        }
        .onChange(of: viewModel.isRunning) { _, _ in
            updateTelemetryPublishing()
        }
        .onDisappear {
            viewModel.setTelemetryPublishingEnabled(false)
            viewModel.clearEmbeddedPluginEditor()
            tuningPopoutPanel?.close()
            tuningPopoutPanel = nil
            closeCoordinator.updateHandler(nil)
        }
        .alert("Discard Unsaved Changes?", isPresented: Binding(
            get: { pendingSessionLoadRequest != nil },
            set: { isPresented in
                if !isPresented {
                    pendingSessionLoadRequest = nil
                }
            }
        )) {
            Button("Cancel", role: .cancel) {
                pendingSessionLoadRequest = nil
            }

            Button("Load", role: .destructive) {
                if let request = pendingSessionLoadRequest {
                    performSessionLoad(from: request.url)
                }
                pendingSessionLoadRequest = nil
            }
        } message: {
            Text("Load \(pendingSessionLoadRequest?.sessionName ?? "this show") and discard the current unsaved changes?")
        }
        .alert("Discard Unsaved Changes?", isPresented: $showsNewSessionConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("New Show", role: .destructive) {
                performCreateNewSession()
            }
        } message: {
            Text("Create a new show and discard the current unsaved changes?")
        }
        .alert(
            "Audio Device Unavailable",
            isPresented: Binding(
                get: { viewModel.sessionDeviceResolutionAlert != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.sessionDeviceResolutionAlert = nil
                    }
                }
            ),
            presenting: viewModel.sessionDeviceResolutionAlert
        ) { _ in
            Button("Retry") {
                viewModel.retrySessionDeviceResolution()
            }
            Button("Cancel", role: .cancel) {
                viewModel.sessionDeviceResolutionAlert = nil
            }
        } message: { alert in
            Text(alert.message)
        }
        .modifier(EngineStartFailureAlertModifier(viewModel: viewModel))
    }

    private var workspaceTabs: some View {
        HStack(spacing: 8) {
            sessionTitleView
            workspaceTabButtons

            Spacer()

            workspaceToolbarActions
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.20))
        .overlay(
            Rectangle()
                .fill(Color.white.opacity(0.05))
                .frame(height: 1),
            alignment: .bottom
        )
    }

    private var sessionTitleView: some View {
        Text(viewModel.currentSessionDisplayName)
            .font(.system(size: 14, weight: .semibold, design: .default))
            .foregroundStyle(StudioTheme.strongText)
            .lineLimit(1)
    }

    private var workspaceTabButtons: some View {
        HStack(spacing: 0) {
            ForEach(MultiTrackWorkspaceTab.allCases) { tab in
                workspaceTabButton(for: tab)
            }
        }
    }

    private func workspaceTabButton(for tab: MultiTrackWorkspaceTab) -> some View {
        Button {
            selectedTab = tab
        } label: {
            Text(tab.rawValue.uppercased())
                .font(.system(size: 11, weight: .medium, design: .default))
                .tracking(1.0)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(tabBackground(for: tab))
                .foregroundStyle(tabForeground(for: tab))
        }
        .buttonStyle(.plain)
    }

    private func tabBackground(for tab: MultiTrackWorkspaceTab) -> some ShapeStyle {
        selectedTab == tab ? Color.white.opacity(0.06) : Color.clear
    }

    private func tabForeground(for tab: MultiTrackWorkspaceTab) -> Color {
        selectedTab == tab ? StudioTheme.accent : StudioTheme.mutedText
    }

    @ViewBuilder
    private var workspaceToolbarActions: some View {
        HStack(spacing: 12) {
            if selectedTab == .rack {
                Button {
                    showsEmbeddedPluginPane.toggle()
                } label: {
                    Label(showsEmbeddedPluginPane ? "Hide Panel" : "Show Panel", systemImage: showsEmbeddedPluginPane ? "sidebar.right" : "rectangle.split.2x1")
                }
                .buttonStyle(StudioSecondaryButtonStyle())
            }

            startStopButton
        }
    }

    private var startStopButton: some View {
        Group {
            if viewModel.isRunning {
                Button {
                    viewModel.toggleStartStop()
                } label: {
                    Label("Running", systemImage: "stop.fill")
                }
                .buttonStyle(StudioDestructiveButtonStyle())
            } else {
                Button {
                    viewModel.toggleStartStop()
                } label: {
                    Label("Stopped", systemImage: "play.fill")
                }
                .buttonStyle(StudioSecondaryButtonStyle())
                .disabled(viewModel.isBusy)
            }
        }
    }

    @ViewBuilder
    private var workspaceBody: some View {
        switch selectedTab {
        case .perform:
            PerformTabView(
                viewModel: viewModel,
                requestCreateNewSession: requestCreateNewSession,
                openSessionPanel: openSessionPanel,
                saveSessionAs: saveSessionAs,
                requestSessionLoad: { requestSessionLoad(from: $0) }
            )
        case .rack:
            RackTabView(
                viewModel: viewModel,
                showsEmbeddedPluginPane: $showsEmbeddedPluginPane,
                popOutTuningInspector: popOutTuningInspector
            )
        case .show:
            ShowTabView(
                viewModel: viewModel,
                showsDiagnostics: $showsDiagnostics,
                requestCreateNewSession: requestCreateNewSession,
                openSessionPanel: openSessionPanel,
                saveSessionAs: saveSessionAs,
                requestSessionLoad: { requestSessionLoad(from: $0) }
            )
        case .setup:
            SetupTabView(
                viewModel: viewModel,
                chooseStartupSessionPanel: chooseStartupSessionPanel
            )
        }
    }

    private func popOutTuningInspector() {
        if let existing = tuningPopoutPanel {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let tuningView = TuningPopoutView(viewModel: viewModel)
        let hostingController = NSHostingController(rootView: tuningView)
        hostingController.preferredContentSize = NSSize(width: 480, height: 600)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 600),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Waves Tune Control"
        panel.contentViewController = hostingController
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        tuningPopoutPanel = panel
    }

    private func updateTelemetryPublishing() {
        let shouldPublishTelemetry = viewModel.isRunning && selectedTab == .show && showsDiagnostics
        viewModel.setTelemetryPublishingEnabled(shouldPublishTelemetry)
    }

    private func openSessionPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.simpleAUHostMultiTrackSession, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = try? viewModel.managedSessionsDirectoryURL()

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        requestSessionLoad(from: url)
    }

    private func chooseStartupSessionPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.simpleAUHostMultiTrackSession, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = try? viewModel.managedSessionsDirectoryURL()

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        viewModel.setStartupSpecificSessionURL(url)
    }

    private func configureCloseHandling() {
        closeCoordinator.updateHandler(
            .init(
                hasUnsavedChanges: { viewModel.hasUnsavedChanges },
                documentName: { viewModel.currentSessionName },
                save: { saveCurrentSessionForClose() }
            )
        )
    }

    @discardableResult
    private func saveCurrentSessionForClose() -> Bool {
        do {
            if viewModel.hasStoredSessionFile {
                try viewModel.saveSession()
                return true
            }
            return saveSessionAs()
        } catch {
            viewModel.statusMessage = error.localizedDescription
            presentErrorAlert(error)
            return false
        }
    }

    @discardableResult
    private func saveSessionAs() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.simpleAUHostMultiTrackSession]
        panel.canCreateDirectories = true
        panel.directoryURL = try? viewModel.managedSessionsDirectoryURL()
        panel.nameFieldStringValue = viewModel.suggestedSessionFilename()

        guard panel.runModal() == .OK, let url = panel.url else {
            return false
        }

        do {
            try viewModel.saveSession(to: url)
            return true
        } catch {
            viewModel.statusMessage = error.localizedDescription
            presentErrorAlert(error)
            return false
        }
    }

    private func presentErrorAlert(_ error: Error) {
        NSAlert(error: error).runModal()
    }

    private func requestSessionLoad(from url: URL) {
        let sessionName = url.deletingPathExtension().lastPathComponent
        if viewModel.hasUnsavedChanges {
            pendingSessionLoadRequest = PendingSessionLoadRequest(url: url, sessionName: sessionName)
            return
        }

        performSessionLoad(from: url)
    }

    private func requestCreateNewSession() {
        if viewModel.hasUnsavedChanges {
            showsNewSessionConfirmation = true
            return
        }

        performCreateNewSession()
    }

    private func performCreateNewSession() {
        viewModel.createNewSession()
    }

    private func performSessionLoad(from url: URL) {
        Task {
            do {
                try await viewModel.loadSessionAsync(from: url)
            } catch {
                viewModel.statusMessage = error.localizedDescription
            }
        }
    }
}
