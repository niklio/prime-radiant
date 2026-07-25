#!/bin/sh
# Prime Radiant gateway provisioning — streamed by the app over SSH:
#
#   ssh box 'sh -s' < server/dist/provision-bundle.sh
#
# The bundle is this script with the gateway dist embedded as a base64 heredoc
# (built by `npm run build`; this checked-in copy carries only the marker and
# needs RADIANT_DIST_FILE=<path to server.mjs> for direct dev runs).
#
# Idempotent; re-running IS the upgrade mechanism: server.mjs is replaced,
# config/token/data are kept, the service is kickstarted.
#
# stdout is a machine contract, parsed by the app (UX doc §1, screen 1c2).
# Exact grammar, one marker per line, in order:
#   ##stage:reach                      stage begins: "reaching the box"
#   ##stage:plant                      stage begins: "planting the radiant"
#   ##stage:wake                       stage begins: "waking the engine"
#   ##token:<64-hex device token>      after wake completes
#   ##addr:<best address>              https://<magicdns> when tailscale serve
#                                      is configured, else http://<ip>:<port>
#   ##fail:<stage>:<one plain sentence>   halt; the sentence is shown verbatim
# Nothing else is written to stdout. The full log lands in
# $GATEWAY_DIR/provision.log on the box.
#
# Test/env overrides (documented for server/test/provision.test.ts):
#   RADIANT_GATEWAY_DIR  install dir      (default $HOME/.prime-radiant/gateway)
#   RADIANT_PORT         gateway port     (default 7717)
#   RADIANT_LOGIN_SH     login-shell cmd  (default zsh -lc; tests use "sh -c"
#                        so PATH stubs for claude/tailscale pass through)
#   RADIANT_DIST_FILE    server.mjs path when the payload heredoc is empty

set -u

GATEWAY_DIR="${RADIANT_GATEWAY_DIR:-$HOME/.prime-radiant/gateway}"
PORT="${RADIANT_PORT:-7717}"
LOGIN_SH="${RADIANT_LOGIN_SH:-}"
LABEL="com.primeradiant.gateway"

mkdir -p "$GATEWAY_DIR" 2>/dev/null || {
  printf '%s\n' "##fail:reach:could not create $GATEWAY_DIR on the box."
  exit 1
}
LOG="$GATEWAY_DIR/provision.log"
log() { printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >>"$LOG"; }
say() { printf '%s\n' "$1"; log "stdout: $1"; }
fail() {
  say "##fail:$1:$2"
  exit 1
}
log "---- provision run: dir=$GATEWAY_DIR port=$PORT ----"

# Run a command through the user's login shell (where PATH resolves node and
# claude — pivot v3). $LOGIN_SH intentionally word-splits ("sh -c" in tests).
login_sh() {
  if [ -n "$LOGIN_SH" ]; then $LOGIN_SH "$1" 2>>"$LOG"
  elif command -v zsh >/dev/null 2>&1; then zsh -lc "$1" 2>>"$LOG"
  else sh -lc "$1" 2>>"$LOG"
  fi
}

# ---- stage: reach — the box has everything the gateway needs ----------------

say "##stage:reach"

NODE_BIN=$(login_sh 'command -v node' | tail -1)
[ -n "$NODE_BIN" ] || fail reach "install node 20 or newer on the box, then retry."
NODE_MAJOR=$("$NODE_BIN" -p 'process.versions.node.split(".")[0]' 2>>"$LOG")
[ -n "$NODE_MAJOR" ] && [ "$NODE_MAJOR" -ge 20 ] 2>/dev/null ||
  fail reach "this box has node ${NODE_MAJOR:-unknown}; install node 20 or newer, then retry."
log "node: $NODE_BIN (major $NODE_MAJOR)"

# The env-var footgun (pivot §5.2): a key in the login environment would make
# claude silently bill API credits instead of the subscription.
LOGIN_KEY=$(login_sh 'printenv ANTHROPIC_API_KEY' || true)
[ -z "$LOGIN_KEY" ] ||
  fail reach "remove ANTHROPIC_API_KEY from the box's shell profile, then retry."

CLAUDE_BIN=$(login_sh 'command -v claude' | tail -1)
[ -n "$CLAUDE_BIN" ] ||
  fail reach "install the claude CLI on the box and run claude login, then retry."
AUTH_STATUS=$(login_sh 'claude auth status' || true)
log "claude auth status: $AUTH_STATUS"
printf '%s' "$AUTH_STATUS" | grep -q '"loggedIn"[[:space:]]*:[[:space:]]*true' ||
  fail reach "run claude login on the box, then retry."

# ---- stage: plant — files, token, LaunchAgent -------------------------------

say "##stage:plant"

PAYLOAD_TMP=$(mktemp) || fail plant "could not create a temporary file on the box."
cat >"$PAYLOAD_TMP" <<'__RADIANT_GATEWAY_B64__'
# @@GATEWAY_DIST_B64@@
__RADIANT_GATEWAY_B64__

SERVER_TMP="$GATEWAY_DIR/server.mjs.tmp"
DECODED=$("$NODE_BIN" -e '
  const fs = require("fs");
  const b64 = fs.readFileSync(process.argv[1], "utf8").replace(/^#.*$/gm, "");
  const buf = Buffer.from(b64.replace(/\s+/g, ""), "base64");
  fs.writeFileSync(process.argv[2], buf);
  console.log(buf.length);
' "$PAYLOAD_TMP" "$SERVER_TMP" 2>>"$LOG")
rm -f "$PAYLOAD_TMP"
if [ -z "$DECODED" ] || [ "$DECODED" -lt 10000 ] 2>/dev/null; then
  if [ -n "${RADIANT_DIST_FILE:-}" ] && [ -f "${RADIANT_DIST_FILE:-}" ]; then
    cp "$RADIANT_DIST_FILE" "$SERVER_TMP" || fail plant "could not copy the gateway payload."
    log "payload: dev copy from $RADIANT_DIST_FILE"
  else
    fail plant "this script has no gateway payload; build dist/provision-bundle.sh and retry."
  fi
else
  log "payload: decoded $DECODED bytes"
fi
mv "$SERVER_TMP" "$GATEWAY_DIR/server.mjs" || fail plant "could not install server.mjs."

# Config: created on first run (token minted here, returned in-band below);
# re-runs keep the existing token, models, and data untouched.
CONFIG="$GATEWAY_DIR/config.json"
TOKEN=$("$NODE_BIN" -e '
  const fs = require("fs");
  const crypto = require("crypto");
  const [file, port, loginSh] = process.argv.slice(1);
  let c = {};
  try { c = JSON.parse(fs.readFileSync(file, "utf8")); } catch {}
  if (!c.deviceToken) c.deviceToken = crypto.randomBytes(32).toString("hex");
  if (c.port === undefined) c.port = Number(port);
  if (c.bind === undefined) c.bind = "0.0.0.0";
  if (c.interactiveModel === undefined) c.interactiveModel = "sonnet";
  if (c.restructureModel === undefined) c.restructureModel = "opus";
  if (c.loginShell === undefined) c.loginShell = loginSh ? loginSh.split(" ") : ["zsh", "-lc"];
  if (c.turnTimeoutMs === undefined) c.turnTimeoutMs = 240000;
  fs.writeFileSync(file + ".tmp", JSON.stringify(c, null, 2) + "\n");
  fs.renameSync(file + ".tmp", file);
  console.log(c.deviceToken);
' "$CONFIG" "$PORT" "$LOGIN_SH" 2>>"$LOG")
[ -n "$TOKEN" ] || fail plant "could not write the gateway config."
PORT=$("$NODE_BIN" -p 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).port' "$CONFIG")
log "config ready (port $PORT)"

# LaunchAgent: minimal environment — deliberately NO inherited vars, so no
# ANTHROPIC_API_KEY can ever reach the service (pivot §5.2).
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST="$PLIST_DIR/$LABEL.plist"
mkdir -p "$PLIST_DIR" || fail plant "could not create $PLIST_DIR."
cat >"$PLIST" <<EOF || fail plant "could not write the LaunchAgent plist."
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$NODE_BIN</string>
    <string>$GATEWAY_DIR/server.mjs</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>RADIANT_GATEWAY_DIR</key><string>$GATEWAY_DIR</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$GATEWAY_DIR/gateway.log</string>
  <key>StandardErrorPath</key><string>$GATEWAY_DIR/gateway.log</string>
</dict>
</plist>
EOF
log "plist written: $PLIST"

# ---- stage: wake — bootstrap, kickstart, health -----------------------------

say "##stage:wake"

UID_N=$(id -u)
launchctl bootout "gui/$UID_N/$LABEL" >>"$LOG" 2>&1 || true
# bootout is asynchronous — bootstrapping the same label too soon fails with
# an I/O error. Wait for the old instance to disappear, then retry bootstrap.
k=0
while launchctl print "gui/$UID_N/$LABEL" >/dev/null 2>&1 && [ $k -lt 15 ]; do
  sleep 1
  k=$((k + 1))
done
k=0
while [ $k -lt 5 ]; do
  if launchctl bootstrap "gui/$UID_N" "$PLIST" >>"$LOG" 2>&1; then
    log "bootstrap ok (attempt $((k + 1)))"
    break
  fi
  sleep 2
  k=$((k + 1))
done
launchctl kickstart -k "gui/$UID_N/$LABEL" >>"$LOG" 2>&1 || true

HEALTH_OK=0
i=0
while [ $i -lt 30 ]; do
  if curl -s -m 2 "http://127.0.0.1:$PORT/v1/health" 2>>"$LOG" | grep -q '"ok":true'; then
    HEALTH_OK=1
    break
  fi
  sleep 1
  i=$((i + 1))
done
[ "$HEALTH_OK" -eq 1 ] ||
  fail wake "the gateway did not start; check ~/.prime-radiant/gateway/gateway.log on the box."
log "health ok after ${i}s"

# tailscale serve fronting (TLS + MagicDNS) — attempted, never fatal.
TS_BIN=""
for candidate in "$(command -v tailscale 2>/dev/null || true)" \
  "/Applications/Tailscale.app/Contents/MacOS/Tailscale"; do
  if [ -n "$candidate" ] && [ -x "$candidate" ]; then
    TS_BIN="$candidate"
    break
  fi
done
SERVE_OK=0
DNS_NAME=""
TS_IP=""
if [ -n "$TS_BIN" ]; then
  DNS_NAME=$("$TS_BIN" status --json 2>>"$LOG" |
    "$NODE_BIN" -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{console.log(JSON.parse(d).Self.DNSName.replace(/\.$/,""))}catch{console.log("")}})' 2>>"$LOG")
  TS_IP=$("$TS_BIN" ip -4 2>>"$LOG" | head -1)
  # --bg returns promptly on success; guard against privilege prompts hanging.
  "$TS_BIN" serve --bg --https=443 "http://127.0.0.1:$PORT" >>"$LOG" 2>&1 &
  SERVE_PID=$!
  j=0
  while kill -0 "$SERVE_PID" 2>/dev/null && [ $j -lt 10 ]; do
    sleep 1
    j=$((j + 1))
  done
  if kill -0 "$SERVE_PID" 2>/dev/null; then
    kill "$SERVE_PID" 2>/dev/null
    wait "$SERVE_PID" 2>/dev/null # reap quietly; no job-control notice
    log "tailscale serve: timed out (likely needs privileges); skipped"
  elif wait "$SERVE_PID"; then
    SERVE_OK=1
    log "tailscale serve: configured (https://$DNS_NAME)"
  else
    log "tailscale serve: refused; skipped"
  fi
else
  log "tailscale binary not found; serve skipped"
fi

# Record serve state so health/debugging can see what the app was given.
"$NODE_BIN" -e '
  const fs = require("fs");
  const [file, ok, dns] = process.argv.slice(1);
  const c = JSON.parse(fs.readFileSync(file, "utf8"));
  c.serve = { configured: ok === "1", ...(dns ? { dnsName: dns } : {}) };
  fs.writeFileSync(file + ".tmp", JSON.stringify(c, null, 2) + "\n");
  fs.renameSync(file + ".tmp", file);
' "$CONFIG" "$SERVE_OK" "$DNS_NAME" 2>>"$LOG" || true

if [ "$SERVE_OK" -eq 1 ] && [ -n "$DNS_NAME" ]; then
  ADDR="https://$DNS_NAME"
elif [ -n "$TS_IP" ]; then
  ADDR="http://$TS_IP:$PORT"
else
  FALLBACK_IP=$(ipconfig getifaddr en0 2>/dev/null || hostname)
  ADDR="http://$FALLBACK_IP:$PORT"
fi

say "##token:$TOKEN"
say "##addr:$ADDR"
log "---- provision complete ----"
exit 0
