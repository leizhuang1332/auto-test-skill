#!/bin/bash
# extract-dto.sh - Extract DTO class names from method signature
# Input: $1 = method signature string
# Output: JSON array to stdout
set -e
METHOD_SIG="$1"
if [[ -z "$METHOD_SIG" ]]; then echo "[]"; exit 0; fi
PROJECT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
python3 - "$METHOD_SIG" "$PROJECT_ROOT" <<'EOF'
import re, sys, json, os

method_sig = sys.argv[1]
project_root = sys.argv[2] if len(sys.argv) > 2 else "."

def find_java_file(type_name, project_root):
    if not type_name:
        return None
    search_paths = [
        os.path.join(project_root, 'src/main/java/com/yl/spmibill/capacity/dto'),
        os.path.join(project_root, 'src/main/java/com/yl/spmibill/capacity/vo'),
    ]
    for search_path in search_paths:
        if not os.path.exists(search_path):
            continue
        for root, dirs, files in os.walk(search_path):
            for f in files:
                if f == type_name + '.java':
                    return os.path.join(root, f)
    # Fallback: broader search
    base = os.path.join(project_root, 'src/main/java/com/yl/spmibill/capacity')
    if os.path.exists(base):
        for root, dirs, files in os.walk(base):
            for f in files:
                if f == type_name + '.java':
                    return os.path.join(root, f)
    return None

def infer_package(java_file_path):
    if not java_file_path or not os.path.exists(java_file_path):
        return "com.yl.spmibill.capacity"
    try:
        with open(java_file_path, 'r') as f:
            for line in f:
                match = re.match(r'package\s+([\w.]+);', line.strip())
                if match:
                    return match.group(1)
    except:
        pass
    return "com.yl.spmibill.capacity"

# Remove annotations
sig = re.sub(r'@\w+(?:\([^)]*\))?', '', method_sig)

# Skip types
skip_types = {'int','long','double','float','boolean','char','byte','short','String','Integer','Long','Double','Float','Boolean','Character','Byte','Short','void','List','Map','Set','Collection','ArrayList','HashMap','HashSet','Page','Result','Object','Comparable','Serializable'}

# Find all type names (capitalized identifiers)
type_pattern = r'\b([A-Z][a-zA-Z0-9]*(?:\.[a-zA-Z][a-zA-Z0-9]*)*)\b'
matches = re.findall(type_pattern, sig)

# Also find types inside angle brackets
generic_pattern = r'<([A-Z][a-zA-Z0-9]*)>'
generic_matches = re.findall(generic_pattern, sig)
matches.extend(generic_matches)

# Deduplicate and filter
types = []
for t in matches:
    if t not in skip_types and t not in types:
        types.append(t)

dtos = []
for t in types:
    path = find_java_file(t, project_root)
    pkg = infer_package(path) if path else "com.yl.spmibill.capacity"
    dtos.append({"name": t, "path": path, "package": pkg})

print(json.dumps(dtos, indent=2))
EOF