# Spatial layers — version 1.2

## Research and implementation choice

Reviewed Apple documentation on 2026-09-08.

| Approach | What it provides | Decision |
| --- | --- | --- |
| [ARKit classified reconstruction](https://developer.apple.com/documentation/arkit/visualizing-and-interacting-with-a-reconstructed-scene) | LiDAR mesh anchors in the existing AR coordinate system; horizontal/vertical plane detection improves planar reconstruction | Used during the existing survey session; feature-detected with `supportsSceneReconstruction` |
| [ARMeshClassification](https://developer.apple.com/documentation/arkit/armeshclassification) | Per-face labels including floor and wall | Project classified floor triangles onto X/Z; draw projected wall triangles as outlines |
| [RoomPlan](https://developer.apple.com/documentation/roomplan/roomcapturesession) | Structured room capture, coaching and higher-level room elements; can share an ARSession | A future option for clean architectural floor plans. Version 1.2 deliberately delivers observed mesh coverage, not a complete room model |
| [MapKit](https://developer.apple.com/documentation/mapkit/) | Native satellite imagery, gestures, map projection and attribution | Native satellite MKMapView with a survey overlay; no screenshots, tile scraping or imagery export |
| [Core Location permission](https://developer.apple.com/documentation/corelocation/cllocationmanager/requestwheninuseauthorization()) | Foreground location with explicit user consent | Off by default; only active while recording |
| [ARKit gravity and heading](https://developer.apple.com/documentation/arkit/arconfiguration/worldalignment-swift.enum/gravityandheading) | Geographic orientation coupled to location services | Keep existing gravity-only coordinates; use a separate, explicit manual registration instead of changing the raw frame |

## Using the release

Open **Map options → Layers** to show/hide floor surfaces, walls, route/measurements or Apple Maps satellite imagery. On a LiDAR device, start a survey and slowly sweep the camera across floors and walls. Unclassified areas stay blank. These are approximate observed surfaces; sparse mesh sampling and occlusion can leave holes. Non-LiDAR devices retain Wi-Fi and AR trajectory mapping without reconstructed surfaces.

For satellite registration, enable **Geography → Record geographic location**. During a survey, set **Map +Z bearing** to the true bearing of the local map's downward axis; at survey start that axis points behind the camera. Stand still, allow several location/AR samples to arrive, and tap **Register map at current GPS location**. The GPS fix must be less than ten seconds old, have reported horizontal accuracy at most 100 m, and have bracketing normal AR poses within 250 ms in one tracking segment. Accuracy in meters remains visible. Re-register during recording to correct placement or bearing. Saved surveys retain the last registration; old unregistered surveys remain local maps.

This is manual geographic registration, not automatic north calibration or precision indoor positioning. GPS and user bearing errors can shift/rotate the overlay substantially. Short local offsets use a spherical tangent-plane approximation; polar coordinates at or beyond 85° latitude are rejected. Satellite imagery needs network access and is not included in exports. The simulator verified overlay rendering and attribution but displayed placeholder basemap tiles; actual imagery availability remains a device/network acceptance check. The app retains MapKit's attribution and controls.

**Heatmap** options include 0.10/0.25/0.50/1.00 m bins; measured-only, inverse-distance, nearest-neighbor and Gaussian fill; support radius up to 5 m; Signal, Thermal and Ocean palettes; weak/strong dBm limits; opacity; and the existing ±0.75 m height band. Settings persist on the device. Palette/range also apply to the signal trail and legend. Brighter bins contain measurements; lower-opacity cells are estimates. Gaussian uses sigma = radius/3. No algorithm estimates beyond its radius or models wall attenuation. Turning off the height band intentionally projects all retained sample heights onto one map.

## Data and performance contract

New surveys use SQLite schema 2. Existing raw tables and protocol are unchanged; schema 1 remains readable. The append-only `map_layers(kind,payload,phone_s)` table stores LZFSE-compressed JSON mesh observations, JSON removals, optional location fixes and geographic reference revisions. Each row includes a monotonic persistence timestamp; mesh records also carry the observation-frame timestamp. The manifest declares schema 2 and the approximate mesh/geographic semantics. Reopening replays the latest mesh state and reference; ZIP export includes the table. Treat exported mesh and geographic information as private survey data.

Mesh updates are coalesced by anchor on the serial AR delegate queue (256 pending anchors), processed at most four anchors per half second, and sampled to at most 1,500 source faces per anchor update. Only classified floor/wall faces are retained. A record preserves anchor ID, observation-frame monotonic timestamp, tracking segment, world-space vertices, original face count and sampling flag. These are decimated ARKit reconstruction observations, not full raw LiDAR depth frames. Unchanged geometry is skipped. SQLite keeps the accepted updates; the live and reopened mesh retain at most 256 recent anchors and approximately 12,000 displayed triangles, with a visible sampling indication. Wi-Fi callbacks and commit-before-ACK behavior are unchanged.

Heat computation runs on its utility queue. Measured bins have priority in the 20,000-cell output budget. The accumulation has a two-million-operation budget; if exhausted, the result falls back to measured bins and reports a limit rather than displaying partially accumulated estimates. Display bounds are computed off-main. The local Canvas renders asynchronously, and MapKit uses a renderer over immutable snapshots.

## Device acceptance still required

1. On a LiDAR iPhone, scan an L-shaped room and verify floor coverage, projected walls, updates/removals, background/stop and saved-survey reopening.
2. Compare known wall lengths and openings; record mesh gaps and drift without claiming survey-grade accuracy.
3. Deny location permission, then enable it; verify local mapping stays usable. Register outdoors at a known location and bearing, rotate/pan/zoom the satellite map and check alignment and attribution.
4. Repeat with weak indoor GPS, tracking loss, a second floor, no internet and a non-LiDAR device.
5. Run the existing ESP/iPhone drain test and a sustained survey to quantify mesh persistence overhead and RF losses.

Automated/simulator evidence is recorded separately in TESTING.md; it does not prove any of these physical-device results.
