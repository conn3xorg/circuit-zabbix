variable "port" {
  type    = number
  default = 2299
}

# Example passwords only. Pass your own with -var or TF_VAR_ on a real host.
variable "db_password" {
  type      = string
  default   = "correct-horse-battery"
  ephemeral = true
  sensitive = true
}

variable "admin_password" {
  type      = string
  default   = "staple-paper-clip"
  ephemeral = true
  sensitive = true
}

# The container's distribution: rocky, ubuntu or debian. depends_on below
# holds back reading the host until the apply, so the circuit takes the
# distribution from here to plan.
variable "os" {
  type    = string
  default = "rocky"
}

locals {
  host = { box = { address = "127.0.0.1", os = var.os } }
}

# PostgreSQL on the same host, listening only on localhost.
module "postgres" {
  source = "github.com/conn3xorg/circuit-postgres?ref=v0.2.0"

  hosts                = local.host
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  users          = ["zabbix"]
  user_passwords = { zabbix = var.db_password }
  databases      = { zabbix = "zabbix" }
}

# The server, the frontend and an agent, all on the one host, so the
# server can monitor itself.
module "zabbix" {
  source = "../.."

  depends_on = [module.postgres]

  servers              = local.host
  agents               = local.host
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  database_password = var.db_password
  admin_password    = var.admin_password
}

output "frontend_url" {
  value = module.zabbix.frontend_url
}
