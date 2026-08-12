import re, sys, yaml

src, out = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(src))

doc.setdefault('metadata', {})
doc['metadata']['labels'].setdefault('pipeline/run-id', 'x')
doc['metadata']['labels']['pipeline/run-id'] += '-direct'

container = doc['spec']['tasks'][0]['template']['spec']['containers'][0]

# strip env vars that route to squid / trust squid CA
DROP_ENV = {
    'HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY', 'http_proxy', 'https_proxy', 'no_proxy',
    'SSL_CERT_FILE', 'CURL_CA_BUNDLE', 'REQUESTS_CA_BUNDLE', 'GIT_SSL_CAINFO',
    'PIP_CERT', 'NODE_EXTRA_CA_CERTS', 'UV_CA_BUNDLE', 'CARGO_HTTP_CAINFO',
    'HF_HUB_ENABLE_HF_TRANSFER', 'UV_SSL_CERT_FILE',
}
if 'env' in container:
    container['env'] = [e for e in container['env'] if e.get('name') not in DROP_ENV]
    if not container['env']:
        del container['env']

# blank in-script proxy setup: PROXY=http://squid-cache... → PROXY=
# and comment out apt Acquire:: lines (empty proxy config = direct)
args = container.get('args', [''])
text = args[0]
text = text.replace(
    'PROXY=http://squid-cache.squid.svc.cluster.local:3128', 'PROXY=')
text = re.sub(r'echo "Acquire::\S*Proxy[^;]*;"[^\n]*', '# direct (no proxy)', text)
args[0] = text
container['args'] = args

# keep postStart hooks identical in both variants — the postStart script is
# the same everywhere (JVM trust store, OS CA injection, conditional apt proxy
# that only activates when HTTPS_PROXY is set, which direct runs don't have)
# container.pop('lifecycle', None)

with open(out, 'w') as f:
    yaml.safe_dump(doc, f, default_flow_style=False, sort_keys=False,
                   allow_unicode=True, width=1000000)
