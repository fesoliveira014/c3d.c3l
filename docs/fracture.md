# Fracture workspace and surface validation

`c3d::physics::fracture` provides bounded workspaces, exact arithmetic, filtered
geometric predicates, centered quantization and private topology/intersection
validation. Complete solid validation, Boolean construction, Voronoi partitioning and
collision reconstruction remain separate implementation layers.

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

## Surface input and topology

`SolidMeshView` borrows indexed triangle geometry, one explicit topological ID
per render vertex and one material label per triangle. Topological IDs are dense;
render vertices sharing an ID have exactly equal positions (either signed zero
is accepted). Different IDs are never welded by distance. Unreferenced render
vertices are allowed. Bounds stored in `Geometry` are not trusted or modified.
Normals, tangents, colors and both UV streams are optional but must match the
position count when present. All scalar attributes must be finite.

Private validation rejects malformed streams with `INVALID_ARGUMENT` and
unsupported topology, deformation or custom attributes with `UNSUPPORTED`.
Sorted edge records require two oppositely directed faces per edge. Every used
vertex has one connected face fan; pinched connections fault even when each
edge has two faces. These topology defects produce `INVALID_SOLID`.
Disconnected closed shells are retained with their lowest source face as a
stable shell key. Topology alone does not establish a valid geometric solid.
The surface layer below adds zero-area and intersection checks; nesting and
orientation remain a separate validation layer.

Topology arrays and temporary edge records use the existing workspace, without
another allocation. Reservations align absolute addresses and check byte/count
overflow before writing. A failed call restores its incoming cursor, including
failure after earlier successful reservations. The recorded peak includes
temporary edge storage; successful construction releases that temporary range.
All validators remain private. Tests exercise `O0`, `O3` and `O4`, including
bit-based finite checks that remain effective under fast floating-point math.

## Surface geometry and diagnostics

Private surface validation rejects zero-area triangles and intersections beyond
shared topological vertices or edges. It covers coplanar overlaps, edge/face
piercing and unshared vertex contacts. Every contact between distinct shells is
invalid, including a lone touching vertex. The checks use exact projected and
tetrahedral orientation predicates; strict filters may certify raw-float signs,
while uncertain cases and O4/O5 builds use exact arithmetic. Projected grid
orientation fits native `int128`. No intersection coordinate is approximated.

An AABB hierarchy accelerates candidate selection. Quantized bounds use integer
coordinates. Raw bounds use signed monotonic float-bit keys, preserving
subnormal ordering without floating arithmetic. Construction splits the widest
key range (axis order breaks ties), sorts by summed bound keys then source face
index, and divides the range in half. Queries visit source faces in ascending
order and traverse left children first; each unordered pair is checked once.
The first offending pair therefore has a deterministic order. Private diagnostic
data reports its source face indices and defect kind. A degenerate face names
itself twice; success and failures before geometry checking leave sentinel IDs.

Hierarchy and surface arrays remain in the workspace. Failure restores the
incoming cursor. Tests compare contacts under exact affine transforms, in raw
and grid domains, including extreme floats and subnormals. The separated-shell
fixture has 32 tetrahedra and 128 triangles: the hierarchy tests 192 candidate
pairs out of 8,128 possible pairs, including valid adjacent-face contacts.
It reproduces the same face order and first diagnostic across repeated runs.
## Shell nesting and quantized validity

Complete private input validation measures each shell's signed volume exactly.
Raw float coordinates use their integer units of `2^-149`; summing at most
`uint::max` triangle determinants needs at most 866 bits. The existing 896-bit
packed integer holds each shell total. Two shared arithmetic values and nine
coordinates plus three determinant temporaries give a measured peak of 14 live
wide values for this pass. Grid inputs use the same exact accumulation. A zero
sum produces `INVALID_SOLID` with a private degenerate-shell diagnostic.

Containment uses the first vertex of each shell's lowest-index face. Prior
intersection validation excludes every contact between distinct shells, so this
query is strictly inside or outside another shell. A fixed positive-Z ray uses
one symbolic query perturbation `(epsilon, epsilon^2, 0)`. Projected edge signs
resolve a zero constant by `-dy`, then `dx`; no numeric epsilon, retries or
constructed intersection positions are used. Parallel projected faces do not
cross the ray. Exact tetrahedral signs select forward intersections.

Shell bounds come from existing face bounds. Non-enclosing shell pairs are
pruned; ray queries reuse the existing hierarchy. Each shell's parent is its
containing shell with the smallest absolute exact volume. Even nesting depths
must have outward positive volume; odd depths bound cavities and must have
negative volume. Depth-two islands and disconnected outer shells are supported.
Wrong winding produces `INVALID_SOLID` and a stable private shell index.
Counters retain candidate triangle pairs, shell pairs, containment queries and
candidate containment faces separately for raw and grid validation.

The private validator accepts an optional caller-supplied common grid. It first
validates the original float solid, then quantizes its used topological vertices
and repeats geometric validity, nesting and orientation on the actual grid
coordinates. It reuses the topology and hierarchy arrays. Unreferenced vertices
are not quantized. A valid source that collapses, touches another shell, changes
winding or otherwise becomes invalid produces `NUMERICAL_FAILURE`; malformed
original solids retain `INVALID_SOLID`. Any rejection restores the incoming
scratch cursor and publishes no result. All input arrays remain borrowed and
unchanged. Public Boolean, Voronoi and collision-generation operations remain
unimplemented.

Tests validate a lone 12-triangle box in both domains, then nested boxes and
islands, reordered shell inputs, disjoint boxes, reversed winding, subnormals
and extreme float coordinates. Fixed-ray cases hit a triangulation edge, an
octahedron apex, a parallel exterior face and a supporting-plane extension.
Quantization cases cover collapse, cross-shell contact and orientation reversal.
