## contention_guard -- decides whether a wall-clock budget sample measured
## the code or the host.
##
## The budget tests (``test_element_tree_delta_budget``,
## ``test_webp_inprocess_encoder_budget``, ``test_freya_render_budget``)
## time a loop and assert its median against a fixed budget. On a shared,
## saturated host the median measures the host instead: the same code took
## a 9 ms median per Freya frame on one CI runner and 54 ms on another
## whose host carried a 1-minute load of 42 on 32 CPUs. A budget is never
## loosened for that. Instead the sample is classified: a run on a
## contended host prints ``NOT MEASURED`` with the evidence and is
## reported as skipped, never as a pass; every other run asserts the
## budget exactly as before.
##
## Usage, around the measured loop only::
##
##   let probe = startContentionProbe()
##   ...the timed loop...
##   let verdict = probe.finish()
##   assertBudgetUnlessContended(verdict, "median <= 50 ms", med <= BudgetMs)
##
## A run is **contended** when any of these holds (each is printed as
## evidence, measured or not):
##
## 1. **Host load.** The 1-minute load average per CPU exceeds
##    ``MaxLoadPerCpu`` (1.0) before or after the loop. The threshold and
##    the measure are those of ngx-isonim's latency-bound guard
##    (``tests/e2e/test_async_streaming.nim``): ``getloadavg(3)`` divided
##    by the CPUs. Here the CPU count is the smallest of the online CPUs,
##    the CPUs this process may run on (``sched_getaffinity(2)``, read from
##    ``/proc/self/status``) and the cgroup v2 ``cpu.max`` quota, so a
##    process confined to fewer CPUs is never judged against CPUs it
##    cannot use. Load average counts runnable and uninterruptible tasks
##    host-wide (https://www.kernel.org/doc/html/latest/filesystems/proc.html,
##    ``/proc/loadavg``), so it also sees contention that leaves a thread
##    running but slower: shared SMT siblings, caches, memory bandwidth.
## 2. **Run-queue wait (Linux).** The measuring thread spent more than
##    ``MaxRunQueueWaitFraction`` of the loop's wall time runnable but not
##    running: the second field of ``/proc/thread-self/schedstat``
##    (https://www.kernel.org/doc/html/latest/scheduler/sched-stats.html).
##    This is what CPU-weight starvation, a shared cpuset or quota
##    throttling does to the measured thread, whatever the host-wide load.
## 3. **CFS throttling (Linux, cgroup v2).** The process's cgroup or one of
##    its ancestors was throttled by its ``cpu.max`` quota during the loop
##    (``nr_throttled`` in ``cpu.stat``,
##    https://docs.kernel.org/admin-guide/cgroup-v2.html#cpu-interface-files).
##    Load average does not show quota throttling at all.
##
## Raw CPU time against wall time is deliberately **not** a criterion. A
## measured operation that sleeps or blocks -- the defect a budget exists
## to catch -- also makes wall time exceed CPU time, so that test would
## classify a genuinely slow implementation as contended. A sleeping
## thread is neither running nor waiting on a run queue, so it raises none
## of the three signals above, and its budget is asserted and fails.
##
## Evidence that cannot be read counts as contended (as an unreadable load
## does in the ngx guard): an unknown host is never taken for an idle one.
## The exception is a signal the platform does not have at all, which is
## reported as ``n/a`` and does not decide the verdict: the schedstat and
## cgroup signals exist only on Linux, and Windows has no load average, so
## on Windows the budget is asserted unconditionally, as it was before
## this guard existed.

import std/[cpuinfo, monotimes, os, strformat, strutils, times, unittest]

const
  MaxLoadPerCpu* = 1.0
    ## Above this 1-minute load average per CPU a wall-clock budget measures
    ## the host, not the code. Same threshold as ngx-isonim's guard.
  MaxRunQueueWaitFraction* = 0.05
    ## Above this share of the loop's wall time spent waiting on a run
    ## queue, the measuring thread was descheduled for long enough to move
    ## a median by more than the margin the tightest budget leaves.

const HasLoadAverage = defined(posix)
  ## Windows has no load average; there the load signal is ``n/a``.

when HasLoadAverage:
  proc c_getloadavg(loadavg: ptr cdouble; nelem: cint): cint {.
    importc: "getloadavg", header: "<stdlib.h>".}

proc loadAverage1(): float =
  ## The 1-minute load average; +inf when it cannot be read.
  when HasLoadAverage:
    var avg: array[3, cdouble]
    if c_getloadavg(addr avg[0], 3) < 1: Inf
    else: float(avg[0])
  else:
    Inf

proc parseCpuList(list: string): int =
  ## Counts the CPUs in a kernel CPU list such as ``0-3,8,10-11``; 0 when
  ## the list is malformed.
  for part in list.strip().split(','):
    if part.len == 0: continue
    let bounds = part.split('-')
    try:
      if bounds.len == 1:
        discard parseInt(bounds[0])
        inc result
      elif bounds.len == 2:
        result += parseInt(bounds[1]) - parseInt(bounds[0]) + 1
      else:
        return 0
    except ValueError:
      return 0

proc cgroupDirs(): seq[string] =
  ## The process's cgroup v2 directory and each of its ancestors up to the
  ## root, innermost first. Empty off Linux or without a unified hierarchy.
  ## The root is included because inside a container's cgroup namespace it
  ## is the container's own cgroup, where a container CPU quota lives; on a
  ## host the root has neither ``cpu.max`` nor ``nr_throttled``.
  when defined(linux):
    try:
      for line in readFile("/proc/self/cgroup").splitLines():
        if line.startsWith("0::"):
          var rel = line[3 .. ^1]
          while true:
            result.add("/sys/fs/cgroup" & (if rel == "/": "" else: rel))
            if rel.len <= 1: break
            rel = rel.parentDir()
    except IOError, OSError:
      discard

proc quotaCpus(dirs: seq[string]): float =
  ## The tightest cgroup ``cpu.max`` quota in CPUs; +inf when none is set.
  result = Inf
  for d in dirs:
    try:
      let fields = readFile(d / "cpu.max").splitWhitespace()
      if fields.len == 2 and fields[0] != "max":
        result = min(result, parseFloat(fields[0]) / parseFloat(fields[1]))
    except IOError, OSError, ValueError:
      discard

proc availableCpus(): float =
  ## The CPUs this process can actually use: online CPUs, narrowed by its
  ## affinity mask and by any cgroup CPU quota. At least 1.
  result = float(max(1, countProcessors()))
  when defined(linux):
    try:
      for line in readFile("/proc/self/status").splitLines():
        if line.startsWith("Cpus_allowed_list:"):
          let n = parseCpuList(line.split(':', 1)[1])
          if n > 0: result = min(result, float(n))
    except IOError, OSError:
      discard
    result = min(result, quotaCpus(cgroupDirs()))
  result = max(1.0, result)

type
  ThreadSched = object
    known: bool
    runNs, waitNs: int64

  ContentionProbe* = object
    ## Readings taken just before the measured loop.
    startWall: MonoTime
    loadBefore: float
    cpus: float
    sched: ThreadSched
    throttled: int64     ## sum of ``nr_throttled`` over the cgroup chain
    throttledKnown: bool
    cgroups: seq[string]

  ContentionVerdict* = object
    ## Whether the loop between ``startContentionProbe`` and ``finish``
    ## measured the code. ``evidence`` names every reading behind it.
    contended*: bool
    evidence*: string

proc readThreadSched(): ThreadSched =
  ## The calling thread's on-CPU and run-queue-wait time, in nanoseconds.
  when defined(linux):
    try:
      let f = readFile("/proc/thread-self/schedstat").splitWhitespace()
      if f.len >= 2:
        result = ThreadSched(known: true, runNs: parseBiggestInt(f[0]),
                             waitNs: parseBiggestInt(f[1]))
    except IOError, OSError, ValueError:
      discard

proc readThrottled(dirs: seq[string]): tuple[known: bool; count: int64] =
  ## Sum of ``nr_throttled`` over the cgroup chain. ``known`` is false when
  ## no ``cpu.stat`` with that field could be read (cpu controller absent).
  for d in dirs:
    try:
      for line in readFile(d / "cpu.stat").splitLines():
        if line.startsWith("nr_throttled "):
          result.count += parseBiggestInt(line.split(' ')[1])
          result.known = true
    except IOError, OSError, ValueError:
      discard

proc startContentionProbe*(): ContentionProbe =
  ## Takes the "before" readings. Call it immediately before the timed loop.
  result.cgroups = cgroupDirs()
  result.cpus = availableCpus()
  result.loadBefore = loadAverage1()
  let t = readThrottled(result.cgroups)
  result.throttledKnown = t.known
  result.throttled = t.count
  result.sched = readThreadSched()
  result.startWall = getMonoTime()

proc finish*(probe: ContentionProbe): ContentionVerdict =
  ## Takes the "after" readings and classifies the loop. Call it on the
  ## same thread as ``startContentionProbe``, immediately after the loop.
  let wallNs = inNanoseconds(getMonoTime() - probe.startWall)
  let sched = readThreadSched()
  let loadAfter = loadAverage1()
  let t = readThrottled(probe.cgroups)

  var reasons: seq[string]
  let load = max(probe.loadBefore, loadAfter)
  let loadPerCpu = load / probe.cpus
  var loadText = "load average n/a"
  when HasLoadAverage:
    loadText = &"1-min load {probe.loadBefore:.2f} before / " &
      &"{loadAfter:.2f} after on {probe.cpus:.1f} CPUs " &
      &"({loadPerCpu:.2f} per CPU, limit {MaxLoadPerCpu:.2f})"
    if not (loadPerCpu <= MaxLoadPerCpu):    # also catches NaN / +inf
      reasons.add &"load per CPU {loadPerCpu:.2f} > {MaxLoadPerCpu:.2f}"

  var schedText = "run-queue wait n/a"
  when defined(linux):
    if probe.sched.known and sched.known and wallNs > 0:
      let waitNs = sched.waitNs - probe.sched.waitNs
      let runNs = sched.runNs - probe.sched.runNs
      let waitFrac = float(waitNs) / float(wallNs)
      schedText = &"run-queue wait {float(waitNs) / 1e6:.2f} ms = " &
        &"{waitFrac * 100:.1f}% of {float(wallNs) / 1e6:.1f} ms wall " &
        &"(on CPU {float(runNs) / 1e6:.1f} ms)"
      if waitFrac > MaxRunQueueWaitFraction:
        reasons.add &"run-queue wait {waitFrac * 100:.1f}% > " &
          &"{MaxRunQueueWaitFraction * 100:.1f}%"
    else:
      schedText = "run-queue wait unreadable"
      reasons.add "run-queue wait unreadable"

  var throttleText = "cgroup throttling n/a"
  if probe.throttledKnown and t.known:
    let periods = t.count - probe.throttled
    throttleText = &"cgroup throttled periods {periods}"
    if periods > 0:
      reasons.add &"cgroup CPU quota throttled {periods} periods"

  result.contended = reasons.len > 0
  result.evidence = &"{loadText}; {schedText}; {throttleText}"
  if result.contended:
    result.evidence = "contended: " & reasons.join(", ") & ". " &
      result.evidence

template assertBudgetUnlessContended*(verdict: ContentionVerdict;
                                      claim: string; cond: untyped) =
  ## Inside a ``unittest`` test: asserts ``cond`` (the budget) when
  ## ``verdict`` says the loop measured the code. Otherwise prints
  ## ``NOT MEASURED`` with the evidence and marks the test skipped -- not
  ## passed -- unless an earlier check in the test already failed, which
  ## stays a failure.
  if verdict.contended:
    echo "    [NOT MEASURED] ", claim, ": ", verdict.evidence
    if testStatusIMPL != TestStatus.FAILED:
      skip()
  else:
    echo "    [MEASURED] ", claim, ": ", verdict.evidence
    check cond
