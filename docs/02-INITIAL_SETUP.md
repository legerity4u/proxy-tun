# Initial setup after flashing custom firmware

Что делать сразу после прошивки кастомной сборки OpenWrt на роутер.

> **Предусловие:** роутер перезагрузился после `sysupgrade`, подключён кабелем
> **напрямую к ПК**, доступен по `192.168.1.1`, пароль root пустой.
>
> **Порядок разделов важен:** раздел 4 (установка пакетов) нельзя выполнить,
> пока не выполнен раздел 3 — настройка сети и переключение роутера с прямого
> подключения к ПК на вышестоящий роутер (ПК при этом возвращается на DHCP).

---

## 1. Первый вход

```bash
ssh root@192.168.1.1

# Сменить пароль
passwd
```

---

## 2. USB-флешка: разметка, overlay, swap

Выносим overlay на USB на обоих роутерах — единообразно, с swap для стабильности sing-box.

### 2.1. Проверить что флешка определилась

```bash
cat /proc/partitions | grep sda
# или
ls -la /dev/sd*

# Информация о флешке
dmesg | tail -20
```

### 2.2. Создание разделов

Два раздела:
- `sda2` — swap (Linux swap, +256 МБ)
- `sda1` — overlay (ext4, всё остальное)

> ⚠️ Все данные на флешке будут удалены.

```bash
fdisk /dev/sda
```

Последовательность команд в fdisk:

| Команда | Что делает |
|---------|------------|
| `p` | Посмотреть текущую таблицу разделов |
| `d` (повторить если несколько) | Удалить существующие разделы |
| `n` → `p` → `2` → Enter → `+256M` | Создать sda2 (swap, 256 МБ) |
| `t` → `2` → `82` | Тип раздела sda2: Linux swap |
| `n` → `p` → `1` → Enter → Enter | Создать sda1 (overlay, остальное место) |
| `t` → `1` → `83` | Тип раздела sda1: Linux (ext4) |
| `w` | Записать таблицу и выйти |

Проверить:

```bash
fdisk -l /dev/sda
```

### 2.3. Форматирование

```bash
# overlay
mkfs.ext4 /dev/sda1

# swap
mkswap /dev/sda2
```

### 2.4. Настройка fstab

Удалить старую конфигурацию и сгенерировать новую:

```bash
rm /etc/fstab
block detect >> /etc/fstab
```

Настроить через UCI:

```bash
# Удалить старые секции (если есть)
uci delete fstab.@mount[0] 2>/dev/null
uci delete fstab.@swap[0] 2>/dev/null

# Секция mount для overlay
uci add fstab mount
uci set fstab.@mount[-1].target='/overlay'
uci set fstab.@mount[-1].device='/dev/sda1'
uci set fstab.@mount[-1].fstype='ext4'
uci set fstab.@mount[-1].enabled='1'
uci set fstab.@global[0].auto_mount='1'

# Секция swap
uci add fstab swap
uci set fstab.@swap[-1].device='/dev/sda2'
uci set fstab.@swap[-1].enabled='1'
uci set fstab.@global[0].auto_swap='1'

# Сохранить
uci commit fstab
/etc/init.d/fstab restart
```

Проверить:

```bash
uci show fstab
# или
cat /etc/config/fstab
```

### 2.5. Копирование overlay на USB

```bash
# Создать точку монтирования
mkdir -p /mnt/sda1

# Примонтировать sda1
mount /dev/sda1 /mnt/sda1

# Скопировать текущий overlay
tar -C /overlay -cvf - . | tar -C /mnt/sda1 -xf -
```

### 2.6. Перезагрузка и проверка

```bash
reboot
```

После перезагрузки:

```bash
df -h /overlay
# Ожидаемый результат: overlay на /dev/sda1, > 700 MB свободно

free -h
# Swap: не 0

cat /proc/swaps
# /dev/sda2 — активен
```

---

## 3. Настройка сети после прошивки (VLAN, WAN, DHCP, firewall, WiFi)

Первичная настройка сети сразу после прошивки. Единственный Ethernet-порт
MR3020 разведён на два VLAN: LAN (`eth0.1`, мост `br-lan`) и WAN (`eth0.2`, DHCP).

> ⚠️ **Без этого раздела дальше не пройти:** пока сеть не настроена и роутер
> физически не переключён с прямого подключения к ПК на вышестоящий роутер
> (а ПК не возвращён на DHCP) — интернета у роутера нет, и `apk` из раздела 4
> работать не будет.

### 3.1. Очистка старых VLAN-секций (на всякий случай)

```bash
uci delete network.@switch_vlan[0] 2>/dev/null
uci delete network.@switch_vlan[1] 2>/dev/null
```

### 3.2. Коммутатор (VLAN)

```bash
uci set network.@switch[0]=switch
uci set network.@switch[0].name='switch0'
uci set network.@switch[0].reset='1'
uci set network.@switch[0].enable_vlan='1'

# VLAN 1 (LAN) — порт 0 без тега, CPU с тегом
uci add network switch_vlan
uci set network.@switch_vlan[-1].device='switch0'
uci set network.@switch_vlan[-1].vlan='1'
uci set network.@switch_vlan[-1].ports='0 6t'
uci set network.@switch_vlan[-1].description='LAN'

# VLAN 2 (WAN) — тот же порт 0 + CPU
uci add network switch_vlan
uci set network.@switch_vlan[-1].device='switch0'
uci set network.@switch_vlan[-1].vlan='2'
uci set network.@switch_vlan[-1].ports='0 6t'
uci set network.@switch_vlan[-1].description='WAN'
```

### 3.3. Мост и интерфейсы

```bash
uci set network.@device[0]=device
uci set network.@device[0].name='br-lan'
uci set network.@device[0].type='bridge'
uci set network.@device[0].ports='eth0.1'

uci set network.lan=interface
uci set network.lan.device='br-lan'
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.1.1'
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.ip6assign='60'

uci set network.wan=interface
uci set network.wan.device='eth0.2'
uci set network.wan.proto='dhcp'
```

### 3.4. DHCP

```bash
uci set dhcp.lan=dhcp
uci set dhcp.lan.interface='lan'
uci set dhcp.lan.start='100'
uci set dhcp.lan.limit='150'
uci set dhcp.lan.leasetime='12h'
uci set dhcp.lan.dhcpv4='server'

uci set dhcp.wan=dhcp
uci set dhcp.wan.interface='wan'
uci set dhcp.wan.ignore='1'
```

### 3.5. Firewall

Базовые зоны + разрешение SSH и пинга из WAN (SSH нужен, чтобы заходить
с ПК после переключения роутера к вышестоящему роутеру, напр. с `192.168.0.x`):

```bash
uci set firewall.@defaults[0]=defaults
uci set firewall.@defaults[0].input='REJECT'
uci set firewall.@defaults[0].output='ACCEPT'
uci set firewall.@defaults[0].forward='REJECT'
uci set firewall.@defaults[0].synflood_protect='1'

uci set firewall.@zone[0]=zone
uci set firewall.@zone[0].name='lan'
uci set firewall.@zone[0].network='lan'
uci set firewall.@zone[0].input='ACCEPT'
uci set firewall.@zone[0].output='ACCEPT'
uci set firewall.@zone[0].forward='ACCEPT'

uci set firewall.@zone[1]=zone
uci set firewall.@zone[1].name='wan'
uci set firewall.@zone[1].network='wan'
uci set firewall.@zone[1].input='REJECT'
uci set firewall.@zone[1].output='ACCEPT'
uci set firewall.@zone[1].forward='REJECT'
uci set firewall.@zone[1].masq='1'
uci set firewall.@zone[1].mtu_fix='1'

uci set firewall.@forwarding[0]=forwarding
uci set firewall.@forwarding[0].src='lan'
uci set firewall.@forwarding[0].dest='wan'

# Разрешить SSH из WAN (чтобы заходить с 192.168.0.x)
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-SSH-WAN'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].dest_port='22'
uci set firewall.@rule[-1].target='ACCEPT'

# Разрешить пинг из WAN (опционально)
uci add firewall rule
uci set firewall.@rule[-1].name='Allow-Ping-WAN'
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='icmp'
uci set firewall.@rule[-1].icmp_type='echo-request'
uci set firewall.@rule[-1].target='ACCEPT'
```

### 3.6. WiFi (2.4 GHz)

SSID, пароль и тип шифрования — единые для обеих площадок для удобства.
Реальные значения — в `private/AGENTS.local.md`.

```bash
uci delete wireless.radio0 2>/dev/null
uci delete wireless.default_radio0 2>/dev/null

uci set wireless.radio0=wifi-device
uci set wireless.radio0.type='mac80211'
uci set wireless.radio0.path='platform/10300000.wmac'
uci set wireless.radio0.band='2g'
uci set wireless.radio0.channel='1'
uci set wireless.radio0.htmode='HT20'
uci set wireless.radio0.cell_density='0'
uci set wireless.radio0.disabled='0'

uci set wireless.default_radio0=wifi-iface
uci set wireless.default_radio0.device='radio0'
uci set wireless.default_radio0.network='lan'
uci set wireless.default_radio0.mode='ap'
uci set wireless.default_radio0.ssid='<wifi-ssid>'
uci set wireless.default_radio0.encryption='sae-mixed'
uci set wireless.default_radio0.key='<wifi-password>'
uci set wireless.default_radio0.ocv='0'
```

Если роутер двухдиапазонный (Asus RT-AC1200), дополнительно настраивается radio1 (5 GHz):

```bash
uci set wireless.default_radio1.ssid='<wifi-ssid-5ghz>'
uci set wireless.default_radio1.encryption='sae-mixed'
uci set wireless.default_radio1.key='<wifi-password>'
uci set wireless.radio1.disabled='0'
uci set wireless.default_radio1.disabled='0'
```

> Коммит всех секций — один раз, в разделе 3.7 (`uci commit`).

### 3.7. Применение и переключение кабелей

```bash
uci commit
/etc/init.d/network restart
```

Затем физически:

1. Переключить роутер с прямого подключения к ПК на вышестоящий роутер (хаб) —
   WAN (`eth0.2`) получит адрес по DHCP.
2. Вернуть ПК на получение настроек по DHCP (в сети вышестоящего роутера).

После восстановления доступа по SSH (WAN-адрес роутера):

```bash
# Эти службы после восстановления доступа можно перезапустить
/etc/init.d/firewall restart
/etc/init.d/dnsmasq restart
wifi reload
```

### 3.8. Проверка после переключения

```bash
# На роутере — WAN получил адрес от вышестоящего
ip -4 addr show eth0.2
# → inet 192.168.0.x/24 (подсеть вышестоящего роутера)

# С ПК — SSH по WAN-адресу работает (правило Allow-SSH-WAN из 3.5)
ssh -o StrictHostKeyChecking=accept-new root@<ROUTER_IP> "echo OK"
# → OK
```

---

## 4. Установка post-flash пакетов

> ⚠️ Выполнять **только после раздела 3**: сеть настроена, роутер подключён
> к вышестоящему роутеру, ПК снова на DHCP.

Теперь, когда overlay на USB и сеть настроена, можно ставить пакеты:

```bash
apk update
apk add bash coreutils-base64 grep jq curl nano-full tcpdump conntrack
```

> - `grep` — полноценный GNU grep (3.12): пакет подменяет busybox-симлинк
>   `/bin/grep` → `/usr/libexec/grep-gnu`. Нужен для диагностики агентом
>   на роутере — busybox-версия урезана (нет `-o`, `-P`, контекстов).
> - `tcpdump` — полный вариант (в репо есть ещё урезанный `tcpdump-mini`)
>   — захват пакетов для диагностики.
> - `conntrack` — просмотр таблицы соединений ядра (TROUBLESHOOTING.md,
>   сценарий Д2 «Ajax Hub»).

**sing-box** — отдельным шагом (версию и способ установки — из репо или ручной
заменой бинарника — обсуждают перед установкой, см. [03-DEPLOY.md → Шаг 1](03-DEPLOY.md#шаг-1-установка-sing-box) и [Приложение C](03-DEPLOY.md#приложение-c-ручное-обновление-sing-box-когда-opkg-отстаёт)):

```bash
apk add sing-box
```

> ⚠️ **apk атомарен:** если хотя бы один пакет из списка не найден, не
> устанавливается ни один. Проверено 2026-09-11 (MR3020): пакета `time` в
> репозитории OpenWrt 25.12 **не существует** — строка `apk add ... time ...`
> падала целиком: `ERROR: unable to select packages: time (no such package)`,
> и sing-box из неё тоже не ставился.
>
> Отдельный пакет `time` не нужен, утилита уже есть:
> - `/usr/bin/time` — симлинк на busybox (applet вшит в базовую прошивку);
> - в bash, кроме того, `time` — встроенное ключевое слово
>   (`time sing-box check` работает и без бинарника).

---

## 5. Часовой пояс, локаль и bash

### 5.1. Часовой пояс

```bash
uci set system.@system[0].timezone='MSK-3'
uci set system.@system[0].zonename='Europe/Moscow'
uci commit system
```

### 5.2. Локаль

Проверить текущие значения:

```bash
echo "LANG=$LANG"
echo "LC_ALL=$LC_ALL"
echo "LC_CTYPE=$LC_CTYPE"
env | grep -E 'LANG|LC_'
```

Чтобы SSH-сессии поднимались с локалью автоматически:

```bash
cat >> /etc/profile << 'PROFILEEOF'
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
export LC_CTYPE=en_US.UTF-8
export HISTSIZE=10000
PROFILEEOF
```

Проверка: перелогиниться по SSH и `echo $LANG` — должно вывести `en_US.UTF-8`.

### 5.3. Bash вместо ash

```bash
apk add bash        # раздел 4 уже ставит bash — команда идемпотентна
bash --version      # проверить версию bash
which bash          # проверить путь к bash
```

Для текущего пользователя (у нас только root) меняем оболочку с ash на bash:

```bash
sed -i 's|/bin/ash|/bin/bash|g' /etc/passwd

# Если нужно вернуться с bash на ash:
# sed -i 's|/bin/bash|/bin/ash|g' /etc/passwd
```

Создать `~/.bashrc` — выполняется при каждом запуске bash:

```bash
cat > ~/.bashrc << 'EOF'
# Если запущен интерактивный shell
if [ -n "$PS1" ]; then
    # Цветной prompt
    PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
    
    # Настройки истории
    HISTSIZE=10000
    HISTFILESIZE=20000
    HISTCONTROL=ignoreboth:erasedups
    HISTTIMEFORMAT="%d.%m.%Y %H:%M:%S "
    shopt -s histappend
    
    # Сохранять историю после каждой команды
    PROMPT_COMMAND="history -a;$PROMPT_COMMAND"
    
    # Алиасы
    alias ll='ls -la'
    alias l='ls -CF'
    alias ..='cd ..'
    alias ...='cd ../..'
    alias grep='grep --color=auto'
    alias h='history'
    alias hg='history | grep'
    
    # Цветной ls
    if [ -x /usr/bin/dircolors ]; then
        eval "$(dircolors -b)"
        alias ls='ls --color=auto'
    fi
fi
EOF
```

Создать `~/.bash_profile` — выполняется при логине (делает bash оболочкой по умолчанию с загрузкой `.bashrc`):

```bash
cat > ~/.bash_profile << 'EOF'
# Если существует .bashrc, загрузить его
if [ -f ~/.bashrc ]; then
    . ~/.bashrc
fi
# Дополнительные настройки для логина
echo "Добро пожаловать в bash на OpenWRT!"
echo "Текущая дата: $(date)"
EOF
```

Перенести историю команд из ash в bash:

```bash
cat ~/.ash_history >> ~/.bash_history 2>/dev/null
```

---

## 6. SSH-ключ

> **Важно:** WAN-адрес роутер получает по DHCP от вышестоящего роутера (провайдер / домашний маршрутизатор). ПК с opencode находится в той же сети (напр. `192.168.0.0/24`). Чтобы WAN-адрес роутера не менялся и SSH-доступ не терялся — назначь **статическую аренду DHCP (reservation)** на вышестоящем роутере для MAC-адреса WAN-интерфейса нашего роутера.

Сгенерировать ключ на ПК (если ещё нет):

```bash
ssh-keygen -t rsa -b 4096 -C "ai-agent"
```

Скопировать на роутер:

```bash
# Ubuntu / Linux — ssh-copy-id
ssh-copy-id -i ~/.ssh/id_rsa.pub root@<ROUTER_IP>

# Windows / если ssh-copy-id не работает — вставить ключ вручную:
# cat ~/.ssh/id_rsa.pub | ssh root@192.168.1.1 "cat > /etc/dropbear/authorized_keys"
# Или на роутере:
# echo "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQ... (полный ключ)" > /etc/dropbear/authorized_keys

chmod 600 /etc/dropbear/authorized_keys
/etc/init.d/dropbear restart
```

Проверить:

```bash
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 root@<ROUTER_IP> "echo OK"
# Должно вернуть: OK
```

---

## 7. Проверка перед деплоем VPN

```bash
# WAN поднят
ip -4 addr show eth0.2
# → должен быть IP провайдера (напр. 192.168.0.3/24)

ping -c 3 1.1.1.1
# → должен работать

# DNS работает
nslookup youtube.com
# → должен вернуть IP

# Подписка доступна
curl -sS --max-time 10 "https://connliberty.com/" -o /dev/null -w 'HTTP %{http_code}\n'
# → если 000/timeout — см. TROUBLESHOOTING.md
```

---

## Дальше

- **[03-DEPLOY.md](03-DEPLOY.md)** — деплой VPN
- **[../README.md](../README.md)** — обзор архитектуры
- **[TROUBLESHOOTING.md](TROUBLESHOOTING.md)** — диагностика
