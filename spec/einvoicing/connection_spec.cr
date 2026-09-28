# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Einvoicing::SpecSupport
private alias Api = Einvoicing::Api

describe "Raccordement à la plateforme agréée (ADR-004 D2, D6, D8)" do
  it "chiffre les secrets : aléa, authentification, clé de l'instance" do
    first = Einvoicing::Secrets.encrypt("client-secret")
    second = Einvoicing::Secrets.encrypt("client-secret")
    first.should start_with("v1:")
    first.should_not eq(second)
    first.should_not contain("client-secret")
    Einvoicing::Secrets.decrypt(first).should eq("client-secret")
    Einvoicing::Secrets.encrypt("").should eq("")
    tampered = first[0...-4] + (first[-4] == 'A' ? "BAAA" : "AAAA")
    expect_raises(Einvoicing::Secrets::Error) { Einvoicing::Secrets.decrypt(tampered) }
    expect_raises(Einvoicing::Secrets::Error) { Einvoicing::Secrets.decrypt("clair") }
    Einvoicing::Secrets.decrypt_json(Einvoicing::Secrets.encrypt_json({"a" => "b"})).should eq({"a" => "b"})
  end

  it "liste les adaptateurs selon le régime du dossier : PEPPOL_BE pour la Belgique seulement" do
    S.books("fr")
    adapters = Api.adapters(S.admin)
    adapters.map { |item| {item.code, item.available} }.should eq([{"AFNOR", true}, {"PEPPOL_BE", false}])
    adapters.first.fields.map(&.name).should contain("client_secret")
    adapters.first.fields.find! { |item| item.name == "client_secret" }.secret.should be_true
    result = Api.configure(S.admin, Api::ConnectionInput.new("PEPPOL_BE", {"url" => "https://peppol.test"}))
    result.errors.map(&.key).should contain("einvoicing.errors.connection.adapter.regime")
    Api.configure(S.admin, Api::ConnectionInput.new("INCONNU")).errors.map(&.key)
      .should eq(["einvoicing.errors.connection.adapter.unknown"])
  end

  it "contrôle les paramètres : obligatoires, HTTPS, choix" do
    S.books
    result = Api.configure(S.admin, Api::ConnectionInput.new("AFNOR", {"flow_url" => "http://pa.test/afnor-flow",
                                                                       "token_url" => "", "client_id" => "x", "client_secret" => "y", "environment" => "demo"}))
    result.failure?.should be_true
    result.errors.map { |error| {error.field, error.key} }.should eq([
      {"flow_url", "einvoicing.errors.connection.field.https"},
      {"token_url", "einvoicing.errors.connection.field.blank"},
      {"environment", "einvoicing.errors.connection.field.choice"},
    ])
    Api.connection(S.admin).should be_nil
  end

  it "enregistre un seul adaptateur actif, secrets chiffrés en base, jamais réaffichés" do
    S.books
    connection = S.connect_afnor
    connection.adapter.should eq("AFNOR")
    connection.active.should be_true
    connection.mode.should eq("sandbox")
    row = Einvoicing::Connection.filter(adapter: "AFNOR").first!
    row.secrets.to_s.should_not contain(S::SimulatedPlatform::CLIENT_SECRET)
    row.settings.to_s.should_not contain(S::SimulatedPlatform::CLIENT_SECRET)
    field = connection.fields.find! { |item| item.name == "client_secret" }
    {field.value, field.stored}.should eq({"", true})
    connection.fields.find! { |item| item.name == "client_id" }.value.should eq(S::SimulatedPlatform::CLIENT_ID)
    # Un secret laissé vide garde la valeur enregistrée.
    again = Api.configure(S.admin, Api::ConnectionInput.new("AFNOR", {
      "flow_url" => "https://pa.test/afnor-flow", "token_url" => "https://pa.test/oauth2/token",
      "client_id" => S::SimulatedPlatform::CLIENT_ID, "client_secret" => "", "environment" => "production",
    }))
    again.value!.mode.should eq("production")
    Api.check_connection(S.admin).success?.should be_true
    Einvoicing::Connection.filter(active: true).count.should eq(1)
  end

  it "exige de ressaisir les secrets enregistrés quand une adresse change (D-ESL-004)" do
    S.books
    S.connect_afnor
    moved = Api.configure(S.admin, Api::ConnectionInput.new("AFNOR", {
      "flow_url" => "https://pa.test/afnor-flow", "token_url" => "https://ailleurs.test/oauth2/token",
      "client_id" => S::SimulatedPlatform::CLIENT_ID, "client_secret" => "", "environment" => "sandbox",
    }))
    moved.failure?.should be_true
    moved.errors.map { |error| {error.field, error.key} }.should eq([
      {"client_secret", "einvoicing.errors.connection.field.secret_reentry"},
    ])
    Einvoicing::Connection.filter(adapter: "AFNOR").first!.settings.to_s.should_not contain("ailleurs.test")
    # Secret saisi à nouveau : l'adresse est admise.
    Api.configure(S.admin, Api::ConnectionInput.new("AFNOR", {
      "flow_url" => "https://pa.test/afnor-flow", "token_url" => "https://ailleurs.test/oauth2/token",
      "client_id" => S::SimulatedPlatform::CLIENT_ID, "client_secret" => S::SimulatedPlatform::CLIENT_SECRET,
      "environment" => "sandbox",
    })).success?.should be_true
  end

  it "obtient le jeton OAuth, le conserve chiffré, le renouvelle sur un refus 401" do
    S.books
    S.connect_afnor
    Api.check_connection(S.admin).success?.should be_true
    S.platform.tokens.should eq(["tok-1"])
    row = Einvoicing::Connection.filter(adapter: "AFNOR").first!
    row.access_token.to_s.should_not contain("tok-1")
    Einvoicing::Secrets.decrypt(row.access_token.to_s).should eq("tok-1")
    Api.check_connection(S.admin)
    S.platform.tokens.size.should eq(1)
    S.platform.revoked << "tok-1"
    Api.check_connection(S.admin).success?.should be_true
    S.platform.tokens.should eq(["tok-1", "tok-2"])
  end

  it "signale un raccordement refusé et un débranchement" do
    S.books
    Api.check_connection(S.admin).errors.first.key.should eq("einvoicing.errors.connection.missing")
    Api.configure(S.admin, Api::ConnectionInput.new("AFNOR", {
      "flow_url" => "https://pa.test/afnor-flow", "token_url" => "https://pa.test/oauth2/token",
      "client_id" => "mauvais", "client_secret" => "faux", "environment" => "sandbox",
    })).value!
    result = Api.check_connection(S.admin)
    result.failure?.should be_true
    result.errors.first.key.should eq("einvoicing.errors.connection.failed")
    Api.disconnect(S.admin).success?.should be_true
    Api.connection(S.admin).should be_nil
    Api.synchronize(S.admin).errors.first.key.should eq("einvoicing.errors.connection.missing")
  end

  it "vérifie TLS sur le réseau réel et refuse une adresse non HTTPS" do
    Einvoicing::Http::NetTransport.tls_context.verify_mode.should eq(OpenSSL::SSL::VerifyMode::PEER)
    expect_raises(Einvoicing::ConnectorError, /non HTTPS/) do
      Einvoicing::Http::NetTransport.new.exec(Einvoicing::Http::Request.new("GET", "http://example.test/"))
    end
  end
end
