// install.sh functions with stub curl / claude / systemctl / tmux — no network, no root.
import { beforeEach, expect, test } from "bun:test";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = join(import.meta.dir, "..", "install.sh");
const TOKEN = "1234567890:AAHabcdefghijklmnopqrstuvwxyz0123456";
let dir: string, bin: string, agent: string;

function stub(name: string, body: string) {
  const p = join(bin, name);
  writeFileSync(p, `#!/usr/bin/env bash\n${body}\n`);
  chmodSync(p, 0o755);
}

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "install-"));
  bin = join(dir, "bin");
  agent = join(dir, "agent");
  mkdirSync(bin);
  mkdirSync(agent);
  // Fake Telegram: getMe ok, first getUpdates returns one message from the owner.
  stub("curl", `
    echo "$*" >> "${dir}/curl.log"
    case "$*" in
      *"/getMe"*) echo '{"ok":true,"result":{"id":1234567890,"is_bot":true,"username":"my_test_bot"}}' ;;
      *"/getUpdates"*"timeout=10"*) echo '{"ok":true,"result":[{"update_id":77,"message":{"message_id":1,"from":{"id":4242,"is_bot":false,"first_name":"Лилия"},"chat":{"id":4242,"type":"private"},"text":"привет"}}]}' ;;
      *) echo '{"ok":true,"result":[]}' ;;
    esac`);
  stub("systemctl", `echo "systemctl $*" >> "${dir}/sys.log"`);
});

function run(fn: string, input = "", env: Record<string, string> = {}) {
  const tty = join(dir, "tty");
  writeFileSync(tty, input);
  const bunDir = join(process.execPath, "..");
  const p = Bun.spawnSync(["bash", "-c", `. "${SCRIPT}"; AGENT_DIR="${agent}"; AGENT_NAME=agent; ENV_FILE="${agent}/secrets/channel.env"; exec 3<"${tty}"; ${fn}`], {
    env: { HOME: dir, PATH: `${bin}:${bunDir}:/usr/bin:/bin`, INSTALL_SH_SOURCE_ONLY: "1", INSTALL_TTY: tty, ...env },
  });
  return { code: p.exitCode, out: p.stdout.toString() + p.stderr.toString() };
}

test("telegram: bad token is rejected, good one is saved with the owner ID found by itself", () => {
  const r = run("setup_telegram", `not-a-token\n${TOKEN}\n`);
  expect(r.code).toBe(0);
  expect(r.out).toContain("Это не похоже на ключ бота");
  expect(r.out).toContain("бот @my_test_bot");
  expect(r.out).toContain("ваш номер в Telegram: 4242 (Лилия)");
  expect(r.out).not.toContain(TOKEN); // token never printed
  const envFile = join(agent, "secrets/channel.env");
  const env = readFileSync(envFile, "utf8");
  expect(env).toContain(`TELEGRAM_BOT_TOKEN=${TOKEN}`);
  expect(env).toContain("TELEGRAM_EXPECTED_BOT_ID=1234567890");
  expect(env).toContain("TELEGRAM_ALLOWED_USER_IDS=4242");
  expect(statSync(envFile).mode & 0o777).toBe(0o600);
  // the test word is acknowledged so the agent does not answer it later
  expect(readFileSync(join(dir, "curl.log"), "utf8")).toContain("offset=78");
});

test("telegram: already configured → skipped, nothing asked", () => {
  mkdirSync(join(agent, "secrets"));
  writeFileSync(join(agent, "secrets/channel.env"), `TELEGRAM_BOT_TOKEN=${TOKEN}\nTELEGRAM_ALLOWED_USER_IDS=4242\n`);
  const r = run("setup_telegram; echo OWNER=$OWNER_ID");
  expect(r.out).toContain("уже настроен");
  expect(r.out).toContain("OWNER=4242");
  expect(existsSync(join(dir, "curl.log"))).toBe(false);
});

test("telegram: no message from the owner → asks for the ID by hand", () => {
  stub("curl", `case "$*" in *"/getMe"*) echo '{"ok":true,"result":{"username":"b"}}';; *) echo '{"ok":true,"result":[]}';; esac`);
  stub("seq", `echo 1`); // one polling round instead of 18
  const r = run("setup_telegram", `${TOKEN}\n 98 76 \n`);
  expect(r.code).toBe(0);
  expect(r.out).toContain("@userinfobot");
  expect(readFileSync(join(agent, "secrets/channel.env"), "utf8")).toContain("TELEGRAM_ALLOWED_USER_IDS=9876");
});

test("first-run screens are marked done without losing existing Claude settings", () => {
  writeFileSync(join(dir, ".claude.json"), JSON.stringify({ userID: "keep", projects: { "/x": { a: 1 } } }));
  const r = run("mark_first_run_done");
  expect(r.code).toBe(0);
  const c = JSON.parse(readFileSync(join(dir, ".claude.json"), "utf8"));
  expect(c.userID).toBe("keep");
  expect(c.hasCompletedOnboarding).toBe(true);
  expect(c.projects["/x"].a).toBe(1);
  expect(c.projects[agent].hasTrustDialogAccepted).toBe(true);
});

test("claude login is skipped when already signed in, fails clearly when not", () => {
  stub("claude", `[ "$1 $2" = "auth status" ] && echo '{ "loggedIn": true }'`);
  expect(run("claude_login").out).toContain("уже выполнен");
  stub("claude", `[ "$1 $2" = "auth status" ] && echo '{ "loggedIn": false }'; exit 0`);
  const r = run("claude_login");
  expect(r.code).toBe(1);
  expect(r.out).toContain("вход в Claude не выполнен");
});

test("service unit runs start.sh in tmux, restarts itself, confirms the channels warning", () => {
  const unitDir = join(dir, "etc");
  mkdirSync(unitDir);
  const r = run("install_service", "", { UNIT_DIR: unitDir });
  expect(r.code).toBe(0);
  const unit = readFileSync(join(unitDir, "agent.service"), "utf8");
  expect(unit).toContain(`cd ${agent} && bash start.sh`);
  expect(unit).toContain("Restart=always");
  expect(unit).toContain('grep -q "development channels"');
  expect(unit).toContain('grep -q "Yes, I trust this folder"');
  // systemd turns $$ into a literal $; the heredoc is unquoted, so the script must write \$\$
  expect(unit).toContain('for i in $$(seq 1 30)');
  expect(unit).toContain('echo "$$p"');
  expect(readFileSync(join(dir, "sys.log"), "utf8")).toContain("systemctl enable agent");
});

test("refuses a non-empty foreign folder instead of overwriting it", () => {
  writeFileSync(join(agent, "something.txt"), "x");
  const r = run("get_template");
  expect(r.code).toBe(1);
  expect(r.out).toContain("уже занята");
});
