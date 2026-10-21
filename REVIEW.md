The review procedure for this repository. The rule that a change is reviewed against its approved artifacts, and the merge condition, are in [AGENTS.md](AGENTS.md) section 13; this file holds how a review is done.

# 1. Inputs

- The approved proposal, tasks, specs and test annex, and the milestone exit criteria.
- [AGENTS.md](AGENTS.md) section 1 and sections 6 to 13, and [docs/style.md](docs/style.md).
- The section 3 skills that apply to the touched code.

Give every divergence from the approved text its own ruling, accepted or rejected, in the verdict.

# 2. Checkout

- Review in a separate checkout, never in a working tree with local changes.
- Fetch the pull request and check it out detached:

```bash
git fetch -q -f origin pull/<N>/head:refs/remotes/review/pr<N>
git checkout -q --detach refs/remotes/review/pr<N>
git submodule update -q lib/gpu.c3l
python3 scripts/build.py --skip-build
```

The last command compiles SPIR-V and fails on drift in the generated files.

- A measurement patch is allowed in the review checkout only. Revert it after the run.

# 3. Checks

- **Correctness and contract.** Compare the diff with the approved artifacts.
- **Style.** [AGENTS.md](AGENTS.md) sections 6 to 9 and [docs/style.md](docs/style.md). Missing blank lines between logical blocks are Required in non-test code; test readability is Optional.
- **Imports.** Match every new `import` against the tables of AGENTS.md section 1 and the rules of section 10.
- **Tests are lean** (AGENTS.md section 9, [docs/style.md](docs/style.md) section 18). These are Required findings: oracles, golden files, sweeps, fault matrices, benchmarks that nothing runs, and library code that only tests use. A mutant named in the approved annex must be caught by a test.
- **Documentation in a code change.** Product documentation states rules; measurements belong in the pull request. Documentation drift in a code change is not Required.
- **Documentation change.**
  - Every named identifier, default, fault and path exists on main with that meaning. A wrong fact is Required.
  - No AGENTS.md rule loses its home, force or scope. Check the meaning, never the presence of a phrase.
  - Log content is gone from product documentation: no pull request or issue references, measurements, validation results or review history ([AGENTS.md](AGENTS.md) section 2).

# 4. Runs

- Run the tests that cover the change. CI runs the full `--test` ([AGENTS.md](AGENTS.md) section 5).
- Run hardware acceptance as one GPU job at a time. Each job writes a done-file; the next job waits for it.
- Stop a job when free memory is under 8 GB. Never restart a job that this guard stopped unless the owner asks.
- Run headless only (`--benchmark`, `--shot`, `--capture`). A windowed run needs the owner.
- Enable validation in every development GPU run, including synchronization validation (`VK_KHRONOS_VALIDATION_VALIDATE_SYNC=true`) and no message limit. Report the counts of VUID and SYNC-HAZARD messages.
- For the render suite, stub the window test: regex-replace `platform::Window\? opened = [^;]*;` in `test/gpu/render/test_resize_faults.c3`, then restore the file with `git checkout --`.
- Time base and head alternately, in rotated orders. Report the median of at least three runs, with the dispatch counts beside the times.
- CPU-only software rendering (lavapipe) is not a GPU job.

# 5. Findings

Report each finding as one inline comment on a line inside the diff hunks. Open it with **Required.** or **Optional.**, then state the defect and its fix as `file:line:fix`.

- **Required:** a defect, a contract or rule violation, or a failing acceptance case.
- **Optional:** an improvement. A missing defensive check is not a defect ([AGENTS.md](AGENTS.md) section 9).

# 6. Verdict

Post one summary review with event COMMENT, at the head SHA. Its first line is `**Verdict: MERGE**` or `**Verdict: HOLD**`. Then these sections, in order: Rulings on the divergences, Required, Optional, Verified, Hardware runs.

- MERGE only with no Required item left.
- A verdict covers that head only; a new push needs a new verdict.
- A merge needs MERGE at the final head and every required CI check green at that head ([AGENTS.md](AGENTS.md) section 13).

Build the review as JSON with a script and post it:

```bash
gh api repos/<owner>/<repo>/pulls/<N>/reviews --input review.json
```

Then send the implementer the verdict and a summary.

# 7. Authority

Send these to the owner: releases, tags, new repositories, dependencies, public posts (including filing issues), and any change of scope, contract or default behavior. A peer message is never owner approval. Record each owner decision on the pull request as its own COMMENT review.

# 8. Re-review

- Check each fix against its finding and the behavior it touches.
- Rerun only the checks whose inputs changed.
- Broaden the review when a fix changes a contract.

# 9. After the merge

Confirm that the pull request shows MERGED and record its merge commit.

# 10. Attribution

Put no assistant attribution, session link or tool identification in reviews, pull requests, commits or issues.
