1. After the permission error in wsl i moved to using windows exclusively. I had a encoding Encoding issue because of that. windows encode isn UTF-16 and isn't compatible with ansible which is linux and encodes in UTF-8

2. WSL is a bitch, had a big issue when docker won't start because WSL fail to start. A quick fix was to find and stop the wsl process `taskkill /F /IM wslservice.exe` but that only work temporaly. The long ter solution was to uninstall docker, and wsl. Disable wsl in services. wipe all the cache then reinstall docker, finanlly ipdate wsl.
```
wsl --shutdown
wsl --unregister <distro_name>

wsl --list --all

wsl --uninstall
```
3. 