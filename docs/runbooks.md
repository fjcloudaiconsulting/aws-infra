# Runbooks

Step-by-step procedures for the recurring changes. Why things are built this way is in
[architecture.md](architecture.md); every setting made outside git, and what breaks when it is wrong, is in
[configuration-map.md](configuration-map.md). Every command below uses the owner's kubeconfig
(`~/.kube/platform`, over NetBird) and never prints a secret value.

One-off procedures have their own page: the TBD cutover from DigitalOcean, with rehearsal and rollback, is
[tbd-cutover.md](tbd-cutover.md) (INFRA-48); database restores are
[`clusters/platform/data/RESTORE.md`](../clusters/platform/data/RESTORE.md).

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

| Piece | Where |
|---|---|
| Leaf certificate and key (one for both zones) | `cloudflare` workspace variables `origin_pull_certificate` and `origin_pull_private_key` (sensitive), uploaded to each zone by [`terraform/cloudflare/origin_pull.tf`](../terraform/cloudflare/origin_pull.tf). The key is also in that workspace's state, in clear inside the state file: keep remote state sharing off |
| CA certificate (public) | Secret `kube-system/origin-pull-ca`, key `ca.crt`, file `clusters/platform/traefik/origin-pull-ca.secret.yaml` |
| CA private key | Made on a RAM disk that was then ejected, so no further certificate the origin trusts can be signed |

Order matters, because the origin fails closed: **Cloudflare presents the certificate first, the origin requires it
after.** A missing `origin-pull-ca` Secret, or a `TLSOption default` that cannot load it, takes every host down. It
fails open, silently, if a second `TLSOption` named `default` appears in any namespace or a router names its own
`tls.options`; `tests/test_origin_pull.py` rejects both in CI.

**Check** (run both; the in-cluster probe stands in for a direct connection, which the firewall drops before TLS):

```sh
export KUBECONFIG=~/.kube/platform
curl -sSL -o /dev/null -w '%{http_code}\n' https://dev.ziftbook.com/                 # 200: our zones pass
curl -sS -o /dev/null -w '%{http_code}\n' https://ping.thebetterdecision.com/ping    # 200: the thebetterdecision.com zone passes too
kubectl -n default run aop-probe --rm -i --restart=Never --quiet --image=curlimages/curl:8.17.0 -- \
  curl -ksS -o /dev/null -w '%{http_code}\n' --connect-to dev.ziftbook.com:443:traefik.kube-system.svc.cluster.local:443 https://dev.ziftbook.com/
# 000 and a "curl: (56)" error (handshake refused; the verify-result text is about the server cert): enforced.
# Any HTTP code (307, 200, 404) means the origin accepts clients without our certificate.
```

**Rollback** (origin first, then Cloudflare; never the other way round):

1. Revert the PR that added `TLSOption default`. Flux applies it within a few minutes. Faster, while the revert is in
   review, with `KUBECONFIG=~/.kube/platform`: `flux suspend kustomization flux-system && kubectl -n kube-system
   delete tlsoption default`, then `flux resume kustomization flux-system` once the revert is merged. Keep the `origin-pull-ca` Secret.
2. Only if Cloudflare itself must stop presenting the certificate: set `enabled = false` in
   `cloudflare_authenticated_origin_pulls_settings.app` and apply. Deleting that resource does not turn it off.

**Rotate** (before the expiry in [configuration-map.md](configuration-map.md#expiries-and-rotation), or at once if the
leaf key may have leaked). Each step is its own merge: Flux applies a commit as one batch, and Traefik fails closed
if it sees a `secretNames` entry before its Secret. Name the new Secret after its year, for example
`origin-pull-ca-2036`.

1. Generate a new CA and leaf with the INFRA-93 owner steps, part A.
2. Add the new CA as its own Secret file (`kubectl create secret generic origin-pull-ca-<year> -n kube-system
   --from-file=ca.crt=ca.crt --dry-run=client -o yaml`, then encrypt as in the Secret section). Merge.
3. Add `origin-pull-ca-<year>` under `clientAuth.secretNames`, next to the current one. Merge. Traefik trusts both CAs.
4. In a quiet window, replace **both** workspace variables (always certificate and key together: a key-only change
   plans an update that does nothing), wipe the local key, and apply `cloudflare`. Terraform uploads the new
   certificate, then deletes the old one without waiting for the new one to become active, so expect proxied hosts to
   answer 52x for a few minutes, until each zone shows the new certificate **Active** in the dashboard. Then run the
   check.
5. Remove the old Secret's name from `secretNames`. Merge. Delete its file. Merge. Run the check and update the expiry
   row in the configuration map.
