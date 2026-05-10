#!/usr/bin/env bash
set -Eeuo pipefail

# cleanup-thinkpad-vfs0090-fingerprint.sh
# Fedora-only cleanup script for the ThinkPad / Validity VFS0090 138a:0090
# fingerprint setup created by setup.sh.
#
# What it removes:
#   - local VFS0090 helper tools under /opt/vfs0090-tools
#   - wrapper commands under /usr/local/bin/vfs0090-*
#   - temporary patched snap/venv leftovers from earlier manual attempts
#   - libfprint-vfs0090 COPR package
#   - coldcarti/libfprint-vfs0090 COPR repo file
#   - local fprintd fingerprint enrollments/templates
#   - authselect with-fingerprint feature
#   - stale open-fprintd/python-validity packages/services if present
#
# What it does NOT do:
#   - it does not restart dbus-broker.service or dbus.service
#   - it does not factory-reset the fingerprint sensor flash
#   - it does not change BIOS fingerprint settings
#
# Usage:
#   chmod +x cleanup-thinkpad-vfs0090-fingerprint.sh
#   sudo ./cleanup-thinkpad-vfs0090-fingerprint.sh
#
# Non-interactive:
#   sudo ASSUME_YES=1 ./cleanup-thinkpad-vfs0090-fingerprint.sh
#   sudo ./cleanup-thinkpad-vfs0090-fingerprint.sh --yes

APP_NAME="cleanup-thinkpad-vfs0090-fingerprint"
SUPPORTED_DISTRO_ID="fedora"
ASSUME_YES="${ASSUME_YES:-0}"

BASE_DIR="/opt/vfs0090-tools"
COPR_REPO_FILE="/etc/yum.repos.d/_copr:copr.fedorainfracloud.org:coldcarti:libfprint-vfs0090.repo"
DBUS_FILE="/usr/share/dbus-1/system-services/net.reactivated.Fprint.service"

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

Fedora-only cleanup script for the ThinkPad VFS0090 fingerprint setup.

Usage:
  sudo ./${APP_NAME}.sh [options]

Options:
  -y, --yes   Do not ask for confirmation
  -h, --help  Show this help

EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y|--yes)
        ASSUME_YES=1
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
    die "This cleanup script is Fedora-only. Detected: ${PRETTY_NAME:-unknown}"
  fi

  log "Detected Fedora: ${PRETTY_NAME:-Fedora}"
}

detect_target_user() {
  local target="${SUDO_USER:-}"

  if [[ -z "${target}" || "${target}" == "root" ]]; then
    target="$(logname 2>/dev/null || true)"
  fi

  if [[ -z "${target}" || "${target}" == "root" ]]; then
    target=""
  fi

  printf '%s' "${target}"
}

confirm_cleanup() {
  cat <<EOF

This will remove the Fedora VFS0090 fingerprint setup from this laptop.

It will remove:
  - /opt/vfs0090-tools
  - /usr/local/bin/vfs0090-tool
  - /usr/local/bin/vfs0090-init
  - /usr/local/bin/vfs0090-led-test
  - /usr/local/bin/vfs0090-factory-reset
  - temporary /var/tmp and /tmp VFS0090 helper leftovers
  - libfprint-vfs0090 package and COPR repo
  - local fprintd fingerprint enrollments/templates
  - authselect with-fingerprint feature
  - stale open-fprintd/python-validity packages/services if present

It will NOT:
  - restart dbus-broker.service or dbus.service
  - factory-reset the fingerprint sensor flash
  - change BIOS fingerprint settings

EOF

  if [[ "${ASSUME_YES}" == "1" ]]; then
    warn "ASSUME_YES=1 set; continuing without interactive confirmation."
    return 0
  fi

  local answer
  read -r -p "Continue cleanup? [y/N] " answer
  case "${answer}" in
    y|Y|yes|YES)
      ;;
    *)
      die "Cancelled by user."
      ;;
  esac
}

stop_services() {
  log "Stopping fingerprint-related services"

  systemctl stop fprintd.service 2>/dev/null || true
  systemctl stop python3-validity.service open-fprintd.service 2>/dev/null || true
  systemctl stop open-fprintd-suspend.service open-fprintd-resume.service 2>/dev/null || true

  pkill -f 'fprintd|python3-validity|open-fprintd|validitysensor|validity-sensors' 2>/dev/null || true
}

delete_fingerprints() {
  log "Deleting local fprintd fingerprint enrollments/templates"

  local target_user
  target_user="$(detect_target_user)"

  # Try the normal fprintd path first for the invoking user.
  if [[ -n "${target_user}" ]] && command -v fprintd-delete >/dev/null 2>&1; then
    systemctl start fprintd.service 2>/dev/null || true
    fprintd-delete "${target_user}" 2>/dev/null || true
    systemctl stop fprintd.service 2>/dev/null || true
  fi

  # Remove all local fprintd templates. This does not reset sensor firmware/flash.
  rm -rf /var/lib/fprint
}

disable_fingerprint_auth() {
  log "Disabling authselect fingerprint feature if enabled"

  if command -v authselect >/dev/null 2>&1; then
    authselect disable-feature with-fingerprint 2>/dev/null || true
    authselect apply-changes 2>/dev/null || true
    authselect current || true
  else
    warn "authselect not found; skipping PAM feature cleanup."
  fi
}

remove_wrappers_and_tools() {
  log "Removing VFS0090 helper wrappers and local tool directory"

  rm -f \
    /usr/local/bin/vfs0090-tool \
    /usr/local/bin/vfs0090-init \
    /usr/local/bin/vfs0090-led-test \
    /usr/local/bin/vfs0090-factory-reset

  rm -rf "${BASE_DIR}"

  # Leftovers from earlier manual/snap-based experiments.
  rm -rf \
    /var/tmp/vfs0090-venv \
    /var/tmp/validity-sensors-tools-fixed

  rm -f \
    /tmp/run-vfs0090-fixed.sh \
    /tmp/prepare-vfs0090-fixed.sh
}

remove_conflicting_old_stack() {
  log "Removing stale open-fprintd/python-validity stack if present"

  systemctl disable --now python3-validity.service open-fprintd.service open-fprintd-suspend.service open-fprintd-resume.service 2>/dev/null || true
  dnf remove -y python3-validity open-fprintd fprintd-clients fprintd-clients-pam 2>/dev/null || true
}

remove_vfs0090_driver_and_copr() {
  log "Removing libfprint-vfs0090 and COPR repository"

  dnf remove -y libfprint-vfs0090 2>/dev/null || true

  if command -v dnf >/dev/null 2>&1; then
    dnf -y copr disable coldcarti/libfprint-vfs0090 2>/dev/null || true
  fi

  rm -f "${COPR_REPO_FILE}"
}

restore_fprintd_dbus_file_if_fprintd_installed() {
  log "Restoring Fedora fprintd D-Bus activation if fprintd remains installed"

  # Do not restart dbus-broker.service or dbus.service here.
  # If D-Bus activation behaves oddly after cleanup, reboot instead.

  if rpm -q fprintd >/dev/null 2>&1; then
    if [[ -f "${DBUS_FILE}" ]] && grep -q "open-fprintd" "${DBUS_FILE}"; then
      warn "Stale open-fprintd activation found; replacing with Fedora fprintd activation."
      cp -a "${DBUS_FILE}" "${DBUS_FILE}.cleanup-bak.$(date +%Y%m%d-%H%M%S)"
      cat > "${DBUS_FILE}" <<'EOF'
[D-BUS Service]
Name=net.reactivated.Fprint
Exec=/usr/libexec/fprintd
User=root
SystemdService=fprintd.service
EOF
    fi

    # Reinstall fprintd to restore packaged files, but keep it available if Fedora had it.
    dnf reinstall -y fprintd fprintd-pam 2>/dev/null || true
  fi

  systemctl daemon-reload
}

maybe_remove_fprintd_packages() {
  log "Leaving Fedora fprintd/fprintd-pam installed"

  cat <<'EOF'
This cleanup intentionally leaves Fedora's standard fprintd and fprintd-pam
packages installed if present. They are normal distribution packages and may be
used by GNOME/Fedora even without the VFS0090 COPR driver.

If you want to remove them too, run manually:

  sudo dnf remove fprintd fprintd-pam

EOF
}

print_final_state() {
  log "Cleanup complete"

  cat <<'EOF'
Recommended checks:

  rpm -qa | grep -Ei 'fprint|libfprint|validity|open-fprintd|python3-validity'
  ls -lah /opt/vfs0090-tools 2>/dev/null || echo '/opt/vfs0090-tools removed'
  command -v vfs0090-init || echo 'vfs0090-init removed'
  authselect current

A reboot is recommended after cleanup, especially if D-Bus activation was
previously polluted by open-fprintd.

EOF
}

main() {
  parse_args "$@"
  require_root
  require_fedora
  confirm_cleanup

  stop_services
  delete_fingerprints
  disable_fingerprint_auth
  remove_wrappers_and_tools
  remove_conflicting_old_stack
  remove_vfs0090_driver_and_copr
  restore_fprintd_dbus_file_if_fprintd_installed
  maybe_remove_fprintd_packages
  print_final_state
}

main "$@"
