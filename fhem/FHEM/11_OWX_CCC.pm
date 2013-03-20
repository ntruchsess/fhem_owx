########################################################################################
#
# OWX_CCC.pm
#
# FHEM module providing hardware dependent functions for the COC/CUNO interface of OWX
#
# Prof. Dr. Peter A. Henning
#
# $Id: 11_OWX_CCC.pm 3.19 2013-03 - pahenning $
#
########################################################################################
#
# Provides the following subroutines
#
# OWX_CCC_Alarms
# OWX_CCC_Complex
# OWX_CCC_Discover
# OWX_CCC_Init
# OWX_CCC_Reset
# OWX_CCC_Verify
#
########################################################################################
#
# OWX_SER_Alarms - Find devices on the 1-Wire bus, 
#              which have the alarm flag set
#
# Parameter hash = hash of bus master
#
# Return 0 because not implemented here.
#
########################################################################################

package OWX_CCC;

sub new($$) {
	my ($class,$hash) = @_;

	return bless {
		hash => $hash,
	}, $class;
}

sub Define($) {
	my ($self,$dev) = @_;
	my $hash = $self->{hash};
		
    $hash->{DeviceName} = $dev;
    #-- Second step in case of CUNO: See if we can open it
    my $msg = "OWX: COC/CUNO device $dev";
    #-- hash des COC/CUNO
    $owx_hwdevice = $main::defs{$dev};
    if($owx_hwdevice){
      main::Log(1,$msg." defined");
      #-- store with OWX device
      $hash->{INTERFACE} = "COC/CUNO";
      $hash->{HWDEVICE}    = $owx_hwdevice;
      #-- loop for some time until the state is "Initialized"
      for(my $i=0;$i<6;$i++){
        last if( $owx_hwdevice->{STATE} eq "Initialized");
        main::Log(1,"OWX: Waiting, at t=$i ".$dev." is still ".$owx_hwdevice->{STATE});
        select(undef,undef,undef,3); 
      }
      main::Log(1, "OWX: Can't open ".$dev) if( $owx_hwdevice->{STATE} ne "Initialized");
      #-- reset the 1-Wire system in COC/CUNO
      CUL_SimpleWrite($owx_hwdevice, "Oi");
      return undef;
    }else{
      main::Log(1, $msg." not defined");
      return $msg." not defined";
    } 
}

sub Alarms () {
  my ($self) = @_;
  
  return 0;
} 

########################################################################################
# 
# OWX_CCC_Complex - Send match ROM, data block and receive bytes as response
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
  
  my $select;
  my $res = "";
  
  #-- get the interface
  my $owx_hwdevice  = $hash->{HWDEVICE};
  
  #-- has match ROM part
  if( $owx_dev ){
    #-- ID of the device
    my $owx_rnf = substr($owx_dev,3,12);
    my $owx_f   = substr($owx_dev,0,2);

    #-- 8 byte 1-Wire device address
    my @owx_ROM_ID  =(0,0,0,0 ,0,0,0,0); 
    #-- from search string to reverse string id
    $owx_dev=~s/\.//g;
    for(my $i=0;$i<8;$i++){
       $owx_ROM_ID[7-$i]=substr($owx_dev,2*$i,2);
    }
    $select=sprintf("Om%s%s%s%s%s%s%s%s",@owx_ROM_ID); 
    Log 3,"OWX: Sending match ROM to COC/CUNO ".$select
       if( $owx_debug > 1);
    #--
    CUL_SimpleWrite($owx_hwdevice, $select);
    my ($err,$ob) = OWX_CCC_ReadAnswer($owx_hwdevice);
    #-- padding first 9 bytes into result string, since we have this 
    #   in the serial interfaces as well
    $res .= "000000000";
  }
  #-- has data part
  if ( $data ){
    OWX_CCC_Send($hash,$data);
    $res .= $data;
  }
  #-- has receive part
  if( $numread > 0 ){
    #$numread += length($data);
    Log 3,"COC/CUNO is expected to deliver $numread bytes"
      if( $owx_debug > 1);
    $res.=OWX_CCC_Receive($hash,$numread);
  }
  Log 3,"OWX: returned from COC/CUNO $res"
    if( $owx_debug > 1);
  return $res;
}

########################################################################################
#
# OWX_CCC_Discover - Discover devices on the 1-Wire bus via internal firmware
#
# Parameter hash = hash of bus master
#
# Return 0  : error
#        1  : OK
#
########################################################################################

sub Discover () {
  
  my ($self) = @_;
  my $hash = $self->{hash};
  
  my $res;
  
  #-- get the interface
  my $owx_hwdevice  = $hash->{HWDEVICE};
  
  #-- zero the array
  @{$hash->{DEVS}}=();
  #-- reset the busmaster
  OWX_CCC_Init($hash);
  #-- get the devices
  CUL_SimpleWrite($owx_hwdevice, "Oc");
  select(undef,undef,undef,0.5);
  my ($err,$ob) = OWX_CCC_ReadAnswer($owx_hwdevice);
  if( $ob ){
    Log 3,"OWX_CCC_Discover: Answer to ".$owx_hwdevice->{NAME}." device search is ".$ob;
    foreach my $dx (split(/\n/,$ob)){
      next if ($dx !~ /^\d\d?\:[0-9a-fA-F]{16}/);
      $dx =~ s/\d+\://;
      my $ddx = substr($dx,14,2).".";
      #-- reverse data from culfw
      for( my $i=1;$i<7;$i++){
        $ddx .= substr($dx,14-2*$i,2);
      }
      $ddx .= ".".substr($dx,0,2);
      push (@{$hash->{DEVS}},$ddx);
    }
    return 1;
  } else {
    Log 1, "OWX: No answer to ".$owx_hwdevice->{NAME}." device search";
    return 0;
  }
}

########################################################################################
# 
# OWX_CCC_Init - Initialize the 1-wire device
#
# Parameter hash = hash of bus master
#
# Return 1 : OK
#        0 : not OK
#
########################################################################################

sub Init () { 
  my ($self) = @_;
  my $hash = $self->{hash};
  
  #-- get the interface
  my $owx_hwdevice  = $hash->{HWDEVICE};
  
  my $ob = CallFn($owx_hwdevice->{NAME}, "GetFn", $owx_hwdevice, (" ", "raw", "ORm"));
  return 0 if( !defined($ob) );
  return 0 if( length($ob) < 13);
  if( substr($ob,9,4) eq "OK" ){
    return 1;
  }else{
    return 0
  }
}

########################################################################################
#
# OWX_CCC_ReadAnswer - Replacement for CUL_ReadAnswer for better control
# 
# Parameter: hash = hash of bus master 
#
# Return: string received 
#
########################################################################################

sub
OWX_CCC_ReadAnswer($)
{
  my ($hash) = @_;
  
  my $type = $hash->{TYPE};

  my $arg ="";
  my $anydata=0;
  my $regexp =undef;
   
  my ($mculdata, $rin) = ("", '');
  my $buf;
  my $to = 3;                                         # 3 seconds timeout
  $to = $hash->{RA_Timeout} if($hash->{RA_Timeout});  # ...or less
  for(;;) {
      return ("Device lost when reading answer for get $arg", undef)
        if(!$hash->{FD});

      vec($rin, $hash->{FD}, 1) = 1;
      my $nfound = select($rin, undef, undef, $to);
      if($nfound < 0) {
        next if ($! == EAGAIN() || $! == EINTR() || $! == 0);
        my $err = $!;
        DevIo_Disconnected($hash);
        return("OWX_CCC_ReadAnswer $arg: $err", undef);
      }
      return ("Timeout reading answer for get $arg", undef)
        if($nfound == 0);
      $buf = DevIo_SimpleRead($hash);
      return ("No data", undef) if(!defined($buf));

 

    if($buf) {
      Log 5, "CUL/RAW (ReadAnswer): $buf";
      $mculdata .= $buf;
    }

    # \n\n is socat special
    if($mculdata =~ m/\r\n/ || $anydata || $mculdata =~ m/\n\n/ ) {
      if($regexp && $mculdata !~ m/$regexp/) {
        CUL_Parse($hash, $hash, $hash->{NAME}, $mculdata, $hash->{initString});
      } else {
        return (undef, $mculdata)
      }
    }
  }
}

########################################################################################
#
# OWX_CCC_Receive - Read data from the 1-Wire bus
# 
# Parameter: hash = hash of bus master, numread = number of bytes to read
#
# Return: string received 
#
########################################################################################

sub OWX_CCC_Receive ($$) {
  my ($hash,$numread) = @_;
  
  my $res="";
  my $res2="";
  
  #-- get the interface
  my $owx_hwdevice  = $hash->{HWDEVICE};
  
  for( 
  my $i=0;$i<$numread;$i++){
  #Log 1, "Sending $owx_hwdevice->{NAME}: OrB";
  #my $ob = CallFn($owx_hwdevice->{NAME}, "GetFn", $owx_hwdevice, (" ", "raw", "OrB"));
  CUL_SimpleWrite($owx_hwdevice, "OrB");
  select(undef,undef,undef,0.01);
  my ($err,$ob) = OWX_CCC_ReadAnswer($owx_hwdevice);
  #Log 1, "Answer from $owx_hwdevice->{NAME}:$ob: ";

    #-- process results  
    if( !(defined($ob)) ){
      return "";
    #-- four bytes received makes one byte of result
    }elsif( length($ob) == 4 ){
      $res  .= sprintf("%c",hex(substr($ob,0,2)));
      $res2 .= "0x".substr($ob,0,2)." ";
    #-- 11 bytes received makes one byte of result
    }elsif( length($ob) == 11 ){
      $res  .= sprintf("%c",hex(substr($ob,9,2)));
      $res2 .= "0x".substr($ob,9,2)." ";
    #-- 18 bytes received from CUNO 
    }elsif( length($ob) == 18 ){
    
    my $res = "OWX: Receiving 18 bytes from CUNO: $ob\n";
    for(my $i=0;$i<length($ob);$i++){  
      my $j=int(ord(substr($ob,$i,1))/16);
      my $k=ord(substr($ob,$i,1))%16;
      $res.=sprintf "0x%1x%1x ",$j,$k;
    }
    Log 3, $res;
    
    #$numread++;
    #-- 20 bytes received = leftover from match
    }elsif( length($ob) == 20 ){
      $numread++;
    }else{
      Log 1,"OWX: Received unexpected number of ".length($ob)." bytes on bus ".$owx_hwdevice->{NAME};
    } 
  }
  Log 3, "OWX: Received $numread bytes = $res2 on bus ".$owx_hwdevice->{NAME}
     if( $owx_debug > 1);
  
  return($res);
}

########################################################################################
# 
# OWX_CCC_Reset - Reset the 1-Wire bus 
#
# Parameter hash = hash of bus master
#
# Return 1 : OK
#        0 : not OK
#
########################################################################################

sub Reset () { 
  my ($self) = @_;
  my $hash = $self->{hash};
  
  #-- get the interface
  my $owx_hwdevice  = $hash->{HWDEVICE};
  
  my $ob = CallFn($owx_hwdevice->{NAME}, "GetFn", $owx_hwdevice, (" ", "raw", "ORb"));
  
  if( substr($ob,9,4) eq "OK:1" ){
    return 1;
  }else{
    return 0
  }
}

#########################################################################################
# 
# OWX_CCC_Send - Send data block  
#
# Parameter hash = hash of bus master, data = string to send
#
# Return response, if OK
#        0 if not OK
#
########################################################################################

sub OWX_CCC_Send ($$) {
  my ($hash,$data) =@_;
  
  my ($i,$j,$k);
  my $res  = "";
  my $res2 = "";

  #-- get the interface
  my $owx_hwdevice  = $hash->{HWDEVICE};
  
  for( $i=0;$i<length($data);$i++){
    $j=int(ord(substr($data,$i,1))/16);
    $k=ord(substr($data,$i,1))%16;
  	$res  =sprintf "OwB%1x%1x ",$j,$k;
    $res2.=sprintf "0x%1x%1x ",$j,$k;
    CUL_SimpleWrite($owx_hwdevice, $res);
  } 
  Log 3,"OWX: Send to COC/CUNO $res2"
     if( $owx_debug > 1);
}

########################################################################################
#
# OWX_CCC_Verify - Verify a particular device on the 1-Wire bus
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
  
  my $i;
    
  #-- get the interface
  my $owx_hwdevice  = $hash->{HWDEVICE};
  
  #-- Ask the COC/CUNO 
  CUL_SimpleWrite($owx_hwdevice, "OCf");
  #-- sleeping for some time
  select(undef,undef,undef,3);
  CUL_SimpleWrite($owx_hwdevice, "Oc");
  select(undef,undef,undef,0.5);
  my ($err,$ob) = OWX_CCC_ReadAnswer($owx_hwdevice);
  if( $ob ){
    foreach my $dx (split(/\n/,$ob)){
      next if ($dx !~ /^\d\d?\:[0-9a-fA-F]{16}/);
      $dx =~ s/\d+\://;
      my $ddx = substr($dx,14,2).".";
      #-- reverse data from culfw
      for( my $i=1;$i<7;$i++){
        $ddx .= substr($dx,14-2*$i,2);
      }
      $ddx .= ".".substr($dx,0,2);
      return 1 if( $dev eq $ddx);
    }
  }
  return 0;
} 

1;