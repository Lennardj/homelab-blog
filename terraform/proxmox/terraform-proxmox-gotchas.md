# An AI refinied list of issue i faced.  


1\. Proxmox API Tokens Require Explicit ACLs
--------------------------------------------

**Gotcha**API tokens do **not** inherit permissions from the user they belong to.

**Impact**

*   Terraform fails to create or manage resources
    
*   Errors may appear unrelated to authentication
    

**Rule**

> Always assign ACLs directly to the API token at the correct scope(e.g. /, /nodes, /vms, /storage).

2\. Do Not Mix Proxmox Terraform Providers
------------------------------------------

**Gotcha**bpg/proxmox and Telmate/proxmox expose similarly named resources but are **not compatible**.

**Impact**

*   Schema mismatches
    
*   Unexpected behaviour
    
*   Failed plans or applies
    

**Rule**

> Choose **one** provider per project and standardise on it.

3\. Proxmox API URL Must End with /api2/json
--------------------------------------------

**Gotcha**Using:

`   https://host:8006   `

instead of:

`   https://host:8006/api2/json   `

**Impact**

*   Terraform errors like 501 no such file '/users'
    
*   API appears reachable but fails on operations
    

**Rule**

> Always use the full Proxmox API endpoint.

4\. Disk Shrink During Clone Detaches the OS Disk (unused0)
-----------------------------------------------------------

**Gotcha**Proxmox **cannot shrink disks** during a clone operation.

**Impact**

*   Original OS disk is detached as unused0
    
*   Terraform creates a new blank disk
    
*   VM starts but has **no OS to boot**
    

**Symptoms**

*   scsi0 exists but system does not boot
    
*   unused0 appears in qm config
    

**Rule**

> Requested VM disk size must be **greater than or equal to the template disk size**.

5\. Cloud-Init Settings Do Not Reliably Inherit from Templates
--------------------------------------------------------------

**Gotcha**Cloud-init values such as passwords and package upgrades are **per-VM**, not guaranteed to inherit.

**Impact**

*   Missing passwords
    
*   ciupgrade resets to default
    
*   Confusing provisioning state
    

**Rule**

> Explicitly declare all required cloud-init values in Terraform.

6\. Terraform Can Remove Hardware Inherited from Templates
----------------------------------------------------------

**Gotcha**Terraform reconciles infrastructure to its declared state and may **remove undeclared devices**.

**Impact**

*   OS disks detached
    
*   Serial ports removed
    
*   VGA configuration broken
    

**Rule**

> Declare **all critical hardware explicitly** if your workload depends on it.

7\. Serial Console ≠ VGA Console (Cloud Images)
-----------------------------------------------

**Gotcha**Most cloud images boot primarily to **serial console**, not VGA.

**Impact**

*   noVNC shows flashing or blank screen
    
*   VM appears “hung” while actually running
    

**Rule**

> Use:

`qm terminal` 

or explicitly configure VGA + serial devices.

8\. Terraform Is Not a VM Power Manager
---------------------------------------

**Gotcha**Terraform is declarative and does not reliably manage runtime state.

**Impact**

*   VMs may stop on re-apply
    
*   Terraform “fixes” state unintentionally
    

**Rule**

> Use Terraform for provisioning, not lifecycle orchestration.Handle runtime behaviour via Proxmox or post-provisioning scripts.

9\. Terraform Cannot Reliably Discover DHCP IPs on Proxmox
----------------------------------------------------------

**Gotcha**The Telmate provider does not reliably expose DHCP-assigned IP addresses.

**Impact**

*   Missing or empty Terraform outputs
    
*   Broken downstream automation
    

**Rule**

> Use qemu-guest-agent and query Proxmox directly(e.g. qm agent network-get-interfaces).

10\. Cloud-Init Features Require Cloud-Init OS Type
---------------------------------------------------

**Gotcha**Cloud-init features silently fail if the VM OS type is not set correctly.

**Impact**

*   SSH keys not injected
    
*   User configuration ignored
    

**Rule**

> os\_type = "cloud-init" is mandatory when using cloud-init.

## Guest Agent Is Mandatory for Reliable IP Outputs

**Gotcha**  
Terraform can only retrieve VM IP addresses from Proxmox if the QEMU guest agent
is installed and running **inside the guest OS**.

**Symptoms**
- Terraform outputs for IPs are empty (`""`)
- `terraform apply` succeeds but networking outputs are missing
- `terraform plan --refresh-only` suddenly populates IPs *after* manual agent install

**Root Cause**
The VM template did not have `qemu-guest-agent` installed.
While `agent = 1` was enabled in Proxmox, no guest-side service was available
to report runtime network state.

**Fix**
Bake the guest agent into the template *before* converting it:

```bash
sudo apt update
sudo apt install -y qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
sudo cloud-init clean --logs
sudo shutdown -h now
```