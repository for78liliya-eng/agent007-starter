# Заготовка агента — курс «Агент своими руками»

Из этой папки получается ваш личный агент в Telegram на Claude Code.
Пошагово всё разобрано в уроках курса; здесь — короткая памятка.

## Что нужно заранее
- подписка Claude Pro или Max;
- на компьютере: Git, Claude Code и bun (урок 6);
- бот от @BotFather и ваш Telegram ID от @userinfobot.

## Запуск (урок 7)
```bash
git clone https://github.com/for78liliya-eng/agent007-starter.git coder
cd coder
claude
```
В чате claude попросите: «создай secrets/channel.env по образцу
channel.env.example и впиши мой токен и ID». Выйдите (Ctrl+C два раза) и:
```bash
bash start.sh
```
Напишите боту в Telegram — он ответит.

## Что внутри
| Что | Зачем |
|---|---|
| `CLAUDE.md` | личность агента-кодера |
| `core/` | память: кто владелец, оглавление, заметки по темам |
| `secrets/` | токены и ключи — только у вас, в git не попадают |
| `.claude/settings.json` | что агенту можно делать без вопросов |
| `.mcp.json` | подключение плагина связи с Telegram |
| `start.sh` | запуск агента со связью с Telegram |
| `dashi-plugin-claude-code/` | плагин связи с Telegram (Apache 2.0, см. NOTICE) |

## Проверка заготовки
```bash
bun test ./tests/
```
