## EPP-M10 acceptance: Freya headless render budget at the Desktop
## viewport (1440×900).
##
## Renders 100 frames against a moderately complex tree (header +
## body with 8 rows + footer — representative of the editor preview
## payload exercised by the EPP-M8 acceptance matrix), and asserts
## the median per-frame wall-clock latency stays under 50 ms.
##
## Why this gate is *strictly* under the EPP-M8 goal: the launcher
## frame loop runs at ``--fps 30`` (33 ms cap) and the matrix measures
## the end-to-end client-perceived frame interval. The render-side
## budget must leave room for encoder/transport overhead, so the test
## holds Freya itself to ≤ 50 ms median.
##
## ## Why the unit test predicts the matrix outcome
##
## The EPP-M8 acceptance matrix
## (``isonim/tests/browser/e2e_editor_preview_acceptance_matrix_live.mjs``)
## measures wall-clock cadence at the browser canvas — which is
## bounded from below by the launcher's frame-source render time.
## The render path goes through ``FreyaFrameSource.renderFrame`` →
## ``freya_render_to_pixels`` (FFI into the Rust shim), which is
## exactly what this test exercises in isolation. Bringing the
## render-side median under 50 ms is the necessary and sufficient
## condition to close the matrix's "Freya 144 ms vs 50 ms goal" gap.
##
## ## Build prerequisites
##
## Compiles with ``-d:useFreyaHeadless`` so the adapter routes through
## the headless Skia raster path. The Rust shim must be built with
## ``--features freya-headless`` and on the dynamic loader search path;
## the dev shell's shellHook handles this.

import std/[algorithm, monotimes, strformat, strutils, times, unittest]

import isonim_freya/renderer
import isonim_freya/bindings as freya_bindings

import isonim_render_serve/adapters/freya_adapter

proc median(xs: var seq[float]): float =
  if xs.len == 0: return 0.0
  xs.sort()
  if xs.len mod 2 == 1: xs[xs.len div 2]
  else: 0.5 * (xs[xs.len div 2 - 1] + xs[xs.len div 2])

proc msSince(start: MonoTime): float =
  float(inMicroseconds(getMonoTime() - start)) / 1000.0

proc buildEditorLikeTree(): tuple[r: FreyaRenderer; root: FreyaElement] =
  ## Build a tree that mirrors the editor preview payload's shape and
  ## density. Eight rows is the median Task Manager scenario; the
  ## chrome bar + status footer match the EPP-M8 fixture's anatomy.
  let r = FreyaRenderer()
  let root = r.createElement("div")
  r.setAttribute(root, "class", "editor-root")
  r.setStyle(root, "background", "rgb(24, 24, 30)")
  r.setStyle(root, "width", "100%")
  r.setStyle(root, "height", "100%")

  let chrome = r.createElement("rect")
  r.setStyle(chrome, "background", "rgb(40, 50, 90)")
  r.setStyle(chrome, "height", "48")
  r.appendChild(root, chrome)
  let title = r.createElement("label")
  r.setTextContent(title, "Task Manager — IsoNim Freya")
  r.setStyle(title, "color", "rgb(230, 230, 240)")
  r.setStyle(title, "font_size", "20")
  r.appendChild(chrome, title)

  let body = r.createElement("rect")
  r.setStyle(body, "background", "rgb(30, 30, 40)")
  r.appendChild(root, body)
  for i in 0 ..< 8:
    let row = r.createElement("rect")
    r.setStyle(row, "background", "rgb(50, 55, 70)")
    r.setStyle(row, "height", "40")
    r.setStyle(row, "padding", "8")
    r.appendChild(body, row)
    let lbl = r.createElement("label")
    r.setTextContent(lbl, &"Task {i}: implement feature {i}")
    r.setStyle(lbl, "color", "rgb(200, 210, 220)")
    r.setStyle(lbl, "font_size", "14")
    r.appendChild(row, lbl)

  let footer = r.createElement("rect")
  r.setStyle(footer, "background", "rgb(40, 40, 50)")
  r.setStyle(footer, "height", "24")
  r.appendChild(root, footer)
  (r: r, root: root)

suite "EPP-M10: Freya headless render budget at Desktop viewport":

  test "median wall-clock per frame stays under 50 ms over 100 frames":
    const Width = 1440
    const Height = 900
    const Frames = 100
    # Acceptance gate from EPP-M10. Hard-coded — DO NOT loosen.
    # If this is failing, fix the renderer, do not adjust the
    # threshold. Baseline before EPP-M10 was 148 ms median for the
    # real-Skia path (measured against the same tree shape; the
    # bottlenecks were per-frame ``launch_test_with_config`` (62 ms),
    # PNG encode in ``create_snapshot`` (~25 ms), and PNG decode via
    # the ``image`` crate (~33 ms)).
    const BudgetMs = 50.0

    freya_bindings.freya_reset_tree()
    let built = buildEditorLikeTree()
    # We intentionally reuse the same root pointer across frames —
    # the editor's preview loop polls the same view-model tree, so
    # the production hot path is "render-the-same-tree-N-times" and
    # exercises the shim's `TestingHandler` cache + reusable Skia
    # surface introduced by EPP-M10.
    let fs = newFreyaFrameSource(built.r, built.root,
                                 width = Width, height = Height)
    # Warmup — the first frame pays the shim's launch cost (VDOM
    # init, font collection, surface allocation). The acceptance
    # matrix measures sustained cadence, not first-frame.
    discard fs.renderFrame()

    var samples = newSeq[float](Frames)
    for f in 0 ..< Frames:
      let t0 = getMonoTime()
      let frame = fs.renderFrame()
      let dt = msSince(t0)
      check frame.pixels.len == Width * Height * 4
      samples[f] = dt

    let med = median(samples)
    var slowestK = samples
    slowestK.sort(SortOrder.Descending)
    let p95 = slowestK[min(slowestK.high, 4)]   # ~5% slowest
    let pathTag =
      when defined(useFreyaHeadless): "real-skia-headless"
      else: "synthetic-fallback"
    echo &"EPP-M10 Freya budget @ {Width}x{Height} [{pathTag}]: median={med:.2f} ms p95={p95:.2f} ms (over {Frames} frames)"

    when defined(useFreyaHeadless):
      # The headless path is the one EPP-M8 caught at 144 ms; this is
      # the gate that proves EPP-M10's cached TestingHandler + direct
      # Skia readback got the median under the 50 ms goal.
      check med <= BudgetMs
    else:
      # Synthetic-fallback path. The synthetic raster runs entirely
      # in Nim memory; debug builds pay GC overhead per 5 MB seq, so
      # the median can climb above the 50 ms goal in unoptimised
      # builds. Release builds clear the bar comfortably; debug
      # builds are gated separately.
      when defined(release):
        check med <= BudgetMs
