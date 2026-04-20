#!/bin/bash
set -e

# Configuration
# NEW ARCHITECTURE: Reads from test-spec-{controller}.json (Phase 1/2 output), NOT state.json
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
SKILL_DIR="$HOME/.claude/skills/auto-test-run"
TEST_SPEC_DIR="${PROJECT_ROOT}/.auto-test"
TEST_REPORT_DIR="${PROJECT_ROOT}/.auto-test/test-reports"
FIX_LOG_DIR="${PROJECT_ROOT}/.auto-test/test-reports"
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
JAR_NAME="spmibill_capacity"
MAX_PORT_RETRY=3
CURL_TIMEOUT=10
STARTUP_WAIT=15
AUTO_FIX_ENABLED=true

# Find latest test-spec JSON file
find_test_spec() {
    local controller="${1:-}"
    if [[ -n "$controller" ]]; then
        # Find specific controller's test spec
        local spec_file=$(ls -t "$TEST_SPEC_DIR"/test-spec-"${controller}"-*.json 2>/dev/null | head -1)
        if [[ -n "$spec_file" ]]; then
            echo "$spec_file"
            return 0
        fi
    fi
    # Find any test-spec file
    local spec_file=$(ls -t "$TEST_SPEC_DIR"/test-spec-*.json 2>/dev/null | head -1)
    if [[ -n "$spec_file" ]]; then
        echo "$spec_file"
        return 0
    fi
    return 1
}

# Set test spec file from controller argument or find latest
if [[ -n "$1" ]]; then
    TEST_SPEC_FILE=$(find_test_spec "$1")
else
    TEST_SPEC_FILE=$(find_test_spec)
fi

if [[ -z "$TEST_SPEC_FILE" ]]; then
    echo "[ERROR] test-spec JSON file not found in $TEST_SPEC_DIR" >&2
    echo "[ERROR] Run Phase 1 (auto-test-gen) and Phase 2 (auto-test-data) first" >&2
    exit 1
fi

# Logging functions
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

# Check test spec file exists
check_test_spec() {
    if [[ ! -f "$TEST_SPEC_FILE" ]]; then
        log_error "Test spec file not found: $TEST_SPEC_FILE"
        return 1
    fi
    log_info "Test spec file: $TEST_SPEC_FILE"
}

# Verify Phase 2 completion - check status = "data_inserted" before running tests
verify_insert_status() {
    log_info "Verifying Phase 2 completion (status = 'data_inserted')..."

    # Count test cases by status
    local total=$(jq '.testCases | length' "$TEST_SPEC_FILE" 2>/dev/null || echo "0")
    local data_inserted=$(jq '[.testCases[] | select(.status == "data_inserted")] | length' "$TEST_SPEC_FILE" 2>/dev/null || echo "0")
    local pending=$(jq '[.testCases[] | select(.status == "pending")] | length' "$TEST_SPEC_FILE" 2>/dev/null || echo "0")
    local completed=$(jq '[.testCases[] | select(.status == "completed")] | length' "$TEST_SPEC_FILE" 2>/dev/null || echo "0")

    log_info "Test Case Status: $data_inserted/$total data_inserted, $pending pending, $completed completed"

    # If no test cases have data_inserted status, Phase 2 may not have been run
    if [[ $data_inserted -eq 0 ]] && [[ $pending -gt 0 ]]; then
        log_error "WARNING: No test cases have 'data_inserted' status!"
        log_error "Phase 2 (auto-test-data) may not have been executed."

        # Show which test cases are affected
        local affected=$(jq -r '.testCases[] | select(.status == "pending") | "- \(.id // "unknown"): \(.method // "unknown") (status: pending)"' "$TEST_SPEC_FILE" 2>/dev/null)
        if [[ -n "$affected" ]]; then
            log_error "Affected test cases:"
            echo "$affected" >&2
        fi

        echo ""
        echo "=========================================="
        echo "   PHASE 2 NOT COMPLETED WARNING"
        echo "=========================================="
        echo "Phase 2 INSERT data has not been executed."
        echo "Running curl tests without INSERT data may cause misleading database errors."
        echo ""
        echo "Options:"
        echo "  1. Continue anyway (tests may fail)"
        echo "  2. Abort and run Phase 2 first"
        echo ""
        read -p "Choice (1/2, default=2): " choice
        choice="${choice:-2}"

        if [[ "$choice" == "2" ]]; then
            log_info "Aborting - run /auto-test-data first"
            return 1
        fi
        log_info "Continuing despite warning..."
    fi

    return 0
}

# Read test cases from test-spec JSON
# NEW ARCHITECTURE: Reads from test-spec-{controller}.json with status="data_inserted"
read_test_cases() {
    # Count test cases with status = "data_inserted"
    local total=$(jq '.testCases | length' "$TEST_SPEC_FILE" 2>/dev/null || echo "0")
    local data_inserted=$(jq '[.testCases[] | select(.status == "data_inserted")] | length' "$TEST_SPEC_FILE" 2>/dev/null || echo "0")
    log_info "Found $total total test case(s), $data_inserted ready for execution (status=data_inserted)"
    echo "$data_inserted"
}

# Construct request body from 输入参数.fields
# NEW ARCHITECTURE: Reads from 输入参数.fields array
construct_request_body() {
    local tc_json="$1"

    # Extract fields array from 输入参数
    local fields=$(echo "$tc_json" | jq -c '.["输入参数"].fields // []')

    if [[ "$fields" == "[]" ]] || [[ -z "$fields" ]]; then
        echo "{}"
        return
    fi

    # Build JSON object from fields using jq -p (pipe to build object)
    # This avoids subshell issues with while loops
    local body
    body=$(echo "$fields" | jq -n '
        [inputs] | flatten | reduce .[] as $field ({}; . + {($field.name): $field.value})
    ' 2>/dev/null)

    if [[ -z "$body" ]] || [[ "$body" == "null" ]]; then
        echo "{}"
    else
        echo "$body"
    fi
}

# Maven build
run_maven_build() {
    log_info "Running mvn clean package -DskipTests..."
    cd "$PROJECT_ROOT"

    if ! mvn clean package -DskipTests -q 2>&1 | tee /tmp/mvn_build.log; then
        log_error "Maven build failed"
        cat /tmp/mvn_build.log
        return 1
    fi

    log_info "Maven build successful"
    return 0
}

# Find jar file
find_jar_file() {
    local jar_path="$PROJECT_ROOT/target/${JAR_NAME}.jar"
    if [[ -f "$jar_path" ]]; then
        echo "$jar_path"
        return 0
    fi
    # Fallback: find any non-original jar
    local found=$(find "$PROJECT_ROOT/target" -name "*.jar" ! -name "*-original.jar" 2>/dev/null | head -1)
    if [[ -n "$found" ]]; then
        echo "$found"
        return 0
    fi
    log_error "jar file not found in target/"
    return 1
}

# Read application.yml config
read_app_config() {
    local app_yml="$PROJECT_ROOT/src/main/resources/application.yml"

    # Extract server.port
    SERVER_PORT=$(grep -A1 "^server:" "$app_yml" 2>/dev/null | grep "port:" | sed 's/.*port: *//' | tr -d ' ')
    SERVER_PORT="${SERVER_PORT:-8080}"

    # Extract context-path
    CONTEXT_PATH=$(grep "context-path:" "$app_yml" 2>/dev/null | sed 's/.*context-path: *//' | tr -d ' ')
    CONTEXT_PATH="${CONTEXT_PATH:-}"

    log_info "Config: port=$SERVER_PORT, context-path=$CONTEXT_PATH"
}

# Port checking
check_port_listening() {
    lsof -i :${1} 2>/dev/null | grep -q LISTEN
}

# Kill port process
kill_port_process() {
    local port=$1
    local pids=$(lsof -ti :${port} 2>/dev/null)
    if [[ -n "$pids" ]]; then
        log_info "Killing processes on port $port: $pids"
        echo "$pids" | xargs kill -9 2>/dev/null || true
        sleep 2
    fi
}

# Wait for startup
wait_for_startup() {
    local port=$1
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
    log_info "App started successfully on port $port"
    return 0
}

# Start application with retry
start_app() {
    local jar_path=$1
    local attempt=1

    while [[ $attempt -le $MAX_PORT_RETRY ]]; do
        log_info "Start attempt $attempt/$MAX_PORT_RETRY"

        if check_port_listening $SERVER_PORT; then
            log_info "Port $SERVER_PORT occupied, killing existing process..."
            kill_port_process $SERVER_PORT
        fi

        nohup java -jar "$jar_path" --spring.profiles.active=test \
            > /tmp/app_startup.log 2>&1 &

        if wait_for_startup $SERVER_PORT; then
            return 0
        fi

        attempt=$((attempt + 1))
        if [[ $attempt -le $MAX_PORT_RETRY ]]; then
            log_info "Retry $attempt in 5 seconds..."
            sleep 5
        fi
    done

    log_error "Failed to start app after $MAX_PORT_RETRY attempts"
    cat /tmp/app_startup.log
    return 1
}

# Test single endpoint
test_endpoint() {
    local method=$1
    local endpoint=$2
    local body=$3
    local test_case_id=$4

    local url="http://localhost:${SERVER_PORT}${CONTEXT_PATH}${endpoint}"
    local response_file="/tmp/curl_response_${test_case_id}_$$.json"

    local http_code
    local time_ms
    local response_body

    if [[ "$method" == "GET" ]]; then
        http_code=$(curl -s -X GET "$url" \
            -w "\n%{http_code}\n%{time_ms}" \
            -o "$response_file" \
            --max-time $CURL_TIMEOUT 2>/dev/null | tail -1)
        time_ms=$(curl -s -X GET "$url" \
            -w "%{time_ms}" \
            -o /dev/null --max-time $CURL_TIMEOUT 2>/dev/null)
    else
        http_code=$(curl -s -X POST "$url" \
            -H "Content-Type: application/json" \
            -d "$body" \
            -w "\n%{http_code}\n%{time_ms}" \
            -o "$response_file" \
            --max-time $CURL_TIMEOUT 2>/dev/null | tail -1)
        time_ms=$(curl -s -X POST "$url" \
            -H "Content-Type: application/json" \
            -d "$body" \
            -w "%{time_ms}" \
            -o /dev/null --max-time $CURL_TIMEOUT 2>/dev/null)
    fi

    response_body=$(cat "$response_file" 2>/dev/null)

    # Parse business code from response
    local business_code
    business_code=$(echo "$response_body" | jq -r '.code // .success // ""' 2>/dev/null)

    # Determine PASS/FAIL
    local status="FAIL"
    local error_msg=""

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

    rm -f "$response_file"

    # Output JSON for later processing
    echo "{\"testCaseId\":\"$test_case_id\",\"endpoint\":\"$endpoint\",\"method\":\"$method\",\"status\":\"$status\",\"httpStatus\":$http_code,\"responseTimeMs\":$time_ms,\"errorMessage\":\"$error_msg\"}"
}

# Invoke auto-fix when test fails
invoke_auto_fix() {
    local test_case_id=$1
    local endpoint=$2
    local method=$3
    local error_message=$4

    local error_log="/tmp/test_error_${test_case_id}.log"
    echo "$error_message" > "$error_log"

    log_info "Calling auto-fix for test case: $test_case_id"

    # Call auto-fix.sh and capture full output
    local fix_output
    fix_output=$(bash "$SKILL_DIR/auto-fix.sh" "$error_log" "$test_case_id" 2>&1)
    local fix_status=$?

    local fix_action=""

    if echo "$fix_output" | grep -q "^skipped$"; then
        log_info "Auto-fix skipped (non-service layer or parse error)"
        fix_action="skipped"
    elif echo "$fix_output" | grep -q "^error$"; then
        log_error "Auto-fix encountered error"
        fix_action="error"
    elif echo "$fix_output" | grep -q "^ai_fix_needed$"; then
        # Extract the AI prompt (everything after "ai_fix_needed")
        local ai_prompt=$(echo "$fix_output" | sed -n '/^ai_fix_needed$/,/^$/p' | tail -n +2)

        log_info "AI fix needed - prompting user for confirmation"

        # Show AI prompt to user
        echo ""
        echo "=========================================="
        echo "   AUTO-FIX RECOMMENDED"
        echo "=========================================="
        echo ""
        echo "$ai_prompt"
        echo ""
        echo "=========================================="
        echo ""

        # Ask for confirmation
        echo "Apply this fix? (yes/no)"
        echo "  yes - apply fix and re-run test"
        echo "  no  - skip fix, continue to next test"
        echo ""
        read -p "Choice: " choice

        if [[ "$choice" == "yes" ]]; then
            log_info "Fix confirmed by user"
            # Mark as fix_needed - actual fix application requires Claude Code
            echo "NOTE: Fix requires Claude Code tool calling for actual code modification"
            fix_action="fix_needed"
        else
            log_info "Fix declined by user"
            fix_action="fix_declined"
        fi
    else
        log_error "Unknown response from auto-fix.sh"
        fix_action="error"
    fi

    echo "$fix_action"
}

# Run all tests
# NEW ARCHITECTURE: Reads from test-spec-{controller}.json, only status="data_inserted"
run_all_tests() {
    log_info "Starting endpoint tests..."

    # Initialize results array
    echo "[]" > "$RESULTS_FILE"

    # Read test cases with status = "data_inserted" from test-spec JSON
    local test_cases
    test_cases=$(jq -c '[.testCases[] | select(.status == "data_inserted")]' "$TEST_SPEC_FILE" 2>/dev/null || echo "[]")

    local count=$(echo "$test_cases" | jq 'length' 2>/dev/null || echo "0")
    log_info "Found $count test case(s) ready for execution"

    # For each test case, extract endpoint info and test
    echo "$test_cases" | jq -c '.[]' 2>/dev/null | while read tc; do
        local method_name=$(echo "$tc" | jq -r '.method // empty')
        local tc_id=$(echo "$tc" | jq -r '.id // "unknown"')
        local 功能=$(echo "$tc" | jq -r '.功能 // "unknown"')

        # Construct request body from 输入参数.fields
        local request_body
        request_body=$(construct_request_body "$tc")

        # Determine HTTP method from method name (default POST for mutations, GET for queries)
        local http_method="POST"
        if [[ "$method_name" == get* ]] || [[ "$method_name" == query* ]] || [[ "$method_name" == find* ]]; then
            http_method="GET"
        fi

        # Get route path from controller + method name mapping
        # For now, we need to construct the endpoint
        # The route would typically come from @PostMapping/@GetMapping annotation
        # For Phase 3, we use a convention: /{context-path}/spmi/capacity/bill/{methodName}
        local endpoint="/spmi/capacity/bill/${method_name}"

        if [[ -n "$method_name" ]]; then
            log_info "Testing [$tc_id]: $http_method $endpoint (功能: $功能)"
            log_info "Request body: $request_body"

            local result_json
            result_json=$(test_endpoint "$http_method" "$endpoint" "$request_body" "$tc_id")

            # Check if test failed and auto-fix is enabled
            local test_status=$(echo "$result_json" | jq -r '.status')
            if [[ "$test_status" == "FAIL" ]] && [[ "$AUTO_FIX_ENABLED" == "true" ]]; then
                local error_msg=$(echo "$result_json" | jq -r '.errorMessage')
                log_info "Test failed: $error_msg"

                local fix_result
                fix_result=$(invoke_auto_fix "$tc_id" "$endpoint" "$http_method" "$error_msg")

                if [[ "$fix_result" == "fix_needed" ]]; then
                    log_info "Fix identified - rebuilding and retrying..."
                    # Rebuild and restart
                    if run_maven_build; then
                        kill_port_process $SERVER_PORT
                        if start_app "$JAR_PATH"; then
                            log_info "Retrying test after fix..."
                            result_json=$(test_endpoint "$http_method" "$endpoint" "$request_body" "$tc_id")
                        fi
                    fi
                fi
            fi

            # Append to results file
            jq --argjson result "$result_json" '. += [$result]' "$RESULTS_FILE" > "${RESULTS_FILE}.tmp"
            mv "${RESULTS_FILE}.tmp" "$RESULTS_FILE"

            # Update test-spec JSON with actual results
            update_test_case_result "$tc_id" "$result_json"
        fi
    done
}

# Update test-spec JSON with actual results
# NEW ARCHITECTURE: Updates 实际结果, 原因, status=completed in test-spec JSON
update_test_case_result() {
    local tc_id="$1"
    local result_json="$2"

    local actual_result=$(echo "$result_json" | jq -r '.status')
    local error_message=$(echo "$result_json" | jq -r '.errorMessage')

    # Update the test-spec JSON
    # Set 实际结果 = "PASS" or "FAIL"
    # Set 原因 = error message if FAIL
    # Set status = "completed"
    local updated_spec
    updated_spec=$(jq --arg id "$tc_id" --arg result "$actual_result" --arg reason "$error_message" \
        '.testCases |= [.testCases[] | if .id == $id then
            .["实际结果"] = $result |
            .["原因"] = (if $result == "FAIL" then $reason else null end) |
            .status = "completed"
        else . end]' \
        "$TEST_SPEC_FILE" 2>/dev/null)

    if [[ -n "$updated_spec" ]]; then
        echo "$updated_spec" > "$TEST_SPEC_FILE"
        log_info "Updated test-spec: $tc_id -> $actual_result (status=completed)"
    fi
}

# Report generation functions
ensure_report_dir() {
    if [[ ! -d "$TEST_REPORT_DIR" ]]; then
        mkdir -p "$TEST_REPORT_DIR"
        log_info "Created report directory: $TEST_REPORT_DIR"
    fi
}

generate_summary_json() {
    local total=$1
    local passed=$2
    local failed=$3
    local skipped=$4
    local duration_ms=$5

    jq -n \
        --argjson total "$total" \
        --argjson passed "$passed" \
        --argjson failed "$failed" \
        --argjson skipped "$skipped" \
        --argjson duration "$duration_ms" \
        '{
            total: $total,
            passed: $passed,
            failed: $failed,
            skipped: $skipped,
            durationMs: $duration
        }'
}

generate_test_report() {
    local timestamp="$1"
    local results_file="$2"
    local input_value="$3"

    local report_path="${TEST_REPORT_DIR}/${timestamp}_report.md"

    ensure_report_dir

    # Read results
    local total=$(jq '[.[] | select(.status)] | length' "$results_file" 2>/dev/null || echo "0")
    local passed=$(jq '[.[] | select(.status == "PASS")] | length' "$results_file" 2>/dev/null || echo "0")
    local failed=$(jq '[.[] | select(.status == "FAIL")] | length' "$results_file" 2>/dev/null || echo "0")
    local skipped=$(jq '[.[] | select(.status == "SKIP")] | length' "$results_file" 2>/dev/null || echo "0")

    # Build markdown report
    cat > "$report_path" << REPORT_EOF
# Auto-Test Report

## Test Summary
- **Input**: ${input_value}
- **Timestamp**: $(date -j '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date '+%Y-%m-%d %H:%M:%S')
- **Total**: ${total}
- **Passed**: ${passed}
- **Failed**: ${failed}
- **Skipped**: ${skipped}

## Detailed Results

| Endpoint | Method | Status | Duration | HTTP Status |
|----------|--------|--------|----------|-------------|
$(jq -r '.[] | "| \(.endpoint) | \(.method) | \(.status) | \(.responseTimeMs)ms | \(.httpStatus) |"' "$results_file" 2>/dev/null || echo "| - | - | - | - | - |")

## Failure Details

$(jq -r '.[] | select(.status == "FAIL") | "### \(.endpoint)\n- HTTP Status: \(.httpStatus)\n- Error: \(.errorMessage // "Unknown")\n"' "$results_file" 2>/dev/null || echo "No failures")
REPORT_EOF

    log_info "Test report: $report_path"
    echo "$report_path"
}

generate_fix_log() {
    local timestamp="$1"
    local fixes_file="${FIX_LOG_DIR}/fixes.jsonl"

    local fix_log_path="${TEST_REPORT_DIR}/${timestamp}_fixes.md"

    if [[ ! -f "$fixes_file" ]] || [[ ! -s "$fixes_file" ]]; then
        log_info "No fixes to log"
        return 0
    fi

    cat > "$fix_log_path" << 'FIXHEADER'
# Auto-Test Fix Log

## Fix Records

FIXHEADER

    local fix_num=1
    while IFS= read -r line; do
        local test_case_id=$(echo "$line" | jq -r '.testCaseId')
        local file=$(echo "$line" | jq -r '.file')
        local line_num=$(echo "$line" | jq -r '.lineNumber')
        local issue=$(echo "$line" | jq -r '.issue')
        local diff_lines=$(echo "$line" | jq -r '.diffLines')
        local status=$(echo "$line" | jq -r '.status')
        local result_after=$(echo "$line" | jq -r '.testResultAfterFix')

        cat >> "$fix_log_path" << FIXENTRY
### ${fix_num}. ${file}:${line_num} - ${issue}
**Status**: ${status}
**Diff**: ${diff_lines} line(s)
**Test After Fix**: ${result_after}

---
FIXENTRY

        fix_num=$((fix_num + 1))
    done < "$fixes_file"

    log_info "Fix log: $fix_log_path"
    echo "$fix_log_path"
}

update_state_with_results() {
    local timestamp="$1"
    local results_file="$2"
    local report_path="$3"
    local fix_log_path="$4"

    local test_results_json
    test_results_json=$(jq -s '.' "$results_file" 2>/dev/null)

    # Read summary
    local total=$(jq 'length' "$results_file" 2>/dev/null || echo "0")
    local passed=$(jq '[.[] | select(.status == "PASS")] | length' "$results_file" 2>/dev/null || echo "0")
    local failed=$(jq '[.[] | select(.status == "FAIL")] | length' "$results_file" 2>/dev/null || echo "0")
    local skipped=$(jq '[.[] | select(.status == "SKIP")] | length' "$results_file" 2>/dev/null || echo "0")

    local summary_json
    summary_json=$(generate_summary_json "$total" "$passed" "$failed" "$skipped" 0)

    # Update test-spec JSON with phase completion
    local controller=$(jq -r '.controller // "unknown"' "$TEST_SPEC_FILE" 2>/dev/null)

    # Update phase field in test-spec
    local updated_spec
    updated_spec=$(jq --arg phase "phase3_completed" --arg ts "$timestamp" \
        --arg rp "$report_path" --arg fp "$fix_log_path" \
        --argjson summary "$summary_json" \
        --argjson results "$test_results_json" \
        '. + {
            phase: $phase,
            testResults: {
                timestamp: $ts,
                reportPath: $rp,
                fixLogPath: $fp,
                summary: $summary,
                details: $results
            }
        }' "$TEST_SPEC_FILE" 2>/dev/null)

    if [[ -n "$updated_spec" ]]; then
        echo "$updated_spec" > "$TEST_SPEC_FILE"
        log_info "Updated test-spec with phase3_completed status"
    fi
}

# Main flow
main() {
    log_info "Starting run-test.sh"
    log_info "Project: $PROJECT_ROOT"
    log_info "Test spec: $TEST_SPEC_FILE"

    # Add temp file for results
    RESULTS_FILE="/tmp/test_results_$$.json"

    # Add cleanup trap
    trap "rm -f $RESULTS_FILE /tmp/curl_response_* /tmp/curl_timing_* 2>/dev/null" EXIT

    # 1. Check test spec file
    check_test_spec

    # 1.5. Verify Phase 2 completion (status = "data_inserted")
    if ! verify_insert_status; then
        log_error "Phase 2 verification failed - aborting"
        exit 1
    fi

    # 2. Maven build
    if ! run_maven_build; then
        log_error "Maven build failed - aborting"
        exit 1
    fi

    # 3. Find jar
    JAR_PATH=$(find_jar_file) || exit 1
    log_info "Jar: $JAR_PATH"

    # 4. Read config
    read_app_config

    # 5. Start app
    if ! start_app "$JAR_PATH"; then
        log_error "App start failed - aborting"
        exit 1
    fi

    # 6. Run tests
    run_all_tests

    # 7. Generate reports
    log_info "Generating test report..."
    local controller_name=$(jq -r '.controller // "unknown"' "$TEST_SPEC_FILE" 2>/dev/null)
    local report_path
    report_path=$(generate_test_report "$TIMESTAMP" "$RESULTS_FILE" "$controller_name")

    # Generate fix log if fixes exist
    local fix_log_path=""
    if [[ -f "${FIX_LOG_DIR}/fixes.jsonl" ]]; then
        fix_log_path=$(generate_fix_log "$TIMESTAMP")
    fi

    # Update test-spec JSON
    update_state_with_results "$TIMESTAMP" "$RESULTS_FILE" "$report_path" "$fix_log_path"

    # Human verification checkpoint
    echo ""
    echo "=========================================="
    echo "   TEST EXECUTION COMPLETE"
    echo "=========================================="
    echo ""
    echo "Reports generated:"
    echo "  - Test Report: ${TEST_REPORT_DIR}/${TIMESTAMP}_report.md"
    echo "  - Fix Log: ${TEST_REPORT_DIR}/${TIMESTAMP}_fixes.md (if fixes applied)"
    echo ""
    echo "Please review the reports and confirm:"
    echo "  - Type 'approve' to mark phase complete"
    echo "  - Type any other text to describe issues"
    read -r user_feedback

    log_info "run-test.sh completed"
}

main "$@"