#!/usr/bin/env bash
# run_stack.sh — start/stop/status for ADS-B, VDL2, bridge, and a localhost web server

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_BRIDGE="${APP_DIR}/visualizer_bridge.py"

READSB_BIN="$(command -v readsb || true)"
DUMPVDL2_BIN="$(command -v dumpvdl2 || true)"
PY_BIN="$(command -v python3 || command -v python || true)"

LOG_DIR="${APP_DIR}/logs"
PID_DIR="${APP_DIR}/pids"
mkdir -p "${LOG_DIR}" "${PID_DIR}"

READSB_PID="${PID_DIR}/readsb.pid"
VDL2_PID="${PID_DIR}/dumpvdl2.pid"
BRIDGE_PID="${PID_DIR}/bridge.pid"
WEB_PID="${PID_DIR}/web8111.pid"

start_proc() {
  local cmd="$1"
  local pidf="$2"
  local log="$3"
  nohup bash -c "${cmd}" >>"${log}" 2>&1 &
  echo $! >"${pidf}"
}

is_running() {
  [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null
}

stop_pid() {
  local pidf="$1"
  if is_running "${pidf}"; then
    kill "$(cat "${pidf}")" 2>/dev/null || true
    sleep 0.4
    if is_running "${pidf}"; then kill -9 "$(cat "${pidf}")" 2>/dev/null || true; fi
  fi
  rm -f "${pidf}"
}

start() {
  if [[ -z "${READSB_BIN}" || -z "${DUMPVDL2_BIN}" || -z "${PY_BIN}" ]]; then
    echo "Missing binaries. Needed: readsb, dumpvdl2, python3" >&2
    exit 1
  fi

  : >/tmp/aircraft.json
  : >/tmp/vdl2.json

  echo "Starting ADS-B on ADSB"
  start_proc \
    "${READSB_BIN} --device-type rtlsdr --device ADSB --write-json /tmp --write-json-every 1" \
    "${READSB_PID}" "${LOG_DIR}/readsb.log"

  echo "Starting VDL2 on VDL2"
  start_proc \
    "${DUMPVDL2_BIN} --rtlsdr VDL2 136650000 136725000 136775000 136800000 136825000 136875000 136900000 136975000 --output decoded:json:file:path=\"/tmp/vdl2.json\"" \
    "${VDL2_PID}" "${LOG_DIR}/dumpvdl2.log"

  echo "Starting bridge"
  start_proc \
    "${PY_BIN} \"${PY_BRIDGE}\"" \
    "${BRIDGE_PID}" "${LOG_DIR}/bridge.log"

  echo "Starting localhost web server on 127.0.0.1:8111"
  start_proc \
    "${PY_BIN} -m http.server 8111 --bind 127.0.0.1" \
    "${WEB_PID}" "${LOG_DIR}/web8111.log"

  status
}

stop() {
  stop_pid "${WEB_PID}"
  stop_pid "${BRIDGE_PID}"
  stop_pid "${VDL2_PID}"
  stop_pid "${READSB_PID}"
  pkill -f "visualizer_bridge.py" 2>/dev/null || true
  pkill -f "http.server 8111" 2>/dev/null || true
  pkill -f dumpvdl2 2>/dev/null || true
  pkill -f readsb 2>/dev/null || true
  echo "Stopped."
}

status_line() {
  local name="$1" pidf="$2"
  if is_running "${pidf}"; then
    echo "[UP]  ${name} pid=$(cat "${pidf}")"
  else
    echo "[DOWN] ${name}"
  fi
}

status() {
  status_line "ADS-B (readsb)" "${READSB_PID}"
  status_line "VDL2 (dumpvdl2)" "${VDL2_PID}"
  status_line "Bridge (Flask)" "${BRIDGE_PID}"
  status_line "Web 127.0.0.1:8111" "${WEB_PID}"
  echo "Files:"
  if command -v stat >/dev/null 2>&1; then
    A_SIZE=$(stat -c%s /tmp/aircraft.json 2>/dev/null || stat -f%z /tmp/aircraft.json 2>/dev/null || echo 0)
    V_SIZE=$(stat -c%s /tmp/vdl2.json 2>/dev/null || stat -f%z /tmp/vdl2.json 2>/dev/null || echo 0)
  else
    A_SIZE=$(wc -c </tmp/aircraft.json 2>/dev/null || echo 0)
    V_SIZE=$(wc -c </tmp/vdl2.json 2>/dev/null || echo 0)
  fi
  echo "  /tmp/aircraft.json size=${A_SIZE}"
  echo "  /tmp/vdl2.json size=${V_SIZE}"
}

logs() {
  echo "Logs in ${LOG_DIR}"
  for f in readsb dumpvdl2 bridge web8111; do
    echo "==> ${LOG_DIR}/${f}.log"
    tail -n 50 "${LOG_DIR}/${f}.log" 2>/dev/null || true
    echo
  done
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  status) status ;;
  logs) logs ;;
  *) echo "Usage: $0 {start|stop|status|logs}"; exit 1 ;;
esac
