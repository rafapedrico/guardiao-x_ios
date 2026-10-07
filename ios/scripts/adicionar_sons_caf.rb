# Inclui os sons do alarme (ios/Runner/Sounds/som_N.caf) no bundle do Runner
# usando a gem xcodeproj (a mesma que o CocoaPods usa) — o project.pbxproj
# não é editado à mão. Idempotente: arquivos já incluídos são ignorados.
#
# Os .caf saem de assets/sounds/som_N.mp3 (até 30 s, IMA4 mono 44,1 kHz,
# convertidos com ffmpeg). Ficam na raiz do bundle porque é lá que o iOS
# procura:
#   - o som do Push recebido (o servidor envia aps.sound = "som_N.caf");
#   - o som das notificações do cronômetro e do despertador;
#   - o som do alarme do AlarmKit (despertador, iOS 26+).
#
# USO (a partir da pasta ios/):
#   gem install xcodeproj
#   ruby scripts/adicionar_sons_caf.rb
# O CI (ios-build.yml e ios-testflight.yml) também roda este script antes
# do build.

require 'xcodeproj'

caminho_projeto = File.expand_path('../Runner.xcodeproj', __dir__)
projeto = Xcodeproj::Project.open(caminho_projeto)
runner = projeto.targets.find { |t| t.name == 'Runner' } or abort('Target Runner não encontrado')

grupo_runner = projeto.main_group.find_subpath('Runner', false) or abort('Grupo Runner não encontrado')
grupo_sons = grupo_runner.find_subpath('Sounds', false) || grupo_runner.new_group('Sounds', 'Sounds')

pasta = File.expand_path('../Runner/Sounds', __dir__)
arquivos = Dir.glob(File.join(pasta, 'som_*.caf')).map { |c| File.basename(c) }.sort
abort('Nenhum .caf em ios/Runner/Sounds') if arquivos.empty?

recursos = runner.resources_build_phase
ja_no_bundle = recursos.files_references.compact.map(&:path)
adicionados = 0
arquivos.each do |nome|
  ref = grupo_sons.files.find { |f| f.path == nome } || grupo_sons.new_reference(nome)
  ref.last_known_file_type = 'file'
  next if ja_no_bundle.include?(nome)

  recursos.add_file_reference(ref, true)
  adicionados += 1
end

projeto.save
puts "Sons .caf no bundle do Runner: #{arquivos.size} (#{adicionados} adicionados agora)."
