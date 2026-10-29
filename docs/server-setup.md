# Конфигурация сервера devops-vm

Хост: Windows 11, команды на хосте выполняются в Git Bash.

## 1. Параметры виртуальной машины

| Параметр | Значение |
|---|---|
| Гипервизор | Oracle VirtualBox 7.2.22 (каталог машин `D:\VirtualBox VMs`) |
| Гостевая ОС | Ubuntu Server 24.04.5 LTS (64-bit), ядро 6.8.0 |
| Имя | devops-vm |
| ОЗУ / ЦП | 2048 МБ / 2 |
| Диск | 25 ГБ, динамический VDI, разметка LVM |

## 2. Сетевые интерфейсы

| Адаптер | Тип | Интерфейс | Адрес | Назначение |
|---|---|---|---|---|
| 1 | NAT | enp0s3 | 10.0.2.15/24 | выход в Интернет, проброс портов |
| 2 | Host-only | enp0s8 | 192.168.56.101/24 | прямой доступ с хоста (хост — 192.168.56.1) |

```bash
ip -brief address
```

## 3. Проброс портов

| Имя | Протокол | Адрес хоста | Порт хоста | Порт гостя |
|---|---|---|---|---|
| ssh | TCP | 127.0.0.1 | 2222 | 2222 (до усиления защиты — 22) |

## 4. Учётные записи

| Пользователь | Группы | Аутентификация |
|---|---|---|
| student | sudo | создан установщиком; вход по SSH запрещён (AllowUsers) |
| devops | sudo | только ключ ed25519 (`~/.ssh/devops_vm` на хосте) |

```bash
sudo adduser devops
sudo usermod -aG sudo devops
# на хосте:
ssh-keygen -t ed25519 -C "devops-vm-key" -f ~/.ssh/devops_vm
ssh-copy-id -i ~/.ssh/devops_vm.pub -p 2222 devops@127.0.0.1
```

Права: `~/.ssh` — 700, `~/.ssh/authorized_keys` — 600.

Отпечаток ключа хоста (сверяется при первом подключении):
`ED25519 SHA256:6qYszRV5y3nxto+jb2kWETs8ofNalh8OqN/OO+LPoMU`.

Файл `~/.ssh/config` на хосте:

```
Host devops
    HostName 127.0.0.1
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes

Host devops.local
    HostName devops.local
    Port 2222
    User devops
    IdentityFile ~/.ssh/devops_vm
    IdentitiesOnly yes
```

## 5. Служба SSH

Основной `/etc/ssh/sshd_config` не изменялся (копия — `sshd_config.backup`). Параметры вынесены в `/etc/ssh/sshd_config.d/99-hardening.conf`:

```
Port 2222
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
AllowUsers devops
X11Forwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
```

```bash
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
# конфликтующая строка из cloud-init:
sudo sed -i 's/^PasswordAuthentication yes/#PasswordAuthentication yes/' /etc/ssh/sshd_config.d/50-cloud-init.conf
sudo sshd -t && sudo sshd -T | grep -Ei "^(port|permitrootlogin|passwordauthentication|maxauthtries|allowusers)"
# отказ от активации по сокету, иначе порт задаёт ssh.socket (22)
sudo systemctl disable --now ssh.socket
sudo systemctl enable --now ssh.service
sudo systemctl restart ssh
sudo ss -tlnp | grep sshd
```

После этого в VirtualBox правило проброса `ssh`: порт гостя 22 → 2222.

## 6. Правила межсетевого экрана

Политика: `deny (incoming)`, `allow (outgoing)`, `disabled (routed)`.

| Порт | Действие | Комментарий |
|---|---|---|
| 2222/tcp | LIMIT | SSH rate-limited |
| 80/tcp | ALLOW | HTTP |
| 443/tcp | ALLOW | HTTPS |

```bash
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw limit 2222/tcp comment 'SSH rate-limited'
sudo ufw allow 80/tcp comment 'HTTP'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw enable
sudo ufw logging medium
```

Проверка: `curl -m 3 http://192.168.56.101:8080` с хоста завершается таймаутом,
в `/var/log/ufw.log` — запись `[UFW BLOCK] IN=enp0s8 SRC=192.168.56.1 DST=192.168.56.101 PROTO=TCP DPT=8080`.

## 7. Снимки состояния

| Снимок | Состояние |
|---|---|
| 01-clean-install | чистая установка, обновления применены |
| 02-keys-configured | пользователь devops, вход по ключу |
| 03-ssh-hardened | усиленная конфигурация SSH |
| 04-nginx-https | Nginx, HTTPS, статический ресурс |
| 05-docker-compose | Docker Engine, проект `app` (приложение + СУБД) |
| 06-before-kr2 | состояние перед контрольной работой № 2 |
| 07-kr2 | проект `kr2` (приложение + Redis), ресурс `notes.devops.local` |

## 8. Веб-сервер

| Параметр | Значение |
|---|---|
| Пакет | `nginx` 1.24.0 (Ubuntu), служба `nginx` включена в автозагрузку |
| Процессы | главный — `root`, рабочие — `www-data` |
| Конфигурация ресурса | `/etc/nginx/sites-available/devops-site`, ссылка в `sites-enabled/`; ссылка `sites-enabled/default` удалена |
| Каталог ресурса | `/var/www/devops-site`, владелец `devops:devops`, каталоги `755`, файлы `644` |
| Сертификат | `/etc/ssl/certs/devops.crt`, `root:root`, `644`, самоподписанный, CN и SAN `devops.local` |
| Закрытый ключ | `/etc/ssl/private/devops.key`, `root:root`, `600`, RSA 2048 |
| Срок действия | 365 дней (выпущен 28.10.2026, действует до 28.10.2027) |
| Журналы | `/var/log/nginx/devops-site.access.log`, `/var/log/nginx/devops-site.error.log` |

```bash
sudo apt install -y nginx
sudo mkdir -p /var/www/devops-site
sudo chown -R devops:devops /var/www/devops-site

sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/devops.key \
  -out /etc/ssl/certs/devops.crt \
  -subj "/CN=devops.local" \
  -addext "subjectAltName=DNS:devops.local"

sudo ln -s /etc/nginx/sites-available/devops-site /etc/nginx/sites-enabled/
sudo rm /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

Файл `/etc/nginx/sites-available/devops-site`:

```nginx
server {
    listen 80;
    listen [::]:80;
    server_name devops.local;

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;

    server_name devops.local;

    ssl_certificate     /etc/ssl/certs/devops.crt;
    ssl_certificate_key /etc/ssl/private/devops.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

    root /var/www/devops-site;
    index index.html;

    location / {
        try_files $uri $uri/ =404;
    }

    error_page 404 /404.html;

    access_log /var/log/nginx/devops-site.access.log;
    error_log  /var/log/nginx/devops-site.error.log;
}
```

Порты 80 и 443 открыты правилами раздела 6, профили `Nginx *` в UFW не используются.
Заголовок HSTS не добавляется: сертификат самоподписанный.

Доставка содержимого — `scripts/deploy.sh` (rsync с `--delete --chmod=D755,F644`) из каталога `site/` репозитория.
На хосте Windows сценарий запускается в WSL версии 1 (WSL 2 включает Hyper-V, см. раздел «Затруднения»);
в WSL скопированы `~/.ssh/devops_vm` и `~/.ssh/config` (права `600`), сертификат получен по SSH:

```bash
scp devops:/etc/ssl/certs/devops.crt ~/devops.crt
curl --cacert ~/devops.crt -I https://devops.local    # 200 OK
```

## 9. Контейнеризация

| Параметр | Значение |
|---|---|
| Docker Engine | 29.9.2 (`docker-ce`), официальный репозиторий `download.docker.com`; пакет `docker.io` не установлен |
| Плагины | Compose v5.6.1 (`docker-compose-plugin`), Buildx; containerd 2.4.2 |
| Группа `docker` | только `devops` (имеет право sudo; участник группы фактически получает права root) |
| Проект на сервере | `/home/devops/app` (имя проекта Compose — `app`), источник — каталог `app/` репозитория |
| Файл `.env` | `/home/devops/app/.env`, владелец `devops`, права `600`, создаётся только на сервере из `.env.example`, пароль — `openssl rand -hex 16` |
| Образ приложения | `devops-app:1.0` на `python:3.12-slim`, процесс `gunicorn` от пользователя `app` (uid 999) |
| СУБД | `postgres:16-alpine`, проверка готовности `pg_isready`, приложение запускается после `service_healthy` |
| Сеть | пользовательская сеть `app_backend` (bridge), СУБД доступна приложению по имени `db` |
| Публикуемые порты | `127.0.0.1:5000` → `app:5000`; порт 5432 не публикуется |
| Именованные тома | `app_db_data` → `/var/lib/postgresql/data` |
| Перезапуск | `restart: unless-stopped` для обоих сервисов |

Установка Docker Engine:

```bash
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y $pkg
done
sudo apt-get update
sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker devops    # затем новая SSH-сессия
```

Доставка и запуск проекта:

```bash
# на хосте (WSL), из корня репозитория
rsync -avz --delete --exclude=.env --chmod=D755,F644 app/ devops:app/
# на сервере, один раз
cd ~/app
cp .env.example .env
chmod 600 .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 16)/" .env
# запуск и обновление
docker compose up -d --build
docker compose ps
```

`--exclude=.env` обязателен: без него `--delete` удалит файл `.env` на сервере.
`--chmod=D755,F644` нужен из-за WSL: файлы на диске `D:` видны в WSL с правами `777`, и `COPY` перенёс бы их в образ доступными на запись пользователю `app`.
`docker compose down -v` удаляет том `app_db_data` вместе с базой данных, на рабочем сервере не используется.

Обратный прокси-сервер: в блок HTTPS файла `/etc/nginx/sites-available/devops-site` перед `error_page` добавлено расположение
(копия файла до изменения — `/root/devops-site.before-app`):

```nginx
    location /app/ {
        proxy_pass http://127.0.0.1:5000/;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
```

```bash
sudo nginx -t && sudo systemctl reload nginx
curl --cacert ~/devops.crt https://devops.local/app/         # Hello from Docker, ... Visits: N
curl --cacert ~/devops.crt -I https://devops.local/          # статический ресурс, 200 OK
```

Порт, опубликованный на `0.0.0.0` (`-p 5001:5000`), доступен из сети в обход UFW: Docker добавляет правило DNAT в цепочку `DOCKER` таблицы `nat`,
и пакет перенаправляется до правил UFW. Поэтому приложение публикуется только на `127.0.0.1`, а наружу доступно через Nginx по HTTPS.

## 10. Локальное доменное имя

На хосте (`C:\Windows\System32\drivers\etc\hosts`, PowerShell от имени администратора):

```powershell
Add-Content -Path C:\Windows\System32\drivers\etc\hosts -Value "192.168.56.101    devops.local"
ipconfig /flushdns
```

На сервере:

```bash
sudo hostnamectl set-hostname devops-vm
sudo sed -i 's/^127.0.1.1.*/127.0.1.1 devops-vm.devops.local devops-vm/' /etc/hosts
hostname -f   # devops-vm.devops.local
```

## 11. Контрольная работа № 2 (вариант 2)

| Параметр | Значение |
|---|---|
| Репозиторий | `devops-kr2` (шаблон `kr2-template`), ветка `kr2/variant-2` |
| Проект на сервере | `/home/devops/kr2` (имя проекта Compose — `kr2`), доставка `rsync --exclude=.env --exclude=.git --chmod=D755,F644` |
| Сервисы | `app` (образ `kr2-app:1.0`, uid 999) и `redis` (`redis:7-alpine`, пароль, AOF, пользователь `redis`) |
| Файл `.env` | `/home/devops/kr2/.env`, права `600`, `REDIS_PASSWORD` — `openssl rand -hex 32` |
| Сеть и том | `kr2_backend`, `kr2_redis_data` → `/data` |
| Публикация | `127.0.0.1:8002`; порт 6379 не публикуется |
| Ресурс Nginx | `/etc/nginx/sites-available/kr2`, ссылка в `sites-enabled/`, имя `notes.devops.local` |
| Сертификат | `/etc/ssl/certs/kr2.crt` (CN и SAN `notes.devops.local`, 365 дней), ключ `/etc/ssl/private/kr2.key`, `root`, `600` |
| Журналы | `/var/log/nginx/kr2.access.log`, `/var/log/nginx/kr2.error.log` |

```bash
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/private/kr2.key -out /etc/ssl/certs/kr2.crt \
  -subj "/CN=notes.devops.local" -addext "subjectAltName=DNS:notes.devops.local"
sudo chmod 600 /etc/ssl/private/kr2.key
sudo ln -s /etc/nginx/sites-available/kr2 /etc/nginx/sites-enabled/kr2
sudo nginx -t && sudo systemctl reload nginx
```

На хосте в `hosts` добавлена запись `192.168.56.101    notes.devops.local`. Правила UFW не менялись.

## Проверка

```bash
scp scripts/audit.sh devops:~/
ssh devops
bash ~/audit.sh; echo "Код возврата: $?"
```

На корректной конфигурации: `Пройдено: 19, не пройдено: 0`, код возврата 0.
При `MaxAuthTries 10` проверка MaxAuthTries даёт `[FAIL]`, код возврата 1.
Проверка срока сертификата с завышенным порогом: `CERT_MIN_DAYS=400 bash ~/audit.sh` — код возврата 1.
При публикации `"5000:5000"` в `docker-compose.yml` проверка портов даёт `[FAIL]` (`0.0.0.0:5000 [::]:5000`), код возврата 1.

## Затруднения при развёртывании

- VirtualBox 7.2 не устанавливается в корень диска (`D:\`) — программа установлена в `C:\Program Files`, машины хранятся на `D:`.
- Пока работал гипервизор Windows (целостность памяти / VBS), VirtualBox работал в режиме `native API` и установщик Ubuntu зависал — выполнено `bcdedit /set hypervisorlaunchtype off`, отключена целостность памяти.
- `wsl --install` включил компонент «Платформа виртуальных машин», и VirtualBox снова перешёл в режим `NEM` — компоненты `VirtualMachinePlatform` и `HypervisorPlatform` отключены через `dism /disable-feature`, повторно выполнено `bcdedit /set hypervisorlaunchtype off`; WSL версии 1 работает без них.
- Сохранённое состояние ВМ после изменения компонентов Windows не загружается (`VERR_SSM_LOAD_CONFIG_MISMATCH`) — состояние сброшено, машину выключать командой `sudo poweroff`.
- Git в WSL считал все файлы изменёнными из-за CRLF рабочей копии Windows — в репозитории задано `core.autocrlf true` (вместе с `core.fileMode false`).
- Файлы рабочей копии на диске `D:` в WSL имеют права `777`, и `rsync -a` переносил их на сервер без изменений — доставка каталога `app/` выполняется с `--chmod=D755,F644`.
- Первый запрос к контейнеру сразу после `docker run -d` завершался `Connection reset by peer`: `gunicorn` ещё не успевал начать приём соединений — проверка выполняется после паузы в несколько секунд.
