# Restoring the database dumps

The nightly `db-backup` CronJob (and, until INFRA-49, the droplet) writes one set per night to
`tbd-mysql-backups-884686184019`: `<prefix>/YYYY/MM/DD/{<db>,grants,manifest}_<stamp>`. The manifest
carries the table count and the SHA256 of the dump and grants files.

| prefix | database | written by |
|---|---|---|
| `tbd-mysql/` | MySQL `pfv2` (TBD) | `data/db-backup` |
| `ziftbook-postgres/` | Postgres `ziftbook` | `data/db-backup` |
| `pfv-data-01/` | MySQL `pfv2` (TBD, production until cutover) | the DigitalOcean droplet |

Only root (or the break-glass user) can read the dumps: the uploaders are put-only and the probe is
list-only (`terraform/tbd-backups`). Run everything from a Mac with AWS profile `tbd` and the
NetBird kubeconfig. Dumps stream from S3 straight into the pod; nothing lands on the Mac except the
manifest. Never print table contents or the grants file (it holds password hashes).

There are two targets:

- **Drill:** throwaway servers in a scratch namespace (steps 1-5). Run it before any one-way door
  that relies on the backups (droplet retirement, INFRA-49) and after a backup format change.
- **Real restore:** the `data` StatefulSet pod after its volume was lost (step 6).

## 1. Pick a set

```bash
export KUBECONFIG=~/.kube/platform AWS_PROFILE=tbd
B=tbd-mysql-backups-884686184019
PREFIX=tbd-mysql   # or ziftbook-postgres, pfv-data-01
M=$(aws s3api list-objects-v2 --bucket "$B" --prefix "$PREFIX/" \
  --query 'reverse(sort_by(Contents[?contains(Key, `/manifest_`)], &LastModified))[0].Key' --output text)
aws s3 cp "s3://$B/$M" manifest.json && jq . manifest.json   # date, tables, both keys and SHA256s
```

For an older night, set `M` to that night's manifest key.

## 2. Scratch servers (drill only)

```bash
NS=restore-drill
kubectl create namespace "$NS"
kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=baseline
kubectl -n "$NS" create secret generic root --from-literal=password="$(openssl rand -hex 24)"
kubectl apply -n "$NS" -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: deny-ingress
spec:
  podSelector: {}
  policyTypes: [Ingress]
---
apiVersion: v1
kind: Pod
metadata:
  name: mysql
spec:
  containers:
    - name: mysql
      image: mysql:8.4.11@sha256:6ea90827b1100f8f2ae306a539f86d2c264a26ed435a2a9f75551dd5c3aeb242
      env:
        - name: MYSQL_ROOT_HOST
          value: localhost
        - name: MYSQL_ROOT_PASSWORD
          valueFrom: {secretKeyRef: {name: root, key: password}}
      resources:
        limits: {memory: 768Mi}
---
apiVersion: v1
kind: Pod
metadata:
  name: postgres
spec:
  containers:
    - name: postgres
      image: postgres:18.6@sha256:5a5a84b19854a9ffaa54082c166ff4ec27473a361e496e5ea167f298f2da9722
      env:
        - name: POSTGRES_PASSWORD
          valueFrom: {secretKeyRef: {name: root, key: password}}
      resources:
        limits: {memory: 512Mi}
EOF
# The entrypoints run a socket-only server first; TCP answers only once the real server is up.
until kubectl -n "$NS" exec mysql -- mysqladmin ping -h127.0.0.1 --silent 2>/dev/null; do sleep 5; done
until kubectl -n "$NS" exec postgres -- pg_isready -qh 127.0.0.1 2>/dev/null; do sleep 5; done
```

The images are the ones `mysql.yaml`, `postgres.yaml` and `db-backup.yaml` pin; keep them in step.

## 3. Copy and check the files

```bash
POD=mysql   # postgres for ziftbook-postgres
# SQL on stdin, run as the database superuser over the pod's socket.
my() { kubectl -n "$NS" exec -i "$POD" -- sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -NB "$@"' sh "$@"; }
pg() { kubectl -n "$NS" exec -i "$POD" -- psql -U postgres -XAtq -v ON_ERROR_STOP=1 "$@"; }
for k in dump grants; do
  key=$(jq -r ".$k.key" manifest.json) sha=$(jq -r ".$k.sha256" manifest.json)
  aws s3 cp "s3://$B/$key" - | kubectl -n "$NS" exec -i "$POD" -- sh -c "cat >/tmp/$k.sql.gz"
  kubectl -n "$NS" exec "$POD" -- sh -c "echo '$sha  /tmp/$k.sql.gz' | sha256sum -c && gzip -t /tmp/$k.sql.gz"
done
```

Expect `/tmp/dump.sql.gz: OK` and `/tmp/grants.sql.gz: OK`. Anything else: stop, try an older night.

## 4. Restore

Grants first, so the data restore can reference the users.

**MySQL** (`tbd-mysql`, `pfv-data-01`). The dump has no `CREATE DATABASE`; the grants use
`CREATE USER IF NOT EXISTS`, so existing users keep their passwords.
For `pfv-data-01`, drop the `gzip -dc /tmp/grants.sql.gz | mysql -uroot &&` line: the droplet
writes password hashes as raw text, which MySQL rejects (`ERROR 1827`), and on the cluster the app
users come from the `mysql` secret anyway.

```bash
kubectl -n "$NS" exec "$POD" -- sh -c 'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
  gzip -dc /tmp/grants.sql.gz | mysql -uroot &&
  mysql -uroot -e "CREATE DATABASE IF NOT EXISTS pfv2" &&
  gzip -dc /tmp/dump.sql.gz | mysql -uroot pfv2 && echo restored'
```

**Postgres** (`ziftbook-postgres`). The globals recreate every role, so `role "postgres" already
exists` is the one expected error; the dump carries its own `CREATE DATABASE`.

```bash
kubectl -n "$NS" exec "$POD" -- sh -c '
  gzip -dc /tmp/grants.sql.gz | psql -U postgres -Xq 2>&1 | grep ERROR | grep -v "role \"postgres\" already exists"
  gzip -dc /tmp/dump.sql.gz | psql -U postgres -Xq -v ON_ERROR_STOP=1 -d postgres >/dev/null && echo restored'
```

Expect only `restored`.

## 5. Verify, then remove the drill

Table count must equal the manifest's `tables`. Row counts per table are the record of the drill.

**MySQL:**

```bash
jq .tables manifest.json
my <<'SQL'
SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = 'pfv2' AND table_type = 'BASE TABLE';
SELECT user FROM mysql.user WHERE user LIKE 'pfv%';
SQL
# Exact row count per table.
my <<'SQL' | my
SELECT CONCAT('SELECT ''', table_name, ''', COUNT(*) FROM pfv2.`', table_name, '`;')
FROM information_schema.tables WHERE table_schema = 'pfv2' AND table_type = 'BASE TABLE' ORDER BY table_name;
SQL
```

A round trip proves the rows match the dump byte for byte: re-dump with the backup's options and
compare the `INSERT` lines. Expect two identical hashes.

```bash
kubectl -n "$NS" exec "$POD" -- sh -c 'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
  gzip -dc /tmp/dump.sql.gz | grep "^INSERT INTO" | sha256sum
  mysqldump -uroot --single-transaction --routines --triggers --events --quick --hex-blob pfv2 | grep "^INSERT INTO" | sha256sum'
```

**Postgres:** the same checks, one statement per table.

```bash
jq .tables manifest.json
pg -d ziftbook <<'SQL'
SELECT count(*) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema');
SELECT rolname FROM pg_roles WHERE rolname NOT LIKE 'pg\_%' ORDER BY 1;
SQL
pg -d ziftbook <<'SQL' | pg -d ziftbook
SELECT format('SELECT %L, count(*) FROM %I.%I;', schemaname || '.' || tablename, schemaname, tablename)
FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY 1;
SQL
```

Remove the drill (this deletes the restored data with it) and the manifest:

```bash
kubectl delete namespace "$NS" && rm manifest.json
```

## 6. Real restore into `data`

Only into an **empty** database: a fresh volume, where the entrypoint has created `pfv2` or
`ziftbook` and the app users from the cluster secrets. If the database holds tables, stop and decide
first; never drop it on reflex.

1. Stop the writers: scale the app Deployment in `tbd-prod` or `ziftbook-staging` to 0.
2. Steps 1, 3 and 4 with `NS=data` and `POD=mysql-0` (or `postgres-0`). The grants keep the
   existing users' passwords, so the app's secret still works. For Postgres, the dump's
   `CREATE DATABASE ziftbook` fails if the entrypoint already created it: drop the empty database
   first (`psql -U postgres -c 'DROP DATABASE ziftbook'`, after checking it has no tables).
3. Step 5's checks, then remove the copies: `kubectl -n data exec <pod> -- rm /tmp/dump.sql.gz /tmp/grants.sql.gz`.
4. Scale the app back up and check it logs in.
