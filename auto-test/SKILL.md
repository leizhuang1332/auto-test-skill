---
name: auto-test
description: Orchestrate full pipeline: auto-test-gen → auto-test-data → auto-test-run. Phase 4 (Pipeline Orchestration) chains Phase 1, 2, and 3 together.
metadata:
  author: leizhuang1332
  version: "1.0"
  phase: 4
  pipeline: auto-test
---

# Skill: auto-test

**Phase:** Phase 4 (Pipeline Orchestration)
**Purpose:** Orchestrate full pipeline: auto-test-gen → auto-test-data → auto-test-run

## Triggers

- `/auto-test <input>` — main entry point (full pipeline)
- `auto-test <input>` — alternative invocation

## Input

Same as Phase 1 (auto-test-gen):
- `<*Controller>` — SpmiCapacityBillController
- `<*Controller.*Method()>` — SpmiCapacityBillController.create()
- `测试 <git branch>` — test by branch
- `测试 <git commit>` — test by commit

## Output Directory

All pipeline artifacts are stored in `{PROJECT_ROOT}/.auto-test/`:
```
{PROJECT_ROOT}/.auto-test/
├── test-spec-{controller}-{timestamp}.json   # Phase 1 output
├── test-spec-{controller}-{timestamp}.md   # Phase 1 markdown report
├── requirements-{timestamp}.json            # Phase 1 requirements
├── insert-templates/                         # Phase 2 INSERT templates
├── test-reports/                             # Phase 3 reports
└── backups/                                   # Phase 3 auto-fix backups
```

## Pipeline Flow

```
/auto-test <input>
       │
       ▼
Phase 1: auto-test-gen
  ├─ parse-input.sh → identify Controller
  ├─ requirements-clarification.sh → 5 Q&A questions
  ├─ extract-methods.sh → list methods
  ├─ extract-dto.sh / extract-feign.sh → identify DTOs
  ├─ gen-test-spec.sh → AI generate JSON test spec
  ├─ User confirms → write .auto-test/test-spec-{controller}.json
  └─ test-spec JSON: status=pending
       │
       ▼
Phase 2: auto-test-data
  ├─ identify-entity.sh → DTO → Entity (reads test-spec JSON)
  ├─ gen-insert.sh → INSERT templates (reads test-spec JSON)
  ├─ execute-insert.sh → MCP execute → update status=data_inserted
  └─ test-spec JSON: status=data_inserted
       │
       ▼
Phase 3: auto-test-run
  ├─ verify_insert_status() → check status=data_inserted
  ├─ mvn clean package -DskipTests
  ├─ java -jar → start app
  ├─ curl test each endpoint (reads test-spec JSON)
  ├─ auto-fix.sh on failure (≤5 line bugs)
  ├─ Update test-spec: 实际结果, 原因, status=completed
  └─ Generate test report to .auto-test/test-reports/
```

## Scripts

| Script | Purpose | Location |
|--------|---------|----------|
| auto-test.sh | Pipeline orchestration | This skill |

## Phase Transitions

Phase transitions happen via state.json `phase` field:

| Current Phase | Next Phase | Transition Condition |
|---------------|------------|---------------------|
| phase1_in_progress | phase1_completed | All test cases confirmed and compiled |
| phase2_in_progress | phase2_completed | All INSERTs executed successfully |
| phase3_in_progress | phase3_completed | All tests run and report generated |

## Prerequisites

- Phase 1 requires: Maven, Java 8+, Controller source files
- Phase 2 requires: Phase 1 completed, database connection
- Phase 3 requires: Phase 2 completed, Maven build succeeds

## File Structure

```
~/.claude/skills/auto-test/
├── SKILL.md              # This file - pipeline orchestration
```

## Architecture Pattern

Pipeline orchestration using existing Phase 1/2/3 skills:
- **auto-test-gen** skill handles test case generation
- **auto-test-data** skill handles INSERT data preparation
- **auto-test-run** skill handles test execution
- **auto-test** skill chains them together

## Verification

Run pipeline:
```bash
auto-test SpmiCapacityBillController
```

Expected flow:
1. Phase 1 generates tests
2. Phase 2 generates INSERT data
3. Phase 3 runs tests and generates report
