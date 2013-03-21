########################################################################################
#
# OWX.pm
#
# FHEM module to commmunicate with 1-Wire bus devices
# * via an active DS2480/DS2482/DS2490/DS9097U bus master interface attached to an USB port
# * via a passive DS9097 interface attached to an USB port
# * via a network-attached CUNO
# * via a COC attached to a Raspberry Pi
# * via an Arduino running OneWireFirmata attached to USB
#
# Prof. Dr. Peter A. Henning
#
# Contributions from: Martin Fischer, Rudolf König, Boris Neubert, Joachim Herold, 
#                     Norbert Truchsess
#
# $Id: 00_OWX.pm 3.19 2013-03 - pahenning $
#
########################################################################################
#
# define <name> OWX <serial-device> for USB interfaces or
# define <name> OWX <cuno/coc-device> for a CUNO or COC interface
# define <name> OWX <arduino-pin> for a Arduino/Firmata (10_FRM.pm) interface
#    
# where <name> may be replaced by any name string 
#       <serial-device> is a serial (USB) device
#       <cuno/coc-device> is a CUNO or COC device
#       <arduino-pin> is an Arduino pin 
#
# get <name> alarms                 => find alarmed 1-Wire devices (not with CUNO)
# get <name> devices                => find all 1-Wire devices 
#
# set <name> interval <seconds>     => set period for temperature conversion and alarm testing
# set <name> followAlarms on/off    => determine whether an alarm is followed by a search for
#                                      alarmed devices
#
# attr <name> dokick 0/1            => 1 if the interface regularly kicks thermometers on the
#                                      bus to do a temperature conversion, 
#                                      and to make an alarm check
#                                      0 if not
#
########################################################################################
#
#  This programm is free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  (at your option) any later version.
#
#  The GNU General Public License can be found at
#  http://www.gnu.org/copyleft/gpl.html.
#  A copy is found in the textfile GPL.txt and important notices to the license
#  from the author is found in LICENSE.txt distributed with these scripts.
#
#  This script is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU General Public License for more details.
#
########################################################################################
package main;

use strict;
use warnings;

#-- unfortunately some things OS-dependent
my $owgdevregexp;
if( $^O =~ /Win/ ) {
  require Win32::SerialPort;
  $owgdevregexp= "com";
} else {
  require Device::SerialPort;
  $owgdevregexp= "/dev/";
} 

use vars qw{%attr %defs $init_done};

require "$attr{global}{modpath}/FHEM/DevIo.pm";

sub Log($$);

# These we may get on request
my %gets = (
   "alarms"  => "A",
   "devices" => "D"
);

# These occur in a pulldown menu as settable values for the bus master
my %sets = (
   "interval" => "T",
   "followAlarms" => "F"
);

# These are attributes
my %attrs = (
);

#-- some globals needed for the 1-Wire module
#-- Debugging 0,1,2,3
my $owx_debug=0;
#-- 8 byte 1-Wire device address
my @owx_ROM_ID  =(0,0,0,0 ,0,0,0,0); 

########################################################################################
#
# The following subroutines are independent of the bus interface
#
########################################################################################
#
# OWX_Initialize
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWX_Initialize ($) {
  my ($hash) = @_;
  #-- Provider
  $hash->{Clients}     = ":OWAD:OWCOUNT:OWID:OWLCD:OWMULTI:OWSWITCH:OWTHERM:";

  #-- Normal Devices
  $hash->{DefFn}   = "OWX_Define";
  $hash->{UndefFn} = "OWX_Undef";
  $hash->{GetFn}   = "OWX_Get";
  $hash->{SetFn}   = "OWX_Set";
  $hash->{InitFn}  = "OWX_Init";
  $hash->{AttrList}= "loglevel:0,1,2,3,4,5,6 dokick:0,1 IODev";
}

########################################################################################
#
# OWX_Define - Implements DefFn function
# 
# Parameter hash = hash of device addressed, def = definition string
#
########################################################################################

sub OWX_Define ($$) {
  my ($hash, $def) = @_;
  my @a = split("[ \t][ \t]*", $def);
  
  my $owx_hwdevice;
  
  #-- check syntax
  if(int(@a) < 3){
    return "OWX: Syntax error - must be define <name> OWX"
  }
  
  #-- check syntax
  Log 1,"OWX: Warning - Some parameter(s) ignored, must be define <name> OWX <serial-device>|<cuno/coc-device>|<arduino-pin>"
     if(int(@a) > 3);
  #-- If this line contains 3 parameters, it is the bus master definition
  my $dev = $a[2];
  
  #-- Dummy 1-Wire ROM identifier, empty device lists
  $hash->{ROM_ID}      = "FF";
  $hash->{DEVS}        = ();
  $hash->{ALARMDEVS}   = ();
  
  my $owx;
  #-- First step: check if we have a directly connected serial interface attached
  if ( $dev =~ m|$owgdevregexp|i){  
    require "$attr{global}{modpath}/FHEM/11_OWX_SER.pm";
    $owx = OWX_SER->new($hash);
  #-- First step: check if we have a COC/CUNO interface attached  
  # TODO NEED TO IMPROVE THIS  
  }elsif( $dev =~ /CUNO/ ){
    require "$attr{global}{modpath}/FHEM/11_OWX_CCC.pm";
    $owx = OWX_CCC->new($hash);
  #-- check if we are connecting to Arduino (via FRM):
  } elsif ($dev =~ /^\d{1,2}$/) {
  	require "$attr{global}{modpath}/FHEM/11_OWX_FRM.pm";
    $owx = OWX_FRM->new($hash);
  }

  if ($owx) {
  	my $ret = $owx->Define($def);
  	return $ret if $ret;  
  	
  	$hash->{OWX} = $owx;
  	
  	return OWX_Init($hash);
  }
  return undef;
}

########################################################################################
#
# OWX_Alarms - Find devices on the 1-Wire bus, 
#              which have the alarm flag set
#
# Parameter hash = hash of bus master
#
# Return: Message or list of alarmed devices
#
########################################################################################

sub OWX_Alarms ($) {
  my ($hash) = @_;

  my @owx_alarm_names=();
  
  #-- get the interface
  my $name          = $hash->{NAME};
  my $owx           = $hash->{OWX};
  my $res;

  $hash->{ALARMDEVS}=();

  if (defined $owx) {
    $res = $owx->Alarms();
  } else {
    #-- interface error
    my $owx_interface = $hash->{INTERFACE};
    if( !(defined($owx_interface))){
      return undef;
    } else {
      return "OWX: Alarms called with unknown interface $owx_interface on bus $name";
    }
  }

  if( $res == 0){
    return "OWX: No alarmed 1-Wire devices found on bus $name";
  }

  #-- walk through all the devices to get their proper fhem names
  foreach my $fhem_dev (sort keys %main::defs) {
    #-- skip if busmaster
    next if( $name eq $main::defs{$fhem_dev}{NAME} );
    #-- all OW types start with OW
    next if( substr($main::defs{$fhem_dev}{TYPE},0,2) ne "OW");
    foreach my $owx_dev  (@{$hash->{ALARMDEVS}}) {
      #-- two pieces of the ROM ID found on the bus
      my $owx_rnf = substr($owx_dev,3,12);
      my $owx_f   = substr($owx_dev,0,2);
      my $id_owx  = $owx_f.".".$owx_rnf;
        
      #-- skip if not in alarm list
      if( $owx_dev eq $main::defs{$fhem_dev}{ROM_ID} ){
        $main::defs{$fhem_dev}{STATE} = "Alarmed";
        push(@owx_alarm_names,$main::defs{$fhem_dev}{NAME});
      }
    }
  }
  #-- so far, so good - what do we want to do with this ?
  return "OWX: $res alarmed 1-Wire devices found on bus $name (".join(",",@owx_alarm_names).")";
}  

########################################################################################
# 
# OWX_Complex - Send match ROM, data block and receive bytes as response
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

sub OWX_Complex ($$$$) {
  my ($hash,$owx_dev,$data,$numread) =@_;
  my $name   = $hash->{NAME};
    
  #-- get the interface
  my $owx = $hash->{OWX};

  if (defined $owx) {
	return $owx->Complex($owx_dev,$data,$numread);
  } else {
	#-- interface error
  	my $owx_interface = $hash->{INTERFACE};
  	if( !(defined($owx_interface))) {
      #Log 3,"OWX: Complex called with undefined interface";
      return 0;
    } else {
	  Log 3,"OWX: Complex called with unknown interface $owx_interface on bus $name";
      return 0;
    }
  }
}

########################################################################################
#
# OWX_CRC - Check the CRC8 code of a device address in @owx_ROM_ID
#
# Parameter romid = if not zero, return the CRC8 value instead of checking it
#
########################################################################################

my @crc8_table = (
    0, 94,188,226, 97, 63,221,131,194,156,126, 32,163,253, 31, 65,
    157,195, 33,127,252,162, 64, 30, 95, 1,227,189, 62, 96,130,220,
    35,125,159,193, 66, 28,254,160,225,191, 93, 3,128,222, 60, 98,
    190,224, 2, 92,223,129, 99, 61,124, 34,192,158, 29, 67,161,255,
    70, 24,250,164, 39,121,155,197,132,218, 56,102,229,187, 89, 7,
    219,133,103, 57,186,228, 6, 88, 25, 71,165,251,120, 38,196,154,
    101, 59,217,135, 4, 90,184,230,167,249, 27, 69,198,152,122, 36,
    248,166, 68, 26,153,199, 37,123, 58,100,134,216, 91, 5,231,185,
    140,210, 48,110,237,179, 81, 15, 78, 16,242,172, 47,113,147,205,
    17, 79,173,243,112, 46,204,146,211,141,111, 49,178,236, 14, 80,
    175,241, 19, 77,206,144,114, 44,109, 51,209,143, 12, 82,176,238,
    50,108,142,208, 83, 13,239,177,240,174, 76, 18,145,207, 45,115,
    202,148,118, 40,171,245, 23, 73, 8, 86,180,234,105, 55,213,139,
    87, 9,235,181, 54,104,138,212,149,203, 41,119,244,170, 72, 22,
    233,183, 85, 11,136,214, 52,106, 43,117,151,201, 74, 20,246,168,
    116, 42,200,150, 21, 75,169,247,182,232, 10, 84,215,137,107, 53);


sub OWX_CRC ($) {
  my ($romid) = @_;
  my $crc8=0;  

  if( $romid eq "0" ){  
    for(my $i=0; $i<8; $i++){
      $crc8 = $crc8_table[ $crc8 ^ $owx_ROM_ID[$i] ];
    }  
    return $crc8;
  } else {
    #-- from search string to byte id
    $romid=~s/\.//g;
    for(my $i=0;$i<8;$i++){
      $owx_ROM_ID[$i]=hex(substr($romid,2*$i,2));
    }
    for(my $i=0; $i<7; $i++){
      $crc8 = $crc8_table[ $crc8 ^ $owx_ROM_ID[$i] ];
    }  
    return $crc8;
  }
}  

########################################################################################
#
# OWX_CRC - Check the CRC8 code of an a byte string
#
# Parameter string, crc. 
# If crc is defined, make a comparison, otherwise output crc8
#
########################################################################################

sub OWX_CRC8 ($$) {
  my ($string,$crc) = @_;
  my $crc8=0;  
  my @strhex;
  
  #Log 1,"CRC8 calculated for string of length ".length($string);

  for(my $i=0; $i<length($string); $i++){
    $strhex[$i]=ord(substr($string,$i,1));
    $crc8 = $crc8_table[ $crc8 ^ $strhex[$i] ];
  }
   
  if( defined($crc) ){
    my $crcx = ord($crc);
    if ( $crcx == $crc8 ){
      return 1;
    }else{
      return 0;
    }
  }else{
    #Log 1,"Returning $crc8";
    return $crc8;
  }
}  

########################################################################################
#
# OWX_CRC16 - Calculate the CRC16 code of a string 
#
#  TODO UNFINISHED CODE
#
# Parameter crc - previous CRC code, c next character
#
########################################################################################

my @crc16_table = (
0x0000, 0xC0C1, 0xC181, 0x0140, 0xC301, 0x03C0, 0x0280, 0xC241,
0xC601, 0x06C0, 0x0780, 0xC741, 0x0500, 0xC5C1, 0xC481, 0x0440,
0xCC01, 0x0CC0, 0x0D80, 0xCD41, 0x0F00, 0xCFC1, 0xCE81, 0x0E40,
0x0A00, 0xCAC1, 0xCB81, 0x0B40, 0xC901, 0x09C0, 0x0880, 0xC841,
0xD801, 0x18C0, 0x1980, 0xD941, 0x1B00, 0xDBC1, 0xDA81, 0x1A40,
0x1E00, 0xDEC1, 0xDF81, 0x1F40, 0xDD01, 0x1DC0, 0x1C80, 0xDC41,
0x1400, 0xD4C1, 0xD581, 0x1540, 0xD701, 0x17C0, 0x1680, 0xD641,
0xD201, 0x12C0, 0x1380, 0xD341, 0x1100, 0xD1C1, 0xD081, 0x1040,
0xF001, 0x30C0, 0x3180, 0xF141, 0x3300, 0xF3C1, 0xF281, 0x3240,
0x3600, 0xF6C1, 0xF781, 0x3740, 0xF501, 0x35C0, 0x3480, 0xF441,
0x3C00, 0xFCC1, 0xFD81, 0x3D40, 0xFF01, 0x3FC0, 0x3E80, 0xFE41,
0xFA01, 0x3AC0, 0x3B80, 0xFB41, 0x3900, 0xF9C1, 0xF881, 0x3840,
0x2800, 0xE8C1, 0xE981, 0x2940, 0xEB01, 0x2BC0, 0x2A80, 0xEA41,
0xEE01, 0x2EC0, 0x2F80, 0xEF41, 0x2D00, 0xEDC1, 0xEC81, 0x2C40,
0xE401, 0x24C0, 0x2580, 0xE541, 0x2700, 0xE7C1, 0xE681, 0x2640,
0x2200, 0xE2C1, 0xE381, 0x2340, 0xE101, 0x21C0, 0x2080, 0xE041,
0xA001, 0x60C0, 0x6180, 0xA141, 0x6300, 0xA3C1, 0xA281, 0x6240,
0x6600, 0xA6C1, 0xA781, 0x6740, 0xA501, 0x65C0, 0x6480, 0xA441,
0x6C00, 0xACC1, 0xAD81, 0x6D40, 0xAF01, 0x6FC0, 0x6E80, 0xAE41,
0xAA01, 0x6AC0, 0x6B80, 0xAB41, 0x6900, 0xA9C1, 0xA881, 0x6840,
0x7800, 0xB8C1, 0xB981, 0x7940, 0xBB01, 0x7BC0, 0x7A80, 0xBA41,
0xBE01, 0x7EC0, 0x7F80, 0xBF41, 0x7D00, 0xBDC1, 0xBC81, 0x7C40,
0xB401, 0x74C0, 0x7580, 0xB541, 0x7700, 0xB7C1, 0xB681, 0x7640,
0x7200, 0xB2C1, 0xB381, 0x7340, 0xB101, 0x71C0, 0x7080, 0xB041,
0x5000, 0x90C1, 0x9181, 0x5140, 0x9301, 0x53C0, 0x5280, 0x9241,
0x9601, 0x56C0, 0x5780, 0x9741, 0x5500, 0x95C1, 0x9481, 0x5440,
0x9C01, 0x5CC0, 0x5D80, 0x9D41, 0x5F00, 0x9FC1, 0x9E81, 0x5E40,
0x5A00, 0x9AC1, 0x9B81, 0x5B40, 0x9901, 0x59C0, 0x5880, 0x9841,
0x8801, 0x48C0, 0x4980, 0x8941, 0x4B00, 0x8BC1, 0x8A81, 0x4A40,
0x4E00, 0x8EC1, 0x8F81, 0x4F40, 0x8D01, 0x4DC0, 0x4C80, 0x8C41,
0x4400, 0x84C1, 0x8581, 0x4540, 0x8701, 0x47C0, 0x4680, 0x8641,
0x8201, 0x42C0, 0x4380, 0x8341, 0x4100, 0x81C1, 0x8081, 0x4040
);

sub OWX_CRC16 ($$$) {
  my ($string,$crclo,$crchi) = @_;
  my $crc16=0;  
  my @strhex;
  
  #Log 1,"CRC16 calculated for string of length ".length($string);

  for(my $i=0; $i<length($string); $i++){
    $strhex[$i]=ord(substr($string,$i,1));
    $crc16 = $crc16_table[ ($crc16 ^ $strhex[$i]) & 0xFF ] ^ ($crc16 >> 8);
  }
   
  if( defined($crclo) & defined($crchi) ){
    my $crc = (255-ord($crclo))+256*(255-ord($crchi));
    if ($crc == $crc16 ){
      return 1;
    }else{
      return 0;
    }
  }else{
    return $crc16;
  }
}  

########################################################################################
#
# OWX_Discover - Discover devices on the 1-Wire bus, 
#                autocreate devices if not already present
#
# Parameter hash = hash of bus master
#
# Return: List of devices in table format or undef
#
########################################################################################

sub OWX_Discover ($) {
  my ($hash) = @_;
  my $res;
  my $ret= "";
  my $name = $hash->{NAME};
  my $exname;
  my $acname;
  
  #-- get the interface
  my $owx = $hash->{OWX};
  my @owx_names=();

  #-- Discover all devices on the 1-Wire bus, they will be found in $hash->{DEVS}
  if (defined $owx) {
	$res = $owx->Discover();
  } else {
  	my $owx_interface = $hash->{INTERFACE};
    if( !defined($owx_interface) ) {
      return undef;
    } else {
      Log 1,"OWX: Discover called with unknown interface $owx_interface";
      return undef;
    } 
  }

  #-- Go through all devices found on this bus
  foreach my $owx_dev  (@{$hash->{DEVS}}) {
    #-- ignore those which do not have the proper pattern
    if( !($owx_dev =~ m/[0-9A-F]{2}\.[0-9A-F]{12}\.[0-9A-F]{2}/) ){
      Log 3,"OWX: Invalid 1-Wire device ID $owx_dev, ignoring it";
      next;
    }
    
    #-- three pieces of the ROM ID found on the bus
    my $owx_rnf = substr($owx_dev,3,12);
    my $owx_f   = substr($owx_dev,0,2);
    my $owx_crc = substr($owx_dev,15,3);
    my $id_owx  = $owx_f.".".$owx_rnf;
      
    my $match = 0;
    
    #-- Check against all existing devices  
    foreach my $fhem_dev (sort keys %main::defs) { 
      #-- skip if busmaster
      # next if( $hash->{NAME} eq $main::defs{$fhem_dev}{NAME} );
      #-- all OW types start with OW
      next if( !defined($main::defs{$fhem_dev}{TYPE}));
      next if( substr($main::defs{$fhem_dev}{TYPE},0,2) ne "OW");
      my $id_fhem = substr($main::defs{$fhem_dev}{ROM_ID},0,15);
      #-- skip interface device
      next if( length($id_fhem) != 15 );
      #-- testing if equal to the one found here  
      #   even with improper family
      #   Log 1, " FHEM-Device = ".substr($id_fhem,3,12)." OWX discovered device ".substr($id_owx,3,12);
      if( substr($id_fhem,3,12) eq substr($id_owx,3,12) ) {
        #-- warn if improper family id
        if( substr($id_fhem,0,2) ne substr($id_owx,0,2) ){
          Log 1, "OWX: Warning, $fhem_dev is defined with improper family id ".substr($id_fhem,0,2). 
           ", must enter correct model in configuration";
           #$main::defs{$fhem_dev}{OW_FAMILY} = substr($id_owx,0,2);
        }
        $exname=$main::defs{$fhem_dev}{NAME};
        push(@owx_names,$exname);
        #-- replace the ROM ID by the proper value including CRC
        $main::defs{$fhem_dev}{ROM_ID}=$owx_dev;
        $main::defs{$fhem_dev}{PRESENT}=1;    
        $match = 1;
        last;
      }
      #
    }
 
    #-- Determine the device type. This is done manually here
    #   could be automatic as in OWServer
    my $acstring;
    my $chip;
    #-- Family 01 = ROM display    
    if( $owx_f eq "01" ){
      $chip     = "DS2401";
      $acstring = "OWID";  
    #-- Family 10 = Temperature sensor DS1820
    }elsif( $owx_f eq "10" ){
      $chip     = "DS1820";
      $acstring = "OWTHERM DS1820";  
    #-- Family 12 = Switch DS2406
    }elsif( $owx_f eq "12" ){
      $chip     = "DS2406";
      $acstring = "OWSWITCH DS2406";     
    #-- Family 1D = Counter/RAM DS2423
    }elsif( $owx_f eq "1D" ){
      $chip     = "DS2423";
      $acstring = "OWCOUNT DS2423";            
    #-- Family 20 = A/D converter DS2450
    } elsif( $owx_f eq "20" ){
      $chip     = "DS2450";
      $acstring = "OWAD DS2450"; 
    #-- Family 22 = Temperature sensor DS1822
    }elsif( $owx_f eq "22" ){
      $chip     = "DS1822";
      $acstring = "OWTHERM DS1822";  
    #-- Family 26 = Multisensor DS2438
    }elsif( $owx_f eq "26" ){
      $chip     = "DS2438";
      $acstring = "OWMULTI DS2438";
    #-- Family 28 = Temperature sensor DS18B20
    }elsif( $owx_f eq "28" ){
      $chip     = "DS18B20";
      $acstring = "OWTHERM DS18B20";   
    #-- Family 29 = Switch DS2408
    }elsif( $owx_f eq "29" ){
      $chip     = "DS2408";
      $acstring = "OWSWITCH DS2408";  
    #-- Family 3A = Switch DS2413
    }elsif( $owx_f eq "3A" ){
      $chip     = "DS2413";
      $acstring = "OWSWITCH DS2413";  
    #-- Family FF = LCD display    
    }elsif( $owx_f eq "FF" ){
      $chip     = "LCD";
      $acstring = "OWLCD";              
    #-- All unknown families are ID only (ID-Chips have family id 09)
    } else {
      $chip     = "unknown";
      $acstring = "OWID $owx_f";  
    }
       
    #Log 1,"###\nfor the following device match=$match, chip=$chip name=$name acstring=$acstring";
    #-- device exists
    if( $match==1 ){
      $ret .= sprintf("%s.%s      %-10s %s\n", $owx_f,$owx_rnf, $chip, $exname);
    #-- device unknoen, autocreate
    }else{
    #-- example code for checking global autocreate - do we want this ?
    #foreach my $d (keys %defs) {
    #next if($defs{$d}{TYPE} ne "autocreate");
    #return undef if(AttrVal($defs{$d}{NAME},"disable",undef));
      my $acname = sprintf "OWX_%s_%s",$owx_f,$owx_rnf;
      #Log 1, "to define $acname $acstring $owx_rnf";
      $res = CommandDefine(undef,"$acname $acstring $owx_rnf");
      if($res) {
        $ret.= "OWX: Error autocreating with $acname $acstring $owx_rnf: $res\n";
      } else{
        select(undef,undef,undef,0.1);
        push(@owx_names,$acname);
        $main::defs{$acname}{PRESENT}=1;
        #-- THIS IODev, default room (model is set in the device module)
        CommandAttr (undef,"$acname IODev $hash->{NAME}"); 
        CommandAttr (undef,"$acname room OWX"); 
        #-- replace the ROM ID by the proper value 
        $main::defs{$acname}{ROM_ID}=$owx_dev;
        $ret .= sprintf("%s.%s      %-10s %s\n", $owx_f,$owx_rnf, $chip, $acname);
      } 
    }
  }

  #-- final step: Undefine all 1-Wire devices which 
  #   are autocreated and
  #   not discovered on this bus 
  #   but have this IODev
  foreach my $fhem_dev (sort keys %main::defs) {
    #-- skip if malformed device
    #next if( !defined($main::defs{$fhem_dev}{NAME}) );
    #-- all OW types start with OW, but safeguard against deletion of other devices
    #next if( !defined($main::defs{$fhem_dev}{TYPE}));
    next if( substr($main::defs{$fhem_dev}{TYPE},0,2) ne "OW");
    next if( uc($main::defs{$fhem_dev}{TYPE}) eq "OWX");
    next if( uc($main::defs{$fhem_dev}{TYPE}) eq "OWFS");
    next if( uc($main::defs{$fhem_dev}{TYPE}) eq "OWSERVER");
    next if( uc($main::defs{$fhem_dev}{TYPE}) eq "OWDEVICE");
    #-- restrict to autocreated devices
    next if( $main::defs{$fhem_dev}{NAME} !~ m/OWX_[0-9a-fA-F]{2}_/);
    #-- skip if the device is present.
    next if( $main::defs{$fhem_dev}{PRESENT} == 1);
    #-- skip if different IODev, but only if other IODev exists
    if ( $main::defs{$fhem_dev}{IODev} ){
      next if( $main::defs{$fhem_dev}{IODev}{NAME} ne $hash->{NAME} );
    }
    Log 1, "OWX: Deleting unused 1-Wire device $main::defs{$fhem_dev}{NAME} of type $main::defs{$fhem_dev}{TYPE}";
    CommandDelete(undef,$main::defs{$fhem_dev}{NAME});
    #Log 1, "present= ".$main::defs{$fhem_dev}{PRESENT}." iodev=".$main::defs{$fhem_dev}{IODev}{NAME};
  }
  #-- Log the discovered devices
  Log 1, "OWX: 1-Wire devices found on bus $name (".join(",",@owx_names).")";
  #-- tabular view as return value
  return "OWX: 1-Wire devices found on bus $name \n".$ret;
  
}   

########################################################################################
#
# OWX_Get - Implements GetFn function 
#
#  Parameter hash = hash of the bus master a = argument array
#
########################################################################################

sub OWX_Get($@) {
  my ($hash, @a) = @_;
  return "OWX: Get needs exactly one parameter" if(@a != 2);

  my $name     = $hash->{NAME};
  my $owx_dev  = $hash->{ROM_ID};

  if( $a[1] eq "alarms") {
    my $res = OWX_Alarms($hash);
    #-- process result
    return $res
    
  } elsif( $a[1] eq "devices") {
    my $res = OWX_Discover($hash);
    #-- process result
    return $res
    
  } else {
    return "OWX: Get with unknown argument $a[1], choose one of ". 
    join(",", sort keys %gets);
  }
}

#######################################################################################
# 
# OWX_Init - Re-Initialize the device 
#
# Parameter hash = hash of bus master
#
# Return 1 : OK
#        0 : not OK
#
########################################################################################

sub OWX_Init ($) {
  my ($hash)=@_;
  
  #-- get the interface
  my $owx = $hash->{OWX};
  
  if (defined $owx) {
  	  #-- Third step: see, if a bus interface is detected
  	if (!($owx->Detect())) {
      $hash->{PRESENT} = 0;
      readingsSingleUpdate($hash,"state","failed",1);
      $init_done = 1; 
      return "OWX_Init failed";
    }
  	my $ret = $owx->Init();
  	return $ret if ($ret);
  } else {
    #-- interface error
  	my $owx_interface = $hash->{INTERFACE};
	if( !(defined($owx_interface))){
      return "OWX: Init called with undefined interface";
	} else {
      return "OWX: Init called with unknown interface $owx_interface";
	}
  }
  
  #-- Fourth step: discovering devices on the bus
  #   in 10 seconds discover all devices on the 1-Wire bus
  InternalTimer(gettimeofday()+10, "OWX_Discover", $hash,0);
  
  #-- Default settings
  $hash->{interval}     = 300;          # kick every 5 minutes
  $hash->{followAlarms} = "off";
  $hash->{ALARMED}      = "no";
  
  #-- InternalTimer blocks if init_done is not true
  my $oid = $init_done;
  $hash->{PRESENT} = 1;
  readingsSingleUpdate($hash,"state","defined",1);
  $init_done = 1;
  #-- Intiate first alarm detection and eventually conversion in a minute or so
  InternalTimer(gettimeofday() + $hash->{interval}, "OWX_Kick", $hash,1);
  $init_done     = $oid;
  $hash->{STATE} = "Active";
  return undef;
}

########################################################################################
#
# OWX_Kick - Initiate some processes in all devices
#
# Parameter hash = hash of bus master
#
# Return 1 : OK
#        0 : Not OK
#
########################################################################################

sub OWX_Kick($) {
  my($hash) = @_;
  my $ret;

  #-- Call us in n seconds again.
  InternalTimer(gettimeofday()+ $hash->{interval}, "OWX_Kick", $hash,1);
  #-- During reset we see if an alarmed device is present.
  OWX_Reset($hash);
   
  #-- Only if we have the dokick attribute set to 1
  if( defined($attr{$hash->{NAME}}{dokick}) &&  ($attr{$hash->{NAME}}{dokick} eq "1") ){
    #-- issue the skip ROM command \xCC followed by start conversion command \x44 
    $ret = OWX_Complex($hash,"","\xCC\x44",0);
    if( $ret eq 0 ){
      Log 3, "OWX: Failure in temperature conversion\n";
      return 0;
    }
    #-- sleeping for some time
    select(undef,undef,undef,0.5);
  }
  return 1;
}

########################################################################################
# 
# OWX_Reset - Reset the 1-Wire bus 
#
# Parameter hash = hash of bus master
#
# Return 1 : OK
#        0 : not OK
#
########################################################################################

sub OWX_Reset ($) {
  my ($hash)=@_;
  
  #-- get the interface
  my $owx           = $hash->{OWX};
  
  if (defined $owx) {
	return $owx->Reset();
  } else {  	
    #-- interface error
    my $owx_interface = $hash->{INTERFACE};
    if( !(defined($owx_interface))){
      return 0;
    } else {
      Log 3,"OWX: Reset called with unknown interface $owx_interface";
      return 0;
    }
  }
}

########################################################################################
#
# OWX_Set - Implements SetFn function
# 
# Parameter hash , a = argument array
#
########################################################################################

sub OWX_Set($@) {
  my ($hash, @a) = @_;
  my $name = shift @a;
  my $res;

  #-- First we need to find the ROM ID corresponding to the device name
  my $owx_romid =  $hash->{ROM_ID};
  Log 5, "OWX_Set request $name $owx_romid ".join(" ",@a);

  #-- for the selector: which values are possible
  return join(" ", sort keys %sets) if(@a != 2);
  return "OWX_Set: With unknown argument $a[0], choose one of " . join(" ", sort keys %sets)
    if(!defined($sets{$a[0]}));
    
  #-- Set timer value
  if( $a[0] eq "interval" ){
    #-- only values >= 15 secs allowed
    if( $a[1] >= 15){
      $hash->{interval} = $a[1];  
  	  $res = 1;
  	} else {
  	  $res = 0;
  	}
  }
  
  #-- Set alarm behaviour
  if( $a[0] eq "followAlarms" ){
    #-- only values >= 15 secs allowed
    if( (lc($a[1]) eq "off") && ($hash->{followAlarms} eq "on") ){
      $hash->{interval} = "off";  
  	  $res = 1;
  	}elsif( (lc($a[1]) eq "on") && ($hash->{followAlarms} eq "off") ){
      $hash->{interval} = "off";  
  	  $res = 1;
  	} else {
  	  $res = 0;
  	}
    
  }
  Log GetLogLevel($name,3), "OWX_Set $name ".join(" ",@a)." => $res";  
  DoTrigger($name, undef) if($init_done);
  return "OWX_Set => $name ".join(" ",@a)." => $res";
}

########################################################################################
#
# OWX_Undef - Implements UndefFn function
#
# Parameter hash = hash of the bus master, name
#
########################################################################################

sub OWX_Undef ($$) {
  my ($hash, $name) = @_;
  RemoveInternalTimer($hash);
  DevIo_CloseDev($hash);
  return undef;
}

########################################################################################
#
# OWX_Verify - Verify a particular device on the 1-Wire bus
#
# Parameter hash = hash of bus master, dev =  8 Byte ROM ID of device to be tested
#
# Return 1 : device found
#        0 : device not found
#
########################################################################################

sub OWX_Verify ($$) {
  my ($hash,$dev) = @_;
  my $i;
  
  #-- get the interface
  my $owx           = $hash->{OWX};

  if (defined $owx) {
  	return $owx->Verify($dev);
  } else {
    #-- interface error
	my $owx_interface = $hash->{INTERFACE};
    if( !(defined($owx_interface))){
      return 0;
    } else {
      Log 1,"OWX: Verify called with unknown interface $owx_interface";
      return 0;
    }
  }
}

1;

=pod
=begin html

<a name="OWX"></a>
        <h3>OWX</h3>
        <p> FHEM module to commmunicate with 1-Wire bus devices</p>
        <ul>
            <li>via an active DS2480/DS2482/DS2490/DS9097U bus master interface attached to an USB
                port or </li>
            <li>via a passive DS9097 interface attached to an USB port or</li>
            <li>via a network-attached CUNO or through a COC on the RaspBerry Pi</li>
            <li>via an Arduino running OneWireFirmata attached to USB</li>
        </ul> Internally these interfaces are vastly different, read the corresponding <a
            href="http://fhemwiki.de/wiki/Interfaces_f%C3%BCr_1-Wire"> Wiki pages </a>
        <br />
        <br />
        <h4>Example</h4><br />
        <p>
            <code>define OWio1 OWX /dev/ttyUSB1</code>
            <br />
            <code>define OWio2 OWX COC</code>
            <br />
            <code>define OWio3 OWX 10</code>
            <br />
        </p>
        <br />
        <a name="OWXdefine"></a>
        <h4>Define</h4>
        <p>
            <code>define &lt;name&gt; OWX &lt;serial-device&gt;</code> or <br />
            <code>define &lt;name&gt; OWX &lt;cuno/coc-device&gt;</code> or <br />
            <code>define &lt;name&gt; OWX &lt;arduino-pin&gt;</code>
            <br /><br /> Define a 1-Wire interface to communicate with a 1-Wire bus.<br />
            <br />
        </p>
        <ul>
            <li>
                <code>&lt;serial-device&gt;</code> The serial device (e.g. USB port) to which the
                1-Wire bus is attached.</li>
            <li>
                <code>&lt;cuno-device&gt;</code> The previously defined CUNO to which the 1-Wire bus
                is attached. </li>
            <li>
                <code>&lt;arduino-pin&gt;</code> The pin of the previous defined <a href="#FRM">FRM</a>
                to which the 1-Wire bus is attached. If there is more than one FRM device defined
                use <a href="#IODev">IODev</a> attribute to select which FRM device to use.</li>
        </ul>
        <br />
        <a name="OWXset"></a>
        <h4>Set</h4>
        <ul>
            <li><a name="owx_interval">
                    <code>set &lt;name&gt; interval &lt;value&gt;</code>
                </a>
                <br />sets the time period in seconds for "kicking" the 1-Wire bus when the <a href="#OWXdokick">dokick attribute</a> is set (default
                is 300 seconds).
            </li>
            <li><a name="owx_followAlarms">
                    <code>set &lt;name&gt; followAlarms on|off</code>
                </a>
                <br /><br /> instructs the module to start an alarm search in case a reset pulse
                discovers any 1-Wire device which has the alarm flag set. </li>
        </ul>
        <br />
        <a name="OWXget"></a>
        <h4>Get</h4>
        <ul>
            <li><a name="owx_alarms"></a>
                <code>get &lt;name&gt; alarms</code>
                <br /><br /> performs an "alarm search" for devices on the 1-Wire bus and, if found,
                generates an event in the log (not with CUNO). </li>
            <li><a name="owx_devices"></a>
                <code>get &lt;name&gt; devices</code>
                <br /><br /> redicovers all devices on the 1-Wire bus. If a device found has a
                previous definition, this is automatically used. If a device is found but has no
                definition, it is autocreated. If a defined device is not on the 1-Wire bus, it is
                autodeleted. </li>
        </ul>
        <br />
        <a name="OWXattr"></a>
        <h4>Attributes</h4>
        <ul>
            <li><a name="OWXdokick"><code>attr &lt;name&gt; dokick 0|1</code></a>
                <br />1 if the interface regularly kicks thermometers on the bus to do a temperature conversion, 
               and to perform an alarm check, 0 if not</li>
            <li><a name="OWXIODev"><code>attr &lt;name&gt; IODev <FRM-device></code></a>
                <br />assignes a specific FRM-device to OWX when working through an Arduino. 
                Required only if there is more than one FRM defined.</li>
            <li>Standard attributes <a href="#alias">alias</a>, <a href="#comment">comment</a>, <a
                    href="#event-on-update-reading">event-on-update-reading</a>, <a
                    href="#event-on-change-reading">event-on-change-reading</a>, <a href="#room"
                    >room</a>, <a href="#eventMap">eventMap</a>, <a href="#loglevel">loglevel</a>,
                    <a href="#webCmd">webCmd</a></li>
        </ul>

=end html
=cut