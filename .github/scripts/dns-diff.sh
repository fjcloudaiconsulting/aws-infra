#!/usr/bin/env bash
# INFRA-15 NS-switch gate: every record must answer the same from Route 53 and Cloudflare.
# Usage: .github/scripts/dns-diff.sh <cloudflare-ns> [old-ns]   exit 0 = zero diffs.
set -uo pipefail
NEW=${1:?cloudflare nameserver}
OLD=${2:-ns-419.awsdns-52.com}
Z=thebetterdecision.com
CF=d1vhzkck8shsp8.cloudfront.net

# dig +short prints timeouts as ";; ..." lines on stdout; drop them so a timeout reads as empty.
q() { dig +short +norecurse +time=3 +tries=2 @"$1" "$2" "$3" | grep -v '^;' | sed 's/\.$//' | sort; }
fail=0
ok() { printf 'ok    %-58s %s\n' "$1" "$2"; }
bad() { printf 'DIFF  %-58s %s\n  route53:    %s\n  cloudflare: %s\n' "$1" "$2" "$3" "$4"; fail=1; }

# Exact: records copied verbatim.
for nt in "$Z TXT" "app.$Z CNAME" \
  "_d8193f70c4baeb1cabf4316aaa913106.$Z CNAME" "_f5a90d945c9943f00f2a831d0daeadb8.www.$Z CNAME" \
  "m.$Z MX" "m.$Z TXT" "_dmarc.m.$Z TXT" "email._domainkey.m.$Z TXT" "email.m.$Z CNAME"; do
  read -r n t <<<"$nt"
  a=$(q "$OLD" "$n" "$t"); b=$(q "$NEW" "$n" "$t")
  if [ -n "$a" ] && [ "$a" = "$b" ]; then ok "$n" "$t"; else bad "$n" "$t" "$a" "$b"; fi
done

# Aliases: Route 53 answers A/AAAA from CloudFront; Cloudflare answers www with a CNAME to the
# distribution and the apex with flattened A/AAAA. Both must land on the same distribution.
b=$(q "$NEW" "www.$Z" CNAME)
if [ "$b" = "$CF" ]; then ok "www.$Z" "CNAME->$CF"; else bad "www.$Z" CNAME "(alias $CF)" "$b"; fi
# Flattened IPs differ from the alias IPs, so only their shape is compared; www above pins the
# target, and Terraform gives apex and www the same content.
ipre() { [ -n "$1" ] && ! printf '%s\n' "$1" | grep -qvE "$2"; }
for pair in "A ^[0-9.]+$" "AAAA ^[0-9a-f:]+$"; do
  read -r t re <<<"$pair"
  a=$(q "$OLD" "$Z" "$t"); b=$(q "$NEW" "$Z" "$t")
  if ipre "$a" "$re" && ipre "$b" "$re"; then ok "$Z" "$t (both answer IPs)"; else bad "$Z" "$t" "$a" "$b"; fi
done
# The flattened apex must serve the site (same CloudFront distribution and certificate).
ip=$(q "$NEW" "$Z" A | head -1)
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$Z:443:$ip" "https://$Z/")
case $code in 2*|3*) ok "https://$Z via $ip" "HTTP $code" ;; *) bad "https://$Z" "HTTP" "-" "$code via $ip" ;; esac

# A DS record at .com still pointing at Route 53 keys would break resolution after the switch.
# Fails closed: a timeout is not "no DS".
ds=$(dig +norecurse +time=3 +tries=2 @a.gtld-servers.net "$Z" DS)
if grep -q 'status: NOERROR' <<<"$ds" && grep -q 'ANSWER: 0,' <<<"$ds"; then ok "$Z" "no DS at .com"
else bad "$Z" DS "-" "$(grep -E 'status:|IN[[:space:]]+DS' <<<"$ds")"; fi

[ $fail = 0 ] && echo "PASS: zero diffs" || echo "FAIL"
exit $fail
