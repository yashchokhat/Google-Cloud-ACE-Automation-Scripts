#!/bin/bash

set -u

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" \
  --format='value(projectNumber)')"

ZONE="asia-east1-b"
LOCATION="asia-east1"
DEPLOYMENT="lamp-1"
SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

echo "======================================"
echo "PROJECT      : $PROJECT_ID"
echo "PROJECT NUM  : $PROJECT_NUMBER"
echo "ZONE         : $ZONE"
echo "DEPLOYMENT   : $DEPLOYMENT"
echo "SERVICE ACCT : $SA"
echo "======================================"

echo "[1/6] Enabling required APIs..."
gcloud services enable \
  compute.googleapis.com \
  config.googleapis.com \
  cloudresourcemanager.googleapis.com \
  servicemanagement.googleapis.com \
  serviceusage.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

echo "[2/6] Checking Compute service account..."
gcloud iam service-accounts describe "$SA" \
  --project="$PROJECT_ID" >/dev/null 2>&1 || {
    echo "ERROR: Compute service account not available."
    exit 1
  }

echo "[3/6] Granting required deployment permissions..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA" \
  --role="roles/compute.admin" \
  --quiet >/dev/null

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA" \
  --role="roles/config.agent" \
  --quiet >/dev/null 2>&1 || true

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:$SA" \
  --role="roles/serviceusage.serviceUsageConsumer" \
  --quiet >/dev/null 2>&1 || true

echo "[4/6] Checking existing Infrastructure Manager deployment..."
gcloud infra-manager deployments describe \
  "projects/$PROJECT_ID/locations/$LOCATION/deployments/$DEPLOYMENT" \
  --quiet >/dev/null 2>&1 && {
    echo "Existing deployment found."
  } || {
    echo "No existing deployment."
  }

echo "[5/6] Starting Google Click-to-Deploy LAMP deployment..."

gcloud infra-manager deployments apply \
  "projects/$PROJECT_ID/locations/$LOCATION/deployments/$DEPLOYMENT" \
  --service-account="projects/$PROJECT_ID/serviceAccounts/$SA" \
  --gcs-source="gs://cloud-marketplace-terraform-prod/acf25bb1-f064-4851-a1c2-625b75672c51/terraform.zip#1733901947418152" \
  --labels="goog-cloud-marketplace-product-id=5416d651-ffa7-4d30-ac18-06be7dba905e,goog-config-partner=marketplace" \
  --quiet

RESULT=$?

if [ "$RESULT" -ne 0 ]; then
  echo
  echo "======================================"
  echo "Infrastructure Manager deployment failed."
  echo "This is a known issue with this lab's"
  echo "Marketplace tenant-project deployment."
  echo "======================================"
  exit "$RESULT"
fi

echo "[6/6] Waiting for lamp-1-vm..."

for i in {1..36}; do

  VM_STATUS="$(gcloud compute instances describe lamp-1-vm \
    --zone="$ZONE" \
    --format='value(status)' 2>/dev/null || true)"

  echo "Attempt $i/36 : ${VM_STATUS:-CREATING}"

  if [ "$VM_STATUS" = "RUNNING" ]; then
    break
  fi

  sleep 10
done

echo
echo "======================================"
echo "VM CHECK"
echo "======================================"

gcloud compute instances list \
  --filter="name=lamp-1-vm" \
  --format="table(name,zone,status,machineType.basename(),networkInterfaces[0].accessConfigs[0].natIP)"

IP="$(gcloud compute instances describe lamp-1-vm \
  --zone="$ZONE" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)"

echo
echo "======================================"
echo "SITE URL"
echo "======================================"
echo "http://$IP"

echo
echo "======================================"
echo "HTTP TEST"
echo "======================================"

for i in {1..12}; do
  if curl -fsS --max-time 10 "http://$IP" >/dev/null 2>&1; then
    echo "LAMP WEB SERVER: OK"
    curl -I --max-time 10 "http://$IP" 2>/dev/null | head -n 5
    break
  fi

  echo "Waiting for Apache..."
  sleep 10
done

echo
echo "======================================"
echo "DONE"
echo "======================================"
