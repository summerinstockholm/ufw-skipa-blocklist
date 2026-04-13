#!/usr/bin/env bash

set -euo pipefail

# Определяем URL исходного списка IPv4/CIDR из репозитория CyberOK_Skipa_ips.
SOURCE_URL="${SOURCE_URL:-https://raw.githubusercontent.com/tread-lightly/CyberOK_Skipa_ips/main/lists/skipa_cidr.txt}"
# Определяем путь к основному UFW before.rules файлу, который будем аккуратно патчить.
UFW_BEFORE_RULES="${UFW_BEFORE_RULES:-/etc/ufw/before.rules}"
# Определяем путь к native nftables-конфигу только для проверки конфликта.
NFTABLES_CONF="${NFTABLES_CONF:-/etc/nftables.conf}"
# Определяем имя standalone nftables unit-файла для проверки конфликта.
NFTABLES_SERVICE="${NFTABLES_SERVICE:-nftables.service}"
# Определяем маркер начала управляемого блока в /etc/ufw/before.rules.
BEGIN_MARKER="# BEGIN SKIPA BLOCKLIST - managed by update-skipa-banlist.sh"
# Определяем маркер конца управляемого блока в /etc/ufw/before.rules.
END_MARKER="# END SKIPA BLOCKLIST - managed by update-skipa-banlist.sh"
# Создаём временный файл под исходный скачанный список.
TMP_SOURCE_FILE="$(mktemp)"
# Создаём временный файл под очищенный и провалидированный список CIDR.
TMP_CLEAN_FILE="$(mktemp)"
# Создаём временный файл под новый управляемый блок правил.
TMP_BLOCK_FILE="$(mktemp)"
# Создаём временный файл под новый кандидатный /etc/ufw/before.rules.
TMP_BEFORE_RULES_FILE="$(mktemp)"

# Объявляем функцию очистки временных файлов при любом выходе из скрипта.
cleanup() {
  # Удаляем временный файл с исходным списком.
  rm -f "${TMP_SOURCE_FILE}"
  # Удаляем временный файл с очищенным списком.
  rm -f "${TMP_CLEAN_FILE}"
  # Удаляем временный файл с управляемым блоком.
  rm -f "${TMP_BLOCK_FILE}"
  # Удаляем временный файл с кандидатным before.rules.
  rm -f "${TMP_BEFORE_RULES_FILE}"
}

# Регистрируем функцию cleanup на завершение скрипта.
trap cleanup EXIT

# Проверяем, что updater запущен от root, потому что он меняет /etc/ufw/before.rules и делает ufw reload.
if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: запускай updater от root или через sudo." >&2
  exit 1
fi

# Проверяем, что команда ufw доступна в системе.
if ! command -v ufw >/dev/null 2>&1; then
  echo "ERROR: команда ufw недоступна." >&2
  exit 1
fi

# Проверяем, что команда curl доступна в системе.
if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: команда curl недоступна." >&2
  exit 1
fi

# Проверяем, что python3 доступна в системе.
if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: команда python3 недоступна." >&2
  exit 1
fi

# Проверяем, что основной файл /etc/ufw/before.rules существует.
if [[ ! -f "${UFW_BEFORE_RULES}" ]]; then
  echo "ERROR: не найден файл ${UFW_BEFORE_RULES}." >&2
  exit 1
fi

# Проверяем, что UFW активен, потому что дальше будет ufw reload.
if ! ufw status | grep -q '^Status: active'; then
  echo "ERROR: UFW выключен. Сначала включи его командой 'sudo ufw enable'." >&2
  exit 1
fi

# Проверяем, включён ли standalone nftables.service в автозапуск.
NFTABLES_ENABLED="no"
if systemctl is-enabled "${NFTABLES_SERVICE}" >/dev/null 2>&1; then
  # Запоминаем, что nftables.service включён.
  NFTABLES_ENABLED="yes"
fi

# Проверяем, активен ли standalone nftables.service прямо сейчас.
NFTABLES_ACTIVE="no"
if systemctl is-active "${NFTABLES_SERVICE}" >/dev/null 2>&1; then
  # Запоминаем, что nftables.service активен.
  NFTABLES_ACTIVE="yes"
fi

# Проверяем, содержит ли /etc/nftables.conf осмысленные строки кроме комментариев и пустых строк.
NFTABLES_CONF_HAS_CONTENT="no"
if [[ -f "${NFTABLES_CONF}" ]] && grep -Eq '^[[:space:]]*[^#[:space:]]' "${NFTABLES_CONF}"; then
  # Запоминаем, что файл native nftables-конфига непустой.
  NFTABLES_CONF_HAS_CONTENT="yes"
fi

# Если standalone nftables service включён или активен, считаем это конфликтом и останавливаем обновление.
if [[ "${NFTABLES_ENABLED}" == "yes" || "${NFTABLES_ACTIVE}" == "yes" ]]; then
  # Печатаем подробную ошибку в stderr.
  echo "ERROR: обнаружен конфликт с standalone ${NFTABLES_SERVICE}." >&2

  # Печатаем состояние автозапуска unit-файла.
  echo "       is-enabled: ${NFTABLES_ENABLED}" >&2

  # Печатаем состояние активности unit-файла.
  echo "       is-active : ${NFTABLES_ACTIVE}" >&2

  # Если /etc/nftables.conf непустой, отдельно показываем это.
  if [[ "${NFTABLES_CONF_HAS_CONTENT}" == "yes" ]]; then
    # Печатаем пояснение о native nftables-конфиге.
    echo "       /etc/nftables.conf содержит правила или другие осмысленные строки." >&2
  fi

  # Печатаем рекомендацию сначала устранить конфликт.
  echo "       UFW-only updater не будет продолжать работу в такой конфигурации." >&2
  exit 1
fi

# Если nftables.service не активен, но /etc/nftables.conf непустой, просто печатаем предупреждение.
if [[ "${NFTABLES_CONF_HAS_CONTENT}" == "yes" ]]; then
  # Печатаем warning для администратора.
  echo "WARNING: /etc/nftables.conf содержит данные, но standalone nftables.service не активен и не включён." >&2

  # Печатаем совет не включать native nftables параллельно с этим UFW-only решением.
  echo "         Не включай standalone nftables.service параллельно с этим updater-скриптом." >&2
fi

# Скачиваем исходный список IP-адресов и подсетей во временный файл.
curl --fail --silent --show-error --location "${SOURCE_URL}" --output "${TMP_SOURCE_FILE}"

# Валидируем список IPv4/CIDR через Python и одновременно нормализуем его.
python3 - "${TMP_SOURCE_FILE}" "${TMP_CLEAN_FILE}" <<'PY'
# Импортируем модуль ipaddress для строгой проверки IPv4 сетей.
import ipaddress

# Импортируем sys для чтения аргументов командной строки.
import sys

# Получаем путь к исходному файлу со списком.
src_path = sys.argv[1]

# Получаем путь к выходному файлу для очищенного списка.
out_path = sys.argv[2]

# Создаём множество для дедупликации записей.
seen = set()

# Открываем исходный файл в UTF-8 на чтение.
with open(src_path, 'r', encoding='utf-8') as src:
    # Итерируемся по строкам исходного файла.
    for raw_line in src:
        # Отрезаем inline-комментарий после символа # и убираем пробелы по краям.
        line = raw_line.split('#', 1)[0].strip()

        # Пропускаем пустые строки.
        if not line:
            continue

        # Строго интерпретируем запись как IPv4 сеть или IPv4 адрес с маской.
        network = ipaddress.IPv4Network(line, strict=False)

        # Сохраняем запись в каноническом виде.
        seen.add(str(network))

# Открываем выходной файл на запись в UTF-8.
with open(out_path, 'w', encoding='utf-8') as out:
    # Сортируем сети сначала по сетевому адресу, затем по длине префикса.
    for network in sorted(
        seen,
        key=lambda item: (
            int(ipaddress.IPv4Network(item).network_address),
            ipaddress.IPv4Network(item).prefixlen,
        ),
    ):
        # Записываем нормализованную сеть в отдельную строку.
        out.write(network + '\n')
PY

# Проверяем, что после очистки список не оказался пустым.
if [[ ! -s "${TMP_CLEAN_FILE}" ]]; then
  echo "ERROR: после валидации список блокировок пуст." >&2
  exit 1
fi

# Формируем новый управляемый блок правил во временный файл.
{
  # Печатаем маркер начала управляемого блока.
  printf '%s\n' "${BEGIN_MARKER}"

  # Печатаем комментарий об источнике списка.
  printf '# Source: %s\n' "${SOURCE_URL}"

  # Печатаем комментарий о том, что блок пересобирается автоматически.
  printf '# This block is generated automatically. Do not edit it manually.\n'

  # Печатаем пустую строку для читаемости.
  printf '\n'

  # Читаем очищенные CIDR по одному и генерируем для каждого четыре правила.
  while IFS= read -r CIDR; do
    # Генерируем DROP для входящего трафика от адресов и подсетей из списка.
    printf -- '-A ufw-before-input -s %s -j DROP\n' "${CIDR}"

    # Генерируем DROP для исходящего трафика к адресам и подсетям из списка.
    printf -- '-A ufw-before-output -d %s -j DROP\n' "${CIDR}"

    # Генерируем DROP для форвардимого трафика от адресов и подсетей из списка.
    printf -- '-A ufw-before-forward -s %s -j DROP\n' "${CIDR}"

    # Генерируем DROP для форвардимого трафика к адресам и подсетям из списка.
    printf -- '-A ufw-before-forward -d %s -j DROP\n' "${CIDR}"
  done < "${TMP_CLEAN_FILE}"

  # Печатаем маркер конца управляемого блока.
  printf '%s\n' "${END_MARKER}"
} > "${TMP_BLOCK_FILE}"

# Патчим /etc/ufw/before.rules через Python, чтобы:
# 1) удалить старый managed-блок, если он уже был;
# 2) вставить новый managed-блок сразу после определения цепочек и до первого обычного правила.
python3 - "${UFW_BEFORE_RULES}" "${TMP_BLOCK_FILE}" "${TMP_BEFORE_RULES_FILE}" "${BEGIN_MARKER}" "${END_MARKER}" <<'PY'
# Импортируем sys для чтения аргументов командной строки.
import sys

# Импортируем Path для удобной работы с файлами.
from pathlib import Path

# Получаем путь к текущему before.rules.
before_rules_path = Path(sys.argv[1])

# Получаем путь к новому managed-блоку.
block_path = Path(sys.argv[2])

# Получаем путь к итоговому candidate before.rules.
out_path = Path(sys.argv[3])

# Получаем маркер начала блока.
begin_marker = sys.argv[4]

# Получаем маркер конца блока.
end_marker = sys.argv[5]

# Считываем исходный before.rules построчно с сохранением символов перевода строки.
lines = before_rules_path.read_text(encoding='utf-8').splitlines(keepends=True)

# Считываем новый managed-блок как список строк с переводами строки.
block_lines = block_path.read_text(encoding='utf-8').splitlines(keepends=True)

# Если в исходном файле нет финального перевода строки, это не проблема, новый блок будет вставлен ниже.
# Сначала удаляем старый managed-блок, если он уже присутствует.
filtered_lines = []
inside_block = False
for line in lines:
    stripped = line.rstrip('\n')
    if stripped == begin_marker:
        inside_block = True
        continue
    if stripped == end_marker:
        inside_block = False
        continue
    if inside_block:
        continue
    filtered_lines.append(line)

# Если после удаления блока подряд образовалось слишком много пустых строк, это некритично; оставим файл максимально близким к исходному.
lines = filtered_lines

# Ищем начало *filter секции.
filter_start_index = None
for index, line in enumerate(lines):
    if line.strip() == '*filter':
        filter_start_index = index
        break

# Если *filter секция не найдена, это нестандартный before.rules, и безопаснее остановиться.
if filter_start_index is None:
    raise SystemExit('ERROR: в /etc/ufw/before.rules не найдена секция *filter.')

# Ищем конец *filter секции, то есть первый COMMIT после *filter.
filter_commit_index = None
for index in range(filter_start_index + 1, len(lines)):
    if lines[index].strip() == 'COMMIT':
        filter_commit_index = index
        break

# Если COMMIT не найден, before.rules повреждён или нестандартен, поэтому безопаснее остановиться.
if filter_commit_index is None:
    raise SystemExit('ERROR: в /etc/ufw/before.rules не найден COMMIT для секции *filter.')

# Определяем точку вставки нового managed-блока.
# Вставляем блок сразу после объявления цепочек и комментариев вокруг них,
# но до первого реального правила типа -A/-I, чтобы наш DROP стоял раньше стандартных allow/accept.
insert_index = None
for index in range(filter_start_index + 1, filter_commit_index):
    stripped = lines[index].strip()
    if not stripped:
        continue
    if stripped.startswith('#'):
        continue
    if stripped.startswith(':'):
        continue
    insert_index = index
    break

# Если внутри *filter не найдено ни одного обычного правила,
# вставляем managed-блок перед COMMIT.
if insert_index is None:
    insert_index = filter_commit_index

# Собираем итоговый файл: начало, пустая строка, managed-блок, пустая строка, остаток файла.
new_lines = []
new_lines.extend(lines[:insert_index])
if new_lines and not new_lines[-1].endswith('\n'):
    new_lines[-1] = new_lines[-1] + '\n'
new_lines.append('\n')
new_lines.extend(block_lines)
new_lines.append('\n')
new_lines.extend(lines[insert_index:])

# Записываем candidate before.rules на диск.
out_path.write_text(''.join(new_lines), encoding='utf-8')
PY

# Делаем резервную копию текущего before.rules перед заменой файла.
BACKUP_FILE="${UFW_BEFORE_RULES}.bak.$(date +%F-%H%M%S)"
cp -a "${UFW_BEFORE_RULES}" "${BACKUP_FILE}"

# Устанавливаем новый candidate before.rules на место с корректными правами.
install -m 0640 "${TMP_BEFORE_RULES_FILE}" "${UFW_BEFORE_RULES}"

# Пытаемся перечитать правила через ufw reload.
if ufw reload; then
  # Если reload успешен, печатаем итоговое сообщение.
  echo "OK: SKIPA blocklist обновлён и применён через UFW."
else
  # Если reload не удался, печатаем ошибку о начале отката.
  echo "ERROR: ufw reload завершился ошибкой. Выполняется откат ${UFW_BEFORE_RULES} из backup ${BACKUP_FILE}." >&2

  # Восстанавливаем исходный before.rules из резервной копии.
  cp -a "${BACKUP_FILE}" "${UFW_BEFORE_RULES}"

  # Пробуем вернуть исходное состояние UFW после отката.
  ufw reload || true

  exit 1
fi
