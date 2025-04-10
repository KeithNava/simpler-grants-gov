locals {
  search_config = local.environment_config.search_config
  service_name  = "${local.prefix}${module.app_config.app_name}-${var.environment_name}"
}

module "search" {
  count = local.search_config != null ? 1 : 0

  source = "../../modules/search"

  service_name                  = local.service_name
  availability_zone_count       = local.search_config.availability_zone_count
  zone_awareness_enabled        = var.environment_name == "prod" ? true : false
  multi_az_with_standby_enabled = var.environment_name == "prod" ? true : false
  dedicated_master_enabled      = var.environment_name == "prod" ? true : false
  dedicated_master_count        = var.environment_name == "prod" ? 3 : 1
  subnet_ids                    = slice(data.aws_subnets.database.ids, 0, var.environment_name == "prod" ? 3 : 1)
  instance_count                = local.search_config.instance_count
  engine_version                = local.search_config.engine_version
  dedicated_master_type         = local.search_config.dedicated_master_type
  instance_type                 = local.search_config.instance_type
  volume_size                   = local.search_config.volume_size
  vpc_id                        = data.aws_vpc.network.id
}
