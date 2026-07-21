# godot-cpp generated bindings

`bindings_4_7_single_64.tar` contains the generated C++ source tree for
godot-cpp revision `ba0edfed90512ec64aba51d4295a3e7e30112f86`, which is also
pinned in `build.zig.zon`.

The host Zig tool verifies the exact extension API, interface, and archive
SHA-256 hashes before extracting the immutable Godot 4.7, single-precision,
64-bit binding snapshot into Zig's build cache. The generated files retain
godot-cpp's MIT license headers.

This snapshot deliberately avoids executing godot-cpp's Python generator in
consumer builds. Replace the archive and update all manifest constants in
`generator.zig` whenever the pinned godot-cpp revision, Godot API, interface,
precision, or pointer width changes.
