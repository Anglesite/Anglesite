#!/usr/bin/env bash
# Single source of truth for the suite names moved into CI's isolated, low-concurrency
# test lane (#1344). `build-test`'s full `swift test --parallel` run --skips this same
# regex so these suites run exactly once, in scripts/test-timing-sensitive.sh's job
# instead. Keep this list to suites with direct #1344 evidence or an equivalent
# self-diagnosed cross-suite-contention doc comment — see the plan at
# docs/superpowers/plans/2026-08-07-ci-isolate-timing-sensitive-tests.md for the
# inclusion criteria and the suites considered and left out.
#
# Unanchored regex substring match against `<test-target>.<test-case>/<test>` (SwiftPM's
# `swift test --filter`/`--skip`, confirmed via `swift test --help`: no tag-based
# filtering exists in this toolchain). Each name below was checked for accidental
# substring collisions against every other suite in Tests/.
#
# LoopbackMCPBridgeTests + LocalContainerSiteRuntimeReindexTests (#1656): both assert
# real wall-clock budgets (a Task.sleep-raced response timeout; an unstructured-Task
# reindex poll) and were seen missing those budgets under build-test's full-parallel
# scheduler contention — the same class of flake #1344 isolated this lane for.
#
# ProcessSupervisorShutdownTests: its `waitForExitOrTerminate` cases (via the `awaitMarker`
# helper) spawn a real `/bin/sh` fixture and poll LogCenter for a `"__STARTED__"` marker
# under a bounded 10s `ContinuousClock` deadline — the identical "subprocess-started
# marker timed out" shape #1344 already named for AuditCommandTests (also a real-
# ProcessSupervisor-subprocess wait). Reproduced deterministically (3 tests, `Expectation
# failed: await awaitMarker("__STARTED__", in: center)`) in build-test's full-parallel CI
# lane on two unrelated PRs (#1598, #1602) while passing every time locally and in
# isolation; moving it here is the same established mitigation.
#
# HMRRelayTests (#1598 CI run): `closingConnectionStopsHeartbeatAndOnMissGrowth` waits (via
# `waitUntil`) for a `ControlHeartbeat` on a 20ms ping interval to register its first miss,
# generously bounded at 15s — timed out entirely under build-test's full-parallel scheduler
# contention (`Caught error: timed out after 15.0 seconds waiting for the first miss`) while
# resolving in ~3.7s every time run locally/in isolation. Same class of flake as above:
# starved `Task` scheduling under a heavily loaded CI runner, not a real regression.
#
# LANHostScanCoordinatorTests was removed (#1810): its only isolation reason was a fixed
# sleep-then-assert wall-clock race, which migrating to `waitUntil` eliminates outright — see
# the suite's own doc comment. Unlike the suites above, it has no remaining real-I/O or
# shared-resource contention to isolate, so it no longer belongs in this lane.
#
# ProcessSupervisorRunLoggingTests + ProcessSupervisorRunLoggingPortableTests (#1966, PR #1979):
# both suites' `runDetaching` daemon cases spawn a real `/bin/sh` that backgrounds a 5s
# grandchild and assert `ContinuousClock.now - start < .seconds(...)` to prove `runDetaching`
# returned without waiting for it. build-test's `build-test` job (run 34316239022, Xcode
# 26.6/Swift 6.3.3) failed both — `5.957118040999999 seconds` and `6.28011725 seconds`,
# both just over the grandchild's 5s sleep — under the full-`--parallel` run; the same
# posix_spawn/waitpid path (spawnAndWait in InProcessBackend.swift), driven directly and
# under 40-way concurrent load, returned in ~6ms every time on an unloaded machine, and the
# suites pass consistently on Xcode 27/Swift 6.4 locally. Same class of flake as
# ProcessSupervisorShutdownTests above: the detached task doing the blocking `waitpid`
# queues behind other blocking work on build-test's oversubscribed thread pool rather than
# `runDetaching` itself blocking on the daemon — moving here is the same established
# mitigation, paired with tightening the bound (still >2x an isolated run's overhead, well
# under the 5s failure signature) now that cross-suite contention is removed.
export TIMING_SENSITIVE_TEST_FILTER='VsockTCPProxyTests|E2EServerReadinessTests|AuditCommandTests|MCPClientTests|LoopbackMCPBridgeTests|LocalContainerSiteRuntimeReindexTests|ProcessSupervisorShutdownTests|HMRRelayTests|ProcessSupervisorRunLoggingTests|ProcessSupervisorRunLoggingPortableTests'
