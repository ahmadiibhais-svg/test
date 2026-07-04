# The $25/month cost guardrail (CLAUDE.md), managed as code like everything else.
# (The hand-made "My Budget" ($40/daily) from account setup is left untouched;
# this one is the project guardrail — DECISIONS.md D7.)
#
# Four explicit notification blocks instead of a dynamic loop: this is a guardrail,
# and guardrails should be boringly readable.
resource "aws_budgets_budget" "monthly" {
  name        = "avertra-sockshop-monthly"
  budget_type = "COST"

  limit_amount = tostring(var.budget_limit_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Early warning: half the budget actually spent.
  notification {
    notification_type          = "ACTUAL"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = var.budget_alert_emails
  }

  # Second warning: 80% actually spent — time to scale things down.
  notification {
    notification_type          = "ACTUAL"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = var.budget_alert_emails
  }

  # Budget breached in fact.
  notification {
    notification_type          = "ACTUAL"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = var.budget_alert_emails
  }

  # Trend-based: AWS forecasts month-end spend will exceed the budget — fires days
  # before the money is actually gone (e.g. a NAT gateway left running).
  notification {
    notification_type          = "FORECASTED"
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    subscriber_email_addresses = var.budget_alert_emails
  }
}
