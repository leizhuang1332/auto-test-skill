# Auto-Test Pipeline Skill

## Problem Statement

Java 开发工程师在 Spring Boot + Maven 项目中自测耗时长。当前痛点：
- 测试数据准备繁琐（需要手动造数据）
- Controller 接口测试涉及 Feign 外部服务调用，Mock 配置复杂
- 测试流程无法自动化，每次自测都要手动跑 maven、启动应用、用 curl 测试

## What Makes This Cool

一条命令 `/auto-test` 完成：生成测试用例 → 生成测试数据 → 自动编译打包 → 启动应用 → curl 测试接口 → 自动修复小错误 → 输出测试报告。整个过程无需人工介入，AI 自动驾驶。

## Install

```
# clone this repo to local

cd auto-test

cp auto-test/ ~/.claude/skill/
cp auto-test-data/ ~/.claude/skill/
cp auto-test-gen/ ~/.claude/skill/
cp auto-test-run/ ~/.claude/skill/
```
重启 claude 后，即可使用 /auto-test 命令
```
/auto-test <input>
```

## Constraints

- 技术栈：Spring Boot + Maven + Apollo 配置中心
- 测试框架：纯 curl HTTP 测试（Phase 3），无 JUnit5 生成
- 数据库：真实 MySQL（Phase 2 直连插入）
- HTTP 服务：Feign Stub 真实存在（从 application.yml 或 Apollo 读取 stub 配置）
- 目标接口：Controller 层 HTTP 接口

## Input Specification

| 输入格式 | 示例 | 说明 |
|---------|------|------|
| `<*Controller>` | `SpmiCapacityBillController` | 测试某个 Controller 的所有接口 |
| `<*Controller.*Method()>` | `SpmiCapacityBillController.create()` | 测试指定方法 |
| `测试 <git branch>` | `测试 leizhuang/feature-xxx` | 测试分支所有提交涉及的代码 |
| `测试 <git commit>` | `测试 432b3e3` | 测试指定 commit 涉及的代码 |

## Output Specification

| 输出文件 | 路径 | 说明 |
|---------|------|------|
| 测试规格 JSON | `{PROJECT_ROOT}/.auto-test/test-spec-{controller}-{timestamp}.json` | Phase 1 输出，Phase 2/3 的数据源 |
| 测试报告 | `{PROJECT_ROOT}/.auto-test/test-reports/{timestamp}.md` | 测试结果汇总 |
| 修复日志 | `{PROJECT_ROOT}/.auto-test/backups/` | 自动修复备份 |

## Pipeline Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                         /auto-test                                  │
│                    (完整 pipeline 入口)                              │
└─────────────────────────────────────────────────────────────────────┘
         │                    │                    │
         ▼                    ▼                    ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│ /auto-test-gen  │  │ /auto-test-data │  │ /auto-test-run  │
│   Phase 1       │→ │   Phase 2       │→ │   Phase 3       │
│ 生成测试规格     │  │ 生成测试数据     │  │ 执行测试         │
└─────────────────┘  └─────────────────┘  └─────────────────┘
         │                    │                    │
         └──────────┬──────────┴──────────┘
                    ▼
          {PROJECT_ROOT}/.auto-test/
          test-spec-{controller}-{timestamp}.json  ← 阶段间共享数据
```

**三种调用方式：**
- `/auto-test <input>` — 一键跑完完整 pipeline
- `/auto-test-gen <input>` — 只跑 Phase 1
- `/auto-test-data` — 只跑 Phase 2（依赖 test-spec JSON）
- `/auto-test-run` — 只跑 Phase 3（依赖 test-spec JSON）

## Phase 1: 生成测试规格 (auto-test-gen)

### 输入解析

1. 解析用户输入，识别类型：
   - `*Controller` → 扫描该 Controller 所有 public 方法
   - `*Controller.*Method()` → 扫描指定方法
   - `测试 <branch>` → `git diff origin/main...<branch>` 找到改动的 Java 文件
   - `测试 <commit>` → `git show <commit> --name-only` 找到改动的 Java 文件

2. 对于每个目标方法：
   - 提取方法签名（参数类型、返回值）
   - 分析 RequestBody 参数的 DTO 类
   - 识别该 Controller 依赖的 Service/Feign 层

### 测试规格生成

为每个接口方法生成 JSON 测试规格：

```json
{
  "id": "TC001",
  "method": "getPages",
  "methodSignature": "Result<Page<XXXVo>> getPages(XXXQueryDTO dto)",
  "功能": "分页获取XXX列表",
  "数据边界": "正常分页查询：page=1, size=10",
  "输入参数": {
    "dtoClass": "XXXQueryDTO",
    "fields": [
      {"name": "billMonth", "type": "String", "value": "2026-03", "description": "账单月份"}
    ]
  },
  "预期返回结果": {
    "code": 200,
    "message": "success",
    "data": {"records": [], "total": 0}
  },
  "实际结果": null,
  "原因": null,
  "dtoClasses": [{"name": "XXXQueryDTO", "path": "/path/to/XXXQueryDTO.java"}],
  "feignMocks": [],
  "status": "pending"
}
```

### 用户确认流程

生成测试规格后，显示给用户确认：
- 列出所有将测试的接口
- 显示测试规格摘要
- 用户确认后才写入 `{PROJECT_ROOT}/.auto-test/test-spec-{controller}-{timestamp}.json`

### test-spec JSON Schema

```json
{
  "version": "1.0",
  "project": "yl-jms-spmibill-capacity",
  "createdAt": "2026-04-20T10:00:00",
  "controller": "SpmiCapacityBillController",
  "controllerPath": "/path/to/Controller.java",
  "phase": "phase1_completed",
  "requirements": {
    "businessContext": "业务背景描述",
    "dataBoundaries": ["边界1", "边界2"],
    "externalDependencies": ["FeignClient1"],
    "commonBugs": ["常见bug1"],
    "priority": {"TC001": "blocking", "TC002": "nice-to-have"}
  },
  "testCases": [
    {
      "id": "TC001",
      "method": "methodName",
      "methodSignature": "Result<Type> methodName(ParamType)",
      "功能": "功能描述（中文）",
      "数据边界": "数据边界描述（中文）",
      "输入参数": {
        "dtoClass": "DTOClassName",
        "fields": [
          {"name": "fieldName", "type": "FieldType", "value": "testValue", "description": "字段描述"}
        ]
      },
      "预期返回结果": {"code": 200, "message": "success", "data": {}},
      "实际结果": null,
      "原因": null,
      "dtoClasses": [{"name": "DTOClassName", "path": "/path/to/DTO.java"}],
      "entityClass": {
        "name": "EntityName",
        "path": "/path/to/Entity.java",
        "tableName": "table_name",
        "identificationMethod": "annotation|naming_inference|manual",
        "confidence": 0.95
      },
      "feignMocks": [],
      "status": "pending"
    }
  ]
}
```

## Phase 2: 生成测试数据 (auto-test-data)

### Entity 识别

1. 从 Phase 1 的 testCases 中提取所有 dtoClasses
2. 追踪 DTO 的关联 Entity（通过 Service 实现分析）
3. 对每个 Entity 生成 INSERT 模板

**识别优先级（依次尝试）：**
1. **注解扫描**：查找源码中带 `@Entity`、`@Table` 注解的类
2. **命名推断**：`*DTO` → 去掉 DTO 后缀，查 `*Entity`、`*DO` 是否存在
3. **数据库逆向**：直接连库 `SHOW TABLES`（可选）

### 数据模板生成

为每个 Entity 生成 INSERT 语句模板：

```sql
-- SpiCapacityBill
INSERT INTO spmi_capacity_bill (
  id, bill_no, carrier_id, carrier_name,
  create_time, update_time, status
) VALUES (
  #{id}, #{billNo}, #{carrierId}, #{carrierName},
  NOW(), NOW(), 'DRAFT'
);
```

变量用 `#{varName}` 占位。

### MCP 执行插入

- 使用 JDBC 直连（读取 `application.yml` 的数据库配置）
- **使用专用测试库账号**（只读权限/测试库），避免污染生产数据
- 按依赖顺序插入（先主表后从表）
- MCP 执行结果更新到 test-spec JSON

**test-spec JSON 更新：**
```json
{
  "phase": "phase2_completed",
  "testCases": [
    {
      "id": "TC001",
      "status": "data_inserted",
      "entityClass": {
        "name": "SpmiCapacityBill",
        "tableName": "spmi_capacity_bill",
        "insertSql": "INSERT INTO spmi_capacity_bill ..."
      }
    }
  ]
}
```

## Phase 3: 执行测试 (auto-test-run)

### Step 1: 编译打包

```bash
cd <project-root>
mvn clean package -DskipTests
```

**错误处理：**
- 构建失败 → 记录错误到报告，pipeline 中止
- 构建成功但无 jar 文件 → 记录错误，上报用户

### Step 2: 启动应用

**启动命令：**
```bash
java -jar target/<app-name>.jar --spring.profiles.active=test
```

**端口占用处理：**
```bash
lsof -i :${port} | grep LISTEN
lsof -ti :${port} | xargs kill -9
java -jar target/<app-name>.jar --spring.profiles.active=test
```

### Step 3: 读取配置

从 `application.yml` 提取：
- `spring.application.name`
- `server.port`
- `server.servlet.context-path`

拼接 base URL：`http://localhost:${port}${context-path}`

### Step 4: 执行 curl 测试

从 test-spec JSON 读取测试用例，逐个执行：

```bash
# 构造请求体
BODY='{"billMonth":"2026-03","carrierId":1,"current":1,"size":10}'

# 执行 curl
curl -X POST http://localhost:8080/spmi/capacity/bill/pages \
  -H "Content-Type: application/json" \
  -d "$BODY"
```

**预期响应判断：**
- HTTP 200 + 业务 code=200 → PASS
- HTTP 200 + 业务 code≠200 → FAIL（业务错误）
- HTTP 500 → FAIL（服务器错误）
- HTTP 超时 → FAIL（超时）

### Step 5: 自动修复（小改动）

如果测试失败，尝试自动修复：

**修复策略：**
1. 分析错误日志，定位 StackTrace 中的源码文件和行号
2. 判断改动范围（基于 diff 行数）：
   - ≤5 行 diff → 自动修复
   - >5 行 diff → 记录到 fixes.md，跳过该测试
3. 常见小改动场景：
   - 空指针：加 null check（1-2 行）
   - 缺少字段：补充字段赋值（1-3 行）
   - 边界条件：调整判断条件（1-2 行）

**自动修复前**，将原文件备份到 `{PROJECT_ROOT}/.auto-test/backups/`。

### Step 6: 输出报告

**测试报告 `{PROJECT_ROOT}/.auto-test/test-reports/{timestamp}.md`：**
```markdown
# Auto-Test Report

## 测试概要
- 输入: SpmiCapacityBillController
- 时间: 2026-04-20 10:00:00
- 总测试数: 12
- 通过: 10
- 失败: 2

## 详细结果

| ID | 接口 | 方法 | 状态 | 耗时 |
|----|------|------|------|------|
| TC001 | /spmi/capacity/bill/pages | POST | PASS | 120ms |
| TC002 | /spmi/capacity/bill/pages | POST | FAIL | 80ms |

## 失败详情

### TC002: /spmi/capacity/bill/pages
- 错误: HTTP 500
- 原因: NullPointerException at BillService.java:42
```

## Skill 文件结构

```
~/.claude/skills/
├── auto-test/
│   └── SKILL.md              # Pipeline 编排脚本 (auto-test.sh)
├── auto-test-gen/
│   ├── SKILL.md              # Phase 1 说明
│   ├── parse-input.sh         # 输入解析
│   ├── extract-methods.sh     # 提取 Controller 方法
│   ├── extract-dto.sh        # 提取 DTO 类
│   ├── extract-feign.sh      # 提取 FeignClient
│   ├── requirements-clarification.sh  # Q&A 需求确认
│   ├── gen-test-spec.sh      # 生成 test-spec JSON
│   └── state-schema.json      # test-spec JSON Schema
├── auto-test-data/
│   ├── SKILL.md              # Phase 2 说明
│   ├── identify-entity.sh     # Entity 识别
│   ├── gen-insert.sh         # 生成 INSERT 模板
│   ├── execute-insert.sh      # MCP 执行插入
│   └── state-schema.json      # INSERT 模板 Schema
├── auto-test-run/
│   ├── SKILL.md              # Phase 3 说明
│   ├── run-test.sh           # 执行 curl 测试
│   ├── auto-fix.sh          # 自动修复脚本
│   └── state-schema.json      # 测试报告 Schema
└── shared/
    └── (无共享文件，通过 .auto-test/ 目录传递数据)
```

## Success Criteria

- 用户输入 `SpmiCapacityBillController` 后，自动完成：测试规格生成 → 数据插入 → 编译启动 → 接口测试 → 报告输出
- Phase 1/2 需要用户确认后继续（不是完全无人介入）
- 测试失败时，自动修复 ≤5 行 diff 的 Bug；超过阈值则跳过
- 端口占用时自动 kill 并重试
- Maven 构建失败时记录错误并上报，不卡死流程

## Distribution Plan

以 Claude Code Skill 发布，调用方式：
```bash
/auto-test SpmiCapacityBillController
/auto-test SpmiCapacityBillController.create
/auto-test 测试 leizhuang/feature-xxx
/auto-test 测试 432b3e3
```

Phase 独立调用：
```bash
/auto-test-gen SpmiCapacityBillController  # 只生成测试规格
/auto-test-data                             # 只生成数据（依赖 test-spec JSON）
/auto-test-run                              # 只执行测试（依赖 test-spec JSON）
```

## 实现状态

| Phase | 脚本 | 状态 | 说明 |
|-------|------|------|------|
| Phase 1 | parse-input.sh | ✅ 完成 | |
| Phase 1 | extract-methods.sh | ✅ 完成 | |
| Phase 1 | extract-dto.sh | ✅ 完成 | |
| Phase 1 | gen-test-spec.sh | ✅ 完成 | |
| Phase 2 | identify-entity.sh | ✅ 完成 | |
| Phase 2 | gen-insert.sh | ✅ 完成 | |
| Phase 2 | execute-insert.sh | ✅ 完成 | |
| Phase 3 | run-test.sh | ✅ 完成 | |
| Phase 3 | auto-fix.sh | ✅ 完成 | |
| Pipeline | auto-test.sh | ✅ 完成 | 串联三个 Phase |