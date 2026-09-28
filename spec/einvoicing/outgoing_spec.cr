# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Einvoicing::SpecSupport
private alias Api = Einvoicing::Api
private alias Inv = Partiduo::Api::Invoicing

private def ready : Nil
  S.books
  S.connect_afnor
end

private def flow_info(flow : Einvoicing::SpecSupport::SimulatedPlatform::Flow) : {String, String, String}
  {flow.syntax, flow.rule, flow.tracking_id}
end

describe "Factures émises : relevé, route, transmission (ADR-004 D3, D8, D9)" do
  it "relève une facture émise par la plateforme (client professionnel français)" do
    ready
    invoice = S.issue
    invoice.issue_channel.should eq("platform")
    row = S.transmission(invoice)
    {row.route, row.status, row.platform_required}.should eq({"platform", "pending", false})
    {row.number, row.total_gross, row.customer_country}.should eq({invoice.number.to_s, S.d("960"), "FR"})
    row.tracking_id.should start_with("PDUO-")
    row.transmittable?.should be_true
    Api.counts(S.admin).outgoing_pending.should eq(1)
    Api.outgoing_attention_count(S.admin).should eq(1)
  end

  it "donne la route de chaque vente : B2C, international, hors plateforme signalé (ADR-004 D9)" do
    ready
    private_customer = S.card("CUSTOMER", "Jeanne Dupuis", "CLI-DUPUIS", email: "jeanne@exemple.test")
    foreign = S.card("CUSTOMER", "Müller GmbH", "CLI-MULLER", vat: "DE129273398", country: "DE", email: "rechnung@mueller.test")
    b2c = S.issue(private_customer)
    b2c.b2c.should be_true
    S.transmission(b2c).route.should eq("b2c")
    S.transmission(b2c).status.should eq("pending")
    international = S.transmission(S.issue(foreign))
    {international.route, international.status, international.customer_country}.should eq({"international", "ereporting", "DE"})
    Einvoicing::Report.filter(transmission_id: international.id).count.should eq(1)
    off = S.transmission(S.issue(channel: "email"))
    {off.route, off.status, off.platform_required}.should eq({"off_platform", "off_platform", true})
    off.transmittable?.should be_false
  end

  it "laisse hors plateforme, sans signalement, une facture à un client public (Chorus Pro, ADR-004 D9 révisé)" do
    ready
    city = S.card("CUSTOMER", "Ville de Paris", "CLI-PARIS", siren: "217500016", email: "factures@paris.test")
    # Sans l'extension CHORUSPRO, le cœur propose le courriel (dépôt à la
    # main sur le portail) : la nature suffit à laisser la facture hors
    # plateforme, sans signalement.
    Partiduo::Api::Invoicing.propose_channel(S.admin, city.id).channel.should eq("email")
    row = S.transmission(S.issue(city))
    {row.channel, row.route, row.status, row.platform_required}.should eq({"email", "off_platform", "off_platform", false})
    row.transmittable?.should be_false
    portal = S.transmission(S.issue(city, channel: "public_portal"))
    {portal.channel, portal.route, portal.status, portal.platform_required}
      .should eq({"public_portal", "off_platform", "off_platform", false})
  end

  it "transmet le PDF/A-3 Factur-X du module Facturation ; « Déposée » (200) remonte de la plateforme" do
    ready
    invoice = S.issue
    sync = Api.synchronize(S.admin).value!
    sync.transmitted.should eq(1)
    sync.errors.should be_empty
    flow = S.platform.sent("CustomerInvoice").first
    flow_info(flow).should eq({"Factur-X", "B2B", S.transmission(invoice).tracking_id})
    flow.profile.should eq("CIUS")
    flow.content.should eq(Inv.document_pdf(S::SYSTEM, invoice.id).content)
    row = S.transmission(invoice)
    {row.status, row.adapter, row.syntax, row.platform_ref}.should eq({"submitted", "AFNOR", "Factur-X", flow.id})
    # Remise par la plateforme : l'événement `invoice.platform_deposited`
    # est publié ; la Facturation, abonnée, marque la facture « envoyée » et
    # trace le dépôt (copie PDF, ADR-004 D9 révisé).
    Inv.document(S::SYSTEM, invoice.id).sent_at.should_not be_nil
    Inv.pdf_copy_status(S::SYSTEM, invoice.id).deposited_at.should_not be_nil
    deposited = Inv.document_events(S::SYSTEM, invoice.id).find!(&.action.==("platform_deposited"))
    deposited.details["platform_ref"].should eq(flow.id)

    S.platform.acknowledge(flow, "Ok")
    Api.synchronize(S.admin).value!.statuses.should eq(1)
    S.transmission(invoice).status.should eq("deposited")
    events = Api.transmission_events(S.admin, row.id)
    events.map { |event| {event.code, event.issuer, event.state} }.should eq([{"200", "platform", "received"}])
    # Relire les mêmes statuts ne crée pas de doublon (curseur et idempotence).
    Api.synchronize(S.admin).value!.statuses.should eq(0)
    Api.transmission_events(S.admin, row.id).size.should eq(1)
  end

  it "garde « submitted » quand un abonné du dépôt lève : pas de second dépôt (CGI art. 283-3, D-CPY-007)" do
    ready
    invoice = S.issue
    manifest = Partiduo::Modules.active_manifests.last
    handlers = (manifest.subscriptions["invoice.platform_deposited"] ||= [] of Partiduo::Events::Handler)
    failing = Partiduo::Events::Handler.new { |_event| raise "abonné en panne" }
    handlers << failing
    begin
      sync = Api.synchronize(S.admin).value!
    ensure
      handlers.delete(failing)
      manifest.subscriptions.delete("invoice.platform_deposited") if handlers.empty?
    end
    sync.transmitted.should eq(1)
    flow = S.platform.sent("CustomerInvoice").first
    row = S.transmission(invoice)
    {row.status, row.platform_ref, row.attempts}.should eq({"submitted", flow.id, 1})
    row.error.should contain("abonné en panne")
    # Les écritures des abonnés sont annulées (point de sauvegarde) : la
    # facture n'est pas marquée envoyée, mais le dépôt reste acquis.
    Inv.document(S::SYSTEM, invoice.id).sent_at.should be_nil
    Api.synchronize(S.admin)
    S.platform.sent("CustomerInvoice").size.should eq(1)
    S.transmission(invoice).status.should eq("submitted")
  end

  it "remonte « Rejetée » (213) avec son motif, puis retransmet" do
    ready
    invoice = S.issue
    Api.synchronize(S.admin)
    flow = S.platform.sent("CustomerInvoice").first
    S.platform.acknowledge(flow, "Error", "BT-48 manquant")
    Api.synchronize(S.admin)
    row = S.transmission(invoice)
    {row.status, row.last_code}.should eq({"rejected", "213"})
    row.error.should contain("BT-48 manquant")
    row.transmittable?.should be_true
    Api.counts(S.admin).outgoing_rejected.should eq(1)
    again = Api.transmit(S.admin, row.id).value!
    again.status.should eq("submitted")
    again.attempts.should eq(2)
    S.platform.sent("CustomerInvoice").size.should eq(2)
  end

  it "garde la facture à transmettre si la plateforme est indisponible" do
    ready
    invoice = S.issue
    S.platform.tokens # jeton obtenu à la première requête
    S.platform.fail_next = 503
    sync = Api.synchronize(S.admin).value!
    sync.transmitted.should eq(0)
    sync.errors.first.should contain("503")
    row = S.transmission(invoice)
    {row.status, row.attempts}.should eq({"pending", 1})
    Api.synchronize(S.admin).value!.transmitted.should eq(1)
  end

  it "transmet une vente B2C en CII avec la note BAR (e-reporting)" do
    ready
    private_customer = S.card("CUSTOMER", "Jeanne Dupuis", "CLI-DUPUIS", email: "jeanne@exemple.test")
    invoice = S.issue(private_customer)
    Api.synchronize(S.admin)
    flow = S.platform.sent("CustomerInvoice").first
    {flow.syntax, flow.rule}.should eq({"CII", "B2C"})
    String.new(flow.content).should contain("<ram:SubjectCode>BAR</ram:SubjectCode>")
    # Le canal de la facture (courriel) n'est pas changé : elle n'est pas
    # « envoyée » par la plateforme.
    Inv.document(S::SYSTEM, invoice.id).sent_at.should be_nil
  end

  it "déclare les ventes internationales en e-reporting, par lot mensuel" do
    ready
    foreign = S.card("CUSTOMER", "Müller GmbH", "CLI-MULLER", vat: "DE129273398", country: "DE", email: "rechnung@mueller.test")
    S.issue(foreign)
    S.issue(foreign, quantity: "2")
    sync = Api.synchronize(S.admin).value!
    sync.reports.should eq(2)
    flow = S.platform.sent(syntax: "FRR").first
    flow.rule.should eq("B2BInt")
    xml = String.new(flow.content)
    xml.should contain("<CountryId>DE</CountryId>")
    xml.should contain("<StartDate>20260901</StartDate>")
    xml.should contain("<Siren>#{S::COMPANY_SIREN}</Siren>")
    Einvoicing::Report.filter(state: "sent").count.should eq(2)
    Api.synchronize(S.admin).value!.reports.should eq(0)
  end

  it "émet « Encaissée » (212) au lettrage du paiement, une seule fois par lettrage" do
    ready
    invoice = S.issue
    Api.synchronize(S.admin)
    row = S.transmission(invoice)
    Partiduo::Api::Transaction.run do
      Partiduo::Events.publish("payment.matched", {"matching_id" => "77", "sources" => "invoice:#{invoice.id}",
                                                   "amounts" => "invoice:#{invoice.id}=500.00", "matched_on" => "2026-09-20"})
      Partiduo::Api::Result(Nil).success(nil)
    end
    Partiduo::Events.publish("payment.matched", {"matching_id" => "77", "sources" => "invoice:#{invoice.id}"})
    event = Api.transmission_events(S.admin, row.id).find! { |item| item.code == "212" }
    {event.issuer, event.amount, event.occurred_at, event.state}.should eq({"seller", S.d("500"), S.date("2026-09-20"), "sent"})
    Api.transmission_events(S.admin, row.id).count(&.code.==("212")).should eq(1)
    S.transmission(invoice).status.should eq("paid")
    cdar = S.platform.sent(syntax: "CDAR").first
    xml = String.new(cdar.content)
    xml.should contain("<ram:ProcessConditionCode>212</ram:ProcessConditionCode>")
    xml.should contain("<ram:IssuerAssignedID>#{invoice.number}</ram:IssuerAssignedID>")
    xml.should contain(%(<ram:ValueAmount currencyID="EUR">500.00</ram:ValueAmount>))
  end

  it "laisse « Encaissée » à émettre quand la plateforme ne répond pas, puis l'émet à la synchronisation" do
    ready
    invoice = S.issue
    Api.synchronize(S.admin)
    S.platform.fail_next = 500
    Partiduo::Events.publish("payment.recorded", {"payment_id" => "5", "invoice_id" => invoice.id.to_s, "amount" => "960.00",
                                                  "paid_on" => "2026-09-21"})
    event = Einvoicing::Event.filter(code: "212").first!
    event.state.should eq("failed")
    Api.synchronize(S.admin).value!.sent_statuses.should eq(1)
    Einvoicing::Event.filter(code: "212").first!.state.should eq("sent")
  end

  it "applique les statuts du destinataire (CDAR) : Refusée (210)" do
    ready
    invoice = S.issue
    Api.synchronize(S.admin)
    S.platform.buyer_status(invoice.number.to_s, "210", "MONTANTTOTAL_ERR", "Montant faux")
    Api.synchronize(S.admin)
    row = S.transmission(invoice)
    row.status.should eq("refused")
    event = Api.transmission_events(S.admin, row.id).last
    {event.code, event.issuer, event.reason_code, event.reason}.should eq({"210", "buyer", "MONTANTTOTAL_ERR", "Montant faux"})
  end

  it "produit à la demande Factur-X, CII, EXTENDED-CTC-FR, UBL et PEPPOL" do
    ready
    invoice = S.issue
    Api.export(S.admin, invoice.id, "facturx").content_type.should eq("application/pdf")
    Api.export(S.admin, invoice.id, "cii").filename.should eq("#{invoice.number}-cii.xml")
    String.new(Api.export(S.admin, invoice.id, "extended-ctc-fr").content).should contain("extended-ctc-fr")
    String.new(Api.export(S.admin, invoice.id, "ubl").content).should contain("<Invoice xmlns=")
    String.new(Api.export(S.admin, invoice.id, "peppol").content).should contain("poacc:billing:3.0")
    expect_raises(Partiduo::Api::NotFound) { Api.export(S.admin, invoice.id, "pdf") }
  end

  it "relève à la demande une facture émise avant l'activation" do
    S.books
    Partiduo::Api::Modules.deactivate(S::SYSTEM, "EINV")
    invoice = S.issue
    S.activate
    Api.transmission_for_invoice(S.admin, invoice.id).should be_nil
    Api.track(S.admin, invoice.id).value!.route.should eq("platform")
    Api.track(S.admin, invoice.id).value!.id.should eq(S.transmission(invoice).id)
  end
end
