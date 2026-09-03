# Contributing

Read `AGENTS.md` first, then `docs/style.md`. Both are mandatory, and neither is optional for a
one-line change.

- `AGENTS.md` carries the project rules: module layout, import boundaries, docstrings, comments,
  what counts as over-checking and over-testing, and the change workflow.
- `docs/style.md` is the style baseline: naming, definition order, call formatting, initializers,
  error handling, and the review checklist.

Before every commit:

```bash
python3 scripts/build.py --test
```

Broken builds are never committed.

Never run `c3fmt`. It is line-length aware but not argument aware, and it breaks the call format
and the one-fault-per-line faultdefs. Hand-format to the guide.

Read your own diff top to bottom before committing.
