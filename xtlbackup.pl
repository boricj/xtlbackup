#/usr/bin/env perl

use strict;

use Getopt::Std;
use IPC::Run 'run';
use JSON;
use POSIX 'strftime';

my %tools;

my @snapshot_jobs;
my @prune_jobs;

my %options;

#
# Detect tools.
#
sub detect_tools {
	my @tools_list = qw(btrfs);
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
		print STDERR "Found tool $tool at $tools{$tool}.\n" if defined $options{v};
	}
}

#
# Run snapshot jobs.
#
sub run_snapshot_jobs {
	foreach (@snapshot_jobs) {
		my $dest = strftime($$_{'to'}, localtime);

		my @cmd = ($tools{'btrfs'}, 'subvolume', 'snapshot', '-r', $$_{'from'}, $dest);

		print "Snapshotting '$$_{'from'}' to '$dest'.\n" if defined $options{v};

		if (! defined $options{d}) {
			run \@cmd or die "Error: snapshot job failed";
		}
	}
}

#
# Run prune jobs.
#
sub run_prune_jobs {
	foreach (@prune_jobs) {
		$$_{'target'} =~ /^(.*?)%/;
		my @targets = sort {$b cmp $a } glob ("$1*");

		while (scalar @targets > $keep_max) {
			my $target = pop @targets;

			print "Pruning '$target'.\n" if defined $options{v};

			my @cmd = ($tools{'btrfs'}, 'subvolume', 'delete', $target);

			if (! defined $options{d}) {
				run \@cmd or die "Error: prune job failed";
			}
		}
	}
}

#
# Check if a configuration object is correct.
#
# $_[0]: object to check
sub check_config_object {
	my %valid_tags = (
	    'keep_max' => 'SCALAR',
	    'snapshot_to' => 'SCALAR',
	    'subvolume' => 'SCALAR'
	) ;
	my $key, my %obj;

	# Check object syntax
	if (ref($_[0]) ne 'HASH') {
		die 'Error: expecting object configuration file, got ' . ref($_[0]);
	}

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

	# Check object semantics
	if (! exists $_[0]{'subvolume'}) {
		die 'Error: missing mandatory "subvolume" key';
	}

	if (! exists $_[0]{'snapshot_to'}) {
		die 'Error: missing mandatory "snapshot_to" key';
	}
}

#
# Parse a configuration object.
#
# $_[0]: object to parse
sub parse_config_object {
	if (exists $_[0]{'snapshot_to'}) {
		my %job = (
		    'from' => $_[0]{'subvolume'},
		    'to' => $_[0]{'snapshot_to'}
		);

		push @snapshot_jobs, \%job;
	}

	if (exists $_[0]{'keep_max'}) {
		my %job = (
		    'target' => $_[0]{'snapshot_to'},
		    'keep_max' => $_[0]{'keep_max'}
		);

		push @prune_jobs, \%job;
	}
}

#
# Parse a configuration file.
#
# $_[0]: path to file
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

	# Parse JSON object
	if (ref($dataconf) eq 'ARRAY') {
		foreach $dataitem (@$dataconf) {
			check_config_object $dataitem;
			parse_config_object $dataitem;
		}
	}
	else {
		check_config_object $dataconf;
		parse_config_object $dataconf;
	}
}

#
# Main program.
#

detect_tools();

# Process command line.
getopts('dv', \%options);

print STDERR "Dry-run mode on, no modifications will be made.\n" if defined $options{d};

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
run_prune_jobs();
