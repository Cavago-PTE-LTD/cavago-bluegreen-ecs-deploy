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
LISTENER_ARN="$4"
TG_A_NAME="$5"
TG_B_NAME="$6"
SVC_A_NAME="$7"
SVC_B_NAME="$8"
SUBDOMAIN="$9"
CONTAINER_UPDATES="${10}"

echo "🔑 Starting A/B deployment for environment: $ENVIRONMENT"
echo "🔑 Using cluster name: $CLUSTER_NAME"
echo "🔑 Using task definition name: $TASK_DEF_NAME"
echo "🔑 Using listener ARN: $LISTENER_ARN"
echo "🔑 Using target group A name: $TG_A_NAME"
echo "🔑 Using target group B name: $TG_B_NAME"
echo "🔑 Using service A name: $SVC_A_NAME"
echo "🔑 Using service B name: $SVC_B_NAME"
echo "🔑 Using subdomain: $SUBDOMAIN"

# Convert container updates string to array
IFS=',' read -ra CONTAINER_PAIRS <<< "$CONTAINER_UPDATES"

echo "🔑 Using container updates:"
for pair in "${CONTAINER_PAIRS[@]}"; do
    IFS=':' read -r container image <<< "$pair"
    echo "   - $container: $image"
done

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

echo "📦 Current container definitions:"
jq '.taskDefinition.containerDefinitions[] | {name: .name, image: .image}' task-def.json

# Check service configuration
echo "🔍 Checking service configuration..."
aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SVC_A_NAME" > service-a.json
aws ecs describe-services --cluster "$CLUSTER_NAME" --services "$SVC_B_NAME" > service-b.json

echo "📦 Service A container names:"
jq '.services[0].taskDefinition' service-a.json
echo "📦 Service B container names:"
jq '.services[0].taskDefinition' service-b.json

# Create a temporary file for the jq command
cat > update.jq << 'EOF'
.taskDefinition 
| del(.taskDefinitionArn, .revision, .status, .requiresAttributes, .compatibilities, .registeredAt, .registeredBy) 
| .containerDefinitions = (
    .containerDefinitions 
    | map(
        if .name == "cavago-web-nginx-container" then 
          . + {"image": $image1}
        elif .name == "cavago-web-php-fpm-container" then 
          . + {"image": $image2}
        else 
          .
        end
      )
  )
EOF

# Extract container names and images
IFS=':' read -r container1 image1 <<< "${CONTAINER_PAIRS[0]}"
IFS=':' read -r container2 image2 <<< "${CONTAINER_PAIRS[1]}"

echo "🔧 Updating containers:"
echo "   - cavago-web-nginx-container: $image1"
echo "   - cavago-web-php-fpm-container: $image2"

# Update all specified containers
UPDATED_TASK_DEF=$(jq --arg image1 "$image1" \
                      --arg image2 "$image2" \
                      -f update.jq task-def.json)

# Debug: Print the updated task definition
echo "📝 Updated task definition:"
echo "$UPDATED_TASK_DEF" | jq '.'

# Debug: Print container definitions after update
echo "📦 Updated container definitions:"
echo "$UPDATED_TASK_DEF" | jq '.containerDefinitions[] | {name: .name, image: .image}'

echo "$UPDATED_TASK_DEF" > new-task-def.json

# Clean up temporary files
rm update.jq service-a.json service-b.json

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
