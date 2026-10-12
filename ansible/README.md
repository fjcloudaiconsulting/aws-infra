# Ansible: Hetzner hosts and k3s HA (INFRA-64)

Terraform (`terraform/hetzner`) creates the servers, the private network and the database volume. Ansible does
everything on the hosts: base config, the volume mount on db-1, and k3s. There is no cloud-init user data.

| Host | Private IP | Role | k3s |
|------|-----------|------|-----|
| node-1 | 10.0.1.11 | app | server, label `role=app` |
| node-2 | 10.0.1.12 | app | server, label `role=app` |
| db-1 | 10.0.1.21 | db | server, label `role=db`, taint `role=db:NoSchedule`, volume at `/var/lib/rancher/k3s/storage` |

All three are k3s servers with embedded etcd (quorum 2 of 3), flannel `wireguard-native` over the private NIC.

`site.yml` runs four plays: refuse placeholder addresses, `node_base` on every host (swap, security-only
unattended upgrades without reboot, key-only SSH), `db_storage` on db-1, then the k3s servers one at a time
(`serial: 1`, stop at the first failure, wait for the node Ready and etcd healthy after each, db-1 last).

## Prerequisites (the machine running Ansible)

- Run every command from this directory (`ansible/`), so `ansible.cfg` applies.
- ansible-core 2.21 (CI pins 2.21.5), the Python `netaddr` library (`k3s.orchestration` uses `ansible.utils.ipwrap`),
  `sops`, and the owner age key (`export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`).
- `ansible-galaxy collection install -r requirements.yml` (installs into the git-ignored `collections/`).
- The deploy key at `~/.ssh/fjc-hetzner-deploy`.
- `inventory.yaml` holds real addresses: replace each `192.0.2.x` placeholder with that server's primary IPv4
  (`terraform/hetzner` outputs). The first play fails while any placeholder is left.

Never pass `-v` (or more) on a k3s run: the collection handles the token in task arguments. The k3s play has
`diff: false` so `--diff` cannot print it.

## The k3s token

`secrets.sops.yaml` holds `k3s_token`, encrypted to the owner age key only (`.sops.yaml`). It is decrypted lazily,
only when a k3s task needs it. A separate Ansible age key comes with the first non-owner machine that must decrypt
(INFRA-180). To rotate it on a fresh cluster only (a live cluster's token cannot simply be swapped):
`openssl rand -hex 32 | sed 's/^/k3s_token: /' | sops encrypt --filename-override ansible/secrets.sops.yaml > ansible/secrets.sops.yaml`
from the repo root. Never print it.

## Split brain: bootstrap versus join

The collection gives `cluster-init` to the first host of the `server` group (node-1) and points the others at
`api_endpoint`. `cluster-init` on an empty disk starts a brand-new etcd cluster, so a rebuilt node-1 run that way
would start a second cluster beside the live one. Here the collection's choice is overridden (our `server_config_yaml`
is merged last):

- `k3s_bootstrap` (default `false`). Only `-e k3s_bootstrap=true` gives node-1 `cluster-init: true`. The play refuses
  it unless every server is in the run and none has etcd data (`/var/lib/rancher/k3s/server/db/etcd`).
- Otherwise every server, node-1 included, has `cluster-init: false` and `server: https://<k3s_join_peer>:6443`:
  node-1 joins through node-2, node-2 and db-1 through node-1. A server without etcd data first checks that its peer's
  API answers, and stops if not (k3s would otherwise wait forever to join).
- To join through a different live peer (say node-1 is the rebuilt one and node-2 is also down), pass
  `-e k3s_join_peer=10.0.1.21`.

The first bootstrap runs the three servers as one batch, because the collection's own check waits until every server
has joined, which a one-host batch can never satisfy on an empty cluster. Every later run is `serial: 1`.

The collection restarts k3s on every server on every run, one at a time. Expect a short API blip per node.

## First bootstrap

1. `terraform/hetzner` applied; the volume `fjc-db` is attached to db-1.
2. Real addresses in `inventory.yaml` (a PR, merged).
3. `ssh -i ~/.ssh/fjc-hetzner-deploy root@<ip> true` for each host, to accept the host keys.
4. From `main` at the merged SHA:

   ```sh
   ansible-playbook site.yml --check --diff
   ansible-playbook site.yml -e k3s_bootstrap=true
   ```

5. Check: `ssh root@<node-1> k3s kubectl get nodes -o wide` shows three Ready nodes; db-1 carries the taint.
   The admin kubeconfig is fetched to `~/.kube/fjc-hetzner.yaml` (mode 0600) with the server set to node-1's
   private IP; it works only from inside the private network or over a tunnel.

## Steady-state run

1. Merge the change first.
2. `git switch main && git pull` and note the SHA.
3. `ansible-playbook site.yml --check --diff`, read it.
4. `ansible-playbook site.yml` (no `-e k3s_bootstrap`).
5. Paste the `PLAY RECAP` into the PR with the SHA.

## Rebuilding one node

Rebuild means Terraform replaces the server (`terraform apply -replace='hcloud_server.node["<name>"]'` via a TFC run);
the primary IP and private IP stay. Etcd keeps quorum with two of three servers, so rebuild one node at a time and
wait for it to be Ready before touching another.

Before the replace, from a working node: `k3s kubectl drain <name> --ignore-daemonsets --delete-emptydir-data`, then
`k3s kubectl delete node <name>`. Deleting the node removes its etcd member and its node-password secret, so the
rebuilt node can join under the same name.

After the replace: `ssh-keygen -R <public ip>`, accept the new host key, then
`ansible-playbook site.yml --limit <name>` (never with `k3s_bootstrap`).

### App node (node-2)

The steps above, nothing more.

### node-1

The same. node-1 has no etcd data after the rebuild, so it joins through node-2 (`k3s_join_peer`); it never
re-initialises the cluster.

### db-1

The volume holds the database files and survives the rebuild; it must be unmounted cleanly before the old server
goes away.

1. Scale the database StatefulSets in `data` to 0 and wait for the pods to go.
2. Drain and delete the node as above.
3. On db-1: `systemctl stop k3s && /usr/local/bin/k3s-killall.sh`, then `umount /var/lib/rancher/k3s/storage`
   (`findmnt /var/lib/rancher/k3s/storage` prints nothing).
4. Replace the server in TFC (the attachment follows the new server).
5. `ansible-playbook site.yml --limit db-1`. The play finds the volume, mounts it by its filesystem UUID and installs
   the k3s mount guard before k3s is installed.
6. Scale the StatefulSets back up; the local-path volumes are pinned to node `db-1` and come back with their data.

## Volume-missing drill (db-1)

What it proves: without the volume, k3s on db-1 does not start, so the databases cannot initialise empty data dirs
on the root disk.

1. Do the db-1 steps 1 to 3 above (databases at 0, node drained, k3s stopped, volume unmounted).
2. Detach the volume (Hetzner console or `hcloud volume detach fjc-db`).
3. `systemctl start k3s` fails with a dependency error after the device timeout (about 90 s);
   `systemctl status k3s` names `var-lib-rancher-k3s-storage.mount`.
4. `ansible-playbook site.yml --limit db-1 --check` stops at "Exactly one volume is attached".
5. A reboot in this state stops in emergency mode (the fstab entry has no `nofail`, on purpose); use the Hetzner
   console.
6. Re-attach the volume (`hcloud volume attach fjc-db --server db-1`, automount off), `mount -a`, `systemctl start k3s`,
   uncordon db-1, scale the StatefulSets back up.
