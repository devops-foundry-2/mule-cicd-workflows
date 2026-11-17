#!/usr/bin/env bash
# onboard-app.sh — Create and configure a new MuleSoft app repo in devops-foundry-2.
#
# Usage:
#   ./onboard-app.sh --app <name> --region <emea|amer|both> [--description "..."]
#
# What it does (in order):
#   1. Create the public repo in devops-foundry-2
#   2. Seed main branch with the caller workflow template (mule-ci.yml)
#   3. Create GitHub Environments with required reviewers on Production
#   4. Set repository variables (ANYPOINT_BG_ID, ENV_ID, ENV_NAME per tier)
#   5. Create empty secret placeholders (MAVEN_SETTINGS_XML, NONPROD_CONNECTED_APP_ID, etc.)
#   6. Apply branch protection on main (1 approval, code-owner review, no force-push)
#   7. Create branch-name ruleset (feature/*, bugfix/*, hotfix/* allowed; direct main push blocked)
#
# SECRETS: this script never reads or echoes secret values. It creates empty secret containers
# that the user must fill via the GitHub UI or CLI.
#
# Prerequisites: gh CLI authenticated as agarwalaman210-p with admin:org, repo, workflow scopes.
set -euo pipefail

ORG="devops-foundry-2"
TEMPLATES_REPO="${ORG}/mule-cicd-workflows"
REVIEWER_HANDLE="agarwalaman210-p"
REVIEWER_ID=355196375  # GitHub user ID for agarwalaman210-p (from Phase 0 probe)

usage() {
  echo "Usage: $0 --app <name> --region <emea|amer|both> [--description \"...\"]"
  exit 1
}

APP_NAME=""
REGION=""
DESCRIPTION=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --app) APP_NAME="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --description) DESCRIPTION="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -z "$APP_NAME" || -z "$REGION" ]] && usage
[[ "$REGION" =~ ^(emea|amer|both)$ ]] || { echo "ERROR: --region must be emea, amer, or both"; exit 1; }

REPO="${ORG}/${APP_NAME}"

echo "=== Onboarding ${APP_NAME} (region: ${REGION}) ==="

# 1. Create repo
echo "Creating repo ${REPO}..."
gh repo create "$REPO" \
  --public \
  --description "${DESCRIPTION:-MuleSoft application ${APP_NAME}}" \
  --add-readme 2>/dev/null || echo "  Repo already exists — adopting"

# 2. Copy caller workflow template and seed main
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cd "$TMP_DIR"
git init -q
git checkout -b main
mkdir -p .github/workflows

# Download the caller template from mule-cicd-workflows
gh api repos/${TEMPLATES_REPO}/contents/templates/mule-ci.yml \
  --jq '.content' | base64 -d > .github/workflows/mule-ci.yml

# Determine business-groups JSON based on region
case "$REGION" in
  emea) BG_JSON='[{"key":"emea","prefix":"EMEA"}]' ;;
  amer) BG_JSON='[{"key":"amer","prefix":"AMER"}]' ;;
  both) BG_JSON='[{"key":"emea","prefix":"EMEA"},{"key":"amer","prefix":"AMER"}]' ;;
esac

# Substitute placeholders
sed -i '' \
  "s|__ORG__|${ORG}|g;
   s|__TEMPLATES_REF__|main|g;
   s|__DEPLOYMENT_TARGET__|ch2|g;
   s|'__BUSINESS_GROUPS__'|'${BG_JSON}'|g" \
  .github/workflows/mule-ci.yml 2>/dev/null || \
sed -i \
  "s|__ORG__|${ORG}|g;
   s|__TEMPLATES_REF__|main|g;
   s|__DEPLOYMENT_TARGET__|ch2|g;
   s|'__BUSINESS_GROUPS__'|'${BG_JSON}'|g" \
  .github/workflows/mule-ci.yml

# CODEOWNERS
echo "* @${REVIEWER_HANDLE}" > CODEOWNERS

git add .
git commit -q -m "chore: initial scaffold for ${APP_NAME}"
git -c credential.helper='!gh auth git-credential' remote add origin \
  "https://github.com/${REPO}.git"
git -c credential.helper='!gh auth git-credential' push -u origin main -q
echo "  Caller workflow and CODEOWNERS pushed to main"

# 3. Create GitHub Environments
echo "Creating GitHub Environments..."
BGS=()
[[ "$REGION" == "emea" || "$REGION" == "both" ]] && BGS+=("EMEA")
[[ "$REGION" == "amer" || "$REGION" == "both" ]] && BGS+=("AMER")

for BG in "${BGS[@]}"; do
  for TIER in Design Sandbox Production; do
    ENV_NAME="${BG}-${TIER}"
    echo "  Creating environment: ${ENV_NAME}"
    if [[ "$TIER" == "Production" ]]; then
      # Production requires approval; prevent self-review is off (pilot accepted)
      gh api -X PUT "repos/${REPO}/environments/${ENV_NAME}" \
        --input - <<EOF
{"reviewers": [{"type": "User", "id": ${REVIEWER_ID}}], "deployment_branch_policy": null}
EOF
    else
      # Design and Sandbox: no required reviewers
      gh api -X PUT "repos/${REPO}/environments/${ENV_NAME}" \
        --input - <<< '{"deployment_branch_policy": null}'
    fi
  done
done

# 4. Set repository variables (empty; fill via Anypoint inspector values)
echo "Creating repository variables (empty — fill with Anypoint BG/env IDs)..."
for BG in "${BGS[@]}"; do
  for VAR_SUFFIX in ANYPOINT_BG_ID ANYPOINT_ORG_ID \
                    DESIGN_ENV_ID DESIGN_ENV_NAME \
                    SANDBOX_ENV_ID SANDBOX_ENV_NAME \
                    PRODUCTION_ENV_ID PRODUCTION_ENV_NAME; do
    VAR_NAME="${BG}_${VAR_SUFFIX}"
    gh api -X POST "repos/${REPO}/actions/variables" \
      -f name="$VAR_NAME" -f value="__FILL_ME__" 2>/dev/null || \
    gh api -X PATCH "repos/${REPO}/actions/variables/${VAR_NAME}" \
      -f value="__FILL_ME__" 2>/dev/null || true
  done
done

# 5. Create empty secret slots (values must be set by human)
echo "Creating secret slots (empty — fill with real values)..."
# GitHub CLI requires a value; use a sentinel that the CI workflow detects and fails on
SENTINEL_B64=$(printf '%s' '__FILL_ME__' | base64)
for SECRET in MAVEN_SETTINGS_XML ENV_SETTINGS_TOKEN \
              NONPROD_CONNECTED_APP_ID NONPROD_CONNECTED_APP_SECRET \
              PROD_CONNECTED_APP_ID PROD_CONNECTED_APP_SECRET \
              LOCAL_SECURE_KEY; do
  gh secret set "$SECRET" --repo "$REPO" --body "__FILL_ME__" 2>/dev/null || true
done
for BG in "${BGS[@]}"; do
  for TIER in DESIGN SANDBOX PRODUCTION; do
    gh secret set "${TIER}_SECURE_KEY" --env "${BG}-${TIER^}" --repo "$REPO" \
      --body "__FILL_ME__" 2>/dev/null || true
  done
done

# 6. Branch protection on main
echo "Applying branch protection on main..."
gh api -X PUT "repos/${REPO}/branches/main/protection" \
  --input - <<'EOF'
{
  "required_status_checks": null,
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "require_code_owner_reviews": true,
    "dismiss_stale_reviews": true
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": false
}
EOF

# 7. Branch-name ruleset
echo "Creating branch-name ruleset..."
gh api -X POST "repos/${REPO}/rulesets" \
  --input - <<'EOF'
{
  "name": "branch-name-convention",
  "target": "branch",
  "enforcement": "active",
  "conditions": {
    "ref_name": {
      "include": ["~ALL"],
      "exclude": ["refs/heads/main"]
    }
  },
  "rules": [
    {
      "type": "branch_name_pattern",
      "parameters": {
        "pattern": "^(feature|bugfix|hotfix)/.+$",
        "operator": "regex",
        "negate": false,
        "name": ""
      }
    }
  ]
}
EOF

echo ""
echo "=== Onboarding complete for ${APP_NAME} ==="
echo ""
echo "ACTION REQUIRED — fill these secrets/variables before running the pipeline:"
echo "  1. MAVEN_SETTINGS_XML       — base64-encoded settings.xml (see mtd-parent-pom/settings.xml.template)"
echo "  2. ENV_SETTINGS_TOKEN       — GitHub PAT (read:contents) to checkout mule-app-env-settings"
echo "  3. NONPROD_CONNECTED_APP_ID/SECRET — Anypoint Connected App for Design+Sandbox"
echo "  4. PROD_CONNECTED_APP_ID/SECRET    — Anypoint Connected App for Production"
echo "  5. LOCAL_SECURE_KEY / *_SECURE_KEY — Mule secure-properties encryption key per env"
for BG in "${BGS[@]}"; do
  echo "  6. ${BG}_ANYPOINT_BG_ID, ${BG}_*_ENV_ID, ${BG}_*_ENV_NAME — from Anypoint Platform"
done
echo ""
echo "Repo URL: https://github.com/${REPO}"
