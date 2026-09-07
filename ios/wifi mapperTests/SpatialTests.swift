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
    @Test func heatAlgorithmsKeepMeasurementsAndBoundEstimates() throws {
        let points=[point(0.1,0.1,-80),point(1.1,0.1,-40)]
        for algorithm in HeatAlgorithm.allCases {
            let heat=HeatmapBuilder.generate(points,radius:1,algorithm:algorithm)
            #expect(heat.cells.filter {$0.measured}.count==2)
            #expect(heat.cells.allSatisfy {$0.rssi>=(-80.001) && $0.rssi<=(-39.999)})
            if algorithm == .measured {#expect(heat.cells.count==2)}
            if algorithm == .nearest {#expect(heat.cells.allSatisfy {$0.rssi == -80 || $0.rssi == -40})}
        }
        let gaussian=HeatmapBuilder.generate(points,radius:1,algorithm:.gaussian)
        let idw=HeatmapBuilder.generate(points,radius:1,algorithm:.idw)
        let g=try #require(gaussian.cells.first {$0.x==0.375 && $0.z==0.125})
        let i=try #require(idw.cells.first {$0.x==0.375 && $0.z==0.125})
        #expect(abs(g.rssi-i.rssi)>0.1)
    }
    @Test func denseOutputPrioritizesMeasuredCellsAndIsDeterministic() {
        let points=[point(0,0,-60),point(50,50,-40)]
        let result=HeatmapBuilder.generate(points,maxCells:2)
        #expect(result.cells.count==2);#expect(result.cells.allSatisfy {$0.measured})
        let a=HeatmapBuilder.generate(points,maxCells:5),b=HeatmapBuilder.generate(points,maxCells:5)
        #expect(a.cells.map(\.id)==b.cells.map(\.id));#expect(a.limited)
        #expect(a.cells.filter {$0.measured}.count==2)
    }
    @Test func workBudgetFallsBackToMeasurementsWithoutBiasedFill() {
        let points=(0..<250).map {point(Double($0)*0.5,0,-50)}
        let result=HeatmapBuilder.generate(points,cellSize:0.1,radius:5)
        #expect(result.limited);#expect(result.cells.count==250)
        #expect(result.cells.allSatisfy {$0.measured})
    }
    @Test func unsafeHeatParametersDoNotTrap() {
        let points=[point(0,0,-60),point(Double.greatestFiniteMagnitude,0,-40)]
        #expect(HeatmapBuilder.generate(points,cellSize:.nan).cells.isEmpty)
        #expect(HeatmapBuilder.generate(points,radius:.infinity).cells.isEmpty)
        #expect(HeatmapBuilder.generate(points,cellSize:0.00001).cells.isEmpty)
        #expect(HeatmapBuilder.generate(points,heightCenter:.nan).cells.isEmpty)
        #expect(HeatmapBuilder.generate(points,algorithm:.measured).cells.count==1)
    }
    @Test func geographicRegistrationUsesRightHandedARAxes() throws {
        let fix=GeoFix(latitude:0,longitude:0,altitude:10,horizontalAccuracy:5,verticalAccuracy:8,timestamp:Date(timeIntervalSince1970:0),phoneSeconds:1)
        let south=GeoReference(fix:fix,position:.zero,bearing:180,segment:1)
        #expect(south.coordinate(.zero).latitude==0)
        #expect(south.coordinate(MapPosition(x:1,y:0,z:0)).longitude>0)
        #expect(south.coordinate(MapPosition(x:0,y:0,z:1)).latitude<0)
        let north=GeoReference(fix:fix,position:.zero,bearing:0,segment:1)
        #expect(north.coordinate(MapPosition(x:1,y:0,z:0)).longitude<0)
        #expect(north.coordinate(MapPosition(x:0,y:0,z:1)).latitude>0)
        let east=GeoReference(fix:fix,position:MapPosition(x:5,y:0,z:7),bearing:90,segment:1)
        #expect(east.coordinate(MapPosition(x:5,y:0,z:7)).latitude==0)
        #expect(east.coordinate(MapPosition(x:5,y:0,z:8)).longitude>0)
        let restored=try JSONDecoder().decode(GeoReference.self,from:JSONEncoder().encode(east))
        #expect(restored.position==east.position);#expect(restored.fix.valid)
    }
    @Test func palettesClampAndSettingsRoundTrip() throws {
        var settings=HeatSettings()
        for palette in HeatPalette.allCases {
            settings.palette=palette
            for value in [-120.0,-70,0] {
                let rgb=SignalPalette.rgb(value,settings:settings)
                #expect([rgb.0,rgb.1,rgb.2].allSatisfy {$0>=0 && $0<=1})
            }
        }
        #expect(try JSONDecoder().decode(HeatSettings.self,from:JSONEncoder().encode(settings))==settings)
    }
    @Test func clockExpiresOldOffsets() {
        var model=ClockModel();model.add(ClockSample(t1:0,t2:10,t3:10,t4:20));model.add(ClockSample(t1:70_000_000,t2:70_000_200,t3:70_000_200,t4:70_000_400));#expect(model.samples.count==1)
    }
}

#if !canImport(MapperCore)
import SQLite3
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
    @Test func meshUpdatesRemovalAndReferenceSurviveReopen() throws {
        let id=UUID(),anchor=UUID();let folder=SurveyStore.root.appendingPathComponent(id.uuidString)
        defer {try? FileManager.default.removeItem(at:folder)}
        let fix=GeoFix(latitude:0,longitude:0,altitude:0,horizontalAccuracy:4,verticalAccuracy:5,timestamp:Date(timeIntervalSince1970:0),phoneSeconds:1)
        do {
            let store=try SurveyStore(id:id)
            let face=SurfaceFace(a:.zero,b:MapPosition(x:1,y:0,z:0),c:MapPosition(x:0,y:0,z:1),wall:false)
            try store.layer("mesh",SurfacePatch(id:anchor,phoneSeconds:1,segment:1,faces:[face],sourceFaceCount:1,sampled:false))
            try store.layer("location",fix)
            try store.layer("reference",GeoReference(fix:fix,position:.zero,bearing:180,segment:1))
            let first=try SurveyStore.load(folder)
            #expect(first.surfaces[anchor]?.faces.count==1);#expect(first.reference?.bearing==180)
            try store.layer("mesh-removed",anchor)
            try store.finish()
        }
        let loaded=try SurveyStore.load(folder)
        #expect(loaded.surfaces.isEmpty);#expect(loaded.reference?.fix.horizontalAccuracy==4)
    }
    @Test func schemaOneSurveyLoadsWithoutMapLayers() throws {
        let id=UUID();let folder=SurveyStore.root.appendingPathComponent(id.uuidString)
        defer {try? FileManager.default.removeItem(at:folder)}
        do {let store=try SurveyStore(id:id);try store.pose(MapPose(phoneSeconds:1,position:.zero,transform:[],tracking:"normal",segment:1))}
        var database: OpaquePointer?
        #expect(sqlite3_open(folder.appendingPathComponent("survey.sqlite").path,&database)==SQLITE_OK)
        defer {sqlite3_close(database)}
        #expect(sqlite3_exec(database,"DROP TABLE map_layers; PRAGMA user_version=1",nil,nil,nil)==SQLITE_OK)
        let loaded=try SurveyStore.load(folder)
        #expect(loaded.poses.count==1);#expect(loaded.surfaces.isEmpty);#expect(loaded.reference==nil)
    }
    @Test func interruptedSurveyRemainsReadable() throws {
        let id=UUID();let folder=SurveyStore.root.appendingPathComponent(id.uuidString);defer {try? FileManager.default.removeItem(at:folder)}
        do {let store=try SurveyStore(id:id);try store.pose(MapPose(phoneSeconds:1,position:.zero,transform:Array(repeating:0,count:16),tracking:"limited",segment:0))}
        #expect(SurveyStore.list().first(where:{$0.id==id.uuidString})?.finished==false)
        #expect(try SurveyStore.load(folder).poses.count==1)
    }
}
#endif
