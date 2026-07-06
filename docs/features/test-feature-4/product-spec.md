# Product Specification

## Feature
- Feature ID: `test-feature-4`
- Title: `Unified Search`

## Problem
Users navigating the application must search separately within each section (projects, tasks, members, documents) to find what they need. There is no global search capability, which forces users to know exactly where something lives before they can find it. This slows down workflows, increases frustration, and makes onboarding harder for new team members who are unfamiliar with the app's structure.

## Goals
- Provide a single global search bar accessible from any page via keyboard shortcut and nav bar
- Return results across all major entity types: projects, tasks, documents, members, and comments
- Display results grouped by entity type with a relevance-ranked ordering within each group
- Support filtering results by entity type, date range, and assigned user
- Show a preview snippet for each result (e.g. task description excerpt, document paragraph)
- Deliver results within 300ms for queries on indexed data

## Non-goals
- Full-text search inside file attachments (filenames only for v1)
- Search within archived or deleted entities
- Saved/pinned searches or search history
- Natural language query parsing or semantic search (keyword-based only for v1)
- Cross-workspace search (scoped to the current workspace only)
