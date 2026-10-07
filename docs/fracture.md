# Fracture workspace and exact arithmetic

`c3d::physics::fracture` provides bounded workspaces, exact arithmetic, filtered
geometric predicates and centered quantization. Solid validation, Boolean construction,
Voronoi partitioning and collision reconstruction are separate implementation
layers; workspace availability does not imply those operations are delivered.

## Workspace contract

`create_fracture_workspace` makes one aligned allocation of `scratch_bytes`.
Counts must be positive, and `resolution_m` must be finite and positive. The
workspace owns its allocation until `destroy_fracture_workspace`, which clears
the owner. Its public fields are observational; do not edit them or destroy
shallow copies. An operation exclusively borrows one workspace. Independent
workspaces share no mutable state.

`MIN_FRACTURE_SCRATCH_BYTES` reserves all fixed arithmetic storage. Smaller
limits return `INVALID_ARGUMENT` at creation. On the supported C3 0.8.3 targets,
the block is 24,800 bytes: 24 values of 1032 bytes plus counters. Each value has
8192 magnitude bits and sign/used-length metadata. Byte-size overflow or an
allocator failure returns `CAPACITY_EXCEEDED`, with no owner. Geometry scratch
will need space beyond this arithmetic minimum and remains bounded by the same
allocation.

Wide values always reside in this block. Stack values contain only pointers,
small borrowed limb views, indices and native scalars. Arithmetic operates on
used limbs and allocates nothing. Add, multiply and left shift report
`NUMERICAL_FAILURE` on fixed-width overflow; no truncated result is accepted.
Magnitude division and GCD share the same reserved values.
Acquiring a value beyond the reservation returns `CAPACITY_EXCEEDED` before
writing to storage. A failed nested acquire restores the caller's temporary
count; the block remains immediately reusable.

## Representation bounds

Fracture filters require strict floating point at CLI `O0`–`O3`.
`fracture_test` sets `fp-math: strict` explicitly. At `O4`/`O5`, C3 0.8.3
exposes optimizer level `O3`; floating filters are compiled out and every
predicate uses the exact path. This also applies to explicit strict builds at
those levels and loses the filter speed-up. Unrelated physics builds remain
available at every level. Explicit relaxed/fast overrides at `O0`–`O3` remain
undetectable and unsupported. Tests cover `O0`, `O3` and exact-only `O4`.

Generation uses centered integer coordinates with `abs(q) < 2^30`. Its grid
step is the largest power of two at or below `resolution_m / 16`, using
nearest-even quantization. The anchor is the lower bound; its integer center is
the nearest-even midpoint offset in grid units. Quantization rounds relative to
that center using exact integer arithmetic, including half-step parity.
Out-of-range coordinates produce `NUMERICAL_FAILURE`; there is no coarser retry.
The solid-validation layer must reject topology invalidated by quantization.

Interval operations round both bounds outwards. A sign is accepted only when
the interval excludes zero or is exactly zero; otherwise the exact predicate
runs. Homogeneous coordinates are rescaled together by a power of two before
filtering. Vertex identity compares exact cross-products, never plane IDs.
Direct grid-point tetrahedra fit native `int128` (96 bits); implicit vertices
use the reserved wide arithmetic. Predicate counts, filter counts and elapsed
exact-predicate fallback nanoseconds are recorded in the workspace.

Collision reconstruction will consume published float surfaces exactly, without
quantizing them again. A finite float has magnitude below `2^277` in units of
`2^-149`. Source-triangle supporting planes fit 896-bit stored coefficients.
Constructed vertices are implicit plane triples with homogeneous coordinates.

| Bound in bits | Quantized domain | Exact float domain |
|---|---:|---:|
| Input coordinate | 30 | 277 |
| Plane normal | 63 | 557 |
| Plane offset | 95 | 836 |
| Homogeneous denominator | 192 | 1674 |
| Homogeneous numerator | 224 | 1953 |
| Four-vertex orientation | 869 | 7538 |
| Plane test of an interior representative | 867 | 7536 |

The orientation bound follows from a four-by-four determinant's 24 terms:
`3*1953 + 1674 + 5 = 7538` bits. Interior classification uses the mean of four
affinely independent cell vertices and tests it against existing integer planes.
New planes come from source triangles, shared site bisectors or bounded axis
splits. There is no repeated construction from growing rational expressions.
Exact volume sums over at most `uint::max` float triangles need at most 866 bits;
their centroid moments need at most 1145 bits.

## Live temporary budget

The arithmetic functions need zero additional wide values for add, multiply,
shift and float conversion, one for magnitude division, and five for GCD.
The following geometric layers are designed to fit these total live bounds,
including caller-held operands and outputs:

| Operation | Maximum live values |
|---|---:|
| Triangle-plane construction | 21 |
| Four-vertex homogeneous orientation | 20 |
| Four-vertex interior representative | 23 |
| Volume and centroid accumulation | 20 |

All top-level operations reserve 24 values. Triangle-plane construction releases
its point/edge temporaries before coefficient normalization. Cell traversal is
iterative and never retains arithmetic temporaries across child processing.
Measured peaks must confirm these bounds when those layers are implemented.
The required fixture measurements also record predicate count, filter fraction
and exact-arithmetic time separately for generation and reconstruction.
Tests verify the implemented peaks: 21 for planes, 20 for orientation,
11 for identity and 9 for quantization.
