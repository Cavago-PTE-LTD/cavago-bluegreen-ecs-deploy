#!/bin/bash
set -e

# Debug: Print all arguments
echo "Number of arguments: $#"
echo "Arguments received:"
for ((i=1; i<=$#; i++)); do
    echo "Argument $i: ${!i}"
done

# Input parameters
ENVIRONMENT="$1"          # dev, staging, prod
LISTENER_ARN="$2"        # ALB listener ARN
TG_A_NAME="$3"           # Target Group A name
TG_B_NAME="$4"           # Target Group B name
ASG_A_NAME="$5"          # Auto Scaling Group A name
ASG_B_NAME="$6"          # Auto Scaling Group B name
SUBDOMAIN="$7"           # Subdomain for the application
AMI_ID="$8"              # New AMI ID to deploy
LAUNCH_TEMPLATE_NAME="$9" # Launch template name
LAUNCH_TEMPLATE_VERSION="${10}" # Launch template version
ZIP_FILE_NAME="${11}"    # Name of the ZIP file containing application code
S3_BUCKET="${12}"        # S3 bucket containing the deployment package

echo "🔑 Starting Blue/Green deployment for environment: $ENVIRONMENT"
echo "🔑 Using listener ARN: $LISTENER_ARN"
echo "🔑 Using target group A name: $TG_A_NAME"
echo "🔑 Using target group B name: $TG_B_NAME"
echo "🔑 Using ASG A name: $ASG_A_NAME"
echo "🔑 Using ASG B name: $ASG_B_NAME"
echo "🔑 Using subdomain: $SUBDOMAIN"
echo "🔑 Using AMI ID: $AMI_ID"
echo "🔑 Using launch template: $LAUNCH_TEMPLATE_NAME (version: $LAUNCH_TEMPLATE_VERSION)"
echo "🔑 Using deployment package: $ZIP_FILE_NAME from bucket: $S3_BUCKET"

# Download deployment package from S3
echo "📥 Downloading deployment package from S3..."
aws s3 cp "s3://$S3_BUCKET/$ZIP_FILE_NAME" "/tmp/$ZIP_FILE_NAME"

# Create a temporary user data script that will download and deploy the application
cat > /tmp/user-data.sh << 'EOF'
#!/bin/bash
set -e

# Install AWS CLI if not present
if ! command -v aws &> /dev/null; then
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install
fi

# Download and extract deployment package
aws s3 cp "s3://${S3_BUCKET}/${ZIP_FILE_NAME}" "/tmp/${ZIP_FILE_NAME}"
unzip -o "/tmp/${ZIP_FILE_NAME}" -d /var/www/html/

# Set proper permissions
chown -R www-data:www-data /var/www/html
chmod -R 755 /var/www/html
chmod -R 777 /var/www/html/storage
chmod -R 777 /var/www/html/bootstrap/cache

# Run deployment commands
cd /var/www/html
php artisan config:cache
php artisan route:cache
php artisan view:cache

# Clean up
rm "/tmp/${ZIP_FILE_NAME}"
EOF

# Make the user data script executable
chmod +x /tmp/user-data.sh

# Create new launch template version with updated AMI and user data
NEW_TEMPLATE_VERSION=$(aws ec2 create-launch-template-version \
  --launch-template-name "$LAUNCH_TEMPLATE_NAME" \
  --source-version "$LAUNCH_TEMPLATE_VERSION" \
  --launch-template-data "ImageId=$AMI_ID,UserData=$(base64 -w 0 /tmp/user-data.sh)" \
  --query "LaunchTemplateVersion.VersionNumber" \
  --output text)

echo "📦 New launch template version created: $NEW_TEMPLATE_VERSION"

# Clean up temporary files
rm /tmp/user-data.sh

# Get target group ARNs
TG_A_ARN=$(aws elbv2 describe-target-groups --names "$TG_A_NAME" \
  --query "TargetGroups[0].TargetGroupArn" --output text)
TG_B_ARN=$(aws elbv2 describe-target-groups --names "$TG_B_NAME" \
  --query "TargetGroups[0].TargetGroupArn" --output text)

# Determine active and idle target groups
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

# Determine which ASG is active and which is idle
if [ "$BLUE_TG_ARN" == "$TG_A_ARN" ]; then
  echo "✅ A is active. Deploying to B."
  BLUE_ASG="$ASG_A_NAME"
  GREEN_ASG="$ASG_B_NAME"
  GREEN_TG_ARN="$TG_B_ARN"
elif [ "$BLUE_TG_ARN" == "$TG_B_ARN" ]; then
  echo "✅ B is active. Deploying to A."
  BLUE_ASG="$ASG_B_NAME"
  GREEN_ASG="$ASG_A_NAME"
  GREEN_TG_ARN="$TG_A_ARN"
else
  echo "❌ Unable to determine active target group."
  exit 1
fi

# Update the idle ASG to use new launch template version
echo "🚀 Updating $GREEN_ASG to use new launch template version..."
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "$GREEN_ASG" \
  --launch-template "LaunchTemplateName=$LAUNCH_TEMPLATE_NAME,Version=$NEW_TEMPLATE_VERSION" \
  --desired-capacity 1 \
  --min-size 1 \
  --max-size 1

# Wait for new instances to be healthy in target group
echo "⏳ Waiting for new instances to be healthy in target group..."
aws elbv2 wait target-in-service \
  --target-group-arn "$GREEN_TG_ARN" \
  --targets Id=$(aws ec2 describe-instances \
    --filters "Name=tag:aws:autoscaling:groupName,Values=$GREEN_ASG" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" \
    --output text)

echo "🎯 Blue active TG ARN: $BLUE_TG_ARN"
echo "🎯 Blue Rule ARN: $BLUE_RULE_ARN"
echo "🎯 Green Rule ARN: $GREEN_RULE_ARN"

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

echo "✅ ALB path patterns updated!"

# Wait for a short period to ensure traffic is properly routed
echo "⏳ Waiting for traffic to stabilize..."
sleep 30

# Check if the new deployment is healthy
HEALTH_CHECK=$(aws elbv2 describe-target-health \
  --target-group-arn "$GREEN_TG_ARN" \
  --query "TargetHealthDescriptions[0].TargetHealth.State" \
  --output text)

if [ "$HEALTH_CHECK" != "healthy" ]; then
  echo "❌ New deployment is not healthy. Rolling back..."
  
  # Rollback: Switch rules back
  aws elbv2 modify-rule \
    --rule-arn "$BLUE_RULE_ARN" \
    --conditions '[{"Field":"host-header","Values":["'"$SUBDOMAIN"'"]}, {"Field":"path-pattern","Values":["/*"]}]'
  
  aws elbv2 modify-rule \
    --rule-arn "$GREEN_RULE_ARN" \
    --conditions '[{"Field":"host-header","Values":["'"$SUBDOMAIN"'"]}, {"Field":"path-pattern","Values":["/green/*"]}]'
  
  # Terminate the unhealthy instances
  aws autoscaling update-auto-scaling-group \
    --auto-scaling-group-name "$GREEN_ASG" \
    --desired-capacity 0
  
  echo "❌ Deployment failed and rolled back"
  exit 1
fi

# Scale down the old ASG
echo "🧹 Scaling down old ASG: $BLUE_ASG"
aws autoscaling update-auto-scaling-group \
  --auto-scaling-group-name "$BLUE_ASG" \
  --desired-capacity 0

# After successful deployment, clean up the deployment package
echo "🧹 Cleaning up deployment package..."
rm "/tmp/$ZIP_FILE_NAME"

echo "✅ Blue/Green deployment complete!"
