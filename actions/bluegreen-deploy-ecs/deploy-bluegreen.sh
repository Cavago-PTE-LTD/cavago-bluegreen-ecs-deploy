#!/bin/bash
set -e

# Input parameters
ENVIRONMENT="$1"
IMAGE_TAG="$2"
CLUSTER_NAME="$3"
LISTENER_ARN="$4"
TG_A_NAME="$5"
TG_B_NAME="$6"
SVC_A="$7"
SVC_B="$8"

echo "🔄 Starting A/B deployment for environment: $ENVIRONMENT"
echo "🖼️  Deploying image tag: $IMAGE_TAG"

# Determine active and idle services
ACTIVE_TG_ARN=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
  --query "Rules[?Priority=='1'].Actions[0].TargetGroupArn" --output text)

TG_ARN_A=$(aws elbv2 describe-target-groups --names "$TG_A_NAME" \
  --query "TargetGroups[0].TargetGroupArn" --output text)
TG_ARN_B=$(aws elbv2 describe-target-groups --names "$TG_B_NAME" \
  --query "TargetGroups[0].TargetGroupArn" --output text)

if [ "$ACTIVE_TG_ARN" == "$TG_ARN_A" ]; then
  echo "✅ A is active. Deploying to B."
  ACTIVE_SVC="$SVC_A"
  IDLE_SVC="$SVC_B"
  IDLE_TG_ARN="$TG_ARN_B"
elif [ "$ACTIVE_TG_ARN" == "$TG_ARN_B" ]; then
  echo "✅ B is active. Deploying to A."
  ACTIVE_SVC="$SVC_B"
  IDLE_SVC="$SVC_A"
  IDLE_TG_ARN="$TG_ARN_A"
else
  echo "❌ Unable to determine active target group."
  exit 1
fi

# Update idle service to new image
echo "🚀 Updating $IDLE_SVC to image tag $IMAGE_TAG..."
aws ecs update-service \
  --cluster "$CLUSTER_NAME" \
  --service "$IDLE_SVC" \
  --force-new-deployment \
  --output text

# Wait for the new service to become healthy
echo "⏳ Waiting for $IDLE_SVC to stabilize..."
aws ecs wait services-stable \
  --cluster "$CLUSTER_NAME" \
  --services "$IDLE_SVC"

# Switch ALB rule to point to new target group
echo "🔁 Switching ALB to new target group..."
aws elbv2 modify-rule \
  --listener-arn "$LISTENER_ARN" \
  --conditions Field=path-pattern,Values="/" \
  --actions Type=forward,TargetGroupArn="$IDLE_TG_ARN" \
  --rule-arn $(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
    --query "Rules[?Priority=='1'].RuleArn" --output text)

# Optionally, scale down the old service
# echo "🧹 (Optional) Scaling down old service: $ACTIVE_SVC"
# aws ecs update-service --cluster "$CLUSTER_NAME" --service "$ACTIVE_SVC" --desired-count 0

echo "✅ A/B deployment complete!"
