# examples

スクリプトの動作確認用サンプルです。IP・UA は JPCERT 公表の IOC と文書用の例示アドレス（203.0.113.0/24, 198.51.100.0/24）を使っています。

```bash
scripts/scan_logs.sh -b 100 examples/sample-access.log
```

IOC 一致（4 件）、不審パス（`/.env`, `/backup.zip`, `/shell.jsp?cmd=id`）、NoSQL 演算子（`$ne`）、バースト（198.51.100.77）が検出されれば正常です。
