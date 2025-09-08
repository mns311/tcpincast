// 2013/10/28 kajita

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

class TcpIASink;

class TcpIASink : public TcpSink {
 public:
	TcpIASink(Acker* acker);
	virtual void delay_bind_init_all();
	virtual int delay_bind_dispatch(const char *varName, const char *localName, TclObject *tracer);
	virtual int command(int argc, const char*const* argv);
	virtual void add_to_ack(Packet* pkt);
 protected:
	double advwnd_;    // configured advertised window size
	double advwndcur;  // current advertised window size
	double advwndprev; // previous configured advertised window size
};

static class TcpIASinkClass : public TclClass {
public:
	TcpIASinkClass() : TclClass("Agent/TCPSink/TCPIASink") {}
	TclObject* create(int, const char*const*) {
		return (new TcpIASink(new Acker));
	}
} class_tcpiasink;

TcpIASink::TcpIASink(Acker* acker) : TcpSink(acker)
{
	bind("advwnd_", &advwnd_);
	advwndprev = advwnd_;
	advwndcur = advwnd_;
}

void TcpIASink::delay_bind_init_all()
{
	delay_bind_init_one("advwnd_");

	TcpSink::delay_bind_init_all();
}

int TcpIASink::delay_bind_dispatch(const char *varName, const char *localName, TclObject *tracer)
{
	if (delay_bind(varName, localName, "advwnd_", &advwnd_, tracer)) return TCL_OK;

        return TcpSink::delay_bind_dispatch(varName, localName, tracer);
}

int TcpIASink::command(int argc, const char*const* argv)
{
	if (argc == 3) {
		if (strcmp(argv[1], "active") == 0) {
			if (atoi(argv[2]) == 0)
				advwndcur = 0.0;
			else if (atoi(argv[2]) == 1) {
				advwndprev = advwnd_;
				advwndcur = advwnd_;
			}
			else
				return (TCL_OK);
			if (acker_->Seqno() > -1) {
				Packet* npkt = allocpkt();
				hdr_tcp *ntcp = hdr_tcp::access(npkt);
				double now = Scheduler::instance().clock();

				ntcp->seqno() = acker_->Seqno();
				ntcp->ts() = now;
				ntcp->ts_echo() = acker_->ts_to_echo();
				add_to_ack(npkt);

				send(npkt, 0);
			}
			return (TCL_OK);
		}
			
	}
	return (TcpSink::command(argc, argv));
}
//
/* Add fields to the ack. */
void TcpIASink::add_to_ack(Packet* pkt) 
{
	hdr_tcp *th = hdr_tcp::access(pkt);

	if (acker_->Seqno() > 0 && (int)advwnd_ != (int)advwndprev) {
		advwndprev = advwnd_;	
		advwndcur = advwnd_;
	}

	th->wnd() = advwndcur;
}

