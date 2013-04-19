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
# Define
# Init
# Verify #TODO refactor Verify...
# search
# alarms
# execute
#
########################################################################################

package OWX_FRM;

use strict;
use warnings;

use Device::Firmata::Constants qw/ :all /;

sub new() {
	my ($class) = @_;

	return bless {
		hash      => $hash,
		interface => "firmata",
	    #-- module version
		version => 4.0
	}, $class;
}

sub Define($$) {
	my ($self,$hash,$def) = @_;
	$self->{name} = $hash->{NAME};
	$self->{hash} = $hash;

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

sub Init($)
{
	my ($self,$hash) = @_;
	
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
	$firmata->onewire_search($pin);
	return undef;
}

sub Disconnect($)
{
	my ($hash) = @_;
	$hash->{STATE} = "disconnected";
};

sub FRM_OWX_observer
{
	my ( $data,$self ) = @_;
	my $command = $data->{command};
	COMMAND_HANDLER: {
		$command eq "READ_REPLY" and do {
			my $owx_device = FRM_OWX_firmata_to_device($data->{device});
			my $owx_data = pack "C*",@{$data->{data}};
			$self->{replies}->{$owx_device} = $owx_data;
			my $request = $self->{requests}->{$owx_device};
			my $data = pack "C*",@{$request->{'write'}};
			main::OWX_AfterExecute( $self->{hash}, $request->{'reset'}, $owx_device, $data, $request->{'read'}, $owx_data );
			last;			
		};
		($command eq "SEARCH_REPLY" or $command eq "SEARCH_ALARMS_REPLY") and do {
			my @owx_devices = ();
			foreach my $device (@{$data->{devices}}) {
				push @owx_devices, FRM_OWX_firmata_to_device($device);
			};
			if ($command eq "SEARCH_REPLY") {
				$self->{devs} = \@owx_devices;
				main::OWX_AfterSearch($self->{hash},\@owx_devices);
			} else {
				$self->{alarmdevs} = \@owx_devices;
				main::OWX_AfterAlarms($self->{hash},\@owx_devices);
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
				return 1;
			};
		};
	};
	return undef;
};

sub alarms() {
	my ($self) = @_;
	if ( my $hash = $self->{hash} ) {
		if ( my $frm = $hash->{IODev} ) {
			if (my $firmata = $frm->{FirmataDevice} and my $pin = $self->{pin} ) {
				$firmata->onewire_search_alarms($pin);
				return 1;
			};
		};
	};
	return undef;
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
				return 1;
			};
		};
	};
	return undef;
};

sub poll($) {
	my ($self,$hash) = @_;
	if (my $frm = $hash->{IODev} ) {
		main::FRM_poll($frm);
	};		
};

1;