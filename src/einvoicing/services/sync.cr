# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  # Synchronisation avec la plateforme agréée (ADR-004 D2) : factures à
  # transmettre, factures reçues et statuts lus *par curseur* page après
  # page, statuts émis, e-reporting. Chaque page est enregistrée avec son
  # curseur dans une même transaction : une interruption reprend au dernier
  # curseur conservé, sans perte ni doublon. Interne.
  module Sync
    # Nombre maximal de pages lues par synchronisation (garde-fou).
    MAX_PAGES = 200

    # Verrou consultatif de session : une seule synchronisation ou
    # transmission à la fois dans le dossier (tâche planifiée, bouton de
    # l'écran, « Transmettre ») ; DECISIONS D-EINV-022.
    LOCK_KEY = "einvoicing:sync"

    # Synchronisation ou transmission déjà en cours.
    class Busy < Exception
    end

    # Exécute le bloc sous le verrou de synchronisation ; `Busy` s'il est
    # déjà pris. Le verrou est tenu par une connexion réservée pendant tout
    # le bloc et libéré à la fin (ou à la fermeture de la connexion si le
    # processus s'arrête).
    def self.exclusive(&)
      Marten::DB::Connection.default.open do |db|
        acquired = db.scalar("SELECT pg_try_advisory_lock(hashtext($1))", LOCK_KEY).as(Bool)
        raise Busy.new("synchronisation en cours") unless acquired
        begin
          return yield
        ensure
          db.exec("SELECT pg_advisory_unlock(hashtext($1))", LOCK_KEY)
        end
      end
    end

    def self.run(by : Int64?) : Api::SyncView
      exclusive { run_locked(by) }
    end

    private def self.run_locked(by : Int64?) : Api::SyncView
      connection = Connections.active || raise Connections::NotConfigured.new
      adapter = connection.adapter.to_s
      connector = Connections.connector(connection)
      errors = [] of String

      transmitted = 0
      if Partiduo::Modules.active?("INVOICING")
        # Canal relu avant de transmettre (D-EINV-021).
        Transmission.filter(channel_final: false, status__in: Outgoing::REFRESHABLE).order(:id).each do |row|
          Outgoing.refresh!(row)
        end
        Transmission.filter(status: "pending", route__in: %w[platform b2c]).order(:id).each do |row|
          error = Outgoing.transmit!(row, connector, adapter, by)
          if error
            errors << ErrorText.encode("einvoicing.errors.sync.invoice", {"number" => row.number.to_s, "detail" => error})
          elsif row.status != "pending"
            transmitted += 1
          end
        end
      end

      received = guarded(errors) { receive(connection, connector, adapter) } || 0
      statuses = guarded(errors) { statuses(connection, connector) } || 0

      sent_statuses = 0
      Event.filter(state__in: %w[to_send failed]).order(:id).each do |event|
        if Lifecycle.send!(event, connector)
          sent_statuses += 1
        elsif event.state == "failed"
          errors << event.error.to_s
        end
      end

      reports, report_errors = EReporting.send_pending(connector)
      errors.concat(report_errors)

      Connection.filter(id: connection.id).update(last_sync_at: Time.utc, last_error: errors.first? || "",
        updated_at: Time.utc)
      Api::SyncView.new(transmitted, received, statuses, sent_statuses, reports, errors.map { |text| ErrorText.translate(text) })
    end

    # Factures reçues, page après page, à partir du curseur conservé.
    private def self.receive(connection : Connection, connector : Connector, adapter : String) : Int32
      count = 0
      cursor = connection.incoming_cursor.try { |value| Connector::Cursor.new(value) }
      MAX_PAGES.times do
        page = connector.fetch_incoming(cursor)
        Partiduo::Api::Transaction.run do
          page.items.each do |item|
            known = Reception.filter(platform_ref: item.platform_ref).exists?
            Incoming.store!(item, adapter)
            count += 1 unless known
          end
          Connection.filter(id: connection.id).update(incoming_cursor: page.cursor.try(&.value))
          Partiduo::Api::Result(Nil).success(nil)
        end
        connector.acknowledge(page.items)
        cursor = page.cursor
        break unless page.has_more
      end
      count
    end

    # Statuts, page après page, à partir du curseur conservé.
    private def self.statuses(connection : Connection, connector : Connector) : Int32
      count = 0
      cursor = connection.status_cursor.try { |value| Connector::Cursor.new(value) }
      MAX_PAGES.times do
        page = connector.fetch_statuses(cursor)
        Partiduo::Api::Transaction.run do
          page.items.each { |event| count += 1 if Lifecycle.apply!(event) }
          Connection.filter(id: connection.id).update(status_cursor: page.cursor.try(&.value))
          Partiduo::Api::Result(Nil).success(nil)
        end
        cursor = page.cursor
        break unless page.has_more
      end
      count
    end

    private def self.guarded(errors : Array(String), &) : Int32?
      yield
    rescue ex : ConnectorError
      errors << ex.text
      nil
    end
  end
end
