#!/usr/bin/env bash
set -euo pipefail
# lowspec_setup.sh — безопасная настройка для VPS 1 vCPU / 1 GB
# Что делает:
# - добавляет swap до ~1G (если нужно)
# - пишет щадящие sysctl для TCP/UDP/BBR/qdisc (low memory safe)
# - пытается включить BBR (если ядро поддерживает)
# - ограничивает системный журнал (journald)
# - добавляет лимит nofile
# - опционально: можно включить изменение MTU и отключение offloads (по флагам)
# Рекомендация: перезагрузить сервер после выполнения для полной стабильности.

# CONFIG
DESIRED_TOTAL_SWAP_MB=1024    # желаемый суммарный swap в МБ (1G)
SWAPFILE_PREFIX="/swapfile"   # имена: /swapfile, /swapfile2, ...
SYSCTL_CONF="/etc/sysctl.d/99-lowmem-network.conf"
LIMITS_CONF="/etc/security/limits.d/99-rikori.conf"
JOURNAL_CONF="/etc/systemd/journald.conf"
APPLY_MTU=true               # если true — применит MTU (ниже IF_MTU)
IF_MTU=1450
TOGGLE_OFFLOADS=false         # если true — отключит GRO/GSO/TSO через ethtool
# Конец конфигов

if [ "$(id -u)" -ne 0 ]; then
  echo "Запусти скрипт от root или через sudo"
  exit 1
fi

echo "=== lowspec_setup: старт ==="
# 1) определяем интерфейс (первый не-loopback)
IFACE=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n1)
echo "Интерфейс: ${IFACE}"

# 2) проверим текущий swap и добавим, если суммарно < DESIRED_TOTAL_SWAP_MB
current_swap_mb=$(free -m | awk '/Swap:/ {print $2}')
echo "Текущий swap: ${current_swap_mb} MB, нужно ${DESIRED_TOTAL_SWAP_MB} MB"

if [ "${current_swap_mb}" -lt "${DESIRED_TOTAL_SWAP_MB}" ]; then
  need_mb=$((DESIRED_TOTAL_SWAP_MB - current_swap_mb))
  # создаём swap-файл(ы) пока не дойдём до нужной суммы; имя /swapfile*, уникально
  created=0
  idx=1
  while [ "${need_mb}" -gt 0 ]; do
    target="/swapfile${idx}"
    if [ "${idx}" -eq 1 ]; then
      target="/swapfile"
    fi
    if [ -f "${target}" ]; then
      echo "Файл ${target} уже существует, пропускаю"
    else
      # создаём минимум 128MB куски, или need_mb если меньше
      chunk_mb=${need_mb}
      if [ "${chunk_mb}" -gt 512 ]; then chunk_mb=512; fi
      if [ "${chunk_mb}" -lt 128 ]; then chunk_mb=128; fi
      echo "Создаём swap ${target} ${chunk_mb}M ..."
      if fallocate -l "${chunk_mb}M" "${target}" 2>/dev/null; then
        :
      else
        dd if=/dev/zero of="${target}" bs=1M count="${chunk_mb}" status=progress
      fi
      chmod 600 "${target}"
      mkswap "${target}"
      swapon "${target}"
      echo "${target} none swap sw 0 0" >> /etc/fstab
      need_mb=$((need_mb - chunk_mb))
      created=1
    fi
    idx=$((idx+1))
    # safety
    if [ "${idx}" -gt 8 ]; then
      echo "Превышен лимит файлов swap. Прерываю."
      break
    fi
  done
  if [ "${created}" -eq 1 ]; then
    echo "Swap обновлён."
  else
    echo "Swap не изменён."
  fi
else
  echo "Swap достаточно, ничего не делаю."
fi

# 3) sysctl — low memory safe tuning
cat > "${SYSCTL_CONF}" <<'EOF'
# Low-memory safe network tuning (by rikori)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# moderate buffers to save RAM but reduce packet loss
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608

# UDP tuning
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.udp_mem = 4096 16384 4194304

# conntrack
net.netfilter.nf_conntrack_max = 65536

# sysctl misc
vm.swappiness = 10
EOF

echo "Применяю sysctl..."
sysctl --system >/dev/null 2>&1 || true

# 4) Попытка включить BBR корректно
echo "Пробуем включить BBR..."
if ! modprobe tcp_bbr 2>/dev/null; then
  echo "modprobe tcp_bbr не сработал — возможно, ядро старое (<4.9). Проверяй uname -r"
else
  echo "tcp_bbr загружен, добавляю в /etc/modules-load.d/bbr.conf"
  echo "tcp_bbr" > /etc/modules-load.d/bbr.conf || true
fi

# Если sysctl ранее не установил tcp_congestion_control, попытаемся установить
if sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
  echo "BBR активен."
else
  # попытка принудительно
  if sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1; then
    echo "BBR включён через sysctl."
  else
    echo "Не удалось включить BBR через sysctl. Возможно, ядро не поддерживает."
  fi
fi

# 5) Ограничить логи journald — SystemMaxUse=50M (идемпотентно)
if grep -q '^SystemMaxUse' "${JOURNAL_CONF}" 2>/dev/null; then
  sed -i 's/^SystemMaxUse=.*/SystemMaxUse=50M/' "${JOURNAL_CONF}"
else
  echo 'SystemMaxUse=50M' >> "${JOURNAL_CONF}"
fi
systemctl restart systemd-journald || true
echo "Journald ограничен до 50M."

# 6) limits.conf — ulimit for nofile (moderate)
cat > "${LIMITS_CONF}" <<'EOF'
# rikori limits: safe values for low-memory VPS
* soft nofile 65536
* hard nofile 65536
EOF
echo "Limits для nofile записаны."

# 7) Опционально: изменить MTU
if [ "${APPLY_MTU}" = true ]; then
  if [ -n "${IFACE}" ]; then
    echo "Применяю MTU ${IF_MTU} на интерфейс ${IFACE} (временно)"
    ip link set dev "${IFACE}" mtu "${IF_MTU}" || true
    # Для постоянного изменения — пользователь должен корректно обновить сетевые настройки (netplan/interfaces)
    echo "MTU применён (временный)."
  fi
else
  echo "MTU изменение пропущено (APPLY_MTU=false)"
fi

# 8) Опционально: выключение offloads (GRO/GSO/TSO) — осторожно
if [ "${TOGGLE_OFFLOADS}" = true ]; then
  if command -v ethtool >/dev/null 2>&1; then
    echo "Отключаю GRO/GSO/TSO на ${IFACE} (можно вернуть позже)"
    ethtool -K "${IFACE}" gro off gso off tso off || true
  else
    echo "ethtool не установлен, пропускаю offloads."
  fi
else
  echo "Изменение offloads пропущено (TOGGLE_OFFLOADS=false)"
fi

# 9) Уменьшаем детальные логи для xray/3x-ui (только предлагается, не меняем автоматически)
echo
echo "Важно: проверь настройки xray/3x-ui — установи log.level = warning (или error) в конфиге, чтобы снизить I/O."

# 10) Вывод статуса
echo
echo "=== Итог: статус системы ==="
echo "-- Swap --"
swapon --show || true
free -h || true
echo
echo "-- sysctl values --"
sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max net.ipv4.udp_mem || true
echo
echo "-- interface status (errors) --"
ip -s link show dev "${IFACE}" || true
echo
echo "-- MTU --"
ip link show "${IFACE}" | grep mtu || true
echo
echo "-- qdisc --"
tc qdisc show dev "${IFACE}" || true
echo
echo "Рекомендую перезагрузить сервер: sudo reboot"
echo "=== lowspec_setup: готово ==="
