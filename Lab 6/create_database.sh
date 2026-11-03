#!/bin/bash
set -euo pipefail

export $(grep -v '^#' .env | xargs)
export AWS_DEFAULT_REGION="$AWS_REGION"   # lets us skip --region on every call

echo "== 1. Default VPC and subnets in both AZs =="
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text)
SUBNET_A=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$AZ_A" \
  --query "Subnets[0].SubnetId" --output text)
SUBNET_B=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" "Name=availability-zone,Values=$AZ_B" \
  --query "Subnets[0].SubnetId" --output text)

echo "== 2. Database security group (port 5432, from the app security group only) =="
DB_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$DB_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
if [ -z "$DB_SECURITY_GROUP_ID" ] || [ "$DB_SECURITY_GROUP_ID" = "None" ]; then
  DB_SECURITY_GROUP_ID=$(aws ec2 create-security-group \
    --group-name "$DB_SG_NAME" \
    --description "PostgreSQL access from the lab app instances only" \
    --vpc-id "$VPC_ID" --query "GroupId" --output text)
  aws ec2 authorize-security-group-ingress --group-id "$DB_SECURITY_GROUP_ID" \
    --protocol tcp --port 5432 --source-group "$APP_SECURITY_GROUP_ID" >/dev/null
else
  echo "Database security group already exists, skipping."
fi

echo "== 3. DB subnet group =="
aws rds create-db-subnet-group \
  --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
  --db-subnet-group-description "Lab subnets for the weather database" \
  --subnet-ids "$SUBNET_A" "$SUBNET_B" >/dev/null 2>&1 || echo "DB subnet group already exists, skipping."

echo "== 4. Database password (random, stored as a SecureString, never printed) =="
if ! aws ssm get-parameter --name "$DB_PASSWORD_PARAM" >/dev/null 2>&1; then
  aws ssm put-parameter --name "$DB_PASSWORD_PARAM" --type SecureString \
    --value "$(openssl rand -hex 16)" >/dev/null
else
  echo "Password parameter already exists, keeping it."
fi
DB_PASSWORD=$(aws ssm get-parameter --name "$DB_PASSWORD_PARAM" --with-decryption \
  --query Parameter.Value --output text)

echo "== 5. The PostgreSQL instance (free tier size, no backups) =="
if aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" >/dev/null 2>&1; then
  echo "Database $DB_INSTANCE_ID already exists, skipping."
else
  aws rds create-db-instance \
    --db-instance-identifier "$DB_INSTANCE_ID" \
    --db-instance-class db.t4g.micro \
    --engine postgres \
    --allocated-storage 20 --storage-type gp2 \
    --master-username "$DB_USER" --master-user-password "$DB_PASSWORD" \
    --db-name "$DB_NAME" \
    --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" \
    --vpc-security-group-ids "$DB_SECURITY_GROUP_ID" \
    --availability-zone "$AZ_A" \
    --backup-retention-period 0 \
    --no-multi-az \
    --no-publicly-accessible \
    --no-auto-minor-version-upgrade \
    --no-deletion-protection \
    --storage-encrypted >/dev/null
fi
unset DB_PASSWORD

echo "Waiting for the database to become available (usually 5 to 10 minutes)..."
aws rds wait db-instance-available --db-instance-identifier "$DB_INSTANCE_ID"

DB_HOST=$(aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" \
  --query "DBInstances[0].Endpoint.Address" --output text)

cat > db_outputs.env << EOF
DB_HOST=$DB_HOST
DB_SECURITY_GROUP_ID=$DB_SECURITY_GROUP_ID
EOF

echo
echo "Done. Database endpoint: $DB_HOST"
echo "Automated backups are OFF (retention 0) and no final snapshot will be taken on delete."
echo "Next: ./create_weather_stack.sh. When testing is finished: ./delete_weather_stack.sh then ./delete_database.sh"