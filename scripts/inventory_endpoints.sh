#!/usr/bin/env bash
# inventory_endpoints.sh - リポジトリから外部公開エンドポイントの候補を抽出する（読み取り専用）
#
# 抽出対象:
#   - IaC: terraform (aws_lb, aws_api_gateway, cloudfront, route53), wrangler.toml (routes), serverless.yml (http events),
#          docker-compose (ports), Kubernetes (Ingress / Service type LoadBalancer / NodePort), CloudFormation
#   - Web サーバ: nginx (server_name, location), Apache (VirtualHost, ServerName)
#   - アプリのルーティング: Express / Hono / Fastify / Koa, Next.js (app/ pages/ api), Rails (routes.rb), Django (urls.py),
#          Flask/FastAPI (@app.route, @router.get), Spring (@RequestMapping 等), Go (HandleFunc, r.GET), Laravel (routes/)
#   - 管理・デバッグ系の疑いがあるパス (admin, internal, debug, actuator, metrics, swagger, graphql 等) を別枠で強調
#
# 使い方:
#   inventory_endpoints.sh [-o <outfile.md>] <repo-dir> [<repo-dir>...]
#
# 出力は Markdown。Step 1 の一覧表の下書きとして使い、用途・想定利用者・認証方式・担当者は手で埋める。
set -uo pipefail

OUTFILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) OUTFILE="$2"; shift 2;;
    -h|--help) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
    -*) echo "unknown option: $1" >&2; exit 1;;
    *) break;;
  esac
done
[[ $# -ge 1 ]] || { sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

if command -v rg >/dev/null 2>&1; then
  G() { rg -n --no-heading --color never -g '!node_modules' -g '!.git' -g '!vendor' -g '!dist' -g '!build' -g '!*.min.js' -g '!*.lock' "$@" 2>/dev/null; }
else
  G() { grep -rn --exclude-dir={node_modules,.git,vendor,dist,build} --exclude='*.min.js' --exclude='*.lock' -E "$@" 2>/dev/null; }
fi

out() { if [[ -n "$OUTFILE" ]]; then tee "$OUTFILE"; else cat; fi; }

section() { echo; echo "## $1"; echo; }
show() { # title, grep pattern, [glob...]
  local title="$1" pat="$2"; shift 2
  local res
  if command -v rg >/dev/null 2>&1; then
    local globs=(); for g in "$@"; do globs+=(-g "$g"); done
    res=$(G "${globs[@]}" -e "$pat" "${DIRS[@]}" | head -300)
  else
    local incs=(); for g in "$@"; do incs+=(--include="$g"); done
    res=$(G "${incs[@]}" "$pat" "${DIRS[@]}" | head -300)
  fi
  [[ -z "$res" ]] && return 0
  echo "### $title"; echo; echo '```'; echo "$res" | cut -c1-220; echo '```'; echo
}

DIRS=("$@")
{
  echo "# 公開エンドポイント候補（自動抽出）"
  echo
  echo "- 対象: ${DIRS[*]}"
  echo "- 実行: $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "- 注意: 候補の列挙であり、実際に公開されているかは IaC の適用状態・DNS・WAF/ACL で確認する。"

  section "1. インフラ定義（公開面）"
  show "Terraform: LB / API Gateway / CloudFront / Route53 / Security Group 0.0.0.0/0" \
    'resource "aws_(lb|alb|elb|api_gateway_rest_api|apigatewayv2_api|cloudfront_distribution|route53_record|lambda_function_url|app_runner_service|amplify_app)"|resource "google_(compute_global_forwarding_rule|cloud_run_service|cloud_run_v2_service|api_gateway_api|compute_backend_service)"|resource "azurerm_(app_service|linux_web_app|windows_web_app|application_gateway|api_management)"|resource "cloudflare_(record|worker_route|pages_project|tunnel)"|cidr_blocks\s*=\s*\[\s*"0\.0\.0\.0/0"|"::/0"' '*.tf' '*.tfvars'
  show "Cloudflare Workers / Pages: wrangler.toml routes" \
    '^\s*(routes?|pattern|custom_domain|zone_name|workers_dev)\s*=' 'wrangler.toml' 'wrangler.json' 'wrangler.jsonc'
  show "Serverless Framework: http / httpApi events" \
    '^\s*-\s*(http|httpApi|alb|websocket):|^\s*(path|method):\s' 'serverless.yml' 'serverless.yaml'
  show "docker-compose: ports" \
    '^\s*-\s*"?[0-9.]*:?[0-9]+:[0-9]+"?' 'docker-compose*.yml' 'docker-compose*.yaml' 'compose*.yml' 'compose*.yaml'
  show "Kubernetes: Ingress / LoadBalancer / NodePort / host" \
    'kind:\s*(Ingress|Gateway|HTTPRoute|VirtualService)|type:\s*(LoadBalancer|NodePort)|^\s*-?\s*host:\s' '*.yaml' '*.yml'
  show "CloudFormation / SAM: LB / API / Function URL" \
    'Type:\s*AWS::(ElasticLoadBalancingV2::LoadBalancer|ApiGateway::RestApi|ApiGatewayV2::Api|Serverless::Api|Serverless::HttpApi|CloudFront::Distribution|Lambda::Url|Serverless::Function)' '*.yaml' '*.yml' '*.json' '*.template'
  show "nginx: server_name / listen / location" \
    '^\s*(server_name|listen|location)\s' '*.conf' 'nginx*' '*.nginx'
  show "Apache: VirtualHost / ServerName / ServerAlias" \
    '<VirtualHost|^\s*(ServerName|ServerAlias)\s' '*.conf' 'httpd*' '.htaccess'

  section "2. アプリケーションのルーティング"
  show "Node (Express / Hono / Fastify / Koa / NestJS)" \
    '\b(app|router|server|api|r)\.(get|post|put|patch|delete|all|use|route|on)\s*\(\s*['"'"'"`]/|@(Get|Post|Put|Patch|Delete|Controller)\(' '*.js' '*.mjs' '*.cjs' '*.ts' '*.mts'
  show "Next.js / Nuxt / SvelteKit / Remix: ファイルベースルート（API）" \
    'export\s+(async\s+)?function\s+(GET|POST|PUT|PATCH|DELETE)|export\s+default\s+(async\s+)?function\s+handler|defineEventHandler|export\s+const\s+(GET|POST|PUT|PATCH|DELETE|action|loader)\b' '*/app/**/route.ts' '*/app/**/route.js' '*/pages/api/**' '*/server/api/**' '*/routes/**/+server.ts' '*/app/routes/**'
  show "Python (Flask / FastAPI / Django)" \
    '@(app|router|api|bp|blueprint)\.(route|get|post|put|patch|delete|api_route)\(|^\s*(path|re_path|url)\(' '*.py'
  show "Ruby on Rails: routes.rb" \
    '^\s*(resources?|get|post|put|patch|delete|match|namespace|scope|mount|root)\s' 'routes.rb' 'routes/*.rb'
  show "Java / Kotlin (Spring)" \
    '@(RequestMapping|GetMapping|PostMapping|PutMapping|PatchMapping|DeleteMapping|RestController|Controller)\b|@Path\(' '*.java' '*.kt'
  show "Go (net/http / gin / echo / chi / fiber)" \
    '\.(HandleFunc|Handle|GET|POST|PUT|PATCH|DELETE|Any|Group|Route|Get|Post|Put|Patch|Delete)\(\s*"/' '*.go'
  show "PHP (Laravel / Symfony / Slim)" \
    'Route::(get|post|put|patch|delete|any|match|resource|apiResource|group)\(|#\[Route\(|\$app->(get|post|put|patch|delete|any|group)\(' '*.php'
  show "OpenAPI / GraphQL スキーマ" \
    '^(openapi|swagger):|^paths:|^\s*type\s+(Query|Mutation)\b' '*.yaml' '*.yml' '*.json' '*.graphql' '*.gql'

  section "3. 管理・内部・デバッグ系の疑いがあるパス（公開範囲を要確認）"
  show "admin / internal / debug / actuator / metrics / swagger / graphql / console / webhook / cron" \
    '["`'"'"']/?(api/)?(v[0-9]+/)?(admin|internal|private|manage|management|debug|_debug|actuator|metrics|health|status|swagger|api-docs|docs|graphql|graphiql|playground|console|phpmyadmin|adminer|webhook|hooks?|cron|batch|jobs?|export|dump|backup|impersonate|sudo|su)\b' '*.js' '*.mjs' '*.ts' '*.py' '*.rb' '*.go' '*.java' '*.kt' '*.php' '*.tf' '*.yml' '*.yaml' '*.toml' '*.conf'

  section "4. 認証をバイパスしている可能性がある箇所"
  show "認証スキップ・公開指定（public, skipAuth, allowAnonymous, permitAll, csrf disable 等）" \
    '\b(skipAuth|noAuth|public(Route|Endpoint)?|allowAnonymous|AllowAnonymous|permitAll|csrf\(\)\.disable|csrf_exempt|authenticate\s*=\s*false|auth:\s*false|@Public\(|isPublic\s*[:=]\s*true|excludedPaths|unprotected)\b' '*.js' '*.ts' '*.py' '*.rb' '*.go' '*.java' '*.kt' '*.php' '*.yml' '*.yaml'

  section "5. 一覧表（手で埋める）"
  echo
  echo "| # | 名称 | 公開 URL / ポート | 用途 | 想定利用者 | 認証 | 主要構成要素 | ログ所在 / 保持期間 | 担当 |"
  echo "|---|---|---|---|---|---|---|---|---|"
  echo "| 1 | | | | | | | | |"
} | out
