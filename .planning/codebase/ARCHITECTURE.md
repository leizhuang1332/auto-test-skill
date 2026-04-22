# Architecture

**Analysis Date:** 2026-04-22

## Pattern Overview

**Overall:** Sequential Pipeline with Shared JSON State

**Key Characteristics:**
- Three-phase sequential pipeline (gen -> data -> run) orchestrated by a Phase 4 coordinator
- Test-spec JSON file serves as the single source of truth and shared state between phases
- Bash scripts handle orchestration and file I/O; AI (Claude Code) handles generation and analysis
- User confirmation gates at each phase boundary prevent unwanted side effects
- Status field on each test case drives phase transitions and prevents re-processing

## Layers

**Orchestration Layer (Phase 4):**
- Purpose: Chain Phase 1, 2, and 3 into a single `/auto-test` invocation; manage phase transitions
- Location: `auto-test/`
- Contains: Pipeline coordinator script, phase transition logic
- Depends on: All three sub-skill directories (`auto-test-gen`, `auto-test-data`, `auto-test-run`)
- Used by: End user via `/auto-test <input>` command

**Generation Layer (Phase 1):**
- Purpose: Parse user input, clarify requirements, extract Controller/DTO/Feign metadata, generate JSON test spec via AI
- Location: `auto-test-gen/`
- Contains: Input parsing scripts, metadata extraction scripts, AI prompt construction, test-spec JSON writer
- Depends on: Git (for branch/commit diff), Python3 (for `extract-methods.sh`, `extract-dto.sh`), jq, project source files
- Used by: Orchestration layer, or directly via `/auto-test-gen`

**Data Preparation Layer (Phase 2):**
- Purpose: Map DTOs to Entity classes, generate INSERT SQL templates, execute INSERTs via MCP to MySQL
- Location: `auto-test-data/`
- Contains: Entity identification scripts, INSERT template generator, MCP execution integration
- Depends on: Phase 1 output (test-spec JSON), Java source files, MCP mysql tool, jq
- Used by: Orchestration layer, or directly via `/auto-test-data`

**Execution Layer (Phase 3):**
- Purpose: Maven build, application startup, curl endpoint testing, auto-fix small bugs, generate reports
- Location: `auto-test-run/`
- Contains: Maven build runner, app startup with port management, curl test executor, auto-fix analyzer, report generator
- Depends on: Phase 1+2 output (test-spec JSON with `status=data_inserted`), Maven, Java 8+, curl, jq
- Used by: Orchestration layer, or directly via `/auto-test-run`

## Data Flow

**Full Pipeline Flow:**

1. User invokes `/auto-test SpmiCapacityBillController`
2. `auto-test/auto-test.sh` creates `{PROJECT_ROOT}/.auto-test/` directory structure
3. Phase 1 runs sequentially: `parse-input.sh` -> `requirements-clarification.sh` -> `extract-methods.sh` -> `extract-dto.sh` + `extract-feign.sh` -> `gen-test-spec.sh`
4. AI generates test-spec JSON; user confirms; JSON written to `{PROJECT_ROOT}/.auto-test/test-spec-{controller}-{timestamp}.json` with `phase: phase1_completed`, all test cases `status: pending`
5. Phase 2 runs sequentially: `identify-entity.sh` -> `gen-insert.sh` -> `execute-insert.sh`
6. Each test case updated with `entityClass`, `insertTemplate`; after MCP INSERT, status updated to `data_inserted`
7. Phase 3 runs: `run-test.sh` verifies `status=data_inserted`, builds Maven, starts app, curls each endpoint
8. Each test case updated with `实际结果` (PASS/FAIL), `原因`, `status: completed`
9. Report markdown files generated; test-spec JSON updated with `phase: phase3_completed`

**State Management:**
- Single JSON file (`test-spec-{controller}-{timestamp}.json`) accumulates state across all three phases
- Each phase reads and writes to the same file using `jq` for atomic JSON updates
- Phase status tracked in top-level `phase` field: `phase1_in_progress` -> `phase1_completed` -> `phase2_in_progress` -> etc.
- Test case status tracked per-case in `testCases[].status`: `pending` -> `data_inserted` -> `completed`
- Schema extensions are cumulative: Phase 2 adds `entityClass`/`insertTemplate`/`insertStatus`/`insertResult` fields; Phase 3 adds `testResults`/`fixes` top-level objects

**Inter-Phase Communication Pattern:**
```
Phase 1 output:
  test-spec JSON with testCases[].status = "pending"
  requirements-{timestamp}.json
  test-spec-{controller}-{timestamp}.md

Phase 2 reads:
  testCases[].dtoClasses[]  ->  identify Entity
  testCases[].输入参数       ->  generate INSERT template

Phase 2 output:
  testCases[].entityClass      (added by identify-entity.sh)
  testCases[].insertTemplate   (added by gen-insert.sh)
  testCases[].insertStatus     (added by gen-insert.sh)
  testCases[].insertResult     (added by execute-insert.sh)
  testCases[].status = "data_inserted"  (updated by execute-insert.sh)

Phase 3 reads:
  testCases[] where status == "data_inserted"
  testCases[].输入参数.fields  ->  construct request body
  testCases[].method           ->  determine HTTP method and endpoint

Phase 3 output:
  testCases[].实际结果 = "PASS" | "FAIL"  (updated by run-test.sh)
  testCases[].原因 = error message        (updated by run-test.sh)
  testCases[].status = "completed"        (updated by run-test.sh)
  testResults{} top-level object          (added by run-test.sh)
  fixes[] top-level array                 (added by auto-fix.sh)
  test-reports/{timestamp}_report.md
  test-reports/{timestamp}_fixes.md
```

## Key Abstractions

**Test Spec JSON:**
- Purpose: Single source of truth for the entire pipeline; carries test case definitions, execution state, and results
- Examples: `{PROJECT_ROOT}/.auto-test/test-spec-{controller}-{timestamp}.json`
- Pattern: Accumulating document -- each phase adds fields without removing Phase 1 data. JSON schema versions track the extensions (v1.0 = Phase 1, v2.0 = Phase 2, v3.0 = Phase 3)

**AI Prompt Construction:**
- Purpose: Build structured prompts for Claude Code AI to generate test specs or analyze/fix code
- Examples: `gen-test-spec.sh` (lines 165-272), `auto-test-run/auto-fix.sh` (lines 159-207), `auto-test-gen/gen-test-class.sh` (lines 113-245)
- Pattern: Scripts collect context (source code, metadata, requirements), write prompt to temp file (`.gen-test-spec-prompt.txt`), then signal that AI is needed. The actual AI invocation is delegated to Claude Code's tool-calling environment.

**Entity Identification Strategy:**
- Purpose: Resolve DTO class names to database Entity classes for INSERT generation
- Examples: `auto-test-data/identify-entity.sh` (lines 170-327)
- Pattern: Three-tier fallback: (1) Annotation scan (`@Entity`/`@Table`) with confidence 0.95, (2) Naming inference (`SpmiCapacityBillIdDTO` -> `SpmiCapacityBill`) with confidence 0.7, (3) Database reverse (stub, not implemented). Results written as `entityClass` JSON with `identificationMethod` and `confidence` fields.

**User Confirmation Gate:**
- Purpose: Prevent unwanted file writes, database inserts, or code modifications without human approval
- Examples: `gen-test-spec.sh` show_preview + write_files, `execute-insert.sh` interactive confirm, `auto-fix.sh` ask_fix_confirmation
- Pattern: Scripts always display what they intend to do (markdown preview, SQL statement, code diff), then pause for user input. Only after explicit confirmation does the destructive action proceed.

## Entry Points

**`/auto-test <input>`:**
- Location: `auto-test/SKILL.md` (trigger) -> `auto-test/auto-test.sh` (execution)
- Triggers: User invokes `/auto-test` command in Claude Code
- Responsibilities: Create `.auto-test/` directory, validate prerequisites (mvn, java), run Phase 1/2/3 in sequence, report final output paths

**`/auto-test-gen <input>`:**
- Location: `auto-test-gen/SKILL.md` (trigger) -> scripts in `auto-test-gen/`
- Triggers: User invokes `/auto-test-gen` command, or called by orchestrator
- Responsibilities: Parse input (4 formats), run interactive requirements Q&A, extract Controller methods/DTOs/FeignClients, invoke AI to generate test spec, write JSON + markdown after user confirmation

**`/auto-test-data`:**
- Location: `auto-test-data/SKILL.md` (trigger) -> scripts in `auto-test-data/`
- Triggers: User invokes `/auto-test-data` command, or called by orchestrator
- Responsibilities: Read test-spec JSON, identify Entity classes from DTOs, generate INSERT SQL templates, execute INSERTs via MCP, update test case status to `data_inserted`

**`/auto-test-run`:**
- Location: `auto-test-run/SKILL.md` (trigger) -> scripts in `auto-test-run/`
- Triggers: User invokes `/auto-test-run` command, or called by orchestrator
- Responsibilities: Verify Phase 2 completion, Maven build, start Spring Boot app, curl test each endpoint, auto-fix failures (if <=5 line diff), generate test reports, update test case status to `completed`

## Error Handling

**Strategy:** Fail-fast with logging; interactive recovery for non-trivial errors; auto-fix for small bugs

**Patterns:**

- **Missing prerequisites:** `auto-test.sh` checks for `mvn` and `java` commands at startup; exits with error message if not found. `identify-entity.sh` checks for `jq`. Scripts use `set -e` to abort on any command failure.

- **File not found:** `parse-input.sh` exits with error if Controller file not found. `find_test_spec()` in multiple scripts returns exit code 1 with descriptive error when no test-spec JSON exists. `run-test.sh` aborts if jar not found in `target/`.

- **Phase order violations:** `verify_insert_status()` in `run-test.sh` checks that test cases have `status=data_inserted` before running. If only `pending` cases exist, it warns the user and offers abort or continue options.

- **Port conflict handling:** `run-test.sh` uses `lsof` to detect port occupancy, kills existing processes with `kill -9`, retries startup up to 3 times (`MAX_PORT_RETRY=3`). Waits up to 60 seconds for app startup with 2-second polling intervals.

- **Auto-fix scope limit:** `auto-fix.sh` only attempts fixes on Service layer files (matches path pattern `src/main/java/com/yl/spmibill/capacity/service`). Diff must be <=5 lines (`MAX_DIFF_LINES=5`). Non-service or large diffs are logged and skipped. Backs up original file before applying fix.

- **JSON update atomicity:** All test-spec JSON updates use the pattern: write to temp file (`.tmp`), then `mv` to replace original. This prevents partial writes on failure.

- **Maven build failure:** `run-test.sh` aborts pipeline if `mvn clean package -DskipTests` fails. `gen-test-class.sh` offers AI auto-fix for compilation errors, storing the error in state for AI to read.

- **Database safety:** `execute-insert.sh` warns on non-localhost connections. Database config read from env vars first, then `application.yml`, then interactive prompt. Password read with `-s` (silent) flag.

## Cross-Cutting Concerns

**Logging:** All scripts use `log_info()`, `log_error()`, `log_warn()` functions that prefix messages with ISO timestamps. `execute-insert.sh` also writes to a dedicated log file (`execute-insert.log`). Format: `[YYYY-MM-DD HH:MM:SS] INFO: message`

**Validation:** Input validation at each script entry point. JSON schema validation via `state-schema.json` files (draft-07). `jq` used extensively for safe JSON parsing; scripts handle `null`/empty gracefully with `// empty` fallbacks.

**Authentication:** Database credentials sourced from environment variables (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`) or parsed from `application.yml`. No secrets stored in scripts or test-spec JSON.

**Idempotency:** On re-run, `gen-test-spec.sh` appends `_v{n}` suffix to avoid overwriting existing test-spec files. `gen-test-class.sh` appends `_v{n}` suffix to existing test Java files. Test case processing skips cases that are not in the expected status (e.g., Phase 2 skips non-`pending` cases, Phase 3 skips non-`data_inserted` cases).

**Cleanup:** `run-test.sh` uses a `trap` on EXIT to clean up temp files (`/tmp/test_results_*`, `/tmp/curl_response_*`). `gen-test-spec.sh` removes `.gen-test-spec-prompt.txt` and `.gen-test-spec-ai-output.json` after writing output files.

---

*Architecture analysis: 2026-04-22*
