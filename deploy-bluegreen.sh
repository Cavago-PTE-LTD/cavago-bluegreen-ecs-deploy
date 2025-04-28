#!/bin/bash
set -e

# Input parameters
ENVIRONMENT="$1"
IMAGE_TAG="$2"
ECR_URI="$3"
CLUSTER_NAME="$4"
TASK_DEF_NAME="$5"
LISTENER_ARN="$6"
TG_A_NAME="$7"
TG_B_NAME="$8"
SVC_A_NAME="$9"
SVC_B_NAME="${10}"
CONTAINER_NAME="${11}"

NEW_IMAGE="$ECR_URI:$IMAGE_TAG"

echo "🔄 Starting A/B deployment for environment: $ENVIRONMENT"
echo "🖼️  Deploying image tag: $IMAGE_TAG"
echo "🔑 Using ECR URI: $ECR_URI"
echo "🔑 Using cluster name: $CLUSTER_NAME"
echo "🔑 Using task definition name: $TASK_DEF_NAME"
echo "🔑 Using listener ARN: $LISTENER_ARN"
echo "🔑 Using target group A name: $TG_A_NAME"
echo "🔑 Using target group B name: $TG_B_NAME"
echo "🔑 Using service A name: $SVC_A_NAME"
echo "🔑 Using service B name: $SVC_B_NAME"
echo "🔑 Using container name: $CONTAINER_NAME"
# Determine active and idle services
ACTIVE_TG_ARN=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" \
  --query "Rules[?Priority=='1'].Actions[0].TargetGroupArn" --output text)

TG_A_ARN=$(aws elbv2 describe-target-groups --names "$TG_A_NAME" \
  --query "TargetGroups[0].TargetGroupArn" --output text)
TG_B_ARN=$(aws elbv2 describe-target-groups --names "$TG_B_NAME" \
  --query "TargetGroups[0].TargetGroupArn" --output text)

if [ "$ACTIVE_TG_ARN" == "$TG_A_ARN" ]; then
  echo "✅ A is active. Deploying to B."
  ACTIVE_SVC="$SVC_A_NAME"
  IDLE_SVC="$SVC_B_NAME"
  IDLE_TG_ARN="$TG_B_ARN"
elif [ "$ACTIVE_TG_ARN" == "$TG_B_ARN" ]; then
  echo "✅ B is active. Deploying to A."
  ACTIVE_SVC="$SVC_B_NAME"
  IDLE_SVC="$SVC_A_NAME"
  IDLE_TG_ARN="$TG_A_ARN"
else
  echo "❌ Unable to determine active target group."
  exit 1
fi

echo "📥 Fetching current task definition for: $TASK_DEF_NAME"
aws ecs describe-task-definition --task-definition "$TASK_DEF_NAME" > task-def.json

echo "🛠 Updating task definition with new image: $NEW_IMAGE"
UPDATED_TASK_DEF=$(jq --arg IMAGE "$NEW_IMAGE" \
  --arg CONTAINER "$CONTAINER_NAME" \
  '.taskDefinition |
   del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy) |
   .containerDefinitions |= map(if .name == $CONTAINER then .image = $IMAGE else . end)' \
   task-def.json)

echo "$UPDATED_TASK_DEF" > new-task-def.json

echo "📤 Registering new task definition..."
NEW_TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json file://new-task-def.json \
  --query "taskDefinition.taskDefinitionArn" \
  --output text)

# Update idle service to new image
echo "🚀 Updating ECS service to use new task definition..."
aws ecs update-service \
  --cluster "$CLUSTER_NAME" \
  --service "$IDLE_SVC" \
  --task-definition "$NEW_TASK_DEF_ARN" \
  --force-new-deployment

# Wait for the new service to become healthy
echo "⏳ Waiting for $IDLE_SVC to stabilize..."
aws ecs wait services-stable \
  --cluster "$CLUSTER_NAME" \
  --services "$IDLE_SVC"

# Get the rule ARN
echo "🔑 Getting rule ARN for listener: $LISTENER_ARN"
RULE_ARN=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" --query "Rules[?Priority=='1'].RuleArn" --output text)

# Switch ALB rule to point to new target group
echo "🔁 Switching ALB to new target group my modifying the rule: $RULE_ARN"
aws elbv2 modify-rule \  
  --rule-arn "$RULE_ARN" \
  --conditions Field=path-pattern,Values="/" \
  --actions Type=forward,TargetGroupArn="$IDLE_TG_ARN"

# Optionally, scale down the old service
# echo "🧹 (Optional) Scaling down old service: $ACTIVE_SVC"
# aws ecs update-service --cluster "$CLUSTER_NAME" --service "$ACTIVE_SVC" --desired-count 0

echo "✅ A/B deployment complete!"
