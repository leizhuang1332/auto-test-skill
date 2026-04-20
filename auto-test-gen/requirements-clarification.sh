#!/bin/bash
# requirements-clarification.sh - Interactive Q&A for product requirements before test generation
# Purpose: Ask user 5 clarifying questions about business requirements, data boundaries, and edge cases
# Output: JSON file with user answers for AI prompt context
# Usage: bash requirements-clarification.sh <controller_name>

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
OUTPUT_DIR="${PROJECT_ROOT}/.auto-test"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_FILE="${OUTPUT_DIR}/requirements-${TIMESTAMP}.json"

# Ensure output directory exists
mkdir -p "$OUTPUT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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

# Default answers (in case user skips)
DEFAULT_ANSWERS='{
  "businessContext": null,
  "dataBoundaries": [],
  "externalDependencies": [],
  "commonBugs": [],
  "priority": {}
}'

# Check if running in Claude Code (interactive mode)
if [[ -z "$CLAUDE_CODE" ]]; then
    echo_warn "This script is designed to run within Claude Code's interactive mode."
    echo_info "When running via Claude Code, the AskUserQuestion tool will be used for Q&A."
    echo_info "Output file: $OUTPUT_FILE"
    echo ""
    echo "For standalone execution, this script outputs instructions for Claude Code."
fi

# ============================================================
# CLAUDE CODE INSTRUCTIONS
# ============================================================
# When this script is invoked, Claude Code should:
# 1. Read the CONTROLLER_NAME from $1 (or prompt for it)
# 2. Ask the following 5 questions ONE AT A TIME using AskUserQuestion
# 3. Record answers in a JSON structure
# 4. Write the JSON to OUTPUT_FILE
# ============================================================

CONTROLLER_NAME="${1:-}"

if [[ -z "$CONTROLLER_NAME" ]]; then
    echo "Usage: bash requirements-clarification.sh <ControllerName>"
    echo "Example: bash requirements-clarification.sh SpmiCapacityBillController"
    echo ""
    echo "CONTROLLER_NAME not provided. This script should be invoked by gen-test-class.sh"
    echo "with the Controller name as argument."
    exit 1
fi

echo_info "Starting requirements clarification for: $CONTROLLER_NAME"
echo_info "Output will be written to: $OUTPUT_FILE"
echo ""

# Initialize JSON structure
cat > "$OUTPUT_FILE" << 'JSONEOF'
{
  "controller": "",
  "timestamp": "",
  "businessContext": null,
  "dataBoundaries": [],
  "externalDependencies": [],
  "commonBugs": [],
  "priority": {}
}
JSONEOF

# Update controller and timestamp
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
python3 - << 'PYEOF' 2>/dev/null || true
import json
import sys
from datetime import datetime

with open('OUTPUT_FILE', 'r') as f:
    data = json.load(f)

data['controller'] = 'CONTROLLER_PLACEHOLDER'
data['timestamp'] = 'TIMESTAMP_PLACEHOLDER'

with open('OUTPUT_FILE', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
PYEOF

# Use sed for replacement since python may not be available
sed -i.bak "s/CONTROLLER_PLACEHOLDER/$CONTROLLER_NAME/" "$OUTPUT_FILE" 2>/dev/null || true
sed -i.bak "s/TIMESTAMP_PLACEHOLDER/$TIMESTAMP/" "$OUTPUT_FILE" 2>/dev/null || true
rm -f "${OUTPUT_FILE}.bak" 2>/dev/null || true

echo "============================================================"
echo "REQUIREMENTS CLARIFICATION QUESTIONS"
echo "============================================================"
echo ""
echo "Please answer the following questions to help generate"
echo "better test cases for $CONTROLLER_NAME"
echo ""
echo "============================================================"
echo ""

# Questions template (for Claude Code to ask via AskUserQuestion)
QUESTIONS=(
    "Q1: 业务背景 — 这个接口的业务目的是什么？谁会用？解决了什么问题？"
    "Q2: 数据边界 — 需要覆盖哪些边界情况？例如：空数据（空列表、空字符串、null）、极限值（最大\/最小数量、超长内容）、特殊状态（已删除、已锁定、审批中）、权限限制（无权限、数据不属于当前用户）"
    "Q3: 外部依赖 — 调用了哪些外部服务\/Feign？有没有已知的异常场景？"
    "Q4: 常见错误 — 有没有上线后出过的bug？用户常犯什么错误？"
    "Q5: 优先级 — 哪些用例必须覆盖（Blocking）？哪些可以跳过（Nice to have）？"
)

# Print questions for reference (when not in Claude Code)
for i in "${!QUESTIONS[@]}"; do
    echo "------------------------------------------------------------"
    echo -e "${GREEN}${QUESTIONS[$i]}${NC}"
    echo "------------------------------------------------------------"
    echo ""
done

echo "============================================================"
echo "CLAUDE CODE INSTRUCTIONS"
echo "============================================================"
echo ""
echo "To use this script with Claude Code:"
echo ""
echo "1. Invoke: bash requirements-clarification.sh <ControllerName>"
echo ""
echo "2. Claude Code will ask these 5 questions ONE AT A TIME:"
echo ""
for q in "${QUESTIONS[@]}"; do
    echo "   - $q"
done
echo ""
echo "3. After collecting answers, Claude Code should write the JSON:"
echo ""
echo "   cat > \${PROJECT_ROOT}/.auto-test/requirements-\${TIMESTAMP}.json << EOF"
echo '   {'
echo '     "controller": "<CONTROLLER_NAME>",'
echo '     "timestamp": "<ISO_TIMESTAMP>",'
echo '     "businessContext": "<user answer for Q1>",'
echo '     "dataBoundaries": [<array of boundary cases from Q2>],'
echo '     "externalDependencies": [<array of feign services from Q3>],'
echo '     "commonBugs": [<array of known bugs from Q4>],'
echo '     "priority": { "<TC_ID>": "blocking|nice-to-have", ... }'
echo '   }'
echo '   EOF'
echo ""
echo "4. Store the output file path for AI prompt context in gen-test-class.sh"
echo ""
echo "============================================================"
echo ""

# If CLAUDE_CODE is set, we expect the AI to handle the interactive part
if [[ -n "$CLAUDE_CODE" ]]; then
    echo_info "Running in Claude Code mode - expecting AskUserQuestion for interactive Q&A"
    echo_success "Questions printed above. Claude Code should ask them via AskUserQuestion."
    echo_success "Output will be written to: $OUTPUT_FILE"
fi

echo ""
echo_info "Next step: Run gen-test-class.sh which will read from this file"
echo "or invoke this script again to collect requirements before test generation."
