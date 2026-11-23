# Azure VM lab

This configuration describes one Ubuntu 24.04 LTS VM, a virtual network and subnet,
a network security group, and a static public IPv4 address. The subnet allows
TCP port 22 from the configured IPv4 `/32` and denies other inbound traffic. The
public IP provides explicit outbound connectivity. SSH uses a public key, and the
VM enables Secure Boot, vTPM, and boot diagnostics with Azure-managed storage.

## Validate

Use Terraform 1.17.2 or a compatible 1.x release. From the repository root, run:

```bash
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform init -backend=false -lockfile=readonly -input=false
terraform -chdir=terraform validate
terraform -chdir=terraform test
```

The tests use a mock AzureRM provider. They check the planned access rules,
VM security settings, and boot diagnostics. A mocked apply checks the connections
between the VM, network interface, public IP, subnet, and security group. Input
tests reject broad SSH ranges, IPv6, malformed CIDRs, and missing key or region
values. GitHub Actions runs the same checks on changes to the Terraform
configuration.

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

## Generate the Ansible inventory

After an approved apply, verify the VM's SSH host key through a trusted channel
and add it to your controller's `known_hosts`. From the repository root on the
Linux controller, run the following with the private key matching the public key
used for the VM:

```bash
(
  set -euo pipefail
  umask 077
  mkdir -p artifacts
  terraform -chdir=terraform output -json \
    | python3 ansible/render-inventory.py > artifacts/lab.json
  ANSIBLE_HOST_KEY_CHECKING=True ansible-playbook -i artifacts/lab.json \
    --private-key ~/.ssh/id_ed25519 ansible/install-tools.yml --limit lab-vm
)
```

The renderer reads the `public_ip` and `admin_username` outputs from the current
state and writes a single host in the `lab` group. Missing or invalid values
stop the command before Ansible runs. Regenerate the inventory after replacing
the VM. Keep `terraform output -json` in the pipe because Terraform includes any
sensitive output values in its JSON.

When the lab is finished, review a destroy plan and confirm the dedicated resource
group and its resources have been removed.

The live Azure plan, VM boot, and SSH access to that VM still need verification
against the selected subscription.

## Boot troubleshooting

After deployment, open the VM's **Boot diagnostics** view in the Azure portal to
inspect the serial log and screenshot. Record any observed boot error before
changing the VM. These diagnostics help investigate failures that prevent SSH
from starting. Collection and retrieval still need verification on the deployed
VM. [Azure boot diagnostics](https://learn.microsoft.com/azure/virtual-machines/boot-diagnostics)
