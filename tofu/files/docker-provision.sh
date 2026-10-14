#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Docker-App: Erststart der Team-VM (von cloud-init aufgerufen)
# Gibt jedem Nutzer einen eigenen rootless Docker-Daemon, einen eigenen
# Portbereich und Zugriff auf den Team-Ordner /srv/team. Idempotent.
#
# Warum rootless: Mitglieder der Gruppe "docker" sind faktisch root
# ("docker run -v /:/host ..."). Ein rootless Daemon laeuft dagegen mit den
# Rechten des Nutzers - Container kommen nicht weiter als der Nutzer selbst.
# -----------------------------------------------------------------------------

USERS_FILE=/etc/docker-app/users
PORTS_FILE=/etc/docker-app/ports
TEAM_GROUP=team
TEAM_DIR=/srv/team
PORT_BASE=8000
PORTS_PER_USER=10

log() { echo "[$(date -Is)] $*"; }

# -----------------------------------------------------------------------------
# [1] AppArmor: rootlesskit braucht User-Namespaces
# -----------------------------------------------------------------------------
# Ubuntu 24.04 sperrt unprivilegierte User-Namespaces per AppArmor. Ohne
# eigenes Profil startet kein rootless Daemon. Neuere Pakete bringen es mit.
if command -v apparmor_parser >/dev/null 2>&1 && ! grep -rqs rootlesskit /etc/apparmor.d/; then
  log "Adding AppArmor profile for rootlesskit..."
  cat >/etc/apparmor.d/usr.bin.rootlesskit <<'EOF'
abi <abi/4.0>,
include <tunables/global>

"/usr/bin/rootlesskit" flags=(unconfined) {
  userns,

  include if exists <local/usr.bin.rootlesskit>
}
EOF
  apparmor_parser -r /etc/apparmor.d/usr.bin.rootlesskit
fi

# -----------------------------------------------------------------------------
# [2] Firewall
# -----------------------------------------------------------------------------
# Rootless veroeffentlichte Ports oeffnet rootlesskit als normaler Prozess auf
# dem Host - anders als bei rootful Docker greift ufw hier also wirklich.
log "Configuring ufw..."
ufw allow 22/tcp
ufw allow "${PORT_BASE}:$((PORT_BASE + 999))/tcp"
ufw --force enable

# -----------------------------------------------------------------------------
# [3] Team-Ordner
# -----------------------------------------------------------------------------
getent group "$TEAM_GROUP" >/dev/null || groupadd "$TEAM_GROUP"
install -d -m 2775 -o root -g "$TEAM_GROUP" "$TEAM_DIR"

# -----------------------------------------------------------------------------
# [4] Pro Nutzer: Sub-IDs, Linger, Daemon, Portbereich
# -----------------------------------------------------------------------------
# useradd legt Sub-IDs normalerweise selbst an; fehlen sie, hinten anhaengen.
ensure_subids() {
  local user=$1 file opt start
  for file in /etc/subuid /etc/subgid; do
    grep -q "^${user}:" "$file" && continue
    start=$(awk -F: 'BEGIN { m = 100000 } { e = $2 + $3; if (e > m) m = e } END { print m }' "$file")
    if [ "$file" = /etc/subuid ]; then opt=--add-subuids; else opt=--add-subgids; fi
    usermod "$opt" "${start}-$((start + 65535))" "$user"
  done
}

# Befehl als Nutzer mit dessen systemd-User-Instanz ausfuehren.
as_user() {
  local user=$1 uid home
  shift
  uid=$(id -u "$user")
  home=$(getent passwd "$user" | cut -d: -f6)
  runuser -u "$user" -- env -i \
    HOME="$home" USER="$user" LOGNAME="$user" \
    PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
    XDG_RUNTIME_DIR="/run/user/$uid" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" \
    "$@" </dev/null
}

ports_tmp=$(mktemp)
index=0

# Eigener Deskriptor: runuser & Co. sollen die Nutzerliste nicht mitlesen.
while read -r user <&3; do
  [ -n "$user" ] || continue
  if ! id "$user" >/dev/null 2>&1; then
    log "WARN: Linux-Nutzer $user fehlt, uebersprungen"
    continue
  fi

  log "Setting up $user..."
  uid=$(id -u "$user")
  home=$(getent passwd "$user" | cut -d: -f6)
  group=$(id -gn "$user")

  # Portbereich: reine Absprache, damit sich das Team nicht in die Quere kommt.
  port=$((PORT_BASE + index * PORTS_PER_USER))
  index=$((index + 1))
  echo "$user $port" >>"$ports_tmp"

  usermod -aG "$TEAM_GROUP" "$user"
  ensure_subids "$user"

  # Lernmaterial nachreichen, falls der Nutzer vor /etc/skel/docker-kurs entstand.
  if [ -d /etc/skel/docker-kurs ] && [ ! -e "$home/docker-kurs" ]; then
    cp -r /etc/skel/docker-kurs "$home/docker-kurs"
    chown -R "$user:$group" "$home/docker-kurs"
  fi
  [ -e "$home/team" ] || ln -s "$TEAM_DIR" "$home/team"

  # Docker-Hub-Images ueber den Google-Mirror: alle VMs teilen sich nach
  # aussen wenige Adressen, und Docker Hub drosselt anonyme Pulls pro Adresse.
  install -d -m 0755 -o "$user" -g "$group" "$home/.config" "$home/.config/docker"
  if [ ! -e "$home/.config/docker/daemon.json" ]; then
    echo '{ "registry-mirrors": ["https://mirror.gcr.io"] }' >"$home/.config/docker/daemon.json"
    chown "$user:$group" "$home/.config/docker/daemon.json"
  fi

  # Linger: der Daemon laeuft weiter, auch wenn der Nutzer nicht angemeldet ist.
  loginctl enable-linger "$user"
  systemctl start "user@${uid}.service"
  for _ in $(seq 1 30); do
    [ -S "/run/user/$uid/bus" ] && break
    sleep 1
  done

  if ! as_user "$user" dockerd-rootless-setuptool.sh install; then
    log "ERROR: rootless Docker fuer $user fehlgeschlagen"
    continue
  fi

  ready=false
  for _ in $(seq 1 30); do
    if as_user "$user" docker info >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 2
  done
  if [ "$ready" = true ]; then
    log "$user: Docker laeuft, Ports ${port}-$((port + PORTS_PER_USER - 1))"
  else
    log "ERROR: Docker-Daemon von $user antwortet nicht"
  fi
done 3<"$USERS_FILE"

install -m 0644 "$ports_tmp" "$PORTS_FILE"
rm -f "$ports_tmp"

log "Docker-App bereit."
