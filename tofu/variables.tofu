################################################
# PFLICHT-Variablen
################################################

variable "users" {
  description = "Per-team roster — vom Worker injiziert."
  type = map(list(object({
    email = string
  })))
  default = {}
}

################################################
# Konfigurierbare Variablen
################################################

variable "image_name" {
  description = "Basis-Image (Ubuntu 24.04 empfohlen) @openstack:image:name"
  type        = string
  default     = "Ubuntu 24.04"
}

#   ipv4  eine Schnittstelle im IPv4-Netz (network_v4_uuid)
#   ipv6  eine Schnittstelle im IPv6-Netz (network_uuid) - Standard
#   dual  IPv6-Netz als Hauptschnittstelle, dazu eine zweite im IPv4-Netz
variable "ip_mode" {
  description = "Adressfamilie: ipv4, ipv6 oder dual (beide)"
  type        = string
  default     = "ipv6"

  validation {
    condition     = contains(["ipv4", "ipv6", "dual"], var.ip_mode)
    error_message = "ip_mode muss \"ipv4\", \"ipv6\" oder \"dual\" sein."
  }
}

# Der Name bleibt network_uuid, damit bestehende Deployments beim Redeploy
# ihre gespeicherte Netzwahl weiter treffen.
variable "network_uuid" {
  description = "Netz mit öffentlicher IPv6, z. B. DHBWV6 - für ipv6 und dual @openstack:network:id"
  type        = string
  default     = "9b579624-d844-4df3-b38d-89978b31d37d"
}

variable "network_v4_uuid" {
  description = "Netz mit öffentlich gerouteter IPv4, z. B. DHBWv4 - für ipv4 und dual @openstack:network:id"
  type        = string
  default     = ""
}

variable "floating_ip_pool" {
  description = "Name des External Networks für Floating IPs @openstack:floating_ip_pool:name"
  type        = string
  default     = "DHBW"
}

variable "shared_secgroup_id" {
  description = "ID der gemeinsamen Security Group für alle VMs @openstack:security_group:id"
  type        = string
  default     = "7ca4f889-e11e-4a16-83a8-73a77ebdbbe6"
}

# Jeder Nutzer hat einen eigenen Docker-Daemon und eigenen Image-Speicher.
# gp1.small reicht fuer kleine Teams; fuer groessere einen groesseren Flavor.
variable "flavor_name" {
  description = "VM-Größe der Team-VM @openstack:flavor:name"
  type        = string
  default     = "gp1.small"
}

# Jedes Team bekommt eine eigene VM. Die Obergrenze schuetzt das
# Projektkontingent, wie bei der Windows-App: lieber eine klare Meldung vor
# dem Apply als ein Quota-Fehler mit halbfertigen Instanzen.
variable "max_teams" {
  description = "Obergrenze gleichzeitiger Team-VMs"
  type        = number
  default     = 15

  validation {
    condition     = var.max_teams >= 1 && var.max_teams <= 30
    error_message = "max_teams muss zwischen 1 und 30 liegen."
  }
}
