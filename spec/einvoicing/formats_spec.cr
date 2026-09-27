# SPDX-License-Identifier: AGPL-3.0-or-later

require "../spec_helper"

private alias S = Einvoicing::SpecSupport
private alias F = Einvoicing::Formats

describe "Formats de la facture électronique (ADR-004 D3)" do
  it "reconnaît UBL, CII et Factur-X à leur contenu" do
    F::Reader.detect(S.ubl_invoice).should eq("UBL")
    F::Reader.detect(S.ubl_invoice(credit: true)).should eq("UBL")
    F::Reader.detect(S.cii_invoice).should eq("CII")
    F::Reader.detect("%PDF-1.7\n".to_slice).should eq("Factur-X")
    F::Reader.detect("<html><body/></html>".to_slice).should be_nil
    F::Reader.detect("bonjour".to_slice).should be_nil
    expect_raises(F::ReadError) { F::Reader.parse("<a/>".to_slice) }
  end

  it "lit une facture UBL : fournisseur (SIREN 0002), montants, TVA, lignes" do
    parsed = F::Reader.parse(S.ubl_invoice)
    parsed.syntax.should eq("UBL")
    parsed.profile.should eq(F::EN16931)
    parsed.number.should eq("FM-2026-0412")
    parsed.type_code.should eq("380")
    parsed.issue_date.should eq(S.date("2026-09-05"))
    parsed.due_date.should eq(S.date("2026-10-05"))
    parsed.seller.name.should eq("Fournitures Martin SAS")
    parsed.seller.siren.should eq(S::SUPPLIER_SIREN)
    parsed.seller.vat_number.should eq("FR83#{S::SUPPLIER_SIREN}")
    parsed.buyer.siren.should eq(S::COMPANY_SIREN)
    parsed.total_net.should eq(S.d("250"))
    parsed.total_vat.should eq(S.d("50"))
    parsed.total_gross.should eq(S.d("300"))
    parsed.vat_lines.map { |line| {line.category, line.percent, line.base, line.amount} }
      .should eq([{"S", S.d("20"), S.d("250"), S.d("50")}])
    parsed.lines.first.description.should eq("Ramettes de papier")
    parsed.lines.first.quantity.should eq(S.d("10"))
    parsed.notes.should eq(["Fournitures de bureau"])
    parsed.credit_note?.should be_false
    F::Reader.parse(S.ubl_invoice(credit: true)).credit_note?.should be_true
  end

  it "lit une facture CII (D16B à D22B)" do
    parsed = F::Reader.parse(S.cii_invoice)
    parsed.syntax.should eq("CII")
    parsed.number.should eq("PB-7781")
    parsed.issue_date.should eq(S.date("2026-09-07"))
    parsed.due_date.should eq(S.date("2026-10-07"))
    parsed.currency_code.should eq("EUR")
    parsed.seller.name.should eq("Plomberie Bernard")
    parsed.seller.siren.should eq(S::SUPPLIER2_SIREN)
    parsed.total_gross.should eq(S.d("120"))
    parsed.payable.should eq(S.d("120"))
    parsed.lines.first.unit_code.should eq("HUR")
    parsed.vat_lines.first.amount.should eq(S.d("20"))
  end

  it "tire le SIREN d'un SIRET, d'une adresse de l'annuaire ou d'un numéro de TVA français" do
    F.siren_from(S::SUPPLIER_SIREN, F::SCHEME_SIREN).should eq(S::SUPPLIER_SIREN)
    F.siren_from("#{S::SUPPLIER_SIREN}00017", F::SCHEME_SIRET).should eq(S::SUPPLIER_SIREN)
    F.siren_from("#{S::SUPPLIER_SIREN}_#{S::SUPPLIER_SIREN}00017_SERV", F::SCHEME_FR_ADDR).should eq(S::SUPPLIER_SIREN)
    F.siren_from("FR 83 #{S::SUPPLIER_SIREN}").should eq(S::SUPPLIER_SIREN)
    F.siren_from("BE0417497106").should eq("")
    F.amount(S.d("0.00001")).should eq("0.00")
    F.amount(S.d("-12.345")).should eq("-12.35")
    F.amount(S.d("1e20")).should eq("100000000000000000000.00")
  end

  it "produit l'UBL 2.1 EN 16931 d'une facture émise, relu à l'identique (SIREN 0002, adresse 0225)" do
    S.books
    invoice = S.issue
    xml = Einvoicing::Outgoing.ubl(invoice)
    xml.should contain(%(<cbc:CustomizationID>urn:cen.eu:en16931:2017</cbc:CustomizationID>))
    xml.should contain(%(<cbc:CompanyID schemeID="0002">#{S::COMPANY_SIREN}</cbc:CompanyID>))
    xml.should contain(%(<cbc:CompanyID schemeID="0002">#{S::CUSTOMER_SIREN}</cbc:CompanyID>))
    xml.should contain(%(<cbc:EndpointID schemeID="0225">#{S::CUSTOMER_SIREN}</cbc:EndpointID>))
    xml.should_not contain(%(schemeID="0009"))
    parsed = F::Reader.parse(xml.to_slice)
    parsed.number.should eq(invoice.number)
    parsed.type_code.should eq("380")
    parsed.seller.siren.should eq(S::COMPANY_SIREN)
    parsed.buyer.siren.should eq(S::CUSTOMER_SIREN)
    parsed.total_net.should eq(S.d("800"))
    parsed.total_vat.should eq(S.d("160"))
    parsed.total_gross.should eq(S.d("960"))
    parsed.lines.size.should eq(1)
    parsed.lines.first.unit_code.should eq("HUR")

    peppol = Einvoicing::Outgoing.ubl(invoice, peppol: true)
    peppol.should contain(F::PEPPOL_BIS3)
    peppol.should contain(F::PEPPOL_PROFILE)
  end

  it "produit l'avoir UBL (CreditNote, référence de la facture corrigée)" do
    S.books
    invoice = S.issue
    credit = S.issue(kind: "credit_note", credited: invoice.id, quantity: "2")
    xml = Einvoicing::Outgoing.ubl(credit)
    xml.should contain("<CreditNote xmlns=\"urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2\"")
    xml.should contain("<cbc:CreditNoteTypeCode>381</cbc:CreditNoteTypeCode>")
    xml.should match(%r{<cac:InvoiceDocumentReference>\s*<cbc:ID>#{invoice.number}</cbc:ID>})
    F::Reader.parse(xml.to_slice).credit_note?.should be_true
  end

  it "produit à la demande le CII EN 16931 et EXTENDED-CTC-FR depuis le XML Factur-X de la Facturation" do
    S.books
    invoice = S.issue
    cii = Einvoicing::Outgoing.cii(invoice, F::EN16931)
    extended = Einvoicing::Outgoing.cii(invoice, F::EXTENDED_CTC_FR)
    cii.should contain("<ram:ID>urn:cen.eu:en16931:2017</ram:ID>")
    extended.should contain("<ram:ID>#{F::EXTENDED_CTC_FR}</ram:ID>")
    F::Reader.parse(extended.to_slice).profile.should eq(F::EXTENDED_CTC_FR)
    F::Reader.parse(cii.to_slice).total_gross.should eq(S.d("960"))
    # Vente B2C : note BAR = B2C (ADR-004 D8).
    b2c = Einvoicing::Outgoing.cii(invoice, F::EN16931, b2c: true)
    b2c.should contain("<ram:IncludedNote><ram:Content>B2C</ram:Content><ram:SubjectCode>BAR</ram:SubjectCode></ram:IncludedNote>")
    F::Reader.parse(b2c.to_slice).notes.should contain("B2C")
    expect_raises(F::Cii::Error) { F::Cii.variant("<x/>") }
  end

  it "extrait et lit le XML embarqué d'un PDF/A-3 Factur-X" do
    S.books
    invoice = S.issue
    pdf = Partiduo::Api::Invoicing.document_pdf(S::SYSTEM, invoice.id).content
    F::Reader.detect(pdf).should eq("Factur-X")
    F::Reader.embedded_xml(pdf).should_not be_nil
    parsed = F::Reader.parse(pdf)
    parsed.syntax.should eq("Factur-X")
    parsed.number.should eq(invoice.number)
    parsed.seller.siren.should eq(S::COMPANY_SIREN)
    parsed.total_gross.should eq(S.d("960"))
    expect_raises(F::ReadError) { F::Reader.parse("%PDF-1.4\nrien\n%%EOF".to_slice) }
  end

  it "écrit et relit un message de cycle de vie CDAR (statut, motif, montant)" do
    seller = Einvoicing::Connector::Party.new(name: "Atelier Brunet", siren: S::COMPANY_SIREN)
    event = Einvoicing::Connector::LifecycleEvent.new(code: "212", occurred_at: Time.utc(2026, 9, 20, 10, 0, 0),
      invoice_number: "F-2026-0001", invoice_date: S.date("2026-09-10"), issuer: "seller", amount: S.d("960"),
      seller: seller)
    xml = F::Cdar.build(event, "CDAR-1")
    xml.should contain("<ram:ProcessConditionCode>212</ram:ProcessConditionCode>")
    xml.should contain(%(<ram:ValueAmount currencyID="EUR">960.00</ram:ValueAmount>))
    status = F::Cdar.parse(xml.to_slice).first
    status.code.should eq("212")
    status.invoice_number.should eq("F-2026-0001")
    status.issuer.should eq("seller")
    status.amount.should eq(S.d("960"))
    status.occurred_at.should eq(Time.utc(2026, 9, 20, 10, 0, 0))
    refused = F::Cdar.build(event.copy_with(code: "210", issuer: "buyer", reason_code: "DOUBLON", reason: "déjà reçue", amount: nil), "CDAR-2")
    parsed = F::Cdar.parse(refused.to_slice).first
    {parsed.code, parsed.issuer, parsed.reason_code, parsed.reason}.should eq({"210", "buyer", "DOUBLON", "déjà reçue"})
    F::Cdar.parse("<x/>".to_slice).should be_empty
  end
end
