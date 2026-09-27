# SPDX-License-Identifier: AGPL-3.0-or-later

require "xml"

module Einvoicing
  module Formats
    # Message de cycle de vie CDAR (UN/CEFACT Cross Domain Acknowledgement
    # And Response D22B), par lequel les plateformes échangent les statuts
    # d'une facture (ADR-004 D4 ; flux `CustomerInvoiceLC` et
    # `SupplierInvoiceLC` de l'API Flux XP Z12-013). Structure réduite aux
    # données du statut : facture visée, code (`ProcessConditionCode`),
    # motif, montant encaissé (DECISIONS D-EINV-007).
    module Cdar
      NS_RSM = "urn:un:unece:uncefact:data:standard:CrossDomainAcknowledgementAndResponse:100"
      NS_RAM = "urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"
      NS_UDT = "urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100"
      NS_QDT = "urn:un:unece:uncefact:data:standard:QualifiedDataType:100"
      NS     = {"rsm" => NS_RSM, "ram" => NS_RAM, "udt" => NS_UDT, "qdt" => NS_QDT}

      GUIDELINE = "urn.cpro.gouv.fr:1p0:CDV:invoice"

      # Rôles (UNTDID 3035) : vendeur, acheteur, plateforme.
      ROLES = {"seller" => "SE", "buyer" => "BY", "platform" => "WK"}

      def self.build(event : Connector::LifecycleEvent, id : String) : String
        XML.build(encoding: "UTF-8", indent: "  ") do |xml|
          xml.element("rsm:CrossDomainAcknowledgementAndResponse",
            {"xmlns:rsm" => NS_RSM, "xmlns:ram" => NS_RAM, "xmlns:udt" => NS_UDT, "xmlns:qdt" => NS_QDT}) do
            xml.element("rsm:ExchangedDocumentContext") do
              xml.element("ram:BusinessProcessSpecifiedDocumentContextParameter") { xml.element("ram:ID") { xml.text "REGULATED" } }
              xml.element("ram:GuidelineSpecifiedDocumentContextParameter") { xml.element("ram:ID") { xml.text GUIDELINE } }
            end
            xml.element("rsm:ExchangedDocument") do
              xml.element("ram:ID") { xml.text id }
              timestamp(xml, "ram:IssueDateTime", event.occurred_at)
              party(xml, "ram:SenderTradeParty", event.issuer == "buyer" ? event.buyer : event.seller, ROLES[event.issuer]? || "SE")
              party(xml, "ram:RecipientTradeParty", event.issuer == "buyer" ? event.seller : event.buyer,
                event.issuer == "buyer" ? "SE" : "BY")
            end
            xml.element("rsm:AcknowledgementDocument") do
              xml.element("ram:MultipleReferencesIndicator") { xml.element("udt:Indicator") { xml.text "false" } }
              xml.element("ram:TypeCode") { xml.text "305" }
              timestamp(xml, "ram:IssueDateTime", event.occurred_at)
              xml.element("ram:ReferenceReferencedDocument") do
                xml.element("ram:IssuerAssignedID") { xml.text event.invoice_number }
                xml.element("ram:TypeCode") { xml.text event.type_code }
                if day = event.invoice_date
                  xml.element("ram:FormattedIssueDateTime") do
                    xml.element("qdt:DateTimeString", {"format" => "102"}) { xml.text day.to_s("%Y%m%d") }
                  end
                end
                xml.element("ram:ProcessConditionCode") { xml.text event.code }
                party(xml, "ram:IssuerTradeParty", event.seller, "SE")
                xml.element("ram:SpecifiedDocumentStatus") do
                  xml.element("ram:ReasonCode") { xml.text event.reason_code } unless event.reason_code.empty?
                  xml.element("ram:Reason") { xml.text event.reason } unless event.reason.empty?
                  if amount = event.amount
                    xml.element("ram:SpecifiedDocumentCharacteristic") do
                      xml.element("ram:TypeCode") { xml.text "MEN" }
                      xml.element("ram:ValueAmount", {"currencyID" => event.currency_code}) { xml.text Formats.amount(amount) }
                    end
                  end
                end
              end
            end
          end
        end
      end

      # Statut lu dans un message CDAR : code, facture visée, date, motif,
      # émetteur (`seller`, `buyer`, `platform`), montant.
      record Status,
        code : String,
        invoice_number : String,
        occurred_at : Time,
        issuer : String,
        reason_code : String,
        reason : String,
        amount : BigDecimal?,
        type_code : String = "380",
        invoice_date : Time? = nil,
        seller_siren : String = ""

      def self.parse(bytes : Bytes) : Array(Status)
        doc = XML.parse(String.new(bytes))
        root = doc.root
        return [] of Status if root.nil? || root.name != "CrossDomainAcknowledgementAndResponse"
        text = ->(path : String, node : XML::Node) { node.xpath_node(path, NS).try(&.content.strip) || "" }
        sent = timestamp_of(text.call("/rsm:CrossDomainAcknowledgementAndResponse/rsm:ExchangedDocument/ram:IssueDateTime/udt:DateTimeString", root))
        role = text.call("/rsm:CrossDomainAcknowledgementAndResponse/rsm:ExchangedDocument/ram:SenderTradeParty/ram:RoleCode", root)
        issuer = ROLES.key_for?(role) || "platform"
        root.xpath_nodes("//rsm:AcknowledgementDocument/ram:ReferenceReferencedDocument", NS).compact_map do |node|
          code = text.call("ram:ProcessConditionCode", node)
          next unless code.matches?(/\A\d{3}\z/)
          Status.new(
            code: code, invoice_number: text.call("ram:IssuerAssignedID", node), occurred_at: sent || Time.utc,
            issuer: issuer, reason_code: text.call("ram:SpecifiedDocumentStatus/ram:ReasonCode", node),
            reason: text.call("ram:SpecifiedDocumentStatus/ram:Reason", node),
            amount: Formats.decimal(text.call("ram:SpecifiedDocumentStatus/ram:SpecifiedDocumentCharacteristic/ram:ValueAmount", node)),
            type_code: text.call("ram:TypeCode", node).presence || "380",
            invoice_date: Formats.date(text.call("ram:FormattedIssueDateTime/qdt:DateTimeString", node)),
            seller_siren: text.call("ram:IssuerTradeParty/ram:GlobalID", node),
          )
        end
      rescue XML::Error
        [] of Status
      end

      private def self.timestamp(xml : XML::Builder, name : String, time : Time) : Nil
        xml.element(name) { xml.element("udt:DateTimeString", {"format" => "204"}) { xml.text time.to_utc.to_s("%Y%m%d%H%M%S") } }
      end

      private def self.timestamp_of(text : String) : Time?
        return Time.parse_utc(text, "%Y%m%d%H%M%S") if text.matches?(/\A\d{14}\z/)
        Formats.date(text)
      rescue Time::Format::Error
        nil
      end

      private def self.party(xml : XML::Builder, name : String, party : Connector::Party?, role : String) : Nil
        xml.element(name) do
          if party && !party.siren.empty?
            xml.element("ram:GlobalID", {"schemeID" => SCHEME_SIREN}) { xml.text party.siren }
          end
          xml.element("ram:Name") { xml.text party.name } if party && !party.name.empty?
          xml.element("ram:RoleCode") { xml.text role }
          if party && !party.electronic_address.empty?
            xml.element("ram:URIUniversalCommunication") do
              xml.element("ram:URIID", {"schemeID" => party.scheme.presence || SCHEME_FR_ADDR}) { xml.text party.electronic_address }
            end
          end
        end
      end
    end

    # Lot d'e-reporting des transactions (ADR-004 D8 ; flux `FRR` de l'API
    # Flux, `UnitaryCustomerTransactionReport`). Représentation réduite aux
    # données de chaque transaction (DECISIONS D-EINV-008).
    module EReport
      NS = "urn.cpro.gouv.fr:1p0:ereporting"

      def self.build(batch : Connector::EReportingBatch) : String
        XML.build(encoding: "UTF-8", indent: "  ") do |xml|
          xml.element("Report", {"xmlns" => NS}) do
            xml.element("ReportDocument") do
              xml.element("Id") { xml.text batch.tracking_id }
              xml.element("IssueDateTime") { xml.text Time.utc.to_s("%Y%m%d%H%M%S") }
              xml.element("TypeCode") { xml.text batch.kind }
              xml.element("ReportPeriod") do
                xml.element("StartDate") { xml.text batch.period_start.to_s("%Y%m%d") }
                xml.element("EndDate") { xml.text batch.period_end.to_s("%Y%m%d") }
              end
              xml.element("Declarant") do
                xml.element("Siren") { xml.text batch.declarant.siren }
                xml.element("Name") { xml.text batch.declarant.name }
              end
            end
            batch.entries.each do |entry|
              xml.element("Transaction") do
                xml.element("InvoiceId") { xml.text entry.invoice_number }
                xml.element("IssueDate") { xml.text entry.date.to_s("%Y%m%d") }
                xml.element("TypeCode") { xml.text entry.type_code }
                xml.element("CurrencyCode") { xml.text entry.currency_code }
                xml.element("Category") { xml.text entry.category }
                xml.element("Counterpart") do
                  xml.element("Name") { xml.text entry.counterpart_name } unless entry.counterpart_name.empty?
                  xml.element("CountryId") { xml.text entry.counterpart_country }
                  xml.element("VatId") { xml.text entry.counterpart_vat } unless entry.counterpart_vat.empty?
                end
                xml.element("TaxBasisTotalAmount") { xml.text Formats.amount(entry.net) }
                xml.element("TaxTotalAmount") { xml.text Formats.amount(entry.vat) }
                xml.element("GrandTotalAmount") { xml.text Formats.amount(entry.gross) }
              end
            end
          end
        end
      end
    end
  end
end
