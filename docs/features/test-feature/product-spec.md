# Product Specification

## Feature
- Feature ID: `test-feature`
- Title: AI Agent Onboarding Experience

## Problem

Voyager's AI agent — accessible via `useAgentChat` and `useAgentSSE` in `voyager-mobile` — is one of the platform's most differentiated features, but new users discover it by accident (if at all). After completing `SignInV2`, users land on the main dashboard with no guided introduction to the agent. The agent session creation flow (`agentStore.createSession`) and the trade approval gate (`useTradeApprovalGate`) are invisible to first-time users who have never interacted with the agent before.

Activation data shows that users who complete at least one agent-assisted trade in their first session have significantly higher 30-day retention, but the majority of new users never open the agent chat at all.

## Goals

- Add a first-time onboarding flow in `voyager-mobile` that triggers automatically after `SignInV2` completes for new accounts (no prior agent sessions in `agentStore.activeSessions`)
- Walk the user through three guided steps: (1) what the AI agent does, (2) connecting their first wallet via the existing `AuthProvider` flow, (3) making their first agent-assisted action (deposit or portfolio scan)
- On completion of the onboarding flow, create an initial agent session via `agentStore.createSession` and open the agent chat with a pre-populated welcome prompt
- Track onboarding funnel completion steps in `voyager-backend` analytics so product can measure drop-off at each step
- Allow users to skip onboarding and access it again later from the Settings screen

## Non-goals

- Onboarding for `voyager-interface` (web) — mobile only for v1
- Changes to the `SignInV2` authentication flow itself
- Modifying `useAgentSSE` or the underlying agent streaming protocol
- In-app tutorial overlays or coach marks beyond the three onboarding steps
- A/B testing of onboarding variants — single flow for v1
