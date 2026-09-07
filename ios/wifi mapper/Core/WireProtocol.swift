import Foundation

enum WireError: Error { case version(UInt8), malformed, overflow }
struct WireMessage: Equatable {
    let type: UInt8
    let sequence: UInt32
    let payload: Data
}
extension Data {
    func u16(_ p: Int) -> UInt16 { UInt16(self[startIndex+p]) | UInt16(self[startIndex+p+1]) << 8 }
    func u32(_ p: Int) -> UInt32 { UInt32(u16(p)) | UInt32(u16(p+2)) << 16 }
    func u64(_ p: Int) -> UInt64 { UInt64(u32(p)) | UInt64(u32(p+4)) << 32 }
    mutating func put<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
}
struct WireDecoder {
    private var bytes = Data()
    mutating func reset() { bytes.removeAll(keepingCapacity: true) }
    mutating func feed(_ chunk: Data) throws -> [WireMessage] {
        guard bytes.count + chunk.count <= 131072 else { reset(); throw WireError.overflow }
        bytes.append(chunk)
        var messages: [WireMessage] = []
        while bytes.count >= 12 {
            guard bytes[0] == 0x57, bytes[1] == 0x4d, bytes.u16(10) == 0 else { reset(); throw WireError.malformed }
            guard bytes[2] == 1 else { let v = bytes[2]; reset(); throw WireError.version(v) }
            let length = Int(bytes.u16(8))
            guard length <= 2048 else { reset(); throw WireError.overflow }
            guard bytes.count >= length + 12 else { break }
            messages.append(WireMessage(type: bytes[3], sequence: bytes.u32(4), payload: bytes.subdata(in: 12..<12+length)))
            bytes = Data(bytes.dropFirst(12+length))
        }
        return messages
    }
    static func encode(type: UInt8, sequence: UInt32 = 0, payload: Data = Data()) -> Data {
        precondition(payload.count <= 2048)
        var d = Data([0x57,0x4d,1,type]); d.put(sequence); d.put(UInt16(payload.count)); d.put(UInt16(0)); d.append(payload); return d
    }
}
struct AccessPoint: Identifiable, Equatable {
    let id: UInt16
    let bssid: String
    let ssid: String
    let channel: Int
    let capability: UInt16
    let beaconInterval: UInt16
    var title: String { ssid.isEmpty ? "Hidden network" : ssid }
    var secured: Bool { capability & 0x10 != 0 }
    static func decode(_ d: Data) throws -> Self {
        guard d.count >= 14 else { throw WireError.malformed }
        let length = Int(d[9]); guard length <= 32, d.count == 14+length else { throw WireError.malformed }
        return Self(id: d.u16(0), bssid: d[2..<8].map { String(format:"%02X",$0) }.joined(separator: ":"), ssid: String(decoding: d[14...], as: UTF8.self), channel: Int(d[8]), capability: d.u16(10), beaconInterval: d.u16(12))
    }
}
struct SignalSample: Identifiable, Equatable {
    let id: UInt64
    let espUs: UInt64
    let apID: UInt16
    let rssi: Int
    let channel: Int
    let secondary: Int
    let subtype: Int
    let phy: Int
    let mcs: Int
    let frameLength: Int
    let radioUs: UInt32
    var seconds: Double { Double(espUs) / 1_000_000 }
    static func decode(_ message: WireMessage) throws -> [Self] {
        let d = message.payload
        guard d.count >= 2 else { throw WireError.malformed }
        let count = Int(d.u16(0)); guard count > 0, count <= 32, d.count == 2+count*24 else { throw WireError.malformed }
        return try (0..<count).map { i in
            let p = 2+i*24
            guard (1...14).contains(d[p+11]), [5,8].contains(d[p+13]) else { throw WireError.malformed }
            return Self(id: UInt64(message.sequence)<<8|UInt64(i), espUs: d.u64(p), apID: d.u16(p+8), rssi: Int(Int8(bitPattern: d[p+10])), channel: Int(d[p+11]), secondary: Int(d[p+12]), subtype: Int(d[p+13]), phy: Int(d[p+14]), mcs: Int(d[p+15]), frameLength: Int(d.u16(p+16)), radioUs: d.u32(p+18))
        }
    }
}
struct ClockSample: Equatable {
    let t1: Double, t2: Double, t3: Double, t4: Double
    var rttUs: Double { (t4-t1)-(t3-t2) }
    var offsetUs: Double { ((t2-t1)+(t3-t4))/2 }
}
struct ClockModel {
    private(set) var samples: [ClockSample] = []
    var best: ClockSample? { samples.min { $0.rttUs < $1.rttUs } }
    func best(at phoneSeconds: Double, maximumAge: Double = 30) -> ClockSample? {
        samples.filter { let age=phoneSeconds-$0.t4/1_000_000;return age >= 0 && age < maximumAge }.min { $0.rttUs < $1.rttUs }
    }
    mutating func add(_ sample: ClockSample) {
        guard sample.t4 >= sample.t1, sample.t3 >= sample.t2, sample.rttUs >= 0, sample.rttUs < 2_000_000 else { return }
        samples.removeAll { $0.t4 < sample.t4 - 60_000_000 }; samples.append(sample); if samples.count > 30 { samples.removeFirst(samples.count-30) }
    }
}
struct SignalStatistics {
    let count: Int
    let minimum: Int?
    let maximum: Int?
    let mean: Double?
    let deviation: Double?
    init(_ samples: [SignalSample]) {
        count = samples.count; minimum = samples.map(\.rssi).min(); maximum = samples.map(\.rssi).max()
        guard !samples.isEmpty else { mean = nil; deviation = nil; return }
        let m = samples.reduce(0.0) { $0+Double($1.rssi) } / Double(samples.count)
        mean = m; deviation = sqrt(samples.reduce(0.0) { $0+pow(Double($1.rssi)-m,2) } / Double(samples.count))
    }
}
