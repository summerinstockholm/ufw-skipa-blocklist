# SKIPA UFW blocklist for Ubuntu 24.04

Этот репозиторий защищает Ubuntu 24.04 сервер от IP-адресов и подсетей из проекта [CyberOK_Skipa_ips](https://github.com/tread-lightly/CyberOK_Skipa_ips/tree/main).

## Структура репозитория

```text
.
├── README.md
├── scripts
│   ├── install-skipa-banlist.sh
│   └── update-skipa-banlist.sh
└── systemd
    ├── skipa-banlist.service
    └── skipa-banlist.timer
```

## Смысл решения

Решение работает через **UFW** и **не трогает** `/etc/nftables.conf`.

Скрипты делают следующее:

- скачивают актуальный `skipa_cidr.txt` из исходного репозитория проекта [CyberOK_Skipa_ips](https://github.com/tread-lightly/CyberOK_Skipa_ips/tree/main);
- валидируют IPv4/CIDR;
- ведут блоклист как **управляемый блок** внутри `/etc/ufw/before.rules`;
- вставляют этот блок **в начало `*filter`-секции**, то есть **раньше стандартных UFW-правил**, включая стандартные ICMP accept;
- не трогают существующие правила, добавленные через `ufw allow/deny/...`;
- обновляют блоклист по `systemd timer`.

В результате:

- входящий трафик **от** IP/подсетей из списка дропается;
- исходящий трафик **к** IP/подсетям из списка дропается;
- транзитный `forward`-трафик **от** и **к** IP/подсетям из списка дропается;
- ICMP от заблокированных адресов тоже дропается, потому что managed-блок стоит раньше стандартных UFW accept для ICMP.

## Что важно заранее понимать

- это решение рассчитано на хосты, где **UFW является основным firewall-менеджером**;
- если на сервере отдельно включён `nftables.service` с native-конфигурацией, installer и updater **остановятся с ошибкой**;
- существующие правила UFW не удаляются и не переписываются;
- `ufw status` не покажет правила из `/etc/ufw/before.rules`, поэтому проверять результат нужно через `ufw show raw` и просмотр самого файла.

## Требования

- Ubuntu 24.04;
- root или `sudo`;
- установленный `ufw`;
- включённый `ufw`;
- доступ к `https://raw.githubusercontent.com/`.

## Проверки перед установкой

### Проверить, что UFW включён

```bash
sudo ufw status verbose
```

Ожидается:

```text
Status: active
```

Если UFW выключен, включи его сам:

```bash
sudo ufw enable
```

### Проверить возможный конфликт с native nftables

```bash
sudo systemctl is-enabled nftables.service
sudo systemctl is-active nftables.service
sudo sed -n '1,200p' /etc/nftables.conf 2>/dev/null
```

Если `nftables.service` включён или активен, сначала разберись с этим конфликтом. Этот репозиторий не должен работать параллельно с отдельным native `nftables`-контуром.

## Установка

### Шаг 1. Клонировать репозиторий

```bash
git clone <git@github.com:summerinstockholm/ufw-skipa-blocklist.git>
cd <ufw-skipa-blocklist>
```

### Шаг 2. Запустить installer

```bash
sudo bash scripts/install-skipa-banlist.sh
```

Installer сам сделает следующее:

- проверит root;
- проверит наличие файлов репозитория;
- установит `ufw`, `curl`, `python3`, если нужно;
- проверит, что `ufw` активен;
- проверит конфликт с `nftables.service`;
- сделает backup `/etc/ufw/before.rules`;
- установит updater-скрипт и systemd unit-файлы;
- выполнит первую загрузку блоклиста;
- включит timer.

## Что создаётся на сервере

### Установленные файлы

```text
/usr/local/sbin/update-skipa-banlist.sh
/etc/systemd/system/skipa-banlist.service
/etc/systemd/system/skipa-banlist.timer
```

### Изменяемый файл

```text
/etc/ufw/before.rules
```

В него добавляется только управляемый блок между маркерами:

```text
# BEGIN SKIPA BLOCKLIST - managed by update-skipa-banlist.sh
...
# END SKIPA BLOCKLIST - managed by update-skipa-banlist.sh
```

Этот блок updater пересобирает целиком при каждом обновлении.

## Проверка после установки

### Проверить timer

```bash
systemctl status skipa-banlist.timer --no-pager
systemctl list-timers --all | grep skipa
```

### Проверить service

```bash
systemctl status skipa-banlist.service --no-pager
journalctl -u skipa-banlist.service -n 100 --no-pager
```

### Проверить, что managed-блок попал в `/etc/ufw/before.rules`

```bash
sudo sed -n '/BEGIN SKIPA BLOCKLIST/,/END SKIPA BLOCKLIST/p' /etc/ufw/before.rules
```

### Проверить полный firewall state

```bash
sudo ufw show raw
```

### Проверить только строки с блоклистом в raw rules

```bash
sudo ufw show raw | grep -E 'ufw-before-(input|output|forward).*SKIPA|ufw-before-(input|output|forward)'
```

## Обновление вручную

Если нужно немедленно подтянуть свежий список:

```bash
sudo /usr/local/sbin/update-skipa-banlist.sh
```

## Как именно блокируется трафик

Updater добавляет в `before.rules` такие типы правил:

- `ufw-before-input` + `-s <CIDR> -j DROP`
- `ufw-before-output` + `-d <CIDR> -j DROP`
- `ufw-before-forward` + `-s <CIDR> -j DROP`
- `ufw-before-forward` + `-d <CIDR> -j DROP`

Это означает:

- с этих адресов нельзя достучаться до хоста;
- хост сам не сможет ходить на эти адреса;
- если хост форвардит трафик, то трафик через него от/к этим адресам тоже режется.

## Почему ICMP тоже блокируется

Managed-блок вставляется в начало `*filter`-секции `before.rules`, то есть **раньше** стандартных UFW-правил для ICMP. Поэтому ping и другой трафик от заблокированных адресов тоже попадут под DROP раньше стандартных accept-правил.

## Повторный запуск installer

Повторный запуск допустим:

```bash
sudo bash scripts/install-skipa-banlist.sh
```

Он не должен ломать существующие правила UFW и просто переустановит свои файлы и заново пересоберёт managed-блок.

## Удаление

### Остановить timer

```bash
sudo systemctl disable --now skipa-banlist.timer
```

### Удалить unit-файлы

```bash
sudo rm -f /etc/systemd/system/skipa-banlist.service
sudo rm -f /etc/systemd/system/skipa-banlist.timer
sudo systemctl daemon-reload
```

### Удалить managed-блок из `/etc/ufw/before.rules`

Самый простой путь — восстановить backup, который делал installer или updater.

Если backup не нужен и хочешь убрать только managed-блок:

```bash
sudo python3 - <<'PY'
from pathlib import Path
path = Path('/etc/ufw/before.rules')
text = path.read_text(encoding='utf-8')
start = '# BEGIN SKIPA BLOCKLIST - managed by update-skipa-banlist.sh'
end = '# END SKIPA BLOCKLIST - managed by update-skipa-banlist.sh'
start_index = text.find(start)
if start_index != -1:
    end_index = text.find(end, start_index)
    if end_index != -1:
        end_index += len(end)
        if end_index < len(text) and text[end_index:end_index+1] == '\n':
            end_index += 1
        new_text = text[:start_index] + text[end_index:]
        path.write_text(new_text, encoding='utf-8')
PY
sudo ufw reload
```

### Удалить updater-скрипт

```bash
sudo rm -f /usr/local/sbin/update-skipa-banlist.sh
```
