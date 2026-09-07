# Local Agent Directives (Universal Memory v2.2 - Antigravity CLI)

## 1. Environment & Scope
- Vault Tools: `bitbonsai/mcpvault`
- Project ID: `lch_multigravity-win-cli`
- Base Path: `AI/Projects/lch_multigravity-win-cli`

## 2. Startup Lifecycle (Turn 1 Execution)
1. Inspect Pending Deltas: Call `list_directory` on `AI/Projects/<Project_ID>/Sessions/Active/`.
2. Batch Context Load: Call `read_multiple_notes` passing:
   - `AI/Projects/<Project_ID>/State_<Project_ID>.md`
   - All pending session paths returned from Step 1.

## 3. Session Teardown & State Reconciliation (Mandatory Final Turn)
Before completing the run:
1. Write session log: Create `AI/Projects/lch_multigravity-win-cli/Sessions/Active/YYYY-MM-DD_<role>_<uuid>.md`.
2. Trigger Steward Reconciliation:
   - Call subagent `Obsidian-Steward` with argument: path to the created session file.
   - Wait for Steward to commit deltas to `State_lch_multigravity-win-cli.md` and archive the session file.