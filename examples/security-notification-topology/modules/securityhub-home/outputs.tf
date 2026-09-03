output "finding_aggregator_arn" {
  value = aws_securityhub_finding_aggregator.this.arn
}

output "control_rule_arn" {
  value = aws_cloudwatch_event_rule.control_findings.arn
}
