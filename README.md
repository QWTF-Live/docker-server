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
different modes, plus a QWfwd proxy.

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


#### Attach to container

```sh
docker attach <container>
```

`ctrl-p` `ctrl-q` to detach.


#### Stop

```sh
docker compose -f production.yml down
```


## Force run updater

```sh
docker compose -f production.yml exec updater /updater/sync.sh
```


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
