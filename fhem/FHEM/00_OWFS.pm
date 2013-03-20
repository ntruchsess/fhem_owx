################################################################
#
#  Copyright notice
#
#  (c) 2011 Copyright: Martin Fischer (m_fischer at gmx dot de)
#  All rights reserved
#
#  This script free software; you can redistribute it and/or modify
#  it under the terms of the GNU General Public License as published by
#  the Free Software Foundation; either version 2 of the License, or
#  any later version.
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
################################################################
package main;

use strict;
use warnings;
use Time::HiRes qw(gettimeofday);
use OWNet;

use Data::Dumper;

###################################
# declare variables
my $ownet;
my %gets    = ();
my %models  = ();
my %sets    = ();
my @OWDevices;
my @OWModules;

###################################
# OWFS Standard Properties
$gets{STANDARD} = {
        "address"       => 1,
        "crc8"          => 1,
        "family"        => 1,
        "id"            => 1,
        "locator"       => 0,
        "r_address"     => 0,
        "r_id"          => 0,
        "r_locator"     => 0,
        "type"          => 1,
};

###################################
# OWFS Bus Masters Special Properties
$gets{DS9097} = {
        # there are no special properties for this object
};
$gets{DS9097U} = {
        # there are no special properties for this object
};
$gets{DS9490R} = {
        # there are no special properties for this object
};

###################################
# OWFS informations
$gets{OWFS} = {
        "alarms"        => "",
        "devices"       => "",
        "list"          => "",
        "settings"      => "",
};

###################################
# OWFS settings
$sets{units} = {
        "temperature_scale" => 1,
        "pressure_scale"    => 1,
};
$sets{timeout} = {
        "directory"     => 1,
        "ftp"           => 1,
        "ha7"           => 1,
        "network"       => 1,
        "presence"      => 1,
        "serial"        => 1,
        "server"        => 1,
        "stable"        => 1,
        "uncached"      => 1,
        "usb"           => 1,
        "volatile"      => 1,
        "w1"            => 1,
};

###################################
sub OWFS_Initialize($) {
  my ($hash) = @_;

  # Provider
  $hash->{WriteFn}    = "OWFS_Write";
  $hash->{Clients}    = ":OWCOUNT:OWHUB:OWLCD:OWMULTI:OWSWITCH:OWTEMP:";

  # Normal Devices
  $hash->{DefFn}      = "OWFS_Define";
  $hash->{UndefFn}    = "OWFS_Undef";
  $hash->{GetFn}      = "OWFS_Get";
  #$hash->{SetFn}      = "OWFS_Set";
  $hash->{StateFn}    = "OWFS_SetState";
  $hash->{AttrList}   = "do_not_notify:1,0 loglevel:0,1,2,3,4,5,6 ".
                        "cached:0,1 crc8:0,1 locator:0,1 present:0,1 r_address:0,1 r_id:0,1 r_locator:0,1";
  # Define clients
  @OWModules = split(":",$hash->{Clients});

  # Define models
  foreach my $t (sort keys %gets) {
    $models{$t} = "" if($t ne "OWFS" && $t ne "STANDARD");
  }

}

###################################
sub OWFS_Define($$) {
  my ($hash, $def) = @_;
  my $ret = undef;

  # define <name> OWFS <owserver:port> <model> <id|none> [interval]
  # define foo OWFS 192.168.1.5:4304 DS9490R 93302D000000 10
  my @a = split("[ \t][ \t]*", $def);

  return "wrong syntax: define <name> OWFS <owserver:port> <model> <id|none> [interval]"
    if(@a < 3 || int(@a) > 6);

  my $name      = $a[0];
  my $dev       = $a[2];
  my $model     = $a[3];
  my $id        = "none";
  my $interval  = 10;

  # wrong model
  return "Define $name: wrong model: choose one of " . join " ", sort keys %models
    if(!grep { $_ eq $model } keys %models);
  # missing ID
  return "Define $name: please specify an ID for Model $model"
    if(@a == 4 && $model ne "DS9097");

  if(@a > 4) {
    # ID given for a passive bus master
    return "Define $name: DS9097 is a passive Bus Master without an ID"
      if($model eq "DS9097" && uc($a[4]) ne "none");
    # wrong ID format
    return "Define $name: wrong ID format: specify a 12 digit value"
      if($model ne "DS9097" && uc($a[4]) !~ m/^[0-9|A-F]{12}$/);

    $id = $a[4];
  }

  if(int(@a)==6) { $interval = $a[5]; }

  $hash->{INTERVAL}   = $interval;
  $hash->{OW_ALARM}   = "none";
  $hash->{OW_MODEL}   = $model;
  $hash->{OW_ID}      = $id;
  $hash->{OW_DEVICE}  = $dev;
  $hash->{STATE}      = "Defined";

  $ret = OWFS_DoInit($hash);
  return $ret if($ret);

  return undef;
}

#####################################
sub OWFS_DoInit($) {
  my $hash  = shift;
  my $name  = $hash->{NAME};
  my $model = $hash->{OW_MODEL};
  my $dev   = $hash->{OW_DEVICE};
  my $ret = undef;

  # check Backend server for reachability
  Log GetLogLevel($name,3), "OWFS check for Backend server for 1-wire control at $dev";
  $ret = OWNet::dir($dev." -slash -ff.i","/");
  return "OWFS Can't connect to Backend server for 1-wire control at $dev! Reason: $!" if(!$ret);

  Log GetLogLevel($name,3), "OWFS Backend server for 1-wire control at $dev is reachable for Device $name";

  # get OWFS settings
  $ret = OWFS_GetSettings($hash);
  return "OWFS Can't get settings from Backend server for 1-wire control at $dev" if (!defined($ret));

  # initialize device
  $ret = OWFS_InitializeDevice($hash);
  return "OWFS Can't initialize Device $name" if (!defined($ret));
  $hash->{STATE} = "Initalized";

  # get device special properties
  # $ret = OWFS_GetProperties($hash,$model,%{$gets{$model}});  # there are no special properties for busmasters

  $hash->{STATE} = "active";

  push(@OWModules,$hash->{TYPE});

  # get alarm devices
###
### timer start prüfen
###
  $ret = OWFS_GetAlarmDevices($hash);

  return undef;
}

####################################
sub OWFS_Get($$) {
  my ($hash,@a) = @_;
  my $name  = $hash->{NAME};
  my $dev   = $hash->{OW_DEVICE};
  my $model = $hash->{OW_MODEL};
  my @args;
  my $str;
  my $ret = undef;

  push(@args,sort keys %{$gets{OWFS}});
  push(@args,sort keys %{$gets{$model}});

  return "wrong syntax: argument is missing @a, choose one of ".join(" ",sort @args)
    if (@a < 2);
  return "wrong syntax: unknown argument $a[1], choose one of ".join(" ",sort @args)
    if(!grep { $_ eq $a[1] } @args);

  if ($a[1] eq "alarms") {
    # get alarm devices
    return "wrong syntax: no arguments allowed for $a[1], use <get $name $a[1]>" if (@a > 2);

    $hash->{LOCAL} = 1;
    $ret = OWFS_GetAlarmDevices($hash);
    if($ret) {
      $str = $ret;
    } else {
      $str = "none";
    }
    delete $hash->{LOCAL};

  } elsif ($a[1] eq "devices") {
    # get devices
    return "wrong syntax: no arguments allowed for $a[1], use <get $name $a[1]>" if (@a > 2);

    $ret = OWFS_GetDevices($hash);
    $str = $ret;

  } elsif ($a[1] eq "list") {
    # get list
    return "wrong syntax: too many arguments for $a[1], use <get $name $a[1] [path]>" if (@a > 3);
    my $path;
    $path = $a[2] || "/";

    $ret = OWFS_GetList($hash,$path);
    $str = $ret;

  } elsif ($a[1] eq "settings") {
    # get OWFS settings
    return "wrong syntax: no arguments allowed for $a[1], use <get $name $a[1]>" if (@a > 2);

    $ret = OWFS_GetSettings($hash);
    return "OWFS Can't get settings from $dev" if (!defined($ret));

    foreach my $path (qw(timeout units)) {
      $str .= "\n\t$path:";
      foreach my $query (sort keys %{$sets{$path}}) {
        next if ($sets{$path}{$query} == 0);
        $str .= sprintf("\n\t%-17s => %s",$query, $hash->{$path}{$query}{VAL});
      }
    }

  }
  return "$a[1] => $str";
}

###################################
sub OWFS_Write($$;$$$) {
  my ($hash,$cmd,$path,$arg1,$arg2) = @_;
  my $args  = @_;
  my $name  = $hash->{NAME};
  my $type  = $hash->{TYPE};
  my $cache = "";
  my $dev;
  my $owserver;
  my $owserverArgs = " -slash -ff.i";
  my $offset;
  my $size;
  my $value;
  my $ret   = undef;

  if($type eq "OWFS") {
    $dev = $hash->{OW_DEVICE};
  } else {
    $dev = $hash->{IODev}->{OW_DEVICE};
  }

  $owserver = $dev.$owserverArgs;

  $path = "" if(!defined($path));
  $arg1 = "" if(!defined($arg1));
  $arg2 = "" if(!defined($arg2));

  my ($sPack,$sFile,$sLine,$sSub,$sArgs) = caller(0);
  my ($cPack,$cFile,$cLine,$cSub,$cArgs) = caller(1);
  $sSub =~ s/^.*:://;
  $cSub =~ s/^.*:://;
  Log GetLogLevel($name,5), "$type call: >$sSub(HASH($name),$cmd,$path,$arg1,$arg2)< from >$cSub (Line:$cLine)<";

  $cache = "/uncached"
    if (!defined($attr{$name}{cached}) || $attr{$name}{cached} == 0);

  if ($args == 3) {
    if ($cmd eq "dir") {
      $ret = OWNet::dir($owserver,$path);
    }
    if ($cmd eq "read") {
      $ret = OWNet::read($owserver,$path);
    }
  } elsif ($args == 4) {
    if ($cmd eq "read") {
      $size = $arg1;
      $ret = OWNet::read($owserver,$path);
    }
    if ($cmd eq "write") {
      $value = $arg1;
      $ret = OWNet::write($owserver,$path,$value);
    }
  } elsif ($args == 5) {
    $offset = $arg2;
    if ($cmd eq "read") {
      $size   = $arg1;
      $ret = OWNet::read($owserver,$path);
    }
    if ($cmd eq "write") {
      $value  = $arg1;
      #-- PAH $ret = OWNet::write($owserver,$path,$size,$offset);
      $ret = OWNet::write($owserver,$path,$size);
    }
  }

  if (!defined($ret)) {
    Log GetLogLevel($name,2), "OWFS $name Can't connect to Backend server at $dev ( $! )";
    return undef;
  }

  return $ret;
}

##################################
sub OWFS_InitializeDevice($) {
  my $hash  = shift;
  my $id    = $hash->{OW_ID};
  my $name  = $hash->{NAME};
  my $type  = $hash->{TYPE};
  my @dir;
  my $ret   = undef;

  $hash->{OW_FAMILY} = undef;

  $ret = OWFS_Write($hash,"dir","/");
  return undef if (!defined($ret));

  @dir = sort(split(",",$ret));

  foreach my $entry (@dir) {
    $entry =~ s/\///g;

    if (uc($entry) =~ m/^[0-9|A-F]{2}.[0-9|A-F]{12}$/) {
      if (uc($entry) =~ m/$id/ && !defined($hash->{OW_FAMILY})) {
        $hash->{OW_FAMILY} = substr($entry,0,2);
        Log GetLogLevel($name,4), "$type initialize Device $name (Family: $hash->{OW_FAMILY})";
      }
    }   
  }

  $ret = undef;
  if (defined($hash->{OW_FAMILY}) && $hash->{OW_MODEL} ne "DS9097") {
    $ret = OWFS_GetProperties($hash,"STANDARD");
  }

  return undef if (!defined($ret));

  Log GetLogLevel($name,4), "$type Device $name (Type: $hash->{OW_MODEL}) initialized";
  return 1;
}

##################################
sub OWFS_GetProperties($$;\%) {
  my @params = @_;
  my ($hash,$prop) = ($params[0],$params[1]);
  my $name = $hash->{NAME};
  my $path = $hash->{OW_FAMILY}.".".$hash->{OW_ID};
  my $subname = undef;
  my $subref = undef;
  my $ret  = undef;

  if ($hash->{TYPE} ne "OWFS") {
    $subname = "$hash->{TYPE}_ParseUpdate";
    $subref  = \&$subname;
  }

  $gets{$prop} = $params[2] if(@params > 2);

  foreach my $query (sort keys %{$gets{$prop}}) {
    next if ($gets{$prop}{$query} == 0);
    $ret = undef;
    $ret = OWFS_Write($hash,"read","/$path/$query");
    if (!defined($ret)) {
      Log GetLogLevel($name,4), "OWFS Can't read property >$query< for Device $name";
      return undef;
    } else {
      $ret =~ s/^\s+//g;
      if ($hash->{TYPE} eq "OWFS" || ($hash->{TYPE} ne "OWFS" && $prop eq "STANDARD")) {
        OWFS_UpdateReading($hash,$query,TimeNow(),$ret);
      } else {
        # pass the readings to parent process
        Log GetLogLevel($name,5), "OWFS call: >$subname(HASH($hash->{NAME}))<";
        &$subref($hash,$query,$ret);
      }
    }
  }
  return 1;
}

#####################################
sub OWFS_GetSettings($) {
  my $hash = shift;
  my $name = $hash->{NAME};
  my $value;
  my $ret = undef;

  foreach my $path (sort keys %sets) {
    foreach my $query (sort keys %{$sets{$path}}) {
      next if ($sets{$path}{$query} == 0);
      Log GetLogLevel($name,5), "OWFS global read /settings/$path/$query";
      $ret = undef;
      $ret = OWFS_Write($hash,"read","/settings/$path/$query");
      return undef if (!defined($ret));
      if (defined($ret)) {
        $value = $ret;
        $value =~ s/^\s+//g;
        Log GetLogLevel($name,4), "OWFS global $path $query: $value";
        $hash->{$path}{$query}{VAL}  = $value;
        $hash->{$path}{$query}{TIME} = TimeNow();
      }
    }
  }

  return 1;
}

######################################
sub OWFS_GetDevices($) {
  my $hash  = shift;
  my $name  = $hash->{NAME};
  my $alarm = $hash->{OW_ALARM};
  my $state = $hash->{STATE};
  my $path  = "/";
  my @dir;
  my $id;
  my $str;
  my $retstr;
  my $ret = undef;

  $ret = OWFS_Write($hash,"dir",$path);

  if (defined($ret)) {
    @dir = sort(split(",",$ret));
    $ret = undef;

    foreach my $entry (@dir) {
      #$entry =~ s/.*$path//g;
      $entry =~ s/\///g;

      if (uc($entry) =~ m/^[0-9|A-F]{2}.[0-9|A-F]{12}$/) {
        $id   = substr($entry,3,12);
        $str  = "\n\t$entry: undefined";

        delete($modules{""}) if (defined($modules{""}));
        for my $d (sort { my $x = $modules{$defs{$a}{TYPE}}{ORDER}.$defs{$a}{TYPE} cmp
                                  $modules{$defs{$b}{TYPE}}{ORDER}.$defs{$b}{TYPE};
                             $x = ($a cmp $b) if($x == 0); $x; } keys %defs) {
          next if(IsIgnored($d));

          my $p = $defs{$d};
          my $t = $p->{TYPE};

          next if (!grep /^$t/, @OWModules);

          if (defined($p->{OW_ID}) && $p->{OW_ID} eq $id) {
            $str   = "\n\t$entry: $t:".$p->{NAME};
            $entry = "$t:$p->{NAME}";
          }
        }
        $retstr .= $str;
      }
    }
    $ret = $retstr;
  }
  return $ret;
}

######################################
sub OWFS_GetAlarmDevices($) {
  my $hash  = shift;
  my $name  = $hash->{NAME};
  my $alarm = $hash->{OW_ALARM};
  my $state = $hash->{STATE};
  my $path  = "/alarm/";
  my $count = 0;
  my @dir;
  my $id;
  my $str;
  my $retstr;
  my @alarmDevices = ();
  my $ret = undef;

  $ret = OWFS_Write($hash,"dir",$path);

  if (defined($ret)) {
    @dir = sort(split(",",$ret));
    $ret = undef;

    splice(@alarmDevices,0);

    foreach my $entry (@dir) {
      $entry =~ s/.*$path//g;
      $entry =~ s/\///g;

      if (uc($entry) =~ m/^[0-9|A-F]{2}.[0-9|A-F]{12}$/) {
        $id   = substr($entry,3,12);
        $str  = "\n\t$entry: undefined";

        delete($modules{""}) if (defined($modules{""}));
        for my $d (sort { my $x = $modules{$defs{$a}{TYPE}}{ORDER}.$defs{$a}{TYPE} cmp
                                  $modules{$defs{$b}{TYPE}}{ORDER}.$defs{$b}{TYPE};
                             $x = ($a cmp $b) if($x == 0); $x; } keys %defs) {
          next if(IsIgnored($d));

          my $p = $defs{$d};
          my $t = $p->{TYPE};

          next if (!grep /^$t/, @OWModules);

          if (defined($p->{OW_ID}) && $p->{OW_ID} eq $id) {
            $str   = "\n\t$entry: $t:".$p->{NAME};
            $entry = "$t:$p->{NAME}";
          }
        }
        push(@alarmDevices,$entry);
        $retstr .= $str;
      }
    }
  }

  if (@alarmDevices) {
    $hash->{OW_ALARM} = "@alarmDevices";
    $hash->{STATE} = "alarm";
  } else {
    $hash->{OW_ALARM} = "none";
    $hash->{STATE} = "active";
  }

  Log GetLogLevel($name,4), "OWFS $name Alarm: $hash->{OW_ALARM}"
    if($hash->{OW_ALARM} ne "none" && $hash->{OW_ALARM} ne $alarm);

  # inform changes
  $hash->{CHANGED}[$count++] = "Alarm: $hash->{OW_ALARM}"
    if($hash->{OW_ALARM} ne $alarm);

  $hash->{CHANGED}[$count++] = "State: $hash->{STATE}"
    if($hash->{STATE} ne $state);

  if(!$hash->{LOCAL}) {
    DoTrigger($name, undef) if($init_done);
  }

  $ret = $retstr if($hash->{LOCAL});

  if(!$hash->{LOCAL}) {
    # update timer
    RemoveInternalTimer($hash);
    InternalTimer(time()+$hash->{INTERVAL}, "OWFS_GetAlarmDevices", $hash, 0);
  }

  return $ret;

}

##################################
sub OWFS_GetList($$) {
  my ($hash,$path) = @_;
  my $name = $hash->{NAME};
  my @dir;
  my $ret  = undef;

  $ret = OWFS_Write($hash,"dir",$path);
  Log GetLogLevel($name,5), "OWFS discovered directory: $path";

  if (defined($ret)) {
    @dir = sort(split(",",$ret));
    $ret = undef;

    foreach my $entry (@dir) {
      $ret .= "\n\t$entry";
    }
  } else {
    $ret = "\n\t$path: not found";
  }
  return $ret;
}

##################################
sub OWFS_GetUpdate($\%) {
  my $hash = shift;
  my %update = %{(shift)};
  my $name = $hash->{NAME};
  my $type = $hash->{TYPE};
  my $path = $hash->{OW_FAMILY}.".".$hash->{OW_ID};
  my $subname = "$hash->{TYPE}_ParseUpdate";
  my $subref  = \&$subname;
  my $ret = undef;

  Log GetLogLevel($name,5), "OWFS get updates for $type:$name";
  foreach my $query (sort keys %update) {
    next if ($update{$query} == 0);
    $ret = undef;
    $ret = OWFS_Write($hash,"read","/$path/$query");
    last if(!defined($ret));
    $ret =~ s/^\s+//g;
    # pass the readings to parent process
    Log GetLogLevel($name,5), "OWFS call >$subname(HASH($hash->{NAME}),$query,$ret)<";
    &$subref($hash,$query,$ret);
  }

  return 1;
}

##################################
sub OWFS_GetChildUpdate($\%) {
  my $hash = shift;
  my %update = %{(shift)};
  my %childUpdate = ();
  my $name = $hash->{NAME};
  my $type = $hash->{TYPE};
  my $path = $hash->{OW_FAMILY}.".".$hash->{OW_ID};
  my $subname = "$hash->{TYPE}_ParseUpdate";
  my $subref  = \&$subname;
  my $ret = undef;
  my @ret;

  # check if there is already a childprocess
  if ($hash->{CHILDPID}) {
    Log GetLogLevel($name,2), "$type $name Child already forked: timeout too short?";
    return undef;
  }

  # open a pipe to communicate between Child and Parent process
  pipe(READER,WRITER);

  # fork current process
  $hash->{CHILDPID} = fork();

  if(!defined($hash->{CHILDPID})) {
    # could not fork or forking has failed
    Log GetLogLevel($name,2), "OWFS cannot fork for $type:$name : $!";
    return undef;

  } elsif ($hash->{CHILDPID} == 0) {
    # Child process
    close READER;

    Log GetLogLevel($name,5), "OWFS Child get updates for $type:$name";
    foreach my $query (sort keys %update) {
      next if ($update{$query} == 0);
      $ret = undef;
      $ret = OWFS_Write($hash,"read","/$path/$query");
      last if(!defined($ret));
      $ret =~ s/^\s+//g;
      push(@ret, "$query:$ret");
    }
    # pass readings to Parent process
    print WRITER join(" ",@ret);
    exit(0);

  } else {
    # Parent process
    close WRITER;
    
    # get readings from Child process
    %childUpdate = split(/[: ]/,<READER>);
    # wait for the Child process to complete the updates
    #waitpid($hash->{CHILDPID},0);
    Log GetLogLevel($name,5), "OWFS Parent got updates for $type:$name from Child ($hash->{CHILDPID})";
    delete $hash->{CHILDPID};

    # pass readings to device
    foreach my $query (sort keys %childUpdate) {
      $ret = $childUpdate{$query};
      Log GetLogLevel($name,5), "OWFS Parent call >$subname(HASH($hash->{NAME}),$query,$ret)<";
      &$subref($hash,$query,$ret);
    }

  }

  return 1;

}

##################################
sub OWFS_UpdateReading($$$$) {
  my ($hash,$reading,$now,$value) = @_;

  # exit if empty value
  return undef
    if(!defined($value) || $value eq "");

  # update readings
  $hash->{READINGS}{$reading}{TIME} = $now;
  $hash->{READINGS}{$reading}{VAL}  = $value;
  Log GetLogLevel($hash->{NAME},4), "$hash->{TYPE} $hash->{NAME} $reading: $value"
    if($reading ne "warnings" || ($reading eq "warnings" && $value ne "none"));

  return 1;

}

##################################
sub OWFS_SetState($$$$) {
  my ($hash, $tim, $vt, $val) = @_;
  return undef;
}

##################################
sub OWFS_StandardProperties {
  return \%{$gets{STANDARD}};
}

sub OWFS_StandardScale($$) {
  my ($hash,$scale) = @_;
  return $defs{$hash->{IODev}->{NAME}}{units}{$scale}{VAL};
}

#####################################
sub OWFS_Undef($$) {
  my ($hash, $arg) = @_;
  my $name = $hash->{NAME};

  foreach my $d (sort keys %defs) {
    if (defined($defs{$d}) && defined($defs{$d}{IODev}) && $defs{$d}{IODev} == $hash) {
      my $lev = ($reread_active ? 4 : 2);
      Log GetLogLevel($name,$lev), "deleting port for $d";
      delete $defs{$d}{IODev};
    }
  }
  RemoveInternalTimer($hash);
  undef $ownet;
  return undef;
}

# vim: ts=2:et

1;
