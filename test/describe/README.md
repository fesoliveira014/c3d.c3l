# Description test consumers

Private visitors that exercise the `c3d::describe` contract against a shared example component, an owned-data fixture
and a numeric fixture. They are test code, not production serialization APIs or formats. The description contract itself
is in [type descriptions](../../docs/type_descriptions.md).

## Files

| File | Holds |
| --- | --- |
| `fixtures.c3` | The fixture types and the limits below. |
| `binary.c3`, `binary_tests.c3` | A little-endian binary reader and writer with length-delimited scopes, and its tests. |
| `json.c3`, `json_tests.c3` | A JSONC reader and writer over the standard library DOM, and its tests. |
| `events.c3` | A recorder that copies visit callbacks into fixed storage, and the tests that compare reflected and authored descriptions in every mode. |
| `references.c3` | Symbolic fixture tokens for entity and asset references. |
| `faults.c3` | `INVALID_FIXTURE` and `CONSUMER_ABORT`. |

The core description and device-free inspector contract tests (`test/src/test_describe*.c3`) build into the same target.

## Fixture limits

| Limit | Value |
| --- | --- |
| Elements or bytes in a dynamically allocated slice or string | 64 |
| Total destination storage | 32 KiB |
| Nesting | 16 scopes |
| Allocations tracked per read | 64 |
| Fixture buffer | 16 KiB |

The fixture reader allocates every destination through a bounded ledger. A successful read keeps the storage until the
caller releases it, and a fault releases everything. The JSONC reader uses the standard library DOM, which allocates
infallibly, so the tests make no out-of-memory guarantee for parsing.

## JSONC fixture text

- Every described field is required. A missing field, a wrong shape, an out-of-range integer or an invalid enum or
  reference token returns `INVALID_FIXTURE`.
- Finite floats use 9 significant digits and doubles 17, with an explicit `-0.0`. Non-finite values are the strings
  `"f32:%08x"` and `"f64:%016x"` of their bits. Unsigned 64-bit values are quoted decimals.

## Run

```bash
c3c test describe --path test
```
