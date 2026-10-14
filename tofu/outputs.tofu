############################
# [CONTRACT] User Accounts Output
############################

# Schluessel "<team>-<username>", wie vom AppStore fuer den Mailversand
# verlangt. Login per SSH auf die Team-VM, dort laeuft der eigene Docker-Daemon.
output "user_accounts" {
  description = "[CONTRACT] User accounts mit Login-Informationen"
  sensitive   = true
  value = {
    for uid, user in local.users_map : uid => {
      type     = "password"
      ip       = local.team_ip[user.team]
      port     = 22
      username = user.username
      auth     = random_password.user_passwords[uid].result
      email    = user.email
      team     = user.team
    }
  }

  depends_on = [time_sleep.wait_for_docker]
}

############################
# Team-VM Details
############################

output "team_vms" {
  description = "Details aller Team-VMs"
  value = {
    for team in local.teams_list : team => {
      instance_id   = openstack_compute_instance_v2.team_vm[team].id
      instance_name = openstack_compute_instance_v2.team_vm[team].name
      ip            = local.team_ip[team]
      floating_ip   = local.enable_floating_ip ? openstack_networking_floatingip_v2.team_fip[team].address : null
      users = [
        for u in local.all_users : {
          username    = u.username
          ssh_command = "ssh ${u.username}@${local.team_ip[team]}"
        }
        if u.team == team
      ]
    }
  }
}

output "teams_summary" {
  description = "Übersicht: Teams und User-Anzahl"
  value = {
    for team in local.teams_list : team => length([for u in local.all_users : u if u.team == team])
  }
}
