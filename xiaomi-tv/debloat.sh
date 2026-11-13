#!/usr/bin/env bash
# =============================================================================
# Xiaomi TV: прибрати PatchWall, Mi Channels / Xiaomi TV+ і рекламу через ADB.
#
# Основано на списку пакетів з Kamikazi951/xiaomitv-debloat-toolkit (MIT),
# з додатковими перевірками безпеки:
#   * за замовчуванням лише показує план (dry-run); зміни — тільки з --apply
#   * вимикає лише пакети, які реально є на ТВ і зараз увімкнені
#   * НЕ вимикає лаунчери (PatchWall / Google TV), якщо не встановлено
#     інший лаунчер — інакше ТВ лишиться без домашнього екрана
#   * записує, що саме вимкнено, у лог; --restore вмикає рівно це назад
#   * нічого не видаляє (тільки pm disable-user), без root
#
# Використання:
#   ./debloat.sh find                    # знайти ТВ у локальній мережі
#   ./debloat.sh plan    <IP>            # показати, що буде вимкнено
#   ./debloat.sh apply   <IP> [--keep-netflix]
#   ./debloat.sh restore <IP>            # повернути все, що вимкнув apply
# =============================================================================
set -euo pipefail

MODE="${1:-}"
TV_IP="${2:-}"
PORT="${PORT:-5555}"
KEEP_NETFLIX=0
for a in "$@"; do [ "$a" = "--keep-netflix" ] && KEEP_NETFLIX=1; done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$SCRIPT_DIR/logs"

# --- Пакети ------------------------------------------------------------------
# Реклама, PatchWall-канали, телеметрія — безпечно вимикати завжди.
ADS_AND_TELEMETRY=(
  com.mitv.tvhome.mitvplus        # Xiaomi TV+ / Mi Channels (FAST-канали з рекламою)
  com.mitv.tvhome.michannel       # фід контенту для Mi Channels
  com.mitv.tvhome.oemtab          # вкладка "MI HOME" у верхньому меню
  com.xm.webcontent               # рекламні банери та рекомендації
  com.miui.tv.analytics           # телеметрія Xiaomi
  com.xiaomi.statistic            # статистика використання
  com.xiaomi.mitv.tvmanager       # "очищувач", фоновий демон
  fusion.android.tv.demo          # демо-режим для магазину
  com.google.android.feedback     # відправка звітів про збої
)
NETFLIX=(com.netflix.ninja)
# Лаунчери — вимикаємо тільки якщо є альтернативний лаунчер.
LAUNCHERS=(
  com.mitv.tvhome.atv                       # PatchWall
  com.google.android.apps.tv.launcherx      # Google TV launcher
  com.google.android.tungsten.setupwraith   # setup-майстер LauncherX
)
# Відомі сторонні лаунчери.
ALT_LAUNCHERS=(
  com.spocky.projengmenu        # Projectivy Launcher
  com.google.android.tvlauncher # стандартний Android TV launcher
  nl.ndsc.launcher              # FLauncher
  me.efesser.flauncher          # FLauncher (fork)
  com.wolf.firelauncher         # Wolf Launcher
  com.atvlauncher               # ATV Launcher
)
# Ніколи не чіпати: тюнер, HDMI, пульт, звук, клавіатура.
PROTECTED=(
  com.mitv.livetv com.mitv.livetv.ci_mediatek com.mediatek.tvinput
  com.mediatek.tv.service com.google.android.tv.remote.service com.mi.bluetooth
  com.android.bluetooth com.dolby.android.audio.service
  com.google.android.inputmethod.latin
)

die() { echo "Помилка: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "потрібна програма '$1' (встановіть: $2)"; }

# --- Пошук ТВ у мережі -------------------------------------------------------
find_tv() {
  echo "==> Шукаю пристрої з відкритим ADB (порт $PORT)..."
  if adb mdns check >/dev/null 2>&1; then
    adb mdns services 2>/dev/null | grep -i adb || true
  fi
  if command -v nmap >/dev/null; then
    local subnet
    subnet="$(ip -4 route 2>/dev/null | awk '/src/ && !/docker|br-/ {print $1; exit}')"
    [ -n "$subnet" ] || die "не вдалося визначити підмережу; вкажіть IP вручну"
    echo "==> Сканую $subnet ..."
    nmap -Pn -p "$PORT",6466,8008 --open "$subnet" -oG - | awk '/open/ {print "  Можливо ТВ:", $2, $5}'
    echo "Порт 5555 = ADB, 6466 = Android TV Remote, 8008 = Chromecast."
  else
    echo "nmap не встановлено. IP телевізора: Налаштування → Мережа → ваша Wi-Fi."
  fi
}

# --- ADB ---------------------------------------------------------------------
DEV=""
connect() {
  [ -n "$TV_IP" ] || die "вкажіть IP телевізора, напр.: $0 $MODE 192.168.1.45"
  DEV="$TV_IP:$PORT"
  echo "==> Підключаюсь до $DEV (на ТВ натисніть «Дозволити», якщо спитає)..."
  adb connect "$DEV" | sed 's/^/    /'
  timeout 60 adb -s "$DEV" wait-for-device || die "ТВ не відповідає. Увімкніть «Налагодження USB/по мережі» у Параметрах розробника."
  local state; state="$(adb -s "$DEV" get-state 2>/dev/null || true)"
  [ "$state" = "device" ] || die "стан '$state' — підтвердіть запит налагодження на екрані ТВ і повторіть."
  echo "    Модель: $(sh_tv getprop ro.product.model)  Android $(sh_tv getprop ro.build.version.release)"
}
sh_tv() { adb -s "$DEV" shell "$@" | tr -d '\r'; }

INSTALLED=""; DISABLED=""
load_pkgs() {
  INSTALLED="$(sh_tv pm list packages | sed 's/^package://')"
  DISABLED="$(sh_tv pm list packages -d | sed 's/^package://')"
}
installed() { grep -qx "$1" <<<"$INSTALLED"; }
enabled()   { installed "$1" && ! grep -qx "$1" <<<"$DISABLED"; }

build_plan() {
  PLAN=()
  local list=("${ADS_AND_TELEMETRY[@]}")
  [ "$KEEP_NETFLIX" = 1 ] || list+=("${NETFLIX[@]}")

  local alt=""
  for p in "${ALT_LAUNCHERS[@]}"; do enabled "$p" && alt="$p" && break; done
  if [ -n "$alt" ]; then
    echo "==> Знайдено альтернативний лаунчер: $alt — PatchWall/Google TV launcher теж буде вимкнено."
    list+=("${LAUNCHERS[@]}")
  else
    echo "==> Альтернативного лаунчера немає — лаунчери НЕ чіпаю (інакше зникне домашній екран)."
    echo "    Щоб прибрати і сам PatchWall: встановіть Projectivy Launcher з Google Play і запустіть знову."
  fi

  for p in "${list[@]}"; do
    for s in "${PROTECTED[@]}"; do [ "$p" = "$s" ] && continue 2; done
    if enabled "$p"; then PLAN+=("$p"); fi
  done
  return 0
}

print_plan() {
  if [ "${#PLAN[@]}" -eq 0 ]; then echo "==> Нічого вимикати: пакетів немає або вони вже вимкнені."; return; fi
  echo "==> Буде вимкнено (${#PLAN[@]}):"
  printf '    - %s\n' "${PLAN[@]}"
}

apply() {
  build_plan; print_plan
  [ "${#PLAN[@]}" -gt 0 ] || return 0
  read -r -p "Продовжити? [y/N] " ans; [[ "$ans" =~ ^[yYтТ]$ ]] || { echo "Скасовано."; return; }
  mkdir -p "$LOG_DIR"
  local log="$LOG_DIR/disabled-${TV_IP}.txt"
  for p in "${PLAN[@]}"; do
    if out="$(sh_tv pm disable-user --user 0 "$p" 2>&1)" && grep -q "disabled" <<<"$out"; then
      echo "    ✔ $p"; echo "$p" >>"$log"
    else
      echo "    ✘ $p: $out"
    fi
  done
  sort -u "$log" -o "$log"
  echo "==> Готово. Список вимкненого: $log"
  echo "    Відкат: $0 restore $TV_IP"
  read -r -p "Перезавантажити ТВ зараз? [y/N] " ans
  [[ "$ans" =~ ^[yYтТ]$ ]] && adb -s "$DEV" reboot || true
}

restore() {
  local log="$LOG_DIR/disabled-${TV_IP}.txt"
  local list=()
  if [ -f "$log" ]; then mapfile -t list <"$log"
  else
    echo "==> Логу немає — вмикаю всі пакети зі списку скрипта."
    list=("${ADS_AND_TELEMETRY[@]}" "${NETFLIX[@]}" "${LAUNCHERS[@]}")
  fi
  for p in "${list[@]}"; do
    installed "$p" || continue
    if sh_tv pm enable "$p" >/dev/null; then echo "    ✔ $p"; fi
  done
  if [ -f "$log" ]; then mv "$log" "$log.restored-$(date +%s)"; fi
  echo "==> Відкат завершено."
}

need adb "Linux: sudo apt install adb · macOS: brew install android-platform-tools · Windows: Platform Tools від Google"
case "$MODE" in
  find)    find_tv ;;
  plan)    connect; load_pkgs; build_plan; print_plan ;;
  apply)   connect; load_pkgs; apply ;;
  restore) connect; load_pkgs; restore ;;
  *) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
