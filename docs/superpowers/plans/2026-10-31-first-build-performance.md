# First-build performance implementation plan

> Implemented inline with the executing-plans and test-driven-development skills. Commit and PR publication were authorized on 2026-11-01.

**Goal:** Reduce first-build work in SARC parsing, IPA compression, and Vulkan/OpenGL target selection, in that order, with correctness checks and benchmarks.

**Architecture:** Bound SARC filename reads to the name table. Compress large ZIP entries in bounded parallel raw-Deflate blocks with the preceding 32 KiB as each block's dictionary, preserving level 6, ordered output, CRC, Zip64, stored fallback, and atomic publication. Select Mac/iOS outputs explicitly and retain other-target outputs and their own reuse keys.

**Tech stack:** Python 3.12+, zlib, concurrent.futures, unittest, existing SPIRV-Cross and Metal.

**Spec:** The user's authorization in this chat for the first three audit findings. Implementation choices above retain existing rendering and package behavior. Direct shader tools retain their default of Mac plus iOS with --ios.

## Global constraints

- Game files stay outside the repository; benchmarks use synthetic temporary fixtures. The user supplied the existing game folder ~/Games/LegendsZA for regression; its generated files stay beside that build.
- Commit only with explicit authorization (received 2026-11-01); no device installation/signing.
- Keep compression level and quality; blanket storage/lower compression trade size for time and are not selected.
- Preserve registered shader coverage; no deferred work at first launch.

## Review focus

- Malformed SARC names cannot reach the data area; unnamed members work.
- Deflate chunks roundtrip across boundaries; output order and dictionary history are correct.
- Packing failures preserve the old IPA and index; memory remains bounded.
- Mac/iOS transitions never reuse stale target keys or delete the other target.
- Synthetic timing is not full-game validation; missing games, routes and toolchain mismatches must be reported.

## Task 1: SARC parsing

- [x] Test named/unnamed members, out-of-table offsets and absent terminators; observe malformed cases fail.
- [x] Bound filename lookup; run parser and nesting tests.
- [x] Benchmark old/new parsing on deterministic synthetic archives and compare every member.

## Task 2: IPA compression

- [x] Test multi-chunk roundtrip, dictionaries, concurrency, Zip64, ordering and failure cleanup; observe new concurrency test fail.
- [x] Implement bounded parallel Deflate and run the existing IPA tests plus independent ZIP readers.
- [x] Benchmark cold packs of mixed, compressible and incompressible synthetic images, with output sizes.

## Task 3: Vulkan/GL targets

- [x] Test direct-tool and NSP target selection, transitions, stale keys and failure cleanup; observe new cases fail.
- [x] Implement explicit target selection and independent output reuse keys.
- [x] Run shader/NSP tests; benchmark actual Metal compilation of synthetic shaders.

## Task 4: Verification

- [x] Run relevant suites, lint, docs and chain checks, and review the diff.
- [x] Attempt the required five-game regression and report missing resources.
- [x] Document mechanisms, timings and remaining useful parallelization candidates.

## Progress

- Pre-flight: tasks share no new interfaces; target tools and the NSP caller must agree on the target-selection flag.
- Initial baseline used an Intel Python and could not import ARM lz4; use arch -arm64 /opt/homebrew/bin/python3 throughout.

- Implemented all three changes in order, with failing regression cases before their fixes and an independent review. The review found a weak concurrency assertion; it now requires two worker threads to rendezvous and fails with one worker. TSV output files now close explicitly.
- Synthetic benchmarks and their methodology are recorded once in [Packing](../../reference/packing.md). SARC members and ZIP payload hashes matched; iOS Vulkan/GL libraries and tables were byte-identical. A real 4 GiB + 17 byte Zip64 entry passed Python and system unzip verification.
- Pinned Python lint: 392 existing findings, zero new and zero fixed entries left in the baseline. Final related test sweep: 309 tests across 28 suites passed in 72.6 s, recorded in `/private/tmp/nx-first-build-final-tests.log`; documentation was checked again after the final edits (11 passed). Existing ResourceWarnings come from unchanged chain/cache readers. `git diff --check` passed.
- Regression discovery found only Legends Z-A (`0100F43008C44000`) under `~/Games`. The full `check --games 0100F43008C44000 --baseline HEAD` attempt failed on the baseline's compiler check: installed Metal 32023.921.6, required 32023.922.4. The game has no smoke route. Five-game and gameplay validation remain incomplete; no unsupported-compiler override was used.
- Implementation remained uncommitted in the native `first-build-performance` worktree until publication was authorized on 2026-11-01.

## Further parallelization candidates

The first three candidates below were subsequently implemented and measured in the [parallelism follow-up](2026-10-31-first-build-parallelism.md). Architecture-level pipeline prebuild concurrency remains a candidate.

1. `dm/tools/nx_extract/Program.cs`, `WriteImage`: enumeration and the file read/decrypt/hash/write loop run serially. Bounded read/decode workers feeding one ordered image writer are a candidate after confirming LibHac storage concurrency and profiling CPU versus disk time. Shared damage reporting and lenient filesystem initialization also need synchronization.
2. `dm/tools/patch_nso.py`, the `for fa, fb in funcs` detailed x18 analysis: disassembly, window discovery and jump-table analysis run serially. Independent function analysis could return plain records from processes, followed by deterministic patch emission. Module rewrites, x18-lite processing and spin-candidate searches already run in parallel; this proposal is limited to the remaining serial analysis. The NSP caller also gives every module a fixed worker allowance that does not grow when other modules finish.
3. `dm/gfx/tools/shader_split.py`, `main`: scanning each main executable and preparing archive jobs happen before its process pool starts. Large archive jobs then finish before loose-file jobs are submitted. Parallel discovery and a shared queue could reduce serial startup and idle workers, while preserving source order and memory limits.
4. `dm/gfx/tools/pso_offline.py`: GPU architectures are compiled one after another. Bounded concurrent architecture builds may help, but Metal's internal threading and peak memory need measurement before selecting worker counts.
