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

    Log = ::Log.for("einvoicing")

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
      route, platform_required, international = route_for(view)
      totals = view.totals
      country = view.customer.country_code.presence || Partiduo::Api::Core.settings(SYSTEM).country_code
      row = Transmission.new(
        invoice_id: view.id, kind: view.kind, number: view.number.to_s, type_code: view.type_code.to_s,
        customer_card_id: view.customer_card_id, customer_name: view.customer.name, customer_country: country,
        issue_date: view.issue_date, currency_code: view.currency_code, total_net: totals.total_net,
        total_vat: totals.total_vat, total_gross: totals.total_gross, channel: view.issue_channel, b2c: view.b2c,
        route: route, platform_required: platform_required, status: initial_status(route),
        tracking_id: "PDUO-#{UUID.random}", channel_final: !view.sent_at.nil?,
      )
      row.save!
      EReporting.queue!(row, view) if international && route == "international"
      row
    end

    private def self.initial_status(route : String) : String
      {"platform" => "pending", "b2c" => "pending", "international" => "ereporting"}[route]? || "off_platform"
    end

    # Voie et signalement d'un document, d'après son canal et son client.
    # Une facture de canal « plateforme » déjà envoyée par un autre moyen
    # (courriel de la Facturation, papier marqué envoyé) sans avoir été
    # déposée n'est plus transmise : elle suit la voie de son client hors
    # plateforme (`sent_elsewhere`).
    def self.route_for(view : Inv::DocumentView, sent_elsewhere : Bool = false) : {String, Bool, Bool}
      settings = Partiduo::Api::Core.settings(SYSTEM)
      country = view.customer.country_code.presence || settings.country_code
      international = country != settings.country_code
      route, platform_required = route_of(view, settings.tax_regime, international, sent_elsewhere)
      {route, platform_required, international}
    end

    # Route d'un document (ADR-004 D8, D9) et signalement « la réforme
    # impose la plateforme » :
    #
    # * canal `platform` : transmis (B2B) ;
    # * dossier français, client particulier (B2C) : transmis pour
    #   e-reporting (note `BAR`), puis « Encaissée » au paiement ;
    # * dossier français, client professionnel étranger : e-reporting des
    #   ventes internationales ;
    # * canal `public_portal` (Chorus Pro) ou client public : hors plateforme, sans
    #   signalement (Chorus Pro, extension `partiduo-choruspro`) ;
    # * sinon hors plateforme ; signalé si le client est un professionnel
    #   français (l'émission par la plateforme est alors obligatoire).
    def self.route_of(view : Inv::DocumentView, regime : String, international : Bool,
                      sent_elsewhere : Bool = false) : {String, Bool}
      return {"platform", false} if view.issue_channel == "platform" && !sent_elsewhere
      # Client public (ADR-004 D9 révisé) : Chorus Pro, pas la plateforme
      # agréée ; ni transmission ni signalement (DECISIONS D-FIN-001).
      return {"off_platform", false} if view.issue_channel == "public_portal" || view.customer.nature == "public"
      if regime == "fr"
        return {"b2c", false} if view.b2c
        return {"international", false} if international
        return {"off_platform", view.customer.professional?}
      end
      {"off_platform", false}
    end

    # Statuts où la voie se recalcule encore : rien n'est déposé ni déclaré.
    REFRESHABLE = %w[pending rejected off_platform ereporting]

    # Relit le canal du document avant de transmettre (D-INV-016 : il reste
    # modifiable jusqu'à l'envoi ; DECISIONS D-EINV-021) et met à jour la
    # voie, le statut, le signalement et la déclaration d'e-reporting. Rend
    # `false` si la ligne n'a pas pu être relue (document introuvable).
    def self.refresh!(row : Transmission) : Bool
      return true if row.channel_final || !REFRESHABLE.includes?(row.status)
      report = Report.filter(transmission_id: row.id).first
      if report && report.state.in?("sent", "not_applicable")
        row.channel_final = true
        row.save!
        return true
      end
      view = Inv.document(SYSTEM, row.invoice_id!.to_i64)
      # Envoyée sans dépôt : le canal est figé et ce n'était pas la plateforme
      # (le dépôt pose lui-même l'envoi).
      sent_elsewhere = !view.sent_at.nil? && row.platform_ref.nil?
      route, platform_required, international = route_for(view, sent_elsewhere)
      row.channel = view.issue_channel
      row.b2c = view.b2c
      row.platform_required = platform_required
      if route != row.route
        row.route = route
        row.status = row.status == "rejected" && route.in?("platform", "b2c") ? "rejected" : initial_status(route)
        row.error = "" unless row.status == "rejected"
        report.try(&.delete) if route != "international"
      end
      row.channel_final = !view.sent_at.nil?
      row.save!
      EReporting.queue!(row, view) if route == "international" && international && report.nil?
      true
    rescue Partiduo::Api::NotFound
      false
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
                                  {"#{view.number}.xml", "application/xml", ubl(view, peppol: connector.is_a?(Connectors::PeppolBe)).to_slice}
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
    # d'erreur enregistré (`ErrorText`, la facture reste à transmettre).
    # La ligne est verrouillée et son statut revérifié avant le dépôt : une
    # facture déjà déposée par une autre opération ne l'est pas deux fois
    # (DECISIONS D-EINV-022). Une erreur du contrat ou de la base sur cette
    # facture est notée sur la ligne ; la synchronisation continue.
    def self.transmit!(row : Transmission, connector : Connector, adapter : String, by : Int64?,
                       retry_rejected : Bool = false) : String?
      error = nil
      Partiduo::Api::Transaction.run do
        locked = Transmission.all.lock.filter(id: row.id).first
        ready = locked && (locked.status == "pending" || (retry_rejected && locked.status == "rejected"))
        next Partiduo::Api::Result(Nil).success(nil) unless locked && ready && locked.route.in?("platform", "b2c")
        error = submit!(locked, connector, adapter, by)
        Partiduo::Api::Result(Nil).success(nil)
      end
      reload(row)
      error
    rescue ex
      Log.error(exception: ex) { "facture #{row.number} non transmise" }
      text = ex.is_a?(ConnectorError) ? ex.text : ErrorText.encode("einvoicing.errors.transmission.internal",
        {"detail" => ex.message.to_s})
      Transmission.filter(id: row.id).update(attempts: row.attempts!.to_i32 + 1, error: text, updated_at: Time.utc)
      reload(row)
      text
    end

    private def self.reload(row : Transmission) : Nil
      fresh = Transmission.filter(id: row.id).first
      return if fresh.nil?
      row.status = fresh.status
      row.route = fresh.route
      row.platform_ref = fresh.platform_ref
      row.attempts = fresh.attempts
      row.error = fresh.error
      row.syntax = fresh.syntax
      row.profile = fresh.profile
      row.adapter = fresh.adapter
      row.submitted_at = fresh.submitted_at
      row.last_code = fresh.last_code
      row.channel_final = fresh.channel_final
    end

    private def self.submit!(row : Transmission, connector : Connector, adapter : String, by : Int64?) : String?
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
      row.channel_final = submission.status != "error"
      row.save!
      case submission.status
      when "ok"
        Lifecycle.record!(row, Connector::LifecycleEvent.new(code: "200", occurred_at: Time.utc, issuer: "platform"))
      when "error"
        Lifecycle.record!(row, Connector::LifecycleEvent.new(code: "213", occurred_at: Time.utc, issuer: "platform",
          reason_code: submission.reason_code, reason: submission.reason))
      end
      # Dépôt réussi : l'événement `invoice.platform_deposited` est publié ;
      # la Facturation, abonnée, marque la facture envoyée (canal figé) et
      # en envoie la copie PDF si elle est prévue (ADR-004 D9 révisé,
      # D-CPY-001 du cœur) : aucun appel direct entre modules. Pas après un
      # rejet (213) : la facture n'est pas remise et son canal doit rester
      # modifiable.
      notify_deposit(row, adapter, by) if row.route == "platform" && submission.status != "error"
      nil
    rescue ex : ConnectorError | Formats::Cii::Error
      text = ex.is_a?(ConnectorError) ? ex.text : ErrorText.encode("einvoicing.errors.transmission.format",
        {"detail" => ex.message.to_s})
      row.attempts = row.attempts!.to_i32 + 1
      row.error = text
      row.save!
      text
    end

    # Publie `invoice.platform_deposited` dans un point de sauvegarde : le
    # dépôt est déjà accepté par la plateforme, un abonné qui lève (document
    # introuvable, délai de verrou…) ne doit pas l'annuler, sans quoi la
    # synchronisation suivante redéposerait la facture (second original, CGI
    # art. 283-3). Seules les écritures des abonnés sont annulées ; l'échec
    # est journalisé et noté sur la ligne, qui reste « submitted »
    # (DECISIONS D-CPY-007 du cœur).
    private def self.notify_deposit(row : Transmission, adapter : String, by : Int64?) : Nil
      Partiduo::Api::Transaction.run do
        Partiduo::Events.publish("invoice.platform_deposited",
          {"invoice_id" => row.invoice_id!.to_i64.to_s, "platform_ref" => row.platform_ref.to_s,
           "connector" => adapter}, by)
        Partiduo::Api::Result(Nil).success(nil)
      end
    rescue ex
      Log.error(exception: ex) { "facture #{row.number} déposée ; avis de dépôt non traité" }
      row.error = ErrorText.encode("einvoicing.errors.transmission.deposit_notice", {"detail" => ex.message.to_s})
      row.save!
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
        attempts: row.attempts!.to_i32, error: ErrorText.translate(row.error || ""), created_at: row.created_at!,
      )
    end
  end
end
