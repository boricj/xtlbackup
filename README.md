# xtlbackup

`xtlbackup` is a program for managing snapshots, backups and replications of btrfs subvolumes written in Perl.

## Principles of operation

`xtlbackup` works with the following workflow (all steps are optional):
* Timestamped snapshots of subvolumes are taken in a snapshot zone ;
* Backups of the snapshot zones are replicated on a separate btrfs filesystem ;
* Backups of the snapshot zones are replicated on a remote system through SSH ;
* Old snapshots are pruned from the snapshot zones _in lexicographical order_.

The workflow is specified in one or more JSON configuration files:

```
# /etc/xtlbackup-sample.json
[
  # Job declaration block
  {
    "snapshots":        "/snapshots/root-%Y-%m-%d-%H%M%S", # Snapshot zone with UNIX-style date format, mandatory

    "subvolume":        "/root",                           # Subvolume to snapshot
    "keep_max":         10,                                # Maximum number of snapshots to keep

    "backups":          "/backups/root-%Y-%m-%d-%H%M%S",   # Replicate snapshots on separate filesystem
    "keep_backups_max": 30,                                # Maximum number of backups to keep

    "remote_host":      "root@nas.example.com",            # Replicate snapshots on remote host
    "remote_id":        "/root/.ssh/id_rsa_backup",        # SSH key for identification
    "remote_backups":   "/remote_backups"                  # Where to replicate on the remote host
  },

  # Another job - no remote replications
  {
    "snapshots":        "/snapshots/home/%Y-%m-%d",        # Snapshot zone inside dedicated directory

    "subvolume":        "/home",
    "keep_max":         7,

    "backups":          "${HOME_BACKUPS_LOCATION}",        # Environment ${variables} can be used too
    "keep_backups_max": 15
  }
]
```

`xtlbackup /etc/xtlbackup-sample.json` will then take care of everything. If you want snapshots, replications and pruning to happen separately, split jobs into separate JSON files.

## Installing dependencies

On Debian-like systems, run:

`# apt-get install libipc-run-perl libjson-perl`

On other systems, you can try CPAN:

```
# cpanm IPC::Run
# cpanm JSON
```

## Why xtlbackup?

* It's dead-simple.
* It's powerful.
* It does not force you into a specific way of doing your backups or laying out your subvolumes.

Suprisingly enough, all the btrfs-based backup solutions I've tried so far fail at least one of these principes.
