#!/usr/bin/env python3
"""Generate the native Xcode project with Python's standard library; no XcodeGen required."""
from pathlib import Path
import hashlib
import json
import plistlib
import os

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / 'Roamtty.xcodeproj'
objects = {}
def uid(name): return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(object_key, isa, **values):
    identifier = uid(object_key)
    objects[identifier] = {'isa': isa, **values}
    return identifier

def file(path, kind=None):
    extension = Path(path).suffix
    types = {'.swift':'sourcecode.swift', '.c':'sourcecode.c.c', '.h':'sourcecode.c.h', '.sh':'text.script.sh', '.ttf':'file', '.otf':'file', '.xcassets':'folder.assetcatalog', '.plist':'text.plist.xml', '.xcprivacy':'text.xml', '.entitlements':'text.plist.entitlements', '.txt':'text', '.md':'net.daringfireball.markdown'}
    return add('file:'+path, 'PBXFileReference', path=path, sourceTree='SOURCE_ROOT', lastKnownFileType=kind or types.get(extension, 'text'))

def build_file(path, phase): return add('build:'+phase+':'+path, 'PBXBuildFile', fileRef=file(path))

def config_list(name, settings):
    refs=[]
    for config in ['Debug', 'Release']:
        conf={**settings}
        if config=='Debug': conf.update({'SWIFT_OPTIMIZATION_LEVEL':'-Onone','GCC_OPTIMIZATION_LEVEL':'0','DEBUG_INFORMATION_FORMAT':'dwarf','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'$(inherited) DEBUG','ONLY_ACTIVE_ARCH':'YES'})
        else: conf.update({'SWIFT_OPTIMIZATION_LEVEL':'-O','DEBUG_INFORMATION_FORMAT':'dwarf-with-dsym','SWIFT_COMPILATION_MODE':'wholemodule'})
        refs.append(add('config:'+name+':'+config, 'XCBuildConfiguration', buildSettings=conf, name=config))
    return add('configlist:'+name,'XCConfigurationList',buildConfigurations=refs,defaultConfigurationIsVisible='0',defaultConfigurationName='Release')

COMMON={
    'SDKROOT':'iphoneos', 'IPHONEOS_DEPLOYMENT_TARGET':'16.0', 'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator',
    'SWIFT_VERSION':'5.0', 'SWIFT_STRICT_CONCURRENCY':'minimal', 'CLANG_ENABLE_MODULES':'YES', 'CLANG_ENABLE_OBJC_ARC':'YES',
    'GCC_C_LANGUAGE_STANDARD':'gnu11', 'CLANG_CXX_LANGUAGE_STANDARD':'c++17', 'TARGETED_DEVICE_FAMILY':'1,2',
    'CODE_SIGN_STYLE':'Automatic', 'DEVELOPMENT_TEAM':os.environ.get('DEVELOPMENT_TEAM',''),
    # Embedded products are signed when copied, so stripping them there only warns; each target strips its own binary.
    'COPY_PHASE_STRIP':'NO',
    # No target defines App Intents; extracting their metadata would only note that AppIntents.framework is not linked.
    'LM_SKIP_METADATA_EXTRACTION':'YES',
    'ENABLE_USER_SCRIPT_SANDBOXING':'NO', 'ROAMTTY_APP_GROUP_ENABLED':'NO', 'ROAMTTY_ENTITLEMENTS':'App/Support/Development.entitlements', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS':'$(inherited)',
    'HEADER_SEARCH_PATHS':['$(inherited)','$(SRCROOT)/Sources/CNative/include','$(SRCROOT)/Vendor/$(PLATFORM_NAME)/include'],
    'LIBRARY_SEARCH_PATHS':['$(inherited)','$(SRCROOT)/Vendor/$(PLATFORM_NAME)/lib'],
    'SWIFT_INCLUDE_PATHS':['$(inherited)','$(SRCROOT)/Sources/CNative/include','$(BUILT_PRODUCTS_DIR)'],
    'OTHER_LDFLAGS':['$(inherited)','-lssh2','-lcrypto','-lz','-lsqlite3'],
}
products=[]
targets=[]
target_ids={name:uid('target:'+name) for name in ['CNative','RoamttyCore','RoamttyTransport','RoamttyDesktopCore','Roamtty','RoamttyShare','RoamttyUITests']}
product_ids={}
for name in target_ids:
    suffix = '.app' if name=='Roamtty' else '.appex' if name=='RoamttyShare' else '.xctest' if name=='RoamttyUITests' else '.a'
    path = name+suffix if suffix!='.a' else 'lib'+name+suffix
    product_ids[name]=add('product:'+name,'PBXFileReference',explicitFileType={'.app':'wrapper.application','.appex':'wrapper.app-extension','.xctest':'wrapper.cfbundle','.a':'archive.ar'}[suffix],path=path,sourceTree='BUILT_PRODUCTS_DIR',includeInIndex='0')
    products.append(product_ids[name])

def dependency(target, owner):
    proxy=add('proxy:'+owner+':'+target,'PBXContainerItemProxy',containerPortal=uid('project'),proxyType='1',remoteGlobalIDString=target_ids[target],remoteInfo=target)
    return add('dependency:'+owner+':'+target,'PBXTargetDependency',target=target_ids[target],targetProxy=proxy)

def make_target(name, sources, resources, depends, settings, product_type):
    phases=[add('sources:'+name,'PBXSourcesBuildPhase',buildActionMask='2147483647',files=[build_file(p,name+':source') for p in sources],runOnlyForDeploymentPostprocessing='0')]
    links=[]
    for target in depends:
        if target in ['RoamttyShare','Roamtty']: continue
        links.append(add('link:'+name+':'+target,'PBXBuildFile',fileRef=product_ids[target]))
    if name=='Roamtty': links.append(add('link:SwiftTerm','PBXBuildFile',productRef=uid('packageproduct:SwiftTerm')))
    phases.append(add('frameworks:'+name,'PBXFrameworksBuildPhase',buildActionMask='2147483647',files=links,runOnlyForDeploymentPostprocessing='0'))
    if resources: phases.append(add('resources:'+name,'PBXResourcesBuildPhase',buildActionMask='2147483647',files=[build_file(p,name+':resource') for p in resources],runOnlyForDeploymentPostprocessing='0'))
    if name=='Roamtty':
        embed=add('embed:share','PBXBuildFile',fileRef=product_ids['RoamttyShare'],settings={'ATTRIBUTES':['RemoveHeadersOnCopy']})
        phases.append(add('embedphase:share','PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath='',dstSubfolderSpec='13',files=[embed],name='Embed App Extensions',runOnlyForDeploymentPostprocessing='0'))
    values=dict(buildConfigurationList=config_list(name,{**COMMON,**settings}),buildPhases=phases,buildRules=[],dependencies=[dependency(d,name) for d in depends],name=name,productName=name,productReference=product_ids[name],productType=product_type)
    if name=='Roamtty': values['packageProductDependencies']=[uid('packageproduct:SwiftTerm')]
    targets.append(add('target:'+name,'PBXNativeTarget',**values))

def paths(pattern): return sorted(str(p.relative_to(ROOT)) for p in ROOT.glob(pattern) if p.is_file())
static={'SKIP_INSTALL':'YES','DEFINES_MODULE':'YES','SWIFT_INSTALL_OBJC_HEADER':'NO','PRODUCT_NAME':'$(TARGET_NAME)','MACH_O_TYPE':'staticlib','CODE_SIGNING_ALLOWED':'NO'}
make_target('CNative',paths('Sources/CNative/**/*.c'),[],[],{**static,'MODULEMAP_FILE':'$(SRCROOT)/Sources/CNative/include/module.modulemap','PUBLIC_HEADERS_FOLDER_PATH':'include/CNative'},'com.apple.product-type.library.static')
make_target('RoamttyCore',paths('Sources/RoamttyCore/**/*.swift'),[],['CNative'],static,'com.apple.product-type.library.static')
make_target('RoamttyTransport',paths('Sources/RoamttyTransport/**/*.swift'),[],['RoamttyCore','CNative','RoamttyDesktopCore'],static,'com.apple.product-type.library.static')
make_target('RoamttyDesktopCore',paths('Sources/RoamttyDesktopCore/**/*.swift'),[],[],static,'com.apple.product-type.library.static')
app_settings={'PRODUCT_BUNDLE_IDENTIFIER':'com.roamtty.app.ios','PRODUCT_NAME':'Roamtty','INFOPLIST_FILE':'App/Support/Info.plist','ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','MARKETING_VERSION':'1.0.0','CURRENT_PROJECT_VERSION':'1','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks'],'CODE_SIGN_ENTITLEMENTS':'$(ROAMTTY_ENTITLEMENTS)','GENERATE_INFOPLIST_FILE':'NO'}
resources=paths('App/Roamtty/Resources/Fonts/*')+paths('Sources/RoamttyCore/Resources/*')+paths('Sources/RoamttyDesktopCore/Resources/*')+['App/Roamtty/Resources/Assets.xcassets','App/Roamtty/Resources/PrivacyInfo.xcprivacy','THIRD_PARTY_NOTICES.md']+paths('licenses/**/*')
make_target('Roamtty',paths('App/Roamtty/**/*.swift')+paths('App/Shared/*.swift'),resources,['RoamttyCore','RoamttyTransport','RoamttyDesktopCore','CNative','RoamttyShare'],app_settings,'com.apple.product-type.application')
make_target('RoamttyShare',paths('App/ShareExtension/**/*.swift')+paths('App/Shared/*.swift'),['App/ShareExtension/PrivacyInfo.xcprivacy'],[],{'PRODUCT_BUNDLE_IDENTIFIER':'com.roamtty.app.ios.share','PRODUCT_NAME':'RoamttyShare','INFOPLIST_FILE':'App/Support/ShareInfo.plist','APPLICATION_EXTENSION_API_ONLY':'YES','SKIP_INSTALL':'YES','MARKETING_VERSION':'1.0.0','CURRENT_PROJECT_VERSION':'1','CODE_SIGN_ENTITLEMENTS':'$(ROAMTTY_ENTITLEMENTS)','OTHER_LDFLAGS':['$(inherited)'],'LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks']},'com.apple.product-type.app-extension')
make_target('RoamttyUITests',paths('App/UITests/**/*.swift'),[],['Roamtty'],{'PRODUCT_BUNDLE_IDENTIFIER':'com.roamtty.app.ios.uitests','GENERATE_INFOPLIST_FILE':'YES','PRODUCT_NAME':'$(TARGET_NAME)','TEST_TARGET_NAME':'Roamtty','OTHER_LDFLAGS':['$(inherited)']},'com.apple.product-type.bundle.ui-testing')
add('package:SwiftTerm','XCRemoteSwiftPackageReference',repositoryURL='https://github.com/yahaa/SwiftTerm.git',requirement={'kind':'revision','revision':'0a311223749cf1b96294772a2c5478be67915572'})
add('packageproduct:SwiftTerm','XCSwiftPackageProductDependency',package=uid('package:SwiftTerm'),productName='SwiftTerm')
source_refs=[key for key,value in objects.items() if value['isa']=='PBXFileReference' and value.get('sourceTree')=='SOURCE_ROOT']
product_group=add('products','PBXGroup',children=products,name='Products',sourceTree='<group>')
main_group=add('main','PBXGroup',children=source_refs+[product_group],sourceTree='<group>')
add('project','PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'1600','TargetAttributes':{target_ids['RoamttyUITests']:{'TestTargetID':target_ids['Roamtty']}}},buildConfigurationList=config_list('Project',COMMON),compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings='0',knownRegions=['en','zh-Hans','Base'],mainGroup=main_group,productRefGroup=product_group,projectDirPath='',projectRoot='',targets=targets,packageReferences=[uid('package:SwiftTerm')])

def serialize(value, level=0):
    indent='\t'*level
    if isinstance(value,dict): return '{\n'+''.join('\t'*(level+1)+serialize(k)+' = '+serialize(v,level+1)+';\n' for k,v in value.items())+indent+'}'
    if isinstance(value,list): return '(\n'+''.join('\t'*(level+1)+serialize(v,level+1)+',\n' for v in value)+indent+')'
    return json.dumps(str(value),ensure_ascii=False)
PROJECT.mkdir(exist_ok=True)
(PROJECT/'project.pbxproj').write_text('// !$*UTF8*$!\n'+serialize({'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':uid('project')})+'\n')
schemes=PROJECT/'xcshareddata/xcschemes'; schemes.mkdir(parents=True,exist_ok=True)
def build_ref(name): return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_ids[name]}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:Roamtty.xcodeproj"/>'
(schemes/'Roamtty.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{build_ref('Roamtty')}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target_ids['RoamttyUITests']}" BuildableName="RoamttyUITests.xctest" BlueprintName="RoamttyUITests" ReferencedContainer="container:Roamtty.xcodeproj"/></TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{build_ref('Roamtty')}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{build_ref('Roamtty')}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print(f'Generated {PROJECT} ({len(objects)} objects, {len(targets)} targets)')
