# Blue/Green ECS Deploy GitHub Action

This action performs a blue/green (A/B) deployment to AWS ECS using ALB Target Groups.

## Inputs

| Name           | Description                                 | Required |
|----------------|---------------------------------------------|----------|
| cluster        | ECS cluster name                            | ✅        |
| service_a      | ECS service name (A)                        | ✅        |
| service_b      | ECS service name (B)                        | ✅        |
| listener_arn   | ALB Listener ARN                            | ✅        |
| target_group_a | Target Group A ARN                          | ✅        |
| target_group_b | Target Group B ARN                          | ✅        |
| image          | Docker image URI to deploy                  | ✅        |
| container_name | Container name in task definition           | ✅        |

## Example usage

```yaml
- name: Blue/Green Deploy
  uses: Cavago-PTE-LTD/cavago-bluegreen-ecs-deploy@v1
  with:
    cluster: my-ecs-cluster
    service_a: my-service-a
    service_b: my-service-b
    listener_arn: arn:aws:elasticloadbalancing:...
    target_group_a: arn:aws:elasticloadbalancing:...
    target_group_b: arn:aws:elasticloadbalancing:...
    image: 123456789.dkr.ecr.us-east-1.amazonaws.com/my-app:latest
    container_name: my-container
