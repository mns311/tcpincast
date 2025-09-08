#!/bin/sh
# Simple goodput calculator v.2 (2016-12-29)
#   Block size = SvrNum * SRU_KB
if [ $# -ne 3 ]; then
  echo "Usage: <this> out.ns SvrNum SRU_KB"
	exit 1
fi

NS_OUT=$1
SVR_NUM=$2
SRU_KB=$3

# Goodput
START=`grep '^r.*0\ 1\ tcp' $NS_OUT | head -1 | awk '{print $2;}'`
FINISH=`grep '^r.*0\ 1\ tcp' $NS_OUT | grep -v 'tcp\ 40\ ' | tail -1 | awk '{print $2;}'`

GP=`echo "scale=6; ( $SVR_NUM * $SRU_KB * 1024.0 * 8 ) \
    * 10 ^ (-6) / ( $FINISH - $START )" | bc`

# Dropped
DROPPED=`grep '^d.*tcp' $NS_OUT | wc -l | awk '{print $1;}'`

# Sent
SENT_TO0=`grep '^+.*\ 0\ tcp' $NS_OUT | wc -l | awk '{print $1;}'`

# In FreeBSD, set echo '-e' option
# In Linux, no need to set option
echo "${GP}\t${SENT_TO0}\t${DROPPED}"
 

