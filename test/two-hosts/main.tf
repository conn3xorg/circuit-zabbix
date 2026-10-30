# A server on one host and a PSK-encrypted agent on another, for CI. Start
# them with examples/local/up.sh as zabbix-server on port 2299 and
# zabbix-agent on port 2300, then copy that directory's id_ed25519 here and
# put both hosts' keys in known_hosts.

variable "server_ip" {
  type        = string
  description = "The server container's address on the Podman network, which the agent reports to."
}

variable "db_password" {
  type      = string
  default   = "correct-horse-battery"
  ephemeral = true
  sensitive = true
}

locals {
  server = { zabbix = { address = "127.0.0.1", port = 2299, os = "ubuntu" } }
}

module "postgres" {
  source = "github.com/conn3xorg/circuit-postgres?ref=v0.2.0"

  hosts                = local.server
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  users          = ["zabbix"]
  user_passwords = { zabbix = var.db_password }
  databases      = { zabbix = "zabbix" }
}

module "zabbix" {
  source = "../.."

  depends_on = [module.postgres]

  servers              = local.server
  agents               = { agent = { address = "127.0.0.1", port = 2300, os = "rocky" } }
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  database_password = var.db_password
  server_address    = var.server_ip
  agent_psk         = true
}
