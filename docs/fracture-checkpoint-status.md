# Fracture extraction checkpoint

The owner paused further M84 feature development on 2026-10-07 and requested a standalone `c3d_fracture.c3l` repository. This checkpoint preserves completed implementation and acceptance evidence; it does not mark M84 complete.

The extraction retains geometry and asset types, allocators and generic faults, glTF loading and source inspection, rendering/picking/GUI, Box3D integration and generic multi-hull `Breakable` support in c3d. The independent project owns exact arithmetic, solid validation, Boolean/Voronoi generation, surface and collision reconstruction, recipes, site placement, baking and its sidecar/tool workflow.

## Verified checkpoint

- The 36 selected collision test groups pass at O0, O3, O4 and explicit O4 fast math. Unrelated test groups were skipped.
- All 96 quaternion-rotated acceptance cases reconstruct successfully at hull limits 128 and 4. Their source positions are retained bitwise, cavity/notch probes remain outside collision hulls, and triangle-order permutations retain output.
- The independent rational oracle certifies the configured missing-volume, overlap and exterior-excess bounds for all 96 exported cases. The exact exported corpus contains 9,877 hulls and 41,810 point entries; every hull also passes the isolated native hull-construction diagnostic.
- The two ordinary physics cooking groups pass in all four optimization modes, with 218 unrelated physics tests skipped. Those groups currently use a Rodrigues rotation formula; aligning them with the quaternion-based exported corpus remains a test correction. They are additional input coverage, not a byte-identical rerun of the exported corpus.
- All 105 manual benchmark cases pass one warmup and three measured repetitions. Measurements and input definitions are in `fracture-measurements.md`; performance acceptance was not requested after the owner paused the milestone.

## Deferred work

1. Preserve authored coplanar vertices during point-limited collision subdivision. A validated cube with an authored face-center vertex succeeds at limit 128 with all nine source positions, but the current limit-4 output omits the face-center position. The same boundary must cover authored edge and interior points. A tetrahedral refinement draft and public regression drafts are preserved separately, unaccepted and outside the active build.
2. Align ordinary cooking fixtures with the quaternion acceptance corpus and add native cooking coverage for the authored-point correction.
3. Complete the bake writer/loader, sidecar validation, transactional directory publication and tool workflow. These were not completed before extraction.
4. Complete runtime/interactive demonstration and milestone acceptance after the owner resumes that feature work. No complete authoring UI is claimed.

Direction records: [milestone issue](https://github.com/fesoliveira014/c3d.c3l/issues/267#issuecomment-6047780415) and [collision PR](https://github.com/fesoliveira014/c3d.c3l/pull/326#issuecomment-6047783077).
