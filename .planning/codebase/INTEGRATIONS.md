# External Integrations

**Analysis Date:** 2026-04-22

## APIs & External Services

**Spring Boot Application (Target):**
- The skill operates on a running Spring Boot application
- Phase 3 starts the app via `java -jar target/{app}.jar --spring.profiles.active=test`
- Endpoints tested via curl HTTP requests to `http://localhost:${port}${context-path}`
- No SDK/client library; direct HTTP via curl

**Apollo Configuration Center:**
- Referenced in constraints as externalized configuration provider
- Not directly integrated by the skill scripts
- Application reads Apollo config at runtime; the skill reads `application.yml` for database and server config instead

## Data Storage

**Databases:**
- MySQL - Target application database
  - Connection: env vars (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`) or parsed from `application.yml` (`spring.datasource.url`)
  - Client: MCP (Model Context Protocol) for INSERT execution; fallback to `mysql` CLI for testing
  - Used in Phase 2 for test data insertion via `execute-insert.sh`
  - JDBC URL pattern parsed: `jdbc:mysql://host:port/database`
  - Safety: warns on non-localhost connections (`check_db_safety()` in `execute-insert.sh`)

**File Storage:**
- Local filesystem only - All artifacts stored in `{PROJECT_ROOT}/.auto-test/` directory
  - `test-spec-{controller}-{timestamp}.json` - Phase 1 output (source of truth)
  - `test-spec-{controller}-{timestamp}.md` - Phase 1 markdown report
  - `requirements-{timestamp}.json` - Phase 1 requirements Q&A output
  - `insert-templates/` - Phase 2 INSERT SQL templates
  - `test-reports/` - Phase 3 test report markdown files
  - `backups/` - Phase 3 auto-fix file backups (`.bak` files)

**Caching:**
- None

## Authentication & Identity

**Auth Provider:**
- None (skill itself has no auth)
- Target application auth not handled by the skill; curl tests hit endpoints directly
- Database auth: username/password from env vars or `application.yml`

## Claude Code Skill System Integration

**Skill Registration:**
- Skills are installed to `~/.claude/skills/{skill-name}/`
- Each skill has a `SKILL.md` with YAML frontmatter defining:
  - `name` - Skill trigger name
  - `description` - What the skill does
  - `metadata.author`, `metadata.version`, `metadata.phase`, `metadata.pipeline`
- Skills invoked via `/skill-name` or `skill-name` in Claude Code

**Four Skill Directories:**

| Skill | Path | Phase | Trigger |
|-------|------|-------|---------|
| auto-test | `~/.claude/skills/auto-test/` | Pipeline orchestration | `/auto-test <input>` |
| auto-test-gen | `~/.claude/skills/auto-test-gen/` | Phase 1: Test spec generation | `/auto-test-gen <input>` |
| auto-test-data | `~/.claude/skills/auto-test-data/` | Phase 2: Data insertion | `/auto-test-data` |
| auto-test-run | `~/.claude/skills/auto-test-run/` | Phase 3: Test execution | `/auto-test-run` |

**AI Interaction Points:**
Claude Code's AI is invoked at several points where bash scripts cannot proceed autonomously:

1. **`requirements-clarification.sh`** - Uses `AskUserQuestion` tool for 5 interactive Q&A questions (business context, data boundaries, external dependencies, common bugs, priority)
2. **`gen-test-spec.sh`** - Writes AI prompt to `.auto-test/.gen-test-spec-prompt.txt`; AI generates JSON test spec
3. **`gen-test-class.sh`** - Builds AI prompt for JUnit5 test class generation (legacy/alternative script)
4. **`execute-insert.sh`** - Generates MCP prompt for database INSERT execution; status set to `mcp_required`
5. **`auto-fix.sh`** - Builds AI prompt for bug fix analysis; outputs `ai_fix_needed` status

**Script-AI Handoff Pattern:**
```
Bash script runs → generates prompt file / outputs instruction →
Claude Code reads prompt → AI generates content →
Script reads AI output file / Claude Code writes result →
Script continues
```

## Inter-Phase Data Flow

**Shared Data Contract: `test-spec-{controller}-{timestamp}.json`**

The test-spec JSON file in `{PROJECT_ROOT}/.auto-test/` is the single source of truth connecting all three phases:

```
Phase 1 (auto-test-gen)
  ├─ Writes: test-spec-{controller}-{timestamp}.json
  ├─ Sets: phase = "phase1_completed"
  └─ Sets: testCases[].status = "pending"
       │
Phase 2 (auto-test-data)
  ├─ Reads: testCases[].dtoClasses → identifies Entity classes
  ├─ Reads: testCases[].输入参数 → generates INSERT templates
  ├─ Writes: testCases[].entityClass (Entity identification result)
  ├─ Writes: testCases[].insertTemplate (INSERT SQL)
  ├─ Writes: testCases[].insertStatus = "pending"|"data_inserted"|"failed"
  ├─ Sets: phase = "phase2_completed"
  └─ Sets: testCases[].status = "data_inserted"
       │
Phase 3 (auto-test-run)
  ├─ Reads: testCases[] where status = "data_inserted"
  ├─ Reads: testCases[].输入参数.fields → constructs curl request body
  ├─ Reads: testCases[].method → determines endpoint
  ├─ Writes: testCases[].实际结果 = "PASS"|"FAIL"
  ├─ Writes: testCases[].原因 = error message
  ├─ Writes: testCases[].status = "completed"
  ├─ Sets: phase = "phase3_completed"
  └─ Appends: testResults object + fixes array
```

**Test Case Status Lifecycle:**
```
pending (Phase 1 output)
  → data_inserted (Phase 2 INSERT complete)
  → completed (Phase 3 test executed)
```

**Phase Status Values:**
```
phase1_in_progress → phase1_completed
phase2_in_progress → phase2_completed
phase3_in_progress → phase3_completed / phase3_failed
```

**JSON Schema Validation:**
- Phase 1 schema: `auto-test-gen/state-schema.json` (version 1.0, strict `additionalProperties: false`)
- Phase 2 schema: `auto-test-data/state-schema.json` (version 2.0, `additionalProperties: true`)
- Phase 3 schema: `auto-test-run/state-schema.json` (version 3.0, `additionalProperties: true`)
- Schemas use JSON Schema draft-07 (`$schema: http://json-schema.org/draft-07/schema#`)

## MCP (Model Context Protocol) Usage

**Integration Point: Phase 2 `execute-insert.sh`**
- MCP is used for database INSERT execution
- The script generates an MCP prompt requesting Claude Code to use its MCP mysql tool
- Script creates a temporary `.mcp-insert-XXXXXX.sh` file with instructions
- Actual execution delegated to Claude Code's MCP tools, not performed by the bash script directly
- Status set to `mcp_required` when running outside Claude Code context
- MCP configuration: Claude Code must be configured with a MySQL MCP server (`claude --mcp /path/to/mysql-mcp-server`)

**Integration Point: Phase 1 `requirements-clarification.sh`**
- Uses `AskUserQuestion` tool (Claude Code MCP tool) for interactive Q&A
- Checks `CLAUDE_CODE` env var to determine if running within Claude Code context

**Limitation:**
- MCP database operations cannot be performed directly by bash scripts
- Scripts generate prompts/instructions and delegate to Claude Code runtime
- This creates a dependency on Claude Code for actual database writes and AI generation

## Java Source Code Integration

**Source Scanning (Phase 1):**
- `parse-input.sh` - Finds Controller Java files via `find` + `grep` on the project source tree
- `extract-methods.sh` - Parses `@PostMapping`, `@GetMapping`, `@PutMapping`, `@DeleteMapping` annotations and method signatures from Controller `.java` files (Python 3 inline)
- `extract-dto.sh` - Extracts DTO class names from method signatures, locates DTO `.java` files in `src/main/java/com/yl/spmibill/capacity/dto` and `vo` directories (Python 3 inline)
- `extract-feign.sh` - Scans `@FeignClient` annotations and `@Autowired` Feign fields from Controller source (pure bash)

**Entity Identification (Phase 2):**
- `identify-entity.sh` - Maps DTO classes to Entity classes using:
  1. Annotation scan: `@Entity`, `@Table` on Java source files
  2. Naming inference: `XXXDTO` -> `XXX`, `XXXIdDTO` -> `XXX`, then try `XXXEntity`, `XXXDO`
  3. Database reverse: stub only (not implemented)
- `gen-insert.sh` - Reads Entity `.java` files, extracts `private` field declarations, generates INSERT SQL with `#{varName}` placeholders

**Auto-Fix Integration (Phase 3):**
- `auto-fix.sh` - Parses Java stack traces to locate source file + line number
- Builds AI prompt with surrounding source context (5 lines before, 10 lines after error line)
- Only fixes files matching `SERVICE_LAYER_PATTERN` (`src/main/java/com/yl/spmibill/capacity/service`)
- Backs up original files before modification

## Git Integration

**Input Parsing (`parse-input.sh`):**
- `git rev-parse --show-toplevel` - Project root resolution (used throughout all scripts)
- `git show <commit> --name-only` - Find Controller files changed in a commit
- `git diff origin/main...<branch> --name-only` - Find Controller files changed in a branch
- `git symbolic-ref refs/remotes/origin/HEAD` - Default base branch detection

**Project Root:**
- Nearly every script resolves `PROJECT_ROOT` via `git rev-parse --show-toplevel 2>/dev/null`
- Falls back to `pwd` or empty string on failure

## Feign Client Integration

**Purpose:** Identify external service dependencies for mocking

**Detection Method (Phase 1 `extract-feign.sh`):**
- Method 1: Scans `@FeignClient` annotation on interface declarations in Controller source
- Method 2: Scans `@Autowired` fields containing "Feign" in the type name
- Extracts: Feign client name, package (from imports), field name

**Usage in Pipeline:**
- Phase 1: Feign clients listed in `testCases[].feignMocks` array
- Phase 2: Not directly used
- Phase 3: Feign stubs expected to be available (from `application.yml` or Apollo config); curl tests hit the running application which handles Feign internally

**Constraint:**
- Feign Stub services must be real and accessible at test time
- The skill does NOT generate Feign mocks or stubs itself
- Stub configuration read from application.yml or Apollo at application runtime

## Monitoring & Observability

**Error Tracking:**
- None (no external error tracking service)

**Logs:**
- `execute-insert.sh` writes to `{PROJECT_ROOT}/.auto-test/execute-insert.log`
- `auto-fix.sh` writes fix records to `{PROJECT_ROOT}/.auto-test/test-reports/fixes.jsonl`
- Phase 3 app startup log: `/tmp/app_startup.log`
- Maven build log: `/tmp/mvn_build.log`
- curl responses: `/tmp/curl_response_{test_case_id}_{pid}.json`

## CI/CD & Deployment

**Hosting:**
- Local development machine only (no CI/CD integration)

**CI Pipeline:**
- None

**Distribution:**
- Manual copy to `~/.claude/skills/` directory
- Restart Claude Code required after installation

## Environment Configuration

**Required env vars (for Phase 2 database access):**
- `DB_HOST` - MySQL host (optional, falls back to application.yml)
- `DB_PORT` - MySQL port (default 3306)
- `DB_NAME` - MySQL database name
- `DB_USER` - MySQL username
- `DB_PASSWORD` - MySQL password

**Optional env vars:**
- `CLAUDE_CODE` - Set when running within Claude Code interactive mode

**Secrets location:**
- Database credentials may be in `application.yml` (parsed at runtime)
- No `.env` files used by this skill
- `DB_PASSWORD` env var if set (never logged or echoed)

## Webhooks & Callbacks

**Incoming:**
- None

**Outgoing:**
- None

---

*Integration audit: 2026-04-22*
