import Testing
import Foundation
#if canImport(MapperCore)
@testable import MapperCore
#else
@testable import wifi_mapper
#endif
struct SpatialTests {
    private func pose(_ seconds: Double,_ x: Double,normal: Bool=true,segment: Int=1) -> MapPose { MapPose(phoneSeconds:seconds,position:MapPosition(x:x,y:0,z:0),transform:[],tracking:normal ? "normal" : "limited",segment:segment) }
    private func point(_ x: Double,_ z: Double,_ rssi: Int,y: Double=0) -> TrailPoint { TrailPoint(id:0,phoneSeconds:0,position:MapPosition(x:x,y:y,z:z),segment:1,apID:1,rssi:rssi,uncertaintyMs:3) }
    @Test func expiredLowLatencySyncDoesNotHideFreshSync() {
        var clock=ClockModel()
        let old=ClockSample(t1:0,t2:100,t3:100,t4:200)
        let fresh=ClockSample(t1:25_000_000,t2:25_002_000,t3:25_002_000,t4:25_004_000)
        clock.add(old);clock.add(fresh)
        #expect(clock.best == old)
        #expect(clock.best(at:35) == fresh)
        #expect(clock.best(at:60) == nil)
    }
    @Test func alignsCaptureTimeRatherThanArrival() throws {
        let poses=[pose(100,0),pose(100.1,1),pose(100.2,2)]
        let result=try #require(PoseInterpolation.position(at:100.05,in:poses))
        #expect(abs(result.0.x-0.5)<0.00001);#expect(result.1==1)
        #expect(PoseInterpolation.position(at:101,in:poses)==nil)
    }
    @Test func refusesTrackingGapsAndExtrapolation() {
        #expect(PoseInterpolation.position(at:1.05,in:[pose(1,0),pose(1.1,1,normal:false)])==nil)
        #expect(PoseInterpolation.position(at:1.05,in:[pose(1,0),pose(1.1,1,segment:2)])==nil)
        #expect(PoseInterpolation.position(at:1.1,in:[pose(1,0),pose(2,1)])==nil)
        #expect(PoseInterpolation.position(at:0.9,in:[pose(1,0),pose(1.1,1)])==nil)
        #expect(PoseInterpolation.position(at:1,in:[])==nil)
    }
    @Test func heatmapPreservesMeasuredBinsAndLimitsSupport() throws {
        let heat=HeatmapBuilder.generate([point(0.1,0.1,-50),point(0.12,0.12,-70)],radius:1)
        let measured=try #require(heat.cells.first(where: { $0.measured }));#expect(measured.rssi == -60);#expect(measured.support==2)
        #expect(heat.cells.allSatisfy { hypot($0.x-measured.x,$0.z-measured.z)<=1.001 })
        #expect(heat.cells.allSatisfy { abs($0.rssi+60)<0.00001 })
    }
    @Test func excludesOtherFloorsAndBoundsMemory() {
        let heat=HeatmapBuilder.generate([point(0,0,-40),point(0,0,-90,y:3)],heightCenter:0)
        #expect(heat.cells.first(where: { $0.measured })?.rssi == -40)
        let limited=HeatmapBuilder.generate([point(0,0,-50)],maxCells:5)
        #expect(limited.cells.count<=5);#expect(limited.limited)
        #expect(HeatmapBuilder.generate([],heightCenter:0).cells.isEmpty)
        #expect(HeatmapBuilder.generate([point(0,0,-50)],cellSize:0).cells.isEmpty)
    }
    @Test func interpolationStaysInsideMeasuredSignalRange() {
        let heat=HeatmapBuilder.generate([point(-0.5,0,-80),point(0.5,0,-40)])
        #expect(heat.cells.allSatisfy { $0.rssi >= -80.001 && $0.rssi <= -39.999 })
        #expect(heat.cells.contains { !$0.measured && $0.rssi > -75 && $0.rssi < -45 })
    }
    @Test func clockExpiresOldOffsets() {
        var model=ClockModel();model.add(ClockSample(t1:0,t2:10,t3:10,t4:20));model.add(ClockSample(t1:70_000_000,t2:70_000_200,t3:70_000_200,t4:70_000_400));#expect(model.samples.count==1)
    }
}

#if !canImport(MapperCore)
struct SurveyStorageTests {
    @Test func durableRawAndAlignedRoundTrip() throws {
        let id=UUID();let folder=SurveyStore.root.appendingPathComponent(id.uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        do {
            let store=try SurveyStore(id:id)
            let matrix:[Float]=[1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1]
            try store.pose(MapPose(phoneSeconds:1,position:.zero,transform:matrix,tracking:"normal",segment:1))
            try store.pose(MapPose(phoneSeconds:1.1,position:MapPosition(x:1,y:0,z:0),transform:matrix,tracking:"normal",segment:1))
            let ap=AccessPoint(id:7,bssid:"02:00:00:00:00:01",ssid:"Storage test",channel:6,capability:17,beaconInterval:100);try store.ap(ap)
            let sample=SignalSample(id:256,espUs:6_050_000,apID:7,rssi:-61,channel:6,secondary:0,subtype:8,phy:1,mcs:0,frameLength:100,radioUs:123)
            let clock=ClockSample(t1:1_000_000,t2:6_005_000,t3:6_005_000,t4:1_010_000);try store.sync(clock)
            let identifiers=try store.batch([sample],boot:1,sequence:1,received:1.2,clock:clock)
            #expect(identifiers.count==1 && identifiers[0]>0)
            let duplicate=try store.batch([sample],boot:1,sequence:1,received:1.3,clock:clock);#expect(duplicate==[-1])
            try store.aligned(TrailPoint(id:identifiers[0],phoneSeconds:1.05,position:MapPosition(x:0.5,y:0,z:0),segment:1,apID:7,rssi:-61,uncertaintyMs:5))
            try store.finish()
        }
        let loaded=try SurveyStore.load(folder);#expect(loaded.poses.count==2);#expect(loaded.points.count==1);#expect(loaded.points[0].rssi == -61);#expect(loaded.aps[7]?.ssid=="Storage test")
        #expect(SurveyStore.list().first(where:{$0.id==id.uuidString})?.finished==true)
        let archive=try SurveyStore.export(folder);defer {try? FileManager.default.removeItem(at:archive)}
        let prefix=try Data(contentsOf:archive).prefix(2);#expect(prefix==Data([0x50,0x4b]))
    }
    @Test func interruptedSurveyRemainsReadable() throws {
        let id=UUID();let folder=SurveyStore.root.appendingPathComponent(id.uuidString);defer {try? FileManager.default.removeItem(at:folder)}
        do {let store=try SurveyStore(id:id);try store.pose(MapPose(phoneSeconds:1,position:.zero,transform:Array(repeating:0,count:16),tracking:"limited",segment:0))}
        #expect(SurveyStore.list().first(where:{$0.id==id.uuidString})?.finished==false)
        #expect(try SurveyStore.load(folder).poses.count==1)
    }
}
#endif
