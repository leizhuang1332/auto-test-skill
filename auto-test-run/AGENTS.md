<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-22 | Updated: 2026-04-22 -->

# auto-test-run

## Purpose
Phase 3 of the auto-test pipeline. Reads Phase 1/2 test-spec JSON (must have `status: data_inserted`), runs `mvn clean package`, starts the Spring Boot app, executes curl-based HTTP tests against Controller endpoints, auto-fixes bugs with ≤5-line diffs (with user confirmation), and outputs markdown test reports.

## Key Files

| File | Description |
|------|-------------|
| `SKILL.md` | Skill definition: triggers, prerequisites, curl validation rules, auto-fix scope, report format |
| `run-test.sh` | Main orchestration: mvn package → find jar → read application.yml → start app → curl test each endpoint → update test-spec → generate report |
| `auto-fix.sh` | AI analyzes test failure, generates fix for ≤5-line Service-layer bugs; user confirms before applying |
| `state-schema.json` | JSON schema with testResults and fixes extensions on top of Phase 1/2 test-spec |

## Subdirectories

_None_

## For AI Agents

### Working In This Directory
- This phase **reads** test-spec JSON from Phase 2 (test cases must have `status: "data_inserted"`)
- **Port conflict handling:** If the configured port is occupied, kill the existing process (up to 3 retries)
- **Curl validation logic:** HTTP 200 + `code=200`/`success=true` → PASS; otherwise → FAIL
- **Auto-fix scope:** Only Service-layer fixes with ≤5-line diffs; Controller validation, transaction, DB connection, and Feign timeout issues are excluded
- After each test, the test-spec JSON is updated: `实际结果`, `原因`, `status: "completed"`
- Two report files: `{timestamp}.md` (test results) and `{timestamp}-fixes.md` (fix log)

### Testing Requirements
- Requires Phase 1+2 completed (test-spec JSON with `status: data_inserted`)
- Test by running `/auto-test-run` after Phase 2
- Verify test reports are generated in `{PROJECT_ROOT}/.auto-test/test-reports/`
- Check that test-spec JSON has `status: "completed"` and `phase: "phase3_completed"`

### Common Patterns
- **Startup sequence:** mvn package → find jar (exclude `*-original.jar`) → read `application.yml` for port/context-path → start app → wait for port listen
- **Auto-fix flow:** Analyze error → generate diff → user confirms → apply fix → backup original to `.auto-test/backups/` → retry test
- **Report generation:** Markdown tables for pass/fail summary, detailed failure section with error messages

## Dependencies

### Internal
- `../auto-test-gen/` — Phase 1 produces the test-spec JSON with test case definitions
- `../auto-test-data/` — Phase 2 inserts data and sets `status: data_inserted`
- `../auto-test/` — Pipeline orchestrator invokes this phase

### External
- Maven (`mvn`) for building the Spring Boot application
- Java 8+ for running the application JAR
- `curl` for HTTP testing
- `jq` for JSON response parsing
- `lsof` for port conflict detection

<!-- MANUAL: Custom project notes can be added below -->
