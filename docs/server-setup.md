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

## 8. Локальное доменное имя

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

## Проверка

```bash
scp scripts/audit.sh devops:~/
ssh devops
bash ~/audit.sh; echo "Код возврата: $?"
```

На корректной конфигурации: `Пройдено: 6, не пройдено: 0`, код возврата 0.
При `MaxAuthTries 10` проверка MaxAuthTries даёт `[FAIL]`, код возврата 1.

## Затруднения при развёртывании

- VirtualBox 7.2 не устанавливается в корень диска (`D:\`) — программа установлена в `C:\Program Files`, машины хранятся на `D:`.
- Пока работал гипервизор Windows (целостность памяти / VBS), VirtualBox работал в режиме `native API` и установщик Ubuntu зависал — выполнено `bcdedit /set hypervisorlaunchtype off`, отключена целостность памяти.
