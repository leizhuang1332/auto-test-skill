<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-04-22 | Updated: 2026-04-22 -->

# auto-test-gen

## Purpose
Phase 1 of the auto-test pipeline. Parses user input (Controller name, method, git branch, or commit), runs interactive requirements Q&A, extracts Controller methods/DTOs/FeignClients from Java source, then uses AI to generate JSON test spec. User confirms before writing the test-spec JSON file to disk.

## Key Files

| File | Description |
|------|-------------|
| `SKILL.md` | Skill definition: triggers, 4 input formats, data flow, confirmation flow, test-spec schema |
| `parse-input.sh` | Parses user input to identify type (Controller/method/branch/commit) and locate the Java file |
| `requirements-clarification.sh` | Interactive 5-question Q&A: business context, data boundaries, external deps, common bugs, priority |
| `extract-methods.sh` | Scans Controller Java file, lists public methods with signatures, return types, and annotations |
| `extract-dto.sh` | Traces method parameters to find DTO Java class files and their field definitions |
| `extract-feign.sh` | Scans `@Autowired` fields to identify FeignClient dependencies used by the Controller |
| `gen-test-spec.sh` | AI generates JSON test spec per method, renders markdown preview, user confirms, writes file |
| `state-schema.json` | JSON schema defining the test-spec structure: version, project, testCases with 输入参数/预期返回结果 |

## Subdirectories

_None_

## For AI Agents

### Working In This Directory
- This is the **most complex phase** — it involves source code analysis, interactive Q&A, and AI-driven spec generation
- Scripts are executed by Claude step-by-step (not as a monolithic bash pipeline)
- The `requirements-clarification.sh` Q&A must complete before `gen-test-spec.sh` runs — AI needs business context to generate meaningful test specs
- Output file naming: `test-spec-{controller}-{timestamp}.json` (conflicts get `_v{n}` suffix)
- On re-run: merge `testCases[]` arrays, preserve existing test cases with their status

### Testing Requirements
- Test by running `/auto-test-gen SpmiCapacityBillController` against a real Spring Boot project
- Verify the generated test-spec JSON has correct methods, DTOs, and expected results
- Check that the markdown preview matches the JSON content

### Common Patterns
- **Source extraction chain:** `parse-input.sh` → `extract-methods.sh` → `extract-dto.sh` + `extract-feign.sh` → `gen-test-spec.sh`
- **AI generation:** `gen-test-spec.sh` invokes AI which reads Controller.java, DTO files, and requirements answers to produce test specs
- **User confirmation gate:** JSON spec is shown as markdown first; only written to disk after user approval

## Dependencies

### Internal
- `../auto-test-data/` — Phase 2 reads this phase's test-spec JSON output
- `../auto-test-run/` — Phase 3 reads this phase's test-spec JSON output
- `../auto-test/` — Pipeline orchestrator invokes this phase

### External
- Spring Boot project source code (Controller.java, DTO classes, FeignClient interfaces)
- `find`, `grep` commands for source scanning

<!-- MANUAL: Custom project notes can be added below -->
