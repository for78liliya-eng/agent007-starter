#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────
# install.sh — one-command setup of a personal Claude Code agent in Telegram
# on a fresh Ubuntu/Debian server (run as root).
#
#   curl -fsSL https://raw.githubusercontent.com/for78liliya-eng/agent007-starter/main/install.sh | bash
#
# What it does (each step is skipped if already done, so it is safe to re-run):
#   1. system packages + light hardening (fail2ban, automatic security updates)
#   2. bun and Claude Code
#   3. the agent folder from this template (default /root/agent)
#   4. asks for the bot token, finds the owner's Telegram ID by itself
#   5. Claude sign-in (link + code in the browser)
#   6. a systemd service: the agent runs 24/7 and restarts itself
#   7. the bot writes to the owner: "I am installed"
#
# The student only does what must be done by a human: create a bot in
# @BotFather, sign in to Claude, write one message to their bot.
# Env overrides: AGENT_DIR, AGENT_NAME (service + tmux name), REPO_URL, BRANCH.
# Messages to the user are in Russian; code comments are in English.
# ─────────────────────────────────────────────────────────────
set -uo pipefail

# Everything lives in main(), called on the last line: if the download is cut
# off midway, bash never runs a half-received script.
main() {
  AGENT_DIR="${AGENT_DIR:-/root/agent}"
  AGENT_NAME="${AGENT_NAME:-agent}"
  REPO_URL="${REPO_URL:-https://github.com/for78liliya-eng/agent007-starter.git}"
  BRANCH="${BRANCH:-main}"
  ENV_FILE="$AGENT_DIR/secrets/channel.env"
  export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"

  # Reading answers: from the terminal even when the script itself comes from a pipe.
  if [ -z "${INSTALL_TTY:-}" ]; then
    if [ -r /dev/tty ] && (exec </dev/tty) 2>/dev/null; then INSTALL_TTY=/dev/tty; else INSTALL_TTY=/dev/stdin; fi
  fi
  exec 3<"$INSTALL_TTY"   # opened once, so consecutive answers are read in order

  say  "Устанавливаю вашего агента. Это займёт 5–10 минут."
  say  "Мне понадобятся: ключ бота от @BotFather и вход в ваш аккаунт Claude."
  echo

  check_system
  step 1 "Обновляю сервер и ставлю нужные программы"; install_packages
  step 2 "Ставлю bun и Claude Code";                    install_bun; install_claude
  step 3 "Создаю папку агента: $AGENT_DIR";              get_template
  step 4 "Подключаю Telegram";                          setup_telegram
  step 5 "Вход в Claude";                               claude_login; mark_first_run_done
  step 6 "Включаю круглосуточную работу";               install_service
  step 7 "Проверяю";                                    final_check
}

# ── output helpers ──
say()  { printf '%s\n' "$*"; }
step() { echo; printf '━━ Шаг %s из 7. %s\n' "$1" "$2"; }
ok()   { printf '   готово: %s\n' "$*"; }
die()  { echo; printf 'ОШИБКА: %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2"; echo "Исправьте и запустите ту же команду ещё раз: сделанные шаги повторяться не будут."; exit 1; }
ask()  { local __v; printf '%s' "$1" >&2; IFS= read -r __v <&3 || __v=""; printf '%s' "$__v"; }

check_system() {
  [ "$(id -u)" = "0" ] || die "запустите под пользователем root" "Зайдите на сервер командой ssh root@АДРЕС_СЕРВЕРА и повторите."
  command -v apt-get >/dev/null 2>&1 || die "нужен сервер с Ubuntu или Debian" "При создании сервера выберите Ubuntu 24.04."
  curl -fsS -m 15 -o /dev/null https://api.telegram.org 2>/dev/null || curl -sS -m 15 -o /dev/null https://api.telegram.org \
    || die "сервер не может достучаться до Telegram" "Сервер должен быть не в России (Telegram оттуда закрыт). Возьмите сервер в США, как в первом уроке."
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || die "не удалось обновить список программ" "Проверьте интернет на сервере."
  apt-get install -y -qq git curl unzip tmux ca-certificates fail2ban unattended-upgrades >/dev/null 2>&1 \
    || die "не удалось поставить программы (git, tmux и другие)"
  systemctl enable --now fail2ban >/dev/null 2>&1 || true
  ok "git, tmux, защита от подбора пароля (fail2ban), автообновления безопасности"
  # Cheapest servers have 1 GB RAM; Claude Code + the plugin need headroom.
  if [ -z "$(swapon --show 2>/dev/null)" ] && [ ! -f /swapfile ]; then
    if fallocate -l 2G /swapfile 2>/dev/null && chmod 600 /swapfile && mkswap /swapfile >/dev/null 2>&1 && swapon /swapfile 2>/dev/null; then
      grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      ok "запасная память 2 ГБ (swap)"
    fi
  fi
}

install_bun() {
  if ! command -v bun >/dev/null 2>&1; then
    curl -fsSL https://bun.sh/install | bash >/dev/null 2>&1 || die "не удалось поставить bun"
  fi
  command -v bun >/dev/null 2>&1 || die "bun поставился, но не находится"
  ok "bun $(bun --version)"
}

install_claude() {
  if ! command -v claude >/dev/null 2>&1; then
    curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1 || die "не удалось поставить Claude Code"
  fi
  command -v claude >/dev/null 2>&1 || die "Claude Code поставился, но не находится"
  ok "Claude Code $(claude --version 2>/dev/null | awk '{print $1}')"
}

get_template() {
  if [ -d "$AGENT_DIR/.git" ]; then
    ok "папка уже есть, оставляю как есть (ваши настройки и память не трогаю)"
  else
    [ -e "$AGENT_DIR" ] && die "папка $AGENT_DIR уже занята чем-то другим" "Переименуйте её или запустите так: AGENT_DIR=/root/agent2 bash install.sh"
    git clone -q --branch "$BRANCH" "$REPO_URL" "$AGENT_DIR" || die "не удалось скачать заготовку агента"
    ok "заготовка скачана"
  fi
  (cd "$AGENT_DIR/dashi-plugin-claude-code/plugin" && bun install --silent >/dev/null 2>&1) || die "не удалось поставить плагин связи с Telegram"
  ok "плагин связи с Telegram"
}

# Telegram Bot API helper: tg <method> [curl args...]. Token never printed.
tg() { local m="$1"; shift; curl -sS -m 40 "https://api.telegram.org/bot${BOT_TOKEN}/${m}" "$@"; }
# jq-like one-liner on bun (installed in step 2): js <expression on `d`> < json
js() { bun -e "const d=JSON.parse(require('fs').readFileSync(0,'utf8')); const r=($1); if (r!==undefined && r!==null) console.log(r)" 2>/dev/null; }

setup_telegram() {
  if [ -f "$ENV_FILE" ] && grep -q '^TELEGRAM_BOT_TOKEN=.\+' "$ENV_FILE" && grep -q '^TELEGRAM_ALLOWED_USER_IDS=[0-9]\+' "$ENV_FILE"; then
    ok "Telegram уже настроен (secrets/channel.env), пропускаю"
    BOT_TOKEN="$(sed -n 's/^TELEGRAM_BOT_TOKEN=//p' "$ENV_FILE")"
    OWNER_ID="$(sed -n 's/^TELEGRAM_ALLOWED_USER_IDS=//p' "$ENV_FILE" | cut -d, -f1)"
    return
  fi
  say "   Откройте в Telegram @BotFather, отправьте /newbot, придумайте имя и адрес бота."
  say "   BotFather пришлёт ключ вида 1234567890:AAH... — скопируйте его целиком."
  local me tries=0
  while :; do
    BOT_TOKEN="$(ask '   Вставьте ключ бота и нажмите Enter: ' | tr -d '[:space:]')"
    if [[ "$BOT_TOKEN" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{30,}$ ]]; then
      me="$(tg getMe)"
      if printf '%s' "$me" | grep -q '"ok":true'; then break; fi
      say "   Telegram не принял этот ключ. Скопируйте его из BotFather ещё раз."
    else
      say "   Это не похоже на ключ бота. Он выглядит так: 1234567890:AAH... (цифры, двоеточие, буквы)."
    fi
    tries=$((tries+1)); [ $tries -ge 5 ] && die "ключ бота так и не подошёл"
  done
  BOT_ID="${BOT_TOKEN%%:*}"
  BOT_USERNAME="$(printf '%s' "$me" | js 'd.result.username')"
  ok "бот @$BOT_USERNAME"

  # The bot must not be in use elsewhere (another agent, a webhook).
  tg deleteWebhook >/dev/null 2>&1 || true

  say "   Теперь откройте своего бота @$BOT_USERNAME в Telegram и отправьте ему любое слово."
  say "   Так я узнаю ваш номер в Telegram, и агент будет отвечать только вам. Жду до 3 минут..."
  OWNER_ID=""; OWNER_NAME=""
  local upd offset=0 i
  for i in $(seq 1 18); do
    upd="$(tg getUpdates -d timeout=10 -d offset=$offset 2>/dev/null)"
    # first private message from a human: "<id>\t<first name>\t<update_id>"
    local hit; hit="$(printf '%s' "$upd" | js '(d.result||[]).map(u=>u.message).filter(m=>m&&m.from&&!m.from.is_bot&&m.chat.type==="private").map(m=>m.from.id+"\t"+(m.from.first_name||""))[0]')"
    if [ -n "$hit" ]; then
      OWNER_ID="${hit%%$'\t'*}"; OWNER_NAME="${hit#*$'\t'}"
      # Acknowledge the updates so the agent does not get the test word later.
      local last; last="$(printf '%s' "$upd" | js 'Math.max(...d.result.map(u=>u.update_id))')"
      [ -n "$last" ] && tg getUpdates -d offset=$((last+1)) -d timeout=0 >/dev/null 2>&1
      break
    fi
  done
  if [ -z "$OWNER_ID" ]; then
    say "   Сообщение не пришло. Узнайте свой номер у бота @userinfobot (строка Id)."
    OWNER_ID="$(ask '   Вставьте ваш номер (только цифры): ' | tr -cd '0-9')"
    [ -n "$OWNER_ID" ] || die "без вашего номера агент не будет знать, кому отвечать"
  else
    ok "ваш номер в Telegram: $OWNER_ID ($OWNER_NAME)"
  fi

  mkdir -p "$AGENT_DIR/secrets"
  ( umask 077
    cat > "$ENV_FILE" <<EOF
# Created by install.sh. Only on this server: not in git, not in backups.
TELEGRAM_BOT_TOKEN=$BOT_TOKEN
TELEGRAM_EXPECTED_BOT_ID=$BOT_ID
TELEGRAM_ALLOWED_USER_IDS=$OWNER_ID
AGENT_ID=$AGENT_NAME
TELEGRAM_MEMORY_ENABLED=false
GROQ_API_KEY=
EOF
  )
  chmod 600 "$ENV_FILE"
  ok "ключи сохранены в secrets/channel.env (видны только на этом сервере)"
}

claude_logged_in() { claude auth status 2>/dev/null | grep -q '"loggedIn": *true'; }

claude_login() {
  if claude_logged_in; then ok "вход в Claude уже выполнен"; return; fi
  say "   Сейчас появится ссылка. Откройте её в браузере, где вы вошли в claude.ai, и нажмите «Разрешить»."
  say "   Скопируйте код со страницы, вставьте сюда и нажмите Enter."
  claude auth login --claudeai <&3 || true
  claude_logged_in || die "вход в Claude не выполнен" "Нужна подписка Claude Pro или Max. Запустите команду ещё раз и пройдите вход до конца."
  ok "вход в Claude выполнен"
}

# Skip the first-run screens (theme, folder trust) that would block a service with no one at the keyboard.
mark_first_run_done() {
  AGENT_DIR="$AGENT_DIR" bun -e '
    const fs = require("fs"), p = process.env.HOME + "/.claude.json";
    let c = {}; try { c = JSON.parse(fs.readFileSync(p, "utf8")); } catch {}
    c.hasCompletedOnboarding = true;
    c.projects ??= {};
    const d = process.env.AGENT_DIR;
    c.projects[d] = { ...(c.projects[d] ?? {}), hasTrustDialogAccepted: true };
    fs.writeFileSync(p, JSON.stringify(c, null, 2));
  ' || die "не удалось сохранить настройки Claude"
}

install_service() {
  local unit="${UNIT_DIR:-/etc/systemd/system}/${AGENT_NAME}.service" n="$AGENT_NAME"
  cat > "$unit" <<EOF
[Unit]
Description=Personal Claude agent in Telegram (${n}), 24/7
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
WorkingDirectory=${AGENT_DIR}
Environment=HOME=${HOME}
Environment=PATH=${HOME}/.local/bin:${HOME}/.bun/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/bin/tmux -L ${n} new-session -d -s ${n} 'cd ${AGENT_DIR} && bash start.sh'
# Nobody is at the keyboard: accept the folder-trust question if it shows up (e.g. a second
# agent installed while the first one rewrote ~/.claude.json), then the "development channels" warning.
ExecStartPost=/bin/sh -c 'for i in \$\$(seq 1 30); do sleep 5; p=\$\$(/usr/bin/tmux -L ${n} capture-pane -p -t ${n} 2>/dev/null); if echo "\$\$p" | grep -q "Yes, I trust this folder"; then /usr/bin/tmux -L ${n} send-keys -t ${n} Enter; elif echo "\$\$p" | grep -q "development channels"; then /usr/bin/tmux -L ${n} send-keys -t ${n} Enter; break; fi; done'
ExecStop=-/usr/bin/tmux -L ${n} kill-server
Restart=always
RestartSec=5
TimeoutStartSec=180

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$n" >/dev/null 2>&1
  systemctl restart "$n" || die "служба агента не запустилась" "Подробности: journalctl -u $n -n 50"
  ok "служба $n: запускается сама после перезагрузки и поднимается, если упала"
}

final_check() {
  local i up=""
  for i in $(seq 1 18); do
    sleep 5
    if tmux -L "$AGENT_NAME" capture-pane -p -t "$AGENT_NAME" 2>/dev/null | grep -q "❯"; then up=1; break; fi
  done
  if [ -z "$up" ]; then
    say "   Агент запускается дольше обычного. Посмотреть его окно: tmux -L $AGENT_NAME attach (выйти: Ctrl+B, потом D)."
  fi
  tg sendMessage -d chat_id="$OWNER_ID" --data-urlencode "text=Я установлен и работаю на сервере круглосуточно. Напишите мне что-нибудь, например: «Привет! Расскажи, что ты умеешь»." >/dev/null 2>&1 || true

  echo
  say "━━ Готово. Агент работает."
  say "Бот уже написал вам в Telegram. Ответьте ему — первое сообщение может идти до минуты."
  echo
  say "Пригодится:"
  say "  перезапустить агента:     systemctl restart $AGENT_NAME"
  say "  посмотреть окно агента:   tmux -L $AGENT_NAME attach   (выйти, не останавливая: Ctrl+B, потом D)"
  say "  состояние:                systemctl status $AGENT_NAME"
  say "  папка агента:             $AGENT_DIR"
}

# Allow tests to source the functions without running the installer.
if [ "${INSTALL_SH_SOURCE_ONLY:-}" != "1" ]; then main "$@"; fi
