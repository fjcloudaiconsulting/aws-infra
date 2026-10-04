# Runbooks

Step-by-step procedures for the recurring changes. Why things are built this way is in
[architecture.md](architecture.md); every setting made outside git, and what breaks when it is wrong, is in
[configuration-map.md](configuration-map.md). Every command below uses the owner's kubeconfig
(`~/.kube/platform`, over NetBird) and never prints a secret value.

One-off procedures have their own page: the TBD cutover from DigitalOcean, with rehearsal and rollback, is
[tbd-cutover.md](tbd-cutover.md) (INFRA-48); database restores are
[`clusters/platform/data/RESTORE.md`](../clusters/platform/data/RESTORE.md).

## Follow Flux and rollouts

One GitRepository and one Kustomization, both named `flux-system`, apply all of `clusters/platform` from `main`.
Flux polls git every minute and re-applies at least every 10 minutes. In Argo CD terms: the Kustomization is the
only Application, `reconcile` is Sync, `suspend` is turning auto-sync off. Flux has no UI here; the CLI is the view.

```bash
export KUBECONFIG=~/.kube/platform

# Which commit is live: both lines show main@sha1:<merge commit>, READY True.
flux get sources git
flux get kustomizations
# Apply a merge now instead of waiting for the poll (source first, then the apply).
flux reconcile kustomization flux-system --with-source
# What the last apply changed ("Deployment/tbd-prod/scheduler configured") and any failure, newest last.
flux events --for Kustomization/flux-system
flux logs --level=error --since=1h
# Every object Flux manages (pruning removes what leaves git).
flux tree kustomization flux-system

# Rollouts: Flux only applies the manifest; it does not wait for pods (no healthChecks), so READY True can hide a
# crashing pod. Check the workload itself.
kubectl -n tbd-prod rollout status deploy/backend --timeout=5m
kubectl -n tbd-prod get deploy,pods                       # READY 1/1, RESTARTS 0
kubectl -n tbd-prod get events --sort-by=.lastTimestamp | tail -20
kubectl -n tbd-prod logs deploy/backend -c migrate        # init container: migrations
kubectl -n tbd-prod logs deploy/backend -f --since=10m    # app log, follow
kubectl -n tbd-prod get deploy -o jsonpath='{..image}' | tr ' ' '\n' | sort -u   # images actually running

# Hold Flux during manual work (it would revert live edits), then hand back. Resume re-applies git at once.
flux suspend kustomization flux-system
flux resume kustomization flux-system
```

Swap the namespace for `ziftbook-staging` or `data` (StatefulSets: `kubectl -n data rollout status sts/mysql`). A
release reaches the cluster only through a PR that changes an image tag under `clusters/`; there is no image
automation.

## Write or rotate a Kubernetes Secret

Secrets are `clusters/**/<name>.secret.yaml`, SOPS-encrypted to the cluster's age key (`.sops.yaml`). Flux decrypts
them in the cluster. Two rules decide how to work with one:

- **Encrypting a new file needs only the public key**, which is in `.sops.yaml`. This works on any laptop.
- **Editing an existing file needs the private key**, which is kept offline. Without it, `sops` fails with
  `Failed to get the data key required to decrypt the SOPS file`.

So put each value that is written or rotated on its own (an API key, a certificate) in **its own Secret file**, and
regenerate the whole file to change it. Example, a key read from a silent prompt (it stays out of shell history and
the screen):

```sh
F=clusters/platform/<dir>/<name>.secret.yaml   # the path must match .sops.yaml
read -rs K; printf %s "$K" | kubectl create secret generic <name> -n <namespace> \
  --from-file=<key>=/dev/stdin --dry-run=client -o yaml \
  | sops encrypt --filename-override "$F" --input-type yaml --output-type yaml /dev/stdin > "$F"; unset K
grep -c '<key>: ENC' "$F"   # must print 1; 0 means not encrypted: do not commit
```

Commit, push, merge. Flux applies it within a few minutes. A pod reads env at start, so after a key change run
`kubectl -n <namespace> rollout restart deploy/<name>`. To edit a multi-key Secret instead, load the offline key
first (`export SOPS_AGE_KEY_FILE=<path to the key file>`), then `sops edit <file>`.

## Add a public hostname for an app

Traffic path: Cloudflare (proxied, SSL mode Full strict), then Traefik on the node, then the app Service. Cloudflare
only accepts the origin if Traefik shows a Cloudflare **Origin CA** certificate for that zone.

1. **DNS:** add a proxied record in [`terraform/cloudflare/main.tf`](../terraform/cloudflare/main.tf) pointing to the
   node IP. Set the zone's SSL mode to strict there too, if this is the zone's first host on the node.
2. **Route:** add a Traefik `IngressRoute` in the app's folder under `clusters/platform/<namespace>/`, matching
   ``Host(`<host>`)`` on entryPoint `websecure`, with no `tls` block (the default TLS store serves the cert).
3. **Certificate:** an Origin CA certificate covers **one zone only**, because the Cloudflare dashboard refuses
   hostnames from another zone. Each zone has its own Secret in `kube-system`, listed in the `TLSStore default`
   ([`clusters/platform/traefik/traefik.yaml`](../clusters/platform/traefik/traefik.yaml)). Traefik picks the
   certificate by SNI.

   | Zone | Secret | Role |
   |---|---|---|
   | thebetterdecision.com | `origin-cert` | `defaultCertificate` |
   | ziftbook.com | `origin-cert-ziftbook` | `certificates` entry |

   A new host in an existing zone needs nothing here, because the certificate covers `*.<zone>`. For a **new
   zone**:
   1. Cloudflare dashboard, that zone, SSL/TLS > Origin Server > Create Certificate. Hostnames: `<zone>` and
      `*.<zone>`. Save the certificate and the private key to files outside the repo.
   2. From the repo root:

      ```sh
      F=clusters/platform/traefik/origin-cert-<app>.secret.yaml
      kubectl create secret tls origin-cert-<app> -n kube-system --cert=<crt> --key=<key> --dry-run=client -o yaml \
        | sops encrypt --filename-override "$F" --input-type yaml --output-type yaml /dev/stdin > "$F"
      grep -c 'tls.key: ENC' "$F"   # must print 1
      ```

      Then delete the key file.
   3. Add `- secretName: origin-cert-<app>` under `certificates` in the TLSStore.
4. **Check** after merge and the `cloudflare` workspace apply:

```sh
kubectl -n kube-system get secret origin-cert-<app> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName
curl -sI https://<host> | head -1    # 526 = Traefik showed the wrong cert; 404 = no IngressRoute matched
```

## Mail (Mailgun)

Every app sends through the Mailgun HTTP API with the official SDK (`mailgun-python`), in the EU region. No SMTP,
and no in-cluster mail server.

| Environment | Sending domain | DNS |
|---|---|---|
| Every dev/staging environment of every app | `m.fjconsulting.dev`, shared | `fjdev_mail` in `terraform/cloudflare` |
| Production | `m.<appdomain>`, one per app (TBD: `m.thebetterdecision.com`) | the app zone's records in `terraform/cloudflare` |

Each environment has its **own sending key**: send-only, scoped to the domain, and revoked on its own if it leaks.
A domain's record set is MX `mxa`/`mxb.eu.mailgun.org`, SPF `include:mailgun.org`, DKIM TXT, DMARC with Mailgun
reporting, and the tracking CNAME `email.m` to `eu.mailgun.org`.

**Add a dev environment** (for example TBD staging). The domain already exists, so only two steps are needed:

1. Mailgun > Sending > Domains > `m.fjconsulting.dev` > Sending API keys > Add sending key, with the environment
   name as the description.
2. Write the key to a new Secret `<app>-mailgun` (key `api-key`) in the environment's namespace, as in the Secret
   section. Then wire the app's env to it, with the app's own setting names: Ziftbook uses `ZIF_MAILGUN_DOMAIN`,
   `ZIF_MAILGUN_REGION` (eu) and `ZIF_MAILGUN_API_KEY` from `secretKeyRef ziftbook-mailgun/api-key` (see
   [`clusters/platform/ziftbook-staging/worker.yaml`](../clusters/platform/ziftbook-staging/worker.yaml)).

**Add a production domain:**

1. Add the domain in Mailgun (EU).
2. Copy its records into `terraform/cloudflare` (the TBD block is the model).
3. Merge and apply, then verify the domain in Mailgun.

If Mailgun's "automatic setup" for Cloudflare was used instead, the records already exist outside Terraform. Adopt
them with `import` blocks (id `<zone_id>/<record_id>`, from the Cloudflare API) rather than deleting them, as
INFRA-47 did. Once the apply has adopted them, remove the blocks in a follow-up PR (its plan must show no changes).

The domain `m.fjconsulting.dev` is shared, so Mailgun webhooks on it deliver every dev app's events to every
registered URL. Each app tags its messages and ignores events for messages it did not send.

**Check:**

```sh
# Use DoH: local dig can be intercepted (NetBird DNS) and answer empty even when the records exist.
curl -s -H 'accept: application/dns-json' 'https://cloudflare-dns.com/dns-query?name=m.fjconsulting.dev&type=MX'   # mxa/mxb.eu.mailgun.org
kubectl -n <namespace> exec deploy/<name> -- sh -c 'test -n "$<APP>_MAILGUN_API_KEY" && echo set'
```

Then check that the Mailgun dashboard shows the domain as verified. A lookup made before the records existed is
cached as "no record" for up to 30 minutes (the zone's SOA minimum), so Mailgun can show MX unverified for that
long after the apply. Press Verify again later; nothing needs changing.

## TBD smoke account

TBD's post-deploy smoke test (`scripts/smoke-test.sh` in the tbd repo) logs in as a dedicated production user: active,
email verified, **no MFA** by design (TBD-371, the script cannot answer a TOTP challenge). Its username is also the only
entry of `FOUNDER_COUNT_EXCLUDE_USERNAMES`, so it is not counted as a founder.

The credentials live in two places, kept equal:

- `tbd-prod/tbd-smoke` (`clusters/platform/tbd-prod/tbd-smoke.secret.yaml`, SOPS), keys `username` and `password`. Anyone
  with cluster access reads them for a manual run:

  ```bash
  SU=$(kubectl -n tbd-prod get secret tbd-smoke -o jsonpath='{.data.username}' | base64 -d)
  SP=$(kubectl -n tbd-prod get secret tbd-smoke -o jsonpath='{.data.password}' | base64 -d)
  SMOKE_USERNAME=$SU SMOKE_PASSWORD=$SP SMOKE_BASE_URL=https://app.thebetterdecision.com ~/src/tbd/scripts/smoke-test.sh; unset SU SP
  ```

- tbd repo Actions secrets `SMOKE_USERNAME` / `SMOKE_PASSWORD` (write-only), read only by the DigitalOcean deploy path;
  deleted after INFRA-49 (configuration map, Actions secrets). From then on the cluster copy is the only one and the
  rotation below skips `gh secret set`.

**Rotate** (never display the password; the hash is TBD's own `bcrypt`): generate it in memory, set the bcrypt hash on
the user row in the production database (`UPDATE users SET password_hash=..., password_changed_at=UTC_TIMESTAMP() WHERE
username=...`, expect 1 row), run the smoke test above with the new value, then `printf %s "$P" | gh secret set
SMOKE_PASSWORD -R fjcloudaiconsulting/tbd` and rewrite `tbd-smoke.secret.yaml` with
`jq -n ... | sops encrypt --input-type json --output-type yaml --filename-override <file> /dev/stdin > <file>`. Last
rotated 2026-10-04 (INFRA-48), on the DigitalOcean database before the cutover copy.

## Origin pull client certificate (Authenticated Origin Pulls)

The Lightsail firewall admits every Cloudflare IP, so any Cloudflare zone could reach the node. Zone-level
Authenticated Origin Pulls closes that (INFRA-93): Cloudflare presents our own client certificate when it connects to
the origin for thebetterdecision.com and ziftbook.com, and Traefik's `TLSOption default`
([`clusters/platform/traefik/traefik.yaml`](../clusters/platform/traefik/traefik.yaml)) fails the TLS handshake of any
client without a certificate signed by our CA.

Certificates come in **generations** (1, 2, ...): one CA and one leaf each, shared by both zones.

| Piece | Where |
|---|---|
| Leaf certificate (public) | `terraform/cloudflare/origin-pull/<gen>.crt`, uploaded to each zone by [`origin_pull.tf`](../terraform/cloudflare/origin_pull.tf) |
| Leaf private key | `cloudflare` workspace variable `origin_pull_private_key_<gen>` (sensitive). Terraform also keeps it in the workspace state, in clear inside the state file: remote state sharing stays off |
| CA certificate (public) | Secret `kube-system/origin-pull-ca-<gen>`, key `ca.crt`, file `clusters/platform/traefik/origin-pull-ca-<gen>.secret.yaml`, listed under `clientAuth.secretNames` |
| CA private key | Made on a RAM disk that was then ejected, so no further certificate the origin trusts can be signed |
| Expiry alert | `cloudflare_notification_policy.origin_pull_expiry`: email 30 and 14 days before |

Order matters, because the origin fails closed: **Cloudflare presents the certificate first, the origin requires it
after.** A `secretNames` entry without its Secret, or Cloudflare without an active certificate, takes every host
down. It fails open, silently, if a second `TLSOption` named `default` appears in any namespace, a router names its
own `tls.options`, or an entrypoint sets TLS options; `tests/test_origin_pull.py` rejects these in CI.

**Generate a generation** (owner, on a Mac with OpenSSL 3: `openssl version` prints `OpenSSL 3.x`). The keys exist
only on a RAM disk, never on the SSD or in a Time Machine snapshot. Set `G` to the new generation number.

```sh
G=1
hdiutil attach -nomount ram://32768            # prints a device, for example /dev/disk4
diskutil erasevolume HFS+ INFRA93 /dev/diskN   # the device printed above; ends with "Finished erase"
cd /Volumes/INFRA93 && umask 077
printf '%s\n' 'basicConstraints=critical,CA:TRUE' 'keyUsage=critical,keyCertSign,cRLSign' 'subjectKeyIdentifier=hash' > ca.ext
printf '%s\n' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature,keyEncipherment' 'extendedKeyUsage=clientAuth' 'authorityKeyIdentifier=keyid' > client.ext
openssl req -new -newkey rsa:4096 -nodes -keyout ca.key -out ca.csr -subj "/O=FJ Consulting/CN=FJ Consulting origin-pull CA $G"
openssl x509 -req -in ca.csr -key ca.key -sha256 -days 3660 -set_serial "0x$(openssl rand -hex 16)" -extfile ca.ext -out ca.crt
openssl req -new -newkey rsa:4096 -nodes -keyout client.key -out client.csr -subj "/O=FJ Consulting/CN=Cloudflare origin pull $G"
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -sha256 -days 3650 -set_serial "0x$(openssl rand -hex 16)" -extfile client.ext -out client.crt
openssl verify -CAfile ca.crt -purpose sslclient client.crt   # client.crt: OK
rm ca.key ca.csr client.csr ca.ext client.ext
mkdir -m 700 ~/Downloads/origin-pull-$G && cp ca.crt client.crt ~/Downloads/origin-pull-$G/
```

Then create the workspace variable from the key, and destroy the key. First quit any clipboard-history app and turn
off Handoff (System Settings > General > AirDrop & Handoff), so the key is neither kept nor sent to other devices.
HCP Terraform > workspace `cloudflare` > Variables > Add variable: Terraform variable, key
`origin_pull_private_key_<G>`, value from `pbcopy < /Volumes/INFRA93/client.key`, Sensitive on, HCL off. Then:

```sh
pbcopy < /dev/null && cd ~ && diskutil eject INFRA93   # "Disk INFRA93 ejected": the CA and leaf keys are gone
```

`~/Downloads/origin-pull-<G>/` now holds only the two public certificates, for the repo side (from the repo root, on
the PR branch, with `G` set again if this is a new shell):

```sh
mkdir -p terraform/cloudflare/origin-pull && cp ~/Downloads/origin-pull-$G/client.crt terraform/cloudflare/origin-pull/$G.crt
F=clusters/platform/traefik/origin-pull-ca-$G.secret.yaml
kubectl create secret generic origin-pull-ca-$G -n kube-system --from-file=ca.crt=$HOME/Downloads/origin-pull-$G/ca.crt \
  --dry-run=client -o yaml \
  | sops encrypt --filename-override "$F" --input-type yaml --output-type yaml /dev/stdin > "$F"
grep -c 'ca.crt: ENC' "$F"   # must print 1
openssl x509 -in terraform/cloudflare/origin-pull/$G.crt -noout -enddate   # the expiry for the configuration map
```

**Check** (the in-cluster probe stands in for a direct connection, which the firewall drops before TLS starts):

```sh
export KUBECONFIG=~/.kube/platform
curl -sSL -o /dev/null -w '%{http_code}\n' https://dev.ziftbook.com/                 # 200: our zones pass
curl -sS -o /dev/null -w '%{http_code}\n' https://ping.thebetterdecision.com/ping    # 200: the thebetterdecision.com zone passes too
kubectl -n default run aop-probe --rm -i --restart=Never --quiet --image=curlimages/curl:8.17.0 -- \
  curl -ksS -o /dev/null -w '%{http_code}\n' --connect-to dev.ziftbook.com:443:traefik.kube-system.svc.cluster.local:443 https://dev.ziftbook.com/
# 000 and a "curl: (56)" error (handshake refused; the verify-result text is about the server cert): enforced.
# Any HTTP code (307, 200, 404) means the origin accepts clients without our certificate.
```

**Rollback** (origin first, then Cloudflare; never the other way round). The Cloudflare dashboard cannot rescue an
outage here: the origin is what refuses the connection. Keep the CA Secrets in every path.

- Laptop: `flux --kubeconfig ~/.kube/platform suspend kustomization flux-system && kubectl --kubeconfig
  ~/.kube/platform -n kube-system delete tlsoption default` (traffic is back within seconds), then revert the PR that
  added `TLSOption default`, merge it, and `flux --kubeconfig ~/.kube/platform resume kustomization flux-system`.
- Phone, GitHub web: on the merged PR that added `TLSOption default`, press Revert, then merge the revert PR (owner
  bypass). Flux polls every minute and prunes, so the TLSOption is gone about 2 to 3 minutes after the merge.
- Phone, Lightsail browser SSH (Lightsail console > platform-node > Connect using SSH):
  `sudo k3s kubectl -n flux-system patch kustomization flux-system --type=merge -p '{"spec":{"suspend":true}}'`, then
  `sudo k3s kubectl -n kube-system delete tlsoption default`. Revert the PR as above, then resume with the same patch
  and `"suspend":false`.
- Cloudflare side, only if Cloudflare itself must stop presenting the certificate: set `enabled = false` on
  `cloudflare_authenticated_origin_pulls_settings.app` and apply. Deleting that resource does not turn it off.

**Rotate** (before the expiry in [configuration-map.md](configuration-map.md#expiries-and-rotation), or at once if a
leaf key may have leaked). No outage window: each step is its own merge (Flux applies a commit as one batch, and
Traefik fails closed if it sees a `secretNames` entry before its Secret), and Cloudflare keeps the old certificate
until the new one is active.

1. Generate generation N+1 as above. Commit `origin-pull-ca-<N+1>.secret.yaml` alone. Merge.
2. Add `origin-pull-ca-<N+1>` under `clientAuth.secretNames`, next to the current one. Merge. Traefik trusts both CAs;
   run the check.
3. Add `origin-pull/<N+1>.crt`, a `variable "origin_pull_private_key_<N+1>"` and its `origin_pull_keys` entry in
   `origin_pull.tf`. Merge and apply: the plan adds one certificate per zone and destroys nothing. With both active,
   Cloudflare uses the most recently deployed one.
4. Wait until each zone shows the new certificate **Active** (SSL/TLS > Origin Server > Authenticated Origin Pulls).
   Not Active within about 15 minutes, or `deployment_timed_out`: stop here and investigate; nothing is broken, the old
   certificate is still served.
5. Remove generation N from `origin_pull.tf` (variable, key entry, `.crt` file). Merge and apply: the plan destroys one
   certificate per zone. Run the check, then delete the workspace variable `origin_pull_private_key_<N>`.
6. Remove `origin-pull-ca-<N>` from `secretNames`. Merge. Delete its Secret file. Merge. Run the check and update the
   expiry row in the configuration map.

## Uptime alarm emails during a TBD deploy

The Route 53 uptime check reads `https://app.thebetterdecision.com/health/dependencies` (INFRA-48), not Traefik's
`/ping`. That is deliberate: a down app, MySQL or Valkey now alarms. The trade is that planned outages alarm too.
`platform-ping-unhealthy` fires after about 3 to 4 minutes of failures (the checkers need about 90 s, then the alarm
two 1-minute periods), so an outage longer than that sends an ALARM email and then an OK email:

- a slow TBD release (the Deployments use `Recreate`, and the backend's migrate init container runs first; a normal
  30 to 60 s release does not alarm),
- a MySQL or Valkey restart that takes that long (a version bump, a node reboot).

`/ping` never did that. An ALARM followed by OK within minutes of a merge in `tbd-prod` or `data` is expected. An
ALARM without an OK is an outage: check `kubectl -n tbd-prod get pods` and `curl -s https://app.thebetterdecision.com/health/dependencies`
(it names the failing dependency).

## Node memory and the upsize

The node is one Lightsail `medium_3_0` (4 GB, 3832Mi allocatable). Lightsail has no memory metric, so memory is read
from the kubelet; INFRA-108 turns the trigger below into a Grafana Cloud alert once INFRA-85 ships metrics. Until then,
run the check weekly and before every new workload.

### Check

```bash
export KUBECONFIG=~/.kube/platform
N=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
# available = node memory minus working set: what kubelet evictions use. rss leaves out page cache.
kubectl get --raw "/api/v1/nodes/$N/proxy/stats/summary" \
  | jq '.node.memory | {availableMi: (.availableBytes/1048576|floor), workingSetMi: (.workingSetBytes/1048576|floor), rssMi: (.rssBytes/1048576|floor)}'
kubectl describe node "$N" | sed -n '/Allocated resources/,/Events/p' | grep -E 'memory|Resource'   # requests, limits
kubectl get node "$N" -o jsonpath='MemoryPressure={.status.conditions[?(@.type=="MemoryPressure")].status}{"\n"}'   # False
# Containers killed for memory, and evicted pods: expect no output.
kubectl get pods -A -o json | jq -r '.items[] | select(any(.status.containerStatuses[]?; .lastState.terminated.reason == "OOMKilled" or .state.terminated.reason == "OOMKilled")) | "\(.metadata.namespace)/\(.metadata.name) OOMKilled"'
kubectl get pods -A --field-selector status.phase=Failed -o jsonpath='{range .items[?(@.status.reason=="Evicted")]}{.metadata.namespace}/{.metadata.name} Evicted{"\n"}{end}'
```

Baseline, 2026-10-04 12:11Z, TBD prod and Ziftbook staging live, little traffic: available 1335Mi (35%), working set
2497Mi, RSS 1806Mi, of which the k3s process (API server, datastore, kubelet, containerd) 846Mi and all pods 872Mi
(`mysql-0` 222Mi the largest). Requests 1916Mi (49%), limits 5290Mi (138%).

### Trigger

Upsize when any of these holds:

1. `availableMi` under **768** (20% of allocatable) at three checks on different days of normal running, or for 30
   minutes once the INFRA-108 alert exists.
2. Any container `OOMKilled`, any `Evicted` pod, or `MemoryPressure=True`.
3. Before a new workload goes on the node: `availableMi` minus its expected use (the RSS of a comparable workload
   already running, else its memory requests) would land under 768. Memory requests above 85% of allocatable
   (3257Mi) also block it, since the scheduler stops placing pods.

The next bundle is `large_3_0` (8 GB, 2 vCPU, 160 GB, $44 a month against $24); Lightsail has nothing between 4 and
8 GB. Bundle and spend are the owner's call, recorded on INFRA-80.

### Upsize: snapshot to a larger bundle

Lightsail cannot resize an instance: the path is a snapshot and a new instance from it on a larger bundle. The disk
moves whole (databases, k3s datastore, the SOPS key in `flux-system`, NetBird's peer identity on its volume), so
nothing re-enrols, and the static IP moves, so Cloudflare's origin, the DNS records and the uptime check keep their
values. Plan about 1 to 1.5 hours of downtime in a scheduled window. Run by the owner from the Mac (AWS profile
`tbd`, the NetBird kubeconfig) and the Lightsail console. The new instance is `platform-node-2` (the next one is
`-3`); Lightsail names are unique across resource types, so never reuse a name.

Two traps this order avoids:

- **Node name.** k3s names the node after the hostname, Lightsail derives the hostname from the private IP, and the
  new instance gets a new private IP. Every local-path volume (`data-mysql-0`, `data-postgres-0`, `data-valkey-0`,
  `netbird-state`) is pinned to the node name, so under a new name the databases stay Pending. Step 2 pins the name.
- **Two live copies.** Never run the old and the new instance at the same time: both are the same NetBird peer and
  both would write the nightly backup. The old one stays stopped unless you roll back.

Before the window: prepare the Terraform change in step 6 on a branch (a PR left unmerged; its plan fails until
`platform-node-2` exists).

**1. Stop writes, take fresh dumps, record row counts.**

```bash
export KUBECONFIG=~/.kube/platform AWS_PROFILE=tbd
cd "$(mktemp -d)"   # everything below that writes a file writes it here
flux suspend kustomization flux-system   # keeps the replicas at 0 until step 8
kubectl get deploy -A | grep -vE '^(kube-system|flux-system|netbird) '   # every app namespace on the node
kubectl -n tbd-prod scale deploy --all --replicas=0
kubectl -n ziftbook-staging scale deploy --all --replicas=0   # and every other app namespace listed above
kubectl -n data create job --from=cronjob/db-backup pre-upsize
kubectl -n data wait --for=condition=complete job/pre-upsize --timeout=30m   # a failed Job also waits it out: kubectl -n data get job
kubectl -n data get job pre-upsize -o jsonpath='{.status.startTime}{"\n"}'   # the dumps below must be newer
```

Then [RESTORE.md](../clusters/platform/data/RESTORE.md) step 1, without its `cd` line (stay in this directory),
for `tbd-mysql` (then `mv manifest.json tbd.json`) and `ziftbook-postgres` (then `mv manifest.json zif.json`), plus
any prefix the cluster has gained since (not the droplet's `pfv-data-01`): each `date` must be after the Job's start
(both UTC, as a stamp `20261004-120000` and as `2026-10-04T12:00:00Z`) and `tables` above 0. Record the row count per
table with the `NS=data` versions of RESTORE.md's helpers (read-only queries, counts only):

```bash
NS=data
my() { kubectl -n "$NS" exec -i mysql-0 -- sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -NB "$@"' sh "$@"; }
pg() { kubectl -n "$NS" exec -i postgres-0 -- psql -U postgres -XAtq -v ON_ERROR_STOP=1 "$@"; }
counts() (   # a subshell: pipefail and exit stay inside
  set -o pipefail
  my <<'SQL' | my || exit 1
SELECT CONCAT('SELECT ''', table_name, ''', COUNT(*) FROM tbd.`', table_name, '`;')
FROM information_schema.tables WHERE table_schema = 'tbd' AND table_type = 'BASE TABLE' ORDER BY table_name;
SQL
  pg -d ziftbook <<'SQL' | pg -d ziftbook || exit 1
SELECT format('SELECT %L, count(*) FROM %I.%I;', schemaname || '.' || tablename, schemaname, tablename)
FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY 1;
SQL
)
# MySQL lines are tab-separated, Postgres lines use |. Both must cover at least the dump's tables, or nothing was
# counted. Extend counts() for any database added since.
counts > before.txt && [ "$(grep -c "$(printf '\t')" before.txt)" -ge "$(jq .tables tbd.json)" ] \
  && [ "$(grep -c '|' before.txt)" -ge "$(jq .tables zif.json)" ] && echo complete
```

**2. Pin the node name.** Lightsail console > `platform-node` > Connect using SSH:

```bash
sudo grep -q '^node-name:' /etc/rancher/k3s/config.yaml || echo "node-name: $(hostname)" | sudo tee -a /etc/rancher/k3s/config.yaml
sudo grep node-name /etc/rancher/k3s/config.yaml
```

It must print the name `kubectl get nodes` shows (today `ip-172-26-3-190`). k3s reads it at its next start, which is
the new instance's first boot; nothing restarts now.

**3. Stop the old instance and snapshot it.** Stopped, so the databases and the k3s datastore are consistent on disk.

```bash
aws lightsail stop-instance --instance-name platform-node
aws lightsail get-instance-state --instance-name platform-node --query state.name   # repeat until "stopped"
SNAP=platform-node-pre-upsize-$(date -u +%Y%m%d)
aws lightsail create-instance-snapshot --instance-name platform-node --instance-snapshot-name "$SNAP"
aws lightsail get-instance-snapshot --instance-snapshot-name "$SNAP" --query instanceSnapshot.state   # until "available"
```

**4. Create the new instance.** Same zone, IPv4 only (the API defaults to dual stack), the 03:00 automatic snapshot.
A new instance opens 22 and 80 to the world: close them at once (repeat the command until it is accepted while the
instance is still pending), leaving only the console's SSH until step 6.

```bash
aws lightsail create-instances-from-snapshot --instance-snapshot-name "$SNAP" --instance-names platform-node-2 \
  --availability-zone eu-central-1a --bundle-id large_3_0 --ip-address-type ipv4 \
  --add-ons 'addOnType=AutoSnapshot,autoSnapshotAddOnRequest={snapshotTimeOfDay=03:00}'
aws lightsail put-instance-public-ports --instance-name platform-node-2 \
  --port-infos 'fromPort=22,toPort=22,protocol=tcp,cidrListAliases=lightsail-connect'
aws lightsail get-instance-state --instance-name platform-node-2 --query state.name   # until "running"
```

**5. Check the cluster.** NetBird reconnects from the new instance by itself (allow a few minutes).

```bash
kubectl get nodes -o wide   # one node, the pinned name, Ready, a new INTERNAL-IP
kubectl get pvc -A          # all Bound
kubectl get pods -A | grep -vE 'Running|Completed'   # only the header (the app Deployments are at 0)
```

If kubectl cannot connect after 10 minutes, use the console's SSH on `platform-node-2`: `sudo k3s kubectl get nodes`.
A second node, or database pods Pending with `volume node affinity conflict`, means step 2 did not take: add
`node-name: <the old name from step 2>` there (literally, not `$(hostname)`), `sudo systemctl restart k3s`, then `sudo k3s kubectl delete node <the new name>`.

**6. Terraform: move the static IP and the firewall to the new instance.** Open the prepared PR; the change in
`terraform/platform`:

```hcl
# The old instance and its firewall leave state but stay (stopped) for rollback.
removed {
  from = aws_lightsail_instance.node
  lifecycle {
    destroy = false
  }
}
removed {
  from = aws_lightsail_instance_public_ports.firewall
  lifecycle {
    destroy = false
  }
}
import {
  to = aws_lightsail_instance.node_2
  id = "platform-node-2"
}
resource "aws_lightsail_instance" "node_2" {
  name      = "platform-node-2"
  bundle_id = "large_3_0"
  # every other argument, the add_on and the lifecycle block exactly as in the old resource
}
```

plus: `aws_lightsail_static_ip_attachment.node` and a new `aws_lightsail_instance_public_ports.firewall_2` (the `firewall`
block copied whole, `depends_on` and `prevent_destroy` included) point at `node_2`; the alarm stack's `MonitoredResourceName` points at `node_2` with new logical IDs and
`AlarmName`s (`platform-node-2-...`), because CloudFormation cannot update `MonitoredResourceName`; the budget limit
if the owner raised it; and the docs naming `platform-node` or `medium_3_0` (configuration-map.md, architecture.md,
CLAUDE.md). The plan shows 1 import; the attachment replaced (its destroy is the
only one allowed: detach and attach, seconds); `firewall_2` added; `node_2` changed in place (the default tags) and the
stack (and budget) updated. The `import` and `removed` blocks can go in a later PR. If it plans to replace `node_2`, it fails on `prevent_destroy`: match the
attribute it names and plan again. Merge, approve the apply in the TFC UI, then:

```bash
aws lightsail get-static-ip --static-ip-name platform-node-ip --query 'staticIp.[attachedTo,ipAddress]'   # platform-node-2, 52.57.109.122
aws lightsail get-instance-port-states --instance-name platform-node-2 --query 'portStates[].[fromPort,state]'   # 443 and 22 open
curl -s -o /dev/null -w '%{http_code}\n' https://ping.thebetterdecision.com/ping   # 200: Cloudflare reaches Traefik
```

**7. Restore check.** Writes stopped before the dumps, so the moved databases must match step 1 exactly. In the same
shell (or define `my`, `pg` and `counts` again in that directory):

```bash
counts > after.txt && diff before.txt after.txt && echo identical
```

Anything but `identical`: do not hand back; roll back (below) or restore per RESTORE.md step 6 from the step 1 dumps.

**8. Hand back.**

```bash
flux resume kustomization flux-system   # re-applies git, Deployments back to their replicas
kubectl -n tbd-prod wait --for=condition=Available deploy --all --timeout=5m   # each app namespace
curl -s -o /dev/null -w '%{http_code}\n' https://app.thebetterdecision.com/health/dependencies   # 200
```

Then the [TBD smoke account](#tbd-smoke-account) run, and the check above: `availableMi` should have grown by about
4 GB. The uptime alarm sent an ALARM during the window; expect its OK now.

**9. The next morning.** RESTORE.md step 1 again: a nightly set from the new node, dated today, `tables` above 0.

**10. Retire the old instance (owner, one-way door), after 7 days without a rollback.** It is billed while stopped
($24 a month, prorated). Its automatic snapshots are deleted with it; the manual `$SNAP` is not (about $0.05 per GB
a month): delete it once the next restore drill passes.

```bash
aws lightsail delete-instance --instance-name platform-node
```

**Rollback.** Before step 6's apply: stop `platform-node-2`, wait for `stopped`, start `platform-node` (the static IP
and its firewall never left it), then step 8. After the apply: also `aws lightsail attach-static-ip --static-ip-name
platform-node-ip --instance-name platform-node` before starting it (its firewall rules are intact), and reconcile
Terraform in a follow-up PR (import `platform-node` back, `removed` for `node_2`). Never revert the step 6 PR: with
`node_2` gone from the configuration, Terraform plans to destroy `platform-node-2`. Writes made on the new node after
step 8 are lost on rollback unless dumped first (a Job from `cronjob/db-backup` under a new name, then RESTORE.md step 6 on the old node).
