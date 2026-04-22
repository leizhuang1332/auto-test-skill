<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-22 | Updated: 2026-04-22 -->

# auto-test

## Purpose
Pipeline orchestration skill (Phase 4) that chains the three auto-test phases together: `/auto-test-gen` → `/auto-test-data` → `/auto-test-run`. This is the main entry point users invoke with `/auto-test <input>`.

## Key Files

| File | Description |
|------|-------------|
| `SKILL.md` | Skill definition: triggers, input formats, pipeline flow, phase transition rules |
| `auto-test.sh` | Bash script that orchestrates the full pipeline — calls Phase 1/2/3 scripts sequentially |
| `state-schema.json` | JSON schema defining the pipeline state shape and phase transition fields |

## Subdirectories

_None_

## For AI Agents

### Working In This Directory
- This skill **delegates** to the three phase skills — it does not contain testing logic itself
- The `auto-test.sh` script coordinates: parse input → call gen scripts → call data scripts → call run scripts
- Phase transitions are tracked via the `phase` field in test-spec JSON: `phase1_completed` → `phase2_completed` → `phase3_completed`
- User confirmation happens at Phase 1 (test spec approval) and Phase 2 (INSERT approval)

### Testing Requirements
- Test by invoking `/auto-test SpmiCapacityBillController` against a real Spring Boot project
- Verify each phase transitions correctly by checking the test-spec JSON `phase` field

### Common Patterns
- **Pipeline pattern:** Sequential phase execution with state tracked in shared JSON
- **Error propagation:** If any phase fails, the pipeline stops and reports the error

## Dependencies

### Internal
- `../auto-test-gen/` — Phase 1: generates test spec JSON
- `../auto-test-data/` — Phase 2: generates and inserts test data
- `../auto-test-run/` — Phase 3: executes tests and generates reports

### External
- Spring Boot + Maven target project
- Java 8+, MySQL

<!-- MANUAL: Custom project notes can be added below -->
