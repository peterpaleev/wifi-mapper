# Wire protocol v1

All integers little endian. Stream header: magic bytes 57 4d, version u8=1, type u8, sequence u32, payload length u16 (0...2048), reserved u16=0. Ordered BLE notifications are chunks of this stream, at most ATT MTU minus 3. Reset stream parser on reconnect. TCP uses identical framing. Reject incompatible version, invalid lengths and malformed records.

Service 8e7a0001-6d52-4f9b-a81c-3f8b2046e001. Characteristics same UUID with 0002 (info read), 0003 (control write), 0004 (data notify). Info, diagnostics and sync replies share the serialized data stream.

Types: 1 hello, 2 info, 3 start (16-byte session UUID), 4 stop, 5 config (u16 dwell ms, u8 first channel, u8 channel count), 6 get config, 7 sync request (u64 phone t1 microseconds), 8 sync response (t1,t2,t3 u64), 9 AP descriptor, 10 observation batch, 11 status, 12 error UTF-8, 13 ACK (u32 batch sequence), 14 stopped, 15 preview.

Info: boot ID u32, protocol u8, firmware major/minor/patch u8 each, MAC 6 bytes, flash bytes u32, PSRAM bytes u32, active session UUID16. Config reply type6 echoes config. Dwell 40...1000 ms; conservative passive channels1...11 by default, user config must remain inside firmware country limits.

Descriptor: apID u16, BSSID6, channel u8, SSID length u8, capability u16, beacon interval u16, SSID bytes (0...32). AP IDs remain stable until reboot. Unknown descriptors are requested with hello and raw observations remain stored.

Batch: count u16 then records of 24 bytes: timestampUs u64, apID u16, RSSI i8, channel u8, secondary u8, subtype u8, signal mode u8, MCS u8, frame length u16, radio timestamp u32, reserved u16. Up to32 records/batch. Each batch is retained until ACK; reconnect/retry can duplicate a sequence, so phone deduplicates by (boot ID, batch sequence, record index). ACK only after durable DB insertion during recording. Descriptor updates are sent before observations.

Status: uptimeUs u64 then u32 received, accepted, filtered, queueDrops, bufferDrops, bufferUsed, bufferCapacity, highWater, transportBytes, reconnects; channel u8, capturing u8, dwell u16, then 11 u64 actual channel dwell microsecond totals. Counters cumulative since boot. Stopped is sent only after RX queue, ring and outstanding ACK drain. No flash observation queue.
