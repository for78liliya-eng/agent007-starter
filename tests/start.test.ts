// start.sh checks and environment, with a stub `claude` instead of the real one.
import { beforeEach, expect, test } from "bun:test";
import { chmodSync, cpSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const REPO = join(import.meta.dir, "..");
let dir: string;
let agent: string;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "start-"));
  agent = join(dir, "agent");
  mkdirSync(join(agent, "secrets"), { recursive: true });
  cpSync(join(REPO, "start.sh"), join(agent, "start.sh"));
  // Pretend plugin deps are installed so start.sh skips `bun install`.
  mkdirSync(join(agent, "dashi-plugin-claude-code/plugin/node_modules"), { recursive: true });
  mkdirSync(join(dir, "bin"));
  const stub = join(dir, "bin/claude");
  writeFileSync(stub, '#!/usr/bin/env bash\necho "ARGS=$*"\necho "CWD=$(pwd)"\necho "WS=$TELEGRAM_WORKSPACE_ROOT"\necho "STATE=$TELEGRAM_STATE_DIR"\necho "MEM=$TELEGRAM_MEMORY_WORKSPACE"\n');
  chmodSync(stub, 0o755);
});

function run(extraEnv: Record<string, string> = {}) {
  const bunDir = join(process.execPath, "..");
  const p = Bun.spawnSync(["bash", "start.sh"], {
    cwd: agent,
    env: { HOME: dir, PATH: `${join(dir, "bin")}:${bunDir}:/usr/bin:/bin`, ...extraEnv },
  });
  return { code: p.exitCode, out: p.stdout.toString() + p.stderr.toString() };
}

test("fails with a hint when channel.env is missing", () => {
  const r = run();
  expect(r.code).toBe(1);
  expect(r.out).toContain("нет файла secrets/channel.env");
});

test("fails when the owner ID is empty", () => {
  writeFileSync(join(agent, "secrets/channel.env"), "TELEGRAM_BOT_TOKEN=1:x\nTELEGRAM_ALLOWED_USER_IDS=\n");
  const r = run();
  expect(r.code).toBe(1);
  expect(r.out).toContain("TELEGRAM_ALLOWED_USER_IDS");
});

test("starts claude from the agent root with per-agent paths", () => {
  writeFileSync(join(agent, "secrets/channel.env"), "TELEGRAM_BOT_TOKEN=1:x\nTELEGRAM_ALLOWED_USER_IDS=42\nTELEGRAM_MEMORY_ENABLED=true\n");
  const r = run();
  expect(r.code).toBe(0);
  expect(r.out).toContain("ARGS=--dangerously-load-development-channels server:dashi-channel");
  expect(r.out).toContain(`CWD=${agent}`);
  expect(r.out).toContain(`WS=${agent}`);
  expect(r.out).toContain(`STATE=${agent}/.state`);
  expect(r.out).toContain(`MEM=${agent}/core/memory`);
});

test("ignores paths inherited from a parent agent's shell", () => {
  writeFileSync(join(agent, "secrets/channel.env"), "TELEGRAM_BOT_TOKEN=1:x\nTELEGRAM_ALLOWED_USER_IDS=42\n");
  const r = run({ TELEGRAM_WORKSPACE_ROOT: "/other", TELEGRAM_STATE_DIR: "/other/state" });
  expect(r.code).toBe(0);
  expect(r.out).toContain(`WS=${agent}`);
  expect(r.out).toContain(`STATE=${agent}/.state`);
});
