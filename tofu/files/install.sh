#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# Docker-App: Software installieren (beim ersten Boot, als root)
# Installiert Docker Engine samt rootless-Extras, Compose und Buildx sowie
# lazydocker. Die Daemons der Nutzer richtet danach docker-provision.sh ein.
# -----------------------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive

echo "Updating package lists..."
apt-get update -y
apt-get install -y curl wget git vim nano htop jq tree bash-completion ufw ca-certificates \
  uidmap dbus-user-session slirp4netns systemd-container

# -----------------------------------------------------------------------------
# [1] Docker Engine aus dem offiziellen Repository
# -----------------------------------------------------------------------------
echo "Adding the Docker apt repository..."
install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# shellcheck disable=SC1091 # zur Laufzeit auf der VM vorhanden
codename=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
arch=$(dpkg --print-architecture)
echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" \
  >/etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras

# Der systemweite Daemon bleibt aus: Nutzer arbeiten nur mit ihrem eigenen.
echo "Disabling the rootful Docker daemon..."
systemctl disable --now docker.service docker.socket containerd.service

docker --version
docker compose version

# -----------------------------------------------------------------------------
# [2] lazydocker (Terminal-Oberflaeche, wie k9s fuer Kubernetes)
# -----------------------------------------------------------------------------
# Optional: scheitert der Download, laeuft die Einrichtung trotzdem weiter.
install_lazydocker() {
  local tag ver larch
  case "$arch" in
    amd64) larch=x86_64 ;;
    arm64) larch=arm64 ;;
    *) return 1 ;;
  esac
  # Innerhalb von "|| ..." greift set -e nicht - daher jeder Schritt mit return.
  tag=$(curl -fsSL https://api.github.com/repos/jesseduffield/lazydocker/releases/latest | jq -r .tag_name) || return 1
  [ -n "$tag" ] && [ "$tag" != null ] || return 1
  ver=${tag#v}
  curl -fsSL "https://github.com/jesseduffield/lazydocker/releases/download/${tag}/lazydocker_${ver}_Linux_${larch}.tar.gz" |
    tar -xz -C /usr/local/bin lazydocker || return 1
  chmod 0755 /usr/local/bin/lazydocker
}

echo "Installing lazydocker..."
install_lazydocker || echo "WARN: lazydocker konnte nicht installiert werden"

apt-get clean
echo "Installation finished."
