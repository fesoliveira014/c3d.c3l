# Fracture workspace and solid construction

`c3d::physics::fracture` provides bounded workspaces, exact arithmetic, filtered
geometric predicates, centered quantization, complete private solid validation
and exact source construction records, convex-cell clipping and local face-driven
partitioning with material occupancy and exact planar boundary reconstruction. Public Boolean/Voronoi construction and collision reconstruction remain separate layers.

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
| Source-edge support normal | 31 | 278 |
| Source-edge support offset | 62 | 557 |
| Homogeneous denominator | 192 | 1674 |
| Homogeneous numerator | 224 | 1953 |
| Four-vertex orientation | 869 | 7538 |
| Plane test of an interior representative | 867 | 7536 |

The orientation bound follows from a four-by-four determinant's 24 terms:
`3*1953 + 1674 + 5 = 7538` bits. Interior classification uses the mean of four
affinely independent cell vertices and tests it against existing integer planes.
Partition planes come from source triangles, shared site bisectors or bounded
axis splits. Source-edge support planes are used only for constructions, never
for BSP partition decisions or cell boundaries. There is no repeated construction from growing rational expressions.
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
| Source-edge support-plane construction | 10 |
| Constructed vertex against a plane | 7 |
| Plane-normal independence | 4 |
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
11 for identity, 9 for quantization and 14 for exact shell-volume accumulation.
Source construction records peak at 21 on raw floats and 10 on grid inputs;
no accepted reservation grows.

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


## Exact source construction records

Private construction records preserve each source face's canonical integer
plane and original winding. Each undirected topological edge owns one support
plane. Its owner is the lowest incident face index; the dropped projection axis
is that face normal's first nonzero exact integer component. Lifting the exact
projected edge line through that axis gives a plane whose intersection with the
owner face is exactly the source edge. These coefficient bounds are included
above and remain below the existing general-plane bounds.

At a crease, the edge support plane can coincide with the other incident face.
The defining pair therefore always uses the owner face and the edge support
plane. An original vertex uses the two edges meeting at its corner in its
lowest-index incident triangle. Those two lines are non-collinear; an exact
determinant selects an independent third plane from the second line's defining
pair. The private helper requires a validated non-degenerate source triangle.
Representations selected from different incident faces compare geometrically
equal, including when those faces use different projection axes.

Plane-side queries use outward interval filters and exact homogeneous fallback,
with exact-only behavior at O4/O5. A strict edge crossing yields the owner face,
edge support and cut as its plane triple. A cut through one endpoint reuses the
original vertex representation. A cut containing the edge reports coplanarity
without creating a clipped vertex; a separated edge reports no intersection.

All records borrow the workspace. Construction restores the incoming cursor on
failure and leaves source arrays unchanged. Unreferenced topological identities
have no constructed point. Tests cover flat-face interior vertices, subdivided
collinear boundaries, creases, rational crossings, endpoint and coplanar cuts,
extreme floats, subnormals, grid limits and partial reservation failure.
Construction planes are stored separately from source face planes. The cell
partition test verifies that their presence changes neither cells nor partition planes.


## Convex-cell splitting

Private convex cells store plane-triple vertices, outward polygon faces and
paired edge corners. Bounds use exact source-coordinate minima and maxima,
including raw float subnormals and extremes or the actual quantized coordinates.
An edge's incident face planes define its line. Vertex triples do not encode
every incident plane at non-simple vertices and are never used to infer edge
adjacency.

A split classifies every original vertex exactly or through the strict interval
filter. A tangent or separated cut borrows the unchanged cell and returns no
zero-volume child. A proper split creates one plane triple per strictly crossed
undirected edge, using its two incident face planes and the cut. Vertices on the
cut retain their original triples. Each original polygon is clipped in its
existing order; lower-dimensional remnants are omitted. Boundary half-edges
form one cap cycle, which is emitted once per child in opposite order with the
same plane and opposite orientation. Sorting endpoint identities pairs twins.

Only explicit partition planes enter this layer. Source-edge construction
records are neither inputs to the splitter nor eligible cell boundaries.
The invariance fixture creates the same eight cells with and without those
records, checks identical vertices, faces and paired corners, and confirms
source supporting planes leave that partition unchanged.

Cells and intermediate arrays borrow the fixed workspace. Proper splits retain
their parent and both children; temporary pairing and cap-order arrays release
their scratch tail. A capacity failure restores the incoming cursor and leaves
the parent unchanged. No heap allocation or wider arithmetic reservation is
introduced. Split predicates peak at seven live wide values. The broader
partition fixture also constructs raw source planes, which retains the existing
21-value construction peak. Public generation operations remain a separate
implementation layer.

Tests verify edge incidence, outward winding, exact half-space membership,
nonzero volume, cap identity and orientation, rational volume conservation,
cuts through original vertices and edges, tangency, four-plane vertices of an
octahedron followed by another cut, deterministic partition records, and
capacity failures throughout bounds construction and splitting.


## Local face partition and occupancy

The private partition starts with the source bounds and inserts source triangles
in ascending input index order. Each triangle visits the current leaf cells in
stable order. Its supporting plane is eligible only when the cell has vertices
on both sides and the actual triangle intersects the cell with nonzero area.
Clipping the triangle against every cell face determines this overlap exactly;
support extensions and point or edge contacts alone do not split a cell.

Clipped polygon vertices retain independent line-plane construction records.
An original edge uses its designated owner face and edge-support plane, even
when the current triangle is the other incident face. A newly clipped edge uses
the source face and cell boundary planes. Source-edge support planes never
partition space or become cell boundaries.

A proper split replaces its leaf with negative then positive children. Later
triangles visit those children. Fixed input order reproduces the same ordered
cells; reordering source faces may change the partition but preserves the exact
occupied region. Leaf records and retained parent/intermediate cells borrow the
fixed arena. Capacity failure restores the incoming cursor without changing the
source surface or its construction records.

Occupancy samples the exact mean of four affinely independent cell vertices.
The sample lies strictly inside every cell half-space. Positive homogeneous
denominators keep all comparisons exact. A +Z ray with symbolic X then Y
perturbations counts source-triangle crossings; the source BVH prunes exact
homogeneous comparisons against original coordinate bounds. Odd parity is
material, including nested cavities, islands and disconnected components.

The mean retains four output values and sixteen constructed coordinates, with
three construction temporaries: 23 live wide values at peak. Occupancy reuses
this storage and does not retain a wide value per cell. The fixed 24-value
reservation is unchanged. Small local fixtures peak at 46,456 bytes for a box,
63,744 for a concave prism, 69,432 for two separated boxes, 80,392 for a hollow
box and 114,000 for an outer shell, cavity and island. These totals include
surface validation and source constructions; grid fixture coordinates are
borrowed. They do not represent complete fracture-generation budgets.

Tests cover raw and grid domains, exact region equality across face permutations,
stable repeated records, positive cell volume and volume conservation, oblique
nested shells checked against inverse-transformed bounds, raw subnormals and
extremes, crease-edge construction, support-extension rejection, strict rational
interior samples, and capacity rollback. Public Boolean/Voronoi output and
collision reconstruction remain unimplemented.


## Planar edge normalization

The private planar pass accepts directed coplanar segments with independent
defining plane pairs. It chooses the first nonzero patch-normal axis to drop,
then orders points lexicographically in the remaining coordinates. Identity is
geometric: different plane triples at the same exact position share one point.
Strict segment crossings use the patch plane and one independent plane from
each line. No plane is derived from a rational constructed point.

All original endpoints and strict crossings enter the point set. Each segment
is split at every point on its closed span, covering endpoint contacts,
T-junctions and partial collinear overlaps. Subedges use canonical endpoint
order with signed multiplicity. Integer endpoint sorting groups equal subedges;
opposite counts cancel and same-direction counts remain explicit. Canonical
coefficient order selects a defining line pair when equivalent subedges have
different constructions. Unused points are removed from the returned graph.
This layer returns edges; boundary reconstruction consumes the signed graph.

For positive homogeneous denominators, general projected orientation is a
three-by-three determinant with columns W, X and Y. The accepted raw bounds give
two 1953-bit numerators and one 1674-bit denominator per term; six signed terms
need at most 5583 magnitude bits. The grid bound is 643 bits. Coordinate ordering
needs at most 3628 bits in the raw domain and 417 in the grid domain. Projected
orientation holds twelve point coordinates, one result and three determinant
temporaries: sixteen live wide values. Exact point ordering peaks at eleven.
Compile-time assertions pin the projected bound and temporary schedule against
the unchanged 8192-bit and 24-value reservations. Strict interval filters may
resolve signs and ordering; uncertain and O4/O5 cases use exact arithmetic.

Points, split-edge records and packed output borrow the fixed arena. Failed
construction restores the incoming cursor and arithmetic count. Complete
cancellation restores the cursor on success too. Input permutations preserve
the ordered geometric graph. Two crossing segments peak at 25,512 bytes with
five points and four edges. One face canceled against two opposite half-faces
peaks at 26,480 bytes and retains only the 24,800-byte arithmetic block. These
measurements borrow fixture planes and include no source validation or complete
surface reconstruction. No reservation grows.

Tests cover rational crossings, T-junctions, independent line selection,
collinear overlaps, signed multiplicity, opposite subdivisions, canonical
permutations, raw finite extremes and subnormals, near-grid-limit coordinates,
nearly collinear filtered signs, and storage/arithmetic exhaustion with reuse.


## Boundary patches

The private boundary pass emits directed faces from occupied cells. Exact planar
noding cancels every shared subedge, including unequal face subdivisions. Empty
cells emit nothing. Each surviving plane must match a source plane or an explicit
cut plane; missing provenance violates a private contract. Source patches clip
each original triangle against the contributing cells before cancellation, so
coplanar triangles with different provenance remain distinct.

Contours follow the signed graph in exact point order. Each vertex needs one
incoming and one outgoing edge with unit weight. Open or branched boundaries,
repeated edges and inconsistent nested winding produce NON_MANIFOLD_RESULT.
Exact containment assigns the nearest enclosing contour; parity distinguishes
outer contours, holes and nested islands. Collinear subdivision points are
removed first. A second pass inserts every retained patch point lying on another
patch edge, preserving conforming boundaries between planes and provenance
regions. Reconciliation stages its output and leaves the input patches unchanged
on failure. Every operation uses the fixed workspace.

Patches sort by canonical plane coefficients and an oriented source-triangle key
rotated to its lowest topology identity. The key survives source-face shuffling;
the stored face index maps back to that input's attribute arrays. Original render
corner indices retain the input triangle's order. Exact three-corner recognition
marks unchanged source triangles after reconciliation. Uncut box, concave prism,
hollow box, nested shell/cavity/island and disconnected fixtures reproduce the
same triangles, corner identities, provenance and count in both domains. Oblique
cut fixtures also preserve ordered patches under source-face permutations.

Boundary reconstruction alone peaks at 16 of the existing 24 wide values. Total
scratch peaks, including retained validation, source and partition records, are
78,324 bytes for the box, 122,748 for the concave prism, 136,692 for disconnected
boxes, 162,420 for the hollow box and 228,284 for nested shells. Both domains have
the same measured storage. No reservation grew. These are private reconstruction
measurements; complete generation, shared triangulation and float publication
remain separate acceptance work.
