# xtlbackup

`xtlbackup` is a program for managing snapshots, backups and replications of btrfs subvolumes written in Perl.

## Principles of operation

`xtlbackup` works with the following workflow (most steps are optional):
* Snapshots of subvolumes are taken in a snapshot zone ;
* A backup of the snapshot zone is replicated on a separate btrfs filesystem ;
* A backup of the snapshot zone is replicated on a remote system through SSH ;
* Old snapshots are pruned from the snapshot zone.

The workflow is specified in one or more JSON configuration files.

## Installing dependencies

On Debian-like systems, run:

`apt-get install libipc-run-perl libjson-perl`
