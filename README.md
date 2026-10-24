# Docker-App

Eine Docker-Lernumgebung für Hochschulkurse. Jedes Team bekommt eine
**eigene VM**. Jedes Teammitglied meldet sich per SSH an und hat dort einen
**eigenen Docker-Daemon** (rootless): eigene Images, eigene Container, eigene
Netze – ohne root-Rechte auf der VM.

## Vorinstallierte Software

- Docker Engine (offizielles Repository) im rootless-Modus
- Docker Compose und Buildx (CLI-Plugins, Alias `dc` für `docker compose`)
- lazydocker (Terminal-Oberfläche)
- Git, curl, jq, tree, vim, nano, htop

## Lernverzeichnis

Jeder Nutzer findet nach dem Login unter `~/docker-kurs/` folgende Struktur:

    ~/docker-kurs/
    ├── LIES_MICH.txt            ← Kurzreferenz und erste Schritte
    └── beispiele/
        ├── 01-webseite/         ← eigenes Image mit Dockerfile (nginx)
        ├── 02-compose/          ← Web-App + Redis mit Docker Compose
        └── 03-multistage/       ← Multi-Stage-Build (Go → scratch)

## User-Management

- **Ein Account pro Nutzer**, abgeleitet aus der E-Mail-Adresse
  (z. B. `anna.schulz@dhbw.de` → Benutzername `annaschulz`)
- Jeder Nutzer erhält ein zufälliges Passwort, Login per SSH mit Passwort
- Kein `sudo` und **keine Gruppe `docker`**: Wer Zugriff auf den
  systemweiten Daemon hat, ist faktisch root (`docker run -v /:/host …`).
  Der systemweite Daemon ist deshalb abgeschaltet. Stattdessen läuft pro
  Nutzer ein rootless Daemon als systemd-User-Dienst (mit Linger, läuft also
  auch ohne aktive Sitzung weiter).
- Gemeinsamer Team-Ordner `/srv/team` (Link `~/team`), Gruppe `team`

### Portbereiche

Alle Teammitglieder teilen sich die Ports der VM. Damit niemand dem anderen
einen Port wegnimmt, bekommt jeder einen Bereich von 10 Ports ab 8000
(1. Nutzer 8000–8009, 2. Nutzer 8010–8019, …). Der erste Port steht in
`$MEIN_PORT`, die Liste aller Bereiche in `/etc/docker-app/ports`. Das ist
eine Absprache, keine technische Sperre.

## VM-Deployment

| | |
|---|---|
| VMs | **eine VM pro Team**, ein Docker-Daemon pro Nutzer |
| Flavor | im Wizard wählbar, Standard `gp1.small` |
| Betriebssystem | Ubuntu 24.04, Software wird beim ersten Boot per cloud-init installiert |
| Erreichbarkeit | SSH auf Port 22, wählbar über IPv6 (Standard), IPv4 oder beides |
| Offene Ports | 22 (SSH), 8000–8999 (veröffentlichte Container-Ports) |
| Bereit nach | ca. 4–5 Minuten nach dem Start der VM |
| Obergrenze | `max_teams`, Standard 15 Team-VMs pro Deployment |

Ob die Ports 8000–8999 tatsächlich von außen erreichbar sind, hängt
zusätzlich von der gewählten Security Group ab.

Images von Docker Hub werden über `mirror.gcr.io` bezogen
(`~/.config/docker/daemon.json`), weil Docker Hub anonyme Pulls pro Adresse
drosselt und alle VMs nach außen wenige Adressen teilen. Fehlt ein Image im
Mirror, fällt Docker automatisch auf Docker Hub zurück.

## Konfigurierbare Variablen

| Variable | Wizard-Feld | Standard |
|---|---|---|
| `image_name` | Image-Auswahl | `Ubuntu 24.04` |
| `ip_mode` | Adressfamilie: `ipv4`, `ipv6` oder `dual` | `ipv6` |
| `network_uuid` | Netz mit öffentlicher IPv6, für `ipv6` und `dual` | DHBWV6-Netz |
| `network_v4_uuid` | Netz mit öffentlich gerouteter IPv4, für `ipv4` und `dual` | leer |
| `shared_secgroup_id` | Security-Group-Auswahl | gemeinsame App-Store-SG |
| `flavor_name` | Flavor-Auswahl | `gp1.small` |
| `floating_ip_pool` | External-Network-Auswahl (derzeit ungenutzt) | `DHBW` |
| `max_teams` | Obergrenze | `15` |

`users` setzt der AppStore selbst.

Jeder Nutzer speichert seine Images getrennt (`~/.local/share/docker`).
Bei großen Teams oder großen Images einen Flavor mit mehr Platte wählen.

## Adressfamilie (`ip_mode`)

| `ip_mode` | Schnittstellen | Zugangsdaten nennen |
|---|---|---|
| `ipv6` (Standard) | eine, im Netz `network_uuid` | die IPv6 |
| `ipv4` | eine, im Netz `network_v4_uuid` | die IPv4 |
| `dual` | Hauptschnittstelle in `network_uuid`, zweite in `network_v4_uuid` | die IPv4 |

Wie bei der Ubuntu-App: Bei `dual` hängt OpenTofu die IPv4-Schnittstelle
erst an die laufende VM. cloud-init wartet auf sie und richtet sie mit
eigener Routing-Tabelle über das Gateway des IPv4-Netzes ein, bevor die
Einrichtung startet. Die IPv4 im Netz `DHBWV6` ist eine private
NAT-Adresse; öffentliches IPv4 gibt es nur über ein eigenes IPv4-Netz,
deshalb brauchen `ipv4` und `dual` die Variable `network_v4_uuid`. Eine
eigene Security Group öffnet SSH je gewählter Familie.

Auf newstack erprobt ist bisher nur `ipv6`.

## Aufbau

Reine OpenTofu-App nach ADR 0010: ein Ordner `tofu/`, kein Packer, kein
Image-Bau.

    Docker-App/
    └── tofu/
        ├── main.tofu
        ├── variables.tofu
        ├── outputs.tofu
        ├── cloud-init.yml.tpl        ← legt Nutzer und Dateien an, startet die Skripte
        └── files/
            ├── install.sh            ← installiert Docker, Compose, Buildx, lazydocker
            ├── docker-provision.sh   ← rootless Daemons, Ports, Team-Ordner, Firewall
            ├── profile.sh            ← Alias und $MEIN_PORT
            └── docker-kurs/          ← Lernmaterial (→ /etc/skel)

Beim ersten Boot läuft zuerst `install.sh`, danach `docker-provision.sh`.
Die Skripte gehen gzip-komprimiert in die `user_data` (Limit 64 KB).

## Fehlersuche

Auf der VM (als Admin über die OpenStack-Konsole):

    cat /var/log/docker-provision.log
    cat /etc/docker-app/ports
    systemctl --user -M <benutzer>@ status docker
    journalctl --user -M <benutzer>@ -u docker

## Lokale Checks

    cd tofu && tofu fmt -check && tofu init -backend=false && tofu validate && tofu test
    shellcheck tofu/files/*.sh

`tofu test` mockt alle Provider und braucht keinen OpenStack-Zugang.

## Release

Der AppStore deployt nur Git-Tags im Format `v<Major>.<Minor>.<Patch>`.

### v1.1.0

Adressfamilie wählbar: `ip_mode` mit `ipv4`, `ipv6` oder `dual`, neue
Variable `network_v4_uuid`, eigene SSH-Regel je Familie. Die Adresse in den
Zugangsdaten kommt ohne eckige Klammern. Tests mit gemockten Providern
unter `tofu/tests/`.

### v1.0.0

Erste Version: eine VM pro Team, rootless Docker-Daemon pro Nutzer,
Compose, Buildx und lazydocker vorinstalliert, Portbereiche pro Nutzer,
gemeinsamer Team-Ordner.
