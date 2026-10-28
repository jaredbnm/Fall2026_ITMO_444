#!/bin/bash
set -e
export AWS_PAGER=""  # keep the AWS CLI from pausing in `less` on JSON output
export $(grep -v '^#' .env | xargs)

echo "== S3 bucket =="
if aws s3api head-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null; then
  echo "Bucket already exists, skipping."
else
  aws s3api create-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION"
fi

cat > trust-policy.json << 'EOF'
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow", "Principal": { "Service": "ec2.amazonaws.com" }, "Action": "sts:AssumeRole" } ] }
EOF

echo "== Uploader role (PutObject on shared.txt only) =="
aws iam create-role --role-name "$UPLOADER_ROLE_NAME" \
  --assume-role-policy-document file://trust-policy.json 2>/dev/null || echo "Role exists, skipping."

cat > uploader-policy.json << EOF
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow", "Action": ["s3:PutObject"], "Resource": "arn:aws:s3:::${BUCKET_NAME}/shared.txt" } ] }
EOF

aws iam put-role-policy --role-name "$UPLOADER_ROLE_NAME" \
  --policy-name "${UPLOADER_ROLE_NAME}-policy" --policy-document file://uploader-policy.json

aws iam create-instance-profile --instance-profile-name "$UPLOADER_PROFILE_NAME" 2>/dev/null || echo "Profile exists, skipping."
aws iam add-role-to-instance-profile --instance-profile-name "$UPLOADER_PROFILE_NAME" \
  --role-name "$UPLOADER_ROLE_NAME" 2>/dev/null || true

echo "== Viewer role (GetObject + ListBucket on shared.txt only) =="
aws iam create-role --role-name "$VIEWER_ROLE_NAME" \
  --assume-role-policy-document file://trust-policy.json 2>/dev/null || echo "Role exists, skipping."

cat > viewer-policy.json << EOF
{ "Version": "2012-10-17", "Statement": [
  { "Effect": "Allow", "Action": ["s3:GetObject"], "Resource": "arn:aws:s3:::${BUCKET_NAME}/shared.txt" },
  { "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::${BUCKET_NAME}" } ] }
EOF

aws iam put-role-policy --role-name "$VIEWER_ROLE_NAME" \
  --policy-name "${VIEWER_ROLE_NAME}-policy" --policy-document file://viewer-policy.json

aws iam create-instance-profile --instance-profile-name "$VIEWER_PROFILE_NAME" 2>/dev/null || echo "Profile exists, skipping."
aws iam add-role-to-instance-profile --instance-profile-name "$VIEWER_PROFILE_NAME" \
  --role-name "$VIEWER_ROLE_NAME" 2>/dev/null || true

echo "Waiting 15s for IAM propagation..."
sleep 15

echo "== Building user-data from local lab03/ files =="
UPLOADER_APP_JS_B64=$(base64 < lab03/uploader-app/app.js | tr -d '\n')
UPLOADER_PKG_JSON_B64=$(base64 < lab03/uploader-app/package.json | tr -d '\n')

cat > user-data-uploader.sh << EOF
#!/bin/bash
dnf update -y
dnf install -y nodejs
mkdir -p /opt/app
echo "$UPLOADER_APP_JS_B64" | base64 -d > /opt/app/app.js
echo "$UPLOADER_PKG_JSON_B64" | base64 -d > /opt/app/package.json
cd /opt/app
npm install --omit=dev
cat > /etc/systemd/system/uploader.service << 'SERVICE'
[Unit]
Description=Uploader App
After=network.target

[Service]
Environment=BUCKET_NAME=$BUCKET_NAME
Environment=AWS_REGION=$AWS_REGION
Environment=PORT=3000
WorkingDirectory=/opt/app
ExecStart=/usr/bin/node /opt/app/app.js
Restart=always
User=ec2-user

[Install]
WantedBy=multi-user.target
SERVICE
chown -R ec2-user:ec2-user /opt/app
systemctl daemon-reload
systemctl enable uploader.service
systemctl start uploader.service
EOF

VIEWER_APP_JS_B64=$(base64 < lab03/viewer-app/app.js | tr -d '\n')
VIEWER_PKG_JSON_B64=$(base64 < lab03/viewer-app/package.json | tr -d '\n')

cat > user-data-viewer.sh << EOF
#!/bin/bash
dnf update -y
dnf install -y nodejs
mkdir -p /opt/app
echo "$VIEWER_APP_JS_B64" | base64 -d > /opt/app/app.js
echo "$VIEWER_PKG_JSON_B64" | base64 -d > /opt/app/package.json
cd /opt/app
npm install --omit=dev
cat > /etc/systemd/system/viewer.service << 'SERVICE'
[Unit]
Description=Viewer App
After=network.target

[Service]
Environment=BUCKET_NAME=$BUCKET_NAME
Environment=AWS_REGION=$AWS_REGION
Environment=PORT=3000
WorkingDirectory=/opt/app
ExecStart=/usr/bin/node /opt/app/app.js
Restart=always
User=ec2-user

[Install]
WantedBy=multi-user.target
SERVICE
chown -R ec2-user:ec2-user /opt/app
systemctl daemon-reload
systemctl enable viewer.service
systemctl start viewer.service
EOF

echo "== Building launch template data =="
UPLOADER_USERDATA_B64=$(base64 < user-data-uploader.sh | tr -d '\n')
VIEWER_USERDATA_B64=$(base64 < user-data-viewer.sh | tr -d '\n')

cat > uploader-lt-data.json << EOF
{
  "ImageId": "$AMI_ID",
  "InstanceType": "$INSTANCE_TYPE",
  "KeyName": "$KEY_NAME",
  "SecurityGroupIds": ["$APP_SECURITY_GROUP_ID"],
  "IamInstanceProfile": { "Name": "$UPLOADER_PROFILE_NAME" },
  "UserData": "$UPLOADER_USERDATA_B64",
  "TagSpecifications": [
    { "ResourceType": "instance", "Tags": [{ "Key": "Name", "Value": "uploader-app" }] }
  ]
}
EOF

cat > viewer-lt-data.json << EOF
{
  "ImageId": "$AMI_ID",
  "InstanceType": "$INSTANCE_TYPE",
  "KeyName": "$KEY_NAME",
  "SecurityGroupIds": ["$APP_SECURITY_GROUP_ID"],
  "IamInstanceProfile": { "Name": "$VIEWER_PROFILE_NAME" },
  "UserData": "$VIEWER_USERDATA_B64",
  "TagSpecifications": [
    { "ResourceType": "instance", "Tags": [{ "Key": "Name", "Value": "viewer-app" }] }
  ]
}
EOF

echo "== Creating/updating launch templates =="
if aws ec2 describe-launch-templates --launch-template-names "$UPLOADER_LT_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Template $UPLOADER_LT_NAME exists, publishing a new version"
  aws ec2 create-launch-template-version \
    --launch-template-name "$UPLOADER_LT_NAME" \
    --source-version 1 \
    --launch-template-data file://uploader-lt-data.json \
    --region "$AWS_REGION" > /dev/null
else
  aws ec2 create-launch-template \
    --launch-template-name "$UPLOADER_LT_NAME" \
    --launch-template-data file://uploader-lt-data.json \
    --region "$AWS_REGION" > /dev/null
fi

if aws ec2 describe-launch-templates --launch-template-names "$VIEWER_LT_NAME" --region "$AWS_REGION" >/dev/null 2>&1; then
  echo "Template $VIEWER_LT_NAME exists, publishing a new version"
  aws ec2 create-launch-template-version \
    --launch-template-name "$VIEWER_LT_NAME" \
    --source-version 1 \
    --launch-template-data file://viewer-lt-data.json \
    --region "$AWS_REGION" > /dev/null
else
  aws ec2 create-launch-template \
    --launch-template-name "$VIEWER_LT_NAME" \
    --launch-template-data file://viewer-lt-data.json \
    --region "$AWS_REGION" > /dev/null
fi

echo "== Looking up the default VPC and subnets in both AZs =="
VPC_ID=$(aws ec2 describe-vpcs \
  --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text --region "$AWS_REGION")
 
SUBNET_A=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$AZ_A" \
  --query "Subnets[0].SubnetId" --output text --region "$AWS_REGION")
 
SUBNET_B=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$AZ_B" \
  --query "Subnets[0].SubnetId" --output text --region "$AWS_REGION")
 
if [ "$SUBNET_A" = "None" ] || [ "$SUBNET_B" = "None" ] || [ -z "$SUBNET_A" ] || [ -z "$SUBNET_B" ]; then
  echo "Could not find a subnet in both $AZ_A and $AZ_B. Check Part A and fix AZ_A/AZ_B in .env."
  exit 1
fi
echo "VPC: $VPC_ID | $AZ_A: $SUBNET_A | $AZ_B: $SUBNET_B"
 
echo "== ALB security group =="
ALB_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$ALB_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" --output text --region "$AWS_REGION" 2>/dev/null || true)
 
if [ "$ALB_SECURITY_GROUP_ID" = "None" ] || [ -z "$ALB_SECURITY_GROUP_ID" ]; then
  ALB_SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name "$ALB_SG_NAME" \
    --description "Allow inbound to the ALB on the app listener ports" \
    --vpc-id "$VPC_ID" \
    --query "GroupId" --output text --region "$AWS_REGION")
  aws ec2 authorize-security-group-ingress --group-id "$ALB_SECURITY_GROUP_ID" \
    --protocol tcp --port "$UPLOADER_LISTENER_PORT" --cidr 0.0.0.0/0 --region "$AWS_REGION" >/dev/null
  aws ec2 authorize-security-group-ingress --group-id "$ALB_SECURITY_GROUP_ID" \
    --protocol tcp --port "$VIEWER_LISTENER_PORT" --cidr 0.0.0.0/0 --region "$AWS_REGION" >/dev/null
else
  echo "ALB security group already exists, skipping."
fi
 
echo "== Tightening the app security group to only accept traffic from the ALB =="
aws ec2 revoke-security-group-ingress --group-id "$APP_SECURITY_GROUP_ID" \
  --protocol tcp --port 3000 --cidr 0.0.0.0/0 --region "$AWS_REGION" >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$APP_SECURITY_GROUP_ID" \
  --protocol tcp --port 3000 --source-group "$ALB_SECURITY_GROUP_ID" --region "$AWS_REGION" >/dev/null 2>&1 || true
 
echo "== Target groups =="
UPLOADER_TG_ARN=$(aws elbv2 describe-target-groups --names "$UPLOADER_TG_NAME" --region "$AWS_REGION" \
  --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)
 
if [ "$UPLOADER_TG_ARN" = "None" ] || [ -z "$UPLOADER_TG_ARN" ]; then
  UPLOADER_TG_ARN=$(aws elbv2 create-target-group \
    --name "$UPLOADER_TG_NAME" \
    --protocol HTTP --port 3000 \
    --vpc-id "$VPC_ID" \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-path / \
    --health-check-interval-seconds 10 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 2 \
    --region "$AWS_REGION" \
    --query "TargetGroups[0].TargetGroupArn" --output text)
else
  echo "Target group $UPLOADER_TG_NAME already exists, skipping."
fi
 
VIEWER_TG_ARN=$(aws elbv2 describe-target-groups --names "$VIEWER_TG_NAME" --region "$AWS_REGION" \
  --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)
 
if [ "$VIEWER_TG_ARN" = "None" ] || [ -z "$VIEWER_TG_ARN" ]; then
  VIEWER_TG_ARN=$(aws elbv2 create-target-group \
    --name "$VIEWER_TG_NAME" \
    --protocol HTTP --port 3000 \
    --vpc-id "$VPC_ID" \
    --target-type instance \
    --health-check-protocol HTTP \
    --health-check-path / \
    --health-check-interval-seconds 10 \
    --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 \
    --unhealthy-threshold-count 2 \
    --region "$AWS_REGION" \
    --query "TargetGroups[0].TargetGroupArn" --output text)
else
  echo "Target group $VIEWER_TG_NAME already exists, skipping."
fi
 
echo "== Application Load Balancer =="
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --region "$AWS_REGION" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null || true)
 
if [ "$ALB_ARN" = "None" ] || [ -z "$ALB_ARN" ]; then
  ALB_ARN=$(aws elbv2 create-load-balancer \
    --name "$ALB_NAME" \
    --subnets "$SUBNET_A" "$SUBNET_B" \
    --security-groups "$ALB_SECURITY_GROUP_ID" \
    --scheme internet-facing \
    --type application \
    --region "$AWS_REGION" \
    --query "LoadBalancers[0].LoadBalancerArn" --output text)
  echo "Waiting for the ALB to become active..."
  aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN" --region "$AWS_REGION"
else
  echo "Load balancer $ALB_NAME already exists, skipping."
fi
 
echo "== Listeners =="
EXISTING_PORTS=$(aws elbv2 describe-listeners --load-balancer-arn "$ALB_ARN" --region "$AWS_REGION" \
  --query "Listeners[].Port" --output text 2>/dev/null || true)
 
if echo "$EXISTING_PORTS" | tr '\t' '\n' | grep -qx "$UPLOADER_LISTENER_PORT"; then
  echo "Listener on port $UPLOADER_LISTENER_PORT already exists, skipping."
else
  aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP --port "$UPLOADER_LISTENER_PORT" \
    --default-actions "Type=forward,TargetGroupArn=$UPLOADER_TG_ARN" \
    --region "$AWS_REGION" >/dev/null
fi
 
if echo "$EXISTING_PORTS" | tr '\t' '\n' | grep -qx "$VIEWER_LISTENER_PORT"; then
  echo "Listener on port $VIEWER_LISTENER_PORT already exists, skipping."
else
  aws elbv2 create-listener \
    --load-balancer-arn "$ALB_ARN" \
    --protocol HTTP --port "$VIEWER_LISTENER_PORT" \
    --default-actions "Type=forward,TargetGroupArn=$VIEWER_TG_ARN" \
    --region "$AWS_REGION" >/dev/null
fi
 
ALB_DNS_NAME=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
  --query "LoadBalancers[0].DNSName" --output text --region "$AWS_REGION")
 
echo "== Auto Scaling Groups (these launch the instances now, not run-instances) =="
EXISTING_UPLOADER_ASG=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$UPLOADER_ASG_NAME" --region "$AWS_REGION" \
  --query "AutoScalingGroups[0].AutoScalingGroupName" --output text 2>/dev/null || true)
 
if [ "$EXISTING_UPLOADER_ASG" = "None" ] || [ -z "$EXISTING_UPLOADER_ASG" ]; then
  aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "$UPLOADER_ASG_NAME" \
    --launch-template "LaunchTemplateName=$UPLOADER_LT_NAME,Version=\$Latest" \
    --min-size 1 --max-size 1 --desired-capacity 1 \
    --vpc-zone-identifier "$SUBNET_A,$SUBNET_B" \
    --target-group-arns "$UPLOADER_TG_ARN" \
    --health-check-type ELB \
    --health-check-grace-period 120 \
    --tags "ResourceId=$UPLOADER_ASG_NAME,ResourceType=auto-scaling-group,Key=Name,Value=uploader-app,PropagateAtLaunch=true" \
    --region "$AWS_REGION"
else
  echo "Auto Scaling Group $UPLOADER_ASG_NAME already exists, skipping."
fi
 
EXISTING_VIEWER_ASG=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$VIEWER_ASG_NAME" --region "$AWS_REGION" \
  --query "AutoScalingGroups[0].AutoScalingGroupName" --output text 2>/dev/null || true)
 
if [ "$EXISTING_VIEWER_ASG" = "None" ] || [ -z "$EXISTING_VIEWER_ASG" ]; then
  aws autoscaling create-auto-scaling-group \
    --auto-scaling-group-name "$VIEWER_ASG_NAME" \
    --launch-template "LaunchTemplateName=$VIEWER_LT_NAME,Version=\$Latest" \
    --min-size 1 --max-size 1 --desired-capacity 1 \
    --vpc-zone-identifier "$SUBNET_A,$SUBNET_B" \
    --target-group-arns "$VIEWER_TG_ARN" \
    --health-check-type ELB \
    --health-check-grace-period 120 \
    --tags "ResourceId=$VIEWER_ASG_NAME,ResourceType=auto-scaling-group,Key=Name,Value=viewer-app,PropagateAtLaunch=true" \
    --region "$AWS_REGION"
else
  echo "Auto Scaling Group $VIEWER_ASG_NAME already exists, skipping."
fi
 
cat > stack_outputs.env << EOF
VPC_ID=$VPC_ID
SUBNET_A=$SUBNET_A
SUBNET_B=$SUBNET_B
ALB_SECURITY_GROUP_ID=$ALB_SECURITY_GROUP_ID
ALB_ARN=$ALB_ARN
ALB_DNS_NAME=$ALB_DNS_NAME
UPLOADER_TG_ARN=$UPLOADER_TG_ARN
VIEWER_TG_ARN=$VIEWER_TG_ARN
EOF
 
echo "Done. ALB DNS name: $ALB_DNS_NAME"
echo "Uploader: http://$ALB_DNS_NAME:$UPLOADER_LISTENER_PORT/"
echo "Viewer:   http://$ALB_DNS_NAME:$VIEWER_LISTENER_PORT/"
echo "Give the target groups 1-2 minutes to report healthy. Check with:"
echo "  aws elbv2 describe-target-health --target-group-arn $UPLOADER_TG_ARN --region $AWS_REGION"