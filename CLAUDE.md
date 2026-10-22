<!--
SPDX-FileCopyrightText: 2021 ash_json_api_wrapper contributors <https://github.com/ash-project/ash_json_api_wrapper/graphs/contributors>

SPDX-License-Identifier: MIT
-->

# CLAUDE.md

This is a public fork of `ash-project/ash_json_api_wrapper`, an Ash data layer
for wrapping external JSON APIs. Work here adds pluggable query dialects
(Cube.js, OData, ...) and better resource generation from OpenAPI specs, with
the aim of offering it upstream.

## Branches and upstream pull requests

- `main` mirrors `upstream/main`. Never commit to it; update it with
  `git fetch upstream && git push origin upstream/main:main`.
- `next` is the default branch: `main`, then exactly one `fork: tooling`
  commit, then the fork's work. The tooling commit holds everything that
  must never go upstream: `CLAUDE.md`, `.githooks/`, `scripts/leak-check.sh`,
  `scripts/install-hooks.sh`, `.github/workflows/leak-check.yml` and the
  fork-only CI changes in `.github/workflows/elixir.yml`. Changes to these
  files are folded into that commit (`git commit --fixup` + `GIT_SEQUENCE_EDITOR=: git rebase -i
  --autosquash main`), never added as separate commits.
- Feature branches start from `next`. Their commits never touch the tooling
  files, so each feature can go upstream on its own.
- To offer a feature upstream: `git switch -c upstream/<topic> upstream/main`,
  cherry-pick the feature's commits, and open the pull request from that
  branch. The tooling commit is not part of it.
- When upstream moves: update `main`, then `git rebase main next` (the
  tooling commit stays first) and force-push `next`.

## Everything here is public

Code, tests, fixtures, commit messages, branch names, issues, pull requests
and CI logs are all public. Write them as if for any user of the library:

- Never name the applications, vendors or customers this library is used
  with, and never describe how or why someone uses it. Explain features by
  what they do in general terms.
- Examples and test fixtures use public APIs with public specs (for example
  Microsoft Graph for OData) or made-up APIs written from public documentation.
  Never copy a spec, payload or recorded response from a real integration.
- When a public API serves as an example, pick broad, generic entities rather
  than the subset a real integration happens to need.

### Leak check

`scripts/install-hooks.sh` sets `core.hooksPath` to `.githooks`, which checks
staged changes, commit messages and pushes against a denylist. The list lives
outside the repository in `~/.config/leak-denylist/terms` locally and in the
`LEAK_DENYLIST` Actions secret in CI; never add it to the repository, since
the list itself would give away what it protects. The CI job also checks pull
request text, issues and comments. A failure only reports where a term was
found. Fix the text (for commits: rewrite them before pushing) rather than
working around the check.

## Development

```bash
mix deps.get
mix test
mix check   # format, credo, dialyzer, docs (see .check.exs)
```

Every new file needs an SPDX header (the upstream CI runs `reuse lint`).
