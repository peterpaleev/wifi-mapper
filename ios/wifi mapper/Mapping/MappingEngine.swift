import Foundation
import ARKit
import AVFoundation
import Combine

struct MappingSnapshot {
    var surfaces: [SurfacePatch]=[]
    var surfaceLimited=false
    var layerRevision=0
    var mapBounds: [MapPosition]=[]
    var reference: GeoReference?
    var recording=false
    var stopping=false
    var reviewing=false
    var tracking="Camera stopped"
    var poses: [MapPose]=[]
    var points: [TrailPoint]=[]
    var heat=HeatResult(cells:[],resolution:0.25,limited:false)
    var aps: [AccessPoint]=[]
    var selectedAP: UInt16?
    var position=MapPosition.zero
    var distance=0.0
    var duration=0.0
    var rawCount=0
    var alignedCount=0
    var unalignedCount=0
    var trackingGaps=0
    var error: String?
    var folder: URL?
    var exportURL: URL?
    var title="New survey"
    var revision=0
}
struct SpatialBatch {
    let samples: [SignalSample]
    let boot: UInt32
    let sequence: UInt32
    let received: Double
    let clock: ClockSample?
    let aps: [AccessPoint]
    let sensorStatus: String
}
final class MappingEngine: @unchecked Sendable {
    let queue=DispatchQueue(label:"wifi.mapper.survey",qos:.userInitiated)
    private var state=MappingSnapshot()
    private var store: SurveyStore?
    private var poses: [MapPose]=[]
    private var points: [TrailPoint]=[]
    private var descriptors: [UInt16:AccessPoint]=[:]
    private var pending: [(Int64,SignalSample,Double,Double)]=[]
    private var startSeconds=0.0
    private var boot: UInt32?
    private let heatQueue=DispatchQueue(label:"wifi.mapper.heatmap",qos:.utility)
    private var heatBusy=false
    private var heatVersion=0
    private var surfaces: [UUID:SurfacePatch]=[:]
    private var heatSettings=HeatSettings()
    private var heatEnabled=false
    private var heightCenter: Double?=0
    private var lastHeat=0.0
    private var lastHeatCount = -1
    private var lastSyncT1=0.0
    private var lastStatusWrite=0.0
    private var lastLiveWrite=0.0
    private var timer: DispatchSourceTimer?
    var onSnapshot: (@Sendable(MappingSnapshot)->Void)?
    init() {
        let timer=DispatchSource.makeTimerSource(queue:queue);timer.schedule(deadline:.now(),repeating:.milliseconds(250));timer.setEventHandler { [weak self] in self?.publish() };timer.resume();self.timer=timer
    }
    func begin() { queue.async {
        guard !self.state.recording else { return }
        do {
            let store=try SurveyStore(id:UUID());self.store=store;self.state=MappingSnapshot();self.state.recording=true;self.state.folder=store.folder
            self.state.title=Date().formatted(date:.abbreviated,time:.shortened);self.startSeconds=ProcessInfo.processInfo.systemUptime
            self.surfaces.removeAll();self.poses.removeAll();self.points.removeAll();self.pending.removeAll();self.descriptors.removeAll();self.boot=nil;self.lastSyncT1=0;self.lastHeatCount = -1;self.heatVersion += 1
            try store.event("start","Rig is uncalibrated; keep ESP fixed relative to iPhone")
        } catch { self.failure(error) }
    } }
    func beginStopping() { queue.async { self.state.stopping=true } }
    func finish() { queue.async {
        guard self.state.recording else { return }
        self.resolvePending(final:true)
        do { try self.store?.event("stop","Unaligned observations: \(self.state.unalignedCount)");try self.store?.finish() } catch { self.failure(error) }
        self.state.recording=false;self.state.stopping=false;self.store=nil;self.publish()
    } }
    func select(_ id: UInt16?) { queue.async { if self.state.selectedAP != id { self.state.selectedAP=id;self.state.heat.cells=[];self.lastHeatCount = -1;self.heatVersion += 1;self.state.revision += 1 } } }
    func options(heat: Bool,height: Double?,settings: HeatSettings) { queue.async { self.heatEnabled=heat;self.heightCenter=height;self.heatSettings=settings;self.state.heat.cells=[];self.lastHeatCount = -1;self.heatVersion += 1 } }
    func surface(_ patch: SurfacePatch) { queue.async {
        guard self.state.recording,patch.phoneSeconds>=self.startSeconds else {return}
        if let previous=self.surfaces[patch.id],previous.faces==patch.faces,previous.sampled==patch.sampled,previous.sourceFaceCount==patch.sourceFaceCount,previous.segment==patch.segment {return}
        do {
            try self.store?.layer("mesh",patch);self.state.layerRevision += 1
            self.surfaces[patch.id]=patch
            if self.surfaces.count>256,let oldest=self.surfaces.values.min(by: {$0.phoneSeconds<$1.phoneSeconds}) {
                self.surfaces.removeValue(forKey:oldest.id);self.state.surfaceLimited=true
            }
        } catch {self.failure(error)}
    } }
    func removeSurface(_ id: UUID) { queue.async {
        guard self.state.recording else {return}
        do {try self.store?.layer("mesh-removed",id);self.surfaces.removeValue(forKey:id);self.state.layerRevision += 1} catch {self.failure(error)}
    } }
    func location(_ fix: GeoFix) { queue.async {
        guard self.state.recording else {return}
        do {try self.store?.layer("location",fix)} catch {self.failure(error)}
    } }
    func register(_ fix: GeoFix,bearing: Double) { queue.async {
        guard self.state.recording,fix.valid,bearing.isFinite,
              let (position,segment)=PoseInterpolation.position(at:fix.phoneSeconds,in:self.poses),
              ProcessInfo.processInfo.systemUptime-fix.phoneSeconds<10 else {
            self.state.error="Registration needs a recent location fix bracketed by normal AR poses. Stand still briefly and retry.";return
        }
        let reference=GeoReference(fix:fix,position:position,bearing:bearing,segment:segment)
        do {try self.store?.layer("reference",reference);self.state.reference=reference} catch {self.failure(error)}
    } }
    func event(_ kind: String,_ message: String) { queue.async { if self.state.recording { try? self.store?.event(kind,message) };self.state.tracking=message } }
    func ingestPose(_ pose: MapPose) { queue.async {
        guard self.state.recording,pose.phoneSeconds>=self.startSeconds else { return }
        do { try self.store?.pose(pose) } catch { self.failure(error);return }
        if let previous=self.poses.last,pose.normal,previous.normal,pose.segment==previous.segment,pose.phoneSeconds-previous.phoneSeconds<0.25 {
            let distance=pose.position.distance(to:previous.position)
            if distance<0.5 { self.state.distance += distance }
        }
        if let previous=self.poses.last,previous.normal && !pose.normal { self.state.trackingGaps += 1 }
        self.poses.append(pose);self.state.position=pose.position;self.state.tracking=pose.tracking
        // Retain enough poses to align a full ESP backlog. Raw poses remain on disk.
        if self.poses.count>72000 { self.poses.removeFirst(12000) }
        self.state.duration=pose.phoneSeconds-self.startSeconds;self.resolvePending(final:false)
    } }
    /// The transport calls this off-main and acknowledges only after this durable write.
    func ingest(_ batch: SpatialBatch) -> Bool { queue.sync {
        guard state.recording,let store else { return true }
        do {
            if let boot,boot != batch.boot { throw SurveyStorageError(message:"ESP rebooted during survey. Stop and begin a new survey to preserve AP identity.") };boot=batch.boot
            for ap in batch.aps where descriptors[ap.id] != ap { descriptors[ap.id]=ap;try store.ap(ap) }
            let sync=batch.clock.flatMap { sample -> ClockSample? in
                guard sample.rttUs<=100_000,batch.received-sample.t4/1e6<30 else { return nil };return sample
            }
            if let sync,sync.t1 != lastSyncT1 { try store.sync(sync);lastSyncT1=sync.t1 }
            if batch.received-lastStatusWrite>=1 { try store.event("sensor-status",batch.sensorStatus);lastStatusWrite=batch.received }
            let ids=try store.batch(batch.samples,boot:batch.boot,sequence:batch.sequence,received:batch.received,clock:sync)
            for (index,sample) in batch.samples.enumerated() where ids[index]>=0 {
                state.rawCount += 1
                if let sync { pending.append((ids[index],sample,(Double(sample.espUs)-sync.offsetUs)/1e6,sync.rttUs/2000)) }
                else { state.unalignedCount += 1 }
            }
            resolvePending(final:false)
            return true
        } catch { failure(error);return false }
    } }
    private func resolvePending(final: Bool) {
        guard let latest=poses.last else {
            let drop=final ? pending.count : max(0,pending.count-32768)
            state.unalignedCount += drop
            if drop>0 { pending.removeFirst(drop) }
            return
        }
        var remaining: [(Int64,SignalSample,Double,Double)]=[]
        for (id,sample,seconds,uncertainty) in pending {
            if seconds>latest.phoneSeconds && !final { remaining.append((id,sample,seconds,uncertainty));continue }
            if let (position,segment)=PoseInterpolation.position(at:seconds,in:poses) {
                let point=TrailPoint(id:id,phoneSeconds:seconds,position:position,segment:segment,apID:sample.apID,rssi:sample.rssi,uncertaintyMs:uncertainty)
                do { try store?.aligned(point);points.append(point);state.alignedCount += 1;state.revision += 1 }
                catch { failure(error) }
            } else { state.unalignedCount += 1 }
        }
        // A bad/future clock must not grow memory indefinitely.
        if remaining.count>32768 { state.unalignedCount += remaining.count-32768;remaining=Array(remaining.suffix(32768)) }
        pending=remaining
        if points.count>150000 { points.removeFirst(10000) }
    }
    private func failure(_ error: Error) { state.error=error.localizedDescription }
    func clearError() { queue.async { self.state.error=nil } }
    func load(_ folder: URL) { queue.async {
        guard !self.state.recording else { return }
        do {
            let data=try SurveyStore.load(folder);self.poses=data.poses;self.points=data.points;self.descriptors=data.aps
            self.state=MappingSnapshot();self.state.reviewing=true;self.state.folder=folder;self.state.title="Saved survey";self.state.tracking="Saved AR trajectory"
            self.surfaces=data.surfaces;self.state.surfaceLimited=data.surfaceLimited;self.state.reference=data.reference;self.state.selectedAP=data.aps.keys.sorted().first;self.state.rawCount=data.rawCount;self.state.alignedCount=data.points.count;self.state.unalignedCount=max(0,data.rawCount-data.points.count);self.state.position=data.poses.last?.position ?? .zero
            self.state.duration=(data.poses.last?.phoneSeconds ?? 0)-(data.poses.first?.phoneSeconds ?? 0);self.lastHeatCount = -1;self.heatVersion += 1;self.state.revision += 1
            for pair in zip(data.poses,data.poses.dropFirst()) where pair.0.normal && pair.1.normal && pair.0.segment==pair.1.segment { self.state.distance += pair.0.position.distance(to:pair.1.position) }
            self.publish()
        } catch { self.failure(error) }
    } }
    func export() { queue.async { guard let folder=self.state.folder,!self.state.recording else { return };do { self.state.exportURL=try SurveyStore.export(folder) } catch { self.failure(error) } } }
    private func publish() {
        let patches=surfaces.values.sorted {$0.id.uuidString<$1.id.uuidString}
        let perPatch=max(1,12000/max(1,patches.count))
        state.surfaces=patches.map {p in SurfacePatch(id:p.id,phoneSeconds:p.phoneSeconds,segment:p.segment,faces:decimate(p.faces,maximum:perPatch),sourceFaceCount:p.sourceFaceCount,sampled:p.sampled || p.faces.count>perPatch)}
        state.surfaceLimited=state.surfaceLimited || state.surfaces.contains {$0.sampled}
        state.poses=decimate(poses,maximum:4000)
        let selected=points.filter { $0.apID==state.selectedAP }
        state.points=decimate(selected,maximum:5000)
        let boundsPositions=state.poses.map(\.position)+state.points.map(\.position)+state.surfaces.flatMap {$0.faces.flatMap {[$0.a,$0.b,$0.c]}}
        if !boundsPositions.isEmpty {
            state.mapBounds=[MapPosition(x:boundsPositions.map(\.x).min()!,y:0,z:boundsPositions.map(\.z).min()!),MapPosition(x:boundsPositions.map(\.x).max()!,y:0,z:boundsPositions.map(\.z).max()!)]
        } else {state.mapBounds=[]}
        state.aps=descriptors.values.sorted { $0.title<$1.title }
        if state.selectedAP==nil,let first=state.aps.first { state.selectedAP=first.id }
        if heatEnabled {
            let now=ProcessInfo.processInfo.systemUptime
            if lastHeatCount != selected.count,now-lastHeat>=1,!heatBusy {
                lastHeatCount=selected.count;lastHeat=now;heatBusy=true
                let height=heightCenter,version=heatVersion,settings=heatSettings
                heatQueue.async {
                    let result=HeatmapBuilder.generate(selected,cellSize:settings.cellSize,radius:settings.radius,heightCenter:height,algorithm:settings.algorithm)
                    self.queue.async { self.heatBusy=false;if version==self.heatVersion && self.heatEnabled { self.state.heat=result;self.state.layerRevision += 1 } }
                }
            }
        } else { state.heat.cells=[] }
        if ProcessInfo.processInfo.systemUptime-lastLiveWrite>=1 {
            lastLiveWrite=ProcessInfo.processInfo.systemUptime
            let report: [String:Any]=["generatedAt":ISO8601DateFormatter().string(from:Date()),"recording":state.recording,"reviewing":state.reviewing,"title":state.title,"tracking":state.tracking,"poseCount":poses.count,"rawWiFiCount":state.rawCount,"alignedCount":state.alignedCount,"unalignedCount":state.unalignedCount,"pendingAlignment":pending.count,"distanceMeters":state.distance,"durationSeconds":state.duration,"position":[state.position.x,state.position.y,state.position.z],"heatmapCells":state.heat.cells.count,"heatmapEnabled":heatEnabled,"surveyFolder":state.folder?.lastPathComponent ?? "","error":state.error ?? ""]
            let url=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("live-survey.json")
            do { try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:url,options:.atomic) } catch { failure(error) }
        }
        onSnapshot?(state)
    }
    private func decimate<T>(_ values: [T],maximum: Int) -> [T] {
        guard values.count>maximum else { return values };let stride=max(1,Int(ceil(Double(values.count)/Double(maximum))));var output=values.enumerated().compactMap { $0.offset%stride==0 ? $0.element : nil };if let last=values.last { output.append(last) };return output
    }
    #if DEBUG
    func fixture(geographic: Bool=false) { queue.async {
        if geographic {
            let fix=GeoFix(latitude:48.8584,longitude:2.2945,altitude:0,horizontalAccuracy:5,verticalAccuracy:5,timestamp:Date(timeIntervalSince1970:0),phoneSeconds:0)
            self.state.reference=GeoReference(fix:fix,position:.zero,bearing:180,segment:0)
        }
        self.state.reviewing=true;self.state.title="SIMULATED MAP";self.state.tracking="Simulated poses";self.state.selectedAP=1
        self.descriptors[1]=AccessPoint(id:1,bssid:"02:00:00:00:00:01",ssid:"Demo Lab",channel:6,capability:17,beaconInterval:100)
        self.poses=[];self.points=[]
        for i in 0..<160 {
            let t=Double(i)/20;let position=MapPosition(x:cos(t)*2,y:0,z:sin(t)*1.6)
            self.poses.append(MapPose(phoneSeconds:Double(i)*0.2,position:position,transform:[],tracking:"normal",segment:0))
            self.points.append(TrailPoint(id:Int64(i),phoneSeconds:Double(i)*0.2,position:position,segment:0,apID:1,rssi:-45-i/5,uncertaintyMs:4))
        }
        let floorID=UUID(),wallID=UUID()
        self.surfaces[floorID]=SurfacePatch(id:floorID,phoneSeconds:0,segment:0,faces:[
            SurfaceFace(a:MapPosition(x:-3,y:-1.2,z:-2.5),b:MapPosition(x:3,y:-1.2,z:-2.5),c:MapPosition(x:3,y:-1.2,z:2.5),wall:false),
            SurfaceFace(a:MapPosition(x:-3,y:-1.2,z:-2.5),b:MapPosition(x:3,y:-1.2,z:2.5),c:MapPosition(x:-3,y:-1.2,z:2.5),wall:false)
        ],sourceFaceCount:2,sampled:false)
        self.surfaces[wallID]=SurfacePatch(id:wallID,phoneSeconds:0,segment:0,faces:[
            SurfaceFace(a:MapPosition(x:-3,y:-1.2,z:-2.5),b:MapPosition(x:3,y:-1.2,z:-2.5),c:MapPosition(x:3,y:1.5,z:-2.5),wall:true),
            SurfaceFace(a:MapPosition(x:3,y:-1.2,z:-2.5),b:MapPosition(x:3,y:-1.2,z:2.5),c:MapPosition(x:3,y:1.5,z:2.5),wall:true)
        ],sourceFaceCount:2,sampled:false)
        self.state.position=self.poses.last!.position;self.state.rawCount=160;self.state.alignedCount=160;self.state.distance=15;self.state.duration=32;self.state.revision=1;self.heatEnabled=true;self.lastHeatCount = -1;self.publish()
    } }
    #endif
}

final class ARTracker: NSObject, ARSessionDelegate, @unchecked Sendable {
    let session=ARSession()
    let engine: MappingEngine
    private let delegateQueue=DispatchQueue(label:"wifi.mapper.arkit",qos:.userInitiated)
    private var lastFrame=0.0
    private var segment=0
    private var wasNormal=false
    private var pendingMesh: [UUID:(anchor:ARMeshAnchor,seconds:Double,segment:Int)]=[:]
    private var meshOrder: [UUID]=[]
    private var lastMesh=0.0
    init(engine: MappingEngine) { self.engine=engine;super.init();session.delegate=self;session.delegateQueue=delegateQueue }
    func start() {
        let config=ARWorldTrackingConfiguration();config.worldAlignment = .gravity;config.planeDetection=[.horizontal,.vertical]
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {config.sceneReconstruction = .meshWithClassification}
        delegateQueue.async { self.lastFrame=0;self.segment=0;self.wasNormal=false;self.pendingMesh.removeAll();self.meshOrder.removeAll();self.lastMesh=0 }
        session.run(config,options:[.resetTracking,.removeExistingAnchors])
    }
    func stop() { session.pause() }
    func session(_ session: ARSession,didUpdate frame: ARFrame) {
        guard frame.timestamp-lastFrame>=0.045 else { return };lastFrame=frame.timestamp
        let tracking: String
        switch frame.camera.trackingState {
        case .normal:tracking="normal"
        case .notAvailable:tracking="Tracking unavailable"
        case .limited(let reason):
            switch reason { case .initializing:tracking="Move slowly · initializing";case .excessiveMotion:tracking="Move more slowly";case .insufficientFeatures:tracking="Point at textured, well-lit surfaces";case .relocalizing:tracking="Relocalizing · return to the last view";@unknown default:tracking="Tracking limited" }
        }
        let normal=tracking=="normal";if normal && !wasNormal { segment += 1 };wasNormal=normal
        if normal,frame.timestamp-lastMesh>=0.5 {lastMesh=frame.timestamp;captureMesh()}
        let matrix=frame.camera.transform
        let values=(0..<4).flatMap { c in (0..<4).map { r in matrix[c][r] } }
        let position=matrix.columns.3
        engine.ingestPose(MapPose(phoneSeconds:frame.timestamp,position:MapPosition(x:Double(position.x),y:Double(position.y),z:Double(position.z)),transform:values,tracking:tracking,segment:segment))
    }
    func session(_ session: ARSession,didAdd anchors: [ARAnchor]) {queueMeshes(anchors)}
    func session(_ session: ARSession,didUpdate anchors: [ARAnchor]) {queueMeshes(anchors)}
    func session(_ session: ARSession,didRemove anchors: [ARAnchor]) {
        for anchor in anchors where anchor is ARMeshAnchor {
            pendingMesh.removeValue(forKey:anchor.identifier);meshOrder.removeAll {$0==anchor.identifier};engine.removeSurface(anchor.identifier)
        }
    }
    private func queueMeshes(_ anchors: [ARAnchor]) {
        guard wasNormal,let timestamp=session.currentFrame?.timestamp else {return}
        for case let mesh as ARMeshAnchor in anchors {
            if pendingMesh[mesh.identifier]==nil {
                guard meshOrder.count<256 else {continue}
                meshOrder.append(mesh.identifier)
            }
            pendingMesh[mesh.identifier]=(mesh,timestamp,segment)
        }
    }
    private func captureMesh() {
        // At most four anchors per half second, on the AR delegate queue.
        for _ in 0..<min(4,meshOrder.count) {
            let id=meshOrder.removeFirst()
            guard let pending=pendingMesh.removeValue(forKey:id),pending.segment==segment else {continue}
            let anchor=pending.anchor,mesh=anchor.geometry
            guard let classification=mesh.classification,mesh.faces.indexCountPerPrimitive==3 else {continue}
            let step=max(1,Int(ceil(Double(mesh.faces.count)/1500)))
            var faces: [SurfaceFace]=[]
            func vertex(_ index: Int) -> MapPosition {
                let pointer=mesh.vertices.buffer.contents().advanced(by:mesh.vertices.offset+index*mesh.vertices.stride)
                let x=pointer.load(as:Float.self),y=pointer.advanced(by:4).load(as:Float.self),z=pointer.advanced(by:8).load(as:Float.self)
                let p=anchor.transform * SIMD4<Float>(x,y,z,1)
                return MapPosition(x:Double(p.x),y:Double(p.y),z:Double(p.z))
            }
            for face in stride(from:0,to:mesh.faces.count,by:step) {
                let kind=classification.buffer.contents().advanced(by:classification.offset+face*classification.stride).load(as:UInt8.self)
                guard kind==UInt8(ARMeshClassification.floor.rawValue) || kind==UInt8(ARMeshClassification.wall.rawValue) else {continue}
                var indices: [Int]=[]
                for i in 0..<3 {
                    let pointer=mesh.faces.buffer.contents().advanced(by:(face*3+i)*mesh.faces.bytesPerIndex)
                    indices.append(mesh.faces.bytesPerIndex==2 ? Int(pointer.load(as:UInt16.self)) : Int(pointer.load(as:UInt32.self)))
                }
                guard indices.allSatisfy({$0<mesh.vertices.count}) else {continue}
                faces.append(SurfaceFace(a:vertex(indices[0]),b:vertex(indices[1]),c:vertex(indices[2]),wall:kind==UInt8(ARMeshClassification.wall.rawValue)))
            }
            engine.surface(SurfacePatch(id:id,phoneSeconds:pending.seconds,segment:pending.segment,faces:faces,sourceFaceCount:mesh.faces.count,sampled:step>1))
        }
    }
    func sessionWasInterrupted(_ session: ARSession) { wasNormal=false;engine.event("AR interruption","Camera interrupted · no positions assigned") }
    func sessionInterruptionEnded(_ session: ARSession) { wasNormal=false;engine.event("AR resumed","Relocalizing") }
    func session(_ session: ARSession,didFailWithError error: Error) { engine.event("AR error",error.localizedDescription) }
}

@MainActor final class MappingModel: ObservableObject {
    @Published var snapshot=MappingSnapshot()
    @Published var heatEnabled=false { didSet { updateOptions() } }
    @Published var heightSlice=true { didSet { updateOptions() } }
    @Published var heightCenter=0.0 { didSet { updateOptions() } }
    @Published var heatSettings=HeatSettings() { didSet {updateOptions();savePreferences()} }
    @Published var showFloors=true
    @Published var showWalls=true
    @Published var showRoute=true
    @Published var satellite=false
    @Published var satelliteStatus=""
    @Published var geoEnabled=false {didSet {geo.setEnabled(geoEnabled && snapshot.recording)}}
    @Published var northBearing=180.0
    let geo=GeoLocationModel()
    @Published var floorProjection=false
    @Published var surveys: [SurveySummary]=[]
    @Published var cameraError: String?
    @Published var starting=false
    let engine=MappingEngine()
    lazy var tracker=ARTracker(engine:engine)
    private var stopFallback: Task<Void,Never>?
    private(set) var stopRequested=false
    init() {
        if let data=UserDefaults.standard.data(forKey:"heatSettings.v1"),let settings=try? JSONDecoder().decode(HeatSettings.self,from:data) {heatSettings=settings}
        geo.onFix={ [weak engine] fix in engine?.location(fix) }
        updateOptions()
        engine.onSnapshot={ [weak self] value in Task { @MainActor [weak self] in self?.snapshot=value } }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-test-fixture") { heatEnabled=true;satellite=ProcessInfo.processInfo.arguments.contains("--ui-test-geographic-fixture");engine.fixture(geographic:satellite) }
        #endif
    }
    func start(inspector: InspectorModel) {
        guard !snapshot.recording,!starting else { return };starting=true
        guard ARWorldTrackingConfiguration.isSupported else { cameraError="AR world tracking is unavailable on this device.";starting=false;return }
        Task {
            let allowed=AVCaptureDevice.authorizationStatus(for:.video) == .authorized ? true : await AVCaptureDevice.requestAccess(for:.video)
            guard allowed else { cameraError="Allow Camera access in Settings → Apps → wifi mapper to track your position.";starting=false;return }
            engine.begin();tracker.start();geo.setEnabled(geoEnabled);engine.select(inspector.snapshot.selected);heightCenter=0
            if inspector.snapshot.compatible { inspector.engine.capture(true) }
            starting=false
        }
    }
    func stop(inspector: InspectorModel) {
        guard snapshot.recording,!stopRequested else { return };stopRequested=true;engine.beginStopping()
        if inspector.snapshot.compatible { inspector.engine.capture(false) }
        else { completeStop();return }
        stopFallback?.cancel();stopFallback=Task { try? await Task.sleep(for:.seconds(8));guard !Task.isCancelled else { return };engine.event("Drain timeout","Stopped before sensor drain confirmation; retained local measurements");completeStop() }
    }
    func completeStop() { stopRequested=false;stopFallback?.cancel();engine.finish();tracker.stop();geo.setEnabled(false);Task { try? await Task.sleep(for:.milliseconds(300));surveys=SurveyStore.list() } }
    func appBackgrounded(inspector: InspectorModel) { if snapshot.recording { engine.event("Background","Survey ended because app left foreground");inspector.engine.capture(false);completeStop() } }
    func refreshSurveys() { surveys=SurveyStore.list() }
    func registerLocation() {if let fix=geo.fix {engine.register(fix,bearing:northBearing)} }
    private func savePreferences() {if let data=try? JSONEncoder().encode(heatSettings) {UserDefaults.standard.set(data,forKey:"heatSettings.v1")} }
    private func updateOptions() { engine.options(heat:heatEnabled,height:heightSlice ? heightCenter : nil,settings:heatSettings) }
}
