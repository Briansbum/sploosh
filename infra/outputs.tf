output "ci_role_arn" {
  description = "IAM role ARN for GitHub Actions OIDC -- set as AWS_ROLE_ARN repo secret"
  value       = aws_iam_role.ci.arn
}

output "worker_access_key_id" {
  description = "AWS access key ID for the Cloudflare Worker — add to wrangler secrets"
  value       = aws_iam_access_key.cf_worker.id
}

output "worker_secret_access_key" {
  description = "AWS secret key for the Cloudflare Worker — add to wrangler secrets"
  value       = aws_iam_access_key.cf_worker.secret
  sensitive   = true
}

output "security_group_id" {
  description = "Minecraft security group — referenced in D1 modpacks table"
  value       = aws_security_group.minecraft.id
}

output "fleet_ids" {
  description = "EC2 Fleet IDs keyed by modpack name — insert into D1 modpacks table"
  value       = { for k, v in aws_ec2_fleet.mc : k => v.id }
}

output "s3_bucket" {
  value = aws_s3_bucket.backups.id
}
