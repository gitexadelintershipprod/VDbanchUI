#!/usr/bin/env bash
#
# FINAL v4.3 - Prepare RHEL 9 as Vdbench LINUX SLAVE.
#
# Expected workflow:
#   1) Put this script and all required files in: /root/install
#   2) Run it from /root/install as root:
#        cd /root/install
#        chmod +x ./03-Prepare-Vdbench-Linux-Slave-v4.3.sh
#        ./03-Prepare-Vdbench-Linux-Slave-v4.3.sh
#
# What this script does:
#   - Uses /root/install as the source/staging directory by default, regardless of current working directory.
#   - Creates /opt/install as the permanent install asset directory.
#   - Copies required files from /root/install to /opt/install.
#   - Copies local RPMs to /opt/install and /opt/install/rpms.
#   - Installs/validates SSH, unzip, Java.
#   - Adds the master public key to /root/.ssh/authorized_keys.
#   - Installs Vdbench to /opt/vdbench.
#
# Required source files in /root/install:
#   - vdbench*.zip
#   - master_id_rsa.pub (preferred) or master_id*.pub / *.pub
#
# Optional source files in /root/install:
#   - *.rpm
#   - rpms/*.rpm
#   - java/*
#
# Offline/template mode is DEFAULT.
#   ./03-Prepare-Vdbench-Linux-Slave-v4.3.sh
#
# Optional online/repo mode, only if explicitly needed:
#   OFFLINE_ONLY=0 ./03-Prepare-Vdbench-Linux-Slave-v4.3.sh
#
# Keep firewall/SELinux unchanged:
#   KEEP_FIREWALL_ENABLED=1 KEEP_SELINUX_ENFORCING=1 ./03-Prepare-Vdbench-Linux-Slave-v4.3.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_DIR="$(pwd)"

# Source/staging directory. If the script is in /root/install, this becomes /root/install.
SOURCE_DIR="${SOURCE_DIR:-/root/install}"

# Permanent install asset directory.
INSTALL_DIR="${INSTALL_DIR:-/opt/install}"
RPM_DIR="${RPM_DIR:-$INSTALL_DIR/rpms}"
VDBENCH_ROOT="${VDBENCH_ROOT:-/opt/vdbench}"

MASTER_PUBLIC_KEY_FILE="${MASTER_PUBLIC_KEY_FILE:-}"
OFFLINE_ONLY="${OFFLINE_ONLY:-1}"
KEEP_FIREWALL_ENABLED="${KEEP_FIREWALL_ENABLED:-0}"
KEEP_SELINUX_ENFORCING="${KEEP_SELINUX_ENFORCING:-0}"

LOG_DIR="$INSTALL_DIR/logs"
LOG_FILE=""

step() {
  echo
  echo "================================================================"
  echo "[$(date '+%F %T')] $*"
  echo "================================================================"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

run_cmd() {
  echo "+ $*"
  "$@"
}

init_logging() {
  mkdir -p "$LOG_DIR"
  LOG_FILE="$LOG_DIR/prepare-linux-slave-$(hostname)-$(date +%Y%m%d_%H%M%S).log"
  touch "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    die "Run this script as root."
  fi
}

require_rhel_like() {
  if [[ ! -f /etc/os-release ]]; then
    die "/etc/os-release not found. Cannot identify OS."
  fi

  # RHEL/Rocky/Alma/Oracle Linux are expected. Do not hard-fail only because ID differs.
  echo "OS release:"
  cat /etc/os-release || true

  command -v dnf >/dev/null 2>&1 || die "dnf not found. This script is intended for RHEL 9-compatible systems."
}

copy_file_if_exists() {
  local src="$1"
  local dst_dir="$2"

  [[ -f "$src" ]] || return 0
  mkdir -p "$dst_dir"
  local dst="$dst_dir/$(basename "$src")"

  # If source and destination are the same physical file, do nothing.
  # This allows safe reruns from /opt/install after files have already been staged.
  if [[ -e "$dst" ]] && [[ "$(readlink -f "$src")" == "$(readlink -f "$dst")" ]]; then
    return 0
  fi

  cp -f "$src" "$dst_dir/"
}

stage_install_assets() {
  step "Staging files from $SOURCE_DIR to $INSTALL_DIR"

  [[ -d "$SOURCE_DIR" ]] || die "SOURCE_DIR does not exist: $SOURCE_DIR"

  mkdir -p "$INSTALL_DIR" "$RPM_DIR" "$LOG_DIR"

  shopt -s nullglob

  local copied=0
  local f

  for f in "$SOURCE_DIR"/vdbench*.zip; do
    copy_file_if_exists "$f" "$INSTALL_DIR"
    copied=1
  done

  for f in "$SOURCE_DIR"/master_id*.pub "$SOURCE_DIR"/*.pub; do
    copy_file_if_exists "$f" "$INSTALL_DIR"
    copied=1
  done

  for f in "$SOURCE_DIR"/*.rpm; do
    copy_file_if_exists "$f" "$INSTALL_DIR"
    copied=1
  done

  if [[ -d "$SOURCE_DIR/rpms" ]]; then
    for f in "$SOURCE_DIR"/rpms/*.rpm; do
      copy_file_if_exists "$f" "$RPM_DIR"
      copied=1
    done
  fi

  if [[ -d "$SOURCE_DIR/java" ]]; then
    mkdir -p "$INSTALL_DIR/java"
    cp -a "$SOURCE_DIR/java"/. "$INSTALL_DIR/java"/ || true
    copied=1
  fi

  # Keep a copy of the exact script used.
  copy_file_if_exists "$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")" "$INSTALL_DIR"

  shopt -u nullglob

  [[ "$copied" -eq 1 ]] || die "No install assets were copied from $SOURCE_DIR. Check the directory content."

  echo "Staged files in $INSTALL_DIR:"
  find "$INSTALL_DIR" -maxdepth 2 -type f | sort | sed 's/^/  /'
}

find_first_file() {
  local base_dir="$1"
  local pattern="$2"

  find "$base_dir" -maxdepth 1 -type f -name "$pattern" | sort | head -n 1
}

precheck_required_assets() {
  step "Checking required assets in $INSTALL_DIR"

  local vdbench_zip
  vdbench_zip="$(find_first_file "$INSTALL_DIR" 'vdbench*.zip')"
  [[ -n "$vdbench_zip" ]] || die "Vdbench zip not found in $INSTALL_DIR. Expected vdbench*.zip"
  echo "OK: Vdbench zip -> $vdbench_zip"

  if [[ -z "$MASTER_PUBLIC_KEY_FILE" ]]; then
    MASTER_PUBLIC_KEY_FILE="$(find_first_file "$INSTALL_DIR" 'master_id_rsa.pub')"
    if [[ -z "$MASTER_PUBLIC_KEY_FILE" ]]; then
      MASTER_PUBLIC_KEY_FILE="$(find_first_file "$INSTALL_DIR" 'master_id*.pub')"
    fi
    if [[ -z "$MASTER_PUBLIC_KEY_FILE" ]]; then
      MASTER_PUBLIC_KEY_FILE="$(find_first_file "$INSTALL_DIR" '*.pub')"
    fi
  fi

  [[ -n "$MASTER_PUBLIC_KEY_FILE" ]] || die "Master public key not found in $INSTALL_DIR. Expected master_id_rsa.pub (or legacy master_id_ed25519.pub / *.pub)"
  [[ -f "$MASTER_PUBLIC_KEY_FILE" ]] || die "Master public key file not found: $MASTER_PUBLIC_KEY_FILE"
  echo "OK: Master public key -> $MASTER_PUBLIC_KEY_FILE"
}

command_exists_or_path() {
  local cmd="$1"

  command -v "$cmd" >/dev/null 2>&1 && return 0

  case "$cmd" in
    sshd) [[ -x /usr/sbin/sshd ]] && return 0 ;;
  esac

  return 1
}

collect_local_rpms() {
  # Collect RPM files without passing duplicate packages to dnf.
  # The same RPM may exist both in /opt/install and /opt/install/rpms
  # after staging. Passing both paths to dnf causes @commandline conflicts.
  shopt -s nullglob
  local -a files=("$RPM_DIR"/*.rpm "$INSTALL_DIR"/*.rpm)
  shopt -u nullglob

  if [[ "${#files[@]}" -eq 0 ]]; then
    return 1
  fi

  declare -A seen_rpm
  local f base rpm_id

  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"

    # Prefer RPM metadata for deduplication. Fall back to filename if rpm -qp fails.
    rpm_id="$(rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}' "$f" 2>/dev/null || true)"
    [[ -n "$rpm_id" ]] || rpm_id="$base"

    if [[ -n "${seen_rpm[$rpm_id]:-}" ]]; then
      echo "Skipping duplicate RPM: $f (already using ${seen_rpm[$rpm_id]})" >&2
      continue
    fi

    seen_rpm[$rpm_id]="$f"
    printf '%s\n' "$f"
  done | sort
}
install_local_rpms_if_available() {
  step "Checking local RPM bundle"

  local -a rpm_files=()
  mapfile -t rpm_files < <(collect_local_rpms || true)

  if [[ "${#rpm_files[@]}" -eq 0 ]]; then
    echo "No local RPMs found in:"
    echo "  $INSTALL_DIR/*.rpm"
    echo "  $RPM_DIR/*.rpm"
    return 1
  fi

  echo "Local RPMs found:"
  printf '  %s\n' "${rpm_files[@]}"

  run_cmd dnf install -y --disablerepo='*' "${rpm_files[@]}"
}

install_packages() {
  step "Installing/checking required packages"

  local missing=0
  local cmd

  for cmd in ssh systemctl sshd unzip java; do
    if ! command_exists_or_path "$cmd"; then
      echo "Missing command: $cmd"
      missing=1
    fi
  done

  if [[ "$missing" -eq 0 ]]; then
    echo "All required commands already exist."
    java --version || java -version || true
    return
  fi

  if [[ "$OFFLINE_ONLY" == "1" ]]; then
    install_local_rpms_if_available || die "Offline/template package install failed. Check the dnf error above and verify the local RPM bundle in /root/install and /root/install/rpms."
  else
    if install_local_rpms_if_available; then
      echo "Local RPM install completed."
    else
      echo "OFFLINE_ONLY=0 was explicitly set and no local RPM bundle was found. Trying dnf repositories."
      run_cmd dnf install -y unzip openssh-server openssh-clients
      if ! command -v java >/dev/null 2>&1; then
        run_cmd dnf install -y java-11-openjdk-headless || run_cmd dnf install -y java-17-openjdk-headless
      fi
    fi
  fi

  for cmd in ssh systemctl sshd unzip java; do
    command_exists_or_path "$cmd" || die "Required command still missing after install: $cmd"
    if command -v "$cmd" >/dev/null 2>&1; then
      echo "OK: $cmd -> $(command -v "$cmd")"
    elif [[ "$cmd" == "sshd" && -x /usr/sbin/sshd ]]; then
      echo "OK: sshd -> /usr/sbin/sshd"
    fi
  done

  java --version || java -version
}

disable_power_saving() {
  step "Disabling common power-saving items"

  systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true

  if command -v tuned-adm >/dev/null 2>&1; then
    tuned-adm profile throughput-performance 2>/dev/null || true
  fi

  echo "Power-saving configuration attempted."
}

disable_firewall_selinux() {
  if [[ "$KEEP_FIREWALL_ENABLED" != "1" ]]; then
    step "Disabling firewalld"
    systemctl stop firewalld 2>/dev/null || true
    systemctl disable firewalld 2>/dev/null || true
    echo "firewalld disabled where present."
  else
    step "Keeping firewalld enabled and allowing SSH"
    if command -v firewall-cmd >/dev/null 2>&1; then
      firewall-cmd --permanent --add-service=ssh || true
      firewall-cmd --reload || true
    fi
  fi

  if [[ "$KEEP_SELINUX_ENFORCING" != "1" ]]; then
    step "Setting SELinux to permissive"
    setenforce 0 2>/dev/null || true
    if [[ -f /etc/selinux/config ]]; then
      sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
    fi
    echo "SELinux set to permissive where possible."
  else
    step "Keeping SELinux enforcing"
  fi
}

sshd_bin() {
  if command -v sshd >/dev/null 2>&1; then
    command -v sshd
  else
    echo /usr/sbin/sshd
  fi
}

configure_sshd() {
  step "Configuring sshd for root login and public key auth"

  mkdir -p /etc/ssh/sshd_config.d /run/sshd
  chmod 755 /run/sshd

  cat >/etc/ssh/sshd_config.d/99-vdbench-lab.conf <<'SSHD_EOF'
# Vdbench lab configuration
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
StrictModes yes
AuthorizedKeysFile .ssh/authorized_keys
SSHD_EOF

  local sshd_path
  sshd_path="$(sshd_bin)"

  "$sshd_path" -t || die "sshd configuration test failed."

  systemctl enable --now sshd
  systemctl restart sshd

  echo
  echo "Effective sshd settings:"
  local sshd_effective
  sshd_effective="$($sshd_path -T)"

  printf '%s\n' "$sshd_effective" | grep -E '^(permitrootlogin|pubkeyauthentication|passwordauthentication|authorizedkeysfile|strictmodes) ' || true

  grep -qi '^permitrootlogin yes$' <<<"$sshd_effective" || die "Effective sshd setting is not 'PermitRootLogin yes'."
  grep -qi '^pubkeyauthentication yes$' <<<"$sshd_effective" || die "Effective sshd setting is not 'PubkeyAuthentication yes'."

  systemctl --no-pager --full status sshd || true
}

normalize_master_public_key() {
  local src="$1"
  local dst="$2"

  [[ -f "$src" ]] || die "Master public key not found: $src"
  [[ -s "$src" ]] || die "Master public key file is empty: $src"

  tr -d '\r' < "$src" \
    | awk '
        /^ssh-(rsa|ed25519|ecdsa-sha2-nistp[0-9]+)[[:space:]]/ { print; found=1 }
        END { if (!found) exit 2 }
      ' > "$dst" || die "Invalid public key content in $src"

  [[ -s "$dst" ]] || die "Normalized public key became empty."

  ssh-keygen -lf "$dst" >/dev/null 2>&1 || die "ssh-keygen cannot read normalized public key: $dst"
}

add_master_public_key() {
  step "Adding Master public key to /root/.ssh/authorized_keys"

  local tmp_key
  tmp_key="$(mktemp)"
  normalize_master_public_key "$MASTER_PUBLIC_KEY_FILE" "$tmp_key"

  echo "Master public key fingerprint:"
  ssh-keygen -lf "$tmp_key"

  mkdir -p /root/.ssh
  chmod 700 /root/.ssh
  chown root:root /root/.ssh

  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  chown root:root /root/.ssh/authorized_keys

  cp -a /root/.ssh/authorized_keys "/root/.ssh/authorized_keys.backup.$(date +%Y%m%d_%H%M%S)" || true

  if grep -qxF "$(cat "$tmp_key")" /root/.ssh/authorized_keys; then
    echo "Master public key already exists in authorized_keys."
  else
    cat "$tmp_key" >> /root/.ssh/authorized_keys
    echo >> /root/.ssh/authorized_keys
    echo "Master public key appended to authorized_keys."
  fi

  restorecon -Rv /root/.ssh 2>/dev/null || true

  echo
  echo "Authorized keys fingerprints:"
  ssh-keygen -lf /root/.ssh/authorized_keys || true

  echo
  echo "Authorized keys permissions:"
  ls -ld /root/.ssh
  ls -l /root/.ssh/authorized_keys

  rm -f "$tmp_key"

  systemctl restart sshd
}

install_vdbench() {
  step "Installing Vdbench to $VDBENCH_ROOT"

  local zip_file
  zip_file="$(find_first_file "$INSTALL_DIR" 'vdbench*.zip')"
  [[ -n "$zip_file" ]] || die "Vdbench zip not found in $INSTALL_DIR. Expected vdbench*.zip"

  echo "Using Vdbench zip: $zip_file"

  local tmp_dir
  tmp_dir="$(mktemp -d)"

  unzip -q "$zip_file" -d "$tmp_dir"

  local vdbench_bin
  vdbench_bin="$(find "$tmp_dir" -type f -name vdbench | head -n 1 || true)"

  if [[ -z "$vdbench_bin" ]]; then
    rm -rf "$tmp_dir"
    die "vdbench executable not found inside $zip_file"
  fi

  local source_root
  source_root="$(dirname "$vdbench_bin")"

  rm -rf "$VDBENCH_ROOT"
  mkdir -p "$VDBENCH_ROOT"
  cp -a "$source_root"/. "$VDBENCH_ROOT"/

  chmod +x "$VDBENCH_ROOT/vdbench" || true
  mkdir -p "$VDBENCH_ROOT/cfg" "$VDBENCH_ROOT/output"

  rm -rf "$tmp_dir"

  [[ -x "$VDBENCH_ROOT/vdbench" ]] || die "Vdbench install failed. Missing executable: $VDBENCH_ROOT/vdbench"

  echo "Vdbench installed in $VDBENCH_ROOT"
}

create_local_smoke_config() {
  step "Creating local Vdbench smoke config"

  mkdir -p "$VDBENCH_ROOT/cfg"

  cat >"$VDBENCH_ROOT/cfg/local_smoke_readonly.cfg" <<'CFG_EOF'
* Local read-only smoke test
* Change /dev/sdb if your test disk is different.
* Do NOT use the OS disk.

sd=sd1,lun=/dev/sdb,threads=4,size=1g
wd=wd1,sd=sd1,xfersize=4k,rdpct=100,seekpct=100
rd=rd1,wd=wd1,iorate=100,elapsed=60,interval=1
CFG_EOF

  echo "Created: $VDBENCH_ROOT/cfg/local_smoke_readonly.cfg"
}

show_validation() {
  step "Running local validation"

  echo
  echo "hostname:"
  hostname

  echo
  echo "ip addresses:"
  hostname -I 2>/dev/null || true

  echo
  echo "java --version:"
  java --version || java -version

  echo
  echo "ssh -V:"
  ssh -V 2>&1 || true

  echo
  echo "sshd effective config:"
  "$(sshd_bin)" -T | grep -E '^(permitrootlogin|pubkeyauthentication|passwordauthentication|authorizedkeysfile|strictmodes) ' || true

  echo
  echo "sshd service:"
  systemctl --no-pager --full status sshd || true

  echo
  echo "Vdbench local test:"
  "$VDBENCH_ROOT/vdbench" -t

  step "Disk list"
  lsblk -o NAME,TYPE,SIZE,MODEL,SERIAL,ROTA,MOUNTPOINTS || true

  echo
  echo "Vdbench LINUX SLAVE is prepared."
  echo
  echo "From MASTER test:"
  echo "  ssh root@<linux-slave-ip> hostname"
  echo "  ssh root@<linux-slave-ip> java --version"
  echo "  ssh root@<linux-slave-ip> $VDBENCH_ROOT/vdbench -t"
  echo
  echo "Vdbench path for distributed config:"
  echo "  vdbench=$VDBENCH_ROOT"
  echo
  echo "Linux raw disk example:"
  echo "  lun=/dev/sdb"
  echo
  echo "Log file:"
  echo "  $LOG_FILE"
}

main() {
  require_root

  mkdir -p "$INSTALL_DIR"
  init_logging

  step "Starting Vdbench LINUX SLAVE preparation FINAL v4.3 - offline default"
  echo "RUN_DIR=$RUN_DIR"
  echo "SCRIPT_DIR=$SCRIPT_DIR"
  echo "SOURCE_DIR=$SOURCE_DIR"
  echo "INSTALL_DIR=$INSTALL_DIR"
  echo "RPM_DIR=$RPM_DIR"
  echo "VDBENCH_ROOT=$VDBENCH_ROOT"
  echo "OFFLINE_ONLY=$OFFLINE_ONLY"
  echo "HOSTNAME=$(hostname)"

  require_rhel_like
  stage_install_assets
  precheck_required_assets

  install_packages
  disable_power_saving
  disable_firewall_selinux
  configure_sshd
  add_master_public_key
  install_vdbench
  create_local_smoke_config
  show_validation

  step "DONE"
  echo "Reboot this Linux slave before final testing if SELinux/firewall/power settings changed."
}

main "$@"
