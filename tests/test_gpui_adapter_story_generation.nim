## ERV-M3 — story-generation guard control flow.
##
## Asserts the Nim adapter's contract for the shim's ERV-M3 FFI:
##
##   1. ``gpui_bump_generation`` is exported through the Nim bindings,
##      returns a monotonically increasing ``uint64``, and the values
##      it produces are observable from a subsequent submit
##      (i.e. the underlying ``AtomicU64`` is process-wide and the
##      ``Acquire``/``Release`` pair establishes happens-before).
##
##   2. ``GpuiFrameSource.bumpStoryGeneration`` is the launcher-facing
##      adapter helper that the ``StoryDispatchSink``'s ``mountFn``
##      must call BEFORE mutating the GPUI tree state, and it
##      delegates to the FFI.
##
##   3. A render token submitted BEFORE a bump surfaces as
##      ``GpuiRenderTakeStale`` on the next poll — *not* as a Ready
##      buffer that would paint the previous story's bytes — and the
##      token is consumed.
##
## The test uses the real shim cdylib (no mocks): the same dylib the
## bridge loads in production. The bumps and submits are real FFI
## calls; only the render content is irrelevant for the staleness
## assertion (we don't await Ready bytes — we deliberately poll
## while the slot is still Pending so the test works on hosts where
## the headless renderer is unavailable).

import std/unittest

import isonim_gpui/renderer
import isonim_gpui/bindings as gpui_bindings

import isonim_render_serve/adapters/gpui_adapter

suite "ERV-M3: GPUI adapter story-generation guard":

  test "gpui_bump_generation is monotonic across consecutive calls":
    # Snapshot the generation before / between / after three bumps.
    # The deltas must be exactly +1 each — the counter is process-wide
    # and unchanged by anything else in this test process.
    let g0 = gpui_bindings.gpui_bump_generation()
    let g1 = gpui_bindings.gpui_bump_generation()
    let g2 = gpui_bindings.gpui_bump_generation()
    check g1 == g0 + 1'u64
    check g2 == g1 + 1'u64

  test "GpuiFrameSource.bumpStoryGeneration delegates to the FFI":
    # Pre-condition the adapter helper produces a strictly-greater
    # generation than a raw FFI call that preceded it. The helper
    # must NOT swallow the bump (e.g. by short-circuiting on a
    # nil src field).
    gpui_reset_tree()
    let r = GpuiRenderer()
    let root = r.createElement("div")
    let fs = newGpuiFrameSource(r, root, width = 16, height = 16)
    let baseline = gpui_bindings.gpui_bump_generation()
    let bumped = fs.bumpStoryGeneration()
    check bumped == baseline + 1'u64

  test "render token submitted before a bump is dropped as stale":
    # Submit a render request, then bump the generation BEFORE polling
    # for the result. The shim guarantees the next ``try_take`` returns
    # ``GpuiRenderTakeStale`` (= 2) instead of Ready bytes, so the
    # bridge never paints the prior story's frame. The token is
    # consumed by the stale path.
    gpui_reset_tree()
    let r = GpuiRenderer()
    let root = r.createElement("div")
    discard r # silence unused-var on bare-Linux lanes
    discard root
    let token = gpui_bindings.gpui_render_submit_async(
      cuint(64), cuint(48), cfloat(1.0))
    check token != 0'u32

    discard gpui_bindings.gpui_bump_generation()

    var outPtr: ptr uint8
    var outLen: csize_t = 0
    let rc = gpui_bindings.gpui_render_try_take(
      token, addr outPtr, addr outLen)
    check rc == gpui_bindings.GpuiRenderTakeStale
    check outPtr.isNil
    check outLen == 0

    # Token must be consumed — a re-poll returns UnknownToken.
    let rc2 = gpui_bindings.gpui_render_try_take(
      token, addr outPtr, addr outLen)
    check rc2 == gpui_bindings.GpuiRenderTakeUnknownToken

  test "GpuiRenderTakeStale is distinct from Ready / Pending / UnknownToken":
    # Documents the sentinel constants the adapter switch-cases on. If
    # the shim ever collapses Stale into Pending (or 0), this test
    # catches the contract drift before the staleness path silently
    # turns into "paint the prior story's frame".
    check gpui_bindings.GpuiRenderTakeReady == cint(0)
    check gpui_bindings.GpuiRenderTakePending == cint(1)
    check gpui_bindings.GpuiRenderTakeStale == cint(2)
    check gpui_bindings.GpuiRenderTakeUnknownToken == cint(-100)
    check gpui_bindings.GpuiRenderTakeStale !=
          gpui_bindings.GpuiRenderTakeReady
    check gpui_bindings.GpuiRenderTakeStale !=
          gpui_bindings.GpuiRenderTakePending
    check gpui_bindings.GpuiRenderTakeStale !=
          gpui_bindings.GpuiRenderTakeUnknownToken
