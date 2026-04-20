---
name: auto-test-run
description: Read Phase 1/2 test-spec-{controller}.json → mvn package → java -jar → curl test Controller endpoints → auto-fix ≤5 line bugs → output test reports. Phase 3 of the auto-test pipeline.
metadata:
  author: leizhuang1332
  version: "2.0"
  phase: 3
  pipeline: auto-test
---

# Skill: auto-test-run

**Phase:** Phase 3 only (auto-test-run)
**Purpose:** Read Phase 1/2 test-spec-{controller}.json → mvn package → java -jar → curl test Controller endpoints → auto-fix ≤5 line bugs → output test reports

## Triggers

- `/auto-test-run` — main entry point (Phase 3)
- `auto-test-run` — alternative invocation
- `bash run-test.sh` — direct script execution

## Prerequisites

- Phase 1 completed (test-spec-{controller}.json with test cases)
- Phase 2 completed (test data inserted via MCP, status = "data_inserted")
- Maven installed (mvn command available)
- Java 8+ (java command available)
- Application builds without errors

## Input

Reads from test-spec JSON (`{PROJECT_ROOT}/.auto-test/test-spec-{controller}-{timestamp}.json`):
- `testCases[].method` — method name to test
- `testCases[].输入参数.fields` — DTO fields for request body construction
- `testCases[].status` — must be `data_inserted` to run (Phase 2 completed)
- `testCases[].预期返回结果` — expected response (for reference)

## Data Flow

```
test-spec-{controller}.json (from Phase 1 + Phase 2)
       │
       ▼
run-test.sh: Maven package + App startup
  ├─ Find latest test-spec-{controller}.json
  ├─ Check status = "data_inserted" (Phase 2 completed)
  ├─ mvn clean package -DskipTests
  ├─ Find jar in target/ (exclude *-original.jar)
  ├─ Read application.yml for server.port + context-path
  ├─ Port conflict: kill existing + retry (max 3 attempts)
  ├─ Start app with java -jar
  └─ Wait for startup (port listen check)
       │
       ▼
For each test case (status = "data_inserted"):
  ├─ Construct request body from 输入参数.fields
  ├─ curl POST/GET to endpoint
  ├─ Validate response:
  │   ├─ HTTP 200 + code=200 → PASS
  │   ├─ HTTP 200 + code!=200 → FAIL (business error)
  │   ├─ HTTP 500 → FAIL (server error)
  │   └─ timeout (10s) → FAIL (timeout)
  ├─ Update test-spec JSON:
  │   ├─ 实际结果 = "PASS" or "FAIL"
  │   ├─ 原因 = error message if FAIL
  │   └─ status = "completed"
  └─ Record result in testResults[]
       │
       ▼
If test FAIL + Service layer + diff ≤5 lines:
  ├─ auto-fix.sh: AI analyze error, generate fix
  ├─ User confirmation before applying
  ├─ Apply fix to source file
  └─ Retry test after fix
       │
       ▼
Generate test report:
  ├─ {PROJECT_ROOT}/.auto-test/test-reports/{timestamp}.md
  └─ {PROJECT_ROOT}/.auto-test/test-reports/{timestamp}-fixes.md
```

## Scripts

| Script | Purpose |
|--------|---------|
| `run-test.sh` | Main orchestration: mvn package, jar find, app start, curl test, report |
| `auto-fix.sh` | AI analyze test failure, generate fix for ≤5 line bugs |

## Port Conflict Handling

```bash
# Check if port is in use
lsof -i :${port} | grep LISTEN

# Kill existing process
lsof -ti :${port} | xargs kill -9

# Retry start (max 3 attempts)
for i in {1..3}; do
  java -jar ${jar_file} --server.port=${port}
  if port_listen_check; then break; fi
  kill -9 $!
done
```

## Curl Test Validation

| Response | Interpretation |
|----------|----------------|
| HTTP 200 + `code=200` or `success=true` | PASS |
| HTTP 200 + `code!=200` or `success=false` | FAIL (business error) |
| HTTP 500 | FAIL (server error) |
| HTTP timeout (>10s) | FAIL (timeout) |

Response body parsing:
```bash
# Extract code from JSON response
echo "$response" | jq -r '.code // .success // empty'
```

## Auto-fix Scope

**Included:**
- Service layer direct fixes (logic errors, null checks, etc.)
- Diff ≤5 lines

**Excluded:**
- Controller parameter validation
- Transaction issues
- Database connection problems
- Feign client timeouts
- Diff >5 lines

**Flow:**
1. AI analyzes error message + source code
2. AI generates diff patch
3. User confirms before applying
4. Fix applied to source file
5. Retry test

## Test Report Format

Path: `{PROJECT_ROOT}/.auto-test/test-reports/{timestamp}.md`

```markdown
# Test Report

**Generated:** {timestamp}
**Project:** yl-jms-spmibill-capacity
**Total:** {N} | **Passed:** {N} | **Failed:** {N} | **Skipped:** {N}

## Summary

| Test Case | Endpoint | Method | Status | Duration |
|-----------|----------|--------|--------|----------|
| ... | ... | ... | PASS/FAIL | ... |

## Failure Details

{template for failed tests with error messages}
```

## Fix Log Format

Path: `{PROJECT_ROOT}/.auto-test/test-reports/{timestamp}-fixes.md`

```markdown
# Fix Log

**Generated:** {timestamp}

## Fixes Applied

### {testCaseId}: {issue description}
- **File:** {file path}
- **Line:** {line number}
- **Diff:** {N} lines
- **Before:**
```diff
- removed line
+ added line
```
- **After:** Test re-run result

## Skipped Fixes

{template for fixes not applied or exceeding diff threshold}
```

## State Schema Extensions

Phase 3 extends Phase 2 schema with:

```json
{
  "phase": "phase3_in_progress",
  "testResults": {
    "timestamp": "2026-04-19T10:30:00Z",
    "summary": {
      "total": 10,
      "passed": 8,
      "failed": 2,
      "skipped": 0,
      "durationMs": 45000
    },
    "details": [{
      "testCaseId": "test-001",
      "endpoint": "/lockBatch",
      "method": "POST",
      "status": "PASS|FAIL|SKIP",
      "httpStatus": 200,
      "responseTimeMs": 150,
      "errorMessage": null,
      "fixApplied": false
    }]
  },
  "fixes": [{
    "testCaseId": "test-001",
    "file": "/path/to/Service.java",
    "lineNumber": 42,
    "issue": "Null pointer on missing param",
    "diffLines": 3,
    "before": "...",
    "after": "...",
    "status": "applied|skipped|failed",
    "testResultAfterFix": "PASS"
  }]
}
```

## File Structure

```
~/.claude/skills/auto-test-run/
├── SKILL.md              # This file - skill entry point
├── state-schema.json     # Extended schema with testResults and fixes
├── run-test.sh           # Main orchestration script
└── auto-fix.sh           # ≤5 line bug auto-fix
```

## Prerequisites Check

Before running, verify:
```bash
# Phase 1/2 test-spec JSON exists
ls -t {PROJECT_ROOT}/.auto-test/test-spec-*.json

# Test cases have status = "data_inserted" (Phase 2 completed)
jq '[.testCases[] | select(.status == "data_inserted")] | length' test-spec-*.json

# Maven available
mvn -version

# Java available
java -version
```

## Architecture Pattern

Following Phase 1/2 patterns:
- **bash scripts** handle build, startup, testing orchestration
- **AI assistance** for error analysis and fix generation
- **User confirmation** before applying auto-fixes
- **test-spec-{controller}.json** stores test results (实际结果, 原因, status=completed) and fix logs

## Key Differences from Phase 1/2

| Aspect | Phase 1/2 | Phase 3 |
|--------|-----------|---------|
| User interaction | Multiple confirmations | Only for auto-fix |
| Test execution | User manually runs | Automated via curl |
| Failure handling | User fixes | AI auto-fix (≤5 lines) |
| Report output | None | Markdown reports |
| State updates | test-spec JSON with status changes | test-spec JSON with 实际结果, 原因, status=completed |
