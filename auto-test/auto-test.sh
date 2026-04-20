#!/bin/bash
set -e

# auto-test.sh - Pipeline orchestration for auto-test-gen → auto-test-data → auto-test-run
# Uses test-spec-{controller}.json in {PROJECT_ROOT}/.auto-test/ as source of truth

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
AUTO_TEST_DIR="${PROJECT_ROOT}/.auto-test"
SKILL_DIR="$HOME/.claude/skills/auto-test"
PHASE1_DIR="$HOME/.claude/skills/auto-test-gen"
PHASE2_DIR="$HOME/.claude/skills/auto-test-data"
PHASE3_DIR="$HOME/.claude/skills/auto-test-run"

log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

# Ensure .auto-test directory exists
ensure_auto_test_dir() {
    if [[ ! -d "$AUTO_TEST_DIR" ]]; then
        mkdir -p "$AUTO_TEST_DIR"
        mkdir -p "${AUTO_TEST_DIR}/test-reports"
        mkdir -p "${AUTO_TEST_DIR}/backups"
        mkdir -p "${AUTO_TEST_DIR}/insert-templates"
        log_info "Created .auto-test directory structure"
    fi
}

# Find latest test-spec JSON file
find_test_spec() {
    local controller="$1"
    if [[ -n "$controller" ]]; then
        local spec_file=$(ls -t "${AUTO_TEST_DIR}"/test-spec-"${controller}"-*.json 2>/dev/null | head -1)
        if [[ -n "$spec_file" ]]; then
            echo "$spec_file"
            return 0
        fi
    fi
    # Find any test-spec file
    local spec_file=$(ls -t "${AUTO_TEST_DIR}"/test-spec-*.json 2>/dev/null | head -1)
    if [[ -n "$spec_file" ]]; then
        echo "$spec_file"
        return 0
    fi
    return 1
}

# Extract controller name from test-spec JSON
get_controller_from_spec() {
    local spec_file="$1"
    jq -r '.controller // empty' "$spec_file" 2>/dev/null
}

# Run Phase 1: auto-test-gen
run_phase1() {
    log_info "=========================================="
    log_info "PHASE 1: Generating test cases"
    log_info "=========================================="

    local input="$1"
    if [[ -z "$input" ]]; then
        log_error "No input provided for Phase 1"
        return 1
    fi

    cd "$PHASE1_DIR"

    # parse-input.sh
    log_info "Running parse-input.sh..."
    bash parse-input.sh "$input"

    # requirements-clarification.sh (interactive Q&A)
    log_info "Running requirements-clarification.sh..."
    bash requirements-clarification.sh

    # extract-methods.sh
    log_info "Running extract-methods.sh..."
    bash extract-methods.sh

    # extract-dto.sh + extract-feign.sh
    log_info "Running extract-dto.sh..."
    bash extract-dto.sh
    log_info "Running extract-feign.sh..."
    bash extract-feign.sh

    # gen-test-spec.sh (generates JSON test spec, requires user confirmation)
    log_info "Running gen-test-spec.sh..."
    bash gen-test-spec.sh

    # Find the generated test-spec JSON
    local test_spec
    test_spec=$(find_test_spec) || {
        log_error "Failed to find generated test-spec JSON"
        return 1
    }

    local controller
    controller=$(get_controller_from_spec "$test_spec")
    log_info "Phase 1 complete: test-spec-${controller}.json generated"
    echo "$test_spec"
}

# Run Phase 2: auto-test-data
run_phase2() {
    local test_spec="$1"

    log_info "=========================================="
    log_info "PHASE 2: Generating test data"
    log_info "=========================================="

    # Find latest test-spec if not provided
    if [[ -z "$test_spec" ]]; then
        test_spec=$(find_test_spec) || {
            log_error "No test-spec JSON found. Run Phase 1 first."
            return 1
        }
    fi

    cd "$PHASE2_DIR"

    # identify-entity.sh (reads test-spec JSON)
    log_info "Running identify-entity.sh..."
    bash identify-entity.sh "$test_spec"

    # gen-insert.sh (reads test-spec JSON)
    log_info "Running gen-insert.sh..."
    bash gen-insert.sh "$test_spec"

    # execute-insert.sh (MCP execute, requires user confirmation)
    log_info "Running execute-insert.sh..."
    bash execute-insert.sh "$test_spec"

    log_info "Phase 2 complete: test data inserted via MCP"
}

# Run Phase 3: auto-test-run
run_phase3() {
    local test_spec="$1"

    log_info "=========================================="
    log_info "PHASE 3: Running tests"
    log_info "=========================================="

    # Find latest test-spec if not provided
    if [[ -z "$test_spec" ]]; then
        test_spec=$(find_test_spec) || {
            log_error "No test-spec JSON found. Run Phase 1 and Phase 2 first."
            return 1
        }
    fi

    cd "$PHASE3_DIR"

    # run-test.sh (verifies status=data_inserted, runs curl tests)
    log_info "Running run-test.sh..."
    bash run-test.sh "$test_spec"

    log_info "Phase 3 complete: tests executed, report generated"
}

# Main
main() {
    local input="$1"

    if [[ -z "$input" ]]; then
        echo "Usage: auto-test <input>"
        echo "  <input> examples:"
        echo "    SpmiCapacityBillController"
        echo "    SpmiCapacityBillController.create()"
        echo "    测试 leizhuang/feature-xxx"
        echo "    测试 432b3e3"
        exit 1
    fi

    # Ensure output directory exists
    ensure_auto_test_dir

    log_info "Starting auto-test pipeline"
    log_info "Input: $input"
    log_info "Output directory: $AUTO_TEST_DIR"

    # Check prerequisites
    if ! command -v mvn &> /dev/null; then
        log_error "Maven not found - required for auto-test"
        exit 1
    fi

    if ! command -v java &> /dev/null; then
        log_error "Java not found - required for auto-test"
        exit 1
    fi

    # Run phases in sequence
    local test_spec
    test_spec=$(run_phase1 "$input")
    run_phase2 "$test_spec"
    run_phase3 "$test_spec"

    log_info "=========================================="
    log_info "Pipeline complete!"
    log_info "=========================================="
    log_info "Test spec: $test_spec"
    log_info "Reports: ${AUTO_TEST_DIR}/test-reports/"
}

main "$@"
