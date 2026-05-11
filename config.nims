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
