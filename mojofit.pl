#!/usr/bin/perl

use strict;
use File::Util;
use Data::Dumper;
use Mojo::DOM;
use List::Util qw(first max maxstr min minstr reduce shuffle sum);
use List::MoreUtils qw(all);
use DateTime;
use DateTime::Format::DateParse;
use Data::Google::Visualization::DataTable;
use JSON;
use JSON::XS;

# Config
our @POWERLIFTS = ('Barbell Squat', 'Barbell Bench Press', 'Barbell Deadlift', 'Standing Barbell Shoulder Press (OHP)', 'Pendlay Row');
our %POWERSET = map {$_ => 1} (@POWERLIFTS);

# Util objects
my($f) = File::Util->new();
#my $fitdtparse = DateTime::Format::Strptime->new( pattern => '%d %b, %Y' );

my $jsonStream=$f->load_file('ironjesus.json');
my @streamItem = @{decode_json($jsonStream)};

filterPowerlifts(\@streamItem);
filterMaxWeight(\@streamItem);
filterSetReps(\@streamItem, 1, 1);
print powerTableMax(\@streamItem);
exit;
# Display
foreach my $item (@streamItem) {
	print $item->{date}->date. "\n";
	foreach my $action (@{$item->{actions}}) {
		print " *$action->{name}*\n";
		foreach my $set ($action->{sets}) {
			printSets($set);
		}
	}
	print "\n";
}

sub powerTableMax {
	my $streamItems = shift;
	my $datatable = Data::Google::Visualization::DataTable->new();
	my @powercols = map { {id=>'', label=>$_, type=>'number'}} @POWERLIFTS;
	 $datatable->add_columns(
	        { id => 'date',     label => "Date",        type => 'date', p => {}},
	        @powercols,
	 );

	 foreach my $item (@$streamItems) {
		 my @row = ({v=>$item->{date}});
		 map { push @row, {v=>getMaxFromItem($item, $_)} } (@POWERLIFTS);
		 $datatable->add_rows(\@row);
	 }
	 my $output = $datatable->output_javascript();
	 return $output;
}

sub filterSetReps {
	my ($streamItems, $sets, $reps) = @_;
	foreach my $item (@$streamItems) {
		foreach my $action (@{$item->{actions}}) {
			my @goodsets = grep {$_->{reps} >= $reps} (@{$action->{sets}});
			my $kg = getMaxFromSets(\@goodsets, $sets);
			#print "$sets x $reps max of $kg    @goodsets\n";
			$action->{max} = $kg
		}

	}
	return $streamItems;
}

sub getMaxFromSets {
	my ($sets, $minset) = @_;
	my %setreps;
	map { $setreps{$_->{kg}}++} (@$sets);
	foreach my $kg (sort keys %setreps) {
		return $kg if $setreps{$kg}>=$minset;
	}
	return undef;
}

sub getMaxFromItem {
	my ($item, $name) = @_;
	foreach my $action (@{$item->{actions}}) {
		if ($name eq $action->{name}) {
			return $action->{max} if exists($action->{max});
			return $action->{sets}->[0]->{kg};
		}
	}
	return undef;
}

sub filterPowerlifts {
	my ($streamItems) = shift;
	my @ret;
	foreach my $item (@$streamItems) {
		my @poweractions = grep {$POWERSET{$_->{name}}} (@{$item->{actions}});
		#my @poweractions = grep {$_->{name} =~ m/Barbell/ } (@{$item->{actions}});
		$item->{actions} = \@poweractions;
		push @ret, $item if scalar(@poweractions);
	}
	@$streamItems = @ret;
	return $streamItems;
}

sub filterMaxWeight {
	my ($streamItems) = shift;
	foreach my $item (@$streamItems) {
		foreach my $action (@{$item->{actions}}) {
			my $max = max map {$_->{kg}} (@{$action->{sets}});
			my @maxsets = grep {$_->{kg} == $max} (@{$action->{sets}});
			$action->{sets} = \@maxsets;
		}

	}
	return $streamItems;
}

sub parseSetText {
	my $setText = shift;
	my %setData;
	if ($setText =~ m/([\d\.]+) kg/) {
		$setData{kg} = $1;
	}
	if ($setText =~ m/([\d\.]+) reps/) {
		$setData{reps} = $1;
	}
	$setData{text} = $setText;
	return \%setData;
}

sub printSets {
	my ($sets) = @_;
	if ($sets->[0]->{kg}) {
		printFormatWeightedSets($sets);
	}
	else {
		foreach my $set (@$sets) {
			print $set->{kg}. " kg " if $set->{kg};
			print $set->{reps}." reps " if $set->{reps};
			print "\n";
		}
	}
}

sub printFormatWeightedSets {
	my ($sets) = @_;
	return "" if (0==scalar(@$sets)); # Warn?
	foreach my $set (@$sets) {
		#print $set->{kg}. " kg " if $set->{kg};
		#print $set->{reps}." reps " if $set->{reps};
		#print "\n";
	}
	my $max = max(map {$_->{kg}} (@$sets));
	my @maxset = grep {$_->{kg} eq $max} (@$sets);
	#print "Max $max kg\n";
	if (all {$_->{reps} == $maxset[0]->{reps}} (@maxset)) {
		my $n = scalar(@maxset);
		print "  ${n}x$sets->[0]->{reps} ${max}kg\n";
	}
	else {
		my $reps = join('/', map {$_->{reps}} (@maxset));
		print "  $reps ${max}kg\n";
	}
}


sub Mojo::Collection::DESTROY {
	# Nothing doing! Do not autoload call
}

__END__

my $s = scraper {
	process "div.stream_item", "items[]" => scraper {
		process "ul.action_detail li", "foo[]" => scraper {
			process "div.action_prompt", activity=>'TEXT',
			process "ul li", content => 'HTML',
		}
	};
};
