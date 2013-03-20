########################################################################################
#
# 99_myUtils.pm
#
# Collection of various routines
#
########################################################################################
package main;
use strict;
use warnings;
use POSIX;

sub
myUtils_Initialize($$)
{
  my ($hash) = @_;
}

########################################################################################
#
#  Untoggle von Uli M
#
#   define <name> notify <sensor> {Untoggle("<sensor>")} 
#
########################################################################################

sub
Untoggle($)
{
 my ($obj) = @_;

 if (Value($obj) eq "toggle"){
   if (OldValue($obj) eq "off") {
     Log 5, "Untoggle ".$obj." toggle -> on";
     fhem ("setstate ".$obj." on");
   }
   else {
     fhem ("setstate ".$obj." off");
     Log 5, "Untoggle ".$obj." toggle -> off";
   }
 } elsif ( Value($obj) eq "dim100%" ) {
   fhem ("setstate ".$obj." on");
 } else {
   fhem "setstate ".$obj." ".Value($obj);
 }

}

########################################################################################
#
#   Uncomplex von Peter A Henning
#
#   define <name> notify <sensor> {Uncomplex("<sensor>",List_of_Sensors)} 
#
########################################################################################

sub
Uncomplex($)
{
 my ($obj,@list) = @_;
 my $sen;

 if (Value($obj) eq "toggle"){
     Log 5, "Uncomplex ".$obj." toggle -> off";
     fhem ("setstate ".$obj." off");
     foreach $sen (@list) { 
       Log 5, "Uncomplex ".$obj.".".$sen." -> off";
       fhem ("setstate ".$sen." off");
     }
  } elsif (value($obj) eq "dimupdown"){
     Log 5, "Uncomplex ".$obj." toggle -> on";
     fhem ("setstate ".$obj." on");
     foreach $sen (@list) { 
       Log 5, "Uncomplex ".$obj.".".$sen." -> on";
       fhem ("setstate ".$sen." on");
     }
  } else {
    fhem "setstate ".$obj." ".Value($obj);
  }
}

###Version der Module###############################################################################
{fhem "define weblink_version weblink htmlCode {getVersion()}"}
sub getVersion()
{
    my @versions = qx (grep '\$Id:' /usr/share/fhem/FHEM/*.pm);
   
    my $ret = "<div class=modversion><table class='modversion'>";
    $ret .= "<tr class=title><td>Modul</td><td>Version</td><td>Datum</td><td>Autor</td></tr>\n";
   
    my $counter = 1;
    foreach (@versions) {
        my ($mod, $version) = split("\#",$_);
        my @Daten = split(" ",$version);
        $ret .= "<tr>";
        $ret .= "<td>$Daten[1]</td>";
        $ret .= "<td>$Daten[2]</td>";
        $ret .= "<td>$Daten[3] $Daten[4]</td>";
        $ret .= "<td>$Daten[5]</td>";
        $ret .= "</tr>\n";
        $counter++
    }
    $ret .= "</table></div>";
    return $ret;
}
###Ende Version der Module###########################################################################
1;
