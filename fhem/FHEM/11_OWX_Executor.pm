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
		workerthread => $thr
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
	my ( $self, $reset, $owx_dev, $data, $numread, $delay ) = @_;
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

sub Poll($) {
	my ($self,$hash) = @_;
	
	# Non-blocking dequeue
	while( my $item = $self->{responses}->dequeue_nb() ) {

		my $command = $item->{command};
		
		if ($item->{success}) {
			# Work on $item
			RESPONSE_HANDLER: {
				
				$command eq SEARCH and do {
					OWX_AfterDiscover($hash,$item->{devices});
					last;
				};
				
				$command eq ALARMS and do {
					OWX_AfterAlarms($hash,$item->{devices});
					last;
				};
				
				$command eq EXECUTE and do {
					OWX_AfterExecute($hash,$item->{reset},$item->{address},$item->{writedata},$item->{numread},$item->{readdata});
					last;
				};
			};
		} else {
			#response is error
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
				$item->{success} = $devices ? 1 : 0;
				$item->{devices} = $devices;
				$responses->enqueue($item);
				last;
			};
			
			$command eq ALARMS and do {
				my $devices = $owx->Alarms();
				$item->{success} = $devices ? 1 : 0;
				$item->{devices} = $devices;
				$responses->enqueue($item);
				last;
			};
	
			$command eq EXECUTE and do {
				if (defined $item->{reset}) {
					$owx->Reset();
				};
				my $res = $owx->Complex($item->{address},$item->{writedata},$item->{numread});
				$item->{success} = $res ? 1 : 0;
				$item->{readdata} = $res;
				$responses->enqueue($item); #TODO: handle delay...
				last;
			};
			
			$command eq EXIT and do {
				return undef;
			};
		};
	};
};
	
1;
