locals {
  security_group_id = length(var.security_group_ids) == 0 ? azurerm_network_security_group.dsf_base_sg.id : var.security_group_ids[0]

  incoming_folder_path = "/opt/itpba/incoming"

  public_ip  = azurerm_linux_virtual_machine.vm.public_ip_address
  private_ip = azurerm_linux_virtual_machine.vm.private_ip_address

  install_script = templatefile("${path.module}/setup.tftpl", {
    vault_name                                 = azurerm_key_vault.vault.name
    analytics_archiver_password_name           = azurerm_key_vault_secret.analytics_archiver_password.name
    admin_analytics_registration_password_name = azurerm_key_vault_secret.admin_analytics_registration_password.name
    analytics_ssh_password_secret_name         = azurerm_key_vault_secret.ssh_password.name
    archiver_user                              = var.archiver_user
    archiver_password                          = var.archiver_password
    admin_server_private_ip                    = var.admin_server_private_ip
  })

  readiness_script = templatefile("${path.module}/waiter.tftpl", {
    admin_server_public_ip = var.admin_server_public_ip
  })
}

resource "azurerm_network_interface" "nic" {
  name                = var.name
  resource_group_name = var.resource_group.name
  location            = var.resource_group.location

  ip_configuration {
    name                          = join("-", [var.name, "nic"])
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = "Dynamic"
  }
  tags = var.tags
}

resource "azurerm_network_interface_security_group_association" "nic_sg_association" {
  network_interface_id      = azurerm_network_interface.nic.id
  network_security_group_id = local.security_group_id
}

resource "azurerm_linux_virtual_machine" "vm" {
  name                = var.name
  resource_group_name = var.resource_group.name
  location            = var.resource_group.location
  size                = var.instance_size
  admin_username      = local.vm_user

  network_interface_ids = [
    azurerm_network_interface.nic.id
  ]

  admin_ssh_key {
    public_key = var.ssh_public_key
    username   = local.vm_user
  }

  os_disk {
    disk_size_gb         = var.storage_details.disk_size
    caching              = var.storage_details.volume_caching
    storage_account_type = var.storage_details.storage_account_type
  }

  source_image_id = local.image_id

  identity {
    type = "UserAssigned"
    identity_ids = [
      azurerm_user_assigned_identity.user_assigned_identity.id
    ]
  }
  custom_data = base64encode(local.install_script)

  # Ignore changes to the custom_data attribute (Don't replace on userdata change)
  lifecycle {
    ignore_changes = [
      custom_data
    ]
  }

  tags = var.tags
}

resource "azurerm_user_assigned_identity" "user_assigned_identity" {
  name                = var.name
  location            = var.resource_group.location
  resource_group_name = var.resource_group.name
}

data "azurerm_subscription" "subscription" {}

resource "azurerm_role_assignment" "vm_identity_role_assignment" {
  scope                = data.azurerm_subscription.subscription.id
  principal_id         = azurerm_user_assigned_identity.user_assigned_identity.principal_id
  role_definition_name = "Storage Blob Data Reader"
}

module "statistics" {
  source = "./_modules/azurerm/statistics"
  count  = var.send_usage_statistics ? 1 : 0

  deployment_name = var.name
  product         = "DRA"
  resource_type   = "dra-analytics"
  artifact        = local.image_id
  location        = var.resource_group.location
}

resource "null_resource" "readiness" {
  provisioner "local-exec" {
    command     = local.readiness_script
    interpreter = ["/bin/bash", "-c"]
  }
  depends_on = [
    azurerm_linux_virtual_machine.vm,
    module.statistics
  ]
}

module "statistics_success" {
  source = "./_modules/azurerm/statistics"
  count  = var.send_usage_statistics ? 1 : 0

  id         = module.statistics[0].id
  status     = "success"
  depends_on = [null_resource.readiness]
}
