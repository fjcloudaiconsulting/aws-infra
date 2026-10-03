# TBD cutover: DigitalOcean to the k3s node (INFRA-48)

TBD production moves from the DigitalOcean App Platform app `pfv` and its data droplet `pfv-data-01` to
`tbd-prod` on the Lightsail node, by stop, dump, restore (downtime window, owner ruling 2026-10-02). Valkey is not
migrated: every user logs in again. DigitalOcean stays stopped but intact for one week as the rollback target;
decommissioning is INFRA-49 (not before 2026-10-11).

Three PRs, merged in this order at the steps marked **MERGE** below, and one rollback branch:

| PR | Branch | Content | Merges |
|---|---|---|---|
| A1 prep | `feat/INFRA-48-tbd-prod-prep` | image tags, frontend runtime env, INFRA-83 client-IP env, `tbd.secret.yaml`, this runbook. Replicas stay 0 | before the rehearsal |
| A2 live | `feat/INFRA-48-tbd-prod-live` | backend and frontend replicas 1, IngressRoute `app.thebetterdecision.com`, `MIN_TABLES=1`, probe floor, `tbd` in `WATCH_REPOS` | real run, step 4 |
| B go | `feat/INFRA-48-tbd-dns` | Cloudflare `app` record proxied to the node, scheduler replicas 1 | real run, step 5 |
| C rollback | `revert/INFRA-48-tbd-dns-rollback` | `git revert` of B. Branch only; a PR only to roll back | rollback only |

A2 and B stay draft PRs until their step, so neither can be merged by accident. The scheduler goes live with the
DNS (B), not with A2, so a no-go before DNS never leaves two schedulers mailing from two copies of the data.

## Setup (every shell used below)

Mac with NetBird connected, AWS profile `tbd` logged in (`aws login --profile tbd`), `doctl` authenticated, the
aws-infra and tbd checkouts on `main`. Nothing here prints a secret value.

```bash
export KUBECONFIG=~/.kube/platform AWS_PROFILE=tbd
B=tbd-mysql-backups-884686184019 NS=data POD=mysql-0
# Names from the live StatefulSet: tbd / tbd_app once INFRA-73 is applied (pfv2 / pfv_app before it).
DB=$(kubectl -n data get sts mysql -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MYSQL_DATABASE")].value}')
DBUSER=$(kubectl -n data get sts mysql -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="MYSQL_USER")].value}')
# SQL on stdin, as MySQL root over the pod's socket.
my() { kubectl -n "$NS" exec -i "$POD" -- sh -c 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" exec mysql -uroot -NB "$@"' sh "$@"; }
# Prints NAME fingerprint (first 12 hex of sha256) for each TBD secret env var; the same line runs on DigitalOcean.
FP='for k in JWT_SECRET_KEY MFA_ENCRYPTION_KEY AI_CREDENTIAL_ENCRYPTION_KEY AI_CREDENTIAL_ENCRYPTION_KEY_PREV API_TOKEN_HMAC_KEY MAILGUN_API_KEY MAILGUN_WEBHOOK_SIGNING_KEY GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET CAPTCHA_SECRET FOUNDER_COUNT_EXCLUDE_USERNAMES; do printf "%s %s\n" "$k" "$(printenv "$k" | sha256sum | cut -c1-12)"; done'
echo "$DB $DBUSER"   # tbd tbd_app
```

The droplet commands run as root on `pfv-data-01` (`doctl compute ssh pfv-data-01`); its `mysql` reads
`/root/.my.cnf`.

## 1. Write the tbd secret (owner, before the rehearsal, about 30 minutes)

`tbd-prod/tbd` takes every value from the DigitalOcean app except the two connection URLs, which point at the
cluster's MySQL and Valkey and are built from their Secrets in the cluster. The keys must equal DigitalOcean's, or
logins (JWT, PAT pepper) and encrypted columns (MFA, AI credentials) break.

1. DigitalOcean control panel > Apps > `pfv` > Console > component `backend`. This opens a shell in the running
   container. Run the `FP` loop (paste the quoted value of `FP` as one line) and keep the output: it is the
   reference.
2. In the aws-infra checkout on branch `feat/INFRA-48-tbd-prod-prep`, run the block below. For each name it
   prompts silently: in the DO console run `printenv <NAME>`, copy the value, paste it at the prompt, press Enter.
   The value shows in the DO browser console only, never in the local terminal; clear the DO console after.
   An empty answer is accepted only for `AI_CREDENTIAL_ENCRYPTION_KEY_PREV` (the key is then left out; the
   manifests read it as optional).

```bash
F=clusters/platform/tbd-prod/tbd.secret.yaml
sts() { kubectl -n data get sts mysql -o jsonpath="{.spec.template.spec.containers[0].env[?(@.name==\"$1\")].value}"; }
sec() { kubectl -n data get secret "$1" -o jsonpath="{.data.$2}" | base64 -d; }
J=$(DBPW=$(sec mysql app-password) VKPW=$(sec valkey password) DB=$(sts MYSQL_DATABASE) DBUSER=$(sts MYSQL_USER) jq -nc '{
  "database-url": "mysql+aiomysql://\(env.DBUSER):\(env.DBPW | @uri)@mysql.data.svc.cluster.local:3306/\(env.DB)",
  "redis-url": "redis://:\(env.VKPW | @uri)@valkey.data.svc.cluster.local:6379/0"}')
for k in JWT_SECRET_KEY MFA_ENCRYPTION_KEY AI_CREDENTIAL_ENCRYPTION_KEY AI_CREDENTIAL_ENCRYPTION_KEY_PREV API_TOKEN_HMAC_KEY \
         MAILGUN_API_KEY MAILGUN_WEBHOOK_SIGNING_KEY GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET CAPTCHA_SECRET FOUNDER_COUNT_EXCLUDE_USERNAMES; do
  while :; do
    printf '%s: ' "$k"; IFS= read -rs V; echo
    [ -n "$V" ] && break
    [ "$k" = AI_CREDENTIAL_ENCRYPTION_KEY_PREV ] && break
    echo "  empty, paste again"
  done
  [ -n "$V" ] && J=$(J=$J K=$(printf %s "$k" | tr 'A-Z_' 'a-z-') V=$V jq -nc 'env.J | fromjson | .[env.K] = env.V')
done
unset V; pbcopy </dev/null   # empty the clipboard the values went through
# Fingerprints of what was pasted: must equal the DO console output of step 1, line by line.
for k in $(printf %s "$J" | jq -r 'keys[]' | grep -v -e database-url -e redis-url); do
  printf '%s %s\n' "$(printf %s "$k" | tr 'a-z-' 'A-Z_')" "$(printf %s "$J" | jq -r --arg k "$k" '.[$k]' | shasum -a 256 | cut -c1-12)"
done
# Encrypt straight from memory to the file: the plaintext never touches the disk.
printf %s "$J" | jq '{apiVersion: "v1", kind: "Secret", metadata: {name: "tbd", namespace: "tbd-prod"}, type: "Opaque", stringData: .}' |
  sops encrypt --input-type json --output-type yaml --filename-override "$F" /dev/stdin >"$F"; unset J
grep -c ': ENC\[' "$F"                                  # 14 (13 keys + mac), or 13 without ..._PREV
python3 .github/scripts/check-sops-secrets.py clusters  # exit 0
```

A fingerprint that differs: rerun the block (it regenerates the whole file). Fingerprints are unsalted short hashes
and some values are guessable (usernames, the Google client id): compare them on screen, never paste them into Jira
or a PR. Then commit and push to the A1 branch:

```bash
git add "$F" && git commit -m "feat(clusters): tbd-prod secret from the DigitalOcean app (INFRA-48)" && git push
```

## 2. Preflight (before the rehearsal and again at the window start, 15 minutes)

Every check must print what its comment says. Any other output is a no-go until explained.

```bash
kubectl get nodes --no-headers | awk '{print $2}'                       # Ready
kubectl top node --no-headers | awk '{print $4}'                        # under 2600Mi
aws sts get-caller-identity --query Account --output text               # 884686184019
TAG=$(gh release view -R fjcloudaiconsulting/tbd --json tagName --jq .tagName); echo "$TAG"   # the release in the A1 pins
gh release view "$TAG" -R fjcloudaiconsulting/tbd --json body --jq .body | grep -c INFRA-83     # 1 or more
CIP=<the client-IP env name from the INFRA-83 PR>
grep -c "name: $CIP" clusters/platform/tbd-prod/backend.yaml clusters/platform/tbd-prod/scheduler.yaml   # 1 each: without it every user shares Traefik's IP (one rate-limit bucket)
curl -s https://app.thebetterdecision.com/health                        # DO: {"status":"ok",... "version":"<TAG without v>" ...}
grep -rhoE 'ghcr\.io/fjcloudaiconsulting/tbd/[a-z]+:v[0-9.]+' clusters/ | sort -u   # backend, frontend, migrations, all :$TAG
kubectl -n tbd-prod get secret tbd -o json | jq '.data | length'        # 13 (12 without ..._PREV)
kubectl -n tbd-prod get deploy --no-headers | awk '{print $1, $2}'      # backend 0/0, frontend 0/0, scheduler 0/0
kubectl get ingressroute -A --no-headers | awk '{print $1"/"$2}'        # kube-system/ping, ziftbook-staging/frontend: no tbd route
kubectl -n data get pod mysql-0 valkey-0 --no-headers | awk '{print $1, $2}'   # 1/1 each
my <<<"SELECT user FROM mysql.user WHERE user LIKE 'tbd%' OR user LIKE 'pfv%' ORDER BY 1"   # tbd_app, tbd_backup (INFRA-73)
kubectl -n data get jobs --sort-by=.status.startTime --no-headers | tail -1   # db-backup-... Complete
# The rollback target: DO still serves the custom domain on its own address, whatever our DNS says.
curl -s --connect-to app.thebetterdecision.com:443:pfv-xccvs.ondigitalocean.app:443 https://app.thebetterdecision.com/health   # {"status":"ok"...}
echo | openssl s_client -connect pfv-xccvs.ondigitalocean.app:443 -servername app.thebetterdecision.com 2>/dev/null | openssl x509 -noout -enddate   # after 2026-10-12 (Nov 19 2026 on 2026-10-03)
kubectl -n kube-system get secret origin-cert -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName   # *.thebetterdecision.com
git ls-remote origin refs/heads/revert/INFRA-48-tbd-dns-rollback | wc -l   # 1
```

At the window start also: A1 merged; A2 and B open with CI green; B's `Terraform Cloud/FlamaCorp/cloudflare` check
says `1 to change` and nothing else (`gh pr checks feat/INFRA-48-tbd-dns`).

## 3. Restore procedure (used by the rehearsal and the real run)

Input: `M`, the S3 key of a `pfv-data-01` manifest. The droplet's grants file is skipped (its hashes are raw text,
ERROR 1827; the cluster's users come from the `mysql` Secret). The dump has no `CREATE DATABASE` or `USE`, so it
loads into `$DB` whatever the droplet called it.

```bash
cd "$(mktemp -d)"   # keeps manifest.json out of the repo
aws s3 cp "s3://$B/$M" manifest.json && jq '{date, tables, database}' manifest.json
# Gate: tbd-prod has never served the public (no tbd IngressRoute), so $DB holds nothing worth keeping.
kubectl -n tbd-prod get ingressroute -o name | wc -l                   # 0
kubectl -n tbd-prod get deploy backend -o jsonpath='{.spec.replicas}'; echo   # 0
my <<<"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB'"   # 0, or the rehearsal's count
# Empty it (a no-op on a fresh database, the rehearsal's copy otherwise). Grants on $DB.* survive DROP DATABASE.
my <<<"DROP DATABASE \`$DB\`; CREATE DATABASE \`$DB\`"
key=$(jq -r .dump.key manifest.json) sha=$(jq -r .dump.sha256 manifest.json)
aws s3 cp "s3://$B/$key" - | kubectl -n "$NS" exec -i "$POD" -- sh -c 'cat >/tmp/dump.sql.gz'
kubectl -n "$NS" exec "$POD" -- sh -c "echo '$sha  /tmp/dump.sql.gz' | sha256sum -c && gzip -t /tmp/dump.sql.gz"   # /tmp/dump.sql.gz: OK
kubectl -n "$NS" exec "$POD" -- sh -c 'gzip -dc /tmp/dump.sql.gz | grep -cE "DEFINER=|^USE |^CREATE DATABASE"'      # 0
kubectl -n "$NS" exec "$POD" -- sh -c 'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
  gzip -dc /tmp/dump.sql.gz | mysql -uroot "$1" && echo restored' sh "$DB"                                         # restored
jq .tables manifest.json
my <<<"SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$DB' AND table_type = 'BASE TABLE'"     # same number
my <<<"SHOW GRANTS FOR '$DBUSER'@'%'" | grep -c "ON \`$DB\`"             # 1
# Round trip: the rows re-dumped from the cluster equal the droplet's dump. Two identical hashes, not e3b0c442...
kubectl -n "$NS" exec "$POD" -- sh -c 'export MYSQL_PWD="$MYSQL_ROOT_PASSWORD"
  gzip -dc /tmp/dump.sql.gz | grep "^INSERT INTO" | sha256sum
  mysqldump -uroot --single-transaction --quick --hex-blob "$1" | grep "^INSERT INTO" | sha256sum
  rm /tmp/dump.sql.gz' sh "$DB"
rm manifest.json; cd -
```

About 5 minutes for the ~750 KB dump. A mismatch anywhere: stop, do not start the app on that data.

## 4. Rehearsal (Sunday midday, about 75 minutes)

Goal: the real secret, images and a copy of production data run on k3s while DigitalOcean stays live. So the copy
must not be reachable publicly, run jobs or send mail: no IngressRoute (A2 is not merged), scheduler 0, and egress
limited to the cluster for the duration.

Needs: A1 merged and applied (preflight green).

```bash
# 1. Hold Flux (it would scale back to 0) and pick last night's droplet dump.
flux suspend kustomization flux-system
M=$(aws s3api list-objects-v2 --bucket "$B" --prefix pfv-data-01/ \
  --query 'reverse(sort_by(Contents[?contains(Key, `/manifest_`)], &LastModified))[0].Key' --output text); echo "$M"   # today, 02:00
# 2. Section 3 with this M.
# 3. Egress to the cluster only (no Mailgun, Google, Turnstile). Flux recreates egress-no-imds on resume.
kubectl -n tbd-prod delete networkpolicy egress-no-imds
kubectl -n tbd-prod apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rehearsal-cluster-only
  namespace: tbd-prod
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
    - to:
        - namespaceSelector: {}
EOF
# 4. Backend and frontend only. The scheduler stays 0.
kubectl -n tbd-prod scale deploy/backend deploy/frontend --replicas=1
kubectl -n tbd-prod rollout status deploy/backend --timeout=5m && kubectl -n tbd-prod rollout status deploy/frontend --timeout=5m
kubectl -n tbd-prod logs deploy/backend -c migrate | tail -5             # no error; nothing to apply when DO runs $TAG
kubectl -n tbd-prod exec deploy/backend -- python -c "
import socket
try:
    socket.create_connection(('api.eu.mailgun.net', 443), timeout=5); print('OPEN')
except OSError as e:
    print('blocked', type(e).__name__)"                                  # blocked (TimeoutError or ConnectionRefusedError); OPEN: stop
kubectl -n tbd-prod exec deploy/backend -- sh -c "$FP"                  # equal to the DO console output (section 1)
# 5. Smoke over port-forward with TBD's own scripts/smoke-test.sh (its login writes only to this copy).
kubectl -n tbd-prod port-forward svc/backend 8000:8000 >/dev/null & PF1=$!
kubectl -n tbd-prod port-forward svc/frontend 3000:3000 >/dev/null & PF2=$!; sleep 3
curl -s localhost:8000/health                                           # {"status":"ok","version":"<TAG without v>",...}
curl -s -o /dev/null -w '%{http_code}\n' localhost:3000/login           # 200
read -r SU; read -rs SP   # the smoke account (no MFA); not exported, handed to the script only
SMOKE_USERNAME=$SU SMOKE_PASSWORD=$SP SMOKE_BASE_URL=http://localhost:8000 ~/src/tbd/scripts/smoke-test.sh   # every line ✓, exit 0
kill $PF1 $PF2
# 6. Rollback path: DO still serves the domain directly, and C is exactly B reversed.
curl -s --connect-to app.thebetterdecision.com:443:pfv-xccvs.ondigitalocean.app:443 https://app.thebetterdecision.com/health   # {"status":"ok"...}
git fetch origin && git diff "$(git merge-base origin/main origin/feat/INFRA-48-tbd-dns)" origin/revert/INFRA-48-tbd-dns-rollback --stat   # empty
# 7. Tear down: back to replicas 0 and the normal egress policy (Flux first, so egress is never fully open).
kubectl -n tbd-prod scale deploy/backend deploy/frontend --replicas=0
flux resume kustomization flux-system   # waits for the apply: recreates egress-no-imds
kubectl -n tbd-prod delete networkpolicy rehearsal-cluster-only
kubectl -n tbd-prod get deploy,networkpolicy --no-headers | awk '{print $1, $2}'   # deployments 0/0; egress-no-imds back, no rehearsal policy
```

Leave the restored copy in `$DB`: the real run empties it (section 3). Record the durations and the table count in
a Jira comment. Go for the window only if every step printed its expected value.

Rehearsal rollback at any point: step 7. Nothing in the rehearsal touches DigitalOcean.

## 5. Real run (Sunday evening window, about 1h45)

Times from the window start (T). Each go/no-go (**G**) is the owner's call. Read `SU` and `SP` once as in
rehearsal step 5; `unset SP` at the end of the window.

| T | Step | Who |
|---|---|---|
| 0:00 | Preflight (section 2). **G1** | agent, owner reads |
| 0:15 | Step 1, freeze DigitalOcean | owner |
| 0:30 | Step 2, final dump | owner |
| 0:35 | Step 3, restore. **G2** | agent |
| 0:50 | Step 4, **MERGE A2**, smoke over port-forward. **G3** | owner merges, agent smokes |
| 1:10 | Step 5, **MERGE B**, approve the `cloudflare` apply, public smoke. **G4**, final go | owner |
| 1:30 | Step 6, backup proof, watch | agent |

### Step 1. Freeze DigitalOcean (15 min)

1. Stop TBD releases from deploying to DO: the release workflow's `deploy` job pushes `.do/app.yaml`, which would
   un-archive the app. Overwrite its token in GitHub, then revoke the real one so no valid copy is left unheld:

   ```bash
   gh secret set DIGITALOCEAN_ACCESS_TOKEN -R fjcloudaiconsulting/tbd --body disabled-by-INFRA-48
   gh secret list -R fjcloudaiconsulting/tbd | grep DIGITALOCEAN   # updated just now
   ```

   DO control panel > API > Tokens: delete the token the tbd repo used (a rollback mints a new one, R1).
2. DO control panel > Apps > `pfv` > Settings > Archive mode > **Archive**, type the app name, confirm. Wait for the
   deployment to finish.

   ```bash
   curl -s https://app.thebetterdecision.com/health | head -c 80; echo   # no longer {"status":"ok"...}: DO's offline page
   ```
3. On the droplet (`doctl compute ssh pfv-data-01`):

   ```bash
   mysql -NBe "SELECT COUNT(*) FROM information_schema.processlist WHERE user = 'pfv_app'"   # 0 (repeat until 0)
   # Belt for the rollback week: a DO scheduler that comes back skips its ticks for 8 days...
   REDISCLI_AUTH=$(awk '/^requirepass/{print $2}' /etc/redis/conf.d/00-static.conf) \
     redis-cli --no-auth-warning SET scheduler:tick:lock INFRA-48 EX 691200   # OK (exactly; NOAUTH means nothing was set)
   # ...and nothing can write to the droplet's data (until a mysqld restart).
   mysql -e "SET GLOBAL super_read_only = ON"; mysql -NBe "SELECT @@global.read_only, @@global.super_read_only"   # 1	1
   ```

Rollback from here: [R1](#rollback).

### Step 2. Final dump (5 min)

On the droplet:

```bash
/usr/local/bin/mysql-backup.sh >>/var/log/mysql-backup.log 2>&1; echo "rc=$?"; tail -3 /var/log/mysql-backup.log   # rc=0
```

On the Mac:

```bash
M=$(aws s3api list-objects-v2 --bucket "$B" --prefix pfv-data-01/ \
  --query 'reverse(sort_by(Contents[?contains(Key, `/manifest_`)], &LastModified))[0].Key' --output text); echo "$M"   # stamped minutes ago, not 02:00
```

Rollback: R1.

### Step 3. Restore (15 min)

Section 3 with this `M`. **G2**: every check printed its expected value. Rollback: R1.

### Step 4. tbd-prod live, no DNS yet (20 min)

**MERGE A2**: the owner marks it ready and merges it. Then:

```bash
flux reconcile source git flux-system && flux reconcile kustomization flux-system
kubectl -n tbd-prod rollout status deploy/backend --timeout=5m && kubectl -n tbd-prod rollout status deploy/frontend --timeout=5m
kubectl -n tbd-prod get deploy --no-headers | awk '{print $1, $2}'      # backend 1/1, frontend 1/1, scheduler 0/0
kubectl -n tbd-prod logs deploy/backend -c migrate | tail -5             # no error
kubectl -n tbd-prod get ingressroute app --no-headers | wc -l            # 1
```

Then rehearsal step 5 again (`/health` shows `$TAG`, `/login` 200, `smoke-test.sh` all ✓). **G3**.

Users still get DO's offline page: the `app` record is DNS-only to DO. Rollback: R1 (the idle k3s pods do no
harm; revert A2 later in daylight).

### Step 5. DNS and scheduler (20 min)

**MERGE B**: the owner marks it ready and merges it. Flux starts the scheduler within a minute or two; the
`cloudflare` workspace queues an apply.

1. HCP Terraform > FlamaCorp > `cloudflare` > the run for B's merge commit. The plan must be `0 to add, 1 to
   change, 0 to destroy`, on `cloudflare_dns_record.tbd["app"]`. **Confirm & Apply**.
2. Checks (proxied records answer with Cloudflare addresses; allow a minute after the apply):

   ```bash
   curl -s -H 'accept: application/dns-json' 'https://cloudflare-dns.com/dns-query?name=app.thebetterdecision.com&type=A' | jq -r '.Answer[].data'   # Cloudflare IPs (104.x / 172.6x.x), no ondigitalocean.app
   curl -s https://app.thebetterdecision.com/health                       # {"status":"ok","version":"<TAG without v>",...} from k3s
   kubectl -n tbd-prod get deploy scheduler --no-headers | awk '{print $2}'   # 1/1
   SMOKE_USERNAME=$SU SMOKE_PASSWORD=$SP SMOKE_BASE_URL=https://app.thebetterdecision.com ~/src/tbd/scripts/smoke-test.sh   # all ✓
   ```
3. Browser (private window): `https://app.thebetterdecision.com`, log in (Google SSO and password), open the
   dashboard and a report. A local resolver can hold the old CNAME for up to 60 seconds.

**G4**, final go. From here a rollback loses the writes made on k3s (accepted). Rollback: R3.

After G4, rebuild C on the merged B so it is ready (still no PR):

```bash
git fetch origin && git switch -C revert/INFRA-48-tbd-dns-rollback origin/main
git revert --no-commit "$(gh pr view feat/INFRA-48-tbd-dns --json mergeCommit --jq .mergeCommit.oid)"
git commit -m "revert(cloudflare): app.thebetterdecision.com back to DigitalOcean, scheduler off (INFRA-48)"
git diff origin/main --stat   # terraform/cloudflare/main.tf, clusters/platform/tbd-prod/scheduler.yaml and docs only
git push --force-with-lease origin revert/INFRA-48-tbd-dns-rollback
```

### Step 6. Backup proof and watch (20 min)

```bash
kubectl -n data create job --from=cronjob/db-backup db-backup-cutover
kubectl -n data wait --for=condition=complete job/db-backup-cutover --timeout=10m
kubectl -n data logs job/db-backup-cutover -c mysql-dump | tail -1      # ok: tbd-mysql <N> tables, <bytes> bytes (N = the manifest's tables)
kubectl -n data logs job/db-backup-cutover -c upload | grep -c uploaded  # 6
kubectl -n tbd-prod logs deploy/scheduler --since=20m | grep -c scheduler.tick.complete   # 1 or more (a tick every 15 min)
kubectl -n tbd-prod logs deploy/scheduler --since=20m | grep -c scheduler.tick.error      # 0
kubectl -n tbd-prod get events --field-selector type=Warning --sort-by=.lastTimestamp | tail -3   # nothing newer than step 4
```

Then comment the result on INFRA-48. Monday: the 02:00 UTC `db-backup` and the 04:17 UTC freshness probe must be
green on real data (`tbd-mysql` floor 100000 bytes since A2).

## Rollback

Do the steps in order; each names its check.

**R1: before DNS (steps 1 to 4).** DigitalOcean comes back; k3s holds no public traffic.

1. Droplet: `mysql -e "SET GLOBAL super_read_only = OFF; SET GLOBAL read_only = OFF"` (check:
   `mysql -NBe "SELECT @@global.read_only"` prints 0), then
   `REDISCLI_AUTH=$(awk '/^requirepass/{print $2}' /etc/redis/conf.d/00-static.conf) redis-cli --no-auth-warning DEL scheduler:tick:lock`
   (prints 1).
2. DO control panel > Apps > `pfv` > Settings > Archive mode > **Restore**. Check:
   `curl -s https://app.thebetterdecision.com/health` prints `{"status":"ok"...`.
3. DO control panel > API > Tokens > Generate New Token (`tbd-release-deploy`, custom scopes: app read and
   update only), then
   `read -rs T; printf %s "$T" | gh secret set DIGITALOCEAN_ACCESS_TOKEN -R fjcloudaiconsulting/tbd; unset T`.
   Check: `gh secret list -R fjcloudaiconsulting/tbd | grep DIGITALOCEAN` shows it updated just now; the next
   release deploys to DO again.
4. If A2 was merged: open a revert PR of A2 for later; the k3s pods idle until then.

**R2: B merged, apply not yet approved.** Discard the run in HCP Terraform (Discard Run), then R3 step 1 (its plan
shows no changes, since the record never moved; Flux stops the scheduler), then R1.

**R3: after DNS (step 5, and the rollback week until INFRA-49).**

1. Rebuild C as at the end of step 5 if not done, then
   `gh pr create --head revert/INFRA-48-tbd-dns-rollback --title "revert(cloudflare): TBD back to DigitalOcean (INFRA-48)" --body "Rollback, docs/tbd-cutover.md R3."`;
   **MERGE C**; approve the `cloudflare` apply (`1 to change`). Flux stops the k3s scheduler (check: scheduler
   `0/0`); the record goes back to the DNS-only CNAME `pfv-xccvs.ondigitalocean.app` (check: the DoH query of step 5
   with `type=CNAME` returns it; resolvers follow within 5 minutes).
2. R1 steps 1 to 3.
3. Revert A2 (backend and frontend to 0, no IngressRoute) in a PR.

Writes made on k3s after G4 are not copied back (accepted, downtime ruling).
