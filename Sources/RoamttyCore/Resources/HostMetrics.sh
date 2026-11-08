export LC_ALL=C
s=$(uname -s 2>/dev/null)
# Intel GPUs: idle (RC6) residency in ms next to uptime; busy share comes from two readings.
rc6() { for c in /sys/class/drm/card*; do
  case ${c##*/} in *-*) continue ;; esac
  r=$c/power/rc6_residency_ms; [ -r "$r" ] || r=$c/device/tile0/gt0/gtidle/idle_residency_ms
  [ -r "$r" ] && echo "$1=${c##*/} $(cut -d ' ' -f 1 /proc/uptime) $(cat "$r")"
done; }
echo "hostname=$(hostname 2>/dev/null || uname -n)"
echo "kernel=$(uname -sr 2>/dev/null)"
echo "arch=$(uname -m 2>/dev/null)"
if [ -r /etc/os-release ]; then echo "os=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')"
elif [ "$s" = Darwin ]; then echo "os=macOS $(sw_vers -productVersion 2>/dev/null)"; fi
if [ -r /proc/stat ]; then
  echo "cpus=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
  echo "model=$(sed -n 's/^model name[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | head -n 1)"
  echo "cpu1=$(head -n 1 /proc/stat)"
  rc6 rc6a 2>/dev/null
  sleep 0.5 2>/dev/null || sleep 1
  echo "cpu2=$(head -n 1 /proc/stat)"
  rc6 rc6b 2>/dev/null
  echo "load=$(cut -d ' ' -f 1-4 /proc/loadavg)"
  echo "uptime=$(cut -d ' ' -f 1 /proc/uptime)"
  awk '/^(MemTotal|MemAvailable|SwapTotal|SwapFree):/ { sub(":", "", $1); print "kb_" $1 "=" $2 }' /proc/meminfo
  sed 1,2d /proc/net/dev | tr ':' ' ' | awk '$1 != "lo" { rx += $2; tx += $10 } END { printf "net=%.0f %.0f\n", rx, tx }'
elif [ "$s" = Darwin ]; then
  echo "cpus=$(sysctl -n hw.ncpu 2>/dev/null)"
  echo "model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  echo "idle=$(top -l 2 -n 0 -s 1 2>/dev/null | sed -n 's/.* \([0-9.]*\)% idle.*/\1/p' | tail -n 1)"
  echo "load=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}')"
  b=$(sysctl -n kern.boottime 2>/dev/null | sed 's/.*{ sec = \([0-9]*\).*/\1/')
  [ -n "$b" ] && echo "uptime=$(( $(date +%s) - b ))"
  echo "bytes_MemTotal=$(sysctl -n hw.memsize 2>/dev/null)"
  vm_stat 2>/dev/null | awk '/page size of/ { p = $8 } /^Pages (free|inactive|speculative)/ { gsub("\\.", "", $NF); n += $NF } END { if (p) printf "bytes_MemAvailable=%.0f\n", n * p }'
  netstat -ibn 2>/dev/null | awk '$1 !~ /^lo/ && $3 ~ /Link/ { rx += $7; tx += $10 } END { printf "net=%.0f %.0f\n", rx, tx }'
  ioreg -r -d 1 -w 0 -c IOAccelerator 2>/dev/null | awk '
    function num(key) { if (match($0, "\"" key "\"=[0-9]+")) { v = substr($0, RSTART, RLENGTH); sub(/.*=/, "", v); return v } return "" }
    /^\+-o/ { if (seen) print "macgpu=" u " " m " " n; seen = 1; u = "-"; m = "-"; n = "" }
    /"PerformanceStatistics" =/ { v = num("Device Utilization %"); if (v == "") v = num("GPU Activity\\(%\\)"); if (v != "") u = v; v = num("In use system memory"); if (v != "") m = v }
    /"model" = / { n = $0; sub(/.*"model" = "/, "", n); sub(/".*/, "", n) }
    END { if (seen) print "macgpu=" u " " m " " n }'
fi
# macOS keeps / as a small sealed system volume; files live on the Data volume of the same container.
r=/; [ "$s" = Darwin ] && [ -d /System/Volumes/Data ] && r=/System/Volumes/Data
df -Pk "$r" "$HOME" 2>/dev/null | awk 'NR > 1 && !seen[$6]++ { m = $6; for (i = 7; i <= NF; i++) m = m " " $i; print "disk=" $2 " " $3 " " $4 " " m }'
echo "users=$(who 2>/dev/null | wc -l)"
{ ps -eo pcpu=,pmem=,comm= --sort=-pcpu 2>/dev/null || ps -Aro pcpu=,pmem=,comm= 2>/dev/null; } | head -n 5 | sed 's/^/proc=/'
if command -v nvidia-smi >/dev/null 2>&1; then
  t=; command -v timeout >/dev/null 2>&1 && t="timeout 5"
  $t nvidia-smi --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit --format=csv,noheader,nounits 2>/dev/null | sed 's/^/gpu=/'
  $t nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null | sed 's/^/gpuproc=/'
fi
for c in /sys/class/drm/card*; do
  case ${c##*/} in *-*) continue ;; esac
  d=$c/device
  [ -r "$d/gpu_busy_percent" ] || continue
  h=$(ls -d "$d"/hwmon/hwmon* 2>/dev/null | head -n 1)
  echo "amdgpu=$(cat "$d/gpu_busy_percent" 2>/dev/null || echo -) $(cat "$d/mem_info_vram_used" 2>/dev/null || echo -) $(cat "$d/mem_info_vram_total" 2>/dev/null || echo -) $(cat "$h/temp1_input" 2>/dev/null || echo -) $(cat "$h/power1_average" 2>/dev/null || echo -) $(cat "$h/power1_cap" 2>/dev/null || echo -) $(cat "$d/product_name" 2>/dev/null)"
done
for c in /sys/class/drm/card*; do
  case ${c##*/} in *-*) continue ;; esac
  [ -r "$c/power/rc6_residency_ms" ] || [ -r "$c/device/tile0/gt0/gtidle/idle_residency_ms" ] || continue
  f=$c/device/tile0/gt0/freq0
  a=$(cat "$c/gt_act_freq_mhz" 2>/dev/null || cat "$f/act_freq" 2>/dev/null || echo -)
  x=$(cat "$c/gt_RP0_freq_mhz" 2>/dev/null || cat "$f/rp0_freq" 2>/dev/null || echo -)
  n=$(lspci -s "$(basename "$(readlink "$c/device")")" 2>/dev/null | sed 's/^[^ ]* [^:]*: //; s/ (rev [0-9a-f]*)$//; s/Corporation //')
  echo "igpu=${c##*/} $a $x $n"
done
exit 0