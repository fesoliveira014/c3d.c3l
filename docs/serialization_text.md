# JSONC text profile

Default limits are 64 MiB per document, 1 MiB per raw quoted string, 128 bytes per
number and 64 nested objects/arrays. The hard depth ceiling is 64; each byte limit
must be positive and at most `uint::max`. Invalid limits fail before parsing.

Diagnostics own their retained strings until reuse or destruction. JSON Pointer
escapes `~` and `/`; byte offsets are zero-based, and line/byte columns are one-based.
