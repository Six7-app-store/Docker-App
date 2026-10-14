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
# Erst Software installieren, dann die Daemons der Nutzer einrichten.
runcmd:
  - systemctl restart ssh
  - bash -c "/usr/local/sbin/docker-install.sh && /usr/local/sbin/docker-provision.sh" > /var/log/docker-provision.log 2>&1

final_message: "Docker-Team-VM bereit - Log unter /var/log/docker-provision.log"
