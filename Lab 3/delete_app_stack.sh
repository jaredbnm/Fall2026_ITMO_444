#!/bin/bash
set -e
export $(grep -v '^#' .env | xargs)
if [[ -f uploader_instance_id.txt && -f viewer_instance_id.txt ]]; then
UPLOADER_ID=$(cat uploader_instance_id.txt)
VIEWER_ID=$(cat viewer_instance_id.txt)
echo "Terminating instances: $UPLOADER_ID $VIEWER_ID"
aws ec2 terminate-instances --instance-ids "$UPLOADER_ID" "$VIEWER_ID" --region "$AWS_REGION"
aws ec2 wait instance-terminated --instance-ids "$UPLOADER_ID" "$VIEWER_ID" --region "$AWS_REGION"
echo "Instances terminated."
rm -f uploader_instance_id.txt viewer_instance_id.txt
else
echo "No instance ID files found — skipping instance termination."
fi
echo "== Deleting launch templates =="
aws ec2 delete-launch-template --launch-template-name "$UPLOADER_LT_NAME" --region "$AWS_REGION" 2>/dev/null
|| true
aws ec2 delete-launch-template --launch-template-name "$VIEWER_LT_NAME" --region "$AWS_REGION" 2>/dev/null
true
echo "== Removing IAM instance profiles and roles =="
aws iam remove-role-from-instance-profile --instance-profile-name "$UPLOADER_PROFILE_NAME" \
--role-name "$UPLOADER_ROLE_NAME" 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name "$UPLOADER_PROFILE_NAME" 2>/dev/null || true
aws iam delete-role-policy --role-name "$UPLOADER_ROLE_NAME" \
--policy-name "${UPLOADER_ROLE_NAME}-policy" 2>/dev/null || true
aws iam delete-role --role-name "$UPLOADER_ROLE_NAME" 2>/dev/null || true
aws iam remove-role-from-instance-profile --instance-profile-name "$VIEWER_PROFILE_NAME" \
--role-name "$VIEWER_ROLE_NAME" 2>/dev/null || true
aws iam delete-instance-profile --instance-profile-name "$VIEWER_PROFILE_NAME" 2>/dev/null || true
aws iam delete-role-policy --role-name "$VIEWER_ROLE_NAME" \
--policy-name "${VIEWER_ROLE_NAME}-policy" 2>/dev/null || true
aws iam delete-role --role-name "$VIEWER_ROLE_NAME" 2>/dev/null || true
echo "== Emptying and deleting S3 bucket =="
aws s3 rm "s3://$BUCKET_NAME" --recursive --region "$AWS_REGION" 2>/dev/null || true
aws s3api delete-bucket --bucket "$BUCKET_NAME" --region "$AWS_REGION" 2>/dev/null || true
echo "Cleanup complete."