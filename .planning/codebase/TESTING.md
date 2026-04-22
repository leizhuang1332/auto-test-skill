# Testing Patterns

**Analysis Date:** 2026-04-22

## Test Framework

**Runner:**
- No test framework is used to test this project itself
- The project IS a testing tool -- it generates and runs integration tests for Spring Boot applications

**Assertion Library:**
- Not applicable for self-testing
- The project's own test validation logic uses bash conditionals and `jq` for JSON assertions

**Run Commands:**
- No test commands exist for the project itself
- The project's purpose is to run tests against target Spring Boot applications via:
```bash
bash auto-test.sh <input>                     # Run full pipeline
bash auto-test-gen/parse-input.sh <input>     # Test Phase 1 input parsing
bash auto-test-run/run-test.sh                # Test Phase 3 execution
```

## How the Project Tests Itself (or Doesn't)

**Current state: Zero self-testing.** The project has no unit tests, integration tests, or validation tests for its own scripts. There are no `*.test.sh`, `*.spec.sh`, or `*_test.sh` files anywhere in the codebase.

**What exists instead:**
- Manual verification checkpoints embedded in scripts (user confirmation prompts)
- Defensive error handling and validation within scripts
- Status tracking in test-spec JSON to detect pipeline failures

## Quality Gates Within the Pipeline

The project implements several human-in-the-loop quality gates rather than automated test suites:

### Gate 1: Requirements Clarification (Phase 1)

**Location:** `auto-test-gen/requirements-clarification.sh`

The script asks 5 interactive questions before generating test specs:
1. Business context (Q1)
2. Data boundaries (Q2)
3. External dependencies (Q3)
4. Common bugs (Q4)
5. Priority levels (Q5)

**Implementation:** The script detects if running within Claude Code (`$CLAUDE_CODE` env var) and expects the AskUserQuestion tool for interactive Q&A. When run standalone, it prints instructions.

### Gate 2: Test Spec Confirmation (Phase 1)

**Location:** `auto-test-gen/gen-test-spec.sh` lines 280-325

Before writing the test-spec JSON to disk:
1. AI generates JSON test spec as markdown preview
2. User reviews functionality, data boundaries, expected results
3. **On approve:** Write JSON file to `{PROJECT_ROOT}/.auto-test/`
4. **On reject:** Skip that test case

**Implementation in `gen-test-class.sh`** (lines 460-490):
```bash
ask_confirmation() {
    echo "Please confirm the generated test cases:"
    echo "  - Type 'yes' to approve all and write files"
    echo "  - Type 'no' to reject all"
    echo "  - Type 'select 1,3,5' to approve specific test cases"
    read -r user_choice
}
```

### Gate 3: INSERT Confirmation (Phase 2)

**Location:** `auto-test-data/execute-insert.sh` lines 428-484

Before executing each INSERT statement:
1. Display generated SQL
2. Show input parameters
3. User chooses: Enter (execute), `skip`, or `quit`

```bash
echo "Options:"
echo "  - Press Enter to EXECUTE this INSERT via MCP"
echo "  - Type 'skip' to skip this INSERT"
echo "  - Type 'quit' to exit entirely"
read -p "Your choice: " choice
```

### Gate 4: Non-localhost Database Safety (Phase 2)

**Location:** `auto-test-data/execute-insert.sh` lines 338-357

```bash
check_db_safety() {
    if [[ "$DB_HOST" != "localhost" ]] && [[ "$DB_HOST" != "127.0.0.1" ]]; then
        echo "WARNING: NON-LOCALHOST CONNECTION"
        echo "Press Ctrl+C to cancel, or Enter to continue..."
        read -r
    fi
}
```

### Gate 5: Auto-fix Confirmation (Phase 3)

**Location:** `auto-test-run/auto-fix.sh` lines 134-142 and `auto-test-run/run-test.sh` lines 374-388

Before applying any source code fix:
1. Show fix preview (original vs. fixed code)
2. Display diff line count and threshold
3. User chooses: `yes` (apply and re-run), `no` (skip fix)

```bash
ask_fix_confirmation() {
    echo "Apply this fix? (yes/no)"
    echo "  yes - apply fix and re-run test"
    echo "  no  - skip fix, continue to next test"
    read -p "Choice: " choice
}
```

### Gate 6: Phase 2 Completion Verification (Phase 3)

**Location:** `auto-test-run/run-test.sh` lines 70-115

Before running Phase 3 tests, the script verifies Phase 2 completion:
```bash
verify_insert_status() {
    local data_inserted=$(jq '[.testCases[] | select(.status == "data_inserted")] | length' ...)
    if [[ $data_inserted -eq 0 ]] && [[ $pending -gt 0 ]]; then
        log_error "WARNING: No test cases have 'data_inserted' status!"
        echo "Options:"
        echo "  1. Continue anyway (tests may fail)"
        echo "  2. Abort and run Phase 2 first"
        read -p "Choice (1/2, default=2): " choice
    fi
}
```

### Gate 7: Final Human Verification (Phase 3)

**Location:** `auto-test-run/run-test.sh` lines 720-732

After all tests complete:
```bash
echo "Please review the reports and confirm:"
echo "  - Type 'approve' to mark phase complete"
echo "  - Type any other text to describe issues"
read -r user_feedback
```

## Error Handling Patterns in Scripts

### Pattern 1: Exit on Error (`set -e`)

Every script uses `set -e` as the second line. This means any command returning non-zero exits the script immediately.

**Mitigations for `set -e`:**
- `2>/dev/null || true` to suppress expected failures
- `2>/dev/null || echo "[]"` for graceful degradation
- `if ! command; then ... fi` for explicit error handling

### Pattern 2: Prerequisite Checking

**Tool availability checks:**
```bash
# jq check (used in identify-entity.sh, gen-insert.sh, execute-insert.sh, gen-test-class.sh)
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed" >&2
    exit 1
fi

# Maven check (auto-test.sh lines 187-194)
if ! command -v mvn &> /dev/null; then
    log_error "Maven not found - required for auto-test"
    exit 1
fi

# python3 check (extract-methods.sh)
if ! command -v python3 &> /dev/null; then echo "[]"; exit 1; fi
```

**File existence checks:**
```bash
# Controller file (parse-input.sh)
if [[ ! -f "$CONTROLLER_PATH" ]]; then
    echo_error "Controller file not found: $CONTROLLER_NAME"
    exit 1
fi

# Test spec file (multiple scripts)
check_test_spec() {
    if [[ ! -f "$TEST_SPEC_FILE" ]]; then
        log_error "Test spec file not found"
        return 1
    fi
}
```

### Pattern 3: Fallback Values

```bash
# Default port (run-test.sh)
SERVER_PORT="${SERVER_PORT:-8080}"

# Default base branch (parse-input.sh)
DEFAULT_BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@')
: "${DEFAULT_BASE:=master}"

# Default controller name (gen-test-spec.sh)
if [[ -z "$CONTROLLER_NAME" ]]; then
    CONTROLLER_NAME=$(basename "$CONTROLLER_PATH" .java)
fi
```

### Pattern 4: Maven Build Failure Handling

**Location:** `auto-test-run/run-test.sh` lines 156-167

```bash
run_maven_build() {
    if ! mvn clean package -DskipTests -q 2>&1 | tee /tmp/mvn_build.log; then
        log_error "Maven build failed"
        cat /tmp/mvn_build.log
        return 1
    fi
}
```

In `gen-test-class.sh` (lines 647-683), Maven compile failure triggers an AI auto-fix offer:
```bash
if run_mvn_compile; then
    update_compile_status "true" ""
else
    echo "Would you like to attempt AI auto-fix? (yes/no)"
    read -r auto_fix_choice
    if [[ "$auto_fix_choice" == "yes" ]]; then
        jq --arg err "$compile_output" '.lastCompileError = $err' "$STATE_FILE" > ...
    fi
fi
```

### Pattern 5: Cleanup on Exit

**Location:** `auto-test-run/run-test.sh` line 671

```bash
trap "rm -f $RESULTS_FILE /tmp/curl_response_* /tmp/curl_timing_* 2>/dev/null" EXIT
```

This ensures temporary files are cleaned up even on abnormal exit.

## Robustness Measures

### Backup Before Auto-fix

**Location:** `auto-test-run/auto-fix.sh` lines 93-105

Every file modification is preceded by a backup:
```bash
backup_file() {
    local timestamp=$(date '+%Y%m%d_%H%M%S')
    local backup_path="${BACKUP_DIR}/$(basename "$file_path")_${timestamp}.bak"
    cp "$file_path" "$backup_path"
    log_info "Backed up to: $backup_path"
    echo "$backup_path"
}
```

Backups are stored in `{PROJECT_ROOT}/.auto-test/backups/` with timestamp suffixes.

### Port Conflict Handling

**Location:** `auto-test-run/run-test.sh` lines 202-265

Three-attempt retry logic with forced process kill:
```bash
MAX_PORT_RETRY=3

start_app() {
    local attempt=1
    while [[ $attempt -le $MAX_PORT_RETRY ]]; do
        if check_port_listening $SERVER_PORT; then
            kill_port_process $SERVER_PORT
        fi
        nohup java -jar "$jar_path" --spring.profiles.active=test > /tmp/app_startup.log 2>&1 &
        if wait_for_startup $SERVER_PORT; then
            return 0
        fi
        attempt=$((attempt + 1))
    done
    log_error "Failed to start app after $MAX_PORT_RETRY attempts"
    return 1
}
```

Startup wait logic (max 60 seconds):
```bash
wait_for_startup() {
    local max_wait=60
    local waited=0
    while ! check_port_listening $port; do
        if [[ $waited -ge $max_wait ]]; then
            log_error "App failed to start within ${max_wait}s"
            return 1
        fi
        sleep 2
        waited=$((waited + 2))
    done
}
```

### Auto-fix Scope Limitation

**Location:** `auto-test-run/auto-fix.sh` lines 8-12

Auto-fix is deliberately constrained to prevent unbounded changes:
```bash
MAX_DIFF_LINES=5
SERVICE_LAYER_PATTERN="src/main/java/com/yl/spmibill/capacity/service"
```

**Exclusions from auto-fix:**
- Controller parameter validation
- Transaction issues
- Database connection problems
- Feign client timeouts
- Any diff > 5 lines

### Atomic State File Updates

All test-spec JSON updates use the temp-file-and-rename pattern:
```bash
jq '.field = "value"' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
```

This prevents partial writes from corrupting the pipeline state.

### File Version Conflict Handling

**Location:** `auto-test-gen/SKILL.md` line 173

If a test-spec file already exists, a version suffix is appended:
```
test-spec-SpmiCapacityBillController_v1.json
```

**Implementation in `gen-test-class.sh`** (lines 252-271):
```bash
get_output_path() {
    local suffix=""
    local version=1
    while [[ -f "$full_path" ]]; do
        suffix="_v${version}"
        ((version++)) || true
    done
}
```

### State Idempotency

**Location:** `auto-test-gen/SKILL.md` line 177

On re-run, the pipeline merges `testCases[]` arrays and preserves existing test cases with their status and results, rather than overwriting.

## Test Validation Logic (Phase 3)

The project's test execution uses this response interpretation:

| Response | Interpretation |
|----------|----------------|
| HTTP 200 + `code=200` or `success=true` | PASS |
| HTTP 200 + `code!=200` or `success=false` | FAIL (business error) |
| HTTP 500 | FAIL (server error) |
| HTTP 000 or empty | FAIL (connection timeout) |
| Timeout (>10s via `--max-time $CURL_TIMEOUT`) | FAIL (timeout) |

**Implementation:** `auto-test-run/run-test.sh` lines 268-328

```bash
test_endpoint() {
    local business_code=$(echo "$response_body" | jq -r '.code // .success // ""')
    if [[ "$http_code" == "200" ]]; then
        if [[ "$business_code" == "200" ]] || [[ "$business_code" == "true" ]]; then
            status="PASS"
        else
            error_msg="Business error: code=$business_code"
        fi
    elif [[ "$http_code" == "000" ]] || [[ -z "$http_code" ]]; then
        error_msg="Connection timeout"
    else
        error_msg="HTTP $http_code"
    fi
}
```

## Fix Logging and Audit Trail

**Location:** `auto-test-run/auto-fix.sh` lines 209-243

Every fix attempt (applied, skipped, or failed) is logged to `fixes.jsonl`:
```bash
log_fix() {
    local fix_entry=$(jq -n \
        --arg tc "$test_case_id" \
        --arg f "$file" \
        --argjson ln "$line" \
        --arg iss "$issue" \
        --argjson dl "$diff_lines" \
        --arg st "$status" \
        --arg tr "$test_result_after" \
        '{testCaseId: $tc, file: $f, lineNumber: $ln, issue: $iss,
          diffLines: $dl, status: $st, testResultAfterFix: $tr}')
    echo "$fix_entry" | jq -c '.' >> "${FIX_LOG_DIR}/fixes.jsonl"
}
```

**INSERT execution logging:** `auto-test-data/execute-insert.sh` lines 64-81

All INSERT operations are logged to `{PROJECT_ROOT}/.auto-test/execute-insert.log` with dual output (console + file):
```bash
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" >> "$LOG_FILE"
}
```

## Known Quality Gaps

### Gap 1: No Self-Testing

**What's missing:** The project has zero automated tests for its own scripts. A typo in a `jq` filter, a broken regex, or a logic error in entity identification would only be caught at runtime against a real target project.

**Risk:** Silent data corruption (e.g., `jq` returning `null` where a string is expected), incorrect entity identification, broken INSERT templates.

**Priority:** High

### Gap 2: Inconsistent Error Handling Across Scripts

**What's missing:** Not all scripts follow the same error handling patterns. For example:
- `auto-test.sh` uses `log_info`/`log_error` functions
- `identify-entity.sh` routes ALL logs to stderr
- `execute-insert.sh` writes logs to both console and file
- `requirements-clarification.sh` uses `echo_info`/`echo_warn`/`echo_success` (different function names)

**Risk:** Inconsistent user experience; stderr-based logging may lose messages in some invocation patterns.

**Priority:** Medium

### Gap 3: No Validation of AI-Generated Output

**What's missing:** When AI generates test specs (Phase 1) or fix patches (Phase 3), the scripts do not validate the output against the JSON schema before writing. If the AI produces malformed JSON, it will be written to disk and may cause Phase 2/3 failures.

**Risk:** Pipeline breaks silently with invalid JSON; error messages are cryptic `jq` parse errors.

**Priority:** High

### Gap 4: MCP Execution Is Stubbed

**What's missing:** `execute-insert.sh` generates MCP scripts but cannot actually execute them. The status is set to `mcp_required` rather than `data_inserted`, which means Phase 3's `verify_insert_status()` will fail because no test cases have `status == "data_inserted"`.

**Risk:** Phase 2 cannot be completed in standalone script mode. Only works when orchestrated by Claude Code with MCP tools.

**Priority:** High (blocks standalone execution)

### Gap 5: Hardcoded Project-Specific Values

**What's missing:** Several scripts contain hardcoded values specific to the `yl-jms-spmibill-capacity` project:
- `auto-test-gen/extract-dto.sh` line 19: `com/yl/spmibill/capacity/dto`
- `auto-test-gen/extract-feign.sh` line 36: `com.yl.spmibill.capacity.feign`
- `auto-test-run/run-test.sh` line 12: `JAR_NAME="spmibill_capacity"`
- `auto-test-run/auto-fix.sh` line 12: `src/main/java/com/yl/spmibill/capacity/service`
- `gen-test-class.sh` line 29: `com/yl/spmibill/capacity/controller/generated`
- State schema files: `"project": "yl-jms-spmibill-capacity"` as `const`

**Risk:** The skill cannot be used with any other Spring Boot project without manual edits.

**Priority:** Medium

### Gap 6: No Curl Response Validation Against Schema

**What's missing:** Phase 3 checks for `code=200` or `success=true` in curl responses but does not validate the response body structure against `预期返回结果` from the test spec. The `data` field in expected results is never compared.

**Risk:** A test can PASS even if the response data is completely wrong, as long as `code=200`.

**Priority:** Medium

### Gap 7: Race Condition in Port Check

**What's missing:** `run-test.sh` uses `lsof` for port checking which has a TOCTOU (time-of-check-time-of-use) race condition between checking port availability and starting the Java process.

**Risk:** In rare cases, another process could grab the port between the check and the start.

**Priority:** Low

### Gap 8: No Retry on Curl Timeouts

**What's missing:** When a curl test times out (HTTP code 000), the script immediately marks it as FAIL with no retry logic. Transient network issues could cause false failures.

**Risk:** Flaky test results in environments with slow startup or network latency.

**Priority:** Low

## Test Types Summary

**Unit Tests:**
- Not used. No individual script functions are tested in isolation.

**Integration Tests:**
- The entire pipeline IS an integration test for the target Spring Boot application. But the pipeline scripts themselves have no integration tests.

**E2E Tests:**
- Not used for the project itself. The `auto-test.sh` full pipeline invocation serves as a manual E2E test.

**Smoke Tests:**
- Prerequisite checks (jq, mvn, java, python3 availability) serve as basic smoke tests before pipeline execution begins.

---

*Testing analysis: 2026-04-22*
