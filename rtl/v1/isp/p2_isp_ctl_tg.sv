// p2_isp_ctl_tg: the decision "SHADE(OPAQUE) of this entry" (PLAN M7; ARCHITECTURE 3.4.1 "Pre-sorted TR-modifier
// glitch"). [M timemeas tables.txt 14: a pre-sorted tile with an empty opaque list and a translucent modifier volume
// once skipped its background, ~1000 clk less, blended over the previous render's buffer; history-dependent.] refsw3
// never skips the background, and neither does the RTL: until probe T21 finds the set / clear rule, this sub-block is
// a pass-through, the one place that rule will go.
module p2_isp_ctl_tg (
  input  logic shade_in,      // p2_isp_ctl: this entry shades its opaque pass (always)
  output logic shade_out      // what ctl does
);
  assign shade_out = shade_in;
endmodule
