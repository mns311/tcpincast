#!/bin/bash

# --- 設定項目 ---
NOW=$(date '+%Y%m%d_%H%M%S')

APP_NUM="1"
SRU_SIZE="512"
ADV_WIN="44"
LINK_BUF="40"
RTOMIN="200"

ACTSVR_LIST=(8 16 32 48 64) # 80 96 112 128 144 160 176 192 208 224 240 256
REPEAT="20"

MAX_JOBS=$(nproc)

B_LINK_NUM=1
SCRIPT="incast-nearly-serialization.tcl"
OUTPUT="goodput.${NOW}.txt"
RAW_OUTPUT_DIR="raw_results_${NOW}"
COMBINED_RAW_FILE="${RAW_OUTPUT_DIR}/all_results_combined.txt"

COMPLETED_JOBS_FILE="${RAW_OUTPUT_DIR}/completed_jobs.log"

NS_OUT="out.ns"
ET_OUT="out.et"
TCP_OUT="out.tcp"
Q_OUT="out.q"
C_NODE_ID=1
X_NODE_ID=0
TIME_GRAIN=1.0

NS_CMD="ns"
GP_CMD="./a.out"

# --- 必要な変数をエクスポート ---
export SCRIPT APP_NUM ADV_WIN LINK_BUF RTOMIN B_LINK_NUM
export NS_OUT ET_OUT TCP_OUT Q_OUT X_NODE_ID C_NODE_ID TIME_GRAIN
export NS_CMD GP_CMD
export COMPLETED_JOBS_FILE
export RAW_OUTPUT_DIR

# --- スクリプト中断時のクリーンアップ ---
trap "echo '...スクリプトが中断されました。クリーンアップを実行します。'; rm -rf run_*; exit" INT TERM

run_simulation() {
  local ACTSVR=$1
  local SRU=$2
  local seed=$3
  local RUNDIR="run_${ACTSVR}_${SRU}_${seed}"
  mkdir -p "$RUNDIR"

  (
    cd "$RUNDIR"
    "$NS_CMD" ../"$SCRIPT" $APP_NUM $ACTSVR $ADV_WIN $SRU $LINK_BUF $RTOMIN $seed &> /dev/null
    local GP_STATS
    GP_STATS=$(../"$GP_CMD" "$NS_OUT" "$ET_OUT" $X_NODE_ID $B_LINK_NUM $TIME_GRAIN | tail -1)
    local Q_STATS="0\t0"
    if [ -s "$Q_OUT" ]; then
        Q_STATS=$(grep -v '^0' "$Q_OUT" | awk '{len += $2; if ($2 > max) max = $2} END {if (NR>0) printf len/NR "\t" max; else printf "0\t0"}')
    fi
    echo -e "${ACTSVR}\t${seed}\t${GP_STATS}\t${Q_STATS}" > "result.part"
  )

  echo "${ACTSVR}_${SRU}_${seed}" >> "$COMPLETED_JOBS_FILE"
  mv "$RUNDIR" "$RAW_OUTPUT_DIR/"
}
export -f run_simulation

########################################################################
# 初期化
echo "🛠️  初期化処理を開始します..."
mkdir -p "$RAW_OUTPUT_DIR"
cat /dev/null > "$OUTPUT"
cat /dev/null > "$COMPLETED_JOBS_FILE"
echo -e "ACTSVR\tSeed\tGoodput_Mbps\tRTX_Count\tQueueAvg_pkts\tQueueMax_pkts" > "$COMBINED_RAW_FILE"
for SRU in $SRU_SIZE; do
  printf "\tGP_${SRU}KB\tRTX_${SRU}KB\tQ_${SRU}KB\tQ_MAX_${SRU}KB" >> "$OUTPUT"
done
echo "" >> "$OUTPUT"

TOTAL_JOBS=$((${#ACTSVR_LIST[@]} * REPEAT))

# --- 全シミュレーションジョブを投入 ---
echo "🚀 全${TOTAL_JOBS}個のシミュレーションジョブを開始します (最大${MAX_JOBS}並列)..."
for ACTSVR in "${ACTSVR_LIST[@]}"
do
  for SRU in $SRU_SIZE
  do
    for i in $(seq 0 $(($REPEAT - 1)))
    do
      if [[ $(jobs -p | wc -l) -ge $MAX_JOBS ]]; then
        wait -n
      fi
      run_simulation "$ACTSVR" "$SRU" "$i" &
    done
  done
done

# --- 全ジョブの完了を待機 & 進捗表示 ---
echo ""
echo "⏳ 全てのジョブを投入しました。残りのジョブの完了を待っています..."
while [[ $(jobs -p | wc -l) -gt 0 ]]; do
    wait -n
    COMPLETED_JOBS=$(wc -l < "$COMPLETED_JOBS_FILE")
    REMAINING_JOBS=$((TOTAL_JOBS - COMPLETED_JOBS))
    printf "\r  [進捗] %d / %d 個完了 (残り %d 個)" "$COMPLETED_JOBS" "$TOTAL_JOBS" "$REMAINING_JOBS"
done
printf "\r  [進捗] %d / %d 個完了 (残り 0 個)   \n" "$TOTAL_JOBS" "$TOTAL_JOBS"

# --- 全ジョブ完了後にまとめて集計 ---
echo "✅ 全てのシミュレーションが完了しました。"
echo "📊 結果を集計しています..."
find "$RAW_OUTPUT_DIR" -name "result.part" -path "${RAW_OUTPUT_DIR}/run_*" -exec cat {} + >> "$COMBINED_RAW_FILE"

### ### 変更点: ここからソート処理を追加 ### ###
echo "📑 生データファイル ($COMBINED_RAW_FILE) をソートしています..."
{
  # 1. ヘッダー行を読み込んで出力
  IFS= read -r header
  printf '%s\n' "$header"
  # 2. 残りのデータ行を1列目(サーバ数)と2列目(seed値)で数値的にソート
  sort -k1,1n -k2,2n
} < "$COMBINED_RAW_FILE" > "${COMBINED_RAW_FILE}.sorted"
# 3. ソート済みファイルで元のファイルを置き換え
mv "${COMBINED_RAW_FILE}.sorted" "$COMBINED_RAW_FILE"
### ### ソート処理ここまで ### ###

gawk '
  BEGIN { FS="\t" }
  NR > 1 {
    sum_gp[$1] += $3; sum_rtx[$1] += $4; sum_q_avg[$1] += $5
    if ($6 > max_q[$1]) { max_q[$1] = $6 }
    count[$1]++
  }
  END {
    n = asorti(count, sorted_keys, "@ind_num_asc");
    for (i = 1; i <= n; i++) {
      actsvr = sorted_keys[i]
      printf "%s\t%.2f\t%.2f\t%.2f\t%d\n", actsvr, sum_gp[actsvr]/count[actsvr], sum_rtx[actsvr]/count[actsvr], sum_q_avg[actsvr]/count[actsvr], max_q[actsvr]
    }
  }
' "$COMBINED_RAW_FILE" >> "$OUTPUT"

echo "🎉 全ての処理が完了しました。"
echo "最終サマリー: $OUTPUT"
echo "全ての生データ: $COMBINED_RAW_FILE"
echo "各シミュレーションの生ログは ${RAW_OUTPUT_DIR} に保存されています。"