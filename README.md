# FortressOne Server Suite

## Dependencies

- [Docker Engine](https://docs.docker.com/engine/install/)
- [Docker Compose v2](https://docs.docker.com/compose/install/), i.e. the
  `docker compose` plugin. The standalone `docker-compose` binary is no longer
  used anywhere in this repo.


## Development

Runs a single FortressOne server on port 27500.


### Configuration

- Locally clone [map-repo](https://github.com/FortressOne/map-repo)
- Clone and compile [server-qwprogs](https://github.com/FortressOne/server-qwprogs)

Edit `.env.example` and save it as `.env`.


### Usage

#### Start server

```sh
docker compose up -d
```


#### Tail logs

```sh
docker compose logs -f
```


#### Attach to container

```sh
docker attach <container name>
```

`ctrl-p` `ctrl-q` to detach.


#### Stop server

```sh
docker compose down
```


## Production

Runs five automatically updated FortressOne FTE QuakeWorld servers in
different modes, plus a QWfwd proxy and certbot.

The five shards, the updater and the crash reporter are one container
(`qwtflive/fortressone`): they are all built from our own repos and released
together, and sharing a filesystem is what lets the updater hand files to the
servers without thirteen named volumes to pass them through. Each shard runs
with its own FTE `-homedir` under `/srv/shards/<name>`, so its demos, stats,
console log and crash cores stay its own. See `qwtfsv/shards.conf` for the
shard list.

certbot and QWfwd stay separate containers: certbot because TLS fixes should
arrive with a `pull` rather than waiting on a rebuild of ours, QWfwd because it
is not built from any repo here.

| Mode     | Port  |
| -------  | ----- |
| Pub      | 27500 |
| Duel     | 27501 |
| Tourney  | 27504 |
| Scrim    | 27505 |
| Staging  | 27510 |
| QWfwd    | 30000 |


### Configuration

Edit `.env.production_example` and save it as `.env.production`.


### Usage

Before executing commands you must source the production environment file:

```sh
source .env.production
```


#### Start server

```sh
docker compose -f production.yml up -d
```


#### Tail logs

```sh
docker compose -f production.yml logs -f
```


#### List containers

```sh
docker ps
```


#### Server consoles

`docker attach` cannot be used in production: five servers share one container,
and so one stdin. Each shard reads from its own FIFO and writes its own log
instead, and `console` joins the two back together.

```sh
docker exec -it docker-server-fortressone-1 console          # tmux, one window per shard
docker exec -it docker-server-fortressone-1 console pub      # just pub
docker exec    docker-server-fortressone-1 console pub status # send one command
```

`ctrl-a n` walks the windows (the inner prefix is `ctrl-a` so it does not fight
your own tmux), `ctrl-a d` detaches. Leaving a console never stops the server.

For anything scripted prefer rcon, which is authenticated and works off-host.


#### Stop

```sh
docker compose -f production.yml down
```


## Migrating a host from the old layout

The pre-single-container stack kept its data in thirteen named volumes, which
`docker compose down` does not remove. `migrate-volumes.sh` folds them into
`tf-data`, imports `/etc/letsencrypt` into the `letsencrypt` volume so certbot
keeps the existing certificate rather than issuing a fresh one, and deletes the
old volumes once each copy is verified.

```sh
./migrate-volumes.sh --dry-run   # say what would happen, touch nothing
./migrate-volumes.sh             # migrate, then remove the old volumes
./migrate-volumes.sh --keep      # migrate but leave the old volumes behind
```

`deploy` runs it before `restart.sh -f`, so a normal deploy migrates the host
on its own. It is a no-op once there is nothing left to move, and on a host
that never had the old layout.

Nothing is deleted unless every file in it arrived at the destination, and
existing files are never overwritten, so an interrupted run resumes.


## Force run updater

```sh
docker compose -f production.yml exec fortressone /updater/sync.sh
```


## TLS certificates

The web live view connects to the game port over wss, which needs a
certificate browsers trust. certbot issues and renews it over dns-01 through
Cloudflare — http-01 is not available, as the hosts have no inbound port 80 —
into the `letsencrypt` volume, which the server container mounts read-only.

It needs `cloudflare.ini` next to `production.yml`, mode `600`, which `deploy`
writes from `CF_TOKEN`:

```ini
dns_cloudflare_api_token = <token>
```

FTE reads the pem once at startup and has no reload command, so a renewal only
takes effect on restart. The `certwatch` service inside the server container
watches for a new certificate and restarts each shard the first time it sees it
empty, so nobody loses a game to it. A shard that never empties is left for up
to 12 hours before being restarted anyway.


## Create a new server instance in the cloud

Hosts are reached with [docker contexts](https://docs.docker.com/engine/manage-resources/contexts/)
over SSH. `docker-machine` is archived and is no longer used.

- Create the VM (EC2, Linode, whatever) with 27500, 27501, 27504, 27505 and
  27510 open on **both** udp and tcp, plus 30000/udp for QWfwd
- Create a user with passwordless sudo, add your public key to its
  `~/.ssh/authorized_keys`, and put it in the `docker` group
- Install Docker Engine and the Compose plugin on the host
- Register a context named after the region:

```sh
docker context create sydney --docker "host=ssh://ubuntu@sydney.fortressone.org"
docker context inspect sydney   # confirm the connection works
```

- Copy `.env.production_example` to `.env.<region>` and fill it in
- Bring it up:

```sh
source .env.<region>
export DOCKER_CONTEXT=<region>
docker compose -f production.yml up -d
docker compose -f production.yml logs -tf
```

- Run the updater once to pull down progs and maps:
  `docker compose -f production.yml exec updater /updater/sync.sh`
- Point the region's DNS record at the new instance in Cloudflare

`unset DOCKER_CONTEXT` (or `docker context use default`) to go back to the local
daemon.


### AWS

`scripts/open-ports` opens the game ports on an existing security group. When
creating instances by hand, open 27500-27505 and 27510 on udp and tcp, and
30000/udp.


### Linode

If Docker fails to come up right after provisioning
(`Unable to verify the Docker daemon is listening`), restart the VPS and try
again.


## Scripts

The scripts in `scripts/` iterate over every host listed in `scripts/shared`,
switching `DOCKER_CONTEXT` and sourcing `.env.<name>` for each one. They need a
docker context and a `.env.<name>` file per host.

| Script | Does |
| ------ | ---- |
| `scripts/deploy` | `down --remove-orphans`, `pull`, `up -d` on every host |
| `scripts/restart` | `docker compose restart` on every host |
| `scripts/update` | force-runs the updater on every host |
| `scripts/stats` | `docker stats` for every host |
| `scripts/open-ports` | opens the game ports in the AWS security group |


### Set up the environment for a single host

Requires a `.env.<context name>` file with the FO environment variables set.

```sh
source scripts/connect <context name>
```


## To Do

- [x] auto update maps
- [x] auto update qwprogs
- [x] sane default config
- [x] autorecord and mvd file server
- [ ] QTV
- [x] QWFWD
- [ ] stats


### Renew AWS after 1 year free period

E.G. for 2021 Virginia I did:
- Create new AWS account
- email: zel+virginia2021@fortressone.org
- password: xxxx
- AWS account name: fortressone-virginia2021
- Company name: FortressOne Team
- Credit card: FortressOne Team credit card
- Basic plan
- Set reminder for a year to renew again :P
- AIM > Add user
  - name: admin
  - access type: Programmatic access
- Create group
  - Group name: admin
  - Tick AdministratorAccess
- Save credentials
- Terminate the old EC2 instance
- Create a new instance and docker context as above, with the new credentials and region
- Update DNS with new IP at cloudflare
- .env file shouldn't change (credentials in env file are for storage).
- `source .env.virginia; export DOCKER_CONTEXT=virginia`
- `docker compose -f production.yml up -d`
- Close old account in My Account
