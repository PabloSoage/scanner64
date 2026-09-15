# ---------------------------------------------------------------------------
# sweep_nch.ps1 - Un bitstream por cada numero de canales.
#
# Da la materia prima de dos cosas a la vez:
#   D6  la columna de vatios: hay que medir el INA260 con cada diseno cargado.
#   B8b la curva canales-contra-Fs, que es el resultado central de la memoria.
#
# Se lanza y se olvida. Va dejando los artefactos segun terminan y borra el
# proyecto de cada punto para no comerse el disco -- pero SOLO despues de
# comprobar que el .bit.bin esta copiado. La primera version borraba antes de
# comprobar y perdio el punto de 4 canales entero.
#
#     powershell -File syn/sweep_nch.ps1
#
# Deja en C:/kv/sweep/results, por cada N:
#     scanner64_nN.bit.bin   listo para fpgautil
#     scanner64_nN.bit       por si hace falta rehacer el .bin
#     util_nN.rpt            utilizacion post-implementacion
#     resumen.csv            N, WNS, Fmax
# ---------------------------------------------------------------------------

$vivado  = "E:\AMDDesignTools\2026.1\Vivado\bin\vivado.bat"
$bootgen = "E:\AMDDesignTools\2026.1\Vivado\bin\bootgen.bat"
$tcl     = "E:/Repos/scanner64/syn/build_kria.tcl"
$base    = "C:/kv/sweep"
$res     = "$base/results"

New-Item -ItemType Directory -Force $res | Out-Null
$log = "$res/sweep.log"
function Di($m) {
    $t = Get-Date -Format "HH:mm:ss"
    "$t  $m" | Tee-Object -FilePath $log -Append
}

$csv = "$res/resumen.csv"
if (-not (Test-Path $csv)) { "N_CH,WNS_ns,Fmax_MHz" | Set-Content $csv }

Di "=== barrido de N_CH: 4 8 16 32 64 ==="

foreach ($n in 4, 8, 16, 32, 64) {
    $dir  = "$base/n$n"
    $vlog = "$res/vivado_n$n.log"
    Di "--- N_CH = $n : sintetizando"
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }

    & $vivado -mode batch -notrace -source $tcl -tclargs $dir $n *> $vlog

    $bit = Get-ChildItem "$dir/scanner64_kria.runs/impl_1/*.bit" -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if (-not $bit) {
        Di "--- N_CH = $n : FALLO en Vivado. Ver $vlog. El proyecto NO se borra."
        continue
    }

    # bootgen deja el .bin JUNTO AL .bit DE ENTRADA, no en el directorio de
    # trabajo. Por eso se busca ahi y no al nivel de arriba.
    $bif = "$dir/pl.bif"
    "all:`n{`n    [destination_device = pl] $($bit.FullName)`n}" |
        Set-Content -Encoding ASCII $bif
    & $bootgen -image $bif -arch zynqmp -process_bitstream bin *>> $vlog

    $bin = Get-ChildItem "$($bit.Directory)/*.bit.bin" -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if (-not $bin) {
        Di "--- N_CH = $n : FALLO en bootgen. El proyecto NO se borra."
        continue
    }

    Copy-Item $bin.FullName "$res/scanner64_n$n.bit.bin" -Force
    Copy-Item $bit.FullName "$res/scanner64_n$n.bit"     -Force
    if (Test-Path "$dir/utilization.rpt") {
        Copy-Item "$dir/utilization.rpt" "$res/util_n$n.rpt" -Force
    }

    # El timing sale del propio log de Vivado, que ya lo imprime.
    $wns = $null; $fmx = $null
    foreach ($l in Get-Content $vlog) {
        if ($l -match 'WNS a 100 MHz\s*:\s*(-?[0-9.]+)')  { $wns = $Matches[1] }
        if ($l -match 'Fmax\s*:\s*([0-9.]+)')             { $fmx = $Matches[1] }
    }
    "$n,$wns,$fmx" | Add-Content $csv
    Di "--- N_CH = $n : listo. WNS $wns ns, Fmax $fmx MHz"

    # Ahora si: el artefacto esta a salvo fuera del proyecto.
    Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue
}

Di "=== barrido terminado ==="
Get-ChildItem $res -Filter "*.bit.bin" | ForEach-Object { Di "  $($_.Name)" }
Di "resumen:"
Get-Content $csv | ForEach-Object { Di "  $_" }
