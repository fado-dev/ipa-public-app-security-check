#!/usr/bin/env bash
# check_persistence.sh - Linux サーバ上の永続化・侵害の痕跡を列挙する（読み取り専用。変更は行わない）
#
# 根絶フェーズ (references/incident-response.md IR-26) で使用。侵害が疑われるホスト上で実行するか、
# ディスクイメージをマウントして -r <root> で指定する。root 権限がないと一部は確認できない。
#
# 確認内容:
#   1. 最近作成・変更されたユーザー / sudoers / パスワードなしアカウント / UID 0 の重複
#   2. SSH authorized_keys の内容と更新日時
#   3. cron (system / user) 、systemd unit / timer、rc.local、profile 系の起動スクリプト
#   4. 最近変更された setuid/setgid ファイル、/tmp /dev/shm /var/tmp 内の実行ファイル
#   5. 外部へ接続中のプロセス、リッスンしているポート、削除済みバイナリから実行中のプロセス
#   6. 最近変更された Web ルート・システムバイナリ
#   7. ログの欠落・消去の痕跡（wtmp/btmp/auth.log のサイズ・更新日時）
#
# 使い方:
#   check_persistence.sh [-d <days>] [-r <root>] [-o <outfile>]
#     -d <days>   何日以内の変更を対象にするか（デフォルト: 30）
#     -r <root>   マウントしたディスクイメージのルート（デフォルト: /）。指定時はプロセス・ネットワーク確認をスキップ
#     -o <file>   結果の書き出し先
#
# 注意: 出力には個人名・鍵のコメント等が含まれうる。レポートに転記する際はマスクする。
set -uo pipefail

DAYS=30; ROOT="/"; OUTFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d) DAYS="$2"; shift 2;;
    -r) ROOT="${2%/}/"; shift 2;;
    -o) OUTFILE="$2"; shift 2;;
    -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 1;;
  esac
done
out() { if [[ -n "$OUTFILE" ]]; then tee "$OUTFILE"; else cat; fi; }
LIVE=0; [[ "$ROOT" == "/" ]] && LIVE=1
hr() { echo; echo "== $1 =="; }
ls_t() { ls -la --time-style=long-iso "$@" 2>/dev/null || ls -laT "$@" 2>/dev/null; }

{
  echo "check_persistence.sh  root=$ROOT  期間=${DAYS}日  実行=$(date '+%Y-%m-%d %H:%M:%S %Z')  user=$(id -un)"
  [[ $(id -u) -ne 0 ]] && echo "WARN: root ではないため一部の確認（shadow, 他ユーザーの cron/authorized_keys, プロセス詳細）が不完全"

  hr "1. アカウント"
  echo "-- UID 0 のアカウント（root 以外は要確認）"
  awk -F: '$3==0{print "  "$1}' "${ROOT}etc/passwd" 2>/dev/null
  echo "-- ログインシェルを持つアカウント"
  awk -F: '$7 !~ /(nologin|false|sync|halt|shutdown)$/ {printf "  %-20s uid=%-6s home=%s shell=%s\n", $1,$3,$6,$7}' "${ROOT}etc/passwd" 2>/dev/null
  echo "-- パスワード未設定 / ロックされていないシステムアカウント（shadow 読めれば）"
  awk -F: '($2=="" ){print "  EMPTY PASSWORD: "$1} ($2 !~ /^[!*]/ && $1 !~ /^(root)$/){print "  active: "$1" (lastchg="$3")"}' "${ROOT}etc/shadow" 2>/dev/null || echo "  (shadow 読み取り不可)"
  echo "-- 最近変更されたアカウント関連ファイル"
  find "${ROOT}etc" -maxdepth 1 \( -name passwd -o -name shadow -o -name group -o -name sudoers -o -name gshadow \) -mtime "-$DAYS" -exec ls -la --time-style=long-iso {} \; 2>/dev/null | sed 's/^/  /'
  echo "-- sudoers / sudoers.d の NOPASSWD・ALL"
  grep -rnE 'NOPASSWD|ALL=\(ALL' "${ROOT}etc/sudoers" "${ROOT}etc/sudoers.d" 2>/dev/null | grep -v '^\s*#' | sed 's/^/  /'

  hr "2. SSH authorized_keys（更新日時と鍵のコメント部のみ表示）"
  for h in "${ROOT}root" "${ROOT}home"/*; do
    for k in "$h/.ssh/authorized_keys" "$h/.ssh/authorized_keys2"; do
      [[ -f "$k" ]] || continue
      echo "  $k  ($(ls_t "$k" | awk '{print $6" "$7}'))"
      awk '{c=""; for(i=3;i<=NF;i++) c=c" "$i; print "    "$1" ..."c}' "$k" 2>/dev/null
    done
  done
  grep -nE '^\s*(PermitRootLogin|PasswordAuthentication|AuthorizedKeysFile|PubkeyAuthentication)' "${ROOT}etc/ssh/sshd_config" 2>/dev/null | sed 's/^/  sshd_config: /'

  hr "3. 起動・スケジュール"
  echo "-- system cron"
  for f in "${ROOT}etc/crontab" "${ROOT}etc/cron.d"/*; do
    [[ -f "$f" ]] && { echo "  [$f] $(ls_t "$f" | awk '{print $6" "$7}')"; grep -vE '^\s*(#|$)' "$f" | head -20 | sed 's/^/    /'; }
  done
  echo "-- cron.hourly/daily/weekly/monthly のうち ${DAYS} 日以内に変更されたもの"
  find "${ROOT}etc/cron.hourly" "${ROOT}etc/cron.daily" "${ROOT}etc/cron.weekly" "${ROOT}etc/cron.monthly" -type f -mtime "-$DAYS" 2>/dev/null | sed 's/^/  /'
  echo "-- user crontabs"
  for f in "${ROOT}var/spool/cron/crontabs"/* "${ROOT}var/spool/cron"/*; do
    [[ -f "$f" ]] && { echo "  [$f]"; grep -vE '^\s*(#|$)' "$f" | head -20 | sed 's/^/    /'; }
  done
  echo "-- 最近追加・変更された systemd unit / timer"
  find "${ROOT}etc/systemd" "${ROOT}lib/systemd/system" "${ROOT}usr/lib/systemd/system" "${ROOT}root/.config/systemd" "${ROOT}home"/*/.config/systemd -type f \( -name '*.service' -o -name '*.timer' \) -mtime "-$DAYS" 2>/dev/null | while read -r u; do
    echo "  $u"; grep -E '^\s*(ExecStart|ExecStartPre|OnCalendar|OnBootSec)=' "$u" | sed 's/^/    /'
  done
  echo "-- rc.local / init.d / profile 系の最近の変更"
  find "${ROOT}etc/rc.local" "${ROOT}etc/init.d" "${ROOT}etc/profile" "${ROOT}etc/profile.d" "${ROOT}etc/bash.bashrc" "${ROOT}root/.bashrc" "${ROOT}root/.profile" "${ROOT}home"/*/.bashrc "${ROOT}home"/*/.profile "${ROOT}home"/*/.zshrc "${ROOT}etc/ld.so.preload" -type f -mtime "-$DAYS" 2>/dev/null | sed 's/^/  /'
  [[ -s "${ROOT}etc/ld.so.preload" ]] && { echo "  ⚠️ /etc/ld.so.preload が存在:"; sed 's/^/    /' "${ROOT}etc/ld.so.preload"; }

  hr "4. 不審なファイル"
  echo "-- /tmp /var/tmp /dev/shm 内の実行可能ファイル・スクリプト"
  find "${ROOT}tmp" "${ROOT}var/tmp" "${ROOT}dev/shm" -type f \( -perm -u+x -o -name '*.sh' -o -name '*.py' -o -name '*.pl' -o -name '*.elf' \) 2>/dev/null | head -50 | sed 's/^/  /'
  echo "-- 最近変更された setuid/setgid ファイル"
  find "${ROOT}" -xdev -type f \( -perm -4000 -o -perm -2000 \) -mtime "-$DAYS" 2>/dev/null | head -50 | sed 's/^/  /'
  echo "-- 最近変更されたシステムバイナリ（パッケージ更新の可能性もあるので dpkg -V / rpm -Va で照合）"
  find "${ROOT}bin" "${ROOT}sbin" "${ROOT}usr/bin" "${ROOT}usr/sbin" "${ROOT}usr/local/bin" -type f -mtime "-$DAYS" 2>/dev/null | head -50 | sed 's/^/  /'
  echo "-- 隠しファイル・ディレクトリ（/ 直下、/var, /opt, /usr/local の浅い階層）"
  find "${ROOT}" "${ROOT}var" "${ROOT}opt" "${ROOT}usr/local" -maxdepth 2 -name '.*' ! -name '.' ! -name '..' -mtime "-$DAYS" 2>/dev/null | head -50 | sed 's/^/  /'

  if [[ $LIVE -eq 1 ]]; then
    hr "5. プロセス・ネットワーク（ライブ）"
    echo "-- リッスンしているポート"
    (ss -tulpn 2>/dev/null || netstat -tulpn 2>/dev/null) | sed 's/^/  /' | head -60
    echo "-- 外部へ ESTABLISHED な接続"
    (ss -tnp state established 2>/dev/null || netstat -tnp 2>/dev/null | grep ESTABLISHED) | grep -vE '127\.0\.0\.1|::1' | sed 's/^/  /' | head -60
    echo "-- 削除済みバイナリから実行中のプロセス（メモリ常駐マルウェアの疑い）"
    for p in /proc/[0-9]*; do
      exe=$(readlink "$p/exe" 2>/dev/null) || continue
      [[ "$exe" == *"(deleted)"* ]] && echo "  pid=${p#/proc/} exe=$exe cmd=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null | cut -c1-120)"
    done
    echo "-- /tmp /dev/shm /var/tmp から実行中のプロセス"
    for p in /proc/[0-9]*; do
      exe=$(readlink "$p/exe" 2>/dev/null) || continue
      [[ "$exe" =~ ^/(tmp|dev/shm|var/tmp)/ ]] && echo "  pid=${p#/proc/} exe=$exe"
    done
    echo "-- Web サーバ・DB ユーザーが親のシェル / 不審な子プロセス"
    ps -eo pid,ppid,user,etime,cmd 2>/dev/null | awk '$3 ~ /^(www-data|nginx|apache|tomcat|httpd|node|mysql|postgres)$/ && $5 ~ /(sh|bash|nc|ncat|python|perl|curl|wget|socat|base64)/' | sed 's/^/  /' | head -30
    echo "-- 最近のログイン（last / lastb）"
    last -n 20 2>/dev/null | sed 's/^/  /'
    echo "  -- 失敗ログイン (lastb, root 要)"
    lastb -n 10 2>/dev/null | sed 's/^/  /' || echo "  (lastb 不可)"
  else
    hr "5. プロセス・ネットワーク: ディスクイメージのためスキップ"
  fi

  hr "6. ログの欠落・消去の痕跡"
  for f in "${ROOT}var/log/wtmp" "${ROOT}var/log/btmp" "${ROOT}var/log/auth.log" "${ROOT}var/log/secure" "${ROOT}var/log/syslog" "${ROOT}var/log/messages" "${ROOT}root/.bash_history" "${ROOT}home"/*/.bash_history; do
    [[ -e "$f" ]] || continue
    sz=$(stat -c %s "$f" 2>/dev/null || stat -f %z "$f" 2>/dev/null)
    mt=$(ls_t "$f" | awk '{print $6" "$7}')
    flag=""; [[ "$sz" -eq 0 ]] && flag="  ⚠️ サイズ 0（消去の疑い）"
    [[ -L "$f" ]] && flag="$flag  ⚠️ シンボリックリンク ($(readlink "$f"))"
    echo "  $f  size=$sz  mtime=$mt$flag"
  done
  echo "-- journald の最古エントリ（ローテーションで消えていないか）"
  [[ $LIVE -eq 1 ]] && journalctl --list-boots 2>/dev/null | head -5 | sed 's/^/  /'

  echo
  echo "※ 本スクリプトは変更を行わない。疑わしい項目は削除前に証拠保全（コピー・ハッシュ・取得者・日時）を行い、クリーンイメージからの再構築を基本とする。"
} | out
