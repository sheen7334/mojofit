#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin";
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
use Mojolicious::Lite;


# Config
our @POWERLIFTS = ('Barbell Squat', 'Barbell Bench Press', 'Barbell Deadlift', 'Standing Barbell Shoulder Press (OHP)', 'Pendlay Row');
our %POWERSET = map {$_ => 1} (@POWERLIFTS);

# Util objects
our($f) = File::Util->new();

get '/user/:username' => sub {};

any '/userjson/:username' => sub {
	my $c = shift;
	my $target = $c->param('username');
	$target =~ m/^[A-Za-z0-9]+$/ or return $c->render(text => 'Invalid username');
	my $minsets = $c->param('sets') || 1;
	my $minreps = $c->param('reps') || 1;
	my $js = getTargetJson($target, $minsets, $minreps);
	my $json = "jsonData=$js; drawChart();";
	$c->render(text => $json, format => 'json');
};

any '/debug' => sub {
    my $c = shift;
	my @nms = $c->param;
	my $str = $c->req->body;
	$str .= "\n";
	foreach (@nms) {
		$str.="$_ : " . $c->param($_) ."\n";
	}
    $c->render(text => $str);
};

app->start;

sub getTargetJson {
	my ($target, $minsets, $minreps) = @_;
	return '' unless $f->can_read("${target}.json");
	
	my $jsonStream=$f->load_file("${target}.json");
	my @streamItem = @{decode_json($jsonStream)};

	filterPowerlifts(\@streamItem);
	filterMaxWeight(\@streamItem);
	filterSetReps(\@streamItem, $minsets, $minreps);
	return powerTableMax(\@streamItem);

}

sub debugStream {
	my ($stream) = @_;
	# Display
	foreach my $item (@$stream) {
		print $item->{date}->date. "\n";
		foreach my $action (@{$item->{actions}}) {
			print " *$action->{name}*\n";
			foreach my $set ($action->{sets}) {
				printSets($set);
			}
		}
		print "\n";
	}
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

__DATA__
@@ userusername.html.ep
<html>
  <head>
    <script type="text/javascript" src="https://www.google.com/jsapi"></script>
	<script type="text/javascript" src="//ajax.googleapis.com/ajax/libs/jquery/1.10.2/jquery.min.js"></script>
	
    <script type="text/javascript">
      google.load("visualization", "1", {packages:["corechart"]});
      // google.setOnLoadCallback(drawChart);
	  var jsonData;
	  
	  google.setOnLoadCallback(defaultChart);
	  
	  function defaultChart() {
		  jsonData = $.ajax({
		            url: "/userjson/<%== $username %>",
		            dataType:"script",
		            async: true
		            });
	  }
	  
      function drawChart() {
		  var data = new google.visualization.DataTable(jsonData);
		  var options = {"hAxis":{"title":""},"vAxis":{"title":"","format":"# kg"},"width":900,"height":500,"interpolateNulls":true,"legend":{"position":"top","maxLines":5}};

        var chart = new google.visualization.LineChart(document.getElementById('chart_div'));
        chart.draw(data, options);
      }
    </script>
  </head>
  <body>
  <h1>Fitocracy performance for <%== $username %></h1>
    <div id="chart_div" style="width: 900px; height: 500px;">Loading...</div>
  </body>
</html>
