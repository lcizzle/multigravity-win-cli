# Local Agent Directives (Universal Memory v2.1)

1. **Vault Access**: This workspace uses the `bitbonsai/mcpvault` MCP server.
2. **Global Startup Step**: On Turn 1, read `AI/Global/System/AGENTS.md` to load universal system directives.
3. **Project Context**: On Turn 1, read `AI/Projects/lch_multigravity-win-cli/State_lch_multigravity-win-cli.md` and check `AI/Projects/lch_multigravity-win-cli/Sessions/Active/` for uncommitted delta overlays.
4. **Memory Stewardship**: All working state consolidation, frontmatter validation, and MOC maintenance are managed via `Obsidian-Steward`. Domain agents append session logs to `Sessions/Active/`.
