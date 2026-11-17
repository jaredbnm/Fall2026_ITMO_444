#!/bin/bash
set -e
export AWS_PAGER=""  # keep the AWS CLI from pausing in `less` on JSON output
export $(grep -v '^#' .env | xargs)
[ -f stack_outputs.env ] && export $(grep -v '^#' stack_outputs.env | xargs)

# Look up anything stack_outputs.env didn't give us by name, so a missing/stale file
# (e.g. after a half-finished earlier run) doesn't leave resources behind.
if [ -z "$ALB_ARN" ]; then
	ALB_ARN=$(aws elbv2 describe-load-balancers --names "$ALB_NAME" --region "$AWS_REGION" \
		--query "LoadBalancers[0].LoadBalancerArn" --output text 2>/dev/null || true)
fi
if [ -z "$UPLOADER_TG_ARN" ]; then
	UPLOADER_TG_ARN=$(aws elbv2 describe-target-groups --names "$UPLOADER_TG_NAME" --region "$AWS_REGION" \
		--query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)
fi
if [ -z "$VIEWER_TG_ARN" ]; then
	VIEWER_TG_ARN=$(aws elbv2 describe-target-groups --names "$VIEWER_TG_NAME" --region "$AWS_REGION" \
		--query "TargetGroups[0].TargetGroupArn" --output text 2>/dev/null || true)
fi
if [ -z "$ALB_SECURITY_GROUP_ID" ]; then
	ALB_SECURITY_GROUP_ID=$(aws ec2 describe-security-groups \
		--filters "Name=group-name,Values=$ALB_SG_NAME" \
		--query "SecurityGroups[0].GroupId" --output text --region "$AWS_REGION" 2>/dev/null || true)
fi

# --- New: tear down the ALB/ASG/multi-AZ layer first ---
echo "== Deleting Auto Scaling Groups (this also terminates their instances) =="
aws autoscaling delete-auto-scaling-group \
	--auto-scaling-group-name "$UPLOADER_ASG_NAME" --force-delete --region "$AWS_REGION" 2>/dev/null || true
aws autoscaling delete-auto-scaling-group \
	--auto-scaling-group-name "$VIEWER_ASG_NAME" --force-delete --region "$AWS_REGION" 2>/dev/null || true

echo "Waiting for both Auto Scaling Groups to be gone..."
for ASG_NAME in "$UPLOADER_ASG_NAME" "$VIEWER_ASG_NAME"; do
	for i in $(seq 1 20); do
		EXISTING=$(aws autoscaling describe-auto-scaling-groups \
			--auto-scaling-group-names "$ASG_NAME" --region "$AWS_REGION" \
			--query "AutoScalingGroups[0].AutoScalingGroupName" --output text 2>/dev/null || true)
		if [ "$EXISTING" = "None" ] || [ -z "$EXISTING" ]; then
			echo "$ASG_NAME deleted."
			break
		fi
		if [ "$i" = "20" ]; then
			echo "WARNING: $ASG_NAME still exists after 5 minutes. Check the EC2 > Auto Scaling Groups console."
		fi
		sleep 15
	done
done

echo "== Deleting the load balancer =="
if [ "$ALB_ARN" != "None" ] && [ -n "$ALB_ARN" ]; then
	aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN" --region "$AWS_REGION" 2>/dev/null || true
	aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB_ARN" --region "$AWS_REGION" 2>/dev/null || true
fi

echo "== Deleting target groups =="
aws elbv2 delete-target-group --target-group-arn "$UPLOADER_TG_ARN" --region "$AWS_REGION" 2>/dev/null || true
aws elbv2 delete-target-group --target-group-arn "$VIEWER_TG_ARN" --region "$AWS_REGION" 2>/dev/null || true

echo "== Restoring the app security group to its previous-lab state =="
aws ec2 revoke-security-group-ingress --group-id "$APP_SECURITY_GROUP_ID" \
	--protocol tcp --port 3000 --source-group "$ALB_SECURITY_GROUP_ID" --region "$AWS_REGION" >/dev/null 2>&1 || true
aws ec2 authorize-security-group-ingress --group-id "$APP_SECURITY_GROUP_ID" \
	--protocol tcp --port 3000 --cidr 0.0.0.0/0 --region "$AWS_REGION" >/dev/null 2>&1 || true

echo "== Deleting the ALB security group =="
# The ALB's network interfaces can linger for a minute after it's deleted, so retry.
if [ "$ALB_SECURITY_GROUP_ID" != "None" ] && [ -n "$ALB_SECURITY_GROUP_ID" ]; then
	for i in $(seq 1 12); do
		if aws ec2 delete-security-group --group-id "$ALB_SECURITY_GROUP_ID" --region "$AWS_REGION" 2>/dev/null; then
			echo "$ALB_SG_NAME deleted."
			break
		fi
		if [ "$i" = "12" ]; then
			echo "WARNING: could not delete $ALB_SG_NAME. Wait a minute and re-run this script."
		fi
		sleep 10
	done
fi

rm -f stack_outputs.env uploader-lt-data.json viewer-lt-data.json user-data-uploader.sh user-data-viewer.sh \
	uploader-policy.json viewer-policy.json trust-policy.json

# --- Unchanged from the previous lab: bucket + IAM teardown ---
echo "== Removing IAM instance profiles and roles =="
aws iam remove-role-from-instance-profile --instance-profile-name "$UPLOADER_PROFILE_NAME" \
	--role-name "$UPLOADER_ROLE_NAME" 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name "$UPLOADER_PROFILE_NAME" 2>/dev/null || true
# Delete every inline policy, not just ours — any leftover one blocks delete-role.
for POLICY in $(aws iam list-role-policies --role-name "$UPLOADER_ROLE_NAME" \
	--query "PolicyNames[]" --output text 2>/dev/null || true); do
	aws iam delete-role-policy --role-name "$UPLOADER_ROLE_NAME" --policy-name "$POLICY" 2>/dev/null || true
done
aws iam delete-role --role-name "$UPLOADER_ROLE_NAME" 2>/dev/null || true

aws iam remove-role-from-instance-profile --instance-profile-name "$VIEWER_PROFILE_NAME" \
	--role-name "$VIEWER_ROLE_NAME" 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name "$VIEWER_PROFILE_NAME" 2>/dev/null || true
for POLICY in $(aws iam list-role-policies --role-name "$VIEWER_ROLE_NAME" \
	--query "PolicyNames[]" --output text 2>/dev/null || true); do
	aws iam delete-role-policy --role-name "$VIEWER_ROLE_NAME" --policy-name "$POLICY" 2>/dev/null || true
done
aws iam delete-role --role-name "$VIEWER_ROLE_NAME" 2>/dev/null || true

echo "== Emptying and deleting S3 bucket =="
aws s3 rm "s3://$BUCKET_NAME" --recursive --region "$AWS_REGION" 2>/dev/null || true
aws s3api delete-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null || true

echo "Cleanup complete."
