# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Einvoicing::SpecSupport
private alias Api = Einvoicing::Api

private def manager : Partiduo::Api::Actor
  Partiduo::Api::Actor.user(1_i64, [Partiduo::Api::Modules::MANAGE_MODULES])
end

private def menu_routes(entries : Array(Partiduo::Api::Modules::MenuView)) : Array(String?)
  entries.flat_map { |entry| [entry.route] + menu_routes(entry.children) }
end

describe "Extension EINV : manifeste et activation (ADR-003 D1, D2 ; ADR-004 D1)" do
  it "déclare une extension qui dépend de DOCUMENT seulement" do
    manifest = Partiduo::Modules[Einvoicing::CODE]
    manifest.kind.should eq(Partiduo::Modules::Kind::Extension)
    manifest.version.should eq(Einvoicing::VERSION)
    manifest.depends_on.should eq(["DOCUMENT"])
    manifest.permissions.should eq([Api::READ, Api::SEND, Api::RECEIVE, Api::CONFIGURE])
    manifest.menus.map { |menu| {menu.code, menu.parent, menu.route} }.should eq([
      {"EINV_OUT", "BILLING", "einv:outgoing"}, {"EINV_IN", "ENTRY", "einv:incoming"},
      {"EINV_DIRECTORY", "REFERENCE", "einv:directory"}, {"EINV_SETTINGS", "SETTINGS", "einv:settings"},
    ])
    manifest.subscribed_events.sort.should eq(["credit_note.issued", "invoice.issued", "payment.matched", "payment.recorded"])
    Partiduo::Modules.structure_errors.should be_empty
    # La réception fonctionne sur le socle et DOCUMENT seuls ; sans DOCUMENT,
    # l'activation est refusée.
    Partiduo::Modules.dependency_errors(manifest, Set{"DOCUMENT", "EINV"}).should be_empty
    Partiduo::Modules.dependency_errors(manifest, Set{"EINV"}).should_not be_empty
  end

  it "traduit son nom, ses permissions et ses menus en fr, en et nl" do
    manifest = Partiduo::Modules[Einvoicing::CODE]
    keys = [manifest.name] + manifest.permission_entries.map(&.label) + manifest.menus.map(&.label)
    Partiduo::LOCALES.each do |locale|
      I18n.with_locale(locale) { keys.each { |key| I18n.t(key).should_not contain("missing") } }
    end
  end

  it "exige DOCUMENT pour s'activer et reste invisible tant qu'elle est inactive" do
    with_active_modules("") do
      result = Partiduo::Api::Modules.activate(manager, "einv")
      result.failure?.should be_true
      result.errors.first.key.should eq("modules.errors.activation.missing_dependency")
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.receptions(S.admin) }
      Api.pending_count(S.admin).should be_nil
      menu_routes(Partiduo::Api::Modules.menu(S.admin)).should_not contain("einv:incoming")
    end
  end

  it "s'active sur le socle seul avec DOCUMENT : menus, compteur, réception sans Comptabilité ni Facturation" do
    with_active_modules("") do
      PartiduoUi::Reference.provision("fr")
      S.activate
      Partiduo::Modules.check!
      routes = menu_routes(Partiduo::Api::Modules.menu(S.admin))
      routes.should contain("einv:incoming")
      routes.should contain("einv:settings")
      Api.pending_count(S.admin).should eq(0)
      reception = Api.import(S.admin, "facture.xml", S.ubl_invoice).value!
      reception.status.should eq("received")
      Api.pending_count(S.admin).should eq(1)
      # Pré-comptabiliser exige la Comptabilité ; émettre, la Facturation.
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.post(S.admin, reception.id) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.track(S.admin, 1_i64) }
    end
  end

  it "refuse son contrat sans les permissions" do
    S.books
    nobody = Partiduo::Api::Actor.user(3_i64, [] of String)
    expect_raises(Partiduo::Api::Forbidden) { Api.receptions(nobody) }
    expect_raises(Partiduo::Api::Forbidden) { Api.transmissions(Partiduo::Api::Actor.anonymous) }
    expect_raises(Partiduo::Api::Forbidden) { Api.adapters(S.reader) }
    expect_raises(Partiduo::Api::Forbidden) { Api.synchronize(S.reader) }
    expect_raises(Partiduo::Api::Forbidden) { Api.refuse(S.reader, 1_i64, Api::RefuseInput.new("AUTRE", "x")) }
    Api.pending_count(nobody).should be_nil
    Api.receptions(S.reader).should be_empty
  end
end
