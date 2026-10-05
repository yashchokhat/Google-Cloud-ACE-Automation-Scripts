cat > full-storage-sql-lab.sh <<'EOF'
#!/bin/bash
set -euo pipefail

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"

VM_NAME="bloghost"
SQL_NAME="blog-db"
SQL_USER="blogdbuser"
SQL_PASSWORD='Passw0rd1!'
NETWORK="default"

echo "=========================================="
echo "CLOUD STORAGE + CLOUD SQL LAB"
echo "PROJECT: $PROJECT_ID"
echo "=========================================="

# ============================================================
# 1. DETECT REGION / ZONE
# ============================================================

REGION="$(gcloud config get-value compute/region 2>/dev/null || true)"
ZONE="$(gcloud config get-value compute/zone 2>/dev/null || true)"

[[ "$REGION" == "(unset)" ]] && REGION=""
[[ "$ZONE" == "(unset)" ]] && ZONE=""

# Try environment variables commonly available in labs
if [[ -z "$REGION" && -n "${REGION:-}" ]]; then
  REGION="$REGION"
fi

if [[ -z "$ZONE" && -n "${ZONE:-}" ]]; then
  ZONE="$ZONE"
fi

if [[ -z "$REGION" || -z "$ZONE" ]]; then
  echo
  echo "Lab Region/Zone is not configured in Cloud Shell."
  echo "Enter the values shown in your lab instructions."
  read -rp "LAB REGION (example europe-west1): " REGION
  read -rp "LAB ZONE (example europe-west1-c): " ZONE
fi

echo "REGION: $REGION"
echo "ZONE  : $ZONE"

gcloud config set project "$PROJECT_ID" --quiet
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# ============================================================
# 2. ENABLE APIs
# ============================================================

echo
echo "[1/8] Enabling required APIs..."

gcloud services enable \
  compute.googleapis.com \
  sqladmin.googleapis.com \
  storage.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

# ============================================================
# 3. CREATE BLOGHOST VM
# ============================================================

echo
echo "[2/8] Creating bloghost..."

# HTTP firewall
gcloud compute firewall-rules create default-allow-http \
  --network="$NETWORK" \
  --direction=INGRESS \
  --priority=1000 \
  --action=ALLOW \
  --rules=tcp:80 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=http-server \
  --quiet 2>/dev/null || true

# Startup script
cat > startup.sh <<'STARTUP'
#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

apt-get update -y
apt-get install -y apache2 php php-mysql

systemctl enable apache2
systemctl restart apache2
STARTUP

if ! gcloud compute instances describe "$VM_NAME" \
    --zone="$ZONE" >/dev/null 2>&1; then

  gcloud compute instances create "$VM_NAME" \
    --zone="$ZONE" \
    --machine-type=e2-standard-2 \
    --image-family=debian-12 \
    --image-project=debian-cloud \
    --tags=http-server \
    --metadata-from-file=startup-script=startup.sh
else
  echo "bloghost already exists."
fi

# ============================================================
# 4. WAIT FOR VM
# ============================================================

echo
echo "Waiting for bloghost..."

for i in {1..36}; do

  VM_STATUS="$(gcloud compute instances describe "$VM_NAME" \
    --zone="$ZONE" \
    --format='value(status)' 2>/dev/null || true)"

  echo "VM status: ${VM_STATUS:-CREATING}"

  if [[ "$VM_STATUS" == "RUNNING" ]]; then
    break
  fi

  sleep 10
done

BLOG_INTERNAL_IP="$(gcloud compute instances describe "$VM_NAME" \
  --zone="$ZONE" \
  --format='value(networkInterfaces[0].networkIP)')"

BLOG_EXTERNAL_IP="$(gcloud compute instances describe "$VM_NAME" \
  --zone="$ZONE" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')"

echo
echo "BLOGHOST INTERNAL IP: $BLOG_INTERNAL_IP"
echo "BLOGHOST EXTERNAL IP: $BLOG_EXTERNAL_IP"

# ============================================================
# 5. CLOUD STORAGE
# ============================================================

echo
echo "[3/8] Creating Cloud Storage bucket..."

case "$REGION" in
  europe-* )
    LOCATION="EU"
    ;;
  asia-* )
    LOCATION="ASIA"
    ;;
  us-*|northamerica-*|southamerica-* )
    LOCATION="US"
    ;;
  australia-* )
    LOCATION="ASIA"
    ;;
  *)
    LOCATION="US"
    ;;
esac

echo "Bucket location: $LOCATION"

if ! gcloud storage buckets describe \
    "gs://$PROJECT_ID" >/dev/null 2>&1; then

  gcloud storage buckets create \
    "gs://$PROJECT_ID" \
    --location="$LOCATION" \
    --project="$PROJECT_ID" \
    --no-uniform-bucket-level-access \
    --no-public-access-prevention
else
  echo "Bucket already exists."
fi

echo
echo "Downloading lab image..."

gcloud storage cp \
  gs://cloud-training/gcpfci/my-excellent-blog.png \
  ./my-excellent-blog.png

echo
echo "Uploading image..."

gcloud storage cp \
  ./my-excellent-blog.png \
  "gs://$PROJECT_ID/my-excellent-blog.png"

echo
echo "Making object public..."

gsutil acl ch \
  -u allUsers:R \
  "gs://$PROJECT_ID/my-excellent-blog.png"

IMAGE_URL="https://storage.googleapis.com/$PROJECT_ID/my-excellent-blog.png"

echo "IMAGE URL:"
echo "$IMAGE_URL"

# ============================================================
# 6. CREATE CLOUD SQL
# ============================================================

echo
echo "[4/8] Creating Cloud SQL blog-db..."

# IMPORTANT:
# Remove gcloud compute location properties temporarily.
# This prevents --zone/--region conflicts in gcloud sql.

gcloud config unset compute/region --quiet || true
gcloud config unset compute/zone --quiet || true

if ! gcloud sql instances describe "$SQL_NAME" \
    --project="$PROJECT_ID" >/dev/null 2>&1; then

  gcloud sql instances create "$SQL_NAME" \
    --project="$PROJECT_ID" \
    --database-version=MYSQL_8_0 \
    --edition=ENTERPRISE \
    --tier=db-custom-2-8192 \
    --zone="$ZONE" \
    --availability-type=ZONAL \
    --assign-ip \
    --ssl-mode=ALLOW_UNENCRYPTED_AND_ENCRYPTED \
    --authorized-networks="$BLOG_EXTERNAL_IP/32" \
    --root-password="$SQL_PASSWORD"

else
  echo "blog-db already exists."
fi

# Restore compute location settings
gcloud config set compute/region "$REGION" --quiet
gcloud config set compute/zone "$ZONE" --quiet

# ============================================================
# 7. WAIT FOR SQL
# ============================================================

echo
echo "Waiting for Cloud SQL..."

for i in {1..60}; do

  SQL_STATE="$(gcloud sql instances describe "$SQL_NAME" \
    --project="$PROJECT_ID" \
    --format='value(state)' 2>/dev/null || true)"

  echo "SQL status: ${SQL_STATE:-CREATING}"

  if [[ "$SQL_STATE" == "RUNNABLE" ]]; then
    break
  fi

  sleep 10
done

SQL_IP="$(gcloud sql instances describe "$SQL_NAME" \
  --project="$PROJECT_ID" \
  --format='value(ipAddresses[0].ipAddress)')"

echo
echo "CLOUD SQL PUBLIC IP: $SQL_IP"

# ============================================================
# 8. CREATE DATABASE USER
# ============================================================

echo
echo "[5/8] Creating blogdbuser..."

if gcloud sql users list \
    --instance="$SQL_NAME" \
    --project="$PROJECT_ID" \
    --format='value(name)' |
    grep -qx "$SQL_USER"; then

  gcloud sql users set-password "$SQL_USER" \
    --instance="$SQL_NAME" \
    --host="%" \
    --password="$SQL_PASSWORD" \
    --project="$PROJECT_ID"

else

  gcloud sql users create "$SQL_USER" \
    --instance="$SQL_NAME" \
    --host="%" \
    --password="$SQL_PASSWORD" \
    --project="$PROJECT_ID"

fi

echo
echo "Authorizing bloghost external IP..."

gcloud sql instances patch "$SQL_NAME" \
  --project="$PROJECT_ID" \
  --authorized-networks="$BLOG_EXTERNAL_IP/32" \
  --ssl-mode=ALLOW_UNENCRYPTED_AND_ENCRYPTED \
  --quiet

# ============================================================
# 9. CREATE PHP APPLICATION
# ============================================================

echo
echo "[6/8] Creating PHP application..."

cat > index.php <<PHP
<html>
<head>
<title>Welcome to my excellent blog</title>
</head>

<body>

<img src='$IMAGE_URL'>

<h1>Welcome to my excellent blog</h1>

<?php

\$dbserver = "$SQL_IP";
\$dbuser = "$SQL_USER";
\$dbpassword = "$SQL_PASSWORD";

try {

    \$conn = new PDO(
        "mysql:host=\$dbserver;dbname=mysql",
        \$dbuser,
        \$dbpassword
    );

    \$conn->setAttribute(
        PDO::ATTR_ERRMODE,
        PDO::ERRMODE_EXCEPTION
    );

    echo "Connected successfully";

} catch(PDOException \$e) {

    echo "Database connection failed:: " . \$e->getMessage();

}

?>

</body>
</html>
PHP

# ============================================================
# 10. COPY APP TO VM
# ============================================================

echo
echo "Deploying PHP application..."

# Wait until SSH becomes available
for i in {1..30}; do

  if gcloud compute ssh "$VM_NAME" \
      --zone="$ZONE" \
      --quiet \
      --command="echo SSH_READY" >/dev/null 2>&1; then
    break
  fi

  echo "Waiting for SSH..."
  sleep 10
done

gcloud compute scp \
  ./index.php \
  "$VM_NAME:/tmp/index.php" \
  --zone="$ZONE" \
  --quiet

gcloud compute ssh "$VM_NAME" \
  --zone="$ZONE" \
  --quiet \
  --command='
sudo cp /tmp/index.php /var/www/html/index.php
sudo chown www-data:www-data /var/www/html/index.php
sudo chmod 644 /var/www/html/index.php
sudo systemctl restart apache2
'

# ============================================================
# 11. VERIFY EVERYTHING
# ============================================================

echo
echo "[7/8] Verifying Cloud Storage..."

gcloud storage ls \
  "gs://$PROJECT_ID/my-excellent-blog.png"

echo
echo "Public image test:"
curl -I --max-time 15 "$IMAGE_URL" || true

echo
echo "[8/8] Verifying Cloud SQL..."

gcloud sql instances describe "$SQL_NAME" \
  --project="$PROJECT_ID" \
  --format='table(
    name,
    databaseVersion,
    region,
    gceZone,
    state
  )'

echo
echo "Cloud SQL user:"
gcloud sql users list \
  --instance="$SQL_NAME" \
  --project="$PROJECT_ID"

# ============================================================
# 12. VERIFY WEBSITE
# ============================================================

echo
echo "=========================================="
echo "WEBSITE"
echo "=========================================="

echo "http://$BLOG_EXTERNAL_IP/index.php"

echo
echo "Waiting for PHP application..."

for i in {1..30}; do

  PAGE="$(curl -s --max-time 15 \
    "http://$BLOG_EXTERNAL_IP/index.php" || true)"

  if echo "$PAGE" | grep -q "Connected successfully"; then

    echo
    echo "=========================================="
    echo "CONNECTED SUCCESSFULLY"
    echo "=========================================="

    echo "$PAGE" | grep \
      -E "Welcome to my excellent blog|Connected successfully"

    break
  fi

  echo "Attempt $i/30: waiting..."
  sleep 10
done

# ============================================================
# FINAL SUMMARY
# ============================================================

echo
echo "=========================================="
echo "FINAL LAB RESOURCES"
echo "=========================================="

echo "Project:"
echo "$PROJECT_ID"

echo
echo "VM:"
gcloud compute instances list \
  --filter="name=$VM_NAME"

echo
echo "Cloud SQL:"
gcloud sql instances list \
  --filter="name=$SQL_NAME"

echo
echo "Bucket:"
gcloud storage ls \
  "gs://$PROJECT_ID"

echo
echo "Image:"
echo "$IMAGE_URL"

echo
echo "Website:"
echo "http://$BLOG_EXTERNAL_IP/index.php"

echo
echo "=========================================="
echo "LAB AUTOMATION COMPLETE"
echo "=========================================="
echo
echo "Click Check my progress."
echo "Verify Connected successfully + image."
echo "Then click End Lab."
EOF

chmod +x full-storage-sql-lab.sh
./full-storage-sql-lab.sh
