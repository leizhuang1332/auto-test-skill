<!-- Generated: 2026-04-22 | Updated: 2026-04-22 -->

# auto-test-skill

## Purpose
A Claude Code Skill project that automates end-to-end testing for Spring Boot + Maven Java applications. Given a Controller name, branch, or commit, it generates test specs, inserts test data into MySQL, builds/starts the app, runs curl-based HTTP tests, auto-fixes small bugs, and outputs reports — all driven by a single `/auto-test` command.

## Key Files

| File | Description |
|------|-------------|
| `README.md` | Full project documentation: problem statement, pipeline architecture, phase specs, input/output formats, success criteria |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `auto-test/` | Pipeline orchestration (Phase 4) — chains Phase 1→2→3 together (see `auto-test/AGENTS.md`) |
| `auto-test-gen/` | Test spec generation (Phase 1) — parse input, clarify requirements, extract methods/DTOs/Feign, generate JSON test spec (see `auto-test-gen/AGENTS.md`) |
| `auto-test-data/` | Test data generation (Phase 2) — identify Entity classes, generate INSERT templates, execute via MCP (see `auto-test-data/AGENTS.md`) |
| `auto-test-run/` | Test execution (Phase 3) — mvn package, start app, curl test endpoints, auto-fix ≤5-line bugs, output reports (see `auto-test-run/AGENTS.md`) |

## For AI Agents

### Working In This Directory
- This is a **Claude Code Skill** project — each subdirectory is an independently invocable skill via `/auto-test`, `/auto-test-gen`, `/auto-test-data`, `/auto-test-run`
- Skills are installed to `~/.claude/skill/` and invoked by Claude Code's skill system
- The shared data contract between phases is the `test-spec-{controller}-{timestamp}.json` file stored in the target project's `.auto-test/` directory
- All scripts are bash (`.sh`) and designed to be executed by Claude as guided steps, not as standalone CLI tools

### Testing Requirements
- To test the full pipeline, invoke `/auto-test <ControllerName>` against a real Spring Boot + Maven project
- Individual phases can be tested independently if the prerequisite test-spec JSON exists

### Common Patterns
- **Phase contract:** Phases communicate via JSON test-spec files with a `status` field (`pending` → `data_inserted` → `completed`)
- **User confirmation:** Phases 1 and 2 require user confirmation before writing files or executing INSERTs
- **MCP for database:** Phase 2 uses MCP (JDBC) to execute INSERT statements against MySQL
- **AI-assisted generation:** Phase 1 uses AI to generate test specs; Phase 3 uses AI to analyze failures and suggest fixes

## Dependencies

### Internal
- `auto-test-gen` output → `auto-test-data` input (test-spec JSON)
- `auto-test-data` output → `auto-test-run` input (test-spec JSON with `status=data_inserted`)
- `auto-test` orchestrates the above three in sequence

### External
- Spring Boot + Maven project (target application)
- MySQL database (for Phase 2 INSERT execution)
- Java 8+ runtime
- `mvn`, `curl`, `jq`, `lsof` commands

<!-- MANUAL: Custom project notes can be added below -->
