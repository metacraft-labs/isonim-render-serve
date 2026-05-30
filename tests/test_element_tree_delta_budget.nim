## test_element_tree_delta_budget — ETS-M3 Part A.
##
## Performance gate for ``computeElementTreeDelta``. The ETS-M1
## audit (§ 6) calibrated the wire-byte regime at three tree
## sizes: N=15 (task_app), N=48 (settings_app), N=500 (audit
## worst-case bound). The spec brief for ETS-M3 sets the diff-cost
## budget at <1 ms / call for N=500, scaled down for the
## smaller real-app sizes.
##
## The mutation pattern this benchmark drives matches what real
## launcher UIs actually produce per render tick:
##
##   * One row's bounds shift (e.g. a scroll-induced y-delta).
##   * One row added at the end.
##   * One row removed from the middle.
##
## That is the typical add-one / drop-one / nudge-one shape; mass
## edits (e.g. a 100-row insert) are out of scope here — the
## budget guards the per-frame steady-state cost.
##
## The test asserts the median wall-clock per ``computeElementTreeDelta``
## call stays under per-size budget. p99 is reported for visibility
## but not asserted on — short, infrequent stalls (GC pauses, OS
## scheduler hiccups) are acceptable as long as the median holds.
##
## Budget table (per ETS-M3 brief):
##
##   * N=48  -> median < 0.1 ms
##   * N=100 -> median < 0.3 ms
##   * N=500 -> median < 1.0 ms
##
## Per-call min/median/p99 numbers are printed for the campaign
## acceptance gate (ETS-M6) to consult.

import std/[algorithm, monotimes, strformat, times, unittest]

import isonim_render_serve

# ---------------------------------------------------------------------------
# Synthetic manifest builders
# ---------------------------------------------------------------------------

proc mkEntry(id: string; xx, yy, ww, hh: int;
             kind = "row"): ElementEntry =
  ElementEntry(id: id,
               componentPath: id,
               kind: kind,
               bounds: ElementBounds(x: xx, y: yy, w: ww, h: hh))

proc syntheticManifest(n: int; w = 1024; h = 768): ElementTreeManifest =
  ## Build a manifest of size ``n``. The first element mimics the
  ## settings_app filter bar at the top; the remaining ``n-1`` are
  ## stacked rows. The shape mirrors what the real launchers emit
  ## (one chrome element + many list rows) so the diff's union-of-
  ## ids iteration sees realistic id-key distribution.
  var elements: seq[ElementEntry] = @[]
  if n > 0:
    elements.add mkEntry("chrome/FilterBar", 0, 0, w, 12,
                         kind = "filter-bar")
  for i in 0 ..< (n - 1):
    elements.add mkEntry("rows/Row#" & $i,
                         0, 12 + i * 12, w, 12, kind = "row")
  ElementTreeManifest(
    frameSeq: 0,
    surfaceWidth: w, surfaceHeight: h,
    elements: elements)

proc mutatedManifest(n: int; w = 1024; h = 768): ElementTreeManifest =
  ## Mutate the synthetic manifest of size ``n`` with the
  ## "one row updated, one added, one removed" pattern. Specifically:
  ##
  ##   * Row #0 has its y-bound shifted by +1 (the canonical
  ##     scroll-tick / animation delta).
  ##   * The middle row (index n div 2) is removed.
  ##   * A fresh row "rows/Row#new" is appended.
  ##
  ## The total element count is unchanged (n) so the diff produces
  ## one update + one remove + one add — three ops, which is the
  ## representative shape the brief pinpoints.
  var elements: seq[ElementEntry] = @[]
  if n > 0:
    elements.add mkEntry("chrome/FilterBar", 0, 0, w, 12,
                         kind = "filter-bar")
  let removeIdx = (n - 1) div 2
  for i in 0 ..< (n - 1):
    if i == removeIdx: continue
    let yShift = (if i == 0: 1 else: 0)
    elements.add mkEntry("rows/Row#" & $i,
                         0, 12 + i * 12 + yShift, w, 12, kind = "row")
  elements.add mkEntry("rows/Row#new",
                       0, 12 + (n - 1) * 12, w, 12, kind = "row")
  ElementTreeManifest(
    frameSeq: 1,
    surfaceWidth: w, surfaceHeight: h,
    elements: elements)

# ---------------------------------------------------------------------------
# Bench harness
# ---------------------------------------------------------------------------

type
  BenchStats = object
    minNs: int64
    medianNs: int64
    p99Ns: int64
    iterations: int

proc benchDelta(n: int; iterations: int): BenchStats =
  ## Run ``computeElementTreeDelta(prev, curr)`` ``iterations``
  ## times for a tree of size ``n`` and report min / median / p99
  ## wall-clock per call in nanoseconds.
  let prev = syntheticManifest(n)
  let curr = mutatedManifest(n)
  # Warm up the diff allocator + table internals a few times so the
  # first measured call doesn't pay one-time setup cost.
  for _ in 0 ..< 10:
    discard computeElementTreeDelta(prev, curr)
  var samples = newSeq[int64](iterations)
  for i in 0 ..< iterations:
    let t0 = getMonoTime()
    let ops = computeElementTreeDelta(prev, curr)
    let t1 = getMonoTime()
    samples[i] = inNanoseconds(t1 - t0)
    doAssert ops.len >= 3,
      "mutation pattern should produce >=3 ops for N=" & $n
  sort(samples, system.cmp[int64])
  result.iterations = iterations
  result.minNs = samples[0]
  result.medianNs = samples[iterations div 2]
  let p99Idx = min(iterations - 1, (iterations * 99) div 100)
  result.p99Ns = samples[p99Idx]

proc nsToMs(ns: int64): float = float(ns) / 1_000_000.0

proc reportStats(label: string; n: int; stats: BenchStats) =
  echo &"[ETS-M3 budget] {label} N={n} iters={stats.iterations}: " &
       &"min={nsToMs(stats.minNs):.4f} ms " &
       &"median={nsToMs(stats.medianNs):.4f} ms " &
       &"p99={nsToMs(stats.p99Ns):.4f} ms"

# ---------------------------------------------------------------------------
# Suite
# ---------------------------------------------------------------------------

const Iterations = 1000

suite "ETS-M3 Part A: computeElementTreeDelta perf budget":

  test "N=48 (settings_app): median < 0.1 ms":
    let stats = benchDelta(48, Iterations)
    reportStats("settings_app", 48, stats)
    # Budget: <0.1 ms median. Settings_app is the canonical
    # real-launcher size and the budget is tight.
    check nsToMs(stats.medianNs) < 0.1

  test "N=100: median < 0.3 ms":
    let stats = benchDelta(100, Iterations)
    reportStats("midsize", 100, stats)
    # Budget: <0.3 ms median. 2x the settings_app size.
    check nsToMs(stats.medianNs) < 0.3

  test "N=500 (audit worst case): median < 1 ms":
    let stats = benchDelta(500, Iterations)
    reportStats("worst-case", 500, stats)
    # Budget: <1 ms median. The audit's published worst-case
    # bound that ETS-M6's acceptance gate consults.
    check nsToMs(stats.medianNs) < 1.0
