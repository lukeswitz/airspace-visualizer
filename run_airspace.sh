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
AI_SERVER="${APP_DIR}/ai_server.py"

READSB_BIN="$(command -v readsb || true)"
DUMP1090_BIN="$(command -v dump1090 || true)"
DUMP1090_FA_BIN="$(command -v dump1090-fa || true)"
DUMP1090_MUT_BIN="$(command -v dump1090-mutability || true)"
DUMPVDL2_BIN="$(command -v dumpvdl2 || true)"
OLLAMA_BIN="$(command -v ollama || true)"
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
OLLAMA_PID="${PID_DIR}/ollama.pid"
OLLAMA_EXTERNAL_MARKER="${PID_DIR}/ollama.external"
AI_SERVER_PID="${PID_DIR}/ai_server.pid"

AIRCRAFT_JSON="/tmp/aircraft.json"
VDL2_NDJSON="/tmp/vdl2.ndjson"
VDL2_JSON="/tmp/vdl2.json"

select_sdr_devices() {
  echo "=========================================="
  echo "RTL-SDR Device Detection and Assignment"
  echo "=========================================="
  
  local devices=()
  local device_info=()
  
  # Detect all devices
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*([0-9]+): ]]; then
      local idx="${BASH_REMATCH[1]}"
      devices+=("$idx")
      device_info+=("$line")
    fi
  done < <(rtl_test -t 2>&1)
  
  if [[ ${#devices[@]} -eq 0 ]]; then
    echo "ERROR: No RTL-SDR devices found"
    exit 1
  fi
  
  echo ""
  echo "Detected ${#devices[@]} RTL-SDR device(s):"
  for info in "${device_info[@]}"; do
    echo "  $info"
  done
  echo ""
  
  # Single device - ask which function
  if [[ ${#devices[@]} -eq 1 ]]; then
    echo "Only 1 device detected (index ${devices[0]})"
    echo "Select mode:"
    echo "  1) ADS-B only (1090 MHz)"
    echo "  2) VDL2/ACARS only (136 MHz)"
    echo "  3) Time-sliced (alternating ADS-B/VDL2)"
    read -p "Choice [1-3]: " mode_choice
    
    case "$mode_choice" in
      1)
        ADSB_IDX="${devices[0]}"
        VDL2_IDX=""
        USE_TIMESLICE=false
        echo "✓ Device ${ADSB_IDX} assigned to ADS-B"
        ;;
      2)
        ADSB_IDX=""
        VDL2_IDX="${devices[0]}"
        USE_TIMESLICE=false
        echo "✓ Device ${VDL2_IDX} assigned to VDL2/ACARS"
        ;;
      3)
        ADSB_IDX="${devices[0]}"
        VDL2_IDX="${devices[0]}"
        USE_TIMESLICE=true
        echo "✓ Device ${ADSB_IDX} assigned to time-sliced mode"
        ;;
      *)
        echo "Invalid choice, defaulting to ADS-B only"
        ADSB_IDX="${devices[0]}"
        VDL2_IDX=""
        USE_TIMESLICE=false
        ;;
    esac
    return
  fi
  
  # Multiple devices - assign individually
  echo "Assign devices to functions:"
  echo ""
  
  # Select ADS-B device
  echo "Available devices:"
  for i in "${!devices[@]}"; do
    echo "  $((i+1))) ${device_info[$i]}"
  done
  echo "  s) Skip ADS-B (VDL2 only mode)"
  read -p "Select device for ADS-B (1090 MHz) [1-${#devices[@]},s]: " adsb_choice
  
  if [[ "$adsb_choice" == "s" ]]; then
    ADSB_IDX=""
    echo "✓ ADS-B disabled"
  elif [[ "$adsb_choice" =~ ^[0-9]+$ ]] && [[ "$adsb_choice" -ge 1 ]] && [[ "$adsb_choice" -le ${#devices[@]} ]]; then
    ADSB_IDX="${devices[$((adsb_choice-1))]}"
    echo "✓ Device ${ADSB_IDX} assigned to ADS-B"
  else
    echo "Invalid choice, using device ${devices[0]}"
    ADSB_IDX="${devices[0]}"
  fi
  
  echo ""
  
  # Select VDL2 device
  echo "Available devices:"
  for i in "${!devices[@]}"; do
    local dev="${devices[$i]}"
    if [[ "$dev" == "$ADSB_IDX" ]]; then
      echo "  $((i+1))) ${device_info[$i]} [ALREADY ASSIGNED TO ADS-B]"
    else
      echo "  $((i+1))) ${device_info[$i]}"
    fi
  done
  echo "  s) Skip VDL2 (ADS-B only mode)"
  read -p "Select device for VDL2/ACARS (136 MHz) [1-${#devices[@]},s]: " vdl2_choice
  
  if [[ "$vdl2_choice" == "s" ]]; then
    VDL2_IDX=""
    USE_TIMESLICE=false
    echo "✓ VDL2 disabled"
  elif [[ "$vdl2_choice" =~ ^[0-9]+$ ]] && [[ "$vdl2_choice" -ge 1 ]] && [[ "$vdl2_choice" -le ${#devices[@]} ]]; then
    VDL2_IDX="${devices[$((vdl2_choice-1))]}"
    
    # Check if same device
    if [[ "$VDL2_IDX" == "$ADSB_IDX" ]] && [[ -n "$ADSB_IDX" ]]; then
      echo "⚠️  Same device selected for both functions"
      read -p "Enable time-slicing? [Y/n]: " timeslice_choice
      if [[ "$timeslice_choice" =~ ^[Nn] ]]; then
        USE_TIMESLICE=false
        echo "✓ Device ${VDL2_IDX} assigned to VDL2 (will conflict with ADS-B)"
      else
        USE_TIMESLICE=true
        echo "✓ Device ${VDL2_IDX} assigned to time-sliced mode"
      fi
    else
      USE_TIMESLICE=false
      echo "✓ Device ${VDL2_IDX} assigned to VDL2"
    fi
  else
    echo "Invalid choice, using device ${devices[0]}"
    VDL2_IDX="${devices[0]}"
    USE_TIMESLICE=false
  fi
  
  echo ""
  echo "=========================================="
  echo "Configuration Summary:"
  echo "  ADS-B:        ${ADSB_IDX:-disabled}"
  echo "  VDL2:         ${VDL2_IDX:-disabled}"
  echo "  Time-sliced:  ${USE_TIMESLICE}"
  echo "=========================================="
  echo ""
}

adsb_cmd() {
  local adsb_idx="${ADSB_IDX:-1}"
  
  if [[ -z "$adsb_idx" ]]; then
    echo ""
    return
  fi
  
  if [[ -n "${READSB_BIN}" ]]; then
    echo "${READSB_BIN} --device-type rtlsdr --device ${adsb_idx} --gain 49.6 --write-json /tmp --write-json-every 1"
  elif [[ -n "${DUMP1090_FA_BIN}" ]]; then
    echo "${DUMP1090_FA_BIN} --device ${adsb_idx} --gain 49.6 --net --write-json /tmp --write-json-every 1"
  elif [[ -n "${DUMP1090_MUT_BIN}" ]]; then
    echo "${DUMP1090_MUT_BIN} --device ${adsb_idx} --gain 49.6 --net --write-json /tmp --write-json-every 1"
  elif [[ -n "${DUMP1090_BIN}" ]]; then
    echo "${DUMP1090_BIN} --device ${adsb_idx} --gain 49.6 --net --write-json /tmp --write-json-every 1"
  else
    echo ""
  fi
}

vdl2_cmd() {
  local vdl_idx="${VDL2_IDX:-0}"
  
  if [[ -z "$vdl_idx" ]]; then
    echo ""
    return
  fi
  # // 131.525 131.725 131.825 130.450 130.825 131.550 for most airports, use 136 for delta/southwest hubs
  if [[ -n "${DUMPVDL2_BIN}" ]]; then
    # echo "acarsdec -A -e --output json:file:path=$VDL2_NDJSON --rtlsdr $vdl_idx -g 36.4 131.525 131.725 131.825 130.450 130.825 131.550"
    # echo "${DUMPVDL2_BIN} --rtlsdr ${vdl_idx} --gain 49.6 131525000 131550000 131725000 131825000 --output decoded:json:file:path=${VDL2_NDJSON}"
    echo "${DUMPVDL2_BIN} --rtlsdr ${vdl_idx} --gain 49.6 136650000 136725000 136775000 136800000 136825000 136875000 136900000 136975000 --output decoded:json:file:path=${VDL2_NDJSON}"
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
  # Interactive device selection
  select_sdr_devices
  
  # sanity: tools
  local ADSB_CMD="$(adsb_cmd)"
  local VDL_CMD="$(vdl2_cmd)"
  
  if [[ -z "${ADSB_CMD}" ]] && [[ -z "${VDL_CMD}" ]]; then
    echo "Error: No functions enabled or no SDR tools found." >&2
    exit 1
  fi
  
  # stop leftovers
  stop_all >/dev/null 2>&1 || true

  # ensure output files exist
  : >"${AIRCRAFT_JSON}"
  : >"${VDL2_NDJSON}"
  : >"${VDL2_JSON}"

  # start ADS-B if enabled
  if [[ -n "${ADSB_CMD}" ]] && [[ "${USE_TIMESLICE}" != "true" ]]; then
    echo "Starting ADS-B: ${ADSB_CMD}"
    start_proc "${ADSB_CMD}" "${READSB_PID}" "${LOG_DIR}/readsb.log"
    sleep 0.5
  fi

  # start VDL2 if enabled (and not time-sliced)
  if [[ -n "${VDL_CMD}" ]] && [[ "${USE_TIMESLICE}" != "true" ]]; then
    echo "Starting VDL2: ${VDL_CMD}"
    start_proc "${VDL_CMD}" "${VDL2_PID}" "${LOG_DIR}/dumpvdl2.log"
    sleep 0.5
  fi
  
  # start time-sliced mode if enabled
  if [[ "${USE_TIMESLICE}" == "true" ]]; then
    echo "Starting time-sliced mode on device ${ADSB_IDX}"
    if [[ ! -f "${APP_DIR}/single_rtlsdr_scheduler.sh" ]]; then
      echo "Error: single_rtlsdr_scheduler.sh not found"
      exit 1
    fi
    start_proc "bash ${APP_DIR}/single_rtlsdr_scheduler.sh" "${READSB_PID}" "${LOG_DIR}/timeslice.log"
    sleep 0.5
  fi

  # keep last NDJSON line mirrored to single JSON file
  echo "Starting NDJSON follower -> ${VDL2_JSON}"
  nohup bash -c "tail -F -n1 \"${VDL2_NDJSON}\" | while read -r line; do [[ -n \"\$line\" ]] && echo \"\$line\" > \"${VDL2_JSON}\"; done" \
    >>"${LOG_DIR}/vdl_tail.log" 2>&1 &
  echo $! >"${TAIL_PID}"
  sleep 0.2

  # Start Ollama if not running
  echo "Checking Ollama status..."
  rm -f "${OLLAMA_EXTERNAL_MARKER}"
  
  if [[ -z "${OLLAMA_BIN}" ]]; then
    echo "⚠️  Ollama not found in PATH - AI features will be unavailable"
    echo "   Install with: curl -fsSL https://ollama.ai/install.sh | sh"
  else
    if curl -s http://localhost:11434/api/version &>/dev/null; then
      echo "✅ Ollama already running (external instance)"
      touch "${OLLAMA_EXTERNAL_MARKER}"
    else
      echo "Starting Ollama server..."
      start_proc "${OLLAMA_BIN} serve" "${OLLAMA_PID}" "${LOG_DIR}/ollama.log"
      sleep 3
      
      if curl -s http://localhost:11434/api/version &>/dev/null; then
        echo "✅ Ollama server started successfully"
      else
        echo "⚠️  Ollama failed to start - check ${LOG_DIR}/ollama.log"
      fi
    fi
  fi

  # Start AI server if available (fix: prevent multiple instances)
  if [[ -f "${AI_SERVER}" ]]; then
    # Kill any existing AI server processes first
    pkill -9 -f "ai_server.py" 2>/dev/null || true
    sleep 1
    
    # Only start if not already running on port 11435
    if ! curl -s http://localhost:11435/ &>/dev/null; then
      echo "Starting AI server: ${PY_BIN} ${AI_SERVER}"
      start_proc "${PY_BIN} ${AI_SERVER}" "${AI_SERVER_PID}" "${LOG_DIR}/ai_server.log"
      sleep 2
      
      # Verify it started
      if curl -s http://localhost:11435/ &>/dev/null; then
        echo "✅ AI server started successfully"
      else
        echo "⚠️  AI server failed to start - check ${LOG_DIR}/ai_server.log"
      fi
    else
      echo "✅ AI server already running"
    fi
  else
    echo "⚠️  AI server not found at ${AI_SERVER}"
  fi

  # start bridge
  echo "Starting bridge: ${PY_BIN} ${PY_BRIDGE}"
  start_proc "${PY_BIN} ${PY_BRIDGE}" "${BRIDGE_PID}" "${LOG_DIR}/bridge.log"
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
  if is_running "${AI_SERVER_PID}"; then
    pkill -9 "$(cat "${AI_SERVER_PID}")" 2>/dev/null || true
    rm -f "${AI_SERVER_PID}"
  fi
  pkill -9 -f "ai_server.py" 2>/dev/null || true
  
  if [[ ! -f "${OLLAMA_EXTERNAL_MARKER}" ]]; then
    stop_pid "${OLLAMA_PID}"
    pkill -f "ollama serve" 2>/dev/null || true
  fi
  rm -f "${OLLAMA_EXTERNAL_MARKER}"
  
  stop_pid "${TAIL_PID}"
  stop_pid "${VDL2_PID}"
  stop_pid "${READSB_PID}"
  
  pkill -f "http.server 8111" 2>/dev/null || true
  pkill -f "visualizer_bridge.py" 2>/dev/null || true
  pkill -f "tail -F -n1 ${VDL2_NDJSON}" 2>/dev/null || true
  pkill -f dumpvdl2 2>/dev/null || true
  pkill -f readsb 2>/dev/null || true
  pkill -9 -f "ai_server.py" 2>/dev/null || true
  
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
  
  if [[ -f "${OLLAMA_EXTERNAL_MARKER}" ]]; then
    if curl -s http://localhost:11434/api/version &>/dev/null; then
      echo "[UP]  Ollama (ML server) external instance"
    else
      echo "[DOWN] Ollama (ML server) external instance not responding"
    fi
  else
    status_line "Ollama (ML server)" "${OLLAMA_PID}"
  fi
  
  status_line "AI Server (Flask)" "${AI_SERVER_PID}"
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
  echo "ollama:    ${LOG_DIR}/ollama.log"
  echo "ai_server: ${LOG_DIR}/ai_server.log"
  echo
  tail -n 50 "${LOG_DIR}/readsb.log" 2>/dev/null || true
  tail -n 50 "${LOG_DIR}/dumpvdl2.log" 2>/dev/null || true
  tail -n 50 "${LOG_DIR}/vdl_tail.log" 2>/dev/null || true
  tail -n 50 "${LOG_DIR}/bridge.log" 2>/dev/null || true
  tail -n 50 "${LOG_DIR}/web8111.log" 2>/dev/null || true
  tail -n 50 "${LOG_DIR}/ollama.log" 2>/dev/null || true
  tail -n 50 "${LOG_DIR}/ai_server.log" 2>/dev/null || true
}

case "${1:-}" in
  start) start_all ;;
  stop) stop_all ;;
  status) status_all ;;
  logs) show_logs ;;
  *) echo "Usage: $0 {start|stop|status|logs}"; exit 1 ;;
esac