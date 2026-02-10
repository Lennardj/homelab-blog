1. Encoding issue. because I am using Windows cmd which encode isn UTF-16 isn't compatible with ansible UTF-8
Ansible is:

Linux-native

SSH-based

Relies on POSIX tooling

Windows CMD:

Uses UTF-16 internally

Breaks Python CLI parsing

Causes exactly the error you saw