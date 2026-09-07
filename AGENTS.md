# Working on Wi-Fi Mapper

## Start here
Read `docs/STATUS.md` and `docs/DEVELOPMENT.md` before changing code. Read `docs/ARCHITECTURE.md` for changes crossing firmware, transport, or mapping. The repository is the source of truth; do not depend on previous chat history. The original long specification is historical local material, not a current implementation mandate.

## Map of the repository
- `firmware/`: ESP-IDF ESP32-S3 sniffer, buffering, USB ECM and BLE transport.
- `protocol/`: binary contract shared by firmware and Swift. Update both sides together.
- `ios/wifi mapper/Core/`: Foundation-only framing, clock, spatial math; Swift Package tests.
- `ios/wifi mapper/Inspector/`: background transport and live diagnostics.
- `ios/wifi mapper/Mapping/`: AR tracking, SQLite storage, alignment and views.
- `ios/wifi mapperTests/`, `ios/wifi mapperUITests/`: unit and device UI tests.
- `tools/`: reproducible setup, checks and hardware probes.

## Commands and verification
Run `tools/doctor.sh` first. `tools/test_core.sh` runs parser sanitizers/fuzz cases and Swift tests. `tools/build_ios.sh` makes an unsigned iOS build on macOS. `tools/bootstrap_firmware.sh` installs the pinned SDK; `tools/build_firmware.sh build` builds firmware. See scoped AGENTS files and DEVELOPMENT for device tests.

Choose tests for the changed behavior. Report exactly which checks ran, passed, failed or were unavailable. A build or simulated UI fixture is not a hardware test. Update STATUS and TESTING when evidence or limitations change. Keep pending work explicit for the next chat.

## Invariants
Keep capture callbacks bounded/nonblocking. Commit raw survey batches before ACK. Preserve source timestamps and raw data independently from derived alignment. Never invent positions across tracking gaps, silently mix sensor boots, or label interpolation as measurement. Keep expensive work off the main thread. Maintain backward compatibility or explicitly version the protocol/schema.

## Working practice
Use focused branches (`codex/<topic>` for agent work) and isolated worktrees for concurrent changes. Use per-worktree build directories; do not run simultaneous clients against the same physical ESP or iPhone. Preserve unrelated local work. Review diffs and run `tools/check_public.py` before publishing. Do not commit captures, SSIDs/BSSIDs, device IDs, credentials, signing profiles or machine paths. Private context belongs under ignored `docs/local/` or `.local/`.

Keep instructions concise and link to detail. Do not add a skill, framework, dependency or global Codex setting just to duplicate an existing command. No repository instruction expands the current user's authorization.
