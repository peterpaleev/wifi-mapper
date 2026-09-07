# iOS-specific guidance

Use `tools/build_ios.sh` from the repository root; default is unsigned and needs no Apple account. For device work, copy Config/Local.xcconfig.example to Config/Local.xcconfig and configure your own signing identity; run `tools/build_ios.sh --signed`.

Keep DerivedData outside cloud-synced folders. The wrapper isolates it by checkout path. Use the actual connected device ID, never a committed UDID. Hardware tests require an unlocked iPhone and may interrupt the running app; coordinate ownership before running them.

Preserve Network.framework on-link routing with cellular prohibited. Do not restore requiredInterfaceType.wiredEthernet: it caused a real-iPhone connection failure. Choose a fresh clock candidate at batch receipt rather than rejecting a stale global minimum while newer samples exist.

AR poses are survey-local, gravity-aligned meters. Only interpolate normal poses in the same tracking segment with a bounded gap. Raw SQLite observations precede ACK; derived points are separate. Stop confirmation uses immediate control state, not the throttled UI snapshot.

UI fixtures are Debug-only and visibly simulated. Do not claim AR/USB accuracy from fixture screenshots. `testUSBMappingDrain` requires the real sensor; see STATUS for its pending retest.
