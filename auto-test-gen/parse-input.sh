#!/bin/bash
# parse-input.sh - Parse user input for auto-test-gen
# Input: $1 - raw user input string
# Output: JSON to stdout: {"type":"...","value":"...","filePath":"..."}
# Errors: Print error message to stderr, exit 1

set -e

# Ensure we're in the project root
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
if [[ -z "$PROJECT_ROOT" ]]; then
  echo '{"type":"error","value":"Not in a git repository","filePath":null}' >&2
  exit 1
fi
cd "$PROJECT_ROOT"

INPUT="$1"

# Case 1 - Commit (7-8 char hex string)
if [[ "$INPUT" =~ ^[0-9a-f]{7,8}$ ]]; then
  type="commit"
  value="$INPUT"

  filePath=$(git show "$value" --name-only 2>/dev/null | grep -i "Controller" | head -1)

  if [[ -z "$filePath" ]]; then
    echo "Error: No Controller files found in commit ${value}" >&2
    exit 1
  fi

  filePath="$PROJECT_ROOT/$filePath"
  filePath=$(readlink -f "$filePath" 2>/dev/null || echo "$filePath")

  echo "{\"type\":\"$type\",\"value\":\"$value\",\"filePath\":\"$filePath\"}"
  exit 0

# Case 2 - Branch ("测试 " prefix)
elif [[ "$INPUT" == "测试 "* ]]; then
  type="branch"
  value="${INPUT#* }"

  DEFAULT_BASE=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@')
  : "${DEFAULT_BASE:=master}"

  filePath=$(git diff "$DEFAULT_BASE"..."$value" --name-only 2>/dev/null | grep -i "Controller" | head -1)

  if [[ -z "$filePath" ]]; then
    echo "Error: No Controller files found in branch ${value}" >&2
    exit 1
  fi

  filePath="$PROJECT_ROOT/$filePath"
  filePath=$(readlink -f "$filePath" 2>/dev/null || echo "$filePath")

  echo "{\"type\":\"$type\",\"value\":\"$value\",\"filePath\":\"$filePath\"}"
  exit 0

# Case 3 - Method ("Controller.method()" pattern)
elif [[ "$INPUT" =~ ^(.*Controller)\.(.*)\(\)$ ]]; then
  type="method"
  controller="${BASH_REMATCH[1]}"
  method="${BASH_REMATCH[2]}"
  value="$INPUT"

  controllerFile=$(find "$PROJECT_ROOT/src" -name "*${controller}.java" 2>/dev/null | head -1)

  if [[ -z "$controllerFile" ]]; then
    echo "Error: Controller ${controller} not found" >&2
    exit 1
  fi

  if ! grep -q "public.*$method(" "$controllerFile" 2>/dev/null; then
    echo "Error: Method ${method} not found in ${controller}" >&2
    exit 1
  fi

  filePath=$(readlink -f "$controllerFile" 2>/dev/null || echo "$controllerFile")

  echo "{\"type\":\"$type\",\"value\":\"$value\",\"filePath\":\"$filePath\"}"
  exit 0

# Case 4 - Controller (ends with Controller)
elif [[ "$INPUT" =~ ^.*Controller$ ]]; then
  type="controller"
  value="$INPUT"

  controllerFile=$(find "$PROJECT_ROOT/src" -name "*${value}.java" 2>/dev/null | head -1)

  if [[ -z "$controllerFile" ]]; then
    echo "Error: Controller ${value} not found" >&2
    exit 1
  fi

  filePath=$(readlink -f "$controllerFile" 2>/dev/null || echo "$controllerFile")

  echo "{\"type\":\"$type\",\"value\":\"$value\",\"filePath\":\"$filePath\"}"
  exit 0

# Case 5 - Unknown
else
  echo "{\"type\":\"unknown\",\"value\":\"$INPUT\",\"filePath\":null}" >&2
  exit 1
fi
