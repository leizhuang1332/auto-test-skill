#!/bin/bash
# gen-test-class.sh - Main orchestration script for auto-test-gen
# Phase 1: AI generates JUnit5 test cases → user confirms → write files → mvn compile
#
# Usage:
#   bash gen-test-class.sh [state-file-path]
#
# Input:
#   $1 = path to state.json (defaults to ~/.gstack/projects/yl-jms-spmibill-capacity/auto-test-state.json)
#
# Flow:
#   1. Read state.json for pending test cases
#   2. Read Controller source + DTO sources
#   3. Construct AI prompt for each test case
#   4. Display markdown preview for user review
#   5. User confirms → write .java files
#   6. Run mvn compile to verify
#   7. On compile failure: AI auto-fix once → retry compile

set -e

# ============================================================
# CONFIGURATION
# ============================================================

STATE_FILE="${1:-$HOME/.gstack/projects/yl-jms-spmibill-capacity/auto-test-state.json}"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
SKILL_DIR="$HOME/.claude/skills/auto-test-gen"
GENERATED_TEST_DIR="$PROJECT_ROOT/src/test/java/com/yl/spmibill/capacity/controller/generated"

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

# Check state file exists
check_state_file() {
    if [[ ! -f "$STATE_FILE" ]]; then
        log_error "State file not found: $STATE_FILE"
        echo "Please run parse-input.sh first to create state.json"
        exit 1
    fi
}

# Read a field from state.json using jq
read_state_field() {
    local field="$1"
    jq -r "$field // empty" "$STATE_FILE" 2>/dev/null || echo ""
}

# Get all pending test cases as JSON array
get_pending_test_cases() {
    jq '[.testCases[] | select(.status == "pending")]' "$STATE_FILE" 2>/dev/null || echo "[]"
}

# Count pending test cases
count_pending() {
    local pending
    pending=$(get_pending_test_cases)
    echo "$pending" | jq length 2>/dev/null || echo "0"
}

# Get test case by index from pending array
get_test_case() {
    local index="$1"
    local pending
    pending=$(get_pending_test_cases)
    echo "$pending" | jq ".[$index]" 2>/dev/null || echo "{}"
}

# Extract field from test case JSON
tc_field() {
    local tc_json="$1"
    local field="$2"
    echo "$tc_json" | jq -r "$field // empty" 2>/dev/null || echo ""
}

# Read file content safely
read_file() {
    local file_path="$1"
    if [[ -f "$file_path" ]]; then
        cat "$file_path"
    else
        echo ""
    fi
}

# Escape string for JSON embedding
escape_json_string() {
    local str="$1"
    # Use jq to properly escape
    echo "$str" | jq -Rs '.' | sed 's/^"//;s/"$//'
}

# ============================================================
# AI PROMPT CONSTRUCTION
# ============================================================

# Build AI prompt for generating a test case
build_ai_prompt() {
    local tc_json="$1"
    local controller_file="$2"

    local controller_name
    local method_name
    local route_path
    local http_method
    local method_signature

    controller_name=$(tc_field "$tc_json" ".controller")
    method_name=$(tc_field "$tc_json" ".method")
    route_path=$(tc_field "$tc_json" ".routePath")
    http_method=$(tc_field "$tc_json" ".httpMethod")
    method_signature=$(tc_field "$tc_json" ".methodSignature")

    # Get dtoClasses array
    local dto_classes_json
    dto_classes_json=$(echo "$tc_json" | jq -c ".dtoClasses // []")

    # Get feignMocks array
    local feign_mocks_json
    feign_mocks_json=$(echo "$tc_json" | jq -c ".feignMocks // []")

    # Get serviceMocks array
    local service_mocks_json
    service_mocks_json=$(echo "$tc_json" | jq -c ".serviceMocks // []")

    # Build prompt
    cat << PROMPT_EOF
## Task: Generate JUnit5 Controller Test

Generate a JUnit5 test class for a Spring Boot Controller method.

### Project Context
- Project root: ${PROJECT_ROOT}
- Test output dir: ${GENERATED_TEST_DIR}
- Package: com.yl.spmibill.capacity.controller.generated

### Controller Info
- Controller: ${controller_name}
- Method: ${method_name}
- Route: ${route_path}
- HTTP Method: ${http_method}
- Signature: ${method_signature}

### Controller Source
\`\`\`java
$(read_file "$controller_file")
\`\`\`

### DTO Classes
$(echo "$dto_classes_json" | jq -r '.[] | "- \(.name): \(.path // "unknown")"')

### Feign Clients to Mock
$(echo "$feign_mocks_json" | jq -r '.[] | "- \(.)"')

### Service Mocks
$(echo "$service_mocks_json" | jq -r '.[] | "- \(.)"')

### Test Pattern Reference (from existing test)
Use this pattern for Controller tests:
```java
@SpringBootTest
@MockBean for FeignClients
@Autowired for Controller
@Test

@ExtendWith(MockitoExtension.class)
@Mock for mapper/feign, @InjectMocks for service
```

Example service test:
```java
@Slf4j
@ExtendWith(MockitoExtension.class)
@DisplayName("集运类型维护Service单元测试")
class SpmiHKConsolidationShippingTypeServiceImplTest {

    @Mock
    private SpmiHKConsolidationShippingTypeMapper spmiHKConsolidationShippingTypeMapper;

    private SpmiHKConsolidationShippingTypeServiceImpl spmiHKConsolidationShippingTypeService;

    @BeforeEach
    void setUp() {
        spmiHKConsolidationShippingTypeService = new SpmiHKConsolidationShippingTypeServiceImpl();
        try {
            java.lang.reflect.Field baseMapperField = ServiceImpl.class.getDeclaredField("baseMapper");
            baseMapperField.setAccessible(true);
            baseMapperField.set(spmiHKConsolidationShippingTypeService, spmiHKConsolidationShippingTypeMapper);
        } catch (Exception e) {
            fail("Failed to inject mapper: " + e.getMessage());
        }
    }

    @Test
    @DisplayName("分页查询-正常查询返回分页结果")
    void getPages_ValidQueryDTO_ReturnPageResult() {
        // given
        SpmiHKConsolidationShippingTypeQueryDTO queryDTO = new SpmiHKConsolidationShippingTypeQueryDTO();
        queryDTO.setCurrent(1);
        queryDTO.setSize(10);

        // when
        Page<SpmiHKConsolidationShippingTypePageVO> result = spmiHKConsolidationShippingTypeService.getPages(queryDTO);

        // then
        assertNotNull(result);
        log.info("result={}", result);
    }
}
```

### Requirements
1. Use @SpringBootTest for Controller tests
2. Use @MockBean for FeignClients
3. Use @Autowired for the Controller
4. Generate realistic test data, NOT nulls
5. Follow Given-When-Then structure with log.info
6. Use assertNotNull, assertEquals, assertTrue, assertThrows as appropriate
7. Use verify(mock, times(1)).methodCall() for verification
8. Import all necessary classes
9. Package: com.yl.spmibill.capacity.controller.generated

### Output Format
Return ONLY the Java test code in a markdown code block. No explanations.
```java
// your test code here
```
PROMPT_EOF
}

# ============================================================
# FILE WRITING
# ============================================================

# Generate output file path for a test case
get_output_path() {
    local controller_name="$1"
    local method_name="$2"
    local suffix=""
    local version=1

    local base_name="${controller_name}${method_name}Test"
    local output_file="${base_name}${suffix}.java"
    local full_path="$GENERATED_TEST_DIR/$output_file"

    # Check for existing files and add version suffix
    while [[ -f "$full_path" ]]; do
        suffix="_v${version}"
        output_file="${base_name}${suffix}.java"
        full_path="$GENERATED_TEST_DIR/$output_file"
        ((version++)) || true
    done

    echo "$full_path"
}

# Write test file
write_test_file() {
    local output_path="$1"
    local content="$2"

    # Ensure directory exists
    mkdir -p "$(dirname "$output_path")"

    # Write content (removing markdown code block markers if present)
    echo "$content" | sed 's/^```java//;s/^```$//' > "$output_path"

    log_info "Written: $output_path"
}

# ============================================================
# STATE UPDATE
# ============================================================

# Update test case status in state.json
update_test_case_status() {
    local controller="$1"
    local method="$2"
    local status="$3"
    local test_file_path="$4"
    local generated_code="$5"

    # Build update object
    local update_json
    update_json=$(jq -n \
        --arg status "$status" \
        --arg testFilePath "$test_file_path" \
        --argjson generatedCode null \
        '{
            status: $status,
            testFilePath: (if $testFilePath == "" then null else $testFilePath end),
            generatedCode: $generatedCode
        }')

    # Update the specific test case in the array
    local new_test_cases
    new_test_cases=$(jq \
        "[.testCases[] | if (.controller == \"$controller\" and .method == \"$method\") then . * $update_json else . end]" \
        "$STATE_FILE")

    # Write back
    jq --argjson testCases "$new_test_cases" '.testCases = $testCases' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# Update overall state after confirmation
mark_confirmed() {
    jq '.confirmed = true' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# Update compile status
update_compile_status() {
    local success="$1"
    local error_msg="$2"

    if [[ "$success" == "true" ]]; then
        jq '.mavenCompileAttempted = true | .mavenCompileSuccess = true | .compilationError = null' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    else
        jq --arg err "$error_msg" '.mavenCompileAttempted = true | .mavenCompileSuccess = false | .compilationError = $err' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
}

# ============================================================
# MAVEN COMPILE
# ============================================================

# Run maven compile
run_mvn_compile() {
    log_info "Running mvn compile..."
    cd "$PROJECT_ROOT"

    local compile_output
    local compile_exit_code

    compile_output=$(mvn compile -pl . -am -q 2>&1)
    compile_exit_code=$?

    if [[ $compile_exit_code -eq 0 ]]; then
        log_info "Maven compile successful"
        return 0
    else
        log_error "Maven compile failed"
        echo "$compile_output" >&2
        return 1
    fi
}

# ============================================================
# AUTO-FIX ON COMPILE FAILURE
# ============================================================

# Build AI prompt for fixing compilation error
build_fix_prompt() {
    local original_code="$1"
    local compile_error="$2"
    local controller_file="$3"

    cat << PROMPT_EOF
## Task: Fix Compilation Error

The following Java test code has compilation errors. Please fix them.

### Original Test Code
\`\`\`java
$original_code
\`\`\`

### Controller Source
\`\`\`java
$(read_file "$controller_file")
\`\`\`

### Compilation Error
\`\`\`
$compile_error
\`\`\`

### Instructions
1. Read the compilation error carefully
2. Fix the test code to resolve the error
3. Make minimal changes - only what's necessary
4. Return ONLY the fixed Java test code in a markdown code block
5. Do not change the test logic, only fix syntax/type issues

Output format:
\`\`\`java
// fixed test code here
\`\`\`
PROMPT_EOF
}

# ============================================================
# USER INTERACTION
# ============================================================

# Display markdown preview for all generated tests
display_markdown_preview() {
    local pending_cases="$1"

    echo ""
    echo "=========================================="
    echo "   GENERATED TEST CASES PREVIEW"
    echo "=========================================="
    echo ""

    local count
    count=$(echo "$pending_cases" | jq length)

    for ((i=0; i<count; i++)); do
        local tc
        tc=$(echo "$pending_cases" | jq ".[$i]")

        local controller
        local method
        local route_path
        local http_method
        local generated_code

        controller=$(tc_field "$tc" ".controller")
        method=$(tc_field "$tc" ".method")
        route_path=$(tc_field "$tc" ".routePath")
        http_method=$(tc_field "$tc" ".httpMethod")
        generated_code=$(tc_field "$tc" ".generatedCode")

        echo "----------------------------------------"
        echo ""
        echo "### Test Case $((i+1))/${count}"
        echo ""
        echo "**Controller:** ${controller}"
        echo "**Method:** ${method}"
        echo "**Route:** ${route_path}"
        echo "**HTTP Method:** ${http_method}"
        echo ""
        echo '```java'
        echo "$generated_code"
        echo '```'
        echo ""
    done

    echo "=========================================="
    echo ""
}

# Ask user for confirmation
ask_confirmation() {
    local count="$1"

    echo "Please confirm the generated test cases:"
    echo "  - Type 'yes' to approve all and write files"
    echo "  - Type 'no' to reject all"
    echo "  - Type 'select 1,3,5' to approve specific test cases"
    echo ""
    echo -n "Your choice: "
    read -r user_choice

    echo "$user_choice"
}

# Parse user selection
parse_selection() {
    local choice="$1"
    local count="$2"

    if [[ "$choice" == "yes" ]] || [[ "$choice" == "y" ]]; then
        # Return all indices as comma-separated
        seq -s, 0 $((count-1))
    elif [[ "$choice" == "no" ]] || [[ "$choice" == "n" ]]; then
        echo "rejected_all"
    elif [[ "$choice" =~ ^select[\ ] ]]; then
        # Extract indices after "select "
        echo "$choice" | sed 's/select //'
    else
        echo "invalid"
    fi
}

# ============================================================
# MAIN FLOW
# ============================================================

main() {
    log_info "Starting gen-test-class.sh"
    log_info "State file: $STATE_FILE"
    log_info "Project root: $PROJECT_ROOT"

    # Check prerequisites
    check_state_file

    # Ensure generated test directory exists
    mkdir -p "$GENERATED_TEST_DIR"

    # Get pending test cases
    local pending_cases
    pending_cases=$(get_pending_test_cases)

    local pending_count
    pending_count=$(count_pending)

    if [[ "$pending_count" -eq 0 ]]; then
        log_info "No pending test cases found in state.json"
        log_info "Nothing to generate"
        exit 0
    fi

    log_info "Found $pending_count pending test case(s)"

    # Process each pending test case
    # NOTE: In the actual workflow, AI generates the code.
    # This script orchestrates the flow and expects generatedCode to be populated.
    # If generatedCode is null/empty, we skip that test case.

    echo ""
    echo "=========================================="
    echo "   PROCESSING PENDING TEST CASES"
    echo "=========================================="
    echo ""

    local processed_count=0
    local skip_count=0

    for ((i=0; i<pending_count; i++)); do
        local tc
        tc=$(echo "$pending_cases" | jq ".[$i]")

        local controller
        local method
        local generated_code

        controller=$(tc_field "$tc" ".controller")
        method=$(tc_field "$tc" ".method")
        generated_code=$(tc_field "$tc" ".generatedCode")

        if [[ -z "$generated_code" ]] || [[ "$generated_code" == "null" ]]; then
            log_info "Test case [$i]: ${controller}.${method} - No generated code (AI generation not yet done)"
            ((skip_count++)) || true
            continue
        fi

        log_info "Test case [$i]: ${controller}.${method} - Code available"
        ((processed_count++)) || true
    done

    if [[ "$skip_count" -gt 0 ]]; then
        echo ""
        log_info "Note: $skip_count test case(s) have no generated code."
        log_info "This script expects AI to have already generated the code."
        log_info "Run this script after AI has populated generatedCode in state.json"
    fi

    if [[ "$processed_count" -eq 0 ]]; then
        echo ""
        log_info "No test cases with generated code to process."
        log_info "Please run AI generation first."
        exit 0
    fi

    # Display markdown preview
    display_markdown_preview "$pending_cases"

    # Ask for user confirmation
    local user_choice
    user_choice=$(ask_confirmation "$processed_count")

    # Parse selection
    local selection
    selection=$(parse_selection "$user_choice" "$processed_count")

    if [[ "$selection" == "invalid" ]]; then
        log_error "Invalid choice: $user_choice"
        exit 1
    fi

    if [[ "$selection" == "rejected_all" ]]; then
        log_info "User rejected all test cases"
        # Mark all pending as rejected
        for ((i=0; i<pending_count; i++)); do
            local tc
            tc=$(echo "$pending_cases" | jq ".[$i]")
            local controller
            local method
            controller=$(tc_field "$tc" ".controller")
            method=$(tc_field "$tc" ".method")
            update_test_case_status "$controller" "$method" "rejected" "" ""
        done
        log_info "All test cases marked as rejected"
        exit 0
    fi

    # Process confirmed test cases
    log_info "Writing confirmed test files..."

    local confirmed_count=0
    local indices
    IFS=',' read -ra indices <<< "$selection"

    for idx in "${indices[@]}"; do
        local tc
        tc=$(echo "$pending_cases" | jq ".[$idx]")

        local controller
        local method
        local generated_code

        controller=$(tc_field "$tc" ".controller")
        method=$(tc_field "$tc" ".method")
        generated_code=$(tc_field "$tc" ".generatedCode")

        # Get output path
        local output_path
        output_path=$(get_output_path "$controller" "$method")

        # Write test file
        write_test_file "$output_path" "$generated_code"

        # Update state
        update_test_case_status "$controller" "$method" "confirmed" "$output_path" ""

        ((confirmed_count++)) || true
    done

    log_info "Wrote $confirmed_count test file(s)"

    # Mark overall state as confirmed
    mark_confirmed

    # Run maven compile
    echo ""
    echo "=========================================="
    echo "   RUNNING MAVEN COMPILE"
    echo "=========================================="
    echo ""

    if run_mvn_compile; then
        update_compile_status "true" ""
        log_info "All tests compiled successfully"
    else
        # Compile failed - offer AI auto-fix (user choice since autonomous=false)
        log_error "Compilation failed"
        echo ""
        echo "=========================================="
        echo "   COMPILATION FAILED"
        echo "=========================================="
        echo ""
        echo "Would you like to attempt AI auto-fix? (yes/no)"
        echo "Note: AI will make minimal changes to fix syntax/type issues."
        echo ""
        echo -n "Your choice: "
        read -r auto_fix_choice

        if [[ "$auto_fix_choice" == "yes" ]] || [[ "$auto_fix_choice" == "y" ]]; then
            log_info "User requested AI auto-fix"
            echo ""
            echo "NOTE: AI auto-fix requires Claude Code tool calling."
            echo "Please invoke Claude Code with the compilation error."
            echo ""
            # Store compile error in state for AI to read
            local compile_output
            compile_output=$(mvn compile -pl . -am -q 2>&1)
            jq --arg err "$compile_output" '.lastCompileError = $err' "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
            update_compile_status "false" "AI auto-fix requested - see lastCompileError in state.json"
            log_info "Compile error saved to state.json for AI fix"
            exit 1
        else
            update_compile_status "false" "Compilation failed - user declined auto-fix"
            log_error "Compilation failed"
            exit 1
        fi
    fi

    echo ""
    echo "=========================================="
    echo "   COMPLETED"
    echo "=========================================="
    echo ""
    log_info "Test generation complete!"
    log_info "Generated files are in: $GENERATED_TEST_DIR"
}

# Run main
main "$@"
