import Foundation

struct MapPosition: Codable, Equatable, Sendable {
    var x: Double, y: Double, z: Double
    static let zero = Self(x: 0, y: 0, z: 0)
    func distance(to other: Self) -> Double { sqrt(pow(x-other.x,2)+pow(y-other.y,2)+pow(z-other.z,2)) }
    static func interpolate(_ a: Self, _ b: Self, fraction: Double) -> Self {
        Self(x: a.x+(b.x-a.x)*fraction, y: a.y+(b.y-a.y)*fraction, z: a.z+(b.z-a.z)*fraction)
    }
}
struct MapPose: Codable, Sendable {
    let phoneSeconds: Double
    let position: MapPosition
    let transform: [Float] // Column-major ARKit camera-to-world matrix.
    let tracking: String
    let segment: Int
    var normal: Bool { tracking == "normal" }
}
struct TrailPoint: Identifiable, Codable, Sendable {
    let id: Int64
    let phoneSeconds: Double
    let position: MapPosition
    let segment: Int
    let apID: UInt16
    let rssi: Int
    let uncertaintyMs: Double
}
struct PoseInterpolation {
    static func position(at seconds: Double, in poses: [MapPose], maximumGap: Double = 0.25) -> (MapPosition, Int)? {
        guard seconds.isFinite, poses.count >= 2, seconds >= poses[0].phoneSeconds, seconds <= poses[poses.count-1].phoneSeconds else { return nil }
        var low = 0, high = poses.count-1
        while high-low > 1 { let middle = (low+high)/2; if poses[middle].phoneSeconds <= seconds { low = middle } else { high = middle } }
        let a = poses[low], b = poses[high], gap = b.phoneSeconds-a.phoneSeconds
        guard a.normal, b.normal, a.segment == b.segment, gap > 0, gap <= maximumGap else { return nil }
        return (.interpolate(a.position,b.position,fraction:(seconds-a.phoneSeconds)/gap),a.segment)
    }
}
struct HeatCell: Identifiable, Sendable {
    let x: Double, z: Double, size: Double, rssi: Double
    let measured: Bool
    let support: Int
    var id: String { "\(x):\(z)" }
}
struct HeatResult: Sendable { var cells: [HeatCell]; var resolution: Double; var limited: Bool }
enum HeatAlgorithm: String, Codable, CaseIterable, Sendable {
    case measured = "Measured only", idw = "Inverse distance", nearest = "Nearest neighbor", gaussian = "Gaussian"
}
enum HeatPalette: String, Codable, CaseIterable, Sendable {
    case signal = "Signal", thermal = "Thermal", ocean = "Ocean"
}
struct HeatSettings: Codable, Equatable, Sendable {
    var cellSize = 0.25
    var radius = 1.5
    var algorithm = HeatAlgorithm.idw
    var palette = HeatPalette.signal
    var minimum = -90.0
    var maximum = -40.0
    var opacity = 0.6
}
struct HeatmapBuilder {
    struct Key: Hashable { let x: Int, z: Int }
    struct Bin { var sum = 0.0; var count = 0; var mean: Double { sum/Double(count) } }
    struct Estimate { var sum = 0.0; var weight = 0.0; var nearest = Double.infinity; var value = 0.0; var support = 0 }
    /// Spatial-bin means prevent stationary sampling density from dominating estimates.
    /// Both output and work are bounded; measured bins get priority over estimated cells.
    static func generate(_ points: [TrailPoint], cellSize: Double = 0.25, radius: Double = 1.5, heightCenter: Double? = nil, maxCells: Int = 20000, algorithm: HeatAlgorithm = .idw) -> HeatResult {
        guard cellSize.isFinite, radius.isFinite, cellSize >= 0.1, cellSize <= 5,
              radius >= cellSize, radius <= 5, maxCells > 0,
              heightCenter == nil || heightCenter!.isFinite else { return HeatResult(cells:[],resolution:cellSize,limited:false) }
        let limit = min(maxCells, 20000)
        var bins: [Key: Bin] = [:]
        for p in points where p.position.x.isFinite && p.position.y.isFinite && p.position.z.isFinite && abs(p.position.x) < 1e6 && abs(p.position.z) < 1e6 {
            if let heightCenter, abs(p.position.y-heightCenter)>0.75 { continue }
            let key=Key(x:Int(floor(p.position.x/cellSize)),z:Int(floor(p.position.z/cellSize)))
            bins[key,default:Bin()].sum += Double(p.rssi);bins[key,default:Bin()].count += 1
        }
        let keys=bins.keys.sorted { $0.x == $1.x ? $0.z < $1.z : $0.x < $1.x }
        var limited=keys.count>limit
        var cells=keys.prefix(limit).map { key in
            HeatCell(x:(Double(key.x)+0.5)*cellSize,z:(Double(key.z)+0.5)*cellSize,size:cellSize,rssi:bins[key]!.mean,measured:true,support:bins[key]!.count)
        }
        guard algorithm != .measured, cells.count<limit else { return HeatResult(cells:cells,resolution:cellSize,limited:limited || (algorithm != .measured && !cells.isEmpty)) }
        var estimates: [Key:Estimate]=[:]
        let reach=Int(ceil(radius/cellSize)), capacity=limit-cells.count
        var operations=0
        outer: for source in keys {
            let bin=bins[source]!
            for dx in -reach...reach { for dz in -reach...reach {
                operations += 1
                if operations>2_000_000 { limited=true;break outer }
                let d2=Double(dx*dx+dz*dz)*cellSize*cellSize
                guard d2>0,d2<=radius*radius else { continue }
                let key=Key(x:source.x+dx,z:source.z+dz)
                guard bins[key]==nil else { continue }
                if estimates[key]==nil && estimates.count>=capacity { limited=true;continue }
                var value=estimates[key,default:Estimate()]
                let weight=algorithm == .gaussian ? exp(-d2/(2*pow(radius/3,2))) : 1/d2
                value.sum += bin.mean*weight;value.weight += weight;value.support += bin.count
                if d2<value.nearest {value.nearest=d2;value.value=bin.mean}
                estimates[key]=value
            } }
        }
        // An interrupted accumulation would bias estimates toward earlier bins. Omit it.
        if operations>2_000_000 {return HeatResult(cells:cells,resolution:cellSize,limited:true)}
        for key in estimates.keys.sorted(by: { $0.x == $1.x ? $0.z < $1.z : $0.x < $1.x }) {
            let v=estimates[key]!
            cells.append(HeatCell(x:(Double(key.x)+0.5)*cellSize,z:(Double(key.z)+0.5)*cellSize,size:cellSize,rssi:algorithm == .nearest ? v.value : v.sum/v.weight,measured:false,support:v.support))
        }
        return HeatResult(cells:cells,resolution:cellSize,limited:limited)
    }
}
/// Same continuous palette in the camera trail, 2D trace and heatmap.
struct SignalPalette {
    static func rgb(_ rssi: Double, settings: HeatSettings = HeatSettings()) -> (Float,Float,Float) {
        let value = max(0,min(1,(rssi-settings.minimum)/max(1,settings.maximum-settings.minimum)))
        if settings.palette == .ocean { return (Float(0.1+0.8*value),Float(0.2+0.75*value),Float(0.5+0.4*value)) }
        if settings.palette == .thermal { return (Float(min(1,value*2)),Float(max(0,value*2-1)),Float(0.6*(1-value))) }
        if value < 0.5 { return (1,Float(value*2),0.15) }
        return (Float(2-2*value),0.95,0.25)
    }
}
