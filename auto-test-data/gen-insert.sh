#!/bin/bash
# gen-insert.sh - Generate INSERT SQL templates from identified Entity classes
# Phase 2: Reads from test-spec-{controller}.json (NOT old state.json)
#
# Usage:
#   bash gen-insert.sh [controller-name]
#
# Input:
#   $1 = controller name (e.g., "SpmiCapacityBillController")
#       If not provided, lists available controllers with test-spec files
#
# Flow:
#   1. Find latest test-spec-{controller}-*.json file
#   2. Read entityClasses[] from testCases[].entityClass
#   3. For each Entity class, read Java source and extract field names
#   4. Generate INSERT SQL template with #{fieldName} placeholders
#   5. Display markdown preview of all templates
#   6. Write insertTemplate back to test-spec JSON
#
# INSERT Template Format:
#   INSERT INTO {tableName} ({columns}) VALUES ({placeholders});
#
# Placeholder Rules:
#   - Long/Integer: #{fieldName}
#   - String: #{fieldName}
#   - LocalDateTime: NOW()
#   - Date: NOW()
#   - Enum: '#{fieldName}' (user must select value)

set -e

# ============================================================
# CONFIGURATION
# ============================================================

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
PROJECT_DIR="${PROJECT_ROOT}/.auto-test"
JAVA_SOURCE_ROOT="$PROJECT_ROOT/src/main/java"

# Controller name from argument
CONTROLLER_NAME="${1:-}"

# Will be set after finding test-spec file
TEST_SPEC_FILE=""

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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2
}

# Check test-spec file exists
check_test_spec_file() {
    if [[ ! -f "$TEST_SPEC_FILE" ]]; then
        log_error "Test spec file not found: $TEST_SPEC_FILE"
        echo "Please run Phase 1 auto-test-gen and Phase 2 identify-entity.sh first"
        exit 1
    fi
}

# Find latest test-spec-{controller}-*.json file
find_test_spec() {
    local controller="$1"
    local pattern="$PROJECT_DIR/test-spec-${controller}-"*.json

    local files=( $pattern )

    if [[ ${#files[@]} -eq 0 ]]; then
        log_error "No test-spec file found for controller: $controller"
        echo "Please run Phase 1 auto-test-gen first to create test-spec JSON"
        return 1
    fi

    # Return the most recent file
    echo "${files[-1]}"
    return 0
}

# List available controllers with test-spec files
list_available_controllers() {
    local specs=( "$PROJECT_DIR"/test-spec-*-*.json )

    if [[ ${#specs[@]} -eq 0 ]]; then
        echo "No test-spec files found in $PROJECT_DIR"
        echo "Please run Phase 1 auto-test-gen first"
        return
    fi

    echo "Available controllers with test-spec files:"
    echo ""

    for spec in "${specs[@]}"; do
        local filename
        filename=$(basename "$spec")
        # Extract controller name: test-spec-{ControllerName}-timestamp.json
        local controller="${filename#test-spec-}"
        controller="${controller%-*}"

        local has_entity
        has_entity=$(jq '[.testCases[].entityClass | select(. != null)] | length' "$spec" 2>/dev/null || echo "0")

        echo "  - $controller (entities: $has_entity)"
    done
}

# Count test cases with entityClass
count_test_cases_with_entity() {
    jq '[.testCases[] | select(.entityClass != null)] | length' "$TEST_SPEC_FILE" 2>/dev/null || echo "0"
}

# Count entity classes across all test cases
count_entity_classes() {
    jq '[.testCases[].entityClass | select(. != null)] | length' "$TEST_SPEC_FILE" 2>/dev/null || echo "0"
}

# Get all unique entity classes as JSON array (unique by name and path)
get_all_entity_classes() {
    jq '[.testCases[].entityClass | select(. != null) | {name, path, tableName, identificationMethod, confidence}] | unique_by(.name)' "$TEST_SPEC_FILE" 2>/dev/null || echo "[]"
}

# Get entity class by index
get_entity_class() {
    local index="$1"
    local all_entities
    all_entities=$(get_all_entity_classes)
    echo "$all_entities" | jq ".[$index]" 2>/dev/null || echo "{}"
}

# Extract field from entity class JSON
entity_field() {
    local entity_json="$1"
    local field="$2"
    echo "$entity_json" | jq -r "$field // empty" 2>/dev/null || echo ""
}

# ============================================================
# CAMELCASE TO SNAKE_CASE CONVERSION
# ============================================================

# Convert camelCase to snake_case
# Examples:
#   billNo -> bill_no
#   carrierId -> carrier_id
#   createTime -> create_time
#   ID -> id (special case)
to_snake_case() {
    local input="$1"

    # Special case: ID at the end -> id
    if [[ "$input" == "ID" ]]; then
        echo "id"
        return
    fi

    # Special case: ID in the middle (e.g., billID) -> bill_id
    # But handle common cases like billNo, carrierId first

    # Handle common patterns
    # First, handle trailing ID (e.g., carrierID -> carrier_id)
    input=$(echo "$input" | sed 's/\([A-Z]\)ID$/\1Id/')

    # General camelCase to snake_case conversion
    # Insert underscore before uppercase letters, then lowercase
    echo "$input" | sed 's/\([A-Z]\)/_\L\1/g' | sed 's/^_//' | tr '[:upper:]' '[:lower:]'
}

# ============================================================
# FIELD EXTRACTION FROM JAVA SOURCE
# ============================================================

# Extract field name and type from a Java source file
# Returns: "type|fieldName" or empty if not found
extract_field_from_line() {
    local line="$1"

    # Match: private Type fieldName;
    # Also handle: private Type fieldName = value;
    if [[ "$line" =~ private[[:space:]]+([A-Za-z<>]+(?:<[^>]+>)?)[[:space:]]+([a-z][A-Za-z]*)\ ?(=|$) ]]; then
        local field_type="${BASH_REMATCH[1]}"
        local field_name="${BASH_REMATCH[2]}"
        echo "$field_type|$field_name"
        return 0
    fi

    return 1
}

# Read all fields from an Entity Java source file
# Returns: JSON array of {type, name, columnName}
read_entity_fields() {
    local entity_path="$1"

    if [[ ! -f "$entity_path" ]]; then
        log_warn "Entity file not found: $entity_path"
        echo "[]"
        return
    fi

    local fields="[]"

    # Read file and process line by line
    while IFS= read -r line; do
        # Skip comments
        if [[ "$line" =~ ^[[:space:]]*// ]]; then
            continue
        fi

        # Extract field
        local result
        result=$(extract_field_from_line "$line" 2>/dev/null) || continue

        if [[ -z "$result" ]]; then
            continue
        fi

        IFS='|' read -r field_type field_name <<< "$result"

        # Skip serialVersionUID
        if [[ "$field_name" == "serialVersionUID" ]]; then
            continue
        fi

        # Convert field name to column name (snake_case)
        local column_name
        column_name=$(to_snake_case "$field_name")

        # Build field JSON
        local field_json
        field_json=$(jq -n \
            --arg type "$field_type" \
            --arg name "$field_name" \
            --arg column "$column_name" \
            '{type: $type, name: $name, columnName: $column}')

        fields=$(echo "$fields" | jq ". + [$field_json]")
    done < "$entity_path"

    echo "$fields"
}

# ============================================================
# DETERMINE VALUE PLACEHOLDER
# ============================================================

# Determine the value placeholder for a given Java field type
# Returns: placeholder string (e.g., "#{fieldName}", "NOW()", "'#{fieldName}'")
get_value_placeholder() {
    local field_type="$1"
    local field_name="$2"

    # Normalize type (remove generics, trim)
    local normalized_type="${field_type%%<*}"  # Remove generic part
    normalized_type=$(echo "$normalized_type" | xargs)  # Trim whitespace

    case "$normalized_type" in
        "long"|"Long"|"int"|"Integer"|"short"|"Short"|"byte"|"Byte"|"double"|"Double"|"float"|"Float"|"BigDecimal")
            echo "#{${field_name}}"
            ;;
        "String"|"CharSequence"|"Character")
            echo "#{${field_name}}"
            ;;
        "LocalDateTime"|"LocalDate"|"Instant"|"Timestamp"|"Date")
            echo "NOW()"
            ;;
        "boolean"|"Boolean")
            echo "#{${field_name}}"
            ;;
        "LocalTime")
            echo "NOW()"
            ;;
        *)
            # For enums and unknown types, use quoted placeholder
            echo "'#{${field_name}}'"
            ;;
    esac
}

# ============================================================
# GENERATE INSERT TEMPLATE FOR ONE ENTITY
# ============================================================

# Generate INSERT SQL template for a single Entity
# Returns: SQL template string
generate_insert_template() {
    local entity_json="$1"

    local entity_name
    local entity_path
    local table_name

    entity_name=$(entity_field "$entity_json" ".name")
    entity_path=$(entity_field "$entity_json" ".path")
    table_name=$(entity_field "$entity_json" ".tableName")

    log_info "Generating INSERT template for: $entity_name"
    log_info "  Entity path: $entity_path"
    log_info "  Table name: $table_name"

    # Read fields from Entity source
    local fields_json
    fields_json=$(read_entity_fields "$entity_path")

    local field_count
    field_count=$(echo "$fields_json" | jq length)

    if [[ "$field_count" -eq 0 ]]; then
        log_warn "No fields found in $entity_path"
        echo ""
        return
    fi

    # Build column list and values list
    local columns=""
    local values=""
    local first=true

    for ((i=0; i<field_count; i++)); do
        local field
        field=$(echo "$fields_json" | jq ".[$i]")

        local field_type
        local field_name
        local column_name

        field_type=$(echo "$field" | jq -r '.type')
        field_name=$(echo "$field" | jq -r '.name')
        column_name=$(echo "$field" | jq -r '.columnName')

        local placeholder
        placeholder=$(get_value_placeholder "$field_type" "$field_name")

        if [[ "$first" == "true" ]]; then
            first=false
        else
            columns+=", "
            values+=", "
        fi

        columns+="$column_name"
        values+="$placeholder"
    done

    # Build INSERT template
    local template="INSERT INTO $table_name ($columns) VALUES ($values);"

    echo "$template"
}

# ============================================================
# MARKDOWN PREVIEW
# ============================================================

# Display markdown preview of all INSERT templates
display_markdown_preview() {
    local all_entities
    all_entities=$(get_all_entity_classes)

    local entity_count
    entity_count=$(count_entity_classes)

    if [[ "$entity_count" -eq 0 ]]; then
        echo ""
        echo "## INSERT Templates"
        echo ""
        echo "*No Entity classes found. Please run identify-entity.sh first.*"
        echo ""
        return
    fi

    echo ""
    echo "## INSERT Templates"
    echo ""
    echo "Generated from $entity_count Entity class(es)"
    echo ""

    local idx=0
    local tc_count
    tc_count=$(jq '.testCases | length' "$TEST_SPEC_FILE" 2>/dev/null || echo "0")

    for ((tc_idx=0; tc_idx<tc_count; tc_idx++)); do
        local entity_class_json
        entity_class_json=$(jq ".testCases[$tc_idx].entityClass // null" "$TEST_SPEC_FILE" 2>/dev/null)

        if [[ "$entity_class_json" == "null" ]] || [[ -z "$entity_class_json" ]]; then
            continue
        fi

        local controller
        local method
        controller=$(jq -r ".testCases[$tc_idx].controller" "$TEST_SPEC_FILE" 2>/dev/null)
        method=$(jq -r ".testCases[$tc_idx].method" "$TEST_SPEC_FILE" 2>/dev/null)

        echo "### Test Case: $controller.$method"
        echo ""

        local entity_name
        local table_name
        local ident_method
        local confidence

        entity_name=$(entity_field "$entity_class_json" ".name")
        table_name=$(entity_field "$entity_class_json" ".tableName")
        ident_method=$(entity_field "$entity_class_json" ".identificationMethod")
        confidence=$(entity_field "$entity_class_json" ".confidence")

        local template
        template=$(generate_insert_template "$entity_class_json")

        echo "**$((idx+1)). $entity_name**"
        echo "| Property | Value |"
        echo "|----------|-------|"
        echo "| Table | \`$table_name\` |"
        echo "| Identification | $ident_method (confidence: $confidence) |"
        echo ""
        echo '```sql'
        echo "-- $entity_name"
        echo "$template"
        echo '```'
        echo ""

        ((idx++)) || true
    done
}

# ============================================================
# STATE UPDATE
# ============================================================

# Update insertTemplate for a specific test case
update_test_case_insert_template() {
    local tc_index="$1"
    local insert_template="$2"

    local tmp_file="${TEST_SPEC_FILE}.tmp"

    # Escape the template for JSON
    local escaped_template
    escaped_template=$(echo "$insert_template" | jq -Rs '.')

    # Use jq to update the specific test case's insertTemplate field
    jq ".[\"testCases\"][$tc_index].insertTemplate = $escaped_template | .[\"testCases\"][$tc_index].insertStatus = \"pending\"" "$TEST_SPEC_FILE" > "$tmp_file" && mv "$tmp_file" "$TEST_SPEC_FILE"
}

# Main function to update all test case INSERT templates
update_all_insert_templates() {
    local tc_count
    tc_count=$(jq '.testCases | length' "$TEST_SPEC_FILE" 2>/dev/null || echo "0")

    local updated=0

    for ((tc_idx=0; tc_idx<tc_count; tc_idx++)); do
        local entity_class_json
        entity_class_json=$(jq ".testCases[$tc_idx].entityClass // null" "$TEST_SPEC_FILE" 2>/dev/null)

        if [[ "$entity_class_json" == "null" ]] || [[ -z "$entity_class_json" ]]; then
            continue
        fi

        local template
        template=$(generate_insert_template "$entity_class_json")

        if [[ -n "$template" ]]; then
            update_test_case_insert_template "$tc_idx" "$template"
            ((updated++)) || true
        fi
    done

    echo "$updated"
}

# ============================================================
# MAIN FLOW
# ============================================================

main() {
    # If no controller provided, list available options
    if [[ -z "$CONTROLLER_NAME" ]]; then
        echo ""
        echo "=========================================="
        echo "   INSERT TEMPLATE GENERATION"
        echo "=========================================="
        echo ""
        log_info "No controller specified"

        list_available_controllers
        echo ""
        echo "Usage: bash gen-insert.sh <controller-name>"
        echo "Example: bash gen-insert.sh SpmiCapacityBillController"
        exit 0
    fi

    log_info "Starting gen-insert.sh"
    log_info "Controller: $CONTROLLER_NAME"
    log_info "Project root: $PROJECT_ROOT"
    log_info "Java source: $JAVA_SOURCE_ROOT"

    # Find test-spec file for this controller
    TEST_SPEC_FILE=$(find_test_spec "$CONTROLLER_NAME")
    if [[ $? -ne 0 ]] || [[ -z "$TEST_SPEC_FILE" ]]; then
        exit 1
    fi

    log_info "Test spec file: $TEST_SPEC_FILE"

    # Check test-spec file exists
    check_test_spec_file

    # Get entity count
    local entity_count
    entity_count=$(count_entity_classes)

    if [[ "$entity_count" -eq 0 ]]; then
        log_info "No Entity classes found in test-spec"
        log_info "Please run identify-entity.sh first to identify Entity classes"
        echo ""
        echo "## INSERT Templates"
        echo ""
        echo "*No Entity classes found. Please run identify-entity.sh first.*"
        echo ""
        exit 0
    fi

    log_info "Found $entity_count Entity class(es) to process"

    echo ""
    echo "=========================================="
    echo "   INSERT TEMPLATE GENERATION"
    echo "=========================================="
    echo ""

    # Display markdown preview
    display_markdown_preview

    echo ""
    echo "=========================================="
    echo "   UPDATING TEST-SPEC"
    echo "=========================================="
    echo ""

    # Update test-spec JSON with INSERT templates
    local updated
    updated=$(update_all_insert_templates)

    echo ""
    log_info "Updated INSERT templates for $updated test case(s)"

    # Verify by reading back
    echo ""
    echo "Sample insertTemplate from first test case with template:"
    jq '[.testCases[] | select(.insertTemplate != null)] | .[0].insertTemplate' "$TEST_SPEC_FILE" 2>/dev/null | head -5 || echo "No insertTemplate found"

    echo ""
    log_info "Done. INSERT templates have been written to test-spec JSON"
    echo ""
    log_info "Next step: Review the templates above, then run execute-insert.sh to execute"
}

# Run main
main "$@"
