########################################################################################
#
# OWX_SER.pm
#
# FHEM module providing hardware dependent functions for the serial (USB) interface of OWX
#
# Prof. Dr. Peter A. Henning
# Norbert Truchsess
#
# $Id: 11_OWX.pm 3.19 2013-03 - pahenning $
#
########################################################################################
#
# Provides the following subroutines
#
# OWX_SER_Alarms
# OWX_SER_Complex
# OWX_SER_Discover
# OWX_SER_Init
# OWX_SER_Reset
# OWX_SER_Verify
#
########################################################################################
#
# OWX_SER_Alarms - Find devices on the 1-Wire bus, 
#              which have the alarm flag set
#
# Parameter hash = hash of bus master
#
# Return number of alarmed devices.
#
########################################################################################

package OWX_SER;

use strict;
use warnings;

use vars qw{$owx_debug};

sub new($) {
	my ($class,$hash) = @_;
	
	return bless {
		#-- OWX device
		hash => $hash,
		#-- baud rate serial interface
		baud => 9600,
		#-- 16 byte search string
		search => [0,0,0,0 ,0,0,0,0, 0,0,0,0, 0,0,0,0],
		ROM_ID => [0,0,0,0 ,0,0,0,0],
		#-- search state for 1-Wire bus search
		LastDiscrepancy => 0,
		LastFamilyDiscrepancy => 0,
		LastDeviceFlag => 0,
	}, $class;
}

sub Define ($) {
	my ($self,$def) = @_;
	my $hash = $self->{hash};
	
	my @a = split("[ \t][ \t]*", $def);

	#-- check syntax
	if(int(@a) < 3){
		return "OWX: Syntax error - must be define <name> OWX"
	}
	#-- If this line contains 3 parameters, it is the bus master definition
	my $dev = $a[2];
    #-- when the specified device name contains @<digits> already, use it as supplied
    if ( $dev !~ m/\@\d*/ ){
      $hash->{DeviceName} = $dev."\@9600";
    }
    #-- Second step in case of serial device: open the serial device to test it
    my $msg = "OWX: Serial device $dev";
    my $ret = DevIo_OpenDev($hash,0,undef);
    my $hwdevice = $hash->{USBDev};
    if(!defined($hwdevice)){
      Log(1, $msg." not defined");
      return "OWX: Can't open serial device $dev: $!"
    } else {
      Log(1,$msg." defined");
    }
    $hwdevice->reset_error();
    $hwdevice->baudrate(9600);
    $hwdevice->databits(8);
    $hwdevice->parity('none');
    $hwdevice->stopbits(1);
    $hwdevice->handshake('none');
    $hwdevice->write_settings;
    #-- store with OWX device
    $hash->{INTERFACE} = "serial";
    $hash->{HWDEVICE}   = $hwdevice;
    return undef;
}

sub Detect () {
  my ($self) = @_;
  my $hash = $self->{hash};
  
  my ($i,$j,$k,$l,$res,$ret,$ress);
  my $name = $hash->{NAME};
  my $ress0 = "OWX: 1-Wire bus $name: interface ";
  $ress     = $ress0;

  my $interface;
  
  #-- timing byte for DS2480
  $self->Query_2480("\xC1",1);
  
  #-- Max 4 tries to detect an interface
  for($l=0;$l<100;$l++) {
    #-- write 1-Wire bus (Fig. 2 of Maxim AN192)
    $res = $self->Query_2480("\x17\x45\x5B\x0F\x91",5);
    
    #-- process 4/5-byte string for detection
    if( !defined($res)){
      $res="";
      $ret=0;
    }elsif( ($res eq "\x16\x44\x5A\x00\x90") || ($res eq "\x16\x44\x5A\x00\x93")){
      $ress .= "master DS2480 detected for the first time";
      $interface="DS2480";
      $ret=1;
    } elsif( $res eq "\x17\x45\x5B\x0F\x91"){
      $ress .= "master DS2480 re-detected";
      $interface="DS2480";
      $ret=1;
    } elsif( ($res eq "\x17\x0A\x5B\x0F\x02") || ($res eq "\x00\x17\x0A\x5B\x0F\x02") || ($res eq "\x30\xf8\x00") ){
      $ress .= "passive DS9097 detected";
      $interface="DS9097";
      $ret=1;
    } else {
      $ret=0;
    }
    last 
      if( $ret==1 );
    $ress .= "not found, answer was ";
    for($i=0;$i<length($res);$i++){
      $j=int(ord(substr($res,$i,1))/16);
      $k=ord(substr($res,$i,1))%16;
      $ress.=sprintf "0x%1x%1x ",$j,$k;
    }
    Log(1, $ress);
    $ress = $ress0;
    #-- sleeping for some time
    select(undef,undef,undef,0.5);
  }
  if( $ret == 0 ){
    $interface=undef;
    $ress .= "not detected, answer was ";
    for($i=0;$i<length($res);$i++){
      $j=int(ord(substr($res,$i,1))/16);
      $k=ord(substr($res,$i,1))%16;
      $ress.=sprintf "0x%1x%1x ",$j,$k;
    }
  }
  $hash->{INTERFACE} = $interface;
  Log(1, $ress);
  return $ret; 
}

sub Init() {
	return undef;
}

sub Alarms () {
  my ($self) = @_;
  
  my $hash = $self->{hash};
  
  #-- Discover all alarmed devices on the 1-Wire bus
  my $res = $self->SER_First("alarm");
  while( $self->{LastDeviceFlag}==0 && $res != 0){
    $res = $res & $self->SER_Next("alarm");
  }
  Log(1, " Alarms = ".join(' ',@{$hash->{ALARMDEVS}}));
  return( int(@{$hash->{ALARMDEVS}}) );
} 

########################################################################################
# 
# OWX_SER_Complex - Send match ROM, data block and receive bytes as response
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
  my ($self,$dev,$data,$numread) =@_;
  
  my $hash = $self->{hash};
  
  my $select;
  my $res  = "";
  my $res2 = "";
  my ($i,$j,$k);
  
  #-- get the interface
  my $interface = $hash->{INTERFACE};
  my $hwdevice  = $hash->{HWDEVICE};
  
  #-- has match ROM part
  if( $dev ){
    #-- ID of the device
    my $owx_rnf = substr($dev,3,12);
    my $owx_f   = substr($dev,0,2);

    #-- 8 byte 1-Wire device address
    my @rom_id  =(0,0,0,0 ,0,0,0,0); 
    #-- from search string to byte id
    $dev=~s/\.//g;
    for(my $i=0;$i<8;$i++){
       $rom_id[$i]=hex(substr($dev,2*$i,2));
    }
    $select=sprintf("\x55%c%c%c%c%c%c%c%c",@rom_id).$data; 
  #-- has no match ROM part
  } else {
    $select=$data;
  }
  #-- has receive data part
  if( $numread >0 ){
    #$numread += length($data);
    for( my $i=0;$i<$numread;$i++){
      $select .= "\xFF";
    };
  }
  
  #-- for debugging
  if( $owx_debug > 1){
    $res2 = "OWX_SER_Complex: Sending out ";
    for($i=0;$i<length($select);$i++){  
      $j=int(ord(substr($select,$i,1))/16);
      $k=ord(substr($select,$i,1))%16;
      $res2.=sprintf "0x%1x%1x ",$j,$k;
    }
    Log(3, $res2);
  }
  if( $interface eq "DS2480" ){
    $res = $self->Block_2480($select);
  }elsif( $interface eq "DS9097" ){
    $res = $self->Block_9097($select);
  }
  
  #-- for debugging
  if( $owx_debug > 1){
    $res2 = "OWX_SER_Complex: Receiving   ";
    for($i=0;$i<length($res);$i++){  
      $j=int(ord(substr($res,$i,1))/16);
      $k=ord(substr($res,$i,1))%16;
      $res2.=sprintf "0x%1x%1x ",$j,$k;
    }
    Log(3, $res2);
  }
  
  return $res
}

########################################################################################
#
# OWX_SER_Discover - Find devices on the 1-Wire bus
#
# Parameter hash = hash of bus master
#
# Return 1, if alarmed devices found, 0 otherwise.
#
########################################################################################

sub Discover () {
  my ($self) = @_;
  my $hash = $self->{hash};
  
  #-- Discover all alarmed devices on the 1-Wire bus
  my $res = $self->SER_First("discover");
  while( $self->{LastDeviceFlag}==0 && $res!=0 ){
    $res = $res & $self->SER_Next("discover"); 
  }
  return( @{$hash->{DEVS}} == 0);
} 

########################################################################################
#
# OWX_SER_First - Find the 'first' devices on the 1-Wire bus
#
# Parameter hash = hash of bus master, mode
#
# Return 1 : device found, ROM number pushed to list
#        0 : no device present
#
########################################################################################

sub SER_First ($) {
  my ($self,$mode) = @_;
  
  #-- clear 16 byte of search data
  @{$self->{search}} = (0,0,0,0 ,0,0,0,0, 0,0,0,0, 0,0,0,0);
  #-- reset the search state
  $self->{LastDiscrepancy} = 0;
  $self->{LastDeviceFlag} = 0;
  $self->{LastFamilyDiscrepancy} = 0;
  #-- now do the search
  return $self->Search($mode);
}

########################################################################################
#
# OWX_SER_Next - Find the 'next' devices on the 1-Wire bus
#
# Parameter hash = hash of bus master, mode
#
# Return 1 : device found, ROM number in owx_ROM_ID and pushed to list (LastDeviceFlag=0) 
#                                     or only in owx_ROM_ID (LastDeviceFlag=1)
#        0 : device not found, or ot searched at all
#
########################################################################################

sub SER_Next ($) {
  my ($self,$mode) = @_;
  
  #-- now do the search
  return $self->Search($mode);
}

########################################################################################
# 
# OWX_SER_Reset - Reset the 1-Wire bus 
#
# Parameter hash = hash of bus master
#
# Return 1 : OK
#        0 : not OK
#
########################################################################################

sub Reset () {
  my ($self)=@_;
  my $hash = $self->{hash};
  
  #-- get the interface
  my $interface = $hash->{INTERFACE};
  
   #-- interface error
  if(  $interface eq "DS2480"){
    return $self->Reset_2480();
  }elsif(  $interface eq "DS9097"){
    return $self->Reset_9097();
  }
}

#######################################################################################
#
# OWX_SER_Search - Perform the 1-Wire Search Algorithm on the 1-Wire bus using the existing
#              search state.
#
# Parameter hash = hash of bus master, mode=alarm,discover or verify
#
# Return 1 : device found, ROM number in owx_ROM_ID and pushed to list (LastDeviceFlag=0) 
#                                     or only in owx_ROM_ID (LastDeviceFlag=1)
#        0 : device not found, or ot searched at all
#
########################################################################################

sub Search ($) {
  my ($self,$mode)=@_;
  my $hash = $self->{hash};
  
  my @owx_fams=();
  
  #-- get the interface
  my $interface = $hash->{INTERFACE};
  my $hwdevice  = $hash->{HWDEVICE};
  
  #-- if the last call was the last one, no search 
  if ($self->{LastDeviceFlag}==1){
    return 0;
  }
  #-- 1-Wire reset
  if ($self->Reset()==0){
    #-- reset the search
    Log(1, "OWX: Search reset failed");
    $self->{LastDiscrepancy} = 0;
    $self->{LastDeviceFlag} = 0;
    $self->{LastFamilyDiscrepancy} = 0;
    return 0;
  }
  
  #-- Here we call the device dependent part
  if( $interface eq "DS2480" ){
    $self->Search_2480($mode);
  }elsif( $interface eq "DS9097" ){
    $self->Search_9097($mode);
  }else{
    Log(1,"OWX: Search called with unknown interface ".$interface);
    return 0;
  }
  #--check if we really found a device
  if( OWX_CRC(0)!= 0){  # TODO: pass $self->{ROM_ID}
  #-- reset the search
    Log(1, "OWX: Search CRC failed ");
    $self->{LastDiscrepancy} = 0;
    $self->{LastDeviceFlag} = 0;
    $self->{LastFamilyDiscrepancy} = 0;
    return 0;
  }
    
  #-- character version of device ROM_ID, first byte = family 
  my $dev=sprintf("%02X.%02X%02X%02X%02X%02X%02X.%02X",@{$self->{ROM_ID}});
  
  #-- for some reason this does not work - replaced by another test, see below
  #if( $self->{LastDiscrepancy}==0 ){
  #    $self->{LastDeviceFlag}=1;
  #}
  #--
  if( $self->{LastDiscrepancy}==$self->{LastFamilyDiscrepancy} ){
      $self->{LastFamilyDiscrepancy}=0;    
  }
    
  #-- mode was to verify presence of a device
  if ($mode eq "verify") {
    Log(5, "OWX: Device verified $dev");
    return 1;
  #-- mode was to discover devices
  } elsif( $mode eq "discover" ){
    #-- check families
    my $famfnd=0;
    foreach (@owx_fams){
      if( substr($dev,0,2) eq $_ ){        
        #-- if present, set the fam found flag
        $famfnd=1;
        last;
      }
    }
    push(@owx_fams,substr($dev,0,2)) if( !$famfnd );
    foreach (@{$hash->{DEVS}}){
      if( $dev eq $_ ){        
        #-- if present, set the last device found flag
        $self->{LastDeviceFlag}=1;
        last;
      }
    }
    if( $self->{LastDeviceFlag}!=1 ){
      #-- push to list
      push(@{$hash->{DEVS}},$dev);
      Log(5, "OWX: New device found $dev");
    }  
    return 1;
    
  #-- mode was to discover alarm devices 
  } else {
    for(my $i=0;$i<@{$hash->{ALARMDEVS}};$i++){
      if( $dev eq ${$hash->{ALARMDEVS}}[$i] ){        
        #-- if present, set the last device found flag
        $self->{LastDeviceFlag}=1;
        last;
      }
    }
    if( $self->{LastDeviceFlag}!=1 ){
    #--push to list
      push(@{$hash->{ALARMDEVS}},$dev);
      Log(5, "OWX: New alarm device found $dev");
    }  
    return 1;
  }
}

########################################################################################
#
# OWX_SER_Verify - Verify a particular device on the 1-Wire bus
#
# Parameter hash = hash of bus master, dev =  8 Byte ROM ID of device to be tested
#
# Return 1 : device found
#        0 : device not
#
########################################################################################

sub Verify ($) {
  my ($self,$dev) = @_;
  my $hash = $self->{hash};
  my @rom_id;
  my $i;
    
  #-- from search string to byte id
  my $devs=$dev;
  $devs=~s/\.//g;
  for($i=0;$i<8;$i++){
     $rom_id[$i]=hex(substr($devs,2*$i,2));
  }
  #-- reset the search state
  $self->{LastDiscrepancy} = 64;
  $self->{LastDeviceFlag} = 0;
  #-- now do the search
  my $res=$self->Search("verify");
  my $dev2=sprintf("%02X.%02X%02X%02X%02X%02X%02X.%02X",@rom_id);
  #-- reset the search state
  $self->{LastDiscrepancy} = 0;
  $self->{LastDeviceFlag} = 0;
  #-- check result
  if ($dev eq $dev2){
    return 1;
  }else{
    return 0;
  }
}

########################################################################################
#
# The following subroutines in alphabetical order are only for a DS2480 bus interface
#
#########################################################################################
# 
# OWX_Block_2480 - Send data block (Fig. 6 of Maxim AN192)
#
# Parameter hash = hash of bus master, data = string to send
#
# Return response, if OK
#        0 if not OK
#
########################################################################################

sub Block_2480 ($) {
  my ($self,$data) =@_;
  my $hash = $self->{hash};
  
   my $data2="";
   my $retlen = length($data);
   
  #-- if necessary, prepend E1 character for data mode
  if( substr($data,0,1) ne '\xE1') {
    $data2 = "\xE1";
  }
  #-- all E3 characters have to be duplicated
  for(my $i=0;$i<length($data);$i++){
    my $newchar = substr($data,$i,1);
    $data2=$data2.$newchar;
    if( $newchar eq '\xE3'){
      $data2=$data2.$newchar;
    }
  }
  #-- write 1-Wire bus as a single string
  my $res =$self->Query_2480($data2,$retlen);
  return $res;
}

########################################################################################
# 
# OWX_Level_2480 - Change power level (Fig. 13 of Maxim AN192)
#
# Parameter hash = hash of bus master, newlevel = "normal" or something else
#
# Return 1 : OK
#        0 : not OK
#
########################################################################################

sub Level_2480 ($) {
  my ($self,$newlevel) =@_;
  my $hash = $self->{hash};
  my $cmd="";
  my $retlen=0;
  #-- if necessary, prepend E3 character for command mode
  $cmd = "\xE3";
 
  #-- return to normal level
  if( $newlevel eq "normal" ){
    $cmd=$cmd."\xF1\xED\xF1";
    $retlen+=3;
    #-- write 1-Wire bus
    my $res = $self->Query_2480($cmd,$retlen);
    #-- process result
    my $r1  = ord(substr($res,0,1)) & 236;
    my $r2  = ord(substr($res,1,1)) & 236;
    if( ($r1 eq 236) && ($r2 eq 236) ){
      Log(5, "OWX: Level change to normal OK");
      return 1;
    } else {
      Log(3, "OWX: Failed to change to normal level");
      return 0;
    }
  #-- start pulse  
  } else {    
    $cmd=$cmd."\x3F\xED";
    $retlen+=2;
    #-- write 1-Wire bus
    my $res = $self->Query_2480($cmd,$retlen);
    #-- process result
    if( $res eq "\x3E" ){
      Log(5, "OWX: Level change OK");
      return 1;
    } else {
      Log(3, "OWX: Failed to change level");
      return 0;
    }
  }
}

########################################################################################
#
# OWX_Query_2480 - Write to and read from the 1-Wire bus
# 
# Parameter: hash = hash of bus master, cmd = string to send to the 1-Wire bus
#
# Return: string received from the 1-Wire bus
#
########################################################################################

sub Query_2480 ($$) {
	
  my ($self,$cmd,$retlen) = @_;
  my $hash = $self->{hash};
  my ($i,$j,$k,$l,$m,$n);
  my $string_in = "";
  my $string_part;
  
  #-- get hardware device
  my $hwdevice = $hash->{HWDEVICE};
  
  $hwdevice->baudrate($self->{baud});
  $hwdevice->write_settings;

  if( $owx_debug > 2){
    my $res = "OWX: Sending out        ";
    for($i=0;$i<length($cmd);$i++){  
      $j=int(ord(substr($cmd,$i,1))/16);
      $k=ord(substr($cmd,$i,1))%16;
  	$res.=sprintf "0x%1x%1x ",$j,$k;
    }
    Log(3, $res);
  }
  
  my $count_out = $hwdevice->write($cmd);
  
  if( !($count_out)){
    Log(3,"OWX_Query_2480: No return value after writing") if( $owx_debug > 0);
  } else {
    Log(3, "OWX_Query_2480: Write incomplete $count_out ne ".(length($cmd))."") if ( ($count_out != length($cmd)) & ($owx_debug > 0));
  }
  #-- sleeping for some time
  select(undef,undef,undef,0.04);
 
  #-- read the data - looping for slow devices suggested by Joachim Herold
  $n=0;                                                
  for($l=0;$l<$retlen;$l+=$m) {                            
    my ($count_in, $string_part) = $hwdevice->read(48);  
    $string_in .= $string_part;                            
    $m = $count_in;		
  	$n++;
 	if( $owx_debug > 2){
 	  Log(3, "Schleifendurchlauf $n");
 	  }
 	if ($n > 100) {                                       
	  $m = $retlen;                                         
	}
	select(undef,undef,undef,0.02);	                      
    if( $owx_debug > 2){	
      my $res = "OWX: Receiving in loop no. $n ";
      for($i=0;$i<$count_in;$i++){ 
	    $j=int(ord(substr($string_part,$i,1))/16);
        $k=ord(substr($string_part,$i,1))%16;
        $res.=sprintf "0x%1x%1x ",$j,$k;
	  }
      Log(3, $res)
        if( $count_in > 0);
	}
  }
	
  #-- sleeping for some time
  select(undef,undef,undef,0.01);
  return($string_in);
}

########################################################################################
# 
# OWX_Reset_2480 - Reset the 1-Wire bus (Fig. 4 of Maxim AN192)
#
# Parameter hash = hash of bus master
#
# Return 1 : OK
#        0 : not OK
#
########################################################################################

sub Reset_2480 () {

  my ($self)=@_;
  my $hash = $self->{hash};
  my $cmd="";
  my $name     = $hash->{NAME};
 
  my ($res,$r1,$r2);
  #-- if necessary, prepend \xE3 character for command mode
  $cmd = "\xE3";
  
  #-- Reset command \xC5
  $cmd  = $cmd."\xC5"; 
  #-- write 1-Wire bus
  $res = $self->Query_2480($cmd,1);

  #-- if not ok, try for max. a second time
  $r1  = ord(substr($res,0,1)) & 192;
  if( $r1 != 192){
    #Log(1, "Trying second reset";
    $res = $self->Query_2480($cmd,1);
  }

  #-- process result
  $r1  = ord(substr($res,0,1)) & 192;
  if( $r1 != 192){
    Log(3, "OWX: Reset failure on bus $name");
    return 0;
  }
  $hash->{ALARMED} = "no";
  
  $r2 = ord(substr($res,0,1)) & 3;
  
  if( $r2 == 3 ){
    #Log(3, "OWX: No presence detected";
    return 1;
  }elsif( $r2 ==2 ){
    Log(1, "OWX: Alarm presence detected on bus $name");
    $hash->{ALARMED} = "yes";
  }
  return 1;
}

########################################################################################
#
# OWX_Search_2480 - Perform the 1-Wire Search Algorithm on the 1-Wire bus using the existing
#              search state.
#
# Parameter hash = hash of bus master, mode=alarm,discover or verify
#
# Return 1 : device found, ROM number in owx_ROM_ID and pushed to list (LastDeviceFlag=0) 
#                                     or only in owx_ROM_ID (LastDeviceFlag=1)
#        0 : device not found, or ot searched at all
#
########################################################################################

sub Search_2480 ($) {
  my ($self,$mode)=@_;
  my $hash = $self->{hash};
  
  my ($sp1,$sp2,$response,$search_direction,$id_bit_number);
    
  #-- Response search data parsing operates bytewise
  $id_bit_number = 1;
  
  select(undef,undef,undef,0.5);
  
  #-- clear 16 byte of search data
  @{$self->{search}}=(0,0,0,0 ,0,0,0,0, 0,0,0,0, 0,0,0,0);
  #-- Output search data construction (Fig. 9 of Maxim AN192)
  #   operates on a 16 byte search response = 64 pairs of two bits
  while ( $id_bit_number <= 64) {
    #-- address single bits in a 16 byte search string
    my $newcpos = int(($id_bit_number-1)/4);
    my $newimsk = ($id_bit_number-1)%4;
    #-- address single bits in a 8 byte id string
    my $newcpos2 = int(($id_bit_number-1)/8);
    my $newimsk2 = ($id_bit_number-1)%8;

    if( $id_bit_number <= $self->{LastDiscrepancy}){
      #-- first use the ROM ID bit to set the search direction  
      if( $id_bit_number < $self->{LastDiscrepancy} ) {
        $search_direction = ($self->{ROM_ID}[$newcpos2]>>$newimsk2) & 1;
        #-- at the last discrepancy search into 1 direction anyhow
      } else {
        $search_direction = 1;
      } 
      #-- fill into search data;
      $self->{search}[$newcpos]+=$search_direction<<(2*$newimsk+1);
    }
    #--increment number
    $id_bit_number++;
  }
  #-- issue data mode \xE1, the normal search command \xF0 or the alarm search command \xEC 
  #   and the command mode \xE3 / start accelerator \xB5 
  if( $mode ne "alarm" ){
    $sp1 = "\xE1\xF0\xE3\xB5";
  } else {
    $sp1 = "\xE1\xEC\xE3\xB5";
  }
  #-- issue data mode \xE1, device ID, command mode \xE3 / end accelerator \xA5
  $sp2=sprintf("\xE1%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c%c\xE3\xA5",@{$self->{search}}); 
  $response = $self->Query_2480($sp1,1); 
  $response = $self->Query_2480($sp2,16);   
     
  #-- interpret the return data
  if( length($response)!=16 ) {
    Log(3, "OWX: Search 2nd return has wrong parameter with length = ".length($response)."");
    return 0;
  }
  #-- Response search data parsing (Fig. 11 of Maxim AN192)
  #   operates on a 16 byte search response = 64 pairs of two bits
  $id_bit_number = 1;
  #-- clear 8 byte of device id for current search
  @{$self->{ROM_ID}} =(0,0,0,0 ,0,0,0,0); 

  while ( $id_bit_number <= 64) {
    #-- adress single bits in a 16 byte string
    my $newcpos = int(($id_bit_number-1)/4);
    my $newimsk = ($id_bit_number-1)%4;

    #-- retrieve the new ROM_ID bit
    my $newchar = substr($response,$newcpos,1);
 
    #-- these are the new bits
    my $newibit = (( ord($newchar) >> (2*$newimsk) ) & 2) / 2;
    my $newdbit = ( ord($newchar) >> (2*$newimsk) ) & 1;

    #-- output for test purpose
    #print "id_bit_number=$id_bit_number => newcpos=$newcpos, newchar=0x".int(ord($newchar)/16).
    #      ".".int(ord($newchar)%16)." r$id_bit_number=$newibit d$id_bit_number=$newdbit\n";
    
    #-- discrepancy=1 and ROM_ID=0
    if( ($newdbit==1) and ($newibit==0) ){
        $self->{LastDiscrepancy}=$id_bit_number;
        if( $id_bit_number < 9 ){
        	$self->{LastFamilyDiscrepancy}=$id_bit_number;
        }
    } 
    #-- fill into device data; one char per 8 bits
    $self->{ROM_ID}[int(($id_bit_number-1)/8)]+=$newibit<<(($id_bit_number-1)%8);
  
    #-- increment number
    $id_bit_number++;
  }
  return 1;
}

########################################################################################
# 
# OWX_WriteBytePower_2480 - Send byte to bus with power increase (Fig. 16 of Maxim AN192)
#
# Parameter hash = hash of bus master, dbyte = byte to send
#
# Return 1 : OK
#        0 : not OK
#
########################################################################################

sub WriteBytePower_2480 ($) {

  my ($self,$dbyte) =@_;
  my $hash = $self->{hash};
  
  my $cmd="\x3F";
  my $ret="\x3E";
  #-- if necessary, prepend \xE3 character for command mode
  $cmd = "\xE3".$cmd;
  
  #-- distribute the bits of data byte over several command bytes
  for (my $i=0;$i<8;$i++){
    my $newbit   = (ord($dbyte) >> $i) & 1;
    my $newchar  = 133 | ($newbit << 4);
    my $newchar2 = 132 | ($newbit << 4) | ($newbit << 1) | $newbit;
    #-- last command byte still different
    if( $i == 7){
      $newchar = $newchar | 2;
    }
    $cmd = $cmd.chr($newchar);
    $ret = $ret.chr($newchar2);
  }
  #-- write 1-Wire bus
  my $res = $self->Query($cmd);
  #-- process result
  if( $res eq $ret ){
    Log(5, "OWX: WriteBytePower OK");
    return 1;
  } else {
    Log(3, "OWX: WriteBytePower failure");
    return 0;
  }
}

########################################################################################
#
# The following subroutines in alphabetical order are only for a DS9097 bus interface
#
########################################################################################
# 
# OWX_Block_9097 - Send data block (
#
# Parameter hash = hash of bus master, data = string to send
#
# Return response, if OK
#        0 if not OK
#
########################################################################################

sub Block_9097 ($) {
  my ($self,$data) =@_;
  my $hash = $self->{hash};
  
   my $data2="";
   my $res=0;
   for (my $i=0; $i<length($data);$i++){
     $res = $self->TouchByte_9097(ord(substr($data,$i,1)));
     $data2 = $data2.chr($res);
   }
   return $data2;
}

########################################################################################
#
# OWX_Query_9097 - Write to and read from the 1-Wire bus
# 
# Parameter: hash = hash of bus master, cmd = string to send to the 1-Wire bus
#
# Return: string received from the 1-Wire bus
#
########################################################################################

sub Query_9097 ($) {

  my ($self,$cmd) = @_;
  my $hash = $self->{hash};
  my ($i,$j,$k);
  #-- get hardware device 
  my $hwdevice = $hash->{HWDEVICE};
  
  $hwdevice->baudrate($self->{baud});
  $hwdevice->write_settings;
  
  if( $owx_debug > 2){
    my $res = "OWX: Sending out ";
    for($i=0;$i<length($cmd);$i++){  
      $j=int(ord(substr($cmd,$i,1))/16);
      $k=ord(substr($cmd,$i,1))%16;
      $res.=sprintf "0x%1x%1x ",$j,$k;
    }
    Log(3, $res);
  } 
	
  my $count_out = $hwdevice->write($cmd);

  Log(1, "OWX: Write incomplete $count_out ne ".(length($cmd))."") if ( $count_out != length($cmd) );
  #-- sleeping for some time
  select(undef,undef,undef,0.01);
 
  #-- read the data
  my ($count_in, $string_in) = $hwdevice->read(48);
    
  if( $owx_debug > 2){
    my $res = "OWX: Receiving ";
    for($i=0;$i<$count_in;$i++){  
      $j=int(ord(substr($string_in,$i,1))/16);
      $k=ord(substr($string_in,$i,1))%16;
      $res.=sprintf "0x%1x%1x ",$j,$k;
    }
    Log(3, $res);
  }
	
  #-- sleeping for some time
  select(undef,undef,undef,0.01);
 
  return($string_in);
}

########################################################################################
# 
# OWX_ReadBit_9097 - Read 1 bit from 1-wire bus  (Fig. 5/6 from Maxim AN214)
#
# Parameter hash = hash of bus master
#
# Return bit value
#
########################################################################################

sub ReadBit_9097 () {
  my ($self) = @_;
  my $hash = $self->{hash};
  
  #-- set baud rate to 115200 and query!!!
  my $sp1="\xFF";
  $self->{baud}=115200;
  my $res=$self->Query_9097($sp1);
  $self->{baud}=9600;
  #-- process result
  if( substr($res,0,1) eq "\xFF" ){
    return 1;
  } else {
    return 0;
  } 
}

########################################################################################
# 
# OWX_Reset_9097 - Reset the 1-Wire bus (Fig. 4 of Maxim AN192)
#
# Parameter hash = hash of bus master
#
# Return 1 : OK
#        0 : not OK
#
########################################################################################

sub Reset_9097 () {

  my ($self)=@_;
  my $hash = $self->{hash};
  
  my $cmd="";
    
  #-- Reset command \xF0
  $cmd="\xF0";
  #-- write 1-Wire bus
  my $res = $self->Query_9097($cmd);
  #-- TODO: process result
  #-- may vary between 0x10, 0x90, 0xe0
  return 1;
}

########################################################################################
#
# OWX_Search_9097 - Perform the 1-Wire Search Algorithm on the 1-Wire bus using the existing
#              search state.
#
# Parameter hash = hash of bus master, mode=alarm,discover or verify
#
# Return 1 : device found, ROM number in owx_ROM_ID and pushed to list (LastDeviceFlag=0) 
#                                     or only in owx_ROM_ID (LastDeviceFlag=1)
#        0 : device not found, or ot searched at all
#
########################################################################################

sub Search_9097 ($) {

  my ($self,$mode)=@_;
  my $hash = $self->{hash};
  
  my ($sp1,$sp2,$response,$search_direction,$id_bit_number);
    
  #-- Response search data parsing operates bitwise
  $id_bit_number = 1;
  my $rom_byte_number = 0;
  my $rom_byte_mask = 1;
  my $last_zero = 0;
      
  #-- issue search command
  $self->{baud}=115200;
  $sp2="\x00\x00\x00\x00\xFF\xFF\xFF\xFF";
  $response = $self->Query_9097($sp2);
  $self->{baud}=9600;
  #-- issue the normal search command \xF0 or the alarm search command \xEC 
  #if( $mode ne "alarm" ){
  #  $sp1 = 0xF0;
  #} else {
  #  $sp1 = 0xEC;
  #}
      
  #$response = OWX_TouchByte($hash,$sp1); 

  #-- clear 8 byte of device id for current search
  @{$self->{ROM_ID}} =(0,0,0,0 ,0,0,0,0); 

  while ( $id_bit_number <= 64) {
    #loop until through all ROM bytes 0-7  
    my $id_bit     = $self->TouchBit_9097(1);
    my $cmp_id_bit = $self->TouchBit_9097(1);
     
    #print "id_bit = $id_bit, cmp_id_bit = $cmp_id_bit\n";
     
    if( ($id_bit == 1) && ($cmp_id_bit == 1) ){
      #print "no devices present at id_bit_number=$id_bit_number \n";
      next;
    }
    if ( $id_bit != $cmp_id_bit ){
      $search_direction = $id_bit;
    } else {
      # hä ? if this discrepancy if before the Last Discrepancy
      # on a previous next then pick the same as last time
      if ( $id_bit_number < $self->{LastDiscrepancy} ){
        if (($self->{ROM_ID}[$rom_byte_number] & $rom_byte_mask) > 0){
          $search_direction = 1;
        } else {
          $search_direction = 0;
        }
      } else {
        # if equal to last pick 1, if not then pick 0
        if ($id_bit_number == $self->{LastDiscrepancy}){
          $search_direction = 1;
        } else {
          $search_direction = 0;
        }   
      }
      # if 0 was picked then record its position in LastZero
      if ($search_direction == 0){
        $last_zero = $id_bit_number;
        # check for Last discrepancy in family
        if ($last_zero < 9) {
          $self->{LastFamilyDiscrepancy} = $last_zero;
        }
      }
    }
    # print "search_direction = $search_direction, last_zero=$last_zero\n";
    # set or clear the bit in the ROM byte rom_byte_number
    # with mask rom_byte_mask
    #print "ROM byte mask = $rom_byte_mask, search_direction = $search_direction\n";
    if ( $search_direction == 1){
      $self->{ROM_ID}[$rom_byte_number] |= $rom_byte_mask;
    } else {
      $self->{ROM_ID}[$rom_byte_number] &= ~$rom_byte_mask;
    }
    # serial number search direction write bit
    $response = $self->WriteBit_9097($search_direction);
    # increment the byte counter id_bit_number
    # and shift the mask rom_byte_mask--
    $id_bit_number++;
    $rom_byte_mask <<= 1;
    #-- if the mask is 0 then go to new rom_byte_number and
    if ($rom_byte_mask == 256){
      $rom_byte_number++;
      $rom_byte_mask = 1;
    } 
    $self->{LastDiscrepancy} = $last_zero;
  }
  return 1; 
}

########################################################################################
# 
# OWX_TouchBit_9097 - Write/Read 1 bit from 1-wire bus  (Fig. 5-8 from Maxim AN 214)
#
# Parameter hash = hash of bus master
#
# Return bit value
#
########################################################################################

sub TouchBit_9097 ($) {
  my ($self,$bit) = @_;
  my $hash = $self->{hash};
  
  my $sp1;
  #-- set baud rate to 115200 and query!!!
  if( $bit == 1 ){
    $sp1="\xFF";
  } else {
    $sp1="\x00";
  }
  $self->{baud}=115200;
  my $res=$self->Query_9097($sp1);
  $self->{baud}=9600;
  #-- process result
  my $sp2=substr($res,0,1);
  if( $sp1 eq $sp2 ){
    return 1;
  }else {
    return 0;
  }
}

########################################################################################
# 
# OWX_TouchByte_9097 - Write/Read 8 bit from 1-wire bus 
#
# Parameter hash = hash of bus master
#
# Return bit value
#
########################################################################################

sub TouchByte_9097 ($) {
  my ($self,$byte) = @_;
  my $hash = $self->{hash};
  
  my $loop;
  my $result=0;
  my $bytein=$byte;
  
  for( $loop=0; $loop < 8; $loop++ ){
    #-- shift result to get ready for the next bit
    $result >>=1;
    #-- if sending a 1 then read a bit else write 0
    if( $byte & 0x01 ){
      if( $self->ReadBit_9097() ){
        $result |= 0x80;
      }
    } else {
      $self->WriteBit_9097(0);
    }
    $byte >>= 1;
  }
  return $result;
}

########################################################################################
# 
# OWX_WriteBit_9097 - Write 1 bit to 1-wire bus  (Fig. 7/8 from Maxim AN 214)
#
# Parameter hash = hash of bus master
#
# Return bit value
#
########################################################################################

sub WriteBit_9097 ($) {
  my ($self,$bit) = @_;
  my $hash = $self->{hash};
  
  my $sp1;
  #-- set baud rate to 115200 and query!!!
  if( $bit ==1 ){
    $sp1="\xFF";
  } else {
    $sp1="\x00";
  }
  $self->{baud}=115200;
  my $res=$self->Query_9097($sp1);
  $self->{baud}=9600;
  #-- process result
  if( substr($res,0,1) eq $sp1 ){
    return 1;
  } else {
    return 0;
  } 
}

1;