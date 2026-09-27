# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  # Facture reçue par la plateforme agréée (ADR-004 D3), lue (UBL, CII,
  # Factur-X) et déposée dans la boîte « Justificatifs à traiter »
  # (`receipt_id`, justificatif de `partiduo-document`, lu par
  # `Document::Api`). Les fichiers sont des pièces jointes du socle, rangées
  # par DOCUMENT.
  #
  # Statuts : `received` (à traiter), `accepted`, `refused` (statut 210
  # émis), `posted` (pré-comptabilisée : `entry_id`, `received_invoice_id`
  # de la Comptabilité).
  class Reception < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :platform_ref, :string, max_size: 255, unique: true
    field :adapter, :string, max_size: 32, blank: true, default: ""
    field :receipt_id, :big_int, blank: true, null: true, index: true
    field :syntax, :string, max_size: 16, blank: true, default: ""
    field :profile, :string, max_size: 120, blank: true, default: ""
    field :type_code, :string, max_size: 3, blank: true, default: ""
    field :number, :string, max_size: 100, blank: true, default: ""
    field :issue_date, :date, blank: true, null: true
    field :due_date, :date, blank: true, null: true
    field :currency_code, :string, max_size: 3, blank: true, default: ""
    field :supplier_name, :string, max_size: 255, blank: true, default: ""
    field :supplier_siren, :string, max_size: 9, blank: true, default: "", index: true
    field :supplier_vat, :string, max_size: 32, blank: true, default: ""
    field :supplier_country, :string, max_size: 2, blank: true, default: ""
    field :supplier_card_id, :big_int, blank: true, null: true
    field :buyer_siren, :string, max_size: 9, blank: true, default: ""
    field :total_net, :decimal, max_digits: 20, decimal_places: 4, blank: true, null: true
    field :total_vat, :decimal, max_digits: 20, decimal_places: 4, blank: true, null: true
    field :total_gross, :decimal, max_digits: 20, decimal_places: 4, blank: true, null: true
    field :payable, :decimal, max_digits: 20, decimal_places: 4, blank: true, null: true
    # Lignes, ventilation de TVA, notes et erreurs de lecture (JSON).
    field :data, :json
    field :status, :string, max_size: 16, default: "received", index: true
    field :entry_id, :big_int, blank: true, null: true
    field :received_invoice_id, :big_int, blank: true, null: true
    field :decided_at, :date_time, blank: true, null: true
    field :decided_by_id, :big_int, blank: true, null: true
    field :received_at, :date_time

    with_timestamp_fields
  end
end
