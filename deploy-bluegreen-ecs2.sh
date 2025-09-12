#!/bin/bash
set -e

# Debug: Print all arguments
echo "Number of arguments: $#"
echo "Arguments received:"
for ((i=1; i<=$#; i++)); do
    echo "Argument $i: ${!i}"
done

# Input parameters
APP_NAME="$1"
ENVIRONMENT="$2"
CLUSTER_NAME="$3"
TASK_DEF_ARN="$4"
SERVICE_A_NAME="$5"
SERVICE_B_NAME="$6"
SUBDOMAIN="$7"
DESIRED_COUNT="$8"
OLD_SUBDOMAIN="$9"

echo "🔑 Starting A/B deployment for application: $APP_NAME"
echo "🔑 Starting A/B deployment for environment: $ENVIRONMENT"
echo "🔑 Using cluster name: $CLUSTER_NAME"
echo "🔑 Using task definition name: $TASK_DEF_ARN"

echo "🔑 Using service A name: $SERVICE_A_NAME"
echo "🔑 Using service B name: $SERVICE_B_NAME"
echo "🔑 Using subdomain: $SUBDOMAIN"
echo "🔑 Using desired count: $DESIRED_COUNT"
echo "🔑 Using old subdomain: $OLD_SUBDOMAIN"

# Construct target group names
TARGET_GROUP_A_NAME="${APP_NAME}-${ENVIRONMENT}-tg-A"
TARGET_GROUP_B_NAME="${APP_NAME}-${ENVIRONMENT}-tg-B"

echo "🔑 Target Group A Name: $TARGET_GROUP_A_NAME"
echo "🔑 Target Group B Name: $TARGET_GROUP_B_NAME"

# Look up target group ARNs by name
TARGET_A_ARN=$(aws elbv2 describe-target-groups \
  --names "$TARGET_GROUP_A_NAME" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)

TARGET_B_ARN=$(aws elbv2 describe-target-groups \
  --names "$TARGET_GROUP_B_NAME" \
  --query "TargetGroups[0].TargetGroupArn" \
  --output text)

echo "✅ Target Group A ARN: $TARGET_A_ARN"
echo "✅ Target Group B ARN: $TARGET_B_ARN"

TAGS_A=$(aws elbv2 list-tags --resource-arns "$TARGET_A_ARN" --query "TagDescriptions[0].Tags")
TAGS_B=$(aws elbv2 list-tags --resource-arns "$TARGET_B_ARN" --query "TagDescriptions[0].Tags")

# Extract "deployment" tag (assuming you tag TGs with deployment=blue|green)
COLOR_A=$(echo "$TAGS_A" | jq -r '.[] | select(.Key=="Deployment") | .Value')
COLOR_B=$(echo "$TAGS_B" | jq -r '.[] | select(.Key=="Deployment") | .Value')

if [ "$COLOR_A" == "blue" ] || [ "$COLOR_B" == "green" ]; then
  echo "✅ Service A is BLUE (active). Deploying to Service B."
  BLUE_SVC="$SERVICE_A_NAME"
  GREEN_SVC="$SERVICE_B_NAME"
  BLUE_TG_ARN="$TARGET_A_ARN"
  GREEN_TG_ARN="$TARGET_B_ARN"
elif [ "$COLOR_B" == "blue" ] || [ "$COLOR_A" == "green" ]; then
  echo "✅ Service B is BLUE (active). Deploying to Service A."
  BLUE_SVC="$SERVICE_B_NAME"
  GREEN_SVC="$SERVICE_A_NAME"
  BLUE_TG_ARN="$TARGET_B_ARN"
  GREEN_TG_ARN="$TARGET_A_ARN"
else  
  echo "✅ Could not determine active (blue) target group. Deploying to Service A."
  BLUE_SVC="$SERVICE_B_NAME"
  GREEN_SVC="$SERVICE_A_NAME"
  BLUE_TG_ARN="$TARGET_B_ARN"
  GREEN_TG_ARN="$TARGET_A_ARN"  
fi

LOAD_BALANCER_ARN=$(aws elbv2 describe-target-groups \
  --target-group-arns "$TARGET_A_ARN" \
  --query "TargetGroups[0].LoadBalancerArns[0]" \
  --output text)

echo "🔑 Using load balancer ARN: $LOAD_BALANCER_ARN"

LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$LOAD_BALANCER_ARN" \
  --query "Listeners[?Protocol==\`HTTPS\`].ListenerArn" \
  --output text)

echo "🔑 Using listener ARN: $LISTENER_ARN"

# Determine active and idle services
RULES=$(aws elbv2 describe-rules --listener-arn "$LISTENER_ARN" --output json)

# Find rule ARNs associated with Target A and B
RULE_A_ARN=$(echo "$RULES" | jq -r --arg tg "$TARGET_A_ARN" '
  .Rules[] 
  | select(.Actions[]?.TargetGroupArn == $tg)
  | .RuleArn
')

RULE_B_ARN=$(echo "$RULES" | jq -r --arg tg "$TARGET_B_ARN" '
  .Rules[] 
  | select(.Actions[]?.TargetGroupArn == $tg)
  | .RuleArn
')

echo "🎯 Rule for Target A: $RULE_A_ARN"
echo "🎯 Rule for Target B: $RULE_B_ARN"

if [ -z "$RULE_A_ARN" ] || [ -z "$RULE_B_ARN" ]; then
  echo "❌ Could not find rules for both target groups."
  exit 1
fi

# Swap them
echo "🚀 Swapping Target A -> B and Target B -> A"

aws elbv2 modify-rule \
  --rule-arn "$RULE_A_ARN" \
  --actions Type=forward,TargetGroupArn="$TARGET_B_ARN"

aws elbv2 modify-rule \
  --rule-arn "$RULE_B_ARN" \
  --actions Type=forward,TargetGroupArn="$TARGET_A_ARN"

echo "✅ Forwarding Rule Swap complete!"

# Update idle service to new image
echo "🚀 Updating ECS service to use new task definition: $TASK_DEF_ARN"
aws ecs update-service \
  --cluster "$CLUSTER_NAME" \
  --service "$GREEN_SVC" \
  --task-definition "$TASK_DEF_ARN" \
  --desired-count "$DESIRED_COUNT" \
  --force-new-deployment

# Wait for the new service to become healthy
echo "⏳ Waiting for $GREEN_SVC to stabilize..."
aws ecs wait services-stable \
  --cluster "$CLUSTER_NAME" \
  --services "$GREEN_SVC"

echo "🎯 New Blue (active): $GREEN_TG_ARN"
echo "🎯 New Green (idle): $BLUE_TG_ARN"

# Tag the new Blue as Deployment=blue, remove from Green
echo "🏷️ Updating target group tags..."

aws elbv2 add-tags \
  --resource-arns "$GREEN_TG_ARN" \
  --tags Key=Deployment,Value=blue

aws elbv2 add-tags \
  --resource-arns "$BLUE_TG_ARN" \
  --tags Key=Deployment,Value=green

echo "✅ Tags updated! $GREEN_TG_ARN -> Deployment=blue"

# Optionally, scale down the old service
echo "🧹 Scaling down old service: $BLUE_SVC"
aws ecs update-service --cluster "$CLUSTER_NAME" --service "$BLUE_SVC" --desired-count 0

echo "✅ A/B deployment complete!"


