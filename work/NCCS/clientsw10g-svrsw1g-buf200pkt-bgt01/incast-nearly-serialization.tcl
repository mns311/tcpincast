# Serialized Flows (with Max Flow is x fix)
# Check Args
if {$argc != 7} {
  puts -nonewline "Usage: ns incast <app_num> <actsrv_num> <advwnd-pkt> "
  puts "<SRU-KB> <rtomin_ms> <link_buf-pkt> <seed>"
  exit 1
}

#################################################################
## app_num means the number of client node
set app_num [lindex $argv 0]
# ActiveServerNum: $argv(1)
set svr_num [lindex $argv 1]
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

# Bandwidth (Gbps)
set bw_Gbps 10

# Link Delay (us)
set link_del_us 19
# Maximum Random Link Delay: 0--maxrand (us)
#set maxrand_link_del_us 20
set maxrand_link_del_us 0

## Cluster Size (max server num)
set cluster_size 256

## Background Traffic
set bgt_pkt_byte 1500
## ratio to Bandwidth (0.01 means 1Gbps * 0.01 = 10Mbps)
set bgt_total_rate 0.001

# multiple number; minimum is 2.(1 is complete serialization)
set kx 8

# SYN Interval Delay (us) for each Request
set SYN_del_us 0

# Maximum Random SYN Delay: 0--maxrand (us)
set maxrand_SYN_del_us 0

# Total Size (byte) of All Servers SRU with TCP/IP Header and Handshake
set SRU_trans [expr (int($SRU / 1460) + 1) * 1500 + 40]
set Block_trans [expr ${SRU_trans} * ${svr_num}]

# Base RTT : Propagation Delay and Transmission Delay of a Packet
#            where there is not any others packet. (across 2 nodes)
set base_RTT_us [expr ${link_del_us} * 4 + 2 * 1500 * 8 \
					 / (${bw_Gbps} * pow(10, 9)) * pow(10, 6)]

# Optimize Total Advertised Window Size (pkt) ... Roll up
set opt_adv_wnd [expr ceil(${base_RTT_us} * pow(10, -6) \
    * ${bw_Gbps} * pow(10, 9) / (1500 * 8))]

# Max Parallel Flows
## (1) and (2) Only one flow can exist at the same time.
 set para_num 1
## Or (3) and (3)' using specified para_num (K method)
# set para_num 3

## (3) and (3)' Many Flows can exist at the same tine.
## 4 means that refuirements of fast restransmission (to generate 3 dup ACKs)
#set para_num [expr int(${opt_adv_wnd} / 4)]
#if {${para_num} < 1} {
#	set para_num 1
#}

## Calculate Advertised Window per Flow (pkt)
# set adv_wnd 5
set adv_wnd [expr int(${opt_adv_wnd} / ${para_num})]
if {${adv_wnd} < 4} {
	set adv_wnd 4
}


# Minimum Speed between Bandwidth and Adevrtised Window's Capacity (bps)
set flow_cap_bps [expr min(${bw_Gbps} * pow(10, 9), \
			${opt_adv_wnd} * 1500 * 8 / (${base_RTT_us} * pow(10, -6)))]

# BDP with above
set base_BDP_byte [expr ${flow_cap_bps} * ${base_RTT_us} * pow(10, -6) / 8]

## Packet Exchanging Times until fill above flow capacity in Slow Start
## i.e. End of SlowStart Period.
## 1. Considerless Slow Start Period
# set eossp_times 0

## 2 and 3. Consider Slow Start Period
## +1 means that check_trans lag per a rtt. (Not Used)
#set eossp_times [expr ceil(log10(${base_BDP_byte} / 1500) / log10(2)) + 1]
## This is "m - 1" in ICC2013 paper
set eossp_times [expr ceil(log10(${base_BDP_byte} / 1500) / log10(2))]

## Slow Start Period (us)
## This is T1 in ICC2013 paper
## Following is not stricted
#set ssp_us [expr ${base_RTT_us} * ${eossp_times}]
set ssp_us [expr ${base_RTT_us} * ${eossp_times} \
				+ ceil(ceil(${base_BDP_byte} / 1500) \
						   - pow(2, ${eossp_times} - 1)) \
				* 1500 * 8 / (${bw_Gbps} * pow(10, 9)) * pow(10, 6)]

## Data Size (byte) to be transmitted in Slow Start period
## as if it is not in Slow Start Behavior.
set ssp_trans [expr ${flow_cap_bps} * ${ssp_us} * pow(10, -6) / 8]

## Link Error Rate (Unit:pkt) 0.001 = 0.1% (a loss in 1000 pkt)
# set err_rate 0.001
set err_rate 0

## Next Flow_id
set next_flowid 0
## Parameters For Speculative SYN Send
# A Current Number of flows sending data
set cur_flow_num 0


#############################################
# Constant / Global Variable
set tick 0.0000001; # 100ns
set qmon_interval [expr pow(10, -4)]; # 1us

#############################################
# Random Model
# defaultRNG can effect C++ world.
global defaultRNG
$defaultRNG seed [expr ${seed} * ${svr_num} + 1]
set rng [new RNG]
# seed 0 equal to current OS time (UTC)
# so seed should be more than 1 for repeatability
$rng seed [expr ${seed} * ${svr_num} + 1]

#################################################################
# Tracing Message
puts -nonewline "Server: $svr_num, wnd: ${adv_wnd}pkt, "
puts -nonewline "SRU: [lindex $argv 2]KB, link_buf: ${link_buf}pkt, "
puts "Seed: $seed, "
puts -nonewline "Block_trans: ${Block_trans}B, "
puts -nonewline "RTT: [expr $link_del_us * 4]us, "
puts -nonewline "RTT_rand: ${maxrand_link_del_us}us, "
puts "SYN_del: ${SYN_del_us}-[expr $SYN_del_us + $maxrand_SYN_del_us]us"
puts "flow_cap=${flow_cap_bps}bps, base_BDP=${base_BDP_byte}B, "
puts "base_RTT: ${base_RTT_us}us, ssp_us=${ssp_us}us, ssp_trans=${ssp_trans}B"
puts "para: ${para_num}, opt_wnd: ${opt_adv_wnd}, kx: ${kx}"


Agent/TCP set trace_all_oneline_ true
Agent/TCP set packetSize_ 1460
Agent/TCP set singledup_ 0 ;      # 0: Disabled Limited Transmit
Agent/TCP set tcpTick_ $tick ;  # 100ns (default 0.01: 10ms)
Agent/TCP set minrto_ [expr $rtomin_ms * pow(10, -3)] ; # (default 0.2: 200ms)

##############################################
#Open the ns trace file and trace counter
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
# Send SYN Packet
proc send_syn {flowid time} {
	global ns link_del_us ftp_ SRU
	$ns at [expr $time + ${link_del_us} * 2 * 0.000001] \
		"$ftp_($flowid) send $SRU"
}

##############################################
#Create a Switch and a Client node
set nx [$ns node]
set nc [$ns node]
$ns duplex-link $nx $nc ${bw_Gbps}Gb ${link_del_us}us DropTail
$ns queue-limit $nx $nc ${link_buf}

# Link Error Module between Switch and Client
set loss_module [new ErrorModel]
$loss_module unit pkt
$loss_module set rate_ $err_rate
set loss_random_variable [new RandomVariable/Uniform]
$loss_random_variable use-rng ${rng}
$loss_module ranvar ${loss_random_variable}
$loss_module drop-target [new Agent/Null]
$ns lossmodel $loss_module $nx $nc

## Create Nodes and Background Traffic
for {set i 0} {$i < $cluster_size} {incr i} {
    set n_($i) [$ns node]
    $ns duplex-link $nx $n_($i) 1Gb ${link_del_us}us DropTail
    $ns queue-limit $n_($i) $nx 1000

	## For Backgroung Traffic
	set udp_($i) [new Agent/UDP]
	$udp_($i) set fid_ [expr $i + $cluster_size]
	$udp_($i) set packetSize_ ${bgt_pkt_byte}
	$ns attach-agent $n_($i) $udp_($i)
	set cbr_($i) [new Application/Traffic/CBR]
	$cbr_($i) set rate_ \
		[expr ${bw_Gbps} * 1000 * ${bgt_total_rate} / ${cluster_size}]Mb
	$cbr_($i) set packetSize_ ${bgt_pkt_byte}
	$cbr_($i) set random_ 1.0
	$cbr_($i) attach-agent $udp_($i)
	set null_($i) [new Agent/Null]
	$ns attach-agent $nc $null_($i)
	$ns connect $udp_($i) $null_($i)

	# Start Background Traffic
	$ns at [expr 1.0 + [$rng uniform 0 38400] * pow(10, -6)] \
		"$cbr_($i) start"
}

## Create TCP Traffic
for {set i 0} {$i < $svr_num} {incr i} {
    set tcp_($i) [new Agent/TCP/Newreno]
    $tcp_($i) set fid_ $i
	$tcp_($i) set window_ ${adv_wnd}
    $tcp_($i) attach-trace $tf
    $tcp_($i) trace maxseq_
    $tcp_($i) trace ack_
    set ftp_($i) [new Application/FTP]
    $ftp_($i) attach-agent $tcp_($i)
	$ftp_($i) set type_ FTP
    $ns attach-agent $n_($i) $tcp_($i)
    set snk_($i) [new Agent/TCPSink]
    $ns attach-agent $nc $snk_($i)
    $ns connect $tcp_($i) $snk_($i)

	# For FIN flags Emulation
	# If the value is over SRU_trans, the flow is finished.
	set prev_bytes($i) 0

	# For mark tobefin 0: off, 1: on
	set flag_to_be_fin($i) 0

    # Caluclate Delay (us)
    set del_us [expr $SYN_del_us + [$rng uniform 0 ${maxrand_SYN_del_us}]]

	# Start TCP Traffic if possible
	if {$i < ${para_num}} { 
		send_syn $i [expr 1.0 + $del_us * 0.000001]
		incr next_flowid
		incr cur_flow_num
	}
}

## (3)' Prepare Next Flow Multiplicity
## When (1), (2) and (3), Following Sentences should be comment out.
#for {set i $next_flowid} {$i < $svr_num} {incr i} {
#	$tcp_($i) set window_ ${opt_adv_wnd}
#}


$ns at 0.0 "debug"
$ns at 0.99 "check_trans"
$ns at 21.0 "finish"

# for Queue Monitoring
set qmon [$ns monitor-queue $nx $nc [open queue_mon.ns w] ${qmon_interval}]
[$ns link $nx $nc] queue-sample-timeout

proc update_link_del {} {
	global ns nx n_ link_del_us maxrand_link_del_us cluster_size rng
	for {set i 0} {$i < $cluster_size} {incr i} {
		$ns delay $nx $n_($i) [expr $link_del_us \
			   + [$rng uniform 0 ${maxrand_link_del_us}]]us duplex
	}
}

proc check_qlen {} {
	global ns qf qmon
	set now [$ns now]

	$qmon instvar parrivals_ pdepartures_ pdrops_ pkts_
	puts $qf "$now\t[expr $parrivals_ - $pdepartures_ - $pdrops_]\t$pkts_"
}


proc check_trans {} {
	global ns snk_ tcp_ cbr_ cluster_size svr_num prev_bytes
	global link_del_us tick seed qmon_interval flag_to_be_fin
	global Block_trans SRU_trans prev_bytes next_flowid kx
	global slow_start_period_us ssp_trans para_num cur_flow_num
	# 0.0001 = 100 us = 1 RTT
	set next_time 0.0001
	set now [$ns now]

	# check total traffic and each flow traffic
	set total_bytes 0
	for {set i 0} {$i < $svr_num} {incr i} {
		set total_bytes [expr $total_bytes + [$snk_($i) set bytes_]]

		# This flow has new data?
		if {$prev_bytes($i) < [$snk_($i) set bytes_]} {

		    # (a) If the flow will be finished in a few rtt,
			# it starts next flow. (only first time)
			if {[$snk_($i) set bytes_] >= \
                    (${SRU_trans} - ${ssp_trans} / ${para_num})
				&& $flag_to_be_fin($i) == 0 } {
				if {${next_flowid} < ${svr_num} \
                        && ${cur_flow_num} < ${para_num} * ${kx}} {
					send_syn $next_flowid $now
					incr next_flowid
					incr cur_flow_num
					set flag_to_be_fin($i) 1
					## (3)' Prepare Next Flow Multiplicity
					## When (1), (2) and (3), Following should be comment out.
					#set para_num 1
				}
			}

			# Is finish sending flow?
			if {[$snk_($i) set bytes_] >= ${SRU_trans}} {
				set cur_flow_num [expr ${cur_flow_num} - 1]
			}

			set prev_bytes($i) [$snk_($i) set bytes_]
		}
	}

    update_link_del

	# Is finished All Flow?
    if {$total_bytes >= $Block_trans} {
		flush stdout
		for {set i 0} {$i < $cluster_size} {incr i} {
			$ns at [expr $now + $next_time] "$cbr_($i) stop"
		}
		$ns at [expr $now + 0.2] "finish"
	} else {
		$ns at [expr $now + $next_time] "check_trans"
		for {set i 0} {$i < $next_time} {set i [expr $i + $qmon_interval]} {
			$ns at [expr $now + $i] "check_qlen"
		}
	}
}

proc debug {} {
    global ns
    set next_time 1.0
    set now [$ns now]
    puts -nonewline "$now."
    flush stdout
    $ns at [expr $now+$next_time] "debug"
}

#Run the simulation
$ns run
