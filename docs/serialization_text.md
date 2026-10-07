# JSONC text profile

Default limits are 64 MiB per document, 1 MiB per raw quoted string, 128 bytes per
number and 64 nested objects/arrays. The hard depth ceiling is 64; each byte limit
must be positive and at most `uint::max`. Invalid limits fail before parsing.

Diagnostics own their retained strings until reuse or destruction. JSON Pointer
escapes `~` and `/`; byte offsets are zero-based, and line/byte columns are one-based.

Finite float/double values use `%.9g`/`%.17g`: after rounding to nine/seventeen
significant digits, use exponent form when the decimal exponent is below -4 or
at least the precision; otherwise use fixed form. Remove trailing fractional
zeros and an unnecessary decimal point. Signed zero is `-0.0`.
Non-finite values use only quoted `f32:` plus eight lowercase hexadecimal digits
or `f64:` plus sixteen; finite-bit tokens and mismatched widths are rejected.
Parse finite values directly from their original lexemes into the destination
width. Wide signed/unsigned integers use quoted decimal strings; narrower
integers require numeric tokens without a fraction or exponent. Quoted integers
have no leading zeros or negative-zero spelling; zero is exactly `"0"`.

## Text subtree export

`write_subtree_text` emits deterministic parent-before-child records, document-local
node IDs, every authored node field and every non-transient described component
field. Output belongs to the supplied allocator. Each used binary-only component
returns `UNSUPPORTED` with its node path and registered type name.

Set `TextWriteOptions.omit_binary_only` only with an initialized `OmissionReport`.
Every omitted component is listed by node path and type name; report strings and
entries belong to its allocator and are released by `destroy_omission_report`.
Diagnostics and reports are cleared before each call, including failed calls.
Partial reports are released if report allocation fails. This export shares the
binary collector/projection path; component collection faults retain their details.

## Text subtree import

`read_subtree_text` reads one complete JSONC document. Nodes have contiguous
zero-based document IDs and may appear in any record order; names may be empty
or repeated. Siblings are created in ascending document ID order, independently
of descendant IDs. Scene linking prepends each child, so the resulting sibling
list has descending IDs, as it does for canonical binary records. The reader requires one root, live in-document parent references
and an acyclic connected graph before creating nodes. It restores local/world
transform mode, layers and authored visibility under the requested live parent.

Described components decode before validation, then attach in the existing
restore phases. Validators can borrow another component's decoded authoring
through `ReadContext.authored`. Reader-owned strings, arrays and scratch storage
are released after attachment or failure; attachments copy retained values.
A failed import removes the newly created subtree. A supplied diagnostic retains
the JSON Pointer, source position, node record path and component name.

## Container contract checks

The text contract target injects failure at every reader acquisition starting from
raw JSONC text: parser values/strings/key storage, graph ordering, component DTOs,
cloned defaults and dynamic overlays. Rollback checks retain every existing node
field, component values, asset counts, key identity and revisions. A separate
attachment fault runs after an earlier owned component attaches and verifies its
removal. Reader-owned allocations return to zero in both paths.

Embedded subtrees use a caller-extracted source span; diagnostics are relative to
that span. The container reader still requires exactly one document. Explicitly
listed older text versions use current semantic defaults; unknown components are
skipped only when requested, and their syntax remains validated. Mixed text and
binary-only exports restore every retained component and omit only report entries.

[Authored lookup measurements](serialization_lookup.md) record the large-document
case and its local, review-pending performance evidence.
