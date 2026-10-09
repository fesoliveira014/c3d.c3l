# Profile animation fixture

Format version: 1. File: profile_animation_v1.fbx.
Repository-authored ASCII FBX 7.4, under the repository MIT license. It contains numeric transforms and animation data only. No third-party asset data was copied.

The format structure follows the vendored ufbx parser and its ASCII examples. Its units are metres (UnitScaleFactor 100), with positive X/Y/Z axes and Y up. A second is 46186158000 FBX ticks.

The implicit root is omitted from the imported template. The authored hierarchy is:

| Template index | Name | Parent | Local translation | Local rotation/scale |
| --- | --- | --- | --- | --- |
| 0 | Carrier | -1 | (0,0,0) | Identity/(1,1,1) |
| 1 | Hip | 0 | (0,1,0) | Identity/(1,1,1) |
| 2 | Foot | 1 | (0,-1,0) | Identity/(1,1,1) |

Stack Translate (objects 200-203) moves Carrier X from 0 to 1 over one second. Stack Scale (300-303) changes Hip X scale from 1 to 2 while Y/Z remain 1; this is deliberately unsupported by calibrated profile baking.

Derived inputs are constructed in memory from this exact file:

- Clean: replace the sole "a: 1,2" value array, in curve 303, with "a: 1,1". Both stack identities and all hierarchy/rest fields stay unchanged.
- Renamed source: replace "Model::Hip" with "Model::RenamedHip".
- Empty stacks: retain the complete file prefix through the three Model objects, omit objects beginning at "AnimationStack: 200" and all later animation objects, then close Objects and supply only connections 100->0, 101->100 and 102->101. The three model nodes remain unchanged.
- Empty stacks with mismatched source: apply the Hip rename to the empty-stack input.

The clean first stack has analytic Hip/Foot model positions (t,1,0)/(t,0,0), for t in [0,1] seconds, under identity calibration and facing. A separate target calibration rotates Hip 45 degrees about +Z while preserving authored target locals.

profile_animation_v1.sha256 records the committed base file hash. profile_animation_LICENSE.txt contains the applicable license.

## Turning fixture

profile_turning_v1.fbx is a separate repository-authored ASCII FBX fixture with
the same hierarchy and units. Hip's authored rotation is 20 degrees about Y.
Turn90 and Turn360 animate Hip's Y rotation from 20 to 110 and 380 degrees,
respectively, over one second. Both use five equally spaced linear keys; no
scale or translation curve is present. Tests prepare an offset, yawed and
uniformly scaled target carrier and compare the profiled EXTRACT branches with
the independently loaded KEEP branches at keys and subkeys.

profile_turning_v1.sha256 records its file hash. The same MIT license applies.
