package OWX_Executor;
use strict;
use warnings;
use constant {
	SEARCH  => 1,
	ALARMS  => 2,
	EXECUTE => 3,
	EXIT    => 4,
	LOG     => 5
};

sub new($) {
	my ( $class, $owx ) = @_;
	return bless {
		owx => $owx,
		commands => []
	}, $class;
};

sub search() {
	my $self = shift;
	push @{$self->{commands}},{ command => SEARCH, devices => $self->{owx}->Discover() }; 
};

sub alarms() {
	my $self = shift;
	push @{$self->{commands}},{ command => ALARMS, devices => $self->{owx}->Alarms() }; 
}

sub execute($$$$$$) {
	my ( $self, $context, $reset, $owx_dev, $data, $numread, $delay ) = @_;
	my $owx = $self->{owx};
	my $item = {
		command   => EXECUTE,
		context   => $context,
		reset     => $reset,
		address   => $owx_dev,
		writedata => $data,
		numread   => $numread,
		delay     => $delay
	};

	if ($reset) {
		if(!$owx->Reset()) {
			$item->{success}=0;
			push @{$self->{commands}},$item;
			return;
		};
	};
	my $res = $owx->Complex($item->{address},$item->{writedata},$item->{numread});
	if (defined $res) {
		my $writelen = defined $item->{writedata} ? split (//,$item->{writedata}) : 0;
		my @result = split (//, $res);
		$item->{readdata} = 9+$writelen < @result ? substr($res,9+$writelen) : "";
		$item->{success} = 1;
		if ($delay) {
			select (undef,undef,undef,$item->{delay}/1000); #TODO implement device (address) specific wait
		}
	} else {
		$item->{success} = 0;
	}
	push @{$self->{commands}},$item;
};

sub exit($) {
	my ( $self,$hash ) = @_;
	main::OWX_Disconnected($hash);
}

sub poll($) {
	my ($self,$hash) = @_;
	while (my $item = shift @{$self->{commands}}) {
		my $command = $item->{command};
		COMMANDS: {
			$command eq SEARCH and do {
				main::OWX_AfterSearch($hash,$item->{devices});
				last;
			};
			$command eq ALARMS and do {
				main::OWX_AfterAlarms($hash,$item->{devices});
				last;
			};
			$command eq EXECUTE and do {
				main::OWX_AfterExecute($hash,$item->{context},$item->{success},$item->{reset},$item->{address},$item->{writedata},$item->{numread},$item->{readdata});
				last;
			};
		};
	};
};

package OWX_AsyncExecutor;
use strict;
use warnings;
use constant {
	SEARCH  => 1,
	ALARMS  => 2,
	EXECUTE => 3,
	EXIT    => 4,
	LOG     => 5
};
use threads;
use Thread::Queue;

sub new($) {
	my ( $class, $owx ) = @_;
	my $requests   = Thread::Queue->new();
	my $responses  = Thread::Queue->new();
	my $worker = OWX_Worker->new($owx,$requests,$responses);
	my $thr = threads->create(
			sub {
				$worker->run();
			}
		)->detach();
	return bless {
		requests     => $requests,
		responses    => $responses,
		workerthread => $thr,
		owx => $owx,
	}, $class;
}

sub search() {
	my $self = shift;
	$self->{requests}->enqueue( { command => SEARCH } );
}

sub alarms() {
	my $self = shift;
	$self->{requests}->enqueue( { command => ALARMS } );
}

sub execute($$$$$$) {
	my ( $self, $context, $reset, $owx_dev, $data, $numread, $delay ) = @_;
	$self->{requests}->enqueue(
		{
			command   => EXECUTE,
			context   => $context,
			reset     => $reset,
			address   => $owx_dev,
			writedata => $data,
			numread   => $numread,
			delay     => $delay
		}
	);
};

sub exit($) {
	my ( $self,$hash ) = @_;
	$self->{requests}->enqueue(
		{
			command => EXIT
		}
	);
}

sub poll($) {
	my ($self,$hash) = @_;
	
	# Non-blocking dequeue
	while( my $item = $self->{responses}->dequeue_nb() ) {

		my $command = $item->{command};
		
		# Work on $item
		RESPONSE_HANDLER: {
			
			$command eq SEARCH and do {
				return unless $item->{success};
				my @devices = split(/;/,$item->{devices});
				main::OWX_AfterSearch($hash,\@devices);
				last;
			};
			
			$command eq ALARMS and do {
				return unless $item->{success};
				my @devices = split(/;/,$item->{devices});
				main::OWX_AfterAlarms($hash,\@devices);
				last;
			};
				
			$command eq EXECUTE and do {
				main::OWX_AfterExecute($hash,$item->{context},$item->{success},$item->{reset},$item->{address},$item->{writedata},$item->{numread},$item->{readdata});
				last;
			};
			
			$command eq LOG and do {
				my $loglevel = main::GetLogLevel($hash->{NAME},6);
				main::Log($loglevel <6 ? $loglevel : $item->{level},$item->{message});
				last;
			};
			
			$command eq EXIT and do {
				main::OWX_Disconnected($hash);
				last;
			};
		};
	};
};

package OWX_Worker;

use constant {
	SEARCH  => 1,
	ALARMS  => 2,
	EXECUTE => 3,
	EXIT    => 4,
	LOG     => 5
};

sub new($$$) {
	my ( $class, $owx, $requests, $responses ) = @_;

	return bless {
		requests  => $requests,
		responses => $responses,
		owx       => $owx
	}, $class;
};

sub run() {
	my $self = shift;
	my $requests = $self->{requests};
	my $responses = $self->{responses};
	my $owx = $self->{owx};
	$owx->{logger} = $self;
	while ( my $item = $requests->dequeue() ) {
		REQUEST_HANDLER: {
			my $command = $item->{command};
			
			$command eq SEARCH and do {
				my $devices = $owx->Discover();
				if (defined $devices) {
					$item->{success} = 1;
					$item->{devices} = join(';', @{$devices});
				} else {
					$item->{success} = 0;
				}
				$responses->enqueue($item);
				last;
			};
			
			$command eq ALARMS and do {
				my $devices = $owx->Alarms();
				if (defined $devices) {
					$item->{success} = 1;
					$item->{devices} = join(';', @{$devices});
				} else {
					$item->{success} = 0;
				}
				$responses->enqueue($item);
				last;
			};
	
			$command eq EXECUTE and do {
				if (defined $item->{reset}) {
					if(!$owx->Reset()) {
						$item->{success}=0;
						$responses->enqueue($item);
						last;
					};
				};
				my $res = $owx->Complex($item->{address},$item->{writedata},$item->{numread});
				if (defined $res) {
					my $writelen = defined $item->{writedata} ? split (//,$item->{writedata}) : 0;
					my @result = split (//, $res);
					$item->{readdata} = 9+$writelen < @result ? substr($res,9+$writelen) : "";
					$item->{success} = 1;
					$responses->enqueue($item);
					if ($item->{delay}) {
						select (undef,undef,undef,$item->{delay}/1000); #TODO implement device (address) specific wait
					}
				} else {
					$item->{success} = 0;
					$responses->enqueue($item);
				}
				last;
			};
			
			$command eq EXIT and do {
				$responses->enqueue($item);
				last;
				#return undef;
			};
		};
	};
};

sub log($$) {
	my ($self,$level,$msg) = @_;
	my $responses = $self->{responses};
	$responses->enqueue({
		command => LOG,
		level   => $level,
		message => $msg
	});
};

1;
