import SwiftUI
import MapKit
import CoreLocation
import Combine

@MainActor final class GeoLocationModel: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var fix: GeoFix?
    @Published var status="Location is off"
    private let manager=CLLocationManager()
    private var enabled=false
    var onFix: ((GeoFix)->Void)?
    override init() {super.init();manager.delegate=self;manager.desiredAccuracy=kCLLocationAccuracyBest;manager.distanceFilter=1}
    func setEnabled(_ value: Bool) {
        enabled=value
        if !value {manager.stopUpdatingLocation();fix=nil;status="Location is off";return}
        switch manager.authorizationStatus {
        case .notDetermined:status="Waiting for location permission";manager.requestWhenInUseAuthorization()
        case .authorizedAlways,.authorizedWhenInUse:status="Acquiring location…";manager.startUpdatingLocation()
        case .denied,.restricted:status="Location unavailable · enable access in Settings"
        @unknown default:status="Location unavailable"
        }
    }
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {if enabled {setEnabled(true)}}
    func locationManager(_ manager: CLLocationManager,didUpdateLocations locations: [CLLocation]) {
        guard enabled,let location=locations.last else {return}
        let age=Date().timeIntervalSince(location.timestamp)
        guard age>=0,age<10 else {status="Waiting for a fresh location";return}
        let value=GeoFix(latitude:location.coordinate.latitude,longitude:location.coordinate.longitude,altitude:location.altitude,horizontalAccuracy:location.horizontalAccuracy,verticalAccuracy:location.verticalAccuracy,timestamp:location.timestamp,phoneSeconds:ProcessInfo.processInfo.systemUptime-age)
        guard value.valid else {status="Location accuracy is insufficient (need ≤100 m)";return}
        fix=value;status=String(format:"GPS ±%.0f m · altitude %.0f m",value.horizontalAccuracy,value.altitude);onFix?(value)
    }
    func locationManager(_ manager: CLLocationManager,didFailWithError error: Error) {status=error.localizedDescription}
}

struct GeographicMap: UIViewRepresentable {
    let snapshot: MappingSnapshot
    let settings: HeatSettings
    let floors: Bool
    let walls: Bool
    let route: Bool
    @Binding var status: String
    var fitRevision=0
    func makeCoordinator() -> Coordinator {Coordinator(status:$status)}
    func makeUIView(context: Context) -> MKMapView {
        let view=MKMapView();view.accessibilityIdentifier="satelliteMap";view.mapType = .satellite;view.isPitchEnabled=false;view.delegate=context.coordinator
        return view
    }
    func updateUIView(_ view: MKMapView,context: Context) {
        guard let reference=snapshot.reference else {return}
        let c=context.coordinator
        let contentKey="\(snapshot.folder?.lastPathComponent ?? ""):\(snapshot.poses.last?.phoneSeconds ?? 0):\(snapshot.revision):\(snapshot.layerRevision):\(snapshot.heat.cells.count):\(settings):\(floors):\(walls):\(route):\(reference.fix.timestamp):\(reference.bearing):\(fitRevision)"
        guard c.contentKey != contentKey else {return};c.contentKey=contentKey
        // A renderer owns immutable survey data; MapKit projects it as the map pans/zooms.
        if let old=c.overlay {view.removeOverlay(old)}
        let overlay=SurveyMapOverlay(snapshot:snapshot,settings:settings,floors:floors,walls:walls,route:route)
        c.overlay=overlay;view.addOverlay(overlay,level:.aboveRoads)
        let key="\(snapshot.folder?.lastPathComponent ?? ""):\(reference.fix.timestamp):\(reference.bearing):\(fitRevision)"
        if c.referenceKey != key {
            c.referenceKey=key
            let coordinates=(snapshot.mapBounds.isEmpty ? snapshot.poses.map(\.position) : snapshot.mapBounds.flatMap {p in snapshot.mapBounds.map {MapPosition(x:p.x,y:0,z:$0.z)}}).map {reference.coordinate($0)}
            var rect=MKMapRect.null
            for coordinate in coordinates {
                let p=MKMapPoint(CLLocationCoordinate2D(latitude:coordinate.latitude,longitude:coordinate.longitude))
                rect=rect.union(MKMapRect(x:p.x,y:p.y,width:1,height:1))
            }
            if rect.isNull || rect.size.width<1 {view.setRegion(MKCoordinateRegion(center:overlay.coordinate,latitudinalMeters:80,longitudinalMeters:80),animated:false)}
            else {
                let padding=max(2/MKMetersPerMapPointAtLatitude(reference.fix.latitude),max(rect.width,rect.height)*0.15)
                view.setVisibleMapRect(rect.insetBy(dx:-padding,dy:-padding),edgePadding:UIEdgeInsets(top:80,left:30,bottom:80,right:30),animated:false)
            }
        }
    }
    final class Coordinator: NSObject, MKMapViewDelegate {
        var status: Binding<String>
        init(status: Binding<String>) {self.status=status}
        func mapViewWillStartLoadingMap(_ mapView: MKMapView) {status.wrappedValue="Loading satellite imagery…"}
        func mapViewDidFinishRenderingMap(_ mapView: MKMapView,fullyRendered: Bool) {
            if fullyRendered {status.wrappedValue="";mapView.accessibilityValue="Satellite imagery ready"}
        }
        func mapViewDidFailLoadingMap(_ mapView: MKMapView,withError error: Error) {status.wrappedValue="Satellite imagery unavailable · check internet"}

        var overlay: SurveyMapOverlay?
        var referenceKey=""
        var contentKey=""
        func mapView(_ mapView: MKMapView,rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let overlay=overlay as? SurveyMapOverlay else {return MKOverlayRenderer(overlay:overlay)}
            return SurveyMapRenderer(overlay:overlay)
        }
    }
}
final class SurveyMapOverlay: NSObject, MKOverlay {
    let snapshot: MappingSnapshot
    let settings: HeatSettings
    let floors: Bool, walls: Bool, route: Bool
    var coordinate: CLLocationCoordinate2D {CLLocationCoordinate2D(latitude:snapshot.reference!.fix.latitude,longitude:snapshot.reference!.fix.longitude)}
    var boundingMapRect: MKMapRect { .world }
    init(snapshot: MappingSnapshot,settings: HeatSettings,floors: Bool,walls: Bool,route: Bool) {
        self.snapshot=snapshot;self.settings=settings;self.floors=floors;self.walls=walls;self.route=route
    }
}
final class SurveyMapRenderer: MKOverlayRenderer {
    override func draw(_ mapRect: MKMapRect,zoomScale: MKZoomScale,in context: CGContext) {
        guard let data=overlay as? SurveyMapOverlay,let reference=data.snapshot.reference else {return}
        func project(_ p: MapPosition) -> CGPoint {
            let coordinate=reference.coordinate(p)
            return point(for:MKMapPoint(CLLocationCoordinate2D(latitude:coordinate.latitude,longitude:coordinate.longitude)))
        }
        func color(_ rssi: Double,_ alpha: Double) -> CGColor {
            let c=SignalPalette.rgb(rssi,settings:data.settings)
            return CGColor(red:CGFloat(c.0),green:CGFloat(c.1),blue:CGFloat(c.2),alpha:alpha)
        }
        func polygon(_ points: [MapPosition],fill: CGColor?,stroke: CGColor?=nil,width: Double=1) {
            guard let first=points.first else {return}
            context.beginPath();context.move(to:project(first));for p in points.dropFirst() {context.addLine(to:project(p))}
            if let fill {context.closePath();context.setFillColor(fill);context.fillPath()}
            else if let stroke {context.setStrokeColor(stroke);context.setLineWidth(width/zoomScale);context.strokePath()}
        }
        // Floors below RF estimates; walls above them. No attenuation is inferred.
        if data.floors {
            for patch in data.snapshot.surfaces {for face in patch.faces where !face.wall {polygon([face.a,face.b,face.c],fill:CGColor(gray:0.85,alpha:0.2))}}
        }
        for cell in data.snapshot.heat.cells {
            let h=cell.size/2
            polygon([MapPosition(x:cell.x-h,y:0,z:cell.z-h),MapPosition(x:cell.x+h,y:0,z:cell.z-h),MapPosition(x:cell.x+h,y:0,z:cell.z+h),MapPosition(x:cell.x-h,y:0,z:cell.z+h)],fill:color(cell.rssi,data.settings.opacity*(cell.measured ? 1 : 0.5)))
        }
        if data.walls {
            for patch in data.snapshot.surfaces {for face in patch.faces where face.wall {polygon([face.a,face.b,face.c,face.a],fill:nil,stroke:CGColor(red:0.25,green:0.9,blue:1,alpha:0.8),width:2)}}
        }
        if data.route {
            for (a,b) in zip(data.snapshot.poses,data.snapshot.poses.dropFirst()) where a.normal && b.normal && a.segment==b.segment {
                polygon([a.position,b.position],fill:nil,stroke:CGColor(gray:1,alpha:0.5),width:2)
            }
            for p in data.snapshot.points {
                let point=project(p.position),r=2.5/zoomScale
                context.setFillColor(color(Double(p.rssi),1));context.fillEllipse(in:CGRect(x:point.x-r,y:point.y-r,width:r*2,height:r*2))
            }
        }
    }
}

struct GeoLayerOptions: View {
    @ObservedObject var mapping: MappingModel
    @ObservedObject var geo: GeoLocationModel
    var body: some View {
        Toggle("Record geographic location",isOn:$mapping.geoEnabled)
        Text(mapping.geoEnabled && !mapping.snapshot.recording ? "Location starts with your next survey." : geo.status).font(.caption).foregroundStyle(.secondary)
        if let reference=mapping.snapshot.reference {
            Text(String(format:"Reference %.5f, %.5f · ±%.0f m",reference.fix.latitude,reference.fix.longitude,reference.fix.horizontalAccuracy)).font(.caption.monospaced())
            Text(String(format:"Registered +Z bearing: %.0f°",reference.bearing)).font(.caption)
        }
        Stepper(String(format:"Map +Z bearing: %.0f° true",mapping.northBearing),value:$mapping.northBearing,in:0...360,step:5)
        Button("Register map at current GPS location") {mapping.registerLocation()}
            .disabled(!mapping.snapshot.recording || !mapping.geoEnabled || geo.fix==nil)
        Text("Set the true bearing of the map’s downward (+Z) axis, then register while standing still. At survey start +Z points behind the camera. GPS may be several meters off indoors. Registration uses the AR pose at the GPS timestamp; it does not move saved measurements.").font(.caption).foregroundStyle(.secondary)
    }
}
