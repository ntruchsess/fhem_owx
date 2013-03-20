# ! /usr/bin/sh

# stop old fhem
/sbin/killproc /usr/bin/perl /usr/bin/fhem.pl fhem.cfg

# copy files to new fhem

cp startfhem /usr/share/fhem

cp FHEM/15_EMX.pm /usr/share/fhem/FHEM
cp FHEM/15_EMX.pm /usr/share/fhem/FHEM/15_CUL_EM.pm
cp FHEM/70_NT5000.pm /usr/share/fhem/FHEM
cp FHEM/00_OWX.pm /usr/share/fhem/FHEM
#cp FHEM/00_OWFS.pm /usr/share/fhem/FHEM
cp FHEM/21_OWTHERM.pm /usr/share/fhem/FHEM
cp FHEM/21_OWMULTI.pm /usr/share/fhem/FHEM
cp FHEM/21_OWSWITCH.pm /usr/share/fhem/FHEM
cp FHEM/21_OWCOUNT.pm /usr/share/fhem/FHEM
cp FHEM/21_OWAD.pm /usr/share/fhem/FHEM
cp FHEM/21_OWID.pm /usr/share/fhem/FHEM
cp FHEM/21_OWLCD.pm /usr/share/fhem/FHEM
#cp FHEM/01_FHEMWEB.pm /usr/share/fhem/FHEM
cp FHEM/59_Weather.pm /usr/share/fhem/FHEM
cp FHEM/92_FileLog.pm /usr/share/fhem/FHEM
#cp FHEM/98_SVG.pm /usr/share/fhem/FHEM
#cp FHEM/99_myUtils.pm /usr/share/fhem/FHEM
#cp FHEM/nt5000d.gplot /usr/share/fhem/FHEM
#cp FHEM/nt5000m.gplot /usr/share/fhem/FHEM
#cp FHEM/nt5000y.gplot /usr/share/fhem/FHEM
#cp FHEM/emxd.gplot /usr/share/fhem/FHEM
#cp FHEM/emxm.gplot /usr/share/fhem/FHEM
#cp FHEM/owxd.gplot /usr/share/fhem/FHEM
#cp FHEM/tempall.gplot /usr/share/fhem/FHEM
#cp FHEM/rk.gplot /usr/share/fhem/FHEM
#cp FHEM/pahstyle.css /usr/share/fhem/FHEM
#cp FHEM/pahsvg_style.css /usr/share/fhem/FHEM
#cp FHEM/pahsvg_defs.svg /usr/share/fhem/FHEM
#cp FHEM/svg.js /usr/share/fhem/FHEM

# start new fhem
/usr/bin/perl /usr/bin/fhem.pl fhem.cfg
