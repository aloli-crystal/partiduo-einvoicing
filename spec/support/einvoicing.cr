# SPDX-License-Identifier: AGPL-3.0-or-later

# Exécute le bloc avec une autre liste de modules actifs (`PARTIDUO_MODULES`),
# puis restaure la configuration. Sans ligne dans `modules_activation`, c'est
# l'ensemble actif de l'instance (DECISIONS D-018).
def with_active_modules(codes : String?, &)
  previous = ENV["PARTIDUO_MODULES"]?
  codes.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = codes)
  yield
ensure
  previous.nil? ? ENV.delete("PARTIDUO_MODULES") : (ENV["PARTIDUO_MODULES"] = previous)
end

module Einvoicing
  module SpecSupport
    alias Api = Einvoicing::Api
    alias Inv = Partiduo::Api::Invoicing
    alias Acc = Partiduo::Api::Accounting

    SYSTEM = Partiduo::Api::Actor.system

    # SIREN valides (clé de Luhn) : client, fournisseurs.
    CUSTOMER_SIREN  = "552100554"
    SUPPLIER_SIREN  = "542107651"
    SUPPLIER2_SIREN = "404833048"
    COMPANY_SIREN   = "732829320"

    @@platform : SimulatedPlatform?

    def self.platform : SimulatedPlatform
      @@platform || raise "plateforme simulée absente"
    end

    def self.reset_platform : SimulatedPlatform
      platform = SimulatedPlatform.new
      @@platform = platform
      Einvoicing::Http.transport = platform
      platform
    end

    PERMISSIONS = [Api::READ, Api::SEND, Api::RECEIVE, Api::CONFIGURE,
                   Document::Api::READ, Document::Api::WRITE, "core.attachment.read", "core.attachment.write",
                   "cards.card.read", "vat.rate.read", "accounting.entry.read", "accounting.entry.post",
                   "accounting.ledger.read", "invoicing.invoice.read", "invoicing.invoice.write",
                   "invoicing.invoice.issue", "invoicing.invoice.send"]

    @@admin_id : Int64 = 1_i64

    # Administrateur du dossier : un utilisateur réel (droits par journal de
    # la Comptabilité), avec les permissions de l'extension.
    def self.admin : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(@@admin_id, PERMISSIONS, level: 3)
    end

    def self.reader : Partiduo::Api::Actor
      Partiduo::Api::Actor.user(2_i64, [Api::READ])
    end

    def self.d(text : String) : BigDecimal
      BigDecimal.new(text)
    end

    def self.date(text : String) : Time
      Time.parse_utc(text, "%Y-%m-%d")
    end

    # Dossier provisionné (régime `fr` ou `be`), exercice 2026, DOCUMENT et
    # EINV actifs.
    def self.books(regime : String = "fr") : Nil
      PartiduoUi::Reference.provision(regime)
      PartiduoUi::Reference.fiscal_year(2026)
      @@admin_id = PartiduoUi::Accounts.create.user.id
      purchase_account if Partiduo::Modules.active?("ACCOUNTING")
      activate
    end

    # Dossier de `books`, raccordé à la plateforme simulée, administrateur
    # connecté dans le navigateur de test.
    def self.signed_in(regime : String = "fr") : PartiduoUi::Browser
      books(regime)
      regime == "be" ? connect_peppol : connect_afnor
      PartiduoUi::Accounts.signed_in
    end

    # Compte de charge par défaut du journal d'achats (`6064`, créé sous
    # `60`), dont la pré-comptabilisation a besoin.
    def self.purchase_account(account : String = "6064") : Nil
      Acc.create_account(SYSTEM, Acc::AccountInput.new(number: account, label: "Fournitures administratives", parent: "60")).value!
      ledger = Acc.ledgers(SYSTEM, Acc::LedgerKind::Purchase).first
      input = Acc::LedgerInput.new(name: ledger.name, kind: ledger.kind, code: ledger.code, description: ledger.description,
        enabled: ledger.enabled, default_account: account, receipt_prefix: ledger.receipt_prefix,
        receipt_padding: ledger.receipt_padding, currency_code: ledger.currency_code.presence)
      Acc.update_ledger(SYSTEM, ledger.id, input).value!
      nil
    end

    def self.activate : Nil
      Partiduo::Api::Modules.activate(SYSTEM, "DOCUMENT").value!
      Partiduo::Api::Modules.activate(SYSTEM, "EINV").value!
      nil
    end

    # Raccordement XP Z12-013 à la plateforme simulée.
    def self.connect_afnor(environment : String = "sandbox") : Api::ConnectionView
      Api.configure(admin, Api::ConnectionInput.new("AFNOR", {
        "flow_url" => "https://pa.test/afnor-flow", "directory_url" => "https://pa.test/afnor-directory",
        "token_url" => "https://pa.test/oauth2/token", "client_id" => SimulatedPlatform::CLIENT_ID,
        "client_secret" => SimulatedPlatform::CLIENT_SECRET, "organization_id" => "", "environment" => environment,
      })).value!
    end

    def self.connect_peppol : Api::ConnectionView
      Api.configure(admin, Api::ConnectionInput.new("PEPPOL_BE", {
        "url" => "https://peppol.test", "participant_id" => "0208:0417497106", "user_id" => "PDUO",
        "auth_header" => SimulatedPlatform::PEPPOL_HEADER,
        "token" => SimulatedPlatform::PEPPOL_TOKEN, "environment" => "production",
      })).value!
    end

    def self.card(category : String, name : String, code : String, siren : String? = nil, vat : String? = nil,
                  country : String? = nil, email : String? = nil) : Partiduo::Api::Cards::CardView
      found = PartiduoUi::Reference.category(category)
      address = country.try do |value|
        Partiduo::Api::Cards::AddressInput.new(line1: "1 rue du Port", postcode: "1000", city: "Ville", country_code: value)
      end
      input = Partiduo::Api::Cards::CardInput.new(category_id: found.id, name: name, code: code, siren: siren,
        vat_number: vat, address: address, email: email)
      Partiduo::Api::Cards.create_card(SYSTEM, input).value!
    end

    def self.customer : Partiduo::Api::Cards::CardView
      Partiduo::Api::Cards.card_by_code(SYSTEM, "CLI-MOREL") ||
        card("CUSTOMER", "Atelier Morel SAS", "CLI-MOREL", siren: CUSTOMER_SIREN, email: "compta@morel.test")
    end

    def self.supplier : Partiduo::Api::Cards::CardView
      Partiduo::Api::Cards.card_by_code(SYSTEM, "FOUR-MARTIN") ||
        card("SUPPLIER", "Fournitures Martin SAS", "FOUR-MARTIN", siren: SUPPLIER_SIREN)
    end

    def self.item : Partiduo::Api::Cards::CardView
      Partiduo::Api::Cards.card_by_code(SYSTEM, "CONSEIL") || begin
        rate = Partiduo::Api::Vat.rate_by_code(SYSTEM, "NOR") || Partiduo::Api::Vat.rate_by_code(SYSTEM, "21G") || raise "taux normal absent"
        input = Partiduo::Api::Cards::CardInput.new(category_id: PartiduoUi::Reference.category("SALE").id,
          name: "Conseil (heure)", code: "CONSEIL", unit_code: "HUR", sale_price: d("80"), vat_rate_id: rate.id)
        Partiduo::Api::Cards.create_card(SYSTEM, input).value!
      end
    end

    # Facture émise par la Facturation (PDF/A-3 Factur-X), `quantity` heures
    # de conseil à 80 € HT, au client donné, par le canal donné.
    def self.issue(customer : Partiduo::Api::Cards::CardView = self.customer, quantity : String = "10",
                   channel : String? = nil, b2c : Bool? = nil, kind : String = "invoice",
                   credited : Int64? = nil) : Inv::DocumentView
      product = item
      draft = Inv.create_document(SYSTEM, Inv::DocumentInput.new(kind: kind, customer_card_id: customer.id,
        lines: [Inv::LineInput.new(item_card_id: product.id, quantity: d(quantity))], issue_channel: channel, b2c: b2c,
        credited_document_id: credited)).value!
      Inv.issue(SYSTEM, draft.id, Inv::IssueInput.new(date("2026-09-10"))).value!
    end

    def self.transmission(invoice : Inv::DocumentView) : Api::TransmissionView
      Api.transmission_for_invoice(admin, invoice.id) || raise "facture #{invoice.number} non relevée"
    end

    # --- Factures reçues d'exemple ---------------------------------------------------

    def self.ubl_invoice(number : String = "FM-2026-0412", siren : String = SUPPLIER_SIREN, net : String = "250.00",
                         vat : String = "50.00", gross : String = "300.00", credit : Bool = false) : Bytes
      root = credit ? "CreditNote" : "Invoice"
      line = credit ? "CreditNoteLine" : "InvoiceLine"
      quantity = credit ? "CreditedQuantity" : "InvoicedQuantity"
      type = credit ? "<cbc:CreditNoteTypeCode>381</cbc:CreditNoteTypeCode>" : "<cbc:InvoiceTypeCode>380</cbc:InvoiceTypeCode>"
      <<-XML.to_slice
        <?xml version="1.0" encoding="UTF-8"?>
        <#{root} xmlns="urn:oasis:names:specification:ubl:schema:xsd:#{root}-2" xmlns:cac="urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2" xmlns:cbc="urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2">
          <cbc:CustomizationID>urn:cen.eu:en16931:2017</cbc:CustomizationID>
          <cbc:ID>#{number}</cbc:ID>
          <cbc:IssueDate>2026-09-05</cbc:IssueDate>
          <cbc:DueDate>2026-10-05</cbc:DueDate>
          #{type}
          <cbc:Note>Fournitures de bureau</cbc:Note>
          <cbc:DocumentCurrencyCode>EUR</cbc:DocumentCurrencyCode>
          <cac:AccountingSupplierParty><cac:Party>
            <cbc:EndpointID schemeID="0225">#{siren}</cbc:EndpointID>
            <cac:PartyName><cbc:Name>Fournitures Martin SAS</cbc:Name></cac:PartyName>
            <cac:PostalAddress><cbc:CityName>Lyon</cbc:CityName><cbc:PostalZone>69002</cbc:PostalZone><cac:Country><cbc:IdentificationCode>FR</cbc:IdentificationCode></cac:Country></cac:PostalAddress>
            <cac:PartyTaxScheme><cbc:CompanyID>FR83#{siren}</cbc:CompanyID><cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme></cac:PartyTaxScheme>
            <cac:PartyLegalEntity><cbc:RegistrationName>Fournitures Martin SAS</cbc:RegistrationName><cbc:CompanyID schemeID="0002">#{siren}</cbc:CompanyID></cac:PartyLegalEntity>
          </cac:Party></cac:AccountingSupplierParty>
          <cac:AccountingCustomerParty><cac:Party>
            <cbc:EndpointID schemeID="0225">#{COMPANY_SIREN}</cbc:EndpointID>
            <cac:PartyName><cbc:Name>Atelier Brunet SARL</cbc:Name></cac:PartyName>
            <cac:PostalAddress><cac:Country><cbc:IdentificationCode>FR</cbc:IdentificationCode></cac:Country></cac:PostalAddress>
            <cac:PartyLegalEntity><cbc:RegistrationName>Atelier Brunet SARL</cbc:RegistrationName><cbc:CompanyID schemeID="0002">#{COMPANY_SIREN}</cbc:CompanyID></cac:PartyLegalEntity>
          </cac:Party></cac:AccountingCustomerParty>
          <cac:TaxTotal>
            <cbc:TaxAmount currencyID="EUR">#{vat}</cbc:TaxAmount>
            <cac:TaxSubtotal><cbc:TaxableAmount currencyID="EUR">#{net}</cbc:TaxableAmount><cbc:TaxAmount currencyID="EUR">#{vat}</cbc:TaxAmount>
              <cac:TaxCategory><cbc:ID>S</cbc:ID><cbc:Percent>20.00</cbc:Percent><cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme></cac:TaxCategory></cac:TaxSubtotal>
          </cac:TaxTotal>
          <cac:LegalMonetaryTotal>
            <cbc:LineExtensionAmount currencyID="EUR">#{net}</cbc:LineExtensionAmount>
            <cbc:TaxExclusiveAmount currencyID="EUR">#{net}</cbc:TaxExclusiveAmount>
            <cbc:TaxInclusiveAmount currencyID="EUR">#{gross}</cbc:TaxInclusiveAmount>
            <cbc:PayableAmount currencyID="EUR">#{gross}</cbc:PayableAmount>
          </cac:LegalMonetaryTotal>
          <cac:#{line}>
            <cbc:ID>1</cbc:ID>
            <cbc:#{quantity} unitCode="C62">10</cbc:#{quantity}>
            <cbc:LineExtensionAmount currencyID="EUR">#{net}</cbc:LineExtensionAmount>
            <cac:Item><cbc:Name>Ramettes de papier</cbc:Name><cac:ClassifiedTaxCategory><cbc:ID>S</cbc:ID><cbc:Percent>20.00</cbc:Percent><cac:TaxScheme><cbc:ID>VAT</cbc:ID></cac:TaxScheme></cac:ClassifiedTaxCategory></cac:Item>
            <cac:Price><cbc:PriceAmount currencyID="EUR">25.00</cbc:PriceAmount></cac:Price>
          </cac:#{line}>
        </#{root}>
        XML
    end

    def self.cii_invoice(number : String = "PB-7781", siren : String = SUPPLIER2_SIREN) : Bytes
      <<-XML.to_slice
        <?xml version="1.0" encoding="UTF-8"?>
        <rsm:CrossIndustryInvoice xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100" xmlns:ram="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100" xmlns:udt="urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100">
          <rsm:ExchangedDocumentContext><ram:GuidelineSpecifiedDocumentContextParameter><ram:ID>urn:cen.eu:en16931:2017</ram:ID></ram:GuidelineSpecifiedDocumentContextParameter></rsm:ExchangedDocumentContext>
          <rsm:ExchangedDocument><ram:ID>#{number}</ram:ID><ram:TypeCode>380</ram:TypeCode><ram:IssueDateTime><udt:DateTimeString format="102">20260907</udt:DateTimeString></ram:IssueDateTime></rsm:ExchangedDocument>
          <rsm:SupplyChainTradeTransaction>
            <ram:IncludedSupplyChainTradeLineItem>
              <ram:AssociatedDocumentLineDocument><ram:LineID>1</ram:LineID></ram:AssociatedDocumentLineDocument>
              <ram:SpecifiedTradeProduct><ram:Name>Maintenance</ram:Name></ram:SpecifiedTradeProduct>
              <ram:SpecifiedLineTradeAgreement><ram:NetPriceProductTradePrice><ram:ChargeAmount>100.00</ram:ChargeAmount></ram:NetPriceProductTradePrice></ram:SpecifiedLineTradeAgreement>
              <ram:SpecifiedLineTradeDelivery><ram:BilledQuantity unitCode="HUR">1</ram:BilledQuantity></ram:SpecifiedLineTradeDelivery>
              <ram:SpecifiedLineTradeSettlement><ram:ApplicableTradeTax><ram:TypeCode>VAT</ram:TypeCode><ram:CategoryCode>S</ram:CategoryCode><ram:RateApplicablePercent>20</ram:RateApplicablePercent></ram:ApplicableTradeTax>
                <ram:SpecifiedTradeSettlementLineMonetarySummation><ram:LineTotalAmount>100.00</ram:LineTotalAmount></ram:SpecifiedTradeSettlementLineMonetarySummation></ram:SpecifiedLineTradeSettlement>
            </ram:IncludedSupplyChainTradeLineItem>
            <ram:ApplicableHeaderTradeAgreement>
              <ram:SellerTradeParty><ram:Name>Plomberie Bernard</ram:Name><ram:SpecifiedLegalOrganization><ram:ID schemeID="0002">#{siren}</ram:ID></ram:SpecifiedLegalOrganization><ram:PostalTradeAddress><ram:CountryID>FR</ram:CountryID></ram:PostalTradeAddress><ram:SpecifiedTaxRegistration><ram:ID schemeID="VA">FR12#{siren}</ram:ID></ram:SpecifiedTaxRegistration></ram:SellerTradeParty>
              <ram:BuyerTradeParty><ram:Name>Atelier Brunet SARL</ram:Name><ram:SpecifiedLegalOrganization><ram:ID schemeID="0002">#{COMPANY_SIREN}</ram:ID></ram:SpecifiedLegalOrganization><ram:PostalTradeAddress><ram:CountryID>FR</ram:CountryID></ram:PostalTradeAddress></ram:BuyerTradeParty>
            </ram:ApplicableHeaderTradeAgreement>
            <ram:ApplicableHeaderTradeDelivery/>
            <ram:ApplicableHeaderTradeSettlement>
              <ram:InvoiceCurrencyCode>EUR</ram:InvoiceCurrencyCode>
              <ram:ApplicableTradeTax><ram:CalculatedAmount>20.00</ram:CalculatedAmount><ram:TypeCode>VAT</ram:TypeCode><ram:BasisAmount>100.00</ram:BasisAmount><ram:CategoryCode>S</ram:CategoryCode><ram:RateApplicablePercent>20</ram:RateApplicablePercent></ram:ApplicableTradeTax>
              <ram:SpecifiedTradePaymentTerms><ram:DueDateDateTime><udt:DateTimeString format="102">20261007</udt:DateTimeString></ram:DueDateDateTime></ram:SpecifiedTradePaymentTerms>
              <ram:SpecifiedTradeSettlementHeaderMonetarySummation><ram:LineTotalAmount>100.00</ram:LineTotalAmount><ram:TaxBasisTotalAmount>100.00</ram:TaxBasisTotalAmount><ram:TaxTotalAmount currencyID="EUR">20.00</ram:TaxTotalAmount><ram:GrandTotalAmount>120.00</ram:GrandTotalAmount><ram:DuePayableAmount>120.00</ram:DuePayableAmount></ram:SpecifiedTradeSettlementHeaderMonetarySummation>
            </ram:ApplicableHeaderTradeSettlement>
          </rsm:SupplyChainTradeTransaction>
        </rsm:CrossIndustryInvoice>
        XML
    end

    # Corps `multipart/form-data` d'un formulaire avec un fichier.
    def self.multipart(fields : Hash(String, String), file : {String, String, Bytes}?) : {String, String}
      io = IO::Memory.new
      boundary = "PartiduoEinvoicingSpecBoundary"
      HTTP::FormData.build(io, boundary) do |builder|
        fields.each { |name, value| builder.field(name, value) }
        if file
          builder.file(file[0], IO::Memory.new(file[2]), HTTP::FormData::FileMetadata.new(filename: file[1]))
        end
      end
      {io.to_s, "multipart/form-data; boundary=#{boundary}"}
    end

    # Envoi d'un formulaire multipart par le navigateur de test.
    def self.upload(browser : PartiduoUi::Browser, path : String, fields : Hash(String, String),
                    file : {String, String, Bytes}?) : Marten::HTTP::Response
      body, content_type = multipart(fields, file)
      client = Marten::Spec::Client.new
      browser.jar.each { |name, value| client.cookies[name] = value }
      response = client.post(path, data: body, content_type: content_type, headers: browser.headers)
      client.cookies.each { |(name, value)| value.empty? ? browser.jar.delete(name) : (browser.jar[name] = value) }
      response
    end
  end
end

# Chaque exemple part d'une plateforme simulée vierge ; les rendus d'images
# de DOCUMENT passent par un outil factice (aucun outil externe).
Spec.before_each do
  Einvoicing::SpecSupport.reset_platform
  Document::Imaging.renderer = Einvoicing::SpecSupport::FakeRenderer.new
end

module Einvoicing
  module SpecSupport
    class FakeRenderer < Document::Imaging::Renderer
      def name : String
        "fake"
      end

      def render(input : String, content_type : String, size : Int32) : Bytes?
        Bytes[0xFF, 0xD8, 0xFF, 0xE0, size.to_u8!, 0xFF, 0xD9]
      end
    end
  end
end
