# circuit-zabbix

[![Conn3x grade](https://conn3x.org/circuits/zabbix/grade.svg)](https://conn3x.org/circuits/zabbix/grade)

A Conn3x circuit that installs Zabbix 7.0 LTS from Zabbix's own repositories: the server and its web frontend on one host, and Zabbix agent 2 on as many hosts as you like. You get a server that's already past the setup wizard, an Admin password that isn't `zabbix`, and agents that know where to report and under what name.

Zabbix keeps its data in PostgreSQL. Pair this circuit with [circuit-postgres](https://github.com/conn3xorg/circuit-postgres) on the same host, or point it at a database you already run. The circuit imports Zabbix's schema into it once, the way Zabbix's install guide does by hand.

## Usage

```hcl
module "postgres" {
  source = "github.com/conn3xorg/circuit-postgres?ref=v0.3.0"

  hosts                = { zabbix = { address = "203.0.113.10", os = "ubuntu" } }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  users          = ["zabbix"]
  user_passwords = { zabbix = var.db_password }
  databases      = { zabbix = "zabbix" }
}

module "zabbix" {
  source = "github.com/conn3xorg/circuit-zabbix?ref=v0.1.5"

  depends_on = [module.postgres]

  servers = { zabbix = { address = "203.0.113.10", os = "ubuntu" } }
  agents = {
    zabbix = { address = "203.0.113.10", os = "ubuntu" }
    web1   = { address = "203.0.113.11", os = "debian" }
    db1    = { address = "203.0.113.12", os = "rocky" }
  }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  database_password = var.db_password
  admin_password    = var.admin_password
  server_address    = "10.0.0.10"
}
```

Declare `db_password` and `admin_password` as `ephemeral` variables and pass them at run time with `-var` or `TF_VAR_`. Neither reaches the plan or state. Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`

The frontend listens on `127.0.0.1:8080` on the server, for a reverse proxy in front of it. Until you have one, an SSH tunnel does:

```sh
ssh -L 8080:127.0.0.1:8080 root@203.0.113.10
```

Then open `http://localhost:8080` and sign in as `Admin` with your `admin_password`.

`depends_on` makes sure PostgreSQL is up before Zabbix imports its schema. It also holds back reading the hosts until the apply, so give each one's distribution in `os`, as above: the circuit picks repositories and packages by distribution, and without `os` the plan fails with `Invalid for_each argument`. The same goes for hosts created in the same plan. If `os` turns out not to match a host, Conn3x stops before configuring it.

To try it on a throwaway container first, see [examples/local](examples/local).

### Agents for a server you already run

Leave `servers` empty and set `server_address` to your Zabbix server, or to the proxy the agents should report to:

```hcl
module "zabbix_agents" {
  source = "github.com/conn3xorg/circuit-zabbix?ref=v0.1.5"

  agents         = { web1 = "203.0.113.11", web2 = "203.0.113.12" }
  server_address = "zabbix.example.com"
}
```

### Which address the agents get

Agents accept passive checks only from `server_address`, and send active checks to it. By default that's the address you gave the server host, which is the one Conn3x connects to. When the agents reach the server on another address, such as a private network, set `server_address` to that one.

An agent on the server host itself also accepts `127.0.0.1`, since that's where Zabbix's own "Zabbix server" host looks for it.

### Encrypting agent traffic with a pre-shared key

Set `agent_psk = true` and each agent generates a 256-bit key on its own host, in `/etc/zabbix/zabbix_agent2.psk`, readable only by the agent. From then on it talks to the server only over TLS with that key. The key's identity is the agent's name.

The key never leaves the host, so Conn3x can't hand it to the server for you. Doing that would put every agent's key in state. You give it to the server yourself, once per agent:

1. Read the key on the agent: `cat /etc/zabbix/zabbix_agent2.psk`.
2. In the frontend, open the host under Data collection > Hosts, go to the Encryption tab, tick PSK under both "Connections to host" and "Connections from host", and enter the agent's name as the PSK identity and the key as the PSK.

The API does the same with `host.create` or `host.update` and `"tls_connect": 2, "tls_accept": 2, "tls_psk_identity": "web1", "tls_psk": "..."`. Until you do, the server can't reach the agent, and the agent's active checks are refused. An agent on the server host is no exception: with `agent_psk` on, give the "Zabbix server" host its key too.

The circuit doesn't register agents as hosts in Zabbix. Add them in the frontend, through the API, or with Zabbix's autoregistration; each agent's name is its `Hostname`.

## What it does

On every host, first:

1. Adds Zabbix's repository for the release series, `https://repo.zabbix.com/zabbix/7.0/`, for the host's distribution and architecture, with Zabbix's signing key from [files/zabbix.asc](files/zabbix.asc). That key expires on 28 April 2034.

On the server host, in order:

1. On Rocky Linux, AlmaLinux and RHEL, also adds Zabbix's `non-supported` repository, which carries the `fping` the server needs, with its key from [files/zabbix-non-supported.asc](files/zabbix-non-supported.asc), which expires on 30 June 2034. Then installs `zabbix-selinux-policy`, turns on the SELinux booleans `httpd_can_connect_zabbix` and `httpd_can_network_connect_db` where SELinux is on, and sets `PGGSSENCMODE=disable` in `/etc/sysconfig/zabbix-server`. Without that, libpq looks for a Kerberos keytab on every connection, and SELinux logs a denial for each.
2. Installs `curl`, the PostgreSQL client, `zabbix-server-pgsql`, `zabbix-sql-scripts`, `zabbix-nginx-conf`, the frontend (`zabbix-frontend-php` on Debian and Ubuntu, `zabbix-web-pgsql` on the Red Hat family), `php-pgsql` and `zabbix-get`. nginx and PHP-FPM come from the distribution.
3. Sets `DBHost`, `DBPort`, `DBName` and `DBUser` in `/etc/zabbix/zabbix_server.conf`, and writes the password to `/etc/zabbix/zabbix_server.d/conn3x-db.conf`, readable only by root, which the server includes.
4. Imports `/usr/share/zabbix-sql-scripts/postgresql/server.sql.gz` into the database in one transaction, if the database has no Zabbix tables yet. It never imports over an existing schema; upgrades between 7.0 releases are the server's own job when it starts. On the server host itself (`127.0.0.1`, `localhost`, `::1` or the host's address), `psql` only gets the password if root or the `postgres` user holds the port, so a PostgreSQL in a container with a published port needs its container's address in `database.host` instead. It can't check another host's port, so a database elsewhere relies on the network between the hosts and on PostgreSQL's own authentication. The check narrows the window rather than closing it, and the Zabbix server and frontend, which connect on their own, don't have one.
5. Starts `zabbix-server` now and at boot, and restarts it when its settings change.
6. Writes `/etc/zabbix/web/zabbix.conf.php` with the database settings, so the frontend skips its setup wizard.
7. Sets `listen` in the server block Zabbix's package ships for nginx, and starts PHP-FPM and nginx with Zabbix's pool and server block. Then waits for the API at `/api_jsonrpc.php` to answer.
8. With `admin_password` set, logs in to the API and changes Admin's password from Zabbix's default to yours. It only ever changes a password it knows: if Admin logs in with yours already, it does nothing, and if Admin logs in with neither, it stops and says so.

On each agent, in order:

1. Installs `zabbix-agent2`.
2. Sets `Server`, `ServerActive` and `Hostname` in `/etc/zabbix/zabbix_agent2.conf`.
3. With `agent_psk`, generates the key, and writes the TLS settings to `/etc/zabbix/zabbix_agent2.d/conn3x-tls.conf`.
4. Starts `zabbix-agent2` now and at boot, and restarts it when its settings change.

Every Zabbix package is pinned to `zabbix_version`. On Debian and Ubuntu that's the exact package; on the Red Hat family, Zabbix's RPMs put the distribution in the revision, so they get the newest revision of the release.

### What it doesn't do

- It doesn't open firewall ports. Agents listen on 10050 and the server on 10051; open them between your hosts with [circuit-firewall](https://github.com/conn3xorg/circuit-firewall) or your cloud's firewall.
- It doesn't put TLS in front of the frontend. Use a reverse proxy, such as [circuit-caddy](https://github.com/conn3xorg/circuit-caddy).
- It doesn't create hosts, templates or users in Zabbix, apart from changing Admin's password.
- It doesn't set up Zabbix's high-availability cluster, proxies, TimescaleDB or MySQL.
- Fedora isn't supported. Zabbix doesn't publish packages for it, and the hosts' facts stop the plan on one.

### Signing keys

Zabbix signs its 7.0 repositories with key `4C3D 6F2C C75F 5146 754F C374 D913 219A B533 3005`, which expires on 28 April 2034, and its `non-supported` repository with `D9AA 84C2 B617 479C 6E4F CF4D 19F2 4753 08EF A7DD`, which expires on 30 June 2034. Both come from Zabbix's own `zabbix-release` package. Check them with:

```sh
gpg --show-keys files/zabbix.asc files/zabbix-non-supported.asc
```

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `servers` | any | `{}` | The host to run the server and frontend on, as a map of one name to an address or a host object. A host object can set `address`, `host_key`, `user`, `port`, `private_key_file`, `jump_hosts` and `os`, the distribution's ID, such as `ubuntu` or `rocky`. At most one. |
| `agents` | any | `{}` | Hosts to run Zabbix agent 2 on, by name, in the same form. Each name becomes the agent's `Hostname` and may use letters, digits, `.`, `_` and `-`. A name can be in both `servers` and `agents`. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `zabbix_version` | string | `"7.0.32-2"` | Zabbix release and package revision, as Zabbix's Debian packages number them. The first two numbers pick the repository. Raising it upgrades every Zabbix package in place. |
| `database` | object | `{}` | PostgreSQL to use: `host` (default `"127.0.0.1"`), `port` (`5432`), `name` (`"zabbix"`) and `user` (`"zabbix"`). The role and an empty database it owns must exist. |
| `database_password` | string | `null` | Password of the database user. Needed with `servers`. Ephemeral and sensitive. |
| `admin_password` | string | `null` | Password for the frontend's Admin user, at least 8 characters. Zabbix's password policy also turns down easy-to-guess passwords and any containing `admin` or `zabbix`, in any case. When null, Admin keeps the password it has. Ephemeral and sensitive. |
| `listen_address` | string | `"127.0.0.1"` | Address the frontend listens on. |
| `listen_port` | number | `8080` | Port the frontend serves on, in plain HTTP. |
| `server_address` | string | `null` | Address the agents report to and accept passive checks from. When null, the server host's address. Needed when `servers` is empty. |
| `agent_psk` | bool | `false` | Encrypt agent traffic with a pre-shared key each agent generates. See [Encrypting agent traffic with a pre-shared key](#encrypting-agent-traffic-with-a-pre-shared-key). |

## Outputs

| Name | Description |
| --- | --- |
| `frontend_url` | Where the frontend listens on the server host, such as `http://127.0.0.1:8080`. Null without a server. |
| `server_address` | Address the agents report to. |
| `psk_file` | Path of each agent's key on its own host, `/etc/zabbix/zabbix_agent2.psk`, when `agent_psk` is on. |

## Requirements

Requires Conn3x v0.6.9 or later and systemd on each host, with access to `repo.zabbix.com` and the distribution's own mirrors. The server needs a PostgreSQL release Zabbix 7.0 supports, with a role and an empty database for Zabbix; the tests used PostgreSQL 18 from circuit-postgres. The droplets in the tests had 2 GB of memory.

## Tested on

Ubuntu 24.04, Debian 13 and Rocky Linux 10. CI applies [examples/local](examples/local), with PostgreSQL from circuit-postgres, the server, the frontend and an agent on one amd64 container, checks that the second plan has no changes, and then checks that the frontend answers `/index.php`, the API reports 7.0.32, Admin logs in with the example's password and no longer with `zabbix`, and `zabbix_get -k agent.ping` returns 1. A second job runs the server on Ubuntu 24.04 and a PSK agent on Rocky Linux 10, in two containers: the agent refuses `zabbix_get` without the key and answers with it, and once the agent is registered through the API with its key, the server reports it available. The same was run on arm64 containers on a Mac.

On arm64 containers, every job above also ran against hosts first applied at v0.1.0 and then moved to this version: the second plan had no changes and the checks passed. All of it ran on Conn3x v0.6.11 and on a newer development build.

On DigitalOcean, a Rocky Linux 10 droplet with SELinux enforcing ran PostgreSQL, the server, the frontend and an agent, and an Ubuntu 24.04 droplet ran a PSK agent reporting over the private network, both with `agent_psk` on. The checks above passed, and passed again after rebooting both, with a second plan that had no changes. The server ran confined as `zabbix_t`, and nginx and PHP-FPM as `httpd_t`.

## License

MPL-2.0. See [LICENSE](LICENSE). Zabbix itself is AGPL-3.0.
