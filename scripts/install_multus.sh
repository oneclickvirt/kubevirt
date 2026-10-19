#!/usr/bin/env bash
# Optional K3s/Flannel secondary networks with a persistent Multus entry.
set -euo pipefail
umask 077
command -v k3s >/dev/null
command -v python3 >/dev/null
data_dir=${K3S_DATA_DIR:-/var/lib/rancher/k3s}
cni_bin=${K3S_CNI_BIN_DIR:-$data_dir/data/cni}
cni_conf=${K3S_CNI_CONF_DIR:-$data_dir/agent/etc/cni/net.d}
[[ "$data_dir" = /* && "$cni_bin" = /* && "$cni_conf" = /* ]]
test -x "$cni_bin/bridge"
test -s "$cni_conf/10-flannel.conflist"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
fetch() {
    curl --fail --silent --show-error --location --connect-timeout 15 \
        --max-time 180 --retry 2 --retry-max-time 360 "$1" -o "$2"
}
if ! test -x "$cni_bin/static"; then
    case "$(uname -m)" in
        x86_64) architecture=amd64 ;;
        aarch64|arm64) architecture=arm64 ;;
        *) echo 'Unsupported CNI plugin architecture' >&2; exit 1 ;;
    esac
    asset="cni-plugins-linux-$architecture-v1.9.1.tgz"
    url=https://github.com/containernetworking/plugins/releases/download/v1.9.1
    fetch "$url/$asset" "$stage/plugins.tgz"
    fetch "$url/$asset.sha256" "$stage/plugins.sha256"
    expected=$(awk 'NR==1 {print $1}' "$stage/plugins.sha256")
    [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]]
    printf '%s  %s\n' "$expected" "$stage/plugins.tgz" | sha256sum -c -
    member=$(tar -tzf "$stage/plugins.tgz" | awk '$0 == "static" || $0 == "./static" {print}')
    test -n "$member"
    tar -xzf "$stage/plugins.tgz" -C "$stage" "$member"
    install -m 755 "$stage/static" "$cni_bin/static"
fi
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
manifest=${MULTUS_MANIFEST_FILE:-$script_dir/multus-k3s.json}
if ! test -f "$manifest"; then
    if test -n "${MULTUS_MANIFEST_FILE:-}"; then
        echo 'Configured Multus manifest is missing' >&2; exit 1
    fi
    manifest=$stage/multus-k3s.json
    fetch https://raw.githubusercontent.com/oneclickvirt/kubevirt/main/scripts/multus-k3s.json "$manifest"
fi
python3 - "$manifest" "$stage/rendered.json" "$data_dir" "$cni_bin" "$cni_conf" <<'PY'
import hashlib,json,pathlib,sys
source,output,data_dir,cni_bin,cni_conf=sys.argv[1:]
primary=json.loads((pathlib.Path(cni_conf)/'10-flannel.conflist').read_text())
assert all(p.get('type') not in ('multus','multus-shim') for p in primary.get('plugins',[primary])), 'Recursive primary CNI rejected'
existing=pathlib.Path(cni_conf)/'00-multus-oneclickvirt.conf'
if existing.exists():assert json.loads(existing.read_text()).get('oneclickvirtManaged')=='boot-safe-v1', 'Unmanaged CNI entry preserved'
raw=pathlib.Path(source).read_bytes()
assert hashlib.sha256(raw).hexdigest()=='3b4b986138ecfaf884bd5bea30572689d10918228b65fe8c2dbcc2f445cf243a', 'Multus manifest checksum mismatch'
document=json.loads(raw)
paths={'/var/lib/rancher/k3s':data_dir,'/var/lib/rancher/k3s/data':data_dir+'/data','/var/lib/rancher/k3s/data/cni':cni_bin,'/var/lib/rancher/k3s/agent/etc/cni/net.d':cni_conf}
def rewrite(obj):
    if isinstance(obj,dict):return {k:rewrite(v) for k,v in obj.items()}
    if isinstance(obj,list):return [rewrite(v) for v in obj]
    return paths.get(obj,obj) if isinstance(obj,str) else obj
document=rewrite(document)
for item in document['items']:
    if item['kind']=='ConfigMap' and item['metadata']['name']=='multus-daemon-config':
        conf=json.loads(item['data']['daemon-config.json']);conf['binDir']=cni_bin
        item['data']['daemon-config.json']=json.dumps(conf)
pathlib.Path(output).write_text(json.dumps(document))
PY
k3s kubectl apply -f "$stage/rendered.json"
k3s kubectl -n kube-system rollout status daemonset/kube-multus-ds --timeout=240s
python3 - "$cni_conf" "$cni_bin" <<'PY'
import json,os,pathlib,sys,tempfile
directory=pathlib.Path(sys.argv[1]);primary=json.loads((directory/'10-flannel.conflist').read_text())
plugins=primary.get('plugins',[primary])
assert plugins and all(p.get('type') not in ('multus','multus-shim') for p in plugins), 'Recursive primary CNI rejected'
capabilities={k:True for p in plugins for k,v in p.get('capabilities',{}).items() if v is True}
config={'cniVersion':primary.get('cniVersion','0.3.1'),'name':'multus-cni-network','type':'multus-shim',
        'clusterNetwork':'/host/etc/cni/net.d/10-flannel.conflist','binDir':sys.argv[2],
        'logLevel':'error','logToStderr':True,'capabilities':capabilities,'oneclickvirtManaged':'boot-safe-v1'}
target=directory/'00-multus-oneclickvirt.conf'
if target.exists():assert json.loads(target.read_text()).get('oneclickvirtManaged')=='boot-safe-v1', 'Unmanaged CNI entry preserved'
fd,name=tempfile.mkstemp(prefix='.ocv-multus-',dir=directory)
try:
    with os.fdopen(fd,'w') as f:json.dump(config,f);f.write('\n');f.flush();os.fsync(f.fileno())
    os.replace(name,target)
finally:
    if os.path.exists(name):os.unlink(name)
PY
# The daemon removes only 00-multus.conf on shutdown. This separate entry
# remains, making kubelet retry until the host-network daemon is ready.
printf 'Multus installed; persistent CNI entry prevents primary-only boot fallback\n'
