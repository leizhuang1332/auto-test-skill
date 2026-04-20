#!/bin/bash
# identify-entity.sh - Identify Entity classes from Phase 1 DTO classes
# Phase 2: Maps DTO classes to Entity classes using annotation scanning and naming inference
#
# Usage:
#   bash identify-entity.sh [controller-name]
#
# Input:
#   $1 = Controller name (e.g., "SpmiCapacityBillController")
#       (defaults to interactive selection if not provided)
#
# Flow:
#   1. Find latest test-spec-{controller}-*.json file
#   2. Extract dtoClasses[] from testCases[].dtoClasses
#   3. For each DTO, identify corresponding Entity
#   4. Write entityClass to each testCase in test-spec JSON
#
# Identification Priority:
#   1. Annotation Scan (@Entity, @Table) - confidence 0.95
#   2. Naming Inference (DTO → Entity) - confidence 0.7
#   3. Database Reverse (optional/future) - skip if not configured

set -e

# ============================================================
# CONFIGURATION
# ============================================================

PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
PROJECT_DIR="${PROJECT_ROOT}/.auto-test"
JAVA_SOURCE_ROOT="$PROJECT_ROOT/src/main/java"

# Default controller (can be overridden by $1)
CONTROLLER_NAME="${1:-}"

# Require jq for JSON processing
if ! command -v jq &> /dev/null; then
    echo "Error: jq is required but not installed" >&2
    exit 1
fi

# ============================================================
# FUNCTIONS
# ============================================================

# Log with timestamp (output to stderr to avoid polluting command substitution)
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >&2
}

log_error() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

log_warn() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2
}

# Find Java source files
find_java_sources() {
    if [[ -d "$JAVA_SOURCE_ROOT" ]]; then
        find "$JAVA_SOURCE_ROOT" -name "*.java" -type f 2>/dev/null
    else
        echo ""
    fi
}

# ============================================================
# TEST-SPEC FILE MANAGEMENT
# ============================================================

# Find latest test-spec-{controller}-*.json file
find_test_spec() {
    local controller="$1"

    if [[ -z "$controller" ]]; then
        log_error "Controller name is required"
        return 1
    fi

    local pattern="$PROJECT_DIR/test-spec-${controller}-"*.json
    local files
    files=( $pattern )

    if [[ ${#files[@]} -eq 0 ]] || [[ ! -f "${files[0]}" ]]; then
        log_error "No test-spec file found for controller: $controller"
        log_error "Expected pattern: $pattern"
        log_error "Please run Phase 1 auto-test-gen first to create test-spec JSON"
        return 1
    fi

    # Return the latest file (sorted by name, which includes timestamp)
    printf '%s\n' "${files[@]}" | sort -r | head -1
}

# List available controllers with test-spec files
list_available_controllers() {
    local specs
    specs=( "$PROJECT_DIR"/test-spec-*-*.json )

    if [[ ${#specs[@]} -eq 0 ]]; then
        echo "No test-spec files found in $PROJECT_DIR"
        return 1
    fi

    echo "Available controllers with test-spec files:"
    echo ""

    for spec in "${specs[@]}"; do
        local filename
        filename=$(basename "$spec")
        # Extract controller name: test-spec-{ControllerName}-timestamp.json
        local controller="${filename#test-spec-}"
        controller="${controller%-*.json}"
        local modified
        modified=$(stat -f "%Sm" "$spec" 2>/dev/null || stat -c "%y" "$spec" 2>/dev/null || echo "unknown")
        echo "  - $controller (modified: $modified)"
    done

    echo ""
    return 0
}

# Check if test-spec file has valid structure
check_test_spec_structure() {
    local test_spec="$1"

    if [[ ! -f "$test_spec" ]]; then
        log_error "Test spec file not found: $test_spec"
        return 1
    fi

    # Check if it has testCases array
    local tc_count
    tc_count=$(jq '.testCases | length' "$test_spec" 2>/dev/null || echo "0")

    if [[ "$tc_count" -eq 0 ]] || [[ "$tc_count" == "null" ]]; then
        log_error "No testCases found in test-spec file: $test_spec"
        return 1
    fi

    log_info "Test spec file valid: $tc_count test case(s) found"
    return 0
}

# ============================================================
# DTO EXTRACTION
# ============================================================

# Get all unique dtoClasses across all test cases
get_all_dto_classes() {
    local test_spec="$1"

    jq '[.testCases[].dtoClasses[]? | select(. != null) | {name, path}] | unique_by(.name)' "$test_spec" 2>/dev/null || echo "[]"
}

# Count dtoClasses in test spec
count_dto_classes() {
    local test_spec="$1"
    jq '[.testCases[].dtoClasses[]? | select(. != null)] | length' "$test_spec" 2>/dev/null || echo "0"
}

# Extract field from dto class JSON
dto_field() {
    local dto_json="$1"
    local field="$2"
    echo "$dto_json" | jq -r "$field // empty" 2>/dev/null || echo ""
}

# ============================================================
# IDENTIFICATION METHODS
# ============================================================

# Priority 1: Annotation Scan
# Search for @Entity or @Table annotations that match the DTO name
scan_annotation() {
    local dto_name="$1"

    log_info "  Scanning annotations for: $dto_name"

    local java_files
    java_files=$(find_java_sources)

    if [[ -z "$java_files" ]]; then
        log_warn "  No Java files found in $JAVA_SOURCE_ROOT"
        return 1
    fi

    # Try to find Entity by matching class name (without DTO suffix)
    local base_name="${dto_name%DTO}"
    base_name="${base_name%DTO}"  # Handle cases like XXXIdDTO → XXX

    # Search for class declaration matching base name
    while IFS= read -r java_file; do
        # Check if file contains class declaration for base name
        if grep -q "public class $base_name\b" "$java_file" 2>/dev/null; then
            local class_path
            class_path=$(realpath "$java_file" 2>/dev/null || echo "$java_file")

            # Check for @Entity or @Table annotation on this class
            if grep -E '@(Entity|Table)\b' "$java_file" >/dev/null 2>&1; then
                log_info "  Found Entity via annotation: $base_name"
                # Extract table name from @Table annotation
                local table_name
                table_name=$(grep -oP '@Table\s*\(\s*name\s*=\s*"\K[^"]+' "$java_file" 2>/dev/null || echo "")
                if [[ -z "$table_name" ]]; then
                    # Fallback: convert class name to snake_case
                    table_name=$(echo "$base_name" | sed 's/\([A-Z]\)/_\L\1/g' | sed 's/^_//' | tr '[:upper:]' '[:lower:]')
                fi
                echo "$class_path|$table_name|annotation|0.95"
                return 0
            fi
        fi
    done <<< "$java_files"

    return 1
}

# Priority 2: Naming Inference
# DTO naming patterns to Entity:
# - SpmiCapacityBillDTO → SpmiCapacityBill (in entity package)
# - BaseQuery → BaseDO or BaseEntity (check entity package)
# - XXXIdDTO → XXX
infer_by_naming() {
    local dto_name="$1"

    log_info "  Inferring by naming: $dto_name"

    # Strip DTO suffix
    local base_name="${dto_name%DTO}"
    base_name="${base_name%Id}"  # Handle XXXIdDTO → XXX

    local java_files
    java_files=$(find_java_sources)

    if [[ -z "$java_files" ]]; then
        log_warn "  No Java files found"
        return 1
    fi

    # If no DTO suffix, the DTO name might already be close to Entity
    if [[ "$base_name" == "$dto_name" ]]; then
        # No DTO suffix, try common suffixes
        for suffix in "Entity" "DO" "PO"; do
            local candidate="$base_name$suffix"
            local candidate_path
            candidate_path=$(echo "$java_files" | xargs grep -l "public class $candidate\b" 2>/dev/null | head -1)
            if [[ -n "$candidate_path" ]]; then
                local class_path
                class_path=$(realpath "$candidate_path" 2>/dev/null || echo "$candidate_path")
                local table_name
                table_name=$(echo "$candidate" | sed 's/\([A-Z]\)/_\L\1/g' | sed 's/^_//' | tr '[:upper:]' '[:lower:]')
                log_info "  Inferred Entity via naming: $candidate"
                echo "$class_path|$table_name|naming_inference|0.7"
                return 0
            fi
        done
    else
        # Has DTO suffix, try exact match in entity package
        local entity_candidates=(
            "$base_name"                           # SpmiCapacityBill
            "${base_name}Entity"                  # SpmiCapacityBillEntity
            "${base_name}DO"                      # SpmiCapacityBillDO
        )

        for candidate in "${entity_candidates[@]}"; do
            local candidate_path
            candidate_path=$(echo "$java_files" | xargs grep -l "public class $candidate\b" 2>/dev/null | head -1)
            if [[ -n "$candidate_path" ]]; then
                local class_path
                class_path=$(realpath "$candidate_path" 2>/dev/null || echo "$candidate_path")
                local table_name
                table_name=$(echo "$candidate" | sed 's/\([A-Z]\)/_\L\1/g' | sed 's/^_//' | tr '[:upper:]' '[:lower:]')
                log_info "  Inferred Entity via naming: $candidate"
                echo "$class_path|$table_name|naming_inference|0.7"
                return 0
            fi
        done
    fi

    return 1
}

# Priority 3: Database Reverse (stub/future)
# This would connect to database and SHOW TABLES
# Skipped if not configured
db_reverse() {
    local dto_name="$1"

    log_info "  Database reverse lookup not implemented (requires DB config)"

    # Stub: Return failure to indicate this method is not available
    return 1
}

# ============================================================
# IDENTIFICATION MAIN
# ============================================================

# Identify entity for a single DTO
identify_entity() {
    local dto_name="$1"

    log_info "Identifying Entity for DTO: $dto_name"

    local result=""

    # Priority 1: Annotation Scan
    result=$(scan_annotation "$dto_name")
    if [[ -n "$result" ]]; then
        echo "$result"
        return 0
    fi

    # Priority 2: Naming Inference
    result=$(infer_by_naming "$dto_name")
    if [[ -n "$result" ]]; then
        echo "$result"
        return 0
    fi

    # Priority 3: Database Reverse (stub)
    # Skip - not implemented
    log_warn "  Could not identify Entity for $dto_name"
    echo "||unknown|0.0"
    return 0
}

# ============================================================
# STATE UPDATE
# ============================================================

# Update entityClass for a specific test case in test-spec JSON
update_test_case_entity_class() {
    local test_spec="$1"
    local tc_index="$2"
    local entity_json="$3"

    # Use jq to update the specific test case's entityClass field
    local tmp_file="${test_spec}.tmp"
    jq ".[\"testCases\"][$tc_index].entityClass = $entity_json" "$test_spec" > "$tmp_file" && mv "$tmp_file" "$test_spec"
}

# Build entityClass JSON for a single DTO
build_entity_class_json() {
    local dto_name="$1"

    local ident_result
    ident_result=$(identify_entity "$dto_name")

    IFS='|' read -r entity_path table_name ident_method confidence <<< "$ident_result"

    # Strip DTO suffix from name
    local entity_name="${dto_name%DTO}"
    entity_name="${entity_name%Id}"

    # If path is relative, make it absolute
    if [[ -n "$entity_path" ]] && [[ "$entity_path" != /* ]]; then
        entity_path="$PROJECT_ROOT/$entity_path"
    fi

    # Build JSON
    jq -n \
        --arg name "$entity_name" \
        --arg path "$entity_path" \
        --arg tableName "$table_name" \
        --arg method "$ident_method" \
        --argjson conf "$confidence" \
        '{
            name: (if $name == "" then null else $name end),
            path: (if $path == "" or $path == "/" then null else $path end),
            tableName: (if $tableName == "" or $tableName == "unknown" then null else $tableName end),
            identificationMethod: (if $method == "" or $method == "unknown" then null else $method end),
            confidence: $conf
        }'
}

# ============================================================
# MAIN FLOW
# ============================================================

main() {
    log_info "Starting identify-entity.sh"
    log_info "Project root: $PROJECT_ROOT"
    log_info "Project dir: $PROJECT_DIR"
    log_info "Java source: $JAVA_SOURCE_ROOT"

    # If no controller provided, list available options
    if [[ -z "$CONTROLLER_NAME" ]]; then
        echo ""
        echo "=========================================="
        echo "   ENTITY IDENTIFICATION"
        echo "=========================================="
        echo ""
        log_info "No controller specified"

        list_available_controllers
        echo "Usage: bash identify-entity.sh <controller-name>"
        echo "Example: bash identify-entity.sh SpmiCapacityBillController"
        exit 0
    fi

    echo ""
    echo "=========================================="
    echo "   ENTITY IDENTIFICATION"
    echo "=========================================="
    echo ""
    log_info "Controller: $CONTROLLER_NAME"

    # Find test-spec file
    local test_spec
    test_spec=$(find_test_spec "$CONTROLLER_NAME")
    if [[ $? -ne 0 ]] || [[ -z "$test_spec" ]]; then
        exit 1
    fi

    log_info "Test spec file: $test_spec"

    # Check structure
    check_test_spec_structure "$test_spec"
    if [[ $? -ne 0 ]]; then
        exit 1
    fi

    # Get all unique dto classes
    local all_dtos
    all_dtos=$(get_all_dto_classes "$test_spec")

    local dto_count
    dto_count=$(count_dto_classes "$test_spec")

    if [[ "$dto_count" -eq 0 ]]; then
        log_info "No DTO classes found in test-spec"
        log_info "Nothing to identify"
        exit 0
    fi

    log_info "Found $dto_count DTO class(es) to process"

    # Process each test case
    local tc_count
    tc_count=$(jq '.testCases | length' "$test_spec" 2>/dev/null || echo "0")

    local processed=0
    local total_with_dtos=0

    for ((tc_idx=0; tc_idx<tc_count; tc_idx++)); do
        local tc
        tc=$(jq ".testCases[$tc_idx]" "$test_spec")

        local tc_id
        local method
        tc_id=$(echo "$tc" | jq -r '.id // "unknown"')
        method=$(echo "$tc" | jq -r '.method // "unknown"')

        # Get dtoClasses for this test case
        local dto_classes_json
        dto_classes_json=$(echo "$tc" | jq '.dtoClasses // []')

        local dto_count_in_tc
        dto_count_in_tc=$(echo "$dto_classes_json" | jq 'length')

        if [[ "$dto_count_in_tc" -eq 0 ]] || [[ "$dto_count_in_tc" == "null" ]]; then
            continue
        fi

        ((total_with_dtos++)) || true

        log_info ""
        log_info "Processing test case [$tc_idx]: $tc_id.$method"

        # For now, identify entity for the first DTO (main entity)
        # If there are multiple DTOs, the first one is typically the main input
        local first_dto
        first_dto=$(echo "$dto_classes_json" | jq '.[0]')

        local dto_name
        dto_name=$(echo "$first_dto" | jq -r '.name // empty')

        if [[ -z "$dto_name" ]]; then
            log_warn "  No DTO name found, skipping"
            continue
        fi

        log_info "  Main DTO: $dto_name"

        # Build entity class JSON
        local entity_json
        entity_json=$(build_entity_class_json "$dto_name")

        # Update test-spec JSON
        update_test_case_entity_class "$test_spec" "$tc_idx" "$entity_json"

        ((processed++)) || true

        # Log the result
        local entity_name
        entity_name=$(echo "$entity_json" | jq -r '.name')
        local ident_method
        ident_method=$(echo "$entity_json" | jq -r '.identificationMethod')
        local confidence
        confidence=$(echo "$entity_json" | jq -r '.confidence')

        log_info "  → Entity: $entity_name (method: $ident_method, confidence: $confidence)"
    done

    echo ""
    echo "=========================================="
    echo "   SUMMARY"
    echo "=========================================="
    echo ""
    log_info "Processed $processed test case(s) with DTO classes"
    log_info "Entity identification complete"

    # Verify by reading back
    echo ""
    echo "Sample entityClass from first test case:"
    jq '.testCases[0].entityClass' "$test_spec" 2>/dev/null || echo "No entityClass found"

    echo ""
    log_info "Done. Entity classes have been written to:"
    log_info "  $test_spec"
}

# Run main
main "$@"
