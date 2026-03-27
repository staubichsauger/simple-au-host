import SwiftUI

struct MultiTrackView: View {
    @StateObject private var viewModel = MultiTrackViewModel()
    @State private var isImportingSession = false
    @State private var isExportingSession = false
    @State private var showsDiagnostics = false
    @State private var sessionDocument = MultiTrackSessionDocument(
        session: MultiTrackSessionFile(
            name: "Untitled Session",
            inputDeviceID: nil,
            outputDeviceID: nil,
            bufferSize: 128,
            latencyBufferSettings: MultiTrackLatencyBufferSettings(hardwareBufferSize: 128),
            tracks: [MultiTrackTrackConfiguration(name: "Track 1", layout: .mono)]
        )
    )
    let onBackToModeSelection: (() -> Void)?

    init(onBackToModeSelection: (() -> Void)? = nil) {
        self.onBackToModeSelection = onBackToModeSelection
    }

    var body: some View {
        StudioShell(
            eyebrow: "Multi Track Rack",
            title: viewModel.currentSessionName,
            subtitle: "Build a compact live rack with per-track routing, insert chains, latency classes, and session management."
        ) {
            HStack(spacing: 8) {
                StudioBadge(
                    title: viewModel.isRunning ? "Running" : "Stopped",
                    systemImage: viewModel.isRunning ? "dot.radiowaves.left.and.right" : "stop.fill",
                    tint: viewModel.isRunning ? .green : .white.opacity(0.78)
                )
                StudioBadge(
                    title: "\(viewModel.tracks.count) Tracks",
                    systemImage: "slider.horizontal.3",
                    tint: Color(red: 0.42, green: 0.84, blue: 0.97)
                )
                if !viewModel.sessionWarnings.isEmpty {
                    StudioBadge(
                        title: "\(viewModel.sessionWarnings.count) Warnings",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: StudioTheme.warning
                    )
                }
            }
        } content: {
            GeometryReader { proxy in
                ScrollView {
                    Group {
                        if proxy.size.width >= 1220 {
                            HStack(alignment: .top, spacing: 20) {
                                mainColumn
                                sidebarColumn
                                    .frame(width: 340)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 20) {
                                mainColumn
                                sidebarColumn
                            }
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .task {
            viewModel.load()
        }
        .fileImporter(
            isPresented: $isImportingSession,
            allowedContentTypes: [.simpleAUHostMultiTrackSession, .json]
        ) { result in
            do {
                let url = try result.get()
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                try viewModel.loadSession(from: url)
            } catch {
                viewModel.statusMessage = error.localizedDescription
            }
        }
        .fileExporter(
            isPresented: $isExportingSession,
            document: sessionDocument,
            contentType: .simpleAUHostMultiTrackSession,
            defaultFilename: viewModel.suggestedSessionFilename()
        ) { result in
            switch result {
            case .success(let url):
                viewModel.rememberExportedSessionURL(url)
            case .failure(let error):
                viewModel.statusMessage = error.localizedDescription
            }
        }
    }

    private var sessionOverviewPanel: some View {
        StudioPanel("Session I/O", subtitle: "Global interfaces and hardware buffer size shared by all tracks.") {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        StudioFieldLabel("Input Interface")
                        Picker("Input interface", selection: $viewModel.selectedInputDeviceID) {
                            ForEach(viewModel.inputDevices) { device in
                                Text(device.displayName).tag(Optional(device.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: viewModel.selectedInputDeviceID) { _, _ in
                            viewModel.handleDeviceSelectionChange()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 12) {
                        StudioFieldLabel("Output Interface")
                        Picker("Output interface", selection: $viewModel.selectedOutputDeviceID) {
                            ForEach(viewModel.outputDevices) { device in
                                Text(device.displayName).tag(Optional(device.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .onChange(of: viewModel.selectedOutputDeviceID) { _, _ in
                            viewModel.handleDeviceSelectionChange()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 12) {
                    StudioFieldLabel("Hardware Buffer")
                    Picker("Hardware buffer size", selection: $viewModel.selectedBufferSize) {
                        ForEach(viewModel.availableBufferSizes, id: \.self) { size in
                            Text("\(size) frames").tag(size)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .onChange(of: viewModel.selectedBufferSize) { _, newValue in
                        viewModel.customBufferSizeText = String(newValue)
                    }

                    HStack(spacing: 10) {
                        TextField("Custom frames", text: $viewModel.customBufferSizeText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180)
                            .onSubmit {
                                viewModel.applyCustomBufferSize()
                            }

                        Button("Apply") {
                            viewModel.applyCustomBufferSize()
                        }
                        .buttonStyle(StudioSecondaryButtonStyle())
                        .disabled(viewModel.isBusy || viewModel.isRunning)
                    }

                    Text(viewModel.bufferSizeHelpText)
                        .font(.caption)
                        .foregroundStyle(StudioTheme.mutedText)
                }
            }
            .disabled(viewModel.isBusy || viewModel.isRunning)
        }
    }

    private var bufferingPanel: some View {
        StudioPanel("Latency Buffers", subtitle: "Buffered and broadcast tracks can run on larger internal blocks than the hardware buffer.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    StudioFieldLabel("Realtime")
                    Spacer()
                    Text("\(viewModel.selectedBufferSize) frames")
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .foregroundStyle(StudioTheme.accent)
                }

                Text("Realtime tracks follow the hardware callback cadence. Buffered and Broadcast/Post must be whole multiples of that size.")
                    .font(.caption)
                    .foregroundStyle(StudioTheme.mutedText)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        latencyField(
                            title: "Buffered",
                            text: $viewModel.bufferedInternalBufferText,
                            action: viewModel.applyBufferedInternalBufferSize
                        )

                        latencyField(
                            title: "Broadcast/Post",
                            text: $viewModel.broadcastInternalBufferText,
                            action: viewModel.applyBroadcastInternalBufferSize
                        )
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        latencyField(
                            title: "Buffered",
                            text: $viewModel.bufferedInternalBufferText,
                            action: viewModel.applyBufferedInternalBufferSize
                        )

                        latencyField(
                            title: "Broadcast/Post",
                            text: $viewModel.broadcastInternalBufferText,
                            action: viewModel.applyBroadcastInternalBufferSize
                        )
                    }
                }
            }
        }
    }

    private var trackToolbarPanel: some View {
        StudioPanel("Track Management", subtitle: "Create mono or stereo strips and edit their routing, inserts, and latency mode below.") {
            HStack(spacing: 12) {
                Button("Add Mono Track") {
                    viewModel.addMonoTrack()
                }
                .buttonStyle(StudioSecondaryButtonStyle())
                .disabled(viewModel.isRunning)

                Button("Add Stereo Track") {
                    viewModel.addStereoTrack()
                }
                .buttonStyle(StudioPrimaryButtonStyle())
                .disabled(viewModel.isRunning)
            }
        }
    }

    private var tracksPanel: some View {
        StudioPanel("Tracks", subtitle: "Each strip owns its own routing, insert chain, and latency class.") {
            LazyVStack(spacing: 16) {
                ForEach($viewModel.tracks) { $track in
                    trackCard($track)
                }
            }
        }
    }

    private func trackCard(_ track: Binding<MultiTrackTrackConfiguration>) -> some View {
        let value = track.wrappedValue

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(value.name.isEmpty ? "Unnamed Track" : value.name)
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .foregroundStyle(StudioTheme.strongText)

                    HStack(spacing: 8) {
                        StudioBadge(
                            title: value.layout.title,
                            systemImage: value.layout == .mono ? "circle.grid.1x1.fill" : "square.split.2x1.fill",
                            tint: Color(red: 0.42, green: 0.84, blue: 0.97)
                        )
                        StudioBadge(
                            title: value.latencyClass.title,
                            systemImage: "speedometer",
                            tint: value.latencyClass == .realtime ? StudioTheme.accent : .white.opacity(0.78)
                        )
                        StudioBadge(
                            title: value.isEnabled ? "Enabled" : "Muted",
                            systemImage: value.isEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                            tint: value.isEnabled ? .green : .white.opacity(0.7)
                        )
                    }
                }

                Spacer()

                Button("Remove Track", role: .destructive) {
                    viewModel.removeTrack(id: value.id)
                }
                .buttonStyle(StudioDestructiveButtonStyle())
                .disabled(viewModel.isRunning)
            }

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        StudioFieldLabel("Track Name")
                        TextField("Track name", text: track.name)
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.isRunning)

                        Toggle("Enabled", isOn: track.isEnabled)
                            .toggleStyle(.switch)
                            .disabled(viewModel.isRunning)

                        StudioFieldLabel("Layout")
                        Picker("Layout", selection: track.layout) {
                            ForEach(TrackChannelLayout.allCases) { layout in
                                Text(layout.title).tag(layout)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .disabled(viewModel.isRunning)
                        .onChange(of: track.wrappedValue.layout) { _, _ in
                            viewModel.sanitizeTrack(id: value.id)
                        }

                        StudioFieldLabel("Latency Class")
                        Picker("Latency class", selection: track.latencyClass) {
                            ForEach(TrackLatencyClass.allCases) { latencyClass in
                                Text(latencyClass.title).tag(latencyClass)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .disabled(viewModel.isRunning)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 12) {
                        StudioFieldLabel("Input Start Channel")
                        Picker("Input start channel", selection: track.inputStartChannel) {
                            ForEach(viewModel.availableInputStartChannels(for: value), id: \.self) { channel in
                                Text("Channel \(channel)").tag(channel)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(viewModel.isRunning || viewModel.availableInputStartChannels(for: value).isEmpty)

                        StudioFieldLabel("Output Start Channel")
                        Picker("Output start channel", selection: track.outputStartChannel) {
                            ForEach(viewModel.availableOutputStartChannels(for: value), id: \.self) { channel in
                                Text("Channel \(channel)").tag(channel)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(viewModel.isRunning || viewModel.availableOutputStartChannels(for: value).isEmpty)

                        StudioMetricTile("Internal Buffer", value: viewModel.internalBufferDescription(for: value))
                        StudioMetricTile("Mode Notes", value: value.latencyClass.description)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        StudioFieldLabel("Track Name")
                        TextField("Track name", text: track.name)
                            .textFieldStyle(.roundedBorder)
                            .disabled(viewModel.isRunning)

                        Toggle("Enabled", isOn: track.isEnabled)
                            .toggleStyle(.switch)
                            .disabled(viewModel.isRunning)

                        StudioFieldLabel("Layout")
                        Picker("Layout", selection: track.layout) {
                            ForEach(TrackChannelLayout.allCases) { layout in
                                Text(layout.title).tag(layout)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .disabled(viewModel.isRunning)
                        .onChange(of: track.wrappedValue.layout) { _, _ in
                            viewModel.sanitizeTrack(id: value.id)
                        }

                        StudioFieldLabel("Latency Class")
                        Picker("Latency class", selection: track.latencyClass) {
                            ForEach(TrackLatencyClass.allCases) { latencyClass in
                                Text(latencyClass.title).tag(latencyClass)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .disabled(viewModel.isRunning)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        StudioFieldLabel("Input Start Channel")
                        Picker("Input start channel", selection: track.inputStartChannel) {
                            ForEach(viewModel.availableInputStartChannels(for: value), id: \.self) { channel in
                                Text("Channel \(channel)").tag(channel)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(viewModel.isRunning || viewModel.availableInputStartChannels(for: value).isEmpty)

                        StudioFieldLabel("Output Start Channel")
                        Picker("Output start channel", selection: track.outputStartChannel) {
                            ForEach(viewModel.availableOutputStartChannels(for: value), id: \.self) { channel in
                                Text("Channel \(channel)").tag(channel)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .disabled(viewModel.isRunning || viewModel.availableOutputStartChannels(for: value).isEmpty)

                        StudioMetricTile("Internal Buffer", value: viewModel.internalBufferDescription(for: value))
                        StudioMetricTile("Mode Notes", value: value.latencyClass.description)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("INSERTS")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .tracking(1.8)
                        .foregroundStyle(StudioTheme.accent)
                    Spacer()
                    Button("Add Plugin") {
                        viewModel.addPluginInsert(to: value.id)
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())
                    .disabled(viewModel.isRunning)
                }

                if value.plugins.isEmpty {
                    Text("No inserts on this track.")
                        .font(.caption)
                        .foregroundStyle(StudioTheme.mutedText)
                } else {
                    ForEach(Array(track.plugins.enumerated()), id: \.element.id) { index, plugin in
                        pluginRow(trackID: value.id, plugin: plugin, index: index, totalCount: value.plugins.count)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.black.opacity(0.16))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            sessionOverviewPanel
            bufferingPanel
            trackToolbarPanel
            tracksPanel
        }
    }

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            transportPanel
            diagnosticsPanel
        }
    }

    private func pluginRow(
        trackID: UUID,
        plugin: Binding<MultiTrackTrackConfiguration.PluginInsert>,
        index: Int,
        totalCount: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(viewModel.pluginInsertLabel(for: plugin.wrappedValue, index: index))
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(StudioTheme.mutedText)

                Spacer()

                Button {
                    viewModel.movePluginInsert(trackID: trackID, pluginID: plugin.wrappedValue.id, direction: -1)
                } label: {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isRunning || index == 0)

                Button {
                    viewModel.movePluginInsert(trackID: trackID, pluginID: plugin.wrappedValue.id, direction: 1)
                } label: {
                    Image(systemName: "arrow.down")
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isRunning || index == totalCount - 1)

                Button("Remove", role: .destructive) {
                    viewModel.removePluginInsert(trackID: trackID, pluginID: plugin.wrappedValue.id)
                }
                .buttonStyle(.borderless)
                .disabled(viewModel.isRunning)
            }

            Picker("Insert \(index + 1)", selection: plugin.pluginID) {
                Text("Bypass").tag(String?.none)
                ForEach(viewModel.plugins) { availablePlugin in
                    Text(availablePlugin.name).tag(Optional(availablePlugin.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(viewModel.isRunning)

            Button("Open Plugin UI") {
                viewModel.openPluginEditor(for: trackID, pluginID: plugin.wrappedValue.id)
            }
            .buttonStyle(StudioSecondaryButtonStyle())
            .disabled(!viewModel.canOpenPluginEditor(for: plugin.wrappedValue))
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private var transportPanel: some View {
        StudioPanel("Transport", subtitle: "Session file actions, engine control, and mode switching.") {
            VStack(alignment: .leading, spacing: 12) {
                if let onBackToModeSelection {
                    Button("Change Mode") {
                        onBackToModeSelection()
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())
                    .disabled(viewModel.isRunning)
                }

                HStack(spacing: 12) {
                    Button("New") {
                        viewModel.createNewSession()
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())
                    .disabled(viewModel.isRunning)

                    Button("Open") {
                        isImportingSession = true
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())
                    .disabled(viewModel.isRunning)
                }

                HStack(spacing: 12) {
                    Button("Save") {
                        do {
                            if viewModel.hasStoredSessionFile {
                                try viewModel.saveSession()
                            } else {
                                sessionDocument = viewModel.sessionDocumentForExport()
                                isExportingSession = true
                            }
                        } catch {
                            viewModel.statusMessage = error.localizedDescription
                        }
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())

                    Button("Save As") {
                        sessionDocument = viewModel.sessionDocumentForExport()
                        isExportingSession = true
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())
                }

                Button("Refresh Devices") {
                    viewModel.load()
                }
                .buttonStyle(StudioSecondaryButtonStyle())
                .disabled(viewModel.isRunning)

                Button(viewModel.isRunning ? "Stop Engine" : "Start Engine") {
                    viewModel.toggleStartStop()
                }
                .buttonStyle(StudioPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!viewModel.canStart && !viewModel.isRunning)

                Button("Reset Counters") {
                    viewModel.resetDropoutCounters()
                }
                .buttonStyle(StudioSecondaryButtonStyle())

                Text(viewModel.statusMessage)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(viewModel.statusMessage.lowercased().contains("error") ? StudioTheme.danger : StudioTheme.mutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var diagnosticsPanel: some View {
        StudioPanel("Diagnostics", subtitle: "Session warnings, validation notes, and live engine telemetry.") {
            VStack(alignment: .leading, spacing: 14) {
                Toggle("Show Diagnostics", isOn: $showsDiagnostics)
                    .toggleStyle(.switch)

                if showsDiagnostics {
                    if !viewModel.sessionWarnings.isEmpty {
                        warningList(viewModel.sessionWarnings)
                    }

                    if !viewModel.latencyBufferValidationMessages.isEmpty {
                        warningList(viewModel.latencyBufferValidationMessages)
                    }

                    if !viewModel.invalidTrackMessages.isEmpty {
                        warningList(viewModel.invalidTrackMessages)
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        StudioMetricTile("Dropouts", value: "\(viewModel.audioDropoutCount)", tint: viewModel.audioDropoutCount > 0 ? StudioTheme.warning : StudioTheme.strongText)
                        StudioMetricTile("Dropped Frames", value: "\(viewModel.droppedFrameCount)")
                        StudioMetricTile("Callbacks", value: trimmedTelemetry(viewModel.telemetrySummary, prefix: "Callbacks in/out: "))
                        StudioMetricTile("Ring", value: trimmedTelemetry(viewModel.ringTelemetrySummary, prefix: "Peak ring occupancy in/out: "))
                        StudioMetricTile("Workers", value: trimmedTelemetry(viewModel.workerTelemetrySummary, prefix: "Workers: "))
                        StudioMetricTile("Engine", value: viewModel.statusMessage)
                    }
                }
            }
        }
    }

    private func latencyField(
        title: String,
        text: Binding<String>,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            StudioFieldLabel(title)
            HStack(spacing: 10) {
                TextField("Frames", text: text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                    .onSubmit {
                        action()
                    }

                Button("Apply") {
                    action()
                }
                .buttonStyle(StudioSecondaryButtonStyle())
                .disabled(viewModel.isBusy || viewModel.isRunning)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func warningList(_ messages: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(messages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(StudioTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func trimmedTelemetry(_ value: String, prefix: String) -> String {
        value.replacingOccurrences(of: prefix, with: "")
    }
}
