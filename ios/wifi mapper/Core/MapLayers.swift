import Foundation

/// A decimated observation of ARKit's reconstructed mesh, not a surveyed boundary.
struct SurfaceFace: Codable, Equatable, Sendable {
    let a: MapPosition
    let b: MapPosition
    let c: MapPosition
    let wall: Bool
}
struct SurfacePatch: Codable, Sendable, Identifiable {
    let id: UUID
    let phoneSeconds: Double
    let segment: Int
    let faces: [SurfaceFace]
    let sourceFaceCount: Int
    let sampled: Bool
}
struct GeoFix: Codable, Sendable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let horizontalAccuracy: Double
    let verticalAccuracy: Double
    let timestamp: Date
    let phoneSeconds: Double
    var valid: Bool { latitude.isFinite && longitude.isFinite && abs(latitude)<85 && abs(longitude)<=180 && horizontalAccuracy.isFinite && horizontalAccuracy>=0 && horizontalAccuracy<=100 }
}
/// Explicit manual registration: bearing of local +Z clockwise from true north.
/// GPS is never used to modify raw AR poses or Wi-Fi alignment.
struct GeoReference: Codable, Sendable {
    let fix: GeoFix
    let position: MapPosition
    var bearing: Double
    let segment: Int
    func coordinate(_ point: MapPosition) -> (latitude: Double, longitude: Double) {
        let angle=bearing * .pi/180, dx=point.x-position.x, dz=point.z-position.z
        let east = -cos(angle)*dx + sin(angle)*dz
        let north = sin(angle)*dx + cos(angle)*dz
        let latitude=fix.latitude+north/6_378_137*180 / .pi
        let longitude=fix.longitude+east/(6_378_137*cos(fix.latitude * .pi/180))*180 / .pi
        return (latitude,(longitude+540).truncatingRemainder(dividingBy:360)-180)
    }
}
