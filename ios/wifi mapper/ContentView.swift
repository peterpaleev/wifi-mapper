import SwiftUI
import Charts

private let signalCyan = Color(red: 0.2, green: 0.86, blue: 0.91)
private let panelColor = Color(red: 0.075, green: 0.095, blue: 0.125)

struct ContentView: View {
    @StateObject private var model = InspectorModel()
    @StateObject private var mapping = MappingModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        TabView {
            SurveyView(mapping: mapping, inspector: model).tabItem { Label("Map", systemImage: "map") }
            SignalView(model: model).tabItem { Label("Signal", systemImage: "waveform.path") }
            NetworksView(model: model).tabItem { Label("Networks", systemImage: "wifi") }
            ControlsView(model: model).tabItem { Label("Controls", systemImage: "slider.horizontal.3") }
            DiagnosticsView(model: model).tabItem { Label("Diagnostics", systemImage: "stethoscope") }
        }
        .tint(signalCyan).preferredColorScheme(.dark)
        .onAppear {
            model.engine.attachMapping(mapping.engine) { Task { @MainActor in if mapping.stopRequested { mapping.completeStop() } } }
        }
        .onChange(of: model.snapshot.selected) { _, id in if !mapping.snapshot.reviewing { mapping.engine.select(id) } }
        .onChange(of: model.snapshot.compatible) { _, ready in if ready && mapping.snapshot.recording { model.engine.capture(true) } }
        .onChange(of: model.snapshot.capturing) { _, active in UIApplication.shared.isIdleTimerDisabled = active || mapping.snapshot.recording }
        .onChange(of: mapping.snapshot.recording) { _, active in UIApplication.shared.isIdleTimerDisabled = active || model.snapshot.capturing }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                mapping.appBackgrounded(inspector: model)
                if model.snapshot.capturing { model.engine.capture(false) }
            }
        }
        .alert("Sensor message", isPresented: Binding(get: { model.snapshot.error != nil }, set: { if !$0 { model.engine.clearError() } })) {
            Button("OK") { model.engine.clearError() }
        } message: { Text(model.snapshot.error ?? "") }
    }
}
private struct ConnectionBadge: View {
    let state: InspectorSnapshot
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(state.compatible ? signalCyan : .orange).frame(width: 7, height: 7)
            Text(state.connection).font(.caption.monospaced())
            Spacer()
            if state.capturing { Text("LIVE").font(.caption2.bold()).foregroundStyle(signalCyan) }
        }.foregroundStyle(.secondary)
    }
}
private struct Panel<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title.uppercased()).font(.caption2.bold()).tracking(1.5).foregroundStyle(.secondary)
            content
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(panelColor, in: RoundedRectangle(cornerRadius: 18))
    }
}
private struct SignalView: View {
    @ObservedObject var model: InspectorModel
    @State private var selectedTime: Double?
    private var s: InspectorSnapshot { model.snapshot }
    private var selected: APRow? { s.aps.first { $0.id == s.selected } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    ConnectionBadge(state: s)
                    if s.aps.isEmpty {
                        ContentUnavailableView("Inspect a Wi-Fi signal", systemImage: "waveform.path", description: Text("Connect the ESP32’s native USB port to iPhone, then connect and start capture in Controls. Networks appear as beacons arrive."))
                        Text("2.4 GHz · packet RSSI · USB Ethernet").font(.caption.monospaced()).foregroundStyle(.secondary)
                    } else {
                        Panel(title: "Selected access point") {
                            Picker("Network", selection: Binding(get: { s.selected ?? s.aps.first!.id }, set: { model.engine.select($0); model.frozen = false })) {
                                ForEach(s.aps) { row in Text("\(row.ap.title) · \(row.ap.bssid.suffix(8))").tag(row.id) }
                            }.pickerStyle(.menu).labelsHidden().accessibilityIdentifier("networkPicker")
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(selected?.latest.map { String($0.rssi) } ?? "—").font(.system(size: 66, weight: .light, design: .rounded)).monospacedDigit().foregroundStyle(signalCyan)
                                Text("dBm").foregroundStyle(.secondary)
                                Spacer()
                                VStack(alignment: .trailing, spacing: 5) {
                                    Text("CH \(selected?.latest?.channel ?? selected?.ap.channel ?? 0)").font(.headline.monospaced())
                                    Text(String(format: "%.1f samples/s", s.selectedPerSecond)).font(.caption.monospaced()).foregroundStyle(.secondary)
                                }
                            }
                            HStack { Text(selected?.ap.bssid ?? ""); Spacer(); Text(ageLabel(selected?.age)) }.font(.caption.monospaced()).foregroundStyle((selected?.age ?? 100) > 3 ? .orange : .secondary)
                        }
                        Panel(title: "Signal history · last 60 seconds") {
                            let points = model.visibleSamples
                            let latest = max(points.last?.seconds ?? 60, model.frozen || !s.capturing ? 0 : s.uptime)
                            Chart(points) { point in
                                LineMark(x: .value("ESP time", point.seconds), y: .value("RSSI", point.rssi)).foregroundStyle(signalCyan).lineStyle(StrokeStyle(lineWidth: 1.4))
                            }
                            .chartXScale(domain: max(0,latest-60)...max(1,latest))
                            .chartYScale(domain: -100 ... -20)
                            .chartYAxis { AxisMarks(position: .leading, values: [-100,-80,-60,-40,-20]) }
                            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { value in AxisGridLine(); AxisValueLabel { if let seconds = value.as(Double.self) { Text("\(Int(seconds-latest))s") } } } }
                            .chartXSelection(value: $selectedTime)
                            .frame(height: 180)
                            if let time = selectedTime, let nearest = points.min(by: { abs($0.seconds-time) < abs($1.seconds-time) }) {
                                Text(String(format: "Cursor  %.3f s  ·  %d dBm  ·  CH %d", nearest.seconds, nearest.rssi, nearest.channel)).font(.caption.monospaced()).foregroundStyle(signalCyan)
                            }
                            HStack {
                                Button { model.toggleFreeze() } label: { Label(model.frozen ? "Resume plot" : "Freeze plot", systemImage: model.frozen ? "play.fill" : "pause.fill") }.buttonStyle(.bordered)
                                Spacer()
                                Text("\(points.count) samples").font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }
                        Panel(title: "RSSI density · time × signal level") {
                            HStack(spacing: 8) {
                                VStack { Text("−20"); Spacer(); Text("−60"); Spacer(); Text("−100") }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                DensityWaterfall(samples: model.visibleSamples, latest: model.frozen || !s.capturing ? (model.visibleSamples.last?.seconds ?? 60) : max(s.uptime, s.latest?.seconds ?? 60))
                            }.frame(height: 170)
                            HStack { Text("−60s"); Spacer(); Text("dBm ↑ · brighter = more packets"); Spacer(); Text("Now") }.font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            Text("Packet signal-strength distribution, not a frequency spectrum. Empty cells mean no observed packets.").font(.caption2).foregroundStyle(.secondary)
                        }
                        StatisticsPanel(samples: model.visibleSamples)
                    }
                }.padding()
            }.background(Color.black).navigationTitle("Signal inspector")
        }
    }
    private func ageLabel(_ age: Double?) -> String {
        guard let age else { return "No samples" }
        return age < 1 ? "Just received" : String(format: "%.1fs since RX", age)
    }
}
private struct DensityWaterfall: View {
    let samples: [SignalSample]
    let latest: Double
    var body: some View {
        Canvas { context, size in
            let cols = 60, rows = 40
            var bins = [Int](repeating: 0, count: cols*rows)
            let end = max(60,latest), start = end-60
            for s in samples {
                let column = Int(floor(s.seconds-start)), row = (s.rssi+100)/2
                if (0..<cols).contains(column), (0..<rows).contains(row) { bins[column*rows+row] += 1 }
            }
            let maximum = max(1,bins.max() ?? 1)
            for column in 0..<cols {
                for row in 0..<rows {
                    let count = bins[column*rows+row]
                    let rect = CGRect(x: CGFloat(column)*size.width/60, y: CGFloat(rows-1-row)*size.height/40, width: size.width/60+0.2, height: size.height/40+0.2)
                    let level = log1p(Double(count))/log1p(Double(maximum))
                    let color = count == 0 ? Color.white.opacity(0.025) : Color(hue: 0.58-level*0.42, saturation: 0.9, brightness: 0.3+level*0.7)
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }.accessibilityLabel("RSSI density chart for the selected network, last sixty seconds")
    }
}
private struct StatisticsPanel: View {
    let samples: [SignalSample]
    var body: some View {
        let stats = SignalStatistics(samples)
        Panel(title: "Window statistics · observed samples") {
            HStack {
                metric("Mean", stats.mean.map { String(format:"%.1f",$0) } ?? "—", "dBm")
                Spacer(); metric("Min / Max", stats.minimum.map { "\($0) / \(stats.maximum!)" } ?? "—", "dBm")
                Spacer(); metric("Deviation", stats.deviation.map { String(format:"%.1f",$0) } ?? "—", "dB")
            }
        }
    }
    private func metric(_ title: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.caption).foregroundStyle(.secondary); Text(value).font(.headline.monospaced()); Text(unit).font(.caption2).foregroundStyle(.secondary) }
    }
}
private struct NetworksView: View {
    @ObservedObject var model: InspectorModel
    @State private var query = ""
    @State private var order = "Strength"
    var rows: [APRow] {
        let rows = model.snapshot.aps.filter { query.isEmpty || $0.ap.title.localizedCaseInsensitiveContains(query) || $0.ap.bssid.localizedCaseInsensitiveContains(query) }
        switch order {
        case "Name": return rows.sorted { $0.ap.title.localizedStandardCompare($1.ap.title) == .orderedAscending }
        case "Channel": return rows.sorted { $0.ap.channel < $1.ap.channel }
        default: return rows
        }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ConnectionBadge(state: model.snapshot)
                    Picker("Sort", selection: $order) { ForEach(["Strength","Name","Channel"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                }
                Section("\(rows.count) access points · select to inspect") {
                    ForEach(rows) { row in
                        Button { model.engine.select(row.id); model.frozen = false } label: {
                            HStack(spacing: 12) {
                                Image(systemName: row.id == model.snapshot.selected ? "checkmark.circle.fill" : "wifi").foregroundStyle(row.id == model.snapshot.selected ? signalCyan : .secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(row.ap.title).font(.headline).foregroundStyle(.primary)
                                    Text(row.ap.bssid).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    Text("CH \(row.ap.channel) · \(row.count) samples · \(row.ap.secured ? "Protected" : "Open")").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                VStack(alignment: .trailing) { Text(row.latest.map { "\($0.rssi)" } ?? "—").font(.title3.monospaced()); Text("dBm").font(.caption2); if (row.age ?? 0) > 3 { Text("stale").font(.caption2).foregroundStyle(.orange) } }.foregroundStyle(signalCyan)
                            }.padding(.vertical, 4)
                        }
                    }
                }
                Section { Text("Each BSSID is a separate radio. The ESP32-S3 observes 2.4 GHz only; 5/6 GHz networks will not appear.").font(.caption).foregroundStyle(.secondary) }
            }.searchable(text: $query, prompt: "SSID or BSSID").navigationTitle("Networks")
        }
    }
}
private struct ControlsView: View {
    @ObservedObject var model: InspectorModel
    @State private var dwell = 80
    @State private var channel = 0
    @State private var showClear = false
    var body: some View {
        NavigationStack {
            Form {
                Section("USB sensor") {
                    ConnectionBadge(state: model.snapshot)
                    TextField("Sensor IP address", text: $model.host).keyboardType(.decimalPad).autocorrectionDisabled().textInputAutocapitalization(.never)
                    HStack {
                        Button("Connect USB") { model.engine.connect(host: model.host) }.disabled(model.snapshot.connected).accessibilityIdentifier("connectUSB")
                        Spacer()
                        Button("Disconnect") { model.engine.disconnect() }.disabled(!model.snapshot.connected || model.snapshot.capturing || model.snapshot.stopping)
                    }
                    Text("Use a USB-C data cable and the ESP32 native USB port. iPhone should show Ethernet in Settings. Allow Local Network access when asked. Keep the app open during capture.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Capture") {
                    Button { model.engine.capture(!model.snapshot.capturing) } label: {
                        Label(model.snapshot.stopping ? "Draining buffer…" : model.snapshot.capturing ? "Stop capture" : "Start capture", systemImage: model.snapshot.capturing ? "stop.fill" : "play.fill")
                    }.disabled(!model.snapshot.compatible || model.snapshot.stopping).accessibilityIdentifier("captureButton")
                    Text("Sweep first to discover networks. Lock to the selected network’s channel for denser, more consistent signal sampling.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Radio controls") {
                    Picker("Channel", selection: $channel) { Text("Sweep 1–11").tag(0); ForEach(1...11,id: \.self) { Text("Channel \($0)").tag($0) } }
                    Picker("Dwell per channel", selection: $dwell) { ForEach([40,80,150,300,1000],id: \.self) { Text("\($0) ms").tag($0) } }
                    Button("Apply radio settings") { model.engine.configure(dwell: dwell, channel: channel == 0 ? nil : channel) }.disabled(!model.snapshot.compatible)
                    Button("Lock to selected network") {
                        if let ap = model.snapshot.aps.first(where: { $0.id == model.snapshot.selected }), (1...11).contains(ap.ap.channel) { channel = ap.ap.channel; model.engine.configure(dwell: dwell, channel: channel) }
                    }.disabled(model.snapshot.selected == nil || !model.snapshot.compatible)
                    Text("Applied: \(model.snapshot.channelCount == 1 ? "channel \(model.snapshot.firstChannel)" : "sweep 1–11") · \(model.snapshot.dwellMs) ms").font(.caption.monospaced()).foregroundStyle(signalCyan)
                }
                Section("Raw measurements") {
                    Toggle("Record all APs to CSV", isOn: Binding(get: { model.snapshot.logging }, set: { model.engine.setLogging($0) })).disabled(!model.snapshot.capturing && !model.snapshot.logging)
                    if model.snapshot.logging { Text("\(model.snapshot.logRows) rows saved").font(.caption.monospaced()) }
                    if let url = model.snapshot.exportURL { ShareLink(item: url) { Label("Export raw CSV", systemImage: "square.and.arrow.up") } }
                    Button("Clear display history", role: .destructive) { showClear = true }
                    Text("CSV preserves individual observations from every AP. Display history is bounded; export captures measurements from the moment recording is enabled.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("Controls")
                .confirmationDialog("Clear live charts and local sample counts?", isPresented: $showClear) { Button("Clear history", role: .destructive) { model.engine.clear(); model.frozen = false } }
        }
    }
}
private struct DiagnosticsView: View {
    @ObservedObject var model: InspectorModel
    private var s: InspectorSnapshot { model.snapshot }
    var body: some View {
        NavigationStack {
            List {
                Section("Device") {
                    Text(s.device).font(.caption.monospaced())
                    row("Firmware / protocol", "\(s.firmware) / v1")
                    row("Boot ID", String(format: "%08X", s.bootID))
                    row("Flash / PSRAM", "\(s.flashMB) / \(s.psramMB) MB")
                    row("Uptime", String(format: "%.1f s", s.uptime))
                    row("Current channel", "\(s.activeChannel)")
                }
                Section("Capture health · counters since boot") {
                    row("Frames received", "\(s.counters[0])")
                    row("Observations accepted", "\(s.counters[1])")
                    row("Accepted rate", String(format: "%.1f / s", s.framesPerSecond))
                    row("Filtered / malformed", "\(s.counters[2])")
                    row("RX queue drops", "\(s.counters[3])", warning: s.counters[3] > 0)
                    row("Observation buffer drops", "\(s.counters[4])", warning: s.counters[4] > 0)
                    row("Buffered / capacity", "\(s.counters[5]) / \(s.counters[6])")
                    ProgressView(value: Double(s.counters[5]), total: Double(max(1,s.counters[6])))
                    row("Buffer high-water", "\(s.counters[7])")
                    Text("Zero software drops does not prove zero over-air loss. Channel hopping and the shared Wi-Fi/BLE radio limit observation coverage.").font(.caption).foregroundStyle(.secondary)
                }
                Section("USB transport") {
                    Text(s.pathDetails).font(.caption.monospaced()).textSelection(.enabled)
                    ForEach(s.interfaceAddresses, id: \.self) { address in Text(address).font(.caption.monospaced()).textSelection(.enabled) }
                    if let url = s.diagnosticsURL { ShareLink(item: url) { Label("Export diagnostics", systemImage: "square.and.arrow.up") } }
                    row("Phone bytes received", "\(s.receivedBytes)")
                    row("Receive throughput", String(format: "%.1f kB/s", s.bytesPerSecond/1000))
                    row("Sensor bytes sent", "\(s.counters[8])")
                    row("Reconnect attempts", "\(s.reconnects)")
                    row("Duplicate batches recovered", "\(s.duplicates)")
                    row("Decode errors", "\(s.decodeErrors)", warning: s.decodeErrors > 0)
                    row("Last packet", s.lastPacketAge.map { String(format: "%.1f s ago",$0) } ?? "—", warning: (s.lastPacketAge ?? 0) > 3)
                    row("Best sync RTT", s.syncRTT.map { String(format:"%.2f ms",$0) } ?? "—")
                    row("ESP − phone clock", s.syncOffset.map { String(format:"%.2f ms",$0) } ?? "—")
                    Button("Measure clock sync") { model.engine.sync() }.disabled(!s.compatible)
                }
                if let latest = s.latest {
                    Section("Selected AP · latest packet") {
                        row("Source timestamp", "\(latest.espUs) µs")
                        row("RX radio timestamp", "\(latest.radioUs) µs")
                        row("Type", latest.subtype == 8 ? "Beacon" : "Probe response")
                        row("PHY / MCS", "\(latest.phy) / \(latest.mcs)")
                        row("Frame length", "\(latest.frameLength) bytes")
                        row("Secondary channel code", "\(latest.secondary)")
                    }
                }
                Section("Measured dwell by channel · seconds") {
                    Chart(Array(s.channelDwell.enumerated()), id: \.offset) { item in BarMark(x: .value("Channel", "\(item.offset+1)"), y: .value("Seconds", item.element)).foregroundStyle(signalCyan) }.frame(height: 140)
                }
                Section("Event log") {
                    if s.events.isEmpty { Text("No events yet").foregroundStyle(.secondary) }
                    ForEach(Array(s.events.enumerated()), id: \.offset) { item in Text(item.element).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }.navigationTitle("Diagnostics")
        }
    }
    private func row(_ title: String, _ value: String, warning: Bool = false) -> some View {
        LabeledContent(title) { Text(value).font(.caption.monospaced()).foregroundStyle(warning ? .orange : .secondary).textSelection(.enabled) }
    }
}
