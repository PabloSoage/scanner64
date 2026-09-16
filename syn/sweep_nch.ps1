# ---------------------------------------------------------------------------
# sweep_nch.ps1 - One bitstream per channel count.
#
# It provides the raw material for two things at once:
#   D6  the watts column: the INA260 has to be measured with each design loaded.
#   B8b the channels-against-Fs curve, which is the central result.
#
# Launch it and forget it. It drops the artefacts as each point finishes and
# deletes that point's project so it does not eat the disk -- but ONLY after
# checking the .bit.bin has been copied. The first version deleted before
# checking and lost the whole 4-channel point.
#
#     powershell -File syn/sweep_nch.ps1
#
# Leaves, in C:/kv/sweep/results, for each N:
#     scanner64_nN.bit.bin   ready for fpgautil
#     scanner64_nN.bit       in case the .bin has to be rebuilt
#     util_nN.rpt            post-implementation utilisation
#     summary.csv            N, WNS, Fmax
# ---------------------------------------------------------------------------

$vivado  = "E:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat"
$bootgen = "E:\AMDDesignTools\2026.1\Vivado\bin\bootgen.bat"
$tcl     = "E:/Repos/scanner64/syn/build_kria.tcl"
$base    = "C:/kv/sweep"
$res     = "$base/results"

New-Item -ItemType Directory -Force $res | Out-Null
$log = "$res/sweep.log"
function Say($m) {
    $t = Get-Date -Format "HH:mm:ss"
    "$t  $m" | Tee-Object -FilePath $log -Append
}

$csv = "$res/summary.csv"
if (-not (Test-Path $csv)) { "N_CH,WNS_ns,Fmax_MHz" | Set-Content $csv }

Say "=== N_CH sweep: 4 8 16 32 64 ==="

foreach ($n in 4, 8, 16, 32, 64) {
    $dir  = "$base/n$n"
    $vlog = "$res/vivado_n$n.log"
    Say "--- N_CH = $n : synthesising"
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }

    & $vivado -mode batch -notrace -source $tcl -tclargs $dir $n *> $vlog

    $bit = Get-ChildItem "$dir/scanner64_kria.runs/impl_1/*.bit" -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if (-not $bit) {
        Say "--- N_CH = $n : Vivado FAILED. See $vlog. The project is NOT deleted."
        continue
    }

    # bootgen leaves the .bin NEXT TO THE INPUT .bit, not in the working
    # directory. That is why it is looked for there and not one level up.
    $bif = "$dir/pl.bif"
    "all:`n{`n    [destination_device = pl] $($bit.FullName)`n}" |
        Set-Content -Encoding ASCII $bif
    & $bootgen -image $bif -arch zynqmp -process_bitstream bin *>> $vlog

    $bin = Get-ChildItem "$($bit.Directory)/*.bit.bin" -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if (-not $bin) {
        Say "--- N_CH = $n : bootgen FAILED. The project is NOT deleted."
        continue
    }

    Copy-Item $bin.FullName "$res/scanner64_n$n.bit.bin" -Force
    Copy-Item $bit.FullName "$res/scanner64_n$n.bit"     -Force
    if (Test-Path "$dir/utilization.rpt") {
        Copy-Item "$dir/utilization.rpt" "$res/util_n$n.rpt" -Force
    }

    # The timing comes out of Vivado's own log, which already prints it.
    $wns = $null; $fmx = $null
    foreach ($l in Get-Content $vlog) {
        if ($l -match 'WNS at 100 MHz\s*:\s*(-?[0-9.]+)') { $wns = $Matches[1] }
        if ($l -match 'Fmax\s*:\s*([0-9.]+)')             { $fmx = $Matches[1] }
    }
    "$n,$wns,$fmx" | Add-Content $csv
    Say "--- N_CH = $n : done. WNS $wns ns, Fmax $fmx MHz"

    # Now, and only now: the artefact is safe outside the project.
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
}

Say "=== sweep finished ==="
Get-ChildItem $res -Filter "*.bit.bin" | ForEach-Object { Say "  $($_.Name)" }
Say "summary:"
Get-Content $csv | ForEach-Object { Say "  $_" }
