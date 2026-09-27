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

    def self.run(by : Int64?) : Api::SyncView
      connection = Connections.active || raise Connections::NotConfigured.new
      adapter = connection.adapter.to_s
      connector = Connections.connector(connection)
      errors = [] of String

      transmitted = 0
      if Partiduo::Modules.active?("INVOICING")
        Transmission.filter(status: "pending", route__in: %w[platform b2c]).order(:id).each do |row|
          error = Outgoing.transmit!(row, connector, adapter, by)
          error ? (errors << "#{row.number} : #{error}") : (transmitted += 1)
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
      Api::SyncView.new(transmitted, received, statuses, sent_statuses, reports, errors)
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
      errors << ex.message.to_s
      nil
    end
  end
end
