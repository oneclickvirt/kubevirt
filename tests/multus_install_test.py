"""Run the installer against a disposable K3s filesystem and command stub."""
import json,os,pathlib,subprocess,tempfile,unittest

ROOT=pathlib.Path(__file__).resolve().parents[1]
class InstallMultusTest(unittest.TestCase):
    def test_persistent_entry_and_paths(self):
        with tempfile.TemporaryDirectory(prefix="multus quote' space ") as temp:
            root=pathlib.Path(temp);data=root/'k3s';cni=data/'data/cni';conf=data/'agent/etc/cni/net.d';commands=root/'commands'
            for p in (cni,conf,commands):p.mkdir(parents=True)
            for name in ('bridge','static'):
                binary=cni/('real-'+name);binary.write_text('#!/bin/sh\nexit 0\n');binary.chmod(0o755);(cni/name).symlink_to(binary)
            primary={'cniVersion':'1.0.0','name':'cbr0','plugins':[{'type':'flannel'},{'type':'portmap','capabilities':{'portMappings':True}}]}
            (conf/'10-flannel.conflist').write_text(json.dumps(primary))
            stub=commands/'k3s';stub.write_text('''#!/usr/bin/env python3
import json,os,pathlib,sys
p=pathlib.Path(os.environ['CAPTURE']);args=sys.argv[1:]
if args[:3]==['kubectl','apply','-f']:p.write_bytes(pathlib.Path(args[3]).read_bytes())
elif args==['kubectl','-n','kube-system','rollout','status','daemonset/kube-multus-ds','--timeout=240s']:pass
else:raise SystemExit(77)
''');stub.chmod(0o755)
            env=os.environ|{'PATH':str(commands)+os.pathsep+os.environ['PATH'],'K3S_DATA_DIR':str(data),'CAPTURE':str(root/'applied.json')}
            result=subprocess.run(['bash',str(ROOT/'scripts/install_multus.sh')],env=env,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            target=conf/'00-multus-oneclickvirt.conf';config=json.loads(target.read_text());self.assertEqual(config['binDir'],str(cni));self.assertTrue(config['capabilities']['portMappings'])
            document=json.loads((root/'applied.json').read_text());daemon=next(x for x in document['items'] if x['kind']=='DaemonSet');volumes=daemon['spec']['template']['spec']['volumes'];mounts=daemon['spec']['template']['spec']['containers'][0]['volumeMounts']
            self.assertTrue(any(v.get('hostPath',{}).get('path')==str(data/'data') for v in volumes));self.assertTrue(any(v['mountPath']==str(data/'data') for v in mounts))
            confmap=next(x for x in document['items'] if x['kind']=='ConfigMap');self.assertEqual(json.loads(confmap['data']['daemon-config.json'])['multusMasterCNI'],'10-flannel.conflist')
            # Emulate the upstream shutdown action. The remaining first CNI
            # entry must still call Multus, so early Pods cannot bypass it.
            automatic=conf/'00-multus.conf';automatic.write_text('{}');automatic.unlink()
            first=sorted(p for p in conf.iterdir() if p.suffix in ('.conf','.conflist'))[0]
            self.assertEqual(first,target);self.assertEqual(json.loads(first.read_text())['type'],'multus-shim')
            result=subprocess.run(['bash',str(ROOT/'scripts/install_multus.sh')],env=env,capture_output=True,text=True);self.assertEqual(result.returncode,0,result.stderr)
            target.write_text('{"ownedBy":"someone-else"}')
            result=subprocess.run(['bash',str(ROOT/'scripts/install_multus.sh')],env=env,capture_output=True,text=True);self.assertNotEqual(result.returncode,0);self.assertEqual(json.loads(target.read_text()),{'ownedBy':'someone-else'})
            # Corrupt a local manifest: no Kubernetes mutation is accepted.
            bad=root/'bad.json';bad.write_text('{}');capture=root/'applied.json';capture.unlink()
            env['MULTUS_MANIFEST_FILE']=str(bad)
            result=subprocess.run(['bash',str(ROOT/'scripts/install_multus.sh')],env=env,capture_output=True,text=True);self.assertNotEqual(result.returncode,0);self.assertFalse(capture.exists())

if __name__=='__main__':unittest.main()
