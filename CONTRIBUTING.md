# Contributing to MongrelDB Julia

Thanks for taking the time to help the MongrelDB Julia client. This document
describes how to propose a change, what we expect from a pull request, and
the coding standards that apply to the codebase.

If anything here is unclear or out of date, open an issue or a PR.

## Code of conduct

Be kind, be specific, assume good faith. Disagree about the technical
details, not the person. Public reviews stay focused on the diff.

## How to propose a change

The MongrelDB Julia client uses a standard **fork -> branch -> pull request**
workflow on GitHub.

1. **Fork** [`visorcraft/MongrelDB-Julia`](https://github.com/visorcraft/MongrelDB-Julia)
   to your GitHub account.
2. **Clone** your fork and add the upstream remote:

   ```sh
   git clone git@github.com:<you>/MongrelDB-Julia.git
   cd MongrelDB-Julia
   git remote add upstream https://github.com/visorcraft/MongrelDB-Julia.git
   ```

3. **Branch** from `master`. Pick a descriptive, kebab-case branch name:
   `fix-query-builder-alias`, `feature/sparse-vector`, `docs/auth-guide`.

   ```sh
   git fetch upstream
   git switch -c my-change upstream/master
   ```

4. **Make focused commits.** One logical change per commit. Run the
   preflight (see below) before pushing.
5. **Open a pull request** against `master` on `visorcraft/MongrelDB-Julia`.
   Fill in the PR template:
   - **What.** One paragraph summary of the change.
   - **Why.** Bug fix? New feature? Doc fix? Link the issue if one exists.
   - **How to test.** The exact commands a reviewer should run.
   - **Risk.** What might break? What did you not test?

## Before you push: preflight

Run the full CI preflight locally:

```sh
julia --project=. -e 'using Pkg; Pkg.instantiate()'
julia --project=. test/json_test.jl
```

All steps must pass with zero warnings. If a check fails, fix the root
cause, do not silence the linter or skip the test.

To run the live integration suite (requires a running `mongreldb-server`):

```sh
MONGRELDB_URL=http://127.0.0.1:8453 julia --project=. test/live_test.jl
```

Live tests self-skip when `MONGRELDB_URL` is unset or unreachable.

## What we look for in a review

- The change does one thing and does it well.
- Behavior changes ship with tests. New client behavior: a unit test in
  `test/json_test.jl`. Wire-format changes: update the test so the exact
  outgoing JSON keys stay covered. Daemon-dependent coverage: a test in
  `test/live_test.jl` that skips cleanly when no server is available.
- The change keeps this repo a thin client over `mongreldb-server`. Do not
  re-implement storage, indexing, WAL, or SQL planning logic here.
- Documentation is updated alongside the code (`docs/`, `README.md`) if the
  change affects users.
- Commits have clear messages (see below).

## Coding standards

### Julia

- **Version.** Julia 1.9+. Do not drop the minimum casually.
- **Style.** Four-space indentation, module-level docstrings on public
  functions, explicit return types on the public API.
- **Dependencies.** Standard library only. Do not add new external package
  dependencies; the zero-dependency story is a feature. JSON is vendored in
  `src/JSON.jl`.
- **Naming.** `lowerCamelCase` for functions to match the other MongrelDB
  clients; modules and types are `UpperCamelCase`.
- **Transport.** Keep transport-specific behavior behind the `http_request`
  helper, and raise `MongrelDBError` with the right `kind` instead of leaking
  generic exceptions when mapping server or network errors.

### Commit messages

- Conventional Commit-style subjects: `fix(query): ...`, `test: ...`,
  `ci: ...`. Keep subjects concise and imperative.
- Subject line <= 72 characters, no trailing period.
- Body: wrap at 72 characters. Explain *why*, not *what* (the diff shows the
  what).
- Reference issues with `Fixes #123` / `Refs #123` on a final line when
  applicable.
- **Never** add AI/assistant attribution (no `Co-Authored-By`, no
  `Generated with`, no tool names).

## Issue reports

A useful bug report includes:

- The MongrelDB Julia client version (from `Project.toml`).
- Your Julia version (`julia --version`) and OS.
- The `mongreldb-server` version if the issue involves live requests.
- The exact code or commands that reproduce the issue.
- The expected result and the actual result.
- Any error output or stack trace.

Feature requests are welcome. Please describe the problem you are trying to
solve before proposing the solution.

## Security

If you find a vulnerability, **do not** open a public GitHub issue.
Report it privately through GitHub's private vulnerability reporting, the
repository's **Security** tab then **Report a vulnerability**. The full
policy is in [`SECURITY.md`](SECURITY.md).

## Licensing

The MongrelDB Julia client is dual-licensed under MIT OR Apache-2.0. By
contributing, you agree that your changes are made available under the
same license.

- Do **not** paste code from other database clients unless you have done
  a license review first.
- New third-party dependencies must be MIT or Apache-2.0 licensed (and for
  this repo, standard library only).

Thanks again, looking forward to your PR.
