# Task Breakdown: Agent RAG v2 — Source Code + Docs Indexing

Feature status: `in_tdd` — technical design approved. Machine state lives in `tasks/T<n>.yaml`.

## Repo split

All tasks target the `rag-service` repo. No workflow repo changes are required.

## Task index

| ID | Wave | Title | Depends on |
|---|---|---|---|
| T1 | 1 | Schema + model upgrade | — |
| T2 | 2 | Docs folder indexing | T1 |
| T3 | 2 | Source code indexing — AST chunking | T1 |

---

## T1 — Schema + model upgrade

### Description

Foundation task for all of v2. Delivers three tightly coupled changes that must land together before T2 or T3 can write any points:

1. **`VALID_SOURCE_TYPES`** — add `"doc"` and `"source_code"` to the frozenset in `services/shared/schema.py`. The indexer raises `ValueError` on upsert for any unrecognised source type, so this must be in place before T2/T3 run.
2. **`VECTOR_DIM`** — update `services/shared/qdrant_init.py` from `384` to `768` to match the upgraded embedding model.
3. **Embedding model swap** — replace `sentence-transformers/all-MiniLM-L6-v2` with `BAAI/bge-base-en-v1.5` in both `services/indexer/embedder.py` and `services/rag_server/embedder.py`. Both services must use the same model or query vectors and index vectors will be in different spaces.
4. **Qdrant collection migration** — the dimension change requires dropping and recreating the collection. Document the one-time operator procedure and add a startup check: if the existing collection has `vector_size != 768`, log a clear error and exit rather than silently writing mismatched vectors.

### Required skills
- python-best-practices

### Subtasks
- [ ] Add `"doc"` and `"source_code"` to `VALID_SOURCE_TYPES` in `services/shared/schema.py`
- [ ] Update `VECTOR_DIM = 768` in `services/shared/qdrant_init.py`
- [ ] Swap model name to `BAAI/bge-base-en-v1.5` in `services/indexer/embedder.py`
- [ ] Swap model name to `BAAI/bge-base-en-v1.5` in `services/rag_server/embedder.py`
- [ ] Add startup dimension check in `qdrant_init.py`: if collection exists with wrong vector size, raise a clear error (do not silently write mismatched vectors)
- [ ] Update `tests/shared/test_schema.py` — verify `"doc"` and `"source_code"` are valid; verify old types still valid
- [ ] Update `tests/shared/test_qdrant_init.py` — verify collection created with `vector_size=768`
- [ ] Add migration procedure to `README.md` operator section: stop indexer → drop collection → redeploy → re-index

---

## T2 — Docs folder indexing

### Description

Extend the indexer to recognise and chunk Markdown files under `docs/` across all registered repos, storing them as `source_type: doc`.

**Inclusion pattern:** `docs/**/*.md`, excluding paths already covered by existing source types:
- `docs/features/*/product-spec.md` → already `product_spec`
- `docs/features/*/technical-design.md` → already `technical_design`
- `docs/features/*/tasks.md` → machine-generated planning, redundant

**Chunking:** reuse the existing `_sliding_window_chunks(512, 50)` strategy — the same as `product_spec` and `technical_design`. Docs are prose; sliding window is appropriate.

**`feature_id` extraction:** if the path matches `docs/features/<id>/...`, extract `<id>` as `feature_id` in the payload (consistent with how product specs and technical designs capture feature scope). Otherwise `feature_id` is `None`.

### Required skills
- python-best-practices

### Subtasks
- [ ] Add `doc` inclusion pattern to `_PATTERNS` in `services/indexer/source_mapper.py` — match `docs/**/*.md`, exclude the three paths above, extract `feature_id` from `docs/features/<id>/` paths
- [ ] Add `"doc"` case to `chunk_document()` in `services/indexer/chunker.py` — delegate to `_sliding_window_chunks(512, 50)`
- [ ] Add exclusion tests in `test_source_mapper.py`: `docs/features/x/product-spec.md` → not `doc`; `docs/features/x/tasks.md` → not indexed
- [ ] Add inclusion tests: `docs/architecture/overview.md` → `("doc", None)`; `docs/features/my-feat/guide.md` → `("doc", "my-feat")`
- [ ] Add chunker test: `chunk_document("doc", <markdown>)` returns non-empty list of strings
- [ ] Integration test: index a `docs/` markdown file → `rag_query("architecture overview", workspace_id=...)` returns it in results

---

## T3 — Source code indexing — AST chunking

### Description

Extend the indexer to recognise source code files and chunk them using tree-sitter AST parsing, falling back to sliding window for unsupported languages or malformed files.

**Inclusion patterns** (after exclusions are applied):
- `.py`, `.ts`, `.tsx`, `.js`, `.go`
- Exclusions: `node_modules/`, `vendor/`, `dist/`, `build/`, `.next/`, `out/`, `__pycache__/`, `migrations/`
- Test files (`.test.ts`, `.spec.ts`, `test_*.py`) are **included** — they document real usage patterns

**AST chunking strategy for `source_code`:**
1. Infer language from file extension (`.py` → Python, `.ts`/`.tsx` → TypeScript, `.go` → Go, `.js` → JavaScript/TypeScript grammar)
2. Parse with tree-sitter; walk top-level nodes: `function_definition`, `class_definition`, `method_definition`, `function_declaration`, `arrow_function` (when assigned to a variable)
3. For each node emit a chunk prefixed with `# file: <source_path>` and `# class: <ClassName>` if inside a class — so the embedding captures file location and class membership, not just the isolated body
4. Very large nodes (> 6000 chars ≈ 1500 tokens): apply `_sliding_window_chunks` within the node body, each sub-chunk prefixed with the function signature line
5. Fallback: if tree-sitter fails (parse error, unsupported language, zero nodes extracted) → `_sliding_window_chunks(512, 50)` on the whole file

**New dependencies:**
```
tree-sitter>=0.23.0
tree-sitter-python>=0.23.0
tree-sitter-typescript>=0.23.0
tree-sitter-go>=0.23.0
```

### Required skills
- python-best-practices

### Subtasks
- [ ] Add `tree-sitter>=0.23.0`, `tree-sitter-python`, `tree-sitter-typescript`, `tree-sitter-go` to `requirements.txt`
- [ ] Add source code inclusion patterns to `_PATTERNS` in `source_mapper.py` — `.py`, `.ts`, `.tsx`, `.js`, `.go` → `source_type: source_code`
- [ ] Extend `_EXCLUDE_PATTERNS` with `__pycache__/`, `dist/`, `build/`, `.next/`, `out/`, `migrations/`
- [ ] Implement `_ast_chunk_source(content, language, source_path)` in `chunker.py` using tree-sitter
- [ ] Add fallback to `_sliding_window_chunks` when tree-sitter yields zero nodes or raises
- [ ] Add `"source_code"` case to `chunk_document()` — delegates to `_ast_chunk_source`, fallback to sliding window
- [ ] Unit test: Python file with two functions → two chunks, each starting with function signature
- [ ] Unit test: file with a class containing two methods → chunks include `# class: ClassName` prefix
- [ ] Unit test: malformed/unparseable file → falls back to sliding window, no exception raised
- [ ] Unit test: `node_modules/foo.ts` → `classify_path` returns `None`
- [ ] Unit test: `services/auth.test.ts` → `classify_path` returns `("source_code", None)` (test files included)
- [ ] Integration test: index a `.py` file → `rag_query("function that handles authentication")` returns the auth function chunk
