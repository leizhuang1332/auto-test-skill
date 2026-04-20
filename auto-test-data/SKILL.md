---
name: auto-test-data
description: Read Phase 1 test-spec-{controller}.json (DTO fields) → identify Entity classes → generate INSERT templates → user confirms → execute INSERT → update test-spec status to data_inserted. Phase 2 of the auto-test pipeline.
metadata:
  author: leizhuang1332
  version: "2.0"
  phase: 2
  pipeline: auto-test
---

# Skill: auto-test-data

**Phase:** Phase 2 only (auto-test-data)
**Purpose:** Read Phase 1 test-spec JSON (DTO fields) → identify Entity classes → generate INSERT templates → user confirms → execute INSERT → update status to data_inserted

## CRITICAL: Phase 1 Output Format

This skill reads from Phase 1 output: `test-spec-{controller}-{timestamp}.json`
**NOT the old state.json architecture.**

## Triggers

- `/auto-test-data <controller-name>` — main entry point (Phase 2)
- `auto-test-data <controller-name>` — alternative invocation

## Input

Reads from Phase 1 output: `{PROJECT_ROOT}/.auto-test/test-spec-{controller}-{timestamp}.json`

- `testCases[].输入参数` — DTO fields for test data construction
- `testCases[].status` — must be `"pending"` (not yet data_inserted) to be processed

Example Phase 1 test-spec format:
```json
{
  "testCases": [
    {
      "id": "TC001",
      "method": "lockBatch",
      "输入参数": {
        "dtoClass": "SpmiCapacityBillIdDTO",
        "fields": [
          { "name": "id", "type": "Long", "value": "1" }
        ]
      },
      "status": "pending"
    }
  ]
}
```

## Output

- **INSERT templates:** shown as markdown for user confirmation
- **Execution results:** stored in test-spec JSON
- **test-spec updates:** `entityClass`, `insertTemplate`, `insertStatus`, `insertResult`
- **Status transition:** `pending` → `data_inserted` after successful INSERT

## Data Flow

```
test-spec-{controller}.json (from Phase 1)
       │
       ▼
identify-entity.sh: DTO → Entity 识别
       │
       ▼
gen-insert.sh: 生成 INSERT 模板
       │
       ▼
execute-insert.sh: 用户确认 → MCP 执行插入
       │
       ▼
test-spec-{controller}.json (updated: status = "data_inserted")
```

## Phase 2 Scripts

| Script | Purpose |
|--------|---------|
| `identify-entity.sh` | Identify Entity class from DTO class (annotation priority, naming inference fallback) |
| `gen-insert.sh` | Generate INSERT SQL template with `#{varName}` placeholders |
| `execute-insert.sh` | User confirmation → MCP executes INSERT → update status |

## Entity Identification Rules

| Priority | Method | Description |
|----------|--------|-------------|
| 1 | Annotation | Look for `@Table`, `@Entity` annotations in same package or related packages |
| 2 | Naming inference | XXXDTO → XXX (e.g., `SpmiCapacityBillIdDTO` → `SpmiCapacityBill`) |
| 3 | Database reverse | Optional: query database table structure |

## INSERT Template Format

Generated INSERT templates use `#{varName}` placeholders:

```sql
INSERT INTO spmi_capacity_bill (id, bill_no, amount, status)
VALUES (#{id}, #{billNo}, #{amount}, #{status});
```

## Confirmation Flow

1. Display INSERT templates as markdown (not yet executed)
2. User reviews templates
3. **On approve:** MCP executes INSERT → update test-spec status
4. **On reject:** Skip this INSERT, move to next

## Database Safety

- **Recommended:** Use dedicated test database account
- **Transaction:** Each INSERT is committed individually
- **Backup:** Consider backing up data before bulk inserts

## Prerequisites

- Phase 1 must be completed (`test-spec-{controller}.json` exists)
- Database connection available
- Test database account with write permissions

## State Schema Extensions

Phase 2 extends Phase 1 test-spec schema with:

```json
{
  "testCases": [{
    "entityClass": {
      "name": "SpmiCapacityBill",
      "path": "/path/SpmiCapacityBill.java",
      "tableName": "spmi_capacity_bill",
      "identificationMethod": "annotation|naming_inference|database_reverse",
      "confidence": 0.95
    },
    "insertTemplate": "INSERT INTO ...",
    "insertStatus": "pending|data_inserted|failed",
    "insertResult": {
      "success": true,
      "error": null,
      "rowsAffected": 1
    }
  }]
}
```

## Architecture Pattern

Following Phase 1 pattern:
- **bash scripts** handle Entity identification and INSERT template generation
- **MCP** executes INSERT after user confirmation
- **test-spec JSON** stores paths and metadata, status transitions tracked

## File Structure

```
~/.claude/skills/auto-test-data/
├── SKILL.md              # This file - skill entry point
├── state-schema.json     # Extended schema with Entity and INSERT fields
├── identify-entity.sh    # DTO → Entity identification
├── gen-insert.sh         # INSERT template generation
└── execute-insert.sh     # User confirmation + MCP execution
```
