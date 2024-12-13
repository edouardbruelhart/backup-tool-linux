# Operations that should still be performed with this tool

- Manage "failed: Operation not permitted (1)" errors of rsync -> Probably ignore these files as they are configuration files or environment files, more linked to sofwares than user data
- Modify the backup-tool -n to add only one drive at a time. If the user wants multiple drives he will run this command multiple times
- Implement backup-tool -m to modify the setup
- Add the possibility to create a complete snapshot of the disk in order to restore same session on any machine if needed
- Let the user choose to format the disk or not if he selects a drive that has already been setup (for example if user wants to make classic backup and snapshot on the same disk)