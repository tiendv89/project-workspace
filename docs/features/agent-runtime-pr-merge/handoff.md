# Handoff — agent-runtime-pr-merge

**Feature ID:** `agent-runtime-pr-merge`
**Completed:** 2026-04-27
**Authored by:** Automated close-out (pr-merge loop) + matthew@swellnetwork.io

---

## Summary

This feature closed the loop in the agent runtime when an implementation PR is merged by a human. Previously, the runtime's polling loop had no handler for the merged state — the task YAML stayed at `in_review` and the management-repo PR remained open indefinitely.

### What was delivered

**T1 — Extend PR poller + implement merge-completion handler** (tiendv89/agent-workflow#51, merged)
- Added `merged` field to `PrStatusResult` and the GraphQL query in `check-in-review-prs.ts`
- Created `src/pr-response/handle-merged-prs.ts`: detects merged implementation PRs, merges the management-repo PR via GitHub API, applies the auto-ready rule to unblocked downstream tasks, and marks the task `done`
- Wired the new handler into `main.ts` after the existing in-review pass
- Added 20 unit tests covering the full merge-completion path

**T2 — Documentation update** (tiendv89/agent-workflow#52, merged)
- Added section 12 to `OPERATOR-GUIDE.md` covering automated PR merge close-out
- Updated `agent.yaml` reference with `pr_poll_interval_seconds`
- Annotated `GITHUB_TOKEN` in `DOCKER.md`

---

## Verification

- Both implementation PRs reviewed and merged by human
- Both management-repo PRs (#55, #56) merged into main
- Auto-ready rule triggered correctly: T2 activated when T1 was marked done by the loop
- All 20 new unit tests pass

---

## Known limitations / follow-ons

None identified. The feature is complete as scoped.

---

## Approval required

A human must review this handoff and approve it to advance the feature to `done`.
