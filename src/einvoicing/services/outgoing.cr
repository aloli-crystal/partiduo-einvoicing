# SPDX-License-Identifier: AGPL-3.0-or-later

require "digest/sha256"

module Einvoicing
  # Factures émises (ADR-004 D3, D8, D9) : relevé à l'émission, route
  # (plateforme, B2C, international, hors plateforme), transmission du
  # PDF/A-3 Factur-X produit par le module Facturation, fichiers produits à
  # la demande. Le module Facturation n'est lu que par
  # `Partiduo::Api::Invoicing` (ADR-006 D3, ADR-005 D3). Interne.
  module Outgoing
    alias Inv = Partiduo::Api::Invoicing
    alias FieldError = Partiduo::Api::FieldError

    SYSTEM = Partiduo::Api::Actor.system

    # Abonné de `invoice.issued` et `credit_note.issued` : la facture est
    # relevée avec sa route. Idempotent (une facture n'est relevée qu'une
    # fois). Rien n'est bloqué (ADR-004 D9).
    def self.issued(event : Partiduo::Events::Event) : Nil
      id = (event["credit_note_id"]? || event["invoice_id"]).to_i64
      return if Transmission.filter(invoice_id: id).exists?
      return unless Partiduo::Modules.active?("INVOICING")
      view = Inv.document(SYSTEM, id)
      return unless view.fiscal? && view.number
      record!(view)
    end

    # Relève un document fiscal émis.
    def self.record!(view : Inv::DocumentView) : Transmission
      settings = Partiduo::Api::Core.settings(SYSTEM)
      regime = settings.tax_regime
      country = view.customer.country_code.presence || settings.country_code
      international = country != settings.country_code
      route, platform_required = route_of(view, regime, international)
      totals = view.totals
      row = Transmission.new(
        invoice_id: view.id, kind: view.kind, number: view.number.to_s, type_code: view.type_code.to_s,
        customer_card_id: view.customer_card_id, customer_name: view.customer.name, customer_country: country,
        issue_date: view.issue_date, currency_code: view.currency_code, total_net: totals.total_net,
        total_vat: totals.total_vat, total_gross: totals.total_gross, channel: view.issue_channel, b2c: view.b2c,
        route: route, platform_required: platform_required,
        status: {"platform" => "pending", "b2c" => "pending", "international" => "ereporting"}[route]? || "off_platform",
        tracking_id: "PDUO-#{UUID.random}",
      )
      row.save!
      EReporting.queue!(row, view) if route == "international"
      row
    end

    # Route d'un document (ADR-004 D8, D9) et signalement « la réforme
    # impose la plateforme » :
    #
    # * canal `platform` : transmis (B2B) ;
    # * dossier français, client particulier (B2C) : transmis pour
    #   e-reporting (note `BAR`), puis « Encaissée » au paiement ;
    # * dossier français, client professionnel étranger : e-reporting des
    #   ventes internationales ;
    # * sinon hors plateforme ; signalé si le client est un professionnel
    #   français (l'émission par la plateforme est alors obligatoire).
    def self.route_of(view : Inv::DocumentView, regime : String, international : Bool) : {String, Bool}
      return {"platform", false} if view.issue_channel == "platform"
      if regime == "fr"
        return {"b2c", false} if view.b2c
        return {"international", false} if international
        return {"off_platform", view.customer.professional?}
      end
      {"off_platform", false}
    end

    # Facture à transmettre, au format que préfère l'adaptateur :
    # PDF/A-3 Factur-X du module Facturation, CII (note `BAR` pour le B2C,
    # toujours en CII), ou UBL PEPPOL pour le point d'accès belge.
    def self.outgoing_invoice(row : Transmission, connector : Connector) : Connector::OutgoingInvoice
      view = Inv.document(SYSTEM, row.invoice_id!.to_i64)
      b2c = row.route == "b2c"
      syntax = b2c ? "CII" : connector.preferred_syntax
      filename, type, content = case syntax
                                when "Factur-X"
                                  file = Inv.document_pdf(SYSTEM, view.id)
                                  {file.filename, "application/pdf", file.content}
                                when "UBL"
                                  {"#{view.number}.xml", "application/xml", ubl(view, peppol: connector.is_a?(Connectors::NoalyssPeppol)).to_slice}
                                else
                                  {"#{view.number}.xml", "application/xml", cii(view, Formats::EN16931, b2c).to_slice}
                                end
      Connector::OutgoingInvoice.new(
        invoice_id: view.id, number: view.number.to_s, type_code: view.type_code.to_s, syntax: syntax,
        profile: "EN16931", filename: filename, content_type: type, content: content,
        processing_rule: b2c ? "B2C" : "B2B", seller: party(view.seller), buyer: party(view.customer),
        tracking_id: row.tracking_id.to_s, sha256: Digest::SHA256.hexdigest(content),
      )
    end

    # Transmet une facture ; `nil` en cas de succès, sinon le message
    # d'erreur (la facture reste à transmettre).
    def self.transmit!(row : Transmission, connector : Connector, adapter : String, by : Int64?) : String?
      invoice = outgoing_invoice(row, connector)
      submission = connector.submit(invoice)
      row.platform_ref = submission.platform_ref
      row.syntax = invoice.syntax
      row.profile = invoice.profile
      row.adapter = adapter
      row.submitted_at = Time.utc
      row.submitted_by_id = by
      row.attempts = row.attempts!.to_i32 + 1
      row.error = ""
      row.status = "submitted"
      row.save!
      case submission.status
      when "ok"
        Lifecycle.record!(row, Connector::LifecycleEvent.new(code: "200", occurred_at: Time.utc, issuer: "platform"))
      when "error"
        Lifecycle.record!(row, Connector::LifecycleEvent.new(code: "213", occurred_at: Time.utc, issuer: "platform",
          reason_code: submission.reason_code, reason: submission.reason))
      end
      # Remise par la plateforme : la facture passe « envoyée » dans le
      # module Facturation (canal figé).
      Inv.mark_sent(SYSTEM, row.invoice_id!.to_i64) if row.route == "platform"
      nil
    rescue ex : ConnectorError | Formats::Cii::Error
      row.attempts = row.attempts!.to_i32 + 1
      row.error = ex.message.to_s
      row.save!
      ex.message.to_s
    end

    # Fichier d'une facture émise, produit à la demande (ADR-004 D3).
    def self.file(view : Inv::DocumentView, format : String) : Api::FileView
      case format
      when "facturx"
        pdf = Inv.document_pdf(SYSTEM, view.id)
        Api::FileView.new(pdf.filename, "application/pdf", pdf.content)
      when "cii"
        Api::FileView.new("#{view.number}-cii.xml", "application/xml", cii(view, Formats::EN16931).to_slice)
      when "extended-ctc-fr"
        Api::FileView.new("#{view.number}-extended-ctc-fr.xml", "application/xml",
          cii(view, Formats::EXTENDED_CTC_FR).to_slice)
      when "ubl"
        Api::FileView.new("#{view.number}-ubl.xml", "application/xml", ubl(view).to_slice)
      when "peppol"
        Api::FileView.new("#{view.number}-peppol.xml", "application/xml", ubl(view, peppol: true).to_slice)
      else
        raise Partiduo::Api::NotFound.new("einvoicing_format", view.id)
      end
    end

    def self.cii(view : Inv::DocumentView, profile : String, b2c : Bool = false) : String
      Formats::Cii.variant(String.new(Inv.facturx_xml(SYSTEM, view.id).content), profile, b2c)
    end

    def self.ubl(view : Inv::DocumentView, peppol : Bool = false) : String
      settings = Inv.settings(SYSTEM)
      Formats::Ubl.build(view, settings.iban, settings.bic, peppol)
    end

    def self.party(party : Inv::PartyView) : Connector::Party
      endpoint = Formats::Ubl.endpoint(party)
      Connector::Party.new(name: party.name, siren: party.siren, siret: party.siret, vat_number: party.vat_number,
        country_code: party.country_code, electronic_address: endpoint.try(&.[0]) || "", scheme: endpoint.try(&.[1]) || "")
    end

    def self.view(row : Transmission) : Api::TransmissionView
      Api::TransmissionView.new(
        id: row.id!.to_i64, invoice_id: row.invoice_id!.to_i64, kind: row.kind!, number: row.number!,
        type_code: row.type_code!, customer_card_id: row.customer_card_id.try(&.to_i64),
        customer_name: row.customer_name || "", customer_country: row.customer_country || "",
        issue_date: row.issue_date, currency_code: row.currency_code || "EUR", total_net: row.total_net!,
        total_vat: row.total_vat!, total_gross: row.total_gross!, channel: row.channel || "", b2c: row.b2c!,
        route: row.route!, platform_required: row.platform_required!, status: row.status!,
        last_code: row.last_code || "", adapter: row.adapter || "", syntax: row.syntax || "", profile: row.profile || "",
        platform_ref: row.platform_ref, tracking_id: row.tracking_id!, submitted_at: row.submitted_at,
        attempts: row.attempts!.to_i32, error: row.error || "", created_at: row.created_at!,
      )
    end
  end
end
