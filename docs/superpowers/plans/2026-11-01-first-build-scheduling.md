# First-build scheduling implementation plan

> **For agentic workers:** Use superpowers:executing-plans to implement this plan task by task. The user authorized all three changes, tests and fresh-output benchmarks; no additional design approval is needed.

**Goal:** Reduce first-build time through shader scheduling, adaptive module rewrite allocation and concurrent PSO preparation.

**Architecture:** Keep output semantics and ordering unchanged. Use one bounded queue for shader translation batches and dependency-ready finish jobs, without changing the pinned translator. Give module rewrites CPU allocations that grow as other modules exit, read between analysis passes. Read independent PSO inputs concurrently and reuse library metadata and digests within the invocation.

**Tech stack:** Python, existing .NET translator and Apple Metal tools.

**Spec:** The user's approval of the three proposals in this chat. Shader scheduling goes first; each change gets its own fresh-output comparison.

## Global constraints

- Keep game data and benchmark artifacts under `~/Games/LegendsZA/0100F43008C44000-work/`; preserve the existing build.
- Keep the repository Metal tool lock unchanged. The installed Metal is 32023.921.6; the lock requires 32023.922.4. Any experimental compiler adaptation belongs only in benchmark copies and must be labeled unsupported-toolchain evidence.
- Preserve deterministic shader results, dependency handling, failure reporting, rewrite output bytes and PSO descriptors/digests.
- Respect explicit `J` and `DM_REWRITE_J`; bound default concurrency and memory.
- Regenerate the chain header, run the relevant suites and lint, and attempt available-game regressions; report unavailable five-game and supported-toolchain validation.
- The user subsequently authorized committing these changes and updating PR #896 with measurements and remaining validation limitations.

## Review focus

- Cached and failed pixel dependencies must not allow vertex padding to read incomplete or stale sources.
- Mixed-duration work must overlap without exceeding the shared shader worker budget.
- Module completion, cancellation and explicit worker overrides must leave no allocation files in published output or orphan workers.
- Missing/malformed PSO inputs must keep existing skip/error semantics and deterministic ordering.
- Fresh benchmark directories and empty caches must prevent prior outputs from masquerading as first-build gains.

### Task 1: Shader scheduling

Files: `dm/gfx/tools/dmsh_schedule.py`, `dm/gfx/tools/dmsh_build.py`, `dm/gfx/tools/dmsh_chain.py`, `dm/gfx/tests/test_dmsh_schedule.py`.

- [x] Add tests for overlap, pair dependencies, cached dependencies, translation failure, ordered results and concurrency bounds; observe failure.
- [x] Implement a bounded batch/finish scheduler and integrate it with existing translation and finish callbacks. Preserve the translator binary and diagnostics.
- [x] Run scheduler and existing shader tests; regenerate the chain header.
- [x] Benchmark baseline and candidate using fresh output/cache directories; compare shader artifacts and report the compiler limitation.

### Task 2: Adaptive module allocation

Files: `dm/tools/rewrite_jobs.py`, `dm/tools/patch_nso.py`, `scripts/build_ipa_from_nsp.py`, rewrite tests.

- [x] Test size-based scheduling, freed-worker reassignment, per-pass worker reads and explicit overrides; observe failure.
- [x] Allocate the default CPU budget across active modules and update surviving modules when slots free; preserve ordering of generated artifacts and cleanup.
- [x] Run rewrite/NSP tests and benchmark all available game modules into fresh directories, comparing output hashes.

### Task 3: PSO preparation

Files: `dm/gfx/tools/pso_offline.py`, `dm/tools/tests/test_pso_offline.py`.

- [x] Test shared input reads, deterministic serial/parallel planning and digest equality, malformed/missing inputs; observe failure.
- [x] Preload unique reflections/libraries with bounded workers; reuse library bytes for functions, layer detection and hashes.
- [x] Run PSO tests and benchmark real game planning/digest/script generation with fresh output directories.

### Task 4: Verification and review

- [x] Run the relevant full Python suites, lint and chain-header check.
- [x] Attempt required regression/host/graphics validation and record exact limitations.
- [x] Obtain a fresh whole-change review and address substantive findings.
- [x] Record benchmark methodology and results in the game note and general mechanism in the reference docs; regenerate the symptom index.

## Recorded outcome

All three changes implemented and reviewed; review findings fixed with regression tests. Fresh-output stage medians: shaders 123.245 to 116.296 s (3 runs), main+sdk rewrite 35.835 to 23.384 s (3 runs), PSO preparation 8.862 to 6.983 s (5 runs). Shader/rewrite ranges are wide under background filesystem activity; see the game note for raw ranges and comparison normalization. PSO inputs were isolated after discarding an empty-input attempt.

Python: 1,084 passed, 13 optional skips, 124 suites. Lint: zero new findings. Mac host and native graphics checks passed. The required regression was attempted on the only local game and stopped at the pinned Metal check; full Mac/iOS shader, five-game and gameplay validation remain unavailable. The repository tool lock stays unchanged, and the existing unsupported-Metal override was used only for scratch benchmarks. Publication is authorized in PR #896 with these results and limitations.
