# Features

This folder stores real feature folders only.

Expected structure:
- docs/features/FEATURE-001/
  - product-spec.md
  - technical-design.md
  - tasks/
    - T1.yaml
    - T2.yaml
  - status.yaml
  - handoffs/
  - deployment-checklist.md   # later

Rules:
- one task = one YAML file
- subtasks live inside task files as notes/checklist/log entries
- subtasks do not have their own lifecycle status
