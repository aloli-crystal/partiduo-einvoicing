# SPDX-License-Identifier: AGPL-3.0-or-later

# Tables de l'extension EINV (ADR-004 D2 à D4, D8), successeurs de
# `peppol_connect.peppol_parameter`, `document_incoming` et
# `document_outgoing` de `peppol-connect`.
#
# Intégrité en base :
#
# * un seul raccordement actif (index unique partiel) ;
# * statuts, routes, émetteurs et états contrôlés ;
# * un événement porte sur une facture émise *ou* une facture reçue ;
# * un événement « à émettre » est de l'émetteur du dossier ;
# * une facture reçue pré-comptabilisée cite son écriture ; une facture
#   refusée ou pré-comptabilisée a une date de décision ;
# * montants de l'e-reporting et des événements positifs ou nuls.
class Migration::Einvoicing::V0001 < Marten::Migration
  depends_on :core, "0002_core_referential"
  depends_on :document, "0001_create_document_receipt"

  CONSTRAINTS = [
    {<<-SQL, "DROP INDEX IF EXISTS einvoicing_connection_one_active"},
      CREATE UNIQUE INDEX einvoicing_connection_one_active ON einvoicing_connection (active) WHERE active
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE einvoicing_transmission
        ADD CONSTRAINT einvoicing_transmission_status_check CHECK (status IN
          ('pending', 'submitted', 'deposited', 'rejected', 'refused', 'approved', 'paid', 'ereporting', 'off_platform')),
        ADD CONSTRAINT einvoicing_transmission_route_check CHECK (route IN ('platform', 'b2c', 'international', 'off_platform')),
        ADD CONSTRAINT einvoicing_transmission_kind_check CHECK (kind IN ('invoice', 'deposit_invoice', 'credit_note')),
        ADD CONSTRAINT einvoicing_transmission_submitted_check CHECK (
          status IN ('pending', 'ereporting', 'off_platform') OR platform_ref IS NOT NULL
        )
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE einvoicing_reception
        ADD CONSTRAINT einvoicing_reception_status_check CHECK (status IN ('received', 'accepted', 'refused', 'posted')),
        ADD CONSTRAINT einvoicing_reception_posted_check CHECK ((status = 'posted') = (entry_id IS NOT NULL)),
        ADD CONSTRAINT einvoicing_reception_decided_check CHECK (status NOT IN ('refused', 'posted') OR decided_at IS NOT NULL)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE einvoicing_lifecycle_event
        ADD CONSTRAINT einvoicing_lifecycle_event_target_check CHECK ((transmission_id IS NULL) <> (reception_id IS NULL)),
        ADD CONSTRAINT einvoicing_lifecycle_event_code_check CHECK (code ~ '^[0-9]{3}$'),
        ADD CONSTRAINT einvoicing_lifecycle_event_issuer_check CHECK (issuer IN ('platform', 'seller', 'buyer')),
        ADD CONSTRAINT einvoicing_lifecycle_event_state_check CHECK (state IN
          ('received', 'to_send', 'sent', 'failed', 'not_applicable')),
        ADD CONSTRAINT einvoicing_lifecycle_event_amount_check CHECK (amount IS NULL OR amount >= 0),
        ADD CONSTRAINT einvoicing_lifecycle_event_sent_check CHECK (state <> 'sent' OR sent_at IS NOT NULL),
        ADD CONSTRAINT einvoicing_lifecycle_event_fk_transmission FOREIGN KEY (transmission_id)
          REFERENCES einvoicing_transmission (id),
        ADD CONSTRAINT einvoicing_lifecycle_event_fk_reception FOREIGN KEY (reception_id)
          REFERENCES einvoicing_reception (id)
      SQL
    {<<-SQL, "SELECT 1"},
      ALTER TABLE einvoicing_report
        ADD CONSTRAINT einvoicing_report_kind_check CHECK (kind IN ('international_sales')),
        ADD CONSTRAINT einvoicing_report_state_check CHECK (state IN ('to_send', 'sent', 'failed', 'not_applicable')),
        ADD CONSTRAINT einvoicing_report_fk_transmission FOREIGN KEY (transmission_id)
          REFERENCES einvoicing_transmission (id)
      SQL
    # Le justificatif d'une facture reçue ne disparaît pas (DOCUMENT n'en
    # supprime aucun ; la clé le garantit).
    {<<-SQL, "SELECT 1"},
      ALTER TABLE einvoicing_reception
        ADD CONSTRAINT einvoicing_reception_fk_receipt FOREIGN KEY (receipt_id) REFERENCES document_receipt (id)
      SQL
  ]

  def plan
    create_table :einvoicing_connection do
      column :id, :big_int, primary_key: true, auto: true
      column :adapter, :string, max_size: 32, unique: true
      column :active, :bool, default: false
      column :settings, :json
      column :secrets, :text, default: ""
      column :access_token, :text, default: ""
      column :access_token_expires_at, :date_time, null: true
      column :refresh_token, :text, default: ""
      column :incoming_cursor, :text, null: true
      column :status_cursor, :text, null: true
      column :last_sync_at, :date_time, null: true
      column :last_error, :text, default: ""
      column :updated_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :einvoicing_transmission do
      column :id, :big_int, primary_key: true, auto: true
      column :invoice_id, :big_int, unique: true
      column :kind, :string, max_size: 16
      column :number, :string, max_size: 40
      column :type_code, :string, max_size: 3
      column :customer_card_id, :big_int, null: true
      column :customer_name, :string, max_size: 255, default: ""
      column :customer_country, :string, max_size: 2, default: ""
      column :issue_date, :date, null: true
      column :currency_code, :string, max_size: 3, default: "EUR"
      column :total_net, :decimal, max_digits: 20, decimal_places: 4
      column :total_vat, :decimal, max_digits: 20, decimal_places: 4
      column :total_gross, :decimal, max_digits: 20, decimal_places: 4
      column :channel, :string, max_size: 16, default: ""
      column :b2c, :bool, default: false
      column :route, :string, max_size: 16
      column :platform_required, :bool, default: false
      column :status, :string, max_size: 16, index: true
      column :last_code, :string, max_size: 3, default: ""
      column :adapter, :string, max_size: 32, default: ""
      column :syntax, :string, max_size: 16, default: ""
      column :profile, :string, max_size: 20, default: ""
      column :platform_ref, :string, max_size: 255, null: true, unique: true
      column :tracking_id, :string, max_size: 64, unique: true
      column :submitted_at, :date_time, null: true
      column :attempts, :int, default: 0
      column :error, :text, default: ""
      column :submitted_by_id, :big_int, null: true
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :einvoicing_reception do
      column :id, :big_int, primary_key: true, auto: true
      column :platform_ref, :string, max_size: 255, unique: true
      column :adapter, :string, max_size: 32, default: ""
      column :receipt_id, :big_int, null: true, index: true
      column :syntax, :string, max_size: 16, default: ""
      column :profile, :string, max_size: 120, default: ""
      column :type_code, :string, max_size: 3, default: ""
      column :number, :string, max_size: 100, default: ""
      column :issue_date, :date, null: true
      column :due_date, :date, null: true
      column :currency_code, :string, max_size: 3, default: ""
      column :supplier_name, :string, max_size: 255, default: ""
      column :supplier_siren, :string, max_size: 9, default: "", index: true
      column :supplier_vat, :string, max_size: 32, default: ""
      column :supplier_country, :string, max_size: 2, default: ""
      column :supplier_card_id, :big_int, null: true
      column :buyer_siren, :string, max_size: 9, default: ""
      column :total_net, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :total_vat, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :total_gross, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :payable, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :data, :json
      column :status, :string, max_size: 16, default: "received", index: true
      column :entry_id, :big_int, null: true
      column :received_invoice_id, :big_int, null: true
      column :decided_at, :date_time, null: true
      column :decided_by_id, :big_int, null: true
      column :received_at, :date_time
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    create_table :einvoicing_lifecycle_event do
      column :id, :big_int, primary_key: true, auto: true
      column :transmission_id, :big_int, null: true, index: true
      column :reception_id, :big_int, null: true, index: true
      column :code, :string, max_size: 3
      column :occurred_at, :date_time
      column :issuer, :string, max_size: 16
      column :reason_code, :string, max_size: 32, default: ""
      column :reason, :text, default: ""
      column :amount, :decimal, max_digits: 20, decimal_places: 4, null: true
      column :state, :string, max_size: 16
      column :platform_ref, :string, max_size: 255, null: true, unique: true
      column :sent_at, :date_time, null: true
      column :error, :text, default: ""
      column :origin, :string, max_size: 64, null: true, unique: true
      column :created_by_id, :big_int, null: true
      column :created_at, :date_time
    end

    create_table :einvoicing_report do
      column :id, :big_int, primary_key: true, auto: true
      column :kind, :string, max_size: 32
      column :transmission_id, :big_int, null: true, unique: true
      column :period, :date
      column :entry, :json
      column :state, :string, max_size: 16, default: "to_send", index: true
      column :batch_ref, :string, max_size: 64, default: ""
      column :sent_at, :date_time, null: true
      column :error, :text, default: ""
      column :created_at, :date_time
      column :updated_at, :date_time
    end

    CONSTRAINTS.each { |(forward, backward)| execute(forward, backward) }
  end
end
