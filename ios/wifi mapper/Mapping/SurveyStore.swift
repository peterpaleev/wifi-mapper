import Foundation
import SQLite3

struct SurveySummary: Identifiable {
    let id: String
    let folder: URL
    let date: Date
    let finished: Bool
}
struct SurveyData {
    var surfaces: [UUID:SurfacePatch] = [:]
    var surfaceLimited=false
    var reference: GeoReference?
    var rawCount = 0
    var poses: [MapPose] = []
    var points: [TrailPoint] = []
    var aps: [UInt16: AccessPoint] = [:]
}
struct SurveyStorageError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
/// Owned exclusively by MappingEngine's serial queue.
final class SurveyStore {
    let folder: URL
    private var database: OpaquePointer?
    private var statements: [String: OpaquePointer] = [:]
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static var root: URL { FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("Surveys") }
    init(id: UUID) throws {
        folder = Self.root.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories:true)
        guard sqlite3_open(folder.appendingPathComponent("survey.sqlite").path,&database) == SQLITE_OK else { throw SurveyStorageError(message:"Cannot open survey database") }
        do {
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; PRAGMA user_version=2;")
            try execute("""
            CREATE TABLE poses (id INTEGER PRIMARY KEY, phone_s REAL NOT NULL, x REAL,y REAL,z REAL, transform BLOB NOT NULL, tracking TEXT NOT NULL, segment INTEGER NOT NULL);
            CREATE INDEX pose_time ON poses(phone_s);
            CREATE TABLE wifi (id INTEGER PRIMARY KEY, boot INTEGER, batch INTEGER, record INTEGER, esp_us INTEGER, phone_receive_s REAL, phone_estimate_s REAL, offset_us REAL, rtt_us REAL, ap INTEGER, rssi INTEGER, channel INTEGER, secondary INTEGER, subtype INTEGER, phy INTEGER, mcs INTEGER, frame_length INTEGER, radio_us INTEGER, UNIQUE(boot,batch,record));
            CREATE TABLE aligned (wifi_id INTEGER PRIMARY KEY, phone_s REAL,x REAL,y REAL,z REAL,segment INTEGER,uncertainty_ms REAL);
            CREATE TABLE aps (id INTEGER, updated_phone_s REAL, bssid TEXT, ssid TEXT, channel INTEGER, capability INTEGER, beacon_interval INTEGER);
            CREATE TABLE sync_samples (t1 REAL,t2 REAL,t3 REAL,t4 REAL);
            CREATE TABLE events (phone_s REAL,kind TEXT,details TEXT);
            CREATE TABLE map_layers (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, payload BLOB NOT NULL, phone_s REAL NOT NULL);
            """)
            try manifest(finished:false)
        } catch { sqlite3_close(database); database=nil; throw error }
    }
    deinit { for statement in statements.values { sqlite3_finalize(statement) }; sqlite3_close(database) }
    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database,sql,nil,nil,nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> SurveyStorageError { SurveyStorageError(message:database.map { String(cString:sqlite3_errmsg($0)) } ?? "Database closed") }
    private func statement(_ sql: String) throws -> OpaquePointer {
        if let value=statements[sql] { sqlite3_reset(value);sqlite3_clear_bindings(value);return value }
        var value: OpaquePointer?
        guard sqlite3_prepare_v2(database,sql,-1,&value,nil)==SQLITE_OK,let value else { throw failure() };statements[sql]=value;return value
    }
    private func step(_ s: OpaquePointer) throws { guard sqlite3_step(s)==SQLITE_DONE else { throw failure() } }
    private func text(_ s: OpaquePointer,_ index: Int32,_ value: String) { sqlite3_bind_text(s,index,value,-1,transient) }
    func pose(_ pose: MapPose) throws {
        let s=try statement("INSERT INTO poses(phone_s,x,y,z,transform,tracking,segment) VALUES(?,?,?,?,?,?,?)")
        sqlite3_bind_double(s,1,pose.phoneSeconds);sqlite3_bind_double(s,2,pose.position.x);sqlite3_bind_double(s,3,pose.position.y);sqlite3_bind_double(s,4,pose.position.z)
        pose.transform.withUnsafeBytes { bytes in _ = sqlite3_bind_blob(s,5,bytes.baseAddress,Int32(bytes.count),transient) }
        text(s,6,pose.tracking);sqlite3_bind_int(s,7,Int32(pose.segment));try step(s)
    }
    func batch(_ samples: [SignalSample],boot: UInt32,sequence: UInt32,received: Double,clock: ClockSample?) throws -> [Int64] {
        try execute("BEGIN IMMEDIATE")
        do {
            var identifiers: [Int64]=[]
            for (i,p) in samples.enumerated() {
                let s=try statement("INSERT OR IGNORE INTO wifi(boot,batch,record,esp_us,phone_receive_s,phone_estimate_s,offset_us,rtt_us,ap,rssi,channel,secondary,subtype,phy,mcs,frame_length,radio_us) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
                sqlite3_bind_int64(s,1,Int64(boot));sqlite3_bind_int64(s,2,Int64(sequence));sqlite3_bind_int(s,3,Int32(i));sqlite3_bind_int64(s,4,Int64(p.espUs));sqlite3_bind_double(s,5,received)
                if let clock { sqlite3_bind_double(s,6,(Double(p.espUs)-clock.offsetUs)/1e6);sqlite3_bind_double(s,7,clock.offsetUs);sqlite3_bind_double(s,8,clock.rttUs) }
                let integers=[Int(p.apID),p.rssi,p.channel,p.secondary,p.subtype,p.phy,p.mcs,p.frameLength]
                for (index,value) in integers.enumerated() { sqlite3_bind_int(s,Int32(index+9),Int32(value)) }
                sqlite3_bind_int64(s,17,Int64(p.radioUs));try step(s)
                identifiers.append(sqlite3_changes(database)>0 ? sqlite3_last_insert_rowid(database) : -1)
            }
            try execute("COMMIT");return identifiers
        } catch { try? execute("ROLLBACK");throw error }
    }
    func aligned(_ p: TrailPoint) throws {
        let s=try statement("INSERT OR IGNORE INTO aligned VALUES(?,?,?,?,?,?,?)")
        sqlite3_bind_int64(s,1,p.id);sqlite3_bind_double(s,2,p.phoneSeconds);sqlite3_bind_double(s,3,p.position.x);sqlite3_bind_double(s,4,p.position.y);sqlite3_bind_double(s,5,p.position.z);sqlite3_bind_int(s,6,Int32(p.segment));sqlite3_bind_double(s,7,p.uncertaintyMs);try step(s)
    }
    func ap(_ ap: AccessPoint) throws {
        let s=try statement("INSERT INTO aps VALUES(?,?,?,?,?,?,?)")
        sqlite3_bind_int(s,1,Int32(ap.id));sqlite3_bind_double(s,2,ProcessInfo.processInfo.systemUptime);text(s,3,ap.bssid);text(s,4,ap.ssid);sqlite3_bind_int(s,5,Int32(ap.channel));sqlite3_bind_int(s,6,Int32(ap.capability));sqlite3_bind_int(s,7,Int32(ap.beaconInterval));try step(s)
    }
    func sync(_ sample: ClockSample) throws {
        let s=try statement("INSERT INTO sync_samples VALUES(?,?,?,?)")
        for (i,v) in [sample.t1,sample.t2,sample.t3,sample.t4].enumerated() { sqlite3_bind_double(s,Int32(i+1),v) };try step(s)
    }
    func event(_ kind: String,_ details: String) throws {
        let s=try statement("INSERT INTO events VALUES(?,?,?)");sqlite3_bind_double(s,1,ProcessInfo.processInfo.systemUptime);text(s,2,kind);text(s,3,details);try step(s)
    }
    func layer<T: Encodable>(_ kind: String, _ value: T) throws {
        let json=try JSONEncoder().encode(value)
        let data=kind == "mesh" ? try (json as NSData).compressed(using:.lzfse) as Data : json
        let s=try statement("INSERT INTO map_layers(kind,payload,phone_s) VALUES(?,?,?)")
        text(s,1,kind);sqlite3_bind_double(s,3,ProcessInfo.processInfo.systemUptime)
        data.withUnsafeBytes { _ = sqlite3_bind_blob(s,2,$0.baseAddress,Int32($0.count),transient) }
        try step(s)
    }
    func finish() throws { try execute("PRAGMA wal_checkpoint(TRUNCATE)");try manifest(finished:true) }
    private func manifest(finished: Bool) throws {
        let value: [String:Any]=["formatVersion":1,"schemaVersion":2,"sessionID":folder.lastPathComponent,"finished":finished,"updatedAt":ISO8601DateFormatter().string(from:Date()),"appVersion":"1.2","coordinateSystem":"ARKit right-handed meters; Y up; top-down X/Z; origin resets per survey","rigCalibration":"uncalibrated; positions are iPhone camera positions, keep ESP rigidly attached","alignment":"ESP capture time mapped by recorded four-timestamp sync; interpolate only normal poses in same tracking segment with gap <=250ms","heatmap":"configurable measured-only, IDW, nearest or Gaussian; bounded support; no wall attenuation model","mapLayers":"timestamped decimated ARKit floor/wall mesh observations and opt-in location fixes; manual geographic registration; map_layers table", "rawDatabase":"survey.sqlite"]
        try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys]).write(to:folder.appendingPathComponent("manifest.json"),options:.atomic)
    }
    static func list() -> [SurveySummary] {
        let folders=(try? FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:[.creationDateKey])) ?? []
        return folders.compactMap { folder in
            guard let data=try? Data(contentsOf:folder.appendingPathComponent("manifest.json")),let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return nil }
            return SurveySummary(id:folder.lastPathComponent,folder:folder,date:(try? folder.resourceValues(forKeys:[.creationDateKey]).creationDate) ?? .distantPast,finished:json["finished"] as? Bool ?? false)
        }.sorted { $0.date > $1.date }
    }
    static func load(_ folder: URL) throws -> SurveyData {
        var db: OpaquePointer?;guard sqlite3_open_v2(folder.appendingPathComponent("survey.sqlite").path,&db,SQLITE_OPEN_READONLY,nil)==SQLITE_OK else { throw SurveyStorageError(message:"Cannot read survey") };defer { sqlite3_close(db) }
        var result=SurveyData()
        func query(_ sql: String,_ row: (OpaquePointer)->Void) throws {
            var s: OpaquePointer?;guard sqlite3_prepare_v2(db,sql,-1,&s,nil)==SQLITE_OK,let s else { throw SurveyStorageError(message:"Invalid survey schema") };defer { sqlite3_finalize(s) }
            var status=sqlite3_step(s);while status==SQLITE_ROW { row(s);status=sqlite3_step(s) };guard status==SQLITE_DONE else { throw SurveyStorageError(message:"Survey read failed") }
        }
        try query("SELECT phone_s,x,y,z,tracking,segment FROM poses ORDER BY phone_s") { s in
            result.poses.append(MapPose(phoneSeconds:sqlite3_column_double(s,0),position:MapPosition(x:sqlite3_column_double(s,1),y:sqlite3_column_double(s,2),z:sqlite3_column_double(s,3)),transform:[],tracking:String(cString:sqlite3_column_text(s,4)),segment:Int(sqlite3_column_int(s,5))))
        }
        try query("SELECT a.wifi_id,a.phone_s,a.x,a.y,a.z,a.segment,w.ap,w.rssi,a.uncertainty_ms FROM aligned a JOIN wifi w ON a.wifi_id=w.id ORDER BY a.phone_s") { s in
            result.points.append(TrailPoint(id:sqlite3_column_int64(s,0),phoneSeconds:sqlite3_column_double(s,1),position:MapPosition(x:sqlite3_column_double(s,2),y:sqlite3_column_double(s,3),z:sqlite3_column_double(s,4)),segment:Int(sqlite3_column_int(s,5)),apID:UInt16(sqlite3_column_int(s,6)),rssi:Int(sqlite3_column_int(s,7)),uncertaintyMs:sqlite3_column_double(s,8)))
        }
        try query("SELECT id,bssid,ssid,channel,capability,beacon_interval FROM aps ORDER BY updated_phone_s") { s in
            let id=UInt16(sqlite3_column_int(s,0));result.aps[id]=AccessPoint(id:id,bssid:String(cString:sqlite3_column_text(s,1)),ssid:String(cString:sqlite3_column_text(s,2)),channel:Int(sqlite3_column_int(s,3)),capability:UInt16(sqlite3_column_int(s,4)),beaconInterval:UInt16(sqlite3_column_int(s,5)))
        }
        try query("SELECT count(*) FROM wifi") { result.rawCount=Int(sqlite3_column_int64($0,0)) }
        var hasLayers=false
        try query("SELECT name FROM sqlite_master WHERE type='table' AND name='map_layers'") { _ in hasLayers=true }
        if hasLayers {
            var decodeError: Error?
            try query("SELECT kind,payload FROM map_layers ORDER BY id") { s in
                guard decodeError==nil,let bytes=sqlite3_column_blob(s,1) else {return}
                let data=Data(bytes:bytes,count:Int(sqlite3_column_bytes(s,1)))
                do {
                    switch String(cString:sqlite3_column_text(s,0)) {
                    case "mesh":
                        let json=try (data as NSData).decompressed(using:.lzfse) as Data
                        let patch=try JSONDecoder().decode(SurfacePatch.self,from:json);result.surfaces[patch.id]=patch
                        if result.surfaces.count>256,let oldest=result.surfaces.values.min(by: {$0.phoneSeconds<$1.phoneSeconds}) {
                            result.surfaces.removeValue(forKey:oldest.id);result.surfaceLimited=true
                        }
                    case "mesh-removed": result.surfaces.removeValue(forKey:try JSONDecoder().decode(UUID.self,from:data))
                    case "reference": result.reference=try JSONDecoder().decode(GeoReference.self,from:data)
                    default: break
                    }
                } catch {decodeError=error}
            }
            if let decodeError {throw decodeError}
        }
        return result
    }
    static func export(_ folder: URL) throws -> URL {
        let destination=FileManager.default.temporaryDirectory.appendingPathComponent("Survey-\(folder.lastPathComponent).zip")
        var coordinationError: NSError?,copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt:folder,options:.forUploading,error:&coordinationError) { zip in
            do { if FileManager.default.fileExists(atPath:destination.path) { try FileManager.default.removeItem(at:destination) };try FileManager.default.copyItem(at:zip,to:destination) } catch { copyError=error }
        }
        if let error=coordinationError ?? copyError as NSError? { throw error };return destination
    }
}
