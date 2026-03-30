#!/bin/bash
# ClaudyBro Terminal Performance Benchmark
# Measures how different terminals affect Claude Code performance.
#
# Usage:
#   ./benchmark.sh                  # Run 3 iterations (default)
#   ./benchmark.sh --iterations 5   # Run 5 iterations
#   ./benchmark.sh --prompt "..."   # Custom prompt
#
# Run this script in each terminal you want to compare:
#   ClaudyBro, Terminal.app, iTerm2, Warp, Alacritty, etc.
# Results are saved to /tmp/claudybro/benchmarks/ for comparison.

set -euo pipefail

# ── Config ───────────────────────────────────────────────────────────
ITERATIONS=3
PROMPT="Explain the concept of backpressure in stream processing in exactly 3 paragraphs. Be detailed and technical."
RESULTS_DIR="/tmp/claudybro/benchmarks"
TERMINAL_NAME="${TERM_PROGRAM:-unknown}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
CSV_FILE="${RESULTS_DIR}/results.csv"
REPORT_FILE="${RESULTS_DIR}/report_${TERMINAL_NAME}_${TIMESTAMP}.txt"

# ── Parse args ───────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --iterations|-n) ITERATIONS="$2"; shift 2 ;;
        --prompt|-p)     PROMPT="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--iterations N] [--prompt \"...\"]"
            echo "  Run in each terminal to compare Claude Code performance."
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Timing function ──────────────────────────────────────────────────
# Use gdate for nanoseconds if available, else fall back to seconds
if command -v gdate &>/dev/null; then
    now_ms() { echo $(( $(gdate +%s%N) / 1000000 )); }
    PRECISION="ms"
elif [[ "$(uname)" == "Darwin" ]]; then
    # macOS python3 fallback for millisecond precision
    if command -v python3 &>/dev/null; then
        now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
        PRECISION="ms"
    else
        now_ms() { echo $(( $(date +%s) * 1000 )); }
        PRECISION="s"
    fi
else
    now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
    PRECISION="ms"
fi

# ── Prerequisite check ───────────────────────────────────────────────
if ! command -v claude &>/dev/null; then
    echo "Error: 'claude' command not found in PATH."
    echo "Install Claude Code first: https://claude.ai/code"
    exit 1
fi

mkdir -p "$RESULTS_DIR"

# ── CSV header ───────────────────────────────────────────────────────
if [[ ! -f "$CSV_FILE" ]]; then
    echo "terminal,iteration,ttft_ms,total_ms,bytes,throughput_bps,cpu_peak" > "$CSV_FILE"
fi

# ── Single test run ──────────────────────────────────────────────────
run_single_test() {
    local iteration=$1
    local output_file
    output_file=$(mktemp /tmp/claudybro/bench_output_XXXX)
    local ttft_file
    ttft_file=$(mktemp /tmp/claudybro/bench_ttft_XXXX)
    local cpu_file
    cpu_file=$(mktemp /tmp/claudybro/bench_cpu_XXXX)

    # Start CPU monitor for the terminal process in background
    local term_pid=$$
    (
        peak_cpu=0
        while kill -0 $term_pid 2>/dev/null && [[ -f "$cpu_file" ]]; do
            # Sample parent terminal process CPU
            cpu=$(ps -p "$PPID" -o %cpu= 2>/dev/null | tr -d ' ' || echo "0")
            cpu_int=${cpu%.*}
            if (( cpu_int > peak_cpu )); then
                peak_cpu=$cpu_int
                echo "$peak_cpu" > "$cpu_file"
            fi
            sleep 0.5
        done
    ) &
    local cpu_monitor_pid=$!

    # Measure total time + TTFT
    local start_ms
    start_ms=$(now_ms)

    # Pipe through a reader that captures time-to-first-byte
    claude -p "$PROMPT" 2>/dev/null | {
        local first=true
        while IFS= read -r -n 1 char; do
            if $first; then
                now_ms > "$ttft_file"
                first=false
            fi
            printf '%s' "$char"
        done
    } > "$output_file"

    local end_ms
    end_ms=$(now_ms)

    # Stop CPU monitor
    kill "$cpu_monitor_pid" 2>/dev/null || true
    wait "$cpu_monitor_pid" 2>/dev/null || true

    # Calculate metrics
    local total_ms=$(( end_ms - start_ms ))
    local bytes
    bytes=$(wc -c < "$output_file" | tr -d ' ')

    local ttft_ms=0
    if [[ -s "$ttft_file" ]]; then
        local ttft_end
        ttft_end=$(cat "$ttft_file")
        ttft_ms=$(( ttft_end - start_ms ))
    fi

    local throughput_bps=0
    if (( total_ms > 0 )); then
        throughput_bps=$(( bytes * 1000 / total_ms ))
    fi

    local cpu_peak=0
    if [[ -s "$cpu_file" ]]; then
        cpu_peak=$(cat "$cpu_file")
    fi

    # Output results
    echo "${TERMINAL_NAME},${iteration},${ttft_ms},${total_ms},${bytes},${throughput_bps},${cpu_peak}" >> "$CSV_FILE"

    # Print iteration result
    printf "  Run %d: TTFT=%dms  Total=%dms  Bytes=%d  Throughput=%d B/s  CPU Peak=%d%%\n" \
        "$iteration" "$ttft_ms" "$total_ms" "$bytes" "$throughput_bps" "$cpu_peak"

    # Cleanup
    rm -f "$output_file" "$ttft_file" "$cpu_file"

    # Return values via globals (bash limitation)
    _TTFT_MS=$ttft_ms
    _TOTAL_MS=$total_ms
    _BYTES=$bytes
    _THROUGHPUT=$throughput_bps
    _CPU_PEAK=$cpu_peak
}

# ── Main benchmark ───────────────────────────────────────────────────
echo "╔══════════════════════════════════════════════════════════╗"
echo "║       ClaudyBro Terminal Performance Benchmark          ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
echo "Terminal:    $TERMINAL_NAME"
echo "Iterations:  $ITERATIONS"
echo "Precision:   $PRECISION"
echo "Prompt:      ${PROMPT:0:60}..."
echo "Results:     $CSV_FILE"
echo ""
echo "Running benchmark..."
echo "────────────────────────────────────────────────────────────"

sum_ttft=0
sum_total=0
sum_bytes=0
sum_throughput=0
max_cpu=0

for i in $(seq 1 "$ITERATIONS"); do
    run_single_test "$i"
    sum_ttft=$(( sum_ttft + _TTFT_MS ))
    sum_total=$(( sum_total + _TOTAL_MS ))
    sum_bytes=$(( sum_bytes + _BYTES ))
    sum_throughput=$(( sum_throughput + _THROUGHPUT ))
    if (( _CPU_PEAK > max_cpu )); then
        max_cpu=$_CPU_PEAK
    fi

    # Brief pause between iterations
    if (( i < ITERATIONS )); then
        sleep 2
    fi
done

# ── Report ───────────────────────────────────────────────────────────
avg_ttft=$(( sum_ttft / ITERATIONS ))
avg_total=$(( sum_total / ITERATIONS ))
avg_bytes=$(( sum_bytes / ITERATIONS ))
avg_throughput=$(( sum_throughput / ITERATIONS ))

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  RESULTS: $TERMINAL_NAME"
echo "════════════════════════════════════════════════════════════"
echo ""
printf "  Avg Time-to-First-Token:  %d ms\n" "$avg_ttft"
printf "  Avg Total Completion:     %d ms\n" "$avg_total"
printf "  Avg Response Size:        %d bytes\n" "$avg_bytes"
printf "  Avg Throughput:           %d B/s\n" "$avg_throughput"
printf "  Peak Terminal CPU:        %d%%\n" "$max_cpu"
echo ""
echo "────────────────────────────────────────────────────────────"
echo "  Results appended to: $CSV_FILE"
echo "  Run this script in other terminals to compare!"
echo ""
echo "  To view comparison:"
echo "    column -t -s',' $CSV_FILE"
echo "════════════════════════════════════════════════════════════"

# Save report
{
    echo "Terminal: $TERMINAL_NAME"
    echo "Date: $(date)"
    echo "Iterations: $ITERATIONS"
    echo "Avg TTFT: ${avg_ttft}ms"
    echo "Avg Total: ${avg_total}ms"
    echo "Avg Throughput: ${avg_throughput} B/s"
    echo "Peak CPU: ${max_cpu}%"
} > "$REPORT_FILE"

echo "Report saved to: $REPORT_FILE"
