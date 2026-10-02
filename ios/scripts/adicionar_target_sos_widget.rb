# Cria o target Widget Extension "SOSWidget" no Runner.xcodeproj usando a
# gem xcodeproj (a mesma que o CocoaPods usa) — o project.pbxproj NUNCA é
# editado à mão. Idempotente: se o target já existir, não faz nada.
#
# USO (a partir da pasta ios/):
#   gem install xcodeproj
#   ruby scripts/adicionar_target_sos_widget.rb
#
# O que o script faz:
# - Target "SOSWidget" (app extension, Swift, iOS 15.0) com os fontes de
#   ios/SOSWidget/ (SOSWidget.swift, SOSWidgetBundle.swift), o catálogo
#   Assets.xcassets (imagem de 512x512) e o Localizable.strings em 11
#   idiomas. O original de 1024x1024 (sos_widget.png) fica só no repo.
# - Configurações base Flutter/Debug.xcconfig e Flutter/Release.xcconfig:
#   trazem FLUTTER_BUILD_NAME/FLUTTER_BUILD_NUMBER, então a versão do
#   widget é sempre IGUAL à do app (a Apple recusa o upload se divergir).
# - Embute o .appex no Runner ("Embed Foundation Extensions", destino
#   PlugIns) ANTES de "Thin Binary" — evita o "Cycle inside Runner"
#   conhecido do Flutter — e adiciona a dependência de target.
# - O Podfile só declara o target 'Runner', então nenhum pod é aplicado
#   ao SOSWidget.

require 'xcodeproj'

NOME_TARGET = 'SOSWidget'.freeze
BUNDLE_ID = 'com.rmfglobal.guardiaox.SOSWidget'.freeze
TEAM_ID = 'SW48YVGJZ7'.freeze
DEPLOYMENT_TARGET = '15.0'.freeze
IDIOMAS = %w[pt en es fr de it ru zh-Hans ja ar hi].freeze

caminho_projeto = File.expand_path('../Runner.xcodeproj', __dir__)
projeto = Xcodeproj::Project.open(caminho_projeto)

if projeto.targets.any? { |t| t.name == NOME_TARGET }
  puts "Target #{NOME_TARGET} já existe — nada a fazer."
  exit 0
end

runner = projeto.targets.find { |t| t.name == 'Runner' } or abort('Target Runner não encontrado')

# --- Arquivos -------------------------------------------------------------
grupo = projeto.main_group.find_subpath(NOME_TARGET, false) ||
        projeto.main_group.new_group(NOME_TARGET, NOME_TARGET)

ref_widget = grupo.new_reference('SOSWidget.swift')
ref_bundle = grupo.new_reference('SOSWidgetBundle.swift')
ref_assets = grupo.new_reference('Assets.xcassets')
grupo.new_reference('Info.plist')

grupo_strings = grupo.new_variant_group('Localizable.strings')
IDIOMAS.each do |idioma|
  ref = grupo_strings.new_reference("#{idioma}.lproj/Localizable.strings")
  ref.name = idioma
  ref.last_known_file_type = 'text.plist.strings'
end

regioes = projeto.root_object.known_regions
IDIOMAS.each { |idioma| regioes << idioma unless regioes.include?(idioma) }

# --- Target ---------------------------------------------------------------
widget = projeto.new_target(:app_extension, NOME_TARGET, :ios, DEPLOYMENT_TARGET, nil, :swift)
widget.add_build_configuration('Profile', :release) unless widget.build_configurations.any? { |c| c.name == 'Profile' }

widget.add_file_references([ref_widget, ref_bundle])
widget.add_resources([ref_assets, grupo_strings])
widget.add_system_frameworks(%w[WidgetKit SwiftUI])
# new_target/add_system_frameworks gravam o caminho do SDK da máquina que
# roda o script (ex: iPhoneOS26.0.sdk); relativo ao SDKROOT vale em
# qualquer Xcode (inclusive o do runner do GitHub Actions).
widget.frameworks_build_phase.files.each do |arquivo_fw|
  ref = arquivo_fw.file_ref
  next unless ref && ref.path.to_s.end_with?('.framework')

  ref.source_tree = 'SDKROOT'
  ref.path = "System/Library/Frameworks/#{File.basename(ref.path)}"
end

xcconfig_debug = projeto.files.find { |f| f.path == 'Flutter/Debug.xcconfig' } or abort('Flutter/Debug.xcconfig não encontrado')
xcconfig_release = projeto.files.find { |f| f.path == 'Flutter/Release.xcconfig' } or abort('Flutter/Release.xcconfig não encontrado')

widget.build_configurations.each do |config|
  config.base_configuration_reference = config.name == 'Debug' ? xcconfig_debug : xcconfig_release
  s = config.build_settings
  s['PRODUCT_BUNDLE_IDENTIFIER'] = BUNDLE_ID
  s['PRODUCT_NAME'] = '$(TARGET_NAME)'
  s['DEVELOPMENT_TEAM'] = TEAM_ID
  s['CODE_SIGN_STYLE'] = 'Automatic'
  s['IPHONEOS_DEPLOYMENT_TARGET'] = DEPLOYMENT_TARGET
  s['SWIFT_VERSION'] = '5.0'
  s['INFOPLIST_FILE'] = 'SOSWidget/Info.plist'
  s['GENERATE_INFOPLIST_FILE'] = 'NO'
  s['MARKETING_VERSION'] = '$(FLUTTER_BUILD_NAME)'
  s['CURRENT_PROJECT_VERSION'] = '$(FLUTTER_BUILD_NUMBER)'
  s['TARGETED_DEVICE_FAMILY'] = '1,2'
  s['SKIP_INSTALL'] = 'YES'
  s['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
  s['LD_RUNPATH_SEARCH_PATHS'] = ['$(inherited)', '@executable_path/Frameworks', '@executable_path/../../Frameworks']
  s['ASSETCATALOG_COMPILER_APPICON_NAME'] = ''
end

atributos = projeto.root_object.attributes['TargetAttributes'] ||= {}
atributos[widget.uuid] = {
  'CreatedOnToolsVersion' => '15.0',
  'DevelopmentTeam' => TEAM_ID,
  'ProvisioningStyle' => 'Automatic',
}

# --- Embed no Runner --------------------------------------------------------
runner.add_dependency(widget)

fase_embed = runner.new_copy_files_build_phase('Embed Foundation Extensions')
fase_embed.symbol_dst_subfolder_spec = :plug_ins
arquivo = fase_embed.add_file_reference(widget.product_reference, true)
arquivo.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }

fases = runner.build_phases
fases.delete(fase_embed)
indice_thin = fases.index { |f| f.display_name == 'Thin Binary' } ||
              fases.index { |f| f.display_name == 'Run Script' }
indice_thin ? fases.insert(indice_thin, fase_embed) : fases << fase_embed

projeto.save
puts "Target #{NOME_TARGET} criado e embutido no Runner."
puts "Fases do Runner: #{runner.build_phases.map(&:display_name).join(' -> ')}"
