#!/usr/bin/env node
// Starts the proxy with a safe config:
// - loads .env (without overriding variables already exported)
// - strips ANTHROPIC_API_KEY (bill the subscription) unless ALLOW_API_KEY=1
// - finds the Claude Code binary bundled with the SDK (CLAUDE_CLI_PATH)
// - refuses to start without API_KEY; warns when not bound to localhost
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const envFile = join(root, ".env");
if (existsSync(envFile)) process.loadEnvFile(envFile);

const env = { ...process.env };
env.HOST ||= "127.0.0.1";
env.PORT ||= "8787";
if (!/^(1|true|yes)$/i.test(env.ALLOW_API_KEY ?? "")) delete env.ANTHROPIC_API_KEY;

const fail = (msg) => { console.error(`[start] ${msg}`); process.exit(1); };

if (!env.API_KEY) fail("API_KEY is missing: set it in .env (the key clients such as Strix send to the proxy).");
if (!["127.0.0.1", "localhost", "::1"].includes(env.HOST))
  console.warn(`[start] ⚠️  HOST=${env.HOST}: the proxy will be reachable from the network.`);

if (!env.CLAUDE_CLI_PATH) {
  const require = createRequire(join(root, "package.json"));
  const sdkDir = dirname(require.resolve("@anthropic-ai/claude-agent-sdk"));
  const sdkRequire = createRequire(join(sdkDir, "package.json"));
  const exe = process.platform === "win32" ? "claude.exe" : "claude";
  const candidates = [
    `@anthropic-ai/claude-agent-sdk-${process.platform}-${process.arch}`,
    `@anthropic-ai/claude-agent-sdk-${process.platform}-${process.arch}-musl`,
  ];
  for (const pkg of candidates) {
    try {
      const bin = join(dirname(sdkRequire.resolve(`${pkg}/package.json`)), exe);
      if (existsSync(bin)) { env.CLAUDE_CLI_PATH = bin; break; }
    } catch { /* package not installed for this platform */ }
  }
  if (!env.CLAUDE_CLI_PATH)
    fail("Claude Code binary not found: rerun `pnpm install` or set CLAUDE_CLI_PATH in .env.");
}

const server = join(root, ".output", "server", "index.mjs");
if (!existsSync(server)) fail("build not found: run `pnpm build` first.");

console.log(`[start] http://${env.HOST}:${env.PORT}  CLI=${env.CLAUDE_CLI_PATH}`);
const child = spawn(process.execPath, [server], { env, stdio: "inherit" });
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, () => child.kill(sig));
child.on("exit", (code, signal) => process.exit(signal ? 1 : (code ?? 0)));
