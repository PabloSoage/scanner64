# ---------------------------------------------------------------------------
# sweep_fs.ps1 - The channels-against-Fs curve. The central experiment.
#
# The integrators process one sample per cycle, so the less bandwidth you need
# the more channels fit in the same area:
#
#     FOLD = floor(Fclk / Fs)
#
# With Fclk = 100 MHz: 100 MSPS -> 1, 50 -> 2, 25 -> 4, 12.5 -> 8, 6.25 -> 16.
#
# TWO N_CH POINTS PER FOLD, and not out of caution: with only one, the design's
# fixed cost -- AXI, generator, glue -- gets spread over however many channels
# there are and falsifies the marginal cost. With two points it comes out by
# difference:
#
#     marginal = (cost(64) - cost(16)) / 48
#
# and from that the ceiling, which is what answers "how many channels fit at
# this Fs".
#
#     powershell -File syn/sweep_fs.ps1
#
# Leaves C:/kv/fs/summary.csv and one utilisation report per point.
# ---------------------------------------------------------------------------

$vivado = "E:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat"
$tcl    = "E:/Repos/scanner64/syn/fold_check.tcl"
$base   = "C:/kv/fs"

New-Item -ItemType Directory -Force $base | Out-Null
Copy-Item "E:\Repos\scanner64\rtl\sin_lut.mem" $base -Force
Set-Location $base

$csv = "$base/summary.csv"
"fold,fs_msps,n_ch,lut,ff,bram,dsp,wns_ns,fmax_mhz" | Set-Content $csv

function Say($m) { "$(Get-Date -Format HH:mm:ss)  $m" | Tee-Object -FilePath "$base/sweep.log" -Append }

Say "=== Fs sweep: FOLD 1 2 4 8 16, with N_CH 16 and 64 ==="

foreach ($fold in 1, 2, 4, 8, 16) {
    $fs = 100.0 / $fold
    foreach ($n in 16, 64) {
        $tag = "f${fold}_n${n}"
        Say "--- FOLD=$fold (Fs=$fs MSPS)  N_CH=$n"
        & $vivado -mode batch -nojournal -notrace -source $tcl -tclargs $n $fold `
            *> "$base/$tag.log"

        $txt = Get-Content "$base/$tag.log" -Raw
        function Field($name) {
            if ($txt -match "(?m)^\s+$name\s+([0-9.]+)") { $Matches[1] } else { "" }
        }
        $lut  = Field "CLB LUTs"
        $ff   = Field "CLB Registers"
        $bram = Field "Block RAM Tile"
        $dsp  = Field "DSPs"
        $wns  = ""; $fmax = ""
        if ($txt -match "WNS\s+(-?[0-9.]+) ns\s+->\s+Fmax ([0-9.]+)") {
            $wns = $Matches[1]; $fmax = $Matches[2]
        }
        if ($lut -eq "") {
            Say "    FAILED: no utilisation. See $tag.log"
        } else {
            "$fold,$fs,$n,$lut,$ff,$bram,$dsp,$wns,$fmax" | Add-Content $csv
            Say "    LUT $lut  FF $ff  BRAM $bram  DSP $dsp  Fmax $fmax MHz"
        }
        # The report, under its own name: fold_check.tcl calls them all alike.
        if (Test-Path "$base/${n}ch_fold${fold}_util.rpt") {
            Move-Item "$base/${n}ch_fold${fold}_util.rpt" "$base/$tag`_util.rpt" -Force
        }
    }
}

Say "=== finished ==="
Get-Content $csv | ForEach-Object { Say "  $_" }
