# homelab

docker compose stacks for my home server plus the tooling, networking, and backup/restore methods. everything runs baremetal on a single box + a NAS for storage, reachable over tailscale, fronted by caddy for TLS + routing, with nightly backups pushed to cloudflare R2.

# tooling

CLI tools are pinned and installed with `mise` via `mise.toml`. if doing a fresh install:

    curl -fsSL https://mise.run | sh
    mise trust
    mise install

`tailscale` cannot be installed via mise:

    curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up

# networking

## tailscale

all devices run `tailscale`. devices within my tailnet can reach services hosted on the homelab via magicDNS at `homelab.<tailnet>.ts.net:PORT` or tailscale's assigned IPv4 address. for simplicity/memorability, all device IPs have been manually reassigned to static addresses within a single `100.x.x.x` block. see the bottom of the README for a table with hosts/ports.

rather than inviting people into my tailnet, the homelab node is shared out to them. shared users only see this node, and can reach it at the homelab IP address. this is used for others to access the palworld server as well as homeassistant.

i am also using the `mullvad` VPN addon for tailscale, which allows for choosing an exit node on any device in my tailnet on a per-client basis, obscuring IPs for private browsing. using an exit node on the homelab server routes all of its outbound traffic through mullvad, which breaks anything that depends on a stable, reputable source IP: caddy's calls to the cloudflare API for cert renewal, the tesla fleet API, and other outbound integrations all get rate-limited or rejected when they come from a shared mullvad exit node. therefore there is no exit node set on this server:

    sudo tailscale set --exit-node=

## cloudflare

services can also be accessed via my domain `jaydeepappas.me`, which is registered and DNS-hosted through `cloudflare`. there exists a wildcard `*.jaydeepappas.me` A record which points to the homelab IP, so hosted subdomains are reachable via more human-friendly names.

note that this record must not be proxied through cloudflare (no orange cloud), and the apex domain does not resolve to anything without another explicit A record.

## caddy

the above cloudflare configuration requires `caddy` as a reverse proxy to route traffic by some subdomain to some port. for example, incoming traffic matching `ha.jaydeepappas.me` is routed to `localhost:8123`. tailscale already encrypts all traffic in transit, so plain HTTP over the tailnet is low-risk. however, browsers and password managers can be finicky when visiting HTTP sites, so i've opted into using HTTPS.

caddy handles HTTPS by default, but its default certificate challenges require `let's encrypt` to connect inbound to the homelab server, which it can't do since the A records point to a private tailnet IP. to get around this we opt into the DNS-01 challenge to prove domain ownership by creating a temporary TXT record through the cloudflare API. the stock caddy image ships without DNS provider modules, so `caddy/Dockerfile` uses `xcaddy` to bring in the [`caddy-dns/cloudflare`](https://github.com/caddy-dns/cloudflare) module for this certificate validation flow.

the cloudflare API token caddy uses for this needs `Zone:Zone:Read` to look up the zone ID and `Zone:DNS:Edit` to write the challenge record, scoped to the `jaydeepappas.me` zone. note that a missing or expired token fails silently until the cert actually needs renewing.

## access

homelab can be SSH'd into from machines that are inside the tailnet and have a matching key pair (using `openssh`, **not** `tailscale ssh`. see `~/.ssh/authorized_keys`. this is enforced by firewall rules, allowing ssh only on the tailscale0 interface and denying it everywhere else:

    sudo ufw allow in on tailscale0 to any port 22 proto tcp
    sudo ufw deny 22/tcp

# NAS

storage for homelab and other personal data. using a synology NAS for setup ease and hands-off approach. it is stricly a storage device and does not run any workloads other than the native tailscale plugin.

## layout

The `data` share (`/volume1/data`) is mounted on the homelab at `/mnt/nas` over NFSv4.1, across the tailnet, and mounts at boot via `/etc/fstab`.

```
/mnt/nas/
├── media/  # jellyfin media
├── x/
├── y/
└── z/
```

## access

the nas can be accessed from any personal device on my tailnet using the tailnet IP, magicDNS, or friendly DNS. tagged devices (like the homelab) are owned by the tag, not by me, so they need an explicit grant, which is granted in the tailscale access policy.

it is accessed via tailnet instead of LAN for consistent practices. this costs some throughput and requires a dependency on `tailscaled`, but is a trade-off i prefer due to simplicity and consistency.

## rebuilding DSM from scratch

1. create a `btrfs` volume; create a shared folder (`data` for example)
2. install the `tailscale` package and run it. tag the new machine in tailscale with `tag:nas` to satisfy existing grants
3. the `tailscale` package defaults to userspace networking, where NFS sees connections from `127.0.0.1` instead of the client's tailnet IP and denies them. fix via control panel → task scheduler → triggered task → boot-up, user `root`:

   ```
   /var/packages/Tailscale/target/bin/tailscale configure-host; synosystemctl restart pkgctl-Tailscale.service
   ```

   run it once manually. verify with `ip addr show tailscale0` over SSH
4. set `NFSv4.1` via control panel → file services → NFS: enable, set max protocol to `NFSv4.1`
5. on the `data` share: edit → NFS permissions. create an entry with:
   - **hostname or IP**: the homelab's tailnet IP
   - **privilege**: read/write
   - **squash**: map all users to admin (avoids UID mismatches between container PUIDs and DSM's UIDs)
6. enable SMB for easy windows network drive mapping via control panel → file services → SMB; min protocol SMB2
7. enable automatic restarts: control panel → hardware & power → enable `restart automatically
   when power supply issue is fixed`

## rebuilding the mount on the homelab

```bash
sudo apt install nfs-common
sudo mkdir -p /mnt/nas
sudo chattr +i /mnt/nas # while unmounted
```

update `/etc/fstab`:

```
100.x.y.z:/volume1/data  /mnt/nas  nfs  nfsvers=4.1,hard,noatime,_netdev,nofail,retry=10,x-systemd.after=tailscaled.service,x-systemd.wants=tailscaled.service,x-systemd.mount-timeout=11min  0  0
```

then run:
```bash
sudo systemctl daemon-reload && sudo mount /mnt/nas && findmnt /mnt/nas
```

### above options explained

- **`chattr +i` on the mountpoint** — if the mount is missing, writes fail loudly instead of quietly filling the local disk
- **`hard`** — I/O blocks if the NAS disappears, rather than returning errors mid-write
- **`noatime`** — stops the client from writing an access-time update every time a file is read
- **`_netdev`** — marks this as a network filesystem, so systemd orders it after the network is up and unmounts it before teardown
- **`nofail`** — a dead NAS doesn't drop a headless box into emergency mode.
- **`retry=10` + `mount-timeout=11min`** — homelab boots faster than the nas. without retries the mount fails once and is never retried. systemd's default mount timeout is 90s so give it some breathing room
- **`x-systemd.after/wants=tailscaled`** — `_netdev` only waits for `network-online.target`, but we want to wait for tailscale
- **no `x-systemd.automount`** — autofs doesn't propagate into docker bind mounts under default `rprivate` propagation; containers see an empty dir or ELOOP

note: if the mount hangs, retry=10 is swallowing the real error. retest with retry=0.

# secrets

all secrets are tracked in `secrets.enc.yaml`, encrypted via `SOPS` using an `age`-generated X25519 key pair. note that secret values are still ingested via plaintext `.env` files in each docker compose stack that are not checked in; the value of the SOPS-encrypted file is the ability to check it into github, providing a source of truth and auditing for all things secrets related.

`.sops.yaml` defines the public key and holds the `path_regex` that decides which files sops applies that key to. the private key lives at `~/.config/sops/age/keys.txt`. since losing the private key renders `secrets.enc.yaml` a paperweight, the private key is also stored securely in Bitwarden.

 - `sops -e -i secrets.enc.yaml` encrypts a file in place
 - `sops -d secrets.enc.yaml` decrypts to stdout
 - `sops secrets.enc.yaml` decrypts in your editor (re-encrypts on save)

# backups

## docker

all docker volumes have been created as bind mounts and moved to a central location `/opt/appdata` for backup simplicity.

## backup script

backups run nightly on a cron and push an encrypted snapshot to `r2` via `restic`. see `scripts/homelab-backup.sh` for AI slop shell script that works just fine. the script first makes any live databases safe to copy, using `pg_dump` for teslamate's postgres and sqlite's `.backup` API for HA's recorder, grafana, and jellyfin. these are dumped at `/var/lib/homelab-backup/dumps`. sources are listed explicitly in the script rather than sweeping all of `/opt/appdata`, so a new service isn't backed up until it's added to `SOURCES`. retention is `restic forget --prune` in the script, **not** an R2 lifecycle policy. restic packs are shared between snapshots, so aging out an "old" object can break a recent one. the bucket should not have any lifecycle policies that would remove restic-managed files.

after making any changes to the script, run this from the repo root to copy it into `/usr/local/bin` with root ownership:

    sudo install -m 700 scripts/homelab-backup.sh /usr/local/bin/homelab-backup.sh

containers write files into their bind mounts as their own UIDs, often with restrictive permissions, so parts of `/opt/appdata` aren't readable by regular users. instead of `chown`ing the directory (this would break applications like postgres refusing to start if the data dir isn't owned by the user running it), we make the backup script run as root. this is added to root's crontab `sudo crontab -e`:

    00 3 * * * /usr/local/bin/homelab-backup.sh >> /var/log/homelab-backup-cron.log 2>&1

the script logs to `/var/log/homelab-backup.log`; the crontab line above also redirects stdout/stderr to `/var/log/homelab-backup-cron.log`, which catches failures that happen before the script can log anything itself. it also posts to a private discord channel: green on success, red on failure, yellow on a partial run.

`scripts/.env.example` lists the required vars. the AWS creds are from an r2 API token from the cloudflare dashboard. the RESTIC_PASSWORD is stored in Bitwarden alongside the `age` private key, as losing this renders backups useless.

## restore

restic reads the repo, password, and r2 creds from the environment, so load the env file first:

    set -a; . scripts/.env; set +a
    restic snapshots --tag homelab
    sudo -E /home/jaydee/.local/bin/mise exec -C ~/stacks -- restic restore latest --target /var/tmp/restore --tag homelab

restic recreates full absolute paths underneath `--target`, so the above gives you `/var/tmp/restore/opt/appdata/...` and `/var/tmp/restore/var/lib/homelab-backup/dumps/...`. on a fresh machine you can skip staging entirely and restore straight onto the real paths with `--target /`. **never do this on a running machine**, as restic will overwrite live database files underneath a running container.

live databases are deliberately excluded from the file backup, because they're captured separately via `pg_dump` / sqlite's `.backup` API. the dumps have to be placed by hand:

    dumps/homeassistant/home-assistant_v2.db  ->  /opt/appdata/homeassistant/config/
    dumps/jellyfin/jellyfin.db                ->  /opt/appdata/jellyfin/config/data/
    dumps/teslamate/grafana.db                ->  /opt/appdata/teslamate/grafana/
    dumps/teslamate/teslamate-db.sql          ->  psql import

when dropping a restored `.db` into place, delete the stale `-wal` and `-shm` siblings first.

# services

| service | url | magicdns | port |
|---|---|---|---|
| nas | https://nas.jaydeepappas.me | `nas.<tailnet>.ts.net:5000` | 5000 |
| homeassistant | https://ha.jaydeepappas.me | `homelab.<tailnet>.ts.net:8123` | 8123 |
| teslamate | https://teslamate.jaydeepappas.me | `homelab.<tailnet>.ts.net:4000` | 4000 |
| grafana | https://grafana.jaydeepappas.me | `homelab.<tailnet>.ts.net:3000` | 3000 |
| jellyfin | https://jellyfin.jaydeepappas.me | `homelab.<tailnet>.ts.net:8096` | 8096 |
| palworld | n/a | `homelab.<tailnet>.ts.net:8211` | 8211/udp |
