import Foundation
import Network
import Combine
import Darwin

struct APRow: Identifiable {
    let ap: AccessPoint
    let latest: SignalSample?
    let count: Int
    let age: Double?
    var id: UInt16 { ap.id }
}
struct InspectorSnapshot {
    var connection = "Disconnected"
    var interfaceAddresses: [String] = []
    var pathDetails = "No connection path"
    var connected = false
    var compatible = false
    var capturing = false
    var stopping = false
    var aps: [APRow] = []
    var selected: UInt16?
    var samples: [SignalSample] = []
    var latest: SignalSample?
    var device = "ESP32-S3 · USB Ethernet"
    var bootID: UInt32 = 0
    var flashMB = 0
    var psramMB = 0
    var firmware = "—"
    var uptime = 0.0
    var counters: [UInt32] = Array(repeating: 0, count: 10)
    var channelDwell: [Double] = Array(repeating: 0, count: 11)
    var activeChannel = 0
    var dwellMs = 80
    var firstChannel = 1
    var channelCount = 11
    var receivedBytes = 0
    var bytesPerSecond = 0.0
    var framesPerSecond = 0.0
    var selectedPerSecond = 0.0
    var duplicates = 0
    var decodeErrors = 0
    var reconnects = 0
    var syncRTT: Double?
    var syncOffset: Double?
    var lastPacketAge: Double?
    var events: [String] = []
    var diagnosticsURL: URL?
    var exportURL: URL?
    var logging = false
    var logRows = 0
    var error: String?
}
/// All mutable capture/network state belongs to this queue. Only snapshots cross to UI.
final class InspectorEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "wifi.mapper.inspector", qos: .userInitiated)
    private var connection: NWConnection?
    private var generation = 0
    private var wanted = false
    private var host = "192.168.7.1"
    private var decoder = WireDecoder()
    private var state = InspectorSnapshot()
    private var aps: [UInt16: AccessPoint] = [:]
    private var history: [UInt16: [SignalSample]] = [:]
    private var counts: [UInt16: Int] = [:]
    private var lastReceive: [UInt16: Double] = [:]
    private var seen = Set<UInt32>()
    private var seenOrder: [UInt32] = []
    private var clock = ClockModel()
    private var timer: DispatchSourceTimer?
    private var previousTick = ProcessInfo.processInfo.systemUptime
    private var statusReceivedAt: Double?
    private var previousBytes = 0
    private var previousAccepted: UInt32 = 0
    private var lastPacket: Double?
    private var lastSync = 0.0
    private var pendingSync = Set<UInt64>()
    private var log: FileHandle?
    private var logURL: URL?
    private var desiredCapture = false
    private var lastEventMessage = ""
    private var lastEventAt = 0.0
    private var spatialSink: ((SpatialBatch) -> Bool)?
    private var stoppedSink: (() -> Void)?
    func attachMapping(_ engine: MappingEngine, stopped: @escaping () -> Void) {
        queue.async { self.spatialSink = { engine.ingest($0) }; self.stoppedSink = stopped }
    }
    var onSnapshot: (@Sendable (InspectorSnapshot) -> Void)?
    init() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(200))
        timer.setEventHandler { [weak self] in self?.publish() }; timer.resume(); self.timer = timer
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-fixture") {
            queue.async { self.loadUITestFixture() }
        }
        #endif
    }
    #if DEBUG
    private func loadUITestFixture() {
        state.connection = "SIMULATED TEST DATA"; state.firmware = "0.1.0"; state.bootID = 123
        state.flashMB = 8; state.psramMB = 8; state.uptime = 60; state.counters = [12000,800,11000,0,0,0,32768,32,48000,1]
        for apID: UInt16 in [1,2] {
            aps[apID] = AccessPoint(id: apID, bssid: apID == 1 ? "02:00:00:00:00:01" : "02:00:00:00:00:02", ssid: apID == 1 ? "Demo Lab" : "Demo Office", channel: apID == 1 ? 6 : 11, capability: 17, beaconInterval: 100)
            var generated: [SignalSample] = []
            for i in 0..<600 {
                let timestamp = UInt64(i) * 100_000
                let level = -55 + Int(8 * sin(Double(i) * 0.025)) + (i % 5) - 2 - Int(apID) * 3
                let identifier = UInt64(apID) * 1000 + UInt64(i)
                let sample = SignalSample(id: identifier, espUs: timestamp, apID: apID,
                    rssi: level, channel: apID == 1 ? 6 : 11, secondary: 0, subtype: 8,
                    phy: 1, mcs: 0, frameLength: 120, radioUs: UInt32(timestamp))
                generated.append(sample)
            }
            history[apID] = generated
            counts[apID] = 600; lastReceive[apID] = ProcessInfo.processInfo.systemUptime
        }
        state.selected = 1; state.channelDwell = Array(repeating: 5.0, count: 11)
        event("SIMULATED TEST DATA — visual testing only")
    }
    #endif
    func connect(host: String) { queue.async { self.host = host.trimmingCharacters(in: .whitespacesAndNewlines); self.wanted = true; self.establish() } }
    func disconnect() { queue.async { self.wanted = false; self.generation += 1; self.connection?.cancel(); self.connection = nil; self.state.connected = false; self.state.compatible = false; self.state.connection = "Disconnected"; self.finishLog(); self.publish() } }
    func select(_ id: UInt16) { queue.async { self.state.selected = id } }
    func capture(_ enabled: Bool) { queue.async {
        guard self.state.compatible else { return }
        self.desiredCapture = enabled
        if enabled { self.state.stopping = false; self.send(15); self.event("Capture started") }
        else { self.state.stopping = true; self.send(4); self.event("Stopping · draining queued measurements") }
    } }
    func configure(dwell: Int, channel: Int?) { queue.async {
        var data = Data(); data.put(UInt16(clamping: dwell)); data.append(UInt8(clamping: channel ?? 1)); data.append(channel == nil ? 11 : 1)
        self.send(5, data); self.event(channel.map { "Lock requested: channel \($0)" } ?? "Sweep requested: channels 1–11")
    } }
    func clear() { queue.async { self.history.removeAll(); self.counts.removeAll(); self.lastReceive.removeAll(); self.event("Display history cleared; firmware counters unchanged") } }
    func sync() { queue.async { self.sendSync() } }
    func clearError() { queue.async { self.state.error = nil } }
    func setLogging(_ enabled: Bool) { queue.async {
        if !enabled { self.finishLog(); return }
        do {
            let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Captures")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent("WiFi-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).csv")
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            self.log = try FileHandle(forWritingTo: url); self.logURL = url
            try self.log?.write(contentsOf: Data("boot_id,batch_sequence,index,esp_timestamp_us,phone_receive_uptime_s,ap_id,bssid,ssid,rssi_dbm,rx_channel,secondary,subtype,phy,mcs,frame_length,radio_timestamp_us\n".utf8))
            self.state.logging = true; self.state.logRows = 0; self.state.exportURL = nil; self.event("Raw CSV recording started · all APs")
        } catch { self.fail("Cannot create CSV: \(error.localizedDescription)") }
    } }
    private func establish() {
        generation += 1; let current = generation
        connection?.cancel(); decoder.reset(); state.connected = false; state.compatible = false
        state.connection = "Connecting over USB…"; pendingSync.removeAll(); clock = ClockModel()
        let parameters = NWParameters.tcp
        // Let iOS resolve the on-link route. Requiring a path class up front can
        // exclude USB interfaces while the system is configuring them.
        parameters.prohibitedInterfaceTypes = [.cellular]
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 45832, using: parameters)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self, weak connection] status in
            guard let self, current == self.generation else { return }
            switch status {
            case .ready:
                self.state.connected = true; self.state.connection = "USB connected · checking sensor"
                self.event("USB TCP connected to \(self.host):45832"); self.send(1); self.receive(connection, generation: current)
            case .waiting(let error): self.state.connection = "Waiting for sensor network"
                if let path = connection?.currentPath, path.unsatisfiedReason == .localNetworkDenied {
                    self.state.connection = "Local Network permission denied"
                }
                self.event("USB waiting: \(error.localizedDescription)")
            case .failed(let error): self.lost(error.localizedDescription, generation: current)
            case .cancelled: break
            default: break
            }
        }
        connection.start(queue: queue)
    }
    private func lost(_ reason: String, generation current: Int) {
        guard current == generation else { return }; generation += 1; let retryGeneration = generation
        connection?.cancel(); connection = nil; state.connected = false; state.compatible = false
        state.connection = wanted ? "USB disconnected · reconnecting" : "Disconnected"; event(reason)
        guard wanted else { return }; state.reconnects += 1
        queue.asyncAfter(deadline: .now()+1) { [weak self] in guard let self, self.wanted, self.generation == retryGeneration else { return }; self.establish() }
    }
    private func receive(_ c: NWConnection?, generation current: Int) {
        c?.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self, weak c] data, _, done, error in
            guard let self, current == self.generation else { return }
            if let data, !data.isEmpty {
                self.state.receivedBytes += data.count; self.lastPacket = ProcessInfo.processInfo.systemUptime
                do { for message in try self.decoder.feed(data) { try self.handle(message) } }
                catch { self.state.decodeErrors += 1; self.fail("Invalid sensor protocol: \(error)"); self.wanted = false; self.lost("Protocol rejected", generation: current); return }
            }
            if let error { self.lost(error.localizedDescription, generation: current) }
            else if done { self.lost("USB stream closed", generation: current) }
            else { self.receive(c, generation: current) }
        }
    }
    private func send(_ type: UInt8, _ data: Data = Data()) {
        guard state.connected else { return }; let current = generation
        connection?.send(content: WireDecoder.encode(type: type, payload: data), completion: .contentProcessed { [weak self] error in
            if let error { self?.lost(error.localizedDescription, generation: current) }
        })
    }
    private func sendSync() {
        guard state.compatible else { return }
        let t = UInt64(ProcessInfo.processInfo.systemUptime*1_000_000); pendingSync.insert(t)
        if pendingSync.count > 32 { pendingSync = [t] }
        var data = Data(); data.put(t); send(7, data); lastSync = ProcessInfo.processInfo.systemUptime
    }
    private func handle(_ m: WireMessage) throws {
        let d = m.payload
        switch m.type {
        case 2:
            guard d.count == 38, d[4] == 1 else { throw WireError.malformed }
            let boot = d.u32(0)
            if state.bootID != boot {
                if state.bootID != 0 { event("Sensor reboot detected · histories reset") }
                aps.removeAll(); history.removeAll(); counts.removeAll(); lastReceive.removeAll(); seen.removeAll(); seenOrder.removeAll(); previousAccepted = 0; state.selected = nil
            }
            state.bootID = boot; state.firmware = "\(d[5]).\(d[6]).\(d[7])"; state.flashMB = Int(d.u32(14))/1048576; state.psramMB = Int(d.u32(18))/1048576
            state.device = "ESP32-S3 · " + d[8..<14].map { String(format: "%02X", $0) }.joined(separator: ":")
            state.compatible = true; state.connection = "USB Ethernet · ready"
            for i in 0..<8 { queue.asyncAfter(deadline: .now()+Double(i)*0.15) { [weak self] in self?.sendSync() } }
            if state.stopping { send(4) } else if desiredCapture { send(15) }
        case 6:
            guard d.count == 4 else { throw WireError.malformed }; state.dwellMs = Int(d.u16(0)); state.firstChannel = Int(d[2]); state.channelCount = Int(d[3])
        case 8:
            guard d.count == 24 else { throw WireError.malformed }
            guard pendingSync.remove(d.u64(0)) != nil else { return }
            clock.add(ClockSample(t1: Double(d.u64(0)), t2: Double(d.u64(8)), t3: Double(d.u64(16)), t4: ProcessInfo.processInfo.systemUptime*1_000_000))
        case 9:
            let ap = try AccessPoint.decode(d); aps[ap.id] = ap
            if state.selected == nil { state.selected = ap.id }
        case 10:
            guard state.compatible else { send(1); return }
            let samples = try SignalSample.decode(m)
            if seen.contains(m.sequence) { state.duplicates += 1 }
            else {
                let now = ProcessInfo.processInfo.systemUptime
                if let spatialSink, !spatialSink(SpatialBatch(samples: samples, boot: state.bootID, sequence: m.sequence, received: now, clock: clock.best(at: now), aps: Array(aps.values), sensorStatus: "firmware=\(state.firmware); boot=\(state.bootID); dwellMs=\(state.dwellMs); firstChannel=\(state.firstChannel); channelCount=\(state.channelCount); counters=\(state.counters)" )) {
                    fail("Survey storage failed; batch retained on sensor. Stop the survey and inspect storage diagnostics.")
                    return
                }
                if let log {
                    var csv = ""
                    for (i,s) in samples.enumerated() {
                        let ap = aps[s.apID]
                        let ssid = "\""+(ap?.ssid ?? "").replacingOccurrences(of: "\"", with: "\"\"")+"\""
                        csv += "\(state.bootID),\(m.sequence),\(i),\(s.espUs),\(now),\(s.apID),\(ap?.bssid ?? ""),\(ssid),\(s.rssi),\(s.channel),\(s.secondary),\(s.subtype),\(s.phy),\(s.mcs),\(s.frameLength),\(s.radioUs)\n"
                    }
                    do { try log.write(contentsOf: Data(csv.utf8)); try log.synchronize(); state.logRows += samples.count }
                    catch { fail("CSV write failed: \(error.localizedDescription)"); finishLog(); desiredCapture = false; send(4) }
                }
                seen.insert(m.sequence); seenOrder.append(m.sequence)
                if seenOrder.count > 8192 { seen.remove(seenOrder.removeFirst()) }
                for sample in samples {
                    history[sample.apID, default: []].append(sample); counts[sample.apID, default: 0] += 1; lastReceive[sample.apID] = now
                    if history[sample.apID, default: []].count > 3000 { history[sample.apID]?.removeFirst(500) }
                }
            }
            var ack = Data(); ack.put(m.sequence); send(13, ack)
        case 11:
            guard d.count == 140 else { throw WireError.malformed }
            statusReceivedAt = ProcessInfo.processInfo.systemUptime
            state.uptime = Double(d.u64(0))/1_000_000; state.counters = (0..<10).map { d.u32(8+$0*4) }
            state.activeChannel = Int(d[48]); state.capturing = d[49] != 0; state.dwellMs = Int(d.u16(50)); state.channelDwell = (0..<11).map { Double(d.u64(52+$0*8))/1_000_000 }
        case 12: fail(String(decoding: d, as: UTF8.self)); state.stopping = false
        case 14: state.capturing = false; state.stopping = false; finishLog(); event("Capture stopped · buffer drained"); stoppedSink?()
        default: throw WireError.malformed
        }
    }
    private func saveDiagnostics() {
        let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = folder.appendingPathComponent("live-diagnostics.json")
        let report: [String: Any] = [
            "formatVersion": 1, "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "connection": state.connection, "connected": state.connected,
            "compatible": state.compatible, "capturing": state.capturing,
            "host": host, "bootID": state.bootID, "firmware": state.firmware,
            "device": state.device, "uptimeSeconds": state.uptime,
            "APCount": aps.count, "receivedBytes": state.receivedBytes,
            "queueDrops": state.counters[3], "bufferDrops": state.counters[4],
            "bufferUsed": state.counters[5], "bufferCapacity": state.counters[6],
            "decodeErrors": state.decodeErrors, "duplicates": state.duplicates,
            "reconnects": state.reconnects, "dwellMs": state.dwellMs,
            "firstChannel": state.firstChannel, "channelCount": state.channelCount,
            "samplesReceived": counts.values.reduce(0,+), "CSVRows": state.logRows,
            "wiredPath": connection?.currentPath?.usesInterfaceType(.wiredEthernet) ?? false,
            "interfaceAddresses": state.interfaceAddresses, "pathDetails": state.pathDetails,
            "events": state.events
        ]
        do { try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: url, options: .atomic); state.diagnosticsURL = url }
        catch { if state.error == nil { fail("Cannot save diagnostics: \(error.localizedDescription)") } }
    }
    private func finishLog() {
        guard let log else { return }
        do { try log.synchronize(); try log.close(); state.exportURL = logURL; event("CSV saved · \(state.logRows) raw observations") }
        catch { fail("CSV close failed: \(error.localizedDescription)") }
        self.log = nil; state.logging = false
    }
    private func fail(_ message: String) { state.error = message; event(message) }
    private func event(_ message: String) {
        let now = ProcessInfo.processInfo.systemUptime
        if message == lastEventMessage && now-lastEventAt < 5 { return }
        lastEventMessage = message; lastEventAt = now
        state.events.insert("\(Date().formatted(date: .omitted, time: .standard))  \(message)", at: 0)
        if state.events.count > 80 { state.events.removeLast() }
    }
    private func interfaceAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result: [String] = []
        var item = head
        while let current = item {
            defer { item = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: current.pointee.ifa_name) + " · " + String(cString: host))
            }
        }
        return result
    }
    private func publish() {
        let now = ProcessInfo.processInfo.systemUptime, dt = max(0.001, now-previousTick)
        if dt >= 1 {
            state.bytesPerSecond = Double(state.receivedBytes-previousBytes)/dt; previousBytes = state.receivedBytes
            let accepted = state.counters[1]
            state.framesPerSecond = accepted >= previousAccepted ? Double(accepted-previousAccepted)/dt : 0
            previousAccepted = accepted; previousTick = now
            state.interfaceAddresses = interfaceAddresses()
            if let path = connection?.currentPath {
                state.pathDetails = "\(path.status) · \(path.unsatisfiedReason) · " + path.availableInterfaces.map { "\($0.name) (\($0.type))" }.joined(separator: ", ")
            }
            saveDiagnostics()
        }
        let estimatedESPNow = state.uptime + (statusReceivedAt.map { now-$0 } ?? 0)
        state.aps = aps.values.map { ap in
            let latest = history[ap.id]?.last
            let age = lastReceive[ap.id].map { max(now-$0, latest.map { estimatedESPNow-$0.seconds } ?? 0) }
            return APRow(ap: ap, latest: latest, count: counts[ap.id] ?? 0, age: age)
        }.sorted { ($0.latest?.rssi ?? -127) > ($1.latest?.rssi ?? -127) }
        if let id = state.selected {
            let samples = history[id] ?? []; state.latest = samples.last
            let latestEsp = state.capturing ? max(state.uptime, samples.last?.seconds ?? 0) : (samples.last?.seconds ?? 0)
            state.samples = samples.filter { $0.seconds >= latestEsp-60 }
            state.selectedPerSecond = Double(samples.filter { $0.seconds >= latestEsp-5 }.count)/5
        } else { state.samples = []; state.latest = nil }
        state.syncRTT = clock.best.map { $0.rttUs/1000 }; state.syncOffset = clock.best.map { $0.offsetUs/1000 }
        state.lastPacketAge = lastPacket.map { now-$0 }
        if state.compatible, now-lastSync > 10 { sendSync() }
        onSnapshot?(state)
    }
}

@MainActor final class InspectorModel: ObservableObject {
    @Published var snapshot = InspectorSnapshot()
    @Published var host = "192.168.7.1"
    @Published var frozen = false
    @Published var frozenSamples: [SignalSample] = []
    let engine = InspectorEngine()
    init() { engine.onSnapshot = { [weak self] snapshot in Task { @MainActor [weak self] in self?.snapshot = snapshot } } }
    var visibleSamples: [SignalSample] { frozen ? frozenSamples : snapshot.samples }
    func toggleFreeze() { if !frozen { frozenSamples = snapshot.samples }; frozen.toggle() }
}
