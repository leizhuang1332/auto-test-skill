---
name: auto-test-gen
description: Parse user input → requirements clarification → scan Controller source → AI generates JSON test spec → user confirms → write test-spec JSON. Phase 1 of the auto-test pipeline.
metadata:
  author: leizhuang1332
  version: "1.0"
  phase: 1
  pipeline: auto-test
---

# Skill: auto-test-gen

**Phase:** Phase 1 only (auto-test-gen)
**Purpose:** Parse user input → requirements clarification → AI generates JSON test spec → user confirms → write test-spec JSON as source of truth for Phase 2/3

## Triggers

- `/auto-test-gen <input>` — main entry point (Phase 1)
- `auto-test-gen <input>` — alternative invocation

## Input Formats (4 types)

| Format | Example | parse-input.sh Logic |
|--------|---------|---------------------|
| `<*Controller>` | `SpmiCapacityBillController` | glob pattern: `find src -name "*Controller.java"` |
| `<*Controller.*Method()>` | `SpmiCapacityBillController.create()` | glob + grep for method signature |
| `测试 <git branch>` | `测试 leizhuang/feature-xxx` | `git diff origin/main...<branch> --name-only \| grep Controller` |
| `测试 <git commit>` | `测试 432b3e3` | `git show <commit> --name-only \| grep Controller` |

## Data Flow (NEW ARCHITECTURE)

```
User input: "SpmiCapacityBillController"
       │
       ▼
parse-input.sh
  ├─ glob "**/SpmiCapacityBillController.java"
  ├─ if method specified: grep method signature
  └─ → { type: "controller", value: "SpmiCapacityBillController", filePath: "/abs/path/Controller.java" }
       │
       ▼
requirements-clarification.sh (NEW - Interactive Q&A)
  ├─ Q1: 业务背景 — 这个接口的业务目的是什么？谁会用？
  ├─ Q2: 数据边界 — 需要覆盖哪些边界情况？（空数据、极限值、特殊状态）
  ├─ Q3: 外部依赖 — 调用了哪些外部服务/Feign？
  ├─ Q4: 常见错误 — 有没有上线后出过的 bug？
  └─ Q5: 优先级 — 哪些用例必须覆盖？
       │
       ▼
extract-methods.sh
  └─ → { methods: [{name, returnType, params, annotations}] }
       │
       ▼
extract-dto.sh + extract-feign.sh
  └─ → { dtos: [...], feignClients: [...] }
       │
       ▼
gen-test-spec.sh: For each method, invoke AI
  → AI reads Controller.java, DTO files, requirements answers
  → AI generates JSON test spec (markdown preview)
       │
       ▼
User confirmation
  → User approves: write test-spec JSON to {PROJECT_ROOT}/.auto-test/...
  → User rejects: skip that test case
       │
       ▼
Phase 2/3 read test-spec JSON, execute their workflows
```

## Scripts

| Script | Purpose |
|--------|---------|
| `parse-input.sh` | Parse user input → identify type + find Controller file |
| `requirements-clarification.sh` | Interactive Q&A with user to gather requirements (NEW) |
| `extract-methods.sh` | Find Controller file → list public methods with signatures |
| `extract-dto.sh` | From method params → find DTO Java files |
| `extract-feign.sh` | From @Autowired fields → list FeignClients |
| `gen-test-spec.sh` | AI generates JSON test spec, user confirms, writes file (NEW) |

## Output Locations

- **JSON test spec:** `{PROJECT_ROOT}/.auto-test/test-spec-{controller}-{timestamp}.json`
- **Markdown report:** `{PROJECT_ROOT}/.auto-test/test-spec-{controller}-{timestamp}.md`

## JSON Test Spec Schema

```json
{
  "version": "1.0",
  "project": "yl-jms-spmibill-capacity",
  "createdAt": "ISO8601",
  "controller": "SpmiCapacityBillController",
  "controllerPath": "/path/to/Controller.java",
  "phase": "phase1_completed",
  "requirements": {
    "businessContext": "业务背景描述",
    "dataBoundaries": ["边界情况1", "边界情况2"],
    "externalDependencies": ["外部服务1", "FeignClient1"],
    "commonBugs": ["历史bug1", "历史bug2"],
    "priority": { "TC001": "blocking", "TC002": "nice-to-have" }
  },
  "testCases": [
    {
      "id": "TC001",
      "method": "lockBatch",
      "methodSignature": "Result<Boolean> lockBatch(BaseQuery<List<SpmiCapacityBillIdDTO>>)",
      "功能": "批量锁定结算单",
      "数据边界": "正常数据：多条有效结算单ID",
      "输入参数": {
        "dtoClass": "SpmiCapacityBillIdDTO",
        "fields": [
          { "name": "id", "type": "Long", "value": "1", "description": "结算单ID" }
        ]
      },
      "预期返回结果": {
        "code": 200,
        "message": "success",
        "data": true
      },
      "实际结果": null,
      "原因": null,
      "dtoClasses": [{ "name": "SpmiCapacityBillIdDTO", "path": "/path/to/DTO.java" }],
      "feignMocks": ["SpmiBillFeignClient"],
      "status": "pending"
    }
  ]
}
```

## Phase 2/3 Contract

- Phase 2 reads `testCases[].status == "pending"`, inserts data to MySQL, updates status to `data_inserted`
- Phase 3 reads `testCases[].status == "data_inserted"`, executes, updates `实际结果` + `原因`

## Confirmation Flow

1. AI generates JSON test spec as markdown preview (not yet written to disk)
2. User reviews the generated spec (functionality, data boundaries, expected results)
3. **On approve:** Write JSON file to `{PROJECT_ROOT}/.auto-test/...`
4. **On reject:** Skip that test case, move to next
5. After all confirmations: generate markdown report alongside JSON

## Test Case Priority Levels

| Priority | Meaning |
|----------|---------|
| `blocking` | Must pass for release (P0 cases) |
| `nice-to-have` | Good coverage but not blocking (P1 cases) |

## Requirements Clarification Questions (NEW)

Before generating test specs, the skill asks:

1. **业务背景 (Business Context):** 这个接口的业务目的是什么？谁会用？
2. **数据边界 (Data Boundaries):** 需要覆盖哪些边界情况？（空数据、极限值、特殊状态）
3. **外部依赖 (External Dependencies):** 调用了哪些外部服务/Feign？
4. **常见错误 (Common Bugs):** 有没有上线后出过的 bug？
5. **优先级 (Priority):** 哪些用例必须覆盖？

## Architecture Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Requirements gathering | Interactive Q&A | Ensures AI has business context before generating specs |
| Output format | JSON test spec | Source of truth for Phase 2 (data insertion) and Phase 3 (execution) |
| Confirmation flow | Show JSON spec first | User validates business logic before file write |
| Phase separation | JSON contract between phases | Phase 2/3 can read status field to track progress |

## File Conflict Handling

If test-spec file already exists: append `_v{n}` suffix (e.g., `test-spec-SpmiCapacityBillController_v1.json`)

## State Idempotency

On re-run: merge `testCases[]` arrays, preserve existing test cases with their status and results.
