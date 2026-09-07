# Periodo de partida para la sintesis out-of-context.
# El WNS que reporte da el Fmax alcanzable: 1000/(10 - WNS) MHz.
create_clock -period 10.000 -name clk [get_ports clk]
