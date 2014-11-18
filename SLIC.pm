#!/usr/bin/perl
use strict; 
use warnings; 

package SLIC;

use Data::Dumper; 
use DateTime; 
use DateTime::Format::DateParse; 


our @WARNS;

sub parse_text {
	my ($text) = @_;
	$text =~ s/\r\n/\n/g; # Stupid windows convention
	$text =~ s/\r/\n/g; # Enforce \n only
	$text =~ s/\n\ +/\n/g; #Trim leading space
	
	open OUT, ">prev.txt";
	print OUT $text;
	close OUT;
	
	@WARNS = ();
	$text =~ m/\n([\S\ ]*?)'s? Log \-/s or die ("Can't find your name inside the text");
	my $name = $1;
	$name =~ m/^\w[\w\ \d]+$/ or die ("Invalid name parsed $name"); #Whitelist name for file saving
	my @posts = split(/Joined: \w+ \d+\s*(?:Follow)?\s*/, $text);
	shift @posts;
	
	my @items = map {parse_post($_, $name)} (@posts);
	# FIXME: Should return a copy of warns
	return ($name,\@items, \@WARNS);
}

sub parse_post {
	my ($post, $name) = @_;
	
	$post =~ s/^New\s*//; # No idea where this comes in...
	if ($post =~ m/(.*?)\n\s*?\n(.*)\nNotes\s(.*)${name}, /s) {
		my ($datetxt, $workout, $notes) = ($1,$2,$3);
		#$datetxt =~ s/^\w+//; # Trim the DOW
			my $date = DateTime::Format::DateParse->parse_datetime($datetxt);
		$date or die ("$datetxt is not a date in $_");
		# push @$streamItem, {actions=>\@actions, date=>$date->epoch}; push @actions, {name=> $name, sets=>\@sets} ; 
		# push @sets, parseSetText($setText); reps text kg
			my $actions = parse_workout($workout);
		my $item = {actions=>$actions, date=>$date->epoch, notes=>$notes};
		
		parse_warn ("************\n");
		return $item;
	}
	else {
		parse_warn ("Failed to parse post for $name: $post");
		die "Failed to parse post for $name: $post";
		return {};
	}
}
sub parse_workout {
	my ($workout)= @_;
	
	my @exs = split (/\n\n/, $workout);
	my @actions = map {
		parse_action($_);
	} (@exs);
	return \@actions;
}
sub parse_action {
	my ($acttext) = @_;
	my @exbits = split(/\n/, $acttext);
	#print "*$_\n";
	my %SLIC_TO_MOJO = (
	'Squat'=>'Barbell Squat',
	'Press'=>'Standing Barbell Shoulder Press (OHP)',
	'Overhead Press' => 'Standing Barbell Shoulder Press (OHP)',
	'Bench'=>'Barbell Bench Press',
	'Deadlift'=>'Barbell Deadlift',);
	
	my $exname = shift @exbits;
	$exname = $SLIC_TO_MOJO{$exname} if $SLIC_TO_MOJO{$exname};
	
	my $action = {name=>$exname, sets=> [] };
	
	foreach (@exbits) {
		if (m/(.*?)\s?([\d\.]+)([a-z]+)$/) {
			my ($reps, $weight, $unit) = ($1,$2,$3);
			my $set = parse_reps($reps, $weight, $unit);
			push @{$action->{sets}}, @$set;
			
		}
		else {
			parse_warn ("Can't parse line $_");
		}
	}
	
	parse_warn ("$exname");
	foreach (@{$action->{sets}}) {
	my $unit = 'kg';
		parse_warn ("$_->{reps} x $_->{$unit}$unit");
	}
	
	parse_warn ("***");
	return $action;
}
# returns sets
sub parse_reps {
	my ($str, $weight, $unit) = @_;
	if ($str =~ m/(\d+)x/) { #5x100kg
		return [{reps=>1, $unit=>$weight}];
	}
	elsif ($str =~ m/(\d+)x(\d+)/) { # 5x5 100kg
		my ($sets, $reps) = ($1,$2);
		return [map { {reps=>$reps, $unit=>$weight} } (1..$sets)];
	}
	elsif ($str =~ m|\d+(/\d+)+|) { # 1/0/0 100kg
		my @reps = split(m|/|, $str);
		return [map { {reps=>$_, $unit=>$weight} } @reps];
	}
	else {
		parse_warn ("Can't parse rep scheme: $str");
		return [];
	}
}

sub parse_warn {
	my ($msg) = @_;
	print STDERR "$msg\n";
	push @WARNS, $msg;
}

1;
