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

sub new() {
	my ($class) = @_;

	return bless {
		interface => "firmata",
	    #-- module version
		version => 4.0
	}, $class;
}

sub Define($$) {
	my ($self,$hash,$def) = @_;
	$self->{name} = $hash->{NAME};

  	if (defined $main::modules{FRM}) {
		main::AssignIoPort($hash);
  		my @a = split("[ \t][ \t]*", $def);
		my $u = "wrong syntax: define <name> FRM_XXX pin";
  		return $u unless int(@a) > 0;
  		$self->{pin} = $a[2];
  		$self->{IODev} = $hash->{IODev};
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
	my $firmata = $self->{IODev}->{FirmataDevice};
	$firmata->observe_onewire($pin,\&FRM_OWX_observer,$self);
	$self->{replies} = {};
	$self->{devs} = [];
	if ( main::AttrVal($self->{name},"buspower","") eq "parasitic" ) {
		$firmata->onewire_config($pin,1);
	}
	$self->{STATE}="Initialized";
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
			last;			
		};
		($command eq "SEARCH_REPLY" or $command eq "SEARCH_ALARMS_REPLY") and do {
			my @owx_devices = ();
			foreach my $device (@{$data->{devices}}) {
				push @owx_devices, FRM_OWX_firmata_to_device($device);
			}
			if ($command eq "SEARCH_REPLY") {
				$self->{devs} = \@owx_devices;
			} else {
				$self->{alarmdevs} = \@owx_devices;
			}
			last;
		};
	}
}

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

	#-- get the interface
	my $frm = $self->{IODev};
	return 0 unless defined $frm;
	my $firmata = $frm->{FirmataDevice};
	my $pin     = $self->{pin};
	return 0 unless ( defined $firmata and defined $pin );
	$self->{alarmdevs} = undef;			
	$firmata->onewire_search_alarms($pin);
	my $times = main::AttrVal($self->{name},"ow-read-timeout",1000) / 50; #timeout in ms, defaults to 1 sec
	for (my $i=0;$i<$times;$i++) {
		if (main::FRM_poll($frm)) {
			if (defined $self->{alarmdevs}) {
				return $self->{alarmdevs};
			}
		} else {
			select (undef,undef,undef,0.05);
		}
	}
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
	#-- get the interface
	my $frm = $self->{IODev};
	return undef unless defined $frm;
	my $firmata = $frm->{FirmataDevice};
	my $pin     = $self->{pin};
	return undef unless ( defined $firmata and defined $pin );

	$firmata->onewire_reset($pin);
	
	return 1;
}

########################################################################################
# 
# Complex - Send match ROM, data block and receive bytes as response
#
# Parameter hash    = hash of bus master, 
#           owx_dev = ROM ID of device
#           data    = string to send
#           numread = number of bytes to receive
#
# Return response, if OK
#        0 if not OK
#
########################################################################################

sub Complex ($$$) {
	my ($self,$owx_dev,$data,$numread) =@_;

	my $res = "";

	#-- get the interface
	my $frm = $self->{IODev};
	return 0 unless defined $frm;
	my $firmata = $frm->{FirmataDevice};
	my $pin     = $self->{pin};
	return 0 unless ( defined $firmata and defined $pin );

	my $ow_command = {};

	#-- has match ROM part
	if ($owx_dev) {
		$ow_command->{"select"} = FRM_OWX_device_to_firmata($owx_dev);

		#-- padding first 9 bytes into result string, since we have this
		#   in the serial interfaces as well
		$res .= "000000000";
	}

	#-- has data part
	if ($data) {
		my @data = unpack "C*", $data;
		$ow_command->{"write"} = \@data;
		$res.=$data;
	}

	#-- has receive part
	if ( $numread > 0 ) {
		$ow_command->{"read"} = $numread;
		#Firmata sends 0-address on read after skip
		$owx_dev = '00.000000000000.00' unless defined $owx_dev;
		$self->{replies}->{$owx_dev} = undef;		
	}

	$firmata->onewire_command_series( $pin, $ow_command );
	
	if ($numread) {
		my $times = main::AttrVal($self->{name},"ow-read-timeout",1000) / 50; #timeout in ms, defaults to 1 sec
		for (my $i=0;$i<$times;$i++) {
			if (main::FRM_poll($frm)) {
				if (defined $self->{replies}->{$owx_dev}) {
					$res .= $self->{replies}->{$owx_dev};
					return $res;
				}
			} else {
				select (undef,undef,undef,0.05);
			}
		}
	}
	return $res;
}

########################################################################################
#
# Discover - Discover devices on the 1-Wire bus via internal firmware
#
# Parameter hash = hash of bus master
#
# Return 0  : error
#        1  : OK
#
########################################################################################

sub Discover ($) {

	my ($self) = @_;

	#-- get the interface
	my $frm = $self->{IODev};
	return 0 unless defined $frm;
	my $firmata = $frm->{FirmataDevice};
	my $pin     = $self->{pin};
	return 0 unless ( defined $firmata and defined $pin );
	my $old_devices = $self->{devs};
	$self->{devs} = undef;			
	$firmata->onewire_search($pin);
	my $times = main::AttrVal($self->{name},"ow-read-timeout",1000) / 50; #timeout in ms, defaults to 1 sec
	for (my $i=0;$i<$times;$i++) {
		if (main::FRM_poll($frm)) {
			if (defined $self->{devs}) {
				return $self->{devs};
			}
		} else {
			select (undef,undef,undef,0.05);
		}
	}
	$self->{devs} = $old_devices;
	return $self->{devs};
}

1;