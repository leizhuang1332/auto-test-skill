# Codebase Concerns

**Analysis Date:** 2026-04-22

## Security Concerns

### SC-1: Database Password Logged in Plaintext
- **Issue:** `execute-insert.sh` logs the MySQL connection arguments including the password to the log file. The `build_mysql_args()` function at line 333-335 constructs `-p$DB_PASSWORD` and this string is written to `execute-insert.log` via `log_info` calls and stored in test-spec JSON.
- **Files:** `auto-test-data/execute-insert.sh` lines 64-67, 329, 333-335
- **Impact:** Database credentials leaked in log files and JSON artifacts under `.auto-test/`, which could be committed to version control.
- **Current mitigation:** `check_db_safety()` warns on non-localhost connections (line 338-357).
- **Recommendations:** Never log `DB_PASSWORD` or `mysql_args`. Mask passwords in log output. Add `.auto-test/*.log` to `.gitignore`.

### SC-2: Database Credentials Read from application.yml Without Sanitization
- **Issue:** `read_db_config()` parses `application.yml` using `grep` to extract `username` and `password` fields (lines 283-303). The password is stored in shell variable `DB_PASSWORD` and passed on the command line to `mysql`, where it is visible in `ps` output.
- **Files:** `auto-test-data/execute-insert.sh` lines 283-303, 333-335
- **Impact:** Passwords visible in process listings and shell history.
- **Current mitigation:** Interactive mode uses `read -s` (line 320) for password input.
- **Recommendations:** Use `mysql --defaults-extra-file` with a temp file containing credentials, then delete the file immediately after use.

### SC-3: SQL Injection via Unsanitized Field Values
- **Issue:** `build_insert_sql()` in `execute-insert.sh` constructs SQL by embedding field values directly. While `gen-insert.sh` uses `#{varName}` placeholders, the `build_insert_sql()` function at lines 161-186 concatenates values from `fields_json` directly into SQL strings with minimal quoting. String values get single-quote wrapping via complex bash escaping (line 177-184), but there is no proper escaping of SQL special characters within those values.
- **Files:** `auto-test-data/execute-insert.sh` lines 161-186
- **Impact:** If test data values contain single quotes or SQL metacharacters, INSERT statements will break or could be exploited for injection.
- **Recommendations:** Use parameterized queries via MCP or escape values using `mysql_real_escape_string` equivalent before embedding in SQL.

### SC-4: Temporary MCP Scripts with Embedded SQL Left on Disk
- **Issue:** `mcp_execute_insert()` creates a temporary shell script at `$PROJECT_ROOT/.mcp-insert-XXXXXX.sh` (line 209) containing the SQL statement. This script is never cleaned up after use.
- **Files:** `auto-test-data/execute-insert.sh` lines 209-230
- **Impact:** SQL statements with potentially sensitive data persist on disk in the project root.
- **Recommendations:** Clean up temporary MCP scripts after execution. Write them to `/tmp` instead of `$PROJECT_ROOT`.

### SC-5: App Killed with `kill -9` Without Graceful Shutdown
- **Issue:** `run-test.sh` uses `kill -9` (SIGKILL) to terminate the Spring Boot application on port conflicts (line 209-214). This prevents graceful shutdown, which can corrupt data or leave database connections open.
- **Files:** `auto-test-run/run-test.sh` lines 207-214
- **Impact:** Potential data corruption, orphaned database connections, incomplete transaction rollback.
- **Recommendations:** Send SIGTERM first, wait for graceful shutdown, then SIGKILL as fallback.

### SC-6: AI Prompt Contains Full Source Code Written to Disk
- **Issue:** `gen-test-spec.sh` writes the entire Controller source code and all metadata to `.gen-test-spec-prompt.txt` (line 169-272). Similarly, `gen-test-class.sh` builds prompts containing full source code. These files may contain proprietary business logic.
- **Files:** `auto-test-gen/gen-test-spec.sh` line 169, `auto-test-gen/gen-test-class.sh` lines 143-245
- **Impact:** Proprietary source code exposed in plaintext files under `.auto-test/`.
- **Current mitigation:** `gen-test-spec.sh` attempts cleanup at line 350 (`rm -f .gen-test-spec-prompt.txt`), but only on successful completion.
- **Recommendations:** Ensure cleanup happens in all exit paths (use `trap`). Add `.auto-test/` to `.gitignore`.

## Reliability Concerns

### RC-1: Broken Variable Reference in execute-insert.sh
- **Issue:** `find_test_spec()` at line 94 references `$GSTACK_DIR` which is never defined in this script. All other scripts use `$AUTO_TEST_DIR` or `$PROJECT_DIR`. This will cause the function to always fail when searching for test-spec files.
- **Files:** `auto-test-data/execute-insert.sh` line 94
- **Impact:** `execute-insert.sh` cannot find its input test-spec JSON file and will always exit with an error, making Phase 2 INSERT execution non-functional.
- **Fix approach:** Replace `$GSTACK_DIR` with `$AUTO_TEST_DIR` to match the variable defined at line 42.

### RC-2: `set -e` with Subshell Failures Silently Ignored
- **Issue:** Multiple scripts use `set -e` (exit on error) but then capture command output in subshells like `result=$(some_command)` or `variable=$(find_test_spec)`. When `set -e` is active, failures in subshells used in assignments do NOT always cause the script to exit, depending on bash version and context. Several critical operations rely on this pattern.
- **Files:** `auto-test/auto-test.sh` lines 96, 117, 149; `auto-test-data/identify-entity.sh` lines 309, 349; `auto-test-data/gen-insert.sh` line 515
- **Impact:** A failed `find_test_spec` call could return empty string, and the script continues with `$test_spec` set to empty, causing confusing downstream errors.
- **Fix approach:** Add explicit error checking after each subshell assignment: `test_spec=$(find_test_spec) || { log_error "..."; return 1; }`.

### RC-3: Race Condition in test-spec JSON Updates
- **Issue:** Multiple scripts update the same test-spec JSON file using a read-modify-write pattern: read with `jq`, write to `.tmp` file, then `mv`. If two operations run concurrently (e.g., two `identify-entity` processes), updates can be lost.
- **Files:** `auto-test-data/identify-entity.sh` line 341, `auto-test-data/gen-insert.sh` line 458, `auto-test-data/execute-insert.sh` line 262, `auto-test-run/run-test.sh` line 496
- **Impact:** Concurrent updates could silently overwrite each other's changes, leading to lost entityClass, insertTemplate, or test result data.
- **Fix approach:** Use file locking (`flock`) or serialize all updates through a single process.

### RC-4: Temporary File Cleanup Uses PID but Not Guaranteed Unique
- **Issue:** `run-test.sh` uses `$$` for temp file names (`/tmp/test_results_$$.json`, `/tmp/curl_response_${test_case_id}_$$.json`). PID-based names can collide if a previous run crashed without cleanup and PID wrapped around.
- **Files:** `auto-test-run/run-test.sh` lines 275, 668
- **Impact:** Stale temp files from crashed runs could interfere with new runs.
- **Current mitigation:** `trap` at line 671 cleans up on EXIT.
- **Recommendations:** Use `mktemp` for guaranteed unique temp files instead of PID-based naming.

### RC-5: requirements-clarification.sh Python Script References Wrong File
- **Issue:** The embedded Python script at line 96-108 reads from the literal filename `OUTPUT_FILE` instead of the shell variable's expanded value. The `open('OUTPUT_FILE', 'r')` call will fail because no file named `OUTPUT_FILE` exists.
- **Files:** `auto-test-data/../../auto-test-gen/requirements-clarification.sh` lines 96-108
- **Impact:** The Python-based JSON update silently fails. The fallback `sed` commands (lines 112-114) then perform the replacement, but they use basic string substitution that breaks if `CONTROLLER_NAME` contains regex metacharacters or `/` characters.
- **Fix approach:** Pass the actual file path as an argument to the Python script, or remove the broken Python block entirely and rely on `jq` for JSON manipulation like all other scripts do.

### RC-6: Extract-dto.sh Not Invoked with Method Signatures
- **Issue:** In `gen-test-spec.sh` line 142, `extract-dto.sh` is called with an empty string as argument (`"$SKILL_DIR/extract-dto.sh" "" 2>/dev/null`), but `extract-dto.sh` expects method signature strings as input (`$1 = method signature string`). It will always return `[]`.
- **Files:** `auto-test-gen/gen-test-spec.sh` line 142, `auto-test-gen/extract-dto.sh` line 7
- **Impact:** Phase 1 test spec generation will never populate DTO classes, so Phase 2 entity identification will have nothing to work with.
- **Fix approach:** Pass each method signature from `$METHODS_JSON` to `extract-dto.sh`, or refactor `extract-dto.sh` to accept the Controller path and extract DTOs from all methods.

### RC-7: App Startup Wait May Not Be Sufficient
- **Issue:** `wait_for_startup()` polls `lsof` every 2 seconds for up to 60 seconds (line 218-233), checking if the port is listening. However, Spring Boot applications can start listening on their port before they are fully initialized (beans loaded, database connections ready). A curl test immediately after port listen detection may hit a not-yet-ready application.
- **Files:** `auto-test-run/run-test.sh` lines 218-233
- **Impact:** False test failures due to hitting endpoints before the app is fully ready.
- **Fix approach:** After port is detected, add a health check probe (e.g., curl to `/actuator/health` or the context root) with a short retry loop before starting tests.

### RC-8: `lsof` Not Available on All Platforms
- **Issue:** `run-test.sh` uses `lsof` for port checking (lines 203, 209, 243), but `lsof` is not installed by default on all Linux distributions and is not available on Windows (the current development platform is Windows 10). This makes Phase 3 non-functional on Windows.
- **Files:** `auto-test-run/run-test.sh` lines 203, 209, 243
- **Impact:** Port conflict detection and startup wait are broken on Windows.
- **Fix approach:** Use platform-agnostic port checking: `netstat`, `ss`, or attempt a `curl`/`nc` connection to the port.

## Maintainability Concerns

### MC-1: Hard-Coded Project-Specific Paths Throughout Codebase
- **Issue:** Multiple scripts contain hard-coded paths specific to `yl-jms-spmibill-capacity`:
  - `extract-dto.sh` lines 19-21: `com/yl/spmibill/capacity/dto`, `com/yl/spmibill/capacity/vo`
  - `extract-dto.sh` line 30: `com/yl/spmibill/capacity`
  - `extract-dto.sh` line 41: default package `com.yl.spmibill.capacity`
  - `extract-feign.sh` lines 36, 68: default package `com.yl.spmibill.capacity.feign`
  - `gen-test-class.sh` line 29: `com/yl/spmibill/capacity/controller/generated`
  - `gen-test-class.sh` line 153: `com.yl.spmibill.capacity.controller.generated`
  - `run-test.sh` line 12: `JAR_NAME="spmibill_capacity"`
  - `auto-fix.sh` line 12: `src/main/java/com/yl/spmibill/capacity/service`
  - `state-schema.json` (auto-test-gen) line 209: `"const": "yl-jms-spmibill-capacity"`
  - `state-schema.json` (auto-test-run) line 187: `"const": "yl-jms-spmibill-capacity"`
- **Impact:** The skill cannot be used with any other Spring Boot project without editing multiple shell scripts and JSON schemas. This defeats the purpose of a reusable Claude Code Skill.
- **Fix approach:** Extract all project-specific values into a config file (e.g., `.auto-test/config.json`) read at runtime. Derive package paths from `application.yml` or the project's base package. Remove `const` constraints from schemas.

### MC-2: Duplicated Utility Functions Across Scripts
- **Issue:** Logging functions (`log_info`, `log_error`, `log_warn`), `find_test_spec()`, `list_available_controllers()`, and other utilities are re-implemented in nearly every script with slight variations:
  - `auto-test.sh` lines 14-20: logging to stdout/stderr only
  - `execute-insert.sh` lines 64-81: logging to both stdout and log file
  - `identify-entity.sh` lines 47-57: logging to stderr only
  - `gen-insert.sh` lines 57-67: logging to stdout only
  - `run-test.sh` lines 52-58: logging to stdout only
- **Impact:** Bug fixes must be applied in multiple places. Inconsistent logging behavior (some log to file, some to stderr, some to stdout) makes debugging difficult.
- **Fix approach:** Create a shared `lib.sh` or `common.sh` in a `shared/` directory and source it from all scripts.

### MC-3: Inconsistent test-spec File Discovery
- **Issue:** Different scripts find the latest test-spec file differently:
  - `auto-test.sh` line 37: uses `ls -t` and `head -1` with glob pattern
  - `identify-entity.sh` lines 82-93: uses bash array expansion and `sort -r | head -1`
  - `gen-insert.sh` lines 80-94: uses bash array and `${files[-1]}` (last element)
  - `execute-insert.sh` lines 88-105: uses `ls -t` with `$GSTACK_DIR` (broken variable)
  - `run-test.sh` lines 19-36: uses `ls -t` and `head -1`
- **Files:** All scripts with `find_test_spec()` functions
- **Impact:** Different sorting methods may select different files. `gen-insert.sh` uses `${files[-1]}` which gets the lexicographically last filename, not necessarily the most recent by timestamp. Bash array expansion with glob patterns can fail if no files match.
- **Fix approach:** Consolidate into a single shared function. Use `ls -t` consistently for most-recent-first ordering.

### MC-4: Mixed Language Output (Chinese and English)
- **Issue:** JSON schema fields use Chinese property names (`输入参数`, `功能`, `数据边界`, `预期返回结果`, `实际结果`, `原因`) while all other fields, log messages, and code are in English. This creates a jarring codebase experience and makes it harder for non-Chinese-speaking developers to understand or contribute.
- **Files:** `auto-test-gen/state-schema.json` lines 175-179, `auto-test-data/state-schema.json` lines 176-179, `auto-test-gen/gen-test-spec.sh` line 200 (prompt template), `auto-test-run/run-test.sh` lines 133, 415, 487-491
- **Impact:** jq queries must use Chinese characters (e.g., `.["输入参数"].fields`), which are error-prone to type and may cause encoding issues in some terminals.
- **Recommendations:** Use English field names in JSON schema with an optional `descriptionZh` field for Chinese descriptions. This is a breaking change requiring migration of existing test-spec files.

### MC-5: No Input Validation on Controller Names
- **Issue:** `parse-input.sh` passes user input directly into `find` commands and JSON output without sanitization. A malicious or accidental input like `; rm -rf /` in the Controller name could be dangerous, though `find -name` limits the attack surface.
- **Files:** `auto-test-gen/parse-input.sh` lines 65, 87
- **Impact:** Unexpected behavior with unusual Controller names containing shell metacharacters.
- **Fix approach:** Validate that input matches expected patterns (alphanumeric, dots, underscores) before using in commands.

### MC-6: State Schema Versioning Conflicts
- **Issue:** The three `state-schema.json` files define overlapping but incompatible schemas:
  - `auto-test-gen/state-schema.json`: version `"1.0"`, `project` is `"const": "yl-jms-spmibill-capacity"`
  - `auto-test-data/state-schema.json`: version `"2.0"`, `additionalProperties: true`
  - `auto-test-run/state-schema.json`: version `"3.0"`, `project` is `"const": "yl-jms-spmibill-capacity"`
  - The `testCase` object in `auto-test-gen` schema has `additionalProperties: false` (line 142), but Phase 2 and 3 need to add `entityClass`, `insertTemplate`, `insertStatus`, etc. This means the Phase 1 schema rejects the extensions that Phase 2/3 write.
- **Files:** `auto-test-gen/state-schema.json` line 142, `auto-test-data/state-schema.json` line 161
- **Impact:** Schema validation would fail if Phase 2/3 extensions are checked against the Phase 1 schema. The `additionalProperties: false` in Phase 1's testCase definition prevents Phase 2 from adding its fields.
- **Fix approach:** Either make all schemas use `additionalProperties: true` for testCase, or create a single unified schema that includes all phase fields with phase-specific required constraints.

## Scalability Concerns

### SCAL-1: Full Java Source Tree Scan on Every DTO Lookup
- **Issue:** `identify-entity.sh` calls `find_java_sources()` (line 60-66) which runs `find` on the entire `src/main/java` directory tree for every single DTO being identified. In `scan_annotation()` (line 176-217), the full file list is then iterated with `grep` for each DTO. For a project with thousands of Java files and dozens of DTOs, this becomes O(n*m) where n=files and m=DTOs.
- **Files:** `auto-test-data/identify-entity.sh` lines 60-66, 176-217
- **Impact:** Very slow execution on large projects. Each call to `find_java_sources()` re-scans the entire source tree.
- **Fix approach:** Cache the file list once at startup. Build an index of class name to file path, then do direct lookups.

### SCAL-2: Sequential Test Execution Without Parallelism
- **Issue:** `run-test.sh` runs all curl tests sequentially in a `while read` loop (lines 399-471). For a Controller with many endpoints, this can be very slow since each test waits for the full HTTP round-trip plus any auto-fix attempt.
- **Files:** `auto-test-run/run-test.sh` lines 399-471
- **Impact:** Testing 20+ endpoints could take several minutes unnecessarily.
- **Fix approach:** Run independent curl tests in parallel (using background processes), then collect results. Auto-fix steps would need to remain sequential.

### SCAL-3: No Support for Multi-Module Maven Projects
- **Issue:** All scripts assume a single-module Maven project with `src/main/java` at the project root. Multi-module projects (common in enterprise Java) have source code in submodules like `module-a/src/main/java`. `find_jar_file()` only looks in `$PROJECT_ROOT/target/` (line 171-183).
- **Files:** `auto-test-run/run-test.sh` lines 171-183, `auto-test-data/identify-entity.sh` line 31
- **Impact:** The skill is unusable with multi-module Maven projects.
- **Fix approach:** Add Maven module detection. Use `mvn -pl` to build specific modules. Search for jars in the correct module's `target/` directory.

## Missing Features / Incomplete Implementations

### MF-1: MCP Execution Is a Stub
- **Issue:** `execute-insert.sh` does not actually execute INSERT statements via MCP. It creates a temporary shell script and marks the test case status as `mcp_required` (lines 466-481). The actual MCP execution is deferred to Claude Code, but the integration is not implemented -- only instructions are printed.
- **Files:** `auto-test-data/execute-insert.sh` lines 190-230, 466-481
- **Impact:** Phase 2 INSERT execution is non-functional when running scripts standalone. The entire Phase 2 depends on Claude Code's MCP tools, making the skill unusable in any other context.
- **Recommendations:** Document the MCP dependency clearly. Provide a fallback using `mysql` CLI for environments without MCP.

### MF-2: Database Reverse Lookup Not Implemented
- **Issue:** `db_reverse()` in `identify-entity.sh` is a stub that always returns failure (lines 287-293). The SKILL.md documents this as "Priority 3: Database Reverse (optional/future)" but it remains unimplemented.
- **Files:** `auto-test-data/identify-entity.sh` lines 287-293
- **Impact:** When annotation scan and naming inference both fail, the system falls through to returning `unknown` with confidence 0.0 (line 325), rather than trying a potentially useful database query.
- **Recommendations:** Implement using `SHOW TABLES LIKE '%baseName%'` via MCP or CLI.

### MF-3: gen-test-class.sh Still References Old state.json Architecture
- **Issue:** `gen-test-class.sh` reads from `$HOME/.gstack/projects/yl-jms-spmibill-capacity/auto-test-state.json` (line 26) and updates `state.json` with test case status. This contradicts the "NEW ARCHITECTURE" described in SKILL.md which uses `test-spec-{controller}-{timestamp}.json`. The script is effectively a leftover from a previous architecture.
- **Files:** `auto-test-gen/gen-test-class.sh` lines 26, 60-63, 291-318
- **Impact:** This script does not participate in the current pipeline architecture. If invoked directly, it operates on a different state file than Phase 2/3 expect.
- **Fix approach:** Either update `gen-test-class.sh` to use the test-spec JSON architecture, or remove it if `gen-test-spec.sh` replaces its functionality.

### MF-4: No Rollback Mechanism for INSERT Executions
- **Issue:** When Phase 2 inserts test data into the database, there is no corresponding cleanup or rollback mechanism. The SKILL.md mentions "Consider backing up data before bulk inserts" as a recommendation but no DELETE or TRUNCATE scripts exist.
- **Files:** `auto-test-data/SKILL.md` lines 111-114, `auto-test-data/execute-insert.sh`
- **Impact:** Test data accumulates in the database across runs, potentially causing unique constraint violations or polluting test results.
- **Recommendations:** Generate corresponding DELETE statements alongside INSERT templates. Add a `cleanup-insert.sh` script. Track inserted row IDs for targeted cleanup.

### MF-5: No `.gitignore` Management for `.auto-test/` Directory
- **Issue:** The pipeline creates `.auto-test/` in the project root with JSON files, logs, and backups. There is no automated check or setup to ensure `.auto-test/` is in `.gitignore`. Artifacts containing source code, SQL, and credentials could be accidentally committed.
- **Files:** `auto-test/auto-test.sh` lines 23-31 (creates directory structure)
- **Impact:** Sensitive test artifacts (source code in prompts, SQL with data, credentials in logs) could be committed to version control.
- **Fix approach:** `ensure_auto_test_dir()` should check and append `.auto-test/` to `.gitignore` if not already present.

### MF-6: No Error Recovery Between Pipeline Phases
- **Issue:** `auto-test.sh` runs Phase 1, 2, and 3 sequentially with `set -e`. If any phase fails, the entire pipeline aborts with no way to resume from the failed phase. The test-spec JSON tracks phase status but there is no resume logic.
- **Files:** `auto-test/auto-test.sh` lines 199-201
- **Impact:** If Phase 2 fails (e.g., database connection issue), the user must re-run the entire pipeline from scratch, even though Phase 1's output (test-spec JSON) still exists.
- **Fix approach:** Check the test-spec JSON `phase` field before each phase. If `phase >= phase1_completed`, skip Phase 1. Add a `--resume` flag or phase-specific re-entry.

## Potential Bugs / Edge Cases

### EC-1: CamelCase to snake_case Conversion Produces Wrong Results
- **Issue:** The `to_snake_case()` function in `gen-insert.sh` (lines 163-182) uses a sed pattern `s/\([A-Z]\)/_\L\1/g` which incorrectly handles certain cases:
  - `ID` becomes `_i_d` instead of `id` (partially handled by special case on line 167-168)
  - `billID` becomes `bill_i_d` (the sed on line 177 converts ID to Id first, but this creates `bill_Id` which then becomes `bill__id` with double underscore)
  - Consecutive uppercase like `XMLParser` becomes `_x_m_l_parser` instead of `xml_parser`
- **Files:** `auto-test-data/gen-insert.sh` lines 163-182
- **Impact:** Generated column names may not match actual database column names, causing INSERT failures.
- **Fix approach:** Use a proper camelCase-to-snake_case conversion (e.g., insert underscore only before uppercase letters that follow a lowercase letter or before an uppercase letter followed by a lowercase letter).

### EC-2: identify-entity.sh Only Processes First DTO Per Test Case
- **Issue:** At line 475, the comment says "For now, identify entity for the first DTO (main entity)" and only processes `dtoClasses[0]`. If a test case depends on multiple DTOs mapping to different entities, only the primary entity gets identified.
- **Files:** `auto-test-data/identify-entity.sh` lines 472-476
- **Impact:** Missing entity identification for secondary DTOs means incomplete INSERT template generation for related tables.
- **Fix approach:** Loop through all `dtoClasses` entries, not just the first.

### EC-3: construct_request_body() Produces Flat JSON from Nested Fields
- **Issue:** `run-test.sh` line 143-151 builds a flat JSON object from `输入参数.fields`, but Spring Boot controllers often expect nested JSON structures (e.g., `BaseQuery<List<SpmiCapacityBillIdDTO>>` wraps data in a generic query object with `data`, `current`, `size` fields). The flat construction will not match the expected request format.
- **Files:** `auto-test-run/run-test.sh` lines 129-151
- **Impact:** curl requests will send incorrectly structured request bodies, causing 400 Bad Request or deserialization errors on the server.
- **Fix approach:** Include the DTO wrapper structure in the test-spec JSON and honor it during request body construction.

### EC-4: Endpoint Path Convention Does Not Match Actual Routes
- **Issue:** `run-test.sh` line 432 constructs the endpoint as `/spmi/capacity/bill/${method_name}` using a hardcoded convention. However, actual Spring Boot routes are defined by `@RequestMapping`, `@PostMapping`, `@GetMapping` annotations on methods, which can be arbitrary paths. The `extract-methods.sh` script already extracts `routePath` from these annotations.
- **Files:** `auto-test-run/run-test.sh` line 432
- **Impact:** Nearly all curl tests will hit 404 because the endpoint paths do not match the actual routes.
- **Fix approach:** Store `routePath` in the test-spec JSON during Phase 1 (it is partially extracted by `extract-methods.sh` but not propagated to the test case output). Use the stored route path in Phase 3.

### EC-5: HTTP Method Guessing from Method Name Is Unreliable
- **Issue:** `run-test.sh` lines 424-426 guess the HTTP method from the Java method name prefix (`get*`, `query*`, `find*` = GET, otherwise POST). This is unreliable -- a method named `getOrCreate` would incorrectly be called as GET, and a method named `processOrder` would default to POST even if it's actually a GET endpoint.
- **Files:** `auto-test-run/run-test.sh` lines 424-426
- **Impact:** Wrong HTTP method causes 405 Method Not Allowed or incorrect test behavior.
- **Fix approach:** Extract and store `httpMethod` from the `@*Mapping` annotations during Phase 1 (already extracted by `extract-methods.sh`) and use it in Phase 3.

### EC-6: Double Curl Execution in test_endpoint()
- **Issue:** `test_endpoint()` executes curl TWICE for each test: once to get the HTTP status code (lines 282-286 or 290-296) and once to get the timing (lines 287-289 or 297-300). The second curl hits the server again, which may produce different results if the endpoint has side effects (e.g., creating a record).
- **Files:** `auto-test-run/run-test.sh` lines 282-300
- **Impact:** Non-idempotent endpoints (POST creating data) are called twice, potentially creating duplicate records. The timing measurement does not correspond to the actual test request.
- **Fix approach:** Use a single curl invocation with `-w "%{http_code}\n%{time_total}"` to capture both response data and timing in one request.

### EC-7: `extract-methods.sh` Modifies chmod on Every Run
- **Issue:** The last line of `extract-methods.sh` (line 89) runs `chmod +x ~/.claude/skills/auto-test-gen/extract-methods.sh`, making the script modify its own permissions on every execution. This is a side effect unrelated to the script's purpose.
- **Files:** `auto-test-gen/extract-methods.sh` line 89
- **Impact:** Unnecessary filesystem writes. If the skill directory is read-only or has different ownership, this causes errors.
- **Fix approach:** Remove the `chmod` line. Set permissions during installation instead.

### EC-8: Empty `find_test_spec` Glob Expands to Literal Pattern
- **Issue:** In `identify-entity.sh` lines 82-83 and `gen-insert.sh` lines 83-84, bash arrays are populated via glob patterns like `files=( $pattern )`. If no files match, the array contains the literal glob string (e.g., `test-spec-FooController-*.json`) rather than being empty, because `nullglob` is not set.
- **Files:** `auto-test-data/identify-entity.sh` lines 82-83, `auto-test-data/gen-insert.sh` lines 83-84
- **Impact:** The script proceeds with a non-existent filename, causing confusing error messages from `jq` or `cat`.
- **Fix approach:** Add `shopt -s nullglob` at the top of scripts that use glob expansion, or explicitly check with `ls` before array assignment.

## Dependencies at Risk

### DEP-1: Python3 Required but Not Checked in Most Scripts
- **Issue:** `extract-methods.sh` and `extract-dto.sh` embed Python3 scripts (using `python3 -` heredoc pattern). However, only `extract-methods.sh` checks for python3 availability (line 6). `extract-dto.sh` does not check and will fail silently if python3 is missing.
- **Files:** `auto-test-gen/extract-methods.sh` line 6, `auto-test-gen/extract-dto.sh`
- **Impact:** `extract-dto.sh` produces no output if python3 is not installed, leading to empty DTO arrays in test specs.
- **Fix approach:** Add python3 availability check at the top of `extract-dto.sh`, or rewrite both scripts in pure bash/jq to eliminate the python3 dependency.

### DEP-2: jq Dependency Is Critical but Only Checked in Some Scripts
- **Issue:** `jq` is used extensively throughout all scripts for JSON parsing and manipulation. Some scripts check for `jq` availability (e.g., `identify-entity.sh` line 37, `gen-insert.sh` line 47, `execute-insert.sh` line 54), but `auto-test.sh`, `parse-input.sh`, `extract-feign.sh`, and `run-test.sh` do not.
- **Files:** `auto-test/auto-test.sh`, `auto-test-gen/parse-input.sh`, `auto-test-gen/extract-feign.sh`, `auto-test-run/run-test.sh`
- **Impact:** Scripts fail with cryptic errors if `jq` is not installed.
- **Fix approach:** Add a `check_prerequisites()` function to each script that verifies `jq` is available.

### DEP-3: Platform-Dependent Commands (readlink, stat, lsof)
- **Issue:** The codebase uses several platform-dependent commands:
  - `readlink -f` (GNU coreutils) -- not available on macOS by default
  - `stat -f "%Sm"` (macOS) vs `stat -c "%y"` (Linux) -- both used with fallback in `identify-entity.sh` line 116
  - `lsof` -- not available on Windows
  - `realpath` -- not available on older macOS
- **Files:** `auto-test-gen/parse-input.sh` lines 32, 53, 78, 95; `auto-test-data/identify-entity.sh` line 116, 198, 249, 274
- **Impact:** Scripts break or behave inconsistently across macOS, Linux, and Windows.
- **Fix approach:** Use portable alternatives or add platform detection with appropriate fallbacks.

### DEP-4: grep -P (Perl Regex) Not Portable
- **Issue:** `identify-entity.sh` line 206 uses `grep -oP` (Perl-compatible regex) to extract the table name from `@Table` annotations. `grep -P` is not available on macOS by default (BSD grep).
- **Files:** `auto-test-data/identify-entity.sh` line 206
- **Impact:** Entity identification fails on macOS because `grep -P` is not supported.
- **Fix approach:** Replace with `sed` or `awk` for regex extraction, or use the embedded Python3 pattern for this extraction.

## Test Coverage Gaps

### TC-1: No Tests for Any Shell Script
- **What's not tested:** None of the 10 shell scripts have any automated tests. There are no test harnesses, no mock data fixtures, and no integration tests.
- **Files:** All `.sh` files in `auto-test/`, `auto-test-gen/`, `auto-test-data/`, `auto-test-run/`
- **Risk:** Any refactoring or bug fix could introduce regressions that go undetected. The broken `$GSTACK_DIR` variable (RC-1) and missing `extract-dto.sh` argument (RC-6) are examples of bugs that tests would have caught immediately.
- **Priority:** High

### TC-2: No Validation of Generated JSON Test Spec
- **What's not tested:** The test-spec JSON files generated by `gen-test-spec.sh` are never validated against the `state-schema.json`. A malformed JSON output from the AI could propagate through Phase 2 and 3 without detection.
- **Files:** `auto-test-gen/gen-test-spec.sh`, `auto-test-gen/state-schema.json`
- **Risk:** Invalid JSON structure causes silent failures in downstream phases.
- **Priority:** Medium

---

*Concerns audit: 2026-04-22*
