#!/bin/sh

NOW=`date '+%Y%m%d_%H%M%S'`

SVR_NUM=256
SRU_SIZE="64"
ADV_WIN="44"
LINK_BUF="40"
RTOMIN="0.2"
E_BUFMAX="40"
E_HOPMAX="1"
E_BW="1"

REPEAT="1"

SCRIPT="ahtcp.A.tcl"
OUTPUT="goodput.${NOW}.txt"
NS_OUT="out.ns"
ET_OUT="out.et"
TCP_OUT="out.tcp"
Q_OUT="out.q"
GP_OUT="gp.dat"
Q_REC="q.rec"

NS_CMD="ns"
GP_CMD="./gp.sh"
TAIL_1_CMD="tail -1"
#SEQ_CMD="jot"
# in Linux
SEQ_CMD="seq"

#######################################################################
# Argument Options
# Tagging
if [ $# -eq 1 ]; then
	OUTPUT="goodput.${1}.txt"
	cp $SCRIPT $HOME/data/$SCRIPT.${1}
	cp ${0} $HOME/data/${0}.${1}
fi


########################################################################
# Initialization
if [ -e $Q_OUT ]; then
	rm -f $Q_OUT
fi
if [ -e $Q_REC ]; then
	rm -f $Q_REC
fi
cat /dev/null > $OUTPUT

# Output Data Index (line 1)
for SRU in $SRU_SIZE
  do
  printf "\tGP_${SRU}KB\tDR_${SRU}KB\tPST_${SRU}KB\tQ_MAX_${SRU}KB" >> $OUTPUT
done
echo "" >> $OUTPUT

# Start Simulations
#for SVR in `$SEQ_CMD $SVR_NUM`
#for SVR in 2 4 8 16 32 64 96 128 160 192 224 256
for SVR in 2 4 8 16 32 64 96 128 160 192 224 256 320 384 512 640 768 896 1024
do
  printf "$SVR\t" >> $OUTPUT
  for SRU in $SRU_SIZE
  do
    cat /dev/null > $GP_OUT
	if [ -e $Q_REC ]; then
		rm -f $Q_REC
	fi
    i=0
    while [ $i -lt $REPEAT ]
			do
      # Exec Simulation ($i = random seed)
			$NS_CMD $SCRIPT $SVR $ADV_WIN $SRU $LINK_BUF $RTOMIN $E_BUFMAX $E_HOPMAX $E_BW $i
	  # Calculate Goodput and Summary
			$GP_CMD $NS_OUT $SVR $SRU	>> $GP_OUT
	  # Record Average and Maximum Queue Length if possibe
			if [ -e $Q_OUT ]; then
					grep -v '^0' $Q_OUT |\
							awk '{len += $2} END {printf len/NR "\t"}' >> $Q_REC
					grep -v '^0' $Q_OUT | sort -nr -k 2 | head -2 | tail -1 |\
							awk '{printf $2 "\n"}' >> $Q_REC
					rm -f $Q_OUT
			fi
	  # Prepare Next Simulation
			i=`expr $i + 1`
    done
    # Caluclate Average Goodput and  Drop Rate
		awk '{sum_tp += $1; s_cnt += $2; d_cnt += $3;} \
         END {printf sum_tp/NR "\t" d_cnt/s_cnt "\t" s_cnt/NR "\t";}' $GP_OUT >> $OUTPUT
	# Caluclate Maximum Queue Length
		if [ -e $Q_REC ]; then
				sort -nr -k 2 $Q_REC | head -1 | awk '{printf $2 "\t"}' >> $OUTPUT
		# When average calculation
		# awk '{len += $1} END {printf len/NR "\t"}' $Q_REC >> $OUTPUT
		else
				printf "\t" >> $OUTPUT
		fi
  done
  echo "" >> $OUTPUT
done


############################
# 
if [ $# -eq 1 ]; then
		cp $OUTPUT $HOME/data/goodput.${1}.txt
fi


