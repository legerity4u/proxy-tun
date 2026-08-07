# Custom firmware build for OpenWrt (ramips/mt76x8)

Пошаговая инструкция для сборки кастомной прошивки OpenWrt 25.12.5.
Поддерживаемые роутеры: **TP-Link MR3020 v3** и **ASUS RT-AC1200**.

---

## Переменные модели

| Параметр | `PLACEHOLDER` | MR3020 v3 | ASUS RT-AC1200 |
|---|---|---|---|
| Target Profile | `$PROFILE` | `tplink_tl-mr3020-v3` | `asus_rt-ac1200` |
| Директория сборки | `$BUILD_DIR` | `~/openwrt/tplink` | `~/openwrt/asus` |
| IP роутера после прошивки | `$ROUTER_IP` | `192.168.0.x` (см. `private/`) | `192.168.10.x` (см. `private/`) |
| Файл прошивки | `$FW_FILE` | `openwrt-ramips-mt76x8-tplink_tl-mr3020-v3-squashfs-sysupgrade.bin` | `openwrt-ramips-mt76x8-asus_rt-ac1200-squashfs-sysupgrade.bin` |

---

## 1. Подготовка среды сборки

Сборка делается на Ubuntu (нативная или WSL2). Тестировалось на Ubuntu 26.04 LTS.

```bash
sudo apt update && sudo apt install -y \
    build-essential flex bison gawk gettext git git-core \
    libncurses5-dev libssl-dev zlib1g-dev unzip python3 \
    python3-pip rsync subversion wget file libelf-dev clang \
    g++ gcc-multilib g++-multilib
```

## 2. Клонирование и обновление фидов

```bash
git clone -b v25.12.5 --depth 1 https://git.openwrt.org/openwrt/openwrt.git $BUILD_DIR
cd $BUILD_DIR
./scripts/feeds update -a
./scripts/feeds install -a
```

Для двух роутеров — клонировать в `~/openwrt/tplink` и `~/openwrt/asus`, обновить фиды в каждой.

## 3. Конфигурация (.config)

> Если планируется сборка для нескольких роутеров — вынеси `dl/` в общую папку,
> чтобы скачать исходники один раз (~500 MB экономии):
> ```bash
> mkdir -p ~/openwrt/dl && ln -sfn ~/openwrt/dl dl
> ```

```bash
# Базовый конфиг для mt76x8 (не snapshot)
wget -O .config https://downloads.openwrt.org/releases/25.12.5/targets/ramips/mt76x8/config.buildinfo
wget -O feeds.conf.default https://downloads.openwrt.org/releases/25.12.5/targets/ramips/mt76x8/feeds.buildinfo

make menuconfig
```

### Обязательные настройки в menuconfig

| Раздел | Настройка | Причина |
|---|---|---|
| `Target System` | `MediaTek Ralink MIPS` | ramips |
| `Subtarget` | `MT76x8` | mt76x8 |
| `Target Profile` | **`$PROFILE`** | Модель роутера |
| `Target Images` | `[*] squashfs`, `[ ] ramdisk` | Только squashfs |
| `Global build → Kernel build options` | `[*] Support for paging of anonymous memory (swap)` | Иначе OOM на 64 MB |
| `Kernel modules → USB Support` | `kmod-usb-core`, `kmod-usb2`, `kmod-usb-ohci`, `kmod-usb-ehci`, `kmod-usb-storage` | USB overlay |
| `Kernel modules → Filesystems` | `kmod-fs-ext4` | ext4 на флешке |
| `Kernel modules → Network Support` | `kmod-tun` | TUN для sing-box |
| `Kernel modules → Netfilter Extensions` | `kmod-nft-tproxy`, `kmod-nft-socket`, `kmod-nft-nat` | nftables + transparent proxy |
| `Base system` | `block-mount`, `blockd`, `e2fsprogs`, `swap-utils`, `fstools` | Разметка и overlay |
| `Utilities → Disc` | `fdisk` | Разметка USB |

### Экономия места (опционально, зависит от свободного места на flash)

| Раздел | Что отключить / заменить | Экономия |
|---|---|---|
| `LuCI` | Весь раздел | ~1.5–2 MB |
| `Libraries → SSL` | `libustream-mbedtls` вместо `libustream-openssl` | ~0.5 MB |
| `Network → Web Servers` | `uhttpd` | ~0.2 MB |
| `Network → VPN` | `ppp`, `ppp-mod-pppoe` | ~0.2 MB |
| `Kernel modules → IPv6` | `kmod-ip6tables`, `kmod-ip6tables-extra` | ~0.1 MB |
| `Base system` | `dnsmasq` вместо `dnsmasq-full` (если без IPv6) | ~0.1 MB |

После всех правок:

```bash
make defconfig
```

## 4. Сборка

```bash
make download          # скачать исходники (один раз, если dl/ общая)
make -j$(nproc) V=s    # сборка (20–40 мин первая, 5–15 мин последующие)
```

Готовый образ:

```bash
ls -lh $BUILD_DIR/bin/targets/ramips/mt76x8/$FW_FILE
# → squashfs-sysupgrade.bin, ~4–7 MB
```

## 5. Прошивка

Предварительно (если меняли роутер):

```bash
ssh-keygen -f "$HOME/.ssh/known_hosts" -R '$ROUTER_IP'
```

Копирование и прошивка:

```bash
ROUTER="root@$ROUTER_IP"
FW_FILE="$BUILD_DIR/bin/targets/ramips/mt76x8/$FW_FILE"

scp -O "$FW_FILE" "$ROUTER:/tmp/"         # или cat … | ssh … cat
ssh "$ROUTER" "sysupgrade -n /tmp/$FW_FILE"
```

После перезагрузки — `ssh root@192.168.1.1` (дефолтный пароль пустой).

**Stock → OpenWrt:** см. OpenWrt Wiki для модели — TFTP recovery или WebUI.

## 6. Дальше

> **[02-INITIAL_SETUP.md](02-INITIAL_SETUP.md)** — первый вход, USB overlay, пакеты, SSH.

Кратко:
1. `ssh root@192.168.1.1`, `passwd`
2. Разметить USB (sda2 swap +256M, sda1 overlay ext4)
3. Настроить fstab, скопировать overlay, перезагрузить
4. `apk add bash coreutils-base64 jq curl nano-full time sing-box`
5. Часовой пояс, SSH-ключ
6. **[03-DEPLOY.md](03-DEPLOY.md)** — VPN
