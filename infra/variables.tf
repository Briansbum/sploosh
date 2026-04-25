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
  description = "EC2 instance types to pool across in the Fleet (memory-optimised)"
  type        = list(string)
  default = [
    "r6a.xlarge",   # 32 GB, AMD, ~$0.06/h spot
    "r7a.xlarge",   # 32 GB, AMD Zen4
    "r6i.xlarge",   # 32 GB, Intel
    "m6a.2xlarge",  # 32 GB, AMD (more CPU)
    "m7a.2xlarge",
  ]
}

variable "ami_ids" {
  description = "Per-modpack AMI IDs, updated by CI after each ami.yml run"
  type        = map(string)
  default     = {} # populated by CI via workspace variable or tfvars
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
