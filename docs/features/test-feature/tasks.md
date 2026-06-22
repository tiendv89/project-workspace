# Tasks — test-feature

> Feature status: `in_tdd` | Stage: `tasks` | Machine state lives in `tasks/T<n>.yaml`

## Dependency Diagram

```
T1: Validate task lifecycle (management-repo)
  └── Can begin now — no blockers

T2: Complete handoff validation (management-repo)
  └── BLOCKED on T1 (T1 must reach `done` to trigger auto-ready on T2)
```

## Index

| ID | Wave | Title | Depends on |
|----|------|-------|------------|
| T1 | 1 | Validate task lifecycle | — |
| T2 | 2 | Complete handoff validation | T1 |

---

## T1 — Validate task lifecycle

### Description
Exercise the full task status progression (`ready → in_progress → in_review → done`) within the management repo. This task validates that the claim protocol, log entries, and status transitions all work correctly for the `test-feature` feature. No production code is changed — this is a workflow validation task.

### Required skills
- (none)

### Subtasks
- [ ] Claim the task (status: `in_progress`)
- [ ] Append a `started` log entry
- [ ] Append a `work_phase_complete` log entry
- [ ] Move task to `in_review`
- [ ] Human or reviewer marks task `done`

---

## T2 — Complete handoff validation

### Description
After T1 is done (auto-ready rule triggers), validate the downstream task lifecycle and produce a handoff summary. Confirms that `depends_on` resolution, the auto-ready transition, and the handoff stage all function correctly end-to-end for this test feature.

### Required skills
- (none)

### Subtasks
- [ ] Confirm T1 is `done` and T2 auto-transitioned to `ready`
- [ ] Claim the task (status: `in_progress`)
- [ ] Append a `started` log entry
- [ ] Write a brief handoff summary to `handoffs/test-feature.md`
- [ ] Move task to `in_review`
- [ ] Human or reviewer marks task `done`
