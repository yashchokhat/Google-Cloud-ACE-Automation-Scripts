cat > full-storage-sql-lab.sh <<'EOF'
#!/bin/bash

set -uo pipefail

# ============================================================
# GOOGLE CLOUD FUNDAMENTALS
# GETTING STARTED WITH CLOUD STORAGE AND CLOUD SQL
# FULL LAB AUTOMATION
# ============================================================

PROJECT="$(gcloud config get-value project 2>/dev/null || true)"

REGION="us-central1"
ZONE="us-central1-a"

VM="bloghost"

SQL="blog-db"
SQL_USER="blogdbuser"
SQL_PASS='Passw0rd1!'

BUCKET="gs://${PROJECT}"
IMAGE_OBJECT="my-excellent-blog.png"
IMAGE_URL="https://storage.googleapis.com/${PROJECT}/${IMAGE_OBJECT}"

TASK1="FAILED"
TASK2="FAILED"
TASK3="FAILED"
TASK4="FAILED"
TASK5="FAILED"
TASK6="FAILED"

echo
echo "============================================================"
echo "CLOUD STORAGE + CLOUD SQL LAB"
echo "============================================================"
echo "PROJECT : $PROJECT"
echo "REGION  : $REGION"
echo "ZONE    : $ZONE"
echo "============================================================"

if [ -z "$PROJECT" ] || [ "$PROJECT" = "(unset)" ]; then
    echo "ERROR: Project is not configured."
    exit 1
fi

# ============================================================
# TASK 1 - VERIFY AUTHENTICATED LAB SESSION
# ============================================================

echo
echo "============================================================"
echo "TASK 1 - SIGN IN / LAB SESSION"
echo "============================================================"

ACCOUNT="$(gcloud auth list \
    --filter=status:ACTIVE \
    --format='value(account)' 2>/dev/null | head -n1 || true)"

if [ -n "$ACCOUNT" ] && [ "$PROJECT" != "(unset)" ]; then
    echo "Active account : $ACCOUNT"
    echo "Active project : $PROJECT"
    TASK1="COMPLETED"
else
    echo "Authentication/project check failed."
fi

echo "TASK 1: $TASK1"

# ============================================================
# API ENABLEMENT
# ============================================================

echo
echo "Enabling APIs..."

gcloud services enable \
    compute.googleapis.com \
    sqladmin.googleapis.com \
    storage.googleapis.com \
    --project="$PROJECT" \
    --quiet

gcloud config set project "$PROJECT" --quiet >/dev/null 2>&1
gcloud config set compute/region "$REGION" --quiet >/dev/null 2>&1
gcloud config set compute/zone "$ZONE" --quiet >/dev/null 2>&1

# ============================================================
# TASK 2 - DEPLOY WEB SERVER VM
# ============================================================

echo
echo "============================================================"
echo "TASK 2 - DEPLOY WEB SERVER VM"
echo "============================================================"

cat > startup.sh <<'STARTUP'
#!/bin/bash
apt-get install apache2 php php-mysql -y
service apache2 restart
STARTUP

# HTTP firewall
gcloud compute firewall-rules create default-allow-http \
    --project="$PROJECT" \
    --network=default \
    --direction=INGRESS \
    --priority=1000 \
    --action=ALLOW \
    --rules=tcp:80 \
    --source-ranges=0.0.0.0/0 \
    --target-tags=http-server \
    --quiet 2>/dev/null || true

# Check whether VM exists
if gcloud compute instances describe "$VM" \
    --project="$PROJECT" \
    --zone="$ZONE" >/dev/null 2>&1; then

    echo "bloghost already exists."

else

    echo "Creating bloghost..."

    if ! gcloud compute instances create "$VM" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --machine-type=e2-standard-2 \
        --image-family=debian-12 \
        --image-project=debian-cloud \
        --network=default \
        --tags=http-server \
        --metadata-from-file=startup-script=startup.sh; then

        echo "TASK 2 creation failed."
        exit 1
    fi
fi

echo
echo "Waiting for bloghost..."

for i in {1..30}; do

    VM_STATUS="$(gcloud compute instances describe "$VM" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --format='value(status)' 2>/dev/null || true)"

    echo "VM status: ${VM_STATUS:-CREATING}"

    if [ "$VM_STATUS" = "RUNNING" ]; then
        break
    fi

    sleep 10
done

sleep 40

VM_STATUS="$(gcloud compute instances describe "$VM" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --format='value(status)' 2>/dev/null || true)"

VM_MACHINE="$(gcloud compute instances describe "$VM" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --format='value(machineType.basename())' 2>/dev/null || true)"

VM_INTERNAL="$(gcloud compute instances describe "$VM" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --format='value(networkInterfaces[0].networkIP)' 2>/dev/null || true)"

VM_EXTERNAL="$(gcloud compute instances describe "$VM" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>/dev/null || true)"

VM_TAGS="$(gcloud compute instances describe "$VM" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --format='value(tags.items)' 2>/dev/null || true)"

VM_SCRIPT="$(gcloud compute instances describe "$VM" \
    --project="$PROJECT" \
    --zone="$ZONE" \
    --format='value(metadata.items)' 2>/dev/null || true)"

HTTP_CODE="$(curl -s \
    -o /dev/null \
    -w '%{http_code}' \
    --max-time 15 \
    "http://$VM_EXTERNAL" 2>/dev/null || true)"

echo
echo "VM STATUS   : $VM_STATUS"
echo "MACHINE     : $VM_MACHINE"
echo "ZONE        : $ZONE"
echo "INTERNAL IP : $VM_INTERNAL"
echo "EXTERNAL IP : $VM_EXTERNAL"
echo "HTTP        : $HTTP_CODE"

if [ "$VM_STATUS" = "RUNNING" ] &&
   [ "$VM_MACHINE" = "e2-standard-2" ] &&
   echo "$VM_TAGS" | grep -qw "http-server" &&
   echo "$VM_SCRIPT" | grep -q "apt-get install apache2 php php-mysql -y"; then

    TASK2="COMPLETED"
fi

echo "TASK 2: $TASK2"

# ============================================================
# TASK 3 - CLOUD STORAGE BUCKET + IMAGE
# ============================================================

echo
echo "============================================================"
echo "TASK 3 - CLOUD STORAGE"
echo "============================================================"

if gcloud storage buckets describe \
    "$BUCKET" \
    --project="$PROJECT" >/dev/null 2>&1; then

    echo "Bucket already exists."

else

    echo "Creating US multi-region bucket..."

    gcloud storage buckets create \
        "$BUCKET" \
        --project="$PROJECT" \
        --location=US
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
    "$BUCKET/$IMAGE_OBJECT"

echo
echo "Making object publicly readable..."

gsutil acl ch \
    -u allUsers:R \
    "$BUCKET/$IMAGE_OBJECT"

OBJECT_EXISTS="$(gcloud storage ls \
    "$BUCKET/$IMAGE_OBJECT" 2>/dev/null || true)"

IMAGE_HTTP="$(curl -s \
    -o /dev/null \
    -w '%{http_code}' \
    --max-time 15 \
    "$IMAGE_URL" 2>/dev/null || true)"

echo
echo "OBJECT : $OBJECT_EXISTS"
echo "URL    : $IMAGE_URL"
echo "HTTP   : $IMAGE_HTTP"

if [ -n "$OBJECT_EXISTS" ] && [ "$IMAGE_HTTP" = "200" ]; then
    TASK3="COMPLETED"
fi

echo "TASK 3: $TASK3"

# ============================================================
# TASK 4 - CLOUD SQL
# ============================================================

echo
echo "============================================================"
echo "TASK 4 - CLOUD SQL"
echo "============================================================"

# Avoid gcloud Compute location inheritance conflicts
gcloud config unset compute/region --quiet >/dev/null 2>&1 || true
gcloud config unset compute/zone --quiet >/dev/null 2>&1 || true

SQL_EXISTS=0

if gcloud sql instances describe "$SQL" \
    --project="$PROJECT" >/dev/null 2>&1; then
    SQL_EXISTS=1
fi

if [ "$SQL_EXISTS" -eq 0 ]; then

    echo "Creating blog-db..."

    # Enterprise + Sandbox-style small dedicated instance
    gcloud sql instances create "$SQL" \
        --project="$PROJECT" \
        --database-version=MYSQL_8_0 \
        --edition=ENTERPRISE \
        --tier=db-custom-1-3840 \
        --region="$REGION" \
        --zone="$ZONE" \
        --availability-type=ZONAL \
        --assign-ip \
        --ssl-mode=ALLOW_UNENCRYPTED_AND_ENCRYPTED \
        --root-password="$SQL_PASS"

else

    echo "blog-db already exists."

fi

echo
echo "Waiting for Cloud SQL..."

for i in {1..60}; do

    SQL_STATUS="$(gcloud sql instances describe "$SQL" \
        --project="$PROJECT" \
        --format='value(state)' 2>/dev/null || true)"

    echo "SQL status: ${SQL_STATUS:-CREATING}"

    if [ "$SQL_STATUS" = "RUNNABLE" ]; then
        break
    fi

    sleep 10
done

SQL_STATUS="$(gcloud sql instances describe "$SQL" \
    --project="$PROJECT" \
    --format='value(state)' 2>/dev/null || true)"

SQL_IP="$(gcloud sql instances describe "$SQL" \
    --project="$PROJECT" \
    --format='value(ipAddresses[0].ipAddress)' 2>/dev/null || true)"

echo
echo "SQL STATUS : $SQL_STATUS"
echo "SQL IP     : $SQL_IP"

# ============================================================
# CREATE USER
# ============================================================

echo
echo "Creating blogdbuser..."

if gcloud sql users list \
    --project="$PROJECT" \
    --instance="$SQL" \
    --format='value(name)' 2>/dev/null |
    grep -qx "$SQL_USER"; then

    gcloud sql users set-password "$SQL_USER" \
        --project="$PROJECT" \
        --instance="$SQL" \
        --host="%" \
        --password="$SQL_PASS"

else

    gcloud sql users create "$SQL_USER" \
        --project="$PROJECT" \
        --instance="$SQL" \
        --host="%" \
        --password="$SQL_PASS"

fi

# ============================================================
# AUTHORIZE BLOGHOST EXTERNAL IP
# ============================================================

echo
echo "Authorizing bloghost..."

gcloud sql instances patch "$SQL" \
    --project="$PROJECT" \
    --authorized-networks="$VM_EXTERNAL/32" \
    --ssl-mode=ALLOW_UNENCRYPTED_AND_ENCRYPTED \
    --quiet

sleep 15

SQL_USER_CHECK="$(gcloud sql users list \
    --project="$PROJECT" \
    --instance="$SQL" \
    --format='value(name)' 2>/dev/null |
    grep -x "$SQL_USER" || true)"

AUTH_NETWORK="$(gcloud sql instances describe "$SQL" \
    --project="$PROJECT" \
    --format='value(settings.ipConfiguration.authorizedNetworks[].value)' \
    2>/dev/null || true)"

if [ "$SQL_STATUS" = "RUNNABLE" ] &&
   [ -n "$SQL_IP" ] &&
   [ -n "$SQL_USER_CHECK" ] &&
   echo "$AUTH_NETWORK" | grep -q "$VM_EXTERNAL"; then

    TASK4="COMPLETED"
fi

echo
echo "Authorized network:"
echo "$AUTH_NETWORK"

echo "TASK 4: $TASK4"

# Restore gcloud compute location
gcloud config set compute/region "$REGION" --quiet >/dev/null 2>&1
gcloud config set compute/zone "$ZONE" --quiet >/dev/null 2>&1

# ============================================================
# TASK 5 - CONNECT PHP APPLICATION TO CLOUD SQL
# ============================================================

echo
echo "============================================================"
echo "TASK 5 - CLOUD SQL CONNECTION"
echo "============================================================"

cat > index.php <<PHP
<html>
<head>
<title>Welcome to my excellent blog</title>
</head>
<body>

<h1>Welcome to my excellent blog</h1>

<?php

\$dbserver = "$SQL_IP";
\$dbuser = "blogdbuser";
\$dbpassword = "$SQL_PASS";

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

echo "Waiting for SSH..."

SSH_OK=0

for i in {1..30}; do

    if gcloud compute ssh "$VM" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --quiet \
        --command="echo SSH_READY" >/dev/null 2>&1; then

        SSH_OK=1
        break
    fi

    sleep 10
done

if [ "$SSH_OK" -eq 1 ]; then

    gcloud compute scp \
        ./index.php \
        "$VM:/tmp/index.php" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --quiet

    gcloud compute ssh "$VM" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --quiet \
        --command='
sudo cp /tmp/index.php /var/www/html/index.php
sudo chown www-data:www-data /var/www/html/index.php
sudo chmod 644 /var/www/html/index.php
sudo service apache2 restart
'

fi

sleep 10

PAGE="$(curl -s \
    --max-time 30 \
    "http://$VM_EXTERNAL/index.php" \
    2>/dev/null || true)"

echo
echo "PAGE RESPONSE:"
echo "$PAGE"

if echo "$PAGE" | grep -q "Connected successfully"; then
    TASK5="COMPLETED"
fi

echo
echo "TASK 5: $TASK5"

# ============================================================
# TASK 6 - DISPLAY STORAGE IMAGE
# ============================================================

echo
echo "============================================================"
echo "TASK 6 - CLOUD STORAGE IMAGE ON WEB PAGE"
echo "============================================================"

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
\$dbuser = "blogdbuser";
\$dbpassword = "$SQL_PASS";

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

if [ "$SSH_OK" -eq 1 ]; then

    gcloud compute scp \
        ./index.php \
        "$VM:/tmp/index.php" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --quiet

    gcloud compute ssh "$VM" \
        --project="$PROJECT" \
        --zone="$ZONE" \
        --quiet \
        --command='
sudo cp /tmp/index.php /var/www/html/index.php
sudo chown www-data:www-data /var/www/html/index.php
sudo chmod 644 /var/www/html/index.php
sudo service apache2 restart
'

fi

sleep 10

FINAL_PAGE="$(curl -s \
    --max-time 30 \
    "http://$VM_EXTERNAL/index.php" \
    2>/dev/null || true)"

echo
echo "FINAL PAGE:"
echo "$FINAL_PAGE"

SQL_PAGE_OK=0
IMAGE_PAGE_OK=0

if echo "$FINAL_PAGE" | grep -q "Connected successfully"; then
    SQL_PAGE_OK=1
fi

if echo "$FINAL_PAGE" | grep -q "$IMAGE_URL"; then
    IMAGE_PAGE_OK=1
fi

if [ "$SQL_PAGE_OK" -eq 1 ] &&
   [ "$IMAGE_PAGE_OK" -eq 1 ]; then
    TASK6="COMPLETED"
fi

echo
echo "TASK 6: $TASK6"

# ============================================================
# FINAL TASK REPORT
# ============================================================

echo
echo
echo "############################################################"
echo "#                      FINAL STATUS                        #"
echo "############################################################"

printf "%-62s %s\n" \
    "Task 1 - Sign in / authenticated lab session" \
    "$TASK1"

printf "%-62s %s\n" \
    "Task 2 - Deploy web server VM instance" \
    "$TASK2"

printf "%-62s %s\n" \
    "Task 3 - Cloud Storage bucket + public image" \
    "$TASK3"

printf "%-62s %s\n" \
    "Task 4 - Cloud SQL instance + user + network" \
    "$TASK4"

printf "%-62s %s\n" \
    "Task 5 - Connect application to Cloud SQL" \
    "$TASK5"

printf "%-62s %s\n" \
    "Task 6 - Display Cloud Storage image on webpage" \
    "$TASK6"

# ============================================================
# RESOURCE SUMMARY
# ============================================================

echo
echo "############################################################"
echo "#                     RESOURCES                            #"
echo "############################################################"

echo
echo "COMPUTE ENGINE:"
gcloud compute instances list \
    --filter="name=$VM" \
    --format="table(
        name,
        zone.basename(),
        machineType.basename(),
        status,
        networkInterfaces[0].networkIP,
        networkInterfaces[0].accessConfigs[0].natIP
    )" 2>/dev/null || true

echo
echo "CLOUD SQL:"
gcloud sql instances list \
    --filter="name=$SQL" \
    --format="table(
        name,
        databaseVersion,
        region,
        gceZone,
        tier,
        state,
        primaryAddress
    )" 2>/dev/null || true

echo
echo "CLOUD STORAGE:"
gcloud storage ls \
    "$BUCKET/$IMAGE_OBJECT" 2>/dev/null || true

echo
echo "WEBSITE:"
echo "http://$VM_EXTERNAL/index.php"

echo
echo "IMAGE:"
echo "$IMAGE_URL"

echo
echo "############################################################"

if [ "$TASK1" = "COMPLETED" ] &&
   [ "$TASK2" = "COMPLETED" ] &&
   [ "$TASK3" = "COMPLETED" ] &&
   [ "$TASK4" = "COMPLETED" ] &&
   [ "$TASK5" = "COMPLETED" ] &&
   [ "$TASK6" = "COMPLETED" ]; then

    echo "ALL TASKS COMPLETED SUCCESSFULLY."

else

    echo "ONE OR MORE TASKS FAILED."
    echo "Review the status above."

fi

echo "############################################################"
echo
echo "Now click Check my progress for each checkpoint."
echo "After the checkpoints pass, click End Lab."
echo

EOF

chmod +x full-storage-sql-lab.sh
./full-storage-sql-lab.sh
