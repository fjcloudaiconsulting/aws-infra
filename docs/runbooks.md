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
read -rs K; printf %s "$K" | kubectl create secret generic <name> -n <namespace> \
  --from-file=<key>=/dev/stdin --dry-run=client -o yaml > clusters/platform/<dir>/<name>.secret.yaml \
  && sops --encrypt --in-place clusters/platform/<dir>/<name>.secret.yaml; unset K
grep -c '<key>: ENC' clusters/platform/<dir>/<name>.secret.yaml   # must print 1; 0 means not encrypted: do not commit
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
   2. `kubectl create secret tls origin-cert-<app> -n kube-system --cert=<crt> --key=<key> --dry-run=client -o yaml > clusters/platform/traefik/origin-cert-<app>.secret.yaml`,
      then encrypt it as in the Secret section, and delete the key file.
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

- tbd repo Actions secrets `SMOKE_USERNAME` / `SMOKE_PASSWORD` (write-only), used by the release and deploy workflows.

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
kubectl create secret generic origin-pull-ca-$G -n kube-system --from-file=ca.crt=$HOME/Downloads/origin-pull-$G/ca.crt \
  --dry-run=client -o yaml > clusters/platform/traefik/origin-pull-ca-$G.secret.yaml \
  && sops --encrypt --in-place clusters/platform/traefik/origin-pull-ca-$G.secret.yaml
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

## Metrics to Grafana Cloud (Alloy)

One Grafana Alloy DaemonSet in `observability` (INFRA-85, design in [architecture.md](architecture.md), Telemetry)
sends metrics to the Grafana Cloud stack's OTLP gateway every 60 s:

- **Node:** CPU, memory, load, pressure, disks and filesystems (`job="node"`).
- **Pods and k3s:** per-container CPU, memory, throttling, OOM events and pod network from cAdvisor, plus the whole node
  (`id="/"`) and the k3s service (`id="/system.slice/k3s.service"`) (`job="cadvisor"`). PVCs live on the root disk
  (local-path), so `node_filesystem_avail_bytes{mountpoint="/"}` is their free space too. The kubelet's own `/metrics`
  is not scraped (about 58,000 control-plane series on k3s, which tripled Alloy's memory).
- **Apps:** whatever an app sends as OTLP/HTTP metrics to `http://alloy.observability.svc:4318` (set
  `OTEL_EXPORTER_OTLP_ENDPOINT` to that; adoption is INFRA-105 for TBD and INFRA-106 for Ziftbook). Only `tbd-prod`
  and `ziftbook-staging` may reach the port. Alloy deletes `url.*`, `client.address`, `http.request.header.*` and
  `exception.message` from every data point.

Traces and logs are not collected yet. Config: [`clusters/platform/observability/alloy/config.alloy`](../clusters/platform/observability/alloy/config.alloy);
a change there rolls the pod (the ConfigMap name carries a hash).

**Credentials** are Secret `observability/grafana-cloud` (keys `otlp-endpoint`, `instance-id`, `token`), file
`clusters/platform/observability/grafana-cloud.secret.yaml`. The token belongs to a Grafana Cloud access policy with the
`metrics:write` scope only. To write or rotate it, create a new token on that policy (Grafana Cloud > Administration >
Cloud access policies > the policy > Add token), regenerate the whole file (only the public key is needed), merge,
restart, then delete the old token:

```sh
read -rs T; printf %s "$T" | kubectl create secret generic grafana-cloud -n observability \
  --from-literal=otlp-endpoint='<OTLP endpoint>' --from-literal=instance-id='<Instance ID>' \
  --from-file=token=/dev/stdin --dry-run=client -o yaml > clusters/platform/observability/grafana-cloud.secret.yaml \
  && sops --encrypt --in-place clusters/platform/observability/grafana-cloud.secret.yaml; unset T
grep -cE '(otlp-endpoint|instance-id|token): ENC\[' clusters/platform/observability/grafana-cloud.secret.yaml   # 3
# After the merge (env is read at start):
kubectl -n observability rollout restart ds/alloy
```

**Check** it is working:

```sh
kubectl -n observability get pods                 # alloy-xxxxx 1/1 Running; CreateContainerConfigError = Secret missing
kubectl -n observability logs ds/alloy --since=10m | grep -E 'level=(error|warn)'
# Nothing, or only "Failed to open directory, disabling udev device properties" once at start (harmless).
# "401" or "Unauthorized" from otelcol.exporter.otlphttp: wrong token, instance ID or a revoked token.
kubectl -n observability top pod                  # memory: limit 256Mi
```

In Grafana Cloud, Explore with the Prometheus data source: `up` shows one series per job (`node`, `cadvisor`),
each 1. `sum by (namespace) (container_memory_working_set_bytes{pod!=""})` shows memory per namespace.
For the Alloy UI (pipeline graph, component health): `kubectl -n observability port-forward ds/alloy 12345`, then
http://localhost:12345.

**Memory:** measured locally at about 150 MiB working set against payloads captured from the node's kubelet; request
128Mi, limit 256Mi, `GOMEMLIMIT` 200MiB. If `kubectl top` shows it near the limit, look for a new high-cardinality
series in the app metrics before raising it.

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
