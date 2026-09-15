# gzscript platform support

Support levels (see docs/testing.md for how each is verified):

- **Build**: CI cross/native-compiles the extension for the target.
- **Runtime smoke**: CI runs a Zig script inside Godot on the target
  (`Runtime Smoke / …` jobs: cold compile, warm reuse, source-change
  recompile, explicit destroy, clean shutdown).
- **Fully tested**: the complete integration/lifecycle suite runs there.

| Platform | Arch | Build | Runtime smoke | Fully tested |
| -------- | ---- | ----: | ------------: | -----------: |
| Linux    | x86_64 | ✓ | ✓ | ✓ |
| Linux    | ARM64 | ✓ | ✓ | — |
| macOS    | ARM64 | ✓ | ✓ | — |
| macOS    | x86_64 | ✓ | — | — |
| Windows  | x86_64 | ✓ | ✓ | — |
| Windows  | ARM64 | ✓ | — | — |

Notes:

- Internal arch names are `x86_64`/`aarch64`; they map to upstream
  spellings (`arm64` in `gzscript.gdextension`, `amd64`/`arm64` elsewhere).
- macOS x86_64 has no native Intel CI runner; it is build-only until one
  exists (a Rosetta run would be labeled as such, never as native).
- Windows ARM64 is build-only until a trustworthy native ARM64 CI runner
  with Godot/Zig support is available.
- Only Debug-extension runtime is smoke-tested. Headless Godot loads the
  `template_debug` libraries, so `ReleaseFast` runtime testing needs
  export-template runners (future work); `ReleaseFast` *builds* are verified
  by the build matrix on all six targets.
- ZLS is not required for runtime smoke tests.
