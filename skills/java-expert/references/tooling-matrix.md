# Tooling & Library Matrix — verified 2026-11-27

Versions move. Treat this file as a **snapshot with a date**, never as gospel:
re-verify with the commands in §9 before pinning anything. "Current" below means
"current on 2026-11-27".

---

## 1. JDK

| Release | Date | Status | Support | Use it for |
|---|---|---|---|---|
| 8 | 2014 | Legacy | Extended only | Legacy maintenance; do not start here |
| 11 | 2018 | Legacy LTS | Extended | Legacy maintenance only |
| 17 | 2021 | LTS | Extended | Minimum for Spring Boot 4 / Jakarta EE 11 |
| 21 | 2023 | LTS | Long | Conservative production default in enterprises |
| 25 | **Sept 2025** | **LTS** | Premier → 2030, Extended → 2033 | **Recommended production default** |
| 26 | Mar 2026 | Feature | Superseded | Not a target |
| 27 | **Sept 2026** | Feature (non-LTS) | Premier → Mar 2027 | Evaluation, compatibility testing |
| 28 | Mar 2027 | Feature | — | Not a target |
| 29 | Sept 2027 | Next LTS (planned) | — | Future migration target |

**Rule:** production runs an LTS (21 or 25). Feature releases are for testing
and library compatibility. Never adopt a non-LTS release as a production
baseline you cannot leave within six months.

### Language/API features by release — what you may actually use

| Feature | Final in | Notes |
|---|---|---|
| Records, sealed types, pattern `instanceof` | 17 | Safe floor |
| Text blocks, `var`, switch expressions | 17 | Safe floor |
| Record patterns, pattern `switch` | 21 | Safe on 21+ |
| Virtual threads | 21 | Safe on 21+; do not pool them |
| Sequenced collections | 21 | `getFirst()`/`getLast()` |
| Unnamed variables `_` | 22 | Only if target ≥ 22 |
| Markdown doc comments | 23 | Only if target ≥ 23 |
| Scoped Values | 25 | Safe on 25+; prefer over `ThreadLocal` |
| Module import declarations | 25 | Safe on 25+ |
| Compact source files / instance `main` | 25 | Scripts only |
| Flexible constructor bodies | 25 | Safe on 25+ |
| Compact object headers | 25 (product), 27 (default) | JVM flag on 25; default on 27 |
| Key Derivation Function API | 25 | Pre-quantum hygiene |
| Structured concurrency | Preview (25, 27) | `--enable-preview` only |
| Primitive types in patterns | Preview | `--enable-preview` only |
| Lazy constants | Preview (27) | `--enable-preview` only |
| Vector API | Incubator | `jdk.incubator.vector` only |

**Preview features are not shippable in a library or a deliverable you cannot
rebuild on the next JDK.** If a task asks for one, implement it behind a flag
and say so.

### JDK 25 / 27 operational notes

- 27 flips **G1 to default everywhere** and **enables compact object headers
  by default** — both change heap behavior; re-baseline memory and GC logs
  before promoting.
- 27 enables **post-quantum hybrid key exchange in TLS 1.3** — check that
  old TLS terminators/load balancers in front of the app still negotiate.
- 27's **JFR redaction** covers `password`/`token`/`secret`-like values; do not
  rely on it as your only secret-hygiene control.

---

## 2. Build tools

| Tool | Stable now | Notes |
|---|---|---|
| Maven | **3.10.x** (3.10.2 recommended) | Resolver 2, stricter validation. `maven.resolver.validation` is the escape hatch |
| Maven 4 | **4.0.0-rc-7** | RC only — *not* for production branches. Build POM vs consumer POM, `before:`/`after:` phases, `mvnup` |
| Gradle | **9.8.x** (9.8.1) | Requires Java 17+ for the daemon; removed long-deprecated APIs |
| Declarative Gradle | Early access | Prototype only |

Rules:

- Commit the wrapper (`mvnw`/`mvnw.cmd` + `.mvn/wrapper`, or `gradlew` +
  `gradle/wrapper`). Pin the distribution, verify the checksum.
- Maven 3.9 → 3.10 is a routine upgrade and a good stepping stone to 4; do it
  in its own change because Resolver 2 validation surfaces previously-ignored
  POM errors.
- Do not mix a Maven build and a Gradle build in one deployable module.
- Gradle: prefer Kotlin DSL for new builds; enable configuration cache
  (`org.gradle.configuration-cache=true`) and the build cache in CI.
- Maven: `-T 1C` for parallel builds, `-Dmaven.repo.local` only in CI caches,
  never `dependency:purge-local-repository` as a "fix".

---

## 3. Frameworks

| Stack | Current | Java floor | Jakarta level | Status |
|---|---|---|---|---|
| Spring Boot 4.2 | 4.2.0 (19 Nov 2026) | 17 | EE 11 / Servlet 6.1 | Latest |
| **Spring Boot 4.1** | 4.1.3 | 17 | EE 11 | **Recommended production line** (OSS → Jul 2027) |
| Spring Boot 4.0 | 4.0.10 | 17 | EE 11 | OSS ends 31 Dec 2026 — migrate off |
| Spring Boot 3.5 | 3.5.16 (final) | 17 | EE 10 / Servlet 6.0 | OSS ended 30 Jun 2026 |
| Spring Framework | 7.0.x (Boot 4.x) / 6.2.x (Boot 3.4–3.5) | 17 | — | — |
| Jakarta EE | 11 | 17 | Servlet 6.1, JPA 3.2, CDI 4.1, Validation 3.1 | Current |
| Jakarta EE 12 | Not released | 17 | JPA 4.0, CDI 5.0 | Do not target |
| Quarkus | 3.x | 17 | EE 11 track | Current |
| Micronaut | 4.x | 17 | EE 11 track | Current |
| Helidon | 4.x | 21 | EE 11 | Current |

### Spring Boot 4 migration facts (memorize these)

- Spring Framework 7, **Jackson 3** (`tools.jackson.*`, not `com.fasterxml.*`),
  JSpecify annotations, modularized jars.
- **Servlet 6.1 / Jakarta EE 11 baseline** → Tomcat 11, Jetty 12.1+.
- **Undertow embedded server support removed** → pick Tomcat, Jetty, or
  Netty/Reactor.
- Java 17 minimum; 25 is first-class.
- Module/artifact coordinates changed for several starters — resolve by
  dependency tree, not memory.
- Boot 3.x → 4.x is a *project*, not a patch: Jackson package moves alone will
  touch every DTO mapper.

### If the task is "upgrade Spring Boot"

Ladder: `3.3 → 3.4 → 3.5 (last 3.x) → 4.0 → 4.1/4.2`. At each step: clean
build, full tests, `dependency:tree` diff, run the app, check actuator, then
commit. Never jump a major in one commit.

---

## 4. Persistence

| Library | Version | Notes |
|---|---|---|
| Hibernate ORM | **7.4.x** (7.4.17.Final) | JPA 3.2 / EE 11 / Java 17+; stable line |
| Hibernate ORM 8.0 | 8.0.0 CR | JPA 4.0 / EE 12 — pre-release |
| Hibernate Validator | 9.1.x | Jakarta Validation 3.1 |
| Spring Data JPA | 4.2.x (Boot 4.2) | Manages Hibernate 7.4 |
| Flyway | 10.x+ (verify) | Preferred for SQL-first migrations |
| Liquibase | 4.2x+ (verify) | Preferred for multi-DB / XML changelogs |
| jOOQ | 3.20 (needs Java 21) | Complex SQL, type-safe |
| Testcontainers | 1.20+ | Real DB in tests; do not mock the DB |

Rules: no `ddl-auto=update` outside a scratch profile; migrations are
forward-only and reviewed; every `@Transactional` boundary is deliberate;
N+1 is a defect (use `@EntityGraph` or projections); pagination on every
collection endpoint; `@Version` on entities with concurrent writers.

---

## 5. Testing

| Tool | Version | Use |
|---|---|---|
| JUnit Jupiter | 5.11+ / 6.x if the BOM allows | Unit + integration |
| AssertJ | 3.26+ | Readable assertions |
| Mockito | 5.x | Collaborator isolation |
| Testcontainers | 1.20+ | DB, Kafka, Redis, WireMock |
| WireMock | 3.x | HTTP contract tests |
| REST Assured | 5.x | API tests |
| Awaitility | 4.x | Async assertions (no `Thread.sleep`) |
| JaCoCo | 0.8.13+ | Must be new enough for your JDK's bytecode; older agents silently skip classes |
| ArchUnit | 1.3+ | Architecture rules as tests |

Rules: no `Thread.sleep` in tests; no shared mutable static fixtures; freeze
time (`Clock` injection) instead of asserting on `now()`; name tests
`method_condition_expected`; one behavior per test.

---

## 6. Quality, security, observability

| Concern | Tooling |
|---|---|
| Static analysis | Error Prone, SpotBugs + find-sec-bugs, PMD, Checkstyle, SonarQube |
| Dependency CVEs | OWASP Dependency-Check, `mvn versions:*`, Dependabot/Renovate |
| Security | Spring Security 6.5/7, `jakarta.security.enterprise`, OWASP ASVS checklist |
| Metrics | Micrometer + Prometheus |
| Tracing | Micrometer Tracing + OpenTelemetry (Boot 4 has an OTel starter) |
| Logging | SLF4J 2 + Logback 1.5; **JSON encoder for prod**, one binding only |
| Profiling | JFR (now with method timing/tracing on 25+), async-profiler |
| Containers | Jib (no Dockerfile), Buildpacks, distroless base images |
| Native | GraalVM for JDK 25+; Quarkus/Micronaut first-class, Boot needs work |

---

## 7. Application servers / containers

| Container | Servlet | Namespace | Java | Notes |
|---|---|---|---|---|
| Tomcat 11.0 | 6.1 | `jakarta.*` | 17+ | Current line |
| Tomcat 10.1 | 6.0 | `jakarta.*` | 11+ | EE 10 apps |
| Tomcat 9 | 4.0 | `javax.*` | 8+ | Last `javax` line |
| Jetty 12.1 | 6.1 | `jakarta.*` | 17+ | EE 11 environment |
| WildFly 3x | 6.1 | `jakarta.*` | 17+ | Full platform, has classloading descriptors |
| WebLogic 15.x | 6.0 | `jakarta.*` | 17+ | `weblogic.xml` classloading preferences |
| WebSphere Liberty | 6.1 | `jakarta.*` | 17+ | Feature-based install |

Container choice constrains the WAR: **the Servlet API version and the
`javax`/`jakarta` namespace are decided by the container, not by preference.**

---

## 8. Version floors worth enforcing in a review

Floors, not latest-known versions: they are the minimum you may accept, and
they are revised per CVE. Confirm the current patch with §9 before writing a
pin.

| Artifact | Floor | Reason |
|---|---|---|
| Log4j2 | 2.17.1+ | CVE-2021-44228 lineage |
| Spring Framework | 6.2.x / 7.0.x | CVE stream + Boot support |
| Jackson | BOM-managed | CVE stream |
| Tomcat | latest 10.1.x / 11.0.x | CVE stream |
| SnakeYAML | 2.2+ | Deserialization RCE class |
| H2 (test) | 2.2.224+ | JNDI RCE class |
| Commons-Text / BC | BOM-managed | CVE stream |
| Maven | 3.10.x | Resolver 2 validation |
| Gradle | 9.8.x | Daemon security fixes |

---

## 9. How to verify currency (do this, don't trust memory)

```bash
# Dependencies and plugins with updates available
./mvnw -q versions:display-dependency-updates
./mvnw -q versions:display-plugin-updates
./mvnw -q versions:display-property-updates

# Gradle
./gradlew dependencyUpdates            # ben-manes/gradle-versions-plugin

# Effective versions actually resolved (the truth)
./mvnw -q dependency:tree -Dverbose
./mvnw -q help:effective-pom

# Duplicate / conflicting classes
./mvnw -q dependency:tree -Dincludes=org.slf4j
jar tf target/app.war | grep -i "servlet-api"

# Toolchain actually used
./mvnw -v ; ./gradlew -v ; java -version
```

External checks when you have network: Maven Central metadata
(`mvn versions:*` above is enough), the upstream release notes RSS for Spring
Boot, Hibernate's compatibility matrix, and the container's changelog for the
CVE you are chasing.

---

## 10. Upgrade decision record (write one of these)

```markdown
### Upgrade: Spring Boot 3.5.16 → 4.1.3
Why: 3.5 OSS support ended 2026-06-30.
Scope: parent version, Jackson 3 package migration (12 files), Undertow → Tomcat.
Risk: Jackson 3 API moves; Undertow threads config must be ported to Tomcat.
Tests: full `clean verify`, container smoke test, JSON contract diff.
Rollback: revert single commit; schema untouched.
Go/No-go: <decision + who approved>
```
