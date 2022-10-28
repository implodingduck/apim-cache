terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "=3.21.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "=3.1.0"
    }
  }
  backend "azurerm" {

  }
}

provider "azurerm" {
  features {
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
  }

  subscription_id = var.subscription_id
}

locals {
  func_name      = "func${random_string.unique.result}"
  loc_for_naming = lower(replace(var.location, " ", ""))
  gh_repo        = replace(var.gh_repo, "implodingduck/", "")
  tags = {
    "managed_by" = "terraform"
    "repo"       = local.gh_repo
  }
}

resource "random_string" "unique" {
  length  = 8
  special = false
  upper   = false
}


data "azurerm_client_config" "current" {}

data "azurerm_log_analytics_workspace" "default" {
  name                = "DefaultWorkspace-${data.azurerm_client_config.current.subscription_id}-EUS"
  resource_group_name = "DefaultResourceGroup-EUS"
}

data "azurerm_network_security_group" "basic" {
  name                = "basic"
  resource_group_name = "rg-network-eastus"
}

resource "azurerm_resource_group" "rg" {
  name     = "rg-${local.gh_repo}-${random_string.unique.result}-${local.loc_for_naming}"
  location = var.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "default" {
  name                = "${local.func_name}-vnet-eastus"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  address_space       = ["10.2.0.0/16"]

  tags = local.tags
}


resource "azurerm_subnet" "default" {
  name                 = "default-subnet-eastus"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["10.2.0.0/24"]
}

resource "azurerm_subnet" "apim" {
  name                 = "apim-subnet-eastus"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["10.2.1.0/24"]
}

resource "azurerm_subnet" "func" {
  name                 = "func-subnet-eastus"
  resource_group_name  = azurerm_resource_group.rg.name
  virtual_network_name = azurerm_virtual_network.default.name
  address_prefixes     = ["10.2.2.0/24"]
  delegation {
    name = "serverfarm-delegation"
    service_delegation {
      name = "Microsoft.Web/serverFarms"
      actions = [
        "Microsoft.Network/virtualNetworks/subnets/action",
      ]
    }
  }
}

resource "azurerm_api_management" "apim" {
  name                 = "apim${random_string.unique.result}"
  location             = azurerm_resource_group.rg.location
  resource_group_name  = azurerm_resource_group.rg.name
  publisher_name       = "Implodingduck"
  publisher_email      = "something@nothing.com"
  virtual_network_type = "External"
  virtual_network_configuration {
    subnet_id = azurerm_subnet.apim.id
  }
  policy = [
    {
      xml_content = <<-EOT
    <!--
        IMPORTANT:
        - Policy elements can appear only within the <inbound>, <outbound>, <backend> section elements.
        - Only the <forward-request> policy element can appear within the <backend> section element.
        - To apply a policy to the incoming request (before it is forwarded to the backend service), place a corresponding policy element within the <inbound> section element.
        - To apply a policy to the outgoing response (before it is sent back to the caller), place a corresponding policy element within the <outbound> section element.
        - To add a policy position the cursor at the desired insertion point and click on the round button associated with the policy.
        - To remove a policy, delete the corresponding policy statement from the policy document.
        - Policies are applied in the order of their appearance, from the top down.
    -->
    <policies>
      <inbound />
      <backend>
        <forward-request />
      </backend>
      <outbound />
    </policies>
EOT
      xml_link    = ""
    },
  ]
  zones    = []
  sku_name = "Developer_1"
  tags     = local.tags
}

resource "azurerm_api_management_api" "cacheapi" {
  name                = "cache-api"
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azurerm_api_management.apim.name
  revision            = "1"
  display_name        = "Cache API"
  path                = "cacheapi"
  protocols           = ["https"]

}

resource "azurerm_api_management_api_operation" "hello" {
  operation_id        = "hello"
  api_name            = azurerm_api_management_api.cacheapi.name
  api_management_name = azurerm_api_management_api.cacheapi.api_management_name
  resource_group_name = azurerm_api_management_api.cacheapi.resource_group_name
  display_name        = "hello"
  method              = "GET"
  url_template        = "/api/HttpTrigger"
  description         = "This can only be done by the logged in user."
  request {
    query_parameter {
      name     = "name"
      required = false
      type     = "string"
    }
  }


  response {
    status_code = 200
  }
}

resource "azurerm_api_management_api_operation_policy" "cache" {
  api_name            = azurerm_api_management_api_operation.hello.api_name
  api_management_name = azurerm_api_management_api_operation.hello.api_management_name
  resource_group_name = azurerm_api_management_api_operation.hello.resource_group_name
  operation_id        = azurerm_api_management_api_operation.hello.operation_id

  xml_content = <<XML
<policies>
    <inbound>
      <base />
      <cache-lookup vary-by-developer="false" vary-by-developer-groups="false">
        <vary-by-query-parameter>name</vary-by-query-parameter>
      </cache-lookup>
      <set-backend-service backend-id="${azurerm_api_management_backend.func.name}" />
    </inbound>
    <backend>
      <base />
    </backend>
    <outbound>
      <base />
      <cache-store duration="300" />
    </outbound>
    <on-error>
      <base />
    </on-error>
</policies>
XML

}

resource "azurerm_api_management_backend" "func" {
  name                = "func-backend"
  resource_group_name = azurerm_resource_group.rg.name
  api_management_name = azurerm_api_management.apim.name
  protocol            = "http"
  url                 = "https://${azurerm_linux_function_app.func.default_hostname}"
}


resource "azurerm_redis_cache" "cache" {
  name                = "cache${random_string.unique.result}"
  location            = azurerm_resource_group.rg.location
  resource_group_name = azurerm_resource_group.rg.name
  capacity            = 0
  family              = "C"
  sku_name            = "Basic"
  enable_non_ssl_port = false
  minimum_tls_version = "1.2"

  redis_configuration {
  }
}

resource "azurerm_api_management_redis_cache" "cache" {
  name              = "ext-redis-cache"
  api_management_id = azurerm_api_management.apim.id
  connection_string = azurerm_redis_cache.cache.primary_connection_string
  description       = "Redis cache instances"
  redis_cache_id    = azurerm_redis_cache.cache.id
  cache_location    = azurerm_redis_cache.cache.location
}


resource "azurerm_storage_account" "sa" {
  name                     = "sa${local.func_name}"
  resource_group_name      = azurerm_resource_group.rg.name
  location                 = azurerm_resource_group.rg.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
}

resource "azurerm_storage_container" "container" {
  name                  = "function"
  storage_account_name  = azurerm_storage_account.sa.name
  container_access_type = "private"
}


resource "azurerm_storage_container" "hosts" {
  name                  = "azure-webjobs-hosts"
  storage_account_name  = azurerm_storage_account.sa.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "secrets" {
  name                  = "azure-webjobs-secrets"
  storage_account_name  = azurerm_storage_account.sa.name
  container_access_type = "private"
}

resource "azurerm_role_assignment" "system" {
  scope                = azurerm_storage_account.sa.id
  role_definition_name = "Storage Blob Data Owner"
  principal_id         = azurerm_linux_function_app.func.identity.0.principal_id
}

resource "azurerm_service_plan" "asp" {
  name                = "asp-${local.func_name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  os_type             = "Linux"
  sku_name            = "EP1"
}

resource "azurerm_application_insights" "app" {
  name                = "${local.func_name}-insights"
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location
  application_type    = "other"
  workspace_id        = data.azurerm_log_analytics_workspace.default.id
}


resource "azurerm_linux_function_app" "func" {
  name                = local.func_name
  resource_group_name = azurerm_resource_group.rg.name
  location            = azurerm_resource_group.rg.location

  service_plan_id            = azurerm_service_plan.asp.id
  storage_account_name       = azurerm_storage_account.sa.name
  storage_account_access_key = azurerm_storage_account.sa.primary_access_key
  virtual_network_subnet_id  = azurerm_subnet.func.id


  site_config {
    application_insights_connection_string = azurerm_application_insights.app.connection_string
    application_insights_key               = azurerm_application_insights.app.instrumentation_key
    vnet_route_all_enabled                 = true
    application_stack {
      node_version = "16"
    }

  }
  identity {
    type = "SystemAssigned"
  }
  app_settings = {
    "BUILD_FLAGS"                    = "UseExpressBuild"
    "ENABLE_ORYX_BUILD"              = "true"
    "SCM_DO_BUILD_DURING_DEPLOYMENT" = "1"
    "XDG_CACHE_HOME"                 = "/tmp/.cache"
    "CACHE_CONNSTR"                  = "@Microsoft.KeyVault(SecretUri=https://${azurerm_key_vault.kv.name}.vault.azure.net/secrets/${azurerm_key_vault_secret.cacheconnstr.name}/)"
  }

}

resource "local_file" "localsettings" {
  content  = <<-EOT
{
  "IsEncrypted": false,
  "Values": {
    "FUNCTIONS_WORKER_RUNTIME": "node",
    "AzureWebJobsStorage": ""
  }
}
EOT
  filename = "../func/local.settings.json"
}


resource "null_resource" "publish_func" {
  depends_on = [
    azurerm_linux_function_app.func,
    local_file.localsettings
  ]
  triggers = {
    index = "${timestamp()}"
  }
  provisioner "local-exec" {
    working_dir = "../func"
    command     = "timeout 10m func azure functionapp publish ${azurerm_linux_function_app.func.name} --build remote"

  }
}

resource "azurerm_key_vault" "kv" {
  name                       = "kv-${local.func_name}"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

}


resource "azurerm_key_vault_access_policy" "sp" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = data.azurerm_client_config.current.object_id

  key_permissions = [
    "Create",
    "Get",
    "Purge",
    "Recover",
    "Delete"
  ]

  secret_permissions = [
    "Set",
    "Purge",
    "Get",
    "List",
    "Delete"
  ]

  certificate_permissions = [
    "Purge"
  ]

  storage_permissions = [
    "Purge"
  ]

}


resource "azurerm_key_vault_access_policy" "func" {
  key_vault_id = azurerm_key_vault.kv.id
  tenant_id    = data.azurerm_client_config.current.tenant_id
  object_id    = azurerm_linux_function_app.func.identity.0.principal_id

  key_permissions = [
    "Get",
  ]

  secret_permissions = [
    "Get",
    "List"
  ]

}

resource "azurerm_key_vault_secret" "cacheconnstr" {
  depends_on = [
    azurerm_key_vault_access_policy.sp
  ]
  name         = "cacheconnstr"
  value        = azurerm_redis_cache.cache.primary_connection_string
  key_vault_id = azurerm_key_vault.kv.id
  tags         = local.tags
}
