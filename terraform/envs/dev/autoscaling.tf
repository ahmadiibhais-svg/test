resource "aws_appautoscaling_target" "front_end" {
  service_namespace  = "ecs"
  resource_id        = "service/${module.ecs_cluster.cluster_name}/front-end"
  scalable_dimension = "ecs:service:DesiredCount"
  min_capacity       = 2
  max_capacity       = 5

  depends_on = [module.front_end]
}

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
    scale_out_cooldown = 60
    scale_in_cooldown  = 120
  }
}

resource "aws_appautoscaling_policy" "front_end_requests" {
  name               = "front-end-req-per-target-100"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.front_end.resource_id
  scalable_dimension = aws_appautoscaling_target.front_end.scalable_dimension
  service_namespace  = aws_appautoscaling_target.front_end.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${module.alb.alb_arn_suffix}/${module.alb.tg_arn_suffix}"
    }
    target_value       = 100
    scale_out_cooldown = 60
    scale_in_cooldown  = 120
  }
}
