# polly2-rtl

A SystemVerilog model of the Dreamcast's PowerVR2 / CLX2 CORE that is **bit-exact and cycle-accurate** to a console:
every pixel, depth word and register a console produces, at the clock a console produces it. The cycle timing is
part of the result (the translucent sort's order, races between the units, reads of a framebuffer still being
written out), so it is modelled from the start, from measured stage latches and occupancy, not latency tables.

- The functional rules are refsw3's (nulldc3 `refsw3/refcore`), the software model that matches a console bit for
  bit, every rule pinned by a console test in dreamcast-tests.
- The timing comes from console timing probes (dreamcast-tests), with the pipeline structure that explains them.
- Nothing is cut to fit an FPGA: that version is polly2-rtl-lite (formerly polly2-rtl, r6b).

Layout (as shrike4-rtl):

    rtl/v1/      the core, one folder per unit
    tb/          Verilator testbenches: per unit in lockstep with refsw3's functions, whole frames against
                 refsw3-offline and the console's archived dumps
    model/       timing models and analysis tools
    tools/hw/    console runs (through dreamcast-tests run2.sh)
    docs/        the specification per unit, timing, architecture
    agents/      agents' reports and scratch

Status: started 2026-11-20.
