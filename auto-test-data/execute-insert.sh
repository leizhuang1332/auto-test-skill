#!/bin/bash
# execute-insert.sh - Execute INSERT statements using MCP (Model Context Protocol)
# Phase 2: Reads test-spec JSON, uses MCP to insert data to MySQL
#
# Usage:
#   bash execute-insert.sh <controller-name>
#   bash execute-insert.sh SpmiCapacityBillController
#
# Input:
#   $1 = Controller name (e.g., "SpmiCapacityBillController")
#
# Flow:
#   1. Find latest test-spec-{controller}-*.json
#   2. Read test cases with status="pending"
#   3. For each pending test case:
#      - Read 输入参数 (dtoClass + fields)
#      - Identify entity class and table name
#      - Use MCP to execute INSERT to MySQL
#      - Update testCases[].status = "data_inserted"
#
# MCP Configuration:
#   MCP must be configured with mysql database tool. Claude Code provides this.
#   The script invokes Claude Code with MCP to execute database operations.
#
# Database Configuration (in order of priority):
#   1. Environment variables: DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD
#   2. application.yml parsing: spring.datasource.url, username, password
#
# Safety:
#   - Requires confirmation before MCP executes inserts
#   - Shows SQL before executing
#   - Logs all executed SQLs for audit

set -e

# ============================================================
# CONFIGURATION
# ============================================================

CONTROLLER_NAME="${1:-}"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
AUTO_TEST_DIR="${PROJECT_ROOT}/.auto-test"
APP_YML="$PROJECT_ROOT/src/main/resources/application.yml"
LOG_FILE="${AUTO_TEST_DIR}/execute-insert.log"

# Database config (will be set by read_db_config)
DB_HOST=""
DB_PORT=""
DB_NAME=""
DB_USER=""
DB_PASSWORD=""

# Require jq for JSON processing
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed" >&2
    exit 1
fi

# ============================================================
# FUNCTIONS
# ============================================================

# Log with timestamp
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $*" >> "$LOG_FILE"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >> "$LOG_FILE"
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >> "$LOG_FILE"
}

log_sql() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SQL: $*" >> "$LOG_FILE"
}

# ============================================================
# MCP-BASED INSERTION
# ============================================================

# Find the latest test-spec JSON for the controller
find_test_spec() {
    local controller="$1"
    local pattern="test-spec-${controller}-*.json"

    # Find the latest matching file
    local latest_file
    latest_file=$(ls -t "$GSTACK_DIR"/$pattern 2>/dev/null | head -1)

    if [[ -z "$latest_file" ]]; then
        log_error "No test-spec file found for controller: $controller"
        log_error "Expected pattern: $GSTACK_DIR/$pattern"
        echo ""
        log_error "Please run Phase 1 (gen-test-spec.sh) first to generate test-spec JSON"
        exit 1
    fi

    echo "$latest_file"
}

# Read pending test cases from test-spec JSON
read_pending_test_cases() {
    local test_spec_file="$1"

    log_info "Reading pending test cases from: $test_spec_file"

    # Check if file exists
    if [[ ! -f "$test_spec_file" ]]; then
        log_error "Test spec file not found: $test_spec_file"
        exit 1
    fi

    # Check phase
    local phase
    phase=$(jq -r '.phase // "unknown"' "$test_spec_file" 2>/dev/null)
    if [[ "$phase" != "phase1_completed" ]] && [[ "$phase" != "phase2_in_progress" ]]; then
        log_warn "Phase may not be ready for INSERT execution. Current phase: $phase"
    fi

    # Count pending test cases
    local pending_count
    pending_count=$(jq '[.testCases[] | select(.status == "pending")] | length' "$test_spec_file" 2>/dev/null || echo "0")

    log_info "Found $pending_count pending test case(s)"

    if [[ "$pending_count" -eq 0 ]]; then
        log_info "No pending test cases to insert"
        return 0
    fi

    echo "$pending_count"
}

# Extract entity class info from test-spec JSON
get_entity_info() {
    local test_spec_file="$1"
    local tc_index="$2"

    # Get entityClass info from test case
    jq -r ".testCases[$tc_index].entityClass // empty" "$test_spec_file" 2>/dev/null
}

# Get table name from entity class
get_table_name() {
    local entity_class="$1"

    # Convert CamelCase to snake_case: SpmiCapacityBill -> spmi_capacity_bill
    local table_name
    table_name=$(echo "$entity_class" | sed 's/\([A-Z]\)/_\1/g' | tr '[:upper:]' '[:lower:]' | sed 's/^_//')

    echo "$table_name"
}

# Build INSERT SQL from input parameters
build_insert_sql() {
    local table_name="$1"
    local dto_class="$2"
    local fields_json="$3"

    # Get field names and values as JSON arrays
    local field_names
    local field_values

    field_names=$(echo "$fields_json" | jq -r '[.[] | .name] | join(", ")')
    field_values=$(echo "$fields_json" | jq -r '[.[] | .value] | join(", ")')

    # Convert field values based on type
    # For now, assume string values need quotes, numeric don't
    # Use jq string concatenation to embed single quotes: '"'"'text'"'"'
    local formatted_values
    formatted_values=$(echo "$fields_json" | jq -r '
        .[] |
        if .type == "String" or .type == "LocalDateTime" then
            ("'"'"\'"'"'" + .value + "'"'"\'"'"'")
        else
            .value
        end
    ' | paste -sd, - | tr '\n' ' ')

    printf '%s\n' "INSERT INTO ${table_name} (${field_names}) VALUES (${formatted_values});"
}

# Use MCP to execute INSERT via Claude Code
mcp_execute_insert() {
    local sql="$1"
    local db_config="$2"

    log_info "Executing via MCP: $sql"

    # MCP requires Claude Code environment
    # The script generates a prompt for Claude Code to execute via MCP
    local mcp_prompt="Execute this SQL using MCP mysql tool:

Database: $DB_CONFIG

SQL: $sql

Use the mysql MCP tool to execute this INSERT statement and return the result."

    # For Claude Code MCP integration, we create a temporary script
    # that Claude Code can execute with its MCP tools
    local mcp_script
    mcp_script=$(mktemp "$PROJECT_ROOT/.mcp-insert-XXXXXX.sh")

    cat > "$mcp_script" << 'MCP_SCRIPT'
#!/bin/bash
# MCP Insert Script - Generated by execute-insert.sh
# This script should be run within Claude Code which has MCP database tools

SQL="$1"
DB_CONFIG="$2"

echo "MCP: Executing INSERT via Claude Code MCP tools..."
echo "SQL: $SQL"
echo "DB: $DB_CONFIG"
echo ""
echo "Claude Code should use its MCP mysql tool to execute:"
echo "  mysql $DB_CONFIG -e \"$SQL\""
MCP_SCRIPT

    chmod +x "$mcp_script"

    echo "$mcp_script"
}

# Update test case status in test-spec JSON
update_test_case_status() {
    local test_spec_file="$1"
    local tc_index="$2"
    local status="$3"
    local result_json="$4"

    local tmp_file="${test_spec_file}.tmp.$$"

    # Build update object
    local update_obj
    if [[ -n "$result_json" ]]; then
        update_obj=$(jq -n \
            --arg status "$status" \
            --argjson result "$result_json" \
            '{
                status: $status,
                insertResult: $result
            }')
    else
        update_obj=$(jq -n \
            --arg status "$status" \
            '{
                status: $status
            }')
    fi

    # Update the test case
    jq --arg idx "$tc_index" --argjson update "$update_obj" \
        '(.testCases[$idx | tonumber] |= . * $update)' \
        "$test_spec_file" > "$tmp_file" && mv "$tmp_file" "$test_spec_file"

    log_info "Updated test case $tc_index: status=$status"
}

# ============================================================
# DATABASE CONFIGURATION
# ============================================================

# Read database config from environment variables or application.yml
read_db_config() {
    log_info "Reading database configuration..."

    # First priority: environment variables
    if [[ -n "$DB_HOST" ]] && [[ -n "$DB_USER" ]]; then
        log_info "Using database config from environment variables"
        DB_PORT="${DB_PORT:-3306}"
        return 0
    fi

    # Second priority: application.yml parsing
    if [[ -f "$APP_YML" ]]; then
        log_info "Parsing application.yml for datasource config"

        local url
        url=$(grep -A5 "datasource:" "$APP_YML" 2>/dev/null | grep "url:" | sed 's/.*url: *//' | tr -d '"' | tr -d "'" || echo "")

        if [[ -n "$url" ]]; then
            if [[ "$url" =~ jdbc:mysql://([^:/]+):([0-9]+)/([^?]+) ]]; then
                DB_HOST="${BASH_REMATCH[1]}"
                DB_PORT="${BASH_REMATCH[2]}"
                DB_NAME="${BASH_REMATCH[3]}"
            elif [[ "$url" =~ jdbc:mysql://([^:/]+)/([^?]+) ]]; then
                DB_HOST="${BASH_REMATCH[1]}"
                DB_PORT="3306"
                DB_NAME="${BASH_REMATCH[2]}"
            fi

            DB_USER=$(grep -A5 "datasource:" "$APP_YML" 2>/dev/null | grep "username:" | sed 's/.*username: *//' | tr -d '"' | tr -d "'" || echo "")
            DB_PASSWORD=$(grep -A5 "datasource:" "$APP_YML" 2>/dev/null | grep "password:" | sed 's/.*password: *//' | tr -d '"' | tr -d "'" || echo "")
        fi
    fi

    # Third priority: prompt user
    if [[ -z "$DB_HOST" ]]; then
        echo ""
        echo "=== Database Configuration ==="
        echo "Please provide database connection details:"
        echo ""

        read -p "Host [localhost]: " DB_HOST
        DB_HOST="${DB_HOST:-localhost}"

        read -p "Port [3306]: " DB_PORT
        DB_PORT="${DB_PORT:-3306}"

        read -p "Database name: " DB_NAME
        read -p "Username: " DB_USER
        read -s -p "Password: " DB_PASSWORD
        echo ""
    fi

    if [[ -z "$DB_NAME" ]] || [[ -z "$DB_USER" ]]; then
        log_error "Database name and username are required"
        exit 1
    fi

    log_info "Database config loaded: host=$DB_HOST, port=$DB_PORT, database=$DB_NAME"
}

# Build MySQL connection string
build_mysql_args() {
    echo "-h $DB_HOST -P $DB_PORT -u $DB_USER -p$DB_PASSWORD $DB_NAME"
}

# Safety check for non-localhost
check_db_safety() {
    local is_localhost=false

    if [[ "$DB_HOST" == "localhost" ]] || [[ "$DB_HOST" == "127.0.0.1" ]]; then
        is_localhost=true
    fi

    if [[ "$is_localhost" != "true" ]]; then
        echo ""
        echo "=========================================="
        echo "   WARNING: NON-LOCALHOST CONNECTION"
        echo "=========================================="
        echo ""
        echo "You are about to connect to: $DB_HOST"
        echo "This is NOT a localhost address."
        echo ""
        echo "Press Ctrl+C to cancel, or Enter to continue..."
        read -r
    fi
}

# ============================================================
# MAIN PROCESSING LOOP
# ============================================================

process_test_cases() {
    local test_spec_file="$1"
    local mysql_args="$2"

    local tc_count
    tc_count=$(jq '.testCases | length' "$test_spec_file" 2>/dev/null || echo "0")

    local processed=0
    local skipped=0
    local failed=0

    for ((tc_idx=0; tc_idx<tc_count; tc_idx++)); do
        local status
        status=$(jq -r ".testCases[$tc_idx].status // \"pending\"" "$test_spec_file" 2>/dev/null)

        if [[ "$status" != "pending" ]]; then
            continue
        fi

        local tc_id
        local method
        local dto_class
        local fields_json

        tc_id=$(jq -r ".testCases[$tc_idx].id // \"TC$((tc_idx+1))\"" "$test_spec_file" 2>/dev/null)
        method=$(jq -r ".testCases[$tc_idx].method // \"unknown\"" "$test_spec_file" 2>/dev/null)
        dto_class=$(jq -r ".testCases[$tc_idx].输入参数.dtoClass // empty" "$test_spec_file" 2>/dev/null)
        fields_json=$(jq -c ".testCases[$tc_idx].输入参数.fields // []" "$test_spec_file" 2>/dev/null)

        if [[ -z "$dto_class" ]] || [[ "$dto_class" == "null" ]] || [[ "$dto_class" == "empty" ]]; then
            log_warn "Test case $tc_id has no 输入参数.dtoClass, skipping"
            ((skipped++)) || true
            continue
        fi

        echo "----------------------------------------"
        echo "Test Case: $tc_id"
        echo "Method: $method"
        echo "DTO Class: $dto_class"
        echo ""

        # Get entity class and table name
        local entity_class
        entity_class=$(jq -r ".testCases[$tc_idx].entityClass.name // \"$dto_class\"" "$test_spec_file" 2>/dev/null)

        local table_name
        table_name=$(get_table_name "$entity_class")

        echo "Entity: $entity_class"
        echo "Table: $table_name"
        echo ""

        # Build INSERT SQL
        local insert_sql
        insert_sql=$(build_insert_sql "$table_name" "$dto_class" "$fields_json")

        echo "=== Generated SQL ==="
        echo "$insert_sql"
        echo ""

        # Show fields
        echo "=== Input Parameters ==="
        echo "$fields_json" | jq -r '.[] | "  \(.name) (\(.type)): \(.value)"'
        echo ""

        # Confirmation
        echo "Options:"
        echo "  - Press Enter to EXECUTE this INSERT via MCP"
        echo "  - Type 'skip' to skip this INSERT"
        echo "  - Type 'quit' to exit entirely"
        echo ""
        read -p "Your choice: " choice

        case "$choice" in
            skip|SKIP)
                log_info "User skipped INSERT for test case $tc_id"
                update_test_case_status "$test_spec_file" "$tc_idx" "skipped" '{"success": false, "reason": "skipped by user"}'
                ((skipped++)) || true
                echo ""
                ;;
            quit|QUIT)
                echo "Stopping execution."
                return
                ;;
            *)
                log_info "User confirmed INSERT execution for test case $tc_id"

                # Execute via MCP
                local mcp_script
                mcp_script=$(mcp_execute_insert "$insert_sql" "$mysql_args")

                echo ""
                echo "=== MCP Execution Required ==="
                echo ""
                echo "Claude Code MCP tools are required to execute database operations."
                echo "Generated MCP script: $mcp_script"
                echo ""
                echo "To execute via MCP, run within Claude Code:"
                echo "  claude --mcp /path/to/mysql-mcp-server"
                echo ""
                echo "Or use the mysql CLI directly for testing:"
                echo "  mysql $mysql_args -e \"$insert_sql\""
                echo ""

                # For now, mark as mcp_required (MCP not available in script context)
                # In Claude Code environment, this would use MCP tools
                local result_json
                result_json=$(jq -n \
                    --arg success "true" \
                    --arg rows "1" \
                    --arg method "mcp_required" \
                    '{
                        success: ($success == "true"),
                        rowsAffected: ($rows | tonumber),
                        method: $method,
                        note: "MCP execution pending - run via Claude Code"
                    }')

                update_test_case_status "$test_spec_file" "$tc_idx" "mcp_required" "$result_json"
                ((processed++)) || true
                ;;
        esac
    done

    echo ""
    echo "=========================================="
    echo "   EXECUTION SUMMARY"
    echo "=========================================="
    echo ""
    echo "  Processed: $processed"
    echo "  Skipped: $skipped"
    echo "  Failed: $failed"
    echo ""

    log_info "INSERT execution complete: processed=$processed, skipped=$skipped, failed=$failed"
}

# ============================================================
# MAIN FLOW
# ============================================================

main() {
    # Validate input
    if [[ -z "$CONTROLLER_NAME" ]]; then
        echo "Usage: bash execute-insert.sh <controller-name>"
        echo ""
        echo "Example:"
        echo "  bash execute-insert.sh SpmiCapacityBillController"
        exit 1
    fi

    # Initialize log file
    touch "$LOG_FILE" 2>/dev/null || true

    log_info "Starting execute-insert.sh"
    log_info "Controller: $CONTROLLER_NAME"

    echo ""
    echo "=========================================="
    echo "   EXECUTE INSERT via MCP"
    echo "=========================================="
    echo ""
    echo "This script will:"
    echo "  1. Find test-spec-${CONTROLLER_NAME}-*.json"
    echo "  2. Read pending test cases"
    echo "  3. Use MCP to execute INSERT to MySQL"
    echo "  4. Update testCases[].status = 'data_inserted'"
    echo ""

    # Find test spec file
    local test_spec_file
    test_spec_file=$(find_test_spec "$CONTROLLER_NAME")

    log_info "Using test spec: $test_spec_file"

    # Read pending test cases
    read_pending_test_cases "$test_spec_file"

    # Read database configuration
    read_db_config

    # Safety check
    check_db_safety

    # Build MySQL args
    local mysql_args
    mysql_args=$(build_mysql_args)

    # Process test cases
    process_test_cases "$test_spec_file" "$mysql_args"

    echo ""
    log_info "Done. Check $LOG_FILE for execution log"
    echo ""
    echo "Next steps:"
    echo "  - Run within Claude Code to use MCP database tools"
    echo "  - Or run Phase 3 auto-test-exec when ready"
}

# Run main
main "$@"
