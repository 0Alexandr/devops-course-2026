#!/usr/bin/env bash
# Контроль конфигурации сервера devops-vm (практические работы № 5 и 6)
set -uo pipefail

PASS=0; FAIL=0

check() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        echo "  [OK]   $desc"; ((PASS++))
    else
        echo "  [FAIL] $desc (ожидалось: '$expected', получено: '$actual')"; ((FAIL++))
    fi
}

echo "Аудит узла: $(hostname -f), $(date '+%Y-%m-%d %H:%M')"

echo "[1] Служба SSH"
check "Вход от имени root запрещён" "no" "$(sudo sshd -T | awk '/^permitrootlogin/{print $2}')"
check "Парольная аутентификация отключена" "no" "$(sudo sshd -T | awk '/^passwordauthentication/{print $2}')"

# TODO 1: значение параметра port отлично от 22
SSH_PORT="$(sudo sshd -T | awk '/^port /{print $2}')"
check "Порт SSH отличен от 22 (текущий: ${SSH_PORT:-нет})" "yes" \
      "$([[ -n "$SSH_PORT" && "$SSH_PORT" != "22" ]] && echo yes || echo no)"

# TODO 2: значение параметра maxauthtries равно 3
check "MaxAuthTries равно 3" "3" "$(sudo sshd -T | awk '/^maxauthtries/{print $2}')"

echo "[2] Межсетевой экран"
check "UFW активен" "active" "$(sudo ufw status | awk '/^Status:/{print $2}')"

# TODO 3: политика по умолчанию для входящего трафика равна deny
check "Политика входящего трафика по умолчанию: deny" "deny" \
      "$(sudo ufw status verbose | awk '/^Default:/{print $2}')"

echo "[3] Учётные записи пользователей"
awk -F: '$3>=1000 && $3<65534 {printf "  %s (uid=%s)\n",$1,$3}' /etc/passwd

echo "[4] Веб-сервер"
check "Служба nginx активна" "active" "$(systemctl is-active nginx)"
check "Конфигурация nginx синтаксически корректна" "0" "$(sudo nginx -t >/dev/null 2>&1; echo $?)"

# порог в днях задаётся переменной CERT_MIN_DAYS (по умолчанию 30)
CERT_MIN_DAYS="${CERT_MIN_DAYS:-30}"
check "Сертификат действует ещё не менее ${CERT_MIN_DAYS} дн." "0" \
      "$(openssl x509 -checkend $((CERT_MIN_DAYS * 86400)) -noout -in /etc/ssl/certs/devops.crt >/dev/null; echo $?)"

WORLD_WRITABLE="$(find /var/www/devops-site -perm -o+w | head -n 3 | tr '\n' ' ')"
KEY_MODE="$(sudo stat -c '%a' /etc/ssl/private/devops.key)"
check "Нет файлов ресурса с записью для всех, права ключа 600" "|600" \
      "${WORLD_WRITABLE% }|${KEY_MODE}"

echo "Пройдено: $PASS, не пройдено: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
