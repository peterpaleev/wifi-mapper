# Changelog

## 1.2.0 — Spatial layers and configurable heatmaps

- Add LiDAR-classified floor coverage and wall outlines to the top-down map, with independent layer visibility and unsupported-device messaging.
- Preserve timestamped mesh observations, removals and optional geographic data in schema 2 surveys; reopen/export them while retaining schema 1 compatibility.
- Add opt-in foreground GPS and explicit geographic registration with a user-set true-north bearing.
- Add an Apple Maps satellite layer with projected floor/wall, route and heatmap overlays, native navigation and attribution.
- Add grid resolution, support radius, measured-only/IDW/nearest/Gaussian fill, three palettes, dBm limits, opacity and persistent heatmap preferences.
- Bound interpolation work and prioritize measured bins; discard incomplete estimates when the work budget is exhausted.

The app remains experimental. Mesh geometry is sampled, satellite registration is approximate/manual, and heatmap fill does not model wall attenuation. New LiDAR/GPS behavior needs real-device acceptance. See docs/SPATIAL_LAYERS.md and docs/TESTING.md.

## 1.1 — Spatial Wi-Fi mapping

ARKit tracking, synchronized Wi-Fi trails, height-filtered IDW heatmaps, durable SQLite surveys and ZIP export. See docs/TESTING.md for the original hardware evidence and outstanding USB drain regression.
