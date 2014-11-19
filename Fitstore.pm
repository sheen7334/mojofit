use strict;
use warnings;

package Fitstore;

use JSON;

our $DATA_DIR = '.';

sub new {
	my ($class, $id) = @_;
	# Sanitise $id
	my $self = {id=>$id, index=>0, data=>{}};
	bless $self, $class;
	$self->load_from_stream;
	return $self;
}

sub handle_item_submitted {
	# Nothing doing for validation
}

sub submit_workouts {
	my ($self, $items) = @_;
	# Each $item should contain actions/date and optional notes
	foreach my $item (@$items) {
		$item->{date} or die ("Item has not date");
		$item->{actions} or die ("Item has no actions");
	}
	# No other validation for now!
	my @events = map { {action=>'item_submitted', item=>$_}} (@$items);
	$self->commit_append(\@events);
	
}

sub load_from_stream {
	my ($self) = @_;
	my $file = "$DATA_DIR/$self->{id}.dat";
	open IN, $file or return; # Warn if auto-creating new stream?
	while (<IN>) {
		my $line = $_;
		my $ev = decode_json($line);
		$self->handle($ev);
	}
	close IN;
}

sub commit_append {
	my ($self, $event) = @_;
	my $file = "$DATA_DIR/$self->{id}.dat";
	# Open for r/w and lock!
	open FH, "+>>$file" or die ("Can't open $file for write-append: $!");
	# TODO: flock
	seek (FH, 0, Fcntl::SEEK_SET); # Start of file
	my $count = 0;
	while (<FH>) {$count++};
	seek(FH, 0, Fcntl::SEEK_END); # To end
	# TODO: Check for consistency
	if ('HASH'eq ref ($event)) {
		$event = [$event];
	}
	if ('ARRAY' eq ref($event)) {
		foreach (@$event) {
			$_->{'time'} = time; # Stamp it
			print FH encode_json($_);
			print FH "\n";	
		}
	}
	else {
		Carp::confess("Event was malformed. Code bug");
	}
	close FH;
	
	foreach (@$event) {
		$self->handle($_);
	}
}

sub handle {
	my ($self, $ev) = @_;
	('HASH' eq ref($ev)) or confess ("Not a hashref:".($ev));
	my $method = "handle_$ev->{action}";
	
	$self->can($method) or die ("Not such handler for $ev->{action}");
	$self->$method($ev);
	$self->{index}++;
}

package Fitstore::MainView;
use JSON;

our @ISA = qw'Fitstore';

sub new {
	my ($class, $id) = @_;
	# Sanitise $id
	my $self = {id=>$id, index=>0, by_date=>{}};
	bless $self, $class;
	$self->load_from_stream;
	return $self;
}

sub handle_item_submitted {
	my ($self, $event) = @_;
	my $item = $event->{item};
	$self->{bydate}->{$item->{date}} = $item;
}

sub write_by_date {
	my ($self) = @_;
	my @keys = sort keys %{$self->{bydate}};
	my @items = map {$self->{bydate}->{$_}} (@keys);
	open OUT, ">$self->{id}.json";
	print OUT encode_json(\@items);
	close OUT; 
}

1