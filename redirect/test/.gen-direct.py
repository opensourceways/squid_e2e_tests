#!/usr/bin/env python3
# 从 squid 注入版 vcjob 生成直连版 vcjob（去掉代理注入，避免双份拷贝）
#
# 背景：redirect/test 下的测试用例是"同一场景跑 squid vs 直连对照"。
# 为避免每个文件手写 squid + direct 两个 task（大量重复 env/卷/脚本），
# 只维护一份 squid 注入版，本脚本自动剥离注入生成 direct 版。
#
# 处理（squid task → direct task）：
#   1. task 名去 -squid 后缀 → -direct
#   2. 删除指向 squid 的代理/CA env：HTTP_PROXY/HTTPS_PROXY/NO_PROXY/SSL_CERT_FILE/
#      CURL_CA_BUNDLE/GIT_SSL_CAINFO 等（直连走系统 CA）
#   3. 移除 squid-ca secret 卷挂载与卷定义
#   4. 脚本内清理 git proxy/sslCAInfo config 行（env 已删，留着只会设空值）
#   5. metadata.name/generateName 加 -direct、pipeline/run-id 加 -direct，避免与 squid 版冲突
#   6. 非 -squid 后缀的 task（如 already-direct 的对照 task）原样保留
#
# 用法:
#   python3 .gen-direct.py <squid-vcjob.yaml> <out-vcjob.yaml>
#   例:  python3 .gen-direct.py 03-git-lfs-vcjob.yaml /tmp/03-git-lfs-direct.yaml
#
# 注意: 生成的 direct 版只是"去掉代理注入"，不带 ghd-proxy/CA 白名单等 url_rewrite 干预，
#       因此被测流量 = 客户端原样直连境外（对照 B 方案的基线）。
import re
import sys
import yaml

src, out = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(src))

# 标记 direct，避免与 squid 版 job 冲突
doc.setdefault('metadata', {})
doc['metadata'].setdefault('labels', {})
doc['metadata']['labels'].setdefault('pipeline/run-id', 'x')
doc['metadata']['labels']['pipeline/run-id'] += '-direct'
if doc['metadata'].get('generateName'):
    doc['metadata']['generateName'] = doc['metadata']['generateName'].rstrip('-') + '-direct-'
if doc['metadata'].get('name'):
    doc['metadata']['name'] = doc['metadata']['name'] + '-direct'

DROP_ENV = {
    'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'no_proxy',
    'SSL_CERT_FILE', 'CURL_CA_BUNDLE', 'REQUESTS_CA_BUNDLE', 'GIT_SSL_CAINFO',
    'PIP_CERT', 'NODE_EXTRA_CA_CERTS', 'UV_CA_BUNDLE', 'CARGO_HTTP_CAINFO',
}

for task in doc['spec']['tasks']:
    if task['name'].endswith('-squid'):
        task['name'] = task['name'][:-len('-squid')] + '-direct'
    spec = task['template']['spec']
    container = spec['containers'][0]

    # 1) 剥掉代理/CA env
    if 'env' in container:
        keep = []
        for e in container['env']:
            name = e.get('name', '')
            if name in DROP_ENV:
                continue
            keep.append(e)
        container['env'] = keep
        if not keep:
            del container['env']

    # 2) 移除 squid-ca 卷挂载与卷定义
    if 'volumeMounts' in container:
        container['volumeMounts'] = [
            v for v in container['volumeMounts'] if v.get('name') != 'squid-ca']
        if not container['volumeMounts']:
            del container['volumeMounts']
    if 'volumes' in spec:
        spec['volumes'] = [v for v in spec['volumes'] if v.get('name') != 'squid-ca']
        if not spec['volumes']:
            del spec['volumes']

    # 3) 脚本内清理 git 代理/CA config 行（env 已删，留着只会设空值）
    args = container.get('args', [''])
    if args and args[0]:
        text = args[0]
        # 3a) 先整块删除"只包着 git proxy/sslCAInfo config 的 if [ -n ... ]; then ... fi"，
        #     避免剥掉 config 行后留下空 then 块（POSIX sh 空 if 块是语法错误）。
        text = re.sub(
            r'\n[ \t]*if \[ -n "\$[A-Z_]+" \]; then'
            r'\n(?:[ \t]*git config --global (?:http|https)\.(?:proxy|sslCAInfo)[^\n]*\n)+'
            r'[ \t]*fi',
            '\n', text)
        # 3b) 兜底：删除散落的 git proxy/sslCAInfo config 行
        #     注意只删 http(s).proxy / http.sslCAInfo，保留 url.<...>.insteadOf（04 的核心行为）
        text = re.sub(r'\n[ \t]*git config --global (?:http|https)\.(?:proxy|sslCAInfo)[^\n]*', '\n', text)
        args[0] = text
        container['args'] = args

with open(out, 'w') as f:
    yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False,
                   allow_unicode=True, width=1000000)
