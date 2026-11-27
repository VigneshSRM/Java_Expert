#!/usr/bin/env bash
# env-probe.sh — first-contact reconnaissance for a Java repository.
# Read-only. Safe to run anywhere. No JDK required.
#
# Usage: scripts/env-probe.sh [repo-path]
#
# Reports: build tool, effective Java target, framework + versions, packaging,
# web/persistence stack, tests, modules, wrapper state, and red flags.

set -uo pipefail

ROOT="${1:-.}"
cd "$ROOT" 2>/dev/null || { echo "env-probe: cannot cd to '$ROOT'" >&2; exit 2; }

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; OFF=$'\033[0m'
if [ ! -t 1 ]; then BOLD=""; DIM=""; RED=""; YEL=""; GRN=""; OFF=""; fi

sect() { printf '\n%s== %s ==%s\n' "$BOLD" "$1" "$OFF"; }
val()  { printf '  %-22s %s\n' "$1" "$2"; }
flag() { printf '  %s!%s %s\n' "$YEL" "$OFF" "$1"; }
bad()  { printf '  %sx%s %s\n' "$RED" "$OFF" "$1"; }
ok()   { printf '  %sok%s %s\n' "$GRN" "$OFF" "$1"; }

first_line() { head -n1 2>/dev/null; }

printf '%sJava Expert — environment probe%s\n' "$BOLD" "$OFF"
printf '%s%s%s\n' "$DIM" "$(pwd)" "$OFF"

# --------------------------------------------------------------------------
sect "Repository"
if [ -d .git ]; then
  val "branch" "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
  val "HEAD" "$(git log --oneline -1 2>/dev/null || echo '?')"
  val "dirty files" "$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
else
  flag "not a git repository"
fi
if command -v find >/dev/null 2>&1; then
  val "java files" "$(find . -name '*.java' -not -path './.git/*' -not -path '*/target/*' -not -path '*/build/*' 2>/dev/null | wc -l | tr -d ' ')"
  val "test files" "$(find . -path '*/src/test/*' -name '*.java' -not -path '*/target/*' 2>/dev/null | wc -l | tr -d ' ')"
fi

# --------------------------------------------------------------------------
sect "Build tool"
BUILD="none"
POM=""; GRADLE=""
if [ -f pom.xml ]; then BUILD="maven"; POM="pom.xml"; fi
if [ -f build.gradle.kts ]; then BUILD="${BUILD/maven/maven+gradle}"; [ "$BUILD" = "none" ] && BUILD="gradle"; GRADLE="build.gradle.kts"; fi
if [ -f build.gradle ]; then BUILD="${BUILD/gradle/gradle+groovy}"; [ "$BUILD" = "none" ] && BUILD="gradle"; GRADLE="${GRADLE:-build.gradle}"; fi
val "detected" "$BUILD"
[ "$BUILD" = "maven+gradle" ] && flag "both pom.xml and a Gradle build present — confirm the real build"
[ -n "$GRADLE" ] && val "gradle script" "$GRADLE"

if [ -f mvnw ]; then ok "maven wrapper (mvnw) committed"; else [ "$BUILD" != "none" ] && flag "no mvnw wrapper"; fi
if [ -f gradlew ]; then ok "gradle wrapper (gradlew) committed"; fi
[ -f .mvn/wrapper/maven-wrapper.properties ] && val "maven dist" "$(grep -m1 distributionUrl .mvn/wrapper/maven-wrapper.properties | sed 's/.*\///')"

if command -v java >/dev/null 2>&1; then
  val "java -version" "$(java -version 2>&1 | first_line)"
else
  flag "no 'java' on PATH (versions below come from config only)"
fi
if command -v mvn >/dev/null 2>&1; then val "mvn" "$(mvn -v 2>/dev/null | first_line)"; fi
if command -v gradle >/dev/null 2>&1; then val "gradle" "$(gradle -v 2>/dev/null | grep -m1 '^Gradle')"; fi

# --------------------------------------------------------------------------
sect "Effective Java target (authoritative)"
TARGET=""
[ -f .java-version ] && { TARGET="$(cat .java-version)"; val ".java-version" "$TARGET"; }
[ -f .sdkmanrc ] && val ".sdkmanrc" "$(grep -m1 'java=' .sdkmanrc || echo present)"
if [ -n "$POM" ]; then
  for key in maven.compiler.release maven.compiler.target java.version maven.compiler.source; do
    v=$(grep -oE "<${key}>[^<]+</${key}>" "$POM" 2>/dev/null | head -1 | sed -E "s/.*<${key}>([^<]+)<\/${key}>/\1/")
    [ -n "$v" ] && { val "$key" "$v"; [ -z "$TARGET" ] && TARGET="$v"; }
  done
  if grep -q '<release>' "$POM" 2>/dev/null; then
    val "<release> (plugin)" "$(grep -m1 -A0 '<release>' "$POM" | sed -E 's/.*<release>([^<]+).*/\1/')"
  fi
  grep -q 'maven-toolchains-plugin\|toolchains.xml' "$POM" 2>/dev/null && val "toolchain" "declared in pom"
fi
if [ -n "$GRADLE" ]; then
  for pat in 'jvmToolchain(\([0-9]*\))' 'JavaLanguageVersion.of(\([0-9]*\))' 'sourceCompatibility *= *[^0-9]*\([0-9]*\)' 'targetCompatibility *= *[^0-9]*\([0-9]*\)'; do
    v=$(grep -oE "$pat" "$GRADLE" 2>/dev/null | head -1 | grep -oE '[0-9]+$')
    [ -n "$v" ] && { val "gradle toolchain" "$v"; [ -z "$TARGET" ] && TARGET="$v"; }
  done
fi
[ -z "$TARGET" ] && flag "no explicit Java target found — build inherits the runner's JDK (unreproducible)"

# --------------------------------------------------------------------------
sect "Framework & platform"
if [ -n "$POM" ]; then
  BOOT=$(grep -A2 'spring-boot-starter-parent' "$POM" 2>/dev/null | grep -oE '<version>[^<]+' | head -1 | tr -d '<version>')
  [ -z "$BOOT" ] && BOOT=$(grep -B1 -A3 'org.springframework.boot' "$POM" 2>/dev/null | grep -oE '<version>[^<]+' | head -1 | tr -d '<version>')
  [ -n "$BOOT" ] && val "spring-boot" "$BOOT"
  grep -q 'spring-boot-starter-web\b\|spring-boot-starter-webflux' "$POM" && val "web starter" "present"
  grep -q 'spring-boot-maven-plugin' "$POM" && val "boot plugin" "present (jar/war repackage)"
  grep -q 'jakarta.platform\|jakartaee-api' "$POM" && val "Jakarta EE" "declared"
  grep -q 'quarkus' "$POM" && val "Quarkus" "$(grep -m1 -A1 'quarkus.platform' "$POM" | grep -oE '[0-9]+\.[0-9.]+' | head -1)"
  grep -q 'micronaut' "$POM" && val "Micronaut" "declared"
fi
if [ -n "$GRADLE" ]; then
  B=$(grep -oE 'org.springframework.boot[^0-9]*[0-9]+\.[0-9]+\.[0-9]+' "$GRADLE" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  [ -n "$B" ] && val "spring-boot" "$B"
  grep -q 'spring-boot' "$GRADLE" && val "boot plugin" "present"
fi

# --------------------------------------------------------------------------
sect "Packaging & web layer"
PKG=""
if [ -n "$POM" ]; then
  PKG=$(grep -oE '<packaging>[^<]+' "$POM" | head -1 | sed 's/<packaging>//')
  grep -q 'spring-boot-maven-plugin' "$POM" && PKG="${PKG:-jar (boot)}"
fi
grep -q "war" "$GRADLE" 2>/dev/null && PKG="${PKG:-war (gradle)}"
[ -n "$PKG" ] && val "packaging" "$PKG"

[ -f src/main/webapp/WEB-INF/web.xml ] && {
  val "web.xml" "present"
  val "  version" "$(grep -oE 'web-app[^>]*version="[0-9.]+"' src/main/webapp/WEB-INF/web.xml | grep -oE '[0-9]+\.[0-9]+' | head -1)"
  grep -q 'metadata-complete="true"' src/main/webapp/WEB-INF/web.xml && flag "metadata-complete=true — annotations are IGNORED"
  grep -q 'xmlns.jcp.org/xml/ns/javaee' src/main/webapp/WEB-INF/web.xml && val "  namespace" "javax (Java EE) — needs Tomcat 9"
  grep -q 'jakarta.ee/xml/ns/jakartaee' src/main/webapp/WEB-INF/web.xml && val "  namespace" "jakarta (Jakarta EE) — needs Tomcat 10.1+"
}
[ -d src/main/webapp ] && [ ! -f src/main/webapp/WEB-INF/web.xml ] && val "webapp/" "present, no web.xml (annotations/servlet initializer)"

if [ -n "$POM" ]; then
  grep -q 'javax.servlet-api\|javax.servlet:jstl\|javax.servlet:servlet-api' "$POM" && val "servlet API" "javax  (Tomcat 9 line)"
  grep -q 'jakarta.servlet-api' "$POM" && val "servlet API" "jakarta (Tomcat 10.1/11)"
  if grep -q 'javax.servlet-api\|jakarta.servlet-api' "$POM" && ! grep -q -B2 -A2 'servlet-api' "$POM" | grep -q '<scope>provided'; then
    flag "servlet-api may not be 'provided' — never bundle it in a WAR"
  fi
  grep -q 'spring-boot-starter-undertow' "$POM" && flag "Undertow starter: removed in Spring Boot 4"
  grep -q 'spring-boot-starter-tomcat' "$POM" && grep -q '<scope>provided' "$POM" && val "tomcat starter" "provided (container deploy)"
fi

# javax usage in sources vs container expectation
if command -v grep >/dev/null 2>&1 && [ -d src ]; then
  JAVAX=$(grep -rl 'import javax\.servlet\|import javax\.persistence\|import javax\.validation' src/ 2>/dev/null | wc -l | tr -d ' ')
  JAKARTA=$(grep -rl 'import jakarta\.servlet\|import jakarta\.persistence\|import jakarta\.validation' src/ 2>/dev/null | wc -l | tr -d ' ')
  [ "$JAVAX" -gt 0 ] && [ "$JAKARTA" -gt 0 ] && bad "MIXED namespaces: $JAVAX javax file(s), $JAKARTA jakarta file(s) — deployment will fail"
  [ "$JAVAX" -gt 0 ] && [ "$JAKARTA" -eq 0 ] && val "namespaces" "$JAVAX file(s) on javax only"
  [ "$JAKARTA" -gt 0 ] && [ "$JAVAX" -eq 0 ] && val "namespaces" "$JAKARTA file(s) on jakarta only"
fi

# --------------------------------------------------------------------------
sect "Persistence & migrations"
if [ -n "$POM" ]; then
  grep -q 'spring-boot-starter-data-jpa\|hibernate-core' "$POM" && val "JPA/Hibernate" "present"
  grep -q 'flyway' "$POM" && val "Flyway" "present"
  grep -q 'liquibase' "$POM" && val "Liquibase" "present"
  grep -q 'jooq' "$POM" && val "jOOQ" "present"
fi
while IFS= read -r f; do
  [ -z "$f" ] && continue
  DA=$(grep -h 'ddl-auto' "$f" 2>/dev/null | sed 's/.*ddl-auto[=: ]*//')
  [ -n "$DA" ] && val "ddl-auto ($(basename "$f"))" "$DA"
done <<EOF
$(find . \( -name 'application*.yml' -o -name 'application*.yaml' -o -name 'application*.properties' \) -not -path '*/target/*' -not -path '*/build/*' 2>/dev/null | head -5)
EOF

# --------------------------------------------------------------------------
sect "Testing"
if [ -n "$POM" ]; then
  grep -q 'junit-jupiter\|junit' "$POM" && val "JUnit" "present"
  grep -q 'testcontainers' "$POM" && val "Testcontainers" "present"
  grep -q 'mockito' "$POM" && val "Mockito" "present"
  grep -q 'assertj' "$POM" && val "AssertJ" "present"
  grep -q 'jacoco' "$POM" && val "JaCoCo" "present"
  grep -q 'spotbugs\|pmd\|checkstyle\|errorprone\|error_prone' "$POM" && val "static analysis" "configured"
  grep -q 'owasp\|dependency-check' "$POM" && val "OWASP dep-check" "configured"
  if ! grep -q 'junit\|testcontainers\|mockito' "$POM" && grep -q 'spring-boot-starter-parent' "$POM"; then
    val "JUnit" "inherited from the Boot parent (BOM-managed)"
  fi
fi

# --------------------------------------------------------------------------
sect "Modules & deployables"
if [ -n "$POM" ]; then
  M=$(grep -c '<module>' "$POM" 2>/dev/null); M=${M:-0}
  [ "$M" -gt 0 ] && val "maven modules" "$M"
fi
if [ -f settings.gradle.kts ] || [ -f settings.gradle ]; then
  G=$(grep -h '^include' settings.gradle* 2>/dev/null | wc -l | tr -d ' ')
  [ "$G" -gt 0 ] && val "gradle subprojects" "$G"
fi
ART=$(find . -maxdepth 3 \( -name '*.war' -o -name '*.ear' \) -not -path './.git/*' 2>/dev/null | head -5)
if [ -n "$ART" ]; then printf '  %-22s\n' "existing artifacts"; echo "$ART" | sed 's/^/    /'; else val "existing artifacts" "none (build one before WAR debugging)"; fi

# --------------------------------------------------------------------------
sect "Suggested next steps"
N=1
next() { printf '  %d. %-20s %s\n' "$N" "$1" "$2"; N=$((N+1)); }
next "Build untouched:" "./mvnw -q -DskipTests package  (or ./gradlew build -x test)"
next "Smell scan:" "scripts/java-audit.sh ."
[ -n "$PKG" ] && next "Inspect artifact:" "scripts/war-inspect.sh target/*.war"
next "Record first:" "write the numbers above into plan.status.md"

printf '\n%sProbe complete.%s\n' "$BOLD" "$OFF"
