########################################################################################
#
# OWX_FRM.pm
#
# FHEM module providing hardware dependent functions for the FRM interface of OWX
#
# Norbert Truchsess
#
# $Id: 11_OWX_FRM.pm 2013-03 - ntruchsess $
#
########################################################################################
#
# Provides the following methods for OWX
#
# Alarms
# Complex
# Define
# Discover
# Init
# Reset
# Verify
#
########################################################################################

package OWX_FRM;

use strict;
use warnings;

use Device::Firmata::Constants qw/ :all /;

sub new($) {
	my ($class,$hash) = @_;

	return bless {
		hash => $hash,
	    #-- module version
		version => 4.0
	}, $class;
}

sub Define($) {
	my ($self,$def) = @_;
	my $hash = $self->{hash};
  	$hash->{INTERFACE} = "firmata";

  	if (defined $main::modules{FRM}) {
		main::AssignIoPort($hash);
  		my @a = split("[ \t][ \t]*", $def);
		my $u = "wrong syntax: define <name> FRM_XXX pin";
  		return $u unless int(@a) > 0;
  		$self->{pin} = $a[2];
  		return undef;
  	} else {
  	  my $ret = "module FRM not yet loaded, please define an FRM device first."; 
  	  main::Log(1,$ret);
  	  return $ret;
  	}
}

sub Detect () {
  my ($self) = @_;
  my $hash = $self->{hash};

  my $ret;
  my $name = $hash->{NAME};
  my $ress = "OWX: 1-Wire bus $name: interface ";

  my $iodev = $hash->{IODev};
  if (defined $iodev and defined $iodev->{FirmataDevice} and defined $iodev->{FD}) { #TODO $iodev->{FD} is not available on windows...
    $ret=1;
    $ress .= "Firmata detected in $iodev->{NAME}";
  } else {
	$ret=0;
	$ress .= defined $iodev ? "$iodev->{NAME} is not connected to Firmata" : "not associated to any FRM device";
  }
  main::Log(1, $ress);
  return $ret; 
}

########################################################################################
# 
# Init - Initialize the 1-wire device
#
# Parameter hash = hash of bus master
#
# Return 1 : OK
#        0 : not OK
#
########################################################################################

sub Init()
{
	my ($self) = @_;
	my $hash = $self->{hash};
	
	my $pin = $self->{pin};
	my $ret = main::FRM_Init_Pin_Client($hash,[$pin],PIN_ONEWIRE);
	return $ret if (defined $ret);
	my $firmata = $hash->{IODev}->{FirmataDevice};
	$firmata->observe_onewire($pin,\&FRM_OWX_observer,$self);
	$self->{replies} = {};
	$self->{devs} = [];
	if ( main::AttrVal($hash->{NAME},"buspower","") eq "parasitic" ) {
		$firmata->onewire_config($pin,1);
	}
	$hash->{STATE}="Initialized";
	$firmata->onewire_search($pin);
	return undef;
}

sub FRM_OWX_observer
{
	my ( $data,$self ) = @_;
	my $command = $data->{command};
	COMMAND_HANDLER: {
		$command eq "READ_REPLY" and do {
			my $owx_device = FRM_OWX_firmata_to_device($data->{device});
			my $owx_data = pack "C*",@{$data->{data}};
			$self->{replies}->{$owx_device} = $owx_data;
			unless ($self->{synchronous}) {
				my $request = $self->{requests}->{$owx_device};
				my $data = pack "C*",@{$request->{'write'}};
				main::OWX_AfterExecute( $self->{hash}, $request->{'reset'}, $owx_device, $data, $request->{'read'}, $owx_data );
			}
			last;			
		};
		($command eq "SEARCH_REPLY" or $command eq "SEARCH_ALARMS_REPLY") and do {
			my @owx_devices = ();
			foreach my $device (@{$data->{devices}}) {
				push @owx_devices, FRM_OWX_firmata_to_device($device);
			};
			if ($command eq "SEARCH_REPLY") {
				$self->{devs} = \@owx_devices;
				unless ($self->{synchronous}) {
					main::OWX_AfterSearch($self->{hash},\@owx_devices);
				};
			} else {
				$self->{alarmdevs} = \@owx_devices;
				unless ($self->{synchronous}) {
					main::OWX_AfterAlarms($self->{hash},\@owx_devices);
				};
			};
			last;
		};
	};
};

########### functions implementing interface to OWX ##########

sub FRM_OWX_device_to_firmata
{
	my @device;
	foreach my $hbyte (unpack "A2xA2A2A2A2A2A2xA2", shift) {
		push @device, hex $hbyte;
	}
	return {
		family => shift @device,
		crc => pop @device,
		identity => \@device,
	}
}

sub FRM_OWX_firmata_to_device
{
	my $device = shift;
	return sprintf ("%02X.%02X%02X%02X%02X%02X%02X.%02X",$device->{family},@{$device->{identity}},$device->{crc});
}

########################################################################################
#
# Verify - Verify a particular device on the 1-Wire bus
#
# Parameter hash = hash of bus master, dev =  8 Byte ROM ID of device to be tested
#
# Return 1 : device found
#        0 : device not
#
########################################################################################

sub Verify($) {
	my ($self,$dev) = @_;
	foreach my $found ($self->{devs}) {
		if ($dev eq $found) {
			return 1;
		}
	}
	return 0;
}

sub Alarms() {
	my ($self) = @_;
	my $hash = $self->{hash};

	#-- get the interface
	my $frm = $hash->{IODev};
	return 0 unless defined $frm;
	my $firmata = $frm->{FirmataDevice};
	my $pin     = $self->{pin};
	return 0 unless ( defined $firmata and defined $pin );
	$self->{alarmdevs} = undef;			
	$firmata->onewire_search_alarms($pin);
	my $times = main::AttrVal($hash,"ow-read-timeout",1000) / 50; #timeout in ms, defaults to 1 sec
	$self->{synchronous} = 1;
	for (my $i=0;$i<$times;$i++) {
		if (main::FRM_poll($frm)) {
			if (defined $self->{alarmdevs}) {
				delete $self->{synchronous};
				return $self->{alarmdevs};
			}
		} else {
			select (undef,undef,undef,0.05);
		}
	}
	delete $self->{synchronous};
	return [];
}

########################################################################################
# 
# Reset - Reset the 1-Wire bus 
#
# Parameter hash = hash of bus master
#
# Return 1 : OK
#        0 : not OK
#
########################################################################################

sub Reset() {
	my ($self) = @_;
	if ( my $hash = $self->{hash} ) {
		if ( my $frm = $hash->{IODev} ) {
			if (my $firmata = $frm->{FirmataDevice} and my $pin = $self->{pin} ) {
				$firmata->onewire_reset($pin);
				return 1;
			};
		};
	};
	return undef;
}

########################################################################################
#
# asynchronous methods search, alarms and execute
#
########################################################################################

sub search() {
	my ($self) = @_;
	if ( my $hash = $self->{hash} ) {
		if ( my $frm = $hash->{IODev} ) {
			if (my $firmata = $frm->{FirmataDevice} and my $pin = $self->{pin} ) {
				$firmata->onewire_search($pin);
			};
		};
	};
};

sub alarms() {
	my ($self) = @_;
	if ( my $hash = $self->{hash} ) {
		if ( my $frm = $hash->{IODev} ) {
			if (my $firmata = $frm->{FirmataDevice} and my $pin = $self->{pin} ) {
				$firmata->onewire_search_alarms($pin);
			};
		};
	};
};

sub execute($$$$$) {
	my ( $self, $reset, $owx_dev, $data, $numread, $delay ) = @_;

	if ( my $hash = $self->{hash} ) {
		if ( my $frm = $hash->{IODev} ) {
			if (my $firmata = $frm->{FirmataDevice} and my $pin = $self->{pin} ) {
				my @data = unpack "C*", $data if defined $data;
				my $ow_command = {
					'reset'  => $reset,
					'skip'   => defined ($owx_dev) ? undef : 1,
					'select' => defined ($owx_dev) ? FRM_OWX_device_to_firmata($owx_dev) : undef,
					'read'   => $numread,
					'write'  => @data ? \@data : undef, 
					'delay'  => $delay
				};
		
				$owx_dev = '00.000000000000.00' unless defined $owx_dev;
				$self->{requests}->{$owx_dev} = $ow_command;
				$self->{replies}->{$owx_dev} = undef;		
		
				$firmata->onewire_command_series( $pin, $ow_command );
			};
		};
	};
};

sub poll($) {
	my ($self,$hash) = @_;
	if (my $frm = $hash->{IODev} ) {
		main::FRM_poll($frm);
	};		
};

1;