# Version Desctiption
set version "Incast Simulation / FullTCP v.1 (ppt v.107)"

# Check Args Format
if {$argc != 9} {
  puts -nonewline "Usage: ns incast <actsrv-num> <advwnd-pkt> "
  puts -nonewline "<SRU-KB> <link_buf-pkt> <rto_min-ms> "
  puts "<mb:e_buf_max-pkt> <mb:e_hop_max-num> <mb:e_bw-Gbps> <seed>"
  exit 1
}

puts "--- ${version} ---"

#################################################################
# Argments
# ActiveServerNum: $argv(0)
set actsvr_num [lindex $argv 0]
# Advertised Window size (pkt): $argv(1)
set adv_wnd [lindex $argv 1]
# SRU Size (Byte) ... only Payload: $argv(2)
set SRU [expr [lindex $argv 2] * 1024]
# Link Buffer (pkt): $argv(3)
set link_buf [lindex $argv 3]
# RTOmin (ms): $argv(4) ... default TCP is 200ms
set rtomin_ms [lindex $argv 4]
# Estimated Link Buffer Max in the NW: $argv(5)
set e_bufmax_pkt [lindex $argv 5]
# Estimated Hop Max in the NW: $argv(6)
set e_hopmax_num [lindex $argv 6]
# Estimated Link Speed: $argv(7)
set e_bw_Gbps [lindex $argv 7]
# Random Seed: $argv(8)
set seed [lindex $argv 8]

#############################################################
## NCCSの制御変数を追加
## kx: 最大同時接続数を決めるための係数
set kx 128
## para_num: 初期に通信を開始するフロー数
set para_num 128
#############################################################

################################################################
# Variables
# Create a simulator object
set ns [new Simulator]

###############################################################
## Network Definition
## Bandwidth (Gbps)
set bw_Gbps 10

## Cluster Size (max server num)
set cluster_size 1024

## Link Delay (us) where exists 1 switch
set link_del_us [expr (100 - \
		(2 * 1500 * 8 / (${bw_Gbps} * pow(10,9)) ) * pow(10,6) ) / 4]

## Background Traffic
set bgt_pkt_byte 1500
## ratio to Bandwidth (0.01 means 1Gbps * 0.01 = 10Mbps)
set bgt_total_rate 0.01

# Link Error Rate (Unit:pkt) 0.001 = 0.1% (a loss in 1000 pkt)
# set err_rate 0.001
set err_rate 0

# Base RTT : Propagation Delay and Transmission Delay of a Packet
#            where there is not any others packet. (across 2 nodes)
set base_RTT_us [expr ${link_del_us} * 4 + 2 * 1500 * 8 \
					 / (${bw_Gbps} * pow(10, 9)) * pow(10, 6)]
#puts "linkdel = ${link_del_us}us, x6 = [expr 6 * ${link_del_us}]us"


# Base BDP
set base_BDP_byte [expr ${base_RTT_us} * pow(10, -6) \
                        * ${bw_Gbps} * pow(10, 9) / 8]
set base_BDP_pkt [expr ${base_BDP_byte} / 1500]


# The number of packets of SRU
set SRU_pkt [expr ceil(${SRU}/1460.)]

# Total Size of All Servers SRU with TCP/IP Header and Handshake
set SRU_trans [expr (int($SRU / 1460) + 1) * 1500 + 40]
set Block_trans [expr ${SRU_trans} * ${actsvr_num}]

# Total size of all servers SRU without TCP/IP header and handshake
# but include one byte for SYN
set Block_bytes [expr (${SRU} + 1) * ${actsvr_num}]


## Decide RTO backoff type
## 1: Exponential backoff (default TCP)
## 2: Liner backoff
## 3: RTOdc backoff
Agent/TCP set bo_type_ 1 ;# (default 1)

## derive maxbackoff (2015/12/12)
# Case 1: Do nothing
set maxbackoff 64 ;# default

# Case 2: Optimized (only when smaller rtomin  timer is used)
set buf_del_max_ms [expr ${e_bufmax_pkt} * 1500 * 8 * ${e_hopmax_num} \
					 / (${e_bw_Gbps} * pow(10, 9)) * pow(10, 3)]

## 2016.4.3 Osada (RTOdc)
set rtodc_ms [expr ${buf_del_max_ms} + ${base_RTT_us} / pow(10, 3)]
puts "rtodc: ${rtodc_ms}ms"


if {${rtomin_ms} < 10} {
#	## 2016.3.20 Osada (RTOmax)
#	set rtomax_ms [expr ${buf_del_max_ms} + ${base_RTT_us} / pow(10, 3)]
#	puts "rtomax: ${rtomax_ms}ms"
#	Agent/TCP set maxrto_ [expr $rtomax_ms / pow(10, 3)] ; # (default 60 sec)

#	set maxbackoff [expr ceil(($base_RTT_us + $buf_del_max_ms * pow(10, 3)) \
#				     / max($base_RTT_us, $rtomin_ms * pow(10, 3)))]
#
## 2015.12.24 Osada (Normalizing)
#	if {$maxbackoff > 32} {
#		set maxbackoff 64
#	} elseif {$maxbackoff > 16} {
#		set maxbackoff 32
#	} elseif {$maxbackoff > 8} {
#		set maxbackoff 16
#	} elseif {$maxbackoff > 4} {
#		set maxbackoff 8
#	} elseif {$maxbackoff > 2} {
#		set maxbackoff 4
#	} elseif {$maxbackoff > 1} {
#		set maxbackoff 2
#	} else {
#		set maxbackoff 1
#	}
#
}


########################################################################
## Application Definition
## Barrier Synchronized Application (BSApp)class
Class BSApp
## Constructor
BSApp instproc init {args} {
	$self set id 0
	$self set c_node 0
	$self set actsvr_num 0
	
	# is_finをis_app_finに名前変更
	$self set is_app_fin 0

	# --- NCCSから以下の状態管理変数を追加 ---
	$self set next_syn_flowid 0
	$self set next_flowid 0
	$self set cur_flow_num 0
	# ------------------------------------

	# --- AHTCPのGoodput計算用変数はそのまま ---
	$self set prev_total_bytes 0
	$self set prev_time 1
    $self set gp_(0) -1
    $self set gp_(1) -1
    $self set gp_(2) -1
    $self set gp_(3) -1
    $self set gp_(4) -1
    $self set gp_max -1
    $self set gp_avg -1
    $self set gp_avg_max -1
    $self set locktime 0
}

## Print Status for BSApp
BSApp instproc print {} {
	puts "$id\t |[llength $sendq_]| = $sendq_"
}

#############################################
# Constants / Global Variable
set tick [expr pow(10, -7)]         ;    # 100ns
set qmon_interval [expr pow(10, -4)];    # 100us
Agent/TCP set trace_all_oneline_ true
Agent/TCP/FullTcp set segsize_ 1460
Agent/TCP/FullTcp set interval_ 0      ; # Delayed ACK interval: fedault 0.1 (100ms)
Agent/TCP/FullTcp set debug_ false;      # Added Sept. 16, 2007.
Agent/TCP/FullTcp set nodelay_ false;    # Nagle disable? (default: false)
Agent/TCP/FullTcp set segsperack_ true;  # (default: false)
Agent/TCP/FullTcp set sru_bytes_ ${SRU}
Agent/TCP/FullTcp set base_rtt_ [expr $base_RTT_us / pow(10, 6)] ; # (default 100us)
Agent/TCP set dcrto_ [expr $rtodc_ms / pow(10, 3)] ; # (default 60 sec)


# should be used with timestamp option
set is_ha true
Agent/TCP/FullTcp set is_ha_ $is_ha;     # default: false
Agent/TCP set timestamps_ true;        # default: false
Agent/TCP set ts_resetRTO_ true ;	     # default: false
					# Set to true to **back-off** RTO
					#   after any valid RTT measurement (with timestamp)
Agent/TCP/FullTcp set ts_option_size_ 0; # in bytes (default: 10)

# Use RTXREQ option (osada)
set is_rtxreq false
Agent/TCP/FullTcp set is_rtxreq_ $is_rtxreq;     # (default: false)

Agent/TCP set tcpTick_ $tick             ; # 100ns (default 0.01: 10ms)
Agent/TCP set minrto_ [expr $rtomin_ms * pow(10, -3)] ; # (default 0.2: 200ms)


# Agent/TCP set maxbackoff_ $maxbackoff    ; # (default 64)

# set is_randomrto false
# Agent/TCP set is_randomrto_ $is_randomrto ; # (default false)

Queue/DropTail set queue_in_bytes_ true  ; # Default false
Queue/DropTail set mean_pktsize_ 1500    ; # Default 500

Trace set show_tcphdr_ 1; # trace-all shows tcp headers(default: 0)

set app_num 1                            ; # the number of BSApps

#############################################
# Random Model
# defaultRNG can effect C++ world.
global defaultRNG
$defaultRNG seed [expr ${seed} * ${actsvr_num} + 1]
set rng [new RNG]
# seed 0 equal to current OS time (UTC)
# so seed should be more than 1 for repeatability
$rng seed [expr ${seed} * ${actsvr_num} + 1]

expr srand (${seed})
##############################################
# Tracing Message (Optional)
puts -nonewline "ActServer: $actsvr_num, adv_wnd: ${adv_wnd}pkt, "
puts "SRU: ${SRU}B, link_buf: ${link_buf}pkt, "
puts -nonewline "RTOmin: ${rtomin_ms}ms, BaseRTT: ${base_RTT_us}us, "
puts "BaseBDP: ${base_BDP_pkt}pkt, Seed: $seed"
puts -nonewline "e_bufmax: ${e_bufmax_pkt}pkt, e_hopmax: ${e_hopmax_num}, "
puts "e_bw: ${e_bw_Gbps}Gbps"
puts "maxbackoff: ${maxbackoff}, buf_del_max: ${buf_del_max_ms}ms"

##############################################
# Check Integrity of variables
if {${actsvr_num} > ${cluster_size}} {
	puts "Error: Too many servers (MAX: ${cluster_size})"
	exit 1
}
# Because of goodput calculation program (gp.c)
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
## Send SYN Packet
BSApp instproc send_syn {index time} {
	global ns base_RTT_us SRU svr_type_ cluster_size
	$self instvar id ftp_ actsvr_num
	$ns at [expr $time + ${base_RTT_us} * pow(10, -6) / 2] \
		"[$self set ftp_($index)] send $SRU"
#	puts -nonewline "time: [expr $time + ${base_RTT_us} * pow(10, -6) / 2]"
#	puts -nonewline " | send [expr $index + $id * $actsvr_num] | app_($id) -> "
#	puts "$svr_type_([expr ($index + $id * $actsvr_num) % $cluster_size])"
}

## Send SYN Packet belonging to the application
# 次のSYNパケットを送信する
BSApp instproc send_next_syn {time} {
	global ns SRU base_RTT_us
	$self instvar ftp_ actsvr_num next_syn_flowid

	if {${next_syn_flowid} < ${actsvr_num}} {
		$ns at [expr $time + ${base_RTT_us} * pow(10, -6) / 2] \
			"[$self set ftp_($next_syn_flowid)] send $SRU"
		incr next_syn_flowid
	}
}

# 次のフローをアクティブ化（データ送信を許可）する
BSApp instproc change_next_active_state {} {
	$self instvar next_flowid snk_ id # tcp_ではなくsnk_を参照
	global ns

    # 受信側(snk)をアクティブ化し、送信許可を出す
	$snk_($next_flowid) active 1
	
	puts "Time: [$ns now] App($id):Flow($next_flowid) become active (start sending data)"
	incr next_flowid
}

##########################################
## Attach TCP Agent to an application
BSApp instproc set_actsvr {actsvr_num_in} {
	global ns tf adv_wnd n_ cluster_size svr_type_ 
	$self instvar actsvr_num id c_node 
	$self instvar tcp_ snk_ ftp_

	set actsvr_num $actsvr_num_in
	puts -nonewline "appid ($id) set active servers..."

	for {set i 0} {$i < $actsvr_num} {incr i} {
		set tcp_($i) [new Agent/TCP/FullTcp/Newreno]
		$tcp_($i) set fid_ [expr $i + $id * $actsvr_num]
		$tcp_($i) set window_ ${adv_wnd}
		$tcp_($i) attach-trace $tf
		$tcp_($i) trace maxseq_
		$tcp_($i) trace ack_
		set ftp_($i) [new Application/FTP]
		$ftp_($i) attach-agent $tcp_($i)
		$ftp_($i) set type_ FTP
		## Decide server
		$ns attach-agent \
			$n_([expr ($i + $id * $actsvr_num) % ${cluster_size}]) $tcp_($i)
		# puts -nonewline "flowid [expr $i + $id * $actsvr_num] on cluster "
		# puts "$svr_type_([expr ($i + $id * $actsvr_num) % ${cluster_size}])"
		set snk_($i) [new Agent/TCP/FullTcp/IAFull]
        $snk_($i) set advwnd_ia_ $adv_wnd
        $snk_($i) active 0
        
		$ns attach-agent $c_node $snk_($i)
		$snk_($i) set fid_ [expr $i + $id * $actsvr_num]

		#$self print

		$ns connect $tcp_($i) $snk_($i)
		$snk_($i) listen
	}

	puts "done"
}


##############################################
## Create Switchs
set nx   [$ns node]            ;# Nodeid = 0

#############################################
## Create Clients
for {set i 0} {$i < $app_num} {incr i} {
	set nc_($i) [$ns node]     ;# Nodeid = 1 -- ${app_num}

	## Connecting and Setting LinkBuf of Clients
	$ns duplex-link $nx $nc_($i) ${bw_Gbps}Gb ${link_del_us}us DropTail
	$ns queue-limit $nx $nc_($i) ${link_buf}   ;# This is a bottleNeck
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
puts -nonewline "shuffle node..."
flush stdout
set svr_labels [shuffle $svr_labels]
puts "done"

## Create Server Nodes and Set Background Traffic
puts -nonewline "set node..."
flush stdout

for {set i 0} {$i < $cluster_size} {incr i} {
  set n_($i) [$ns node]
	set svr_label [lindex $svr_labels $i]
	$ns duplex-link $nx $n_($i) ${bw_Gbps}Gb ${link_del_us}us DropTail
	$ns queue-limit $n_($i) $nx 10000

	## For debug
	#puts "node $i is of cluster $svr_type_($i)"

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

puts "done"

## Create applications
for {set app_i 0} {$app_i < $app_num} {incr app_i} {
	set app_($app_i) [new BSApp]
	$app_($app_i) set id $app_i

	## Attach the application to the client node
	$app_($app_i) set c_node $nc_($app_i)

	## Set Servers and Create Flows belonging to the application
	$app_($app_i) set_actsvr $actsvr_num
}

## Start TCP Traffic (at least one flow per applications and clusters)
for {set i 0} {$i < $app_num} {incr i} {
    # NCCS方式で、最初のフローを開始する
	for {set j 0} {$j < $para_num && $j < $actsvr_num} {incr j} {
		$app_($i) send_next_syn 1.0
		$app_($i) change_next_active_state
		$app_($i) set cur_flow_num [expr [$app_($i) set cur_flow_num] + 1]
	}
}



$ns at 0.0 "debug"
$ns at 1.0 "check_trans"
#$ns at 21.0 "finish"

####################################################################
## for Queue Monitoring
set qmon [$ns monitor-queue $nx $nc_(0) [open qm.out w] ${qmon_interval}]
[$ns link $nx $nc_(0)] queue-sample-timeout

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
# ahtcp.A.tcl の BSApp instproc check を以下に置き換える

BSApp instproc check {} {
	global ns Block_bytes SRU is_ha is_rtxreq para_num kx
	$self instvar actsvr_num snk_ is_app_fin id tcp_
	$self instvar prev_time prev_total_bytes gp_ gp_max gp_avg gp_avg_max locktime
	$self instvar next_flowid cur_flow_num next_syn_flowid is_flow_fin_

	set interval_us 1000
	set now [$ns now]
	set total_bytes 0
    set SRU_trans [expr (int($SRU / 1460) + 1) * 1500 + 40]

	for {set i 0} {$i < $actsvr_num} {incr i} {
		set rcvd_bytes [$snk_($i) set rcv_nxt_]
		set total_bytes [expr $total_bytes + $rcvd_bytes]
		if {![info exists is_flow_fin_($i)]} { set is_flow_fin_($i) 0 }

        ## --- NCCSサーバー数制御ロジック ---
		# 1. SYN-ACK受信後、次のSYNを送信
		if {${i} == ${next_syn_flowid} - 1 && ${rcvd_bytes} >= 1 && ${next_syn_flowid} < ${actsvr_num}} {
			$self send_next_syn $now
		}

		# 2. フロー進捗後、上限まで次のフローをアクティブ化
		if {$is_flow_fin_($i) == 0 && ${rcvd_bytes} >= ${SRU_trans} / 2} {
			if {${next_flowid} < ${actsvr_num} && ${cur_flow_num} < ${kx}} {
				$self change_next_active_state
				incr cur_flow_num
				set is_flow_fin_($i) 1 ;# このフローからの再トリガーを防ぐ
			}
		}

		# 3. フロー完了後、アクティブ数を減算
        if {${rcvd_bytes} >= ${SRU_trans}} {
            # is_counted_fin_ という完了フラグをチェック
            if {![info exists is_counted_fin_($i)]} {
                set is_counted_fin_($i) 1 ; # 完了フラグを立てる
                incr cur_flow_num -1
            }
        }
	}

    ## --- AHTCP Goodput監視ロジック (変更なし) ---
	if {($is_ha == true || $is_rtxreq == true ) && $now > $prev_time + $interval_us * pow(10, -6) } {
        # スループットがゼロの場合の処理
        if { $now > $locktime && $gp_(0) == 0} {
            puts -nonewline "\n$now: Goodput is 0. Re-sending active 1 to unlock sender.\n"
            for {set i 0} {$i < $actsvr_num} {incr i} {
                # 止まっている可能性のあるフロー全てに対して再度送信許可を出す
                $snk_($i) active 1
            }
            set locktime [expr $now + $interval_us * 3 * pow(10, -6)]
        # スループットがゼロではないが、性能が低下した場合の処理
        } elseif {$now > $locktime && $gp_avg < $gp_avg_max * 0.25} {
            for {set i 0} {$i < $actsvr_num} {incr i} {
                set rcvd_bytes [$snk_($i) set rcv_nxt_]
                if {$rcvd_bytes < $SRU} {
                    # こちらは従来通りデータロスを疑い、req-rtxを呼び出す
                    $snk_($i) req-rtx
                }
            }
            set locktime [expr $now + $interval_us * 3 * pow(10, -6)]
            set gp_max $gp_avg
            set gp_avg_max -1
        }
		set prev_total_bytes $total_bytes
		set prev_time $now
	}

	## --- アプリケーション全体の完了チェック ---
	if {$total_bytes >= $Block_bytes && $is_app_fin == 0} {
		set is_app_fin 1
		puts "time: [$ns now] app($id) is finished."
	}
}


## Global
proc check_trans {} {
    global ns cbr_ cluster_size app_ app_num qmon_interval

    set next_time [expr 20 * pow(10, -6)]
    set now [$ns now]
    # ローカル変数の名前を is_all_apps_finished に変更（推奨）
    set is_all_apps_finished 1  ;# ON

    # check all application's traffic only where there are alive
    for {set i 0} {$i < $app_num} {incr i} {
        # check if the flow has outstanding data
        # ↓ BSAppオブジェクトから読み出す変数名を is_app_fin に修正
        if {[$app_($i) set is_app_fin] == 0} {
            $app_($i) check
            # ローカル変数の名前を is_all_apps_finished に変更
            set is_all_apps_finished 0
        }
    }

    # if all application is finished, stop the simulation after 0.1ms
    # else it prepares next checking
    # ↓ ローカル変数の名前を is_all_apps_finished に変更
    if {$is_all_apps_finished == 1} {
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
puts "run..."
$ns run
