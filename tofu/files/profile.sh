# shellcheck shell=sh
# Docker-App: Komfort fuer alle Login-Shells.
# Wird auch von /bin/sh gelesen - deshalb nur POSIX-Syntax.
alias dc='docker compose'

# Erster Port des eigenen Bereichs (siehe ~/docker-kurs/LIES_MICH.txt).
# Docker Compose liest ihn ebenfalls, z. B. "${MEIN_PORT}:80".
if [ "$(id -u)" -ne 0 ] && [ -r /etc/docker-app/ports ]; then
  MEIN_PORT=$(awk -v u="$(id -un)" '$1 == u { print $2 }' /etc/docker-app/ports)
  if [ -n "$MEIN_PORT" ]; then
    export MEIN_PORT
  else
    unset MEIN_PORT
  fi
fi
