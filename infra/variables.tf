variable "github_repo" {
  description = "GitHub repo in owner/name format, used for OIDC trust policy"
  type        = string
  default     = "Briansbum/sploosh"
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "eu-west-2"
}

variable "vpc_id" {
  description = "VPC ID to deploy into (default VPC is fine)"
  type        = string
}

variable "operator_cidr" {
  description = "Your home IP /32 for SSH access"
  type        = string
}

variable "instance_types" {
  description = "EC2 instance types to pool across in the Fleet (all 16 GiB / 4 vCPU, spot ~$0.04-0.08/hr in eu-west-2)"
  type        = list(string)
  default = [
    "m5.xlarge",
    "m5a.xlarge",
    "m6i.xlarge",
    "m6a.xlarge",
  ]
}

variable "ami_ids" {
  description = "Per-modpack AMI IDs, updated by CI after each ami.yml run"
  type        = map(string)
}

variable "rcon_password" {
  description = "RCON password written into user-data"
  type        = string
  sensitive   = true
}

variable "restic_password" {
  description = "restic repository encryption password"
  type        = string
  sensitive   = true
}

variable "idle_webhook_url" {
  description = "CF Worker /idle-shutdown webhook URL (populated after worker deploy)"
  type        = string
  default     = ""
}

variable "idle_webhook_secret" {
  description = "HMAC secret for the idle-shutdown webhook"
  type        = string
  sensitive   = true
  default     = ""
}
