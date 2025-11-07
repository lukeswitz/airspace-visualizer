#!/usr/bin/env bash
# run_airspace.sh — manage ADS-B + VDL2 ingest and bridge + web server
# Usage:
#   ./run_airspace.sh start
#   ./run_airspace.sh stop
#   ./run_airspace.sh status
#   ./run_airspace.sh logs

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY_BRIDGE="${APP_DIR}/visualizer_bridge.py"

READSB_BIN="$(command -v readsb || true)"
DUMP1090_BIN="$(command -v dump1090 || true)"
DUMP1090_FA_BIN="$(command -v dump1090-fa || true)"
DUMP1090_MUT_BIN="$(command -v dump1090-mutability || true)"
DUMPVDL2_BIN="$(command -v dumpvdl2 || true)"
PY_BIN="$(command -v python3 || command -v python || true)"

LOG_DIR="${APP_DIR}/logs"
mkdir -p "${LOG_DIR}"

PID_DIR="${APP_DIR}/pids"
mkdir -p "${PID_DIR}"

READSB_PID="${PID_DIR}/readsb.pid"
VDL2_PID="${PID_DIR}/dumpvdl2.pid"
TAIL_PID="${PID_DIR}/vdl_tail.pid"
BRIDGE_PID="${PID_DIR}/bridge.pid"
WEB_PID="${PID_DIR}/web8111.pid"

AIRCRAFT_JSON="/tmp/aircraft.json"
VDL2_NDJSON="/tmp/vdl2.ndjson"
VDL2_JSON="/tmp/vdl2.json"

detect_rtlsdr_devices() {
  rtl_test -t 2>&1 | grep -E "^\s+[0-9]+:" | while read -r line; do
    echo "$line"
  done
}

find_device_by_serial() {
  local serial="$1"
  rtl_test -t 2>&1 | grep -B1 "SN: ${serial}" | grep -oP '^\s+\K[0-9]+(?=:)' | head -1
}

adsb_cmd() {
  local adsb_idx
  adsb_idx="$(find_device_by_serial "00000001" || echo "1")"
  
  if [[ -n "${READSB_BIN}" ]]; then
    echo "${READSB_BIN} --device-type rtlsdr --device ${adsb_idx} --write-json /tmp --write-json-every 1"
  elif [[ -n "${DUMP1090_FA_BIN}" ]]; then
    echo "${DUMP1090_FA_BIN} --device ${adsb_idx} --net --write-json /tmp --write-json-every 1"
  elif [[ -n "${DUMP1090_MUT_BIN}" ]]; then
    echo "${DUMP1090_MUT_BIN} --device ${adsb_idx} --net --write-json /tmp --write-json-every 1"
  elif [[ -n "${DUMP1090_BIN}" ]]; then
    echo "${DUMP1090_BIN} --device ${adsb_idx} --net --write-json /tmp --write-json-every 1"
  else
    echo ""
  fi
}

vdl2_cmd() {
  local vdl_idx
  vdl_idx="$(find_device_by_serial "VDL2" || echo "0")"
  
  if [[ -n "${DUMPVDL2_BIN}" ]]; then
    echo "${DUMPVDL2_BIN} --rtlsdr ${vdl_idx} 136650000 136725000 136775000 136800000 136825000 136875000 136900000 136975000 --output decoded:json:file:path=\"${VDL2_NDJSON}\""
  else
    echo ""
  fi
}

is_running() {
  local pidf="$1"
  [[ -f "${pidf}" ]] && kill -0 "$(cat "${pidf}")" 2>/dev/null
}

start_proc() {
  local cmd="$1"
  local pidf="$2"
  local log="$3"
  nohup bash -c "${cmd}" >>"${log}" 2>&1 &
  echo $! >"${pidf}"
}

start_all() {
  # sanity: tools
  local ADSB_CMD="$(adsb_cmd)"
  local VDL_CMD="$(vdl2_cmd)"
  if [[ -z "${ADSB_CMD}" ]]; then
    echo "Error: readsb/dump1090 not found in PATH." >&2
    exit 1
  fi
  if [[ -z "${VDL_CMD}" ]]; then
    echo "Error: dumpvdl2 not found in PATH." >&2
    exit 1
  fi
  if [[ -z "${PY_BIN}" ]]; then
    echo "Error: python3 not found." >&2
    exit 1
  fi

  # stop leftovers
  stop_all >/dev/null 2>&1 || true

  # ensure output files exist
  : >"${AIRCRAFT_JSON}"
  : >"${VDL2_NDJSON}"
  : >"${VDL2_JSON}"

  # start ADS-B
  echo "Starting ADS-B: ${ADSB_CMD}"
  start_proc "${ADSB_CMD}" "${READSB_PID}" "${LOG_DIR}/readsb.log"
  sleep 0.5

  # start VDL2 (NDJSON)
  echo "Starting VDL2: ${VDL_CMD}"
  start_proc "${VDL_CMD}" "${VDL2_PID}" "${LOG_DIR}/dumpvdl2.log"
  sleep 0.5

  # keep last NDJSON line mirrored to single JSON file
  echo "Starting NDJSON follower -> ${VDL2_JSON}"
  nohup bash -c "tail -F -n1 \"${VDL2_NDJSON}\" | while read -r line; do [[ -n \"\$line\" ]] && echo \"\$line\" > \"${VDL2_JSON}\"; done" \
    >>"${LOG_DIR}/vdl_tail.log" 2>&1 &
  echo $! >"${TAIL_PID}"
  sleep 0.2

  # start bridge
  echo "Starting bridge: ${PY_BIN} ${PY_BRIDGE}"
  start_proc "${PY_BIN} \"${PY_BRIDGE}\"" "${BRIDGE_PID}" "${LOG_DIR}/bridge.log"
  sleep 0.2

  # start web server
  echo "Starting localhost web server on 127.0.0.1:8111"
  start_proc "${PY_BIN} -m http.server 8111 --bind 127.0.0.1" "${WEB_PID}" "${LOG_DIR}/web8111.log"

  echo "Started."
  status_all
}

stop_pid() {
  local pidf="$1"
  if is_running "${pidf}"; then
    kill "$(cat "${pidf}")" 2>/dev/null || true
    sleep 0.5
    if is_running "${pidf}"; then
      kill -9 "$(cat "${pidf}")" 2>/dev/null || true
    fi
  fi
  rm -f "${pidf}"
}

stop_all() {
  stop_pid "${WEB_PID}"
  stop_pid "${BRIDGE_PID}"
  stop_pid "${TAIL_PID}"
  stop_pid "${VDL2_PID}"
  stop_pid "${READSB_PID}"
  # also gently kill by name if left
  pkill -f "http.server 8111" 2>/dev/null || true
  pkill -f "visualizer_bridge.py" 2>/dev/null || true
  pkill -f "tail -F -n1 ${VDL2_NDJSON}" 2>/dev/null || true
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

status_all() {
  status_line "ADS-B (readsb/dump1090)" "${READSB_PID}"
  status_line "VDL2 (dumpvdl2)" "${VDL2_PID}"
  status_line "VDL2 tail->json" "${TAIL_PID}"
  status_line "Bridge (Flask)" "${BRIDGE_PID}"
  status_line "Web 127.0.0.1:8111" "${WEB_PID}"
  echo "Files:"
  echo "  ${AIRCRAFT_JSON} size=$(stat -c%s \"${AIRCRAFT_JSON}\" 2>/dev/null || stat -f%z \"${AIRCRAFT_JSON}\" 2>/dev/null || echo 0)"
  echo "  ${VDL2_JSON} size=$(stat -c%s \"${VDL2_JSON}\" 2>/dev/null || stat -f%z \"${VDL2_JSON}\" 2>/dev/null || echo 0)"
}

show_logs() {
  echo "Logs in ${LOG_DIR}"
  echo "readsb:    ${LOG_DIR}/readsb.log"
  echo "dumpvdl2:  ${LOG_DIR}/dumpvdl2.log"
  echo "vdl_tail:  ${LOG_DIR}/vdl_tail.log"
  echo "bridge:    ${LOG_DIR}/bridge.log"
  echo "web8111:   ${LOG_DIR}/web8111.log"
  echo
  tail -n 50 "${LOG_DIR}/readsb.log" 2>/dev/null || true
  tail -n 50 "${LOG_DIR}/dumpvdl2.log" 2>/dev/null || true
  tail -n 50 "${LOG_DIR}/vdl_tail.log" 2>/dev/null || true
  tail -n 50 "${LOG_DIR}/bridge.log" 2>/dev/null || true
  tail -n 50 "${LOG_DIR}/web8111.log" 2>/dev/null || true
}

case "${1:-}" in
  start) start_all ;;
  stop) stop_all ;;
  status) status_all ;;
  logs) show_logs ;;
  *) echo "Usage: $0 {start|stop|status|logs}"; exit 1 ;;
esac