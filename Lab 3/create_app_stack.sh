#!/bin/bash
set -e
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

echo "== Launching instances from the templates =="
UPLOADER_ID=$(aws ec2 run-instances \
  --launch-template "LaunchTemplateName=$UPLOADER_LT_NAME,Version=\$Latest" \
  --count 1 \
  --region "$AWS_REGION" \
  --query "Instances[0].InstanceId" --output text)

VIEWER_ID=$(aws ec2 run-instances \
  --launch-template "LaunchTemplateName=$VIEWER_LT_NAME,Version=\$Latest" \
  --count 1 \
  --region "$AWS_REGION" \
  --query "Instances[0].InstanceId" --output text)

echo "$UPLOADER_ID" > uploader_instance_id.txt
echo "$VIEWER_ID" > viewer_instance_id.txt

echo "Waiting for both instances to reach 'running'..."
aws ec2 wait instance-running --instance-ids "$UPLOADER_ID" "$VIEWER_ID" --region "$AWS_REGION"

aws ec2 describe-instances --instance-ids "$UPLOADER_ID" "$VIEWER_ID" \
  --query "Reservations[*].Instances[*].[Tags[?Key=='Name'].Value|[0],PublicIpAddress]" \
  --output table --region "$AWS_REGION"

echo "Instances are running. Give them ~60-90s to finish installing Node.js before browsing to :3000."