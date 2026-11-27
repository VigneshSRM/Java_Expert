#!/usr/bin/env bash
# war-inspect.sh — inspect a WAR/JAR/EAR for the defects that break deployments.
# Read-only. Requires python3 for the deep checks; falls back to `unzip -l`.
#
# Usage: scripts/war-inspect.sh path/to/app.war
#
# Looks for: bundled servlet API, javax/jakarta mixing, duplicate artifacts,
# bytecode level, duplicate SLF4J bindings, web.xml version/metadata-complete,
# Spring Boot WAR requirements, fat jars, JSP/JSTL state, ZIP integrity.

set -uo pipefail

ART="${1:-}"
BOLD=$'\033[1m'; DIM=$'\033[2m';RED=$'\033[31m'; YEL=$'\033[33m'; GRN=$'\033[32m'; CYA=$'\033[36m'; OFF=$'\033[0m'
if [ ! -t 1 ]; then BOLD=""; DIM=""; RED=""; YEL=""; GRN=""; CYA=""; OFF=""; fi

if [ -z "$ART" ]; then
  echo "usage: $0 <artifact.war|.jar|.ear>" >&2
  exit 2
fi
[ -f "$ART" ] || { echo "war-inspect: no such file: $ART" >&2; exit 2; }

printf '%sJava Expert — artifact inspection%s\n' "$BOLD" "$OFF"
printf '%s%s%s\n' "$DIM" "$ART" "$OFF"
printf '  %-16s %s\n' "size" "$(du -h "$ART" 2>/dev/null | cut -f1)"
printf '  %-16s %s\n' "sha256" "$(sha256sum "$ART" 2>/dev/null | cut -d' ' -f1)"

if ! command -v python3 >/dev/null 2>&1; then
  printf '\n%s!%s python3 not available — basic listing only.\n' "$YEL" "$OFF"
  echo "  Counts: $(unzip -l "$ART" 2>/dev/null | tail -1)"
  echo "  Servlet API present in archive:"
  unzip -l "$ART" 2>/dev/null | grep -iE 'servlet-api|jsp-api|jstl' | sed 's/^/    /' || echo "    none"
  echo "  Top-level entries:"
  unzip -l "$ART" 2>/dev/null | awk '{print $4}' | grep -E '^(WEB-INF|META-INF)/[^/]*/?$' | head -20 | sed 's/^/    /'
  echo
  echo "Install python3 for duplicate-jar, bytecode, and nested-jar analysis."
  exit 0
fi

python3 - "$ART" <<'PY'
import hashlib, io, os, re, sys, zipfile

path = sys.argv[1]
BDOFF = "\033[0m"; BOLD = "\033[1m"; RED = "\033[31m"; YEL = "\033[33m"; GRN = "\033[32m"; DIM = "\033[2m"
if not sys.stdout.isatty():
    BDOFF = BOLD = RED = YEL = GRN = DIM = ""

finding_p0 = []
finding_p1 = []
finding_p2 = []
notes = []

def say(kind, msg):
    if kind == "P0": print(f"{RED}[P0]{BDOFF} {msg}"); finding_p0.append(msg)
    elif kind == "P1": print(f"{RED}[P1]{BDOFF} {msg}"); finding_p1.append(msg)
    elif kind == "P2": print(f"{YEL}[P2]{BDOFF} {msg}"); finding_p2.append(msg)
    elif kind == "ok": print(f"{GRN} ok {BDOFF}{msg}")
    else: print(f"{DIM}    {msg}{BDOFF}")

def section(t):
    print(f"\n{BOLD}== {t} =={BDOFF}")

try:
    z = zipfile.ZipFile(path)
except Exception as e:
    print(f"{RED}[P0]{BDOFF} Not a readable ZIP archive: {e}")
    sys.exit(0)

names = z.namelist()
section("Archive")
print(f"    entries:        {len(names)}")
bad = z.testzip()
if bad:
    say("P0", f"Corrupt entry '{bad}' — the archive is damaged. Rebuild it; never patch a WAR in place.")
else:
    say("ok", "ZIP integrity OK")

manifest = ""
try:
    manifest = z.read("META-INF/MANIFEST.MF").decode("utf-8", "replace")
except KeyError:
    pass

webxml = None
for candidate in ("WEB-INF/web.xml",):
    if candidate in names:
        try:
            webxml = z.read(candidate).decode("utf-8", "replace")
        except Exception:
            webxml = ""
        break

if webxml is None:
    boot = any(n.startswith("WEB-INF/lib/spring-boot") or n.startswith("BOOT-INF/lib/spring-boot") for n in names)
    if boot:
        say("P2", "No WEB-INF/web.xml. Valid only if a SpringBootServletInitializer subclass exists; "
                   "a Boot WAR without it starts but serves nothing.")
    else:
        say("P2", "No WEB-INF/web.xml — annotations/SCI only. Verify the container scans the package.")

# --------------------------------------------------------------------------
section("Deployment descriptor")
if webxml is not None:
    m = re.search(r'<web-app[^>]*version="([0-9.]+)"', webxml)
    ver = m.group(1) if m else "?"
    servlet_map = {"4.0": "Tomcat 9 (javax)", "5.0": "Tomcat 10.0 (jakarta)",
                   "6.0": "Tomcat 10.1 (jakarta)", "6.1": "Tomcat 11 (jakarta)"}
    print(f"    web-app version: {ver}  -> {servlet_map.get(ver, 'unknown')}")
    if 'xmlns.jcp.org/xml/ns/javaee' in webxml:
        say("P2", "javax namespace declared — requires a Tomcat 9-class container.")
    if 'jakarta.ee/xml/ns/jakartaee' in webxml:
        print(f"{DIM}    namespace: jakarta (Tomcat 10.1+/EE 10+){BDOFF}")
    if 'metadata-complete="true"' in webxml:
        say("P1", 'metadata-complete="true" — @WebServlet/@WebFilter annotations are IGNORED. '
                  "Declare everything in XML or remove the attribute.")
    if ver in ("2.5", "3.0", "3.1"):
        say("P2", f"Old descriptor version {ver}; validate against the target container's XSD.")

# --------------------------------------------------------------------------
section("Servlet API & namespace")
all_entries = set(names)
libs = [n for n in names if re.match(r'^(WEB-INF|BOOT-INF|APP-INF)/lib/[^/]+\.jar$', n)]
print(f"    bundled jars:   {len(libs)}")

servlet_api_bundled = []
javax_jar_libs = []
jakarta_jar_libs = []
logging_providers = []
fat_jars = []
jstl = []
nested_fail = []

for lib in libs:
    base = os.path.basename(lib)
    low = base.lower()
    if re.search(r'(^|[-_.])(servlet|jsp|el|jstl)[-_.]?api', low) or low.startswith(("jakarta.servlet-api", "javax.servlet-api",
                                                                                     "jakarta.servlet.jsp-api", "jsp-api")):
        servlet_api_bundled.append(base)
    if "jstl" in low or base.startswith("jakarta.servlet.jsp.jstl"):
        jstl.append(base)
    try:
        data = z.read(lib)
        if len(data) > 400 * 1024 * 1024:
            continue
        nz = zipfile.ZipFile(io.BytesIO(data))
        inner = nz.namelist()
        inner_set = set(inner)
        if any(n.startswith("javax/servlet/") for n in inner):
            javax_jar_libs.append(base)
        if any(n.startswith("jakarta/servlet/") for n in inner):
            jakarta_jar_libs.append(base)
        if "META-INF/services/org.slf4j.spi.SLF4JServiceProvider" in inner_set or \
           "org/slf4j/impl/StaticLoggerBinder.class" in inner_set:
            logging_providers.append(base)
        if any(n.startswith("BOOT-INF/") or n.startswith("WEB-INF/classes/") for n in inner):
            fat_jars.append(base)
    except Exception:
        nested_fail.append(base)

if servlet_api_bundled:
    say("P0", "Servlet/JSP API bundled inside the WAR: " + ", ".join(sorted(set(servlet_api_bundled))) +
              " — must be <scope>provided</scope>. Two API copies cause ClassCastException.")
else:
    say("ok", "No servlet/jsp API jar bundled")

if javax_jar_libs and jakarta_jar_libs:
    say("P0", "MIXED namespaces in WEB-INF/lib — javax in [%s], jakarta in [%s]. "
              "This cannot deploy. Replace the javax jars." % (", ".join(javax_jar_libs[:4]), ", ".join(jakarta_jar_libs[:4])))
elif javax_jar_libs:
    say("P1", "javax-namespace jars present: " + ", ".join(javax_jar_libs[:6]) +
              " — fine on Tomcat 9, fatal on Tomcat 10.1/11.")
elif jakarta_jar_libs:
    print(f"{DIM}    jakarta-namespace jars: {len(jakarta_jar_libs)} (expected on EE 10+){BDOFF}")

if len(logging_providers) > 1:
    say("P1", f"{len(logging_providers)} SLF4J providers: " + ", ".join(sorted(logging_providers)) +
              " — keep exactly one binding.")
elif logging_providers:
    print(f"{DIM}    logging provider: {logging_providers[0]}{BDOFF}")

if fat_jars:
    say("P1", "Nested fat/shaded jars inside the WAR: " + ", ".join(fat_jars[:4]) +
              " — shaded classes duplicate WEB-INF/classes and break linkage.")

if nested_fail:
    say("P2", f"{len(nested_fail)} jar(s) could not be read as ZIP (corrupt or unusual): " + ", ".join(nested_fail[:4]))

# --------------------------------------------------------------------------
section("Duplicate artifacts")
art_re = re.compile(r'^(?P<name>.+?)-(?P<ver>\d[\w.\-]*?)\.jar$', re.I)
buckets = {}
for lib in libs:
    base = os.path.basename(lib)
    m = art_re.match(base)
    if m:
        buckets.setdefault(m.group("name").lower(), []).append(base)
dupes = {k: v for k, v in buckets.items() if len(v) > 1}
if dupes:
    for k, v in sorted(dupes.items())[:10]:
        say("P1", f"Two versions of '{k}' in WEB-INF/lib: " + ", ".join(sorted(v)) +
                  " — run dependency:tree -Dverbose and exclude the loser.")
else:
    say("ok", "No duplicate artifact names detected")

# --------------------------------------------------------------------------
section("Bytecode level")
majors = {}
for n in names:
    if n.startswith(("WEB-INF/classes/", "BOOT-INF/classes/")) and n.endswith(".class"):
        try:
            head = z.read(n)[:8]
            if head[:4] == b"\xca\xfe\xba\xbe" and len(head) >= 8:
                majors[int.from_bytes(head[6:8], "big")] = majors.get(int.from_bytes(head[6:8], "big"), 0) + 1
        except Exception:
            pass
java_of = {52: 8, 55: 11, 61: 17, 62: 18, 63: 19, 64: 20, 65: 21, 66: 22, 67: 23, 68: 24, 69: 25, 70: 26, 71: 27}
if majors:
    for mv, cnt in sorted(majors.items()):
        j = java_of.get(mv, "?")
        print(f"    major {mv} -> Java {j}   ({cnt} classes)")
    if len(majors) > 1:
        say("P1", "Multiple bytecode levels in ONE artifact — mixed compilation targets. "
                  "UnsupportedClassVersionError is coming.")
    top = max(majors)
    print(f"{DIM}    container JRE must be >= Java {java_of.get(top, '?')}{BDOFF}")
else:
    say("P2", "No application classes found under WEB-INF/classes — is this the right artifact?")

# --------------------------------------------------------------------------
section("Web assets")
classfiles = [n for n in names if n.startswith(("WEB-INF/classes/", "BOOT-INF/classes/")) and n.endswith(".class")]
jsp = [n for n in names if n.endswith((".jsp", ".jspx", ".jspf"))]
static = [n for n in names if re.match(r'^(static/|assets/|css/|js/|images/)', n)]
print(f"    classes:        {len(classfiles)}")
print(f"    JSP/JSPX:       {len(jsp)}")
print(f"    static assets:  {len(static)}")
if jsp:
    if not any("jasper" in os.path.basename(l).lower() for l in libs):
        say("P2", "JSPs present but no Jasper/JSP engine bundled — the container must supply it "
                  "(Tomcat does; a plain servlet-only runtime does not).")
    if any(n.startswith("WEB-INF/") and n.endswith(".jsp") for n in names):
        say("P2", "A JSP sits under WEB-INF (not directly reachable). Correct only if forwarded to.")

if "Start-Class" in manifest:
    m = re.search(r'Start-Class:\s*(\S+)', manifest)
    if m:
        print(f"    Start-Class:    {m.group(1)}")
        say("P2", "Executable-archive manifest in a container deployment — repackage is producing a "
                  "fat artifact. Disable repackage for WAR-to-container deploys.")

# --------------------------------------------------------------------------
print(f"\n{BOLD}== Verdict =={BDOFF}")
if finding_p0:
    print(f"{RED}{BOLD}  {len(finding_p0)} blocking issue(s).{BDOFF} Fix these before deploying.")
elif finding_p1:
    print(f"{YEL}{BOLD}  No blocking issue; {len(finding_p1)} high-risk item(s).{BDOFF}")
elif finding_p2:
    print(f"{YEL}  {len(finding_p2)} advisory item(s); artifact looks deployable.{BDOFF}")
else:
    print(f"{GRN}  No structural problems detected.{BDOFF}")

print(f"\n{DIM}Structural checks only. Runtime causes need the container log: look for the"
      f"\ndeepest 'Caused by:' and see references/war-troubleshooting.md.{BDOFF}")
PY

exit 0
