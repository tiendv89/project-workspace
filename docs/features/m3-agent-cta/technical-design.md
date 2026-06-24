# Technical Design

## Feature
- Feature ID: `m3-agent-cta`
- Title: Agent CTA Suggestions — Context-Aware Action Cards After Agent Replies

## 1. Current State

### What exists today

The M3 agent-chat stack (through v4 + stop-agent-chat) is:

**Transport**: SSE-only (`GET /api/v1/threads/{id}/stream`). A persistent long-lived subscription pushes events to every thread member. Messages are sent via `POST /api/v1/threads/{id}/messages` (returns `202` immediately). The BFF (`workflow-bff`) proxies the stream from the hermes-agent (`workflow-backend`) under `/bff/hermes-agent`.

**Hermes agent turn events** published on the in-process bus (`src/realtime/bus.py`):
- `message.created` — full message object (human or assistant)
- Token deltas + `hermes.tool.progress` frames — streamed mid-turn
- `agent.working` / `agent.stopped` — ephemeral UI state
- `hermes.artifact.saved` — tool output artefacts
- `turn.stopped` — terminal event when the user cancels (m3-stop-agent-chat)
- `[DONE]` — terminal sentinel marking normal turn end

**Message storage** (hermes Postgres `messages` table):
```
id, session_id, role, content, tool_calls JSONB, finish_reason, author_id, created_at
```

**Frontend** (`digital-factory-ui`) handles these events via a chat store slice. The message composer is a blank text input; there are no guided next-step affordances.

### Current constraints

- Each agent turn produces plain markdown content only. There is no structured sidecar data attached to a turn.
- The `messages` table has no column for structured suggestion data.
- There is no endpoint exposing which workspace capabilities (GitNexus, RAG) are configured.
- The empty-state (no-message) thread view has no affordance; it shows only the composer.

### Current limitations

- Users must know slash commands and lifecycle stage rules to move forward after an agent reply.
- New users have no discovery path; experienced users repeat the same mental mapping on every turn.

---

## 2. Problem Framing

### What needs to change

1. The Hermes agent must optionally produce a structured list of `CtaSuggestion` objects alongside its main response content.
2. The hermes executor must persist those suggestions and publish them on the SSE bus as a new `turn.cta_suggestions` event.
3. The BFF must surface which workspace capabilities are active (GitNexus, RAG) so the frontend can gate capability-starter cards.
4. The frontend must render CTA card rows after agent responses, handle click-to-submit, degrade gracefully on past turns, and show starter cards on empty-state open.

### What must remain stable

- The existing SSE stream contract (`[DONE]`, `turn.stopped`, `message.created`) is unchanged.
- The `messages` table schema change is additive (new nullable/defaulted column) — no migration hazard for existing rows.
- The agent still produces a normal prose reply; CTAs are an optional sidecar, never replacing content.
- All existing approval gating, lifecycle actions, and member permissions are untouched.

### Fixed assumptions

- The Hermes agent already uses the Anthropic tool-use API. CTA generation will use the same tool-call mechanism — no new LLM invocation is needed.
- The BFF SSE proxy is already generic (it forwards any typed event emitted on the bus); no structural BFF change is needed for CTA event passthrough.

---

## 3. Options Considered

### Option A — Inline structured JSON block in agent response content

The agent embeds a fenced JSON block (e.g. ` ```cta_suggestions\n[...]\n``` `) at the end of its markdown. The backend strips and parses it before persisting `content`.

**Pros**: No schema change to hermes tool registry.
**Cons**: Model format adherence is unreliable; regex scraping is fragile; the CTA block is visible in the raw content stream mid-turn before it can be stripped. Fails AC8 (cards must not appear mid-stream).
**Verdict**: Rejected.

### Option B — Separate model call after main turn

After the hermes agent finishes its normal reply, a second lightweight model call generates CTAs given the full conversation as context.

**Pros**: Complete isolation from the main turn; no changes to hermes tool schema.
**Cons**: 200–400 ms additional latency per turn (second API round-trip); doubles token cost for every turn even when CTAs produce nothing useful; complicates turn lifecycle (two sequential model calls per user message).
**Verdict**: Rejected.

### Option C — `suggest_next_actions` tool call (chosen)

A new `suggest_next_actions(suggestions: CtaSuggestion[])` tool is registered in the hermes tool registry. The agent may call it as the final action of a turn when it judges a next step is worth surfacing. The hermes executor handles this tool call locally (no external API hit):
- Validates the `suggestions` payload against the schema.
- Persists to `messages.cta_suggestions`.
- Publishes `turn.cta_suggestions` on the SSE bus.
- Returns `{"status": "ok"}` to the agent so the turn ends cleanly.

**Pros**: Structured output enforced at the tool-call layer (schema validation, retries); zero additional model cost; fits naturally into the existing tool-registry pattern; the tool call fires before `[DONE]` so the frontend can reliably render cards only after turn end (AC8).
**Cons**: Agent must be prompted to understand when and how to call the tool; if the agent over-calls it the result is noisy (mitigated by prompt examples).
**Verdict**: Selected.

---

## 4. Chosen Design

### 4.1 Hermes agent — `hermes-agent`

#### New tool: `suggest_next_actions`

Registered in the hermes tool registry alongside existing tools (e.g. `save_artifact`).

```python
# tools/suggest_next_actions.py
TOOL_SCHEMA = {
    "name": "suggest_next_actions",
    "description": (
        "Suggest 1–3 context-aware next actions the user could take. "
        "Call this at the end of a turn when a natural follow-up exists. "
        "Omit the call when no clear next step applies."
    ),
    "input_schema": {
        "type": "object",
        "properties": {
            "suggestions": {
                "type": "array",
                "items": {
                    "type": "object",
                    "required": ["id", "title", "category", "description", "action_text", "button_label"],
                    "properties": {
                        "id":           {"type": "string"},
                        "title":        {"type": "string", "maxLength": 40},
                        "category":     {"type": "string", "enum": [
                            "Lifecycle", "Clarify", "Review", "Edit", "Action", "GitNexus", "RAG"
                        ]},
                        "description":  {"type": "string", "maxLength": 120},
                        "action_text":  {"type": "string"},
                        "button_label": {"type": "string", "maxLength": 20},
                        "icon":         {"type": "string"}
                    }
                },
                "maxItems": 3
            }
        },
        "required": ["suggestions"]
    }
}
```

The executor handles this tool call **locally** (no external API call):

```python
# In hermes executor tool dispatch
if tool_name == "suggest_next_actions":
    suggestions = tool_input["suggestions"]
    # Persist to message
    await db.execute(
        "UPDATE messages SET cta_suggestions=$1 WHERE id=$2",
        json.dumps(suggestions), message_id
    )
    # Publish SSE event
    await bus.publish(session_id, {
        "type": "turn.cta_suggestions",
        "message_id": message_id,
        "suggestions": suggestions
    })
    return {"status": "ok"}
```

#### System prompt extension

New section appended to the hermes system prompt:

```
## Suggesting next actions

After delivering your main response, you MAY call `suggest_next_actions` with 1–3 CTA objects when
a natural follow-up exists. Guidelines:
- Prefer lifecycle actions (approve, advance) when the conversation just completed a document draft.
- Prefer clarifying follow-ups when your answer introduced a concept the user might want to explore.
- OMIT the call when you answered a simple factual question or when no clear next step exists.
- Never suggest more than 3 options.
- `action_text` must be the literal text that will be submitted as the user's next message (e.g. "/approve-product-spec").
- `button_label` is the human-facing button text (3–4 words max).
```

#### Database migration

```sql
ALTER TABLE messages
  ADD COLUMN cta_suggestions JSONB NOT NULL DEFAULT '[]'::jsonb;
```

Additive — existing rows get `[]` by default; no backfill required.

### 4.2 BFF — `workflow-bff`

#### SSE passthrough

The `turn.cta_suggestions` event is forwarded automatically — the BFF's SSE proxy already passes all typed events from the bus without an allow-list. **No structural BFF change required.**

#### New endpoint: `GET /api/v1/workspace/capabilities`

Returns which optional agent capabilities are configured for this workspace deployment.

```json
{
  "gitnexus": true,
  "rag": false
}
```

The BFF resolves this from environment variables already present in its runtime:
- `gitnexus`: `GITNEXUS_MCP_URL` is set and non-empty → `true`
- `rag`: `MCP_RAG_URL` is set and non-empty → `true`

No auth required (workspace-scoped, not per-user secret). Response is safe to cache for the session lifetime.

### 4.3 Frontend — `digital-factory-ui`

#### New types

```typescript
interface CtaSuggestion {
  id: string
  title: string
  category: 'Lifecycle' | 'Clarify' | 'Review' | 'Edit' | 'Action' | 'GitNexus' | 'RAG'
  description: string
  action_text: string
  button_label: string
  icon?: string
}

interface WorkspaceCapabilities {
  gitnexus: boolean
  rag: boolean
}
```

#### Chat store extension

The message store slice (zustand or Redux) gains a `cta_suggestions` field per message (populated from both the SSE `turn.cta_suggestions` event and history re-hydration):

```typescript
// In message store slice
case 'turn.cta_suggestions':
  dispatch(setMessageCtas({ messageId: event.message_id, ctas: event.suggestions }))
  break
```

On history load, `message.cta_suggestions` from the API response is mapped into the store — past turns render inert cards without a separate fetch.

#### New components

**`CTACard`** — renders a single suggestion card:
- `active` prop: `true` for the current turn, `false` for past turns (inert variant: disabled button, `opacity-50`)
- Click calls `onAction(suggestion.action_text)` only when `active`

**`CTASuggestionRow`** — renders up to 3 `CTACard`s:
- Fades in via CSS transition after `turn.cta_suggestions` is received (AC8)
- Horizontal flex row, wraps vertically below 768 px
- Rendered immediately below the assistant message bubble, before the next message

**`EmptyStateCTARow`** — shown in the thread empty-state (zero messages):
- Accepts `featureStatus` (from existing feature context) and `capabilities` (from `GET /api/v1/workspace/capabilities`)
- Maps feature stage → 1–2 lifecycle starter cards using the static table from the product spec
- Appends capability starters only for `capabilities.gitnexus === true` / `capabilities.rag === true`
- Dismissed on first `message.created` event or on card click
- Not persisted in message history (ephemeral UI state only)

#### Click handler

```typescript
function handleCtaClick(actionText: string) {
  setInputDraft('')          // clear any draft
  submitMessage(actionText)  // same path as pressing Enter in the composer
  setCtaActive(false)        // dismiss/gray the current turn's CTA row
}
```

---

## 5. Dependency Analysis

| Dependency | Type | Status | Notes |
|---|---|---|---|
| Hermes tool registry (`suggest_next_actions`) | Internal | Unbuilt | Delivered by T4 (T1 wrong repo) |
| `messages.cta_suggestions` DB column | Internal | Unbuilt | Delivered by T4 (T1 wrong repo) |
| `turn.cta_suggestions` SSE event type | Internal | Unbuilt | Defined by T4 (T1 wrong repo); BFF passthrough is free |
| `GET /api/v1/workspace/capabilities` | Internal | Unbuilt | Delivered by T2 |
| v4 in-process SSE bus (`bus.publish`) | Internal | Done | Landed in m3-agent-chat-v4 |
| v4 `messages` table + `session_id` FK | Internal | Done | Landed in m3-agent-chat-v4 |
| Hermes system-prompt extension | Internal | Unbuilt | Part of T1 |
| Anthropic Claude model — tool use API | External | Done | Already in production |

No external vendor integrations are new. No blocking external decisions exist.

---

## 6. Parallelization / Blocking Analysis

```
T4: Hermes agent — suggest_next_actions tool + DB migration   [hermes-agent]
  └── Can begin now — no blockers (fixes T1 which was incorrectly in workflow-backend)
  │
T2: BFF — workspace capabilities endpoint                     [workflow-bff]
  └── Done
  │
  T3: Frontend — CTA card components + empty-state starters   [digital-factory-ui]
      └── Done (was BLOCKED on T1/T2; T2 done, T4 provides correct T1 replacement)
```

T3 is the sole downstream task. It covers both post-reply CTA cards and empty-state starters in one frontend task; the two components are independent enough to write in parallel within the same task but live in the same repo and are small enough to not warrant splitting.

---

## 7. Repository Impact

| Repo | Tasks | Changes |
|---|---|---|
| `hermes-agent` | T4 | New `suggest_next_actions` tool + handler; `messages` Alembic migration; system prompt extension (T1 was incorrectly targeted at `workflow-backend` — T4 corrects this) |
| `workflow-bff` | T2 | New `GET /api/v1/workspace/capabilities` route; SSE passthrough is zero-change |
| `digital-factory-ui` | T3 | New `CTACard`, `CTASuggestionRow`, `EmptyStateCTARow` components; chat store extension; `WorkspaceCapabilities` API call |

---

## 8. Validation and Release Impact

### Testing expectations

**T4 (`hermes-agent`)** — corrects T1 which targeted wrong repo:
- Unit test: `suggest_next_actions` handler persists correct JSON and publishes `turn.cta_suggestions` event.
- Unit test: tool schema validation rejects payloads with `> 3` suggestions or invalid `category` values.
- Integration test: full agent turn with CTA tool call → verify `messages.cta_suggestions` populated and SSE event received.

**T2 (`workflow-bff`)**:
- Unit test: `GET /api/v1/workspace/capabilities` returns correct booleans based on env var presence.
- Integration test: endpoint accessible under existing auth model.

**T3 (`digital-factory-ui`)**:
- Component tests: `CTACard` active vs inert states; `CTASuggestionRow` fade-in timing; `EmptyStateCTARow` stage-to-starters mapping; capability gating hides GitNexus/RAG when `false`.
- E2E test: click CTA card → message submitted → CTA row grayed out.
- Visual regression: past-turn inert cards; mobile stacking at 767 px.

### Migration impact

`ALTER TABLE messages ADD COLUMN cta_suggestions JSONB NOT NULL DEFAULT '[]'::jsonb` — additive, no lock on existing rows, zero downtime.

### Rollout concerns

- T1 and T2 can be deployed independently. T3 gracefully handles absent `cta_suggestions` (empty array = no card row rendered).
- If T3 deploys before T1 is live: `cta_suggestions` is always `[]` → no cards rendered → no visible change. Safe.
- Feature is additive to all existing chat surfaces with no breaking changes.

### Backward compatibility

- Clients that do not handle `turn.cta_suggestions` events ignore the unknown type; the turn still ends with `[DONE]`.
- `messages.cta_suggestions` defaulting to `[]` means existing API consumers that do not read this field are unaffected.

---

## Figma

No Figma link was provided in the product spec. UI implementation should follow the card anatomy described in the product spec (§ User Experience) and match the existing design system tokens already in use in `digital-factory-ui` (dark background, blue primary action button, rounded cards, small category tag chip).
