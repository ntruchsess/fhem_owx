package OWX_AsyncExecutor;
use strict;
use warnings;
use constant {
	SEARCH  => 1,
	ALARMS  => 2,
	EXECUTE => 3,
	EXIT    => 4
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
		owx => $owx
	}, $class;
}

sub search() {
	my $self = shift;
	main::Log (1,"Executor->search");
	$self->{requests}->enqueue( { command => SEARCH } );
}

sub alarms() {
	my $self = shift;
	main::Log (1,"Executor->alarms");
	$self->{requests}->enqueue( { command => ALARMS } );
}

sub execute($$$$$$) {
	my ( $self, $reset, $owx_dev, $data, $numread, $delay ) = @_;
	main::Log (1,"Executor->execute");	
	$self->{requests}->enqueue(
		{
			command   => EXECUTE,
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
	$self->{owx}->Disconnect($hash);
}

sub poll($) {
	my ($self,$hash) = @_;
	
	# Non-blocking dequeue
	while( my $item = $self->{responses}->dequeue_nb() ) {

		my $command = $item->{command};
		
		if ($item->{success}) {
			# Work on $item
			RESPONSE_HANDLER: {
				
				$command eq SEARCH and do {
					my @devices = split(/;/,$item->{devices});
					main::OWX_AfterSearch($hash,\@devices);
					last;
				};
				
				$command eq ALARMS and do {
					my @devices = split(/;/,$item->{devices});
					main::OWX_AfterAlarms($hash,\@devices);
					last;
				};
				
				$command eq EXECUTE and do {
					main::OWX_AfterExecute($hash,$item->{reset},$item->{address},$item->{writedata},$item->{numread},$item->{readdata});
					last;
				};
			};
		} else {
			main::OWX_Disconnected($hash);
		};
	};
};

package OWX_Worker;

use constant {
	SEARCH  => 1,
	ALARMS  => 2,
	EXECUTE => 3,
	EXIT    => 4
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
					$owx->Reset();
				};
				my $res = $owx->Complex($item->{address},$item->{writedata},$item->{numread});
				if (defined $res) {
					if (defined $item->{address}) {
						$item->{success} = 1;
						my $writelen = split (//,$item->{writedata});
						my @result = split (//, $res);
						$item->{readdata} = 9+$writelen < @result ? substr($res,9+$writelen) : "";
						$responses->enqueue($item);
					}
					if ($item->{delay}) {
						select (undef,undef,undef,$item->{delay}/1000);
					}
				} else {
					$item->{success} = 0;
					$responses->enqueue($item);
				}
				last;
			};
			
			$command eq EXIT and do {
				return undef;
			};
		};
	};
};
	
1;
