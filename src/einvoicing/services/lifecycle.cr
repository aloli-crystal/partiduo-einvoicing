# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  # Cycle de vie des factures (ADR-004 D4) : événements remontés de la
  # plateforme (Déposée 200, Rejetée 213, et les statuts du destinataire),
  # statuts émis par le dossier (Refusée 210 à la réception, Encaissée 212
  # au paiement), envoi à la plateforme. Interne.
  module Lifecycle
    # Statut d'une facture émise après un code reçu.
    TRANSMISSION_STATUS = {"200" => "deposited", "213" => "rejected", "210" => "refused", "205" => "approved",
                           "212" => "paid"}

    # Enregistre un événement sur une facture émise et met son statut à
    # jour. Idempotent sur `platform_ref`.
    def self.record!(row : Transmission, event : Connector::LifecycleEvent, state : String = "received") : Event?
      ref = event.platform_ref
      return if ref && Event.filter(platform_ref: ref).exists?
      created = Event.create!(transmission_id: row.id, code: event.code, occurred_at: event.occurred_at,
        issuer: event.issuer, reason_code: event.reason_code[0, Math.min(event.reason_code.size, 32)],
        reason: event.reason, amount: event.amount.try(&.abs), state: state, platform_ref: ref, created_at: Time.utc)
      if status = TRANSMISSION_STATUS[event.code]?
        # Un statut plus ancien ne remplace pas « Encaissée ».
        unless row.status == "paid" && event.code != "212"
          row.status = status
          row.last_code = event.code
          row.error = event.code == "213" ? [event.reason_code, event.reason].reject(&.empty?).join(" : ") : ""
          row.save!
        end
      else
        row.last_code = event.code
        row.save!
      end
      created
    end

    # Enregistre un événement reçu sur une facture reçue (statut remonté
    # par la plateforme). Idempotent sur `platform_ref`.
    def self.record!(row : Reception, event : Connector::LifecycleEvent) : Event?
      ref = event.platform_ref
      return if ref && Event.filter(platform_ref: ref).exists?
      Event.create!(reception_id: row.id, code: event.code, occurred_at: event.occurred_at, issuer: event.issuer,
        reason_code: event.reason_code[0, Math.min(event.reason_code.size, 32)], reason: event.reason,
        amount: event.amount.try(&.abs), state: "received", platform_ref: ref, created_at: Time.utc)
    end

    # Abonné de `payment.matched` (lettrage d'un paiement, Comptabilité) :
    # « Encaissée » (212) pour chaque facture émise transmise que le
    # lettrage règle, avec le montant réglé (`amounts`) et la date du
    # paiement (`matched_on`). Un même lettrage n'émet qu'une fois par
    # facture (`origin`).
    def self.payment_matched(event : Partiduo::Events::Event) : Nil
      amounts = parse_amounts(event["amounts"]?.to_s)
      paid_on = event["matched_on"]?.try { |text| Formats.date(text) } || Partiduo::Api::Core.today
      event["sources"]?.to_s.split(',').each do |source|
        kind, _, id = source.strip.partition(':')
        invoice_id = id.to_i64?
        next unless kind == "invoice" && invoice_id
        cash!(invoice_id, amounts[source.strip]?, paid_on, "matching:#{event["matching_id"]}:#{invoice_id}", event.actor_user_id)
      end
    end

    # Abonné de `payment.recorded` (encaissement saisi dans la Facturation,
    # Comptabilité inactive) : même effet.
    def self.payment_recorded(event : Partiduo::Events::Event) : Nil
      invoice_id = event["invoice_id"]?.try(&.to_i64?)
      return unless invoice_id
      paid_on = event["paid_on"]?.try { |text| Formats.date(text) } || Partiduo::Api::Core.today
      cash!(invoice_id, Formats.decimal(event["amount"]?), paid_on, "payment:#{event["payment_id"]}", event.actor_user_id)
    end

    # « Encaissée » (212), à émettre, sur une facture transmise (B2B) ou
    # déclarée (B2C) ; l'envoi est tenté après la validation de l'opération,
    # sinon à la synchronisation suivante.
    def self.cash!(invoice_id : Int64, amount : BigDecimal?, paid_on : Time, origin : String, by : Int64?) : Nil
      row = Transmission.filter(invoice_id: invoice_id).first
      return if row.nil? || !row.route.in?("platform", "b2c") || row.kind == "credit_note"
      return if Event.filter(origin: origin).exists?
      value = amount || row.total_gross!
      return unless value > 0
      created = Event.create!(transmission_id: row.id, code: "212", occurred_at: paid_on, issuer: "seller",
        amount: value, state: "to_send", origin: origin, created_by_id: by, created_at: Time.utc)
      row.status = "paid"
      row.last_code = "212"
      row.save!
      event_id = created.id!.to_i64
      Partiduo::Events.after_commit { send_later(event_id) }
    end

    # Envoi immédiat d'un statut émis, sans bloquer l'opération d'origine :
    # un échec le laisse à émettre pour la synchronisation suivante.
    def self.send_later(event_id : Int64) : Nil
      connection = Connections.active
      return if connection.nil?
      event = Event.filter(id: event_id).first
      return if event.nil?
      send!(event, Connections.connector(connection))
    rescue ex : ConnectorError | Secrets::Error
      Log.warn { "statut #{event_id} non émis : #{ex.message}" }
    end

    # Émet un statut `to_send` ou `failed` ; met à jour son état.
    def self.send!(event : Event, connector : Connector) : Bool
      connector.send_status(connector_event(event))
      event.state = "sent"
      event.sent_at = Time.utc
      event.error = ""
      event.save!
      true
    rescue ex : Unsupported
      event.state = "not_applicable"
      event.error = ex.message.to_s
      event.save!
      false
    rescue ex : ConnectorError
      event.state = "failed"
      event.error = ex.message.to_s
      event.save!
      false
    end

    # Événement tel que la plateforme le reçoit (CDAR) : facture visée,
    # parties, montant.
    def self.connector_event(event : Event) : Connector::LifecycleEvent
      settings = Partiduo::Api::Core.settings(Partiduo::Api::Actor.system)
      company = Connector::Party.new(name: settings.company_name, siren: settings.siren.gsub(/\D/, ""),
        vat_number: settings.vat_number, country_code: settings.country_code,
        electronic_address: settings.siren.gsub(/\D/, ""), scheme: Formats::SCHEME_FR_ADDR)
      if transmission = event.transmission_id.try { |id| Transmission.filter(id: id).first }
        buyer = transmission.customer_card_id.try { |id| customer(id.to_i64) } ||
                Connector::Party.new(name: transmission.customer_name.to_s, country_code: transmission.customer_country.to_s)
        Connector::LifecycleEvent.new(code: event.code!, occurred_at: event.occurred_at!, direction: "outgoing",
          invoice_ref: transmission.platform_ref || transmission.tracking_id.to_s, invoice_number: transmission.number.to_s,
          invoice_date: transmission.issue_date, type_code: transmission.type_code.to_s, issuer: event.issuer!,
          reason_code: event.reason_code.to_s, reason: event.reason.to_s, amount: event.amount,
          currency_code: transmission.currency_code.to_s, seller: company, buyer: buyer)
      else
        reception = Reception.filter(id: event.reception_id).first || raise ConnectorError.new("événement sans facture")
        seller = Connector::Party.new(name: reception.supplier_name.to_s, siren: reception.supplier_siren.to_s,
          vat_number: reception.supplier_vat.to_s, country_code: reception.supplier_country.to_s,
          electronic_address: reception.supplier_siren.to_s, scheme: Formats::SCHEME_FR_ADDR)
        Connector::LifecycleEvent.new(code: event.code!, occurred_at: event.occurred_at!, direction: "incoming",
          invoice_ref: reception.platform_ref.to_s, invoice_number: reception.number.to_s, invoice_date: reception.issue_date,
          type_code: reception.type_code.presence || "380", issuer: event.issuer!, reason_code: event.reason_code.to_s,
          reason: event.reason.to_s, amount: event.amount, currency_code: reception.currency_code.presence || "EUR",
          seller: seller, buyer: company)
      end
    end

    # Applique un statut lu chez la plateforme ; `false` si la facture visée
    # est inconnue du dossier.
    def self.apply!(event : Connector::LifecycleEvent) : Bool
      if event.direction == "incoming"
        row = find_reception(event)
        return false if row.nil?
        !record!(row, event).nil?
      else
        row = find_transmission(event)
        return false if row.nil?
        !record!(row, event).nil?
      end
    end

    private def self.find_transmission(event : Connector::LifecycleEvent) : Transmission?
      ref = event.invoice_ref
      found = ref.empty? ? nil : (Transmission.filter(platform_ref: ref).first || Transmission.filter(tracking_id: ref).first)
      found || (event.invoice_number.empty? ? nil : Transmission.filter(number: event.invoice_number).first)
    end

    private def self.find_reception(event : Connector::LifecycleEvent) : Reception?
      ref = event.invoice_ref
      found = ref.empty? ? nil : Reception.filter(platform_ref: ref).first
      found || (event.invoice_number.empty? ? nil : Reception.filter(number: event.invoice_number).first)
    end

    private def self.customer(id : Int64) : Connector::Party?
      card = Partiduo::Api::Cards.card(Partiduo::Api::Actor.system, id)
      Connector::Party.new(name: card.name, siren: card.siren, siret: card.siret, vat_number: card.vat_number,
        country_code: card.address.try(&.country_code) || "", electronic_address: card.electronic_address || "",
        scheme: card.electronic_address ? Formats::SCHEME_FR_ADDR : "")
    rescue Partiduo::Api::NotFound
      nil
    end

    # `invoice:42=100.00;invoice:43=12.50` → montants par source.
    private def self.parse_amounts(text : String) : Hash(String, BigDecimal)
      amounts = {} of String => BigDecimal
      text.split(/[;]/).each do |pair|
        source, _, amount = pair.partition('=')
        Formats.decimal(amount).try { |value| amounts[source.strip] = value }
      end
      amounts
    end

    def self.view(event : Event) : Api::EventView
      Api::EventView.new(id: event.id!.to_i64, code: event.code!, occurred_at: event.occurred_at!, issuer: event.issuer!,
        reason_code: event.reason_code || "", reason: event.reason || "", amount: event.amount, state: event.state!,
        sent_at: event.sent_at, error: event.error || "")
    end

    Log = ::Log.for("einvoicing")
  end
end
