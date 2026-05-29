## isonim-render-serve — repo-level Nim config.
##
## Path-based deps so the new RS-M2 GPUI adapter (and its tests) can
## resolve `isonim_gpui/renderer` and the canonical
## `isonim-examples/task_app/` demo modules without nimble installs.
## Mirrors the pattern from `isonim-examples/config.nims`.
##
## The bridge proper (RS-M1) is self-contained — only the new
## `adapters/gpui_adapter.nim` and the RS-M2 integration tests need
## the cross-repo paths below.

switch("path", "$config")
# EPP-M10: the budget test (and any future bare ``nim c -r`` invocation
# from the repo root) needs ``src`` on the import path so
# ``isonim_render_serve/...`` modules resolve without depending on the
# Justfile's explicit ``--path:src --path:tests`` flags. This mirrors
# how the other consumers (``isonim_freya/renderer``,
# ``isonim_gpui/renderer``) are wired in via path extensions.
switch("path", "$config/src")
switch("path", "$config/tests")
switch("path", "$config/../isonim/src")
switch("path", "$config/../nim-everywhere/src")
switch("path", "$config/../nim-stew")
switch("path", "$config/../nim-faststreams")

# RS-M2: GPUI streaming adapter pulls `isonim_gpui/renderer`. The
# renderer FFI loads `libgpui_nim_shim.so` at run time via `dynlib`;
# the `LD_LIBRARY_PATH` (or a copy of the shared object next to the
# binary) must point at `../isonim-gpui/rust/target/debug` for the
# RS-M2 integration tests to actually run. Compile-time resolution
# only needs the path switch below — the flake's shellHook extends
# `LD_LIBRARY_PATH` for run-time loading.
switch("path", "$config/../isonim-gpui/src")

# RS-M4: Freya streaming adapter pulls `isonim_freya/renderer`. As
# with the GPUI shim, run-time loading needs `LD_LIBRARY_PATH` to
# include `../isonim-freya/rust/target/debug`; the flake's
# shellHook handles that.
switch("path", "$config/../isonim-freya/src")

# RS-M5 (partial-linux): Cocoa adapter pulls `isonim_cocoa/renderer`.
# `nim check` on this Linux host accepts the renderer module (no
# AppKit-link-time symbols are needed until the macOS engineer wires
# up `bitmapImageRepForCachingDisplayInRect` per the recipe in
# `src/isonim_render_serve/adapters/cocoa_adapter.nim`). The cross-
# compile gate test (`tests/test_cocoa_adapter_compile.nim`) drives
# `nim check --os:macosx` over the adapter to catch AppKit-side
# surface drift from this Linux host. Run-time AppKit linking is the
# macOS engineer's responsibility; no `LD_LIBRARY_PATH` extension is
# needed on Linux (the Linux scaffold returns placeholder pixels and
# never touches AppKit).
switch("path", "$config/../isonim-cocoa/src")

# RS-M6 (partial-linux): Android adapter pulls `isonim_android/renderer`.
# `nim check` on this Linux host accepts the renderer module when the
# adapter is compiled with the plain Linux build (no `-d:mockJni` /
# `-d:commandBuffer` needed) because the Android adapter sources gate
# every renderer-touching call site behind `when defined(android)` —
# the Linux scaffold returns placeholder pixels and never touches JNI.
# The cross-compile gate test (`tests/test_android_adapter_compile.nim`)
# drives `nim check --os:android -d:mockJni` over the adapter from this
# Linux host to catch Android-runtime-side surface drift. Two paths are
# required because `isonim_android/renderer` lives under
# `isonim-android/nim-lib/src/isonim_android/`, separate from the
# `isonim-android/src/` directory that holds the broader package —
# same pair EX-M6 used in `isonim-examples/config.nims`. No
# `LD_LIBRARY_PATH` extension is needed on Linux (the Linux scaffold
# never touches the JNI bridge / Android NDK).
switch("path", "$config/../isonim-android/nim-lib/src")
switch("path", "$config/../isonim-android/src")

# RS-M2: the streaming integration test instantiates the canonical
# GPUI task_app demo (the EX-M3 composition root at
# `task_app/main_gpui.nim`) as the frame source. Pulling the demo
# requires both the `isonim-examples` repo root (which holds the
# `task_app/` tree directly — `isonim_examples.nimble` declares no
# `srcDir`) and `isonim-tui/src` for the TerminalRenderer surface
# imports transitively reached by the EX-M3 cross-renderer
# infrastructure.
switch("path", "$config/../isonim-examples")
switch("path", "$config/../isonim-tui/src")
switch("path", "$config/../nim-termctl/src")
switch("path", "$config/../nim-pty/src")
