# ---------------------------------------------------------------------------
# sweep_fs.ps1 — La curva canales-contra-Fs. El experimento central.
#
# Los integradores procesan una muestra por ciclo, asi que a menos ancho de
# banda caben mas canales en la misma area:
#
#     FOLD = floor(Fclk / Fs)
#
# Con Fclk = 100 MHz: 100 MSPS -> 1, 50 -> 2, 25 -> 4, 12,5 -> 8, 6,25 -> 16.
#
# DOS PUNTOS DE N_CH POR CADA FOLD, y no por prudencia: con uno solo el coste
# fijo del diseno --AXI, generador, pegamento-- se reparte entre los canales que
# haya y falsea el coste marginal. Con dos puntos sale por diferencia:
#
#     marginal = (coste(64) - coste(16)) / 48
#
# y de ahi el techo, que es lo que responde "cuantos canales caben a esta Fs".
#
#     powershell -File syn/sweep_fs.ps1
#
# Deja C:/kv/fs/resumen.csv y un informe de utilizacion por punto.
# ---------------------------------------------------------------------------

$vivado = "E:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat"
$tcl    = "E:/Repos/scanner64/syn/fold_check.tcl"
$base   = "C:/kv/fs"

New-Item -ItemType Directory -Force $base | Out-Null
Copy-Item "E:\Repos\scanner64\rtl\sin_lut.mem" $base -Force
Set-Location $base

$csv = "$base/resumen.csv"
"fold,fs_msps,n_ch,lut,ff,bram,dsp,wns_ns,fmax_mhz" | Set-Content $csv

function Di($m) { "$(Get-Date -Format HH:mm:ss)  $m" | Tee-Object -FilePath "$base/sweep.log" -Append }

Di "=== barrido de Fs: FOLD 1 2 4 8 16, con N_CH 16 y 64 ==="

foreach ($fold in 1, 2, 4, 8, 16) {
    $fs = 100.0 / $fold
    foreach ($n in 16, 64) {
        $tag = "f${fold}_n${n}"
        Di "--- FOLD=$fold (Fs=$fs MSPS)  N_CH=$n"
        & $vivado -mode batch -nojournal -notrace -source $tcl -tclargs $n $fold `
            *> "$base/$tag.log"

        $txt = Get-Content "$base/$tag.log" -Raw
        function Campo($nombre) {
            if ($txt -match "(?m)^\s+$nombre\s+([0-9.]+)") { $Matches[1] } else { "" }
        }
        $lut  = Campo "CLB LUTs"
        $ff   = Campo "CLB Registers"
        $bram = Campo "Block RAM Tile"
        $dsp  = Campo "DSPs"
        $wns  = ""; $fmax = ""
        if ($txt -match "WNS\s+(-?[0-9.]+) ns\s+->\s+Fmax ([0-9.]+)") {
            $wns = $Matches[1]; $fmax = $Matches[2]
        }
        if ($lut -eq "") {
            Di "    FALLO: sin utilizacion. Ver $tag.log"
        } else {
            "$fold,$fs,$n,$lut,$ff,$bram,$dsp,$wns,$fmax" | Add-Content $csv
            Di "    LUT $lut  FF $ff  BRAM $bram  DSP $dsp  Fmax $fmax MHz"
        }
        # El informe, con nombre propio: fold_check.tcl los llama igual.
        if (Test-Path "$base/${n}ch_fold${fold}_util.rpt") {
            Move-Item "$base/${n}ch_fold${fold}_util.rpt" "$base/$tag`_util.rpt" -Force
        }
    }
}

Di "=== terminado ==="
Get-Content $csv | ForEach-Object { Di "  $_" }
