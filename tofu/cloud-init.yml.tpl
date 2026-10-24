#cloud-config

# SSH mit Passwort-Auth aktivieren
ssh_pwauth: true

# Benutzer anlegen - ohne sudo und ohne Gruppe "docker" (die waere root).
# Jeder bekommt einen eigenen rootless Docker-Daemon, siehe docker-provision.sh.
# jsonencode() quotet jeden Wert, damit YAML nichts davon umdeutet.
users:
%{ for user in team_users ~}
  - name: ${jsonencode(user.username)}
    shell: /bin/bash
    lock_passwd: false
%{ endfor ~}

# Passwoerter zwingend ueber jsonencode(): eines, das mit ! @ % oder *
# beginnt, waere als unquotierter Skalar ein YAML-Syntaxfehler.
chpasswd:
  expire: false
  users:
%{ for user in team_users ~}
    - name: ${jsonencode(user.username)}
      password: ${jsonencode(user.password)}
      type: text
%{ endfor ~}

write_files:
  - path: /etc/ssh/sshd_config.d/99-docker-app.conf
    permissions: '0644'
    content: |
      PasswordAuthentication yes
      PubkeyAuthentication yes
      PermitRootLogin no
      UsePAM yes

  # Liste der Nutzer, eine Zeile pro Benutzername; liest docker-provision.sh.
  - path: /etc/docker-app/users
    permissions: '0600'
    owner: 'root:root'
    content: |
%{ for user in team_users ~}
      ${user.username}
%{ endfor ~}

  - path: /etc/docker-app/team
    permissions: '0644'
    content: ${jsonencode(team_name)}

  # Skripte und Lernmaterial (aus tofu/files/, gzip+base64).
  - path: /usr/local/sbin/docker-install.sh
    permissions: '0755'
    encoding: gz+b64
    content: ${install_gz}

  - path: /usr/local/sbin/docker-provision.sh
    permissions: '0755'
    encoding: gz+b64
    content: ${provision_gz}

  - path: /etc/profile.d/docker-app.sh
    permissions: '0644'
    encoding: gz+b64
    content: ${profile_gz}

%{ for name, data in kurs_files ~}
  - path: ${jsonencode("/etc/skel/docker-kurs/${name}")}
    permissions: '0644'
    encoding: gz+b64
    content: ${data}

%{ endfor ~}
%{ if secondary_mac != "" ~}
  # ip_mode = dual: die IPv4-Schnittstelle, die OpenTofu nach dem Boot
  # anhaengt. Ihre Default-Route ueber das Gateway des IPv4-Netzes steht in
  # einer eigenen Tabelle, und nur Pakete mit ihrer Adresse als Absender
  # nehmen diese Tabelle. Sonst gingen Antworten ueber die
  # Hauptschnittstelle hinaus, und Neutrons Port-Security verwirft sie als
  # gefaelschten Absender. Gleiches Muster wie der Staging-Aufbau im
  # deployment-Repo.
  - path: /etc/netplan/60-secondary-ipv4.yaml
    permissions: '0600'
    content: |
      network:
        version: 2
        ethernets:
          secondary:
            match:
              macaddress: "${secondary_mac}"
            dhcp4: true
            dhcp6: false
            accept-ra: false
            dhcp4-overrides:
              use-routes: false
            routes:
              - to: default
                via: "${secondary_gateway}"
                table: 100
            routing-policy:
              - from: "${secondary_ipv4}"
                table: 100

%{ endif ~}
# Erst Software installieren, dann die Daemons der Nutzer einrichten.
runcmd:
  - systemctl restart ssh
%{ if secondary_mac != "" ~}
  # Die IPv4-Schnittstelle kommt erst nach dem Boot dazu. Bis zu fuenf
  # Minuten auf ihre MAC warten, dann die netplan-Datei oben anwenden.
  - [sh, -c, 'for i in $(seq 1 60); do if ip -o link | grep -qi "$1"; then netplan apply; break; fi; sleep 5; done', sh, "${secondary_mac}"]
%{ endif ~}
  - bash -c "/usr/local/sbin/docker-install.sh && /usr/local/sbin/docker-provision.sh" > /var/log/docker-provision.log 2>&1

final_message: "Docker-Team-VM bereit - Log unter /var/log/docker-provision.log"
