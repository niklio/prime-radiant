/**
 * Gateway config: ~/.prime-radiant/gateway/config.json, written by
 * provision.sh (which mints the device token) and updated in place only when
 * a hand-installed server completes pairing. `RADIANT_GATEWAY_DIR` overrides
 * the directory (tests, sandboxed provisioning).
 */
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

export interface GatewayConfig {
  /** Absent on a hand-installed, not-yet-paired server (pairing-code path). */
  deviceToken?: string;
  port: number;
  /** Tailnet interface to bind (the gateway always also binds loopback). */
  bind: string;
  /** Model aliases per mode; the CLI resolves aliases on the box (BoxConfig). */
  interactiveModel: string;
  restructureModel: string;
  /** Login shell prefix for claude spawns; ["zsh","-lc"] on real boxes. */
  loginShell: string[];
  turnTimeoutMs: number;
  /** Recorded by provision.sh: whether `tailscale serve` fronting is active. */
  serve?: { configured: boolean; dnsName?: string };
}

export const DEFAULT_CONFIG: GatewayConfig = {
  port: 7717,
  bind: "0.0.0.0",
  interactiveModel: "sonnet",
  restructureModel: "opus",
  loginShell: ["zsh", "-lc"],
  turnTimeoutMs: 240_000,
};

export function gatewayDir(): string {
  return process.env.RADIANT_GATEWAY_DIR ?? path.join(homedir(), ".prime-radiant", "gateway");
}

export function loadConfig(dir: string): GatewayConfig {
  const file = path.join(dir, "config.json");
  if (!existsSync(file)) return { ...DEFAULT_CONFIG };
  const parsed = JSON.parse(readFileSync(file, "utf8")) as Partial<GatewayConfig>;
  return { ...DEFAULT_CONFIG, ...parsed };
}

/** Atomic rewrite; used only to persist a token minted by /v1/pair. */
export function saveConfig(dir: string, config: GatewayConfig): void {
  mkdirSync(dir, { recursive: true });
  const file = path.join(dir, "config.json");
  const tmp = `${file}.tmp`;
  writeFileSync(tmp, `${JSON.stringify(config, null, 2)}\n`);
  renameSync(tmp, file);
}
