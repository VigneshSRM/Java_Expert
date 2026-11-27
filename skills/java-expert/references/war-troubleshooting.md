# WAR / Servlet-Container Troubleshooting

Deep reference for Job E. Work top-down: **artifact → classpath → lifecycle →
routing → resources**. Most "WAR issues" are one of: wrong namespace, wrong
scope, version skew, or a classloader assumption that stopped being true.

---

## 1. Mental model: what actually loads your classes

```
Bootstrap (JDK)
  └─ System classloader (container's lib/*.jar, JDK modules)
       └─ Webapp classloader (WEB-INF/classes, WEB-INF/lib/*.jar)
            └─ (optional) shared/common loader configured by the container
```

Consequences you must reason from:

1. **`WEB-INF/lib` wins over container libs** in Tomcat's default
   `delegate=false` (webapp-first) mode. Two versions of a class on different
   levels is how you get `LinkageError`/`ClassCastException`.
2. **Duplicating the Servlet API inside the WAR breaks the container contract.**
   The container's instance and the app's instance come from different loaders.
3. **Static state is per-classloader.** After undeploy, any live thread holding
   a webapp class keeps the whole loader alive → Metaspace leak.
4. **A WAR is a ZIP.** Every "it works in the IDE" gap is usually a missing jar
   in `WEB-INF/lib`.

---

## 2. First three commands

```bash
# 1. What is in it?
scripts/war-inspect.sh target/app.war

# 2. Does the class exist, and where?
unzip -l target/app.war | grep -i "servlet-api\|jakarta\|javax"
unzip -p target/app.war META-INF/MANIFEST.MF

# 3. Bytecode version of the classes (69 = Java 25, 65 = 21, 61 = 17, 55 = 11, 52 = 8)
unzip -p target/app.war WEB-INF/classes/com/acme/App.class | head -c 8 | od -An -tu1
```

Class-file major version map:

| Bytecode | Java | | Bytecode | Java |
|---|---|---|---|---|
| 52 | 8 | | 65 | 21 |
| 55 | 11 | | 66 | 22 |
| 61 | 17 | | 67 | 23 |
| 62 | 18 | | 68 | 24 |
| 63 | 19 | | 69 | 25 |
| 64 | 20 | | 70 | 26 |
| | | | 71 | 27 |

---

## 3. Signature bank

### 3.1 Name resolution / namespace

| Log signature | Root cause | Diagnosis | Fix |
|---|---|---|---|
| `ClassNotFoundException: javax.servlet.http.HttpServlet` | App compiled against Java EE, running on Tomcat 10.1/11 | `grep -rn "javax.servlet" src/`; container is EE 11 | Migrate to `jakarta.*` (§4), or deploy on Tomcat 9 |
| `ClassNotFoundException: jakarta.servlet.http.HttpServlet` | App is `jakarta` but container is Tomcat 9 | `unzip -p app.war WEB-INF/web.xml \| head` | Deploy on Tomcat 10.1/11, or downgrade namespace |
| `ClassCastException: jakarta.servlet.X cannot be cast to javax.servlet.X` | **Mixed namespaces**: one dependency still ships `javax` | Inspect `WEB-INF/lib` for jars with `javax/servlet` entries | Upgrade/replace the stale lib; never bundle both |
| `NoClassDefFoundError: jakarta/servlet/jsp/jstl/core/Config` | JSTL 1.2 (`javax`) on a `jakarta` container | Check JSTL jar version | Use JSTL 3.x (`jakarta.servlet.jsp.jstl`), update taglib URIs to `jakarta.tags.core` |
| `The absolute uri: http://java.sun.com/jsp/jstl/core cannot be resolved` | Old taglib URI with new JSTL, or JSTL missing | Look for `.tld` in the WAR | Use `jakarta.tags.*` URIs and JSTL 3.x, or keep JSTL 1.2 on Tomcat 9 |
| `UnsupportedClassVersionError: ... class file version 69.0` | WAR bytecode 25, container JRE 21 | `java -version` of the container | Set `maven.compiler.release` to the container's JDK, or upgrade the container |
| `Unsupported major.minor version 61.0` | Same, older pair | Same | Same |
| `NoSuchMethodError: jakarta.servlet.http.HttpServletRequest.getX()` | Servlet API version skew (compiled on 6.1, running 6.0) | Compare `jakarta.servlet-api` in build vs container | Align to the container's Servlet level; never ship the API |

### 3.2 Classpath / packaging

| Log signature | Root cause | Diagnosis | Fix |
|---|---|---|---|
| `NoClassDefFoundError` at runtime but compiles | Dependency scoped `provided`, container doesn't ship it | `mvn dependency:tree -Dscope=provided` | Change to `compile`, or install into the container's lib (last resort) |
| `NoSuchMethodError` / `AbstractMethodError` on your own classes | Two versions of your lib in `WEB-INF/lib` | `unzip -l app.war \| grep -c "same-artifact"`; `dependency:tree -Dverbose` | Exclude the loser; enforce convergence (`maven-enforcer`) |
| `Class path contains multiple SLF4J providers` | Duplicate bindings (logback + log4j-slf4j2 + slf4j-simple) | `unzip -l app.war \| grep -i "slf4j\|logback\|log4j"` | Exclude all but one binding |
| `java.lang.LinkageError: loader constraint violation` | Same class from two loaders, or split package | Full message names both loaders | Remove duplicate jar; avoid `tomcat/lib` copies |
| `java.util.ServiceConfigurationError` | Duplicate/incomplete `META-INF/services` entries | `unzip -l app.war \| grep META-INF/services` | Exclude duplicate provider jar; merge services file if hand-built |
| `ZipException: invalid LOC header (bad signature)` | Corrupt or truncated WAR, or edited-in-place ZIP | `unzip -t app.war` | Rebuild from source; never patch the ZIP |
| `java.lang.IllegalArgumentException: MALFORMED` on upload | WAR > 2 GB without ZIP64, or bad encoding | Compare size | Enable ZIP64 / split the app |
| App works in IDE, 404/500 in container | IDE used the classpath of the *project*, not the WAR | Diff IDE classpath vs `WEB-INF/lib` | Reproduce with the real artifact (§7) |

### 3.3 Startup / Spring context

| Log signature | Root cause | Fix |
|---|---|---|
| `NoClassDefFoundError: org/springframework/web/context/ContextLoaderListener` | `spring-web` marked `provided` or excluded | Make it `compile`; re-check exclusions |
| `BeanDefinitionOverrideException` | Duplicate bean definition (double component scan, two contexts) | Merge/limit `@ComponentScan`; check parent context |
| `NoSuchBeanDefinitionException` in a WAR but not a JAR | Child context can't see parent beans | Inject via parent, or `@Import`; don't rely on classloader hierarchy |
| `NoSuchMethodError: org.springframework...` | Spring version skew (two Spring jars) | Let the Boot BOM own versions; remove explicit versions |
| `java.lang.IllegalStateException: Unable to find ... ServletWebServerApplicationContext` | Boot app deployed to a container without `SpringBootServletInitializer` | See §5 checklist |
| `ApplicationContextException: Unable to start ... due to missing ServletWebServerFactory` | Boot web starter excluded | Add `spring-boot-starter-web` |
| `Failed to configure a DataSource: 'url' attribute is not specified` | Profile missing in container env | Set `SPRING_PROFILES_ACTIVE`/config location for the container |
| `Address already in use` | Port conflict | Change port, or stop the other process — not a WAR defect |

### 3.4 Routing / serving

| Symptom | Root cause | Fix |
|---|---|---|
| 404 on all paths | Context path mismatch (`app.war` → `/app`), or `metadata-complete="true"` suppressing annotations, or servlets in an unscanned package | Check URL vs WAR name; remove `metadata-complete` or declare in `web.xml` |
| 404 on `/` only, others fine | No welcome file, or root servlet unmapped | Add `welcome-file-list` or map `/` |
| 404 only for `.jsp` | No JSP engine (Jasper) on the container, or JSP placed under `WEB-INF` | Add JSP support; move JSP to a publicly reachable path |
| 500 with `Unable to compile class for JSP` | JSP uses APIs the container's JDK lacks, or JRE-only runtime (`No Java compiler available`) | Run the container on a **JDK**, align JSP source level |
| 405 on POST | Servlet overrides `doGet` only, or a filter blocks the method | Implement the correct `doX`, check filter chain |
| 403 on static assets | Spring Security path matcher catches `/css/**`, `/js/**` | Permit static paths explicitly |
| `Invalid <url-pattern>` at deploy | Malformed `<url-pattern>` in `web.xml`/`@WebServlet` | Fix pattern (`/api/*`, not `api/*`) |
| `metadata-complete` ignores annotations | Descriptor says so | Remove the attribute or port annotations to XML |
| `Session already invalidated` / lost session across nodes | No session replication/stickiness | Configure persistence or a session store |

### 3.5 Runtime / lifecycle / leaks

| Symptom | Root cause | Fix |
|---|---|---|
| `OutOfMemoryError: Metaspace` growing per redeploy | Classloader leak: `ThreadLocal`, unstopped threads, JDBC driver registered in webapp loader, static caches, logging MDC, `java.util.Timer` | See §6 |
| `java.lang.IllegalStateException: The web application appears to have started a thread but has failed to stop it` | Unstopped `ExecutorService` | Shut down executors in `@PreDestroy`/`contextDestroyed` |
| `InaccessibleObjectException` on 17+ | Reflective access to JDK internals (old cglib/Jackson/Hibernate) | Upgrade the lib, else `--add-opens` in `setenv.sh`/`jvm.config` |
| Permgen/Metaspace fine, but heap fills after redeploy | Static `Map` in a container-level class | Move caches out of the webapp, or bound + evict them |
| `NotSerializableException` on restart | Session attribute not `Serializable` | Make it serializable or store an id |
| Slow first request, then fast | Lazy init/JIT warmup; not a defect | Measure with JFR before "optimizing" |
| `java.io.IOException: Permission denied` on explode | Read-only `webapps/`, wrong owner, SELinux | Fix permissions on the deploy dir; run container as the owning user |

### 3.6 Container-specific

| Container | Signature | Fix |
|---|---|---|
| Tomcat | `SEVERE: Error deploying web application archive` with no cause shown | The real cause is a `Caused by:` earlier or in `localhost.<date>.log`; raise `org.apache.catalina` to `FINE` if absent |
| Tomcat | `JAR file ... is unreadable` / `invalid LOC` | Corrupt download; re-copy |
| Tomcat | `Deployment of web application archive ... has failed due to a StackOverflowError` | Recursive scan/config; check regex or circular init |
| WildFly | `WFLYCTL0180: Services with missing/unavailable dependencies` | Read the full `WFLYSRV0153` block; usually a failed datasource/JMS lookup |
| WildFly | `ClassNotFoundException` for a jar that *is* in `WEB-INF/lib` | `jboss-deployment-structure.xml` excluding it, or `jboss-classloading.xml` parent-first |
| WebLogic | `ClassCastException` with same class name from two loaders | Add `<prefer-application-packages>` in `weblogic.xml` |
| WebLogic | `weblogic.application.ModuleException: ... UnsupportedClassVersionError` | Server JDK too old |
| Jetty | `java.lang.NoClassDefFoundError: jakarta/servlet/http/HttpServlet` | Missing `jetty-ee10-servlet`/`ee11` module for the namespace |
| Any | `java.lang.NoClassDefFoundError: Could not initialize class X` | A `static {}` initializer threw; the *first* failure's stack trace is the real one |

---

## 4. `javax` → `jakarta` migration (only when the container forces it)

Do **not** start this because you saw `javax` imports. Start it when the target
container is Tomcat 10.1/11, WildFly 3x, WebLogic 15+, or Jakarta EE 10+, or a
delegating skill explicitly asks for it.

1. **Inventory usage**
   ```bash
   grep -rln "javax\.\(servlet\|persistence\|validation\|annotation\|inject\|ws\.rs\|enterprise\|faces\|el\|json\|mail\|websocket\|transaction\|jms\|xml\.bind\)" src/
   ```
2. **Update imports** (deterministic mapping):

   | Java EE | Jakarta |
   |---|---|
   | `javax.servlet.*` | `jakarta.servlet.*` |
   | `javax.persistence.*` | `jakarta.persistence.*` |
   | `javax.validation.*` | `jakarta.validation.*` |
   | `javax.annotation.*` | `jakarta.annotation.*` |
   | `javax.inject.*` | `jakarta.inject.*` |
   | `javax.ws.rs.*` | `jakarta.ws.rs.*` |
   | `javax.enterprise.*` | `jakarta.enterprise.*` |
   | `javax.faces.*` | `jakarta.faces.*` |
   | `javax.el.*` | `jakarta.el.*` |
   | `javax.json.*` | `jakarta.json.*` |
   | `javax.mail.*` | `jakarta.mail.*` |
   | `javax.websocket.*` | `jakarta.websocket.*` |
   | `javax.transaction.*` | `jakarta.transaction.*` |

3. **Update `web.xml`** — namespace + version + schema URI must match the target:

   | Container | Servlet | `web-app` version | Namespace |
   |---|---|---|---|
   | Tomcat 9 | 4.0 | `4.0` | `http://xmlns.jcp.org/xml/ns/javaee` |
   | Tomcat 10.1 | 6.0 | `6.0` | `https://jakarta.ee/xml/ns/jakartaee` |
   | Tomcat 11 | 6.1 | `6.1` | `https://jakarta.ee/xml/ns/jakartaee` |

4. **Update dependencies** to the matching API level. In Spring Boot, **let the
   Boot BOM decide** — Boot 4 = Jakarta EE 11 / Servlet 6.1.
5. **Audit third-party jars** — anything still shipping `javax/servlet` classes
   will fail at runtime even though it compiles. This is the step people skip.
6. **Update JSP taglib URIs** (`http://java.sun.com/jsp/jstl/core` →
   `jakarta.tags.core`) and JSTL artifact (`javax.servlet:jstl` →
   `jakarta.servlet.jsp.jstl:jakarta.servlet.jsp.jstl-api` + impl).
7. **Rebuild, inspect the artifact, deploy, smoke test.** Keep the change on its
   own branch; it is not a diff you can review mixed with feature work.

Automated help exists (Apache Tomcat Migration Tool for Jakarta EE), but verify
its output by inspection — it will not fix stale third-party jars.

---

## 5. Spring Boot → WAR: the three fixed requirements

```xml
<packaging>war</packaging>          <!-- 1 -->

<dependency>
  <groupId>org.springframework.boot</groupId>
  <artifactId>spring-boot-starter-tomcat</artifactId>
  <scope>provided</scope>           <!-- 2 -->
</dependency>
```

```java
// 3
public class ServletInitializer extends SpringBootServletInitializer {
    @Override
    protected SpringApplicationBuilder configure(SpringApplicationBuilder app) {
        return app.sources(Application.class);
    }
}
```

Checklist when a Boot WAR "starts but serves nothing":

- [ ] Packaging is `war`, artifact name drives the context path.
- [ ] `SpringBootServletInitializer` subclass exists and is on the classpath.
- [ ] `spring-boot-starter-tomcat` is `provided` (not `compile`, not absent).
- [ ] No `ServletWebServerFactory` customization meant for embedded mode.
- [ ] `spring-boot-maven-plugin` is **not** producing an executable fat WAR in a
      container deployment (`repackage` off, or use the `war` plugin).
- [ ] Actuator paths don't collide with the context path.
- [ ] `server.servlet.context-path` is empty in container mode — the container
      owns the context path.

---

## 6. Classloader-leak checklist (redeploy OOM: Metaspace)

For each item, grep the codebase. Present = likely leak.

- [ ] `ThreadLocal` / `InheritableThreadLocal` with no `remove()`.
- [ ] Threads started by the app: `new Thread`, `Executors.*`, `Timer`,
      `ScheduledExecutorService` — all must be shut down on context destroy.
- [ ] JDBC drivers registered from `WEB-INF/lib` (Tomcat logs
      `The web application ... registered the JDBC driver ... but failed to
      unregister it`).
- [ ] `DriverManager`/`MBeanServer`/`SecurityManager` registrations.
- [ ] Static caches/registries with no clear method (`Map`, `List`, Guava
      caches, Caffeine without shutdown).
- [ ] `java.util.logging` handlers attached to container loggers.
- [ ] Shutdown hooks added by the webapp (`Runtime.addShutdownHook`).
- [ ] Third-party libs known to leak (old `dom4j`, old `c3p0`, some XML parsers,
      some `Abdera`/`Tika` paths) — check with a heap dump.
- [ ] Threads created by scheduled tasks, message listeners, or async executors
      without `destroyMethod`.

Verify with:

```bash
# Watch Metaspace across 3 redeploys
jcmd <pid> VM.metaspace summary
# or
jstat -gcmetacapacity <pid> 5s
```

A monotonic rise across redeploys with no traffic is conclusive.

---

## 7. Reproduce locally before declaring a fix

```bash
# Build the exact artifact
./mvnw -q clean package

# Inspect
scripts/war-inspect.sh target/app.war

# Run it the way production does (pick one)
docker run --rm -p 8080:8080 \
  -v "$PWD/target/app.war:/usr/local/tomcat/webapps/app.war" \
  tomcat:11-jdk21

# Smoke test
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8080/app/actuator/health
curl -sS http://localhost:8080/app/api/ping
```

Minimum smoke set: health endpoint, one authenticated call, one 404, one static
asset, one JSP if used, and a log check with no `SEVERE`/`ERROR` at startup.

---

## 8. Anti-patterns (do not do these)

| Anti-pattern | Why it's wrong | Do instead |
|---|---|---|
| Copy jars into `tomcat/lib` | Global mutation, hides conflicts, breaks other apps | Fix the WAR's own classpath |
| Delete `WEB-INF/lib` jars until it starts | Non-deterministic; will break elsewhere | Diff the dependency tree, exclude explicitly |
| Ship `javax.servlet-api`/`jakarta.servlet-api` in the WAR | Two API copies, cast errors | `provided` scope |
| Patch the WAR ZIP in place | Unreproducible artifact | Rebuild |
| Set `delegate=true` globally to "fix" classloading | Breaks webapp isolation for everything | Fix the specific duplication |
| Add `--add-opens` for every module | Masks outdated libs; weakens encapsulation | Upgrade the lib; scope the flag |
| Redeploy to "clear" the error | Hides leaks; extends outage | Fix the leak |
| Ignore the first `Caused by:` | You fix the symptom | Read to the deepest cause |
| Bump the container to match the WAR without testing | New namespace/behavior breaks other apps | Align the WAR to the fleet's standard container |
