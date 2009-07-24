
package Proc::Parallel::HostsCommand;

use strict;
use warnings;
use Proc::Parallel;
use Tie::Function::Examples qw(%q_shell);

my $usage = <<END_USAGE;

Usage: $0 host-list-file [Options] command-to-run

Options:

	--series 	Run commands in series rather than in parallel
	-N --NNN n	Run n commands per system, replace "NNN" in command with command number
	--counter	Replace =COUNTER= and =TOTAL= with a count and total command number
	-0 		For -NNN and --counter count from zero instead of one
	--local		Do not ssh to remote systems (implies --name)
	--name		In command, replace =HOSTNAME= with the remote system name 
	--raw		Do not tag command output with hostnames
	--help		Display this message
	--33		Run at most 33 simultaneous commands (start more as others finish)

Description:

	$0 is a command to run a commmand on a bunch of systems at once.
	It requires a file that lists the remote systems.  In that file,
	multiple hosts can be put on the same line.

	If the host-list-file isn't a valid filename, $0 will try
	to find the host-list-file by looking in:
		\$DO_DOT_HOSTS_LISTS
		\$HOME/.hosts.
	It will append host-list-file to those locations.  If host-list-file
	is "cluster1", it will look for:
		\${DO_DOT_HOSTS_LISTS}cluster1
		\$HOME/.hosts.cluster1

	The options can come before or after the host-list-file. 

	If the host-list-file does not contain any slashes (/) then it will not
	look in the current directory for it.

Examples:

	do.hosts cluster1 uptime
	do.hosts cluster1 -N 2 echo NNN
	do.hosts cluster1 --counter echo =COUNTER=
	do.hosts cluster1 --local scp access_log =HOSTNAME=:/data/david/dsl
	do.hosts cluster1 --raw cat /data/david/dsl | wc
	do.hosts cluster1 --local scp =HOSTNAME=:/data/david/dsl foo.=HOSTNAME=
	do.hosts cluster1 --local --counter scp =HOSTNAME=:/data/david/dsl foo.=COUNTER=

END_USAGE

our @more_places_to_look = ();

sub run
{
	my (@argv) = @_;


	my $series;
	my $NNN = 0;
	my $zero;
	my $host_list;
	my $local;
	my $name;
	my $counter;
	my $raw;
	my $simultaneous = 0;


	while (@argv && (($argv[0] =~ /^-/) || ! $host_list)) {
		my $a = shift @argv;
		if ($a =~ /^(?:-s|--series|--single)$/) {
			$series = 1;
		} elsif ($a =~ /^(?:-N|--NNN)$/) {
			$NNN = shift @argv;
			die "NNN requires an integer\n$usage"
				unless $NNN =~ /^\d+$/;
		} elsif ($a =~ /^--?l(?:ocal)?$/) {
			$local = 1;
			$name = 1;
		} elsif ($a =~ /^--?r(?:aw)?$/) {
			$raw = 1;
		} elsif ($a =~ /^--?n(?:ame)?$/) {
			$name = 1;
		} elsif ($a =~ /^--?h(?:elp)?$/) {
			print $usage;
			exit 0;
		} elsif ($a =~ /^--?c(?:ounter)?$/) {
			$counter = 1;
		} elsif ($a =~ /^-?-0$/) {
			$zero = 1;
		} elsif ($a =~ /^-?-(\d+)$/) {
			$simultaneous = $1;
		} elsif ($a =~ /^-/) {
		} elsif ($a =~ /^-/) {
			die "Unknown flag: $a\n$usage";
		} elsif (! $host_list) {
			$host_list = $a;
		} else {
			die;
		}
	}
	die "need to specify a host list and a command\n$usage" unless $host_list;
	die "need to specify a command\n$usage" unless @argv;

	PLACE:
	for(;;) {
		last if $host_list =~ m{/} && -f $host_list;

		my @hlp = ("$ENV{HOME}/.hosts.", @more_places_to_look);
		unshift(@hlp, "$ENV{DO_DOT_HOSTS_LISTS}")
			if $ENV{DO_DOT_HOSTS_LISTS};

		for my $p (@hlp) {
			next unless -f "$p$host_list";
			$host_list = "$p$host_list";
			last PLACE;
		}

		die "need a hosts lists file\n$usage";
	}

	open my $hl, "<", $host_list
		or die "open $host_list: $!";

	my @hosts;

	while (<$hl>) {
		chomp;
		s/#.*//;
		next if /^\s*$/;
		push(@hosts, grep { /\S/ } split(/\s+/, $_));
	}

	close($hl);

	my $n = $NNN || 1;

	my @todo_list;
	my $running = 0;

	my $total = $n * @hosts;
	my $count = $zero ? 0 : 1;
	for my $nnn (1..$n) {
		for my $host (@hosts) {
			my $command = join(' ', map { $q_shell{$_} } @argv);
			$command = $argv[0] if @argv == 1;
			my $sub = '';
			if ($NNN) {
				$sub = $nnn;
				$sub -= 1 if $zero;
				$command =~ s/NNN/$sub/g;
				$sub = "-$sub";
			} 
			if ($name) {
				$command =~ s/=HOSTNAME=/$host/g;
			}
			if ($counter) {
				$command =~ s/=COUNTER=/$count/g;
				$command =~ s/=TOTAL=/$total/g;
				$count++;
			}
			$command = "ssh -o StrictHostKeyChecking=no $host -n $q_shell{$command}"
				unless $local;

			my $header = "$host$sub:\t";
			$header = '' if $raw;

			my $per_line = sub {
				my ($handler, $ioe, $input_buffer_reference) = @_;
				while (<$ioe>) {
					print "$header$_";
				}
			};
			my $finished = sub {
				my ($handler, $ioe, $input_buffer_reference) = @_;
				print "$header$$input_buffer_reference\n"
				if length($$input_buffer_reference);
				$running--;
				if (@todo_list) {
					start_command( @{shift @todo_list} );
					$running++;
				}
			};

			if ($series) {
				print "+ $command\n";
				system($command);
			} elsif ($simultaneous && $running >= $simultaneous) {
				push(@todo_list, [ "$command 2>&1", $per_line, $finished ]);
			} else {
				start_command("$command 2>&1", $per_line, $finished );
				$running++;
			}
		}
	}

	finish_commands() unless $series;
}

1;

__END__

=head1 LICENSE

This package may be used and redistributed under the terms of either
the Artistic 2.0 or LGPL 2.1 license.

