#!/bin/bash
# extract-methods.sh - Extract HTTP endpoint methods from Controller Java file
set -e
CONTROLLER_PATH="$1"
if [[ ! -f "$CONTROLLER_PATH" ]]; then echo "[]"; exit 1; fi
if ! command -v python3 &> /dev/null; then echo "[]"; exit 1; fi
python3 - "$CONTROLLER_PATH" <<'EOF'
import re, sys, json
def parse_controller(file_path):
    with open(file_path, 'r') as f: content = f.read()
    mapping_pattern = r'@(Post|Get|Put|Delete|Request)Mapping\s*\(\s*["\']([^"\']+)["\']\s*\)'
    lines = content.split('\n')
    methods = []
    i = 0
    while i < len(lines):
        line = lines[i]
        mapping_match = re.search(mapping_pattern, line)
        if mapping_match:
            http_method = mapping_match.group(1).upper()
            if http_method == 'REQUEST': http_method = 'POST'
            route_path = mapping_match.group(2)
            method_sig = ""
            j = i + 1
            while j < min(i + 10, len(lines)):
                next_line = lines[j].strip()
                if next_line.startswith('public ') and '(' in next_line:
                    method_sig = next_line
                    break
                j += 1
            if method_sig:
                method_info = parse_method_signature(method_sig)
                method_info['routePath'] = route_path
                method_info['httpMethod'] = http_method
                methods.append(method_info)
                i = j
        i += 1
    return methods
def parse_method_signature(sig_line):
    sig = sig_line.strip()
    match = re.match(r'public\s+([\w<>,\s]+(?:<[^>]+>)?)\s+(\w+)\s*\((.*)\)', sig)
    if not match: return {'name':'unknown','returnType':'unknown','params':[],'hasRequestBody':False}
    return_type = match.group(1).strip()
    method_name = match.group(2)
    params_str = match.group(3)
    params = parse_params(params_str)
    has_request_body = '@RequestBody' in sig
    return {'name':method_name,'returnType':return_type,'params':params,'hasRequestBody':has_request_body}
def parse_params(params_str):
    if not params_str.strip(): return []
    params = []
    depth = 0
    current = ""
    for char in params_str:
        if char in '<(':
            depth += 1; current += char
        elif char in '>)':
            depth -= 1; current += char
        elif char == ',' and depth == 0:
            param = current.strip()
            if param:
                parsed = parse_single_param(param)
                if parsed: params.append(parsed)
            current = ""
        else:
            current += char
    param = current.strip()
    if param:
        parsed = parse_single_param(param)
        if parsed: params.append(parsed)
    return params
def parse_single_param(param_str):
    param_str = param_str.strip()
    if not param_str: return None
    parts = param_str.split()
    param_type = ""; param_name = ""
    for part in parts:
        if part.startswith('@'): continue
        elif not param_type: param_type = part
        else: param_name = part; break
    if not param_type: return None
    return {'type':param_type,'name':param_name}
if __name__ == '__main__':
    if len(sys.argv) < 2: print("[]"); sys.exit(1)
    file_path = sys.argv[1]
    try:
        methods = parse_controller(file_path)
        print(json.dumps(methods, indent=2))
    except: print("[]"); sys.exit(1)
EOF
chmod +x ~/.claude/skills/auto-test-gen/extract-methods.sh