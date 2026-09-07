# Contributing

Read AGENTS.md, docs/STATUS.md and docs/DEVELOPMENT.md. Start with a focused issue or change, use a branch/worktree, and preserve protocol/storage compatibility. Submit a pull request describing the problem, changed behavior, validation, and remaining limitations.

Run tools/test_core.sh; build iOS or firmware when changed. Hardware-dependent results must name the device class and test scope without personal identifiers. Keep original data and test logs local; publish aggregate or synthetic evidence only. Do not attach SSIDs, BSSIDs, room scans, signing material or credentials to public issues.

There is no automatic deployment or firmware flashing in CI. Contributions are under the project's MIT license. Third-party SDKs/components retain their upstream licenses and are downloaded rather than vendored.
