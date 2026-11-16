#!/usr/bin/env bash
# Attach shaileshwedsshubhangi.in (GoDaddy-registered) to the prod CloudFront distribution,
# using Route 53 for DNS and ACM for the SSL certificate.
#
# Run one step at a time:
#   ./scripts/custom-domain.sh zone     # 1. create Route 53 hosted zone, print nameservers for GoDaddy
#   ./scripts/custom-domain.sh ns-check # 2. confirm GoDaddy nameserver change has propagated
#   ./scripts/custom-domain.sh cert     # 3. request ACM cert + add DNS validation records
#   ./scripts/custom-domain.sh cert-status  #  wait until cert is ISSUED, prints ARN for serverless.yml
#   (4. put the ARN into serverless.yml and deploy prod)
#   ./scripts/custom-domain.sh dns      # 5. point apex + www at the prod CloudFront distribution
#   ./scripts/custom-domain.sh verify   # 6. check everything resolves and serves over HTTPS
#
# Uses the prod AWS account credentials: set AWS_PROFILE if they aren't your default profile.

set -euo pipefail

DOMAIN="shaileshwedsshubhangi.in"
WWW="www.${DOMAIN}"
STACK="shailesh-weds-shubhangi-prod"
REGION="us-east-1"                      # ACM certs for CloudFront must live in us-east-1
CLOUDFRONT_ZONE_ID="Z2FDTNDATAQYW2"     # fixed hosted zone id for all CloudFront aliases

aws() { command aws --region "$REGION" "$@"; }

zone_id() {
  aws route53 list-hosted-zones-by-name --dns-name "$DOMAIN" \
    --query "HostedZones[?Name=='${DOMAIN}.'].Id | [0]" --output text | sed 's|/hostedzone/||'
}

require_zone() {
  local id; id=$(zone_id)
  if [[ -z "$id" || "$id" == "None" ]]; then
    echo "No hosted zone for $DOMAIN yet. Run: $0 zone" >&2; exit 1
  fi
  echo "$id"
}

cert_arn() {
  aws acm list-certificates --certificate-statuses PENDING_VALIDATION ISSUED \
    --query "CertificateSummaryList[?DomainName=='${DOMAIN}'].CertificateArn | [0]" --output text
}

step_zone() {
  local id; id=$(zone_id)
  if [[ -z "$id" || "$id" == "None" ]]; then
    echo "Creating hosted zone for $DOMAIN..."
    id=$(aws route53 create-hosted-zone --name "$DOMAIN" \
      --caller-reference "wedding-$(date +%s)" --query 'HostedZone.Id' --output text | sed 's|/hostedzone/||')
  else
    echo "Hosted zone already exists: $id"
  fi
  echo
  echo "Set these 4 nameservers in GoDaddy (My Products > $DOMAIN > DNS > Nameservers > Change > 'I'll use my own nameservers'):"
  aws route53 get-hosted-zone --id "$id" --query 'DelegationSet.NameServers' --output text | tr '\t' '\n'
}

step_ns_check() {
  local id; id=$(require_zone)
  local expected actual
  expected=$(aws route53 get-hosted-zone --id "$id" --query 'DelegationSet.NameServers' --output text | tr '\t' '\n' | sort)
  actual=$(dig +short NS "$DOMAIN" @8.8.8.8 | sed 's/\.$//' | sort)
  echo "Expected:"; echo "$expected"
  echo "Public DNS currently returns:"; echo "${actual:-<nothing>}"
  if [[ "$expected" == "$actual" ]]; then
    echo "✅ Nameservers propagated. Next: $0 cert"
  else
    echo "⏳ Not propagated yet (can take from minutes up to 48h). Re-run later."
  fi
}

step_cert() {
  local id; id=$(require_zone)
  local arn; arn=$(cert_arn)
  if [[ -z "$arn" || "$arn" == "None" ]]; then
    echo "Requesting ACM certificate for $DOMAIN and $WWW..."
    arn=$(aws acm request-certificate --domain-name "$DOMAIN" \
      --subject-alternative-names "$WWW" --validation-method DNS \
      --query CertificateArn --output text)
    sleep 10  # validation records take a moment to appear on a new cert
  else
    echo "Certificate already requested: $arn"
  fi

  echo "Adding DNS validation records to Route 53..."
  local changes
  changes=$(aws acm describe-certificate --certificate-arn "$arn" \
    --query 'Certificate.DomainValidationOptions[].ResourceRecord' --output json |
    python3 -c '
import json, sys
recs = {r["Name"]: r for r in json.load(sys.stdin) if r}
print(json.dumps({"Changes": [{"Action": "UPSERT", "ResourceRecordSet": {
  "Name": r["Name"], "Type": r["Type"], "TTL": 300,
  "ResourceRecords": [{"Value": r["Value"]}]}} for r in recs.values()]}))')
  aws route53 change-resource-record-sets --hosted-zone-id "$id" --change-batch "$changes" >/dev/null
  echo "✅ Validation records added. Next: $0 cert-status"
}

step_cert_status() {
  local arn; arn=$(cert_arn)
  if [[ -z "$arn" || "$arn" == "None" ]]; then echo "No certificate yet. Run: $0 cert" >&2; exit 1; fi
  local status; status=$(aws acm describe-certificate --certificate-arn "$arn" --query Certificate.Status --output text)
  echo "Certificate: $arn"
  echo "Status:      $status"
  if [[ "$status" == "ISSUED" ]]; then
    echo "✅ Use this ARN as the prod certificate in serverless.yml, then deploy prod."
  else
    echo "⏳ Usually issues within ~5–30 min after nameservers propagate. Re-run later."
  fi
}

step_dns() {
  local id; id=$(require_zone)
  local cf
  cf=$(aws cloudformation describe-stacks --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='ApiDistribution'].OutputValue | [0]" --output text)
  if [[ -z "$cf" || "$cf" == "None" ]]; then echo "Could not find CloudFront domain in stack $STACK" >&2; exit 1; fi
  echo "Prod CloudFront: $cf"

  local changes=""
  for name in "$DOMAIN" "$WWW"; do
    for type in A AAAA; do
      changes+="{\"Action\":\"UPSERT\",\"ResourceRecordSet\":{\"Name\":\"$name\",\"Type\":\"$type\",\"AliasTarget\":{\"HostedZoneId\":\"$CLOUDFRONT_ZONE_ID\",\"DNSName\":\"$cf\",\"EvaluateTargetHealth\":false}}},"
    done
  done
  aws route53 change-resource-record-sets --hosted-zone-id "$id" \
    --change-batch "{\"Changes\":[${changes%,}]}" >/dev/null
  echo "✅ $DOMAIN and $WWW now alias to $cf. Next: $0 verify"
}

step_verify() {
  for host in "$DOMAIN" "$WWW"; do
    echo "== $host"
    echo "DNS:   $(dig +short "$host" @8.8.8.8 | head -1)"
    echo "HTTPS: $(curl -sS -o /dev/null -w '%{http_code}' "https://$host/" || echo failed)"
  done
}

case "${1:-}" in
  zone)        step_zone ;;
  ns-check)    step_ns_check ;;
  cert)        step_cert ;;
  cert-status) step_cert_status ;;
  dns)         step_dns ;;
  verify)      step_verify ;;
  *) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
