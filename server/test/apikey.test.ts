/**
 * The env-var footgun (pivot §5.2): the built dist must refuse to start when
 * ANTHROPIC_API_KEY is present. Runs the real gateway/dist/server.mjs.
 */
import { execFile } from "node:child_process";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";

const execFileP = promisify(execFile);
const dist = path.join(
  path.dirname(fileURLToPath(import.meta.url)),
  "..",
  "gateway",
  "dist",
  "server.mjs",
);

describe("ANTHROPIC_API_KEY refusal", () => {
  it("exits 1 with a loud message when the key is in the environment", async () => {
    const dir = mkdtempSync(path.join(tmpdir(), "radiant-apikey-"));
    let code = 0;
    let stderr = "";
    try {
      await execFileP(process.execPath, [dist], {
        env: {
          PATH: process.env.PATH,
          RADIANT_GATEWAY_DIR: dir,
          ANTHROPIC_API_KEY: "sk-ant-test-never-bill-this",
        },
        timeout: 10_000,
      });
    } catch (err) {
      code = (err as { code: number }).code;
      stderr = (err as { stderr: string }).stderr;
    }
    expect(code).toBe(1);
    expect(stderr).toContain("FATAL: ANTHROPIC_API_KEY");
    expect(stderr).toContain("subscription");
  });
});
