# Cluster access (kubectl and Flux over NetBird)

The node has no public Kubernetes port. Admins reach the API server over NetBird: the `netbird`
Deployment in this directory makes the node a NetBird peer (`platform-node`), and a NetBird policy
lets only the `owner-devices` group reach it, on TCP 6443 only. kubectl authenticates as the
ServiceAccount `netbird/owner-admin` (cluster-admin) with a 90-day token.

Never paste a setup key, token or passphrase into a chat or ticket; every command below keeps them
off screen.

## 1. NetBird account and policy (once per NetBird account)

At https://app.netbird.io:

1. Groups: `k3s` and `owner-devices`.
2. Setup Keys -> Create Setup Key: name `platform-node`, Reusable off, Ephemeral off,
   auto-assigned group `k3s`, expiry 7 days.
3. Access Control -> Policies: disable the `Default` (All <-> All) policy.
4. Add Policy `owner-to-k3s-api`: source `owner-devices`, destination `k3s`, TCP `6443`, one way.

The policy is the security boundary. NetBird forwards traffic for the peer's IP to the node's
loopback, so an allow-all policy would expose the kubelet, metrics endpoints and Traefik (bypassing
Cloudflare).

## 2. Enrol the node (once, or after losing the state volume)

On a Mac with `sops` and the repo checked out, with the setup key in the clipboard:

```bash
read -rs NB_KEY   # paste the setup key, press Enter (nothing is shown)
[ -n "$NB_KEY" ] && printf 'NB_SETUP_KEY=%s\n' "$NB_KEY" \
  | kubectl create secret generic netbird-setup-key -n netbird --from-env-file=/dev/stdin --dry-run=client -o yaml \
  | sops encrypt --filename-override clusters/platform/netbird/setup-key.secret.yaml --input-type yaml --output-type yaml /dev/stdin \
  > clusters/platform/netbird/setup-key.secret.yaml
unset NB_KEY
grep -c 'NB_SETUP_KEY: ENC\[AES256' clusters/platform/netbird/setup-key.secret.yaml   # expect 1
```

Commit `setup-key.secret.yaml` in a PR and merge. Within a few minutes the dashboard shows
`platform-node` Connected in group `k3s`; turn off login expiration for that peer.

The key is single-use: the peer identity then lives on the `netbird-state` volume (excluded from
Flux pruning). If that volume is lost, the pod crash-loops on the spent key until a new key is
encrypted and merged as above (delete the stale `platform-node` peer first, or the DNS name gets
a suffix).

## 3. Add an admin device

1. Install the client: `brew install --cask netbirdio/tap/netbird-ui`, open it, Connect, log in.
2. In the dashboard, add the device's peer to group `owner-devices`.
3. Check: `netbird status -d | grep -A3 platform-node` lists the peer (`Idle` is normal with lazy
   connections; it connects on first use).

## 4. kubeconfig

**If someone already has access**, they mint the token from their machine and hand it over
through a password manager (never chat):

```bash
kubectl -n netbird create token owner-admin --duration=2160h
```

**First admin, nobody has access yet**: mint it on the node through the Lightsail console
(instance `platform-node` -> Connect using SSH), encrypted with a passphrase you type:

```bash
read -rs PASS && export PASS   # type a passphrase, press Enter
CT="$(sudo k3s kubectl -n netbird create token owner-admin --duration=2160h | openssl enc -aes-256-cbc -pbkdf2 -a -A -pass env:PASS)"; unset PASS
echo "$CT"; echo "length: ${#CT}"
```

Then on the admin's Mac (`read -rs` waits for Enter; nothing is echoed):

```bash
NODE=platform-node.netbird.cloud
export KUBECONFIG=~/.kube/platform
mkdir -p ~/.kube
curl -sfk "https://$NODE:6443/cacerts" > ~/.kube/platform-ca.crt && grep -c 'BEGIN CERTIFICATE' ~/.kube/platform-ca.crt   # expect 1
kubectl config set-cluster platform --server="https://$NODE:6443" \
  --certificate-authority="$HOME/.kube/platform-ca.crt" --embed-certs --tls-server-name=kubernetes

# Console route: decrypt. Handed-over token: skip to `read -rs TOKEN` instead.
read -rs CT                     # paste the ciphertext, press Enter
read -rs PASS && export PASS    # type the passphrase, press Enter
printf '%s' "$CT" | tr -d ' \r\n' | wc -c   # must equal the length printed on the node
TOKEN="$(printf '%s' "$CT" | tr -d ' \r\n' | openssl enc -d -aes-256-cbc -pbkdf2 -a -A -pass env:PASS)"; unset PASS CT

[ -n "$TOKEN" ] && kubectl config set-credentials owner-admin --token="$TOKEN" && echo "token set (${#TOKEN} chars)"; unset TOKEN
kubectl config set-context platform --cluster=platform --user=owner-admin
kubectl config use-context platform
chmod 600 ~/.kube/platform
kubectl get nodes   # expect the node Ready
```

`tls-server-name: kubernetes` is needed because the NetBird name is not in the k3s certificate;
`kubernetes` is a built-in SAN, so k3s needs no change.

Check that only 6443 is reachable (10250 and 443 must time out or refuse):

```bash
for p in 6443 10250 443; do nc -z -G 3 "$NODE" $p && echo "$p open" || echo "$p closed"; done
```

## 5. Renew and revoke

- Renew before the 90 days run out: `kubectl -n netbird create token owner-admin --duration=2160h`
  from a working kubeconfig, then `kubectl config set-credentials owner-admin --token=...` via
  `read -rs TOKEN` as above.
- Revoke every token at once: `kubectl -n netbird delete sa owner-admin`. Flux recreates the
  account within its interval; mint a new token through the console route.
- Anyone who can create pods or tokens in namespace `netbird` holds cluster-admin: never grant
  namespace-scoped rights there.

## 6. Flux view

- CLI: `flux get all -A`, `flux get kustomizations -A`.
- UI: `brew install --cask headlamp`; add `~/.kube/platform` under Settings -> Clusters, then
  Settings -> Plugin Catalog -> Flux.
