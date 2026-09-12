#!/usr/bin/env bash
# Mint a bucket-scoped R2 API token for the sccache bucket and store the S3
# credentials for it, printing nothing secret. Run it yourself:
#
#   bash ~/rbuild/scripts/mint-r2-token.sh
#
# Needs ~/secret_keys/cloudflare_account_id and ~/secret_keys/cloudflare_api_token
# (an account token allowed to create account-owned API tokens). Writes
#   ~/secret_keys/r2_sccache_access_key_id      (the new token's id)
#   ~/secret_keys/r2_sccache_secret_access_key  (sha256 of the token value, R2's S3 secret)
# then pushes them to the rbuild repo secrets and Codespaces user secrets.
set -euo pipefail
S=~/secret_keys; BUCKET="${1:-sccache}"; REPO="${RBUILD_DISPATCH_REPO:-Abdk4Moura/rbuild}"; CS_REPO="${2:-Abdk4Moura/Egregoria}"
ACC=$(tr -d '\n\r' < $S/cloudflare_account_id); TOK=$(tr -d '\n\r' < $S/cloudflare_api_token)
RESP=$(curl -sS -m 30 -X POST -H "Authorization: Bearer $TOK" -H 'Content-Type: application/json' \
  "https://api.cloudflare.com/client/v4/accounts/$ACC/tokens" -d "{
  \"name\": \"rbuild-sccache ($(date -u +%F))\",
  \"policies\": [{\"effect\": \"allow\",
    \"resources\": {\"com.cloudflare.edge.r2.bucket.${ACC}_default_${BUCKET}\": \"*\"},
    \"permission_groups\": [
      {\"id\": \"6a018a9f2fc74eb6b293b0c548f38b39\", \"name\": \"Workers R2 Storage Bucket Item Read\"},
      {\"id\": \"2efd5506f9c8494dacb1fa10a3e7d5b6\", \"name\": \"Workers R2 Storage Bucket Item Write\"}]}]}")
if [ "$(echo "$RESP" | jq -r .success)" != "true" ]; then
  echo "token creation failed:"; echo "$RESP" | jq -c '[.errors[]?.message]'; exit 1
fi
umask 077
echo "$RESP" | jq -r .result.id    | tr -d '\n' > $S/r2_sccache_access_key_id
echo "$RESP" | jq -r .result.value | tr -d '\n' | sha256sum | cut -d' ' -f1 | tr -d '\n' > $S/r2_sccache_secret_access_key
echo "stored: $S/r2_sccache_access_key_id, $S/r2_sccache_secret_access_key"
gh secret set R2_ACCESS_KEY_ID     -R "$REPO" < $S/r2_sccache_access_key_id
gh secret set R2_SECRET_ACCESS_KEY -R "$REPO" < $S/r2_sccache_secret_access_key
gh variable set R2_ACCOUNT_ID      -R "$REPO" --body "$ACC"
gh variable set R2_BUCKET          -R "$REPO" --body "$BUCKET"
gh secret set R2_ACCESS_KEY_ID     --user --app codespaces --repos "$CS_REPO" < $S/r2_sccache_access_key_id
gh secret set R2_SECRET_ACCESS_KEY --user --app codespaces --repos "$CS_REPO" < $S/r2_sccache_secret_access_key
gh secret set R2_ACCOUNT_ID        --user --app codespaces --repos "$CS_REPO" --body "$ACC"
echo "secrets set on $REPO and Codespaces ($CS_REPO). Verify with: gh workflow run cache-size.yml -R $REPO"
