# common.mk: the self-test of the testbench headers every testbench shares, tb/common/p2tb.h and zkey.h.
#
#   make tbcommon-selftest   build/tb/common/p2tb_selftest: Fails, Args, shards, Rng, VecFile; zkey.h against refcore's
#                            StoredDepth (every class of key round-trips; keys refsw3 cannot make are rejected)
TBCOMMON_ST = $(BUILD)/tb/common/p2tb_selftest

.PHONY: tbcommon-selftest

$(TBCOMMON_ST): tb/common/p2tb_selftest.cpp tb/common/p2tb.h tb/common/zkey.h $(wildcard $(REFCORE)/*.h)
	@mkdir -p $(dir $@)
	$(HOSTCXX) $(HOST_CXXFLAGS) $< -o $@

tbcommon-selftest: $(TBCOMMON_ST)
	@$(TBCOMMON_ST)
