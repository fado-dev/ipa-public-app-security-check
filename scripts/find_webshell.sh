#!/usr/bin/env bash
# find_webshell.sh - Web/AP サーバ上の Web シェル候補を列挙する（読み取り専用。削除・変更は行わない）
#
# 確認内容:
#   1. 指定ディレクトリ配下で最近作成・変更された実行可能 Web ファイル (.war .jsp .jspx .php .phtml .asp .aspx .cgi .pl .py .sh .jar)
#   2. 内容に危険な関数・コマンド実行の痕跡を含むファイル (Runtime.exec, ProcessBuilder, eval, system, passthru, shell_exec, base64_decode 等)
#   3. Tomcat 等の自動デプロイ先 (webapps/) にある見覚えのない WAR / 展開ディレクトリ
#
# 使い方:
#   find_webshell.sh [-d <days>] [-o <outfile>] <dir> [<dir>...]
#     -d <days>   何日以内の作成・変更を対象にするか（デフォルト: 90）
#     -o <file>   結果の書き出し先（省略時は標準出力）
#
# 例:
#   find_webshell.sh -d 30 /opt/tomcat/webapps /var/www
#
# 注意: 見つかったファイルは削除せず、references/incident-response.md の「証拠保全」に従いコピーとハッシュを記録する。
set -uo pipefail

DAYS=90; OUTFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) DAYS="$2"; shift 2;;
    -o) OUTFILE="$2"; shift 2;;
    -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    -*) echo "unknown option: $1" >&2; exit 1;;
    *) break;;
  esac
done
[[ $# -ge 1 ]] || { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

out() { if [[ -n "$OUTFILE" ]]; then tee -a "$OUTFILE"; else cat; fi; }
[[ -n "$OUTFILE" ]] && : > "$OUTFILE"

hash_of() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; elif command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1; else echo "-"; fi; }
stat_line() { # path -> mtime, size, owner
  if stat -c '%y %s %U' "$1" >/dev/null 2>&1; then stat -c '%y|%s|%U' "$1"; else stat -f '%Sm|%z|%Su' "$1"; fi
}

EXT_RE='.*\.\(war\|jsp\|jspx\|jspf\|php\|php[3-7]\|phtml\|phar\|asp\|aspx\|ashx\|asmx\|cgi\|pl\|py\|sh\|jar\|class\)'
DANGER_RE='Runtime\.getRuntime\(\)\.exec|ProcessBuilder|getParameter\([^)]*\)[^;]*exec|\beval\(|\bsystem\(|passthru\(|shell_exec\(|popen\(|proc_open\(|pcntl_exec|base64_decode\(|gzinflate\(|str_rot13\(|assert\(|preg_replace\(.*\/e|\$_(GET|POST|REQUEST|COOKIE)\[[^]]*\]\s*\(|cmd\.exe|\/bin\/sh|\/bin\/bash|wscript\.shell|os\.system|subprocess\.|child_process'

{
  echo "find_webshell.sh  対象: $*  / 期間: ${DAYS} 日以内  / 実行: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo
  echo "== 1. 最近作成・変更された実行可能 Web ファイル =="
  found=0
  for d in "$@"; do
    [[ -d "$d" ]] || { echo "  (skip: $d はディレクトリではない)"; continue; }
    while IFS= read -r f; do
      found=1
      IFS='|' read -r mt sz ow <<< "$(stat_line "$f")"
      printf '  %s | %s bytes | %s | sha256:%s\n    %s\n' "$mt" "$sz" "$ow" "$(hash_of "$f")" "$f"
    done < <(find "$d" -type f -iregex "$EXT_RE" -mtime "-$DAYS" 2>/dev/null | sort)
  done
  [[ $found -eq 0 ]] && echo "  該当なし"

  echo
  echo "== 2. 危険な関数・コマンド実行の痕跡を含むファイル（テキスト検索） =="
  found=0
  for d in "$@"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do
      found=1
      printf '  %s\n' "$f"
      grep -nE -m 3 "$DANGER_RE" "$f" 2>/dev/null | cut -c1-200 | sed 's/^/      /'
    done < <(find "$d" -type f \( -iname '*.jsp' -o -iname '*.jspx' -o -iname '*.php*' -o -iname '*.phtml' -o -iname '*.asp' -o -iname '*.aspx' -o -iname '*.cgi' -o -iname '*.pl' -o -iname '*.py' -o -iname '*.sh' \) -size -2M -mtime "-$DAYS" -exec grep -lE "$DANGER_RE" {} + 2>/dev/null | sort)
  done
  [[ $found -eq 0 ]] && echo "  該当なし（正規コードでも検出されるため、内容と配置場所で判断）"

  echo
  echo "== 3. 自動デプロイ先 (webapps 等) の WAR / 展開ディレクトリ =="
  found=0
  for d in "$@"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r w; do
      found=1
      IFS='|' read -r mt sz ow <<< "$(stat_line "$w")"
      printf '  %s | %s | %s\n' "$mt" "$ow" "$w"
    done < <(find "$d" \( -path '*/webapps/*' -o -path '*/deployments/*' -o -path '*/autodeploy/*' -o -path '*/wwwroot/*' \) -maxdepth 4 \( -iname '*.war' -o -type d \) -mindepth 1 2>/dev/null | awk -F/ '{print}' | sort | awk 'NF' | head -200)
  done
  [[ $found -eq 0 ]] && echo "  該当なし（または対象外のディレクトリ）"

  echo
  echo "== 4. 1 行で非常に長い、または難読化が疑われるファイル（長さ 2000 文字以上の行を含む） =="
  found=0
  for d in "$@"; do
    [[ -d "$d" ]] || continue
    while IFS= read -r f; do found=1; printf '  %s\n' "$f"; done < <(find "$d" -type f \( -iname '*.jsp' -o -iname '*.php*' -o -iname '*.asp*' \) -size -2M -mtime "-$DAYS" -exec awk 'length($0)>2000{print FILENAME; exit}' {} \; 2>/dev/null | sort -u)
  done
  [[ $found -eq 0 ]] && echo "  該当なし"

  echo
  echo "※ 見つかったファイルは削除・編集せず、コピーとハッシュを保全したうえで、デプロイ履歴・担当者に照会して正当性を確認する。"
} | out
