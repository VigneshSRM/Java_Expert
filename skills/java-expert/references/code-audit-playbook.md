# Code Audit & Fix Playbook

Use for Job D ("analyze and fix the issues"). Run
`scripts/java-audit.sh <repo>` for the mechanical pass, then work this playbook
by severity. **Findings are ranked and evidenced; a wall of nits is a failed
audit.**

Severity: **P0** data loss / RCE / auth bypass / secret leak · **P1** wrong
results, race, leak, deploy failure, reachable CVE · **P2** latent bug,
performance cliff · **P3** style, dead code, missing test.

---

## 0. Audit sequence

1. **Build it** (`clean verify`). Build breakage is finding #1.
2. **Map the shape**: modules, entry points, persistence, external calls,
   scheduled work, security config.
3. **Read the diff surface first.** If you are auditing a change, that is the
   only place P0/P1 findings matter.
4. **Scan by category** (§1–§8), recording `file:line`, mechanism, severity.
5. **Reproduce** the top 3 before fixing.
6. **Fix P0/P1**, verify, report P2/P3 without touching them unless asked.

---

## 1. Correctness

| Check | Detection | Fix pattern |
|---|---|---|
| Mutable default/static collections | `grep -rn "static.*\(Map\|List\|Set\)<" src/` | `List.of()`, `Map.copyOf()`, unmodifiable views |
| `==` on boxed/String | `grep -rnE '== *"' src/` ; SpotBugs `ES_COMPARING_STRINGS_WITH_EQ` | `.equals` / `Objects.equals` |
| `equals` without `hashCode` | SpotBugs `HE_EQUALS_USE_HASHCODE` | Implement both, or use a record |
| Float equality | `grep -rnE '(double\|float).*==' src/` | `BigDecimal` for money; epsilon for metrics |
| Money as `double` | `grep -rn "double.*\(amount\|price\|total\)"` | `BigDecimal` + `RoundingMode`, or minor units as `long` |
| `Optional.get()` unchecked | `grep -rn "\.get()" src/ \| grep -i optional` | `orElseThrow`, `map`, `ifPresent` |
| Null-hostile public API | Missing `@Nullable`/`@NonNull` | Add JSpecify annotations at boundaries |
| Off-by-one in pagination | Page index vs offset math | Pass `Pageable`, assert total pages in a test |
| Timezone-naive timestamps | `grep -rn "new Date()\|SimpleDateFormat\|Calendar"` | `Instant`/`ZonedDateTime`, `Clock` injected |
| `switch` without `default` on enums | PMD `MissingSwitchDefault` | Add `default` or make the switch exhaustive on a sealed type |

---

## 2. Concurrency

| Check | Detection | Fix pattern |
|---|---|---|
| Non-thread-safe singleton fields | `@Service`/`@Component` with mutable fields | Remove state; use locals or `ThreadLocal`/`ScopedValue` |
| `SimpleDateFormat` shared | `grep -rn "SimpleDateFormat"` | `DateTimeFormatter` (immutable) |
| `HashMap` shared across threads | Field of type `HashMap` in a singleton | `ConcurrentHashMap`, or confine it |
| Check-then-act races | `if (map.containsKey) map.get` | `computeIfAbsent`, atomic APIs |
| Unbounded executors | `Executors.newFixedThreadPool` w/o bounds, `newCachedThreadPool` | Bounded pool + queue + rejection policy |
| Pooling virtual threads | `Executors.newVirtualThreadPerTaskExecutor` wrapped in a pool | Never pool; one executor per task set |
| `synchronized` on hot path with blocking I/O | `grep -rn "synchronized"` | Narrow the lock; use `ReentrantLock` (vthread-friendly) |
| Missing timeouts | `HttpClient`, `RestTemplate`, `WebClient`, JDBC without timeout | Set connect/read/response timeouts everywhere |
| `Thread.sleep` in tests/prod | `grep -rn "Thread.sleep"` | `Awaitility`; in prod, a scheduled task |
| `CompletableFuture` swallowed errors | `.thenApply` without `exceptionally`/`whenComplete` | Handle or propagate; log with context |

---

## 3. Resources & leaks

| Check | Detection | Fix pattern |
|---|---|---|
| Unclosed streams/connections | SpotBugs `OS_OPEN_STREAM`, `ODR_OPEN_DATABASE_RESOURCE` | Try-with-resources |
| `finally { close() }` | `grep -rn "finally" src/ \| grep -i close` | Try-with-resources, or `closeQuietly` in the finally only |
| Connection pool exhaustion | Pool size vs concurrency; long transactions | Bound transactions; close early; tune pool ≈ 2× cores for blocking |
| Caches without bounds | `new HashMap<>()` used as cache | Caffeine with `maximumSize` + `expireAfterWrite` |
| `Files.lines`/`Stream` not closed | SpotBugs `OS_OPEN_STREAM` | Try-with-resources |
| Growing in-memory lists from queries | `findAll()` on unbounded tables | `Pageable`, streaming, projection |

---

## 4. Security (P0/P1 by default)

| Check | Detection | Fix pattern |
|---|---|---|
| SQL/JPQL concatenation | `grep -rnE '"(select\|update\|delete\|insert).*\+' src/` | Parameters/bindings; Criteria API |
| Secrets in repo | `grep -rnE "(password\|secret\|token\|apikey)\s*[:=]\s*[\"'][^\"']{6,}"` | Env/vault; rotate the exposed secret |
| Verbose error to client | `@ExceptionHandler` returning `e.getMessage()`/stack trace | Generic message + correlation id; log details |
| Missing `@Valid` on bodies | Controller method params without `@Valid` | Add + `@ControllerAdvice` |
| Authorization on read only | Mutating endpoints without `@PreAuthorize`/filter rule | Deny by default; authorize each mutation |
| CORS `*` with credentials | `allowedOrigins("*")` + `allowCredentials(true)` | Explicit origin list |
| Disabled TLS verification | `TrustAllStrategy`, `NoopHostnameVerifier` | Proper truststore |
| Deserialization of untrusted data | `ObjectInputStream`, unsafe Jackson polymorphic typing | Allowlist, `@JsonTypeInfo` with a validator |
| Weak crypto | `MD5`, `SHA1`, `DES`, `ECB` | SHA-256+, AES-GCM, Argon2/bcrypt for passwords |
| Path traversal | `new File(base + userInput)` | Normalize + verify prefix, or map ids to paths |
| SSRF | Server-side fetch of user URL | Allowlist hosts/schemes; block link-local |
| Log injection / PII | Logging raw user input or tokens | Structured logging, redaction |
| Actuator exposed | `management.endpoints.web.exposure.include=*` | Expose only health/info; secure the rest |
| Outdated vulnerable dep | `mvn versions:display-dependency-updates` + advisory DB | Upgrade to the fixed line; document mitigation otherwise |

---

## 5. Persistence / JPA

| Check | Detection | Fix pattern |
|---|---|---|
| N+1 selects | Log SQL with `hibernate.show_sql` in a test; count | `@EntityGraph`, join fetch, projection |
| `EAGER` everywhere | `grep -rn "FetchType.EAGER"` | `LAZY` + explicit fetch at the use site |
| `equals`/`hashCode` on entities with generated ids | `grep -rn "public boolean equals"` in entities | Identity by id, or business key; never `Objects.equals` on all fields |
| `ddl-auto=update` outside tests | `grep -rn "ddl-auto"` | Flyway/Liquibase; validate in prod |
| Transaction on controller | `@Transactional` outside the service layer | Service-level boundaries |
| Lost updates | No `@Version` on concurrently written entities | Optimistic locking |
| `findAll()` then filter in memory | `grep -rn "findAll()"` | Query with predicates |
| String-based JPQL with `LIKE %x%` | Full table scan | Trigram index or dedicated search |
| Batch inserts without batching | `saveAll` in a loop, no `hibernate.jdbc.batch_size` | Enable batching, flush/clear periodically |
| Open Session in View | `spring.jpa.open-in-view=true` (default) | Disable; fetch explicitly |

---

## 6. API & design

| Check | Detection | Fix pattern |
|---|---|---|
| Leaking entities in responses | Controller returns `@Entity` | DTO/record mapping |
| Breaking change to a wire format | Field rename/removal in a DTO | Additive change; version the API |
| `Optional` as a field/param | `grep -rn "Optional<"` in fields | Return type only |
| Exceptions as control flow | `catch (X) { return null; }` | Explicit result type or propagate |
| God service (>500 LOC, 15 deps) | File size, constructor arity | Extract collaborators |
| Interface with one impl and no test seam | Pure ceremony, or hidden seam | Keep if it enables testing/DI, else remove |
| Distributed transaction without compensation | Multiple repos in one method | Outbox/Saga; document it |
| Unbounded retries | `@Retryable` without `maxAttempts` | Bounded + backoff + jitter + idempotency |
| Missing idempotency on POST | No idempotency key | Key table or natural dedupe |

---

## 7. Build & dependency hygiene

| Check | Detection | Fix pattern |
|---|---|---|
| Explicit versions over a BOM | `grep -c "<version>" pom.xml` vs deps with managed artifacts | Remove versions; let the BOM own them |
| Version ranges / `LATEST` | `grep -rn "LATEST\|RELEASE\|\[1.0," pom.xml` | Pin exact versions |
| Snapshot in a release | `grep -rn "SNAPSHOT" pom.xml` | Release dependency |
| Missing enforcer | No `maven-enforcer-plugin` | Ban duplicates, require Java/Maven versions, convergence |
| Dependency convergence | `mvn enforcer:enforce -Drules=dependencyConvergence` | Exclude/align |
| Duplicate logging bindings | `dependency:tree \| grep -i "slf4j\|logback\|log4j"` | One binding only |
| Test deps leaking to runtime | `provided`/`test` missing | Correct scopes |
| No wrapper committed | `ls mvnw gradlew` | Commit the wrapper |
| Java version not enforced | No `maven.compiler.release` / toolchain | Set `release` explicitly |
| Build not reproducible | Timestamps, `-SNAPSHOT`, unpinned plugins | Pin plugins, `project.build.outputTimestamp` |

---

## 8. Tests

| Check | Detection | Fix pattern |
|---|---|---|
| Tests asserting nothing | `grep -rn "assert" \| wc -l` vs test count; mutation testing | Real assertions |
| Sleeping | `grep -rn "Thread.sleep"` | Awaitility |
| Shared mutable state | Static fields in tests | Per-test fixtures |
| Real clock/db in unit tests | `LocalDate.now()`, live DB URL | Inject `Clock`; Testcontainers |
| Mocked repository | `@Mock` on a repository | Testcontainers + real DB for SQL correctness |
| No failure-path test | Only happy-path names | Add error/edge tests |
| Flaky ordering | `@TestMethodOrder` used to hide coupling | Independent tests |
| Coverage theatre | 90% coverage, no assertions | Prefer mutation testing on core logic |

---

## 9. Modernization (only when in scope)

Apply deliberately, one type at a time, with tests green between steps.

1. **Records** for DTOs/value objects. Not for JPA entities or mutable builders.
2. **`sealed` + pattern `switch`** for closed hierarchies → compiler-checked
   exhaustiveness, no `default` silently swallowing new cases.
3. **Text blocks** for SQL/JSON literals; keep them parameterized.
4. **`var`** only when the type is obvious from the right-hand side.
5. **`Optional`** chaining instead of nested null checks.
6. **Virtual threads** for blocking fan-out; remove pools, remove `synchronized`
   around I/O.
7. **`ScopedValue`** for request-scoped context (final in 25).
8. **`List.of`/`Map.of`/`Stream.toList()`** for immutable collections.
9. **`Closeable`/try-with-resources** everywhere.
10. **Structured concurrency** only under `--enable-preview` and only in an
    explicitly experimental module.

Each modernization step must be behavior-preserving and separately reviewable.

---

## 10. Finding + report format

```markdown
### [P1] Order totals lose precision
`src/main/java/com/acme/order/OrderService.java:142`
Mechanism: `double total` accumulates line items, then is formatted with
`String.format("%.2f")`; binary floating point cannot represent 0.1.
Evidence: `OrderServiceTest.rounding_fails_onThreeItems` (added) fails with 29.099999.
Fix: `BigDecimal` with `RoundingMode.HALF_UP` at the boundary; scale 2.
Verified: `mvn -q -Dtest=OrderServiceTest test` → 8 passed.
```

Then a ranked summary table:

| # | Sev | Finding | File:line | Status |
|---|---|---|---|---|
| 1 | P1 | ... | ... | fixed |
| 2 | P2 | ... | ... | reported |

State explicitly what you did **not** fix and why. Silence reads as "no other
issues exist", which is almost never true.
