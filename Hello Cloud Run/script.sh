cat > full-cloud-run-lab.sh <<'EOF'
#!/bin/bash

set -uo pipefail

# ============================================================
# HELLO CLOUD RUN
# FULL LAB AUTOMATION
# ============================================================

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"

if [ -z "$PROJECT_ID" ] || [ "$PROJECT_ID" = "(unset)" ]; then
    echo "ERROR: Google Cloud project is not set."
    echo "Run: gcloud config set project PROJECT_ID"
    exit 1
fi

export GOOGLE_CLOUD_PROJECT="$PROJECT_ID"

TASK1="NOT COMPLETED"
TASK2="NOT COMPLETED"
TASK3="NOT COMPLETED"
TASK4="NOT COMPLETED"
TASK5="NOT COMPLETED"
TASK6="NOT COMPLETED"

# ============================================================
# REGION
# ============================================================

REGION="${REGION:-}"

if [ -z "$REGION" ]; then
    CURRENT_REGION="$(gcloud config get-value compute/region 2>/dev/null || true)"

    if [ "$CURRENT_REGION" != "(unset)" ] && [ -n "$CURRENT_REGION" ]; then
        REGION="$CURRENT_REGION"
    fi
fi

if [ -z "$REGION" ]; then
    echo
    echo "============================================================"
    echo "LAB REGION REQUIRED"
    echo "============================================================"
    echo "Enter the REGION shown in your Google Skills lab."
    echo "Example: us-central1"
    echo
    read -r -p "Region: " REGION
fi

if [ -z "$REGION" ]; then
    echo "ERROR: Region cannot be empty."
    exit 1
fi

LOCATION="$REGION"

echo
echo "============================================================"
echo "HELLO CLOUD RUN LAB"
echo "============================================================"
echo "Project : $PROJECT_ID"
echo "Region  : $REGION"
echo "============================================================"

# ============================================================
# TASK 1
# Enable Cloud Run + Artifact Registry APIs
# ============================================================

echo
echo "============================================================"
echo "TASK 1 - ENABLE APIs"
echo "============================================================"

if gcloud services enable \
    run.googleapis.com \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    --project="$PROJECT_ID" \
    --quiet; then

    gcloud config set compute/region "$REGION" --quiet >/dev/null 2>&1 || true

    TASK1="COMPLETED"
    echo "TASK 1: COMPLETED"

else

    echo "TASK 1: FAILED"

fi

# ============================================================
# TASK 2
# Create Node.js application
# ============================================================

echo
echo "============================================================"
echo "TASK 2 - CREATE NODE.JS APPLICATION"
echo "============================================================"

rm -rf helloworld
mkdir -p helloworld

cd helloworld || exit 1

cat > package.json <<'JSON'
{
  "name": "helloworld",
  "description": "Simple hello world sample in Node",
  "version": "1.0.0",
  "main": "index.js",
  "scripts": {
    "start": "node index.js"
  },
  "author": "Google LLC",
  "license": "Apache-2.0",
  "dependencies": {
    "express": "^4.17.1"
  }
}
JSON

cat > index.js <<'JS'
const express = require('express');

const app = express();

const port = process.env.PORT || 8080;

app.get('/', (req, res) => {
  const name = process.env.NAME || 'World';
  res.send(`Hello ${name}!`);
});

app.listen(port, () => {
  console.log(`helloworld: listening on port ${port}`);
});
JS

cat > Dockerfile <<'DOCKER'
FROM node:20-slim

WORKDIR /usr/src/app

COPY package*.json ./

RUN npm install --only=production

COPY . ./

CMD [ "npm", "start" ]
DOCKER

if [ -f package.json ] && [ -f index.js ] && [ -f Dockerfile ]; then

    TASK2="COMPLETED"
    echo "TASK 2: COMPLETED"

else

    echo "TASK 2: FAILED"

fi

# ============================================================
# TASK 3
# Create Artifact Registry repository
# ============================================================

echo
echo "============================================================"
echo "TASK 3 - ARTIFACT REGISTRY"
echo "============================================================"

if gcloud artifacts repositories describe my-repository \
    --location="$LOCATION" \
    --project="$PROJECT_ID" \
    >/dev/null 2>&1; then

    echo "Repository already exists."

else

    if ! gcloud artifacts repositories create my-repository \
        --repository-format=docker \
        --location="$LOCATION" \
        --description="Docker repository" \
        --project="$PROJECT_ID"; then

        echo "Repository creation failed."
    fi

fi

echo
echo "Configuring Docker authentication..."

gcloud auth configure-docker \
    "$LOCATION-docker.pkg.dev" \
    --quiet >/dev/null 2>&1 || true

if gcloud artifacts repositories describe my-repository \
    --location="$LOCATION" \
    --project="$PROJECT_ID" \
    >/dev/null 2>&1; then

    TASK3="COMPLETED"
    echo "TASK 3: COMPLETED"

else

    echo "TASK 3: FAILED"

fi

# ============================================================
# TASK 4
# Build container + upload to Artifact Registry
# ============================================================

echo
echo "============================================================"
echo "TASK 4 - BUILD + UPLOAD CONTAINER"
echo "============================================================"

IMAGE="$LOCATION-docker.pkg.dev/$PROJECT_ID/my-repository/helloworld"

echo "Image:"
echo "$IMAGE"

if gcloud builds submit \
    --tag="$IMAGE" \
    --project="$PROJECT_ID"; then

    echo
    echo "Cloud Build completed successfully."

    if gcloud artifacts docker images list \
        "$LOCATION-docker.pkg.dev/$PROJECT_ID/my-repository" \
        --include-tags \
        --format="value(package)" \
        --project="$PROJECT_ID" 2>/dev/null |
        grep -q "helloworld"; then

        TASK4="COMPLETED"
        echo "TASK 4: COMPLETED"

    else

        echo "TASK 4: Image not found in Artifact Registry."

    fi

else

    echo "TASK 4: FAILED"

fi

# ============================================================
# OPTIONAL LOCAL TEST
# ============================================================

echo
echo "============================================================"
echo "LOCAL CONTAINER TEST"
echo "============================================================"

docker rm -f helloworld-local >/dev/null 2>&1 || true

if docker run -d \
    --name helloworld-local \
    -p 8080:8080 \
    "$IMAGE" >/dev/null 2>&1; then

    sleep 8

    LOCAL_RESPONSE="$(curl -s --max-time 10 http://localhost:8080 2>/dev/null || true)"

    echo "Response:"
    echo "$LOCAL_RESPONSE"

    docker rm -f helloworld-local >/dev/null 2>&1 || true

else

    echo "Local Docker test unavailable."
    echo "Continuing with Cloud Run deployment."

fi

# ============================================================
# TASK 5
# Deploy Cloud Run
# ============================================================

echo
echo "============================================================"
echo "TASK 5 - DEPLOY CLOUD RUN"
echo "============================================================"

if gcloud run deploy helloworld \
    --image="$IMAGE" \
    --allow-unauthenticated \
    --region="$LOCATION" \
    --platform=managed \
    --project="$PROJECT_ID" \
    --quiet; then

    echo
    echo "Cloud Run deployment succeeded."

else

    echo "TASK 5: DEPLOYMENT FAILED"

fi

# ============================================================
# GET SERVICE URL
# ============================================================

SERVICE_URL="$(gcloud run services describe helloworld \
    --region="$LOCATION" \
    --project="$PROJECT_ID" \
    --format='value(status.url)' 2>/dev/null || true)"

echo
echo "Service URL:"
echo "$SERVICE_URL"

# ============================================================
# TEST CLOUD RUN
# ============================================================

echo
echo "Testing Cloud Run service..."

RUN_RESPONSE=""

if [ -n "$SERVICE_URL" ]; then

    for i in {1..12}; do

        RUN_RESPONSE="$(curl -Ls --max-time 20 "$SERVICE_URL" 2>/dev/null || true)"

        if echo "$RUN_RESPONSE" | grep -q "Hello World!"; then
            break
        fi

        echo "Waiting for service..."
        sleep 10

    done

fi

echo
echo "Cloud Run response:"
echo "$RUN_RESPONSE"

if echo "$RUN_RESPONSE" | grep -q "Hello World!"; then

    TASK5="COMPLETED"
    echo
    echo "TASK 5: COMPLETED"

else

    echo
    echo "TASK 5: FAILED - expected Hello World!"

fi

# ============================================================
# FINAL STATUS BEFORE CLEANUP
# ============================================================

cd ..

echo
echo
echo "############################################################"
echo "#                  LAB STATUS                              #"
echo "############################################################"

printf "%-48s %s\n" \
    "Task 1 - Enable APIs" \
    "$TASK1"

printf "%-48s %s\n" \
    "Task 2 - Create Node.js application" \
    "$TASK2"

printf "%-48s %s\n" \
    "Task 3 - Create Artifact Registry repository" \
    "$TASK3"

printf "%-48s %s\n" \
    "Task 4 - Containerize + upload image" \
    "$TASK4"

printf "%-48s %s\n" \
    "Task 5 - Deploy containerized app to Cloud Run" \
    "$TASK5"

echo
echo "Cloud Run URL:"
echo "$SERVICE_URL"

echo
echo "============================================================"
echo "CHECKPOINT STEP"
echo "============================================================"
echo
echo "STOP HERE."
echo
echo "1. Go to Google Skills."
echo "2. Click 'Check my progress' for Task 3."
echo "3. Click 'Check my progress' for Task 4."
echo "4. Click 'Check my progress' for Task 5."
echo
echo "Make sure the checkpoints PASS before cleanup."
echo
read -r -p "After the checkpoints PASS, press ENTER to perform Task 6 cleanup..."

# ============================================================
# TASK 6
# Delete image + Cloud Run service
# ============================================================

echo
echo "============================================================"
echo "TASK 6 - CLEANUP"
echo "============================================================"

CLEANUP_OK=1

echo
echo "Deleting container image..."

if gcloud artifacts docker images delete \
    "$IMAGE" \
    --project="$PROJECT_ID" \
    --quiet >/dev/null 2>&1; then

    echo "Container image deleted."

else

    echo "Container image deletion failed."
    CLEANUP_OK=0

fi

echo
echo "Deleting Cloud Run service..."

if gcloud run services delete helloworld \
    --region="$LOCATION" \
    --project="$PROJECT_ID" \
    --quiet >/dev/null 2>&1; then

    echo "Cloud Run service deleted."

else

    echo "Cloud Run service deletion failed."
    CLEANUP_OK=0

fi

if [ "$CLEANUP_OK" -eq 1 ]; then

    TASK6="COMPLETED"

else

    TASK6="PARTIAL"

fi

# ============================================================
# FINAL STATUS
# ============================================================

echo
echo
echo "############################################################"
echo "#                 FINAL LAB STATUS                         #"
echo "############################################################"

printf "%-48s %s\n" \
    "Task 1 - Enable APIs" \
    "$TASK1"

printf "%-48s %s\n" \
    "Task 2 - Create Node.js application" \
    "$TASK2"

printf "%-48s %s\n" \
    "Task 3 - Create Artifact Registry repository" \
    "$TASK3"

printf "%-48s %s\n" \
    "Task 4 - Containerize + upload image" \
    "$TASK4"

printf "%-48s %s\n" \
    "Task 5 - Deploy containerized app to Cloud Run" \
    "$TASK5"

printf "%-48s %s\n" \
    "Task 6 - Delete image + Cloud Run service" \
    "$TASK6"

echo
echo "============================================================"

if [ "$TASK1" = "COMPLETED" ] &&
   [ "$TASK2" = "COMPLETED" ] &&
   [ "$TASK3" = "COMPLETED" ] &&
   [ "$TASK4" = "COMPLETED" ] &&
   [ "$TASK5" = "COMPLETED" ] &&
   [ "$TASK6" = "COMPLETED" ]; then

    echo "ALL AUTOMATED TASKS COMPLETED."

else

    echo "ONE OR MORE TASKS DID NOT COMPLETE."
    echo "Review the status above."

fi

echo "============================================================"
echo
echo "Now click End Lab after the required checkpoints are passed."
echo
EOF

chmod +x full-cloud-run-lab.sh
./full-cloud-run-lab.sh
