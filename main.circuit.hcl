# Facts give each host's distribution, release and architecture, which pick
# Zabbix's repository and the package names.
data "conn3x_host" "facts" {
  for_each = local.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }

    postcondition {
      condition     = contains(["debian", "ubuntu", "rocky", "almalinux", "rhel"], self.os_id)
      error_message = "Host ${each.key} is ${self.os_id}. Zabbix publishes packages for Debian, Ubuntu, Rocky Linux, AlmaLinux and RHEL, not for this distribution."
    }
  }
}

locals {
  hosts = merge(var.servers, var.agents)

  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os     = { for name, h in local.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  family = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) ? "debian" : "redhat" }

  el_servers = { for name, h in var.servers : name => h if local.family[name] == "redhat" }

  series = regex("^[0-9]+\\.[0-9]+", var.zabbix_version)

  # Debian and Ubuntu install the exact package, which names the epoch and
  # the distribution. Zabbix's RPMs spell the revision as releaseN with
  # the distribution after it, which a version can't match, so the Red Hat
  # family installs the release's newest revision.
  version = { for name, f in data.conn3x_host.facts : name => f.os_family == "debian" ? "1:${var.zabbix_version}+${f.os_id}${f.os_version}" : split("-", var.zabbix_version)[0] }

  # Zabbix keeps arm64 builds for Debian and Ubuntu in a repository of their
  # own, and one repository per distribution and major release on the Red
  # Hat family.
  codename = { "22.04" = "jammy", "24.04" = "noble", "12" = "bookworm", "13" = "trixie" }
  el_dir   = { rocky = "rocky", almalinux = "alma", rhel = "rhel" }
  repo = { for name, f in data.conn3x_host.facts : name => f.os_family == "debian" ? {
    url    = "https://repo.zabbix.com/zabbix/${local.series}/${f.os_id}${f.arch == "aarch64" ? "-arm64" : ""}"
    suites = [local.codename[f.os_version]]
    } : {
    url    = "https://repo.zabbix.com/zabbix/${local.series}/${local.el_dir[f.os_id]}/${split(".", f.os_version)[0]}/$basearch/"
    suites = null
  } }

  # The frontend runs on the distribution's own nginx and PHP-FPM, through
  # the pool and server block Zabbix's packages ship.
  php = { "22.04" = "8.1", "24.04" = "8.3", "12" = "8.2", "13" = "8.4" }
  web = { for name, f in data.conn3x_host.facts : name => f.os_family == "debian" ? {
    frontend = "zabbix-frontend-php"
    psql     = "postgresql-client"
    fpm      = "php${lookup(local.php, f.os_version, "")}-fpm"
    user     = "www-data"
    nginx    = "/etc/zabbix/nginx.conf"
    } : {
    frontend = "zabbix-web-pgsql"
    psql     = "postgresql"
    fpm      = "php-fpm"
    user     = "apache"
    nginx    = "/etc/nginx/conf.d/zabbix.conf"
  } }

  server_name    = one(keys(var.servers))
  server_address = try(coalesce(var.server_address, try(var.servers[local.server_name].address, var.servers[local.server_name], null)), null)

  local_host = lookup({ "0.0.0.0" = "127.0.0.1", "::" = "[::1]" }, var.listen_address, strcontains(var.listen_address, ":") ? "[${var.listen_address}]" : var.listen_address)
  local_url  = "http://${local.local_host}:${var.listen_port}"
  api        = "${local.local_url}/api_jsonrpc.php"
  listen     = strcontains(var.listen_address, ":") ? "[${var.listen_address}]:${var.listen_port}" : "${var.listen_address}:${var.listen_port}"

  db = var.database

  db_password_file    = "/etc/zabbix/zabbix_server.d/conn3x-db.conf"
  admin_password_file = "/etc/zabbix/conn3x-admin-password"
  psk_file            = "/etc/zabbix/zabbix_agent2.psk"

  # psql reads the password from the server's own drop-in, so it's never on
  # a command line.
  pgpassword = "export PGPASSWORD=\"$(sed -n 's/^DBPassword=//p' ${local.db_password_file})\""
  psql       = "psql -X -q -h '${local.db.host}' -p ${local.db.port} -U '${local.db.user}' -d '${local.db.name}'"

  schema_check = "${local.pgpassword}; ${local.psql} -tAc \"SELECT 1 FROM pg_tables WHERE schemaname = current_schema() AND tablename = 'dbversion'\" | grep -qx 1"

  # From zabbix.conf.php.example, with the database filled in.
  frontend_config = <<-EOT
    <?php
    // Written by Conn3x. Changes here are overwritten on the next apply.
    $DB['TYPE']				= 'POSTGRESQL';
    $DB['SERVER']			= '${local.db.host}';
    $DB['PORT']				= '${local.db.port}';
    $DB['DATABASE']			= '${local.db.name}';
    $DB['USER']				= '${local.db.user}';
    $DB['PASSWORD']			= '%PASSWORD%';
    $DB['SCHEMA']			= '';
    $DB['ENCRYPTION']		= false;
    $DB['KEY_FILE']			= '';
    $DB['CERT_FILE']		= '';
    $DB['CA_FILE']			= '';
    $DB['VERIFY_HOST']		= false;
    $DB['CIPHER_LIST']		= '';
    $DB['VAULT']			= '';
    $DB['VAULT_URL']		= '';
    $DB['VAULT_PREFIX']		= '';
    $DB['VAULT_DB_PATH']	= '';
    $DB['VAULT_TOKEN']		= '';
    $DB['VAULT_CERT_FILE']	= '';
    $DB['VAULT_KEY_FILE']	= '';
    $DB['DOUBLE_IEEE754']	= true;

    $ZBX_SERVER_NAME		= '${coalesce(local.server_name, "Zabbix")}';

    $IMAGE_FORMAT_DEFAULT	= IMAGE_FORMAT_PNG;
  EOT

  # An agent on the server host also answers the server's own host in
  # Zabbix, which polls it at 127.0.0.1.
  agent_server = { for name, h in var.agents : name => contains(keys(var.servers), name) && !contains(["127.0.0.1", "localhost"], coalesce(local.server_address, "-")) ? "${local.server_address},127.0.0.1" : local.server_address }

  agent_tls = var.agent_psk ? "TLSConnect=psk\nTLSAccept=psk\nTLSPSKFile=${local.psk_file}\n" : ""
}

circuit "zabbix_repo" {
  hosts = local.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Zabbix's own repository for the release series. Its signing key, in
  # files/zabbix.asc, expires on 28 April 2034.
  step "repo" {
    repository {
      name   = "zabbix"
      url    = local.repo[each.key].url
      key    = file("${path.module}/files/zabbix.asc")
      suites = local.repo[each.key].suites
    }
  }
}

# The Red Hat family's zabbix-server-pgsql needs fping, which Zabbix ships in
# a repository of packages it builds but doesn't support. Its key, in
# files/zabbix-non-supported.asc, expires on 30 June 2034.
circuit "zabbix_el" {
  hosts = local.el_servers

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "non_supported" {
    repository {
      name = "zabbix-non-supported"
      url  = "https://repo.zabbix.com/non-supported/rhel/${split(".", data.conn3x_host.facts[each.key].os_version)[0]}/$basearch/"
      key  = file("${path.module}/files/zabbix-non-supported.asc")
    }
  }

  # Lets the server run its checks, such as fping, under SELinux.
  step "selinux_policy" {
    depends_on = [conn3x_repository.zabbix_repo__repo]
    package {
      name    = "zabbix-selinux-policy"
      version = local.version[each.key]
    }
  }

  # libpq looks for a Kerberos keytab on every connection unless GSSAPI
  # encryption is off, and SELinux denies the server that, filling the
  # audit log each time it starts.
  step "gssencmode" {
    line {
      path   = "/etc/sysconfig/zabbix-server"
      regexp = "^PGGSSENCMODE="
      line   = "PGGSSENCMODE=disable"
      create = true
    }
  }

  # Lets nginx and PHP-FPM reach the Zabbix server and the database, on
  # hosts where SELinux is on.
  step "selinux_booleans" {
    for_each = toset(["httpd_can_connect_zabbix", "httpd_can_network_connect_db"])
    command {
      command = "setsebool -P ${item.value} on"
      unless  = "! selinuxenabled || getsebool ${item.value} | grep -q 'on$'"
    }
  }
}

circuit "zabbix_server" {
  hosts = var.servers

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # The checks below talk to the Zabbix API with curl.
  step "curl" {
    depends_on = [conn3x_repository.zabbix_repo__repo, conn3x_package.zabbix_el__selinux_policy, conn3x_command.zabbix_el__selinux_booleans, conn3x_repository.zabbix_el__non_supported]
    package {
      name = "curl"
    }
  }

  # Imports the schema, wherever the database runs.
  step "psql" {
    package {
      name = local.web[each.key].psql
    }
  }

  step "server" {
    package {
      name    = "zabbix-server-pgsql"
      version = local.version[each.key]
    }
    notify = [handler.restart]
  }

  step "sql_scripts" {
    package {
      name    = "zabbix-sql-scripts"
      version = local.version[each.key]
    }
  }

  # Before the frontend package, so its PHP comes as PHP-FPM for nginx
  # rather than as Apache's PHP module.
  step "nginx_conf" {
    package {
      name    = "zabbix-nginx-conf"
      version = local.version[each.key]
    }
  }

  step "frontend" {
    package {
      name    = local.web[each.key].frontend
      version = local.version[each.key]
    }
  }

  step "php_pgsql" {
    package {
      name = "php-pgsql"
    }
  }

  # zabbix_get, for checking an agent answers from the server.
  step "get" {
    package {
      name    = "zabbix-get"
      version = local.version[each.key]
    }
  }

  step "db_host" {
    line {
      path   = "/etc/zabbix/zabbix_server.conf"
      regexp = "^#? ?DBHost="
      line   = "DBHost=${local.db.host}"
    }
    notify = [handler.restart]
  }

  step "db_port" {
    line {
      path   = "/etc/zabbix/zabbix_server.conf"
      regexp = "^#? ?DBPort="
      line   = "DBPort=${local.db.port}"
    }
    notify = [handler.restart]
  }

  step "db_name" {
    line {
      path   = "/etc/zabbix/zabbix_server.conf"
      regexp = "^#? ?DBName="
      line   = "DBName=${local.db.name}"
    }
    notify = [handler.restart]
  }

  step "db_user" {
    line {
      path   = "/etc/zabbix/zabbix_server.conf"
      regexp = "^#? ?DBUser="
      line   = "DBUser=${local.db.user}"
    }
    notify = [handler.restart]
  }

  # zabbix_server.conf includes this directory. Write-only: the plan and
  # state record only an HMAC of the content.
  step "db_password" {
    file {
      path       = local.db_password_file
      content_wo = "DBPassword=${var.database_password == null ? "" : var.database_password}\n"
      owner      = "root"
      group      = "root"
      mode       = "0600"
    }
    notify = [handler.restart]
  }

  # Zabbix's docs import the schema by hand, once, into an empty database.
  # unless is checked at plan time, before the password file is written on
  # a first apply, so the command checks again before it imports.
  step "schema" {
    command {
      command = "set -e; if ${local.schema_check}; then exit 0; fi; ${local.pgpassword}; zcat /usr/share/zabbix-sql-scripts/postgresql/server.sql.gz | ${local.psql} -v ON_ERROR_STOP=1 --single-transaction >/dev/null"
      unless  = local.schema_check
    }
  }

  step "running" {
    service {
      name    = "zabbix-server"
      state   = "started"
      enabled = true
    }
  }

  # The frontend's database settings, which spare you the setup wizard.
  # Write-only, as it holds the password, in PHP's single quotes.
  step "frontend_config" {
    file {
      path       = "/etc/zabbix/web/zabbix.conf.php"
      content_wo = replace(local.frontend_config, "%PASSWORD%", replace(replace(var.database_password == null ? "" : var.database_password, "\\", "\\\\"), "'", "\\'"))
      owner      = "root"
      group      = local.web[each.key].user
      mode       = "0640"
    }
  }

  step "listen" {
    line {
      path   = local.web[each.key].nginx
      regexp = "^#?\\s*listen\\s"
      line   = "        listen          ${local.listen};"
    }
  }

  # PHP-FPM reads Zabbix's pool, and nginx its server block, only at start.
  # It runs here rather than in a handler so the checks below find both
  # running with them.
  step "restart_web" {
    command {
      command = "systemctl restart ${local.web[each.key].fpm} nginx"
      triggers = {
        nginx_conf = conn3x_package.zabbix_server__nginx_conf[each.key].revision
        frontend   = conn3x_package.zabbix_server__frontend[each.key].revision
        php_pgsql  = conn3x_package.zabbix_server__php_pgsql[each.key].revision
        listen     = conn3x_line.zabbix_server__listen[each.key].revision
      }
    }
  }

  step "fpm" {
    service {
      name    = local.web[each.key].fpm
      state   = "started"
      enabled = true
    }
  }

  step "nginx" {
    service {
      name    = "nginx"
      state   = "started"
      enabled = true
    }
  }

  step "api" {
    command {
      command = "for _ in $(seq 60); do curl -sf -H 'Content-Type: application/json-rpc' -d '{\"jsonrpc\":\"2.0\",\"method\":\"apiinfo.version\",\"params\":{},\"id\":1}' ${local.api} | grep -q '\"result\"' && exit 0; sleep 2; done; echo 'The Zabbix API did not answer on ${local.api} within two minutes. See journalctl -u nginx -u ${local.web[each.key].fpm}.' >&2; exit 1"
      unless  = "curl -sf -H 'Content-Type: application/json-rpc' -d '{\"jsonrpc\":\"2.0\",\"method\":\"apiinfo.version\",\"params\":{},\"id\":1}' ${local.api} | grep -q '\"result\"'"
    }
  }

  # Empty when admin_password is null, which leaves Admin's password alone.
  step "admin_password_file" {
    file {
      path       = local.admin_password_file
      content_wo = var.admin_password == null ? "" : var.admin_password
      owner      = "root"
      group      = "root"
      mode       = "0600"
    }
  }

  # Sets Admin's password through the API when the file changes. It logs in
  # with the new password first, then with Zabbix's default, so it only
  # changes a password it knows. The password reaches curl on stdin, never
  # on a command line. Admin is user 1 in every new Zabbix database.
  step "admin_password" {
    command {
      command  = <<-EOT
        [ -s ${local.admin_password_file} ] || exit 0
        new=$(sed 's/\\/\\\\/g; s/"/\\"/g' ${local.admin_password_file})
        rpc() { curl -sS -H 'Content-Type: application/json-rpc' "$@" --data-binary @- ${local.api}; }
        login() { printf '{"jsonrpc":"2.0","method":"user.login","params":{"username":"Admin","password":"%s"},"id":1}' "$1" | rpc | sed -n 's/.*"result":"\([0-9a-f]*\)".*/\1/p'; }
        [ -n "$(login "$new")" ] && exit 0
        tok=$(login zabbix)
        [ -n "$tok" ] || { echo "Admin logs in with neither admin_password nor Zabbix's default password. Set it in the frontend under User settings, then apply again." >&2; exit 1; }
        out=$(printf '{"jsonrpc":"2.0","method":"user.update","params":{"userid":"1","current_passwd":"zabbix","passwd":"%s"},"id":2}' "$new" | rpc -H "Authorization: Bearer $tok")
        echo "$out" | grep -q '"result"' || { echo "Zabbix refused the new Admin password: $out" >&2; exit 1; }
      EOT
      triggers = conn3x_file.zabbix_server__admin_password_file[each.key].revision
    }
  }

  handler "restart" {
    service {
      name = "zabbix-server"
    }
  }
}

circuit "zabbix_agent" {
  hosts = var.agents

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "agent2" {
    depends_on = [conn3x_repository.zabbix_repo__repo]
    package {
      name    = "zabbix-agent2"
      version = local.version[each.key]
    }
    notify = [handler.restart]
  }

  # The agent answers passive checks only from Server, and sends active
  # checks to ServerActive under its Hostname.
  step "server" {
    line {
      path   = "/etc/zabbix/zabbix_agent2.conf"
      regexp = "^Server="
      line   = "Server=${local.agent_server[each.key]}"
    }
    notify = [handler.restart]
  }

  step "server_active" {
    line {
      path   = "/etc/zabbix/zabbix_agent2.conf"
      regexp = "^ServerActive="
      line   = "ServerActive=${local.server_address}"
    }
    notify = [handler.restart]
  }

  step "hostname" {
    line {
      path   = "/etc/zabbix/zabbix_agent2.conf"
      regexp = "^Hostname="
      line   = "Hostname=${each.key}"
    }
    notify = [handler.restart]
  }

  # 32 random bytes in hex, made on the host once and kept. Only the agent's
  # user can read it, and it never leaves the host.
  step "psk" {
    for_each = var.agent_psk ? ["psk"] : []
    command {
      command = "umask 077 && od -An -tx1 -N32 /dev/urandom | tr -d ' \\n' > ${local.psk_file}.new && echo >> ${local.psk_file}.new && chown zabbix:zabbix ${local.psk_file}.new && chmod 400 ${local.psk_file}.new && mv ${local.psk_file}.new ${local.psk_file}"
      creates = local.psk_file
    }
  }

  # The identity is the agent's Hostname, which you enter with the key on
  # the server's side.
  step "tls" {
    file {
      path    = "/etc/zabbix/zabbix_agent2.d/conn3x-tls.conf"
      content = "# Written by Conn3x. Changes here are overwritten on the next apply.\n${local.agent_tls}${var.agent_psk ? "TLSPSKIdentity=${each.key}\n" : ""}"
      owner   = "root"
      group   = "zabbix"
      mode    = "0640"
    }
    notify = [handler.restart]
  }

  step "running" {
    service {
      name    = "zabbix-agent2"
      state   = "started"
      enabled = true
    }
  }

  handler "restart" {
    service {
      name = "zabbix-agent2"
    }
  }
}
