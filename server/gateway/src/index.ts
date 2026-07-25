/**
 * Gateway entrypoint. Normally installed by provision.sh as
 * ~/.prime-radiant/gateway/server.mjs and run by launchd
 * (com.primeradiant.gateway); hand-install is `node server.mjs`, which prints
 * a pairing code when no device token exists yet.
 */
import { execFile } from "node:child_process";
import { realpathSync } from "node:fs";
import http from "node:http";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { createGateway, VERSION } from "./app.ts";
import { ClaudeRunner } from "./claude.ts";
import { gatewayDir, loadConfig, saveConfig, type GatewayConfig } from "./config.ts";
import { logLine } from "./log.ts";
import { runMaintenance } from "./maintenance.ts";
import { createStore } from "./storage.ts";

const execFileP = promisify(execFile);
const MAINTENANCE_INTERVAL_MS = 60 * 60 * 1000;

/**
 * The env-var footgun (pivot §5.2): with ANTHROPIC_API_KEY present, the
 * claude CLI silently bills API credits instead of the subscription. Refuse
 * to run — both in our own env and in the login shell claude will inherit.
 */
export function refuseIfApiKeyPresent(env: NodeJS.ProcessEnv = process.env): void {
  if (env.ANTHROPIC_API_KEY !== undefined && env.ANTHROPIC_API_KEY !== "") {
    process.stderr.write(
      "FATAL: ANTHROPIC_API_KEY is set in the gateway environment. " +
        "The claude CLI would silently bill API credits instead of the owner's " +
        "subscription (pivot-claude-tailscale.md §5.2). Unset it and restart.\n",
    );
    process.exit(1);
  }
}

async function loginShellProbe(loginShell: string[], command: string): Promise<string | null> {
  const [shell, ...args] = loginShell;
  try {
    const { stdout } = await execFileP(shell as string, [...args, command]);
    return stdout.trim();
  } catch {
    return null;
  }
}

export async function main(): Promise<void> {
  refuseIfApiKeyPresent();

  const dir = gatewayDir();
  const config: GatewayConfig = loadConfig(dir);

  // The login shell is what claude actually runs under — check the footgun
  // there too (a key exported from ~/.zprofile would bypass the env check).
  const loginKey = await loginShellProbe(config.loginShell, "printenv ANTHROPIC_API_KEY");
  if (loginKey !== null && loginKey !== "") {
    process.stderr.write(
      "FATAL: ANTHROPIC_API_KEY is set in the box's login-shell environment. " +
        "Remove it from the shell profile and restart (pivot-claude-tailscale.md §5.2).\n",
    );
    process.exit(1);
  }
  const claudePath = await loginShellProbe(config.loginShell, "command -v claude");
  const agentReady = claudePath !== null && claudePath !== "";

  const store = await createStore(dir);
  const runner = new ClaudeRunner({
    loginShell: config.loginShell,
    turnTimeoutMs: config.turnTimeoutMs,
    onBudget: (state) => gateway.setBudget(state),
  });
  const gateway = createGateway({
    store,
    runner,
    config,
    agentReady: () => agentReady,
    onTokenMinted: (token) => saveConfig(dir, { ...config, deviceToken: token }),
  });

  if (config.deviceToken === undefined) {
    // Hand-installed and unpaired: print the one-time code (UX doc §1,
    // screen 1c — "code shown by your server").
    const code = gateway.enablePairing();
    process.stdout.write(`pairing code: ${code}\n`);
    logLine({ event: "pairing_code_active" });
  }

  const server = http.createServer(gateway.handler);
  server.listen(config.port, config.bind, () => {
    logLine({ event: "listening", version: VERSION, bind: config.bind, port: config.port, store: store.kind, agentReady });
  });
  // Always answer on loopback too (provision health checks, tailscale serve).
  let loopback: http.Server | null = null;
  if (config.bind !== "0.0.0.0" && config.bind !== "127.0.0.1" && config.bind !== "localhost") {
    loopback = http.createServer(gateway.handler);
    loopback.listen(config.port, "127.0.0.1");
  }

  const backupsDir = path.join(dir, "backups");
  const maintain = () => {
    try {
      const result = runMaintenance(store, backupsDir);
      if (result.backedUp || result.rotated > 0 || result.purged > 0) {
        logLine({ event: "maintenance", ...result });
      }
    } catch (err) {
      logLine({ event: "maintenance_failed", message: (err as Error).message });
    }
  };
  maintain();
  const timer = setInterval(maintain, MAINTENANCE_INTERVAL_MS);

  const shutdown = () => {
    clearInterval(timer);
    runner.dispose();
    server.close();
    loopback?.close();
    store.close();
    logLine({ event: "shutdown" });
    process.exit(0);
  };
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}

// Run when invoked directly (node server.mjs), not when imported by tests.
// realpath both sides: node realpaths the entry module (macOS /tmp is a
// symlink), argv[1] arrives as typed.
const invokedDirectly = (() => {
  if (process.argv[1] === undefined) return false;
  try {
    return import.meta.url === pathToFileURL(realpathSync(path.resolve(process.argv[1]))).href;
  } catch {
    return false;
  }
})();
if (invokedDirectly || process.env.RADIANT_FORCE_MAIN === "1") {
  void main();
}
