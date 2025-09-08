# Version Desctiption
set version "Nearly Complete Connection Serialization including SYN diff RTT (v.1/v84)"

# Check Args Format
if {$argc != 7} {
  puts -nonewline "Usage: ns incast <app_num> <actsrv_num> <advwnd-pkt> "
  puts "<SRU-KB> <link_buf-pkt> <rto_min-ms> <seed>"
  exit 1
}

puts "--- ${version} ---"

#################################################################
# Argments
# ApplicationNum: $argv(0)
## The number of barrier synchronized applications (hereafter BSApp)
## app_num means the number of client node
set app_num [lindex $argv 0]
# ActiveServerNum: $argv(1)
set actsvr_num [lindex $argv 1]
# Advertised Window size (pkt): $argv(2)
set adv_wnd [lindex $argv 2]
# SRU Size (Byte) ... only Payload: $argv(3)
set SRU [expr [lindex $argv 3] * 1024]
# Link Buffer (pkt): $argv(4)
set link_buf [lindex $argv 4]
# RTOmin (ms): $argv(5) ... default TCP is 200ms
set rtomin_ms [lindex $argv 5]
# Random Seed: $argv(6)
set seed [lindex $argv 6]

################################################################
# Variables
# Create a simulator object
set ns [new Simulator]

## Bandwidth (Gbps)
set bw_Gbps 1

## Cluster Size (max server num) divided by 3
## Note : Claster names are "a" and "b", respectively.
##        For examples, if 1024 is set,
##        then cluster_a is 512 and b is 512.
set cluster_size 256

## Link Delay (us)
## Transmission Delay
set td_us [expr 1500 * 8 / (${bw_Gbps} * pow(10,9)) * pow (10, 6)]

## Basic propagation delay of each link (based on 100us)
set pd_us [expr (100 - (3 * ${td_us})) / 6.]

## Additional propagation delay of server link (100, 200, 300us)
set pd_a1_us [expr (100 - 100) / 2.]
set pd_a2_us [expr (100 - 100) / 2.]
set pd_a3_us [expr (100 - 100) / 2.]

## Background Traffic
set bgt_pkt_byte 1500
## ratio to Bandwidth (0.01 means 1Gbps * 0.01 = 10Mbps)
set bgt_total_rate 0.01

# Link Error Rate (Unit:pkt) 0.001 = 0.1% (a loss in 1000 pkt)
# set err_rate 0.001
set err_rate 0

# Base RTT : Propagation Delay and Transmission Delay of a Packet
#            where there is not any others packet. (across 2 nodes)
set bRTT_t1_us [expr 2 * (3 * ${pd_us} + ${pd_a1_us}) + 3 * ${td_us}]
set bRTT_t2_us [expr 2 * (3 * ${pd_us} + ${pd_a2_us}) + 3 * ${td_us}]
set bRTT_t3_us [expr 2 * (3 * ${pd_us} + ${pd_a3_us}) + 3 * ${td_us}]
set bRTT_max_us [expr max(${bRTT_t1_us}, ${bRTT_t2_us}, ${bRTT_t3_us})]
set bRTT_min_us [expr min(${bRTT_t2_us}, ${bRTT_t2_us}, ${bRTT_t3_us})]
set bRTT_avg_us [expr (${bRTT_t1_us} + ${bRTT_t2_us} + ${bRTT_t3_us}) / 3.]
#puts "RTT: t1 = ${bRTT_t1_us}us, t2 = ${bRTT_t2_us}us, t3 = ${bRTT_t3_us}us"

# The number of packets of SRU
set SRU_pkt [expr ceil(${SRU}/1460.)]

# Total Size of All Servers SRU with TCP/IP Header and Handshake (byte)
set SRU_trans [expr (int($SRU / 1460.) + 1) * 1500 + 40]
set Block_trans [expr ${SRU_trans} * ${actsvr_num}]

#############################################################
## Calculate NCCS variables
## 1. K in the paper (APCC2013 osada)
##    K = 1 means complete connection serialization
set kx 2

## 2. initial flow num (always 1 recommended)
##    If you want to reduce initial slow start loss,
##    then set para_num to a large number
set para_num 1

## 3. Optimized advertised window size (pkt) Roll up
set opt_adv_wnd [expr ceil(${bRTT_max_us} * pow(10, -6) \
    * ${bw_Gbps} * pow(10, 9) / (1500 * 8))]

## 4. Optimized advertised window size per flow
##    the minimum size is 4 for a trigger of fast retransmission
set adv_wnd [expr int(${opt_adv_wnd} / ${para_num})]
if {${adv_wnd} < 4} {
	set adv_wnd 4
}

## 5. BaseBDP (byte)
set bBDP_byte [expr ${bw_Gbps} * pow(10, 9) \
					   * ${bRTT_max_us} * pow(10, -6) / 8.]
set bBDP_pkt [expr ${bBDP_byte} / 1500.]


## 6. Time when cwnd reaches base_BDP(RTT)
##    That is the time of end of slow start period
##    m - 1 in the paper (APCC2013 osada)
set eossp_times [expr ceil(log10(${bBDP_byte} / 1500) / log10(2))]

## 7. Slow Start Period (us)
## This is T_1 in the paper (APCC2013 osada)
set ssp_us [expr ${bRTT_max_us} * ${eossp_times} \
				+ ceil(ceil(${bBDP_byte} / 1500.0) \
						   - pow(2, ${eossp_times} - 1)) \
				* 1500 * 8 / (${bw_Gbps} * pow(10, 9)) * pow(10, 6)]

## 8. Data Size (byte) to be transmitted in Slow Start period
## as if it is not in Slow Start Behavior.
set ssp_trans [expr ${bw_Gbps} * pow(10, 9) \
				   * ${ssp_us} * pow(10, -6) / 8]

########################################################################
## Define Barrier Synchronized Application (BSApp)class
Class BSApp
## Constructor
BSApp instproc init {args} {
	## Application ID
	$self set id 0

	## Attached Node
	$self set c_node 0

	## The number of servers
	$self set actsvr_num 0

	## Dummy Hash (define later)
	## tcp_ snk_ ftp_ f_dest_ f_bRTT_us_

	## Flag of finish (app): 0=off, 1=on
	$self set is_app_fin 0

	## Flag of finish (flow): 0=off, 1=on (Array)
	## Define later
	# $self set is_flow_fin_

	## Next flow id under SYN-SENT(?)
	$self set next_syn_flowid 0

	## Next flow id under ESTABLISH
	$self set next_flowid 0

	## The number of current transmitting flows
	$self set cur_flow_num 0
}

#############################################
# Constant / Global Variable
set tick [expr pow(10, -7)]         ; # 100ns
set qmon_interval [expr pow(10, -4)]; # 100us
set maxbackoff 64
Agent/TCP set trace_all_oneline_ true
Agent/TCP set packetSize_ 1460
Agent/TCP set singledup_ 0          ; # 0: Disabled Limited Transmit
Agent/TCP set tcpTick_ $tick        ; # 100ns (default 0.01: 10ms)
Agent/TCP set minrto_ [expr $rtomin_ms * pow(10, -3)] ; # default 0.2 (200ms)
Agent/TCP set maxbackoff_ $maxbackoff ; # (default 64)

Queue/DropTail set queue_in_bytes_ true  ;# Default false
Queue/DropTail set mean_pktsize_ 1500    ;# Default 500

Agent/TCP/IANewreno set maxdupsyn_ 1 ; # maximum number of duplicate SYNs (default 3)

#############################################
# Random Model
# defaultRNG can effect C++ world.
global defaultRNG
$defaultRNG seed [expr ${seed} * ${actsvr_num} + 1]
set rng [new RNG]
# seed 0 equal to current OS time (UTC)
# so seed should be more than 1 for repeatability
$rng seed [expr ${seed} * ${actsvr_num} + 1]

##############################################
# Tracing Message (Optional)
puts -nonewline "ActServer: $actsvr_num, adv_wnd: ${adv_wnd}pkt, "
puts -nonewline "SRU: [lindex $argv 3]KB, link_buf: ${link_buf}pkt, "
puts "RTOmin: ${rtomin_ms}ms, Seed: $seed"
puts -nonewline "BaseRTT_max: ${bRTT_max_us}us, para_num: ${para_num}, "
puts "ssp_us:${ssp_us}us, ssp_trans=${ssp_trans}B"

##############################################
# Check Integrity of variables
if {${actsvr_num} > ${cluster_size}} {
	puts "Error: Too many servers (MAX: ${cluster_size})"
	exit 1
}
# Because of goodput calculation program (MAXFLOW in gp.c)
if {${actsvr_num} * ${app_num} > 8192} {
	puts -nonewline "Error: Too many applications (MAX: "
	puts "[expr 8192 / $actsvr_num])"
	exit 1
}

##############################################
# Open the ns trace file and trace counter
set nf [open out.ns w]
$ns trace-all $nf
set ef [open out.et w]
$ns eventtrace-all $ef
set tf [open out.tcp w]
set qf [open out.q w]

proc finish {} {
	global ns nf ef tf qf
	$ns flush-trace
	close $nf
	close $tf
	close $ef
	close $qf
	puts "Done."
	exit 0
}

############################################
## Shuffle list using likely quick sort
proc shuffle { list } {
	if { [llength $list] < 2 } { return $list }
	set lft {}
	set rgt {}
	foreach item $list {
		if { rand() > 0.5 } {
          lappend lft $item
		} else {
          lappend rgt $item
		}
	}
	concat [shuffle $lft] [shuffle $rgt]
}


################################################
## Start next flows at the same time
BSApp instproc send_next_syn {time} {
	global ns SRU
	$self instvar ftp_ actsvr_num next_syn_flowid f_bRTT_us_

	if {${next_syn_flowid} < ${actsvr_num}} {
		#puts "Time: [$ns now] fid: ${next_syn_flowid} will send SYN (not start) at [expr $time + $f_bRTT_us_(${next_syn_flowid}) * pow(10, -6) / 2] "
		$ns at [expr $time + $f_bRTT_us_(${next_syn_flowid}) * pow(10, -6) / 2] \
			"[$self set ftp_($next_syn_flowid)] send $SRU"
		incr next_syn_flowid
	}
}


##############################################
## Change Active State
BSApp instproc change_next_active_state {state} {
	$self instvar next_flowid snk_ id
	global ns

	$snk_($next_flowid) active 1 
	#puts "Time: [$ns now] App($id):Flow($next_flowid) become active (start sending data)"
	incr next_flowid

	## if next_flowid >= actserver and curflownum < para_num + 1
	## then it should be adjust window size (only the flow)
	## Under considered 2014/11/16
}

##########################################
## Attach TCP Agent to an application
BSApp instproc set_actsvr {actsvr_num_in} {
	global ns tf adv_wnd n_ cluster_size svr_type_ s_bRTT_us_
	$self instvar actsvr_num id c_node f_dest_ f_bRTT_us_
	$self instvar tcp_ snk_ ftp_ is_flow_fin_
	# id is application id

	set actsvr_num $actsvr_num_in

	for {set fid 0} {$fid < $actsvr_num} {incr fid} {
		set tcp_($fid) [new Agent/TCP/IANewreno]
		$tcp_($fid) set fid_ [expr $fid + $id * $actsvr_num]
		$tcp_($fid) set window_ ${adv_wnd}
		$tcp_($fid) attach-trace $tf
		$tcp_($fid) trace maxseq_
		$tcp_($fid) trace ack_
		set ftp_($fid) [new Application/FTP]
		$ftp_($fid) attach-agent $tcp_($fid)
		$ftp_($fid) set type_ FTP
		## Decide server
		set sid [expr ($fid + $id * $actsvr_num) % ${cluster_size}]
		$ns attach-agent $n_($sid) $tcp_($fid)
		#puts -nonewline "flowid [expr $fid + $id * $actsvr_num] on cluster "
		#puts "$svr_type_(${sid}), rtt = $s_bRTT_us_($sid)"
		set snk_($fid) [new Agent/TCPSink/TCPIASink]
		$snk_($fid) set advwnd_ $adv_wnd
		$snk_($fid) active 0
		$ns attach-agent $c_node $snk_($fid)

		## Flow destination Marking
		if {$svr_type_($sid) == "a"} {
			set f_dest_($fid) "a"
		} elseif {$svr_type_($sid) == "b"} {
			set f_dest_($fid) "b"
		}

		## Flow bRTT Marking
		set f_bRTT_us_($fid) $s_bRTT_us_($sid)

		## Set finish flag to OFF(0)
		set is_flow_fin_($fid) 0

		$ns connect $tcp_($fid) $snk_($fid)
	}
}

##############################################
## Create Switchs
set nx   [$ns node]            ;# Nodeid = 0
set nxa  [$ns node]            ;# Nodeid = 1
set nxb  [$ns node]            ;# Nodeid = 2

## Connecting and Setting LinkBuf of Switchs
$ns duplex-link $nxa $nx ${bw_Gbps}Gb ${pd_us}us DropTail
$ns duplex-link $nxb $nx ${bw_Gbps}Gb ${pd_us}us DropTail
$ns queue-limit $nxa $nx ${link_buf}   ;# This is a bottleNeck
$ns queue-limit $nxb $nx ${link_buf}   ;# This is a bottleNeck

#############################################
## Create Clients
for {set i 0} {$i < $app_num} {incr i} {
	set nc_($i) [$ns node]     ;# Nodeid = 3 -- ${app_num} + 2

	## Connecting and Setting LinkBuf of Clients
	$ns duplex-link $nx $nc_($i) ${bw_Gbps}Gb ${pd_us}us DropTail
	$ns queue-limit $nx $nc_($i) 10000
}

############################################
## Link Error Module between Switch and Client (only client 0)
set loss_module [new ErrorModel]
$loss_module unit pkt
$loss_module set rate_ $err_rate
set loss_random_variable [new RandomVariable/Uniform]
$loss_random_variable use-rng ${rng}
$loss_module ranvar ${loss_random_variable}
$loss_module drop-target [new Agent/Null]
$ns lossmodel $loss_module $nx $nc_(0)

## For Shuffling Servers Deployment Pattern
for {set i 0} {$i < $cluster_size} {incr i} {lappend svr_labels $i}
set svr_labels [shuffle $svr_labels]

## For Shuffling RTT Setting Pattern
for {set i 0} {$i < $cluster_size} {incr i} {lappend pd_labels $i}
set pd_labels [shuffle $pd_labels]

## Create Server Nodes and Set Background Traffic
for {set i 0} {$i < $cluster_size} {incr i} {
    set n_($i) [$ns node]
	set svr_label [lindex $svr_labels $i]
	set pd_label  [lindex $pd_labels  $i]
	if {$svr_label % 2 == 0} {
		# This node is belong to the cluster connected swicth nxa.
		set svr_type_($i) "a"
		if {$pd_label % 3 == 0} {
			set pd_s_us [expr ${pd_us} + ${pd_a1_us}]
			set s_bRTT_us_($i) ${bRTT_t1_us}
		} elseif {$pd_label % 3 == 1} {
			set pd_s_us [expr ${pd_us} + ${pd_a2_us}]
			set s_bRTT_us_($i) ${bRTT_t2_us}
		} elseif {$pd_label % 3 == 2} {
			set pd_s_us [expr ${pd_us} + ${pd_a3_us}]
			set s_bRTT_us_($i) ${bRTT_t3_us}
		}
		$ns duplex-link $nxa $n_($i) ${bw_Gbps}Gb ${pd_s_us}us DropTail
		$ns queue-limit $n_($i) $nxa 10000
	} elseif {$svr_label % 2 == 1} {
		# This node is belong to the cluster connected swicth nxb.
		set svr_type_($i) "b"
		if {$pd_label % 3 == 0} {
			set pd_s_us [expr ${pd_us} + ${pd_a1_us}]
			set s_bRTT_us_($i) ${bRTT_t1_us}
		} elseif {$pd_label % 3 == 1} {
			set pd_s_us [expr ${pd_us} + ${pd_a2_us}]
			set s_bRTT_us_($i) ${bRTT_t2_us}
		} elseif {$pd_label % 3 == 2} {
			set pd_s_us [expr ${pd_us} + ${pd_a3_us}]
			set s_bRTT_us_($i) ${bRTT_t3_us}
		}
		$ns duplex-link $nxb $n_($i) ${bw_Gbps}Gb ${pd_s_us}us DropTail
		$ns queue-limit $n_($i) $nxb 10000
	}


	## For debug
	#puts "node $i is of cluster $svr_type_($i) pd = ${pd_s_us}us"

	## For Backgroung Traffic
	set udp_($i) [new Agent/UDP]
	$udp_($i) set fid_ [expr $i + 8192]
	$udp_($i) set packetSize_ ${bgt_pkt_byte}
	$ns attach-agent $n_($i) $udp_($i)
	set cbr_($i) [new Application/Traffic/CBR]
	$cbr_($i) set rate_ \
		[expr ${bw_Gbps} * 1000 * ${bgt_total_rate} / ${cluster_size}]Mb
	$cbr_($i) set packetSize_ ${bgt_pkt_byte}
	$cbr_($i) set random_ 1.0
	$cbr_($i) attach-agent $udp_($i)
	set null_($i) [new Agent/Null]
	$ns attach-agent $nc_([expr $i % $app_num]) $null_($i)
	$ns connect $udp_($i) $null_($i)

	## Start Background Traffic
	if {${bgt_total_rate} > 0} {
		$ns at [expr 1.0 + [$rng uniform 0 38400] * pow(10, -6)] \
			"$cbr_($i) start"
	}
}

## Create applications and start TCP traffic
for {set i 0} {$i < $app_num} {incr i} {
	set app_($i) [new BSApp]
	$app_($i) set id $i

	## Attach the application to the client node
	$app_($i) set c_node $nc_($i)

	## Set Servers and Create Flows belonging to the application
	$app_($i) set_actsvr $actsvr_num

	## Start all applications
	#$app_($i) send_all_syn 1.0

	## Start TCP Traffic as possible (i: app, j: flow belonging app)
	for {set j 0} {$j < $para_num && $j < $actsvr_num} {incr j} {
		$app_($i) send_next_syn 1.0
		$app_($i) change_next_active_state 1
		$app_($i) set cur_flow_num [expr [$app_($i) set cur_flow_num] + 1]
	}
}

$ns at 0.0 "debug"
$ns at 1.0 "check_trans"
$ns at 21.0 "finish"

####################################################################
## for Queue Monitoring
set qmon [$ns monitor-queue $nxa $nx [open qm.out w] ${qmon_interval}]
[$ns link $nxa $nx] queue-sample-timeout

proc check_qlen {} {
	global ns qf qmon
	set now [$ns now]

	$qmon instvar parrivals_ pdepartures_ pdrops_ pkts_
	$qmon instvar barrivals_ bdepartures_ bdrops_ size_
	# Unit: packet
	#puts $qf "$now\t[expr $parrivals_ - $pdepartures_ - $pdrops_]\t$pkts_"
	# Unit: byte
	puts $qf "$now\t[expr $barrivals_ - $bdepartures_ - $bdrops_]\t$size_"
}


###################################################################
## for checking transmission situation

## Each Application
BSApp instproc check {} {
	global ns Block_trans SRU_trans bBDP_pkt ssp_trans para_num kx
	$self instvar actsvr_num tcp_ snk_ is_app_fin id next_flowid
	$self instvar is_flow_fin_ cur_flow_num next_syn_flowid

	set now [$ns now]

	# if the application experience new data,
	# check conditions belows
	set total_bytes 0     ;# For checking flag $is_app_fin
	for {set i 0} {$i < $actsvr_num} {incr i} {
		# get rcvd data size
		set rcvd_bytes [$snk_($i) set bytes_]

		# store total_bytes
		set total_bytes [expr $total_bytes + $rcvd_bytes]

		# If the flow received SYN-ACK(SYN), it starts next flow.
		# Note that it sends SYN only and it does not send data packet
		# until a previous flow finishes.
		if {${i} == ${next_syn_flowid} - 1 && ${rcvd_bytes} >= 40 \
				&& ${next_syn_flowid} < ${actsvr_num}} {
			$self send_next_syn $now
		}

		# If the flow is finished, it starts next flow.
		if {$is_flow_fin_($i) == 0 \
				&& ${rcvd_bytes} >= \
				${SRU_trans} - ${ssp_trans} / ${para_num}} {
			if {${next_flowid} < ${actsvr_num} \
					&& ${cur_flow_num} < ${para_num} * ${kx}} {
				$self change_next_active_state 1
				incr cur_flow_num
				set is_flow_fin_($i) 1
			}
		}

		if {${rcvd_bytes} >= ${SRU_trans}} {
			set cur_flow_num [expr ${cur_flow_num} - 1]
		}

	}

	# if the all flows are finished, mark as $is_app_fin = ON
	if {$total_bytes >= $Block_trans && $is_app_fin == 0} {
		set is_app_fin 1 ;# ON
		puts "time: [$ns now] app($id) is finished."
	}
}


## Global
proc check_trans {} {
	global ns cbr_ cluster_size app_ app_num qmon_interval

	set next_time [expr 20 * pow(10, -6)]
	set now [$ns now]
	set is_all_app_fin 1  ;# ON

	# check all application's traffic only where there are alive
	for {set i 0} {$i < $app_num} {incr i} {
		# check if the flow has outstanding data
		if {[$app_($i) set is_app_fin] == 0} {
			$app_($i) check
			set is_all_app_fin 0
		}
	}

  	# if all application is finished, stop the simulation after 0.1ms
	# else it prepares next checking
    if {$is_all_app_fin == 1} {
		flush stdout
		for {set i 0} {$i < $cluster_size} {incr i} {
			$ns at [expr $now + $next_time] "$cbr_($i) stop"
		}
		puts -nonewline "wait..."
		$ns at [expr $now + 0.1] "finish"
	} else {
		$ns at [expr $now + $next_time] "check_trans"
		for {set i 0} {$i < $next_time} {set i [expr $i + $qmon_interval]} {
			$ns at [expr $now + $i] "check_qlen"
		}
	}
}

proc debug {} {
    global ns
    set next_time 0.5
    set now [$ns now]
	if {$now == int($now)} {
		puts -nonewline "$now"
	} else {
		puts -nonewline "."
	}
    flush stdout
    $ns at [expr $now+$next_time] "debug"
}

#Run the simulation
$ns run
