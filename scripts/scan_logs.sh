#!/usr/bin/env bash
# scan_logs.sh - アクセスログを IOC・不審パス・大量リクエスト・エラー率の観点で集計する（読み取り専用）
#
# 対応形式:
#   - nginx / Apache combined ログ（デフォルト）
#   - AWS ALB アクセスログ（行頭が http/https/h2/ws/wss の場合に自動判定）
#   - gzip 圧縮ファイル (.gz) はそのまま指定可
#   - JSON ログ (Cloudflare Logpush 等) は事前に jq で combined 相当に変換してから渡す（--help 参照）
#
# 使い方:
#   scan_logs.sh [options] <logfile> [<logfile>...]
#   cat access.log | scan_logs.sh -
#
# オプション:
#   -i, --ioc <file>      IOC ファイル（デフォルト: ../references/ioc.md）
#   -t, --top <n>         上位件数（デフォルト: 20）
#   -b, --burst <n>       1 分あたりのリクエスト数がこの値以上の IP を「バースト」として報告（デフォルト: 300）
#   -o, --out <dir>       詳細結果 (CSV) の出力先ディレクトリ（省略時は標準出力のサマリーのみ）
#   -h, --help
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOC_FILE="${SCRIPT_DIR}/../references/ioc.md"
TOP=20
BURST=300
OUT=""

usage() { sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; cat <<'EOF'

JSON ログの変換例 (Cloudflare Logpush):
  jq -r '"\(.ClientIP) - - [\(.EdgeStartTimestamp)] \"\(.ClientRequestMethod) \(.ClientRequestURI) HTTP/1.1\" \(.EdgeResponseStatus) 0 \"-\" \"\(.ClientRequestUserAgent)\""' logs.json > access.log
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--ioc) IOC_FILE="$2"; shift 2;;
    -t|--top) TOP="$2"; shift 2;;
    -b|--burst) BURST="$2"; shift 2;;
    -o|--out) OUT="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    -*) echo "unknown option: $1" >&2; usage; exit 1;;
    *) break;;
  esac
done
[[ $# -ge 1 ]] || { usage; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- IOC の読み込み（ioc.md の ```ioc-ip / ```ioc-ua ブロック） ---
IOC_IP="$TMP/ioc_ip.txt"; IOC_UA="$TMP/ioc_ua.txt"
if [[ -f "$IOC_FILE" ]]; then
  awk '/^```ioc-ip/{f=1;next} /^```/{f=0} f' "$IOC_FILE" | sed 's/#.*//; s/[[:space:]]//g' | grep -v '^$' > "$IOC_IP" || true
  awk '/^```ioc-ua/{f=1;next} /^```/{f=0} f' "$IOC_FILE" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | grep -v '^#' > "$IOC_UA" || true
else
  echo "WARN: IOC file not found: $IOC_FILE (IOC 照合をスキップ)" >&2
  : > "$IOC_IP"; : > "$IOC_UA"
fi

# --- 入力を正規化: ip \t time(YYYY-MM-DD HH:MM) \t method \t path \t status \t ua ---
NORM="$TMP/norm.tsv"
read_input() {
  for f in "$@"; do
    if [[ "$f" == "-" ]]; then cat
    elif [[ "$f" == *.gz ]]; then gzip -dc "$f"
    else cat "$f"; fi
  done
}
read_input "$@" | awk '
function month(m){ return index("JanFebMarAprMayJunJulAugSepOctNovDec", m) ? sprintf("%02d", (index("JanFebMarAprMayJunJulAugSepOctNovDec", m)+2)/3) : "00" }
{
  line=$0
  if (line ~ /^(http|https|h2|ws|wss) /) {
    # ALB: type time elb client:port target:port rp tp rtp st tst rb sb "req" "ua" ...
    n=split(line, a, " ")
    ip=a[4]; sub(/:[0-9]+$/, "", ip)
    t=substr(a[2],1,16); gsub(/T/, " ", t)
    st=a[9]
    # request と ua はダブルクォート内
    m=match(line, /"[^"]*"/); req=substr(line, RSTART+1, RLENGTH-2)
    rest=substr(line, RSTART+RLENGTH)
    m=match(rest, /"[^"]*"/); ua=(m ? substr(rest, RSTART+1, RLENGTH-2) : "-")
    split(req, r, " "); method=r[1]; path=r[2]; sub(/^https?:\/\/[^\/]+/, "", path)
  } else {
    # combined: ip - - [dd/Mon/yyyy:HH:MM:SS +0000] "METHOD PATH PROTO" status bytes "ref" "ua"
    ip=$1
    m=match(line, /\[[^\]]+\]/); ts=substr(line, RSTART+1, RLENGTH-2)
    d=substr(ts,1,2); mo=month(substr(ts,4,3)); y=substr(ts,8,4); hm=substr(ts,13,5)
    t=y "-" mo "-" d " " hm
    rest=substr(line, RSTART+RLENGTH)
    m=match(rest, /"[^"]*"/); req=substr(rest, RSTART+1, RLENGTH-2)
    rest=substr(rest, RSTART+RLENGTH)
    split(rest, s, " "); st=s[1]
    # ua = 最後のクォート
    ua="-"
    if (match(rest, /"[^"]*"[[:space:]]*$/)) ua=substr(rest, RSTART+1, RLENGTH-2); sub(/"[[:space:]]*$/, "", ua)
    split(req, r, " "); method=r[1]; path=r[2]
  }
  if (ip=="" || path=="") next
  gsub(/\t/, " ", ua); gsub(/\t/, " ", path)
  print ip "\t" t "\t" method "\t" path "\t" st "\t" ua
}' > "$NORM"

TOTAL=$(wc -l < "$NORM" | tr -d ' ')
if [[ "$TOTAL" -eq 0 ]]; then echo "解析できる行がありません（形式を確認してください）" >&2; exit 1; fi

[[ -n "$OUT" ]] && mkdir -p "$OUT"
emit() { # name, content via stdin
  if [[ -n "$OUT" ]]; then tee "$OUT/$1.tsv"; else cat; fi
}

hr() { printf '\n== %s ==\n' "$1"; }

echo "scan_logs.sh  対象: $* / 行数: $TOTAL / 期間: $(cut -f2 "$NORM" | sort | head -1) 〜 $(cut -f2 "$NORM" | sort | tail -1)"

hr "ステータスコード分布"
cut -f5 "$NORM" | sort | uniq -c | sort -rn | awk -v t="$TOTAL" '{printf "%8d  %5.1f%%  %s\n", $1, $1*100/t, $2}'
ERR=$(awk -F'\t' '$5 ~ /^[45]/' "$NORM" | wc -l | tr -d ' ')
printf '4xx/5xx 合計: %d (%.1f%%)  ※平時の値と比較すること\n' "$ERR" "$(awk -v e="$ERR" -v t="$TOTAL" 'BEGIN{print e*100/t}')"

hr "IOC 一致: 不審 IP ($(wc -l < "$IOC_IP" | tr -d ' ') 件を照合)"
if [[ -s "$IOC_IP" ]]; then
  awk -F'\t' 'NR==FNR{ioc[$1]=1; next} ($1 in ioc){print}' "$IOC_IP" "$NORM" > "$TMP/ioc_ip_hit.tsv" || true
  if [[ -s "$TMP/ioc_ip_hit.tsv" ]]; then
    echo "❌ 一致あり: $(wc -l < "$TMP/ioc_ip_hit.tsv" | tr -d ' ') 行"
    cut -f1 "$TMP/ioc_ip_hit.tsv" | sort | uniq -c | sort -rn
    echo "--- 一致行（先頭 $TOP 件）"
    head -n "$TOP" "$TMP/ioc_ip_hit.tsv" | emit ioc_ip_hits
    [[ -n "$OUT" ]] && cp "$TMP/ioc_ip_hit.tsv" "$OUT/ioc_ip_hits_all.tsv"
  else echo "✅ 一致なし"; fi
else echo "❓ IOC IP リストが空"; fi

hr "IOC 一致: 不審 User-Agent ($(wc -l < "$IOC_UA" | tr -d ' ') 件を部分一致で照合)"
if [[ -s "$IOC_UA" ]]; then
  awk -F'\t' 'NR==FNR{ua[++n]=$0; next} {for(i=1;i<=n;i++) if (index($6, ua[i])) {print; break}}' "$IOC_UA" "$NORM" > "$TMP/ioc_ua_hit.tsv" || true
  if [[ -s "$TMP/ioc_ua_hit.tsv" ]]; then
    echo "⚠️ 一致あり: $(wc -l < "$TMP/ioc_ua_hit.tsv" | tr -d ' ') 行（正規の監視・バッチの可能性もあるため送信元と内容を確認）"
    cut -f1,6 "$TMP/ioc_ua_hit.tsv" | sort | uniq -c | sort -rn | head -n "$TOP" | emit ioc_ua_hits
  else echo "✅ 一致なし"; fi
else echo "❓ IOC UA リストが空"; fi

hr "不審パス（設定ファイル・バックアップ・Web シェル・スキャン系）"
awk -F'\t' 'BEGIN{IGNORECASE=1}
  $4 ~ /(\.env|\.git\/|\.svn\/|\.htaccess|\.htpasswd|\.DS_Store|phpinfo|wp-config|config\.(php|yml|yaml|json|xml)|\.bak|\.old|\.orig|\.swp|\.sql|\.sql\.gz|\.zip|\.tar|\.tgz|\.7z|\.rar|backup|dump|\.war|\.jsp|\.jspx|\.asp|\.aspx|\.php|shell|cmd=|exec=|command=|\/actuator|\/manager\/html|\/console|\/_debug|\/debug|\/swagger|\/graphql|\/\.aws|\/\.ssh|id_rsa|\/etc\/passwd|\.\.\/|%2e%2e)/ {print}' "$NORM" > "$TMP/susp_path.tsv" || true
if [[ -s "$TMP/susp_path.tsv" ]]; then
  echo "⚠️ $(wc -l < "$TMP/susp_path.tsv" | tr -d ' ') 行。200 系で応答しているものは特に確認:"
  echo "--- パス別（status 200-399 のみ、上位 $TOP）"
  awk -F'\t' '$5 ~ /^[23]/' "$TMP/susp_path.tsv" | cut -f4 | sort | uniq -c | sort -rn | head -n "$TOP" | emit susp_path_2xx
  echo "--- 送信元 IP 別（上位 $TOP）"
  cut -f1 "$TMP/susp_path.tsv" | sort | uniq -c | sort -rn | head -n "$TOP" | emit susp_path_by_ip
  [[ -n "$OUT" ]] && cp "$TMP/susp_path.tsv" "$OUT/susp_path_all.tsv"
else echo "✅ 該当なし"; fi

hr "インジェクション疑い（NoSQL/SQL 演算子をクエリに含む）"
awk -F'\t' 'BEGIN{IGNORECASE=1} $4 ~ /(\$ne|\$gt|\$lt|\$regex|\$where|\$or\[|\[\$|%24ne|%24gt|%24regex|union[+ %]select|information_schema|sleep\(|benchmark\(|waitfor[+ %]delay|or[+ %]1=1|'"'"'[+ %]or[+ %]|--[+ %]|\/\*.*\*\/)/ {print}' "$NORM" > "$TMP/inj.tsv" || true
if [[ -s "$TMP/inj.tsv" ]]; then
  echo "⚠️ $(wc -l < "$TMP/inj.tsv" | tr -d ' ') 行（POST ボディは含まれないため、アプリログ・WAF ログも確認）"
  cut -f1 "$TMP/inj.tsv" | sort | uniq -c | sort -rn | head -n "$TOP" | emit injection_by_ip
  [[ -n "$OUT" ]] && cp "$TMP/inj.tsv" "$OUT/injection_all.tsv"
else echo "✅ 該当なし（GET クエリのみの判定）"; fi

hr "バースト: 1 分あたり ${BURST} リクエスト以上の送信元"
awk -F'\t' '{c[$1 "\t" $2]++} END{for(k in c) if (c[k]>='"$BURST"') print c[k] "\t" k}' "$NORM" | sort -rn | head -n "$TOP" > "$TMP/burst.tsv" || true
if [[ -s "$TMP/burst.tsv" ]]; then
  echo "⚠️ 該当あり（req/min, IP, 分）。CDN・監視・社内 NAT の可能性も考慮"
  emit burst < "$TMP/burst.tsv"
else echo "✅ 該当なし"; fi

hr "送信元 IP 上位 $TOP（総リクエスト）"
cut -f1 "$NORM" | sort | uniq -c | sort -rn | head -n "$TOP" | emit top_ips

hr "4xx/5xx を多く出している送信元 IP 上位 $TOP（探索の疑い）"
awk -F'\t' '$5 ~ /^[45]/ {print $1}' "$NORM" | sort | uniq -c | sort -rn | head -n "$TOP" | emit top_error_ips

hr "認証系エンドポイントへのアクセス上位（login / reset / otp / sms / token）"
awk -F'\t' 'BEGIN{IGNORECASE=1} $4 ~ /(login|signin|auth|reset|forgot|otp|sms|verify|token|session)/ {print $1 "\t" $4}' "$NORM" | sed 's/?.*//' | sort | uniq -c | sort -rn | head -n "$TOP" | emit auth_endpoints

hr "User-Agent 上位 $TOP"
cut -f6 "$NORM" | sort | uniq -c | sort -rn | head -n "$TOP" | emit top_ua

hr "時間帯別リクエスト数（UTC/JST はログの時刻基準。平時と比較）"
cut -f2 "$NORM" | cut -c1-13 | sort | uniq -c | awk '{printf "%s:00  %d\n", $2" "$3, $1}' | tail -n 48

echo
echo "※ 本スクリプトは起点の抽出のみを行う。一致・該当は侵害の証拠ではなく、references/ioc.md と照らして内容を確認すること。"
[[ -n "$OUT" ]] && echo "※ 詳細 TSV を $OUT に出力した。"
exit 0
