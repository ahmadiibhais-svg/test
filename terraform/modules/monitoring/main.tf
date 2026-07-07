# Monitoring module — Phase 4. The framing (docs sentence, Ahmad's APM line):
# infra monitoring answers "is the box healthy"; the dashboard's p99 + 5xx
# answer "is the APP healthy". Alarms notify the humans via SNS email.

# ------------------------------------------------------------------ alerting
#tfsec:ignore:aws-sns-enable-topic-encryption -- accepted 2026-07-07: encrypting with the default aws/sns key would SILENTLY BREAK the alarms (CloudWatch alarms cannot publish to topics encrypted with the AWS-managed key; a CMK with a key policy costs $1/mo + complexity for demo-scale alert text)
resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
}

# Email subscriptions start PENDING until the recipient clicks the link AWS
# sends — an unconfirmed subscription silently receives nothing.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# ------------------------------------------------------------------ dashboard
# One JSON document; for-expressions fan the 13 services into per-line metrics.
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project}-overview"

  dashboard_body = jsonencode({
    widgets = [
      {
        type = "metric", x = 0, y = 0, width = 8, height = 6
        properties = {
          title  = "ALB requests / 5min"
          region = var.aws_region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      },
      {
        type = "metric", x = 8, y = 0, width = 8, height = 6
        properties = {
          title  = "Latency p50 vs p99 (the tail is the truth)"
          region = var.aws_region
          period = 300
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p50", label = "p50" }],
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", var.alb_arn_suffix, { stat = "p99", label = "p99" }]
          ]
        }
      },
      {
        type = "metric", x = 16, y = 0, width = 8, height = 6
        properties = {
          title  = "HTTP 5xx (target)"
          region = var.aws_region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/ApplicationELB", "HTTPCode_Target_5XX_Count", "LoadBalancer", var.alb_arn_suffix]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 6, width = 8, height = 6
        properties = {
          title  = "ECS CPU % per service"
          region = var.aws_region
          stat   = "Average"
          period = 300
          metrics = [for s in var.service_names :
            ["AWS/ECS", "CPUUtilization", "ClusterName", var.cluster_name, "ServiceName", s, { label = s }]
          ]
        }
      },
      {
        type = "metric", x = 8, y = 6, width = 8, height = 6
        properties = {
          title  = "ECS memory % per service"
          region = var.aws_region
          stat   = "Average"
          period = 300
          metrics = [for s in var.service_names :
            ["AWS/ECS", "MemoryUtilization", "ClusterName", var.cluster_name, "ServiceName", s, { label = s }]
          ]
        }
      },
      {
        type = "metric", x = 16, y = 6, width = 8, height = 6
        properties = {
          title  = "Running tasks per service (Container Insights)"
          region = var.aws_region
          stat   = "Average"
          period = 300
          metrics = [for s in var.service_names :
            ["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", var.cluster_name, "ServiceName", s, { label = s }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 12, width = 24, height = 6
        properties = {
          title  = "RDS vitals (catalogue-db)"
          region = var.aws_region
          period = 300
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", var.rds_identifier, { stat = "Average", label = "CPU %" }],
            ["AWS/RDS", "DatabaseConnections", "DBInstanceIdentifier", var.rds_identifier, { stat = "Average", label = "connections", yAxis = "right" }],
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", var.rds_identifier, { stat = "Average", label = "free storage (bytes)", yAxis = "right" }]
          ]
        }
      }
    ]
  })
}

# ------------------------------------------------------------------- alarms
# 5 tripwires; every one notifies (and resolves) via the same topic.

resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${var.project}-alb-5xx"
  alarm_description   = "More than 5 target 5xx in 5 minutes — the app is failing users."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HTTPCode_Target_5XX_Count"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching" # no traffic = no news, not an incident

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "p99_latency" {
  alarm_name          = "${var.project}-alb-p99-latency"
  alarm_description   = "p99 latency over threshold — the slowest users are suffering first."
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = { LoadBalancer = var.alb_arn_suffix }
  extended_statistic  = "p99" # percentile stats use extended_statistic, not statistic
  period              = 300
  evaluation_periods  = 1
  threshold           = var.p99_latency_threshold_seconds
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "frontend_cpu" {
  alarm_name          = "${var.project}-front-end-cpu"
  alarm_description   = "front-end CPU above 80% for 10 minutes — scale or investigate."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = var.cluster_name, ServiceName = var.frontend_service_name }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.project}-rds-cpu"
  alarm_description   = "RDS CPU above 80% for 10 minutes."
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = var.rds_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 2
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}

resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${var.project}-rds-free-storage"
  alarm_description   = "RDS free storage under 2 GB — databases die ugly when disks fill."
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = var.rds_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2000000000 # bytes
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching" # missing storage data IS alarming

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]
}
