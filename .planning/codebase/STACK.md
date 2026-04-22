# Technology Stack

**Analysis Date:** 2026-04-22

## Languages

**Primary:**
- Bash 4+ - All pipeline orchestration, data extraction, and automation scripts (13 `.sh` files)
- JSON - State schemas, test-spec files, inter-phase data contracts (3 `state-schema.json` files + runtime `test-spec-*.json`)

**Secondary:**
- Markdown - SKILL.md documentation for each skill, test reports, fix logs
- Python 3 - Embedded inline scripts within bash for Java source parsing (used inside `extract-methods.sh` and `extract-dto.sh`)
- Java (read-only) - Target application source files parsed by the skill; not written by this project itself

## Runtime

**Environment:**
- Bash (Unix shell) - All scripts use `#!/bin/bash` with `set -e`
- Python 3 - Invoked inline via `python3 - <<'EOF'` heredoc pattern for Java parsing
- Requires a Unix-like environment (uses `lsof`, `nohup`, `readlink -f`, `sed`, `grep`, `find`, `xargs`, `mktemp`)

**Package Manager:**
- None (this is a Claude Code Skill, not a package)
- Distributed by copying skill directories to `~/.claude/skills/`

## Frameworks

**Core:**
- Claude Code Skill System - Framework for defining AI-powered skills with `/skill-name` triggers
  - Each skill defined by a `SKILL.md` with YAML frontmatter (name, description, metadata)
  - Skills installed to `~/.claude/skills/{skill-name}/`

**Target Application Stack (what the skill operates on):**
- Spring Boot - Java application framework (controllers, services, repositories)
- Maven - Build tool (`mvn clean package -DskipTests`, `mvn compile`)
- Apollo Configuration Center - Externalized configuration (referenced in constraints)

**Testing Approach (used by Phase 3):**
- curl - HTTP testing of Controller endpoints (no JUnit5 generation in main pipeline)
- JSON response validation via `jq` (`.code`, `.success` field extraction)

**Build/Dev:**
- Bash scripts - Pipeline orchestration and automation
- jq - JSON processing (required dependency for all phases)
- Python 3 - Embedded Java source parsing
- git - Input parsing (branch diff, commit inspection)

## Key Dependencies

**Critical:**
- jq - JSON query/manipulation; required by `identify-entity.sh`, `gen-insert.sh`, `execute-insert.sh`, `run-test.sh`, `gen-test-spec.sh`, `gen-test-class.sh`. Exits with error if not found.
- python3 - Used inline by `extract-methods.sh` and `extract-dto.sh` for Java source code parsing (regex-based method signature and DTO class extraction)
- git - Used by `parse-input.sh` for repository root detection, branch diffing, commit inspection; also used throughout for `PROJECT_ROOT` resolution via `git rev-parse --show-toplevel`
- Maven (mvn) - Required by Phase 3 `run-test.sh` for `mvn clean package -DskipTests`
- Java 8+ - Required by Phase 3 to run `java -jar` for application startup

**Infrastructure:**
- curl - HTTP client for endpoint testing in Phase 3; timeout configurable via `CURL_TIMEOUT` (default 10s)
- lsof - Port conflict detection and process killing in Phase 3 (`lsof -i :${port}`)
- sed/grep/find - Text processing, Java source scanning, file discovery throughout all phases

## Configuration

**Environment:**
- `CLAUDE_CODE` env var - Checked by `requirements-clarification.sh` to determine interactive mode vs Claude Code integration
- `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` - Database connection env vars (first priority for `execute-insert.sh`)
- `application.yml` - Spring Boot config at `{PROJECT_ROOT}/src/main/resources/application.yml`; parsed for:
  - `spring.datasource.url`, `username`, `password` (Phase 2 database config)
  - `spring.application.name` (project identification)
  - `server.port` (default 8080)
  - `server.servlet.context-path`

**Build:**
- No build system for the skill itself (copy-based distribution)
- Target project uses Maven: `mvn clean package -DskipTests` for Phase 3

**Skill Configuration Constants (in scripts):**
- `JAR_NAME="spmibill_capacity"` - Hardcoded in `run-test.sh` line 13
- `MAX_PORT_RETRY=3` - Port conflict retry limit (`run-test.sh` line 14)
- `CURL_TIMEOUT=10` - HTTP request timeout in seconds (`run-test.sh` line 15)
- `STARTUP_WAIT=15` - App startup wait time (`run-test.sh` line 16)
- `MAX_DIFF_LINES=5` - Auto-fix diff threshold (`auto-fix.sh` line 9)
- `SERVICE_LAYER_PATTERN="src/main/java/com/yl/spmibill/capacity/service"` - Auto-fix scope limit (`auto-fix.sh` line 12)

## Platform Requirements

**Development:**
- macOS or Linux (uses `lsof`, `readlink -f`, Unix paths)
- Bash 4+, Python 3, jq, git, Maven, Java 8+
- Claude Code CLI (for AI-powered generation phases)

**Production:**
- Target: Spring Boot + Maven Java application
- Target project package convention: `com.yl.spmibill.capacity` (hardcoded in multiple scripts)
- MySQL database accessible for Phase 2 INSERT execution
- Feign Stub services available (configured via application.yml or Apollo)

**Distribution:**
- Copy skill directories to `~/.claude/skills/`:
  ```bash
  cp auto-test/ ~/.claude/skills/auto-test/
  cp auto-test-gen/ ~/.claude/skills/auto-test-gen/
  cp auto-test-data/ ~/.claude/skills/auto-test-data/
  cp auto-test-run/ ~/.claude/skills/auto-test-run/
  ```
- Restart Claude Code after installation
- Invoke via `/auto-test <input>`, `/auto-test-gen <input>`, `/auto-test-data`, `/auto-test-run`

---

*Stack analysis: 2026-04-22*
