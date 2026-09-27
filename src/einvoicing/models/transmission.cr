# SPDX-License-Identifier: AGPL-3.0-or-later

module Einvoicing
  # Facture émise suivie par l'extension (facture, facture d'acompte ou
  # avoir du module Facturation), relevée à `invoice.issued` ou
  # `credit_note.issued`. `invoice_id` est l'identifiant du document de la
  # Facturation, lu par `Partiduo::Api::Invoicing` ; pas de clé étrangère
  # vers un module que l'extension ne déclare pas (D-DOC-002).
  #
  # `route` : `platform` (transmise à la plateforme, règle B2B), `b2c`
  # (transmise pour e-reporting, note `BAR` = `B2C`), `international`
  # (e-reporting des ventes internationales), `off_platform` (courriel ou
  # papier, rien à transmettre).
  class Transmission < Marten::Model
    field :id, :big_int, primary_key: true, auto: true
    field :invoice_id, :big_int, unique: true
    field :kind, :string, max_size: 16
    field :number, :string, max_size: 40
    field :type_code, :string, max_size: 3
    field :customer_card_id, :big_int, blank: true, null: true
    field :customer_name, :string, max_size: 255, blank: true, default: ""
    field :customer_country, :string, max_size: 2, blank: true, default: ""
    field :issue_date, :date, blank: true, null: true
    field :currency_code, :string, max_size: 3, default: "EUR"
    field :total_net, :decimal, max_digits: 20, decimal_places: 4
    field :total_vat, :decimal, max_digits: 20, decimal_places: 4
    field :total_gross, :decimal, max_digits: 20, decimal_places: 4
    field :channel, :string, max_size: 16, blank: true, default: ""
    field :b2c, :bool, default: false
    field :route, :string, max_size: 16
    # La réforme impose la plateforme (client professionnel français) alors
    # que le canal est le courriel ou le papier : signalé, jamais bloqué
    # (ADR-004 D9).
    field :platform_required, :bool, default: false
    # Canal définitif : facture envoyée (canal figé par la Facturation),
    # déposée, ou déclarée en e-reporting. Tant qu'il ne l'est pas, la voie
    # est recalculée avant chaque transmission (DECISIONS D-EINV-021).
    field :channel_final, :bool, default: false
    # `pending`, `submitted`, `deposited` (200), `rejected` (213), `refused`
    # (210), `approved` (205), `paid` (212), `ereporting`, `off_platform`.
    field :status, :string, max_size: 16, index: true
    field :last_code, :string, max_size: 3, blank: true, default: ""
    field :adapter, :string, max_size: 32, blank: true, default: ""
    field :syntax, :string, max_size: 16, blank: true, default: ""
    field :profile, :string, max_size: 20, blank: true, default: ""
    field :platform_ref, :string, max_size: 255, blank: true, null: true, unique: true
    field :tracking_id, :string, max_size: 64, unique: true
    field :submitted_at, :date_time, blank: true, null: true
    field :attempts, :int, default: 0
    field :error, :text, blank: true, default: ""
    field :submitted_by_id, :big_int, blank: true, null: true

    with_timestamp_fields
  end
end
