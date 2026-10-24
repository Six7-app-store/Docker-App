# Prüft, wie Adressfamilie, SSH-Regeln und Zugangsadresse aus ip_mode
# entstehen. Alle Provider sind gemockt: der Test braucht keinen
# OpenStack-Zugang und legt nichts an.
#
#   cd tofu && tofu init -backend=false && tofu test

mock_provider "openstack" {
  mock_data "openstack_images_image_v2" {
    defaults = {
      id = "00000000-0000-0000-0000-00000000image"
    }
  }
  mock_resource "openstack_compute_instance_v2" {
    defaults = {
      access_ip_v6 = "[2001:db8::42]"
      network      = { fixed_ip_v4 = "10.200.0.42" }
    }
  }
  mock_data "openstack_networking_subnet_v2" {
    defaults = {
      gateway_ip = "141.72.10.1"
    }
  }
  mock_resource "openstack_networking_port_v2" {
    defaults = {
      all_fixed_ips = ["141.72.10.7"]
      mac_address   = "fa:16:3e:00:00:07"
    }
  }
}

mock_provider "random" {}
mock_provider "time" {}

variables {
  users = {
    "Team #1" = [{ email = "Anna.Alt@dhbw.de" }]
    "b"       = [{ email = "ben@dhbw.de" }]
  }
}

run "ipv6_ist_standard" {
  command = apply

  assert {
    condition     = keys(openstack_networking_secgroup_rule_v2.ssh) == ["IPv6"]
    error_message = "Ohne Auswahl gilt ipv6: eine SSH-Regel fuer IPv6."
  }
  assert {
    condition     = openstack_compute_instance_v2.team_vm["b"].network[0].uuid == "9b579624-d844-4df3-b38d-89978b31d37d"
    error_message = "ipv6 haengt die VM ins IPv6-Netz."
  }
  assert {
    condition     = output.team_vms["b"].ip == "2001:db8::42"
    error_message = "Die Adresse kommt ohne Klammern, ssh erwartet sie so."
  }
  assert {
    condition     = length(openstack_compute_interface_attach_v2.team_v4) == 0
    error_message = "ipv6 braucht keine zweite Schnittstelle."
  }
}

run "zugang_ueber_ipv4" {
  command = apply

  variables {
    ip_mode         = "ipv4"
    network_v4_uuid = "00000000-0000-0000-0000-0000000000v4"
  }

  assert {
    condition     = openstack_compute_instance_v2.team_vm["b"].network[0].uuid == "00000000-0000-0000-0000-0000000000v4"
    error_message = "ipv4 muss die VM ins IPv4-Netz haengen."
  }
  assert {
    condition     = keys(openstack_networking_secgroup_rule_v2.ssh) == ["IPv4"]
    error_message = "ipv4 braucht genau eine SSH-Regel fuer IPv4."
  }
  assert {
    condition     = output.team_vms["b"].ip == "10.200.0.42"
    error_message = "Die Zugangsdaten muessen die feste IPv4 der VM nennen."
  }
}

run "dual_haengt_ipv4_als_zweite_schnittstelle_an" {
  command = apply

  variables {
    ip_mode         = "dual"
    network_v4_uuid = "00000000-0000-0000-0000-0000000000v4"
  }

  assert {
    condition     = length(openstack_compute_interface_attach_v2.team_v4) == 2
    error_message = "dual braucht je Team-VM eine IPv4-Schnittstelle als zweiten Port."
  }
  assert {
    condition     = toset(keys(openstack_networking_secgroup_rule_v2.ssh)) == toset(["IPv4", "IPv6"])
    error_message = "dual braucht SSH-Regeln fuer beide Familien."
  }
  assert {
    condition     = output.team_vms["b"].ip == "141.72.10.7"
    error_message = "Bei dual nennen die Zugangsdaten die oeffentliche IPv4 der zweiten Schnittstelle."
  }
  assert {
    condition     = strcontains(yamldecode(openstack_compute_instance_v2.team_vm["b"].user_data).write_files[length(yamldecode(openstack_compute_instance_v2.team_vm["b"].user_data).write_files) - 1].content, "from: \"141.72.10.7\"")
    error_message = "cloud-init muss die IPv4-Schnittstelle mit eigener Routing-Tabelle einrichten."
  }
  assert {
    condition     = strcontains(yamldecode(openstack_compute_instance_v2.team_vm["b"].user_data).write_files[length(yamldecode(openstack_compute_instance_v2.team_vm["b"].user_data).write_files) - 1].content, "via: \"141.72.10.1\"")
    error_message = "Die eigene Tabelle braucht die Default-Route ueber das Gateway des IPv4-Netzes."
  }
  assert {
    condition     = yamldecode(openstack_compute_instance_v2.team_vm["b"].user_data).runcmd[1][4] == "fa:16:3e:00:00:07"
    error_message = "cloud-init muss vor der Einrichtung auf die zweite Schnittstelle warten."
  }
}

run "ipv4_ohne_netz_wird_abgelehnt" {
  command = plan

  variables {
    ip_mode = "ipv4"
  }

  expect_failures = [openstack_compute_instance_v2.team_vm]
}

run "unbekannter_ip_mode_wird_abgelehnt" {
  command = plan

  variables {
    ip_mode = "ipv5"
  }

  expect_failures = [var.ip_mode]
}
