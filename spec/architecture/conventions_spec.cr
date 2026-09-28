# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"
require "../../lib/partiduo-ui-bulma/scripts/api_boundary"

private def source_files(pattern : String) : Array(String)
  Dir.glob(File.join(Einvoicing::SpecSupport::ROOT, pattern)).reject(&.includes?("/lib/")).sort!
end

private def flatten_keys(value : YAML::Any, prefix : String = "") : Array(String)
  if hash = value.as_h?
    hash.flat_map { |key, child| flatten_keys(child, prefix.empty? ? key.as_s : "#{prefix}.#{key.as_s}") }
  else
    [prefix]
  end
end

describe "Conventions de l'extension EINV" do
  it "ouvre chaque fichier source par l'en-tête SPDX" do
    missing = (source_files("{src,ui,spec,config,scripts}/**/*.{cr,sh}") + source_files("*.cr")).reject do |path|
      lines = File.read_lines(path)
      (path.ends_with?(".sh") ? lines[1]? : lines.first?) == "# SPDX-License-Identifier: AGPL-3.0-or-later"
    end
    missing += source_files("ui/**/*.html").reject do |path|
      File.read(path).starts_with?("{# SPDX-License-Identifier: AGPL-3.0-or-later")
    end
    missing.should be_empty
  end

  it "a les mêmes clés de traduction en fr, en et nl" do
    %w[src/einvoicing/locales ui/bulma/locales].each do |dir|
      keys = Partiduo::LOCALES.to_h do |locale|
        tree = YAML.parse(File.read(File.join(Einvoicing::SpecSupport::ROOT, dir, "#{locale}.yml")))
        {locale, flatten_keys(tree[locale]).sort}
      end
      keys["en"].should eq(keys["fr"])
      keys["nl"].should eq(keys["fr"])
    end
  end

  it "traduit toute clé citée par le code et les gabarits de l'extension" do
    cited = source_files("{src,ui}/**/*.{cr,html}").flat_map do |path|
      File.read(path).scan(/["'](einvoicing(?:_ui)?\.[a-z_]+(?:\.[a-z0-9_]+)+)["']/).map(&.[1])
    end.uniq! - Partiduo::Modules[Einvoicing::CODE].permissions
    cited.size.should be > 60
    dynamic = [] of String
    Einvoicing::Api::CODES.each { |code| dynamic << "einvoicing.codes.#{code}" }
    Einvoicing::Api::ROUTES.each { |code| dynamic << "einvoicing.routes.#{code}" }
    Einvoicing::Api::TRANSMISSION_STATUSES.each { |code| dynamic << "einvoicing.transmission_statuses.#{code}" }
    Einvoicing::Api::RECEPTION_STATUSES.each { |code| dynamic << "einvoicing.reception_statuses.#{code}" }
    Einvoicing::Api::REFUSAL_REASONS.each { |code| dynamic << "einvoicing.refusal_reasons.#{code}" }
    Einvoicing::Api::EXPORT_FORMATS.each { |code| dynamic << "einvoicing_ui.formats.#{code.tr("-", "_")}" }
    %w[received to_send sent failed not_applicable].each { |code| dynamic << "einvoicing.event_states.#{code}" }
    %w[platform seller buyer].each { |code| dynamic << "einvoicing.issuers.#{code}" }
    Einvoicing::Connections.adapters.each do |adapter|
      dynamic << adapter.label_key
      adapter.fields.each { |field| dynamic << "einvoicing.fields.#{field.name}" }
    end
    missing = Partiduo::LOCALES.flat_map do |locale|
      I18n.with_locale(locale) do
        (cited + dynamic).select { |key| I18n.t(key).includes?("missing") && I18n.t("#{key}.one").includes?("missing") }
          .map { |key| "#{locale}:#{key}" }
      end
    end
    missing.should be_empty
  end

  it "range ses tables sous le préfixe einvoicing_ (ADR-003 D5)" do
    [Einvoicing::Connection, Einvoicing::Transmission, Einvoicing::Reception, Einvoicing::Event, Einvoicing::Report]
      .map(&.db_table).should eq(%w[einvoicing_connection einvoicing_transmission einvoicing_reception
      einvoicing_lifecycle_event einvoicing_report])
  end

  it "ne parle au cœur, depuis ui/bulma, que par Partiduo::Api (ADR-005 D3)" do
    root = Einvoicing::SpecSupport::ROOT
    ApiBoundary.scan([File.join(root, "ui")], base: root).map(&.to_s).should eq([] of String)
  end

  it "ne parle aux métiers d'extension, depuis ui/bulma, que par leur module Api (ADR-005 D4)" do
    allowed = %w[Api Ui CODE VERSION]
    leaks = source_files("ui/**/*.cr").flat_map do |path|
      File.read_lines(path).each_with_index(1).flat_map do |line, number|
        ApiBoundary.strip_comment(line).scan(/(?<![\w:])(Einvoicing|Document)::([A-Za-z_]\w*)/).compact_map do |match|
          "#{path.lchop(Einvoicing::SpecSupport::ROOT + "/")}:#{number} #{match[1]}::#{match[2]}" unless allowed.includes?(match[2])
        end
      end
    end
    leaks.should be_empty
  end

  it "ne parle au module Facturation et à la Comptabilité que par Partiduo::Api (ADR-006 D3)" do
    leaks = source_files("src/**/*.cr").select do |path|
      File.read(path).matches?(/Partiduo::(Invoicing|Accounting|Cards|Core|Vat)::/)
    end
    leaks.map(&.lchop(Einvoicing::SpecSupport::ROOT + "/")).should be_empty
  end

  it "n'utilise que des icônes de la planche de l'interface (ADR-005 D5)" do
    lucide = File.join(Einvoicing::SpecSupport::ROOT, "lib", "partiduo-ui-bulma", "icons", "lucide")
    known = Dir.glob(File.join(lucide, "*.svg")).map { |path| File.basename(path, ".svg") }
    known.should_not be_empty
    used = source_files("ui/bulma/templates/**/*.html").flat_map do |path|
      File.read(path).scan(/_icon\.html" with name="([a-z0-9-]+)"/).map { |match| "#{path.lchop(Einvoicing::SpecSupport::ROOT + "/")} #{match[1]}" }
    end
    used.reject { |item| known.includes?(item.split(' ').last) }.should be_empty
  end
end
