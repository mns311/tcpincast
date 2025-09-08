/* -*-	Mode:C++; c-basic-offset:4; tab-width:4; indent-tabs-mode:t -*- */
/*
 * Copyright (c) 1997 Regents of the University of California.
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. All advertising materials mentioning features or use of this software
 *    must display the following acknowledgement:
 *	This product includes software developed by the Daedalus Research
 *	Group at the University of California Berkeley.
 * 4. Neither the name of the University nor of the Laboratory may be used
 *    to endorse or promote products derived from this software without
 *    specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 *
 * Contributed by the Daedalus Research Group, U.C.Berkeley
 * http://daedalus.cs.berkeley.edu
 *
 * @(#) $Header: 
 */

/*
 *   https://github.com/osada/sim-incast/
 */

#ifndef lint
static const char rcsid[] =
    "@(#) $Header: $";
#endif

#include <iostream>
#include "template.h"
#include "flags.h"
#include "tcp-sink.h"
#include "ip.h"
#include "hdr_qs.h"

#define ADVWND_MIN 2
// a parameter to absorb potential oversubscribed bandwidth (alpha)
#define ABSORB_P 1.0
#define LINK_CAPACITY_MBPS 1000
#define SMOOTH_BITS 3
// 1500 Byte
#define MSS 1500
// 100ns
#define TICK 0.0000001
#define GAMMA_1 0.1
#define GAMMA_2 0.5
#define AVAIL_THRESH 0.1
#define NONE 0x00
#define FIRST_SLOT 0x01
#define SECOND_SLOT 0x02
#define TCP_TIMER_IC 101
#define TCP_TIMER_GST 102
// 100us
#define RTT_INIT 0.0001

class TcpICSink;

class ICAckTimer : public TimerHandler {
public:
	ICAckTimer(TcpICSink *a) : TimerHandler() { a_ = a; }
protected:
	virtual void expire(Event *e);
	TcpICSink *a_;
};

class GlobalSlotTimer : public TimerHandler {
public:
	GlobalSlotTimer(TcpICSink *a) : TimerHandler() { a_ = a; }
protected:
	virtual void expire(Event *e);
	TcpICSink *a_;
};

class TcpICSink : public DelAckSink {
public:
	TcpICSink(Acker*);
	virtual void recv(Packet* pkt, Handler* h);
	virtual void timeout(int tno);
        virtual void reset();

protected:
	virtual void add_to_ack(Packet* pkt);
	void update_window();
	virtual void delay_bind_init_all();
	virtual int delay_bind_dispatch(const char *varName, 
					const char *localName,
					TclObject *tracer);

	double wnd_;  // -1: disable to control advertised window
	double reverse_rtt_; // unit = tcpTick_
	double sub_slot_T_;  // unit = tcpTick_
	double prev_bytes;
	double total_bytes_;
	double prev_total_bytes;
	double prev_update_time;
	double sbw_mbps;          // smoothed bandwidth
	int status;          // ICTCP Status

  	ICAckTimer ic_ack_timer_;
	GlobalSlotTimer global_slot_timer_;

};

static class TcpICSinkClass : public TclClass {
public:
	TcpICSinkClass() : TclClass("Agent/TCPSink/ICTCP") {}
	TclObject* create(int, const char*const*) {
		return (new TcpICSink(new Acker));
	}
} class_tcpicsink;

TcpICSink::TcpICSink(Acker* acker) : DelAckSink(acker),
	sbw_mbps(0.0), status(NONE), ic_ack_timer_(this), global_slot_timer_(this)
{
	// bind_time("ia_ack_interval_", &ia_ack_interval_);
	// bind("bytes_", &bytes_); // useby JOBS
	wnd_ = -1.0;
	bind("wnd_", &wnd_);
	total_bytes_ = 0.0;
	bind("total_bytes_", &total_bytes_);
	prev_total_bytes = 0.0;
	prev_update_time = 0.0;
	prev_bytes = 0.0;
	reverse_rtt_ = 0.0;
	bind("reverse_rtt_", &reverse_rtt_);
	sub_slot_T_ = 0.0;
	bind("sub_slot_T_", &sub_slot_T_);

}

void TcpICSink::delay_bind_init_all()
{
	delay_bind_init_one("wnd_");
	delay_bind_init_one("total_bytes_");
	delay_bind_init_one("reverse_rtt_");
	delay_bind_init_one("sub_slot_T_");
	TcpSink::delay_bind_init_all();
}

int TcpICSink::delay_bind_dispatch(const char *varName, 
				   const char *localName, TclObject *tracer)
{
        if (delay_bind(varName, localName, "wnd_", &wnd_, tracer)) return TCL_OK;
        if (delay_bind(varName, localName, "total_bytes_", &total_bytes_, tracer)) return TCL_OK;
        if (delay_bind(varName, localName, "reverse_rtt_", &reverse_rtt_, tracer)) return TCL_OK;
        if (delay_bind(varName, localName, "sub_slot_T_", &sub_slot_T_, tracer)) return TCL_OK;
        return TcpSink::delay_bind_dispatch(varName, localName, tracer);
}

void TcpICSink::update_window()
{
	double now = Scheduler::instance().clock();
	double bw_est_mbps = 0.0;
	double bw_msr_mbps = 0.0;
	double total_traffic_mbps = 0.0;
	double bw_avail_mbps = 0.0;
	double bw_diff = 0.0;

	// check if too small rtt or not
	if (reverse_rtt_ * TICK == 0) reverse_rtt_ = RTT_INIT;

	// Calculate Throuhput of this flow
 	if (now - prev_update_time == 0 || prev_update_time == 0) {
		//init bw_msr
		bw_msr_mbps = ((bytes_ - prev_bytes) / (reverse_rtt_ * TICK))
			* 8 / 1000 / 1000;
	}
	else {
		bw_msr_mbps = ((bytes_ - prev_bytes) / (now - prev_update_time))
			* 8 / 1000 / 1000;
	}

	if (sbw_mbps == 0) {
		// init sbw
		sbw_mbps = bw_msr_mbps;
	}
	else {
		sbw_mbps = max(bw_msr_mbps, (sbw_mbps * 7 + bw_msr_mbps) / 8);
	}

	bw_est_mbps = max(sbw_mbps, ((wnd_ * MSS) / (reverse_rtt_ * TICK))
					  * 8 / 1000 / 1000);

	// Calculate total traffic and available bandwidth
 	if (now - prev_update_time == 0  || prev_update_time == 0) {
		// init total_traffic
		total_traffic_mbps = ((total_bytes_ - prev_total_bytes) 
			/ (reverse_rtt_ * TICK)) * 8 / 1000 / 1000;
	}
	else {
	    total_traffic_mbps = ((total_bytes_ - prev_total_bytes)
			/ (now - prev_update_time)) * 8 / 1000 / 1000;
	}
	bw_avail_mbps = ABSORB_P * LINK_CAPACITY_MBPS - total_traffic_mbps;
	if (bw_avail_mbps < 0) bw_avail_mbps = 0;

	//  Get difference between bw_est and smoothed bandwidth
	bw_diff = (bw_est_mbps - sbw_mbps) / bw_est_mbps;

	// Adjust advertised window size
	if (bw_diff <= GAMMA_1 || bw_diff <= MSS / (wnd_ * MSS)) {
		if (status & SECOND_SLOT 
		    && bw_avail_mbps > AVAIL_THRESH * LINK_CAPACITY_MBPS )
			wnd_ = wnd_ + 1;
	}
	else if (bw_diff > GAMMA_2) {
		wnd_ = wnd_ - 1;
	}

	// Minimum check
	if (wnd_ < ADVWND_MIN) wnd_ = ADVWND_MIN;

// 	cout << now << ": diff=" << bw_diff
// 		 << ", wnd=" << wnd_
// 		 << " | msr=" << bw_msr_mbps
// 		 << ", sbw=" << sbw_mbps
// 		 << ", est=" << bw_est_mbps
// 		 << ", avail=" << bw_avail_mbps 
// 		 << ", tt=" <<total_traffic_mbps << "\n";

	prev_update_time = now;
	prev_total_bytes = total_bytes_;
	prev_bytes = bytes_;

	ic_ack_timer_.resched(reverse_rtt_ * TICK);
}

/* Add fields to the ack. */
void TcpICSink::add_to_ack(Packet* pkt) 
{
	hdr_tcp *th = hdr_tcp::access(pkt);
	double now = Scheduler::instance().clock();

	// set advertised window size
	th->wnd() = wnd_;

	if (ic_ack_timer_.status() != TIMER_PENDING) {
		prev_total_bytes = total_bytes_;
		prev_update_time = now;
		ic_ack_timer_.resched(RTT_INIT);
	}
	if (global_slot_timer_.status() != TIMER_PENDING) {
		global_slot_timer_.resched(RTT_INIT);
	}

	// debug
// 	cout << now << ": C snd ack -> win " << wnd_ 
// 	     << ", total_bytes_: " << total_bytes_ 
// 	     << ", r_rtt_: " << reverse_rtt_ 
// 	     << ", T_: " << sub_slot_T_ << "\n";
}

void TcpICSink::recv(Packet* pkt, Handler*) 
{
	int numToDeliver;
	int numBytes = hdr_cmn::access(pkt)->size();
	hdr_tcp *th = hdr_tcp::access(pkt);
	/* W.N. Check if packet is from previous incarnation */
	if (th->ts() < lastreset_) {
		// Remove packet and do nothing
		Packet::free(pkt);
		return;
	}
	acker_->update_ts(th->seqno(),th->ts(),ts_echo_rfc1323_);
	// next_ is also updated in update()
	numToDeliver = acker_->update(th->seqno(), numBytes);
	if (numToDeliver) {
		bytes_ += numToDeliver; // for JOBS
		recvBytes(numToDeliver);
	}
	
	// If there's no timer and the packet is in sequence, set a timer.
	// Otherwise, send the ack and update the timer.
	if (delay_timer_.status() != TIMER_PENDING &&
		th->seqno() == acker_->Seqno()) {
		// There's no timer, so we can set one and choose
		// to delay this ack.
		// If we're following RFC2581 (section 4.2) exactly,
		// we should only delay the ACK if we're know we're
		// not doing recovery, i.e. not gap-filling.
		// Since this is a change to previous ns behaviour,
		// it's controlled by an optional bound flag.
		// discussed April 2000 in the ns-users list archives.
		if (RFC2581_immediate_ack_ && 
			(th->seqno() < acker_->Maxseen())) {
			// don't delay the ACK since
			// we're filling in a gap
		} else if (SYN_immediate_ack_ && (th->seqno() == 0)) {
			// don't delay the ACK since
			// we should respond to the connection-setup
			// SYN immediately
		} else {
			// delay the ACK and start the timer.
			save_ = pkt;
			delay_timer_.resched(interval_);
			return;
		}
	}
	// If there was a timer, turn it off.
	if (delay_timer_.status() == TIMER_PENDING) 
		delay_timer_.cancel();
	ack(pkt);
	if (save_ != NULL) {
		Packet::free(save_);
		save_ = NULL;
	}
	
	Packet::free(pkt);
}


void TcpICSink::timeout(int tno)
{
	Packet* pkt = 0;
	switch (tno) {
	case 0:
	case TCP_TIMER_DELACK:
		/*
		 * The timer expired so we ACK the last packet seen.
		 * tno == 0 always means DelAckTimeout
		 * since superclass is written so.
		 */
		pkt = save_;
		ack(pkt);
		save_ = 0;
		Packet::free(pkt);
		break;
	case TCP_TIMER_IC:
		// Shigeyuki Osada 2012/1/19
		update_window();
		break;
    case TCP_TIMER_GST:
// 		cout << Scheduler::instance().clock()
// 			 << ": old_status = " << status;
		if (status == NONE) status = FIRST_SLOT;
		else if (status & FIRST_SLOT) status = SECOND_SLOT;
		else if (status & SECOND_SLOT) status = FIRST_SLOT;
		global_slot_timer_.resched(sub_slot_T_ * TICK);
//  		cout << ", new_status = " << status << ", T="
// 			 << sub_slot_T_ * TICK << "\n";
		break;
	default:
		break;
	}
}

void TcpICSink::reset()
{
    if (delay_timer_.status() == TIMER_PENDING)
        delay_timer_.cancel();
    if (ic_ack_timer_.status() == TIMER_PENDING)
		ic_ack_timer_.cancel();
    if (global_slot_timer_.status() == TIMER_PENDING)
		global_slot_timer_.cancel();
    TcpSink::reset();
}


void ICAckTimer::expire(Event* /*e*/) {
	a_->timeout(TCP_TIMER_IC);
}

void GlobalSlotTimer::expire(Event* /*e*/) {
	a_->timeout(TCP_TIMER_GST);
}
