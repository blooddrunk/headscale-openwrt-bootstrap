# Milestone 1 checks

`test-milestone1.sh` uses fixture roots and fake read-only commands.  It checks
syntax, JSON output, the unsafe LuCI helper fingerprint, hard-stop behavior for
different ControlURLs, and private backup manifests.  The test deliberately
does not invoke any target init script.

