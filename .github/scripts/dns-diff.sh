#!/usr/bin/env bash
# INFRA-15 NS-switch gate: every record must answer the same from Route 53 and Cloudflare.
# Usage: .github/scripts/dns-diff.sh <cloudflare-ns> [old-ns]   exit 0 = zero diffs.
set -uo pipefail
NEW=${1:?cloudflare nameserver}
OLD=${2:-ns-419.awsdns-52.com}
Z=thebetterdecision.com
CF=d1vhzkck8shsp8.cloudfront.net

q() { dig +short +norecurse +time=3 +tries=2 @"$1" "$2" "$3" | sed 's/\.$//' | sort; }
fail=0
ok() { printf 'ok    %-58s %s\n' "$1" "$2"; }
bad() { printf 'DIFF  %-58s %s\n  route53:    %s\n  cloudflare: %s\n' "$1" "$2" "$3" "$4"; fail=1; }

# Exact: records copied verbatim.
for nt in "$Z TXT" "app.$Z CNAME" \
  "_d8193f70c4baeb1cabf4316aaa913106.$Z CNAME" "_f5a90d945c9943f00f2a831d0daeadb8.www.$Z CNAME" \
  "m.$Z MX" "m.$Z TXT" "_dmarc.m.$Z TXT" "email._domainkey.m.$Z TXT" "email.m.$Z CNAME"; do
  set -- $nt
  a=$(q "$OLD" "$1" "$2"); b=$(q "$NEW" "$1" "$2")
  if [ -n "$a" ] && [ "$a" = "$b" ]; then ok "$1" "$2"; else bad "$1" "$2" "$a" "$b"; fi
done

# Aliases: Route 53 answers A/AAAA from CloudFront; Cloudflare answers www with a CNAME to the
# distribution and the apex with flattened A/AAAA. Both must land on the same distribution.
b=$(q "$NEW" "www.$Z" CNAME)
if [ "$b" = "$CF" ]; then ok "www.$Z" "CNAME->$CF"; else bad "www.$Z" CNAME "(alias $CF)" "$b"; fi
for t in A AAAA; do
  a=$(q "$OLD" "$Z" "$t"); b=$(q "$NEW" "$Z" "$t")
  if [ -n "$a" ] && [ -n "$b" ]; then ok "$Z" "$t (both non-empty)"; else bad "$Z" "$t" "$a" "$b"; fi
done
# The flattened apex must serve the site (same CloudFront distribution and certificate).
ip=$(q "$NEW" "$Z" A | head -1)
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$Z:443:$ip" "https://$Z/")
case $code in 2*|3*) ok "https://$Z via $ip" "HTTP $code" ;; *) bad "https://$Z" "HTTP" "-" "$code via $ip" ;; esac

[ $fail = 0 ] && echo "PASS: zero diffs" || echo "FAIL"
exit $fail
