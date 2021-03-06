########################################################################################
#
# OWMULTI.pm
#
# FHEM module to commmunicate with 1-Wire chip DS2438Z - Smart Battery Monitor
#
# Prof. Dr. Peter A. Henning
#
# $Id$
#
########################################################################################
#
# define <name> OWMULTI [<model>] <ROM_ID> [interval] or OWMULTI <FAM_ID>.<ROM_ID> [interval]
#
# where <name> may be replaced by any name string 
#     
#       <model> is a 1-Wire device type. If omitted, we assume this to be an
#              DS2438  
#       <FAM_ID> is a 1-Wire family id, currently allowed value is 26
#       <ROM_ID> is a 12 character (6 byte) 1-Wire ROM ID 
#                without Family ID, e.g. A2D90D000800 
#       [interval] is an optional query interval in seconds
#
# get <name> id          => OW_FAMILY.ROM_ID.CRC 
# get <name> present     => 1 if device present, 0 if not
# get <name> interval    => query interval
# get <name> reading     => measurement value obtained from VFunction
# get <name> temperature => temperature measurement
# get <name> VDD         => supply voltage measurement
# get <name> V|raw       => raw external voltage measurement
# get <name> version     => OWX version number
#
# set <name> interval    => set period for measurement
#
# Additional attributes are defined in fhem.cfg
# Note: attributes "tempXXXX" are read during every update operation.
#
# attr <name> tempOffset <float>        = temperature offset in degree Celsius added to the raw temperature reading 
# attr <name> tempUnit  <string>        = unit of measurement, e.g. Celsius/Kelvin/Fahrenheit or C/K/F, default is Celsius
# attr <name> VName   <string>|<string> = name for the channel | a type description for the measured value
# attr <name> VUnit   <string>|<string> = unit of measurement for the voltage channel | its abbreviation 
# attr <name> Vfunction <string>        = arbitrary functional expression involving the values VDD, V, T 
#                                         VDD is replaced by the measured supply voltage in Volt, 
#                                         V by the measured external voltage
#                                         T by the measured and corrected temperature in its unit
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

use vars qw{%attr %defs %modules $readingFnAttributes $init_done};
use strict;
use warnings;
sub Log($$);

my $owx_version="4.01";

my %gets = (
  "id"          => "",
  "present"     => "",
  "interval"    => "",
  "reading"     => "",
  "temperature" => "",
  "VDD"         => "",
  "VAD"         => "",
  "raw"         => "",
  "version"     => ""
);

my %sets = (
  "interval"    => "",
);

my %updates = (
  "present"     => "",
  "reading" => "",
);

########################################################################################
#
# The following subroutines are independent of the bus interface
#
# Prefix = OWMULTI
#
########################################################################################
#
# OWMULTI_Initialize
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWMULTI_Initialize ($) {
  my ($hash) = @_;

  $hash->{DefFn}   = "OWMULTI_Define";
  $hash->{UndefFn} = "OWMULTI_Undef";
  $hash->{GetFn}   = "OWMULTI_Get";
  $hash->{SetFn}   = "OWMULTI_Set";
  $hash->{AfterExecuteFn} = "OWXMULTI_AfterExecute";
  $hash->{AttrFn}  = "OWMULTI_Attr";

  #tempOffset = a temperature offset added to the temperature reading for correction 
  #tempUnit   = a unit of measure: C/F/K
  $hash->{AttrList}= "IODev do_not_notify:0,1 showtime:0,1 model:DS2438 loglevel:0,1,2,3,4,5 ".
                     "tempOffset tempUnit:C,Celsius,F,Fahrenheit,K,Kelvin ".
                     "VName VUnit VFunction ".
                     "interval ".
                     $readingFnAttributes;
                     
  #-- temperature and voltage globals - always the raw values from the device
  $hash->{owg_temp} = undef;
  $hash->{owg_volt} = undef;
  $hash->{owg_vdd} = undef;
  $hash->{owg_channel} = undef;
                     
  #make sure OWX is loaded so OWX_CRC is available if running with OWServer
  main::LoadModule("OWX");	
}

#######################################################################################
#
# OWMULTI_Attr - Set one attribute value for device
#
#  Parameter hash = hash of device addressed
#            a = argument array
#
########################################################################################

sub OWMULTI_Attr(@) {
  my ($do,$name,$key,$value) = @_;
  
  my $hash = $defs{$name};
  my $ret;
  
  if ( $do eq "set") {
  	ARGUMENT_HANDLER: {
  	  $key eq "interval" and do {
        # check value
        return "OWMULTI: Set with short interval, must be > 1" if(int($value) < 1);
        # update timer
        $hash->{INTERVAL} = $value;
        if ($init_done) {
          RemoveInternalTimer($hash);
          InternalTimer(gettimeofday()+$hash->{INTERVAL}, "OWMULTI_GetValues", $hash, 1);
        }
  	    last;
  	  };
    }
  }
  return $ret;
}
  
########################################################################################
#
# OWMULTI_Define - Implements DefFn function
# 
# Parameter hash = hash of device addressed, def = definition string
#
########################################################################################

sub OWMULTI_Define ($$) {
  my ($hash, $def) = @_;
  
  # define <name> OWMULTI [<model>] <id> [interval]
  # e.g.: define flow OWMULTI 525715020000 300
  my @a = split("[ \t][ \t]*", $def);
  
  my ($name,$model,$fam,$id,$crc,$interval,$ret);
  my $tn = TimeNow();
  
  #-- default
  $name          = $a[0];
  $interval      = 300;
  $ret           = "";

  #-- check syntax
  return "OWMULTI: Wrong syntax, must be define <name> OWMULTI [<model>] <id> [interval]"
       if(int(@a) < 2 || int(@a) > 6);
       
  #-- different types of definition allowed
  my $a2 = $a[2];
  my $a3 = defined($a[3]) ? $a[3] : "";
  #-- no model, 12 characters
  if( $a2 =~ m/^[0-9|a-f|A-F]{12}$/ ) {
    $model         = "DS2438";
    $fam           = "26";
    $id            = $a[2];
    if(int(@a)>=4) { $interval = $a[3]; }
    CommandAttr (undef,"$name model DS2438");
  #-- no model, 2+12 characters
   } elsif(  $a2 =~ m/^[0-9|a-f|A-F]{2}\.[0-9|a-f|A-F]{12}$/ ) {
    $fam           = substr($a[2],0,2);
    $id            = substr($a[2],3);
    if(int(@a)>=4) { $interval = $a[3]; }
    if( $fam eq "26" ){
      $model = "DS2438";
      CommandAttr (undef,"$name model DS2438"); 
    }else{
      return "OWMULTI: Wrong 1-Wire device family $fam";
    }
  #-- model, 12 characters
  } elsif(  $a3 =~ m/^[0-9|a-f|A-F]{12}$/ ) {
    $model         = $a[2];
    $id            = $a[3];
    if(int(@a)>=5) { $interval = $a[4]; }
    if( $model eq "DS2438" ){
      $fam = "26";
      CommandAttr (undef,"$name model DS2438"); 
    }else{
      return "OWMULTI: Wrong 1-Wire device model $model";
    }
  } else {    
    return "OWMULTI: $a[0] ID $a[2] invalid, specify a 12 or 2.12 digit value";
  }
  
 
  #-- determine CRC Code - only if this is a direct interface
  $crc = sprintf("%02x",OWX_CRC($fam.".".$id."00"));
  
  #-- define device internals
  $hash->{OW_ID}      = $id;
  $hash->{OW_FAMILY}  = $fam;
  $hash->{PRESENT}    = 0;
  $hash->{ROM_ID}     = "$fam.$id.$crc";
  $hash->{INTERVAL}   = $interval;

  #-- Couple to I/O device
  AssignIoPort($hash);
  if( !defined($hash->{IODev}->{NAME}) || !defined($hash->{IODev}) ){
    return "OWMULTI: Warning, no 1-Wire I/O device found for $name.";
  }
  #if( $hash->{IODev}->{PRESENT} != 1 ){
  #  return "OWMULTI: Warning, 1-Wire I/O device ".$hash->{IODev}->{NAME}." not present for $name.";
  #}
  $main::modules{OWMULTI}{defptr}{$id} = $hash;
  #--
  readingsSingleUpdate($hash,"state","defined",1);
  Log 3, "OWMULTI: Device $name defined."; 
  
  #-- Start timer for updates
  InternalTimer(time()+10, "OWMULTI_GetValues", $hash, 0);

  return undef; 
}
  
########################################################################################
#
# OWMULTI_ChannelNames - find the real channel names  
#
#  Parameter hash = hash of device addressed
#
########################################################################################

sub OWMULTI_ChannelNames($) { 
  my ($hash) = @_;
  
  my $name   = $hash->{NAME};
  my $state  = $hash->{READINGS}{"state"}{VAL};
   
  my ($cname,@cnama,$unit,@unarr);
  my ($tunit,$toffset,$tfactor,$tabbr,$vfunc);

  #-- Set channel name, channel unit for voltage channel
  $cname = defined($attr{$name}{"VName"})  ? $attr{$name}{"VName"} : "voltage|voltage";
  @cnama = split(/\|/,$cname);
  if( int(@cnama)!=2){
    Log 1, "OWMULTI: Incomplete channel name specification $cname. Better use $cname|<type of data>"
      if( $state eq "defined");
    push(@cnama,"unknown");
  }
 
  #-- unit
  $unit = defined($attr{$name}{"VUnit"})  ? $attr{$name}{"VUnit"} : "Volt|V";
  @unarr= split(/\|/,$unit);
  if( int(@unarr)!=2 ){
    Log 1, "OWMULTI: Incomplete channel unit specification $unit. Better use $unit|<abbreviation>"
      if( $state eq "defined");
    push(@unarr,"");  
  }
    
  #-- put into readings
  $hash->{owg_channel} = $cnama[0]; 
  $hash->{READINGS}{$hash->{owg_channel}}{TYPE}     = $cnama[1];  
  $hash->{READINGS}{$hash->{owg_channel}}{UNIT}     = $unarr[0];
  $hash->{READINGS}{$hash->{owg_channel}}{UNITABBR} = $unarr[1];
    
  #-- temperature scale 
  $hash->{READINGS}{"temperature"}{UNIT} = defined($attr{$name}{"tempUnit"}) ? $attr{$name}{"tempUnit"} : "Celsius";
  $tunit  = defined($attr{$name}{"tempUnit"}) ? $attr{$name}{"tempUnit"} : $hash->{READINGS}{"temperature"}{UNIT};
  $toffset = defined($attr{$name}{"tempOffset"}) ? $attr{$name}{"tempOffset"} : 0.0 ;
  $tfactor = 1.0;
  
  if( $tunit eq "Celsius" ){
    $tabbr   = "&deg;C";
  } elsif ($tunit eq "Kelvin" ){
    $tabbr   = "K";
    $toffset += "273.16"
  } elsif ($tunit eq "Fahrenheit" ){
    $tabbr   = "&deg;F";
    $toffset = ($toffset+32)/1.8;
    $tfactor = 1.8;
  } else {
    $tabbr="?";
    Log 1, "OWMULTI_FormatValues: unknown unit $tunit";
  }
  
  #-- these values are rather complex to obtain, therefore save them in the hash
  $hash->{READINGS}{"temperature"}{TYPE}     = "temperature";
  $hash->{READINGS}{"temperature"}{UNIT}     = $tunit;
  $hash->{READINGS}{"temperature"}{UNITABBR} = $tabbr;
  $hash->{tempf}{offset}                     = $toffset;
  $hash->{tempf}{factor}                     = $tfactor;
}  

########################################################################################
#
# OWMULTI_FormatValues - put together various format strings 
#
#  Parameter hash = hash of device addressed, fs = format string
#
########################################################################################

sub OWMULTI_FormatValues($) {
  my ($hash) = @_;
  
  my $name    = $hash->{NAME}; 
  my ($toffset,$tfactor,$tval,$vfunc,$vval);
  my $svalue  = "";
  
  #-- no change in any value if invalid reading
  return if( ($hash->{owg_temp} eq "") || ($hash->{owg_vdd} eq "") || ($hash->{owg_volt} eq "") );
  
  #-- obtain channel names
  OWMULTI_ChannelNames($hash);
  
  #-- correct values for proper offset, factor 
  $toffset = $hash->{tempf}{offset};
  $tfactor = $hash->{tempf}{factor};
  $tval    = ($hash->{owg_temp} + $toffset)*$tfactor;
  
  #-- attribute VFunction defined ?
  $vfunc   = defined($attr{$name}{"VFunction"}) ? $attr{$name}{"VFunction"} : "V";

  #-- replace by proper values 
  $vfunc =~ s/VDD/\$hash->{owg_vdd}/g;
  $vfunc =~ s/V/\$hash->{owg_volt}/g;
  $vfunc =~ s/T/\$tval/g;
  
  #-- determine the measured value from the function
  $vfunc = "\$hash->{owg_vdd} = $hash->{owg_vdd}; \$hash->{owg_volt} = $hash->{owg_volt}; \$tval = $tval; ".$vfunc;
  #Log 1, "vfunc= ".$vfunc;
  $vfunc = eval($vfunc);
  if( !$vfunc ){
    $vval = "";
  } elsif( $vfunc ne "" ){
    $vval = int( $vfunc*1000 )/1000;
  } else {
    
  }
  
  #-- string buildup for return value, STATE 
  $svalue .= sprintf( "%s: %5.2f %s (T: %5.2f %s)", $hash->{owg_channel}, $vval,$hash->{READINGS}{$hash->{owg_channel}}{UNITABBR},$tval,$hash->{READINGS}{"temperature"}{UNITABBR});
  
  #-- put into READINGS
  readingsBeginUpdate($hash);
  readingsBulkUpdate($hash,$hash->{owg_channel},$vval);
  readingsBulkUpdate($hash,"VDD",$hash->{owg_vdd});
  readingsBulkUpdate($hash,"temperature",$tval);
  
  #-- STATE
  readingsBulkUpdate($hash,"state",$svalue);
  readingsEndUpdate($hash,1); 

  return $svalue;
}
  
########################################################################################
#
# OWMULTI_Get - Implements GetFn function 
#
#  Parameter hash = hash of device addressed, a = argument array
#
########################################################################################

sub OWMULTI_Get($@) {
  my ($hash, @a) = @_;
  
  my $reading = $a[1];
  my $name    = $hash->{NAME};
  my $model   = $hash->{OW_MODEL};
  my $value   = undef;
  my $ret     = "";

  #-- check syntax
  return "OWMULTI: Get argument is missing @a"
    if(int(@a) != 2);
    
  #-- check argument
  return "OWMULTI: Get with unknown argument $a[1], choose one of ".join(" ", sort keys %gets)
    if(!defined($gets{$a[1]}));
  
  #-- get id
  if($a[1] eq "id") {
    $value = $hash->{ROM_ID};
     return "$name.id => $value";
  } 
  
  #-- Get other values according to interface type
  my $interface= $hash->{IODev}->{TYPE};
  
  #-- get present
  if($a[1] eq "present" ) {
    #-- OWX interface
    if( $interface eq "OWX" ){
      #-- hash of the busmaster
      my $master       = $hash->{IODev};
      $value           = OWX_Verify($master,$hash->{ROM_ID});
      $hash->{PRESENT} = $value;
      return "$name.present => $value";
    } else {
      return "OWMULTI: Verification not yet implemented for interface $interface";
    }
  } 
  
  #-- get interval
  if($reading eq "interval") {
    $value = $hash->{INTERVAL};
     return "$name.interval => $value";
  } 
  
  #-- get version
  if( $a[1] eq "version") {
    return "$name.version => $owx_version";
  }
  
  #-- reset presence
  $hash->{PRESENT}  = 0;

  #-- OWX interface
  if( $interface eq "OWX" ){
    #-- not different from getting all values ..
    $ret = OWXMULTI_GetValues($hash);
  #-- OWFS interface not yet implemented
  }elsif( $interface eq "OWServer" ){
    $ret = OWFSMULTI_GetValues($hash);
  #-- Unknown interface
  }else{
    return "OWMULTI: Get with wrong IODev type $interface";
  }
  
  #-- process results
  if( defined($ret)  ){
    return "OWMULTI: Could not get values from device $name, reason $ret";
  }
  $hash->{PRESENT} = 1; 
  
  #-- return the special reading
  if ($reading eq "reading") {
    return "OWMULTI: $name.reading => ".OWMULTI_FormatValues($hash);
  }
  
  #-- return the special reading
  if ($reading eq "VAD") {
    return "OWMULTI: $name.VAD => ".
      $hash->{READINGS}{$hash->{owg_channel}}{VAL};
  } 
  if ($reading eq "temperature") {
    return "OWMULTI: $name.temperature => ".
      $hash->{READINGS}{"temperature"}{VAL};
  } 
  if ($reading eq "VDD") {
    return "OWMULTI: $name.VDD => ".
      $hash->{READINGS}{"VDD"}{VAL};
  } 
  if ( $reading eq "raw") {
    return "OWMULTI: $name.V => ".
      $hash->{owg_volt};
  } 
  return undef;
}

#######################################################################################
#
# OWMULTI_GetValues - Updates the readings from device
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWMULTI_GetValues($@) {
  my $hash    = shift;
  
  my $name    = $hash->{NAME};
  my $value   = "";
  my $ret     = "";
  
  #-- check if device needs to be initialized
  OWMULTI_InitializeDevice($hash)
    if( $hash->{READINGS}{"state"}{VAL} eq "defined");
  
  #-- restart timer for updates
  RemoveInternalTimer($hash);
  InternalTimer(time()+$hash->{INTERVAL}, "OWMULTI_GetValues", $hash, 1);

  #-- reset presence
  $hash->{PRESENT}  = 0;

  #-- Get values according to interface type
  my $interface= $hash->{IODev}->{TYPE};
  if( $interface eq "OWX" ){
    #-- max 3 tries
    for(my $try=0; $try<3; $try++){
      $ret = OWXMULTI_GetValues($hash);
      return if( !defined($ret) );
    } 
  }elsif( $interface eq "OWServer" ){
    $ret = OWFSMULTI_GetValues($hash);
  }else{
    return "OWMULTI: GetValues with wrong IODev type $interface";
  }

  #-- process results
  if( defined($ret)  ){
    return "OWMULTI: Could not get values from device $name, reason $ret";
  }
  $hash->{PRESENT} = 1; 

  $value=OWMULTI_FormatValues($hash);
  Log 5, $value;

  return undef;
}

########################################################################################
#
# OWMULTI_InitializeDevice - delayed setting of initial readings and channel names  
#
#  Parameter hash = hash of device addressed
#
########################################################################################

sub OWMULTI_InitializeDevice($) {
  my ($hash) = @_;
  
  my $name   = $hash->{NAME};
  
  #-- Initial readings
  $hash->{owg_temp} = "";
  $hash->{owg_volt} = "";
  $hash->{owg_vdd}  = "";  
  
  #-- Set state to initialized
  readingsSingleUpdate($hash,"state","initialized",1);
}

#######################################################################################
#
# OWMULTI_Set - Set one value for device
#
#  Parameter hash = hash of device addressed
#            a = argument string
#
########################################################################################

sub OWMULTI_Set($@) {
  my ($hash, @a) = @_;

  #-- for the selector: which values are possible
  return join(" ", sort keys %sets) if(@a == 2);
  #-- check syntax
  return "OWMULTI: Set needs one parameter"
    if(int(@a) != 3);
  #-- check argument
  return "OWMULTI: Set with unknown argument $a[1], choose one of ".join(",", sort keys %sets)
      if(!defined($sets{$a[1]}));
      
  #-- define vars
  my $key   = $a[1];
  my $value = $a[2];
  my $ret   = undef;
  my $name  = $hash->{NAME};
  my $model = $hash->{OW_MODEL};

 #-- set new timer interval
  if($key eq "interval") {
    # check value
    return "OWMULTI: Set with short interval, must be > 1"
      if(int($value) < 1);
    # update timer
    $hash->{INTERVAL} = $value;
    RemoveInternalTimer($hash);
    InternalTimer(gettimeofday()+$hash->{INTERVAL}, "OWMULTI_GetValues", $hash, 1);
    return undef;
  }

  #-- set other values depending on interface type
  my $interface = $hash->{IODev}->{TYPE};
  my $offset    = $hash->{tempf}{offset};
  my $factor    = $hash->{tempf}{factor};
    
  #-- find upper and lower boundaries for given offset/factor
  my $mmin = (-55+$offset)*$factor;
  my $mmax = (125+$offset)*$factor;
  return sprintf("OWMULTI: Set with wrong value $value for $key, range is  [%3.1f,%3.1f]",$mmin,$mmax)
    if($value < $mmin || $value > $mmax);
    
  #-- seems to be ok, put into the device
  $a[2]  = int($value/$factor-$offset);

  #-- OWX interface
  if( $interface eq "OWX" ){
    $ret = OWXMULTI_SetValues($hash,@a);
  #-- OWFS interface 
  }elsif( $interface eq "OWServer" ){
    $ret = OWFSMULTI_SetValues($hash,@a);
  } else {
    return "OWMULTI: Set with wrong IODev type $interface";
  }
  #-- process results
  if( defined($ret)  ){
    return "OWMULTI: Could not set device $name, reason: ".$ret;
  }
  
  #-- process results - we have to reread the device
  $hash->{PRESENT} = 1; 
  OWMULTI_GetValues($hash);
  OWMULTI_FormatValues($hash);
  Log 4, "OWMULTI: Set $hash->{NAME} $key $value";
  
  return undef;
}

########################################################################################
#
# OWMULTI_Undef - Implements UndefFn function
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWMULTI_Undef ($) {
  my ($hash) = @_;
  
  delete($main::modules{OWMULTI}{defptr}{$hash->{OW_ID}});
  RemoveInternalTimer($hash);
  return undef;
}

########################################################################################
#
# The following subroutines in alphabetical order are only for a 1-Wire bus connected 
# via OWFS
#
# Prefix = OWFSMULTI
#
########################################################################################
#
# OWFSMULTI_GetValues - Get reading from one device
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWFSMULTI_GetValues($) {
  my ($hash) = @_;
  
  #-- ID of the device
  my $owx_add = substr($hash->{ROM_ID},0,15);
  
  #-- hash of the busmaster
  my $master = $hash->{IODev};
  my $name   = $hash->{NAME};
          
  #-- get values - or should we rather get the uncached ones ?
  $hash->{owg_temp} = OWServer_Read($master,"/$owx_add/temperature");
  $hash->{owg_vdd}   = OWServer_Read($master,"/$owx_add/VDD");
  $hash->{owg_volt}   = OWServer_Read($master,"/$owx_add/VAD");
  
  return "no return from OWServer"
    if( (!defined($hash->{owg_temp})) || (!defined($hash->{owg_vdd})) || (!defined($hash->{owg_volt})) );
  return "empty return from OWServer"
    if( ($hash->{owg_temp} eq "") || ($hash->{owg_vdd} eq "") || ($hash->{owg_volt} eq "") );
    
  return undef;
}

#######################################################################################
#
# OWFSMULTI_SetValues - Set values in device
# 
# Parameter hash = hash of device addressed
#           a = argument array
#
########################################################################################

sub OWFSMULTI_SetValues($@) {
  my ($hash, @a) = @_;
  
}

########################################################################################
#
# The following subroutines in alphabetical order are only for a 1-Wire bus connected 
# directly to the FHEM server
#
# Prefix = OWXMULTI
#
########################################################################################
#
# OWXMULTI_GetValues - Get reading from one device
#
# Parameter hash = hash of device addressed
#
########################################################################################

sub OWXMULTI_GetValues($) {

  my ($hash) = @_;
  
  my ($i,$j,$k,$res,$res2);
   
  #-- ID of the device
  my $owx_dev = $hash->{ROM_ID};
  #-- hash of the busmaster
  my $master = $hash->{IODev};
  
  #-- switch the device to current measurement off, VDD only
  #-- issue the match ROM command \x55 and the write scratchpad command
  if (!OWX_Execute( $master, "writestatusvdd", 1, $owx_dev, "\x4E\x00\x08", 0, undef )) {
    return "$owx_dev write status failed";
  }

  #-- copy scratchpad to register
  #-- issue the match ROM command \x55 and the copy scratchpad command
  if (!OWX_Execute( $master, "copyscratchpadvdd", 1, $owx_dev, "\x48\x00", 0, undef )) {
    return "$owx_dev copy scratchpad failed"; 
  }
     
  #-- initiate temperature conversion
  #-- issue the match ROM command \x55 and the start conversion command
  #-- conversion needs some 10 ms !
  if (!OWX_Execute( $master, "temperaturconversionvdd", 1, $owx_dev, "\x44", 0, 12 )) {
    return "$owx_dev temperature conversion failed";
  } 
  
  #-- initiate voltage conversion
  #-- issue the match ROM command \x55 and the start conversion command
  #-- conversion needs some 4 ms  !
  if (!OWX_Execute( $master, "voltageconversionvdd", 1, $owx_dev, "\xB4", 0, 6 )) {
    return "$owx_dev voltage conversion failed";
  } 
  
  #-- from memory to scratchpad
  #-- issue the match ROM command \x55 and the recall memory command
  #-- copy needs some 10 ms !
  if (!OWX_Execute( $master, "recallmemoryvdd", 1, $owx_dev, "\xB8\x00", 0, 12 )) {
     return "$owx_dev recall memory failed";
   } 
  
  #-- NOW ask the specific device 
  #-- issue the match ROM command \x55 and the read scratchpad command \xBE
  #-- reading 9 + 2 + 9 data bytes = 20 bytes
  if (!OWX_Execute( $master, "readscratchpadvdd", 1, $owx_dev, "\xBE\x00", 9, undef )) {
    return "$owx_dev not accessible in 2nd step"; 
  }

  ################################################################
  
  #-- switch the device to current measurement off, V external only
  #-- issue the match ROM command \x55 and the write scratchpad command
  if (!OWX_Execute( $master, "writestatusvad", 1, $owx_dev, "\x4E\x00\x00", 0, undef )) {
    return "$owx_dev write status failed";
  } 
  
  #-- copy scratchpad to register
  #-- issue the match ROM command \x55 and the copy scratchpad command
  if (!OWX_Execute( $master, "copyscratchpadvad", 1, $owx_dev, "\x48\x00", 0, undef )) {
    return "$owx_dev copy scratchpad failed"; 
  }
  
  #-- initiate voltage conversion
  #-- issue the match ROM command \x55 and the start conversion command
  #-- conversion needs some 4 ms  !
  if (!OWX_Execute( $master, "voltageconversionvad", 1, $owx_dev, "\xB4", 0, 6 )) {
    return "$owx_dev voltage conversion failed";
  } 
  
  #-- from memory to scratchpad
  #-- issue the match ROM command \x55 and the recall memory command
  #-- copy needs some 10 ms !
  if (!OWX_Execute( $master, "recallmemoryvad", 1, $owx_dev, "\xB8\x00", 0, 12 )) {
     return "$owx_dev recall memory failed";
  } 
  
  #-- NOW ask the specific device 
  #-- issue the match ROM command \x55 and the read scratchpad command \xBE
  #-- reading 9 + 2 + 9 data bytes = 20 bytes
  if (!OWX_Execute( $master, "readscratchpadvad", 1, $owx_dev, "\xBE\x00", 9, undef )) {
    return "$owx_dev not accessible in 2nd step"; 
  }

  return undef; 
}
  
sub OWXMULTI_AfterGetValues($$$) {
  my ($hash,$context,$readdata) = @_;
  
  HANDLEREADSCRATCHPAD: {
  
    $context eq "vdd" and do {

      #-- process results
      my  @data=split(//,$readdata);
      return "invalid data length, ".int(@data)." instead of 9 bytes"
        if (@data != 9); 
      return "conversion not complete or data invalid"
        if ((ord($data[0]) & 112)!=0); 
      return "invalid CRC"
        if (OWX_CRC8(substr($readdata,0,8),$data[8])==0);
      
      #-- this must be different for the different device types
      #   family = 26 => DS2438
      
      #-- temperature
      my $lsb  = ord($data[1]);
      my $msb  = ord($data[2]) & 127;
      my $sign = ord($data[2]) & 128;
          
      #-- test with -55 degrees
      #$lsb   = 0;
      #$sign  = 1;
      #$msb   = 73;
          
      #-- 2's complement form = signed bytes
      $hash->{owg_temp} = $msb+ $lsb/256;   
      if( $sign !=0 ){
        $hash->{owg_temp} = -128+$hash->{owg_temp};
      }
      
      #-- voltage
      $lsb  = ord($data[3]);
      $msb  = ord($data[4]) & 3;
          
      #-- test with 5V
      #$lsb  = 244;
      #$msb  = 1;
          
      #-- supply voltage
      $hash->{owg_vdd} = ($msb*256+ $lsb)/100;
      
      last;
    };
    
    $context eq "vad" and do {
    
      #-- process results
      my @data=split(//,$readdata);
      return "invalid data length, ".int(@data)." instead of 9 bytes"
        if (@data != 9); 
      return "conversion not complete or data invalid"
        if ((ord($data[0]) & 112)!=0); 
      return "invalid CRC"
        if (OWX_CRC8(substr($readdata,0,8),$data[8])==0);
      
      #-- this must be different for the different device types
      #   family = 26 => DS2438
      #-- voltage
      my $lsb  = ord($data[3]);
      my $msb  = ord($data[4]) & 3;
          
      #-- test with 7.2 V
      #$lsb  = 208;
      #$msb  = 2;
          
      #-- external voltage
      $hash->{owg_volt} = ($msb*256+ $lsb)/100;
      
      my $value=OWMULTI_FormatValues($hash);
      Log 5, $value;
      
      last;
    };
  }
        
  return undef;
}

#######################################################################################
#
# OWXMULTI_SetValues - Set values in device
# 
# Parameter hash = hash of device addressed
#           a = argument array
#
########################################################################################

sub OWXMULTI_SetValues($@) {
  my ($hash, @a) = @_;
  
  my ($i,$j,$k);
  
  my $name = $hash->{NAME};
  #-- ID of the device
  my $owx_dev = $hash->{ROM_ID};
  #-- hash of the busmaster
  my $master = $hash->{IODev};
 
  #-- define vars
  my $key   = $a[1];
  my $value = $a[2];

  #-- issue the match ROM command \x55 and the write scratchpad command \x4E,
  #   followed by the write EEPROM command \x48
  #
  #   so far writing the EEPROM does not work properly.
  #   1. \x48 directly appended to the write scratchpad command => command ok, no effect on EEPROM
  #   2. \x48 appended to match ROM => command not ok. 
  #   3. \x48 sent by WriteBytePower after match ROM => command ok, no effect on EEPROM
  
  my $select=sprintf("\x4E%c%c\x48",0,0); 
  if (!OWX_Execute( $master, "setvalues", 1, $owx_dev, $select, 0, undef )) {
    return "OWXMULTI: Device $owx_dev not accessible"; 
  } 
  
  return undef;
}

sub OWXMULTI_AfterExecute() {
  my ( $hash, $context, $success, $reset, $owx_dev, $data, $numread, $readdata ) = @_;
  
  my $loglevel = main::GetLogLevel($hash->{NAME},6);
  return unless ($success and $context);
  
  CONTEXT: {
    ($context =~ /^readscratchpad.*/) and do {
      return OWXMULTI_AfterGetValues($hash,substr($context,14), $readdata );
    };
  };
  return undef;
}

1;

=pod
=begin html

 <a name="OWMULTI"></a>
        <h3>OWMULTI</h3>
        <p>FHEM module to commmunicate with 1-Wire multi-sensors, currently the DS2438 smart battery
            monitor<br /> <br />This 1-Wire module works with the OWX interface module or with the OWServer interface module
                (prerequisite: Add this module's name to the list of clients in OWServer).
            Please define an <a href="#OWX">OWX</a> device or <a href="#OWServer">OWServer</a> device first.</p>
       <h4>Example</h4>
        <p>
            <code>define OWX_M OWMULTI 7C5034010000 45</code>
            <br />
            <code>attr OWX_M VName relHumidity|humidity</code>
            <br />
            <code>attr OWX_M VUnit percent|%</code>
            <br />
            <code>attr OWX_M VFunction (161.29 * V / VDD - 25.8065)/(1.0546 - 0.00216 * T)</code>
        </p>
        <a name="OWMULTIdefine"></a>
        <h4>Define</h4>
        <p>
            <code>define &lt;name&gt; OWMULTI [&lt;model&gt;] &lt;id&gt; [&lt;interval&gt;]</code> or <br/>
            <code>define &lt;name&gt; OWMULTI &lt;fam&gt;.&lt;id&gt; [&lt;interval&gt;]</code> 
            <br /><br /> Define a 1-Wire multi-sensor</p>
        <ul>
            <li>
                <code>[&lt;model&gt;]</code><br /> Defines the sensor model (and thus 1-Wire family
                id), currently the following values are permitted: <ul>
                    <li>model DS2438 with family id 26 (default if the model parameter is omitted).
                        Measured is a temperature value, an external voltage and the current supply
                        voltage</li>
                </ul>
            </li>
             <li>
                <code>&lt;fam&gt;</code>
                <br />2-character unique family id, see above 
            </li>
            <li>
                <code>&lt;id&gt;</code>
                <br />12-character unique ROM id of the converter device without family id and CRC
                code </li>
            <li>
                <code>&lt;interval&gt;</code>
                <br />Measurement interval in seconds. The default is 300 seconds. </li>
        </ul>
        <a name="OWMULTIset"></a>
        <h4>Set</h4>
        <ul>
            <li><a name="owmulti_interval">
                    <code>set &lt;name&gt; interval &lt;int&gt;</code></a><br /> Measurement
                interval in seconds. The default is 300 seconds. </li>
        </ul>
        <a name="OWMULTIget"></a>
        <h4>Get</h4>
        <ul>
            <li><a name="owmulti_id">
                    <code>get &lt;name&gt; id</code></a>
                <br /> Returns the full 1-Wire device id OW_FAMILY.ROM_ID.CRC </li>
            <li><a name="owmulti_present">
                    <code>get &lt;name&gt; present</code>
                </a>
                <br /> Returns 1 if this 1-Wire device is present, otherwise 0. </li>
            <li><a name="owmulti_interval2">
                    <code>get &lt;name&gt; interval</code></a><br />Returns measurement interval in
                seconds. </li>
            <li><a name="owmulti_reading">
                    <code>get &lt;name&gt; reading</code></a><br />Obtain the measurement values </li>
            <li><a name="owmulti_vad">
                    <code>get &lt;name&gt; VAD</code></a><br />Obtain the measurement value from
                VFunction. </li>
            <li><a name="owmulti_temperature">
                    <code>get &lt;name&gt; temperature</code></a><br />Obtain the temperature value. </li>
            <li><a name="owmulti_vdd">
                    <code>get &lt;name&gt; VDD</code></a><br />Obtain the current supply voltage. </li>
            <li><a name="owmulti_raw">
                    <code>get &lt;name&gt; V</code> or <code>get &lt;name&gt;
                raw</code></a><br />Obtain the raw external voltage measurement. </li>
        </ul>
        <a name="OWMULTIattr"></a>
        <h4>Attributes</h4>
        <ul>
            <li><a name="owmulti_vname"><code>attr &lt;name&gt; VName
                        &lt;string&gt;|&lt;string&gt;</code></a>
                <br />name for the channel | a type description for the measured value. </li>
            <li><a name="owmulti_vunit"><code>attr &lt;name&gt; VUnit
                        &lt;string&gt;|&lt;string&gt;</code></a>
                <br />unit of measurement for this channel | its abbreviation. </li>
            <li><a name="owmulti_vfunction"><code>attr &lt;name&gt; VFunction
                    &lt;string&gt;</code></a>
                <br />arbitrary functional expression involving the values VDD, V, T. Example see
                above. <ul>
                    <li>VDD is replaced by the measured supply voltage in Volt,</li>
                    <li> V by the measured external voltage,</li>
                    <li>T by the measured and corrected temperature in its unit</li>
                </ul></li>
            <li><a name="owmulti_tempOffset"><code>attr &lt;name&gt; tempOffset &lt;float&gt;</code>
                </a>
                <br />temperature offset in &deg;C added to the raw temperature reading. </li>
            <li><a name="owmulti_tempUnit"><code>attr &lt;name&gt; tempUnit
                        Celsius|Kelvin|Fahrenheit|C|K|F</code>
                </a>
                <br />unit of measurement (temperature scale), default is Celsius = &deg;C </li>
            <li>Standard attributes <a href="#alias">alias</a>, <a href="#comment">comment</a>, <a
                    href="#event-on-update-reading">event-on-update-reading</a>, <a
                    href="#event-on-change-reading">event-on-change-reading</a>, <a
                    href="#stateFormat">stateFormat</a>, <a href="#room"
                    >room</a>, <a href="#eventMap">eventMap</a>, <a href="#loglevel">loglevel</a>,
                    <a href="#webCmd">webCmd</a></li>
        </ul>
        
=end html
=cut