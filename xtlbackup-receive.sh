#!/bin/sh

#
# This file sanitizes commands received for remote backups with xtlbackup.
# It is to be used as a shell for an authorized SSH key.
#
# To use it, prefix the relevant SSH key in /root/.ssh/authorized_keys with
# command="SNAPSHOTS_PATH='<some path regex>' /usr/sbin/xtlbackup-receive",no-port-forwarding,no-agent-forwarding,no-X11-forwarding,no-pty
#
# The regex match is attempted on the canonicalized path (only if it exists).
# Here are some examples:
#  * To match /remote_backups, SNAPSHOTS_PATH='/remote_backups'
#  * To match any given subdirectory of /remote_backups, SNAPSHOTS_PATH='/remote_backups/[^/]\+$'
#
# The following commands are allowed:
#  * ls (grep $SNAPSHOTS_PATH)
#  * btrfs receive (grep $SNAPSHOTS_PATH)
#

# Check if a given path is authorized.
validate_path() {
	if [ -z "$SNAPSHOTS_PATH" ]
	then
		>&2 echo "Error: SNAPSHOTS_PATH not set."
		exit 1
	fi

	# Extract an absolute path from $1
	CMD_PATH=$(cd "$1" 2> /dev/null && pwd)

	if ! echo "$CMD_PATH" | grep "$SNAPSHOTS_PATH" > /dev/null
	then
		>&2 echo "Error: illegal path '$1'."
		exit 1
	fi
}

# Retrieve SSH command
if [ -n "$SSH_ORIGINAL_COMMAND" ]
then
	set -- $SSH_ORIGINAL_COMMAND
fi

if [ "$1" = 'btrfs' ]
then
	if [ "$2" = 'receive' ]
	then
		if [ "$#" -ne 3 ]
		then
			>&2 echo "Error: invalid number of arguments."
			exit 1
		fi

		validate_path "$3"
		exec $@
	else
		>&2 echo "Error: unauthorized btrfs operation '$2'."
		exit 1
	fi
elif [ "$1" = 'ls' ]
then
	if [ "$#" -ne 2 ]
	then
		>&2 echo "Error: invalid number of arguments."
		exit 1
	fi

	validate_path "$2"
	exec $@
else
	>&2 echo "Error: unauthorized command '$1'."
	exit 1
fi
