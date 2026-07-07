# Phase 5 — auto-scaling on front-end (HPA, ECS edition).
# Target tracking = "keep this metric AT this value": AWS creates and manages
# the underlying CloudWatch alarms itself (visible in the console, named
# TargetTracking-*) and scales to hold the target. Two policies, either can
# trigger a scale-out; scale-IN only when BOTH agree capacity is excessive.

# Registers front-end's desired count as a scalable dimension (min/max bounds).
resource "aws_appautoscaling_target" "front_end" {
  service_namespace  = "ecs"
  resource_id        = "service/${module.ecs_cluster.cluster_name}/front-end"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 2 # never below the HA baseline
  max_capacity       = 5 # demo ceiling (cost guardrail)

  # resource_id is just a string — Terraform can't see the service inside it,
  # so the ordering must be stated (same class of fix as D12).
  depends_on = [module.front_end]
}

# Policy 1: average CPU across front-end tasks at 60%.
resource "aws_appautoscaling_policy" "front_end_cpu" {
  name               = "front-end-cpu-60"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.front_end.resource_id
  scalable_dimension = aws_appautoscaling_target.front_end.scalable_dimension
  service_namespace  = aws_appautoscaling_target.front_end.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 60
    scale_out_cooldown = 60  # add capacity fast
    scale_in_cooldown  = 120 # remove it cautiously (flap damping)
  }
}

# Policy 2: requests per target at 100/min — the traffic-shaped signal that
# reacts before CPU does (the load test is designed to trip this one).
resource "aws_appautoscaling_policy" "front_end_requests" {
  name               = "front-end-req-per-target-100"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.front_end.resource_id
  scalable_dimension = aws_appautoscaling_target.front_end.scalable_dimension
  service_namespace  = aws_appautoscaling_target.front_end.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      # "which target group's request count": <alb-suffix>/<tg-suffix>
      resource_label = "${module.alb.alb_arn_suffix}/${module.alb.tg_arn_suffix}"
    }
    target_value       = 100
    scale_out_cooldown = 60
    scale_in_cooldown  = 120
  }
}
