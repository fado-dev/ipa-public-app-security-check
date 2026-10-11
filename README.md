# public-app-security-check

IPA注意喚起（2026-10-09）／JPCERT/CC AT-2026-0030 に基づく、外部公開アプリケーションの緊急セキュリティ点検スキル。

## インストール方法

### Claude Code
```
mkdir -p ~/.claude/skills
cp -r public-app-security-check ~/.claude/skills/
```
プロジェクト単位で使う場合は `.claude/skills/public-app-security-check/` に置く。

### Cowork（Claude デスクトップアプリ）
設定 → スキル から `public-app-security-check` フォルダ（または zip）を追加する。

## 使い方

対象リポジトリや環境を開いた状態で、以下のように依頼する。

- 「公開アプリのセキュリティチェックをして」
- 「IPAの注意喚起に沿って点検して」
- 「このサービスを public-app-security-check で点検して」

点検結果は `security-check-YYYYMMDD.md` として出力される。

## 参考

- https://www.ipa.go.jp/security/security-alert/2026/alert20261009.html
- https://www.jpcert.or.jp/at/2026/at260030.html
