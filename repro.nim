## Reprobuild project file for isonim-render-serve.
##
## **Library-first topological bootstrap for the isonim ecosystem.**
## ``isonim-render-serve`` is the WebSocket bridge for the IsoNim
## *render-stream* protocol: a self-contained F/M/I packet codec
## (``src/isonim_render_serve/packet.nim`` + the ``packet_video`` /
## ``packet_webp`` companions), an RFC 6455 frame codec vendored from
## isonim-tui-serve (``ws_frame.nim``), an element-tree diff/delta layer
## (``diff_region``, ``element_tree_delta``, ``element_tree_attrs``), the
## event-dispatch + story-dispatch overlays, and the async server that
## streams frames to a browser ``<canvas>`` (``bridge.nim`` +
## ``src/isonim_render_serve.nim``).
##
## **Why library-first.** The facade ``src/isonim_render_serve.nim`` is a
## Linux LEAF at the LIBRARY level: it imports ONLY its own
## ``./isonim_render_serve/*`` submodules (packet / ws_frame /
## event_dispatch / diff_region / element_tree_* / story_dispatch /
## launcher_sinks / bridge) plus the ``h264_videotoolbox_encoder``
## adapter — and that encoder's ``isonim_cocoa`` import is
## ``when defined(macosx)``-gated (a Linux stub), so NO workspace sibling
## is reached from the library closure on this Linux host. The nimble
## file only ``requires "nim >= 2.0.0"``. This makes the ``library
## isonim_render_serve`` edge the bootstrap ANCHOR that isonim's ``src``
## can depend on before the rest of the mutually-recursive isonim
## renderer repos land — exactly the leaf that unblocks the ecosystem.
##
## A Mode 1 / Mode 3 hybrid (per
## ``reprobuild-specs/Three-Mode-Convention-System.md``) modelled on the
## canonical leaf recipes ``nim-libvterm/repro.nim`` and the just-landed
## sibling ``isonim-tui-serve/repro.nim`` (whose bridge-serial pool for
## its async-server test is the closest template here):
##
## * Declares the upstream tool floor via ``uses:`` so any future
##   consumer (isonim's ``src``, the per-backend launchers in
##   isonim-examples) picks up the same toolchain the nimble file's
##   ``requires "nim >= 2.0.0"`` implies.
## * Declares ``library isonim_render_serve`` — the importable umbrella is
##   ``src/isonim_render_serve.nim`` (consumers ``import
##   isonim_render_serve``); the submodules under
##   ``src/isonim_render_serve/`` are importable too.
## * Emits, per LEAF test file under ``tests/``, a BUILD edge
##   (``buildNimUnittest.build``) that compiles ``build/test-bin/<stem>``
##   and an EXECUTE edge (``edge.testBinary.run``) that runs it — the
##   two-edge test template from ``reprobuild-specs/Package-Model.md``
##   §"The test template". BUILD halves collect into ``test-builds``;
##   EXECUTE halves into ``test`` so ``repro build test`` / ``repro
##   test`` materialise the runnable closure (each execute edge
##   transitively depends on its build edge).
##
## **Compile flags.** Each BUILD edge reproduces the repo's DEFAULT
## matrix point — ``just test`` → ``test-orc`` → ``_matrix orc release
## on`` → ``nim c … --mm:orc -d:release --threads:on``: ``--mm:orc`` via
## ``mm:``, ``-d:release`` via ``defines:``, ``--threads:on`` via the
## wrapper's default ``threadsOn`` (this repo's async bridge +
## subprocess codec paths use ``asyncdispatch`` / ``osproc``, so
## ``--threads:on`` is meaningful). ``--path:src --path:tests`` is
## threaded via the edge's ``paths:`` slot (``src`` is also carried in
## ``extraInputs`` so the whole module tree is a declared input). The
## repo SHIPS a ``config.nims`` that nim reads from the repo tree at
## compile time; it lifts ``-d:withCodecWebP`` + ``-d:withInProcessWebP``
## (so the WebP encoder facade + in-process libwebp FFI are compiled in)
## and adds sibling ``--path:`` switches for not-yet-landed renderer
## repos — the latter are missing-dir path switches that nim ignores
## with a warning, so the LEAF closure still compiles cleanly on this
## host. The ``--styleCheck:usages --styleCheck:error`` switches from
## ``nim-flags`` are style toggles that don't change the produced binary
## and aren't part of the typed ``nim c`` surface, so they're omitted —
## the corpus compiles + runs identically.
##
## **Codec provisioning.** The nix dev shell supplies ``libwebp`` on
## ``LD_LIBRARY_PATH`` (flake ``packages``), so the in-process libwebp
## FFI (``adapters/webp_libwebp_ffi.nim``) is LIVE and the WebP codec
## tests exercise the real encoder. The shell does NOT ship ``ffmpeg``,
## so the subprocess-fallback arms of the WebP tests
## (``test_webp_inprocess_subprocess_parity`` and the ffmpeg-only cases
## in ``test_webp_encoder_lifecycle`` / ``test_webp_inprocess_encoder_*``)
## call ``skip()`` — they are NOT weakened, only skipped when both
## backends can't run; the in-process path still runs to exit 0. Every
## WebP test therefore exits 0 on this host whether or not ffmpeg is
## present. (Adding ``ffmpeg`` to the flake would light up the
## subprocess-parity arms; that's a flake edit, out of scope for this
## recipe.)
##
## **Serialization pool (capacity-1).** Three classes of execute edge are
## routed through a single capacity-1 pool (mirroring isonim-tui-serve's
## ``bridge-serial`` pool) so they run with scheduler headroom:
##
##   1. BRIDGE tests — spawn a real ``asynchttpserver`` on a best-effort
##      ephemeral port and drive it with a hand-rolled WebSocket client
##      (``tests/ws_test_client.nim``); concurrent runs starve the async
##      dispatcher and race the ephemeral-port pick.
##   2. WebP-lifecycle tests — fork ``ffmpeg`` child processes on their
##      non-skipped arms.
##   3. Wall-clock LATENCY-BUDGET tests
##      (``test_element_tree_delta_budget``,
##      ``test_webp_inprocess_encoder_budget``) — assert a per-call /
##      per-frame time budget that is meaningless under CPU contention;
##      running them alongside 7 other parallel edges inflates the
##      measured median past budget (observed: 12.6 ms clean vs a >16 ms
##      failure under load).
##
## This changes ONLY scheduling — no ``check`` / budget is skipped,
## relaxed, or removed; every pooled test runs in full to exit 0. The
## pure-codec / diff / codec-roundtrip / in-process-lifecycle execute
## edges and every BUILD (compile) edge stay unpooled and parallel.
##
## ---------------------------------------------------------------------
## SECOND PASS — sibling-dependent tests RE-ENABLED (renderer siblings
## have now landed their ``library`` edges).
## ---------------------------------------------------------------------
##
## The renderer siblings this repo consumes from source now each ship a
## landed ``repro.nim`` ``library`` export: ``isonim`` (``library
## isonim``), ``isonim-gpui`` (``library isonim_gpui``), ``isonim-freya``
## (``library isonim_freya``), ``isonim-cocoa`` (``library
## isonim_cocoa``), plus ``nim-everywhere`` (``library nim_everywhere``).
## They are named in the ``uses:`` block below (SC-11 develop-mode
## from-source consumption), so reprobuild builds each from source and
## folds it into the lock. The ``isonim-android`` renderer declares NO
## ``library`` export (its ``package isonim_android`` block has only
## ``uses: isonim``), and the ``task_app/*`` demo tree (isonim-examples,
## whose library is exported at the repo ROOT and which declares ``uses:
## "isonim-render-serve"`` back) is NOT consumed as a ``uses:`` edge here
## — pulling it recurses its whole downstream demo graph. Both arrive via
## the committed ``config.nims`` ``--path:`` switches instead (exactly as
## ``isonim-examples/config.nims`` threads the android roots); the demo /
## android modules are plain Nim sources on the path, so no producer
## sub-build is needed for them.
##
## FOURTEEN previously-deferred test files are RE-ENABLED in
## ``renderServeTestSpecs`` below (verified BUILD + RUN green under the
## repo's default ``nim c --mm:orc -d:release --threads:on -r`` matrix
## point on this Linux host):
##
##   * gpui:  test_gpui_adapter_element_tree, test_gpui_adapter_real_pixels,
##            test_gpui_adapter_streams_task_app (pooled — async server),
##            test_gpui_input_routes_to_fireevent (pooled — async server).
##   * freya: test_freya_adapter_element_tree, test_freya_adapter_real_pixels,
##            test_freya_adapter_streams_task_app (pooled — async server),
##            test_freya_input_routes_to_fireevent (pooled — async server),
##            test_freya_render_budget (pooled — wall-clock budget).
##   * cocoa: test_cocoa_adapter_macos_only (Linux: body is
##            ``when defined(macosx)``-gated → the AppKit path is compiled
##            out, the suite runs its Linux-scaffold arms to exit 0;
##            pooled since the macOS arm would spawn the async server),
##            test_cocoa_adapter_compile (pooled — drives a ``nim check
##            --os:macosx`` subprocess over the real cocoa adapter sources).
##   * android: test_android_adapter_element_tree,
##            test_android_adapter_compile (pooled — drives a ``nim check
##            --os:android -d:mockJni`` subprocess).
##   * cross-backend: test_rasteriser_kind_paint (gpui + freya arms run;
##            cocoa/android arms are ``when defined``-gated out on Linux).
##
## The ``test_*_real_pixels`` suites self-gate their real-GPU-readback arm
## with ``skip()`` (the headless ``useGpuiHeadless`` / ``useFreyaHeadless``
## define is off and the dev shell ships no real GPU/display) and assert
## the synthetic-fallback path instead — NOT weakened, only the
## hardware-only arm is skipped; the fallback arm runs to exit 0.
##
## THREE further LEAF tests — previously host-red with a RangeDefect in
## the async WebSocket read path — are ALSO re-enabled (serial pool; they
## spawn the async bridge):
##     * tests/test_bridge_element_tree_emission.nim
##     * tests/test_bridge_emits_delta_when_negotiated.nim
##     * tests/test_bridge_manifest_key_kind_propagates.nim
## The RangeDefect was NOT a manifest/delta product bug (``manifestKey``
## already spans ``kind``): the WS test client created a FRESH decoder per
## ``drainPackets`` call, so bytes buffered in the previous decoder from an
## over-long ``recv`` were dropped and the next drain parsed mid-frame,
## reading a payload byte as a frame header whose 4-bit opcode (11 / 15)
## has no ``WsOpcode`` representant → ``RangeDefect``. Fixed by keying the
## decoder state on the socket so it persists across drains
## (``ws_test_client.clientStateFor``), plus lowering the tests' default
## ``fps`` so the mid-stream manifest flip lands before the server
## exhausts its ``maxFrames`` budget (a pre-existing pacing race the
## desync had masked). No ``check`` weakened; product ``src/`` unchanged.
##
## ---------------------------------------------------------------------
## STILL DEFERRED — stale prebuilt renderer shim (NOT rebuildable here).
## ---------------------------------------------------------------------
##
## THREE tests depend on offscreen-pixel-readback entry points
## (``gpui_render_to_pixels`` / ``freya_render_to_pixels`` /
## ``gpui_bump_generation``) that are present in the renderer siblings'
## Rust SOURCES but ABSENT from the prebuilt ``rust/target/debug/
## lib{gpui,freya}_nim_shim.so`` cdylibs this host ships. The shims are
## built out-of-band (the dev shell carries no ``cargo`` to rebuild
## them — same constraint the ``isonim-gpui`` / ``isonim-freya`` /
## ``isonim-examples`` recipes document), so the adapter's headless
## ``*_render_to_pixels`` call misses the export and falls through to the
## synthetic raster, which paints a non-background pixel for the nil-root
## case the test pins. This is a stale-artifact/env condition, NOT a
## render-serve product bug (the adapter is a faithful passthrough) and
## NOT a reprobuild bug; ``uses: "isonim-gpui"`` threads the sibling
## SOURCE path but does not rebuild the out-of-band cdylib.
##
##     * tests/test_gpui_adapter_renderframe.nim      (nil-root → synthetic,
##                                                     `gpui_render_to_pixels` absent)
##     * tests/test_freya_adapter_renderframe.nim     (nil-root → synthetic,
##                                                     `freya_render_to_pixels` absent)
##     * tests/test_gpui_adapter_story_generation.nim (`gpui_bump_generation` absent)
##
## ---------------------------------------------------------------------
## STILL DEFERRED — Objective-C / AppKit toolchain absent on Linux.
## ---------------------------------------------------------------------
##
## THREE tests compile the real ``isonim-cocoa`` Objective-C sources
## DIRECTLY into the test binary (``import
## isonim_render_serve/adapters/cocoa_adapter`` unconditionally, which
## pulls ``isonim-cocoa/src/isonim_cocoa/appkit/textcontrols_helper.m``
## and ``#include <objc/message.h>``). The Linux dev shell has no
## Objective-C runtime headers, so the ``gcc -c … textcontrols_helper.m``
## / ``objc/message.h`` include fails at compile time. This is a
## host-toolchain limitation (macOS-only), NOT a render-serve product
## bug and NOT a reprobuild bug. (``test_cocoa_adapter_macos_only`` and
## ``test_cocoa_adapter_compile`` compile FINE because the former gates
## its AppKit imports behind ``when defined(macosx)`` and the latter
## reaches the cocoa sources only through a driven ``nim check``
## subprocess, never linking objc into its own binary.)
##
##     * tests/test_cocoa_adapter_element_tree.nim
##     * tests/test_per_backend_diff_stability.nim
##     * tests/test_per_backend_hover_dispatch.nim
##
## ``tests/ws_test_client.nim`` is an IMPORTED helper (a WebSocket client
## used by the bridge/streaming tests via ``import ./ws_test_client``),
## NOT a standalone ``suite`` test — it gets no edge, only a transitive
## input of the tests that import it.
##
## **Tool provisioning.** ``defaultToolProvisioning "path"`` matches the
## canonical recipes: the nix dev shell puts ``nim`` + ``gcc`` on
## ``PATH``, so the weak-local PATH resolver is the right default.
## Without it ``repro build`` refuses to run with "typed tool
## provisioning is required for uses declarations".

import std/os

import repro_project_dsl

# ``ct_test_nim_unittest`` supplies the ``buildNimUnittest.build(...)``
# typed-tool used by every test BUILD edge below, and the
# ``edge.testBinary.run(...)`` UFCS dispatch for the EXECUTE edges. It
# re-exports ``repro_project_dsl`` so the import order is unimportant.
# Like the ``nim-libvterm`` / ``isonim-tui-serve`` leaf recipes this file
# does NOT import ``ct_test_runner_install`` (that module is
# engine-coupled and reprobuild-internal): the execute edges route
# through the engine's default direct-binary runner (run the binary, key
# on exit status), which is exactly the exit-0 verification this corpus
# needs — Nim ``unittest`` prints per-suite results and exits non-zero on
# failure.
import ct_test_nim_unittest

type
  RenderServeTestSpec = object
    ## One entry per runnable LEAF test file. ``source`` is the
    ## repo-relative ``.nim`` path; ``binary`` is the
    ## ``build/test-bin/<stem>`` output. ``pool`` names the serialization
    ## pool (empty = unpooled/parallel).
    source: string
    binary: string
    pool: string

const serialPoolName = "isonim_render_serve.bridge-serial"

# Absolute rpath to the prebuilt Freya-shim cdylib directory. The Freya
# renderer's ``bindings.nim`` FFI is a bare-soname
# ``{.dynlib: "libfreya_nim_shim.so".}`` (unlike the GPUI shim whose
# ``bindings.nim`` resolves an ABSOLUTE ``currentSourcePath()``-derived
# path into ``../isonim-gpui/rust/target/debug`` — so the GPUI shim loads
# with no rpath/env). Any test that constructs a ``FreyaRenderer`` needs
# ``libfreya_nim_shim.so`` reachable at run time; baking an absolute
# ``-Wl,-rpath`` onto every test binary lets the FFI ``dlopen`` the
# prebuilt sibling shim with NO ``LD_LIBRARY_PATH`` (mirrors the
# ``isonim-examples`` / ``isonim-freya`` recipes). It is harmless on
# binaries that never load the shim (an unused rpath entry). The shim is
# prebuilt out-of-band — the dev shell has no ``cargo`` to rebuild it.
const repoRoot = currentSourcePath().parentDir()
let freyaShimRpath =
  absolutePath(repoRoot / ".." / "isonim-freya" / "rust" / "target" / "debug")

const renderServeTestSpecs: seq[RenderServeTestSpec] = @[
  # --- Pure codec / diff / element-tree round-trips ------------------
  # No I/O, no subprocess, no async server — run in parallel.
  RenderServeTestSpec(source: "tests/test_packet_codec_roundtrip.nim",
    binary: "build/test-bin/test_packet_codec_roundtrip", pool: ""),
  RenderServeTestSpec(source: "tests/test_packet_element_tree_roundtrip.nim",
    binary: "build/test-bin/test_packet_element_tree_roundtrip", pool: ""),
  RenderServeTestSpec(source: "tests/test_packet_select_story_roundtrip.nim",
    binary: "build/test-bin/test_packet_select_story_roundtrip", pool: ""),
  RenderServeTestSpec(source: "tests/test_packet_video_codec_id_helper.nim",
    binary: "build/test-bin/test_packet_video_codec_id_helper", pool: ""),
  RenderServeTestSpec(source: "tests/test_packet_video_codec_roundtrip.nim",
    binary: "build/test-bin/test_packet_video_codec_roundtrip", pool: ""),
  RenderServeTestSpec(source: "tests/test_packet_webp_codec_roundtrip.nim",
    binary: "build/test-bin/test_packet_webp_codec_roundtrip", pool: ""),
  RenderServeTestSpec(source: "tests/test_packet_webp_diff_region_roundtrip.nim",
    binary: "build/test-bin/test_packet_webp_diff_region_roundtrip", pool: ""),
  RenderServeTestSpec(source: "tests/test_ws_frame_codec.nim",
    binary: "build/test-bin/test_ws_frame_codec", pool: ""),
  RenderServeTestSpec(source: "tests/test_diff_region_compute.nim",
    binary: "build/test-bin/test_diff_region_compute", pool: ""),
  RenderServeTestSpec(source: "tests/test_diff_region_encoder.nim",
    binary: "build/test-bin/test_diff_region_encoder", pool: ""),
  RenderServeTestSpec(source: "tests/test_browser_diff_decoder.nim",
    binary: "build/test-bin/test_browser_diff_decoder", pool: ""),
  RenderServeTestSpec(source: "tests/test_compute_element_tree_delta.nim",
    binary: "build/test-bin/test_compute_element_tree_delta", pool: ""),
  RenderServeTestSpec(source: "tests/test_element_tree_delta_codec_roundtrip.nim",
    binary: "build/test-bin/test_element_tree_delta_codec_roundtrip", pool: ""),
  RenderServeTestSpec(source: "tests/test_story_dispatch_sink.nim",
    binary: "build/test-bin/test_story_dispatch_sink", pool: ""),
  # --- In-process-only WebP encoder lifecycle -----------------------
  # Probes libwebp directly (in-process FFI, live in the dev shell); no
  # wall-clock assertion, so it stays unpooled/parallel.
  RenderServeTestSpec(source: "tests/test_webp_inprocess_encoder_lifecycle.nim",
    binary: "build/test-bin/test_webp_inprocess_encoder_lifecycle", pool: ""),
  # --- Wall-clock LATENCY-BUDGET tests (capacity-1 serial pool) -----
  # These assert a per-call / per-frame wall-clock budget (element-tree
  # delta < 1 ms/call; in-process WebP encode median < 16 ms @ 1280x800).
  # A latency assertion is meaningless under CPU contention — running
  # them alongside 7 other parallel edges saturates the host and inflates
  # the measured median past budget (observed: median 12.6 ms clean vs a
  # >16 ms failure under load). They are routed through the capacity-1
  # pool so they measure the encoder / delta cost with scheduler
  # headroom. This changes ONLY scheduling — no budget is relaxed; the
  # assertions run in full to exit 0.
  RenderServeTestSpec(source: "tests/test_element_tree_delta_budget.nim",
    binary: "build/test-bin/test_element_tree_delta_budget", pool: serialPoolName),
  RenderServeTestSpec(source: "tests/test_webp_inprocess_encoder_budget.nim",
    binary: "build/test-bin/test_webp_inprocess_encoder_budget", pool: serialPoolName),
  # --- Subprocess / async-server tests (capacity-1 serial pool) -----
  # Bridge tests: spawn a real asynchttpserver on an ephemeral port +
  # hand-rolled WS client (import ./ws_test_client).
  RenderServeTestSpec(source: "tests/test_bridge_hello_first.nim",
    binary: "build/test-bin/test_bridge_hello_first", pool: serialPoolName),
  RenderServeTestSpec(source: "tests/test_bridge_stub_frame_source.nim",
    binary: "build/test-bin/test_bridge_stub_frame_source", pool: serialPoolName),
  RenderServeTestSpec(source: "tests/test_bridge_input_roundtrip.nim",
    binary: "build/test-bin/test_bridge_input_roundtrip", pool: serialPoolName),
  RenderServeTestSpec(source: "tests/test_bridge_diff_streaming.nim",
    binary: "build/test-bin/test_bridge_diff_streaming", pool: serialPoolName),
  RenderServeTestSpec(source: "tests/test_input_keyboard_roundtrip.nim",
    binary: "build/test-bin/test_input_keyboard_roundtrip", pool: serialPoolName),
  RenderServeTestSpec(source: "tests/test_protocol_violation_close.nim",
    binary: "build/test-bin/test_protocol_violation_close", pool: serialPoolName),
  RenderServeTestSpec(source: "tests/test_v_packet_emission.nim",
    binary: "build/test-bin/test_v_packet_emission", pool: serialPoolName),
  # WebP tests that fork an ffmpeg child on their non-skipped arms:
  # serialized so the fork+exec runs with headroom (arms ``skip()`` when
  # ffmpeg is absent — no check weakened either way).
  RenderServeTestSpec(source: "tests/test_webp_encoder_lifecycle.nim",
    binary: "build/test-bin/test_webp_encoder_lifecycle", pool: serialPoolName),
  RenderServeTestSpec(source: "tests/test_webp_inprocess_subprocess_parity.nim",
    binary: "build/test-bin/test_webp_inprocess_subprocess_parity", pool: serialPoolName),

  # --- SECOND PASS: renderer-sibling adapter tests (siblings landed) --
  # Pure adapter / element-tree / real-pixels probes: no async server,
  # no wall-clock budget → unpooled/parallel. The ``real_pixels`` suites
  # self-``skip()`` the real-GPU arm and assert the synthetic fallback.
  RenderServeTestSpec(source: "tests/test_gpui_adapter_element_tree.nim",
    binary: "build/test-bin/test_gpui_adapter_element_tree", pool: ""),
  RenderServeTestSpec(source: "tests/test_gpui_adapter_real_pixels.nim",
    binary: "build/test-bin/test_gpui_adapter_real_pixels", pool: ""),
  RenderServeTestSpec(source: "tests/test_freya_adapter_element_tree.nim",
    binary: "build/test-bin/test_freya_adapter_element_tree", pool: ""),
  RenderServeTestSpec(source: "tests/test_freya_adapter_real_pixels.nim",
    binary: "build/test-bin/test_freya_adapter_real_pixels", pool: ""),
  RenderServeTestSpec(source: "tests/test_android_adapter_element_tree.nim",
    binary: "build/test-bin/test_android_adapter_element_tree", pool: ""),
  RenderServeTestSpec(source: "tests/test_rasteriser_kind_paint.nim",
    binary: "build/test-bin/test_rasteriser_kind_paint", pool: ""),
  # Cross-compile gate tests drive a ``nim check`` subprocess (heavy
  # child compile) → serial pool so the fork+exec runs with headroom.
  RenderServeTestSpec(source: "tests/test_cocoa_adapter_compile.nim",
    binary: "build/test-bin/test_cocoa_adapter_compile", pool: serialPoolName),
  RenderServeTestSpec(source: "tests/test_android_adapter_compile.nim",
    binary: "build/test-bin/test_android_adapter_compile", pool: serialPoolName),
  # Cocoa macOS-only suite: on Linux the AppKit body is
  # ``when defined(macosx)``-gated out; pooled because the macOS arm
  # would spawn the async bridge server (import ./ws_test_client).
  RenderServeTestSpec(source: "tests/test_cocoa_adapter_macos_only.nim",
    binary: "build/test-bin/test_cocoa_adapter_macos_only", pool: serialPoolName),
  # Streaming / input-routing suites: spawn the async server + WS client
  # (import ./ws_test_client) and instantiate the task_app demo as the
  # frame source → serial pool (same rationale as the bridge tests).
  RenderServeTestSpec(source: "tests/test_gpui_adapter_streams_task_app.nim",
    binary: "build/test-bin/test_gpui_adapter_streams_task_app", pool: serialPoolName),
  RenderServeTestSpec(source: "tests/test_gpui_input_routes_to_fireevent.nim",
    binary: "build/test-bin/test_gpui_input_routes_to_fireevent", pool: serialPoolName),
  RenderServeTestSpec(source: "tests/test_freya_adapter_streams_task_app.nim",
    binary: "build/test-bin/test_freya_adapter_streams_task_app", pool: serialPoolName),
  RenderServeTestSpec(source: "tests/test_freya_input_routes_to_fireevent.nim",
    binary: "build/test-bin/test_freya_input_routes_to_fireevent", pool: serialPoolName),
  # Freya render-budget: asserts a per-frame wall-clock budget → serial
  # pool so the measurement runs with scheduler headroom (not weakened).
  RenderServeTestSpec(source: "tests/test_freya_render_budget.nim",
    binary: "build/test-bin/test_freya_render_budget", pool: serialPoolName),

  # --- Element-tree manifest/delta bridge tests (formerly RangeDefect) -
  # These spawn the async bridge server + hand-rolled WS client and drive
  # the ETS-M2 / RS-M11 element-tree manifest flow → serial pool. They
  # were previously host-red with a RangeDefect; the crash was a
  # frame-desync in the test WS client (a fresh decoder per drain dropped
  # socket-buffered bytes) surfacing an unchecked WsOpcode conversion,
  # plus a frame-loop pacing race that let the server exhaust its
  # ``maxFrames`` budget before the mid-stream manifest flip landed. Both
  # were fixed in the tests (persistent per-socket decoder in
  # ``ws_test_client``; low default ``fps`` so the flip lands mid-stream);
  # the product manifest/delta emission (``manifestKey`` already spans
  # ``kind``) was correct and is unchanged. They now run to exit 0.
  RenderServeTestSpec(source: "tests/test_bridge_element_tree_emission.nim",
    binary: "build/test-bin/test_bridge_element_tree_emission", pool: serialPoolName),
  RenderServeTestSpec(source: "tests/test_bridge_emits_delta_when_negotiated.nim",
    binary: "build/test-bin/test_bridge_emits_delta_when_negotiated", pool: serialPoolName),
  RenderServeTestSpec(source: "tests/test_bridge_manifest_key_kind_propagates.nim",
    binary: "build/test-bin/test_bridge_manifest_key_kind_propagates", pool: serialPoolName),
]

package isonim_render_serve:
  defaultToolProvisioning "path"

  uses:
    # Toolchain floor — the PATH-resolvable binaries the build needs.
    # ``nim`` compiles every test binary (the ``buildNimUnittest.build``
    # edges below) and the library facade; ``gcc`` is the C back-end
    # ``nim c`` shells out to and links through. The lower bound mirrors
    # the nimble file's ``requires "nim >= 2.0.0"``; ``gcc >=12`` matches
    # the workspace toolchain floor. Sufficient for the path-mode
    # resolver under ``nix develop``.
    "nim >=2.0"
    "gcc >=12"

    # SECOND-PASS sibling Nim-library producers (SC-11 develop-mode
    # from-source consumption). Each names a workspace PROJECT that ships
    # a landed ``repro.nim`` ``library`` edge; reprobuild builds it from
    # source and threads its exported root onto this repo's ``nim c
    # --path:`` via the ``nimPathDirs`` aux channel, and FOLDS it into the
    # lock. The renderer-adapter tests re-enabled above ``import
    # isonim_gpui/renderer`` / ``isonim_freya/renderer`` /
    # ``isonim_cocoa/renderer`` / ``isonim/core/signals``. ``isonim``
    # re-exports ``nim_everywhere/platform`` so nim-everywhere is a direct
    # compile input too.
    "isonim"          # library isonim
    "isonim-gpui"     # library isonim_gpui
    "isonim-freya"    # library isonim_freya
    "isonim-cocoa"    # library isonim_cocoa
    "nim-everywhere"  # library nim_everywhere
    # NOTE: the ``task_app/*`` demo tree (isonim-examples) that the
    # streaming/input tests instantiate, and the ``isonim_android/renderer``
    # sources the android tests pull, are threaded via the committed
    # ``config.nims`` ``--path:`` switches, NOT ``uses:`` edges.
    # ``isonim-examples`` exports its library at the repo ROOT and declares
    # ``uses: "isonim-render-serve"`` back — consuming it as a ``uses:``
    # edge pulls its full downstream demo graph rather than a leaf splice;
    # ``isonim-android`` declares no ``library`` export at all. Both are
    # plain Nim sources on the path, so the ``config.nims`` switches
    # resolve them at compile time with no producer sub-build.

  # Library declaration — the ``src/`` tree is importable when this
  # package is consumed via ``uses: "isonim_render_serve"``. The umbrella
  # is ``src/isonim_render_serve.nim`` (consumers ``import
  # isonim_render_serve``); the submodules under
  # ``src/isonim_render_serve/`` (packet, ws_frame, bridge,
  # element_tree_delta, ...) are importable too. This is the bootstrap
  # anchor isonim's ``src`` depends on.
  library isonim_render_serve

  build:
    # Two-edge test template (Package-Model.md §"The test template"): one
    # compile BUILD edge + one EXECUTE edge per LEAF test file. BUILD
    # halves collect into ``test-builds`` (compile verification); EXECUTE
    # halves into ``test`` so ``repro test`` / ``repro build test``
    # materialise the runnable closure (each execute edge transitively
    # depends on its build edge).
    #
    # Compile flags reproduce the repo's default matrix point
    # (``just test`` → ``_matrix orc release on``):
    #   * ``paths = @["src", "tests"]``  — ``--path:src --path:tests``.
    #   * ``defines = @["release"]``     — ``-d:release`` (the repo's
    #     ``config.nims`` lifts ``-d:withCodecWebP`` /
    #     ``-d:withInProcessWebP`` automatically at compile time).
    #   * ``mm = "orc"``                 — ``--mm:orc``.
    #   * ``threadsOn`` (default true)   — ``--threads:on``.
    var testBuildActions: seq[BuildActionDef] = @[]
    var testExecuteActions: seq[BuildActionDef] = @[]

    # Capacity-1 pool serialising the async-server bridge tests + the
    # ffmpeg-forking WebP tests (mirrors isonim-tui-serve's bridge pool).
    let serialPool = buildPool(serialPoolName, 1'u32)
    discard serialPool

    proc emitTestPair(source, binary, pool: string;
                      buildActions, executeActions: var seq[BuildActionDef]) =
      var lastSlash = -1
      for i in 0 ..< binary.len:
        if binary[i] == '/' or binary[i] == '\\':
          lastSlash = i
      let stem =
        if lastSlash >= 0: binary[lastSlash + 1 .. ^1]
        else: binary
      let edge = buildNimUnittest.build(
        source = source,
        binary = binary,
        defines = @["release"],
        paths = @["src", "tests"],
        mm = "orc",
        # Bake the absolute Freya-shim rpath so a binary that constructs a
        # ``FreyaRenderer`` ``dlopen``s the prebuilt sibling
        # ``libfreya_nim_shim.so`` at run time with no ``LD_LIBRARY_PATH``
        # (harmless unused rpath on binaries that never load the shim).
        extraPassL = @["-Wl,-rpath," & freyaShimRpath],
        extraInputs = @["src"],
        actionId = "isonim_render_serve.test_build." & stem)
      buildActions.add(edge.action)
      # ``registerImplicitName = false`` because the BUILD edge already
      # owns the binary basename as the implicit target name; the
      # explicit ``actionId`` is the execute edge's selector (two-edge
      # shape).
      let executeEdge =
        if pool.len > 0:
          edge.testBinary.run(
            actionId = "isonim_render_serve.test_execute." & stem,
            pool = pool,
            registerImplicitName = false)
        else:
          edge.testBinary.run(
            actionId = "isonim_render_serve.test_execute." & stem,
            registerImplicitName = false)
      executeActions.add(executeEdge)

    for spec in renderServeTestSpecs:
      emitTestPair(spec.source, spec.binary, spec.pool,
        testBuildActions, testExecuteActions)

    discard collect("test", testExecuteActions)
    discard collect("test-builds", testBuildActions)
