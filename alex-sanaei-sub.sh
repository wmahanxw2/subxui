#!/usr/bin/env bash
# ALEX tunnel sub page -> Sanaei 3x-ui v3 (custom sub theme, no rebuild)
#   bash alex-sanaei-sub.sh                  install (downloads sub.html from GitHub)
#   bash alex-sanaei-sub.sh /path/sub.html   install from a local file
#   bash alex-sanaei-sub.sh --remove         go back to the default sub page
set -Eeuo pipefail

SUB_SRC_URL="${SUB_SRC_URL:-https://raw.githubusercontent.com/wmahanxw2/ALEX/main/sub.html}"
ARG="${1:-}"
XUI_DIR="${XUI_DIR:-/usr/local/x-ui}"
XUI_BIN="$XUI_DIR/x-ui"
DB="${XUI_DB:-/etc/x-ui/x-ui.db}"
THEME_DIR="${THEME_DIR:-$XUI_DIR/alex-sub-theme}"
STAMP="$(date +%Y%m%d-%H%M%S)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -x "$XUI_BIN" ] || die "x-ui not found at $XUI_BIN"
[ -f "$DB" ] || die "database not found at $DB (set XUI_DB=/path/x-ui.db)"

# ---------- tools ----------
need=()
for c in curl python3 sqlite3; do command -v "$c" >/dev/null 2>&1 || need+=("$c"); done
if [ "${#need[@]}" -gt 0 ]; then
  say "installing: ${need[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null && apt-get install -y curl python3 sqlite3 >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl python3 sqlite >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl python3 sqlite >/dev/null
  else
    die "install these manually: ${need[*]}"
  fi
fi

# ---------- confirm this x-ui has the custom sub theme setting ----------
KEY="subThemeDir"
grep -aq "$KEY" "$XUI_BIN" || die "this x-ui build has no '$KEY' setting (needs 3.x). Version: $("$XUI_BIN" -v 2>/dev/null || echo ?)"

set_setting() {  # $1 = value ; empty value removes the row
  sqlite3 "$DB" "DELETE FROM settings WHERE \"key\"='$KEY';"
  if [ -n "$1" ]; then
    sqlite3 "$DB" "INSERT INTO settings(\"key\",\"value\") VALUES('$KEY','$1');"
  fi
}

# ---------- remove mode ----------
if [ "$ARG" = "--remove" ]; then
  cp -a "$DB" "$DB.bak-$STAMP"
  set_setting ""
  systemctl restart x-ui
  say "removed. The default sub page is back (DB backup: $DB.bak-$STAMP)"
  exit 0
fi

# ---------- get ALEX sub.html ----------
if [ -n "$ARG" ]; then
  cp "$ARG" "$TMP/sub.html"
else
  curl -fsSL "$SUB_SRC_URL" -o "$TMP/sub.html" \
    || die "download failed. Put sub.html on the server and run: bash $0 /path/to/sub.html"
fi

# ---------- convert Jinja (PasarGuard) -> Go template (3x-ui) ----------
say "converting page"
python3 - "$TMP/sub.html" "$TMP/out.html" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
h = open(src, encoding="utf-8").read()

m = re.search(r'<script id="jx-data".*?</script>', h, re.S)
if not m:
    sys.exit("jx-data block not found in sub.html")
head, tail = h[:m.start()], h[m.end():]

raw_tag = re.compile(r'\{%-?\s*(?:end)?raw\s*-?%\}')
def clean(s):
    s = raw_tag.sub('', s)
    n = s.count('{{')
    if n:
        print("WARN: %d literal '{{' in the page changed to '{ {'" % n)
    return s.replace('{{', '{ {')
head, tail = clean(head), clean(tail)

block = r'''<script id="jx-data" type="application/json">{"username":{{ .sId }},"emails":{{ .emails }},"up":{{ .uploadByte }},"down":{{ .downloadByte }},"limit":{{ .totalByte }},"expire":{{ .expire }},"enabled":{{ .enabled }},"announce":{{ .announce }},"links":{{ .links }} }</script>
<script>(function(){var e=document.getElementById("jx-data"),d={};
try{d=JSON.parse(e.textContent)||{}}catch(x){}
d.used=(+d.up||0)+(+d.down||0);
d.status=d.enabled===false?"disabled":"active";
if(+d.expire<0){d.status="on_hold";d.expire=0}
if(Array.isArray(d.emails)&&d.emails[0])d.username=String(d.emails[0]);
d.announce=d.announce||"";
if(typeof d.links==="string")d.links=d.links.split(/\r?\n/);
if(!Array.isArray(d.links))d.links=[];
try{e.textContent=JSON.stringify(d)}catch(x){}})();</script>
'''

old = 'location.origin+"/healthz?t="'
new = 'location.href.split("#")[0].split("?")[0]+"?format=info&t="'
if old in tail:
    tail = tail.replace(old, new)
    print("ping url patched")
else:
    print("WARN: ping url pattern not found (ping may show 'no response')")

out = head + block + tail

# safety: only our own template actions may exist in the final file
allowed = {'{{ .%s }}' % k for k in
           ('sId','emails','uploadByte','downloadByte','totalByte','expire','enabled','announce','links')}
bad = [a for a in re.findall(r'\{\{.*?\}\}', out, re.S) if a not in allowed]
if bad:
    sys.exit("unexpected template actions in output: %r" % bad[:3])

open(dst, "w", encoding="utf-8").write(out)
print("template written")
PY

# ---------- install theme ----------
mkdir -p "$THEME_DIR"
if [ -f "$THEME_DIR/sub.html" ]; then cp -a "$THEME_DIR/sub.html" "$THEME_DIR/sub.html.bak-$STAMP"; fi
install -m 644 "$TMP/out.html" "$THEME_DIR/sub.html"

cp -a "$DB" "$DB.bak-$STAMP"
set_setting "$THEME_DIR"
say "restarting x-ui"
systemctl restart x-ui
sleep 3
systemctl is-active --quiet x-ui || die "x-ui did not start. Roll back: bash $0 --remove"

say "done. Open a user's sub link in a browser (use a private tab)."
echo "If you still see the old page:  journalctl -u x-ui -n 40 | grep 'sub:'"
echo "Back to default page:           bash $0 --remove"
