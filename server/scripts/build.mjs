/**
 * Dev-time build (target boxes never run npm):
 * 1. gateway/src → gateway/dist/server.mjs — single ESM file, ajv + shared
 *    assets bundled in, zero runtime dependencies (node:* builtins only).
 * 2. provision.sh + base64(server.mjs) → dist/provision-bundle.sh — the
 *    combined artifact the app streams over SSH (`ssh box 'sh -s' < bundle`).
 */
import { build } from "esbuild";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const serverOut = path.join(root, "gateway", "dist", "server.mjs");

await build({
  entryPoints: [path.join(root, "gateway", "src", "index.ts")],
  outfile: serverOut,
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node20",
  banner: {
    js: "// Prime Radiant gateway — built by server/scripts/build.mjs; do not edit.\nimport { createRequire } from 'node:module'; const require = createRequire(import.meta.url);",
  },
  external: ["node:sqlite"],
  minify: false,
  legalComments: "none",
});

const provision = readFileSync(path.join(root, "provision.sh"), "utf8");
const marker = "# @@GATEWAY_DIST_B64@@";
if (!provision.includes(marker)) {
  throw new Error("provision.sh is missing the payload marker");
}
const b64 = readFileSync(serverOut).toString("base64").replace(/(.{76})/g, "$1\n");
const bundle = provision.replace(marker, b64);
mkdirSync(path.join(root, "dist"), { recursive: true });
const bundlePath = path.join(root, "dist", "provision-bundle.sh");
writeFileSync(bundlePath, bundle, { mode: 0o755 });

const kb = (bytes) => `${(bytes / 1024).toFixed(0)} KB`;
console.log(`gateway/dist/server.mjs  ${kb(readFileSync(serverOut).length)}`);
console.log(`dist/provision-bundle.sh ${kb(bundle.length)}`);
