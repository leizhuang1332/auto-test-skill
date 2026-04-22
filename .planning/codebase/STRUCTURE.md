# Codebase Structure

**Analysis Date:** 2026-04-22

## Directory Layout

```
auto-test-skill/                    # Project root - Claude Code Skill for automated Spring Boot testing
├── .auto-test/                     # (Runtime) Output directory created at PROJECT_ROOT of target app
│   ├── test-spec-*.json            # Phase 1 output: JSON test spec (source of truth)
│   ├── test-spec-*.md              # Phase 1 output: Markdown report
│   ├── requirements-*.json         # Phase 1 output: Requirements Q&A answers
│   ├── insert-templates/           # Phase 2: INSERT SQL template files
│   ├── test-reports/               # Phase 3: Test result reports + fix logs
│   ├── backups/                    # Phase 3: Auto-fix file backups
│   └── execute-insert.log          # Phase 2: INSERT execution audit log
├── auto-test/                      # Phase 4: Pipeline orchestration skill
│   ├── SKILL.md                    # Skill definition + pipeline documentation
│   └── auto-test.sh                # Pipeline coordinator script
├── auto-test-gen/                  # Phase 1: Test generation skill
│   ├── SKILL.md                    # Skill definition + data flow documentation
│   ├── state-schema.json           # JSON Schema (draft-07) for test-spec format
│   ├── parse-input.sh              # Input parser (4 formats: Controller, method, branch, commit)
│   ├── requirements-clarification.sh # Interactive 5-question Q&A for requirements
│   ├── extract-methods.sh          # Controller method + HTTP annotation extraction (Python3)
│   ├── extract-dto.sh              # DTO class extraction from method signatures (Python3)
│   ├── extract-feign.sh            # FeignClient extraction from @Autowired/@FeignClient (Bash)
│   ├── gen-test-spec.sh            # Main Phase 1 orchestrator: builds AI prompt, writes JSON
│   └── gen-test-class.sh           # JUnit5 test class generator (alternative/legacy approach)
├── auto-test-data/                 # Phase 2: Test data preparation skill
│   ├── SKILL.md                    # Skill definition + entity identification rules
│   ├── state-schema.json           # JSON Schema extension for Phase 2 fields
│   ├── identify-entity.sh          # DTO -> Entity mapping (annotation scan, naming inference)
│   ├── gen-insert.sh               # INSERT SQL template generator with #{varName} placeholders
│   └── execute-insert.sh           # MCP-based INSERT execution with user confirmation
├── auto-test-run/                  # Phase 3: Test execution skill
│   ├── SKILL.md                    # Skill definition + curl validation rules + auto-fix scope
│   ├── state-schema.json           # JSON Schema extension for Phase 3 fields
│   ├── run-test.sh                 # Main Phase 3 orchestrator: build, start, test, report
│   └── auto-fix.sh                 # Service-layer bug fix analyzer (<=5 line diff)
└── README.md                       # Project overview, installation, usage, pipeline docs
```

## Directory Purposes

**`auto-test/`:**
- Purpose: Pipeline orchestration (Phase 4); chains Phase 1 -> 2 -> 3 into a single invocation
- Contains: 1 skill definition file, 1 bash script
- Key files: `auto-test.sh` (pipeline coordinator with `run_phase1()`, `run_phase2()`, `run_phase3()`)

**`auto-test-gen/`:**
- Purpose: Test case generation (Phase 1); parse input, extract metadata, AI-generate test spec
- Contains: 1 skill definition, 1 JSON schema, 7 bash scripts (2 embed Python3)
- Key files: `gen-test-spec.sh` (main orchestrator), `parse-input.sh` (input router), `state-schema.json` (contract)

**`auto-test-data/`:**
- Purpose: Test data preparation (Phase 2); map DTOs to Entities, generate INSERT SQL, execute via MCP
- Contains: 1 skill definition, 1 JSON schema, 3 bash scripts
- Key files: `identify-entity.sh` (3-tier entity resolution), `execute-insert.sh` (MCP bridge)

**`auto-test-run/`:**
- Purpose: Test execution (Phase 3); build, start app, curl endpoints, auto-fix, report
- Contains: 1 skill definition, 1 JSON schema, 2 bash scripts
- Key files: `run-test.sh` (full test lifecycle), `auto-fix.sh` (bounded bug fixer)

**`.planning/codebase/`:**
- Purpose: Codebase analysis documents (this file and companions)
- Contains: Architecture, structure, conventions, testing, concerns documents
- Generated: Yes (by GSD mapping tools)
- Committed: Yes

## Key File Locations

**Entry Points:**
- `auto-test/auto-test.sh`: Full pipeline entry point (`/auto-test <input>`)
- `auto-test-gen/gen-test-spec.sh`: Phase 1 standalone entry point (`/auto-test-gen <input>`)
- `auto-test-data/identify-entity.sh`: Phase 2 standalone entry point (`/auto-test-data <controller>`)
- `auto-test-run/run-test.sh`: Phase 3 standalone entry point (`/auto-test-run`)

**Configuration:**
- `auto-test-gen/state-schema.json`: JSON Schema for test-spec format (v1.0, 244 lines)
- `auto-test-data/state-schema.json`: JSON Schema extension for Phase 2 fields (v2.0, 267 lines)
- `auto-test-run/state-schema.json`: JSON Schema extension for Phase 3 fields (v3.0, 227 lines)

**Core Logic:**
- `auto-test-gen/parse-input.sh`: 4-case input router (Controller, Controller.method, git branch, git commit)
- `auto-test-gen/extract-methods.sh`: Python3 embedded script for @RequestMapping parsing
- `auto-test-gen/extract-dto.sh`: Python3 embedded script for DTO type resolution from method signatures
- `auto-test-gen/extract-feign.sh`: Bash script for @Autowired/@FeignClient field extraction
- `auto-test-data/identify-entity.sh`: 3-tier Entity resolution (annotation -> naming -> DB reverse)
- `auto-test-data/gen-insert.sh`: INSERT template generator with camelCase-to-snake_case conversion
- `auto-test-run/run-test.sh`: Full lifecycle script (735 lines) with Maven build, port management, curl testing, report generation
- `auto-test-run/auto-fix.sh`: Stack trace parser + AI prompt builder for Service-layer fixes

**Skill Definitions:**
- `auto-test/SKILL.md`: Pipeline orchestration docs (123 lines)
- `auto-test-gen/SKILL.md`: Phase 1 data flow + input formats + JSON schema (178 lines)
- `auto-test-data/SKILL.md`: Phase 2 entity rules + INSERT format + confirmation flow (163 lines)
- `auto-test-run/SKILL.md`: Phase 3 curl validation + auto-fix scope + report format (275 lines)

## Naming Conventions

**Files:**
- Skill directories: `auto-test-{phase}` (kebab-case, prefixed with `auto-test`)
- SKILL files: `SKILL.md` (uppercase, standard Claude Code skill definition)
- Shell scripts: `kebab-case.sh` (e.g., `parse-input.sh`, `gen-test-spec.sh`, `auto-fix.sh`)
- State schemas: `state-schema.json` (same name in each skill directory)
- Output files: `test-spec-{controller}-{timestamp}.json` (kebab-case with controller name and timestamp)
- Timestamp format in filenames: `%Y%m%d_%H%M%S` (e.g., `20260422_103000`)
- Test IDs: `TC001`, `TC002` (TC prefix + 3-digit zero-padded number)

**Directories:**
- Skill directories: `auto-test`, `auto-test-gen`, `auto-test-data`, `auto-test-run`
- Runtime output: `.auto-test/` (hidden directory at target project root)
- Subdirectories under `.auto-test/`: `insert-templates/`, `test-reports/`, `backups/`

**JSON Field Names:**
- English fields: `camelCase` (e.g., `controllerPath`, `entityClass`, `insertTemplate`, `testResults`)
- Chinese fields: literal Chinese characters (e.g., `功能`, `数据边界`, `输入参数`, `预期返回结果`, `实际结果`, `原因`)
- Mixed convention is intentional: English for structural/machine fields, Chinese for business-semantic fields

## Where to Add New Code

**New Input Format (Phase 1):**
- Add a new case block in `auto-test-gen/parse-input.sh` (follow the existing if/elif pattern)
- Update the input format table in `auto-test-gen/SKILL.md`
- Update `auto-test/SKILL.md` input section

**New Extraction Script (Phase 1):**
- Add script to `auto-test-gen/` directory
- Follow naming pattern: `extract-{what}.sh`
- Call it from `gen-test-spec.sh` in the `extract_metadata()` function
- Output should be JSON to stdout

**New Entity Identification Method (Phase 2):**
- Add function to `auto-test-data/identify-entity.sh`
- Follow the priority pattern: add to the `identify_entity()` function after existing methods
- Return format: `path|tableName|method|confidence`
- Update `state-schema.json` `entityIdentificationMethodEnum` with new method name

**New Test Validation Rule (Phase 3):**
- Modify the `test_endpoint()` function in `auto-test-run/run-test.sh`
- Add to the PASS/FAIL determination logic block
- Update the validation table in `auto-test-run/SKILL.md`

**New Auto-Fix Scope:**
- Modify `is_service_layer()` in `auto-test-run/auto-fix.sh`
- Adjust `MAX_DIFF_LINES` constant (currently 5)
- Update the included/excluded lists in `auto-test-run/SKILL.md`

**New Pipeline Phase:**
- Create new `auto-test-{name}/` directory with `SKILL.md` + scripts + `state-schema.json`
- Add Phase 4/5 transition in `auto-test/SKILL.md`
- Add `run_phaseN()` function in `auto-test/auto-test.sh`
- Extend `phaseEnum` in all `state-schema.json` files

**Utilities:**
- Shared helpers: No shared utility directory exists. Each script is self-contained.
- Common patterns (`log_info`, `find_test_spec`, `jq` updates) are duplicated across scripts.
- If adding shared utilities, create a `shared/` directory and source from each script.

## Special Directories

**`.auto-test/` (Runtime Output):**
- Purpose: All pipeline artifacts are stored here at the target project's root
- Generated: Yes (created by `ensure_auto_test_dir()` in `auto-test.sh`)
- Committed: No (should be in `.gitignore` of target project)
- Subdirectories: `insert-templates/`, `test-reports/`, `backups/`
- Contains the test-spec JSON that accumulates state across all phases

**`~/.claude/skills/` (Installation Target):**
- Purpose: Where skills are installed for Claude Code to discover them
- Generated: No (manual copy during installation)
- Committed: No (outside this repository)
- Structure mirrors this repo: `~/.claude/skills/auto-test/`, `~/.claude/skills/auto-test-gen/`, etc.
- Installation: `cp auto-test/ ~/.claude/skill/` etc. (per README.md)

**`.omc/` (OMC State):**
- Purpose: Oh-my-claudecode orchestration state (sessions, mission state, agent replay)
- Generated: Yes (by OMC framework)
- Committed: No (runtime state, appears as untracked in git)
- Not part of the skill codebase

**`.planning/` (GSD Planning):**
- Purpose: GSD workflow planning documents (codebase maps, phase plans)
- Generated: Yes (by GSD tools)
- Committed: Yes

## File Relationships

**Script Calling Chain (Full Pipeline):**
```
auto-test.sh
  ├── parse-input.sh          (Phase 1, standalone)
  ├── requirements-clarification.sh  (Phase 1, standalone)
  ├── extract-methods.sh      (Phase 1, called by gen-test-spec.sh)
  ├── extract-dto.sh          (Phase 1, called by gen-test-spec.sh)
  ├── extract-feign.sh        (Phase 1, called by gen-test-spec.sh)
  ├── gen-test-spec.sh        (Phase 1, calls extract-* above, writes test-spec JSON)
  ├── identify-entity.sh      (Phase 2, reads test-spec JSON, adds entityClass)
  ├── gen-insert.sh           (Phase 2, reads test-spec JSON, adds insertTemplate)
  ├── execute-insert.sh       (Phase 2, reads test-spec JSON, updates status)
  ├── run-test.sh             (Phase 3, reads test-spec JSON, runs curl tests)
  │   └── auto-fix.sh         (Phase 3, called by run-test.sh on FAIL)
  └── gen-test-class.sh       (Phase 1, alternative JUnit5 generator, reads state.json)
```

**Data File Dependencies:**
```
SKILL.md files:
  auto-test/SKILL.md          -> references all 3 sub-skills
  auto-test-gen/SKILL.md      -> references all scripts in auto-test-gen/
  auto-test-data/SKILL.md     -> references all scripts in auto-test-data/
  auto-test-run/SKILL.md      -> references all scripts in auto-test-run/

state-schema.json files:
  auto-test-gen/state-schema.json   -> defines base test-spec format (v1.0)
  auto-test-data/state-schema.json  -> extends with Entity/INSERT fields (v2.0)
  auto-test-run/state-schema.json   -> extends with testResults/fixes fields (v3.0)

Runtime data flow:
  requirements-{ts}.json       <- requirements-clarification.sh -> gen-test-spec.sh
  test-spec-{controller}-{ts}.json <- gen-test-spec.sh -> identify-entity.sh -> gen-insert.sh -> execute-insert.sh -> run-test.sh
  test-reports/{ts}_report.md  <- run-test.sh
  test-reports/{ts}_fixes.md   <- run-test.sh (via auto-fix.sh)
  test-reports/fixes.jsonl     <- auto-fix.sh (append-only log)
  backups/{file}_{ts}.bak      <- auto-fix.sh (before applying fix)
```

---

*Structure analysis: 2026-04-22*
