1. Encoding issue. because I am using Windows cmd which encode isn UTF-16 isn't compatible with ansible UTF-8
Ansible is:

Linux-native

SSH-based

Relies on POSIX tooling

Windows CMD:

Uses UTF-16 internally

Breaks Python CLI parsing

Causes exactly the error you saw

2. WSL is a bitch, had a big issue when docker won't start because WSL fail to start. A quick fix was to find and stop the wsl process `taskkill /F /IM wslservice.exe` but that only work temporaly. The long ter solution was to uninstall docker, and wsl. Disable wsl in services. wipe all the cache then reinstall docker, finanlly ipdate wsl.
```
wsl --shutdown
wsl --unregister <distro_name>

wsl --list --all

wsl --uninstall
```
3. Te