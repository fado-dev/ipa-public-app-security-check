# AGENTS.md

このリポジトリは、外部公開アプリケーションの緊急セキュリティ点検と CSIRT 観点のインシデント対応チェックを行うための手順書とスクリプト集です。
特定の AI ツールに依存せず、Codex / Cursor / Gemini CLI / GitHub Copilot などの AI エージェントでも、人手でも使えます。

## エージェント向け指示

1. 最初に `SKILL.md` を読み、その手順（Step 0〜7）に従って点検する。冒頭の YAML フロントマターは Claude 用のメタデータなので、他のツールでは無視してよい。
2. 各ステップで必要になった時点で `references/` 配下を読む（`checklist.md` / `ioc.md` / `incident-response.md` / `report-template.md`）。
3. ログ・ファイルの確認には `scripts/` の bash スクリプトを使う。すべて読み取り専用で、使う前に `--help` で引数を確認する。
4. 結果は `references/report-template.md` に沿って `security-check-YYYYMMDD.md` として出力する。
5. 質問ツールがない環境では、`SKILL.md` の Step 0 の確認事項（対象・本番アクセス可否・平時か侵害の疑いか・組織名と読者・出力先）を通常の対話で質問する。

## 守ること

- 断定できない項目は ❓ とし、推測で ✅ にしない。
- 異常の疑いがある環境では、ログ削除・再起動・ファイル上書きの前に証拠保全を済ませる。
- 本番ログや認証情報の値をレポートに転記しない。
