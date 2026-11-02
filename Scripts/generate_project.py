#!/usr/bin/env python3
"""Dependency-free, reproducible Xcode project generation; no XcodeGen needed."""
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
objects = {}
def ident(value): return hashlib.sha1(value.encode()).hexdigest()[:24].upper()
def add(key, value):
    object_id = ident(key); objects[object_id] = value; return object_id
def q(value): return json.dumps(str(value), ensure_ascii=False)
def array(values): return '(\n' + ''.join('    ' + str(v) + ',\n' for v in values) + ')'
def obj(**values): return '{ ' + ' '.join(k + ' = ' + str(v) + ';' for k, v in values.items()) + ' }'
def configs(key, settings):
    configs=[]
    for configuration in ['Debug', 'Release']:
        s=dict(settings)
        s['SWIFT_OPTIMIZATION_LEVEL']=q('-Onone' if configuration == 'Debug' else '-O')
        s['DEBUG_INFORMATION_FORMAT']=q('dwarf' if configuration == 'Debug' else 'dwarf-with-dsym')
        if configuration=='Debug':
            s['SWIFT_ACTIVE_COMPILATION_CONDITIONS']=q('DEBUG $(inherited)')
            s['GCC_PREPROCESSOR_DEFINITIONS']=array([q('DEBUG=1'),q('$(inherited)')])
            s['ENABLE_TESTABILITY']='YES'
        configs.append(add(key+configuration,obj(isa='XCBuildConfiguration',buildSettings=obj(**s),name=q(configuration))))
    return add(key+'list',obj(isa='XCConfigurationList',buildConfigurations=array(configs),defaultConfigurationIsVisible=0,defaultConfigurationName=q('Release')))

common = dict(SWIFT_VERSION=q('5.0'), IPHONEOS_DEPLOYMENT_TARGET=q('17.0'), SDKROOT=q('iphoneos'),
    CODE_SIGN_STYLE=q('Automatic'), TARGETED_DEVICE_FAMILY=q('1,2'), SWIFT_STRICT_CONCURRENCY=q('minimal'),
    CLANG_ENABLE_MODULES='YES', CLANG_ENABLE_OBJC_ARC='YES', GCC_C_LANGUAGE_STANDARD=q('gnu11'),
    ENABLE_USER_SCRIPT_SANDBOXING='NO', PRODUCT_NAME=q('$(TARGET_NAME)'),
    SUPPORTED_PLATFORMS=q('iphoneos iphonesimulator'),
    HEADER_SEARCH_PATHS=array([q('$(inherited)'),q('$(SRCROOT)/Vendor/Astronomy')]))
appsettings=dict(common, PRODUCT_BUNDLE_IDENTIFIER=q('com.lihao.BlindOracle'),
    DEVELOPMENT_TEAM=q(os.environ.get('DEVELOPMENT_TEAM', 'A82X46N3WS')),
    INFOPLIST_FILE=q('App/Info.plist'), CURRENT_PROJECT_VERSION=2, MARKETING_VERSION=q('0.1.1'),
    ASSETCATALOG_COMPILER_APPICON_NAME=q('AppIcon'),
    SWIFT_OBJC_BRIDGING_HEADER=q('App/BlindOracle-Bridging-Header.h'),
    HEADER_SEARCH_PATHS=array([q('$(inherited)'),q('$(SRCROOT)/Vendor/Astronomy')]),
    LD_RUNPATH_SEARCH_PATHS=q('$(inherited) @executable_path/Frameworks'))

sourcefiles=[]
for folder in ['App','Core','Services','Plugins','Vendor']:
    sourcefiles += [p for p in (ROOT/folder).rglob('*') if p.suffix in ['.swift','.c'] and p.is_file()]
sourcefiles += list((ROOT/'Views').glob('*.swift'))
sourcefiles=sorted(sourcefiles)
fileids=[]; appbuild=[]
for p in sourcefiles:
    path=p.relative_to(ROOT).as_posix()
    kind='sourcecode.swift' if p.suffix=='.swift' else 'sourcecode.c.c'
    f=add('file:'+path,obj(isa='PBXFileReference',lastKnownFileType=q(kind),path=q(path),sourceTree=q('<group>')))
    fileids.append(f);appbuild.append(add('build:'+path,obj(isa='PBXBuildFile',fileRef=f)))

resourceids=[];resourcebuild=[]
resourcepaths=[ROOT/'Resources/Assets.xcassets']+[p for p in (ROOT/'Resources').iterdir() if p.name!='Assets.xcassets']
resourcepaths += [ROOT/'Documentation']
for p in sorted(resourcepaths):
    path=p.relative_to(ROOT).as_posix()
    kind='folder.assetcatalog' if p.suffix=='.xcassets' else 'folder' if p.is_dir() else 'text'
    f=add('file:'+path,obj(isa='PBXFileReference',lastKnownFileType=q(kind),path=q(path),sourceTree=q('<group>')))
    resourceids.append(f);resourcebuild.append(add('build:'+path,obj(isa='PBXBuildFile',fileRef=f)))

appproduct=add('product:app',obj(isa='PBXFileReference',explicitFileType=q('wrapper.application'),includeInIndex=0,path=q('BlindOracle.app'),sourceTree=q('BUILT_PRODUCTS_DIR')))
testproduct=add('product:tests',obj(isa='PBXFileReference',explicitFileType=q('wrapper.cfbundle'),includeInIndex=0,path=q('BlindOracleTests.xctest'),sourceTree=q('BUILT_PRODUCTS_DIR')))
uiproduct=add('product:ui',obj(isa='PBXFileReference',explicitFileType=q('wrapper.cfbundle'),includeInIndex=0,path=q('BlindOracleUITests.xctest'),sourceTree=q('BUILT_PRODUCTS_DIR')))
products=add('products',obj(isa='PBXGroup',children=array([appproduct,testproduct,uiproduct]),name=q('Products'),sourceTree=q('<group>')))
sourcegroup=add('sourcesgroup',obj(isa='PBXGroup',children=array(fileids),name=q('Sources'),sourceTree=q('<group>')))
resourcegroup=add('resourcesgroup',obj(isa='PBXGroup',children=array(resourceids),name=q('Resources'),sourceTree=q('<group>')))
sources=add('sourcesphase',obj(isa='PBXSourcesBuildPhase',buildActionMask=2147483647,files=array(appbuild),runOnlyForDeploymentPostprocessing=0))
resources=add('resourcesphase',obj(isa='PBXResourcesBuildPhase',buildActionMask=2147483647,files=array(resourcebuild),runOnlyForDeploymentPostprocessing=0))
frameworks=add('frameworksphase',obj(isa='PBXFrameworksBuildPhase',buildActionMask=2147483647,files='()',runOnlyForDeploymentPostprocessing=0))
credentialphase=add('credentialphase',obj(isa='PBXShellScriptBuildPhase',alwaysOutOfDate=1,buildActionMask=2147483647,files='()',inputPaths='()',name=q('Development credential (Debug only)'),outputPaths='()',runOnlyForDeploymentPostprocessing=0,shellPath=q('/bin/sh'),shellScript=q('/usr/bin/python3 "${SRCROOT}/Scripts/development_key.py"')))
appconfig=configs('appconfig',appsettings)
apptarget=add('apptarget',obj(isa='PBXNativeTarget',buildConfigurationList=appconfig,buildPhases=array([sources,frameworks,resources,credentialphase]),buildRules='()',dependencies='()',name=q('BlindOracle'),productName=q('BlindOracle'),productReference=appproduct,productType=q('com.apple.product-type.application')))

testgroups=[]; targets=[apptarget]
for label,folder,product,ui in [('BlindOracleTests','Tests',testproduct,False),('BlindOracleUITests','UITests',uiproduct,True)]:
    build=[];refs=[]
    for p in sorted((ROOT/folder).glob('*.swift')):
        path=p.relative_to(ROOT).as_posix()
        f=add('file:'+path,obj(isa='PBXFileReference',lastKnownFileType=q('sourcecode.swift'),path=q(path),sourceTree=q('<group>')))
        refs.append(f);build.append(add('build:'+path,obj(isa='PBXBuildFile',fileRef=f)))
    testgroups.append(add(folder+'group',obj(isa='PBXGroup',children=array(refs),name=q(folder),sourceTree=q('<group>'))))
    phase=add(folder+'sourcesphase',obj(isa='PBXSourcesBuildPhase',buildActionMask=2147483647,files=array(build),runOnlyForDeploymentPostprocessing=0))
    proxy=add(folder+'proxy',obj(isa='PBXContainerItemProxy',containerPortal=ident('project'),proxyType=1,remoteGlobalIDString=apptarget,remoteInfo=q('BlindOracle')))
    dependency=add(folder+'dependency',obj(isa='PBXTargetDependency',target=apptarget,targetProxy=proxy))
    settings=dict(common,PRODUCT_BUNDLE_IDENTIFIER=q('com.lihao.'+label),GENERATE_INFOPLIST_FILE='YES',LD_RUNPATH_SEARCH_PATHS=q('$(inherited) @executable_path/Frameworks @loader_path/Frameworks'))
    if ui: settings['TEST_TARGET_NAME']=q('BlindOracle')
    else:
        settings['TEST_HOST']=q('$(BUILT_PRODUCTS_DIR)/BlindOracle.app/BlindOracle');settings['BUNDLE_LOADER']=q('$(TEST_HOST)')
    config=configs(folder+'config',settings)
    target=add(folder+'target',obj(isa='PBXNativeTarget',buildConfigurationList=config,buildPhases=array([phase]),buildRules='()',dependencies=array([dependency]),name=q(label),productName=q(label),productReference=product,productType=q('com.apple.product-type.bundle.ui-testing' if ui else 'com.apple.product-type.bundle.unit-test')))
    targets.append(target)

main=add('main',obj(isa='PBXGroup',children=array([sourcegroup,resourcegroup]+testgroups+[products]),sourceTree=q('<group>')))
# No App Intents or Shortcuts are declared; skip their unused metadata task.
projectconfig=configs('projectconfig',dict(CLANG_ENABLE_MODULES='YES',CLANG_WARN_DOCUMENTATION_COMMENTS='NO',GCC_WARN_INHIBIT_ALL_WARNINGS='NO',LM_SKIP_METADATA_EXTRACTION='YES'))
project=add('project',obj(isa='PBXProject',attributes=obj(BuildIndependentTargetsInParallel='YES',LastUpgradeCheck=2710),buildConfigurationList=projectconfig,compatibilityVersion=q('Xcode 14.0'),developmentRegion=q('zh-Hans'),hasScannedForEncodings=0,knownRegions=array([q('zh-Hans'),q('en'),q('Base')]),mainGroup=main,productRefGroup=products,projectDirPath=q(''),projectRoot=q(''),targets=array(targets)))
directory=ROOT/'BlindOracle.xcodeproj';directory.mkdir(exist_ok=True)
(directory/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+''.join(k+' = '+v+';\n' for k,v in objects.items())+'}; rootObject = '+project+'; }\n')
schemes=directory/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
reference=lambda target,name: f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="{name}" BlueprintName="{name.split(".")[0]}" ReferencedContainer="container:BlindOracle.xcodeproj"/>'
appref=reference(apptarget,'BlindOracle.app')
tests=''.join('<TestableReference skipped="NO">'+reference(t,name+'.xctest')+'</TestableReference>' for t,name in [(targets[1],'BlindOracleTests'),(targets[2],'BlindOracleUITests')])
testenv='<EnvironmentVariables><EnvironmentVariable key="BLINDORACLE_LIVE_SMOKE" value="1" isEnabled="YES"/></EnvironmentVariables>' if os.environ.get('BLINDORACLE_LIVE_SMOKE')=='1' else ''
(schemes/'BlindOracle.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2710" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{appref}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="NO"><Testables>{tests}</Testables>{testenv}</TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{appref}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{appref}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>''')
print(f'Generated BlindOracle.xcodeproj: {len(sourcefiles)} implementation files; {len(resourcepaths)} resource entries; 3 targets.')
