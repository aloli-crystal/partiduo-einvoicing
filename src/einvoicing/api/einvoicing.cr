# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  # Contrat public de l'extension EINV, sur le modèle de `Partiduo::Api`
  # (DECISIONS C2) : acteur en premier argument, contrôle d'accès en première
  # ligne, objets de vue immuables, erreurs par champ. L'interface de
  # l'extension (`ui/bulma/`) ne voit que ce module et `Partiduo::Api`.
  #
  # Référence : `doc/api/einvoicing.adoc`.
  module Api
    alias Actor = Partiduo::Api::Actor
    alias Guard = Partiduo::Api::Guard
    alias Result = Partiduo::Api::Result
    alias FieldError = Partiduo::Api::FieldError
    alias Transaction = Partiduo::Api::Transaction
    alias Acc = Partiduo::Api::Accounting
    alias Inv = Partiduo::Api::Invoicing

    MODULE_CODE = Einvoicing::CODE
    READ        = "einvoicing.invoice.read"
    SEND        = "einvoicing.invoice.send"
    RECEIVE     = "einvoicing.invoice.receive"
    CONFIGURE   = "einvoicing.settings.manage"

    MAX_LIMIT = 500

    # --- Raccordement ----------------------------------------------------------

    # Adaptateurs compilés dans la distribution ; `available` selon le
    # régime du dossier (NOALYSS-PEPPOL : dossiers belges seulement).
    def self.adapters(actor : Actor) : Array(AdapterView)
      Guard.authorize!(actor, CONFIGURE, module_code: MODULE_CODE)
      regime = regime(actor)
      Connections.adapters.map do |adapter|
        existing = Connection.filter(adapter: adapter.code).first
        AdapterView.new(adapter.code, adapter.label_key, adapter.regimes.includes?(regime), fields(adapter, existing))
      end
    end

    # Raccordement actif, `nil` s'il n'y en a pas.
    def self.connection(actor : Actor) : ConnectionView?
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      Connections.active.try { |row| connection_view(row) }
    end

    # Enregistre les paramètres d'un adaptateur et en fait l'adaptateur
    # actif du dossier (un seul à la fois, ADR-004 D2). Secrets chiffrés ;
    # un secret laissé vide garde la valeur enregistrée. Changer d'adaptateur
    # repart des curseurs de ce nouvel adaptateur.
    def self.configure(actor : Actor, input : ConnectionInput) : Result(ConnectionView)
      Guard.authorize!(actor, CONFIGURE, module_code: MODULE_CODE)
      adapter = Connections.adapter?(input.adapter)
      Transaction.run do
        existing = Connection.all.lock.filter(adapter: input.adapter).first
        errors = [] of FieldError
        Connections.check(adapter, input.adapter, input.values, existing, regime(actor), errors)
        next Result(ConnectionView).failure(errors) unless errors.empty? && adapter
        secrets = existing ? Secrets.decrypt_json(existing.secrets.to_s) : {} of String => String
        values = {} of String => String
        adapter.fields.each do |field|
          value = input.values[field.name]?.to_s.strip
          if field.secret
            secrets[field.name] = value unless value.empty?
          else
            values[field.name] = value
          end
        end
        Connection.filter(active: true).exclude(adapter: input.adapter).update(active: false, updated_at: Time.utc)
        row = existing || Connection.new(adapter: input.adapter)
        row.settings = JSON.parse(values.to_json)
        row.secrets = Secrets.encrypt_json(secrets)
        row.active = true
        row.updated_by_id = actor.user_id
        # Nouveaux identifiants : les jetons en cours ne valent plus.
        row.access_token = ""
        row.access_token_expires_at = nil
        row.save!
        Result(ConnectionView).success(connection_view(row))
      end
    end

    # Débranche la plateforme : plus rien n'est transmis ni reçu ; les
    # paramètres restent enregistrés.
    def self.disconnect(actor : Actor) : Result(Nil)
      Guard.authorize!(actor, CONFIGURE, module_code: MODULE_CODE)
      Transaction.run do
        Connection.filter(active: true).update(active: false, access_token: "", access_token_expires_at: nil,
          updated_at: Time.utc)
        Result(Nil).success(nil)
      end
    end

    # Essai du raccordement actif (authentification comprise).
    def self.check_connection(actor : Actor) : Result(Nil)
      Guard.authorize!(actor, CONFIGURE, module_code: MODULE_CODE)
      Connections.connector.check
      Result(Nil).success(nil)
    rescue Connections::NotConfigured
      Result(Nil).failure(FieldError.base("einvoicing.errors.connection.missing"))
    rescue ex : ConnectorError
      Result(Nil).failure(FieldError.base("einvoicing.errors.connection.failed", {"detail" => ex.localized}))
    end

    # --- Synchronisation -------------------------------------------------------

    # Transmet les factures en attente, lit factures reçues et statuts par
    # curseur, émet les statuts et l'e-reporting (ADR-004 D2). Permission
    # `einvoicing.invoice.send` ou `einvoicing.invoice.receive`.
    def self.synchronize(actor : Actor) : Result(SyncView)
      Guard.authorize!(actor, nil, module_code: MODULE_CODE)
      unless actor.can?(SEND) || actor.can?(RECEIVE)
        raise Partiduo::Api::Forbidden.new(SEND)
      end
      Result(SyncView).success(Sync.run(actor.user_id))
    rescue Connections::NotConfigured
      Result(SyncView).failure(FieldError.base("einvoicing.errors.connection.missing"))
    rescue Sync::Busy
      Result(SyncView).failure(FieldError.base("einvoicing.errors.sync.running"))
    end

    # --- Factures émises -------------------------------------------------------

    # Les factures émises (client, montants, numéros) se lisent aussi avec
    # `invoicing.invoice.read` (DECISIONS D-EINV-023).
    INVOICE_READ = "invoicing.invoice.read"

    private def self.authorize_outgoing!(actor : Actor) : Nil
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      raise Partiduo::Api::Forbidden.new(INVOICE_READ) unless actor.system || actor.can?(INVOICE_READ)
    end

    def self.transmissions(actor : Actor, query : TransmissionQuery = TransmissionQuery.new) : Array(TransmissionView)
      authorize_outgoing!(actor)
      rows = Transmission.all
      query.status.try { |status| rows = rows.filter(status: status) }
      if text = query.search.try(&.strip).presence
        rows = rows.filter { q(number__icontains: text) | q(customer_name__icontains: text) }
      end
      offset = Math.max(query.offset, 0)
      rows.order("-issue_date", "-id")[offset...(offset + query.limit.clamp(1, MAX_LIMIT))].to_a.map { |row| Outgoing.view(row) }
    end

    def self.transmission(actor : Actor, id : Int64) : TransmissionView
      authorize_outgoing!(actor)
      Outgoing.view(Transmission.filter(id: id).first || raise Partiduo::Api::NotFound.new("transmission", id))
    end

    # Suivi d'un document de la Facturation, `nil` s'il n'est pas relevé.
    def self.transmission_for_invoice(actor : Actor, invoice_id : Int64) : TransmissionView?
      authorize_outgoing!(actor)
      Transmission.filter(invoice_id: invoice_id).first.try { |row| Outgoing.view(row) }
    end

    def self.transmission_events(actor : Actor, id : Int64) : Array(EventView)
      authorize_outgoing!(actor)
      Event.filter(transmission_id: id).order(:occurred_at, :id).to_a.map { |event| Lifecycle.view(event) }
    end

    # Relève un document fiscal émis que l'abonnement n'a pas vu (émis avant
    # l'activation de l'extension) : idempotent. Exige la Facturation.
    def self.track(actor : Actor, invoice_id : Int64) : Result(TransmissionView)
      Guard.authorize!(actor, SEND, module_code: MODULE_CODE)
      Partiduo::Modules.require_active!("INVOICING")
      Transaction.run do
        if existing = Transmission.filter(invoice_id: invoice_id).first
          next Result(TransmissionView).success(Outgoing.view(existing))
        end
        view = Inv.document(Actor.system, invoice_id)
        unless view.fiscal? && view.number
          next Result(TransmissionView).failure(FieldError.new("invoice_id", "einvoicing.errors.transmission.not_issued"))
        end
        Result(TransmissionView).success(Outgoing.view(Outgoing.record!(view)))
      end
    end

    # Transmet (ou retransmet après un rejet) une facture à la plateforme
    # active. Exige la Facturation (`ModuleDisabled` sinon).
    def self.transmit(actor : Actor, id : Int64) : Result(TransmissionView)
      Guard.authorize!(actor, SEND, module_code: MODULE_CODE)
      Partiduo::Modules.require_active!("INVOICING")
      Transmission.filter(id: id).first || raise Partiduo::Api::NotFound.new("transmission", id)
      connection = Connections.active
      return Result(TransmissionView).failure(FieldError.base("einvoicing.errors.connection.missing")) if connection.nil?
      # Même verrou que la synchronisation, puis canal relu (D-EINV-021,
      # D-EINV-022) : la ligne est relue sous le verrou.
      Sync.exclusive do
        row = Transmission.filter(id: id).first || raise Partiduo::Api::NotFound.new("transmission", id)
        Outgoing.refresh!(row)
        unless Outgoing.view(row).transmittable?
          next Result(TransmissionView).failure(FieldError.base("einvoicing.errors.transmission.not_transmittable",
            {"status" => row.status.to_s}))
        end
        error = Outgoing.transmit!(row, Connections.connector(connection), connection.adapter.to_s, actor.user_id,
          retry_rejected: true)
        if error
          Result(TransmissionView).failure(FieldError.base("einvoicing.errors.transmission.failed",
            {"detail" => ErrorText.translate(error)}))
        else
          Result(TransmissionView).success(Outgoing.view(row))
        end
      end
    rescue Sync::Busy
      Result(TransmissionView).failure(FieldError.base("einvoicing.errors.sync.running"))
    end

    # Fichier d'une facture émise, produit à la demande (ADR-004 D3) :
    # `facturx` (PDF/A-3 du module Facturation), `cii`, `extended-ctc-fr`,
    # `ubl`, `peppol`. Lecture de la Facturation exigée.
    def self.export(actor : Actor, invoice_id : Int64, format : String) : FileView
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      view = Inv.document(actor, invoice_id)
      raise Partiduo::Api::NotFound.new("invoice", invoice_id) unless view.fiscal? && view.number
      Outgoing.file(view, format)
    end

    # --- Factures reçues -------------------------------------------------------

    def self.receptions(actor : Actor, query : ReceptionQuery = ReceptionQuery.new) : Array(ReceptionView)
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      rows = Reception.all
      query.status.try { |status| rows = rows.filter(status: status) }
      if text = query.search.try(&.strip).presence
        rows = rows.filter { q(number__icontains: text) | q(supplier_name__icontains: text) | q(supplier_siren__startswith: text) }
      end
      offset = Math.max(query.offset, 0)
      rows.order("-received_at", "-id")[offset...(offset + query.limit.clamp(1, MAX_LIMIT))].to_a.map { |row| Incoming.view(row) }
    end

    def self.reception(actor : Actor, id : Int64) : ReceptionView
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      Incoming.view(Incoming.find!(id))
    end

    def self.reception_events(actor : Actor, id : Int64) : Array(EventView)
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      Event.filter(reception_id: id).order(:occurred_at, :id).to_a.map { |event| Lifecycle.view(event) }
    end

    # Dépose à la main une facture électronique reçue hors synchronisation
    # (UBL, CII ou Factur-X), comme si la plateforme l'avait livrée ;
    # idempotent sur le contenu. Permissions `einvoicing.invoice.receive`
    # et celles de DOCUMENT pour déposer.
    def self.import(actor : Actor, filename : String, content : Bytes) : Result(ReceptionView)
      Guard.authorize!(actor, RECEIVE, module_code: MODULE_CODE)
      Guard.authorize!(actor, Document::Api::WRITE, module_code: Document::CODE)
      Guard.authorize!(actor, Document::Api::ATTACHMENT_WRITE)
      unless Formats::Reader.detect(content)
        return Result(ReceptionView).failure(FieldError.new("content", "einvoicing.errors.reception.unreadable"))
      end
      Transaction.run do
        incoming = Connector::IncomingInvoice.new(platform_ref: "import:#{Digest::SHA256.hexdigest(content)}",
          filename: filename.presence || "facture.xml", content: content)
        Result(ReceptionView).success(Incoming.view(Incoming.store!(incoming, "import")))
      end
    end

    # Accepte une facture reçue (décision locale, rien n'est émis).
    def self.accept(actor : Actor, id : Int64) : Result(ReceptionView)
      Guard.authorize!(actor, RECEIVE, module_code: MODULE_CODE)
      Transaction.run do
        row = Incoming.lock!(id)
        next status_error(row, "not_received") unless row.status == "received"
        Result(ReceptionView).success(Incoming.view(Incoming.decide!(row, "accepted", actor.user_id)))
      end
    end

    # Refuse une facture reçue : statut « Refusée » (210) émis vers la
    # plateforme avec son motif (ADR-004 D4) ; le justificatif est écarté
    # de la boîte à traiter.
    def self.refuse(actor : Actor, id : Int64, input : RefuseInput) : Result(ReceptionView)
      Guard.authorize!(actor, RECEIVE, module_code: MODULE_CODE)
      errors = [] of FieldError
      unless REFUSAL_REASONS.includes?(input.reason_code)
        errors << FieldError.new("reason_code", "einvoicing.errors.reception.reason_code", {"value" => input.reason_code})
      end
      reason = input.reason.strip
      errors << FieldError.new("reason", "einvoicing.errors.reception.reason_blank") if input.reason_code == "AUTRE" && reason.empty?
      errors << FieldError.new("reason", "einvoicing.errors.reception.reason_too_long", {"max" => "1000"}) if reason.size > 1000
      return Result(ReceptionView).failure(errors) unless errors.empty?
      event_id = nil
      result = Transaction.run do
        row = Incoming.lock!(id)
        next status_error(row, "already_decided") unless row.status.in?("received", "accepted")
        Incoming.decide!(row, "refused", actor.user_id)
        event = Event.create!(reception_id: row.id, code: "210", occurred_at: Time.utc, issuer: "buyer",
          reason_code: input.reason_code, reason: reason, state: "to_send", created_by_id: actor.user_id,
          created_at: Time.utc)
        event_id = event.id!.to_i64
        row.receipt_id.try do |receipt_id|
          receipt = Document::Api.receipt(Actor.system, receipt_id.to_i64)
          Document::Api.discard(Actor.system, receipt.id) if receipt.to_process?
        end
        Result(ReceptionView).success(Incoming.view(row))
      end
      event_id.try { |value| Lifecycle.send_later(value) } if result.success?
      result
    end

    # Écriture d'achat proposée pour une facture reçue (ADR-004 D3) ;
    # erreurs si la Comptabilité ne peut pas la recevoir (pas de journal
    # d'achats, fournisseur sans fiche, facture sans numéro).
    def self.purchase_prefill(actor : Actor, id : Int64) : Result(Acc::ReceivedInvoiceInput)
      Guard.authorize!(actor, RECEIVE, module_code: MODULE_CODE)
      Guard.authorize!(actor, "accounting.entry.post", module_code: "ACCOUNTING")
      row = Incoming.find!(id)
      input, errors = Incoming.prefill(actor, row, Incoming.view(row))
      input ? Result(Acc::ReceivedInvoiceInput).success(input) : Result(Acc::ReceivedInvoiceInput).failure(errors)
    end

    # Pré-comptabilise une facture reçue dans le journal d'achats par le
    # service d'écriture du cœur (`post_received_invoice`, origine
    # plateforme, pièce jointe = fichier reçu) ; refusée si elle fait
    # doublon avec une facture déjà enregistrée, reçue par la plateforme ou
    # hors plateforme (ADR-004 D9). `input` à `nil` : l'écriture proposée.
    # Exige la Comptabilité.
    def self.post(actor : Actor, id : Int64,
                  input : Acc::ReceivedInvoiceInput? = nil) : Result(Acc::ReceivedInvoiceView)
      Guard.authorize!(actor, RECEIVE, module_code: MODULE_CODE)
      Guard.authorize!(actor, "accounting.entry.post", module_code: "ACCOUNTING")
      Transaction.run do
        row = Incoming.lock!(id)
        unless row.status.in?("received", "accepted")
          next Result(Acc::ReceivedInvoiceView).failure(FieldError.base("einvoicing.errors.reception.status.already_decided",
            {"status" => row.status.to_s}))
        end
        proposed, errors = Incoming.prefill(actor, row, Incoming.view(row))
        chosen = input || proposed
        next Result(Acc::ReceivedInvoiceView).failure(errors) if chosen.nil?
        # La pièce jointe, la source et l'origine restent celles de la
        # facture reçue, quoi qu'ait saisi l'écran — même quand l'écriture
        # proposée n'a pu être construite (fournisseur choisi à l'écran).
        receipt = row.receipt_id.try { |receipt_id| Document::Api.receipt(Actor.system, receipt_id.to_i64) }
        if receipt.nil?
          next Result(Acc::ReceivedInvoiceView).failure(FieldError.base("einvoicing.errors.reception.no_file"))
        end
        platform_ref = row.platform_ref.to_s
        chosen = chosen.copy_with(origin: Acc::ReceptionOrigin::Platform,
          platform_reference: platform_ref.size > 255 ? platform_ref[0, 255] : platform_ref,
          document: chosen.document.copy_with(attachment_id: receipt.original_attachment_id,
            source: "#{Document::Api::SOURCE_PREFIX}#{receipt.id}"))
        result = Acc.post_received_invoice(actor, chosen)
        next result if result.failure?
        posted = result.value!
        row.entry_id = posted.entry_id
        row.received_invoice_id = posted.id
        Incoming.decide!(row, "posted", actor.user_id)
        result
      end
    end

    # Contrôle de l'écriture d'achat (totaux et doublon), sans écrire.
    def self.check_post(actor : Actor, id : Int64) : Result(Acc::EntryDraftView)
      prefill = purchase_prefill(actor, id)
      return Result(Acc::EntryDraftView).failure(prefill.errors) if prefill.failure?
      Acc.check_received_invoice(actor, prefill.value!)
    end

    # Doublons possibles (ADR-004 D9) : autres factures reçues par la
    # plateforme, et, Comptabilité active et saisie permise, factures
    # d'achat déjà enregistrées du même fournisseur, même numéro, même
    # montant — y compris celles reçues hors plateforme.
    def self.duplicates(actor : Actor, id : Int64) : DuplicatesView
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      row = Incoming.find!(id)
      view = Incoming.view(row)
      same = Incoming.same_invoices(row).map { |other| Incoming.view(other) }
      recorded = [] of Acc::ReceivedInvoiceView
      card = view.supplier_card_id
      amount = view.signed_gross
      if card && amount && !view.number.empty? && Partiduo::Modules.active?("ACCOUNTING") && actor.can?("accounting.entry.post")
        query = Acc::DuplicateQuery.new(supplier_card_id: card, number: view.number, amount: amount,
          currency_code: view.currency_code.presence)
        recorded = Acc.received_invoice_duplicates(actor, query).reject { |item| item.id == view.received_invoice_id }
      end
      DuplicatesView.new(same, recorded)
    end

    # Fichier reçu (l'original tel que déposé dans la boîte) ou son XML
    # (`data` pour un Factur-X, l'original pour un UBL ou un CII).
    def self.reception_file(actor : Actor, id : Int64, variant : String = "original") : FileView
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      row = Incoming.find!(id)
      receipt_id = row.receipt_id || raise Partiduo::Api::NotFound.new("reception_file", id)
      receipt = Document::Api.receipt(actor, receipt_id.to_i64)
      chosen = variant == "xml" && receipt.data_attachment_id ? "data" : "original"
      file = Document::Api.file(actor, receipt.id, chosen)
      FileView.new(file.filename, file.content_type, file.content)
    end

    # --- Annuaire --------------------------------------------------------------

    # Recherche dans l'annuaire de la plateforme active (SIREN, SIRET ou
    # adresse électronique) ; chaque ligne cite la fiche du socle de même
    # SIREN si elle existe.
    def self.lookup(actor : Actor, query : String) : Result(Array(DirectoryEntryView))
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      text = query.strip
      if text.size < 3
        return Result(Array(DirectoryEntryView)).failure(FieldError.new("q", "einvoicing.errors.directory.too_short"))
      end
      entries = Connections.connector.lookup(text)
      Result(Array(DirectoryEntryView)).success(entries.map do |entry|
        card = nil
        if !entry.siren.empty? && actor.can?("cards.card.read")
          card = Partiduo::Api::Cards.cards(actor, Partiduo::Api::Cards::CardQuery.new(search: entry.siren, limit: 5))
            .find { |item| item.siren == entry.siren }
        end
        DirectoryEntryView.new(entry.address, entry.scheme, entry.name, entry.siren, entry.siret, entry.routing_id,
          entry.platform, entry.status, card.try(&.code))
      end)
    rescue Connections::NotConfigured
      Result(Array(DirectoryEntryView)).failure(FieldError.base("einvoicing.errors.connection.missing"))
    rescue Unsupported
      Result(Array(DirectoryEntryView)).failure(FieldError.base("einvoicing.errors.directory.unsupported"))
    rescue ex : ConnectorError
      Result(Array(DirectoryEntryView)).failure(FieldError.base("einvoicing.errors.connection.failed", {"detail" => ex.localized}))
    end

    # --- Compteurs -------------------------------------------------------------

    def self.counts(actor : Actor) : CountsView
      Guard.authorize!(actor, READ, module_code: MODULE_CODE)
      CountsView.new(Reception.filter(status: "received").count.to_i64,
        Transmission.filter(status: "pending").count.to_i64, Transmission.filter(status: "rejected").count.to_i64)
    end

    # Compteur du menu : factures reçues à traiter ; `nil` si l'extension
    # est inactive ou l'acteur sans droit de lecture.
    def self.pending_count(actor : Actor) : Int64?
      return unless Partiduo::Modules.active?(MODULE_CODE) && actor.can?(READ)
      Reception.filter(status: "received").count.to_i64
    end

    # Compteur des factures émises à transmettre ou rejetées.
    def self.outgoing_attention_count(actor : Actor) : Int64?
      return unless Partiduo::Modules.active?(MODULE_CODE) && actor.can?(READ)
      Transmission.filter(status__in: %w[pending rejected]).count.to_i64
    end

    # --- Outils ----------------------------------------------------------------

    private def self.regime(actor : Actor) : String
      Partiduo::Api::Core.settings(Actor.system).tax_regime
    rescue Partiduo::Api::NotFound
      ""
    end

    private def self.fields(adapter : Connections::Adapter, row : Connection?) : Array(FieldView)
      settings = row.try { |item| Connections.settings_of(item) }
      adapter.fields.map do |field|
        stored = !(settings.try(&.secrets[field.name]?) || "").empty?
        FieldView.new(field.name, field.secret, field.required, field.kind, field.choices,
          field.secret ? "" : (settings.try(&.values[field.name]?) || ""), stored)
      end
    end

    private def self.connection_view(row : Connection) : ConnectionView
      adapter = Connections.adapter?(row.adapter.to_s)
      mode = begin
        Connections.connector(row).mode
      rescue ConnectorError
        "sandbox"
      end
      ConnectionView.new(row.adapter.to_s, adapter.try(&.label_key) || "einvoicing.adapters.unknown", row.active!, mode,
        adapter ? fields(adapter, row) : [] of FieldView, row.last_sync_at, ErrorText.translate(row.last_error || ""),
        row.updated_at!)
    end

    private def self.status_error(row : Reception, code : String) : Result(ReceptionView)
      Result(ReceptionView).failure(FieldError.base("einvoicing.errors.reception.status.#{code}", {"status" => row.status.to_s}))
    end
  end
end
