# Coding Conventions

**Analysis Date:** 2026-04-22

## Naming Patterns

**Files:**
- Shell scripts: `kebab-case.sh` (e.g., `parse-input.sh`, `extract-methods.sh`, `gen-test-spec.sh`, `auto-fix.sh`)
- JSON schemas: `kebab-case.json` (e.g., `state-schema.json`)
- Skill documentation: `SKILL.md` (always uppercase, fixed name)
- Test spec output files: `test-spec-{ControllerName}-{timestamp}.json` (e.g., `test-spec-SpmiCapacityBillController-20260420_100000.json`)
- Report output files: `{timestamp}_report.md`, `{timestamp}_fixes.md`
- Backup files: `{filename}_{timestamp}.bak`

**Functions (bash):**
- `snake_case` for all shell functions (e.g., `log_info`, `find_test_spec`, `parse_stack_trace`, `build_ai_fix_prompt`)
- Accessor/query functions prefixed with `get_`, `read_`, `find_`, `check_`, `count_` (e.g., `get_all_dto_classes`, `read_app_config`, `find_jar_file`, `check_test_spec_structure`, `count_entity_classes`)
- Mutator/update functions prefixed with `update_`, `mark_`, `write_` (e.g., `update_test_case_status`, `mark_confirmed`, `write_test_file`)
- Lifecycle functions: `ensure_*` for directory creation (e.g., `ensure_backup_dir`, `ensure_report_dir`)

**Variables (bash):**
- `UPPER_SNAKE_CASE` for constants and configuration variables (e.g., `PROJECT_ROOT`, `AUTO_TEST_DIR`, `MAX_DIFF_LINES`, `CURL_TIMEOUT`)
- `lower_snake_case` for local/script-level variables (e.g., `controller_name`, `test_spec`, `tc_count`)
- Chinese field names in JSON preserved as-is (e.g., `功能`, `数据边界`, `输入参数`, `预期返回结果`, `实际结果`, `原因`)

**JSON keys (test-spec schema):**
- `camelCase` for English keys (e.g., `testCase`, `dtoClass`, `entityClass`, `insertTemplate`, `businessContext`)
- Chinese keys for business-domain fields (e.g., `功能`, `数据边界`, `输入参数`, `预期返回结果`, `实际结果`, `原因`)
- Test case IDs: `TC{NNN}` pattern with regex `^TC\d{3}$` (e.g., `TC001`, `TC002`)
- Phase enum values: `snake_case` (e.g., `phase1_in_progress`, `phase2_completed`, `data_inserted`)

## Code Style

**Formatting:**
- No linter or formatter configured for shell scripts
- No consistent indentation width (some files use 2 spaces, others 4)
- Line length varies; no enforced limit

**Shebang:**
- All shell scripts use `#!/bin/bash`
- All scripts include `set -e` (exit on error) as the second line

**Shell compatibility:**
- Bash-specific features used: `[[ ]]` conditionals, `${BASH_REMATCH}`, `declare -a`, `read -p`, `read -s`, process substitution `< <(...)`, heredocs
- Not POSIX sh compatible

## Import Organization

**Script invocation order:**
1. `parse-input.sh` (no dependencies)
2. `requirements-clarification.sh` (no script dependencies, uses `$1`)
3. `extract-methods.sh` (requires `$1` = controller path)
4. `extract-dto.sh` (requires `$1` = method signature)
5. `extract-feign.sh` (requires `$1` = controller path)
6. `gen-test-spec.sh` (orchestrates 1-5)
7. `identify-entity.sh` (reads test-spec JSON from Phase 1)
8. `gen-insert.sh` (reads test-spec JSON, requires entity classes)
9. `execute-insert.sh` (reads test-spec JSON, requires INSERT templates)
10. `run-test.sh` (reads test-spec JSON, requires data_inserted status)
11. `auto-fix.sh` (called by run-test.sh on failure)

**Path resolution pattern:**
```bash
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$HOME/.claude/skills/auto-test-{gen,data,run}"
```

**External tool dependencies:**
- `jq` -- required for all JSON processing, checked with `command -v jq`
- `python3` -- used for complex parsing in `extract-methods.sh` and `extract-dto.sh`
- `git` -- used for project root detection and diff-based input parsing
- `mvn` -- required for Phase 3 build
- `java` -- required for Phase 3 app startup
- `curl` -- required for Phase 3 endpoint testing
- `lsof` -- required for port conflict handling

## Script Structure Pattern

Every shell script follows this canonical structure:

```bash
#!/bin/bash
# {script-name}.sh - {One-line description}
# Phase {N}: {What this phase does}
#
# Usage:
#   bash {script-name}.sh {arguments}
#
# Flow:
#   1. {Step description}
#   2. {Step description}

set -e

# ============================================================
# CONFIGURATION
# ============================================================
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
# ... other constants

# ============================================================
# FUNCTIONS
# ============================================================

log_info() { ... }
log_error() { ... }

# Helper functions grouped by concern

# ============================================================
# MAIN FLOW
# ============================================================

main() {
    # Validate input
    # Find test-spec file
    # Process data
    # Update state
    # Display summary
}

main "$@"
```

**Key structural conventions:**
- Section headers use `# =====...` separator lines (77 `=` characters)
- Every script has a `main()` function called at the bottom
- Direct invocation guard: `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` (used in `auto-fix.sh`, `gen-test-spec.sh`)
- Other scripts simply call `main "$@"` unconditionally

## JSON Schema Conventions

**Schema structure (`state-schema.json` files):**
- JSON Schema draft-07 (`"$schema": "http://json-schema.org/draft-07/schema#"`)
- Title follows pattern: `"Auto-Test-{Phase} State Schema"`
- Version numbers increment per phase: `"1.0"` (Phase 1), `"2.0"` (Phase 2), `"3.0"` (Phase 3)
- Definitions use `$ref` for reusability
- `additionalProperties: false` on strict objects (Phase 1 schema); `additionalProperties: true` on lenient objects (Phase 2/3 schemas)
- Required fields listed explicitly in `"required"` arrays
- Enum fields defined as reusable definitions (e.g., `phaseEnum`, `testCaseStatusEnum`, `insertStatusEnum`)
- Confidence scores: `0.0` to `1.0` range with `"minimum": 0, "maximum": 1`
- Nullable fields: `"type": ["string", "null"]` pattern

**Phase-to-phase schema extension pattern:**
- Phase 1 schema (`auto-test-gen/state-schema.json`): Defines `testCase` with `pending` status, DTO classes, Chinese business fields
- Phase 2 schema (`auto-test-data/state-schema.json`): Extends with `entityClass`, `insertTemplate`, `insertStatus`, `insertResult`
- Phase 3 schema (`auto-test-run/state-schema.json`): Extends with `testResults`, `fixes`, `testReportPath`, `fixReportPath`

**Inconsistency note:** Phase 1 schema uses `additionalProperties: false` (strict), while Phase 2 and 3 use `additionalProperties: true` (lenient). This allows Phase 2/3 to add fields without schema violation but loses validation strictness.

## SKILL.md Documentation Pattern

Every SKILL.md follows this fixed structure:

```markdown
---
name: {skill-name}
description: {One-line description of purpose and flow}
metadata:
  author: leizhuang1332
  version: "{N}"
  phase: {N}
  pipeline: auto-test
---

# Skill: {skill-name}

**Phase:** Phase {N} ({skill-name})
**Purpose:** {What it does}

## Triggers
## Input
## Output
## Data Flow (ASCII diagram)
## Scripts (table)
## Prerequisites
## State Schema Extensions (JSON example)
## Architecture Pattern
## File Structure (tree)
```

**Key SKILL.md conventions:**
- YAML frontmatter is mandatory with `name`, `description`, `metadata` fields
- Pipeline name is always `auto-test`
- Author is always `leizhuang1332`
- Data flow diagrams use ASCII art with box-drawing characters
- Script tables use `| Script | Purpose |` format
- File structure shows the installed path at `~/.claude/skills/{skill-name}/`

## Data Format Conventions

**Test-spec JSON structure (the source of truth):**
```json
{
  "version": "1.0",
  "project": "yl-jms-spmibill-capacity",
  "createdAt": "ISO8601",
  "controller": "SpmiCapacityBillController",
  "controllerPath": "/abs/path/Controller.java",
  "phase": "phase1_completed",
  "requirements": {
    "businessContext": "...",
    "dataBoundaries": ["..."],
    "externalDependencies": ["..."],
    "commonBugs": ["..."],
    "priority": { "TC001": "blocking" }
  },
  "testCases": [...]
}
```

**Status progression across phases:**
- Test case `status`: `pending` -> `data_inserted` -> `completed`
- Root `phase`: `phase1_completed` -> `phase2_in_progress` -> `phase2_completed` -> `phase3_in_progress` -> `phase3_completed`

**INSERT template format:**
```sql
INSERT INTO {table_name} ({snake_case_columns}) VALUES (#{camelCasePlaceholders});
```
- Use `#{varName}` placeholders for user-provided values
- Use `NOW()` for datetime fields
- Use `'#{varName}'` (quoted) for enum/unknown types

**AI prompt format:**
- Stored as `.gen-test-spec-prompt.txt` or inline heredoc
- Uses markdown code blocks for source code embedding
- Ends with explicit output format instructions: "Return ONLY the JSON object"

**Test report format (markdown):**
- Header: `# Auto-Test Report`
- Summary section with total/passed/failed/skipped counts
- Results table with columns: `| Endpoint | Method | Status | Duration | HTTP Status |`
- Failure details section with error messages

**Fix log format (JSONL):**
- Each fix is a single-line JSON object appended to `fixes.jsonl`
- Fields: `testCaseId`, `file`, `lineNumber`, `issue`, `diffLines`, `status`, `testResultAfterFix`

## Error Handling

**Logging pattern (consistent across all scripts):**
```bash
log_info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2; }
```
- `log_info` goes to stdout
- `log_error` and `log_warn` go to stderr
- Exception: `identify-entity.sh` sends ALL log output to stderr to keep stdout clean for command substitution

**Exit codes:**
- `0` -- success
- `1` -- general error (missing argument, file not found, validation failure)
- Scripts use `set -e` so any unhandled command failure terminates the script

**Graceful degradation patterns:**
- Missing optional files: `2>/dev/null || echo "[]"` / `2>/dev/null || echo "0"` / `2>/dev/null || true`
- Missing tools: `command -v jq &> /dev/null` check with explicit error message
- Missing test spec: informative error with "Run Phase N first" guidance
- Python3 unavailable: `extract-methods.sh` returns empty array `[]`

**State file update safety:**
```bash
jq '.field = "value"' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
```
- Atomic write via temp file + rename pattern
- Used consistently in `identify-entity.sh`, `gen-insert.sh`, `execute-insert.sh`, `gen-test-class.sh`

## Comments

**When to comment:**
- Header comment block on every script: purpose, usage, flow description
- Section separator comments with `=` character lines
- Inline comments for complex logic (e.g., regex patterns, business rules)
- Chinese comments are acceptable for business-domain explanations

**JSDoc/TSDoc:**
- Not applicable (no TypeScript/JavaScript in this project)

## Function Design

**Size:** Functions range from 5 to 80 lines. Longer functions exist in `gen-insert.sh` and `run-test.sh` where orchestration logic is concentrated.

**Parameters:**
- Positional arguments (`$1`, `$2`, etc.) -- no `getopts` or named argument parsing
- First argument is typically the controller name or file path
- Default values set with `${VAR:-default}` pattern

**Return values:**
- Data output: `echo` to stdout (captured via command substitution)
- Error output: `echo` to stderr + `return 1`
- Status indicators: `echo "skipped"`, `echo "error"`, `echo "ai_fix_needed"` as string return codes

## Module Design

**Exports:** Shell scripts are standalone executables, not sourced as libraries. Exception: `gen-test-spec.sh` uses `if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then main "$@"; fi` to support both sourcing and direct execution.

**Barrel files:** None. Each script is invoked directly.

**Inter-script communication:** Via the shared `test-spec-{controller}-{timestamp}.json` file in `{PROJECT_ROOT}/.auto-test/`, not via stdout piping between scripts.

---

*Convention analysis: 2026-04-22*
