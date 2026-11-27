#!/usr/bin/env bash
# java-audit.sh — fast, read-only smell scan for a Java repository.
# Not a compiler and not a replacement for SpotBugs/Sonar: it finds the
# high-signal patterns that precede real incidents, with file:line evidence.
#
# Usage: scripts/java-audit.sh [repo-path] [--all]
#   --all   show every match instead of the first 5 per rule
#
# Exit code: 0 always (this is a report, not a gate).

set -uo pipefail

ROOT="."
SHOW_ALL=0
for a in "$@"; do
  case "$a" in
    --all) SHOW_ALL=1 ;;
    *) ROOT="$a" ;;
  esac
done
cd "$ROOT" 2>/dev/null || { echo "java-audit: cannot cd to '$ROOT'" >&2; exit 2; }

BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; YEL=$'\033[33m'; CYA=$'\033[36m'; OFF=$'\033[0m'
if [ ! -t 1 ]; then BOLD=""; DIM=""; RED=""; YEL=""; CYA=""; OFF=""; fi

P0=0; P1=0; P2=0; P3=0
SEV_COLOR_P0="$RED"; SEV_COLOR_P1="$RED"; SEV_COLOR_P2="$YEL"; SEV_COLOR_P3="$DIM"

EXCLUDES=(--exclude-dir=.git --exclude-dir=target --exclude-dir=build --exclude-dir=out
          --exclude-dir=node_modules --exclude-dir=.idea --exclude-dir=.gradle
          --exclude-dir=.mvn --exclude-dir=generated)

bump() { case "$1" in P0) P0=$((P0+1));; P1) P1=$((P1+1));; P2) P2=$((P2+1));; P3) P3=$((P3+1));; esac; }

# rule <severity> <title> <hint> <include-glob> <regex>
rule() {
  local sev="$1" title="$2" hint="$3" glob="$4" regex="$5"
  local out n limit
  out=$(grep -rnE "${EXCLUDES[@]}" --include="$glob" -- "$regex" . 2>/dev/null | grep -v '^\s*$')
  [ -z "$out" ] && return 0
  n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  bump "$sev"
  local color="$DIM"
  case "$sev" in P0) color="$RED";; P1) color="$RED";; P2) color="$YEL";; P3) color="$DIM";; esac
  printf '\n%s[%s]%s %s%s%s  %s(%s hit%s)%s\n' "$color" "$sev" "$OFF" "$BOLD" "$title" "$OFF" "$DIM" "$n" "$([ "$n" -eq 1 ] || echo s)" "$OFF"
  printf '      %s→ %s%s\n' "$DIM" "$hint" "$OFF"
  if [ "$SHOW_ALL" -eq 1 ]; then limit="$n"; else limit=5; fi
  printf '%s\n' "$out" | head -n "$limit" | sed 's/^/      /'
  [ "$n" -gt "$limit" ] && printf '      %s... %s more (use --all)%s\n' "$DIM" "$((n-limit))" "$OFF"
  return 0
}

printf '%sJava Expert — smell scan%s\n' "$BOLD" "$OFF"
printf '%s%s%s\n' "$DIM" "$(pwd)" "$OFF"
command -v grep >/dev/null 2>&1 || { echo "grep not found" >&2; exit 2; }

# ==========================================================================
# Namespace / deployment blockers
# ==========================================================================
JAVAX_N=$(grep -rlE "${EXCLUDES[@]}" --include='*.java' '^import javax\.(servlet|persistence|validation|annotation|ws\.rs|enterprise|faces|el|json|mail|websocket|transaction)\.' . 2>/dev/null | wc -l | tr -d ' ')
JAKARTA_N=$(grep -rlE "${EXCLUDES[@]}" --include='*.java' '^import jakarta\.(servlet|persistence|validation|annotation|ws\.rs|enterprise|faces|el|json|mail|websocket|transaction)\.' . 2>/dev/null | wc -l | tr -d ' ')
if [ "$JAVAX_N" -gt 0 ] && [ "$JAKARTA_N" -gt 0 ]; then
  P0=$((P0+1))
  printf '\n%s[P0]%s %sMixed namespaces — deployment will fail%s\n' "$RED" "$OFF" "$BOLD" "$OFF"
  printf '      %s%d file(s) on javax.*, %d on jakarta.*. Pick one; the container decides which.%s\n' "$DIM" "$JAVAX_N" "$JAKARTA_N" "$OFF"
  printf '      javax files:\n'
  grep -rlE "${EXCLUDES[@]}" --include='*.java' '^import javax\.(servlet|persistence|validation)\.' . 2>/dev/null | head -5 | sed 's/^/        /'
elif [ "$JAVAX_N" -gt 0 ]; then
  printf '\n%s[i]%s %d file(s) on javax.* — only valid for Tomcat 9 / EE 8 targets.\n' "$CYA" "$OFF" "$JAVAX_N"
fi

# ==========================================================================
# P0 — security incidents
# ==========================================================================
# Credentials: two precise scans (code literals + config values), not a keyword grep.
cred_check() {
  local title="$1" hint="$2" out="$3"
  [ -z "$out" ] && return 0
  local n; n=$(printf '%s\n' "$out" | wc -l | tr -d ' ')
  P0=$((P0+1))
  printf '\n%s[P0]%s %s%s%s  %s(%s hit%s)%s\n' "$RED" "$OFF" "$BOLD" "$title" "$OFF" "$DIM" "$n" "$([ "$n" -eq 1 ] || echo s)" "$OFF"
  printf '      %s→ %s%s\n' "$DIM" "$hint" "$OFF"
  printf '%s\n' "$out" | head -n 5 | sed 's/^/      /'
}

CRED_RE='([Pp]assword|[Pp]asswd|[Ss]ecret|[Aa]pi[_-]?[Kk]ey|[Aa]ccess[_-]?[Kk]ey|[Pp]rivate[_-]?[Kk]ey|[Tt]oken|PASSWORD|SECRET|TOKEN)'
cred_check "Hardcoded credential or key in code" \
  "Rotate the value first, then move it to env/vault." \
  "$(grep -rnE "${EXCLUDES[@]}" --include='*.java' \
      "${CRED_RE}[[:space:]]*=[[:space:]]*\"[^\"]{6,}\"" . 2>/dev/null)"

cred_check "Hardcoded credential in config" \
  "Rotate the value first, then reference an env var or vault placeholder." \
  "$(grep -rnE "${EXCLUDES[@]}" --include='*.properties' --include='*.yml' --include='*.yaml' \
      "^[[:space:]]*[A-Za-z0-9_.-]*([Pp]assword|[Pp]asswd|[Pp]wd|[Ss]ecret|[Aa]pi[_-]?[Kk]ey|[Aa]ccess[_-]?[Kk]ey|[Tt]oken)[A-Za-z0-9_.-]*[[:space:]]*[:=][[:space:]]*[^@\$[:space:]]{6,}" . 2>/dev/null)"

rule P0 "TLS verification disabled" \
  "Trust-all / no-hostname-verification defeats TLS. Use a real truststore." \
  '*.java' '(TrustAllStrategy|NoopHostnameVerifier|ALLOW_ALL_HOSTNAME_VERIFIER|checkServerTrusted[^)]*\)[[:space:]]*\{[[:space:]]*\}|setHostnameVerifier\()'

rule P0 "Java deserialization of untrusted data" \
  "ObjectInputStream on request data is an RCE primitive. Use a DTO/allowlist." \
  '*.java' 'new[[:space:]]+ObjectInputStream|enableDefaultTyping|activateDefaultTyping'

rule P0 "Command execution with interpolation" \
  "Runtime.exec / ProcessBuilder with concatenated input = RCE." \
  '*.java' '(Runtime\.getRuntime\(\)\.exec|new[[:space:]]+ProcessBuilder)[[:space:]]*\([^)]*\+'

# ==========================================================================
# P1 — correctness, security, reliability
# ==========================================================================
rule P1 "SQL/JPQL built by concatenation" \
  "Use bind parameters. Concatenation is both an injection path and a plan-cache killer." \
  '*.java' '"[[:space:]]*(select|SELECT|update|UPDATE|delete|DELETE|insert|INSERT)[^"]*"[[:space:]]*\+'

rule P1 "Empty catch block" \
  "Swallowed exception: the failure disappears from logs and metrics." \
  '*.java' 'catch[[:space:]]*\([^)]*\)[[:space:]]*\{[[:space:]]*\}'

rule P1 "printStackTrace / System.out / System.err" \
  "Bypasses the logging framework: no correlation id, no levels, no redaction." \
  '*.java' '(\.printStackTrace\(\)|System\.(out|err)\.print)'

rule P1 "CORS wildcard with credentials" \
  "allowedOrigins(\"*\") + allowCredentials(true) is rejected by browsers and unsafe anyway." \
  '*.java' 'allowedOrigins?\([[:space:]]*"\*"|addAllowedOrigin\([[:space:]]*"\*"|@CrossOrigin\([^)]*origins[[:space:]]*=[[:space:]]*"\*"'

rule P1 "Exception message returned to the client" \
  "Leaks internals. Return a correlation id; log the detail." \
  '*.java' '(ResponseEntity|ResponseEntity\.status|return)[^;]*e\.getMessage\(\)|getMessage\(\)[[:space:]]*\+[[:space:]]*"'

rule P1 "Weak or broken cryptography" \
  "MD5/SHA-1/DES/ECB are not acceptable for integrity, passwords, or transport." \
  '*.java' 'MessageDigest\.getInstance\([[:space:]]*"(MD5|SHA-?1)"|Cipher\.getInstance\([[:space:]]*"(DES|DESede|RC4|AES/ECB[^"]*)"'

rule P1 "Path traversal from request input" \
  "Normalize and verify the resolved path stays under the allowed root." \
  '*.java' 'new[[:space:]]+File\([^)]*\+[^)]*\)|Paths\.get\([^)]*\+[^)]*\)'

rule P1 "Unbounded executor" \
  "newCachedThreadPool has no ceiling; an outage becomes OOM under load." \
  '*.java' 'Executors\.newCachedThreadPool\('

rule P2 "Thread.sleep" \
  "Blocks a thread: in prod use scheduling, in tests use Awaitility. Never in a request path." \
  '*.java' 'Thread\.sleep\('

# ==========================================================================
# P2 — latent bugs and performance
# ==========================================================================
rule P2 "Mutable static collection" \
  "Shared mutable state across threads. Use immutable copies or a concurrent type." \
  '*.java' 'static[[:space:]]+(final[[:space:]]+)?(HashMap|ArrayList|HashSet|LinkedList|TreeMap)<'

rule P2 "double for money" \
  "Binary floating point cannot represent cents. Use BigDecimal or long minor units." \
  '*.java' '(private|protected|public)[[:space:]]+(final[[:space:]]+)?double[[:space:]]+[a-zA-Z_]*(amount|price|total|balance|cost|fee|tax)[a-zA-Z_]*'

rule P2 "Legacy date API" \
  "java.util.Date/Calendar/SimpleDateFormat are mutable and timezone-naive." \
  '*.java' '(new[[:space:]]+Date\(\)|new[[:space:]]+SimpleDateFormat|Calendar\.getInstance\(\))'

rule P2 "SimpleDateFormat as a field" \
  "Not thread-safe in a singleton. Use DateTimeFormatter." \
  '*.java' '(private|protected|public)[^(]*SimpleDateFormat[[:space:]]+[a-zA-Z_]'

rule P2 "\`.get()\` with no visible guard (heuristic)" \
  "Throws NoSuchElementException on the empty path. Use orElseThrow/map." \
  '*.java' '\.get\(\)[[:space:]]*;' 

rule P2 "synchronized block containing I/O" \
  "Holds a monitor across a network/disk call: throughput collapse and vthread pinning." \
  '*.java' 'synchronized[[:space:]]*\([^)]*\)[[:space:]]*\{'

rule P2 "Fetches all rows then filters in memory" \
  "findAll() over an unbounded table. Use a query with predicates and pagination." \
  '*.java' '\.findAll\(\)'

rule P2 "EAGER fetch on an association" \
  "Loads the graph on every query. Default to LAZY and fetch explicitly." \
  '*.java' 'FetchType\.EAGER'

rule P2 "ddl-auto=update outside tests" \
  "Schema drift in production. Use Flyway/Liquibase." \
  '*.{properties,yml,yaml}' 'ddl-auto[=:][[:space:]]*(update|create|create-drop)'

rule P2 "open-in-view left enabled" \
  "Holds a session for the whole request; masks N+1 and hides lazy loads." \
  '*.{properties,yml,yaml}' 'open-in-view[=:][[:space:]]*true'

rule P2 "Unchecked ThreadLocal" \
  "Must be removed in a finally, or the classloader leaks on redeploy." \
  '*.java' 'new[[:space:]]+ThreadLocal<'

rule P2 "No timeout on an HTTP client" \
  "Unbounded waits tie up request threads until the pool dies." \
  '*.java' '(HttpClient\.newBuilder\(\)|new[[:space:]]+RestTemplate\(\)|WebClient\.create\(\))'

rule P2 "Retry without a bound" \
  "Infinite retries amplify an outage. Add maxAttempts + backoff + jitter." \
  '*.java' '@Retryable[[:space:]]*(\([[:space:]]*\))?[[:space:]]*$'

# ==========================================================================
# P3 — build and hygiene
# ==========================================================================
if [ -f pom.xml ]; then
  SNAP=$(grep -c 'SNAPSHOT' pom.xml 2>/dev/null || echo 0)
  [ "$SNAP" -gt 0 ] && { P3=$((P3+1)); printf '\n%s[P3]%s Snapshot dependency in pom.xml (%s)\n      Cannot be reproduced by anyone else. Pin a release.\n' "$DIM" "$OFF" "$SNAP"; grep -n 'SNAPSHOT' pom.xml | head -5 | sed 's/^/      /'; }
  RANGE=$(grep -nE '<version>\[|LATEST|RELEASE</version>' pom.xml 2>/dev/null)
  [ -n "$RANGE" ] && { P1=$((P1+1)); printf '\n%s[P1]%s Version range / LATEST in pom.xml\n      Non-deterministic builds. Pin exact versions.\n' "$RED" "$OFF"; printf '%s\n' "$RANGE" | head -5 | sed 's/^/      /'; }
  if ! grep -q 'maven-enforcer-plugin' pom.xml 2>/dev/null; then
    P3=$((P3+1)); printf '\n%s[P3]%s No maven-enforcer-plugin\n      Add converge/requireJavaVersion/banDuplicateClasses rules.\n' "$DIM" "$OFF"
  fi
  if ! grep -qE 'maven.compiler.release|<release>|<maven.compiler.target>' pom.xml 2>/dev/null; then
    P2=$((P2+1)); printf '\n%s[P2]%s No explicit Java release in pom.xml\n      The build inherits the runner JDK and is not reproducible.\n' "$YEL" "$OFF"
  fi
  PROVIDED_ISSUE=$(grep -n -B3 -A3 'servlet-api' pom.xml 2>/dev/null | grep -c 'provided' || true)
  if grep -q 'servlet-api' pom.xml 2>/dev/null && [ "$PROVIDED_ISSUE" -eq 0 ]; then
    P1=$((P1+1)); printf '\n%s[P1]%s servlet-api without <scope>provided</scope>\n      Bundling the API in a WAR causes loader conflicts. Fix the scope.\n' "$RED" "$OFF"
  fi
fi

rule P3 "TODO / FIXME / XXX" \
  "Track these or delete them; they accumulate silently." \
  '*.java' '(TODO|FIXME|XXX):'

rule P3 "System.currentTimeMillis for elapsed time" \
  "Skewed by clock adjustments. Use System.nanoTime for durations, Instant for timestamps." \
  '*.java' 'currentTimeMillis\(\)[[:space:]]*-'

rule P3 "Wildcard import" \
  "Hides the dependency surface and invites collisions." \
  '*.java' '^import[[:space:]]+[a-zA-Z0-9_.]+\*;'

# ==========================================================================
# Summary
# ==========================================================================
printf '\n%s== Summary ==%s\n' "$BOLD" "$OFF"
print_count() { printf '  %s%-3s%s %s%d%s rule group(s) triggered\n' "$1" "$2" "$OFF" "$DIM" "$3" "$OFF"; }
print_count "$RED"  "P0" "$P0"
print_count "$RED"  "P1" "$P1"
print_count "$YEL"  "P2" "$P2"
print_count "$DIM"  "P3" "$P3"

printf '\n%sThis is a heuristic scan. Confirm each hit in context before changing code;%s\n' "$DIM" "$OFF"
printf '%sregex matches include strings and comments.%s\n' "$DIM" "$OFF"
printf 'Next: references/code-audit-playbook.md for mechanisms and fix patterns.\n'
printf 'Then: reproduce, fix P0/P1, verify, report P2/P3 without touching them.\n'

exit 0
