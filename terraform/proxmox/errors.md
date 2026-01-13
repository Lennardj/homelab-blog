1. Even with the APi token, terraform was unable to connect and control proxmox
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