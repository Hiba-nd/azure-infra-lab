# Azure VM lab

This configuration describes one Ubuntu 24.04 LTS VM, a virtual network and subnet,
a network security group, and a static public IPv4 address. The subnet allows
TCP port 22 from the configured IPv4 `/32` and denies other inbound traffic. The
public IP provides explicit outbound connectivity. SSH uses a public key, and the
VM enables Secure Boot and vTPM.

## Validate

Use Terraform 1.17.2 or a compatible 1.x release. From the repository root, run:

```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false -lockfile=readonly -input=false
terraform -chdir=terraform validate
terraform -chdir=terraform test
```

The tests use a mock AzureRM provider. They check the planned access rules and
VM security settings and verify that Terraform rejects unrestricted SSH. GitHub
Actions runs the same checks on changes to the Terraform configuration.

## Prepare a deployment plan

Sign in with the Azure CLI and select the intended subscription. The subscription
needs the `Microsoft.Compute` and `Microsoft.Network` resource providers registered.
Choose a region where your subscription has quota for the VM size, then review
the cost of the VM, managed disk, and public IP.

```bash
az login
az account set --subscription '<subscription-id>'
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
export TF_VAR_location='<azure-region>'
export TF_VAR_ssh_source_cidr='<your-public-ipv4>/32'
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
terraform -chdir=terraform init
terraform -chdir=terraform plan -out=lab.tfplan
```

Use your own SSH public key. The key under `tests/fixtures/` is test data.
The default size is `Standard_B2ls_v2`. The Canonical image uses the latest Ubuntu
24.04 LTS build available in the selected region. Record the resolved image
version when testing a live deployment. This lab uses local Terraform state.
Keep state and plan files on the machine that manages the deployment.

After an approved apply, `terraform -chdir=terraform output -raw public_ip`
and `terraform -chdir=terraform output -raw admin_username` supply the values for
the Ansible inventory described in the [root README](../README.md). Verify the VM's
SSH host key before connecting. When the lab is finished, review a destroy plan
and confirm the dedicated resource group and its resources have been removed.

The live Azure plan, VM boot, and SSH access to that VM still need verification
against the selected subscription.
