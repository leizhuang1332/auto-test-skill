#!/bin/bash
set -e

# Configuration
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
SKILL_DIR="$HOME/.claude/skills/auto-test-run"
BACKUP_DIR="${PROJECT_ROOT}/.auto-test/backups"
FIX_LOG_DIR="${PROJECT_ROOT}/.auto-test/test-reports"
MAX_DIFF_LINES=5

# Auto-fix only allowed on Service layer files
SERVICE_LAYER_PATTERN="src/main/java/com/yl/spmibill/capacity/service"

# Logging functions
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

# Ensure backup directory exists
ensure_backup_dir() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        log_info "Created backup directory: $BACKUP_DIR"
    fi
}

# Parse stack trace to extract file:line
parse_stack_trace() {
    local error_log="$1"

    # Look for "at com.yl.spmibill.capacity.service." pattern
    local match
    match=$(grep -oE "at [a-zA-Z0-9_.]+\.service\.[a-zA-Z0-9_.]+\([a-zA-Z0-9_]+\.java:[0-9]+\)" "$error_log" 2>/dev/null | head -1)

    if [[ -z "$match" ]]; then
        # Try generic Java pattern
        match=$(grep -oE "at [a-zA-Z0-9_.]+\([a-zA-Z0-9_]+\.java:[0-9]+\)" "$error_log" 2>/dev/null | head -1)
    fi

    if [[ -z "$match" ]]; then
        log_error "Could not parse stack trace"
        return 1
    fi

    # Extract file and line: "at FooService.bar(FooService.java:42)"
    local file=$(echo "$match" | grep -oE "[a-zA-Z0-9_]+\.java")
    local line=$(echo "$match" | grep -oE ":[0-9]+\)" | tr -d ':)')

    echo "${file}:${line}"
    return 0
}

# Check if file is in service layer
is_service_layer() {
    local file="$1"
    echo "$file" | grep -q "service" && return 0
    return 1
}

# Compute diff between original and fixed content
compute_diff() {
    local original="$1"
    local fixed="$2"

    # Count non-empty lines that differ
    local diff_lines
    diff_lines=$(diff -u <(echo "$original") <(echo "$fixed") 2>/dev/null | grep -c "^[+-]" || echo "0")

    echo "$diff_lines"
}

# Compute diff lines (net changes)
compute_diff_lines() {
    local original="$1"
    local fixed="$2"

    local diff_output
    diff_output=$(diff -u <(echo "$original") <(echo "$fixed") 2>/dev/null || true)

    local added=$(echo "$diff_output" | grep -c "^+" || echo "0")
    local removed=$(echo "$diff_output" | grep -c "^-" || echo "0")

    # Net change is the larger of added/removed for simple line counting
    local net_diff=$((added > removed ? added : removed))

    echo "$net_diff"
}

# Backup file before modification
backup_file() {
    local file_path="$1"
    local timestamp=$(date '+%Y%m%d_%H%M%S')

    ensure_backup_dir

    local backup_path="${BACKUP_DIR}/$(basename "$file_path")_${timestamp}.bak"
    cp "$file_path" "$backup_path"

    log_info "Backed up to: $backup_path"
    echo "$backup_path"
}

# Show fix preview to user
show_fix_preview() {
    local file="$1"
    local line="$2"
    local original="$3"
    local fixed="$4"
    local diff_count="$5"

    echo ""
    echo "=========================================="
    echo "   AUTO-FIX PREVIEW"
    echo "=========================================="
    echo ""
    echo "File: $file"
    echo "Line: $line"
    echo "Diff: $diff_count lines (threshold: $MAX_DIFF_LINES)"
    echo ""
    echo "--- Original ---"
    echo "$original"
    echo ""
    echo "--- Fixed ---"
    echo "$fixed"
    echo ""
    echo "=========================================="
    echo ""
}

# Ask user for fix confirmation
ask_fix_confirmation() {
    echo "Apply this fix? (yes/no)"
    echo "  yes - apply fix and re-run test"
    echo "  no  - skip fix, continue to next test"
    echo ""
    read -p "Choice: " choice
    echo "$choice"
}

# Apply fix to file
apply_fix() {
    local file_path="$1"
    local fixed_content="$2"

    # Backup first
    backup_file "$file_path" > /dev/null

    # Write fixed content
    echo "$fixed_content" > "$file_path"

    log_info "Fix applied to: $file_path"
}

# Build AI prompt for fix analysis
build_ai_fix_prompt() {
    local file="$1"
    local line="$2"
    local error_msg="$3"
    local context_lines=20

    # Read source file around the error line
    local file_path="$PROJECT_ROOT/$file"
    local source_around_error
    source_around_error=$(sed -n "$((line > 5 ? line - 5 : 1)),$((line + 10))p" "$file_path" 2>/dev/null)

    cat << PROMPT_EOF
## Task: Fix Bug in Service Layer

A test failed with the following error:

### Error
\`\`\`
$error_msg
\`\`\`

### Source File: $file (around line $line)
\`\`\`java
$source_around_error
\`\`\`

### Fix Requirements
1. Fix must be in Service layer code (not Controller/transaction)
2. Diff must be ≤5 lines
3. Only make minimal changes to fix the immediate bug
4. Do NOT refactor or rewrite entire methods

### Common Fix Patterns
- NPE: Add null check (1-2 lines)
  \`\`\`java
  // Before
  if (bill.getStatus() != null)

  // After
  if (bill != null && bill.getStatus() != null)
  \`\`\`
- Missing field: Add assignment (1-3 lines)
- Boundary: Adjust condition (1-2 lines)

### Output Format
Return ONLY the fixed source code in a markdown code block.
Show minimal diff - only changed lines.
PROMPT_EOF
}

# Log fix to fixes.jsonl
log_fix() {
    local test_case_id="$1"
    local file="$2"
    local line="$3"
    local issue="$4"
    local diff_lines="$5"
    local status="$6"
    local test_result_after="$7"

    # Ensure log directory exists
    if [[ ! -d "$FIX_LOG_DIR" ]]; then
        mkdir -p "$FIX_LOG_DIR"
    fi

    local fix_entry=$(jq -n \
        --arg tc "$test_case_id" \
        --arg f "$file" \
        --argjson ln "$line" \
        --arg iss "$issue" \
        --argjson dl "$diff_lines" \
        --arg st "$status" \
        --arg tr "$test_result_after" \
        '{
          testCaseId: $tc,
          file: $f,
          lineNumber: $ln,
          issue: $iss,
          diffLines: $dl,
          status: $st,
          testResultAfterFix: $tr
        }')

    # Append to fixes log
    echo "$fix_entry" | jq -c '.' >> "${FIX_LOG_DIR}/fixes.jsonl" 2>/dev/null || true
}

# Extract original lines from source
get_original_lines() {
    local file="$1"
    local line="$2"
    local num_lines="${3:-1}"

    local file_path="$PROJECT_ROOT/$file"
    if [[ ! -f "$file_path" ]]; then
        # Try alternative path
        file_path="$PROJECT_ROOT/src/main/java/com/yl/spmibill/capacity/$file"
    fi

    if [[ -f "$file_path" ]]; then
        sed -n "${line},$((line + num_lines - 1))p" "$file_path" 2>/dev/null
    else
        echo ""
    fi
}

# Apply fix by replacing specific lines
apply_line_fix() {
    local file="$1"
    local start_line="$2"
    local end_line="$3"
    local new_content="$4"

    local file_path="$PROJECT_ROOT/$file"
    if [[ ! -f "$file_path" ]]; then
        file_path="$PROJECT_ROOT/src/main/java/com/yl/spmibill/capacity/$file"
    fi

    if [[ ! -f "$file_path" ]]; then
        log_error "File not found: $file"
        return 1
    fi

    # Backup first
    backup_file "$file_path" > /dev/null

    # Create temp file with fix applied
    local temp_file="/tmp/fix_apply_$$.tmp"

    # Get lines before the fix
    if [[ $start_line -gt 1 ]]; then
        head -n $((start_line - 1)) "$file_path" > "$temp_file"
    fi

    # Add new content
    echo "$new_content" >> "$temp_file"

    # Add lines after the fix
    tail -n +$((end_line + 1)) "$file_path" >> "$temp_file" 2>/dev/null || true

    # Replace original with fixed
    mv "$temp_file" "$file_path"

    log_info "Fix applied to: $file_path (lines $start_line-$end_line)"
}

# Main function
main() {
    local error_log="${1:-/tmp/test_error.log}"
    local test_case_id="${2:-unknown}"

    log_info "Starting auto-fix.sh for test case: $test_case_id"
    log_info "Error log: $error_log"

    # 1. Parse stack trace
    local parsed
    parsed=$(parse_stack_trace "$error_log") || {
        log_error "Failed to parse stack trace"
        echo "skipped"
        return 1
    }

    local file=$(echo "$parsed" | cut -d: -f1)
    local line=$(echo "$parsed" | cut -d: -f2)

    log_info "Error location: $file:$line"

    # 2. Check if service layer
    if ! is_service_layer "$file"; then
        log_info "Not a Service layer file - skipping auto-fix"
        log_fix "$test_case_id" "$file" "$line" "Non-service layer" 0 "skipped" "N/A"
        echo "skipped"
        return 0
    fi

    # 3. Read context around error
    local file_path="$PROJECT_ROOT/src/main/java/com/yl/spmibill/capacity/$file"
    if [[ ! -f "$file_path" ]]; then
        file_path="$PROJECT_ROOT/$file"
    fi

    if [[ ! -f "$file_path" ]]; then
        log_error "Source file not found: $file"
        echo "error"
        return 1
    fi

    local error_msg=$(cat "$error_log")

    # 4. Build AI prompt and get fix (in real flow, AI generates this)
    # The script outputs "ai_fix_needed" to indicate AI assistance is required
    local ai_prompt
    ai_prompt=$(build_ai_fix_prompt "$file" "$line" "$error_msg")

    log_info "AI prompt generated - requires Claude Code tool calling"
    echo "ai_fix_needed"
    echo "$ai_prompt"
}

# Run main if called directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
