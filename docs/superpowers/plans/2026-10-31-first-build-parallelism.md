# First-build parallelism implementation plan

> Implemented inline with the executing-plans and test-driven-development skills. Preserve the earlier first-build improvements. Commit and PR publication were authorized on 2026-11-01.

**Goal:** Implement and measure the three additional parallelization improvements authorized by the user: RomFS extraction, rewriter function analysis, then shader discovery.

**Architecture:** Bound concurrency and preserve deterministic output. RomFS work must use verified-safe storage access, fixed output offsets or an ordered writer, and atomic publication. Rewriter workers analyze independent functions and return serializable results; patch emission stays ordered. Shader discovery runs independent preparation tasks concurrently and submits archive and loose-file scans together without changing result order.

**Tech stack:** .NET 10 / LibHac 0.19.0, native ARM Python 3.14, multiprocessing and concurrent.futures.

**Spec:** The user's go-ahead in this chat and the three candidates in the preceding implementation plan. Thread count, batching and scheduling are implementation choices, selected by correctness tests and benchmarks.

## Constraints and review focus

- Commit only with explicit authorization (received 2026-11-01). Do not modify existing player builds or bypass the Metal compiler lock. Generated game data stays in the supplied game's work folder.
- Bound memory independently of RomFS size; handle very large files, short reads, damaged files and worker failures without publishing a partial image.
- Verify LibHac storage ownership and locking before concurrent access. Preserve --allow-damaged behavior and deterministic damage reports.
- Never send Capstone objects between processes. Preserve every output byte and all cross-window/retry checks, including functions split into pieces.
- Preserve shader source ordering, duplicate precedence, Unity deferred passes, profile inputs, progress reporting and errors. Avoid unbounded simultaneous executable images.
- Compare each implementation with its saved pre-change source, using repeated runs and output hashes. Report stage measurements separately from full builds.

## Task 1: RomFS extraction

- [x] Inspect exact LibHac dependency and select safe worker ownership.
- [x] Add a synthetic C# harness exercising the real image writer, including overlapping reads, empty/large files, damage fallback and failure cleanup; observe the concurrency check fail before implementation.
- [x] Implement bounded extraction workers and deterministic image assembly.
- [x] Run extraction/RomFS tests; benchmark serial versus parallel on synthetic integrity-checked storage and, when feasible, the supplied NSP.

## Task 2: Rewriter analysis

- [x] Add function-analysis and full-output equivalence tests, including exclusive windows/retries and jump tables; observe the missing parallel behavior fail.
- [x] Extract independent analysis, serialize only selected instruction addresses, merge results in function order, and retain serial patch emission and validation.
- [x] Run rewriter/NSO regression tests and benchmark real-module or representative synthetic rewrites with output hashes.

## Task 3: Shader discovery

- [x] Test overlapping discovery and archive/loose scans, deterministic source precedence, progress and error propagation; observe serial scheduling fail.
- [x] Parallelize bounded independent preparation, eliminate the archive/loose scan barrier, preserve Unity dependencies.
- [x] Run shader-split/NSP tests and benchmark representative discovery with identical packages and tables.

## Final verification

- [x] Run relevant combined tests, pinned lint, docs and chain checks; request one independent code review.
- [x] Attempt the required local-game regression; record missing games, routes or compiler support accurately.
- [x] Document mechanisms, measurements and limitations; regenerate the symptom index.

## Ledger

- Pre-change sources saved under `/private/tmp/nx-parallel-baseline`; earlier changes are not part of this pass's baseline difference.
- Existing regression limitation: only Legends Z-A was discovered; Xcode 27.0 Metal does not match the pinned 27.2 compiler and Z-A has no smoke route.

- Task 1: LibHac 0.19 storage inspection confirmed cache/AES state and the shared LocalStorage seek lock. Independent worker stacks plus positional package reads and ordered output passed extraction tests; all real-game images matched. Measurements are in `/private/tmp/nx-parallel-extract-bench.json`.
- Ruling: recognize LibHac RomFS integrity error 2002-4144 as damaged input — the new tests exposed that the existing 46xx-only filter missed this real library error — if wrong, unrelated errors might be misclassified; the fix matches only this specific verification result.
- Task 2: preserve earlier jump-table dependencies by merging in address order and reanalyzing affected functions with prior context; giant unsplit functions stay serial to bound Capstone memory. New analysis/concurrency tests and existing rewrite, jump-table and spin tests pass (57 tests).
- Task 2 benchmark: all rewritten code and six metadata tables match the baseline. The benchmark initially compared `build_src.sha256` too; that fingerprint must change with the source. The corrected comparison excludes only that expected difference, retains all timings, and records the explanation in the benchmark log.
- Task 3: executable analysis overlaps archive preparation; archive and loose-file scans share one queue. Source precedence and worker context restoration pass the new tests. Five alternating real-input rounds retain every package/table hash; the measured timing spread is documented rather than discarded.
- Final review: a fresh read-only reviewer checked all three production changes and their tests; no actionable correctness findings. No additional game was validated by that review.
- Latest regression: `first-build-regress/reports/20261031-230431-check/report.md` reports PASS using identical cached chain artifacts (28,603 shaders). It did not rebuild Metal or run gameplay. A separate fresh compiler check still reports the version mismatch above.
- Reproducible benchmark scripts, saved pre-change sources, logs and JSON hash manifests are retained under the game's `0100F43008C44000-work/parallel-build-bench/`. Measurements live once in the [game note](../../../dm/games/0100F43008C44000/README.md#first-build-stage-measurements).
- Final verification: 457 tests passed across 49 relevant suites, including docs and the current chain-header check. The initial sandboxed Mac-app suite stopped in `iconutil`; all 44 tests in that suite passed outside the sandbox without code changes. The final function tests were rerun after fixture typing fixes. Pinned lint reports 392 existing findings, zero new findings and no stale baseline entries; `git diff --check` passes. No commit was created.

## Publication follow-up, 2026-11-01

- A fresh pre-rebase run completed 1,040 cases across 118 Python suites: 1,027 passed and 13 optional tests skipped; lint had zero new findings.
- Reconciled with upstream `cd859c38`, including #810's damaged-NSP handling: preserve image damage flags and reopen each failed worker's checked storage. The real LibHac repeated-damage fixture failed with `The LinkedList is empty` before the reset and passed afterward, forced to one worker so it exhausts the old cache. All 14 extraction/RomFS tests passed.
- A fresh read-only integration review found no actionable issues; upstream edits in the automatically merged shader, rewriter and NSP files were retained. The recorded benchmark runs precede this rebase; they have not been relabeled as measurements of the integrated revision.
- The post-rebase run completed 1,085 cases across 122 Python suites: 1,072 passed and 13 optional tests skipped (nine requiring Unicorn and four native GPU/Metal fixtures). Pinned lint against `origin/main` reports 391 existing findings, zero new findings and no stale baseline entries. The compiler preflight still rejects the installed Metal version; no override was used.
- The publication regression against `origin/main` (`cd859c38`) stopped on the baseline compiler preflight before comparing the candidate: `first-build-regress/reports/20261101-122831-check/report.md`. The earlier cached PASS does not establish final integrated-revision game coverage.
