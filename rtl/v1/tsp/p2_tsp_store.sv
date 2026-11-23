// p2_tsp_store: the TSP's set-up store, its run queue (SRQ) and the look-ahead (PLAN M9; ARCHITECTURE 3.7.1; tim 3.7).
// Functionally transparent: a store entry is a pure function of its key, the tag's parameter block and the render's
// registers (refsw3 GetFpuEntry, whose fpuCache of 32 is cleared at every region array entry; refsw_tile.cpp L518-556).
//
//   the SRQ          the sorter's items (p2_rs_t with new_drain, p2_sort), P2_TSP_SRQ_N deep [G T6], in order to run
//                    start (p2_tsp_rstart, M10; the testbench in M9): its head leaves once the entries it references are
//                    set up
//   the entries      P2_TSP_STORE_N = 16 [G T6], keyed by (tag[31:0], vsel): vsel the volume a run's pixel uses, InVolume =
//                    vmask[n] && tag.shadow && rm not PT_PASS0 / PT_PASSN (refsw_tile.cpp RenderParamTags, PixelFlush_tsp:
//                    InVolume ? Col[1] : Col[0], the second TSP / TCW / U / V with two volumes) [M allfs: a triangle
//                    straddling a volume edge is set up twice]. The words: a header (p2_tsp_hdr_t), K (p2_tsp_k_t) and
//                    P2_TSP_NPLANE planes (p2_tsp_plane_t) in four banks [die: region 5, four equal SRAMs; the header
//                    and K beside them, the wide and the narrow SRAM: ARCHITECTURE 3.12]
//   the look-ahead   a pointer walking the SRQ from its head: for each run the volumes its pixels need (one, or both for
//                    a run with mixed vmask and the shadow bit), one key a clock; a key in the store is pinned again; a
//                    key not in it takes an unpinned entry (FIFO replacement from the last one taken [G]; [M] not LRU,
//                    GAP T6) and a setup job (p2_tsp_pfetch, p2_tsp_setup); a key with no free entry or no room for its
//                    job waits [M tim 3.7: "~11-12 new primitives ahead", a storage limit]
//   pins             an entry is pinned (a count) from the look-ahead's reference until the run's last store read
//                    (`rel`: the pixel pipe's P10, M11; the testbench in M9) [G T6: pins to P10]
//   across entries   entries are kept (STORE_KEEP [G T6]); `flush` (a render's start: the parameters and the registers
//                    change) empties the store
// Read port: one word a clock of an entry (0 the header, 1 K, 2 .. the planes), the data the clock after (synchronous
// RAMs); run start's (M10) and the testbench's.
module p2_tsp_store
  import p2_regs_pkg::*;
  import p2_pkg::*;
  import p2_tsp_pkg::*;
  import p2_tsp_prog_pkg::*;
(
  input  logic                          clk,
  input  logic                          rst,
  input  logic                          flush,          // empty the store (a render's start); only while it is idle
  // the sorter's items, valid/ready
  input  logic                          in_v,
  output logic                          in_rdy,
  input  p2_rs_t                        in_item,
  input  logic                          in_nd,
  // the SRQ's head (run start), valid/ready: the item and the entries of the volumes it needs
  output logic                          out_v,
  input  logic                          out_rdy,
  output p2_rs_t                        out_item,
  output logic                          out_nd,
  output logic [1:0]                    out_need,       // [v]: some pixel of the run uses volume v
  output logic [1:0][P2_TSP_SIDX_BITS-1:0] out_idx,
  // the run's last store read: its pins go (in the order the runs left)
  input  logic                          rel_v,
  input  logic [1:0]                    rel_need,
  input  logic [1:0][P2_TSP_SIDX_BITS-1:0] rel_idx,
  // setup jobs (p2_tsp_pfetch), valid/ready
  output logic                          jb_v,
  input  logic                          jb_rdy,
  output p2_tsp_job_t                   jb,
  // the setup's writes (p2_tsp_setup)
  input  logic                          sh_v,
  input  logic [P2_TSP_SIDX_BITS-1:0]   sh_idx,
  input  p2_tsp_hdr_t                   sh_w,
  input  logic                          sp_v,
  input  logic [P2_TSP_SIDX_BITS-1:0]   sp_idx,
  input  logic [3:0]                    sp_plane,
  input  p2_tsp_plane_t                 sp_w,
  input  logic                          sk_v,
  input  logic [P2_TSP_SIDX_BITS-1:0]   sk_idx,
  input  p2_tsp_k_t                     sk_w,
  input  logic                          done,
  input  logic [P2_TSP_SIDX_BITS-1:0]   done_idx,
  // the read port
  input  logic                          rd_v,
  input  logic [P2_TSP_SIDX_BITS-1:0]   rd_idx,
  input  logic [3:0]                    rd_word,        // 0 header, 1 K, 2 + p plane p
  output p2_tsp_hdr_t                   rd_hdr,
  output p2_tsp_k_t                     rd_k,
  output p2_tsp_plane_t                 rd_plane,
  // statistics (reported, not gated: T6)
  output logic [5:0]                    t_srq,          // SRQ occupancy
  output logic [4:0]                    t_pinned,       // entries pinned
  output logic                          t_la_wait,      // the look-ahead waits for an entry or for room for a job
  output logic                          t_job,          // a setup job issued
  output logic                          t_hit           // a key found in the store
);
  localparam int N  = P2_TSP_STORE_N;
  localparam int IB = P2_TSP_SIDX_BITS;
  localparam int QN = P2_TSP_SRQ_N;
  localparam int QB = $clog2(QN);
  localparam int PB = 7;                 // pin counts: at most 2 a run, QN runs plus those after the SRQ
  localparam int JOB_N = 2;              // setup jobs waiting for p2_tsp_pfetch [G]

  // ---------------------------------------------------------------------------------------------- the SRQ
  p2_rs_t [QN-1:0]            q_item;
  logic   [QN-1:0]            q_nd;
  logic   [QN-1:0][1:0]       q_need;
  logic   [QN-1:0][1:0][IB-1:0] q_idx;
  logic   [QB-1:0]            q_wp, q_lp, q_rp;
  logic   [QB:0]              q_n, q_la;   // items in the SRQ; items the look-ahead has passed and not left
  logic                       push, pop, la_adv;
  assign in_rdy = q_n != (QB+1)'(QN);
  assign push   = in_v && in_rdy;

  // ---------------------------------------------------------------------------------------------- the entries
  logic [N-1:0][31:0]   k_tag;
  logic [N-1:0]         k_vsel, e_valid, e_ready;
  logic [N-1:0][PB-1:0] e_pin;
  logic [IB-1:0]        rep;          // where the replacement search starts: after the last entry taken

  // the look-ahead's item and the volumes it needs
  p2_rs_t     la_item;
  logic [1:0] la_need;
  logic       la_half;                // the first needed volume is done (an item that needs both)
  logic       la_have;
  assign la_have = q_la != q_n;
  assign la_item = q_item[q_lp];
  always_comb begin
    logic [31:0] lm, inv;
    logic        vol_ok;
    // pixels n < len; InVolume = vmask[n] && shadow && rm not PT_PASS0 / PT_PASSN
    lm     = 32'hFFFF_FFFF >> (5'd31 - la_item.lenm1);
    vol_ok = la_item.tag.shadow && la_item.rm != P2_RM_PUNCHTHROUGH_PASS0 && la_item.rm != P2_RM_PUNCHTHROUGH_PASSN;
    inv    = vol_ok ? (la_item.vmask & lm) : 32'h0;
    la_need[1] = !la_item.null_ && inv != 32'h0;
    la_need[0] = !la_item.null_ && (inv != lm);
  end
  // the key looked up this clock: volume 0 first, then volume 1
  logic        lk_vsel, lk_v;
  logic [31:0] lk_tag;
  assign lk_vsel = !la_need[0] || la_half;
  assign lk_tag  = la_item.tag;
  assign lk_v    = la_have && !la_item.null_ && !flush;
  logic          hit;
  logic [IB-1:0] hit_i;
  always_comb begin
    hit   = 1'b0;
    hit_i = '0;
    for (int i = 0; i < N; i++)
      if (e_valid[i] && k_tag[i] == lk_tag && k_vsel[i] == lk_vsel) begin
        hit   = 1'b1;
        hit_i = IB'(i);
      end
  end
  // a free entry: unpinned, the first from rep on
  logic          vic;
  logic [IB-1:0] vic_i;
  always_comb begin
    vic   = 1'b0;
    vic_i = '0;
    for (int d = N - 1; d >= 0; d--) begin
      logic [IB-1:0] i;
      i = rep + IB'(d);
      if (e_pin[i] == '0) begin
        vic   = 1'b1;
        vic_i = i;
      end
    end
  end
  // the job queue
  p2_tsp_job_t [JOB_N-1:0]      jq;
  logic [$clog2(JOB_N)-1:0]     jq_rp, jq_wp;
  logic [$clog2(JOB_N+1)-1:0]   jq_n;
  logic                         jq_full, jq_push, jq_pop;
  assign jq_full = jq_n == ($clog2(JOB_N+1))'(JOB_N);
  assign jb_v    = jq_n != '0;
  assign jb      = jq[jq_rp];
  assign jq_pop  = jb_v && jb_rdy;

  // this clock's look-ahead step
  logic          lk_hit, lk_new, lk_wait, lk_done_key;
  logic [IB-1:0] lk_i;
  assign lk_hit      = lk_v && hit;
  assign lk_new      = lk_v && !hit && vic && !jq_full;
  assign lk_wait     = lk_v && !hit && !(vic && !jq_full);
  assign lk_done_key = lk_hit || lk_new;
  assign lk_i        = hit ? hit_i : vic_i;
  assign jq_push     = lk_new;
  p2_tsp_job_t   jq_new;
  always_comb begin
    jq_new      = '0;
    jq_new.tag  = p2_tag_t'(lk_tag);
    jq_new.vsel = lk_vsel;
    jq_new.sidx = vic_i;
  end
  // the item is passed when its last needed key is done (a null item at once)
  assign la_adv = la_have && !flush &&
                  (la_item.null_ || (lk_done_key && (lk_vsel || !la_need[1])));

  // ---------------------------------------------------------------------------------------------- the head
  logic [1:0]          h_need;
  logic [1:0][IB-1:0]  h_idx;
  logic                h_ok;
  assign h_need = q_need[q_rp];
  assign h_idx  = q_idx[q_rp];
  assign h_ok   = (!h_need[0] || e_ready[h_idx[0]]) && (!h_need[1] || e_ready[h_idx[1]]);
  assign out_v    = q_la != '0 && h_ok;
  assign out_item = q_item[q_rp];
  assign out_nd   = q_nd[q_rp];
  assign out_need = h_need;
  assign out_idx  = h_idx;
  assign pop      = out_v && out_rdy;

  always_ff @(posedge clk) begin
    if (rst) begin
      q_wp    <= '0;
      q_lp    <= '0;
      q_rp    <= '0;
      q_n     <= '0;
      q_la    <= '0;
      la_half <= 1'b0;
      e_valid <= '0;
      e_ready <= '0;
      e_pin   <= '0;
      rep     <= '0;
      jq_rp   <= '0;
      jq_wp   <= '0;
      jq_n    <= '0;
    end else begin
      // the SRQ
      if (push) begin
        q_item[q_wp] <= in_item;
        q_nd[q_wp]   <= in_nd;
        q_wp         <= q_wp + 1'b1;
      end
      if (pop)
        q_rp <= q_rp + 1'b1;
      q_n  <= q_n + (QB+1)'(push) - (QB+1)'(pop);
      q_la <= q_la + (QB+1)'(la_adv) - (QB+1)'(pop);
      // the look-ahead
      if (lk_done_key) begin
        q_idx[q_lp][lk_vsel] <= lk_i;
        if (lk_new) begin
          k_tag[vic_i]   <= lk_tag;
          k_vsel[vic_i]  <= lk_vsel;
          e_valid[vic_i] <= 1'b1;
          e_ready[vic_i] <= 1'b0;
          rep            <= vic_i + 1'b1;
        end
      end
      if (la_adv) begin
        q_need[q_lp] <= la_need;
        q_lp         <= q_lp + 1'b1;
        la_half      <= 1'b0;
      end else if (lk_done_key && !lk_vsel) begin
        la_half <= 1'b1;
      end
      // pins: + the look-ahead's key, - the runs' last reads
      for (int i = 0; i < N; i++) begin
        logic [PB-1:0] inc, dec;
        inc = (lk_done_key && lk_i == IB'(i)) ? PB'(1) : PB'(0);
        dec = PB'(rel_v && rel_need[0] && rel_idx[0] == IB'(i)) + PB'(rel_v && rel_need[1] && rel_idx[1] == IB'(i));
        e_pin[i] <= e_pin[i] + inc - dec;
      end
      // the setup's end
      if (done)
        e_ready[done_idx] <= 1'b1;
      if (flush) begin
        e_valid <= '0;
        e_ready <= '0;
      end
      // the jobs
      if (jq_push) begin
        jq[jq_wp] <= jq_new;
        jq_wp     <= jq_wp + 1'b1;
      end
      if (jq_pop)
        jq_rp <= jq_rp + 1'b1;
      jq_n <= jq_n + ($clog2(JOB_N+1))'(jq_push) - ($clog2(JOB_N+1))'(jq_pop);
    end
  end

  // ---------------------------------------------------------------------------------------------- the words
  // the header and K: one RAM each, a write port (the setup) and a read port
  p2_tsp_hdr_t [N-1:0] m_hdr;
  p2_tsp_k_t   [N-1:0] m_k;
  always_ff @(posedge clk) begin
    if (sh_v) m_hdr[sh_idx] <= sh_w;
    if (sk_v) m_k[sk_idx]   <= sk_w;
    if (rd_v) begin
      rd_hdr <= m_hdr[rd_idx];
      rd_k   <= m_k[rd_idx];
    end
  end
  // the planes: four banks, plane p in bank p mod 4 at row (entry, p / 4); one plane written a clock, one read
  localparam int ROWS = 3;              // ceil(P2_TSP_NPLANE / 4)
  p2_tsp_plane_t [3:0]    bank_q;
  logic [1:0]             rd_bank;
  genvar b;
  generate
    for (b = 0; b < 4; b = b + 1) begin : g_bank
      p2_tsp_plane_t [N*ROWS-1:0] mem;
      logic [3:0] rp;
      assign rp = rd_word - 4'd2;
      always_ff @(posedge clk) begin
        if (sp_v && sp_plane[1:0] == 2'(b))
          mem[sp_idx * ROWS + 32'(sp_plane[3:2])] <= sp_w;
        if (rd_v && rd_word >= 4'd2 && rp[1:0] == 2'(b))
          bank_q[b] <= mem[rd_idx * ROWS + 32'(rp[3:2])];
      end
    end
  endgenerate
  always_ff @(posedge clk)
    if (rd_v) rd_bank <= 2'(rd_word - 4'd2);
  assign rd_plane = bank_q[rd_bank];

  // ---------------------------------------------------------------------------------------------- statistics
  always_comb begin
    t_pinned = '0;
    for (int i = 0; i < N; i++)
      if (e_pin[i] != '0) t_pinned = t_pinned + 5'd1;
  end
  assign t_srq     = 6'(q_n);
  assign t_la_wait = lk_wait;
  assign t_job     = lk_new;
  assign t_hit     = lk_hit;
endmodule
