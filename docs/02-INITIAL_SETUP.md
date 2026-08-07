# Initial setup after flashing custom firmware

Что делать сразу после прошивки кастомной сборки OpenWrt на роутер.

> **Предусловие:** роутер перезагрузился после `sysupgrade`, доступен по
> `192.168.1.1`, пароль root пустой.

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

## 3. Установка post-flash пакетов

Теперь, когда overlay на USB, можно ставить пакеты:

```bash
apk update
apk add bash coreutils-base64 jq curl nano-full time sing-box
```

---

## 4. Часовой пояс

```bash
uci set system.@system[0].timezone='MSK-3'
uci set system.@system[0].zonename='Europe/Moscow'
uci commit system
```

---

## 5. Firewall: SSH через WAN (для доступа снаружи)

Если роутер получает WAN-адрес по DHCP (например, за провайдерским роутером), открываем SSH с WAN-стороны:

```bash
uci set firewall.wan_ssh=rule
uci set firewall.wan_ssh.name='Allow-SSH-WAN'
uci set firewall.wan_ssh.src='wan'
uci set firewall.wan_ssh.proto='tcp'
uci set firewall.wan_ssh.dest_port='22'
uci set firewall.wan_ssh.target='ACCEPT'
uci commit firewall
/etc/init.d/firewall reload
```

**Проверка:**
```bash
uci show firewall.wan_ssh
# → firewall.wan_ssh.name='Allow-SSH-WAN'
# → firewall.wan_ssh.src='wan'
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

## 7. WiFi

SSID, пароль и тип шифрования — единые для обеих площадок для удобства. Реальные значения — в `private/AGENTS.local.md`.

### 7.1. MR3020 — один диапазон 2.4 GHz

```bash
uci set wireless.default_radio0.ssid='<wifi-ssid>'
uci set wireless.default_radio0.encryption='sae-mixed'
uci set wireless.default_radio0.key='<wifi-password>'
uci set wireless.radio0.disabled='0'
uci set wireless.default_radio0.disabled='0'

uci commit wireless
wifi reload
```

### 7.2. ASUS RT-AC1200 — два диапазона

```bash
# 2.4 GHz
uci set wireless.default_radio0.ssid='<wifi-ssid>'
uci set wireless.default_radio0.encryption='sae-mixed'
uci set wireless.default_radio0.key='<wifi-password>'
uci set wireless.radio0.disabled='0'
uci set wireless.default_radio0.disabled='0'

# 5 GHz
uci set wireless.default_radio1.ssid='<wifi-ssid-5ghz>'
uci set wireless.default_radio1.encryption='sae-mixed'
uci set wireless.default_radio1.key='<wifi-password>'
uci set wireless.radio1.disabled='0'
uci set wireless.default_radio1.disabled='0'

uci commit wireless
wifi reload
```

---

## 8. Проверка перед деплоем VPN

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
