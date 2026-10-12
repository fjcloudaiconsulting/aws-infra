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
unattended upgrades without reboot, key-only SSH, the private NIC on DHCP via `/etc/netplan/60-private.yaml`
because a network attached after first boot is missing from cloud-init's netplan file), `db_storage` on db-1, then the k3s servers one at a time
(`serial: 1`, stop at the first failure, wait for the node Ready and etcd healthy after each, db-1 last).

## Prerequisites (the machine running Ansible)

- Run every command from this directory (`ansible/`), so `ansible.cfg` applies.
- ansible-core 2.21 (CI pins 2.21.5), the Python `netaddr` library (`k3s.orchestration` uses `ansible.utils.ipwrap`),
  `sops`, and the Ansible age key: `export SOPS_AGE_KEY_FILE=~/.config/sops/age/ansible-hetzner.txt`. The owner's
  cluster key is never needed for Ansible.
- `kubectl` on this machine. The k3s play checks it first: without it the collection silently skips fetching the
  admin kubeconfig.
- `ansible-galaxy collection install -r requirements.yml` (installs into the git-ignored `collections/`).
- The deploy key at `~/.ssh/fjc-hetzner-deploy`.
- `inventory.yaml` holds each server's primary IPv4 (they outlive server rebuilds). The first play refuses a
  `192.0.2.x` placeholder.

The collection handles the token in task arguments. The `k3s_server` role runs with `no_log` (so `-v` shows
`censored` for it) and the k3s play has `diff: false` (so `--diff` cannot print it). `-e k3s_no_log=false` lifts
`no_log` to debug a failing role; never share that output.

## The k3s token

`secrets.sops.yaml` holds `k3s_token`, encrypted to two age keys (`.sops.yaml`): the owner key and the Ansible key
(`~/.config/sops/age/ansible-hetzner.txt` on the operator laptop, which decrypts only `ansible/`). INFRA-180 adds a CI
recipient. It is decrypted lazily, only when a k3s task needs it. A lost Ansible key: make a new one, swap its public
key into `.sops.yaml`, then `sops updatekeys ansible/secrets.sops.yaml` with the owner key. To rotate the token itself,
on a fresh cluster only (a live cluster's token cannot simply be swapped):
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

Quorum guard: before restarting a server that has etcd data, the play checks that every server is in the run (none
failed or was unreachable in an earlier play, none left out by `--limit`) and that `kubectl get nodes` shows every
server Ready. Otherwise it stops before any restart, since restarting one member while another is down leaves etcd
at 1 of 3. So steady-state runs always cover all three servers; only a rebuilt node (no etcd data yet) runs alone.
After each restart it waits for that node's own `/readyz/etcd`, then for the node to be Ready.

## First bootstrap

1. `terraform/hetzner` applied; the volume `fjc-db` is attached to db-1.
2. The primary IPv4s in `inventory.yaml` match `terraform/hetzner`.
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

The order matters: stop k3s on the old node before deleting its Node object. Deleting the Node removes its etcd
member and its node-password secret; a k3s that is still running (or restarts) on the old node re-registers and
rejoins as a stale member, and the rebuilt node then hits a node-password conflict.

1. From a working node: `k3s kubectl drain <name> --ignore-daemonsets --delete-emptydir-data`.
2. On the OLD node: `systemctl disable --now k3s && /usr/local/bin/k3s-killall.sh`.
3. From a working node: `k3s kubectl delete node <name>`.
4. Replace the server in TFC.
5. `ssh-keygen -R <public ip>`, accept the new host key, then `ansible-playbook site.yml --limit <name>` (never with
   `k3s_bootstrap`). The rebuilt node has no etcd data, so the quorum guard lets it run alone; it joins a live peer.

If that run fails after k3s started on the new node, the node now has etcd data and the quorum guard would refuse a
plain rerun on it. Reset it instead:

1. db-1 only, FIRST: `systemctl stop k3s && /usr/local/bin/k3s-killall.sh && umount /var/lib/rancher/k3s/storage`,
   and check `findmnt /var/lib/rancher/k3s/storage` prints nothing. `k3s-uninstall.sh` deletes everything under the
   k3s data dir, including the contents of a volume still mounted inside it: the database files.
2. On the new node: `/usr/local/bin/k3s-uninstall.sh`.
3. If it registered (`k3s kubectl get nodes` on a working node lists it): `k3s kubectl delete node <name>` from a
   working node.
4. Rerun `ansible-playbook site.yml --limit <name>` (on db-1 this mounts the volume again before k3s is installed).

### App node (node-2)

The steps above, nothing more.

### node-1

The same. node-1 has no etcd data after the rebuild, so it joins through node-2 (`k3s_join_peer`); it never
re-initialises the cluster.

### db-1

The volume holds the database files and survives the rebuild; it must be unmounted cleanly before the old server
goes away.

1. Scale the database StatefulSets in `data` to 0 and wait for the pods to go.
2. Drain db-1 (step 1 above).
3. On the old db-1: `systemctl disable --now k3s && /usr/local/bin/k3s-killall.sh`, then
   `umount /var/lib/rancher/k3s/storage` (`findmnt /var/lib/rancher/k3s/storage` prints nothing).
4. `k3s kubectl delete node db-1` from a working node.
5. Replace the server in TFC (the attachment follows the new server).
6. `ssh-keygen -R <public ip>`, then `ansible-playbook site.yml --limit db-1`. The play finds the volume, mounts it by
   its filesystem UUID and installs the k3s mount guard before k3s is installed.
7. Scale the StatefulSets back up; the local-path volumes are pinned to node `db-1` and come back with their data.

## Volume-missing drill (db-1)

What it proves: without the volume, k3s on db-1 does not start, so the databases cannot initialise empty data dirs
on the root disk.

1. Scale the database StatefulSets in `data` to 0, drain db-1, then on db-1
   `systemctl stop k3s && /usr/local/bin/k3s-killall.sh` and `umount /var/lib/rancher/k3s/storage`. Keep the Node object.
2. Detach the volume (Hetzner console or `hcloud volume detach fjc-db`).
3. `systemctl start k3s` fails with a dependency error after the device timeout (about 90 s);
   `systemctl status k3s` names `var-lib-rancher-k3s-storage.mount`.
4. `ansible-playbook site.yml --limit db-1 --check` stops at "Exactly one volume is attached".
5. A reboot in this state stops in emergency mode (the fstab entry has no `nofail`, on purpose); use the Hetzner
   console.
6. Re-attach the volume (`hcloud volume attach fjc-db --server db-1`, automount off), `mount -a`, `systemctl start k3s`,
   uncordon db-1, scale the StatefulSets back up.
