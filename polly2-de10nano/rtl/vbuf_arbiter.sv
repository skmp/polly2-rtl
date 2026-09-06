// Two-master arbiter for the 128-bit HPS vbuf Avalon read port.
//
// Both display controllers serialize their own bursts.  The arbiter accepts
// one command, retains its owner until every return beat has arrived, and
// applies round-robin priority when both scanout engines request together.
// Return data is broadcast, but readdatavalid is asserted only to the owner.

module vbuf_arbiter
(
	input  wire         clk,
	input  wire         reset,

	input  wire         m0_read,
	input  wire [27:0]  m0_address,
	input  wire  [7:0]  m0_burstcount,
	output reg          m0_waitrequest,
	output wire [127:0] m0_readdata,
	output wire         m0_readdatavalid,

	input  wire         m1_read,
	input  wire [27:0]  m1_address,
	input  wire  [7:0]  m1_burstcount,
	output reg          m1_waitrequest,
	output wire [127:0] m1_readdata,
	output wire         m1_readdatavalid,

	output reg          s_read,
	output reg  [27:0]  s_address,
	output reg   [7:0]  s_burstcount,
	input  wire         s_waitrequest,
	input  wire [127:0] s_readdata,
	input  wire         s_readdatavalid
);

localparam [1:0] IDLE = 2'd0, COMMAND = 2'd1, DATA = 2'd2;

reg [1:0] state = IDLE;
reg       owner = 1'b0;
reg       prefer = 1'b0;
reg [7:0] beats_left = 8'd0;
reg [27:0] command_address = 28'd0;
reg [7:0] command_burstcount = 8'd0;

assign m0_readdata = s_readdata;
assign m1_readdata = s_readdata;
assign m0_readdatavalid = (state == DATA) && !owner && s_readdatavalid;
assign m1_readdatavalid = (state == DATA) &&  owner && s_readdatavalid;

always @* begin
	m0_waitrequest = 1'b1;
	m1_waitrequest = 1'b1;
	s_read = 1'b0;
	s_address = command_address;
	s_burstcount = command_burstcount;

	if (state == COMMAND) begin
		s_read = 1'b1;
		if (owner) m1_waitrequest = s_waitrequest;
		else       m0_waitrequest = s_waitrequest;
	end
end

always @(posedge clk) begin
	if (reset) begin
		state <= IDLE;
		owner <= 1'b0;
		prefer <= 1'b0;
		beats_left <= 8'd0;
		command_address <= 28'd0;
		command_burstcount <= 8'd0;
	end else begin
		case (state)
		IDLE: begin
			if (m0_read || m1_read) begin
				owner <= m0_read && m1_read ? prefer : m1_read;
				if (m0_read && m1_read ? prefer : m1_read) begin
					command_address <= m1_address;
					command_burstcount <= m1_burstcount;
				end else begin
					command_address <= m0_address;
					command_burstcount <= m0_burstcount;
				end
				state <= COMMAND;
			end
		end

		COMMAND: begin
			if (!s_waitrequest) begin
				beats_left <= command_burstcount;
				state <= DATA;
			end
		end

		DATA: begin
			if (s_readdatavalid) begin
				if (beats_left == 8'd1) begin
					beats_left <= 8'd0;
					prefer <= ~owner;
					state <= IDLE;
				end else beats_left <= beats_left - 8'd1;
			end
		end

		default: state <= IDLE;
		endcase
	end
end

endmodule
