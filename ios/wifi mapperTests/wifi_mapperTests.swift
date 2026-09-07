import Testing
import Foundation
#if canImport(MapperCore)
@testable import MapperCore
#else
@testable import wifi_mapper
#endif

struct MapperTests {
    @Test func framingAtEveryBoundary() throws {
        let encoded = WireDecoder.encode(type: 8, sequence: 0x12345678, payload: Data([0,1,2,3,4]))
        for split in 0...encoded.count {
            var decoder = WireDecoder()
            let a = try decoder.feed(Data(encoded.prefix(split)))
            let b = try decoder.feed(Data(encoded.dropFirst(split)))
            #expect(a+b == [WireMessage(type: 8, sequence: 0x12345678, payload: Data([0,1,2,3,4]))])
        }
        var decoder = WireDecoder(); #expect(try decoder.feed(encoded+encoded).count == 2)
    }
    @Test func bytewiseAndInvalidFrames() throws {
        let encoded = WireDecoder.encode(type: 1)
        var decoder = WireDecoder(); var messages: [WireMessage] = []
        for byte in encoded { messages += try decoder.feed(Data([byte])) }
        #expect(messages.count == 1)
        var invalid = encoded; invalid[2] = 2
        #expect(throws: WireError.self) { try decoder.feed(invalid) }
        invalid = encoded; invalid[8] = 255; invalid[9] = 255
        #expect(throws: WireError.self) { try decoder.feed(invalid) }
        #expect(try decoder.feed(encoded).count == 1)
    }
    @Test func observationVector() throws {
        var d = Data(); d.put(UInt16(1)); d.put(UInt64(1_234_567)); d.put(UInt16(17)); d.append(contentsOf: [UInt8(bitPattern: -61),6,0,8,1,3]); d.put(UInt16(128)); d.put(UInt32(1234)); d.put(UInt16(0))
        let m = WireMessage(type: 10, sequence: 42, payload: d)
        let sample = try #require(SignalSample.decode(m).first)
        #expect(sample.espUs == 1_234_567); #expect(sample.apID == 17); #expect(sample.rssi == -61); #expect(sample.channel == 6); #expect(sample.radioUs == 1234); #expect(sample.id == 42<<8)
        #expect(throws: WireError.self) { try SignalSample.decode(WireMessage(type: 10, sequence: 42, payload: Data(d.dropLast()))) }
        let stats = SignalStatistics([sample]); #expect(stats.mean == -61); #expect(stats.deviation == 0)
    }
    @Test func descriptorBoundaries() throws {
        var d = Data(); d.put(UInt16(9)); d.append(contentsOf: [0,1,2,3,4,5,6,0]); d.put(UInt16(17)); d.put(UInt16(100))
        let ap = try AccessPoint.decode(d); #expect(ap.ssid == ""); #expect(ap.bssid == "00:01:02:03:04:05"); #expect(ap.secured)
        d[9] = 32; d.append(Data(repeating: 65, count: 32)); #expect(try AccessPoint.decode(d).ssid.count == 32)
        d[9] = 33; #expect(throws: WireError.self) { try AccessPoint.decode(d) }
    }
    @Test func clockRejectsBadSamplesChoosesMinimumRTT() {
        var model = ClockModel()
        model.add(ClockSample(t1: 1000, t2: 6100, t3: 6120, t4: 1220))
        #expect(model.best?.offsetUs == 5000); #expect(model.best?.rttUs == 200)
        model.add(ClockSample(t1: 2000, t2: 7500, t3: 7510, t4: 3010))
        #expect(model.best?.rttUs == 200)
        model.add(ClockSample(t1: 2000, t2: 7500, t3: 7400, t4: 2010)); #expect(model.samples.count == 2)
    }
}
