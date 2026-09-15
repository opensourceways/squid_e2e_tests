# 生成 direct 变体：剥离全部代理 env，走 pod 默认路由（对照 with-squid 变体）
# 改自 traffic-test/tool/.gen-direct.py：适配多 task vcjob（遍历全部 task），并同步改
# metadata.name（volcano 同名 job 不允许 update/重建冲突）。
import copy, re, sys, yaml

src, out = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(src))

doc.setdefault('metadata', {})
doc['metadata']['name'] += '-direct'
doc['metadata']['labels'].setdefault('pipeline/run-id', 'x')
doc['metadata']['labels']['pipeline/run-id'] += '-direct'

DROP_ENV = {
    'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'no_proxy',
    'SSL_CERT_FILE', 'CURL_CA_BUNDLE', 'REQUESTS_CA_BUNDLE', 'GIT_SSL_CAINFO',
    'PIP_CERT', 'NODE_EXTRA_CA_CERTS', 'UV_CA_BUNDLE', 'CARGO_HTTP_CAINFO',
    'HF_HUB_ENABLE_HF_TRANSFER', 'UV_SSL_CERT_FILE',
}
for task in doc['spec']['tasks']:
    spec = task['template']['spec']
    # task 名同步加后缀，避免与 with-squid 变体的 task 混淆
    if not task.get('name', '').endswith('-direct'):
        task['name'] += '-direct'
    for container in spec.get('containers', []):
        # 剥离路由到 squid / 信任 squid CA 的 env
        if 'env' in container:
            container['env'] = [e for e in container['env'] if e.get('name') not in DROP_ENV]
            if not container['env']:
                del container['env']
        # 脚本内显式代理赋值同样清空；MODE 标记为 direct
        if 'args' in container and container['args']:
            text = container['args'][0]
            text = text.replace('http://squid-cache.squid.svc.cluster.local:3128', '')
            text = re.sub(r'echo "Acquire::\S*Proxy[^;]*;"[^\n]*', '# direct (no proxy)', text)
            container['args'][0] = text
        if 'env' in container or True:
            # MODE env 已随 DROP_ENV 保留（MODE 不在 DROP_ENV），改值即可；若 env 被整删则跳过
            for e in container.get('env', []) or []:
                if e.get('name') == 'MODE':
                    e['value'] = str(e.get('value', '')).replace('-with-squid', '-direct')
        # GOPROXY 属于 go 上游选择，direct 组保留官方 GOPROXY（只剥离 squid 代理层）

with open(out, 'w') as f:
    yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False,
                   allow_unicode=True, width=1000000)
print(f"OK -> {out}")
