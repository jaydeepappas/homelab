# networking

### tailscale

all devices run `Tailscale`. devices within my tailnet can reach hosted services via MagicDNS `ocicat-bortle.ts.net` or Tailscale's assigned IPv4 address. for simplicity/memorability, internal IPs have been manually reassigned to `10.75.75.x` addresses.

### cloudflare

services can also be access via my domain `jaydeepappas.me`, which is owned by `Cloudflare`. there exists a wilcard `*.jaydeepappas.me` A record which points to the homelab IP `100.75.75.0`, so hosted subdomains are reachable via more human-friendly names.

### caddy

the above CF configuration requires `Caddy` as a reverse proxy to route traffic by some subdomain to some port. for example, incoming traffic matching `ha.jaydeepappas.me` is routed to `localhost:8123`. tailscale already encrypts all traffic in transit, so plain HTTP over the tailnet is low-risk. however, browsers and password managers can be finicky when visiting HTTP sites, so i've opted into using HTTPS.

Caddy handles HTTPS by default, but its default certificate challenges require Let's Encrypt to connect inbound to the homelab server, which it can't do since the A records point to a private tailnet IP. to get around this we opt into the DNS-01 challenge to prove domain ownership by creating a temporary TXT record through the Cloudflare API. the stock Caddy image ships without DNS provider modules, so `caddy/Dockerfile` uses `xcaddy` to bring in the [`caddy-dns/cloudflare`](https://github.com/caddy-dns/cloudflare) module for this certificate validation flow.

### access

homelab can be SSH'd into from machines that are inside the tailnet and have a matching kay pair. see `~/.ssh/authorized_keys`.

# backups

### docker

all docker volumes have been created as bind mounts and moved to a central location `/opt/appdata` for backup simplicity.

### backup script

backups are handled via script that runs on a cron and pushes a tarball to `r2`. see `scripts/homelab-backup.sh` for AI slop shell script that works just fine. the script uses `rclone`, whose config file lives at `~/.config/rclone/rclone.conf`. after making any changes to this script, run `sudo install -m 700 homelab-backup.sh /usr/local/bin/homelab-backup.sh` to copy into `/usr/local/bin` with root ownership.

since all docker mounts live in `/opt`, the backup script must run as root. this is added to crontab as `sudo`: `00 3 * * * /usr/local/bin/homelab-backup.sh >> /var/log/homelab-backup-cron.log 2>&1`

# secrets

all secrets are encrypted via `sops` using an `age`-generated X25519 key pair. encrypting secrets allows us to check encrypted files containing secrets into github, providing a source of truth and auditing for all things secrets related. `.sops.yaml` defines the public key and which files should be encrypted. the private key lives at `~/.config/sops/age/keys.txt`. since losing the private key renders `secrets.enc.yaml` a paperweight, the private key is also stored securely in Bitwarden.

run `sops -e -i secrets.enc.yaml` to encrypt a file in place.
run `sops -d secrets.enc.yaml` to decrypt a file to stdout.
run `sops secrets.enc.yaml` to decrypt in your editor (re-encrypts on save).


################################################

disorganized list of tools i need to consolidate/mise-ify

sops

rclone

age

tesla_auth

tailscale

htop
