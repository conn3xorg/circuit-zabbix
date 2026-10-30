variable "servers" {
  type        = any
  default     = {}
  description = "Host to run the Zabbix server and frontend on, by name: a map of one name to an address, or to a host object with an address and optional host_key, user, port, private_key_file, jump_hosts or os. Empty for agents that report to a server you run elsewhere."

  validation {
    condition     = length(var.servers) <= 1
    error_message = "Give at most one server. Zabbix's high-availability cluster isn't covered by this circuit."
  }

  validation {
    condition     = alltrue([for h in var.servers : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux or rhel. Zabbix doesn't publish packages for Fedora."
  }
}

variable "agents" {
  type        = any
  default     = {}
  description = "Hosts to run Zabbix agent 2 on, by name, in the same form as servers. Each name becomes the agent's Hostname, the name you give the host in Zabbix. A name can be in both servers and agents, so the server monitors itself."

  validation {
    condition     = alltrue([for name in keys(var.agents) : can(regex("^[A-Za-z0-9._-]+$", name))])
    error_message = "Agent names become Zabbix host names, so they may use letters, digits, . _ and -."
  }

  validation {
    condition     = alltrue([for h in var.agents : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux or rhel. Zabbix doesn't publish packages for Fedora."
  }
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}

variable "zabbix_version" {
  type        = string
  default     = "7.0.32-2"
  description = "Zabbix release and package revision to install, as Zabbix's Debian packages number them, such as \"7.0.32-2\". The release's first two numbers pick Zabbix's repository. Raising it upgrades every Zabbix package in place."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+-[0-9]+$", var.zabbix_version))
    error_message = "zabbix_version must be a full release and package revision, such as \"7.0.32-2\"."
  }
}

variable "database" {
  type = object({
    host = optional(string, "127.0.0.1")
    port = optional(number, 5432)
    name = optional(string, "zabbix")
    user = optional(string, "zabbix")
  })
  default     = {}
  description = "PostgreSQL database the server and frontend keep their data in. The role and an empty database it owns must exist, such as from circuit-postgres. The defaults suit PostgreSQL on the server host itself."

  validation {
    condition     = can(regex("^[A-Za-z0-9_.:-]+$", var.database.host)) && can(regex("^[A-Za-z0-9_]+$", var.database.name)) && can(regex("^[A-Za-z0-9_]+$", var.database.user))
    error_message = "database host may use letters, digits and . _ - :, and name and user letters, digits and _."
  }
}

variable "database_password" {
  type        = string
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "Password of the database user. Needed with servers. Pass it at run time with -var or TF_VAR_database_password; it never reaches state or the plan."

  validation {
    condition     = length(var.servers) == 0 || length(coalesce(var.database_password, "")) > 0
    error_message = "servers needs database_password."
  }

  validation {
    condition     = !strcontains(coalesce(var.database_password, "-"), "\n")
    error_message = "database_password must be on one line."
  }
}

variable "admin_password" {
  type        = string
  default     = null
  ephemeral   = true
  sensitive   = true
  description = "Password to give the frontend's Admin user in place of Zabbix's default, zabbix. When null, Admin keeps whatever password it has. Pass it at run time with -var or TF_VAR_admin_password; it never reaches state or the plan."

  validation {
    condition     = var.admin_password == null || (length(coalesce(var.admin_password, "")) >= 8 && !strcontains(coalesce(var.admin_password, "-"), "\n"))
    error_message = "admin_password must be at least 8 characters, on one line."
  }
}

variable "listen_address" {
  type        = string
  default     = "127.0.0.1"
  description = "Address the frontend listens on. The default keeps it to the server host itself, for a reverse proxy or an SSH tunnel in front."

  validation {
    condition     = can(cidrhost("${var.listen_address}/${strcontains(var.listen_address, ":") ? 128 : 32}", 0))
    error_message = "listen_address must be an IP address, such as \"127.0.0.1\" or \"0.0.0.0\"."
  }
}

variable "listen_port" {
  type        = number
  default     = 8080
  description = "Port the frontend serves on, in plain HTTP."

  validation {
    condition     = var.listen_port >= 1 && var.listen_port <= 65535 && floor(var.listen_port) == var.listen_port
    error_message = "listen_port must be a port number from 1 to 65535."
  }
}

variable "server_address" {
  type        = string
  default     = null
  description = "Address the agents know the server by: they accept passive checks from it and send active checks to it. When null, the address of the host in servers."

  validation {
    condition     = var.server_address == null || can(regex("^[A-Za-z0-9_.:\\[\\]-]+$", coalesce(var.server_address, "-")))
    error_message = "server_address must be a host name or an IP address, such as \"zabbix.example.com\" or \"10.0.0.5\"."
  }

  validation {
    condition     = var.server_address != null || length(var.servers) > 0 || length(var.agents) == 0
    error_message = "Agents without a server in servers need server_address."
  }
}

variable "agent_psk" {
  type        = bool
  default     = false
  description = "Encrypt the agents' traffic with a pre-shared key. Each agent generates its own key, which never leaves the host; you register it with the server yourself. See the README."
}
