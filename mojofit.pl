#!/usr/bin/perl
use FindBin;
use lib "$FindBin::Bin";
use strict;

package Mojofit;

use File::Util;
use Data::Dumper;
use Mojo::DOM;
use List::Util qw(first max maxstr min minstr reduce shuffle sum);
use List::MoreUtils qw(all);
use DateTime;
use DateTime::Format::DateParse;
use Data::Google::Visualization::DataTable;

use Mojolicious::Lite;

#plugin 'TagHelpers';

# Config
our @POWERLIFTS = ('Barbell Squat', 'Barbell Bench Press', 'Barbell Deadlift', 'Standing Barbell Shoulder Press (OHP)', 'Pendlay Row');
our %POWERSET = map {$_ => 1} (@POWERLIFTS);

# Util objects
our($f) = File::Util->new();

get '/user/:username' => sub {
	my $c = shift;
	my $minreps = $c->param('minreps');
	my $minsets = $c->param('minsets');
	my $period = $c->param('period');
	my $useperiod = $c->param('useperiod');
	$minreps ||= 1;
	$minsets ||= 1;
	$period ||= 28;
	$useperiod ||= 0;
	$c->stash('minreps',$minreps);
	$c->stash('minsets',$minsets);
	$c->stash('period',$period);
	$c->stash('jsperiod', $c->param('useperiod') ? $c->param('period') : 0);
	#$c->stash('useperiod',$useperiod);
	my $target = $c->param('username');
	$target =~ m/^[A-Za-z0-9\-\.]+$/ or return $c->render(text => 'Invalid username');
	my $stream = getMaxStream($target);

	$c->stash('interpolateNulls', 1);
	$c->stash('log', formatStream($stream));
};

any '/userjson/:username/:minsets/:minreps/:period' => sub {
	my $c = shift;
	my $target = $c->param('username');
	$target =~ m/^[A-Za-z0-9\-\.]+$/ or return $c->render(text => 'Invalid username');
	my $minsets = $c->param('minsets') || 1;
	my $minreps = $c->param('minreps') || 1;
	my $period = $c->param('period');
	my $js = getTargetJson($target, $minsets, $minreps, $period);
	my $json = "jsonData=$js; drawChart();";
	$c->render(text => $json, format => 'json');
};

any '/uservolume/:username' => sub {
	my $c = shift;
	my $target = $c->param('username');
	$target =~ m/^[A-Za-z0-9\-\.]+$/ or return $c->render(text => 'Invalid username');
	my $stream = Mojofit::Stream::getStream($target);
	
	my $ret = '';
	foreach my $item (@$stream) {
		if ($item->maxFor('Barbell Squat')) {
			$ret .= $item->{date} . ' ' . $item->maxFor('Barbell Squat') . ' '. $item->volumeFor('Barbell Squat')."\n";
		}
	}
	$c->render(text => $ret);
	
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


sub getMaxStream {
	my ($target) = @_;
	my $stream = Mojofit::Stream::getStream($target);
	if ($target !~ m/^SLIC-/) {
		# Fito
		$stream->filterMaxWeight;
	}
	return $stream;
}

sub getTargetJson {
	my ($target, $minsets, $minreps, $period) = @_;
	return '' unless $f->can_read("${target}.json");
	my $stream = getMaxStream($target);

	if ($target =~ m/^SLIC-/) {
		# SLIC JSON
	}
	else {
		# Fitocracy JSON
		$stream->filterSetReps($minsets, $minreps);
	}
	
	consistency($stream);
	movingMax($stream, $period);
	return powerTableMax($stream, $period);
	#return powerTableConMax($stream, $period);

}

sub movingMax {
	my ($origstream,  $perdays) = @_;
	$perdays ||=1;
	my $LOOKBACK= $perdays * 24 * 60 *60; # Days to secs
	
	my $stream = [sort {$a->{date} <=> $b->{date}} @$origstream];
	my %prev = (); #map {$_ => 0 } (@POWERLIFTS);
	for my $i (0..scalar(@$stream)-1) {
		my $item = $stream->[$i];
		my $back = $i-1;
		#print STDERR "Looking back from $item->{'date'} to $stream->[$back]->{'date'}\n";
		if ($perdays) {
			#my %permax = map { $_ => $item->maxFor($_) } (@POWERLIFTS);
			# Max will use previous max by induction
			my %permax = map { $_ => $item->maxFor($_) || $prev{$_} } (@POWERLIFTS);
			while ($back>=0 && $stream->[$back] && ($stream->[$back]->{'date'}+$LOOKBACK > $item->{'date'})) {
				my $old = $stream->[$back];
				
				foreach (@POWERLIFTS) {
					my $oldmax = $old->maxFor($_);
					if ($permax{$_} && $oldmax) {
						$permax{$_} = $permax{$_}< $oldmax ? $oldmax : $permax{$_}
					}
				}
				$back--;
			}
			$item->{'permax'} = \%permax;
			%prev = %permax;

			
		}
		else {
		}
		#print STDERR "$item->{date} $workouts\n";
	}
}

sub consistency {
	my ($origstream, $condays) = @_;
	$condays ||= 7;	
	my @WEIGHT = (0,1,3,3,2,2,2,2,2);
	
	my $stream = [sort {$a->{date} <=> $b->{date}} @$origstream];
	
	my $CONBACK = $condays * 24 * 60 * 60;
	my $sumcon = 0;
	
	for my $i (0..scalar(@$stream)-1) {
		my $item = $stream->[$i];
		my $back = $i-1;
		my $workouts = 0; # Workouts in period
		my $to = DateTime->from_epoch(epoch=>$item->{'date'});
		my $consistency = 1;
		$item->{'sincelast'} = 0;
		while ($back>=0 && $stream->[$back] && ($stream->[$back]->{'date'}+$CONBACK > $item->{'date'})) {
			my $from = DateTime->from_epoch(epoch=>$stream->[$back]->{'date'});
			my $delta = $to->delta_days($from)->days;
			$consistency += 1;# $WEIGHT[$delta];
			#print STDERR "Hit back $delta\n";
			my $old = $stream->[$back];
			if ($old->validPowerLift) {
				$item->{'sincelast'} ||= $delta;
				$workouts ++;
			}
			$back--;
		}
		#print STDERR "Since last $item->{'sincelast'}\n";
		
		$item->{'workouts'} = $workouts;
		$sumcon += $item->{'sincelast'} / 3;
		for (my $b=$i-1; $b>=$i-4; $b--) {
			
			if ($b>=0 && $stream->[$b]) {
				#print STDERR "$stream->[$b]->{date} - $stream->[$i]->{date}\n" unless defined $stream->[$b]->{'workouts'};
				$workouts += $stream->[$b]->{'workouts'};
				#print STDERR "Accumulate $stream->[$b]->{'workouts'}\n";
			}
		}
		$item->{'consistency'} = $workouts; #sprintf('%d', 10* ($workouts / 7) );
		$item->{'sumcon'} = $sumcon;
		
	}
}

sub formatStream {
	my ($stream) = @_;
	my $ret = '';
	# Display
	foreach my $item (@$stream) {
		my $dt = DateTime->from_epoch( epoch => $item->{date});
		$ret .= $dt->ymd. "\n";
		foreach my $action (@{$item->{actions}}) {
			$ret .= " $action->{name} : ";
			foreach my $set ($action->{sets}) {
				$ret .= formatSets($set);
			}
		}
		$ret .= "\n";
	}
	return $ret;
}

sub powerTableMax {
	my ($streamItems, $period) = @_;
	my $maxfld = $period ? 'permax' : 'max';
	my $datatable = Data::Google::Visualization::DataTable->new();
	my @powercols = map { {id=>'', label=>$_, type=>'number'}} @POWERLIFTS;
	 $datatable->add_columns(
	        { id => 'date',     label => "Date",        type => 'date', p => {}},
			{ id => 'consistency',     label => "Consistency",        type => 'number', p => {}},
	        @powercols,
	 );

	 foreach my $item (@$streamItems) {
		 my @row = ({v=>$item->{date}}, {v=>$item->{consistency}},  );
		 map { push @row, {v=>$item->{$maxfld}->{$_}} } (@POWERLIFTS);
		 $datatable->add_rows(\@row);
	 }
	 my $output = $datatable->output_javascript();
	 return $output;
}

sub powerTableConMax {
	my ($streamItems, $period) = @_;
	my $maxfld = $period ? 'permax' : 'max';
	my $datatable = Data::Google::Visualization::DataTable->new();
	my @powercols = map { {id=>'', label=>$_, type=>'number'}} @POWERLIFTS;
	 $datatable->add_columns(
			{ id => 'consistency',     label => "Work",        type => 'number', p => {}},
	        @powercols,
	 );

	 foreach my $item (@$streamItems) {
		 my @row = ({v=>$item->{sumcon}, f=>"$item->{sumcon} - ".$item->date->ymd},  );
		 map { push @row, {v=>$item->{$maxfld}->{$_}} } (@POWERLIFTS);
		 $datatable->add_rows(\@row);
	 }
	 my $output = $datatable->output_javascript();
	 return $output;
}


sub calcVolumeFromWorkout {
	my ($item) = @_;
	foreach my $action (@{$item->{actions}}) {
		if ($action->{sets}->[0]->{kg} && $action->{sets}->[0]->{reps} ) {
			my $volume = sum (map {$_->{kg} * $_->{reps}} (@{$action->{sets}}));
			$action->{'volume'} = $volume;
		}
	}
	return $item;
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

sub formatSets {
	my ($sets) = @_;
	my $ret = '';
	if ($sets->[0]->{kg}) {
		$ret .= formatWeightedSets($sets);
	}
	else {
		foreach my $set (@$sets) {
			$ret .= $set->{kg}. " kg " if $set->{kg};
			$ret .= $set->{reps}." reps " if $set->{reps};
			$ret .= "\n";
		}
	}
	return $ret;
}

sub formatWeightedSets {
	my ($sets) = @_;
	my $ret = '';
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
		$ret .= "  ${n}x$sets->[0]->{reps} ${max}kg\n";
	}
	else {
		my $reps = join('/', map {$_->{reps}} (@maxset));
		$ret .= "  $reps ${max}kg\n";
	}
	return $ret;
}


sub Mojo::Collection::DESTROY {
	# Nothing doing! Do not autoload call
}


app->start;


package Mojofit::Set;

package Mojofit::Action;
use List::Util qw(first max maxstr min minstr reduce shuffle sum);

sub filterSetReps {
	my ($action, $sets, $reps) = @_;
	my @goodsets = grep {$_->{reps} >= $reps} (@{$action->{sets}});
	my $kg = getMaxFromSets(\@goodsets, $sets);
	#print "$sets x $reps max of $kg    @goodsets\n";
	$action->{max} = $kg;
	return $action;
}


sub filterMaxWeight {
	my ($action) = shift;
	my $max = max map {$_->{kg}} (@{$action->{sets}});
	my @maxsets = grep {$_->{kg} == $max} (@{$action->{sets}});
	$action->{sets} = \@maxsets;
	return $action;
}


# Static
sub getMaxFromSets {
	my ($sets, $minset) = @_;
	my %setreps;
	map { $setreps{$_->{kg}}++} (@$sets);
	foreach my $kg (sort keys %setreps) {
		return $kg if $setreps{$kg}>=$minset;
	}
	return undef;
}


package Mojofit::StreamItem;
use List::Util qw(first max maxstr min minstr reduce shuffle sum);

sub date {
	my ($item) = @_;
	$item->{dateobj} ||= DateTime->from_epoch( epoch => $item->{date});
}

sub maxFor {
	my ($item, $name) = @_;
	return $item->{max}->{$name} if exists($item->{max}->{$name});
	my $max = $item->getMaxFromItem($name);
	$item->{max}->{$name} = $max;
	return $max;
}

sub volumeFor {
	my ($item, $name) = @_;
	$item->calcVolumeFromItem unless exists $item->{volume};
	return $item->{volume}->{$name};
}

sub calcVolumeFromItem {
	my ($item) = @_;
	my %volmap;
	foreach my $action (@{$item->{actions}}) {
		if ($action->{sets}->[0]->{kg} && $action->{sets}->[0]->{reps} ) {
			my $volume = sum (map {$_->{kg} * $_->{reps}} (@{$action->{sets}}));
			$volmap{$action->{name}} = $volume;
		}
	}
	$item->{volume} =  \%volmap;
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

sub validPowerLift {
	my ($item) = @_;
	return $item->maxFor('Barbell Squat') || $item->maxFor('Barbell Deadlift');
}

sub filterPowerLifts {
	my ($item) = @_;
	my @poweractions = grep {$Mojofit::POWERSET{$_->{name}}} (@{$item->{actions}});
	#my @poweractions = grep {$_->{name} =~ m/Barbell/ } (@{$item->{actions}});
	$item->{actions} = \@poweractions;
	return $item;
}

sub actionCount {
	return scalar(@{shift->{'actions'}});
}

package Mojofit::Stream;
use JSON;
use List::Util qw(first max maxstr min minstr reduce shuffle sum);
use List::MoreUtils qw(all);
use Data::Dumper;

sub getStream {
	my ($target) = @_;
	return [] unless $f->can_read("${target}.json");
	my $jsonStream=$f->load_file("${target}.json");
	my $stream = decode_json($jsonStream);

	bless $stream, "Mojofit::Stream";
	foreach my $item (@$stream) {
		bless $item, 'Mojofit::StreamItem';
		foreach my $action (@{$item->{'actions'}}) {
			foreach my $set (@{$action->{sets}}) {
				bless $set, 'Mojofit::Set';
			}
			bless $action, 'Mojofit::Action';
		}
	}
	
	if ($target !~ m/^SLIC-/) {
		# Fito
		$stream->filterPowerlifts;
	}
	
	return $stream;
}

# Methods
sub items {
	my ($stream) = @_;
	return @$stream; 
}


sub filterPowerlifts {
	my ($stream) = shift;
	my @ret;
	foreach my $item ($stream->items) {
		#my @poweractions = grep {$Mojofit::POWERSET{$_->{name}}} (@{$item->{actions}});
		#$item->{actions} = \@poweractions;
		$item->filterPowerLifts;
		#push @ret, $item if scalar(@poweractions);
		push @ret, $item if $item->actionCount;
	}
	# Updating self!!! FIXME
	@$stream = @ret;
	return $stream->items;
}


sub filterSetReps {
	my ($stream, $sets, $reps) = @_;
	foreach my $item ($stream->items) {
		foreach my $action (@{$item->{actions}}) {
			$action->filterSetReps($sets, $reps);
		}

	}
	return $stream;
}


sub filterMaxWeight {
	my ($stream) = shift;
	foreach my $item ($stream->items) {
		foreach my $action (@{$item->{actions}}) {
			$action->filterMaxWeight();
		}
	}
	return $stream;
}

sub toListByDate {
	my ($origstream, $condays) = @_;	
	my $stream = [sort {$a->{date} <=> $b->{date}} $origstream->items];
	my $basedate = DateTime->from_epoch(epoch=>$stream->[0]->{'date'})->to_julian;
	my @byDate;
	foreach my $item (@$stream) {
		my $to = DateTime->from_epoch(epoch=>$item->{'date'});
		$byDate[$to->to_julian - $basedate] = $item;
	}
	return \@byDate;
}


package Mojofit;

__DATA__
@@ userusername.html.ep
<html>
  <head>
    <script type="text/javascript" src="https://www.google.com/jsapi"></script>
	<script type="text/javascript" src="//ajax.googleapis.com/ajax/libs/jquery/1.10.2/jquery.min.js"></script>
    <script type="text/javascript" src="http://canvg.googlecode.com/svn/trunk/rgbcolor.js"></script> 
    <script type="text/javascript" src="http://canvg.googlecode.com/svn/trunk/canvg.js"></script>
    <script type="text/javascript">
      google.load("visualization", "1", {packages:["corechart"]});
      // google.setOnLoadCallback(drawChart);
	  var jsonData;
	  
	  google.setOnLoadCallback(defaultChart);
	  
	  function defaultChart() {
		  jsonData = $.ajax({
		            url: "/userjson/<%== $username %>/<%== $minsets %>/<%== $minreps %>/<%== $jsperiod %>",
		            dataType:"script",
		            async: true
		            });
	  }
	  
      function drawChart() {
		  var data = new google.visualization.DataTable(jsonData);
		  var options = {"hAxis":{"title":""},"vAxis":{"title":"","format":"# kg"},"width":900,"height":500,"interpolateNulls":<%== $interpolateNulls ? 'true' : 'false' %>,"legend":{"position":"top","maxLines":5}};

        var chart = new google.visualization.LineChart(document.getElementById('chart_div'));
        chart.draw(data, options);
      }

	  function getImgData(chartContainer) {
	    var chartArea = chartContainer.getElementsByTagName('svg')[0].parentNode;
	    var svg = chartArea.innerHTML;
	    var doc = chartContainer.ownerDocument;
	    var canvas = doc.createElement('canvas');
	    canvas.setAttribute('width', chartArea.offsetWidth);
	    canvas.setAttribute('height', chartArea.offsetHeight);


	    canvas.setAttribute(
	        'style',
	        'position: absolute; ' +
	        'top: ' + (-chartArea.offsetHeight * 2) + 'px;' +
	        'left: ' + (-chartArea.offsetWidth * 2) + 'px;');
	    doc.body.appendChild(canvas);
	    canvg(canvas, svg);
	    var imgData = canvas.toDataURL("image/png");
	    canvas.parentNode.removeChild(canvas);
	    return imgData;
	  }
	  
      function saveAsImg(chartContainer) {
        var imgData = getImgData(chartContainer);
        
        // Replacing the mime-type will force the browser to trigger a download
        // rather than displaying the image in the browser window.
        window.location = imgData.replace("image/png", "image/octet-stream");
      }
      
      function toImg(chartContainer, imgContainer) { 
        var doc = chartContainer.ownerDocument;
        var img = doc.createElement('img');
        img.src = getImgData(chartContainer);
        
        while (imgContainer.firstChild) {
          imgContainer.removeChild(imgContainer.firstChild);
        }
        imgContainer.appendChild(img);
      }
	  
    </script>
  </head>
  <body>
  <h1>Training log for <em><%== $username %></em></h1>
    <div id="chart_div" style="width: 900px; height: 500px;">Loading...</div>
	<form>
	<input type="number" name="minsets" value="<%== $minsets %>" size="2" max="99"> sets x <input type="number" name="minreps" value="<%== $minreps %>" width="2"> reps<br>
	Smooth to periodic cycle <%= check_box useperiod => 1 %> of <input type="number" name="period" value="<%== $period %>" width="2"> days<br>
	<input type="submit">
	</form>
	
    <div id="img_div" style="position: fixed; top: 0; right: 0; z-index: 10; border: 1px solid #b9b9b9">
      Image will be placed here
    </div>
	<button onclick="toImg(document.getElementById('chart_div'), document.getElementById('img_div'));">Convert to image</button>
	<pre><%== $log %></pre>
  </body>
</html>
