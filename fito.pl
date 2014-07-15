#!/usr/bin/perl
use strict;
use warnings;
use WWW::Mechanize;
use JSON;
use Data::Dumper;
use IO::Socket::SSL;
use File::Util;
use Mojo::DOM;
use List::Util qw(first max maxstr min minstr reduce shuffle sum);
use List::MoreUtils qw(all);
use DateTime;
use DateTime::Format::DateParse;
use FindBin;
use lib "$FindBin::Bin/../lib";

our $m = WWW::Mechanize->new(autocheck=>0);
our($f) = File::Util->new();

my $LOGIN_URL = 'https://www.fitocracy.com/accounts/login/';

our $ACTIVITY_HEADERS = ['fito_id','name','shortname','slic_id'];
our $ACTIVITY_TYPES = [
	[1, 'Barbell Bench Press', 'bench', 2],
	[3, 'Barbell Deadlift', 'deadlift',5],
	[2, 'Barbell Squat', 'squat', 1],
	[174, 'Front Barbell Squat', 'front_squat', 64],
	[532, 'Pendlay Row', 'row',4],
	[183, 'Standing Barbell Shoulder Press (OHP)', 'press', 3],
];


our $username = 'thumbdog';
our $password = 'password';
our $targetuser = 'glorat';
our $stream_increment = 15; # How much does fito show in one hit
#our $STREAM_LIMIT = 900;
our $STREAM_LIMIT = 30;

$m->agent_alias('Windows Mozilla');

getFromFito();
#getFromStash();

sub getFromStash {
	my $stream_offset=0;
	my @streamItem;
	while ($stream_offset < $STREAM_LIMIT) {
		my $file = "data/$targetuser-$stream_offset.html";
	
		if ($f->can_read($file)) {
			print STDERR "Processing from stashed $stream_offset\n";
			my $html = $f->load_file($file);
			my $dom = Mojo::DOM->new($html);
			processStream(\@streamItem, $dom);
		}
		else {
			last;
		}
		$stream_offset += $stream_increment;
	}
	my $jsonStream = encode_json(\@streamItem);
	$f->write_file('file'=>"$targetuser.json", 'content'=>$jsonStream);
}

sub getFromFito {

	$m->get($LOGIN_URL);
	$m->form_id('username-login-form');
	my $token  = $m->field('csrfmiddlewaretoken');
	print "Logging in with token $token\n";
	$m->post($LOGIN_URL, {
		"csrfmiddlewaretoken" => $token,
		"is_username" => "1",
		"json" => "1",
		"next" => "/home/",
		"username" => $username,
		"password" => $password,
	});

	$m->get("https://www.fitocracy.com/profile/$targetuser/?feed");
	my $content = $m->content;
	$content =~ m/var profile_user_id = (\d+)/ or die ("Couldn't find profile_user_id for $targetuser");
	my $targetuserid = $1;
	print STDERR "User $targetuser has id $targetuserid\n";
	# It is main parsing time

	# The root of our data structure
	my $stream_offset = 0;
	my @streamItem;
	while ($stream_offset < $STREAM_LIMIT) {
		print STDERR "Processing from $stream_offset\n";
		$m->get("https://www.fitocracy.com/activity_stream/$stream_offset/?user_id=$targetuserid");
		#$f->write_file("data/$targetuser-$stream_offset.html", $m->content);
		my $dom = Mojo::DOM->new($m->content);
		if ($dom->at("div.stream-inner-empty")) {
			print STDERR "No more items!";
			last;
		}
		else {
			processStream(\@streamItem, $dom)
		}
		$stream_offset += $stream_increment;
	}





	my $jsonStream = encode_json(\@streamItem);
	$f->write_file('file'=>"$targetuser.json", 'content'=>$jsonStream);
}


sub processStream {
	my ($streamItem, $dom) = @_;
	if ($dom->at("div.stream-inner-empty")) {
		print STDERR "No more items!";
		return;
	}
	
	
	$dom->find('div.stream_item')->each(sub {
		my $sitem = shift;
		my $date = DateTime::Format::DateParse->parse_datetime($sitem->at('a.action_time')->text);
		$date or next; # Today will break it 
		my @actions;
		foreach my $actEl ($sitem->find('ul.action_detail li')->each) {
			my $nameEl = $actEl->at('div.action_prompt');
			if ($nameEl) {
				print $date->ymd . " " . $nameEl->text . "\n";
				my @sets;
				foreach my $setEl ($actEl->at('ul')->find('li')->each) {
					#if ($setEl->children('span[class="action_prompt_points"]')->first) {
						# Only point worthy items are sets
						my $setText = $setEl->text;
						print STDERR "  ".$setEl->text."\n";
					#	print STDERR "***\n";
						push @sets, parseSetText($setText);
					#}
					#else {
					#	print STDERR "Commentary: ". $setEl->text;
					#	print STDERR "\n";
					#}
				}
				#print "\n";
				my $name = $nameEl->text;
				$name =~ s/:$//;
				push @actions, {name=> $name, sets=>\@sets} ;
			}
		}
		if (scalar (@actions)) {
			push @$streamItem, {actions=>\@actions, date=>$date->epoch};
		}
	});
}


sub parseSetText {
	my $setText = shift;
	my %setData;
	if ($setText =~ m/([\d\.]+) kg/) {
		$setData{kg} = $1;
	}
	elsif ($setText =~ m/([\d\.]+) lb/) {
		$setData{lb} = $1;
		$setData{kg} = sprintf('%.1f', $1 / 2.20462262185); # Fito rounding...
	}# else??
	
	if ($setText =~ m/([\d\.]+) reps/) {
		$setData{reps} = $1;
	}
	$setData{text} = $setText;
	return \%setData;
}


#sub Mojo::Collection::DESTROY {
#	# Nothing doing! Do not autoload call
#}
