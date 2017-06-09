#!/usr/bin/env perl

use strict;

use File::Basename;
use Getopt::Std;
use IPC::Run 'run';
use JSON;
use POSIX 'strftime';

my %tools;

# Lists of jobs to do
my @snapshot_jobs;
my @backup_jobs;
my @remote_backup_jobs;
my @prune_jobs;

#
# Cleanup functions on error.
#

# Command to launch in case everything goes horribly wrong.
my @cleanup_cmd;

local $SIG{__DIE__} = sub {
	my $message = shift;
	print STDERR $message;

	if ($#cleanup_cmd) {
		print "Error detected, running cleanup command\n";
		run @cleanup_cmd;
		@cleanup_cmd = undef;
	}

	exit 1;
};

sub signal_cleanup {
	print "Interrupted by signal\n";

	if ($#cleanup_cmd) {
		run @cleanup_cmd;
		@cleanup_cmd = undef;
	}

	exit 1;
}

use sigtrap qw(handler signal_cleanup normal-signals error-signals);

#
# Detect tools.
#
sub detect_tools {
	my @tools_list = qw(btrfs ssh);
	my @locations = qw(/bin /sbin /usr/bin /usr/sbin /usr/local/bin /usr/local/sbin);

	# Scan tools locations
	foreach my $tool (@tools_list) {
		foreach my $location (@locations) {
			if (-e "$location/$tool") {
				$tools{$tool} = "$location/$tool";
			}
		}
	}

	# Check if all tools were found
	foreach my $tool (@tools_list) {
		die "Error: can't find executable $tool" if ! exists $tools{$tool};
	}
}

#
# Given two sorted lists of snapshots, return instructions for replicating
# snapshots from source to target.
#
sub compute_backup_work {
	my @source_snapshots = @{@_[0]};
	my %target_snapshots = map {$_ => 1 } @{@_[1]};

	my @missing_snapshots;
	my $common_snapshot;

	my $target = $_[2];

	# Build list of missing snapshots
	LOOP: foreach my $snapshot (@source_snapshots) {
		my $dir_snapshot = dirname($snapshot);
		my $name_snapshot = basename($snapshot);

		# Check if snapshot is already at target
		if (exists $target_snapshots{"$target/$name_snapshot"}) {
			# If there's no missing snapshots, we can use it as a base
			if (! @missing_snapshots) {
				$common_snapshot = $snapshot;
			}

			next LOOP;
		}
		# Snapshot missing, add it to the list
		else {
			push @missing_snapshots, $snapshot;
		}
	}

	return ($common_snapshot, @missing_snapshots);
}

#
# Run snapshot jobs.
#
sub run_snapshot_jobs {
	print "Performing snapshotting jobs...\n";

	LOOP: foreach (@snapshot_jobs) {
		my $dest = strftime($$_{'to'}, localtime);

		# Skip snapshot if it already exists
		if (-e $dest) {
			next LOOP;
		}

		# Do snapshot
		my @cmd = ($tools{'btrfs'}, 'subvolume', 'snapshot', '-r', $$_{'from'}, $dest);
		run \@cmd or die "Error: snapshot job failed";
	}
}

#
# Run backup jobs.
#
sub run_backup_jobs {
	print "Performing backup jobs...\n";

	foreach (@backup_jobs) {
		my $target = $$_{'to'};
		$$_{'from'} =~ /^(.*?)%/;

		# Grab lists of snapshots
		my @source_snapshots = sort glob ("$1*");
		my @target_snapshots = sort glob ("$target/*");

		my ($common_snapshot, @missing_snapshots) = compute_backup_work(\@source_snapshots, \@target_snapshots, $target);

		# Transfer missing snapshots
		foreach my $snapshot (@missing_snapshots) {
			my @send;
			my @receive = ($tools{'btrfs'}, 'receive', $target);

			if (defined $common_snapshot) {
				# Incremental send
				print "Incremantal send\n";
				@send = ($tools{'btrfs'}, 'send', '-p', $common_snapshot, $snapshot);
			}
			else {
				# Full send
				print "Full send\n";
				@send = ($tools{'btrfs'}, 'send', $snapshot);
			}

			# Do send/receive
			@cleanup_cmd = ($tools{'btrfs'}, 'subvolume', 'delete', $target . '/' . basename($snapshot));
			run \@send, '|', \@receive or die "Error: backup job failed";
			@cleanup_cmd = undef;

			$common_snapshot = $snapshot;
		}
	}
}

#
# Run remote_backup jobs.
#
sub run_remote_backup_jobs {
	print "Performing remote backup jobs...\n";

	foreach (@remote_backup_jobs) {
		my $target = $$_{'to'};
		my $identity = $$_{'id'};
		my $host = $$_{'host'};

		# Grab list of snapshots at remote
		my @remote_glob = ($tools{'ssh'}, '-oBatchMode=yes', '-i', $identity, $host, 'ls', $target);
		my $remote_glob_result;
		run \@remote_glob, '>', \$remote_glob_result or die "Error: remote backup job failed";

		my @target_snapshots = split ' ', $remote_glob_result;
		my @target_snapshots = sort map "$target/$target_snapshots[$_]", 0..$#target_snapshots;

		# Grab list of local snapshots
		$$_{'from'} =~ /^(.*?)%/;
		my @source_snapshots = sort glob ("$1*");

		my ($common_snapshot, @missing_snapshots) = compute_backup_work(\@source_snapshots, \@target_snapshots, $target);

		# Transfer missing snapshots
		foreach my $snapshot (@missing_snapshots) {
			my @send;
			my @ssh = ($tools{'ssh'}, '-C', '-oBatchMode=yes', '-i', $identity, $host, 'btrfs', 'receive', $target);

			if (defined $common_snapshot) {
				# Incremental send
				print "Incremantal send\n";
				@send = ($tools{'btrfs'}, 'send', '-p', $common_snapshot, $snapshot);
			}
			else {
				# Full send
				print "Full send\n";
				@send = ($tools{'btrfs'}, 'send', $snapshot);
			}

			# Do remote send/receive
			run \@send, '|', \@ssh or die "Error: remote backup job failed";

			$common_snapshot = $snapshot;
		}
	}
}

#
# Run prune jobs.
#
sub run_prune_jobs {
	print "Performing pruning jobs...\n";

	foreach (@prune_jobs) {
		# Grab reverse list of snapshots
		$$_{'target'} =~ /^(.*?)%/;
		my @targets = sort {$b cmp $a } glob ("$1*");

		my $keep_max = $$_{'keep_max'};

		while (scalar @targets > $keep_max) {
			my $target = pop @targets;

			# Do snapshot pruning
			my @cmd = ($tools{'btrfs'}, 'subvolume', 'delete', $target);
			run \@cmd or die "Error: prune job failed";
		}
	}
}

#
# Validate a configuration object before using it.
#
sub validate_config_object {
	my %valid_tags = (
	    'backups' => 'SCALAR',
	    'keep_max' => 'SCALAR',
	    'remote_backups' => 'SCALAR',
	    'remote_host' => 'SCALAR',
	    'remote_id' => 'SCALAR',
	    'snapshots' => 'SCALAR',
	    'subvolume' => 'SCALAR'
	) ;

	my $key, my %obj;

	# Check object syntax
	if (ref($_[0]) ne 'HASH') {
		die 'Error: expecting object configuration file, got ' . ref($_[0]);
	}

	# Grab object to check
	%obj = %{$_[0]};

	foreach $key (keys %obj) {
		# Check if key is known
		if (! exists $valid_tags{$key}) {
			die "Error: unknown key \"$key\"";
		}

		# Check if key has correct type
		my $keytype = %obj{$key};
		if (ref(\$keytype) ne $valid_tags{$key}) {
			die "Error: key \"$key\" must be of type $valid_tags{$key}, got " . ref(\$keytype);
		}
	}

	# 'snapshots' keyword is required
	if (! (exists $_[0]{'snapshots'})) {
		die 'Error: missing mandatory "snapshots" key';
	}

	# Remote backup keys must be either all present or none present
	my $remote_count = (exists $_[0]{'remote_backups'}) + (exists $_[0]{'remote_host'}) + (exists $_[0]{'remote_id'});

	if ($remote_count != 0 and $remote_count != 3) {
		die 'Error: all keys "remote_backups", "remote_host" and "remote_id" are mandatory for remote backups';
	}
}

#
# Parse a configuration object and populate job lists.
#
sub parse_config_object {
	# Subvolume job
	if (exists $_[0]{'subvolume'}) {
		my %job = (
		    'from' => $_[0]{'subvolume'},
		    'to' => $_[0]{'snapshots'}
		);

		push @snapshot_jobs, \%job;
	}

	# Backup job
	if (exists $_[0]{'backups'}) {
		my %job = (
		    'from' => $_[0]{'snapshots'},
		    'to' => $_[0]{'backups'}
		);

		push @backup_jobs, \%job;
	}

	# Remote backup job
	if (exists $_[0]{'remote_backups'}) {
		my %job = (
		    'from' => $_[0]{'snapshots'},
		    'to' => $_[0]{'remote_backups'},
			'host' => $_[0]{'remote_host'},
			'id' => $_[0]{'remote_id'}
		);

		push @remote_backup_jobs, \%job;
	}

	# Prune job
	if (exists $_[0]{'keep_max'}) {
		my %job = (
		    'target' => $_[0]{'snapshots'},
		    'keep_max' => $_[0]{'keep_max'}
		);

		push @prune_jobs, \%job;
	}
}

#
# Parse a configuration file.
#
sub parse_config_file {
	my $json, my $fileconf, my $dataconf, my $dataitem;

	# Read config file into memory
	{
		local $/ = undef;
		open FILE, $_[0] or die "Couldn't open $_[0]: $!";
		binmode FILE;
		$fileconf = <FILE>;
		close FILE;
	}

	# Parse JSON
	$json = JSON->new;
	$json->relaxed(1);
	$dataconf = $json->decode($fileconf);

	if (ref($dataconf) eq 'ARRAY') {
		# Parse array of objects
		foreach $dataitem (@$dataconf) {
			validate_config_object $dataitem;
			parse_config_object $dataitem;
		}
	}
	else {
		# Parse a single object
		validate_config_object $dataconf;
		parse_config_object $dataconf;
	}
}

#
# Main program.
#

detect_tools();

if (! defined $ARGV[0]) {
	parse_config_file('/etc/xtlbackup.json');
}
else {
	foreach (@ARGV)
	{
		parse_config_file $_;
	}
}

run_snapshot_jobs();
run_backup_jobs();
run_remote_backup_jobs();
run_prune_jobs();
