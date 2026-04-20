#!/bin/bash
# extract-feign.sh - Extract FeignClient dependencies from Controller
# Input: $1 = absolute path to Controller.java
# Output: JSON array to stdout

set -e

CONTROLLER_PATH="$1"

if [[ -z "$CONTROLLER_PATH" ]] || [[ ! -f "$CONTROLLER_PATH" ]]; then
  echo "[]"
  exit 1
fi

# Get project root
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "")

# Collect all Feign entries
declare -a ENTRIES

# Method 1: Find @FeignClient annotation on interface declarations
while IFS=: read -r line_num rest; do
  # Look backwards for interface declaration
  prev_lines=$(sed -n "$((line_num-5)),$((line_num-1))p" "$CONTROLLER_PATH")
  if echo "$prev_lines" | grep -q "interface"; then
    interface_line_num=$(echo "$prev_lines" | grep -n "interface" | tail -1 | cut -d: -f1)
    actual_line_num=$((line_num - 5 + interface_line_num - 1))
    interface_name=$(sed -n "${actual_line_num}p" "$CONTROLLER_PATH" | sed 's/.*interface[[:space:]]\+\([A-Za-z0-9_]\+\).*/\1/')
    if [[ -n "$interface_name" ]]; then
      # Find package from imports
      import_line=$(grep "import.*${interface_name}" "$CONTROLLER_PATH" 2>/dev/null | head -1)
      if [[ -n "$import_line" ]]; then
        pkg=$(echo "$import_line" | sed 's/.*import[[:space:]]\+//;s/\.[^.]*$;//')
      else
        pkg="com.yl.spmibill.capacity.feign"
      fi
      ENTRIES+=("{\"name\":\"$interface_name\",\"package\":\"$pkg\",\"fieldName\":null}")
    fi
  fi
done < <(grep -n "@FeignClient" "$CONTROLLER_PATH" 2>/dev/null || true)

# Method 2: Find @Autowired fields with Feign in type
while IFS=: read -r line_num rest; do
  # Check next few lines for field declaration with Feign
  for offset in 0 1 2; do
    check_line=$((line_num + offset))
    field_line=$(sed -n "${check_line}p" "$CONTROLLER_PATH")

    if echo "$field_line" | grep -qi "Feign"; then
      # Extract type name
      if [[ "$field_line" =~ [A-Z][a-zA-Z0-9_]*Feign[a-zA-Z0-9_]* ]]; then
        feign_type="${BASH_REMATCH[0]}"
        # Extract field name
        field_name=$(echo "$field_line" | sed -E 's/.*\b([a-z][a-zA-Z0-9]*Feign[a-zA-Z0-9]*)\b[[:space:]]+([a-z][a-zA-Z0-9]*).*/\2/')
        if [[ -z "$field_name" ]] || [[ "$field_name" == "$feign_type" ]]; then
          field_name=$(echo "$field_line" | sed -E 's/.*\b([a-z][a-zA-Z0-9]*).*/\1/;s/[A-Z]/\L&/g')
        fi
        # Find package from imports
        pkg=""
        for pkg_offset in $(seq $((check_line - 1)) -1 $((check_line - 20))); do
          [[ $pkg_offset -lt 1 ]] && break
          pkg_line=$(sed -n "${pkg_offset}p" "$CONTROLLER_PATH")
          if echo "$pkg_line" | grep -q "import.*${feign_type}"; then
            pkg=$(echo "$pkg_line" | sed 's/.*import[[:space:]]\+//;s/\.[^.]*$;//')
            break
          fi
        done
        [[ -z "$pkg" ]] && pkg="com.yl.spmibill.capacity.feign"

        ENTRIES+=("{\"name\":\"$feign_type\",\"package\":\"$pkg\",\"fieldName\":\"$field_name\"}")
        break
      fi
    fi
  done
done < <(grep -n "@Autowired" "$CONTROLLER_PATH" 2>/dev/null || true)

# Deduplicate and output
if [[ ${#ENTRIES[@]} -eq 0 ]]; then
  echo "[]"
else
  printf '%s\n' "${ENTRIES[@]}" | sort -u | awk 'BEGIN { printf "["; first=1 } { if (!first) printf ","; first=0; printf "\n  %s", $0 } END { if (first) print "[]"; else print "\n]" }'
fi
