# SPDX-License-Identifier: AGPL-3.0-or-later

require "xml"
require "json"
require "pdf"

module Einvoicing
  module Formats
    # Partie d'une facture lue.
    record PartyData,
      name : String = "",
      siren : String = "",
      siret : String = "",
      vat_number : String = "",
      country_code : String = "",
      electronic_address : String = "",
      scheme : String = "" do
      def to_h : Hash(String, String)
        {"name" => name, "siren" => siren, "siret" => siret, "vat_number" => vat_number, "country_code" => country_code,
         "electronic_address" => electronic_address, "scheme" => scheme}
      end
    end

    # Ligne du récapitulatif de TVA (BG-23).
    record VatLine,
      category : String,
      percent : BigDecimal,
      base : BigDecimal,
      amount : BigDecimal do
      def to_h : Hash(String, String)
        {"category" => category, "percent" => Formats.plain(percent), "base" => Formats.plain(base),
         "amount" => Formats.plain(amount)}
      end

      def self.from_h(data : Hash(String, JSON::Any)) : self
        text = ->(key : String) { data[key]?.try(&.as_s?) || "" }
        new(text.call("category"), Formats.decimal(text.call("percent")) || BigDecimal.new(0),
          Formats.decimal(text.call("base")) || BigDecimal.new(0), Formats.decimal(text.call("amount")) || BigDecimal.new(0))
      end
    end

    # Ligne de facture (BG-25).
    record LineData,
      description : String,
      quantity : BigDecimal,
      unit_code : String,
      unit_price : BigDecimal?,
      net : BigDecimal,
      vat_category : String,
      vat_percent : BigDecimal? do
      def to_h : Hash(String, String?)
        {"description" => description, "quantity" => Formats.plain(quantity), "unit_code" => unit_code,
         "unit_price" => unit_price.try { |value| Formats.plain(value) }, "net" => Formats.plain(net),
         "vat_category" => vat_category, "vat_percent" => vat_percent.try { |value| Formats.plain(value) }}
      end

      def self.from_h(data : Hash(String, JSON::Any)) : self
        text = ->(key : String) { data[key]?.try(&.as_s?) }
        new(text.call("description") || "", Formats.decimal(text.call("quantity")) || BigDecimal.new(1),
          text.call("unit_code") || "", Formats.decimal(text.call("unit_price")),
          Formats.decimal(text.call("net")) || BigDecimal.new(0), text.call("vat_category") || "",
          Formats.decimal(text.call("vat_percent")))
      end
    end

    # Facture lue (UBL, CII ou Factur-X). `syntax` : `UBL`, `CII`,
    # `Factur-X` ; `profile` : identifiant de spécification (BT-24) ;
    # `xml` : les données structurées (le XML embarqué pour un Factur-X) ;
    # `errors` : ce qui n'a pas pu être lu (la facture est gardée quand même).
    record Parsed,
      syntax : String,
      profile : String,
      number : String,
      type_code : String,
      issue_date : Time?,
      due_date : Time?,
      currency_code : String,
      seller : PartyData,
      buyer : PartyData,
      total_net : BigDecimal?,
      total_vat : BigDecimal?,
      total_gross : BigDecimal?,
      payable : BigDecimal?,
      vat_lines : Array(VatLine),
      lines : Array(LineData),
      notes : Array(String),
      xml : Bytes,
      errors : Array(String) do
      def credit_note? : Bool
        CREDIT_TYPE_CODES.includes?(type_code)
      end
    end

    class ReadError < Exception
    end

    # Lecture des factures reçues (ADR-004 D3) : UBL 2.1 (facture ou avoir),
    # CII (D16B à D22B) et Factur-X (PDF/A-3 dont on extrait le XML
    # embarqué). Successeur de `XML_Reader` de l'application d'origine
    # (`include/XMLDocument/xml_reader.class.php`), qui ne lisait que l'UBL.
    module Reader
      NS_UBL_INVOICE = "urn:oasis:names:specification:ubl:schema:xsd:Invoice-2"
      NS_UBL_CREDIT  = "urn:oasis:names:specification:ubl:schema:xsd:CreditNote-2"
      NS_CBC         = "urn:oasis:names:specification:ubl:schema:xsd:CommonBasicComponents-2"
      NS_CAC         = "urn:oasis:names:specification:ubl:schema:xsd:CommonAggregateComponents-2"
      NS_RSM         = "urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"
      NS_RAM         = "urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"
      NS_UDT         = "urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100"

      # Noms du XML embarqué dans un PDF Factur-X (et ses prédécesseurs).
      EMBEDDED_NAMES = %w[factur-x.xml zugferd-invoice.xml xrechnung.xml order-x.xml]

      # Syntaxe reconnue au contenu : `Factur-X` (PDF), `CII`, `UBL` ; `nil`
      # sinon.
      def self.detect(bytes : Bytes) : String?
        return if bytes.empty?
        return "Factur-X" if bytes.size >= 5 && bytes[0, 5] == "%PDF-".to_slice
        root = xml_root(bytes)
        return if root.nil?
        case {root.name, root.namespace.try(&.href)}
        when {"CrossIndustryInvoice", NS_RSM}                           then "CII"
        when {"Invoice", NS_UBL_INVOICE}, {"CreditNote", NS_UBL_CREDIT} then "UBL"
        end
      end

      # XML embarqué d'un PDF Factur-X ; `nil` s'il n'y en a pas.
      def self.embedded_xml(pdf : Bytes) : Bytes?
        reader = PDF::Reader.new(pdf)
        files = PDF::AttachedFile.list(reader)
        file = files.find { |item| EMBEDDED_NAMES.includes?(item.name.downcase) } ||
               files.find(&.name.downcase.ends_with?(".xml"))
        file.try(&.data)
      rescue ex
        raise ReadError.new("PDF illisible : #{ex.message}")
      end

      # Lit une facture ; lève `ReadError` si le contenu n'est ni UBL, ni
      # CII, ni un PDF Factur-X.
      def self.parse(bytes : Bytes) : Parsed
        case detect(bytes)
        when "Factur-X"
          xml = embedded_xml(bytes) || raise ReadError.new("PDF sans XML Factur-X embarqué")
          parsed = parse(xml)
          parsed.copy_with(syntax: "Factur-X")
        when "CII"
          parse_cii(bytes)
        when "UBL"
          parse_ubl(bytes)
        else
          raise ReadError.new("ni UBL, ni CII, ni Factur-X")
        end
      end

      private def self.xml_root(bytes : Bytes) : XML::Node?
        text = String.new(bytes[0, Math.min(bytes.size, 512)]).lchop("﻿").lstrip
        return unless text.starts_with?('<')
        XML.parse(String.new(bytes)).root
      rescue XML::Error
        nil
      end

      private def self.document(bytes : Bytes) : XML::Node
        XML.parse(String.new(bytes))
      rescue ex : XML::Error
        raise ReadError.new("XML illisible : #{ex.message}")
      end

      # --- CII -----------------------------------------------------------------

      CII_NS = {"rsm" => NS_RSM, "ram" => NS_RAM, "udt" => NS_UDT}

      private def self.parse_cii(bytes : Bytes) : Parsed
        doc = document(bytes)
        text = ->(path : String, node : XML::Node) { node.xpath_node(path, CII_NS).try(&.content.strip) || "" }
        root = doc.root || raise ReadError.new("XML vide")
        errors = [] of String
        settlement = root.xpath_node("//ram:ApplicableHeaderTradeSettlement", CII_NS)
        totals = root.xpath_node("//ram:SpecifiedTradeSettlementHeaderMonetarySummation", CII_NS)
        vat_lines = root.xpath_nodes("//ram:ApplicableHeaderTradeSettlement/ram:ApplicableTradeTax", CII_NS).compact_map do |node|
          base = decimal(text.call("ram:BasisAmount", node))
          amount = decimal(text.call("ram:CalculatedAmount", node))
          next unless base && amount
          VatLine.new(text.call("ram:CategoryCode", node), decimal(text.call("ram:RateApplicablePercent", node)) || BigDecimal.new(0),
            base, amount)
        end
        lines = root.xpath_nodes("//ram:IncludedSupplyChainTradeLineItem", CII_NS).map do |node|
          quantity = node.xpath_node("ram:SpecifiedLineTradeDelivery/ram:BilledQuantity", CII_NS)
          LineData.new(
            description: text.call("ram:SpecifiedTradeProduct/ram:Name", node),
            quantity: decimal(quantity.try(&.content)) || BigDecimal.new(1),
            unit_code: quantity.try(&.[]?("unitCode")) || "",
            unit_price: decimal(text.call("ram:SpecifiedLineTradeAgreement/ram:NetPriceProductTradePrice/ram:ChargeAmount", node)),
            net: decimal(text.call("ram:SpecifiedLineTradeSettlement/ram:SpecifiedTradeSettlementLineMonetarySummation/ram:LineTotalAmount", node)) || BigDecimal.new(0),
            vat_category: text.call("ram:SpecifiedLineTradeSettlement/ram:ApplicableTradeTax/ram:CategoryCode", node),
            vat_percent: decimal(text.call("ram:SpecifiedLineTradeSettlement/ram:ApplicableTradeTax/ram:RateApplicablePercent", node)),
          )
        end
        number = text.call("/rsm:CrossIndustryInvoice/rsm:ExchangedDocument/ram:ID", root)
        errors << "number" if number.empty?
        Parsed.new(
          syntax: "CII",
          profile: text.call("//rsm:ExchangedDocumentContext/ram:GuidelineSpecifiedDocumentContextParameter/ram:ID", root),
          number: number,
          type_code: text.call("/rsm:CrossIndustryInvoice/rsm:ExchangedDocument/ram:TypeCode", root),
          issue_date: date(text.call("/rsm:CrossIndustryInvoice/rsm:ExchangedDocument/ram:IssueDateTime/udt:DateTimeString", root)),
          due_date: date(text.call("//ram:SpecifiedTradePaymentTerms/ram:DueDateDateTime/udt:DateTimeString", root)),
          currency_code: settlement.try { |node| text.call("ram:InvoiceCurrencyCode", node) } || "",
          seller: cii_party(root.xpath_node("//ram:ApplicableHeaderTradeAgreement/ram:SellerTradeParty", CII_NS)),
          buyer: cii_party(root.xpath_node("//ram:ApplicableHeaderTradeAgreement/ram:BuyerTradeParty", CII_NS)),
          total_net: totals.try { |node| decimal(text.call("ram:TaxBasisTotalAmount", node)) },
          total_vat: totals.try { |node| decimal(text.call("ram:TaxTotalAmount", node)) },
          total_gross: totals.try { |node| decimal(text.call("ram:GrandTotalAmount", node)) },
          payable: totals.try { |node| decimal(text.call("ram:DuePayableAmount", node)) },
          vat_lines: vat_lines,
          lines: lines,
          notes: root.xpath_nodes("/rsm:CrossIndustryInvoice/rsm:ExchangedDocument/ram:IncludedNote/ram:Content", CII_NS).map(&.content.strip),
          xml: bytes,
          errors: errors,
        )
      end

      private def self.cii_party(node : XML::Node?) : PartyData
        return PartyData.new if node.nil?
        text = ->(path : String) { node.xpath_node(path, CII_NS).try(&.content.strip) || "" }
        legal = node.xpath_node("ram:SpecifiedLegalOrganization/ram:ID", CII_NS)
        legal_scheme = legal.try(&.[]?("schemeID")) || ""
        uri = node.xpath_node("ram:URIUniversalCommunication/ram:URIID", CII_NS)
        uri_scheme = uri.try(&.[]?("schemeID")) || ""
        vat = node.xpath_node("ram:SpecifiedTaxRegistration/ram:ID[@schemeID='VA']", CII_NS).try(&.content.strip) || ""
        global = node.xpath_nodes("ram:GlobalID", CII_NS)
        siret = global.find { |item| item["schemeID"]? == SCHEME_SIRET }.try(&.content.strip) || ""
        siret = legal.try(&.content.strip) || "" if siret.empty? && legal_scheme == SCHEME_SIRET
        siren = Formats.siren_from(legal.try(&.content) || "", legal_scheme)
        siren = Formats.siren_from(uri.try(&.content) || "", uri_scheme) if siren.empty?
        siren = Formats.siren_from(siret, SCHEME_SIRET) if siren.empty? && !siret.empty?
        siren = Formats.siren_from(vat) if siren.empty?
        PartyData.new(
          name: text.call("ram:Name"), siren: siren, siret: siret, vat_number: vat,
          country_code: text.call("ram:PostalTradeAddress/ram:CountryID"),
          electronic_address: uri.try(&.content.strip) || "", scheme: uri_scheme,
        )
      end

      # --- UBL -----------------------------------------------------------------

      private def self.parse_ubl(bytes : Bytes) : Parsed
        doc = document(bytes)
        root = doc.root || raise ReadError.new("XML vide")
        credit = root.name == "CreditNote"
        ns = {"cbc" => NS_CBC, "cac" => NS_CAC, "ubl" => credit ? NS_UBL_CREDIT : NS_UBL_INVOICE}
        text = ->(path : String, node : XML::Node) { node.xpath_node(path, ns).try(&.content.strip) || "" }
        errors = [] of String
        totals = root.xpath_node("cac:LegalMonetaryTotal", ns)
        tax_total = root.xpath_nodes("cac:TaxTotal", ns).find(&.xpath_node("cac:TaxSubtotal", ns)) ||
                    root.xpath_node("cac:TaxTotal", ns)
        vat_lines = root.xpath_nodes("cac:TaxTotal/cac:TaxSubtotal", ns).compact_map do |node|
          base = decimal(text.call("cbc:TaxableAmount", node))
          amount = decimal(text.call("cbc:TaxAmount", node))
          next unless base && amount
          VatLine.new(text.call("cac:TaxCategory/cbc:ID", node), decimal(text.call("cac:TaxCategory/cbc:Percent", node)) || BigDecimal.new(0),
            base, amount)
        end
        line_name = credit ? "cac:CreditNoteLine" : "cac:InvoiceLine"
        quantity_name = credit ? "cbc:CreditedQuantity" : "cbc:InvoicedQuantity"
        lines = root.xpath_nodes(line_name, ns).map do |node|
          quantity = node.xpath_node(quantity_name, ns)
          description = text.call("cac:Item/cbc:Name", node)
          description = text.call("cac:Item/cbc:Description", node) if description.empty?
          LineData.new(
            description: description,
            quantity: decimal(quantity.try(&.content)) || BigDecimal.new(1),
            unit_code: quantity.try(&.[]?("unitCode")) || "",
            unit_price: decimal(text.call("cac:Price/cbc:PriceAmount", node)),
            net: decimal(text.call("cbc:LineExtensionAmount", node)) || BigDecimal.new(0),
            vat_category: text.call("cac:Item/cac:ClassifiedTaxCategory/cbc:ID", node),
            vat_percent: decimal(text.call("cac:Item/cac:ClassifiedTaxCategory/cbc:Percent", node)),
          )
        end
        number = text.call("cbc:ID", root)
        errors << "number" if number.empty?
        due = text.call("cbc:DueDate", root)
        due = text.call("cac:PaymentMeans/cbc:PaymentDueDate", root) if due.empty?
        type_code = text.call(credit ? "cbc:CreditNoteTypeCode" : "cbc:InvoiceTypeCode", root)
        type_code = credit ? "381" : "380" if type_code.empty?
        Parsed.new(
          syntax: "UBL",
          profile: text.call("cbc:CustomizationID", root),
          number: number,
          type_code: type_code,
          issue_date: date(text.call("cbc:IssueDate", root)),
          due_date: date(due),
          currency_code: text.call("cbc:DocumentCurrencyCode", root),
          seller: ubl_party(root.xpath_node("cac:AccountingSupplierParty/cac:Party", ns), ns),
          buyer: ubl_party(root.xpath_node("cac:AccountingCustomerParty/cac:Party", ns), ns),
          total_net: totals.try { |node| decimal(text.call("cbc:TaxExclusiveAmount", node)) },
          total_vat: tax_total.try { |node| decimal(text.call("cbc:TaxAmount", node)) },
          total_gross: totals.try { |node| decimal(text.call("cbc:TaxInclusiveAmount", node)) },
          payable: totals.try { |node| decimal(text.call("cbc:PayableAmount", node)) },
          vat_lines: vat_lines,
          lines: lines,
          notes: root.xpath_nodes("cbc:Note", ns).map(&.content.strip),
          xml: bytes,
          errors: errors,
        )
      end

      private def self.ubl_party(node : XML::Node?, ns : Hash(String, String)) : PartyData
        return PartyData.new if node.nil?
        text = ->(path : String) { node.xpath_node(path, ns).try(&.content.strip) || "" }
        name = text.call("cac:PartyName/cbc:Name")
        name = text.call("cac:PartyLegalEntity/cbc:RegistrationName") if name.empty?
        endpoint = node.xpath_node("cbc:EndpointID", ns)
        endpoint_scheme = endpoint.try(&.[]?("schemeID")) || ""
        legal = node.xpath_node("cac:PartyLegalEntity/cbc:CompanyID", ns)
        legal_scheme = legal.try(&.[]?("schemeID")) || ""
        vat = text.call("cac:PartyTaxScheme/cbc:CompanyID")
        identifications = node.xpath_nodes("cac:PartyIdentification/cbc:ID", ns)
        siret = identifications.find { |item| item["schemeID"]? == SCHEME_SIRET }.try(&.content.strip) || ""
        siren = Formats.siren_from(legal.try(&.content) || "", legal_scheme)
        siren = Formats.siren_from(endpoint.try(&.content) || "", endpoint_scheme) if siren.empty?
        siren = Formats.siren_from(siret, SCHEME_SIRET) if siren.empty? && !siret.empty?
        siren = Formats.siren_from(vat) if siren.empty?
        PartyData.new(
          name: name, siren: siren, siret: siret, vat_number: vat,
          country_code: text.call("cac:PostalAddress/cac:Country/cbc:IdentificationCode"),
          electronic_address: endpoint.try(&.content.strip) || "", scheme: endpoint_scheme,
        )
      end

      private def self.decimal(text : String?) : BigDecimal?
        Formats.decimal(text)
      end

      private def self.date(text : String?) : Time?
        Formats.date(text)
      end
    end
  end
end
