# Product Specification

## Feature
- Feature ID: `m3-agent-chat`
- Title: Agent Chat — Conversational Interface for Feature Authoring

## Background
The roadmap places M3 ("The Thread") as the milestone where humans and agents collaborate
in a shared conversational surface built on top of the deployed Hermes agent (M2). This
feature is the first slice of M3: a chat panel inside the digital-factory-ui that lets a
user talk to an AI agent to create and iterate on feature artifacts — product spec,
technical design, and task breakdown.

Today, feature artifacts are hand-authored in Markdown outside the platform and pasted in.
There is no in-product authoring surface, no agent assistance during drafting, and no
conversational feedback loop between the user and the system.

## Problem
Authoring a product spec, technical design, or task breakdown from scratch is the highest-
friction step in the feature lifecycle. Users must:
1. Know the YAML/Markdown structure expected by the workflow.
2. Write the document outside the platform and manually paste it in.
3. Iterate offline until it is good enough to submit for approval.

There is no AI assistance, no context from the existing workspace, and no way to ask the
system questions ("what repos are available?", "does this conflict with any existing
feature?") while authoring.

## Goals
- **G1** — Provide a chat panel in the digital-factory-ui where a logged-in user can
  converse with an agent to draft a feature's product spec, technical design, and task
  breakdown.
- **G2** — The agent streams responses in real time; users see partial output as it arrives.
- **G3** — The agent can read workspace context (existing features, repos, skills) to give
  grounded, accurate answers.
- **G4** — Drafts produced in chat are written directly into the feature's artifact files
  (`product-spec.md`, `technical-design.md`, tasks YAML) via the existing workflow skills —
  not through a parallel write path.
- **G5** — The existing lifecycle gates are not bypassed: the agent drafts; the human
  approves via the existing `approve-feature` flow.
- **G6** — The chat panel is reusable — the same component can later host agent
  participation at the task level and eventually @mentions (M3 follow-ons).

## Non-goals
- **NG1** — This feature does not implement @mentions, tagging teammates, or group chat.
  Single-user, single-agent conversation only.
- **NG2** — This feature does not implement the Hermes agent or any new agent backend.
  The frontend connects to the existing workflow-backend using the Claude API directly
  (or a thin backend endpoint that proxies it). Hermes deployment is M2.
- **NG3** — This feature does not add persistent chat history stored server-side. Chat
  context lives in the browser session; a page refresh starts a fresh conversation.
  (Persistent history is a follow-on once an auth and storage backend exists.)
- **NG4** — This feature does not implement the real-time backbone (SSE/WebSocket for
  presence, live board updates, notifications). Streaming is scoped to the chat response
  stream only.
- **NG5** — This feature does not add new approval UI. Approval continues via the existing
  `approve-feature` workflow.
- **NG6** — This feature does not gate on M2 (Hermes deployment). The chat agent is a
  Claude API call wired through the backend; it does not require a resident Hermes VM.

## User Flow

### Opening the chat panel
The chat panel is always visible as a fixed right-side panel in the digital-factory-ui
layout. It requires no action to open — it is present whenever the user is viewing a
feature. The panel sits alongside the existing Product Spec / Technical Design / Tasks /
Logs content area, not as a tab within it.

### Authoring a product spec via chat
1. User opens the Chat tab on a new feature whose product spec is still a blank template.
2. User types: *"Help me write the product spec for a feature that adds dark mode to the
   dashboard."*
3. Agent responds with clarifying questions or a draft, streamed token by token.
4. User iterates conversationally until the draft is ready.
5. User types: *"Save this as the product spec."*
6. Agent calls the `write_product_spec` tool, which invokes the workflow skill and writes
   `product-spec.md` to the feature directory in the management repo.
7. The Product Spec tab now shows the saved content. The user navigates there and clicks
   **Approve** via the existing flow.

### Querying workspace context
1. User types: *"What repos are available in this workspace?"*
2. Agent calls `get_workspace_context` tool, reads `workspace.yaml`, and responds with the
   repo list.

### Slash-command skill picker
1. User types `/` in the prompt input.
2. A popover appears above the input listing all available skills (e.g. `/write-product-spec`,
   `/write-technical-design`, `/get-feature-state`, `/get-workspace-context`).
3. Continuing to type filters the list in real time (e.g. `/write` narrows to the two write
   skills).
4. User selects a skill with arrow keys + Enter, or by clicking.
5. The skill name is inserted into the input and the agent invokes it when the message is
   submitted — same as if the user had typed the intent in prose, but more precise and
   discoverable.
6. Skills that take arguments (e.g. `/write-product-spec <draft>`) show a short usage hint
   in the popover row.

## Scope

### In scope for this feature
- Chat panel UI component in digital-factory-ui — a fixed right-side panel always visible
  when a feature is open, alongside (not inside) the existing FeatureTabView content area.
- Auto-resizing prompt input with streaming output rendering (reuse or port voyager's
  `PromptInput`, `Conversation`, `MessageThread`, `MarkdownContent` components).
- **Slash-command skill picker**: typing `/` in the prompt input opens a filtered popover
  listing available skills; arrow-key navigation + Enter or click to select; selected skill
  name inserted into the input. UX modelled on Claude Code's `/`-command picker.
- A backend API endpoint (workflow-backend) that:
  - Accepts a conversation history + system context.
  - Calls the Claude API with tool definitions.
  - Streams the response back to the UI via SSE.
- Tool definitions available to the agent:
  - `get_workspace_context` — reads workspace.yaml (repos, roles, model_policy).
  - `get_feature_state` — reads the feature's status.yaml, product-spec.md,
    technical-design.md (whichever exist).
  - `write_product_spec` — writes product-spec.md to the management repo via the
    existing `init-feature` / spec skill path.
  - `write_technical_design` — writes technical-design.md.
- System prompt that:
  - Scopes the agent to the current workspace and feature.
  - Instructs the agent to draft through the workflow skills, not bypass gates.
  - Provides the feature lifecycle context (stages, statuses).

### Out of scope (tracked separately)
- Task breakdown authoring via chat (follow-on, same chat panel).
- @mentions and multi-actor threads (M3 follow-on).
- Persistent chat history (requires auth + storage backend).
- Hermes resident agent deployment (M2).

## Success Criteria
- A user can open the Chat tab on any feature and get a streamed response within 2 seconds
  of submitting a message.
- A user can ask the agent to draft a product spec and have the result appear in the
  Product Spec tab after saying "save it", with no manual copy-paste.
- The existing approve/reject flow continues to work unchanged after a chat-authored draft
  is saved.
- The chat panel does not introduce a write path that bypasses the workflow skill layer.
- Typing `/` in the prompt shows a skill popover; typing `/write` filters it to write-skills
  only; selecting one inserts the command and submitting invokes it correctly.

## Reference
- Roadmap: `docs/roadmap-milestone.md` — M3 "The Thread", especially §"Spec-by-conversation"
  and §"The critical guardrail".
- Voyager agent chat UI components:
  `/Users/pye/code/voyager/voyager-interface/src/components/intelligence/agent/` —
  `Conversation`, `MessageThread`, `PromptInput`, tool call renderer, streaming patterns.
- Current feature view: `digital-factory-ui/src/features/board/components/FeatureTabView/`.
