#!/usr/bin/env bash
# Запуск агента: Claude Code + связь с Telegram.
# Пока это окно открыто — агент отвечает в Telegram.
# Чтобы работал круглосуточно — урок «Переезд на сервер».
set -euo pipefail

export PATH="$HOME/.bun/bin:$HOME/.local/bin:$PATH"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT/secrets/channel.env"
PLUGIN_DIR="$ROOT/dashi-plugin-claude-code/plugin"

fail() { echo; echo "ОШИБКА: $1"; [ -n "${2:-}" ] && echo "$2"; exit 1; }

[ -f "$ENV_FILE" ] || fail "нет файла secrets/channel.env" \
  "Попросите агента в чате claude: «создай secrets/channel.env по образцу channel.env.example и впиши мой токен и ID»."
command -v claude >/dev/null 2>&1 || fail "не найден Claude Code" "Поставьте его (урок 6) и откройте новый терминал."
command -v bun >/dev/null 2>&1 || fail "не найден bun" "Поставьте его (урок 6) и откройте новый терминал."

if [ ! -d "$PLUGIN_DIR/node_modules" ]; then
  echo "Первый запуск: ставлю детали плагина связи с Telegram (один раз)..."
  (cd "$PLUGIN_DIR" && bun install) || fail "не удалось поставить детали плагина" "Проверьте интернет и запустите ещё раз."
fi

# Ignore values inherited from a parent agent's shell (e.g. when the coder
# starts another agent); only channel.env may override the defaults below.
unset TELEGRAM_WORKSPACE_ROOT TELEGRAM_STATE_DIR TELEGRAM_MEMORY_WORKSPACE

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

[ -n "${TELEGRAM_BOT_TOKEN:-}" ] || fail "в secrets/channel.env пустой TELEGRAM_BOT_TOKEN"
[ -n "${TELEGRAM_ALLOWED_USER_IDS:-}" ] || fail "в secrets/channel.env пустой TELEGRAM_ALLOWED_USER_IDS" \
  "Без него агент не знает, кому отвечать. Узнайте свой ID у бота @userinfobot."

# Files the agent sends must live inside its own folder; absolute path avoids
# resolving "." relative to the plugin directory.
export TELEGRAM_WORKSPACE_ROOT="${TELEGRAM_WORKSPACE_ROOT:-$ROOT}"
# Per-agent state dir, so several agents on one machine do not share it.
export TELEGRAM_STATE_DIR="${TELEGRAM_STATE_DIR:-$ROOT/.state}"
if [ "${TELEGRAM_MEMORY_ENABLED:-false}" = "true" ]; then
  export TELEGRAM_MEMORY_WORKSPACE="${TELEGRAM_MEMORY_WORKSPACE:-$ROOT/core/memory}"
fi
mkdir -p "$TELEGRAM_STATE_DIR"

echo "Запускаю агента. Напишите своему боту в Telegram — он ответит."
echo "Остановить: Ctrl+C. Пока окно открыто — агент работает."
cd "$ROOT"
exec claude --dangerously-load-development-channels server:dashi-channel
