# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Einvoicing::SpecSupport
private alias Api = Einvoicing::Api
private alias Acc = Partiduo::Api::Accounting

private def ready : Nil
  S.books
  S.connect_afnor
end

private def delivered(count : Int32 = 3) : Nil
  S.platform.deliver(S.ubl_invoice, "FM-2026-0412.xml", "UBL")
  S.platform.deliver(S.cii_invoice, "PB-7781.xml", "CII") if count > 1
  S.platform.deliver(S.ubl_invoice("FM-2026-0413", net: "100.00", vat: "20.00", gross: "120.00"), "FM-2026-0413.xml", "UBL") if count > 2
end

private def reception(number : String) : Api::ReceptionView
  Api.receptions(S.admin, Api::ReceptionQuery.new(status: nil)).find! { |item| item.number == number }
end

describe "Factures reçues : lecture, boîte à traiter, décisions (ADR-004 D3, D4, D9)" do
  it "reçoit page après page par curseur, sans doublon à la synchronisation suivante" do
    ready
    S.supplier
    delivered
    sync = Api.synchronize(S.admin).value!
    sync.received.should eq(3)
    # Trois factures, deux par page : deux recherches avec curseur.
    searches = S.platform.requests.select(&.url.ends_with?("/flows/search"))
      .map { |request| JSON.parse(String.new(request.body || Bytes.empty)) }
    incoming = searches.select { |body| body["where"]["flowType"].as_a.map(&.as_s) == ["SupplierInvoice"] }
    incoming.size.should eq(2)
    incoming[1]["cursor"].as_s.should eq("off:2")
    connection = Einvoicing::Connection.filter(active: true).first!
    JSON.parse(connection.incoming_cursor.to_s)["t"]?.should_not be_nil

    Api.synchronize(S.admin).value!.received.should eq(0)
    Einvoicing::Reception.all.count.should eq(3)
    Api.pending_count(S.admin).should eq(3)
    # Une facture livrée plus tard est lue à partir du curseur conservé.
    S.platform.deliver(S.ubl_invoice("FM-2026-0500"), "FM-2026-0500.xml", "UBL")
    Api.synchronize(S.admin).value!.received.should eq(1)
  end

  it "dépose chaque facture dans la boîte « Justificatifs à traiter » de DOCUMENT, fiche reconnue par le SIREN" do
    ready
    supplier = S.supplier
    delivered(1)
    Api.synchronize(S.admin)
    view = reception("FM-2026-0412")
    {view.syntax, view.supplier_name, view.supplier_siren, view.supplier_card_id}
      .should eq({"UBL", "Fournitures Martin SAS", S::SUPPLIER_SIREN, supplier.id})
    {view.total_net, view.total_vat, view.total_gross}.should eq({S.d("250"), S.d("50"), S.d("300")})
    view.lines.first.description.should eq("Ramettes de papier")
    view.vat_lines.first.percent.should eq(S.d("20"))
    receipt = Document::Api.receipt(S.admin, (view.receipt_id || 0_i64))
    {receipt.source, receipt.status, receipt.kind}.should eq({"einvoice", "to_process", "invoice"})
    {receipt.supplier_code, receipt.amount, receipt.reference}.should eq({"FOUR-MARTIN", S.d("300"), "FM-2026-0412"})
    receipt.external_ref.should eq("einvoicing:#{view.platform_ref}")
    Document::Api.file(S.admin, receipt.id).content.should eq(S.ubl_invoice)
  end

  it "reçoit un Factur-X : PDF lisible dans la boîte, XML embarqué en données structurées" do
    ready
    customer_invoice = S.issue # un PDF/A-3 Factur-X réel produit par la Facturation
    pdf = Partiduo::Api::Invoicing.document_pdf(S::SYSTEM, customer_invoice.id).content
    S.platform.deliver(pdf, "facture.pdf", "Factur-X")
    Api.synchronize(S.admin)
    view = reception(customer_invoice.number.to_s)
    view.syntax.should eq("Factur-X")
    view.total_gross.should eq(S.d("960"))
    receipt = Document::Api.receipt(S.admin, (view.receipt_id || 0_i64))
    receipt.content_type.should eq("application/pdf")
    receipt.data_attachment_id.should_not be_nil
    Api.reception_file(S.admin, view.id, "xml").content_type.should eq("application/xml")
    Api.reception_file(S.admin, view.id).content.should eq(pdf)
  end

  it "garde une facture illisible avec ses erreurs de lecture" do
    ready
    S.platform.deliver("%PDF-1.4\nsans xml\n%%EOF".to_slice, "scan.pdf", "Factur-X")
    Api.synchronize(S.admin)
    view = Api.receptions(S.admin).first
    view.read_errors.first.should contain("PDF")
    view.number.should eq("")
    Document::Api.receipt(S.admin, (view.receipt_id || 0_i64)).status.should eq("to_process")
  end

  it "accepte une facture (décision locale)" do
    ready
    delivered(1)
    Api.synchronize(S.admin)
    view = reception("FM-2026-0412")
    accepted = Api.accept(S.admin, view.id).value!
    accepted.status.should eq("accepted")
    Api.accept(S.admin, view.id).errors.first.key.should eq("einvoicing.errors.reception.status.not_received")
  end

  it "refuse une facture : « Refusée » (210) émise avec son motif, justificatif écarté" do
    ready
    delivered(1)
    Api.synchronize(S.admin)
    view = reception("FM-2026-0412")
    Api.refuse(S.admin, view.id, Api::RefuseInput.new("INCONNU")).errors.first.key.should eq("einvoicing.errors.reception.reason_code")
    Api.refuse(S.admin, view.id, Api::RefuseInput.new("AUTRE")).errors.first.key.should eq("einvoicing.errors.reception.reason_blank")
    refused = Api.refuse(S.admin, view.id, Api::RefuseInput.new("DOUBLON", "Déjà reçue en juillet")).value!
    refused.status.should eq("refused")
    refused.decided_at.should_not be_nil
    event = Api.reception_events(S.admin, view.id).first
    {event.code, event.issuer, event.reason_code, event.state}.should eq({"210", "buyer", "DOUBLON", "sent"})
    xml = String.new(S.platform.sent(syntax: "CDAR").first.content)
    xml.should contain("<ram:ProcessConditionCode>210</ram:ProcessConditionCode>")
    xml.should contain("<ram:ReasonCode>DOUBLON</ram:ReasonCode>")
    xml.should contain("<ram:RoleCode>BY</ram:RoleCode>")
    Document::Api.receipt(S.admin, (view.receipt_id || 0_i64)).status.should eq("discarded")
    Api.refuse(S.admin, view.id, Api::RefuseInput.new("DOUBLON")).errors.first.key.should eq("einvoicing.errors.reception.status.already_decided")
  end

  it "pré-comptabilise dans le journal d'achats par le service d'écriture ; le justificatif est rattaché" do
    ready
    S.supplier
    delivered(1)
    Api.synchronize(S.admin)
    view = reception("FM-2026-0412")
    prefill = Api.purchase_prefill(S.admin, view.id).value!
    prefill.number.should eq("FM-2026-0412")
    prefill.origin.should eq(Acc::ReceptionOrigin::Platform)
    prefill.document.third_party.should eq("FOUR-MARTIN")
    prefill.document.lines.map { |line| {line.amount, line.vat_rate, line.vat_amount} }.should eq([{S.d("250"), "NOR", S.d("50")}])
    Api.check_post(S.admin, view.id).success?.should be_true

    posted = Api.post(S.admin, view.id).value!
    {posted.number, posted.total_amount, posted.origin}.should eq({"FM-2026-0412", S.d("300"), Acc::ReceptionOrigin::Platform})
    posted.platform_reference.should eq(view.platform_ref)
    after = Api.reception(S.admin, view.id)
    {after.status, after.entry_id, after.received_invoice_id}.should eq({"posted", posted.entry_id, posted.id})
    entry = Acc.entry(S.admin, posted.entry_id)
    receipt = Document::Api.receipt(S.admin, (view.receipt_id || 0_i64))
    entry.attachment_id.should eq(receipt.original_attachment_id)
    {receipt.status, receipt.entry_id}.should eq({"attached", posted.entry_id})
    Api.post(S.admin, view.id).errors.first.key.should eq("einvoicing.errors.reception.status.already_decided")
  end

  it "détecte le doublon avec une facture reçue hors plateforme et refuse de la pré-comptabiliser (ADR-004 D9)" do
    ready
    S.supplier
    delivered(1)
    Api.synchronize(S.admin)
    view = reception("FM-2026-0412")
    # La même facture, reçue en PDF simple et saisie à la main.
    attachment = Partiduo::Api::Core.store_attachment(S.admin, Partiduo::Api::Core::AttachmentInput.new("fm.pdf",
      "application/pdf", IO::Memory.new("%PDF-1.4\n%%EOF\n"))).value!
    ledger = Acc.ledgers(S.admin, Acc::LedgerKind::Purchase).first
    manual = Acc::DocumentInput.new(ledger_id: ledger.id, date: S.date("2026-09-05"), third_party: "FOUR-MARTIN",
      lines: [Acc::DocumentLineInput.new(amount: S.d("250"), vat_rate: "NOR")], attachment_id: attachment.id)
    off = Acc.post_received_invoice(S.admin, Acc::ReceivedInvoiceInput.new(document: manual, number: "FM 2026/0412")).value!
    off.off_platform?.should be_true

    duplicates = Api.duplicates(S.admin, view.id)
    duplicates.found?.should be_true
    duplicates.received_invoices.map(&.id).should eq([off.id])
    result = Api.post(S.admin, view.id)
    result.failure?.should be_true
    result.errors.map(&.key).should contain("accounting.errors.received_invoice.duplicate")
    Api.reception(S.admin, view.id).status.should eq("received")
  end

  it "signale une même facture reçue deux fois par la plateforme" do
    ready
    S.supplier
    S.platform.deliver(S.ubl_invoice, "a.xml", "UBL")
    S.platform.deliver(S.ubl_invoice("fm-2026-0412"), "b.xml", "UBL")
    Api.synchronize(S.admin)
    first = Api.receptions(S.admin).min_by(&.id)
    Api.duplicates(S.admin, first.id).receptions.map(&.number).should eq(["fm-2026-0412"])
  end

  it "refuse de pré-comptabiliser sans fiche fournisseur, un avoir est signé négativement" do
    ready
    S.platform.deliver(S.ubl_invoice(credit: true, number: "AV-12"), "av.xml", "UBL")
    Api.synchronize(S.admin)
    view = reception("AV-12")
    view.credit_note?.should be_true
    view.signed_gross.should eq(S.d("-300"))
    Api.purchase_prefill(S.admin, view.id).errors.map(&.key).should eq(["einvoicing.errors.reception.supplier_unknown"])
    S.supplier
    # La fiche créée après la réception n'est pas rattachée : la facture en
    # garde la trace, mais la saisie exige la fiche.
    Einvoicing::Reception.filter(id: view.id).update(supplier_card_id: S.supplier.id)
    prefill = Api.purchase_prefill(S.admin, view.id).value!
    prefill.document.lines.first.amount.should eq(S.d("-250"))
    Api.post(S.admin, view.id).value!.total_amount.should eq(S.d("-300"))
  end

  it "reçoit à la main un fichier déposé, et refuse un fichier inconnu" do
    ready
    Api.import(S.admin, "pb.xml", S.cii_invoice).value!.syntax.should eq("CII")
    Api.import(S.admin, "pb.xml", S.cii_invoice).value!.id.should eq(Api.receptions(S.admin).first.id)
    Api.import(S.admin, "note.txt", "bonjour".to_slice).errors.first.key.should eq("einvoicing.errors.reception.unreadable")
  end
end
