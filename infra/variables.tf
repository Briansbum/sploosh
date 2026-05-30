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
  description = "EC2 instance types to pool across in the Fleet (all 16 GiB, spot ~$0.02-0.06/hr in eu-west-2)"
  type        = list(string)
  default = [
    # r-family large: 16 GiB, 2 vCPU — memory-optimised, largest spot pools
    "r5.large",     # Intel Cascade Lake, very large pool
    "r5a.large",    # AMD EPYC, separate spot pool
    "r5n.large",    # Intel, higher network bandwidth
    "r6i.large",    # Intel Ice Lake
    # m-family xlarge: 16 GiB, 4 vCPU — extra CPU for mod-heavy packs
    "m5.xlarge",    # Intel, very large pool
    "m5a.xlarge",   # AMD, large pool
    "m6i.xlarge",   # Intel Ice Lake
    "m6a.xlarge",   # AMD EPYC
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
