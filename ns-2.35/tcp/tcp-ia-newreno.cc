// 2013/10/28 kajita

#ifndef lint
static const char rcsid[] =
    "@(#) $Header: $";
#endif

#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <iostream>

#include "packet.h"
#include "ip.h"
#include "tcp.h"
#include "flags.h"

#include "random.h"

class IANewRenoTcpAgent : public virtual NewRenoTcpAgent {
 public:
	IANewRenoTcpAgent();
	virtual void delay_bind_init_all();
	virtual int delay_bind_dispatch(const char *varName, const char *localName, TclObject *tracer);
	virtual void send_much(int force, int reason, int maxburst = 0);
	virtual void recv_helper(Packet* pkt);
	virtual void newack(Packet* pkt);
	virtual void recv(Packet *pkt, Handler*);
 protected:
	int maxdupsyn_; // maximum number of duplicate SYNs
	int wnd_update_wait;
};

static class IANewRenoTcpClass : public TclClass {
public:
	IANewRenoTcpClass() : TclClass("Agent/TCP/IANewreno") {}
	TclObject* create(int, const char*const*) {
		return (new IANewRenoTcpAgent());
	}
} class_icnewreno;

IANewRenoTcpAgent::IANewRenoTcpAgent()
{
	bind("maxdupsyn_", &maxdupsyn_);
	wnd_update_wait = 0;
}

void IANewRenoTcpAgent::delay_bind_init_all()
{
	delay_bind_init_one("maxdupsyn_");

	NewRenoTcpAgent::delay_bind_init_all();
}

int IANewRenoTcpAgent::delay_bind_dispatch(const char *varName, const char *localName, TclObject *tracer)
{
	if (delay_bind(varName, localName, "maxdupsyn_", &maxdupsyn_, tracer)) return TCL_OK;

        return NewRenoTcpAgent::delay_bind_dispatch(varName, localName, tracer);
}

/*
 * Try to send as much data as the window will allow.  The link layer will 
 * do the buffering; we ask the application layer for the size of the packets.
 */
void IANewRenoTcpAgent::send_much(int force, int reason, int maxburst)
{
	send_idle_helper();
	int win = window();
	int npackets = 0;

	if (!force && delsnd_timer_.status() == TIMER_PENDING)
		return;
	/* Save time when first packet was sent, for newreno  --Allman */
	if (t_seqno_ == 0)
		firstsent_ = Scheduler::instance().clock();

	if (burstsnd_timer_.status() == TIMER_PENDING)
		return;
	while (t_seqno_ <= highest_ack_ + win && t_seqno_ < curseq_) {
		if (overhead_ == 0 || force || qs_approved_) {

			// kajita
			if (t_seqno_ == 0) {
				int count;
				for (count = 0; count < maxdupsyn_; ++count) {
					output(t_seqno_, reason);
				}
			} else {
				output(t_seqno_, reason);
			}

			npackets++;
			if (QOption_)
				process_qoption_after_send () ; 
			t_seqno_ ++ ;
			if (qs_approved_ == 1) {
				// delay = effective RTT / window
				double delay = (double) t_rtt_ * tcp_tick_ / win;
				if (overhead_) { 
					delsnd_timer_.resched(delay + Random::uniform(overhead_));
				} else {
					delsnd_timer_.resched(delay);
				}
				return;
			}
		} else if (!(delsnd_timer_.status() == TIMER_PENDING)) {
			/*
			 * Set a delayed send timeout.
			 */
			delsnd_timer_.resched(Random::uniform(overhead_));
			return;
		}
		win = window();
		if (maxburst && npackets == maxburst)
			break;
	}
	/* call helper function */
	send_helper(maxburst);
}

void IANewRenoTcpAgent::recv_helper(Packet* pkt)
{
	hdr_tcp *tcph = hdr_tcp::access(pkt);

	if (tcph->wnd() >= 0) {
		wnd_ = tcph->wnd();
	}
	return;
}

/*
 * Process a packet that acks previously unacknowleged data.
 */
void IANewRenoTcpAgent::newack(Packet* pkt)
{
 	double now = Scheduler::instance().clock();
	hdr_tcp *tcph = hdr_tcp::access(pkt);

	/* 
	 * Wouldn't it be better to set the timer *after*
	 * updating the RTT, instead of *before*? 
	 */
	if (!timerfix_) newtimer(pkt);
	dupacks_ = 0;
	last_ack_ = tcph->seqno();
	prev_highest_ack_ = highest_ack_ ;
	highest_ack_ = last_ack_;
		if (t_seqno_ < last_ack_ + 1)
		t_seqno_ = last_ack_ + 1;

	// kajita
	if (wnd_update_wait == 1) {
		wnd_update_wait = 0;
	} else {
		/* 
		 * Update RTT only if it's OK to do so from info in the flags header.
		 * This is needed for protocols in which intermediate agents
		 * in the network intersperse acks (e.g., ack-reconstructors) for
		 * various reasons (without violating e2e semantics).
		 */
		hdr_flags *fh = hdr_flags::access(pkt);
		if (!fh->no_ts_) {
			if (ts_option_) {
				ts_echo_=tcph->ts_echo();		
				rtt_update(now - tcph->ts_echo());
				if (ts_resetRTO_ && (!ect_ || !ecn_backoff_ ||
				    !hdr_flags::access(pkt)->ecnecho())) { 
					// From Andrei Gurtov
					/* 
					 * Don't end backoff if still in ECN-Echo with
				 	 * a congestion window of 1 packet. 
					 */
					t_backoff_ = 1;
					ecn_backoff_ = 0;
				}
			}
			if (rtt_active_ && tcph->seqno() >= rtt_seq_) {
				if (!ect_ || !ecn_backoff_ || 
					!hdr_flags::access(pkt)->ecnecho()) {
					/* 
					 * Don't end backoff if still in ECN-Echo with
				 	 * a congestion window of 1 packet. 
					 */
					t_backoff_ = 1;
					ecn_backoff_ = 0;
				}
				rtt_active_ = 0;
				if (!ts_option_)
					rtt_update(now - rtt_ts_);
			}
		}
	}

	if (timerfix_) newtimer(pkt);
	/* update average window */
	awnd_ *= 1.0 - wnd_th_;
	awnd_ += wnd_th_ * cwnd_;
}

void IANewRenoTcpAgent::recv(Packet *pkt, Handler*)
{
	hdr_tcp *tcph = hdr_tcp::access(pkt);
	int valid_ack = 0;

	// kajita
	double now = Scheduler::instance().clock();
	if (tcph->wnd() == 0) {
		if (wnd_update_wait == 0) {
			wnd_update_wait = 1;
			/* 
			 * Update RTT only if it's OK to do so from info in the flags header.
			 * This is needed for protocols in which intermediate agents
			 * in the network intersperse acks (e.g., ack-reconstructors) for
			 * various reasons (without violating e2e semantics).
			 */
			hdr_flags *fh = hdr_flags::access(pkt);
			if (!fh->no_ts_) {
				if (ts_option_) {
					ts_echo_=tcph->ts_echo();
					rtt_update(now - tcph->ts_echo());
					if (ts_resetRTO_ && (!ect_ || !ecn_backoff_ ||
					    !hdr_flags::access(pkt)->ecnecho())) { 
						// From Andrei Gurtov
						/* 
						 * Don't end backoff if still in ECN-Echo with
					 	 * a congestion window of 1 packet. 
						 */
						t_backoff_ = 1;
						ecn_backoff_ = 0;
					}
				}
				if (rtt_active_ && tcph->seqno() >= rtt_seq_) {
					if (!ect_ || !ecn_backoff_ || 
						!hdr_flags::access(pkt)->ecnecho()) {
						/* 
						 * Don't end backoff if still in ECN-Echo with
					 	 * a congestion window of 1 packet. 
						 */
						t_backoff_ = 1;
						ecn_backoff_ = 0;
					}
					rtt_active_ = 0;
					if (!ts_option_)
						rtt_update(now - rtt_ts_);
				}
			}
		}
		cancel_rtx_timer();
		Packet::free(pkt);
		return;
	}

	/* Use first packet to calculate the RTT  --contributed by Allman */

        if (qs_approved_ == 1 && tcph->seqno() > last_ack_)
		endQuickStart();
        if (qs_requested_ == 1)
                processQuickStart(pkt);
	if (++acked_ == 1) 
		basertt_ = Scheduler::instance().clock() - firstsent_;


	/* Estimate ssthresh based on the calculated RTT and the estimated
	   bandwidth (using ACKs 2 and 3).  */

	else if (acked_ == 2)
		ack2_ = Scheduler::instance().clock();
	else if (acked_ == 3) {
		ack3_ = Scheduler::instance().clock();
		if (ack3_ == ack2_) ack2_ -= 0.00001; // which is RTT_est
		new_ssthresh_ = int((basertt_ * (size_ / (ack3_ - ack2_))) / size_);
		if (newreno_changes_ > 0 && new_ssthresh_ < ssthresh_)
			ssthresh_ = new_ssthresh_;
	}

#ifdef notdef
	if (pkt->type_ != PT_ACK) {
		fprintf(stderr,
			"ns: confiuration error: tcp received non-ack\n");
		exit(1);
	}
#endif
        /* W.N.: check if this is from a previous incarnation */
        if (tcph->ts() < lastreset_) {
                // Remove packet and do nothing
                Packet::free(pkt);
                return;
        }
	++nackpack_;
	ts_peer_ = tcph->ts();

	if (hdr_flags::access(pkt)->ecnecho() && ecn_)
		ecn(tcph->seqno());
	recv_helper(pkt);
	recv_frto_helper(pkt);
	if (tcph->seqno() > last_ack_) {
		if (tcph->seqno() >= recover_ 
		    || (last_cwnd_action_ != CWND_ACTION_DUPACK)) {
			if (dupwnd_ > 0) {
			     dupwnd_ = 0;
			     if (last_cwnd_action_ == CWND_ACTION_DUPACK)
				last_cwnd_action_ = CWND_ACTION_EXITED;
			     if (exit_recovery_fix_) {
				int outstanding = maxseq_ - tcph->seqno() + 1;
				if (ssthresh_ < outstanding)
                                        cwnd_ = ssthresh_;
                                else
                                        cwnd_ = outstanding;
			    }
			}
			firstpartial_ = 0;
			recv_newack_helper(pkt);
			if (last_ack_ == 0 && delay_growth_) {
				cwnd_ = initial_window();
			}
		} else {
			/* received new ack for a packet sent during Fast
			 *  Recovery, but sender stays in Fast Recovery */
			if (partial_window_deflation_ == 0)
				dupwnd_ = 0;
			partialnewack_helper(pkt);
		}
	} else if (tcph->seqno() == last_ack_) {
		if (hdr_flags::access(pkt)->eln_ && eln_) {
			tcp_eln(pkt);
			return;
		}
		if (++dupacks_ == numdupacks_) {
			dupack_action();
                        if (!exitFastRetrans_)
                                dupwnd_ = numdupacks_;
		} else if (dupacks_ > numdupacks_ && (!exitFastRetrans_
		      || last_cwnd_action_ == CWND_ACTION_DUPACK)) {
			trace_event("NEWRENO_FAST_RECOVERY");
			++dupwnd_;	// fast recovery

			/* For every two duplicate ACKs we receive (in the
			 * "fast retransmit phase"), send one entirely new
			 * data packet "to keep the flywheel going".  --Allman
			 */
			if (newreno_changes_ > 0 && (dupacks_ % 2) == 1)
				output (t_seqno_++,0);
		} else if (dupacks_ < numdupacks_ && singledup_ ) {
                        send_one();
                }
	}
        if (tcph->seqno() >= last_ack_)
                // Check if ACK is valid.  Suggestion by Mark Allman.
                valid_ack = 1;
	Packet::free(pkt);
#ifdef notyet
	if (trace_)
		plot();
#endif

	/*
	 * Try to send more data
	 */

        if (valid_ack || aggressive_maxburst_)
	{
		if (dupacks_ == 0) 
		{
			/*
			 * Maxburst is really only needed for the first
			 *  window of data on exiting Fast Recovery.
			 */
			send_much(0, 0, maxburst_);
		}
		else if (dupacks_ > numdupacks_ - 1 && newreno_changes_ == 0)
		{
			send_much(0, 0, 2);
		}
	}

}

