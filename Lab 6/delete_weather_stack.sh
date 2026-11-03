#!/bin/bash
set -uo pipefail

export $(grep -v '^#' .env | xargs)
export AWS_DEFAULT_REGION="$AWS_REGION"
[ -f stack_outputs.env ] && export $(grep -v '^#' stack_outputs.env | xargs)

echo "== Deleting Auto Scaling Groups (this also terminates their instances) =="
for ASG in "$WEATHER_ASG_NAME" "$ADVISOR_ASG_NAME"; do
  aws autoscaling delete-auto-scaling-group --auto-scaling-group-name "$ASG" --force-delete 2>/dev/null || true
done
for ASG in "$WEATHER_ASG_NAME" "$ADVISOR_ASG_NAME"; do
  for i in $(seq 1 20); do
    EXISTING=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
      --query "AutoScalingGroups[0].AutoScalingGroupName" --output text 2>/dev/null || true)
    if [ -z "$EXISTING" ] || [ "$EXISTING" = "None" ]; then
      echo "$ASG deleted."
      break
    fi
    sleep 15
  done
done

echo "== Deleting the load balancer and target groups =="
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
  --query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null || true)
if [ -n "$ALB_ARN" ] && [ "$ALB_ARN" != "None" ]; then
  aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" || true
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" 2>/dev/null || true
fi
for TG in "$WEATHER_TG_NAME" "$ADVISOR_TG_NAME"; do
  TG_ARN=$(aws elbv2 describe-target-groups --names "$TG" \
    --query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)
  if [ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ]; then
    aws elbv2 delete-target-group --target-group-arn "$TG_ARN" || true
  fi
done

echo "== Restoring the app security group and deleting the ALB security group =="
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
  --query "Vpcs[0].VpcId" --output text)
ALB_SG=$(aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=$ALB_SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query "SecurityGroups[0].GroupId" --output text 2>/dev/null || true)
if [ -n "$ALB_SG" ] && [ "$ALB_SG" != "None" ]; then
  aws ec2 revoke-security-group-ingress --group-id "$APP_SECURITY_GROUP_ID" \
    --protocol tcp --port 3000 --source-group "$ALB_SG" >/dev/null 2>&1 || true
fi
aws ec2 authorize-security-group-ingress --group-id "$APP_SECURITY_GROUP_ID" \
  --protocol tcp --port 3000 --cidr 0.0.0.0/0 >/dev/null 2>&1 || true
if [ -n "$ALB_SG" ] && [ "$ALB_SG" != "None" ]; then
  for i in $(seq 1 10); do
    if aws ec2 delete-security-group --group-id "$ALB_SG" 2>/dev/null; then
      echo "ALB security group deleted."
      break
    fi
    echo "ALB network interfaces still releasing, waiting 15s..."
    sleep 15
  done
fi

echo "== Deleting launch templates =="
aws ec2 delete-launch-template --launch-template-name "$WEATHER_LT_NAME" >/dev/null 2>&1 || true
aws ec2 delete-launch-template --launch-template-name "$ADVISOR_LT_NAME" >/dev/null 2>&1 || true

echo "== Removing IAM instance profiles and roles =="
for PAIR in "$WEATHER_ROLE_NAME:$WEATHER_PROFILE_NAME" "$ADVISOR_ROLE_NAME:$ADVISOR_PROFILE_NAME"; do
  ROLE="${PAIR%%:*}"; PROFILE="${PAIR#*:}"
  aws iam remove-role-from-instance-profile --instance-profile-name "$PROFILE" --role-name "$ROLE" 2>/dev/null || true
  aws iam delete-instance-profile --instance-profile-name "$PROFILE" 2>/dev/null || true
  aws iam delete-role-policy --role-name "$ROLE" --policy-name "${ROLE}-policy" 2>/dev/null || true
  aws iam delete-role --role-name "$ROLE" 2>/dev/null || true
done

rm -f stack_outputs.env
echo "Weather stack removed. Your Gemini API key parameter was left in place (the last step of the experiments shows how to delete it)."