# workspace — Hermes operating rules
# Workspace operating rules

<!-- BEGIN SHARED WORKFLOW RULES -->

## Repo identity

This workspace contains one or more implementation repositories. Each task
targets a single repo declared in `workspace.yaml`. Before writing any code,
confirm which repo and which branch your task targets -- read your task spec
(`$TASK_REPO_PATH`) to be certain.

## Code quality

### Test-before-declaring-done rule

Do not declare work complete until the full test suite passes.

- Detect the test runner from the project: check `package.json` scripts, `Makefile`,
  `go.mod`, `pytest.ini`, or equivalent config. Do not assume a specific runner.
- Run the full test suite, not a subset.
- If tests fail and you can fix them, do so and re-run. Stop after three failed
  attempts and report the failure state clearly.
- **Write tests for new logic.** Every new function, method, or conditional branch
  gets at minimum a happy-path unit test plus one edge case (null/empty input,
  boundary value, or failure path). This is non-negotiable.

### Formatter rule

Run the project's formatter before each commit:

- `package.json` with a `format` or `lint:fix` script -> run it
- Go -> `gofmt -w .`
- Python -> `ruff format .` or `black .` (whichever the project uses)
- Anything else -> skip silently

A PR with unformatted code will be rejected.

### Lint rule

If the project has a lint step (`eslint`, `golangci-lint`, `flake8`, `ruff check`,
etc.), run it after formatting and fix any errors before committing. Warnings are
acceptable; errors are not.

**Go projects: `golangci-lint run` is mandatory before every commit.** Zero errors
required — this matches what CI enforces. Install:
`go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest`

### Pre-push checks rule

Before pushing any branch, run all tests and lint checks. Do not push if any tests fail or lint errors exist. Fix all failures and re-run until clean.

## Commit message conventions

Use the **Conventional Commits** format:

```
<type>(<featureId>/<taskId>): <short description>
```

Types: `feat`, `fix`, `chore`, `refactor`, `docs`, `test`, `style`, `perf`.

Rules:
- Description is lowercase, imperative mood, no trailing period.
- Keep the full title under 72 characters.
- One logical unit per commit -- do not batch unrelated changes.

Examples:
- `feat(hermes-skill-adaptation/T3): add SOUL.md agent identity file`
- `fix(auth-flow/T5): handle missing refresh token in session init`
- `chore(hermes-skill-adaptation/T3): add HERMES.shared.md workspace rules`

## Checkpoint discipline

**Commit incrementally.** Never batch many hours of work into a single commit.
After each substantial action -- file write, test run, multi-file edit -- commit
with a `wip(<featureId>/<taskId>): <what you just did>` message.

Incremental commits:
- Protect against unexpected termination (the next run sees your last checkpoint)
- Make PR review easier
- Allow the orchestrator to detect forward progress

Never commit `result.json` or `handover.md` files to the implementation repo.
These are executor artefacts, not project artefacts.

## MCP lookup priority

### RAG -- project knowledge retrieval

**Always query RAG before opening a file to look up code or context.**

Lookup order:
1. Call `mcp_rag_rag_query(query="<your question>")` first.
2. If results are relevant and high-confidence, use them -- do not open the file.
3. Fall back to a direct file read only when RAG returns no results or the
   results are clearly irrelevant.

Use RAG for: project architecture, API patterns, existing implementations,
configuration purpose, any concept specific to this codebase.

Skip RAG and read directly when:
- You know the exact file path and need a targeted line-range edit.
- The file is a lock file, generated output, or config file unlikely to be indexed.

### GitNexus -- structural code questions

**Always use GitNexus before grep or full-file reads for structural questions.**

Lookup order:
1. `mcp_gitnexus_query(query="<symbol or pattern>")` to locate a symbol across the repo.
2. `mcp_gitnexus_context(symbol="<symbol>")` to get callers, callees, type relationships.
3. `mcp_gitnexus_impact(symbol="<symbol>")` before any refactor or deletion.
4. `mcp_gitnexus_detect_changes(files=["..."])` to map a diff to affected symbols.
5. Fall back to grep or file reads only when GitNexus returns no results.

Use GitNexus for: finding where a function is defined, understanding what calls
a method, assessing the blast radius of a change, tracing execution flows.

### MCP invocation syntax reminder

Hermes MCP tool names use **single underscores**: `mcp_<server>_<tool>`.

Examples:
- `mcp_rag_rag_query` -- RAG knowledge lookup
- `mcp_gitnexus_query` -- GitNexus symbol search
- `mcp_gitnexus_context` -- GitNexus caller/callee graph
- `mcp_gitnexus_impact` -- GitNexus blast-radius analysis
- `mcp_gitnexus_detect_changes` -- GitNexus diff-to-symbol mapping

Do NOT use `mcp__` (double underscore) -- that is Claude's syntax.

## File and naming conventions

- Follow the conventions already present in the repo you are editing.
- Match the indentation style, import order, and export pattern of surrounding code.
- Do not introduce new dependencies unless the task explicitly requires them.
- Prefer editing existing files over creating new ones.
- Do not create `README.md` files or documentation unless explicitly requested.

## Security rules

- Do not introduce command injection, SQL injection, XSS, or other OWASP top-10
  vulnerabilities. If you notice you wrote insecure code, fix it immediately.
- Trust internal code and framework guarantees. Only validate at system boundaries
  (user input, external APIs).
- Do not commit secrets, tokens, or credentials to the repository.

## What the wrapper handles (do not duplicate)

The executor wrapper handles these steps after you exit -- you must NOT do them:

- `git push` to the remote
- Opening the pull request
- Writing `result.json` to `$RESULT_PATH`

Your job ends when all local commits are made and the test suite passes.

<!-- END SHARED WORKFLOW RULES -->
