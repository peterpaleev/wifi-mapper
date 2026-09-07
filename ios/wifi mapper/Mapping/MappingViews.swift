import SwiftUI
import ARKit
import SceneKit

private func signalColor(_ rssi: Double) -> Color { let c=SignalPalette.rgb(rssi);return Color(red:Double(c.0),green:Double(c.1),blue:Double(c.2)) }
private let mapAccent=Color(red:0.2,green:0.86,blue:0.91)

struct SurveyView: View {
    @ObservedObject var mapping: MappingModel
    @ObservedObject var inspector: InspectorModel
    @State private var mode=0
    @State private var showOptions=false
    @State private var showSurveys=false
    @State private var confirmNew=false
    var body: some View {
        NavigationStack {
            VStack(spacing:0) {
                HStack {
                    Picker("Map view",selection:$mode) { Label("Camera",systemImage:"camera").tag(0);Label("Top down",systemImage:"map").tag(1) }.pickerStyle(.segmented)
                    Button { showOptions=true } label: { Image(systemName:"slider.horizontal.3").padding(8) }.accessibilityLabel("Map options")
                }.padding(.horizontal).padding(.vertical,8)
                networkBar
                ZStack(alignment:.topLeading) {
                    CameraTrailView(tracker:mapping.tracker,poses:mapping.snapshot.poses,points:mapping.snapshot.points,revision:mapping.snapshot.revision,projectToFloor:mapping.floorProjection)
                        .overlay(alignment:.center) { if !mapping.snapshot.recording { cameraEmpty } }
                        .opacity(mode==0 && !mapping.snapshot.reviewing ? 1 : 0)
                        .allowsHitTesting(mode==0 && !mapping.snapshot.reviewing)
                    if mode==1 || mapping.snapshot.reviewing {
                        TopDownMap(poses:mapping.snapshot.poses,points:mapping.snapshot.points,cells:mapping.snapshot.heat.cells,position:mapping.snapshot.position)
                    }
                    VStack(alignment:.leading,spacing:8) {
                        trackingBadge
                        if mapping.snapshot.recording && mapping.snapshot.alignedCount==0 {
                            Text(inspector.snapshot.compatible ? "Waiting for synchronized Wi-Fi samples" : "Position tracking active · connect ESP for signal colors")
                                .font(.caption).padding(9).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:10))
                        }
                        if mapping.snapshot.reviewing { Text(mapping.snapshot.title).font(.caption.bold()).padding(9).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:10)) }
                    }.padding(12)
                    VStack { Spacer();HStack { signalLegend;Spacer() } }.padding(12).allowsHitTesting(false)
                }.clipped()
                bottomPanel
            }
            .background(Color.black).navigationTitle("Wi-Fi Mapper").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.topBarTrailing) { Button { mapping.refreshSurveys();showSurveys=true } label:{Image(systemName:"folder")} .accessibilityLabel("Saved surveys") } }
            .sheet(isPresented:$showOptions) { options }
            .sheet(isPresented:$showSurveys) { surveyList }
            .confirmationDialog("Start a new survey with a new coordinate origin? The current survey stays saved.",isPresented:$confirmNew) { Button("Start new survey") { mode=0;mapping.start(inspector:inspector) } }
            .alert("Mapping",isPresented:Binding(get:{mapping.cameraError != nil || mapping.snapshot.error != nil},set:{if !$0 {mapping.cameraError=nil;mapping.engine.clearError()}})) { Button("OK") {mapping.cameraError=nil;mapping.engine.clearError()} } message:{Text(mapping.cameraError ?? mapping.snapshot.error ?? "")}
            .onChange(of:mapping.snapshot.reviewing) { _,value in if value {mode=1} }
            .onChange(of:mapping.snapshot.recording) { old,value in if old && !value {mode=1} }
        }
    }
    private var networkBar: some View {
        HStack(spacing:6) {
            Circle().fill(inspector.snapshot.compatible ? mapAccent : .orange).frame(width:6,height:6)
            if mapping.snapshot.reviewing {
                Picker("Survey network",selection:Binding(get:{mapping.snapshot.selectedAP ?? 0},set:{mapping.engine.select($0)})) {
                    ForEach(mapping.snapshot.aps) { ap in Text(ap.title).tag(ap.id) }
                }.labelsHidden().pickerStyle(.menu)
            } else if inspector.snapshot.aps.isEmpty {
                Text(inspector.snapshot.connection).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !inspector.snapshot.compatible { Button("Connect USB") { inspector.engine.connect(host:inspector.host) }.font(.caption.bold()) }
            } else {
                Picker("Wi-Fi network",selection:Binding(get:{inspector.snapshot.selected ?? inspector.snapshot.aps[0].id},set:{inspector.engine.select($0);mapping.engine.select($0)})) {
                    ForEach(inspector.snapshot.aps) { row in Text("\(row.ap.title) · \(row.ap.bssid.suffix(5))").tag(row.id) }
                }.labelsHidden().pickerStyle(.menu)
                Spacer()
                Text(inspector.snapshot.latest.map{"\($0.rssi) dBm"} ?? "—").font(.caption.monospaced().bold()).foregroundStyle(mapAccent)
            }
        }.padding(.horizontal).frame(minHeight:38).background(Color.white.opacity(0.04))
    }
    private var trackingBadge: some View {
        HStack(spacing:7) {
            Image(systemName:mapping.snapshot.tracking=="normal" ? "viewfinder" : "viewfinder.circle")
            Text(mapping.snapshot.tracking=="normal" ? "Tracking position" : mapping.snapshot.tracking)
        }.font(.caption.weight(.semibold)).foregroundStyle(mapping.snapshot.tracking=="normal" ? .green : .orange)
            .padding(9).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:10))
    }
    private var cameraEmpty: some View {
        VStack(spacing:14) {
            Image(systemName:"viewfinder").font(.system(size:44)).foregroundStyle(mapAccent)
            Text("Map your Wi-Fi in space").font(.title3.bold())
            Text("Start a survey and walk slowly. Turn back to see your colored trail in the room, or switch to Top down.").font(.subheadline).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Text("Keep the ESP32 fixed relative to the phone.").font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(maxWidth:340).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:24)).padding()
    }
    private var signalLegend: some View {
        VStack(alignment:.leading,spacing:4) {
            HStack(spacing:0) { ForEach(0..<50,id:\.self) { i in signalColor(Double(i)-90).frame(width:3,height:5) } }.clipShape(Capsule())
            HStack { Text("−90 weak");Spacer();Text("−40 strong") }.font(.system(size:9,design:.monospaced)).frame(width:150)
            Text(mapping.heatEnabled && mode==1 ? "Heatmap: estimated · 1.5 m support" : "Gray: trajectory without aligned signal").font(.system(size:9))
        }.padding(9).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:10))
    }
    private var bottomPanel: some View {
        VStack(spacing:10) {
            HStack {
                metric(String(format:"%.1f m",mapping.snapshot.distance),"distance")
                Spacer();metric("\(mapping.snapshot.alignedCount)","mapped samples")
                Spacer();metric(String(format:"%02d:%02d",Int(mapping.snapshot.duration)/60,Int(mapping.snapshot.duration)%60),"survey time")
            }
            HStack(spacing:12) {
                Button {
                    if mapping.snapshot.recording {mapping.stop(inspector:inspector)}
                    else if mapping.snapshot.folder != nil {confirmNew=true}
                    else {mapping.start(inspector:inspector)}
                } label:{Label(mapping.snapshot.stopping ? "Finishing…" : mapping.snapshot.recording ? "Stop & save" : mapping.starting ? "Opening camera…" : "Start survey",systemImage:mapping.snapshot.recording ? "stop.fill" : "record.circle") .frame(maxWidth:.infinity).padding(.vertical,6)}
                    .buttonStyle(.borderedProminent).tint(mapping.snapshot.recording ? .red : mapAccent).disabled(mapping.starting || mapping.snapshot.stopping).accessibilityIdentifier("surveyButton")
                Toggle(isOn:$mapping.heatEnabled) {Image(systemName:"square.3.layers.3d")}.toggleStyle(.button).tint(mapAccent).accessibilityLabel("Live heatmap")
            }
            if mapping.snapshot.rawCount>0 && mapping.snapshot.unalignedCount>0 { Text("\(mapping.snapshot.unalignedCount) observations kept without a valid pose").font(.caption2).foregroundStyle(.orange) }
        }.padding(.horizontal,16).padding(.vertical,12).background(Color(white:0.075))
    }
    private func metric(_ value: String,_ title: String) -> some View {VStack(alignment:.leading,spacing:2) {Text(value).font(.headline.monospacedDigit());Text(title).font(.caption2).foregroundStyle(.secondary)}}
    private var options: some View {
        NavigationStack {
            Form {
                Section("Live surface") {
                    Toggle("Generate live heatmap",isOn:$mapping.heatEnabled)
                    Toggle("Keep one height level",isOn:$mapping.heightSlice)
                    if mapping.heightSlice { Stepper(String(format:"Height center: %.1f m ± 0.75 m",mapping.heightCenter),value:$mapping.heightCenter,in:-20...20,step:0.5) }
                    Text("0.25 m spatial bins, inverse-distance interpolation within 1.5 m. Estimates do not model walls. Measured trail points remain visible.").font(.caption).foregroundStyle(.secondary)
                    if mapping.snapshot.heat.limited {Text("Surface limit reached. Raw data remains saved.").foregroundStyle(.orange)}
                }
                Section("Sensor") {
                    Button("Lock radio to selected network") {
                        if let row=inspector.snapshot.aps.first(where: { $0.id==inspector.snapshot.selected }), (1...11).contains(row.ap.channel) { inspector.engine.configure(dwell:80,channel:row.ap.channel) }
                    }.disabled(!inspector.snapshot.compatible || inspector.snapshot.selected==nil)
                    Text("A fixed channel gives denser signal measurements. Use Controls to return to discovery sweep.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Camera trail") {
                    Toggle("Project trail below the phone",isOn:$mapping.floorProjection)
                    Text("Display projection places the trail 1.2 m below the survey origin. It is not a measured floor. Saved 3D positions remain unchanged.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Position and quality") {
                    Text(String(format:"x %.2f m · y %.2f m · z %.2f m",mapping.snapshot.position.x,mapping.snapshot.position.y,mapping.snapshot.position.z)).font(.caption.monospaced())
                    LabeledContent("Tracking gaps",value:"\(mapping.snapshot.trackingGaps)")
                    LabeledContent("Raw Wi-Fi samples",value:"\(mapping.snapshot.rawCount)")
                    LabeledContent("Aligned samples",value:"\(mapping.snapshot.alignedCount)")
                    Text("ARKit coordinates are relative to this survey. ESP antenna offset is uncalibrated. Start a new survey after a sensor reboot.").font(.caption).foregroundStyle(.secondary)
                }
                if let folder=mapping.snapshot.folder,!mapping.snapshot.recording {
                    Section("Saved survey") {
                        Button("Prepare full survey export") {mapping.engine.export()}
                        if let url=mapping.snapshot.exportURL {ShareLink(item:url){Label("Share survey ZIP",systemImage:"square.and.arrow.up")}}
                        Text(folder.lastPathComponent).font(.caption2.monospaced())
                    }
                }
            }.navigationTitle("Map options").toolbar {Button("Done"){showOptions=false}}
        }
    }
    private var surveyList: some View {
        NavigationStack {
            List {
                if mapping.surveys.isEmpty {ContentUnavailableView("No saved surveys",systemImage:"map",description:Text("Stop a survey to save its trace and raw measurements."))}
                ForEach(mapping.surveys) { (survey: SurveySummary) in
                    Button {mapping.engine.load(survey.folder);showSurveys=false;mode=1} label:{
                        VStack(alignment:.leading,spacing:5) {Text(survey.date.formatted(date:.abbreviated,time:.shortened));Text(survey.finished ? "Saved · open map" : "Interrupted · recover recorded data").font(.caption).foregroundStyle(survey.finished ? Color.secondary : Color.orange)}
                    }.disabled(mapping.snapshot.recording)
                }
            }.navigationTitle("Surveys").toolbar {Button("Done"){showSurveys=false}}
        }
    }
}

struct TopDownMap: View {
    let poses: [MapPose]
    let points: [TrailPoint]
    let cells: [HeatCell]
    let position: MapPosition
    @State private var zoom=1.0
    @State private var pan=CGSize.zero
    @GestureState private var drag=CGSize.zero
    @GestureState private var magnification=1.0
    @State private var inspected: TrailPoint?
    var body: some View {
        GeometryReader { geometry in
            let viewport=MapViewport(positions:poses.map(\.position)+points.map(\.position),size:geometry.size,zoom:zoom*magnification,pan:CGSize(width:pan.width+drag.width,height:pan.height+drag.height))
            Canvas {context,size in
                context.fill(Path(CGRect(origin:.zero,size:size)),with:.color(Color(red:0.035,green:0.055,blue:0.075)))
                let step=max(0.5,pow(10,floor(log10(max(0.1,viewport.span/10)))))
                let lowerX=floor(viewport.center.x-viewport.span),upperX=ceil(viewport.center.x+viewport.span)
                if (upperX-lowerX)/step<250 {
                    for x in stride(from:lowerX,through:upperX,by:step) {
                        var path=Path();path.move(to:viewport.project(MapPosition(x:x,y:0,z:viewport.center.z-viewport.span*2)));path.addLine(to:viewport.project(MapPosition(x:x,y:0,z:viewport.center.z+viewport.span*2)));context.stroke(path,with:.color(.white.opacity(0.07)),lineWidth:0.5)
                    }
                    for z in stride(from:floor(viewport.center.z-viewport.span),through:ceil(viewport.center.z+viewport.span),by:step) {
                        var path=Path();path.move(to:viewport.project(MapPosition(x:viewport.center.x-viewport.span*2,y:0,z:z)));path.addLine(to:viewport.project(MapPosition(x:viewport.center.x+viewport.span*2,y:0,z:z)));context.stroke(path,with:.color(.white.opacity(0.07)),lineWidth:0.5)
                    }
                }
                for cell in cells {
                    let center=viewport.project(MapPosition(x:cell.x,y:0,z:cell.z));let side=cell.size*viewport.scale
                    context.fill(Path(CGRect(x:center.x-side/2,y:center.y-side/2,width:side+0.3,height:side+0.3)),with:.color(signalColor(cell.rssi).opacity(cell.measured ? 0.62 : 0.3)))
                }
                for (a,b) in zip(poses,poses.dropFirst()) where a.segment==b.segment && a.normal && b.normal {
                    var path=Path();path.move(to:viewport.project(a.position));path.addLine(to:viewport.project(b.position));context.stroke(path,with:.color(.white.opacity(0.3)),lineWidth:2)
                }
                for (a,b) in zip(points,points.dropFirst()) where a.segment==b.segment && b.phoneSeconds-a.phoneSeconds<2 && a.position.distance(to:b.position)<2 {
                    var path=Path();path.move(to:viewport.project(a.position));path.addLine(to:viewport.project(b.position));context.stroke(path,with:.color(signalColor(Double(b.rssi))),lineWidth:3)
                }
                for p in points {let xy=viewport.project(p.position);context.fill(Path(ellipseIn:CGRect(x:xy.x-2,y:xy.y-2,width:4,height:4)),with:.color(signalColor(Double(p.rssi))))}
                let current=viewport.project(position);context.fill(Path(ellipseIn:CGRect(x:current.x-6,y:current.y-6,width:12,height:12)),with:.color(mapAccent));context.stroke(Path(ellipseIn:CGRect(x:current.x-8,y:current.y-8,width:16,height:16)),with:.color(.white),lineWidth:1.5)
                if let origin=poses.first {context.draw(Text("START").font(.system(size:9,weight:.bold)).foregroundColor(.white),at:viewport.project(origin.position),anchor:.bottomTrailing)}
            }
            .gesture(DragGesture().updating($drag){v,s,_ in s=v.translation}.onEnded {pan.width += $0.translation.width;pan.height += $0.translation.height})
            .simultaneousGesture(MagnificationGesture().updating($magnification){v,s,_ in s=v}.onEnded {zoom=max(0.25,min(12,zoom*$0))})
            .simultaneousGesture(SpatialTapGesture().onEnded {event in inspected=points.min { hypot(viewport.project($0.position).x-event.location.x,viewport.project($0.position).y-event.location.y)<hypot(viewport.project($1.position).x-event.location.x,viewport.project($1.position).y-event.location.y) } })
            .overlay(alignment:.topTrailing) {Button {zoom=1;pan = .zero;inspected=nil} label:{Image(systemName:"arrow.up.left.and.arrow.down.right").padding(10).background(.ultraThinMaterial,in:Circle())}.padding(12).accessibilityLabel("Fit map")}
            .overlay(alignment:.bottomTrailing) {
                VStack(alignment:.trailing,spacing:5) {
                    if let inspected {Text("\(inspected.rssi) dBm").font(.headline);Text(String(format:"x %.2f · z %.2f m",inspected.position.x,inspected.position.z)).font(.caption2.monospaced())}
                    let unit=pow(10,floor(log10(80/viewport.scale)))
                    let meters=unit * (80/viewport.scale/unit>=5 ? 5 : 80/viewport.scale/unit>=2 ? 2 : 1)
                    Rectangle().fill(.white).frame(width:meters*viewport.scale,height:2)
                    Text(String(format:"%g m · X/Z",meters)).font(.caption2.monospaced())
                }.padding(9).background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:10)).padding(12)
            }
            .overlay {if poses.isEmpty {ContentUnavailableView("Your route appears here",systemImage:"point.topleft.down.curvedto.point.bottomright.up",description:Text("Start a survey and move slowly. Pinch to zoom, drag to pan, tap to inspect a measurement.")).allowsHitTesting(false)}}
        }.accessibilityElement(children:.contain).accessibilityIdentifier("topDownMap")
    }
}
private struct MapViewport {
    let center: MapPosition
    let scale: Double
    let span: Double
    let size: CGSize
    let pan: CGSize
    init(positions: [MapPosition],size: CGSize,zoom: Double,pan: CGSize) {
        let minX=positions.map(\.x).min() ?? -2,maxX=positions.map(\.x).max() ?? 2,minZ=positions.map(\.z).min() ?? -2,maxZ=positions.map(\.z).max() ?? 2
        center=MapPosition(x:(minX+maxX)/2,y:0,z:(minZ+maxZ)/2);span=max(5,max(maxX-minX,maxZ-minZ)+3)
        scale=max(1,min(size.width,size.height)*0.85/span)*zoom;self.size=size;self.pan=pan
    }
    func project(_ p: MapPosition) -> CGPoint {CGPoint(x:size.width/2+(p.x-center.x)*scale+pan.width,y:size.height/2+(p.z-center.z)*scale+pan.height)}
}

struct CameraTrailView: UIViewRepresentable {
    let tracker: ARTracker
    let poses: [MapPose]
    let points: [TrailPoint]
    let revision: Int
    let projectToFloor: Bool
    func makeUIView(context:Context) -> ARSCNView {
        let view=ARSCNView(frame:.zero);view.session=tracker.session;view.session.delegate=tracker;view.scene=SCNScene();view.automaticallyUpdatesLighting=false;view.preferredFramesPerSecond=60
        view.scene.rootNode.addChildNode(context.coordinator.trail);view.scene.rootNode.addChildNode(context.coordinator.route)
        return view
    }
    func makeCoordinator() -> Coordinator {Coordinator()}
    func updateUIView(_ view: ARSCNView,context:Context) {
        let c=context.coordinator
        let key="\(revision):\(points.count):\(poses.count):\(projectToFloor)"
        guard key != c.key,ProcessInfo.processInfo.systemUptime-c.lastBuild>0.4 else {return};c.key=key;c.lastBuild=ProcessInfo.processInfo.systemUptime
        let floor=(poses.first?.position.y ?? 0)-1.2
        c.trail.geometry=Self.geometry(points:points.map {($0.position,$0.segment,$0.phoneSeconds,SignalPalette.rgb(Double($0.rssi)))},radius:0.018,floor:projectToFloor ? floor : nil)
        c.route.geometry=Self.geometry(points:poses.map {($0.position,$0.normal ? $0.segment : -1,$0.phoneSeconds,(Float(0.45),Float(0.48),Float(0.52)))},radius:0.005,floor:projectToFloor ? floor : nil)
    }
    final class Coordinator {let trail=SCNNode();let route=SCNNode();var key="";var lastBuild=0.0}
    /// Small hexagonal tubes render an anchored 3D trail in two draw calls.
    private static func geometry(points:[(MapPosition,Int,Double,(Float,Float,Float))],radius:Float,floor:Double?) -> SCNGeometry? {
        guard points.count>1 else {return nil}
        var vertices:[SCNVector3]=[],colors:[Float]=[],indices:[UInt32]=[]
        let display=points.count>2500 ? points.enumerated().filter {$0.offset%Int(ceil(Double(points.count)/2500))==0}.map(\.element) : points
        for (a,b) in zip(display,display.dropFirst()) {
            guard a.1>=0,a.1==b.1,b.2-a.2<2,a.0.distance(to:b.0)<2,a.0.distance(to:b.0)>0.005 else {continue}
            let start=SIMD3<Float>(Float(a.0.x),Float(floor ?? a.0.y),Float(a.0.z)),end=SIMD3<Float>(Float(b.0.x),Float(floor ?? b.0.y),Float(b.0.z))
            let delta=end-start;guard simd_length(delta)>0.001 else {continue};let direction=simd_normalize(delta)
            let reference=abs(direction.y)>0.9 ? SIMD3<Float>(1,0,0) : SIMD3<Float>(0,1,0)
            let u=simd_normalize(simd_cross(direction,reference))*radius,v=simd_normalize(simd_cross(direction,u))*radius
            let base=UInt32(vertices.count)
            for (center,color) in [(start,a.3),(end,b.3)] {
                for side in 0..<6 {let angle=Float(side)*Float.pi/3;let p=center+cos(angle)*u+sin(angle)*v;vertices.append(SCNVector3(p.x,p.y,p.z));colors.append(contentsOf:[color.0,color.1,color.2,1])}
            }
            for side:UInt32 in 0..<6 {let next=(side+1)%6;indices.append(contentsOf:[base+side,base+next,base+6+side,base+next,base+6+next,base+6+side])}
        }
        guard !vertices.isEmpty else {return nil}
        let colorData=colors.withUnsafeBytes {Data($0)}
        let colorSource=SCNGeometrySource(data:colorData,semantic:.color,vectorCount:vertices.count,usesFloatComponents:true,componentsPerVector:4,bytesPerComponent:4,dataOffset:0,dataStride:16)
        let geometry=SCNGeometry(sources:[SCNGeometrySource(vertices:vertices),colorSource],elements:[SCNGeometryElement(indices:indices,primitiveType:.triangles)])
        let material=SCNMaterial();material.lightingModel = .constant;material.diffuse.contents=UIColor.white;material.isDoubleSided=true;geometry.materials=[material];return geometry
    }
}
