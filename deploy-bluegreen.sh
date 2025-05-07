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
SUBDOMAIN="${12}"

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
echo "🔑 Using subdomain: $SUBDOMAIN"

# Determine active and idle services
RULES=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" --output json)

BLUE_RULE_ARN=$(echo "$RULES" | jq -r --arg subdomain "$SUBDOMAIN" '
  .Rules[] 
  | select(
      (.Conditions | any(.Field == "path-pattern" and (.Values // [] | index("/*")))) and
      (.Conditions | any(.Field == "host-header" and (.Values // [] | index($subdomain))))
    )
  | .RuleArn
')

GREEN_RULE_ARN=$(echo "$RULES" | jq -r --arg subdomain "$SUBDOMAIN" '
  .Rules[] 
  | select(
      (.Conditions | any(.Field == "path-pattern" and (.Values // [] | index("/green/*")))) and
      (.Conditions | any(.Field == "host-header" and (.Values // [] | index($subdomain))))
    )
  | .RuleArn
')

BLUE_TG_ARN=$(echo "$RULES" | jq -r --arg subdomain "$SUBDOMAIN" '
  .Rules[] 
  | select(
      (.Conditions | any(.Field == "path-pattern" and (.Values // [] | index("/*")))) and
      (.Conditions | any(.Field == "host-header" and (.Values // [] | index($subdomain))))
    )
  | .Actions[] 
  | select(.Type == "forward") 
  | .TargetGroupArn
')


TG_A_ARN=$(aws elbv2 describe-target-groups --names "$TG_A_NAME" \
  --query "TargetGroups[0].TargetGroupArn" --output text)
TG_B_ARN=$(aws elbv2 describe-target-groups --names "$TG_B_NAME" \
  --query "TargetGroups[0].TargetGroupArn" --output text)

if [ "$BLUE_TG_ARN" == "$TG_A_ARN" ]; then
  echo "✅ A is active. Deploying to B."
  BLUE_SVC="$SVC_A_NAME"
  GREEN_SVC="$SVC_B_NAME"
  GREEN_TG_ARN="$TG_B_ARN"
elif [ "$BLUE_TG_ARN" == "$TG_B_ARN" ]; then
  echo "✅ B is active. Deploying to A."
  BLUE_SVC="$SVC_B_NAME"
  GREEN_SVC="$SVC_A_NAME"
  GREEN_TG_ARN="$TG_A_ARN"
else
  echo "❌ Unable to determine active target group."
  exit 1
fi

echo "📥 Fetching current task definition for: $TASK_DEF_NAME"
aws ecs describe-task-definition --task-definition "$TASK_DEF_NAME" > task-def.json

echo "📦 Existing container names:"
jq '.taskDefinition.containerDefinitions[].name' task-def.json

# Update only the container you care about
UPDATED_TASK_DEF=$(jq --arg IMAGE "$NEW_IMAGE" --arg CONTAINER "$CONTAINER_NAME" '
  .taskDefinition
  | del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy)
  | .containerDefinitions = [
      (.containerDefinitions[] | select(.name == $CONTAINER) | .image = $IMAGE)
    ]
' task-def.json)

echo "$UPDATED_TASK_DEF" > new-task-def.json

echo "📤 Registering new task definition..."
NEW_TASK_DEF_ARN=$(aws ecs register-task-definition \
  --cli-input-json file://new-task-def.json \
  --query "taskDefinition.taskDefinitionArn" \
  --output text)

# Update idle service to new image
echo "🚀 Updating ECS service to use new task definition: $NEW_TASK_DEF_ARN"
aws ecs update-service \
  --cluster "$CLUSTER_NAME" \
  --service "$GREEN_SVC" \
  --task-definition "$NEW_TASK_DEF_ARN" \
  --desired-count 1 \
  --force-new-deployment

# Wait for the new service to become healthy
echo "⏳ Waiting for $GREEN_SVC to stabilize..."
aws ecs wait services-stable \
  --cluster "$CLUSTER_NAME" \
  --services "$GREEN_SVC"

echo "🎯 Blue active TG ARN: $BLUE_TG_ARN"
echo "🎯 Blue Rule ARN: $BLUE_RULE_ARN"
echo "🎯 Green Rule ARN (if exists): $GREEN_RULE_ARN"

# Update current active rule: demote to /green/*
echo "🔧 Updating blue rule to /green/*"
aws elbv2 modify-rule \
  --rule-arn "$BLUE_RULE_ARN" \
  --conditions "Field=host-header,Values=$SUBDOMAIN" "Field=path-pattern,Values="/green/*"  

# Update green rule (new deployment): promote to /* 
echo "🔧 Updating green rule to /*"
aws elbv2 modify-rule \
  --rule-arn "$GREEN_RULE_ARN" \
  --conditions "Field=host-header,Values=$SUBDOMAIN" "Field=path-pattern,Values="/*"  

echo "✅ ALB path patterns and priorities updated!"

# Optionally, scale down the old service
echo "🧹 Scaling down old service: $ACTIVE_SVC"
aws ecs update-service --cluster "$CLUSTER_NAME" --service "$BLUE_SVC" --desired-count 0

echo "✅ A/B deployment complete!"
