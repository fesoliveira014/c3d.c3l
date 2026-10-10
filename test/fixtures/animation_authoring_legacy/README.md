# Historical weighted and planar animation authoring

These streams were captured with the unchanged registered Animator v2 and
AnimatedCrowd v3 writers at `ccab31a73f6f6a2b6bd358bf64ce554e618d1674`.
The manual recipe guards both registered versions before writing. It never
patches the old codec, its authoring descriptions or its projection.

The source is `test/fixtures/gltf/skin.gltf`, SHA-256
`2d63048337e5b5e0e2e6ba3eac5ebe5ce9a619c8aea7c0e27a99d4c48d86a7fc`.
Load it with model key `animation_authoring_legacy/model`; its generated clip key
is `animation_authoring_legacy/model#anim/0`. The streams contain keyed
references, not clip payloads.

The Animator has root node 2, a paused/nonlooping EXTRACT yaw base action with
speed -0.5 and weight 0.6, and three additive MULTIPLICATIVE members on layer 1.
Their copied weighted row is `(0,0.25,0.5,0.75)`. The 2D group's points are
`(-1,-1)`, `(2,-1)`, `(-1,2)`, authored triangle `(2,1,0)`, parameter `(0.5,0.25)`,
weight 0.75 and speed -0.25; it is paused. The recipe deliberately sets nonzero
runtime clocks and phase before saving; the writer omits them.

The crowd has count 2, capacity 3, four actions per instance, event capacity 17
and tracing enabled. Instance 0 has the same base and 2D membership, root node 2,
base ordinal 0 and authored start 0.125. Its placement has positive uniform
scale 2. Instance 1 is explicitly configured with empty playback and has a
reflected, nonuniform placement. The prepared capture follows actual preparation
and an update of 0.25 seconds. Its binary and JSONC bytes match the pending
capture because projection omits runtime state.

Reproduce from an untouched checkout at the commit above. Copy this manual
recipe into `test/animation_authoring_freeze`; it is outside the normal test
sequence. Use pin-matched dependency artifacts and the compiler's default safe
mode:

```powershell
git submodule update --init
git -C lib/gpu.c3l submodule update --init
git -C lib/cgltf.c3l submodule update --init
git -C lib/ufbx.c3l submodule update --init
c3c build animation_authoring_freeze --path test/animation_authoring_freeze
Copy-Item lib/shaderc.c3l/windows/shaderc_shared.dll test/animation_authoring_freeze/build/
& test/animation_authoring_freeze/build/animation_authoring_freeze.exe C:/tmp/c3d-authoring-v2-freeze C:/tmp/c3d-issue-353-motion/test/fixtures/animation_authoring_legacy
```

Captured with C3 0.8.3, compiler git
`1d155ee04d3b607261b99aa15ed5eefd6d7db284`, LLVM 22.1.8, Windows x64,
static CRT and no optimization override. `SHA256SUMS` covers all six streams and
the retained recipe/project. The receipt is in the change artifacts.
