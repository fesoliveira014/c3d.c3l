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
