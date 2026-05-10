# ⚙️ LowSpec VPS Network Setup

**Скрипт безопасной оптимизации VPS с 1 vCPU / 1 GB RAM для стабильной работы:**  
`VLESS`, `Xray`, `3x-ui`, `WireGuard`, `OpenVPN`, `DNS-серверов` и любых других TCP/UDP-сервисов.

[![bash](https://img.shields.io/badge/shell-bash-green)](https://www.gnu.org/software/bash/)
[![license](https://img.shields.io/badge/license-MIT-blue)](#license)
[![vps](https://img.shields.io/badge/low-memory-orange)](#)

> 🧠 **Главная цель** – повысить стабильность сети и снизить нагрузку на память на серверах с **1 GB RAM** и **1 vCPU**. Без агрессивного тюнинга, только проверенные безопасные параметры.

---

## 📦 Для чего нужен этот скрипт?

На дешёвых или маломощных VPS (1 GB RAM, одно ядро) часто возникают:

- 📉 **packet loss** и тряска соединения  
- 🔁 **нестабильный TCP** (разрывы, таймауты)  
- 💥 **нехватка памяти** (OOM killer убивает процессы)  
- 📂 **перегруженный journald** (логи съедают место)  
- 🧩 **проблемы с conntrack** (nf_conntrack переполнен)  

Скрипт аккуратно настраивает **systemd**, **sysctl**, **swap**, **лимиты** и опционально – **MTU / offloads**.  
Он **не перезаписывает лишнего** и **не ломает существующую конфигурацию**.

---

## 🔧 Что делает скрипт (подробно)

### 1️⃣ Swap (до ~1 ГБ)

- Проверяет текущий суммарный swap (`free -m`).
- Если swap меньше **1024 МБ** – создаёт недостающий объём.
- Использует файлы `/swapfile`, `/swapfile2`… (максимум 8 файлов).
- Каждый новый файл создаётся через `fallocate` или `dd`.
- Добавляет запись в `/etc/fstab` для автоматического подключения после перезагрузки.

### 2️⃣ Network sysctl (Low‑Memory Safe)

Записывает щадящие параметры в `/etc/sysctl.d/99-lowmem-network.conf`:

| Параметр | Значение | Зачем |
|----------|----------|-------|
| `net.core.default_qdisc` | `fq` | Fair Queue – подходит для BBR |
| `net.ipv4.tcp_congestion_control` | `bbr` | Современный алгоритм контроля перегрузок |
| `net.core.rmem_default` | `262144` | Буфер приёма по умолчанию (256 КБ) |
| `net.core.wmem_default` | `262144` | Буфер отправки по умолчанию |
| `net.core.rmem_max` | `8388608` | Макс. буфер приёма (8 МБ) – экономит память |
| `net.core.wmem_max` | `8388608` | Макс. буфер отправки |
| `net.ipv4.udp_rmem_min` | `16384` | Минимальный буфер UDP для приёма |
| `net.ipv4.udp_wmem_min` | `16384` | Минимальный буфер UDP для отправки |
| `net.ipv4.udp_mem` | `4096 16384 4194304` | Лимиты памяти для UDP (low‑mem safe) |
| `net.netfilter.nf_conntrack_max` | `65536` | Максимум соединений conntrack (без переполнения) |
| `vm.swappiness` | `10` | Редко использовать своп – меньше нагрузки на диск |

После записи применяет `sysctl --system`.

### 3️⃣ BBR (TCP Bottleneck Bandwidth & RTT)

- Загружает модуль ядра `tcp_bbr` (`modprobe`).
- Если ядро **4.9+** – BBR будет активен.
- Добавляет `tcp_bbr` в `/etc/modules-load.d/bbr.conf`.
- Проверяет и принудительно включает через `sysctl -w net.ipv4.tcp_congestion_control=bbr`.

> ⚠️ На старых ядрах (< 4.9) BBR недоступен – скрипт просто выведет предупреждение.

### 4️⃣ Ограничение systemd‑journald

- Устанавливает `SystemMaxUse=50M` в `/etc/systemd/journald.conf`.
- Перезапускает `systemd-journald`.
- Журналы больше не съедят всё свободное место на диске (особенно важно для маленьких VPS с 10–20 GB SSD).

### 5️⃣ Лимиты открытых файлов (nofile)

Создаёт файл `/etc/security/limits.d/99-rikori.conf`:

```conf
* soft nofile 65536
* hard nofile 65536
