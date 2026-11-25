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

## CPU alert

Set `enable_cpu_alert=true` to add an Azure Monitor metric alert and an email
action group. The rule evaluates the VM's `Percentage CPU` metric every minute
using a five-minute average. It fires when that average is greater than
`cpu_alert_threshold`, which defaults to 80 percent, with severity 2 and automatic
resolution enabled. [VM platform metrics](https://learn.microsoft.com/azure/azure-monitor/reference/supported-metrics/microsoft-compute-virtualmachines-metrics)

| Input | Default | Purpose |
| --- | --- | --- |
| `enable_cpu_alert` | `false` | Include the alert and action group in the deployment |
| `alert_email` | `null` | Required notification address when the alert is enabled |
| `cpu_alert_threshold` | `80` | CPU percentage from 0 to 100 |

After approving monitoring costs and registering `Microsoft.Insights` in the
selected subscription, add these environment variables to the deployment inputs:

```bash
export TF_VAR_enable_cpu_alert=true
export TF_VAR_alert_email='<notification-email>'
terraform -chdir=terraform plan -out=lab.tfplan
```

Review the plan for the VM scope, threshold, and notification action group before
applying. Terraform marks the email input as sensitive in its plan output. State
and saved plans still contain it and belong in private storage. Setting
`enable_cpu_alert=false` removes the alert and action group in the next approved
apply. Metric alert rules have usage charges to review before deployment.
[Azure Monitor alert pricing](https://learn.microsoft.com/azure/azure-monitor/alerts/alerts-types)

Tests cover the disabled default, enabled VM scope and notification settings,
removal when disabled again, missing or invalid email, and threshold bounds.
Metric ingestion, alert firing, delivery, and resolution still require a live
test after deployment. Record the threshold, CPU time series, and timestamps for
the fired and resolved states, together with the notification received. The
Linux checks and backup jobs continue to publish their reports to journald.

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
export TF_VAR_vm_size='Standard_B2ls_v2'
export TF_VAR_ssh_source_cidr='<your-public-ipv4>/32'
export TF_VAR_ssh_public_key="$(cat ~/.ssh/id_ed25519.pub)"
terraform -chdir=terraform init
terraform -chdir=terraform plan -out=lab.tfplan
```

Use the same inputs to inspect the deployment prerequisites from a Linux controller
with Python 3 and Azure CLI. Run from the repository root.

```bash
python3 tools/azure-preflight.py --subscription "$ARM_SUBSCRIPTION_ID" \
  --location "$TF_VAR_location" --vm-size "$TF_VAR_vm_size"
```

Add `--with-cpu-alert` when enabling the optional CPU alert.

The preflight checks the requested subscription is enabled and the required
resource providers are registered. It selects an exact VM size from the region's
SKU response, checks location restrictions, and compares its vCPU count against
both the remaining regional and VM-family quotas. The check follows the lab VM's
regional placement. Zone restrictions apply to deployments that select an
availability zone. [Azure vCPU quotas](https://learn.microsoft.com/azure/virtual-machines/quotas)

Every Azure command includes the supplied subscription ID. The tool uses
`account show`, `provider show`, `vm list-skus`, and `vm list-usage`. Each command
has a 60-second timeout. Successful output reports the selected region and SKU,
required vCPUs, remaining quotas, and `status=ok`. Failures print a diagnostic on
stderr with exit 1, while invalid arguments return 2. CLI error messages identify
the operation to repeat directly for Azure's detailed diagnostics.

Quota, SKU restrictions, and available compute capacity can change between this
check and deployment. Azure evaluates capacity at creation. The real plan and
deployment still need to verify access policies, image and security support,
network resources, costs, and VM boot in the selected subscription.

```bash
python3 tests/test-azure-preflight.py -v
```

The tests simulate Azure CLI responses through its subprocess boundary and check
that every requested operation is a subscription-scoped read. They cover
registration, restricted sizes, both quota tiers and the exact quota boundary,
missing or malformed data, sign-in errors, and timeouts. A live subscription check
remains to be performed.

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
