# Example Project (shared folder)

This directory is mounted inside the VM via virtiofs (`tag: project` → `/mnt/project` on Linux).

Try after `spinoza up`:

```bash
spinoza ssh
ls /mnt/project
cat /mnt/project/hello.txt
```

Edit files on the host — changes are visible instantly in the guest.
