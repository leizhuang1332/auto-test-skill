<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-22 | Updated: 2026-04-22 -->

# auto-test-data

## Purpose
Phase 2 of the auto-test pipeline. Reads Phase 1's test-spec JSON, identifies Entity classes from DTOs, generates INSERT SQL templates with `#{varName}` placeholders, gets user confirmation, then executes INSERTs via MCP (JDBC). Updates test-spec status from `pending` to `data_inserted`.

## Key Files

| File | Description |
|------|-------------|
| `SKILL.md` | Skill definition: triggers, input/output spec, entity identification rules, confirmation flow |
| `auto-test.sh` | Bash script for Phase 2 orchestration: identify entity → generate INSERT → execute |
| `state-schema.json` | JSON schema with Entity and INSERT extensions on top of Phase 1 test-spec |

## Subdirectories

_None_

## For AI Agents

### Working In This Directory
- This phase **reads** test-spec JSON from Phase 1 (must have `status: "pending"` test cases)
- Entity identification priority: annotation (`@Table`/`@Entity`) → naming inference (strip DTO suffix) → database reverse
- INSERT templates use `#{varName}` placeholder syntax — values are filled from DTO field definitions
- **User confirmation is required** before executing any INSERT statement
- After successful INSERT, the test-spec JSON is updated: `entityClass`, `insertTemplate`, `insertStatus`, `insertResult`, and `status` → `data_inserted`

### Testing Requirements
- Requires Phase 1 completed (test-spec JSON exists in target project's `.auto-test/` directory)
- Test by running `/auto-test-data <controller>` after Phase 1
- Verify test-spec JSON has `status: "data_inserted"` after successful execution

### Common Patterns
- **Entity resolution chain:** Try annotation scan first, fall back to naming convention, last resort database introspection
- **MCP execution:** INSERT statements are executed via JDBC MCP, not bash
- **Dependency ordering:** Insert parent tables before child tables to respect foreign keys

## Dependencies

### Internal
- `../auto-test-gen/` — Phase 1 output (test-spec JSON) is the required input
- `../auto-test-run/` — Phase 3 consumes this phase's output (`status: data_inserted`)

### External
- MySQL database connection (read from target project's `application.yml`)
- MCP JDBC tool for INSERT execution

<!-- MANUAL: Custom project notes can be added below -->
