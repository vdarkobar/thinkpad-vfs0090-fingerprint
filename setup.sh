#!/usr/bin/env bash
set -Eeuo pipefail

# fingerprint-p50-vfs0090-fedora.sh
# Fedora-only no-snap installer/initializer for ThinkPad P50 Validity VFS7500
# fingerprint reader: USB ID 138a:0090.
#
# Daily fingerprint use is handled by Fedora fprintd + libfprint-vfs0090.
# One-time sensor initialization is handled by validity-sensors-tools from:
#   https://github.com/vdarkobar/python-validity
#
# Scope:
#   Supported: Fedora, Validity/Synaptics VFS7500 138a:0090
#   Refuses: non-Fedora systems, missing 138a:0090 sensor
#
# Usage:
#   chmod +x fingerprint-p50-vfs0090-fedora.sh
#   sudo ./fingerprint-p50-vfs0090-fedora.sh
#
# Optional:
#   sudo ASSUME_YES=1 ./fingerprint-p50-vfs0090-fedora.sh
#   sudo ./fingerprint-p50-vfs0090-fedora.sh --yes
#   sudo ./fingerprint-p50-vfs0090-fedora.sh --skip-init

APP_NAME="fingerprint-p50-vfs0090-fedora"
SENSOR_USB_ID="138a:0090"
SUPPORTED_DISTRO_ID="fedora"

BASE_DIR="/opt/vfs0090-tools"
SRC_DIR="${BASE_DIR}/source"
VENV_DIR="${BASE_DIR}/venv"
STATE_DIR="${BASE_DIR}/state"
COMMON_DIR="${BASE_DIR}/common"
FIRMWARE_DIR="${BASE_DIR}/firmware"

INIT_REPO_URL="${INIT_REPO_URL:-https://github.com/vdarkobar/python-validity.git}"
# Optional: pin to a branch, tag, or commit. Empty means default branch HEAD.
INIT_REPO_REF="${INIT_REPO_REF:-}"

LENOVO_DRIVER_URL="https://download.lenovo.com/pccbbs/mobiles/n1cgn08w.exe"
LENOVO_FW_NAME="6_07f_Lenovo.xpfwext"
LOCAL_FW_PATH="${FIRMWARE_DIR}/${LENOVO_FW_NAME}"

ASSUME_YES="${ASSUME_YES:-0}"
RUN_INIT="${RUN_INIT:-1}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\n\033[1;33mWARN: %s\033[0m\n' "$*" >&2; }
die()  { printf '\n\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf '\n\033[1;31mERROR: command failed at line %s: %s\033[0m\n' "${BASH_LINENO[0]:-?}" "${BASH_COMMAND:-?}" >&2
  exit "$exit_code"
}
trap on_error ERR

usage() {
  cat <<EOF
${APP_NAME}

Fedora-only no-snap setup for ThinkPad P50 / Validity VFS7500 138a:0090.

Usage:
  sudo ./${APP_NAME}.sh [options]

Options:
  -y, --yes       Do not ask before running destructive sensor initialization
  --skip-init     Install tools/driver/wrappers only; do not initialize sensor
  -h, --help      Show this help

Environment overrides:
  ASSUME_YES=1
  RUN_INIT=0
  INIT_REPO_URL=https://github.com/vdarkobar/python-validity.git
  INIT_REPO_REF=<branch|tag|commit>

Manual firmware fallback:
  If Lenovo's official URL is unavailable, place this file before rerunning:
    ${LOCAL_FW_PATH}

EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)
        ASSUME_YES=1
        shift
        ;;
      --skip-init)
        RUN_INIT=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run as root, for example: sudo ./${APP_NAME}.sh"
  fi
}

require_fedora() {
  [[ -r /etc/os-release ]] || die "/etc/os-release not found"
  # shellcheck disable=SC1091
  source /etc/os-release

  if [[ "${ID:-}" != "${SUPPORTED_DISTRO_ID}" ]]; then
    die "This script is Fedora-only. Detected: ${PRETTY_NAME:-unknown}"
  fi

  log "Detected Fedora: ${PRETTY_NAME:-Fedora}"
}

ensure_lsusb() {
  if ! command -v lsusb >/dev/null 2>&1; then
    log "Installing usbutils so the fingerprint sensor can be checked"
    dnf install -y usbutils
  fi
}

require_sensor() {
  ensure_lsusb

  local sensor_line
  sensor_line="$(lsusb | grep -Ei 'validity|synaptics|138a' || true)"

  if ! lsusb | grep -q "${SENSOR_USB_ID}"; then
    printf '\nDetected fingerprint-related USB devices:\n%s\n' "${sensor_line:-none}"
    die "This script only supports Validity/Synaptics VFS7500 USB ID ${SENSOR_USB_ID}. Refusing to continue."
  fi

  log "Detected supported fingerprint sensor"
  lsusb | grep "${SENSOR_USB_ID}"
}

confirm_destructive_init() {
  if [[ "${RUN_INIT}" != "1" ]]; then
    warn "Sensor initialization skipped because RUN_INIT=0 / --skip-init was used."
    return 0
  fi

  cat <<EOF

This will factory-reset and pair the ${SENSOR_USB_ID} fingerprint sensor with this laptop.

This is required for the VFS0090 driver, but it is a destructive sensor-side
initialization step. It should only be run on the intended ThinkPad/workstation.

Official Lenovo firmware source checked by this script:
  ${LENOVO_DRIVER_URL}

Firmware expected inside Lenovo package:
  ${LENOVO_FW_NAME}

If the official Lenovo URL is unavailable, the script will look for a manually
provided firmware file here:
  ${LOCAL_FW_PATH}

EOF

  if [[ "${ASSUME_YES}" == "1" ]]; then
    warn "ASSUME_YES=1 set; continuing without interactive confirmation."
    return 0
  fi

  local answer
  read -r -p "Continue with sensor factory-reset/pairing? [y/N] " answer
  case "${answer}" in
    y|Y|yes|YES)
      ;;
    *)
      die "Cancelled by user."
      ;;
  esac
}

stop_conflicting_services() {
  log "Stopping fingerprint services that may hold the USB device"
  systemctl stop fprintd.service python3-validity.service open-fprintd.service 2>/dev/null || true
  systemctl stop open-fprintd-suspend.service open-fprintd-resume.service 2>/dev/null || true
  pkill -f 'fprintd|python3-validity|open-fprintd|validitysensor|validity-sensors' 2>/dev/null || true
}

remove_conflicting_stack() {
  log "Removing conflicting python-validity/open-fprintd packages if present"
  systemctl disable --now python3-validity.service open-fprintd.service open-fprintd-suspend.service open-fprintd-resume.service 2>/dev/null || true
  dnf remove -y python3-validity open-fprintd fprintd-clients fprintd-clients-pam 2>/dev/null || true
}

install_fedora_packages() {
  log "Installing Fedora packages and libfprint-vfs0090 driver"

  dnf install -y \
    dnf-plugins-core \
    git \
    usbutils \
    curl \
    wget \
    p7zip \
    p7zip-plugins \
    gcc \
    gmp-devel \
    libusb1-devel \
    python3 \
    python3-devel \
    python3-pip \
    python3-virtualenv \
    fprintd \
    fprintd-pam

  dnf -y copr enable coldcarti/libfprint-vfs0090
  dnf install -y libfprint-vfs0090 fprintd fprintd-pam --allowerasing

  # Restore Fedora's packaged fprintd files after any old open-fprintd pollution.
  dnf reinstall -y fprintd fprintd-pam
}

clone_initializer_source() {
  log "Installing initializer source from ${INIT_REPO_URL}"

  rm -rf "${SRC_DIR}"
  mkdir -p "${BASE_DIR}"

  if [[ -n "${INIT_REPO_REF}" ]]; then
    git init "${SRC_DIR}"
    git -C "${SRC_DIR}" remote add origin "${INIT_REPO_URL}"
    git -C "${SRC_DIR}" fetch --depth 1 origin "${INIT_REPO_REF}"
    git -C "${SRC_DIR}" checkout --detach FETCH_HEAD
  else
    git clone --depth 1 "${INIT_REPO_URL}" "${SRC_DIR}"
  fi

  [[ -f "${SRC_DIR}/validity-sensors-tools" ]] || die "validity-sensors-tools not found in ${SRC_DIR}"
  [[ -d "${SRC_DIR}/proto9x" ]] || die "proto9x/ not found in ${SRC_DIR}"

  chmod +x "${SRC_DIR}/validity-sensors-tools"
}

create_venv() {
  log "Creating Python virtual environment"

  rm -rf "${VENV_DIR}"
  python3 -m venv "${VENV_DIR}"
  "${VENV_DIR}/bin/python" -m pip install -U pip setuptools wheel
  "${VENV_DIR}/bin/pip" install pyusb pycryptodome fastecdsa

  mkdir -p "${STATE_DIR}" "${COMMON_DIR}" "${FIRMWARE_DIR}"
}

patch_time_clock() {
  log "Patching old Python time.clock() usage"

  find "${SRC_DIR}" -type f \( \
    -name "*.py" -o \
    -name "validity-sensors-tools" -o \
    -path "*/Crypto/Random/*" \
  \) -print0 | xargs -0 sed -i -E \
    -e 's/time\.clock\(\)/time.perf_counter()/g' \
    -e 's/time\.clock/time.perf_counter/g' \
    -e 's/from time import clock/from time import perf_counter as clock/g'
}

patch_flash_already_partitioned() {
  log "Patching flash-already-partitioned behavior"

  "${VENV_DIR}/bin/python" <<PY
from pathlib import Path
import re

p = Path("${SRC_DIR}/proto9x/init_flash.py")
if not p.exists():
    raise SystemExit(f"Missing expected file: {p}")

s = p.read_text()
s2 = re.sub(
    r"^(\s*)raise Exception\('Flash is already partitioned'\)",
    r"\1print('Flash is already partitioned; continuing')\n\1return",
    s,
    flags=re.MULTILINE,
)

if s2 != s:
    p.write_text(s2)
    print(f"Patched {p}")
else:
    print("Flash partition patch target not found or already patched")
PY
}

patch_fastecdsa() {
  log "Patching fastecdsa compatibility for old prehashed hex-string call"

  "${VENV_DIR}/bin/python" <<'PY'
from pathlib import Path
import fastecdsa.ecdsa as ecdsa

p = Path(ecdsa.__file__)
s = p.read_text()

if "from binascii import hexlify" in s and "unhexlify" not in s:
    s = s.replace(
        "from binascii import hexlify",
        "from binascii import hexlify, unhexlify"
    )

old = """if prehashed:
        if not isinstance(msg, (bytes, bytearray)):
            raise TypeError(f"Prehashed message must be bytes, got {type(msg)}")"""

new = """if prehashed:
        if isinstance(msg, str):
            try:
                msg = unhexlify(msg)
            except Exception:
                msg = msg.encode()
        if not isinstance(msg, (bytes, bytearray)):
            raise TypeError(f"Prehashed message must be bytes, got {type(msg)}")"""

if old in s:
    s = s.replace(old, new)
    p.write_text(s)
    print(f"Patched {p}")
else:
    print("fastecdsa patch target not found or already patched")
PY
}

apply_patches() {
  patch_time_clock
  patch_flash_already_partitioned
  patch_fastecdsa
}

write_wrappers() {
  log "Installing helper wrappers"

  cat > /usr/local/bin/vfs0090-tool <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

BASE_DIR="${BASE_DIR}"
SRC_DIR="${SRC_DIR}"
VENV_DIR="${VENV_DIR}"
STATE_DIR="${STATE_DIR}"
COMMON_DIR="${COMMON_DIR}"

TOOL="\${1:-}"
if [[ -z "\${TOOL}" ]]; then
  cat <<'USAGE'
Usage:
  sudo vfs0090-tool <tool>

Tools:
  initializer
  factory-reset
  flash-firmware
  pair
  calibrate
  dump-db
  erase-db
  led-dance

Aliases:
  init        -> initializer
  reset       -> factory-reset
  led         -> led-dance
  led-test    -> led-dance
USAGE
  exit 2
fi
shift || true

case "\${TOOL}" in
  init) TOOL="initializer" ;;
  reset) TOOL="factory-reset" ;;
  led|led-test) TOOL="led-dance" ;;
  initializer|factory-reset|flash-firmware|pair|calibrate|dump-db|erase-db|led-dance)
    ;;
  enroll)
    echo "ERROR: Do not use validity-sensors-tools enroll for 138a:0090. Use fprintd-enroll instead." >&2
    exit 2
    ;;
  *)
    echo "ERROR: unsupported tool: \${TOOL}" >&2
    exit 2
    ;;
esac

exec env -u LD_LIBRARY_PATH -u PYTHONHOME \
  SNAP="\${SRC_DIR}" \
  SNAP_NAME="validity-sensors-tools" \
  SNAP_DATA="\${STATE_DIR}" \
  SNAP_COMMON="\${COMMON_DIR}" \
  PYTHONPATH="\${SRC_DIR}" \
  PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  "\${VENV_DIR}/bin/python" "\${SRC_DIR}/validity-sensors-tools" -t "\${TOOL}" "\$@"
EOF

  chmod +x /usr/local/bin/vfs0090-tool

  cat > /usr/local/bin/vfs0090-init <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/vfs0090-tool initializer "$@"
EOF
  chmod +x /usr/local/bin/vfs0090-init

  cat > /usr/local/bin/vfs0090-led-test <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/vfs0090-tool led-dance "$@"
EOF
  chmod +x /usr/local/bin/vfs0090-led-test

  cat > /usr/local/bin/vfs0090-factory-reset <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/vfs0090-tool factory-reset "$@"
EOF
  chmod +x /usr/local/bin/vfs0090-factory-reset
}

lenovo_firmware_url_available() {
  # Some vendor servers behave differently for HEAD requests, so try HEAD first
  # and then a tiny ranged GET before declaring the URL unavailable.
  curl -fsSIL --max-time 20 "${LENOVO_DRIVER_URL}" >/dev/null 2>&1 \
    || curl -fsSL --max-time 20 --range 0-0 "${LENOVO_DRIVER_URL}" -o /dev/null >/dev/null 2>&1
}

resolve_initializer_firmware_args() {
  INIT_FIRMWARE_ARGS=()

  log "Checking Lenovo firmware source"
  cat <<EOF
Official Lenovo firmware source:
  ${LENOVO_DRIVER_URL}

Firmware expected inside Lenovo package:
  ${LENOVO_FW_NAME}

Local manual firmware path, used only if Lenovo's official download is unavailable:
  ${LOCAL_FW_PATH}
EOF

  local attempt
  for attempt in 1 2 3; do
    if lenovo_firmware_url_available; then
      log "Official Lenovo firmware URL is reachable"
      INIT_FIRMWARE_ARGS=()
      return 0
    fi

    warn "Official Lenovo firmware URL check failed, attempt ${attempt}/3"

    if [[ -s "${LOCAL_FW_PATH}" ]]; then
      log "Using local user-provided firmware file"
      ls -lh "${LOCAL_FW_PATH}"
      INIT_FIRMWARE_ARGS=( -f "${LOCAL_FW_PATH}" )
      return 0
    fi

    if [[ "${attempt}" -lt 3 ]]; then
      warn "Local firmware file not found yet: ${LOCAL_FW_PATH}"
      sleep 2
    fi
  done

  cat <<EOF

Official Lenovo download failed.

Please manually download the Lenovo driver from:
${LENOVO_DRIVER_URL}

Then extract/copy the firmware file and place it here:
${LOCAL_FW_PATH}

Expected firmware filename:
${LENOVO_FW_NAME}

After placing the file, rerun this setup script.

EOF

  die "Lenovo download is unavailable and local firmware file was not found."
}

run_initializer() {
  if [[ "${RUN_INIT}" != "1" ]]; then
    warn "Skipping sensor initialization. Wrappers are installed under /usr/local/bin."
    return 0
  fi

  resolve_initializer_firmware_args
  stop_conflicting_services

  log "Running patched VFS0090 initializer"
  /usr/local/bin/vfs0090-init "${INIT_FIRMWARE_ARGS[@]}"

  log "Running LED test"
  /usr/local/bin/vfs0090-led-test
}

fix_dbus_activation_if_needed() {
  log "Checking D-Bus activation file for stale open-fprintd references"

  # Important: do NOT restart dbus-broker.service or dbus.service here.
  # Restarting the system bus during an active graphical session can black-screen
  # or kill the desktop session. Updating the activation file plus systemd
  # daemon-reload is enough for this installer; if activation still behaves oddly,
  # reboot instead of restarting the system bus live.

  local dbus_file="/usr/share/dbus-1/system-services/net.reactivated.Fprint.service"

  if [[ ! -f "${dbus_file}" ]]; then
    warn "D-Bus activation file missing; writing Fedora fprintd activation file."
    cat > "${dbus_file}" <<'EOF'
[D-BUS Service]
Name=net.reactivated.Fprint
Exec=/usr/libexec/fprintd
User=root
SystemdService=fprintd.service
EOF
  elif grep -q "open-fprintd" "${dbus_file}"; then
    warn "Found stale open-fprintd D-Bus activation file; replacing with Fedora fprintd activation."
    cp -a "${dbus_file}" "${dbus_file}.bak.$(date +%Y%m%d-%H%M%S)"
    cat > "${dbus_file}" <<'EOF'
[D-BUS Service]
Name=net.reactivated.Fprint
Exec=/usr/libexec/fprintd
User=root
SystemdService=fprintd.service
EOF
  else
    log "D-Bus activation file does not reference open-fprintd. Leaving it unchanged."
  fi

  systemctl daemon-reload
}

enable_fingerprint_auth() {
  log "Enabling Fedora fingerprint authentication via authselect"

  if command -v authselect >/dev/null 2>&1; then
    authselect enable-feature with-fingerprint || true
    authselect apply-changes
    authselect current || true
  else
    warn "authselect not found; cannot enable fingerprint PAM integration automatically."
  fi
}

restart_and_probe_fprintd() {
  log "Restarting fprintd and probing device"

  systemctl restart fprintd.service || true
  fprintd-list "${SUDO_USER:-${USER:-root}}" || true
}

final_instructions() {
  local target_user
  target_user="${SUDO_USER:-}"
  if [[ -z "${target_user}" || "${target_user}" == "root" ]]; then
    target_user="$(logname 2>/dev/null || true)"
  fi
  if [[ -z "${target_user}" ]]; then
    target_user="\$USER"
  fi

  cat <<EOF

Setup phase finished.

Installed helper commands:
  sudo vfs0090-init
  sudo vfs0090-led-test
  sudo vfs0090-factory-reset
  sudo vfs0090-tool <initializer|factory-reset|led-dance|calibrate|erase-db>

Do not use validity-sensors-tools enroll for 138a:0090.
Enroll only through fprintd.

Recommended next commands as your normal user:

  fprintd-list "\$USER"
  fprintd-delete "\$USER"
  fprintd-enroll -f right-index-finger "\$USER"
  fprintd-verify "\$USER"

Test sudo/PAM fingerprint prompt:

  sudo -k
  sudo true

Useful diagnostics:

  systemctl status fprintd.service --no-pager
  journalctl -fu fprintd
  cat /usr/share/dbus-1/system-services/net.reactivated.Fprint.service
  authselect current

Target user detected during install: ${target_user}

EOF
}

main() {
  parse_args "$@"
  require_root
  require_fedora
  require_sensor
  confirm_destructive_init
  stop_conflicting_services
  remove_conflicting_stack
  install_fedora_packages
  clone_initializer_source
  create_venv
  apply_patches
  write_wrappers
  run_initializer
  fix_dbus_activation_if_needed
  enable_fingerprint_auth
  restart_and_probe_fprintd
  final_instructions
}

main "$@"
