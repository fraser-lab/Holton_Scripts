#! /bin/tcsh -f
#    
#    auto-converging refmac5 script        -James Holton     3-19-18
#
set pdbin = starthere.pdb
set mtzfile = ./refme.mtz
set libfile = ""
set tempfile = tempfile
set refmac5 = refmac5

set CONVERGE
set SALVAGE_LAST
set damp = 0.5
set NCYC = 5
set min_shift = 0.01
set min_Oshift = 0
set min_Bshift = 1
set max_trials = 10000
set max_diverge = 50
set user_scale = ""
rm -f ${tempfile}shifts

# parameters for damping the PDB manually
# maximum allowed changes
set maxdXYZ = ""
set maxdocc = ""
set maxdB   = ""
set user_maxB = ""
set user_minB = ""

# use outlier B factors as key to occupancy refinement, units of sigma
set hinudge = 10
set lonudge = 4

# a few command-line options
foreach arg ( $* )
    if("$arg" =~ *.pdb) set pdbin = "$arg"
    if("$arg" =~ *.mtz) set mtzfile = "$arg"
    if("$arg" =~ *.cif) set libfile = "$arg"
    if(-x "$arg") then
        set test = `echo | $arg |& awk '/REFMAC/{print 1}'`
        if("$test" == "1") then
            set refmac5 = $arg
            echo "refmac executable: $refmac5"
        endif
    endif
    if("$arg" =~ conver*) set CONVERGE
    if("$arg" =~ noconver*) unset CONVERGE
    if("$arg" =~ salvage*) set SALVAGE_LAST
    if("$arg" =~ nosalvage*) unset SALVAGE_LAST
    if("$arg" =~ append*) set APPEND
    if("$arg" =~ noappend*) unset APPEND
    if("$arg" =~ converge_scale*) set CONVERGE_SCALE
    if("$arg" =~ F000*) set find_F000
    if("$arg" =~ prune_bad*) then
        set PRUNE_BADDIES = `echo $arg | awk -F "=" '{print $NF+0}'`
    endif
    if("$arg" =~ nudge_occ*) then
        set NUDGE_OCC
        set user_nudge = `echo $arg | awk -F "=" '{print $NF+0}'`
        if("$user_nudge" != "0") then
            set hinudge = $user_nudge
            set lonudge = $user_nudge
        endif
    endif
    if("$arg" =~ prune_highB*) then
       set PRUNE_HIGHB
       set highB = `echo $arg | awk -F "=" '{print $NF+0}'`
       if("$highB" == "0") set highB = 499
    endif
    if("$arg" =~ maxdXYZ=*) set maxdXYZ = "$arg"
    if("$arg" =~ maxdocc=*) set maxdocc = "$arg"
    if("$arg" =~ maxdB=*)   set maxdB   = "$arg"
    if("$arg" =~ minB=*)    set user_minB   = `echo $arg | awk -F "=" '{print $2+0}'`
    if("$arg" =~ maxB=*)    set user_maxB   = `echo $arg | awk -F "=" '{print $2+0}'`
    set int = `echo $arg | awk '{print int($1)}'`
    if("$arg" == "$int") set NCYC = $int
    set test = `echo $arg | awk '/A$/ && $1+0>0{print $1+0}'`
    if("$test" != "") set min_shift = $test
    set test = `echo $arg | awk '/O$/ && $1+0>0{print $1+0}'`
    if("$test" != "") set min_Oshift = $test
    set test = `echo $arg | awk '/B$/ && $1+0>0{print $1+0}'`
    if("$test" != "") set min_Bshift = $test
    set test = `echo $arg | awk '/^scale=/{print substr($1,index($1,"=")+1)+0}'`
    if("$test" != "") set user_scale = $test
    set test = `echo $arg | awk '/^trials=/{print substr($1,index($1,"=")+1)+0}'`
    if("$test" != "") set max_trials = $test
    set test = `echo $arg | awk '/^diverge=/{print substr($1,index($1,"=")+1)+0}'`
    if("$test" != "") set max_diverge = $test
    set test = `echo $arg | awk '/^ncyc=/{print substr($1,index($1,"=")+1)+0}'`
    if("$test" != "") set NCYC = $test
end

set test = `echo "one\ntwo" | tac |& awk 'NR==1 && /two/{print "1"}'`
if("$test" != "1") then
    alias tac "awk '{line[++n]="'$0'"} END{for(;n>0;--n) print line[n]}'"
endif


#get variables from mtz file
echo "go" | mtzdump hklin $mtzfile |\
awk '/OVERALL FILE STATISTICS/,/No. of reflections used/' |\
awk 'NF>10 && $(NF-1) ~ /[FJQPWADI]/' |\
cat >! ${tempfile}mtzdmp

# use completeness, or F/sigF to pick default F
cat ${tempfile}mtzdmp |\
awk '$(NF-1) == "F"{F=$NF; meanF=$8; reso=$(NF-2); comp=substr($0,32)+0; \
      getline; \
      S="none";meanS=1e6;\
      if($(NF-1)=="Q"){S=$NF;if($8)meanS=$8};\
      meanF/=meanS;\
      print F, S, reso, comp, meanF;}' |\
awk 'toupper($1) != "FC"' |\
sort -k3n,4 -k4nr,5 -k5nr >! ${tempfile}F

# use completeness, or I/sigI to pick default IP
cat ${tempfile}mtzdmp |\
awk '$(NF-1) == "J"{I=$NF; meanI=$8; reso=$(NF-2); comp=substr($0,32)+0; \
      getline; \
      S="none";meanS=1e6;\
      if($(NF-1)=="Q"){S=$NF;if($8)meanS=$8};\
      meanI/=meanS;\
      print I, S, reso, comp, meanI;}' |\
awk 'toupper($1) != "IC"' |\
sort -k3n,4 -k4nr,5 -k5nr >! ${tempfile}I


# and extract all dataset types/labels
cat ${tempfile}mtzdmp |\
awk 'NF>2{print $(NF-1), $NF, " "}' |\
cat >! ${tempfile}cards

# pick F with best resolution, or F/sigma
set F    = `awk '$1 !~ /part/ && $2 != "none"{print}' ${tempfile}F | head -n 1`
if("$F" == "") then
    set F    = `awk '$1 !~ /part/{print}' ${tempfile}F | head -n 1`
endif
set SIGF
if($#F > 2) then
    set SIGF = $F[2]
    set F    = $F[1]
    if("$SIGF" == "none") set SIGF = ""
endif

# pick I with best resolution, or I/sigma
set IP    = `awk '$1 !~ /part/ && $2 != "none"{print}' ${tempfile}I | head -n 1`
if("$IP" == "") then
    set IP    = `awk '$1 !~ /part/{print}' ${tempfile}I | head -n 1`
endif
set SIGIP
if($#IP > 2) then
    set SIGIP = $IP[2]
    set IP    = $IP[1]
    if("$SIGIP" == "none") set SIGIP = ""
endif





if("$F" == "") then

    #get variables from mtz file
    echo "go" | mtzdump hklin $mtzfile |\
    awk '/OVERALL FILE STATISTICS/,/No. of reflections used/' |\
    awk 'NF>10 && $(NF-1) ~ /[GL]/{print $(NF)}' |\
    cat >! ${tempfile}anocards

    # pick first 2 valid datasets, dangerous? 
    set F    = `head -n 4 ${tempfile}anocards`
    set SIGF
    if($#F == 4) then
        set F = "F+=$F[1] SIGF+=$F[2] F-=$F[3] SIGF-=$F[4]"
    endif
    rm -f ${tempfile}anocards

endif






# detect any Fparts
cat ${tempfile}mtzdmp |\
awk '$(NF-1) == "F" && /part/{F=$NF; \
      getline; P=$NF; print "FPART="F" PHIP="P}' |\
sort -k1.12g |\
awk '{++n;gsub("=",n"=");print}' |\
cat >! ${tempfile}Fpart
set Fparts  = `cat ${tempfile}Fpart`
set partstrucs = `awk '{print substr($1,6)+0}' ${tempfile}Fpart`
set SCPART
set SCPART_CARD
if("$Fparts" != "") then
    set SCPART_CARD = "SCPART $partstrucs"
#    set SCPART = "$SCPART_CARD"
endif
if("$Fparts" != "" && "$user_scale" != "" && $user_scale != "0") then
    set SCPART_CARD = "SCPART $user_scale"
    set SCPART = "$SCPART_CARD"
endif
rm -f ${tempfile}Fpart

# is there a Free-R flag?
set FREE = ""
set FREEcad = ""
foreach label ( FREE FreeR_flag FreeRflag R-free-flags R_FREE_FLAGS )
grep " $label " ${tempfile}cards >& /dev/null
if(! $status) then
    set freeflag = $label
    set FREE =  FREE=$label
    set FREEcad = E3=FreeR_flag
endif
end

# are there phases?
set HL = ""
set HLcad = ""
grep HLD ${tempfile}cards >& /dev/null
if(! $status) then
    set HL = "HLA=HLA HLB=HLB HLC=HLC HLD=HLD"
    set HLcad = "E4=HLA E5=HLB E6=HLC E7=HLD"
endif
grep HLDDM ${tempfile}cards >& /dev/null
if(! $status) then
    set HL = "HLA=HLADM HLB=HLBDM HLC=HLCDM HLD=HLDDM"
    set HLcad = "E4=HLADM E5=HLBDM E6=HLCDM E7=HLDDM"
endif


set shift = ""
echo "<html>"

again:

set trials = 0
set trials_since_damp = 0
set trials_since_start = 0
set damp_step = 0.5
set undamp_step = 0.2
if(! $?APPEND) then
    rm -f refmac_shifts.txt
    rm -f refmac_Rplot.txt
    rm -f refmac_scales.txt
endif
cp -p $pdbin last_refmac.pdb

resume:
set moving = 1
set last_time = 0
while ($moving && $trials_since_start < $max_trials || $last_time)

    set FP = "FP=$F"
    if($#F > 1) set FP = "$F"
    set SIGFP
    if("$SIGF" != "") set SIGFP = "SIGFP=$SIGF"
    if("$F" == "") set FP = ""
    if("$FP" == "" && "$IP" != "") then
        set FP = "IP=$IP"
        set SIGFP = ""
        if("$SIGIP" != "") set SIGFP = "SIGIP=$SIGIP"
    endif
    set LABIN = "LABIN $FP $SIGFP $Fparts $FREE $HL"

    set DAMP = "DAMP $damp $damp"

    set otheropts
    set extraopts
    if(-e refmac_opts.txt) then
        set otheropts = "@refmac_opts.txt"
        set test = `awk 'toupper($1) ~ /^LABI/{print}' refmac_opts.txt | wc -l`
        if("$test" != "0") set LABIN = ""
        set test = `awk 'toupper($1) ~ /^DAMP/{print}' refmac_opts.txt | wc -l`
        if("$test" != "0") set DAMP = ""
    endif
    set LIBSTUFF
    if(-e "$libfile") set LIBSTUFF = "LIBIN $libfile"
    if(-e atomsf.lib) set LIBSTUFF = "$LIBSTUFF ATOMSF ./atomsf.lib"
    if($?find_F000) then
        set LIBSTUFF = "$LIBSTUFF MSKOUT ${tempfile}rawmask.map"
        set extraopts = "MAKE HOUT Y"
    endif

    $refmac5 HKLIN $mtzfile HKLOUT ./refmacout.mtz $LIBSTUFF \
XYZIN  $pdbin XYZOUT refmacout.pdb << EOF-refmac | tee ${tempfile}.log
$LABIN
$SCPART
$otheropts
$extraopts
$DAMP
NCYC $NCYC
EOF-refmac

    if($status || ! -e refmacout.pdb) then
        set BAD = "refmac failed ( $status ) ."
        goto exit
    endif

    set n = `tail -1 refmac_scales.log |& awk '{print $1+1}'`

    # extract twin statistics
    tac ${tempfile}.log |\
    awk '/ Cycle / && stats!=""{print stats,funk+0;exit}\
         /function value/{funk=$NF}\
         $1==5{$2*=100;$3*=100;$1="";stats=$0}' >! ${tempfile}stats.txt
    set stats = `cat ${tempfile}stats.txt`
    tac ${tempfile}.log |\
    awk '/^Twin fractions /{print $4,$5,$6,$7,$8,$9,$10,$11,$12,$13;exit}' |\
    cat >! ${tempfile}twinstats.txt
    set twinstats = `cat ${tempfile}twinstats.txt`
    echo "$n $stats $twinstats " | tee -a refmac_Rplot.txt
    rm -f ${tempfile}stats.txt ${tempfile}twinstats.txt

    if($#stats > 3) then
        set R = $stats[1]
        set Rfree = $stats[2]
        if(! $?minR && -e refmacout_minR.pdb) then
            set test = `awk '/  R VALUE  / && /ING SET/ && $NF+0>0{print $NF*100}' refmacout_minR.pdb`
            if("$test" != "") set minR = "$test"
        endif
        if(! $?minRfree && -e refmacout_minRfree.pdb) then
            set test = `awk '/  FREE R VALUE  / && $NF+0>0{print $NF*100}' refmacout_minRfree.pdb`
            if("$test" != "") set minRfree = "$test"
        endif
        if(! $?minR) set minR = $R
        if(! $?minRfree) set minRfree = $Rfree
        set test = `echo $R $minR | awk '{print ($1<$2)}'`
        if($test) then
            set minR = $R
            set minR_n = $n
            cp -p refmacout.pdb refmacout_minR.pdb
        endif
        set test = `echo $Rfree $minRfree | awk '{print ($1<$2)}'`
        if($test) then
            set minRfree = $Rfree
            set minRfree_n = $n
            cp -p refmacout.pdb refmacout_minRfree.pdb
        endif
    endif

    # get refined partial structure /solvent scale factors
    tac ${tempfile}.log |\
    awk '/Cycle/ && s0 != ""{print s0,B0,s1,B1,s2,B2,s3,B3;exit}\
         /function value/{funk=$NF}\
         /Overall               : scale = /{s0=$5;B0=$NF}\
         /Partial structure    1: scale = /{s1=$6;B1=$NF}\
         /Partial structure    2: scale = /{s2=$6;B2=$NF}\
         /Partial structure    3: scale = /{s3=$6;B3=$NF}' |\
    cat >! ${tempfile}scales.txt
    set scales = `cat ${tempfile}scales.txt`
    echo "$n $scales " | tee -a refmac_scales.log
    rm -f ${tempfile}scales.txt

    if($?find_F000) then
        if($#scales != 4) then
            set BAD = "solvent mask scale unknown.  $#scales values available.  Cannot compute F000"
            goto exit
        endif
        if(! -e ${tempfile}rawmask.map) then
            set BAD = "rawmask.map not produced, cannot compute F000"
            goto exit
        endif
        # need to know the cell, for volume
        set CELL = `awk '/Cell from mtz :/{print $5,$6,$7,$8,$9,$10}' ${tempfile}.log`
        # need to know SG, for ASU count
        set SGnum = `awk '/Space group from mtz: /{print $7+0}' ${tempfile}.log`
        # number of copies of each pdb file atom in the unit cell
        set symops = `awk -v SGnum=$SGnum 'SGnum==$1{print $2}' ${CLIBD}/symop.lib`
        if("$symops" == "") then
            set BAD = "unable to determine number of symmetry operators"
            goto exit
        endif
        if($#CELL != 6) then
            set BAD = "cannot get unit cell, cannot compute F000"
            goto exit
        endif
        # calculate cell volume
        echo $CELL |\
        awk 'NF==6{DTR=atan2(1,1)/45; A=cos(DTR*$4); B=cos(DTR*$5); G=cos(DTR*$6); \
            skew = 1 + 2*A*B*G - A*A - B*B - G*G ; if(skew < 0) skew = -skew;\
            printf "%.3f\n", $1*$2*$3*sqrt(skew)}' |\
        cat >! ${tempfile}volume
        set CELLvolume = `cat ${tempfile}volume`
        rm -f ${tempfile}volume


        # mask is not always on proper scale, max value should be unity
        set mapscale = `echo | mapdump mapin ${tempfile}rawmask.map | awk '/Maximum density/{print 1./$NF}'`
        echo "scale factor $mapscale" |\
        mapmask mapin ${tempfile}rawmask.map mapout ${tempfile}_mask.map 
        set mapscale = `echo | mapdump mapin ${tempfile}_mask.map | awk '/Maximum density/{print 1./$NF}'`
        echo "scale factor $mapscale" |\
        mapmask mapin ${tempfile}_mask.map mapout bulk_solvent_mask.map 
        set mapscale = `echo | mapdump mapin bulk_solvent_mask.map | awk '/Maximum density/{print 1./$NF}'`
        echo "final bulk solvent mask map scale: $mapscale"
        rm -f ${tempfile}rawmask.map

        # fraction of unit cell occupied by this mask
        set mask_cellfrac = `echo | mapdump mapin bulk_solvent_mask.map | awk '/Mean density/{print $NF}'`
        echo "bulk solvent mask cell fraction: $mask_cellfrac"

        # count number of electrons in mask, using refined bulk solvent scale
        set bulk_F000 = `echo "$mask_cellfrac $CELLvolume $scales[3] " | awk '{print $1*$2*$3}'`
        echo "$bulk_F000 total electrons/cell in the solvent mask"

        # now we have done the hard part, now just add up all the electrons represented by the coordinates

        # count up atom types - weigthed by occupancy
        cat refmacout.pdb |\
        awk '/^ATOM|^HETAT/{occ=substr($0, 55, 6);Ee=$NF;\
             count[Ee]+=occ;} \
          END{for(Ee in count) print count[Ee],Ee}' |\
        cat >! ${tempfile}Ee_counts.txt

        # get a list of atomic numbers
        cat ${CLIBD}/atomsf.lib |\
        awk '/^[A-Z]/{Ee=$1;getline;print Ee,$2}' |\
        cat - ${tempfile}Ee_counts.txt |\
        awk '/^[A-Z]/{Z[$1]=$2;next}\
           {Zsum+=$1*Z[$2]} END{print Zsum}' |\
        cat >! ${tempfile}Zsum.txt
        set Zsum = `cat ${tempfile}Zsum.txt`
        set Zsum_F000 = `echo $Zsum $symops | awk '{print $1*$2}'`
        set Zsum_offset = `echo $Zsum_F000 $CELLvolume | awk '{print $1/$2}'`
        echo "coordinate file electrons/cell: $Zsum_F000"

        set F000 = `echo $Zsum_F000 $bulk_F000 | awk '{print $1+$2}'`
        echo "estimated F000 value: $F000 electrons/cell"
    endif

    # dampen the shift if called for?
    if("$maxdXYZ" != "" || "$maxdocc" != "" || "$maxdB" != "") then
        set opts = ( $maxdXYZ $maxdocc $maxdB )
        if("$user_minB" != "") set opts = ( $opts minB=$user_maxB )
        if("$user_maxB" != "") set opts = ( $opts maxB=$user_maxB )
        damp_pdb.com last_refmac.pdb refmacout.pdb $opts
        mv refmacout.pdb undamped.pdb
        mv new.pdb refmacout.pdb
    endif

    cat last_refmac.pdb |\
    awk '/^ATOM|^HETAT/{++n;\
       print n,substr($0,31,8),substr($0,39,8),substr($0,47,8),"|",substr($0,12,16)}' |\
    cat >! ${tempfile}before.xyz
    cat refmacout.pdb |\
    awk '/^ATOM|^HETAT/{++n;\
       print n,substr($0,31,8),substr($0,39,8),substr($0,47,8),"|",substr($0,12,16)}' |\
    cat >! ${tempfile}after.xyz
    cat ${tempfile}before.xyz ${tempfile}after.xyz |\
    awk '{split($0,w,"|");key=w[2]} \
       X[key]==""{X[key]=$2;Y[key]=$3;Z[key]=$4;next} \
       {print (X[key]-$2)^2+(Y[key]-$3)^2+(Z[key]-$4)^2,substr($0,index($0,"|"))}' |\
    cat >! ${tempfile}ms_shifts.txt
    set shift = `awk '{++n;sum+=$1} END{if(n) printf "%.3f", sqrt(sum/n)}' ${tempfile}ms_shifts.txt`
    # take maximum shift
    set shift = `sort -gr ${tempfile}ms_shifts.txt | awk '{print sqrt($1);exit}'`
    set shift_atom = `sort -gr ${tempfile}ms_shifts.txt | awk -F "|" '{print $2;exit}'`
    rm -f ${tempfile}before.xyz ${tempfile}after.xyz ${tempfile}ms_shifts.txt >& /dev/null


    cat last_refmac.pdb |\
    awk '/^ATOM|^HETAT/{++n;print n,substr($0,55,6)+0,"|",substr($0,12,16)}' |\
    cat >! ${tempfile}before.o
    cat refmacout.pdb |\
    awk '/^ATOM|^HETAT/{++n;print n,substr($0,55,6)+0,"|",substr($0,12,16)}' |\
    cat >! ${tempfile}after.o
    cat ${tempfile}before.o ${tempfile}after.o |\
    awk '{split($0,w,"|");key=w[2]} \
       O[key]==""{O[key]=$2;next} \
       {print (O[key]-$2)^2,substr($0,index($0,"|"))}' |\
    cat >! ${tempfile}ms_o.txt
    set oshift = `awk '{++n;sum+=$1} END{if(n) printf "%.3f", sqrt(sum/n)}' ${tempfile}ms_o.txt`
    # take maximum shift
    set oshift = `sort -gr ${tempfile}ms_o.txt | awk '{print sqrt($1);exit}'`
    set oshift_atom = `sort -gr ${tempfile}ms_o.txt | awk -F "|" '{print $2;exit}'`
    rm -f ${tempfile}before.o ${tempfile}after.o ${tempfile}ms_o.txt >& /dev/null


    cat last_refmac.pdb |\
    awk '/^ATOM|^HETAT/{++n;print n,substr($0,61,6)+0,"|",substr($0,12,16)}' |\
    cat >! ${tempfile}before.B
    cat refmacout.pdb |\
    awk '/^ATOM|^HETAT/{++n;print n,substr($0,61,6)+0,"|",substr($0,12,16)}' |\
    cat >! ${tempfile}after.B
    cat ${tempfile}before.B ${tempfile}after.B |\
    awk '{split($0,w,"|");key=w[2]} \
       B[key]==""{B[key]=$2;next} \
       {print (B[key]-$2)^2,substr($0,index($0,"|"))}' |\
    cat >! ${tempfile}ms_B.txt
    set Bshift = `awk '{++n;sum+=$1} END{if(n) printf "%.3f", sqrt(sum/n)}' ${tempfile}ms_B.txt`
    # take maximum shift
    set Bshift = `sort -gr ${tempfile}ms_B.txt | awk '{print sqrt($1);exit}'`
    set Bshift_atom = `sort -gr ${tempfile}ms_B.txt | awk -F "|" '{print $2;exit}'`
    rm -f ${tempfile}before.B ${tempfile}after.B ${tempfile}ms_B.txt >& /dev/null


    echo "moved $shift A  $oshift occ $Bshift B (waiting for $min_shift $min_Oshift $min_Bshift )   $shift_atom   $oshift_atom   $Bshift_atom" |\
      tee -a refmac_shifts.txt
    tail -10 refmac_shifts.txt |\
    awk '{++n;v[n]=$2;sum+=$2;ssqr=$2*$2}\
      END{avg=sum/n;sum=0;for(i=1;i<=n;++i)sum+=(v[i]-avg)^2;\
        print sqrt(sum/n),sqrt(ssqr/n)}' |\
    cat >! ${tempfile}_rms_shift
    set rmsd_shift = `awk '{print $1}' ${tempfile}_rms_shift`
    set rms_shift = `awk '{print $2}' ${tempfile}_rms_shift`
    set trials    = `awk 'END{print NR}' refmac_shifts.txt`
    @ trials_since_damp = ( $trials_since_damp + 1 )
    @ trials_since_start = ( $trials_since_start + 1 )
#    if($trials > 2000 && "$rms_shift" != "") then
#        echo "rmsd shift in last 20 trials: $rmsd_shift"
#        set shift = "$rmsd_shift"
#    endif
    set moving = `echo "$shift $oshift $Bshift $min_shift $min_Oshift $min_Bshift" | awk '{print ($1+0>$4+0 || $2+0>$5+0 || $3+0>$6+0)}'`
    if( $moving && $trials_since_damp > 30 ) then
        set trials_since_damp = 0
        set test = `echo $damp_step 1e-5 | awk '{print ($1<$2)}'`
        if($test) then
            echo "damping increment too fine."
            set converge_damped
        else
#            set damp_step = `echo $damp_step 0.5 | awk '{print $1*$2}'`
            set undamp_step = `echo $undamp_step 0.5 | awk '{print $1*$2}'`
            echo "reducing un-damp step to $undamp_step"
        endif
        set damp = `echo $damp $damp_step | awk '{print $1 * $2}'`
        echo "convergence taking too long, damping shifts by $damp_step"
    endif
#    if($trials > 5000) then
#        set min_shift = `echo $min_shift | awk '{print $1*1.1}'`
#    endif
    set moving = `echo "$shift $oshift $Bshift $min_shift $min_Oshift $min_Bshift" | awk '{print ($1+0>$4+0 || $2+0>$5+0 || $3+0>$6+0)}'`
    echo "checking $shift $oshift $Bshift > $min_shift ($moving) "

    foreach m ( `seq 9 -1 1` )
        @ o = ( $m - 1 )
        if(-e minus${o}_refmac.pdb) cp -p minus${o}_refmac.pdb minus${m}_refmac.pdb
    end
    cp -p last_refmac.pdb minus1_refmac.pdb
    cp -p last_refmac.pdb last_last_refmac.pdb
    cp -p refmacout.pdb last_refmac.pdb
    set pdbin = last_refmac.pdb

    cat refmacout.pdb |\
    awk '{id=substr($0,12,15)} \
        /^ATOM|^HETAT/ && substr($0,55,6)+0==0{++bad[id]}\
      ! bad[id]{print}' |\
    cat >! nonzero.pdb
    cat refmacout.pdb |\
    awk '{id=substr($0,12,15)} \
        /^ATOM|^HETAT/ && substr($0,55,6)+0==0{++bad[id]}\
      bad[id]{print}' |\
    tee -a refined_to_zero.pdb
    set pdbin = nonzero.pdb

    set output_atoms = `egrep "^ATOM|^HETAT" refmacout.pdb | wc -l`
    set nonzero_atoms = `egrep "^ATOM|^HETAT" nonzero.pdb | wc -l`
    if("$output_atoms" != "$nonzero_atoms") echo "WARNING: only $nonzero_atoms of $output_atoms are non-zero"


    if($?NUDGE_OCC) then
        set medB = `awk '/^ATOM|^HETAT/{print substr($0,61)+0}' $pdbin | sort -g | awk '{v[NR]=$1} END{print v[int(NR/2)]}'`
        set madB = `awk -v medB=$medB '/^ATOM|^HETAT/{print sqrt((substr($0,61)-medB)^2)}' $pdbin | sort -g | awk '{v[NR]=$1} END{print v[int(NR/2)]}'`
        set maxB = `awk '/^ATOM|^HETAT/{print substr($0,61)+0}' $pdbin | sort -gr | head -1`
        set minB = `awk '/^ATOM|^HETAT/{print substr($0,61)+0}' $pdbin | sort -g | head -1`
        if("$user_maxB" != "") set maxB = $user_maxB
        if("$user_minB" != "") set minB = $user_minB

        echo "BSTAT $maxB $minB $medB $madB" |\
        cat - $pdbin |\
        awk -v hinudge=$hinudge -v lonudge=$lonudge '\
         /^BSTAT/{maxB=$2;minB=$3;medB=$4;madB=$5;next} ! /^ATOM|^HETAT/{print}\
         /^ATOM|^HETAT/{O=substr($0,55,6)+0;B=substr($0,61)+0; \
           before=substr($0,1,54);after=substr($0,67)\
           deltaO=0;\
           if(B>=maxB && maxB>medB+hinudge*madB)deltaO=-0.01;\
           if(B<=minB && minB<medB-lonudge*madB)deltaO=+0.01;\
           O+=deltaO;\
           if(O>1)O=1;\
           if(O<0.01) next;\
           printf("%s%6.2f%6.2f%s\n",before,O,B,after);}' |\
        cat >! newocc.pdb
        set nudges = `diff newocc.pdb $pdbin | egrep '>' | wc -l`
        set nudgedBs = `diff newocc.pdb $pdbin | awk '/^>/{print substr($0,63,6)}'`
        echo "nudged $nudges occupancies of extreme B factors: $nudgedBs"
        set pdbin = newocc.pdb
    endif

    if($?PRUNE_HIGHB) then
        set medB = `awk '/^ATOM|^HETAT/{print substr($0,61)+0}' $pdbin | sort -g | awk '{v[NR]=$1} END{print v[int(NR/2)]}'`
        set madB = `awk -v medB=$medB '/^ATOM|^HETAT/{print sqrt((substr($0,61)-medB)^2)}' $pdbin | sort -g | awk '{v[NR]=$1} END{print v[int(NR/2)]}'`
        set maxB = `awk '/^ATOM|^HETAT/{print substr($0,61)+0}' $pdbin | sort -gr | head -1`
        set test = `echo $maxB $highB | awk '{print ($1+0>$2+0)}'`
        if($test) then
            cat $pdbin |\
            awk -v highB=$highB '/^ATOM|^HETAT/ && substr($0,61)+0>=highB{next}\
               {print}' |\
            cat >! pruned.pdb
            cat $pdbin |\
            awk -v highB=$highB '/^ATOM|^HETAT/ && substr($0,61)+0<highB{next}\
               {print}' |\
            cat >! highB.pdb
            set pdbin = pruned.pdb
            set atomsleft = `egrep "^ATOM|^HETAT" $pdbin | wc -l`
            echo "pruning B factors of $highB  (median = $medB +/- $madB max= $maxB).  $atomsleft atoms left"
            set trials_since_damp = 0
        endif
    endif


    if($?PRUNE_BADDIES) then
        # pick a threshold
        set thresh = `echo $PRUNE_BADDIES 3 | awk '{print ($1>$2?$1:$2)}'`

        echo "labin F1=DELFWT PHI=PHDELWT" |\
         fft hklin refmacout.mtz mapout fofc.map > /dev/null
        echo "scale factor -1" |\
         mapmask mapin fofc.map mapout fcfo.map > /dev/null
        pick.com fcfo.map -top  | tee pick.log
        set worst = `awk '/nearest neighbor/{getline;print $5;exit}' pick.log`
        set test = `echo $worst $thresh | awk '{print ($1>$2)}'`
        echo -n "" >! baddie.txt
        if($test) then
            pick.com -top=10 fcfo.map $pdbin 0.001A -fast | tee pick.log 
            awk '/neighbor/,""' pick.log |\
            awk '$5+0>=3 && $6+0<=0.5{print substr($0,58);exit}' >! baddie.txt
        endif
        set test = `awk 'NF>0' baddie.txt | wc -l`
        if($test) then
            cat baddie.txt |\
            awk '{print "/"$0"/{next}"}' |\
            cat >! filter.awk
            echo '{print}' >> filter.awk
            awk -f filter.awk $pdbin >! filtered.pdb
            set pdbin = filtered.pdb
            set baddie = `cat baddie.txt`
            set atomsleft = `egrep "^ATOM|^HETAT" $pdbin | wc -l`
            echo "pruned $baddie from the strucutre, $atomsleft atoms left"
            set trials_since_damp = 0
        endif
    endif


    # apply scales to partial structures?
    if("$user_scale" != "") then
        # use the scaled Fobs
        tac ${tempfile}.log |\
        awk '/Overall / && /: scale = /' |\
        awk -F "=" '{print $2+0,$3+0;exit}' |\
        cat >! ${tempfile}scale.txt
        set scale = `awk '{print 1/$1}' ${tempfile}scale.txt`
        set B     = `awk '{print -$2}' ${tempfile}scale.txt`
        set B = 0
        echo "scaling $mtzfile by $scale $B"
        cad hklin1 $mtzfile hklout ./refmac_nextin.mtz << EOF > /dev/null
scale file 1 $scale $B
labin file 1 all
EOF
        set mtzfile = ./refmac_nextin.mtz
    endif
    cp -p $mtzfile ${tempfile}nextin.mtz 
    set partscales = `awk '/Data line--- SCPART/{print $4,$5,$6,$7}' ${tempfile}.log` 
    if(0 && $#partscales > 0) then
        set refmacnum = 0
        rm -f ${tempfile}partscales.txt
        foreach partscale ( $partscales )
            @ refmacnum = ( $refmacnum + 1 )
            set Fpart = `echo $partscale $Fparts | awk '{n=$1;for(i=2;i<=NF;++i)if($i~"^FPART"n"="){print substr($i,8);exit}}'`
            set PHIpart = `echo $partscale $Fparts | awk '{n=$1;for(i=2;i<=NF;++i)if($i~"PHIP"n"="){print substr($i,7);exit}}'`

            tac ${tempfile}.log |\
            awk -v n=$refmacnum '/Partial structure / && /: scale = / && $3+0==n' |\
            awk -F "=" '{print $2+0,$3+0;exit}' |\
            cat >! ${tempfile}scale.txt
            set partSB = `cat ${tempfile}scale.txt`
            if($#partSB != 2) then
                set BAD = "unable to scale partial structures"
                goto exit
            endif
            echo "$Fpart $PHIpart $partSB" | tee -a ${tempfile}partscales.txt
        end
        # apply scales
        foreach Fpart ( `echo "$Fparts" | awk '{for(i=1;i<=NF;++i){if($i~/^FPART/) print substr($i,8)}}'` )
            set PHIpart = `echo "$Fparts $Fpart" | awk '{for(i=1;i<=NF;++i){if($i~"="$NF) print substr($(i+1),7)}}'`

            set partSB = `egrep "^$Fpart " ${tempfile}partscales.txt | awk '{print $3,$4}'`
            echo "refined scale for $Fpart is $partSB "
            if($#partSB != 2) set partSB = ( 1 0 )
            set test = `echo "$partSB" | awk '{print ($1<0.1 || $1>10 || $2>20 || $2<-20)}'`
            if($test) then
#                set BAD = "refmac scaling blew up"
#                goto exit
            endif
            set test = `echo "$partSB" | awk '{print ($1<0.5)}'`
            if($test) set partSB = ( 0.8 $partSB[2] )
            set test = `echo "$partSB" | awk '{print ($1>10.0)}'`
            if($test) set partSB = ( 1.2 $partSB[2] )
            set test = `echo "$partSB" | awk '{print ($2>10)}'`
            if($test) set partSB = ( $partSB[1] 5 )
            set test = `echo "$partSB" | awk '{print ($2<-10)}'`
            if($test) set partSB = ( $partSB[1] -5 )
            echo "scaling $Fpart $PHIpart by $partSB "
            echo head |\
            mtzdump hklin ${tempfile}nextin.mtz |\
            awk 'NF>10' | awk '$(NF-1)~/^[FQIP]$/{++n;print $NF" "}' |\
            egrep -v "^$Fpart " | egrep -v "^$PHIpart " |\
            awk '{++n;print "E"n"="$1}' >! ${tempfile}tokens.txt
            set tokens = `cat ${tempfile}tokens.txt`
            cad hklin1 ${tempfile}nextin.mtz hklin2 ${tempfile}nextin.mtz hklout ${tempfile}refmac_pluspart.mtz << EOF > /dev/null
SCALE FILE 2 $partSB
labin file 1 $tokens
labin file 2 E1=$Fpart E2=$PHIpart
EOF
            mv ${tempfile}refmac_pluspart.mtz ${tempfile}nextin.mtz
            
            if ($?CONVERGE_SCALE) then
                set shift = `echo $partSB | awk '{print sqrt(($1-1)^2)}'`
                set moving = `echo "$shift $oshift $Bshift $min_shift $min_Oshift $min_Bshift" | awk '{print ($1+0>$4+0 || $2+0>$5+0 || $3+0>$6+0)}'`
                echo "scale shift $shift > $min_shift ($moving) "
            endif
        end
    endif
    mv ${tempfile}nextin.mtz ./refmac_nextin.mtz
    set mtzfile = ./refmac_nextin.mtz

    if(! $?CONVERGE) set moving = 0

    if($last_time == 1) then
        echo "exiting on specified last_time "
        break
    endif

    if($?max_diverge && $?minR_n) then
        set since_minR = `echo $n $minR_n | awk '{print $1-$2}'`
        set test = `echo $since_minR $max_diverge | awk '{print ($1>$2)}'`
        if($test) then
            set DIVERGING
            echo "things are getting worse! this will be the last time. "
            if($?SALVAGE_LAST) cp -p refmacout_minR.pdb $pdbin
            set last_time = 1
        endif
    endif

end


set test = `echo $damp | awk '{print ($1<1)}'`
if($test && ! $?converge_damped && ! $last_time) then
    echo "loosening the damping factor a bit..."
    set damp = `echo $damp $undamp_step | awk '{print $1*(1+$2)}' | awk '$1>1{$1=1} {print}'`
    set trials_since_damp = 0
    goto resume
endif

if("$Fparts" != "" && "$SCPART" == "" && "$SCPART_CARD" != "") then
    set SCPART = "$SCPART_CARD"
#    goto resume
endif

echo "labin F1=DELFWT PHI=PHDELWT" |\
 fft hklin refmacout.mtz mapout fofc.map > /dev/null
#pick.com -6 fofc.map refmacout.pdb -top

if($?DIVERGING) echo "refinement was diverging."
if($trials_since_start == $max_trials) echo "maximum trials reached."

exit:
if($?BAD) then
    echo "ERROR: $BAD"
    exit 9
endif
