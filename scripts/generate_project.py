#!/usr/bin/env python3
"""Regenerate only the standalone SDK project; never rewrite the host project."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
objects = {}


def obj(key, isa, **fields):
    uid = hashlib.sha256(key.encode()).hexdigest()[:24].upper()
    objects[uid] = dict(isa=isa, **fields)
    return uid


def serialize(value, indent=0):
    tab = '\t' * indent
    if isinstance(value, dict):
        return '{\n' + ''.join(tab + '\t' + json.dumps(k) + ' = ' + serialize(v, indent + 1) + ';\n'
                                 for k, v in value.items()) + tab + '}'
    if isinstance(value, list):
        return '(\n' + ''.join(tab + '\t' + serialize(v, indent + 1) + ',\n' for v in value) + tab + ')'
    return json.dumps(str(value), ensure_ascii=False)


def file(path, kind):
    return obj('file:' + path, 'PBXFileReference', path=path, sourceTree='<group>', lastKnownFileType=kind)


def phase(key, isa, refs):
    return obj(key, isa, buildActionMask=2147483647, files=refs, runOnlyForDeploymentPostprocessing=0)


def configurations(key, extra):
    configs = []
    for name in ('Debug', 'Release'):
        settings = dict(CLANG_ENABLE_MODULES='YES', CLANG_ENABLE_OBJC_ARC='YES', SDKROOT='iphoneos',
                        SUPPORTED_PLATFORMS='iphoneos iphonesimulator macosx',
                        IPHONEOS_DEPLOYMENT_TARGET='12.0', MACOSX_DEPLOYMENT_TARGET='10.15',
                        SWIFT_VERSION='5.0', GCC_C_LANGUAGE_STANDARD='gnu11',
                        GCC_OPTIMIZATION_LEVEL='0' if name == 'Debug' else 's',
                        SWIFT_OPTIMIZATION_LEVEL='-Onone' if name == 'Debug' else '-O',
                        DEBUG_INFORMATION_FORMAT='dwarf', ONLY_ACTIVE_ARCH='YES' if name == 'Debug' else 'NO',
                        ENABLE_TESTABILITY='YES', GENERATE_INFOPLIST_FILE='YES', CODE_SIGN_STYLE='Automatic', TARGETED_DEVICE_FAMILY='1,2',
                        GCC_PREPROCESSOR_DEFINITIONS=['$(inherited)', 'DEBUG=1'] if name == 'Debug' else ['$(inherited)'])
        settings.update(extra)
        configs.append(obj(key + name, 'XCBuildConfiguration', name=name, buildSettings=settings))
    return obj(key + 'configs', 'XCConfigurationList', buildConfigurations=configs,
               defaultConfigurationIsVisible=0, defaultConfigurationName='Release')


sources, headers, source_refs = [], [], []
public_headers = {'OfflineTool.h', 'OFTPackageInstaller.h', 'OFTOfflineResourceResolver.h', 'OFTOfflineSchemeHandler.h'}
for path in sorted(list((ROOT / 'Sources').glob('*')) + list((ROOT / 'Vendor/ZIPFoundation/Sources').glob('*.swift'))):
    if path.suffix not in {'.h', '.m', '.swift'}:
        continue
    rel = path.relative_to(ROOT).as_posix()
    ref = file(rel, {'.h': 'sourcecode.c.h', '.m': 'sourcecode.c.objc', '.swift': 'sourcecode.swift'}[path.suffix])
    source_refs.append(ref)
    if path.suffix == '.h':
        if path.name in public_headers:
            headers.append(obj('build:' + rel, 'PBXBuildFile', fileRef=ref, settings={'ATTRIBUTES': ['Public']}))
    else:
        sources.append(obj('build:' + rel, 'PBXBuildFile', fileRef=ref))

framework = obj('product:sdk', 'PBXFileReference', explicitFileType='wrapper.framework',
                path='OfflineTool.framework', sourceTree='BUILT_PRODUCTS_DIR')
privacy = file('Vendor/ZIPFoundation/Sources/Resources/PrivacyInfo.xcprivacy', 'text.xml')
source_refs.append(privacy)
license_ref = file('Resources/ZIPFoundation-LICENSE.txt', 'text')
source_refs.append(license_ref)
webkit = obj('webkit', 'PBXFileReference', path='System/Library/Frameworks/WebKit.framework', sourceTree='SDKROOT', lastKnownFileType='wrapper.framework')
source_refs.append(webkit)
sdk = obj('target:sdk', 'PBXNativeTarget', name='OfflineTool', productName='OfflineTool',
          productReference=framework, productType='com.apple.product-type.framework',
          buildConfigurationList=configurations('sdk', dict(PRODUCT_NAME='OfflineTool',
              PRODUCT_BUNDLE_IDENTIFIER='com.offline.tool', DEFINES_MODULE='YES', SKIP_INSTALL='NO', BUILD_LIBRARY_FOR_DISTRIBUTION='YES',
              INSTALL_PATH='$(LOCAL_LIBRARY_DIR)/Frameworks', DYLIB_INSTALL_NAME_BASE='@rpath',
              CURRENT_PROJECT_VERSION='1', MARKETING_VERSION=(ROOT / 'VERSION').read_text().strip())),
          buildPhases=[phase('sdk.headers', 'PBXHeadersBuildPhase', headers),
                       phase('sdk.sources', 'PBXSourcesBuildPhase', sources),
                       phase('sdk.frameworks', 'PBXFrameworksBuildPhase', [obj('sdk.webkit', 'PBXBuildFile', fileRef=webkit)]),
                       phase('sdk.resources', 'PBXResourcesBuildPhase', [obj('sdk.privacy', 'PBXBuildFile', fileRef=privacy), obj('sdk.license', 'PBXBuildFile', fileRef=license_ref)])], buildRules=[], dependencies=[])

test_sources, test_refs = [], []
for path in sorted((ROOT / 'Tests').glob('*.m')):
    rel = path.relative_to(ROOT).as_posix()
    ref = file(rel, 'sourcecode.c.objc'); test_refs.append(ref)
    test_sources.append(obj('build:' + rel, 'PBXBuildFile', fileRef=ref))
fixtures = file('Tests/Fixtures', 'folder'); test_refs.append(fixtures)
test_product = obj('product:tests', 'PBXFileReference', path='OfflineToolTests.xctest',
                   explicitFileType='wrapper.cfbundle', sourceTree='BUILT_PRODUCTS_DIR')
dependency = obj('tests.sdk.dependency', 'PBXTargetDependency', target=sdk)
tests = obj('target:tests', 'PBXNativeTarget', name='OfflineToolTests', productName='OfflineToolTests',
            productReference=test_product, productType='com.apple.product-type.bundle.unit-test',
            buildConfigurationList=configurations('tests', dict(PRODUCT_NAME='OfflineToolTests',
                PRODUCT_BUNDLE_IDENTIFIER='com.offline.tool.tests',
                HEADER_SEARCH_PATHS=['$(inherited)'],
                LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@loader_path/../Frameworks', '@loader_path/Frameworks'],
                FRAMEWORK_SEARCH_PATHS=['$(inherited)', '$(PLATFORM_DIR)/Developer/Library/Frameworks'],
                OTHER_LDFLAGS=['$(inherited)', '-framework', 'XCTest'])),
            buildPhases=[phase('tests.sources', 'PBXSourcesBuildPhase', test_sources),
                phase('tests.frameworks', 'PBXFrameworksBuildPhase', [obj('tests.link.sdk', 'PBXBuildFile', fileRef=framework)]),
                phase('tests.resources', 'PBXResourcesBuildPhase', [obj('tests.fixtures', 'PBXBuildFile', fileRef=fixtures)]),
                obj('tests.embed', 'PBXCopyFilesBuildPhase', buildActionMask=2147483647,
                    dstPath='', dstSubfolderSpec=10, name='Embed SDK', runOnlyForDeploymentPostprocessing=0,
                    files=[obj('tests.embed.sdk', 'PBXBuildFile', fileRef=framework, settings={'ATTRIBUTES':['CodeSignOnCopy', 'RemoveHeadersOnCopy']})])],
            buildRules=[], dependencies=[dependency])
demo_refs = [file('Demo/main.m', 'sourcecode.c.objc'), file('Demo/DemoStartupPreparationViewController.m', 'sourcecode.c.objc')]
demo_header = file('Demo/DemoStartupPreparationViewController.h', 'sourcecode.c.h')
demo_zip = file('Demo/Resources/demo.zip', 'archive.zip')
demo_product = obj('product:demo', 'PBXFileReference', path='OfflineToolDemo.app', explicitFileType='wrapper.application', sourceTree='BUILT_PRODUCTS_DIR')
demo = obj('target:demo', 'PBXNativeTarget', name='OfflineToolDemo', productName='OfflineToolDemo',
           productReference=demo_product, productType='com.apple.product-type.application',
           buildConfigurationList=configurations('demo', dict(PRODUCT_NAME='OfflineToolDemo',
               PRODUCT_BUNDLE_IDENTIFIER='com.offline.tool.sample', SUPPORTED_PLATFORMS='iphoneos iphonesimulator',
               GENERATE_INFOPLIST_FILE='NO', INFOPLIST_FILE='Demo/Info.plist',
               HEADER_SEARCH_PATHS=['$(inherited)'],
               LD_RUNPATH_SEARCH_PATHS=['$(inherited)', '@executable_path/Frameworks'])),
           buildPhases=[phase('demo.sources', 'PBXSourcesBuildPhase', [obj('demo.src.' + r, 'PBXBuildFile', fileRef=r) for r in demo_refs]),
               phase('demo.frameworks', 'PBXFrameworksBuildPhase', [obj('demo.link.sdk', 'PBXBuildFile', fileRef=framework)]),
               phase('demo.resources', 'PBXResourcesBuildPhase', [obj('demo.res.' + r, 'PBXBuildFile', fileRef=r) for r in [demo_zip]]),
               obj('demo.embed', 'PBXCopyFilesBuildPhase', buildActionMask=2147483647, dstPath='', dstSubfolderSpec=10,
                   name='Embed SDK', runOnlyForDeploymentPostprocessing=0,
                   files=[obj('demo.embed.sdk', 'PBXBuildFile', fileRef=framework, settings={'ATTRIBUTES':['CodeSignOnCopy','RemoveHeadersOnCopy']})])],
           buildRules=[], dependencies=[obj('demo.sdk.dependency', 'PBXTargetDependency', target=sdk)])
products = obj('products', 'PBXGroup', name='Products', sourceTree='<group>', children=[framework, test_product, demo_product])
main = obj('main', 'PBXGroup', sourceTree='<group>', children=[
    obj('sources', 'PBXGroup', name='SDK Sources', sourceTree='<group>', children=source_refs),
    obj('tests.group', 'PBXGroup', name='Tests', sourceTree='<group>', children=test_refs),
    obj('demo.group', 'PBXGroup', name='Demo', sourceTree='<group>', children=demo_refs + [demo_header, demo_zip]), products])
project = obj('project', 'PBXProject', attributes={'LastUpgradeCheck': '1600'}, buildConfigurationList=configurations('project', {}),
              compatibilityVersion='Xcode 14.0', developmentRegion='en', knownRegions=['en', 'Base'],
              mainGroup=main, productRefGroup=products, projectDirPath='', projectRoot='', targets=[sdk, tests, demo])
output = ROOT / 'OfflineTool.xcodeproj'
output.mkdir(exist_ok=True)
(output / 'project.pbxproj').write_text('// !$*UTF8*$!\n' + serialize(dict(archiveVersion=1, classes={}, objectVersion=56,
                                                                     objects=objects, rootObject=project)) + '\n')
scheme = output / 'xcshareddata/xcschemes/OfflineTool.xcscheme'
scheme.parent.mkdir(parents=True, exist_ok=True)
def buildable(uid, name, product):
    return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{uid}" BuildableName="{product}" BlueprintName="{name}" ReferencedContainer="container:OfflineTool.xcodeproj"/>'
scheme.write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable(sdk, 'OfflineTool', 'OfflineTool.framework')}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables>
  <TestableReference skipped="NO">{buildable(tests, 'OfflineToolTests', 'OfflineToolTests.xctest')}</TestableReference>
 </Testables></TestAction>
 <LaunchAction buildConfiguration="Debug"/>
 <ProfileAction buildConfiguration="Release"/>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
(scheme.parent / 'OfflineToolDemo.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable(demo, 'OfflineToolDemo', 'OfflineToolDemo.app')}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES">
  <BuildableProductRunnable runnableDebuggingMode="0">{buildable(demo, 'OfflineToolDemo', 'OfflineToolDemo.app')}</BuildableProductRunnable>
 </LaunchAction>
 <AnalyzeAction buildConfiguration="Debug"/>
 <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(output)
