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
  # ueber ihre IPv6-Adresse.
  enable_floating_ip = false
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

  security_groups = [var.shared_secgroup_id]

  timeouts {
    create = "15m"
    delete = "15m"
  }

  network {
    uuid = var.network_uuid
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
  })

  metadata = {
    team = each.key
    app  = local.app_name
  }

  depends_on = [terraform_data.team_limit]
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
  depends_on      = [openstack_compute_instance_v2.team_vm]
  create_duration = "300s"
}

############################
# ADRESSEN
############################

# Oeffentlich erreichbar ist nur die IPv6-Adresse (die IPv4 ist eine
# projektinterne NAT-Adresse). Ohne Klammern, weil ssh "user@2001:db8::1"
# erwartet; fehlt IPv6 wider Erwarten, faellt es auf IPv4 zurueck.
locals {
  team_ip = {
    for team in local.teams_list : team => (
      local.enable_floating_ip
      ? openstack_networking_floatingip_v2.team_fip[team].address
      : (
        openstack_compute_instance_v2.team_vm[team].access_ip_v6 != ""
        ? openstack_compute_instance_v2.team_vm[team].access_ip_v6
        : openstack_compute_instance_v2.team_vm[team].network[0].fixed_ip_v4
      )
    )
  }
}
