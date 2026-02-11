# My rough draft writing 

1. Even with the terraform was unable to connect and control proxmox
- This was due to the fact that each api token token needs to have it own permmision to access the cluster
Errors Encountered So Far (Terraform / Proxmox)

2. Provider mismatch I mixed up the bpg/proxmox and Telmate/proxmox while using proxmox_vm_qemu, i ended up going with telmate as it was easier in my opinion.

3. Split API token variables vs provider expectations

Telmate requires pm_api_token_id + pm_api_token_secret; wrong variable used at one point.

4. Incorrect Proxmox API URL

Missing /api2/json caused 501 no such file '/users'.

5. os type = l26 not 126
l26 represent ubuntu
he code breaks down as follows:
"l": Stands for Linux.
"26": Historically refers to Linux Kernel version 2.6. 
6. sshkeys = var,ssh_public_key
this can only work if i am using cloud init
7. boot order
pay attention to the name proxmox give to the boot device for me it was ide2
"order=scsi0;ide2;net0"
8. storage
the iso storage and the disk storage has to be in differnce places

9. accidentally push the .terraform file has to do a hard reset and deleter the .git file 
10. vm won't auto start, can't be done unless i create
11. Fucking VScode give me a rediculous error, the kubernetes schema for YAML was installed but not the docker compose one. This cause the `docker-compse.yaml` to give a error with services at the top level.
I had to install it by going to `setting.json` in vscode and adding `"https://raw.githubusercontent.com/compose-spec/compose-spec/master/schema/compose-spec.json": "docker-compose.test.yaml"`
12. Fucking hashicorp/terraform entry point. My docker compose ran well but the terraform container didn't do it's thing. When i check the logs `docker compose logs -f terraform` i notices that it is saying terraform doesn't have a blah blah meaning what ever command i was running blooding terraform was appended in from. ad and entry point to fix `  entrypoint: ["/bin/sh", "-lc"]`
13. Docker `entrypoint` and `command` these  two just trip me up and it cost me two days, can't for the life of me figure out why the command on the terraform image wasn't working, even after changing the entrypoint to /bin/sh. Anyways, I just added the command I wanted directly in the entry point
14. 





# Refined by AI below

1\. Terraform could not connect to Proxmox despite valid API token
------------------------------------------------------------------

**Problem**Terraform failed to authenticate or perform actions against Proxmox, even though an API token was configured.

**Root Cause**In Proxmox, **API tokens do not inherit user permissions automatically**. Each token requires explicit permissions on the relevant scope (e.g. /, /vms, /nodes, /storage).

**Fix / Lesson**

*   Assign proper ACLs directly to the API token.
    
*   Do not assume user-level permissions apply to tokens.
    

2\. Provider mismatch: bpg/proxmox vs Telmate/proxmox
-----------------------------------------------------

**Problem**Terraform configuration mixed resources from different Proxmox providers.

**Root Cause**proxmox\_vm\_qemu was used while alternating between:

*   bpg/proxmox
    
*   Telmate/proxmox
    

Each provider has different schemas and expectations.

**Fix / Lesson**

*   Standardised on **Telmate/proxmox** for simplicity and documentation maturity.
    
*   Never mix providers for the same resource type.
    

3\. API token variables did not match provider expectations
-----------------------------------------------------------

**Problem**Terraform failed during provider initialization.

**Root Cause**Telmate requires:

*   pm\_api\_token\_id
    
*   pm\_api\_token\_secret
    

At one point, incorrect variable names were used.

**Fix / Lesson**

*   Always align variable names exactly with provider documentation.
    
*   Do not “guess” provider input fields.
    

4\. Incorrect Proxmox API URL
-----------------------------

**Problem**Terraform returned:

`   501 no such file '/users'   `

**Root Cause**The Proxmox API URL was missing the required suffix:

`   /api2/json   `

**Fix / Lesson**

*   https://:8006/api2/json
    
*   Proxmox API will partially respond even with invalid paths, which can be misleading.
    

5\. Incorrect OS type value (l26 vs 126)
----------------------------------------

**Problem**Terraform failed when setting os\_type.

**Root Cause**A typo caused os\_type = 126 instead of l26.

**Explanation**

*   l → Linux
    
*   26 → historical reference to Linux kernel 2.6
    

**Fix / Lesson**

*   os\_type = "l26" is correct for Ubuntu.
    
*   Small typos in low-level VM config cause hard failures.
    

6\. SSH keys only work with cloud-init
--------------------------------------

**Problem**sshkeys = var.ssh\_public\_key had no effect.

**Root Cause**SSH keys are only injected when **cloud-init is enabled**.

**Fix / Lesson**

*   os\_type = "cloud-init"
    
*   SSH key injection is a cloud-init feature, not a generic Proxmox feature.
    

7\. Boot order device names must match Proxmox naming
-----------------------------------------------------

**Problem**VMs failed to boot with “device does not exist” errors.

**Root Cause**Boot order referenced incorrect device names.

**Example**

`   order=scsi0;ide2;net0   `

In this setup:

*   scsi0 = OS disk
    
*   ide2 = cloud-init disk
    

**Fix / Lesson**

*   qm config
    

8\. ISO storage and disk storage must be different
--------------------------------------------------

**Problem**VM creation or disk import failed.

**Root Cause**ISO images and VM disks were placed on incompatible or identical storage backends.

**Fix / Lesson**

*   Use:
    
    *   local (or similar) for ISOs
        
    *   local-lvm, ZFS, or Ceph for VM disks
        
*   Understand Proxmox storage capabilities.
    

9\. Accidentally committed .terraform/ directory
------------------------------------------------

**Problem**Terraform state and provider binaries were committed to Git.

**Root Cause**Missing .gitignore entry.

**Fix / Lesson**

*   Performed a hard reset and cleaned Git history.
    
*   Added .terraform/ to .gitignore.
    
*   Terraform state should **never** be committed unless explicitly intended (e.g. remote backend).
    

10\. VM did not auto-start after Terraform apply
------------------------------------------------

**Problem**VMs were created but did not start automatically.

**Root Cause**Terraform cannot reliably auto-start VMs in Proxmox without:

*   explicit onboot configuration, or
    
*   external orchestration.
    

**Fix / Lesson**

*   VM startup is better handled by:
    
    *   Proxmox onboot, or
        
    *   a post-provisioning script
        
*   Terraform’s role is provisioning, not lifecycle orchestration.

### 11\. Disk shrink during clone causes OS disk detachment (unused0)

**This is the single most important Proxmox lesson you learned.**

**What happened**

*   Template OS disk was ~68 GB
    
*   Terraform requested smaller disks (35 GB / 50 GB)
    
*   Proxmox cannot shrink disks
    
*   Provider detached the real OS disk as unused0
    
*   A new blank disk was attached as scsi0
    
*   VM “started” but had no OS to boot
    

**Why this matters**

*   This is a _classic Proxmox + Terraform footgun_
    
*   Explains boot failures that look like BIOS or cloud-init issues
    

**You should explicitly document**

*   Template disk size must be ≤ requested VM disk size
    
*   Terraform may silently detach disks instead of failing
    

### 12\. Cloud-init settings do **not** reliably inherit from templates

You noticed this but didn’t write it explicitly.

**What happened**

*   Template had password + ciupgrade=1
    
*   Cloned VMs showed:
    
    *   ciupgrade: 0
        
    *   no cipassword
        

**Lesson**

*   Cloud-init values are **per-VM**, not truly inherited
    
*   Terraform must explicitly set:
    
    *   ciupgrade
        
    *   cipassword _or_ sshkeys
        

This is a subtle but very real production issue.

### 13\. Terraform can remove hardware devices inherited from templates

This is a _huge_ insight you uncovered.

**What happened**

*   Template had serial0: socket
    
*   Terraform clone removed the serial device
    
*   VM had vga: serial0 but **no serial device**
    
*   Console looped / flashed / showed nothing
    
*   qm terminal failed until serial was re-added
    

**Lesson**

*   Terraform reconciles “desired state”
    
*   Undeclared devices may be **deleted**, even if present in the template
    
*   Critical devices (disks, serial, VGA) should be explicitly declared if relied upon
    

### 14\. Serial console vs VGA console confusion

This deserves its own entry.

**What happened**

*   Cloud image used vga: serial0
    
*   No Proxmox splash screen appeared
    
*   noVNC showed reconnect loops
    
*   VM _was running_, just not visible on VGA
    

**Lesson**

*   Cloud images often boot to **serial console only**
    
*   qm terminal or explicitly configure VGA
    

This is a classic cloud-image pitfall.

### 15\. Terraform cannot reliably retrieve DHCP IPs from Proxmox

You’re literally fixing this now — it should be documented.

**What happened**

*   Terraform could not expose VM IPs
    
*   proxmox\_vm\_qemu does not reliably return DHCP addresses
    
*   Even with qemu-guest-agent, provider support is inconsistent
    

**Lesson**

*   IP discovery requires:
    
    *   Proxmox qm agent network-get-interfaces
        
    *   external script or post-provisioning step
        
*   Terraform alone is insufficient here