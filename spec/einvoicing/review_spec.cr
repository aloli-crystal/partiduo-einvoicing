# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Clôture du lot E : remarques de relecture (DECISIONS D-EINV-020 à
# D-EINV-027) — « Encaissée » avant le dépôt, canal relu avant de transmettre,
# rejet immédiat sans figer le canal, exclusion mutuelle, TVA de la
# pré-comptabilisation, statuts rattachés sans ambiguïté, erreurs traduites.

private alias S = Einvoicing::SpecSupport
private alias Api = Einvoicing::Api
private alias Inv = Partiduo::Api::Invoicing
private alias Connector = Einvoicing::Connector

private def ready : Nil
  S.books
  S.connect_afnor
end

private def matched(invoice : Inv::DocumentView, id : String, amount : String = "960.00") : Nil
  Partiduo::Api::Transaction.run do
    Partiduo::Events.publish("payment.matched", {"matching_id" => id, "sources" => "invoice:#{invoice.id}",
                                                 "amounts" => "invoice:#{invoice.id}=#{amount}", "matched_on" => "2026-09-20"})
    Partiduo::Api::Result(Nil).success(nil)
  end
end

private def row_of(invoice : Inv::DocumentView) : Einvoicing::Transmission
  Einvoicing::Transmission.filter(invoice_id: invoice.id).first!
end

# Plateforme qui répond au dépôt par un rejet immédiat (213), ou qui lève
# une erreur hors du contrat des connecteurs.
private class ScriptedConnector < Einvoicing::Connector
  getter submitted = 0

  def initialize(@outcome : String)
  end

  def submit(invoice : OutgoingInvoice) : Submission
    @submitted += 1
    raise KeyError.new("clé absente") if @outcome == "crash"
    Submission.new(platform_ref: "REJ-#{invoice.tracking_id}", status: @outcome, reason_code: "BR-FR-01",
      reason: "SIREN absent")
  end

  def fetch_incoming(after : Cursor?) : Page(IncomingInvoice)
    Page(IncomingInvoice).new([] of IncomingInvoice, after, false)
  end

  def send_status(event : LifecycleEvent) : Nil
  end

  def fetch_statuses(after : Cursor?) : Page(LifecycleEvent)
    Page(LifecycleEvent).new([] of LifecycleEvent, after, false)
  end

  def send_ereporting(batch : EReportingBatch) : Nil
  end

  def check : Nil
  end

  def mode : String
    "sandbox"
  end
end

describe "Facturation électronique : remarques de relecture (clôture du lot E)" do
  it "attend le dépôt pour « Encaissée » : paiement lettré avant la synchronisation (D-EINV-020)" do
    ready
    invoice = S.issue
    matched(invoice, "91")
    row = S.transmission(invoice)
    # La facture reste à transmettre ; le 212 attend, rien n'est émis.
    {row.status, row.last_code}.should eq({"pending", ""})
    Einvoicing::Event.filter(code: "212").first!.state.should eq("to_send")
    S.platform.sent(syntax: "CDAR").should be_empty

    sync = Api.synchronize(S.admin).value!
    sync.transmitted.should eq(1)
    sync.errors.should be_empty
    S.platform.sent("CustomerInvoice").size.should eq(1)
    # Déposée dans la même synchronisation, puis « Encaissée » émise.
    sync.sent_statuses.should eq(1)
    cdar = String.new(S.platform.sent(syntax: "CDAR").first.content)
    cdar.should contain("<ram:ProcessConditionCode>212</ram:ProcessConditionCode>")
    {S.transmission(invoice).status, S.transmission(invoice).last_code}.should eq({"paid", "212"})
    Api.outgoing_attention_count(S.admin).should eq(0)
  end

  it "garde une facture rejetée (213) à retransmettre quand elle est payée" do
    ready
    invoice = S.issue
    Api.synchronize(S.admin)
    S.platform.acknowledge(S.platform.sent("CustomerInvoice").first, "Error", "BT-48 manquant")
    Api.synchronize(S.admin)
    matched(invoice, "92")
    S.transmission(invoice).status.should eq("rejected")
    Api.synchronize(S.admin).value!.sent_statuses.should eq(0)
    S.platform.sent(syntax: "CDAR").should be_empty
    Einvoicing::Event.filter(code: "212").first!.state.should eq("to_send")

    Api.transmit(S.admin, S.transmission(invoice).id).value!.status.should eq("submitted")
    Api.synchronize(S.admin).value!.sent_statuses.should eq(1)
    S.transmission(invoice).status.should eq("paid")
  end

  it "relit le canal avant de transmettre : courriel puis plateforme, plateforme puis papier (D-EINV-021)" do
    ready
    by_mail = S.issue(channel: "email")
    S.transmission(by_mail).route.should eq("off_platform")
    Inv.set_issue_channel(S::SYSTEM, by_mail.id, Inv::ChannelInput.new("platform")).value!
    on_paper = S.issue
    Inv.set_issue_channel(S::SYSTEM, on_paper.id, Inv::ChannelInput.new("paper")).value!

    Api.synchronize(S.admin).value!.transmitted.should eq(1)
    S.platform.sent("CustomerInvoice").map(&.tracking_id).should eq([S.transmission(by_mail).tracking_id])
    {S.transmission(by_mail).route, S.transmission(by_mail).status, S.transmission(by_mail).channel}
      .should eq({"platform", "submitted", "platform"})
    paper = S.transmission(on_paper)
    {paper.route, paper.status, paper.channel, paper.platform_required}.should eq({"off_platform", "off_platform", "paper", true})
    paper.transmittable?.should be_false
    row_of(on_paper).platform_ref.should be_nil
  end

  it "ne dépose pas une facture déjà envoyée par un autre moyen, et relit le canal avant « Transmettre »" do
    ready
    sent = S.issue
    Inv.mark_sent(S::SYSTEM, sent.id).value!
    other = S.issue
    Inv.set_issue_channel(S::SYSTEM, other.id, Inv::ChannelInput.new("email")).value!

    result = Api.transmit(S.admin, S.transmission(other).id)
    result.error_keys.should eq(["einvoicing.errors.transmission.not_transmittable"])
    Api.synchronize(S.admin).value!.transmitted.should eq(0)
    S.platform.sent("CustomerInvoice").should be_empty
    row = row_of(sent)
    {row.route, row.status, row.channel_final}.should eq({"off_platform", "off_platform", true})
  end

  it "suit un client passé à l'international : e-reporting déclaré, puis voie figée" do
    ready
    foreign = S.card("CUSTOMER", "Müller GmbH", "CLI-MULLER", vat: "DE129273398", country: "DE", email: "rechnung@mueller.test")
    invoice = S.issue(foreign, channel: "platform")
    S.transmission(invoice).route.should eq("platform")
    Inv.set_issue_channel(S::SYSTEM, invoice.id, Inv::ChannelInput.new("email")).value!
    Api.synchronize(S.admin).value!.reports.should eq(1)
    S.platform.sent("CustomerInvoice").should be_empty
    {S.transmission(invoice).route, S.transmission(invoice).status}.should eq({"international", "ereporting"})
    Einvoicing::Report.filter(transmission_id: S.transmission(invoice).id, state: "sent").count.should eq(1)
    Api.synchronize(S.admin)
    row_of(invoice).channel_final.should be_true
  end

  it "ne marque pas envoyée une facture rejetée au dépôt : son canal reste modifiable (D-EINV-021)" do
    ready
    invoice = S.issue
    row = row_of(invoice)
    connector = ScriptedConnector.new("error")
    Einvoicing::Outgoing.transmit!(row, connector, "SCRIPT", nil).should be_nil
    {row.status, row.last_code}.should eq({"rejected", "213"})
    Inv.document(S::SYSTEM, invoice.id).sent_at.should be_nil
    Inv.set_issue_channel(S::SYSTEM, invoice.id, Inv::ChannelInput.new("paper")).success?.should be_true
    # Déjà traitée : une seconde passe ne redépose pas.
    Einvoicing::Outgoing.transmit!(row, connector, "SCRIPT", nil).should be_nil
    connector.submitted.should eq(1)
  end

  it "note sur la facture une erreur hors du contrat des connecteurs, sans interrompre" do
    ready
    invoice = S.issue
    row = row_of(invoice)
    error = Einvoicing::Outgoing.transmit!(row, ScriptedConnector.new("crash"), "SCRIPT", nil)
    error.should_not be_nil
    view = S.transmission(invoice)
    {view.status, view.attempts}.should eq({"pending", 1})
    view.error.should contain("clé absente")
    I18n.with_locale("en") { S.transmission(invoice).error.should start_with("Internal error during transmission") }
  end

  it "exclut deux synchronisations ou transmissions simultanées (D-EINV-022)" do
    ready
    invoice = S.issue
    id = S.transmission(invoice).id
    Einvoicing::Sync.exclusive do
      Api.synchronize(S.admin).error_keys.should eq(["einvoicing.errors.sync.running"])
      Api.transmit(S.admin, id).error_keys.should eq(["einvoicing.errors.sync.running"])
    end
    S.platform.sent("CustomerInvoice").should be_empty
    Api.synchronize(S.admin).value!.transmitted.should eq(1)
    # Verrou rendu : une transmission de la même facture ne redépose rien.
    Api.transmit(S.admin, id).error_keys.should eq(["einvoicing.errors.transmission.not_transmittable"])
    S.platform.sent("CustomerInvoice").size.should eq(1)
  end

  it "refuse de pré-comptabiliser une TVA sans taux du dossier, ou une écriture qui ne fait pas le TTC" do
    ready
    S.supplier
    seven = Api.import(S.admin, "f7.xml", String.new(S.ubl_invoice(number: "FM-7")).gsub("<cbc:Percent>20.00</cbc:Percent>",
      "<cbc:Percent>7.00</cbc:Percent>").to_slice).value!
    Api.purchase_prefill(S.admin, seven.id).errors.map { |error| {error.field, error.key} }
      .should eq([{"vat", "einvoicing.errors.reception.vat_rate_unknown"}])
    Api.post(S.admin, seven.id).error_keys.should eq(["einvoicing.errors.reception.vat_rate_unknown"])
    Api.reception(S.admin, seven.id).status.should eq("received")

    normal = Api.import(S.admin, "f20.xml", S.ubl_invoice(number: "FM-20")).value!
    blind = Partiduo::Api::Actor.user(S.admin.user_id || 1_i64, S::PERMISSIONS - ["vat.rate.read"], level: 3)
    Api.purchase_prefill(blind, normal.id).error_keys.should eq(["einvoicing.errors.reception.vat_rates_unreadable"])

    wrong = Api.import(S.admin, "fx.xml", S.ubl_invoice(number: "FM-X", gross: "310.00")).value!
    Api.purchase_prefill(S.admin, wrong.id).errors.map { |error| {error.field, error.key} }
      .should eq([{"total", "einvoicing.errors.reception.total_mismatch"}])
    Api.purchase_prefill(S.admin, normal.id).success?.should be_true
  end

  it "rattache un statut sans référence par le numéro et le SIREN du vendeur, jamais au seul numéro" do
    ready
    S.supplier
    S.card("SUPPLIER", "Plomberie Bernard", "FOUR-BERNARD", siren: S::SUPPLIER2_SIREN)
    first = Api.import(S.admin, "a.xml", S.ubl_invoice(number: "F-1")).value!
    second = Api.import(S.admin, "b.xml", S.ubl_invoice(number: "F-1", siren: S::SUPPLIER2_SIREN)).value!
    event = ->(siren : String?) do
      Connector::LifecycleEvent.new(code: "202", occurred_at: Time.utc, direction: "incoming", invoice_number: "F-1",
        platform_ref: "st-#{siren}", seller: siren.try { |value| Connector::Party.new(name: "", siren: value) })
    end
    Einvoicing::Lifecycle.apply!(event.call(nil)).should be_false
    Einvoicing::Lifecycle.apply!(event.call(S::SUPPLIER2_SIREN)).should be_true
    Api.reception_events(S.admin, second.id).map(&.code).should eq(["202"])
    Api.reception_events(S.admin, first.id).should be_empty
  end

  it "traduit les erreurs de transport à la lecture (D-EINV-024)" do
    error = expect_raises(Einvoicing::ConnectorError) do
      Einvoicing::Http::NetTransport.new.exec(Einvoicing::Http::Request.new("GET", "http://pa.test/x"))
    end
    error.key.should eq("einvoicing.errors.transport.https")
    I18n.with_locale("en") { error.localized.should eq("Non-HTTPS address refused: http://pa.test/x") }
    I18n.with_locale("nl") { Einvoicing::ErrorText.translate(error.text).should start_with("Niet-HTTPS-adres geweigerd") }
    line = Einvoicing::ErrorText.encode("einvoicing.errors.sync.invoice", {"number" => "F-9", "detail" => error.text})
    I18n.with_locale("en") { Einvoicing::ErrorText.translate(line).should eq("Invoice F-9: Non-HTTPS address refused: http://pa.test/x") }
    # Texte brut (motif de la plateforme) : rendu tel quel.
    Einvoicing::ErrorText.translate("BT-48 manquant").should eq("BT-48 manquant")
  end

  it "ne montre les factures émises qu'avec la lecture de la Facturation (D-EINV-023)" do
    ready
    invoice = S.issue
    reader = S.reader
    expect_raises(Partiduo::Api::Forbidden) { Api.transmissions(reader) }
    expect_raises(Partiduo::Api::Forbidden) { Api.transmission(reader, S.transmission(invoice).id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.transmission_for_invoice(reader, invoice.id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.transmission_events(reader, S.transmission(invoice).id) }
    both = Partiduo::Api::Actor.user(2_i64, [Api::READ, "invoicing.invoice.read"])
    Api.transmissions(both).size.should eq(1)
  end
end
