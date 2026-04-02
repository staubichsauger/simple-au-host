import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = HostViewModel()
    let onBackToModeSelection: (() -> Void)?

    init(onBackToModeSelection: (() -> Void)? = nil) {
        self.onBackToModeSelection = onBackToModeSelection
    }

    var body: some View {
        StudioShell(
            eyebrow: "Simple Rack",
            title: "Single Insert Host",
            subtitle: "A direct input-to-output path with one plugin slot, hardware buffer control, and live engine telemetry."
        ) {
            HStack(spacing: 8) {
                StudioBadge(
                    title: viewModel.isRunning ? "Running" : "Stopped",
                    systemImage: viewModel.isRunning ? "dot.radiowaves.left.and.right" : "stop.fill",
                    tint: viewModel.isRunning ? .green : .white.opacity(0.78)
                )
                if viewModel.audioDropoutCount > 0 {
                    StudioBadge(
                        title: "\(viewModel.audioDropoutCount) Dropouts",
                        systemImage: "waveform.badge.exclamationmark",
                        tint: StudioTheme.warning
                    )
                }
            }
        } content: {
            GeometryReader { proxy in
                ScrollView {
                    Group {
                        if proxy.size.width >= 1120 {
                            HStack(alignment: .top, spacing: 20) {
                                mainContentColumn
                                sidebarColumn
                                    .frame(width: 330)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 20) {
                                mainContentColumn
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
    }

    private var signalPathPanel: some View {
        StudioPanel("Signal Path", subtitle: "The simple rack keeps a single mono path and one optional insert slot.") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) {
                    pathBlock(title: "Input", value: selectedDeviceName(viewModel.inputDevices, id: viewModel.selectedInputDeviceID), detail: "Ch \(viewModel.selectedInputChannel)")
                    Image(systemName: "arrow.right")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(StudioTheme.accent)
                    pathBlock(title: "Insert", value: selectedPluginName, detail: viewModel.threadedProcessingEnabled ? "Worker Thread" : "Realtime")
                    Image(systemName: "arrow.right")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(StudioTheme.accent)
                    pathBlock(title: "Output", value: selectedDeviceName(viewModel.outputDevices, id: viewModel.selectedOutputDeviceID), detail: "Ch \(viewModel.selectedOutputChannel)")
                }

                VStack(alignment: .leading, spacing: 12) {
                    pathBlock(title: "Input", value: selectedDeviceName(viewModel.inputDevices, id: viewModel.selectedInputDeviceID), detail: "Ch \(viewModel.selectedInputChannel)")
                    pathBlock(title: "Insert", value: selectedPluginName, detail: viewModel.threadedProcessingEnabled ? "Worker Thread" : "Realtime")
                    pathBlock(title: "Output", value: selectedDeviceName(viewModel.outputDevices, id: viewModel.selectedOutputDeviceID), detail: "Ch \(viewModel.selectedOutputChannel)")
                }
            }
        }
    }

    private var inputOutputPanel: some View {
        StudioPanel("Hardware I/O", subtitle: "Choose the interfaces and mono channel endpoints used by the host engine.") {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        fieldLabel("Input Interface")
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

                        fieldLabel("Input Channel")
                        Picker("Input channel", selection: $viewModel.selectedInputChannel) {
                            ForEach(viewModel.availableInputChannels, id: \.self) { channel in
                                Text("Channel \(channel)").tag(channel)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .disabled(viewModel.availableInputChannels.isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: 12) {
                        fieldLabel("Output Interface")
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

                        fieldLabel("Output Channel")
                        Picker("Output channel", selection: $viewModel.selectedOutputChannel) {
                            ForEach(viewModel.availableOutputChannels, id: \.self) { channel in
                                Text("Channel \(channel)").tag(channel)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .disabled(viewModel.availableOutputChannels.isEmpty)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(viewModel.isBusy || viewModel.isRunning)
        }
    }

    private var processingPanel: some View {
        StudioPanel("Processing", subtitle: "Tune hardware and worker-thread buffering for the single insert slot.") {
            VStack(alignment: .leading, spacing: 14) {
                fieldLabel("Hardware Buffer")
                Picker("Buffer size", selection: $viewModel.selectedBufferSize) {
                    ForEach(viewModel.availableBufferSizes, id: \.self) { size in
                        Text("\(size) frames").tag(size)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(viewModel.availableBufferSizes.isEmpty)
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

                Divider()
                    .overlay(Color.white.opacity(0.08))

                fieldLabel("Insert Plugin")
                Picker("Plugin", selection: $viewModel.selectedPluginID) {
                    Text("Bypass").tag(String?.none)
                    ForEach(viewModel.plugins) { plugin in
                        Text(plugin.name).tag(Optional(plugin.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)

                Toggle("Run plugin on worker thread", isOn: $viewModel.threadedProcessingEnabled)
                    .toggleStyle(.switch)

                if viewModel.threadedProcessingEnabled {
                    HStack(spacing: 10) {
                        TextField("Worker buffer frames", text: $viewModel.threadedProcessingBufferSizeText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 180)
                            .onSubmit {
                                viewModel.applyThreadedProcessingBufferSize()
                            }

                        Button("Apply") {
                            viewModel.applyThreadedProcessingBufferSize()
                        }
                        .buttonStyle(StudioSecondaryButtonStyle())
                        .disabled(viewModel.isBusy || viewModel.isRunning)
                    }

                    Text(viewModel.threadedProcessingHelpText)
                        .font(.caption)
                        .foregroundStyle(StudioTheme.mutedText)
                }
            }
            .disabled(viewModel.isBusy || viewModel.isRunning)
        }
    }

    private var transportPanel: some View {
        StudioPanel("Transport", subtitle: "Start and stop the host, refresh devices, and return to the mode switch when idle.") {
            VStack(alignment: .leading, spacing: 12) {
                if let onBackToModeSelection {
                    Button("Change Mode") {
                        onBackToModeSelection()
                    }
                    .buttonStyle(StudioSecondaryButtonStyle())
                    .disabled(viewModel.isRunning)
                }

                Button("Refresh Devices") {
                    viewModel.load()
                }
                .buttonStyle(StudioSecondaryButtonStyle())
                .disabled(viewModel.isBusy || viewModel.isRunning)

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

                if let validationMessage = viewModel.threadedProcessingValidationMessage {
                    Text(validationMessage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(StudioTheme.warning)
                }

                Text(viewModel.statusMessage)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(viewModel.statusColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var diagnosticsPanel: some View {
        StudioPanel("Diagnostics", subtitle: "Dropouts, callback totals, and ring-buffer occupancy for the active session.") {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                StudioMetricTile("Dropouts", value: "\(viewModel.audioDropoutCount)", tint: viewModel.audioDropoutCount > 0 ? StudioTheme.warning : StudioTheme.strongText)
                StudioMetricTile("Dropped Frames", value: "\(viewModel.droppedFrameCount)")
                StudioMetricTile("Callbacks", value: trimmedTelemetry(viewModel.telemetrySummary, prefix: "Callbacks in/out: "))
                StudioMetricTile("Ring Occupancy", value: trimmedTelemetry(viewModel.ringTelemetrySummary, prefix: "Peak ring occupancy in/out: "))
            }
        }
    }

    private func pathBlock(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .medium, design: .default))
                .tracking(1.0)
                .foregroundStyle(StudioTheme.mutedText)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .default))
                .foregroundStyle(StudioTheme.strongText)
            Text(detail)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(StudioTheme.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
        )
    }

    private var mainContentColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            signalPathPanel
            inputOutputPanel
            processingPanel
        }
    }

    private var sidebarColumn: some View {
        VStack(alignment: .leading, spacing: 20) {
            transportPanel
            diagnosticsPanel
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        StudioFieldLabel(title)
    }

    private var selectedPluginName: String {
        viewModel.plugins.first(where: { $0.id == viewModel.selectedPluginID })?.name ?? "Bypass"
    }

    private func selectedDeviceName(_ devices: [AudioDeviceInfo], id: AudioDeviceID?) -> String {
        devices.first(where: { $0.id == id })?.displayName ?? "None"
    }

    private func trimmedTelemetry(_ value: String, prefix: String) -> String {
        value.replacingOccurrences(of: prefix, with: "")
    }
}
