# `plan.txt` — Instruction Format

`plan.txt` is the human's instruction channel to the agent. It is **plain text
that degrades gracefully**: a paragraph of prose works, and a structured outline
works better. This spec defines the structured form, the parsing rules, and the
execution ledger.

---

## 1. Discovery

Checked in order, first match wins:

1. Path named by the user.
2. `plan.txt`, `PLAN.txt`, `plan.md`, `PLAN.md` in the repo root (case-insensitive).
3. `plans/*.txt`, `docs/plan*.txt`, `.java-expert/plan.txt`.

Multiple candidates → ask which one. No plan and a vague request → ask for the
plan rather than inventing scope.

---

## 2. Grammar

One directive per line, `KEY: value`. Indented `KEY:` lines belong to the
enclosing `TASK:`. `#` and `//` begin comments.

| Directive | Scope | Meaning |
|---|---|---|
| `GOAL:` | global | One sentence describing the outcome. Required for multi-task plans. |
| `STACK:` | global | Key=value constraints: `java=`, `build=`, `framework=`, `packaging=`, `db=`. Advisory — the repo wins if it disagrees, but you must flag it. |
| `CONSTRAINT:` | global | Hard limits. Repeatable. |
| `RISK:` | global or task | Known landmine. |
| `TASK:` | — | One unit of work. Repeatable, ordered. |
| `FILES:` | task | Comma-separated targets. Advisory, not a boundary. |
| `AC:` | task | Acceptance criterion — observable, testable. Repeatable. |
| `TEST:` | task | How to prove it. A command where possible. |
| `DONE:` | global | Global definition of done. Prose after it is out of scope. |

### Constraint vocabulary (recognized values)

| Constraint | Effect |
|---|---|
| `no-new-deps` | Solve with the JDK + existing classpath. Adding a dependency requires approval. |
| `java=17-only` / `java=21` / `java=25` | Hard target; no preview features, no newer APIs. |
| `keep-public-api` | No signature changes to public types; additive only. |
| `keep-behavior` | Refactor/upgrade only; observable behavior must not change. |
| `offline` | No network; do not run dependency resolution that needs the internet. |
| `no-schema-change` | No DDL this change. |
| `war=<container>` | Deployable target constrains namespace/Servlet level. |
| `minimal-diff` | Smallest change; no opportunistic refactors. |

Unknown constraints are treated as prose intent — read them literally and don't
invent semantics.

---

## 3. Parsing rules

1. **Prose before the first `TASK:`** is context. Read it; don't turn it into tasks.
2. **Prose after a `TASK:`** before the next `TASK:` is that task's detail.
3. **Prose after `DONE:`** is out of scope. Do not implement it; you may report it.
4. **A task with no `AC:`** gets an AC you write and echo back in the plan before
   implementing. If you cannot write a falsifiable AC, ask.
5. **A task with no `TEST:`** gets a test you choose; state it.
6. **Contradictions** (`STACK: java=25` vs `CONSTRAINT: java=17-only`) → the more
   restrictive constraint wins, and you report the conflict.
7. **Ordering**: execute in file order, except build repair always goes first.
   If task B depends on A's output, note the dependency in the ledger.
8. **Vague verbs** ("improve", "optimize", "clean up") without an AC are not
   executable — ask for the metric, or propose one and get it confirmed before
   changing behavior.
9. **Destructive intent** (`DROP`, `truncate`, `rm -rf`, force-push, prod
   credentials, "delete the old data") → stop and ask. Always.
10. **Idempotency**: re-running the plan must not double-apply a change. Check
    the ledger before starting; resume from `doing`/`todo`.

---

## 4. Worked example — new application

```txt
# Inventory service, greenfield
GOAL: A REST service that tracks stock levels per warehouse and emits low-stock events.

STACK: java=25 build=maven framework=spring-boot@4.1 packaging=jar db=postgresql
CONSTRAINT: no-new-deps
CONSTRAINT: keep-public-api
RISK: Team runs Tomcat 11 in staging; keep the app deployable as a WAR later.

TASK: Scaffold the Maven project with the wrapper and the Boot parent
  AC: `./mvnw -v` prints the pinned Maven; `./mvnw clean verify` passes with zero tests
  TEST: ./mvnw -q clean verify

TASK: Model the domain — Warehouse, Sku, StockLevel
  FILES: src/main/java/com/acme/inventory/domain/
  AC: Records/DTOs for the API, JPA entities for persistence; no `double` for quantities
  TEST: Unit tests for validation boundaries

TASK: Persist with Flyway migrations and Spring Data JPA
  FILES: src/main/resources/db/migration/, src/main/java/com/acme/inventory/repo/
  AC: `clean verify` runs Testcontainers Postgres and applies V1__init.sql
  TEST: StockRepositoryIT

TASK: Expose REST endpoints with validation and error handling
  AC: POST /stock validates quantity >= 0 and returns 400 with a field-level error map
  TEST: MockMvc tests for 200/400/404

TASK: Emit a low-stock event when quantity crosses the threshold
  AC: Crossing the threshold publishes exactly one event per transition (not per update)
  TEST: EventPublisherTest with a fake publisher; assert exactly-once on the transition

DONE: clean verify green, Dockerfile present, README with run instructions.
Also nice to have (out of scope): Grafana dashboards.
```

Note how `DONE:` draws the boundary and the trailing prose is explicitly out of
scope. Note the `RISK` driving a design choice (WAR-compatibility later).

---

## 5. Worked example — existing application

```txt
GOAL: Fix duplicate order submission and make POST /orders idempotent.

STACK: java=21 build=maven framework=spring-boot@3.5 packaging=war
CONSTRAINT: keep-public-api
CONSTRAINT: no-schema-change
RISK: The WAR is deployed on Tomcat 9 today; do not introduce jakarta.* imports.

TASK: Reproduce the duplicate submit
  FILES: src/test/java/com/acme/order/OrderControllerIT.java
  AC: A test that fails against the current code by posting twice with the same key
  TEST: ./mvnw -q -Dtest=OrderControllerIT test

TASK: Implement idempotency with an in-memory key store
  FILES: src/main/java/com/acme/order/IdempotencyFilter.java
  AC: Second request with the same Idempotency-Key returns the first response, no second insert
  AC: Missing header behaves as before (202)
  TEST: OrderControllerIT

TASK: Verify the WAR still deploys on Tomcat 9
  AC: `scripts/war-inspect.sh target/orders.war` reports no jakarta.servlet and no bundled servlet-api
  TEST: docker run tomcat:9-jdk21 + curl /orders/actuator/health

DONE: clean verify green, WAR inspected, no optional refactors.
```

The `RISK` line is what prevents an agent from "helpfully" migrating the app to
`jakarta` and breaking the deployment.

---

## 6. Worked example — WAR failure

```txt
GOAL: The orders.war fails to start on Tomcat 11 with ClassNotFoundException
javax.servlet.http.HttpServlet.

STACK: war=tomcat-11
CONSTRAINT: minimal-diff
CONSTRAINT: keep-behavior

TASK: Characterize the failure
  AC: Paste the deepest `Caused by:` and confirm the WAR contains javax-namespaced classes
  TEST: scripts/war-inspect.sh target/orders.war

TASK: Migrate sources to jakarta
  FILES: src/main/java/, src/main/resources/
  AC: zero `javax.servlet|javax.persistence|javax.validation` imports; web.xml is 6.1
  TEST: grep returns nothing; ./mvnw -q clean verify

TASK: Replace stale third-party jars that still ship javax.servlet
  AC: `unzip -l target/orders.war | grep "javax/servlet"` returns nothing
  TEST: scripts/war-inspect.sh target/orders.war

TASK: Deploy and smoke test
  AC: health 200, login 200, one 404, no SEVERE in the container log
  TEST: docker run tomcat:11-jdk21 + curl

DONE: deploying artifact verified, not just built.
```

---

## 7. Execution ledger — `plan.status.md`

Write it beside the plan. It makes the run resumable and auditable.

```markdown
# Java Expert — run log

Plan: plan.txt
Started: 2026-11-27T10:12:00Z
Repo HEAD: ad53549
Environment: JDK 25.0.1, Maven 3.10.2, Tomcat 11.0.9

| # | Task | Status | Evidence |
|---|------|--------|----------|
| 1 | Conflict: plan says 25, pom says 21 → followed 21, flagged | done | pom.xml:14 |
| 2 | Reproduce duplicate submit | done | OrderControllerIT#doublePost (red) |
| 3 | Idempotency filter | doing | — |
| 4 | WAR inspection | todo | — |

## Decisions
- Used the in-memory key store (constraint: no-schema-change).

## Blocked
- Task 5 needs the staging DB credential — not available.
```

Statuses: `todo` · `doing` · `done` · `blocked` · `skipped (reason)`.

If the run is interrupted, **read the ledger first** and continue from the first
non-`done` task. Do not restart completed work.

---

## 8. When the plan is wrong

Plans are written by humans, often before seeing the code. Handle it explicitly:

| Situation | Response |
|---|---|
| Plan targets a file that doesn't exist | Find the real target, note the substitution in the ledger, continue. |
| Plan assumes a library the repo doesn't use | Use what the repo uses; note it. Adding the library needs approval unless `CONSTRAINT` allows. |
| Plan's stack contradicts the build | Follow the build, flag the contradiction, ask if it blocks delivery. |
| Plan asks for a major upgrade inside a bugfix task | Separate it into its own task; do not bundle. |
| Plan's AC is untestable ("works well") | Propose a measurable AC and confirm before changing behavior. |
| Plan is silent on error handling / security | Apply the defaults in §9, and say you did. |

---

## 9. Defaults when the plan is silent

- Validate all external input; never echo exceptions to clients.
- Parameterize all queries.
- Timeouts on every outbound call.
- Authorize every mutating endpoint.
- Migrations forward-only; no `ddl-auto` in production profiles.
- Log with correlation ids; never log secrets or PII.
- Tests for new behavior, placed beside existing tests in the local style.
- No new dependency unless it clearly beats writing ~50 lines.
