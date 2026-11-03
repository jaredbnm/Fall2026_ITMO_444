#!/bin/bash
set -euo pipefail

export $(grep -v '^#' .env | xargs)
export AWS_DEFAULT_REGION="$AWS_REGION"   # lets us skip --region on every call

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
GEMINI_PARAM_ARN="arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter${GEMINI_PARAM_NAME}"
DB_PASSWORD_ARN="arn:aws:ssm:${AWS_REGION}:${ACCOUNT_ID}:parameter${DB_PASSWORD_PARAM}"

# Portable single-line base64 (works on macOS and Linux; macOS base64 has no -w0)
b64() { base64 < "$1" | tr -d '\n'; }

# ---------------------------------------------------------------------------
# Helper functions (each one is used twice, once per tier)
# ---------------------------------------------------------------------------

# $1 = role name, $2 = instance profile name
ensure_role_and_profile() {
  local ROLE="$1" PROFILE="$2"
  aws iam create-role --role-name "$ROLE" \
    --assume-role-policy-document file://trust-policy.json >/dev/null 2>&1 || echo "Role $ROLE exists, skipping."
  aws iam create-instance-profile --instance-profile-name "$PROFILE" >/dev/null 2>&1 || echo "Profile $PROFILE exists, skipping."
  aws iam add-role-to-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE" >/dev/null 2>&1 || true
}

# $1 = name. Prints the target group ARN (log lines go to stderr so they are not captured)
ensure_target_group() {
  local NAME="$1" ARN
  ARN=$(aws elbv2 describe-target-groups --names "$NAME" \
    --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)
  if [ -z "$ARN" ] || [ "$ARN" = "None" ]; then
    ARN=$(aws elbv2 create-target-group \
      --name "$NAME" --protocol HTTP --port 3000 --vpc-id "$VPC_ID" --target-type instance \
      --health-check-protocol HTTP --health-check-path / \
      --health-check-interval-seconds 10 --health-check-timeout-seconds 5 \
      --healthy-threshold-count 2 --unhealthy-threshold-count 2 \
      --query "TargetGroups[0].TargetGroupArn" --output text)
  else
    echo "Target group $NAME already exists, skipping." >&2
  fi
  echo "$ARN"
}

# $1 = port, $2 = target group ARN
ensure_listener() {
  local PORT="$1" TG_ARN="$2" EXISTING
  EXISTING=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" \
    --query "Listeners[].Port" --output text 2>/dev/null || true)
  if echo "$EXISTING" | tr '\t' '\n' | grep -qx "$PORT"; then
    echo "Listener on port $PORT already exists, skipping."
  else
    aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" \
      --protocol HTTP --port "$PORT" \
      --default-actions "Type=forward,TargetGroupArn=$TG_ARN" >/dev/null
  fi
}

# Writes user-data-<name>.sh
# $1 = name (weather or advisor), $2 = app folder, $3 = extra Environment= lines,
# $4 = extra setup commands to run before npm install (may be empty)
build_user_data() {
  local NAME="$1" APP_DIR="$2" EXTRA_ENV="$3" EXTRA_SETUP="${4:-}"
  local APP_JS_B64 PKG_JSON_B64
  APP_JS_B64=$(b64 "$APP_DIR/app.js")
  PKG_JSON_B64=$(b64 "$APP_DIR/package.json")
  cat > "user-data-${NAME}.sh" << EOF
#!/bin/bash
dnf update -y
dnf install -y nodejs
mkdir -p /opt/app
${EXTRA_SETUP}
echo "$APP_JS_B64" | base64 -d > /opt/app/app.js
echo "$PKG_JSON_B64" | base64 -d > /opt/app/package.json
cd /opt/app
npm install --omit=dev

cat > /etc/systemd/system/${NAME}.service << 'SERVICE'
[Unit]
Description=${NAME} app
After=network.target

[Service]
Environment=PORT=3000
Environment=AWS_REGION=$AWS_REGION
${EXTRA_ENV}
WorkingDirectory=/opt/app
ExecStart=/usr/bin/node /opt/app/app.js
Restart=always
User=ec2-user

[Install]
WantedBy=multi-user.target
SERVICE

chown -R ec2-user:ec2-user /opt/app
systemctl daemon-reload
systemctl enable ${NAME}.service
systemctl start ${NAME}.service
EOF
}

# $1 = launch template name, $2 = instance profile name, $3 = user-data file, $4 = Name tag
ensure_launch_template() {
  local LT_NAME="$1" PROFILE="$2" USERDATA_FILE="$3" TAG="$4"
  cat > "lt-data-${TAG}.json" << EOF
{
  "ImageId": "$AMI_ID",
  "InstanceType": "$INSTANCE_TYPE",
  "KeyName": "$KEY_NAME",
  "SecurityGroupIds": ["$APP_SECURITY_GROUP_ID"],
  "IamInstanceProfile": { "Name": "$PROFILE" },
  "UserData": "$(b64 "$USERDATA_FILE")",
  "TagSpecifications": [
    { "ResourceType": "instance", "Tags": [{ "Key": "Name", "Value": "$TAG" }] }
  ]
}
EOF
  if aws ec2 describe-launch-templates --launch-template-names "$LT_NAME" >/dev/null 2>&1; then
    echo "Template $LT_NAME exists, publishing a new version"
    aws ec2 create-launch-template-version --launch-template-name "$LT_NAME" \
      --source-version 1 --launch-template-data "file://lt-data-${TAG}.json" >/dev/null
  else
    aws ec2 create-launch-template --launch-template-name "$LT_NAME" \
      --launch-template-data "file://lt-data-${TAG}.json" >/dev/null
  fi
}

# $1 = ASG name, $2 = launch template name, $3 = target group ARN, $4 = Name tag
ensure_asg() {
  local ASG="$1" LT_NAME="$2" TG_ARN="$3" TAG="$4" EXISTING
  EXISTING=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
    --query "AutoScalingGroups[0].AutoScalingGroupName" --output text 2>/dev/null || true)
  if [ -z "$EXISTING" ] || [ "$EXISTING" = "None" ]; then
    aws autoscaling create-auto-scaling-group \
      --auto-scaling-group-name "$ASG" \
      --launch-template "LaunchTemplateName=$LT_NAME,Version=\$Latest" \
      --min-size 1 --max-size 1 --desired-capacity 1 \
      --vpc-zone-identifier "$SUBNET_A,$SUBNET_B" \
      --target-group-arns "$TG_ARN" \
      --health-check-type ELB --health-check-grace-period 120 \
      --tags "ResourceId=$ASG,ResourceType=auto-scaling-group,Key=Name,Value=$TAG,PropagateAtLaunch=true"
  else
    echo "Auto Scaling Group $ASG already exists, skipping."
  fi
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

echo "== 1. Checking the Gemini key and the database =="
if ! aws ssm get-parameter --name "$GEMINI_PARAM_NAME" >/dev/null 2>&1; then
  echo "Parameter $GEMINI_PARAM_NAME was not found. Create it first (Part C of the lab)."
  exit 1
fi
if [ ! -f db_outputs.env ]; then
  echo "db_outputs.env was not found. Run ./create_database.sh first (Part E of the lab)."
  exit 1
fi
export $(grep -v '^#' db_outputs.env | xargs)   # gives us DB_HOST

echo "== 2. IAM roles and instance profiles =="
cat > trust-policy.json << 'EOF'
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow", "Principal": { "Service": "ec2.amazonaws.com" }, "Action": "sts:AssumeRole" } ] }
EOF
ensure_role_and_profile "$WEATHER_ROLE_NAME" "$WEATHER_PROFILE_NAME"
ensure_role_and_profile "$ADVISOR_ROLE_NAME" "$ADVISOR_PROFILE_NAME"

# Each role may read only the one secret its tier needs, and nothing else.
cat > weather-policy.json << EOF
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow", "Action": ["ssm:GetParameter"], "Resource": "${DB_PASSWORD_ARN}" } ] }
EOF
aws iam put-role-policy --role-name "$WEATHER_ROLE_NAME" \
  --policy-name "${WEATHER_ROLE_NAME}-policy" --policy-document file://weather-policy.json

cat > advisor-policy.json << EOF
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow", "Action": ["ssm:GetParameter"], "Resource": "${GEMINI_PARAM_ARN}" } ] }
EOF
aws iam put-role-policy --role-name "$ADVISOR_ROLE_NAME" \
  --policy-name "${ADVISOR_ROLE_NAME}-policy" --policy-document file://advisor-policy.json
echo "Waiting 15s for IAM propagation..."
sleep 15

echo "== 3. Default VPC and subnets in both AZs =="
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text)
SUBNET_A=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$AZ_A" \
  --query "Subnets[0].SubnetId" --output text)
SUBNET_B=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$AZ_B" \
  --query "Subnets[0].SubnetId" --output text)

echo "== 4. Security groups =="
ALB_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$ALB_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
if [ -z "$ALB_SECURITY_GROUP_ID" ] || [ "$ALB_SECURITY_GROUP_ID" = "None" ]; then
  ALB_SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name "$ALB_SG_NAME" \
    --description "Allow inbound to the ALB on the app listener ports" \
    --vpc-id "$VPC_ID" --query "GroupId" --output text)
  aws ec2 authorize-security-group-ingress --group-id "$ALB_SECURITY_GROUP_ID" \
    --protocol tcp --port "$WEATHER_LISTENER_PORT" --cidr 0.0.0.0/0 >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$ALB_SECURITY_GROUP_ID" \
    --protocol tcp --port "$ADVISOR_LISTENER_PORT" --cidr 0.0.0.0/0 >/dev/null
else
  echo "ALB security group already exists, skipping."
fi
aws ec2 revoke-security-group-ingress --group-id "$APP_SECURITY_GROUP_ID" \
  --protocol tcp --port 3000 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$APP_SECURITY_GROUP_ID" \
  --protocol tcp --port 3000 --source-group "$ALB_SECURITY_GROUP_ID" >/dev/null 2>&1 || true

echo "== 5. Target groups and the load balancer (the ALB comes first this time) =="
WEATHER_TG_ARN=$(ensure_target_group "$WEATHER_TG_NAME")
ADVISOR_TG_ARN=$(ensure_target_group "$ADVISOR_TG_NAME")

ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null || true)
if [ -z "$ALB_ARN" ] || [ "$ALB_ARN" = "None" ]; then
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "$ALB_NAME" --subnets "$SUBNET_A" "$SUBNET_B" \
    --security-groups "$ALB_SECURITY_GROUP_ID" \
    --scheme internet-facing --type application \
    --query "LoadBalancers[0].LoadBalancerArn" --output text)
  echo "Waiting for the ALB to become active..."
  aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"
else
  echo "Load balancer $ALB_NAME already exists, skipping."
fi
ensure_listener "$WEATHER_LISTENER_PORT" "$WEATHER_TG_ARN"
ensure_listener "$ADVISOR_LISTENER_PORT" "$ADVISOR_TG_ARN"
ALB_DNS_NAME=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query "LoadBalancers[0].DNSName" --output text)

echo "== 6. Launch templates (the advisor needs the ALB address to reach the weather tier) =="
WEATHER_ENV="Environment=\"NWS_USER_AGENT=(itmo-444-544 weather lab, ${CONTACT_EMAIL})\"
Environment=DB_HOST=${DB_HOST}
Environment=DB_NAME=${DB_NAME}
Environment=DB_USER=${DB_USER}
Environment=DB_PASSWORD_PARAM=${DB_PASSWORD_PARAM}
Environment=CACHE_SECONDS=${CACHE_SECONDS}"
# The RDS certificate bundle (so the app can verify the database) and the psql client for your own queries.
WEATHER_SETUP="dnf install -y postgresql15
curl -sS -o /opt/app/rds-ca.pem https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"
ADVISOR_ENV="Environment=WEATHER_URL=http://${ALB_DNS_NAME}:${WEATHER_LISTENER_PORT}
Environment=GEMINI_KEY_PARAM=${GEMINI_PARAM_NAME}
Environment=GEMINI_MODEL=${GEMINI_MODEL}
Environment=KEY_CACHE_SECONDS=${KEY_CACHE_SECONDS}"

build_user_data weather weather-app "$WEATHER_ENV" "$WEATHER_SETUP"
build_user_data advisor advisor-app "$ADVISOR_ENV"
ensure_launch_template "$WEATHER_LT_NAME" "$WEATHER_PROFILE_NAME" user-data-weather.sh weather-app
ensure_launch_template "$ADVISOR_LT_NAME" "$ADVISOR_PROFILE_NAME" user-data-advisor.sh advisor-app

echo "== 7. Auto Scaling Groups (these launch the instances) =="
ensure_asg "$WEATHER_ASG_NAME" "$WEATHER_LT_NAME" "$WEATHER_TG_ARN" weather-app
ensure_asg "$ADVISOR_ASG_NAME" "$ADVISOR_LT_NAME" "$ADVISOR_TG_ARN" advisor-app

cat > stack_outputs.env << EOF
VPC_ID=$VPC_ID
SUBNET_A=$SUBNET_A
SUBNET_B=$SUBNET_B
ALB_SECURITY_GROUP_ID=$ALB_SECURITY_GROUP_ID
ALB_ARN=$ALB_ARN
ALB_DNS_NAME=$ALB_DNS_NAME
WEATHER_TG_ARN=$WEATHER_TG_ARN
ADVISOR_TG_ARN=$ADVISOR_TG_ARN
EOF
rm -f trust-policy.json weather-policy.json advisor-policy.json user-data-weather.sh user-data-advisor.sh lt-data-*.json

echo
echo "Done. ALB DNS name: $ALB_DNS_NAME"
echo "Weather service: http://$ALB_DNS_NAME:$WEATHER_LISTENER_PORT/weather?zip=60616   (saved lookups: /history)"
echo "Advisor page:    http://$ALB_DNS_NAME:$ADVISOR_LISTENER_PORT/"
echo "Give the target groups 2 to 3 minutes to report healthy (the first boot installs Node and your app)."