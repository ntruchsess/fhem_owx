########################################################################################
#
# OWX_FRM.pm
#
# FHEM module providing hardware dependent functions for the FRM interface of OWX
#
# Norbert Truchsess
#
# $Id: 11_OWX_CCC.pm 3.19 2013-03 - pahenning $
#
########################################################################################
#
# Provides the following subroutines for OWX
#
# Alarms
# Complex
# Discover
# Init
# Reset
# Verify
#
########################################################################################

package OWX_FRM;

use strict;
use warnings;

use vars qw{$owx_debug};
use Device::Firmata::Constants qw/ :all /;

sub new($) {
	my ($class,$hash) = @_;

	return bless {
		hash => $hash,
	}, $class;
}

sub Define($) {
	my ($self,$def) = @_;
	my $hash = $self->{hash};
  	$hash->{INTERFACE} = "firmata";

  	if (defined $main::modules{FRM}) {
		main::AssignIoPort($hash);
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
  if (defined $iodev and defined $iodev->{FirmataDevice} and defined $iodev->{FD}) {  	
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
	my $args;
	
	if (defined $hash->{DEF}) {
  		my @a = split("[ \t][ \t]*", $hash->{DEF});
  		$args = \@a;
	}
	
	my $ret = main::FRM_Init_Pin_Client($hash,$args,PIN_ONEWIRE);
	return $ret if (defined $ret);
	my $firmata = $hash->{IODev}->{FirmataDevice};
	my $pin = $hash->{PIN};
	$firmata->observe_onewire($pin,\&FRM_OWX_observer,$hash);
	$hash->{FRM_OWX_REPLIES} = {};
	$hash->{DEVS} = [];
	if ( main::AttrVal($hash->{NAME},"buspower","") eq "parasitic" ) {
		$firmata->onewire_config($pin,1);
	}
	$hash->{STATE}="Initialized";
	$firmata->onewire_search($pin);
	return undef;
}

sub FRM_OWX_observer
{
	my ( $data,$hash ) = @_;
	my $command = $data->{command};
	COMMAND_HANDLER: {
		$command eq "READ_REPLY" and do {
			my $owx_device = FRM_OWX_firmata_to_device($data->{device});
			my $owx_data = pack "C*",@{$data->{data}};
			$hash->{FRM_OWX_REPLIES}->{$owx_device} = $owx_data;
			last;			
		};
		($command eq "SEARCH_REPLY" or $command eq "SEARCH_ALARMS_REPLY") and do {
			my @owx_devices = ();
			foreach my $device (@{$data->{devices}}) {
				push @owx_devices, FRM_OWX_firmata_to_device($device);
			}
			if ($command eq "SEARCH_REPLY") {
				$hash->{DEVS} = \@owx_devices;
				#$main::attr{$hash->{NAME}}{"ow-devices"} = join " ",@owx_devices;
			} else {
				$hash->{ALARMDEVS} = \@owx_devices;
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
	my $hash = $self->{hash};
	foreach my $found ($hash->{DEVS}) {
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
	my $pin     = $hash->{PIN};
	return 0 unless ( defined $firmata and defined $pin );
	$hash->{ALARMDEVS} = undef;			
	$firmata->onewire_search_alarms($hash->{PIN});
	my $times = main::AttrVal($hash,"ow-read-timeout",1000) / 50; #timeout in ms, defaults to 1 sec
	for (my $i=0;$i<$times;$i++) {
		if (main::FRM_poll($hash->{IODev})) {
			if (defined $hash->{ALARMDEVS}) {
				return 1;
			}
		} else {
			select (undef,undef,undef,0.05);
		}
	}
	$hash->{ALARMDEVS} = [];
	return 1;
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
	my $hash = $self->{hash};
	#-- get the interface
	my $frm = $hash->{IODev};
	return undef unless defined $frm;
	my $firmata = $frm->{FirmataDevice};
	my $pin     = $hash->{PIN};
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
	my $hash = $self->{hash};

	my $res = "";

	#-- get the interface
	my $frm = $hash->{IODev};
	return 0 unless defined $frm;
	my $firmata = $frm->{FirmataDevice};
	my $pin     = $hash->{PIN};
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
		$hash->{FRM_OWX_REPLIES}->{$owx_dev} = undef;		
	}

	$firmata->onewire_command_series( $pin, $ow_command );
	
	if ($numread) {
		my $times = main::AttrVal($hash,"ow-read-timeout",1000) / 50; #timeout in ms, defaults to 1 sec
		for (my $i=0;$i<$times;$i++) {
			if (main::FRM_poll($hash->{IODev})) {
				if (defined $hash->{FRM_OWX_REPLIES}->{$owx_dev}) {
					$res .= $hash->{FRM_OWX_REPLIES}->{$owx_dev};
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
	my $hash = $self->{hash};

	#-- get the interface
	my $frm = $hash->{IODev};
	return 0 unless defined $frm;
	my $firmata = $frm->{FirmataDevice};
	my $pin     = $hash->{PIN};
	return 0 unless ( defined $firmata and defined $pin );
	my $old_devices = $hash->{DEVS};
	$hash->{DEVS} = undef;			
	$firmata->onewire_search($hash->{PIN});
	my $times = main::AttrVal($hash,"ow-read-timeout",1000) / 50; #timeout in ms, defaults to 1 sec
	for (my $i=0;$i<$times;$i++) {
		if (main::FRM_poll($hash->{IODev})) {
			if (defined $hash->{DEVS}) {
				return 1;
			}
		} else {
			select (undef,undef,undef,0.05);
		}
	}
	$hash->{DEVS} = $old_devices;
	return 1;
}

1;