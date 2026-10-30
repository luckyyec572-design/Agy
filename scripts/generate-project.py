"""Generate a dependency-free Xcode project on Windows or macOS."""
import hashlib
import plistlib
from pathlib import Path

root = Path(__file__).resolve().parents[1]
debug_info = plistlib.loads((root/'Config/Info.plist').read_bytes())
debug_info['NSAppTransportSecurity'] = {'NSAllowsLocalNetworking': True}
(root/'Config/DebugInfo.plist').write_bytes(plistlib.dumps(debug_info))
objects = []
def uid(key): return hashlib.sha256(key.encode()).hexdigest()[:24].upper()
def add(key, body):
    objects.append(f'\t\t{uid(key)} = {{ {body} }};')
    return uid(key)
def refs(items): return '(' + ', '.join(items) + ',)'
def quote(value): return '"' + str(value).replace('"', '\\"') + '"'
def settings(values): return '{ ' + ' '.join(f'{key} = {quote(value)};' for key,value in values.items()) + ' }'
def configs(key, values):
    ids = []
    for name in ['Debug', 'Release']:
        local = dict(values)
        local['SWIFT_OPTIMIZATION_LEVEL'] = '-Onone' if name == 'Debug' else '-O'
        local['DEBUG_INFORMATION_FORMAT'] = 'dwarf' if name == 'Debug' else 'dwarf-with-dsym'
        local['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = 'DEBUG' if name == 'Debug' else ''
        if key == 'target-configs' and name == 'Debug': local['INFOPLIST_FILE'] = 'Config/DebugInfo.plist'
        ids.append(add(key+name, f'isa = XCBuildConfiguration; buildSettings = {settings(local)}; name = {name};'))
    return add(key, f'isa = XCConfigurationList; buildConfigurations = {refs(ids)}; defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')

files, sources, resources = [], [], []
for path in sorted((root/'Sources').iterdir()):
    if path.suffix == '.swift': kind, phase = 'sourcecode.swift', sources
    elif path.suffix == '.js': kind, phase = 'sourcecode.javascript', resources
    elif path.suffix == '.xcprivacy': kind, phase = 'text.xml', resources
    elif path.suffix == '.xcassets': kind, phase = 'folder.assetcatalog', resources
    else: continue
    ref = add('file:'+path.name, f'isa = PBXFileReference; lastKnownFileType = {kind}; path = "Sources/{path.name}"; sourceTree = SOURCE_ROOT;')
    files.append(ref)
    phase.append(add('build:'+path.name, f'isa = PBXBuildFile; fileRef = {ref};'))
product = add('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = AGY.app; sourceTree = BUILT_PRODUCTS_DIR;')
products = add('products', f'isa = PBXGroup; children = {refs([product])}; name = Products; sourceTree = "<group>";')
group = add('group', f'isa = PBXGroup; children = {refs(files+[products])}; sourceTree = "<group>";')
source_phase = add('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = {refs(sources)}; runOnlyForDeploymentPostprocessing = 0;')
resource_phase = add('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = {refs(resources)}; runOnlyForDeploymentPostprocessing = 0;')
svg_package = add('svg-package', 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/swhitty/SwiftDraw.git"; requirement = { kind = exactVersion; version = 0.29.0; };')
svg_product = add('svg-product', f'isa = XCSwiftPackageProductDependency; package = {svg_package}; productName = SwiftDraw;')
svg_build = add('svg-build', f'isa = PBXBuildFile; productRef = {svg_product};')
framework_phase = add('frameworks', f'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = {refs([svg_build])}; runOnlyForDeploymentPostprocessing = 0;')

project_configs = configs('project-configs', dict(SDKROOT='iphoneos', IPHONEOS_DEPLOYMENT_TARGET='17.0', SWIFT_VERSION='5.0', CLANG_ENABLE_MODULES='YES', ENABLE_USER_SCRIPT_SANDBOXING='YES'))
target_configs = configs('target-configs', dict(PRODUCT_NAME='AGY', PRODUCT_BUNDLE_IDENTIFIER='com.ddyec.agy-iphone', INFOPLIST_FILE='Config/Info.plist', GENERATE_INFOPLIST_FILE='YES', INFOPLIST_KEY_LSRequiresIPhoneOS='YES', INFOPLIST_KEY_UIApplicationSceneManifest_Generation='YES', INFOPLIST_KEY_AGYNativeRendering='YES', TARGETED_DEVICE_FAMILY='1', SUPPORTED_PLATFORMS='iphoneos iphonesimulator', SUPPORTS_MACCATALYST='NO', SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD='NO', CODE_SIGN_STYLE='Automatic', MARKETING_VERSION='1.2.0', CURRENT_PROJECT_VERSION='4', ASSETCATALOG_COMPILER_APPICON_NAME='AppIcon', ENABLE_PREVIEWS='YES', SWIFT_EMIT_LOC_STRINGS='YES'))
target = add('target', f'isa = PBXNativeTarget; buildConfigurationList = {target_configs}; buildPhases = {refs([source_phase,framework_phase,resource_phase])}; buildRules = (); dependencies = (); packageProductDependencies = {refs([svg_product])}; name = AGY; productName = AGY; productReference = {product}; productType = "com.apple.product-type.application";')
add('project', f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2600; }}; buildConfigurationList = {project_configs}; compatibilityVersion = "Xcode 14.0"; developmentRegion = "zh-Hans"; knownRegions = ("zh-Hans", en, Base); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; packageReferences = {refs([svg_package])}; targets = {refs([target])};')
project = root/'AGY.xcodeproj'
project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 60; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {uid("project")}; }}\n', encoding='utf8')
schemes = project/'xcshareddata/xcschemes'
schemes.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="AGY.app" BlueprintName="AGY" ReferencedContainer="container:AGY.xcodeproj"/>'
(schemes/'AGY.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>

</Scheme>''', encoding='utf8')
print('Generated AGY.xcodeproj')
