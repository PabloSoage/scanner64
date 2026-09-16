# Starting period for out-of-context synthesis.
# The WNS it reports gives the achievable Fmax: 1000/(10 - WNS) MHz.
create_clock -period 10.000 -name clk [get_ports clk]
