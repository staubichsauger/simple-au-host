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
        VStack(alignment: .leading, spacing: 16) {
            Form {
                Section("Global I/O") {
                    Picker("Input interface", selection: $viewModel.selectedInputDeviceID) {
                        ForEach(viewModel.inputDevices) { device in
                            Text(device.displayName).tag(Optional(device.id))
                        }
                    }
                    .onChange(of: viewModel.selectedInputDeviceID) { _, _ in
                        viewModel.handleDeviceSelectionChange()
                    }

                    Picker("Output interface", selection: $viewModel.selectedOutputDeviceID) {
                        ForEach(viewModel.outputDevices) { device in
                            Text(device.displayName).tag(Optional(device.id))
                        }
                    }
                    .onChange(of: viewModel.selectedOutputDeviceID) { _, _ in
                        viewModel.handleDeviceSelectionChange()
                    }

                    Picker("Hardware buffer size", selection: $viewModel.selectedBufferSize) {
                        ForEach(viewModel.availableBufferSizes, id: \.self) { size in
                            Text("\(size) frames").tag(size)
                        }
                    }
                    .onChange(of: viewModel.selectedBufferSize) { _, newValue in
                        viewModel.customBufferSizeText = String(newValue)
                    }

                    HStack {
                        Text("Custom buffer")
                        TextField("Frames", text: $viewModel.customBufferSizeText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 140)
                            .onSubmit {
                                viewModel.applyCustomBufferSize()
                            }

                        Button("Apply") {
                            viewModel.applyCustomBufferSize()
                        }
                        .disabled(viewModel.isBusy || viewModel.isRunning)
                    }

                    Text(viewModel.bufferSizeHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Latency class internal buffering") {
                    HStack {
                        Text("Realtime")
                        Spacer()
                        Text("\(viewModel.selectedBufferSize) frames")
                            .foregroundStyle(.secondary)
                    }

                    Text("Realtime tracks run directly on the hardware callback cadence, so their internal buffer follows the hardware buffer size.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Text("Buffered")
                        TextField("Frames", text: $viewModel.bufferedInternalBufferText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 140)
                            .onSubmit {
                                viewModel.applyBufferedInternalBufferSize()
                            }
                        Button("Apply") {
                            viewModel.applyBufferedInternalBufferSize()
                        }
                        .disabled(viewModel.isBusy || viewModel.isRunning)
                    }

                    HStack {
                        Text("Broadcast/Post")
                        TextField("Frames", text: $viewModel.broadcastInternalBufferText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 140)
                            .onSubmit {
                                viewModel.applyBroadcastInternalBufferSize()
                            }
                        Button("Apply") {
                            viewModel.applyBroadcastInternalBufferSize()
                        }
                        .disabled(viewModel.isBusy || viewModel.isRunning)
                    }

                    Text("Buffered and Broadcast/Post internal buffers must be whole multiples of the hardware buffer size and at least as large.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        Button("Add mono track") {
                            viewModel.addMonoTrack()
                        }
                        .disabled(viewModel.isRunning)

                        Button("Add stereo track") {
                            viewModel.addStereoTrack()
                        }
                        .disabled(viewModel.isRunning)
                    }
                } header: {
                    Text("Tracks")
                }

                ForEach($viewModel.tracks) { $track in
                    Section(track.name.isEmpty ? "Track" : track.name) {
                        TextField("Track name", text: $track.name)
                            .disabled(viewModel.isRunning)

                        Toggle("Enabled", isOn: $track.isEnabled)
                            .disabled(viewModel.isRunning)

                        Picker("Layout", selection: $track.layout) {
                            ForEach(TrackChannelLayout.allCases) { layout in
                                Text(layout.title).tag(layout)
                            }
                        }
                        .disabled(viewModel.isRunning)
                        .onChange(of: track.layout) { _, _ in
                            viewModel.sanitizeTrack(id: track.id)
                        }

                        Picker("Latency class", selection: $track.latencyClass) {
                            ForEach(TrackLatencyClass.allCases) { latencyClass in
                                Text(latencyClass.title).tag(latencyClass)
                            }
                        }
                        .disabled(viewModel.isRunning)

                        Picker("Input start channel", selection: $track.inputStartChannel) {
                            ForEach(viewModel.availableInputStartChannels(for: track), id: \.self) { channel in
                                Text("Channel \(channel)").tag(channel)
                            }
                        }
                        .disabled(viewModel.isRunning || viewModel.availableInputStartChannels(for: track).isEmpty)

                        Picker("Output start channel", selection: $track.outputStartChannel) {
                            ForEach(viewModel.availableOutputStartChannels(for: track), id: \.self) { channel in
                                Text("Channel \(channel)").tag(channel)
                            }
                        }
                        .disabled(viewModel.isRunning || viewModel.availableOutputStartChannels(for: track).isEmpty)

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Plugin chain")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Button("Add plugin") {
                                    viewModel.addPluginInsert(to: track.id)
                                }
                                .disabled(viewModel.isRunning)
                            }

                            if track.plugins.isEmpty {
                                Text("No inserts on this track.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(Array($track.plugins.enumerated()), id: \.element.id) { index, $plugin in
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text(viewModel.pluginInsertLabel(for: plugin, index: index))
                                                .font(.caption.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                            Button {
                                                viewModel.movePluginInsert(trackID: track.id, pluginID: plugin.id, direction: -1)
                                            } label: {
                                                Image(systemName: "arrow.up")
                                            }
                                            .buttonStyle(.borderless)
                                            .disabled(viewModel.isRunning || index == 0)

                                            Button {
                                                viewModel.movePluginInsert(trackID: track.id, pluginID: plugin.id, direction: 1)
                                            } label: {
                                                Image(systemName: "arrow.down")
                                            }
                                            .buttonStyle(.borderless)
                                            .disabled(viewModel.isRunning || index == track.plugins.count - 1)

                                            Button("Remove", role: .destructive) {
                                                viewModel.removePluginInsert(trackID: track.id, pluginID: plugin.id)
                                            }
                                            .buttonStyle(.borderless)
                                            .disabled(viewModel.isRunning)
                                        }

                                        Picker("Insert \(index + 1)", selection: $plugin.pluginID) {
                                            Text("Bypass").tag(String?.none)
                                            ForEach(viewModel.plugins) { availablePlugin in
                                                Text(availablePlugin.name).tag(Optional(availablePlugin.id))
                                            }
                                        }
                                        .labelsHidden()
                                        .disabled(viewModel.isRunning)

                                        Button("Open plugin UI") {
                                            viewModel.openPluginEditor(for: track.id, pluginID: plugin.id)
                                        }
                                        .disabled(!viewModel.canOpenPluginEditor(for: plugin))
                                    }
                                    .padding(.vertical, 4)
                                }
                            }
                        }

                        Text(track.latencyClass.description)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(viewModel.internalBufferDescription(for: track))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        HStack {
                            Spacer()
                            Button("Remove track", role: .destructive) {
                                viewModel.removeTrack(id: track.id)
                            }
                            .disabled(viewModel.isRunning)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(viewModel.isBusy)

            GroupBox {
                DisclosureGroup("Diagnostics", isExpanded: $showsDiagnostics) {
                    VStack(alignment: .leading, spacing: 12) {
                        if !viewModel.sessionWarnings.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(viewModel.sessionWarnings, id: \.self) { warning in
                                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }

                        if !viewModel.latencyBufferValidationMessages.isEmpty || !viewModel.invalidTrackMessages.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(viewModel.latencyBufferValidationMessages, id: \.self) { message in
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                ForEach(viewModel.invalidTrackMessages, id: \.self) { message in
                                    Text(message)
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }

                        LazyVGrid(
                            columns: [
                                GridItem(.adaptive(minimum: 180), alignment: .leading),
                                GridItem(.adaptive(minimum: 180), alignment: .leading)
                            ],
                            alignment: .leading,
                            spacing: 10
                        ) {
                            diagnosticsMetric("Audio dropouts", value: "\(viewModel.audioDropoutCount)")
                            diagnosticsMetric("Dropped frames", value: "\(viewModel.droppedFrameCount)")
                            diagnosticsMetric("Callback frames", value: viewModel.telemetrySummary.replacingOccurrences(of: "Callbacks in/out: ", with: ""))
                            diagnosticsMetric("Ring occupancy", value: viewModel.ringTelemetrySummary.replacingOccurrences(of: "Peak ring occupancy in/out: ", with: ""))
                            diagnosticsMetric("Worker telemetry", value: viewModel.workerTelemetrySummary.replacingOccurrences(of: "Workers: ", with: ""))
                            diagnosticsMetric("Engine status", value: viewModel.statusMessage)
                        }
                        .padding(.top, 2)
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline.weight(.semibold))
            }

            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        statusChip(
                            viewModel.currentSessionName,
                            systemImage: "doc.text",
                            tint: .secondary
                        )
                        statusChip(
                            viewModel.isRunning ? "Running" : "Stopped",
                            systemImage: viewModel.isRunning ? "dot.radiowaves.left.and.right" : "stop.fill",
                            tint: viewModel.isRunning ? .green : .secondary
                        )
                        if !viewModel.sessionWarnings.isEmpty {
                            statusChip(
                                "\(viewModel.sessionWarnings.count) warning\(viewModel.sessionWarnings.count == 1 ? "" : "s")",
                                systemImage: "exclamationmark.triangle.fill",
                                tint: .orange
                            )
                        }
                        if viewModel.audioDropoutCount > 0 {
                            statusChip(
                                "\(viewModel.audioDropoutCount) dropouts",
                                systemImage: "waveform.badge.exclamationmark",
                                tint: .orange
                            )
                        }
                        Text(viewModel.statusMessage)
                            .font(.caption)
                            .foregroundStyle(viewModel.statusMessage.lowercased().contains("error") ? .red : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    HStack(spacing: 8) {
                        statusChip(
                            viewModel.isRunning ? "Running" : "Stopped",
                            systemImage: viewModel.isRunning ? "dot.radiowaves.left.and.right" : "stop.fill",
                            tint: viewModel.isRunning ? .green : .secondary
                        )
                        if !viewModel.sessionWarnings.isEmpty {
                            statusChip(
                                "\(viewModel.sessionWarnings.count)",
                                systemImage: "exclamationmark.triangle.fill",
                                tint: .orange
                            )
                        }
                        if viewModel.audioDropoutCount > 0 {
                            statusChip(
                                "\(viewModel.audioDropoutCount)",
                                systemImage: "waveform.badge.exclamationmark",
                                tint: .orange
                            )
                        }
                        Text(viewModel.statusMessage)
                            .font(.caption)
                            .foregroundStyle(viewModel.statusMessage.lowercased().contains("error") ? .red : .secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                HStack(spacing: 12) {
                    if let onBackToModeSelection {
                        Button("Change mode") {
                            onBackToModeSelection()
                        }
                        .disabled(viewModel.isRunning)
                    }

                    Button("New") {
                        viewModel.createNewSession()
                    }
                    .disabled(viewModel.isRunning)

                    Button("Open") {
                        isImportingSession = true
                    }
                    .disabled(viewModel.isRunning)

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

                    Button("Save As") {
                        sessionDocument = viewModel.sessionDocumentForExport()
                        isExportingSession = true
                    }

                    Button("Refresh") {
                        viewModel.load()
                    }
                    .disabled(viewModel.isRunning)

                    Button(viewModel.isRunning ? "Stop" : "Start") {
                        viewModel.toggleStartStop()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!viewModel.canStart && !viewModel.isRunning)

                    Button("Reset counters") {
                        viewModel.resetDropoutCounters()
                    }
                }
            }
        }
        .padding(20)
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

    @ViewBuilder
    private func diagnosticsMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func statusChip(_ title: String, systemImage: String, tint: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
            .fixedSize(horizontal: true, vertical: false)
    }
}
