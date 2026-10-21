# Contributing

Build and run c3d with the [README](README.md). Then read, in this order:

- [AGENTS.md](AGENTS.md): the project rules. Mandatory at the start of every task. Module and import boundaries, simplicity
  rules, verification, and the change workflow. It names the other pages and says when to read them.
- [docs/style.md](docs/style.md): the code style baseline for every `.c3`, `.c3i` and `.glsl` file. Mandatory for code work.
  Naming, call and declaration formatting, error handling, docstrings, comments, tests and the review checklist.
- [docs/architecture.md](docs/architecture.md) and [docs/development.md](docs/development.md): layers, modules, add-on
  packages and feature flags; the build, shader pipeline, test targets and acceptance projects. Read them when your task
  touches those areas.
- [REVIEW.md](REVIEW.md): how your change is reviewed.

## Before you commit

- Run the checks that cover your change: the failing case and the targets it affects, for instance
  `c3c test <target> --path <project>`. The full `python3 scripts/build.py --test` is the CI gate and runs on every pull
  request; you do not need it before each commit. The rules are in [AGENTS.md](AGENTS.md) section 5.
- Read your own diff top to bottom. Do not commit a known build failure.
- Hand-format to the style guide. Do not run `c3fmt` ([docs/style.md](docs/style.md) section 19).
