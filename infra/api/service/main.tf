data "aws_vpc" "network" {
  filter {
    name   = "tag:Name"
    values = [module.project_config.network_configs[var.environment_name].vpc_name]
  }
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.network.id]
  }
  filter {
    name   = "tag:subnet_type"
    values = ["private"]
  }
}

data "aws_subnets" "public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.network.id]
  }
  filter {
    name   = "tag:subnet_type"
    values = ["public"]
  }
}

locals {
  # The prefix key/value pair is used for Terraform Workspaces, which is useful for projects with multiple infrastructure developers.
  # By default, Terraform creates a workspace named “default.” If a non-default workspace is not created this prefix will equal “default”,
  # if you choose not to use workspaces set this value to "dev"
  prefix = terraform.workspace == "default" ? "" : "${terraform.workspace}-"

  # Add environment specific tags
  tags = merge(module.project_config.default_tags, {
    environment = var.environment_name
    description = "Application resources created in ${var.environment_name} environment"
  })

  service_name = "${local.prefix}${module.app_config.app_name}-${var.environment_name}"

  is_temporary = terraform.workspace != "default"

  # Include project name in bucket name since buckets need to be globally unique across AWS
  bucket_name = "${local.prefix}${module.project_config.project_name}-${module.app_config.app_name}-${var.environment_name}"

  environment_config                             = module.app_config.environment_configs[var.environment_name]
  service_config                                 = local.environment_config.service_config
  storage_config                                 = local.environment_config.storage_config
  incident_management_service_integration_config = local.environment_config.incident_management_service_integration
  network_config                                 = module.project_config.network_configs[local.environment_config.network_name]
}

terraform {
  required_version = "< 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.68.0"
    }
  }

  backend "s3" {
    encrypt = "true"
  }
}

provider "aws" {
  region = local.service_config.region
  default_tags {
    tags = local.tags
  }
}

module "project_config" {
  source = "../../project-config"
}

module "app_config" {
  source = "../app-config"
}

data "aws_rds_cluster" "db_cluster" {
  count              = module.app_config.has_database ? 1 : 0
  cluster_identifier = local.database_config.cluster_name
}

data "aws_acm_certificate" "cert" {
  count  = local.service_config.domain_name != null ? 1 : 0
  domain = local.service_config.domain_name
}

data "aws_iam_policy" "app_db_access_policy" {
  count = module.app_config.has_database ? 1 : 0
  name  = local.database_config.app_access_policy_name
}

data "aws_iam_policy" "migrator_db_access_policy" {
  count = module.app_config.has_database ? 1 : 0
  name  = local.database_config.migrator_access_policy_name
}

# Retrieve url for external incident management tool (e.g. Pagerduty, Splunk-On-Call)

data "aws_ssm_parameter" "incident_management_service_integration_url" {
  count = module.app_config.has_incident_management_service ? 1 : 0
  name  = local.incident_management_service_integration_config.integration_url_param_name
}

data "aws_security_groups" "aws_services" {
  filter {
    name   = "group-name"
    values = ["${module.project_config.aws_services_security_group_name_prefix}*"]
  }

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.network.id]
  }
}

data "aws_acm_certificate" "certificate" {
  count  = local.service_config.enable_https ? 1 : 0
  domain = local.service_config.domain_name
}

# data "aws_route53_zone" "zone" {
#   count = local.service_config.domain_name != null ? 1 : 0
#   name  = local.network_config.domain_config.hosted_zone
# }

module "service" {
  source           = "../../modules/service"
  service_name     = local.service_config.service_name
  environment_name = var.environment_name

  image_repository_name = module.app_config.image_repository_name
  image_tag             = local.image_tag

  vpc_id             = data.aws_vpc.network.id
  public_subnet_ids  = data.aws_subnets.public.ids
  private_subnet_ids = data.aws_subnets.private.ids

  domain_name    = local.service_config.domain_name
  hosted_zone_id = null
  # hosted_zone_id  = local.service_config.domain_name != null ? data.aws_route53_zone.zone[0].zone_id : null
  certificate_arn = local.service_config.enable_https ? data.aws_acm_certificate.certificate[0].arn : null

  cpu                      = local.service_config.cpu
  memory                   = local.service_config.memory
  desired_instance_count   = local.service_config.desired_instance_count
  enable_command_execution = local.service_config.enable_command_execution
  max_capacity             = local.service_config.instance_scaling_max_capacity
  min_capacity             = local.service_config.instance_scaling_min_capacity
  enable_autoscaling       = true

  aws_services_security_group_id = data.aws_security_groups.aws_services.ids[0]

  file_upload_jobs     = local.service_config.file_upload_jobs
  enable_s3_cdn        = true
  s3_cdn_bucket_name   = "public-files"
  scheduled_jobs       = local.environment_config.scheduled_jobs
  s3_buckets           = local.environment_config.s3_buckets
  enable_drafts_bucket = true

  db_vars = module.app_config.has_database ? {
    security_group_ids         = module.database[0].security_group_ids
    app_access_policy_arn      = module.database[0].app_access_policy_arn
    migrator_access_policy_arn = module.database[0].migrator_access_policy_arn
    connection_info = {
      host        = module.database[0].host
      port        = module.database[0].port
      user        = module.database[0].app_username
      db_name     = module.database[0].db_name
      schema_name = module.database[0].schema_name
    }
  } : null

  extra_environment_variables = merge({
    # FEATURE_FLAGS_PROJECT = module.feature_flags.evidently_project_name
    # BUCKET_NAME           = local.storage_config.bucket_name
  }, local.service_config.extra_environment_variables)

  secrets = concat(
    [for secret_name in keys(local.service_config.secrets) : {
      name      = secret_name
      valueFrom = module.secrets[secret_name].secret_arn
    }],
    local.environment_config.search_config != null ? [{
      name      = "SEARCH_USERNAME"
      valueFrom = data.aws_ssm_parameter.search_username_arn[0].arn
    }] : [],
    local.environment_config.search_config != null ? [{
      name      = "SEARCH_PASSWORD"
      valueFrom = data.aws_ssm_parameter.search_password_arn[0].arn
    }] : [],
    local.environment_config.search_config != null ? [{
      name      = "SEARCH_ENDPOINT"
      valueFrom = data.aws_ssm_parameter.search_endpoint_arn[0].arn
    }] : []
  )

  extra_policies = {
    # feature_flags_access = module.feature_flags.access_policy_arn,
    # storage_access       = module.storage.access_policy_arn
  }

  is_temporary = local.is_temporary
}

module "monitoring" {
  source = "../../modules/monitoring"
  #Email subscription list:
  email_alerts_subscription_list = ["grantsalerts@navapbc.com"]

  # Module takes service and ALB names to link all alerts with corresponding targets
  service_name                                = local.service_config.service_name
  load_balancer_arn_suffix                    = module.service.load_balancer_arn_suffix
  incident_management_service_integration_url = module.app_config.has_incident_management_service && !local.is_temporary ? data.aws_ssm_parameter.incident_management_service_integration_url[0].value : null
}
