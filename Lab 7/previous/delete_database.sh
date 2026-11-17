#!/bin/bash
set -uo pipefail

export $(grep -v '^#' .env | xargs)
export AWS_DEFAULT_REGION="$AWS_REGION"

echo "== Deleting the database (no final snapshot, no kept backups) =="
if aws rds describe-db-instances --db-instance-identifier "$DB_INSTANCE_ID" >/dev/null 2>&1; then
  aws rds delete-db-instance --db-instance-identifier "$DB_INSTANCE_ID" \
    --skip-final-snapshot --delete-automated-backups >/dev/null
  echo "Waiting for the database to be deleted (a few minutes)..."
  aws rds wait db-instance-deleted --db-instance-identifier "$DB_INSTANCE_ID"
else
  echo "Database $DB_INSTANCE_ID not found, nothing to delete."
fi

echo "== Deleting the DB subnet group =="
aws rds delete-db-subnet-group --db-subnet-group-name "$DB_SUBNET_GROUP_NAME" 2>/dev/null || true

echo "== Deleting the database security group =="
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text)
DB_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$DB_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
if [ -n "$DB_SG" ] && [ "$DB_SG" != "None" ]; then
  for i in $(seq 1 10); do
    if aws ec2 delete-security-group --group-id "$DB_SG" 2>/dev/null; then
      echo "Database security group deleted."
      break
    fi
    echo "Still releasing, waiting 15s..."
    sleep 15
  done
fi

echo "== Deleting the database password parameter =="
aws ssm delete-parameter --name "$DB_PASSWORD_PARAM" 2>/dev/null || true

rm -f db_outputs.env
echo "Database removed. Run the checks in the last experiment step to confirm no snapshots or backups remain."