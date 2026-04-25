terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Use a local backend for now; swap to S3 backend once the bucket exists
  # backend "s3" {
  #   bucket = "sploosh-minecraft-backups"
  #   key    = "terraform/state"
  #   region = var.aws_region
  # }
}

provider "aws" {
  region = var.aws_region
}

# ── S3 ─────────────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "backups" {
  bucket = "sploosh-minecraft-backups"
}

resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Disabled" # restic manages its own retention
  }
}

# Staging prefix for AMI image uploads from CI
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id

  rule {
    id     = "expire-ami-staging"
    status = "Enabled"
    filter {
      prefix = "ami-staging/"
    }
    expiration {
      days = 7
    }
  }
}

# ── IAM — vmimport service role (required for ec2 import-snapshot) ────────────
# Must be named exactly "vmimport"; AWS VM Import/Export service assumes it.

resource "aws_iam_role" "vmimport" {
  name = "vmimport"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vmie.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "sts:ExternalId" = "vmimport" }
      }
    }]
  })
}

resource "aws_iam_role_policy" "vmimport" {
  name = "vmimport-policy"
  role = aws_iam_role.vmimport.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.backups.arn,
          "${aws_s3_bucket.backups.arn}/*",
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "ec2:ModifySnapshotAttribute",
          "ec2:CopySnapshot",
          "ec2:RegisterImage",
          "ec2:Describe*",
        ]
        Resource = "*"
      }
    ]
  })
}

# ── IAM — GitHub Actions OIDC ─────────────────────────────────────────────────
# If this provider already exists in your account, import it:
#   tofu import aws_iam_openid_connect_provider.github arn:aws:iam::<account-id>:oidc-provider/token.actions.githubusercontent.com

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  # AWS validates against trusted CAs; thumbprint is a required placeholder
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "ci" {
  name = "sploosh-github-ci"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "ci" {
  name = "sploosh-ci-policy"
  role = aws_iam_role.ci.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:ImportSnapshot",
          "ec2:DescribeImportSnapshotTasks",
          "ec2:RegisterImage",
          "ec2:DescribeImages",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = "${aws_s3_bucket.backups.arn}/ami-staging/*"
      }
    ]
  })
}

# ── IAM — instance profile ─────────────────────────────────────────────────────

resource "aws_iam_role" "mc_instance" {
  name = "sploosh-minecraft-instance"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "mc_instance_s3" {
  name = "s3-backups"
  role = aws_iam_role.mc_instance.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
        ]
        Resource = [
          "${aws_s3_bucket.backups.arn}",
          "${aws_s3_bucket.backups.arn}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      }
    ]
  })
}

# Attach SSM policy so we can shell in without SSH key
resource "aws_iam_role_policy_attachment" "mc_instance_ssm" {
  role       = aws_iam_role.mc_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "mc" {
  name = "sploosh-minecraft"
  role = aws_iam_role.mc_instance.name
}

# ── IAM — Cloudflare Worker user ───────────────────────────────────────────────

resource "aws_iam_user" "cf_worker" {
  name = "sploosh-cf-worker"
}

resource "aws_iam_user_policy" "cf_worker" {
  name = "sploosh-worker-policy"
  user = aws_iam_user.cf_worker.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeFleets",
          "ec2:DescribeFleetInstances",
          "ec2:DescribeInstances",
          "ec2:ModifyFleet",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:DescribeSecurityGroups",
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_access_key" "cf_worker" {
  user = aws_iam_user.cf_worker.name
}

# ── Security Group ─────────────────────────────────────────────────────────────

resource "aws_security_group" "minecraft" {
  name        = "sploosh-minecraft"
  description = "Minecraft server - port 25565 added per-user by the Discord bot"
  vpc_id      = var.vpc_id

  # SSH from operator only
  ingress {
    description = "SSH operator"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.operator_cidr]
  }

  # 25565 starts empty — bot calls AuthorizeSecurityGroupIngress per user
  # No static 25565 rule here.

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "sploosh-minecraft" }
}

# ── Launch Templates ───────────────────────────────────────────────────────────

locals {
  modpacks = {
    create-central = {
      ami_id       = lookup(var.ami_ids, "create-central", "ami-00000000000000000")
      s3_prefix    = "create-central/restic"
      display_name = "Create Central"
    }
  }
}

resource "aws_launch_template" "mc" {
  for_each = local.modpacks

  name = "sploosh-${each.key}"

  image_id      = each.value.ami_id
  instance_type = var.instance_types[0] # hint; fleet picks from the pool

  iam_instance_profile {
    name = aws_iam_instance_profile.mc.name
  }

  vpc_security_group_ids = [aws_security_group.minecraft.id]

  # 16 GB root volume — world data lives on S3, not EBS
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 16
      volume_type           = "gp3"
      delete_on_termination = true
    }
  }

  # Bootstrap payload — read by nixos/server.nix's mc-bootstrap service
  user_data = base64encode(jsonencode({
    modpack          = each.key
    s3_bucket        = aws_s3_bucket.backups.id
    s3_prefix        = each.value.s3_prefix
    rcon_password    = var.rcon_password
    restic_password  = var.restic_password
    idle_webhook     = var.idle_webhook_url
    webhook_secret   = var.idle_webhook_secret
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name    = "sploosh-${each.key}"
      Modpack = each.key
    }
  }
}

# ── EC2 Fleet (maintain, target=0 when idle) ───────────────────────────────────

resource "aws_ec2_fleet" "mc" {
  for_each = local.modpacks

  type = "maintain"

  target_capacity_specification {
    default_target_capacity_type = "spot"
    total_target_capacity        = 0 # bot sets to 1 to start, 0 to stop
  }

  launch_template_config {
    launch_template_specification {
      launch_template_id = aws_launch_template.mc[each.key].id
      version            = "$Latest"
    }

    # Spread across instance types and AZs for best spot availability
    dynamic "override" {
      for_each = setproduct(var.instance_types, data.aws_availability_zones.available.names)
      content {
        instance_type     = override.value[0]
        availability_zone = override.value[1]
      }
    }
  }

  spot_options {
    allocation_strategy            = "price-capacity-optimized"
    instance_interruption_behavior = "terminate"
  }

  on_demand_options {
    allocation_strategy = "lowestPrice"
  }

  # Allow the fleet to exist with 0 capacity
  excess_capacity_termination_policy = "termination"

  tags = {
    Name    = "sploosh-${each.key}"
    Modpack = each.key
  }

  # Prevent Terraform from destroying the fleet when updating AMI — just update
  lifecycle {
    ignore_changes = [launch_template_config]
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# ── AMI import pipeline ────────────────────────────────────────────────────────
# CI builds the NixOS AMI with nixos-generators, converts to vmdk,
# uploads to s3://sploosh-minecraft-backups/ami-staging/<modpack>/<sha>.vmdk,
# then calls:
#   aws ec2 import-snapshot --disk-container file://container.json
#   aws ec2 register-image ...
#
# The resulting AMI ID is pushed into var.ami_ids (or directly into D1) by CI.
# This Terraform file does not manage AMI registration — that's handled by
# .github/workflows/ami.yml to keep the IDs in D1 alongside the fleet IDs.
#
# See scripts/register-ami.sh for the CI helper.
