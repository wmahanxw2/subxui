#!/usr/bin/env bash
# ALEX tunnel sub page -> Sanaei (3x-ui)
# usage:  bash alex-sanaei-sub.sh            (downloads sub.html from GitHub)
#         bash alex-sanaei-sub.sh /path/sub.html   (use a local copy)
set -Eeuo pipefail

SUB_SRC_URL="${SUB_SRC_URL:-https://raw.githubusercontent.com/wmahanxw2/ALEX/main/sub.html}"
LOCAL_SUB="${1:-}"
XUI_DIR="${XUI_DIR:-/usr/local/x-ui}"
XUI_BIN="$XUI_DIR/x-ui"
WORK="/opt/alex-sub-build"
STAMP="$(date +%Y%m%d-%H%M%S)"

say() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }
die() { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -x "$XUI_BIN" ] || die "x-ui not found at $XUI_BIN"

# ---------- 1) tools ----------
need=()
for c in git curl gcc python3 tar; do command -v "$c" >/dev/null 2>&1 || need+=("$c"); done
if [ "${#need[@]}" -gt 0 ]; then
  say "installing: ${need[*]}"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y >/dev/null && apt-get install -y git curl gcc python3 tar >/dev/null
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y git curl gcc python3 tar >/dev/null
  elif command -v yum >/dev/null 2>&1; then
    yum install -y git curl gcc python3 tar >/dev/null
  else
    die "install these manually: ${need[*]}"
  fi
fi

# ---------- 2) detect installed version, fetch matching source ----------
VER="$("$XUI_BIN" -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n1 || true)"
[ -n "$VER" ] || die "could not detect the x-ui version"
say "installed 3x-ui version: $VER"

rm -rf "$WORK"; mkdir -p "$WORK"
git clone --depth 1 --branch "v$VER" https://github.com/MHSanaei/3x-ui.git "$WORK/src" \
  || die "could not fetch source for tag v$VER"

TPL="$(find "$WORK/src" -type f \( -name subpage.html -o -name subscription.html \) \
        -not -path '*/node_modules/*' | head -n1 || true)"
[ -n "$TPL" ] || die "no Go-template sub page in v$VER (it probably uses the new SPA page). Send me this version number."
say "template to replace: ${TPL#$WORK/src/}"

for k in sId result expire totalByte uploadByte downloadByte; do
  grep -rq "\"$k\"" "$WORK/src/sub" 2>/dev/null \
    || die "this version does not pass the '$k' field to the sub page; script needs an update (version v$VER)"
done

# ---------- 3) get ALEX sub.html and convert Jinja -> Go template ----------
if [ -n "$LOCAL_SUB" ]; then
  cp "$LOCAL_SUB" "$WORK/sub.html"
else
  curl -fsSL "$SUB_SRC_URL" -o "$WORK/sub.html" \
    || die "download failed. Put sub.html on the server and run: bash $0 /path/to/sub.html"
fi

say "converting page"
python3 - "$WORK/sub.html" "$TPL" <<'PY'
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
    return s.replace('{{', '{{"{{"}}')   # keep any literal {{ from breaking Go templates
head, tail = clean(head), clean(tail)

block = r'''<script id="jx-data" type="application/json">{"username":{{ .sId }},"up":{{ .uploadByte }},"down":{{ .downloadByte }},"limit":{{ .totalByte }},"expire":{{ .expire }},"links":{{ .result }} }</script>
<script>(function(){var e=document.getElementById("jx-data"),d={};
try{d=JSON.parse(e.textContent)||{}}catch(x){}
d.used=(+d.up||0)+(+d.down||0);d.status="active";d.announce="";
if(+d.expire<0){d.status="on_hold";d.expire=0}
if(typeof d.links==="string")d.links=d.links.split(/\r?\n/);
if(!Array.isArray(d.links))d.links=[];
try{e.textContent=JSON.stringify(d)}catch(x){}})();</script>
'''

old = 'location.origin+"/healthz?t="'
new = 'location.href.split("#")[0].split("?")[0]+"?t="'
if old in tail:
    tail = tail.replace(old, new)
    print("ping url patched")
else:
    print("WARN: ping url pattern not found (ping may show 'no response')")

open(dst, "w", encoding="utf-8").write(head + block + tail)
print("template written")
PY

# ---------- 4) Go toolchain ----------
case "$(uname -m)" in
  x86_64) GA=amd64 ;;
  aarch64|arm64) GA=arm64 ;;
  *) die "unsupported CPU: $(uname -m)" ;;
esac
export GOPATH="$WORK/gopath" GOCACHE="$WORK/gocache"
say "installing Go toolchain"
GOV="$(curl -fsSL 'https://go.dev/VERSION?m=text' | head -n1 || true)"
if [ -n "$GOV" ] && curl -fsSL "https://go.dev/dl/${GOV}.linux-${GA}.tar.gz" -o "$WORK/go.tgz"; then
  tar -C "$WORK" -xzf "$WORK/go.tgz"
  export PATH="$WORK/go/bin:$PATH"
elif ! command -v go >/dev/null 2>&1; then
  die "could not download Go and no local Go found"
fi
go version

# ---------- 5) check that the new template parses and renders ----------
say "checking template"
mkdir -p "$WORK/chk"
cat > "$WORK/chk/main.go" <<'GO'
package main

import (
	"bytes"
	"fmt"
	"html/template"
	"os"
	"strings"
)

func main() {
	t, err := template.ParseFiles(os.Args[1])
	if err != nil {
		fmt.Println("PARSE ERROR:", err)
		os.Exit(1)
	}
	var b bytes.Buffer
	data := map[string]any{
		"sId": "testuser", "uploadByte": int64(1), "downloadByte": int64(2),
		"totalByte": int64(0), "expire": int64(-5),
		"result": []string{"vless://a@b:443?type=ws#name"},
	}
	if err := t.Execute(&b, data); err != nil {
		fmt.Println("EXEC ERROR:", err)
		os.Exit(1)
	}
	out := b.String()
	if !strings.Contains(out, `"username":"testuser"`) || strings.Contains(out, "<no value>") {
		fmt.Println("OUTPUT CHECK FAILED")
		os.Exit(1)
	}
	fmt.Println("template OK")
}
GO
( cd "$WORK/chk" && go run main.go "$TPL" ) || die "converted template is not valid, nothing was installed"

# ---------- 6) build ----------
say "building x-ui (a few minutes, needs ~1GB RAM)"
( cd "$WORK/src" && CGO_ENABLED=1 go build -ldflags "-w -s" -o "$WORK/x-ui.new" . ) \
  || die "build failed (low RAM? add swap and run again). Nothing was changed."

# ---------- 7) install with backup + rollback ----------
BAK="$XUI_BIN.bak-$STAMP"
cp -a "$XUI_BIN" "$BAK"
say "installing (backup: $BAK)"
systemctl stop x-ui
install -m 755 "$WORK/x-ui.new" "$XUI_BIN"
systemctl start x-ui
sleep 4
if systemctl is-active --quiet x-ui; then
  rm -rf "$WORK"
  say "done. Open a user's sub link in a browser to see the ALEX tunnel page."
  echo "Note: 'x-ui update' replaces the binary, so run this script again after updating."
else
  say "x-ui failed to start, rolling back"
  systemctl stop x-ui || true
  install -m 755 "$BAK" "$XUI_BIN"
  systemctl start x-ui
  die "rolled back to the old binary. Check: journalctl -u x-ui -n 50"
fi
