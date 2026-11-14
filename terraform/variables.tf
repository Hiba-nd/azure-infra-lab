variable "location" {
  description = "Azure region for the lab resources."
  type        = string
  nullable    = false

  validation {
    condition     = trimspace(var.location) != ""
    error_message = "Set location to an Azure region available in your subscription."
  }
}

variable "vm_size" {
  description = "Ubuntu VM size. Check availability and cost in the selected region."
  type        = string
  default     = "Standard_B2ls_v2"
  nullable    = false
}

variable "ssh_source_cidr" {
  description = "Public IPv4 address of the SSH client as a /32 CIDR."
  type        = string
  nullable    = false

  validation {
    condition     = endswith(var.ssh_source_cidr, "/32") && can(cidrnetmask(var.ssh_source_cidr))
    error_message = "Set ssh_source_cidr to one IPv4 address with a /32 suffix."
  }
}

variable "ssh_public_key" {
  description = "OpenSSH public key for the VM administrator."
  type        = string
  nullable    = false

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa) [A-Za-z0-9+/]+={0,2}( [^\\r\\n]*)?$", trimspace(var.ssh_public_key)))
    error_message = "Supply an OpenSSH Ed25519 or RSA public key."
  }
}
