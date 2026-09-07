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
struct HeatmapBuilder {
    struct Key: Hashable { let x: Int, z: Int }
    struct Bin { var sum = 0.0; var count = 0; var mean: Double { sum/Double(count) } }
    /// Inverse-distance weighting of spatial-bin means. No extrapolation beyond radius.
    /// A height slice prevents samples from different floors contaminating one surface.
    static func generate(_ points: [TrailPoint], cellSize: Double = 0.25, radius: Double = 1.5, heightCenter: Double? = nil, maxCells: Int = 20000) -> HeatResult {
        guard cellSize > 0, radius >= cellSize, maxCells > 0 else { return HeatResult(cells: [],resolution:cellSize,limited:false) }
        let filtered = points.filter { p in p.position.x.isFinite && p.position.z.isFinite && p.position.y.isFinite && (heightCenter.map { abs(p.position.y-$0)<=0.75 } ?? true) }
        guard !filtered.isEmpty else { return HeatResult(cells:[],resolution:cellSize,limited:false) }
        var bins: [Key: Bin] = [:]
        for p in filtered {
            let key = Key(x:Int(floor(p.position.x/cellSize)),z:Int(floor(p.position.z/cellSize)))
            bins[key,default:Bin()].sum += Double(p.rssi); bins[key,default:Bin()].count += 1
        }
        let reach = Int(ceil(radius/cellSize))
        var candidates = Set<Key>(), limited = false
        for key in bins.keys.sorted(by: { $0.x == $1.x ? $0.z < $1.z : $0.x < $1.x }) {
            for dx in -reach...reach { for dz in -reach...reach where Double(dx*dx+dz*dz)*cellSize*cellSize <= radius*radius {
                if candidates.count < maxCells { candidates.insert(Key(x:key.x+dx,z:key.z+dz)) } else { limited = true }
            } }
        }
        var cells: [HeatCell] = []; cells.reserveCapacity(candidates.count)
        for key in candidates {
            if let bin = bins[key] {
                cells.append(HeatCell(x:(Double(key.x)+0.5)*cellSize,z:(Double(key.z)+0.5)*cellSize,size:cellSize,rssi:bin.mean,measured:true,support:bin.count)); continue
            }
            var weighted = 0.0, weights = 0.0, support = 0
            for dx in -reach...reach { for dz in -reach...reach {
                let d2 = Double(dx*dx+dz*dz)*cellSize*cellSize
                guard d2 > 0, d2 <= radius*radius, let bin = bins[Key(x:key.x+dx,z:key.z+dz)] else { continue }
                let weight = 1/d2; weighted += bin.mean*weight; weights += weight; support += bin.count
            } }
            if weights > 0 { cells.append(HeatCell(x:(Double(key.x)+0.5)*cellSize,z:(Double(key.z)+0.5)*cellSize,size:cellSize,rssi:weighted/weights,measured:false,support:support)) }
        }
        return HeatResult(cells:cells,resolution:cellSize,limited:limited)
    }
}
/// Same continuous palette in the camera trail, 2D trace and heatmap.
struct SignalPalette {
    static func rgb(_ rssi: Double) -> (Float,Float,Float) {
        let value = max(0,min(1,(rssi+90)/50))
        if value < 0.5 { return (1,Float(value*2),0.15) }
        return (Float(2-2*value),0.95,0.25)
    }
}
