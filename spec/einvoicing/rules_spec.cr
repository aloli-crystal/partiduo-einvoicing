# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

# Cas limites, permissions, modules inactifs et intégrité en base de
# l'extension EINV (lot E, testeur). Règles reprises de `peppol-connect`
# (un seul paramétrage actif, statut du document entrant) et de l'ADR-004
# (D4 cycle de vie, D9 doublons et factures non électroniques).

private alias S = Einvoicing::SpecSupport
private alias Api = Einvoicing::Api
private alias Acc = Partiduo::Api::Accounting

private def sql(query : String, *args) : Nil
  Marten::DB::Connection.default.open(&.exec(query, *args))
end

private def ready : Nil
  S.books
  S.connect_afnor
end

private def imported(number : String = "FM-2026-0412", **args) : Api::ReceptionView
  Api.import(S.admin, "#{number}.xml", S.ubl_invoice(number, **args)).value!
end

describe "EINV : règles, cas limites et intégrité (lot E)" do
  it "impose l'origine plateforme, le fichier reçu et sa référence même pour une écriture saisie à l'écran" do
    ready
    view = imported
    # Fiche inconnue à la réception : l'écriture proposée n'existe pas.
    Api.purchase_prefill(S.admin, view.id).failure?.should be_true
    S.supplier
    ledger = Acc.ledgers(S.admin, Acc::LedgerKind::Purchase).first
    typed = Acc::DocumentInput.new(ledger_id: ledger.id, date: S.date("2026-09-05"), third_party: "FOUR-MARTIN",
      lines: [Acc::DocumentLineInput.new(amount: S.d("250"), account: "6064", vat_rate: "NOR")])
    input = Acc::ReceivedInvoiceInput.new(document: typed, number: "FM-2026-0412")
    posted = Api.post(S.admin, view.id, input).value!
    posted.origin.should eq(Acc::ReceptionOrigin::Platform)
    posted.platform_reference.should eq(view.platform_ref)
    receipt = Document::Api.receipt(S.admin, view.receipt_id || 0_i64)
    Acc.entry(S.admin, posted.entry_id).attachment_id.should eq(receipt.original_attachment_id)
    {receipt.status, receipt.entry_id}.should eq({"attached", posted.entry_id})
    Api.reception(S.admin, view.id).status.should eq("posted")
  end

  it "encadre les décisions : accepter, refuser et pré-comptabiliser selon le statut" do
    ready
    S.supplier
    view = imported
    long = Api.refuse(S.admin, view.id, Api::RefuseInput.new("AUTRE", "x" * 1001))
    long.errors.map(&.key).should eq(["einvoicing.errors.reception.reason_too_long"])
    Api.refuse(S.admin, view.id, Api::RefuseInput.new("AUTRE", "   ")).errors.map(&.key)
      .should eq(["einvoicing.errors.reception.reason_blank"])
    # Motif libre facultatif pour un code précis.
    Api.accept(S.admin, view.id).success?.should be_true
    refused = Api.refuse(S.admin, view.id, Api::RefuseInput.new("MONTANTTOTAL_ERR")).value!
    refused.status.should eq("refused")
    Api.accept(S.admin, view.id).errors.map(&.key).should eq(["einvoicing.errors.reception.status.not_received"])
    Api.post(S.admin, view.id).errors.map(&.key).should eq(["einvoicing.errors.reception.status.already_decided"])

    other = imported("FM-2026-0500")
    Api.post(S.admin, other.id).success?.should be_true
    Api.refuse(S.admin, other.id, Api::RefuseInput.new("DOUBLON")).errors.map(&.key)
      .should eq(["einvoicing.errors.reception.status.already_decided"])
    # Une facture pré-comptabilisée n'émet aucun refus.
    Api.reception_events(S.admin, other.id).map(&.code).should_not contain("210")
    expect_raises(Partiduo::Api::NotFound) { Api.accept(S.admin, 999_999_i64) }
  end

  it "reçoit à la main : nom par défaut, contenu identique idempotent, permissions de DOCUMENT exigées" do
    ready
    first = Api.import(S.admin, "", S.cii_invoice).value!
    Document::Api.receipt(S.admin, first.receipt_id || 0_i64).filename.should eq("facture.xml")
    Api.import(S.admin, "autre-nom.xml", S.cii_invoice).value!.id.should eq(first.id)
    Api.import(S.admin, "vide.xml", Bytes.empty).errors.map(&.key).should eq(["einvoicing.errors.reception.unreadable"])
    receiver = Partiduo::Api::Actor.user(7_i64, [Api::READ, Api::RECEIVE])
    expect_raises(Partiduo::Api::Forbidden) { Api.import(receiver, "a.xml", S.ubl_invoice) }
    Api.counts(S.reader).incoming_to_process.should eq(1)
  end

  it "cherche dans l'annuaire à partir de trois caractères, et signale l'absence de raccordement" do
    S.books
    Api.lookup(S.admin, "  55 ").errors.map(&.key).should eq(["einvoicing.errors.directory.too_short"])
    Api.lookup(S.admin, "552100554").errors.map(&.key).should eq(["einvoicing.errors.connection.missing"])
    Api.synchronize(S.admin).errors.map(&.key).should eq(["einvoicing.errors.connection.missing"])
    Api.check_connection(S.admin).errors.map(&.key).should eq(["einvoicing.errors.connection.missing"])
    Api.connection(S.reader).should be_nil
  end

  it "synchronise avec la seule permission de recevoir ; débranchée, plus rien ne passe" do
    ready
    receiver = Partiduo::Api::Actor.user(S.admin.user_id || 1_i64, [Api::RECEIVE, Document::Api::WRITE,
                                                                    "core.attachment.write"])
    Api.synchronize(receiver).success?.should be_true
    Api.disconnect(S.admin).success?.should be_true
    Api.connection(S.admin).should be_nil
    Einvoicing::Connection.filter(adapter: "AFNOR").first!.access_token.to_s.should eq("")
    Api.synchronize(receiver).errors.map(&.key).should eq(["einvoicing.errors.connection.missing"])
    # Les paramètres restent : un nouvel enregistrement sans secret le garde.
    again = Api.configure(S.admin, Api::ConnectionInput.new("AFNOR", {
      "flow_url" => "https://pa.test/afnor-flow", "directory_url" => "https://pa.test/afnor-directory",
      "token_url" => "https://pa.test/oauth2/token", "client_id" => S::SimulatedPlatform::CLIENT_ID,
      "client_secret" => "", "organization_id" => "", "environment" => "sandbox",
    })).value!
    again.fields.find! { |field| field.name == "client_secret" }.stored.should be_true
    Api.check_connection(S.admin).success?.should be_true
  end

  it "relève et exporte seulement un document fiscal émis ; format inconnu refusé" do
    ready
    S.customer
    draft = Partiduo::Api::Invoicing.create_document(S::SYSTEM, Partiduo::Api::Invoicing::DocumentInput.new(
      kind: "invoice", customer_card_id: S.customer.id,
      lines: [Partiduo::Api::Invoicing::LineInput.new(item_card_id: S.item.id, quantity: S.d("1"))])).value!
    Api.track(S.admin, draft.id).errors.map(&.key).should eq(["einvoicing.errors.transmission.not_issued"])
    expect_raises(Partiduo::Api::NotFound) { Api.export(S.admin, draft.id, "ubl") }
    invoice = S.issue
    expect_raises(Partiduo::Api::NotFound) { Api.export(S.admin, invoice.id, "pdf") }
    tracked = Api.track(S.admin, invoice.id).value!
    Api.track(S.admin, invoice.id).value!.id.should eq(tracked.id)
    Einvoicing::Transmission.filter(invoice_id: invoice.id).count.should eq(1)
    expect_raises(Partiduo::Api::NotFound) { Api.transmission(S.admin, 999_999_i64) }
  end

  it "ne retransmet pas une facture déjà déposée" do
    ready
    invoice = S.issue
    transmission = S.transmission(invoice)
    Api.transmit(S.admin, transmission.id) if transmission.status == "pending"
    deposited = Api.transmission(S.admin, transmission.id)
    deposited.status.should_not eq("pending")
    Api.transmit(S.admin, transmission.id).errors.map(&.key)
      .should eq(["einvoicing.errors.transmission.not_transmittable"])
  end

  it "exige la Facturation pour émettre et la Comptabilité pour pré-comptabiliser (ModuleDisabled)" do
    with_active_modules("accounting") do
      S.books
      S.connect_afnor
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.transmit(S.admin, 1_i64) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.track(S.admin, 1_i64) }
    end
  end

  it "sans Comptabilité, refuse de pré-comptabiliser et ne cherche le doublon que parmi les factures reçues" do
    with_active_modules("invoicing") do
      PartiduoUi::Reference.provision("fr", ["invoicing"])
      S.activate
      PartiduoUi::Accounts.create
      S.connect_afnor
      view = imported
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.purchase_prefill(S.admin, view.id) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.post(S.admin, view.id) }
      expect_raises(Partiduo::Api::ModuleDisabled) { Api.check_post(S.admin, view.id) }
      Api.duplicates(S.admin, view.id).received_invoices.should be_empty
    end
  end

  it "refuse tout le contrat quand l'extension est désactivée (ModuleDisabled)" do
    S.books
    Partiduo::Api::Modules.deactivate(S::SYSTEM, "EINV").success?.should be_true
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.adapters(S.admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.connection(S.admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.synchronize(S.admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.receptions(S.admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.transmissions(S.admin) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.import(S.admin, "a.xml", S.ubl_invoice) }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.lookup(S.admin, "552100554") }
    expect_raises(Partiduo::Api::ModuleDisabled) { Api.counts(S.admin) }
    Api.pending_count(S.admin).should be_nil
    Api.outgoing_attention_count(S.admin).should be_nil
  end

  it "refuse les écritures à un simple lecteur" do
    ready
    view = imported
    reader = S.reader
    expect_raises(Partiduo::Api::Forbidden) { Api.accept(reader, view.id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.post(reader, view.id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.purchase_prefill(reader, view.id) }
    expect_raises(Partiduo::Api::Forbidden) { Api.transmit(reader, 1_i64) }
    expect_raises(Partiduo::Api::Forbidden) { Api.track(reader, 1_i64) }
    expect_raises(Partiduo::Api::Forbidden) { Api.configure(reader, Api::ConnectionInput.new("AFNOR")) }
    expect_raises(Partiduo::Api::Forbidden) { Api.disconnect(reader) }
    expect_raises(Partiduo::Api::Forbidden) { Api.check_connection(reader) }
    Api.reception(reader, view.id).id.should eq(view.id)
    # Le fichier reste soumis aux permissions de DOCUMENT et du socle.
    expect_raises(Partiduo::Api::Forbidden) { Api.reception_file(reader, view.id) }
  end

  it "garantit en base un seul raccordement actif et la cohérence des statuts" do
    ready
    expect_raises(Exception, /einvoicing_connection_one_active/) do
      sql("INSERT INTO einvoicing_connection (adapter, active, settings, secrets, access_token, refresh_token, " \
          "last_error, created_at, updated_at) VALUES ('AUTRE', true, '{}', '', '', '', '', now(), now())")
    end
    view = imported
    {
      "einvoicing_reception_status_check"  => "UPDATE einvoicing_reception SET status = 'lost' WHERE id = $1",
      "einvoicing_reception_posted_check"  => "UPDATE einvoicing_reception SET status = 'posted', decided_at = now() WHERE id = $1",
      "einvoicing_reception_decided_check" => "UPDATE einvoicing_reception SET status = 'refused' WHERE id = $1",
      "einvoicing_reception_fk_receipt"    => "UPDATE einvoicing_reception SET receipt_id = 999999 WHERE id = $1",
    }.each do |constraint, query|
      expect_raises(Exception, /#{constraint}/) { sql(query, view.id) }
    end

    Api.refuse(S.admin, view.id, Api::RefuseInput.new("DOUBLON")).success?.should be_true
    event = Einvoicing::Event.filter(reception_id: view.id).first!.id
    {
      "einvoicing_lifecycle_event_code_check"   => "UPDATE einvoicing_lifecycle_event SET code = '21' WHERE id = $1",
      "einvoicing_lifecycle_event_issuer_check" => "UPDATE einvoicing_lifecycle_event SET issuer = 'pa' WHERE id = $1",
      "einvoicing_lifecycle_event_state_check"  => "UPDATE einvoicing_lifecycle_event SET state = 'lost' WHERE id = $1",
      "einvoicing_lifecycle_event_amount_check" => "UPDATE einvoicing_lifecycle_event SET amount = -1 WHERE id = $1",
      "einvoicing_lifecycle_event_sent_check"   => "UPDATE einvoicing_lifecycle_event SET state = 'sent', sent_at = NULL WHERE id = $1",
      "einvoicing_lifecycle_event_target_check" => "UPDATE einvoicing_lifecycle_event SET reception_id = NULL WHERE id = $1",
    }.each do |constraint, query|
      expect_raises(Exception, /#{constraint}/) { sql(query, event) }
    end

    transmission = S.transmission(S.issue)
    {
      "einvoicing_transmission_status_check"    => "UPDATE einvoicing_transmission SET status = 'sent' WHERE id = $1",
      "einvoicing_transmission_route_check"     => "UPDATE einvoicing_transmission SET route = 'fax' WHERE id = $1",
      "einvoicing_transmission_kind_check"      => "UPDATE einvoicing_transmission SET kind = 'quote' WHERE id = $1",
      "einvoicing_transmission_submitted_check" => "UPDATE einvoicing_transmission SET status = 'deposited', platform_ref = NULL WHERE id = $1",
    }.each do |constraint, query|
      expect_raises(Exception, /#{constraint}/) { sql(query, transmission.id) }
    end
    # Le justificatif d'une facture reçue ne peut disparaître.
    expect_raises(Exception, /einvoicing_reception_fk_receipt/) do
      sql("DELETE FROM document_receipt WHERE id = $1", view.receipt_id)
    end
  end
end
