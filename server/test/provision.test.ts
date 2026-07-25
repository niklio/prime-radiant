/**
 * Local provision.sh run against a throwaway HOME sandbox, exercising the real
 * dist/provision-bundle.sh (payload included) end to end.
 *
 * Stubbed (documented per deliverable D):
 * - `claude`   — answers `auth status` with a loggedIn JSON (or false for the
 *                failure case); never spends anything.
 * - `tailscale`— `status --json` returns a fake MagicDNS self, `ip -4` a fake
 *                100.x, `serve` succeeds — so the ##addr grammar is testable.
 * - `launchctl`— `bootstrap` starts `node server.mjs` directly (launchd is not
 *                available to a test); `bootout` kills it; `kickstart` no-ops.
 * - login shell — RADIANT_LOGIN_SH="sh -c" so the stub PATH passes through
 *                (a real `zsh -lc` would rebuild PATH from the user profile).
 * Everything else — node, curl, the health loop, config/token minting, the
 * LaunchAgent plist, idempotent re-runs — is real.
 */
import { execFile } from "node:child_process";
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { afterAll, describe, expect, it } from "vitest";

const execFileP = promisify(execFile);
const serverRoot = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const bundle = path.join(serverRoot, "dist", "provision-bundle.sh");
const PORT = "7917";

const home = mkdtempSync(path.join(tmpdir(), "radiant-provision-home-"));
const stubs = path.join(home, "stubs");
mkdirSync(stubs);

function stub(name: string, script: string): void {
  const file = path.join(stubs, name);
  writeFileSync(file, `#!/bin/sh\n${script}\n`);
  chmodSync(file, 0o755);
}

stub(
  "claude",
  `if [ "$1" = "auth" ] && [ "$2" = "status" ]; then
  cat "$HOME/claude-auth.json"
  exit 0
fi
exit 1`,
);
stub(
  "tailscale",
  `case "$1" in
  status) printf '%s' '{"Self":{"DNSName":"test-box.tailtest.ts.net.","TailscaleIPs":["100.99.0.1"]}}' ;;
  ip) echo 100.99.0.1 ;;
  serve) exit 0 ;;
esac
exit 0`,
);
stub(
  "launchctl",
  `case "$1" in
  bootstrap)
    nohup node "$HOME/.prime-radiant/gateway/server.mjs" >>"$HOME/launchd-stub.log" 2>&1 &
    echo $! >"$HOME/gateway.pid"
    ;;
  bootout)
    [ -f "$HOME/gateway.pid" ] && kill "$(cat "$HOME/gateway.pid")" 2>/dev/null
    rm -f "$HOME/gateway.pid"
    sleep 1
    ;;
  print)
    [ -f "$HOME/gateway.pid" ] && kill -0 "$(cat "$HOME/gateway.pid")" 2>/dev/null && exit 0
    exit 1
    ;;
esac
exit 0`,
);

const env = {
  HOME: home,
  PATH: `${stubs}:${path.dirname(process.execPath)}:/usr/bin:/bin:/usr/sbin:/sbin`,
  RADIANT_PORT: PORT,
  RADIANT_LOGIN_SH: "sh -c",
};

async function provision(): Promise<{ code: number; stdout: string }> {
  try {
    const { stdout } = await execFileP("sh", [bundle], { env, timeout: 60_000 });
    return { code: 0, stdout };
  } catch (err) {
    const e = err as { code?: number; stdout?: string };
    return { code: e.code ?? -1, stdout: e.stdout ?? "" };
  }
}

function markers(stdout: string): string[] {
  return stdout.split("\n").filter((line) => line.startsWith("##"));
}

afterAll(async () => {
  await execFileP(path.join(stubs, "launchctl"), ["bootout"], { env }).catch(() => {});
});

describe("provision.sh (sandboxed HOME)", () => {
  it("halts on the reach line with one plain sentence when claude is not logged in", async () => {
    writeFileSync(path.join(home, "claude-auth.json"), '{"loggedIn": false}');
    const { code, stdout } = await provision();
    expect(code).toBe(1);
    expect(markers(stdout)).toEqual([
      "##stage:reach",
      "##fail:reach:run claude login on the box, then retry.",
    ]);
  });

  it("provisions: exact stage grammar, in-band token, healthy gateway", async () => {
    writeFileSync(path.join(home, "claude-auth.json"), '{"loggedIn": true, "authMethod": "claude.ai"}');
    const { code, stdout } = await provision();
    expect(code).toBe(0);

    const lines = markers(stdout);
    expect(lines[0]).toBe("##stage:reach");
    expect(lines[1]).toBe("##stage:plant");
    expect(lines[2]).toBe("##stage:wake");
    expect(lines[3]).toMatch(/^##token:[0-9a-f]{64}$/);
    expect(lines[4]).toBe("##addr:https://test-box.tailtest.ts.net");
    expect(lines).toHaveLength(5);

    const gatewayDir = path.join(home, ".prime-radiant", "gateway");
    const config = JSON.parse(readFileSync(path.join(gatewayDir, "config.json"), "utf8")) as {
      deviceToken: string;
      port: number;
      serve: { configured: boolean; dnsName: string };
    };
    expect(`##token:${config.deviceToken}`).toBe(lines[3]);
    expect(config.port).toBe(Number(PORT));
    expect(config.serve).toEqual({ configured: true, dnsName: "test-box.tailtest.ts.net" });
    expect(existsSync(path.join(gatewayDir, "server.mjs"))).toBe(true);
    expect(existsSync(path.join(home, "Library", "LaunchAgents", "com.primeradiant.gateway.plist"))).toBe(true);

    // The gateway the script started answers with the provisioned pairing.
    const health = (await (await fetch(`http://127.0.0.1:${PORT}/v1/health`)).json()) as {
      ok: boolean;
      paired: boolean;
    };
    expect(health.ok).toBe(true);
    expect(health.paired).toBe(true);

    // Scenarios round-trip with the in-band token.
    const put = await fetch(`http://127.0.0.1:${PORT}/v1/scenarios/01ARZ3NDEKTSV4RRFFQ69G5FAV`, {
      method: "PUT",
      headers: { Authorization: `Bearer ${config.deviceToken}` },
      body: JSON.stringify({
        id: "01ARZ3NDEKTSV4RRFFQ69G5FAV",
        title: "sandbox check",
        status: "modeling",
        createdAt: "2026-07-24T00:00:00.000Z",
        updatedAt: "2026-07-24T00:00:00.000Z",
        tree: { id: "01ARZ3NDEKTSV4RRFFQ69G5FA0", label: "root", p: 1, actor: "user" },
        realizedPath: [],
        transcript: [],
      }),
    });
    expect(put.status).toBe(200);
  });

  it("re-run is the upgrade path: same token, config kept, still healthy", async () => {
    const configPath = path.join(home, ".prime-radiant", "gateway", "config.json");
    const before = JSON.parse(readFileSync(configPath, "utf8")) as { deviceToken: string };

    const { code, stdout } = await provision();
    expect(code).toBe(0);
    const lines = markers(stdout);
    expect(lines[3]).toBe(`##token:${before.deviceToken}`);

    const after = JSON.parse(readFileSync(configPath, "utf8")) as { deviceToken: string };
    expect(after.deviceToken).toBe(before.deviceToken);
    const health = (await (await fetch(`http://127.0.0.1:${PORT}/v1/health`)).json()) as {
      ok: boolean;
    };
    expect(health.ok).toBe(true);
  });
});
