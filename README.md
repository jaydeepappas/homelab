# homelab

docker compose stacks for my home server, plus the networking, backup, and secrets tooling. everything runs baremetal on a single box reachable over tailscale, fronted by caddy for TLS + routing, with nightly backups pushed to cloudflare R2.

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

homelab can be SSH'd into from machines that are inside the tailnet and have a matching key pair. see `~/.ssh/authorized_keys`. this is enforced by firewall rules, allowing ssh only on the tailscale0 interface and denying it everywhere else:

    sudo ufw allow in on `tailscale0` to any port 22 proto tcp
    sudo ufw deny 22/tcp

# backups

## docker

all docker volumes have been created as bind mounts and moved to a central location `/opt/appdata` for backup simplicity.

## backup script

backups are handled via a script that runs nightly on a cron and pushes a tarball to `r2`. see `scripts/homelab-backup.sh` for AI slop shell script that works just fine. the script uses `rclone`, whose config lives at `~/.config/rclone/rclone.conf`. since the script runs as root (whose `~` is `/root`), it passes this path to rclone explicitly.

after making any changes to the script, run this from the repo root to copy it into `/usr/local/bin` with root ownership:

    sudo install -m 700 scripts/homelab-backup.sh /usr/local/bin/homelab-backup.sh

containers write files into their bind mounts as their own UIDs, often with restrictive permissions, so parts of `/opt/appdata` aren't readable by regular users. instead of `chown`ing the directory (this would break applications like postgres refusing to start if the data dir isn't owned by the user running it), we make the backup script run as root. this is added to root's crontab `sudo crontab -e`:

    00 3 * * * /usr/local/bin/homelab-backup.sh >> /var/log/homelab-backup-cron.log 2>&1

the script logs to `/var/log/homelab-backup.log`; the crontab line above also redirects stdout/stderr to `/var/log/homelab-backup-cron.log`, which catches failures that happen before the script can log anything itself. it also posts to a private discord channel on both success and failure.

# secrets

all secrets are tracked in `secrets.enc.yaml`, encrypted via `SOPS` using an `age`-generated X25519 key pair. note that secret values are still ingested via plaintext `.env` files in each docker compose stack that are not checked in; the value of the SOPS-encrypted file is the ability to check it into github, providing a source of truth and auditing for all things secrets related.

`.sops.yaml` defines the public key and holds the `path_regex` that decides which files sops applies that key to. the private key lives at `~/.config/sops/age/keys.txt`. since losing the private key renders `secrets.enc.yaml` a paperweight, the private key is also stored securely in Bitwarden.

 - `sops -e -i secrets.enc.yaml` encrypts a file in place
 - `sops -d secrets.enc.yaml` decrypts to stdout
 - `sops secrets.enc.yaml` decrypts in your editor (re-encrypts on save)

# services

| service | url | magicdns | port |
|---|---|---|---|
| homeassistant | https://ha.jaydeepappas.me | `homelab.<tailnet>.ts.net:8123` | 8123 |
| teslamate | https://teslamate.jaydeepappas.me | `homelab.<tailnet>.ts.net:4000` | 4000 |
| grafana | https://grafana.jaydeepappas.me | `homelab.<tailnet>.ts.net:3000` | 3000 |
| jellyfin | https://jellyfin.jaydeepappas.me | `homelab.<tailnet>.ts.net:8096` | 8096 |
| palworld | n/a | `homelab.<tailnet>.ts.net:8211` | 8211/udp |

# todo

disorganized list of tools i need to consolidate/mise-ify:

sops, rclone, age, tesla_auth, tailscale, htop

other things:

 - encrypt backups
 - scope tailscale node sharing with ACLs (`autogroup:shared`)
