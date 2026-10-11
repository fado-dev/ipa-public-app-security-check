# ipa-public-app-security-check

IPA 注意喚起「不正アクセスによる漏えい等の事案を踏まえ、速やかに実施すべき対策等について」（2026-10-09）と
JPCERT/CC 注意喚起（JPCERT-AT-2026-0030）に基づいて、外部公開アプリケーションの緊急セキュリティ点検と、
CSIRT/CERT 観点でのインシデント対応チェックを行う Claude 用スキルです。

Claude Code / Claude Cowork で動作し、対象リポジトリや環境を読み取って点検し、経営者向けサマリー付きの Markdown レポートを出力します。

## 何をするか

IPA の注意喚起と同じ 3 領域に「対応体制」を加えた 4 領域を、「点検（異常の有無）」と「強化策（異常がなくても検討）」に分けて確認します。
異常が見つかった場合は、CSIRT の対応フロー（検知・トリアージ → 証拠保全 → 封じ込め → 根絶 → 復旧 → 影響範囲特定 → 報告・通知 → 事後対応）に沿ってチェックを進めます。

| 領域 | 点検 | 強化策 |
|---|---|---|
| ① 外部公開アプリ | 棚卸し、未適用パッチ、ログの異常（IOC 照合）、アカウント・権限の異常、設定不備 | 公開範囲縮小、MFA、API レート制限、トークン管理、ログ保持 |
| ② 利用外部サービス | ログ確認手段、ログイン異常、不審アカウント、API 連携、クラウド IAM | MFA、アカウント棚卸し、権限最小化、監査ログ |
| ③ 保有データ | 個人情報を含むデータストア、期限超過データ、本番データのコピー、影響範囲の即答可否 | 保有要否の再検討、暗号化、アクセスログ |
| ④ 対応体制 | 連絡網、検知・判断基準、証拠保全手順、封じ込め権限、バックアップ、報告先と期限、脅迫対応方針、机上演習 | — |

## 構成

```
public-app-security-check/
├── SKILL.md                      # 手順（Claude が読む本体）
├── README.md / LICENSE (MIT)
├── examples/
│   └── sample-access.log         # scan_logs.sh の動作確認用
├── references/
│   ├── checklist.md              # IPA/JPCERT の点検・強化策の全項目チェックリスト
│   ├── ioc.md                    # 不審 IP・User-Agent・手口別の痕跡（scan_logs.sh が読み込む）
│   ├── incident-response.md      # CSIRT 対応チェック（平時の準備 26 項目、フェーズ別 55 項目、報告先・期限）
│   └── report-template.md        # レポート雛形
└── scripts/                      # すべて bash のみ・読み取り専用
    ├── scan_logs.sh              # アクセスログの IOC 照合・不審パス・バースト・エラー率集計（nginx/Apache/ALB、.gz 可）
    ├── find_webshell.sh          # 最近作成・変更された .war/.jsp/.php 等と危険関数の検出
    ├── inventory_endpoints.sh    # IaC・ルーティング定義から公開エンドポイント候補を抽出
    └── check_persistence.sh      # Linux サーバの永続化痕跡（cron, systemd, SSH 鍵, 不審プロセス, ログ消去）
```

## インストール

### Claude Code

```bash
# ユーザー全体で使う
git clone https://github.com/fado-dev/ipa-public-app-security-check.git \
  ~/.claude/skills/public-app-security-check

# または、プロジェクト単位で使う
git clone https://github.com/fado-dev/ipa-public-app-security-check.git \
  .claude/skills/public-app-security-check
```

### Claude Cowork（デスクトップアプリ）

このリポジトリを zip でダウンロードし、設定 → スキル からフォルダを追加してください。

## 使い方

対象リポジトリや環境を開いた状態で、次のように依頼します。

- 「公開アプリのセキュリティチェックをして」
- 「IPA の注意喚起に沿って点検して」
- 「CSIRT 観点でインシデント対応体制を点検して」
- 「不審なアクセスが見つかった。初動を確認して」

対象・本番環境へのアクセス可否・現在の状況（平時 / 侵害の疑いあり）・レポートに記載する組織名を確認したうえで点検が始まり、
`security-check-YYYYMMDD.md` が出力されます。
リポジトリや設定から確認できない項目は「要ヒアリング」として担当者向けの質問リストにまとめられます。

スクリプトは単体でも使えます。

```bash
# アクセスログの IOC 照合と集計（複数ファイル・gz 可、-o で TSV 出力）
scripts/scan_logs.sh -o ./result /var/log/nginx/access.log*

# Web シェル候補（30 日以内に作成・変更）
scripts/find_webshell.sh -d 30 /opt/tomcat/webapps /var/www

# 公開エンドポイント候補の抽出
scripts/inventory_endpoints.sh -o endpoints.md ./my-repo

# サーバの永続化痕跡（侵害が疑われるホスト上、またはマウントしたイメージに -r）
sudo scripts/check_persistence.sh -d 30
```

## 注意

- 断定できない項目は ❓（未確認）として出力され、推測で ✅ にはしません。
- 不審 IP / User-Agent の一致は調査の起点であり、それだけで侵害と結論づけません。
- スクリプトはすべて読み取り専用ですが、対象環境での実行自体がログに残ります。証拠保全が必要な環境では `references/incident-response.md` の手順を先に確認してください。
- 異常が見つかった場合は、IPA の推奨どおりセキュリティインシデントとして扱い、専門ベンダーへの詳細調査依頼を推奨します。
- 報告義務の期限・要否は業種・所在地・契約により異なります。`references/incident-response.md` の期限は一般的な目安であり、法務・顧問弁護士に確認してください。
- 本番ログや認証情報の取り扱いは必要最小限にし、レポートにシークレット値を転記しません。

## 参考

- IPA: https://www.ipa.go.jp/security/security-alert/2026/alert20261009.html
- JPCERT/CC: https://www.jpcert.or.jp/at/2026/at260030.html
- 経済産業省 サイバーセキュリティ経営ガイドライン: https://www.meti.go.jp/policy/netsecurity/mng_guide.html
- JPCERT/CC インシデントハンドリングマニュアル: https://www.jpcert.or.jp/csirt_material/
- NIST SP 800-61 Computer Security Incident Handling Guide

## ライセンス

MIT
