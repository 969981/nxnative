# Super Mario RPG (`0100BC0018138000`)

Update 1.0.1 (v65536) over the base game, SDK 14.3.1. Unity 2021.3.15f1 IL2CPP with CRIWARE on NVN. Modules `main`, `subsdk0` (the SDK's movie library) and `sdk`. Initial Mac registration tested a fresh save through the opening movie, title, new-game cutscene, first corridor of Bowser's Keep and first Terrapin attack. The battle was not finished; that route used the provisional profile, which has the same shaders, and the registered profile ran a 60 s opening-movie boot. A later copied-save check reaches normal Mushroom Way battles and reproduces the [RGBA4 lighting defect](#rendering). No game-specific rewriter cut is needed. iPhone and iPad validation remains open.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `sys_resource 0x1000000` | [`game.tsv`](game.tsv) | the NPDM's 16 MB of system resource: virtual address memory |
| 5 GB guest layout: `mem_reserve 0x140000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0x40000000` | `game.tsv` | [Cult of the Lamb](../01002E7016C46000/README.md#memory)'s layout, the same Unity family; the NSP script's heap check chose the 1 GB pool: the game sets no heap, and with the hardware pool the alias region reached +4.27 of 4.38 GB within its first seconds |
| `depth_mode zero` | `game.tsv` | the game calls `nvnDeviceSetDepthMode` with near = 0 (log: `depth mode near=0`), so the pipeline bases made before it runs take the `main0_z` vertex entries |
| `shader_groups /Data/=data` | `game.tsv` | everything with shaders is under `Data/`: the player's serialized files and the `StreamingAssets` bundles |

## Frame rate

- 60 fps, as the game asks (present interval 1).
- **Initial registration, windowless:** left alone in the battle menu, p99 frame intervals of 22.6 to 23.9 ms. Windows holding screenshots, presses and scene changes read up to 95 ms, their long frames with GPU time around 2 ms and most with no new pipelines, on a Mac at load average 19 from other work. The field was not measured without screenshots, nor anything on an idle Mac or with a window, so whether those spikes are all from the shots and the load is open.

## Memory

- **Initial registration:** 4.71 GB resident and 0.89 GB of GPU memory at most over about six minutes, windowless, with a 2.45 GB pipeline archive open; 1.89 GB resident at frame 3300 of the opening movie with an archive of about 120 MB. Six minutes says nothing about growth; a longer soak is open.
- The heap check's region check saw alias +2.79 GB in the first 15 s in `nnMain`.

## Files and shaders

- The merged RomFS has 1,934 files, 6.35 GB: 1,277 UnityFS bundles and 46 CRI USM movies (1.01 GB). The survey also reports an FMOD marker in `main`.
- 82,032 shaders (40,983 vertex, 40,987 pixel, 56 compute, 6 geometry): 82,021 from `Data/` and the player's 11 GLSLC outputs in `main`. All built for the Mac with no failure. It takes about an hour and a half on an M6 on a busy Mac, the longest step of a first build.
- `pso_manifest.tsv` has 380 lines (263 shaders, 117 render pipelines): the `pso_user.tsv` of two runs along the route below, not a separate `DM_PSO_RECORD` pass with prewarm off.

## Rendering

- **Resolved in the host:** the [RGBA4 component-order fix](../../../docs/reference/rendering.md#rgba4-textures-in-metals-channel-order) restores the baked shadowmask's selected channel. In the affected normal Mushroom Way battle, terrain and lower foliage lose direct sunlight while Mario and the UI remain bright; the nearby field is lit normally. The format conversion is shared host behavior, with no shader or profile override.
- On 2026-11-02, fresh baseline `65501fbb` and RGBA4-corrected hosts load isolated copies of the same Mushroom Way checkpoint. The baseline's normal three-Goomba battle is dark; the candidate restores sunlight on the terrain and foliage and completes an attack. Both runs exit 0, without a missing or failed shader/pipeline load. Character and vegetation animation differ; this is a functional scene comparison, not a benchmark or a later-area test.
- Both hosts use the same 552-shader diagnostic subset from unchanged chain `e047be1b6829`, without relabeling old libraries or fabricating a full-build stamp. The conservative constant-buffer metadata fallbacks remain in use; this subset does not replace the full shader-build result above. `DM_AUDIO=1 DM_AUDIO_MUTE=1` preserves normal device pacing while zeroing output; audible sound is not assessed.
- The [focused and full-suite checks](../../../docs/reference/rendering.md#rgba4-textures-in-metals-channel-order) cover the shared format conversion and its copy/view storage boundaries. They establish code and synthetic texture behavior beyond the captured battle, not additional gameplay coverage.

## Mac routes

- Build with `scripts/build_ipa_from_nsp.py <NSP folder> -k <prod.keys> --platform mac` and use its printed command.
- From a fresh save: the opening movie plays by itself. A skips it to the title, then A on the title and on the menu, A on the difficulty (Normal is selected). The new-game cutscene follows; presses of Plus, A and a held B went to it and it reached Bowser's Keep within about a minute, without showing which of them, if any, skipped it. Press A through the dialogue.
- In the corridor, **Up walks up and to the left**. Walking towards the far door pans the camera to the door with Mario out of frame (not a fault: the HUD comes back and he is there once he moves). After the second pan a scene put him back on the carpet and a Terrapin came to life and roamed; touching it starts the battle. In battle A attacks.

## Found on this game

- [RGBA4 textures in Metal's channel order](../../../docs/reference/rendering.md#rgba4-textures-in-metals-channel-order): the baked shadowmask loses its selected channel, suppressing sunlight in outdoor battles; corrected by host conversion rather than a game-specific lighting override.
- The first NSP script run prebuilt its pipeline archive at the default depth mode: [Offline pipeline archive and profile depth disagree](../../../docs/reference/shaders.md#offline-pipeline-archive-and-profile-depth-disagree). The check boots now set the key.
- Calls `nvnCommandBufferSetSubpixelPrecisionBias` and `nvnCommandBufferSetConservativeRasterDilate` repeatedly (thousands of times in six minutes) without turning conservative rasterization on, on the route tested: see [Conservative rasterization remains unimplemented](../../../docs/reference/rendering.md#conservative-rasterization-remains-unimplemented).

## Open

- Later areas, party members, save creation and another Mac remain outside the current comparison. The added Mushroom Way route loads copied progress; it does not establish full-game correctness or save portability.
- The current lighting comparison inspects single frames and logs, not a continuous visual or audible assessment. Initial-registration audio logs show one AudioOut with 6 channels and a few 5 ms underruns under load; the later comparison is muted. Input has gone through `DM_CTL`, not a controller or the keyboard.
- iPhone and iPad runtime validation; no IPA has been built. Memory there is the first thing to watch.
- The base game alone was not played or registered; packing it takes a derived profile.
