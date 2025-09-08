/* -*-	Mode:C; c-basic-offset:4; tab-width:4; indent-tabs-mode:t -*- */
/* gp.c: Calculate goodput using out.tr file (v.2)
 *       Check if there exists retransmission timeout event using out.et
 *   gp <trace file> <event trace file > <src node> <app_num> <granlarity>
 *   (e.g.,) ./gp out.ns out.et 0 1 1.0 > goodput.dat
 *   last line output: <goodput>Mbps <isIncast> <transmitted bytes>Byte \
 *              <transmission time>s <first_recv_time>s <last_recv_time>s
 *   <isIncast>: 0 = fales (not incast); 1 = true (incast)
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAXFLOW 8192
#define H_SIZE  40
#define SW_NODE 0

typedef struct rcvd_t {
	int seqno;
	int flow_id;
	struct rcvd_t *next;
} rcvd_t;

rcvd_t head;

int isnew (int seqno, int flow_id)
{
	rcvd_t *rcvd = head.next;

	while ( rcvd ){
		if ( rcvd->seqno == seqno && rcvd->flow_id == flow_id ) return 0;
		rcvd = rcvd->next;
	}

	// true
	return 1;
}

void updatercvd (int seqno, int flow_id)
{
	rcvd_t *rcvd;

	if ( NULL == (rcvd = (rcvd_t *)malloc(sizeof(rcvd_t))) ) {
		fprintf(stderr, "Memory Allocation Error.\n");
		exit(1);
	}

	rcvd->seqno = seqno;
	rcvd->flow_id = flow_id;
	rcvd->next = head.next;
	head.next = rcvd;
}

int countrcvd (rcvd_t *rcvd)
{
	int count = 0;
	while ( rcvd ){
		count++;
		rcvd = rcvd->next;
	}
	return count;
}

void freercvd (rcvd_t *rcvd)
{
	rcvd_t *ptr_del = NULL;
	while (rcvd) {
		ptr_del = rcvd;
		rcvd = rcvd->next;
		free(ptr_del);
	}
}

int main ( int argc, char **argv )
{
	FILE *fp_ns, *fp_et;
	int tx, rx, packet_size, flow_id, sequence, packet_id, node, cwnd, app_num;
	// unsigned long long int sum, sum_all;
	double sum, sum_all;
	char buffer[128], event, packet_type[8], flags[8], tx_address[16],
		rx_address[16], event_type[32], is_rto;
	double time, clock, granularity, first_recv_time, last_recv_time, goodput;
	double last_sent_time[MAXFLOW];

	// Check the number of arguments
	if (argc != 6) {
		fprintf(stderr, "Usage: <this> <trace_file> <event_file> <src_node> <app_num> <granularity>\n");
		return 1;
	}

	// Init
	head.next = NULL;
	first_recv_time = 100000.0;
	last_recv_time  = -1.0;
	goodput = 0.0;
	int i;
	for(i = 0; i < MAXFLOW; i++) last_sent_time[i] = -1.0;

	// Open Trace file (out.ns)
	if ( NULL == ( fp_ns = fopen ( argv[1], "r" ) ) ) {
		fprintf ( stderr, "Can't open %s\n", argv[1] );
		return 1;
	}

	// Open Event Trace file (out.et)
	if ( NULL == ( fp_et = fopen ( argv[2], "r" ) ) ) {
		fprintf ( stderr, "Can't open %s\n", argv[2] );
		return 1;
	}

	node = atoi ( argv[3] );
	app_num = atoi ( argv[4] );
	granularity = atof ( argv[5] );

	// Check Arguments
	if (app_num < 1) {
		fprintf ( stderr, "Error: the number of applications %s\n", argv[4] );
		return 1;
	}

	// Goodput Calculation
	for ( sum = 0, sum_all = 0, clock = 0.0; feof ( fp_ns ) == 0; ) {
		/* Read One Line */
		fgets ( buffer, 128, fp_ns );
		sscanf ( buffer, "%c %lf %d %d %s %d %s %d %s %s %d %d",
				 &event, &time, &tx, &rx, packet_type, &packet_size, flags, &flow_id,
				 tx_address, rx_address, &sequence, &packet_id );

		// Eliminate others of TCP which is not needed for goodput calculation
		if ( strcmp(packet_type, "tcp") != 0 ) continue;

		// exception check
		if ( flow_id >= MAXFLOW ) {
			printf("MAXFLOW ERROR! flow_id:%d\n", flow_id);
			freercvd( head.next );
			return 1;
		}

		// for counting retransmission timeout
		if ( event == '+' && rx == SW_NODE
			 && last_sent_time[flow_id] < time )
			last_sent_time[flow_id] = time;

		// for calculating goodput
		if ( event != 'r' ) continue;
		if ( tx != node )	continue;

		/* Calclate Goodput Mbps*/
		if ( ( time - clock ) > granularity ) {
			goodput = ( sum / granularity ) * 8.0 / 1000.0 / 1000.0;
			goodput = goodput / app_num;
			clock += granularity;
			printf ( "%f\t%f\t%.0f\n", clock, goodput, sum );
			sum = 0;
		}

		// is newdata? (uncount unnecessary restransmission)
		if ( isnew(sequence, flow_id) ){
			updatercvd(sequence, flow_id);
			if (first_recv_time > time) first_recv_time = time;
			if (packet_size > H_SIZE) {
				sum     += (double)(packet_size - H_SIZE);
				// sum_all += (unsigned long long int)(packet_size - H_SIZE);
				sum_all += (double)(packet_size - H_SIZE);
				last_recv_time = time;
			}
		}
	} // for

	goodput = ( (double) sum_all / (last_recv_time - first_recv_time) ) 
		* 8.0 / 1000.0 / 1000.0 / app_num;

	// Count Retransmisson Timeout Event from Event Trace file
	for ( is_rto = 0; feof ( fp_et ) == 0; ) {
		/* Read One Line */
		fgets ( buffer, 128, fp_et );
		sscanf ( buffer, "%c %lf %d %d %s %s %d %d %d",
				 &event, &time, &tx, &rx, packet_type, event_type, &flow_id,
				 &sequence, &cwnd );

		if ( time > last_sent_time[flow_id] ) continue;
		if ( strcmp(event_type, "TIMEOUT") == 0 ) is_rto = 1;
	}

	//    printf ( "%f\t%d\t%llu\t%f\t%f\t%f\n",
	printf ( "%f\t%d\t%.0f\t%f\t%f\t%f\n",
			 goodput, is_rto, sum_all, last_recv_time - first_recv_time,
			 first_recv_time, last_recv_time);

	fclose ( fp_ns );
	fclose ( fp_et );

	//printf("size of memory: %d\n", countrcvd(head.next));
	//printf("free memory\n");
	freercvd( head.next );
	// printf("done.\n");

	return 0;
}
