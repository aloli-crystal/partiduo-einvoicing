# SPDX-License-Identifier: AGPL-3.0-or-later

require "xml"

module Einvoicing
  module Formats
    # Production d'une facture ou d'un avoir UBL 2.1 au profil EN 16931
    # (ADR-004 D3), ou PEPPOL BIS Billing 3.0 pour le point d'accès belge.
    # Successeur de `InvoiceUBL21` de NOALYSS
    # (`include/XMLDocument/invoiceubl21.class.php`), construit depuis la vue
    # d'un document émis du module Facturation (`Partiduo::Api::Invoicing`),
    # jamais depuis ses tables.
    #
    # SIREN en schéma `0002` (NOALYSS écrivait `0009`, ADR-004 § Contexte) ;
    # adresse électronique `0225` (annuaire français) ou `0208` (numéro
    # d'entreprise belge).
    module Ubl
      alias Inv = Partiduo::Api::Invoicing

      NS_INVOICE = "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
      NS_CREDIT  = "urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2"
      NS_CAC     = "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
      NS_CBC     = "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2"

      # Codes UNTDID 4461 des moyens de paiement.
      TRANSFER = "58"

      def self.build(view : Inv::DocumentView, iban : String = "", bic : String = "", peppol : Bool = false) : String
        type_code = view.type_code || raise ArgumentError.new("document non fiscal : #{view.kind}")
        credit = view.kind == "credit_note"
        root = credit ? "CreditNote" : "Invoice"
        currency = view.currency_code
        XML.build(encoding: "UTF-8", indent: "  ") do |xml|
          xml.element(root, {"xmlns" => credit ? NS_CREDIT : NS_INVOICE, "xmlns:cac" => NS_CAC, "xmlns:cbc" => NS_CBC}) do
            cbc(xml, "CustomizationID", peppol ? PEPPOL_BIS3 : EN16931)
            cbc(xml, "ProfileID", PEPPOL_PROFILE) if peppol
            cbc(xml, "ID", view.number.to_s)
            cbc(xml, "IssueDate", iso(view.issue_date || raise ArgumentError.new("document sans date d'émission")))
            if !credit && (due = view.due_date)
              cbc(xml, "DueDate", iso(due))
            end
            cbc(xml, credit ? "CreditNoteTypeCode" : "InvoiceTypeCode", type_code)
            I18n.with_locale(view.locale) do
              view.mentions.each { |mention| cbc(xml, "Note", mention.message) }
            end
            cbc(xml, "Note", view.notes) unless view.notes.empty?
            cbc(xml, "DocumentCurrencyCode", currency)
            cbc(xml, "BuyerReference", view.buyer_reference) unless view.buyer_reference.empty?
            unless view.order_reference.empty?
              xml.element("cac:OrderReference") { cbc(xml, "ID", view.order_reference) }
            end
            if credited = view.credited
              xml.element("cac:BillingReference") do
                xml.element("cac:InvoiceDocumentReference") { cbc(xml, "ID", credited.number.to_s) }
              end
            end
            xml.element("cac:AccountingSupplierParty") { party(xml, view.seller, seller: true) }
            xml.element("cac:AccountingCustomerParty") { party(xml, view.customer, seller: false) }
            delivery(xml, view)
            unless iban.empty?
              xml.element("cac:PaymentMeans") do
                cbc(xml, "PaymentMeansCode", TRANSFER)
                cbc(xml, "PaymentID", view.structured_reference) unless view.structured_reference.empty?
                xml.element("cac:PayeeFinancialAccount") do
                  cbc(xml, "ID", iban)
                  unless bic.empty?
                    xml.element("cac:FinancialInstitutionBranch") { cbc(xml, "ID", bic) }
                  end
                end
              end
            end
            allowances(xml, view, currency)
            xml.element("cac:TaxTotal") do
              money(xml, "TaxAmount", view.totals.total_vat, currency)
              view.vat_breakdown.each do |group|
                xml.element("cac:TaxSubtotal") do
                  money(xml, "TaxableAmount", group.base, currency)
                  money(xml, "TaxAmount", group.vat, currency)
                  tax_category(xml, "cac:TaxCategory", group.category, group.percent, group.exemption_code,
                    group.exemption_reason)
                end
              end
            end
            totals = view.totals
            xml.element("cac:LegalMonetaryTotal") do
              money(xml, "LineExtensionAmount", totals.lines_total, currency)
              money(xml, "TaxExclusiveAmount", totals.total_net, currency)
              money(xml, "TaxInclusiveAmount", totals.total_gross, currency)
              money(xml, "AllowanceTotalAmount", totals.discount_total, currency) unless totals.discount_total.zero?
              money(xml, "PrepaidAmount", totals.prepaid, currency) unless totals.prepaid.zero?
              money(xml, "PayableAmount", totals.payable, currency)
            end
            view.lines.select(&.priced?).each_with_index do |line, index|
              line_item(xml, line, index + 1, currency, credit)
            end
          end
        end
      end

      private def self.cbc(xml : XML::Builder, name : String, value : String, attributes = {} of String => String) : Nil
        xml.element("cbc:#{name}", attributes) { xml.text value }
      end

      private def self.money(xml : XML::Builder, name : String, value : BigDecimal, currency : String) : Nil
        cbc(xml, name, Formats.amount(value), {"currencyID" => currency})
      end

      private def self.iso(time : Time) : String
        time.to_s("%Y-%m-%d")
      end

      # Partie (BG-4, BG-7) : adresse électronique, nom, adresse, TVA, SIREN.
      private def self.party(xml : XML::Builder, party : Inv::PartyView, seller : Bool) : Nil
        xml.element("cac:Party") do
          if endpoint = endpoint(party)
            cbc(xml, "EndpointID", endpoint[0], {"schemeID" => endpoint[1]})
          end
          unless party.siret.empty?
            xml.element("cac:PartyIdentification") { cbc(xml, "ID", party.siret, {"schemeID" => SCHEME_SIRET}) }
          end
          xml.element("cac:PartyName") { cbc(xml, "Name", party.name) }
          xml.element("cac:PostalAddress") do
            cbc(xml, "StreetName", party.line1) unless party.line1.empty?
            cbc(xml, "AdditionalStreetName", party.line2) unless party.line2.empty?
            cbc(xml, "CityName", party.city) unless party.city.empty?
            cbc(xml, "PostalZone", party.postcode) unless party.postcode.empty?
            xml.element("cac:Country") { cbc(xml, "IdentificationCode", party.country_code) }
          end
          unless party.vat_number.empty?
            xml.element("cac:PartyTaxScheme") do
              cbc(xml, "CompanyID", party.vat_number.gsub(/\s/, ""))
              xml.element("cac:TaxScheme") { cbc(xml, "ID", "VAT") }
            end
          end
          xml.element("cac:PartyLegalEntity") do
            cbc(xml, "RegistrationName", party.name)
            if id = legal_id(party)
              cbc(xml, "CompanyID", id[0], {"schemeID" => id[1]})
            end
          end
          if seller && !party.email.empty?
            xml.element("cac:Contact") { cbc(xml, "ElectronicMail", party.email) }
          end
        end
      end

      # Identifiant légal (BT-30, BT-47) : SIREN en schéma `0002`, numéro
      # d'entreprise belge en `0208`.
      def self.legal_id(party : Inv::PartyView) : {String, String}?
        if party.siren.size == 9
          {party.siren, SCHEME_SIREN}
        elsif party.country_code == "BE" && (digits = party.vat_number.gsub(/[^0-9]/, "")).size == 10
          {digits, SCHEME_BE_NUMBER}
        end
      end

      # Adresse électronique (BT-34, BT-49) : annuaire français (`0225`,
      # `SIREN[_SIRET[_CODEROUTAGE]]`) ou numéro d'entreprise belge (`0208`).
      def self.endpoint(party : Inv::PartyView) : {String, String}?
        if party.siren.size == 9
          {[party.siren, party.siret.presence, party.routing_id.presence].compact.join('_'), SCHEME_FR_ADDR}
        elsif party.country_code == "BE" && (digits = party.vat_number.gsub(/[^0-9]/, "")).size == 10
          {digits, SCHEME_BE_NUMBER}
        end
      end

      private def self.delivery(xml : XML::Builder, view : Inv::DocumentView) : Nil
        address = view.delivery_address
        delivered = view.delivery_date
        return if address.nil? && delivered.nil?
        xml.element("cac:Delivery") do
          cbc(xml, "ActualDeliveryDate", iso(delivered)) if delivered
          if address
            xml.element("cac:DeliveryLocation") do
              xml.element("cac:Address") do
                cbc(xml, "StreetName", address.line1) unless address.line1.empty?
                cbc(xml, "AdditionalStreetName", address.line2) unless address.line2.empty?
                cbc(xml, "CityName", address.city) unless address.city.empty?
                cbc(xml, "PostalZone", address.postcode) unless address.postcode.empty?
                xml.element("cac:Country") { cbc(xml, "IdentificationCode", address.country_code) }
              end
            end
          end
        end
      end

      # Remise globale (BG-20), par catégorie de TVA.
      private def self.allowances(xml : XML::Builder, view : Inv::DocumentView, currency : String) : Nil
        view.vat_breakdown.each do |group|
          next if group.allowance.zero?
          xml.element("cac:AllowanceCharge") do
            cbc(xml, "ChargeIndicator", "false")
            cbc(xml, "AllowanceChargeReasonCode", "95")
            cbc(xml, "AllowanceChargeReason", I18n.with_locale(view.locale) { I18n.t("invoicing.pdf.global_discount") })
            money(xml, "Amount", group.allowance, currency)
            tax_category(xml, "cac:TaxCategory", group.category, group.percent, "", "")
          end
        end
      end

      private def self.tax_category(xml : XML::Builder, name : String, category : String, percent : BigDecimal,
                                    exemption_code : String, exemption_reason : String) : Nil
        xml.element(name) do
          cbc(xml, "ID", category)
          cbc(xml, "Percent", Formats.amount(percent)) unless category == "O"
          cbc(xml, "TaxExemptionReasonCode", exemption_code) unless exemption_code.empty?
          cbc(xml, "TaxExemptionReason", exemption_reason) unless exemption_reason.empty?
          xml.element("cac:TaxScheme") { cbc(xml, "ID", "VAT") }
        end
      end

      private def self.line_item(xml : XML::Builder, line : Inv::LineView, index : Int32, currency : String, credit : Bool) : Nil
        xml.element(credit ? "cac:CreditNoteLine" : "cac:InvoiceLine") do
          cbc(xml, "ID", index.to_s)
          cbc(xml, credit ? "CreditedQuantity" : "InvoicedQuantity", Formats.amount(line.quantity, 4), {"unitCode" => line.unit_code})
          money(xml, "LineExtensionAmount", line.net_amount, currency)
          unless line.discount_amount.zero?
            xml.element("cac:AllowanceCharge") do
              cbc(xml, "ChargeIndicator", "false")
              cbc(xml, "AllowanceChargeReasonCode", "95")
              money(xml, "Amount", line.discount_amount, currency)
              money(xml, "BaseAmount", line.gross_amount, currency)
            end
          end
          xml.element("cac:Item") do
            name = line.description.lines.first? || line.description
            cbc(xml, "Description", line.description) if line.description.includes?('\n')
            cbc(xml, "Name", name)
            xml.element("cac:ClassifiedTaxCategory") do
              cbc(xml, "ID", line.vat_category)
              cbc(xml, "Percent", Formats.amount(line.vat_percent)) unless line.vat_category == "O"
              xml.element("cac:TaxScheme") { cbc(xml, "ID", "VAT") }
            end
          end
          xml.element("cac:Price") { cbc(xml, "PriceAmount", Formats.amount(line.unit_price, 4), {"currencyID" => currency}) }
        end
      end
    end
  end
end
