# OpenTofu erwartet weiterhin das Schluesselwort "terraform"; die Provider
# werden ueber registry.opentofu.org aufgeloest. .tofu-Dateien ab 1.8.
terraform {
  required_version = ">= 1.8"

  required_providers {
    openstack = {
      source  = "terraform-provider-openstack/openstack"
      version = "~> 1.54"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.10"
    }
  }
}

provider "openstack" {
  cloud = "openstack"
}

############################
# APP-DEFAULTS
############################

locals {
  app_name = "docker"

  # Wie bei Ubuntu- und Windows-App: keine Floating IP. Zwischen VM-Subnetz
  # und externem Netz fehlt der Router; oeffentlich erreichbar ist die VM
  # ueber die feste Adresse der gewaehlten Familie (var.ip_mode).
  enable_floating_ip = false
}

############################
# ADRESSFAMILIEN (var.ip_mode)
############################

locals {
  ethertypes = {
    ipv4 = ["IPv4"]
    ipv6 = ["IPv6"]
    dual = ["IPv4", "IPv6"]
  }[var.ip_mode]

  # Bei dual liegt die Hauptschnittstelle im IPv6-Netz: dessen private IPv4
  # bringt den Weg nach draussen (Paketquellen, Docker Hub) ueber NAT mit,
  # die oeffentliche IPv4 kommt als zweite Schnittstelle dazu.
  primary_network_id = var.ip_mode == "ipv4" ? var.network_v4_uuid : var.network_uuid

  dual = var.ip_mode == "dual"
}

# SSH je Adressfamilie - eine IPv4-Regel laesst kein IPv6-Paket durch und
# umgekehrt. Die gemeinsame Security Group bleibt zusaetzlich dran.
resource "openstack_networking_secgroup_v2" "ssh" {
  name        = "${local.app_name}-ssh"
  description = "SSH zur Team-VM (${var.ip_mode})"
}

resource "openstack_networking_secgroup_rule_v2" "ssh" {
  for_each = toset(local.ethertypes)

  security_group_id = openstack_networking_secgroup_v2.ssh.id
  direction         = "ingress"
  ethertype         = each.key
  protocol          = "tcp"
  port_range_min    = 22
  port_range_max    = 22
  remote_ip_prefix  = each.key == "IPv4" ? "0.0.0.0/0" : "::/0"
  description       = "SSH (${each.key})"
}

# Zweite Schnittstelle fuer dual, vorab als Port angelegt: so sind MAC und
# Adresse schon bekannt, wenn cloud-init sein user-data bekommt.
resource "openstack_networking_port_v2" "team_v4" {
  for_each   = local.dual ? toset(local.teams_list) : toset([])
  name       = "${local.app_name}-${local.team_slugs[each.key]}-v4"
  network_id = var.network_v4_uuid

  security_group_ids = [
    var.shared_secgroup_id,
    openstack_networking_secgroup_v2.ssh.id,
  ]
}

locals {
  secondary = {
    for team, port in openstack_networking_port_v2.team_v4 : team => {
      mac  = port.mac_address
      ipv4 = one([for ip in port.all_fixed_ips : ip if !strcontains(ip, ":")])
    }
  }
  secondary_gateway = local.dual ? data.openstack_networking_subnet_v2.v4[0].gateway_ip : ""
}

# Gateway des IPv4-Netzes fuer die eigene Routing-Tabelle der zweiten
# Schnittstelle (dual), siehe cloud-init.yml.tpl.
data "openstack_networking_subnet_v2" "v4" {
  count      = local.dual ? 1 : 0
  network_id = var.network_v4_uuid
  ip_version = 4

  lifecycle {
    postcondition {
      condition     = self.gateway_ip != ""
      error_message = "Das IPv4-Netz in network_v4_uuid hat kein Gateway; dual braucht eins fuer die Antworten der zweiten Schnittstelle."
    }
  }
}

############################
# USER MANAGEMENT (CONTRACT)
############################

locals {
  # Linux-Namen muessen mit einem Buchstaben beginnen und duerfen keine
  # Punkte enthalten - "anna.schulz" wird so zu "annaschulz".
  all_users = flatten([
    for team, members in var.users : [
      for member in members : {
        id    = "${team}-${replace(split("@", member.email)[0], ".", "-")}"
        team  = team
        email = member.email
        username = (
          can(regex("^[a-z]", lower(replace(split("@", member.email)[0], "/[^A-Za-z0-9]/", ""))))
          ? substr(lower(replace(split("@", member.email)[0], "/[^A-Za-z0-9]/", "")), 0, 30)
          : "u${substr(lower(replace(split("@", member.email)[0], "/[^A-Za-z0-9]/", "")), 0, 29)}"
        )
      }
    ]
  ])

  users_map  = { for user in local.all_users : user.id => user }
  teams_list = distinct([for user in local.all_users : user.team])

  # VM-Name: Teamnamen wie "Team #1" sind als Hostname unzulaessig.
  team_slugs = {
    for team in local.teams_list : team => trim(replace(lower(team), "/[^a-z0-9-]+/", "-"), "-")
  }
}

# Ein Passwort pro User. Sonderzeichen bewusst eingeschraenkt; das Passwort
# landet per jsonencode() im cloud-init-YAML.
resource "random_password" "user_passwords" {
  for_each         = local.users_map
  length           = 16
  special          = true
  override_special = "!@%^*_-+="
  min_upper        = 1
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
}

# Abbruch vor dem Anlegen, wenn zu viele Teams kommen.
resource "terraform_data" "team_limit" {
  input = length(local.teams_list)

  lifecycle {
    precondition {
      condition     = length(local.teams_list) <= var.max_teams
      error_message = "Dieses Deployment wuerde ${length(local.teams_list)} Team-VMs anlegen, erlaubt sind ${var.max_teams}. Teams zusammenlegen oder max_teams erhoehen."
    }
  }
}

# Normales Ubuntu-Image; die Software installiert cloud-init beim ersten Boot.
data "openstack_images_image_v2" "image" {
  name        = var.image_name
  most_recent = true
}

# External network nur abfragen, wenn Floating IPs aktiv sind - sonst bricht
# der Plan ab, falls das Netz im Projekt nicht existiert.
data "openstack_networking_network_v2" "external" {
  count = local.enable_floating_ip ? 1 : 0
  name  = var.floating_ip_pool
}

############################
# EINE VM PRO TEAM
############################

resource "openstack_compute_instance_v2" "team_vm" {
  for_each = toset(local.teams_list)

  name        = "${local.app_name}-${local.team_slugs[each.key]}"
  image_id    = data.openstack_images_image_v2.image.id
  flavor_name = var.flavor_name
  key_pair    = null

  # Per ID: Nova nimmt beides an, ein Name ist aber nicht eindeutig, sobald
  # ein zweites Deployment im Projekt eine gleichnamige Gruppe hat.
  security_groups = [var.shared_secgroup_id, openstack_networking_secgroup_v2.ssh.id]

  timeouts {
    create = "15m"
    delete = "15m"
  }

  # Nur die Hauptschnittstelle. Die zweite bei dual haengt interface_attach
  # unten an: als zweiter network-Block wuerde cloud-init sie beim ersten
  # Boot mit einer eigenen Default-Route einrichten.
  network {
    uuid = local.primary_network_id
  }

  # Skripte gzip+base64: so stoeren ${...} der Shell das Template nicht, und
  # user_data bleibt weit unter dem Nova-Limit von 64 KB.
  user_data = templatefile("${path.module}/cloud-init.yml.tpl", {
    install_gz   = base64gzip(file("${path.module}/files/install.sh"))
    provision_gz = base64gzip(file("${path.module}/files/docker-provision.sh"))
    profile_gz   = base64gzip(file("${path.module}/files/profile.sh"))
    kurs_files = {
      for f in fileset("${path.module}/files/docker-kurs", "**") :
      f => base64gzip(file("${path.module}/files/docker-kurs/${f}"))
    }
    team_name = each.key
    team_users = [
      for uid, user in local.users_map : {
        username = user.username
        password = random_password.user_passwords[uid].result
      }
      if user.team == each.key
    ]
    secondary_mac     = local.dual ? local.secondary[each.key].mac : ""
    secondary_ipv4    = local.dual ? local.secondary[each.key].ipv4 : ""
    secondary_gateway = local.secondary_gateway
  })

  metadata = {
    team = each.key
    app  = local.app_name
  }

  depends_on = [terraform_data.team_limit, openstack_networking_secgroup_rule_v2.ssh]

  lifecycle {
    precondition {
      condition     = var.ip_mode == "ipv6" || var.network_v4_uuid != ""
      error_message = "ip_mode \"${var.ip_mode}\" braucht ein IPv4-Netz in network_v4_uuid."
    }
    precondition {
      condition     = var.ip_mode == "ipv4" || var.network_uuid != ""
      error_message = "ip_mode \"${var.ip_mode}\" braucht ein IPv6-Netz in network_uuid."
    }
  }
}

# Zweite Schnittstelle (dual) an die laufende Instanz. Eingerichtet wird sie
# von cloud-init, das auf ihre MAC wartet - siehe runcmd in cloud-init.yml.tpl.
resource "openstack_compute_interface_attach_v2" "team_v4" {
  for_each    = openstack_networking_port_v2.team_v4
  instance_id = openstack_compute_instance_v2.team_vm[each.key].id
  port_id     = each.value.id
}

############################
# FLOATING IPs (optional)
############################

resource "openstack_networking_floatingip_v2" "team_fip" {
  for_each = local.enable_floating_ip ? toset(local.teams_list) : toset([])
  pool     = data.openstack_networking_network_v2.external[0].name
}

data "openstack_networking_port_v2" "vm_port" {
  for_each  = local.enable_floating_ip ? toset(local.teams_list) : toset([])
  device_id = openstack_compute_instance_v2.team_vm[each.key].id
}

resource "openstack_networking_floatingip_associate_v2" "team_fip_assoc" {
  for_each    = local.enable_floating_ip ? toset(local.teams_list) : toset([])
  floating_ip = openstack_networking_floatingip_v2.team_fip[each.key].address
  port_id     = data.openstack_networking_port_v2.vm_port[each.key].id
}

# Docker-Installation und die rootless Daemons der Nutzer brauchen nach
# ACTIVE noch einige Minuten. Ohne Warten gingen die Zugangsdaten zu frueh raus.
resource "time_sleep" "wait_for_docker" {
  depends_on      = [openstack_compute_instance_v2.team_vm, openstack_compute_interface_attach_v2.team_v4]
  create_duration = "300s"
}

############################
# ADRESSEN
############################

# Verbindungsziel je Team. Bei ipv6 die IPv6-Adresse (die IPv4 im IPv6-Netz
# ist eine projektinterne NAT-Adresse), bei ipv4 die feste IPv4, bei dual die
# oeffentliche IPv4 der zweiten Schnittstelle, weil sie mehr Heimnetze
# erreicht. Ohne Klammern, weil ssh "user@2001:db8::1" erwartet.
locals {
  team_ip = {
    for team in local.teams_list : team => (
      local.enable_floating_ip ? openstack_networking_floatingip_v2.team_fip[team].address
      : var.ip_mode == "ipv4" ? openstack_compute_instance_v2.team_vm[team].network[0].fixed_ip_v4
      : local.dual ? local.secondary[team].ipv4
      : (
        # access_ip_v6 liefert der Provider mit Klammern
        openstack_compute_instance_v2.team_vm[team].access_ip_v6 != ""
        ? trim(openstack_compute_instance_v2.team_vm[team].access_ip_v6, "[]")
        : openstack_compute_instance_v2.team_vm[team].network[0].fixed_ip_v4
      )
    )
  }
}
