cat > full-vpc-lab.sh <<'EOF'
#!/bin/bash
set -u

PROJECT_ID="$(gcloud config get-value project 2>/dev/null)"

ZONE1="asia-southeast1-b"
ZONE2="us-west1-a"

VM1="mynet-us-vm"
VM2="mynet-r2-vm"
NETWORK="mynetwork"

echo "=========================================="
echo "GCP VPC + COMPUTE ENGINE LAB"
echo "Project: $PROJECT_ID"
echo "=========================================="

# --------------------------------------------------
# 1. ENABLE COMPUTE ENGINE API
# --------------------------------------------------

echo "[1/10] Enabling Compute Engine API..."

gcloud services enable compute.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

# --------------------------------------------------
# 2. DELETE DEFAULT NETWORK FIREWALL RULES
# --------------------------------------------------

echo "[2/10] Removing default VPC firewall rules..."

DEFAULT_RULES=$(gcloud compute firewall-rules list \
  --filter="network:default" \
  --format="value(name)" 2>/dev/null || true)

if [ -n "$DEFAULT_RULES" ]; then
  while read -r RULE; do
    [ -z "$RULE" ] && continue
    echo "Deleting $RULE"
    gcloud compute firewall-rules delete "$RULE" --quiet || true
  done <<< "$DEFAULT_RULES"
else
  echo "No default firewall rules found."
fi

# --------------------------------------------------
# 3. DELETE DEFAULT NETWORK
# --------------------------------------------------

echo "[3/10] Deleting default VPC network..."

if gcloud compute networks describe default >/dev/null 2>&1; then
  gcloud compute networks delete default --quiet
  sleep 10
else
  echo "Default network already absent."
fi

# --------------------------------------------------
# 4. CREATE AUTOMATIC MODE VPC
# --------------------------------------------------

echo "[4/10] Creating mynetwork auto-mode VPC..."

if ! gcloud compute networks describe "$NETWORK" >/dev/null 2>&1; then
  gcloud compute networks create "$NETWORK" \
    --subnet-mode=auto
else
  echo "$NETWORK already exists."
fi

sleep 5

# --------------------------------------------------
# 5. CREATE FIREWALL RULES
# --------------------------------------------------

echo "[5/10] Creating firewall rules..."

# ICMP
gcloud compute firewall-rules create "${NETWORK}-allow-icmp" \
  --network="$NETWORK" \
  --direction=INGRESS \
  --priority=1000 \
  --action=ALLOW \
  --rules=icmp \
  --source-ranges=0.0.0.0/0 \
  --quiet 2>/dev/null || true

# Internal TCP/UDP/ICMP
gcloud compute firewall-rules create "${NETWORK}-allow-custom" \
  --network="$NETWORK" \
  --direction=INGRESS \
  --priority=1000 \
  --action=ALLOW \
  --rules=tcp,udp,icmp \
  --source-ranges=10.128.0.0/9 \
  --quiet 2>/dev/null || true

# SSH
gcloud compute firewall-rules create "${NETWORK}-allow-ssh" \
  --network="$NETWORK" \
  --direction=INGRESS \
  --priority=1000 \
  --action=ALLOW \
  --rules=tcp:22 \
  --source-ranges=0.0.0.0/0 \
  --quiet 2>/dev/null || true

# RDP
gcloud compute firewall-rules create "${NETWORK}-allow-rdp" \
  --network="$NETWORK" \
  --direction=INGRESS \
  --priority=1000 \
  --action=ALLOW \
  --rules=tcp:3389 \
  --source-ranges=0.0.0.0/0 \
  --quiet 2>/dev/null || true

# --------------------------------------------------
# 6. CREATE VM IN ASIA-SOUTHEAST1
# --------------------------------------------------

echo "[6/10] Creating $VM1..."

if ! gcloud compute instances describe "$VM1" \
  --zone="$ZONE1" >/dev/null 2>&1; then

  gcloud compute instances create "$VM1" \
    --zone="$ZONE1" \
    --machine-type=e2-micro \
    --network="$NETWORK" \
    --image-family=debian-12 \
    --image-project=debian-cloud
else
  echo "$VM1 already exists."
fi

# --------------------------------------------------
# 7. CREATE VM IN US-WEST1
# --------------------------------------------------

echo "[7/10] Creating $VM2..."

if ! gcloud compute instances describe "$VM2" \
  --zone="$ZONE2" >/dev/null 2>&1; then

  gcloud compute instances create "$VM2" \
    --zone="$ZONE2" \
    --machine-type=e2-micro \
    --network="$NETWORK" \
    --image-family=debian-12 \
    --image-project=debian-cloud
else
  echo "$VM2 already exists."
fi

echo
echo "Waiting for VMs..."
sleep 20

# --------------------------------------------------
# 8. GET IP ADDRESSES
# --------------------------------------------------

echo "[8/10] Getting VM IP addresses..."

INTERNAL1=$(gcloud compute instances describe "$VM1" \
  --zone="$ZONE1" \
  --format="value(networkInterfaces[0].networkIP)")

EXTERNAL1=$(gcloud compute instances describe "$VM1" \
  --zone="$ZONE1" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

INTERNAL2=$(gcloud compute instances describe "$VM2" \
  --zone="$ZONE2" \
  --format="value(networkInterfaces[0].networkIP)")

EXTERNAL2=$(gcloud compute instances describe "$VM2" \
  --zone="$ZONE2" \
  --format="value(networkInterfaces[0].accessConfigs[0].natIP)")

echo
echo "VM1: $VM1"
echo "Internal IP : $INTERNAL1"
echo "External IP : $EXTERNAL1"

echo
echo "VM2: $VM2"
echo "Internal IP : $INTERNAL2"
echo "External IP : $EXTERNAL2"

# --------------------------------------------------
# 9. CONNECTIVITY TESTS
# --------------------------------------------------

echo
echo "[9/10] Testing SSH + PING connectivity..."

echo
echo "---- SSH TEST ----"

gcloud compute ssh "$VM1" \
  --zone="$ZONE1" \
  --quiet \
  --command="echo 'SSH connection successful'" || true

echo
echo "---- INTERNAL IP PING ----"

gcloud compute ssh "$VM1" \
  --zone="$ZONE1" \
  --quiet \
  --command="ping -c 3 $INTERNAL2" || true

echo
echo "---- EXTERNAL IP PING ----"

gcloud compute ssh "$VM1" \
  --zone="$ZONE1" \
  --quiet \
  --command="ping -c 3 $EXTERNAL2" || true

# --------------------------------------------------
# 10. REMOVE FIREWALL RULES AS LAB REQUIRES
# --------------------------------------------------

echo
echo "[10/10] Removing firewall rules individually..."

echo "Deleting ICMP rule..."
gcloud compute firewall-rules delete \
  "${NETWORK}-allow-icmp" \
  --quiet || true

sleep 3

echo
echo "Testing external ping after ICMP deletion..."

gcloud compute ssh "$VM1" \
  --zone="$ZONE1" \
  --quiet \
  --command="timeout 10 ping -c 3 $EXTERNAL2" || true

echo
echo "Testing internal ping after ICMP deletion..."
echo "Internal ping may still work through allow-custom."

gcloud compute ssh "$VM1" \
  --zone="$ZONE1" \
  --quiet \
  --command="timeout 10 ping -c 3 $INTERNAL2" || true

echo
echo "Deleting CUSTOM rule..."

gcloud compute firewall-rules delete \
  "${NETWORK}-allow-custom" \
  --quiet || true

sleep 3

echo
echo "Testing internal ping after custom deletion..."

gcloud compute ssh "$VM1" \
  --zone="$ZONE1" \
  --quiet \
  --command="timeout 10 ping -c 3 $INTERNAL2" || true

echo
echo "Deleting SSH rule..."

gcloud compute firewall-rules delete \
  "${NETWORK}-allow-ssh" \
  --quiet || true

sleep 3

echo
echo "Attempting SSH after SSH firewall deletion..."
echo "Failure is expected."

timeout 20 gcloud compute ssh "$VM1" \
  --zone="$ZONE1" \
  --quiet \
  --command="echo 'This should not connect'" || true

# --------------------------------------------------
# FINAL STATE
# --------------------------------------------------

echo
echo "=========================================="
echo "FINAL VPC STATE"
echo "=========================================="

gcloud compute networks describe "$NETWORK" \
  --format="table(name,subnetMode)"

echo
echo "Remaining firewall rules:"
gcloud compute firewall-rules list \
  --filter="network:$NETWORK" \
  --format="table(name,direction,allowed[].map().firewall_rule().list():label=RULES)"

echo
echo "VM INSTANCES:"
gcloud compute instances list \
  --filter="name=('mynet-us-vm' 'mynet-r2-vm')" \
  --format="table(name,zone,status,machineType.basename(),networkInterfaces[0].networkIP,networkInterfaces[0].accessConfigs[0].natIP)"

echo
echo "=========================================="
echo "LAB SCRIPT FINISHED"
echo "=========================================="
echo "Now click 'Check my progress' in the lab."
echo "If the checkpoint passes, click 'End Lab'."
echo "=========================================="
EOF

chmod +x full-vpc-lab.sh
./full-vpc-lab.sh
