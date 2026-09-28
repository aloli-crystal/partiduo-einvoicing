# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Einvoicing::SpecSupport
private alias Api = Einvoicing::Api

private def belgian_books : Nil
  S.books("be")
  S.connect_peppol
end

private def belgian_customer : Partiduo::Api::Cards::CardView
  S.card("CUSTOMER", "Brasserie Lambic SRL", "CLI-LAMBIC", vat: "BE0477472701", country: "BE", email: "factures@lambic.test")
end

describe "Adaptateur Peppol Belgique PEPPOL_BE (reprise de peppol-connect, dossiers belges, ADR-004 D2)" do
  it "n'est admis que pour un dossier belge ; l'adaptateur XP Z12-013 l'est aussi" do
    S.books("be")
    Api.adapters(S.admin).map { |item| {item.code, item.available} }.should eq([{"AFNOR", true}, {"PEPPOL_BE", true}])
    connection = S.connect_peppol
    {connection.adapter, connection.mode}.should eq({"PEPPOL_BE", "production"})
    Einvoicing::Connection.filter(adapter: "PEPPOL_BE").first!.secrets.to_s.should_not contain(S::SimulatedPlatform::PEPPOL_TOKEN)
    result = Api.configure(S.admin, Api::ConnectionInput.new("PEPPOL_BE", {"url" => "http://peppol.test",
                                                                           "participant_id" => "x", "user_id" => "PDUO", "auth_header" => "Bad Header",
                                                                           "token" => "", "environment" => "production"}))
    result.errors.map(&.key).should eq(["einvoicing.errors.connection.field.https", "einvoicing.errors.connection.field.header"])
  end

  it "ouvre la session par /cnx2 avec le jeton permanent (chiffré en base)" do
    belgian_books
    Api.check_connection(S.admin).success?.should be_true
    S.platform.peppol_sessions.should eq(1)
    session = Einvoicing::Connection.filter(adapter: "PEPPOL_BE").first!.access_token.to_s
    session.should_not contain("sess-1")
    Einvoicing::Secrets.decrypt(session).should eq("sess-1")
  end

  it "transmet l'UBL PEPPOL BIS 3 de la facture émise au destinataire 0208" do
    belgian_books
    invoice = S.issue(belgian_customer)
    S.transmission(invoice).route.should eq("platform")
    Api.synchronize(S.admin).value!.transmitted.should eq(1)
    param, name, content = S.platform.peppol_sent.first
    param["peppol_to"].should eq("0208:0477472701")
    param["uuid"].should eq(S.transmission(invoice).tracking_id)
    name.should eq("#{invoice.number}.xml")
    xml = String.new(content)
    xml.should contain(Einvoicing::Formats::PEPPOL_BIS3)
    xml.should contain(%(<cbc:EndpointID schemeID="0208">0417497106</cbc:EndpointID>))
    row = S.transmission(invoice)
    {row.status, row.syntax, row.platform_ref}.should eq({"submitted", "UBL", row.tracking_id})
    request = S.platform.requests.find!(&.url.ends_with?("/1/documents/outgoing"))
    request.headers[S::SimulatedPlatform::PEPPOL_HEADER].should eq("Bearer sess-1  PDUO")
  end

  it "reçoit les factures en attente, les confirme, sans doublon" do
    belgian_books
    S.platform.peppol_inbox << {"uuid-1", String.new(S.ubl_invoice("BE-1")), "0208:0202239951"}
    S.platform.peppol_inbox << {"uuid-2", String.new(S.ubl_invoice("BE-2")), "0208:0202239951"}
    Api.synchronize(S.admin).value!.received.should eq(2)
    S.platform.peppol_acknowledged.should eq(["uuid-1", "uuid-2"])
    Api.receptions(S.admin).map(&.number).sort!.should eq(["BE-1", "BE-2"])
    Einvoicing::Connection.filter(active: true).first!.incoming_cursor.should eq("uuid-2")
    Api.synchronize(S.admin).value!.received.should eq(0)
  end

  it "rouvre la session sur un refus 401" do
    belgian_books
    Api.check_connection(S.admin)
    # La session est remplacée chez l'éditeur (expirée) : 401, puis /cnx2.
    Einvoicing::Connection.filter(adapter: "PEPPOL_BE").update(access_token: Einvoicing::Secrets.encrypt("sess-0"),
      access_token_expires_at: Time.utc + 10.minutes)
    Api.synchronize(S.admin).value!.errors.should be_empty
    S.platform.peppol_sessions.should eq(2)
  end

  it "n'a ni statut ni e-reporting : « Encaissée » reste sans objet, rien n'échoue" do
    belgian_books
    invoice = S.issue(belgian_customer)
    Api.synchronize(S.admin)
    Partiduo::Events.publish("payment.matched", {"matching_id" => "9", "sources" => "invoice:#{invoice.id}"})
    event = Einvoicing::Event.filter(code: "212").first!
    event.state.should eq("not_applicable")
    Api.synchronize(S.admin).value!.errors.should be_empty
    expect_raises(Einvoicing::Unsupported) { Einvoicing::Connections.connector.lookup("0477472701") }
    Api.lookup(S.admin, "0477472701").errors.first.key.should eq("einvoicing.errors.directory.unsupported")
  end

  it "reprend les raccordements de l'ancien code d'adaptateur (migration 0003) avec leur en-tête" do
    S.books("be")
    Marten::DB::Connection.default.open do |db|
      db.exec(<<-SQL)
        INSERT INTO einvoicing_connection (adapter, active, settings, secrets, access_token, refresh_token,
                                           last_error, created_at, updated_at)
        VALUES ('ACME_PEPPOL', true, '{"url": "https://peppol.test", "user_id": "PDUO"}', '', '', '', '', now(), now())
        SQL
      [Migration::Einvoicing::V0003::CONNECTIONS, Migration::Einvoicing::V0003::TRANSMISSIONS,
       Migration::Einvoicing::V0003::RECEPTIONS].each { |statement| db.exec(statement) }
    end
    connection = Einvoicing::Connection.filter(active: true).first!
    connection.adapter.should eq("PEPPOL_BE")
    settings = Einvoicing::Connections.settings_of(connection)
    {settings["auth_header"], settings["url"], settings["user_id"]}.should eq({"Acme-Authz", "https://peppol.test", "PDUO"})
    Einvoicing::Connections.connector.should be_a(Einvoicing::Connectors::PeppolBe)
  end
end
