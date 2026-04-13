#!/usr/bin/env bash

set -euo pipefail

# Определяем каталог, в котором лежит текущий installer-скрипт.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Определяем корневой каталог репозитория как каталог уровнем выше папки scripts.
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Определяем путь к updater-скрипту внутри репозитория.
LOCAL_UPDATE_SCRIPT="${REPO_ROOT}/scripts/update-skipa-banlist.sh"
# Определяем путь к service unit внутри репозитория.
LOCAL_SERVICE_FILE="${REPO_ROOT}/systemd/skipa-banlist.service"
# Определяем путь к timer unit внутри репозитория.
LOCAL_TIMER_FILE="${REPO_ROOT}/systemd/skipa-banlist.timer"
# Определяем путь установки updater-скрипта на целевом сервере.
TARGET_UPDATE_SCRIPT="/usr/local/sbin/update-skipa-banlist.sh"
# Определяем путь установки service unit на целевом сервере.
TARGET_SERVICE_FILE="/etc/systemd/system/skipa-banlist.service"
# Определяем путь установки timer unit на целевом сервере.
TARGET_TIMER_FILE="/etc/systemd/system/skipa-banlist.timer"
# Определяем путь к основному UFW before.rules файлу, который будем изменять.
UFW_BEFORE_RULES="/etc/ufw/before.rules"
# Определяем путь к файлу native nftables-конфига только для проверки конфликта.
NFTABLES_CONF="/etc/nftables.conf"
# Определяем имя unit-файла standalone nftables-сервиса для проверки конфликта.
NFTABLES_SERVICE="nftables.service"

# Проверяем, что installer запущен от root
if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: запускай installer от root или через sudo." >&2
  exit 1
fi

# Проверяем, что updater-скрипт действительно существует в репозитории.
if [[ ! -f "${LOCAL_UPDATE_SCRIPT}" ]]; then
  echo "ERROR: не найден файл ${LOCAL_UPDATE_SCRIPT}." >&2
  exit 1
fi

# Проверяем, что service unit действительно существует в репозитории.
if [[ ! -f "${LOCAL_SERVICE_FILE}" ]]; then
  echo "ERROR: не найден файл ${LOCAL_SERVICE_FILE}." >&2
  exit 1
fi

# Проверяем, что timer unit действительно существует в репозитории.
if [[ ! -f "${LOCAL_TIMER_FILE}" ]]; then
  echo "ERROR: не найден файл ${LOCAL_TIMER_FILE}." >&2
  exit 1
fi

# Обновляем индекс пакетов apt перед установкой зависимостей. Устанавливаем ufw, curl и python3, если их ещё нет в системе.
apt update && apt install -y ufw curl python3

# Проверяем, что команда ufw доступна в PATH после установки пакета.
if ! command -v ufw >/dev/null 2>&1; then
  echo "ERROR: команда ufw недоступна даже после установки пакета." >&2
  exit 1
fi

# Проверяем, что основной файл /etc/ufw/before.rules существует.
if [[ ! -f "${UFW_BEFORE_RULES}" ]]; then
  echo "ERROR: не найден файл ${UFW_BEFORE_RULES}." >&2
  exit 1
fi

# Проверяем, что UFW уже активен, потому что дальше будет ufw reload.
if ! ufw status | grep -q '^Status: active'; then
  echo "ERROR: UFW выключен. Сначала включи UFW командой 'sudo ufw enable', потом запусти installer снова." >&2
  exit 1
fi

# Проверяем, включён ли standalone nftables.service в автозапуск.
NFTABLES_ENABLED="no"
if systemctl is-enabled "${NFTABLES_SERVICE}" >/dev/null 2>&1; then
  NFTABLES_ENABLED="yes"
fi

# Проверяем, активен ли standalone nftables.service прямо сейчас.
NFTABLES_ACTIVE="no"
if systemctl is-active "${NFTABLES_SERVICE}" >/dev/null 2>&1; then
  NFTABLES_ACTIVE="yes"
fi

# Проверяем, содержит ли /etc/nftables.conf хоть какие-то осмысленные строки кроме комментариев и пустых строк.
NFTABLES_CONF_HAS_CONTENT="no"
if [[ -f "${NFTABLES_CONF}" ]] && grep -Eq '^[[:space:]]*[^#[:space:]]' "${NFTABLES_CONF}"; then
  NFTABLES_CONF_HAS_CONTENT="yes"
fi

# Если standalone nftables service включён или активен, считаем это конфликтом и останавливаем установку.
if [[ "${NFTABLES_ENABLED}" == "yes" || "${NFTABLES_ACTIVE}" == "yes" ]]; then
  echo "ERROR: обнаружен конфликт с standalone ${NFTABLES_SERVICE}." >&2

  # Печатаем состояние unit-файла, чтобы было видно источник проблемы.
  echo "       is-enabled: ${NFTABLES_ENABLED}" >&2

  # Печатаем состояние активности unit-файла.
  echo "       is-active : ${NFTABLES_ACTIVE}" >&2

  # Если /etc/nftables.conf непустой, отдельно сообщаем об этом.
  if [[ "${NFTABLES_CONF_HAS_CONTENT}" == "yes" ]]; then
    # Печатаем пояснение, что native nftables-конфиг тоже не пустой.
    echo "       /etc/nftables.conf содержит правила или другие осмысленные строки." >&2
  fi

  # Печатаем инструкцию сначала разобраться с native nftables, а потом запускать installer.
  echo "       Этот репозиторий рассчитан на UFW-only подход и не должен работать параллельно с standalone nftables.service." >&2
  exit 1
fi

# Если nftables.service не активен, но /etc/nftables.conf непустой, просто предупреждаем администратора.
if [[ "${NFTABLES_CONF_HAS_CONTENT}" == "yes" ]]; then
  # Печатаем warning, что файл есть и содержит данные, но сервис не активен.
  echo "WARNING: /etc/nftables.conf содержит данные, но standalone nftables.service не активен и не включён." >&2

  # Печатаем совет не включать native nftables параллельно с этим UFW-only решением.
  echo "         Не включай standalone nftables.service параллельно с этим репозиторием." >&2
fi

# Делаем резервную копию /etc/ufw/before.rules перед первой модификацией.
cp -a "${UFW_BEFORE_RULES}" "${UFW_BEFORE_RULES}.bak.$(date +%F-%H%M%S)"

# Устанавливаем updater-скрипт в /usr/local/sbin с правами на исполнение.
install -m 0755 "${LOCAL_UPDATE_SCRIPT}" "${TARGET_UPDATE_SCRIPT}"

# Устанавливаем service unit в каталог systemd unit-файлов.
install -m 0644 "${LOCAL_SERVICE_FILE}" "${TARGET_SERVICE_FILE}"

# Устанавливаем timer unit в каталог systemd unit-файлов.
install -m 0644 "${LOCAL_TIMER_FILE}" "${TARGET_TIMER_FILE}"

# Перечитываем unit-файлы systemd после установки service и timer.
systemctl daemon-reload

# Выполняем updater-скрипт сразу же, чтобы скачать список и внедрить managed-блок в before.rules.
"${TARGET_UPDATE_SCRIPT}"

# Включаем timer в автозапуск и запускаем его сразу же.
systemctl enable --now skipa-banlist.timer

echo "OK: SKIPA blocklist установлена в UFW, managed-блок создан, timer включён."