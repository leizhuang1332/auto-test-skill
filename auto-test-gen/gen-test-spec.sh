#!/bin/bash
# gen-test-spec.sh - Main orchestration script for JSON test spec generation
# Purpose: Read Controller source, invoke AI to generate JSON test spec, show preview, write files
# Phase: Phase 1 (auto-test-gen)
# Input: $1 = controller name or path (from parse-input.sh output)
# Output: test-spec-{controller}-{timestamp}.json + test-spec-{controller}-{timestamp}.md

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$SCRIPT_DIR"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
AUTO_TEST_DIR="${PROJECT_ROOT}/.auto-test"
OUTPUT_DIR="$AUTO_TEST_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

echo_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

echo_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

echo_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

# =============================================================================
# STEP 1: Parse input and find Controller file
# =============================================================================
parse_input() {
    INPUT="$1"

    if [[ -z "$INPUT" ]]; then
        echo_error "Usage: bash gen-test-spec.sh <ControllerName|ControllerPath>"
        exit 1
    fi

    # Use parse-input.sh if available
    if [[ -x "$SKILL_DIR/parse-input.sh" ]]; then
        PARSED=$(bash "$SKILL_DIR/parse-input.sh" "$INPUT" 2>/dev/null)
        if [[ $? -eq 0 ]]; then
            CONTROLLER_PATH=$(echo "$PARSED" | jq -r '.filePath' 2>/dev/null)
            CONTROLLER_NAME=$(echo "$PARSED" | jq -r '.value' 2>/dev/null)
            INPUT_TYPE=$(echo "$PARSED" | jq -r '.type' 2>/dev/null)
        fi
    fi

    # Fallback: find Controller file directly
    if [[ -z "$CONTROLLER_PATH" ]] || [[ ! -f "$CONTROLLER_PATH" ]]; then
        # Handle Controller.class.method() format
        if [[ "$INPUT" =~ ^(.*Controller)\.(.*)\(\)$ ]]; then
            CONTROLLER_NAME="${BASH_REMATCH[1]}"
            METHOD_NAME="${BASH_REMATCH[2]}"
        elif [[ "$INPUT" =~ ^.*Controller$ ]]; then
            CONTROLLER_NAME="$INPUT"
        else
            CONTROLLER_NAME="$INPUT"
        fi

        CONTROLLER_PATH=$(find "$PROJECT_ROOT/src" -name "*${CONTROLLER_NAME}.java" 2>/dev/null | head -1)
    fi

    if [[ ! -f "$CONTROLLER_PATH" ]]; then
        echo_error "Controller file not found: $CONTROLLER_NAME"
        exit 1
    fi

    # Extract controller name from path if not set
    if [[ -z "$CONTROLLER_NAME" ]]; then
        CONTROLLER_NAME=$(basename "$CONTROLLER_PATH" .java)
    fi

    echo_info "Controller: $CONTROLLER_NAME"
    echo_info "Path: $CONTROLLER_PATH"
}

# =============================================================================
# STEP 2: Load requirements from previous clarification (if exists)
# =============================================================================
load_requirements() {
    echo_info "Checking for previous requirements clarification..."

    # Find most recent requirements file
    REQUIREMENTS_FILE=$(ls -t "$OUTPUT_DIR"/requirements-*.json 2>/dev/null | head -1)

    if [[ -n "$REQUIREMENTS_FILE" ]] && [[ -f "$REQUIREMENTS_FILE" ]]; then
        echo_success "Found requirements file: $REQUIREMENTS_FILE"

        # Parse requirements into variables
        REQUIREMENTS_JSON=$(cat "$REQUIREMENTS_FILE")
        BUSINESS_CONTEXT=$(echo "$REQUIREMENTS_JSON" | jq -r '.businessContext // empty')
        DATA_BOUNDARIES=$(echo "$REQUIREMENTS_JSON" | jq -r '.dataBoundaries[]? // empty' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        EXTERNAL_DEPS=$(echo "$REQUIREMENTS_JSON" | jq -r '.externalDependencies[]? // empty' 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        COMMON_BUGS=$(echo "$REQUIREMENTS_JSON" | jq -r '.commonBugs[]? // empty' 2>/dev/null | tr '\n' ',' | sed 's/,$//')

        echo_info "Requirements loaded: businessContext=$BUSINESS_CONTEXT"
    else
        echo_warn "No requirements file found. Run requirements-clarification.sh first for better test coverage."
        BUSINESS_CONTEXT="null"
        DATA_BOUNDARIES=""
        EXTERNAL_DEPS=""
        COMMON_BUGS=""
    fi
}

# =============================================================================
# STEP 3: Extract methods, DTOs, and FeignClients
# =============================================================================
extract_metadata() {
    echo_info "Extracting metadata from Controller..."

    # Extract methods
    if [[ -x "$SKILL_DIR/extract-methods.sh" ]]; then
        METHODS_JSON=$("$SKILL_DIR/extract-methods.sh" "$CONTROLLER_PATH" 2>/dev/null)
        METHOD_COUNT=$(echo "$METHODS_JSON" | jq 'length' 2>/dev/null || echo "0")
        echo_success "Found $METHOD_COUNT methods"
    else
        echo_error "extract-methods.sh not found or not executable"
        exit 1
    fi

    # Extract DTOs
    if [[ -x "$SKILL_DIR/extract-dto.sh" ]]; then
        DTOS_JSON=$("$SKILL_DIR/extract-dto.sh" "" 2>/dev/null || echo "[]")
    fi

    # Extract FeignClients
    if [[ -x "$SKILL_DIR/extract-feign.sh" ]]; then
        FEIGNS_JSON=$("$SKILL_DIR/extract-feign.sh" "$CONTROLLER_PATH" 2>/dev/null || echo "[]")
        FEIGN_COUNT=$(echo "$FEIGNS_JSON" | jq 'length' 2>/dev/null || echo "0")
        echo_success "Found $FEIGN_COUNT FeignClients"
    fi
}

# =============================================================================
# STEP 4: Read Controller source code
# =============================================================================
read_controller_source() {
    echo_info "Reading Controller source..."
    CONTROLLER_SOURCE=$(cat "$CONTROLLER_PATH")
    CONTROLLER_SOURCE_LENGTH=$(echo "$CONTROLLER_SOURCE" | wc -l)
    echo_success "Controller source: $CONTROLLER_SOURCE_LENGTH lines"
}

# =============================================================================
# STEP 5: Build AI prompt and generate test spec
# =============================================================================
generate_test_spec() {
    echo_info "Generating test spec via AI..."

    # Build the prompt for AI
    cat > "$OUTPUT_DIR/.gen-test-spec-prompt.txt" << PROMPT_EOF
# AI PROMPT: Generate JSON Test Spec for Controller

## Project Context
- Project Root: $PROJECT_ROOT
- Controller: $CONTROLLER_NAME
- Controller Path: $CONTROLLER_PATH

## Controller Source Code
\`\`\`java
$CONTROLLER_SOURCE
\`\`\`

## Extracted Methods (JSON)
\`\`\`json
$METHODS_JSON
\`\`\`

## FeignClients (JSON)
\`\`\`json
$FEIGNS_JSON
\`\`\`

## Requirements Context (from requirements-clarification.sh)
- Business Context: ${BUSINESS_CONTEXT:-Not provided}
- Data Boundaries: ${DATA_BOUNDARIES:-Not provided}
- External Dependencies: ${EXTERNAL_DEPS:-Not provided}
- Common Bugs: ${COMMON_BUGS:-Not provided}

## Your Task

Generate a JSON test specification for all methods in this Controller. The output should be a VALID JSON object following this schema:

\`\`\`json
{
  "version": "1.0",
  "project": "yl-jms-spmibill-capacity",
  "createdAt": "${TIMESTAMP}",
  "controller": "${CONTROLLER_NAME}",
  "controllerPath": "${CONTROLLER_PATH}",
  "phase": "phase1_completed",
  "requirements": {
    "businessContext": "${BUSINESS_CONTEXT:-null}",
    "dataBoundaries": [${DATA_BOUNDARIES:-}],
    "externalDependencies": [${EXTERNAL_DEPS:-}],
    "commonBugs": [${COMMON_BUGS:-}],
    "priority": {}
  },
  "testCases": [
    {
      "id": "TC001",
      "method": "methodName",
      "methodSignature": "Result<Type> methodName(ParamType)",
      "功能": "功能描述（中文）",
      "数据边界": "数据边界描述（中文）",
      "输入参数": {
        "dtoClass": "DTOClassName",
        "fields": [
          { "name": "fieldName", "type": "FieldType", "value": "testValue", "description": "字段描述" }
        ]
      },
      "预期返回结果": {
        "code": 200,
        "message": "success",
        "data": true
      },
      "实际结果": null,
      "原因": null,
      "dtoClasses": [{ "name": "DTOClassName", "path": "/path/to/DTO.java" }],
      "feignMocks": [],
      "status": "pending"
    }
  ]
}
\`\`\`

## Requirements for Test Cases

1. **ID Format**: TC001, TC002, TC003... (sequential)
2. **功能 (Function)**: Describe what this method does in Chinese
3. **数据边界 (Data Boundary)**: Describe the test scenario:
   - 正常数据 (Happy path)
   - 空数据 (Empty/null values)
   - 极限值 (Boundary values)
   - 异常数据 (Error cases)
4. **输入参数**: Include all relevant fields with:
   - name: field name
   - type: Java type
   - value: test value
   - description: field description in Chinese
5. **预期返回结果**: Result<T> structure with code, message, data
6. **dtoClasses**: List all DTO classes used
7. **feignMocks**: List FeignClients to mock (if any)

## Important Notes

- The controller returns Result<T> wrapper objects
- All test case status should be "pending" initially
- 实际结果 and 原因 should be null (filled by Phase 3)
- Use realistic test values based on business context
- Generate at least 2-3 test cases per method covering different scenarios

Please output ONLY the JSON object (no markdown code blocks, no explanations).
PROMPT_EOF

    echo_info "Prompt written to: $OUTPUT_DIR/.gen-test-spec-prompt.txt"
    echo_info "IMPORTANT: This script requires Claude Code to invoke AI for generation."
    echo_warn "In standalone mode, please use Claude Code to read the prompt and generate JSON."
}

# =============================================================================
# STEP 6: Display markdown preview and ask for confirmation
# =============================================================================
show_preview() {
    echo ""
    echo "============================================================"
    echo "GENERATED TEST SPEC PREVIEW"
    echo "============================================================"
    echo ""

    # Check if AI generated output exists
    if [[ -f "$OUTPUT_DIR/.gen-test-spec-ai-output.json" ]]; then
        cat "$OUTPUT_DIR/.gen-test-spec-ai-output.json"
    else
        echo_warn "No AI output found. Running in demo mode."
        cat << 'DEMO_EOF'
{
  "version": "1.0",
  "project": "yl-jms-spmibill-capacity",
  "createdAt": "${TIMESTAMP}",
  "controller": "${CONTROLLER_NAME}",
  "controllerPath": "${CONTROLLER_PATH}",
  "phase": "phase1_completed",
  "requirements": {
    "businessContext": "${BUSINESS_CONTEXT:-null}",
    "dataBoundaries": [],
    "externalDependencies": [],
    "commonBugs": [],
    "priority": {}
  },
  "testCases": []
}
DEMO_EOF
    fi

    echo ""
    echo "============================================================"
    echo "NEXT STEPS"
    echo "============================================================"
    echo ""
    echo "1. Review the generated JSON test spec above"
    echo "2. If running via Claude Code, the AI will generate the actual spec"
    echo "3. After confirmation, files will be written to:"
    echo "   - $OUTPUT_DIR/test-spec-${CONTROLLER_NAME}-${TIMESTAMP}.json"
    echo "   - $OUTPUT_DIR/test-spec-${CONTROLLER_NAME}-${TIMESTAMP}.md"
    echo ""
}

# =============================================================================
# STEP 7: Write JSON and Markdown files
# =============================================================================
write_files() {
    local JSON_CONTENT="$1"

    if [[ -z "$JSON_CONTENT" ]] || [[ "$JSON_CONTENT" == "null" ]]; then
        echo_error "No JSON content provided for writing"
        return 1
    fi

    JSON_OUTPUT="$OUTPUT_DIR/test-spec-${CONTROLLER_NAME}-${TIMESTAMP}.json"
    MD_OUTPUT="$OUTPUT_DIR/test-spec-${CONTROLLER_NAME}-${TIMESTAMP}.md"

    # Write JSON file
    echo "$JSON_CONTENT" > "$JSON_OUTPUT"
    echo_success "JSON written: $JSON_OUTPUT"

    # Generate markdown report
    generate_markdown_report "$JSON_CONTENT" > "$MD_OUTPUT"
    echo_success "Markdown written: $MD_OUTPUT"

    # Clean up temp files
    rm -f "$OUTPUT_DIR/.gen-test-spec-prompt.txt" 2>/dev/null
    rm -f "$OUTPUT_DIR/.gen-test-spec-ai-output.json" 2>/dev/null

    echo ""
    echo_success "Files generated successfully!"
    echo "   JSON: $JSON_OUTPUT"
    echo "   Markdown: $MD_OUTPUT"
}

# =============================================================================
# STEP 8: Generate Markdown Report
# =============================================================================
generate_markdown_report() {
    local JSON_CONTENT="$1"

    cat << HEADER
# Test Spec: ${CONTROLLER_NAME}

**Generated:** ${TIMESTAMP}
**Controller:** ${CONTROLLER_NAME}
**Path:** ${CONTROLLER_PATH}
**Phase:** Phase 1 (auto-test-gen)

---

## Requirements Summary

- **Business Context:** ${BUSINESS_CONTEXT:-Not provided}
- **Data Boundaries:** ${DATA_BOUNDARIES:-Not provided}
- **External Dependencies:** ${EXTERNAL_DEPS:-Not provided}
- **Common Bugs:** ${COMMON_BUGS:-Not provided}

---

## Test Cases

| ID | Method | 功能 | 数据边界 | 输入参数 | 预期返回结果 | 实际结果 | 原因 |
|----|--------|------|----------|---------|-------------|----------|------|
HEADER

    # Parse JSON and generate table rows
    echo "$JSON_CONTENT" | jq -r '.testCases[]? | "| \(.id) | \(.method) | \(.功能) | \(.数据边界) | \(.输入参数.dtoClass) | code=\(.预期返回结果.code), data=\(.预期返回结果.data) | \(.实际结果 // "-") | \(.原因 // "-") |"' 2>/dev/null || true

    cat << FOOTER

---

## Test Case Details

FOOTER

    # Generate detailed section for each test case
    echo "$JSON_CONTENT" | jq -r '.testCases[]? | "### \(.id): \(.method)\n\n**功能:** \(.功能)\n\n**数据边界:** \(.数据边界)\n\n**输入参数:**\n- DTO Class: \(.输入参数.dtoClass)\n- Fields:\n\(.输入参数.fields[]? | "  - \(.name) (\(.type)): \(.description) = \(.value)")\n\n**预期返回结果:**\n- Code: \(.预期返回结果.code)\n- Message: \(.预期返回结果.message)\n- Data: \(.预期返回结果.data)\n\n**Status:** \(.status)\n\n---\n"' 2>/dev/null || true

    cat << EOF

## Phase Status

- **Current Phase:** Phase 1 (auto-test-gen) - COMPLETED
- **Next Phase:** Phase 2 (auto-test-data) - pending

## Files Generated

- \`test-spec-${CONTROLLER_NAME}-${TIMESTAMP}.json\` - JSON test spec (source of truth)
- \`test-spec-${CONTROLLER_NAME}-${TIMESTAMP}.md\` - This markdown report

---
*Generated by gen-test-spec.sh (Phase 1: auto-test-gen)*
EOF
}

# =============================================================================
# MAIN EXECUTION FLOW
# =============================================================================
main() {
    echo "============================================================"
    echo "gen-test-spec.sh - JSON Test Spec Generator"
    echo "============================================================"
    echo ""

    # Step 1: Parse input
    parse_input "$1"

    # Step 2: Load requirements
    load_requirements

    # Step 3: Extract metadata
    extract_metadata

    # Step 4: Read Controller source
    read_controller_source

    # Step 5: Generate test spec (via AI in Claude Code)
    generate_test_spec

    # Step 6: Show preview
    show_preview

    echo ""
    echo_info "Script completed. In Claude Code, AI will generate the actual test spec."
    echo_info "The AI prompt is available at: $OUTPUT_DIR/.gen-test-spec-prompt.txt"

    # If AI output exists, write the files
    if [[ -f "$OUTPUT_DIR/.gen-test-spec-ai-output.json" ]]; then
        echo ""
        echo_warn "AI output found. Writing files..."
        JSON_CONTENT=$(cat "$OUTPUT_DIR/.gen-test-spec-ai-output.json")
        write_files "$JSON_CONTENT"
    fi
}

# Handle direct invocation vs sourcing
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
