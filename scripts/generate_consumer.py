#!/usr/bin/env python3
"""生成只链接指定 XCFramework 的独立 Objective-C 消费工程。"""
import argparse
import hashlib
import json
import shutil
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--framework', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
a = parser.parse_args()
root = Path(__file__).resolve().parents[1]
framework = a.framework.resolve()
if not (framework / 'Info.plist').is_file():
    parser.error('framework must be an existing XCFramework')
out = a.output.resolve()
out.mkdir(parents=True, exist_ok=False)
shutil.copytree(root / 'Demo', out / 'Demo')
objects = {}
def obj(key, isa, **fields):
    uid = hashlib.sha256(key.encode()).hexdigest()[:24].upper()
    objects[uid] = dict(isa=isa, **fields)
    return uid
def serialize(value, indent=0):
    tab = '\t' * indent
    if isinstance(value, dict):
        return '{\n' + ''.join(tab+'\t'+json.dumps(k)+' = '+serialize(v,indent+1)+';\n' for k,v in value.items()) + tab + '}'
    if isinstance(value, list):
        return '(\n' + ''.join(tab+'\t'+serialize(v,indent+1)+',\n' for v in value) + tab + ')'
    return json.dumps(str(value), ensure_ascii=False)
def file(path, kind, tree='<group>'):
    return obj('file:'+path, 'PBXFileReference', path=path, sourceTree=tree, lastKnownFileType=kind)
def phase(key, isa, refs):
    return obj(key,isa,buildActionMask=2147483647,files=refs,runOnlyForDeploymentPostprocessing=0)
refs=[]; sources=[]
for p in sorted((out/'Demo').rglob('*')):
    if p.suffix not in ('.m','.h'): continue
    rel=p.relative_to(out).as_posix()
    r=file(rel,'sourcecode.c.objc' if p.suffix=='.m' else 'sourcecode.c.h');refs.append(r)
    if p.suffix=='.m':sources.append(obj('build:'+rel,'PBXBuildFile',fileRef=r))
licenses=[]
for p in (out/'Demo/Bridge/LICENSE.txt',out/'Demo/Bridge/COPYRIGHT'):
    if p.exists():
        r=file(p.relative_to(out).as_posix(),'text');refs.append(r);licenses.append(obj('license:'+str(p),'PBXBuildFile',fileRef=r))
xc=file(str(framework),'wrapper.xcframework','<absolute>');refs.append(xc)
product=obj('product','PBXFileReference',path='OfflineToolConsumer.app',explicitFileType='wrapper.application',sourceTree='BUILT_PRODUCTS_DIR')
configs=[]
for name in ('Debug','Release'):
    settings=dict(CLANG_ENABLE_MODULES='YES',CLANG_ENABLE_OBJC_ARC='YES',SDKROOT='iphoneos',
        IPHONEOS_DEPLOYMENT_TARGET='15.0',SUPPORTED_PLATFORMS='iphoneos iphonesimulator',
        PRODUCT_NAME='OfflineToolConsumer',PRODUCT_BUNDLE_IDENTIFIER='com.offline.tool.managed.consumer',
        GENERATE_INFOPLIST_FILE='NO',INFOPLIST_FILE='Demo/Info.plist',
        HEADER_SEARCH_PATHS=['$(inherited)','$(SRCROOT)/Demo/Bridge'],
        LD_RUNPATH_SEARCH_PATHS=['$(inherited)','@executable_path/Frameworks'],
        GCC_OPTIMIZATION_LEVEL='0' if name=='Debug' else 's',GCC_C_LANGUAGE_STANDARD='gnu11',
        TARGETED_DEVICE_FAMILY='1,2',CODE_SIGN_STYLE='Automatic')
    configs.append(obj('config:'+name,'XCBuildConfiguration',name=name,buildSettings=settings))
configlist=obj('configs','XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
target=obj('target','PBXNativeTarget',name='OfflineToolConsumer',productName='OfflineToolConsumer',
    productReference=product,productType='com.apple.product-type.application',buildConfigurationList=configlist,
    buildPhases=[phase('sources','PBXSourcesBuildPhase',sources),
        phase('frameworks','PBXFrameworksBuildPhase',[obj('link','PBXBuildFile',fileRef=xc)]),
        phase('resources','PBXResourcesBuildPhase',licenses),
        obj('embed','PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='',dstSubfolderSpec=10,
            name='Embed Candidate',runOnlyForDeploymentPostprocessing=0,
            files=[obj('embed:xc','PBXBuildFile',fileRef=xc,settings={'ATTRIBUTES':['CodeSignOnCopy','RemoveHeadersOnCopy']})])],
    buildRules=[],dependencies=[])
products=obj('products','PBXGroup',name='Products',sourceTree='<group>',children=[product])
main=obj('main','PBXGroup',sourceTree='<group>',children=refs+[products])
project=obj('project','PBXProject',attributes={'LastUpgradeCheck':'1600'},buildConfigurationList=configlist,
    compatibilityVersion='Xcode 14.0',developmentRegion='en',knownRegions=['en','Base'],mainGroup=main,
    productRefGroup=products,projectDirPath='',projectRoot='',targets=[target])
proj=out/'OfflineToolConsumer.xcodeproj';proj.mkdir()
(proj/'project.pbxproj').write_text('// !$*UTF8*$!\n'+serialize(dict(archiveVersion=1,classes={},objectVersion=56,objects=objects,rootObject=project))+'\n')
scheme=proj/'xcshareddata/xcschemes/OfflineToolConsumer.xcscheme';scheme.parent.mkdir(parents=True)
br=f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="OfflineToolConsumer.app" BlueprintName="OfflineToolConsumer" ReferencedContainer="container:OfflineToolConsumer.xcodeproj"/>'
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{br}</BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB"><BuildableProductRunnable runnableDebuggingMode="0">{br}</BuildableProductRunnable></LaunchAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>
''')
(out/'consumption.json').write_text(json.dumps({'framework':str(framework),'sdk_sources_compiled':False,'bundle':'com.offline.tool.managed.consumer','minimum_ios':'15.0','demo_inputs':{str(p.relative_to(out)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((out/'Demo').rglob('*')) if p.is_file()}},indent=2))
print(proj)
