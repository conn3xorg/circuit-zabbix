# Local example

Applies circuit-zabbix to a throwaway Rocky Linux 10 container with systemd: PostgreSQL from circuit-postgres, then the Zabbix server, the frontend and an agent, all on the one host. You need Conn3x and Podman.

On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` To see the frontend, tunnel to it through the container's SSH:

```sh
ssh -p 2299 -i id_ed25519 -o UserKnownHostsFile=known_hosts -L 8080:127.0.0.1:8080 root@127.0.0.1
```

Then open `http://localhost:8080` and sign in as `Admin` with `staple-paper-clip`, the example's password. To ask the agent something from the server:

```sh
ssh -p 2299 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1 zabbix_get -s 127.0.0.1 -k agent.ping
```

`up.sh` listens on `127.0.0.1:2299`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses, and pass its distribution with `-var os=ubuntu` or `-var os=debian`: the example's `depends_on` keeps the circuit from reading the host until the apply.

`./down.sh` removes the container, its volumes, the key and the state.
