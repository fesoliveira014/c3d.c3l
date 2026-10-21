# Contributing

Build and run c3d with the [README](README.md), then read these before you change anything. They are mandatory, and none of
them is optional for a one-line change.

- [AGENTS.md](AGENTS.md): the project rules. Module and import boundaries, simplicity and testing rules, verification, and the
  change workflow.
- [docs/style.md](docs/style.md): the code style baseline for every `.c3`, `.c3i` and `.glsl` file. Naming, call and
  declaration formatting, error handling, docstrings and the review checklist.
- [docs/development.md](docs/development.md): the build, the shader pipeline, the test targets and the acceptance projects.
- [docs/architecture.md](docs/architecture.md): layers, modules, add-on packages and feature flags.

## Before you commit

- Run the checks that cover your change: the failing case and the targets it affects, for instance
  `c3c test <target> --path <project>`. The full `python3 scripts/build.py --test` is the CI gate and runs on every pull
  request; you do not need it before each commit. The rules are in [AGENTS.md](AGENTS.md) section 5.
- Read your own diff top to bottom. Do not commit a known build failure.
- Hand-format to the style guide. Do not run `c3fmt` ([docs/style.md](docs/style.md) section 19).
