#!/usr/bin/env python3
"""冻结输入后生成不可覆盖的本地候选；不改 VERSION 或远端 SPM 身份。"""
import argparse
import hashlib
import json
import os
import plistlib
import subprocess
import time
import zipfile
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('--evidence',type=Path,required=True)
a=parser.parse_args()
root=Path(__file__).resolve().parents[1]
evidence=a.evidence.resolve()
evidence.mkdir(parents=True,exist_ok=True)
inputs=sorted(p for base in ('Sources','Vendor','Resources','Demo','Tests','scripts','OfflineTool.xcodeproj')
    for p in (root/base).rglob('*') if p.is_file() and not any(v in p.parts for v in ('__pycache__','xcuserdata')))
inputs += [root/'VERSION',root/'Package.swift',root/'README.md',root/'LICENSE',root/'THIRD_PARTY_NOTICES.md'] + sorted((root/'docs').glob('*.md'))
manifest={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in inputs}
identity=hashlib.sha256(json.dumps(manifest,sort_keys=True,separators=(',',':')).encode()).hexdigest()
candidate=root/'dist'/('OfflineTool-managed-'+identity[:16])
candidate.mkdir(parents=True,exist_ok=False)
work=root/'build'/('managed-'+identity[:16]);work.mkdir(parents=True,exist_ok=False)
env=os.environ.copy();env['DEVELOPER_DIR']='/Applications/Xcode.app/Contents/Developer'
commands=[]
def run(label,cmd):
    start=time.time();log=work/(label+'.log')
    with log.open('wb') as f:code=subprocess.call(cmd,cwd=root,env=env,stdout=f,stderr=subprocess.STDOUT)
    commands.append({'label':label,'argv':cmd,'start_unix':start,'end_unix':time.time(),'exit':code,'log':str(log)})
    (evidence/'candidate-commands.json').write_text(json.dumps(commands,indent=2))
    if code:raise SystemExit('command failed: '+label+'; '+str(log))
for platform,destination in [('device','generic/platform=iOS'),('simulator','generic/platform=iOS Simulator')]:
    run(platform,['xcodebuild','archive','-project',str(root/'OfflineTool.xcodeproj'),'-scheme','OfflineTool',
        '-configuration','Release','-destination',destination,'-archivePath',str(work/(platform+'.xcarchive')),
        '-derivedDataPath',str(work/(platform+'-build')),'BUILD_LIBRARY_FOR_DISTRIBUTION=YES','SKIP_INSTALL=NO',
        'CODE_SIGNING_ALLOWED=NO','MARKETING_VERSION=0.0.0'])
for platform in ('device','simulator'):
    info=work/(platform+'.xcarchive')/'Products/Library/Frameworks/OfflineTool.framework/Info.plist'
    metadata=plistlib.loads(info.read_bytes())
    metadata['OFTLocalCandidateIdentity']=identity
    metadata['OFTLocalCandidateOnly']=True
    info.write_bytes(plistlib.dumps(metadata))
xc=candidate/'OfflineTool.xcframework'
run('xcframework',['xcodebuild','-create-xcframework',
    '-framework',str(work/'device.xcarchive/Products/Library/Frameworks/OfflineTool.framework'),
    '-framework',str(work/'simulator.xcarchive/Products/Library/Frameworks/OfflineTool.framework'),'-output',str(xc)])
for p in inputs:
    if hashlib.sha256(p.read_bytes()).hexdigest()!=manifest[str(p.relative_to(root))]:
        raise SystemExit('input changed while building: '+str(p))
sourcezip=candidate/'frozen-inputs.zip'
with zipfile.ZipFile(sourcezip,'w',zipfile.ZIP_DEFLATED) as z:
    for p in inputs:z.write(p,str(p.relative_to(root)))
artifact=candidate/'OfflineTool-managed.xcframework.zip'
run('artifact-zip',['ditto','-c','-k','--norsrc','--noextattr','--keepParent',str(xc),str(artifact)])
record={'identity':identity,'local_candidate_only':True,'ios_head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=root,text=True).strip(),
    'inputs':manifest,'minimum_ios':'15.0','marketing_version':'0.0.0','candidate_kind':'local-lifecycle-candidate','version_file_preserved':(root/'VERSION').read_text().strip(),
    'xcframework':str(xc),'xcframework_info':plistlib.loads((xc/'Info.plist').read_bytes()),
    'artifact_zip_sha256':hashlib.sha256(artifact.read_bytes()).hexdigest(),
    'source_zip_sha256':hashlib.sha256(sourcezip.read_bytes()).hexdigest(),
    'xcframework_files':{str(p.relative_to(xc)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(xc.rglob('*')) if p.is_file()},
    'commands':commands}
(candidate/'candidate-manifest.json').write_text(json.dumps(record,indent=2))
(evidence/'candidate-manifest.json').write_text(json.dumps(record,indent=2))
(candidate/'Package.swift').write_text('// swift-tools-version:5.5\nimport PackageDescription\nlet package = Package(name: "OfflineToolManagedCandidate", platforms: [.iOS(.v15)], products: [.library(name: "OfflineTool", targets: ["OfflineTool"])], targets: [.binaryTarget(name: "OfflineTool", path: "OfflineTool.xcframework")])\n')
print(candidate,flush=True)
