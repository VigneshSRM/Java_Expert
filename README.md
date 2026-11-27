# Java_Expert

An **agentic skill** that turns a coding agent into a senior Java engineer: it
builds new applications from `plan.txt` instructions, extends existing ones,
audits and fixes code, and diagnoses WAR/servlet-container deployment failures.

One skill, five jobs:

| Job | You give it | It gives you |
|---|---|---|
| **A. Build from a plan** | a `plan.txt` | working code + an auditable task ledger |
| **B. Change an existing app** | a feature or bug request | the smallest correct diff, with tests |
| **C. Create a new app** | constraints, or nothing | a runnable project with the right stack |
| **D. Audit and fix code** | "find the issues" | ranked P0–P3 findings and verified patches |
| **E. Fix a WAR** | a `.war`, a container log, "won't deploy" | root cause and a deploy-verified fix |

---

## Layout

```
skills/java-expert/
├── SKILL.md                        # the skill: modes, rules, phases, stop conditions
├── references/
│   ├── tooling-matrix.md           # current JDK/build/framework/library versions + how to verify
│   ├── war-troubleshooting.md      # classloading model, 40+ failure signatures, migration procedure
│   ├── code-audit-playbook.md      # check catalog by category, with detection + fix patterns
│   └── plan-txt-spec.md            # plan.txt grammar, worked examples, ledger format
├── scripts/
│   ├── env-probe.sh                # read-only recon: build, target JDK, framework, packaging, red flags
│   ├── java-audit.sh               # high-signal smell scan with file:line evidence and severities
│   └── war-inspect.sh              # artifact forensics: bundled servlet API, namespace mix, dup jars, bytecode
└── assets/
    └── plan.txt.example            # fillable plan template
```

`SKILL.md` is self-sufficient; the references are progressive disclosure — the
agent loads them only when the task needs that depth.

---

## Install

Copy the skill folder into your agent's skills directory:

```bash
mkdir -p .claude/skills
cp -R skills/java-expert .claude/skills/
```

Any agent that reads `SKILL.md` frontmatter works the same way — the directory
needs `name` + `description`, and everything else is plain Markdown and shell.

---

## Quick start

```bash
# 1. Recon the repo (read-only, no JDK required)
skills/java-expert/scripts/env-probe.sh .

# 2. Scan for the patterns that precede incidents
skills/java-expert/scripts/java-audit.sh .

# 3. After a build, inspect the artifact rather than trusting it
skills/java-expert/scripts/war-inspect.sh target/orders.war
```

Then point the agent at a plan:

> Read `skills/java-expert/SKILL.md`, then execute `plan.txt`.

---

## Writing a `plan.txt`

Prose works. These keys make execution precise:

```txt
GOAL: Fix duplicate order submission and make POST /orders idempotent.

STACK: java=21 build=maven framework=spring-boot@3.5 packaging=war
CONSTRAINT: keep-public-api
CONSTRAINT: no-schema-change
RISK: deployed on Tomcat 9 today — do not introduce jakarta.* imports.

TASK: Reproduce the duplicate submit
  AC: a test that fails against current code by posting twice with the same key
  TEST: ./mvnw -q -Dtest=OrderControllerIT test

TASK: Add an Idempotency-Key filter
  AC: the second request returns the first response and inserts nothing
  TEST: OrderControllerIT

DONE: clean verify green, WAR inspected, no optional refactors.
```

The skill also enforces the inverse of a plan: when `plan.txt` contradicts the
build (says Java 25, POM says 17), the repository wins and the conflict is
reported — it will not silently upgrade your platform.

Start from `assets/plan.txt.example`. Full grammar and three worked examples
(new app, brownfield feature, WAR failure) are in
`references/plan-txt-spec.md`.

---

## What makes it behave

- **Recon before code** — no proposal until the build, target JDK, framework,
  and packaging are known.
- **Evidence over assertion** — every "fixed" carries the command, the output,
  and the diff. For WAR work, the artifact is inspected and smoke-tested.
- **Smallest correct diff** — no drive-by refactors, no bundled upgrades.
- **Findings are ranked** — P0 (data loss / RCE / auth bypass) to P3 (style),
  with the mechanism explained, not just the symptom.
- **Refuses the dangerous shortcuts** — no deleting failing tests, no
  `tomcat/lib` jar copies, no trust-all TLS, no `permitAll()` to get green.
- **Knows when to stop** — data migrations, missing credentials, contradictory
  sources of truth, and breaking wire formats become questions, not guesses.

---

## Version currency

The tooling matrix is a **snapshot, verified 2026-11-27**:

- JDK **25 LTS** (production default) · **27** latest feature release (non-LTS) · 29 next LTS
- Spring Boot **4.2.0** latest · **4.1.x** recommended production line
- Jakarta EE **11** · Hibernate ORM **7.4.x** · Tomcat **11** (Servlet 6.1)
- Maven **3.10.x** (Maven 4 still an RC) · Gradle **9.8.x**

Versions drift. `references/tooling-matrix.md` §9 lists the commands to
re-verify (`mvn versions:display-dependency-updates`, `dependency:tree -Dverbose`,
`help:effective-pom`, `mvnw -v`) — use them instead of trusting the table.
