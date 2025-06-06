#!/bin/bash
set -e

# Debug: Print all arguments
echo "Number of arguments: $#"
echo "Arguments received:"
for ((i=1; i<=$#; i++)); do
    echo "Argument $i: ${!i}"
done

# Input parameters
ENVIRONMENT="$1"
CLUSTER_NAME="$2"
TASK_DEF_NAME="$3"
SERVICE_A_NAME="$4"
SERVICE_B_NAME="$5"
SUBDOMAIN="$6"
DESIRED_COUNT="$7"

echo "🔑 Starting A/B deployment for environment: $ENVIRONMENT"
echo "🔑 Using cluster name: $CLUSTER_NAME"
echo "🔑 Using task definition name: $TASK_DEF_NAME"
echo "🔑 Using listener ARN: $LISTENER_ARN"

echo "🔑 Using service A name: $SERVICE_A_NAME"
echo "🔑 Using service B name: $SERVICE_B_NAME"
echo "🔑 Using subdomain: $SUBDOMAIN"
echo "🔑 Using desired count: $DESIRED_COUNT"

TARGET_A_ARN=$(aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_A_NAME" \
  --query "services[0].loadBalancers[0].targetGroupArn" \
  --output text)
TARGET_B_ARN=$(aws ecs describe-services \
  --cluster "$CLUSTER_NAME" \
  --services "$SERVICE_B_NAME" \
  --query "services[0].loadBalancers[0].targetGroupArn" \
  --output text)

echo "🔑 Using target group A ARN: $TARGET_A_ARN"
echo "🔑 Using target group B ARN: $TARGET_B_ARN"

LOAD_BALANCER_ARN=$(aws elbv2 describe-target-groups \
  --target-group-arns "$TARGET_A_ARN" \
  --query "TargetGroups[0].LoadBalancerArns[0]" \
  --output text)

echo "🔑 Using load balancer ARN: $LOAD_BALANCER_ARN"

LISTENER_ARN=$(aws elbv2 describe-listeners \
  --load-balancer-arn "$LOAD_BALANCER_ARN" \
  --query "Listeners[?Protocol==`HTTPS`].ListenerArn" \
  --output text)

echo "🔑 Using listener ARN: $LISTENER_ARN"

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

if [ "$BLUE_TG_ARN" == "$TARGET_A_ARN" ]; then
  echo "✅ A is active. Deploying to B."
  BLUE_SVC="$SERVICE_A_NAME"
  GREEN_SVC="$SERVICE_B_NAME"
  GREEN_TG_ARN="$TARGET_B_ARN"
elif [ "$BLUE_TG_ARN" == "$TARGET_B_ARN" ]; then
  echo "✅ B is active. Deploying to A."
  BLUE_SVC="$SERVICE_B_NAME"
  GREEN_SVC="$SERVICE_A_NAME"
  GREEN_TG_ARN="$TARGET_A_ARN"
else
  echo "❌ Unable to determine active target group."
  exit 1
fi

TASK_DEF_ARN=$(aws ecs describe-task-definition \
  --task-definition "$TASK_DEF_NAME" \
  --query "taskDefinition.taskDefinitionArn" \
  --output text)

echo "🔑 Using task definition ARN: $TASK_DEF_ARN"


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

echo "🎯 Blue active TG ARN: $BLUE_TG_ARN"
echo "🎯 Blue Rule ARN: $BLUE_RULE_ARN"
echo "🎯 Green Rule ARN (if exists): $GREEN_RULE_ARN"

# Update current active rule: demote to /green/*
echo "🔧 Updating blue rule to /green/*"
aws elbv2 modify-rule \
  --rule-arn "$BLUE_RULE_ARN" \
  --conditions '[{"Field":"host-header","Values":["'"$SUBDOMAIN"'"]}, {"Field":"path-pattern","Values":["/green/*"]}]'  

# Update green rule (new deployment): promote to /* 
echo "🔧 Updating green rule to /*"
aws elbv2 modify-rule \
  --rule-arn "$GREEN_RULE_ARN" \
  --conditions '[{"Field":"host-header","Values":["'"$SUBDOMAIN"'"]}, {"Field":"path-pattern","Values":["/*"]}]'  

echo "✅ ALB path patterns and priorities updated!"

# Optionally, scale down the old service
echo "🧹 Scaling down old service: $BLUE_SVC"
aws ecs update-service --cluster "$CLUSTER_NAME" --service "$BLUE_SVC" --desired-count 0

echo "✅ A/B deployment complete!"
