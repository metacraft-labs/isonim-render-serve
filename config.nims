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

# ELT-M8: WebP-lossless production transport is the SHIP tier per the
# ELT-M7 synthesis report. The codec adapter is gated behind
# ``-d:withCodecWebP``; we default it ON at the config level so every
# ``nim c`` invocation through this repo (tests, launcher composition
# via ``isonim-examples``, the standalone bridge CLI) compiles the
# W-packet path in unconditionally. Disabling (e.g. for a minimal
# Linux scaffold build that doesn't ship ffmpeg) is a per-invocation
# ``--define:withCodecWebP=false`` flag.
switch("define", "withCodecWebP")

# FUH-M5: in-process libwebp encoder. Default-on so every launcher
# binary built through this repo (test suite, the standalone bridge
# CLI, the per-backend launchers in ``isonim-examples``) prefers the
# direct API call over the ~133 ms ffmpeg subprocess spawn that the
# FUH-M4 audit measured. The runtime probe in
# ``adapters/webp_libwebp_ffi.isLibwebpAvailable`` falls back to the
# subprocess path when ``libwebp.dylib`` / ``libwebp.so.7`` can't be
# loaded (e.g. minimal CI host without libwebp), so toggling this
# off is rarely needed; the escape hatch is
# ``--define:withInProcessWebP=false``.
switch("define", "withInProcessWebP")

## Worktree-local nimcache: every Nim compile inside this checkout keeps its
## intermediate files (its nimcache) INSIDE this checkout.
##
## WHY.  Nim's default nimcache is `$XDG_CACHE_HOME/nim/<project>_d` (`_r` for
## -d:release; `%USERPROFILE%\nimcache\<project>_d` on Windows).  It is keyed by
## the project NAME only, and the generated file names inside it do not depend
## on the checkout path either.  So two worktrees or clones of this repository
## that build the same project at the same time write, compile and link each
## other's intermediate files.  Measured on 2026-09-26 in a sibling repository:
## ten concurrent builds of two worktrees that differed in a few places gave
## four correct binaries, two that exited 0 with the OTHER worktree's code
## linked in (one of them a mix of both), two compile failures on
## half-rewritten generated C and two link failures.
##
## WHAT.  `<checkout>/.nimcache/<directory of the main module, relative to the
## checkout>/<module name><suffix>`, where the suffix is Nim's own: `_check`
## for `nim check`, `_r` for -d:release or -d:danger, `_d` otherwise.  The
## directory is part of the key, so same-named modules in different directories
## no longer share a cache either.  Only the intermediates move; build outputs
## stay where they were.  An explicit `--nimcache:` on the command line still
## wins, because Nim applies the command line again after the config files.
## `nim js` and project-less invocations are left alone.
##
## HOW IT IS PICKED UP.  Nim runs the `config.nims` of every PARENT directory of
## the compiled module, outermost first, then the one in the module's own
## directory.  So this file applies to every compile under this checkout,
## `just`, `nimble`, CI and a bare `nim c` alike, whatever the working directory.
## `--skipParentCfg` switches it off for modules below the checkout root, so a
## recipe that passes that flag must name its own checkout-local `--nimcache:`.
## Nothing in this repository passes `--skipParentCfg` today.
## `tests/test_nimcache_is_worktree_local.nim` checks the layout, and fails if the
## config is bypassed; its `--skipParentCfg` negative control proves the probe
## can see a shared cache at all.
##
## WINDOWS.  Nim turns the `/` below into `\` on a Windows host.  The layout adds
## `\.nimcache\<module dir>\<module>_d\` in front of Nim's own object file names,
## so keep the checkout root short (about 80 characters) to stay inside MAX_PATH.
block worktreeLocalNimcache:
  var project = projectName()
  if project.len > 4 and project[^4 .. ^1] == ".nim":
    project = project[0 ..< ^4]
  # No project (`nim dump` with no file): nothing to place.  The JS backend
  # has its own convention (a cache next to its output).  `nim e` never
  # generates C, so it never creates the directory.
  if project.len == 0 or getCommand() == "js":
    break worktreeLocalNimcache

  # Plain "/" joins, NOT std/os `/`: NimScript's `/` follows the TARGET OS,
  # so a `--os:windows` cross-compile on a POSIX host would get backslashes.
  let root = thisDir()
  let projDir = projectDir()
  var rel = ""
  if projDir.len >= root.len and projDir[0 ..< root.len] == root:
    rel = projDir[root.len .. ^1]
  else:
    # Cannot happen for a project Nim found this file for (this file is read
    # because it sits in a parent of the project directory).  Stay inside
    # the checkout and stay unique anyway.
    rel = "_outside/"
    for c in projDir:
      rel.add(if c in {'/', '\\', ':'}: '_' else: c)
  while rel.len > 0 and rel[0] in {'/', '\\'}:
    rel = rel[1 .. ^1]

  let suffix =
    if getCommand() == "check": "_check"
    elif defined(release) or defined(danger): "_r"
    else: "_d"
  var cacheDir = root & "/.nimcache"
  if rel.len > 0:
    cacheDir.add("/" & rel)
  switch("nimcache", cacheDir & "/" & project & suffix)
